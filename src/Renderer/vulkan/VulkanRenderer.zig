const std = @import("std");

const tracy = @import("tracy");
const vk = @import("vulkan");
const DeviceProxy = vk.DeviceProxy;

const Renderer = @import("../../Renderer.zig");
const FrameDrawContext = Renderer.FrameDrawContext;
const VulkanContext = @import("../../VulkanContext.zig").VulkanContext;
const Chunk = @import("../../world/Chunk.zig");
const World = @import("../../world/World.zig");
const ChunkPos = World.ChunkPos;
const Mesher = @import("../Mesher.zig");
const ChunkRenderer = @import("chunk_renderer/ChunkRenderer.zig").ChunkRenderer;
const core = @import("core.zig");
const gpu = @import("gpu.zig");
const DepthPyramid = @import("occlusion/DepthPyramid.zig").DepthPyramid;
const OitCompositor = @import("OitCompositor.zig").OitCompositor;
const ShadowRenderer = @import("shadow/ShadowRenderer.zig").ShadowRenderer;
const SkyRenderer = @import("sky/SkyRenderer.zig").SkyRenderer;

/// Starting sizes of the indirect scene's candidate and draw-slot buffers; both grow on
/// demand, so these only set how many chunks fit before the first reallocation.
const initial_scene_candidates: u32 = 32768;
const initial_draw_capacity: u32 = 32768;
const initial_face_buffer_bytes = 256 * 1024 * 1024;
const uploader_face_quota = 64;

const FrameDebugStats = struct {
    frame_number: u64 = 0,
    total_meshes: u32 = 0,
    opaque_drawn: u32 = 0,
    opaque_late_drawn: u32 = 0,
    transparent_drawn: u32 = 0,
    hiz_occluded: u32 = 0,
    frustum_culled: u32 = 0,
    opaque_faces: u32 = 0,
    transparent_faces: u32 = 0,
    shadow_faces: u32 = 0,
    shadow_cascade: ?u32 = null,
    player_pos: @Vector(3, f64) = .{ 0, 0, 0 },
    camera_front: @Vector(3, f32) = .{ 0, 0, 1 },
    elapsed_ns: u64 = 0,

    pub fn log(self: *const FrameDebugStats) void {
        std.log.info("Frame {d}: pos=({d:.1}, {d:.1}, {d:.1}) front=({d:.3}, {d:.3}, {d:.3}) time={d:.2}ms", .{
            self.frame_number,
            self.player_pos[0],
            self.player_pos[1],
            self.player_pos[2],
            self.camera_front[0],
            self.camera_front[1],
            self.camera_front[2],
            @as(f64, @floatFromInt(self.elapsed_ns)) / 1_000_000.0,
        });
        std.log.info("Meshes: {d} total, opaque drawn: {d} ({d} late), transparent: {d}, occluded: {d}, frustum culled: {d}", .{ self.total_meshes, self.opaque_drawn, self.opaque_late_drawn, self.transparent_drawn, self.hiz_occluded, self.frustum_culled });
        std.log.info("Faces drawn - opaque: {d}  transparent: {d}  total: {d}", .{ self.opaque_faces, self.transparent_faces, self.opaque_faces + self.transparent_faces });
        if (self.shadow_cascade) |cascade_index| {
            std.log.info("Shadow - cascade {d}: {d} faces", .{ cascade_index, self.shadow_faces });
        }
    }
};

pub const VulkanRenderer = @This();

vk_ctx: *VulkanContext,
allocator: std.mem.Allocator,
dev: DeviceProxy,

render_color: core.RenderTarget = .{},
render_depth: core.RenderTarget = .{},
render_depth_sampled_view: vk.ImageView = .null_handle,
msaa_color: core.RenderTarget = .{},
msaa_depth: core.RenderTarget = .{},
msaa_samples: vk.SampleCountFlags = .{ .@"1" = true },
msaa_sample_count: u32 = 1,
depth_resolve_mode: vk.ResolveModeFlags = .{},
/// True when the MSAA depth resolve is conservative for the Hi-Z MIN-reduce (min mode,
/// or no MSAA at all). Average/sample-zero resolves can sit nearer than the closest
/// sample, so the pyramid would cull visible silhouettes.
depth_resolve_conservative: bool = false,
depth_format: vk.Format = .undefined,

memory: gpu.GpuMemory = undefined,
single_time: core.SingleTime = undefined,
uploader: gpu.MeshUploader = undefined,
scene: gpu.IndirectScene = undefined,
oit: OitCompositor = undefined,
chunk: ChunkRenderer = undefined,
sky: SkyRenderer = undefined,
shadow: ShadowRenderer = undefined,
pyramid: DepthPyramid = undefined,

render_options: *const Renderer.RenderOptions,
render_options_lock: *std.Io.RwLock,
interface: Renderer,

init_time_ns: u64 = 0,
last_stat_log_ns: u64 = 0,
frame_stats: FrameDebugStats = .{},

/// Monotonically increasing frame counter detecting the first frame after init or
/// swapchain recreation, whose render targets still hold their initial layout.
/// Do not reset outside init; partial-frame resets would use the wrong old layout.
frame_sequence: u64 = 0,

pub fn init(self: *VulkanRenderer, io: std.Io, allocator: std.mem.Allocator, vk_ctx: *VulkanContext, render_options: *const Renderer.RenderOptions, render_options_lock: *std.Io.RwLock) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "init" });
    defer zone.end();
    std.log.info("VulkanRenderer.init: Starting renderer-specific Vulkan initialization...", .{});

    self.* = .{
        .vk_ctx = vk_ctx,
        .allocator = allocator,
        .dev = vk_ctx.dev,
        .render_options = render_options,
        .render_options_lock = render_options_lock,
        .interface = undefined,
    };

    self.init_time_ns = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);

    try self.memory.init(io, allocator, vk_ctx);
    errdefer self.memory.deinit();

    self.single_time = try .init(vk_ctx, io);
    errdefer self.single_time.deinit();

    self.uploader = try gpu.MeshUploader.init(allocator, vk_ctx, &self.memory, &self.single_time, initial_face_buffer_bytes, Mesher.max_face_bytes * uploader_face_quota);
    errdefer self.uploader.deinit();

    try self.scene.init(allocator, vk_ctx, &self.memory, initial_scene_candidates, initial_draw_capacity);
    errdefer self.scene.deinit();

    self.pyramid = try DepthPyramid.init(allocator, vk_ctx, &self.memory, &self.single_time);
    errdefer self.pyramid.deinit();

    self.shadow = try ShadowRenderer.init(vk_ctx, &self.memory, &self.single_time, &self.scene);
    errdefer self.shadow.deinit();

    self.render_options_lock.lockSharedUncancelable(io);
    const initial_shadow_config = self.render_options.shadow;
    self.render_options_lock.unlockShared(io);
    try self.shadow.recreate(io, initial_shadow_config);

    self.oit = try OitCompositor.init(allocator, vk_ctx);
    errdefer self.oit.deinit();

    self.sky = try SkyRenderer.init(allocator, vk_ctx, &self.memory);
    errdefer self.sky.deinit();

    try self.chunk.init(io, allocator, vk_ctx, &self.memory, &self.single_time, &self.uploader, &self.scene, &self.oit, &self.shadow, &self.pyramid, render_options, render_options_lock);
    errdefer self.chunk.deinit(io);

    try self.recreateSwapchainResourcesLocked(io);

    self.interface = .{
        .userdata = @ptrCast(self),
        .vtable = &.{
            .addChunk = vtableAddChunk,
            .removeChunk = vtableRemoveChunk,
            .hasMesh = vtableHasMesh,
            .draw = vtableDraw,
            .recreateSwapchain = vtableRecreateSwapchain,
        },
    };
}

pub fn deinit(self: *VulkanRenderer, io: std.Io) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "deinit" });
    defer zone.end();
    std.log.info("VulkanRenderer.deinit: Flushing pending uploads and waiting for device idle...", .{});

    self.chunk.flushPendingUploads(io) catch {
        @panic("VulkanRenderer.deinit: failed to flush submission batch - GPU state may be inconsistent");
    };
    {
        self.vk_ctx.queue_mutex.lockUncancelable(io);
        defer self.vk_ctx.queue_mutex.unlock(io);
        self.dev.deviceWaitIdle() catch {
            @panic("VulkanRenderer.deinit: deviceWaitIdle failed - cannot safely release GPU resources");
        };

        self.dev.resetCommandPool(self.vk_ctx.upload_command_pool, .{}) catch |err| std.log.err("upload command pool reset failed during deinit: {}", .{err});
        self.dev.resetCommandPool(self.vk_ctx.command_pool, .{ .release_resources = true }) catch |err| std.log.err("command pool reset failed during deinit: {}", .{err});
        // The UI command pool is owned by main and may be mid-recording when
        // deinit runs from a failed openGame inside the UI record path;
        // resetting it yanks the buffer under the recorder and the next
        // drawClippedTriangles faults on a non-recording command buffer.
        self.single_time.deinit();
    }

    self.chunk.deinit(io);
    self.sky.deinit();
    self.shadow.deinit();
    self.pyramid.deinit();
    self.scene.deinit();
    self.uploader.deinit();
    self.destroyRendererSwapchainResources();
    self.oit.deinit();
    self.memory.deinit();
}

fn recreateSwapchainResourcesLocked(self: *VulkanRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recreateSwapchainResourcesLocked" });
    defer zone.end();
    self.render_options_lock.lockSharedUncancelable(io);
    const gamma_correction = self.render_options.gamma_correction;
    const present_mode = self.render_options.present_mode;
    const anti_aliasing = self.render_options.anti_aliasing;
    self.render_options_lock.unlockShared(io);

    try self.vk_ctx.waitSubmittedFrames();
    try self.dev.resetCommandPool(self.vk_ctx.command_pool, .{});

    const old_swapchain = self.vk_ctx.swapchain;
    try self.vk_ctx.createSwapchainLocked(io, gamma_correction, present_mode);

    if (self.vk_ctx.swapchain == old_swapchain and self.render_color.image != .null_handle) return;

    self.destroyRendererSwapchainResources();

    const actual_extent = self.vk_ctx.swapchain_extent;

    try self.createRenderTargets(io, actual_extent, anti_aliasing);

    const samples = core.sampleCountToFlags(self.msaa_sample_count);
    try self.chunk.createPipelines(self.depth_format, samples);
    try self.sky.createPipelines(self.depth_format, samples);
}

fn destroyRendererSwapchainResources(self: *VulkanRenderer) void {
    core.destroyRenderTarget(self.vk_ctx, &self.render_color);
    core.destroyRenderTarget(self.vk_ctx, &self.render_depth);
    core.destroyIfValid(self.dev, &self.render_depth_sampled_view, &self.vk_ctx.vkalloc);
    core.destroyRenderTarget(self.vk_ctx, &self.msaa_color);
    core.destroyRenderTarget(self.vk_ctx, &self.msaa_depth);
}

fn createRenderTargets(self: *VulkanRenderer, io: std.Io, extent: vk.Extent2D, anti_aliasing: Renderer.AntiAliasing) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "createRenderTargets" });
    defer zone.end();
    errdefer self.destroyRendererSwapchainResources();

    const desired = sampleCountFromAA(anti_aliasing);
    const resolved = self.resolveSampleCount(desired);
    self.msaa_sample_count = resolved;
    self.msaa_samples = core.sampleCountToFlags(resolved);
    const use_msaa = resolved > 1;

    self.render_color = try core.createImageWithMemory(self.vk_ctx, extent, self.vk_ctx.swapchain_format, .{ .color_attachment = true, .sampled = true }, .{ .color = true }, .{ .@"1" = true });

    const depth_formats: [3]vk.Format = .{ .d32_sfloat_s8_uint, .d24_unorm_s8_uint, .d32_sfloat };
    self.depth_format = for (depth_formats) |format| {
        // The transparent pass samples the depth, so both features are required.
        const features = self.vk_ctx.instance.getPhysicalDeviceFormatProperties(self.vk_ctx.pdev, format).optimal_tiling_features;
        if (features.depth_stencil_attachment and features.sampled_image) break format;
    } else return error.DepthFormatNotSupported;

    self.render_depth = try core.createImageWithMemory(self.vk_ctx, extent, self.depth_format, .{ .depth_stencil_attachment = true, .sampled = true }, self.depthAspectMask(), .{ .@"1" = true });
    self.render_depth_sampled_view = try self.dev.createImageView(&core.imageViewCreateInfo(self.render_depth.image, self.depth_format, .{ .depth = true }), &self.vk_ctx.vkalloc);

    if (use_msaa) {
        self.msaa_color = try core.createImageWithMemory(self.vk_ctx, extent, self.vk_ctx.swapchain_format, .{ .color_attachment = true }, .{ .color = true }, self.msaa_samples);
        self.msaa_depth = try core.createImageWithMemory(self.vk_ctx, extent, self.depth_format, .{ .depth_stencil_attachment = true }, self.depthAspectMask(), self.msaa_samples);
        self.depth_resolve_mode = self.getDepthResolveMode();
        self.depth_resolve_conservative = self.depth_resolve_mode.min;
        std.log.info("VulkanRenderer: MSAA enabled {d}x (samples={any}) depth_resolve={any}", .{ resolved, self.msaa_samples, self.depth_resolve_mode });
    } else {
        self.msaa_color = .{};
        self.msaa_depth = .{};
        self.depth_resolve_mode = .{};
        // Single-sample depth is the exact nearest sample: no resolve, so conservative.
        self.depth_resolve_conservative = true;
        std.log.info("VulkanRenderer: MSAA disabled", .{});
    }

    try self.pyramid.recreate(io, extent);

    try self.oit.recreate(extent, self.render_color.view);

    std.log.info("VulkanRenderer.createRenderTargets: SUCCESS - Created render targets: color {any}, depth {any}, msaa {any}, accum {any}, reveal {any}\n", .{ self.render_color.image, self.render_depth.image, self.msaa_color.image, self.oit.accum.image, self.oit.reveal.image });
    self.frame_sequence = 0;
}

fn depthAspectMask(self: *const VulkanRenderer) vk.ImageAspectFlags {
    return if (self.depth_format == .d32_sfloat_s8_uint or self.depth_format == .d24_unorm_s8_uint)
        .{ .depth = true, .stencil = true }
    else
        .{ .depth = true };
}

fn sampleCountFromAA(aa: Renderer.AntiAliasing) u32 {
    return switch (aa) {
        .none => 1,
        .msaa2x => 2,
        .msaa4x => 4,
        .msaa8x => 8,
    };
}

fn resolveSampleCount(self: *const VulkanRenderer, desired: u32) u32 {
    // Walk down from the desired count until the device supports it; every intermediate
    // power of two is visited exactly once, so overshooting the device max lands on it.
    // Sample count 2^N is flag bit 2^N, so the supported test is a plain bitmask.
    const counts = self.vk_ctx.instance.getPhysicalDeviceProperties(self.vk_ctx.pdev).limits.framebuffer_color_sample_counts;
    var target = desired;
    while (target > 1 and (counts.toInt() & target) == 0) target /= 2;
    return target;
}

fn getDepthResolveMode(self: *const VulkanRenderer) vk.ResolveModeFlags {
    var props2: vk.PhysicalDeviceProperties2 = .{ .properties = undefined };
    var depth_resolve_props: vk.PhysicalDeviceDepthStencilResolveProperties = .{
        .s_type = .physical_device_depth_stencil_resolve_properties,
        .p_next = null,
        .supported_depth_resolve_modes = .{},
        .supported_stencil_resolve_modes = .{},
        .independent_resolve_none = .false,
        .independent_resolve = .false,
    };
    props2.p_next = @ptrCast(&depth_resolve_props);
    self.vk_ctx.instance.getPhysicalDeviceProperties2(self.vk_ctx.pdev, &props2);
    const modes = depth_resolve_props.supported_depth_resolve_modes;
    // The Hi-Z pyramid MIN-reduces the depth, so only a min resolve is conservative.
    // Average/sample-zero can be nearer than the closest sample; the caller gates
    // occlusion culling off in that case rather than culling visible silhouettes.
    if (modes.min) return .{ .min = true };
    if (modes.average) return .{ .average = true };
    return .{ .sample_zero = true };
}

fn draw(self: *VulkanRenderer, io: std.Io, target: Renderer.DrawTarget, frame_ctx: FrameDrawContext, view_pos: @Vector(3, f64), view_front: @Vector(3, f32)) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const current_frame = frame_ctx.frame_index;

    // The drain runs on a background task; the frame reaps a finished pass and
    // publishes its scene effects now that beginFrame has proven the GPU idle.
    try self.chunk.restartDrain(io);
    self.chunk.publishPending(io);

    const extent: vk.Extent2D = .{ .width = target.width, .height = target.height };

    self.readCullStats(current_frame);

    self.render_options_lock.lockSharedUncancelable(io);
    const aspect = @as(f32, @floatFromInt(target.width)) / @as(f32, @floatFromInt(target.height));
    const fov = std.math.degreesToRadians(self.render_options.fov);
    const day_length_sec = self.render_options.day_length_sec;
    const inside_transparent = self.render_options.inside_transparent;
    const occlusion_culling = self.render_options.occlusion_culling;
    const sky_config = self.render_options.sky;
    const shadow_config = self.render_options.shadow;
    self.render_options_lock.unlockShared(io);
    const vp = core.computeViewProjection(view_front, aspect, fov);

    // No-op when unchanged; must run before any command buffer records.
    self.shadow.recreate(io, shadow_config) catch |err| {
        std.log.err("VulkanRenderer: shadow recreate failed: {any}", .{err});
    };

    const total_candidates = self.scene.max_allocated_index;
    try self.scene.ensureCapacity(total_candidates);

    try self.dev.resetCommandBuffer(frame_ctx.cmd_buffer, .{});
    try self.dev.beginCommandBuffer(frame_ctx.cmd_buffer, &.{ .flags = .{ .one_time_submit = true }, .p_inheritance_info = null });
    errdefer self.dev.endCommandBuffer(frame_ctx.cmd_buffer) catch |err| std.log.err("VulkanRenderer: endCommandBuffer during unwind failed: {any}", .{err});
    self.vk_ctx.gpu_profiler.resetFrame(frame_ctx.cmd_buffer, current_frame);

    const depth_aspect_mask = self.depthAspectMask();
    const frame_start_ns: u64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    const elapsed_sec = @as(f32, @floatFromInt(frame_start_ns -| self.init_time_ns)) / std.time.ns_per_s;

    const frame_sky = SkyRenderer.assembleParams(io, sky_config, view_front, aspect, fov, day_length_sec);

    const scene_aabb = self.scene.getSceneAABB(current_frame);
    self.shadow.prepareFrame(current_frame, shadow_config, view_pos, frame_sky.sun_dir, scene_aabb.min, scene_aabb.max);

    const msaa_enabled = self.msaa_sample_count > 1 and self.msaa_color.image != .null_handle;
    const msaa_color_image: ?vk.Image = if (msaa_enabled) self.msaa_color.image else null;
    const msaa_color_view: ?vk.ImageView = if (msaa_enabled) self.msaa_color.view else null;
    const color_resolve_view: ?vk.ImageView = if (msaa_enabled) self.render_color.view else null;
    const msaa_depth_image: ?vk.Image = if (msaa_enabled) self.msaa_depth.image else null;
    const msaa_depth_view: ?vk.ImageView = if (msaa_enabled) self.msaa_depth.view else null;
    const depth_resolve_view: ?vk.ImageView = if (msaa_enabled) self.render_depth.view else null;
    const pass_ctx: ChunkRenderer.PassContext = .{
        .cmd_buffer = frame_ctx.cmd_buffer,
        .frame_idx = current_frame,
        .extent = extent,
        .view_pos = view_pos,
        .projview = vp.projview,
        .frustum = vp.frustum,
        .total_candidates = total_candidates,
        .elapsed_sec = elapsed_sec,
        .sun_dir = frame_sky.sun_dir,
        .inside_transparent = inside_transparent,
        .occlusion_culling = occlusion_culling,
        .swapchain_old_layout = frame_ctx.swapchain_image_layout.*,
        .swapchain_layout_ptr = frame_ctx.swapchain_image_layout,
        .output_image = frame_ctx.output_image,
        .output_view = frame_ctx.output_view,
        .color_image = self.render_color.image,
        .color_view = self.render_color.view,
        .depth_image = self.render_depth.image,
        .depth_view = self.render_depth.view,
        .depth_sampled_view = self.render_depth_sampled_view,
        .depth_aspect_mask = depth_aspect_mask,
        .frame_sequence = self.frame_sequence,
        .face = self.uploader.faceBinding(),
        .shadow = &self.shadow,
        .msaa_color_view = msaa_color_view,
        .color_resolve_view = color_resolve_view,
        .msaa_depth_view = msaa_depth_view,
        .depth_resolve_view = depth_resolve_view,
        .depth_resolve_mode = self.depth_resolve_mode,
        .depth_resolve_conservative = self.depth_resolve_conservative,
        .msaa_sample_count = self.msaa_sample_count,
    };
    self.sky.uploadParams(current_frame, &frame_sky.params);
    self.sky.record(&.{
        .cmd_buffer = frame_ctx.cmd_buffer,
        .frame_idx = current_frame,
        .extent = extent,
        .color_image = self.render_color.image,
        .color_view = self.render_color.view,
        .depth_image = self.render_depth.image,
        .depth_view = self.render_depth.view,
        .depth_aspect_mask = depth_aspect_mask,
        .frame_sequence = self.frame_sequence,
        .msaa_color_image = msaa_color_image,
        .msaa_color_view = msaa_color_view,
        .color_resolve_view = color_resolve_view,
        .msaa_depth_image = msaa_depth_image,
        .msaa_depth_view = msaa_depth_view,
        .depth_resolve_view = depth_resolve_view,
        .depth_resolve_mode = self.depth_resolve_mode,
        .msaa_sample_count = self.msaa_sample_count,
    });

    self.chunk.recordPasses(&pass_ctx);

    const frame_end_ns: u64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    self.publishFrameStats(io, view_pos, view_front, frame_end_ns, frame_end_ns -| frame_start_ns);

    try self.dev.endCommandBuffer(frame_ctx.cmd_buffer);
    self.frame_sequence +%= 1;
}

/// Copies the previous frame's GPU cull counters, which the compute pass wrote into the
/// host-visible stats buffer, into the debug stats shown by the UI.
fn readCullStats(self: *VulkanRenderer, current_frame: u32) void {
    const stats = self.scene.frame_buffers[current_frame].slices.stats[0];
    self.frame_stats.opaque_drawn = stats.opaque_count + stats.opaque_late_count;
    self.frame_stats.opaque_late_drawn = stats.opaque_late_count;
    self.frame_stats.transparent_drawn = stats.transparent_count;
    self.frame_stats.hiz_occluded = stats.occluded_count;
    self.frame_stats.frustum_culled = stats.frustum_culled_count;
    self.frame_stats.opaque_faces = stats.opaque_face_count + stats.opaque_late_face_count;
    self.frame_stats.transparent_faces = stats.transparent_face_count;
    var shadow_faces: u32 = 0;
    for (stats.shadow_face_count) |faces| shadow_faces +%= faces;
    self.frame_stats.shadow_faces = shadow_faces;
    self.frame_stats.shadow_cascade = self.shadow.frameInnermostCascade();
}

fn publishFrameStats(self: *VulkanRenderer, io: std.Io, view_pos: @Vector(3, f64), view_front: @Vector(3, f32), frame_end_ns: u64, elapsed_ns: u64) void {
    self.frame_stats.frame_number = self.vk_ctx.frame_number.load(.acquire) + 1;
    self.frame_stats.total_meshes = @intCast(self.chunk.meshes.count(io));
    self.frame_stats.player_pos = view_pos;
    self.frame_stats.camera_front = view_front;
    self.frame_stats.elapsed_ns = elapsed_ns;

    if (frame_end_ns -| self.last_stat_log_ns < std.time.ns_per_s) return;
    self.last_stat_log_ns = frame_end_ns;
    self.frame_stats.log();
}

fn vtableAddChunk(user_data: *Renderer.Implementation, io: std.Io, chunk_pos: ChunkPos, encoding: Chunk.Encoding, neighbor_faces: *const [6]Chunk.Encoding.Face) (std.Io.Cancelable || error{AddChunkFailed})!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    self.chunk.addChunk(io, chunk_pos, encoding, neighbor_faces) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.AddChunkFailed,
    };
}

fn vtableRemoveChunk(user_data: *Renderer.Implementation, io: std.Io, chunk_pos: ChunkPos) (std.Io.Cancelable || error{RemoveChunkFailed})!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    self.chunk.removeChunk(io, chunk_pos) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.RemoveChunkFailed,
    };
}

fn vtableHasMesh(user_data: *Renderer.Implementation, io: std.Io, chunk_pos: ChunkPos) bool {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    return self.chunk.hasMesh(io, chunk_pos);
}

fn vtableDraw(user_data: *Renderer.Implementation, io: std.Io, target: Renderer.DrawTarget, frame_ctx: FrameDrawContext, view_pos: @Vector(3, f64), view_front: @Vector(3, f32)) (std.Io.Cancelable || error{DrawFailed})!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    self.draw(io, target, frame_ctx, view_pos, view_front) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.DrawFailed,
    };
}

fn vtableRecreateSwapchain(user_data: *Renderer.Implementation, io: std.Io) !void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    try self.recreateSwapchainResourcesLocked(io);
}
