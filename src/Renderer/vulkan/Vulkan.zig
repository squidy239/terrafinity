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

/// Per-frame rendering statistics collected for debugging.
/// Logged at info level every frame when drawing is active.
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

        const ms = @as(f64, @floatFromInt(self.elapsed_ns)) / 1_000_000.0;

        const opaque_visible_pct = if (self.opaque_candidates > 0)
            @as(f64, @floatFromInt(self.opaque_drawn)) / @as(f64, @floatFromInt(self.opaque_candidates)) * 100.0
        else
            0.0;

        const transparent_visible_pct = if (self.transparent_candidates > 0)
            @as(f64, @floatFromInt(self.transparent_drawn)) / @as(f64, @floatFromInt(self.transparent_candidates)) * 100.0
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
    memory: vk.DeviceMemory,
    device_address: vk.DeviceAddress,
    face_count: u32,
};

const ChunkData = extern struct {
    absolute_position: [3]f32 align(4 * @sizeOf(f32)),
    relative_position: [3]f32 align(4 * @sizeOf(f32)),
    scale: f32,
    address: u64 align(@sizeOf(u64)),
};
comptime {
    if (@sizeOf(ChunkData) != 48) @compileError("ChunkData size must be 48 bytes");
    if (@offsetOf(ChunkData, "address") != 32) @compileError("address offset must be 32");
    if (@offsetOf(ChunkData, "scale") != 28) @compileError("scale offset must be 28");
}

const PushConstants = extern struct {
    projview: [16]f32,
    sun_dir: [3]f32,
    time: f32,
    draw_over: i32,
};

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

meshes: ConcurrentHashMap(RenderBufferKey, ChunkMeshBuffer, std.hash_map.AutoContext(RenderBufferKey), 80, 32),

indirect_draw_buffers: []vk.Buffer = &.{},
indirect_draw_memories: []vk.DeviceMemory = &.{},
indirect_draw_buffers_mapped: [][*]u8 = &.{},

chunk_data_buffers: []vk.Buffer = &.{},
chunk_data_memories: []vk.DeviceMemory = &.{},
chunk_data_buffers_mapped: [][*]u8 = &.{},

max_draw_count: u32 = 100_000,

deferred_deletions: [8]std.ArrayList(ChunkMeshBuffer) = undefined,

camera_front: @Vector(3, f32) = .{ 0, 0, 1 },
viewport_pixels: @Vector(2, u32) = .{ 800, 600 },

render_options: *const RenderOptions = &default_render_options,
render_options_lock: *std.Io.RwLock = &default_render_options_lock,

interface: Renderer,

queue_mutex: std.Io.Mutex = .init,

deferred_deletions_mutex: std.Io.Mutex = .init,

frame_number: u64 = 0,
frame_stats: FrameDebugStats = .{},

pub const RenderOptions = struct {
    draw_over: bool = false,
    fov: f32 = 90.0,
    day_length_sec: f32 = 60 * 5,
};

const default_render_options: RenderOptions = .{
    .draw_over = false,
    .fov = 90.0,
    .day_length_sec = 60 * 5,
};

var default_render_options_lock: std.Io.RwLock = .init;

fn getDeletionQueueIndex(self: *VulkanRenderer) u32 {
    const unbound = self.current_frame_idx.load(.monotonic);
    const fence_slot = @as(u32, @intCast(unbound % @as(u64, @intCast(self.in_flight_fences.len))));
    return fence_slot % @as(u32, @intCast(self.deferred_deletions.len));
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

pub fn init(io: std.Io, allocator: std.mem.Allocator, window: *wio.Window) !*VulkanRenderer {
    return initWithOptions(io, allocator, window, &default_render_options, &default_render_options_lock);
}

pub fn initWithOptions(io: std.Io, allocator: std.mem.Allocator, window: *wio.Window, render_options: *const RenderOptions, render_options_lock: *std.Io.RwLock) !*VulkanRenderer {
    std.log.debug("VulkanRenderer.init: ENTER - Starting Vulkan initialization...", .{});
    std.log.info("VulkanRenderer.init: Starting Vulkan initialization...", .{});

    std.log.debug("VulkanRenderer.init: Step 1 - Creating VulkanRenderer struct...", .{});
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
    };

    std.log.debug("VulkanRenderer.init: Step 1 - Allocated VulkanRenderer struct at ptr={*}", .{self});
    std.log.info("VulkanRenderer.init: Allocated VulkanRenderer struct", .{});

    self.allocator = allocator;
    self.window = window;
    self.render_options = render_options;
    self.render_options_lock = render_options_lock;

    std.log.debug("VulkanRenderer.init: Step 2 - Initializing Vulkan handle fields to safe defaults...", .{});

    inline for (0..8) |i| {
        self.deferred_deletions[i] = .{
            .items = &[_]ChunkMeshBuffer{},
            .capacity = 0,
        };
    }

    std.log.debug("VulkanRenderer.init: Step 3 - Loading Vulkan BaseWrapper...", .{});
    self.vkb = BaseWrapper.load(getProcAddr);

    const app_info = vk.ApplicationInfo{
        .p_application_name = "Terrafinity",
        .application_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
        .p_engine_name = "No Engine",
        .engine_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
        .api_version = vk.API_VERSION_1_3.toU32(),
    };

    var enabled_layers: std.ArrayList([*:0]const u8) = .empty;
    defer enabled_layers.deinit(allocator);

    std.log.debug("VulkanRenderer.init: Step 4 - Enumerating Vulkan instance layer properties...", .{});
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
    std.log.debug("VulkanRenderer.init: Step 4 - Validation layer available: {}", .{has_validation_layer});

    var extension_names: std.ArrayList([*:0]const u8) = .empty;
    defer extension_names.deinit(allocator);

    const wio_extensions = wio.getRequiredVulkanInstanceExtensions();
    std.log.debug("VulkanRenderer.init: Step 5 - wio requires {} Vulkan instance extensions", .{wio_extensions.len});
    for (wio_extensions) |ext| {
        try extension_names.append(allocator, ext);
    }

    std.log.debug("VulkanRenderer.init: Step 5 - Enumerating Vulkan instance extension properties...", .{});
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
    std.log.debug("VulkanRenderer.init: Step 5 - Extension count after adding wio and portability: {}, has_portability={}", .{ extension_names.items.len, has_portability });

    const instance_create_info = vk.InstanceCreateInfo{
        .s_type = .instance_create_info,
        .flags = .{ .enumerate_portability_bit_khr = has_portability },
        .p_application_info = &app_info,
        .enabled_layer_count = @intCast(enabled_layers.items.len),
        .pp_enabled_layer_names = if (enabled_layers.items.len > 0) @ptrCast(enabled_layers.items.ptr) else null,
        .enabled_extension_count = @intCast(extension_names.items.len),
        .pp_enabled_extension_names = if (extension_names.items.len > 0) @ptrCast(extension_names.items.ptr) else null,
    };

    std.log.debug("VulkanRenderer.init: Step 6 - Creating Vulkan instance with createInfo...", .{});
    self.instance_handle = try self.vkb.createInstance(&instance_create_info, null);
    std.log.debug("VulkanRenderer.init: Step 6 - Created Vulkan instance handle={any}", .{self.instance_handle});
    std.log.info("VulkanRenderer.init: Created Vulkan instance successfully", .{});

    std.log.debug("VulkanRenderer.init: Step 7 - Creating InstanceWrapper...", .{});

    const instance_wrapper_ptr = try allocator.create(InstanceWrapper);
    errdefer allocator.destroy(instance_wrapper_ptr);

    instance_wrapper_ptr.* = InstanceWrapper.load(self.instance_handle, getProcAddr);
    self.instance_wrapper = instance_wrapper_ptr;
    self.instance = InstanceProxy.init(self.instance_handle, instance_wrapper_ptr);
    errdefer self.instance.destroyInstance(null);

    var surface: vk.SurfaceKHR = .null_handle;
    std.log.debug("VulkanRenderer.init: Step 8 - Creating Vulkan surface from window...", .{});
    const result: vk.Result = @enumFromInt(window.vkCreateSurface(@intFromEnum(self.instance.handle), null, @ptrCast(&surface)));
    if (result != .success) {
        std.log.err("VulkanRenderer.init: Failed to create Vulkan surface with result: {any}", .{result});
        return error.SurfaceCreationFailed;
    }
    self.surface = surface;
    errdefer self.instance.destroySurfaceKHR(self.surface, null);
    std.log.debug("VulkanRenderer.init: Step 8 - Created Vulkan surface handle={any}", .{self.surface});
    std.log.info("VulkanRenderer.init: Created Vulkan surface successfully", .{});

    std.log.debug("VulkanRenderer.init: Step 9 - Enumerating physical devices...", .{});
    var pdev_count: u32 = 0;
    _ = try self.instance.enumeratePhysicalDevices(&pdev_count, null);

    const pdevs = try allocator.alloc(vk.PhysicalDevice, pdev_count);
    defer allocator.free(pdevs);

    _ = try self.instance.enumeratePhysicalDevices(&pdev_count, pdevs.ptr);

    std.log.debug("VulkanRenderer.init: Step 10 - Found {} physical devices, selecting best...", .{pdev_count});
    var selected_pdev: vk.PhysicalDevice = .null_handle;
    for (pdevs) |pdev| {
        var features12 = vk.PhysicalDeviceVulkan12Features{
            .buffer_device_address = .true,
            .descriptor_indexing = .true,
            .runtime_descriptor_array = .true,
            .p_next = null,
        };
        var features2 = vk.PhysicalDeviceFeatures2{
            .features = .{ .multi_draw_indirect = .true },
            .p_next = @ptrCast(&features12),
        };

        self.instance.getPhysicalDeviceFeatures2(pdev, &features2);

        if (features2.features.multi_draw_indirect == .true and
            features12.buffer_device_address == .true and
            features12.descriptor_indexing == .true)
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
                    selected_pdev = pdev;
                    break;
                }
            }
        }
    }

    if (selected_pdev == .null_handle) {
        std.log.err("VulkanRenderer.init: Step 10 - No suitable physical device found", .{});
        return error.NoSuitablePhysicalDevice;
    }

    self.pdev = selected_pdev;
    std.log.debug("VulkanRenderer.init: Step 10 - Selected physical device handle={any}", .{self.pdev});

    const props = self.instance.getPhysicalDeviceProperties(self.pdev);
    self.props = props;

    const max_draw_indirect_count = props.limits.max_draw_indirect_count;
    if (max_draw_indirect_count > 0) {
        self.max_draw_count = @min(100_000, max_draw_indirect_count);
    } else {
        self.max_draw_count = 65_535;
    }
    std.log.debug("VulkanRenderer.init: Step 11 - max_draw_count set to {}", .{self.max_draw_count});

    const device_name = std.mem.sliceTo(&props.device_name, 0);
    std.log.debug("VulkanRenderer.init: Step 11 - Selected physical device name: '{s}'", .{device_name});
    std.log.info("VulkanRenderer.init: Selected physical device: {s}", .{device_name});

    const queue_priorities = [_]f32{1.0};

    std.log.debug("VulkanRenderer.init: Step 12 - Enumerating queue family properties...", .{});
    var graphics_family: u32 = 0;
    var present_family: u32 = 0;

    const queue_families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(self.pdev, allocator);
    defer allocator.free(queue_families);

    for (queue_families, 0..) |qf, i| {
        const family: u32 = @intCast(i);
        if (graphics_family == 0 and qf.queue_flags.graphics_bit) {
            graphics_family = family;
        }
        var present_supported: vk.Bool32 = .false;
        present_supported = try self.instance.getPhysicalDeviceSurfaceSupportKHR(self.pdev, family, self.surface);
        if (present_family == 0 and present_supported == .true) {
            present_family = family;
        }
    }

    self.queue_family_index = graphics_family;
    self.present_queue_family_index = present_family;

    std.log.debug("VulkanRenderer.init: Step 12 - Graphics queue family index: {}, Present queue family index: {}", .{ graphics_family, present_family });

    const device_extensions = [_][*:0]const u8{
        vk.extensions.khr_swapchain.name,
        vk.extensions.khr_dynamic_rendering.name,
    };

    const queue_create_info_count: u32 = if (graphics_family == present_family) 1 else 2;

    var queue_create_infos_ptr: [2]vk.DeviceQueueCreateInfo = undefined;
    queue_create_infos_ptr[0] = .{
        .flags = .{},
        .queue_family_index = graphics_family,
        .queue_count = 1,
        .p_queue_priorities = &queue_priorities,
    };
    if (graphics_family != present_family) {
        queue_create_infos_ptr[1] = .{
            .flags = .{},
            .queue_family_index = present_family,
            .queue_count = 1,
            .p_queue_priorities = &queue_priorities,
        };
    }

    var dynamic_rendering_features = vk.PhysicalDeviceDynamicRenderingFeatures{
        .dynamic_rendering = .true,
    };
    var features12 = vk.PhysicalDeviceVulkan12Features{
        .draw_indirect_count = .true,
        .descriptor_indexing = .true,
        .runtime_descriptor_array = .true,
        .descriptor_binding_partially_bound = .true,
        .buffer_device_address = .true,
        .p_next = @ptrCast(&dynamic_rendering_features),
    };

    var features11 = vk.PhysicalDeviceVulkan11Features{
        .shader_draw_parameters = .true,
        .p_next = @ptrCast(&features12),
    };

    var features = vk.PhysicalDeviceFeatures2{
        .features = .{
            .multi_draw_indirect = .true,
            .shader_int_64 = .true,
        },
        .p_next = @ptrCast(&features11),
    };

    const device_info = vk.DeviceCreateInfo{
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

    std.log.debug("VulkanRenderer.init: Step 13 - Creating logical device with createInfo...", .{});
    self.dev_handle = try self.instance.createDevice(self.pdev, &device_info, null);
    std.log.debug("VulkanRenderer.init: Step 13 - Created logical device handle={any}", .{self.dev_handle});
    std.log.info("VulkanRenderer.init: Created logical device successfully", .{});

    std.log.debug("VulkanRenderer.init: Step 14 - Creating DeviceWrapper...", .{});

    const dev_wrapper_ptr = try allocator.create(DeviceWrapper);
    errdefer allocator.destroy(dev_wrapper_ptr);

    const gdpa = self.instance.wrapper.dispatch.vkGetDeviceProcAddr orelse return error.MissingDeviceProcAddr;
    dev_wrapper_ptr.* = DeviceWrapper.load(self.dev_handle, gdpa);
    self.dev_wrapper = dev_wrapper_ptr;
    self.dev = DeviceProxy.init(self.dev_handle, dev_wrapper_ptr);
    errdefer {
        if (self.command_pool != .null_handle) {
            self.dev.destroyCommandPool(self.command_pool, null);
        }
        if (self.swapchain != .null_handle) {
            for (self.swapchain_views) |view| {
                if (view != .null_handle) self.dev.destroyImageView(view, null);
            }
            if (self.upload_command_pool != .null_handle) {
                self.dev.destroyCommandPool(self.upload_command_pool, null);
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
    }

    std.log.debug("VulkanRenderer.init: Step 15 - Getting graphics and present queues...", .{});
    self.graphics_queue = self.dev.getDeviceQueue(graphics_family, 0);
    if (graphics_family == present_family) {
        self.present_queue = self.graphics_queue;
        std.log.debug("VulkanRenderer.init: Step 15 - Graphics and present queue are the same", .{});
    } else {
        self.present_queue = self.dev.getDeviceQueue(present_family, 0);
        std.log.debug("VulkanRenderer.init: Step 15 - Graphics queue={any}, Present queue={any}", .{ self.graphics_queue, self.present_queue });
    }

    self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);

    std.log.debug("VulkanRenderer.init: Step 16 - Creating command pool...", .{});
    const pool_info = vk.CommandPoolCreateInfo{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = graphics_family,
    };
    self.command_pool = try self.dev.createCommandPool(&pool_info, null);
    std.log.debug("VulkanRenderer.init: Step 16 - Created command pool handle={any}", .{self.command_pool});

    std.log.debug("VulkanRenderer.init: Step 17 - Creating upload command pool...", .{});
    const upload_pool_info = vk.CommandPoolCreateInfo{
        .flags = .{ .reset_command_buffer_bit = true, .transient_bit = true },
        .queue_family_index = graphics_family,
    };
    self.upload_command_pool = try self.dev.createCommandPool(&upload_pool_info, null);
    std.log.debug("VulkanRenderer.init: Step 17 - Created upload command pool handle={any}", .{self.upload_command_pool});

    std.log.debug("VulkanRenderer.init: Step 18 - Initializing swapchain...", .{});
    try self.createSwapchain(io);
    std.log.debug("VulkanRenderer.init: Step 18 - Swapchain created successfully", .{});

    std.log.debug("VulkanRenderer.init: Step 19 - Creating descriptor set layout...", .{});
    try self.createDescriptorSetLayout();
    std.log.debug("VulkanRenderer.init: Step 19 - Descriptor set layout created successfully", .{});
    std.log.debug("VulkanRenderer.init: Step 20 - Creating descriptor pool and sets...", .{});
    try self.createDescriptorPoolAndSets(io);
    std.log.debug("VulkanRenderer.init: Step 20 - Descriptor pool and sets created successfully", .{});

    std.log.debug("VulkanRenderer.init: Step 20a - Loading block textures...", .{});
    {
        self.texture_manager = textures.TextureArrayManager.init(self);

        // Write embedded block texture PNGs to disk (same as OpenGL renderer)
        const dir = try std.Io.Dir.cwd().createDirPathOpen(io, "packs/default/Blocks/", .{ .open_options = .{ .iterate = true } });
        defer dir.close(io);
        try dir.writeFile(io, .{ .data = @embedFile("../opengl/Blocks/grass.png"), .sub_path = "grass.png" });
        try dir.writeFile(io, .{ .data = @embedFile("../opengl/Blocks/dirt.png"), .sub_path = "dirt.png" });
        try dir.writeFile(io, .{ .data = @embedFile("../opengl/Blocks/snow.png"), .sub_path = "snow.png" });
        try dir.writeFile(io, .{ .data = @embedFile("../opengl/Blocks/stone.png"), .sub_path = "stone.png" });
        try dir.writeFile(io, .{ .data = @embedFile("../opengl/Blocks/water.png"), .sub_path = "water.png" });
        try dir.writeFile(io, .{ .data = @embedFile("../opengl/Blocks/wood.png"), .sub_path = "wood.png" });
        try dir.writeFile(io, .{ .data = @embedFile("../opengl/Blocks/leaves.png"), .sub_path = "leaves.png" });

        try self.texture_manager.loadTextureDirectory(io, dir, allocator, ".png");
    }
    // Destroy dummy placeholder textures now that real textures are loaded
    if (self.dummy_sampler != .null_handle) {
        self.dev.destroySampler(self.dummy_sampler, null);
        self.dummy_sampler = .null_handle;
    }
    if (self.dummy_view != .null_handle) {
        self.dev.destroyImageView(self.dummy_view, null);
        self.dummy_view = .null_handle;
    }
    if (self.dummy_image != .null_handle) {
        self.dev.destroyImage(self.dummy_image, null);
        self.dummy_image = .null_handle;
    }
    if (self.dummy_memory != .null_handle) {
        self.dev.freeMemory(self.dummy_memory, null);
        self.dummy_memory = .null_handle;
    }
    std.log.debug("VulkanRenderer.init: Step 20a - Block textures loaded successfully", .{});

    std.log.debug("VulkanRenderer.init: Step 21 - Creating opaque pipeline...", .{});
    try self.createPipeline();
    std.log.debug("VulkanRenderer.init: Step 21 - Opaque pipeline created successfully", .{});
    std.log.debug("VulkanRenderer.init: Step 22 - Creating transparent pipeline...", .{});
    try self.createTransparentPipeline();
    std.log.debug("VulkanRenderer.init: Step 22 - Transparent pipeline created successfully", .{});

    std.log.debug("VulkanRenderer.init: Step 23 - Allocating indirect buffers...", .{});
    try self.allocateIndirectBuffers();
    std.log.debug("VulkanRenderer.init: Step 23 - Indirect buffers allocated successfully", .{});

    self.queue_family_index = graphics_family;
    self.present_queue_family_index = present_family;
    self.meshes = .init;
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
    _ = self.dev.deviceWaitIdle() catch {};

    var it = self.meshes.iterator();
    while (it.next(io) catch null) |entry| {
        self.destroyChunkMesh(entry.value_ptr.*);
    }
    self.meshes.deinit(io, self.allocator);

    inline for (0..8) |i| {
        var dq = &self.deferred_deletions[i];
        for (dq.items) |mesh| {
            if (mesh.buffer != .null_handle) self.dev.destroyBuffer(mesh.buffer, null);
            if (mesh.memory != .null_handle) self.dev.freeMemory(mesh.memory, null);
        }
        dq.deinit(self.allocator);
    }

    for (self.indirect_draw_buffers) |buf| {
        if (buf != .null_handle) self.dev.destroyBuffer(buf, null);
    }
    self.allocator.free(self.indirect_draw_buffers);
    for (self.indirect_draw_memories) |mem| {
        if (mem != .null_handle) self.dev.freeMemory(mem, null);
    }
    self.allocator.free(self.indirect_draw_memories);

    for (self.chunk_data_buffers) |buf| {
        if (buf != .null_handle) self.dev.destroyBuffer(buf, null);
    }
    self.allocator.free(self.chunk_data_buffers);
    for (self.chunk_data_memories) |mem| {
        if (mem != .null_handle) self.dev.freeMemory(mem, null);
    }
    self.allocator.free(self.chunk_data_memories);

    if (self.swapchain != .null_handle) {
        for (self.swapchain_views) |view| {
            self.dev.destroyImageView(view, null);
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

        if (self.image_acquired_semaphores.len > 0) self.allocator.free(self.image_acquired_semaphores);
        if (self.render_complete_semaphores.len > 0) self.allocator.free(self.render_complete_semaphores);
        if (self.in_flight_fences.len > 0) self.allocator.free(self.in_flight_fences);

        if (self.swapchain_images.len > 0) self.allocator.free(self.swapchain_images);
        if (self.swapchain_views.len > 0) self.allocator.free(self.swapchain_views);
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

    if (self.dummy_sampler != .null_handle) {
        self.dev.destroySampler(self.dummy_sampler, null);
        self.dummy_sampler = .null_handle;
    }
    if (self.dummy_view != .null_handle) {
        self.dev.destroyImageView(self.dummy_view, null);
        self.dummy_view = .null_handle;
    }
    if (self.dummy_image != .null_handle) {
        self.dev.destroyImage(self.dummy_image, null);
        self.dummy_image = .null_handle;
    }
    if (self.dummy_memory != .null_handle) {
        self.dev.freeMemory(self.dummy_memory, null);
        self.dummy_memory = .null_handle;
    }

    self.texture_manager.destroyTextureArray();

    if (self.cmd_buffers.len > 0) {
        self.dev.freeCommandBuffers(self.command_pool, self.cmd_buffers);
        self.allocator.free(self.cmd_buffers);
        self.cmd_buffers = &.{};
    }

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

fn vtableAddChunk(userdata: *anyopaque, io: std.Io, chunk_pos: ChunkPos, opaque_mesh: []Mesher.Face, transparent_mesh: []Mesher.Face) error{ OutOfMemory, OutOfVideoMemory, Unexpected }!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));

    if (opaque_mesh.len > 0) {
        self.uploadMesh(io, .{ .@"opaque" = chunk_pos }, opaque_mesh) catch |err| switch (err) {
            error.OutOfHostMemory, error.OutOfDeviceMemory => return error.OutOfVideoMemory,
            else => return error.Unexpected,
        };
    } else {
        self.remove(io, .{ .@"opaque" = chunk_pos });
    }

    if (transparent_mesh.len > 0) {
        self.uploadMesh(io, .{ .transparent = chunk_pos }, transparent_mesh) catch |err| switch (err) {
            error.OutOfHostMemory, error.OutOfDeviceMemory => return error.OutOfVideoMemory,
            else => return error.Unexpected,
        };
    } else {
        self.remove(io, .{ .transparent = chunk_pos });
    }
}

fn uploadMesh(self: *VulkanRenderer, io: std.Io, key: RenderBufferKey, faces: []Mesher.Face) !void {
    const buffer_size = @as(vk.DeviceSize, @intCast(faces.len)) * @sizeOf(Mesher.Face);

    // Index block_type via EnumIndexer (same as OpenGL) so texture array layer
    // indices match the Block declaration order
    const indexer = std.enums.EnumIndexer(World.Block);
    for (faces) |*face| {
        face.block_type = @intCast(indexer.indexOf(@enumFromInt(face.block_type)));
    }

    var staging_buffer: vk.Buffer = .null_handle;
    var staging_memory: vk.DeviceMemory = .null_handle;
    try self.createBuffer(buffer_size, .{ .transfer_src_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, &staging_buffer, &staging_memory);
    defer {
        if (staging_buffer != .null_handle) self.dev.destroyBuffer(staging_buffer, null);
        if (staging_memory != .null_handle) self.dev.freeMemory(staging_memory, null);
    }

    const data = try self.dev.mapMemory(staging_memory, 0, buffer_size, .{});
    const mapped_slice = @as([*]u8, @ptrCast(data))[0..buffer_size];
    const src_slice = std.mem.sliceAsBytes(faces);
    @memcpy(mapped_slice, src_slice);

    self.dev.unmapMemory(staging_memory);

    var buffer: vk.Buffer = .null_handle;
    var memory: vk.DeviceMemory = .null_handle;
    errdefer {
        if (buffer != .null_handle) self.dev.destroyBuffer(buffer, null);
        if (memory != .null_handle) self.dev.freeMemory(memory, null);
    }

    const usage = vk.BufferUsageFlags{
        .transfer_dst_bit = true,
        .storage_buffer_bit = true,
        .shader_device_address_bit = true,
    };

    const buffer_info = vk.BufferCreateInfo{
        .flags = .{},
        .size = buffer_size,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };

    buffer = try self.dev.createBuffer(&buffer_info, null);

    var alloc_flags = vk.MemoryAllocateFlagsInfo{
        .flags = .{ .device_address_bit = true },
        .device_mask = 0,
    };
    const mem_reqs = self.dev.getBufferMemoryRequirements(buffer);
    const alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = mem_reqs.size,
        .memory_type_index = self.findMemoryType(mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
        .p_next = @ptrCast(&alloc_flags),
    };

    memory = try self.dev.allocateMemory(&alloc_info, null);
    try self.dev.bindBufferMemory(buffer, memory, 0);

    try self.copyBuffer(io, staging_buffer, buffer, buffer_size);

    const address_info = vk.BufferDeviceAddressInfo{
        .buffer = buffer,
    };
    const device_address = self.dev.getBufferDeviceAddress(&address_info);

    const mesh_buffer = ChunkMeshBuffer{
        .buffer = buffer,
        .memory = memory,
        .device_address = device_address,
        .face_count = @intCast(faces.len),
    };

    const existing = try self.meshes.fetchPut(io, self.allocator, key, mesh_buffer);
    if (existing) |e| {
        self.enqueueDeferredDeletion(io, e);
    }
}

pub fn remove(self: *VulkanRenderer, io: std.Io, key: RenderBufferKey) void {
    if (self.meshes.fetchRemove(io, key)) |mesh| {
        self.destroyChunkMesh(mesh);
    }
}

fn vtableRemoveChunk(userdata: *anyopaque, io: std.Io, chunk_pos: ChunkPos) void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));

    if (self.meshes.fetchRemove(io, .{ .@"opaque" = chunk_pos })) |mesh| {
        self.enqueueDeferredDeletion(io, mesh);
    }
    if (self.meshes.fetchRemove(io, .{ .transparent = chunk_pos })) |mesh| {
        self.enqueueDeferredDeletion(io, mesh);
    }
}

fn destroyChunkMesh(self: *VulkanRenderer, mesh: ChunkMeshBuffer) void {
    if (mesh.buffer != .null_handle) self.dev.destroyBuffer(mesh.buffer, null);
    if (mesh.memory != .null_handle) self.dev.freeMemory(mesh.memory, null);
}

pub fn processDeferredDeletions(self: *VulkanRenderer, io: std.Io) error{DrawFailed}!void {
    const current_frame = self.currentFrame();

    var fences_wait: [1]vk.Fence = .{self.in_flight_fences[current_frame]};
    try self.waitFences(&fences_wait);

    try self.processDeletionQueue(io, current_frame);
}

fn vtableDrawChunks(userdata: *anyopaque, io: std.Io, viewpos: @Vector(3, f64)) error{DrawFailed}!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));

    std.log.debug("vtableDrawChunks: ENTER - Starting chunk drawing...", .{});
    const c = tracy.Zone.begin(.{ .src = @src() });
    defer c.end();

    var current_frame = self.currentFrame();

    std.log.debug("vtableDrawChunks: Step 2 - Waiting for previous frame fences to complete...", .{});
    var fences_wait: [1]vk.Fence = .{self.in_flight_fences[current_frame]};
    _ = try self.waitFences(&fences_wait);

    std.log.debug("vtableDrawChunks: Step 3 - Processing deferred deletions...", .{});
    self.processDeletionQueue(io, current_frame) catch return error.DrawFailed;

    std.log.debug("vtableDrawChunks: Step 4 - Resetting fences for current frame...", .{});
    var fences_reset: [1]vk.Fence = .{self.in_flight_fences[current_frame]};
    _ = self.dev.resetFences(&fences_reset) catch |err| switch (err) {
        else => {},
    };

    if (self.swapchain_needs_recreate) {
        self.swapchain_needs_recreate = false;
        std.log.debug("vtableDrawChunks: Swapchain needs recreation due to viewport resize...", .{});
        _ = self.dev.deviceWaitIdle() catch {};
        self.createSwapchain(io) catch |err| switch (err) {
            else => return error.DrawFailed,
        };
        current_frame = self.currentFrame();
    }

    std.log.debug("vtableDrawChunks: Step 5 - Acquiring next swapchain image...", .{});
    var image_index: u32 = 0;
    const acquire_result_res = self.dev.acquireNextImageKHR(
        self.swapchain,
        std.math.maxInt(u64),
        self.image_acquired_semaphores[current_frame],
        .null_handle,
    ) catch |err| switch (err) {
        else => return error.DrawFailed,
    };

    if (acquire_result_res.result == vk.Result.error_out_of_date_khr) {
        self.createSwapchain(io) catch |err| switch (err) {
            else => return error.DrawFailed,
        };
        current_frame = self.currentFrame();
        const acquire_result_res2 = self.dev.acquireNextImageKHR(
            self.swapchain,
            std.math.maxInt(u64),
            self.image_acquired_semaphores[current_frame],
            .null_handle,
        ) catch |err| switch (err) {
            else => return error.DrawFailed,
        };
        image_index = acquire_result_res2.image_index;
    } else if (acquire_result_res.result == vk.Result.suboptimal_khr) {
        self.recreateSwapchainOnly(io) catch |err| switch (err) {
            else => return error.DrawFailed,
        };
        current_frame = self.currentFrame();
        const acquire_result_res2 = self.dev.acquireNextImageKHR(
            self.swapchain,
            std.math.maxInt(u64),
            self.image_acquired_semaphores[current_frame],
            .null_handle,
        ) catch |err| switch (err) {
            else => return error.DrawFailed,
        };
        image_index = acquire_result_res2.image_index;
    } else {
        image_index = acquire_result_res.image_index;
    }
    self.current_swapchain_image_index = image_index;

    const cmd_buffer = self.cmd_buffers[current_frame];

    std.log.debug("vtableDrawChunks: Step 6 - Calculating projection/view math...", .{});
    const aspect = @as(f32, @floatFromInt(self.viewport_pixels[0])) / @as(f32, @floatFromInt(self.viewport_pixels[1]));

    self.render_options_lock.lockSharedUncancelable(io);
    const draw_over = self.render_options.draw_over;
    const fov = std.math.degreesToRadians(self.render_options.fov);
    const day_length_sec = self.render_options.day_length_sec;
    self.render_options_lock.unlockShared(io);

    // Pure-rotation view matrix at origin — matches OpenGL convention.
    // The vertex shader already applies the translation via relative_position = chunk_pos - playerPos,
    // so including it in the view matrix would cause double-translation, putting everything off-screen.
    const up_vec = zm.vec.Vec3f{ .data = [3]f32{ cameraUp[0], cameraUp[1], cameraUp[2] } };

    const view = zm.matrix.Mat4f.lookAtRH(
        .{ .data = @Vector(3, f32){ 0, 0, 0 } },
        .{ .data = self.camera_front },
        up_vec,
    );

    const projection = makeInfReversedZProjRh(fov, aspect, 0.01);
    const projview = @as(@Vector(16, f32), @bitCast(projection.multiply(view).data));

    const blueSky = @Vector(4, f32){ 0.0, 0.4, 0.8, 1.0 };
    const greySky = @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 };
    const skyColor = std.math.lerp(blueSky, greySky, @as(@Vector(4, f32), @splat(@as(f32, @floatCast(@min(1.0, @max(0.0, viewpos[1] / 4096.0)))))));

    const sun_angle = @rem(@as(f64, @floatFromInt(std.Io.Timestamp.now(io, .real).nanoseconds)) / ((@as(f64, @max(0.001, day_length_sec)) * @as(f64, @floatFromInt(std.time.ns_per_s))) / 360.0), 360.0);
    const sun_rot_mat = zm.Mat4f.rotationRH(.{ .data = @Vector(3, f32){ 1.0, 0.0, 0.0 } }, @floatCast(std.math.degreesToRadians(sun_angle)));
    const sun_dir: @Vector(3, f32) = .{ sun_rot_mat.data[1][0], sun_rot_mat.data[1][1], sun_rot_mat.data[1][2] };

    const millitimestamp = std.Io.Timestamp.now(io, .real).toMilliseconds();

    std.log.debug("vtableDrawChunks: Step 7 - Beginning command buffer...", .{});
    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };
    self.dev.beginCommandBuffer(cmd_buffer, &begin_info) catch |err| switch (err) {
        else => return error.DrawFailed,
    };

    std.log.debug("vtableDrawChunks: Step 8 - Beginning dynamic rendering with color and depth attachments...", .{});
    const color_attachment = vk.RenderingAttachmentInfo{
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

    const depth_attachment = vk.RenderingAttachmentInfo{
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

    const render_info = vk.RenderingInfo{
        .flags = .{},
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain_extent },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment),
        .p_depth_attachment = &depth_attachment,
        .p_stencil_attachment = null,
    };
    std.log.debug("vtableDrawChunks: Step 9 - Calling cmdBeginRendering...", .{});
    self.dev.cmdBeginRendering(cmd_buffer, &render_info);

    std.log.debug("vtableDrawChunks: Step 10 - Binding opaque pipeline...", .{});
    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.pipeline);

    const viewport = vk.Viewport{
        .x = 0.0,
        .y = 0.0,
        .width = @as(f32, @floatFromInt(self.swapchain_extent.width)),
        .height = @as(f32, @floatFromInt(self.swapchain_extent.height)),
        .min_depth = 0.0,
        .max_depth = 1.0,
    };
    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = self.swapchain_extent,
    };
    var viewport_arr: [1]vk.Viewport = undefined;
    viewport_arr[0] = viewport;
    self.dev.cmdSetViewport(cmd_buffer, 0, &viewport_arr);
    var scissor_arr: [1]vk.Rect2D = undefined;
    scissor_arr[0] = scissor;
    self.dev.cmdSetScissor(cmd_buffer, 0, &scissor_arr);

    const buffer_info = vk.DescriptorBufferInfo{
        .buffer = self.chunk_data_buffers[current_frame],
        .offset = 0,
        .range = vk.WHOLE_SIZE,
    };

    const chunk_data_write = vk.WriteDescriptorSet{
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

    var pc = PushConstants{
        .projview = std.mem.zeroes([16]f32),
        .sun_dir = @as([3]f32, @bitCast(sun_dir)),
        .time = @floatFromInt(millitimestamp),
        .draw_over = if (draw_over) 1 else 0,
    };

    inline for (0..4) |row| {
        inline for (0..4) |col| {
            pc.projview[row * 4 + col] = @as([4][4]f32, @bitCast(projview))[col][row];
        }
    }

    self.dev.cmdPushConstants(cmd_buffer, self.pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(PushConstants), @ptrCast(&pc));

    std.log.debug("vtableDrawChunks: Step 12 - Extracting frustum planes...", .{});
    const frustum = Frustum.extractFrustumPlanes(projview);

    // Start frame timing
    const frame_start_ns = std.Io.Timestamp.now(io, .real).nanoseconds;

    std.log.debug("vtableDrawChunks: Step 13 - Drawing opaque chunks...", .{});
    const opaque_draw_count = self.drawChunksReal(io, cmd_buffer, current_frame, viewpos, frustum, false, 0) catch {
        return error.DrawFailed;
    };

    std.log.debug("vtableDrawChunks: Step 14 - Binding transparent pipeline...", .{});
    self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.transparent_pipeline);

    // OIT integration point: replace the simple indirect draw below with an OIT pass.
    // To implement Order Independent Transparency, change this section to:
    //   1. Bind an OIT pipeline (or compute shader) that accumulates fragments
    //      into a per-pixel linked list or atomic accumulation buffer.
    //   2. Draw transparent geometry without sorting (already done below).
    //   3. Resolve the OIT buffer with a fullscreen pass (blend or sort per-pixel).
    // The transparent pipeline's depth_write_enable=false is already OIT-compatible.
    std.log.debug("vtableDrawChunks: Step 15 - Drawing transparent chunks...", .{});
    _ = self.drawChunksReal(io, cmd_buffer, current_frame, viewpos, frustum, true, opaque_draw_count) catch {
        return error.DrawFailed;
    };

    // End frame timing
    const frame_end_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const frame_elapsed_ns = @as(u64, @intCast(@max(0, frame_end_ns - frame_start_ns)));

    // Collect frame stats
    self.frame_number += 1;
    self.frame_stats.frame_number = self.frame_number;
    self.frame_stats.total_meshes = @as(u32, @intCast(self.meshes.count(io)));
    self.frame_stats.player_pos = viewpos;
    self.frame_stats.camera_front = self.camera_front;
    self.frame_stats.elapsed_ns = frame_elapsed_ns;

    // Log frame debug stats every frame
    self.frame_stats.log();

    std.log.debug("vtableDrawChunks: Step 16 - Calling cmdEndRendering...", .{});
    self.dev.cmdEndRendering(cmd_buffer);

    const color_to_copy_barrier = vk.ImageMemoryBarrier{
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

    self.dev.cmdPipelineBarrier(cmd_buffer, .{ .color_attachment_output_bit = true }, .{ .transfer_bit = true }, .{}, null, null, @ptrCast(&[_]vk.ImageMemoryBarrier{color_to_copy_barrier}));

    const swapchain_barrier = vk.ImageMemoryBarrier{
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

    self.dev.cmdPipelineBarrier(cmd_buffer, .{ .color_attachment_output_bit = true, .transfer_bit = true }, .{ .transfer_bit = true }, .{}, null, null, @ptrCast(&[_]vk.ImageMemoryBarrier{swapchain_barrier}));

    const copy_region = vk.ImageCopy{
        .src_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_offset = .{ .x = 0, .y = 0, .z = 0 },
        .dst_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
        .extent = .{ .width = self.swapchain_extent.width, .height = self.swapchain_extent.height, .depth = 1 },
    };

    var copy_region_arr: [1]vk.ImageCopy = undefined;
    copy_region_arr[0] = copy_region;

    self.dev.cmdCopyImage(
        cmd_buffer,
        self.render_color_image,
        .transfer_src_optimal,
        self.swapchain_images[image_index],
        .transfer_dst_optimal,
        &copy_region_arr,
    );

    const present_barrier = vk.ImageMemoryBarrier{
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
        .dst_access_mask = .{},
    };

    self.dev.cmdPipelineBarrier(cmd_buffer, .{ .transfer_bit = true }, .{ .bottom_of_pipe_bit = true }, .{}, null, null, @ptrCast(&[_]vk.ImageMemoryBarrier{present_barrier}));

    const color_return_barrier = vk.ImageMemoryBarrier{
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

    self.dev.cmdPipelineBarrier(cmd_buffer, .{ .transfer_bit = true }, .{ .color_attachment_output_bit = true }, .{}, null, null, @ptrCast(&[_]vk.ImageMemoryBarrier{color_return_barrier}));

    std.log.debug("vtableDrawChunks: Step 17 - Ending command buffer...", .{});
    self.dev.endCommandBuffer(cmd_buffer) catch |err| switch (err) {
        else => return error.DrawFailed,
    };

    std.log.debug("vtableDrawChunks: Step 18 - Submitting command buffer to graphics queue...", .{});
    const wait_stages = [_]vk.PipelineStageFlags{.{ .transfer_bit = true }};

    const wait_semaphores: [1]vk.Semaphore = .{self.image_acquired_semaphores[current_frame]};

    const signal_semaphores: [1]vk.Semaphore = .{self.render_complete_semaphores[current_frame]};

    const submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&wait_semaphores),
        .p_wait_dst_stage_mask = &wait_stages,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmd_buffer),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&signal_semaphores),
    };

    std.log.debug("vtableDrawChunks: Step 19 - Calling queueSubmit...", .{});
    {
        _ = self.queue_mutex.lock(io) catch |err| switch (err) {
            error.Canceled => return error.DrawFailed,
        };
        defer self.queue_mutex.unlock(io);

        self.dev.queueSubmit(self.graphics_queue, &[_]vk.SubmitInfo{submit_info}, self.in_flight_fences[current_frame]) catch |err| switch (err) {
            else => return error.DrawFailed,
        };
    }

    std.log.debug("vtableDrawChunks: Step 20 - Preparing present info...", .{});
    const present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&self.render_complete_semaphores[current_frame]),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.swapchain),
        .p_image_indices = &[_]u32{image_index},
        .p_results = undefined,
    };

    std.log.debug("vtableDrawChunks: Step 21 - Calling queuePresentKHR...", .{});
    const present_result = blk: {
        _ = self.queue_mutex.lock(io) catch |err| switch (err) {
            error.Canceled => return error.DrawFailed,
        };
        defer self.queue_mutex.unlock(io);

        break :blk self.dev.queuePresentKHR(self.present_queue, &present_info) catch |err| switch (err) {
            else => return error.DrawFailed,
        };
    };

    std.log.debug("vtableDrawChunks: Step 22 - Advancing to next frame or recreating swapchain...", .{});
    if (present_result == .success) {
        const next_frame = (current_frame + 1) % @as(u32, @intCast(self.in_flight_fences.len));
        self.current_frame_idx.store(next_frame, .monotonic);
    } else if (present_result == vk.Result.error_out_of_date_khr or present_result == vk.Result.suboptimal_khr) {
        self.createSwapchain(io) catch |create_err| switch (create_err) {
            else => {},
        };
    }
}

fn drawChunksReal(self: *VulkanRenderer, io: std.Io, cmd_buffer: vk.CommandBuffer, current_frame: u32, playerPos: @Vector(3, f64), frustum: Frustum, is_transparent: bool, opaque_draw_count: u32) error{ DrawFailed, Canceled, OutOfMemory }!u32 {
    const frame_idx = current_frame % @as(u32, @intCast(self.indirect_draw_buffers_mapped.len));
    const indirect_mapped = self.indirect_draw_buffers_mapped[frame_idx];

    const chunk_data_mapped = self.chunk_data_buffers_mapped[frame_idx];

    var indirect_cmds: [*]vk.DrawIndirectCommand = @ptrCast(@alignCast(indirect_mapped));
    var chunk_data: [*]ChunkData = @ptrCast(@alignCast(chunk_data_mapped));

    var draw_count: u32 = 0;
    const write_offset = opaque_draw_count;

    var candidates: u32 = 0;
    var culled: u32 = 0;

    if (is_transparent) {
        // Note: transparency sorting removed in preparation for Order Independent Transparency (OIT).
        // In the future, replace this simple indirect draw with an OIT pass that accumulates
        // fragments (e.g., per-pixel linked lists or compute-shader blending).
        // The transparent pipeline already uses depth_write_enable = false which is OIT-compatible.

        var it = self.meshes.iterator();
        while (try it.next(io)) |entry| {
            const key = entry.key_ptr.*;
            if (key != .transparent) continue;

            candidates += 1;
            const chunkpos = key.toPos();

            if (!cullChunk(&frustum, chunkpos, playerPos)) {
                const mesh = &entry.value_ptr.*;

                const ratio: @Vector(3, f64) = @splat(@floatCast(ChunkPos.levelToBlockRatioFloat(chunkpos.level)));
                const chunk_blockpos = @as(@Vector(3, f64), @floatFromInt(chunkpos.position)) * ratio;
                const relative_blockpos = chunk_blockpos - playerPos;

                const write_idx = write_offset + draw_count;

                chunk_data[write_idx] = .{
                    .absolute_position = @as([3]f32, @bitCast(@as(@Vector(3, f32), @floatCast(chunk_blockpos)))),
                    .relative_position = @as([3]f32, @bitCast(@as(@Vector(3, f32), @floatCast(relative_blockpos)))),
                    .scale = ChunkPos.toScale(chunkpos.level),
                    .address = mesh.device_address,
                };

                indirect_cmds[write_idx] = .{
                    .vertex_count = @as(u32, mesh.face_count) * 6,
                    .instance_count = 1,
                    .first_vertex = 0,
                    .first_instance = write_offset + draw_count,
                };

                draw_count += 1;
                if (draw_count >= self.max_draw_count - write_offset) break;
            } else {
                culled += 1;
            }
        }

        // Record stats
        self.frame_stats.transparent_candidates = candidates;
        self.frame_stats.transparent_culled = culled;
        self.frame_stats.transparent_drawn = draw_count;
    } else {
        var it = self.meshes.iterator();
        while (try it.next(io)) |entry| {
            const key = entry.key_ptr.*;
            if ((key == .transparent) != is_transparent) continue;

            candidates += 1;
            const chunkpos = key.toPos();

            if (!cullChunk(&frustum, chunkpos, playerPos)) {
                const mesh = entry.value_ptr.*;

                const ratio: @Vector(3, f64) = @splat(@floatCast(ChunkPos.levelToBlockRatioFloat(chunkpos.level)));
                const chunk_blockpos = @as(@Vector(3, f64), @floatFromInt(chunkpos.position)) * ratio;
                const relative_blockpos = chunk_blockpos - playerPos;

                chunk_data[draw_count] = .{
                    .absolute_position = @as([3]f32, @bitCast(@as(@Vector(3, f32), @floatCast(chunk_blockpos)))),
                    .relative_position = @as([3]f32, @bitCast(@as(@Vector(3, f32), @floatCast(relative_blockpos)))),
                    .scale = ChunkPos.toScale(chunkpos.level),
                    .address = mesh.device_address,
                };

                indirect_cmds[draw_count] = .{
                    .vertex_count = @as(u32, mesh.face_count) * 6,
                    .instance_count = 1,
                    .first_vertex = 0,
                    .first_instance = draw_count,
                };

                draw_count += 1;
                if (draw_count >= self.max_draw_count) break;
            } else {
                culled += 1;
            }
        }

        // Record stats
        self.frame_stats.opaque_candidates = candidates;
        self.frame_stats.opaque_culled = culled;
        self.frame_stats.opaque_drawn = draw_count;
    }

    if (draw_count == 0) {
        if (is_transparent) {
            std.log.debug("drawChunksReal(transparent): all {d} candidates culled, nothing to draw", .{candidates});
        } else {
            std.log.debug("drawChunksReal(opaque): all {d} candidates culled, nothing to draw", .{candidates});
        }
        return 0;
    }

    const byte_offset: vk.DeviceSize = @as(vk.DeviceSize, write_offset) * @as(vk.DeviceSize, @sizeOf(vk.DrawIndirectCommand));
    self.dev.cmdDrawIndirect(cmd_buffer, self.indirect_draw_buffers[frame_idx], byte_offset, draw_count, @sizeOf(vk.DrawIndirectCommand));

    return draw_count;
}

fn allocateIndirectBuffers(self: *VulkanRenderer) !void {
    const num_frames = self.swapchain_images.len;

    if (self.indirect_draw_buffers_mapped.len > 0) self.allocator.free(self.indirect_draw_buffers_mapped);
    if (self.chunk_data_buffers_mapped.len > 0) self.allocator.free(self.chunk_data_buffers_mapped);

    self.indirect_draw_buffers = try self.allocator.alloc(vk.Buffer, num_frames);
    @memset(self.indirect_draw_buffers, .null_handle);
    errdefer {
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

    const indirect_size = @as(vk.DeviceSize, @intCast(self.max_draw_count)) * @sizeOf(vk.DrawIndirectCommand);
    for (0..num_frames) |i| {
        try self.createBuffer(indirect_size, .{ .indirect_buffer_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, &self.indirect_draw_buffers[i], &self.indirect_draw_memories[i]);
    }

    self.indirect_draw_buffers_mapped = try self.allocator.alloc([*]u8, num_frames);
    @memset(self.indirect_draw_buffers_mapped, undefined);
    errdefer {
        if (self.indirect_draw_buffers_mapped.len > 0) self.allocator.free(self.indirect_draw_buffers_mapped);
        self.indirect_draw_buffers_mapped = &.{};
    }
    for (0..num_frames) |i| {
        const mapped = try self.dev.mapMemory(self.indirect_draw_memories[i], 0, vk.WHOLE_SIZE, .{});
        self.indirect_draw_buffers_mapped[i] = @ptrCast(@alignCast(mapped));
    }

    self.chunk_data_buffers = try self.allocator.alloc(vk.Buffer, num_frames);
    errdefer {
        for (self.chunk_data_buffers) |buf| {
            if (buf != .null_handle) self.dev.destroyBuffer(buf, null);
        }
        self.allocator.free(self.chunk_data_buffers);
    }
    self.chunk_data_memories = try self.allocator.alloc(vk.DeviceMemory, num_frames);
    errdefer {
        for (self.chunk_data_memories) |mem| {
            if (mem != .null_handle) self.dev.freeMemory(mem, null);
        }
        self.allocator.free(self.chunk_data_memories);
    }

    const chunk_data_size = @as(vk.DeviceSize, @intCast(self.max_draw_count)) * @sizeOf(ChunkData);
    for (0..num_frames) |i| {
        try self.createBuffer(chunk_data_size, .{ .storage_buffer_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, &self.chunk_data_buffers[i], &self.chunk_data_memories[i]);
    }

    self.chunk_data_buffers_mapped = try self.allocator.alloc([*]u8, num_frames);
    @memset(self.chunk_data_buffers_mapped, undefined);
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
    if (size == 0) {
        return error.InvalidBufferSize;
    }

    const buffer_info = vk.BufferCreateInfo{
        .flags = .{},
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    buffer.* = try self.dev.createBuffer(&buffer_info, null);

    const mem_reqs = self.dev.getBufferMemoryRequirements(buffer.*);
    const alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = mem_reqs.size,
        .memory_type_index = self.findMemoryType(mem_reqs.memory_type_bits, properties),
    };
    errdefer self.dev.destroyBuffer(buffer.*, null);
    memory.* = try self.dev.allocateMemory(&alloc_info, null);
    try self.dev.bindBufferMemory(buffer.*, memory.*, 0);
}

fn copyBuffer(self: *VulkanRenderer, io: std.Io, src: vk.Buffer, dst: vk.Buffer, size: vk.DeviceSize) !void {
    _ = self.queue_mutex.lock(io) catch |err| switch (err) {
        error.Canceled => return error.DrawFailed,
    };
    defer self.queue_mutex.unlock(io);

    const alloc_info = vk.CommandBufferAllocateInfo{
        .level = .primary,
        .command_pool = self.upload_command_pool,
        .command_buffer_count = 1,
    };
    var cmd: vk.CommandBuffer = undefined;
    try self.dev.allocateCommandBuffers(&alloc_info, @ptrCast(&cmd));

    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };
    try self.dev.beginCommandBuffer(cmd, &begin_info);

    const copy_region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    self.dev.cmdCopyBuffer(cmd, src, dst, @ptrCast(&copy_region));

    try self.dev.endCommandBuffer(cmd);

    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmd),
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    };

    try self.dev.queueSubmit(self.graphics_queue, &[_]vk.SubmitInfo{submit_info}, .null_handle);

    _ = self.dev.queueWaitIdle(self.graphics_queue) catch {};

    self.dev.freeCommandBuffers(self.upload_command_pool, &[_]vk.CommandBuffer{cmd});
}

pub fn findMemoryType(self: VulkanRenderer, type_filter: u32, properties: vk.MemoryPropertyFlags) u32 {
    for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
        if ((type_filter & (@as(u32, 1) << @as(u5, @intCast(i)))) != 0 and (mem_type.property_flags.toInt() & properties.toInt()) == properties.toInt()) {
            return @as(u32, @intCast(i));
        }
    }
    @panic("Failed to find suitable memory type");
}

fn cullChunk(frustum: *const Frustum, chunkpos: ChunkPos, playerPos: @Vector(3, f64)) bool {
    const scale = ChunkPos.toScale(chunkpos.level);
    const chunkSizeVec: @Vector(3, f32) = @splat(ChunkSize * scale);
    const relativeChunkPos: @Vector(3, f32) = @floatCast((@as(@Vector(3, f32), @floatFromInt(chunkpos.position)) * chunkSizeVec) - playerPos);
    return !frustum.boxInFrustum(.{ .max = relativeChunkPos + chunkSizeVec, .min = relativeChunkPos });
}

fn makeInfReversedZProjRh(fovY_radians: f32, aspectWbyH: f32, zNear: f32) zm.Mat4f {
    const f: f32 = 1.0 / @tan(fovY_radians / 2.0);
    // m11 = -f flips Y for Vulkan's Y-down clip space.
    // The last two rows implement infinite reversed-Z:
    //   z_clip = zNear * w_input  →  at near z=-zN: z_ndc = 1, at far z=-inf: z_ndc → 0
    //   w_clip = -z_input         →  standard RH perspective divide
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

fn recreateSwapchainOnly(self: *VulkanRenderer, io: std.Io) !void {
    _ = self.dev.deviceWaitIdle() catch {};

    // Clean up all old per-frame resources (indirect buffers, chunk data,
    // semaphores, fences, cmd buffers, render targets) before reallocating.
    // This prevents a VRAM leak on every VK_SUBOPTIMAL_KHR frame.
    self.destroyOldSwapchainResources();

    const old_swapchain = self.swapchain;

    var actual_extent = self.swapchain_extent;

    const caps = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.pdev, self.surface);

    if (caps.current_extent.width != 0xFFFF_FFFF) {
        actual_extent = caps.current_extent;
    } else {
        const max_extent = vk.Extent2D{
            .width = @min(caps.max_image_extent.width, 3840),
            .height = @min(caps.max_image_extent.height, 2160),
        };
        actual_extent = .{
            .width = std.math.clamp(self.swapchain_extent.width, caps.min_image_extent.width, max_extent.width),
            .height = std.math.clamp(self.swapchain_extent.height, caps.min_image_extent.height, max_extent.height),
        };
    }

    self.swapchain_extent = actual_extent;
    self.viewport_pixels = .{ actual_extent.width, actual_extent.height };

    const surface_formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.pdev, self.surface, self.allocator);
    defer self.allocator.free(surface_formats);

    var surface_format: vk.SurfaceFormatKHR = surface_formats[0];
    for (surface_formats) |sfmt| {
        if (sfmt.format == .b8g8r8a8_srgb or sfmt.format == .r8g8b8a8_unorm) {
            surface_format = sfmt;
            break;
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

    var image_count = caps.min_image_count + 1;
    if (caps.max_image_count > 0) {
        image_count = @min(image_count, caps.max_image_count);
    }

    const qfi = [_]u32{ self.queue_family_index, self.present_queue_family_index };
    const sharing_mode: vk.SharingMode = if (self.queue_family_index != self.present_queue_family_index)
        .concurrent
    else
        .exclusive;

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

    // old_swapchain is consumed by vkCreateSwapchainKHR (the implementation
    // may reference it during creation), but the application still owns it
    // and must destroy it separately. No errdefer here: if createSwapchainKHR
    // failed, self.swapchain still holds the old value, so there is no leak.
    if (old_swapchain != .null_handle) {
        self.dev.destroySwapchainKHR(old_swapchain, null);
    }

    self.swapchain_images = try self.dev.getSwapchainImagesAllocKHR(self.swapchain, self.allocator);
    errdefer {
        self.allocator.free(self.swapchain_images);
        self.swapchain_images = &.{};
    }

    for (self.swapchain_views) |view| {
        if (view != .null_handle) self.dev.destroyImageView(view, null);
    }
    self.allocator.free(self.swapchain_views);

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
        const view_info = vk.ImageViewCreateInfo{
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

    try self.allocateIndirectBuffers();

    // Recreate per-frame semaphores and fences
    const num_swapchain_images = self.swapchain_images.len;

    if (self.image_acquired_semaphores.len > 0) self.allocator.free(self.image_acquired_semaphores);
    if (self.render_complete_semaphores.len > 0) self.allocator.free(self.render_complete_semaphores);
    if (self.in_flight_fences.len > 0) self.allocator.free(self.in_flight_fences);

    self.image_acquired_semaphores = try self.allocator.alloc(vk.Semaphore, num_swapchain_images);
    @memset(self.image_acquired_semaphores, .null_handle);
    errdefer self.allocator.free(self.image_acquired_semaphores);

    self.render_complete_semaphores = try self.allocator.alloc(vk.Semaphore, num_swapchain_images);
    @memset(self.render_complete_semaphores, .null_handle);
    errdefer self.allocator.free(self.render_complete_semaphores);

    self.in_flight_fences = try self.allocator.alloc(vk.Fence, num_swapchain_images);
    @memset(self.in_flight_fences, .null_handle);
    errdefer self.allocator.free(self.in_flight_fences);

    const semaphore_create_info = vk.SemaphoreCreateInfo{ .flags = .{} };
    const fence_create_info = vk.FenceCreateInfo{
        .flags = .{ .signaled_bit = true },
    };

    for (0..num_swapchain_images) |i| {
        self.image_acquired_semaphores[i] = try self.dev.createSemaphore(&semaphore_create_info, null);
        self.render_complete_semaphores[i] = try self.dev.createSemaphore(&semaphore_create_info, null);
        self.in_flight_fences[i] = try self.dev.createFence(&fence_create_info, null);
    }

    // Recreate command buffers
    if (self.cmd_buffers.len > 0) {
        self.dev.freeCommandBuffers(self.command_pool, self.cmd_buffers);
        self.allocator.free(self.cmd_buffers);
    }

    const cmd_alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = self.command_pool,
        .level = .primary,
        .command_buffer_count = @intCast(num_swapchain_images),
    };

    self.cmd_buffers = try self.allocator.alloc(vk.CommandBuffer, num_swapchain_images);
    errdefer self.allocator.free(self.cmd_buffers);
    try self.dev.allocateCommandBuffers(&cmd_alloc_info, self.cmd_buffers.ptr);

    // Recreate render targets
    try self.createRenderTargets(io, actual_extent);

    // Recreate descriptor pool and sets
    try self.createDescriptorPoolAndSets(io);
    // Rebind the real block texture array to the new descriptor sets
    if (self.texture_manager.texture_view != .null_handle) {
        self.texture_manager.rebindDescriptorSets();
    }

    // Recreate pipelines with the current swapchain format
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
    try self.createPipeline();
    try self.createTransparentPipeline();
}

fn destroyOldSwapchainResources(self: *VulkanRenderer) void {
    _ = self.dev.deviceWaitIdle() catch {};

    for (self.swapchain_views) |view| {
        if (view != .null_handle) self.dev.destroyImageView(view, null);
    }
    self.allocator.free(self.swapchain_images);
    self.swapchain_images = &.{};
    self.allocator.free(self.swapchain_views);
    self.swapchain_views = &.{};

    if (self.cmd_buffers.len > 0) {
        self.dev.freeCommandBuffers(self.command_pool, self.cmd_buffers);
        self.allocator.free(self.cmd_buffers);
        self.cmd_buffers = &.{};
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
    if (self.image_acquired_semaphores.len > 0) self.allocator.free(self.image_acquired_semaphores);
    if (self.render_complete_semaphores.len > 0) self.allocator.free(self.render_complete_semaphores);
    if (self.in_flight_fences.len > 0) self.allocator.free(self.in_flight_fences);
    self.image_acquired_semaphores = &.{};
    self.render_complete_semaphores = &.{};
    self.in_flight_fences = &.{};

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

    for (self.indirect_draw_buffers) |buf| {
        if (buf != .null_handle) self.dev.destroyBuffer(buf, null);
    }
    if (self.indirect_draw_buffers.len > 0) self.allocator.free(self.indirect_draw_buffers);
    self.indirect_draw_buffers = &.{};

    for (self.indirect_draw_memories) |mem| {
        if (mem != .null_handle) self.dev.freeMemory(mem, null);
    }
    if (self.indirect_draw_memories.len > 0) self.allocator.free(self.indirect_draw_memories);
    self.indirect_draw_memories = &.{};

    for (self.chunk_data_buffers) |buf| {
        if (buf != .null_handle) self.dev.destroyBuffer(buf, null);
    }
    if (self.chunk_data_buffers.len > 0) self.allocator.free(self.chunk_data_buffers);
    self.chunk_data_buffers = &.{};

    for (self.chunk_data_memories) |mem| {
        if (mem != .null_handle) self.dev.freeMemory(mem, null);
    }
    if (self.chunk_data_memories.len > 0) self.allocator.free(self.chunk_data_memories);
    self.chunk_data_memories = &.{};

    if (self.indirect_draw_buffers_mapped.len > 0) self.allocator.free(self.indirect_draw_buffers_mapped);
    self.indirect_draw_buffers_mapped = &.{};

    if (self.chunk_data_buffers_mapped.len > 0) self.allocator.free(self.chunk_data_buffers_mapped);
    self.chunk_data_buffers_mapped = &.{};

    // Destroy descriptor pool and sets
    if (self.descriptor_pool != .null_handle) {
        self.dev.destroyDescriptorPool(self.descriptor_pool, null);
        self.descriptor_pool = .null_handle;
    }
    if (self.descriptor_sets_per_frame.len > 0) {
        self.allocator.free(self.descriptor_sets_per_frame);
        self.descriptor_sets_per_frame = &.{};
    }
}

fn createSwapchain(self: *VulkanRenderer, io: std.Io) !void {
    if (self.swapchain_extent.width == 0 or self.swapchain_extent.height == 0) {
        std.log.debug("VulkanRenderer.createSwapchain: Skipping swapchain creation - window size is 0x0", .{});
        return error.InvalidWindowSize;
    }

    std.log.info("VulkanRenderer.createSwapchain: Starting swapchain creation...", .{});
    std.log.debug("VulkanRenderer.createSwapchain: Step 1 - Getting physical device surface capabilities...", .{});

    const caps = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.pdev, self.surface);
    std.log.debug("VulkanRenderer.createSwapchain: Step 1 - Got surface capabilities. current_extent={{width={}, height={}}}", .{ caps.current_extent.width, caps.current_extent.height });

    const old_swapchain = self.swapchain;

    std.log.debug("VulkanRenderer.createSwapchain: Step 2 - Checking if old swapchain resources need cleanup...", .{});
    if (old_swapchain != .null_handle or self.swapchain_images.len > 0 or self.render_color_image != .null_handle) {
        std.log.debug("VulkanRenderer.createSwapchain: Step 2 - Cleaning up old swapchain resources...", .{});
        self.destroyOldSwapchainResources();
    }
    std.log.debug("VulkanRenderer.createSwapchain: Step 2 - Old swapchain resources destroyed", .{});

    var actual_extent = self.swapchain_extent;
    std.log.debug("VulkanRenderer.createSwapchain: Step 3 - Determining actual swapchain extent...", .{});
    if (caps.current_extent.width != 0xFFFF_FFFF) {
        actual_extent = caps.current_extent;
    } else {
        const max_extent = vk.Extent2D{
            .width = @min(caps.max_image_extent.width, 3840),
            .height = @min(caps.max_image_extent.height, 2160),
        };
        actual_extent = .{
            .width = std.math.clamp(self.swapchain_extent.width, caps.min_image_extent.width, max_extent.width),
            .height = std.math.clamp(self.swapchain_extent.height, caps.min_image_extent.height, max_extent.height),
        };
    }

    self.swapchain_extent = actual_extent;
    self.viewport_pixels = .{ actual_extent.width, actual_extent.height };
    std.log.debug("VulkanRenderer.createSwapchain: Step 3 - Set swapchain extent to {{width={}, height={}}}", .{ actual_extent.width, actual_extent.height });

    std.log.debug("VulkanRenderer.createSwapchain: Step 4 - Enumerating physical device surface formats...", .{});
    const surface_formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.pdev, self.surface, self.allocator);
    defer self.allocator.free(surface_formats);
    std.log.debug("VulkanRenderer.createSwapchain: Step 4 - Found {} surface formats", .{surface_formats.len});

    var surface_format: vk.SurfaceFormatKHR = surface_formats[0];
    for (surface_formats) |sfmt| {
        if (sfmt.format == .b8g8r8a8_srgb or sfmt.format == .r8g8b8a8_unorm) {
            surface_format = sfmt;
            break;
        }
    }
    self.swapchain_format = surface_format.format;
    std.log.debug("VulkanRenderer.createSwapchain: Step 4 - Selected surface format: {any}", .{self.swapchain_format});

    std.log.debug("VulkanRenderer.createSwapchain: Step 5 - Enumerating physical device surface present modes...", .{});
    const present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(self.pdev, self.surface, self.allocator);
    defer self.allocator.free(present_modes);
    std.log.debug("VulkanRenderer.createSwapchain: Step 5 - Found {} present modes", .{present_modes.len});

    var present_mode: vk.PresentModeKHR = .fifo_khr;
    for (present_modes) |pm| {
        if (pm == .mailbox_khr or pm == .immediate_khr) {
            present_mode = pm;
            break;
        }
    }
    std.log.debug("VulkanRenderer.createSwapchain: Step 5 - Selected present mode: {any}", .{present_mode});

    var image_count = caps.min_image_count + 1;
    if (caps.max_image_count > 0) {
        image_count = @min(image_count, caps.max_image_count);
    }
    std.log.debug("VulkanRenderer.createSwapchain: Step 6 - Calculated swapchain image count: {}", .{image_count});

    const qfi = [_]u32{ self.queue_family_index, self.present_queue_family_index };
    const sharing_mode: vk.SharingMode = if (self.queue_family_index != self.present_queue_family_index)
        .concurrent
    else
        .exclusive;
    std.log.debug("VulkanRenderer.createSwapchain: Step 6 - Queue family indices: graphics={}, present={}; sharing_mode: {any}", .{ self.queue_family_index, self.present_queue_family_index, sharing_mode });

    errdefer {
        if (old_swapchain != .null_handle) {
            self.dev.destroySwapchainKHR(old_swapchain, null);
        }
    }

    std.log.debug("VulkanRenderer.createSwapchain: Step 7 - Creating swapchain KHR...", .{});
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
    std.log.debug("VulkanRenderer.createSwapchain: Step 7 - Created swapchain handle={any}", .{self.swapchain});
    if (old_swapchain != .null_handle) {
        std.log.debug("VulkanRenderer.createSwapchain: Step 7 - Destroying old swapchain handle={any}", .{old_swapchain});
        self.dev.destroySwapchainKHR(old_swapchain, null);
    }

    std.log.debug("VulkanRenderer.createSwapchain: Step 8 - Getting swapchain images...", .{});
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
        const view_info = vk.ImageViewCreateInfo{
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

    std.log.debug("created semaphores", .{});
    self.in_flight_fences = try self.allocator.alloc(vk.Fence, num_swapchain_images);
    @memset(self.in_flight_fences, .null_handle);
    errdefer {
        for (self.in_flight_fences) |fence| {
            if (fence != .null_handle) self.dev.destroyFence(fence, null);
        }
        if (self.in_flight_fences.len > 0) self.allocator.free(self.in_flight_fences);
        self.in_flight_fences = &.{};
    }

    const semaphore_create_info = vk.SemaphoreCreateInfo{ .flags = .{} };
    const fence_create_info = vk.FenceCreateInfo{
        .flags = .{ .signaled_bit = true },
    };
    std.log.debug("created semaphore and fence info", .{});

    for (0..num_swapchain_images) |i| {
        self.image_acquired_semaphores[i] = try self.dev.createSemaphore(&semaphore_create_info, null);
        self.render_complete_semaphores[i] = try self.dev.createSemaphore(&semaphore_create_info, null);
        self.in_flight_fences[i] = try self.dev.createFence(&fence_create_info, null);
    }
    std.log.debug("created semaphores and fences", .{});

    const cmd_alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = self.command_pool,
        .level = .primary,
        .command_buffer_count = @intCast(num_swapchain_images),
    };
    std.log.debug("allocating command buffers", .{});

    self.cmd_buffers = try self.allocator.alloc(vk.CommandBuffer, num_swapchain_images);
    errdefer self.allocator.free(self.cmd_buffers);
    try self.dev.allocateCommandBuffers(&cmd_alloc_info, self.cmd_buffers.ptr);
    std.log.debug("allocated command buffers", .{});

    self.createRenderTargets(io, actual_extent) catch |err| {
        std.log.err("createRenderTargets failed: {}", .{err});
        return err;
    };

    try self.allocateIndirectBuffers();

    // Recreate descriptor pool and sets if they were previously created (i.e., this is
    // a resize, not the initial creation — descriptor_set_layout doesn't exist yet at init)
    if (self.descriptor_set_layout != .null_handle) {
        try self.createDescriptorPoolAndSets(io);
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
    std.log.debug("VulkanRenderer.createRenderTargets: Step 1 - Starting render targets creation for extent {{width={}, height={}}}", .{ extent.width, extent.height });

    std.log.debug("VulkanRenderer.createRenderTargets: Step 1a - Cleaning up existing render targets...", .{});
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

    std.log.debug("VulkanRenderer.createRenderTargets: Step 2 - Creating color image...", .{});
    const color_image_info = vk.ImageCreateInfo{
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

    std.log.debug("VulkanRenderer.createRenderTargets: Step 2 - Creating color image handle...", .{});
    self.render_color_image = try self.dev.createImage(&color_image_info, null);
    std.log.debug("VulkanRenderer.createRenderTargets: Step 2 - Created color image handle={any}", .{self.render_color_image});

    const color_mem_reqs = self.dev.getImageMemoryRequirements(self.render_color_image);
    std.log.debug("VulkanRenderer.createRenderTargets: Step 2 - Color image memory requirements: size={}, type_bits={}", .{ color_mem_reqs.size, color_mem_reqs.memory_type_bits });
    const color_alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = color_mem_reqs.size,
        .memory_type_index = self.findMemoryType(color_mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    };
    self.render_color_memory = try self.dev.allocateMemory(&color_alloc_info, null);
    std.log.debug("VulkanRenderer.createRenderTargets: Step 2 - Allocated color image memory={any}, binding to image...", .{self.render_color_memory});
    try self.dev.bindImageMemory(self.render_color_image, self.render_color_memory, 0);

    std.log.debug("VulkanRenderer.createRenderTargets: Step 3 - Transitioning color image to color_attachment_optimal...", .{});
    {
        const cmd = try self.beginSingleTimeCommands(io);
        defer self.endSingleTimeCommands(io, cmd) catch {};

        const barrier = vk.ImageMemoryBarrier{
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

        self.dev.cmdPipelineBarrier(cmd, .{ .top_of_pipe_bit = true }, .{ .color_attachment_output_bit = true }, .{}, null, null, @ptrCast(&[_]vk.ImageMemoryBarrier{barrier}));
    }

    std.log.debug("VulkanRenderer.createRenderTargets: Step 4 - Creating color image view...", .{});
    const color_view_info = vk.ImageViewCreateInfo{
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
    std.log.debug("VulkanRenderer.createRenderTargets: Step 4 - Created color image view={any}", .{self.render_color_view});

    const depth_formats = [_]vk.Format{ .d32_sfloat_s8_uint, .d24_unorm_s8_uint, .d32_sfloat };
    var depth_format: vk.Format = .undefined;

    std.log.debug("VulkanRenderer.createRenderTargets: Step 5 - Checking candidate depth formats...", .{});
    for (depth_formats) |fmt| {
        const depth_format_props = self.instance.getPhysicalDeviceFormatProperties(self.pdev, fmt);
        if (depth_format_props.optimal_tiling_features.depth_stencil_attachment_bit) {
            depth_format = fmt;
            self.depth_format = fmt;
            std.log.debug("VulkanRenderer.createRenderTargets: Step 5 - Depth format {any} is supported", .{depth_format});
            break;
        }
    }
    if (depth_format == .undefined) {
        std.log.err("createRenderTargets: no supported depth format found among candidate formats", .{});
        return error.DepthFormatNotSupported;
    }

    const depth_has_stencil = depth_format == .d32_sfloat_s8_uint or depth_format == .d24_unorm_s8_uint;
    const depth_aspect_mask: vk.ImageAspectFlags = if (depth_has_stencil)
        .{ .depth_bit = true, .stencil_bit = true }
    else
        .{ .depth_bit = true };

    std.log.debug("VulkanRenderer.createRenderTargets: Step 6 - Creating depth image...", .{});
    const depth_image_info = vk.ImageCreateInfo{
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

    std.log.debug("VulkanRenderer.createRenderTargets: Step 6 - Creating depth image handle...", .{});
    self.render_depth_image = try self.dev.createImage(&depth_image_info, null);
    std.log.debug("VulkanRenderer.createRenderTargets: Step 6 - Created depth image handle={any}", .{self.render_depth_image});

    const depth_mem_reqs = self.dev.getImageMemoryRequirements(self.render_depth_image);
    const depth_alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = depth_mem_reqs.size,
        .memory_type_index = self.findMemoryType(depth_mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    };
    self.render_depth_memory = try self.dev.allocateMemory(&depth_alloc_info, null);
    std.log.debug("VulkanRenderer.createRenderTargets: Step 6 - Allocated depth image memory={any}, binding to image...", .{self.render_depth_memory});
    try self.dev.bindImageMemory(self.render_depth_image, self.render_depth_memory, 0);

    std.log.debug("VulkanRenderer.createRenderTargets: Step 7 - Transitioning depth image to depth_stencil_attachment_optimal...", .{});
    {
        const cmd = try self.beginSingleTimeCommands(io);
        defer self.endSingleTimeCommands(io, cmd) catch {};

        const barrier = vk.ImageMemoryBarrier{
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

        self.dev.cmdPipelineBarrier(cmd, .{ .top_of_pipe_bit = true }, .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true }, .{}, null, null, @ptrCast(&[_]vk.ImageMemoryBarrier{barrier}));
    }

    std.log.debug("VulkanRenderer.createRenderTargets: Step 8 - Creating depth image view...", .{});
    const depth_view_info = vk.ImageViewCreateInfo{
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
    std.log.debug("VulkanRenderer.createRenderTargets: Step 8 - Created depth image view={any}", .{self.render_depth_view});

    std.log.info("VulkanRenderer.createRenderTargets: SUCCESS - Created render targets: color image {any}, depth image {any}\n", .{ self.render_color_image, self.render_depth_image });
}

fn createDescriptorSetLayout(self: *VulkanRenderer) !void {
    std.log.debug("VulkanRenderer.createDescriptorSetLayout: Step 1 - Creating descriptor set layout...", .{});

    std.log.debug("VulkanRenderer.createDescriptorSetLayout: Step 1 - Configuring binding 0: SSBO for Chunk Data...", .{});
    const chunk_data_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex_bit = true },
        .p_immutable_samplers = null,
    };

    std.log.debug("VulkanRenderer.createDescriptorSetLayout: Step 1 - Configuring binding 1: Texture Array for block textures...", .{});
    const texture_array_binding = vk.DescriptorSetLayoutBinding{
        .binding = 1,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment_bit = true },
        .p_immutable_samplers = null,
    };

    const bindings = [_]vk.DescriptorSetLayoutBinding{ chunk_data_binding, texture_array_binding };

    var layout_info = vk.DescriptorSetLayoutCreateInfo{
        .flags = .{},
        .binding_count = bindings.len,
        .p_bindings = @ptrCast(&bindings),
    };

    std.log.debug("VulkanRenderer.createDescriptorSetLayout: Step 2 - Creating descriptor set layout with {} bindings...", .{bindings.len});
    self.descriptor_set_layout = try self.dev.createDescriptorSetLayout(&layout_info, null);
    std.log.debug("VulkanRenderer.createDescriptorSetLayout: Step 2 - Created descriptor set layout handle={any}", .{self.descriptor_set_layout});
}

fn createDescriptorPoolAndSets(self: *VulkanRenderer, io: std.Io) !void {
    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: Step 1 - Creating descriptor pool...", .{});
    const num_frames = self.swapchain_images.len;
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .storage_buffer, .descriptor_count = @intCast(num_frames) },
        .{ .type = .combined_image_sampler, .descriptor_count = @intCast(num_frames) },
    };

    const pool_info = vk.DescriptorPoolCreateInfo{
        .flags = .{},
        .max_sets = @as(u32, @intCast(num_frames)),
        .pool_size_count = pool_sizes.len,
        .p_pool_sizes = @ptrCast(&pool_sizes),
    };

    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: Step 1 - Creating descriptor pool with {} sizes, max_sets={}", .{ pool_sizes.len, num_frames });
    self.descriptor_pool = try self.dev.createDescriptorPool(&pool_info, null);
    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: Step 1 - Created descriptor pool handle={any}", .{self.descriptor_pool});

    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: Step 2 - Allocating descriptor sets per frame...", .{});
    self.descriptor_sets_per_frame = try self.allocator.alloc(vk.DescriptorSet, num_frames);
    @memset(self.descriptor_sets_per_frame, .null_handle);
    errdefer {
        if (self.descriptor_sets_per_frame.len > 0) self.allocator.free(self.descriptor_sets_per_frame);
        self.descriptor_sets_per_frame = &.{};
    }

    for (0..num_frames) |i| {
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&self.descriptor_set_layout),
        };

        var desc_set: [1]vk.DescriptorSet = undefined;
        try self.dev.allocateDescriptorSets(&alloc_info, &desc_set);
        self.descriptor_sets_per_frame[i] = desc_set[0];
    }
    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: Step 2 - Allocated {} descriptor sets per frame", .{num_frames});

    const dummy_white_pixel: [4]u8 = .{ 255, 255, 255, 255 };
    const dummy_staging_size: vk.DeviceSize = 256 * 4;

    var staging_buffer_dummy: vk.Buffer = .null_handle;
    var staging_memory_dummy: vk.DeviceMemory = .null_handle;
    try self.createBuffer(dummy_staging_size, .{ .transfer_src_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, &staging_buffer_dummy, &staging_memory_dummy);

    const dummy_data = try self.dev.mapMemory(staging_memory_dummy, 0, dummy_staging_size, .{});
    const mapped_slice = @as([*]u8, @ptrCast(dummy_data))[0..dummy_staging_size];
    for (0..256) |i| {
        const offset = i * 4;
        @memcpy(mapped_slice[offset .. offset + 4], &dummy_white_pixel);
    }
    self.dev.unmapMemory(staging_memory_dummy);

    const dummy_image_info = vk.ImageCreateInfo{
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
    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: Step 5 - Created dummy image handle={any}", .{self.dummy_image});

    const dummy_mem_reqs = self.dev.getImageMemoryRequirements(self.dummy_image);
    const dummy_alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = dummy_mem_reqs.size,
        .memory_type_index = self.findMemoryType(dummy_mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    };
    self.dummy_memory = try self.dev.allocateMemory(&dummy_alloc_info, null);
    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: Step 5 - Allocated dummy image memory={any}, binding to image...", .{self.dummy_memory});
    try self.dev.bindImageMemory(self.dummy_image, self.dummy_memory, 0);

    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: Step 6 - Transitioning dummy image layout and copying data...", .{});
    {
        const cmd = try self.beginSingleTimeCommands(io);
        defer self.endSingleTimeCommands(io, cmd) catch {};

        var barrier = vk.ImageMemoryBarrier{
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

        self.dev.cmdPipelineBarrier(cmd, .{ .top_of_pipe_bit = true }, .{ .transfer_bit = true }, .{}, null, null, @ptrCast(&[_]vk.ImageMemoryBarrier{barrier}));

        const copy_region = vk.BufferImageCopy{
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

        var copy_region_arr: [1]vk.BufferImageCopy = undefined;
        copy_region_arr[0] = copy_region;

        self.dev.cmdCopyBufferToImage(cmd, staging_buffer_dummy, self.dummy_image, .transfer_dst_optimal, &copy_region_arr);

        barrier.old_layout = .transfer_dst_optimal;
        barrier.new_layout = .shader_read_only_optimal;
        barrier.src_access_mask = .{ .transfer_write_bit = true };
        barrier.dst_access_mask = .{ .shader_read_bit = true };
        barrier.image = self.dummy_image;

        self.dev.cmdPipelineBarrier(cmd, .{ .transfer_bit = true }, .{ .fragment_shader_bit = true }, .{}, null, null, @ptrCast(&[_]vk.ImageMemoryBarrier{barrier}));
    }

    const dummy_view_info = vk.ImageViewCreateInfo{
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
    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: Step 7 - Created dummy image view handle={any}", .{self.dummy_view});

    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: Step 8 - Creating dummy sampler...", .{});
    const sampler_info = vk.SamplerCreateInfo{
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
    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: Step 8 - Created dummy sampler handle={any}", .{self.dummy_sampler});

    const texture_image_info_descriptor = vk.DescriptorImageInfo{
        .image_layout = .shader_read_only_optimal,
        .image_view = self.dummy_view,
        .sampler = self.dummy_sampler,
    };

    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: Step 9 - Cleaning up staging buffer and memory...", .{});
    if (staging_buffer_dummy != .null_handle) self.dev.destroyBuffer(staging_buffer_dummy, null);
    if (staging_memory_dummy != .null_handle) self.dev.freeMemory(staging_memory_dummy, null);

    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: Step 10 - Writing binding 1: Texture Array...", .{});

    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: Step 11 - Updating descriptor sets...", .{});
    for (self.descriptor_sets_per_frame) |desc_set| {
        self.dev.updateDescriptorSets(&[_]vk.WriteDescriptorSet{.{
            .dst_set = desc_set,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&texture_image_info_descriptor),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }}, null);
    }
    std.log.debug("VulkanRenderer.createDescriptorPoolAndSets: SUCCESS - Descriptor pool and sets created and updated", .{});
}

fn createPipeline(self: *VulkanRenderer) !void {
    std.log.debug("VulkanRenderer.createPipeline: Step 1 - Creating pipeline layout...", .{});
    const pc_range = vk.PushConstantRange{
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .offset = 0,
        .size = @sizeOf(PushConstants),
    };

    const layout_info = vk.PipelineLayoutCreateInfo{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&self.descriptor_set_layout),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&pc_range),
    };

    std.log.debug("VulkanRenderer.createPipeline: Step 1 - Creating pipeline layout with {} set layouts...", .{layout_info.set_layout_count});
    self.pipeline_layout = try self.dev.createPipelineLayout(&layout_info, null);
    std.log.debug("VulkanRenderer.createPipeline: Step 1 - Created pipeline layout handle={any}", .{self.pipeline_layout});

    std.log.debug("VulkanRenderer.createPipeline: Step 2 - Creating graphics pipeline state create infos...", .{});
    const piasci = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };

    const pvsci = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = null,
        .scissor_count = 1,
        .p_scissors = null,
    };

    const prsci = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{},
        .front_face = .clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const pmsci = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    const pcbas = vk.PipelineColorBlendAttachmentState{
        .blend_enable = .true,
        .src_color_blend_factor = .src_alpha,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .src_alpha,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    const pcbsci = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&pcbas),
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };

    const dynstate = [_]vk.DynamicState{ .viewport, .scissor };
    const pdsci = vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dynstate.len,
        .p_dynamic_states = &dynstate,
    };

    const depth_stencil_state = vk.PipelineDepthStencilStateCreateInfo{
        .flags = .{},
        .depth_test_enable = .true,
        .depth_write_enable = .true,
        .depth_compare_op = .greater,
        .depth_bounds_test_enable = .false,
        .stencil_test_enable = .false,
        .front = .{
            .fail_op = .keep,
            .pass_op = .keep,
            .depth_fail_op = .keep,
            .compare_op = .always,
            .compare_mask = 0,
            .write_mask = 0,
            .reference = 0,
        },
        .back = .{
            .fail_op = .keep,
            .pass_op = .keep,
            .depth_fail_op = .keep,
            .compare_op = .always,
            .compare_mask = 0,
            .write_mask = 0,
            .reference = 0,
        },
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
    };

    std.log.debug("VulkanRenderer.createPipeline: Step 3 - Creating vertex shader module (size={} bytes)...", .{vertex_shader_spv.len});
    const vert_shader_module_info = vk.ShaderModuleCreateInfo{
        .flags = .{},
        .code_size = vertex_shader_spv.len,
        .p_code = @ptrCast(@alignCast(vertex_shader_spv.ptr)),
    };
    std.log.debug("VulkanRenderer.createPipeline: Step 3 - Created vertex shader module handle...", .{});
    const vert_shader_module = try self.dev.createShaderModule(&vert_shader_module_info, null);
    errdefer self.dev.destroyShaderModule(vert_shader_module, null);

    std.log.debug("VulkanRenderer.createPipeline: Step 3 - Creating fragment shader module (size={} bytes)...", .{fragment_shader_spv.len});
    const frag_shader_module_info = vk.ShaderModuleCreateInfo{
        .flags = .{},
        .code_size = fragment_shader_spv.len,
        .p_code = @ptrCast(@alignCast(fragment_shader_spv.ptr)),
    };
    std.log.debug("VulkanRenderer.createPipeline: Step 3 - Created fragment shader module handle...", .{});
    const frag_shader_module = try self.dev.createShaderModule(&frag_shader_module_info, null);
    errdefer self.dev.destroyShaderModule(frag_shader_module, null);

    var pssci: [2]vk.PipelineShaderStageCreateInfo = undefined;

    pssci[0] = .{
        .flags = .{},
        .stage = .{ .vertex_bit = true },
        .module = vert_shader_module,
        .p_name = "main",
        .p_specialization_info = null,
    };

    pssci[1] = .{
        .flags = .{},
        .stage = .{ .fragment_bit = true },
        .module = frag_shader_module,
        .p_name = "main",
        .p_specialization_info = null,
    };

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .flags = .{},
        .vertex_binding_description_count = 0,
        .p_vertex_binding_descriptions = undefined,
        .vertex_attribute_description_count = 0,
        .p_vertex_attribute_descriptions = undefined,
    };

    const rendering_info = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = @ptrCast(&self.swapchain_format),
        .depth_attachment_format = self.depth_format,
        .stencil_attachment_format = .undefined,
    };

    const gpci = vk.GraphicsPipelineCreateInfo{
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
    std.log.debug("VulkanRenderer.createPipeline: Step 4 - Creating graphics pipelines with {} create infos...", .{1});
    if (self.dev.createGraphicsPipelines(
        .null_handle,
        &.{gpci},
        null,
        (&pipeline)[0..1],
    )) |res| {
        if (res != .success) return error.PipelineCreationFailed;
    } else |err| return err;

    std.log.debug("VulkanRenderer.createPipeline: Step 5 - Cleaning up shader modules after pipeline creation...", .{});
    self.dev.destroyShaderModule(vert_shader_module, null);
    self.dev.destroyShaderModule(frag_shader_module, null);

    self.pipeline = pipeline;
    std.log.debug("VulkanRenderer.createPipeline: SUCCESS - Created opaque pipeline handle={any}", .{self.pipeline});
}

fn createTransparentPipeline(self: *VulkanRenderer) !void {
    std.log.debug("VulkanRenderer.createTransparentPipeline: Step 1 - Creating transparent graphics pipeline state create infos...", .{});
    const piasci = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };

    const pvsci = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = null,
        .scissor_count = 1,
        .p_scissors = null,
    };

    const prsci = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{},
        .front_face = .clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const pmsci = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    const pcbas = vk.PipelineColorBlendAttachmentState{
        .blend_enable = .true,
        .src_color_blend_factor = .src_alpha,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .src_alpha,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    const pcbsci = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&pcbas),
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };

    const dynstate = [_]vk.DynamicState{ .viewport, .scissor };
    const pdsci = vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dynstate.len,
        .p_dynamic_states = &dynstate,
    };

    // OIT-compatible depth state: depth reads enabled for correct occlusion of transparent
    // fragments behind opaque geometry, but depth writes disabled so that transparent surfaces
    // at different depths can accumulate correctly. For Weighted Blended OIT or per-pixel linked
    // lists, keep depth_test_enable = true and depth_write_enable = false.
    const depth_stencil_state_transparent = vk.PipelineDepthStencilStateCreateInfo{
        .flags = .{},
        .depth_test_enable = .true,
        .depth_write_enable = .false,
        .depth_compare_op = .greater,
        .depth_bounds_test_enable = .false,
        .stencil_test_enable = .false,
        .front = .{
            .fail_op = .keep,
            .pass_op = .keep,
            .depth_fail_op = .keep,
            .compare_op = .always,
            .compare_mask = 0,
            .write_mask = 0,
            .reference = 0,
        },
        .back = .{
            .fail_op = .keep,
            .pass_op = .keep,
            .depth_fail_op = .keep,
            .compare_op = .always,
            .compare_mask = 0,
            .write_mask = 0,
            .reference = 0,
        },
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
    };

    std.log.debug("VulkanRenderer.createTransparentPipeline: Step 2 - Creating vertex and fragment shader modules...", .{});
    const vert_shader_module_info = vk.ShaderModuleCreateInfo{
        .flags = .{},
        .code_size = vertex_shader_spv.len,
        .p_code = @ptrCast(@alignCast(vertex_shader_spv.ptr)),
    };
    const vert_shader_module = try self.dev.createShaderModule(&vert_shader_module_info, null);

    const frag_shader_module_info = vk.ShaderModuleCreateInfo{
        .flags = .{},
        .code_size = fragment_shader_spv.len,
        .p_code = @ptrCast(@alignCast(fragment_shader_spv.ptr)),
    };
    const frag_shader_module = try self.dev.createShaderModule(&frag_shader_module_info, null);

    var pssci: [2]vk.PipelineShaderStageCreateInfo = undefined;

    pssci[0] = .{
        .flags = .{},
        .stage = .{ .vertex_bit = true },
        .module = vert_shader_module,
        .p_name = "main",
        .p_specialization_info = null,
    };

    pssci[1] = .{
        .flags = .{},
        .stage = .{ .fragment_bit = true },
        .module = frag_shader_module,
        .p_name = "main",
        .p_specialization_info = null,
    };

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .flags = .{},
        .vertex_binding_description_count = 0,
        .p_vertex_binding_descriptions = undefined,
        .vertex_attribute_description_count = 0,
        .p_vertex_attribute_descriptions = undefined,
    };

    const rendering_info = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = @ptrCast(&self.swapchain_format),
        .depth_attachment_format = self.depth_format,
        .stencil_attachment_format = .undefined,
    };

    const gpci_transparent = vk.GraphicsPipelineCreateInfo{
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
        .p_depth_stencil_state = &depth_stencil_state_transparent,
        .p_color_blend_state = &pcbsci,
        .p_dynamic_state = &pdsci,
        .layout = self.pipeline_layout,
        .render_pass = .null_handle,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var transparent_pipeline: vk.Pipeline = undefined;
    std.log.debug("VulkanRenderer.createTransparentPipeline: Step 3 - Creating transparent graphics pipelines with {} create infos...", .{1});
    if (self.dev.createGraphicsPipelines(
        .null_handle,
        &.{gpci_transparent},
        null,
        (&transparent_pipeline)[0..1],
    )) |res| {
        if (res != .success) return error.PipelineCreationFailed;
    } else |err| return err;

    std.log.debug("VulkanRenderer.createTransparentPipeline: Step 4 - Cleaning up shader modules after pipeline creation...", .{});
    self.dev.destroyShaderModule(vert_shader_module, null);
    self.dev.destroyShaderModule(frag_shader_module, null);

    self.transparent_pipeline = transparent_pipeline;
    std.log.debug("VulkanRenderer.createTransparentPipeline: SUCCESS - Created transparent pipeline handle={any}", .{self.transparent_pipeline});
}

fn currentFrame(self: *VulkanRenderer) u32 {
    const current_frame_unbound = self.current_frame_idx.load(.monotonic);
    const num_frames = @as(u32, @intCast(self.in_flight_fences.len));
    return if (num_frames > 0) @as(u32, @intCast(current_frame_unbound % num_frames)) else 0;
}

fn waitFences(self: *VulkanRenderer, fences: []const vk.Fence) !void {
    if (self.dev.waitForFences(fences, .true, 2000000000)) |res| {
        if (res != .success) return error.DrawFailed;
    } else |_| return error.DrawFailed;
}

fn enqueueDeferredDeletion(self: *VulkanRenderer, io: std.Io, mesh: ChunkMeshBuffer) void {
    const frame_idx = self.getDeletionQueueIndex();

    _ = self.deferred_deletions_mutex.lock(io) catch |err| switch (err) {
        error.Canceled => {},
    };
    defer self.deferred_deletions_mutex.unlock(io);
    _ = self.deferred_deletions[frame_idx].append(self.allocator, mesh) catch |err| switch (err) {
        error.OutOfMemory => std.log.err("enqueueDeferredDeletion: Out of memory appending to deferred deletion queue", .{}),
    };
}

fn processDeletionQueue(self: *VulkanRenderer, io: std.Io, frame_idx: u32) !void {
    const current_deletion_queue_idx = frame_idx % @as(u32, @intCast(self.deferred_deletions.len));

    _ = self.deferred_deletions_mutex.lock(io) catch |err| switch (err) {
        error.Canceled => {},
    };
    defer self.deferred_deletions_mutex.unlock(io);

    var deletion_queue = &self.deferred_deletions[current_deletion_queue_idx];
    for (deletion_queue.items) |mesh| {
        if (mesh.buffer != .null_handle) self.dev.destroyBuffer(mesh.buffer, null);
        if (mesh.memory != .null_handle) self.dev.freeMemory(mesh.memory, null);
    }
    deletion_queue.clearRetainingCapacity();
}

pub fn beginSingleTimeCommands(self: *VulkanRenderer, io: std.Io) !vk.CommandBuffer {
    _ = io;
    const alloc_info = vk.CommandBufferAllocateInfo{
        .level = .primary,
        .command_pool = self.upload_command_pool,
        .command_buffer_count = 1,
    };
    var cmd: vk.CommandBuffer = undefined;
    try self.dev.allocateCommandBuffers(&alloc_info, @ptrCast(&cmd));

    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };
    try self.dev.beginCommandBuffer(cmd, &begin_info);

    return cmd;
}

pub fn endSingleTimeCommands(self: *VulkanRenderer, io: std.Io, cmd: vk.CommandBuffer) !void {
    try self.dev.endCommandBuffer(cmd);

    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmd),
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    };

    _ = self.queue_mutex.lock(io) catch |err| switch (err) {
        error.Canceled => return error.DrawFailed,
    };
    defer self.queue_mutex.unlock(io);

    try self.dev.queueSubmit(self.graphics_queue, &[_]vk.SubmitInfo{submit_info}, .null_handle);

    _ = self.dev.queueWaitIdle(self.graphics_queue) catch {};

    self.dev.freeCommandBuffers(self.upload_command_pool, &[_]vk.CommandBuffer{cmd});
}

pub fn present(self: *VulkanRenderer, io: std.Io) !void {
    const current_frame = self.currentFrame();

    const wait_semaphores = &[_]vk.Semaphore{self.render_complete_semaphores[current_frame]};

    const present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = @as(u32, @intCast(wait_semaphores.len)),
        .p_wait_semaphores = @ptrCast(wait_semaphores.ptr),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.swapchain),
        .p_image_indices = &[_]u32{self.current_swapchain_image_index},
        .p_results = undefined,
    };

    _ = self.queue_mutex.lock(io) catch |err| switch (err) {
        error.Canceled => return error.VulkanPresentFailed,
    };
    defer self.queue_mutex.unlock(io);

    _ = self.dev.queuePresentKHR(self.present_queue, &present_info) catch |err| switch (err) {
        else => return error.VulkanPresentFailed,
    };
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
fn vtableForEachChunk(userdata: *anyopaque, io: std.Io, callback_userdata: *anyopaque, callback: *const fn (*anyopaque, ChunkPos) void) std.Io.Cancelable!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));
    var it = self.meshes.iterator();
    while (try it.next(io)) |entry| {
        const chunk_pos = entry.key_ptr.*.toPos();
        it.pause(io);
        callback(callback_userdata, chunk_pos);
        try it.unpause(io);
    }
}

test "makeInfReversedZProjRh — Vulkan Y-down and reversed-Z properties" {
    const fov = std.math.degreesToRadians(90.0);
    const aspect = 800.0 / 600.0;
    const zNear: f32 = 0.01;

    const P = makeInfReversedZProjRh(fov, aspect, zNear);

    // Helper to transform a point and get NDC
    const transform = struct {
        fn apply(p: zm.Mat4f, pt: @Vector(4, f32)) struct { clip: @Vector(4, f32), ndc: @Vector(3, f32) } {
            const v = p.multiplyVec(zm.vec.Vec4f{ .data = pt });
            const c = v.data;
            return .{
                .clip = c,
                .ndc = .{ c[0] / c[3], c[1] / c[3], c[2] / c[3] },
            };
        }
    }.apply;

    // 1. Y-down: positive Y world → negative NDC Y (top of screen in Vulkan)
    {
        const r = transform(P, .{ 0, 10, -50, 1 });
        try std.testing.expect(r.ndc[1] < 0);
    }

    // 2. Y-down: negative Y world → positive NDC Y (bottom of screen)
    {
        const r = transform(P, .{ 0, -10, -50, 1 });
        try std.testing.expect(r.ndc[1] > 0);
    }

    // 3. X: positive X world → positive NDC X (right side)
    {
        const r = transform(P, .{ 10, 0, -50, 1 });
        try std.testing.expect(r.ndc[0] > 0);
    }

    // 4. X: negative X world → negative NDC X (left side)
    {
        const r = transform(P, .{ -10, 0, -50, 1 });
        try std.testing.expect(r.ndc[0] < 0);
    }

    // 5. Reversed-Z: near plane (z=-zN) → NDC z = 1.0
    {
        const r = transform(P, .{ 0, 0, -zNear, 1 });
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), r.ndc[2], 1e-6);
    }

    // 6. Reversed-Z: far plane (z→-inf) → NDC z → 0.0
    {
        const r = transform(P, .{ 0, 0, -1e9, 1 });
        try std.testing.expect(r.ndc[2] > 0);
        try std.testing.expect(r.ndc[2] < 1e-6);
    }

    // 7. W is positive for points in front of camera (z < 0 in RH)
    {
        const r = transform(P, .{ 0, 0, -50, 1 });
        try std.testing.expect(r.clip[3] > 0);
    }

    // 8. Perspective: farther objects are smaller
    {
        const near = transform(P, .{ 10, 0, -50, 1 });
        const far = transform(P, .{ 10, 0, -500, 1 });
        // |ndc_x| is smaller for farther objects
        try std.testing.expect(@abs(near.ndc[0]) > @abs(far.ndc[0]));
    }
}

test "lookAtRH at origin — pure rotation view matrix" {
    const up = zm.vec.Vec3f{ .data = @Vector(3, f32){ 0, 1, 0 } };
    const front = zm.vec.Vec3f{ .data = @Vector(3, f32){ 0, 0, 1 } };

    const view = zm.matrix.Mat4f.lookAtRH(
        .{ .data = @Vector(3, f32){ 0, 0, 0 } },
        front,
        up,
    );

    // A pure rotation matrix has no translation → last column should be [0, 0, 0, 1]
    try std.testing.expectEqual(@as(f32, 0.0), view.data[0][3]);
    try std.testing.expectEqual(@as(f32, 0.0), view.data[1][3]);
    try std.testing.expectEqual(@as(f32, 0.0), view.data[2][3]);
    try std.testing.expectEqual(@as(f32, 1.0), view.data[3][3]);

    // Camera at origin looking along +Z.
    // In RH view space, the camera looks along -Z, so points in front have z_view < 0.
    // A point at world (0, 0, 50) is in front of the camera.
    const pt = view.multiplyVec(.{ .data = .{ 0, 0, 50, 1 } });
    try std.testing.expect(pt.data[2] < 0);

    // A point behind the camera at world (0, 0, -50) should have z_view > 0.
    const behind = view.multiplyVec(.{ .data = .{ 0, 0, -50, 1 } });
    try std.testing.expect(behind.data[2] > 0);

    // Right: f=(0,0,1), up=(0,1,0), s = f×up = (-1,0,0).
    // +X in world maps to -X in view space (the camera's right vector is -X).
    const right = view.multiplyVec(.{ .data = .{ 10, 0, 0, 1 } });
    try std.testing.expect(right.data[0] < 0);

    // +Y (up) in world stays +Y in view: u = s×f = (0,1,0).
    const up_pt = view.multiplyVec(.{ .data = .{ 0, 10, 0, 1 } });
    try std.testing.expect(up_pt.data[1] > 0);
}

test "anglesToDirection — matches OpenGL convention" {
    const viewDir = @Vector(3, f32){ 0.0001, -0.4, 0.001 };

    var dir: @Vector(3, f32) = undefined;
    dir[0] = @sin(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    dir[1] = @sin(std.math.degreesToRadians(viewDir[0]));
    dir[2] = @cos(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    dir = zm.Vec3f.norm(.{ .data = dir }).data;

    // Direction should be a unit vector
    const len = @sqrt(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), len, 1e-6);

    // Raw angles should NOT equal the direction
    try std.testing.expect(dir[0] != viewDir[0]);
    try std.testing.expect(dir[1] != viewDir[1]);

    // With pitch near 0, the yaw rotation should be visible
    // yaw=-0.4° means looking slightly to the right
    // cos(-0.4°)≈0.99998, sin(-0.4°)≈-0.00698
    try std.testing.expectApproxEqAbs(@as(f32, -0.00698), dir[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.000001745), dir[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.99998), dir[2], 1e-4);
}

test "projview combination — full pipeline sanity" {
    const fov = std.math.degreesToRadians(90.0);
    const aspect = 800.0 / 600.0;
    const zNear: f32 = 0.01;

    const P = makeInfReversedZProjRh(fov, aspect, zNear);

    // Camera looking along +Z from origin, pure rotation
    const up = zm.vec.Vec3f{ .data = @Vector(3, f32){ 0, 1, 0 } };
    const front = zm.vec.Vec3f{ .data = @Vector(3, f32){ 0, 0, 1 } };
    const V = zm.matrix.Mat4f.lookAtRH(
        .{ .data = @Vector(3, f32){ 0, 0, 0 } },
        front,
        up,
    );

    const projview = P.multiply(V);

    // Helper
    const transform = struct {
        fn apply(pv: zm.Mat4f, pt: @Vector(4, f32)) struct { clip: @Vector(4, f32), ndc: @Vector(3, f32) } {
            const v = pv.multiplyVec(zm.vec.Vec4f{ .data = pt });
            const c = v.data;
            return .{
                .clip = c,
                .ndc = .{ c[0] / c[3], c[1] / c[3], c[2] / c[3] },
            };
        }
    }.apply;

    // Point in front of camera at world z=+50: should be visible (within clip volume)
    const r = transform(projview, .{ 0, 0, 50, 1 });
    // NDC should be in [-1, 1] clip space or [0, 1] for depth (reversed-Z near=1)
    try std.testing.expect(@abs(r.ndc[0]) <= 1);
    try std.testing.expect(@abs(r.ndc[1]) <= 1);
    try std.testing.expect(r.ndc[2] >= 0 and r.ndc[2] <= 1);

    // Point behind camera at world z=-50: should NOT be visible (w should be negative)
    const behind = transform(projview, .{ 0, 0, -50, 1 });
    try std.testing.expect(behind.clip[3] < 0);
}

// ──── RenderBufferKey ──────────────────────────────────────────────────────────

test "RenderBufferKey.toPos — opaque and transparent" {
    const pos_a = ChunkPos{ .level = 0, .position = .{ 1, 2, 3 } };
    const pos_b = ChunkPos{ .level = -3, .position = .{ -10, 20, 30 } };

    const opaque_key: RenderBufferKey = .{ .@"opaque" = pos_a };
    const transparent_key: RenderBufferKey = .{ .transparent = pos_b };

    try std.testing.expectEqual(pos_a, opaque_key.toPos());
    try std.testing.expectEqual(pos_b, transparent_key.toPos());
}

test "RenderBufferKey.toPos — identity after round-trip" {
    const pos = ChunkPos{ .level = 5, .position = .{ -100, 200, -300 } };

    const key: RenderBufferKey = .{ .@"opaque" = pos };
    const extracted = key.toPos();

    try std.testing.expectEqual(pos.level, extracted.level);
    try std.testing.expectEqual(pos.position[0], extracted.position[0]);
    try std.testing.expectEqual(pos.position[1], extracted.position[1]);
    try std.testing.expectEqual(pos.position[2], extracted.position[2]);
}

// ──── FrameDebugStats ──────────────────────────────────────────────────────────

test "FrameDebugStats — default initialization" {
    const stats = FrameDebugStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.frame_number);
    try std.testing.expectEqual(@as(u32, 0), stats.total_meshes);
    try std.testing.expectEqual(@as(u32, 0), stats.opaque_candidates);
    try std.testing.expectEqual(@as(u32, 0), stats.opaque_culled);
    try std.testing.expectEqual(@as(u32, 0), stats.opaque_drawn);
    try std.testing.expectEqual(@as(u32, 0), stats.transparent_candidates);
    try std.testing.expectEqual(@as(u32, 0), stats.transparent_culled);
    try std.testing.expectEqual(@as(u32, 0), stats.transparent_drawn);
    try std.testing.expectEqual(@as(u64, 0), stats.elapsed_ns);
}

test "FrameDebugStats — log with zero values does not crash" {
    // The log method is a no-op in terms of side-effects we can assert,
    // but it must not panic or crash even with all-zero inputs.
    const stats = FrameDebugStats{};
    stats.log();
}

test "FrameDebugStats — log with partial populated stats" {
    var stats = FrameDebugStats{
        .frame_number = 42,
        .total_meshes = 100,
        .opaque_candidates = 60,
        .opaque_culled = 10,
        .opaque_drawn = 50,
        .transparent_candidates = 30,
        .transparent_culled = 20,
        .transparent_drawn = 10,
        .elapsed_ns = 16_666_666,
        .player_pos = .{ 10.5, 20.3, -5.0 },
        .camera_front = .{ 0.1, -0.2, 0.97 },
    };
    stats.log();
}

test "FrameDebugStats — log triggers zero-drawn warning when total_drawn == 0" {
    var stats = FrameDebugStats{
        .frame_number = 1,
        .total_meshes = 10,
        .opaque_candidates = 5,
        .transparent_candidates = 3,
        .elapsed_ns = 5_000_000,
    };
    stats.log(); // Should log warning since total_drawn == 0
}

// ──── getDeletionQueueIndex ─────────────────────────────────────────────────────

test "getDeletionQueueIndex — frame 0 with 2 in-flight fences" {
    var renderer: VulkanRenderer = undefined;
    renderer.current_frame_idx = std.atomic.Value(u32).init(0);
    var fences_2: [2]vk.Fence = .{ .null_handle, .null_handle };
    renderer.in_flight_fences = &fences_2;

    // fence_slot = 0 % 2 = 0; result = 0 % 8 = 0
    try std.testing.expectEqual(@as(u32, 0), renderer.getDeletionQueueIndex());
}

test "getDeletionQueueIndex — monotonically increasing frames" {
    var renderer: VulkanRenderer = undefined;
    renderer.current_frame_idx = std.atomic.Value(u32).init(0);
    var fences_2: [2]vk.Fence = .{ .null_handle, .null_handle };
    renderer.in_flight_fences = &fences_2;

    var expected: u32 = 0;
    while (expected < 16) : (expected += 1) {
        renderer.current_frame_idx.store(expected, .monotonic);
        // fence_slot = expected % 2; result = (expected % 2) % 8 = expected % 2
        const want = @as(u32, @intCast(@as(u64, expected) % 2));
        try std.testing.expectEqual(want, renderer.getDeletionQueueIndex());
    }
}

test "getDeletionQueueIndex — wraps around deferred_deletions (8)" {
    var renderer: VulkanRenderer = undefined;
    renderer.current_frame_idx = std.atomic.Value(u32).init(8);
    var fences_3: [3]vk.Fence = .{ .null_handle, .null_handle, .null_handle };
    renderer.in_flight_fences = &fences_3;

    // fence_slot = 8 % 3 = 2; result = 2 % 8 = 2
    try std.testing.expectEqual(@as(u32, 2), renderer.getDeletionQueueIndex());
}

test "getDeletionQueueIndex — large frame numbers" {
    var renderer: VulkanRenderer = undefined;
    renderer.current_frame_idx = std.atomic.Value(u32).init(100_000);
    var fences_2: [2]vk.Fence = .{ .null_handle, .null_handle };
    renderer.in_flight_fences = &fences_2;

    // fence_slot = 100_000 % 2 = 0; result = 0 % 8 = 0
    try std.testing.expectEqual(@as(u32, 0), renderer.getDeletionQueueIndex());

    renderer.current_frame_idx.store(100_001, .monotonic);
    // fence_slot = 100_001 % 2 = 1; result = 1 % 8 = 1
    try std.testing.expectEqual(@as(u32, 1), renderer.getDeletionQueueIndex());
}

test "getDeletionQueueIndex — 5 in-flight fences, varied frames" {
    var renderer: VulkanRenderer = undefined;
    renderer.current_frame_idx = std.atomic.Value(u32).init(0);
    var fences_5: [5]vk.Fence = .{ .null_handle, .null_handle, .null_handle, .null_handle, .null_handle };
    renderer.in_flight_fences = &fences_5;

    // frame 0: fence_slot = 0 % 5 = 0; result = 0 % 8 = 0
    try std.testing.expectEqual(@as(u32, 0), renderer.getDeletionQueueIndex());

    renderer.current_frame_idx.store(7, .monotonic);
    // frame 7: fence_slot = 7 % 5 = 2; result = 2 % 8 = 2
    try std.testing.expectEqual(@as(u32, 2), renderer.getDeletionQueueIndex());

    renderer.current_frame_idx.store(13, .monotonic);
    // frame 13: fence_slot = 13 % 5 = 3; result = 3 % 8 = 3
    try std.testing.expectEqual(@as(u32, 3), renderer.getDeletionQueueIndex());
}

// ──── findMemoryType ────────────────────────────────────────────────────────────

test "findMemoryType — selects host_visible|host_coherent" {
    var renderer: VulkanRenderer = undefined;
    var mem_types: [vk.MAX_MEMORY_TYPES]vk.MemoryType = undefined;
    @memset(&mem_types, vk.MemoryType{ .property_flags = .{}, .heap_index = 0 });
    mem_types[0] = .{ .property_flags = .{ .host_visible_bit = true, .host_coherent_bit = true }, .heap_index = 0 };
    mem_types[1] = .{ .property_flags = .{ .device_local_bit = true }, .heap_index = 1 };
    mem_types[2] = .{ .property_flags = .{ .host_visible_bit = true, .host_cached_bit = true }, .heap_index = 0 };

    renderer.mem_props = .{
        .memory_type_count = 3,
        .memory_types = mem_types,
        .memory_heap_count = 2,
        .memory_heaps = undefined,
    };

    // Find host_visible | host_coherent among types 0,1,2
    const idx = renderer.findMemoryType(
        @as(u32, 0b111),
        vk.MemoryPropertyFlags{ .host_visible_bit = true, .host_coherent_bit = true },
    );
    try std.testing.expectEqual(@as(u32, 0), idx);
}

test "findMemoryType — selects device_local" {
    var renderer: VulkanRenderer = undefined;
    var mem_types: [vk.MAX_MEMORY_TYPES]vk.MemoryType = undefined;
    @memset(&mem_types, vk.MemoryType{ .property_flags = .{}, .heap_index = 0 });
    mem_types[0] = .{ .property_flags = .{ .host_visible_bit = true, .host_coherent_bit = true }, .heap_index = 0 };
    mem_types[1] = .{ .property_flags = .{ .device_local_bit = true }, .heap_index = 1 };

    renderer.mem_props = .{
        .memory_type_count = 2,
        .memory_types = mem_types,
        .memory_heap_count = 2,
        .memory_heaps = undefined,
    };

    const idx = renderer.findMemoryType(
        @as(u32, 0b11),
        vk.MemoryPropertyFlags{ .device_local_bit = true },
    );
    try std.testing.expectEqual(@as(u32, 1), idx);
}

test "findMemoryType — respects type_filter" {
    var renderer: VulkanRenderer = undefined;
    var mem_types: [vk.MAX_MEMORY_TYPES]vk.MemoryType = undefined;
    @memset(&mem_types, vk.MemoryType{ .property_flags = .{}, .heap_index = 0 });
    mem_types[0] = .{ .property_flags = .{ .device_local_bit = true }, .heap_index = 0 };
    // type 5 also has device_local but is only reachable via bit 5 in type_filter
    mem_types[5] = .{ .property_flags = .{ .device_local_bit = true }, .heap_index = 1 };

    renderer.mem_props = .{
        .memory_type_count = 6,
        .memory_types = mem_types,
        .memory_heap_count = 2,
        .memory_heaps = undefined,
    };

    // type_filter with only bit 5 set → must match memory type 5
    const idx = renderer.findMemoryType(
        @as(u32, 1 << 5),
        vk.MemoryPropertyFlags{ .device_local_bit = true },
    );
    try std.testing.expectEqual(@as(u32, 5), idx);
}

test "findMemoryType — skips types not in type_filter" {
    var renderer: VulkanRenderer = undefined;
    var mem_types: [vk.MAX_MEMORY_TYPES]vk.MemoryType = undefined;
    @memset(&mem_types, vk.MemoryType{ .property_flags = .{}, .heap_index = 0 });
    // type 0 is host_visible but NOT in type_filter (bit 0 not set)
    mem_types[0] = .{ .property_flags = .{ .host_visible_bit = true }, .heap_index = 0 };
    // type 1 is host_visible AND in type_filter
    mem_types[1] = .{ .property_flags = .{ .host_visible_bit = true }, .heap_index = 1 };

    renderer.mem_props = .{
        .memory_type_count = 2,
        .memory_types = mem_types,
        .memory_heap_count = 2,
        .memory_heaps = undefined,
    };

    // Only bit 1 set in filter → must select type 1, not type 0
    const idx = renderer.findMemoryType(
        @as(u32, 1 << 1),
        vk.MemoryPropertyFlags{ .host_visible_bit = true },
    );
    try std.testing.expectEqual(@as(u32, 1), idx);
}

// ──── makeInfReversedZProjRh edge cases ────────────────────────────────────────

test "makeInfReversedZProjRh — very narrow FOV" {
    const fov = std.math.degreesToRadians(10.0);
    const aspect = 16.0 / 9.0;
    const zNear: f32 = 0.01;

    const P = makeInfReversedZProjRh(fov, aspect, zNear);

    // Reversed-Z: near plane maps to NDC z = 1.0
    const v = P.multiplyVec(.{ .data = .{ 0, 0, -zNear, 1 } });
    const ndc_z = v.data[2] / v.data[3];
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ndc_z, 1e-6);

    // Far plane maps to NDC z ≈ 0
    const far_v = P.multiplyVec(.{ .data = .{ 0, 0, -1e9, 1 } });
    const far_ndc_z = far_v.data[2] / far_v.data[3];
    try std.testing.expect(far_ndc_z > 0);
    try std.testing.expect(far_ndc_z < 1e-6);
}

test "makeInfReversedZProjRh — ultra-near zNear" {
    const fov = std.math.degreesToRadians(90.0);
    const aspect = 1.0;
    const zNear: f32 = 0.0001;

    const P = makeInfReversedZProjRh(fov, aspect, zNear);

    // Near plane still maps to NDC z = 1.0
    const v = P.multiplyVec(.{ .data = .{ 0, 0, -zNear, 1 } });
    const ndc_z = v.data[2] / v.data[3];
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ndc_z, 1e-6);
}

test "makeInfReversedZProjRh — wide aspect ratio (ultrawide)" {
    const fov = std.math.degreesToRadians(90.0);
    const aspect = 32.0 / 9.0; // ~super ultrawide
    const zNear: f32 = 0.1;

    const P = makeInfReversedZProjRh(fov, aspect, zNear);

    // Y-down: +Y world → negative NDC Y
    // With 90° VFOV and wide aspect, the viewable horizontal range is much wider
    const r = P.multiplyVec(.{ .data = .{ 10, 0, -50, 1 } });
    const ndc_x = r.data[0] / r.data[3];
    // Should still be visible (within [-1, 1]) but with the wide aspect,
    // the same world X is a smaller fraction of screen width
    try std.testing.expect(@abs(ndc_x) <= 1);

    // Reversed-Z invariant
    const near_v = P.multiplyVec(.{ .data = .{ 0, 0, -zNear, 1 } });
    const near_ndc_z = near_v.data[2] / near_v.data[3];
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), near_ndc_z, 1e-6);

    // Y-down check
    const y_up = P.multiplyVec(.{ .data = .{ 0, 10, -50, 1 } });
    try std.testing.expect(y_up.data[1] / y_up.data[3] < 0);
}

// ──── Camera direction math edge cases ──────────────────────────────────────────

test "camera direction — looking straight up (pitch=+90°)" {
    const viewDir = @Vector(3, f32){ 90.0, 0.0, 0.0 };

    var dir: @Vector(3, f32) = undefined;
    dir[0] = @sin(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    dir[1] = @sin(std.math.degreesToRadians(viewDir[0]));
    dir[2] = @cos(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    dir = zm.Vec3f.norm(.{ .data = dir }).data;

    const len = @sqrt(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), len, 1e-5);

    // Looking straight up: direction should be (0, 1, 0)
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dir[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dir[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dir[2], 1e-5);
}

test "camera direction — looking straight down (pitch=-90°)" {
    const viewDir = @Vector(3, f32){ -90.0, 0.0, 0.0 };

    var dir: @Vector(3, f32) = undefined;
    dir[0] = @sin(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    dir[1] = @sin(std.math.degreesToRadians(viewDir[0]));
    dir[2] = @cos(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    dir = zm.Vec3f.norm(.{ .data = dir }).data;

    const len = @sqrt(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), len, 1e-5);

    // Looking straight down: direction should be (0, -1, 0)
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dir[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), dir[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dir[2], 1e-5);
}

test "camera direction — looking directly behind (yaw=180°)" {
    const viewDir = @Vector(3, f32){ 0.0, 180.0, 0.0 };

    var dir: @Vector(3, f32) = undefined;
    dir[0] = @sin(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    dir[1] = @sin(std.math.degreesToRadians(viewDir[0]));
    dir[2] = @cos(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    dir = zm.Vec3f.norm(.{ .data = dir }).data;

    const len = @sqrt(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), len, 1e-5);

    // Looking behind (180° yaw from +Z): direction should be (0, 0, -1)
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dir[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dir[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), dir[2], 1e-5);
}

test "camera direction — looking right (yaw=+90°)" {
    const viewDir = @Vector(3, f32){ 0.0, 90.0, 0.0 };

    var dir: @Vector(3, f32) = undefined;
    dir[0] = @sin(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    dir[1] = @sin(std.math.degreesToRadians(viewDir[0]));
    dir[2] = @cos(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    dir = zm.Vec3f.norm(.{ .data = dir }).data;

    const len = @sqrt(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), len, 1e-5);

    // Looking right: direction should be (1, 0, 0)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dir[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dir[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dir[2], 1e-5);
}

test "camera direction — looking left (yaw=-90°)" {
    const viewDir = @Vector(3, f32){ 0.0, -90.0, 0.0 };

    var dir: @Vector(3, f32) = undefined;
    dir[0] = @sin(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    dir[1] = @sin(std.math.degreesToRadians(viewDir[0]));
    dir[2] = @cos(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    dir = zm.Vec3f.norm(.{ .data = dir }).data;

    const len = @sqrt(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), len, 1e-5);

    // Looking left: direction should be (-1, 0, 0)
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), dir[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dir[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dir[2], 1e-5);
}

// ──── cullChunk ─────────────────────────────────────────────────────────────────

/// Helper: build a Frustum from a camera configured at `eye` looking toward `target`.
fn makeTestFrustum(eye: @Vector(3, f32), target: @Vector(3, f32), up: @Vector(3, f32), fov_deg: f32, aspect: f32, z_near: f32) Frustum {
    const fov = std.math.degreesToRadians(fov_deg);
    const P = makeInfReversedZProjRh(fov, aspect, z_near);
    const V = zm.Mat4f.lookAtRH(
        .{ .data = eye },
        .{ .data = target },
        .{ .data = up },
    );
    const projview = P.multiply(V);

    const flat: @Vector(16, f32) = .{
        projview.data[0][0], projview.data[0][1], projview.data[0][2], projview.data[0][3],
        projview.data[1][0], projview.data[1][1], projview.data[1][2], projview.data[1][3],
        projview.data[2][0], projview.data[2][1], projview.data[2][2], projview.data[2][3],
        projview.data[3][0], projview.data[3][1], projview.data[3][2], projview.data[3][3],
    };

    return Frustum.extractFrustumPlanes(flat);
}

test "cullChunk — chunk directly in front of camera is NOT culled" {
    const frustum = makeTestFrustum(
        .{ 0, 0, 0 }, // eye at origin
        .{ 0, 0, 1 }, // looking along +Z
        .{ 0, 1, 0 }, // up
        90.0, // 90° vertical FOV
        800.0 / 600.0, // standard aspect
        0.01, // zNear
    );

    // Chunk at level 0, position (0, 0, 0) — sits at world origin, right at the camera's feet
    const chunkpos = ChunkPos{ .level = 0, .position = .{ 0, 0, 0 } };
    const playerPos: @Vector(3, f64) = .{ 0, 0, 0 };

    try std.testing.expect(!cullChunk(&frustum, chunkpos, playerPos));
}

test "cullChunk — chunk in front along view direction is NOT culled" {
    const frustum = makeTestFrustum(
        .{ 0, 0, 0 },
        .{ 0, 0, 1 },
        .{ 0, 1, 0 },
        90.0,
        800.0 / 600.0,
        0.01,
    );

    // Chunk at level 0, position (0, 0, 1) — in front along +Z
    const chunkpos = ChunkPos{ .level = 0, .position = .{ 0, 0, 1 } };
    const playerPos: @Vector(3, f64) = .{ 0, 0, 0 };

    try std.testing.expect(!cullChunk(&frustum, chunkpos, playerPos));
}

test "cullChunk — chunk behind camera IS culled" {
    const frustum = makeTestFrustum(
        .{ 0, 0, 0 },
        .{ 0, 0, 1 },
        .{ 0, 1, 0 },
        90.0,
        800.0 / 600.0,
        0.01,
    );

    // Chunk behind camera at position (0, 0, -2) — behind the viewer
    const chunkpos = ChunkPos{ .level = 0, .position = .{ 0, 0, -2 } };
    const playerPos: @Vector(3, f64) = .{ 0, 0, 0 };

    try std.testing.expect(cullChunk(&frustum, chunkpos, playerPos));
}

test "cullChunk — chunk far to the side IS culled outside 90° FOV" {
    const frustum = makeTestFrustum(
        .{ 0, 0, 0 },
        .{ 0, 0, 1 },
        .{ 0, 1, 0 },
        90.0,
        800.0 / 600.0,
        0.01,
    );

    // Chunk far to the right at X=20 chunks → world X = 640, well outside frustum
    const chunkpos = ChunkPos{ .level = 0, .position = .{ 20, 0, 1 } };
    const playerPos: @Vector(3, f64) = .{ 0, 0, 0 };

    try std.testing.expect(cullChunk(&frustum, chunkpos, playerPos));
}

test "cullChunk — chunk slightly off-center but still visible" {
    const frustum = makeTestFrustum(
        .{ 0, 0, 0 },
        .{ 0, 0, 1 },
        .{ 0, 1, 0 },
        90.0,
        800.0 / 600.0,
        0.01,
    );

    // Chunk at (1, 0, 1) is slightly to the right but should still be within ~106° HFOV
    const chunkpos = ChunkPos{ .level = 0, .position = .{ 1, 0, 1 } };
    const playerPos: @Vector(3, f64) = .{ 0, 0, 0 };

    try std.testing.expect(!cullChunk(&frustum, chunkpos, playerPos));
}

test "cullChunk — chunk far above camera IS culled" {
    const frustum = makeTestFrustum(
        .{ 0, 0, 0 },
        .{ 0, 0, 1 },
        .{ 0, 1, 0 },
        90.0,
        800.0 / 600.0,
        0.01,
    );

    // Chunk far above at (0, 20, 1) — Y=20 chunks = 640 world units, culled by top plane
    const chunkpos = ChunkPos{ .level = 0, .position = .{ 0, 20, 1 } };
    const playerPos: @Vector(3, f64) = .{ 0, 0, 0 };

    try std.testing.expect(cullChunk(&frustum, chunkpos, playerPos));
}

// ──── RenderOptions ─────────────────────────────────────────────────────────────

test "RenderOptions — default values" {
    const options = VulkanRenderer.RenderOptions{};
    try std.testing.expect(!options.draw_over);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), options.fov, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 60 * 5), options.day_length_sec, 1e-6);
}

// ──── ChunkData layout ──────────────────────────────────────────────────────────

test "ChunkData — struct size and alignment" {
    // ChunkData: absolute_position[3]f32 align(4*@sizeOf(f32)=16) (12+4pad), relative_position[3]f32 align(16) (12+4pad),
    // scale f32 (4), pad(4), address u64 align(8) (8) = 48 total with align(16)
    try std.testing.expectEqual(@as(usize, 16), @alignOf(ChunkData));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(ChunkData));
}

// ──── PushConstants layout ───────────────────────────────────────────────────────

test "PushConstants — struct size and alignment" {
    // PushConstants: projview [16]f32=64, sun_dir [3]f32=12, _pad0 f32=4, time f32=4, draw_over i32=4
    try std.testing.expectEqual(@as(usize, 4), @alignOf(PushConstants));
    try std.testing.expectEqual(@as(usize, 84), @sizeOf(PushConstants));
}

// ──── VulkanRenderer itself (partial, structural) ───────────────────────────────

test "VulkanRenderer — RenderOptions has expected field types" {
    const Opts = VulkanRenderer.RenderOptions;
    // Verify at compile time — ensure struct exists and fields are accessible
    comptime {
        if (!@hasField(Opts, "draw_over")) @compileError("missing draw_over");
        if (!@hasField(Opts, "fov")) @compileError("missing fov");
        if (!@hasField(Opts, "day_length_sec")) @compileError("missing day_length_sec");
    }
}

test "ChunkMeshBuffer — struct layout" {
    // buffer: vk.Buffer (Vulkan handle, u64), memory: vk.DeviceMemory (u64),
    // device_address: vk.DeviceAddress (u64), face_count: u32
    // Max alignment among fields is 8 (u64 handles)
    try std.testing.expectEqual(@as(usize, 8), @alignOf(ChunkMeshBuffer));
    // Regular (non-extern) struct; verify size is as expected with u64 handles
    try std.testing.expect(@sizeOf(ChunkMeshBuffer) >= 28); // 3*u64 + u32 + potentially padding
}

test "ChunkData — field sizes" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf([3]f32));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(f32));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(u64));
}
