const std = @import("std");
const tracy = @import("tracy");
const vk = @import("vulkan");

const DeviceProxy = vk.DeviceProxy;

const VulkanContext = @import("../../../VulkanContext.zig").VulkanContext;
const core = @import("../core.zig");
const gpu = @import("../gpu.zig");

const depth_pyramid_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("depth_pyramid_spv")));

const build_workgroup_size: u32 = 8;

const BuildPushConstants = extern struct {
    src_width: i32,
    src_height: i32,
    dst_width: i32,
    dst_height: i32,
};

/// Mirrors the HizParamsBuffer std430 block in occlusion.glsl.
pub const Params = extern struct {
    projview: [16]f32 = @splat(0),
    occlusion_player_pos: [4]f32 = @splat(0),
    pyramid_size: [2]f32 = @splat(0),
    mip_count: u32 = 0,
    enabled: u32 = 0,
};

comptime {
    if (@sizeOf(Params) != 96) @compileError("Params size mismatch with GLSL layout (expected 96)");
}

const FrameParams = struct {
    slice: []align(gpu.cull_buffer_alignment.toByteUnits()) Params,
    buffer: vk.Buffer,
    offset: vk.DeviceSize,
};

/// Reversed-Z hierarchical depth (Hi-Z) pyramid for GPU occlusion culling. Built each
/// frame from the opaque depth buffer with a MIN-reduce mip chain; culling shaders add
/// `occlusion_set_layout` to their pipeline layout, include occlusion.glsl, and call
/// hizOccluded. Renderer-agnostic: any culling pipeline may consume it.
pub const DepthPyramid = @This();

vk_ctx: *VulkanContext,
allocator: std.mem.Allocator,
dev: DeviceProxy,
memory: *gpu.GpuMemory,
single_time: *core.SingleTime,

sampler: vk.Sampler = .null_handle,
build_set_layout: vk.DescriptorSetLayout = .null_handle,
build_pipeline_layout: vk.PipelineLayout = .null_handle,
build_pipeline: vk.Pipeline = .null_handle,
/// Push-descriptor set layout consumers add to their culling pipeline layouts.
occlusion_set_layout: vk.DescriptorSetLayout = .null_handle,

image: vk.Image = .null_handle,
image_memory: vk.DeviceMemory = .null_handle,
/// View over the whole mip chain, sampled by occlusion tests via texelFetch.
full_view: vk.ImageView = .null_handle,
/// One single-mip view per level, used as reduce source and storage destination.
mip_views: []vk.ImageView = &.{},
depth_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
/// Mip 0 dimensions: half the depth buffer, so the first reduce is also the copy.
width: u32 = 0,
height: u32 = 0,

frame_params: []FrameParams = &.{},

pub fn init(allocator: std.mem.Allocator, vk_ctx: *VulkanContext, memory: *gpu.GpuMemory, single_time: *core.SingleTime) !DepthPyramid {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "DepthPyramid.init" });
    defer zone.end();

    var self: DepthPyramid = .{
        .vk_ctx = vk_ctx,
        .allocator = allocator,
        .dev = vk_ctx.dev,
        .memory = memory,
        .single_time = single_time,
    };
    errdefer self.deinit();

    self.sampler = try core.createSampler(self.dev, &vk_ctx.vkalloc, .{ .mag_filter = .nearest, .min_filter = .nearest, .mipmap_mode = .nearest });

    const build_bindings: [2]vk.DescriptorSetLayoutBinding = .{
        .{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
        .{ .binding = 1, .descriptor_type = .storage_image, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
    };
    self.build_set_layout = try core.createDescriptorSetLayout(self.dev, &vk_ctx.vkalloc, .{ .push_descriptor_bit = true }, &build_bindings);

    const occlusion_bindings: [2]vk.DescriptorSetLayoutBinding = .{
        .{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
        .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
    };
    self.occlusion_set_layout = try core.createDescriptorSetLayout(self.dev, &vk_ctx.vkalloc, .{ .push_descriptor_bit = true }, &occlusion_bindings);

    const pc_range: vk.PushConstantRange = .{ .stage_flags = .{ .compute_bit = true }, .offset = 0, .size = @sizeOf(BuildPushConstants) };
    self.build_pipeline_layout = try self.dev.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = (&self.build_set_layout)[0..1],
        .push_constant_range_count = 1,
        .p_push_constant_ranges = (&pc_range)[0..1],
    }, &vk_ctx.vkalloc);

    const comp_module = try core.createShaderModule(self.dev, &vk_ctx.vkalloc, depth_pyramid_spv);
    defer self.dev.destroyShaderModule(comp_module, &vk_ctx.vkalloc);
    const cpci: vk.ComputePipelineCreateInfo = .{
        .flags = .{},
        .stage = core.shaderStageCreateInfo(.{ .compute_bit = true }, comp_module),
        .layout = self.build_pipeline_layout,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };
    if (self.dev.createComputePipelines(.null_handle, (&cpci)[0..1], &vk_ctx.vkalloc, (&self.build_pipeline)[0..1])) |res| {
        if (res != .success) return error.PipelineCreationFailed;
    } else |err| return err;

    const frame_params = try allocator.alloc(FrameParams, VulkanContext.max_frames_in_flight);
    var allocated: usize = 0;
    errdefer {
        for (frame_params[0..allocated]) |fp| memory.cpuToGpu().free(fp.slice);
        allocator.free(frame_params);
    }
    for (frame_params) |*fp| {
        const slice = try memory.cpuToGpu().alignedAlloc(Params, gpu.cull_buffer_alignment, 1);
        slice[0] = .{};
        const info = memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, slice.ptr);
        fp.* = .{ .slice = slice, .buffer = info.buffer, .offset = info.offset };
        allocated += 1;
    }
    self.frame_params = frame_params;

    return self;
}

pub fn deinit(self: *DepthPyramid) void {
    self.destroyImageResources();
    for (self.frame_params) |fp| self.memory.cpuToGpu().free(fp.slice);
    if (self.frame_params.len > 0) self.allocator.free(self.frame_params);
    self.frame_params = &.{};
    core.destroyIfValid(self.dev, &self.build_pipeline, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.build_pipeline_layout, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.build_set_layout, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.occlusion_set_layout, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.sampler, &self.vk_ctx.vkalloc);
}

/// (Re)creates the pyramid image for the given depth buffer extent. The caller must
/// guarantee the device is idle (same contract as the other render targets).
pub fn recreate(self: *DepthPyramid, io: std.Io, depth_extent: vk.Extent2D) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "DepthPyramid.recreate" });
    defer zone.end();
    if (self.image != .null_handle and depth_extent.width == self.depth_extent.width and depth_extent.height == self.depth_extent.height) return;

    self.destroyImageResources();
    errdefer self.destroyImageResources();

    self.depth_extent = depth_extent;
    self.width = @max(1, depth_extent.width / 2);
    self.height = @max(1, depth_extent.height / 2);
    const mip_count = std.math.log2_int(u32, @max(self.width, self.height)) + 1;

    const image_info: vk.ImageCreateInfo = .{
        .image_type = .@"2d",
        .extent = .{ .width = self.width, .height = self.height, .depth = 1 },
        .mip_levels = mip_count,
        .array_layers = 1,
        .format = .r32_sfloat,
        .tiling = .optimal,
        .initial_layout = .undefined,
        .usage = .{ .sampled_bit = true, .storage_bit = true, .transfer_dst_bit = true },
        .sharing_mode = .exclusive,
        .samples = .{ .@"1_bit" = true },
    };
    const alloc = try core.allocateImageWithMemory(self.dev, self.vk_ctx.mem_props, &self.vk_ctx.vkalloc, &image_info);
    self.image = alloc.image;
    self.image_memory = alloc.memory;

    var full_info = core.imageViewCreateInfo(self.image, .r32_sfloat, .{ .color_bit = true });
    full_info.subresource_range.level_count = mip_count;
    self.full_view = try self.dev.createImageView(&full_info, &self.vk_ctx.vkalloc);

    const mip_views = try self.allocator.alloc(vk.ImageView, mip_count);
    var created: usize = 0;
    errdefer {
        for (mip_views[0..created]) |view| self.dev.destroyImageView(view, &self.vk_ctx.vkalloc);
        self.allocator.free(mip_views);
    }
    for (mip_views, 0..) |*view, mip| {
        var info = core.imageViewCreateInfo(self.image, .r32_sfloat, .{ .color_bit = true });
        info.subresource_range.base_mip_level = @intCast(mip);
        view.* = try self.dev.createImageView(&info, &self.vk_ctx.vkalloc);
        created += 1;
    }
    self.mip_views = mip_views;

    try self.transitionToSampled(io);
    std.log.info("DepthPyramid.recreate: pyramid image {any}", .{self.image});
}

/// Writes the per-frame occlusion params. `projview` must be the exact matrix layout
/// pushed to the raster shaders (already transposed for GLSL) so occlusion tests see
/// the same transform the depth buffer was rendered with; `player_pos` is that view's
/// camera position (w = 1).
pub fn writeParams(self: *DepthPyramid, frame_idx: u32, projview: [16]f32, player_pos: [4]f32, enabled: bool) void {
    self.frame_params[frame_idx].slice[0] = .{
        .projview = projview,
        .occlusion_player_pos = player_pos,
        .pyramid_size = .{ @floatFromInt(self.width), @floatFromInt(self.height) },
        .mip_count = @intCast(self.mip_views.len),
        .enabled = @intFromBool(enabled),
    };
}

/// Pushes the occlusion descriptor set (sampled pyramid + params) for a compute
/// pipeline whose layout includes `occlusion_set_layout` at `set_index`.
pub fn pushOcclusionSet(self: *DepthPyramid, cmd: vk.CommandBuffer, pipeline_layout: vk.PipelineLayout, set_index: u32, frame_idx: u32) void {
    const image_info: vk.DescriptorImageInfo = .{ .sampler = self.sampler, .image_view = self.full_view, .image_layout = .shader_read_only_optimal };
    const params = &self.frame_params[frame_idx];
    const buffer_info: vk.DescriptorBufferInfo = .{ .buffer = params.buffer, .offset = params.offset, .range = @sizeOf(Params) };
    var writes: [2]vk.WriteDescriptorSet = .{
        core.imageWriteDescriptorSet(.null_handle, 0, &image_info),
        core.bufferWriteDescriptorSet(.null_handle, 1, .storage_buffer, &buffer_info),
    };
    self.dev.cmdPushDescriptorSetKHR(cmd, .compute, pipeline_layout, set_index, &writes);
}

/// Records the full pyramid build from the depth buffer, which must be in
/// depth_stencil_read_only_optimal with its writes visible to compute sampling.
/// Deferred to the end of the frame: the cull dispatches consume the previous
/// frame's build, so a mesh's own pixels cannot keep it visible. Ends with every
/// mip in shader_read_only_optimal, visible to compute reads.
pub fn recordBuild(self: *DepthPyramid, cmd: vk.CommandBuffer, depth_sampled_view: vk.ImageView) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "DepthPyramid.recordBuild" });
    defer zone.end();

    self.dev.cmdBindPipeline(cmd, .compute, self.build_pipeline);

    var src_width = self.depth_extent.width;
    var src_height = self.depth_extent.height;
    for (self.mip_views, 0..) |dst_view, mip| {
        const dst_width = mipDim(self.width, mip);
        const dst_height = mipDim(self.height, mip);

        var barriers: [2]vk.ImageMemoryBarrier2 = undefined;
        var barrier_count: usize = 0;
        if (mip > 0) {
            barriers[barrier_count] = self.mipBarrier(mip - 1, .general, .shader_read_only_optimal, .{ .shader_write_bit = true }, .{ .shader_read_bit = true });
            barrier_count += 1;
        }
        // This frame's cull already read every mip; the rebuild must wait for those reads.
        barriers[barrier_count] = self.mipBarrier(mip, .shader_read_only_optimal, .general, .{ .shader_read_bit = true }, .{ .shader_write_bit = true });
        barrier_count += 1;
        core.pipelineBarrier(cmd, self.dev, vk.ImageMemoryBarrier2, barriers[0..barrier_count]);

        const src_view = if (mip == 0) depth_sampled_view else self.mip_views[mip - 1];
        const src_layout: vk.ImageLayout = if (mip == 0) .depth_stencil_read_only_optimal else .shader_read_only_optimal;
        self.pushBuildSet(cmd, src_view, src_layout, dst_view);

        const push_constants: BuildPushConstants = .{
            .src_width = @intCast(src_width),
            .src_height = @intCast(src_height),
            .dst_width = @intCast(dst_width),
            .dst_height = @intCast(dst_height),
        };
        self.dev.cmdPushConstants(cmd, self.build_pipeline_layout, .{ .compute_bit = true }, 0, @sizeOf(BuildPushConstants), &push_constants);
        self.dev.cmdDispatch(cmd, ceilDiv(dst_width, build_workgroup_size), ceilDiv(dst_height, build_workgroup_size), 1);

        src_width = dst_width;
        src_height = dst_height;
    }

    core.pipelineBarrier(cmd, self.dev, vk.ImageMemoryBarrier2, (&self.mipBarrier(self.mip_views.len - 1, .general, .shader_read_only_optimal, .{ .shader_write_bit = true }, .{ .shader_read_bit = true }))[0..1]);
}

fn destroyImageResources(self: *DepthPyramid) void {
    for (self.mip_views) |view| self.dev.destroyImageView(view, &self.vk_ctx.vkalloc);
    if (self.mip_views.len > 0) self.allocator.free(self.mip_views);
    self.mip_views = &.{};
    core.destroyIfValid(self.dev, &self.full_view, &self.vk_ctx.vkalloc);
    core.destroyImageWithMemory(self.dev, &self.image, &self.image_memory, &self.vk_ctx.vkalloc);
}

/// Clears every mip to the far plane (0.0) and puts them in shader_read_only_optimal,
/// so the first frame's cull (which consumes the previous build) sees nothing occluded.
/// Called on (re)creation, when the device is idle.
fn transitionToSampled(self: *DepthPyramid, io: std.Io) !void {
    const cmd = try self.single_time.begin();
    const range = vk.ImageSubresourceRange{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = @intCast(self.mip_views.len),
        .base_array_layer = 0,
        .layer_count = 1,
    };
    core.pipelineBarrier(cmd, self.dev, vk.ImageMemoryBarrier2, (&core.imageBarrier2Range(
        self.image,
        range,
        .undefined,
        .general,
        .{ .top_of_pipe_bit = true },
        .{},
        .{ .all_transfer_bit = true },
        .{ .transfer_write_bit = true },
    ))[0..1]);
    self.dev.cmdClearColorImage(cmd, self.image, .general, &vk.ClearColorValue{ .float_32 = .{ 0, 0, 0, 0 } }, (&range)[0..1]);
    core.pipelineBarrier(cmd, self.dev, vk.ImageMemoryBarrier2, (&core.imageBarrier2Range(
        self.image,
        range,
        .general,
        .shader_read_only_optimal,
        .{ .all_transfer_bit = true },
        .{ .transfer_write_bit = true },
        .{ .compute_shader_bit = true },
        .{ .shader_read_bit = true },
    ))[0..1]);
    try self.single_time.end(io, cmd);
}

fn pushBuildSet(self: *DepthPyramid, cmd: vk.CommandBuffer, src_view: vk.ImageView, src_layout: vk.ImageLayout, dst_view: vk.ImageView) void {
    const src_info: vk.DescriptorImageInfo = .{ .sampler = self.sampler, .image_view = src_view, .image_layout = src_layout };
    const dst_info: vk.DescriptorImageInfo = .{ .sampler = .null_handle, .image_view = dst_view, .image_layout = .general };
    var writes: [2]vk.WriteDescriptorSet = .{
        core.imageWriteDescriptorSet(.null_handle, 0, &src_info),
        core.storageImageWriteDescriptorSet(.null_handle, 1, &dst_info),
    };
    self.dev.cmdPushDescriptorSetKHR(cmd, .compute, self.build_pipeline_layout, 0, &writes);
}

fn mipBarrier(self: *const DepthPyramid, mip: usize, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout, src_access: vk.AccessFlags2, dst_access: vk.AccessFlags2) vk.ImageMemoryBarrier2 {
    return core.imageBarrier2Range(
        self.image,
        .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = @intCast(mip), .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        old_layout,
        new_layout,
        .{ .compute_shader_bit = true },
        src_access,
        .{ .compute_shader_bit = true },
        dst_access,
    );
}

fn mipDim(base: u32, mip: usize) u32 {
    return @max(1, base >> @as(u5, @intCast(mip)));
}

fn ceilDiv(value: u32, divisor: u32) u32 {
    return (value + divisor - 1) / divisor;
}

test "mipDim halves down to one" {
    try std.testing.expectEqual(@as(u32, 960), mipDim(960, 0));
    try std.testing.expectEqual(@as(u32, 480), mipDim(960, 1));
    try std.testing.expectEqual(@as(u32, 1), mipDim(960, 10));
    try std.testing.expectEqual(@as(u32, 1), mipDim(1, 5));
}
