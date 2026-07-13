const std = @import("std");

const options = @import("options");
const tracy = @import("tracy");
const vk = @import("vulkan");
const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;
const InstanceProxy = vk.InstanceProxy;
const DeviceProxy = vk.DeviceProxy;
const wio = @import("wio");
const zm = @import("zm");

const ConcurrentHashMap = @import("../../libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const Mesher = @import("../../Mesher.zig");
const Renderer = @import("../../Renderer.zig");
pub const RenderOptions = Renderer.RenderOptions;
const VulkanContext = @import("../../VulkanContext.zig").VulkanContext;
const World = @import("../../world/World.zig");
const ChunkSize = World.ChunkSize;
const ChunkPos = World.ChunkPos;
const Frustum = @import("../opengl/Frustum.zig").Frustum;
const MemoryPool = @import("VulkanBackingAllocator.zig").MemoryPool;
const textures = @import("textures.zig");
const VulkanBackingAllocator = @import("VulkanBackingAllocator.zig").VulkanBackingAllocator;

const vertex_shader_spv: []const u8 = @embedFile("vert_spv");
const fragment_shader_spv: []const u8 = @embedFile("frag_spv");
const transparent_frag_spv: []const u8 = @embedFile("trans_frag_spv");
const composite_vert_spv: []const u8 = @embedFile("comp_vert_spv");
const composite_frag_spv: []const u8 = @embedFile("comp_frag_spv");
const cull_shader_spv: []const u8 = @embedFile("cull_spv");

const InputChunk = extern struct {
    address: u64 align(8),
    absolute_position: [4]f32 align(16),
    relative_position: [4]f32 align(16),
    scale: f32,
    face_count: u32,
    is_transparent: u32,
};

comptime {
    if (@sizeOf(InputChunk) != 64) @compileError("InputChunk size mismatch with GLSL layout (expected 64, got " ++ @typeName(@TypeOf(@sizeOf(InputChunk))) ++ ")");
}

const CullCount = extern struct {
    opaque_count: u32,
    transparent_count: u32,
};

comptime {
    // Must match GLSL CountBuffer (uint + uint) in cull.comp
    if (@sizeOf(CullCount) != 8) @compileError("CullCount size mismatch");
}

const cull_buffer_alignment: std.mem.Alignment = .fromByteUnits(256);
const cull_workgroup_size: u32 = 64;
const draw_type_count = 2;

pub const camera_up = @Vector(3, f32){ 0, 1, 0 };
const sky_height: f32 = 4096.0;
const near_plane: f32 = 0.01;
const degrees_per_circle: f32 = 360.0;

pub const FrameDebugStats = struct {
    frame_number: u64 = 0,
    total_meshes: u32 = 0,
    opaque_candidates: u32 = 0,
    opaque_culled: u32 = 0,
    opaque_drawn: u32 = 0,
    transparent_candidates: u32 = 0,
    transparent_culled: u32 = 0,
    transparent_drawn: u32 = 0,
    player_pos: @Vector(3, f64) = .{ 0, 0, 0 },
    camera_front: @Vector(3, f32) = .{ 0, 0, 1 },
    elapsed_ns: u64 = 0,

    pub fn log(self: *const FrameDebugStats) void {
        const total_drawn = self.opaque_drawn + self.transparent_drawn;
        const total_culled = self.total_meshes -| total_drawn;
        const elapsed_f: f64 = @floatFromInt(self.elapsed_ns);
        const ms = elapsed_f / 1_000_000.0;
        const visible_pct = if (self.total_meshes > 0) @as(f64, @floatFromInt(total_drawn)) / @as(f64, @floatFromInt(self.total_meshes)) * 100.0 else 0.0;
        std.log.info("=== FRAME {d} DEBUG STATS ===", .{self.frame_number});
        std.log.info("Player pos=({d:.1}, {d:.1}, {d:.1})  Camera front=({d:.3}, {d:.3}, {d:.3})", .{
            self.player_pos[0],   self.player_pos[1],   self.player_pos[2],
            self.camera_front[0], self.camera_front[1], self.camera_front[2],
        });
        std.log.info("Meshes in map: {d}  Opaque drawn: {d}  Transparent drawn: {d}", .{ self.total_meshes, self.opaque_drawn, self.transparent_drawn });
        std.log.info("Total: culled={d:>6}  drawn={d:>6} ({d:.1}% visible)", .{ total_culled, total_drawn, visible_pct });
        std.log.info("Time: {d:.2} ms", .{ms});
        std.log.info("========================", .{});
        if (total_drawn == 0) {
            std.log.warn("FRAME {d}: NO CHUNKS DRAWN! total_meshes={d}", .{ self.frame_number, self.total_meshes });
        }
    }
};

const RenderBufferKey = union(enum) {
    @"opaque": ChunkPos,
    transparent: ChunkPos,

    pub fn toPos(self: RenderBufferKey) ChunkPos {
        return switch (self) {
            inline .@"opaque", .transparent => |pos| pos,
        };
    }
};

const IndexPool = struct {
    free_indices: []u32,
    head: u32,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !IndexPool {
        const indices = try allocator.alloc(u32, capacity);
        for (indices, 0..) |*val, i| {
            val.* = @intCast(capacity - 1 - i);
        }
        return .{
            .free_indices = indices,
            .head = capacity,
        };
    }

    pub fn deinit(self: *IndexPool, allocator: std.mem.Allocator) void {
        allocator.free(self.free_indices);
    }

    pub fn allocIndex(self: *IndexPool, io: std.Io) ?u32 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.head == 0) return null;
        self.head -= 1;
        return self.free_indices[self.head];
    }

    pub fn freeIndex(self: *IndexPool, io: std.Io, index: u32) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.free_indices[self.head] = index;
        self.head += 1;
    }

    pub fn grow(self: *IndexPool, io: std.Io, allocator: std.mem.Allocator, new_capacity: u32) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const old_capacity = @as(u32, @intCast(self.free_indices.len));
        const added = new_capacity - old_capacity;
        const new_indices = try allocator.alloc(u32, new_capacity);
        @memcpy(new_indices[0..self.head], self.free_indices[0..self.head]);
        for (new_indices[self.head .. self.head + added], old_capacity..) |*val, i| {
            val.* = @intCast(i);
        }
        allocator.free(self.free_indices);
        self.free_indices = new_indices;
        self.head += added;
    }
};

const ChunkMeshBuffer = struct {
    buffer: vk.Buffer,
    alloc_offset: vk.DeviceSize,
    alloc_size: vk.DeviceSize,
    device_address: vk.DeviceAddress,
    face_count: u32,
    slice: []u8,
    gpu_index: u32,
};

pub const batch_size = 512;
pub const pending_queue_size = 512;

const PendingChunkUpload = struct {
    chunk_pos: ChunkPos,
    timeline_value: u64,
    pool: vk.CommandPool,
    opaque_mesh: ?ChunkMeshBuffer,
    transparent_mesh: ?ChunkMeshBuffer,
    opaque_staging_slice: ?[]u8,
    transparent_staging_slice: ?[]u8,
};

const RetiredMeshEntry = struct {
    mesh: ChunkMeshBuffer,
    gpu_index: u32,
    graphics_timeline_value: u64,
};

const RetiredCandidateSlice = struct {
    slice: []InputChunk,
    graphics_timeline_value: u64,
};

const CommandPoolReservoir = struct {
    pools: []vk.CommandPool = &.{},
    cmds: []vk.CommandBuffer = &.{},
    used: []std.atomic.Value(bool) = &.{},

    pub const Borrowed = struct { pool: vk.CommandPool, cmd: vk.CommandBuffer };

    pub fn init(self: *CommandPoolReservoir, dev: DeviceProxy, queue_family: u32, count: usize, allocator: std.mem.Allocator) !void {
        self.pools = try allocator.alloc(vk.CommandPool, count);
        errdefer allocator.free(self.pools);
        self.cmds = try allocator.alloc(vk.CommandBuffer, count);
        errdefer allocator.free(self.cmds);
        self.used = try allocator.alloc(std.atomic.Value(bool), count);
        errdefer allocator.free(self.used);
        for (self.used) |*u| u.* = .init(false);
        var i: usize = 0;
        errdefer for (0..i) |j| dev.destroyCommandPool(self.pools[j], null);
        for (self.pools, 0..) |*pool, idx| {
            pool.* = try dev.createCommandPool(&.{ .flags = .{ .reset_command_buffer_bit = true }, .queue_family_index = queue_family }, null);
            i += 1;
            try dev.allocateCommandBuffers(&.{ .command_pool = pool.*, .level = .primary, .command_buffer_count = 1 }, (&self.cmds[idx])[0..1]);
        }
    }

    pub fn deinit(self: *CommandPoolReservoir, dev: DeviceProxy, allocator: std.mem.Allocator) void {
        for (self.pools) |pool| if (pool != .null_handle) dev.destroyCommandPool(pool, null);
        allocator.free(self.pools);
        allocator.free(self.cmds);
        allocator.free(self.used);
    }

    pub fn tryBorrowPool(self: *CommandPoolReservoir) ?Borrowed {
        for (self.pools, 0..) |pool, i| {
            if (self.used[i].cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                return .{ .pool = pool, .cmd = self.cmds[i] };
            }
        }
        return null;
    }

    pub fn returnPool(self: *CommandPoolReservoir, dev: DeviceProxy, pool: vk.CommandPool) void {
        dev.resetCommandPool(pool, .{}) catch |err| @panic(@errorName(err));
        for (self.pools, 0..) |p, i| {
            if (p == pool) {
                self.used[i].store(false, .release);
                break;
            }
        }
    }
};

const ChunkData = extern struct {
    address: u64 align(8),
    absolute_position: [4]f32 align(16),
    relative_position: [4]f32 align(16),
    scale: f32,
};

comptime {
    if (@sizeOf(ChunkData) != 64) @compileError("ChunkData size mismatch with GLSL layout (expected 64)");
}

comptime {
    // PushConstants: mat4(64) + vec3(12) + float(4) = 80
    if (@sizeOf(PushConstants) != 80) @compileError("PushConstants size mismatch with GLSL layout");
}

const PushConstants = extern struct {
    projview: [16]f32,
    sun_dir: [3]f32,
    time: f32,
};

fn findMemoryTypeRaw(mem_props: vk.PhysicalDeviceMemoryProperties, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    for (mem_props.memory_types[0..mem_props.memory_type_count], 0..) |mem_type, i| {
        if ((type_filter & (@as(u32, 1) << @as(u5, @intCast(i)))) != 0 and (mem_type.property_flags.toInt() & properties.toInt()) == properties.toInt()) {
            return @intCast(i);
        }
    }
    return error.MemoryTypeNotFound;
}

fn computeViewProjection(self: *const VulkanRenderer, aspect: f32, fov_radians: f32) struct { projview: @Vector(16, f32), frustum: Frustum } {
    const up_vec: zm.vec.Vec3f = .{ .data = [3]f32{ camera_up[0], camera_up[1], camera_up[2] } };
    const camera_front_val = @Vector(3, f32){
        self.camera_front_x.load(.monotonic),
        self.camera_front_y.load(.monotonic),
        self.camera_front_z.load(.monotonic),
    };
    const view = zm.matrix.Mat4f.lookAtRH(
        .{ .data = @Vector(3, f32){ 0, 0, 0 } },
        .{ .data = camera_front_val },
        up_vec,
    );
    const projection = makeInfReversedZProjRh(fov_radians, aspect, near_plane);
    const projview: @Vector(16, f32) = @bitCast(projection.multiply(view).data);
    return .{ .projview = projview, .frustum = Frustum.extractFrustumPlanes(projview) };
}

fn computeSunDirection(io: std.Io, day_length_sec: f32) @Vector(3, f32) {
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const now_ns_f = @as(f64, @floatFromInt(now_ns));
    const sun_angle = @rem(now_ns_f / ((@as(f64, @max(0.001, day_length_sec)) * std.time.ns_per_s) / degrees_per_circle), degrees_per_circle);
    const sun_rot_mat = zm.Mat4f.rotationRH(.{ .data = @Vector(3, f32){ 1.0, 0.0, 0.0 } }, @floatCast(std.math.degreesToRadians(sun_angle)));
    return .{ sun_rot_mat.data[1][0], sun_rot_mat.data[1][1], sun_rot_mat.data[1][2] };
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

const RenderTarget = struct {
    image: vk.Image = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    view: vk.ImageView = .null_handle,
};

const TransferState = struct {
    queue: vk.Queue = undefined,
    queue_family_index: u32 = undefined,
    semaphore: vk.Semaphore = .null_handle,
    graphics_timeline_semaphore: vk.Semaphore = .null_handle,
};

const OitState = struct {
    accum: RenderTarget = .{},
    reveal: RenderTarget = .{},
    sampler: vk.Sampler = .null_handle,
    composition_pipeline: vk.Pipeline = .null_handle,
    composition_layout: vk.PipelineLayout = .null_handle,
    descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    descriptor_sets_per_frame: []vk.DescriptorSet = &.{},
    descriptor_pool: vk.DescriptorPool = .null_handle,
};

const PersistentCandidates = struct {
    buffer: vk.Buffer = .null_handle,
    mapped: [*]InputChunk = undefined,
    offset: vk.DeviceSize = 0,
    slice: []InputChunk = &.{},
};

const GraphicsState = struct {
    opaque_descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    transparent_descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
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

const PerFrameBuffers = struct {
    indirect_draw: []vk.Buffer = &.{},
    indirect_draw_mapped: []?[*]vk.DrawIndirectCommand = &.{},
    indirect_draw_offsets: []vk.DeviceSize = &.{},
    chunk_data: []vk.Buffer = &.{},
    chunk_data_mapped: []?[*]ChunkData = &.{},
    chunk_data_offsets: []vk.DeviceSize = &.{},
    count: []vk.Buffer = &.{},
    count_slices: [][]align(cull_buffer_alignment.toByteUnits()) CullCount = &.{},
    count_offsets: []vk.DeviceSize = &.{},
    stats: []vk.Buffer = &.{},
    stats_mapped: []?[*]align(cull_buffer_alignment.toByteUnits()) CullCount = &.{},
    stats_offsets: []vk.DeviceSize = &.{},
    stats_slices: [][]align(cull_buffer_alignment.toByteUnits()) CullCount = &.{},

    fn deinit(self: *PerFrameBuffers, allocator: std.mem.Allocator, cpu_to_gpu_gpa: std.mem.Allocator, gpu_only_gpa: std.mem.Allocator, draw_capacity: u32) void {
        for (self.indirect_draw_mapped) |ptr| if (ptr) |p| cpu_to_gpu_gpa.free(p[0 .. draw_capacity * draw_type_count]);
        for (self.chunk_data_mapped) |ptr| if (ptr) |p| cpu_to_gpu_gpa.free(p[0 .. draw_capacity * draw_type_count]);
        for (self.count_slices) |slice| gpu_only_gpa.free(slice);
        for (self.stats_slices) |slice| cpu_to_gpu_gpa.free(slice);
        allocator.free(self.indirect_draw);
        allocator.free(self.indirect_draw_mapped);
        allocator.free(self.indirect_draw_offsets);
        allocator.free(self.chunk_data);
        allocator.free(self.chunk_data_mapped);
        allocator.free(self.chunk_data_offsets);
        allocator.free(self.count);
        allocator.free(self.count_slices);
        allocator.free(self.count_offsets);
        allocator.free(self.stats);
        allocator.free(self.stats_mapped);
        allocator.free(self.stats_offsets);
        allocator.free(self.stats_slices);
        self.* = .{};
    }
};

pub const VulkanRenderer = @This();

vk_ctx: *VulkanContext,
allocator: std.mem.Allocator,
dev: DeviceProxy,
graphics_queue: vk.Queue,
upload_command_pool: vk.CommandPool = .null_handle,

current_frame: u32 = 0,
output_cmd_buffer: vk.CommandBuffer = .null_handle,
output_color_image: vk.Image = .null_handle,
output_color_view: vk.ImageView = .null_handle,
render_color: RenderTarget = .{},
render_depth: RenderTarget = .{},
render_depth_sampled_view: vk.ImageView = .null_handle,
depth_format: vk.Format = .undefined,
oit: OitState = .{},
texture_manager: textures.TextureArrayManager = undefined,

graphics_state: GraphicsState = .{},
transfer: TransferState = .{},
meshes: ConcurrentHashMap(RenderBufferKey, ChunkMeshBuffer, std.hash_map.AutoContext(RenderBufferKey), 80, 32),
frame_buffers: PerFrameBuffers = .{},
cull: CullState = .{},
persistent: PersistentCandidates = .{},
index_pool: IndexPool = undefined,
max_allocated_index: std.atomic.Value(u32) = .init(0),
retired_candidate_slices: std.ArrayList(RetiredCandidateSlice) = .empty,

draw_capacity: u32 = 4096,
max_draw_indirect_count: u32 = 65_535,
retired_meshes: std.ArrayList(RetiredMeshEntry) = undefined,
backing_allocator: VulkanBackingAllocator = undefined,
gpu_only_gpa: std.heap.DebugAllocator(.{}) = .init,
cpu_to_gpu_gpa: std.heap.DebugAllocator(.{}) = .init,
pool_reservoir: CommandPoolReservoir = .{},
pending_uploads_queue: std.Io.Queue(PendingChunkUpload) = undefined,
pending_uploads_queue_buffer: []PendingChunkUpload = &.{},
peeked_upload: ?PendingChunkUpload = null,
submission_batch: struct {
    cmds: [batch_size]vk.CommandBuffer = undefined,
    pools: [batch_size]vk.CommandPool = undefined,
    opaque_meshes: [batch_size]?UploadResult = undefined,
    transparent_meshes: [batch_size]?UploadResult = undefined,
    chunk_positions: [batch_size]ChunkPos = undefined,
    count: usize = 0,
    mutex: std.Io.Mutex = .init,
} = .{},
camera_front_x: std.atomic.Value(f32) = .init(0),
camera_front_y: std.atomic.Value(f32) = .init(0),
camera_front_z: std.atomic.Value(f32) = .init(1),
viewport_pixels: @Vector(2, u32) = .{ 800, 600 },
render_options: *const RenderOptions,
render_options_lock: *std.Io.RwLock,
interface: Renderer,

retire_mutex: std.Io.Mutex = .init,
num_in_flight: u32 = 0,
init_time_ns: u64 = 0,
frame_stats: FrameDebugStats = .{},

pub fn setupFrame(self: *VulkanRenderer, frame_index: u32, cmd_buffer: vk.CommandBuffer, output_image: vk.Image, output_view: vk.ImageView) void {
    self.current_frame = frame_index;
    self.output_cmd_buffer = cmd_buffer;
    self.output_color_image = output_image;
    self.output_color_view = output_view;
}

fn loadDefaultTextures(self: *VulkanRenderer, io: std.Io, allocator: std.mem.Allocator) !void {
    self.texture_manager = .init(self, self.render_options.gamma_correction);
    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, "packs/default/Blocks/", .{ .open_options = .{ .iterate = true } });
    defer dir.close(io);
    const textures_to_write = [_]struct { []const u8, []const u8 }{
        .{ "grass.png", @embedFile("../opengl/Blocks/grass.png") },
        .{ "dirt.png", @embedFile("../opengl/Blocks/dirt.png") },
        .{ "snow.png", @embedFile("../opengl/Blocks/snow.png") },
        .{ "stone.png", @embedFile("../opengl/Blocks/stone.png") },
        .{ "water.png", @embedFile("../opengl/Blocks/water.png") },
        .{ "wood.png", @embedFile("../opengl/Blocks/wood.png") },
        .{ "leaves.png", @embedFile("../opengl/Blocks/leaves.png") },
    };
    inline for (textures_to_write) |t| {
        try dir.writeFile(io, .{ .data = t[1], .sub_path = t[0] });
    }
    try self.texture_manager.loadTextureDirectory(io, dir, allocator, ".png");
}

fn allocateIndirectBuffers(self: *VulkanRenderer, i: usize) !void {
    const chunk_data_slice = try self.cpu_to_gpu_gpa.allocator().alloc(ChunkData, self.draw_capacity * draw_type_count);
    const indirect_draw_slice = try self.cpu_to_gpu_gpa.allocator().alloc(vk.DrawIndirectCommand, self.draw_capacity * draw_type_count);

    const chunk_data_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, chunk_data_slice.ptr);
    const indirect_draw_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, indirect_draw_slice.ptr);

    self.frame_buffers.chunk_data[i] = chunk_data_info.buffer;
    self.frame_buffers.chunk_data_mapped[i] = chunk_data_slice.ptr;
    self.frame_buffers.chunk_data_offsets[i] = chunk_data_info.offset;

    self.frame_buffers.indirect_draw[i] = indirect_draw_info.buffer;
    self.frame_buffers.indirect_draw_mapped[i] = indirect_draw_slice.ptr;
    self.frame_buffers.indirect_draw_offsets[i] = indirect_draw_info.offset;

    // Allocate count buffers (GPU-only)
    const count_slice = try self.gpu_only_gpa.allocator().alignedAlloc(CullCount, cull_buffer_alignment, 1);
    const count_info = self.backing_allocator.getBufferAndOffset(.gpu_only, count_slice.ptr);
    self.frame_buffers.count[i] = count_info.buffer;
    self.frame_buffers.count_slices[i] = count_slice;
    self.frame_buffers.count_offsets[i] = count_info.offset;

    // Allocate stats buffers (CPU-to-GPU, mapped)
    const stats_slice = try self.cpu_to_gpu_gpa.allocator().alignedAlloc(CullCount, cull_buffer_alignment, 1);
    stats_slice[0] = .{ .opaque_count = 0, .transparent_count = 0 };
    const stats_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, stats_slice.ptr);
    self.frame_buffers.stats[i] = stats_info.buffer;
    self.frame_buffers.stats_mapped[i] = stats_slice.ptr;
    self.frame_buffers.stats_offsets[i] = stats_info.offset;
    self.frame_buffers.stats_slices[i] = stats_slice;
}

pub fn recreateSwapchainResourcesLocked(self: *VulkanRenderer, io: std.Io) !void {
    self.render_options_lock.lockSharedUncancelable(io);
    const gamma_correction = self.render_options.gamma_correction;
    const present_mode = self.render_options.present_mode;
    self.render_options_lock.unlockShared(io);
    self.vk_ctx.present_mode = present_mode;
    try self.vk_ctx.createSwapchainLocked(gamma_correction);

    self.destroyRendererSwapchainResources();

    const actual_extent = self.vk_ctx.swapchain_extent;
    self.viewport_pixels = .{ actual_extent.width, actual_extent.height };

    try self.createRenderTargets(actual_extent);

    const num_swapchain_images = self.vk_ctx.swapchain_images.len;
    self.num_in_flight = @intCast(num_swapchain_images);
    self.frame_buffers.indirect_draw = try self.allocator.alloc(vk.Buffer, num_swapchain_images);
    self.frame_buffers.indirect_draw_mapped = try self.allocator.alloc(?[*]vk.DrawIndirectCommand, num_swapchain_images);
    self.frame_buffers.indirect_draw_offsets = try self.allocator.alloc(vk.DeviceSize, num_swapchain_images);
    self.frame_buffers.chunk_data = try self.allocator.alloc(vk.Buffer, num_swapchain_images);
    self.frame_buffers.chunk_data_mapped = try self.allocator.alloc(?[*]ChunkData, num_swapchain_images);
    self.frame_buffers.chunk_data_offsets = try self.allocator.alloc(vk.DeviceSize, num_swapchain_images);

    self.frame_buffers.count = try self.allocator.alloc(vk.Buffer, num_swapchain_images);
    self.frame_buffers.count_slices = try self.allocator.alloc([]align(cull_buffer_alignment.toByteUnits()) CullCount, num_swapchain_images);
    self.frame_buffers.count_offsets = try self.allocator.alloc(vk.DeviceSize, num_swapchain_images);

    self.frame_buffers.stats = try self.allocator.alloc(vk.Buffer, num_swapchain_images);
    self.frame_buffers.stats_mapped = try self.allocator.alloc(?[*]align(cull_buffer_alignment.toByteUnits()) CullCount, num_swapchain_images);
    self.frame_buffers.stats_offsets = try self.allocator.alloc(vk.DeviceSize, num_swapchain_images);
    self.frame_buffers.stats_slices = try self.allocator.alloc([]align(cull_buffer_alignment.toByteUnits()) CullCount, num_swapchain_images);

    @memset(self.frame_buffers.indirect_draw_mapped, null);
    @memset(self.frame_buffers.chunk_data_mapped, null);
    @memset(self.frame_buffers.stats_mapped, null);

    for (0..num_swapchain_images) |i| {
        try self.allocateIndirectBuffers(i);
    }

    if (self.graphics_state.opaque_pipeline_layout != .null_handle) {
        if (self.graphics_state.pipeline != .null_handle) {
            self.dev.destroyPipeline(self.graphics_state.pipeline, null);
            self.graphics_state.pipeline = .null_handle;
        }
        if (self.graphics_state.transparent_pipeline != .null_handle) {
            self.dev.destroyPipeline(self.graphics_state.transparent_pipeline, null);
            self.graphics_state.transparent_pipeline = .null_handle;
        }
        self.dev.destroyPipelineLayout(self.graphics_state.opaque_pipeline_layout, null);
        self.graphics_state.opaque_pipeline_layout = .null_handle;
        self.dev.destroyPipelineLayout(self.graphics_state.transparent_pipeline_layout, null);
        self.graphics_state.transparent_pipeline_layout = .null_handle;
        try self.createGraphicsPipelines();
    }

    if (self.graphics_state.opaque_descriptor_set_layout != .null_handle) {
        try self.createOpaqueDescriptorSetLayout();
        try self.createTransparentDescriptorSetLayout();
    }

    // The cull descriptor sets also reference the indirect, chunk_data, count, and stats buffers.
    // These were just recreated by allocateIndirectBuffers above, so the descriptor sets
    // must be updated to point to the new buffers.
    if (self.cull.descriptor_set_layout != .null_handle) {
        for (0..num_swapchain_images) |i| {
            self.updateCullDescriptorSet(@intCast(i));
        }
    }

    if (self.oit.descriptor_set_layout != .null_handle) {
        self.destroyOitPipelinesAndDescriptors();
        try self.createOitPipelinesAndDescriptors();
    }
}

fn destroyRendererSwapchainResources(self: *VulkanRenderer) void {
    destroyRenderTarget(self.dev, &self.render_color);
    destroyRenderTarget(self.dev, &self.render_depth);
    destroyIfValidImageView(self.dev, &self.render_depth_sampled_view);
    self.frame_buffers.deinit(self.allocator, self.cpu_to_gpu_gpa.allocator(), self.gpu_only_gpa.allocator(), self.draw_capacity);
    self.destroyOitResources();
}

pub fn init(io: std.Io, allocator: std.mem.Allocator, vk_ctx: *VulkanContext, render_options: *const RenderOptions, render_options_lock: *std.Io.RwLock) !*VulkanRenderer {
    std.log.info("VulkanRenderer.init: Starting renderer-specific Vulkan initialization...", .{});

    const self = try allocator.create(VulkanRenderer);
    errdefer allocator.destroy(self);

    self.* = .{
        .vk_ctx = vk_ctx,
        .allocator = allocator,
        .dev = vk_ctx.dev,
        .graphics_queue = vk_ctx.graphics_queue,
        .upload_command_pool = vk_ctx.upload_command_pool,
        .render_options = render_options,
        .render_options_lock = render_options_lock,
        .meshes = undefined,
        .interface = undefined,
    };

    self.init_time_ns = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    self.retired_meshes = .empty;

    self.max_draw_indirect_count = if (vk_ctx.props.limits.max_draw_indirect_count > 0) vk_ctx.props.limits.max_draw_indirect_count else 65_535;

    self.transfer.queue_family_index = vk_ctx.transfer_queue_family_index;
    self.transfer.queue = vk_ctx.transfer_queue;
    self.transfer.semaphore = vk_ctx.transfer_semaphore;
    self.transfer.graphics_timeline_semaphore = vk_ctx.graphics_timeline_semaphore;

    self.backing_allocator = VulkanBackingAllocator.init(self.dev, self.vk_ctx.mem_props, io, allocator);
    errdefer self.backing_allocator.deinit();

    self.gpu_only_gpa = .init;
    self.gpu_only_gpa.backing_allocator = self.backing_allocator.allocator(.gpu_only);
    errdefer _ = self.gpu_only_gpa.deinit();

    self.cpu_to_gpu_gpa = .init;
    self.cpu_to_gpu_gpa.backing_allocator = self.backing_allocator.allocator(.cpu_to_gpu);
    errdefer _ = self.cpu_to_gpu_gpa.deinit();

    // Initialize persistent candidate buffer on the GPU
    const initial_capacity = 4096;
    const persistent_candidates_slice = try self.cpu_to_gpu_gpa.allocator().alloc(InputChunk, initial_capacity);
    errdefer self.cpu_to_gpu_gpa.allocator().free(persistent_candidates_slice);
    @memset(persistent_candidates_slice, .{
        .absolute_position = .{ 0, 0, 0, 0 },
        .relative_position = .{ 0, 0, 0, 0 },
        .scale = 0,
        .face_count = 0,
        .is_transparent = 0,
        .address = 0,
    });
    const cand_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, persistent_candidates_slice.ptr);
    self.persistent.buffer = cand_info.buffer;
    self.persistent.mapped = @ptrCast(persistent_candidates_slice.ptr);
    self.persistent.offset = cand_info.offset;
    self.persistent.slice = persistent_candidates_slice;
    self.retired_candidate_slices = .empty;

    self.index_pool = try IndexPool.init(allocator, initial_capacity);
    errdefer self.index_pool.deinit(allocator);
    self.max_allocated_index = .init(0);

    try self.recreateSwapchainResourcesLocked(io);

    try self.createOpaqueDescriptorSetLayout();
    try self.createTransparentDescriptorSetLayout();
    try self.createCullDescriptorSetLayoutAndPool();

    try self.loadDefaultTextures(io, allocator);

    try self.createGraphicsPipelines();
    try self.createCullPipeline();
    try self.createOitPipelinesAndDescriptors();

    self.meshes = .init;

    try self.pool_reservoir.init(self.dev, self.transfer.queue_family_index, 512, allocator);
    errdefer self.pool_reservoir.deinit(self.dev, allocator);

    self.pending_uploads_queue_buffer = try allocator.alloc(PendingChunkUpload, pending_queue_size);
    errdefer allocator.free(self.pending_uploads_queue_buffer);
    self.pending_uploads_queue = std.Io.Queue(PendingChunkUpload).init(self.pending_uploads_queue_buffer);
    self.peeked_upload = null;

    self.interface = .{
        .userdata = @ptrCast(self),
        .vtable = &.{
            .addChunk = vtableAddChunk,
            .draw = vtableDrawChunks,
            .setViewport = vtableSetViewport,
            .updateCameraDirection = vtableUpdateCameraDirection,
            .forEachChunk = vtableForEachChunk,
        },
    };

    return self;
}

pub fn deinit(self: *VulkanRenderer, io: std.Io) void {
    std.log.info("VulkanRenderer.deinit: Flushing pending uploads and waiting for device idle...", .{});

    {
        self.submission_batch.mutex.lockUncancelable(io);
        defer self.submission_batch.mutex.unlock(io);
        self.submitBatchLocked(io) catch |err| {
            std.log.err("VulkanRenderer.deinit: failed to flush submission batch: {any}", .{err});
        };
    }
    {
        self.vk_ctx.queue_mutex.lockUncancelable(io);
        defer self.vk_ctx.queue_mutex.unlock(io);
        self.dev.deviceWaitIdle() catch |err| {
            std.log.err("VulkanRenderer.deinit: deviceWaitIdle failed: {any}", .{err});
        };
    }

    if (self.peeked_upload) |pending| {
        self.destroyPendingUpload(pending);
    }
    while (true) {
        var buf: PendingChunkUpload = undefined;
        const got = self.pending_uploads_queue.getUncancelable(io, (&buf)[0..1], 0) catch 0;
        if (got == 0) break;
        self.destroyPendingUpload(buf);
    }
    self.allocator.free(self.pending_uploads_queue_buffer);

    for (self.retired_meshes.items) |entry| {
        self.destroyChunkMesh(entry.mesh);
    }
    self.retired_meshes.deinit(self.allocator);

    var it = self.meshes.iterator();
    defer it.deinit(io);
    while (it.next(io) catch null) |entry| {
        self.destroyChunkMesh(entry.value_ptr.*);
    }
    self.meshes.deinit(io, self.allocator);

    self.destroyRendererSwapchainResources();

    self.destroyOitPipelinesAndDescriptors();

    destroyIfValidPipeline(self.dev, &self.graphics_state.pipeline);
    destroyIfValidPipeline(self.dev, &self.graphics_state.transparent_pipeline);
    destroyIfValidPipeline(self.dev, &self.cull.pipeline);
    destroyIfValidPipelineLayout(self.dev, &self.graphics_state.opaque_pipeline_layout);
    destroyIfValidPipelineLayout(self.dev, &self.graphics_state.transparent_pipeline_layout);
    destroyIfValidPipelineLayout(self.dev, &self.cull.pipeline_layout);
    destroyIfValidDescriptorSetLayout(self.dev, &self.graphics_state.opaque_descriptor_set_layout);
    destroyIfValidDescriptorSetLayout(self.dev, &self.graphics_state.transparent_descriptor_set_layout);
    destroyIfValidDescriptorSetLayout(self.dev, &self.cull.descriptor_set_layout);

    if (self.cull.descriptor_pool != .null_handle) {
        self.dev.destroyDescriptorPool(self.cull.descriptor_pool, null);
        self.cull.descriptor_pool = .null_handle;
    }
    self.allocator.free(self.cull.descriptor_sets_per_frame);
    self.cull.descriptor_sets_per_frame = &.{};

    self.pool_reservoir.deinit(self.dev, self.allocator);

    for (self.retired_candidate_slices.items) |entry| {
        self.cpu_to_gpu_gpa.allocator().free(entry.slice);
    }
    self.retired_candidate_slices.deinit(self.allocator);
    self.index_pool.deinit(self.allocator);
    self.cpu_to_gpu_gpa.allocator().free(self.persistent.slice);

    _ = self.gpu_only_gpa.deinit();
    _ = self.cpu_to_gpu_gpa.deinit();
    self.backing_allocator.deinit();

    self.texture_manager.destroyTextureArray();

    self.allocator.destroy(self);
}

pub fn addChunk(self: *VulkanRenderer, io: std.Io, chunk_pos: ChunkPos, opaque_mesh: []const Mesher.Face, transparent_mesh: []const Mesher.Face) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "addChunk" });
    defer zone.end();

    var borrowed_opt: ?CommandPoolReservoir.Borrowed = null;
    while (borrowed_opt == null) {
        borrowed_opt = self.pool_reservoir.tryBorrowPool();
        if (borrowed_opt == null) {
            {
                self.submission_batch.mutex.lockUncancelable(io);
                defer self.submission_batch.mutex.unlock(io);
                if (self.submission_batch.count > 0) {
                    try self.submitBatchLocked(io);
                }
            }
            try self.retireCompletedUploads(io);
            try std.Io.sleep(io, .fromNanoseconds(0), .awake);
        }
    }
    const borrowed = borrowed_opt.?;
    const pool = borrowed.pool;
    const cmd = borrowed.cmd;
    errdefer self.pool_reservoir.returnPool(self.dev, pool);

    try self.dev.resetCommandPool(pool, .{});

    const begin_info: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };
    try self.dev.beginCommandBuffer(cmd, &begin_info);

    var opaque_res: ?UploadResult = null;
    var transparent_res: ?UploadResult = null;
    errdefer {
        if (opaque_res) |r| {
            self.cpu_to_gpu_gpa.allocator().free(r.staging_slice);
            self.gpu_only_gpa.allocator().free(r.mesh.slice);
        }
        if (transparent_res) |r| {
            self.cpu_to_gpu_gpa.allocator().free(r.staging_slice);
            self.gpu_only_gpa.allocator().free(r.mesh.slice);
        }
    }

    if (opaque_mesh.len > 0) {
        opaque_res = try self.uploadMeshBuffer(opaque_mesh, cmd);
    }
    if (transparent_mesh.len > 0) {
        transparent_res = try self.uploadMeshBuffer(transparent_mesh, cmd);
    }

    try self.dev.endCommandBuffer(cmd);

    {
        const zone_batch = tracy.Zone.begin(.{ .src = @src(), .name = "addChunk_lock_batch" });
        self.submission_batch.mutex.lockUncancelable(io);
        zone_batch.end();
        defer self.submission_batch.mutex.unlock(io);

        if (self.submission_batch.count == batch_size) {
            try self.submitBatchLocked(io);
        }

        const count = self.submission_batch.count;
        self.submission_batch.cmds[count] = cmd;
        self.submission_batch.pools[count] = pool;
        self.submission_batch.opaque_meshes[count] = opaque_res;
        self.submission_batch.transparent_meshes[count] = transparent_res;
        self.submission_batch.chunk_positions[count] = chunk_pos;
        self.submission_batch.count += 1;
    }
}

fn submitBatchLocked(self: *VulkanRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "submitBatchLocked" });
    defer zone.end();

    const count = self.submission_batch.count;
    if (count == 0) return;

    const next_val = blk: {
        const zone_queue = tracy.Zone.begin(.{ .src = @src(), .name = "submitBatch_lock_queue" });
        self.vk_ctx.queue_mutex.lockUncancelable(io);
        zone_queue.end();
        defer self.vk_ctx.queue_mutex.unlock(io);

        // Load current value and compute next WITHOUT pre-incrementing.
        const next_val = self.vk_ctx.transfer_semaphore_value.load(.monotonic) + 1;

        // Increment and store the counter before submitting so graphics queue knows to wait on this value.
        self.vk_ctx.transfer_semaphore_value.store(next_val, .monotonic);

        var cb_submit_infos: [batch_size]vk.CommandBufferSubmitInfo = undefined;
        for (cb_submit_infos[0..count], self.submission_batch.cmds[0..count]) |*info, cmd| {
            info.* = .{
                .command_buffer = cmd,
                .device_mask = 0,
            };
        }

        const current_graphics_val = self.vk_ctx.frame_number.load(.monotonic);
        const wait_semaphore_info: vk.SemaphoreSubmitInfo = .{
            .semaphore = self.transfer.graphics_timeline_semaphore,
            .value = current_graphics_val,
            .stage_mask = .{ .all_transfer_bit = true },
            .device_index = 0,
        };

        const semaphore_submit_info: vk.SemaphoreSubmitInfo = .{
            .semaphore = self.transfer.semaphore,
            .value = next_val,
            .stage_mask = .{ .all_transfer_bit = true },
            .device_index = 0,
        };

        const submit_info: vk.SubmitInfo2 = .{
            .flags = .{},
            .wait_semaphore_info_count = if (current_graphics_val > 0) 1 else 0,
            .p_wait_semaphore_infos = (&wait_semaphore_info)[0..1],
            .command_buffer_info_count = @intCast(count),
            .p_command_buffer_infos = cb_submit_infos[0..count].ptr,
            .signal_semaphore_info_count = 1,
            .p_signal_semaphore_infos = (&semaphore_submit_info)[0..1],
        };

        try self.dev.queueSubmit2(self.transfer.queue, &[_]vk.SubmitInfo2{submit_info}, .null_handle);
        break :blk next_val;
    };

    var i: usize = 0;
    errdefer {
        for (i..count) |j| {
            self.pool_reservoir.returnPool(self.dev, self.submission_batch.pools[j]);
            if (self.submission_batch.opaque_meshes[j]) |r| {
                self.cpu_to_gpu_gpa.allocator().free(r.staging_slice);
                self.gpu_only_gpa.allocator().free(r.mesh.slice);
            }
            if (self.submission_batch.transparent_meshes[j]) |r| {
                self.cpu_to_gpu_gpa.allocator().free(r.staging_slice);
                self.gpu_only_gpa.allocator().free(r.mesh.slice);
            }
        }
        self.submission_batch.count = 0;
    }
    for (0..count) |j| {
        try self.pushPendingUpload(io, .{
            .chunk_pos = self.submission_batch.chunk_positions[j],
            .timeline_value = next_val,
            .pool = self.submission_batch.pools[j],
            .opaque_mesh = if (self.submission_batch.opaque_meshes[j]) |r| r.mesh else null,
            .transparent_mesh = if (self.submission_batch.transparent_meshes[j]) |r| r.mesh else null,
            .opaque_staging_slice = if (self.submission_batch.opaque_meshes[j]) |r| r.staging_slice else null,
            .transparent_staging_slice = if (self.submission_batch.transparent_meshes[j]) |r| r.staging_slice else null,
        });
        i = j + 1;
    }

    self.submission_batch.count = 0;
}

fn pushPendingUpload(self: *VulkanRenderer, io: std.Io, pending: PendingChunkUpload) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "pushPendingUpload" });
    defer zone.end();

    while (true) {
        if (try self.pending_uploads_queue.put(io, &.{pending}, 0) == 1) return;
        try self.retireCompletedUploads(io);
        try std.Io.sleep(io, .fromNanoseconds(0), .awake);
    }
}

fn vtableAddChunk(user_data: *Renderer.Implementation, io: std.Io, chunk_pos: ChunkPos, opaque_mesh: []Mesher.Face, transparent_mesh: []Mesher.Face) (std.Io.Cancelable || error{AddChunkFailed})!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    self.addChunk(io, chunk_pos, opaque_mesh, transparent_mesh) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.AddChunkFailed,
    };
}

fn destroyChunkMesh(self: *VulkanRenderer, mesh: ChunkMeshBuffer) void {
    self.gpu_only_gpa.allocator().free(mesh.slice);
}

fn destroyPendingUpload(self: *VulkanRenderer, pending: PendingChunkUpload) void {
    if (pending.opaque_mesh) |opaque_m| self.destroyChunkMesh(opaque_m);
    if (pending.transparent_mesh) |transparent| self.destroyChunkMesh(transparent);
    self.freePendingUploadStaging(pending);
}

fn freePendingUploadStaging(self: *VulkanRenderer, pending: PendingChunkUpload) void {
    if (pending.opaque_staging_slice) |slice| self.cpu_to_gpu_gpa.allocator().free(slice);
    if (pending.transparent_staging_slice) |slice| self.cpu_to_gpu_gpa.allocator().free(slice);
    if (pending.pool != .null_handle) {
        self.pool_reservoir.returnPool(self.dev, pending.pool);
    }
}

fn enqueueRetiredMesh(self: *VulkanRenderer, mesh: ChunkMeshBuffer, gpu_index: u32) !void {
    // Caller (retireCompletedUploads) already holds retire_mutex.
    // Add num_in_flight to the timeline value so we don't free the old address until
    // every frame that could have copied it into its chunk_data buffer has completed.
    const retire_frame = self.vk_ctx.frame_number.load(.acquire);
    try self.retired_meshes.append(self.allocator, .{
        .mesh = mesh,
        .gpu_index = gpu_index,
        .graphics_timeline_value = retire_frame + self.num_in_flight,
    });
}

fn retireCompletedUploads(self: *VulkanRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "retireCompletedUploads" });
    defer zone.end();

    self.retire_mutex.lockUncancelable(io);
    defer self.retire_mutex.unlock(io);

    while (true) {
        const pending = if (self.peeked_upload) |p| p else blk: {
            var buf: PendingChunkUpload = undefined;
            const got = try self.pending_uploads_queue.get(io, (&buf)[0..1], 0);
            if (got == 0) return; // Queue is empty, nothing to retire
            break :blk buf;
        };

        // Fresh read each iteration — batches submitted between iterations
        // (e.g. from addChunk flushes) may have completed by now.
        const current_transfer_val = try self.dev.getSemaphoreCounterValue(self.transfer.semaphore);

        if (current_transfer_val >= pending.timeline_value) {
            inline for (.{
                .{ .mesh = pending.opaque_mesh, .tag = .@"opaque" },
                .{ .mesh = pending.transparent_mesh, .tag = .transparent },
            }) |item| {
                const key = @unionInit(RenderBufferKey, @tagName(item.tag), pending.chunk_pos);
                if (item.mesh) |m| {
                    var new_mesh = m;
                    var gpu_idx_opt = self.index_pool.allocIndex(io);
                    if (gpu_idx_opt == null) {
                        try self.growPersistentCandidates(io);
                        gpu_idx_opt = self.index_pool.allocIndex(io);
                    }
                    const gpu_idx = gpu_idx_opt.?;
                    new_mesh.gpu_index = gpu_idx;

                    const ratio = ChunkPos.levelToBlockRatioFloat(pending.chunk_pos.level);
                    const chunk_blockpos = @as(@Vector(3, f64), @floatFromInt(pending.chunk_pos.position)) * @as(@Vector(3, f64), @splat(ratio));
                    const abs_vec: [4]f32 = .{ @floatCast(chunk_blockpos[0]), @floatCast(chunk_blockpos[1]), @floatCast(chunk_blockpos[2]), 1.0 };

                    self.persistent.mapped[gpu_idx] = .{
                        .absolute_position = abs_vec,
                        .relative_position = .{ 0, 0, 0, 0 },
                        .scale = ChunkPos.toScale(pending.chunk_pos.level),
                        .face_count = new_mesh.face_count,
                        .is_transparent = if (item.tag == .transparent) 1 else 0,
                        .address = new_mesh.device_address,
                    };

                    var current_max = self.max_allocated_index.load(.monotonic);
                    while (gpu_idx >= current_max) {
                        if (self.max_allocated_index.cmpxchgStrong(current_max, gpu_idx + 1, .release, .monotonic)) |actual_val| {
                            current_max = actual_val;
                            continue;
                        }
                        break;
                    }

                    const existing = try self.meshes.fetchPut(io, self.allocator, key, new_mesh);
                    if (existing) |old_mesh| {
                        self.persistent.mapped[old_mesh.gpu_index].face_count = 0;
                        // Defer index free: store gpu_index in the retired entry so it's only
                        // returned to the pool after the GPU has finished referencing it.
                        const old_index = old_mesh.gpu_index;
                        try self.enqueueRetiredMesh(old_mesh, old_index);
                    }
                } else {
                    const existing = self.meshes.fetchRemove(io, key);
                    if (existing) |old_mesh| {
                        self.persistent.mapped[old_mesh.gpu_index].face_count = 0;
                        const old_index = old_mesh.gpu_index;
                        try self.enqueueRetiredMesh(old_mesh, old_index);
                    }
                }
            }

            self.freePendingUploadStaging(pending);
            self.peeked_upload = null;
        } else {
            self.peeked_upload = pending;
            break;
        }
    }
}

const UploadResult = struct {
    mesh: ChunkMeshBuffer,
    staging_slice: []u8,
};

fn uploadMeshBuffer(self: *VulkanRenderer, faces: []const Mesher.Face, cmd: vk.CommandBuffer) !UploadResult {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "uploadMeshBuffer" });
    defer zone.end();

    const buffer_size: vk.DeviceSize = @intCast(faces.len * @sizeOf(Mesher.Face));

    const staging_slice = try self.cpu_to_gpu_gpa.allocator().alloc(u8, buffer_size);
    errdefer self.cpu_to_gpu_gpa.allocator().free(staging_slice);

    const dest_faces = std.mem.bytesAsSlice(Mesher.Face, staging_slice);
    const indexer = std.enums.EnumIndexer(World.Block);
    for (faces, dest_faces[0..faces.len]) |face, *dest| {
        dest.* = face;
        dest.block_type = @intCast(indexer.indexOf(@enumFromInt(face.block_type)));
    }

    const staging_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, staging_slice.ptr);

    const slice = try self.gpu_only_gpa.allocator().alloc(u8, buffer_size);
    errdefer self.gpu_only_gpa.allocator().free(slice);

    const buf_info = self.backing_allocator.getBufferAndOffset(.gpu_only, slice.ptr);
    const device_address = self.backing_allocator.getDeviceAddress(.gpu_only, slice.ptr);

    const pre_copy_barrier: vk.BufferMemoryBarrier2 = .{
        .src_stage_mask = .{ .all_transfer_bit = true },
        .src_access_mask = .{ .transfer_write_bit = true, .transfer_read_bit = true },
        .dst_stage_mask = .{ .all_transfer_bit = true },
        .dst_access_mask = .{ .transfer_write_bit = true },
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .buffer = buf_info.buffer,
        .offset = 0,
        .size = vk.WHOLE_SIZE,
    };
    const pre_dependency_info: vk.DependencyInfo = .{
        .dependency_flags = .{},
        .memory_barrier_count = 0,
        .p_memory_barriers = null,
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = (&pre_copy_barrier)[0..1],
        .image_memory_barrier_count = 0,
        .p_image_memory_barriers = null,
    };
    self.dev.cmdPipelineBarrier2(cmd, &pre_dependency_info);

    const copy_region: vk.BufferCopy2 = .{
        .src_offset = staging_info.offset,
        .dst_offset = buf_info.offset,
        .size = buffer_size,
    };
    const copy_buffer_info: vk.CopyBufferInfo2 = .{
        .src_buffer = staging_info.buffer,
        .dst_buffer = buf_info.buffer,
        .region_count = 1,
        .p_regions = (&copy_region)[0..1],
    };
    self.dev.cmdCopyBuffer2(cmd, &copy_buffer_info);

    const buffer_barrier: vk.BufferMemoryBarrier2 = .{
        .src_stage_mask = .{ .all_transfer_bit = true },
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_stage_mask = .{ .all_transfer_bit = true },
        .dst_access_mask = .{ .transfer_write_bit = true, .transfer_read_bit = true },
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .buffer = buf_info.buffer,
        .offset = buf_info.offset,
        .size = buffer_size,
    };
    const dependency_info: vk.DependencyInfo = .{
        .dependency_flags = .{},
        .memory_barrier_count = 0,
        .p_memory_barriers = null,
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = (&buffer_barrier)[0..1],
        .image_memory_barrier_count = 0,
        .p_image_memory_barriers = null,
    };
    self.dev.cmdPipelineBarrier2(cmd, &dependency_info);

    return UploadResult{
        .mesh = ChunkMeshBuffer{
            .buffer = buf_info.buffer,
            .alloc_offset = buf_info.offset,
            .alloc_size = buffer_size,
            .device_address = device_address,
            .face_count = @intCast(faces.len),
            .slice = slice,
            .gpu_index = 0,
        },
        .staging_slice = staging_slice,
    };
}

fn processPendingUploads(self: *VulkanRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "processPendingUploads" });
    defer zone.end();

    {
        const zone_mutex = tracy.Zone.begin(.{ .src = @src(), .name = "processPendingUploads_lock" });
        self.submission_batch.mutex.lockUncancelable(io);
        zone_mutex.end();
        defer self.submission_batch.mutex.unlock(io);
        try self.submitBatchLocked(io);
    }
    try self.retireCompletedUploads(io);
}

inline fn setViewportAndScissor(self: *const VulkanRenderer, cmd: vk.CommandBuffer, extent: vk.Extent2D) void {
    self.dev.cmdSetViewport(cmd, 0, &[_]vk.Viewport{.{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0.0,
        .max_depth = 1.0,
    }});
    self.dev.cmdSetScissor(cmd, 0, &[_]vk.Rect2D{.{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    }});
}

inline fn makeImageBarrier2(
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_stage: vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage: vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
    aspect: vk.ImageAspectFlags,
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
        .subresource_range = .{
            .aspect_mask = aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
}

inline fn cmdImageBarrier2(
    cmd: vk.CommandBuffer,
    dev: DeviceProxy,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_stage: vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage: vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
    aspect: vk.ImageAspectFlags,
) void {
    const barrier = makeImageBarrier2(image, old_layout, new_layout, src_stage, src_access, dst_stage, dst_access, aspect);
    dev.cmdPipelineBarrier2(cmd, &.{
        .dependency_flags = .{},
        .memory_barrier_count = 0,
        .p_memory_barriers = null,
        .buffer_memory_barrier_count = 0,
        .p_buffer_memory_barriers = null,
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = (&barrier)[0..1],
    });
}

inline fn makeBufferBarrier2(
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

inline fn destroyIfValidImageView(dev: DeviceProxy, view: *vk.ImageView) void {
    if (view.* != .null_handle) {
        dev.destroyImageView(view.*, null);
        view.* = .null_handle;
    }
}

inline fn destroyIfValidImage(dev: DeviceProxy, image: *vk.Image, memory: *vk.DeviceMemory) void {
    if (image.* != .null_handle) {
        dev.destroyImage(image.*, null);
        image.* = .null_handle;
    }
    if (memory.* != .null_handle) {
        dev.freeMemory(memory.*, null);
        memory.* = .null_handle;
    }
}

inline fn destroyIfValidPipeline(dev: DeviceProxy, pipeline: *vk.Pipeline) void {
    if (pipeline.* != .null_handle) {
        dev.destroyPipeline(pipeline.*, null);
        pipeline.* = .null_handle;
    }
}

inline fn destroyIfValidPipelineLayout(dev: DeviceProxy, layout: *vk.PipelineLayout) void {
    if (layout.* != .null_handle) {
        dev.destroyPipelineLayout(layout.*, null);
        layout.* = .null_handle;
    }
}

inline fn destroyIfValidDescriptorSetLayout(dev: DeviceProxy, layout: *vk.DescriptorSetLayout) void {
    if (layout.* != .null_handle) {
        dev.destroyDescriptorSetLayout(layout.*, null);
        layout.* = .null_handle;
    }
}

fn destroyRenderTarget(dev: DeviceProxy, rt: *RenderTarget) void {
    destroyIfValidImageView(dev, &rt.view);
    destroyIfValidImage(dev, &rt.image, &rt.memory);
}

inline fn renderingAttachmentColor(view: vk.ImageView, load_op: vk.AttachmentLoadOp, clear_color: [4]f32) vk.RenderingAttachmentInfo {
    return .{
        .s_type = .rendering_attachment_info,
        .image_view = view,
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_view = .null_handle,
        .resolve_image_layout = .undefined,
        .load_op = load_op,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = clear_color } },
    };
}

inline fn renderingAttachmentDepth(view: vk.ImageView, layout: vk.ImageLayout, load_op: vk.AttachmentLoadOp) vk.RenderingAttachmentInfo {
    return .{
        .s_type = .rendering_attachment_info,
        .image_view = view,
        .image_layout = layout,
        .resolve_mode = .{},
        .resolve_image_view = .null_handle,
        .resolve_image_layout = .undefined,
        .load_op = load_op,
        .store_op = if (load_op == .load) .none else .store,
        .clear_value = .{ .depth_stencil = .{ .depth = 0.0, .stencil = 0 } },
    };
}

inline fn renderingInfo(
    extent: vk.Extent2D,
    color_attachments: []const vk.RenderingAttachmentInfo,
    depth_attachment: ?*const vk.RenderingAttachmentInfo,
) vk.RenderingInfo {
    return .{
        .flags = .{},
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = @intCast(color_attachments.len),
        .p_color_attachments = color_attachments.ptr,
        .p_depth_attachment = depth_attachment,
        .p_stencil_attachment = null,
    };
}

inline fn shaderStageCreateInfo(stage: vk.ShaderStageFlags, module: vk.ShaderModule) vk.PipelineShaderStageCreateInfo {
    return .{
        .flags = .{},
        .stage = stage,
        .module = module,
        .p_name = "main",
        .p_specialization_info = null,
    };
}

inline fn imageViewCreateInfo(image: vk.Image, format: vk.Format, aspect: vk.ImageAspectFlags) vk.ImageViewCreateInfo {
    return .{
        .flags = .{},
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

fn createImageWithMemory(self: *VulkanRenderer, extent: vk.Extent2D, format: vk.Format, usage: vk.ImageUsageFlags, aspect: vk.ImageAspectFlags) !RenderTarget {
    const image_info: vk.ImageCreateInfo = .{
        .flags = .{},
        .image_type = .@"2d",
        .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .format = format,
        .tiling = .optimal,
        .initial_layout = .undefined,
        .usage = usage,
        .sharing_mode = .exclusive,
        .samples = .{ .@"1_bit" = true },
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    var mem_reqs2: vk.MemoryRequirements2 = .{
        .memory_requirements = undefined,
    };
    self.dev.getDeviceImageMemoryRequirements(&.{
        .p_create_info = &image_info,
        .plane_aspect = .{},
    }, &mem_reqs2);
    const mem_reqs = mem_reqs2.memory_requirements;

    const alloc_info: vk.MemoryAllocateInfo = .{
        .allocation_size = mem_reqs.size,
        .memory_type_index = try self.findMemoryType(mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    };
    const memory = try self.dev.allocateMemory(&alloc_info, null);
    errdefer self.dev.freeMemory(memory, null);

    const image = try self.dev.createImage(&image_info, null);
    errdefer self.dev.destroyImage(image, null);

    try self.dev.bindImageMemory(image, memory, 0);

    const view = try self.dev.createImageView(&imageViewCreateInfo(image, format, aspect), null);
    return .{ .image = image, .memory = memory, .view = view };
}

fn dispatchCulling(self: *VulkanRenderer, cmd_buffer: vk.CommandBuffer, current_frame: u32, frustum: Frustum, total_candidates: u32, view_pos: @Vector(3, f64)) void {
    self.dev.cmdFillBuffer(cmd_buffer, self.frame_buffers.count[current_frame], self.frame_buffers.count_offsets[current_frame], @sizeOf(CullCount), 0);

    const fill_barrier = makeBufferBarrier2(
        self.frame_buffers.count[current_frame],
        self.frame_buffers.count_offsets[current_frame],
        @sizeOf(CullCount),
        .{ .all_transfer_bit = true },
        .{ .transfer_write_bit = true },
        .{ .compute_shader_bit = true },
        .{ .shader_read_bit = true, .shader_write_bit = true },
    );
    self.dev.cmdPipelineBarrier2(cmd_buffer, &.{
        .dependency_flags = .{},
        .memory_barrier_count = 0,
        .p_memory_barriers = null,
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = (&fill_barrier)[0..1],
        .image_memory_barrier_count = 0,
        .p_image_memory_barriers = null,
    });

    self.dev.cmdBindPipeline(cmd_buffer, .compute, self.cull.pipeline);
    self.dev.cmdBindDescriptorSets(cmd_buffer, .compute, self.cull.pipeline_layout, 0, (&self.cull.descriptor_sets_per_frame[current_frame])[0..1], null);

    var push_consts: extern struct {
        planes: [6][4]f32,
        player_pos: [4]f32 align(16),
        total_candidates: u32,
        draw_capacity: u32,
    } = undefined;
    for (frustum.planes, 0..) |plane, idx| {
        push_consts.planes[idx] = plane;
    }
    push_consts.player_pos = .{
        @floatCast(view_pos[0]),
        @floatCast(view_pos[1]),
        @floatCast(view_pos[2]),
        1.0,
    };
    push_consts.total_candidates = total_candidates;
    push_consts.draw_capacity = self.draw_capacity;

    self.dev.cmdPushConstants(cmd_buffer, self.cull.pipeline_layout, .{ .compute_bit = true }, 0, @sizeOf(@TypeOf(push_consts)), &push_consts);

    const group_count = (total_candidates + (cull_workgroup_size - 1)) / cull_workgroup_size;
    self.dev.cmdDispatch(cmd_buffer, group_count, 1, 1);

    const buffer_barriers: [3]vk.BufferMemoryBarrier2 = .{
        makeBufferBarrier2(self.frame_buffers.indirect_draw[current_frame], self.frame_buffers.indirect_draw_offsets[current_frame], self.draw_capacity * draw_type_count * @sizeOf(vk.DrawIndirectCommand), .{ .compute_shader_bit = true }, .{ .shader_write_bit = true }, .{ .draw_indirect_bit = true }, .{ .indirect_command_read_bit = true }),
        makeBufferBarrier2(self.frame_buffers.chunk_data[current_frame], self.frame_buffers.chunk_data_offsets[current_frame], self.draw_capacity * draw_type_count * @sizeOf(ChunkData), .{ .compute_shader_bit = true }, .{ .shader_write_bit = true }, .{ .vertex_shader_bit = true }, .{ .shader_read_bit = true }),
        makeBufferBarrier2(self.frame_buffers.count[current_frame], self.frame_buffers.count_offsets[current_frame], @sizeOf(CullCount), .{ .compute_shader_bit = true }, .{ .shader_write_bit = true }, .{ .draw_indirect_bit = true, .all_transfer_bit = true }, .{ .indirect_command_read_bit = true, .transfer_read_bit = true }),
    };
    self.dev.cmdPipelineBarrier2(cmd_buffer, &.{
        .dependency_flags = .{},
        .memory_barrier_count = 0,
        .p_memory_barriers = null,
        .buffer_memory_barrier_count = buffer_barriers.len,
        .p_buffer_memory_barriers = &buffer_barriers,
        .image_memory_barrier_count = 0,
        .p_image_memory_barriers = null,
    });

    const region: vk.BufferCopy = .{
        .src_offset = self.frame_buffers.count_offsets[current_frame],
        .dst_offset = self.frame_buffers.stats_offsets[current_frame],
        .size = @sizeOf(CullCount),
    };
    self.dev.cmdCopyBuffer(cmd_buffer, self.frame_buffers.count[current_frame], self.frame_buffers.stats[current_frame], (&region)[0..1]);

    const host_barrier = makeBufferBarrier2(
        self.frame_buffers.stats[current_frame],
        self.frame_buffers.stats_offsets[current_frame],
        @sizeOf(CullCount),
        .{ .all_transfer_bit = true },
        .{ .transfer_write_bit = true },
        .{ .host_bit = true },
        .{ .host_read_bit = true },
    );
    self.dev.cmdPipelineBarrier2(cmd_buffer, &.{
        .dependency_flags = .{},
        .memory_barrier_count = 0,
        .p_memory_barriers = null,
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = (&host_barrier)[0..1],
        .image_memory_barrier_count = 0,
        .p_image_memory_barriers = null,
    });
}

fn recordOpaquePass(
    self: *VulkanRenderer,
    cmd_buffer: vk.CommandBuffer,
    extent: vk.Extent2D,
    current_frame: u32,
    total_candidates: u32,
    pc: PushConstants,
    sky_color: @Vector(4, f32),
    view_pos: @Vector(3, f64),
    frustum: Frustum,
    depth_aspect_mask: vk.ImageAspectFlags,
) void {
    // Frame-start synchronization to prevent cross-frame race conditions on the shared render targets.
    const pre_dispatch_mem_barrier: vk.MemoryBarrier2 = .{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
    };
    const color_aspect: vk.ImageAspectFlags = .{ .color_bit = true };
    const pre_dispatch_img_barriers: [4]vk.ImageMemoryBarrier2 = .{
        makeImageBarrier2(
            self.render_color.image,
            .undefined,
            .color_attachment_optimal,
            .{ .all_commands_bit = true },
            .{ .memory_read_bit = true, .memory_write_bit = true },
            .{ .color_attachment_output_bit = true },
            .{ .color_attachment_write_bit = true },
            color_aspect,
        ),
        makeImageBarrier2(
            self.oit.accum.image,
            .undefined,
            .color_attachment_optimal,
            .{ .all_commands_bit = true },
            .{ .memory_read_bit = true, .memory_write_bit = true },
            .{ .color_attachment_output_bit = true },
            .{ .color_attachment_write_bit = true },
            color_aspect,
        ),
        makeImageBarrier2(
            self.oit.reveal.image,
            .undefined,
            .color_attachment_optimal,
            .{ .all_commands_bit = true },
            .{ .memory_read_bit = true, .memory_write_bit = true },
            .{ .color_attachment_output_bit = true },
            .{ .color_attachment_write_bit = true },
            color_aspect,
        ),
        makeImageBarrier2(
            self.render_depth.image,
            .undefined,
            .depth_stencil_attachment_optimal,
            .{ .all_commands_bit = true },
            .{ .memory_read_bit = true, .memory_write_bit = true },
            .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
            .{ .depth_stencil_attachment_write_bit = true },
            depth_aspect_mask,
        ),
    };
    self.dev.cmdPipelineBarrier2(cmd_buffer, &.{
        .dependency_flags = .{},
        .memory_barrier_count = 1,
        .p_memory_barriers = (&pre_dispatch_mem_barrier)[0..1],
        .buffer_memory_barrier_count = 0,
        .p_buffer_memory_barriers = null,
        .image_memory_barrier_count = pre_dispatch_img_barriers.len,
        .p_image_memory_barriers = &pre_dispatch_img_barriers,
    });

    if (total_candidates > 0) {
        self.dispatchCulling(cmd_buffer, current_frame, frustum, total_candidates, view_pos);
    }

    const color_attachment = renderingAttachmentColor(self.render_color.view, .clear, .{ sky_color[0], sky_color[1], sky_color[2], sky_color[3] });
    const depth_attachment = renderingAttachmentDepth(self.render_depth.view, .depth_stencil_attachment_optimal, .clear);

    self.dev.cmdBeginRendering(cmd_buffer, &renderingInfo(extent, &.{color_attachment}, &depth_attachment));

    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.graphics_state.pipeline);

    self.dev.cmdSetCullMode(cmd_buffer, .{ .back_bit = true });
    self.dev.cmdSetDepthCompareOp(cmd_buffer, .greater);
    self.dev.cmdSetDepthWriteEnable(cmd_buffer, .true);

    self.setViewportAndScissor(cmd_buffer, extent);

    const buffer_info: vk.DescriptorBufferInfo = .{
        .buffer = self.frame_buffers.chunk_data[current_frame],
        .offset = self.frame_buffers.chunk_data_offsets[current_frame],
        .range = self.draw_capacity * draw_type_count * @sizeOf(ChunkData),
    };
    const texture_image_info: vk.DescriptorImageInfo = .{
        .image_layout = .shader_read_only_optimal,
        .image_view = self.texture_manager.texture_view,
        .sampler = self.texture_manager.sampler,
    };
    const dummy_image_info: vk.DescriptorImageInfo = .{ .sampler = .null_handle, .image_view = .null_handle, .image_layout = .undefined };
    const dummy_buffer_info: vk.DescriptorBufferInfo = .{ .buffer = .null_handle, .offset = 0, .range = 0 };
    const dummy_texel_buffer_view: vk.BufferView = .null_handle;
    const writes: [2]vk.WriteDescriptorSet = .{
        .{
            .dst_set = .null_handle,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = (&dummy_image_info)[0..1],
            .p_buffer_info = (&buffer_info)[0..1],
            .p_texel_buffer_view = (&dummy_texel_buffer_view)[0..1],
        },
        .{
            .dst_set = .null_handle,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = (&texture_image_info)[0..1],
            .p_buffer_info = (&dummy_buffer_info)[0..1],
            .p_texel_buffer_view = (&dummy_texel_buffer_view)[0..1],
        },
    };
    self.dev.cmdPushDescriptorSetKHR(cmd_buffer, .graphics, self.graphics_state.opaque_pipeline_layout, 0, &writes);

    self.dev.cmdPushConstants(cmd_buffer, self.graphics_state.opaque_pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(PushConstants), &pc);

    if (total_candidates > 0) {
        const opaque_byte_offset: vk.DeviceSize = self.frame_buffers.indirect_draw_offsets[current_frame];
        const opaque_count_byte_offset: vk.DeviceSize = self.frame_buffers.count_offsets[current_frame];

        self.dev.cmdDrawIndirectCount(
            cmd_buffer,
            self.frame_buffers.indirect_draw[current_frame],
            opaque_byte_offset,
            self.frame_buffers.count[current_frame],
            opaque_count_byte_offset,
            self.draw_capacity,
            @sizeOf(vk.DrawIndirectCommand),
        );
    }

    self.dev.cmdEndRendering(cmd_buffer);
    cmdImageBarrier2(
        cmd_buffer,
        self.dev,
        self.render_depth.image,
        .depth_stencil_attachment_optimal,
        .depth_stencil_read_only_optimal,
        .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .{ .depth_stencil_attachment_write_bit = true },
        .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true, .fragment_shader_bit = true },
        .{ .depth_stencil_attachment_read_bit = true, .shader_read_bit = true },
        depth_aspect_mask,
    );
}

fn recordTransparentPass(
    self: *VulkanRenderer,
    cmd_buffer: vk.CommandBuffer,
    extent: vk.Extent2D,
    current_frame: u32,
    total_candidates: u32,
    pc: PushConstants,
) void {
    const oit_accum_attachment = renderingAttachmentColor(self.oit.accum.view, .clear, .{ 0.0, 0.0, 0.0, 1.0 });
    const oit_reveal_attachment = renderingAttachmentColor(self.oit.reveal.view, .clear, .{ 0.0, 0.0, 0.0, 0.0 });
    const oit_depth_attachment = renderingAttachmentDepth(self.render_depth.view, .depth_stencil_read_only_optimal, .load);
    self.dev.cmdBeginRendering(cmd_buffer, &renderingInfo(extent, &.{ oit_accum_attachment, oit_reveal_attachment }, &oit_depth_attachment));

    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.graphics_state.transparent_pipeline);

    self.dev.cmdSetCullMode(cmd_buffer, .{});
    self.dev.cmdSetDepthCompareOp(cmd_buffer, .greater_or_equal);
    self.dev.cmdSetDepthWriteEnable(cmd_buffer, .false);
    self.setViewportAndScissor(cmd_buffer, extent);

    const buffer_info: vk.DescriptorBufferInfo = .{
        .buffer = self.frame_buffers.chunk_data[current_frame],
        .offset = self.frame_buffers.chunk_data_offsets[current_frame],
        .range = self.draw_capacity * draw_type_count * @sizeOf(ChunkData),
    };
    const texture_image_info: vk.DescriptorImageInfo = .{
        .image_layout = .shader_read_only_optimal,
        .image_view = self.texture_manager.texture_view,
        .sampler = self.texture_manager.sampler,
    };
    const depth_image_info: vk.DescriptorImageInfo = .{
        .image_layout = .depth_stencil_read_only_optimal,
        .image_view = self.render_depth_sampled_view,
        .sampler = self.texture_manager.sampler,
    };
    const dummy_image_info: vk.DescriptorImageInfo = .{ .sampler = .null_handle, .image_view = .null_handle, .image_layout = .undefined };
    const dummy_buffer_info: vk.DescriptorBufferInfo = .{ .buffer = .null_handle, .offset = 0, .range = 0 };
    const dummy_texel_buffer_view: vk.BufferView = .null_handle;
    const writes: [3]vk.WriteDescriptorSet = .{
        .{
            .dst_set = .null_handle,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = (&dummy_image_info)[0..1],
            .p_buffer_info = (&buffer_info)[0..1],
            .p_texel_buffer_view = (&dummy_texel_buffer_view)[0..1],
        },
        .{
            .dst_set = .null_handle,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = (&texture_image_info)[0..1],
            .p_buffer_info = (&dummy_buffer_info)[0..1],
            .p_texel_buffer_view = (&dummy_texel_buffer_view)[0..1],
        },
        .{
            .dst_set = .null_handle,
            .dst_binding = 2,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = (&depth_image_info)[0..1],
            .p_buffer_info = (&dummy_buffer_info)[0..1],
            .p_texel_buffer_view = (&dummy_texel_buffer_view)[0..1],
        },
    };
    self.dev.cmdPushDescriptorSetKHR(cmd_buffer, .graphics, self.graphics_state.transparent_pipeline_layout, 0, &writes);
    self.dev.cmdPushConstants(cmd_buffer, self.graphics_state.transparent_pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(PushConstants), &pc);

    if (total_candidates > 0) {
        const transparent_byte_offset: vk.DeviceSize = self.frame_buffers.indirect_draw_offsets[current_frame] + @as(vk.DeviceSize, @intCast(self.draw_capacity * @sizeOf(vk.DrawIndirectCommand)));
        const transparent_count_byte_offset: vk.DeviceSize = self.frame_buffers.count_offsets[current_frame] + @as(vk.DeviceSize, 4);

        self.dev.cmdDrawIndirectCount(
            cmd_buffer,
            self.frame_buffers.indirect_draw[current_frame],
            transparent_byte_offset,
            self.frame_buffers.count[current_frame],
            transparent_count_byte_offset,
            self.draw_capacity,
            @sizeOf(vk.DrawIndirectCommand),
        );
    }

    self.dev.cmdEndRendering(cmd_buffer);
}

fn recordCompositionPass(
    self: *VulkanRenderer,
    cmd_buffer: vk.CommandBuffer,
    extent: vk.Extent2D,
    output_image: vk.Image,
    output_view: vk.ImageView,
    current_frame: u32,
    depth_aspect_mask: vk.ImageAspectFlags,
) void {
    _ = depth_aspect_mask;
    const color_aspect: vk.ImageAspectFlags = .{ .color_bit = true };
    const pre_comp_barriers: [4]vk.ImageMemoryBarrier2 = .{
        makeImageBarrier2(self.render_color.image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true }, color_aspect),
        makeImageBarrier2(self.oit.accum.image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true }, color_aspect),
        makeImageBarrier2(self.oit.reveal.image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true }, color_aspect),
        makeImageBarrier2(output_image, .undefined, .color_attachment_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, color_aspect),
    };
    self.dev.cmdPipelineBarrier2(cmd_buffer, &.{
        .dependency_flags = .{},
        .memory_barrier_count = 0,
        .p_memory_barriers = null,
        .buffer_memory_barrier_count = 0,
        .p_buffer_memory_barriers = null,
        .image_memory_barrier_count = pre_comp_barriers.len,
        .p_image_memory_barriers = &pre_comp_barriers,
    });

    const swapchain_attachment = renderingAttachmentColor(output_view, .dont_care, .{ 0.0, 0.0, 0.0, 0.0 });
    self.dev.cmdBeginRendering(cmd_buffer, &renderingInfo(extent, &.{swapchain_attachment}, null));

    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.oit.composition_pipeline);
    self.setViewportAndScissor(cmd_buffer, extent);

    const oit_desc_set: vk.DescriptorSet = self.oit.descriptor_sets_per_frame[current_frame];
    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.oit.composition_layout, 0, (&oit_desc_set)[0..1], null);
    self.dev.cmdDraw(cmd_buffer, 3, 1, 0, 0);

    self.dev.cmdEndRendering(cmd_buffer);

    const post_comp_barriers: [1]vk.ImageMemoryBarrier2 = .{
        makeImageBarrier2(output_image, .color_attachment_optimal, .present_src_khr, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true }, .{ .color_attachment_read_bit = true }, color_aspect),
    };
    self.dev.cmdPipelineBarrier2(cmd_buffer, &.{
        .dependency_flags = .{},
        .memory_barrier_count = 0,
        .p_memory_barriers = null,
        .buffer_memory_barrier_count = 0,
        .p_buffer_memory_barriers = null,
        .image_memory_barrier_count = post_comp_barriers.len,
        .p_image_memory_barriers = &post_comp_barriers,
    });
}

pub fn draw(self: *VulkanRenderer, io: std.Io, target: Renderer.DrawTarget, view_pos: @Vector(3, f64)) !void {
    const c = tracy.Zone.begin(.{ .src = @src() });
    defer c.end();

    try self.processPendingUploads(io);
    try self.processRetiredMeshes(io);

    const current_frame = self.current_frame;
    const cmd_buffer = self.output_cmd_buffer;
    const extent: vk.Extent2D = .{ .width = target.width, .height = target.height };

    if (self.frame_buffers.stats_mapped[current_frame]) |counts_ptr| {
        const opaque_count = counts_ptr[0].opaque_count;
        const transparent_count = counts_ptr[0].transparent_count;
        const total_count = @as(u32, @intCast(self.meshes.count(io)));
        self.frame_stats.opaque_drawn = opaque_count;
        self.frame_stats.transparent_drawn = transparent_count;
        self.frame_stats.opaque_candidates = total_count;
        self.frame_stats.transparent_candidates = total_count;
        self.frame_stats.opaque_culled = total_count -| opaque_count;
        self.frame_stats.transparent_culled = total_count -| transparent_count;
    }

    const aspect = @as(f32, @floatFromInt(target.width)) / @as(f32, @floatFromInt(target.height));

    {
        const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "draw_lock_render_options" });
        self.render_options_lock.lockSharedUncancelable(io);
        zone_lock.end();
    }
    const fov = std.math.degreesToRadians(self.render_options.fov);
    const day_length_sec = self.render_options.day_length_sec;
    self.render_options_lock.unlockShared(io);

    const vp = self.computeViewProjection(aspect, fov);
    const blue_sky = @Vector(4, f32){ 0.0, 0.4, 0.8, 1.0 };
    const grey_sky = @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 };
    const sky_color = std.math.lerp(blue_sky, grey_sky, @as(@Vector(4, f32), @splat(@floatCast(@min(1.0, @max(0.0, view_pos[1] / sky_height))))));
    const sun_dir = computeSunDirection(io, day_length_sec);
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const elapsed_sec = @as(f32, @floatFromInt(now_ns -| self.init_time_ns)) / std.time.ns_per_s;

    const total_meshes = self.meshes.count(io);
    if (total_meshes > self.draw_capacity) {
        try self.growDrawCapacity(io, @intCast(total_meshes));
    }

    var pc: PushConstants = .{
        .projview = @splat(0),
        .sun_dir = sun_dir,
        .time = elapsed_sec,
    };
    inline for (0..4) |row| {
        inline for (0..4) |col| {
            pc.projview[row * 4 + col] = @as([4][4]f32, @bitCast(vp.projview))[col][row];
        }
    }

    const total_candidates = self.max_allocated_index.load(.monotonic);

    const begin_info: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };
    try self.dev.beginCommandBuffer(cmd_buffer, &begin_info);

    const depth_aspect_mask: vk.ImageAspectFlags = if (self.depthHasStencil()) .{ .depth_bit = true, .stencil_bit = true } else .{ .depth_bit = true };
    const frame_start_ns = std.Io.Timestamp.now(io, .real).nanoseconds;

    self.recordOpaquePass(cmd_buffer, extent, current_frame, total_candidates, pc, sky_color, view_pos, vp.frustum, depth_aspect_mask);
    self.recordTransparentPass(cmd_buffer, extent, current_frame, total_candidates, pc);

    const frame_end_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const frame_elapsed_ns: u64 = @intCast(@max(0, frame_end_ns - frame_start_ns));

    const frame_num = self.vk_ctx.frame_number.load(.monotonic) + 1;
    self.vk_ctx.frame_number.store(frame_num, .release);
    self.frame_stats.frame_number = frame_num;
    self.frame_stats.total_meshes = @intCast(self.meshes.count(io));
    self.frame_stats.player_pos = view_pos;
    self.frame_stats.camera_front = .{
        self.camera_front_x.load(.monotonic),
        self.camera_front_y.load(.monotonic),
        self.camera_front_z.load(.monotonic),
    };
    self.frame_stats.elapsed_ns = frame_elapsed_ns;

    if (frame_num % 60 == 0) {
        self.frame_stats.log();
    }

    self.recordCompositionPass(cmd_buffer, extent, self.output_color_image, self.output_color_view, current_frame, depth_aspect_mask);

    try self.dev.endCommandBuffer(cmd_buffer);
}

fn vtableDrawChunks(user_data: *Renderer.Implementation, io: std.Io, target: Renderer.DrawTarget, view_pos: @Vector(3, f64)) (std.Io.Cancelable || error{DrawFailed})!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    self.draw(io, target, view_pos) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.DrawFailed,
    };
}

fn growDrawCapacity(self: *VulkanRenderer, io: std.Io, min_capacity: u32) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "growDrawCapacity" });
    defer zone.end();

    if (min_capacity <= self.draw_capacity) return;

    var new_capacity = self.draw_capacity;
    while (new_capacity < min_capacity) {
        new_capacity *= 2;
    }
    // Clamp to device limit: maxDrawCount in vkCmdDrawIndirectCount must be ≤ maxDrawIndirectCount.
    const clamped_capacity = @min(new_capacity, self.max_draw_indirect_count);
    if (clamped_capacity < new_capacity) {
        std.log.warn("VulkanRenderer: draw capacity clamped to device limit {d} (requested {d}). Some chunks may not render!", .{ self.max_draw_indirect_count, new_capacity });
    }
    new_capacity = clamped_capacity;

    std.log.info("VulkanRenderer: Growing draw capacity from {d} to {d} for all frames...", .{ self.draw_capacity, new_capacity });

    self.vk_ctx.queue_mutex.lockUncancelable(io);
    try self.dev.deviceWaitIdle();
    defer self.vk_ctx.queue_mutex.unlock(io);

    const old_draw_capacity = self.draw_capacity;
    const num_frames = self.frame_buffers.indirect_draw_mapped.len;

    // Save old pointers before any modifications (Stage 1 — record)
    const OldFrame = struct {
        chunk_data_ptr: [*]ChunkData,
        indirect_ptr: [*]vk.DrawIndirectCommand,
        count_slice: []align(cull_buffer_alignment.toByteUnits()) CullCount,
        stats_slice: []align(cull_buffer_alignment.toByteUnits()) CullCount,
    };
    const NewFrame = struct {
        chunk_data_slice: []ChunkData,
        indirect_draw_slice: []vk.DrawIndirectCommand,
        count_slice: []align(cull_buffer_alignment.toByteUnits()) CullCount,
        stats_slice: []align(cull_buffer_alignment.toByteUnits()) CullCount,
    };

    var old_frames: [32]OldFrame = undefined;
    var new_frames: [32]NewFrame = undefined;

    for (0..num_frames) |i| {
        old_frames[i] = .{
            .chunk_data_ptr = self.frame_buffers.chunk_data_mapped[i].?,
            .indirect_ptr = self.frame_buffers.indirect_draw_mapped[i].?,
            .count_slice = self.frame_buffers.count_slices[i],
            .stats_slice = self.frame_buffers.stats_slices[i],
        };
    }

    // Allocate all new buffers (can fail — clean up on error)
    var frames_allocated: u32 = 0;
    errdefer {
        for (0..frames_allocated) |j| {
            self.cpu_to_gpu_gpa.allocator().free(new_frames[j].chunk_data_slice);
            self.cpu_to_gpu_gpa.allocator().free(new_frames[j].indirect_draw_slice);
            self.gpu_only_gpa.allocator().free(new_frames[j].count_slice);
            self.cpu_to_gpu_gpa.allocator().free(new_frames[j].stats_slice);
        }
    }

    for (0..num_frames) |i| {
        new_frames[i] = .{
            .chunk_data_slice = try self.cpu_to_gpu_gpa.allocator().alloc(ChunkData, new_capacity * draw_type_count),
            .indirect_draw_slice = try self.cpu_to_gpu_gpa.allocator().alloc(vk.DrawIndirectCommand, new_capacity * draw_type_count),
            .count_slice = try self.gpu_only_gpa.allocator().alignedAlloc(CullCount, cull_buffer_alignment, 1),
            .stats_slice = try self.cpu_to_gpu_gpa.allocator().alignedAlloc(CullCount, cull_buffer_alignment, 1),
        };
        @memset(new_frames[i].stats_slice, .{ .opaque_count = 0, .transparent_count = 0 });

        if (old_draw_capacity > 0) {
            @memcpy(
                new_frames[i].chunk_data_slice[0 .. old_draw_capacity * draw_type_count],
                old_frames[i].chunk_data_ptr[0 .. old_draw_capacity * draw_type_count],
            );
            @memcpy(
                new_frames[i].indirect_draw_slice[0 .. old_draw_capacity * draw_type_count],
                old_frames[i].indirect_ptr[0 .. old_draw_capacity * draw_type_count],
            );
        }
        frames_allocated += 1;
    }

    // Stage 2 — update state and free old (infallible — all new buffers already allocated)
    for (0..num_frames) |i| {
        const chunk_data_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, new_frames[i].chunk_data_slice.ptr);
        const indirect_draw_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, new_frames[i].indirect_draw_slice.ptr);
        const count_info = self.backing_allocator.getBufferAndOffset(.gpu_only, new_frames[i].count_slice.ptr);
        const stats_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, new_frames[i].stats_slice.ptr);

        self.frame_buffers.chunk_data[i] = chunk_data_info.buffer;
        self.frame_buffers.chunk_data_mapped[i] = new_frames[i].chunk_data_slice.ptr;
        self.frame_buffers.chunk_data_offsets[i] = chunk_data_info.offset;

        self.frame_buffers.indirect_draw[i] = indirect_draw_info.buffer;
        self.frame_buffers.indirect_draw_mapped[i] = new_frames[i].indirect_draw_slice.ptr;
        self.frame_buffers.indirect_draw_offsets[i] = indirect_draw_info.offset;

        self.frame_buffers.count[i] = count_info.buffer;
        self.frame_buffers.count_slices[i] = new_frames[i].count_slice;
        self.frame_buffers.count_offsets[i] = count_info.offset;

        self.frame_buffers.stats[i] = stats_info.buffer;
        self.frame_buffers.stats_slices[i] = new_frames[i].stats_slice;
        self.frame_buffers.stats_offsets[i] = stats_info.offset;
        self.frame_buffers.stats_mapped[i] = new_frames[i].stats_slice.ptr;

        // Free old buffers now that new ones are in place
        self.cpu_to_gpu_gpa.allocator().free(old_frames[i].chunk_data_ptr[0 .. old_draw_capacity * draw_type_count]);
        self.cpu_to_gpu_gpa.allocator().free(old_frames[i].indirect_ptr[0 .. old_draw_capacity * draw_type_count]);
        self.gpu_only_gpa.allocator().free(old_frames[i].count_slice);
        self.cpu_to_gpu_gpa.allocator().free(old_frames[i].stats_slice);
    }

    // Stage 3 — update draw_capacity only after ALL frames are successfully migrated
    self.draw_capacity = new_capacity;

    // Stage 4 — update descriptors with the correct (new) draw_capacity
    for (0..num_frames) |i| {
        self.updateCullDescriptorSet(@intCast(i));
    }
}

fn growPersistentCandidates(self: *VulkanRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "growPersistentCandidates" });
    defer zone.end();

    const old_capacity = self.persistent.slice.len;
    const new_capacity = old_capacity * 2;
    std.log.info("VulkanRenderer: Growing persistent GPU scene candidates from {d} to {d}...", .{ old_capacity, new_capacity });

    self.vk_ctx.queue_mutex.lockUncancelable(io);
    try self.dev.deviceWaitIdle();
    defer self.vk_ctx.queue_mutex.unlock(io);

    const new_slice = try self.cpu_to_gpu_gpa.allocator().alloc(InputChunk, new_capacity);
    @memset(new_slice, .{
        .absolute_position = .{ 0, 0, 0, 0 },
        .relative_position = .{ 0, 0, 0, 0 },
        .scale = 0,
        .face_count = 0,
        .is_transparent = 0,
        .address = 0,
    });

    @memcpy(new_slice[0..old_capacity], self.persistent.slice[0..old_capacity]);

    const info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, new_slice.ptr);
    const old_slice = self.persistent.slice;

    self.persistent.buffer = info.buffer;
    self.persistent.mapped = @ptrCast(new_slice.ptr);
    self.persistent.offset = info.offset;
    self.persistent.slice = new_slice;

    const current_frame_num = self.vk_ctx.frame_number.load(.monotonic);
    {
        try self.retired_candidate_slices.append(self.allocator, .{
            .slice = old_slice,
            .graphics_timeline_value = current_frame_num + self.num_in_flight,
        });
    }

    try self.index_pool.grow(io, self.allocator, @intCast(new_capacity));

    const num_frames = self.vk_ctx.swapchain_images.len;
    for (0..num_frames) |i| {
        self.updateCullDescriptorSet(@intCast(i));
    }
}

pub fn findMemoryType(self: *const VulkanRenderer, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    return findMemoryTypeRaw(self.vk_ctx.mem_props, type_filter, properties);
}

pub inline fn depthHasStencil(self: *const VulkanRenderer) bool {
    return self.depth_format == .d32_sfloat_s8_uint or self.depth_format == .d24_unorm_s8_uint;
}

fn destroyOitResources(self: *VulkanRenderer) void {
    destroyRenderTarget(self.dev, &self.oit.accum);
    destroyRenderTarget(self.dev, &self.oit.reveal);

    if (self.oit.descriptor_pool != .null_handle) {
        self.dev.destroyDescriptorPool(self.oit.descriptor_pool, null);
        self.oit.descriptor_pool = .null_handle;
    }
    if (self.oit.descriptor_sets_per_frame.len > 0) {
        self.allocator.free(self.oit.descriptor_sets_per_frame);
        self.oit.descriptor_sets_per_frame = &.{};
    }
}

fn createRenderTargets(self: *VulkanRenderer, extent: vk.Extent2D) !void {
    destroyRenderTarget(self.dev, &self.render_color);
    destroyRenderTarget(self.dev, &self.render_depth);
    destroyIfValidImageView(self.dev, &self.render_depth_sampled_view);
    self.destroyOitResources();

    errdefer {
        destroyRenderTarget(self.dev, &self.render_color);
        destroyRenderTarget(self.dev, &self.render_depth);
        destroyIfValidImageView(self.dev, &self.render_depth_sampled_view);
        self.destroyOitResources();
    }

    const color = try self.createImageWithMemory(extent, self.vk_ctx.swapchain_format, .{ .color_attachment_bit = true, .transfer_src_bit = true, .sampled_bit = true }, .{ .color_bit = true });
    self.render_color = color;

    {
        const cmd = try self.beginSingleTimeCommands();
        cmdImageBarrier2(
            cmd,
            self.dev,
            self.render_color.image,
            .undefined,
            .color_attachment_optimal,
            .{ .top_of_pipe_bit = true },
            .{},
            .{ .color_attachment_output_bit = true },
            .{ .color_attachment_write_bit = true },
            .{ .color_bit = true },
        );
        try self.endSingleTimeCommandsLocked(cmd);
    }

    const depth_formats: [3]vk.Format = .{ .d32_sfloat_s8_uint, .d24_unorm_s8_uint, .d32_sfloat };
    var depth_format: vk.Format = .undefined;
    for (depth_formats) |fmt| {
        if (self.vk_ctx.instance.getPhysicalDeviceFormatProperties(self.vk_ctx.pdev, fmt).optimal_tiling_features.depth_stencil_attachment_bit) {
            depth_format = fmt;
            self.depth_format = fmt;
            break;
        }
    }
    if (depth_format == .undefined) return error.DepthFormatNotSupported;

    const depth_aspect_mask: vk.ImageAspectFlags = if (self.depthHasStencil()) .{ .depth_bit = true, .stencil_bit = true } else .{ .depth_bit = true };
    const depth = try self.createImageWithMemory(extent, depth_format, .{ .depth_stencil_attachment_bit = true, .sampled_bit = true }, depth_aspect_mask);
    self.render_depth = depth;
    self.render_depth_sampled_view = try self.dev.createImageView(&imageViewCreateInfo(depth.image, depth_format, .{ .depth_bit = true }), null);

    {
        const cmd = try self.beginSingleTimeCommands();
        cmdImageBarrier2(
            cmd,
            self.dev,
            self.render_depth.image,
            .undefined,
            .depth_stencil_attachment_optimal,
            .{ .top_of_pipe_bit = true },
            .{},
            .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
            .{ .depth_stencil_attachment_write_bit = true },
            depth_aspect_mask,
        );
        try self.endSingleTimeCommandsLocked(cmd);
    }

    const oit_usage: vk.ImageUsageFlags = .{ .color_attachment_bit = true, .sampled_bit = true };
    const oit_aspect: vk.ImageAspectFlags = .{ .color_bit = true };
    const accum = try self.createImageWithMemory(extent, .r16g16b16a16_sfloat, oit_usage, oit_aspect);
    self.oit.accum = accum;
    const reveal = try self.createImageWithMemory(extent, .r16g16b16a16_sfloat, oit_usage, oit_aspect);
    self.oit.reveal = reveal;

    {
        const cmd = try self.beginSingleTimeCommands();
        cmdImageBarrier2(
            cmd,
            self.dev,
            self.oit.accum.image,
            .undefined,
            .color_attachment_optimal,
            .{ .top_of_pipe_bit = true },
            .{},
            .{ .color_attachment_output_bit = true },
            .{ .color_attachment_write_bit = true },
            oit_aspect,
        );
        cmdImageBarrier2(
            cmd,
            self.dev,
            self.oit.reveal.image,
            .undefined,
            .color_attachment_optimal,
            .{ .top_of_pipe_bit = true },
            .{},
            .{ .color_attachment_output_bit = true },
            .{ .color_attachment_write_bit = true },
            oit_aspect,
        );
        try self.endSingleTimeCommandsLocked(cmd);
    }

    if (self.oit.descriptor_sets_per_frame.len > 0) {
        self.updateOitDescriptorSets();
    }

    std.log.info("VulkanRenderer.createRenderTargets: SUCCESS - Created render targets: color {any}, depth {any}, accum {any}, reveal {any}\n", .{ self.render_color.image, self.render_depth.image, self.oit.accum.image, self.oit.reveal.image });
}

fn createOpaqueDescriptorSetLayout(self: *VulkanRenderer) !void {
    if (self.graphics_state.opaque_descriptor_set_layout == .null_handle) {
        const bindings: [2]vk.DescriptorSetLayoutBinding = .{
            .{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .vertex_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
        };
        var layout_info: vk.DescriptorSetLayoutCreateInfo = .{ .flags = .{ .push_descriptor_bit = true }, .binding_count = bindings.len, .p_bindings = bindings[0..] };
        self.graphics_state.opaque_descriptor_set_layout = try self.dev.createDescriptorSetLayout(&layout_info, null);
    }
}

fn createTransparentDescriptorSetLayout(self: *VulkanRenderer) !void {
    if (self.graphics_state.transparent_descriptor_set_layout == .null_handle) {
        const bindings: [3]vk.DescriptorSetLayoutBinding = .{
            .{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .vertex_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 2, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
        };
        var layout_info: vk.DescriptorSetLayoutCreateInfo = .{ .flags = .{ .push_descriptor_bit = true }, .binding_count = bindings.len, .p_bindings = bindings[0..] };
        self.graphics_state.transparent_descriptor_set_layout = try self.dev.createDescriptorSetLayout(&layout_info, null);
    }
}

fn createCullDescriptorSetLayoutAndPool(self: *VulkanRenderer) !void {
    if (self.cull.descriptor_set_layout == .null_handle) {
        const bindings: [4]vk.DescriptorSetLayoutBinding = .{
            .{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 3, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
        };
        const layout_info: vk.DescriptorSetLayoutCreateInfo = .{ .flags = .{}, .binding_count = bindings.len, .p_bindings = bindings[0..] };
        self.cull.descriptor_set_layout = try self.dev.createDescriptorSetLayout(&layout_info, null);
    }

    const num_frames = self.vk_ctx.swapchain_images.len;
    const pool_sizes: [1]vk.DescriptorPoolSize = .{
        .{ .type = .storage_buffer, .descriptor_count = @intCast(num_frames * 4) },
    };
    const pool_info: vk.DescriptorPoolCreateInfo = .{
        .flags = .{},
        .max_sets = @intCast(num_frames),
        .pool_size_count = pool_sizes.len,
        .p_pool_sizes = pool_sizes[0..].ptr,
    };
    self.cull.descriptor_pool = try self.dev.createDescriptorPool(&pool_info, null);
    errdefer {
        self.dev.destroyDescriptorPool(self.cull.descriptor_pool, null);
        self.cull.descriptor_pool = .null_handle;
    }

    self.cull.descriptor_sets_per_frame = try self.allocator.alloc(vk.DescriptorSet, num_frames);
    errdefer {
        self.allocator.free(self.cull.descriptor_sets_per_frame);
        self.cull.descriptor_sets_per_frame = &.{};
    }

    const layouts = try self.allocator.alloc(vk.DescriptorSetLayout, num_frames);
    defer self.allocator.free(layouts);
    @memset(layouts, self.cull.descriptor_set_layout);

    const alloc_info: vk.DescriptorSetAllocateInfo = .{
        .descriptor_pool = self.cull.descriptor_pool,
        .descriptor_set_count = @intCast(num_frames),
        .p_set_layouts = layouts.ptr,
    };
    try self.dev.allocateDescriptorSets(&alloc_info, self.cull.descriptor_sets_per_frame.ptr);

    for (0..num_frames) |i| {
        self.updateCullDescriptorSet(@intCast(i));
    }
}

fn updateCullDescriptorSet(self: *VulkanRenderer, frame_idx: u32) void {
    const dummy_image_info: vk.DescriptorImageInfo = .{ .sampler = .null_handle, .image_view = .null_handle, .image_layout = .undefined };
    const dummy_texel_buffer_view: vk.BufferView = .null_handle;
    const infos: [4]vk.DescriptorBufferInfo = .{
        .{ .buffer = self.persistent.buffer, .offset = self.persistent.offset, .range = self.persistent.slice.len * @sizeOf(InputChunk) },
        .{ .buffer = self.frame_buffers.indirect_draw[frame_idx], .offset = self.frame_buffers.indirect_draw_offsets[frame_idx], .range = self.draw_capacity * draw_type_count * @sizeOf(vk.DrawIndirectCommand) },
        .{ .buffer = self.frame_buffers.chunk_data[frame_idx], .offset = self.frame_buffers.chunk_data_offsets[frame_idx], .range = self.draw_capacity * draw_type_count * @sizeOf(ChunkData) },
        .{ .buffer = self.frame_buffers.count[frame_idx], .offset = self.frame_buffers.count_offsets[frame_idx], .range = @sizeOf(CullCount) },
    };
    var writes: [4]vk.WriteDescriptorSet = undefined;
    inline for (infos, 0..) |info, i| {
        writes[i] = .{
            .dst_set = self.cull.descriptor_sets_per_frame[frame_idx],
            .dst_binding = @intCast(i),
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = (&dummy_image_info)[0..1],
            .p_buffer_info = (&info)[0..1],
            .p_texel_buffer_view = (&dummy_texel_buffer_view)[0..1],
        };
    }
    self.dev.updateDescriptorSets(&writes, null);
}

fn createFrameDescriptorPool(self: *VulkanRenderer, pool: *vk.DescriptorPool, layout: vk.DescriptorSetLayout, sets: *[]vk.DescriptorSet, pool_sizes: []const vk.DescriptorPoolSize) !void {
    const num_frames = self.vk_ctx.swapchain_images.len;
    const pool_info: vk.DescriptorPoolCreateInfo = .{
        .flags = .{},
        .max_sets = @intCast(num_frames),
        .pool_size_count = @intCast(pool_sizes.len),
        .p_pool_sizes = pool_sizes.ptr,
    };
    pool.* = try self.dev.createDescriptorPool(&pool_info, null);
    errdefer {
        if (pool.* != .null_handle) {
            self.dev.destroyDescriptorPool(pool.*, null);
            pool.* = .null_handle;
        }
    }
    sets.* = try self.allocator.alloc(vk.DescriptorSet, num_frames);
    @memset(sets.*, .null_handle);
    errdefer {
        if (sets.*.len > 0) self.allocator.free(sets.*);
        sets.* = &.{};
    }
    for (sets.*[0..num_frames]) |*set| {
        const alloc_info: vk.DescriptorSetAllocateInfo = .{
            .descriptor_pool = pool.*,
            .descriptor_set_count = 1,
            .p_set_layouts = (&layout)[0..1],
        };
        try self.dev.allocateDescriptorSets(&alloc_info, (&set.*)[0..1]);
    }
}

fn buildGraphicsPipeline(
    self: *VulkanRenderer,
    vert_module: vk.ShaderModule,
    frag_module: vk.ShaderModule,
    color_formats: []const vk.Format,
    depth_format: vk.Format,
    depth_stencil_state: ?vk.PipelineDepthStencilStateCreateInfo,
    blend_attachments: []const vk.PipelineColorBlendAttachmentState,
    layout: vk.PipelineLayout,
) !vk.Pipeline {
    const piasci: vk.PipelineInputAssemblyStateCreateInfo = .{ .topology = .triangle_list, .primitive_restart_enable = .false };
    const pvsci: vk.PipelineViewportStateCreateInfo = .{ .viewport_count = 1, .p_viewports = null, .scissor_count = 1, .p_scissors = null };
    const prsci: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{}, // Set dynamically via cmdSetCullMode
        .front_face = .clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };
    const pmsci: vk.PipelineMultisampleStateCreateInfo = .{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };
    const pcbsci: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = @intCast(blend_attachments.len),
        .p_attachments = blend_attachments.ptr,
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    var dyn_states_buf: [5]vk.DynamicState = undefined;
    var dyn_states = std.ArrayList(vk.DynamicState).initBuffer(&dyn_states_buf);
    dyn_states.appendAssumeCapacity(.viewport);
    dyn_states.appendAssumeCapacity(.scissor);
    dyn_states.appendAssumeCapacity(.cull_mode);
    if (depth_stencil_state != null) {
        dyn_states.appendAssumeCapacity(.depth_compare_op);
        dyn_states.appendAssumeCapacity(.depth_write_enable);
    }
    const dyn: vk.PipelineDynamicStateCreateInfo = .{
        .flags = .{},
        .dynamic_state_count = @intCast(dyn_states.items.len),
        .p_dynamic_states = dyn_states.items.ptr,
    };

    const vertex_input_info: vk.PipelineVertexInputStateCreateInfo = .{
        .flags = .{},
        .vertex_binding_description_count = 0,
        .p_vertex_binding_descriptions = null,
        .vertex_attribute_description_count = 0,
        .p_vertex_attribute_descriptions = null,
    };
    const pssci: [2]vk.PipelineShaderStageCreateInfo = .{
        shaderStageCreateInfo(.{ .vertex_bit = true }, vert_module),
        shaderStageCreateInfo(.{ .fragment_bit = true }, frag_module),
    };

    var pipeline_feedback: vk.PipelineCreationFeedback = undefined;
    var stage_feedbacks: [2]vk.PipelineCreationFeedback = undefined;

    var feedback_info: vk.PipelineCreationFeedbackCreateInfo = .{
        .p_pipeline_creation_feedback = &pipeline_feedback,
        .pipeline_stage_creation_feedback_count = 2,
        .p_pipeline_stage_creation_feedbacks = &stage_feedbacks,
    };

    const rendering_info: vk.PipelineRenderingCreateInfo = .{
        .p_next = &feedback_info,
        .view_mask = 0,
        .color_attachment_count = @intCast(color_formats.len),
        .p_color_attachment_formats = color_formats.ptr,
        .depth_attachment_format = depth_format,
        .stencil_attachment_format = .undefined,
    };
    const ds_ptr: ?*const vk.PipelineDepthStencilStateCreateInfo = if (depth_stencil_state) |*ds| ds else null;
    const gpci: vk.GraphicsPipelineCreateInfo = .{
        .flags = .{},
        .p_next = @ptrCast(&rendering_info),
        .stage_count = 2,
        .p_stages = &pssci,
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &piasci,
        .p_tessellation_state = null,
        .p_viewport_state = &pvsci,
        .p_rasterization_state = &prsci,
        .p_multisample_state = &pmsci,
        .p_depth_stencil_state = ds_ptr,
        .p_color_blend_state = &pcbsci,
        .p_dynamic_state = &dyn,
        .layout = layout,
        .render_pass = .null_handle,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };
    var pipeline: vk.Pipeline = undefined;
    if (self.dev.createGraphicsPipelines(.null_handle, (&gpci)[0..1], null, (&pipeline)[0..1])) |res| {
        if (res != .success) return error.PipelineCreationFailed;
    } else |err| return err;

    if (pipeline_feedback.flags.valid_bit) {
        std.log.info("Vulkan: Pipeline compilation took {d:.3} ms (cached: {})", .{
            @as(f64, @floatFromInt(pipeline_feedback.duration)) / 1_000_000.0,
            pipeline_feedback.flags.application_pipeline_cache_hit_bit,
        });
    }

    return pipeline;
}

fn createGraphicsPipelines(self: *VulkanRenderer) !void {
    const pc_range: vk.PushConstantRange = .{
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .offset = 0,
        .size = @sizeOf(PushConstants),
    };

    const vert_module = try self.dev.createShaderModule(&.{ .flags = .{}, .code_size = vertex_shader_spv.len, .p_code = @ptrCast(@alignCast(vertex_shader_spv.ptr)) }, null);
    defer self.dev.destroyShaderModule(vert_module, null);

    // 1. Opaque Pipeline
    {
        const layout_info: vk.PipelineLayoutCreateInfo = .{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = (&self.graphics_state.opaque_descriptor_set_layout)[0..1],
            .push_constant_range_count = 1,
            .p_push_constant_ranges = (&pc_range)[0..1],
        };
        self.graphics_state.opaque_pipeline_layout = try self.dev.createPipelineLayout(&layout_info, null);

        const frag_module = try self.dev.createShaderModule(&.{ .flags = .{}, .code_size = fragment_shader_spv.len, .p_code = @ptrCast(@alignCast(fragment_shader_spv.ptr)) }, null);
        defer self.dev.destroyShaderModule(frag_module, null);

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
        self.graphics_state.pipeline = try self.buildGraphicsPipeline(vert_module, frag_module, &.{self.vk_ctx.swapchain_format}, self.depth_format, depth_stencil, &.{blend}, self.graphics_state.opaque_pipeline_layout);
    }

    // 2. Transparent Pipeline
    {
        const layout_info: vk.PipelineLayoutCreateInfo = .{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = (&self.graphics_state.transparent_descriptor_set_layout)[0..1],
            .push_constant_range_count = 1,
            .p_push_constant_ranges = (&pc_range)[0..1],
        };
        self.graphics_state.transparent_pipeline_layout = try self.dev.createPipelineLayout(&layout_info, null);

        const frag_module = try self.dev.createShaderModule(&.{ .flags = .{}, .code_size = transparent_frag_spv.len, .p_code = @ptrCast(@alignCast(transparent_frag_spv.ptr)) }, null);
        defer self.dev.destroyShaderModule(frag_module, null);

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
        const blend_attachments: [2]vk.PipelineColorBlendAttachmentState = .{
            .{ .blend_enable = .true, .src_color_blend_factor = .one, .dst_color_blend_factor = .one, .color_blend_op = .add, .src_alpha_blend_factor = .zero, .dst_alpha_blend_factor = .one_minus_src_alpha, .alpha_blend_op = .add, .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true } },
            .{ .blend_enable = .true, .src_color_blend_factor = .one, .dst_color_blend_factor = .one, .color_blend_op = .add, .src_alpha_blend_factor = .one, .dst_alpha_blend_factor = .one, .alpha_blend_op = .add, .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true } },
        };
        const formats: [2]vk.Format = .{ .r16g16b16a16_sfloat, .r16g16b16a16_sfloat };
        self.graphics_state.transparent_pipeline = try self.buildGraphicsPipeline(vert_module, frag_module, &formats, self.depth_format, depth_stencil, &blend_attachments, self.graphics_state.transparent_pipeline_layout);
    }
}

fn createCullPipeline(self: *VulkanRenderer) !void {
    const pc_range: vk.PushConstantRange = .{
        .stage_flags = .{ .compute_bit = true },
        .offset = 0,
        .size = @sizeOf(extern struct {
            planes: [6][4]f32,
            player_pos: [4]f32 align(16),
            total_candidates: u32,
            draw_capacity: u32,
        }),
    };
    const layout_info: vk.PipelineLayoutCreateInfo = .{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = (&self.cull.descriptor_set_layout)[0..1],
        .push_constant_range_count = 1,
        .p_push_constant_ranges = (&pc_range)[0..1],
    };
    self.cull.pipeline_layout = try self.dev.createPipelineLayout(&layout_info, null);
    errdefer {
        self.dev.destroyPipelineLayout(self.cull.pipeline_layout, null);
        self.cull.pipeline_layout = .null_handle;
    }

    const comp_module = try self.dev.createShaderModule(&.{ .flags = .{}, .code_size = cull_shader_spv.len, .p_code = @ptrCast(@alignCast(cull_shader_spv.ptr)) }, null);
    defer self.dev.destroyShaderModule(comp_module, null);

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
    if (self.dev.createComputePipelines(.null_handle, (&cpci)[0..1], null, (&self.cull.pipeline)[0..1])) |res| {
        if (res != .success) return error.PipelineCreationFailed;
    } else |err| return err;
}

fn createOitPipelinesAndDescriptors(self: *VulkanRenderer) !void {
    if (self.oit.descriptor_set_layout == .null_handle) {
        const bindings: [3]vk.DescriptorSetLayoutBinding = .{
            .{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 2, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
        };
        var layout_info: vk.DescriptorSetLayoutCreateInfo = .{ .flags = .{}, .binding_count = bindings.len, .p_bindings = bindings[0..] };
        self.oit.descriptor_set_layout = try self.dev.createDescriptorSetLayout(&layout_info, null);
    }

    if (self.oit.composition_layout == .null_handle) {
        const pipeline_layout_info: vk.PipelineLayoutCreateInfo = .{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = (&self.oit.descriptor_set_layout)[0..1],
            .push_constant_range_count = 0,
            .p_push_constant_ranges = null,
        };
        self.oit.composition_layout = try self.dev.createPipelineLayout(&pipeline_layout_info, null);
    }

    const sampler_info = vk.SamplerCreateInfo{
        .flags = .{},
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1.0,
        .compare_enable = .false,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .float_opaque_black,
        .unnormalized_coordinates = .false,
    };
    self.oit.sampler = try self.dev.createSampler(&sampler_info, null);
    errdefer {
        self.dev.destroySampler(self.oit.sampler, null);
        self.oit.sampler = .null_handle;
    }

    const vert_module = try self.dev.createShaderModule(&.{ .flags = .{}, .code_size = composite_vert_spv.len, .p_code = @ptrCast(@alignCast(composite_vert_spv.ptr)) }, null);
    defer self.dev.destroyShaderModule(vert_module, null);
    const frag_module = try self.dev.createShaderModule(&.{ .flags = .{}, .code_size = composite_frag_spv.len, .p_code = @ptrCast(@alignCast(composite_frag_spv.ptr)) }, null);
    defer self.dev.destroyShaderModule(frag_module, null);

    const blend: vk.PipelineColorBlendAttachmentState = .{
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };
    self.oit.composition_pipeline = try self.buildGraphicsPipeline(vert_module, frag_module, &.{self.vk_ctx.swapchain_format}, .undefined, null, &.{blend}, self.oit.composition_layout);

    const pool_size = vk.DescriptorPoolSize{ .type = .combined_image_sampler, .descriptor_count = @intCast(self.vk_ctx.swapchain_images.len * 3) };
    try self.createFrameDescriptorPool(&self.oit.descriptor_pool, self.oit.descriptor_set_layout, &self.oit.descriptor_sets_per_frame, (&pool_size)[0..1]);
    self.updateOitDescriptorSets();
}

fn updateOitDescriptorSets(self: *VulkanRenderer) void {
    const dummy_buffer_info: vk.DescriptorBufferInfo = .{ .buffer = .null_handle, .offset = 0, .range = 0 };
    const dummy_texel_buffer_view: vk.BufferView = .null_handle;
    const num_frames = self.vk_ctx.swapchain_images.len;
    const image_infos: [3]vk.DescriptorImageInfo = .{
        .{ .sampler = self.oit.sampler, .image_view = self.render_color.view, .image_layout = .shader_read_only_optimal },
        .{ .sampler = self.oit.sampler, .image_view = self.oit.accum.view, .image_layout = .shader_read_only_optimal },
        .{ .sampler = self.oit.sampler, .image_view = self.oit.reveal.view, .image_layout = .shader_read_only_optimal },
    };
    for (self.oit.descriptor_sets_per_frame[0..num_frames]) |desc_set| {
        const writes: [3]vk.WriteDescriptorSet = .{
            .{ .dst_set = desc_set, .dst_binding = 0, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .p_image_info = image_infos[0..1], .p_buffer_info = (&dummy_buffer_info)[0..1], .p_texel_buffer_view = (&dummy_texel_buffer_view)[0..1] },
            .{ .dst_set = desc_set, .dst_binding = 1, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .p_image_info = image_infos[1..2], .p_buffer_info = (&dummy_buffer_info)[0..1], .p_texel_buffer_view = (&dummy_texel_buffer_view)[0..1] },
            .{ .dst_set = desc_set, .dst_binding = 2, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .p_image_info = image_infos[2..3], .p_buffer_info = (&dummy_buffer_info)[0..1], .p_texel_buffer_view = (&dummy_texel_buffer_view)[0..1] },
        };
        self.dev.updateDescriptorSets(&writes, null);
    }
}

fn destroyOitPipelinesAndDescriptors(self: *VulkanRenderer) void {
    destroyIfValidPipeline(self.dev, &self.oit.composition_pipeline);
    destroyIfValidPipelineLayout(self.dev, &self.oit.composition_layout);
    destroyIfValidDescriptorSetLayout(self.dev, &self.oit.descriptor_set_layout);
    if (self.oit.sampler != .null_handle) {
        self.dev.destroySampler(self.oit.sampler, null);
        self.oit.sampler = .null_handle;
    }
}

fn processRetiredMeshes(self: *VulkanRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "processRetiredMeshes" });
    defer zone.end();

    {
        const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "processRetiredMeshes_lock" });
        self.retire_mutex.lockUncancelable(io);
        zone_lock.end();
    }
    defer self.retire_mutex.unlock(io);

    if (self.retired_meshes.items.len == 0 and self.retired_candidate_slices.items.len == 0) return;

    const current_graphics_val = try self.dev.getSemaphoreCounterValue(self.transfer.graphics_timeline_semaphore);

    var i: usize = 0;
    while (i < self.retired_meshes.items.len) {
        const entry = self.retired_meshes.items[i];
        if (current_graphics_val >= entry.graphics_timeline_value) {
            self.destroyChunkMesh(entry.mesh);
            // Now safe to return the index to the pool: all GPU work
            // that could have read this entry's slot is complete.
            self.index_pool.freeIndex(io, entry.gpu_index);
            _ = self.retired_meshes.swapRemove(i);
        } else {
            i += 1;
        }
    }

    var j: usize = 0;
    while (j < self.retired_candidate_slices.items.len) {
        const entry = self.retired_candidate_slices.items[j];
        if (current_graphics_val >= entry.graphics_timeline_value) {
            self.cpu_to_gpu_gpa.allocator().free(entry.slice);
            _ = self.retired_candidate_slices.swapRemove(j);
        } else {
            j += 1;
        }
    }
}

pub fn beginSingleTimeCommands(self: *VulkanRenderer) !vk.CommandBuffer {
    const alloc_info: vk.CommandBufferAllocateInfo = .{
        .level = .primary,
        .command_pool = self.upload_command_pool,
        .command_buffer_count = 1,
    };
    var cmd: vk.CommandBuffer = undefined;
    try self.dev.allocateCommandBuffers(&alloc_info, (&cmd)[0..1]);
    errdefer self.dev.freeCommandBuffers(self.upload_command_pool, &.{cmd});

    const begin_info: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };
    try self.dev.beginCommandBuffer(cmd, &begin_info);

    return cmd;
}

pub fn endSingleTimeCommandsLocked(self: *VulkanRenderer, cmd: vk.CommandBuffer) !void {
    defer self.dev.freeCommandBuffers(self.upload_command_pool, &.{cmd});

    try self.dev.endCommandBuffer(cmd);

    const submit_info: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = (&cmd)[0..1],
        .wait_semaphore_count = 0,
        .p_wait_semaphores = null,
        .p_wait_dst_stage_mask = null,
        .signal_semaphore_count = 0,
        .p_signal_semaphores = null,
    };

    try self.dev.queueSubmit(self.graphics_queue, &.{submit_info}, .null_handle);

    {
        const zone_wait = tracy.Zone.begin(.{ .src = @src(), .name = "endSingleTimeCommands_queueWaitIdle" });
        defer zone_wait.end();
        try self.dev.queueWaitIdle(self.graphics_queue);
    }
}

pub fn endSingleTimeCommands(self: *VulkanRenderer, io: std.Io, cmd: vk.CommandBuffer) !void {
    self.vk_ctx.queue_mutex.lockUncancelable(io);
    defer self.vk_ctx.queue_mutex.unlock(io);
    try self.endSingleTimeCommandsLocked(cmd);
}

fn vtableSetViewport(user_data: *Renderer.Implementation, viewport_pixels: @Vector(2, u32)) error{ViewportSetFailed}!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    if (viewport_pixels[0] != self.viewport_pixels[0] or
        viewport_pixels[1] != self.viewport_pixels[1])
    {
        self.viewport_pixels = viewport_pixels;
        self.vk_ctx.swapchain_extent = .{
            .width = viewport_pixels[0],
            .height = viewport_pixels[1],
        };
        self.vk_ctx.swapchain_needs_recreate.store(true, .monotonic);
    }
}
fn vtableUpdateCameraDirection(user_data: *Renderer.Implementation, view_dir: @Vector(3, f32)) void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    var front: @Vector(3, f32) = undefined;
    front[0] = @sin(std.math.degreesToRadians(view_dir[1])) * @cos(std.math.degreesToRadians(view_dir[0]));
    front[1] = @sin(std.math.degreesToRadians(view_dir[0]));
    front[2] = @cos(std.math.degreesToRadians(view_dir[1])) * @cos(std.math.degreesToRadians(view_dir[0]));
    const norm = zm.Vec3f.norm(.{ .data = front }).data;
    self.camera_front_x.store(norm[0], .monotonic);
    self.camera_front_y.store(norm[1], .monotonic);
    self.camera_front_z.store(norm[2], .monotonic);
}

fn vtableForEachChunk(user_data: *Renderer.Implementation, io: std.Io, callback_user_data: *anyopaque, callback: *const fn (*anyopaque, ChunkPos) void) std.Io.Cancelable!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    var it = self.meshes.iterator();
    defer it.deinit(io);
    while (try it.next(io)) |entry| {
        const chunk_pos = entry.key_ptr.*.toPos();
        it.pause(io);
        callback(callback_user_data, chunk_pos);
        try it.unpause(io);
    }
}

test "RenderBufferKey.toPos" {
    const pos_a: ChunkPos = .{ .level = 0, .position = .{ 1, 2, 3 } };
    const pos_b: ChunkPos = .{ .level = -3, .position = .{ -10, 20, 30 } };
    try std.testing.expectEqual(pos_a, (RenderBufferKey{ .@"opaque" = pos_a }).toPos());
    try std.testing.expectEqual(pos_b, (RenderBufferKey{ .transparent = pos_b }).toPos());
    const pos: ChunkPos = .{ .level = 5, .position = .{ -100, 200, -300 } };
    try std.testing.expectEqual(pos, (RenderBufferKey{ .@"opaque" = pos }).toPos());
}

test "findMemoryType" {
    var mem_types: [vk.MAX_MEMORY_TYPES]vk.MemoryType = undefined;
    @memset(&mem_types, vk.MemoryType{ .property_flags = .{}, .heap_index = 0 });
    mem_types[0] = .{ .property_flags = .{ .host_visible_bit = true, .host_coherent_bit = true }, .heap_index = 0 };
    mem_types[1] = .{ .property_flags = .{ .device_local_bit = true }, .heap_index = 1 };
    mem_types[2] = .{ .property_flags = .{ .host_visible_bit = true, .host_cached_bit = true }, .heap_index = 0 };
    var mem_props: vk.PhysicalDeviceMemoryProperties = .{ .memory_type_count = 3, .memory_types = mem_types, .memory_heap_count = 2, .memory_heaps = undefined };
    try std.testing.expectEqual(@as(u32, 0), try findMemoryTypeRaw(mem_props, 0b111, .{ .host_visible_bit = true, .host_coherent_bit = true }));
    mem_types[0] = .{ .property_flags = .{ .host_visible_bit = true, .host_coherent_bit = true }, .heap_index = 0 };
    mem_types[1] = .{ .property_flags = .{ .device_local_bit = true }, .heap_index = 1 };
    mem_props = .{ .memory_type_count = 2, .memory_types = mem_types, .memory_heap_count = 2, .memory_heaps = undefined };
    try std.testing.expectEqual(@as(u32, 1), try findMemoryTypeRaw(mem_props, 0b11, .{ .device_local_bit = true }));
}

test "ChunkData size" {
    try std.testing.expectEqual(@as(usize, 16), @alignOf(ChunkData));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(ChunkData));
}
