const std = @import("std");

const tracy = @import("tracy");
const vk = @import("vulkan");
const DeviceProxy = vk.DeviceProxy;

const VulkanContext = @import("../../../VulkanContext.zig").VulkanContext;
const World = @import("../../../world/World.zig");
const core = @import("../core.zig");
const gpu = @import("../gpu.zig");
const Csm = @import("Csm.zig");

const shadow_vert_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("shadow_vert_spv")));

/// Lerp factor for the smoothed per-frame movement estimate (measureMovement).
const movement_smoothing: f32 = 0.3;
/// Cosine threshold below which the light direction is treated as a new basis (~25°).
const light_change_cos_threshold: f32 = 0.9;
/// Near-cascade texels the light axis advances per re-orientation; 1 texel is the smallest step the map can make.
const light_step_texels: f32 = 1.0;

/// std430 storage-block layout mirrored by shadow.glsl. Per-cascade members are fixed
/// max_cascades arrays (matching the GLSL `float [max_cascades]` members) so the layout
/// stays stable across a runtime cascade_count change; cascade-uniform values are scalars.
pub const ShadowParams = extern struct {
    light_viewproj: [Csm.max_cascades][16]f32 = @splat(@splat(0.0)),
    split_radius: [Csm.max_cascades]f32 align(16) = @splat(0.0),
    texel_world_size: [Csm.max_cascades]f32 align(16) = @splat(0.0),
    box_radius: [Csm.max_cascades]f32 align(16) = @splat(0.0),
    normal_bias_scale: f32 = 0.0,
    blur_radius: f32 = 0.0,
    blend_fraction: f32 = 0.0,
    fade_start: f32 = 0.0,
    fade_end: f32 = 0.0,
    cascade_count: u32 = 0,
    shadow_strength: f32 = 0.0,
    debug_colors: u32 = 0,
};

comptime {
    const offsets = .{
        .{ "split_radius", 2048 },      .{ "texel_world_size", 2176 }, .{ "box_radius", 2304 },
        .{ "normal_bias_scale", 2432 }, .{ "blur_radius", 2436 },      .{ "blend_fraction", 2440 },
        .{ "fade_start", 2444 },        .{ "fade_end", 2448 },         .{ "cascade_count", 2452 },
        .{ "shadow_strength", 2456 },   .{ "debug_colors", 2460 },
    };
    for (offsets) |entry| {
        if (@offsetOf(ShadowParams, entry[0]) != entry[1]) @compileError("ShadowParams." ++ entry[0] ++ " offset mismatch with shadow.glsl");
    }
    if (@sizeOf(ShadowParams) != 2464) @compileError("ShadowParams size mismatch (expected 2464)");
}

const ShadowPushConstants = extern struct {
    light_viewproj: [16]f32,
    mesh_base: u32,
};

comptime {
    if (@sizeOf(ShadowPushConstants) != 68) @compileError("ShadowPushConstants size mismatch with GLSL layout (expected 68)");
    if (@offsetOf(ShadowPushConstants, "mesh_base") != 64) @compileError("ShadowPushConstants.mesh_base offset mismatch with GLSL layout (expected 64)");
}

/// Owns the shadow depth texture array (1 layer per cascade), the depth-only pipeline,
/// the per-frame ShadowParams storage buffer, the comparison sampler, the shared
/// push-descriptor set layout, committed-matrix state, and the refresh scheduler cursor.
/// Shadows are rasterised at the end of the frame and sampled on the next one; each
/// frame up to `cascades_per_frame` cascades are refreshed (near ones most often, see
/// Csm.refreshIntervals/nextRefreshSet), keeping frame time flat.
pub const ShadowRenderer = @This();

vk_ctx: *VulkanContext,
dev: DeviceProxy,
memory: *gpu.GpuMemory,
single_time: *core.SingleTime,
scene: *gpu.IndirectScene,

image: vk.Image = .null_handle,
image_memory: vk.DeviceMemory = .null_handle,
/// Per-cascade layer views; the first `cascade_count` are live.
views: [Csm.max_cascades]vk.ImageView = @splat(.null_handle),
/// 2D-array view of every layer; the fragment shaders sample this as sampler2DArrayShadow.
array_view: vk.ImageView = .null_handle,
format: vk.Format = .undefined,
map_size: u32 = 0,
cascade_count: u32 = 0,

shadow_set_layout: vk.DescriptorSetLayout = .null_handle,
pipeline: vk.Pipeline = .null_handle,
pipeline_layout: vk.PipelineLayout = .null_handle,
compare_sampler: vk.Sampler = .null_handle,
param_buffers: [VulkanContext.max_frames_in_flight][]align(16) u8 = @splat(&.{}),

/// Committed (sampled) per-cascade data (snapped center, box, light basis) rebuilt into
/// a per-frame matrix by `viewProjAtOrigin`; null until committed. The params
/// cascade_count is the largest contiguous non-null prefix, so a stale cascade beyond
/// it never classifies; the shader early-outs before it.
committed: [Csm.max_cascades]?Csm.CommittedCascade = @splat(null),
/// Latched light direction the shadow maps use, stepped in `light_step_texels` increments (see `latchLight`).
light_dir: Csm.Vec3f = .{ 0.0, 0.0, -1.0 },
/// Cascades computed this frame, used only by the end-of-frame raster. Promoted into
/// `committed` at the start of the next prepareFrame, so a refreshed layer is only ever
/// sampled with the matrix and box radius it was rasterized with.
pending: [Csm.max_cascades]?Csm.CommittedCascade = @splat(null),
/// Whether shadows were active last frame; a false->true transition means the sun just
/// rose and the committed state belongs to the pre-night light direction.
was_active: bool = false,
/// Smoothed camera movement in blocks per frame; pads staleness so a still player keeps a tight box.
per_frame_dist: f32 = 0.0,
last_view_pos: ?Csm.Vec3d = null,

/// Frame counter advanced each prepareFrame; drives the refresh scheduler.
frame_number: u32 = 0,
/// Frame each cascade was last refreshed; `Csm.never_refreshed` until first raster.
last_refresh: [Csm.max_cascades]u32 = @splat(Csm.never_refreshed),
/// Cascades to rasterize at the end of this frame in ascending index order, so the
/// nearest refreshed cascade comes first.
frame_cascades: [gpu.shadow_slot_count]u32 = @splat(0),
frame_cascade_count: u32 = 0,
frame_origin: Csm.Vec3d = .{ 0, 0, 0 },
frame_min_chunk_size: f32 = 0.0,

config_applied: Csm.ShadowConfig = .{},

pub fn init(
    vk_ctx: *VulkanContext,
    memory: *gpu.GpuMemory,
    single_time: *core.SingleTime,
    scene: *gpu.IndirectScene,
) !ShadowRenderer {
    var self: ShadowRenderer = .{
        .vk_ctx = vk_ctx,
        .dev = vk_ctx.dev,
        .memory = memory,
        .single_time = single_time,
        .scene = scene,
    };
    errdefer self.deinit();

    try self.createSharedSetLayout();
    try self.createSampler();
    try self.createPipelineLayout();

    for (&self.param_buffers) |*buf| {
        buf.* = try memory.cpuToGpu().alignedAlloc(u8, .fromByteUnits(16), @sizeOf(ShadowParams));
    }

    return self;
}

pub fn deinit(self: *ShadowRenderer) void {
    for (self.param_buffers) |buf| {
        if (buf.len > 0) self.memory.cpuToGpu().free(buf);
    }

    core.destroyIfValid(self.dev, &self.compare_sampler, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.pipeline, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.pipeline_layout, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.shadow_set_layout, &self.vk_ctx.vkalloc);
    self.destroyShadowImage();
}

fn createSharedSetLayout(self: *ShadowRenderer) !void {
    const bindings: [3]vk.DescriptorSetLayoutBinding = .{
        .{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment = true }, .p_immutable_samplers = null },
        .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment = true }, .p_immutable_samplers = null },
        .{ .binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .fragment = true }, .p_immutable_samplers = null },
    };
    self.shadow_set_layout = try core.createDescriptorSetLayout(self.dev, &self.vk_ctx.vkalloc, .{ .push_descriptor = true }, &bindings);
}

fn createSampler(self: *ShadowRenderer) !void {
    self.compare_sampler = try core.createSampler(self.vk_ctx, .{
        .mipmap_mode = .nearest,
        .address_mode = .clamp_to_border,
        .compare_enable = true,
        .compare_op = .less_or_equal,
        .border_color = .float_opaque_white,
    });
}

fn createPipelineLayout(self: *ShadowRenderer) !void {
    const pc_range: vk.PushConstantRange = .{
        .stage_flags = .{ .vertex = true },
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
    const vert_module = try core.createShaderModule(self.vk_ctx, shadow_vert_spv);
    defer self.dev.destroyShaderModule(vert_module, &self.vk_ctx.vkalloc);

    core.destroyIfValid(self.dev, &self.pipeline, &self.vk_ctx.vkalloc);
    // Depth-only; recording sets standard (not reversed-Z) less-or-equal depth.
    self.pipeline = try core.buildGraphicsPipeline(self.vk_ctx, .{
        .vert_module = vert_module,
        .depth_format = self.format,
        .depth_test = true,
        .layout = self.pipeline_layout,
        .vertex_input = gpu.MeshUploader.faceVertexInputState(),
        .topology = .triangle_strip,
        .depth_bias = .{
            .constant = self.config_applied.depth_bias_constant,
            .slope = self.config_applied.depth_bias_slope,
            .clamp = if (self.vk_ctx.depth_bias_clamp) self.config_applied.depth_bias_clamp else 0.0,
        },
        .depth_clamp = self.vk_ctx.depth_clamp,
    });
}

/// Allocates (or recreates) the shadow depth array and per-cascade views. Called from
/// init and on config change (never mid-frame: it device-waits); only resource-affecting
/// fields (image shape/format and pipeline-static states) force a recreate.
pub fn recreate(self: *ShadowRenderer, io: std.Io, config: Csm.ShadowConfig) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "shadow_recreate" });
    defer zone.end();
    const count = @min(config.cascade_count, Csm.max_cascades);
    const size = config.shadow_map_size;

    // A config that builds no image leaves it null, so the `same` check below is always
    // false and the teardown path would wait for the device every frame. A torn-down
    // state is already current; just record the config and stop.
    if (self.image == .null_handle and (!config.enabled or count == 0 or size == 0)) {
        self.config_applied = config;
        return;
    }

    // Compare the requested format, not `self.format`: pickDepthFormat may fall back.
    const same = self.image != .null_handle and
        self.cascade_count == count and
        self.map_size == size and
        self.config_applied.depth_format == config.depth_format and
        self.config_applied.depth_bias_constant == config.depth_bias_constant and
        self.config_applied.depth_bias_slope == config.depth_bias_slope and
        self.config_applied.depth_bias_clamp == config.depth_bias_clamp and
        self.config_applied.enabled == config.enabled;
    if (same) return;

    var applied = config;

    if (applied.cascade_count > Csm.max_cascades) {
        std.log.warn("ShadowRenderer: cascade_count {d} exceeds MAX_CASCADES {d}; clamping", .{ applied.cascade_count, Csm.max_cascades });
        applied.cascade_count = Csm.max_cascades;
    }

    try self.teardownResources(applied, count, size);
    if (!applied.enabled or count == 0 or size == 0) return;
    try self.buildResources(io, size, count);
}

/// Tears down the current shadow image and pipeline once no submitted frame uses
/// them, and records the freshly-applied resource state.
fn teardownResources(self: *ShadowRenderer, applied: Csm.ShadowConfig, count: u32, size: u32) !void {
    try self.vk_ctx.waitSubmittedFrames();
    self.destroyShadowImage();
    core.destroyIfValid(self.dev, &self.pipeline, &self.vk_ctx.vkalloc);
    self.config_applied = applied;
    self.cascade_count = count;
    self.map_size = size;
    self.committed = @splat(null);
    self.pending = @splat(null);
    self.last_refresh = @splat(Csm.never_refreshed);
}

/// Allocates the shadow image and views, clears every layer to far depth, and rebuilds
/// the pipeline for the new image/pipeline-static state. On failure the image is torn
/// down so the renderer is left in a consistent torn-down state.
fn buildResources(self: *ShadowRenderer, io: std.Io, size: u32, count: u32) !void {
    errdefer self.destroyShadowImage();
    try self.createShadowImage(size, count);
    // Frame 0 samples "fully lit": clear every layer to far depth and leave the array
    // in SHADER_READ_ONLY_OPTIMAL so the first frame has no undefined-layout reads.
    try self.clearDepthArray(io);
    try self.createPipeline();
}

/// Allocates the shadow depth array, per-cascade views, and the 2D-array view. On error
/// the caller's errdefer tears the image down.
fn createShadowImage(self: *ShadowRenderer, size: u32, count: u32) !void {
    self.format = try self.pickDepthFormat();

    const image_info: vk.ImageCreateInfo = .{
        .image_type = .@"2d",
        .extent = .{ .width = size, .height = size, .depth = 1 },
        .mip_levels = 1,
        .array_layers = count,
        .format = self.format,
        .tiling = .optimal,
        .initial_layout = .undefined,
        .usage = .{ .depth_stencil_attachment = true, .sampled = true, .transfer_dst = true },
        .sharing_mode = .exclusive,
        .samples = .{ .@"1" = true },
    };
    self.image, self.image_memory = try core.allocateImageWithMemory(self.vk_ctx, &image_info);

    try self.createImageViews(count);
}

/// Picks a supported depth format among the config's candidates.
fn pickDepthFormat(self: *ShadowRenderer) !vk.Format {
    const candidates: []const vk.Format = switch (self.config_applied.depth_format) {
        .d16 => &.{ .d16_unorm, .d32_sfloat },
        .d32 => &.{ .d32_sfloat, .d16_unorm },
    };
    for (candidates) |fmt| {
        const features = self.vk_ctx.instance.getPhysicalDeviceFormatProperties(self.vk_ctx.pdev, fmt).optimal_tiling_features;
        if (features.depth_stencil_attachment and features.sampled_image) return fmt;
    }
    return error.ShadowDepthFormatNotSupported;
}

/// Creates the per-cascade layer views and the 2D-array view. Unused views stay null,
/// so a partial failure leaves destroyShadowImage safe to run.
fn createImageViews(self: *ShadowRenderer, count: u32) !void {
    for (self.views[0..count], 0..) |*view, i| view.* = try self.createImageView(.@"2d", @intCast(i), 1);
    self.array_view = try self.createImageView(.@"2d_array", 0, count);
}

/// Creates a depth image view over `layer_count` layers starting at `base_layer`.
fn createImageView(self: *ShadowRenderer, view_type: vk.ImageViewType, base_layer: u32, layer_count: u32) !vk.ImageView {
    var info = core.imageViewCreateInfo(self.image, self.format, .{ .depth = true });
    info.view_type = view_type;
    info.subresource_range = depthRange(base_layer, layer_count);
    return self.dev.createImageView(&info, &self.vk_ctx.vkalloc);
}

fn destroyShadowImage(self: *ShadowRenderer) void {
    for (&self.views) |*view| core.destroyIfValid(self.dev, view, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.array_view, &self.vk_ctx.vkalloc);
    core.destroyImageWithMemory(self.vk_ctx, &self.image, &self.image_memory);
}

fn clearDepthArray(self: *ShadowRenderer, io: std.Io) !void {
    const cmd = try self.single_time.begin();

    const full_range = depthRange(0, self.cascade_count);

    const pre_barrier = core.imageBarrier2Range(self.image, full_range, .undefined, .transfer_dst_optimal, .{ .top_of_pipe = true }, .{}, .{ .all_transfer = true }, .{ .transfer_write = true });
    core.pipelineBarrier(cmd, self.dev, vk.ImageMemoryBarrier2, (&pre_barrier)[0..1]);

    self.dev.cmdClearDepthStencilImage(cmd, self.image, .transfer_dst_optimal, &.{ .depth = 1.0, .stencil = 0 }, (&full_range)[0..1]);

    // transfer dst -> shader read (fragment sampling)
    const post_barrier = core.imageBarrier2Range(self.image, full_range, .transfer_dst_optimal, .shader_read_only_optimal, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .fragment_shader = true }, .{ .shader_read = true });
    core.pipelineBarrier(cmd, self.dev, vk.ImageMemoryBarrier2, (&post_barrier)[0..1]);

    self.single_time.end(io, cmd) catch |err| {
        std.log.err("ShadowRenderer: failed to clear depth array: {any}", .{err});
        return err;
    };
}

/// Depth-aspect subresource range over `layer_count` layers starting at `base_layer`.
fn depthRange(base_layer: u32, layer_count: u32) vk.ImageSubresourceRange {
    return .{
        .aspect_mask = .{ .depth = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = base_layer,
        .layer_count = layer_count,
    };
}

/// Computes the frame's refreshed cascades into pending, and writes the per-frame params.
/// Called every frame before the command buffer begins with the config snapshot `recreate`
/// got; `sun_dir` is the live sky direction, latched here so refreshed cascades share a
/// light basis.
pub fn prepareFrame(
    self: *ShadowRenderer,
    frame_idx: u32,
    config: Csm.ShadowConfig,
    view_pos: Csm.Vec3d,
    sun_dir: Csm.Vec3f,
    scene_min: Csm.Vec3d,
    scene_max: Csm.Vec3d,
) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "shadow_prepareFrame" });
    defer zone.end();

    self.measureMovement(view_pos);

    // A failed recreate can leave the image with fewer layers than the config asks for.
    const count = @min(config.cascade_count, self.cascade_count);
    self.frame_cascade_count = 0;

    const light_dir_changed = self.latchLight(config, sun_dir);
    const active = config.enabled and self.image != .null_handle and Csm.sunDayFromSunDir(sun_dir) > 0.0 and count > 0;

    // When the light direction changes meaningfully (sunrise, or a re-latched basis),
    // every committed cascade still holds a matrix and depth content built for the old
    // sun. Reset the ramp so uncommitted cascades sample as fully lit rather than
    // projecting shadows from the previous light direction.
    if ((active and !self.was_active) or light_dir_changed) {
        self.committed = @splat(null);
        self.pending = @splat(null);
        // Stale stamps would otherwise gate every cascade behind its long interval.
        self.last_refresh = @splat(Csm.never_refreshed);
    }
    self.was_active = active;

    if (active) {
        self.promotePending();
        self.refreshCascades(count, .{
            .cfg = config,
            .view_pos = view_pos,
            .light_dir = self.light_dir,
            .scene_min = scene_min,
            .scene_max = scene_max,
            .per_frame_dist = self.per_frame_dist,
            .split_radii = Csm.splitRadii(config),
            .refresh_intervals = Csm.refreshIntervals(config),
        });
    }

    self.writeParams(.{
        .active = active,
        .count = count,
        .config = config,
        .view_pos = view_pos,
        .frame_idx = frame_idx,
    });
    self.frame_number +%= 1;
}

/// Measures smoothed camera movement in blocks per frame for staleness padding. Must
/// stay per-frame (not per-second): the max fly speed would grow the boxes while
/// standing still and cause texel-swimming flicker.
fn measureMovement(self: *ShadowRenderer, view_pos: Csm.Vec3d) void {
    if (self.last_view_pos) |last_view_pos| {
        const delta = view_pos - last_view_pos;
        const dist: f32 = @floatCast(@sqrt(@reduce(.Add, delta * delta)));
        self.per_frame_dist = std.math.lerp(self.per_frame_dist, dist, movement_smoothing);
    }
    self.last_view_pos = view_pos;
}

/// Re-latches the light direction from the live sun: the basis is held frozen and stepped
/// in `light_step_texels` near-texel increments so re-rasterizations land on an identical
/// texel grid (re-deriving every frame would re-commit a rotating grid → shadow swimming).
/// Returns whether the change is large enough (sunrise, azimuth flip) to require a full
/// re-ramp; a small step keeps the committed prefix valid so cascades refresh onto the
/// new axis at their own cadence.
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
    if (Csm.shouldStepLight(old_light_dir, new_light_dir, step_cos)) self.light_dir = new_light_dir;
    return Csm.dot3f(old_light_dir, new_light_dir) < light_change_cos_threshold;
}

/// Promotes last frame's rasterized cascades into the sampled state, so a layer is only
/// ever sampled with the matrix and box it was rasterized with; fresh cascades stay in
/// pending (raster-only) until promoted here.
fn promotePending(self: *ShadowRenderer) void {
    for (&self.committed, self.pending) |*committed, pending| {
        if (pending) |cascade| committed.* = cascade;
    }
    self.pending = @splat(null);
}

/// Minimum chunk world size that may cast a shadow: the larger of the texel-based
/// floor and the size of a chunk at `lowest_shadow_level`, so chunks below that
/// level are culled from the shadow pass. Chunk world size is exactly
/// `levelToBlockRatioFloat(level)`, which the cull shader recomputes as
/// `scale * chunk_size`, so equal levels compare equal and pass the `<` filter.
fn effectiveMinChunkSize(texel_based: f32, lowest_shadow_level: i32) f32 {
    return @max(texel_based, World.ChunkPos.levelToBlockRatioFloat(lowest_shadow_level));
}

/// Selects the cascades to refresh this frame — derived per-cascade intervals (near
/// cascades much more often) capped by the per-frame budget — and computes each into
/// pending, deriving the frame's cull planes and minimum chunk size along the way.
fn refreshCascades(self: *ShadowRenderer, count: u32, ctx: Csm.CascadeContext) void {
    self.frame_origin = ctx.view_pos;
    // At most shadow_slot_count cascades can be drawn per frame (one slot each). If the
    // configured per-frame budget exceeds it, clamp so the buffers never overflow; the
    // scheduler picks the most-overdue cascades.
    const budget = @min(ctx.cfg.cascades_per_frame, gpu.shadow_slot_count);
    const refresh_set = Csm.nextRefreshSet(count, budget, ctx.refresh_intervals, self.last_refresh, self.frame_number);

    // The innermost selected texel drives the minimum chunk size for all cascades.
    var finest_texel: f32 = std.math.inf(f32);
    for (refresh_set[0..count], 0..) |refresh, c| {
        if (!refresh) continue;
        const texel = self.refreshCascade(ctx, c);
        if (texel < finest_texel) finest_texel = texel;
    }
    if (std.math.isFinite(finest_texel)) self.frame_min_chunk_size = effectiveMinChunkSize(ctx.cfg.min_chunk_texels * finest_texel, ctx.cfg.lowest_shadow_level);
}

/// Computes one refreshed cascade into its pending slot and returns its texel size for
/// the minimum chunk size. Each cascade culls and draws its own box into its own slot.
fn refreshCascade(self: *ShadowRenderer, ctx: Csm.CascadeContext, cascade_index: usize) f32 {
    const cascade = Csm.computeCascade(ctx, @intCast(cascade_index));
    self.pending[cascade_index] = Csm.committedOf(cascade);
    self.last_refresh[cascade_index] = self.frame_number;
    self.frame_cascades[self.frame_cascade_count] = @intCast(cascade_index);
    self.frame_cascade_count += 1;
    return cascade.texel;
}

/// Per-frame inputs for the params write (origin compensation changes every frame).
const ParamsContext = struct {
    active: bool,
    count: u32,
    config: Csm.ShadowConfig,
    view_pos: Csm.Vec3d,
    frame_idx: u32,
};

/// Writes params for all committed cascades. cascade_count gates classification to the
/// committed prefix, so an uncommitted cascade is never classified into; it reads the
/// cleared map -> lit.
fn writeParams(self: *ShadowRenderer, ctx: ParamsContext) void {
    var params: ShadowParams = .{};
    // Largest contiguous non-null prefix: cascades 0..active_count-1 are all committed.
    var active_count: u32 = 0;
    while (active_count < ctx.count and self.committed[active_count] != null) active_count += 1;
    if (ctx.active and active_count > 0) {
        params.cascade_count = active_count;
        for (self.committed[0..active_count], 0..) |maybe_committed, cascade| {
            const committed = maybe_committed.?;
            const view_proj = Csm.viewProjAtOrigin(committed, ctx.view_pos);
            @memcpy(params.light_viewproj[cascade][0..], view_proj[0..]);
            params.split_radius[cascade] = committed.split_radius;
            params.texel_world_size[cascade] = 2.0 * committed.radius / @as(f32, @floatFromInt(self.map_size));
            params.box_radius[cascade] = committed.radius;
        }
        params.normal_bias_scale = ctx.config.normal_bias_scale;
        params.blur_radius = ctx.config.blur_radius;
        params.blend_fraction = ctx.config.cascade_blend;
        // Fade is snapshotted from the outer committed cascade's split, not the live
        // max_shadow_distance, so it cannot outrun the box that cascade was fitted for.
        const fade_end = self.committed[active_count - 1].?.split_radius;
        params.fade_start = fade_end * ctx.config.last_cascade_fade;
        params.fade_end = fade_end;
        params.shadow_strength = ctx.config.shadow_strength;
        params.debug_colors = @intFromBool(ctx.config.debug_cascade_colors);
    }
    @memcpy(self.param_buffers[ctx.frame_idx][0..@sizeOf(ShadowParams)], std.mem.asBytes(&params));
}

/// Frustum planes for one cascade, camera-relative, matching Frustum's
/// inside = normal·p + w >= 0 convention. The range matches the projection exactly so
/// the cull and the raster agree about which geometry is inside the cascade; nothing
/// outside the projected depth range is culled in, so depth clamping never paints
/// false occluder depth at the map edges.
fn cullPlanes(committed: Csm.CommittedCascade, view_pos: Csm.Vec3d) [6]@Vector(4, f32) {
    const basis = Csm.buildLightBasis(committed.light_dir, Csm.world_up);
    const c: Csm.Vec3f = .{ @floatCast(committed.center_abs[0] - view_pos[0]), @floatCast(committed.center_abs[1] - view_pos[1]), @floatCast(committed.center_abs[2] - view_pos[2]) };
    const f = basis.forward;
    const f_c = Csm.dot3f(f, c);
    var planes: [6]@Vector(4, f32) = undefined;
    const axes: [2]Csm.Vec3f = .{ basis.right, basis.up };
    for (axes, 0..) |axis, i| {
        const a_c = Csm.dot3f(axis, c);
        planes[i * 2] = .{ axis[0], axis[1], axis[2], -a_c + committed.radius };
        planes[i * 2 + 1] = .{ -axis[0], -axis[1], -axis[2], a_c + committed.radius };
    }
    planes[4] = .{ f[0], f[1], f[2], -f_c - committed.near_plane };
    planes[5] = .{ -f[0], -f[1], -f[2], f_c + committed.far_plane };
    return planes;
}

/// Number of cascades being refreshed this frame (the shadow cull dispatches this many
/// times, once per slot).
pub fn frameCascadeCount(self: *const ShadowRenderer) u32 {
    return self.frame_cascade_count;
}

/// The nearest cascade being refreshed this frame, for stats and debug.
pub fn frameInnermostCascade(self: *const ShadowRenderer) ?u32 {
    if (self.frame_cascade_count == 0) return null;
    return self.frame_cascades[0];
}

/// Cull planes for the cascade refreshed in `slot` this frame.
pub fn frameCascadePlanes(self: *const ShadowRenderer, slot: u32) [6]@Vector(4, f32) {
    return cullPlanes(self.pending[self.frame_cascades[slot]].?, self.frame_origin);
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
    const info = self.memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, self.param_buffers[frame_idx].ptr);
    return .{ .buffer = info.buffer, .offset = info.offset, .range = @sizeOf(ShadowParams) };
}

/// Drops a cascade that was computed but not rasterized: it must not be promoted next
/// frame (promotion would commit a matrix whose layer was never written), and its
/// last-refresh stamp is reset so the next frame re-picks it immediately.
fn dropCascade(self: *ShadowRenderer, cascade: usize) void {
    self.pending[cascade] = null;
    self.last_refresh[cascade] = Csm.never_refreshed;
}

/// Records the shadow raster pass for the frame's cascades. Must run inside the face
/// buffer acquire/release window (the draw binds it as a vertex buffer).
pub fn recordShadowPass(
    self: *ShadowRenderer,
    cmd_buffer: vk.CommandBuffer,
    frame_idx: u32,
    face: gpu.GpuRegionAllocator.Binding,
) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordShadowPass" });
    defer zone.end();
    const gpu_zone = self.vk_ctx.gpu_profiler.beginZone(cmd_buffer, frame_idx, .{ .src = @src(), .name = "shadow" });
    defer gpu_zone.end();
    if (self.image == .null_handle) {
        for (self.frame_cascades[0..self.frame_cascade_count]) |cascade| self.dropCascade(cascade);
        self.frame_cascade_count = 0;
        return;
    }

    // Bound state persists across the per-cascade rendering scopes in one command buffer,
    // so only the attachment, push constants, and draw change per cascade.
    const extent: vk.Extent2D = .{ .width = self.map_size, .height = self.map_size };
    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.pipeline);
    // Cull front faces: the light view matrix (buildViewProj rows s,u,f) has opposite
    // handedness to the camera, so the exterior/occluder faces (top faces, sun-facing
    // sides) are the BACK faces there. Culling back faces would keep the cave
    // interior's faces instead and the surface would never reach the map.
    core.setDynamicState(self.dev, cmd_buffer, extent, .{ .front = true }, .{ .compare_op = .less_or_equal, .write = true });
    const mesh_desc_set = self.scene.mesh_data_descriptor_sets_per_frame[frame_idx];
    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.pipeline_layout, 0, (&mesh_desc_set)[0..1], null);
    self.dev.cmdBindVertexBuffers(cmd_buffer, 0, (&face.buffer)[0..1], (&face.offset)[0..1]);

    for (self.frame_cascades[0..self.frame_cascade_count], 0..) |cascade, slot| {
        self.recordCascadePass(cmd_buffer, frame_idx, extent, cascade, @intCast(slot));
    }
}

/// Records the depth raster for a single cascade layer: layout transitions, clear, and
/// the indirect draw of the frame's culled geometry through the cascade's light matrix.
fn recordCascadePass(self: *ShadowRenderer, cmd_buffer: vk.CommandBuffer, frame_idx: u32, extent: vk.Extent2D, cascade: u32, slot: u32) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordCascadePass" });
    defer zone.end();

    const layer_range = depthRange(cascade, 1);

    // Within-command-buffer dependency: this frame's fragment reads (opaque/transparent
    // sample the shadow array) precede the write to this cascade's layer.
    const pre_barrier = core.imageBarrier2Range(self.image, layer_range, .shader_read_only_optimal, .depth_stencil_attachment_optimal, .{ .fragment_shader = true }, .{ .shader_read = true }, .{ .early_fragment_tests = true, .late_fragment_tests = true }, .{ .depth_stencil_attachment_write = true });
    core.pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, (&pre_barrier)[0..1]);

    // Standard depth (not reversed-Z): ortho depth is linear, so clear to far (1.0) and
    // compare LESS_OR_EQUAL. The main pipeline's reversed-Z convention must NOT be used.
    const depth_attachment = core.renderingAttachmentDepth(self.views[cascade], .depth_stencil_attachment_optimal, .clear, 1.0);
    self.dev.cmdBeginRendering(cmd_buffer, &core.renderingInfo(extent, &.{}, &depth_attachment));

    // The matrix must match the params used when sampling next frame: rebuilt from the
    // pending cascade at the origin the raster uses (the same origin the cascade was
    // computed at), so light-space coordinates are world-anchored. The pending slot is
    // promoted into committed (the sampled state) at the start of the next prepareFrame.
    const shadow_pc = ShadowPushConstants{
        .light_viewproj = Csm.viewProjAtOrigin(self.pending[cascade].?, self.frame_origin),
        .mesh_base = (gpu.shadow_slot_base + slot) * self.scene.draw_capacity,
    };
    self.dev.cmdPushConstants(cmd_buffer, self.pipeline_layout, .{ .vertex = true }, 0, @sizeOf(ShadowPushConstants), &shadow_pc);

    const frame = &self.scene.frame_buffers[frame_idx];
    const indirect_offset = frame.indirect_draw_offset + @as(vk.DeviceSize, @intCast(gpu.shadow_slot_base + slot)) * self.scene.draw_capacity * @sizeOf(vk.DrawIndirectCommand);
    const count_offset = frame.count_offset + @as(vk.DeviceSize, @intCast(@offsetOf(gpu.CullCount, "shadow_count") + slot * @sizeOf(u32)));
    self.dev.cmdDrawIndirectCount(cmd_buffer, frame.indirect_draw, indirect_offset, frame.count, count_offset, self.scene.draw_capacity, @sizeOf(vk.DrawIndirectCommand));

    self.dev.cmdEndRendering(cmd_buffer);

    // Trailing transition back to sampled layout; visible to the next frame's fragment
    // reads without any top-of-frame barrier.
    const post_barrier = core.imageBarrier2Range(self.image, layer_range, .depth_stencil_attachment_optimal, .shader_read_only_optimal, .{ .early_fragment_tests = true, .late_fragment_tests = true }, .{ .depth_stencil_attachment_write = true }, .{ .fragment_shader = true }, .{ .shader_read = true });
    core.pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, (&post_barrier)[0..1]);
}

test {
    std.testing.refAllDecls(@This());
}

test "effectiveMinChunkSize respects lowest shadow level" {
    // Level 0 chunks span 32 blocks: with no texel floor, size-16 chunks (level -1)
    // are culled while size-32 chunks (level 0) still cast.
    const floor_0 = effectiveMinChunkSize(0, 0);
    try std.testing.expect(floor_0 > 16.0 and floor_0 <= 32.0);

    // A tiny level floor loses to the texel floor exactly.
    try std.testing.expectEqual(@as(f32, 1000.0), effectiveMinChunkSize(1000.0, -100));

    // A coarse level floor dominates the texel floor.
    try std.testing.expect(effectiveMinChunkSize(0, 10) > 1000.0);
}
