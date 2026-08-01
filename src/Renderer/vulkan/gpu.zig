const std = @import("std");
const tracy = @import("tracy");
const vk = @import("vulkan");

const DeviceProxy = vk.DeviceProxy;
const VulkanContext = @import("../../VulkanContext.zig").VulkanContext;
const core = @import("core.zig");

// ---------------------------------------------------------------------------
// IndexPool
// ---------------------------------------------------------------------------

pub const IndexPool = struct {
    free_indices: []u32,
    head: u32,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !IndexPool {
        const indices = try allocator.alloc(u32, capacity);
        for (indices, 0..) |*val, i| val.* = @intCast(capacity - 1 - i);
        return .{ .free_indices = indices, .head = capacity };
    }

    pub fn deinit(self: *IndexPool, allocator: std.mem.Allocator) void {
        allocator.free(self.free_indices);
    }

    pub fn allocIndex(self: *IndexPool, io: std.Io) ?u32 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.head == 0) return null;
        self.head -= 1;
        return self.free_indices[self.head];
    }

    pub fn freeIndex(self: *IndexPool, io: std.Io, index: u32) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(self.head < self.free_indices.len);
        self.free_indices[self.head] = index;
        self.head += 1;
    }

    pub fn grow(self: *IndexPool, io: std.Io, allocator: std.mem.Allocator, new_capacity: u32) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const old_capacity = @as(u32, @intCast(self.free_indices.len));
        if (new_capacity <= old_capacity) return;
        const added = new_capacity - old_capacity;
        const new_indices = try allocator.alloc(u32, new_capacity);
        @memcpy(new_indices[0..self.head], self.free_indices[0..self.head]);
        for (new_indices[self.head .. self.head + added], old_capacity..) |*val, i| val.* = @intCast(i);
        allocator.free(self.free_indices);
        self.free_indices = new_indices;
        self.head += added;
    }
};

// ---------------------------------------------------------------------------
// StagingRing
// ---------------------------------------------------------------------------

pub const StagingRing = struct {
    const transfer_alignment: vk.DeviceSize = 256;

    allocator: std.mem.Allocator,

    mapping: []align(transfer_alignment) u8,
    buffer: ?vk.Buffer,

    head: vk.DeviceSize,
    entries: std.ArrayList(struct { ptr: [*]const u8, timeline_value: ?u64 }),
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, cpu_to_gpu_allocator: std.mem.Allocator, capacity_bytes: vk.DeviceSize) !StagingRing {
        const mapping = try cpu_to_gpu_allocator.alignedAlloc(u8, .fromByteUnits(transfer_alignment), capacity_bytes);
        errdefer cpu_to_gpu_allocator.free(mapping);

        return .{
            .allocator = allocator,
            .mapping = mapping,
            .buffer = null,
            .head = 0,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *StagingRing, cpu_to_gpu_allocator: std.mem.Allocator) void {
        cpu_to_gpu_allocator.free(self.mapping);
        self.entries.deinit(self.allocator);
    }

    pub fn resolve(self: *StagingRing, buffer: vk.Buffer) void {
        std.debug.assert(buffer != .null_handle);
        self.buffer = buffer;
    }

    pub fn alloc(self: *StagingRing, io: std.Io, size: vk.DeviceSize) ?[]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.buffer == null) return null;

        const aligned = std.mem.alignForward(vk.DeviceSize, size, transfer_alignment);
        if (aligned > self.mapping.len) return null;

        if (self.head + aligned > self.mapping.len) {
            if (self.entries.items.len > 0) return null;
            self.head = 0;
        }

        const slice = self.mapping[self.head..][0..@intCast(size)];
        self.entries.append(self.allocator, .{ .ptr = slice.ptr, .timeline_value = null }) catch return null;
        self.head += aligned;

        return slice;
    }

    pub fn bind(self: *StagingRing, io: std.Io, slice: []const u8, timeline_value: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        for (self.entries.items) |*e| {
            if (e.ptr == slice.ptr) {
                e.timeline_value = timeline_value;
                return;
            }
        }
    }

    pub fn retire(self: *StagingRing, io: std.Io, current_transfer_val: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (self.entries.items.len > 0) {
            const e = self.entries.items[0];
            const tv = e.timeline_value orelse break;
            if (current_transfer_val < tv) break;
            _ = self.entries.orderedRemove(0);
        }

        if (self.entries.items.len == 0) self.head = 0;
    }

    pub fn cancel(self: *StagingRing, io: std.Io, slice: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        for (self.entries.items, 0..) |e, i| {
            if (e.ptr == slice.ptr) {
                std.debug.assert(e.timeline_value == null);
                _ = self.entries.orderedRemove(i);
                if (i == self.entries.items.len) {
                    // Cancelled the tail entry: retract head so its space is
                    // immediately reusable instead of stranded until wrap-around.
                    const aligned = std.mem.alignForward(vk.DeviceSize, slice.len, transfer_alignment);
                    std.debug.assert(self.head >= aligned);
                    self.head -= aligned;
                }
                if (self.entries.items.len == 0) self.head = 0;
                return;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// GpuRegionAllocator
// ---------------------------------------------------------------------------

const log = std.log.scoped(.gpu_region_allocator);

const buf_align: std.mem.Alignment = .fromByteUnits(256);

const Region = struct {
    offset: vk.DeviceSize,
    length: vk.DeviceSize,
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
    };

    buffer_slice: []align(buf_align.toByteUnits()) u8,
    // Atomic so the render thread can size barriers without taking the allocator mutex.
    buffer: std.atomic.Value(vk.Buffer) = .init(.null_handle),
    buffer_offset: std.atomic.Value(vk.DeviceSize) = .init(0),
    used: std.atomic.Value(vk.DeviceSize) = .init(0),

    free_regions: std.ArrayList(Region),
    free_list_allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,

    pub fn init(free_list_allocator: std.mem.Allocator, gpu_allocator: std.mem.Allocator, capacity_bytes: vk.DeviceSize) !GpuRegionAllocator {
        const slice = try gpu_allocator.alignedAlloc(u8, buf_align, capacity_bytes);

        return GpuRegionAllocator{
            .buffer_slice = slice,
            .free_regions = .empty,
            .free_list_allocator = free_list_allocator,
        };
    }

    pub fn deinit(self: *GpuRegionAllocator, gpu_allocator: std.mem.Allocator) void {
        self.free_regions.deinit(self.free_list_allocator);
        gpu_allocator.free(self.buffer_slice);
    }

    pub fn resolve(self: *GpuRegionAllocator, buffer: vk.Buffer, buffer_offset: vk.DeviceSize) void {
        std.debug.assert(buffer != .null_handle);
        self.buffer.store(buffer, .release);
        self.buffer_offset.store(buffer_offset, .release);
    }

    pub fn allocRegion(self: *GpuRegionAllocator, io: std.Io, length: vk.DeviceSize) ?AllocResult {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.buffer.load(.monotonic) == .null_handle) return null;

        if (self.findFreeRegion(length)) |offset| {
            return .{
                .offset = offset,
                .buffer = self.buffer.load(.monotonic),
                .buffer_offset = self.buffer_offset.load(.monotonic),
            };
        }

        const current_used = self.used.load(.monotonic);
        const new_used, const overflow = @addWithOverflow(current_used, length);
        if (overflow == 0 and new_used <= self.buffer_slice.len) {
            const offset = current_used;
            self.used.store(new_used, .monotonic);
            return .{
                .offset = offset,
                .buffer = self.buffer.load(.monotonic),
                .buffer_offset = self.buffer_offset.load(.monotonic),
            };
        }

        return null;
    }

    fn findFreeRegion(self: *GpuRegionAllocator, length: vk.DeviceSize) ?vk.DeviceSize {
        for (self.free_regions.items, 0..) |region, i| {
            if (region.length < length) continue;

            const result = region.offset;
            if (region.length == length) {
                _ = self.free_regions.orderedRemove(i);
            } else {
                self.free_regions.items[i] = .{
                    .offset = region.offset + length,
                    .length = region.length - length,
                };
            }
            return result;
        }
        return null;
    }

    pub fn freeRegion(self: *GpuRegionAllocator, io: std.Io, offset: vk.DeviceSize, length: vk.DeviceSize) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const insertion_index = for (self.free_regions.items, 0..) |region, i| {
            if (offset < region.offset + region.length and region.offset < offset + length) {
                std.debug.panic("GpuRegionAllocator.freeRegion: overlapping free of [{d}, {d})", .{ offset, offset + length });
            }
            if (region.offset > offset) break i;
        } else self.free_regions.items.len;

        self.free_regions.insert(self.free_list_allocator, insertion_index, .{ .offset = offset, .length = length }) catch @panic("GpuRegionAllocator.freeRegion: insert OOM");

        var i = insertion_index;
        while (i > 0) {
            if (self.free_regions.items[i - 1].offset + self.free_regions.items[i - 1].length == self.free_regions.items[i].offset) {
                self.free_regions.items[i - 1].length += self.free_regions.items[i].length;
                _ = self.free_regions.orderedRemove(i);
                i -= 1;
            } else break;
        }

        while (i + 1 < self.free_regions.items.len) {
            if (self.free_regions.items[i].offset + self.free_regions.items[i].length == self.free_regions.items[i + 1].offset) {
                self.free_regions.items[i].length += self.free_regions.items[i + 1].length;
                _ = self.free_regions.orderedRemove(i + 1);
            } else break;
        }
    }

    pub fn grow(self: *GpuRegionAllocator, io: std.Io, gpu_allocator: std.mem.Allocator) !GrowInfo {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const new_capacity = std.math.mul(vk.DeviceSize, @as(vk.DeviceSize, @intCast(self.buffer_slice.len)), 2) catch return error.OutOfMemory;
        log.info("growing from {d} MB to {d} MB", .{
            self.buffer_slice.len / (1024 * 1024),
            new_capacity / (1024 * 1024),
        });

        const new_slice = try gpu_allocator.alignedAlloc(u8, buf_align, new_capacity);

        const old_info: GrowInfo = .{
            .old_slice = self.buffer_slice,
            .old_buffer = self.buffer.load(.monotonic),
            .old_buffer_offset = self.buffer_offset.load(.monotonic),
            .old_used = self.used.load(.monotonic),
        };

        self.buffer_slice = new_slice;
        // Freed regions stay reusable: the caller copies [0, used) into the new buffer,
        // so their offsets remain valid. buffer is nulled until resolve() pairs it
        // with the new handle — allocRegion returns null in the interim.
        self.buffer.store(.null_handle, .release);
        self.buffer_offset.store(0, .release);

        log.info("grew to {d} MB", .{self.buffer_slice.len / (1024 * 1024)});

        return old_info;
    }
};

// ---------------------------------------------------------------------------
// CommandPoolReservoir
// ---------------------------------------------------------------------------

const reservoir_size = 512;

pub const CommandPoolReservoir = struct {
    pools: [reservoir_size]vk.CommandPool = @splat(@as(vk.CommandPool, .null_handle)),
    cmds: [reservoir_size]vk.CommandBuffer = @splat(@as(vk.CommandBuffer, .null_handle)),
    used: [reservoir_size]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
    count: usize = 0,

    pub const Borrowed = struct { pool: vk.CommandPool, cmd: vk.CommandBuffer };

    pub fn init(self: *CommandPoolReservoir, dev: DeviceProxy, queue_family: u32, init_count: usize, vkalloc: *const vk.AllocationCallbacks) !void {
        self.count = init_count;
        for (self.pools[0..init_count], self.cmds[0..init_count]) |*pool, *cmd| {
            pool.* = try dev.createCommandPool(&.{ .flags = .{ .reset_command_buffer_bit = true }, .queue_family_index = queue_family }, vkalloc);
            try dev.allocateCommandBuffers(&.{ .command_pool = pool.*, .level = .primary, .command_buffer_count = 1 }, (&cmd.*)[0..1]);
        }
    }

    pub fn deinit(self: *CommandPoolReservoir, dev: DeviceProxy, vkalloc: *const vk.AllocationCallbacks) void {
        for (self.pools[0..self.count]) |pool| if (pool != .null_handle) dev.destroyCommandPool(pool, vkalloc);
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

// ---------------------------------------------------------------------------
// GpuMemory
// ---------------------------------------------------------------------------

/// Shared GPU allocation pools: device-local and host-visible GPU-visible memory,
/// each wrapped in a DebugAllocator backed by one VulkanBackingAllocator.
pub const GpuMemory = struct {
    backing_allocator: core.VulkanBackingAllocator,
    gpu_only_gpa: std.heap.DebugAllocator(.{}) = .init,
    cpu_to_gpu_gpa: std.heap.DebugAllocator(.{}) = .init,

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

        self.gpu_only_gpa = .init;
        self.gpu_only_gpa.backing_allocator = self.backing_allocator.allocator(.gpu_only);
        errdefer _ = self.gpu_only_gpa.deinit();

        self.cpu_to_gpu_gpa = .init;
        self.cpu_to_gpu_gpa.backing_allocator = self.backing_allocator.allocator(.cpu_to_gpu);
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

// ---------------------------------------------------------------------------
// MeshUploader
// ---------------------------------------------------------------------------

pub const max_batch = 512;

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
};

const TransferState = struct {
    queue: vk.Queue = undefined,
    queue_family_index: u32 = undefined,
    semaphore: vk.Semaphore = .null_handle,
    graphics_timeline_semaphore: vk.Semaphore = .null_handle,
};

const RetiredFaceBuffer = struct {
    slice: []align(256) u8,
    graphics_timeline_value: u64,
};

/// Async transfer-queue upload pipeline for instanced geometry. Owns the staging ring,
/// the shared GPU face buffer, the command pool reservoir, and the transfer submission
/// machinery (timeline semaphores, queue mutex, growth of the face buffer).
pub const MeshUploader = struct {
    vk_ctx: *VulkanContext,
    allocator: std.mem.Allocator,
    dev: DeviceProxy,
    memory: *GpuMemory,
    single_time: *core.SingleTime,
    num_in_flight: u32 = VulkanContext.max_frames_in_flight,

    staging_ring: StagingRing,
    region_allocator: GpuRegionAllocator,
    pool_reservoir: CommandPoolReservoir = .{},
    retired_face_buffers: std.ArrayList(RetiredFaceBuffer) = undefined,
    transfer: TransferState = .{},

    flush_ctx: *anyopaque = undefined,
    flush_fn: ?*const fn (*anyopaque, std.Io) anyerror!void = null,

    pub fn init(
        allocator: std.mem.Allocator,
        vk_ctx: *VulkanContext,
        memory: *GpuMemory,
        single_time: *core.SingleTime,
        initial_region_bytes: vk.DeviceSize,
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
            .retired_face_buffers = .empty,
        };
        self.transfer = .{
            .queue_family_index = vk_ctx.transfer_queue_family_index,
            .queue = vk_ctx.transfer_queue,
            .semaphore = vk_ctx.transfer_semaphore,
            .graphics_timeline_semaphore = vk_ctx.graphics_timeline_semaphore,
        };

        self.region_allocator = try GpuRegionAllocator.init(allocator, memory.gpuOnly(), initial_region_bytes);
        errdefer self.region_allocator.deinit(memory.gpuOnly());
        const face_buf_info = memory.backing_allocator.getBufferAndOffset(.gpu_only, self.region_allocator.buffer_slice.ptr);
        self.region_allocator.resolve(face_buf_info.buffer, face_buf_info.offset);

        self.staging_ring = try StagingRing.init(allocator, memory.cpuToGpu(), initial_staging_bytes);
        errdefer self.staging_ring.deinit(memory.cpuToGpu());
        const staging_info = memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, self.staging_ring.mapping.ptr);
        self.staging_ring.resolve(staging_info.buffer);

        try self.pool_reservoir.init(self.dev, self.transfer.queue_family_index, 512, &vk_ctx.vkalloc);
        errdefer self.pool_reservoir.deinit(self.dev, &vk_ctx.vkalloc);

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
        if (self.flush_fn) |f| try f(self.flush_ctx, io);
    }

    pub fn borrowPool(self: *MeshUploader, io: std.Io) !CommandPoolReservoir.Borrowed {
        while (true) {
            if (self.pool_reservoir.tryBorrowPool()) |b| return b;
            try self.flush(io);
            try std.Io.sleep(io, .fromNanoseconds(0), .awake);
        }
    }

    pub fn returnPool(self: *MeshUploader, pool: vk.CommandPool) void {
        self.pool_reservoir.returnPool(self.dev, pool);
    }

    pub fn allocStaging(self: *MeshUploader, io: std.Io, buffer_size: vk.DeviceSize) ![]u8 {
        while (true) {
            if (self.staging_ring.alloc(io, buffer_size)) |slice| return slice;
            try self.flush(io);
            try std.Io.sleep(io, .fromNanoseconds(0), .awake);
        }
    }

    pub fn cancelStaging(self: *MeshUploader, io: std.Io, slice: []u8) void {
        self.staging_ring.cancel(io, slice);
    }

    pub fn bindStaging(self: *MeshUploader, io: std.Io, slice: []u8, timeline_value: u64) void {
        self.staging_ring.bind(io, slice, timeline_value);
    }

    pub fn allocRegion(self: *MeshUploader, io: std.Io, buffer_size: vk.DeviceSize) !GpuRegionAllocator.AllocResult {
        while (true) {
            if (self.region_allocator.allocRegion(io, buffer_size)) |result| return result;

            try self.flush(io);

            self.vk_ctx.queue_mutex.lockUncancelable(io);
            defer self.vk_ctx.queue_mutex.unlock(io);

            if (self.region_allocator.allocRegion(io, buffer_size)) |result| return result;

            std.log.info("growing face data buffer...", .{});
            try self.drainInFlightFrames();

            const transfer_done_val = self.vk_ctx.transfer_semaphore_value.load(.acquire);
            if (transfer_done_val > 0) {
                _ = try self.dev.waitSemaphores(&.{
                    .semaphore_count = 1,
                    .p_semaphores = (&self.transfer.semaphore)[0..1],
                    .p_values = (&transfer_done_val)[0..1],
                }, std.math.maxInt(u64));
            }

            const grow_info = try self.region_allocator.grow(io, self.memory.gpuOnly());

            const face_buf_info = self.memory.backing_allocator.getBufferAndOffset(.gpu_only, self.region_allocator.buffer_slice.ptr);
            self.region_allocator.resolve(face_buf_info.buffer, face_buf_info.offset);

            const cmd = try self.single_time.begin();
            self.dev.cmdCopyBuffer2(cmd, &.{
                .src_buffer = grow_info.old_buffer,
                .dst_buffer = self.region_allocator.buffer.load(.monotonic),
                .region_count = 1,
                .p_regions = (&vk.BufferCopy2{
                    .src_offset = grow_info.old_buffer_offset,
                    .dst_offset = self.region_allocator.buffer_offset.load(.monotonic),
                    .size = grow_info.old_used,
                })[0..1],
            });

            self.single_time.endLocked(cmd) catch {
                @panic("MeshUploader.allocRegion: GPU command submission or wait failed - cannot safely continue");
            };

            self.retired_face_buffers.append(self.allocator, .{
                .slice = grow_info.old_slice,
                .graphics_timeline_value = self.vk_ctx.frame_number.load(.acquire) + self.num_in_flight,
            }) catch |err| {
                // The copy above completed, but a frame recorded before the swap may still bind the
                // old buffer; freeing it now would be a use-after-free, so leak it instead.
                std.log.err("MeshUploader.allocRegion: failed to queue old face buffer for retirement ({any}); leaking it", .{err});
            };

            std.log.info("face data buffer grown", .{});
        }
    }

    pub fn freeRegion(self: *MeshUploader, io: std.Io, offset: vk.DeviceSize, length: vk.DeviceSize) void {
        self.region_allocator.freeRegion(io, offset, length);
    }

    pub fn freeMesh(self: *MeshUploader, io: std.Io, mesh: MeshBuffer) void {
        self.region_allocator.freeRegion(io, @as(vk.DeviceSize, @intCast(mesh.face_offset)) * face_stride, mesh.face_byte_count);
    }

    /// Submits command buffers on the transfer queue, gated by the graphics timeline
    /// semaphore, and signals the transfer timeline. Returns the new transfer value.
    pub fn submitToTransferQueue(self: *MeshUploader, io: std.Io, cmds: []const vk.CommandBuffer) !u64 {
        const count = cmds.len;
        if (count == 0) return self.vk_ctx.transfer_semaphore_value.load(.monotonic);
        std.debug.assert(count <= max_batch);

        const zone_queue = tracy.Zone.begin(.{ .src = @src(), .name = "submitToTransferQueue_lock" });
        self.vk_ctx.queue_mutex.lockUncancelable(io);
        zone_queue.end();
        defer self.vk_ctx.queue_mutex.unlock(io);

        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "submitToTransferQueue" });
        defer zone.end();

        const next_val = self.vk_ctx.transfer_semaphore_value.load(.monotonic) + 1;
        self.vk_ctx.transfer_semaphore_value.store(next_val, .monotonic);

        var cb_submit_infos: [max_batch]vk.CommandBufferSubmitInfo = undefined;
        for (cb_submit_infos[0..count], cmds) |*info, cmd| info.* = .{ .command_buffer = cmd, .device_mask = 0 };

        const current_graphics_val = self.vk_ctx.frame_number.load(.acquire);

        const submit_info: vk.SubmitInfo2 = .{
            .flags = .{},
            .wait_semaphore_info_count = 1,
            .p_wait_semaphore_infos = (&vk.SemaphoreSubmitInfo{
                .semaphore = self.transfer.graphics_timeline_semaphore,
                .value = current_graphics_val,
                .stage_mask = .{ .all_transfer_bit = true },
                .device_index = 0,
            })[0..1],
            .command_buffer_info_count = @intCast(count),
            .p_command_buffer_infos = cb_submit_infos[0..count].ptr,
            .signal_semaphore_info_count = 1,
            .p_signal_semaphore_infos = (&vk.SemaphoreSubmitInfo{
                .semaphore = self.transfer.semaphore,
                .value = next_val,
                .stage_mask = .{ .all_transfer_bit = true },
                .device_index = 0,
            })[0..1],
        };

        try self.dev.queueSubmit2(self.transfer.queue, (&submit_info)[0..1], .null_handle);

        return next_val;
    }

    pub fn drainInFlightFrames(self: *MeshUploader) !void {
        const frame_to_wait = self.vk_ctx.frame_number.load(.acquire);
        if (frame_to_wait > 0) {
            const wait_value: u64 = frame_to_wait;
            const wait_info: vk.SemaphoreWaitInfo = .{
                .semaphore_count = 1,
                .p_semaphores = (&self.transfer.graphics_timeline_semaphore)[0..1],
                .p_values = (&wait_value)[0..1],
            };
            _ = try self.dev.waitSemaphores(&wait_info, std.math.maxInt(u64));
        }
    }

    pub fn retireStaging(self: *MeshUploader, io: std.Io, current_transfer_val: u64) void {
        self.staging_ring.retire(io, current_transfer_val);
    }

    pub fn processRetiredFaceBuffers(self: *MeshUploader, current_graphics_val: u64) void {
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

    /// Acquire side of the cross-queue memory dependency: makes the upload batch's
    /// transfer writes to the face buffer visible to this frame's vertex reads.
    pub fn cmdAcquireFaceBuffer(self: *MeshUploader, cmd_buffer: vk.CommandBuffer) void {
        const used = self.region_allocator.used.load(.monotonic);
        if (used == 0) return;
        // The buffer is momentarily null while allocRegion grows it; the per-frame
        // transfer semaphore wait already covers the cross-queue sync in that window.
        const buffer = self.region_allocator.buffer.load(.acquire);
        if (buffer == .null_handle) return;
        core.pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, (&vk.BufferMemoryBarrier2{
            .src_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .vertex_attribute_input_bit = true },
            .dst_access_mask = .{ .vertex_attribute_read_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .buffer = buffer,
            .offset = self.region_allocator.buffer_offset.load(.monotonic),
            .size = used,
        })[0..1]);
    }

    /// Release side: makes this frame's vertex reads available before the next upload
    /// batch writes the same regions on the transfer queue.
    pub fn cmdReleaseFaceBuffer(self: *MeshUploader, cmd_buffer: vk.CommandBuffer) void {
        const used = self.region_allocator.used.load(.monotonic);
        if (used == 0) return;
        const buffer = self.region_allocator.buffer.load(.acquire);
        if (buffer == .null_handle) return;
        core.pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, (&vk.BufferMemoryBarrier2{
            .src_stage_mask = .{ .vertex_attribute_input_bit = true },
            .src_access_mask = .{ .vertex_attribute_read_bit = true },
            .dst_stage_mask = .{ .all_transfer_bit = true },
            .dst_access_mask = .{},
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .buffer = buffer,
            .offset = self.region_allocator.buffer_offset.load(.monotonic),
            .size = used,
        })[0..1]);
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

// ---------------------------------------------------------------------------
// IndirectScene
// ---------------------------------------------------------------------------

pub const MeshCandidate = extern struct {
    absolute_position: [4]f32 align(@sizeOf([4]f32)),
    face_offset: u32,
    scale: f32,
    face_count: u32,
    is_transparent: u32,
};

comptime {
    if (@sizeOf(MeshCandidate) != 32) @compileError("MeshCandidate size mismatch with GLSL layout (expected 32, got " ++ @typeName(@TypeOf(@sizeOf(MeshCandidate))) ++ ")");
}

pub const CullCount = extern struct {
    opaque_count: u32,
    transparent_count: u32,
    opaque_face_count: u32,
    transparent_face_count: u32,
};

comptime {
    if (@sizeOf(CullCount) != 16) @compileError("CullCount size mismatch");
}

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
pub const draw_type_count = 2;

const PersistentCandidates = struct {
    buffer: vk.Buffer = .null_handle,
    mapped: [*]MeshCandidate = undefined,
    offset: vk.DeviceSize = 0,
    slice: []MeshCandidate = &.{},
};

const RetiredCandidateSlice = struct {
    slice: []MeshCandidate,
    graphics_timeline_value: u64,
};

const PerFrameData = struct {
    indirect_draw: vk.Buffer = .null_handle,
    indirect_draw_mapped: ?[*]vk.DrawIndirectCommand = null,
    indirect_draw_offset: vk.DeviceSize = 0,
    mesh_data: vk.Buffer = .null_handle,
    mesh_data_mapped: ?[*]MeshData = null,
    mesh_data_offset: vk.DeviceSize = 0,
    count: vk.Buffer = .null_handle,
    count_slice: []align(cull_buffer_alignment.toByteUnits()) CullCount = &.{},
    count_offset: vk.DeviceSize = 0,
    stats: vk.Buffer = .null_handle,
    stats_mapped: ?[*]align(cull_buffer_alignment.toByteUnits()) CullCount = null,
    stats_offset: vk.DeviceSize = 0,
    stats_slice: []align(cull_buffer_alignment.toByteUnits()) CullCount = &.{},
};

const PerFrameBuffers = struct {
    items: []PerFrameData = &.{},

    fn deinit(self: *PerFrameBuffers, allocator: std.mem.Allocator, cpu_to_gpu_gpa: std.mem.Allocator, gpu_only_gpa: std.mem.Allocator, draw_capacity: u32) void {
        for (self.items) |*item| {
            if (item.indirect_draw_mapped) |p| cpu_to_gpu_gpa.free(p[0 .. draw_capacity * draw_type_count]);
            if (item.mesh_data_mapped) |p| cpu_to_gpu_gpa.free(p[0 .. draw_capacity * draw_type_count]);
            if (item.count_slice.len > 0) gpu_only_gpa.free(item.count_slice);
            if (item.stats_slice.len > 0) cpu_to_gpu_gpa.free(item.stats_slice);
        }
        allocator.free(self.items);
        // Reset so a failed swapchain recreation cannot leave a dangling slice behind.
        self.items = &.{};
    }
};

/// GPU-driven indirect-draw scene: persistent candidate slots, per-frame indirect/
/// mesh-data/count/stats buffers, and the frustum culling dispatch that fills them.
pub const IndirectScene = struct {
    vk_ctx: *VulkanContext,
    allocator: std.mem.Allocator,
    dev: DeviceProxy,
    memory: *GpuMemory,
    num_in_flight: u32 = VulkanContext.max_frames_in_flight,

    persistent: PersistentCandidates = .{},
    index_pool: IndexPool = undefined,
    max_allocated_index: std.atomic.Value(u32) = .init(0),
    retired_candidate_slices: std.ArrayList(RetiredCandidateSlice) = .empty,
    frame_buffers: PerFrameBuffers = .{},
    /// Bumped whenever the candidate buffer or per-frame buffers are reallocated;
    /// consumers that bind these buffers (e.g. the cull dispatch) re-bind on change.
    buffers_version: u32 = 0,

    draw_capacity: u32 = 4096,
    max_draw_indirect_count: u32 = 65_535,

    mesh_data_descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    mesh_data_descriptor_pool: vk.DescriptorPool = .null_handle,
    mesh_data_descriptor_sets_per_frame: []vk.DescriptorSet = &.{},

    pub fn init(self: *IndirectScene, allocator: std.mem.Allocator, vk_ctx: *VulkanContext, memory: *GpuMemory, initial_candidates: u32, initial_draw_capacity: u32) !void {
        self.* = .{
            .vk_ctx = vk_ctx,
            .allocator = allocator,
            .dev = vk_ctx.dev,
            .memory = memory,
        };

        self.max_draw_indirect_count = if (vk_ctx.props.limits.max_draw_indirect_count > 0) vk_ctx.props.limits.max_draw_indirect_count else 65_535;
        self.draw_capacity = initial_draw_capacity;

        const persistent_candidates_slice = try memory.cpuToGpu().alloc(MeshCandidate, initial_candidates);
        errdefer memory.cpuToGpu().free(persistent_candidates_slice);
        @memset(persistent_candidates_slice, .{ .absolute_position = .{ 0, 0, 0, 0 }, .scale = 0, .face_count = 0, .is_transparent = 0, .face_offset = 0 });
        const cand_info = memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, persistent_candidates_slice.ptr);
        self.persistent.buffer = cand_info.buffer;
        self.persistent.mapped = persistent_candidates_slice.ptr;
        self.persistent.offset = cand_info.offset;
        self.persistent.slice = persistent_candidates_slice;

        self.index_pool = try IndexPool.init(allocator, initial_candidates);
        errdefer self.index_pool.deinit(allocator);

        self.frame_buffers.items = try allocator.alloc(PerFrameData, VulkanContext.max_frames_in_flight);
        @memset(self.frame_buffers.items, .{});
        errdefer self.frame_buffers.deinit(allocator, memory.cpuToGpu(), memory.gpuOnly(), self.draw_capacity);
        for (self.frame_buffers.items) |*frame| try self.allocateIndirectBuffers(frame);

        try self.createMeshDataDescriptorResources();
        errdefer self.destroyMeshDataDescriptorResources();
    }

    pub fn deinit(self: *IndirectScene) void {
        self.frame_buffers.deinit(self.allocator, self.memory.cpuToGpu(), self.memory.gpuOnly(), self.draw_capacity);

        self.destroyMeshDataDescriptorResources();
        core.destroyIfValid(self.dev, &self.mesh_data_descriptor_set_layout, &self.vk_ctx.vkalloc);

        for (self.retired_candidate_slices.items) |entry| self.memory.cpuToGpu().free(entry.slice);
        self.retired_candidate_slices.deinit(self.allocator);
        self.index_pool.deinit(self.allocator);
        self.memory.cpuToGpu().free(self.persistent.slice);
    }

    pub fn allocIndex(self: *IndirectScene, io: std.Io) !u32 {
        while (true) {
            if (self.index_pool.allocIndex(io)) |idx| return idx;
            try self.growPersistentCandidates(io);
        }
    }

    pub fn updateMaxAllocatedIndex(self: *IndirectScene, gpu_idx: u32) void {
        var current_max = self.max_allocated_index.load(.monotonic);
        while (gpu_idx >= current_max) {
            if (self.max_allocated_index.cmpxchgStrong(current_max, gpu_idx + 1, .release, .monotonic)) |actual_val| {
                current_max = actual_val;
                continue;
            }
            break;
        }
    }

    pub fn writeCandidate(self: *IndirectScene, gpu_index: u32, mesh: MeshBuffer, is_transparent: bool, transform: CandidateTransform) void {
        self.persistent.mapped[gpu_index] = .{
            .absolute_position = transform.absolute_position,
            .scale = transform.scale,
            .face_count = mesh.face_count,
            .is_transparent = if (is_transparent) 1 else 0,
            .face_offset = mesh.face_offset,
        };
    }

    pub fn releaseCandidate(self: *IndirectScene, io: std.Io, gpu_index: u32) void {
        self.persistent.mapped[gpu_index].face_count = 0;
        self.index_pool.freeIndex(io, gpu_index);
        self.tryShrinkMaxAllocatedIndex(gpu_index);
    }

    pub fn ensureCapacity(self: *IndirectScene, io: std.Io, total_candidates: u32) !void {
        if (total_candidates > self.draw_capacity) try self.growDrawCapacity(io, total_candidates);
    }

    pub fn processRetired(self: *IndirectScene, current_graphics_val: u64) void {
        const items = &self.retired_candidate_slices;
        var i: usize = items.items.len;
        while (i > 0) {
            i -= 1;
            const entry = items.items[i];
            if (current_graphics_val >= entry.graphics_timeline_value) {
                self.memory.cpuToGpu().free(entry.slice);
                _ = items.swapRemove(i);
            }
        }
    }

    fn fillFrameData(
        self: *IndirectScene,
        frame: *PerFrameData,
        mesh_data_slice: []MeshData,
        indirect_draw_slice: []vk.DrawIndirectCommand,
        count_slice: []align(cull_buffer_alignment.toByteUnits()) CullCount,
        stats_slice: []align(cull_buffer_alignment.toByteUnits()) CullCount,
    ) void {
        stats_slice[0] = .{ .opaque_count = 0, .transparent_count = 0, .opaque_face_count = 0, .transparent_face_count = 0 };

        const mesh_data_info = self.memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, mesh_data_slice.ptr);
        const indirect_draw_info = self.memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, indirect_draw_slice.ptr);
        const count_info = self.memory.backing_allocator.getBufferAndOffset(.gpu_only, count_slice.ptr);
        const stats_info = self.memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, stats_slice.ptr);

        frame.* = .{
            .mesh_data = mesh_data_info.buffer,
            .mesh_data_mapped = mesh_data_slice.ptr,
            .mesh_data_offset = mesh_data_info.offset,
            .indirect_draw = indirect_draw_info.buffer,
            .indirect_draw_mapped = indirect_draw_slice.ptr,
            .indirect_draw_offset = indirect_draw_info.offset,
            .count = count_info.buffer,
            .count_slice = count_slice,
            .count_offset = count_info.offset,
            .stats = stats_info.buffer,
            .stats_mapped = stats_slice.ptr,
            .stats_slice = stats_slice,
            .stats_offset = stats_info.offset,
        };
    }

    fn allocateIndirectBuffers(self: *IndirectScene, frame: *PerFrameData) !void {
        const mesh_data_slice = try self.memory.cpuToGpu().alloc(MeshData, self.draw_capacity * draw_type_count);
        const indirect_draw_slice = try self.memory.cpuToGpu().alloc(vk.DrawIndirectCommand, self.draw_capacity * draw_type_count);
        const count_slice = try self.memory.gpuOnly().alignedAlloc(CullCount, cull_buffer_alignment, 1);
        const stats_slice = try self.memory.cpuToGpu().alignedAlloc(CullCount, cull_buffer_alignment, 1);

        self.fillFrameData(frame, mesh_data_slice, indirect_draw_slice, count_slice, stats_slice);
    }

    fn growDrawCapacity(self: *IndirectScene, io: std.Io, min_capacity: u32) !void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "growDrawCapacity" });
        defer zone.end();

        if (min_capacity <= self.draw_capacity) return;

        var new_capacity = self.draw_capacity;
        while (new_capacity < min_capacity) {
            new_capacity = std.math.mul(u32, new_capacity, 2) catch return error.MaxDrawCapacityExceeded;
        }

        const clamped_capacity = @min(new_capacity, self.max_draw_indirect_count);
        if (clamped_capacity < new_capacity) {
            std.log.err("IndirectScene: draw capacity {d} exceeds device max indirect count {d}. Cannot continue rendering.", .{ new_capacity, self.max_draw_indirect_count });
            return error.MaxDrawCapacityExceeded;
        }
        new_capacity = clamped_capacity;

        std.log.info("IndirectScene: Growing draw capacity from {d} to {d} for all frames...", .{ self.draw_capacity, new_capacity });

        self.vk_ctx.queue_mutex.lockUncancelable(io);
        defer self.vk_ctx.queue_mutex.unlock(io);
        _ = try self.dev.deviceWaitIdle();

        const old_draw_capacity = self.draw_capacity;
        const num_frames = self.frame_buffers.items.len;

        const new_mesh_data = try self.allocator.alloc([*]MeshData, num_frames);
        defer self.allocator.free(new_mesh_data);
        const new_indirect = try self.allocator.alloc([*]vk.DrawIndirectCommand, num_frames);
        defer self.allocator.free(new_indirect);
        const new_count_slices = try self.allocator.alloc([]align(cull_buffer_alignment.toByteUnits()) CullCount, num_frames);
        defer self.allocator.free(new_count_slices);
        const new_stats_slices = try self.allocator.alloc([]align(cull_buffer_alignment.toByteUnits()) CullCount, num_frames);
        defer self.allocator.free(new_stats_slices);

        var allocated_frames: usize = 0;
        errdefer {
            for (0..allocated_frames) |i| {
                self.memory.cpuToGpu().free(new_mesh_data[i][0 .. new_capacity * draw_type_count]);
                self.memory.cpuToGpu().free(new_indirect[i][0 .. new_capacity * draw_type_count]);
                self.memory.gpuOnly().free(new_count_slices[i]);
                self.memory.cpuToGpu().free(new_stats_slices[i]);
            }
        }
        for (0..num_frames) |i| {
            const mesh_data_slice = try self.memory.cpuToGpu().alloc(MeshData, new_capacity * draw_type_count);
            errdefer self.memory.cpuToGpu().free(mesh_data_slice);
            const indirect_draw_slice = try self.memory.cpuToGpu().alloc(vk.DrawIndirectCommand, new_capacity * draw_type_count);
            errdefer self.memory.cpuToGpu().free(indirect_draw_slice);
            const count_slice = try self.memory.gpuOnly().alignedAlloc(CullCount, cull_buffer_alignment, 1);
            errdefer self.memory.gpuOnly().free(count_slice);
            const stats_slice = try self.memory.cpuToGpu().alignedAlloc(CullCount, cull_buffer_alignment, 1);
            errdefer self.memory.cpuToGpu().free(stats_slice);
            stats_slice[0] = .{ .opaque_count = 0, .transparent_count = 0, .opaque_face_count = 0, .transparent_face_count = 0 };

            new_mesh_data[i] = mesh_data_slice.ptr;
            new_indirect[i] = indirect_draw_slice.ptr;
            new_count_slices[i] = count_slice;
            new_stats_slices[i] = stats_slice;
            allocated_frames += 1;
        }

        for (self.frame_buffers.items[0..num_frames], new_mesh_data, new_indirect, new_count_slices, new_stats_slices) |*frame, new_mesh, new_ind, new_count, new_stats| {
            const old_mesh = frame.mesh_data_mapped.?;
            const old_ind = frame.indirect_draw_mapped.?;
            const old_count = frame.count_slice;
            const old_stats = frame.stats_slice;

            if (old_draw_capacity > 0) {
                @memcpy(new_mesh[0 .. old_draw_capacity * draw_type_count], old_mesh[0 .. old_draw_capacity * draw_type_count]);
                @memcpy(new_ind[0 .. old_draw_capacity * draw_type_count], old_ind[0 .. old_draw_capacity * draw_type_count]);
            }

            self.fillFrameData(frame, new_mesh[0 .. new_capacity * draw_type_count], new_ind[0 .. new_capacity * draw_type_count], new_count, new_stats);

            self.memory.cpuToGpu().free(old_mesh[0 .. old_draw_capacity * draw_type_count]);
            self.memory.cpuToGpu().free(old_ind[0 .. old_draw_capacity * draw_type_count]);
            self.memory.gpuOnly().free(old_count);
            self.memory.cpuToGpu().free(old_stats);
        }

        self.draw_capacity = new_capacity;
        self.buffers_version += 1;

        for (self.frame_buffers.items[0..num_frames], 0..) |_, i| {
            self.updateMeshDataDescriptorSet(@intCast(i));
        }
    }

    fn growPersistentCandidates(self: *IndirectScene, io: std.Io) !void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "growPersistentCandidates" });
        defer zone.end();

        const old_capacity = self.persistent.slice.len;
        const new_capacity = old_capacity * 2;
        std.log.info("IndirectScene: Growing persistent GPU scene candidates from {d} to {d}...", .{ old_capacity, new_capacity });

        self.vk_ctx.queue_mutex.lockUncancelable(io);
        defer self.vk_ctx.queue_mutex.unlock(io);
        _ = try self.dev.deviceWaitIdle();

        const new_slice = try self.memory.cpuToGpu().alloc(MeshCandidate, new_capacity);
        @memset(new_slice, .{ .absolute_position = .{ 0, 0, 0, 0 }, .scale = 0, .face_count = 0, .is_transparent = 0, .face_offset = 0 });

        @memcpy(new_slice[0..old_capacity], self.persistent.slice[0..old_capacity]);

        const info = self.memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, new_slice.ptr);
        const old_slice = self.persistent.slice;

        self.persistent.buffer = info.buffer;
        self.persistent.mapped = new_slice.ptr;
        self.persistent.offset = info.offset;
        self.persistent.slice = new_slice;

        const current_frame_num = self.vk_ctx.frame_number.load(.acquire);
        try self.retired_candidate_slices.append(self.allocator, .{
            .slice = old_slice,
            .graphics_timeline_value = current_frame_num + self.num_in_flight,
        });

        try self.index_pool.grow(io, self.allocator, @intCast(new_capacity));

        self.buffers_version += 1;
    }

    fn tryShrinkMaxAllocatedIndex(self: *IndirectScene, freed_gpu_index: u32) void {
        const current_max = self.max_allocated_index.load(.acquire);
        if (freed_gpu_index + 1 < current_max) return;

        var new_max: u32 = freed_gpu_index;
        while (new_max > 0) : (new_max -= 1) {
            if (self.persistent.mapped[new_max - 1].face_count != 0) break;
        }

        self.max_allocated_index.store(new_max, .release);
    }

    fn createMeshDataDescriptorResources(self: *IndirectScene) !void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "createMeshDataDescriptorResources" });
        defer zone.end();
        if (self.mesh_data_descriptor_set_layout == .null_handle) {
            const binding = vk.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .vertex_bit = true }, .p_immutable_samplers = null };
            self.mesh_data_descriptor_set_layout = try self.dev.createDescriptorSetLayout(&.{ .flags = .{}, .binding_count = 1, .p_bindings = (&binding)[0..1] }, &self.vk_ctx.vkalloc);
        }

        const pool_size = vk.DescriptorPoolSize{ .type = .storage_buffer, .descriptor_count = @intCast(VulkanContext.max_frames_in_flight) };
        try core.createFrameDescriptorPool(self.dev, self.allocator, &self.vk_ctx.vkalloc, &self.mesh_data_descriptor_pool, self.mesh_data_descriptor_set_layout, &self.mesh_data_descriptor_sets_per_frame, (&pool_size)[0..1]);

        for (0..VulkanContext.max_frames_in_flight) |i| self.updateMeshDataDescriptorSet(@intCast(i));
    }

    fn updateMeshDataDescriptorSet(self: *IndirectScene, frame_idx: u32) void {
        const info: vk.DescriptorBufferInfo = .{
            .buffer = self.frame_buffers.items[frame_idx].mesh_data,
            .offset = self.frame_buffers.items[frame_idx].mesh_data_offset,
            .range = self.draw_capacity * draw_type_count * @sizeOf(MeshData),
        };
        self.dev.updateDescriptorSets((&core.bufferWriteDescriptorSet(self.mesh_data_descriptor_sets_per_frame[frame_idx], 0, .storage_buffer, &info))[0..1], null);
    }

    fn destroyMeshDataDescriptorResources(self: *IndirectScene) void {
        if (self.mesh_data_descriptor_pool != .null_handle) {
            self.dev.destroyDescriptorPool(self.mesh_data_descriptor_pool, &self.vk_ctx.vkalloc);
            self.mesh_data_descriptor_pool = .null_handle;
        }
        if (self.mesh_data_descriptor_sets_per_frame.len > 0) {
            self.allocator.free(self.mesh_data_descriptor_sets_per_frame);
            self.mesh_data_descriptor_sets_per_frame = &.{};
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "GpuRegionAllocator checkAllAllocationFailures" {
    const allocFn = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var allocator = try GpuRegionAllocator.init(alloc, alloc, 1024 * 1024);
            allocator.deinit(alloc);
        }
    }.run;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocFn, .{});
}

test "MeshData size" {
    try std.testing.expectEqual(@as(usize, 16), @alignOf(MeshData));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(MeshData));
}
