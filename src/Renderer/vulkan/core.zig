const std = @import("std");
const zm = @import("zm");
const tracy = @import("tracy");
const vk = @import("vulkan");

const DeviceProxy = vk.DeviceProxy;
const Frustum = @import("Frustum.zig").Frustum;
const VulkanContext = @import("../../VulkanContext.zig").VulkanContext;

// ---------------------------------------------------------------------------
// Camera
// ---------------------------------------------------------------------------

const near_plane: f32 = 0.01;

pub const Camera = struct {
    front_x: std.atomic.Value(f32) = .init(0),
    front_y: std.atomic.Value(f32) = .init(0),
    front_z: std.atomic.Value(f32) = .init(1),

    pub fn updateFront(self: *Camera, front_vec: @Vector(3, f32)) void {
        self.front_x.store(front_vec[0], .monotonic);
        self.front_y.store(front_vec[1], .monotonic);
        self.front_z.store(front_vec[2], .monotonic);
    }

    pub fn front(self: *const Camera) @Vector(3, f32) {
        return .{
            self.front_x.load(.monotonic),
            self.front_y.load(.monotonic),
            self.front_z.load(.monotonic),
        };
    }

    pub fn computeViewProjection(self: *const Camera, aspect: f32, fov_radians: f32) struct { projview: @Vector(16, f32), frustum: Frustum } {
        const up_vec: zm.vec.Vec3f = .{ .data = .{ 0, 1, 0 } };
        const view = zm.matrix.Mat4f.lookAtRH(
            .{ .data = @Vector(3, f32){ 0, 0, 0 } },
            .{ .data = self.front() },
            up_vec,
        );
        const projection = makeInfReversedZProjRh(fov_radians, aspect, near_plane);
        const projview: @Vector(16, f32) = @bitCast(projection.multiply(view).data);
        return .{ .projview = projview, .frustum = Frustum.extractFrustumPlanes(projview) };
    }
};

fn makeInfReversedZProjRh(fov_y_radians: f32, aspect_w_by_h: f32, z_near: f32) zm.Mat4f {
    const f: f32 = 1.0 / @tan(fov_y_radians / 2.0);
    return .{
        .data = .{
            .{ f / aspect_w_by_h, 0.0, 0.0, 0.0 },
            .{ 0.0, -f, 0.0, 0.0 },
            .{ 0.0, 0.0, 0.0, z_near },
            .{ 0.0, 0.0, -1.0, 0.0 },
        },
    };
}

// ---------------------------------------------------------------------------
// Render targets
// ---------------------------------------------------------------------------

pub const RenderTarget = struct {
    image: vk.Image = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    view: vk.ImageView = .null_handle,
};

pub fn destroyIfValid(dev: DeviceProxy, handle: anytype, vkalloc: *const vk.AllocationCallbacks) void {
    const T = @TypeOf(handle.*);
    if (handle.* == .null_handle) return;
    switch (T) {
        vk.ImageView => dev.destroyImageView(handle.*, vkalloc),
        vk.Image, vk.DeviceMemory => unreachable,
        vk.Pipeline => dev.destroyPipeline(handle.*, vkalloc),
        vk.PipelineLayout => dev.destroyPipelineLayout(handle.*, vkalloc),
        vk.DescriptorSetLayout => dev.destroyDescriptorSetLayout(handle.*, vkalloc),
        vk.Sampler => dev.destroySampler(handle.*, vkalloc),
        else => @compileError("destroyIfValid: unsupported type " ++ @typeName(T)),
    }
    handle.* = .null_handle;
}

fn destroyIfValidImage(dev: DeviceProxy, image: *vk.Image, memory: *vk.DeviceMemory, vkalloc: *const vk.AllocationCallbacks) void {
    if (image.* != .null_handle) {
        dev.destroyImage(image.*, vkalloc);
        image.* = .null_handle;
    }
    if (memory.* != .null_handle) {
        dev.freeMemory(memory.*, vkalloc);
        memory.* = .null_handle;
    }
}

pub fn destroyRenderTarget(dev: DeviceProxy, rt: *RenderTarget, vkalloc: *const vk.AllocationCallbacks) void {
    destroyIfValid(dev, &rt.view, vkalloc);
    destroyIfValidImage(dev, &rt.image, &rt.memory, vkalloc);
}

pub fn imageViewCreateInfo(image: vk.Image, format: vk.Format, aspect: vk.ImageAspectFlags) vk.ImageViewCreateInfo {
    return .{
        .flags = .{},
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
}

pub fn createImageWithMemory(dev: DeviceProxy, mem_props: vk.PhysicalDeviceMemoryProperties, vkalloc: *const vk.AllocationCallbacks, extent: vk.Extent2D, format: vk.Format, usage: vk.ImageUsageFlags, aspect: vk.ImageAspectFlags) !RenderTarget {
    const image_info: vk.ImageCreateInfo = .{
        .image_type = .@"2d",
        .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .format = format,
        .tiling = .optimal,
        .initial_layout = .undefined,
        .usage = usage,
        .sharing_mode = .exclusive,
        .samples = .{ .@"1_bit" = true },
    };
    var mem_reqs2: vk.MemoryRequirements2 = .{
        .memory_requirements = undefined,
    };
    dev.getDeviceImageMemoryRequirements(&.{ .p_create_info = &image_info, .plane_aspect = .{} }, &mem_reqs2);
    const mem_reqs = mem_reqs2.memory_requirements;

    const alloc_info: vk.MemoryAllocateInfo = .{
        .allocation_size = mem_reqs.size,
        .memory_type_index = try findMemoryType(mem_props, mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    };

    var target: RenderTarget = .{};
    errdefer destroyRenderTarget(dev, &target, vkalloc);

    target.memory = try dev.allocateMemory(&alloc_info, vkalloc);
    target.image = try dev.createImage(&image_info, vkalloc);
    try dev.bindImageMemory(target.image, target.memory, 0);
    target.view = try dev.createImageView(&imageViewCreateInfo(target.image, format, aspect), vkalloc);
    return target;
}

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

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
                // gpu_only blocks have no real CPU mapping; their alignment padding is a
                // sentinel artifact of the dummy allocation, so the data always sits at
                // buffer offset 0. cpu_to_gpu blocks share the mapping with the buffer,
                // making the pointer delta the true offset.
                const offset: vk.DeviceSize = if (pool == .gpu_only) 0 else @intCast(addr - start);
                return .{ .buffer = block.buffer, .offset = offset };
            }
        }
        std.debug.panic("Pointer 0x{x} is not part of any VulkanBackingAllocator block", .{addr});
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
        const mem_type = try findMemoryType(self.mem_props, mem_reqs.memory_type_bits, required_flags);

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

pub fn findMemoryType(mem_props: vk.PhysicalDeviceMemoryProperties, type_filter: u32, required_properties: vk.MemoryPropertyFlags) !u32 {
    const required_bits = required_properties.toInt();
    const count = @min(mem_props.memory_type_count, 32);
    for (mem_props.memory_types[0..count], 0..) |memory_type, i| {
        if (type_filter & (@as(u32, 1) << @truncate(i)) == 0) continue;
        if (memory_type.property_flags.toInt() & required_bits != required_bits) continue;
        return @intCast(i);
    }
    return error.MemoryTypeNotFound;
}

fn allocPool(ctx: *anyopaque, pool: MemoryPool, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
    const self: *VulkanBackingAllocator = @ptrCast(@alignCast(ctx));
    const slice = self.allocBlock(pool, len, alignment) catch |err| {
        std.log.err("VulkanBackingAllocator: alloc({s}) of size {d} failed: {any}", .{ @tagName(pool), len, err });
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

// ---------------------------------------------------------------------------
// Barriers
// ---------------------------------------------------------------------------

pub fn makeImageBarrier2(
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_stage: vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage: vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
    aspect: vk.ImageAspectFlags,
) vk.ImageMemoryBarrier2 {
    return .{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        .dst_stage_mask = dst_stage,
        .dst_access_mask = dst_access,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
}

pub fn makeBufferBarrier2(
    buffer: vk.Buffer,
    offset: vk.DeviceSize,
    size: vk.DeviceSize,
    src_stage: vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage: vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
) vk.BufferMemoryBarrier2 {
    return .{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        .dst_stage_mask = dst_stage,
        .dst_access_mask = dst_access,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .buffer = buffer,
        .offset = offset,
        .size = size,
    };
}

/// The barrier slice must outlive the cmdPipelineBarrier2 call below (it is consumed
/// synchronously during recording). Do not extract the DependencyInfo and defer the call.
pub fn pipelineBarrier(cmd: vk.CommandBuffer, dev: DeviceProxy, comptime barrier_type: type, barriers: []const barrier_type) void {
    const info: vk.DependencyInfo = switch (barrier_type) {
        vk.ImageMemoryBarrier2 => .{
            .dependency_flags = .{},
            .memory_barrier_count = 0,
            .p_memory_barriers = null,
            .buffer_memory_barrier_count = 0,
            .p_buffer_memory_barriers = null,
            .image_memory_barrier_count = @intCast(barriers.len),
            .p_image_memory_barriers = barriers.ptr,
        },
        vk.BufferMemoryBarrier2 => .{
            .dependency_flags = .{},
            .memory_barrier_count = 0,
            .p_memory_barriers = null,
            .buffer_memory_barrier_count = @intCast(barriers.len),
            .p_buffer_memory_barriers = barriers.ptr,
            .image_memory_barrier_count = 0,
            .p_image_memory_barriers = null,
        },
        else => @compileError("pipelineBarrier: unsupported type " ++ @typeName(barrier_type)),
    };
    dev.cmdPipelineBarrier2(cmd, &info);
}

// ---------------------------------------------------------------------------
// Descriptors
// ---------------------------------------------------------------------------

pub const null_image_info: [1]vk.DescriptorImageInfo = .{.{ .sampler = .null_handle, .image_view = .null_handle, .image_layout = .undefined }};
pub const null_buffer_info: [1]vk.DescriptorBufferInfo = .{.{ .buffer = .null_handle, .offset = 0, .range = 0 }};
pub const null_buffer_view: [1]vk.BufferView = .{vk.BufferView.null_handle};

pub fn bufferWriteDescriptorSet(dst_set: vk.DescriptorSet, dst_binding: u32, descriptor_type: vk.DescriptorType, buffer_info: *const vk.DescriptorBufferInfo) vk.WriteDescriptorSet {
    return .{
        .dst_set = dst_set,
        .dst_binding = dst_binding,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = descriptor_type,
        .p_image_info = &null_image_info,
        .p_buffer_info = (&buffer_info.*)[0..1],
        .p_texel_buffer_view = &null_buffer_view,
    };
}

pub fn imageWriteDescriptorSet(dst_set: vk.DescriptorSet, dst_binding: u32, image_info: *const vk.DescriptorImageInfo) vk.WriteDescriptorSet {
    return .{
        .dst_set = dst_set,
        .dst_binding = dst_binding,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = (&image_info.*)[0..1],
        .p_buffer_info = &null_buffer_info,
        .p_texel_buffer_view = &null_buffer_view,
    };
}

// ---------------------------------------------------------------------------
// Rendering info
// ---------------------------------------------------------------------------

pub fn renderingAttachmentColor(view: vk.ImageView, load_op: vk.AttachmentLoadOp, clear_color: [4]f32) vk.RenderingAttachmentInfo {
    return .{
        .s_type = .rendering_attachment_info,
        .image_view = view,
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_view = .null_handle,
        .resolve_image_layout = .undefined,
        .load_op = load_op,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = clear_color } },
    };
}

pub fn renderingAttachmentDepth(view: vk.ImageView, layout: vk.ImageLayout, load_op: vk.AttachmentLoadOp) vk.RenderingAttachmentInfo {
    return .{
        .s_type = .rendering_attachment_info,
        .image_view = view,
        .image_layout = layout,
        .resolve_mode = .{},
        .resolve_image_view = .null_handle,
        .resolve_image_layout = .undefined,
        .load_op = load_op,
        .store_op = if (load_op == .load) .none else .store,
        .clear_value = .{ .depth_stencil = .{ .depth = 0.0, .stencil = 0 } },
    };
}

pub fn renderingInfo(
    extent: vk.Extent2D,
    color_attachments: []const vk.RenderingAttachmentInfo,
    depth_attachment: ?*const vk.RenderingAttachmentInfo,
) vk.RenderingInfo {
    return .{
        .flags = .{},
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = @intCast(color_attachments.len),
        .p_color_attachments = color_attachments.ptr,
        .p_depth_attachment = depth_attachment,
        .p_stencil_attachment = null,
    };
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

pub fn setViewportAndScissor(dev: DeviceProxy, cmd: vk.CommandBuffer, extent: vk.Extent2D) void {
    dev.cmdSetViewport(cmd, 0, (&vk.Viewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0.0,
        .max_depth = 1.0,
    })[0..1]);
    dev.cmdSetScissor(cmd, 0, (&vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    })[0..1]);
}

/// GPU-immediate helper: allocate a one-shot command buffer from a shared transient pool,
/// record, submit on the graphics queue, and wait on a reusable fence. Used for one-off
/// uploads and buffer copies that must complete synchronously.
pub const SingleTime = struct {
    dev: DeviceProxy,
    pool: vk.CommandPool,
    queue: vk.Queue,
    queue_mutex: *std.Io.Mutex,
    vkalloc: vk.AllocationCallbacks,
    fence: vk.Fence = .null_handle,

    pub fn begin(self: *SingleTime) !vk.CommandBuffer {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "beginSingleTimeCommands" });
        defer zone.end();
        var cmd: vk.CommandBuffer = undefined;
        try self.dev.allocateCommandBuffers(&.{ .level = .primary, .command_pool = self.pool, .command_buffer_count = 1 }, (&cmd)[0..1]);
        errdefer self.dev.freeCommandBuffers(self.pool, &.{cmd});

        try self.dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true }, .p_inheritance_info = null });

        return cmd;
    }

    pub fn free(self: *SingleTime, cmd: vk.CommandBuffer) void {
        self.dev.freeCommandBuffers(self.pool, &.{cmd});
    }

    pub fn endLocked(self: *SingleTime, cmd: vk.CommandBuffer) !void {
        defer self.dev.freeCommandBuffers(self.pool, &.{cmd});

        try self.dev.endCommandBuffer(cmd);

        const submit_info: vk.SubmitInfo2 = .{
            .flags = .{},
            .wait_semaphore_info_count = 0,
            .p_wait_semaphore_infos = null,
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = (&vk.CommandBufferSubmitInfo{ .command_buffer = cmd, .device_mask = 0 })[0..1],
            .signal_semaphore_info_count = 0,
            .p_signal_semaphore_infos = null,
        };

        if (self.fence == .null_handle) {
            self.fence = try self.dev.createFence(&.{}, &self.vkalloc);
        } else {
            try self.dev.resetFences((&self.fence)[0..1]);
        }

        try self.dev.queueSubmit2(self.queue, (&submit_info)[0..1], self.fence);
        _ = try self.dev.waitForFences((&self.fence)[0..1], .true, std.math.maxInt(u64));
    }

    pub fn end(self: *SingleTime, io: std.Io, cmd: vk.CommandBuffer) !void {
        self.queue_mutex.lockUncancelable(io);
        defer self.queue_mutex.unlock(io);
        try self.endLocked(cmd);
    }

    pub fn destroyFence(self: *SingleTime) void {
        if (self.fence != .null_handle) {
            self.dev.destroyFence(self.fence, &self.vkalloc);
            self.fence = .null_handle;
        }
    }
};

// ---------------------------------------------------------------------------
// Pipelines
// ---------------------------------------------------------------------------

pub fn shaderStageCreateInfo(stage: vk.ShaderStageFlags, module: vk.ShaderModule) vk.PipelineShaderStageCreateInfo {
    return .{
        .flags = .{},
        .stage = stage,
        .module = module,
        .p_name = "main",
        .p_specialization_info = null,
    };
}

pub fn createShaderModule(dev: DeviceProxy, vkalloc: *const vk.AllocationCallbacks, spv: []const u32) !vk.ShaderModule {
    return dev.createShaderModule(&.{
        .flags = .{},
        .code_size = spv.len * @sizeOf(u32),
        .p_code = spv.ptr,
    }, vkalloc);
}

pub fn buildGraphicsPipeline(
    dev: DeviceProxy,
    vkalloc: *const vk.AllocationCallbacks,
    pipeline_creation_feedback: bool,
    vert_module: vk.ShaderModule,
    frag_module: vk.ShaderModule,
    color_formats: []const vk.Format,
    depth_format: vk.Format,
    depth_stencil_state: ?vk.PipelineDepthStencilStateCreateInfo,
    blend_attachments: []const vk.PipelineColorBlendAttachmentState,
    layout: vk.PipelineLayout,
    vertex_input_info: vk.PipelineVertexInputStateCreateInfo,
) !vk.Pipeline {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "buildGraphicsPipeline" });
    defer zone.end();
    const piasci: vk.PipelineInputAssemblyStateCreateInfo = .{ .topology = .triangle_list, .primitive_restart_enable = .false };
    const pvsci: vk.PipelineViewportStateCreateInfo = .{ .viewport_count = 1, .p_viewports = null, .scissor_count = 1, .p_scissors = null };
    const prsci: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{}, // Set dynamically via cmdSetCullMode
        .front_face = .clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };
    const pmsci: vk.PipelineMultisampleStateCreateInfo = .{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };
    const pcbsci: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = @intCast(blend_attachments.len),
        .p_attachments = blend_attachments.ptr,
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    var dyn_states_buf: [5]vk.DynamicState = undefined;
    var dyn_states = std.ArrayList(vk.DynamicState).initBuffer(&dyn_states_buf);
    dyn_states.appendAssumeCapacity(.viewport);
    dyn_states.appendAssumeCapacity(.scissor);
    dyn_states.appendAssumeCapacity(.cull_mode);
    if (depth_stencil_state != null) {
        dyn_states.appendAssumeCapacity(.depth_compare_op);
        dyn_states.appendAssumeCapacity(.depth_write_enable);
    }
    const dyn: vk.PipelineDynamicStateCreateInfo = .{ .flags = .{}, .dynamic_state_count = @intCast(dyn_states.items.len), .p_dynamic_states = dyn_states.items.ptr };

    const pssci: [2]vk.PipelineShaderStageCreateInfo = .{
        shaderStageCreateInfo(.{ .vertex_bit = true }, vert_module),
        shaderStageCreateInfo(.{ .fragment_bit = true }, frag_module),
    };

    var pipeline_feedback: vk.PipelineCreationFeedback = .{ .flags = .{}, .duration = 0 };
    var stage_feedbacks: [2]vk.PipelineCreationFeedback = .{ .{ .flags = .{}, .duration = 0 }, .{ .flags = .{}, .duration = 0 } };
    var feedback_info: vk.PipelineCreationFeedbackCreateInfo = .{ .p_pipeline_creation_feedback = &pipeline_feedback, .pipeline_stage_creation_feedback_count = 2, .p_pipeline_stage_creation_feedbacks = &stage_feedbacks };

    const stencil_format: vk.Format = if (depth_format == .d32_sfloat_s8_uint or depth_format == .d24_unorm_s8_uint) depth_format else .undefined;
    var rendering_info: vk.PipelineRenderingCreateInfo = .{
        .p_next = null,
        .view_mask = 0,
        .color_attachment_count = @intCast(color_formats.len),
        .p_color_attachment_formats = color_formats.ptr,
        .depth_attachment_format = depth_format,
        .stencil_attachment_format = stencil_format,
    };
    if (pipeline_creation_feedback) {
        rendering_info.p_next = @ptrCast(&feedback_info);
    }
    const ds_ptr: ?*const vk.PipelineDepthStencilStateCreateInfo = if (depth_stencil_state) |*ds| ds else null;
    const gpci: vk.GraphicsPipelineCreateInfo = .{
        .flags = .{},
        .p_next = @ptrCast(&rendering_info),
        .stage_count = 2,
        .p_stages = &pssci,
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &piasci,
        .p_tessellation_state = null,
        .p_viewport_state = &pvsci,
        .p_rasterization_state = &prsci,
        .p_multisample_state = &pmsci,
        .p_depth_stencil_state = ds_ptr,
        .p_color_blend_state = &pcbsci,
        .p_dynamic_state = &dyn,
        .layout = layout,
        .render_pass = .null_handle,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };
    var pipeline: vk.Pipeline = undefined;
    if (dev.createGraphicsPipelines(.null_handle, (&gpci)[0..1], vkalloc, (&pipeline)[0..1])) |res| {
        if (res != .success) return error.PipelineCreationFailed;
    } else |err| return err;

    if (pipeline_creation_feedback and pipeline_feedback.flags.valid_bit) {
        std.log.debug("Vulkan: Pipeline compilation took {d:.3} ms (cached: {})", .{
            @as(f64, @floatFromInt(pipeline_feedback.duration)) / 1_000_000.0,
            pipeline_feedback.flags.application_pipeline_cache_hit_bit,
        });
    }

    return pipeline;
}

pub fn createFrameDescriptorPool(dev: DeviceProxy, allocator: std.mem.Allocator, vkalloc: *const vk.AllocationCallbacks, pool: *vk.DescriptorPool, layout: vk.DescriptorSetLayout, sets: *[]vk.DescriptorSet, pool_sizes: []const vk.DescriptorPoolSize) !void {
    const num_frames = VulkanContext.max_frames_in_flight;
    pool.* = try dev.createDescriptorPool(&.{ .flags = .{}, .max_sets = @intCast(num_frames), .pool_size_count = @intCast(pool_sizes.len), .p_pool_sizes = pool_sizes.ptr }, vkalloc);
    errdefer if (pool.* != .null_handle) {
        dev.destroyDescriptorPool(pool.*, vkalloc);
        pool.* = .null_handle;
    };

    sets.* = try allocator.alloc(vk.DescriptorSet, num_frames);
    errdefer {
        allocator.free(sets.*);
        sets.* = &.{};
    }

    const layouts = try allocator.alloc(vk.DescriptorSetLayout, num_frames);
    defer allocator.free(layouts);
    @memset(layouts, layout);

    try dev.allocateDescriptorSets(&.{ .descriptor_pool = pool.*, .descriptor_set_count = @intCast(num_frames), .p_set_layouts = layouts.ptr }, sets.*.ptr);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "findMemoryType" {
    var mem_types: [vk.MAX_MEMORY_TYPES]vk.MemoryType = undefined;
    @memset(&mem_types, vk.MemoryType{ .property_flags = .{}, .heap_index = 0 });
    mem_types[0] = .{ .property_flags = .{ .host_visible_bit = true, .host_coherent_bit = true }, .heap_index = 0 };
    mem_types[1] = .{ .property_flags = .{ .device_local_bit = true }, .heap_index = 1 };
    mem_types[2] = .{ .property_flags = .{ .host_visible_bit = true, .host_cached_bit = true }, .heap_index = 0 };
    var mem_props: vk.PhysicalDeviceMemoryProperties = .{ .memory_type_count = 3, .memory_types = mem_types, .memory_heap_count = 2, .memory_heaps = undefined };
    try std.testing.expectEqual(@as(u32, 0), try findMemoryType(mem_props, 0b111, .{ .host_visible_bit = true, .host_coherent_bit = true }));
    mem_types[0] = .{ .property_flags = .{ .host_visible_bit = true, .host_coherent_bit = true }, .heap_index = 0 };
    mem_types[1] = .{ .property_flags = .{ .device_local_bit = true }, .heap_index = 1 };
    mem_props = .{ .memory_type_count = 2, .memory_types = mem_types, .memory_heap_count = 2, .memory_heaps = undefined };
    try std.testing.expectEqual(@as(u32, 1), try findMemoryType(mem_props, 0b11, .{ .device_local_bit = true }));
}

test "VulkanBackingAllocator alloc and free both pools" {
    const wio_mod = @import("wio");

    try wio_mod.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .eventFn = wio_mod.EventQueue.eventFn });
    defer wio_mod.deinit();

    var events: wio_mod.EventQueue = .empty;
    defer events.deinit();

    var window = try wio_mod.Window.create(.{ .title = "test", .event_fn_data = &events });
    defer window.destroy();

    const vk_ctx = try VulkanContext.init(std.testing.allocator, &window);
    defer vk_ctx.deinit(std.testing.io);

    var backing = VulkanBackingAllocator.init(vk_ctx.dev, vk_ctx.mem_props, std.testing.io, std.testing.allocator, vk_ctx.queue_family_index, vk_ctx.transfer_queue_family_index, vk_ctx.vkalloc);
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
