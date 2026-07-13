const std = @import("std");
const vk = @import("vulkan");
const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;
const InstanceProxy = vk.InstanceProxy;
const DeviceProxy = vk.DeviceProxy;
const wio = @import("wio");
const options = @import("options");
const tracy = @import("tracy");

pub const PresentMode = enum {
    vsync,
    mailbox,
    immediate,
};

pub const VulkanContext = @This();

allocator: std.mem.Allocator,
window: *wio.Window,
surface: vk.SurfaceKHR = .null_handle,

vkb: BaseWrapper,
instance_handle: vk.Instance,
instance_wrapper: ?*InstanceWrapper,
instance: InstanceProxy,

debug_callback: vk.DebugUtilsMessengerEXT,

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

image_acquired_semaphores: []vk.Semaphore = &.{},
render_complete_semaphores: []vk.Semaphore = &.{},
in_flight_fences: []vk.Fence = &.{},
current_frame_idx: std.atomic.Value(u32) = .init(0),
current_swapchain_image_index: u32 = 0,

swapchain: vk.SwapchainKHR = .null_handle,
swapchain_format: vk.Format = .b8g8r8a8_srgb,
swapchain_images: []vk.Image = &.{},
swapchain_views: []vk.ImageView = &.{},
swapchain_extent: vk.Extent2D = .{ .width = 800, .height = 600 },
swapchain_needs_recreate: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
present_mode: PresentMode = .mailbox,

transfer_queue: vk.Queue = undefined,
transfer_queue_family_index: u32 = undefined,
transfer_semaphore: vk.Semaphore = .null_handle,
transfer_semaphore_value: std.atomic.Value(u64) = .init(0),
graphics_timeline_semaphore: vk.Semaphore = .null_handle,
frame_number: std.atomic.Value(u64) = .init(1),
queue_mutex: std.Io.Mutex = .init,

fn getProcAddr(instance: vk.Instance, procname: [*:0]const u8) ?*const fn () void {
    return @ptrCast(wio.vkGetInstanceProcAddr(
        (@intFromEnum(instance)),
        procname,
    ));
}

fn selectPhysicalDevice(self: *VulkanContext, allocator: std.mem.Allocator) !vk.PhysicalDevice {
    var pdev_count: u32 = 0;
    _ = try self.instance.enumeratePhysicalDevices(&pdev_count, null);
    const pdevs = try allocator.alloc(vk.PhysicalDevice, pdev_count);
    defer allocator.free(pdevs);
    _ = try self.instance.enumeratePhysicalDevices(&pdev_count, pdevs.ptr);

    var selected_pdev: vk.PhysicalDevice = .null_handle;
    var best_score: u32 = 0;

    for (pdevs) |pdev| {
        var dynamic_rendering_features: vk.PhysicalDeviceDynamicRenderingFeatures = .{ .dynamic_rendering = .false, .p_next = null };
        var sync2_features: vk.PhysicalDeviceSynchronization2Features = .{ .synchronization_2 = .false, .p_next = @ptrCast(&dynamic_rendering_features) };
        var features12: vk.PhysicalDeviceVulkan12Features = .{
            .draw_indirect_count = .false,
            .descriptor_indexing = .false,
            .runtime_descriptor_array = .false,
            .descriptor_binding_partially_bound = .false,
            .buffer_device_address = .false,
            .timeline_semaphore = .false,
            .p_next = @ptrCast(&sync2_features),
        };
        var features2: vk.PhysicalDeviceFeatures2 = .{ .features = .{ .multi_draw_indirect = .false }, .p_next = @ptrCast(&features12) };
        self.instance.getPhysicalDeviceFeatures2(pdev, &features2);

        const required = features2.features.multi_draw_indirect == .true and
            features12.draw_indirect_count == .true and features12.descriptor_indexing == .true and
            features12.runtime_descriptor_array == .true and features12.descriptor_binding_partially_bound == .true and
            features12.buffer_device_address == .true and features12.timeline_semaphore == .true and
            sync2_features.synchronization_2 == .true and dynamic_rendering_features.dynamic_rendering == .true;
        if (!required) continue;

        var has_graphics = false;
        var has_present = false;
        const queue_families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
        defer allocator.free(queue_families);
        for (queue_families, 0..) |qf, i| {
            const family: u32 = @intCast(i);
            if (!has_graphics and qf.queue_flags.graphics_bit) has_graphics = true;
            if (!has_present and (try self.instance.getPhysicalDeviceSurfaceSupportKHR(pdev, family, self.surface)) == .true) has_present = true;
        }
        if (!has_graphics or !has_present) continue;

        const surface_formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(pdev, self.surface, allocator);
        defer allocator.free(surface_formats);
        const present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(pdev, self.surface, allocator);
        defer allocator.free(present_modes);
        if (surface_formats.len == 0 or present_modes.len == 0) continue;

        const props = self.instance.getPhysicalDeviceProperties(pdev);
        var score: u32 = if (props.device_type == .discrete_gpu) 10 else if (props.device_type == .integrated_gpu) 5 else 1;
        if (options.sanitize_thread) {
            const device_name = std.mem.sliceTo(&props.device_name, 0);
            if (std.mem.indexOf(u8, device_name, "NVIDIA") != null or std.mem.indexOf(u8, device_name, "nvidia") != null) score = 1;
        }
        if (score > best_score) {
            best_score = score;
            selected_pdev = pdev;
        }
    }
    if (selected_pdev == .null_handle) return error.NoSuitablePhysicalDevice;
    return selected_pdev;
}

fn selectQueueFamilies(self: *VulkanContext, allocator: std.mem.Allocator) !struct { graphics: u32, present: u32, transfer: u32 } {
    const queue_families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(self.pdev, allocator);
    defer allocator.free(queue_families);
    var graphics_family: u32 = 0;
    var present_family: u32 = 0;
    var transfer_family: ?u32 = null;
    var transfer_score: u8 = 0;
    for (queue_families, 0..) |qf, i| {
        const family: u32 = @intCast(i);
        if (graphics_family == 0 and qf.queue_flags.graphics_bit) graphics_family = family;
        if (present_family == 0 and (try self.instance.getPhysicalDeviceSurfaceSupportKHR(self.pdev, family, self.surface)) == .true) present_family = family;
        if (qf.queue_flags.transfer_bit) {
            const score: u8 = if (!qf.queue_flags.graphics_bit and !qf.queue_flags.compute_bit) 3 else if (!qf.queue_flags.graphics_bit) 2 else 1;
            if (score > transfer_score) {
                transfer_family = family;
                transfer_score = score;
            }
        }
    }
    if (present_family != graphics_family and
        (try self.instance.getPhysicalDeviceSurfaceSupportKHR(self.pdev, graphics_family, self.surface)) == .true)
    {
        present_family = graphics_family;
    }
    return .{ .graphics = graphics_family, .present = present_family, .transfer = transfer_family orelse graphics_family };
}

pub fn init(allocator: std.mem.Allocator, window: *wio.Window) !*VulkanContext {
    std.log.info("VulkanContext.init: Starting Vulkan initialization...", .{});

    const self = try allocator.create(VulkanContext);
    errdefer allocator.destroy(self);

    self.* = .{
        .debug_callback = .null_handle,
        .allocator = allocator,
        .window = window,
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
    };

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

    for (layers) |layer| {
        const name = std.mem.sliceTo(&layer.layer_name, 0);
        if (std.mem.eql(u8, name, "VK_LAYER_KHRONOS_validation")) {
            try enabled_layers.append(allocator, "VK_LAYER_KHRONOS_validation");
        }
    }

    var extension_names: std.ArrayList([*:0]const u8) = .empty;
    defer extension_names.deinit(allocator);

    const wio_extensions = wio.getRequiredVulkanInstanceExtensions();
    for (wio_extensions) |ext| {
        try extension_names.append(allocator, ext);
    }

    var has_portability = false;
    var has_debug_utils = false;
    const extensions = try self.vkb.enumerateInstanceExtensionPropertiesAlloc(null, allocator);
    defer allocator.free(extensions);
    for (extensions) |extension| {
        const name = std.mem.sliceTo(&extension.extension_name, 0);
        if (std.mem.eql(u8, name, "VK_KHR_portability_enumeration")) {
            try extension_names.append(allocator, "VK_KHR_portability_enumeration");
            has_portability = true;
        }
        if (std.mem.eql(u8, name, "VK_EXT_debug_utils")) {
            try extension_names.append(allocator, "VK_EXT_debug_utils");
            has_debug_utils = true;
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

    const instance_wrapper_ptr = try allocator.create(InstanceWrapper);

    instance_wrapper_ptr.* = .load(self.instance_handle, getProcAddr);
    self.instance_wrapper = instance_wrapper_ptr;
    self.instance = .init(self.instance_handle, instance_wrapper_ptr);
    errdefer {
        self.instance.destroyInstance(null);
        allocator.destroy(instance_wrapper_ptr);
        self.instance_wrapper = null;
    }

    const callback_create_info: vk.DebugUtilsMessengerCreateInfoEXT = .{
        .message_severity = .{
            .info_bit_ext = true,
            .verbose_bit_ext = true,
            .error_bit_ext = true,
            .warning_bit_ext = true,
        },
        .message_type = .{
            .device_address_binding_bit_ext = true,
            .validation_bit_ext = true,
            .performance_bit_ext = true,
            .general_bit_ext = true,
        },
        .pfn_user_callback = &debugCallback,
    };
    if (has_debug_utils) {
        self.debug_callback = try self.instance.createDebugUtilsMessengerEXT(&callback_create_info, null);
    }
    errdefer if (has_debug_utils) self.instance.destroyDebugUtilsMessengerEXT(self.debug_callback, null);

    var surface: vk.SurfaceKHR = .null_handle;
    const result: vk.Result = @enumFromInt(window.vkCreateSurface(@intFromEnum(self.instance.handle), null, @ptrCast(&surface)));
    if (result != .success) {
        return error.SurfaceCreationFailed;
    }
    self.surface = surface;
    errdefer self.instance.destroySurfaceKHR(self.surface, null);

    self.pdev = try self.selectPhysicalDevice(allocator);
    self.props = self.instance.getPhysicalDeviceProperties(self.pdev);
    self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);

    const ext_props = try self.instance.enumerateDeviceExtensionPropertiesAlloc(self.pdev, null, allocator);
    defer allocator.free(ext_props);
    var has_push_desc = false;
    for (ext_props) |ext| {
        const name = std.mem.sliceTo(&ext.extension_name, 0);
        if (std.mem.eql(u8, name, "VK_KHR_push_descriptor")) {
            has_push_desc = true;
        }
    }
    std.log.info("Physical device supports VK_KHR_push_descriptor: {}", .{has_push_desc});

    const qfamilies = try self.selectQueueFamilies(allocator);
    self.queue_family_index = qfamilies.graphics;
    self.present_queue_family_index = qfamilies.present;
    self.transfer_queue_family_index = qfamilies.transfer;

    const device_extensions: [4][*:0]const u8 = .{
        vk.extensions.khr_swapchain.name,
        vk.extensions.khr_dynamic_rendering.name,
        vk.extensions.ext_robustness_2.name,
        vk.extensions.khr_push_descriptor.name,
    };

    const queue_priority: f32 = 1.0;
    var queue_create_infos: [3]vk.DeviceQueueCreateInfo = undefined;
    var queue_count: u32 = 0;
    for ([_]u32{ qfamilies.graphics, qfamilies.present, qfamilies.transfer }) |f| {
        for (queue_create_infos[0..queue_count]) |q| {
            if (q.queue_family_index == f) break;
        } else {
            queue_create_infos[queue_count] = .{
                .flags = .{},
                .queue_family_index = f,
                .queue_count = 1,
                .p_queue_priorities = (&queue_priority)[0..1],
            };
            queue_count += 1;
        }
    }

    var robustness2_features: vk.PhysicalDeviceRobustness2FeaturesEXT = .{
        .robust_buffer_access_2 = .false,
        .robust_image_access_2 = .false,
        .null_descriptor = .true,
    };
    var dynamic_rendering_features: vk.PhysicalDeviceDynamicRenderingFeatures = .{
        .dynamic_rendering = .true,
        .p_next = @ptrCast(&robustness2_features),
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
            .independent_blend = .true,
        },
        .p_next = @ptrCast(&features11),
    };

    const device_info: vk.DeviceCreateInfo = .{
        .s_type = .device_create_info,
        .flags = .{},
        .queue_create_info_count = @intCast(queue_count),
        .p_queue_create_infos = queue_create_infos[0..queue_count].ptr,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = null,
        .enabled_extension_count = device_extensions.len,
        .pp_enabled_extension_names = device_extensions[0..],
        .p_enabled_features = null,
        .p_next = @ptrCast(&features),
    };

    self.dev_handle = try self.instance.createDevice(self.pdev, &device_info, null);

    const gdpa = self.instance.wrapper.dispatch.vkGetDeviceProcAddr orelse return error.MissingDeviceProcAddr;

    const dev_wrapper_ptr = try allocator.create(DeviceWrapper);

    dev_wrapper_ptr.* = .load(self.dev_handle, gdpa);
    self.dev_wrapper = dev_wrapper_ptr;
    self.dev = .init(self.dev_handle, dev_wrapper_ptr);
    errdefer {
        self.dev.destroyDevice(null);
        allocator.destroy(dev_wrapper_ptr);
        self.dev_wrapper = null;
    }

    self.graphics_queue = self.dev.getDeviceQueue(qfamilies.graphics, 0);
    self.present_queue = if (qfamilies.graphics == qfamilies.present) self.graphics_queue else self.dev.getDeviceQueue(qfamilies.present, 0);
    self.transfer_queue = self.dev.getDeviceQueue(qfamilies.transfer, 0);

    const pool_info: vk.CommandPoolCreateInfo = .{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = qfamilies.graphics,
    };
    self.command_pool = try self.dev.createCommandPool(&pool_info, null);
    errdefer self.dev.destroyCommandPool(self.command_pool, null);

    const upload_pool_info: vk.CommandPoolCreateInfo = .{
        .flags = .{ .reset_command_buffer_bit = true, .transient_bit = true },
        .queue_family_index = qfamilies.graphics,
    };
    self.upload_command_pool = try self.dev.createCommandPool(&upload_pool_info, null);
    errdefer self.dev.destroyCommandPool(self.upload_command_pool, null);

    var timeline_info: vk.SemaphoreTypeCreateInfo = .{
        .semaphore_type = .timeline,
        .initial_value = 0,
    };
    const timeline_sem_info: vk.SemaphoreCreateInfo = .{
        .p_next = &timeline_info,
        .flags = .{},
    };
    self.transfer_semaphore = try self.dev.createSemaphore(&timeline_sem_info, null);
    errdefer self.dev.destroySemaphore(self.transfer_semaphore, null);

    self.graphics_timeline_semaphore = try self.dev.createSemaphore(&timeline_sem_info, null);

    return self;
}

pub fn deinit(self: *VulkanContext, io: std.Io) void {
    self.queue_mutex.lockUncancelable(io);
    defer self.queue_mutex.unlock(io);

    self.destroySwapchainResources();

    if (self.swapchain != .null_handle) {
        self.dev.destroySwapchainKHR(self.swapchain, null);
        self.swapchain = .null_handle;
    }

    self.dev.destroyCommandPool(self.command_pool, null);
    if (self.upload_command_pool != .null_handle) self.dev.destroyCommandPool(self.upload_command_pool, null);

    self.dev.destroySemaphore(self.transfer_semaphore, null);
    self.dev.destroySemaphore(self.graphics_timeline_semaphore, null);

    if (self.surface != .null_handle) self.instance.destroySurfaceKHR(self.surface, null);
    self.dev.destroyDevice(null);

    if (self.instance_wrapper) |wrapper| {
        if (self.debug_callback != .null_handle) {
            self.instance.destroyDebugUtilsMessengerEXT(self.debug_callback, null);
            self.debug_callback = .null_handle;
        }
        self.instance.destroyInstance(null);
        self.allocator.destroy(wrapper);
    }
    if (self.dev_wrapper) |wrapper| {
        self.allocator.destroy(wrapper);
    }

    self.allocator.destroy(self);
}

fn destroySwapchainSyncResources(self: *VulkanContext) void {
    for (self.image_acquired_semaphores) |sem| if (sem != .null_handle) self.dev.destroySemaphore(sem, null);
    for (self.render_complete_semaphores) |sem| if (sem != .null_handle) self.dev.destroySemaphore(sem, null);
    for (self.in_flight_fences) |fence| if (fence != .null_handle) self.dev.destroyFence(fence, null);
    self.allocator.free(self.image_acquired_semaphores);
    self.allocator.free(self.render_complete_semaphores);
    self.allocator.free(self.in_flight_fences);
    self.image_acquired_semaphores = &.{};
    self.render_complete_semaphores = &.{};
    self.in_flight_fences = &.{};
}

fn allocateSwapchainSyncResources(self: *VulkanContext, num_images: u32) !void {
    self.image_acquired_semaphores = try self.allocator.alloc(vk.Semaphore, num_images);
    @memset(self.image_acquired_semaphores, .null_handle);
    self.render_complete_semaphores = try self.allocator.alloc(vk.Semaphore, num_images);
    @memset(self.render_complete_semaphores, .null_handle);
    self.in_flight_fences = try self.allocator.alloc(vk.Fence, num_images);
    @memset(self.in_flight_fences, .null_handle);
    errdefer self.destroySwapchainSyncResources();

    const semaphore_create_info: vk.SemaphoreCreateInfo = .{ .flags = .{} };
    const fence_create_info: vk.FenceCreateInfo = .{ .flags = .{ .signaled_bit = true } };
    for (self.image_acquired_semaphores, self.render_complete_semaphores, self.in_flight_fences) |*acq, *complete, *fence| {
        acq.* = try self.dev.createSemaphore(&semaphore_create_info, null);
        complete.* = try self.dev.createSemaphore(&semaphore_create_info, null);
        fence.* = try self.dev.createFence(&fence_create_info, null);
    }
}

fn destroySwapchainResources(self: *VulkanContext) void {
    self.dev.deviceWaitIdle() catch {};

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

    self.destroySwapchainSyncResources();
}

pub fn createSwapchainLocked(self: *VulkanContext, io: std.Io, gamma_correction: bool) !void {
    _ = io;
    if (self.swapchain_extent.width == 0 or self.swapchain_extent.height == 0) {
        return error.InvalidWindowSize;
    }

    std.log.info("VulkanContext.createSwapchain: Starting swapchain creation...", .{});

    const caps = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.pdev, self.surface);

    const old_swapchain = self.swapchain;

    if (old_swapchain != .null_handle or self.swapchain_images.len > 0) {
        self.destroySwapchainResources();
    }

    const actual_extent = if (caps.current_extent.width != 0xFFFF_FFFF) caps.current_extent else vk.Extent2D{
        .width = std.math.clamp(self.swapchain_extent.width, caps.min_image_extent.width, @min(caps.max_image_extent.width, 3840)),
        .height = std.math.clamp(self.swapchain_extent.height, caps.min_image_extent.height, @min(caps.max_image_extent.height, 2160)),
    };

    self.swapchain_extent = actual_extent;

    const surface_formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.pdev, self.surface, self.allocator);
    defer self.allocator.free(surface_formats);

    const target_formats: []const vk.Format = if (gamma_correction)
        &.{ .b8g8r8a8_srgb, .r8g8b8a8_srgb }
    else
        &.{ .b8g8r8a8_unorm, .r8g8b8a8_unorm };

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

    const requested_mode: vk.PresentModeKHR = switch (self.present_mode) {
        .vsync => .fifo_khr,
        .mailbox => .mailbox_khr,
        .immediate => .immediate_khr,
    };
    var present_mode: vk.PresentModeKHR = .fifo_khr;
    for (present_modes) |pm| {
        if (pm == requested_mode) {
            present_mode = pm;
            break;
        }
    }
    if (present_mode != requested_mode) {
        std.log.warn("Present mode '{s}' not available, using fallback '{s}' instead", .{
            @tagName(requested_mode),
            @tagName(present_mode),
        });
    }

    const min_for_mode: u32 = switch (present_mode) {
        .mailbox_khr => @max(caps.min_image_count, 3),
        .immediate_khr => @max(caps.min_image_count, 2),
        else => caps.min_image_count,
    };
    const raw_count = @max(min_for_mode + 1, @as(u32, 2));
    const image_count = if (caps.max_image_count > 0) @min(raw_count, caps.max_image_count) else raw_count;

    std.log.info("Swapchain: present_mode={s}, requested={s}, images={d} (min={d}, max={d})", .{
        @tagName(present_mode),
        @tagName(requested_mode),
        image_count,
        caps.min_image_count,
        caps.max_image_count,
    });

    errdefer {
        if (old_swapchain != .null_handle) {
            self.dev.destroySwapchainKHR(old_swapchain, null);
            self.swapchain = .null_handle;
        }
    }

    self.swapchain = try self.dev.createSwapchainKHR(&.{
        .surface = self.surface,
        .min_image_count = image_count,
        .image_format = self.swapchain_format,
        .image_color_space = surface_format.color_space,
        .image_extent = actual_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = null,
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
        self.swapchain_views[i] = try self.dev.createImageView(&.{
            .flags = .{},
            .image = image,
            .view_type = .@"2d",
            .format = self.swapchain_format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        }, null);
    }

    try self.allocateSwapchainSyncResources(@intCast(self.swapchain_images.len));

    const num_swapchain_images = self.swapchain_images.len;
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
}

pub fn currentFrame(self: *VulkanContext) u32 {
    return self.current_frame_idx.load(.monotonic);
}

pub const FrameContext = struct {
    frame_index: u32,
    image_index: u32,
    cmd_buffer: vk.CommandBuffer,
};

pub fn beginFrame(self: *VulkanContext) !FrameContext {
    const timeout: u64 = 2 * std.time.ns_per_s;
    const current_frame = self.currentFrame() % @as(u32, @intCast(self.in_flight_fences.len));
    {
        const wait_result = try self.dev.waitForFences((&self.in_flight_fences[current_frame])[0..1], .true, timeout);
        if (wait_result != .success) return error.DrawFailed;
    }
    try self.dev.resetFences((&self.in_flight_fences[current_frame])[0..1]);
    const acquire = try self.acquireSwapchainImage(current_frame);
    self.current_swapchain_image_index = acquire.image_index;
    return .{
        .frame_index = acquire.frame,
        .image_index = acquire.image_index,
        .cmd_buffer = self.cmd_buffers[acquire.frame],
    };
}

pub fn acquireSwapchainImage(self: *VulkanContext, current_frame_idx: u32) !struct { image_index: u32, frame: u32 } {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "acquireSwapchainImage" });
    defer zone.end();

    const acquire_result = blk: {
        const zone_acquire = tracy.Zone.begin(.{ .src = @src(), .name = "acquireNextImage" });
        defer zone_acquire.end();
        break :blk try self.dev.acquireNextImageKHR(
            self.swapchain,
            std.math.maxInt(u64),
            self.image_acquired_semaphores[current_frame_idx],
            .null_handle,
        );
    };

    if (acquire_result.result == .error_out_of_date_khr or acquire_result.result == .suboptimal_khr) {
        return error.OutOfDate;
    }
    return .{ .image_index = acquire_result.image_index, .frame = current_frame_idx };
}

pub fn submitFrame(self: *VulkanContext, io: std.Io, current_frame_idx: u32, cmd_buffer: vk.CommandBuffer) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "submitFrame" });
    defer zone.end();

    const current_transfer_val = self.transfer_semaphore_value.load(.monotonic);

    const wait_semaphore_infos: [2]vk.SemaphoreSubmitInfo = .{
        .{ .semaphore = self.image_acquired_semaphores[current_frame_idx], .value = 0, .stage_mask = .{ .color_attachment_output_bit = true }, .device_index = 0 },
        .{ .semaphore = self.transfer_semaphore, .value = current_transfer_val, .stage_mask = .{ .compute_shader_bit = true }, .device_index = 0 },
    };

    const signal_semaphore_infos: [2]vk.SemaphoreSubmitInfo = .{
        .{ .semaphore = self.render_complete_semaphores[current_frame_idx], .value = 0, .stage_mask = .{ .color_attachment_output_bit = true }, .device_index = 0 },
        .{ .semaphore = self.graphics_timeline_semaphore, .value = self.frame_number.load(.monotonic), .stage_mask = .{ .all_commands_bit = true }, .device_index = 0 },
    };

    const cmd_buffer_info: vk.CommandBufferSubmitInfo = .{ .command_buffer = cmd_buffer, .device_mask = 0 };

    const submit_info: vk.SubmitInfo2 = .{
        .flags = .{},
        .wait_semaphore_info_count = wait_semaphore_infos.len,
        .p_wait_semaphore_infos = &wait_semaphore_infos,
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = (&cmd_buffer_info)[0..1],
        .signal_semaphore_info_count = signal_semaphore_infos.len,
        .p_signal_semaphore_infos = &signal_semaphore_infos,
    };

    {
        const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "submitFrame_lock_queue" });
        self.queue_mutex.lockUncancelable(io);
        zone_lock.end();
        defer self.queue_mutex.unlock(io);

        const zone_submit = tracy.Zone.begin(.{ .src = @src(), .name = "queueSubmit2" });
        defer zone_submit.end();
        try self.dev.queueSubmit2(self.graphics_queue, (&submit_info)[0..1], self.in_flight_fences[current_frame_idx]);
    }
}

pub fn present(self: *VulkanContext, io: std.Io, current_frame_idx: u32, image_index: u32) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "present" });
    defer zone.end();

    const present_info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = (&self.render_complete_semaphores[current_frame_idx])[0..1],
        .swapchain_count = 1,
        .p_swapchains = (&self.swapchain)[0..1],
        .p_image_indices = &.{image_index},
        .p_results = null,
    };
    const present_result = blk: {
        const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "present_lock_queue" });
        self.queue_mutex.lockUncancelable(io);
        zone_lock.end();
        defer self.queue_mutex.unlock(io);

        const zone_present = tracy.Zone.begin(.{ .src = @src(), .name = "queuePresent" });
        defer zone_present.end();
        break :blk try self.dev.queuePresentKHR(self.present_queue, &present_info);
    };
    if (present_result == .success) {
        const next_frame = (current_frame_idx + 1) % @as(u32, @intCast(self.in_flight_fences.len));
        self.current_frame_idx.store(next_frame, .monotonic);
    } else if (present_result == .suboptimal_khr) {
        const next_frame = (current_frame_idx + 1) % @as(u32, @intCast(self.in_flight_fences.len));
        self.current_frame_idx.store(next_frame, .monotonic);
        self.swapchain_needs_recreate.store(true, .monotonic);
    }
}

const vklog = std.log.scoped(.vulkan);

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = p_user_data;
    _ = message_types;
    if (message_severity.error_bit_ext) {
        vklog.err("{s}", .{(p_callback_data orelse return .false).p_message orelse return .false});
    } else if (message_severity.warning_bit_ext) {
        vklog.warn("{s}", .{(p_callback_data orelse return .false).p_message orelse return .false});
    } else if (message_severity.info_bit_ext) {
        vklog.info("{s}", .{(p_callback_data orelse return .false).p_message orelse return .false});
    } else if (message_severity.verbose_bit_ext) {
        vklog.debug("{s}", .{(p_callback_data orelse return .false).p_message orelse return .false});
    }
    return .false;
}
