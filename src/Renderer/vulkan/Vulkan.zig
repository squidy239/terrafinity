const std = @import("std");

const fragment_shader_spv_data = @import("fragment_shader").data;
const tracy = @import("tracy");
const vertex_shader_spv_data = @import("vertex_shader").data;
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
const ChunkPos = World.ChunkPos;
const Frustum = @import("../opengl/Frustum.zig").Frustum;
const textures = @import("textures.zig");

// Embedded SPIR-V shaders (SPIR-V is 32-bit words, but we store as bytes and cast)
const vertex_shader_spv: []const u8 = @embedFile("vertexshader.spv");
const fragment_shader_spv: []const u8 = @embedFile("fragshader.spv");

pub const cameraUp = @Vector(3, f32){ 0, 1, 0 };

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

const PushConstants = extern struct {
    projview: [16]f32,
    sun_dir: [3]f32,
    time: f32,
    draw_over: i32,
};

// Dispatch tables provided by vulkan-zig
pub const VulkanRenderer = @This();

allocator: std.mem.Allocator,
window: *wio.Window,
surface: vk.SurfaceKHR = .null_handle,

vkb: BaseWrapper,
instance_handle: vk.Instance,
instance_wrapper: *InstanceWrapper,
instance: InstanceProxy,

pdev: vk.PhysicalDevice,
props: vk.PhysicalDeviceProperties,
mem_props: vk.PhysicalDeviceMemoryProperties,

dev_handle: vk.Device,
dev_wrapper: *DeviceWrapper,
dev: DeviceProxy,

graphics_queue: vk.Queue,
present_queue: vk.Queue,
queue_family_index: u32,
present_queue_family_index: u32,

command_pool: vk.CommandPool,
cmd_buffer: vk.CommandBuffer,

swapchain: vk.SwapchainKHR = .null_handle,
swapchain_images: []vk.Image = &.{},
swapchain_views: []vk.ImageView = &.{},
swapchain_extent: vk.Extent2D = .{ .width = 800, .height = 600 },

// Render target images for dynamic rendering (color + depth)
render_color_image: vk.Image = .null_handle,
render_color_view: vk.ImageView = .null_handle,
render_depth_image: vk.Image = .null_handle,
render_depth_view: vk.ImageView = .null_handle,

// Swapchain synchronization primitives
image_acquired_semaphores: []vk.Semaphore = &.{},
render_complete_semaphores: []vk.Semaphore = &.{},
in_flight_fences: []vk.Fence = &.{},
current_frame_idx: u32 = 0,

descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
pipeline_layout: vk.PipelineLayout = .null_handle,
pipeline: vk.Pipeline = .null_handle,
transparent_pipeline: vk.Pipeline = .null_handle, // For transparent rendering with depth_write_enable=false
descriptor_pool: vk.DescriptorPool = .null_handle,
global_descriptor_set: vk.DescriptorSet = .null_handle,

meshes: ConcurrentHashMap(RenderBufferKey, ChunkMeshBuffer, std.hash_map.AutoContext(RenderBufferKey), 80, 32),
meshes_lock: std.Io.Mutex = .init,

indirect_draw_buffer: vk.Buffer,
indirect_draw_memory: vk.DeviceMemory,
chunk_data_buffer: vk.Buffer,
chunk_data_memory: vk.DeviceMemory,
max_draw_count: u32 = 100_000,

camera_front: @Vector(3, f32) = .{ 0, 0, 1 },
viewport_pixels: @Vector(2, u32) = .{ 800, 600 },

render_options: *const RenderOptions = &default_render_options,
render_options_lock: *std.Io.RwLock = &default_render_options_lock,

interface: Renderer,

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

fn getProcAddr(instance: vk.Instance, procname: [*:0]const u8) ?*const fn () void {
    return @ptrCast(wio.vkGetInstanceProcAddr(
        (@intFromEnum(instance)),
        procname,
    ));
}

// Loader for DeviceWrapper - calls vkGetDeviceProcAddr(device, procname)
fn getDeviceProcAddrLoader(device: vk.Device, procname: [*:0]const u8, instance_handle: vk.Instance) ?*const fn () void {
    // Get vkGetDeviceProcAddr via vkGetInstanceProcAddr with the actual instance handle
    const gdpa_ptr = @as(?*const fn () void, @ptrCast(wio.vkGetInstanceProcAddr(@intFromEnum(instance_handle), "vkGetDeviceProcAddr")));
    if (gdpa_ptr) |gdpa| {
        // Cast and call vkGetDeviceProcAddr(device, procname)
        const gdpa_fn = @as(*const fn (vk.Device, [*:0]const u8) ?*const fn () void, @ptrCast(gdpa));
        return gdpa_fn(device, procname);
    }
    return null;
}

pub fn init(io: std.Io, allocator: std.mem.Allocator, window: *wio.Window) !*VulkanRenderer {
    _ = io; // autofix

    const self = try allocator.create(VulkanRenderer);

    // Initialize basic fields early so they are available for subsequent calls
    self.allocator = allocator;
    self.window = window;

    // 1. Load Base Wrapper using getProcAddr helper (ptrcasts the result, not the function pointer)
    self.vkb = BaseWrapper.load(getProcAddr);

    // 2. Create Instance with validation layers and portability enumeration
    const app_info = vk.ApplicationInfo{
        .p_application_name = "Terrafinity",
        .application_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
        .p_engine_name = "No Engine",
        .engine_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
        .api_version = vk.API_VERSION_1_2.toU32(),
    };

    // Check for validation layers
    var enabled_layers: std.ArrayList([*:0]const u8) = .empty;
    errdefer enabled_layers.deinit(allocator);

    const layers = try self.vkb.enumerateInstanceLayerPropertiesAlloc(allocator);
    defer allocator.free(layers);
    for (layers) |layer| {
        const name = std.mem.sliceTo(&layer.layer_name, 0);
        if (std.mem.eql(u8, name, "VK_LAYER_KHRONOS_validation")) {
            try enabled_layers.append(allocator, "VK_LAYER_KHRONOS_validation");
        }
    }

    // Get required Vulkan instance extensions from wio and check for portability enumeration
    var extension_names: std.ArrayList([*:0]const u8) = .empty;
    errdefer extension_names.deinit(allocator);

    // Add wio's required Vulkan instance extensions
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

    const instance_create_info = vk.InstanceCreateInfo{
        .s_type = .instance_create_info,
        .flags = .{ .enumerate_portability_bit_khr = has_portability },
        .p_application_info = &app_info,
        .enabled_layer_count = @intCast(enabled_layers.items.len),
        .pp_enabled_layer_names = if (enabled_layers.items.len > 0) @ptrCast(enabled_layers.items.ptr) else null,
        .enabled_extension_count = @intCast(extension_names.items.len),
        .pp_enabled_extension_names = if (extension_names.items.len > 0) @ptrCast(extension_names.items.ptr) else null,
    };

    self.instance_handle = try self.vkb.createInstance(&instance_create_info, null);

    const instance_wrapper_ptr = try allocator.create(InstanceWrapper);
    errdefer allocator.destroy(instance_wrapper_ptr);

    // Use getProcAddr to load InstanceWrapper (as in wio-vulkan example)
    instance_wrapper_ptr.* = InstanceWrapper.load(self.instance_handle, getProcAddr);
    self.instance_wrapper = instance_wrapper_ptr;
    self.instance = InstanceProxy.init(self.instance_handle, instance_wrapper_ptr);
    errdefer self.instance.destroyInstance(null);

    // 3. Create Surface from window using wio's vkCreateSurface
    var surface: vk.SurfaceKHR = .null_handle;
    const result: vk.Result = @enumFromInt(window.vkCreateSurface(@intFromEnum(self.instance.handle), null, @ptrCast(&surface)));
    if (result != .success) return error.SurfaceCreationFailed;
    self.surface = surface;
    errdefer self.instance.destroySurfaceKHR(self.surface, null);

    // 4. Select Physical Device
    var pdev_count: u32 = 0;
    _ = try self.instance.enumeratePhysicalDevices( &pdev_count, null);

    const pdevs = try allocator.alloc(vk.PhysicalDevice, pdev_count);
    defer allocator.free(pdevs);

    _ = try self.instance.enumeratePhysicalDevices( &pdev_count, pdevs.ptr);

    var selected_pdev: vk.PhysicalDevice = .null_handle;
    for (pdevs) |pdev| {
        // Check if device supports required features
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
            features12.descriptor_indexing == .true) {

            // Check for swapchain support - first verify surface is supported by this physical device's queue families
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
                // Now check for surface formats and present modes
                var format_count: u32 = 0;
                _ = try self.instance.getPhysicalDeviceSurfaceFormatsKHR(pdev, self.surface, &format_count, null);
                var present_mode_count: u32 = 0;
                _ = try self.instance.getPhysicalDeviceSurfacePresentModesKHR(pdev, self.surface, &present_mode_count, null);

                if (format_count > 0 and present_mode_count > 0) {
                    selected_pdev = pdev;
                    break;
                }
            }
        }
    }

    if (selected_pdev == .null_handle) {
        return error.NoSuitablePhysicalDevice;
    }

    self.pdev = selected_pdev;
    self.props = self.instance.getPhysicalDeviceProperties(self.pdev);

    // 5. Create Logical Device with Required Features
    const queue_priorities = [_]f32{1.0};

    // Find graphics and present queue families
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

    const device_extensions = [_][*:0]const u8{
        vk.extensions.khr_swapchain.name,
    };

    // Determine queue create info count based on whether graphics and present families are the same
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

    var features = vk.PhysicalDeviceFeatures2{
        .features = .{ .multi_draw_indirect = .true },
        .p_next = @ptrCast(&features12),
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


    self.dev_handle = try self.instance.createDevice(self.pdev, &device_info, null);

    const dev_wrapper_ptr = try allocator.create(DeviceWrapper);
    errdefer allocator.destroy(dev_wrapper_ptr);

    dev_wrapper_ptr.* = DeviceWrapper.load(self.dev_handle, self.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
    self.dev_wrapper = dev_wrapper_ptr;
    self.dev = DeviceProxy.init(self.dev_handle, dev_wrapper_ptr);
    errdefer self.dev.destroyDevice(null);

    self.graphics_queue = self.dev.getDeviceQueue(graphics_family, 0);
    if (graphics_family == present_family) {
        self.present_queue = self.graphics_queue;
    } else {
        self.present_queue = self.dev.getDeviceQueue(present_family, 0);
    }

    self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);

    // 6. Create Command Pool & Buffer
    const pool_info = vk.CommandPoolCreateInfo{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = graphics_family,
    };
    self.command_pool = try self.dev.createCommandPool( &pool_info, null);

    const alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = self.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    var cmd_buffers: [1]vk.CommandBuffer = undefined;
    try self.dev.allocateCommandBuffers( &alloc_info, &cmd_buffers);
    self.cmd_buffer = cmd_buffers[0];

    // 7. Initialize Swapchain
    try self.createSwapchain();

    // 8. Setup Descriptor Sets and Pipeline
    try self.createDescriptorSetLayout();
    try self.createDescriptorPoolAndSets();
    try self.createPipeline();
    try self.createTransparentPipeline();

    // 9. Initialize Buffers
    try self.allocateIndirectBuffers();

    self.* = .{
        .allocator = allocator,
        .window = window,
        .vkb = self.vkb,
        .instance_handle = self.instance_handle,
        .instance_wrapper = self.instance_wrapper,
        .instance = self.instance,
        .pdev = self.pdev,
        .props = self.props,
        .mem_props = self.mem_props,
        .dev_handle = self.dev_handle,
        .dev_wrapper = self.dev_wrapper,
        .dev = self.dev,
        .graphics_queue = self.graphics_queue,
        .present_queue = self.present_queue,
        .queue_family_index = graphics_family,
        .present_queue_family_index = present_family,
        .command_pool = self.command_pool,
        .cmd_buffer = self.cmd_buffer,
        .swapchain = self.swapchain,
        .swapchain_images = self.swapchain_images,
        .swapchain_views = self.swapchain_views,
        .swapchain_extent = self.swapchain_extent,
        .image_acquired_semaphores = self.image_acquired_semaphores,
        .render_complete_semaphores = self.render_complete_semaphores,
        .in_flight_fences = self.in_flight_fences,
        .current_frame_idx = 0,
        .descriptor_set_layout = self.descriptor_set_layout,
        .pipeline_layout = self.pipeline_layout,
        .pipeline = self.pipeline,
        .transparent_pipeline = self.transparent_pipeline,
        .descriptor_pool = self.descriptor_pool,
        .global_descriptor_set = self.global_descriptor_set,
        .meshes = .init,
        .indirect_draw_buffer = self.indirect_draw_buffer,
        .indirect_draw_memory = self.indirect_draw_memory,
        .chunk_data_buffer = self.chunk_data_buffer,
        .chunk_data_memory = self.chunk_data_memory,
        .interface = .{
            .userdata = @ptrCast(self),
            .vtable = &.{
                .addChunk = vtableAddChunk,
                .removeChunk = vtableRemoveChunk,
                .drawChunks = vtableDrawChunks,
                .clear = vtableClear,
                .setViewport = vtableSetViewport,
                .updateCameraDirection = vtableUpdateCameraDirection,
                .getCameraFront = vtableGetCameraFront,
                .forEachChunk = vtableForEachChunk,
            },
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

    if (self.indirect_draw_buffer != .null_handle) {
        self.dev.destroyBuffer( self.indirect_draw_buffer, null);
    }
    if (self.indirect_draw_memory != .null_handle) {
        self.dev.freeMemory( self.indirect_draw_memory, null);
    }
    if (self.chunk_data_buffer != .null_handle) {
        self.dev.destroyBuffer( self.chunk_data_buffer, null);
    }
    if (self.chunk_data_memory != .null_handle) {
        self.dev.freeMemory( self.chunk_data_memory, null);
    }

    // Destroy swapchain resources first (images, views, semaphores, fences, swapchain)
    if (self.swapchain != .null_handle) {
        for (self.swapchain_views) |view| {
            self.dev.destroyImageView( view, null);
        }

        // Destroy synchronization primitives
        for (self.image_acquired_semaphores) |sem| {
            if (sem != .null_handle) self.dev.destroySemaphore( sem, null);
        }
        for (self.render_complete_semaphores) |sem| {
            if (sem != .null_handle) self.dev.destroySemaphore( sem, null);
        }
        for (self.in_flight_fences) |fence| {
            if (fence != .null_handle) self.dev.destroyFence( fence, null);
        }

        self.allocator.free(self.image_acquired_semaphores);
        self.allocator.free(self.render_complete_semaphores);
        self.allocator.free(self.in_flight_fences);

        self.allocator.free(self.swapchain_images);
        self.allocator.free(self.swapchain_views);
        self.dev.destroySwapchainKHR( self.swapchain, null);
    }

    // Destroy render target images and views
    if (self.render_color_view != .null_handle) {
        self.dev.destroyImageView( self.render_color_view, null);
    }
    if (self.render_depth_view != .null_handle) {
        self.dev.destroyImageView( self.render_depth_view, null);
    }
    if (self.render_color_image != .null_handle) {
        self.dev.destroyImage( self.render_color_image, null);
    }
    if (self.render_depth_image != .null_handle) {
        self.dev.destroyImage( self.render_depth_image, null);
    }

    // Destroy pipeline and descriptor resources
    if (self.pipeline != .null_handle) {
        self.dev.destroyPipeline( self.pipeline, null);
    }
    if (self.transparent_pipeline != .null_handle) {
        self.dev.destroyPipeline( self.transparent_pipeline, null);
    }
    if (self.pipeline_layout != .null_handle) {
        self.dev.destroyPipelineLayout( self.pipeline_layout, null);
    }
    if (self.descriptor_set_layout != .null_handle) {
        self.dev.destroyDescriptorSetLayout( self.descriptor_set_layout, null);
    }
    if (self.descriptor_pool != .null_handle) {
        self.dev.destroyDescriptorPool( self.descriptor_pool, null);
    }

    // Destroy command pool last among device resources (destroys all allocated command buffers)
    if (self.command_pool != .null_handle) {
        self.dev.destroyCommandPool( self.command_pool, null);
    }

    self.dev.destroyDevice(null);
    self.instance_wrapper = undefined;
    self.dev_wrapper = undefined;
    self.instance.destroySurfaceKHR(self.surface, null);
    self.instance.destroyInstance(null);

    self.allocator.destroy(self);
}

// --- Chunk Management (Thread-safe) ---

fn vtableAddChunk(userdata: *anyopaque, io: std.Io, chunk_pos: ChunkPos, opaque_mesh: []Mesher.Face, transparent_mesh: []Mesher.Face) error{ OutOfMemory, OutOfVideoMemory, Unexpected }!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));

    // Acquire lock before mutating the mesh map to prevent iterator invalidation
    self.meshes_lock.lockUncancelable(io);
    defer self.meshes_lock.unlock(io);

    if (opaque_mesh.len > 0) {
        errdefer {} // autofix
        _ = self.uploadMeshLocked(io, .{ .@"opaque" = chunk_pos }, opaque_mesh) catch |err| switch (err) {
            error.OutOfHostMemory, error.OutOfDeviceMemory => return error.OutOfVideoMemory,
            else => return error.Unexpected,
        };
    } else {
        self.removeLocked(io, .{ .@"opaque" = chunk_pos });
    }

    if (transparent_mesh.len > 0) {
        _ = self.uploadMeshLocked(io, .{ .transparent = chunk_pos }, transparent_mesh) catch |err| switch (err) {
            error.OutOfHostMemory, error.OutOfDeviceMemory => return error.OutOfVideoMemory,
            else => return error.Unexpected,
        };
    } else {
        self.removeLocked(io, .{ .transparent = chunk_pos });
    }
}

fn uploadMeshLocked(self: *VulkanRenderer, io: std.Io, key: RenderBufferKey, faces: []Mesher.Face) !void {
    const buffer_size = @as(vk.DeviceSize, @intCast(faces.len)) * @sizeOf(Mesher.Face);

    // 1. Create Staging Buffer
    var staging_buffer: vk.Buffer = .null_handle;
    var staging_memory: vk.DeviceMemory = .null_handle;
    try self.createBuffer(
        buffer_size,
        .{ .transfer_src_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
        &staging_buffer,
        &staging_memory
    );
    defer {
        if (staging_buffer != .null_handle) self.dev.destroyBuffer( staging_buffer, null);
        if (staging_memory != .null_handle) self.dev.freeMemory( staging_memory, null);
    }

    // 2. Map & Copy
    const data = try self.dev.mapMemory(staging_memory, 0, buffer_size, .{});
    const mapped_slice = @as([*]u8, @ptrCast(data))[0..buffer_size];
    const src_slice = std.mem.sliceAsBytes(faces);
    @memcpy(mapped_slice, src_slice);
    self.dev.unmapMemory(staging_memory);

    // 3. Create Device Local Buffer with Shader Device Address bit
    var buffer: vk.Buffer = .null_handle;
    var memory: vk.DeviceMemory = .null_handle;

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

    memory = try self.dev.allocateMemory( &alloc_info, null);
    try self.dev.bindBufferMemory(buffer, memory, 0);

    // 4. Copy Staging -> Device
    try self.copyBuffer(staging_buffer, buffer, buffer_size);

    // 5. Get Buffer Device Address
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
        self.destroyChunkMesh(e);
    }
}

pub fn removeLocked(self: *VulkanRenderer, io: std.Io, key: RenderBufferKey) void {
    if (self.meshes.fetchRemove(io, key)) |mesh| {
        self.destroyChunkMesh(mesh);
    }
}

fn vtableRemoveChunk(userdata: *anyopaque, io: std.Io, chunk_pos: ChunkPos) void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));

    // Acquire lock before mutating the mesh map to prevent iterator invalidation
    self.meshes_lock.lockUncancelable(io);
    defer self.meshes_lock.unlock(io);

    self.removeLocked(io, .{ .@"opaque" = chunk_pos });
    self.removeLocked(io, .{ .transparent = chunk_pos });
}

fn destroyChunkMesh(self: *VulkanRenderer, mesh: ChunkMeshBuffer) void {
    if (mesh.buffer != .null_handle) self.dev.destroyBuffer( mesh.buffer, null);
    if (mesh.memory != .null_handle) self.dev.freeMemory( mesh.memory, null);
}

// --- Drawing & Multi-Draw Indirect ---

fn vtableDrawChunks(userdata: *anyopaque, io: std.Io, viewpos: @Vector(3, f64)) error{DrawFailed}!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));

    const c = tracy.Zone.begin(.{ .src = @src() });
    defer c.end();

    // Wait for previous frame to complete
    var fences_wait: [1]vk.Fence = .{self.in_flight_fences[self.current_frame_idx]};
    if (self.dev.waitForFences(&fences_wait, .true, std.math.maxInt(u64))) |res| {
        if (res != .success) return error.DrawFailed;
    } else |_| return error.DrawFailed;

    // Reset fence for this frame
    var fences_reset: [1]vk.Fence = .{self.in_flight_fences[self.current_frame_idx]};
    _ = self.dev.resetFences(&fences_reset) catch |err| switch (err) {
        else => {},
    };

    // Acquire next swapchain image
    var image_index: u32 = 0;
    const acquire_result_res = self.dev.acquireNextImageKHR(
        self.swapchain,
        std.math.maxInt(u64),
        self.image_acquired_semaphores[self.current_frame_idx],
        .null_handle, // Fence not used when semaphore is provided
    ) catch |err| switch (err) {
        else => return error.DrawFailed,
    };

    if (acquire_result_res.result == vk.Result.error_out_of_date_khr or acquire_result_res.result == vk.Result.suboptimal_khr) {
        // Swapchain is out of date - recreate it
        self.createSwapchain() catch |err| switch (err) {
            else => {},
        };
        image_index = self.current_frame_idx % @as(u32, @intCast(self.swapchain_images.len));
    } else if (acquire_result_res.result != .success) {
        return error.DrawFailed;
    } else {
        image_index = acquire_result_res.image_index;
    }

    // Calculate projection/view math
    const aspect = @as(f32, @floatFromInt(self.viewport_pixels[0])) / @as(f32, @floatFromInt(self.viewport_pixels[1]));

    self.render_options_lock.lockSharedUncancelable(io);
    const draw_over = self.render_options.draw_over;
    const fov = std.math.degreesToRadians(self.render_options.fov);
    const day_length_sec = self.render_options.day_length_sec;
    self.render_options_lock.unlockShared(io);

    const proj = zm.Mat4f.perspectiveRH(fov, aspect, 0.01, 10000.0);

    // Create view matrix using lookAtRH
    const viewpos_f32: @Vector(3, f32) = @floatCast(viewpos);
    const eye_vec = zm.vec.Vec3f{ .data = [3]f32{ viewpos_f32[0], viewpos_f32[1], viewpos_f32[2] } };
    const target_vec = zm.vec.Vec3f{ .data = [3]f32{
        viewpos_f32[0] + self.camera_front[0],
        viewpos_f32[1] + self.camera_front[1],
        viewpos_f32[2] + self.camera_front[2]
    } };
    const up_vec = zm.vec.Vec3f{ .data = [3]f32{ cameraUp[0], cameraUp[1], cameraUp[2] } };

    const view = zm.matrix.Mat4f.lookAtRH(eye_vec, target_vec, up_vec);

    // Reverse Z projection matrix like OpenGL
    var reverse_z_matrix = zm.matrix.Mat4f{
        .data = .{
            .{ proj.data[0][0], 0, 0, 0 },
            .{ 0, proj.data[1][1], 0, 0 },
            .{ 0, 0, 1, -0.01 },
            .{ 0, 0, 1, 0 },
        },
    };
    reverse_z_matrix = reverse_z_matrix.transpose();
    const projection = reverse_z_matrix;
    const projview = @as(@Vector(16, f32), @bitCast(projection.multiply(view).data));

    // Sun direction (directional light)
    const sun_angle = @rem(@as(f128, @floatFromInt(std.Io.Timestamp.now(io, .real).nanoseconds)) / ((@as(f128, @max(0.001, day_length_sec)) * std.time.ns_per_s) / 360), 360.0);
    const sun_rot_mat = zm.Mat4f.rotationRH(.{ .data = @Vector(3, f32){ 1.0, 0.0, 0.0 } }, @floatCast(std.math.degreesToRadians(sun_angle)));
    const sun_dir: @Vector(3, f32) = .{ sun_rot_mat.data[1][0], sun_rot_mat.data[1][1], sun_rot_mat.data[1][2] };

    const millitimestamp = std.Io.Timestamp.now(io, .real).toMilliseconds();

    // Begin Command Buffer
    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };
    self.dev.beginCommandBuffer(self.cmd_buffer, &begin_info) catch |err| switch (err) {
        else => return error.DrawFailed,
    };

    // Begin Dynamic Rendering with depth attachment for reversed-Z support
    const color_attachment = vk.RenderingAttachmentInfo{
        .s_type = .rendering_attachment_info,
        .image_view = self.render_color_view,
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_view = .null_handle,
        .resolve_image_layout = .undefined,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = .{ 0.53, 0.81, 0.92, 1.0 } } },
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
    self.dev.cmdBeginRendering(self.cmd_buffer, &render_info);

    // Bind Opaque Pipeline
    self.dev.cmdBindPipeline(self.cmd_buffer, .graphics, self.pipeline);

    // Set viewport and scissor (dynamic states)
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
    self.dev.cmdSetViewport(self.cmd_buffer, 0, &viewport_arr);
    var scissor_arr: [1]vk.Rect2D = undefined;
    scissor_arr[0] = scissor;
    self.dev.cmdSetScissor(self.cmd_buffer, 0, &scissor_arr);

    // Bind Descriptor Sets
    var desc_set_arr: [1]vk.DescriptorSet = undefined;
    desc_set_arr[0] = self.global_descriptor_set;
    self.dev.cmdBindDescriptorSets(
        self.cmd_buffer,
        .graphics,
        self.pipeline_layout,
        0,
        &desc_set_arr,
        null,
    );

    // Push Constants
    var pc = PushConstants{
        .projview = std.mem.zeroes([16]f32),
        .sun_dir = @as([3]f32, @bitCast(sun_dir)),
        .time = @floatFromInt(millitimestamp),
        .draw_over = if (draw_over) 1 else 0,
    };

    // Populate projview matrix into push constants
    inline for (0..16) |i| {
        pc.projview[i] = @as([16]f32, @bitCast(projview))[i];
    }

    self.dev.cmdPushConstants(
        self.cmd_buffer,
        self.pipeline_layout,
        .{ .vertex_bit = true, .fragment_bit = true },
        0,
        @sizeOf(PushConstants),
        @ptrCast(&pc)
    );

    // Draw Opaque and Transparent passes
    const frustum = Frustum.extractFrustumPlanes(projview);

    // Draw opaque chunks with opaque pipeline (already bound)
    self.drawChunksReal(io, viewpos, frustum, false) catch |err| switch (err) {
        else => return error.DrawFailed,
    };// Opaque

    // Bind transparent pipeline for transparent rendering (depth_write_enable = .false)
    self.dev.cmdBindPipeline(self.cmd_buffer, .graphics, self.transparent_pipeline);

    // Draw transparent chunks with transparent pipeline
    self.drawChunksReal(io, viewpos, frustum, true) catch |err| switch (err) {
        else => return error.DrawFailed,
    };  // Transparent

    self.dev.cmdEndRendering(self.cmd_buffer);

    // Copy render color image to swapchain image for presentation - include in main command buffer
    // Transition render_color_image to transfer_src_optimal
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

    self.dev.cmdPipelineBarrier(self.cmd_buffer, .{ .color_attachment_output_bit = true }, .{ .transfer_bit = true }, .{}, null, null, @ptrCast(&[_]vk.ImageMemoryBarrier{color_to_copy_barrier}));

    // Transition swapchain image to transfer_dst_optimal
    const swapchain_barrier = vk.ImageMemoryBarrier{
        .old_layout = .present_src_khr,
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

    self.dev.cmdPipelineBarrier(self.cmd_buffer, .{ .bottom_of_pipe_bit = true }, .{ .transfer_bit = true }, .{}, null, null, @ptrCast(&[_]vk.ImageMemoryBarrier{swapchain_barrier}));

    // Copy from render color image to swapchain image
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
            self.cmd_buffer,
            self.render_color_image,
            .transfer_src_optimal,
            self.swapchain_images[image_index],
            .transfer_dst_optimal,
            &copy_region_arr,
        );

    // Transition swapchain image to present_src_khr
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

    self.dev.cmdPipelineBarrier(self.cmd_buffer, .{ .transfer_bit = true }, .{ .bottom_of_pipe_bit = true }, .{}, null, null, @ptrCast(&[_]vk.ImageMemoryBarrier{present_barrier}));

    self.dev.endCommandBuffer(self.cmd_buffer) catch |err| switch (err) {
        else => return error.DrawFailed,
    };

    // Submit to queue with synchronization primitives
    const wait_stages = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};

    const submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&self.image_acquired_semaphores[self.current_frame_idx]),
        .p_wait_dst_stage_mask = &wait_stages,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&self.cmd_buffer),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&self.render_complete_semaphores[self.current_frame_idx]),
    };

    self.dev.queueSubmit(self.graphics_queue, &[_]vk.SubmitInfo{submit_info}, self.in_flight_fences[self.current_frame_idx]) catch |err| switch (err) {
        else => return error.DrawFailed,
    };

    // Prepare present info
    const present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&self.render_complete_semaphores[self.current_frame_idx]),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.swapchain),
        .p_image_indices = &[_]u32{image_index},
        .p_results = undefined,
    };

    const present_result = self.dev.queuePresentKHR(self.present_queue, &present_info) catch |err| switch (err) {
        else => return error.DrawFailed,
    };

    // Advance to next frame
    if (present_result == .success or present_result == .suboptimal_khr) {
        self.current_frame_idx = (self.current_frame_idx + 1) % @as(u32, @intCast(self.in_flight_fences.len));
    } else if (present_result == vk.Result.error_out_of_date_khr or present_result == vk.Result.suboptimal_khr) {
        // Swapchain is out of date - recreate it on next frame
        self.createSwapchain() catch |create_err| switch (create_err) {
            else => {},
        };
    }
}

fn drawChunksReal(self: *VulkanRenderer, io: std.Io, playerPos: @Vector(3, f64), frustum: Frustum, is_transparent: bool) !void {

    const indirect_mapped = try self.dev.mapMemory(self.indirect_draw_memory, 0, vk.WHOLE_SIZE, .{});
    defer self.dev.unmapMemory(self.indirect_draw_memory);

    const chunk_data_mapped = try self.dev.mapMemory(self.chunk_data_memory, 0, vk.WHOLE_SIZE, .{});
    defer self.dev.unmapMemory(self.chunk_data_memory);

    var indirect_cmds: [*]vk.DrawIndirectCommand = @ptrCast(@alignCast(indirect_mapped));
    var chunk_data: [*]ChunkData = @ptrCast(@alignCast(chunk_data_mapped));

    var draw_count: u32 = 0;

    self.meshes_lock.lockUncancelable(io);
    defer self.meshes_lock.unlock(io);

    // For transparent sorting, collect data first then sort
    if (is_transparent) {
        // Temporary storage for transparent chunks with distance info
        const TransparentDraw = struct {
            dist_sq: f64,
            chunkpos: ChunkPos,
            mesh: *const ChunkMeshBuffer,
            ratio: @Vector(3, f64),
            chunk_blockpos: @Vector(3, f64),
        };
        var transparent_draws: [100_000]TransparentDraw = undefined;
        var trans_count: usize = 0;

        var it = self.meshes.iterator();
        while (try it.next(io)) |entry| {
            const key = entry.key_ptr.*;
            if (key != .transparent) continue;

            const chunkpos = key.toPos();

            if (!cullChunk(&frustum, chunkpos)) {
                const mesh = &entry.value_ptr.*;

                const ratio: @Vector(3, f64) = @splat(@floatCast(ChunkPos.levelToBlockRatioFloat(chunkpos.level)));
                const chunk_blockpos = @as(@Vector(3, f64), @floatFromInt(chunkpos.position)) * ratio;

                // Calculate distance squared from player for sorting (back-to-front)
                var dist_sq: f64 = 0;
                inline for (0..3) |i| {
                    dist_sq += std.math.pow(f64, chunk_blockpos[i] - playerPos[i], 2);
                }

                if (trans_count < transparent_draws.len) {
                    transparent_draws[trans_count] = .{
                        .dist_sq = dist_sq,
                        .chunkpos = chunkpos,
                        .mesh = mesh,
                        .ratio = ratio,
                        .chunk_blockpos = chunk_blockpos,
                    };
                    trans_count += 1;
                }

                if (trans_count >= self.max_draw_count) break;
            }
        }

        // Sort by distance descending (back-to-front for transparency)
        std.sort.block(TransparentDraw, transparent_draws[0..trans_count], {}, struct {
            pub fn lessThan(_: void, a: TransparentDraw, b: TransparentDraw) bool {
                return a.dist_sq > b.dist_sq;
            }
        }.lessThan);

        // Populate chunk_data and indirect_cmds in sorted order
        for (transparent_draws[0..trans_count], 0..) |td, i| {
            draw_count = @intCast(i);

            const relative_blockpos = td.chunk_blockpos - playerPos;

            chunk_data[draw_count] = .{
                .absolute_position = @as([3]f32, @bitCast(@as(@Vector(3, f32), @floatCast(td.chunk_blockpos)))),
                .relative_position = @as([3]f32, @bitCast(@as(@Vector(3, f32), @floatCast(relative_blockpos)))),
                .scale = ChunkPos.toScale(td.chunkpos.level),
                .address = td.mesh.device_address,
            };

            indirect_cmds[draw_count] = .{
                .vertex_count = td.mesh.face_count * 6,
                .instance_count = 1,
                .first_vertex = 0,
                .first_instance = draw_count, // Use gl_DrawID to index SSBO
            };

            if (draw_count + 1 >= self.max_draw_count) break;
        }
        if (trans_count < @as(usize, self.max_draw_count)) {
            draw_count = @intCast(trans_count);
        } else {
            draw_count = self.max_draw_count;
        }
    } else {
        // Opaque pass - no sorting needed
        var it = self.meshes.iterator();
        while (try it.next(io)) |entry| {
            const key = entry.key_ptr.*;
            if ((key == .transparent) != is_transparent) continue;

            const chunkpos = key.toPos();

            if (!cullChunk(&frustum, chunkpos)) {
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
                    .vertex_count = mesh.face_count * 6,
                    .instance_count = 1,
                    .first_vertex = 0,
                    .first_instance = draw_count, // Use gl_DrawID to index SSBO
                };

                draw_count += 1;
                if (draw_count >= self.max_draw_count) break;
            }
        }
    }

    if (draw_count == 0) return;

    // Pipeline Barrier: Ensure CPU writes to Mapped memory are visible to GPU before drawing
    const memory_barrier = vk.MemoryBarrier{
        .src_access_mask = .{ .host_write_bit = true },
        .dst_access_mask = .{ .indirect_command_read_bit = true, .shader_read_bit = true },
    };

    var memory_barrier_arr: [1]vk.MemoryBarrier = undefined;
    memory_barrier_arr[0] = memory_barrier;

    self.dev.cmdPipelineBarrier(
        self.cmd_buffer,
        .{ .host_bit = true },
        .{ .draw_indirect_bit = true, .vertex_shader_bit = true },
        .{},
        &memory_barrier_arr,
        null,
        null,
    );

    // Multi-Draw Indirect
    self.dev.cmdDrawIndirect(
        self.cmd_buffer,
        self.indirect_draw_buffer,
        0,
        draw_count,
        @sizeOf(vk.DrawIndirectCommand)
    );
}

// --- Helpers & Boilerplate ---

fn allocateIndirectBuffers(self: *VulkanRenderer) !void {
    const indirect_size = @as(vk.DeviceSize, @intCast(self.max_draw_count)) * @sizeOf(vk.DrawIndirectCommand);
    try self.createBuffer(
        indirect_size,
        .{ .indirect_buffer_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
        &self.indirect_draw_buffer,
        &self.indirect_draw_memory
    );

    const chunk_data_size = @as(vk.DeviceSize, @intCast(self.max_draw_count)) * @sizeOf(ChunkData);
    try self.createBuffer(
        chunk_data_size,
        .{ .storage_buffer_bit = true }, // SSBO
        .{ .host_visible_bit = true, .host_coherent_bit = true },
        &self.chunk_data_buffer,
        &self.chunk_data_memory
    );
}

fn createBuffer(self: *VulkanRenderer, size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags, buffer: *vk.Buffer, memory: *vk.DeviceMemory) !void {
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
    memory.* = try self.dev.allocateMemory( &alloc_info, null);
    try self.dev.bindBufferMemory(buffer.*, memory.*, 0);
}

fn copyBuffer(self: *VulkanRenderer, src: vk.Buffer, dst: vk.Buffer, size: vk.DeviceSize) !void {
    const alloc_info = vk.CommandBufferAllocateInfo{
        .level = .primary,
        .command_pool = self.command_pool,
        .command_buffer_count = 1,
    };
    var cmd: vk.CommandBuffer = undefined;
    try self.dev.allocateCommandBuffers( &alloc_info, @ptrCast(&cmd));

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
    try self.dev.queueWaitIdle(self.graphics_queue);

    self.dev.freeCommandBuffers(self.command_pool, &[_]vk.CommandBuffer{cmd});
}

fn findMemoryType(self: VulkanRenderer, type_filter: u32, properties: vk.MemoryPropertyFlags) u32 {
    for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
        if ((type_filter & (@as(u32, 1) << @as(u5, @intCast(i)))) != 0 and (mem_type.property_flags.toInt() & properties.toInt()) == properties.toInt()) {
            return @as(u32, @intCast(i));
        }
    }
    @panic("Failed to find suitable memory type");
}

fn cullChunk(frustum: *const Frustum, chunkpos: ChunkPos) bool {
    const ratio: @Vector(3, f64) = @splat(@floatCast(ChunkPos.levelToBlockRatioFloat(chunkpos.level)));
    // Calculate center in absolute world coordinates (not relative to player)
    const cpos = @as(@Vector(3, f64), @floatFromInt(chunkpos.position)) * ratio;
    const cpos_f32 = @as(@Vector(3, f32), @floatCast(cpos));
    const scale = ChunkPos.toScale(chunkpos.level);
    const radius = 16.0 * std.math.sqrt(3.0) * scale;
    const center = cpos_f32 + @as(@Vector(3, f32), @splat(16.0 * scale));
    return !frustum.sphereInFrustum(center, radius);
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
                f,
                0.0,
                0.0,
            },
            .{
                0.0,
                0.0,
                0.0,
                -1.0,
            },
            .{
                0.0,
                0.0,
                zNear,
                0.0,
            },
        },
    };
}

// --- Swapchain Creation ---

fn destroyOldSwapchainResources(self: *VulkanRenderer) void {
    // Destroy old swapchain images and views
    for (self.swapchain_views) |view| {
        if (view != .null_handle) self.dev.destroyImageView( view, null);
    }
    self.allocator.free(self.swapchain_images);
    self.swapchain_images = &.{};
    self.swapchain_views = &.{};

    // Destroy synchronization primitives
    for (self.image_acquired_semaphores) |sem| {
        if (sem != .null_handle) self.dev.destroySemaphore( sem, null);
    }
    for (self.render_complete_semaphores) |sem| {
        if (sem != .null_handle) self.dev.destroySemaphore( sem, null);
    }
    for (self.in_flight_fences) |fence| {
        if (fence != .null_handle) self.dev.destroyFence( fence, null);
    }
    self.allocator.free(self.image_acquired_semaphores);
    self.allocator.free(self.render_complete_semaphores);
    self.allocator.free(self.in_flight_fences);

    // Destroy render target images and views
    if (self.render_color_view != .null_handle) {
        self.dev.destroyImageView( self.render_color_view, null);
        self.render_color_view = .null_handle;
    }
    if (self.render_depth_view != .null_handle) {
        self.dev.destroyImageView( self.render_depth_view, null);
        self.render_depth_view = .null_handle;
    }
    if (self.render_color_image != .null_handle) {
        self.dev.destroyImage( self.render_color_image, null);
        self.render_color_image = .null_handle;
    }
    if (self.render_depth_image != .null_handle) {
        self.dev.destroyImage( self.render_depth_image, null);
        self.render_depth_image = .null_handle;
    }

    // Destroy old swapchain
    if (self.swapchain != .null_handle) {
        self.dev.destroySwapchainKHR(self.swapchain, null);
        self.swapchain = .null_handle;
    }
}

fn createSwapchain(self: *VulkanRenderer) !void {
    const caps = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.pdev, self.surface);

    // Clean up old swapchain resources before creating new ones
    if (self.swapchain != .null_handle or self.swapchain_images.len > 0 or self.render_color_image != .null_handle) {
        self.destroyOldSwapchainResources();
    }

    var actual_extent = self.swapchain_extent;
    if (caps.current_extent.width != 0xFFFF_FFFF) {
        actual_extent = caps.current_extent;
    } else {
        actual_extent = .{
            .width = std.math.clamp(self.swapchain_extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(self.swapchain_extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
        };
    }

    self.swapchain_extent = actual_extent;

    // Find surface format
    var format_count: u32 = 0;
    _ = try self.instance.getPhysicalDeviceSurfaceFormatsKHR(self.pdev, self.surface, &format_count, null);
    const surface_formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.pdev, self.surface, self.allocator);
    defer self.allocator.free(surface_formats);

    var surface_format: vk.SurfaceFormatKHR = surface_formats[0];
    for (surface_formats) |sfmt| {
        if (sfmt.format == .b8g8r8a8_srgb or sfmt.format == .r8g8b8a8_unorm) {
            surface_format = sfmt;
            break;
        }
    }

    // Find present mode
    var present_mode_count: u32 = 0;
    _ = try self.instance.getPhysicalDeviceSurfacePresentModesKHR(self.pdev, self.surface, &present_mode_count, null);
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
        .image_format = surface_format.format,
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
        .old_swapchain = self.swapchain,
    }, null);

    // Create swapchain images and views
    const swap_images = try self.dev.getSwapchainImagesAllocKHR(self.swapchain, self.allocator);
    defer self.allocator.free(swap_images);

    self.swapchain_images = try self.allocator.alloc(vk.Image, swap_images.len);
    errdefer self.allocator.free(self.swapchain_images);
    @memcpy(self.swapchain_images, swap_images);

    self.swapchain_views = try self.allocator.alloc(vk.ImageView, swap_images.len);
    errdefer self.allocator.free(self.swapchain_views);

    for (swap_images, 0..) |image, i| {
        const view_info = vk.ImageViewCreateInfo{
            .flags = .{},
            .image = image,
            .view_type = .@"2d",
            .format = surface_format.format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        self.swapchain_views[i] = try self.dev.createImageView( &view_info, null);
    }

    // Create swapchain synchronization primitives
    const num_swapchain_images = self.swapchain_images.len;

    self.image_acquired_semaphores = try self.allocator.alloc(vk.Semaphore, num_swapchain_images);
    errdefer {
        for (self.image_acquired_semaphores) |sem| {
            if (sem != .null_handle) self.dev.destroySemaphore( sem, null);
        }
        self.allocator.free(self.image_acquired_semaphores);
    }

    self.render_complete_semaphores = try self.allocator.alloc(vk.Semaphore, num_swapchain_images);
    errdefer {
        for (self.render_complete_semaphores) |sem| {
            if (sem != .null_handle) self.dev.destroySemaphore( sem, null);
        }
        self.allocator.free(self.render_complete_semaphores);
    }

    self.in_flight_fences = try self.allocator.alloc(vk.Fence, num_swapchain_images);
    errdefer {
        for (self.in_flight_fences) |fence| {
            if (fence != .null_handle) self.dev.destroyFence( fence, null);
        }
        self.allocator.free(self.in_flight_fences);
    }

    const semaphore_create_info = vk.SemaphoreCreateInfo{.flags = .{}};
    const fence_create_info = vk.FenceCreateInfo{
        .flags = .{ .signaled_bit = true },
    };

    for (0..num_swapchain_images) |i| {
        self.image_acquired_semaphores[i] = try self.dev.createSemaphore(&semaphore_create_info, null);
        self.render_complete_semaphores[i] = try self.dev.createSemaphore(&semaphore_create_info, null);
        self.in_flight_fences[i] = try self.dev.createFence(&fence_create_info, null);
    }

    // Create render target images for dynamic rendering with depth support
    try self.createRenderTargets(actual_extent);
}

fn createRenderTargets(self: *VulkanRenderer, extent: vk.Extent2D) !void {
    // Destroy existing render targets if any
    if (self.render_color_view != .null_handle) {
        self.dev.destroyImageView( self.render_color_view, null);
        self.render_color_view = .null_handle;
    }
    if (self.render_depth_view != .null_handle) {
        self.dev.destroyImageView( self.render_depth_view, null);
        self.render_depth_view = .null_handle;
    }
    if (self.render_color_image != .null_handle) {
        self.dev.destroyImage( self.render_color_image, null);
        self.render_color_image = .null_handle;
    }
    if (self.render_depth_image != .null_handle) {
        self.dev.destroyImage( self.render_depth_image, null);
        self.render_depth_image = .null_handle;
    }

    // Create color image
    const color_image_info = vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .format = .b8g8r8a8_srgb, // Match swapchain format
        .tiling = .optimal,
        .initial_layout = .undefined,
        .usage = .{ .color_attachment_bit = true, .transfer_src_bit = true },
        .sharing_mode = .exclusive,
        .samples = .{ .@"1_bit" = true },
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };

    self.render_color_image = try self.dev.createImage( &color_image_info, null);

    const color_mem_reqs = self.dev.getImageMemoryRequirements(self.render_color_image);
    const color_alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = color_mem_reqs.size,
        .memory_type_index = self.findMemoryType(color_mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    };
    const color_memory = try self.dev.allocateMemory( &color_alloc_info, null);
    try self.dev.bindImageMemory( self.render_color_image, color_memory, 0);

    // Transition color image to color_attachment_optimal
    {
        const cmd = try self.beginSingleTimeCommands();
        defer self.endSingleTimeCommands(cmd) catch {};

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

    // Create color image view
    const color_view_info = vk.ImageViewCreateInfo{
        .flags = .{},
        .image = self.render_color_image,
        .view_type = .@"2d",
        .format = .b8g8r8a8_srgb,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    self.render_color_view = try self.dev.createImageView( &color_view_info, null);

    // Create depth image (D32_SFLOAT for reversed-Z support)
    const depth_format: vk.Format = .d32_sfloat_s8_uint;

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

    self.render_depth_image = try self.dev.createImage( &depth_image_info, null);

    const depth_mem_reqs = self.dev.getImageMemoryRequirements(self.render_depth_image);
    const depth_alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = depth_mem_reqs.size,
        .memory_type_index = self.findMemoryType(depth_mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    };
    const depth_memory = try self.dev.allocateMemory( &depth_alloc_info, null);
    try self.dev.bindImageMemory( self.render_depth_image, depth_memory, 0);

    // Transition depth image to depth_stencil_attachment_optimal
    {
        const cmd = try self.beginSingleTimeCommands();
        defer self.endSingleTimeCommands(cmd) catch {};

        const barrier = vk.ImageMemoryBarrier{
            .old_layout = .undefined,
            .new_layout = .depth_stencil_attachment_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.render_depth_image,
            .subresource_range = .{
                .aspect_mask = .{ .depth_bit = true },
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

    // Create depth image view
    const depth_view_info = vk.ImageViewCreateInfo{
        .flags = .{},
        .image = self.render_depth_image,
        .view_type = .@"2d",
        .format = depth_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .depth_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    self.render_depth_view = try self.dev.createImageView( &depth_view_info, null);

    std.log.info("Created render targets: color image {}, depth image {}\n", .{ self.render_color_image, self.render_depth_image });
}

// --- Descriptor Set Layout and Pipeline ---

fn createDescriptorSetLayout(self: *VulkanRenderer) !void {
    // Binding 0: SSBO for Chunk Data (Multi-Draw Indirect)
    const chunk_data_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex_bit = true },
        .p_immutable_samplers = null,
    };

    // Binding 1: Texture Array for block textures
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

    self.descriptor_set_layout = try self.dev.createDescriptorSetLayout(&layout_info, null);
}

fn createDescriptorPoolAndSets(self: *VulkanRenderer) !void {
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .storage_buffer, .descriptor_count = 1 },
        .{ .type = .combined_image_sampler, .descriptor_count = 1 },
    };

    const pool_info = vk.DescriptorPoolCreateInfo{
        .flags = .{},
        .max_sets = 1, // Only need 1 global set for the whole engine
        .pool_size_count = pool_sizes.len,
        .p_pool_sizes = @ptrCast(&pool_sizes),
    };

    self.descriptor_pool = try self.dev.createDescriptorPool(&pool_info, null);

    const alloc_info = vk.DescriptorSetAllocateInfo{
        .descriptor_pool = self.descriptor_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&self.descriptor_set_layout),
    };

    var desc_sets: [1]vk.DescriptorSet = undefined;
    try self.dev.allocateDescriptorSets(&alloc_info, &desc_sets);
    self.global_descriptor_set = desc_sets[0];

    // Write Binding 0 (The Chunk Data SSBO) to the descriptor set once here
    const chunk_data_write = vk.WriteDescriptorSet{
        .dst_set = self.global_descriptor_set,
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .storage_buffer,
        .p_image_info = undefined,
        .p_buffer_info = @ptrCast(&.{
            vk.DescriptorBufferInfo{
                .buffer = self.chunk_data_buffer,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }
        }),
        .p_texel_buffer_view = undefined,
    };

    // Write Binding 1 (Texture Array) - use default/dummy texture if not loaded yet
    var texture_image_info_descriptor: ?vk.DescriptorImageInfo = null;

    // Create a default 1x1 white dummy texture and sampler for binding 1
    const dummy_white_pixel: [4]u8 = .{ 255, 255, 255, 255 };

    var staging_buffer_dummy: vk.Buffer = .null_handle;
    var staging_memory_dummy: vk.DeviceMemory = .null_handle;
    try self.createBuffer(
        @as(vk.DeviceSize, 4),
        .{ .transfer_src_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
        &staging_buffer_dummy,
        &staging_memory_dummy
    );

    const dummy_data = try self.dev.mapMemory(staging_memory_dummy, 0, @as(vk.DeviceSize, 4), .{});
    @memcpy(@as([*]u8, @ptrCast(dummy_data))[0..4], &dummy_white_pixel);
    self.dev.unmapMemory(staging_memory_dummy);

    const dummy_image_info = vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .extent = .{ .width = 1, .height = 1, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .format = .r8g8b8a8_unorm,
        .tiling = .optimal,
        .initial_layout = .undefined,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .sharing_mode = .exclusive,
        .samples = .{ .@"1_bit" = true },
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };

    const dummy_image = try self.dev.createImage(&dummy_image_info, null);

    const dummy_mem_reqs = self.dev.getImageMemoryRequirements(dummy_image);
    const dummy_alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = dummy_mem_reqs.size,
        .memory_type_index = self.findMemoryType(dummy_mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    };
    const dummy_memory = try self.dev.allocateMemory(&dummy_alloc_info, null);
    try self.dev.bindImageMemory(dummy_image, dummy_memory, 0);

    // Transition layout and copy data
    {
        const cmd = try self.beginSingleTimeCommands();
        defer self.endSingleTimeCommands(cmd) catch {};

        var barrier = vk.ImageMemoryBarrier{
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = dummy_image,
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

        self.dev.cmdPipelineBarrier(cmd, .{ .top_of_pipe_bit = true }, .{ .transfer_bit = true }, .{}, null, null, @ptrCast(&[_]vk.ImageMemoryBarrier{barrier}));

        const copy_region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = 1, .height = 1, .depth = 1 },
        };

        var copy_region_arr: [1]vk.BufferImageCopy = undefined;
        copy_region_arr[0] = copy_region;

        self.dev.cmdCopyBufferToImage(cmd, staging_buffer_dummy, dummy_image, .transfer_dst_optimal, &copy_region_arr);


        // Transition to shader_read_only_optimal
        barrier.old_layout = .transfer_dst_optimal;
        barrier.new_layout = .shader_read_only_optimal;
        barrier.src_access_mask = .{ .transfer_write_bit = true };
        barrier.dst_access_mask = .{ .shader_read_bit = true };

        self.dev.cmdPipelineBarrier(cmd, .{ .transfer_bit = true }, .{ .fragment_shader_bit = true }, .{}, null, null, @ptrCast(&[_]vk.ImageMemoryBarrier{barrier}));
    }

    const dummy_view_info = vk.ImageViewCreateInfo{
        .flags = .{},
        .image = dummy_image,
        .view_type = .@"2d",
        .format = .r8g8b8a8_unorm,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    const dummy_view = try self.dev.createImageView(&dummy_view_info, null);

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

    const dummy_sampler = try self.dev.createSampler(&sampler_info, null);

    texture_image_info_descriptor = vk.DescriptorImageInfo{
        .image_layout = .shader_read_only_optimal,
        .image_view = dummy_view,
        .sampler = dummy_sampler,
    };

    // Clean up staging buffer and memory
    if (staging_buffer_dummy != .null_handle) self.dev.destroyBuffer(staging_buffer_dummy, null);
    if (staging_memory_dummy != .null_handle) self.dev.freeMemory(staging_memory_dummy, null);

    const texture_array_write = vk.WriteDescriptorSet{
        .dst_set = self.global_descriptor_set,
        .dst_binding = 1,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = @ptrCast(&texture_image_info_descriptor.?),
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };

    self.dev.updateDescriptorSets(&[_]vk.WriteDescriptorSet{chunk_data_write, texture_array_write}, null);
}

fn createPipeline(self: *VulkanRenderer) !void {
    // Create Pipeline Layout
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

    self.pipeline_layout = try self.dev.createPipelineLayout(&layout_info, null);

    // Create Graphics Pipeline (Dynamic Rendering)
    const piasci = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };

    const pvsci = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = null, // set dynamically
        .scissor_count = 1,
        .p_scissors = null, // set dynamically
    };

    const prsci = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = true }, // Match OpenGL: gl.CullFace(gl.BACK)
        .front_face = .clockwise, // Match OpenGL: gl.FrontFace(gl.CW)
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const pmsci = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true }, // OpenGL uses gl.MULTISAMPLE but with samples=1 for swapchain
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    const pcbas = vk.PipelineColorBlendAttachmentState{
        .blend_enable = .true, // Match OpenGL: gl.Enable(gl.BLEND); gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
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

    // Depth stencil state: match OpenGL gl.DepthFunc(gl.GREATER) for reversed-Z
    const depth_stencil_state = vk.PipelineDepthStencilStateCreateInfo{
        .flags = .{},
        .depth_test_enable = .true,
        .depth_write_enable = .true,
        .depth_compare_op = .greater, // Match OpenGL: gl.DepthFunc(gl.GREATER) for reversed-Z
        .depth_bounds_test_enable = .false,
        .stencil_test_enable = .false,
        .front = undefined,
        .back = undefined,
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
    };

    // Create shader modules from embedded SPIR-V data
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

    // Create pipeline shader stage create info structures
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

    // Note: Vertex input state is empty for SSBO-based rendering - we use gl_VertexIndex and gl_DrawID

    const gpci = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = 2,
        .p_stages = &pssci,
        .p_vertex_input_state = null, // Empty for SSBO
        .p_input_assembly_state = &piasci,
        .p_tessellation_state = null,
        .p_viewport_state = &pvsci,
        .p_rasterization_state = &prsci,
        .p_multisample_state = &pmsci,
        .p_depth_stencil_state = &depth_stencil_state, // Reversed-Z depth test with GREATER compare op
        .p_color_blend_state = &pcbsci,
        .p_dynamic_state = &pdsci,
        .layout = self.pipeline_layout,
        .render_pass = .null_handle, // Dynamic rendering
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    const result = self.dev.createGraphicsPipelines(
        .null_handle,
        &.{gpci},
        null,
        (&pipeline)[0..1],
    );
    if (result) |res| {
        if (res != .success) return error.PipelineCreationFailed;
    } else |err| {
        return err;
    }

    // Clean up shader modules after pipeline creation
    self.dev.destroyShaderModule(vert_shader_module, null);
    self.dev.destroyShaderModule(frag_shader_module, null);

    self.pipeline = pipeline;
}

fn createTransparentPipeline(self: *VulkanRenderer) !void {
    // Create Graphics Pipeline for Transparent Rendering (Dynamic Rendering)
    const piasci = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };

    const pvsci = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = null, // set dynamically
        .scissor_count = 1,
        .p_scissors = null, // set dynamically
    };

    const prsci = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = true }, // Match OpenGL: gl.CullFace(gl.BACK)
        .front_face = .clockwise, // Match OpenGL: gl.FrontFace(gl.CW)
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const pmsci = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true }, // OpenGL uses gl.MULTISAMPLE but with samples=1 for swapchain
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    const pcbas = vk.PipelineColorBlendAttachmentState{
        .blend_enable = .true, // Match OpenGL: gl.Enable(gl.BLEND); gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
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

    // Depth stencil state: match OpenGL gl.DepthFunc(gl.GREATER) for reversed-Z, but depth_write_enable = .false for transparency
    const depth_stencil_state_transparent = vk.PipelineDepthStencilStateCreateInfo{
        .flags = .{},
        .depth_test_enable = .true,
        .depth_write_enable = .false, // Do not write to depth buffer for transparent rendering
        .depth_compare_op = .greater, // Match OpenGL: gl.DepthFunc(gl.GREATER) for reversed-Z
        .depth_bounds_test_enable = .false,
        .stencil_test_enable = .false,
        .front = undefined,
        .back = undefined,
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
    };

    // Create shader modules from embedded SPIR-V data (reuse existing ones if possible)
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

    // Create pipeline shader stage create info structures
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

    const gpci_transparent = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = 2,
        .p_stages = &pssci,
        .p_vertex_input_state = null, // Empty for SSBO
        .p_input_assembly_state = &piasci,
        .p_tessellation_state = null,
        .p_viewport_state = &pvsci,
        .p_rasterization_state = &prsci,
        .p_multisample_state = &pmsci,
        .p_depth_stencil_state = &depth_stencil_state_transparent, // Reversed-Z depth test with GREATER compare op, no depth write
        .p_color_blend_state = &pcbsci,
        .p_dynamic_state = &pdsci,
        .layout = self.pipeline_layout,
        .render_pass = .null_handle, // Dynamic rendering
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var transparent_pipeline: vk.Pipeline = undefined;
    const result_transparent = self.dev.createGraphicsPipelines(
        .null_handle,
        &.{gpci_transparent},
        null,
        (&transparent_pipeline)[0..1],
    );
    if (result_transparent) |res| {
        if (res != .success) return error.PipelineCreationFailed;
    } else |err| {
        return err;
    }

    // Clean up shader modules after pipeline creation
    self.dev.destroyShaderModule(vert_shader_module, null);
    self.dev.destroyShaderModule(frag_shader_module, null);

    self.transparent_pipeline = transparent_pipeline;
}

// --- Helper functions for single-time commands ---

pub fn beginSingleTimeCommands(self: *VulkanRenderer) !vk.CommandBuffer {
    const alloc_info = vk.CommandBufferAllocateInfo{
        .level = .primary,
        .command_pool = self.command_pool,
        .command_buffer_count = 1,
    };
    var cmd: vk.CommandBuffer = undefined;
    try self.dev.allocateCommandBuffers( &alloc_info, @ptrCast(&cmd));

    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };
    try self.dev.beginCommandBuffer(cmd, &begin_info);

    return cmd;
}

pub fn endSingleTimeCommands(self: *VulkanRenderer, cmd: vk.CommandBuffer) !void {
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
    try self.dev.queueWaitIdle(self.graphics_queue);

    self.dev.freeCommandBuffers(self.command_pool, &[_]vk.CommandBuffer{cmd});
}

// --- Boilerplate implementations required by VTable ---
fn vtableClear(userdata: *anyopaque, viewpos: @Vector(3, f64)) error{DrawFailed}!void { _ = userdata; _ = viewpos; }
fn vtableSetViewport(userdata: *anyopaque, viewport_pixels: @Vector(2, u32)) error{ViewportSetFailed}!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));
    self.viewport_pixels = viewport_pixels;
}
fn vtableUpdateCameraDirection(userdata: *anyopaque, viewDir: @Vector(3, f32)) void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));
    self.camera_front = viewDir;
}
fn vtableGetCameraFront(userdata: *anyopaque) @Vector(3, f32) {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));
    return self.camera_front;
}
fn vtableForEachChunk(userdata: *anyopaque, io: std.Io, callback_userdata: *anyopaque, callback: *const fn (*anyopaque, ChunkPos) void) std.Io.Cancelable!void {
    const self: *VulkanRenderer = @ptrCast(@alignCast(userdata));
    self.meshes_lock.lock(io) catch return error.Canceled;
    defer self.meshes_lock.unlock(io);
    var it = self.meshes.iterator();
    while (try it.next(io)) |entry| {
        callback(callback_userdata, entry.key_ptr.*.toPos());
    }
}
