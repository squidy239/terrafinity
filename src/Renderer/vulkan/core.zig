const std = @import("std");
const zm = @import("zm");
const tracy = @import("tracy");
const vk = @import("vulkan");

const DeviceProxy = vk.DeviceProxy;
const Frustum = @import("Frustum.zig").Frustum;
const VulkanContext = @import("../../VulkanContext.zig").VulkanContext;

const near_plane: f32 = 0.01;

pub const fullscreen_triangle_vertices: u32 = 3;

/// View-projection and frustum of an origin-eye camera looking along the unit vector `front`.
pub fn computeViewProjection(front: @Vector(3, f32), aspect: f32, fov_radians: f32) struct { projview: @Vector(16, f32), frustum: Frustum } {
    const up_vec: zm.vec.Vec3f = .{ .data = .{ 0, 1, 0 } };
    const view = zm.matrix.Mat4f.lookAtRH(
        .{ .data = @Vector(3, f32){ 0, 0, 0 } },
        .{ .data = front },
        up_vec,
    );
    const projection = makeInfReversedZProjRh(fov_radians, aspect, near_plane);
    const projview: @Vector(16, f32) = @bitCast(projection.multiply(view).data);
    return .{ .projview = projview, .frustum = Frustum.extractFrustumPlanes(projview) };
}

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
        vk.Pipeline => dev.destroyPipeline(handle.*, vkalloc),
        vk.PipelineLayout => dev.destroyPipelineLayout(handle.*, vkalloc),
        vk.DescriptorSetLayout => dev.destroyDescriptorSetLayout(handle.*, vkalloc),
        vk.DescriptorPool => dev.destroyDescriptorPool(handle.*, vkalloc),
        vk.Sampler => dev.destroySampler(handle.*, vkalloc),
        else => @compileError("destroyIfValid: unsupported type " ++ @typeName(T)),
    }
    handle.* = .null_handle;
}

pub fn destroyImageWithMemory(vk_ctx: *const VulkanContext, image: *vk.Image, memory: *vk.DeviceMemory) void {
    if (image.* != .null_handle) {
        vk_ctx.dev.destroyImage(image.*, &vk_ctx.vkalloc);
        image.* = .null_handle;
    }
    if (memory.* != .null_handle) {
        vk_ctx.dev.freeMemory(memory.*, &vk_ctx.vkalloc);
        memory.* = .null_handle;
    }
}

pub fn destroyRenderTarget(vk_ctx: *const VulkanContext, rt: *RenderTarget) void {
    destroyIfValid(vk_ctx.dev, &rt.view, &vk_ctx.vkalloc);
    destroyImageWithMemory(vk_ctx, &rt.image, &rt.memory);
}

/// Allocates device-local memory for `create_info`, creates the image, and binds them.
/// Shared by render targets, textures, and layered (shadow array, depth pyramid) images.
pub fn allocateImageWithMemory(vk_ctx: *const VulkanContext, create_info: *const vk.ImageCreateInfo) !struct { vk.Image, vk.DeviceMemory } {
    const dev = vk_ctx.dev;
    const vkalloc = &vk_ctx.vkalloc;
    var mem_reqs2: vk.MemoryRequirements2 = .{ .memory_requirements = undefined };
    dev.getDeviceImageMemoryRequirements(&.{ .p_create_info = create_info, .plane_aspect = .{} }, &mem_reqs2);
    const mem_reqs = mem_reqs2.memory_requirements;

    const alloc_info: vk.MemoryAllocateInfo = .{
        .allocation_size = mem_reqs.size,
        .memory_type_index = try findMemoryType(vk_ctx.mem_props, mem_reqs.memory_type_bits, .{ .device_local = true }),
    };
    const memory = try dev.allocateMemory(&alloc_info, vkalloc);
    errdefer dev.freeMemory(memory, vkalloc);
    const image = try dev.createImage(create_info, vkalloc);
    errdefer dev.destroyImage(image, vkalloc);
    try dev.bindImageMemory(image, memory, 0);
    return .{ image, memory };
}

pub fn imageViewCreateInfo(image: vk.Image, format: vk.Format, aspect: vk.ImageAspectFlags) vk.ImageViewCreateInfo {
    return .{
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

pub fn sampleCountToFlags(count: u32) vk.SampleCountFlags {
    // SampleCountFlags packs sample count N at bit log2(N).
    if (count >= 1 and count <= 64 and std.math.isPowerOfTwo(count)) return @bitCast(count);
    return .{ .@"1" = true };
}

pub fn createImageWithMemory(vk_ctx: *const VulkanContext, extent: vk.Extent2D, format: vk.Format, usage: vk.ImageUsageFlags, aspect: vk.ImageAspectFlags, samples: vk.SampleCountFlags) !RenderTarget {
    const create_info: vk.ImageCreateInfo = .{
        .image_type = .@"2d",
        .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .format = format,
        .tiling = .optimal,
        .initial_layout = .undefined,
        .usage = usage,
        .sharing_mode = .exclusive,
        .samples = samples,
    };
    const image, const memory = try allocateImageWithMemory(vk_ctx, &create_info);
    var target: RenderTarget = .{ .image = image, .memory = memory };
    errdefer destroyRenderTarget(vk_ctx, &target);
    target.view = try vk_ctx.dev.createImageView(&imageViewCreateInfo(target.image, format, aspect), &vk_ctx.vkalloc);
    return target;
}

/// Represents a single VkBuffer allocation and its associated resources.
/// raw_alloc is the full CPU-side backing allocation, used for range checks and cleanup.
const GpuBlock = struct {
    memory: vk.DeviceMemory,
    buffer: vk.Buffer,
    raw_alloc: []u8,
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

    graphics_queue_family: u32,
    transfer_queue_family: u32,

    vkalloc: vk.AllocationCallbacks,

    blocks: std.enums.EnumArray(MemoryPool, std.AutoHashMapUnmanaged(usize, GpuBlock)) = .initFill(.empty),
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
        var it = self.blocks.iterator();
        while (it.next()) |entry| {
            const map = entry.value;
            if (map.count() > 0) std.debug.panic("VulkanBackingAllocator.deinit: {d} block(s) still allocated in {s} pool", .{ map.count(), @tagName(entry.key) });
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

    /// Returns the buffer and byte offset for a pointer into a block. The caller must own
    /// the pointer. Serializes against allocBlock/freeBlock, which can reallocate the block
    /// map mid-iteration.
    pub fn getBufferAndOffset(self: *VulkanBackingAllocator, pool: MemoryPool, ptr: *anyopaque) struct { buffer: vk.Buffer, offset: vk.DeviceSize } {
        const addr = @intFromPtr(ptr);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var it = self.blocks.getPtr(pool).valueIterator();
        while (it.next()) |block| {
            const start = @intFromPtr(block.raw_alloc.ptr);
            if (addr < start or addr >= start + block.raw_alloc.len) continue;
            // gpu_only blocks have no real CPU mapping. Their alignment padding is a
            // sentinel artifact of the dummy allocation, so the data always sits at
            // buffer offset 0. cpu_to_gpu blocks share the mapping with the buffer,
            // so the pointer delta is the true offset.
            const offset: vk.DeviceSize = if (pool == .gpu_only) 0 else @intCast(addr - start);
            return .{ .buffer = block.buffer, .offset = offset };
        }
        std.debug.panic("Pointer 0x{x} is not part of any VulkanBackingAllocator block", .{addr});
    }

    fn allocBlock(self: *VulkanBackingAllocator, pool: MemoryPool, len: usize, alignment: std.mem.Alignment) ![]u8 {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "VulkanBackingAllocator.allocBlock" });
        defer zone.end();

        const alignment_bytes = alignment.toByteUnits();
        const alloc_len = if (alignment_bytes > 1) len + alignment_bytes -| 1 else len;

        const buffer, const memory, const mem_size = try self.createBufferWithMemory(pool, alloc_len);
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
        try self.blocks.getPtr(pool).put(self.meta_allocator, @intFromPtr(result.ptr), .{
            .memory = memory,
            .buffer = buffer,
            .raw_alloc = raw_cpu,
        });

        return result;
    }

    fn createBufferWithMemory(self: *VulkanBackingAllocator, pool: MemoryPool, len: usize) !struct { vk.Buffer, vk.DeviceMemory, usize } {
        const queue_family_indices: [2]u32 = .{ self.graphics_queue_family, self.transfer_queue_family };
        const is_concurrent = self.graphics_queue_family != self.transfer_queue_family;

        const buffer_info: vk.BufferCreateInfo = .{
            .size = len,
            .usage = .{
                .transfer_src = true,
                .transfer_dst = true,
                .shader_device_address = true,
                .storage_buffer = true,
                .indirect_buffer = true,
                .vertex_buffer = true,
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
            .gpu_only => vk.MemoryPropertyFlags{ .device_local = true },
            .cpu_to_gpu => vk.MemoryPropertyFlags{ .host_visible = true, .host_coherent = true },
        };
        const mem_type = try findMemoryType(self.mem_props, mem_reqs.memory_type_bits, required_flags);

        const memory = try self.dev.allocateMemory(&.{
            .allocation_size = mem_reqs.size,
            .memory_type_index = mem_type,
            .p_next = @ptrCast(&vk.MemoryAllocateFlagsInfo{ .flags = .{ .device_address = true }, .device_mask = 0 }),
        }, &self.vkalloc);
        errdefer self.dev.freeMemory(memory, &self.vkalloc);
        try self.dev.bindBufferMemory(buffer, memory, 0);

        return .{ buffer, memory, mem_reqs.size };
    }

    fn freeBlock(self: *VulkanBackingAllocator, pool: MemoryPool, buf: []u8) void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "VulkanBackingAllocator.freeBlock" });
        defer zone.end();

        self.mutex.lockUncancelable(self.io);
        const fetch_result = self.blocks.getPtr(pool).fetchRemove(@intFromPtr(buf.ptr)) orelse {
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
    const count = @min(mem_props.memory_type_count, mem_props.memory_types.len);
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

/// Image barrier over an explicit subresource range (any layers/mips), shared by the
/// single-layer `makeImageBarrier2` and the layered shadow-array barriers.
pub fn imageBarrier2Range(
    image: vk.Image,
    range: vk.ImageSubresourceRange,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_stage: vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage: vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
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
        .subresource_range = range,
    };
}

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
    return imageBarrier2Range(
        image,
        .{
            .aspect_mask = aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        old_layout,
        new_layout,
        src_stage,
        src_access,
        dst_stage,
        dst_access,
    );
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

/// The barrier slice must outlive the cmdPipelineBarrier2 call below. Recording consumes
/// the slice synchronously, so do not extract the DependencyInfo and defer the call.
pub fn pipelineBarrier(cmd: vk.CommandBuffer, dev: DeviceProxy, comptime barrier_type: type, barriers: []const barrier_type) void {
    const info: vk.DependencyInfo = switch (barrier_type) {
        vk.ImageMemoryBarrier2 => .{ .image_memory_barrier_count = @intCast(barriers.len), .p_image_memory_barriers = barriers.ptr },
        vk.BufferMemoryBarrier2 => .{ .buffer_memory_barrier_count = @intCast(barriers.len), .p_buffer_memory_barriers = barriers.ptr },
        else => @compileError("pipelineBarrier: unsupported type " ++ @typeName(barrier_type)),
    };
    dev.cmdPipelineBarrier2(cmd, &info);
}

const null_image_info: vk.DescriptorImageInfo = .{ .sampler = .null_handle, .image_view = .null_handle, .image_layout = .undefined };
pub const null_buffer_info: vk.DescriptorBufferInfo = .{ .buffer = .null_handle, .offset = 0, .range = 0 };
pub const null_buffer_view: vk.BufferView = .null_handle;

/// Common WriteDescriptorSet builder over a single image or buffer info pointer.
fn writeDescriptorSet(
    dst_set: vk.DescriptorSet,
    dst_binding: u32,
    descriptor_type: vk.DescriptorType,
    image_info: ?*const vk.DescriptorImageInfo,
    buffer_info: ?*const vk.DescriptorBufferInfo,
) vk.WriteDescriptorSet {
    return .{
        .dst_set = dst_set,
        .dst_binding = dst_binding,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = descriptor_type,
        .p_image_info = if (image_info) |info| (&info.*)[0..1] else (&null_image_info)[0..1],
        .p_buffer_info = if (buffer_info) |info| (&info.*)[0..1] else (&null_buffer_info)[0..1],
        .p_texel_buffer_view = (&null_buffer_view)[0..1],
    };
}

pub fn bufferWriteDescriptorSet(dst_set: vk.DescriptorSet, dst_binding: u32, descriptor_type: vk.DescriptorType, buffer_info: *const vk.DescriptorBufferInfo) vk.WriteDescriptorSet {
    return writeDescriptorSet(dst_set, dst_binding, descriptor_type, null, buffer_info);
}

pub fn imageWriteDescriptorSet(dst_set: vk.DescriptorSet, dst_binding: u32, image_info: *const vk.DescriptorImageInfo) vk.WriteDescriptorSet {
    return writeDescriptorSet(dst_set, dst_binding, .combined_image_sampler, image_info, null);
}

pub fn storageImageWriteDescriptorSet(dst_set: vk.DescriptorSet, dst_binding: u32, image_info: *const vk.DescriptorImageInfo) vk.WriteDescriptorSet {
    return writeDescriptorSet(dst_set, dst_binding, .storage_image, image_info, null);
}

pub fn renderingAttachmentColor(view: vk.ImageView, load_op: vk.AttachmentLoadOp, clear_color: [4]f32) vk.RenderingAttachmentInfo {
    return .{
        .image_view = view,
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .load_op = load_op,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = clear_color } },
    };
}

pub fn renderingAttachmentColorResolve(msaa_view: vk.ImageView, resolve_view: vk.ImageView, load_op: vk.AttachmentLoadOp, clear_color: [4]f32) vk.RenderingAttachmentInfo {
    return .{
        .image_view = msaa_view,
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{ .average = true },
        .resolve_image_view = resolve_view,
        .resolve_image_layout = .color_attachment_optimal,
        .load_op = load_op,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = clear_color } },
    };
}

/// Depth attachment builder. `clear_depth` applies when `load_op` is `.clear`.
/// The shadow pass clears to far = 1.0 in standard depth. The main passes use 0.0.
pub fn renderingAttachmentDepth(view: vk.ImageView, layout: vk.ImageLayout, load_op: vk.AttachmentLoadOp, clear_depth: f32) vk.RenderingAttachmentInfo {
    return .{
        .image_view = view,
        .image_layout = layout,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .load_op = load_op,
        .store_op = .store,
        .clear_value = .{ .depth_stencil = .{ .depth = clear_depth, .stencil = 0 } },
    };
}

pub fn renderingAttachmentDepthResolve(msaa_view: vk.ImageView, resolve_view: vk.ImageView, layout: vk.ImageLayout, load_op: vk.AttachmentLoadOp, clear_depth: f32, resolve_mode: vk.ResolveModeFlags) vk.RenderingAttachmentInfo {
    return .{
        .image_view = msaa_view,
        .image_layout = layout,
        .resolve_mode = resolve_mode,
        .resolve_image_view = resolve_view,
        .resolve_image_layout = .depth_stencil_attachment_optimal,
        .load_op = load_op,
        .store_op = .store,
        .clear_value = .{ .depth_stencil = .{ .depth = clear_depth, .stencil = 0 } },
    };
}

pub fn renderingInfo(
    extent: vk.Extent2D,
    color_attachments: []const vk.RenderingAttachmentInfo,
    depth_attachment: ?*const vk.RenderingAttachmentInfo,
) vk.RenderingInfo {
    return .{
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = @intCast(color_attachments.len),
        .p_color_attachments = color_attachments.ptr,
        .p_depth_attachment = depth_attachment,
    };
}

pub const DepthDynamicState = struct {
    compare_op: vk.CompareOp,
    write: bool,
};

/// Sets every state `buildGraphicsPipeline` leaves dynamic: viewport and scissor over
/// `extent`, the cull mode, and, for pipelines with a depth attachment, `depth`.
pub fn setDynamicState(dev: DeviceProxy, cmd: vk.CommandBuffer, extent: vk.Extent2D, cull_mode: vk.CullModeFlags, depth: ?DepthDynamicState) void {
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
    dev.cmdSetCullMode(cmd, cull_mode);
    const depth_state = depth orelse return;
    dev.cmdSetDepthCompareOp(cmd, depth_state.compare_op);
    dev.cmdSetDepthWriteEnable(cmd, vk.Bool32.fromBool(depth_state.write));
}

/// GPU-immediate helper: allocate a one-shot command buffer from a shared transient pool,
/// record, submit on the graphics queue, and wait on a reusable fence. Used for one-off
/// uploads and buffer copies that must complete synchronously.
pub const SingleTime = struct {
    vk_ctx: *VulkanContext,
    /// Guards `vk_ctx.upload_command_pool`, which needs external synchronization. Leaf lock.
    pool_mutex: std.Io.Mutex = .init,
    io: std.Io,
    /// Guarded by `vk_ctx.queue_mutex`, which every submission holds.
    fence: vk.Fence,

    pub fn init(vk_ctx: *VulkanContext, io: std.Io) !SingleTime {
        return .{ .vk_ctx = vk_ctx, .io = io, .fence = try vk_ctx.dev.createFence(&.{}, &vk_ctx.vkalloc) };
    }

    pub fn deinit(self: *SingleTime) void {
        self.vk_ctx.dev.destroyFence(self.fence, &self.vk_ctx.vkalloc);
    }

    pub fn begin(self: *SingleTime) !vk.CommandBuffer {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "beginSingleTimeCommands" });
        defer zone.end();
        const dev = self.vk_ctx.dev;
        const pool = self.vk_ctx.upload_command_pool;
        self.pool_mutex.lockUncancelable(self.io);
        defer self.pool_mutex.unlock(self.io);
        var cmd: vk.CommandBuffer = undefined;
        try dev.allocateCommandBuffers(&.{ .level = .primary, .command_pool = pool, .command_buffer_count = 1 }, (&cmd)[0..1]);
        errdefer dev.freeCommandBuffers(pool, &.{cmd});

        try dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit = true } });

        return cmd;
    }

    pub fn free(self: *SingleTime, cmd: vk.CommandBuffer) void {
        self.pool_mutex.lockUncancelable(self.io);
        defer self.pool_mutex.unlock(self.io);
        self.vk_ctx.dev.freeCommandBuffers(self.vk_ctx.upload_command_pool, &.{cmd});
    }

    pub fn endLocked(self: *SingleTime, cmd: vk.CommandBuffer) !void {
        defer self.free(cmd);
        const dev = self.vk_ctx.dev;

        try dev.endCommandBuffer(cmd);

        const submit_info: vk.SubmitInfo2 = .{
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = (&vk.CommandBufferSubmitInfo{ .command_buffer = cmd, .device_mask = 0 })[0..1],
        };

        try dev.resetFences((&self.fence)[0..1]);
        try dev.queueSubmit2(self.vk_ctx.graphics_queue, (&submit_info)[0..1], self.fence);
        _ = try dev.waitForFences((&self.fence)[0..1], .true, std.math.maxInt(u64));
    }

    pub fn end(self: *SingleTime, io: std.Io, cmd: vk.CommandBuffer) !void {
        self.vk_ctx.queue_mutex.lockUncancelable(io);
        defer self.vk_ctx.queue_mutex.unlock(io);
        try self.endLocked(cmd);
    }
};

pub fn shaderStageCreateInfo(stage: vk.ShaderStageFlags, module: vk.ShaderModule) vk.PipelineShaderStageCreateInfo {
    return .{
        .stage = stage,
        .module = module,
        .p_name = "main",
    };
}

pub fn createShaderModule(vk_ctx: *const VulkanContext, spv: []const u32) !vk.ShaderModule {
    return vk_ctx.dev.createShaderModule(&.{
        .code_size = spv.len * @sizeOf(u32),
        .p_code = spv.ptr,
    }, &vk_ctx.vkalloc);
}

/// Sampler options that vary between call sites. `createSampler` fixes the other fields
/// for the common case: clamped sampling of an image in a fragment shader.
pub const SamplerOptions = struct {
    mag_filter: vk.Filter = .linear,
    min_filter: vk.Filter = .linear,
    mipmap_mode: vk.SamplerMipmapMode = .linear,
    address_mode: vk.SamplerAddressMode = .clamp_to_edge,
    compare_enable: bool = false,
    compare_op: vk.CompareOp = .always,
    anisotropy_enable: bool = false,
    max_anisotropy: f32 = 1.0,
    max_lod: f32 = 0,
    border_color: vk.BorderColor = .float_opaque_black,
};

pub fn createSampler(vk_ctx: *const VulkanContext, opts: SamplerOptions) !vk.Sampler {
    return vk_ctx.dev.createSampler(&.{
        .mag_filter = opts.mag_filter,
        .min_filter = opts.min_filter,
        .mipmap_mode = opts.mipmap_mode,
        .address_mode_u = opts.address_mode,
        .address_mode_v = opts.address_mode,
        .address_mode_w = opts.address_mode,
        .mip_lod_bias = 0,
        .anisotropy_enable = vk.Bool32.fromBool(opts.anisotropy_enable),
        .max_anisotropy = opts.max_anisotropy,
        .compare_enable = vk.Bool32.fromBool(opts.compare_enable),
        .compare_op = opts.compare_op,
        .min_lod = 0,
        .max_lod = opts.max_lod,
        .border_color = opts.border_color,
        .unnormalized_coordinates = .false,
    }, &vk_ctx.vkalloc);
}

/// Full-RGBA opaque blend attachment (no blending) shared by fullscreen passes.
pub const opaque_blend_attachment: vk.PipelineColorBlendAttachmentState = .{
    .blend_enable = .false,
    .src_color_blend_factor = .one,
    .dst_color_blend_factor = .zero,
    .color_blend_op = .add,
    .src_alpha_blend_factor = .one,
    .dst_alpha_blend_factor = .zero,
    .alpha_blend_op = .add,
    .color_write_mask = .{ .r = true, .g = true, .b = true, .a = true },
};

pub const DepthBias = struct {
    constant: f32 = 0,
    slope: f32 = 0,
    clamp: f32 = 0,
};

/// Graphics pipeline state that varies between passes. Cull mode, viewport, and scissor
/// are always dynamic. Depth compare and write become dynamic too when `depth_format` is
/// not `.undefined`. Record sites set them with `setDynamicState`.
pub const GraphicsPipelineDesc = struct {
    vert_module: vk.ShaderModule,
    /// Null builds a depth-only pipeline. Pair it with empty `color_formats`.
    frag_module: ?vk.ShaderModule = null,
    color_formats: []const vk.Format = &.{},
    /// One entry per `color_formats` entry.
    blend_attachments: []const vk.PipelineColorBlendAttachmentState = &.{},
    /// `.undefined` means no depth attachment and no depth-stencil state.
    depth_format: vk.Format = .undefined,
    depth_test: bool = false,
    layout: vk.PipelineLayout,
    vertex_input: vk.PipelineVertexInputStateCreateInfo = .{},
    topology: vk.PrimitiveTopology = .triangle_list,
    samples: vk.SampleCountFlags = .{ .@"1" = true },
    depth_bias: ?DepthBias = null,
    depth_clamp: bool = false,
};

pub fn buildGraphicsPipeline(vk_ctx: *const VulkanContext, desc: GraphicsPipelineDesc) !vk.Pipeline {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "createGraphicsPipeline" });
    defer zone.end();
    const piasci: vk.PipelineInputAssemblyStateCreateInfo = .{ .topology = desc.topology, .primitive_restart_enable = .false };
    const pvsci: vk.PipelineViewportStateCreateInfo = .{ .viewport_count = 1, .scissor_count = 1 };
    const bias = desc.depth_bias orelse DepthBias{};
    const prsci: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = vk.Bool32.fromBool(desc.depth_clamp),
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{}, // Set dynamically via cmdSetCullMode
        .front_face = .clockwise,
        .depth_bias_enable = vk.Bool32.fromBool(desc.depth_bias != null),
        .depth_bias_constant_factor = bias.constant,
        .depth_bias_clamp = bias.clamp,
        .depth_bias_slope_factor = bias.slope,
        .line_width = 1,
    };
    const pmsci: vk.PipelineMultisampleStateCreateInfo = .{
        .rasterization_samples = desc.samples,
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };
    // Compare op and write enable are placeholders: the pipeline makes both dynamic.
    const pdssci: vk.PipelineDepthStencilStateCreateInfo = .{
        .depth_test_enable = vk.Bool32.fromBool(desc.depth_test),
        .depth_write_enable = .false,
        .depth_compare_op = .always,
        .depth_bounds_test_enable = .false,
        .stencil_test_enable = .false,
        .front = undefined,
        .back = undefined,
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
    };
    const pcbsci: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = @intCast(desc.blend_attachments.len),
        .p_attachments = desc.blend_attachments.ptr,
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    const has_depth = desc.depth_format != .undefined;
    // The pipeline makes these states dynamic. The caller sets them with `setDynamicState`.
    // Vulkan reads only the first dynamic_state_count entries.
    const dyn_states: [5]vk.DynamicState = .{ .viewport, .scissor, .cull_mode, .depth_compare_op, .depth_write_enable };
    const dyn: vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = if (has_depth) 5 else 3,
        .p_dynamic_states = dyn_states[0..].ptr,
    };

    // A depth-only pipeline submits just the first (vertex) stage.
    const stage_count: u32 = if (desc.frag_module != null) 2 else 1;
    const pssci: [2]vk.PipelineShaderStageCreateInfo = .{
        shaderStageCreateInfo(.{ .vertex = true }, desc.vert_module),
        shaderStageCreateInfo(.{ .fragment = true }, desc.frag_module orelse .null_handle),
    };

    var pipeline_feedback: vk.PipelineCreationFeedback = .{ .flags = .{}, .duration = 0 };
    var stage_feedbacks: [2]vk.PipelineCreationFeedback = @splat(.{ .flags = .{}, .duration = 0 });
    var feedback_info: vk.PipelineCreationFeedbackCreateInfo = .{ .p_pipeline_creation_feedback = &pipeline_feedback, .pipeline_stage_creation_feedback_count = stage_count, .p_pipeline_stage_creation_feedbacks = &stage_feedbacks };

    const depth_format = desc.depth_format;
    const stencil_format: vk.Format = if (depth_format == .d32_sfloat_s8_uint or depth_format == .d24_unorm_s8_uint) depth_format else .undefined;
    const rendering_info: vk.PipelineRenderingCreateInfo = .{
        .p_next = if (vk_ctx.pipeline_creation_feedback) @ptrCast(&feedback_info) else null,
        .view_mask = 0,
        .color_attachment_count = @intCast(desc.color_formats.len),
        .p_color_attachment_formats = if (desc.color_formats.len > 0) desc.color_formats.ptr else null,
        .depth_attachment_format = depth_format,
        .stencil_attachment_format = stencil_format,
    };
    const gpci: vk.GraphicsPipelineCreateInfo = .{
        .p_next = @ptrCast(&rendering_info),
        .stage_count = stage_count,
        .p_stages = &pssci,
        .p_vertex_input_state = &desc.vertex_input,
        .p_input_assembly_state = &piasci,
        .p_viewport_state = &pvsci,
        .p_rasterization_state = &prsci,
        .p_multisample_state = &pmsci,
        .p_depth_stencil_state = if (has_depth) &pdssci else null,
        .p_color_blend_state = if (desc.blend_attachments.len > 0) &pcbsci else null,
        .p_dynamic_state = &dyn,
        .layout = desc.layout,
        .subpass = 0,
        .base_pipeline_index = -1,
    };
    var pipeline: vk.Pipeline = undefined;
    const result = try vk_ctx.dev.createGraphicsPipelines(.null_handle, (&gpci)[0..1], &vk_ctx.vkalloc, (&pipeline)[0..1]);
    if (result != .success) return error.PipelineCreationFailed;

    if (vk_ctx.pipeline_creation_feedback and pipeline_feedback.flags.valid) {
        std.log.debug("Vulkan: Pipeline compilation took {d:.3} ms (cached: {})", .{
            @as(f64, @floatFromInt(pipeline_feedback.duration)) / 1_000_000.0,
            pipeline_feedback.flags.application_pipeline_cache_hit,
        });
    }

    return pipeline;
}

pub fn createDescriptorSetLayout(dev: DeviceProxy, vkalloc: *const vk.AllocationCallbacks, flags: vk.DescriptorSetLayoutCreateFlags, bindings: []const vk.DescriptorSetLayoutBinding) !vk.DescriptorSetLayout {
    return dev.createDescriptorSetLayout(&.{ .flags = flags, .binding_count = @intCast(bindings.len), .p_bindings = bindings.ptr }, vkalloc);
}

/// Destroys a per-frame descriptor pool and frees its descriptor-set array.
pub fn destroyFrameDescriptorResources(dev: DeviceProxy, allocator: std.mem.Allocator, vkalloc: *const vk.AllocationCallbacks, pool: *vk.DescriptorPool, sets: *[]vk.DescriptorSet) void {
    destroyIfValid(dev, pool, vkalloc);
    if (sets.*.len > 0) {
        allocator.free(sets.*);
        sets.* = &.{};
    }
}

pub fn createFrameDescriptorPool(dev: DeviceProxy, allocator: std.mem.Allocator, vkalloc: *const vk.AllocationCallbacks, pool: *vk.DescriptorPool, layout: vk.DescriptorSetLayout, sets: *[]vk.DescriptorSet, pool_sizes: []const vk.DescriptorPoolSize) !void {
    const num_frames = VulkanContext.max_frames_in_flight;
    pool.* = try dev.createDescriptorPool(&.{ .max_sets = @intCast(num_frames), .pool_size_count = @intCast(pool_sizes.len), .p_pool_sizes = pool_sizes.ptr }, vkalloc);
    errdefer if (pool.* != .null_handle) {
        dev.destroyDescriptorPool(pool.*, vkalloc);
        pool.* = .null_handle;
    };

    sets.* = try allocator.alloc(vk.DescriptorSet, num_frames);
    errdefer {
        allocator.free(sets.*);
        sets.* = &.{};
    }

    const layouts: [VulkanContext.max_frames_in_flight]vk.DescriptorSetLayout = @splat(layout);
    try dev.allocateDescriptorSets(&.{ .descriptor_pool = pool.*, .descriptor_set_count = @intCast(num_frames), .p_set_layouts = &layouts }, sets.*.ptr);
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

test {
    std.testing.refAllDecls(@This());
}
