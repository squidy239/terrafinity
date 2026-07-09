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
const VulkanContext = @import("../../VulkanContext.zig").VulkanContext;

const ConcurrentHashMap = @import("../../libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const Mesher = @import("../../Mesher.zig");
const Renderer = @import("../../Renderer.zig");
const World = @import("../../world/World.zig");
const ChunkSize = World.ChunkSize;
const ChunkPos = World.ChunkPos;
const Frustum = @import("../opengl/Frustum.zig").Frustum;
const textures = @import("textures.zig");

const vertex_shader_spv: []const u8 = @embedFile("vert_spv");
const fragment_shader_spv: []const u8 = @embedFile("frag_spv");
const transparent_frag_spv: []const u8 = @embedFile("trans_frag_spv");
const composite_vert_spv: []const u8 = @embedFile("comp_vert_spv");
const composite_frag_spv: []const u8 = @embedFile("comp_frag_spv");

const VulkanBackingAllocator = @import("VulkanBackingAllocator.zig").VulkanBackingAllocator;
const MemoryPool = @import("VulkanBackingAllocator.zig").MemoryPool;

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
        const total_candidates = self.opaque_candidates + self.transparent_candidates;
        const total_culled = self.opaque_culled + self.transparent_culled;
        const total_drawn = self.opaque_drawn + self.transparent_drawn;

        const elapsed_f: f64 = @floatFromInt(self.elapsed_ns);
        const ms = elapsed_f / 1_000_000.0;

        const opaque_visible_pct = if (self.opaque_candidates > 0) @as(f64, @floatFromInt(self.opaque_drawn)) / @as(f64, @floatFromInt(self.opaque_candidates)) * 100.0 else 0.0;
        const transparent_visible_pct = if (self.transparent_candidates > 0) @as(f64, @floatFromInt(self.transparent_drawn)) / @as(f64, @floatFromInt(self.transparent_candidates)) * 100.0 else 0.0;

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
            inline .@"opaque", .transparent => |pos| pos,
        };
    }
};

const ChunkMeshBuffer = struct {
    buffer: vk.Buffer,
    alloc_offset: vk.DeviceSize,
    alloc_size: vk.DeviceSize,
    device_address: vk.DeviceAddress,
    face_count: u32,
    slice: []u8,
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
    graphics_timeline_value: u64,
};

const CommandPoolReservoir = struct {
    pools: []vk.CommandPool = &.{},
    cmds: []vk.CommandBuffer = &.{},
    used: []std.atomic.Value(bool) = &.{},

    pub const Borrowed = struct {
        pool: vk.CommandPool,
        cmd: vk.CommandBuffer,
    };

    pub fn init(self: *CommandPoolReservoir, dev: DeviceProxy, queue_family: u32, count: usize, allocator: std.mem.Allocator) !void {
        self.pools = try allocator.alloc(vk.CommandPool, count);
        errdefer allocator.free(self.pools);
        self.cmds = try allocator.alloc(vk.CommandBuffer, count);
        errdefer allocator.free(self.cmds);
        self.used = try allocator.alloc(std.atomic.Value(bool), count);
        errdefer allocator.free(self.used);

        for (self.used) |*u| {
            u.* = .init(false);
        }

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
            try dev.allocateCommandBuffers(&cmd_alloc_info, (&self.cmds[idx])[0..1]);
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

    pub fn tryBorrowPool(self: *CommandPoolReservoir) ?Borrowed {
        for (self.pools, 0..) |pool, i| {
            if (self.used[i].cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                return Borrowed{
                    .pool = pool,
                    .cmd = self.cmds[i],
                };
            }
        }
        return null;
    }

    pub fn returnPool(self: *CommandPoolReservoir, pool: vk.CommandPool) void {
        for (self.pools, 0..) |p, i| {
            if (p == pool) {
                self.used[i].store(false, .release);
                break;
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
};

fn findMemoryTypeRaw(mem_props: vk.PhysicalDeviceMemoryProperties, type_filter: u32, properties: vk.MemoryPropertyFlags) u32 {
    for (mem_props.memory_types[0..mem_props.memory_type_count], 0..) |mem_type, i| {
        if ((type_filter & (@as(u32, 1) << @as(u5, @intCast(i)))) != 0 and (mem_type.property_flags.toInt() & properties.toInt()) == properties.toInt()) {
            return @intCast(i);
        }
    }
    @panic("Failed to find suitable memory type");
}

fn cullChunk(frustum: *const Frustum, chunk_pos: ChunkPos, player_pos: @Vector(3, f64)) bool {
    const scale = ChunkPos.toScale(chunk_pos.level);
    const chunk_size_blocks: f64 = @floatCast(scale * @as(f32, ChunkSize));
    const chunk_pos_f: @Vector(3, f64) = @floatFromInt(chunk_pos.position);
    const chunk_world_pos = chunk_pos_f * @as(@Vector(3, f64), @splat(chunk_size_blocks));
    const relative_chunk_pos: @Vector(3, f32) = @floatCast(chunk_world_pos - player_pos);
    const chunk_size_vec: @Vector(3, f32) = @splat(@floatCast(chunk_size_blocks));
    return !frustum.boxInFrustum(.{ .max = relative_chunk_pos + chunk_size_vec, .min = relative_chunk_pos });
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

pub const VulkanRenderer = @This();

vk_ctx: *VulkanContext,

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
render_depth_sampled_view: vk.ImageView = .null_handle,
depth_format: vk.Format = .undefined,

oit_accum_image: vk.Image = .null_handle,
oit_accum_memory: vk.DeviceMemory = .null_handle,
oit_accum_view: vk.ImageView = .null_handle,
oit_reveal_image: vk.Image = .null_handle,
oit_reveal_memory: vk.DeviceMemory = .null_handle,
oit_reveal_view: vk.ImageView = .null_handle,
oit_sampler: vk.Sampler = .null_handle,
oit_composition_pipeline: vk.Pipeline = .null_handle,
oit_composition_layout: vk.PipelineLayout = .null_handle,
oit_descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
oit_descriptor_sets_per_frame: []vk.DescriptorSet = &.{},
oit_descriptor_pool: vk.DescriptorPool = .null_handle,

texture_manager: textures.TextureArrayManager = undefined,

image_acquired_semaphores: []vk.Semaphore = &.{},
render_complete_semaphores: []vk.Semaphore = &.{},
in_flight_fences: []vk.Fence = &.{},

descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
pipeline_layout: vk.PipelineLayout = .null_handle,
pipeline: vk.Pipeline = .null_handle,
transparent_pipeline: vk.Pipeline = .null_handle,
descriptor_pool: vk.DescriptorPool = .null_handle,
descriptor_sets_per_frame: []vk.DescriptorSet = &.{},

transfer_queue: vk.Queue = undefined,
transfer_queue_family_index: u32 = undefined,

transfer_semaphore: vk.Semaphore = .null_handle,
transfer_semaphore_value: std.atomic.Value(u64) = .init(0),
graphics_timeline_semaphore: vk.Semaphore = .null_handle,

meshes: ConcurrentHashMap(RenderBufferKey, ChunkMeshBuffer, std.hash_map.AutoContext(RenderBufferKey), 80, 32),

indirect_draw_buffers: []vk.Buffer = &.{},
indirect_draw_buffers_mapped: []?[*]vk.DrawIndirectCommand = &.{},
indirect_draw_offsets: []vk.DeviceSize = &.{},

chunk_data_buffers: []vk.Buffer = &.{},
chunk_data_buffers_mapped: []?[*]ChunkData = &.{},
chunk_data_offsets: []vk.DeviceSize = &.{},

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

camera_front: @Vector(3, f32) = .{ 0, 0, 1 },
viewport_pixels: @Vector(2, u32) = .{ 800, 600 },

render_options: *const RenderOptions,
render_options_lock: *std.Io.RwLock,

interface: Renderer,

queue_mutex: std.Io.Mutex = .init,
upload_mutex: std.Io.Mutex = .init,

retired_mutex: std.Io.Mutex = .init,
retire_mutex: std.Io.Mutex = .init,

init_time_ns: u64 = 0,
frame_stats: FrameDebugStats = .{},

pub const RenderOptions = Renderer.RenderOptions;

fn updateSwapchainFields(self: *VulkanRenderer) void {
    self.swapchain = self.vk_ctx.swapchain;
    self.swapchain_format = self.vk_ctx.swapchain_format;
    self.swapchain_images = self.vk_ctx.swapchain_images;
    self.swapchain_views = self.vk_ctx.swapchain_views;
    self.swapchain_extent = self.vk_ctx.swapchain_extent;
    self.cmd_buffers = self.vk_ctx.cmd_buffers;
    self.image_acquired_semaphores = self.vk_ctx.image_acquired_semaphores;
    self.render_complete_semaphores = self.vk_ctx.render_complete_semaphores;
    self.in_flight_fences = self.vk_ctx.in_flight_fences;
}

fn allocateIndirectBuffers(self: *VulkanRenderer, i: usize) !void {
    const chunk_data_slice = try self.cpu_to_gpu_gpa.allocator().alloc(ChunkData, self.draw_capacity);
    const indirect_draw_slice = try self.cpu_to_gpu_gpa.allocator().alloc(vk.DrawIndirectCommand, self.draw_capacity);

    const chunk_data_info = self.backing_allocator.getBufferAndOffset(chunk_data_slice.ptr);
    const indirect_draw_info = self.backing_allocator.getBufferAndOffset(indirect_draw_slice.ptr);

    self.chunk_data_buffers[i] = chunk_data_info.buffer;
    self.chunk_data_buffers_mapped[i] = chunk_data_slice.ptr;
    self.chunk_data_offsets[i] = chunk_data_info.offset;

    self.indirect_draw_buffers[i] = indirect_draw_info.buffer;
    self.indirect_draw_buffers_mapped[i] = indirect_draw_slice.ptr;
    self.indirect_draw_offsets[i] = indirect_draw_info.offset;
}

fn recreateSwapchainResourcesLocked(self: *VulkanRenderer, io: std.Io) !void {
    self.render_options_lock.lockSharedUncancelable(io);
    const gamma_correction = self.render_options.gamma_correction;
    const present_mode = self.render_options.present_mode;
    self.render_options_lock.unlockShared(io);
    self.vk_ctx.present_mode = present_mode;
    try self.vk_ctx.createSwapchainLocked(io, gamma_correction);

    self.destroyRendererSwapchainResources();

    self.updateSwapchainFields();

    const actual_extent = self.swapchain_extent;
    self.viewport_pixels = .{ actual_extent.width, actual_extent.height };

    try self.createRenderTargets(actual_extent);

    const num_swapchain_images = self.swapchain_images.len;
    self.indirect_draw_buffers = try self.allocator.alloc(vk.Buffer, num_swapchain_images);
    self.indirect_draw_buffers_mapped = try self.allocator.alloc(?[*]vk.DrawIndirectCommand, num_swapchain_images);
    self.indirect_draw_offsets = try self.allocator.alloc(vk.DeviceSize, num_swapchain_images);
    self.chunk_data_buffers = try self.allocator.alloc(vk.Buffer, num_swapchain_images);
    self.chunk_data_buffers_mapped = try self.allocator.alloc(?[*]ChunkData, num_swapchain_images);
    self.chunk_data_offsets = try self.allocator.alloc(vk.DeviceSize, num_swapchain_images);

    @memset(self.indirect_draw_buffers_mapped, null);
    @memset(self.chunk_data_buffers_mapped, null);

    for (0..num_swapchain_images) |i| {
        try self.allocateIndirectBuffers(i);
    }

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

    if (self.descriptor_set_layout != .null_handle) {
        try self.createDescriptorPoolAndSets();
        if (self.texture_manager.texture_view != .null_handle) {
            self.texture_manager.rebindDescriptorSets();
        }
    }

    if (self.oit_descriptor_set_layout != .null_handle) {
        self.destroyOitPipelinesAndDescriptors();
        try self.createOitPipelinesAndDescriptors();

        if (self.oit_descriptor_pool != .null_handle) {
            self.dev.destroyDescriptorPool(self.oit_descriptor_pool, null);
            self.oit_descriptor_pool = .null_handle;
        }
        if (self.oit_descriptor_sets_per_frame.len > 0) {
            self.allocator.free(self.oit_descriptor_sets_per_frame);
            self.oit_descriptor_sets_per_frame = &.{};
        }
        try self.createOitDescriptorPoolAndSets();
        self.updateOitDescriptorSets();
        self.updateDepthDescriptorSets();
    }
}

fn destroyRendererSwapchainResources(self: *VulkanRenderer) void {
    destroyIfValidImageView(self.dev, &self.render_color_view);
    destroyIfValidImageView(self.dev, &self.render_depth_view);
    destroyIfValidImageView(self.dev, &self.render_depth_sampled_view);
    destroyIfValidImage(self.dev, &self.render_color_image, &self.render_color_memory);
    destroyIfValidImage(self.dev, &self.render_depth_image, &self.render_depth_memory);

    for (self.indirect_draw_buffers_mapped) |maybe_ptr| {
        if (maybe_ptr) |ptr| self.cpu_to_gpu_gpa.allocator().free(ptr[0..self.draw_capacity]);
    }
    for (self.chunk_data_buffers_mapped) |maybe_ptr| {
        if (maybe_ptr) |ptr| self.cpu_to_gpu_gpa.allocator().free(ptr[0..self.draw_capacity]);
    }

    self.allocator.free(self.indirect_draw_buffers);
    self.allocator.free(self.indirect_draw_buffers_mapped);
    self.allocator.free(self.indirect_draw_offsets);
    self.indirect_draw_buffers = &.{};
    self.indirect_draw_buffers_mapped = &.{};
    self.indirect_draw_offsets = &.{};

    self.allocator.free(self.chunk_data_buffers);
    self.allocator.free(self.chunk_data_buffers_mapped);
    self.allocator.free(self.chunk_data_offsets);
    self.chunk_data_buffers = &.{};
    self.chunk_data_buffers_mapped = &.{};
    self.chunk_data_offsets = &.{};

    if (self.descriptor_pool != .null_handle) {
        self.dev.destroyDescriptorPool(self.descriptor_pool, null);
        self.descriptor_pool = .null_handle;
    }
    self.allocator.free(self.descriptor_sets_per_frame);
    self.descriptor_sets_per_frame = &.{};

    self.destroyOitResources();
}

fn recreateSwapchain(self: *VulkanRenderer, io: std.Io) !void {
    self.queue_mutex.lockUncancelable(io);
    defer self.queue_mutex.unlock(io);
    try self.recreateSwapchainResourcesLocked(io);
}

pub fn init(io: std.Io, allocator: std.mem.Allocator, vk_ctx: *VulkanContext, render_options: *const RenderOptions, render_options_lock: *std.Io.RwLock) !*VulkanRenderer {
    std.log.info("VulkanRenderer.init: Starting renderer-specific Vulkan initialization...", .{});

    const self = try allocator.create(VulkanRenderer);
    errdefer allocator.destroy(self);

    self.* = .{
        .vk_ctx = vk_ctx,
        .allocator = allocator,
        .window = vk_ctx.window,
        .surface = vk_ctx.surface,
        .vkb = vk_ctx.vkb,
        .instance_handle = vk_ctx.instance_handle,
        .instance_wrapper = vk_ctx.instance_wrapper,
        .instance = vk_ctx.instance,
        .pdev = vk_ctx.pdev,
        .props = vk_ctx.props,
        .mem_props = vk_ctx.mem_props,
        .dev_handle = vk_ctx.dev_handle,
        .dev_wrapper = vk_ctx.dev_wrapper,
        .dev = vk_ctx.dev,
        .graphics_queue = vk_ctx.graphics_queue,
        .present_queue = vk_ctx.present_queue,
        .queue_family_index = vk_ctx.queue_family_index,
        .present_queue_family_index = vk_ctx.present_queue_family_index,
        .command_pool = vk_ctx.command_pool,
        .upload_command_pool = vk_ctx.upload_command_pool,
        .render_options = render_options,
        .render_options_lock = render_options_lock,
        .meshes = undefined,
        .interface = undefined,
    };

    self.init_time_ns = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    self.retired_meshes = .empty;

    self.max_draw_indirect_count = if (self.props.limits.max_draw_indirect_count > 0) self.props.limits.max_draw_indirect_count else 65_535;

    self.transfer_queue_family_index = vk_ctx.transfer_queue_family_index;
    self.transfer_queue = vk_ctx.transfer_queue;
    self.transfer_semaphore = vk_ctx.transfer_semaphore;
    self.graphics_timeline_semaphore = vk_ctx.graphics_timeline_semaphore;

    self.backing_allocator = VulkanBackingAllocator.init(self.dev, self.mem_props, io, allocator);
    errdefer self.backing_allocator.deinit();

    self.gpu_only_gpa = .init;
    self.gpu_only_gpa.backing_allocator = self.backing_allocator.allocator(.gpu_only);
    errdefer _ = self.gpu_only_gpa.deinit();

    self.cpu_to_gpu_gpa = .init;
    self.cpu_to_gpu_gpa.backing_allocator = self.backing_allocator.allocator(.cpu_to_gpu);
    errdefer _ = self.cpu_to_gpu_gpa.deinit();

    try self.recreateSwapchainResourcesLocked(io);

    try self.createDescriptorSetLayout();
    try self.createDescriptorPoolAndSets();

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

    try self.createPipeline();
    try self.createTransparentPipeline();
    try self.createOitPipelinesAndDescriptors();
    try self.createOitDescriptorPoolAndSets();
    self.updateOitDescriptorSets();
    self.updateDepthDescriptorSets();

    self.meshes = .init;

    try self.pool_reservoir.init(self.dev, self.transfer_queue_family_index, 512, allocator);
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
        self.queue_mutex.lockUncancelable(io);
        defer self.queue_mutex.unlock(io);
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

    destroyIfValidPipeline(self.dev, &self.pipeline);
    destroyIfValidPipeline(self.dev, &self.transparent_pipeline);
    destroyIfValidPipelineLayout(self.dev, &self.pipeline_layout);
    destroyIfValidDescriptorSetLayout(self.dev, &self.descriptor_set_layout);

    self.pool_reservoir.deinit(self.dev, self.allocator);
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
    errdefer self.pool_reservoir.returnPool(pool);

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
        self.queue_mutex.lockUncancelable(io);
        zone_queue.end();
        defer self.queue_mutex.unlock(io);

        const next_val = self.transfer_semaphore_value.fetchAdd(1, .monotonic) + 1;

        var cb_submit_infos: [batch_size]vk.CommandBufferSubmitInfo = undefined;
        for (cb_submit_infos[0..count], self.submission_batch.cmds[0..count]) |*info, cmd| {
            info.* = .{
                .command_buffer = cmd,
                .device_mask = 0,
            };
        }

        const semaphore_submit_info: vk.SemaphoreSubmitInfo = .{
            .semaphore = self.transfer_semaphore,
            .value = next_val,
            .stage_mask = .{ .all_transfer_bit = true },
            .device_index = 0,
        };

        const submit_info: vk.SubmitInfo2 = .{
            .flags = .{},
            .wait_semaphore_info_count = 0,
            .p_wait_semaphore_infos = null,
            .command_buffer_info_count = @intCast(count),
            .p_command_buffer_infos = cb_submit_infos[0..count].ptr,
            .signal_semaphore_info_count = 1,
            .p_signal_semaphore_infos = (&semaphore_submit_info)[0..1],
        };

        try self.dev.queueSubmit2(self.transfer_queue, &[_]vk.SubmitInfo2{submit_info}, .null_handle);
        break :blk next_val;
    };

    for (
        self.submission_batch.chunk_positions[0..count],
        self.submission_batch.pools[0..count],
        self.submission_batch.opaque_meshes[0..count],
        self.submission_batch.transparent_meshes[0..count],
    ) |chunk_pos, pool, opaque_res, transparent_res| {
        try self.pushPendingUpload(io, .{
            .chunk_pos = chunk_pos,
            .timeline_value = next_val,
            .pool = pool,
            .opaque_mesh = if (opaque_res) |r| r.mesh else null,
            .transparent_mesh = if (transparent_res) |r| r.mesh else null,
            .opaque_staging_slice = if (opaque_res) |r| r.staging_slice else null,
            .transparent_staging_slice = if (transparent_res) |r| r.staging_slice else null,
        });
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
        self.pool_reservoir.returnPool(pending.pool);
    }
}

fn enqueueRetiredMesh(self: *VulkanRenderer, io: std.Io, mesh: ChunkMeshBuffer) !void {
    self.retired_mutex.lockUncancelable(io);
    defer self.retired_mutex.unlock(io);

    try self.retired_meshes.append(self.allocator, .{
        .mesh = mesh,
        .graphics_timeline_value = self.vk_ctx.frame_number.load(.monotonic),
    });
}

fn retireCompletedUploads(self: *VulkanRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "retireCompletedUploads" });
    defer zone.end();

    self.retire_mutex.lockUncancelable(io);
    defer self.retire_mutex.unlock(io);

    const current_transfer_val = try self.dev.getSemaphoreCounterValue(self.transfer_semaphore);

    while (true) {
        const pending = if (self.peeked_upload) |p| p else blk: {
            var buf: PendingChunkUpload = undefined;
            const got = try self.pending_uploads_queue.get(io, (&buf)[0..1], 0);
            if (got == 0) return; // Queue is empty, nothing to retire
            break :blk buf;
        };

        if (current_transfer_val >= pending.timeline_value) {
            inline for (.{
                .{ .mesh = pending.opaque_mesh, .tag = .@"opaque" },
                .{ .mesh = pending.transparent_mesh, .tag = .transparent },
            }) |item| {
                const key = @unionInit(RenderBufferKey, @tagName(item.tag), pending.chunk_pos);
                if (item.mesh) |new_mesh| {
                    const existing = try self.meshes.fetchPut(io, self.allocator, key, new_mesh);
                    if (existing) |old_mesh| {
                        try self.enqueueRetiredMesh(io, old_mesh);
                    }
                } else {
                    const existing = self.meshes.fetchRemove(io, key);
                    if (existing) |old_mesh| {
                        try self.enqueueRetiredMesh(io, old_mesh);
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

    const staging_info = self.backing_allocator.getBufferAndOffset(staging_slice.ptr);

    const slice = try self.gpu_only_gpa.allocator().alloc(u8, buffer_size);
    errdefer self.gpu_only_gpa.allocator().free(slice);

    const buf_info = self.backing_allocator.getBufferAndOffset(slice.ptr);
    const device_address = self.backing_allocator.getDeviceAddress(slice.ptr);

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
        .dst_access_mask = .{ .transfer_write_bit = true },
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

inline fn setViewportAndScissor(self: *const VulkanRenderer, cmd: vk.CommandBuffer) void {
    self.dev.cmdSetViewport(cmd, 0, &[_]vk.Viewport{.{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(self.swapchain_extent.width),
        .height = @floatFromInt(self.swapchain_extent.height),
        .min_depth = 0.0,
        .max_depth = 1.0,
    }});
    self.dev.cmdSetScissor(cmd, 0, &[_]vk.Rect2D{.{
        .offset = .{ .x = 0, .y = 0 },
        .extent = self.swapchain_extent,
    }});
}

inline fn makeImageBarrier(
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_access: vk.AccessFlags,
    dst_access: vk.AccessFlags,
    aspect: vk.ImageAspectFlags,
) vk.ImageMemoryBarrier {
    return .{
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
        .src_access_mask = src_access,
        .dst_access_mask = dst_access,
    };
}

inline fn cmdImageBarrier(
    cmd: vk.CommandBuffer,
    dev: DeviceProxy,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_access: vk.AccessFlags,
    dst_access: vk.AccessFlags,
    aspect: vk.ImageAspectFlags,
    src_stage: vk.PipelineStageFlags,
    dst_stage: vk.PipelineStageFlags,
) void {
    const barrier = makeImageBarrier(image, old_layout, new_layout, src_access, dst_access, aspect);
    dev.cmdPipelineBarrier(cmd, src_stage, dst_stage, .{}, null, null, &.{barrier});
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

inline fn destroyIfValidCommandPool(dev: DeviceProxy, pool: *vk.CommandPool) void {
    if (pool.* != .null_handle) {
        dev.destroyCommandPool(pool.*, null);
        pool.* = .null_handle;
    }
}

inline fn destroyIfValidSemaphore(dev: DeviceProxy, sem: *vk.Semaphore) void {
    if (sem.* != .null_handle) {
        dev.destroySemaphore(sem.*, null);
        sem.* = .null_handle;
    }
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
        .store_op = if (load_op == .load) .dont_care else .store,
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

fn createImageWithMemory(self: *VulkanRenderer, extent: vk.Extent2D, format: vk.Format, usage: vk.ImageUsageFlags, aspect: vk.ImageAspectFlags) !struct { image: vk.Image, memory: vk.DeviceMemory, view: vk.ImageView } {
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
    const image = try self.dev.createImage(&image_info, null);
    errdefer self.dev.destroyImage(image, null);

    const mem_reqs = self.dev.getImageMemoryRequirements(image);
    const alloc_info: vk.MemoryAllocateInfo = .{
        .allocation_size = mem_reqs.size,
        .memory_type_index = self.findMemoryType(mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    };
    const memory = try self.dev.allocateMemory(&alloc_info, null);
    errdefer self.dev.freeMemory(memory, null);
    try self.dev.bindImageMemory(image, memory, 0);

    const view = try self.dev.createImageView(&imageViewCreateInfo(image, format, aspect), null);
    return .{ .image = image, .memory = memory, .view = view };
}

pub fn draw(self: *VulkanRenderer, io: std.Io, view_pos: @Vector(3, f64)) !void {
    const c = tracy.Zone.begin(.{ .src = @src() });
    defer c.end();

    try self.processPendingUploads(io);
    try self.processRetiredMeshes(io);

    var current_frame = self.currentFrame();

    const fence_wait: vk.Fence = self.in_flight_fences[current_frame];
    try self.waitFences((&fence_wait)[0..1]);

    const fence_reset: vk.Fence = self.in_flight_fences[current_frame];
    try self.dev.resetFences((&fence_reset)[0..1]);

    if (self.swapchain_needs_recreate or self.vk_ctx.swapchain_needs_recreate) {
        self.swapchain_needs_recreate = false;
        self.vk_ctx.swapchain_needs_recreate = false;
        {
            const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "draw_recreateSwapchain_lock" });
            self.queue_mutex.lockUncancelable(io);
            zone_lock.end();
            defer self.queue_mutex.unlock(io);
            try self.dev.deviceWaitIdle();
            try self.recreateSwapchainResourcesLocked(io);
        }
        current_frame = self.currentFrame();
        try self.dev.resetFences(&.{self.in_flight_fences[current_frame]});
    }

    const acquired = blk: {
        const zone_acq = tracy.Zone.begin(.{ .src = @src(), .name = "draw_acquireSwapchainImage" });
        defer zone_acq.end();
        break :blk self.vk_ctx.acquireSwapchainImage(current_frame) catch |err| switch (err) {
            error.OutOfDate => {
                try self.recreateSwapchain(io);
                const cf = self.currentFrame();
                try self.dev.resetFences(&.{self.in_flight_fences[cf]});
                break :blk try self.vk_ctx.acquireSwapchainImage(cf);
            },
            else => return err,
        };
    };
    self.updateSwapchainFields();
    const image_index = acquired.image_index;
    current_frame = acquired.frame;

    self.vk_ctx.current_swapchain_image_index = image_index;

    const cmd_buffer = self.cmd_buffers[current_frame];

    const aspect = @as(f32, @floatFromInt(self.viewport_pixels[0])) / @as(f32, @floatFromInt(self.viewport_pixels[1]));

    {
        const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "draw_lock_render_options" });
        self.render_options_lock.lockSharedUncancelable(io);
        zone_lock.end();
    }
    const fov = std.math.degreesToRadians(self.render_options.fov);
    const day_length_sec = self.render_options.day_length_sec;
    self.render_options_lock.unlockShared(io);

    // Pure-rotation view matrix at origin — matches OpenGL convention.
    // The vertex shader already applies the translation via relative_position = chunk_pos - player_pos,
    // so including it in the view matrix would cause double-translation, putting everything off-screen.
    const up_vec: zm.vec.Vec3f = .{ .data = [3]f32{ camera_up[0], camera_up[1], camera_up[2] } };

    const view = zm.matrix.Mat4f.lookAtRH(
        .{ .data = @Vector(3, f32){ 0, 0, 0 } },
        .{ .data = self.camera_front },
        up_vec,
    );

    const projection = makeInfReversedZProjRh(fov, aspect, near_plane);
    const projview: @Vector(16, f32) = @bitCast(projection.multiply(view).data);

    const blueSky = @Vector(4, f32){ 0.0, 0.4, 0.8, 1.0 };
    const greySky = @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 };
    const skyColor = std.math.lerp(blueSky, greySky, @as(@Vector(4, f32), @splat(@floatCast(@min(1.0, @max(0.0, view_pos[1] / sky_height))))));

    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const now_ns_f = @as(f64, @floatFromInt(now_ns));
    const sun_angle = @rem(now_ns_f / ((@as(f64, @max(0.001, day_length_sec)) * std.time.ns_per_s) / degrees_per_circle), degrees_per_circle);
    const sun_rot_mat = zm.Mat4f.rotationRH(.{ .data = @Vector(3, f32){ 1.0, 0.0, 0.0 } }, @floatCast(std.math.degreesToRadians(sun_angle)));
    const sun_dir: @Vector(3, f32) = .{ sun_rot_mat.data[1][0], sun_rot_mat.data[1][1], sun_rot_mat.data[1][2] };

    const elapsed_sec = @as(f32, @floatFromInt(now_ns -| self.init_time_ns)) / std.time.ns_per_s;

    const total_meshes = self.meshes.count(io);
    if (total_meshes > self.draw_capacity) {
        try self.growDrawCapacity(io, @intCast(total_meshes));
    }

    const begin_info: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };
    try self.dev.beginCommandBuffer(cmd_buffer, &begin_info);

    const color_attachment = renderingAttachmentColor(self.render_color_view, .clear, .{ skyColor[0], skyColor[1], skyColor[2], skyColor[3] });
    const depth_attachment = renderingAttachmentDepth(self.render_depth_view, .depth_stencil_attachment_optimal, .clear);

    self.dev.cmdBeginRendering(cmd_buffer, &renderingInfo(self.swapchain_extent, &.{color_attachment}, &depth_attachment));

    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.pipeline);

    self.setViewportAndScissor(cmd_buffer);

    self.updateFrameDescriptorSet(current_frame);

    const desc_set: vk.DescriptorSet = self.descriptor_sets_per_frame[current_frame];
    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.pipeline_layout, 0, (&desc_set)[0..1], null);

    var pc: PushConstants = .{
        .projview = @splat(0),
        .sun_dir = sun_dir,
        .time = elapsed_sec,
    };

    inline for (0..4) |row| {
        inline for (0..4) |col| {
            pc.projview[row * 4 + col] = @as([4][4]f32, @bitCast(projview))[col][row];
        }
    }

    self.dev.cmdPushConstants(cmd_buffer, self.pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(PushConstants), &pc);

    const frustum = Frustum.extractFrustumPlanes(projview);

    const depth_aspect_mask: vk.ImageAspectFlags = if (self.depthHasStencil()) .{ .depth_bit = true, .stencil_bit = true } else .{ .depth_bit = true };

    const frame_start_ns = std.Io.Timestamp.now(io, .real).nanoseconds;

    const opaque_draw_count = try self.drawChunksReal(io, cmd_buffer, current_frame, view_pos, frustum, false, 0);

    self.dev.cmdEndRendering(cmd_buffer);
    cmdImageBarrier(cmd_buffer, self.dev, self.render_depth_image, .depth_stencil_attachment_optimal, .depth_stencil_read_only_optimal, .{ .depth_stencil_attachment_write_bit = true }, .{ .depth_stencil_attachment_read_bit = true }, depth_aspect_mask, .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true }, .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true });

    const oit_accum_attachment = renderingAttachmentColor(self.oit_accum_view, .clear, .{ 0.0, 0.0, 0.0, 1.0 });
    const oit_reveal_attachment = renderingAttachmentColor(self.oit_reveal_view, .clear, .{ 0.0, 0.0, 0.0, 0.0 });
    const oit_depth_attachment = renderingAttachmentDepth(self.render_depth_view, .depth_stencil_read_only_optimal, .load);
    self.dev.cmdBeginRendering(cmd_buffer, &renderingInfo(self.swapchain_extent, &.{ oit_accum_attachment, oit_reveal_attachment }, &oit_depth_attachment));

    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.transparent_pipeline);
    self.setViewportAndScissor(cmd_buffer);

    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.pipeline_layout, 0, (&desc_set)[0..1], null);
    self.dev.cmdPushConstants(cmd_buffer, self.pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(PushConstants), &pc);

    _ = try self.drawChunksReal(io, cmd_buffer, current_frame, view_pos, frustum, true, opaque_draw_count);

    self.dev.cmdEndRendering(cmd_buffer);

    const frame_end_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const frame_elapsed_ns: u64 = @intCast(@max(0, frame_end_ns - frame_start_ns));

    const frame_num = self.vk_ctx.frame_number.load(.monotonic) + 1;
    self.vk_ctx.frame_number.store(frame_num, .monotonic);
    self.frame_stats.frame_number = frame_num;
    self.frame_stats.total_meshes = @intCast(self.meshes.count(io));
    self.frame_stats.player_pos = view_pos;
    self.frame_stats.camera_front = self.camera_front;
    self.frame_stats.elapsed_ns = frame_elapsed_ns;

    if (frame_num % 60 == 0) {
        self.frame_stats.log();
    }

    const pre_comp_barriers: [5]vk.ImageMemoryBarrier = .{
        makeImageBarrier(self.render_color_image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_write_bit = true }, .{ .shader_read_bit = true }, .{ .color_bit = true }),
        makeImageBarrier(self.oit_accum_image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_write_bit = true }, .{ .shader_read_bit = true }, .{ .color_bit = true }),
        makeImageBarrier(self.oit_reveal_image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_write_bit = true }, .{ .shader_read_bit = true }, .{ .color_bit = true }),
        makeImageBarrier(self.swapchain_images[image_index], .undefined, .color_attachment_optimal, .{}, .{ .color_attachment_write_bit = true }, .{ .color_bit = true }),
        makeImageBarrier(self.render_depth_image, .depth_stencil_read_only_optimal, .depth_stencil_attachment_optimal, .{ .depth_stencil_attachment_read_bit = true }, .{ .depth_stencil_attachment_write_bit = true }, depth_aspect_mask),
    };
    self.dev.cmdPipelineBarrier(
        cmd_buffer,
        .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .{ .color_attachment_output_bit = true, .fragment_shader_bit = true, .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .{},
        null,
        null,
        &pre_comp_barriers,
    );

    const swapchain_attachment = renderingAttachmentColor(self.swapchain_views[image_index], .dont_care, .{ 0.0, 0.0, 0.0, 0.0 });
    self.dev.cmdBeginRendering(cmd_buffer, &renderingInfo(self.swapchain_extent, &.{swapchain_attachment}, null));

    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.oit_composition_pipeline);
    self.setViewportAndScissor(cmd_buffer);

    const oit_desc_set: vk.DescriptorSet = self.oit_descriptor_sets_per_frame[current_frame];
    self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.oit_composition_layout, 0, (&oit_desc_set)[0..1], null);
    self.dev.cmdDraw(cmd_buffer, 3, 1, 0, 0);

    self.dev.cmdEndRendering(cmd_buffer);

    const post_comp_barriers: [4]vk.ImageMemoryBarrier = .{
        makeImageBarrier(self.swapchain_images[image_index], .color_attachment_optimal, .present_src_khr, .{ .color_attachment_write_bit = true }, .{ .color_attachment_read_bit = true }, .{ .color_bit = true }),
        makeImageBarrier(self.render_color_image, .shader_read_only_optimal, .color_attachment_optimal, .{ .shader_read_bit = true }, .{ .color_attachment_write_bit = true }, .{ .color_bit = true }),
        makeImageBarrier(self.oit_accum_image, .shader_read_only_optimal, .color_attachment_optimal, .{ .shader_read_bit = true }, .{ .color_attachment_write_bit = true }, .{ .color_bit = true }),
        makeImageBarrier(self.oit_reveal_image, .shader_read_only_optimal, .color_attachment_optimal, .{ .shader_read_bit = true }, .{ .color_attachment_write_bit = true }, .{ .color_bit = true }),
    };
    self.dev.cmdPipelineBarrier(
        cmd_buffer,
        .{ .color_attachment_output_bit = true, .fragment_shader_bit = true },
        .{ .color_attachment_output_bit = true },
        .{},
        null,
        null,
        &post_comp_barriers,
    );

    try self.dev.endCommandBuffer(cmd_buffer);

    try self.vk_ctx.submitFrame(io, current_frame, cmd_buffer);
    try self.vk_ctx.presentSwapchainImage(io, current_frame, image_index);
}

fn vtableDrawChunks(user_data: *Renderer.Implementation, io: std.Io, view_pos: @Vector(3, f64)) (std.Io.Cancelable || error{DrawFailed})!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    self.draw(io, view_pos) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.DrawFailed,
    };
}

fn drawChunksReal(self: *VulkanRenderer, io: std.Io, cmd_buffer: vk.CommandBuffer, current_frame: u32, player_pos: @Vector(3, f64), frustum: Frustum, is_transparent: bool, write_offset: u32) !u32 {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "drawChunksReal" });
    defer zone.end();

    const frame_idx = current_frame % @as(u32, @intCast(self.indirect_draw_buffers_mapped.len));
    var indirect_cmds = self.indirect_draw_buffers_mapped[frame_idx].?;
    var chunk_data = self.chunk_data_buffers_mapped[frame_idx].?;

    var draw_count: u32 = 0;
    var candidates: u32 = 0;
    var culled: u32 = 0;

    var it = self.meshes.iterator();
    defer it.deinit(io);
    while (try it.next(io)) |entry| {
        const key = entry.key_ptr.*;
        if (is_transparent != (key == .transparent)) continue;

        candidates += 1;
        const chunk_pos = key.toPos();

        if (!cullChunk(&frustum, chunk_pos, player_pos)) {
            const mesh = entry.value_ptr;

            const ratio: @Vector(3, f64) = @splat(@floatCast(ChunkPos.levelToBlockRatioFloat(chunk_pos.level)));
            const chunk_blockpos = @as(@Vector(3, f64), @floatFromInt(chunk_pos.position)) * ratio;
            const relative_blockpos = chunk_blockpos - player_pos;

            const write_idx = write_offset + draw_count;
            if (write_idx >= self.draw_capacity) {
                self.growDrawCapacity(io, write_idx + 1) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.DrawFailed,
                };
                indirect_cmds = self.indirect_draw_buffers_mapped[frame_idx].?;
                chunk_data = self.chunk_data_buffers_mapped[frame_idx].?;
            }

            chunk_data[write_idx] = .{
                .absolute_position = @bitCast(@as(@Vector(3, f32), @floatCast(chunk_blockpos))),
                .relative_position = @bitCast(@as(@Vector(3, f32), @floatCast(relative_blockpos))),
                .scale = ChunkPos.toScale(chunk_pos.level),
                .address = mesh.device_address,
            };

            indirect_cmds[write_idx] = .{
                .vertex_count = mesh.face_count * 6,
                .instance_count = 1,
                .first_vertex = 0,
                .first_instance = write_offset + draw_count,
            };

            draw_count += 1;
            if (write_offset + draw_count >= self.max_draw_indirect_count) break;
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

    const byte_offset: vk.DeviceSize = self.indirect_draw_offsets[frame_idx] + @as(vk.DeviceSize, @intCast(write_offset * @sizeOf(vk.DrawIndirectCommand)));
    self.dev.cmdDrawIndirect(cmd_buffer, self.indirect_draw_buffers[frame_idx], byte_offset, draw_count, @sizeOf(vk.DrawIndirectCommand));

    return draw_count;
}

fn updateFrameDescriptorSet(self: *VulkanRenderer, frame_idx: u32) void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "updateFrameDescriptorSet" });
    defer zone.end();

    const buffer_info: vk.DescriptorBufferInfo = .{
        .buffer = self.chunk_data_buffers[frame_idx],
        .offset = self.chunk_data_offsets[frame_idx],
        .range = self.draw_capacity * @sizeOf(ChunkData),
    };

    const chunk_data_write: vk.WriteDescriptorSet = .{
        .dst_set = self.descriptor_sets_per_frame[frame_idx],
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .storage_buffer,
        .p_image_info = undefined,
        .p_buffer_info = (&buffer_info)[0..1],
        .p_texel_buffer_view = undefined,
    };

    self.dev.updateDescriptorSets(&[_]vk.WriteDescriptorSet{chunk_data_write}, null);
}

fn growDrawCapacity(self: *VulkanRenderer, io: std.Io, min_capacity: u32) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "growDrawCapacity" });
    defer zone.end();

    if (min_capacity <= self.draw_capacity) return;

    var new_capacity = self.draw_capacity;
    while (new_capacity < min_capacity) {
        new_capacity *= 2;
    }

    std.log.info("VulkanRenderer: Growing draw capacity from {d} to {d} for all frames...", .{ self.draw_capacity, new_capacity });

    self.queue_mutex.lockUncancelable(io);
    defer self.queue_mutex.unlock(io);
    try self.dev.deviceWaitIdle();

    const old_draw_capacity = self.draw_capacity;
    self.draw_capacity = new_capacity;

    for (self.indirect_draw_buffers_mapped, 0..) |_, i| {
        const old_chunk_data_mapped = self.chunk_data_buffers_mapped[i].?;
        const old_indirect_mapped = self.indirect_draw_buffers_mapped[i].?;

        const chunk_data_slice = try self.cpu_to_gpu_gpa.allocator().alloc(ChunkData, new_capacity);
        const indirect_draw_slice = try self.cpu_to_gpu_gpa.allocator().alloc(vk.DrawIndirectCommand, new_capacity);

        if (old_draw_capacity > 0) {
            const old_chunk_slice = old_chunk_data_mapped[0..old_draw_capacity];
            const old_indirect_slice = old_indirect_mapped[0..old_draw_capacity];
            @memcpy(chunk_data_slice[0..old_draw_capacity], old_chunk_slice);
            @memcpy(indirect_draw_slice[0..old_draw_capacity], old_indirect_slice);
        }

        self.cpu_to_gpu_gpa.allocator().free(old_chunk_data_mapped[0..old_draw_capacity]);
        self.cpu_to_gpu_gpa.allocator().free(old_indirect_mapped[0..old_draw_capacity]);

        const chunk_data_info = self.backing_allocator.getBufferAndOffset(chunk_data_slice.ptr);
        const indirect_draw_info = self.backing_allocator.getBufferAndOffset(indirect_draw_slice.ptr);

        self.chunk_data_buffers[i] = chunk_data_info.buffer;
        self.chunk_data_buffers_mapped[i] = chunk_data_slice.ptr;
        self.chunk_data_offsets[i] = chunk_data_info.offset;

        self.indirect_draw_buffers[i] = indirect_draw_info.buffer;
        self.indirect_draw_buffers_mapped[i] = indirect_draw_slice.ptr;
        self.indirect_draw_offsets[i] = indirect_draw_info.offset;

        self.updateFrameDescriptorSet(@intCast(i));
    }
}

pub fn findMemoryType(self: *const VulkanRenderer, type_filter: u32, properties: vk.MemoryPropertyFlags) u32 {
    return findMemoryTypeRaw(self.mem_props, type_filter, properties);
}

pub inline fn depthHasStencil(self: *const VulkanRenderer) bool {
    return self.depth_format == .d32_sfloat_s8_uint or self.depth_format == .d24_unorm_s8_uint;
}

fn destroyOitResources(self: *VulkanRenderer) void {
    destroyIfValidImageView(self.dev, &self.oit_accum_view);
    destroyIfValidImageView(self.dev, &self.oit_reveal_view);
    destroyIfValidImage(self.dev, &self.oit_accum_image, &self.oit_accum_memory);
    destroyIfValidImage(self.dev, &self.oit_reveal_image, &self.oit_reveal_memory);

    if (self.oit_descriptor_pool != .null_handle) {
        self.dev.destroyDescriptorPool(self.oit_descriptor_pool, null);
        self.oit_descriptor_pool = .null_handle;
    }
    if (self.oit_descriptor_sets_per_frame.len > 0) {
        self.allocator.free(self.oit_descriptor_sets_per_frame);
        self.oit_descriptor_sets_per_frame = &.{};
    }
}

fn createRenderTargets(self: *VulkanRenderer, extent: vk.Extent2D) !void {
    destroyIfValidImageView(self.dev, &self.render_color_view);
    destroyIfValidImageView(self.dev, &self.render_depth_view);
    destroyIfValidImageView(self.dev, &self.render_depth_sampled_view);
    destroyIfValidImage(self.dev, &self.render_color_image, &self.render_color_memory);
    destroyIfValidImage(self.dev, &self.render_depth_image, &self.render_depth_memory);
    self.destroyOitResources();

    errdefer {
        destroyIfValidImageView(self.dev, &self.render_color_view);
        destroyIfValidImageView(self.dev, &self.render_depth_view);
        destroyIfValidImageView(self.dev, &self.render_depth_sampled_view);
        destroyIfValidImage(self.dev, &self.render_color_image, &self.render_color_memory);
        destroyIfValidImage(self.dev, &self.render_depth_image, &self.render_depth_memory);
        self.destroyOitResources();
    }

    const color = try self.createImageWithMemory(extent, self.swapchain_format, .{ .color_attachment_bit = true, .transfer_src_bit = true, .sampled_bit = true }, .{ .color_bit = true });
    self.render_color_image = color.image;
    self.render_color_memory = color.memory;
    self.render_color_view = color.view;

    {
        const cmd = try self.beginSingleTimeCommands();
        cmdImageBarrier(cmd, self.dev, self.render_color_image, .undefined, .color_attachment_optimal, .{}, .{ .color_attachment_write_bit = true }, .{ .color_bit = true }, .{ .top_of_pipe_bit = true }, .{ .color_attachment_output_bit = true });
        try self.endSingleTimeCommandsLocked(cmd);
    }

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

    const depth_aspect_mask: vk.ImageAspectFlags = if (self.depthHasStencil()) .{ .depth_bit = true, .stencil_bit = true } else .{ .depth_bit = true };
    const depth = try self.createImageWithMemory(extent, depth_format, .{ .depth_stencil_attachment_bit = true, .sampled_bit = true }, depth_aspect_mask);
    self.render_depth_image = depth.image;
    self.render_depth_memory = depth.memory;
    self.render_depth_view = depth.view;
    self.render_depth_sampled_view = try self.dev.createImageView(&imageViewCreateInfo(depth.image, depth_format, .{ .depth_bit = true }), null);

    {
        const cmd = try self.beginSingleTimeCommands();
        cmdImageBarrier(cmd, self.dev, self.render_depth_image, .undefined, .depth_stencil_attachment_optimal, .{}, .{ .depth_stencil_attachment_write_bit = true }, depth_aspect_mask, .{ .top_of_pipe_bit = true }, .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true });
        try self.endSingleTimeCommandsLocked(cmd);
    }

    const oit_usage: vk.ImageUsageFlags = .{ .color_attachment_bit = true, .sampled_bit = true };
    const oit_aspect: vk.ImageAspectFlags = .{ .color_bit = true };
    const accum = try self.createImageWithMemory(extent, .r16g16b16a16_sfloat, oit_usage, oit_aspect);
    self.oit_accum_image = accum.image;
    self.oit_accum_memory = accum.memory;
    self.oit_accum_view = accum.view;
    const reveal = try self.createImageWithMemory(extent, .r16g16b16a16_sfloat, oit_usage, oit_aspect);
    self.oit_reveal_image = reveal.image;
    self.oit_reveal_memory = reveal.memory;
    self.oit_reveal_view = reveal.view;

    {
        const cmd = try self.beginSingleTimeCommands();
        const barriers: [2]vk.ImageMemoryBarrier = .{
            makeImageBarrier(self.oit_accum_image, .undefined, .color_attachment_optimal, .{}, .{ .color_attachment_write_bit = true }, oit_aspect),
            makeImageBarrier(self.oit_reveal_image, .undefined, .color_attachment_optimal, .{}, .{ .color_attachment_write_bit = true }, oit_aspect),
        };
        self.dev.cmdPipelineBarrier(cmd, .{ .top_of_pipe_bit = true }, .{ .color_attachment_output_bit = true }, .{}, null, null, &barriers);
        try self.endSingleTimeCommandsLocked(cmd);
    }

    if (self.oit_descriptor_sets_per_frame.len > 0) {
        self.updateOitDescriptorSets();
    }

    self.updateDepthDescriptorSets();

    std.log.info("VulkanRenderer.createRenderTargets: SUCCESS - Created render targets: color image {any}, depth image {any}, accum {any}, reveal {any}\n", .{ self.render_color_image, self.render_depth_image, self.oit_accum_image, self.oit_reveal_image });
}

fn createDescriptorSetLayout(self: *VulkanRenderer) !void {
    const bindings: [3]vk.DescriptorSetLayoutBinding = .{
        .{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .vertex_bit = true }, .p_immutable_samplers = null },
        .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
        .{ .binding = 2, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
    };
    var layout_info: vk.DescriptorSetLayoutCreateInfo = .{ .flags = .{}, .binding_count = bindings.len, .p_bindings = bindings[0..] };
    self.descriptor_set_layout = try self.dev.createDescriptorSetLayout(&layout_info, null);
}

pub fn updateDepthDescriptorSets(self: *VulkanRenderer) void {
    if (self.render_depth_view == .null_handle or self.texture_manager.sampler == .null_handle or self.descriptor_pool == .null_handle) return;
    const depth_image_info: vk.DescriptorImageInfo = .{
        .image_layout = .depth_stencil_read_only_optimal,
        .image_view = self.render_depth_sampled_view,
        .sampler = self.texture_manager.sampler,
    };
    for (self.descriptor_sets_per_frame) |desc_set| {
        self.dev.updateDescriptorSets(&[_]vk.WriteDescriptorSet{.{
            .dst_set = desc_set,
            .dst_binding = 2,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = (&depth_image_info)[0..1],
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }}, null);
    }
}

fn createFrameDescriptorPool(self: *VulkanRenderer, pool: *vk.DescriptorPool, layout: vk.DescriptorSetLayout, sets: *[]vk.DescriptorSet, pool_sizes: []const vk.DescriptorPoolSize) !void {
    const num_frames = self.swapchain_images.len;
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

fn createDescriptorPoolAndSets(self: *VulkanRenderer) !void {
    const pool_sizes: [2]vk.DescriptorPoolSize = .{
        .{ .type = .storage_buffer, .descriptor_count = @intCast(self.swapchain_images.len) },
        .{ .type = .combined_image_sampler, .descriptor_count = @intCast(self.swapchain_images.len * 2) },
    };
    try self.createFrameDescriptorPool(&self.descriptor_pool, self.descriptor_set_layout, &self.descriptor_sets_per_frame, &pool_sizes);
}

fn buildGraphicsPipeline(
    self: *VulkanRenderer,
    vert_module: vk.ShaderModule,
    frag_module: vk.ShaderModule,
    color_formats: []const vk.Format,
    depth_format: vk.Format,
    depth_stencil_state: ?vk.PipelineDepthStencilStateCreateInfo,
    blend_attachments: []const vk.PipelineColorBlendAttachmentState,
    cull_back: bool,
    layout: vk.PipelineLayout,
) !vk.Pipeline {
    const piasci: vk.PipelineInputAssemblyStateCreateInfo = .{ .topology = .triangle_list, .primitive_restart_enable = .false };
    const pvsci: vk.PipelineViewportStateCreateInfo = .{ .viewport_count = 1, .p_viewports = null, .scissor_count = 1, .p_scissors = null };
    const prsci: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = if (cull_back) .{ .back_bit = true } else .{},
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
    const dyn_states: [2]vk.DynamicState = .{ .viewport, .scissor };
    const dyn: vk.PipelineDynamicStateCreateInfo = .{ .flags = .{}, .dynamic_state_count = dyn_states.len, .p_dynamic_states = &dyn_states };
    const vertex_input_info: vk.PipelineVertexInputStateCreateInfo = .{
        .flags = .{},
        .vertex_binding_description_count = 0,
        .p_vertex_binding_descriptions = undefined,
        .vertex_attribute_description_count = 0,
        .p_vertex_attribute_descriptions = undefined,
    };
    const pssci: [2]vk.PipelineShaderStageCreateInfo = .{
        shaderStageCreateInfo(.{ .vertex_bit = true }, vert_module),
        shaderStageCreateInfo(.{ .fragment_bit = true }, frag_module),
    };
    const rendering_info: vk.PipelineRenderingCreateInfo = .{
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
    if (self.dev.createGraphicsPipelines(.null_handle, &.{gpci}, null, (&pipeline)[0..1])) |res| {
        if (res != .success) return error.PipelineCreationFailed;
    } else |err| return err;
    return pipeline;
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
        .p_set_layouts = (&self.descriptor_set_layout)[0..1],
        .push_constant_range_count = 1,
        .p_push_constant_ranges = (&pc_range)[0..1],
    };
    self.pipeline_layout = try self.dev.createPipelineLayout(&layout_info, null);

    const vert_module = try self.dev.createShaderModule(&.{ .flags = .{}, .code_size = vertex_shader_spv.len, .p_code = @ptrCast(@alignCast(vertex_shader_spv.ptr)) }, null);
    defer self.dev.destroyShaderModule(vert_module, null);
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
    self.pipeline = try self.buildGraphicsPipeline(vert_module, frag_module, &.{self.swapchain_format}, self.depth_format, depth_stencil, &.{blend}, true, self.pipeline_layout);
}

fn createTransparentPipeline(self: *VulkanRenderer) !void {
    const vert_module = try self.dev.createShaderModule(&.{ .flags = .{}, .code_size = vertex_shader_spv.len, .p_code = @ptrCast(@alignCast(vertex_shader_spv.ptr)) }, null);
    defer self.dev.destroyShaderModule(vert_module, null);
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
    self.transparent_pipeline = try self.buildGraphicsPipeline(vert_module, frag_module, &formats, self.depth_format, depth_stencil, &blend_attachments, false, self.pipeline_layout);
}

fn createOitPipelinesAndDescriptors(self: *VulkanRenderer) !void {
    const bindings: [3]vk.DescriptorSetLayoutBinding = .{
        .{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
        .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
        .{ .binding = 2, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
    };
    var layout_info: vk.DescriptorSetLayoutCreateInfo = .{ .flags = .{}, .binding_count = bindings.len, .p_bindings = bindings[0..] };
    self.oit_descriptor_set_layout = try self.dev.createDescriptorSetLayout(&layout_info, null);
    errdefer {
        self.dev.destroyDescriptorSetLayout(self.oit_descriptor_set_layout, null);
        self.oit_descriptor_set_layout = .null_handle;
    }

    const pipeline_layout_info: vk.PipelineLayoutCreateInfo = .{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = (&self.oit_descriptor_set_layout)[0..1],
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
    };
    self.oit_composition_layout = try self.dev.createPipelineLayout(&pipeline_layout_info, null);
    errdefer {
        self.dev.destroyPipelineLayout(self.oit_composition_layout, null);
        self.oit_composition_layout = .null_handle;
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
    self.oit_sampler = try self.dev.createSampler(&sampler_info, null);
    errdefer {
        self.dev.destroySampler(self.oit_sampler, null);
        self.oit_sampler = .null_handle;
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
    self.oit_composition_pipeline = try self.buildGraphicsPipeline(vert_module, frag_module, &.{self.swapchain_format}, .undefined, null, &.{blend}, false, self.oit_composition_layout);
}

fn destroyOitPipelinesAndDescriptors(self: *VulkanRenderer) void {
    destroyIfValidPipeline(self.dev, &self.oit_composition_pipeline);
    destroyIfValidPipelineLayout(self.dev, &self.oit_composition_layout);
    destroyIfValidDescriptorSetLayout(self.dev, &self.oit_descriptor_set_layout);
    if (self.oit_sampler != .null_handle) {
        self.dev.destroySampler(self.oit_sampler, null);
        self.oit_sampler = .null_handle;
    }
}

fn createOitDescriptorPoolAndSets(self: *VulkanRenderer) !void {
    const pool_size = vk.DescriptorPoolSize{ .type = .combined_image_sampler, .descriptor_count = @intCast(self.swapchain_images.len * 3) };
    try self.createFrameDescriptorPool(&self.oit_descriptor_pool, self.oit_descriptor_set_layout, &self.oit_descriptor_sets_per_frame, (&pool_size)[0..1]);
}

fn updateOitDescriptorSets(self: *VulkanRenderer) void {
    const num_frames = self.swapchain_images.len;
    const image_infos: [3]vk.DescriptorImageInfo = .{
        .{ .sampler = self.oit_sampler, .image_view = self.render_color_view, .image_layout = .shader_read_only_optimal },
        .{ .sampler = self.oit_sampler, .image_view = self.oit_accum_view, .image_layout = .shader_read_only_optimal },
        .{ .sampler = self.oit_sampler, .image_view = self.oit_reveal_view, .image_layout = .shader_read_only_optimal },
    };
    for (self.oit_descriptor_sets_per_frame[0..num_frames]) |desc_set| {
        const writes: [3]vk.WriteDescriptorSet = .{
            .{ .dst_set = desc_set, .dst_binding = 0, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .p_image_info = image_infos[0..1], .p_buffer_info = undefined, .p_texel_buffer_view = undefined },
            .{ .dst_set = desc_set, .dst_binding = 1, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .p_image_info = image_infos[1..2], .p_buffer_info = undefined, .p_texel_buffer_view = undefined },
            .{ .dst_set = desc_set, .dst_binding = 2, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .p_image_info = image_infos[2..3], .p_buffer_info = undefined, .p_texel_buffer_view = undefined },
        };
        self.dev.updateDescriptorSets(&writes, null);
    }
}

fn currentFrame(self: *const VulkanRenderer) u32 {
    return @intCast(self.vk_ctx.currentFrame() % self.in_flight_fences.len);
}

fn waitFences(self: *VulkanRenderer, fences: []const vk.Fence) error{DrawFailed}!void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "waitFences" });
    defer zone.end();

    const timeout_ns: u64 = 2 * std.time.ns_per_s;
    const result = self.dev.waitForFences(fences, .true, timeout_ns) catch return error.DrawFailed;
    if (result != .success) return error.DrawFailed;
}

fn processRetiredMeshes(self: *VulkanRenderer, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "processRetiredMeshes" });
    defer zone.end();

    {
        const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "processRetiredMeshes_lock" });
        self.retired_mutex.lockUncancelable(io);
        zone_lock.end();
    }
    defer self.retired_mutex.unlock(io);

    if (self.retired_meshes.items.len == 0) return;

    const current_graphics_val = try self.dev.getSemaphoreCounterValue(self.graphics_timeline_semaphore);

    var i: usize = 0;
    while (i < self.retired_meshes.items.len) {
        const entry = self.retired_meshes.items[i];
        if (current_graphics_val >= entry.graphics_timeline_value) {
            self.destroyChunkMesh(entry.mesh);
            _ = self.retired_meshes.swapRemove(i);
        } else {
            i += 1;
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
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    };

    try self.dev.queueSubmit(self.graphics_queue, &.{submit_info}, .null_handle);

    {
        const zone_wait = tracy.Zone.begin(.{ .src = @src(), .name = "endSingleTimeCommands_queueWaitIdle" });
        defer zone_wait.end();
        try self.dev.queueWaitIdle(self.graphics_queue);
    }
}

pub fn endSingleTimeCommands(self: *VulkanRenderer, io: std.Io, cmd: vk.CommandBuffer) !void {
    self.queue_mutex.lockUncancelable(io);
    defer self.queue_mutex.unlock(io);
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
        self.swapchain_needs_recreate = true;
    }
}
fn vtableUpdateCameraDirection(user_data: *Renderer.Implementation, view_dir: @Vector(3, f32)) void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data));
    self.camera_front[0] = @sin(std.math.degreesToRadians(view_dir[1])) * @cos(std.math.degreesToRadians(view_dir[0]));
    self.camera_front[1] = @sin(std.math.degreesToRadians(view_dir[0]));
    self.camera_front[2] = @cos(std.math.degreesToRadians(view_dir[1])) * @cos(std.math.degreesToRadians(view_dir[0]));
    self.camera_front = zm.Vec3f.norm(.{ .data = self.camera_front }).data;
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
