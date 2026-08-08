const std = @import("std");

const tracy = @import("tracy");
const vk = @import("vulkan");
const zm = @import("zm");

const DeviceProxy = vk.DeviceProxy;

const Renderer = @import("../../Renderer.zig");
const FrameDrawContext = Renderer.FrameDrawContext;
const VulkanContext = @import("../../VulkanContext.zig").VulkanContext;
const Mesher = @import("../Mesher.zig");
const Chunk = @import("../../world/Chunk.zig");
const World = @import("../../world/World.zig");
const ChunkPos = World.ChunkPos;
const core = @import("core.zig");
const gpu = @import("gpu.zig");
const OitCompositor = @import("OitCompositor.zig").OitCompositor;
const ChunkRenderer = @import("chunk_renderer/ChunkRenderer.zig").ChunkRenderer;
const SkyRenderer = @import("sky/SkyRenderer.zig").SkyRenderer;
const ShadowRenderer = @import("shadow/ShadowRenderer.zig").ShadowRenderer;

const FrameDebugStats = struct {
    frame_number: u64 = 0,
    total_meshes: u32 = 0,
    opaque_drawn: u32 = 0,
    transparent_drawn: u32 = 0,
    opaque_faces: u32 = 0,
    transparent_faces: u32 = 0,
    shadow_faces: u32 = 0,
    shadow_cascade: ?u32 = null,
    player_pos: @Vector(3, f64) = .{ 0, 0, 0 },
    camera_front: @Vector(3, f32) = .{ 0, 0, 1 },
    elapsed_ns: u64 = 0,

    pub fn log(self: *const FrameDebugStats) void {
        const total_faces = self.opaque_faces + self.transparent_faces;
        const elapsed_f: f64 = @floatFromInt(self.elapsed_ns);
        const ms = elapsed_f / 1_000_000.0;
        std.log.info("=== FRAME {d} DEBUG STATS ===", .{self.frame_number});
        std.log.info("Player pos=({d:.1}, {d:.1}, {d:.1})  Camera front=({d:.3}, {d:.3}, {d:.3})", .{
            self.player_pos[0],   self.player_pos[1],   self.player_pos[2],
            self.camera_front[0], self.camera_front[1], self.camera_front[2],
        });
        std.log.info("Meshes in map: {d}  drawn opaque: {d}  transparent: {d}", .{ self.total_meshes, self.opaque_drawn, self.transparent_drawn });
        std.log.info("Faces drawn - opaque: {d}  transparent: {d}  total: {d}", .{ self.opaque_faces, self.transparent_faces, total_faces });
        if (self.shadow_cascade) |c| {
            std.log.info("Shadow - cascade {d}: {d} faces", .{ c, self.shadow_faces });
        }
        std.log.info("Time: {d:.2} ms", .{ms});
        std.log.info("========================", .{});
    }
};

pub const VulkanRenderer = @This();

vk_ctx: *VulkanContext,
allocator: std.mem.Allocator,
dev: DeviceProxy,

render_color: core.RenderTarget = .{},
render_depth: core.RenderTarget = .{},
render_depth_sampled_view: vk.ImageView = .null_handle,
depth_format: vk.Format = .undefined,

camera: core.Camera = .{},
memory: gpu.GpuMemory = undefined,
single_time: core.SingleTime = undefined,
uploader: gpu.MeshUploader = undefined,
scene: gpu.IndirectScene = undefined,
oit: OitCompositor = undefined,
chunk: ChunkRenderer = undefined,
sky: SkyRenderer = undefined,
shadow: ShadowRenderer = undefined,

render_options: *const Renderer.RenderOptions,
render_options_lock: *std.Io.RwLock,
interface: Renderer,

init_time_ns: u64 = 0,
last_stat_log_ns: u64 = 0,
frame_stats: FrameDebugStats = .{},

/// Monotonically increasing frame counter used to detect the first frame after initialization
/// or swapchain recreation. Frame 0 uses `.undefined` as the old layout for render targets
/// (skipping layout transition on initial layout). Subsequent frames use the actual prior
/// layout (e.g. `.shader_read_only_optimal`) to properly transition back to color attachment.
/// Do not reset this counter outside of init — partial-frame resets would use wrong old layouts.
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

    self.single_time = .{
        .dev = vk_ctx.dev,
        .pool = vk_ctx.upload_command_pool,
        .queue = vk_ctx.graphics_queue,
        .queue_mutex = &vk_ctx.queue_mutex,
        .vkalloc = vk_ctx.vkalloc,
    };

    const max_face_bytes = @as(vk.DeviceSize, World.ChunkSize) * World.ChunkSize * World.ChunkSize * 6 * @sizeOf(Mesher.Face);
    self.uploader = try gpu.MeshUploader.init(allocator, vk_ctx, &self.memory, &self.single_time, 64 * 1024 * 1024, max_face_bytes * 64);
    errdefer self.uploader.deinit();

    try self.scene.init(allocator, vk_ctx, &self.memory, 4096, 4096);
    errdefer self.scene.deinit();

    self.shadow = try ShadowRenderer.init(allocator, vk_ctx, &self.memory, &self.single_time, &self.scene, render_options, render_options_lock);
    errdefer self.shadow.deinit();

    self.render_options_lock.lockSharedUncancelable(io);
    const initial_shadow_config = self.render_options.shadow;
    self.render_options_lock.unlockShared(io);
    try self.shadow.recreate(io, initial_shadow_config);

    self.oit = try OitCompositor.init(allocator, vk_ctx);
    errdefer self.oit.deinit();

    self.sky = try SkyRenderer.init(allocator, vk_ctx, &self.memory);
    errdefer self.sky.deinit();

    try self.chunk.init(io, allocator, vk_ctx, &self.memory, &self.single_time, &self.uploader, &self.scene, &self.oit, &self.shadow, render_options, render_options_lock);
    errdefer self.chunk.deinit(io);

    try self.recreateSwapchainResourcesLocked(io);

    self.interface = .{
        .userdata = @ptrCast(self),
        .vtable = &.{
            .addChunk = vtableAddChunk,
            .removeChunk = vtableRemoveChunk,
            .draw = vtableDraw,
            .recreateSwapchain = vtableRecreateSwapchain,
            .updateCameraDirection = vtableUpdateCameraDirection,
            .forEachMesh = vtableForEachMesh,
        },
    };
}

pub fn deinit(self: *VulkanRenderer, io: std.Io) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "deinit" });
    defer zone.end();
    std.log.info("VulkanRenderer.deinit: Flushing pending uploads and waiting for device idle...", .{});

    {
        self.chunk.flushPendingUploads(io) catch {
            @panic("VulkanRenderer.deinit: failed to flush submission batch - GPU state may be inconsistent");
        };
    }
    {
        self.vk_ctx.queue_mutex.lockUncancelable(io);
        defer self.vk_ctx.queue_mutex.unlock(io);
        self.dev.deviceWaitIdle() catch {
            @panic("VulkanRenderer.deinit: deviceWaitIdle failed - cannot safely release GPU resources");
        };

        self.dev.resetCommandPool(self.vk_ctx.upload_command_pool, .{}) catch {};
        self.dev.resetCommandPool(self.vk_ctx.command_pool, .{ .release_resources_bit = true }) catch {};
        if (self.vk_ctx.ui_command_pool != .null_handle) {
            self.dev.resetCommandPool(self.vk_ctx.ui_command_pool, .{ .release_resources_bit = true }) catch {};
        }
        self.single_time.destroyFence();
    }

    self.chunk.deinit(io);
    self.sky.deinit();
    self.shadow.deinit();
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
    self.render_options_lock.unlockShared(io);
    self.vk_ctx.present_mode = present_mode;

    try self.uploader.drainInFlightFrames();
    try self.dev.resetCommandPool(self.vk_ctx.command_pool, .{});

    const old_swapchain = self.vk_ctx.swapchain;
    try self.vk_ctx.createSwapchainLocked(gamma_correction);

    if (self.vk_ctx.swapchain == old_swapchain and self.render_color.image != .null_handle) return;

    self.destroyRendererSwapchainResources();

    const actual_extent = self.vk_ctx.swapchain_extent;

    try self.createRenderTargets(actual_extent);

    try self.chunk.createPipelines(self.depth_format);
    try self.sky.createPipelines(self.depth_format);
}

fn destroyRendererSwapchainResources(self: *VulkanRenderer) void {
    core.destroyRenderTarget(self.dev, &self.render_color, &self.vk_ctx.vkalloc);
    core.destroyRenderTarget(self.dev, &self.render_depth, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.render_depth_sampled_view, &self.vk_ctx.vkalloc);
}

fn createRenderTargets(self: *VulkanRenderer, extent: vk.Extent2D) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "createRenderTargets" });
    defer zone.end();
    core.destroyRenderTarget(self.dev, &self.render_color, &self.vk_ctx.vkalloc);
    core.destroyRenderTarget(self.dev, &self.render_depth, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.render_depth_sampled_view, &self.vk_ctx.vkalloc);

    errdefer {
        core.destroyRenderTarget(self.dev, &self.render_color, &self.vk_ctx.vkalloc);
        core.destroyRenderTarget(self.dev, &self.render_depth, &self.vk_ctx.vkalloc);
        core.destroyIfValid(self.dev, &self.render_depth_sampled_view, &self.vk_ctx.vkalloc);
    }

    self.render_color = try core.createImageWithMemory(self.dev, self.vk_ctx.mem_props, &self.vk_ctx.vkalloc, extent, self.vk_ctx.swapchain_format, .{ .color_attachment_bit = true, .sampled_bit = true }, .{ .color_bit = true });

    const depth_formats: [3]vk.Format = .{ .d32_sfloat_s8_uint, .d24_unorm_s8_uint, .d32_sfloat };
    var depth_format: vk.Format = .undefined;
    for (depth_formats) |fmt| {
        // The transparent pass samples the depth, so both features are required.
        const features = self.vk_ctx.instance.getPhysicalDeviceFormatProperties(self.vk_ctx.pdev, fmt).optimal_tiling_features;
        if (features.depth_stencil_attachment_bit and features.sampled_image_bit) {
            depth_format = fmt;
            self.depth_format = fmt;
            break;
        }
    }
    if (depth_format == .undefined) return error.DepthFormatNotSupported;

    const depth_aspect_mask: vk.ImageAspectFlags = if (self.depthHasStencil()) .{ .depth_bit = true, .stencil_bit = true } else .{ .depth_bit = true };
    self.render_depth = try core.createImageWithMemory(self.dev, self.vk_ctx.mem_props, &self.vk_ctx.vkalloc, extent, depth_format, .{ .depth_stencil_attachment_bit = true, .sampled_bit = true }, depth_aspect_mask);
    self.render_depth_sampled_view = try self.dev.createImageView(&core.imageViewCreateInfo(self.render_depth.image, depth_format, .{ .depth_bit = true }), &self.vk_ctx.vkalloc);

    try self.oit.recreate(extent, self.render_color.view);

    std.log.info("VulkanRenderer.createRenderTargets: SUCCESS - Created render targets: color {any}, depth {any}, accum {any}, reveal {any}\n", .{ self.render_color.image, self.render_depth.image, self.oit.accum.image, self.oit.reveal.image });
    self.frame_sequence = 0;
}

fn depthHasStencil(self: *const VulkanRenderer) bool {
    return self.depth_format == .d32_sfloat_s8_uint or self.depth_format == .d24_unorm_s8_uint;
}

pub fn addChunk(self: *VulkanRenderer, io: std.Io, chunk_pos: ChunkPos, encoding: Chunk.Encoding, neighbor_faces: *const [6]Chunk.Encoding.Face) !void {
    try self.chunk.addChunk(io, chunk_pos, encoding, neighbor_faces);
}

pub fn removeChunk(self: *VulkanRenderer, io: std.Io, chunk_pos: ChunkPos) !void {
    try self.chunk.removeChunk(io, chunk_pos);
}

fn draw(self: *VulkanRenderer, io: std.Io, target: Renderer.DrawTarget, frame_ctx: FrameDrawContext, view_pos: @Vector(3, f64)) !void {
    const c = tracy.Zone.begin(.{ .src = @src() });
    defer c.end();

    const current_frame = frame_ctx.frame_index;
    const cmd_buffer = frame_ctx.cmd_buffer;
    const output_image = frame_ctx.output_image;
    const output_view = frame_ctx.output_view;
    const swapchain_old_layout = frame_ctx.swapchain_image_layout.*;
    const swapchain_layout_ptr = frame_ctx.swapchain_image_layout;

    try self.chunk.processPendingUploads(io);
    try self.chunk.processRetired(io);

    const extent: vk.Extent2D = .{ .width = target.width, .height = target.height };

    if (self.scene.frame_buffers.items[current_frame].stats_mapped) |counts| {
        self.frame_stats.opaque_drawn = counts[0].opaque_count;
        self.frame_stats.transparent_drawn = counts[0].transparent_count;
        self.frame_stats.opaque_faces = counts[0].opaque_face_count;
        self.frame_stats.transparent_faces = counts[0].transparent_face_count;
        self.frame_stats.shadow_faces = counts[0].shadow_face_count;
        self.frame_stats.shadow_cascade = self.shadow.frame_cascade;
    }

    self.render_options_lock.lockSharedUncancelable(io);
    defer self.render_options_lock.unlockShared(io);
    const aspect = @as(f32, @floatFromInt(target.width)) / @as(f32, @floatFromInt(target.height));
    const fov = std.math.degreesToRadians(self.render_options.fov);
    const day_length_sec = self.render_options.day_length_sec;
    const inside_transparent = self.render_options.inside_transparent;
    const sky_config = self.render_options.sky;

    const vp = self.camera.computeViewProjection(aspect, fov);
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const elapsed_sec = @as(f32, @floatFromInt(now_ns -| self.init_time_ns)) / std.time.ns_per_s;

    // Shadow config changes recreate the depth array before any command buffer records;
    // recreate is a no-op when nothing changed.
    self.shadow.recreate(io, self.render_options.shadow) catch |err| {
        std.log.err("VulkanRenderer: shadow recreate failed: {any}", .{err});
    };

    const total_candidates = self.scene.max_allocated_index.load(.monotonic);
    try self.scene.ensureCapacity(io, total_candidates);

    try self.dev.beginCommandBuffer(cmd_buffer, &.{ .flags = .{ .one_time_submit_bit = true }, .p_inheritance_info = null });
    errdefer self.dev.endCommandBuffer(cmd_buffer) catch {};

    const depth_aspect_mask: vk.ImageAspectFlags = if (self.depthHasStencil()) .{ .depth_bit = true, .stencil_bit = true } else .{ .depth_bit = true };
    const frame_start_ns = std.Io.Timestamp.now(io, .real).nanoseconds;

    const frame_sky = SkyRenderer.assembleParams(io, sky_config, self.camera.front(), aspect, fov, day_length_sec);

    const scene_aabb = self.scene.getSceneAABB();
    self.shadow.prepareFrame(
        io,
        current_frame,
        view_pos,
        aspect,
        fov,
        self.camera.front(),
        frame_sky.sun_dir,
        scene_aabb.min,
        scene_aabb.max,
    ) catch |err| {
        std.log.err("VulkanRenderer: shadow prepare failed: {any}", .{err});
    };

    const pass_ctx: ChunkRenderer.PassContext = .{
        .cmd_buffer = cmd_buffer,
        .frame_idx = current_frame,
        .extent = extent,
        .view_pos = view_pos,
        .projview = vp.projview,
        .frustum = vp.frustum,
        .total_candidates = total_candidates,
        .elapsed_sec = elapsed_sec,
        .sun_dir = frame_sky.sun_dir,
        .inside_transparent = inside_transparent,
        .swapchain_old_layout = swapchain_old_layout,
        .swapchain_layout_ptr = swapchain_layout_ptr,
        .output_image = output_image,
        .output_view = output_view,
        .color_image = self.render_color.image,
        .color_view = self.render_color.view,
        .depth_image = self.render_depth.image,
        .depth_view = self.render_depth.view,
        .depth_sampled_view = self.render_depth_sampled_view,
        .depth_aspect_mask = depth_aspect_mask,
        .frame_sequence = self.frame_sequence,
        .shadow = &self.shadow,
    };
    self.sky.uploadParams(current_frame, &frame_sky.params);
    self.sky.record(&.{
        .cmd_buffer = cmd_buffer,
        .frame_idx = current_frame,
        .extent = extent,
        .color_image = self.render_color.image,
        .color_view = self.render_color.view,
        .depth_image = self.render_depth.image,
        .depth_view = self.render_depth.view,
        .depth_aspect_mask = depth_aspect_mask,
        .frame_sequence = self.frame_sequence,
    });

    self.chunk.recordPasses(&pass_ctx);

    const frame_end_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const frame_elapsed_ns: u64 = @intCast(@max(0, frame_end_ns - frame_start_ns));

    const frame_num = self.vk_ctx.frame_number.load(.acquire) + 1;
    self.frame_stats.frame_number = frame_num;
    self.frame_stats.total_meshes = @intCast(self.chunk.meshes.count(io));
    self.frame_stats.player_pos = view_pos;
    self.frame_stats.camera_front = self.camera.front();
    self.frame_stats.elapsed_ns = frame_elapsed_ns;

    if (frame_end_ns - self.last_stat_log_ns >= std.time.ns_per_s) {
        self.last_stat_log_ns = @intCast(frame_end_ns);
        self.frame_stats.log();
    }

    self.frame_sequence += 1;
    try self.dev.endCommandBuffer(cmd_buffer);
}

fn vtableAddChunk(user_data: *Renderer.Implementation, io: std.Io, chunk_pos: ChunkPos, encoding: Chunk.Encoding, neighbor_faces: *const [6]Chunk.Encoding.Face) (std.Io.Cancelable || error{AddChunkFailed})!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    self.addChunk(io, chunk_pos, encoding, neighbor_faces) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.AddChunkFailed,
    };
}

fn vtableRemoveChunk(user_data: *Renderer.Implementation, io: std.Io, chunk_pos: ChunkPos) (std.Io.Cancelable || error{RemoveChunkFailed})!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    self.removeChunk(io, chunk_pos) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.RemoveChunkFailed,
    };
}

fn vtableDraw(user_data: *Renderer.Implementation, io: std.Io, target: Renderer.DrawTarget, frame_ctx: FrameDrawContext, view_pos: @Vector(3, f64)) (std.Io.Cancelable || error{DrawFailed})!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    self.draw(io, target, frame_ctx, view_pos) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.DrawFailed,
    };
}

fn vtableRecreateSwapchain(user_data: *Renderer.Implementation, io: std.Io) !void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    try self.recreateSwapchainResourcesLocked(io);
}

fn vtableUpdateCameraDirection(user_data: *Renderer.Implementation, view_dir: @Vector(3, f32)) void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    const front = Renderer.cameraFrontFromViewDirection(view_dir);
    const norm = zm.Vec3f.norm(.{ .data = front }).data;
    self.camera.updateFront(norm);
}

fn vtableForEachMesh(user_data: *Renderer.Implementation, io: std.Io, callback_user_data: *anyopaque, callback: *const fn (*anyopaque, ChunkPos) error{Failed}!void) (std.Io.Cancelable || error{Failed})!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    try self.chunk.forEachMesh(io, callback_user_data, callback);
}
