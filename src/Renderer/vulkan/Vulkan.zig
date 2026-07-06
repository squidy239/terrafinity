const std = @import("std");

const tracy = @import("tracy");
const vk = @import("vulkan");
const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;
const InstanceProxy = vk.InstanceProxy;
const DeviceProxy = vk.DeviceProxy;
const wio = @import("wio");
const zm = @import("zm");
const options = @import("options");

const ConcurrentHashMap = @import("../../libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const Mesher = @import("../../Mesher.zig");
const Renderer = @import("../../Renderer.zig");
const World = @import("../../world/World.zig");
const ChunkSize = World.ChunkSize;
const ChunkPos = World.ChunkPos;
const Frustum = @import("../opengl/Frustum.zig").Frustum;
const textures = @import("textures.zig");

const vertex_shader_spv: []const u8 = @embedFile("vertexshader.spv");
const fragment_shader_spv: []const u8 = @embedFile("fragshader.spv");

pub const cameraUp = @Vector(3, f32){ 0, 1, 0 };

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
        const total_candidates = self.opaque_candidates + self.transparent_candidates;
        const total_culled = self.opaque_culled + self.transparent_culled;
        const total_drawn = self.opaque_drawn + self.transparent_drawn;

        const elapsed_f: f64 = @floatFromInt(self.elapsed_ns);
        const ms = elapsed_f / 1_000_000.0;

        const opaque_drawn_f: f64 = @floatFromInt(self.opaque_drawn);
        const opaque_candidates_f: f64 = @floatFromInt(self.opaque_candidates);
        const opaque_visible_pct = if (self.opaque_candidates > 0)
            opaque_drawn_f / opaque_candidates_f * 100.0
        else
            0.0;

        const transparent_drawn_f: f64 = @floatFromInt(self.transparent_drawn);
        const transparent_candidates_f: f64 = @floatFromInt(self.transparent_candidates);
        const transparent_visible_pct = if (self.transparent_candidates > 0)
            transparent_drawn_f / transparent_candidates_f * 100.0
        else
            0.0;

        std.log.info("=== FRAME {d} DEBUG STATS ===", .{self.frame_number});
        std.log.info("Player pos=({d:.1}, {d:.1}, {d:.1})  Camera front=({d:.3}, {d:.3}, {d:.3})", .{
            self.player_pos[0],   self.player_pos[1],   self.player_pos[2],
            self.camera_front[0], self.camera_front[1], self.camera_front[2],
        });
        std.log.info("Meshes in map: total={d}  opaque={d}  transparent={d}", .{ self.total_meshes, self.opaque_candidates, self.transparent_candidates });
        std.log.info("Opaque: candidates={d:>6}  culled={d:>6}  drawn={d:>6}  ({d:.1}% visible)", .{
            self.opaque_candidates, self.opaque_culled, self.opaque_drawn, opaque_visible_pct,
        });
        std.log.info("Transparent: candidates={d:>6}  culled={d:>6}  drawn={d:>6}  ({d:.1}% visible)", .{
            self.transparent_candidates, self.transparent_culled, self.transparent_drawn, transparent_visible_pct,
        });
        std.log.info("Total: candidates={d:>6}  culled={d:>6}  drawn={d:>6}", .{ total_candidates, total_culled, total_drawn });
        std.log.info("Time: {d:.2} ms", .{ms});
        std.log.info("========================", .{});

        if (total_drawn == 0) {
            std.log.warn("FRAME {d}: NO CHUNKS DRAWN! total_meshes={d} candidates={d} culled={d}", .{
                self.frame_number,
                self.total_meshes,
                total_candidates,
                total_culled,
            });
        }
    }
};

const RenderBufferKey = union(enum) {
    @"opaque": ChunkPos,
    transparent: ChunkPos,

    pub fn toPos(self: RenderBufferKey) ChunkPos {
        return switch (self) {
            .@"opaque" => |pos| pos,
            .transparent => |pos| pos,
        };
    }
};

const ChunkMeshBuffer = struct {
    buffer: vk.Buffer,
    alloc_offset: vk.DeviceSize,
    alloc_size: vk.DeviceSize,
    device_address: vk.DeviceAddress,
    face_count: u32,
};

const UploadRequest = struct {
    key: RenderBufferKey,
    faces: []Mesher.Face,
};

const CompletedUpload = struct {
    key: RenderBufferKey,
    device_address: vk.DeviceAddress,
    timeline_value: u64,
    buffer: vk.Buffer,
    alloc_offset: vk.DeviceSize,
    alloc_size: vk.DeviceSize,
    face_count: u32,
    pool: vk.CommandPool,
};

const PendingUpload = struct {
    key: RenderBufferKey,
    device_address: vk.DeviceAddress,
    timeline_value: u64,
    buffer: vk.Buffer,
    alloc_offset: vk.DeviceSize,
    alloc_size: vk.DeviceSize,
    face_count: u32,
    pool: vk.CommandPool,
};

const DeletionEntry = struct {
    mesh: ChunkMeshBuffer,
    graphics_timeline_value: u64,
};

const StagingRingBuffer = struct {
    buffer: vk.Buffer = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    ptr: [*]u8 = undefined,
    size: vk.DeviceSize = 128 * 1024 * 1024,
    write_offset: vk.DeviceSize = 0,
    mutex: std.Io.Mutex = .init,

    pub fn init(self: *StagingRingBuffer, dev: DeviceProxy, mem_props: vk.PhysicalDeviceMemoryProperties) !void {
        const buffer_info: vk.BufferCreateInfo = .{
            .flags = .{},
            .size = self.size,
            .usage = .{ .transfer_src_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        };
        self.buffer = try dev.createBuffer(&buffer_info, null);
        errdefer dev.destroyBuffer(self.buffer, null);

        const mem_reqs = dev.getBufferMemoryRequirements(self.buffer);
        const mem_type = findMemoryTypeRaw(mem_props, mem_reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true });

        const alloc_info: vk.MemoryAllocateInfo = .{
            .allocation_size = mem_reqs.size,
            .memory_type_index = mem_type,
            .p_next = null,
        };
        self.memory = try dev.allocateMemory(&alloc_info, null);
        errdefer dev.freeMemory(self.memory, null);

        try dev.bindBufferMemory(self.buffer, self.memory, 0);

        const data = try dev.mapMemory(self.memory, 0, self.size, .{});
        self.ptr = @ptrCast(data);
    }

    pub fn deinit(self: *StagingRingBuffer, dev: DeviceProxy) void {
        if (self.buffer != .null_handle) {
            dev.unmapMemory(self.memory);
            dev.destroyBuffer(self.buffer, null);
        }
        if (self.memory != .null_handle) {
            dev.freeMemory(self.memory, null);
        }
    }

    pub fn allocate(self: *StagingRingBuffer, io: std.Io, size: vk.DeviceSize, dev: DeviceProxy, semaphore: vk.Semaphore, current_timeline: u64) !vk.DeviceSize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const aligned_size = std.mem.alignForward(vk.DeviceSize, size, 16);
        if (self.write_offset + aligned_size > self.size) {
            if (current_timeline > 0) {
                const wait_info = vk.SemaphoreWaitInfo{
                    .flags = .{},
                    .semaphore_count = 1,
                    .p_semaphores = @ptrCast(&semaphore),
                    .p_values = @ptrCast(&current_timeline),
                };
                _ = try dev.waitSemaphores(&wait_info, std.math.maxInt(u64));
            }
            self.write_offset = 0;
        }
        const offset = self.write_offset;
        self.write_offset += aligned_size;
        return offset;
    }
};

const GlobalDeviceAllocator = struct {
    memory: vk.DeviceMemory = .null_handle,
    size: vk.DeviceSize = 256 * 1024 * 1024,
    bump_offset: vk.DeviceSize = 0,
    buckets: [32]std.ArrayList(vk.DeviceSize) = undefined,
    mutex: std.Io.Mutex = .init,
    allocator: std.mem.Allocator = undefined,

    pub fn init(self: *GlobalDeviceAllocator, dev: DeviceProxy, mem_props: vk.PhysicalDeviceMemoryProperties, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        for (&self.buckets) |*b| {
            b.* = .empty;
        }

        const temp_buffer_info: vk.BufferCreateInfo = .{
            .flags = .{},
            .size = 1024,
            .usage = .{
                .transfer_dst_bit = true,
                .storage_buffer_bit = true,
                .shader_device_address_bit = true,
            },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        };
        const temp_buffer = try dev.createBuffer(&temp_buffer_info, null);
        defer dev.destroyBuffer(temp_buffer, null);

        const mem_reqs = dev.getBufferMemoryRequirements(temp_buffer);

        var alloc_flags: vk.MemoryAllocateFlagsInfo = .{
            .flags = .{ .device_address_bit = true },
            .device_mask = 0,
        };

        const memory_type_index = findMemoryTypeRaw(mem_props, mem_reqs.memory_type_bits, .{ .device_local_bit = true });

        const alloc_info: vk.MemoryAllocateInfo = .{
            .allocation_size = self.size,
            .memory_type_index = memory_type_index,
            .p_next = @ptrCast(&alloc_flags),
        };

        self.memory = try dev.allocateMemory(&alloc_info, null);
    }

    pub fn deinit(self: *GlobalDeviceAllocator, dev: DeviceProxy) void {
        if (self.memory != .null_handle) {
            dev.freeMemory(self.memory, null);
        }
        for (&self.buckets) |*b| {
            b.deinit(self.allocator);
        }
    }

    fn bucketIndex(size: vk.DeviceSize) u5 {
        if (size <= 16) return 4;
        const bits = 64 - @clz(size - 1);
        return @intCast(bits);
    }

    pub fn allocate(self: *GlobalDeviceAllocator, io: std.Io, size: vk.DeviceSize, alignment: vk.DeviceSize) !struct { offset: vk.DeviceSize, alloc_size: vk.DeviceSize } {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const alloc_size = @as(vk.DeviceSize, 1) << bucketIndex(size);
        const idx = bucketIndex(alloc_size);

        if (self.buckets[idx].items.len > 0) {
            const offset = self.buckets[idx].pop().?;
            const aligned_offset = std.mem.alignForward(vk.DeviceSize, offset, alignment);
            return .{ .offset = aligned_offset, .alloc_size = alloc_size };
        }

        const aligned_offset = std.mem.alignForward(vk.DeviceSize, self.bump_offset, alignment);
        if (aligned_offset + alloc_size > self.size) {
            return error.OutOfVideoMemory;
        }
        self.bump_offset = aligned_offset + alloc_size;
        return .{ .offset = aligned_offset, .alloc_size = alloc_size };
    }

    pub fn free(self: *GlobalDeviceAllocator, io: std.Io, offset: vk.DeviceSize, alloc_size: vk.DeviceSize) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const idx = bucketIndex(alloc_size);
        self.buckets[idx].append(self.allocator, offset) catch {
            std.log.err("GlobalDeviceAllocator.free: Failed to return offset {d} to bucket {d}", .{ offset, idx });
        };
    }
};

const CommandPoolReservoir = struct {
    pools: []vk.CommandPool = &.{},
    cmds: []vk.CommandBuffer = &.{},
    used: []bool = &.{},
    mutex: std.Io.Mutex = .init,

    pub const Borrowed = struct {
        pool: vk.CommandPool,
        cmd: vk.CommandBuffer,
    };

    pub fn init(self: *CommandPoolReservoir, dev: DeviceProxy, queue_family: u32, count: usize, allocator: std.mem.Allocator) !void {
        self.pools = try allocator.alloc(vk.CommandPool, count);
        errdefer allocator.free(self.pools);
        self.cmds = try allocator.alloc(vk.CommandBuffer, count);
        errdefer allocator.free(self.cmds);
        self.used = try allocator.alloc(bool, count);
        errdefer allocator.free(self.used);

        @memset(self.used, false);
        var i: usize = 0;
        errdefer {
            for (0..i) |j| {
                dev.destroyCommandPool(self.pools[j], null);
            }
        }
        for (self.pools, 0..) |*pool, idx| {
            const pool_info: vk.CommandPoolCreateInfo = .{
                .flags = .{ .reset_command_buffer_bit = true },
                .queue_family_index = queue_family,
            };
            pool.* = try dev.createCommandPool(&pool_info, null);
            i += 1;

            const cmd_alloc_info: vk.CommandBufferAllocateInfo = .{
                .command_pool = pool.*,
                .level = .primary,
                .command_buffer_count = 1,
            };
            var cmd: vk.CommandBuffer = undefined;
            try dev.allocateCommandBuffers(&cmd_alloc_info, @ptrCast(&cmd));
            self.cmds[idx] = cmd;
        }
    }

    pub fn deinit(self: *CommandPoolReservoir, dev: DeviceProxy, allocator: std.mem.Allocator) void {
        for (self.pools) |pool| {
            if (pool != .null_handle) dev.destroyCommandPool(pool, null);
        }
        allocator.free(self.pools);
        allocator.free(self.cmds);
        allocator.free(self.used);
    }

    pub fn borrowPool(self: *CommandPoolReservoir, io: std.Io) ?Borrowed {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.pools, 0..) |pool, i| {
            if (!self.used[i]) {
                self.used[i] = true;
                return Borrowed{
                    .pool = pool,
                    .cmd = self.cmds[i],
                };
            }
        }
        return null;
    }

    pub fn returnPool(self: *CommandPoolReservoir, io: std.Io, pool: vk.CommandPool) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.pools, 0..) |p, i| {
            if (p == pool) {
                self.used[i] = false;
                return;
            }
        }
    }
};

const ChunkData = extern struct {
    absolute_position: [3]f32 align(4 * @sizeOf(f32)),
    relative_position: [3]f32 align(4 * @sizeOf(f32)),
    scale: f32,
    address: u64 align(@sizeOf(u64)),
};

const PushConstants = extern struct {
    projview: [16]f32,
    sun_dir: [3]f32,
    time: f32,
    draw_over: i32,
};

fn findMemoryTypeRaw(mem_props: vk.PhysicalDeviceMemoryProperties, type_filter: u32, properties: vk.MemoryPropertyFlags) u32 {
    for (mem_props.memory_types[0..mem_props.memory_type_count], 0..) |mem_type, i| {
        if ((type_filter & (@as(u32, 1) << @as(u5, @intCast(i)))) != 0 and (mem_type.property_flags.toInt() & properties.toInt()) == properties.toInt()) {
            return @intCast(i);
        }
    }
    @panic("Failed to find suitable memory type");
}

fn cullChunk(frustum: *const Frustum, chunkpos: ChunkPos, playerPos: @Vector(3, f64)) bool {
    const scale = ChunkPos.toScale(chunkpos.level);
    const chunkSizeBlocks: f64 = @floatCast(scale * @as(f32, ChunkSize));
    const chunk_pos_f: @Vector(3, f64) = @floatFromInt(chunkpos.position);
    const chunkWorldPos = chunk_pos_f * @as(@Vector(3, f64), @splat(chunkSizeBlocks));
    const relativeChunkPos: @Vector(3, f32) = @floatCast(chunkWorldPos - playerPos);
    const chunkSizeVec: @Vector(3, f32) = @splat(@floatCast(chunkSizeBlocks));
    return !frustum.boxInFrustum(.{ .max = relativeChunkPos + chunkSizeVec, .min = relativeChunkPos });
}

fn makeInfReversedZProjRh(fovY_radians: f32, aspectWbyH: f32, zNear: f32) zm.Mat4f {
    const f: f32 = 1.0 / @tan(fovY_radians / 2.0);
    return .{
        .data = .{
            .{
                f / aspectWbyH,
                0.0,
                0.0,
                0.0,
            },
            .{
                0.0,
                -f,
                0.0,
                0.0,
            },
            .{
                0.0,
                0.0,
                0.0,
                zNear,
            },
            .{
                0.0,
                0.0,
                -1.0,
                0.0,
            },
        },
    };
}

pub const VulkanRenderer = @This();

allocator: std.mem.Allocator,
window: *wio.Window,
surface: vk.SurfaceKHR = .null_handle,

vkb: BaseWrapper,
instance_handle: vk.Instance,
instance_wrapper: ?*InstanceWrapper,
instance: InstanceProxy,

pdev: vk.PhysicalDevice,
props: vk.PhysicalDeviceProperties,
mem_props: vk.PhysicalDeviceMemoryProperties,

dev_handle: vk.Device,
dev_wrapper: ?*DeviceWrapper,
dev: DeviceProxy,

graphics_queue: vk.Queue,
present_queue: vk.Queue,
queue_family_index: u32,
present_queue_family_index: u32,

command_pool: vk.CommandPool,
upload_command_pool: vk.CommandPool = .null_handle,
cmd_buffers: []vk.CommandBuffer = &.{},

swapchain: vk.SwapchainKHR = .null_handle,
swapchain_format: vk.Format = .b8g8r8a8_srgb,
swapchain_images: []vk.Image = &.{},
swapchain_views: []vk.ImageView = &.{},
swapchain_extent: vk.Extent2D = .{ .width = 800, .height = 600 },
swapchain_needs_recreate: bool = false,

render_color_image: vk.Image = .null_handle,
render_color_memory: vk.DeviceMemory = .null_handle,
render_color_view: vk.ImageView = .null_handle,
render_depth_image: vk.Image = .null_handle,
render_depth_memory: vk.DeviceMemory = .null_handle,
render_depth_view: vk.ImageView = .null_handle,
depth_format: vk.Format = .undefined,

texture_manager: textures.TextureArrayManager = undefined,

dummy_image: vk.Image = .null_handle,
dummy_memory: vk.DeviceMemory = .null_handle,
dummy_view: vk.ImageView = .null_handle,
dummy_sampler: vk.Sampler = .null_handle,

image_acquired_semaphores: []vk.Semaphore = &.{},
render_complete_semaphores: []vk.Semaphore = &.{},
in_flight_fences: []vk.Fence = &.{},
current_frame_idx: std.atomic.Value(u32) = .init(0),
current_swapchain_image_index: u32 = 0,

descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
pipeline_layout: vk.PipelineLayout = .null_handle,
pipeline: vk.Pipeline = .null_handle,
transparent_pipeline: vk.Pipeline = .null_handle,
descriptor_pool: vk.DescriptorPool = .null_handle,
descriptor_sets_per_frame: []vk.DescriptorSet = &.{},

io: std.Io = undefined,
transfer_queue: vk.Queue = undefined,
transfer_queue_family_index: u32 = undefined,

transfer_semaphore: vk.Semaphore = .null_handle,
transfer_semaphore_value: std.atomic.Value(u64) = .init(0),
graphics_timeline_semaphore: vk.Semaphore = .null_handle,

meshes: ConcurrentHashMap(RenderBufferKey, ChunkMeshBuffer, std.hash_map.AutoContext(RenderBufferKey), 80, 32),

indirect_draw_buffers: []vk.Buffer = &.{},
indirect_draw_memories: []vk.DeviceMemory = &.{},
indirect_draw_buffers_mapped: [][*]u8 = &.{},

chunk_data_buffers: []vk.Buffer = &.{},
chunk_data_memories: []vk.DeviceMemory = &.{},
chunk_data_buffers_mapped: [][*]u8 = &.{},

max_draw_count: u32 = 100_000,

deferred_deletions: std.ArrayList(DeletionEntry) = undefined,

staging_ring_buffer: StagingRingBuffer = .{},
device_allocator: GlobalDeviceAllocator = .{},
pool_reservoir: CommandPoolReservoir = .{},

upload_queue: std.Io.Queue(UploadRequest) = undefined,
upload_queue_buf: [1024]UploadRequest = undefined,
upload_queue_count: std.atomic.Value(u32) = .init(0),

pending_uploads: std.ArrayList(PendingUpload) = undefined,

camera_front: @Vector(3, f32) = .{ 0, 0, 1 },
viewport_pixels: @Vector(2, u32) = .{ 800, 600 },

render_options: *const RenderOptions,
render_options_lock: *std.Io.RwLock,

interface: Renderer,

queue_mutex: std.Io.Mutex = .init,
upload_mutex: std.Io.Mutex = .init,
pending_uploads_mutex: std.Io.Mutex = .init,

deferred_deletions_mutex: std.Io.Mutex = .init,

init_time_ns: u64 = 0,
frame_number: std.atomic.Value(u64) = .init(0),
frame_stats: FrameDebugStats = .{},

pub const RenderOptions = struct {
    draw_over: bool = false,
    fov: f32 = 90.0,
    day_length_sec: f32 = 60 * 5,
    gamma_correction: bool = true,
};

fn getDeletionQueueIndex(self: *VulkanRenderer) u32 {
    const unbound = self.current_frame_idx.load(.monotonic);
    return @intCast(unbound % self.in_flight_fences.len);
}

fn getProcAddr(instance: vk.Instance, procname: [*:0]const u8) ?*const fn () void {
    return @ptrCast(wio.vkGetInstanceProcAddr(
        (@intFromEnum(instance)),
        procname,
    ));
}

fn getDeviceProcAddrLoader(device: vk.Device, procname: [*:0]const u8, instance_handle: vk.Instance) ?*const fn () void {
    const gdpa_ptr = @as(?*const fn () void, @ptrCast(wio.vkGetInstanceProcAddr(@intFromEnum(instance_handle), "vkGetDeviceProcAddr")));
    if (gdpa_ptr) |gdpa| {
        const gdpa_fn = @as(*const fn (vk.Device, [*:0]const u8) callconv(.C) ?*const fn () void, @ptrCast(gdpa));
        return gdpa_fn(device, procname);
    }
    return null;
}

pub fn init(io: std.Io, allocator: std.mem.Allocator, window: *wio.Window, render_options: *const RenderOptions, render_options_lock: *std.Io.RwLock) !*VulkanRenderer {
    std.log.info("VulkanRenderer.init: Starting Vulkan initialization...", .{});

    const self = try allocator.create(VulkanRenderer);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = undefined,
        .window = undefined,
        .vkb = undefined,
        .instance_handle = undefined,
        .instance_wrapper = undefined,
        .instance = undefined,
        .pdev = undefined,
        .props = undefined,
        .mem_props = undefined,
        .dev_handle = undefined,
        .dev_wrapper = undefined,
        .dev = undefined,
        .graphics_queue = undefined,
        .present_queue = undefined,
        .queue_family_index = undefined,
        .present_queue_family_index = undefined,
        .command_pool = undefined,
        .meshes = undefined,
        .interface = undefined,
        .render_options = render_options,
        .render_options_lock = render_options_lock,
    };

    std.log.info("VulkanRenderer.init: Allocated VulkanRenderer struct", .{});

    self.allocator = allocator;
    self.window = window;
    self.io = io;
    self.init_time_ns = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);

    self.deferred_deletions = .empty;
    self.pending_uploads = .empty;
    self.upload_queue = .init(&self.upload_queue_buf);

    self.vkb = .load(getProcAddr);

    const app_info: vk.ApplicationInfo = .{
        .p_application_name = "Terrafinity",
        .application_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
        .p_engine_name = "No Engine",
        .engine_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
        .api_version = vk.API_VERSION_1_3.toU32(),
    };

    var enabled_layers: std.ArrayList([*:0]const u8) = .empty;
    defer enabled_layers.deinit(allocator);

    const layers = try self.vkb.enumerateInstanceLayerPropertiesAlloc(allocator);
    defer allocator.free(layers);

    var has_validation_layer: bool = false;
    for (layers) |layer| {
        const name = std.mem.sliceTo(&layer.layer_name, 0);
        if (std.mem.eql(u8, name, "VK_LAYER_KHRONOS_validation")) {
            try enabled_layers.append(allocator, "VK_LAYER_KHRONOS_validation");
            has_validation_layer = true;
        }
    }

    var extension_names: std.ArrayList([*:0]const u8) = .empty;
    defer extension_names.deinit(allocator);

    const wio_extensions = wio.getRequiredVulkanInstanceExtensions();
    for (wio_extensions) |ext| {
        try extension_names.append(allocator, ext);
    }

    var has_portability = false;
    const extensions = try self.vkb.enumerateInstanceExtensionPropertiesAlloc(null, allocator);
    defer allocator.free(extensions);
    for (extensions) |extension| {
        const name = std.mem.sliceTo(&extension.extension_name, 0);
        if (std.mem.eql(u8, name, "VK_KHR_portability_enumeration")) {
            try extension_names.append(allocator, "VK_KHR_portability_enumeration");
            has_portability = true;
        }
    }

    const instance_create_info: vk.InstanceCreateInfo = .{
        .s_type = .instance_create_info,
        .flags = .{ .enumerate_portability_bit_khr = has_portability },
        .p_application_info = &app_info,
        .enabled_layer_count = @intCast(enabled_layers.items.len),
        .pp_enabled_layer_names = if (enabled_layers.items.len > 0) @ptrCast(enabled_layers.items.ptr) else null,
        .enabled_extension_count = @intCast(extension_names.items.len),
        .pp_enabled_extension_names = if (extension_names.items.len > 0) @ptrCast(extension_names.items.ptr) else null,
    };

    self.instance_handle = try self.vkb.createInstance(&instance_create_info, null);
    errdefer {
        var local_wrapper = InstanceWrapper.load(self.instance_handle, getProcAddr);
        const local_instance = InstanceProxy.init(self.instance_handle, &local_wrapper);
        local_instance.destroyInstance(null);
    }
    std.log.info("VulkanRenderer.init: Created Vulkan instance successfully", .{});

    const instance_wrapper_ptr = try allocator.create(InstanceWrapper);
    errdefer allocator.destroy(instance_wrapper_ptr);

    instance_wrapper_ptr.* = .load(self.instance_handle, getProcAddr);
    self.instance_wrapper = instance_wrapper_ptr;
    self.instance = .init(self.instance_handle, instance_wrapper_ptr);
    errdefer {
        self.instance.destroyInstance(null);
        allocator.destroy(instance_wrapper_ptr);
        self.instance_wrapper = null;
    }

    var surface: vk.SurfaceKHR = .null_handle;
    const result: vk.Result = @enumFromInt(window.vkCreateSurface(@intFromEnum(self.instance.handle), null, @ptrCast(&surface)));
    if (result != .success) {
        std.log.err("VulkanRenderer.init: Failed to create Vulkan surface with result: {any}", .{result});
        return error.SurfaceCreationFailed;
    }
    self.surface = surface;
    errdefer self.instance.destroySurfaceKHR(self.surface, null);
    std.log.info("VulkanRenderer.init: Created Vulkan surface successfully", .{});

    var pdev_count: u32 = 0;
    _ = try self.instance.enumeratePhysicalDevices(&pdev_count, null);

    const pdevs = try allocator.alloc(vk.PhysicalDevice, pdev_count);
    defer allocator.free(pdevs);

    _ = try self.instance.enumeratePhysicalDevices(&pdev_count, pdevs.ptr);

    var selected_pdev: vk.PhysicalDevice = .null_handle;
    var best_device_score: u32 = 0;
    for (pdevs) |pdev| {
        var dynamic_rendering_features: vk.PhysicalDeviceDynamicRenderingFeatures = .{
            .dynamic_rendering = .false,
            .p_next = null,
        };
        var sync2_features: vk.PhysicalDeviceSynchronization2Features = .{
            .synchronization_2 = .false,
            .p_next = @ptrCast(&dynamic_rendering_features),
        };
        var features12: vk.PhysicalDeviceVulkan12Features = .{
            .draw_indirect_count = .false,
            .descriptor_indexing = .false,
            .runtime_descriptor_array = .false,
            .descriptor_binding_partially_bound = .false,
            .buffer_device_address = .false,
            .timeline_semaphore = .false,
            .p_next = @ptrCast(&sync2_features),
        };
        var features2: vk.PhysicalDeviceFeatures2 = .{
            .features = .{ .multi_draw_indirect = .false },
            .p_next = @ptrCast(&features12),
        };

        self.instance.getPhysicalDeviceFeatures2(pdev, &features2);

        if (features2.features.multi_draw_indirect == .true and
            features12.draw_indirect_count == .true and
            features12.descriptor_indexing == .true and
            features12.runtime_descriptor_array == .true and
            features12.descriptor_binding_partially_bound == .true and
            features12.buffer_device_address == .true and
            features12.timeline_semaphore == .true and
            sync2_features.synchronization_2 == .true and
            dynamic_rendering_features.dynamic_rendering == .true)
        {
            var has_graphics = false;
            var has_present = false;
            const queue_families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
            defer allocator.free(queue_families);

            for (queue_families, 0..) |qf, i| {
                const family: u32 = @intCast(i);
                if (!has_graphics and qf.queue_flags.graphics_bit) {
                    has_graphics = true;
                }
                if (!has_present) {
                    const supported = try self.instance.getPhysicalDeviceSurfaceSupportKHR(pdev, family, self.surface);
                    if (supported == .true) {
                        has_present = true;
                    }
                }
            }

            if (has_graphics and has_present) {
                const surface_formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(pdev, self.surface, allocator);
                defer allocator.free(surface_formats);

                const present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(pdev, self.surface, allocator);
                defer allocator.free(present_modes);

                if (surface_formats.len > 0 and present_modes.len > 0) {
                    const props = self.instance.getPhysicalDeviceProperties(pdev);
                    var score: u32 = if (props.device_type == .discrete_gpu) 10 else if (props.device_type == .integrated_gpu) 5 else 1;

                    // ThreadSanitizer has known internal runtime crashes/assertion failures
                    // (tsan_interceptors_posix.cpp:2156 "((thr->slot)) != (0)") when using
                    // NVIDIA proprietary driver-level threads. If TSan is enabled, we avoid
                    // selecting NVIDIA GPUs to allow thread sanitization verification to succeed.
                    if (options.sanitize_thread) {
                        const device_name = std.mem.sliceTo(&props.device_name, 0);
                        if (std.mem.indexOf(u8, device_name, "NVIDIA") != null or std.mem.indexOf(u8, device_name, "nvidia") != null) {
                            score = 1;
                        }
                    }

                    if (score > best_device_score) {
                        best_device_score = score;
                        selected_pdev = pdev;
                    }
                }
            }
        }
    }

    if (selected_pdev == .null_handle) {
        std.log.err("VulkanRenderer.init: Step 10 - No suitable physical device found", .{});
        return error.NoSuitablePhysicalDevice;
    }

    self.pdev = selected_pdev;

    const props = self.instance.getPhysicalDeviceProperties(self.pdev);
    self.props = props;

    self.max_draw_count = if (props.limits.max_draw_indirect_count > 0) @min(100_000, props.limits.max_draw_indirect_count) else 65_535;

    const device_name = std.mem.sliceTo(&props.device_name, 0);
    std.log.info("VulkanRenderer.init: Selected physical device: {s}", .{device_name});

    const queue_priorities = [_]f32{1.0};

    var graphics_family: u32 = 0;
    var present_family: u32 = 0;

    const queue_families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(self.pdev, allocator);
    defer allocator.free(queue_families);

    for (queue_families, 0..) |qf, i| {
        const family: u32 = @intCast(i);
        if (graphics_family == 0 and qf.queue_flags.graphics_bit) {
            graphics_family = family;
        }
        if (present_family == 0 and (try self.instance.getPhysicalDeviceSurfaceSupportKHR(self.pdev, family, self.surface)) == .true) {
            present_family = family;
        }
    }

    var transfer_family: ?u32 = null;
    var transfer_score: u8 = 0;
    for (queue_families, 0..) |qf, i| {
        const family: u32 = @intCast(i);
        if (qf.queue_flags.transfer_bit) {
            const score: u8 = if (!qf.queue_flags.graphics_bit and !qf.queue_flags.compute_bit) 3 else if (!qf.queue_flags.graphics_bit) 2 else 1;
            if (score > transfer_score) {
                transfer_family = family;
                transfer_score = score;
            }
        }
    }
    const final_transfer_family = transfer_family orelse graphics_family;

    self.queue_family_index = graphics_family;
    self.present_queue_family_index = present_family;
    self.transfer_queue_family_index = final_transfer_family;

    const device_extensions = [_][*:0]const u8{
        vk.extensions.khr_swapchain.name,
        vk.extensions.khr_dynamic_rendering.name,
    };

    var unique_families: [3]u32 = undefined;
    var unique_count: u32 = 0;
    for ([_]u32{ graphics_family, present_family, final_transfer_family }) |f| {
        var found = false;
        for (unique_families[0..unique_count]) |uf| {
            if (uf == f) {
                found = true;
                break;
            }
        }
        if (!found) {
            unique_families[unique_count] = f;
            unique_count += 1;
        }
    }

    var queue_create_infos_ptr: [3]vk.DeviceQueueCreateInfo = undefined;
    for (unique_families[0..unique_count], 0..) |f, i| {
        queue_create_infos_ptr[i] = .{
            .flags = .{},
            .queue_family_index = f,
            .queue_count = 1,
            .p_queue_priorities = &queue_priorities,
        };
    }

    const queue_create_info_count = unique_count;

    var dynamic_rendering_features: vk.PhysicalDeviceDynamicRenderingFeatures = .{
        .dynamic_rendering = .true,
    };
    var sync2_features: vk.PhysicalDeviceSynchronization2Features = .{
        .synchronization_2 = .true,
        .p_next = @ptrCast(&dynamic_rendering_features),
    };
    var features12: vk.PhysicalDeviceVulkan12Features = .{
        .draw_indirect_count = .true,
        .descriptor_indexing = .true,
        .runtime_descriptor_array = .true,
        .descriptor_binding_partially_bound = .true,
        .buffer_device_address = .true,
        .timeline_semaphore = .true,
        .p_next = @ptrCast(&sync2_features),
    };

    var features11: vk.PhysicalDeviceVulkan11Features = .{
        .shader_draw_parameters = .true,
        .p_next = @ptrCast(&features12),
    };

    var features: vk.PhysicalDeviceFeatures2 = .{
        .features = .{
            .multi_draw_indirect = .true,
            .shader_int_64 = .true,
        },
        .p_next = @ptrCast(&features11),
    };

    const device_info: vk.DeviceCreateInfo = .{
        .s_type = .device_create_info,
        .flags = .{},
        .queue_create_info_count = @intCast(queue_create_info_count),
        .p_queue_create_infos = @ptrCast(&queue_create_infos_ptr[0]),
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = null,
        .enabled_extension_count = device_extensions.len,
        .pp_enabled_extension_names = @ptrCast(&device_extensions[0]),
        .p_enabled_features = null,
        .p_next = @ptrCast(&features),
    };

    self.dev_handle = try self.instance.createDevice(self.pdev, &device_info, null);
    std.log.info("VulkanRenderer.init: Created logical device successfully", .{});

    const dev_wrapper_ptr = try allocator.create(DeviceWrapper);
    errdefer allocator.destroy(dev_wrapper_ptr);

    const gdpa = self.instance.wrapper.dispatch.vkGetDeviceProcAddr orelse return error.MissingDeviceProcAddr;
    dev_wrapper_ptr.* = .load(self.dev_handle, gdpa);
    self.dev_wrapper = dev_wrapper_ptr;
    self.dev = .init(self.dev_handle, dev_wrapper_ptr);
    errdefer {
        if (self.command_pool != .null_handle) {
            self.dev.destroyCommandPool(self.command_pool, null);
        }
        if (self.upload_command_pool != .null_handle) {
            self.dev.destroyCommandPool(self.upload_command_pool, null);
        }
        if (self.swapchain != .null_handle) {
            for (self.swapchain_views) |view| {
                if (view != .null_handle) self.dev.destroyImageView(view, null);
            }
            for (self.image_acquired_semaphores) |sem| {
                if (sem != .null_handle) self.dev.destroySemaphore(sem, null);
            }
            for (self.render_complete_semaphores) |sem| {
                if (sem != .null_handle) self.dev.destroySemaphore(sem, null);
            }
            for (self.in_flight_fences) |fence| {
                if (fence != .null_handle) self.dev.destroyFence(fence, null);
            }
            self.dev.destroySwapchainKHR(self.swapchain, null);
        }
        if (self.render_color_view != .null_handle) {
            self.dev.destroyImageView(self.render_color_view, null);
        }
        if (self.render_depth_view != .null_handle) {
            self.dev.destroyImageView(self.render_depth_view, null);
        }
        if (self.render_color_image != .null_handle) {
            self.dev.destroyImage(self.render_color_image, null);
        }
        if (self.render_color_memory != .null_handle) {
            self.dev.freeMemory(self.render_color_memory, null);
        }
        if (self.render_depth_image != .null_handle) {
            self.dev.destroyImage(self.render_depth_image, null);
        }
        if (self.render_depth_memory != .null_handle) {
            self.dev.freeMemory(self.render_depth_memory, null);
        }
        if (self.pipeline != .null_handle) {
            self.dev.destroyPipeline(self.pipeline, null);
        }
        if (self.transparent_pipeline != .null_handle) {
            self.dev.destroyPipeline(self.transparent_pipeline, null);
        }
        if (self.pipeline_layout != .null_handle) {
            self.dev.destroyPipelineLayout(self.pipeline_layout, null);
        }
        if (self.descriptor_set_layout != .null_handle) {
            self.dev.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
        }
        if (self.descriptor_pool != .null_handle) {
            self.dev.destroyDescriptorPool(self.descriptor_pool, null);
        }
        if (self.indirect_draw_buffers.len > 0) {
            for (self.indirect_draw_buffers) |buf| {
                if (buf != .null_handle) self.dev.destroyBuffer(buf, null);
            }
        }
        if (self.indirect_draw_memories.len > 0) {
            for (self.indirect_draw_memories) |mem| {
                if (mem != .null_handle) self.dev.freeMemory(mem, null);
            }
        }
        if (self.chunk_data_buffers.len > 0) {
            for (self.chunk_data_buffers) |buf| {
                if (buf != .null_handle) self.dev.destroyBuffer(buf, null);
            }
        }
        if (self.chunk_data_memories.len > 0) {
            for (self.chunk_data_memories) |mem| {
                if (mem != .null_handle) self.dev.freeMemory(mem, null);
            }
        }
        self.dev.destroyDevice(null);
        allocator.destroy(dev_wrapper_ptr);
        self.dev_wrapper = null;
    }

    self.graphics_queue = self.dev.getDeviceQueue(graphics_family, 0);
    self.present_queue = if (graphics_family == present_family) self.graphics_queue else self.dev.getDeviceQueue(present_family, 0);

    self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);

    const pool_info: vk.CommandPoolCreateInfo = .{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = graphics_family,
    };
    self.command_pool = try self.dev.createCommandPool(&pool_info, null);

    const upload_pool_info: vk.CommandPoolCreateInfo = .{
        .flags = .{ .reset_command_buffer_bit = true, .transient_bit = true },
        .queue_family_index = graphics_family,
    };
    self.upload_command_pool = try self.dev.createCommandPool(&upload_pool_info, null);

    try self.createSwapchain(io);

    try self.createDescriptorSetLayout();
    try self.createDescriptorPoolAndSets(io, false);

    {
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
    // Destroy dummy placeholder textures now that real textures are loaded
    self.destroyDummyResources();

    try self.createPipeline();
    try self.createTransparentPipeline();

    // Indirect buffers are already allocated by createSwapchain above (line 685).
    // Do NOT call allocateIndirectBuffers again here — that would leak the first
    // batch of Vulkan buffers/memory and their Zig slice allocations.

    self.queue_family_index = graphics_family;
    self.present_queue_family_index = present_family;
    self.meshes = .init;

    // Initialize transfer queue
    self.transfer_queue = self.dev.getDeviceQueue(self.transfer_queue_family_index, 0);

    // Initialize timeline semaphores
    var sem_type_create_info: vk.SemaphoreTypeCreateInfo = .{
        .semaphore_type = .timeline,
        .initial_value = 0,
    };
    const sem_create_info: vk.SemaphoreCreateInfo = .{
        .p_next = @ptrCast(&sem_type_create_info),
        .flags = .{},
    };
    self.transfer_semaphore = try self.dev.createSemaphore(&sem_create_info, null);
    errdefer self.dev.destroySemaphore(self.transfer_semaphore, null);

    self.graphics_timeline_semaphore = try self.dev.createSemaphore(&sem_create_info, null);
    errdefer self.dev.destroySemaphore(self.graphics_timeline_semaphore, null);

    self.transfer_semaphore_value = .init(0);

    // Initialize staging ring buffer
    try self.staging_ring_buffer.init(self.dev, self.mem_props);
    errdefer self.staging_ring_buffer.deinit(self.dev);

    // Initialize global device allocator
    try self.device_allocator.init(self.dev, self.mem_props, allocator);
    errdefer self.device_allocator.deinit(self.dev);

    // Initialize command pool reservoir
    try self.pool_reservoir.init(self.dev, self.transfer_queue_family_index, 8, allocator);
    errdefer self.pool_reservoir.deinit(self.dev, allocator);

    self.interface = .{
        .userdata = @ptrCast(self),
        .vtable = &.{
            .addChunk = vtableAddChunk,
            .removeChunk = vtableRemoveChunk,
            .draw = vtableDrawChunks,
            .setViewport = vtableSetViewport,
            .updateCameraDirection = vtableUpdateCameraDirection,
            .getCameraFront = vtableGetCameraFront,
            .forEachChunk = vtableForEachChunk,
        },
    };

    return self;
}

pub fn getSurface(self: *VulkanRenderer) vk.SurfaceKHR {
    return self.surface;
}

pub fn deinit(self: *VulkanRenderer, io: std.Io) void {
    self.upload_queue.close(io);

    var req_buf: [1]UploadRequest = undefined;
    while (true) {
        const got = self.upload_queue.get(io, &req_buf, 1) catch 0;
        if (got == 0) break;
        self.allocator.free(req_buf[0].faces);
    }

    std.log.info("VulkanRenderer.deinit: Waiting for device idle...", .{});
    {
        self.queue_mutex.lockUncancelable(io);
        defer self.queue_mutex.unlock(io);
        self.dev.deviceWaitIdle() catch |err| {
            std.log.err("VulkanRenderer.deinit: deviceWaitIdle failed: {any}", .{err});
        };
    }
    std.log.info("VulkanRenderer.deinit: device is idle. Cleaning up Vulkan objects...", .{});

    for (self.pending_uploads.items) |pending| {
        if (pending.buffer != .null_handle) self.dev.destroyBuffer(pending.buffer, null);
        self.device_allocator.free(io, pending.alloc_offset, pending.alloc_size);
    }
    self.pending_uploads.deinit(self.allocator);

    for (self.deferred_deletions.items) |entry| {
        if (entry.mesh.buffer != .null_handle) self.dev.destroyBuffer(entry.mesh.buffer, null);
        self.device_allocator.free(io, entry.mesh.alloc_offset, entry.mesh.alloc_size);
    }
    self.deferred_deletions.deinit(self.allocator);

    var it = self.meshes.iterator();
    defer it.deinit(io);
    while (it.next(io) catch null) |entry| {
        self.destroyChunkMesh(io, entry.value_ptr.*);
    }
    self.meshes.deinit(io, self.allocator);

    // Now call destroyOldSwapchainResources to clean up all swapchain and frame-dependent resources
    self.destroyOldSwapchainResources(io);

    if (self.pipeline != .null_handle) {
        self.dev.destroyPipeline(self.pipeline, null);
        self.pipeline = .null_handle;
    }
    if (self.transparent_pipeline != .null_handle) {
        self.dev.destroyPipeline(self.transparent_pipeline, null);
        self.transparent_pipeline = .null_handle;
    }
    if (self.pipeline_layout != .null_handle) {
        self.dev.destroyPipelineLayout(self.pipeline_layout, null);
        self.pipeline_layout = .null_handle;
    }
    if (self.descriptor_set_layout != .null_handle) {
        self.dev.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
        self.descriptor_set_layout = .null_handle;
    }

    if (self.swapchain != .null_handle) {
        self.dev.destroySwapchainKHR(self.swapchain, null);
    }

    // Destroy pools and allocators
    self.pool_reservoir.deinit(self.dev, self.allocator);
    self.device_allocator.deinit(self.dev);
    self.staging_ring_buffer.deinit(self.dev);

    if (self.transfer_semaphore != .null_handle) {
        self.dev.destroySemaphore(self.transfer_semaphore, null);
    }
    if (self.graphics_timeline_semaphore != .null_handle) {
        self.dev.destroySemaphore(self.graphics_timeline_semaphore, null);
    }

    self.destroyDummyResources();

    self.texture_manager.destroyTextureArray();

    if (self.command_pool != .null_handle) {
        self.dev.destroyCommandPool(self.command_pool, null);
        self.command_pool = .null_handle;
    }
    if (self.upload_command_pool != .null_handle) {
        self.dev.destroyCommandPool(self.upload_command_pool, null);
        self.upload_command_pool = .null_handle;
    }

    if (self.surface != .null_handle) {
        self.instance.destroySurfaceKHR(self.surface, null);
        self.surface = .null_handle;
    }

    self.dev.destroyDevice(null);

    if (self.instance_wrapper) |wrapper| {
        self.instance.destroyInstance(null);
        self.allocator.destroy(wrapper);
        self.instance_wrapper = null;
    }
    if (self.dev_wrapper) |wrapper| {
        self.allocator.destroy(wrapper);
        self.dev_wrapper = null;
    }

    self.allocator.destroy(self);
}

pub fn addChunk(self: *VulkanRenderer, io: std.Io, chunk_pos: ChunkPos, opaque_mesh: []const Mesher.Face, transparent_mesh: []const Mesher.Face) !void {
    if (opaque_mesh.len > 0) {
        const faces = try self.allocator.dupe(Mesher.Face, opaque_mesh);
        errdefer self.allocator.free(faces);
        // Index block_type via EnumIndexer (same as OpenGL) so texture array layer
        // indices match the Block declaration order
        const indexer = std.enums.EnumIndexer(World.Block);
        for (faces) |*face| {
            face.block_type = @intCast(indexer.indexOf(@enumFromInt(face.block_type)));
        }
        try self.upload_queue.putOne(io, .{ .key = .{ .@"opaque" = chunk_pos }, .faces = faces });
        _ = self.upload_queue_count.fetchAdd(1, .monotonic);
    } else {
        self.remove(io, .{ .@"opaque" = chunk_pos });
    }

    if (transparent_mesh.len > 0) {
        const faces = try self.allocator.dupe(Mesher.Face, transparent_mesh);
        errdefer self.allocator.free(faces);
        const indexer = std.enums.EnumIndexer(World.Block);
        for (faces) |*face| {
            face.block_type = @intCast(indexer.indexOf(@enumFromInt(face.block_type)));
        }
        try self.upload_queue.putOne(io, .{ .key = .{ .transparent = chunk_pos }, .faces = faces });
        _ = self.upload_queue_count.fetchAdd(1, .monotonic);
    } else {
        self.remove(io, .{ .transparent = chunk_pos });
    }

    try self.processPendingUploads(io);
}

fn vtableAddChunk(userdata: *anyopaque, io: std.Io, chunk_pos: ChunkPos, opaque_mesh: []Mesher.Face, transparent_mesh: []Mesher.Face) (std.Io.Cancelable || error{ OutOfMemory, OutOfVideoMemory, Unexpected })!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));
    self.addChunk(io, chunk_pos, opaque_mesh, transparent_mesh) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
}

pub fn remove(self: *VulkanRenderer, io: std.Io, key: RenderBufferKey) void {
    if (self.meshes.fetchRemove(io, key)) |mesh| self.enqueueDeferredDeletion(io, mesh);
}

fn vtableRemoveChunk(userdata: *anyopaque, io: std.Io, chunk_pos: ChunkPos) void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));

    if (self.meshes.fetchRemove(io, .{ .@"opaque" = chunk_pos })) |mesh| self.enqueueDeferredDeletion(io, mesh);
    if (self.meshes.fetchRemove(io, .{ .transparent = chunk_pos })) |mesh| self.enqueueDeferredDeletion(io, mesh);
}

fn destroyChunkMesh(self: *VulkanRenderer, io: std.Io, mesh: ChunkMeshBuffer) void {
    if (mesh.buffer != .null_handle) self.dev.destroyBuffer(mesh.buffer, null);
    self.device_allocator.free(io, mesh.alloc_offset, mesh.alloc_size);
}
fn retireCompletedUploads(self: *VulkanRenderer, io: std.Io) !void {
    self.pending_uploads_mutex.lockUncancelable(io);
    defer self.pending_uploads_mutex.unlock(io);

    if (self.pending_uploads.items.len == 0) return;

    const current_transfer_val = try self.dev.getSemaphoreCounterValue(self.transfer_semaphore);

    var i: usize = 0;
    while (i < self.pending_uploads.items.len) {
        const pending = self.pending_uploads.items[i];
        if (current_transfer_val >= pending.timeline_value) {
            const mesh_buffer: ChunkMeshBuffer = .{
                .buffer = pending.buffer,
                .alloc_offset = pending.alloc_offset,
                .alloc_size = pending.alloc_size,
                .device_address = pending.device_address,
                .face_count = pending.face_count,
            };

            const existing = try self.meshes.fetchPut(io, self.allocator, pending.key, mesh_buffer);
            if (existing) |e| {
                self.enqueueDeferredDeletion(io, e);
            }

            self.pool_reservoir.returnPool(io, pending.pool);

            _ = self.pending_uploads.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

fn uploadOnePending(self: *VulkanRenderer, io: std.Io, req: UploadRequest) !void {
    defer self.allocator.free(req.faces);

    const buffer_size: vk.DeviceSize = @intCast(req.faces.len * @sizeOf(Mesher.Face));
    const current_val = self.transfer_semaphore_value.load(.monotonic);
    const staging_offset = try self.staging_ring_buffer.allocate(io, buffer_size, self.dev, self.transfer_semaphore, current_val);

    const mapped_dest = self.staging_ring_buffer.ptr + staging_offset;
    const src_bytes = std.mem.sliceAsBytes(req.faces);
    @memcpy(mapped_dest[0..buffer_size], src_bytes);

    const usage: vk.BufferUsageFlags = .{
        .transfer_dst_bit = true,
        .storage_buffer_bit = true,
        .shader_device_address_bit = true,
    };

    var queue_families: [2]u32 = undefined;
    var sharing_mode: vk.SharingMode = .exclusive;
    var queue_family_count: u32 = 0;
    if (self.queue_family_index != self.transfer_queue_family_index) {
        sharing_mode = .concurrent;
        queue_families[0] = self.queue_family_index;
        queue_families[1] = self.transfer_queue_family_index;
        queue_family_count = 2;
    }

    const buffer_info: vk.BufferCreateInfo = .{
        .flags = .{},
        .size = buffer_size,
        .usage = usage,
        .sharing_mode = sharing_mode,
        .queue_family_index_count = queue_family_count,
        .p_queue_family_indices = &queue_families,
    };

    const buffer = try self.dev.createBuffer(&buffer_info, null);
    errdefer self.dev.destroyBuffer(buffer, null);

    const mem_reqs = self.dev.getBufferMemoryRequirements(buffer);
    const alloc_res = try self.device_allocator.allocate(io, mem_reqs.size, mem_reqs.alignment);
    errdefer self.device_allocator.free(io, alloc_res.offset, alloc_res.alloc_size);

    try self.dev.bindBufferMemory(buffer, self.device_allocator.memory, alloc_res.offset);

    const address_info: vk.BufferDeviceAddressInfo = .{
        .buffer = buffer,
    };
    const device_address = self.dev.getBufferDeviceAddress(&address_info);

    const borrowed = blk: {
        var first = true;
        while (true) {
            if (self.pool_reservoir.borrowPool(io)) |p| break :blk p;
            try self.retireCompletedUploads(io);
            if (self.pool_reservoir.borrowPool(io)) |p| break :blk p;
            if (first) {
                first = false;
            } else {
                try io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
            }
        }
    };
    const pool = borrowed.pool;
    const cmd = borrowed.cmd;
    errdefer self.pool_reservoir.returnPool(io, pool);

    try self.dev.resetCommandPool(pool, .{});

    const begin_info: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };
    try self.dev.beginCommandBuffer(cmd, &begin_info);

    const copy_region: vk.BufferCopy2 = .{
        .src_offset = staging_offset,
        .dst_offset = 0,
        .size = buffer_size,
    };
    const copy_buffer_info: vk.CopyBufferInfo2 = .{
        .src_buffer = self.staging_ring_buffer.buffer,
        .dst_buffer = buffer,
        .region_count = 1,
        .p_regions = @ptrCast(&copy_region),
    };
    self.dev.cmdCopyBuffer2(cmd, &copy_buffer_info);

    const buffer_barrier: vk.BufferMemoryBarrier2 = .{
        .src_stage_mask = .{ .all_transfer_bit = true },
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_stage_mask = .{ .all_transfer_bit = true },
        .dst_access_mask = .{ .transfer_write_bit = true },
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .buffer = buffer,
        .offset = 0,
        .size = buffer_size,
    };
    const dependency_info: vk.DependencyInfo = .{
        .dependency_flags = .{},
        .memory_barrier_count = 0,
        .p_memory_barriers = null,
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = @ptrCast(&buffer_barrier),
        .image_memory_barrier_count = 0,
        .p_image_memory_barriers = null,
    };
    self.dev.cmdPipelineBarrier2(cmd, &dependency_info);

    try self.dev.endCommandBuffer(cmd);

    const next_val = self.transfer_semaphore_value.fetchAdd(1, .monotonic) + 1;

    const semaphore_submit_info: vk.SemaphoreSubmitInfo = .{
        .semaphore = self.transfer_semaphore,
        .value = next_val,
        .stage_mask = .{ .all_transfer_bit = true },
        .device_index = 0,
    };
    const command_buffer_submit_info: vk.CommandBufferSubmitInfo = .{
        .command_buffer = cmd,
        .device_mask = 0,
    };

    const submit_info: vk.SubmitInfo2 = .{
        .flags = .{},
        .wait_semaphore_info_count = 0,
        .p_wait_semaphore_infos = null,
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = @ptrCast(&command_buffer_submit_info),
        .signal_semaphore_info_count = 1,
        .p_signal_semaphore_infos = @ptrCast(&semaphore_submit_info),
    };

    self.queue_mutex.lockUncancelable(io);
    defer self.queue_mutex.unlock(io);
    try self.dev.queueSubmit2(self.transfer_queue, &[_]vk.SubmitInfo2{submit_info}, .null_handle);

    self.pending_uploads_mutex.lockUncancelable(io);
    defer self.pending_uploads_mutex.unlock(io);
    try self.pending_uploads.append(self.allocator, .{
        .key = req.key,
        .device_address = device_address,
        .timeline_value = next_val,
        .buffer = buffer,
        .alloc_offset = alloc_res.offset,
        .alloc_size = alloc_res.alloc_size,
        .face_count = @intCast(req.faces.len),
        .pool = pool,
    });
}

fn processPendingUploads(self: *VulkanRenderer, io: std.Io) !void {
    self.upload_mutex.lockUncancelable(io);
    defer self.upload_mutex.unlock(io);

    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    var req_buf: [128]UploadRequest = undefined;
    while (true) {
        const count = self.upload_queue.get(io, &req_buf, 0) catch 0;
        if (count == 0) break;

        for (req_buf[0..count]) |req| {
            self.uploadOnePending(io, req) catch |err| {
                std.log.err("processPendingUploads: Failed to upload pending: {any}", .{err});
            };
        }
    }

    try self.retireCompletedUploads(io);
}

pub fn draw(self: *VulkanRenderer, io: std.Io, viewpos: @Vector(3, f64)) !void {
    const c = tracy.Zone.begin(.{ .src = @src() });
    defer c.end();

    try self.retireCompletedUploads(io);
    try self.processDeletionQueue(io);

    var current_frame = self.currentFrame();

    var fences_wait: [1]vk.Fence = .{self.in_flight_fences[current_frame]};
    try self.waitFences(&fences_wait);

    var fences_reset: [1]vk.Fence = .{self.in_flight_fences[current_frame]};
    try self.dev.resetFences(&fences_reset);

    if (self.swapchain_needs_recreate) {
        self.swapchain_needs_recreate = false;
        {
            self.queue_mutex.lockUncancelable(io);
            defer self.queue_mutex.unlock(io);
            try self.dev.deviceWaitIdle();
        }
        try self.createSwapchain(io);
        current_frame = self.currentFrame();
        try self.dev.resetFences(&.{self.in_flight_fences[current_frame]});
    }

    var image_index: u32 = 0;
    const acquire_result_res = try self.dev.acquireNextImageKHR(
        self.swapchain,
        std.math.maxInt(u64),
        self.image_acquired_semaphores[current_frame],
        .null_handle,
    );

    if (acquire_result_res.result == .error_out_of_date_khr or acquire_result_res.result == .suboptimal_khr) {
        if (acquire_result_res.result == .error_out_of_date_khr) {
            try self.createSwapchain(io);
        } else {
            try self.recreateSwapchainOnly(io);
        }
        current_frame = self.currentFrame();
        try self.dev.resetFences(&.{self.in_flight_fences[current_frame]});
        const acquire_result_res2 = try self.dev.acquireNextImageKHR(
            self.swapchain,
            std.math.maxInt(u64),
            self.image_acquired_semaphores[current_frame],
            .null_handle,
        );
        image_index = acquire_result_res2.image_index;
    } else {
        image_index = acquire_result_res.image_index;
    }

    self.current_swapchain_image_index = image_index;

    const cmd_buffer = self.cmd_buffers[current_frame];

    const aspect = @as(f32, @floatFromInt(self.viewport_pixels[0])) / @as(f32, @floatFromInt(self.viewport_pixels[1]));

    self.render_options_lock.lockSharedUncancelable(io);
    const draw_over = self.render_options.draw_over;
    const fov = std.math.degreesToRadians(self.render_options.fov);
    const day_length_sec = self.render_options.day_length_sec;
    self.render_options_lock.unlockShared(io);

    // Pure-rotation view matrix at origin — matches OpenGL convention.
    // The vertex shader already applies the translation via relative_position = chunk_pos - playerPos,
    // so including it in the view matrix would cause double-translation, putting everything off-screen.
    const up_vec: zm.vec.Vec3f = .{ .data = [3]f32{ cameraUp[0], cameraUp[1], cameraUp[2] } };

    const view = zm.matrix.Mat4f.lookAtRH(
        .{ .data = @Vector(3, f32){ 0, 0, 0 } },
        .{ .data = self.camera_front },
        up_vec,
    );

    const projection = makeInfReversedZProjRh(fov, aspect, 0.01);
    const projview: @Vector(16, f32) = @bitCast(projection.multiply(view).data);

    const blueSky = @Vector(4, f32){ 0.0, 0.4, 0.8, 1.0 };
    const greySky = @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 };
    const skyColor = std.math.lerp(blueSky, greySky, @as(@Vector(4, f32), @splat(@floatCast(@min(1.0, @max(0.0, viewpos[1] / 4096.0))))));

    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const now_ns_f = @as(f64, @floatFromInt(now_ns));
    const sun_angle = @rem(now_ns_f / ((@as(f64, @max(0.001, day_length_sec)) * std.time.ns_per_s) / 360.0), 360.0);
    const sun_rot_mat = zm.Mat4f.rotationRH(.{ .data = @Vector(3, f32){ 1.0, 0.0, 0.0 } }, @floatCast(std.math.degreesToRadians(sun_angle)));
    const sun_dir: @Vector(3, f32) = .{ sun_rot_mat.data[1][0], sun_rot_mat.data[1][1], sun_rot_mat.data[1][2] };

    const elapsed_sec = @as(f32, @floatFromInt(now_ns -| self.init_time_ns)) / std.time.ns_per_s;

    const begin_info: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };
    try self.dev.beginCommandBuffer(cmd_buffer, &begin_info);

    const color_attachment: vk.RenderingAttachmentInfo = .{
        .s_type = .rendering_attachment_info,
        .image_view = self.render_color_view,
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_view = .null_handle,
        .resolve_image_layout = .undefined,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = .{ skyColor[0], skyColor[1], skyColor[2], skyColor[3] } } },
    };

    const depth_attachment: vk.RenderingAttachmentInfo = .{
        .s_type = .rendering_attachment_info,
        .image_view = self.render_depth_view,
        .image_layout = .depth_stencil_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_view = .null_handle,
        .resolve_image_layout = .undefined,
        .load_op = .clear,
        .store_op = .dont_care,
        .clear_value = .{ .depth_stencil = .{ .depth = 0.0, .stencil = 0 } },
    };

    const render_info: vk.RenderingInfo = .{
        .flags = .{},
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain_extent },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment),
        .p_depth_attachment = &depth_attachment,
        .p_stencil_attachment = null,
    };
    self.dev.cmdBeginRendering(cmd_buffer, &render_info);

    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.pipeline);

    self.dev.cmdSetViewport(cmd_buffer, 0, &[_]vk.Viewport{.{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(self.swapchain_extent.width),
        .height = @floatFromInt(self.swapchain_extent.height),
        .min_depth = 0.0,
        .max_depth = 1.0,
    }});
    self.dev.cmdSetScissor(cmd_buffer, 0, &[_]vk.Rect2D{.{
        .offset = .{ .x = 0, .y = 0 },
        .extent = self.swapchain_extent,
    }});

    const buffer_info: vk.DescriptorBufferInfo = .{
        .buffer = self.chunk_data_buffers[current_frame],
        .offset = 0,
        .range = vk.WHOLE_SIZE,
    };

    const chunk_data_write: vk.WriteDescriptorSet = .{
        .dst_set = self.descriptor_sets_per_frame[current_frame],
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .storage_buffer,
        .p_image_info = undefined,
        .p_buffer_info = @ptrCast(&buffer_info),
        .p_texel_buffer_view = undefined,
    };

    self.dev.updateDescriptorSets(&[_]vk.WriteDescriptorSet{chunk_data_write}, null);

    var desc_set_arr: [1]vk.DescriptorSet = undefined;
    desc_set_arr[0] = self.descriptor_sets_per_frame[current_frame];
    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.pipeline_layout, 0, &desc_set_arr, null);

    var pc: PushConstants = .{
        .projview = @splat(0),
        .sun_dir = sun_dir,
        .time = elapsed_sec,
        .draw_over = @intFromBool(draw_over),
    };

    inline for (0..4) |row| {
        inline for (0..4) |col| {
            pc.projview[row * 4 + col] = @as([4][4]f32, @bitCast(projview))[col][row];
        }
    }

    self.dev.cmdPushConstants(cmd_buffer, self.pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(PushConstants), @ptrCast(&pc));

    const frustum = Frustum.extractFrustumPlanes(projview);

    const frame_start_ns = std.Io.Timestamp.now(io, .real).nanoseconds;

    const opaque_draw_count = try self.drawChunksReal(io, cmd_buffer, current_frame, viewpos, frustum, false, 0);

    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.transparent_pipeline);

    // OIT integration point: replace the simple indirect draw below with an OIT pass.
    _ = try self.drawChunksReal(io, cmd_buffer, current_frame, viewpos, frustum, true, opaque_draw_count);

    const frame_end_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const frame_elapsed_ns: u64 = @intCast(@max(0, frame_end_ns - frame_start_ns));

    const f_num = self.frame_number.load(.monotonic) + 1;
    self.frame_number.store(f_num, .monotonic);
    self.frame_stats.frame_number = f_num;
    self.frame_stats.total_meshes = @intCast(self.meshes.count(io));
    self.frame_stats.player_pos = viewpos;
    self.frame_stats.camera_front = self.camera_front;
    self.frame_stats.elapsed_ns = frame_elapsed_ns;

    if (f_num % 60 == 0) {
        self.frame_stats.log();
    }

    self.dev.cmdEndRendering(cmd_buffer);

    const color_to_copy_barrier: vk.ImageMemoryBarrier = .{
        .old_layout = .color_attachment_optimal,
        .new_layout = .transfer_src_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = self.render_color_image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_access_mask = .{ .color_attachment_write_bit = true },
        .dst_access_mask = .{ .transfer_read_bit = true },
    };
    const swapchain_to_copy_barrier: vk.ImageMemoryBarrier = .{
        .old_layout = .undefined,
        .new_layout = .transfer_dst_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = self.swapchain_images[image_index],
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_access_mask = .{},
        .dst_access_mask = .{ .transfer_write_bit = true },
    };
    var pre_copy_barriers = [_]vk.ImageMemoryBarrier{ color_to_copy_barrier, swapchain_to_copy_barrier };
    self.dev.cmdPipelineBarrier(cmd_buffer, .{ .color_attachment_output_bit = true }, .{ .transfer_bit = true }, .{}, null, null, &pre_copy_barriers);

    const image_copy: vk.ImageCopy = .{
        .src_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .src_offset = .{ .x = 0, .y = 0, .z = 0 },
        .dst_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
        .extent = .{ .width = self.swapchain_extent.width, .height = self.swapchain_extent.height, .depth = 1 },
    };
    self.dev.cmdCopyImage(cmd_buffer, self.render_color_image, .transfer_src_optimal, self.swapchain_images[image_index], .transfer_dst_optimal, &[_]vk.ImageCopy{image_copy});

    const swapchain_to_present_barrier: vk.ImageMemoryBarrier = .{
        .old_layout = .transfer_dst_optimal,
        .new_layout = .present_src_khr,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = self.swapchain_images[image_index],
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_access_mask = .{ .color_attachment_read_bit = true },
    };
    const color_return_barrier: vk.ImageMemoryBarrier = .{
        .old_layout = .transfer_src_optimal,
        .new_layout = .color_attachment_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = self.render_color_image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_access_mask = .{ .transfer_read_bit = true },
        .dst_access_mask = .{ .color_attachment_write_bit = true },
    };
    var color_return_barriers = [_]vk.ImageMemoryBarrier{ color_return_barrier, swapchain_to_present_barrier };
    self.dev.cmdPipelineBarrier(cmd_buffer, .{ .transfer_bit = true }, .{ .color_attachment_output_bit = true }, .{}, null, null, &color_return_barriers);

    try self.dev.endCommandBuffer(cmd_buffer);

    const wait_stages = [_]vk.PipelineStageFlags{.{ .transfer_bit = true }};

    const wait_semaphores: [1]vk.Semaphore = .{self.image_acquired_semaphores[current_frame]};

    const signal_sems = [_]vk.Semaphore{ self.render_complete_semaphores[current_frame], self.graphics_timeline_semaphore };
    const signal_values = [_]u64{ 0, self.frame_number.load(.monotonic) };

    const wait_values = [_]u64{0};
    var timeline_submit_info: vk.TimelineSemaphoreSubmitInfo = .{
        .wait_semaphore_value_count = 1,
        .p_wait_semaphore_values = @ptrCast(&wait_values),
        .signal_semaphore_value_count = 2,
        .p_signal_semaphore_values = @ptrCast(&signal_values),
    };

    const submit_info: vk.SubmitInfo = .{
        .p_next = &timeline_submit_info,
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&wait_semaphores),
        .p_wait_dst_stage_mask = @ptrCast(&wait_stages),
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmd_buffer),
        .signal_semaphore_count = 2,
        .p_signal_semaphores = @ptrCast(&signal_sems),
    };

    {
        self.queue_mutex.lockUncancelable(io);
        defer self.queue_mutex.unlock(io);

        try self.dev.queueSubmit(self.graphics_queue, &[_]vk.SubmitInfo{submit_info}, self.in_flight_fences[current_frame]);
    }

    const present_info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&self.render_complete_semaphores[current_frame]),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.swapchain),
        .p_image_indices = &.{image_index},
        .p_results = null,
    };

    const present_result = blk: {
        self.queue_mutex.lockUncancelable(io);
        defer self.queue_mutex.unlock(io);

        break :blk try self.dev.queuePresentKHR(self.present_queue, &present_info);
    };

    if (present_result == .success) {
        const next_frame = (current_frame + 1) % @as(u32, @intCast(self.in_flight_fences.len));
        self.current_frame_idx.store(next_frame, .monotonic);
    } else if (present_result == .error_out_of_date_khr or present_result == .suboptimal_khr) {
        try self.createSwapchain(io);
    }
}

fn vtableDrawChunks(userdata: *anyopaque, io: std.Io, viewpos: @Vector(3, f64)) (std.Io.Cancelable || error{DrawFailed})!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));
    self.draw(io, viewpos) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.DrawFailed,
    };
}

fn drawChunksReal(self: *VulkanRenderer, io: std.Io, cmd_buffer: vk.CommandBuffer, current_frame: u32, playerPos: @Vector(3, f64), frustum: Frustum, is_transparent: bool, write_offset: u32) error{ DrawFailed, Canceled, OutOfMemory }!u32 {
    const frame_idx = current_frame % @as(u32, @intCast(self.indirect_draw_buffers_mapped.len));
    const indirect_mapped = self.indirect_draw_buffers_mapped[frame_idx];
    const chunk_data_mapped = self.chunk_data_buffers_mapped[frame_idx];

    var indirect_cmds: [*]vk.DrawIndirectCommand = @ptrCast(@alignCast(indirect_mapped));
    var chunk_data: [*]ChunkData = @ptrCast(@alignCast(chunk_data_mapped));

    var draw_count: u32 = 0;
    var candidates: u32 = 0;
    var culled: u32 = 0;

    var it = self.meshes.iterator();
    defer it.deinit(io);
    while (try it.next(io)) |entry| {
        const key = entry.key_ptr.*;
        if (is_transparent != (key == .transparent)) continue;

        candidates += 1;
        const chunkpos = key.toPos();

        if (!cullChunk(&frustum, chunkpos, playerPos)) {
            const mesh = entry.value_ptr;

            const ratio: @Vector(3, f64) = @splat(@floatCast(ChunkPos.levelToBlockRatioFloat(chunkpos.level)));
            const chunk_blockpos = @as(@Vector(3, f64), @floatFromInt(chunkpos.position)) * ratio;
            const relative_blockpos = chunk_blockpos - playerPos;

            const write_idx = write_offset + draw_count;

            chunk_data[write_idx] = .{
                .absolute_position = @bitCast(@as(@Vector(3, f32), @floatCast(chunk_blockpos))),
                .relative_position = @bitCast(@as(@Vector(3, f32), @floatCast(relative_blockpos))),
                .scale = ChunkPos.toScale(chunkpos.level),
                .address = mesh.device_address,
            };

            indirect_cmds[write_idx] = .{
                .vertex_count = mesh.face_count * 6,
                .instance_count = 1,
                .first_vertex = 0,
                .first_instance = write_offset + draw_count,
            };

            draw_count += 1;
            if (draw_count >= self.max_draw_count -| write_offset) break;
        } else {
            culled += 1;
        }
    }

    if (is_transparent) {
        self.frame_stats.transparent_candidates = candidates;
        self.frame_stats.transparent_culled = culled;
        self.frame_stats.transparent_drawn = draw_count;
    } else {
        self.frame_stats.opaque_candidates = candidates;
        self.frame_stats.opaque_culled = culled;
        self.frame_stats.opaque_drawn = draw_count;
    }

    if (draw_count == 0) return 0;

    const byte_offset: vk.DeviceSize = @intCast(write_offset * @sizeOf(vk.DrawIndirectCommand));
    self.dev.cmdDrawIndirect(cmd_buffer, self.indirect_draw_buffers[frame_idx], byte_offset, draw_count, @sizeOf(vk.DrawIndirectCommand));

    return draw_count;
}

fn allocateIndirectBuffers(self: *VulkanRenderer) !void {
    const num_frames = self.swapchain_images.len;

    if (self.indirect_draw_buffers_mapped.len > 0) {
        self.allocator.free(self.indirect_draw_buffers_mapped);
        self.indirect_draw_buffers_mapped = &.{};
    }
    if (self.chunk_data_buffers_mapped.len > 0) {
        self.allocator.free(self.chunk_data_buffers_mapped);
        self.chunk_data_buffers_mapped = &.{};
    }

    self.indirect_draw_buffers = try self.allocator.alloc(vk.Buffer, num_frames);
    @memset(self.indirect_draw_buffers, .null_handle);
    errdefer {
        for (self.indirect_draw_buffers) |buf| {
            if (buf != .null_handle) self.dev.destroyBuffer(buf, null);
        }
        if (self.indirect_draw_buffers.len > 0) self.allocator.free(self.indirect_draw_buffers);
        self.indirect_draw_buffers = &.{};
    }
    self.indirect_draw_memories = try self.allocator.alloc(vk.DeviceMemory, num_frames);
    @memset(self.indirect_draw_memories, .null_handle);
    errdefer {
        for (self.indirect_draw_memories) |mem| {
            if (mem != .null_handle) self.dev.freeMemory(mem, null);
        }
        self.allocator.free(self.indirect_draw_memories);
        self.indirect_draw_memories = &.{};
    }

    const indirect_size: vk.DeviceSize = @intCast(self.max_draw_count * @sizeOf(vk.DrawIndirectCommand));
    for (0..num_frames) |i| {
        try self.createBuffer(indirect_size, .{ .indirect_buffer_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, &self.indirect_draw_buffers[i], &self.indirect_draw_memories[i]);
    }

    self.indirect_draw_buffers_mapped = try self.allocator.alloc([*]u8, num_frames);
    errdefer {
        if (self.indirect_draw_buffers_mapped.len > 0) self.allocator.free(self.indirect_draw_buffers_mapped);
        self.indirect_draw_buffers_mapped = &.{};
    }
    for (0..num_frames) |i| {
        const mapped = try self.dev.mapMemory(self.indirect_draw_memories[i], 0, vk.WHOLE_SIZE, .{});
        self.indirect_draw_buffers_mapped[i] = @ptrCast(@alignCast(mapped));
    }

    self.chunk_data_buffers = try self.allocator.alloc(vk.Buffer, num_frames);
    @memset(self.chunk_data_buffers, .null_handle);
    errdefer {
        for (self.chunk_data_buffers) |buf| {
            if (buf != .null_handle) self.dev.destroyBuffer(buf, null);
        }
        self.allocator.free(self.chunk_data_buffers);
        self.chunk_data_buffers = &.{};
    }
    self.chunk_data_memories = try self.allocator.alloc(vk.DeviceMemory, num_frames);
    @memset(self.chunk_data_memories, .null_handle);
    errdefer {
        for (self.chunk_data_memories) |mem| {
            if (mem != .null_handle) self.dev.freeMemory(mem, null);
        }
        self.allocator.free(self.chunk_data_memories);
        self.chunk_data_memories = &.{};
    }

    const chunk_data_size: vk.DeviceSize = @intCast(self.max_draw_count * @sizeOf(ChunkData));
    for (0..num_frames) |i| {
        try self.createBuffer(chunk_data_size, .{ .storage_buffer_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, &self.chunk_data_buffers[i], &self.chunk_data_memories[i]);
    }

    self.chunk_data_buffers_mapped = try self.allocator.alloc([*]u8, num_frames);
    errdefer {
        if (self.chunk_data_buffers_mapped.len > 0) self.allocator.free(self.chunk_data_buffers_mapped);
        self.chunk_data_buffers_mapped = &.{};
    }
    for (0..num_frames) |i| {
        const mapped = try self.dev.mapMemory(self.chunk_data_memories[i], 0, vk.WHOLE_SIZE, .{});
        self.chunk_data_buffers_mapped[i] = @ptrCast(@alignCast(mapped));
    }
}

pub fn createBuffer(self: *VulkanRenderer, size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags, buffer: *vk.Buffer, memory: *vk.DeviceMemory) !void {
    std.debug.assert(size != 0);

    const buffer_info: vk.BufferCreateInfo = .{
        .flags = .{},
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    buffer.* = try self.dev.createBuffer(&buffer_info, null);

    const mem_reqs = self.dev.getBufferMemoryRequirements(buffer.*);
    const alloc_info: vk.MemoryAllocateInfo = .{
        .allocation_size = mem_reqs.size,
        .memory_type_index = self.findMemoryType(mem_reqs.memory_type_bits, properties),
    };
    errdefer self.dev.destroyBuffer(buffer.*, null);
    memory.* = try self.dev.allocateMemory(&alloc_info, null);
    try self.dev.bindBufferMemory(buffer.*, memory.*, 0);
}

fn copyBuffer(self: *VulkanRenderer, io: std.Io, src: vk.Buffer, dst: vk.Buffer, size: vk.DeviceSize) !void {
    self.queue_mutex.lockUncancelable(io);
    defer self.queue_mutex.unlock(io);

    const alloc_info: vk.CommandBufferAllocateInfo = .{
        .level = .primary,
        .command_pool = self.upload_command_pool,
        .command_buffer_count = 1,
    };
    var cmd: vk.CommandBuffer = undefined;
    try self.dev.allocateCommandBuffers(&alloc_info, @ptrCast(&cmd));
    defer self.dev.freeCommandBuffers(self.upload_command_pool, &.{cmd});

    const begin_info: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };
    try self.dev.beginCommandBuffer(cmd, &begin_info);

    const copy_region: vk.BufferCopy = .{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    self.dev.cmdCopyBuffer(cmd, src, dst, @ptrCast(&copy_region));

    try self.dev.endCommandBuffer(cmd);

    const submit_info: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmd),
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    };

    try self.dev.queueSubmit(self.graphics_queue, &.{submit_info}, .null_handle);

    try self.dev.queueWaitIdle(self.graphics_queue);
}

pub fn findMemoryType(self: *const VulkanRenderer, type_filter: u32, properties: vk.MemoryPropertyFlags) u32 {
    return findMemoryTypeRaw(self.mem_props, type_filter, properties);
}

fn recreateSwapchainOnly(self: *VulkanRenderer, io: std.Io) !void {
    try self.dev.deviceWaitIdle();

    try self.createSwapchain(io);
}

fn destroyOldSwapchainResources(self: *VulkanRenderer, io: std.Io) void {
    _ = io;
    self.dev.deviceWaitIdle() catch |err| {
        std.log.err("destroyOldSwapchainResources: deviceWaitIdle failed: {any}", .{err});
    };

    for (self.swapchain_views) |view| if (view != .null_handle) self.dev.destroyImageView(view, null);
    self.allocator.free(self.swapchain_images);
    self.allocator.free(self.swapchain_views);
    self.swapchain_images = &.{};
    self.swapchain_views = &.{};

    if (self.cmd_buffers.len > 0) {
        self.dev.freeCommandBuffers(self.command_pool, self.cmd_buffers);
        self.allocator.free(self.cmd_buffers);
        self.cmd_buffers = &.{};
    }

    for (self.image_acquired_semaphores) |sem| if (sem != .null_handle) self.dev.destroySemaphore(sem, null);
    for (self.render_complete_semaphores) |sem| if (sem != .null_handle) self.dev.destroySemaphore(sem, null);
    for (self.in_flight_fences) |fence| if (fence != .null_handle) self.dev.destroyFence(fence, null);
    self.allocator.free(self.image_acquired_semaphores);
    self.allocator.free(self.render_complete_semaphores);
    self.allocator.free(self.in_flight_fences);
    self.image_acquired_semaphores = &.{};
    self.render_complete_semaphores = &.{};
    self.in_flight_fences = &.{};

    if (self.render_color_view != .null_handle) self.dev.destroyImageView(self.render_color_view, null);
    if (self.render_depth_view != .null_handle) self.dev.destroyImageView(self.render_depth_view, null);
    if (self.render_color_image != .null_handle) self.dev.destroyImage(self.render_color_image, null);
    if (self.render_color_memory != .null_handle) self.dev.freeMemory(self.render_color_memory, null);
    if (self.render_depth_image != .null_handle) self.dev.destroyImage(self.render_depth_image, null);
    if (self.render_depth_memory != .null_handle) self.dev.freeMemory(self.render_depth_memory, null);
    self.render_color_view = .null_handle;
    self.render_depth_view = .null_handle;
    self.render_color_image = .null_handle;
    self.render_color_memory = .null_handle;
    self.render_depth_image = .null_handle;
    self.render_depth_memory = .null_handle;

    for (self.indirect_draw_buffers) |buf| if (buf != .null_handle) self.dev.destroyBuffer(buf, null);
    self.allocator.free(self.indirect_draw_buffers);
    self.indirect_draw_buffers = &.{};

    for (self.indirect_draw_memories) |mem| if (mem != .null_handle) self.dev.freeMemory(mem, null);
    self.allocator.free(self.indirect_draw_memories);
    self.indirect_draw_memories = &.{};

    for (self.chunk_data_buffers) |buf| if (buf != .null_handle) self.dev.destroyBuffer(buf, null);
    self.allocator.free(self.chunk_data_buffers);
    self.chunk_data_buffers = &.{};

    for (self.chunk_data_memories) |mem| if (mem != .null_handle) self.dev.freeMemory(mem, null);
    self.allocator.free(self.chunk_data_memories);
    self.chunk_data_memories = &.{};

    self.allocator.free(self.indirect_draw_buffers_mapped);
    self.indirect_draw_buffers_mapped = &.{};

    self.allocator.free(self.chunk_data_buffers_mapped);
    self.chunk_data_buffers_mapped = &.{};

    if (self.descriptor_pool != .null_handle) {
        self.dev.destroyDescriptorPool(self.descriptor_pool, null);
        self.descriptor_pool = .null_handle;
    }
    self.allocator.free(self.descriptor_sets_per_frame);
    self.descriptor_sets_per_frame = &.{};
}

fn createSwapchain(self: *VulkanRenderer, io: std.Io) !void {
    self.queue_mutex.lockUncancelable(io);
    defer self.queue_mutex.unlock(io);

    if (self.swapchain_extent.width == 0 or self.swapchain_extent.height == 0) {
        return error.InvalidWindowSize;
    }

    std.log.info("VulkanRenderer.createSwapchain: Starting swapchain creation...", .{});

    const caps = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.pdev, self.surface);

    const old_swapchain = self.swapchain;

    if (old_swapchain != .null_handle or self.swapchain_images.len > 0 or self.render_color_image != .null_handle) {
        self.destroyOldSwapchainResources(io);
    }

    const actual_extent = if (caps.current_extent.width != 0xFFFF_FFFF) caps.current_extent else vk.Extent2D{
        .width = std.math.clamp(self.swapchain_extent.width, caps.min_image_extent.width, @min(caps.max_image_extent.width, 3840)),
        .height = std.math.clamp(self.swapchain_extent.height, caps.min_image_extent.height, @min(caps.max_image_extent.height, 2160)),
    };

    self.swapchain_extent = actual_extent;
    self.viewport_pixels = .{ actual_extent.width, actual_extent.height };

    const surface_formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.pdev, self.surface, self.allocator);
    defer self.allocator.free(surface_formats);

    self.render_options_lock.lockSharedUncancelable(io);
    const gamma_correction = self.render_options.gamma_correction;
    self.render_options_lock.unlockShared(io);

    const target_formats: []const vk.Format = if (gamma_correction)
        &[_]vk.Format{ .b8g8r8a8_srgb, .r8g8b8a8_srgb }
    else
        &[_]vk.Format{ .b8g8r8a8_unorm, .r8g8b8a8_unorm };

    var surface_format = surface_formats[0];
    blk: for (target_formats) |tf| {
        for (surface_formats) |sfmt| {
            if (sfmt.format == tf) {
                surface_format = sfmt;
                break :blk;
            }
        }
    }
    self.swapchain_format = surface_format.format;

    const present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(self.pdev, self.surface, self.allocator);
    defer self.allocator.free(present_modes);

    var present_mode: vk.PresentModeKHR = .fifo_khr;
    for (present_modes) |pm| {
        if (pm == .mailbox_khr or pm == .immediate_khr) {
            present_mode = pm;
            break;
        }
    }

    const raw_count = @max(caps.min_image_count + 1, @as(u32, 2));
    const image_count = if (caps.max_image_count > 0) @min(raw_count, caps.max_image_count) else raw_count;

    const qfi = [_]u32{ self.queue_family_index, self.present_queue_family_index };
    const sharing_mode: vk.SharingMode = if (self.queue_family_index != self.present_queue_family_index) .concurrent else .exclusive;

    errdefer if (old_swapchain != .null_handle) self.dev.destroySwapchainKHR(old_swapchain, null);

    self.swapchain = try self.dev.createSwapchainKHR(&.{
        .surface = self.surface,
        .min_image_count = image_count,
        .image_format = self.swapchain_format,
        .image_color_space = surface_format.color_space,
        .image_extent = actual_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = sharing_mode,
        .queue_family_index_count = if (sharing_mode == .concurrent) @as(u32, qfi.len) else 0,
        .p_queue_family_indices = if (sharing_mode == .concurrent) &qfi else null,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = .true,
        .old_swapchain = old_swapchain,
    }, null);
    if (old_swapchain != .null_handle) self.dev.destroySwapchainKHR(old_swapchain, null);

    errdefer {
        self.dev.destroySwapchainKHR(self.swapchain, null);
        self.swapchain = .null_handle;
    }

    self.swapchain_images = try self.dev.getSwapchainImagesAllocKHR(self.swapchain, self.allocator);
    errdefer {
        self.allocator.free(self.swapchain_images);
        self.swapchain_images = &.{};
    }

    self.swapchain_views = try self.allocator.alloc(vk.ImageView, self.swapchain_images.len);
    @memset(self.swapchain_views, .null_handle);
    errdefer {
        for (self.swapchain_views) |view| {
            if (view != .null_handle) self.dev.destroyImageView(view, null);
        }
        self.allocator.free(self.swapchain_views);
        self.swapchain_views = &.{};
    }

    for (self.swapchain_images, 0..) |image, i| {
        const view_info: vk.ImageViewCreateInfo = .{
            .flags = .{},
            .image = image,
            .view_type = .@"2d",
            .format = self.swapchain_format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        self.swapchain_views[i] = try self.dev.createImageView(&view_info, null);
    }

    const num_swapchain_images = self.swapchain_images.len;

    self.image_acquired_semaphores = try self.allocator.alloc(vk.Semaphore, num_swapchain_images);
    @memset(self.image_acquired_semaphores, .null_handle);
    errdefer {
        for (self.image_acquired_semaphores) |sem| {
            if (sem != .null_handle) self.dev.destroySemaphore(sem, null);
        }
        if (self.image_acquired_semaphores.len > 0) self.allocator.free(self.image_acquired_semaphores);
        self.image_acquired_semaphores = &.{};
    }

    self.render_complete_semaphores = try self.allocator.alloc(vk.Semaphore, num_swapchain_images);
    @memset(self.render_complete_semaphores, .null_handle);
    errdefer {
        for (self.render_complete_semaphores) |sem| {
            if (sem != .null_handle) self.dev.destroySemaphore(sem, null);
        }
        if (self.render_complete_semaphores.len > 0) self.allocator.free(self.render_complete_semaphores);
        self.render_complete_semaphores = &.{};
    }

    self.in_flight_fences = try self.allocator.alloc(vk.Fence, num_swapchain_images);
    @memset(self.in_flight_fences, .null_handle);
    errdefer {
        for (self.in_flight_fences) |fence| {
            if (fence != .null_handle) self.dev.destroyFence(fence, null);
        }
        if (self.in_flight_fences.len > 0) self.allocator.free(self.in_flight_fences);
        self.in_flight_fences = &.{};
    }

    const semaphore_create_info: vk.SemaphoreCreateInfo = .{ .flags = .{} };
    const fence_create_info: vk.FenceCreateInfo = .{
        .flags = .{ .signaled_bit = true },
    };

    for (0..num_swapchain_images) |i| {
        self.image_acquired_semaphores[i] = try self.dev.createSemaphore(&semaphore_create_info, null);
        self.render_complete_semaphores[i] = try self.dev.createSemaphore(&semaphore_create_info, null);
        self.in_flight_fences[i] = try self.dev.createFence(&fence_create_info, null);
    }

    const cmd_alloc_info: vk.CommandBufferAllocateInfo = .{
        .command_pool = self.command_pool,
        .level = .primary,
        .command_buffer_count = @intCast(num_swapchain_images),
    };

    self.cmd_buffers = try self.allocator.alloc(vk.CommandBuffer, num_swapchain_images);
    errdefer self.allocator.free(self.cmd_buffers);
    try self.dev.allocateCommandBuffers(&cmd_alloc_info, self.cmd_buffers.ptr);
    errdefer {
        self.dev.freeCommandBuffers(self.command_pool, self.cmd_buffers);
        self.allocator.free(self.cmd_buffers);
        self.cmd_buffers = &.{};
    }

    self.createRenderTargets(io, actual_extent) catch |err| {
        std.log.err("createRenderTargets failed: {}", .{err});
        return err;
    };

    try self.allocateIndirectBuffers();

    // Recreate descriptor pool and sets if they were previously created (i.e., this is
    // a resize, not the initial creation — descriptor_set_layout doesn't exist yet at init)
    if (self.descriptor_set_layout != .null_handle) {
        try self.createDescriptorPoolAndSets(io, true);
        // Rebind the real block texture array to the new descriptor sets
        // (createDescriptorPoolAndSets writes the dummy white texture; overwrite with real one if loaded)
        if (self.texture_manager.texture_view != .null_handle) {
            self.texture_manager.rebindDescriptorSets();
        }
    }

    // Recreate pipelines with the current swapchain format (only if they already exist)
    if (self.pipeline_layout != .null_handle) {
        if (self.pipeline != .null_handle) {
            self.dev.destroyPipeline(self.pipeline, null);
            self.pipeline = .null_handle;
        }
        if (self.transparent_pipeline != .null_handle) {
            self.dev.destroyPipeline(self.transparent_pipeline, null);
            self.transparent_pipeline = .null_handle;
        }
        self.dev.destroyPipelineLayout(self.pipeline_layout, null);
        self.pipeline_layout = .null_handle;
        try self.createPipeline();
        try self.createTransparentPipeline();
    }
}

fn createRenderTargets(self: *VulkanRenderer, io: std.Io, extent: vk.Extent2D) !void {
    if (self.render_color_view != .null_handle) self.dev.destroyImageView(self.render_color_view, null);
    if (self.render_depth_view != .null_handle) self.dev.destroyImageView(self.render_depth_view, null);
    if (self.render_color_image != .null_handle) self.dev.destroyImage(self.render_color_image, null);
    if (self.render_color_memory != .null_handle) self.dev.freeMemory(self.render_color_memory, null);
    if (self.render_depth_image != .null_handle) self.dev.destroyImage(self.render_depth_image, null);
    if (self.render_depth_memory != .null_handle) self.dev.freeMemory(self.render_depth_memory, null);
    self.render_color_view = .null_handle;
    self.render_depth_view = .null_handle;
    self.render_color_image = .null_handle;
    self.render_color_memory = .null_handle;
    self.render_depth_image = .null_handle;
    self.render_depth_memory = .null_handle;

    errdefer {
        if (self.render_color_view != .null_handle) {
            self.dev.destroyImageView(self.render_color_view, null);
            self.render_color_view = .null_handle;
        }
        if (self.render_depth_view != .null_handle) {
            self.dev.destroyImageView(self.render_depth_view, null);
            self.render_depth_view = .null_handle;
        }
        if (self.render_color_image != .null_handle) {
            self.dev.destroyImage(self.render_color_image, null);
            self.render_color_image = .null_handle;
        }
        if (self.render_color_memory != .null_handle) {
            self.dev.freeMemory(self.render_color_memory, null);
            self.render_color_memory = .null_handle;
        }
        if (self.render_depth_image != .null_handle) {
            self.dev.destroyImage(self.render_depth_image, null);
            self.render_depth_image = .null_handle;
        }
        if (self.render_depth_memory != .null_handle) {
            self.dev.freeMemory(self.render_depth_memory, null);
            self.render_depth_memory = .null_handle;
        }
    }
    self.render_depth_memory = .null_handle;

    const color_image_info: vk.ImageCreateInfo = .{
        .flags = .{},
        .image_type = .@"2d",
        .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .format = self.swapchain_format,
        .tiling = .optimal,
        .initial_layout = .undefined,
        .usage = .{ .color_attachment_bit = true, .transfer_src_bit = true },
        .sharing_mode = .exclusive,
        .samples = .{ .@"1_bit" = true },
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    self.render_color_image = try self.dev.createImage(&color_image_info, null);
    const color_mem_reqs = self.dev.getImageMemoryRequirements(self.render_color_image);
    const color_alloc_info: vk.MemoryAllocateInfo = .{
        .allocation_size = color_mem_reqs.size,
        .memory_type_index = self.findMemoryType(color_mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    };
    self.render_color_memory = try self.dev.allocateMemory(&color_alloc_info, null);
    try self.dev.bindImageMemory(self.render_color_image, self.render_color_memory, 0);

    {
        const cmd = try self.beginSingleTimeCommands(io);
        const barrier: vk.ImageMemoryBarrier = .{
            .old_layout = .undefined,
            .new_layout = .color_attachment_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.render_color_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_access_mask = .{},
            .dst_access_mask = .{ .color_attachment_write_bit = true },
        };
        const color_barrier_arr: [1]vk.ImageMemoryBarrier = .{barrier};
        self.dev.cmdPipelineBarrier(cmd, .{ .top_of_pipe_bit = true }, .{ .color_attachment_output_bit = true }, .{}, null, null, &color_barrier_arr);
        try self.endSingleTimeCommandsLocked(cmd);
    }

    const color_view_info: vk.ImageViewCreateInfo = .{
        .flags = .{},
        .image = self.render_color_image,
        .view_type = .@"2d",
        .format = self.swapchain_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    self.render_color_view = try self.dev.createImageView(&color_view_info, null);

    const depth_formats: [3]vk.Format = .{ .d32_sfloat_s8_uint, .d24_unorm_s8_uint, .d32_sfloat };
    var depth_format: vk.Format = .undefined;
    for (depth_formats) |fmt| {
        if (self.instance.getPhysicalDeviceFormatProperties(self.pdev, fmt).optimal_tiling_features.depth_stencil_attachment_bit) {
            depth_format = fmt;
            self.depth_format = fmt;
            break;
        }
    }
    if (depth_format == .undefined) return error.DepthFormatNotSupported;

    const depth_has_stencil = depth_format == .d32_sfloat_s8_uint or depth_format == .d24_unorm_s8_uint;
    const depth_aspect_mask: vk.ImageAspectFlags = if (depth_has_stencil) .{ .depth_bit = true, .stencil_bit = true } else .{ .depth_bit = true };
    const depth_image_info: vk.ImageCreateInfo = .{
        .flags = .{},
        .image_type = .@"2d",
        .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .format = depth_format,
        .tiling = .optimal,
        .initial_layout = .undefined,
        .usage = .{ .depth_stencil_attachment_bit = true },
        .sharing_mode = .exclusive,
        .samples = .{ .@"1_bit" = true },
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    self.render_depth_image = try self.dev.createImage(&depth_image_info, null);
    const depth_mem_reqs = self.dev.getImageMemoryRequirements(self.render_depth_image);
    const depth_alloc_info: vk.MemoryAllocateInfo = .{
        .allocation_size = depth_mem_reqs.size,
        .memory_type_index = self.findMemoryType(depth_mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    };
    self.render_depth_memory = try self.dev.allocateMemory(&depth_alloc_info, null);
    try self.dev.bindImageMemory(self.render_depth_image, self.render_depth_memory, 0);

    {
        const cmd = try self.beginSingleTimeCommands(io);
        const barrier: vk.ImageMemoryBarrier = .{
            .old_layout = .undefined,
            .new_layout = .depth_stencil_attachment_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.render_depth_image,
            .subresource_range = .{
                .aspect_mask = depth_aspect_mask,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_access_mask = .{},
            .dst_access_mask = .{ .depth_stencil_attachment_write_bit = true },
        };
        const depth_barrier_arr: [1]vk.ImageMemoryBarrier = .{barrier};
        self.dev.cmdPipelineBarrier(cmd, .{ .top_of_pipe_bit = true }, .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true }, .{}, null, null, &depth_barrier_arr);
        try self.endSingleTimeCommandsLocked(cmd);
    }

    const depth_view_info: vk.ImageViewCreateInfo = .{
        .flags = .{},
        .image = self.render_depth_image,
        .view_type = .@"2d",
        .format = depth_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = depth_aspect_mask,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    self.render_depth_view = try self.dev.createImageView(&depth_view_info, null);

    std.log.info("VulkanRenderer.createRenderTargets: SUCCESS - Created render targets: color image {any}, depth image {any}\n", .{ self.render_color_image, self.render_depth_image });
}

fn createDescriptorSetLayout(self: *VulkanRenderer) !void {
    const bindings: [2]vk.DescriptorSetLayoutBinding = .{
        .{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .vertex_bit = true }, .p_immutable_samplers = null },
        .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
    };
    var layout_info: vk.DescriptorSetLayoutCreateInfo = .{ .flags = .{}, .binding_count = bindings.len, .p_bindings = @ptrCast(&bindings) };
    self.descriptor_set_layout = try self.dev.createDescriptorSetLayout(&layout_info, null);
}

fn createDescriptorPoolAndSets(self: *VulkanRenderer, io: std.Io, locked: bool) !void {
    // Destroy any stale dummy textures from a previous call (swapchain recreation).
    // On first call during init they start as .null_handle so this is a no-op.
    self.destroyDummyResources();

    const num_frames = self.swapchain_images.len;
    const pool_sizes: [2]vk.DescriptorPoolSize = .{
        .{ .type = .storage_buffer, .descriptor_count = @intCast(num_frames) },
        .{ .type = .combined_image_sampler, .descriptor_count = @intCast(num_frames) },
    };

    const pool_info: vk.DescriptorPoolCreateInfo = .{
        .flags = .{},
        .max_sets = @intCast(num_frames),
        .pool_size_count = pool_sizes.len,
        .p_pool_sizes = @ptrCast(&pool_sizes),
    };

    self.descriptor_pool = try self.dev.createDescriptorPool(&pool_info, null);
    errdefer {
        // Clean up any dummy resources that may have been partially created,
        // plus the descriptor pool itself, on any error during this function.
        self.destroyDummyResources();
        if (self.descriptor_pool != .null_handle) {
            self.dev.destroyDescriptorPool(self.descriptor_pool, null);
            self.descriptor_pool = .null_handle;
        }
    }

    self.descriptor_sets_per_frame = try self.allocator.alloc(vk.DescriptorSet, num_frames);
    @memset(self.descriptor_sets_per_frame, .null_handle);
    errdefer {
        if (self.descriptor_sets_per_frame.len > 0) self.allocator.free(self.descriptor_sets_per_frame);
        self.descriptor_sets_per_frame = &.{};
    }

    for (0..num_frames) |i| {
        const alloc_info: vk.DescriptorSetAllocateInfo = .{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&self.descriptor_set_layout),
        };

        var desc_set: [1]vk.DescriptorSet = undefined;
        try self.dev.allocateDescriptorSets(&alloc_info, &desc_set);
        self.descriptor_sets_per_frame[i] = desc_set[0];
    }

    const dummy_staging_size: vk.DeviceSize = 256 * 4;

    var staging_buffer_dummy: vk.Buffer = .null_handle;
    var staging_memory_dummy: vk.DeviceMemory = .null_handle;
    try self.createBuffer(dummy_staging_size, .{ .transfer_src_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, &staging_buffer_dummy, &staging_memory_dummy);
    defer {
        if (staging_buffer_dummy != .null_handle) self.dev.destroyBuffer(staging_buffer_dummy, null);
        if (staging_memory_dummy != .null_handle) self.dev.freeMemory(staging_memory_dummy, null);
    }

    const dummy_data = try self.dev.mapMemory(staging_memory_dummy, 0, dummy_staging_size, .{});
    const mapped_slice = @as([*]u8, @ptrCast(dummy_data))[0..dummy_staging_size];
    @memset(mapped_slice, 255);
    self.dev.unmapMemory(staging_memory_dummy);

    const dummy_image_info: vk.ImageCreateInfo = .{
        .flags = .{},
        .image_type = .@"2d",
        .extent = .{ .width = 1, .height = 1, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 256,
        .format = .r8g8b8a8_unorm,
        .tiling = .optimal,
        .initial_layout = .undefined,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .sharing_mode = .exclusive,
        .samples = .{ .@"1_bit" = true },
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };

    self.dummy_image = try self.dev.createImage(&dummy_image_info, null);

    const dummy_mem_reqs = self.dev.getImageMemoryRequirements(self.dummy_image);
    const dummy_alloc_info: vk.MemoryAllocateInfo = .{
        .allocation_size = dummy_mem_reqs.size,
        .memory_type_index = self.findMemoryType(dummy_mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    };
    self.dummy_memory = try self.dev.allocateMemory(&dummy_alloc_info, null);
    try self.dev.bindImageMemory(self.dummy_image, self.dummy_memory, 0);

    {
        const cmd = try self.beginSingleTimeCommands(io);

        var barrier: vk.ImageMemoryBarrier = .{
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.dummy_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 256,
            },
            .src_access_mask = .{},
            .dst_access_mask = .{ .transfer_write_bit = true },
        };

        const to_transfer_dst: [1]vk.ImageMemoryBarrier = .{barrier};
        self.dev.cmdPipelineBarrier(cmd, .{ .top_of_pipe_bit = true }, .{ .transfer_bit = true }, .{}, null, null, &to_transfer_dst);

        const copy_region: vk.BufferImageCopy = .{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 256,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = 1, .height = 1, .depth = 1 },
        };

        self.dev.cmdCopyBufferToImage(cmd, staging_buffer_dummy, self.dummy_image, .transfer_dst_optimal, &[_]vk.BufferImageCopy{copy_region});

        barrier.old_layout = .transfer_dst_optimal;
        barrier.new_layout = .shader_read_only_optimal;
        barrier.src_access_mask = .{ .transfer_write_bit = true };
        barrier.dst_access_mask = .{ .shader_read_bit = true };
        barrier.image = self.dummy_image;

        const to_shader_read: [1]vk.ImageMemoryBarrier = .{barrier};
        self.dev.cmdPipelineBarrier(cmd, .{ .transfer_bit = true }, .{ .fragment_shader_bit = true }, .{}, null, null, &to_shader_read);

        if (locked) {
            try self.endSingleTimeCommandsLocked(cmd);
        } else {
            try self.endSingleTimeCommands(io, cmd);
        }
    }

    const dummy_view_info: vk.ImageViewCreateInfo = .{
        .flags = .{},
        .image = self.dummy_image,
        .view_type = .@"2d_array",
        .format = .r8g8b8a8_unorm,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 256,
        },
    };

    self.dummy_view = try self.dev.createImageView(&dummy_view_info, null);

    const sampler_info: vk.SamplerCreateInfo = .{
        .flags = .{},
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .nearest,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .mip_lod_bias = 0.0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1.0,
        .compare_enable = .false,
        .compare_op = .always,
        .min_lod = 0.0,
        .max_lod = 0.0,
        .border_color = .int_opaque_white,
        .unnormalized_coordinates = .false,
    };

    self.dummy_sampler = try self.dev.createSampler(&sampler_info, null);

    const texture_image_info_descriptor: vk.DescriptorImageInfo = .{
        .image_layout = .shader_read_only_optimal,
        .image_view = self.dummy_view,
        .sampler = self.dummy_sampler,
    };

    for (self.descriptor_sets_per_frame) |desc_set| {
        const writes: [1]vk.WriteDescriptorSet = .{.{
            .dst_set = desc_set,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&texture_image_info_descriptor),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }};
        self.dev.updateDescriptorSets(&writes, null);
    }
}

fn createPipeline(self: *VulkanRenderer) !void {
    const pc_range: vk.PushConstantRange = .{
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .offset = 0,
        .size = @sizeOf(PushConstants),
    };
    const layout_info: vk.PipelineLayoutCreateInfo = .{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&self.descriptor_set_layout),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&pc_range),
    };
    self.pipeline_layout = try self.dev.createPipelineLayout(&layout_info, null);
    self.pipeline = try self.createGraphicsPipeline(false, true);
}

fn createTransparentPipeline(self: *VulkanRenderer) !void {
    self.transparent_pipeline = try self.createGraphicsPipeline(true, false);
}

fn createGraphicsPipeline(self: *VulkanRenderer, blend_enable: bool, depth_write_enable: bool) !vk.Pipeline {
    const piasci: vk.PipelineInputAssemblyStateCreateInfo = .{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };
    const pvsci: vk.PipelineViewportStateCreateInfo = .{
        .viewport_count = 1,
        .p_viewports = null,
        .scissor_count = 1,
        .p_scissors = null,
    };
    const prsci: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = true },
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
    const pcbas: vk.PipelineColorBlendAttachmentState = .{
        .blend_enable = if (blend_enable) .true else .false,
        .src_color_blend_factor = .src_alpha,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .src_alpha,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };
    const pcbsci: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&pcbas),
        .blend_constants = .{ 0, 0, 0, 0 },
    };
    const dynstate: [2]vk.DynamicState = .{ .viewport, .scissor };
    const pdsci: vk.PipelineDynamicStateCreateInfo = .{
        .flags = .{},
        .dynamic_state_count = dynstate.len,
        .p_dynamic_states = &dynstate,
    };
    const depth_stencil_state: vk.PipelineDepthStencilStateCreateInfo = .{
        .flags = .{},
        .depth_test_enable = .true,
        .depth_write_enable = if (depth_write_enable) .true else .false,
        .depth_compare_op = .greater,
        .depth_bounds_test_enable = .false,
        .stencil_test_enable = .false,
        .front = undefined,
        .back = undefined,
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
    };
    const vert_shader_info: vk.ShaderModuleCreateInfo = .{
        .flags = .{},
        .code_size = vertex_shader_spv.len,
        .p_code = @ptrCast(@alignCast(vertex_shader_spv.ptr)),
    };
    const vert_shader_module = try self.dev.createShaderModule(&vert_shader_info, null);
    errdefer self.dev.destroyShaderModule(vert_shader_module, null);
    const frag_shader_info: vk.ShaderModuleCreateInfo = .{
        .flags = .{},
        .code_size = fragment_shader_spv.len,
        .p_code = @ptrCast(@alignCast(fragment_shader_spv.ptr)),
    };
    const frag_shader_module = try self.dev.createShaderModule(&frag_shader_info, null);
    errdefer self.dev.destroyShaderModule(frag_shader_module, null);
    const pssci: [2]vk.PipelineShaderStageCreateInfo = .{
        .{
            .flags = .{},
            .stage = .{ .vertex_bit = true },
            .module = vert_shader_module,
            .p_name = "main",
            .p_specialization_info = null,
        },
        .{
            .flags = .{},
            .stage = .{ .fragment_bit = true },
            .module = frag_shader_module,
            .p_name = "main",
            .p_specialization_info = null,
        },
    };
    const vertex_input_info: vk.PipelineVertexInputStateCreateInfo = .{
        .flags = .{},
        .vertex_binding_description_count = 0,
        .p_vertex_binding_descriptions = undefined,
        .vertex_attribute_description_count = 0,
        .p_vertex_attribute_descriptions = undefined,
    };
    const rendering_info: vk.PipelineRenderingCreateInfo = .{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = @ptrCast(&self.swapchain_format),
        .depth_attachment_format = self.depth_format,
        .stencil_attachment_format = .undefined,
    };
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
        .p_depth_stencil_state = &depth_stencil_state,
        .p_color_blend_state = &pcbsci,
        .p_dynamic_state = &pdsci,
        .layout = self.pipeline_layout,
        .render_pass = .null_handle,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };
    var pipeline: vk.Pipeline = undefined;
    if (self.dev.createGraphicsPipelines(.null_handle, &.{gpci}, null, (&pipeline)[0..1])) |res| {
        if (res != .success) return error.PipelineCreationFailed;
    } else |err| return err;
    self.dev.destroyShaderModule(vert_shader_module, null);
    self.dev.destroyShaderModule(frag_shader_module, null);
    return pipeline;
}

fn currentFrame(self: *VulkanRenderer) u32 {
    const num_frames = self.in_flight_fences.len;
    return if (num_frames > 0) @intCast(self.current_frame_idx.load(.monotonic) % num_frames) else 0;
}

fn waitFences(self: *VulkanRenderer, fences: []const vk.Fence) error{DrawFailed}!void {
    const result = self.dev.waitForFences(fences, .true, 2000000000) catch return error.DrawFailed;
    if (result != .success) return error.DrawFailed;
}

fn enqueueDeferredDeletion(self: *VulkanRenderer, io: std.Io, mesh: ChunkMeshBuffer) void {
    self.deferred_deletions_mutex.lockUncancelable(io);
    defer self.deferred_deletions_mutex.unlock(io);

    self.deferred_deletions.append(self.allocator, .{
        .mesh = mesh,
        .graphics_timeline_value = self.frame_number.load(.monotonic),
    }) catch |err| {
        std.log.err("enqueueDeferredDeletion: Out of memory appending: {any}", .{err});
    };
}

fn processDeletionQueue(self: *VulkanRenderer, io: std.Io) !void {
    self.deferred_deletions_mutex.lockUncancelable(io);
    defer self.deferred_deletions_mutex.unlock(io);

    if (self.deferred_deletions.items.len == 0) return;

    const current_graphics_val = try self.dev.getSemaphoreCounterValue(self.graphics_timeline_semaphore);

    var i: usize = 0;
    while (i < self.deferred_deletions.items.len) {
        const entry = self.deferred_deletions.items[i];
        if (current_graphics_val >= entry.graphics_timeline_value) {
            if (entry.mesh.buffer != .null_handle) self.dev.destroyBuffer(entry.mesh.buffer, null);
            self.device_allocator.free(io, entry.mesh.alloc_offset, entry.mesh.alloc_size);

            _ = self.deferred_deletions.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn beginSingleTimeCommands(self: *VulkanRenderer, io: std.Io) !vk.CommandBuffer {
    _ = io;
    const alloc_info: vk.CommandBufferAllocateInfo = .{
        .level = .primary,
        .command_pool = self.upload_command_pool,
        .command_buffer_count = 1,
    };
    var cmd: vk.CommandBuffer = undefined;
    try self.dev.allocateCommandBuffers(&alloc_info, @ptrCast(&cmd));
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
        .p_command_buffers = @ptrCast(&cmd),
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    };

    try self.dev.queueSubmit(self.graphics_queue, &.{submit_info}, .null_handle);

    try self.dev.queueWaitIdle(self.graphics_queue);
}

pub fn endSingleTimeCommands(self: *VulkanRenderer, io: std.Io, cmd: vk.CommandBuffer) !void {
    self.queue_mutex.lockUncancelable(io);
    defer self.queue_mutex.unlock(io);
    try self.endSingleTimeCommandsLocked(cmd);
}

pub fn present(self: *VulkanRenderer, io: std.Io) !void {
    const current_frame = self.currentFrame();

    const present_info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&self.render_complete_semaphores[current_frame]),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.swapchain),
        .p_image_indices = &.{self.current_swapchain_image_index},
        .p_results = null,
    };

    self.queue_mutex.lockUncancelable(io);
    defer self.queue_mutex.unlock(io);

    _ = try self.dev.queuePresentKHR(self.present_queue, &present_info);
}

fn vtableSetViewport(userdata: *anyopaque, viewport_pixels: @Vector(2, u32)) error{ViewportSetFailed}!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));
    self.viewport_pixels = viewport_pixels;
    if (viewport_pixels[0] != self.swapchain_extent.width or
        viewport_pixels[1] != self.swapchain_extent.height)
    {
        self.swapchain_extent = .{
            .width = viewport_pixels[0],
            .height = viewport_pixels[1],
        };
        self.swapchain_needs_recreate = true;
    }
}
fn vtableUpdateCameraDirection(userdata: *anyopaque, viewDir: @Vector(3, f32)) void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));
    // Convert viewDir (pitch, yaw, _) to a unit direction vector, matching OpenGL.
    self.camera_front[0] = @sin(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    self.camera_front[1] = @sin(std.math.degreesToRadians(viewDir[0]));
    self.camera_front[2] = @cos(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    self.camera_front = zm.Vec3f.norm(.{ .data = self.camera_front }).data;
}
fn vtableGetCameraFront(userdata: *anyopaque) @Vector(3, f32) {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));
    return self.camera_front;
}
fn destroyDummyResources(self: *VulkanRenderer) void {
    if (self.dummy_sampler != .null_handle) self.dev.destroySampler(self.dummy_sampler, null);
    if (self.dummy_view != .null_handle) self.dev.destroyImageView(self.dummy_view, null);
    if (self.dummy_image != .null_handle) self.dev.destroyImage(self.dummy_image, null);
    if (self.dummy_memory != .null_handle) self.dev.freeMemory(self.dummy_memory, null);
    self.dummy_sampler = .null_handle;
    self.dummy_view = .null_handle;
    self.dummy_image = .null_handle;
    self.dummy_memory = .null_handle;
}

fn vtableForEachChunk(userdata: *anyopaque, io: std.Io, callback_userdata: *anyopaque, callback: *const fn (*anyopaque, ChunkPos) void) std.Io.Cancelable!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));
    var it = self.meshes.iterator();
    defer it.deinit(io);
    while (try it.next(io)) |entry| {
        const chunk_pos = entry.key_ptr.*.toPos();
        it.pause(io);
        callback(callback_userdata, chunk_pos);
        try it.unpause(io);
    }
}

test "getDeletionQueueIndex" {
    var r: VulkanRenderer = undefined;
    var f2 = [_]vk.Fence{.null_handle} ** 2;
    var f3 = [_]vk.Fence{.null_handle} ** 3;
    var f5 = [_]vk.Fence{.null_handle} ** 5;
    r.current_frame_idx = .init(0);
    r.in_flight_fences = &f2;
    try std.testing.expectEqual(@as(u32, 0), r.getDeletionQueueIndex());
    var exp: u32 = 0;
    while (exp < 16) : (exp += 1) {
        r.current_frame_idx.store(exp, .monotonic);
        try std.testing.expectEqual(@as(u32, @intCast(@as(u64, exp) % 2)), r.getDeletionQueueIndex());
    }
    r.current_frame_idx = .init(8);
    r.in_flight_fences = &f3;
    try std.testing.expectEqual(@as(u32, 2), r.getDeletionQueueIndex());
    r.current_frame_idx = .init(100_000);
    r.in_flight_fences = &f2;
    try std.testing.expectEqual(@as(u32, 0), r.getDeletionQueueIndex());
    r.current_frame_idx.store(100_001, .monotonic);
    try std.testing.expectEqual(@as(u32, 1), r.getDeletionQueueIndex());
    r.current_frame_idx = .init(0);
    r.in_flight_fences = &f5;
    try std.testing.expectEqual(@as(u32, 0), r.getDeletionQueueIndex());
    r.current_frame_idx.store(7, .monotonic);
    try std.testing.expectEqual(@as(u32, 2), r.getDeletionQueueIndex());
    r.current_frame_idx.store(13, .monotonic);
    try std.testing.expectEqual(@as(u32, 3), r.getDeletionQueueIndex());
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
    try std.testing.expectEqual(@as(u32, 0), findMemoryTypeRaw(mem_props, 0b111, .{ .host_visible_bit = true, .host_coherent_bit = true }));
    mem_types[0] = .{ .property_flags = .{ .host_visible_bit = true, .host_coherent_bit = true }, .heap_index = 0 };
    mem_types[1] = .{ .property_flags = .{ .device_local_bit = true }, .heap_index = 1 };
    mem_props = .{ .memory_type_count = 2, .memory_types = mem_types, .memory_heap_count = 2, .memory_heaps = undefined };
    try std.testing.expectEqual(@as(u32, 1), findMemoryTypeRaw(mem_props, 0b11, .{ .device_local_bit = true }));
}

fn makeTestFrustum(eye: @Vector(3, f32), target: @Vector(3, f32), up: @Vector(3, f32), fov_deg: f32, aspect: f32, z_near: f32) Frustum {
    const P = makeInfReversedZProjRh(std.math.degreesToRadians(fov_deg), aspect, z_near);
    const V = zm.Mat4f.lookAtRH(.{ .data = eye }, .{ .data = target }, .{ .data = up });
    const pv = P.multiply(V);
    return Frustum.extractFrustumPlanes(.{
        pv.data[0][0], pv.data[0][1], pv.data[0][2], pv.data[0][3],
        pv.data[1][0], pv.data[1][1], pv.data[1][2], pv.data[1][3],
        pv.data[2][0], pv.data[2][1], pv.data[2][2], pv.data[2][3],
        pv.data[3][0], pv.data[3][1], pv.data[3][2], pv.data[3][3],
    });
}

test "cullChunk" {
    const frustum = makeTestFrustum(.{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 0 }, 90.0, 800.0 / 600.0, 0.01);
    try std.testing.expect(!cullChunk(&frustum, ChunkPos{ .level = 0, .position = .{ 0, 0, 0 } }, .{ 0, 0, 0 }));
}

test "ChunkData size" {
    try std.testing.expectEqual(@as(usize, 16), @alignOf(ChunkData));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(ChunkData));
}
