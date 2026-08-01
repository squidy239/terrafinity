const std = @import("std");
const tracy = @import("tracy");
const vk = @import("vulkan");

const DeviceProxy = vk.DeviceProxy;

const ConcurrentHashMap = @import("../../../libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const Mesher = @import("../../Mesher.zig");
const BFA = @import("../../../world/BufferFirstAllocator.zig");
const Chunk = @import("../../../world/Chunk.zig");
const Renderer = @import("../../../Renderer.zig");
const VulkanContext = @import("../../../VulkanContext.zig").VulkanContext;
const World = @import("../../../world/World.zig");
const Frustum = @import("../Frustum.zig").Frustum;
const core = @import("../core.zig");
const gpu = @import("../gpu.zig");
const OitCompositor = @import("../OitCompositor.zig").OitCompositor;
const textures = @import("textures.zig");
const BlockMaterials = @import("BlockMaterials.zig").BlockMaterials;

const ChunkPos = World.ChunkPos;

const vertex_shader_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("vert_spv")));
const fragment_shader_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("frag_spv")));
const transparent_frag_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("trans_frag_spv")));
const cull_shader_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("cull_spv")));

const sky_height: f32 = 4096.0;

const RenderBufferKey = union(enum) {
    @"opaque": ChunkPos,
    transparent: ChunkPos,

    pub fn toPos(self: RenderBufferKey) ChunkPos {
        return switch (self) {
            inline .@"opaque", .transparent => |pos| pos,
        };
    }
};

const batch_size = 512;
const pending_queue_size = 512;

const SubmissionBatch = struct {
    cmds: [batch_size]vk.CommandBuffer = undefined,
    pools: [batch_size]vk.CommandPool = undefined,
    opaque_meshes: [batch_size]?gpu.UploadResult = undefined,
    transparent_meshes: [batch_size]?gpu.UploadResult = undefined,
    chunk_positions: [batch_size]ChunkPos = undefined,
    count: usize = 0,
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
    face_offset: vk.DeviceSize,
    face_length: vk.DeviceSize,
    graphics_timeline_value: u64,
    free_index: bool,
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
};

comptime {
    if (@sizeOf(CullPushConstants) != 128) @compileError("CullPushConstants size mismatch with GLSL layout");
}

const cull_workgroup_size: u32 = 64;

const GraphicsState = struct {
    opaque_pipeline_layout: vk.PipelineLayout = .null_handle,
    transparent_pipeline_layout: vk.PipelineLayout = .null_handle,
    pipeline: vk.Pipeline = .null_handle,
    transparent_pipeline: vk.Pipeline = .null_handle,
    transparent_depth_descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
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
    io: std.Io,
    cmd_buffer: vk.CommandBuffer,
    frame_idx: u32,
    extent: vk.Extent2D,
    view_pos: @Vector(3, f64),
    projview: @Vector(16, f32),
    frustum: Frustum,
    total_candidates: u32,
    elapsed_sec: f32,
    day_length_sec: f32,
    inside_transparent: bool,
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
num_in_flight: u32 = VulkanContext.max_frames_in_flight,

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
retired_meshes: std.ArrayList(RetiredMeshEntry) = undefined,

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
        .render_options = render_options,
        .render_options_lock = render_options_lock,
        .meshes = .init,
        .texture_manager = undefined,
        .block_materials = undefined,
    };
    self.retired_meshes = .empty;

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

    try self.createTransparentDepthDescriptorSetLayout();

    try self.createCullResources();
}

pub fn deinit(self: *ChunkRenderer, io: std.Io) void {
    if (self.peeked_upload) |pending| self.destroyPendingUpload(io, pending);
    while (true) {
        var buf: PendingMeshUpload = undefined;
        const got = self.pending_uploads_queue.getUncancelable(io, (&buf)[0..1], 0) catch unreachable;
        if (got == 0) break;
        self.destroyPendingUpload(io, buf);
    }
    for (self.retired_meshes.items) |entry| self.uploader.freeRegion(io, entry.face_offset, entry.face_length);
    self.retired_meshes.deinit(self.allocator);

    var it = self.meshes.iterator();
    defer it.deinit(io);
    while (it.next(io) catch unreachable) |entry| self.uploader.freeMesh(io, entry.value_ptr.*);
    self.meshes.deinit(io, self.allocator);

    core.destroyIfValid(self.dev, &self.graphics_state.pipeline, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.graphics_state.transparent_pipeline, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.graphics_state.opaque_pipeline_layout, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.graphics_state.transparent_pipeline_layout, &self.vk_ctx.vkalloc);
    core.destroyIfValid(self.dev, &self.graphics_state.transparent_depth_descriptor_set_layout, &self.vk_ctx.vkalloc);

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

    var buffer: [65536]u8 = undefined;
    var bfa: BFA = .init(&buffer, self.allocator);
    var opaque_faces: std.ArrayList(Mesher.Face) = .empty;
    defer opaque_faces.deinit(bfa.allocator());
    var transparent_faces: std.ArrayList(Mesher.Face) = .empty;
    defer transparent_faces.deinit(bfa.allocator());
    try Mesher.mesh(bfa.allocator(), encoding, neighbor_faces, &opaque_faces, &transparent_faces);

    try self.addMesh(io, chunk_pos, opaque_faces.items, transparent_faces.items);
}

pub fn removeChunk(self: *ChunkRenderer, io: std.Io, chunk_pos: ChunkPos) !void {
    try self.addMesh(io, chunk_pos, &.{}, &.{});
}

pub fn addMesh(self: *ChunkRenderer, io: std.Io, chunk_pos: ChunkPos, opaque_mesh: []const Mesher.Face, transparent_mesh: []const Mesher.Face) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "addMesh" });
    defer zone.end();

    const borrowed = try self.uploader.borrowPool(io);
    const pool = borrowed.pool;
    const cmd = borrowed.cmd;
    errdefer self.uploader.returnPool(pool);

    try self.dev.resetCommandPool(pool, .{});

    try self.dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true }, .p_inheritance_info = null });

    var opaque_res: ?gpu.UploadResult = null;
    var transparent_res: ?gpu.UploadResult = null;
    errdefer {
        if (opaque_res) |r| self.cancelUpload(io, r);
        if (transparent_res) |r| self.cancelUpload(io, r);
    }

    if (opaque_mesh.len > 0) opaque_res = try self.uploadMeshBuffer(io, opaque_mesh, cmd);
    if (transparent_mesh.len > 0) transparent_res = try self.uploadMeshBuffer(io, transparent_mesh, cmd);

    try self.dev.endCommandBuffer(cmd);

    {
        const zone_batch = tracy.Zone.begin(.{ .src = @src(), .name = "addMesh_lock_batch" });
        self.submission_batch.mutex.lockUncancelable(io);
        zone_batch.end();
        defer self.submission_batch.mutex.unlock(io);

        if (self.submission_batch.count == batch_size) try self.submitBatch(io);

        const count = self.submission_batch.count;
        self.submission_batch.cmds[count] = cmd;
        self.submission_batch.pools[count] = pool;
        self.submission_batch.opaque_meshes[count] = opaque_res;
        self.submission_batch.transparent_meshes[count] = transparent_res;
        self.submission_batch.chunk_positions[count] = chunk_pos;
        self.submission_batch.count += 1;
    }
}

fn uploadMeshBuffer(self: *ChunkRenderer, io: std.Io, faces: []const Mesher.Face, cmd: vk.CommandBuffer) !gpu.UploadResult {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "uploadMeshBuffer" });
    defer zone.end();

    const buffer_size: vk.DeviceSize = @intCast(faces.len * @sizeOf(Mesher.Face));

    const staging_slice = try self.uploader.allocStaging(io, buffer_size);
    errdefer self.uploader.cancelStaging(io, staging_slice);

    const indexer = std.enums.EnumIndexer(World.Block);
    for (faces, std.mem.bytesAsSlice(Mesher.Face, staging_slice)[0..faces.len]) |face, *dest| {
        dest.* = face;
        dest.block_type = @intCast(indexer.indexOf(@enumFromInt(face.block_type)));
    }

    const staging_info = self.memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, staging_slice.ptr);

    const face_alloc = try self.uploader.allocRegion(io, buffer_size);
    const face_byte_offset = face_alloc.offset;
    const face_buf = face_alloc.buffer;
    const face_buf_offset = face_alloc.buffer_offset;

    // Hazard barrier on the transfer queue: prior transfer writes to this region (which may
    // have been reused) must finish before the copy overwrites it. No ownership transfer:
    // the buffer is concurrent-shared, so both family indices stay QUEUE_FAMILY_IGNORED.
    core.pipelineBarrier(cmd, self.dev, vk.BufferMemoryBarrier2, (&core.makeBufferBarrier2(
        face_buf,
        face_buf_offset + face_byte_offset,
        buffer_size,
        .{ .all_transfer_bit = true },
        .{ .transfer_write_bit = true },
        .{ .all_transfer_bit = true },
        .{ .transfer_write_bit = true },
    ))[0..1]);

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
    core.pipelineBarrier(cmd, self.dev, vk.BufferMemoryBarrier2, (&core.makeBufferBarrier2(
        face_buf,
        face_buf_offset + face_byte_offset,
        buffer_size,
        .{ .all_transfer_bit = true },
        .{ .transfer_write_bit = true },
        .{ .all_transfer_bit = true },
        .{},
    ))[0..1]);

    return .{
        .mesh = .{
            .face_offset = @intCast(face_byte_offset / @sizeOf(Mesher.Face)),
            .face_byte_count = buffer_size,
            .face_count = @intCast(faces.len),
            .gpu_index = 0,
        },
        .staging_slice = staging_slice,
    };
}

fn submitBatch(self: *ChunkRenderer, io: std.Io) !void {
    const count = self.submission_batch.count;
    if (count == 0) return;
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "submitBatch" });
    defer zone.end();

    const next_val = try self.uploader.submitToTransferQueue(io, self.submission_batch.cmds[0..count]);

    self.submission_batch.count = 0;

    for (self.submission_batch.opaque_meshes[0..count], self.submission_batch.transparent_meshes[0..count], self.submission_batch.chunk_positions[0..count], self.submission_batch.pools[0..count]) |opaque_mesh, transparent_mesh, chunk_pos, pool| {
        if (opaque_mesh) |r| self.uploader.bindStaging(io, r.staging_slice, next_val);
        if (transparent_mesh) |r| self.uploader.bindStaging(io, r.staging_slice, next_val);
        try self.pushPendingUpload(io, .{
            .chunk_pos = chunk_pos,
            .timeline_value = next_val,
            .pool = pool,
            .opaque_mesh = if (opaque_mesh) |r| r.mesh else null,
            .transparent_mesh = if (transparent_mesh) |r| r.mesh else null,
        });
    }
}

fn pushPendingUpload(self: *ChunkRenderer, io: std.Io, pending: PendingMeshUpload) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "pushPendingUpload" });
    defer zone.end();

    while (true) {
        if (try self.pending_uploads_queue.put(io, &.{pending}, 0) == 1) return;
        try self.retireCompletedUploads(io);
        try std.Io.sleep(io, .fromNanoseconds(0), .awake);
    }
}

fn destroyMeshBuffer(self: *ChunkRenderer, io: std.Io, mesh: gpu.MeshBuffer) void {
    self.uploader.freeMesh(io, mesh);
}

fn cancelUpload(self: *ChunkRenderer, io: std.Io, result: gpu.UploadResult) void {
    self.uploader.cancelStaging(io, result.staging_slice);
    self.uploader.freeMesh(io, result.mesh);
}

fn destroyPendingUpload(self: *ChunkRenderer, io: std.Io, pending: PendingMeshUpload) void {
    if (pending.opaque_mesh) |opaque_m| self.destroyMeshBuffer(io, opaque_m);
    if (pending.transparent_mesh) |transparent| self.destroyMeshBuffer(io, transparent);
    if (pending.pool != .null_handle) self.uploader.returnPool(pending.pool);
}

fn enqueueRetiredMesh(self: *ChunkRenderer, gpu_index: u32, face_offset: u32, face_byte_count: vk.DeviceSize, free_index: bool) !void {
    const retire_frame = self.vk_ctx.frame_number.load(.acquire);
    try self.retired_meshes.append(self.allocator, .{
        .gpu_index = gpu_index,
        .face_offset = @as(vk.DeviceSize, @intCast(face_offset)) * gpu.face_stride,
        .face_length = face_byte_count,
        .graphics_timeline_value = retire_frame + self.num_in_flight,
        .free_index = free_index,
    });
}

fn retireOnePendingItem(self: *ChunkRenderer, io: std.Io, mesh: ?gpu.MeshBuffer, key: RenderBufferKey, chunk_pos: ChunkPos) !void {
    if (mesh) |m| {
        var new_mesh = m;

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
            if (removed) |old| try self.enqueueRetiredMesh(old.gpu_index, old.face_offset, old.face_byte_count, false);
        } else {
            const gpu_idx = try self.scene.allocIndex(io);
            new_mesh.gpu_index = gpu_idx;
            self.scene.writeCandidate(gpu_idx, new_mesh, is_transparent, transform);
            self.scene.updateMaxAllocatedIndex(gpu_idx);

            const removed = self.meshes.fetchPut(io, self.allocator, key, new_mesh) catch |err| {
                // Roll back so a retry of this pending item starts from a clean slate:
                // without this the slot would keep drawing an unregistered mesh and the
                // index would be permanently consumed.
                self.scene.releaseCandidate(io, gpu_idx);
                return err;
            };
            if (removed) |old| {
                self.scene.persistent.mapped[old.gpu_index].face_count = 0;
                try self.enqueueRetiredMesh(old.gpu_index, old.face_offset, old.face_byte_count, true);
            }
        }
    } else {
        const existing = self.meshes.fetchRemove(io, key);
        if (existing) |old_mesh| {
            self.scene.persistent.mapped[old_mesh.gpu_index].face_count = 0;
            try self.enqueueRetiredMesh(old_mesh.gpu_index, old_mesh.face_offset, old_mesh.face_byte_count, true);
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
        const pending = if (self.peeked_upload) |p| p else blk: {
            var buf: PendingMeshUpload = undefined;
            const got = try self.pending_uploads_queue.get(io, (&buf)[0..1], 0);
            if (got == 0) return;
            break :blk buf;
        };

        if (current_transfer_val >= pending.timeline_value) {
            try self.retireOnePendingItem(io, pending.opaque_mesh, .{ .@"opaque" = pending.chunk_pos }, pending.chunk_pos);
            try self.retireOnePendingItem(io, pending.transparent_mesh, .{ .transparent = pending.chunk_pos }, pending.chunk_pos);

            self.uploader.returnPool(pending.pool);
            self.peeked_upload = null;
        } else {
            self.peeked_upload = pending;
            break;
        }
    }
}

pub fn processPendingUploads(self: *ChunkRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "processPendingUploads" });
    defer zone.end();

    {
        const zone_mutex = tracy.Zone.begin(.{ .src = @src(), .name = "processPendingUploads_lock" });
        self.submission_batch.mutex.lockUncancelable(io);
        zone_mutex.end();
        defer self.submission_batch.mutex.unlock(io);
        try self.submitBatch(io);
    }
    try self.retireCompletedUploads(io);
}

pub fn flushPendingUploads(self: *ChunkRenderer, io: std.Io) !void {
    self.submission_batch.mutex.lockUncancelable(io);
    defer self.submission_batch.mutex.unlock(io);
    try self.submitBatch(io);
}

/// Retires GPU resources once the graphics timeline passes their recorded frame.
pub fn processRetired(self: *ChunkRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "processRetired" });
    defer zone.end();

    self.retire_mutex.lockUncancelable(io);
    defer self.retire_mutex.unlock(io);

    const current_graphics_val = try self.dev.getSemaphoreCounterValue(self.vk_ctx.graphics_timeline_semaphore);

    self.uploader.processRetiredFaceBuffers(current_graphics_val);
    self.scene.processRetired(current_graphics_val);

    const items = &self.retired_meshes;
    var i: usize = items.items.len;
    while (i > 0) {
        i -= 1;
        const entry = items.items[i];
        if (current_graphics_val >= entry.graphics_timeline_value) {
            if (entry.free_index) {
                self.scene.releaseCandidate(io, entry.gpu_index);
            }
            self.uploader.freeRegion(io, entry.face_offset, entry.face_length);
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

fn createTransparentDepthDescriptorSetLayout(self: *ChunkRenderer) !void {
    if (self.graphics_state.transparent_depth_descriptor_set_layout == .null_handle) {
        const binding = vk.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null };
        self.graphics_state.transparent_depth_descriptor_set_layout = try self.dev.createDescriptorSetLayout(&.{ .flags = .{ .push_descriptor_bit = true }, .binding_count = 1, .p_bindings = (&binding)[0..1] }, &self.vk_ctx.vkalloc);
    }
}

fn createCullResources(self: *ChunkRenderer) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "createCullResources" });
    defer zone.end();
    if (self.cull.descriptor_set_layout == .null_handle) {
        const bindings: [4]vk.DescriptorSetLayoutBinding = .{
            .{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 3, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
        };
        self.cull.descriptor_set_layout = try self.dev.createDescriptorSetLayout(&.{ .flags = .{}, .binding_count = bindings.len, .p_bindings = bindings[0..] }, &self.vk_ctx.vkalloc);
    }

    const pool_size = vk.DescriptorPoolSize{ .type = .storage_buffer, .descriptor_count = @intCast(VulkanContext.max_frames_in_flight * 4) };
    try core.createFrameDescriptorPool(self.dev, self.allocator, &self.vk_ctx.vkalloc, &self.cull.descriptor_pool, self.cull.descriptor_set_layout, &self.cull.descriptor_sets_per_frame, (&pool_size)[0..1]);
    errdefer self.destroyCullDescriptorResources();

    const pc_range: vk.PushConstantRange = .{
        .stage_flags = .{ .compute_bit = true },
        .offset = 0,
        .size = @sizeOf(CullPushConstants),
    };
    self.cull.pipeline_layout = try self.dev.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = (&self.cull.descriptor_set_layout)[0..1],
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
        .stage = .{
            .flags = .{},
            .stage = .{ .compute_bit = true },
            .module = comp_module,
            .p_name = "main",
            .p_specialization_info = null,
        },
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
    if (self.cull.descriptor_pool != .null_handle) {
        self.dev.destroyDescriptorPool(self.cull.descriptor_pool, &self.vk_ctx.vkalloc);
        self.cull.descriptor_pool = .null_handle;
    }
    if (self.cull.descriptor_sets_per_frame.len > 0) {
        self.allocator.free(self.cull.descriptor_sets_per_frame);
        self.cull.descriptor_sets_per_frame = &.{};
    }
}

fn updateCullDescriptorSet(self: *ChunkRenderer, frame_idx: u32) void {
    const scene = self.scene;
    const frame = &scene.frame_buffers.items[frame_idx];
    const infos: [4]vk.DescriptorBufferInfo = .{
        .{ .buffer = scene.persistent.buffer, .offset = scene.persistent.offset, .range = scene.persistent.slice.len * @sizeOf(gpu.MeshCandidate) },
        .{ .buffer = frame.indirect_draw, .offset = frame.indirect_draw_offset, .range = scene.draw_capacity * gpu.draw_type_count * @sizeOf(vk.DrawIndirectCommand) },
        .{ .buffer = frame.mesh_data, .offset = frame.mesh_data_offset, .range = scene.draw_capacity * gpu.draw_type_count * @sizeOf(gpu.MeshData) },
        .{ .buffer = frame.count, .offset = frame.count_offset, .range = @sizeOf(gpu.CullCount) },
    };
    var writes: [4]vk.WriteDescriptorSet = undefined;
    inline for (infos, 0..) |info, i| writes[i] = core.bufferWriteDescriptorSet(self.cull.descriptor_sets_per_frame[frame_idx], @intCast(i), .storage_buffer, &info);
    self.dev.updateDescriptorSets(&writes, null);
}

/// Re-binds the cull descriptor sets whenever the indirect scene reallocated its buffers.
fn updateCullDescriptorsIfNeeded(self: *ChunkRenderer) void {
    const version = self.scene.buffers_version;
    if (version == self.last_cull_version) return;
    for (0..VulkanContext.max_frames_in_flight) |i| self.updateCullDescriptorSet(@intCast(i));
    self.last_cull_version = version;
}

fn dispatchCulling(self: *ChunkRenderer, cmd_buffer: vk.CommandBuffer, current_frame: u32, frustum: Frustum, total_candidates: u32, view_pos: @Vector(3, f64)) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "dispatchCulling" });
    defer zone.end();
    const scene = self.scene;
    const frame = &scene.frame_buffers.items[current_frame];
    self.dev.cmdFillBuffer(cmd_buffer, frame.count, frame.count_offset, @sizeOf(gpu.CullCount), 0);

    core.pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, (&core.makeBufferBarrier2(frame.count, frame.count_offset, @sizeOf(gpu.CullCount), .{ .all_transfer_bit = true }, .{ .transfer_write_bit = true }, .{ .compute_shader_bit = true }, .{ .shader_read_bit = true, .shader_write_bit = true }))[0..1]);

    self.dev.cmdBindPipeline(cmd_buffer, .compute, self.cull.pipeline);
    self.dev.cmdBindDescriptorSets(cmd_buffer, .compute, self.cull.pipeline_layout, 0, (&self.cull.descriptor_sets_per_frame[current_frame])[0..1], null);

    var push_consts: CullPushConstants = undefined;
    for (frustum.planes, 0..) |plane, idx| push_consts.planes[idx] = plane;
    push_consts.player_pos = .{ @floatCast(view_pos[0]), @floatCast(view_pos[1]), @floatCast(view_pos[2]), 1.0 };
    push_consts.total_candidates = total_candidates;
    push_consts.draw_capacity = scene.draw_capacity;

    self.dev.cmdPushConstants(cmd_buffer, self.cull.pipeline_layout, .{ .compute_bit = true }, 0, @sizeOf(@TypeOf(push_consts)), &push_consts);

    const group_count = (total_candidates + (cull_workgroup_size - 1)) / cull_workgroup_size;
    self.dev.cmdDispatch(cmd_buffer, group_count, 1, 1);

    const buffer_barriers: [3]vk.BufferMemoryBarrier2 = .{
        core.makeBufferBarrier2(frame.indirect_draw, frame.indirect_draw_offset, scene.draw_capacity * gpu.draw_type_count * @sizeOf(vk.DrawIndirectCommand), .{ .compute_shader_bit = true }, .{ .shader_write_bit = true }, .{ .draw_indirect_bit = true }, .{ .indirect_command_read_bit = true }),
        core.makeBufferBarrier2(frame.mesh_data, frame.mesh_data_offset, scene.draw_capacity * gpu.draw_type_count * @sizeOf(gpu.MeshData), .{ .compute_shader_bit = true }, .{ .shader_write_bit = true }, .{ .vertex_shader_bit = true }, .{ .shader_read_bit = true }),
        core.makeBufferBarrier2(frame.count, frame.count_offset, @sizeOf(gpu.CullCount), .{ .compute_shader_bit = true }, .{ .shader_write_bit = true }, .{ .draw_indirect_bit = true, .all_transfer_bit = true }, .{ .indirect_command_read_bit = true, .transfer_read_bit = true }),
    };
    core.pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, &buffer_barriers);

    self.dev.cmdCopyBuffer(cmd_buffer, frame.count, frame.stats, (&vk.BufferCopy{ .src_offset = frame.count_offset, .dst_offset = frame.stats_offset, .size = @sizeOf(gpu.CullCount) })[0..1]);

    core.pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, (&core.makeBufferBarrier2(frame.stats, frame.stats_offset, @sizeOf(gpu.CullCount), .{ .all_transfer_bit = true }, .{ .transfer_write_bit = true }, .{ .host_bit = true }, .{ .host_read_bit = true }))[0..1]);
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

    try self.createTransparentDepthDescriptorSetLayout();

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
    const set_layouts: [2]vk.DescriptorSetLayout = .{
        self.texture_manager.descriptor_set_layout,
        self.scene.mesh_data_descriptor_set_layout,
    };
    self.graphics_state.opaque_pipeline_layout = try self.dev.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = set_layouts.len,
        .p_set_layouts = &set_layouts,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = (&graphicsPushConstantRange())[0..1],
    }, &self.vk_ctx.vkalloc);

    const frag_module = try core.createShaderModule(self.dev, &self.vk_ctx.vkalloc, fragment_shader_spv);
    defer self.dev.destroyShaderModule(frag_module, &self.vk_ctx.vkalloc);

    const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
        .flags = .{},
        .depth_test_enable = .true,
        .depth_write_enable = .true,
        .depth_compare_op = .greater,
        .depth_bounds_test_enable = .false,
        .stencil_test_enable = .false,
        .front = undefined,
        .back = undefined,
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
    };
    const blend: vk.PipelineColorBlendAttachmentState = .{
        .blend_enable = .false,
        .src_color_blend_factor = .src_alpha,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .src_alpha,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };
    self.graphics_state.pipeline = try core.buildGraphicsPipeline(self.dev, &self.vk_ctx.vkalloc, self.vk_ctx.pipeline_creation_feedback, vert_module, frag_module, &.{self.vk_ctx.swapchain_format}, depth_format, depth_stencil, &.{blend}, self.graphics_state.opaque_pipeline_layout, gpu.MeshUploader.faceVertexInputState());
}

fn createTransparentPipeline(self: *ChunkRenderer, vert_module: vk.ShaderModule, depth_format: vk.Format) !void {
    const set_layouts: [4]vk.DescriptorSetLayout = .{
        self.texture_manager.descriptor_set_layout,
        self.scene.mesh_data_descriptor_set_layout,
        self.graphics_state.transparent_depth_descriptor_set_layout,
        self.block_materials.descriptor_set_layout,
    };
    self.graphics_state.transparent_pipeline_layout = try self.dev.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = set_layouts.len,
        .p_set_layouts = &set_layouts,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = (&graphicsPushConstantRange())[0..1],
    }, &self.vk_ctx.vkalloc);

    const frag_module = try core.createShaderModule(self.dev, &self.vk_ctx.vkalloc, transparent_frag_spv);
    defer self.dev.destroyShaderModule(frag_module, &self.vk_ctx.vkalloc);

    const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
        .flags = .{},
        .depth_test_enable = .true,
        .depth_write_enable = .false,
        .depth_compare_op = .greater_or_equal,
        .depth_bounds_test_enable = .false,
        .stencil_test_enable = .false,
        .front = undefined,
        .back = undefined,
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
    };
    const blend_attachments: [3]vk.PipelineColorBlendAttachmentState = .{
        .{ .blend_enable = .true, .src_color_blend_factor = .one, .dst_color_blend_factor = .one, .color_blend_op = .add, .src_alpha_blend_factor = .zero, .dst_alpha_blend_factor = .one_minus_src_alpha, .alpha_blend_op = .add, .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true } },
        .{ .blend_enable = .true, .src_color_blend_factor = .one, .dst_color_blend_factor = .one, .color_blend_op = .add, .src_alpha_blend_factor = .one, .dst_alpha_blend_factor = .one, .alpha_blend_op = .add, .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true } },
        .{ .blend_enable = .true, .src_color_blend_factor = .one, .dst_color_blend_factor = .one, .color_blend_op = .add, .src_alpha_blend_factor = .one, .dst_alpha_blend_factor = .one, .alpha_blend_op = .add, .color_write_mask = .{ .r_bit = true, .g_bit = false, .b_bit = false, .a_bit = false } },
    };
    const formats: [3]vk.Format = .{ .r16g16b16a16_sfloat, .r16g16b16a16_sfloat, .r16_sfloat };
    self.graphics_state.transparent_pipeline = try core.buildGraphicsPipeline(self.dev, &self.vk_ctx.vkalloc, self.vk_ctx.pipeline_creation_feedback, vert_module, frag_module, &formats, depth_format, depth_stencil, &blend_attachments, self.graphics_state.transparent_pipeline_layout, gpu.MeshUploader.faceVertexInputState());
}

pub fn recordPasses(self: *ChunkRenderer, ctx: *const PassContext) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordPasses" });
    defer zone.end();
    self.updateCullDescriptorsIfNeeded();
    self.uploader.cmdAcquireFaceBuffer(ctx.cmd_buffer);

    const sun_dir = core.computeSunDirection(ctx.io, ctx.day_length_sec);
    const sky_t: f32 = @floatCast(@min(1.0, @max(0.0, ctx.view_pos[1] / sky_height)));
    const sky_color = std.math.lerp(
        @Vector(4, f32){ 0.0, 0.4, 0.8, 1.0 },
        @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 },
        @as(@Vector(4, f32), @splat(sky_t)),
    );

    const projview_array: [16]f32 = @bitCast(ctx.projview);
    var pc: PushConstants = .{
        .projview = @splat(0),
        .sun_dir = sun_dir,
        .time = ctx.elapsed_sec,
        .mesh_base = 0,
    };
    for (&pc.projview, 0..) |*dst, i| {
        const row = i / 4;
        const col = i % 4;
        dst.* = projview_array[col * 4 + row];
    }

    self.recordOpaquePass(ctx, pc, sky_color);
    self.recordTransparentPass(ctx, pc);

    const scatter_enabled: u32 = @intFromBool(!ctx.inside_transparent);
    self.oit.recordCompositionPass(ctx.cmd_buffer, ctx.extent, ctx.output_image, ctx.output_view, ctx.frame_idx, scatter_enabled, ctx.swapchain_old_layout, ctx.swapchain_layout_ptr, ctx.color_image);

    self.uploader.cmdReleaseFaceBuffer(ctx.cmd_buffer);
}

fn emitFrameStartBarriers(self: *ChunkRenderer, ctx: *const PassContext) void {
    const cmd_buffer = ctx.cmd_buffer;
    const color_aspect: vk.ImageAspectFlags = .{ .color_bit = true };
    const color_old_layout: vk.ImageLayout = if (ctx.frame_sequence > 0) .shader_read_only_optimal else .undefined;
    const depth_old_layout: vk.ImageLayout = if (ctx.frame_sequence > 0) .depth_stencil_read_only_optimal else .undefined;
    const color_src_stage: vk.PipelineStageFlags2 = if (ctx.frame_sequence > 0) .{ .fragment_shader_bit = true } else .{ .top_of_pipe_bit = true };
    const color_src_access: vk.AccessFlags2 = if (ctx.frame_sequence > 0) .{ .shader_read_bit = true } else .{};
    const depth_src_stage: vk.PipelineStageFlags2 = if (ctx.frame_sequence > 0) .{ .fragment_shader_bit = true } else .{ .top_of_pipe_bit = true };
    const depth_src_access: vk.AccessFlags2 = if (ctx.frame_sequence > 0) .{ .depth_stencil_attachment_read_bit = true, .shader_read_bit = true } else .{};

    const pre_dispatch_img_barriers: [2]vk.ImageMemoryBarrier2 = .{
        core.makeImageBarrier2(ctx.color_image, color_old_layout, .color_attachment_optimal, color_src_stage, color_src_access, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, color_aspect),
        core.makeImageBarrier2(ctx.depth_image, depth_old_layout, .depth_stencil_attachment_optimal, depth_src_stage, depth_src_access, .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true }, .{ .depth_stencil_attachment_write_bit = true }, ctx.depth_aspect_mask),
    };
    core.pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, &pre_dispatch_img_barriers);
}

fn recordOpaquePass(self: *ChunkRenderer, ctx: *const PassContext, pc: PushConstants, sky_color: @Vector(4, f32)) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordOpaquePass" });
    defer zone.end();
    self.emitFrameStartBarriers(ctx);

    if (ctx.total_candidates > 0) self.dispatchCulling(ctx.cmd_buffer, ctx.frame_idx, ctx.frustum, ctx.total_candidates, ctx.view_pos);

    const color_attachment = core.renderingAttachmentColor(ctx.color_view, .clear, .{ sky_color[0], sky_color[1], sky_color[2], sky_color[3] });
    const depth_attachment = core.renderingAttachmentDepth(ctx.depth_view, .depth_stencil_attachment_optimal, .clear);

    self.dev.cmdBeginRendering(ctx.cmd_buffer, &core.renderingInfo(ctx.extent, &.{color_attachment}, &depth_attachment));

    self.dev.cmdBindPipeline(ctx.cmd_buffer, .graphics, self.graphics_state.pipeline);

    self.dev.cmdSetCullMode(ctx.cmd_buffer, .{ .back_bit = true });
    self.dev.cmdSetDepthCompareOp(ctx.cmd_buffer, .greater);
    self.dev.cmdSetDepthWriteEnable(ctx.cmd_buffer, .true);

    core.setViewportAndScissor(self.dev, ctx.cmd_buffer, ctx.extent);

    self.dev.cmdBindDescriptorSets(ctx.cmd_buffer, .graphics, self.graphics_state.opaque_pipeline_layout, 0, (&self.texture_manager.descriptor_set)[0..1], null);

    const mesh_desc_set = self.scene.mesh_data_descriptor_sets_per_frame[ctx.frame_idx];
    self.dev.cmdBindDescriptorSets(ctx.cmd_buffer, .graphics, self.graphics_state.opaque_pipeline_layout, 1, (&mesh_desc_set)[0..1], null);

    var pc_opaque = pc;
    pc_opaque.mesh_base = 0;
    self.dev.cmdPushConstants(ctx.cmd_buffer, self.graphics_state.opaque_pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, push_constants_size, &pc_opaque);

    if (ctx.total_candidates > 0) {
        // The face buffer is momentarily null while allocRegion grows it; skip
        // the draw in that rare window instead of binding a stale buffer.
        const face_buf = self.uploader.region_allocator.buffer.load(.acquire);
        if (face_buf != .null_handle) {
            const face_buf_off: vk.DeviceSize = self.uploader.region_allocator.buffer_offset.load(.monotonic);
            self.dev.cmdBindVertexBuffers(ctx.cmd_buffer, 0, (&face_buf)[0..1], (&face_buf_off)[0..1]);

            const frame = &self.scene.frame_buffers.items[ctx.frame_idx];
            self.dev.cmdDrawIndirectCount(ctx.cmd_buffer, frame.indirect_draw, frame.indirect_draw_offset, frame.count, frame.count_offset, self.scene.draw_capacity, @sizeOf(vk.DrawIndirectCommand));
        }
    }

    self.dev.cmdEndRendering(ctx.cmd_buffer);
    core.pipelineBarrier(ctx.cmd_buffer, self.dev, vk.ImageMemoryBarrier2, (&core.makeImageBarrier2(
        ctx.depth_image,
        .depth_stencil_attachment_optimal,
        .depth_stencil_read_only_optimal,
        .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .{ .depth_stencil_attachment_write_bit = true },
        .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true, .fragment_shader_bit = true },
        .{ .depth_stencil_attachment_read_bit = true, .shader_read_bit = true },
        ctx.depth_aspect_mask,
    ))[0..1]);
}

fn recordTransparentPass(self: *ChunkRenderer, ctx: *const PassContext, pc: PushConstants) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordTransparentPass" });
    defer zone.end();
    const oit_color_aspect: vk.ImageAspectFlags = .{ .color_bit = true };
    const oit_old_layout: vk.ImageLayout = if (ctx.frame_sequence > 0) .shader_read_only_optimal else .undefined;
    const oit_src_stage: vk.PipelineStageFlags2 = if (ctx.frame_sequence > 0) .{ .fragment_shader_bit = true } else .{ .top_of_pipe_bit = true };
    const oit_src_access: vk.AccessFlags2 = if (ctx.frame_sequence > 0) .{ .shader_read_bit = true } else .{};
    const oit_pre_barriers: [3]vk.ImageMemoryBarrier2 = .{
        core.makeImageBarrier2(self.oit.accum.image, oit_old_layout, .color_attachment_optimal, oit_src_stage, oit_src_access, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, oit_color_aspect),
        core.makeImageBarrier2(self.oit.reveal.image, oit_old_layout, .color_attachment_optimal, oit_src_stage, oit_src_access, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, oit_color_aspect),
        core.makeImageBarrier2(self.oit.volume_weight.image, oit_old_layout, .color_attachment_optimal, oit_src_stage, oit_src_access, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, oit_color_aspect),
    };
    core.pipelineBarrier(ctx.cmd_buffer, self.dev, vk.ImageMemoryBarrier2, &oit_pre_barriers);

    const oit_accum_attachment = core.renderingAttachmentColor(self.oit.accum.view, .clear, .{ 0.0, 0.0, 0.0, 1.0 });
    const oit_reveal_attachment = core.renderingAttachmentColor(self.oit.reveal.view, .clear, .{ 0.0, 0.0, 0.0, 0.0 });
    const oit_volume_attachment = core.renderingAttachmentColor(self.oit.volume_weight.view, .clear, .{ 0.0, 0.0, 0.0, 0.0 });
    const oit_depth_attachment = core.renderingAttachmentDepth(ctx.depth_view, .depth_stencil_read_only_optimal, .load);
    self.dev.cmdBeginRendering(ctx.cmd_buffer, &core.renderingInfo(ctx.extent, &.{ oit_accum_attachment, oit_reveal_attachment, oit_volume_attachment }, &oit_depth_attachment));

    self.dev.cmdBindPipeline(ctx.cmd_buffer, .graphics, self.graphics_state.transparent_pipeline);

    self.dev.cmdSetCullMode(ctx.cmd_buffer, .{});
    self.dev.cmdSetDepthCompareOp(ctx.cmd_buffer, .greater_or_equal);
    self.dev.cmdSetDepthWriteEnable(ctx.cmd_buffer, .false);
    core.setViewportAndScissor(self.dev, ctx.cmd_buffer, ctx.extent);

    self.dev.cmdBindDescriptorSets(ctx.cmd_buffer, .graphics, self.graphics_state.transparent_pipeline_layout, 0, (&self.texture_manager.descriptor_set)[0..1], null);

    const depth_image_info: vk.DescriptorImageInfo = .{
        .image_layout = .depth_stencil_read_only_optimal,
        .image_view = ctx.depth_sampled_view,
        .sampler = self.texture_manager.sampler,
    };
    // dst_set is ignored by cmdPushDescriptorSetKHR, so null_handle is intentional.
    const depth_write = core.imageWriteDescriptorSet(.null_handle, 0, &depth_image_info);
    self.dev.cmdPushDescriptorSetKHR(ctx.cmd_buffer, .graphics, self.graphics_state.transparent_pipeline_layout, 2, (&depth_write)[0..1]);

    const mesh_desc_set = self.scene.mesh_data_descriptor_sets_per_frame[ctx.frame_idx];
    self.dev.cmdBindDescriptorSets(ctx.cmd_buffer, .graphics, self.graphics_state.transparent_pipeline_layout, 1, (&mesh_desc_set)[0..1], null);

    if (self.block_materials.descriptor_set != .null_handle) {
        self.dev.cmdBindDescriptorSets(ctx.cmd_buffer, .graphics, self.graphics_state.transparent_pipeline_layout, 3, (&self.block_materials.descriptor_set)[0..1], null);
    }

    var pc_transparent = pc;
    pc_transparent.mesh_base = self.scene.draw_capacity;
    self.dev.cmdPushConstants(ctx.cmd_buffer, self.graphics_state.transparent_pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, push_constants_size, &pc_transparent);

    if (ctx.total_candidates > 0) {
        const face_buf = self.uploader.region_allocator.buffer.load(.acquire);
        if (face_buf != .null_handle) {
            const face_buf_off: vk.DeviceSize = self.uploader.region_allocator.buffer_offset.load(.monotonic);
            self.dev.cmdBindVertexBuffers(ctx.cmd_buffer, 0, (&face_buf)[0..1], (&face_buf_off)[0..1]);

            const frame = &self.scene.frame_buffers.items[ctx.frame_idx];
            self.dev.cmdDrawIndirectCount(ctx.cmd_buffer, frame.indirect_draw, frame.indirect_draw_offset + @as(vk.DeviceSize, @intCast(self.scene.draw_capacity * @sizeOf(vk.DrawIndirectCommand))), frame.count, frame.count_offset + @as(vk.DeviceSize, @intCast(@offsetOf(gpu.CullCount, "transparent_count"))), self.scene.draw_capacity, @sizeOf(vk.DrawIndirectCommand));
        }
    }

    self.dev.cmdEndRendering(ctx.cmd_buffer);
}

test "RenderBufferKey.toPos" {
    const pos_a: ChunkPos = .{ .level = 0, .position = .{ 1, 2, 3 } };
    const pos_b: ChunkPos = .{ .level = -3, .position = .{ -10, 20, 30 } };
    try std.testing.expectEqual(pos_a, (RenderBufferKey{ .@"opaque" = pos_a }).toPos());
    try std.testing.expectEqual(pos_b, (RenderBufferKey{ .transparent = pos_b }).toPos());
    const pos: ChunkPos = .{ .level = 5, .position = .{ -100, 200, -300 } };
    try std.testing.expectEqual(pos, (RenderBufferKey{ .@"opaque" = pos }).toPos());
}
