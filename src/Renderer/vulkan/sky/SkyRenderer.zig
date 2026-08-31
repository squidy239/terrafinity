const std = @import("std");
const tracy = @import("tracy");
const vk = @import("vulkan");

const DeviceProxy = vk.DeviceProxy;

const VulkanContext = @import("../../../VulkanContext.zig").VulkanContext;
const core = @import("../core.zig");
const gpu = @import("../gpu.zig");

const sky_vert_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("sky_vert_spv")));
const sky_frag_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("sky_frag_spv")));

pub const max_planets: usize = 4;

const degrees_per_circle: f32 = 360.0;
const min_day_length_sec: f32 = 0.001;

/// Tunable sky values stored in RenderOptions. Plain arrays (no vectors) so the config can
/// be serialized to zon and edited through the struct_ui without layout concerns.
pub const SkyConfig = struct {
    sun_color: [4]f32,
    sun_glow_color: [4]f32,
    sun_angular_radius: f32,
    sun_glow_power: f32,
    sun_intensity: f32,
    moon_color: [4]f32,
    moon_angular_radius: f32,
    moon_phase: f32,
    planet_dirs: [max_planets][4]f32,
    planet_colors: [max_planets][4]f32,
    planet_radii: [max_planets]f32,
    planet_count: f32,
    star_density: f32,
    star_seed: f32,
    star_brightness_min: f32,
    star_brightness_max: f32,
    zenith_color: [4]f32,
    horizon_color: [4]f32,
    ground_color: [4]f32,
    sun_scatter: [4]f32,
    transition_power: f32,
    exposure: f32,

    pub fn default() SkyConfig {
        return .{
            .sun_color = .{ 1.0, 0.95, 0.85, 0.0 },
            .sun_glow_color = .{ 1.0, 0.6, 0.3, 0.0 },
            .sun_angular_radius = std.math.degreesToRadians(2.0),
            .sun_glow_power = 400.0,
            .sun_intensity = 1.2,
            .moon_color = .{ 0.9, 0.9, 0.95, 0.0 },
            .moon_angular_radius = std.math.degreesToRadians(1.4),
            .moon_phase = 1.0,
            .planet_dirs = .{
                .{ 0.7, 0.2, 0.4, 0.0 },
                .{ -0.6, 0.35, -0.2, 0.0 },
                .{ 0.1, -0.4, 0.8, 0.0 },
                .{ 0.5, 0.0, -0.7, 0.0 },
            },
            .planet_colors = .{
                .{ 0.8, 0.6, 0.4, 0.0 },
                .{ 0.5, 0.7, 0.9, 0.0 },
                .{ 0.9, 0.5, 0.5, 0.0 },
                .{ 0.6, 0.8, 0.6, 0.0 },
            },
            .planet_radii = .{ std.math.degreesToRadians(0.6), std.math.degreesToRadians(0.4), std.math.degreesToRadians(0.5), std.math.degreesToRadians(0.3) },
            .planet_count = 0,
            .star_density = 55.0,
            .star_seed = 1.0,
            .star_brightness_min = 0.02,
            .star_brightness_max = 0.9,
            // Colors are written directly to the UNORM swapchain, so they are display-ready
            // values (not linear). Kept saturated so the day sky reads clearly blue, never white.
            .zenith_color = .{ 0.1, 0.32, 0.85, 0.0 },
            .horizon_color = .{ 0.35, 0.58, 0.9, 0.0 },
            .ground_color = .{ 0.35, 0.32, 0.3, 0.0 },
            .sun_scatter = .{ 0.9, 0.5, 0.2, 0.0 },
            .transition_power = 1.0,
            .exposure = 1.0,
        };
    }
};

/// std430 storage-block layout mirrored by sky.frag. All vector members are vec4s so Zig
/// and GLSL agree on 16-byte slots (Zig would round a `@Vector(3, f32) align(16)` to size 16,
/// while GLSL std430 vec3 is size 12 — a guaranteed mismatch). The shader uses `.xyz`.
/// The camera block replaces an inverse view-projection matrix: the view is a pure rotation
/// about the origin, so the sky ray is a combination of the camera basis vectors.
pub const SkyParams = extern struct {
    camera_front: @Vector(4, f32),
    camera_side: @Vector(4, f32),
    camera_up: @Vector(4, f32),
    tan_factor: f32,
    tan_half: f32,
    sun_dir: @Vector(4, f32),
    sun_color: @Vector(4, f32),
    sun_glow_color: @Vector(4, f32),
    sun_angular_radius: f32,
    sun_glow_power: f32,
    sun_intensity: f32,
    moon_dir: @Vector(4, f32),
    moon_color: @Vector(4, f32),
    moon_angular_radius: f32,
    moon_phase: f32,
    planet_dirs: [max_planets]@Vector(4, f32) align(16),
    planet_colors: [max_planets]@Vector(4, f32) align(16),
    planet_radii: [max_planets]f32,
    planet_count: f32,
    star_density: f32,
    star_seed: f32,
    star_brightness_min: f32,
    star_brightness_max: f32,
    zenith_color: @Vector(4, f32),
    horizon_color: @Vector(4, f32),
    ground_color: @Vector(4, f32),
    sun_scatter: @Vector(4, f32),
    transition_power: f32,
    exposure: f32,

    /// GPU-side params from the user config. The camera block, sun, and moon directions are
    /// per-frame data set by `assembleParams` and start as placeholders here.
    pub fn fromConfig(cfg: SkyConfig) SkyParams {
        var planet_dirs: [max_planets]@Vector(4, f32) = undefined;
        for (cfg.planet_dirs, &planet_dirs) |dir, *dst| dst.* = dir;
        var planet_colors: [max_planets]@Vector(4, f32) = undefined;
        for (cfg.planet_colors, &planet_colors) |color, *dst| dst.* = color;
        return .{
            .camera_front = .{ 0.0, 0.0, 1.0, 0.0 },
            .camera_side = .{ 1.0, 0.0, 0.0, 0.0 },
            .camera_up = .{ 0.0, 1.0, 0.0, 0.0 },
            .tan_factor = 0.0,
            .tan_half = 0.0,
            .sun_dir = .{ 0.0, 1.0, 0.0, 0.0 },
            .sun_color = cfg.sun_color,
            .sun_glow_color = cfg.sun_glow_color,
            .sun_angular_radius = cfg.sun_angular_radius,
            .sun_glow_power = cfg.sun_glow_power,
            .sun_intensity = cfg.sun_intensity,
            .moon_dir = .{ 0.0, -1.0, 0.0, 0.0 },
            .moon_color = cfg.moon_color,
            .moon_angular_radius = cfg.moon_angular_radius,
            .moon_phase = cfg.moon_phase,
            .planet_dirs = planet_dirs,
            .planet_colors = planet_colors,
            .planet_radii = cfg.planet_radii,
            .planet_count = cfg.planet_count,
            .star_density = cfg.star_density,
            .star_seed = cfg.star_seed,
            .star_brightness_min = cfg.star_brightness_min,
            .star_brightness_max = cfg.star_brightness_max,
            .zenith_color = cfg.zenith_color,
            .horizon_color = cfg.horizon_color,
            .ground_color = cfg.ground_color,
            .sun_scatter = cfg.sun_scatter,
            .transition_power = cfg.transition_power,
            .exposure = cfg.exposure,
        };
    }

    pub fn default() SkyParams {
        return fromConfig(.default());
    }
};

/// Sun direction from the epoch-based day cycle, fixed in world space. The sun orbits in
/// the YZ plane (elevation follows `day_length_sec`) and never depends on the camera.
/// The sign matches the original `zm.rotationRH`-derived direction: (0, cos, -sin).
pub fn computeSunDirection(io: std.Io, day_length_sec: f32) @Vector(3, f32) {
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const now_ns_f = @as(f64, @floatFromInt(now_ns));
    const angle = @rem(now_ns_f / (@as(f64, @max(min_day_length_sec, day_length_sec)) * std.time.ns_per_s / degrees_per_circle), degrees_per_circle);
    const radians = std.math.degreesToRadians(@as(f32, @floatCast(angle)));
    return .{ 0.0, @cos(radians), @sin(radians) };
}

/// Per-frame sky data: the GPU params plus the sun direction shared with chunk lighting.
pub const FrameSky = struct {
    params: SkyParams,
    sun_dir: @Vector(3, f32),
};

/// Builds the per-frame sky params from the user config: the sun/moon directions and the
/// camera basis. No matrix inversion — the projection's inverse reduces to two scalars
/// (`tan_factor`, `tan_half`) because the view is a pure rotation about the origin.
pub fn assembleParams(
    io: std.Io,
    cfg: SkyConfig,
    camera_front: @Vector(3, f32),
    aspect: f32,
    fov_radians: f32,
    day_length_sec: f32,
) FrameSky {
    const sun_dir = computeSunDirection(io, day_length_sec);
    var params = SkyParams.fromConfig(cfg);
    params.sun_dir = .{ sun_dir[0], sun_dir[1], sun_dir[2], 0.0 };
    params.moon_dir = .{ -sun_dir[0], -sun_dir[1], -sun_dir[2], 0.0 };

    const world_up: @Vector(3, f32) = .{ 0.0, 1.0, 0.0 };
    var side = cross3(camera_front, world_up);
    const side_len_sq = dot3(side, side);
    if (side_len_sq == 0.0) {
        // Front exactly parallel to world up: the scene's lookAtRH is degenerate here too,
        // so any perpendicular axis is as good as another.
        side = cross3(camera_front, .{ 0.0, 0.0, 1.0 });
    }
    side /= @as(@Vector(3, f32), @splat(@sqrt(dot3(side, side))));
    const up = cross3(side, camera_front);

    const tan_half = @tan(fov_radians / 2.0);
    params.camera_front = .{ camera_front[0], camera_front[1], camera_front[2], 0.0 };
    params.camera_side = .{ side[0], side[1], side[2], 0.0 };
    params.camera_up = .{ up[0], up[1], up[2], 0.0 };
    params.tan_factor = aspect * tan_half;
    params.tan_half = tan_half;
    return .{ .params = params, .sun_dir = sun_dir };
}

fn cross3(a: @Vector(3, f32), b: @Vector(3, f32)) @Vector(3, f32) {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn dot3(a: @Vector(3, f32), b: @Vector(3, f32)) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

comptime {
    // Pin every field offset to the std430 layout baked into sky.frag. Scalar clusters
    // following vec4s must start exactly where GLSL places them (vec4 = 16-byte slots).
    if (@offsetOf(SkyParams, "tan_factor") != 48) @compileError("SkyParams.tan_factor offset mismatch (expected 48)");
    if (@offsetOf(SkyParams, "tan_half") != 52) @compileError("SkyParams.tan_half offset mismatch (expected 52)");
    if (@offsetOf(SkyParams, "sun_dir") != 64) @compileError("SkyParams.sun_dir offset mismatch (expected 64)");
    if (@offsetOf(SkyParams, "sun_angular_radius") != 112) @compileError("SkyParams.sun_angular_radius offset mismatch (expected 112)");
    if (@offsetOf(SkyParams, "sun_glow_power") != 116) @compileError("SkyParams.sun_glow_power offset mismatch (expected 116)");
    if (@offsetOf(SkyParams, "sun_intensity") != 120) @compileError("SkyParams.sun_intensity offset mismatch (expected 120)");
    if (@offsetOf(SkyParams, "moon_dir") != 128) @compileError("SkyParams.moon_dir offset mismatch (expected 128)");
    if (@offsetOf(SkyParams, "moon_angular_radius") != 160) @compileError("SkyParams.moon_angular_radius offset mismatch (expected 160)");
    if (@offsetOf(SkyParams, "moon_phase") != 164) @compileError("SkyParams.moon_phase offset mismatch (expected 164)");
    if (@offsetOf(SkyParams, "planet_dirs") != 176) @compileError("SkyParams.planet_dirs offset mismatch (expected 176)");
    if (@offsetOf(SkyParams, "planet_count") != 320) @compileError("SkyParams.planet_count offset mismatch (expected 320)");
    if (@offsetOf(SkyParams, "zenith_color") != 352) @compileError("SkyParams.zenith_color offset mismatch (expected 352)");
    if (@offsetOf(SkyParams, "transition_power") != 416) @compileError("SkyParams.transition_power offset mismatch (expected 416)");
    if (@offsetOf(SkyParams, "exposure") != 420) @compileError("SkyParams.exposure offset mismatch (expected 420)");
    if (@sizeOf(SkyParams) != 432) @compileError("SkyParams size mismatch (expected 432)");
}

const ParamBuffer = core.ParamBuffer;

/// Everything the sky pass needs to record itself, gathered by the caller (VulkanRenderer).
pub const RecordContext = struct {
    cmd_buffer: vk.CommandBuffer,
    frame_idx: u32,
    extent: vk.Extent2D,
    color_image: vk.Image,
    color_view: vk.ImageView,
    depth_image: vk.Image,
    depth_view: vk.ImageView,
    depth_aspect_mask: vk.ImageAspectFlags,
    frame_sequence: u64,
    msaa_color_image: ?vk.Image = null,
    msaa_color_view: ?vk.ImageView = null,
    color_resolve_view: ?vk.ImageView = null,
    msaa_depth_image: ?vk.Image = null,
    msaa_depth_view: ?vk.ImageView = null,
    depth_resolve_view: ?vk.ImageView = null,
    depth_resolve_mode: vk.ResolveModeFlags = .{},
    msaa_sample_count: u32 = 1,
};

/// Renders a fully procedural sky (atmosphere gradient, sun, moon, planets, hash-based
/// stars) as a single fullscreen pass into the scene's color target, clearing depth to far
/// so opaque geometry draws in front. No geometry, no textures, no per-frame allocations.
pub const SkyRenderer = @This();

allocator: std.mem.Allocator,
vk_ctx: *VulkanContext,
dev: DeviceProxy,
memory: *gpu.GpuMemory,

pipeline: vk.Pipeline = .null_handle,
pipeline_layout: vk.PipelineLayout = .null_handle,
descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
descriptor_pool: vk.DescriptorPool = .null_handle,
descriptor_sets_per_frame: []vk.DescriptorSet = &.{},
param_buffers: []ParamBuffer = &.{},

pub fn init(allocator: std.mem.Allocator, vk_ctx: *VulkanContext, memory: *gpu.GpuMemory) !SkyRenderer {
    var self: SkyRenderer = .{
        .allocator = allocator,
        .vk_ctx = vk_ctx,
        .dev = vk_ctx.dev,
        .memory = memory,
    };
    errdefer self.deinit();

    const binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment_bit = true },
        .p_immutable_samplers = null,
    };
    self.descriptor_set_layout = try core.createDescriptorSetLayout(self.dev, &self.vk_ctx.vkalloc, .{}, (&binding)[0..1]);

    self.pipeline_layout = try self.dev.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = (&self.descriptor_set_layout)[0..1],
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
    }, &self.vk_ctx.vkalloc);

    const pool_size = vk.DescriptorPoolSize{ .type = .storage_buffer, .descriptor_count = @intCast(VulkanContext.max_frames_in_flight) };
    try core.createFrameDescriptorPool(
        self.dev,
        allocator,
        &self.vk_ctx.vkalloc,
        &self.descriptor_pool,
        self.descriptor_set_layout,
        &self.descriptor_sets_per_frame,
        (&pool_size)[0..1],
    );

    const cpu_to_gpu = memory.cpuToGpu();
    self.param_buffers = try allocator.alloc(ParamBuffer, VulkanContext.max_frames_in_flight);
    for (self.param_buffers) |*buf| buf.* = .{ .mapping = &.{} };

    for (self.param_buffers) |*buf| {
        buf.mapping = try cpu_to_gpu.alignedAlloc(u8, .fromByteUnits(16), @sizeOf(SkyParams));
    }

    self.updateParamDescriptors();
    return self;
}

pub fn deinit(self: *SkyRenderer) void {
    for (self.param_buffers) |*buf| self.freeParamBuffer(buf);
    if (self.param_buffers.len > 0) {
        self.allocator.free(self.param_buffers);
        self.param_buffers = &.{};
    }
    self.destroyDescriptorResources();
    core.destroyIfValid(self.dev, &self.pipeline, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.pipeline_layout, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.descriptor_set_layout, &self.vk_ctx.vkalloc);
}

fn freeParamBuffer(self: *SkyRenderer, buf: *ParamBuffer) void {
    if (buf.mapping.len > 0) {
        self.memory.cpuToGpu().free(buf.mapping);
        buf.mapping = &.{};
    }
}

fn destroyDescriptorResources(self: *SkyRenderer) void {
    core.destroyFrameDescriptorResources(self.dev, self.allocator, &self.vk_ctx.vkalloc, &self.descriptor_pool, &self.descriptor_sets_per_frame);
}

fn updateParamDescriptors(self: *SkyRenderer) void {
    for (self.param_buffers, self.descriptor_sets_per_frame) |buf, set| {
        const info = self.memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, buf.mapping.ptr);
        const buffer_info: vk.DescriptorBufferInfo = .{ .buffer = info.buffer, .offset = info.offset, .range = @sizeOf(SkyParams) };
        const write = core.bufferWriteDescriptorSet(set, 0, .storage_buffer, &buffer_info);
        self.dev.updateDescriptorSets((&write)[0..1], null);
    }
}

/// Recreates the pipeline for the current depth format. Called on init and swapchain recreate.
pub fn createPipelines(self: *SkyRenderer, depth_format: vk.Format, samples: vk.SampleCountFlags) !void {
    core.destroyIfValid(self.dev, &self.pipeline, &self.vk_ctx.vkalloc);

    const vert_module = try core.createShaderModule(self.dev, &self.vk_ctx.vkalloc, sky_vert_spv);
    defer self.dev.destroyShaderModule(vert_module, &self.vk_ctx.vkalloc);
    const frag_module = try core.createShaderModule(self.dev, &self.vk_ctx.vkalloc, sky_frag_spv);
    defer self.dev.destroyShaderModule(frag_module, &self.vk_ctx.vkalloc);

    const depth_stencil = core.depthStencilState(false, .always, false);
    const blend = core.opaqueBlendAttachment();
    const no_vertex_input = core.emptyVertexInput();
    if (samples.@"1_bit") {
        self.pipeline = try core.buildGraphicsPipeline(
            self.dev,
            &self.vk_ctx.vkalloc,
            self.vk_ctx.pipeline_creation_feedback,
            vert_module,
            frag_module,
            &.{self.vk_ctx.swapchain_format},
            depth_format,
            depth_stencil,
            &.{blend},
            self.pipeline_layout,
            no_vertex_input,
        );
    } else {
        self.pipeline = try core.buildGraphicsPipelineWithSamples(
            self.dev,
            &self.vk_ctx.vkalloc,
            self.vk_ctx.pipeline_creation_feedback,
            vert_module,
            frag_module,
            &.{self.vk_ctx.swapchain_format},
            depth_format,
            depth_stencil,
            &.{blend},
            self.pipeline_layout,
            no_vertex_input,
            samples,
        );
    }
}

/// Copies the given params into the current frame's uniform buffer. Call before `record`.
pub fn uploadParams(self: *SkyRenderer, frame_idx: u32, params: *const SkyParams) void {
    @memcpy(self.param_buffers[frame_idx].mapping[0..@sizeOf(SkyParams)], std.mem.asBytes(params));
}

pub fn record(self: *SkyRenderer, ctx: *const RecordContext) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordSky" });
    defer zone.end();
    const gpu_zone = self.vk_ctx.gpu_profiler.beginZone(ctx.cmd_buffer, ctx.frame_idx, .{ .src = @src(), .name = "sky" });
    defer gpu_zone.end();
    const cmd_buffer = ctx.cmd_buffer;
    const color_aspect: vk.ImageAspectFlags = .{ .color_bit = true };
    const first_frame = ctx.frame_sequence == 0;
    const color_old_layout: vk.ImageLayout = if (first_frame) .undefined else .shader_read_only_optimal;
    const depth_old_layout: vk.ImageLayout = if (first_frame) .undefined else .depth_stencil_read_only_optimal;
    const src_stage: vk.PipelineStageFlags2 = if (first_frame) .{ .top_of_pipe_bit = true } else .{ .fragment_shader_bit = true, .compute_shader_bit = true };
    const color_src_access: vk.AccessFlags2 = if (first_frame) .{} else .{ .shader_read_bit = true };
    const depth_src_access: vk.AccessFlags2 = if (first_frame) .{} else .{ .depth_stencil_attachment_read_bit = true, .shader_read_bit = true };

    const msaa_color_enabled = ctx.msaa_color_image != null;
    const msaa_depth_enabled = ctx.msaa_depth_image != null;
    const color_count: usize = if (msaa_color_enabled) 2 else 1;
    const depth_count: usize = if (msaa_depth_enabled) 2 else 1;
    const total_barriers = color_count + depth_count;
    if (total_barriers == 4) {
        const pre_barriers: [4]vk.ImageMemoryBarrier2 = .{
            core.makeImageBarrier2(
                ctx.color_image,
                color_old_layout,
                .color_attachment_optimal,
                src_stage,
                color_src_access,
                .{ .color_attachment_output_bit = true },
                .{ .color_attachment_write_bit = true },
                color_aspect,
            ),
            core.makeImageBarrier2(
                ctx.msaa_color_image.?,
                if (first_frame) .undefined else .color_attachment_optimal,
                .color_attachment_optimal,
                if (first_frame) .{ .top_of_pipe_bit = true } else .{ .color_attachment_output_bit = true },
                if (first_frame) @as(vk.AccessFlags2, .{}) else .{ .color_attachment_write_bit = true },
                .{ .color_attachment_output_bit = true },
                .{ .color_attachment_write_bit = true },
                color_aspect,
            ),
            core.makeImageBarrier2(
                ctx.depth_image,
                depth_old_layout,
                .depth_stencil_attachment_optimal,
                src_stage,
                depth_src_access,
                .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
                .{ .depth_stencil_attachment_write_bit = true },
                ctx.depth_aspect_mask,
            ),
            core.makeImageBarrier2(
                ctx.msaa_depth_image.?,
                if (first_frame) .undefined else .depth_stencil_attachment_optimal,
                .depth_stencil_attachment_optimal,
                if (first_frame) .{ .top_of_pipe_bit = true } else .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
                if (first_frame) @as(vk.AccessFlags2, .{}) else .{ .depth_stencil_attachment_write_bit = true },
                .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
                .{ .depth_stencil_attachment_write_bit = true },
                ctx.depth_aspect_mask,
            ),
        };
        core.pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, &pre_barriers);
    } else if (msaa_color_enabled) {
        const pre_barriers: [3]vk.ImageMemoryBarrier2 = .{
            core.makeImageBarrier2(
                ctx.color_image,
                color_old_layout,
                .color_attachment_optimal,
                src_stage,
                color_src_access,
                .{ .color_attachment_output_bit = true },
                .{ .color_attachment_write_bit = true },
                color_aspect,
            ),
            core.makeImageBarrier2(
                ctx.msaa_color_image.?,
                if (first_frame) .undefined else .color_attachment_optimal,
                .color_attachment_optimal,
                if (first_frame) .{ .top_of_pipe_bit = true } else .{ .color_attachment_output_bit = true },
                if (first_frame) @as(vk.AccessFlags2, .{}) else .{ .color_attachment_write_bit = true },
                .{ .color_attachment_output_bit = true },
                .{ .color_attachment_write_bit = true },
                color_aspect,
            ),
            core.makeImageBarrier2(
                ctx.depth_image,
                depth_old_layout,
                .depth_stencil_attachment_optimal,
                src_stage,
                depth_src_access,
                .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
                .{ .depth_stencil_attachment_write_bit = true },
                ctx.depth_aspect_mask,
            ),
        };
        core.pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, &pre_barriers);
    } else {
        const pre_barriers: [2]vk.ImageMemoryBarrier2 = .{
            core.makeImageBarrier2(
                ctx.color_image,
                color_old_layout,
                .color_attachment_optimal,
                src_stage,
                color_src_access,
                .{ .color_attachment_output_bit = true },
                .{ .color_attachment_write_bit = true },
                color_aspect,
            ),
            core.makeImageBarrier2(
                ctx.depth_image,
                depth_old_layout,
                .depth_stencil_attachment_optimal,
                src_stage,
                depth_src_access,
                .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
                .{ .depth_stencil_attachment_write_bit = true },
                ctx.depth_aspect_mask,
            ),
        };
        core.pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, &pre_barriers);
    }

    const use_msaa = ctx.msaa_color_view != null and ctx.color_resolve_view != null and ctx.msaa_sample_count > 1;
    const use_msaa_depth = ctx.msaa_depth_view != null and ctx.depth_resolve_view != null and ctx.msaa_sample_count > 1;
    const color_attachment = if (use_msaa) core.renderingAttachmentColorResolve(ctx.msaa_color_view.?, ctx.color_resolve_view.?, .clear, .{ 0.0, 0.0, 0.0, 1.0 }) else core.renderingAttachmentColor(ctx.color_view, .clear, .{ 0.0, 0.0, 0.0, 1.0 });
    const depth_attachment = if (use_msaa_depth) core.renderingAttachmentDepthClearResolve(ctx.msaa_depth_view.?, ctx.depth_resolve_view.?, .depth_stencil_attachment_optimal, 0.0, ctx.depth_resolve_mode) else core.renderingAttachmentDepthClear(ctx.depth_view, .depth_stencil_attachment_optimal, 0.0);
    self.dev.cmdBeginRendering(cmd_buffer, &core.renderingInfo(ctx.extent, &.{color_attachment}, &depth_attachment));

    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.pipeline);
    core.setDynamicState(self.dev, cmd_buffer, .{}, .always, false);
    core.setViewportAndScissor(self.dev, cmd_buffer, ctx.extent);

    const desc_set: vk.DescriptorSet = self.descriptor_sets_per_frame[ctx.frame_idx];
    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.pipeline_layout, 0, (&desc_set)[0..1], null);
    self.dev.cmdDraw(cmd_buffer, core.fullscreen_triangle_vertices, 1, 0, 0);

    self.dev.cmdEndRendering(cmd_buffer);
}

test "SkyParams.default produces a valid std430-sized struct" {
    const p = SkyParams.default();
    try std.testing.expectEqual(@as(usize, 432), @sizeOf(SkyParams));
    try std.testing.expect(p.sun_intensity > 0.0);
    try std.testing.expect(p.planet_count == 0.0);
    try std.testing.expectEqual(@as(usize, max_planets), p.planet_dirs.len);
}

fn initTest(allocator: std.mem.Allocator, vk_ctx: *VulkanContext, memory: *gpu.GpuMemory) !void {
    var sky = try SkyRenderer.init(allocator, vk_ctx, memory);
    sky.deinit();
}

test "assembleParams ray matches the inverse view-projection" {
    const zm = @import("zm");

    const fov = std.math.degreesToRadians(70.0);
    const aspect: f32 = 1.6;
    const near: f32 = 0.01;
    const inv_tan: f32 = 1.0 / @tan(fov / 2.0);
    const fronts: [5]@Vector(3, f32) = .{
        .{ 0.0, 0.0, 1.0 },
        .{ 0.5, 0.3, -0.8 },
        .{ -0.7, 0.6, 0.2 },
        .{ 0.3, 0.95, 0.1 },
        .{ 1e-4, 0.99999999, -2e-4 },
    };
    const ndcs: [9][2]f32 = .{
        .{ -1, -1 },    .{ 1, -1 },     .{ -1, 1 },    .{ 1, 1 },       .{ 0, 0 },
        .{ 0.5, -0.3 }, .{ -0.7, 0.9 }, .{ 0.9, 0.1 }, .{ -0.4, -0.8 },
    };

    for (fronts) |front| {
        const front_n = front / @as(@Vector(3, f32), @splat(@sqrt(dot3(front, front))));
        const frame_sky = assembleParams(std.testing.io, SkyConfig.default(), front_n, aspect, fov, 300.0);

        const proj: zm.Mat4f = .{ .data = .{
            .{ inv_tan / aspect, 0.0, 0.0, 0.0 },
            .{ 0.0, -inv_tan, 0.0, 0.0 },
            .{ 0.0, 0.0, 0.0, near },
            .{ 0.0, 0.0, -1.0, 0.0 },
        } };
        const view = zm.Mat4f.lookAtRH(
            .{ .data = .{ 0.0, 0.0, 0.0 } },
            .{ .data = front_n },
            .{ .data = .{ 0.0, 1.0, 0.0 } },
        );
        const inv = try proj.multiply(view).inverse();
        var inv_cm: [16]f32 = undefined;
        for (0..4) |row| {
            for (0..4) |col| {
                inv_cm[col * 4 + row] = inv.data[row][col];
            }
        }

        for (ndcs) |ndc| {
            var world: [4]f32 = @splat(0);
            for (0..4) |row| {
                for (0..4) |col| {
                    const n: f32 = if (col < 2) ndc[col] else 1.0;
                    world[row] += inv_cm[col * 4 + row] * n;
                }
            }
            const ref: @Vector(3, f32) = .{ world[0] / world[3], world[1] / world[3], world[2] / world[3] };
            const ref_dir = ref / @as(@Vector(3, f32), @splat(@sqrt(dot3(ref, ref))));

            const cf = frame_sky.params.camera_front;
            const cs = frame_sky.params.camera_side;
            const cu = frame_sky.params.camera_up;
            var basis: @Vector(3, f32) = .{ cf[0], cf[1], cf[2] };
            basis += @as(@Vector(3, f32), .{ cs[0], cs[1], cs[2] }) * @as(@Vector(3, f32), @splat(ndc[0] * frame_sky.params.tan_factor));
            basis -= @as(@Vector(3, f32), .{ cu[0], cu[1], cu[2] }) * @as(@Vector(3, f32), @splat(ndc[1] * frame_sky.params.tan_half));
            const basis_dir = basis / @as(@Vector(3, f32), @splat(@sqrt(dot3(basis, basis))));

            inline for (0..3) |i| {
                try std.testing.expectApproxEqAbs(ref_dir[i], basis_dir[i], 1e-4);
            }
        }
    }
}

test "SkyRenderer init/deinit allocation failures" {
    // Window and context are created once outside the failing-allocator runs; wio's global
    // state does not survive OOM injection, so only SkyRenderer.init is exercised per-run.
    const wio_mod = @import("wio");
    try wio_mod.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .eventFn = wio_mod.EventQueue.eventFn });
    defer wio_mod.deinit();
    var events: wio_mod.EventQueue = .empty;
    defer events.deinit();
    var window = try wio_mod.Window.create(.{ .title = "test", .event_fn_data = &events });
    defer window.destroy();
    const vk_ctx = try VulkanContext.init(std.testing.allocator, &window);
    defer vk_ctx.deinit(std.testing.io);
    var memory: gpu.GpuMemory = undefined;
    try memory.init(std.testing.io, std.testing.allocator, vk_ctx);
    defer memory.deinit();

    try std.testing.checkAllAllocationFailures(std.testing.allocator, initTest, .{ vk_ctx, &memory });
}
