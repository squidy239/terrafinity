const std = @import("std");

const tracy = @import("tracy");
const vk = @import("vulkan");
const DeviceProxy = vk.DeviceProxy;

const VulkanContext = @import("../../VulkanContext.zig").VulkanContext;
const core = @import("core.zig");

/// Free list of candidate slots. Owned by the frame thread, like the candidate buffer.
const IndexPool = struct {
    free_indices: []u32,
    head: u32,

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !IndexPool {
        const indices = try allocator.alloc(u32, capacity);
        for (indices, 0..) |*val, i| val.* = @intCast(capacity - 1 - i);
        return .{ .free_indices = indices, .head = capacity };
    }

    pub fn deinit(self: *IndexPool, allocator: std.mem.Allocator) void {
        allocator.free(self.free_indices);
    }

    pub fn allocIndex(self: *IndexPool) ?u32 {
        if (self.head == 0) return null;
        self.head -= 1;
        return self.free_indices[self.head];
    }

    pub fn freeIndex(self: *IndexPool, index: u32) void {
        std.debug.assert(self.head < self.free_indices.len);
        self.free_indices[self.head] = index;
        self.head += 1;
    }

    pub fn grow(self: *IndexPool, allocator: std.mem.Allocator, new_capacity: u32) !void {
        const old_capacity = @as(u32, @intCast(self.free_indices.len));
        if (new_capacity <= old_capacity) return;
        const added = new_capacity - old_capacity;
        self.free_indices = try allocator.realloc(self.free_indices, new_capacity);
        for (self.free_indices[self.head .. self.head + added], old_capacity..) |*val, i| val.* = @intCast(i);
        self.head += added;
    }
};

pub const StagingRing = struct {
    const transfer_alignment: vk.DeviceSize = 256;

    allocator: std.mem.Allocator,

    mapping: []align(transfer_alignment) u8,

    head: vk.DeviceSize,
    entries: std.ArrayList(struct { ptr: [*]const u8, timeline_value: ?u64 }),
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, cpu_to_gpu_allocator: std.mem.Allocator, capacity_bytes: vk.DeviceSize) !StagingRing {
        const mapping = try cpu_to_gpu_allocator.alignedAlloc(u8, .fromByteUnits(transfer_alignment), capacity_bytes);
        errdefer cpu_to_gpu_allocator.free(mapping);

        return .{
            .allocator = allocator,
            .mapping = mapping,
            .head = 0,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *StagingRing, cpu_to_gpu_allocator: std.mem.Allocator) void {
        cpu_to_gpu_allocator.free(self.mapping);
        self.entries.deinit(self.allocator);
    }

    /// Allocates a staging slice, or null when the ring is full. The allocation
    /// failure of the entry bookkeeping is reported so callers do not mistake it
    /// for a full ring and spin.
    pub fn alloc(self: *StagingRing, io: std.Io, size: vk.DeviceSize) !?[]u8 {
        const result = try self.allocPair(io, .{ size, 0 });
        return if (result) |pair| pair[0] else null;
    }

    /// Reserves slices for both sizes as one atomic operation: either every nonzero
    /// size gets a slice or the ring is left untouched and null is returned. A size
    /// of zero yields null in that slot. Allocating both at once removes the
    /// hold-and-wait where an unbound slice blocks FIFO retirement while its owner
    /// waits for ring space that can never free past it.
    pub fn allocPair(self: *StagingRing, io: std.Io, sizes: [2]vk.DeviceSize) !?[2]?[]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var total: vk.DeviceSize = 0;
        for (sizes) |size| total += std.mem.alignForward(vk.DeviceSize, size, transfer_alignment);
        // A pair that cannot fit even in an empty ring would spin forever in the
        // caller's retry loop; fail loudly instead.
        if (total > self.mapping.len) return error.StagingTooLarge;

        var wraps = false;
        if (self.entries.items.len > 0) {
            // FIFO retirement guarantees entries[0] is the tail while any bytes are live.
            const tail_offset: vk.DeviceSize = @intCast(@intFromPtr(self.entries.items[0].ptr) - @intFromPtr(self.mapping.ptr));
            std.debug.assert(tail_offset <= self.mapping.len);
            // Ring occupancy truth table (FIFO: tail is entries[0], head is the bump cursor):
            // | state                                 | live set              | free set                |
            // | empty (no entries)                    | {}                    | [head, len)             |
            // | contiguous (tail < head)              | [tail, head)          | [head, len) + [0, tail) |
            // | split (head < tail)                   | [tail, len)+[0, head) | [head, tail)            |
            // | degenerate full (head == tail, live)  | whole ring            | {} (zero gap)           |
            // Equality MUST take the split branch: head == tail with live entries
            // means full, so the gap is zero and any nonzero total returns null
            // instead of wrapping to 0 and overwriting the tail mid-transfer.
            if (self.head <= tail_offset) {
                // Split (or degenerate full): live set is [tail,len)+[0,head); the prefix
                // is occupied so only the [head,tail) gap is free. NEVER wrap here.
                if (total > tail_offset - self.head) return null;
            } else {
                wraps = self.head + total > self.mapping.len;
                if (wraps and total > tail_offset) return null;
                // The wrap target [0, total) must stay inside the free prefix [0, tail).
                if (wraps) std.debug.assert(total <= tail_offset);
            }
        } else {
            wraps = self.head + total > self.mapping.len;
        }

        var entry_count: usize = 0;
        for (sizes) |size| {
            if (size != 0) entry_count += 1;
        }
        try self.entries.ensureUnusedCapacity(self.allocator, entry_count);

        if (wraps) self.head = 0;

        var result: [2]?[]u8 = .{ null, null };
        for (sizes, &result) |size, *slot| {
            if (size == 0) continue;
            const slice = self.mapping[self.head..][0..@intCast(size)];
            self.entries.appendAssumeCapacity(.{ .ptr = slice.ptr, .timeline_value = null });
            self.head += std.mem.alignForward(vk.DeviceSize, size, transfer_alignment);
            slot.* = slice;
        }
        return result;
    }

    fn findEntryIndex(self: *StagingRing, slice: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.ptr == slice.ptr) return i;
        }
        return null;
    }

    pub fn bind(self: *StagingRing, io: std.Io, slice: []const u8, timeline_value: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.findEntryIndex(slice)) |index| self.entries.items[index].timeline_value = timeline_value;
    }

    pub fn retire(self: *StagingRing, io: std.Io, current_transfer_val: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var retire_count: usize = 0;
        for (self.entries.items) |entry| {
            if ((entry.timeline_value orelse break) > current_transfer_val) break;
            retire_count += 1;
        }
        if (retire_count > 0) @memmove(self.entries.items[0 .. self.entries.items.len - retire_count], self.entries.items[retire_count..]);
        self.entries.items.len -= retire_count;
        if (self.entries.items.len == 0) self.head = 0;
    }

    pub fn cancel(self: *StagingRing, io: std.Io, slice: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const index = self.findEntryIndex(slice) orelse return;
        std.debug.assert(self.entries.items[index].timeline_value == null);
        _ = self.entries.orderedRemove(index);
        if (index == self.entries.items.len) {
            // Cancelled the tail entry: retract head so its space is
            // immediately reusable instead of stranded until wrap-around.
            const aligned = std.mem.alignForward(vk.DeviceSize, slice.len, transfer_alignment);
            std.debug.assert(self.head >= aligned);
            self.head -= aligned;
        }
        if (self.entries.items.len == 0) self.head = 0;
    }
};

const log = std.log.scoped(.gpu_region_allocator);

const buf_align: std.mem.Alignment = .fromByteUnits(256);

const Region = struct {
    offset: vk.DeviceSize,
    length: vk.DeviceSize,
    /// Graphics timeline value at which every frame that could read this region has
    /// completed. A transfer reusing this region must wait until graphics passes it.
    safe_graphics: u64,
};

pub const GrowInfo = struct {
    old_slice: []align(buf_align.toByteUnits()) u8,
    old_buffer: vk.Buffer,
    old_buffer_offset: vk.DeviceSize,
    old_used: vk.DeviceSize,
};

pub const GpuRegionAllocator = struct {
    pub const AllocResult = struct {
        offset: vk.DeviceSize,
        buffer: vk.Buffer,
        buffer_offset: vk.DeviceSize,
        /// 0 for a fresh (never-read) region; the free-time graphics value for a reused one.
        safe_graphics: u64,
    };

    /// What the frame thread binds and barriers, read as one snapshot by `binding`.
    pub const Binding = struct { buffer: vk.Buffer, offset: vk.DeviceSize, used: vk.DeviceSize };

    buffer_slice: []align(buf_align.toByteUnits()) u8,
    // Atomic so the frame thread reads them without taking the allocator mutex. `grow`
    // brackets the buffer swap with odd and even `binding_seq` values (a seqlock).
    buffer: std.atomic.Value(vk.Buffer),
    buffer_offset: std.atomic.Value(vk.DeviceSize),
    used: std.atomic.Value(vk.DeviceSize) = .init(0),
    binding_seq: std.atomic.Value(u32) = .init(0),

    free_regions: std.ArrayList(Region) = .empty,
    free_list_allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,

    /// Takes ownership of `slice`, which `buffer` backs starting at `buffer_offset`.
    pub fn init(free_list_allocator: std.mem.Allocator, slice: []align(buf_align.toByteUnits()) u8, buffer: vk.Buffer, buffer_offset: vk.DeviceSize) GpuRegionAllocator {
        return .{
            .buffer_slice = slice,
            .buffer = .init(buffer),
            .buffer_offset = .init(buffer_offset),
            .free_list_allocator = free_list_allocator,
        };
    }

    pub fn deinit(self: *GpuRegionAllocator, gpu_allocator: std.mem.Allocator) void {
        self.free_regions.deinit(self.free_list_allocator);
        gpu_allocator.free(self.buffer_slice);
    }

    pub fn allocRegion(self: *GpuRegionAllocator, io: std.Io, length: vk.DeviceSize) ?AllocResult {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const buffer = self.buffer.load(.monotonic);
        const buffer_offset = self.buffer_offset.load(.monotonic);

        if (self.findFreeRegion(length)) |found| {
            return .{ .offset = found.offset, .buffer = buffer, .buffer_offset = buffer_offset, .safe_graphics = found.safe_graphics };
        }
        const current_used = self.used.load(.monotonic);
        const new_used, const overflow = @addWithOverflow(current_used, length);
        if (overflow != 0 or new_used > self.buffer_slice.len) return null;
        // Release pairs with `binding`: a reader that sees a size grown into a new
        // buffer also sees that grow's `binding_seq` change and retries.
        self.used.store(new_used, .release);
        return .{ .offset = current_used, .buffer = buffer, .buffer_offset = buffer_offset, .safe_graphics = 0 };
    }

    /// A consistent buffer, offset, and used size. Lock-free so the frame thread never
    /// waits on allocation; it retries only while a grow is swapping the buffer.
    pub fn binding(self: *const GpuRegionAllocator) Binding {
        while (true) {
            const seq = self.binding_seq.load(.acquire);
            const result: Binding = .{
                .buffer = self.buffer.load(.acquire),
                .offset = self.buffer_offset.load(.acquire),
                .used = self.used.load(.acquire),
            };
            if (seq % 2 == 0 and self.binding_seq.load(.monotonic) == seq) return result;
            std.atomic.spinLoopHint();
        }
    }

    fn overlaps(offset: vk.DeviceSize, length: vk.DeviceSize, region: Region) bool {
        return offset < region.offset + region.length and region.offset < offset + length;
    }

    fn findFreeRegion(self: *GpuRegionAllocator, length: vk.DeviceSize) ?struct { offset: vk.DeviceSize, safe_graphics: u64 } {
        // Best-fit: reuse the smallest gap that holds the request, so small
        // meshes stop stranding large gaps at the head of the list.
        var best: ?usize = null;
        var best_len: vk.DeviceSize = std.math.maxInt(vk.DeviceSize);
        for (self.free_regions.items, 0..) |region, i| {
            if (region.length < length or region.length >= best_len) continue;
            best = i;
            best_len = region.length;
        }
        const i = best orelse return null;
        const region = self.free_regions.items[i];
        if (region.length == length) {
            _ = self.free_regions.orderedRemove(i);
        } else {
            self.free_regions.items[i] = .{
                .offset = region.offset + length,
                .length = region.length - length,
                .safe_graphics = region.safe_graphics,
            };
        }
        return .{ .offset = region.offset, .safe_graphics = region.safe_graphics };
    }

    pub fn freeRegion(self: *GpuRegionAllocator, io: std.Io, offset: vk.DeviceSize, length: vk.DeviceSize, current_graphics_val: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        // Sorted by offset, so the insert point is a binary search and only the
        // two neighbors can overlap the freed range.
        const insertion_index = std.sort.lowerBound(Region, self.free_regions.items, offset, struct {
            fn order(context: vk.DeviceSize, region: Region) std.math.Order {
                return std.math.order(context, region.offset);
            }
        }.order);
        if ((insertion_index > 0 and overlaps(offset, length, self.free_regions.items[insertion_index - 1])) or
            (insertion_index < self.free_regions.items.len and overlaps(offset, length, self.free_regions.items[insertion_index])))
        {
            std.debug.panic("GpuRegionAllocator.freeRegion: overlapping free of [{d}, {d})", .{ offset, offset + length });
        }

        self.free_regions.insert(self.free_list_allocator, insertion_index, .{ .offset = offset, .length = length, .safe_graphics = current_graphics_val }) catch @panic("GpuRegionAllocator.freeRegion: insert OOM");

        // The list stays sorted and merged, so at most one neighbor touches each side.
        var merge_index = insertion_index;
        if (merge_index > 0 and self.free_regions.items[merge_index - 1].offset + self.free_regions.items[merge_index - 1].length == self.free_regions.items[merge_index].offset) {
            mergeRegions(&self.free_regions, merge_index - 1);
            merge_index -= 1;
        }
        if (merge_index + 1 < self.free_regions.items.len and self.free_regions.items[merge_index].offset + self.free_regions.items[merge_index].length == self.free_regions.items[merge_index + 1].offset) {
            mergeRegions(&self.free_regions, merge_index);
        }
    }

    /// Folds `regions.items[index + 1]` into `regions.items[index]`, keeping the
    /// later safe-graphics value. Caller proves the pair is adjacent.
    fn mergeRegions(regions: *std.ArrayList(Region), index: usize) void {
        regions.items[index].safe_graphics = @max(regions.items[index].safe_graphics, regions.items[index + 1].safe_graphics);
        regions.items[index].length += regions.items[index + 1].length;
        _ = regions.orderedRemove(index + 1);
    }

    /// The buffer size the next `grow` needs: double the current one.
    pub fn nextCapacity(self: *GpuRegionAllocator, io: std.Io) !vk.DeviceSize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return std.math.mul(vk.DeviceSize, self.buffer_slice.len, 2) catch error.OutOfMemory;
    }

    /// Swaps in `new_slice`, backed by `buffer` at `buffer_offset`, which the caller allocates
    /// outside its locks because device allocation is slow. Returns null when the buffer
    /// already reached that size.
    pub fn grow(self: *GpuRegionAllocator, io: std.Io, new_slice: []align(buf_align.toByteUnits()) u8, buffer: vk.Buffer, buffer_offset: vk.DeviceSize) ?GrowInfo {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (new_slice.len <= self.buffer_slice.len) return null;
        log.info("growing from {d} MB to {d} MB", .{
            self.buffer_slice.len / (1024 * 1024),
            new_slice.len / (1024 * 1024),
        });

        const old_info: GrowInfo = .{
            .old_slice = self.buffer_slice,
            .old_buffer = self.buffer.load(.monotonic),
            .old_buffer_offset = self.buffer_offset.load(.monotonic),
            .old_used = self.used.load(.monotonic),
        };

        self.buffer_slice = new_slice;
        // Freed regions stay reusable: the caller copies [0, used) into the new buffer,
        // so their offsets remain valid.
        const seq = self.binding_seq.load(.monotonic);
        self.binding_seq.store(seq +% 1, .monotonic);
        self.buffer_offset.store(buffer_offset, .release);
        self.buffer.store(buffer, .release);
        self.binding_seq.store(seq +% 2, .release);

        log.info("grew to {d} MB", .{self.buffer_slice.len / (1024 * 1024)});

        return old_info;
    }
};

const reservoir_size = 512;

pub const CommandPoolReservoir = struct {
    pools: [reservoir_size]vk.CommandPool = undefined,
    cmds: [reservoir_size]vk.CommandBuffer = undefined,
    used: [reservoir_size]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
    /// Number of created pools; only `pools[0..count]` are valid.
    count: usize = 0,

    pub const Borrowed = struct { pool: vk.CommandPool, cmd: vk.CommandBuffer };

    pub fn init(self: *CommandPoolReservoir, dev: DeviceProxy, queue_family: u32, vkalloc: *const vk.AllocationCallbacks) !void {
        errdefer self.deinit(dev, vkalloc);
        for (&self.pools, &self.cmds) |*pool, *cmd| {
            pool.* = try dev.createCommandPool(&.{ .flags = .{ .reset_command_buffer = true }, .queue_family_index = queue_family }, vkalloc);
            self.count += 1;
            try dev.allocateCommandBuffers(&.{ .command_pool = pool.*, .level = .primary, .command_buffer_count = 1 }, (&cmd.*)[0..1]);
        }
    }

    pub fn deinit(self: *CommandPoolReservoir, dev: DeviceProxy, vkalloc: *const vk.AllocationCallbacks) void {
        for (self.pools[0..self.count]) |pool| dev.destroyCommandPool(pool, vkalloc);
    }

    pub fn tryBorrowPool(self: *CommandPoolReservoir) ?Borrowed {
        for (self.pools[0..self.count], self.cmds[0..self.count], 0..) |pool, cmd, i| {
            if (self.used[i].cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                return .{ .pool = pool, .cmd = cmd };
            }
        }
        return null;
    }

    pub fn returnPool(self: *CommandPoolReservoir, dev: DeviceProxy, pool: vk.CommandPool) void {
        dev.resetCommandPool(pool, .{}) catch {
            @panic("CommandPoolReservoir.returnPool: resetCommandPool failed - command pool is now unusable");
        };
        for (self.pools[0..self.count], 0..) |p, i| {
            if (p == pool) {
                self.used[i].store(false, .release);
                break;
            }
        }
    }
};

/// Shared GPU allocation pools: device-local and host-visible GPU-visible memory,
/// each wrapped in a SafeAllocator backed by one VulkanBackingAllocator.
pub const GpuMemory = struct {
    backing_allocator: core.VulkanBackingAllocator,
    gpu_only_gpa: std.heap.SafeAllocator = undefined,
    cpu_to_gpu_gpa: std.heap.SafeAllocator = undefined,

    pub fn init(self: *GpuMemory, io: std.Io, allocator: std.mem.Allocator, vk_ctx: *VulkanContext) !void {
        self.backing_allocator = core.VulkanBackingAllocator.init(
            vk_ctx.dev,
            vk_ctx.mem_props,
            io,
            allocator,
            vk_ctx.queue_family_index,
            vk_ctx.transfer_queue_family_index,
            vk_ctx.vkalloc,
        );
        errdefer self.backing_allocator.deinit();

        self.gpu_only_gpa = .init(self.backing_allocator.allocator(.gpu_only), .{});
        errdefer _ = self.gpu_only_gpa.deinit();

        self.cpu_to_gpu_gpa = .init(self.backing_allocator.allocator(.cpu_to_gpu), .{});
        errdefer _ = self.cpu_to_gpu_gpa.deinit();
    }

    pub fn deinit(self: *GpuMemory) void {
        _ = self.gpu_only_gpa.deinit();
        _ = self.cpu_to_gpu_gpa.deinit();
        self.backing_allocator.deinit();
    }

    pub fn gpuOnly(self: *GpuMemory) std.mem.Allocator {
        return self.gpu_only_gpa.allocator();
    }

    pub fn cpuToGpu(self: *GpuMemory) std.mem.Allocator {
        return self.cpu_to_gpu_gpa.allocator();
    }
};

pub const max_batch = 512;

/// Vulkan's guaranteed minimum for `maxDrawIndirectCount`, used when the driver reports 0.
const fallback_max_draw_indirect_count: u32 = 65_535;

/// Upper bound on the transfer back-pressure waits. These waits are satisfied by
/// already-submitted GPU work in normal operation; a timeout means the GPU is
/// stalled and must be reported instead of hanging silently.
pub const transfer_wait_timeout_ns: u64 = 5 * std.time.ns_per_s;

/// Byte stride of one face in the shared vertex/instance buffer. Each face is a single
/// instanced uvec2 consumed by the concrete renderer's vertex shader.
pub const face_stride: u32 = 8;

pub const MeshBuffer = struct {
    face_offset: u32,
    face_byte_count: vk.DeviceSize,
    face_count: u32,
    gpu_index: u32,
};

pub const UploadResult = struct {
    mesh: MeshBuffer,
    staging_slice: []u8,
    /// Max graphics value the face regions in this upload depend on (0 if none).
    safe_graphics: u64,
};

const RetiredFaceBuffer = struct {
    slice: []align(256) u8,
    graphics_timeline_value: u64,
};

/// Waits for a timeline semaphore to reach `value`, or times out. Returns the raw
/// Vulkan wait result so callers can distinguish completion from a stall.
fn waitTimelineValue(dev: DeviceProxy, semaphore: vk.Semaphore, value: u64, timeout: u64) !vk.Result {
    return dev.waitSemaphores(&.{
        .semaphore_count = 1,
        .p_semaphores = (&semaphore)[0..1],
        .p_values = (&value)[0..1],
    }, timeout);
}

/// Async transfer-queue upload pipeline for instanced geometry. Owns the staging ring,
/// the shared GPU face buffer, the command pool reservoir, and the transfer submission
/// machinery (timeline semaphores, queue mutex, growth of the face buffer).
pub const MeshUploader = struct {
    vk_ctx: *VulkanContext,
    allocator: std.mem.Allocator,
    dev: DeviceProxy,
    memory: *GpuMemory,
    single_time: *core.SingleTime,

    staging_ring: StagingRing,
    region_allocator: GpuRegionAllocator,
    pool_reservoir: CommandPoolReservoir = .{},
    retired_face_buffers: std.ArrayList(RetiredFaceBuffer) = .empty,
    retired_face_buffers_mutex: std.Io.Mutex = .init,

    /// Serializes the resource acquisition phase of an upload. Every holder of a
    /// pool, staging slice, or region outside this section is a fully provisioned
    /// upload on a bounded path to submission, so the flush-and-wait loops inside
    /// always wait on GPU progress and never on another blocked acquirer.
    admission_mutex: std.Io.Mutex = .init,

    flush_ctx: *anyopaque = undefined,
    flush_fn: ?*const fn (*anyopaque, std.Io) anyerror!void = null,
    /// Monotonic ns of the last transfer-stall log, to throttle repeated warnings.
    last_transfer_stall_log: std.atomic.Value(u64) = .init(0),

    pub fn init(
        allocator: std.mem.Allocator,
        vk_ctx: *VulkanContext,
        memory: *GpuMemory,
        single_time: *core.SingleTime,
        initial_face_bytes: vk.DeviceSize,
        initial_staging_bytes: vk.DeviceSize,
    ) !MeshUploader {
        var self: MeshUploader = .{
            .vk_ctx = vk_ctx,
            .allocator = allocator,
            .dev = vk_ctx.dev,
            .memory = memory,
            .single_time = single_time,
            .staging_ring = undefined,
            .region_allocator = undefined,
        };

        const face_slice = try memory.gpuOnly().alignedAlloc(u8, buf_align, initial_face_bytes);
        const face_buf_info = memory.backing_allocator.getBufferAndOffset(.gpu_only, face_slice.ptr);
        self.region_allocator = .init(allocator, face_slice, face_buf_info.buffer, face_buf_info.offset);
        errdefer self.region_allocator.deinit(memory.gpuOnly());

        self.staging_ring = try StagingRing.init(allocator, memory.cpuToGpu(), initial_staging_bytes);
        errdefer self.staging_ring.deinit(memory.cpuToGpu());

        try self.pool_reservoir.init(self.dev, vk_ctx.transfer_queue_family_index, &vk_ctx.vkalloc);
        return self;
    }

    pub fn deinit(self: *MeshUploader) void {
        for (self.retired_face_buffers.items) |entry| self.memory.gpuOnly().free(entry.slice);
        self.retired_face_buffers.deinit(self.allocator);

        self.pool_reservoir.deinit(self.dev, &self.vk_ctx.vkalloc);
        self.staging_ring.deinit(self.memory.cpuToGpu());
        self.region_allocator.deinit(self.memory.gpuOnly());
    }

    /// The renderer registers a callback that flushes its submission batch and retires
    /// completed uploads; the uploader calls it when it must make progress to free
    /// staging space, pools, or face buffer regions.
    pub fn setFlush(self: *MeshUploader, ctx: *anyopaque, flush_fn: *const fn (*anyopaque, std.Io) anyerror!void) void {
        self.flush_ctx = ctx;
        self.flush_fn = flush_fn;
    }

    fn flush(self: *MeshUploader, io: std.Io) !void {
        if (self.flush_fn) |flush_callback| try flush_callback(self.flush_ctx, io);
    }

    /// Everything an upload needs, acquired all-or-nothing by reserveUpload. Slot 0
    /// is the opaque mesh, slot 1 the transparent mesh; a zero-size slot holds null.
    pub const UploadReservation = struct {
        borrowed: CommandPoolReservoir.Borrowed,
        staging: [2]?[]u8,
        regions: [2]?GpuRegionAllocator.AllocResult,
        sizes: [2]vk.DeviceSize,
    };

    pub fn reserveUpload(self: *MeshUploader, io: std.Io, sizes: [2]vk.DeviceSize) !UploadReservation {
        self.admission_mutex.lockUncancelable(io);
        defer self.admission_mutex.unlock(io);

        const borrowed = try self.borrowPool(io);
        errdefer self.returnPool(borrowed.pool);

        const staging = try self.allocStagingPair(io, sizes);
        errdefer self.cancelStagingSlices(io, staging);

        var regions: [2]?GpuRegionAllocator.AllocResult = .{ null, null };
        errdefer self.freeReservedRegions(io, regions, sizes);
        for (sizes, &regions) |size, *slot| {
            if (size > 0) slot.* = try self.allocRegion(io, size);
        }

        return .{ .borrowed = borrowed, .staging = staging, .regions = regions, .sizes = sizes };
    }

    /// Releases a reservation whose upload never reached submission.
    pub fn cancelReservation(self: *MeshUploader, io: std.Io, reservation: UploadReservation) void {
        self.cancelStagingSlices(io, reservation.staging);
        self.freeReservedRegions(io, reservation.regions, reservation.sizes);
        self.returnPool(reservation.borrowed.pool);
    }

    /// Cancels in reverse order so the tail entry retracts the ring head first,
    /// letting the earlier entry become the tail and retract it further.
    fn cancelStagingSlices(self: *MeshUploader, io: std.Io, staging: [2]?[]u8) void {
        var reverse_index: usize = staging.len;
        while (reverse_index > 0) {
            reverse_index -= 1;
            if (staging[reverse_index]) |slice| self.staging_ring.cancel(io, slice);
        }
    }

    fn freeReservedRegions(self: *MeshUploader, io: std.Io, regions: [2]?GpuRegionAllocator.AllocResult, sizes: [2]vk.DeviceSize) void {
        const graphics_val = self.vk_ctx.frame_number.load(.acquire);
        for (regions, sizes) |region, size| {
            if (region) |res| self.region_allocator.freeRegion(io, res.offset, size, graphics_val);
        }
    }

    fn borrowPool(self: *MeshUploader, io: std.Io) !CommandPoolReservoir.Borrowed {
        while (true) {
            if (self.pool_reservoir.tryBorrowPool()) |borrowed_pool| return borrowed_pool;
            try self.flush(io);
            // Every pool is held by an upload whose transfer batch is still on the
            // GPU, so blocking on the transfer timeline is bounded and frees pools
            // as the uploads holding them retire.
            try self.waitForTransferCompletion(io);
        }
    }

    pub fn returnPool(self: *MeshUploader, pool: vk.CommandPool) void {
        self.pool_reservoir.returnPool(self.dev, pool);
    }

    /// Blocks until the transfer queue completes at least one more batch than it has
    /// now, or returns immediately when nothing is in flight. This is a non-cancelable
    /// Vulkan wait; callers must check `io.checkCancel()` first, and the timeout-and-retry
    /// loop logs instead of hanging silently on a stalled GPU.
    fn waitForTransferCompletion(self: *MeshUploader, io: std.Io) !void {
        try io.checkCancel();
        const last_submitted = self.vk_ctx.transfer_semaphore_value.load(.monotonic);
        const completed = try self.dev.getSemaphoreCounterValue(self.vk_ctx.transfer_semaphore);
        if (completed >= last_submitted) return;
        const wait_value = completed + 1;
        const result = try waitTimelineValue(self.dev, self.vk_ctx.transfer_semaphore, wait_value, transfer_wait_timeout_ns);
        if (result != .success) self.logTransferStall(io, wait_value, completed, last_submitted);
    }

    /// Logs a stalled transfer wait at most once per second. The counter did not
    /// advance within the timeout, meaning a batch the GPU should complete is stuck.
    fn logTransferStall(self: *MeshUploader, io: std.Io, wait_value: u64, completed: u64, last_submitted: u64) void {
        const now_ns: u64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
        const last_log = self.last_transfer_stall_log.load(.monotonic);
        if (now_ns -| last_log < std.time.ns_per_s) return;
        self.last_transfer_stall_log.store(now_ns, .monotonic);
        std.log.warn("MeshUploader: transfer queue stalled {d}s waiting for value {d} (counter {d}, submitted {d}); GPU may be stuck", .{
            transfer_wait_timeout_ns / std.time.ns_per_s,
            wait_value,
            completed,
            last_submitted,
        });
    }

    fn allocStagingPair(self: *MeshUploader, io: std.Io, sizes: [2]vk.DeviceSize) ![2]?[]u8 {
        while (true) {
            if (try self.staging_ring.allocPair(io, sizes)) |slices| return slices;
            try self.flush(io);
            // A full ring owns staging that only the GPU can release; wait for the
            // next transfer completion instead of busy-spinning.
            try self.waitForTransferCompletion(io);
        }
    }

    pub fn cancelStaging(self: *MeshUploader, io: std.Io, slice: []u8) void {
        self.staging_ring.cancel(io, slice);
    }

    pub fn bindStaging(self: *MeshUploader, io: std.Io, slice: []u8, timeline_value: u64) void {
        self.staging_ring.bind(io, slice, timeline_value);
    }

    /// True when transfer and graphics queues share a physical queue family; their
    /// submits then share the graphics queue mutex.
    fn sharedQueue(self: *const MeshUploader) bool {
        return self.vk_ctx.transfer_queue_family_index == self.vk_ctx.queue_family_index;
    }

    /// The mutex guarding transfer-queue submits. On a distinct transfer family it is
    /// the dedicated transfer mutex so submits do not queue behind graphics/present;
    /// on a shared family the queue mutex must serialize both queues' vkQueueSubmit.
    fn transferLock(self: *MeshUploader) *std.Io.Mutex {
        return if (self.sharedQueue()) &self.vk_ctx.queue_mutex else &self.vk_ctx.transfer_queue_mutex;
    }

    fn allocRegion(self: *MeshUploader, io: std.Io, buffer_size: vk.DeviceSize) !GpuRegionAllocator.AllocResult {
        while (true) {
            if (self.region_allocator.allocRegion(io, buffer_size)) |result| return result;

            try self.flush(io);

            // Allocating device memory can take hundreds of milliseconds, so it happens
            // before the queue locks the frame thread needs. Runs after the locks release.
            const new_slice = try self.memory.gpuOnly().alignedAlloc(u8, buf_align, try self.region_allocator.nextCapacity(io));
            var unused_slice: ?@TypeOf(new_slice) = new_slice;
            defer if (unused_slice) |slice| self.memory.gpuOnly().free(slice);

            // Drain the GPU before swapping the buffer, without holding the queue mutex
            // (the render thread needs it to advance the graphics timeline). Concurrent
            // growers may both drain; the retry after locking makes the double-drain benign.
            try self.vk_ctx.waitSubmittedFrames();

            const transfer_done_val = self.vk_ctx.transfer_semaphore_value.load(.acquire);
            if (transfer_done_val > 0) _ = try waitTimelineValue(self.dev, self.vk_ctx.transfer_semaphore, transfer_done_val, std.math.maxInt(u64));

            // Exclude concurrent transfer submits across the buffer swap and copy: a
            // submit referencing the old buffer must not race the graphics-side copy.
            // Lock order is always transfer then graphics, so no path can deadlock.
            const exclusive_transfer = !self.sharedQueue();
            if (exclusive_transfer) self.vk_ctx.transfer_queue_mutex.lockUncancelable(io);
            defer if (exclusive_transfer) self.vk_ctx.transfer_queue_mutex.unlock(io);

            self.vk_ctx.queue_mutex.lockUncancelable(io);
            defer self.vk_ctx.queue_mutex.unlock(io);

            // Another thread may have grown the buffer while we drained; retry first.
            if (self.region_allocator.allocRegion(io, buffer_size)) |result| return result;

            std.log.info("growing face data buffer...", .{});
            const face_buf_info = self.memory.backing_allocator.getBufferAndOffset(.gpu_only, new_slice.ptr);
            const grow_info = self.region_allocator.grow(io, new_slice, face_buf_info.buffer, face_buf_info.offset) orelse continue;
            unused_slice = null;

            const cmd = try self.single_time.begin();
            self.dev.cmdCopyBuffer2(cmd, &.{
                .src_buffer = grow_info.old_buffer,
                .dst_buffer = face_buf_info.buffer,
                .region_count = 1,
                .p_regions = (&vk.BufferCopy2{
                    .src_offset = grow_info.old_buffer_offset,
                    .dst_offset = face_buf_info.offset,
                    .size = grow_info.old_used,
                })[0..1],
            });

            self.single_time.endLocked(cmd) catch {
                @panic("MeshUploader.allocRegion: GPU command submission or wait failed - cannot safely continue");
            };

            self.retired_face_buffers_mutex.lockUncancelable(io);
            defer self.retired_face_buffers_mutex.unlock(io);
            self.retired_face_buffers.append(self.allocator, .{
                .slice = grow_info.old_slice,
                .graphics_timeline_value = self.vk_ctx.frame_number.load(.acquire) + VulkanContext.max_frames_in_flight,
            }) catch |err| {
                // The copy above completed, but a frame recorded before the swap may still bind the
                // old buffer; freeing it now would be a use-after-free, so leak it instead.
                std.log.err("MeshUploader.allocRegion: failed to queue old face buffer for retirement ({any}); leaking it", .{err});
            };

            std.log.info("face data buffer grown", .{});
        }
    }

    pub fn freeMesh(self: *MeshUploader, io: std.Io, mesh: MeshBuffer, current_graphics_val: u64) void {
        self.region_allocator.freeRegion(io, @as(vk.DeviceSize, @intCast(mesh.face_offset)) * face_stride, mesh.face_byte_count, current_graphics_val);
    }

    /// Submits command buffers on the transfer queue, gated by the graphics timeline
    /// only as far as the batch's reused face regions require, and signals the
    /// transfer timeline. Returns the new transfer value.
    pub fn submitToTransferQueue(self: *MeshUploader, io: std.Io, cmds: []const vk.CommandBuffer, wait_graphics_value: u64) !u64 {
        const count = cmds.len;
        if (count == 0) return self.vk_ctx.transfer_semaphore_value.load(.monotonic);
        std.debug.assert(count <= max_batch);

        const zone_queue = tracy.Zone.begin(.{ .src = @src(), .name = "submitToTransferQueue_lock" });
        const lock = self.transferLock();
        lock.lockUncancelable(io);
        zone_queue.end();
        defer lock.unlock(io);

        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "submitToTransferQueue" });
        defer zone.end();

        // Commit the counter only after the submit succeeds: a failed submit must
        // not claim a value the GPU never signals, or every later wait on it
        // (frames, drains, worker back-pressure) would block forever.
        const next_val = self.vk_ctx.transfer_semaphore_value.load(.monotonic) + 1;

        var cb_submit_infos: [max_batch]vk.CommandBufferSubmitInfo = undefined;
        for (cb_submit_infos[0..count], cmds) |*info, cmd| info.* = .{ .command_buffer = cmd, .device_mask = 0 };

        const submit_info: vk.SubmitInfo2 = .{
            .flags = .{},
            .wait_semaphore_info_count = 1,
            .p_wait_semaphore_infos = (&vk.SemaphoreSubmitInfo{
                .semaphore = self.vk_ctx.graphics_timeline_semaphore,
                .value = wait_graphics_value,
                .stage_mask = .{ .all_transfer = true },
                .device_index = 0,
            })[0..1],
            .command_buffer_info_count = @intCast(count),
            .p_command_buffer_infos = cb_submit_infos[0..count].ptr,
            .signal_semaphore_info_count = 1,
            .p_signal_semaphore_infos = (&vk.SemaphoreSubmitInfo{
                .semaphore = self.vk_ctx.transfer_semaphore,
                .value = next_val,
                .stage_mask = .{ .all_transfer = true },
                .device_index = 0,
            })[0..1],
        };

        try self.dev.queueSubmit2(self.vk_ctx.transfer_queue, (&submit_info)[0..1], .null_handle);
        self.vk_ctx.transfer_semaphore_value.store(next_val, .monotonic);

        return next_val;
    }

    pub fn retireStaging(self: *MeshUploader, io: std.Io, current_transfer_val: u64) void {
        self.staging_ring.retire(io, current_transfer_val);
    }

    pub fn processRetiredFaceBuffers(self: *MeshUploader, io: std.Io, current_graphics_val: u64) void {
        // A dedicated lock, not the queue mutex: freeing a retired buffer is slow
        // and must not stall frame submission.
        self.retired_face_buffers_mutex.lockUncancelable(io);
        defer self.retired_face_buffers_mutex.unlock(io);
        // Scans from the tail so `swapRemove` never revisits a moved element.
        const items = &self.retired_face_buffers;
        var i: usize = items.items.len;
        while (i > 0) {
            i -= 1;
            const entry = items.items[i];
            if (current_graphics_val >= entry.graphics_timeline_value) {
                self.memory.gpuOnly().free(entry.slice);
                _ = items.swapRemove(i);
            }
        }
    }

    /// The frame thread snapshots this once per frame so every barrier and bind of the
    /// frame agrees on the face buffer, even if a concurrent grow swaps it mid-frame.
    pub fn faceBinding(self: *MeshUploader) GpuRegionAllocator.Binding {
        return self.region_allocator.binding();
    }

    fn faceBufferBarrier(
        self: *MeshUploader,
        cmd_buffer: vk.CommandBuffer,
        binding: GpuRegionAllocator.Binding,
        src_stage: vk.PipelineStageFlags2,
        src_access: vk.AccessFlags2,
        dst_stage: vk.PipelineStageFlags2,
        dst_access: vk.AccessFlags2,
    ) void {
        if (binding.used == 0) return;
        core.pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, (&core.makeBufferBarrier2(
            binding.buffer,
            binding.offset,
            binding.used,
            src_stage,
            src_access,
            dst_stage,
            dst_access,
        ))[0..1]);
    }

    /// Acquire side of the cross-queue memory dependency: makes the upload batch's
    /// transfer writes to the face buffer visible to this frame's vertex reads.
    pub fn cmdAcquireFaceBuffer(self: *MeshUploader, cmd_buffer: vk.CommandBuffer, binding: GpuRegionAllocator.Binding) void {
        self.faceBufferBarrier(cmd_buffer, binding, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .vertex_attribute_input = true }, .{ .vertex_attribute_read = true });
    }

    /// Release side: makes this frame's vertex reads available before the next upload
    /// batch writes the same regions on the transfer queue.
    pub fn cmdReleaseFaceBuffer(self: *MeshUploader, cmd_buffer: vk.CommandBuffer, binding: GpuRegionAllocator.Binding) void {
        self.faceBufferBarrier(cmd_buffer, binding, .{ .vertex_attribute_input = true }, .{ .vertex_attribute_read = true }, .{ .all_transfer = true }, .{});
    }

    const face_vertex_binding: vk.VertexInputBindingDescription = .{ .binding = 0, .stride = face_stride, .input_rate = .instance };
    const face_vertex_attribute: vk.VertexInputAttributeDescription = .{ .location = 0, .binding = 0, .format = .r32g32_uint, .offset = 0 };

    pub fn faceVertexInputState() vk.PipelineVertexInputStateCreateInfo {
        return .{
            .flags = .{},
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = (&face_vertex_binding)[0..1],
            .vertex_attribute_description_count = 1,
            .p_vertex_attribute_descriptions = (&face_vertex_attribute)[0..1],
        };
    }
};

pub const MeshCandidate = extern struct {
    absolute_position: [4]f32 align(@sizeOf([4]f32)),
    face_offset: u32,
    scale: f32,
    face_count: u32,
    is_transparent: u32,

    /// The all-zero candidate draws nothing (face_count == 0 gates the cull shader).
    pub fn zeroed() MeshCandidate {
        return .{ .absolute_position = @splat(0), .face_offset = 0, .scale = 0, .face_count = 0, .is_transparent = 0 };
    }
};

comptime {
    if (@sizeOf(MeshCandidate) != 32) @compileError("MeshCandidate size mismatch with GLSL layout (expected 32, got " ++ std.fmt.comptimePrint("{d}", .{@sizeOf(MeshCandidate)}) ++ ")");
}

/// Per-cascade shadow cull slots. The shadow raster draws up to `cascades_per_frame`
/// cascades per frame, each culling and drawing its own box into a dedicated slot; this
/// is the fixed upper bound on those slots so the buffers can size every frame's
/// indirect/mesh regions at allocation time.
pub const shadow_slot_count: u32 = 8;

pub const CullCount = extern struct {
    opaque_count: u32,
    opaque_late_count: u32,
    transparent_count: u32,
    opaque_face_count: u32,
    opaque_late_face_count: u32,
    transparent_face_count: u32,
    /// Meshes culled by the Hi-Z occlusion test (stats only).
    occluded_count: u32,
    /// Meshes outside the main-view frustum, counted by the early cull (stats only).
    frustum_culled_count: u32,
    shadow_count: [shadow_slot_count]u32,
    shadow_face_count: [shadow_slot_count]u32,
    /// Player-relative opaque-scene AABB, per-axis ordered-uint encoded f32 minimum.
    /// Reduced by the early cull dispatch; decoded on the render thread.
    aabb_min_ord: [3]u32,
    /// Player-relative opaque-scene AABB, per-axis ordered-uint encoded f32 maximum.
    aabb_max_ord: [3]u32,

    pub fn zeroed() CullCount {
        return .{
            .opaque_count = 0,
            .opaque_late_count = 0,
            .transparent_count = 0,
            .opaque_face_count = 0,
            .opaque_late_face_count = 0,
            .transparent_face_count = 0,
            .occluded_count = 0,
            .frustum_culled_count = 0,
            .shadow_count = @splat(0),
            .shadow_face_count = @splat(0),
            .aabb_min_ord = @splat(0),
            .aabb_max_ord = @splat(0),
        };
    }
};

comptime {
    if (@sizeOf(CullCount) != 120) @compileError("CullCount size mismatch");
}

/// Encodes a float as a u32 whose unsigned ordering matches the float's value ordering,
/// so `atomicMin`/`atomicMax` on the encoded form reduce the true float min/max.
/// -inf encodes to the smallest u32; +inf to the largest.
fn orderedEncode(f: f32) u32 {
    const u: u32 = @bitCast(f);
    return if (u & 0x8000_0000 != 0) ~u else u | 0x8000_0000;
}

/// Inverse of `orderedEncode`.
fn orderedDecode(o: u32) f32 {
    return if (o & 0x8000_0000 != 0) @bitCast(o & 0x7FFF_FFFF) else @bitCast(~o);
}

/// Ordered-uint encoding of +inf; the initial value for a min reduction.
pub const aabb_min_inf_ord: u32 = 0xFF80_0000;
/// Ordered-uint encoding of -inf; the initial value for a max reduction.
pub const aabb_max_inf_ord: u32 = 0x007F_FFFF;

pub const MeshData = extern struct {
    absolute_position: [4]f32 align(@sizeOf([4]f32)),
    relative_position: [4]f32 align(@sizeOf([4]f32)),
    scale: f32,
};

comptime {
    if (@sizeOf(MeshData) != 48) @compileError("MeshData size mismatch with GLSL layout (expected 48)");
}

pub const CandidateTransform = struct {
    absolute_position: [4]f32,
    scale: f32,
};

pub const cull_buffer_alignment: std.mem.Alignment = .fromByteUnits(256);
/// Main-pass draw slots (opaque early + opaque late + transparent).
pub const draw_type_count = 3;
/// Opaque meshes that were visible last frame, drawn before the Hi-Z pyramid builds.
pub const opaque_early_slot: u32 = 0;
/// Opaque meshes the early pass missed (newly disoccluded), drawn after the late cull.
pub const opaque_late_slot: u32 = 1;
pub const transparent_slot: u32 = 2;
/// Total indirect slots per frame: the main passes plus one shadow slot per cascade
/// that may be rasterized in a frame. Buffers and the cull dispatch must size everything
/// by this, not by `draw_type_count`.
pub const slot_count: u32 = draw_type_count + shadow_slot_count;
/// The first shadow draw's slot offset, in draw units.
pub const shadow_slot_base: u32 = draw_type_count;

const PersistentCandidates = struct {
    buffer: vk.Buffer = .null_handle,
    offset: vk.DeviceSize = 0,
    slice: []MeshCandidate = &.{},
};

const FrameSlices = struct {
    mesh_data: []MeshData = &.{},
    indirect_draw: []vk.DrawIndirectCommand = &.{},
    count: []align(cull_buffer_alignment.toByteUnits()) CullCount = &.{},
    stats: []align(cull_buffer_alignment.toByteUnits()) CullCount = &.{},

    fn free(self: FrameSlices, memory: *GpuMemory) void {
        memory.cpuToGpu().free(self.mesh_data);
        memory.cpuToGpu().free(self.indirect_draw);
        memory.gpuOnly().free(self.count);
        memory.cpuToGpu().free(self.stats);
    }
};

const PerFrameData = struct {
    slices: FrameSlices = .{},
    indirect_draw: vk.Buffer = .null_handle,
    indirect_draw_offset: vk.DeviceSize = 0,
    mesh_data: vk.Buffer = .null_handle,
    mesh_data_offset: vk.DeviceSize = 0,
    count: vk.Buffer = .null_handle,
    count_offset: vk.DeviceSize = 0,
    stats: vk.Buffer = .null_handle,
    stats_offset: vk.DeviceSize = 0,
    /// Player position pushed to the cull shader that wrote this slot's stats buffer.
    /// `getSceneAABB` adds it back to the player-relative reduction result.
    last_cull_player_pos: @Vector(3, f64) = @splat(0),
};

/// GPU-driven indirect-draw scene: persistent candidate slots, per-frame indirect/
/// mesh-data/count/stats buffers, and the frustum culling dispatch that fills them.
/// Only the frame thread touches it, between beginFrame and the first recorded cull.
pub const IndirectScene = struct {
    vk_ctx: *VulkanContext,
    allocator: std.mem.Allocator,
    dev: DeviceProxy,
    memory: *GpuMemory,

    persistent: PersistentCandidates = .{},
    index_pool: IndexPool = undefined,
    /// One past the highest slot that may hold a live candidate.
    max_allocated_index: u32 = 0,
    frame_buffers: []PerFrameData = &.{},
    /// Bumped whenever the candidate buffer or per-frame buffers are reallocated;
    /// consumers that bind these buffers (e.g. the cull dispatch) re-bind on change.
    buffers_version: u32 = 0,

    draw_capacity: u32,

    /// One u32 per candidate slot: nonzero when the mesh passed last frame's late cull.
    /// Written by the late cull, read by the early cull; wrong bits only cost perf
    /// (a mesh drawn one pass later or one frame earlier), never correctness.
    visibility_buffer: vk.Buffer = .null_handle,
    visibility_offset: vk.DeviceSize = 0,
    visibility_slice: []align(cull_buffer_alignment.toByteUnits()) u32 = &.{},
    /// True when the visibility buffer holds garbage (fresh or regrown); the next
    /// recorded frame zero-fills it before the early cull reads it.
    visibility_needs_clear: bool = true,

    mesh_data_descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    mesh_data_descriptor_pool: vk.DescriptorPool = .null_handle,
    mesh_data_descriptor_sets_per_frame: []vk.DescriptorSet = &.{},

    pub fn init(self: *IndirectScene, allocator: std.mem.Allocator, vk_ctx: *VulkanContext, memory: *GpuMemory, initial_candidates: u32, initial_draw_capacity: u32) !void {
        self.* = .{
            .vk_ctx = vk_ctx,
            .allocator = allocator,
            .dev = vk_ctx.dev,
            .memory = memory,
            .draw_capacity = initial_draw_capacity,
        };

        const persistent_candidates_slice = try memory.cpuToGpu().alloc(MeshCandidate, initial_candidates);
        errdefer memory.cpuToGpu().free(persistent_candidates_slice);
        @memset(persistent_candidates_slice, MeshCandidate.zeroed());
        const cand_info = memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, persistent_candidates_slice.ptr);
        self.persistent.buffer = cand_info.buffer;
        self.persistent.offset = cand_info.offset;
        self.persistent.slice = persistent_candidates_slice;

        const visibility_slice = try memory.gpuOnly().alignedAlloc(u32, cull_buffer_alignment, initial_candidates);
        errdefer memory.gpuOnly().free(visibility_slice);
        const vis_info = memory.backing_allocator.getBufferAndOffset(.gpu_only, visibility_slice.ptr);
        self.visibility_buffer = vis_info.buffer;
        self.visibility_offset = vis_info.offset;
        self.visibility_slice = visibility_slice;

        self.index_pool = try IndexPool.init(allocator, initial_candidates);
        errdefer self.index_pool.deinit(allocator);

        self.frame_buffers = try allocator.alloc(PerFrameData, VulkanContext.max_frames_in_flight);
        @memset(self.frame_buffers, .{});
        errdefer self.freeFrameBuffers();
        for (self.frame_buffers) |*frame| self.fillFrameData(frame, try self.allocFrameSlices(self.draw_capacity));

        try self.createMeshDataDescriptorResources();
        errdefer self.destroyMeshDataDescriptorResources();
    }

    fn freeFrameBuffers(self: *IndirectScene) void {
        for (self.frame_buffers) |frame| frame.slices.free(self.memory);
        self.allocator.free(self.frame_buffers);
    }

    pub fn deinit(self: *IndirectScene) void {
        self.freeFrameBuffers();

        self.destroyMeshDataDescriptorResources();
        core.destroyIfValid(self.dev, &self.mesh_data_descriptor_set_layout, &self.vk_ctx.vkalloc);

        self.index_pool.deinit(self.allocator);
        self.memory.gpuOnly().free(self.visibility_slice);
        self.memory.cpuToGpu().free(self.persistent.slice);
    }

    pub fn allocIndex(self: *IndirectScene) !u32 {
        const index = while (true) {
            if (self.index_pool.allocIndex()) |idx| break idx;
            try self.growPersistentCandidates();
        };
        self.max_allocated_index = @max(self.max_allocated_index, index + 1);
        return index;
    }

    pub fn writeCandidate(self: *IndirectScene, gpu_index: u32, mesh: MeshBuffer, is_transparent: bool, transform: CandidateTransform) void {
        self.persistent.slice[gpu_index] = .{
            .absolute_position = transform.absolute_position,
            .scale = transform.scale,
            .face_count = mesh.face_count,
            .is_transparent = if (is_transparent) 1 else 0,
            .face_offset = mesh.face_offset,
        };
    }

    /// Deactivates a slot without freeing its index (retirement happens later).
    pub fn markInactive(self: *IndirectScene, gpu_index: u32) void {
        self.persistent.slice[gpu_index].face_count = 0;
    }

    pub fn releaseCandidate(self: *IndirectScene, gpu_index: u32) void {
        self.persistent.slice[gpu_index].face_count = 0;
        self.index_pool.freeIndex(gpu_index);
        self.tryShrinkMaxAllocatedIndex(gpu_index);
    }

    /// World-space AABB of live opaque candidates, in absolute blocks. Read from the
    /// cull shader's per-frame player-relative reduction; the CPU never scans the
    /// candidate buffer. Transparent candidates are excluded (the shadow cull skips
    /// them). The value lags one frame: the CPU needs it before this frame's cull runs,
    /// so it reflects the last dispatch that wrote this frame slot's stats buffer.
    pub fn getSceneAABB(self: *IndirectScene, current_frame: u32) struct { min: [3]f64, max: [3]f64 } {
        const frame = &self.frame_buffers[current_frame];
        const stats = frame.slices.stats[0];
        const pos = frame.last_cull_player_pos;
        const pos_arr: [3]f64 = @bitCast(pos);
        var min: [3]f64 = undefined;
        var max: [3]f64 = undefined;
        for (&min, &max, pos_arr, stats.aabb_min_ord, stats.aabb_max_ord) |*min_value, *max_value, position, min_ord, max_ord| {
            min_value.* = position + @as(f64, orderedDecode(min_ord));
            max_value.* = position + @as(f64, orderedDecode(max_ord));
        }
        // Untouched sentinels (no opaque candidates) decode to min=+inf/max=-inf, and a
        // never-dispatched frame slot reads zeroes that decode to NaN. Both violate
        // min <= max; fall back to a degenerate box rather than poisoning the shadow fit.
        if (!(min[0] <= max[0])) return .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } };
        return .{ .min = min, .max = max };
    }

    pub fn ensureCapacity(self: *IndirectScene, total_candidates: u32) !void {
        if (total_candidates > self.draw_capacity) try self.growDrawCapacity(total_candidates);
    }

    fn fillFrameData(self: *IndirectScene, frame: *PerFrameData, slices: FrameSlices) void {
        slices.stats[0] = CullCount.zeroed();

        const mesh_data_info = self.memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, slices.mesh_data.ptr);
        const indirect_draw_info = self.memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, slices.indirect_draw.ptr);
        const count_info = self.memory.backing_allocator.getBufferAndOffset(.gpu_only, slices.count.ptr);
        const stats_info = self.memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, slices.stats.ptr);

        frame.* = .{
            .slices = slices,
            .mesh_data = mesh_data_info.buffer,
            .mesh_data_offset = mesh_data_info.offset,
            .indirect_draw = indirect_draw_info.buffer,
            .indirect_draw_offset = indirect_draw_info.offset,
            .count = count_info.buffer,
            .count_offset = count_info.offset,
            .stats = stats_info.buffer,
            .stats_offset = stats_info.offset,
        };
    }

    fn allocFrameSlices(self: *IndirectScene, capacity: u32) !FrameSlices {
        const mesh_data = try self.memory.cpuToGpu().alloc(MeshData, capacity * slot_count);
        errdefer self.memory.cpuToGpu().free(mesh_data);
        const indirect_draw = try self.memory.cpuToGpu().alloc(vk.DrawIndirectCommand, capacity * slot_count);
        errdefer self.memory.cpuToGpu().free(indirect_draw);
        const count = try self.memory.gpuOnly().alignedAlloc(CullCount, cull_buffer_alignment, 1);
        errdefer self.memory.gpuOnly().free(count);
        const stats = try self.memory.cpuToGpu().alignedAlloc(CullCount, cull_buffer_alignment, 1);
        return .{ .mesh_data = mesh_data, .indirect_draw = indirect_draw, .count = count, .stats = stats };
    }

    /// Doubles the draw capacity until it covers `min_capacity`, failing when the device's
    /// indirect-draw limit cannot hold the result.
    fn nextDrawCapacity(self: *IndirectScene, min_capacity: u32) !u32 {
        var new_capacity = self.draw_capacity;
        while (new_capacity < min_capacity) {
            new_capacity = std.math.mul(u32, new_capacity, 2) catch return error.MaxDrawCapacityExceeded;
        }
        // TODO: handle scenes that outgrow the device's max indirect count instead of
        // panicking (e.g. splitting the draw into multiple dispatches).
        const device_max = self.vk_ctx.props.limits.max_draw_indirect_count;
        const max_count = if (device_max > 0) device_max else fallback_max_draw_indirect_count;
        if (new_capacity > max_count) {
            std.log.err("IndirectScene: draw capacity {d} exceeds device max indirect count {d}. Cannot continue rendering.", .{ new_capacity, max_count });
            return error.MaxDrawCapacityExceeded;
        }
        return new_capacity;
    }

    fn growDrawCapacity(self: *IndirectScene, min_capacity: u32) !void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "growDrawCapacity" });
        defer zone.end();

        if (min_capacity <= self.draw_capacity) return;

        const new_capacity = try self.nextDrawCapacity(min_capacity);
        std.log.info("IndirectScene: Growing draw capacity from {d} to {d} for all frames...", .{ self.draw_capacity, new_capacity });

        // Only submitted frames read the per-frame buffers and descriptor sets, so wait
        // for the graphics timeline instead of idling the device: that would also wait
        // out the transfer backlog while holding the queue locks uploads submit under.
        try self.vk_ctx.waitSubmittedFrames();

        const new_frames = try self.allocator.alloc(FrameSlices, self.frame_buffers.len);
        defer self.allocator.free(new_frames);

        var allocated_frames: usize = 0;
        errdefer for (new_frames[0..allocated_frames]) |slices| slices.free(self.memory);
        for (new_frames) |*dst| {
            dst.* = try self.allocFrameSlices(new_capacity);
            allocated_frames += 1;
        }

        for (self.frame_buffers, new_frames) |*frame, new_slices| {
            const old = frame.slices;
            @memcpy(new_slices.mesh_data[0..old.mesh_data.len], old.mesh_data);
            @memcpy(new_slices.indirect_draw[0..old.indirect_draw.len], old.indirect_draw);
            self.fillFrameData(frame, new_slices);
            old.free(self.memory);
        }

        self.draw_capacity = new_capacity;
        self.buffers_version += 1;

        for (0..self.frame_buffers.len) |i| self.updateMeshDataDescriptorSet(@intCast(i));
    }

    fn growPersistentCandidates(self: *IndirectScene) !void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "growPersistentCandidates" });
        defer zone.end();

        const old_slice = self.persistent.slice;
        const new_capacity = old_slice.len * 2;
        std.log.info("IndirectScene: Growing persistent GPU scene candidates from {d} to {d}...", .{ old_slice.len, new_capacity });

        // Only graphics frames read the candidate and visibility buffers, and growth runs on
        // the frame thread before it records, so the old buffers are unused once this returns.
        try self.vk_ctx.waitSubmittedFrames();

        const new_slice = try self.memory.cpuToGpu().alloc(MeshCandidate, new_capacity);
        errdefer self.memory.cpuToGpu().free(new_slice);
        const new_visibility = try self.memory.gpuOnly().alignedAlloc(u32, cull_buffer_alignment, new_capacity);
        errdefer self.memory.gpuOnly().free(new_visibility);
        try self.index_pool.grow(self.allocator, @intCast(new_capacity));

        @memset(new_slice, MeshCandidate.zeroed());
        @memcpy(new_slice[0..old_slice.len], old_slice);
        self.memory.cpuToGpu().free(old_slice);
        self.memory.gpuOnly().free(self.visibility_slice);

        const current_vis_info = self.memory.backing_allocator.getBufferAndOffset(.gpu_only, new_visibility.ptr);
        self.visibility_buffer = current_vis_info.buffer;
        self.visibility_offset = current_vis_info.offset;
        self.visibility_slice = new_visibility;
        self.visibility_needs_clear = true;

        const info = self.memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, new_slice.ptr);
        self.persistent.buffer = info.buffer;
        self.persistent.offset = info.offset;
        self.persistent.slice = new_slice;

        self.buffers_version += 1;
    }

    fn tryShrinkMaxAllocatedIndex(self: *IndirectScene, freed_gpu_index: u32) void {
        if (freed_gpu_index + 1 < self.max_allocated_index) return;

        var new_max: u32 = freed_gpu_index;
        while (new_max > 0) : (new_max -= 1) {
            if (self.persistent.slice[new_max - 1].face_count != 0) break;
        }

        self.max_allocated_index = new_max;
    }

    fn createMeshDataDescriptorResources(self: *IndirectScene) !void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "createMeshDataDescriptorResources" });
        defer zone.end();
        if (self.mesh_data_descriptor_set_layout == .null_handle) {
            const binding = vk.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .vertex = true }, .p_immutable_samplers = null };
            self.mesh_data_descriptor_set_layout = try core.createDescriptorSetLayout(self.dev, &self.vk_ctx.vkalloc, .{}, (&binding)[0..1]);
        }

        const pool_size = vk.DescriptorPoolSize{ .type = .storage_buffer, .descriptor_count = @intCast(VulkanContext.max_frames_in_flight) };
        try core.createFrameDescriptorPool(self.dev, self.allocator, &self.vk_ctx.vkalloc, &self.mesh_data_descriptor_pool, self.mesh_data_descriptor_set_layout, &self.mesh_data_descriptor_sets_per_frame, (&pool_size)[0..1]);

        for (0..VulkanContext.max_frames_in_flight) |i| self.updateMeshDataDescriptorSet(@intCast(i));
    }

    fn updateMeshDataDescriptorSet(self: *IndirectScene, frame_idx: u32) void {
        const info: vk.DescriptorBufferInfo = .{
            .buffer = self.frame_buffers[frame_idx].mesh_data,
            .offset = self.frame_buffers[frame_idx].mesh_data_offset,
            .range = self.draw_capacity * slot_count * @sizeOf(MeshData),
        };
        self.dev.updateDescriptorSets((&core.bufferWriteDescriptorSet(self.mesh_data_descriptor_sets_per_frame[frame_idx], 0, .storage_buffer, &info))[0..1], null);
    }

    fn destroyMeshDataDescriptorResources(self: *IndirectScene) void {
        core.destroyFrameDescriptorResources(self.dev, self.allocator, &self.vk_ctx.vkalloc, &self.mesh_data_descriptor_pool, &self.mesh_data_descriptor_sets_per_frame);
    }
};

/// A 1 MiB region allocator over a fake buffer handle, backed by `gpa`.
fn testRegionAllocator(gpa: std.mem.Allocator) !GpuRegionAllocator {
    return .init(gpa, try gpa.alignedAlloc(u8, buf_align, 1024 * 1024), @fromBackingInt(@intCast(1)), 0);
}

test "GpuRegionAllocator safe_graphics propagation" {
    const io = std.testing.io;
    var allocator = try testRegionAllocator(std.testing.allocator);
    defer allocator.deinit(std.testing.allocator);

    const fresh = allocator.allocRegion(io, 64).?;
    try std.testing.expectEqual(@as(u64, 0), fresh.safe_graphics);

    allocator.freeRegion(io, fresh.offset, 64, 42);
    const reused = allocator.allocRegion(io, 64).?;
    try std.testing.expectEqual(@as(u64, 42), reused.safe_graphics);

    // Adjacent frees merge, and the merged region keeps the max safety value.
    allocator.freeRegion(io, fresh.offset, 32, 7);
    allocator.freeRegion(io, fresh.offset + 32, 32, 13);
    const merged = allocator.allocRegion(io, 64).?;
    try std.testing.expectEqual(@as(u64, 13), merged.safe_graphics);
}
test "GpuRegionAllocator out-of-order frees merge" {
    const io = std.testing.io;
    var allocator = try testRegionAllocator(std.testing.allocator);
    defer allocator.deinit(std.testing.allocator);

    const a = allocator.allocRegion(io, 64).?;
    const b = allocator.allocRegion(io, 64).?;
    const c = allocator.allocRegion(io, 64).?;
    // Free out of order: the list must stay sorted so all three merge.
    allocator.freeRegion(io, b.offset, 64, 2);
    allocator.freeRegion(io, c.offset, 64, 3);
    allocator.freeRegion(io, a.offset, 64, 1);
    const merged = allocator.allocRegion(io, 192).?;
    try std.testing.expectEqual(a.offset, merged.offset);
    try std.testing.expectEqual(@as(u64, 3), merged.safe_graphics);
}

test "MeshData size" {
    try std.testing.expectEqual(@as(usize, 16), @alignOf(MeshData));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(MeshData));
}

test "orderedEncode/orderedDecode round-trip preserves float ordering" {
    const samples: [8]f32 = .{ -std.math.inf(f32), -1000.0, -1.5, -0.0, 0.0, 1.5, 1000.0, std.math.inf(f32) };
    var encoded: [samples.len]u32 = undefined;
    for (samples, 0..) |sample, sample_index| encoded[sample_index] = orderedEncode(sample);

    // Encoding preserves order: sorted samples map to sorted u32s.
    for (1..samples.len) |i| try std.testing.expect(encoded[i - 1] < encoded[i]);

    for (samples, 0..) |sample, sample_index| {
        const back = orderedDecode(encoded[sample_index]);
        if (std.math.isNan(sample)) {
            try std.testing.expect(std.math.isNan(back));
        } else {
            try std.testing.expectEqual(sample, back);
        }
    }

    try std.testing.expectEqual(aabb_min_inf_ord, orderedEncode(std.math.inf(f32)));
    try std.testing.expectEqual(aabb_max_inf_ord, orderedEncode(-std.math.inf(f32)));
}

test "GpuRegionAllocator grow ignores a stale slice" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var allocator = try testRegionAllocator(gpa);
    defer allocator.deinit(gpa);

    for (0..2) |_| {
        const new_slice = try gpa.alignedAlloc(u8, buf_align, try allocator.nextCapacity(io));
        gpa.free(allocator.grow(io, new_slice, @fromBackingInt(@intCast(1)), 0).?.old_slice);
    }
    // A slice no larger than the current buffer means another thread already grew it.
    const stale_slice = try gpa.alignedAlloc(u8, buf_align, allocator.buffer_slice.len);
    defer gpa.free(stale_slice);
    try std.testing.expect(allocator.grow(io, stale_slice, @fromBackingInt(@intCast(1)), 0) == null);
}

fn stagingRingAlloc(gpa: std.mem.Allocator) !void {
    var ring = try StagingRing.init(gpa, gpa, 1024);
    defer ring.deinit(gpa);
    // The entry bookkeeping allocation must propagate OutOfMemory instead of reporting a full ring.
    try std.testing.expect(try ring.alloc(std.testing.io, 8) != null);
}

fn stagingRingAllocPair(gpa: std.mem.Allocator) !void {
    var ring = try StagingRing.init(gpa, gpa, 1024);
    defer ring.deinit(gpa);
    // The entry reservation must propagate OutOfMemory before the ring changes.
    try std.testing.expect(try ring.allocPair(std.testing.io, .{ 8, 8 }) != null);
}

test "StagingRing checkAllAllocationFailures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, stagingRingAlloc, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, stagingRingAllocPair, .{});
}

test "StagingRing allocPair atomicity" {
    const io = std.testing.io;
    var ring = try StagingRing.init(std.testing.allocator, std.testing.allocator, 1024);
    defer ring.deinit(std.testing.allocator);

    // Zero sizes yield null slots without consuming space.
    const empty = (try ring.allocPair(io, .{ 0, 0 })).?;
    try std.testing.expectEqual(null, empty[0]);
    try std.testing.expectEqual(null, empty[1]);

    const pair = (try ring.allocPair(io, .{ 8, 16 })).?;
    try std.testing.expectEqual(8, pair[0].?.len);
    try std.testing.expectEqual(16, pair[1].?.len);

    // A pair that does not fit as a whole is refused entirely; nothing is consumed.
    try std.testing.expectEqual(null, try ring.allocPair(io, .{ 512, 512 }));

    // After both slices retire, the refused pair fits again.
    ring.bind(io, pair[0].?, 1);
    ring.bind(io, pair[1].?, 1);
    ring.retire(io, 1);
    const big = (try ring.allocPair(io, .{ 512, 512 })).?;
    try std.testing.expect(big[0] != null and big[1] != null);

    // A pair larger than the whole ring fails loudly instead of spinning forever.
    try std.testing.expectError(error.StagingTooLarge, ring.allocPair(io, .{ 1024, 1024 }));
}

test "StagingRing split gap boundary and degenerate full" {
    const io = std.testing.io;
    var ring = try StagingRing.init(std.testing.allocator, std.testing.allocator, 1024);
    defer ring.deinit(std.testing.allocator);

    const Off = struct {
        fn run(r: *const StagingRing, slice: []const u8) vk.DeviceSize {
            return @intCast(@intFromPtr(slice.ptr) - @intFromPtr(r.mapping.ptr));
        }
    }.run;

    const a = (try ring.alloc(io, 256)).?;
    const b = (try ring.alloc(io, 256)).?;
    const c = (try ring.alloc(io, 256)).?;
    const d = (try ring.alloc(io, 256)).?;
    try std.testing.expectEqual(@as(vk.DeviceSize, 0), Off(&ring, a));
    try std.testing.expectEqual(@as(vk.DeviceSize, 256), Off(&ring, b));
    try std.testing.expectEqual(@as(vk.DeviceSize, 512), Off(&ring, c));
    try std.testing.expectEqual(@as(vk.DeviceSize, 768), Off(&ring, d));
    @memset(a, 0xaa);
    @memset(b, 0xbb);
    @memset(c, 0xcc);
    @memset(d, 0xdd);

    // Contiguous full: head ran to the end with tail at 0, so anything wraps past the tail.
    try std.testing.expect((try ring.alloc(io, 1)) == null);

    ring.bind(io, a, 1);
    ring.bind(io, b, 1);
    ring.retire(io, 1);

    // Contiguous wrap refusal: 513 aligns to 768, which does not fit the [0, 512) prefix.
    try std.testing.expect((try ring.alloc(io, 513)) == null);

    // Contiguous wrap prefix fit: 256 fits the prefix and wraps to 0, leaving a split ring.
    const e = (try ring.alloc(io, 256)).?;
    try std.testing.expectEqual(@as(vk.DeviceSize, 0), Off(&ring, e));
    @memset(e, 0xee);

    // Split gap is exactly [256, 512): 257 aligns to 512 and is refused ...
    try std.testing.expect((try ring.alloc(io, 257)) == null);

    // ... while 256 fits exactly and fills the ring to head == tail with live entries.
    const f = (try ring.alloc(io, 256)).?;
    try std.testing.expectEqual(@as(vk.DeviceSize, 256), Off(&ring, f));
    @memset(f, 0xff);

    // Degenerate full: head == tail with live entries, so even 1 byte is refused.
    // With head < tail misclassification this wraps to 512 and overwrites c.
    try std.testing.expect((try ring.alloc(io, 1)) == null);
    try std.testing.expect((try ring.allocPair(io, .{ 8, 8 })) == null);

    // The wrap and gap fill only reused retired bytes; live slices are intact.
    try std.testing.expect(c[0] == 0xcc and d[0] == 0xdd and e[0] == 0xee and f[0] == 0xff);
}
