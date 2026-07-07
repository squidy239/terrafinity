const std = @import("std");
const vk = @import("vulkan");
const DeviceProxy = vk.DeviceProxy;
const tracy = @import("tracy");

const log = std.log.scoped(.vulkan_backing_allocator);

/// GpuBlock represents a discrete block of device memory allocated from Vulkan.
/// It tracks both GPU and CPU-accessible pointers.
pub const GpuBlock = struct {
    // 64-bit fields grouped first to ensure optimal alignment with zero padding overhead
    memory: vk.DeviceMemory,
    buffer: vk.Buffer,
    size: usize, // Aligned len requested by the caller
    alloc_size: usize, // Total allocated size (including alignment padding)
    raw_cpu_ptr: [*]u8, // CPU-accessible mapped pointer (unaligned)
    cpu_ptr: [*]u8, // Aligned CPU-accessible pointer returned to the caller
    gpu_address: vk.DeviceAddress,
    pool: MemoryPool,
    alignment: std.mem.Alignment,
};

comptime {
    // Compile-time verification of GpuBlock field layout and alignment efficiency.
    // Grouping 64-bit pointers and integers first minimizes struct packing padding.
    if (@sizeOf(GpuBlock) > 128) {
        @compileError("GpuBlock size is unexpectedly large; check member layouts.");
    }
}

pub const MemoryPool = enum {
    gpu_only, // DEVICE_LOCAL (Fast GPU access, shadow-allocated for CPU-tracking allocator compatibility)
    cpu_to_gpu, // HOST_VISIBLE | HOST_COHERENT
};

/// VulkanBackingAllocator is a thread-safe backing allocator for Vulkan memory resources.
/// It implements the Zig Allocator VTable interface and behaves like a system page allocator,
/// handling large allocation granularities (e.g. >= 4KB pages) on top of which higher-level
/// allocators can be layered.
///
/// Thread safety is guaranteed using std.Io.Mutex. Using uncancelable locks prevents thread
/// cancellation signals from leaving Vulkan allocator states or metadata tracking lists corrupted.
pub const VulkanBackingAllocator = struct {
    dev: DeviceProxy,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    io: std.Io,

    mutex: std.Io.Mutex = .init,

    // Store active blocks and inactive cached free blocks in arrays indexed by MemoryPool.
    blocks: [std.meta.fields(MemoryPool).len]std.ArrayListUnmanaged(GpuBlock) = .{ .empty, .empty },
    free_blocks: [std.meta.fields(MemoryPool).len]std.ArrayListUnmanaged(GpuBlock) = .{ .empty, .empty },

    meta_allocator: std.mem.Allocator, // Standard CPU allocator for tracking metadata

    // Minimum page size alignment to act like a page allocator
    pub const min_page_size: usize = 4096;

    comptime {
        // Enforce that min_page_size is a power of two to guarantee correct behavior of std.mem.alignForward
        if (!std.math.isPowerOfTwo(min_page_size)) {
            @compileError("min_page_size must be a power of two for correct alignment math.");
        }
    }

    pub fn init(dev: DeviceProxy, mem_props: vk.PhysicalDeviceMemoryProperties, io: std.Io, meta_allocator: std.mem.Allocator) VulkanBackingAllocator {
        return .{
            .dev = dev,
            .mem_props = mem_props,
            .io = io,
            .meta_allocator = meta_allocator,
        };
    }

    pub fn deinit(self: *VulkanBackingAllocator) void {
        for (&self.blocks) |*list| {
            for (list.items) |block| {
                self.destroyBlockResources(block, @returnAddress());
            }
            list.deinit(self.meta_allocator);
        }
        for (&self.free_blocks) |*list| {
            for (list.items) |block| {
                self.destroyBlockResources(block, @returnAddress());
            }
            list.deinit(self.meta_allocator);
        }
    }

    // Standard Zig Allocator VTable implementation
    pub fn allocator(self: *VulkanBackingAllocator, pool: MemoryPool) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = switch (pool) {
                .gpu_only => &gpu_only_vtable,
                .cpu_to_gpu => &cpu_to_gpu_vtable,
            },
        };
    }

    pub fn getDeviceAddress(self: *VulkanBackingAllocator, ptr: *anyopaque) vk.DeviceAddress {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const ptr_val = @intFromPtr(ptr);
        // Binary search the sorted blocks for O(log N) lookups
        if (self.findBlockBinarySearch(ptr_val)) |block| {
            const base = @intFromPtr(block.cpu_ptr);
            const offset = ptr_val - base;
            return block.gpu_address + offset;
        }
        std.debug.panic("Pointer 0x{x} is not part of any VulkanBackingAllocator block", .{ptr_val});
    }

    pub fn getBufferAndOffset(self: *VulkanBackingAllocator, ptr: *anyopaque) struct { buffer: vk.Buffer, offset: vk.DeviceSize } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const ptr_val = @intFromPtr(ptr);
        if (self.findBlockBinarySearch(ptr_val)) |block| {
            const base = @intFromPtr(block.raw_cpu_ptr);
            const offset = ptr_val - base;
            return .{ .buffer = block.buffer, .offset = @intCast(offset) };
        }
        std.debug.panic("Pointer 0x{x} is not part of any VulkanBackingAllocator block", .{ptr_val});
    }

    pub inline fn findBlockBinarySearch(self: *const VulkanBackingAllocator, ptr_val: usize) ?GpuBlock {
        for (self.blocks) |list| {
            if (searchList(list.items, ptr_val)) |block| return block;
        }
        return null;
    }

    inline fn searchList(list: []const GpuBlock, ptr_val: usize) ?GpuBlock {
        if (list.len == 0) return null;
        var low: usize = 0;
        var high: usize = list.len;
        while (low < high) {
            const mid = low + ((high - low) >> 1);
            const block = list[mid];
            const base = @intFromPtr(block.cpu_ptr);
            if (ptr_val >= base and ptr_val < base + block.size) {
                return block;
            } else if (ptr_val < base) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return null;
    }

    fn findBlockIndex(list: []const GpuBlock, ptr_val: usize) ?usize {
        if (list.len == 0) return null;
        var low: usize = 0;
        var high: usize = list.len;
        while (low < high) {
            const mid = low + ((high - low) >> 1);
            const block = list[mid];
            const base = @intFromPtr(block.cpu_ptr);
            if (ptr_val == base) {
                return mid;
            } else if (ptr_val < base) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return null;
    }

    fn insertBlockSorted(self: *VulkanBackingAllocator, block: GpuBlock) !void {
        const list = &self.blocks[@intFromEnum(block.pool)];
        // Binary search to find the insertion point to keep list sorted by cpu_ptr
        const ptr_val = @intFromPtr(block.cpu_ptr);
        var low: usize = 0;
        var high: usize = list.items.len;
        while (low < high) {
            const mid = low + ((high - low) >> 1);
            const item_ptr_val = @intFromPtr(list.items[mid].cpu_ptr);
            if (item_ptr_val > ptr_val) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        try list.insert(self.meta_allocator, low, block);
    }

    fn findMemoryType(self: *const VulkanBackingAllocator, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
            if ((type_filter & (@as(u32, 1) << @as(u5, @truncate(i)))) != 0 and (mem_type.property_flags.toInt() & properties.toInt()) == properties.toInt()) {
                return @intCast(i);
            }
        }
        return error.MemoryTypeNotFound;
    }

    fn destroyBlockResources(self: *VulkanBackingAllocator, block: GpuBlock, ret_addr: usize) void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "destroyBlockResources" });
        defer zone.end();

        if (block.pool == .gpu_only) {
            self.meta_allocator.rawFree(block.raw_cpu_ptr[0..block.alloc_size], block.alignment, ret_addr);
        } else {
            self.dev.unmapMemory(block.memory);
        }
        self.dev.destroyBuffer(block.buffer, null);
        self.dev.freeMemory(block.memory, null);
    }

    fn allocBlock(self: *VulkanBackingAllocator, pool: MemoryPool, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ![*]u8 {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "VulkanBackingAllocator.allocBlock" });
        defer zone.end();

        // Enforce large page size alignment (4096 bytes or greater) to act like a page allocator
        const aligned_len = std.mem.alignForward(usize, len, min_page_size);

        // Lock the mutex for the entirety of allocation/retrieval to ensure thread-safety
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const free_list = &self.free_blocks[@intFromEnum(pool)];

        // 1. Check if we have an inactive/cached block that satisfies the request
        for (free_list.items, 0..) |block, idx| {
            if (block.size >= aligned_len and block.alignment.toByteUnits() >= ptr_align.toByteUnits()) {
                const hit_zone = tracy.Zone.begin(.{ .src = @src(), .name = "allocBlock_cache_hit" });
                defer hit_zone.end();

                const matched_block = free_list.swapRemove(idx);
                try self.insertBlockSorted(matched_block);
                return matched_block.cpu_ptr;
            }
        }

        const miss_zone = tracy.Zone.begin(.{ .src = @src(), .name = "allocBlock_cache_miss_real_alloc" });
        defer miss_zone.end();

        // Over-allocate memory by adding the requested ptr_align to guarantee we can satisfy it
        const alloc_size = aligned_len + ptr_align.toByteUnits();

        // 2. Create Buffer with support for bidirectional GPU-to-CPU and CPU-to-GPU memory transfers
        const buffer = try self.dev.createBuffer(&.{
            .flags = .{},
            .size = alloc_size,
            .usage = .{
                .transfer_src_bit = true,
                .transfer_dst_bit = true,
                .shader_device_address_bit = true,
                .storage_buffer_bit = true,
                .indirect_buffer_bit = (pool == .cpu_to_gpu),
            },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        }, null);
        errdefer self.dev.destroyBuffer(buffer, null);

        // 3. Get Memory Requirements
        const mem_reqs = self.dev.getBufferMemoryRequirements(buffer);

        // 4. Find Memory Type
        const req_flags = switch (pool) {
            .gpu_only => vk.MemoryPropertyFlags{ .device_local_bit = true },
            .cpu_to_gpu => vk.MemoryPropertyFlags{ .host_visible_bit = true, .host_coherent_bit = true },
        };
        const mem_type = try self.findMemoryType(mem_reqs.memory_type_bits, req_flags);

        // 5. Allocate Device Memory with Buffer Device Address bit enabled
        var alloc_flags = vk.MemoryAllocateFlagsInfo{
            .flags = .{ .device_address_bit = true },
            .device_mask = 0,
        };
        const memory = try self.dev.allocateMemory(&.{
            .allocation_size = mem_reqs.size,
            .memory_type_index = mem_type,
            .p_next = @ptrCast(&alloc_flags),
        }, null);
        errdefer self.dev.freeMemory(memory, null);

        // 6. Bind buffer memory
        try self.dev.bindBufferMemory(buffer, memory, 0);

        // 7. Get GPU Device Address
        const gpu_address = self.dev.getBufferDeviceAddress(&.{ .buffer = buffer });

        // 8. Map or allocate shadow memory
        var raw_cpu_ptr: [*]u8 = undefined;
        if (pool == .cpu_to_gpu) {
            const mapped = try self.dev.mapMemory(memory, 0, mem_reqs.size, .{});
            raw_cpu_ptr = @ptrCast(mapped);
        } else {
            raw_cpu_ptr = self.meta_allocator.rawAlloc(mem_reqs.size, ptr_align, ret_addr) orelse return error.OutOfMemory;
            if (std.debug.runtime_safety) {
                @memset(raw_cpu_ptr[0..mem_reqs.size], 0xcc);
            }
        }
        errdefer {
            if (pool == .gpu_only) {
                self.meta_allocator.rawFree(raw_cpu_ptr[0..mem_reqs.size], ptr_align, ret_addr);
            } else {
                self.dev.unmapMemory(memory);
            }
        }

        // Align the returned pointer forward to satisfy ptr_align
        const cpu_ptr_addr = std.mem.alignForward(usize, @intFromPtr(raw_cpu_ptr), ptr_align.toByteUnits());
        const cpu_ptr: [*]u8 = @ptrFromInt(cpu_ptr_addr);
        const offset = cpu_ptr_addr - @intFromPtr(raw_cpu_ptr);
        const aligned_gpu_address = gpu_address + offset;

        // Verify that pointer calculations do not exceed total mapped size bounds
        std.debug.assert(offset + aligned_len <= mem_reqs.size);
        std.debug.assert(std.mem.isAligned(cpu_ptr_addr, ptr_align.toByteUnits()));

        const block = GpuBlock{
            .memory = memory,
            .buffer = buffer,
            .size = aligned_len,
            .alloc_size = mem_reqs.size,
            .raw_cpu_ptr = raw_cpu_ptr,
            .cpu_ptr = cpu_ptr,
            .gpu_address = aligned_gpu_address,
            .pool = pool,
            .alignment = ptr_align,
        };

        try self.insertBlockSorted(block);
        return cpu_ptr;
    }

    fn freeBlock(self: *VulkanBackingAllocator, pool: MemoryPool, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "VulkanBackingAllocator.freeBlock" });
        defer zone.end();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = buf_align;

        const list = &self.blocks[@intFromEnum(pool)];
        const free_list = &self.free_blocks[@intFromEnum(pool)];

        // Find the block from its cpu_ptr using O(log N) binary search
        if (findBlockIndex(list.items, @intFromPtr(buf.ptr))) |idx| {
            const block = list.orderedRemove(idx);
            // Append to free list instead of destroying resources to avoid kernel/driver allocation stalls
            free_list.append(self.meta_allocator, block) catch |err| {
                log.warn("VulkanBackingAllocator: failed to cache freed block: {any}, destroying block resources", .{err});
                self.destroyBlockResources(block, ret_addr);
            };
        } else {
            std.debug.panic("VulkanBackingAllocator.freeBlock: Double-free or invalid pointer free detected on: {*}", .{buf.ptr});
        }
    }
};

fn allocGpuOnly(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *VulkanBackingAllocator = @ptrCast(@alignCast(ctx));
    return self.allocBlock(.gpu_only, len, ptr_align, ret_addr) catch |err| {
        log.err("VulkanBackingAllocator: allocGpuOnly of size {d} failed: {any}", .{ len, err });
        return null;
    };
}

fn allocCpuToGpu(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *VulkanBackingAllocator = @ptrCast(@alignCast(ctx));
    return self.allocBlock(.cpu_to_gpu, len, ptr_align, ret_addr) catch |err| {
        log.err("VulkanBackingAllocator: allocCpuToGpu of size {d} failed: {any}", .{ len, err });
        return null;
    };
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = buf;
    _ = buf_align;
    _ = new_len;
    _ = ret_addr;
    return false; // Resize in-place not supported by Vulkan buffers
}

fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = buf;
    _ = buf_align;
    _ = new_len;
    _ = ret_addr;
    return null; // Remap not supported
}

fn freeGpuOnly(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    const self: *VulkanBackingAllocator = @ptrCast(@alignCast(ctx));
    self.freeBlock(.gpu_only, buf, buf_align, ret_addr);
}

fn freeCpuToGpu(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    const self: *VulkanBackingAllocator = @ptrCast(@alignCast(ctx));
    self.freeBlock(.cpu_to_gpu, buf, buf_align, ret_addr);
}

const gpu_only_vtable = std.mem.Allocator.VTable{
    .alloc = allocGpuOnly,
    .resize = resize,
    .remap = remap,
    .free = freeGpuOnly,
};

const cpu_to_gpu_vtable = std.mem.Allocator.VTable{
    .alloc = allocCpuToGpu,
    .resize = resize,
    .remap = remap,
    .free = freeCpuToGpu,
};
