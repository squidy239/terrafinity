const std = @import("std");

const tracy = @import("tracy");
const vk = @import("vulkan");
const DeviceProxy = vk.DeviceProxy;
const zm = @import("zm");
const ConcurrentHashMap = @import("../../libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const utils = @import("../../libs/utils.zig");
const Mesher = @import("../../Mesher.zig");
const Renderer = @import("../../Renderer.zig");
const FrameDrawContext = Renderer.FrameDrawContext;
const VulkanContext = @import("../../VulkanContext.zig").VulkanContext;
const World = @import("../../world/World.zig");
const ChunkPos = World.ChunkPos;
const Frustum = @import("../Frustum.zig").Frustum;
const FaceDataAllocator = @import("FaceDataAllocator.zig").FaceDataAllocator;
const StagingRing = @import("StagingRing.zig").StagingRing;
const textures = @import("textures.zig");
const VulkanBackingAllocator = @import("VulkanBackingAllocator.zig").VulkanBackingAllocator;

const vertex_shader_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("vert_spv")));
const fragment_shader_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("frag_spv")));
const transparent_frag_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("trans_frag_spv")));
const composite_vert_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("comp_vert_spv")));
const composite_frag_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("comp_frag_spv")));
const cull_shader_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("cull_spv")));

const MeshCandidate = extern struct {
    absolute_position: [4]f32 align(@sizeOf([4]f32)),
    face_offset: u32,
    scale: f32,
    face_count: u32,
    is_transparent: u32,
};

comptime {
    if (@sizeOf(MeshCandidate) != 32) @compileError("MeshCandidate size mismatch with GLSL layout (expected 32, got " ++ @typeName(@TypeOf(@sizeOf(MeshCandidate))) ++ ")");
}

const CullCount = extern struct {
    opaque_count: u32,
    transparent_count: u32,
    opaque_face_count: u32,
    transparent_face_count: u32,
};

comptime {
    if (@sizeOf(CullCount) != 16) @compileError("CullCount size mismatch");
}

const BlockMaterial = extern struct {
    volume_color: [3]f32 align(4) = .{ 1.0, 1.0, 1.0 },
    density: f32 = 0.0,
    fresnel_power: f32 = 5.0,
    min_opacity: f32 = 0.15,
};

const BlockMaterialsZon = blk: {
    const vis_count = World.Block.visible_count;
    var names: [vis_count][]const u8 = undefined;
    var ni: usize = 0;
    for (std.meta.fields(World.Block)) |fld| {
        if (!@field(World.Block, fld.name).isVisible()) continue;
        names[ni] = fld.name;
        ni += 1;
    }
    const types: [vis_count]type = .{BlockMaterial} ** vis_count;
    const default_mat: BlockMaterial = .{};
    var attrs: [vis_count]std.builtin.Type.StructField.Attributes = undefined;
    for (&attrs) |*a| a.* = .{ .default_value_ptr = @as(?*const anyopaque, @ptrCast(&default_mat)) };
    break :blk @Struct(.auto, null, &names, &types, &attrs);
};

const MaterialGpu = extern struct {
    density: f32,
    fresnel_power: f32,
    min_opacity: f32,
    // align(16) matches GLSL std430 vec3 alignment (16-byte boundary).
    // Without it, volume_color would sit at offset 12, but GLSL expects
    // it at offset 16, causing every block's material data to read garbage.
    volume_color: [3]f32 align(16),
};

comptime {
    if (@sizeOf(MaterialGpu) != 32) @compileError("MaterialGpu size mismatch with GLSL std430 layout (expected 32, got " ++ std.fmt.comptimePrint("{}", .{@sizeOf(MaterialGpu)}) ++ ")");
}

const cull_buffer_alignment: std.mem.Alignment = .fromByteUnits(256);
const cull_workgroup_size: u32 = 64;
const draw_type_count = 2;

const sky_height: f32 = 4096.0;
const near_plane: f32 = 0.01;
const degrees_per_circle: f32 = 360.0;

const FrameDebugStats = struct {
    frame_number: u64 = 0,
    total_meshes: u32 = 0,
    opaque_drawn: u32 = 0,
    transparent_drawn: u32 = 0,
    opaque_faces: u32 = 0,
    transparent_faces: u32 = 0,
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
        std.log.info("Time: {d:.2} ms", .{ms});
        std.log.info("========================", .{});
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
        for (indices, 0..) |*val, i| val.* = @intCast(capacity - 1 - i);
        return .{ .free_indices = indices, .head = capacity };
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
        std.debug.assert(self.head < self.free_indices.len);
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
        for (new_indices[self.head .. self.head + added], old_capacity..) |*val, i| val.* = @intCast(i);
        allocator.free(self.free_indices);
        self.free_indices = new_indices;
        self.head += added;
    }
};

const MeshBuffer = struct {
    face_offset: u32,
    face_byte_count: vk.DeviceSize,
    face_count: u32,
    gpu_index: u32,
};

const batch_size = 512;
const pending_queue_size = 512;

const SubmissionBatch = struct {
    cmds: [batch_size]vk.CommandBuffer = undefined,
    pools: [batch_size]vk.CommandPool = undefined,
    opaque_meshes: [batch_size]?UploadResult = undefined,
    transparent_meshes: [batch_size]?UploadResult = undefined,
    chunk_positions: [batch_size]ChunkPos = undefined,
    count: usize = 0,
    mutex: std.Io.Mutex = .init,
};

const PendingMeshUpload = struct {
    chunk_pos: ChunkPos,
    timeline_value: u64,
    pool: vk.CommandPool,
    opaque_mesh: ?MeshBuffer,
    transparent_mesh: ?MeshBuffer,
};

const RetiredMeshEntry = struct {
    gpu_index: u32,
    face_offset: vk.DeviceSize,
    face_length: vk.DeviceSize,
    graphics_timeline_value: u64,
    free_index: bool,
};

const RetiredCandidateSlice = struct {
    slice: []MeshCandidate,
    graphics_timeline_value: u64,
};

const RetiredFaceBuffer = struct {
    slice: []align(256) u8,
    graphics_timeline_value: u64,
};

const reservoir_size = 512;

const CommandPoolReservoir = struct {
    pools: [reservoir_size]vk.CommandPool = @splat(@as(vk.CommandPool, .null_handle)),
    cmds: [reservoir_size]vk.CommandBuffer = @splat(@as(vk.CommandBuffer, .null_handle)),
    used: [reservoir_size]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
    count: usize = 0,

    pub const Borrowed = struct { pool: vk.CommandPool, cmd: vk.CommandBuffer };

    pub fn init(self: *CommandPoolReservoir, dev: DeviceProxy, queue_family: u32, init_count: usize, vkalloc: *const vk.AllocationCallbacks) !void {
        self.count = init_count;
        for (self.pools[0..init_count], self.cmds[0..init_count]) |*pool, *cmd| {
            pool.* = try dev.createCommandPool(&.{ .flags = .{ .reset_command_buffer_bit = true }, .queue_family_index = queue_family }, vkalloc);
            try dev.allocateCommandBuffers(&.{ .command_pool = pool.*, .level = .primary, .command_buffer_count = 1 }, (&cmd.*)[0..1]);
        }
    }

    pub fn deinit(self: *CommandPoolReservoir, dev: DeviceProxy, vkalloc: *const vk.AllocationCallbacks) void {
        for (self.pools[0..self.count]) |pool| if (pool != .null_handle) dev.destroyCommandPool(pool, vkalloc);
    }

    pub fn tryBorrowPool(self: *CommandPoolReservoir) ?Borrowed {
        for (self.pools[0..self.count], self.cmds[0..self.count], 0..) |pool, cmd, i| {
            if (self.used[i].cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                return .{ .pool = pool, .cmd = cmd };
            }
        }
        return null;
    }

    pub fn returnPool(self: *CommandPoolReservoir, dev: DeviceProxy, pool: vk.CommandPool) void {
        dev.resetCommandPool(pool, .{}) catch {
            @panic("CommandPoolReservoir.returnPool: resetCommandPool failed - command pool is now unusable");
        };
        for (self.pools[0..self.count], 0..) |p, i| {
            if (p == pool) {
                self.used[i].store(false, .release);
                break;
            }
        }
    }
};

const MeshData = extern struct {
    absolute_position: [4]f32 align(@sizeOf([4]f32)),
    relative_position: [4]f32 align(@sizeOf([4]f32)),
    scale: f32,
};

comptime {
    if (@sizeOf(MeshData) != 48) @compileError("MeshData size mismatch with GLSL layout (expected 48)");
}

comptime {
    if (push_constants_size != 84) @compileError("PushConstants effective size mismatch with GLSL layout (expected 84)");
}

const PushConstants = extern struct {
    projview: [16]f32,
    sun_dir: [3]f32,
    time: f32,
    mesh_base: u32,
};

const push_constants_size = @offsetOf(PushConstants, "mesh_base") + @sizeOf(u32);

const CullPushConstants = extern struct {
    planes: [6][4]f32,
    player_pos: [4]f32 align(16),
    total_candidates: u32,
    draw_capacity: u32,
};

comptime {
    if (@sizeOf(CullPushConstants) != 128) @compileError("CullPushConstants size mismatch with GLSL layout");
}

/// Internal core of findMemoryType; takes explicit mem_props so tests can exercise it without a renderer instance.
fn findMemoryTypeRaw(mem_props: vk.PhysicalDeviceMemoryProperties, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    const count = @min(mem_props.memory_type_count, 32);
    for (mem_props.memory_types[0..count], 0..) |mem_type, i| {
        if ((type_filter & (@as(u32, 1) << @truncate(i))) != 0 and (mem_type.property_flags.toInt() & properties.toInt()) == properties.toInt()) {
            return @intCast(i);
        }
    }
    return error.MemoryTypeNotFound;
}

fn computeViewProjection(self: *const VulkanRenderer, aspect: f32, fov_radians: f32) struct { projview: @Vector(16, f32), frustum: Frustum } {
    const up_vec: zm.vec.Vec3f = .{ .data = .{ 0, 1, 0 } };
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
    volume_weight: RenderTarget = .{},
    sampler: vk.Sampler = .null_handle,
    composition_pipeline: vk.Pipeline = .null_handle,
    composition_layout: vk.PipelineLayout = .null_handle,
    descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    descriptor_sets_per_frame: []vk.DescriptorSet = &.{},
    descriptor_pool: vk.DescriptorPool = .null_handle,
};

const PersistentCandidates = struct {
    buffer: vk.Buffer = .null_handle,
    mapped: [*]MeshCandidate = undefined,
    offset: vk.DeviceSize = 0,
    slice: []MeshCandidate = &.{},
};

const GraphicsState = struct {
    opaque_pipeline_layout: vk.PipelineLayout = .null_handle,
    transparent_pipeline_layout: vk.PipelineLayout = .null_handle,
    pipeline: vk.Pipeline = .null_handle,
    transparent_pipeline: vk.Pipeline = .null_handle,
    transparent_depth_descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    mesh_data_descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    mesh_data_descriptor_pool: vk.DescriptorPool = .null_handle,
    mesh_data_descriptor_sets_per_frame: []vk.DescriptorSet = &.{},
};

const CullState = struct {
    pipeline_layout: vk.PipelineLayout = .null_handle,
    pipeline: vk.Pipeline = .null_handle,
    descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    descriptor_pool: vk.DescriptorPool = .null_handle,
    descriptor_sets_per_frame: []vk.DescriptorSet = &.{},
};

const PerFrameData = struct {
    indirect_draw: vk.Buffer = .null_handle,
    indirect_draw_mapped: ?[*]vk.DrawIndirectCommand = null,
    indirect_draw_offset: vk.DeviceSize = 0,
    mesh_data: vk.Buffer = .null_handle,
    mesh_data_mapped: ?[*]MeshData = null,
    mesh_data_offset: vk.DeviceSize = 0,
    count: vk.Buffer = .null_handle,
    count_slice: []align(cull_buffer_alignment.toByteUnits()) CullCount = &.{},
    count_offset: vk.DeviceSize = 0,
    stats: vk.Buffer = .null_handle,
    stats_mapped: ?[*]align(cull_buffer_alignment.toByteUnits()) CullCount = null,
    stats_offset: vk.DeviceSize = 0,
    stats_slice: []align(cull_buffer_alignment.toByteUnits()) CullCount = &.{},
};

const PerFrameBuffers = struct {
    items: []PerFrameData = &.{},

    fn deinit(self: *PerFrameBuffers, allocator: std.mem.Allocator, cpu_to_gpu_gpa: std.mem.Allocator, gpu_only_gpa: std.mem.Allocator, draw_capacity: u32) void {
        for (self.items) |*item| {
            if (item.indirect_draw_mapped) |p| cpu_to_gpu_gpa.free(p[0 .. draw_capacity * draw_type_count]);
            if (item.mesh_data_mapped) |p| cpu_to_gpu_gpa.free(p[0 .. draw_capacity * draw_type_count]);
            if (item.count_slice.len > 0) gpu_only_gpa.free(item.count_slice);
            if (item.stats_slice.len > 0) cpu_to_gpu_gpa.free(item.stats_slice);
        }
        allocator.free(self.items);
    }
};

pub const VulkanRenderer = @This();

vk_ctx: *VulkanContext,
allocator: std.mem.Allocator,
dev: DeviceProxy,
graphics_queue: vk.Queue,
upload_command_pool: vk.CommandPool = .null_handle,
single_time_fence: vk.Fence = .null_handle,

render_color: RenderTarget = .{},
render_depth: RenderTarget = .{},
render_depth_sampled_view: vk.ImageView = .null_handle,
depth_format: vk.Format = .undefined,
oit: OitState = .{},
texture_manager: textures.TextureManager = undefined,

graphics_state: GraphicsState = .{},

block_materials_mapped: []MaterialGpu = &.{},
block_materials_descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
block_materials_descriptor_pool: vk.DescriptorPool = .null_handle,
block_materials_descriptor_set: vk.DescriptorSet = .null_handle,
transfer: TransferState = .{},
meshes: ConcurrentHashMap(RenderBufferKey, MeshBuffer, std.hash_map.AutoContext(RenderBufferKey), 32),
frame_buffers: PerFrameBuffers = .{},
cull: CullState = .{},
persistent: PersistentCandidates = .{},
index_pool: IndexPool = undefined,
max_allocated_index: std.atomic.Value(u32) = .init(0),
retired_candidate_slices: std.ArrayList(RetiredCandidateSlice) = .empty,

draw_capacity: u32 = 4096,
max_draw_indirect_count: u32 = 65_535,
retired_meshes: std.ArrayList(RetiredMeshEntry) = undefined,
retired_face_buffers: std.ArrayList(RetiredFaceBuffer) = undefined,
backing_allocator: VulkanBackingAllocator = undefined,
face_allocator: FaceDataAllocator = undefined,
staging_ring: StagingRing = undefined,
gpu_only_gpa: std.heap.DebugAllocator(.{}) = .init,
cpu_to_gpu_gpa: std.heap.DebugAllocator(.{}) = .init,
pool_reservoir: CommandPoolReservoir = .{},
pending_uploads_queue: std.Io.Queue(PendingMeshUpload) = undefined,
pending_uploads_queue_buffer: [pending_queue_size]PendingMeshUpload = undefined,
peeked_upload: ?PendingMeshUpload = null,
submission_batch: SubmissionBatch = .{},
camera_front_x: std.atomic.Value(f32) = .init(0),
camera_front_y: std.atomic.Value(f32) = .init(0),
camera_front_z: std.atomic.Value(f32) = .init(1),
viewport_pixels: @Vector(2, u32) = .{ 800, 600 },
render_options: *const Renderer.RenderOptions,
render_options_lock: *std.Io.RwLock,
interface: Renderer,

retire_mutex: std.Io.Mutex = .init,
num_in_flight: u32 = VulkanContext.max_frames_in_flight,
init_time_ns: u64 = 0,
last_stat_log_ns: u64 = 0,
frame_stats: FrameDebugStats = .{},

/// Monotonically increasing frame counter used to detect the first frame after initialization
/// or swapchain recreation. Frame 0 uses `.undefined` as the old layout for render targets
/// (skipping layout transition on initial layout). Subsequent frames use the actual prior
/// layout (e.g. `.shader_read_only_optimal`) to properly transition back to color attachment.
/// Do not reset this counter outside of init — partial-frame resets would use wrong old layouts.
frame_sequence: u64 = 0,

fn loadBlockMaterials(self: *VulkanRenderer, io: std.Io, allocator: std.mem.Allocator) !void {
    const pack_path = try std.fmt.allocPrint(allocator, "packs/{s}/blocks/", .{self.render_options.selected_pack});
    defer allocator.free(pack_path);

    const is_default = std.mem.eql(u8, self.render_options.selected_pack, "default");

    var pack_dir = if (is_default)
        try std.Io.Dir.cwd().createDirPathOpen(io, pack_path, .{ .open_options = .{ .iterate = true } })
    else
        try std.Io.Dir.cwd().openDir(io, pack_path, .{ .iterate = true });
    defer pack_dir.close(io);

    if (is_default) {
        const default_materials_zon = @import("materials").default;
        if (pack_dir.openFile(io, "materials.zon", .{})) |f| {
            f.close(io);
        } else |err| switch (err) {
            error.FileNotFound => try pack_dir.writeFile(io, .{ .data = default_materials_zon, .sub_path = "materials.zon" }),
            else => |e| return e,
        }
    }

    const indexer = std.enums.EnumIndexer(World.Block);
    const count = indexer.count;
    const slice = try self.cpu_to_gpu_gpa.allocator().alloc(MaterialGpu, count);
    errdefer self.cpu_to_gpu_gpa.allocator().free(slice);
    @memset(slice, .{ .density = 0.0, .fresnel_power = 5.0, .min_opacity = 0.15, .volume_color = .{ 1.0, 1.0, 1.0 } });

    var zon_file: ?std.Io.File = null;
    if (pack_dir.openFile(io, "materials.zon", .{})) |f| {
        zon_file = f;
    } else |err| switch (err) {
        error.FileNotFound => std.log.warn("No materials.zon found in pack, using defaults for all blocks", .{}),
        else => |e| return e,
    }
    defer if (zon_file) |f| f.close(io);

    if (zon_file) |f| {
        var temp_arena = std.heap.ArenaAllocator.init(allocator);
        defer temp_arena.deinit();
        const parsed = try utils.loadZon(BlockMaterialsZon, io, f, temp_arena.allocator(), allocator);

        inline for (std.meta.fields(World.Block)) |fld| {
            if (!@field(World.Block, fld.name).isVisible()) continue;
            const mat = &@field(parsed, fld.name);
            const idx = indexer.indexOf(@field(World.Block, fld.name));
            slice[idx] = .{
                .density = mat.density,
                .fresnel_power = mat.fresnel_power,
                .min_opacity = mat.min_opacity,
                .volume_color = mat.volume_color,
            };
        }
    }

    self.block_materials_mapped = slice;
    errdefer self.block_materials_mapped = &.{};
    try self.createBlockMaterialsDescriptorResources();
}

fn createBlockMaterialsDescriptorResources(self: *VulkanRenderer) !void {
    if (self.block_materials_descriptor_set_layout == .null_handle) {
        const binding = vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        };
        self.block_materials_descriptor_set_layout = try self.dev.createDescriptorSetLayout(&.{ .flags = .{}, .binding_count = 1, .p_bindings = (&binding)[0..1] }, &self.vk_ctx.vkalloc);
    }

    if (self.block_materials_descriptor_pool == .null_handle) {
        const pool_size = vk.DescriptorPoolSize{ .type = .storage_buffer, .descriptor_count = 1 };
        self.block_materials_descriptor_pool = try self.dev.createDescriptorPool(&.{ .flags = .{}, .max_sets = 1, .pool_size_count = 1, .p_pool_sizes = (&pool_size)[0..1].ptr }, &self.vk_ctx.vkalloc);
    }

    if (self.block_materials_descriptor_set == .null_handle) {
        try self.dev.allocateDescriptorSets(&.{
            .descriptor_pool = self.block_materials_descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = (&self.block_materials_descriptor_set_layout)[0..1],
        }, (&self.block_materials_descriptor_set)[0..1]);
    }

    const info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, self.block_materials_mapped.ptr);
    const buf_info: vk.DescriptorBufferInfo = .{
        .buffer = info.buffer,
        .offset = info.offset,
        .range = self.block_materials_mapped.len * @sizeOf(MaterialGpu),
    };
    self.dev.updateDescriptorSets((&dummyWriteDescriptorSet(self.block_materials_descriptor_set, 0, .storage_buffer, &buf_info))[0..1], null);
}

fn allocateIndirectBuffers(self: *VulkanRenderer, frame: *PerFrameData) !void {
    const mesh_data_slice = try self.cpu_to_gpu_gpa.allocator().alloc(MeshData, self.draw_capacity * draw_type_count);
    const indirect_draw_slice = try self.cpu_to_gpu_gpa.allocator().alloc(vk.DrawIndirectCommand, self.draw_capacity * draw_type_count);

    const mesh_data_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, mesh_data_slice.ptr);
    const indirect_draw_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, indirect_draw_slice.ptr);

    const count_slice = try self.gpu_only_gpa.allocator().alignedAlloc(CullCount, cull_buffer_alignment, 1);
    const count_info = self.backing_allocator.getBufferAndOffset(.gpu_only, count_slice.ptr);

    const stats_slice = try self.cpu_to_gpu_gpa.allocator().alignedAlloc(CullCount, cull_buffer_alignment, 1);
    stats_slice[0] = .{ .opaque_count = 0, .transparent_count = 0, .opaque_face_count = 0, .transparent_face_count = 0 };
    const stats_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, stats_slice.ptr);

    frame.* = .{
        .mesh_data = mesh_data_info.buffer,
        .mesh_data_mapped = mesh_data_slice.ptr,
        .mesh_data_offset = mesh_data_info.offset,
        .indirect_draw = indirect_draw_info.buffer,
        .indirect_draw_mapped = indirect_draw_slice.ptr,
        .indirect_draw_offset = indirect_draw_info.offset,
        .count = count_info.buffer,
        .count_slice = count_slice,
        .count_offset = count_info.offset,
        .stats = stats_info.buffer,
        .stats_mapped = stats_slice.ptr,
        .stats_slice = stats_slice,
        .stats_offset = stats_info.offset,
    };
}

fn drainInFlightFrames(self: *VulkanRenderer) !void {
    const frame_to_wait = self.vk_ctx.frame_number.load(.acquire);
    if (frame_to_wait > 0) {
        const wait_value: u64 = frame_to_wait;
        const wait_info: vk.SemaphoreWaitInfo = .{
            .semaphore_count = 1,
            .p_semaphores = (&self.vk_ctx.graphics_timeline_semaphore)[0..1],
            .p_values = (&wait_value)[0..1],
        };
        _ = try self.dev.waitSemaphores(&wait_info, std.math.maxInt(u64));
    }
}

fn recreateSwapchainResourcesLocked(self: *VulkanRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recreateSwapchainResourcesLocked" });
    defer zone.end();
    self.render_options_lock.lockSharedUncancelable(io);
    const gamma_correction = self.render_options.gamma_correction;
    const present_mode = self.render_options.present_mode;
    self.render_options_lock.unlockShared(io);
    self.vk_ctx.present_mode = present_mode;

    try self.drainInFlightFrames();
    try self.dev.resetCommandPool(self.vk_ctx.command_pool, .{});

    const old_swapchain = self.vk_ctx.swapchain;
    try self.vk_ctx.createSwapchainLocked(gamma_correction);

    if (self.vk_ctx.swapchain == old_swapchain and self.frame_buffers.items.len > 0) return;

    self.destroyRendererSwapchainResources();

    const actual_extent = self.vk_ctx.swapchain_extent;
    self.viewport_pixels = .{ actual_extent.width, actual_extent.height };

    try self.createRenderTargets(actual_extent);

    self.frame_buffers.items = try self.allocator.alloc(PerFrameData, VulkanContext.max_frames_in_flight);
    @memset(self.frame_buffers.items, .{});

    for (self.frame_buffers.items) |*frame| try self.allocateIndirectBuffers(frame);

    if (self.graphics_state.opaque_pipeline_layout != .null_handle) {
        if (self.graphics_state.pipeline != .null_handle) {
            self.dev.destroyPipeline(self.graphics_state.pipeline, &self.vk_ctx.vkalloc);
            self.graphics_state.pipeline = .null_handle;
        }
        if (self.graphics_state.transparent_pipeline != .null_handle) {
            self.dev.destroyPipeline(self.graphics_state.transparent_pipeline, &self.vk_ctx.vkalloc);
            self.graphics_state.transparent_pipeline = .null_handle;
        }
        self.dev.destroyPipelineLayout(self.graphics_state.opaque_pipeline_layout, &self.vk_ctx.vkalloc);
        self.graphics_state.opaque_pipeline_layout = .null_handle;
        self.dev.destroyPipelineLayout(self.graphics_state.transparent_pipeline_layout, &self.vk_ctx.vkalloc);
        self.graphics_state.transparent_pipeline_layout = .null_handle;
        try self.createGraphicsPipelines();
    }

    if (self.graphics_state.transparent_depth_descriptor_set_layout != .null_handle) {
        try self.createTransparentDepthDescriptorSetLayout();
    }

    if (self.cull.descriptor_set_layout != .null_handle) {
        for (self.cull.descriptor_sets_per_frame, 0..) |_, i| self.updateCullDescriptorSet(@intCast(i));
    }

    if (self.oit.descriptor_set_layout != .null_handle) {
        destroyIfValid(self.dev, &self.oit.composition_pipeline, &self.vk_ctx.vkalloc);
        destroyIfValid(self.dev, &self.oit.composition_layout, &self.vk_ctx.vkalloc);
        destroyIfValid(self.dev, &self.oit.descriptor_set_layout, &self.vk_ctx.vkalloc);
        // oit.sampler is resolution-independent — keep it across resizes
        try self.createOitPipelinesAndDescriptors();
    }

    if (self.graphics_state.mesh_data_descriptor_set_layout != .null_handle) {
        self.destroyMeshDataDescriptorResources();
        try self.createMeshDataDescriptorResources();
    }
}

fn destroyRendererSwapchainResources(self: *VulkanRenderer) void {
    destroyRenderTarget(self.dev, &self.render_color, &self.vk_ctx.vkalloc);
    destroyRenderTarget(self.dev, &self.render_depth, &self.vk_ctx.vkalloc);
    destroyIfValid(self.dev, &self.render_depth_sampled_view, &self.vk_ctx.vkalloc);
    self.frame_buffers.deinit(self.allocator, self.cpu_to_gpu_gpa.allocator(), self.gpu_only_gpa.allocator(), self.draw_capacity);
    self.destroyMeshDataDescriptorResources();
    self.destroyOitResources();
}

pub fn init(self: *VulkanRenderer, io: std.Io, allocator: std.mem.Allocator, vk_ctx: *VulkanContext, render_options: *const Renderer.RenderOptions, render_options_lock: *std.Io.RwLock) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "init" });
    defer zone.end();
    std.log.info("VulkanRenderer.init: Starting renderer-specific Vulkan initialization...", .{});

    self.* = .{
        .vk_ctx = vk_ctx,
        .allocator = allocator,
        .dev = vk_ctx.dev,
        .graphics_queue = vk_ctx.graphics_queue,
        .upload_command_pool = vk_ctx.upload_command_pool,
        .single_time_fence = .null_handle,
        .render_options = render_options,
        .render_options_lock = render_options_lock,
        .meshes = undefined,
        .interface = undefined,
    };

    self.init_time_ns = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    self.retired_meshes = .empty;
    self.retired_face_buffers = .empty;

    self.max_draw_indirect_count = if (vk_ctx.props.limits.max_draw_indirect_count > 0) vk_ctx.props.limits.max_draw_indirect_count else 65_535;

    self.transfer.queue_family_index = vk_ctx.transfer_queue_family_index;
    self.transfer.queue = vk_ctx.transfer_queue;
    self.transfer.semaphore = vk_ctx.transfer_semaphore;
    self.transfer.graphics_timeline_semaphore = vk_ctx.graphics_timeline_semaphore;

    try self.initMemoryManagement(io, allocator);
    try self.initGpuDataStructures(allocator);
    try self.initResources(io, allocator);
    try self.initFinalize();
}

fn initMemoryManagement(self: *VulkanRenderer, io: std.Io, allocator: std.mem.Allocator) !void {
    self.backing_allocator = VulkanBackingAllocator.init(
        self.dev,
        self.vk_ctx.mem_props,
        io,
        allocator,
        self.vk_ctx.queue_family_index,
        self.vk_ctx.transfer_queue_family_index,
        self.vk_ctx.vkalloc,
    );
    errdefer self.backing_allocator.deinit();

    self.gpu_only_gpa = .init;
    self.gpu_only_gpa.backing_allocator = self.backing_allocator.allocator(.gpu_only);
    errdefer _ = self.gpu_only_gpa.deinit();

    self.cpu_to_gpu_gpa = .init;
    self.cpu_to_gpu_gpa.backing_allocator = self.backing_allocator.allocator(.cpu_to_gpu);
    errdefer _ = self.cpu_to_gpu_gpa.deinit();

    self.face_allocator = try FaceDataAllocator.init(allocator, self.gpu_only_gpa.allocator(), 64 * 1024 * 1024);
    errdefer self.face_allocator.deinit(self.gpu_only_gpa.allocator());
    const face_buf_info = self.backing_allocator.getBufferAndOffset(.gpu_only, self.face_allocator.buffer_slice.ptr);
    self.face_allocator.resolve(face_buf_info.buffer, face_buf_info.offset);

    const max_face_bytes = @as(vk.DeviceSize, World.ChunkSize) * World.ChunkSize * World.ChunkSize * 6 * @sizeOf(Mesher.Face);
    self.staging_ring = try .init(allocator, self.cpu_to_gpu_gpa.allocator(), max_face_bytes * 64);
    const staging_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, self.staging_ring.mapping.ptr);
    self.staging_ring.resolve(staging_info.buffer);
}

fn initGpuDataStructures(self: *VulkanRenderer, allocator: std.mem.Allocator) !void {
    const initial_capacity = 4096;

    const persistent_candidates_slice = try self.cpu_to_gpu_gpa.allocator().alloc(MeshCandidate, initial_capacity);
    errdefer self.cpu_to_gpu_gpa.allocator().free(persistent_candidates_slice);
    @memset(persistent_candidates_slice, .{ .absolute_position = .{ 0, 0, 0, 0 }, .scale = 0, .face_count = 0, .is_transparent = 0, .face_offset = 0 });
    const cand_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, persistent_candidates_slice.ptr);
    self.persistent.buffer = cand_info.buffer;
    self.persistent.mapped = persistent_candidates_slice.ptr;
    self.persistent.offset = cand_info.offset;
    self.persistent.slice = persistent_candidates_slice;
    self.retired_candidate_slices = .empty;

    self.index_pool = try IndexPool.init(allocator, initial_capacity);
    self.max_allocated_index = .init(0);

    self.pending_uploads_queue = std.Io.Queue(PendingMeshUpload).init(&self.pending_uploads_queue_buffer);
    self.peeked_upload = null;
}

fn initResources(self: *VulkanRenderer, io: std.Io, allocator: std.mem.Allocator) !void {
    self.texture_manager = textures.TextureManager.init(self, self.render_options.gamma_correction);
    try self.texture_manager.loadTextures(io, allocator, self.render_options.selected_pack);
    try self.loadBlockMaterials(io, allocator);
    try self.createTransparentDepthDescriptorSetLayout();
    try self.recreateSwapchainResourcesLocked(io);
    try self.createCullDescriptorSetLayoutAndPool();
    try self.createMeshDataDescriptorResources();
    try self.createGraphicsPipelines();
    try self.createCullPipeline();
    try self.createOitPipelinesAndDescriptors();
}

fn initFinalize(self: *VulkanRenderer) !void {
    self.meshes = .init;

    try self.pool_reservoir.init(self.dev, self.transfer.queue_family_index, 512, &self.vk_ctx.vkalloc);

    self.interface = .{
        .userdata = @ptrCast(self),
        .vtable = &.{
            .addMesh = vtableAddMesh,
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
        self.submission_batch.mutex.lockUncancelable(io);
        defer self.submission_batch.mutex.unlock(io);
        self.submitBatch(io) catch {
            @panic("VulkanRenderer.deinit: failed to flush submission batch - GPU state may be inconsistent");
        };
    }
    {
        self.vk_ctx.queue_mutex.lockUncancelable(io);
        defer self.vk_ctx.queue_mutex.unlock(io);
        self.dev.deviceWaitIdle() catch {
            @panic("VulkanRenderer.deinit: deviceWaitIdle failed - cannot safely release GPU resources");
        };

        self.dev.resetCommandPool(self.upload_command_pool, .{}) catch {};
        self.dev.resetCommandPool(self.vk_ctx.command_pool, .{ .release_resources_bit = true }) catch {};
        if (self.vk_ctx.ui_command_pool != .null_handle) {
            self.dev.resetCommandPool(self.vk_ctx.ui_command_pool, .{ .release_resources_bit = true }) catch {};
        }
        if (self.single_time_fence != .null_handle) {
            self.dev.destroyFence(self.single_time_fence, &self.vk_ctx.vkalloc);
            self.single_time_fence = .null_handle;
        }
        for (self.pool_reservoir.pools[0..self.pool_reservoir.count]) |pool| {
            if (pool != .null_handle) self.dev.resetCommandPool(pool, .{}) catch {};
        }
    }

    if (self.peeked_upload) |pending| self.destroyPendingUpload(io, pending);
    while (true) {
        var buf: PendingMeshUpload = undefined;
        const got = self.pending_uploads_queue.getUncancelable(io, (&buf)[0..1], 0) catch unreachable;
        if (got == 0) break;
        self.destroyPendingUpload(io, buf);
    }
    for (self.retired_meshes.items) |entry| self.face_allocator.freeRegion(io, entry.face_offset, entry.face_length);
    self.retired_meshes.deinit(self.allocator);

    for (self.retired_face_buffers.items) |entry| self.gpu_only_gpa.allocator().free(entry.slice);
    self.retired_face_buffers.deinit(self.allocator);

    var it = self.meshes.iterator();
    defer it.deinit(io);
    while (it.next(io) catch unreachable) |entry| self.destroyMeshBuffer(io, entry.value_ptr.*);
    self.meshes.deinit(io, self.allocator);

    self.destroyRendererSwapchainResources();
    self.destroyOitPipelinesAndDescriptors();

    destroyIfValid(self.dev, &self.graphics_state.pipeline, &self.vk_ctx.vkalloc);
    destroyIfValid(self.dev, &self.graphics_state.transparent_pipeline, &self.vk_ctx.vkalloc);
    destroyIfValid(self.dev, &self.cull.pipeline, &self.vk_ctx.vkalloc);
    destroyIfValid(self.dev, &self.graphics_state.opaque_pipeline_layout, &self.vk_ctx.vkalloc);
    destroyIfValid(self.dev, &self.graphics_state.transparent_pipeline_layout, &self.vk_ctx.vkalloc);
    destroyIfValid(self.dev, &self.cull.pipeline_layout, &self.vk_ctx.vkalloc);
    destroyIfValid(self.dev, &self.graphics_state.transparent_depth_descriptor_set_layout, &self.vk_ctx.vkalloc);
    destroyIfValid(self.dev, &self.cull.descriptor_set_layout, &self.vk_ctx.vkalloc);
    destroyIfValid(self.dev, &self.graphics_state.mesh_data_descriptor_set_layout, &self.vk_ctx.vkalloc);
    destroyIfValid(self.dev, &self.block_materials_descriptor_set_layout, &self.vk_ctx.vkalloc);

    if (self.block_materials_descriptor_pool != .null_handle) {
        self.dev.destroyDescriptorPool(self.block_materials_descriptor_pool, &self.vk_ctx.vkalloc);
        self.block_materials_descriptor_pool = .null_handle;
    }
    if (self.block_materials_mapped.len > 0) self.cpu_to_gpu_gpa.allocator().free(self.block_materials_mapped);

    if (self.cull.descriptor_pool != .null_handle) {
        self.dev.destroyDescriptorPool(self.cull.descriptor_pool, &self.vk_ctx.vkalloc);
        self.cull.descriptor_pool = .null_handle;
    }
    self.allocator.free(self.cull.descriptor_sets_per_frame);
    self.cull.descriptor_sets_per_frame = &.{};

    self.pool_reservoir.deinit(self.dev, &self.vk_ctx.vkalloc);

    for (self.retired_candidate_slices.items) |entry| self.cpu_to_gpu_gpa.allocator().free(entry.slice);
    self.retired_candidate_slices.deinit(self.allocator);
    self.index_pool.deinit(self.allocator);
    self.cpu_to_gpu_gpa.allocator().free(self.persistent.slice);
    self.staging_ring.deinit(self.cpu_to_gpu_gpa.allocator());

    self.face_allocator.deinit(self.gpu_only_gpa.allocator());

    _ = self.gpu_only_gpa.deinit();
    _ = self.cpu_to_gpu_gpa.deinit();
    self.backing_allocator.deinit();

    self.texture_manager.deinit();
}

pub fn addMesh(self: *VulkanRenderer, io: std.Io, chunk_pos: ChunkPos, opaque_mesh: []const Mesher.Face, transparent_mesh: []const Mesher.Face) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "addMesh" });
    defer zone.end();

    const borrowed = while (true) {
        if (self.pool_reservoir.tryBorrowPool()) |b| break b;
        {
            self.submission_batch.mutex.lockUncancelable(io);
            defer self.submission_batch.mutex.unlock(io);
            if (self.submission_batch.count > 0) try self.submitBatch(io);
        }
        try self.retireCompletedUploads(io);
        try std.Io.sleep(io, .fromNanoseconds(0), .awake);
    };
    const pool = borrowed.pool;
    const cmd = borrowed.cmd;
    errdefer self.pool_reservoir.returnPool(self.dev, pool);

    try self.dev.resetCommandPool(pool, .{});

    try self.dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true }, .p_inheritance_info = null });

    var opaque_res: ?UploadResult = null;
    var transparent_res: ?UploadResult = null;
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

fn submitBatch(self: *VulkanRenderer, io: std.Io) !void {
    const count = self.submission_batch.count;
    if (count == 0) return;
    const zone_queue = tracy.Zone.begin(.{ .src = @src(), .name = "submitBatch_lock_queue" });
    self.vk_ctx.queue_mutex.lockUncancelable(io);
    zone_queue.end();
    defer self.vk_ctx.queue_mutex.unlock(io);

    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "submitBatch" });
    defer zone.end();

    const next_val = self.vk_ctx.transfer_semaphore_value.load(.monotonic) + 1;
    self.vk_ctx.transfer_semaphore_value.store(next_val, .monotonic);

    var cb_submit_infos: [batch_size]vk.CommandBufferSubmitInfo = undefined;
    for (cb_submit_infos[0..count], self.submission_batch.cmds[0..count]) |*info, cmd| info.* = .{ .command_buffer = cmd, .device_mask = 0 };

    const current_graphics_val = self.vk_ctx.frame_number.load(.acquire);

    const submit_info: vk.SubmitInfo2 = .{
        .flags = .{},
        .wait_semaphore_info_count = 1,
        .p_wait_semaphore_infos = (&vk.SemaphoreSubmitInfo{
            .semaphore = self.transfer.graphics_timeline_semaphore,
            .value = current_graphics_val,
            .stage_mask = .{ .all_transfer_bit = true },
            .device_index = 0,
        })[0..1],
        .command_buffer_info_count = @intCast(count),
        .p_command_buffer_infos = cb_submit_infos[0..count].ptr,
        .signal_semaphore_info_count = 1,
        .p_signal_semaphore_infos = (&vk.SemaphoreSubmitInfo{
            .semaphore = self.transfer.semaphore,
            .value = next_val,
            .stage_mask = .{ .all_transfer_bit = true },
            .device_index = 0,
        })[0..1],
    };

    try self.dev.queueSubmit2(self.transfer.queue, (&submit_info)[0..1], .null_handle);

    self.submission_batch.count = 0;

    for (self.submission_batch.opaque_meshes[0..count], self.submission_batch.transparent_meshes[0..count], self.submission_batch.chunk_positions[0..count], self.submission_batch.pools[0..count]) |opaque_mesh, transparent_mesh, chunk_pos, pool| {
        if (opaque_mesh) |r| self.staging_ring.bind(io, r.staging_slice, next_val);
        if (transparent_mesh) |r| self.staging_ring.bind(io, r.staging_slice, next_val);
        try self.pushPendingUpload(io, .{
            .chunk_pos = chunk_pos,
            .timeline_value = next_val,
            .pool = pool,
            .opaque_mesh = if (opaque_mesh) |r| r.mesh else null,
            .transparent_mesh = if (transparent_mesh) |r| r.mesh else null,
        });
    }
}

fn pushPendingUpload(self: *VulkanRenderer, io: std.Io, pending: PendingMeshUpload) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "pushPendingUpload" });
    defer zone.end();

    while (true) {
        if (try self.pending_uploads_queue.put(io, &.{pending}, 0) == 1) return;
        try self.retireCompletedUploads(io);
        try std.Io.sleep(io, .fromNanoseconds(0), .awake);
    }
}

fn vtableAddMesh(user_data: *Renderer.Implementation, io: std.Io, chunk_pos: ChunkPos, opaque_mesh: []Mesher.Face, transparent_mesh: []Mesher.Face) (std.Io.Cancelable || error{AddMeshFailed})!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    self.addMesh(io, chunk_pos, opaque_mesh, transparent_mesh) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.AddMeshFailed,
    };
}

fn destroyMeshBuffer(self: *VulkanRenderer, io: std.Io, mesh: MeshBuffer) void {
    self.face_allocator.freeRegion(io, @as(vk.DeviceSize, @intCast(mesh.face_offset)) * @sizeOf(Mesher.Face), mesh.face_byte_count);
}

fn cancelUpload(self: *VulkanRenderer, io: std.Io, result: UploadResult) void {
    self.staging_ring.cancel(io, result.staging_slice);
    self.face_allocator.freeRegion(io, @as(vk.DeviceSize, @intCast(result.mesh.face_offset)) * @sizeOf(Mesher.Face), result.mesh.face_byte_count);
}

fn destroyPendingUpload(self: *VulkanRenderer, io: std.Io, pending: PendingMeshUpload) void {
    if (pending.opaque_mesh) |opaque_m| self.destroyMeshBuffer(io, opaque_m);
    if (pending.transparent_mesh) |transparent| self.destroyMeshBuffer(io, transparent);
    if (pending.pool != .null_handle) self.pool_reservoir.returnPool(self.dev, pending.pool);
}

fn enqueueRetiredMesh(self: *VulkanRenderer, gpu_index: u32, face_offset: u32, face_byte_count: vk.DeviceSize, free_index: bool) !void {
    const retire_frame = self.vk_ctx.frame_number.load(.acquire);
    try self.retired_meshes.append(self.allocator, .{
        .gpu_index = gpu_index,
        .face_offset = @as(vk.DeviceSize, @intCast(face_offset)) * @sizeOf(Mesher.Face),
        .face_length = face_byte_count,
        .graphics_timeline_value = retire_frame + self.num_in_flight,
        .free_index = free_index,
    });
}

fn retireOnePendingItem(self: *VulkanRenderer, io: std.Io, mesh: ?MeshBuffer, key: RenderBufferKey, chunk_pos: ChunkPos) !void {
    if (mesh) |m| {
        var new_mesh = m;

        const ratio = ChunkPos.levelToBlockRatioFloat(chunk_pos.level);
        const mesh_blockpos = @as(@Vector(3, f64), @floatFromInt(chunk_pos.position)) * @as(@Vector(3, f64), @splat(ratio));
        const abs_vec: [4]f32 = .{ @floatCast(mesh_blockpos[0]), @floatCast(mesh_blockpos[1]), @floatCast(mesh_blockpos[2]), 1.0 };

        const is_transparent = key == .transparent;

        const existing = self.meshes.get(io, key);
        if (existing) |old_mesh| {
            new_mesh.gpu_index = old_mesh.gpu_index;
            self.persistent.mapped[old_mesh.gpu_index] = .{
                .absolute_position = abs_vec,
                .scale = ChunkPos.toScale(chunk_pos.level),
                .face_count = new_mesh.face_count,
                .is_transparent = if (is_transparent) 1 else 0,
                .face_offset = new_mesh.face_offset,
            };
            const removed = try self.meshes.fetchPut(io, self.allocator, key, new_mesh);
            if (removed) |old| try self.enqueueRetiredMesh(old.gpu_index, old.face_offset, old.face_byte_count, false);
        } else {
            const gpu_idx = while (true) {
                if (self.index_pool.allocIndex(io)) |idx| break idx;
                try self.growPersistentCandidates(io);
            };
            new_mesh.gpu_index = gpu_idx;

            self.persistent.mapped[gpu_idx] = .{
                .absolute_position = abs_vec,
                .scale = ChunkPos.toScale(chunk_pos.level),
                .face_count = new_mesh.face_count,
                .is_transparent = if (is_transparent) 1 else 0,
                .face_offset = new_mesh.face_offset,
            };

            var current_max = self.max_allocated_index.load(.monotonic);
            while (gpu_idx >= current_max) {
                if (self.max_allocated_index.cmpxchgStrong(current_max, gpu_idx + 1, .release, .monotonic)) |actual_val| {
                    current_max = actual_val;
                    continue;
                }
                break;
            }

            const removed = try self.meshes.fetchPut(io, self.allocator, key, new_mesh);
            if (removed) |old| {
                self.persistent.mapped[old.gpu_index].face_count = 0;
                try self.enqueueRetiredMesh(old.gpu_index, old.face_offset, old.face_byte_count, true);
            }
        }
    } else {
        const existing = self.meshes.fetchRemove(io, key);
        if (existing) |old_mesh| {
            self.persistent.mapped[old_mesh.gpu_index].face_count = 0;
            try self.enqueueRetiredMesh(old_mesh.gpu_index, old_mesh.face_offset, old_mesh.face_byte_count, true);
        }
    }
}

fn retireCompletedUploads(self: *VulkanRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "retireCompletedUploads" });
    defer zone.end();

    self.retire_mutex.lockUncancelable(io);
    defer self.retire_mutex.unlock(io);

    const current_transfer_val = try self.dev.getSemaphoreCounterValue(self.transfer.semaphore);
    self.staging_ring.retire(io, current_transfer_val);

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

            self.pool_reservoir.returnPool(self.dev, pending.pool);
            self.peeked_upload = null;
        } else {
            self.peeked_upload = pending;
            break;
        }
    }
}

const UploadResult = struct {
    mesh: MeshBuffer,
    staging_slice: []u8,
};

fn allocStagingSlice(self: *VulkanRenderer, io: std.Io, buffer_size: vk.DeviceSize) ![]u8 {
    while (true) {
        if (self.staging_ring.alloc(io, buffer_size)) |slice| return slice;
        try self.processPendingUploads(io);
        try std.Io.sleep(io, .fromNanoseconds(0), .awake);
    }
}

fn uploadMeshBuffer(self: *VulkanRenderer, io: std.Io, faces: []const Mesher.Face, cmd: vk.CommandBuffer) !UploadResult {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "uploadMeshBuffer" });
    defer zone.end();

    const buffer_size: vk.DeviceSize = @intCast(faces.len * @sizeOf(Mesher.Face));

    const staging_slice = try self.allocStagingSlice(io, buffer_size);
    errdefer self.staging_ring.cancel(io, staging_slice);

    const indexer = std.enums.EnumIndexer(World.Block);
    for (faces, std.mem.bytesAsSlice(Mesher.Face, staging_slice)[0..faces.len]) |face, *dest| {
        dest.* = face;
        dest.block_type = @intCast(indexer.indexOf(@enumFromInt(face.block_type)));
    }

    const staging_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, staging_slice.ptr);

    const face_alloc = try self.allocFaceRegion(io, buffer_size);
    const face_byte_offset = face_alloc.offset;
    const face_buf = face_alloc.buffer;
    const face_buf_offset = face_alloc.buffer_offset;

    // Hazard barrier on the transfer queue: prior transfer writes to this region (which may
    // have been reused) must finish before the copy overwrites it. No ownership transfer:
    // the buffer is concurrent-shared, so both family indices stay QUEUE_FAMILY_IGNORED.
    {
        self.dev.cmdPipelineBarrier2(cmd, &.{
            .dependency_flags = .{},
            .memory_barrier_count = 0,
            .p_memory_barriers = null,
            .buffer_memory_barrier_count = 1,
            .p_buffer_memory_barriers = (&vk.BufferMemoryBarrier2{
                .src_stage_mask = .{ .all_transfer_bit = true },
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_stage_mask = .{ .all_transfer_bit = true },
                .dst_access_mask = .{ .transfer_write_bit = true },
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .buffer = face_buf,
                .offset = face_buf_offset + face_byte_offset,
                .size = buffer_size,
            })[0..1],
            .image_memory_barrier_count = 0,
            .p_image_memory_barriers = null,
        });
    }

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
    {
        self.dev.cmdPipelineBarrier2(cmd, &.{
            .dependency_flags = .{},
            .memory_barrier_count = 0,
            .p_memory_barriers = null,
            .buffer_memory_barrier_count = 1,
            .p_buffer_memory_barriers = (&vk.BufferMemoryBarrier2{
                .src_stage_mask = .{ .all_transfer_bit = true },
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_stage_mask = .{ .all_transfer_bit = true },
                .dst_access_mask = .{},
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .buffer = face_buf,
                .offset = face_buf_offset + face_byte_offset,
                .size = buffer_size,
            })[0..1],
            .image_memory_barrier_count = 0,
            .p_image_memory_barriers = null,
        });
    }

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

fn allocFaceRegion(self: *VulkanRenderer, io: std.Io, buffer_size: vk.DeviceSize) !FaceDataAllocator.AllocResult {
    while (true) {
        if (self.face_allocator.allocRegion(io, buffer_size)) |result| return result;

        {
            self.submission_batch.mutex.lockUncancelable(io);
            defer self.submission_batch.mutex.unlock(io);
            try self.submitBatch(io);
        }

        self.vk_ctx.queue_mutex.lockUncancelable(io);
        defer self.vk_ctx.queue_mutex.unlock(io);

        if (self.face_allocator.allocRegion(io, buffer_size)) |result| return result;

        std.log.info("growing face data buffer...", .{});
        try self.drainInFlightFrames();

        const transfer_done_val = self.vk_ctx.transfer_semaphore_value.load(.acquire);
        if (transfer_done_val > 0) {
            _ = try self.dev.waitSemaphores(&.{
                .semaphore_count = 1,
                .p_semaphores = (&self.transfer.semaphore)[0..1],
                .p_values = (&transfer_done_val)[0..1],
            }, std.math.maxInt(u64));
        }

        const grow_info = try self.face_allocator.grow(io, self.gpu_only_gpa.allocator());

        const face_buf_info = self.backing_allocator.getBufferAndOffset(.gpu_only, self.face_allocator.buffer_slice.ptr);
        self.face_allocator.resolve(face_buf_info.buffer, face_buf_info.offset);

        const cmd = try self.beginSingleTimeCommands();
        defer self.endSingleTimeCommandsLocked(cmd) catch {
            @panic("allocFaceRegion: GPU command submission or wait failed - cannot safely continue");
        };

        self.dev.cmdCopyBuffer2(cmd, &.{
            .src_buffer = grow_info.old_buffer,
            .dst_buffer = self.face_allocator.buffer.?,
            .region_count = 1,
            .p_regions = (&vk.BufferCopy2{
                .src_offset = grow_info.old_buffer_offset,
                .dst_offset = self.face_allocator.buffer_offset,
                .size = grow_info.old_used,
            })[0..1],
        });

        try self.retired_face_buffers.append(self.allocator, .{
            .slice = grow_info.old_slice,
            .graphics_timeline_value = self.vk_ctx.frame_number.load(.acquire) + self.num_in_flight,
        });

        std.log.info("face data buffer grown", .{});
    }
}

fn processPendingUploads(self: *VulkanRenderer, io: std.Io) !void {
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

fn setViewportAndScissor(self: *const VulkanRenderer, cmd: vk.CommandBuffer, extent: vk.Extent2D) void {
    self.dev.cmdSetViewport(cmd, 0, (&vk.Viewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0.0,
        .max_depth = 1.0,
    })[0..1]);
    self.dev.cmdSetScissor(cmd, 0, (&vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    })[0..1]);
}

fn makeImageBarrier2(
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

/// The barrier slice must outlive the cmdPipelineBarrier2 call below (it is consumed
/// synchronously during recording). Do not extract the DependencyInfo and defer the call.
fn pipelineBarrier(cmd: vk.CommandBuffer, dev: DeviceProxy, comptime barrier_type: type, barriers: []const barrier_type) void {
    const info: vk.DependencyInfo = switch (barrier_type) {
        vk.ImageMemoryBarrier2 => .{
            .dependency_flags = .{},
            .memory_barrier_count = 0,
            .p_memory_barriers = null,
            .buffer_memory_barrier_count = 0,
            .p_buffer_memory_barriers = null,
            .image_memory_barrier_count = @intCast(barriers.len),
            .p_image_memory_barriers = barriers.ptr,
        },
        vk.BufferMemoryBarrier2 => .{
            .dependency_flags = .{},
            .memory_barrier_count = 0,
            .p_memory_barriers = null,
            .buffer_memory_barrier_count = @intCast(barriers.len),
            .p_buffer_memory_barriers = barriers.ptr,
            .image_memory_barrier_count = 0,
            .p_image_memory_barriers = null,
        },
        else => @compileError("pipelineBarrier: unsupported type " ++ @typeName(barrier_type)),
    };
    dev.cmdPipelineBarrier2(cmd, &info);
}

fn cmdAcquireFaceBuffer(self: *VulkanRenderer, cmd_buffer: vk.CommandBuffer) void {
    if (self.face_allocator.used == 0) return;
    // Acquire side of the cross-queue memory dependency: the face buffer is concurrent-shared,
    // so this barrier (QUEUE_FAMILY_IGNORED) only makes the upload batch's transfer writes
    // visible to this frame's vertex reads — it is not an ownership transfer.
    pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, (&vk.BufferMemoryBarrier2{
        .src_stage_mask = .{ .all_transfer_bit = true },
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_stage_mask = .{ .vertex_attribute_input_bit = true },
        .dst_access_mask = .{ .vertex_attribute_read_bit = true },
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .buffer = self.face_allocator.buffer.?,
        .offset = self.face_allocator.buffer_offset,
        .size = self.face_allocator.used,
    })[0..1]);
}

fn cmdReleaseFaceBuffer(self: *VulkanRenderer, cmd_buffer: vk.CommandBuffer) void {
    if (self.face_allocator.used == 0) return;
    // Release side: make this frame's vertex reads available before the next upload batch
    // writes the same regions on the transfer queue. Concurrent sharing, so no ownership
    // transfer — the family indices stay QUEUE_FAMILY_IGNORED.
    pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, (&vk.BufferMemoryBarrier2{
        .src_stage_mask = .{ .vertex_attribute_input_bit = true },
        .src_access_mask = .{ .vertex_attribute_read_bit = true },
        .dst_stage_mask = .{ .all_transfer_bit = true },
        .dst_access_mask = .{},
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .buffer = self.face_allocator.buffer.?,
        .offset = self.face_allocator.buffer_offset,
        .size = self.face_allocator.used,
    })[0..1]);
}

fn makeBufferBarrier2(
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

fn destroyIfValid(dev: DeviceProxy, handle: anytype, vkalloc: *const vk.AllocationCallbacks) void {
    const T = @TypeOf(handle.*);
    if (handle.* == .null_handle) return;
    switch (T) {
        vk.ImageView => dev.destroyImageView(handle.*, vkalloc),
        vk.Image, vk.DeviceMemory => unreachable,
        vk.Pipeline => dev.destroyPipeline(handle.*, vkalloc),
        vk.PipelineLayout => dev.destroyPipelineLayout(handle.*, vkalloc),
        vk.DescriptorSetLayout => dev.destroyDescriptorSetLayout(handle.*, vkalloc),
        vk.Sampler => dev.destroySampler(handle.*, vkalloc),
        else => @compileError("destroyIfValid: unsupported type " ++ @typeName(T)),
    }
    handle.* = .null_handle;
}

fn destroyIfValidImage(dev: DeviceProxy, image: *vk.Image, memory: *vk.DeviceMemory, vkalloc: *const vk.AllocationCallbacks) void {
    if (image.* != .null_handle) {
        dev.destroyImage(image.*, vkalloc);
        image.* = .null_handle;
    }
    if (memory.* != .null_handle) {
        dev.freeMemory(memory.*, vkalloc);
        memory.* = .null_handle;
    }
}

fn destroyRenderTarget(dev: DeviceProxy, rt: *RenderTarget, vkalloc: *const vk.AllocationCallbacks) void {
    destroyIfValid(dev, &rt.view, vkalloc);
    destroyIfValidImage(dev, &rt.image, &rt.memory, vkalloc);
}

fn renderingAttachmentColor(view: vk.ImageView, load_op: vk.AttachmentLoadOp, clear_color: [4]f32) vk.RenderingAttachmentInfo {
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

fn renderingAttachmentDepth(view: vk.ImageView, layout: vk.ImageLayout, load_op: vk.AttachmentLoadOp) vk.RenderingAttachmentInfo {
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

fn renderingInfo(
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

fn shaderStageCreateInfo(stage: vk.ShaderStageFlags, module: vk.ShaderModule) vk.PipelineShaderStageCreateInfo {
    return .{
        .flags = .{},
        .stage = stage,
        .module = module,
        .p_name = "main",
        .p_specialization_info = null,
    };
}

fn imageViewCreateInfo(image: vk.Image, format: vk.Format, aspect: vk.ImageAspectFlags) vk.ImageViewCreateInfo {
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

pub const null_image_info: [1]vk.DescriptorImageInfo = .{.{ .sampler = .null_handle, .image_view = .null_handle, .image_layout = .undefined }};
pub const null_buffer_info: [1]vk.DescriptorBufferInfo = .{.{ .buffer = .null_handle, .offset = 0, .range = 0 }};
pub const null_buffer_view: [1]vk.BufferView = .{vk.BufferView.null_handle};

fn dummyWriteDescriptorSet(dst_set: vk.DescriptorSet, dst_binding: u32, descriptor_type: vk.DescriptorType, buffer_info: *const vk.DescriptorBufferInfo) vk.WriteDescriptorSet {
    return .{
        .dst_set = dst_set,
        .dst_binding = dst_binding,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = descriptor_type,
        .p_image_info = &null_image_info,
        .p_buffer_info = (&buffer_info.*)[0..1],
        .p_texel_buffer_view = &null_buffer_view,
    };
}

fn imageWriteDescriptorSet(dst_set: vk.DescriptorSet, dst_binding: u32, image_info: *const vk.DescriptorImageInfo) vk.WriteDescriptorSet {
    return .{
        .dst_set = dst_set,
        .dst_binding = dst_binding,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = (&image_info.*)[0..1],
        .p_buffer_info = &null_buffer_info,
        .p_texel_buffer_view = &null_buffer_view,
    };
}

fn createImageWithMemory(self: *VulkanRenderer, extent: vk.Extent2D, format: vk.Format, usage: vk.ImageUsageFlags, aspect: vk.ImageAspectFlags) !RenderTarget {
    const image_info: vk.ImageCreateInfo = .{
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
    };
    var mem_reqs2: vk.MemoryRequirements2 = .{
        .memory_requirements = undefined,
    };
    self.dev.getDeviceImageMemoryRequirements(&.{ .p_create_info = &image_info, .plane_aspect = .{} }, &mem_reqs2);
    const mem_reqs = mem_reqs2.memory_requirements;

    const alloc_info: vk.MemoryAllocateInfo = .{
        .allocation_size = mem_reqs.size,
        .memory_type_index = try self.findMemoryType(mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    };

    var target: RenderTarget = .{};
    errdefer destroyRenderTarget(self.dev, &target, &self.vk_ctx.vkalloc);

    target.memory = try self.dev.allocateMemory(&alloc_info, &self.vk_ctx.vkalloc);
    target.image = try self.dev.createImage(&image_info, &self.vk_ctx.vkalloc);
    try self.dev.bindImageMemory(target.image, target.memory, 0);
    target.view = try self.dev.createImageView(&imageViewCreateInfo(target.image, format, aspect), &self.vk_ctx.vkalloc);
    return target;
}

fn dispatchCulling(self: *VulkanRenderer, cmd_buffer: vk.CommandBuffer, current_frame: u32, frustum: Frustum, total_candidates: u32, view_pos: @Vector(3, f64)) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "dispatchCulling" });
    defer zone.end();
    const frame = &self.frame_buffers.items[current_frame];
    self.dev.cmdFillBuffer(cmd_buffer, frame.count, frame.count_offset, @sizeOf(CullCount), 0);

    pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, (&makeBufferBarrier2(frame.count, frame.count_offset, @sizeOf(CullCount), .{ .all_transfer_bit = true }, .{ .transfer_write_bit = true }, .{ .compute_shader_bit = true }, .{ .shader_read_bit = true, .shader_write_bit = true }))[0..1]);

    self.dev.cmdBindPipeline(cmd_buffer, .compute, self.cull.pipeline);
    self.dev.cmdBindDescriptorSets(cmd_buffer, .compute, self.cull.pipeline_layout, 0, (&self.cull.descriptor_sets_per_frame[current_frame])[0..1], null);

    var push_consts: CullPushConstants = undefined;
    for (frustum.planes, 0..) |plane, idx| push_consts.planes[idx] = plane;
    push_consts.player_pos = .{ @floatCast(view_pos[0]), @floatCast(view_pos[1]), @floatCast(view_pos[2]), 1.0 };
    push_consts.total_candidates = total_candidates;
    push_consts.draw_capacity = self.draw_capacity;

    self.dev.cmdPushConstants(cmd_buffer, self.cull.pipeline_layout, .{ .compute_bit = true }, 0, @sizeOf(@TypeOf(push_consts)), &push_consts);

    const group_count = (total_candidates + (cull_workgroup_size - 1)) / cull_workgroup_size;
    self.dev.cmdDispatch(cmd_buffer, group_count, 1, 1);

    const buffer_barriers: [3]vk.BufferMemoryBarrier2 = .{
        makeBufferBarrier2(frame.indirect_draw, frame.indirect_draw_offset, self.draw_capacity * draw_type_count * @sizeOf(vk.DrawIndirectCommand), .{ .compute_shader_bit = true }, .{ .shader_write_bit = true }, .{ .draw_indirect_bit = true }, .{ .indirect_command_read_bit = true }),
        makeBufferBarrier2(frame.mesh_data, frame.mesh_data_offset, self.draw_capacity * draw_type_count * @sizeOf(MeshData), .{ .compute_shader_bit = true }, .{ .shader_write_bit = true }, .{ .vertex_shader_bit = true }, .{ .shader_read_bit = true }),
        makeBufferBarrier2(frame.count, frame.count_offset, @sizeOf(CullCount), .{ .compute_shader_bit = true }, .{ .shader_write_bit = true }, .{ .draw_indirect_bit = true, .all_transfer_bit = true }, .{ .indirect_command_read_bit = true, .transfer_read_bit = true }),
    };
    pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, &buffer_barriers);

    self.dev.cmdCopyBuffer(cmd_buffer, frame.count, frame.stats, (&vk.BufferCopy{ .src_offset = frame.count_offset, .dst_offset = frame.stats_offset, .size = @sizeOf(CullCount) })[0..1]);

    pipelineBarrier(cmd_buffer, self.dev, vk.BufferMemoryBarrier2, (&makeBufferBarrier2(frame.stats, frame.stats_offset, @sizeOf(CullCount), .{ .all_transfer_bit = true }, .{ .transfer_write_bit = true }, .{ .host_bit = true }, .{ .host_read_bit = true }))[0..1]);
}

fn emitFrameStartBarriers(self: *VulkanRenderer, cmd_buffer: vk.CommandBuffer, depth_aspect_mask: vk.ImageAspectFlags) void {
    const color_aspect: vk.ImageAspectFlags = .{ .color_bit = true };
    const color_old_layout: vk.ImageLayout = if (self.frame_sequence > 0) .shader_read_only_optimal else .undefined;
    const depth_old_layout: vk.ImageLayout = if (self.frame_sequence > 0) .depth_stencil_read_only_optimal else .undefined;
    const color_src_stage: vk.PipelineStageFlags2 = if (self.frame_sequence > 0) .{ .fragment_shader_bit = true } else .{ .top_of_pipe_bit = true };
    const color_src_access: vk.AccessFlags2 = if (self.frame_sequence > 0) .{ .shader_read_bit = true } else .{};
    const depth_src_stage: vk.PipelineStageFlags2 = if (self.frame_sequence > 0) .{ .fragment_shader_bit = true } else .{ .top_of_pipe_bit = true };
    const depth_src_access: vk.AccessFlags2 = if (self.frame_sequence > 0) .{ .depth_stencil_attachment_read_bit = true, .shader_read_bit = true } else .{};

    const pre_dispatch_img_barriers: [2]vk.ImageMemoryBarrier2 = .{
        makeImageBarrier2(self.render_color.image, color_old_layout, .color_attachment_optimal, color_src_stage, color_src_access, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, color_aspect),
        makeImageBarrier2(self.render_depth.image, depth_old_layout, .depth_stencil_attachment_optimal, depth_src_stage, depth_src_access, .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true }, .{ .depth_stencil_attachment_write_bit = true }, depth_aspect_mask),
    };
    pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, &pre_dispatch_img_barriers);
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
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordOpaquePass" });
    defer zone.end();
    self.emitFrameStartBarriers(cmd_buffer, depth_aspect_mask);

    if (total_candidates > 0) self.dispatchCulling(cmd_buffer, current_frame, frustum, total_candidates, view_pos);

    const color_attachment = renderingAttachmentColor(self.render_color.view, .clear, .{ sky_color[0], sky_color[1], sky_color[2], sky_color[3] });
    const depth_attachment = renderingAttachmentDepth(self.render_depth.view, .depth_stencil_attachment_optimal, .clear);

    self.dev.cmdBeginRendering(cmd_buffer, &renderingInfo(extent, &.{color_attachment}, &depth_attachment));

    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.graphics_state.pipeline);

    self.dev.cmdSetCullMode(cmd_buffer, .{ .back_bit = true });
    self.dev.cmdSetDepthCompareOp(cmd_buffer, .greater);
    self.dev.cmdSetDepthWriteEnable(cmd_buffer, .true);

    self.setViewportAndScissor(cmd_buffer, extent);

    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.graphics_state.opaque_pipeline_layout, 0, (&self.texture_manager.descriptor_set)[0..1], null);

    const mesh_desc_set = self.graphics_state.mesh_data_descriptor_sets_per_frame[current_frame];
    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.graphics_state.opaque_pipeline_layout, 1, (&mesh_desc_set)[0..1], null);

    var pc_opaque = pc;
    pc_opaque.mesh_base = 0;
    self.dev.cmdPushConstants(cmd_buffer, self.graphics_state.opaque_pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, push_constants_size, &pc_opaque);

    if (total_candidates > 0) {
        const frame = &self.frame_buffers.items[current_frame];
        const opaque_byte_offset: vk.DeviceSize = frame.indirect_draw_offset;
        const opaque_count_byte_offset: vk.DeviceSize = frame.count_offset;

        const face_buf = self.face_allocator.buffer.?;
        const face_buf_off: vk.DeviceSize = self.face_allocator.buffer_offset;
        self.dev.cmdBindVertexBuffers(cmd_buffer, 0, (&face_buf)[0..1], (&face_buf_off)[0..1]);

        self.dev.cmdDrawIndirectCount(cmd_buffer, frame.indirect_draw, opaque_byte_offset, frame.count, opaque_count_byte_offset, self.draw_capacity, @sizeOf(vk.DrawIndirectCommand));
    }

    self.dev.cmdEndRendering(cmd_buffer);
    pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, (&makeImageBarrier2(
        self.render_depth.image,
        .depth_stencil_attachment_optimal,
        .depth_stencil_read_only_optimal,
        .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .{ .depth_stencil_attachment_write_bit = true },
        .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true, .fragment_shader_bit = true },
        .{ .depth_stencil_attachment_read_bit = true, .shader_read_bit = true },
        depth_aspect_mask,
    ))[0..1]);
}

fn recordTransparentPass(
    self: *VulkanRenderer,
    cmd_buffer: vk.CommandBuffer,
    extent: vk.Extent2D,
    current_frame: u32,
    total_candidates: u32,
    pc: PushConstants,
) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordTransparentPass" });
    defer zone.end();
    const oit_color_aspect: vk.ImageAspectFlags = .{ .color_bit = true };
    const oit_old_layout: vk.ImageLayout = if (self.frame_sequence > 0) .shader_read_only_optimal else .undefined;
    const oit_src_stage: vk.PipelineStageFlags2 = if (self.frame_sequence > 0) .{ .fragment_shader_bit = true } else .{ .top_of_pipe_bit = true };
    const oit_src_access: vk.AccessFlags2 = if (self.frame_sequence > 0) .{ .shader_read_bit = true } else .{};
    const oit_pre_barriers: [3]vk.ImageMemoryBarrier2 = .{
        makeImageBarrier2(self.oit.accum.image, oit_old_layout, .color_attachment_optimal, oit_src_stage, oit_src_access, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, oit_color_aspect),
        makeImageBarrier2(self.oit.reveal.image, oit_old_layout, .color_attachment_optimal, oit_src_stage, oit_src_access, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, oit_color_aspect),
        makeImageBarrier2(self.oit.volume_weight.image, oit_old_layout, .color_attachment_optimal, oit_src_stage, oit_src_access, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, oit_color_aspect),
    };
    pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, &oit_pre_barriers);

    const oit_accum_attachment = renderingAttachmentColor(self.oit.accum.view, .clear, .{ 0.0, 0.0, 0.0, 1.0 });
    const oit_reveal_attachment = renderingAttachmentColor(self.oit.reveal.view, .clear, .{ 0.0, 0.0, 0.0, 0.0 });
    const oit_volume_attachment = renderingAttachmentColor(self.oit.volume_weight.view, .clear, .{ 0.0, 0.0, 0.0, 0.0 });
    const oit_depth_attachment = renderingAttachmentDepth(self.render_depth.view, .depth_stencil_read_only_optimal, .load);
    self.dev.cmdBeginRendering(cmd_buffer, &renderingInfo(extent, &.{ oit_accum_attachment, oit_reveal_attachment, oit_volume_attachment }, &oit_depth_attachment));

    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.graphics_state.transparent_pipeline);

    self.dev.cmdSetCullMode(cmd_buffer, .{});
    self.dev.cmdSetDepthCompareOp(cmd_buffer, .greater_or_equal);
    self.dev.cmdSetDepthWriteEnable(cmd_buffer, .false);
    self.setViewportAndScissor(cmd_buffer, extent);

    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.graphics_state.transparent_pipeline_layout, 0, (&self.texture_manager.descriptor_set)[0..1], null);

    const depth_image_info: vk.DescriptorImageInfo = .{
        .image_layout = .depth_stencil_read_only_optimal,
        .image_view = self.render_depth_sampled_view,
        .sampler = self.texture_manager.sampler,
    };
    // dst_set is ignored by cmdPushDescriptorSetKHR, so null_handle is intentional.
    const depth_write = imageWriteDescriptorSet(.null_handle, 0, &depth_image_info);
    self.dev.cmdPushDescriptorSetKHR(cmd_buffer, .graphics, self.graphics_state.transparent_pipeline_layout, 2, (&depth_write)[0..1]);

    const mesh_desc_set = self.graphics_state.mesh_data_descriptor_sets_per_frame[current_frame];
    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.graphics_state.transparent_pipeline_layout, 1, (&mesh_desc_set)[0..1], null);

    if (self.block_materials_descriptor_set != .null_handle) {
        self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.graphics_state.transparent_pipeline_layout, 3, (&self.block_materials_descriptor_set)[0..1], null);
    }

    var pc_transparent = pc;
    pc_transparent.mesh_base = self.draw_capacity;
    self.dev.cmdPushConstants(cmd_buffer, self.graphics_state.transparent_pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, push_constants_size, &pc_transparent);

    if (total_candidates > 0) {
        const frame = &self.frame_buffers.items[current_frame];
        const transparent_byte_offset: vk.DeviceSize = frame.indirect_draw_offset + @as(vk.DeviceSize, @intCast(self.draw_capacity * @sizeOf(vk.DrawIndirectCommand)));
        const transparent_count_byte_offset: vk.DeviceSize = frame.count_offset + @as(vk.DeviceSize, @intCast(@offsetOf(CullCount, "transparent_count")));

        const face_buf = self.face_allocator.buffer.?;
        const face_buf_off: vk.DeviceSize = self.face_allocator.buffer_offset;
        self.dev.cmdBindVertexBuffers(cmd_buffer, 0, (&face_buf)[0..1], (&face_buf_off)[0..1]);

        self.dev.cmdDrawIndirectCount(cmd_buffer, frame.indirect_draw, transparent_byte_offset, frame.count, transparent_count_byte_offset, self.draw_capacity, @sizeOf(vk.DrawIndirectCommand));
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
    scatter_enabled: u32,
    swapchain_old_layout: vk.ImageLayout,
    swapchain_layout_ptr: ?*vk.ImageLayout,
) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordCompositionPass" });
    defer zone.end();
    const color_aspect: vk.ImageAspectFlags = .{ .color_bit = true };

    const pre_comp_barriers: [5]vk.ImageMemoryBarrier2 = .{
        makeImageBarrier2(self.render_color.image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true }, color_aspect),
        makeImageBarrier2(self.oit.accum.image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true }, color_aspect),
        makeImageBarrier2(self.oit.reveal.image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true }, color_aspect),
        makeImageBarrier2(self.oit.volume_weight.image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true }, color_aspect),
        makeImageBarrier2(
            output_image,
            swapchain_old_layout,
            .color_attachment_optimal,
            switch (swapchain_old_layout) {
                .undefined => .{ .top_of_pipe_bit = true },
                .present_src_khr => .{ .color_attachment_output_bit = true },
                else => .{ .all_commands_bit = true },
            },
            switch (swapchain_old_layout) {
                .undefined => .{},
                .present_src_khr => .{},
                else => .{ .memory_write_bit = true },
            },
            .{ .color_attachment_output_bit = true },
            .{ .color_attachment_write_bit = true, .color_attachment_read_bit = true },
            color_aspect,
        ),
    };
    pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, &pre_comp_barriers);

    const swapchain_attachment = renderingAttachmentColor(output_view, .dont_care, .{ 0.0, 0.0, 0.0, 0.0 });
    self.dev.cmdBeginRendering(cmd_buffer, &renderingInfo(extent, &.{swapchain_attachment}, null));

    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.oit.composition_pipeline);
    self.setViewportAndScissor(cmd_buffer, extent);

    self.dev.cmdPushConstants(cmd_buffer, self.oit.composition_layout, .{ .fragment_bit = true }, 0, @sizeOf(u32), &scatter_enabled);

    const oit_desc_set: vk.DescriptorSet = self.oit.descriptor_sets_per_frame[current_frame];
    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.oit.composition_layout, 0, (&oit_desc_set)[0..1], null);
    self.dev.cmdDraw(cmd_buffer, 3, 1, 0, 0);

    self.dev.cmdEndRendering(cmd_buffer);
    pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, (&makeImageBarrier2(output_image, .color_attachment_optimal, .present_src_khr, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true }, .{}, color_aspect))[0..1]);

    if (swapchain_layout_ptr) |ptr| ptr.* = .present_src_khr;
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

    try self.processPendingUploads(io);
    try self.processRetiredMeshes(io);

    const extent: vk.Extent2D = .{ .width = target.width, .height = target.height };

    if (self.frame_buffers.items[current_frame].stats_mapped) |counts_ptr| {
        self.frame_stats.opaque_drawn = counts_ptr[0].opaque_count;
        self.frame_stats.transparent_drawn = counts_ptr[0].transparent_count;
        self.frame_stats.opaque_faces = counts_ptr[0].opaque_face_count;
        self.frame_stats.transparent_faces = counts_ptr[0].transparent_face_count;
    }

    self.render_options_lock.lockSharedUncancelable(io);
    defer self.render_options_lock.unlockShared(io);
    const aspect = @as(f32, @floatFromInt(target.width)) / @as(f32, @floatFromInt(target.height));
    const fov = std.math.degreesToRadians(self.render_options.fov);
    const day_length_sec = self.render_options.day_length_sec;
    const inside_transparent = self.render_options.inside_transparent;

    const vp = self.computeViewProjection(aspect, fov);
    const sky_t: f32 = @floatCast(@min(1.0, @max(0.0, view_pos[1] / sky_height)));
    const sky_color = std.math.lerp(
        @Vector(4, f32){ 0.0, 0.4, 0.8, 1.0 },
        @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 },
        @as(@Vector(4, f32), @splat(sky_t)),
    );
    const sun_dir = computeSunDirection(io, day_length_sec);
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const elapsed_sec = @as(f32, @floatFromInt(now_ns -| self.init_time_ns)) / std.time.ns_per_s;

    const total_candidates = self.max_allocated_index.load(.monotonic);
    if (total_candidates > self.draw_capacity) try self.growDrawCapacity(io, total_candidates);

    const projview_array: [16]f32 = @bitCast(vp.projview);
    var pc: PushConstants = .{
        .projview = @splat(0),
        .sun_dir = sun_dir,
        .time = elapsed_sec,
        .mesh_base = 0,
    };
    for (&pc.projview, 0..) |*dst, i| {
        const row = i / 4;
        const col = i % 4;
        dst.* = projview_array[col * 4 + row];
    }

    try self.dev.beginCommandBuffer(cmd_buffer, &.{ .flags = .{ .one_time_submit_bit = true }, .p_inheritance_info = null });
    errdefer self.dev.endCommandBuffer(cmd_buffer) catch {};

    const depth_aspect_mask: vk.ImageAspectFlags = if (self.depthHasStencil()) .{ .depth_bit = true, .stencil_bit = true } else .{ .depth_bit = true };
    const frame_start_ns = std.Io.Timestamp.now(io, .real).nanoseconds;

    // Acquire the transfer writes once per frame (not per-pass) to avoid duplicate barriers.
    self.cmdAcquireFaceBuffer(cmd_buffer);
    self.recordOpaquePass(cmd_buffer, extent, current_frame, total_candidates, pc, sky_color, view_pos, vp.frustum, depth_aspect_mask);
    self.recordTransparentPass(cmd_buffer, extent, current_frame, total_candidates, pc);

    const frame_end_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const frame_elapsed_ns: u64 = @intCast(@max(0, frame_end_ns - frame_start_ns));

    const frame_num = self.vk_ctx.frame_number.load(.acquire) + 1;
    self.frame_stats.frame_number = frame_num;
    self.frame_stats.total_meshes = @intCast(self.meshes.count(io));
    self.frame_stats.player_pos = view_pos;
    self.frame_stats.camera_front = .{
        self.camera_front_x.load(.monotonic),
        self.camera_front_y.load(.monotonic),
        self.camera_front_z.load(.monotonic),
    };
    self.frame_stats.elapsed_ns = frame_elapsed_ns;

    if (frame_end_ns - self.last_stat_log_ns >= std.time.ns_per_s) {
        self.last_stat_log_ns = @intCast(frame_end_ns);
        self.frame_stats.log();
    }

    const scatter_enabled: u32 = @intFromBool(!inside_transparent);
    self.recordCompositionPass(cmd_buffer, extent, output_image, output_view, current_frame, scatter_enabled, swapchain_old_layout, swapchain_layout_ptr);

    // Release this frame's vertex reads so the next upload batch can write;
    // pairs with cmdAcquireFaceBuffer at frame start.
    self.cmdReleaseFaceBuffer(cmd_buffer);

    self.frame_sequence += 1;
    try self.dev.endCommandBuffer(cmd_buffer);
}

fn vtableDraw(user_data: *Renderer.Implementation, io: std.Io, target: Renderer.DrawTarget, frame_ctx: FrameDrawContext, view_pos: @Vector(3, f64)) (std.Io.Cancelable || error{DrawFailed})!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    self.draw(io, target, frame_ctx, view_pos) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.DrawFailed,
    };
}

fn growDrawCapacity(self: *VulkanRenderer, io: std.Io, min_capacity: u32) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "growDrawCapacity" });
    defer zone.end();

    if (min_capacity <= self.draw_capacity) return;

    var new_capacity = self.draw_capacity;
    while (new_capacity < min_capacity) new_capacity *= 2;

    const clamped_capacity = @min(new_capacity, self.max_draw_indirect_count);
    if (clamped_capacity < new_capacity) {
        std.log.err("VulkanRenderer: draw capacity {d} exceeds device max indirect count {d}. Cannot continue rendering.", .{ new_capacity, self.max_draw_indirect_count });
        return error.MaxDrawCapacityExceeded;
    }
    new_capacity = clamped_capacity;

    std.log.info("VulkanRenderer: Growing draw capacity from {d} to {d} for all frames...", .{ self.draw_capacity, new_capacity });

    self.vk_ctx.queue_mutex.lockUncancelable(io);
    defer self.vk_ctx.queue_mutex.unlock(io);
    _ = try self.dev.deviceWaitIdle();

    const old_draw_capacity = self.draw_capacity;
    const num_frames = self.frame_buffers.items.len;

    const old_mesh_data = try self.allocator.alloc([*]MeshData, num_frames);
    defer self.allocator.free(old_mesh_data);
    const old_indirect = try self.allocator.alloc([*]vk.DrawIndirectCommand, num_frames);
    defer self.allocator.free(old_indirect);
    const old_count_slices = try self.allocator.alloc([]align(cull_buffer_alignment.toByteUnits()) CullCount, num_frames);
    defer self.allocator.free(old_count_slices);
    const old_stats_slices = try self.allocator.alloc([]align(cull_buffer_alignment.toByteUnits()) CullCount, num_frames);
    defer self.allocator.free(old_stats_slices);

    for (self.frame_buffers.items[0..num_frames], old_mesh_data, old_indirect, old_count_slices, old_stats_slices) |frame, *mesh, *ind, *count, *stats| {
        mesh.* = frame.mesh_data_mapped.?;
        ind.* = frame.indirect_draw_mapped.?;
        count.* = frame.count_slice;
        stats.* = frame.stats_slice;
    }

    for (self.frame_buffers.items[0..num_frames], old_mesh_data, old_indirect, old_count_slices, old_stats_slices) |*frame, old_mesh, old_ind, old_count, old_stats| {
        const mesh_data_slice = try self.cpu_to_gpu_gpa.allocator().alloc(MeshData, new_capacity * draw_type_count);
        const indirect_draw_slice = try self.cpu_to_gpu_gpa.allocator().alloc(vk.DrawIndirectCommand, new_capacity * draw_type_count);
        const count_slice = try self.gpu_only_gpa.allocator().alignedAlloc(CullCount, cull_buffer_alignment, 1);
        const stats_slice = try self.cpu_to_gpu_gpa.allocator().alignedAlloc(CullCount, cull_buffer_alignment, 1);
        stats_slice[0] = .{ .opaque_count = 0, .transparent_count = 0, .opaque_face_count = 0, .transparent_face_count = 0 };

        if (old_draw_capacity > 0) {
            @memcpy(mesh_data_slice[0 .. old_draw_capacity * draw_type_count], old_mesh[0 .. old_draw_capacity * draw_type_count]);
            @memcpy(indirect_draw_slice[0 .. old_draw_capacity * draw_type_count], old_ind[0 .. old_draw_capacity * draw_type_count]);
        }

        const mesh_data_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, mesh_data_slice.ptr);
        const indirect_draw_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, indirect_draw_slice.ptr);
        const count_info = self.backing_allocator.getBufferAndOffset(.gpu_only, count_slice.ptr);
        const stats_info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, stats_slice.ptr);

        frame.* = .{
            .mesh_data = mesh_data_info.buffer,
            .mesh_data_mapped = mesh_data_slice.ptr,
            .mesh_data_offset = mesh_data_info.offset,
            .indirect_draw = indirect_draw_info.buffer,
            .indirect_draw_mapped = indirect_draw_slice.ptr,
            .indirect_draw_offset = indirect_draw_info.offset,
            .count = count_info.buffer,
            .count_slice = count_slice,
            .count_offset = count_info.offset,
            .stats = stats_info.buffer,
            .stats_slice = stats_slice,
            .stats_offset = stats_info.offset,
            .stats_mapped = stats_slice.ptr,
        };

        self.cpu_to_gpu_gpa.allocator().free(old_mesh[0 .. old_draw_capacity * draw_type_count]);
        self.cpu_to_gpu_gpa.allocator().free(old_ind[0 .. old_draw_capacity * draw_type_count]);
        self.gpu_only_gpa.allocator().free(old_count);
        self.cpu_to_gpu_gpa.allocator().free(old_stats);
    }

    self.draw_capacity = new_capacity;

    for (self.frame_buffers.items[0..num_frames], 0..) |_, i| {
        self.updateCullDescriptorSet(@intCast(i));
        self.updateMeshDataDescriptorSet(@intCast(i));
    }
}

fn growPersistentCandidates(self: *VulkanRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "growPersistentCandidates" });
    defer zone.end();

    const old_capacity = self.persistent.slice.len;
    const new_capacity = old_capacity * 2;
    std.log.info("VulkanRenderer: Growing persistent GPU scene candidates from {d} to {d}...", .{ old_capacity, new_capacity });

    self.vk_ctx.queue_mutex.lockUncancelable(io);
    defer self.vk_ctx.queue_mutex.unlock(io);
    _ = try self.dev.deviceWaitIdle();

    const new_slice = try self.cpu_to_gpu_gpa.allocator().alloc(MeshCandidate, new_capacity);
    @memset(new_slice, .{ .absolute_position = .{ 0, 0, 0, 0 }, .scale = 0, .face_count = 0, .is_transparent = 0, .face_offset = 0 });

    @memcpy(new_slice[0..old_capacity], self.persistent.slice[0..old_capacity]);

    const info = self.backing_allocator.getBufferAndOffset(.cpu_to_gpu, new_slice.ptr);
    const old_slice = self.persistent.slice;

    self.persistent.buffer = info.buffer;
    self.persistent.mapped = new_slice.ptr;
    self.persistent.offset = info.offset;
    self.persistent.slice = new_slice;

    const current_frame_num = self.vk_ctx.frame_number.load(.acquire);
    try self.retired_candidate_slices.append(self.allocator, .{
        .slice = old_slice,
        .graphics_timeline_value = current_frame_num + self.num_in_flight,
    });

    try self.index_pool.grow(io, self.allocator, @intCast(new_capacity));

    for (self.cull.descriptor_sets_per_frame, 0..) |_, i| self.updateCullDescriptorSet(@intCast(i));
}

/// Public API: finds a memory type on this renderer's device.
/// findMemoryTypeRaw is kept as a separate function so the unit test can exercise it without a live device.
pub fn findMemoryType(self: *const VulkanRenderer, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    return findMemoryTypeRaw(self.vk_ctx.mem_props, type_filter, properties);
}

fn depthHasStencil(self: *const VulkanRenderer) bool {
    return self.depth_format == .d32_sfloat_s8_uint or self.depth_format == .d24_unorm_s8_uint;
}

fn destroyOitResources(self: *VulkanRenderer) void {
    destroyRenderTarget(self.dev, &self.oit.accum, &self.vk_ctx.vkalloc);
    destroyRenderTarget(self.dev, &self.oit.reveal, &self.vk_ctx.vkalloc);
    destroyRenderTarget(self.dev, &self.oit.volume_weight, &self.vk_ctx.vkalloc);

    if (self.oit.descriptor_pool != .null_handle) {
        self.dev.destroyDescriptorPool(self.oit.descriptor_pool, &self.vk_ctx.vkalloc);
        self.oit.descriptor_pool = .null_handle;
    }
    if (self.oit.descriptor_sets_per_frame.len > 0) {
        self.allocator.free(self.oit.descriptor_sets_per_frame);
        self.oit.descriptor_sets_per_frame = &.{};
    }
}

fn createRenderTargets(self: *VulkanRenderer, extent: vk.Extent2D) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "createRenderTargets" });
    defer zone.end();
    destroyRenderTarget(self.dev, &self.render_color, &self.vk_ctx.vkalloc);
    destroyRenderTarget(self.dev, &self.render_depth, &self.vk_ctx.vkalloc);
    destroyIfValid(self.dev, &self.render_depth_sampled_view, &self.vk_ctx.vkalloc);
    self.destroyOitResources();

    errdefer {
        destroyRenderTarget(self.dev, &self.render_color, &self.vk_ctx.vkalloc);
        destroyRenderTarget(self.dev, &self.render_depth, &self.vk_ctx.vkalloc);
        destroyIfValid(self.dev, &self.render_depth_sampled_view, &self.vk_ctx.vkalloc);
        self.destroyOitResources();
    }

    const color = try self.createImageWithMemory(extent, self.vk_ctx.swapchain_format, .{ .color_attachment_bit = true, .transfer_src_bit = true, .sampled_bit = true }, .{ .color_bit = true });
    self.render_color = color;

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
    self.render_depth_sampled_view = try self.dev.createImageView(&imageViewCreateInfo(depth.image, depth_format, .{ .depth_bit = true }), &self.vk_ctx.vkalloc);

    const oit_usage: vk.ImageUsageFlags = .{ .color_attachment_bit = true, .sampled_bit = true };
    const oit_aspect: vk.ImageAspectFlags = .{ .color_bit = true };
    self.oit.accum = try self.createImageWithMemory(extent, .r16g16b16a16_sfloat, oit_usage, oit_aspect);
    self.oit.reveal = try self.createImageWithMemory(extent, .r16g16b16a16_sfloat, oit_usage, oit_aspect);
    self.oit.volume_weight = try self.createImageWithMemory(extent, .r16_sfloat, oit_usage, oit_aspect);

    if (self.oit.descriptor_sets_per_frame.len > 0) self.updateOitDescriptorSets();

    std.log.info("VulkanRenderer.createRenderTargets: SUCCESS - Created render targets: color {any}, depth {any}, accum {any}, reveal {any}\n", .{ self.render_color.image, self.render_depth.image, self.oit.accum.image, self.oit.reveal.image });
    self.frame_sequence = 0;
}

fn createTransparentDepthDescriptorSetLayout(self: *VulkanRenderer) !void {
    if (self.graphics_state.transparent_depth_descriptor_set_layout == .null_handle) {
        const binding = vk.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null };
        self.graphics_state.transparent_depth_descriptor_set_layout = try self.dev.createDescriptorSetLayout(&.{ .flags = .{ .push_descriptor_bit = true }, .binding_count = 1, .p_bindings = (&binding)[0..1] }, &self.vk_ctx.vkalloc);
    }
}

fn createMeshDataDescriptorResources(self: *VulkanRenderer) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "createMeshDataDescriptorResources" });
    defer zone.end();
    if (self.graphics_state.mesh_data_descriptor_set_layout == .null_handle) {
        const binding = vk.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .vertex_bit = true }, .p_immutable_samplers = null };
        self.graphics_state.mesh_data_descriptor_set_layout = try self.dev.createDescriptorSetLayout(&.{ .flags = .{}, .binding_count = 1, .p_bindings = (&binding)[0..1] }, &self.vk_ctx.vkalloc);
    }

    const pool_size = vk.DescriptorPoolSize{ .type = .storage_buffer, .descriptor_count = @intCast(VulkanContext.max_frames_in_flight) };
    try self.createFrameDescriptorPool(&self.graphics_state.mesh_data_descriptor_pool, self.graphics_state.mesh_data_descriptor_set_layout, &self.graphics_state.mesh_data_descriptor_sets_per_frame, (&pool_size)[0..1]);

    for (0..VulkanContext.max_frames_in_flight) |i| self.updateMeshDataDescriptorSet(@intCast(i));
}

fn updateMeshDataDescriptorSet(self: *VulkanRenderer, frame_idx: u32) void {
    const info: vk.DescriptorBufferInfo = .{
        .buffer = self.frame_buffers.items[frame_idx].mesh_data,
        .offset = self.frame_buffers.items[frame_idx].mesh_data_offset,
        .range = self.draw_capacity * draw_type_count * @sizeOf(MeshData),
    };
    self.dev.updateDescriptorSets((&dummyWriteDescriptorSet(self.graphics_state.mesh_data_descriptor_sets_per_frame[frame_idx], 0, .storage_buffer, &info))[0..1], null);
}

fn destroyMeshDataDescriptorResources(self: *VulkanRenderer) void {
    if (self.graphics_state.mesh_data_descriptor_pool != .null_handle) {
        self.dev.destroyDescriptorPool(self.graphics_state.mesh_data_descriptor_pool, &self.vk_ctx.vkalloc);
        self.graphics_state.mesh_data_descriptor_pool = .null_handle;
    }
    if (self.graphics_state.mesh_data_descriptor_sets_per_frame.len > 0) {
        self.allocator.free(self.graphics_state.mesh_data_descriptor_sets_per_frame);
        self.graphics_state.mesh_data_descriptor_sets_per_frame = &.{};
    }
}

fn createCullDescriptorSetLayoutAndPool(self: *VulkanRenderer) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "createCullDescriptorSetLayoutAndPool" });
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
    try self.createFrameDescriptorPool(&self.cull.descriptor_pool, self.cull.descriptor_set_layout, &self.cull.descriptor_sets_per_frame, (&pool_size)[0..1]);

    for (0..VulkanContext.max_frames_in_flight) |i| self.updateCullDescriptorSet(@intCast(i));
}

fn updateCullDescriptorSet(self: *VulkanRenderer, frame_idx: u32) void {
    const infos: [4]vk.DescriptorBufferInfo = .{
        .{ .buffer = self.persistent.buffer, .offset = self.persistent.offset, .range = self.persistent.slice.len * @sizeOf(MeshCandidate) },
        .{ .buffer = self.frame_buffers.items[frame_idx].indirect_draw, .offset = self.frame_buffers.items[frame_idx].indirect_draw_offset, .range = self.draw_capacity * draw_type_count * @sizeOf(vk.DrawIndirectCommand) },
        .{ .buffer = self.frame_buffers.items[frame_idx].mesh_data, .offset = self.frame_buffers.items[frame_idx].mesh_data_offset, .range = self.draw_capacity * draw_type_count * @sizeOf(MeshData) },
        .{ .buffer = self.frame_buffers.items[frame_idx].count, .offset = self.frame_buffers.items[frame_idx].count_offset, .range = @sizeOf(CullCount) },
    };
    var writes: [4]vk.WriteDescriptorSet = undefined;
    inline for (infos, 0..) |info, i| writes[i] = dummyWriteDescriptorSet(self.cull.descriptor_sets_per_frame[frame_idx], @intCast(i), .storage_buffer, &info);
    self.dev.updateDescriptorSets(&writes, null);
}

fn createFrameDescriptorPool(self: *VulkanRenderer, pool: *vk.DescriptorPool, layout: vk.DescriptorSetLayout, sets: *[]vk.DescriptorSet, pool_sizes: []const vk.DescriptorPoolSize) !void {
    const num_frames = VulkanContext.max_frames_in_flight;
    pool.* = try self.dev.createDescriptorPool(&.{ .flags = .{}, .max_sets = @intCast(num_frames), .pool_size_count = @intCast(pool_sizes.len), .p_pool_sizes = pool_sizes.ptr }, &self.vk_ctx.vkalloc);
    errdefer if (pool.* != .null_handle) {
        self.dev.destroyDescriptorPool(pool.*, &self.vk_ctx.vkalloc);
        pool.* = .null_handle;
    };

    sets.* = try self.allocator.alloc(vk.DescriptorSet, num_frames);
    errdefer {
        self.allocator.free(sets.*);
        sets.* = &.{};
    }

    const layouts = try self.allocator.alloc(vk.DescriptorSetLayout, num_frames);
    defer self.allocator.free(layouts);
    @memset(layouts, layout);

    try self.dev.allocateDescriptorSets(&.{ .descriptor_pool = pool.*, .descriptor_set_count = @intCast(num_frames), .p_set_layouts = layouts.ptr }, sets.*.ptr);
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
    vertex_input_info: vk.PipelineVertexInputStateCreateInfo,
) !vk.Pipeline {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "buildGraphicsPipeline" });
    defer zone.end();
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
    const dyn: vk.PipelineDynamicStateCreateInfo = .{ .flags = .{}, .dynamic_state_count = @intCast(dyn_states.items.len), .p_dynamic_states = dyn_states.items.ptr };

    const pssci: [2]vk.PipelineShaderStageCreateInfo = .{
        shaderStageCreateInfo(.{ .vertex_bit = true }, vert_module),
        shaderStageCreateInfo(.{ .fragment_bit = true }, frag_module),
    };

    // Extern struct — all fields explicit; zeroed so valid_bit is false if driver ignores the pNext struct.
    var pipeline_feedback: vk.PipelineCreationFeedback = .{ .flags = .{}, .duration = 0 };
    var stage_feedbacks: [2]vk.PipelineCreationFeedback = .{ .{ .flags = .{}, .duration = 0 }, .{ .flags = .{}, .duration = 0 } };
    // Function scope so the pointer in rendering_info.p_next outlives the if block below.
    var feedback_info: vk.PipelineCreationFeedbackCreateInfo = .{ .p_pipeline_creation_feedback = &pipeline_feedback, .pipeline_stage_creation_feedback_count = 2, .p_pipeline_stage_creation_feedbacks = &stage_feedbacks };

    const stencil_format: vk.Format = if (depth_format == .d32_sfloat_s8_uint or depth_format == .d24_unorm_s8_uint) depth_format else .undefined;
    var rendering_info: vk.PipelineRenderingCreateInfo = .{
        .p_next = null,
        .view_mask = 0,
        .color_attachment_count = @intCast(color_formats.len),
        .p_color_attachment_formats = color_formats.ptr,
        .depth_attachment_format = depth_format,
        .stencil_attachment_format = stencil_format,
    };
    if (self.vk_ctx.pipeline_creation_feedback) {
        rendering_info.p_next = @ptrCast(&feedback_info);
    }
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
    if (self.dev.createGraphicsPipelines(.null_handle, (&gpci)[0..1], &self.vk_ctx.vkalloc, (&pipeline)[0..1])) |res| {
        if (res != .success) return error.PipelineCreationFailed;
    } else |err| return err;

    if (self.vk_ctx.pipeline_creation_feedback and pipeline_feedback.flags.valid_bit) {
        std.log.debug("Vulkan: Pipeline compilation took {d:.3} ms (cached: {})", .{
            @as(f64, @floatFromInt(pipeline_feedback.duration)) / 1_000_000.0,
            pipeline_feedback.flags.application_pipeline_cache_hit_bit,
        });
    }

    return pipeline;
}

fn createOpaquePipeline(self: *VulkanRenderer, vert_module: vk.ShaderModule) !void {
    const pc_range: vk.PushConstantRange = .{
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .offset = 0,
        .size = push_constants_size,
    };
    const set_layouts: [2]vk.DescriptorSetLayout = .{
        self.texture_manager.descriptor_set_layout,
        self.graphics_state.mesh_data_descriptor_set_layout,
    };
    self.graphics_state.opaque_pipeline_layout = try self.dev.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = set_layouts.len,
        .p_set_layouts = &set_layouts,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = (&pc_range)[0..1],
    }, &self.vk_ctx.vkalloc);

    const frag_module = try self.dev.createShaderModule(&.{ .flags = .{}, .code_size = fragment_shader_spv.len * @sizeOf(u32), .p_code = fragment_shader_spv.ptr }, &self.vk_ctx.vkalloc);
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
    const face_vertex_input: vk.PipelineVertexInputStateCreateInfo = .{
        .flags = .{},
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = (&vk.VertexInputBindingDescription{ .binding = 0, .stride = 8, .input_rate = .instance })[0..1],
        .vertex_attribute_description_count = 1,
        .p_vertex_attribute_descriptions = (&vk.VertexInputAttributeDescription{ .location = 0, .binding = 0, .format = .r32g32_uint, .offset = 0 })[0..1],
    };
    self.graphics_state.pipeline = try self.buildGraphicsPipeline(vert_module, frag_module, &.{self.vk_ctx.swapchain_format}, self.depth_format, depth_stencil, &.{blend}, self.graphics_state.opaque_pipeline_layout, face_vertex_input);
}

fn createTransparentPipeline(self: *VulkanRenderer, vert_module: vk.ShaderModule) !void {
    const pc_range: vk.PushConstantRange = .{
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .offset = 0,
        .size = push_constants_size,
    };
    const set_layouts: [4]vk.DescriptorSetLayout = .{
        self.texture_manager.descriptor_set_layout,
        self.graphics_state.mesh_data_descriptor_set_layout,
        self.graphics_state.transparent_depth_descriptor_set_layout,
        self.block_materials_descriptor_set_layout,
    };
    self.graphics_state.transparent_pipeline_layout = try self.dev.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = set_layouts.len,
        .p_set_layouts = &set_layouts,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = (&pc_range)[0..1],
    }, &self.vk_ctx.vkalloc);

    const frag_module = try self.dev.createShaderModule(&.{ .flags = .{}, .code_size = transparent_frag_spv.len * @sizeOf(u32), .p_code = transparent_frag_spv.ptr }, &self.vk_ctx.vkalloc);
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
    const face_vertex_input: vk.PipelineVertexInputStateCreateInfo = .{
        .flags = .{},
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = (&vk.VertexInputBindingDescription{ .binding = 0, .stride = 8, .input_rate = .instance })[0..1],
        .vertex_attribute_description_count = 1,
        .p_vertex_attribute_descriptions = (&vk.VertexInputAttributeDescription{ .location = 0, .binding = 0, .format = .r32g32_uint, .offset = 0 })[0..1],
    };
    self.graphics_state.transparent_pipeline = try self.buildGraphicsPipeline(vert_module, frag_module, &formats, self.depth_format, depth_stencil, &blend_attachments, self.graphics_state.transparent_pipeline_layout, face_vertex_input);
}

fn createGraphicsPipelines(self: *VulkanRenderer) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "createGraphicsPipelines" });
    defer zone.end();

    const vert_module = try self.dev.createShaderModule(&.{ .flags = .{}, .code_size = vertex_shader_spv.len * @sizeOf(u32), .p_code = vertex_shader_spv.ptr }, &self.vk_ctx.vkalloc);
    defer self.dev.destroyShaderModule(vert_module, &self.vk_ctx.vkalloc);

    try self.createOpaquePipeline(vert_module);
    try self.createTransparentPipeline(vert_module);
}

fn createCullPipeline(self: *VulkanRenderer) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "createCullPipeline" });
    defer zone.end();
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

    const comp_module = try self.dev.createShaderModule(&.{ .flags = .{}, .code_size = cull_shader_spv.len * @sizeOf(u32), .p_code = cull_shader_spv.ptr }, &self.vk_ctx.vkalloc);
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
}

fn createOitPipelinesAndDescriptors(self: *VulkanRenderer) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "createOitPipelinesAndDescriptors" });
    defer zone.end();
    if (self.oit.descriptor_set_layout == .null_handle) {
        const bindings: [4]vk.DescriptorSetLayoutBinding = .{
            .{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 2, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 3, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
        };
        self.oit.descriptor_set_layout = try self.dev.createDescriptorSetLayout(&.{ .flags = .{}, .binding_count = bindings.len, .p_bindings = bindings[0..] }, &self.vk_ctx.vkalloc);
    }

    if (self.oit.composition_layout == .null_handle) {
        const pc_range: vk.PushConstantRange = .{ .stage_flags = .{ .fragment_bit = true }, .offset = 0, .size = @sizeOf(u32) };
        self.oit.composition_layout = try self.dev.createPipelineLayout(&.{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = (&self.oit.descriptor_set_layout)[0..1],
            .push_constant_range_count = 1,
            .p_push_constant_ranges = (&pc_range)[0..1],
        }, &self.vk_ctx.vkalloc);
    }

    if (self.oit.sampler == .null_handle) {
        self.oit.sampler = try self.dev.createSampler(&.{
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
        }, &self.vk_ctx.vkalloc);
        errdefer {
            self.dev.destroySampler(self.oit.sampler, &self.vk_ctx.vkalloc);
            self.oit.sampler = .null_handle;
        }
    }

    const vert_module = try self.dev.createShaderModule(&.{ .flags = .{}, .code_size = composite_vert_spv.len * @sizeOf(u32), .p_code = composite_vert_spv.ptr }, &self.vk_ctx.vkalloc);
    defer self.dev.destroyShaderModule(vert_module, &self.vk_ctx.vkalloc);
    const frag_module = try self.dev.createShaderModule(&.{ .flags = .{}, .code_size = composite_frag_spv.len * @sizeOf(u32), .p_code = composite_frag_spv.ptr }, &self.vk_ctx.vkalloc);
    defer self.dev.destroyShaderModule(frag_module, &self.vk_ctx.vkalloc);

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
    const no_vertex_input: vk.PipelineVertexInputStateCreateInfo = .{
        .flags = .{},
        .vertex_binding_description_count = 0,
        .p_vertex_binding_descriptions = null,
        .vertex_attribute_description_count = 0,
        .p_vertex_attribute_descriptions = null,
    };
    self.oit.composition_pipeline = try self.buildGraphicsPipeline(vert_module, frag_module, &.{self.vk_ctx.swapchain_format}, .undefined, null, &.{blend}, self.oit.composition_layout, no_vertex_input);

    const pool_size: vk.DescriptorPoolSize = .{ .type = .combined_image_sampler, .descriptor_count = @intCast(VulkanContext.max_frames_in_flight * 4) };
    try self.createFrameDescriptorPool(&self.oit.descriptor_pool, self.oit.descriptor_set_layout, &self.oit.descriptor_sets_per_frame, (&pool_size)[0..1]);
    self.updateOitDescriptorSets();
}

fn updateOitDescriptorSets(self: *VulkanRenderer) void {
    const image_infos: [4]vk.DescriptorImageInfo = .{
        .{ .sampler = self.oit.sampler, .image_view = self.render_color.view, .image_layout = .shader_read_only_optimal },
        .{ .sampler = self.oit.sampler, .image_view = self.oit.accum.view, .image_layout = .shader_read_only_optimal },
        .{ .sampler = self.oit.sampler, .image_view = self.oit.reveal.view, .image_layout = .shader_read_only_optimal },
        .{ .sampler = self.oit.sampler, .image_view = self.oit.volume_weight.view, .image_layout = .shader_read_only_optimal },
    };
    const dummy_buffer_info: vk.DescriptorBufferInfo = .{ .buffer = .null_handle, .offset = 0, .range = 0 };
    const dummy_texel_buffer_view: vk.BufferView = .null_handle;
    for (self.oit.descriptor_sets_per_frame) |desc_set| {
        const writes: [4]vk.WriteDescriptorSet = .{
            .{ .dst_set = desc_set, .dst_binding = 0, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .p_image_info = image_infos[0..1], .p_buffer_info = (&dummy_buffer_info)[0..1], .p_texel_buffer_view = (&dummy_texel_buffer_view)[0..1] },
            .{ .dst_set = desc_set, .dst_binding = 1, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .p_image_info = image_infos[1..2], .p_buffer_info = (&dummy_buffer_info)[0..1], .p_texel_buffer_view = (&dummy_texel_buffer_view)[0..1] },
            .{ .dst_set = desc_set, .dst_binding = 2, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .p_image_info = image_infos[2..3], .p_buffer_info = (&dummy_buffer_info)[0..1], .p_texel_buffer_view = (&dummy_texel_buffer_view)[0..1] },
            .{ .dst_set = desc_set, .dst_binding = 3, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .p_image_info = image_infos[3..4], .p_buffer_info = (&dummy_buffer_info)[0..1], .p_texel_buffer_view = (&dummy_texel_buffer_view)[0..1] },
        };
        self.dev.updateDescriptorSets(&writes, null);
    }
}

fn destroyOitPipelinesAndDescriptors(self: *VulkanRenderer) void {
    destroyIfValid(self.dev, &self.oit.composition_pipeline, &self.vk_ctx.vkalloc);
    destroyIfValid(self.dev, &self.oit.composition_layout, &self.vk_ctx.vkalloc);
    destroyIfValid(self.dev, &self.oit.descriptor_set_layout, &self.vk_ctx.vkalloc);
    destroyIfValid(self.dev, &self.oit.sampler, &self.vk_ctx.vkalloc);
}

fn tryShrinkMaxAllocatedIndex(self: *VulkanRenderer, freed_gpu_index: u32) void {
    const current_max = self.max_allocated_index.load(.acquire);
    if (freed_gpu_index + 1 < current_max) return;

    // The freed index was at the boundary. Scan downward through the
    // persistent candidates array to find the highest slot that still
    // has a live mesh. Indices are allocated LIFO — newly loaded chunks
    // take the highest indices, and as the player moves away those are
    // the first to be freed — so the scan is typically very short.
    var new_max: u32 = freed_gpu_index;
    while (new_max > 0) : (new_max -= 1) {
        if (self.persistent.mapped[new_max - 1].face_count != 0) break;
    }

    self.max_allocated_index.store(new_max, .release);
}

fn processRetiredMeshes(self: *VulkanRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "processRetiredMeshes" });
    defer zone.end();

    self.retire_mutex.lockUncancelable(io);
    defer self.retire_mutex.unlock(io);

    if (self.retired_meshes.items.len == 0 and self.retired_candidate_slices.items.len == 0 and self.retired_face_buffers.items.len == 0) return;

    const current_graphics_val = try self.dev.getSemaphoreCounterValue(self.transfer.graphics_timeline_semaphore);

    {
        const items = &self.retired_meshes;
        var i: usize = items.items.len;
        while (i > 0) {
            i -= 1;
            const entry = items.items[i];
            if (current_graphics_val >= entry.graphics_timeline_value) {
                if (entry.free_index) {
                    self.persistent.mapped[entry.gpu_index].face_count = 0;
                    self.index_pool.freeIndex(io, entry.gpu_index);
                    self.tryShrinkMaxAllocatedIndex(entry.gpu_index);
                }
                self.face_allocator.freeRegion(io, entry.face_offset, entry.face_length);
                _ = items.swapRemove(i);
            }
        }
    }

    {
        const items = &self.retired_candidate_slices;
        var i: usize = items.items.len;
        while (i > 0) {
            i -= 1;
            const entry = items.items[i];
            if (current_graphics_val >= entry.graphics_timeline_value) {
                self.cpu_to_gpu_gpa.allocator().free(entry.slice);
                _ = items.swapRemove(i);
            }
        }
    }

    {
        const items = &self.retired_face_buffers;
        var i: usize = items.items.len;
        while (i > 0) {
            i -= 1;
            const entry = items.items[i];
            if (current_graphics_val >= entry.graphics_timeline_value) {
                self.gpu_only_gpa.allocator().free(entry.slice);
                _ = items.swapRemove(i);
            }
        }
    }
}

pub fn beginSingleTimeCommands(self: *VulkanRenderer) !vk.CommandBuffer {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "beginSingleTimeCommands" });
    defer zone.end();
    var cmd: vk.CommandBuffer = undefined;
    try self.dev.allocateCommandBuffers(&.{ .level = .primary, .command_pool = self.upload_command_pool, .command_buffer_count = 1 }, (&cmd)[0..1]);
    errdefer self.dev.freeCommandBuffers(self.upload_command_pool, &.{cmd});

    try self.dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true }, .p_inheritance_info = null });

    return cmd;
}

fn endSingleTimeCommandsLocked(self: *VulkanRenderer, cmd: vk.CommandBuffer) !void {
    defer self.dev.freeCommandBuffers(self.upload_command_pool, &.{cmd});

    try self.dev.endCommandBuffer(cmd);

    const submit_info: vk.SubmitInfo2 = .{
        .flags = .{},
        .wait_semaphore_info_count = 0,
        .p_wait_semaphore_infos = null,
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = (&vk.CommandBufferSubmitInfo{ .command_buffer = cmd, .device_mask = 0 })[0..1],
        .signal_semaphore_info_count = 0,
        .p_signal_semaphore_infos = null,
    };

    const zone_submit = tracy.Zone.begin(.{ .src = @src(), .name = "endSingleTimeCommands_lock" });
    defer zone_submit.end();

    if (self.single_time_fence == .null_handle) {
        self.single_time_fence = try self.dev.createFence(&.{}, &self.vk_ctx.vkalloc);
    } else {
        try self.dev.resetFences((&self.single_time_fence)[0..1]);
    }

    try self.dev.queueSubmit2(self.graphics_queue, (&submit_info)[0..1], self.single_time_fence);
    _ = try self.dev.waitForFences((&self.single_time_fence)[0..1], .true, std.math.maxInt(u64));
}

pub fn endSingleTimeCommands(self: *VulkanRenderer, io: std.Io, cmd: vk.CommandBuffer) !void {
    self.vk_ctx.queue_mutex.lockUncancelable(io);
    defer self.vk_ctx.queue_mutex.unlock(io);
    try self.endSingleTimeCommandsLocked(cmd);
}

fn vtableRecreateSwapchain(user_data: *Renderer.Implementation, io: std.Io) !void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    try self.recreateSwapchainResourcesLocked(io);
}

fn vtableUpdateCameraDirection(user_data: *Renderer.Implementation, view_dir: @Vector(3, f32)) void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    const front = Renderer.cameraFrontFromViewDirection(view_dir);
    const norm = zm.Vec3f.norm(.{ .data = front }).data;
    self.camera_front_x.store(norm[0], .monotonic);
    self.camera_front_y.store(norm[1], .monotonic);
    self.camera_front_z.store(norm[2], .monotonic);
}

fn vtableForEachMesh(user_data: *Renderer.Implementation, io: std.Io, callback_user_data: *anyopaque, callback: *const fn (*anyopaque, ChunkPos) error{Failed}!void) (std.Io.Cancelable || error{Failed})!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    var it = self.meshes.iterator();
    defer it.deinit(io);
    while (try it.next(io)) |entry| {
        const chunk_pos = entry.key_ptr.*.toPos();
        it.pause(io);
        try callback(callback_user_data, chunk_pos);
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

test "MeshData size" {
    try std.testing.expectEqual(@as(usize, 16), @alignOf(MeshData));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(MeshData));
}
