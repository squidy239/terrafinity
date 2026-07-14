const std = @import("std");
const vk = @import("vulkan");
const DeviceProxy = vk.DeviceProxy;
const tracy = @import("tracy");

const log = std.log.scoped(.vulkan_backing_allocator);

/// Represents a single VkBuffer allocation and its associated resources.
pub const GpuBlock = struct {
    memory: vk.DeviceMemory,
    buffer: vk.Buffer,
    cpu_ptr: []u8,
    gpu_address: vk.DeviceAddress,
    pool: MemoryPool,
};

pub const MemoryPool = enum {
    gpu_only,
    cpu_to_gpu,
};

/// A direct backing allocator that creates one VkBuffer per allocation and
/// destroys it on free. No sub-allocation, no free list — each allocation
/// maps 1:1 to a VkBuffer and its backing VkDeviceMemory.
pub const VulkanBackingAllocator = struct {
    dev: DeviceProxy,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    blocks: [std.meta.fields(MemoryPool).len]std.AutoHashMapUnmanaged(usize, GpuBlock) = .{ .{}, .{} },
    meta_allocator: std.mem.Allocator,

    pub fn init(dev: DeviceProxy, mem_props: vk.PhysicalDeviceMemoryProperties, io: std.Io, meta_allocator: std.mem.Allocator) VulkanBackingAllocator {
        return .{
            .dev = dev,
            .mem_props = mem_props,
            .io = io,
            .meta_allocator = meta_allocator,
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

    pub fn getDeviceAddress(self: *VulkanBackingAllocator, pool: MemoryPool, ptr: *anyopaque) vk.DeviceAddress {
        return self.getBlock(pool, ptr).gpu_address;
    }

    pub fn getBufferAndOffset(self: *VulkanBackingAllocator, pool: MemoryPool, ptr: *anyopaque) struct { buffer: vk.Buffer, offset: vk.DeviceSize } {
        return .{ .buffer = self.getBlock(pool, ptr).buffer, .offset = 0 };
    }

    fn getBlock(self: *VulkanBackingAllocator, pool: MemoryPool, ptr: *anyopaque) GpuBlock {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        return self.blocks[@intFromEnum(pool)].get(@intFromPtr(ptr)) orelse
            std.debug.panic("Pointer 0x{x} is not part of any VulkanBackingAllocator block", .{@intFromPtr(ptr)});
    }

    fn findMemoryType(self: *const VulkanBackingAllocator, type_filter: u32, required_properties: vk.MemoryPropertyFlags) !u32 {
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |memory_type, index| {
            const is_supported = type_filter & (@as(u32, 1) << @as(u5, @truncate(index))) != 0;
            const has_properties = memory_type.property_flags.contains(required_properties);
            if (is_supported and has_properties) return @intCast(index);
        }
        return error.MemoryTypeNotFound;
    }

    fn destroyBlockResources(self: *VulkanBackingAllocator, block: GpuBlock) void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "destroyBlockResources" });
        defer zone.end();

        self.dev.destroyBuffer(block.buffer, null);

        if (block.pool == .cpu_to_gpu) self.dev.unmapMemory(block.memory);
        self.dev.freeMemory(block.memory, null);

        if (block.pool == .gpu_only) self.meta_allocator.free(block.cpu_ptr);
    }

    fn allocBlock(self: *VulkanBackingAllocator, pool: MemoryPool, len: usize) ![]u8 {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "VulkanBackingAllocator.allocBlock" });
        defer zone.end();

        const buffer, const memory, const mem_size = try self.createBufferAndMemory(pool, len);
        errdefer self.dev.freeMemory(memory, null);
        errdefer self.dev.destroyBuffer(buffer, null);

        const cpu_ptr: []u8 = if (pool == .cpu_to_gpu) blk: {
            const mapped: [*]u8 = @ptrCast(try self.dev.mapMemory(memory, 0, mem_size, .{}));
            break :blk mapped[0..mem_size];
        } else try self.meta_allocator.alloc(u8, mem_size);
        errdefer {
            if (pool == .cpu_to_gpu) self.dev.unmapMemory(memory) else self.meta_allocator.free(cpu_ptr);
        }

        const block: GpuBlock = .{
            .memory = memory,
            .buffer = buffer,
            .cpu_ptr = cpu_ptr,
            .gpu_address = self.dev.getBufferDeviceAddress(&.{ .buffer = buffer }),
            .pool = pool,
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.blocks[@intFromEnum(pool)].put(self.meta_allocator, @intFromPtr(block.cpu_ptr.ptr), block);

        return cpu_ptr;
    }

    fn createBufferAndMemory(self: *VulkanBackingAllocator, pool: MemoryPool, len: usize) !struct { vk.Buffer, vk.DeviceMemory, usize } {
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
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        };

        const buffer = try self.dev.createBuffer(&buffer_info, null);
        errdefer self.dev.destroyBuffer(buffer, null);

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
        }, null);
        try self.dev.bindBufferMemory(buffer, memory, 0);

        return .{ buffer, memory, mem_reqs.size };
    }

    fn freeBlock(self: *VulkanBackingAllocator, pool: MemoryPool, buf: []u8) void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "VulkanBackingAllocator.freeBlock" });
        defer zone.end();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const fetch_result = self.blocks[@intFromEnum(pool)].fetchRemove(@intFromPtr(buf.ptr)) orelse
            std.debug.panic("VulkanBackingAllocator.freeBlock: Double-free or invalid pointer free detected on: {*}", .{buf.ptr});
        self.destroyBlockResources(fetch_result.value);
    }
};

fn allocGpuOnly(ctx: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const self: *VulkanBackingAllocator = @ptrCast(@alignCast(ctx));
    const slice = self.allocBlock(.gpu_only, len) catch |err| {
        log.err("VulkanBackingAllocator: allocGpuOnly of size {d} failed: {any}", .{ len, err });
        return null;
    };
    return slice.ptr;
}

fn allocCpuToGpu(ctx: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const self: *VulkanBackingAllocator = @ptrCast(@alignCast(ctx));
    const slice = self.allocBlock(.cpu_to_gpu, len) catch |err| {
        log.err("VulkanBackingAllocator: allocCpuToGpu of size {d} failed: {any}", .{ len, err });
        return null;
    };
    return slice.ptr;
}

fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

fn freeGpuOnly(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    const self: *VulkanBackingAllocator = @ptrCast(@alignCast(ctx));
    self.freeBlock(.gpu_only, buf);
}

fn freeCpuToGpu(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    const self: *VulkanBackingAllocator = @ptrCast(@alignCast(ctx));
    self.freeBlock(.cpu_to_gpu, buf);
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
