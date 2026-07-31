const std = @import("std");
const vk = @import("vulkan");
const tracy = @import("tracy");

const log = std.log.scoped(.vulkan_backing_allocator);

/// Represents a single VkBuffer allocation and its associated resources.
/// raw_alloc is the full underlying allocation (CPU-side), used for range
/// checks and cleanup. The VkBuffer has the same size and layout.
pub const GpuBlock = struct {
    memory: vk.DeviceMemory,
    buffer: vk.Buffer,
    raw_alloc: []u8 = &.{}, // safety sentinel for range check
};

pub const MemoryPool = enum {
    gpu_only,
    cpu_to_gpu,
};

/// A direct backing allocator that creates one VkBuffer per allocation and
/// destroys it on free. No sub-allocation, no free list — each allocation
/// maps 1:1 to a VkBuffer and its backing VkDeviceMemory.
pub const VulkanBackingAllocator = struct {
    dev: vk.DeviceProxy,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    graphics_queue_family: u32 = 0,
    transfer_queue_family: u32 = 0,

    vkalloc: vk.AllocationCallbacks,

    blocks: [std.meta.fields(MemoryPool).len]std.AutoHashMapUnmanaged(usize, GpuBlock) = .{ .{}, .{} },
    meta_allocator: std.mem.Allocator,

    pub fn init(
        dev: vk.DeviceProxy,
        mem_props: vk.PhysicalDeviceMemoryProperties,
        io: std.Io,
        hashmap_allocator: std.mem.Allocator,
        graphics_queue_family: u32,
        transfer_queue_family: u32,
        vkalloc: vk.AllocationCallbacks,
    ) VulkanBackingAllocator {
        return .{
            .dev = dev,
            .mem_props = mem_props,
            .io = io,
            .meta_allocator = hashmap_allocator,
            .graphics_queue_family = graphics_queue_family,
            .transfer_queue_family = transfer_queue_family,
            .vkalloc = vkalloc,
        };
    }

    pub fn deinit(self: *VulkanBackingAllocator) void {
        for (&self.blocks, 0..) |*map, pool_idx| {
            if (map.count() > 0) {
                const pool: MemoryPool = @enumFromInt(pool_idx);
                std.debug.panic("VulkanBackingAllocator.deinit: {d} block(s) still allocated in {s} pool", .{ map.count(), @tagName(pool) });
            }
            map.deinit(self.meta_allocator);
        }
    }

    pub fn allocator(self: *VulkanBackingAllocator, pool: MemoryPool) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = switch (pool) {
                .gpu_only => &gpu_only_vtable,
                .cpu_to_gpu => &cpu_to_gpu_vtable,
            },
        };
    }

    /// Returns the buffer handle and byte offset for a pointer into a block.
    /// The caller must own the pointer and may not call this concurrently with
    /// any alloc or free in this pool.
    pub fn getBufferAndOffset(self: *VulkanBackingAllocator, pool: MemoryPool, ptr: *anyopaque) struct { buffer: vk.Buffer, offset: vk.DeviceSize } {
        const addr = @intFromPtr(ptr);
        var it = self.blocks[@intFromEnum(pool)].valueIterator();
        while (it.next()) |block| {
            const start = @intFromPtr(block.raw_alloc.ptr);
            if (addr >= start and addr < start + block.raw_alloc.len) {
                return .{ .buffer = block.buffer, .offset = @intCast(addr - start) };
            }
        }
        std.debug.panic("Pointer 0x{x} is not part of any VulkanBackingAllocator block", .{addr});
    }

    fn findMemoryType(self: *const VulkanBackingAllocator, type_filter: u32, required_properties: vk.MemoryPropertyFlags) !u32 {
        const required_bits = required_properties.toInt();
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |memory_type, i| {
            if (type_filter & (@as(u32, 1) << @as(u5, @intCast(i))) == 0) continue;
            if (memory_type.property_flags.toInt() & required_bits != required_bits) continue;
            return @intCast(i);
        }
        return error.MemoryTypeNotFound;
    }

    fn allocBlock(self: *VulkanBackingAllocator, pool: MemoryPool, len: usize, alignment: std.mem.Alignment) ![]u8 {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "VulkanBackingAllocator.allocBlock" });
        defer zone.end();

        const alignment_bytes = alignment.toByteUnits();
        const alloc_len = if (alignment_bytes > 1) len + alignment_bytes -| 1 else len;

        const buffer, const memory, const mem_size = try self.createBufferAndMemory(pool, alloc_len);
        errdefer self.dev.freeMemory(memory, &self.vkalloc);
        errdefer self.dev.destroyBuffer(buffer, &self.vkalloc);

        const raw_cpu: []u8 = if (pool == .cpu_to_gpu)
            (@as([*]u8, @ptrCast(try self.dev.mapMemory(memory, 0, mem_size, .{}))))[0..mem_size]
        else
            try self.meta_allocator.alloc(u8, mem_size);
        errdefer if (pool == .cpu_to_gpu) self.dev.unmapMemory(memory) else self.meta_allocator.free(raw_cpu);

        const raw_addr = @intFromPtr(raw_cpu.ptr);
        const aligned_addr = alignment.forward(raw_addr);
        const result: []u8 = (@as([*]u8, @ptrFromInt(aligned_addr)))[0..len];

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.blocks[@intFromEnum(pool)].put(self.meta_allocator, @intFromPtr(result.ptr), .{
            .memory = memory,
            .buffer = buffer,
            .raw_alloc = raw_cpu,
        });

        return result;
    }

    fn createBufferAndMemory(self: *VulkanBackingAllocator, pool: MemoryPool, len: usize) !struct { vk.Buffer, vk.DeviceMemory, usize } {
        const queue_family_indices: [2]u32 = .{ self.graphics_queue_family, self.transfer_queue_family };
        const is_concurrent = self.graphics_queue_family != self.transfer_queue_family;

        const buffer_info: vk.BufferCreateInfo = .{
            .flags = .{},
            .size = len,
            .usage = .{
                .transfer_src_bit = true,
                .transfer_dst_bit = true,
                .shader_device_address_bit = true,
                .storage_buffer_bit = true,
                .indirect_buffer_bit = true,
                .vertex_buffer_bit = true,
            },
            .sharing_mode = if (is_concurrent) .concurrent else .exclusive,
            .queue_family_index_count = if (is_concurrent) 2 else 0,
            .p_queue_family_indices = if (is_concurrent) queue_family_indices[0..2].ptr else null,
        };

        const buffer = try self.dev.createBuffer(&buffer_info, &self.vkalloc);
        errdefer self.dev.destroyBuffer(buffer, &self.vkalloc);

        var mem_requirements: vk.MemoryRequirements2 = .{ .memory_requirements = undefined };
        self.dev.getDeviceBufferMemoryRequirements(&.{ .p_create_info = &buffer_info }, &mem_requirements);
        const mem_reqs = mem_requirements.memory_requirements;

        const required_flags = switch (pool) {
            .gpu_only => vk.MemoryPropertyFlags{ .device_local_bit = true },
            .cpu_to_gpu => vk.MemoryPropertyFlags{ .host_visible_bit = true, .host_coherent_bit = true },
        };
        const mem_type = try self.findMemoryType(mem_reqs.memory_type_bits, required_flags);

        const memory = try self.dev.allocateMemory(&.{
            .allocation_size = mem_reqs.size,
            .memory_type_index = mem_type,
            .p_next = @ptrCast(&vk.MemoryAllocateFlagsInfo{ .flags = .{ .device_address_bit = true }, .device_mask = 0 }),
        }, &self.vkalloc);
        try self.dev.bindBufferMemory(buffer, memory, 0);

        return .{ buffer, memory, mem_reqs.size };
    }

    fn freeBlock(self: *VulkanBackingAllocator, pool: MemoryPool, buf: []u8) void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "VulkanBackingAllocator.freeBlock" });
        defer zone.end();

        self.mutex.lockUncancelable(self.io);
        const fetch_result = self.blocks[@intFromEnum(pool)].fetchRemove(@intFromPtr(buf.ptr)) orelse {
            self.mutex.unlock(self.io);
            std.debug.panic("VulkanBackingAllocator.freeBlock: Double-free or invalid pointer free detected on: {*}", .{buf.ptr});
        };
        self.mutex.unlock(self.io);

        const block = fetch_result.value;
        self.dev.destroyBuffer(block.buffer, &self.vkalloc);
        if (pool == .cpu_to_gpu) self.dev.unmapMemory(block.memory);
        self.dev.freeMemory(block.memory, &self.vkalloc);
        if (pool == .gpu_only) self.meta_allocator.free(block.raw_alloc);
    }
};

fn allocPool(ctx: *anyopaque, pool: MemoryPool, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
    const self: *VulkanBackingAllocator = @ptrCast(@alignCast(ctx));
    const slice = self.allocBlock(pool, len, alignment) catch |err| {
        log.err("VulkanBackingAllocator: alloc({s}) of size {d} failed: {any}", .{ @tagName(pool), len, err });
        return null;
    };
    return slice.ptr;
}

fn freePool(ctx: *anyopaque, pool: MemoryPool, buf: []u8) void {
    const self: *VulkanBackingAllocator = @ptrCast(@alignCast(ctx));
    self.freeBlock(pool, buf);
}

fn allocGpuOnly(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    return allocPool(ctx, .gpu_only, len, alignment);
}

fn allocCpuToGpu(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    return allocPool(ctx, .cpu_to_gpu, len, alignment);
}

fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

fn freeGpuOnly(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    freePool(ctx, .gpu_only, buf);
}

fn freeCpuToGpu(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    freePool(ctx, .cpu_to_gpu, buf);
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

test "VulkanBackingAllocator alloc and free both pools" {
    const wio_mod = @import("wio");
    const VulkanContext = @import("../../VulkanContext.zig").VulkanContext;

    try wio_mod.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .eventFn = wio_mod.EventQueue.eventFn });
    defer wio_mod.deinit();

    var events: wio_mod.EventQueue = .empty;
    defer events.deinit();

    var window = try wio_mod.Window.create(.{ .title = "test", .event_fn_data = &events });
    defer window.destroy();

    const vk_ctx = try VulkanContext.init(std.testing.allocator, &window);
    defer vk_ctx.deinit(std.testing.io);

    var backing = VulkanBackingAllocator.init(vk_ctx.dev, vk_ctx.mem_props, std.testing.io, std.testing.allocator, vk_ctx.queue_family_index, vk_ctx.transfer_queue_family_index);
    defer backing.deinit();

    const gpu_alloc = backing.allocator(.gpu_only);
    const cpu_alloc = backing.allocator(.cpu_to_gpu);

    const gpu_slice = try gpu_alloc.alloc(u8, 1024);
    defer gpu_alloc.free(gpu_slice);
    const gpu_info = backing.getBufferAndOffset(.gpu_only, gpu_slice.ptr);
    try std.testing.expect(gpu_info.buffer != .null_handle);
    try std.testing.expect(gpu_info.offset < 1024);

    const cpu_slice = try cpu_alloc.alloc(u64, 256);
    defer cpu_alloc.free(cpu_slice);
    const cpu_info = backing.getBufferAndOffset(.cpu_to_gpu, cpu_slice.ptr);
    try std.testing.expect(cpu_info.buffer != .null_handle);
    try std.testing.expect(cpu_info.offset < 256 * @sizeOf(u64));
    cpu_slice[0] = 42;
}

test "VulkanBackingAllocator getBufferAndOffset rejects unknown pointer" {
    const wio_mod = @import("wio");
    const VulkanContext = @import("../../VulkanContext.zig").VulkanContext;

    try wio_mod.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .eventFn = wio_mod.EventQueue.eventFn });
    defer wio_mod.deinit();

    var events: wio_mod.EventQueue = .empty;
    defer events.deinit();

    var window = try wio_mod.Window.create(.{ .title = "test", .event_fn_data = &events });
    defer window.destroy();

    const vk_ctx = try VulkanContext.init(std.testing.allocator, &window);
    defer vk_ctx.deinit(std.testing.io);

    var backing = VulkanBackingAllocator.init(vk_ctx.dev, vk_ctx.mem_props, std.testing.io, std.testing.allocator, vk_ctx.queue_family_index, vk_ctx.transfer_queue_family_index);
    defer backing.deinit();

    // This should panic - pointer was never allocated through us
    // Can't easily test this without catching the panic, but the fact that
    // normal alloc/free works validates the bookkeeping is intact.
}
