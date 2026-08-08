const std = @import("std");
const tracy = @import("tracy");
const vk = @import("vulkan");

const DeviceProxy = vk.DeviceProxy;

const Renderer = @import("../../../Renderer.zig");
const VulkanContext = @import("../../../VulkanContext.zig").VulkanContext;
const core = @import("../core.zig");
const gpu = @import("../gpu.zig");
const Csm = @import("Csm.zig");
const Frustum = @import("../Frustum.zig").Frustum;

const shadow_vert_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("shadow_vert_spv")));

/// std430 storage-block layout mirrored by shadow.glsl. Fixed MAX_CASCADES arrays
/// (matching the GLSL `float [MAX_CASCADES]` members) keep the layout stable across
/// a runtime cascade_count change.
pub const ShadowParams = extern struct {
    light_viewproj: [Csm.MAX_CASCADES][16]f32,
    split_radius: [Csm.MAX_CASCADES]f32 align(16),
    texel_world_size: [Csm.MAX_CASCADES]f32 align(16),
    box_radius: [Csm.MAX_CASCADES]f32 align(16),
    depth_bias_constant: [Csm.MAX_CASCADES]f32 align(16),
    normal_bias_scale: [Csm.MAX_CASCADES]f32 align(16),
    pcf_radius_texels: [Csm.MAX_CASCADES]f32 align(16),
    blend_fraction: f32,
    fade_start: f32,
    fade_end: f32,
    cascade_count: u32,
    shadow_strength: f32,
    debug_colors: u32,
    _pad: [2]f32,

    pub fn default() ShadowParams {
        return .{
            .light_viewproj = @splat(@splat(0.0)),
            .split_radius = @splat(0.0),
            .texel_world_size = @splat(0.0),
            .box_radius = @splat(0.0),
            .depth_bias_constant = @splat(0.0),
            .normal_bias_scale = @splat(0.0),
            .pcf_radius_texels = @splat(0.0),
            .blend_fraction = 0.0,
            .fade_start = 0.0,
            .fade_end = 0.0,
            .cascade_count = 0,
            .shadow_strength = 0.0,
            .debug_colors = 0,
            ._pad = .{ 0, 0 },
        };
    }
};

comptime {
    if (@offsetOf(ShadowParams, "split_radius") != 2048) @compileError("ShadowParams.split_radius offset mismatch (expected 2048)");
    if (@offsetOf(ShadowParams, "texel_world_size") != 2176) @compileError("ShadowParams.texel_world_size offset mismatch (expected 2176)");
    if (@offsetOf(ShadowParams, "box_radius") != 2304) @compileError("ShadowParams.box_radius offset mismatch (expected 2304)");
    if (@offsetOf(ShadowParams, "depth_bias_constant") != 2432) @compileError("ShadowParams.depth_bias_constant offset mismatch (expected 2432)");
    if (@offsetOf(ShadowParams, "normal_bias_scale") != 2560) @compileError("ShadowParams.normal_bias_scale offset mismatch (expected 2560)");
    if (@offsetOf(ShadowParams, "pcf_radius_texels") != 2688) @compileError("ShadowParams.pcf_radius_texels offset mismatch (expected 2688)");
    if (@offsetOf(ShadowParams, "blend_fraction") != 2816) @compileError("ShadowParams.blend_fraction offset mismatch (expected 2816)");
    if (@offsetOf(ShadowParams, "fade_start") != 2820) @compileError("ShadowParams.fade_start offset mismatch (expected 2820)");
    if (@offsetOf(ShadowParams, "fade_end") != 2824) @compileError("ShadowParams.fade_end offset mismatch (expected 2824)");
    if (@offsetOf(ShadowParams, "cascade_count") != 2828) @compileError("ShadowParams.cascade_count offset mismatch (expected 2828)");
    if (@offsetOf(ShadowParams, "shadow_strength") != 2832) @compileError("ShadowParams.shadow_strength offset mismatch (expected 2832)");
    if (@offsetOf(ShadowParams, "debug_colors") != 2836) @compileError("ShadowParams.debug_colors offset mismatch (expected 2836)");
    if (@sizeOf(ShadowParams) != 2848) @compileError("ShadowParams size mismatch (expected 2848)");
}

const ShadowPushConstants = extern struct {
    light_viewproj: [16]f32,
    mesh_base: u32,
};

comptime {
    if (@sizeOf(ShadowPushConstants) != 68) @compileError("ShadowPushConstants size mismatch with GLSL layout (expected 68)");
    if (@sizeOf(ShadowPushConstants) > 128) @compileError("ShadowPushConstants exceeds max push constant size");
}

const ParamBuffer = struct {
    mapping: []align(16) u8,
};

/// Owns the shadow depth texture array (1 layer per cascade), the depth-only pipeline,
/// the per-frame ShadowParams storage buffer, the comparison sampler, the shared
/// push-descriptor set layout, committed-matrix state, and the update schedule cursor.
/// Shadows are rasterised at the end of the frame and sampled on the next one; at most
/// one cascade is refreshed per frame (see Csm.schedule), keeping frame time flat.
pub const ShadowRenderer = @This();

vk_ctx: *VulkanContext,
allocator: std.mem.Allocator,
dev: DeviceProxy,
memory: *gpu.GpuMemory,
single_time: *core.SingleTime,
scene: *gpu.IndirectScene,
render_options: *const Renderer.RenderOptions,
render_options_lock: *std.Io.RwLock,

image: vk.Image = .null_handle,
image_memory: vk.DeviceMemory = .null_handle,
views: []vk.ImageView = &.{},
/// 2D-array view of every layer; the fragment shaders sample this as sampler2DArrayShadow.
array_view: vk.ImageView = .null_handle,
format: vk.Format = .undefined,
map_size: u32 = 0,
cascade_count: u32 = 0,

shadow_set_layout: vk.DescriptorSetLayout = .null_handle,
pipeline: vk.Pipeline = .null_handle,
pipeline_layout: vk.PipelineLayout = .null_handle,
compare_sampler: vk.Sampler = .null_handle,
param_buffers: []ParamBuffer = &.{},

/// Committed per-cascade data (snapped center, box, light basis) rebuilt into a
/// per-frame matrix by `viewProjAtOrigin`.
committed: [Csm.MAX_CASCADES]Csm.CommittedCascade = @splat(.{ .center_abs = .{ 0, 0, 0 }, .radius = 1.0, .near_plane = 0.0, .far_plane = 1.0, .light_dir = .{ 0.0, 0.0, -1.0 } }),
/// Latched light direction for the current schedule period (direction light travels).
light_dir: Csm.Vec3f = .{ 0.0, 0.0, -1.0 },
/// Per-cascade commit validity. The params cascade_count is the largest contiguous
/// valid prefix (0, 1, …, k-1), so a stale or never-committed cascade beyond the prefix
/// is never classified into — the shader's cascade_count early-outs before it.
valid: [Csm.MAX_CASCADES]bool = @splat(false),
/// Whether shadows were active last frame; a false->true transition means the sun just
/// rose and the committed state belongs to the pre-night light direction.
was_active: bool = false,
/// Smoothed camera movement in blocks per frame, measured from the view_pos delta.
/// Used for staleness padding so a stationary player keeps a tight, stable box (the max
/// fly speed would grow the box while standing still and cause texel-swimming flicker).
per_frame_dist: f32 = 0.0,
last_view_pos: @Vector(3, f64) = .{ 0, 0, 0 },
last_prepare_ns: i128 = 0,

/// Frame counter advanced each prepareFrame; picks the cascade via the schedule table.
schedule_index: u32 = 0,
/// Cascade being refreshed this frame, if any.
frame_cascade: ?u32 = null,
/// When refresh-all-each-frame is enabled, every cascade is committed and rastered this
/// frame; frame_cascade is null and the cull runs against the outermost cascade's box.
refresh_all: bool = false,
/// Number of cascades to raster this frame (count when refresh_all, else 1).
frame_cascade_count: u32 = 1,
/// Camera origin the frame's matrix was committed at (for the end-of-frame raster).
frame_origin: @Vector(3, f64) = .{ 0, 0, 0 },
/// Cull planes for the frame's cascade, camera-relative.
frame_planes: [6]@Vector(4, f32) = undefined,
frame_min_chunk_size: f32 = 0.0,

config_applied: Csm.ShadowConfig = undefined,

pub fn init(
    allocator: std.mem.Allocator,
    vk_ctx: *VulkanContext,
    memory: *gpu.GpuMemory,
    single_time: *core.SingleTime,
    scene: *gpu.IndirectScene,
    render_options: *const Renderer.RenderOptions,
    render_options_lock: *std.Io.RwLock,
) !ShadowRenderer {
    var self: ShadowRenderer = .{
        .allocator = allocator,
        .vk_ctx = vk_ctx,
        .dev = vk_ctx.dev,
        .memory = memory,
        .single_time = single_time,
        .scene = scene,
        .render_options = render_options,
        .render_options_lock = render_options_lock,
    };
    errdefer self.deinit();

    try self.createSharedSetLayout();
    try self.createSampler();
    try self.createPipelineLayout();
    self.config_applied = .{};

    self.param_buffers = try allocator.alloc(ParamBuffer, VulkanContext.max_frames_in_flight);
    for (self.param_buffers) |*buf| buf.* = .{ .mapping = &.{} };
    for (self.param_buffers) |*buf| {
        buf.mapping = try memory.cpuToGpu().alignedAlloc(u8, .fromByteUnits(16), @sizeOf(ShadowParams));
    }

    return self;
}

pub fn deinit(self: *ShadowRenderer) void {
    for (self.param_buffers) |*buf| {
        if (buf.mapping.len > 0) self.memory.cpuToGpu().free(buf.mapping);
    }
    if (self.param_buffers.len > 0) {
        self.allocator.free(self.param_buffers);
        self.param_buffers = &.{};
    }

    core.destroyIfValid(self.dev, &self.compare_sampler, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.pipeline, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.pipeline_layout, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.shadow_set_layout, &self.vk_ctx.vkalloc);
    self.destroyShadowImage();
}

fn createSharedSetLayout(self: *ShadowRenderer) !void {
    const bindings: [3]vk.DescriptorSetLayoutBinding = .{
        .{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
        .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
        .{ .binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
    };
    self.shadow_set_layout = try self.dev.createDescriptorSetLayout(&.{ .flags = .{ .push_descriptor_bit = true }, .binding_count = bindings.len, .p_bindings = bindings[0..] }, &self.vk_ctx.vkalloc);
}

fn createSampler(self: *ShadowRenderer) !void {
    self.compare_sampler = try self.dev.createSampler(&.{
        .flags = .{},
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .nearest,
        .address_mode_u = .clamp_to_border,
        .address_mode_v = .clamp_to_border,
        .address_mode_w = .clamp_to_border,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1.0,
        .compare_enable = .true,
        .compare_op = .less_or_equal,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .float_opaque_white,
        .unnormalized_coordinates = .false,
    }, &self.vk_ctx.vkalloc);
}

fn createPipelineLayout(self: *ShadowRenderer) !void {
    if (self.pipeline_layout != .null_handle) return;
    const pc_range: vk.PushConstantRange = .{
        .stage_flags = .{ .vertex_bit = true },
        .offset = 0,
        .size = @sizeOf(ShadowPushConstants),
    };
    self.pipeline_layout = try self.dev.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = (&self.scene.mesh_data_descriptor_set_layout)[0..1],
        .push_constant_range_count = 1,
        .p_push_constant_ranges = (&pc_range)[0..1],
    }, &self.vk_ctx.vkalloc);
}

fn createPipeline(self: *ShadowRenderer) !void {
    const vert_module = try core.createShaderModule(self.dev, &self.vk_ctx.vkalloc, shadow_vert_spv);
    defer self.dev.destroyShaderModule(vert_module, &self.vk_ctx.vkalloc);

    core.destroyIfValid(self.dev, &self.pipeline, &self.vk_ctx.vkalloc);
    self.pipeline = try core.buildDepthOnlyPipeline(
        self.dev,
        &self.vk_ctx.vkalloc,
        self.vk_ctx.pipeline_creation_feedback,
        vert_module,
        self.format,
        self.pipeline_layout,
        gpu.MeshUploader.faceVertexInputState(),
        self.config_applied.depth_bias_constant,
        self.config_applied.depth_bias_slope,
        if (self.vk_ctx.depth_bias_clamp) self.config_applied.depth_bias_clamp else 0.0,
        self.vk_ctx.depth_clamp,
    );
}

/// Allocates (or recreates) the shadow depth array and per-cascade views. Called from
/// init and on config change; never mid-frame (it device-waits). Only resource-affecting
/// fields (image shape/format and pipeline-static states) force a recreate; the rest is
/// read live by prepareFrame.
pub fn recreate(self: *ShadowRenderer, io: std.Io, config: Csm.ShadowConfig) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "shadow_recreate" });
    defer zone.end();
    const count = @min(config.cascade_count, Csm.MAX_CASCADES);
    const size = config.shadow_map_size;
    const want_format: vk.Format = switch (config.depth_format) {
        .d16 => .d16_unorm,
        .d32 => .d32_sfloat,
    };

    const same = self.image != .null_handle and
        self.cascade_count == count and
        self.map_size == size and
        self.format == want_format and
        self.config_applied.enabled == config.enabled and
        self.config_applied.depth_bias_constant == config.depth_bias_constant and
        self.config_applied.depth_bias_slope == config.depth_bias_slope and
        self.config_applied.depth_bias_clamp == config.depth_bias_clamp and
        self.config_applied.shadow_cull_mode == config.shadow_cull_mode;
    if (same) return;

    var applied = config;

    if (applied.cascade_count > Csm.MAX_CASCADES) {
        std.log.warn("ShadowRenderer: cascade_count {d} exceeds MAX_CASCADES {d}; clamping", .{ applied.cascade_count, Csm.MAX_CASCADES });
        applied.cascade_count = Csm.MAX_CASCADES;
    }

    {
        // Tear down under the queue mutex so no in-flight submission races the destroy.
        self.vk_ctx.queue_mutex.lockUncancelable(io);
        defer self.vk_ctx.queue_mutex.unlock(io);
        _ = try self.dev.deviceWaitIdle();
        self.destroyShadowImage();
        core.destroyIfValid(self.dev, &self.pipeline, &self.vk_ctx.vkalloc);
        self.config_applied = applied;
        self.cascade_count = count;
        self.map_size = size;
        self.valid = @splat(false);
    }

    if (!applied.enabled or count == 0 or size == 0) return;

    errdefer self.destroyShadowImage();

    // Pick a supported depth format among the request's candidates.
    const candidates: []const vk.Format = switch (applied.depth_format) {
        .d16 => &.{ .d16_unorm, .d32_sfloat },
        .d32 => &.{ .d32_sfloat, .d16_unorm },
    };
    self.format = .undefined;
    for (candidates) |fmt| {
        const features = self.vk_ctx.instance.getPhysicalDeviceFormatProperties(self.vk_ctx.pdev, fmt).optimal_tiling_features;
        if (features.depth_stencil_attachment_bit and features.sampled_image_bit) {
            self.format = fmt;
            break;
        }
    }
    if (self.format == .undefined) return error.ShadowDepthFormatNotSupported;

    const image_info: vk.ImageCreateInfo = .{
        .image_type = .@"2d",
        .extent = .{ .width = size, .height = size, .depth = 1 },
        .mip_levels = 1,
        .array_layers = count,
        .format = self.format,
        .tiling = .optimal,
        .initial_layout = .undefined,
        .usage = .{ .depth_stencil_attachment_bit = true, .sampled_bit = true, .transfer_dst_bit = true },
        .sharing_mode = .exclusive,
        .samples = .{ .@"1_bit" = true },
    };
    var mem_reqs2: vk.MemoryRequirements2 = .{ .memory_requirements = undefined };
    self.dev.getDeviceImageMemoryRequirements(&.{ .p_create_info = &image_info, .plane_aspect = .{} }, &mem_reqs2);
    const mem_reqs = mem_reqs2.memory_requirements;
    const alloc_info: vk.MemoryAllocateInfo = .{
        .allocation_size = mem_reqs.size,
        .memory_type_index = try core.findMemoryType(self.vk_ctx.mem_props, mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    };

    self.image_memory = try self.dev.allocateMemory(&alloc_info, &self.vk_ctx.vkalloc);
    self.image = try self.dev.createImage(&image_info, &self.vk_ctx.vkalloc);
    try self.dev.bindImageMemory(self.image, self.image_memory, 0);

    self.views = try self.allocator.alloc(vk.ImageView, count);
    for (self.views) |*view| view.* = .null_handle;
    const aspect: vk.ImageAspectFlags = .{ .depth_bit = true };
    for (0..count) |i| {
        self.views[i] = try self.dev.createImageView(&.{
            .flags = .{},
            .image = self.image,
            .view_type = .@"2d",
            .format = self.format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = aspect,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = @intCast(i),
                .layer_count = 1,
            },
        }, &self.vk_ctx.vkalloc);
    }
    self.array_view = try self.dev.createImageView(&.{
        .flags = .{},
        .image = self.image,
        .view_type = .@"2d_array",
        .format = self.format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = count,
        },
    }, &self.vk_ctx.vkalloc);

    // Frame 0 samples "fully lit": clear every layer to far depth and leave the array
    // in SHADER_READ_ONLY_OPTIMAL so the first frame has no undefined-layout reads.
    try self.clearDepthArray(io);
    try self.createPipeline();
    self.valid = @splat(false);
}

fn destroyShadowImage(self: *ShadowRenderer) void {
    if (self.views.len > 0) {
        for (self.views) |view| {
            if (view != .null_handle) self.dev.destroyImageView(view, &self.vk_ctx.vkalloc);
        }
        self.allocator.free(self.views);
        self.views = &.{};
    }
    core.destroyIfValid(self.dev, &self.array_view, &self.vk_ctx.vkalloc);
    if (self.image != .null_handle) self.dev.destroyImage(self.image, &self.vk_ctx.vkalloc);
    if (self.image_memory != .null_handle) self.dev.freeMemory(self.image_memory, &self.vk_ctx.vkalloc);
    self.image = .null_handle;
    self.image_memory = .null_handle;
}

fn clearDepthArray(self: *ShadowRenderer, io: std.Io) !void {
    const cmd = try self.single_time.begin();

    const depth_aspect: vk.ImageAspectFlags = .{ .depth_bit = true };

    // makeImageBarrier2 only covers a single layer; these barriers span the whole array.
    const pre_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .top_of_pipe_bit = true },
        .src_access_mask = .{},
        .dst_stage_mask = .{ .all_transfer_bit = true },
        .dst_access_mask = .{ .transfer_write_bit = true },
        .old_layout = .undefined,
        .new_layout = .transfer_dst_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = self.image,
        .subresource_range = .{
            .aspect_mask = depth_aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = self.cascade_count,
        },
    };
    self.dev.cmdPipelineBarrier2(cmd, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = (&pre_barrier)[0..1],
    });

    self.dev.cmdClearDepthStencilImage(cmd, self.image, .transfer_dst_optimal, &.{
        .depth = 1.0,
        .stencil = 0,
    }, &.{
        .{
            .aspect_mask = depth_aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = self.cascade_count,
        },
    });

    // transfer dst -> shader read (fragment sampling)
    const post_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_transfer_bit = true },
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_stage_mask = .{ .fragment_shader_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true },
        .old_layout = .transfer_dst_optimal,
        .new_layout = .shader_read_only_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = self.image,
        .subresource_range = .{
            .aspect_mask = depth_aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = self.cascade_count,
        },
    };
    self.dev.cmdPipelineBarrier2(cmd, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = (&post_barrier)[0..1],
    });

    self.single_time.end(io, cmd) catch |err| {
        std.log.err("ShadowRenderer: failed to clear depth array: {any}", .{err});
        return err;
    };
}

/// Computes the frame's cascade, commits it, and writes the per-frame params. Called
/// every frame before the command buffer begins; `sun_dir` is the live sky direction,
/// latched here once per schedule period so refreshed cascades share a light basis.
pub fn prepareFrame(
    self: *ShadowRenderer,
    io: std.Io,
    frame_idx: u32,
    view_pos: @Vector(3, f64),
    aspect: f32,
    fov_y: f32,
    camera_front: @Vector(3, f32),
    sun_dir: Csm.Vec3f,
    scene_min: [3]f64,
    scene_max: [3]f64,
) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "shadow_prepareFrame" });
    defer zone.end();

    // Measure the actual camera movement in blocks per frame (smoothed) for staleness
    // padding. Using the player's max fly speed here would grow the cascade boxes while
    // standing still, making the shadow map coarser and causing texel-swimming flicker.
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    if (self.last_prepare_ns != 0) {
        const dt_sec = @as(f32, @floatFromInt(now_ns - self.last_prepare_ns)) / std.time.ns_per_s;
        const delta = view_pos - self.last_view_pos;
        const dist: f32 = @floatCast(@sqrt(delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2]));
        const speed = dist / @max(dt_sec, 1e-6);
        self.per_frame_dist = std.math.lerp(self.per_frame_dist, speed, 0.3);
    }
    self.last_prepare_ns = now_ns;
    self.last_view_pos = view_pos;

    // The caller (VulkanRenderer.draw) holds the options lock; read the live config so
    // non-resource changes (blend, fade, strength, schedule, splits) apply immediately.
    var config = self.render_options.shadow;
    const count = @min(config.cascade_count, Csm.MAX_CASCADES);
    if (!Csm.validateSchedule(config.schedule, config.schedule_period, count)) {
        config.schedule = Csm.defaultSchedule(count);
        config.schedule_period = @intCast(count);
    }
    self.frame_cascade = null;
    self.refresh_all = false;
    self.frame_cascade_count = 1;

    const period: u32 = @max(@as(u32, config.schedule_period), 1);
    var light_dir_changed = false;
    if (self.schedule_index % period == 0) {
        const clamped = Csm.clampSunElevation(sun_dir, config.min_sun_elevation_deg);
        const new_light_dir = Csm.lightDirFromSunDir(clamped);
        // A ~25° or larger turn (horizon crossing, azimuth flip) invalidates the cached
        // light basis; gradual day-cycle drift stays below it so it never re-ramps.
        if (Csm.dot3f(self.light_dir, new_light_dir) < 0.9) light_dir_changed = true;
        self.light_dir = new_light_dir;
    }

    const sun_day = Csm.sunDayFromSunDir(sun_dir);
    const active = config.enabled and self.image != .null_handle and sun_day > 0.0 and count > 0;

    // When the light direction changes meaningfully (sunrise, or the sun re-latched to a
    // new basis), every committed cascade still holds a matrix and depth content built
    // for the old sun. Reset the ramp so uncommitted cascades sample as fully lit rather
    // than projecting shadows from the previous light direction.
    if ((active and !self.was_active) or light_dir_changed) {
        self.valid = @splat(false);
    }
    self.was_active = active;

    if (active) {
        self.frame_origin = view_pos;
        if (config.refresh_all_each_frame) {
            // Recompute and re-raster every cascade this frame. Cull once against the
            // outermost cascade's box with the finest (cascade 0) min chunk size so the
            // superset geometry feeds every cascade's raster; each layer projects through
            // its own matrix, clipping to its own box.
            for (0..count) |c| {
                const ctx = Csm.CascadeContext{
                    .cfg = config,
                    .fov_y = fov_y,
                    .aspect = aspect,
                    .camera_front = camera_front,
                    .view_pos = view_pos,
                    .light_dir = self.light_dir,
                    .scene_min = .{ scene_min[0], scene_min[1], scene_min[2] },
                    .scene_max = .{ scene_max[0], scene_max[1], scene_max[2] },
                    .per_frame_dist = self.per_frame_dist,
                };
                const cascade = Csm.computeCascade(ctx, @intCast(c));
                self.committed[c] = Csm.committedOf(cascade);
                self.valid[c] = true;
                if (c == count - 1) {
                    self.frame_planes = cullPlanes(cascade.center_abs, cascade.light_dir, cascade.radius, cascade.near_plane, cascade.far_plane, view_pos);
                }
                if (c == 0) self.frame_min_chunk_size = config.min_chunk_texels * cascade.texel;
            }
            self.refresh_all = true;
            self.frame_cascade_count = count;
            self.frame_cascade = @intCast(count);
        } else {
            const cascade_index = config.schedule[self.schedule_index % period];
            if (cascade_index < count) {
                const ctx = Csm.CascadeContext{
                    .cfg = config,
                    .fov_y = fov_y,
                    .aspect = aspect,
                    .camera_front = camera_front,
                    .view_pos = view_pos,
                    .light_dir = self.light_dir,
                    .scene_min = .{ scene_min[0], scene_min[1], scene_min[2] },
                    .scene_max = .{ scene_max[0], scene_max[1], scene_max[2] },
                    .per_frame_dist = self.per_frame_dist,
                };
                const cascade = Csm.computeCascade(ctx, cascade_index);
                self.committed[cascade_index] = Csm.committedOf(cascade);
                self.valid[cascade_index] = true;
                self.frame_cascade = cascade_index;

                self.frame_planes = cullPlanes(cascade.center_abs, cascade.light_dir, cascade.radius, cascade.near_plane, cascade.far_plane, view_pos);
                self.frame_min_chunk_size = config.min_chunk_texels * cascade.texel;
            }
        }
    }

    // Params are written every frame (origin compensation changes every frame), for all
    // committed cascades. The shader's cascade_count is gated on how many cascades have
    // been committed: classifying into an uncommitted cascade would project through a
    // garbage matrix. Uncommitted cascades read cleared maps -> lit.
    var params = ShadowParams.default();
    // Largest contiguous valid prefix: cascades 0..active_count-1 are all committed.
    var active_count: u32 = 0;
    while (active_count < count and self.valid[active_count]) active_count += 1;
    if (active and active_count > 0) {
        params.cascade_count = active_count;
        const splits = Csm.splitRadii(config);
        for (0..active_count) |c| {
            const committed = self.committed[c];
            for (Csm.viewProjAtOrigin(committed, view_pos), 0..) |v, i| {
                params.light_viewproj[c][i] = v;
            }
            params.split_radius[c] = splits[c];
            params.texel_world_size[c] = 2.0 * committed.radius / @as(f32, @floatFromInt(self.map_size));
            params.box_radius[c] = committed.radius;
            params.depth_bias_constant[c] = config.depth_bias_constant;
            params.normal_bias_scale[c] = config.normal_bias_scale;
            params.pcf_radius_texels[c] = config.pcf_radius_texels;
        }
        params.blend_fraction = config.blend_fraction;
        params.fade_start = config.max_shadow_distance * config.fade_fraction;
        params.fade_end = config.max_shadow_distance;
        params.shadow_strength = config.shadow_strength;
        params.debug_colors = @intFromBool(config.debug_cascade_colors);
    }

    @memcpy(self.param_buffers[frame_idx].mapping[0..@sizeOf(ShadowParams)], std.mem.asBytes(&params));

    self.schedule_index +%= 1;
}

/// Frustum planes for the frame's cascade, camera-relative, matching Frustum's
/// inside = normal·p + w >= 0 convention. The range matches the projection exactly so
/// the cull and the raster agree about which geometry is inside the cascade; nothing
/// outside the projected depth range is culled in, so depth clamping never paints
/// false occluder depth at the map edges.
fn cullPlanes(center: Csm.Vec3d, light_dir: Csm.Vec3f, radius: f32, near: f32, far: f32, view_pos: @Vector(3, f64)) [6]@Vector(4, f32) {
    const basis = Csm.buildLightBasis(light_dir, Csm.world_up);
    const c: Csm.Vec3f = .{ @floatCast(center[0] - view_pos[0]), @floatCast(center[1] - view_pos[1]), @floatCast(center[2] - view_pos[2]) };
    const s = basis.right;
    const u = basis.up;
    const f = basis.forward;
    const s_c = Csm.dot3f(s, c);
    const u_c = Csm.dot3f(u, c);
    const f_c = Csm.dot3f(f, c);
    var planes: [6]@Vector(4, f32) = undefined;
    planes[0] = .{ s[0], s[1], s[2], -s_c + radius }; // left:  s·(p-c) >= -r
    planes[1] = .{ -s[0], -s[1], -s[2], s_c + radius }; // right: s·(p-c) <= r
    planes[2] = .{ u[0], u[1], u[2], -u_c + radius }; // bottom
    planes[3] = .{ -u[0], -u[1], -u[2], u_c + radius }; // top
    planes[4] = .{ f[0], f[1], f[2], -f_c - near }; // near:  f·(p-c) >= near
    planes[5] = .{ -f[0], -f[1], -f[2], f_c + far }; // far:   f·(p-c) <= far
    return planes;
}

pub fn frameHasCascade(self: *const ShadowRenderer) bool {
    return if (self.refresh_all) self.frame_cascade_count > 0 else self.frame_cascade != null;
}

pub fn frameCascadePlanes(self: *const ShadowRenderer) [6]@Vector(4, f32) {
    return self.frame_planes;
}

pub fn frameMinChunkSize(self: *const ShadowRenderer) f32 {
    return self.frame_min_chunk_size;
}

/// Descriptor info for binding 1 (the shadow array + comparison sampler). The sampler is
/// always valid so the push never trips VUID-VkWriteDescriptorSet-descriptorType-00325;
/// the image view is null when shadows are disabled (robustness2 null descriptor) and
/// the shader's cascade_count == 0 early-out means it is never sampled.
pub fn shadowImageInfo(self: *const ShadowRenderer) vk.DescriptorImageInfo {
    return .{
        .image_layout = .shader_read_only_optimal,
        .image_view = if (self.array_view == .null_handle) .null_handle else self.array_view,
        .sampler = self.compare_sampler,
    };
}

/// A valid-sampler/null-view descriptor for bindings the pipeline does not sample
/// (the opaque pipeline's binding 0), satisfying the combined-image-sampler VUID.
pub fn nullImageInfo(self: *const ShadowRenderer) vk.DescriptorImageInfo {
    return .{
        .image_layout = .shader_read_only_optimal,
        .image_view = .null_handle,
        .sampler = self.compare_sampler,
    };
}

pub fn paramsBufferInfo(self: *const ShadowRenderer, frame_idx: u32) vk.DescriptorBufferInfo {
    const info = self.memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, self.param_buffers[frame_idx].mapping.ptr);
    return .{ .buffer = info.buffer, .offset = info.offset, .range = @sizeOf(ShadowParams) };
}

/// Records the shadow raster pass for the frame's cascade. Must run inside the face
/// buffer acquire/release window (the draw binds it as a vertex buffer).
pub fn recordShadowPass(
    self: *ShadowRenderer,
    cmd_buffer: vk.CommandBuffer,
    frame_idx: u32,
    face_buffer: vk.Buffer,
    face_buffer_offset: vk.DeviceSize,
) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordShadowPass" });
    defer zone.end();
    // Match the main passes: while allocRegion grows the face buffer it is momentarily
    // null, and the draw would be skipped. Running the layout transitions and the clear
    // anyway would wipe a cascade's layer to fully lit for a frame — skip the whole
    // pass instead so the previous depth survives and the next refresh writes it.
    if (face_buffer == .null_handle) return;
    if (self.image == .null_handle) return;

    if (self.refresh_all) {
        for (0..self.frame_cascade_count) |c| {
            if (self.views.len <= c) continue;
            self.recordCascadePass(cmd_buffer, frame_idx, @intCast(c), face_buffer, face_buffer_offset);
        }
    } else {
        const cascade = self.frame_cascade orelse return;
        if (self.views.len <= cascade) return;
        self.recordCascadePass(cmd_buffer, frame_idx, cascade, face_buffer, face_buffer_offset);
    }
}

/// Records the depth raster for a single cascade layer: layout transitions, clear, and
/// the indirect draw of the frame's culled geometry through the cascade's light matrix.
fn recordCascadePass(
    self: *ShadowRenderer,
    cmd_buffer: vk.CommandBuffer,
    frame_idx: u32,
    cascade: u32,
    face_buffer: vk.Buffer,
    face_buffer_offset: vk.DeviceSize,
) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordCascadePass" });
    defer zone.end();

    const extent: vk.Extent2D = .{ .width = self.map_size, .height = self.map_size };
    const depth_aspect: vk.ImageAspectFlags = .{ .depth_bit = true };

    // Within-command-buffer dependency: this frame's fragment reads (opaque/transparent
    // sample the shadow array) precede the write to this cascade's layer. makeImageBarrier2
    // only covers layer 0, so the range is built by hand for the cascade layer.
    const pre_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .fragment_shader_bit = true },
        .src_access_mask = .{ .shader_read_bit = true },
        .dst_stage_mask = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .dst_access_mask = .{ .depth_stencil_attachment_write_bit = true },
        .old_layout = .shader_read_only_optimal,
        .new_layout = .depth_stencil_attachment_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = self.image,
        .subresource_range = .{
            .aspect_mask = depth_aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = cascade,
            .layer_count = 1,
        },
    };
    core.pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, (&pre_barrier)[0..1]);

    // Standard depth (not reversed-Z): ortho depth is linear, so clear to far (1.0) and
    // compare LESS_OR_EQUAL. The main pipeline's reversed-Z convention must NOT be used.
    const depth_attachment = core.renderingAttachmentDepthClear(self.views[cascade], .depth_stencil_attachment_optimal, 1.0);
    self.dev.cmdBeginRendering(cmd_buffer, &core.renderingInfo(extent, &.{}, &depth_attachment));

    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.pipeline);
    switch (self.config_applied.shadow_cull_mode) {
        .none => self.dev.cmdSetCullMode(cmd_buffer, .{}),
        .back => self.dev.cmdSetCullMode(cmd_buffer, .{ .back_bit = true }),
    }
    self.dev.cmdSetDepthCompareOp(cmd_buffer, .less_or_equal);
    self.dev.cmdSetDepthWriteEnable(cmd_buffer, .true);
    core.setViewportAndScissor(self.dev, cmd_buffer, extent);

    const mesh_desc_set = self.scene.mesh_data_descriptor_sets_per_frame[frame_idx];
    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.pipeline_layout, 0, (&mesh_desc_set)[0..1], null);

    // The matrix must match the params used when sampling next frame: rebuilt from
    // committed state at the origin the raster uses (the same origin the params were
    // written at this frame), so light-space coordinates are world-anchored.
    const committed = self.committed[cascade];
    var shadow_pc = ShadowPushConstants{
        .light_viewproj = Csm.viewProjAtOrigin(committed, self.frame_origin),
        .mesh_base = gpu.shadow_slot_base * self.scene.draw_capacity,
    };
    self.dev.cmdPushConstants(cmd_buffer, self.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(ShadowPushConstants), &shadow_pc);

    self.dev.cmdBindVertexBuffers(cmd_buffer, 0, (&face_buffer)[0..1], (&face_buffer_offset)[0..1]);

    const frame = &self.scene.frame_buffers.items[frame_idx];
    const indirect_offset = frame.indirect_draw_offset + @as(vk.DeviceSize, @intCast(gpu.shadow_slot_base * self.scene.draw_capacity * @sizeOf(vk.DrawIndirectCommand)));
    const count_offset = frame.count_offset + @as(vk.DeviceSize, @intCast(@offsetOf(gpu.CullCount, "shadow_count")));
    self.dev.cmdDrawIndirectCount(cmd_buffer, frame.indirect_draw, indirect_offset, frame.count, count_offset, self.scene.draw_capacity, @sizeOf(vk.DrawIndirectCommand));

    self.dev.cmdEndRendering(cmd_buffer);

    // Trailing transition back to sampled layout; visible to the next frame's fragment
    // reads without any top-of-frame barrier.
    const post_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .late_fragment_tests_bit = true },
        .src_access_mask = .{ .depth_stencil_attachment_write_bit = true },
        .dst_stage_mask = .{ .fragment_shader_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true },
        .old_layout = .depth_stencil_attachment_optimal,
        .new_layout = .shader_read_only_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = self.image,
        .subresource_range = .{
            .aspect_mask = depth_aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = cascade,
            .layer_count = 1,
        },
    };
    core.pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, (&post_barrier)[0..1]);
}

test "ShadowParams layout" {
    try std.testing.expectEqual(@as(usize, 736), @sizeOf(ShadowParams));
}
