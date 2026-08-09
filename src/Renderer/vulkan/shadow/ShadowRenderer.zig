const std = @import("std");

const tracy = @import("tracy");
const vk = @import("vulkan");
const DeviceProxy = vk.DeviceProxy;

const Renderer = @import("../../../Renderer.zig");
const VulkanContext = @import("../../../VulkanContext.zig").VulkanContext;
const core = @import("../core.zig");
const gpu = @import("../gpu.zig");
const Csm = @import("Csm.zig");

const shadow_vert_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("shadow_vert_spv")));

/// Lerp factor for the smoothed per-frame movement estimate (measureMovement).
const movement_smoothing: f32 = 0.3;
/// Cosine threshold below which the light direction is treated as a new basis (~25°).
const light_change_cos_threshold: f32 = 0.9;
/// How many of the near cascade's texels the light axis advances per re-orientation. texel =
/// 2*radius/map_size, so texel/radius = 2/map_size is constant across cascades; a step of
/// `light_step_texels * 2/map_size` radians moves a shadow boundary by ~`light_step_texels`
/// texels regardless of resolution. 1 texel is the smallest step a texel-quantized map can
/// make; the remaining step scales with texel size (raise shadow_map_size to shrink it).
const light_step_texels: f32 = 1.0;

/// std430 storage-block layout mirrored by shadow.glsl. Per-cascade members are fixed
/// MAX_CASCADES arrays (matching the GLSL `float [MAX_CASCADES]` members) so the layout
/// stays stable across a runtime cascade_count change; cascade-uniform values are scalars.
pub const ShadowParams = extern struct {
    light_viewproj: [Csm.MAX_CASCADES][16]f32,
    split_radius: [Csm.MAX_CASCADES]f32 align(16),
    texel_world_size: [Csm.MAX_CASCADES]f32 align(16),
    box_radius: [Csm.MAX_CASCADES]f32 align(16),
    normal_bias_scale: f32,
    blur_radius: f32,
    blend_fraction: f32,
    fade_start: f32,
    fade_end: f32,
    cascade_count: u32,
    shadow_strength: f32,
    debug_colors: u32,

    pub fn default() ShadowParams {
        return .{
            .light_viewproj = @splat(@splat(0.0)),
            .split_radius = @splat(0.0),
            .texel_world_size = @splat(0.0),
            .box_radius = @splat(0.0),
            .normal_bias_scale = 0.0,
            .blur_radius = 0.0,
            .blend_fraction = 0.0,
            .fade_start = 0.0,
            .fade_end = 0.0,
            .cascade_count = 0,
            .shadow_strength = 0.0,
            .debug_colors = 0,
        };
    }
};

comptime {
    if (@offsetOf(ShadowParams, "split_radius") != 2048) @compileError("ShadowParams.split_radius offset mismatch (expected 2048)");
    if (@offsetOf(ShadowParams, "texel_world_size") != 2176) @compileError("ShadowParams.texel_world_size offset mismatch (expected 2176)");
    if (@offsetOf(ShadowParams, "box_radius") != 2304) @compileError("ShadowParams.box_radius offset mismatch (expected 2304)");
    if (@offsetOf(ShadowParams, "normal_bias_scale") != 2432) @compileError("ShadowParams.normal_bias_scale offset mismatch (expected 2432)");
    if (@offsetOf(ShadowParams, "blur_radius") != 2436) @compileError("ShadowParams.blur_radius offset mismatch (expected 2436)");
    if (@offsetOf(ShadowParams, "blend_fraction") != 2440) @compileError("ShadowParams.blend_fraction offset mismatch (expected 2440)");
    if (@offsetOf(ShadowParams, "fade_start") != 2444) @compileError("ShadowParams.fade_start offset mismatch (expected 2444)");
    if (@offsetOf(ShadowParams, "fade_end") != 2448) @compileError("ShadowParams.fade_end offset mismatch (expected 2448)");
    if (@offsetOf(ShadowParams, "cascade_count") != 2452) @compileError("ShadowParams.cascade_count offset mismatch (expected 2452)");
    if (@offsetOf(ShadowParams, "shadow_strength") != 2456) @compileError("ShadowParams.shadow_strength offset mismatch (expected 2456)");
    if (@offsetOf(ShadowParams, "debug_colors") != 2460) @compileError("ShadowParams.debug_colors offset mismatch (expected 2460)");
    if (@sizeOf(ShadowParams) != 2464) @compileError("ShadowParams size mismatch (expected 2464)");
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
/// push-descriptor set layout, committed-matrix state, and the refresh scheduler cursor.
/// Shadows are rasterised at the end of the frame and sampled on the next one; each
/// frame up to `cascades_per_frame` cascades are refreshed (near ones most often, see
/// Csm.refreshIntervals/nextRefreshSet), keeping frame time flat.
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
/// Latched light direction (direction light travels) the shadow maps are rasterized with:
/// held frozen and stepped in `light_step_texels` increments so re-rasterizations land on
/// an identical texel grid (see `latchLight`).
light_dir: Csm.Vec3f = .{ 0.0, 0.0, -1.0 },
/// Per-cascade commit validity. The params cascade_count is the largest contiguous
/// valid prefix (0, 1, …, k-1), so a stale or never-committed cascade beyond the prefix
/// is never classified into — the shader's cascade_count early-outs before it.
valid: [Csm.MAX_CASCADES]bool = @splat(false),
/// Cascades computed this frame, used only by the end-of-frame raster. Promoted into
/// `committed` (the sampled state) at the start of the next prepareFrame, so a refreshed
/// layer is only ever sampled with the matrix and box radius it was rasterized with.
pending: [Csm.MAX_CASCADES]Csm.CommittedCascade = @splat(.{ .center_abs = .{ 0, 0, 0 }, .radius = 1.0, .near_plane = 0.0, .far_plane = 1.0, .light_dir = .{ 0.0, 0.0, -1.0 } }),
/// Per-cascade validity of `pending`; set when a cascade is computed this frame and
/// cleared once it is promoted (or discarded on a light-direction reset).
pending_valid: [Csm.MAX_CASCADES]bool = @splat(false),
/// Whether shadows were active last frame; a false->true transition means the sun just
/// rose and the committed state belongs to the pre-night light direction.
was_active: bool = false,
/// Smoothed camera movement in blocks per frame, measured from the view_pos delta.
/// Used for staleness padding so a stationary player keeps a tight, stable box (the max
/// fly speed would grow the box while standing still and cause texel-swimming flicker).
per_frame_dist: f32 = 0.0,
last_view_pos: @Vector(3, f64) = .{ 0, 0, 0 },
last_prepare_ns: i128 = 0,

/// Frame counter advanced each prepareFrame; drives the refresh scheduler.
frame_number: u32 = 0,
/// Frame each cascade was last refreshed; `Csm.never_refreshed` until first raster.
last_refresh: [Csm.MAX_CASCADES]u32 = @splat(Csm.never_refreshed),
/// Cascades to rasterize at the end of this frame, innermost first (from `nextRefreshSet`).
frame_cascades: [Csm.MAX_CASCADES]u32 = undefined,
/// Number of cascades to rasterize this frame (at most `cascades_per_frame`).
frame_cascade_count: u32 = 0,
/// Camera origin the frame's cascades were computed at (for the end-of-frame raster).
frame_origin: @Vector(3, f64) = .{ 0, 0, 0 },
/// Cull planes for the frame's cascades, one entry per cascade slot, camera-relative.
frame_planes: [gpu.shadow_slot_count][6]@Vector(4, f32) = undefined,
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
    for (self.param_buffers) |*buf| {
        buf.* = .{ .mapping = try memory.cpuToGpu().alignedAlloc(u8, .fromByteUnits(16), @sizeOf(ShadowParams)) };
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

    // When shadows are disabled the image is null, so the `same` check below is always
    // false and the teardown path would call deviceWaitIdle every frame. A torn-down
    // state is already current; just record the config and stop.
    if (!config.enabled and self.image == .null_handle) {
        self.config_applied = config;
        return;
    }

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
        self.pending_valid = @splat(false);
    }

    if (!applied.enabled or count == 0 or size == 0) return;

    errdefer self.destroyShadowImage();
    try self.createShadowImage(size, count);

    // Frame 0 samples "fully lit": clear every layer to far depth and leave the array
    // in SHADER_READ_ONLY_OPTIMAL so the first frame has no undefined-layout reads.
    try self.clearDepthArray(io);
    try self.createPipeline();
}

/// Picks a supported depth format and allocates the shadow depth array, per-cascade
/// views, and the 2D-array view. On error the caller's errdefer tears the image down.
fn createShadowImage(self: *ShadowRenderer, size: u32, count: u32) !void {
    // Pick a supported depth format among the request's candidates.
    const candidates: []const vk.Format = switch (self.config_applied.depth_format) {
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
    const alloc = try core.allocateImageWithMemory(self.dev, self.vk_ctx.mem_props, &self.vk_ctx.vkalloc, &image_info);
    self.image = alloc.image;
    self.image_memory = alloc.memory;

    self.views = try self.allocator.alloc(vk.ImageView, count);
    // Null-initialized so a partial failure leaves destroyShadowImage safe to run.
    for (self.views) |*view| view.* = .null_handle;
    for (self.views, 0..) |*view, i| view.* = try self.createImageView(.@"2d", @intCast(i), 1);
    self.array_view = try self.createImageView(.@"2d_array", 0, count);
}

/// Creates a depth image view over `layer_count` layers starting at `base_layer`.
fn createImageView(self: *ShadowRenderer, view_type: vk.ImageViewType, base_layer: u32, layer_count: u32) !vk.ImageView {
    return self.dev.createImageView(&.{
        .flags = .{},
        .image = self.image,
        .view_type = view_type,
        .format = self.format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .depth_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = base_layer,
            .layer_count = layer_count,
        },
    }, &self.vk_ctx.vkalloc);
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
    core.destroyImageWithMemory(self.dev, &self.image, &self.image_memory, &self.vk_ctx.vkalloc);
}

fn clearDepthArray(self: *ShadowRenderer, io: std.Io) !void {
    const cmd = try self.single_time.begin();

    // These barriers span the whole array; makeImageBarrier2 only covers a single layer.
    const full_range = vk.ImageSubresourceRange{
        .aspect_mask = .{ .depth_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = self.cascade_count,
    };

    const pre_barrier = core.imageBarrier2Range(self.image, full_range, .undefined, .transfer_dst_optimal, .{ .top_of_pipe_bit = true }, .{}, .{ .all_transfer_bit = true }, .{ .transfer_write_bit = true });
    core.pipelineBarrier(cmd, self.dev, vk.ImageMemoryBarrier2, (&pre_barrier)[0..1]);

    self.dev.cmdClearDepthStencilImage(cmd, self.image, .transfer_dst_optimal, &.{ .depth = 1.0, .stencil = 0 }, (&full_range)[0..1]);

    // transfer dst -> shader read (fragment sampling)
    const post_barrier = core.imageBarrier2Range(self.image, full_range, .transfer_dst_optimal, .shader_read_only_optimal, .{ .all_transfer_bit = true }, .{ .transfer_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true });
    core.pipelineBarrier(cmd, self.dev, vk.ImageMemoryBarrier2, (&post_barrier)[0..1]);

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
    sun_dir: Csm.Vec3f,
    scene_min: [3]f64,
    scene_max: [3]f64,
) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "shadow_prepareFrame" });
    defer zone.end();

    self.measureMovement(io, view_pos);

    // The caller (VulkanRenderer.draw) holds the options lock; read the live config so
    // non-resource changes (blend, fade, strength, refresh intervals, splits) apply immediately.
    const config = self.render_options.shadow;
    const count = @min(config.cascade_count, Csm.MAX_CASCADES);
    self.frame_cascade_count = 0;

    const light_dir_changed = self.latchLight(config, sun_dir);
    const active = config.enabled and self.image != .null_handle and Csm.sunDayFromSunDir(sun_dir) > 0.0 and count > 0;

    // When the light direction changes meaningfully (sunrise, or a re-latched basis),
    // every committed cascade still holds a matrix and depth content built for the old
    // sun. Reset the ramp so uncommitted cascades sample as fully lit rather than
    // projecting shadows from the previous light direction.
    if ((active and !self.was_active) or light_dir_changed) {
        self.valid = @splat(false);
        self.pending_valid = @splat(false);
    }
    self.was_active = active;

    if (active) {
        self.promotePending();
        self.refreshCascades(count, config, view_pos, scene_min, scene_max);
    }

    self.writeParams(active, count, config, view_pos, frame_idx);
    self.frame_number +%= 1;
}

/// Measures smoothed camera movement in blocks per frame for staleness padding. Must
/// stay per-frame (not per-second): the max fly speed would grow the boxes while
/// standing still and cause texel-swimming flicker.
fn measureMovement(self: *ShadowRenderer, io: std.Io, view_pos: @Vector(3, f64)) void {
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    if (self.last_prepare_ns != 0) {
        const delta = view_pos - self.last_view_pos;
        const dist: f32 = @floatCast(@sqrt(delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2]));
        self.per_frame_dist = std.math.lerp(self.per_frame_dist, dist, movement_smoothing);
    }
    self.last_prepare_ns = now_ns;
    self.last_view_pos = view_pos;
}

/// Re-latches the light direction from the live sun. The sun drifts continuously, but
/// re-deriving the basis (and re-snapping the texel grid) every frame makes the near
/// cascade re-commit a rotating grid → shadow swimming. So the latched basis is held
/// frozen and only re-oriented after `light_step_texels` near-texels of sun travel, so
/// re-rasterizations land on an identical texel grid and the shadows stay stable between
/// the minimal 1-texel re-orientations. A re-orientation large enough to move to a new sun
/// (sunrise, azimuth flip) also invalidates the cached draw for a full re-ramp; a small
/// one keeps the committed prefix valid so cascades refresh onto the new axis at their own
/// cadence without turning shadows off for a frame.
fn latchLight(self: *ShadowRenderer, config: Csm.ShadowConfig, sun_dir: Csm.Vec3f) bool {
    const clamped = Csm.clampSunElevation(sun_dir, config.min_sun_elevation_deg);
    const new_light_dir = Csm.lightDirFromSunDir(clamped);
    const old_light_dir = self.light_dir;
    // Scale the re-orientation threshold to the near cascade's texel (texel =
    // 2*radius/map_size and texel/radius = 2/map_size), so it is resolution-independent:
    // the axis re-orients after `light_step_texels` near-texels of sun travel. Before the
    // shadow image exists (map_size 0) fall back to the coarse basis change so the axis
    // still tracks a sunrise.
    const step_cos = if (self.map_size > 0)
        @cos(light_step_texels * (2.0 / @as(f32, @floatFromInt(self.map_size))))
    else
        light_change_cos_threshold;
    if (Csm.shouldStepLight(old_light_dir, new_light_dir, step_cos)) {
        self.light_dir = new_light_dir;
    }
    return Csm.dot3f(old_light_dir, new_light_dir) < light_change_cos_threshold;
}

/// Promotes last frame's rasterized cascades into the sampled state, so a layer is only
/// ever sampled with the matrix and box it was rasterized with; fresh cascades stay in
/// pending (raster-only) until promoted here.
fn promotePending(self: *ShadowRenderer) void {
    for (&self.committed, &self.valid, &self.pending, &self.pending_valid) |*committed, *valid, *pending, *pending_valid| {
        if (pending_valid.*) {
            committed.* = pending.*;
            valid.* = true;
        }
    }
    self.pending_valid = @splat(false);
}

/// Selects the cascades to refresh this frame — derived per-cascade intervals (near
/// cascades much more often) capped by the per-frame budget — and computes each into
/// pending; also derives the frame's cull planes and minimum chunk size.
fn refreshCascades(
    self: *ShadowRenderer,
    count: u32,
    config: Csm.ShadowConfig,
    view_pos: @Vector(3, f64),
    scene_min: [3]f64,
    scene_max: [3]f64,
) void {
    self.frame_origin = view_pos;
    // At most shadow_slot_count cascades can be drawn per frame (one slot each). If the
    // configured per-frame budget exceeds it, clamp so the buffers never overflow; the
    // scheduler still picks the most-overdue cascades first.
    const budget = @min(config.cascades_per_frame, gpu.shadow_slot_count);
    const refresh_set = Csm.nextRefreshSet(count, budget, Csm.refreshIntervals(config), self.last_refresh, self.frame_number);

    // Each selected cascade culls and draws its own box into its own slot: per-cascade
    // planes from that cascade's center, radius, and depth range, and the innermost
    // selected texel drives the minimum chunk size for all of them.
    var finest_texel: f32 = std.math.inf(f32);
    for (0..count) |c| {
        if (!refresh_set[c]) continue;
        const slot = self.frame_cascade_count;
        const ctx = Csm.CascadeContext{
            .cfg = config,
            .view_pos = view_pos,
            .light_dir = self.light_dir,
            .scene_min = .{ scene_min[0], scene_min[1], scene_min[2] },
            .scene_max = .{ scene_max[0], scene_max[1], scene_max[2] },
            .per_frame_dist = self.per_frame_dist,
        };
        const cascade = Csm.computeCascade(ctx, @intCast(c));
        self.pending[c] = Csm.committedOf(cascade);
        self.pending_valid[c] = true;
        self.last_refresh[c] = self.frame_number;
        self.frame_cascades[slot] = @intCast(c);
        self.frame_planes[slot] = cullPlanes(cascade.center_abs, cascade.light_dir, cascade.radius, cascade.near_plane, cascade.far_plane, view_pos);
        self.frame_cascade_count += 1;
        if (cascade.texel < finest_texel) finest_texel = cascade.texel;
    }
    if (std.math.isFinite(finest_texel)) self.frame_min_chunk_size = config.min_chunk_texels * finest_texel;
}

/// Writes params every frame (origin compensation changes every frame) for all committed
/// cascades. cascade_count gates classification to the committed prefix, so an
/// uncommitted cascade is never classified into; it reads the cleared map -> lit.
fn writeParams(
    self: *ShadowRenderer,
    active: bool,
    count: u32,
    config: Csm.ShadowConfig,
    view_pos: @Vector(3, f64),
    frame_idx: u32,
) void {
    var params = ShadowParams.default();
    // Largest contiguous valid prefix: cascades 0..active_count-1 are all committed.
    var active_count: u32 = 0;
    while (active_count < count and self.valid[active_count]) active_count += 1;
    if (active and active_count > 0) {
        params.cascade_count = active_count;
        const splits = Csm.splitRadii(config);
        for (0..active_count) |c| {
            const committed = self.committed[c];
            const view_proj = Csm.viewProjAtOrigin(committed, view_pos);
            @memcpy(params.light_viewproj[c][0..], view_proj[0..]);
            params.split_radius[c] = splits[c];
            params.texel_world_size[c] = 2.0 * committed.radius / @as(f32, @floatFromInt(self.map_size));
            params.box_radius[c] = committed.radius;
        }
        params.normal_bias_scale = config.normal_bias_scale;
        params.blur_radius = config.blur_radius;
        params.blend_fraction = config.cascade_blend;
        params.fade_start = config.max_shadow_distance * config.last_cascade_fade;
        params.fade_end = config.max_shadow_distance;
        params.shadow_strength = config.shadow_strength;
        params.debug_colors = @intFromBool(config.debug_cascade_colors);
    }
    @memcpy(self.param_buffers[frame_idx].mapping[0..@sizeOf(ShadowParams)], std.mem.asBytes(&params));
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
    return self.frame_cascade_count > 0;
}

/// Number of cascades being refreshed this frame (the shadow cull dispatches this many
/// times, once per slot).
pub fn frameCascadeCount(self: *const ShadowRenderer) u32 {
    return self.frame_cascade_count;
}

/// The innermost (nearest) cascade being refreshed this frame, for stats and debug.
pub fn frameInnermostCascade(self: *const ShadowRenderer) ?u32 {
    if (self.frame_cascade_count == 0) return null;
    return self.frame_cascades[0];
}

pub fn frameCascadePlanes(self: *const ShadowRenderer, slot: u32) [6]@Vector(4, f32) {
    return self.frame_planes[slot];
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
        .image_view = self.array_view,
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
    if (face_buffer == .null_handle or self.image == .null_handle) return;

    for (self.frame_cascades[0..self.frame_cascade_count], 0..) |cascade, slot| {
        if (self.views.len <= cascade) continue;
        self.recordCascadePass(cmd_buffer, frame_idx, cascade, @intCast(slot), face_buffer, face_buffer_offset);
    }
}

/// Records the depth raster for a single cascade layer: layout transitions, clear, and
/// the indirect draw of the frame's culled geometry through the cascade's light matrix.
fn recordCascadePass(
    self: *ShadowRenderer,
    cmd_buffer: vk.CommandBuffer,
    frame_idx: u32,
    cascade: u32,
    slot: u32,
    face_buffer: vk.Buffer,
    face_buffer_offset: vk.DeviceSize,
) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordCascadePass" });
    defer zone.end();

    const extent: vk.Extent2D = .{ .width = self.map_size, .height = self.map_size };
    const layer_range = vk.ImageSubresourceRange{
        .aspect_mask = .{ .depth_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = cascade,
        .layer_count = 1,
    };

    // Within-command-buffer dependency: this frame's fragment reads (opaque/transparent
    // sample the shadow array) precede the write to this cascade's layer. makeImageBarrier2
    // only covers layer 0, so the range is built by hand for the cascade layer.
    const pre_barrier = core.imageBarrier2Range(self.image, layer_range, .shader_read_only_optimal, .depth_stencil_attachment_optimal, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true }, .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true }, .{ .depth_stencil_attachment_write_bit = true });
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

    // The matrix must match the params used when sampling next frame: rebuilt from the
    // pending cascade at the origin the raster uses (the same origin the cascade was
    // computed at), so light-space coordinates are world-anchored. The pending slot is
    // promoted into committed (the sampled state) at the start of the next prepareFrame.
    const pending_commit = self.pending[cascade];
    const shadow_pc = ShadowPushConstants{
        .light_viewproj = Csm.viewProjAtOrigin(pending_commit, self.frame_origin),
        .mesh_base = (gpu.shadow_slot_base + slot) * self.scene.draw_capacity,
    };
    self.dev.cmdPushConstants(cmd_buffer, self.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(ShadowPushConstants), &shadow_pc);

    self.dev.cmdBindVertexBuffers(cmd_buffer, 0, (&face_buffer)[0..1], (&face_buffer_offset)[0..1]);

    const frame = &self.scene.frame_buffers.items[frame_idx];
    const indirect_offset = frame.indirect_draw_offset + @as(vk.DeviceSize, @intCast((gpu.shadow_slot_base + slot) * self.scene.draw_capacity * @sizeOf(vk.DrawIndirectCommand)));
    const count_offset = frame.count_offset + @as(vk.DeviceSize, @intCast(@offsetOf(gpu.CullCount, "shadow_count") + slot * @sizeOf(u32)));
    self.dev.cmdDrawIndirectCount(cmd_buffer, frame.indirect_draw, indirect_offset, frame.count, count_offset, self.scene.draw_capacity, @sizeOf(vk.DrawIndirectCommand));

    self.dev.cmdEndRendering(cmd_buffer);

    // Trailing transition back to sampled layout; visible to the next frame's fragment
    // reads without any top-of-frame barrier.
    const post_barrier = core.imageBarrier2Range(self.image, layer_range, .depth_stencil_attachment_optimal, .shader_read_only_optimal, .{ .late_fragment_tests_bit = true }, .{ .depth_stencil_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true });
    core.pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, (&post_barrier)[0..1]);
}

test "ShadowParams layout" {
    try std.testing.expectEqual(@as(usize, 2464), @sizeOf(ShadowParams));
}
