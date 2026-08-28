const std = @import("std");

const tracy = @import("tracy");
const vk = @import("vulkan");
const DeviceProxy = vk.DeviceProxy;

const ConcurrentHashMap = @import("../../../libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const Renderer = @import("../../../Renderer.zig");
const VulkanContext = @import("../../../VulkanContext.zig").VulkanContext;
const BFA = @import("../../../world/BufferFirstAllocator.zig");
const Chunk = @import("../../../world/Chunk.zig");
const World = @import("../../../world/World.zig");
const ChunkPos = World.ChunkPos;
const Mesher = @import("../../Mesher.zig");
const core = @import("../core.zig");
const Frustum = @import("../Frustum.zig").Frustum;
const gpu = @import("../gpu.zig");
const DepthPyramid = @import("../occlusion/DepthPyramid.zig").DepthPyramid;
const OitCompositor = @import("../OitCompositor.zig").OitCompositor;
const ShadowRenderer = @import("../shadow/ShadowRenderer.zig").ShadowRenderer;
const BlockMaterials = @import("BlockMaterials.zig").BlockMaterials;
const textures = @import("textures.zig");

const vertex_shader_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("vert_spv")));
const fragment_shader_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("frag_spv")));
const transparent_frag_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("trans_frag_spv")));
const cull_shader_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("cull_spv")));

const RenderBufferKey = union(enum) {
    @"opaque": ChunkPos,
    transparent: ChunkPos,

    pub fn toPos(self: RenderBufferKey) ChunkPos {
        return switch (self) {
            inline .@"opaque", .transparent => |pos| pos,
        };
    }
};

const batch_size = 64;
const pending_queue_size = 512;
/// Stack scratch for one chunk's meshing; larger meshes spill to the fallback allocator.
const mesh_scratch_bytes = 64 * 1024;

const SubmissionBatch = struct {
    cmds: [batch_size]vk.CommandBuffer = undefined,
    pools: [batch_size]vk.CommandPool = undefined,
    opaque_meshes: [batch_size]?gpu.UploadResult = undefined,
    transparent_meshes: [batch_size]?gpu.UploadResult = undefined,
    chunk_positions: [batch_size]ChunkPos = undefined,
    count: usize = 0,
    /// Max graphics value the batch's face regions depend on; the transfer submit
    /// waits for this instead of the newest frame so fresh regions drain ungated.
    max_safe_graphics: u64 = 0,
    mutex: std.Io.Mutex = .init,
};

const PendingMeshUpload = struct {
    chunk_pos: ChunkPos,
    timeline_value: u64,
    pool: vk.CommandPool,
    opaque_mesh: ?gpu.MeshBuffer,
    transparent_mesh: ?gpu.MeshBuffer,
};

const RetiredMeshEntry = struct {
    gpu_index: u32,
    mesh: gpu.MeshBuffer,
    graphics_timeline_value: u64,
    free_index: bool,
};

/// Scene-side effect of a completed upload, applied by publishPending inside the
/// frame's GPU-idle window. Recording is cheap so the drain task can defer every
/// candidate-buffer write until the cull cannot be reading it.
const Publication = union(enum) {
    /// Uploaded mesh to publish at the key.
    retire: struct {
        mesh: gpu.MeshBuffer,
        key: RenderBufferKey,
        chunk_pos: ChunkPos,
    },
    /// No mesh arrived for the key: drop whatever sits there.
    remove: RenderBufferKey,
    /// A retired mesh's candidate slot is safe to free now.
    free_index: u32,
};

const PushConstants = extern struct {
    projview: [16]f32,
    sun_dir: [3]f32,
    time: f32,
    mesh_base: u32,
};

const push_constants_size = @offsetOf(PushConstants, "mesh_base") + @sizeOf(u32);

comptime {
    if (push_constants_size != 84) @compileError("PushConstants effective size mismatch with GLSL layout (expected 84)");
}

const CullPushConstants = extern struct {
    planes: [6][4]f32,
    player_pos: [4]f32 align(16),
    total_candidates: u32,
    draw_capacity: u32,
    /// See the mode constants below; decoded by cull.comp.
    mode: u32,
    /// Minimum chunk AABB size in world blocks to cast a shadow (0 = off).
    min_chunk_size: f32,
};

comptime {
    // Kept at or below 128 bytes, the Vulkan minimum guaranteed push-constant size;
    // the occlusion camera lives in the Hi-Z params buffer instead.
    if (@sizeOf(CullPushConstants) != 128) @compileError("CullPushConstants size mismatch with GLSL layout");
}

/// Early main pass: frustum + visible-last-frame, opaque only.
const cull_mode_early: u32 = 0;
/// Late main pass: frustum + Hi-Z occlusion, updates visibility bits.
const cull_mode_late: u32 = 1;
/// Shadow cull for cascade slot k dispatches with mode = cull_mode_shadow_base + k.
const cull_mode_shadow_base: u32 = 2;

const cull_workgroup_size: u32 = 64;

const GraphicsState = struct {
    opaque_pipeline_layout: vk.PipelineLayout = .null_handle,
    transparent_pipeline_layout: vk.PipelineLayout = .null_handle,
    pipeline: vk.Pipeline = .null_handle,
    transparent_pipeline: vk.Pipeline = .null_handle,
};

const CullState = struct {
    pipeline_layout: vk.PipelineLayout = .null_handle,
    pipeline: vk.Pipeline = .null_handle,
    descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    descriptor_pool: vk.DescriptorPool = .null_handle,
    descriptor_sets_per_frame: []vk.DescriptorSet = &.{},
};

/// Per-frame data the composer gathers before chunk passes are recorded.
pub const PassContext = struct {
    cmd_buffer: vk.CommandBuffer,
    frame_idx: u32,
    extent: vk.Extent2D,
    view_pos: @Vector(3, f64),
    projview: @Vector(16, f32),
    frustum: Frustum,
    total_candidates: u32,
    elapsed_sec: f32,
    sun_dir: @Vector(3, f32),
    inside_transparent: bool,
    occlusion_culling: bool,
    swapchain_old_layout: vk.ImageLayout,
    swapchain_layout_ptr: ?*vk.ImageLayout,
    output_image: vk.Image,
    output_view: vk.ImageView,
    color_image: vk.Image,
    color_view: vk.ImageView,
    depth_image: vk.Image,
    depth_view: vk.ImageView,
    depth_sampled_view: vk.ImageView,
    depth_aspect_mask: vk.ImageAspectFlags,
    frame_sequence: u64,
    /// Shared shadow state; null until VulkanRenderer wires it in.
    shadow: ?*ShadowRenderer,
};

/// Renders the voxel chunk scene: opaque + weighted-blended transparent passes driven
/// by the shared indirect scene, block materials, and block texture atlas.
pub const ChunkRenderer = @This();

vk_ctx: *VulkanContext,
allocator: std.mem.Allocator,
dev: DeviceProxy,
memory: *gpu.GpuMemory,
single_time: *core.SingleTime,
uploader: *gpu.MeshUploader,
scene: *gpu.IndirectScene,
oit: *OitCompositor,
render_options: *const Renderer.RenderOptions,
render_options_lock: *std.Io.RwLock,
shadow: *ShadowRenderer,
pyramid: *DepthPyramid,
/// GLSL-transposed view-projection and camera position the current pyramid was built
/// with; the cull tests with these (one frame stale) so boxes project onto the view
/// that rendered the depth.
last_cull_projview: [16]f32 = @splat(0),
last_cull_player_pos: [4]f32 = .{ 0, 0, 0, 1 },

texture_manager: textures.TextureManager,
block_materials: BlockMaterials,
graphics_state: GraphicsState = .{},
cull: CullState = .{},
last_cull_version: u32 = std.math.maxInt(u32),
meshes: ConcurrentHashMap(RenderBufferKey, gpu.MeshBuffer, std.hash_map.AutoContext(RenderBufferKey), 32),
pending_uploads_queue: std.Io.Queue(PendingMeshUpload) = undefined,
pending_uploads_queue_buffer: [pending_queue_size]PendingMeshUpload = undefined,
peeked_upload: ?PendingMeshUpload = null,
submission_batch: SubmissionBatch = .{},
retire_mutex: std.Io.Mutex = .init,
retired_meshes_mutex: std.Io.Mutex = .init,
retired_meshes: std.ArrayList(RetiredMeshEntry) = undefined,
pending_publications: std.ArrayList(Publication) = undefined,
/// Frame-thread-only scratch that receives the stolen publication list each publish.
publish_scratch: std.ArrayList(Publication) = undefined,
drain_is_running: std.atomic.Value(bool) = .init(false),
drain_future: ?std.Io.Future(@typeInfo(@TypeOf(drainOnce)).@"fn".return_type.?) = null,

pub fn init(
    self: *ChunkRenderer,
    io: std.Io,
    allocator: std.mem.Allocator,
    vk_ctx: *VulkanContext,
    memory: *gpu.GpuMemory,
    single_time: *core.SingleTime,
    uploader: *gpu.MeshUploader,
    scene: *gpu.IndirectScene,
    oit: *OitCompositor,
    shadow: *ShadowRenderer,
    pyramid: *DepthPyramid,
    render_options: *const Renderer.RenderOptions,
    render_options_lock: *std.Io.RwLock,
) !void {
    self.* = .{
        .vk_ctx = vk_ctx,
        .allocator = allocator,
        .dev = vk_ctx.dev,
        .memory = memory,
        .single_time = single_time,
        .uploader = uploader,
        .scene = scene,
        .oit = oit,
        .shadow = shadow,
        .pyramid = pyramid,
        .render_options = render_options,
        .render_options_lock = render_options_lock,
        .meshes = .init,
        .texture_manager = undefined,
        .block_materials = undefined,
    };
    self.retired_meshes = .empty;
    self.pending_publications = .empty;
    self.publish_scratch = .empty;

    self.pending_uploads_queue = std.Io.Queue(PendingMeshUpload).init(&self.pending_uploads_queue_buffer);
    self.peeked_upload = null;

    self.uploader.setFlush(self, &flushUploads);

    self.render_options_lock.lockSharedUncancelable(io);
    const gamma_correction = self.render_options.gamma_correction;
    const selected_pack = self.render_options.selected_pack;
    self.render_options_lock.unlockShared(io);

    self.texture_manager = textures.TextureManager.init(.{
        .dev = vk_ctx.dev,
        .vk_ctx = vk_ctx,
        .memory = memory,
        .single_time = single_time,
    }, gamma_correction);
    try self.texture_manager.loadTextures(io, allocator, selected_pack);
    errdefer self.texture_manager.deinit();

    self.block_materials = .{ .dev = vk_ctx.dev, .vk_ctx = vk_ctx, .memory = memory };
    try self.block_materials.load(io, allocator, selected_pack);
    errdefer self.block_materials.deinit();

    try self.createCullResources();
}

pub fn deinit(self: *ChunkRenderer, io: std.Io) void {
    // Stop the background drain before touching any state it shares with the queues.
    if (self.drain_future) |*future| {
        future.cancel(io) catch {};
        _ = future.await(io) catch {};
        self.drain_future = null;
    }
    if (self.peeked_upload) |pending| self.destroyPendingUpload(io, pending);
    while (true) {
        var buf: PendingMeshUpload = undefined;
        const got = self.pending_uploads_queue.getUncancelable(io, (&buf)[0..1], 0) catch unreachable;
        if (got == 0) break;
        self.destroyPendingUpload(io, buf);
    }
    for (self.retired_meshes.items) |entry| self.uploader.freeMesh(io, entry.mesh, 0);
    self.retired_meshes.deinit(self.allocator);
    for (self.pending_publications.items) |publication| switch (publication) {
        .retire => |r| self.uploader.freeMesh(io, r.mesh, 0),
        .remove => {},
        .free_index => {},
    };
    self.pending_publications.deinit(self.allocator);
    self.publish_scratch.deinit(self.allocator);

    var it = self.meshes.iterator();
    defer it.deinit(io);
    while (it.next(io) catch unreachable) |entry| self.uploader.freeMesh(io, entry.value_ptr.*, 0);
    self.meshes.deinit(io, self.allocator);

    core.destroyIfValid(self.dev, &self.graphics_state.pipeline, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.graphics_state.transparent_pipeline, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.graphics_state.opaque_pipeline_layout, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.graphics_state.transparent_pipeline_layout, &self.vk_ctx.vkalloc);

    core.destroyIfValid(self.dev, &self.cull.pipeline, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.cull.pipeline_layout, &self.vk_ctx.vkalloc);
    self.destroyCullDescriptorResources();
    core.destroyIfValid(self.dev, &self.cull.descriptor_set_layout, &self.vk_ctx.vkalloc);

    self.block_materials.deinit();
    self.texture_manager.deinit();
}

fn flushUploads(ctx: *anyopaque, io: std.Io) !void {
    const self: *ChunkRenderer = @ptrCast(@alignCast(ctx));
    try self.processPendingUploads(io);
}

pub fn addChunk(self: *ChunkRenderer, io: std.Io, chunk_pos: ChunkPos, encoding: Chunk.Encoding, neighbor_faces: *const [6]Chunk.Encoding.Face) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "addChunk" });
    defer zone.end();

    var buffer: [mesh_scratch_bytes]u8 = undefined;
    var bfa: BFA = .init(&buffer, self.allocator);
    var opaque_faces: std.ArrayList(Mesher.Face) = .empty;
    defer opaque_faces.deinit(bfa.allocator());
    var transparent_faces: std.ArrayList(Mesher.Face) = .empty;
    defer transparent_faces.deinit(bfa.allocator());
    {
        const zone_mesh = tracy.Zone.begin(.{ .src = @src(), .name = "mesh" });
        defer zone_mesh.end();
        try Mesher.mesh(bfa.allocator(), encoding, neighbor_faces, &opaque_faces, &transparent_faces);
    }

    try self.addMesh(io, chunk_pos, opaque_faces.items, transparent_faces.items);
}

pub fn removeChunk(self: *ChunkRenderer, io: std.Io, chunk_pos: ChunkPos) !void {
    try self.addMesh(io, chunk_pos, &.{}, &.{});
}

/// Returns true when an opaque or transparent mesh currently exists at the position.
pub fn hasMesh(self: *ChunkRenderer, io: std.Io, chunk_pos: ChunkPos) bool {
    return self.meshes.get(io, .{ .@"opaque" = chunk_pos }) != null or
        self.meshes.get(io, .{ .transparent = chunk_pos }) != null;
}

pub fn addMesh(self: *ChunkRenderer, io: std.Io, chunk_pos: ChunkPos, opaque_mesh: []const Mesher.Face, transparent_mesh: []const Mesher.Face) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "addMesh" });
    defer zone.end();

    // Nothing to upload: skip command resource acquisition entirely. The clear
    // still flows through the pending queue so it stays ordered after any
    // earlier upload of this position; timeline_value 0 retires without
    // waiting on a transfer because it owns no GPU resources.
    if (opaque_mesh.len == 0 and transparent_mesh.len == 0) {
        try self.pushPendingUpload(io, .{
            .chunk_pos = chunk_pos,
            .timeline_value = 0,
            .pool = .null_handle,
            .opaque_mesh = null,
            .transparent_mesh = null,
        });
        return;
    }

    // Acquire every bounded resource up front, all or nothing: past this point the
    // upload never blocks on acquisition, so whatever it holds is on a bounded path
    // to submission and the uploader's backpressure loops can always make progress.
    const reservation = blk: {
        const zone_reserve = tracy.Zone.begin(.{ .src = @src(), .name = "reserve_upload" });
        defer zone_reserve.end();
        break :blk try self.uploader.reserveUpload(io, .{
            @intCast(opaque_mesh.len * @sizeOf(Mesher.Face)),
            @intCast(transparent_mesh.len * @sizeOf(Mesher.Face)),
        });
    };
    // Until the reservation is handed to the submission batch, this call owns the pool,
    // both staging slices and both face regions. Leaking them on an error path strands
    // an unbound staging entry, which wedges the FIFO ring permanently.
    errdefer self.uploader.cancelReservation(io, reservation);

    const pool = reservation.borrowed.pool;
    const cmd = reservation.borrowed.cmd;

    try self.dev.resetCommandPool(pool, .{});

    try self.dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true }, .p_inheritance_info = null });

    var opaque_res: ?gpu.UploadResult = null;
    var transparent_res: ?gpu.UploadResult = null;
    if (opaque_mesh.len > 0) opaque_res = self.recordMeshUpload(opaque_mesh, cmd, reservation.staging[0].?, reservation.regions[0].?);
    if (transparent_mesh.len > 0) transparent_res = self.recordMeshUpload(transparent_mesh, cmd, reservation.staging[1].?, reservation.regions[1].?);

    try self.dev.endCommandBuffer(cmd);

    while (true) {
        const zone_batch = tracy.Zone.begin(.{ .src = @src(), .name = "addMesh_lock_batch" });
        self.submission_batch.mutex.lockUncancelable(io);
        zone_batch.end();
        if (self.submission_batch.count < batch_size) break;
        self.submission_batch.mutex.unlock(io);
        // The batch is full: flush it outside the lock. Submit and queue pushes can
        // block on the GPU, which must not stall other addMesh calls.
        try self.submitBatch(io);
    }
    defer self.submission_batch.mutex.unlock(io);

    const count = self.submission_batch.count;
    self.submission_batch.cmds[count] = cmd;
    self.submission_batch.pools[count] = pool;
    self.submission_batch.opaque_meshes[count] = opaque_res;
    self.submission_batch.transparent_meshes[count] = transparent_res;
    self.submission_batch.chunk_positions[count] = chunk_pos;
    if (opaque_res) |upload| self.submission_batch.max_safe_graphics = @max(self.submission_batch.max_safe_graphics, upload.safe_graphics);
    if (transparent_res) |upload| self.submission_batch.max_safe_graphics = @max(self.submission_batch.max_safe_graphics, upload.safe_graphics);
    self.submission_batch.count += 1;
}

/// Fills the pre-reserved staging slice and records the copy into the pre-reserved
/// face region. Performs no resource acquisition and cannot block.
fn recordMeshUpload(self: *ChunkRenderer, faces: []const Mesher.Face, cmd: vk.CommandBuffer, staging_slice: []u8, face_alloc: gpu.GpuRegionAllocator.AllocResult) gpu.UploadResult {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordMeshUpload" });
    defer zone.end();

    const buffer_size: vk.DeviceSize = @intCast(faces.len * @sizeOf(Mesher.Face));

    const indexer = std.enums.EnumIndexer(World.Block);
    for (faces, std.mem.bytesAsSlice(Mesher.Face, staging_slice)[0..faces.len]) |face, *dest| {
        dest.* = face;
        dest.block_type = @intCast(indexer.indexOf(@enumFromInt(face.block_type)));
    }

    const staging_info = self.memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, staging_slice.ptr);

    const face_byte_offset = face_alloc.offset;
    const face_buf = face_alloc.buffer;
    const face_buf_offset = face_alloc.buffer_offset;

    // Hazard barrier on the transfer queue: prior transfer writes to this region (which may
    // have been reused) must finish before the copy overwrites it. No ownership transfer:
    // the buffer is concurrent-shared, so both family indices stay QUEUE_FAMILY_IGNORED.
    core.pipelineBarrier(cmd, self.dev, vk.BufferMemoryBarrier2, (&core.makeBufferBarrier2(face_buf, face_buf_offset + face_byte_offset, buffer_size, .{ .all_transfer_bit = true }, .{ .transfer_write_bit = true }, .{ .all_transfer_bit = true }, .{ .transfer_write_bit = true }))[0..1]);

    self.dev.cmdCopyBuffer2(cmd, &.{
        .src_buffer = staging_info.buffer,
        .dst_buffer = face_buf,
        .region_count = 1,
        .p_regions = (&vk.BufferCopy2{
            .src_offset = staging_info.offset,
            .dst_offset = face_buf_offset + face_byte_offset,
            .size = buffer_size,
        })[0..1],
    });

    // Release: make the copy's writes available to the graphics queue, which acquires
    // them in cmdAcquireFaceBuffer after the transfer semaphore signals.
    core.pipelineBarrier(cmd, self.dev, vk.BufferMemoryBarrier2, (&core.makeBufferBarrier2(face_buf, face_buf_offset + face_byte_offset, buffer_size, .{ .all_transfer_bit = true }, .{ .transfer_write_bit = true }, .{ .all_transfer_bit = true }, .{}))[0..1]);

    return .{
        .mesh = .{
            .face_offset = @intCast(face_byte_offset / @sizeOf(Mesher.Face)),
            .face_byte_count = buffer_size,
            .face_count = @intCast(faces.len),
            .gpu_index = 0,
        },
        .staging_slice = staging_slice,
        .safe_graphics = face_alloc.safe_graphics,
    };
}

fn submitBatch(self: *ChunkRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "submitBatch" });
    defer zone.end();

    // Swap the batch out under the lock; submit and queue pushes happen outside it
    // because they can block on the GPU and must not hold up other addMesh calls.
    const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "submitBatch_lock" });
    self.submission_batch.mutex.lockUncancelable(io);
    if (self.submission_batch.count == 0) {
        self.submission_batch.mutex.unlock(io);
        zone_lock.end();
        return;
    }
    var batch_copy: SubmissionBatch = self.submission_batch;
    self.submission_batch.count = 0;
    self.submission_batch.max_safe_graphics = 0;
    self.submission_batch.mutex.unlock(io);
    zone_lock.end();
    const count = batch_copy.count;
    const wait_graphics = batch_copy.max_safe_graphics;

    const next_val = self.uploader.submitToTransferQueue(io, batch_copy.cmds[0..count], wait_graphics) catch |err| {
        // Nothing was submitted, so staging, regions, and pools can be released safely.
        for (batch_copy.opaque_meshes[0..count], batch_copy.transparent_meshes[0..count]) |opaque_mesh, transparent_mesh| {
            if (opaque_mesh) |upload| self.cancelUpload(io, upload);
            if (transparent_mesh) |upload| self.cancelUpload(io, upload);
        }
        for (batch_copy.pools[0..count]) |pool| self.uploader.returnPool(pool);
        return err;
    };

    // Bind every slice before pushing any item: a push that fails partway through
    // the batch must not leave unbound staging entries behind, or retire stops at
    // the first entry without a timeline value and the ring wedges permanently.
    for (batch_copy.opaque_meshes[0..count], batch_copy.transparent_meshes[0..count]) |opaque_mesh, transparent_mesh| {
        if (opaque_mesh) |upload| self.uploader.bindStaging(io, upload.staging_slice, next_val);
        if (transparent_mesh) |upload| self.uploader.bindStaging(io, upload.staging_slice, next_val);
    }

    for (batch_copy.opaque_meshes[0..count], batch_copy.transparent_meshes[0..count], batch_copy.chunk_positions[0..count], batch_copy.pools[0..count]) |opaque_mesh, transparent_mesh, chunk_pos, pool| {
        try self.pushPendingUpload(io, .{
            .chunk_pos = chunk_pos,
            .timeline_value = next_val,
            .pool = pool,
            .opaque_mesh = if (opaque_mesh) |upload| upload.mesh else null,
            .transparent_mesh = if (transparent_mesh) |upload| upload.mesh else null,
        });
    }
}

fn pushPendingUpload(self: *ChunkRenderer, io: std.Io, pending: PendingMeshUpload) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "pushPendingUpload" });
    defer zone.end();

    while (true) {
        if (try self.pending_uploads_queue.put(io, &.{pending}, 0) == 1) return;
        // The queue is full. A retire pass either frees a slot (something retired)
        // or holds the front item out as the peek; in both cases the next put
        // succeeds against the freed slot.
        try self.retireCompletedUploads(io);
        if (self.peeked_upload) |front| {
            // The front item's batch is the oldest pending transfer, so waiting on
            // its timeline value is satisfied by already-submitted work; the next
            // retire pass then consumes it and frees its slot. The wait is bounded
            // in normal operation; a timeout means the GPU is stalled and must be
            // reported instead of hanging silently.
            const result = try self.dev.waitSemaphores(&.{
                .semaphore_count = 1,
                .p_semaphores = (&self.uploader.transfer.semaphore)[0..1],
                .p_values = (&front.timeline_value)[0..1],
            }, gpu.transfer_wait_timeout_ns);
            if (result != .success) std.log.warn("ChunkRenderer: pending upload queue stalled waiting for transfer value {d}; GPU may be stuck", .{front.timeline_value});
        }
    }
}

/// Returns a failed pending upload to the tail of the queue so later retire passes
/// retry it while the rest of the queue keeps draining. Cannot block: the item's
/// pool is still held (it is returned only on a successful retire), so the queue
/// can hold at most 511 other items and one slot is always free.
fn requeuePendingUpload(self: *ChunkRenderer, io: std.Io, pending: PendingMeshUpload) void {
    _ = self.pending_uploads_queue.putUncancelable(io, (&pending)[0..1], 1) catch unreachable;
}

fn destroyMeshBuffer(self: *ChunkRenderer, io: std.Io, mesh: gpu.MeshBuffer) void {
    self.uploader.freeMesh(io, mesh, self.vk_ctx.frame_number.load(.acquire));
}

fn cancelUpload(self: *ChunkRenderer, io: std.Io, result: gpu.UploadResult) void {
    self.uploader.cancelStaging(io, result.staging_slice);
    self.uploader.freeMesh(io, result.mesh, self.vk_ctx.frame_number.load(.acquire));
}

fn destroyPendingUpload(self: *ChunkRenderer, io: std.Io, pending: PendingMeshUpload) void {
    if (pending.opaque_mesh) |opaque_m| self.destroyMeshBuffer(io, opaque_m);
    if (pending.transparent_mesh) |transparent| self.destroyMeshBuffer(io, transparent);
    if (pending.pool != .null_handle) self.uploader.returnPool(pending.pool);
}

fn enqueueRetiredMesh(self: *ChunkRenderer, io: std.Io, gpu_index: u32, mesh: gpu.MeshBuffer, free_index: bool) !void {
    const retire_frame = self.vk_ctx.frame_number.load(.acquire);
    // The frame publishes while the drain task frees due entries, so the list needs
    // its own lock: publishPending never holds retire_mutex across an apply.
    self.retired_meshes_mutex.lockUncancelable(io);
    defer self.retired_meshes_mutex.unlock(io);
    try self.retired_meshes.append(self.allocator, .{
        .gpu_index = gpu_index,
        .mesh = mesh,
        .graphics_timeline_value = retire_frame + VulkanContext.max_frames_in_flight,
        .free_index = free_index,
    });
}

/// Records one half of a completed upload for publishPending. Callers reserve before
/// appending; on failure the whole item is requeued because its pool is still held.
fn recordHalf(self: *ChunkRenderer, pending: PendingMeshUpload, key: RenderBufferKey, mesh: ?gpu.MeshBuffer) void {
    if (mesh) |uploaded_mesh| {
        self.pending_publications.appendAssumeCapacity(.{ .retire = .{
            .mesh = uploaded_mesh,
            .key = key,
            .chunk_pos = pending.chunk_pos,
        } });
    } else {
        self.pending_publications.appendAssumeCapacity(.{ .remove = key });
    }
}

fn applyRemoveUpload(self: *ChunkRenderer, io: std.Io, key: RenderBufferKey) !void {
    const existing = self.meshes.fetchRemove(io, key);
    if (existing) |old_mesh| {
        self.scene.markInactive(old_mesh.gpu_index);
        try self.enqueueRetiredMesh(io, old_mesh.gpu_index, old_mesh, true);
    }
}

fn applyRetireUpload(self: *ChunkRenderer, io: std.Io, new_mesh_in: gpu.MeshBuffer, key: RenderBufferKey, chunk_pos: ChunkPos) !void {
    var new_mesh = new_mesh_in;

    const ratio = ChunkPos.levelToBlockRatioFloat(chunk_pos.level);
    const mesh_blockpos = @as(@Vector(3, f64), @floatFromInt(chunk_pos.position)) * @as(@Vector(3, f64), @splat(ratio));
    const abs_vec: [4]f32 = .{ @floatCast(mesh_blockpos[0]), @floatCast(mesh_blockpos[1]), @floatCast(mesh_blockpos[2]), 1.0 };
    const is_transparent = key == .transparent;
    const transform: gpu.CandidateTransform = .{
        .absolute_position = abs_vec,
        .scale = ChunkPos.toScale(chunk_pos.level),
    };

    const existing = self.meshes.get(io, key);
    if (existing) |old_mesh| {
        // A previous attempt may have fully retired this upload before failing on the
        // other half; re-processing it would free a region the live mesh still reads.
        if (old_mesh.face_offset == new_mesh.face_offset and
            old_mesh.face_count == new_mesh.face_count and
            old_mesh.face_byte_count == new_mesh.face_byte_count)
        {
            return;
        }
        new_mesh.gpu_index = old_mesh.gpu_index;
        self.scene.writeCandidate(old_mesh.gpu_index, new_mesh, is_transparent, transform);
        const removed = try self.meshes.fetchPut(io, self.allocator, key, new_mesh);
        if (removed) |old| try self.enqueueRetiredMesh(io, old.gpu_index, old, false);
    } else {
        const gpu_idx = try self.scene.allocIndex(io);
        new_mesh.gpu_index = gpu_idx;
        self.scene.writeCandidate(gpu_idx, new_mesh, is_transparent, transform);
        self.scene.updateMaxAllocatedIndex(gpu_idx);

        const removed = self.meshes.fetchPut(io, self.allocator, key, new_mesh) catch |err| {
            // Roll back so a retry of this publish starts from a clean slate:
            // without this the slot would keep drawing an unregistered mesh and the
            // index would be permanently consumed.
            self.scene.releaseCandidate(io, gpu_idx);
            return err;
        };
        if (removed) |old| {
            self.scene.markInactive(old.gpu_index);
            try self.enqueueRetiredMesh(io, old.gpu_index, old, true);
        }
    }
}

fn retireCompletedUploads(self: *ChunkRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "retireCompletedUploads" });
    defer zone.end();

    self.retire_mutex.lockUncancelable(io);
    defer self.retire_mutex.unlock(io);

    const current_transfer_val = try self.dev.getSemaphoreCounterValue(self.uploader.transfer.semaphore);
    self.uploader.retireStaging(io, current_transfer_val);

    while (true) {
        const pending = if (self.peeked_upload) |pending_upload| pending_upload else blk: {
            var pending_buffer: PendingMeshUpload = undefined;
            const got = try self.pending_uploads_queue.get(io, (&pending_buffer)[0..1], 0);
            if (got == 0) return;
            break :blk pending_buffer;
        };

        if (current_transfer_val >= pending.timeline_value) {
            // Two records per item; reserve first so the appends cannot fail, and a
            // failed reserve requeues the untouched item for the next pass.
            self.pending_publications.ensureUnusedCapacity(self.allocator, 2) catch |err| {
                self.requeuePendingUpload(io, pending);
                self.peeked_upload = null;
                return err;
            };
            self.recordHalf(pending, .{ .@"opaque" = pending.chunk_pos }, pending.opaque_mesh);
            self.recordHalf(pending, .{ .transparent = pending.chunk_pos }, pending.transparent_mesh);

            if (pending.pool != .null_handle) self.uploader.returnPool(pending.pool);
            self.peeked_upload = null;
        } else {
            self.peeked_upload = pending;
            break;
        }
    }
}

/// Applies completed uploads in the frame's GPU-idle window; never waits on the drain.
/// A failed apply is refunded and retried next frame instead of failing the frame.
pub fn publishPending(self: *ChunkRenderer, io: std.Io) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "publishPending" });
    defer zone.end();

    // Swap the whole list out rather than stealing a slice: the drain task appends to
    // the same backing buffer, so a stolen slice would be clobbered mid-iteration.
    self.retire_mutex.lockUncancelable(io);
    std.mem.swap(std.ArrayList(Publication), &self.publish_scratch, &self.pending_publications);
    self.retire_mutex.unlock(io);
    var clear_scratch = true;
    defer if (clear_scratch) self.publish_scratch.clearRetainingCapacity();

    const pending = self.publish_scratch.items;
    for (pending, 0..) |publication, i| {
        self.applyPublication(io, publication) catch |err| {
            std.log.err("ChunkRenderer: publication failed (error {s}); retrying next frame", .{@errorName(err)});
            // Keep the unapplied tail in the scratch list. The next call swaps it
            // back into pending_publications without needing another allocation.
            @memmove(self.publish_scratch.items, self.publish_scratch.items[i..]);
            self.publish_scratch.items.len -= i;
            clear_scratch = false;
            return;
        };
    }
}

fn applyPublication(self: *ChunkRenderer, io: std.Io, publication: Publication) !void {
    switch (publication) {
        .retire => |r| try self.applyRetireUpload(io, r.mesh, r.key, r.chunk_pos),
        .remove => |key| try self.applyRemoveUpload(io, key),
        .free_index => |gpu_index| self.scene.releaseCandidate(io, gpu_index),
    }
}

/// Submits the pending upload batch and retires completed transfers. Called by the
/// drain task and by the uploader's flush backpressure; never runs on the frame path.
fn processPendingUploads(self: *ChunkRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "processPendingUploads" });
    defer zone.end();

    try self.submitBatch(io);
    try self.retireCompletedUploads(io);
}

pub fn flushPendingUploads(self: *ChunkRenderer, io: std.Io) !void {
    try self.submitBatch(io);
}

/// One full drain pass: flush the submission batch, retire completed uploads and
/// free retired GPU resources. Runs to completion on a background task without any
/// frame time budget; scene-side writes go through publishPending's idle window.
fn drainOnce(self: *ChunkRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "drainOnce" });
    defer zone.end();
    defer self.drain_is_running.store(false, .seq_cst);

    try self.processPendingUploads(io);
    try self.processRetired(io);
}

/// Mirrors the loader's restartFuture: when the previous pass finished, reap it and
/// dispatch the next one. The frame never waits on a pass that is still running.
pub fn restartDrain(self: *ChunkRenderer, io: std.Io) !void {
    if (self.drain_is_running.load(.seq_cst)) return;
    if (self.drain_future) |*future| try future.await(io);

    self.drain_is_running.store(true, .seq_cst);
    self.drain_future = io.concurrent(drainOnce, .{ self, io }) catch io.async(drainOnce, .{ self, io });
}

/// Retires GPU resources once the graphics timeline passes their recorded frame.
fn processRetired(self: *ChunkRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "processRetired" });
    defer zone.end();

    self.retire_mutex.lockUncancelable(io);
    defer self.retire_mutex.unlock(io);

    const current_graphics_val = try self.dev.getSemaphoreCounterValue(self.vk_ctx.graphics_timeline_semaphore);

    self.uploader.processRetiredFaceBuffers(io, current_graphics_val);
    self.scene.processRetired(current_graphics_val);

    const items = &self.retired_meshes;
    self.retired_meshes_mutex.lockUncancelable(io);
    defer self.retired_meshes_mutex.unlock(io);
    var i: usize = items.items.len;
    while (i > 0) {
        i -= 1;
        const entry = items.items[i];
        if (current_graphics_val >= entry.graphics_timeline_value) {
            if (entry.free_index) {
                // Freeing a candidate slot writes the candidate buffer, so it is routed
                // through publishPending's idle window like every other scene write.
                self.pending_publications.append(self.allocator, .{ .free_index = entry.gpu_index }) catch |err| {
                    std.log.warn("ChunkRenderer: deferring candidate slot free (error {s}); retrying next pass", .{@errorName(err)});
                    continue; // entry stays queued; retry on the next pass
                };
            }
            self.uploader.freeMesh(io, entry.mesh, current_graphics_val);
            _ = items.swapRemove(i);
        }
    }
}

pub fn forEachMesh(self: *ChunkRenderer, io: std.Io, callback_user_data: *anyopaque, callback: *const fn (*anyopaque, ChunkPos) error{Failed}!void) (std.Io.Cancelable || error{Failed})!void {
    var it = self.meshes.iterator();
    defer it.deinit(io);
    while (try it.next(io)) |entry| {
        const chunk_pos = entry.key_ptr.*.toPos();
        it.pause(io);
        try callback(callback_user_data, chunk_pos);
        try it.unpause(io);
    }
}

fn createCullResources(self: *ChunkRenderer) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "createCullResources" });
    defer zone.end();
    if (self.cull.descriptor_set_layout == .null_handle) {
        var bindings: [5]vk.DescriptorSetLayoutBinding = undefined;
        for (&bindings, 0..) |*b, i| b.* = .{ .binding = @intCast(i), .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null };
        self.cull.descriptor_set_layout = try core.createDescriptorSetLayout(self.dev, &self.vk_ctx.vkalloc, .{}, &bindings);
    }

    const pool_size = vk.DescriptorPoolSize{ .type = .storage_buffer, .descriptor_count = @intCast(VulkanContext.max_frames_in_flight * 5) };
    try core.createFrameDescriptorPool(self.dev, self.allocator, &self.vk_ctx.vkalloc, &self.cull.descriptor_pool, self.cull.descriptor_set_layout, &self.cull.descriptor_sets_per_frame, (&pool_size)[0..1]);
    errdefer self.destroyCullDescriptorResources();

    const pc_range: vk.PushConstantRange = .{
        .stage_flags = .{ .compute_bit = true },
        .offset = 0,
        .size = @sizeOf(CullPushConstants),
    };
    const set_layouts: [2]vk.DescriptorSetLayout = .{ self.cull.descriptor_set_layout, self.pyramid.occlusion_set_layout };
    self.cull.pipeline_layout = try self.dev.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = set_layouts.len,
        .p_set_layouts = &set_layouts,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = (&pc_range)[0..1],
    }, &self.vk_ctx.vkalloc);
    errdefer {
        self.dev.destroyPipelineLayout(self.cull.pipeline_layout, &self.vk_ctx.vkalloc);
        self.cull.pipeline_layout = .null_handle;
    }

    const comp_module = try core.createShaderModule(self.dev, &self.vk_ctx.vkalloc, cull_shader_spv);
    defer self.dev.destroyShaderModule(comp_module, &self.vk_ctx.vkalloc);

    const cpci: vk.ComputePipelineCreateInfo = .{
        .flags = .{},
        .stage = core.shaderStageCreateInfo(.{ .compute_bit = true }, comp_module),
        .layout = self.cull.pipeline_layout,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };
    if (self.dev.createComputePipelines(.null_handle, (&cpci)[0..1], &self.vk_ctx.vkalloc, (&self.cull.pipeline)[0..1])) |res| {
        if (res != .success) return error.PipelineCreationFailed;
    } else |err| return err;

    self.last_cull_version = std.math.maxInt(u32);
    self.updateCullDescriptorsIfNeeded();
}

fn destroyCullDescriptorResources(self: *ChunkRenderer) void {
    core.destroyFrameDescriptorResources(self.dev, self.allocator, &self.vk_ctx.vkalloc, &self.cull.descriptor_pool, &self.cull.descriptor_sets_per_frame);
}

fn updateCullDescriptorSet(self: *ChunkRenderer, frame_idx: u32) void {
    const scene = self.scene;
    const frame = &scene.frame_buffers.items[frame_idx];
    const infos: [5]vk.DescriptorBufferInfo = .{
        .{ .buffer = scene.persistent.buffer, .offset = scene.persistent.offset, .range = scene.persistent.slice.len * @sizeOf(gpu.MeshCandidate) },
        .{ .buffer = frame.indirect_draw, .offset = frame.indirect_draw_offset, .range = scene.draw_capacity * gpu.slot_count * @sizeOf(vk.DrawIndirectCommand) },
        .{ .buffer = frame.mesh_data, .offset = frame.mesh_data_offset, .range = scene.draw_capacity * gpu.slot_count * @sizeOf(gpu.MeshData) },
        .{ .buffer = frame.count, .offset = frame.count_offset, .range = @sizeOf(gpu.CullCount) },
        .{ .buffer = scene.visibility_buffer, .offset = scene.visibility_offset, .range = scene.visibility_slice.len * @sizeOf(u32) },
    };
    var writes: [5]vk.WriteDescriptorSet = undefined;
    for (&writes, &infos, 0..) |*write, *info, binding| write.* = core.bufferWriteDescriptorSet(self.cull.descriptor_sets_per_frame[frame_idx], @intCast(binding), .storage_buffer, info);
    self.dev.updateDescriptorSets(&writes, null);
}

/// Re-binds the cull descriptor sets whenever the indirect scene reallocated its buffers.
fn updateCullDescriptorsIfNeeded(self: *ChunkRenderer) void {
    const version = self.scene.buffers_version;
    if (version == self.last_cull_version) return;
    for (0..VulkanContext.max_frames_in_flight) |frame_index| self.updateCullDescriptorSet(@intCast(frame_index));
    self.last_cull_version = version;
}

fn dispatchCulling(self: *ChunkRenderer, cmd_buffer: vk.CommandBuffer, current_frame: u32, planes: [6]@Vector(4, f32), total_candidates: u32, view_pos: @Vector(3, f64), mode: u32, min_chunk_size: f32, reset_count: bool) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "dispatchCulling" });
    defer zone.end();
    const scene = self.scene;
    const frame = &scene.frame_buffers.items[current_frame];
    if (reset_count) {
        self.dev.cmdFillBuffer(cmd_buffer, frame.count, frame.count_offset, @sizeOf(gpu.CullCount), 0);
        const min_off = frame.count_offset + @as(vk.DeviceSize, @offsetOf(gpu.CullCount, "aabb_min_ord"));
        const max_off = frame.count_offset + @as(vk.DeviceSize, @offsetOf(gpu.CullCount, "aabb_max_ord"));
        self.dev.cmdFillBuffer(cmd_buffer, frame.count, min_off, @sizeOf([3]u32), gpu.aabb_min_inf_ord);
        self.dev.cmdFillBuffer(cmd_buffer, frame.count, max_off, @sizeOf([3]u32), gpu.aabb_max_inf_ord);
        core.pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, (&core.makeBufferBarrier2(frame.count, frame.count_offset, @sizeOf(gpu.CullCount), .{ .all_transfer_bit = true }, .{ .transfer_write_bit = true }, .{ .compute_shader_bit = true }, .{ .shader_read_bit = true, .shader_write_bit = true }))[0..1]);
    }

    self.dev.cmdBindPipeline(cmd_buffer, .compute, self.cull.pipeline);
    self.dev.cmdBindDescriptorSets(cmd_buffer, .compute, self.cull.pipeline_layout, 0, (&self.cull.descriptor_sets_per_frame[current_frame])[0..1], null);
    self.pyramid.pushOcclusionSet(cmd_buffer, self.cull.pipeline_layout, 1, current_frame);

    var push_consts: CullPushConstants = undefined;
    for (&push_consts.planes, planes) |*dst, plane| dst.* = plane;
    push_consts.player_pos = .{ @floatCast(view_pos[0]), @floatCast(view_pos[1]), @floatCast(view_pos[2]), 1.0 };
    push_consts.total_candidates = total_candidates;
    push_consts.draw_capacity = scene.draw_capacity;
    push_consts.mode = mode;
    push_consts.min_chunk_size = min_chunk_size;
    frame.last_cull_player_pos = view_pos;

    self.dev.cmdPushConstants(cmd_buffer, self.cull.pipeline_layout, .{ .compute_bit = true }, 0, @sizeOf(@TypeOf(push_consts)), &push_consts);

    const group_count = (total_candidates + (cull_workgroup_size - 1)) / cull_workgroup_size;
    self.dev.cmdDispatch(cmd_buffer, group_count, 1, 1);
}

/// Barriers over this frame's indirect-draw, mesh-data, and count buffers, the
/// shared trio every cull/pass transition protects.
fn frameBufferBarriers(self: *ChunkRenderer, current_frame: u32, src_stage: vk.PipelineStageFlags2, src_access: vk.AccessFlags2, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2) [3]vk.BufferMemoryBarrier2 {
    const scene = self.scene;
    const frame = &scene.frame_buffers.items[current_frame];
    return .{
        core.makeBufferBarrier2(frame.indirect_draw, frame.indirect_draw_offset, scene.draw_capacity * gpu.slot_count * @sizeOf(vk.DrawIndirectCommand), src_stage, src_access, dst_stage, dst_access),
        core.makeBufferBarrier2(frame.mesh_data, frame.mesh_data_offset, scene.draw_capacity * gpu.slot_count * @sizeOf(gpu.MeshData), src_stage, src_access, dst_stage, dst_access),
        core.makeBufferBarrier2(frame.count, frame.count_offset, @sizeOf(gpu.CullCount), src_stage, src_access, dst_stage, dst_access),
    };
}

/// Makes the previous frames' draw-side and transfer accesses of the shared cull
/// buffers visible again before this frame's cull dispatches rewrite them. Queue
/// submissions order execution but provide no memory dependency by themselves, so
/// without this the reset fill and cull writes race the prior stats copy (transfer
/// read of the count buffer) and the opaque passes' vertex reads of mesh data.
fn preCullFrameBarrier(self: *ChunkRenderer, cmd_buffer: vk.CommandBuffer, current_frame: u32) void {
    core.pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, &self.frameBufferBarriers(current_frame, .{ .draw_indirect_bit = true, .vertex_shader_bit = true, .all_transfer_bit = true }, .{ .indirect_command_read_bit = true, .shader_read_bit = true, .transfer_read_bit = true, .transfer_write_bit = true }, .{ .compute_shader_bit = true, .all_transfer_bit = true }, .{ .shader_read_bit = true, .shader_write_bit = true, .transfer_read_bit = true, .transfer_write_bit = true }));
}

/// Zero-fills the visibility buffer when it is fresh, or makes last frame's late-cull
/// visibility writes visible to this frame's cull dispatches. Scoped to the live
/// candidate count, not the whole (possibly oversized) buffer.
fn prepareVisibility(self: *ChunkRenderer, cmd_buffer: vk.CommandBuffer, total_candidates: u32) void {
    const scene = self.scene;
    const size: vk.DeviceSize = @as(vk.DeviceSize, total_candidates) * @sizeOf(u32);
    if (scene.visibility_needs_clear.swap(false, .acq_rel)) {
        self.dev.cmdFillBuffer(cmd_buffer, scene.visibility_buffer, scene.visibility_offset, size, 0);
        core.pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, (&core.makeBufferBarrier2(scene.visibility_buffer, scene.visibility_offset, size, .{ .all_transfer_bit = true }, .{ .transfer_write_bit = true }, .{ .compute_shader_bit = true }, .{ .shader_read_bit = true, .shader_write_bit = true }))[0..1]);
        return;
    }
    core.pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, (&core.makeBufferBarrier2(scene.visibility_buffer, scene.visibility_offset, size, .{ .compute_shader_bit = true }, .{ .shader_write_bit = true }, .{ .compute_shader_bit = true }, .{ .shader_read_bit = true, .shader_write_bit = true }))[0..1]);
}

/// Makes the early cull's outputs visible to the draws that consume them (early opaque
/// pass and the shadow raster at the frame tail).
fn cullDrawBarrier(self: *ChunkRenderer, cmd_buffer: vk.CommandBuffer, current_frame: u32) void {
    core.pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, &self.frameBufferBarriers(current_frame, .{ .compute_shader_bit = true }, .{ .shader_write_bit = true }, .{ .draw_indirect_bit = true, .vertex_shader_bit = true }, .{ .indirect_command_read_bit = true, .shader_read_bit = true }));
}

/// The late cull rewrites buffers the early passes just consumed and continues the
/// early cull's atomic counters, so it must wait for those reads and see those writes.
fn preLateCullBarrier(self: *ChunkRenderer, cmd_buffer: vk.CommandBuffer, current_frame: u32) void {
    const scene = self.scene;
    const barriers: [4]vk.BufferMemoryBarrier2 = self.frameBufferBarriers(current_frame, .{ .draw_indirect_bit = true, .vertex_shader_bit = true, .compute_shader_bit = true }, .{ .indirect_command_read_bit = true, .shader_read_bit = true, .shader_write_bit = true }, .{ .compute_shader_bit = true }, .{ .shader_read_bit = true, .shader_write_bit = true }) ++ [1]vk.BufferMemoryBarrier2{core.makeBufferBarrier2(scene.visibility_buffer, scene.visibility_offset, scene.visibility_slice.len * @sizeOf(u32), .{ .compute_shader_bit = true }, .{ .shader_read_bit = true }, .{ .compute_shader_bit = true }, .{ .shader_read_bit = true, .shader_write_bit = true })};
    core.pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, &barriers);
}

/// One barrier covering the late cull's outputs, then the count copy into the
/// host-visible stats buffer.
fn cullBarrierAndCopyStats(self: *ChunkRenderer, cmd_buffer: vk.CommandBuffer, current_frame: u32) void {
    const frame = &self.scene.frame_buffers.items[current_frame];
    // Wider masks than strictly needed per buffer; extra dependencies are free here.
    core.pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, &self.frameBufferBarriers(current_frame, .{ .compute_shader_bit = true }, .{ .shader_write_bit = true }, .{ .draw_indirect_bit = true, .all_transfer_bit = true }, .{ .indirect_command_read_bit = true, .transfer_read_bit = true }));

    self.dev.cmdCopyBuffer(cmd_buffer, frame.count, frame.stats, (&vk.BufferCopy{ .src_offset = frame.count_offset, .dst_offset = frame.stats_offset, .size = @sizeOf(gpu.CullCount) })[0..1]);

    // The copy's write must also be available to later submissions' transfer ops
    // (the next stats copy into this ring slot), not just the host read.
    core.pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, (&core.makeBufferBarrier2(frame.stats, frame.stats_offset, @sizeOf(gpu.CullCount), .{ .all_transfer_bit = true }, .{ .transfer_write_bit = true }, .{ .host_bit = true, .all_transfer_bit = true }, .{ .host_read_bit = true, .transfer_read_bit = true, .transfer_write_bit = true }))[0..1]);
}

pub fn createPipelines(self: *ChunkRenderer, depth_format: vk.Format) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "createGraphicsPipelines" });
    defer zone.end();

    if (self.graphics_state.opaque_pipeline_layout != .null_handle) {
        core.destroyIfValid(self.dev, &self.graphics_state.pipeline, &self.vk_ctx.vkalloc);
        core.destroyIfValid(self.dev, &self.graphics_state.transparent_pipeline, &self.vk_ctx.vkalloc);
        core.destroyIfValid(self.dev, &self.graphics_state.opaque_pipeline_layout, &self.vk_ctx.vkalloc);
        core.destroyIfValid(self.dev, &self.graphics_state.transparent_pipeline_layout, &self.vk_ctx.vkalloc);
    }

    const vert_module = try core.createShaderModule(self.dev, &self.vk_ctx.vkalloc, vertex_shader_spv);
    defer self.dev.destroyShaderModule(vert_module, &self.vk_ctx.vkalloc);

    try self.createOpaquePipeline(vert_module, depth_format);
    try self.createTransparentPipeline(vert_module, depth_format);
}

fn graphicsPushConstantRange() vk.PushConstantRange {
    return .{
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .offset = 0,
        .size = push_constants_size,
    };
}

fn createOpaquePipeline(self: *ChunkRenderer, vert_module: vk.ShaderModule, depth_format: vk.Format) !void {
    const set_layouts: [3]vk.DescriptorSetLayout = .{
        self.texture_manager.descriptor_set_layout,
        self.scene.mesh_data_descriptor_set_layout,
        self.shadow.shadow_set_layout,
    };
    const blend = vk.PipelineColorBlendAttachmentState{
        .blend_enable = .false,
        .src_color_blend_factor = .src_alpha,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .src_alpha,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };
    try self.buildChunkPipeline(vert_module, fragment_shader_spv, depth_format, &set_layouts, &.{self.vk_ctx.swapchain_format}, &.{blend}, core.depthStencilState(true, .greater, true), &self.graphics_state.opaque_pipeline_layout, &self.graphics_state.pipeline);
}

fn createTransparentPipeline(self: *ChunkRenderer, vert_module: vk.ShaderModule, depth_format: vk.Format) !void {
    const set_layouts: [4]vk.DescriptorSetLayout = .{
        self.texture_manager.descriptor_set_layout,
        self.scene.mesh_data_descriptor_set_layout,
        self.shadow.shadow_set_layout,
        self.block_materials.descriptor_set_layout,
    };
    const blend_attachments: [3]vk.PipelineColorBlendAttachmentState = .{
        .{ .blend_enable = .true, .src_color_blend_factor = .one, .dst_color_blend_factor = .one, .color_blend_op = .add, .src_alpha_blend_factor = .zero, .dst_alpha_blend_factor = .one_minus_src_alpha, .alpha_blend_op = .add, .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true } },
        .{ .blend_enable = .true, .src_color_blend_factor = .one, .dst_color_blend_factor = .one, .color_blend_op = .add, .src_alpha_blend_factor = .one, .dst_alpha_blend_factor = .one, .alpha_blend_op = .add, .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true } },
        .{ .blend_enable = .true, .src_color_blend_factor = .one, .dst_color_blend_factor = .one, .color_blend_op = .add, .src_alpha_blend_factor = .one, .dst_alpha_blend_factor = .one, .alpha_blend_op = .add, .color_write_mask = .{ .r_bit = true, .g_bit = false, .b_bit = false, .a_bit = false } },
    };
    const formats: [3]vk.Format = .{ .r16g16b16a16_sfloat, .r16g16b16a16_sfloat, .r16_sfloat };
    try self.buildChunkPipeline(vert_module, transparent_frag_spv, depth_format, &set_layouts, &formats, &blend_attachments, core.depthStencilState(true, .greater_or_equal, false), &self.graphics_state.transparent_pipeline_layout, &self.graphics_state.transparent_pipeline);
}

/// Builds a chunk pipeline layout (shared push constant range) and pipeline from the
/// given set layouts, color formats, blend attachments, and depth-stencil state.
fn buildChunkPipeline(
    self: *ChunkRenderer,
    vert_module: vk.ShaderModule,
    frag_spv: []const u32,
    depth_format: vk.Format,
    set_layouts: []const vk.DescriptorSetLayout,
    formats: []const vk.Format,
    blend: []const vk.PipelineColorBlendAttachmentState,
    depth_stencil: vk.PipelineDepthStencilStateCreateInfo,
    pipeline_layout: *vk.PipelineLayout,
    pipeline: *vk.Pipeline,
) !void {
    const pc_range = graphicsPushConstantRange();
    pipeline_layout.* = try self.dev.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = @intCast(set_layouts.len),
        .p_set_layouts = set_layouts.ptr,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = (&pc_range)[0..1],
    }, &self.vk_ctx.vkalloc);

    const frag_module = try core.createShaderModule(self.dev, &self.vk_ctx.vkalloc, frag_spv);
    defer self.dev.destroyShaderModule(frag_module, &self.vk_ctx.vkalloc);

    pipeline.* = try core.buildGraphicsPipeline(self.dev, &self.vk_ctx.vkalloc, self.vk_ctx.pipeline_creation_feedback, vert_module, frag_module, formats, depth_format, depth_stencil, blend, pipeline_layout.*, gpu.MeshUploader.faceVertexInputState());
}

pub fn recordPasses(self: *ChunkRenderer, ctx: *const PassContext) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordPasses" });
    defer zone.end();
    self.updateCullDescriptorsIfNeeded();
    self.uploader.cmdAcquireFaceBuffer(ctx.cmd_buffer);

    const projview_array: [16]f32 = @bitCast(ctx.projview);
    var pc: PushConstants = .{
        .projview = @splat(0),
        .sun_dir = ctx.sun_dir,
        .time = ctx.elapsed_sec,
        .mesh_base = 0,
    };
    for (&pc.projview, 0..) |*dst, i| {
        const row = i / 4;
        const col = i % 4;
        dst.* = projview_array[col * 4 + row];
    }
    // The cull tests against the pyramid built last frame, so it must project with the
    // matrix and camera that frame's depth was rendered with, not this frame's.
    self.pyramid.writeParams(ctx.frame_idx, self.last_cull_projview, self.last_cull_player_pos, ctx.occlusion_culling);
    self.last_cull_projview = pc.projview;
    self.last_cull_player_pos = .{ @floatCast(ctx.view_pos[0]), @floatCast(ctx.view_pos[1]), @floatCast(ctx.view_pos[2]), 1.0 };

    if (ctx.total_candidates > 0) {
        const gpu_zone = self.vk_ctx.gpu_profiler.beginZone(ctx.cmd_buffer, ctx.frame_idx, .{ .src = @src(), .name = "cull" });
        defer gpu_zone.end();
        self.dispatchFrameCulling(ctx);
    }
    {
        const gpu_zone = self.vk_ctx.gpu_profiler.beginZone(ctx.cmd_buffer, ctx.frame_idx, .{ .src = @src(), .name = "opaque_early" });
        defer gpu_zone.end();
        self.recordOpaquePass(ctx, pc, .early);
    }
    {
        const gpu_zone = self.vk_ctx.gpu_profiler.beginZone(ctx.cmd_buffer, ctx.frame_idx, .{ .src = @src(), .name = "hiz_late_cull" });
        defer gpu_zone.end();
        self.recordPyramidAndLateCull(ctx);
    }
    {
        const gpu_zone = self.vk_ctx.gpu_profiler.beginZone(ctx.cmd_buffer, ctx.frame_idx, .{ .src = @src(), .name = "opaque_late" });
        defer gpu_zone.end();
        self.recordOpaquePass(ctx, pc, .late);
    }
    // Depth is final now; transparent tests against it, samples it in the shader, and
    // the end-of-frame pyramid build reduces it for next frame's cull.
    self.depthToSampledBarrier(ctx, .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true, .fragment_shader_bit = true, .compute_shader_bit = true }, .{ .depth_stencil_attachment_read_bit = true, .shader_read_bit = true });
    {
        const gpu_zone = self.vk_ctx.gpu_profiler.beginZone(ctx.cmd_buffer, ctx.frame_idx, .{ .src = @src(), .name = "transparent" });
        defer gpu_zone.end();
        self.recordTransparentPass(ctx, pc);
    }

    // Build next frame's occlusion pyramid from this frame's completed opaque depth.
    // The late cull consumed the pyramid built last frame (double-buffered), so newly
    // built occluders cull previously visible meshes within one frame.
    {
        const gpu_zone = self.vk_ctx.gpu_profiler.beginZone(ctx.cmd_buffer, ctx.frame_idx, .{ .src = @src(), .name = "hiz_build" });
        defer gpu_zone.end();
        self.pyramid.recordBuild(ctx.cmd_buffer, ctx.depth_sampled_view);
    }

    self.oit.recordCompositionPass(.{
        .cmd_buffer = ctx.cmd_buffer,
        .extent = ctx.extent,
        .output_image = ctx.output_image,
        .output_view = ctx.output_view,
        .frame_idx = ctx.frame_idx,
        .scatter_enabled = @intFromBool(!ctx.inside_transparent),
        .scatter_light = OitCompositor.volumeScatterLight(ctx.sun_dir),
        .swapchain_old_layout = ctx.swapchain_old_layout,
        .swapchain_layout_ptr = ctx.swapchain_layout_ptr,
    }, ctx.color_image);

    // The shadow raster fills the tail of the frame where the GPU is draining and
    // overlaps with the next frame's cull/vertex work; its output is sampled next frame.
    // Gated on candidates: with none, no cull ran, so the count buffer was never zeroed.
    if (shadowActive(ctx)) |shadow| {
        const face_buf = self.uploader.region_allocator.buffer.load(.acquire);
        const face_buf_off: vk.DeviceSize = self.uploader.region_allocator.buffer_offset.load(.monotonic);
        shadow.recordShadowPass(ctx.cmd_buffer, ctx.frame_idx, face_buf, face_buf_off);
    }

    self.uploader.cmdReleaseFaceBuffer(ctx.cmd_buffer);
}

/// True when the shadow cull+raster should run this frame: a cascade is active and
/// there are candidates (the cull dispatch, which zeroes the count buffer, ran).
fn shadowActive(ctx: *const PassContext) ?*ShadowRenderer {
    if (ctx.total_candidates == 0) return null;
    const shadow = ctx.shadow orelse return null;
    if (!shadow.frameHasCascade()) return null;
    return shadow;
}

/// Pushes the shared set-2 push-descriptor set for the given pipeline: binding 0 is the
/// opaque depth sampler (NULL for the opaque pipeline, which never samples it), binding
/// 1 the shadow array + comparison sampler (NULL when shadows are disabled), binding 2
/// the per-frame ShadowParams buffer (always valid; cascade_count == 0 early-outs).
fn pushShadowSet2(self: *ChunkRenderer, cmd_buffer: vk.CommandBuffer, pipeline_layout: vk.PipelineLayout, frame_idx: u32, opaque_depth_info: ?*const vk.DescriptorImageInfo) void {
    const depth_info = if (opaque_depth_info) |info| info.* else self.shadow.nullImageInfo();
    const shadow_info = self.shadow.shadowImageInfo();
    const params_info = self.shadow.paramsBufferInfo(frame_idx);
    var writes: [3]vk.WriteDescriptorSet = undefined;
    writes[0] = core.imageWriteDescriptorSet(.null_handle, 0, &depth_info);
    writes[1] = core.imageWriteDescriptorSet(.null_handle, 1, &shadow_info);
    writes[2] = core.bufferWriteDescriptorSet(.null_handle, 2, .storage_buffer, &params_info);
    self.dev.cmdPushDescriptorSetKHR(cmd_buffer, .graphics, pipeline_layout, 2, &writes);
}

/// Culls the early main pass and every active shadow cascade into this frame's CullCount.
/// The reset-less cascade and late culls are safe only because the early cull just zeroed
/// the whole CullCount, and the shadow raster never draws a count that was not reset.
fn dispatchFrameCulling(self: *ChunkRenderer, ctx: *const PassContext) void {
    self.preCullFrameBarrier(ctx.cmd_buffer, ctx.frame_idx);
    self.prepareVisibility(ctx.cmd_buffer, ctx.total_candidates);
    self.dispatchCulling(ctx.cmd_buffer, ctx.frame_idx, ctx.frustum.planes, ctx.total_candidates, ctx.view_pos, cull_mode_early, 0.0, true);
    if (shadowActive(ctx)) |shadow| {
        for (0..shadow.frameCascadeCount()) |slot| {
            self.dispatchCulling(ctx.cmd_buffer, ctx.frame_idx, shadow.frameCascadePlanes(@intCast(slot)), ctx.total_candidates, ctx.view_pos, cull_mode_shadow_base + @as(u32, @intCast(slot)), shadow.frameMinChunkSize(), false);
        }
    }
    self.cullDrawBarrier(ctx.cmd_buffer, ctx.frame_idx);
}

/// Runs the late cull: re-tests every candidate against the previous frame's occlusion
/// pyramid, draws newly disoccluded opaque meshes and all visible transparent meshes,
/// and records the visibility bits the next frame's early cull reads.
fn recordPyramidAndLateCull(self: *ChunkRenderer, ctx: *const PassContext) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordPyramidAndLateCull" });
    defer zone.end();

    if (ctx.total_candidates == 0) return;
    self.preLateCullBarrier(ctx.cmd_buffer, ctx.frame_idx);
    self.dispatchCulling(ctx.cmd_buffer, ctx.frame_idx, ctx.frustum.planes, ctx.total_candidates, ctx.view_pos, cull_mode_late, 0.0, false);
    self.cullBarrierAndCopyStats(ctx.cmd_buffer, ctx.frame_idx);
}

/// Transitions depth from attachment to read-only, visible to the given consumers.
fn depthToSampledBarrier(self: *ChunkRenderer, ctx: *const PassContext, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2) void {
    core.pipelineBarrier(ctx.cmd_buffer, self.dev, vk.ImageMemoryBarrier2, (&core.makeImageBarrier2(
        ctx.depth_image,
        .depth_stencil_attachment_optimal,
        .depth_stencil_read_only_optimal,
        .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .{ .depth_stencil_attachment_write_bit = true },
        dst_stage,
        dst_access,
        ctx.depth_aspect_mask,
    ))[0..1]);
}

/// Binds the per-frame sets shared by every chunk pipeline: set 0 the bindless texture
/// array, set 1 the mesh-data storage buffer for `frame_idx`.
fn bindSharedDescriptorSets(self: *ChunkRenderer, cmd_buffer: vk.CommandBuffer, pipeline_layout: vk.PipelineLayout, frame_idx: u32) void {
    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, pipeline_layout, 0, (&self.texture_manager.descriptor_set)[0..1], null);
    const mesh_desc_set = self.scene.mesh_data_descriptor_sets_per_frame[frame_idx];
    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, pipeline_layout, 1, (&mesh_desc_set)[0..1], null);
}

const OpaquePhase = enum { early, late };

fn recordOpaquePass(self: *ChunkRenderer, ctx: *const PassContext, pc: PushConstants, phase: OpaquePhase) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordOpaquePass" });
    defer zone.end();

    const color_attachment = core.renderingAttachmentColor(ctx.color_view, .load, .{ 0.0, 0.0, 0.0, 1.0 });
    const depth_attachment = core.renderingAttachmentDepth(ctx.depth_view, .depth_stencil_attachment_optimal, .load);

    self.dev.cmdBeginRendering(ctx.cmd_buffer, &core.renderingInfo(ctx.extent, &.{color_attachment}, &depth_attachment));

    self.dev.cmdBindPipeline(ctx.cmd_buffer, .graphics, self.graphics_state.pipeline);

    core.setDynamicState(self.dev, ctx.cmd_buffer, .{ .back_bit = true }, .greater, true);

    core.setViewportAndScissor(self.dev, ctx.cmd_buffer, ctx.extent);

    self.bindSharedDescriptorSets(ctx.cmd_buffer, self.graphics_state.opaque_pipeline_layout, ctx.frame_idx);

    // Set 2: push-descriptor shared layout. Binding 0 is unused by the opaque shader,
    // so it is pushed as null (robustness2.null_descriptor makes that legal).
    self.pushShadowSet2(ctx.cmd_buffer, self.graphics_state.opaque_pipeline_layout, ctx.frame_idx, null);

    const slot: u32 = switch (phase) {
        .early => gpu.opaque_early_slot,
        .late => gpu.opaque_late_slot,
    };
    self.pushChunkConstants(ctx.cmd_buffer, self.graphics_state.opaque_pipeline_layout, pc, slot * self.scene.draw_capacity);

    if (ctx.total_candidates > 0) {
        const count_field: vk.DeviceSize = switch (phase) {
            .early => @offsetOf(gpu.CullCount, "opaque_count"),
            .late => @offsetOf(gpu.CullCount, "opaque_late_count"),
        };
        const frame = &self.scene.frame_buffers.items[ctx.frame_idx];
        self.drawChunkMeshes(ctx.cmd_buffer, ctx.frame_idx, frame.indirect_draw_offset + @as(vk.DeviceSize, slot * self.scene.draw_capacity) * @sizeOf(vk.DrawIndirectCommand), frame.count_offset + count_field);
    }

    self.dev.cmdEndRendering(ctx.cmd_buffer);
}

fn recordTransparentPass(self: *ChunkRenderer, ctx: *const PassContext, pc: PushConstants) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordTransparentPass" });
    defer zone.end();
    const oit_color_aspect: vk.ImageAspectFlags = .{ .color_bit = true };
    const oit_old_layout: vk.ImageLayout = if (ctx.frame_sequence > 0) .shader_read_only_optimal else .undefined;
    const oit_src_stage: vk.PipelineStageFlags2 = if (ctx.frame_sequence > 0) .{ .fragment_shader_bit = true } else .{ .top_of_pipe_bit = true };
    const oit_src_access: vk.AccessFlags2 = if (ctx.frame_sequence > 0) .{ .shader_read_bit = true } else .{};
    var oit_pre_barriers: [3]vk.ImageMemoryBarrier2 = undefined;
    const oit_images: [3]vk.Image = .{ self.oit.accum.image, self.oit.reveal.image, self.oit.volume_weight.image };
    for (oit_images, &oit_pre_barriers) |image, *barrier| {
        barrier.* = core.makeImageBarrier2(image, oit_old_layout, .color_attachment_optimal, oit_src_stage, oit_src_access, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, oit_color_aspect);
    }
    core.pipelineBarrier(ctx.cmd_buffer, self.dev, vk.ImageMemoryBarrier2, &oit_pre_barriers);

    const oit_accum_attachment = core.renderingAttachmentColor(self.oit.accum.view, .clear, .{ 0.0, 0.0, 0.0, 1.0 });
    const oit_reveal_attachment = core.renderingAttachmentColor(self.oit.reveal.view, .clear, .{ 0.0, 0.0, 0.0, 0.0 });
    const oit_volume_attachment = core.renderingAttachmentColor(self.oit.volume_weight.view, .clear, .{ 0.0, 0.0, 0.0, 0.0 });
    const oit_depth_attachment = core.renderingAttachmentDepth(ctx.depth_view, .depth_stencil_read_only_optimal, .load);
    self.dev.cmdBeginRendering(ctx.cmd_buffer, &core.renderingInfo(ctx.extent, &.{ oit_accum_attachment, oit_reveal_attachment, oit_volume_attachment }, &oit_depth_attachment));

    self.dev.cmdBindPipeline(ctx.cmd_buffer, .graphics, self.graphics_state.transparent_pipeline);

    core.setDynamicState(self.dev, ctx.cmd_buffer, .{}, .greater_or_equal, false);
    core.setViewportAndScissor(self.dev, ctx.cmd_buffer, ctx.extent);

    self.bindSharedDescriptorSets(ctx.cmd_buffer, self.graphics_state.transparent_pipeline_layout, ctx.frame_idx);

    const depth_image_info: vk.DescriptorImageInfo = .{
        .image_layout = .depth_stencil_read_only_optimal,
        .image_view = ctx.depth_sampled_view,
        .sampler = self.texture_manager.sampler,
    };
    self.pushShadowSet2(ctx.cmd_buffer, self.graphics_state.transparent_pipeline_layout, ctx.frame_idx, &depth_image_info);

    if (self.block_materials.descriptor_set != .null_handle) self.dev.cmdBindDescriptorSets(ctx.cmd_buffer, .graphics, self.graphics_state.transparent_pipeline_layout, 3, (&self.block_materials.descriptor_set)[0..1], null);

    self.pushChunkConstants(ctx.cmd_buffer, self.graphics_state.transparent_pipeline_layout, pc, gpu.transparent_slot * self.scene.draw_capacity);

    if (ctx.total_candidates > 0) {
        const frame = &self.scene.frame_buffers.items[ctx.frame_idx];
        self.drawChunkMeshes(ctx.cmd_buffer, ctx.frame_idx, frame.indirect_draw_offset + @as(vk.DeviceSize, gpu.transparent_slot * self.scene.draw_capacity) * @sizeOf(vk.DrawIndirectCommand), frame.count_offset + @as(vk.DeviceSize, @intCast(@offsetOf(gpu.CullCount, "transparent_count"))));
    }

    self.dev.cmdEndRendering(ctx.cmd_buffer);
}

/// Pushes the chunk push constants with the given mesh base offset.
fn pushChunkConstants(self: *ChunkRenderer, cmd_buffer: vk.CommandBuffer, pipeline_layout: vk.PipelineLayout, pc: PushConstants, mesh_base: u32) void {
    var pc_x = pc;
    pc_x.mesh_base = mesh_base;
    self.dev.cmdPushConstants(cmd_buffer, pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, push_constants_size, &pc_x);
}

/// Binds the face vertex buffer and issues the indirect count draw for the pass. The
/// face buffer is momentarily null while allocRegion grows it; the draw is skipped in
/// that rare window instead of binding a stale buffer.
fn drawChunkMeshes(self: *ChunkRenderer, cmd_buffer: vk.CommandBuffer, frame_idx: u32, draw_offset: vk.DeviceSize, count_offset: vk.DeviceSize) void {
    const face_buf = self.uploader.region_allocator.buffer.load(.acquire);
    if (face_buf == .null_handle) return;
    const face_buf_off: vk.DeviceSize = self.uploader.region_allocator.buffer_offset.load(.monotonic);
    self.dev.cmdBindVertexBuffers(cmd_buffer, 0, (&face_buf)[0..1], (&face_buf_off)[0..1]);

    const frame = &self.scene.frame_buffers.items[frame_idx];
    self.dev.cmdDrawIndirectCount(cmd_buffer, frame.indirect_draw, draw_offset, frame.count, count_offset, self.scene.draw_capacity, @sizeOf(vk.DrawIndirectCommand));
}

test "RenderBufferKey.toPos" {
    const pos_a: ChunkPos = .{ .level = 0, .position = .{ 1, 2, 3 } };
    const pos_b: ChunkPos = .{ .level = -3, .position = .{ -10, 20, 30 } };
    try std.testing.expectEqual(pos_a, (RenderBufferKey{ .@"opaque" = pos_a }).toPos());
    try std.testing.expectEqual(pos_b, (RenderBufferKey{ .transparent = pos_b }).toPos());
    const pos: ChunkPos = .{ .level = 5, .position = .{ -100, 200, -300 } };
    try std.testing.expectEqual(pos, (RenderBufferKey{ .@"opaque" = pos }).toPos());
}

test "pushPendingUpload queue semantics: put(min=0) never blocks" {
    // pushPendingUpload relies on put with min=0 returning 0 immediately when the
    // queue is full (never suspending), so a retire pass always gets a chance to
    // free the slot before the next attempt.
    const io = std.testing.io;
    var buf: [2]usize = undefined;
    var queue: std.Io.Queue(usize) = .init(&buf);

    var item: usize = 1;
    try std.testing.expectEqual(@as(usize, 1), try queue.put(io, (&item)[0..1], 0));
    var item2: usize = 2;
    try std.testing.expectEqual(@as(usize, 1), try queue.put(io, (&item2)[0..1], 0));

    var full_item: usize = 3;
    try std.testing.expectEqual(@as(usize, 0), try queue.put(io, (&full_item)[0..1], 0));

    var out: usize = undefined;
    try std.testing.expectEqual(@as(usize, 1), try queue.get(io, (&out)[0..1], 0));
    try std.testing.expectEqual(@as(usize, 1), try queue.put(io, (&full_item)[0..1], 0));
}
