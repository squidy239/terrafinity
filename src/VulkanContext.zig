const std = @import("std");

const builtin = @import("builtin");

const options = @import("options");
const tracy = @import("tracy");
const vk = @import("vulkan");
const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;
const InstanceProxy = vk.InstanceProxy;
const DeviceProxy = vk.DeviceProxy;
const wio = @import("wio");

pub const PresentMode = enum {
    vsync,
    mailbox,
    immediate,
};

pub const VulkanContext = @This();

pub const max_frames_in_flight: u32 = 2;

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
sampler_anisotropy: bool = false,

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
current_frame_idx: std.atomic.Value(u32) = .init(0),

swapchain: vk.SwapchainKHR = .null_handle,
swapchain_format: vk.Format = .b8g8r8a8_srgb,
swapchain_gamma: std.atomic.Value(bool) = .init(false),
swapchain_extent_actual: vk.Extent2D = .{ .width = 0, .height = 0 },
swapchain_images: []vk.Image = &.{},
swapchain_views: []vk.ImageView = &.{},
swapchain_image_layouts: []vk.ImageLayout = &.{},
swapchain_extent: vk.Extent2D = .{ .width = 800, .height = 600 },
swapchain_needs_recreate: std.atomic.Value(bool) = .init(false),
present_mode: PresentMode = .mailbox,
last_present_mode_requested: PresentMode = .mailbox,
swapchain_present_mode: vk.PresentModeKHR = .fifo_khr,

transfer_queue: vk.Queue = undefined,
transfer_queue_family_index: u32 = undefined,
ui_command_pool: vk.CommandPool = .null_handle,
transfer_semaphore: vk.Semaphore = .null_handle,
transfer_semaphore_value: std.atomic.Value(u64) = .init(0),
graphics_timeline_semaphore: vk.Semaphore = .null_handle,
frame_number: std.atomic.Value(u64) = .init(0),
queue_mutex: std.Io.Mutex = .init,

fn getProcAddr(instance: vk.Instance, procname: [*:0]const u8) ?*const fn () void {
    return @ptrCast(wio.vkGetInstanceProcAddr(@intFromEnum(instance), procname));
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
        var robustness2_features: vk.PhysicalDeviceRobustness2FeaturesEXT = .{ .p_next = null };
        var dynamic_rendering_features: vk.PhysicalDeviceDynamicRenderingFeatures = .{ .dynamic_rendering = .false, .p_next = @ptrCast(&robustness2_features) };
        var sync2_features: vk.PhysicalDeviceSynchronization2Features = .{ .synchronization_2 = .false, .p_next = @ptrCast(&dynamic_rendering_features) };
        var features13: vk.PhysicalDeviceVulkan13Features = .{ .p_next = @ptrCast(&sync2_features) };
        var features12: vk.PhysicalDeviceVulkan12Features = .{
            .draw_indirect_count = .false,
            .descriptor_indexing = .false,
            .shader_sampled_image_array_non_uniform_indexing = .false,
            .descriptor_binding_sampled_image_update_after_bind = .false,
            .runtime_descriptor_array = .false,
            .descriptor_binding_partially_bound = .false,
            .buffer_device_address = .false,
            .buffer_device_address_capture_replay = .false,
            .timeline_semaphore = .false,
            .p_next = @ptrCast(&features13),
        };
        var features2: vk.PhysicalDeviceFeatures2 = .{ .features = .{ .multi_draw_indirect = .false }, .p_next = @ptrCast(&features12) };
        self.instance.getPhysicalDeviceFeatures2(pdev, &features2);

        const anisotropy_supported = features2.features.sampler_anisotropy == .true;
        const required = features2.features.multi_draw_indirect == .true and
            features2.features.shader_int_64 == .true and features2.features.independent_blend == .true and
            features12.draw_indirect_count == .true and features12.descriptor_indexing == .true and
            features12.shader_sampled_image_array_non_uniform_indexing == .true and
            features12.descriptor_binding_sampled_image_update_after_bind == .true and
            features12.runtime_descriptor_array == .true and features12.descriptor_binding_partially_bound == .true and
            features12.buffer_device_address == .true and
            features12.timeline_semaphore == .true and
            features13.synchronization_2 == .true and features13.dynamic_rendering == .true and
            robustness2_features.null_descriptor == .true;
        if (!required) continue;

        var has_graphics = false;
        var has_present = false;
        const queue_families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
        defer allocator.free(queue_families);
        for (queue_families, 0..) |qf, family| {
            if (!has_graphics and qf.queue_flags.graphics_bit) has_graphics = true;
            if (!has_present and (try self.instance.getPhysicalDeviceSurfaceSupportKHR(pdev, @intCast(family), self.surface)) == .true) has_present = true;
            if (has_graphics and has_present) break;
        }
        if (!has_graphics or !has_present) continue;

        const surface_formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(pdev, self.surface, allocator);
        defer allocator.free(surface_formats);
        const present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(pdev, self.surface, allocator);
        defer allocator.free(present_modes);
        if (surface_formats.len == 0 or present_modes.len == 0) continue;

        const props = self.instance.getPhysicalDeviceProperties(pdev);
        var score: u32 = if (props.device_type == .discrete_gpu) 10 else if (props.device_type == .integrated_gpu) 5 else 1;
        // NVIDIA's Vulkan driver produces false-positive thread sanitizer errors,
        // making TSAN builds unusable with NVIDIA hardware. Demote to lowest priority
        // so the integrated GPU (or another vendor's discrete GPU) is preferred instead.
        if (options.sanitize_thread) {
            const device_name = std.mem.sliceTo(&props.device_name, 0);
            if (std.mem.indexOf(u8, device_name, "NVIDIA") != null or std.mem.indexOf(u8, device_name, "nvidia") != null) score = 1;
        }
        if (score > best_score) {
            best_score = score;
            selected_pdev = pdev;
            self.sampler_anisotropy = anisotropy_supported;
        }
    }
    if (selected_pdev == .null_handle) return error.NoSuitablePhysicalDevice;
    return selected_pdev;
}

fn selectQueueFamilies(self: *VulkanContext, allocator: std.mem.Allocator) !struct { graphics: u32, present: u32, transfer: u32 } {
    const queue_families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(self.pdev, allocator);
    defer allocator.free(queue_families);
    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;
    var transfer_family: ?u32 = null;
    var transfer_score: u8 = 0;
    for (queue_families, 0..) |qf, family| {
        const family_idx: u32 = @intCast(family);
        if (graphics_family == null and qf.queue_flags.graphics_bit) graphics_family = family_idx;
        if (present_family == null and (try self.instance.getPhysicalDeviceSurfaceSupportKHR(self.pdev, family_idx, self.surface)) == .true) present_family = family_idx;
        if (qf.queue_flags.transfer_bit) {
            const score: u8 = if (!qf.queue_flags.graphics_bit and !qf.queue_flags.compute_bit) 3 else if (!qf.queue_flags.graphics_bit) 2 else 1;
            if (score > transfer_score) {
                transfer_family = family_idx;
                transfer_score = score;
            }
        }
    }
    const final_graphics = graphics_family orelse return error.NoGraphicsQueue;
    var final_present = present_family orelse return error.NoPresentQueue;
    if (final_present != final_graphics and
        (try self.instance.getPhysicalDeviceSurfaceSupportKHR(self.pdev, final_graphics, self.surface)) == .true)
    {
        final_present = final_graphics;
    }
    return .{ .graphics = final_graphics, .present = final_present, .transfer = transfer_family orelse final_graphics };
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
        .instance_wrapper = null,
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

    var extension_names: std.ArrayListUnmanaged([*:0]const u8) = .empty;
    defer extension_names.deinit(allocator);

    const wio_extensions = wio.getRequiredVulkanInstanceExtensions();
    try extension_names.appendSlice(allocator, wio_extensions);

    var has_portability = false;
    var has_debug_utils = false;
    const extensions = try self.vkb.enumerateInstanceExtensionPropertiesAlloc(null, allocator);
    defer allocator.free(extensions);
    for (extensions) |extension| {
        const name = std.mem.sliceTo(&extension.extension_name, 0);
        if (std.mem.eql(u8, name, "VK_KHR_portability_enumeration")) {
            try extension_names.append(allocator, "VK_KHR_portability_enumeration");
            has_portability = true;
        } else if (std.mem.eql(u8, name, "VK_EXT_debug_utils")) {
            try extension_names.append(allocator, "VK_EXT_debug_utils");
            has_debug_utils = true;
        }
    }

    var layer_names: std.ArrayListUnmanaged([*:0]const u8) = .empty;
    defer layer_names.deinit(allocator);

    if (builtin.mode == .Debug) {
        const layers = try self.vkb.enumerateInstanceLayerPropertiesAlloc(allocator);
        defer allocator.free(layers);
        for (layers) |layer| {
            const name = std.mem.sliceTo(&layer.layer_name, 0);
            if (std.mem.eql(u8, name, "VK_LAYER_KHRONOS_validation")) {
                try layer_names.append(allocator, "VK_LAYER_KHRONOS_validation");
                std.log.info("Enabling Vulkan validation layer", .{});
                break;
            }
        }
    }

    const instance_create_info: vk.InstanceCreateInfo = .{
        .flags = .{ .enumerate_portability_bit_khr = has_portability },
        .p_application_info = &app_info,
        .enabled_layer_count = @intCast(layer_names.items.len),
        .pp_enabled_layer_names = @ptrCast(layer_names.items.ptr),
        .enabled_extension_count = @intCast(extension_names.items.len),
        .pp_enabled_extension_names = @ptrCast(extension_names.items.ptr),
    };

    self.instance_handle = try self.vkb.createInstance(&instance_create_info, null);
    errdefer if (self.instance_wrapper == null) {
        var local_wrapper = InstanceWrapper.load(self.instance_handle, getProcAddr);
        const local_instance = InstanceProxy.init(self.instance_handle, &local_wrapper);
        local_instance.destroyInstance(null);
    };

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

    var device_extensions: []const [*:0]const u8 = &.{};
    if (has_push_desc) {
        device_extensions = &.{
            vk.extensions.khr_swapchain.name,
            vk.extensions.ext_robustness_2.name,
            vk.extensions.khr_push_descriptor.name,
        };
    } else {
        std.log.warn("VK_KHR_push_descriptor not supported, device creation will likely fail", .{});
        device_extensions = &.{
            vk.extensions.khr_swapchain.name,
            vk.extensions.ext_robustness_2.name,
        };
    }

    const queue_priority: f32 = 1.0;
    var queue_create_infos: [3]vk.DeviceQueueCreateInfo = undefined;
    var queue_count: u32 = 0;
    const families: [3]u32 = .{ qfamilies.graphics, qfamilies.present, qfamilies.transfer };
    for (families) |f| {
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
        .null_descriptor = .true,
    };
    var features13: vk.PhysicalDeviceVulkan13Features = .{
        .synchronization_2 = .true,
        .dynamic_rendering = .true,
        .p_next = @ptrCast(&robustness2_features),
    };
    var features12: vk.PhysicalDeviceVulkan12Features = .{
        .draw_indirect_count = .true,
        .descriptor_indexing = .true,
        .shader_sampled_image_array_non_uniform_indexing = .true,
        .descriptor_binding_sampled_image_update_after_bind = .true,
        .runtime_descriptor_array = .true,
        .descriptor_binding_partially_bound = .true,
        .buffer_device_address_capture_replay = .false,
        .buffer_device_address = .true,
        .timeline_semaphore = .true,
        .p_next = @ptrCast(&features13),
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
            .sampler_anisotropy = if (self.sampler_anisotropy) .true else .false,
        },
        .p_next = @ptrCast(&features11),
    };

    const device_info: vk.DeviceCreateInfo = .{
        .queue_create_info_count = @intCast(queue_count),
        .p_queue_create_infos = queue_create_infos[0..queue_count].ptr,
        .enabled_extension_count = @intCast(device_extensions.len),
        .pp_enabled_extension_names = device_extensions[0..device_extensions.len].ptr,
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
    self.present_queue = self.dev.getDeviceQueue(qfamilies.present, 0);
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

    self.ui_command_pool = try self.dev.createCommandPool(&pool_info, null);
    errdefer self.dev.destroyCommandPool(self.ui_command_pool, null);

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
    errdefer self.dev.destroySemaphore(self.graphics_timeline_semaphore, null);

    self.image_acquired_semaphores = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    @memset(self.image_acquired_semaphores, .null_handle);
    errdefer {
        for (self.image_acquired_semaphores) |sem| if (sem != .null_handle) self.dev.destroySemaphore(sem, null);
        allocator.free(self.image_acquired_semaphores);
    }

    self.render_complete_semaphores = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    @memset(self.render_complete_semaphores, .null_handle);
    errdefer {
        for (self.render_complete_semaphores) |sem| if (sem != .null_handle) self.dev.destroySemaphore(sem, null);
        allocator.free(self.render_complete_semaphores);
    }

    const semaphore_create_info: vk.SemaphoreCreateInfo = .{ .flags = .{} };
    for (self.image_acquired_semaphores, self.render_complete_semaphores) |*acq, *complete| {
        acq.* = try self.dev.createSemaphore(&semaphore_create_info, null);
        complete.* = try self.dev.createSemaphore(&semaphore_create_info, null);
    }

    const cmd_alloc_info: vk.CommandBufferAllocateInfo = .{
        .command_pool = self.command_pool,
        .level = .primary,
        .command_buffer_count = max_frames_in_flight,
    };

    self.cmd_buffers = try allocator.alloc(vk.CommandBuffer, max_frames_in_flight);
    errdefer {
        allocator.free(self.cmd_buffers);
        self.cmd_buffers = &.{};
    }
    try self.dev.allocateCommandBuffers(&cmd_alloc_info, self.cmd_buffers.ptr);

    return self;
}

pub fn deinit(self: *VulkanContext, io: std.Io) void {
    self.queue_mutex.lockUncancelable(io);

    self.dev.deviceWaitIdle() catch |err| {
        std.log.err("deviceWaitIdle failed during VulkanContext.deinit: {}", .{err});
    };

    self.dev.resetCommandPool(self.command_pool, .{}) catch {};
    if (self.ui_command_pool != .null_handle) self.dev.resetCommandPool(self.ui_command_pool, .{}) catch {};

    self.destroySwapchainResources();

    if (self.swapchain != .null_handle) {
        self.dev.destroySwapchainKHR(self.swapchain, null);
        self.swapchain = .null_handle;
    }

    if (self.cmd_buffers.len > 0) {
        self.dev.freeCommandBuffers(self.command_pool, self.cmd_buffers);
        self.allocator.free(self.cmd_buffers);
        self.cmd_buffers = &.{};
    }

    for (self.image_acquired_semaphores) |sem| if (sem != .null_handle) self.dev.destroySemaphore(sem, null);
    self.allocator.free(self.image_acquired_semaphores);
    self.image_acquired_semaphores = &.{};

    for (self.render_complete_semaphores) |sem| if (sem != .null_handle) self.dev.destroySemaphore(sem, null);
    self.allocator.free(self.render_complete_semaphores);
    self.render_complete_semaphores = &.{};

    self.dev.destroyCommandPool(self.command_pool, null);
    if (self.upload_command_pool != .null_handle) self.dev.destroyCommandPool(self.upload_command_pool, null);
    if (self.ui_command_pool != .null_handle) self.dev.destroyCommandPool(self.ui_command_pool, null);

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

    self.queue_mutex.unlock(io);
    self.allocator.destroy(self);
}

fn destroySwapchainResources(self: *VulkanContext) void {
    for (self.swapchain_views) |view| if (view != .null_handle) self.dev.destroyImageView(view, null);
    self.allocator.free(self.swapchain_images);
    self.allocator.free(self.swapchain_views);
    self.allocator.free(self.swapchain_image_layouts);
    self.swapchain_images = &.{};
    self.swapchain_views = &.{};
    self.swapchain_image_layouts = &.{};
}

pub fn createSwapchainLocked(self: *VulkanContext, gamma_correction: bool) !void {
    if (self.swapchain_extent.width == 0 or self.swapchain_extent.height == 0) {
        return error.InvalidWindowSize;
    }

    if (self.swapchain != .null_handle) {
        const current_gamma = self.swapchain_gamma.load(.monotonic);
        const extent_same = self.swapchain_extent_actual.width == self.swapchain_extent.width and
            self.swapchain_extent_actual.height == self.swapchain_extent.height;
        if (current_gamma == gamma_correction and extent_same and self.present_mode == self.last_present_mode_requested) return;
    }

    self.swapchain_extent_actual = self.swapchain_extent;
    self.swapchain_gamma.store(gamma_correction, .monotonic);

    std.log.info("VulkanContext.createSwapchain: Starting swapchain creation...", .{});

    const caps = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.pdev, self.surface);

    const old_swapchain = self.swapchain;
    const old_views = self.swapchain_views;
    const old_images = self.swapchain_images;
    const old_image_layouts = self.swapchain_image_layouts;

    const actual_extent = if (caps.current_extent.width != 0xFFFFFFFF)
        caps.current_extent
    else
        vk.Extent2D{
            .width = std.math.clamp(self.swapchain_extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(self.swapchain_extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
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
    const raw_count = min_for_mode + 1;
    const image_count = if (caps.max_image_count > 0) @min(raw_count, caps.max_image_count) else raw_count;

    std.log.info("Swapchain: present_mode={s}, requested={s}, images={d} (min={d}, max={d})", .{
        @tagName(present_mode),
        @tagName(requested_mode),
        image_count,
        caps.min_image_count,
        caps.max_image_count,
    });

    const queue_family_indices: [2]u32 = .{ self.queue_family_index, self.present_queue_family_index };
    const new_swapchain = try self.dev.createSwapchainKHR(&.{
        .surface = self.surface,
        .min_image_count = image_count,
        .image_format = self.swapchain_format,
        .image_color_space = surface_format.color_space,
        .image_extent = actual_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = if (self.queue_family_index == self.present_queue_family_index) .exclusive else .concurrent,
        .queue_family_index_count = if (self.queue_family_index == self.present_queue_family_index) 0 else 2,
        .p_queue_family_indices = if (self.queue_family_index == self.present_queue_family_index) null else queue_family_indices[0..queue_family_indices.len],
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = .true,
        .old_swapchain = old_swapchain,
    }, null);

    errdefer self.dev.destroySwapchainKHR(new_swapchain, null);

    const new_images = try self.dev.getSwapchainImagesAllocKHR(new_swapchain, self.allocator);
    errdefer self.allocator.free(new_images);

    const new_views = try self.allocator.alloc(vk.ImageView, new_images.len);
    @memset(new_views, .null_handle);
    errdefer {
        for (new_views) |view| {
            if (view != .null_handle) self.dev.destroyImageView(view, null);
        }
        self.allocator.free(new_views);
    }

    for (new_images, new_views) |image, *view| {
        view.* = try self.dev.createImageView(&.{
            .flags = .{},
            .image = image,
            .view_type = .@"2d",
            .format = self.swapchain_format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        }, null);
    }

    // New resources created successfully, now safely destroy old resources
    for (old_views) |view| {
        if (view != .null_handle) self.dev.destroyImageView(view, null);
    }
    self.allocator.free(old_images);
    self.allocator.free(old_views);
    self.allocator.free(old_image_layouts);

    if (old_swapchain != .null_handle) {
        self.dev.destroySwapchainKHR(old_swapchain, null);
    }

    self.swapchain = new_swapchain;
    self.swapchain_images = new_images;
    self.swapchain_views = new_views;
    self.swapchain_present_mode = present_mode;
    self.last_present_mode_requested = self.present_mode;
    self.swapchain_image_layouts = &.{};
    self.swapchain_image_layouts = try self.allocator.alloc(vk.ImageLayout, new_images.len);
    for (self.swapchain_image_layouts) |*layout| layout.* = .undefined;
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
    const current_frame = self.currentFrame();
    {
        const frame_number = self.frame_number.load(.acquire);
        if (frame_number >= max_frames_in_flight) {
            const wait_value: u64 = frame_number - max_frames_in_flight + 1;
            const wait_info: vk.SemaphoreWaitInfo = .{
                .semaphore_count = 1,
                .p_semaphores = (&self.graphics_timeline_semaphore)[0..1],
                .p_values = (&wait_value)[0..1],
            };
            const wait_result = self.dev.waitSemaphores(&wait_info, std.math.maxInt(u64)) catch return error.DrawFailed;
            if (wait_result != .success) return error.DrawFailed;
        }
    }
    const image_index = try self.acquireSwapchainImage(current_frame);
    return .{
        .frame_index = current_frame,
        .image_index = image_index,
        .cmd_buffer = self.cmd_buffers[current_frame],
    };
}

pub fn acquireSwapchainImage(self: *VulkanContext, current_frame_idx: u32) !u32 {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "acquireSwapchainImage" });
    defer zone.end();

    const acquire_result = blk: {
        const zone_acquire = tracy.Zone.begin(.{ .src = @src(), .name = "acquireNextImage" });
        defer zone_acquire.end();
        break :blk self.dev.acquireNextImageKHR(
            self.swapchain,
            std.math.maxInt(u64),
            self.image_acquired_semaphores[current_frame_idx],
            .null_handle,
        ) catch |err| switch (err) {
            error.OutOfDateKHR, error.SurfaceLostKHR => return error.OutOfDate,
            else => return err,
        };
    };

    return acquire_result.image_index;
}

pub fn submitFrame(self: *VulkanContext, io: std.Io, ctx: FrameContext) !void {
    try self.submitFrameWithExtra(io, ctx, .null_handle, true);
}

pub fn submitFrameWithExtra(self: *VulkanContext, io: std.Io, ctx: FrameContext, extra_cmd_buffer: vk.CommandBuffer, include_game: bool) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "submitFrame" });
    defer zone.end();

    const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "submitFrame_lock_queue" });
    self.queue_mutex.lockUncancelable(io);
    zone_lock.end();
    defer self.queue_mutex.unlock(io);

    const current_transfer_val = self.transfer_semaphore_value.load(.monotonic);
    const current_graphics_val = self.frame_number.fetchAdd(1, .release) + 1;
    const prev_graphics_val = current_graphics_val - 1;

    const wait_semaphore_infos: [3]vk.SemaphoreSubmitInfo = .{
        .{ .semaphore = self.image_acquired_semaphores[ctx.frame_index], .value = 0, .stage_mask = .{ .color_attachment_output_bit = true }, .device_index = 0 },
        .{ .semaphore = self.transfer_semaphore, .value = current_transfer_val, .stage_mask = .{ .top_of_pipe_bit = true }, .device_index = 0 },
        .{ .semaphore = self.graphics_timeline_semaphore, .value = prev_graphics_val, .stage_mask = .{ .top_of_pipe_bit = true }, .device_index = 0 },
    };

    const signal_semaphore_infos: [2]vk.SemaphoreSubmitInfo = .{
        .{ .semaphore = self.render_complete_semaphores[ctx.frame_index], .value = 0, .stage_mask = .{ .bottom_of_pipe_bit = true }, .device_index = 0 },
        .{ .semaphore = self.graphics_timeline_semaphore, .value = current_graphics_val, .stage_mask = .{ .all_commands_bit = true }, .device_index = 0 },
    };

    var cmd_buffer_infos: [2]vk.CommandBufferSubmitInfo = undefined;
    var cmd_buffer_count: u32 = 0;
    if (include_game) {
        cmd_buffer_infos[0] = .{ .command_buffer = ctx.cmd_buffer, .device_mask = 0 };
        cmd_buffer_count += 1;
    }
    if (extra_cmd_buffer != .null_handle) {
        cmd_buffer_infos[cmd_buffer_count] = .{ .command_buffer = extra_cmd_buffer, .device_mask = 0 };
        cmd_buffer_count += 1;
    }

    const submit_info: vk.SubmitInfo2 = .{
        .flags = .{},
        .wait_semaphore_info_count = wait_semaphore_infos.len,
        .p_wait_semaphore_infos = wait_semaphore_infos[0..wait_semaphore_infos.len],
        .command_buffer_info_count = cmd_buffer_count,
        .p_command_buffer_infos = cmd_buffer_infos[0..cmd_buffer_count].ptr,
        .signal_semaphore_info_count = signal_semaphore_infos.len,
        .p_signal_semaphore_infos = signal_semaphore_infos[0..signal_semaphore_infos.len],
    };

    const zone_submit = tracy.Zone.begin(.{ .src = @src(), .name = "queueSubmit2" });
    defer zone_submit.end();
    try self.dev.queueSubmit2(self.graphics_queue, (&submit_info)[0..1], .null_handle);
}

pub fn present(self: *VulkanContext, io: std.Io, ctx: FrameContext) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "present" });
    defer zone.end();

    const present_info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = (&self.render_complete_semaphores[ctx.frame_index])[0..1],
        .swapchain_count = 1,
        .p_swapchains = (&self.swapchain)[0..1],
        .p_image_indices = (&ctx.image_index)[0..1],
        .p_results = null,
    };
    const present_result = blk: {
        const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "present_lock_queue" });
        self.queue_mutex.lockUncancelable(io);
        zone_lock.end();
        defer self.queue_mutex.unlock(io);

        const zone_present = tracy.Zone.begin(.{ .src = @src(), .name = "queuePresent" });
        defer zone_present.end();
        break :blk self.dev.queuePresentKHR(self.present_queue, &present_info) catch |err| switch (err) {
            error.OutOfDateKHR, error.SurfaceLostKHR => {
                const next_frame = (ctx.frame_index + 1) % max_frames_in_flight;
                self.current_frame_idx.store(next_frame, .monotonic);
                return error.OutOfDate;
            },
            else => return err,
        };
    };
    if (present_result == .success or present_result == .suboptimal_khr) {
        const next_frame = (ctx.frame_index + 1) % max_frames_in_flight;
        self.current_frame_idx.store(next_frame, .monotonic);
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
    const cb_data = p_callback_data orelse return .false;
    const msg = std.mem.span(cb_data.p_message orelse return .false);
    switch (cb_data.message_id_number) {
        else => {},
    }

    if (message_severity.error_bit_ext) {
        vklog.err("Id: {d}, {s}", .{ cb_data.message_id_number, msg });
    } else if (message_severity.warning_bit_ext) {
        vklog.warn("Id: {d}, {s}", .{ cb_data.message_id_number, msg });
    } else if (message_severity.info_bit_ext) {
        vklog.info("Id: {d}, {s}", .{ cb_data.message_id_number, msg });
    } else if (message_severity.verbose_bit_ext) {
        vklog.debug("Id: {d}, {s}", .{ cb_data.message_id_number, msg });
    }
    return .false;
}

test "VulkanContext init and deinit" {
    try wio.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .eventFn = wio.EventQueue.eventFn });
    defer wio.deinit();

    var events: wio.EventQueue = .empty;
    defer events.deinit();

    var window = try wio.Window.create(.{ .title = "test", .event_fn_data = &events });
    defer window.destroy();

    const ctx = try VulkanContext.init(std.testing.allocator, &window);
    defer ctx.deinit(std.testing.io);

    try std.testing.expect(ctx.instance_handle != .null_handle);
    try std.testing.expect(ctx.dev_handle != .null_handle);
    try std.testing.expect(ctx.graphics_queue != .null_handle);
    try std.testing.expect(ctx.present_queue != .null_handle);
    try std.testing.expect(ctx.command_pool != .null_handle);
    try std.testing.expect(ctx.upload_command_pool != .null_handle);
    try std.testing.expect(ctx.ui_command_pool != .null_handle);
    try std.testing.expect(ctx.transfer_semaphore != .null_handle);
    try std.testing.expect(ctx.graphics_timeline_semaphore != .null_handle);
    try std.testing.expect(ctx.surface != .null_handle);
    try std.testing.expect(ctx.cmd_buffers.len > 0);
    try std.testing.expect(ctx.image_acquired_semaphores.len > 0);
    try std.testing.expect(ctx.render_complete_semaphores.len > 0);
}

test "VulkanRenderer init and deinit" {
    const VulkanRenderer = @import("Renderer/vulkan/VulkanRenderer.zig").VulkanRenderer;
    const Renderer = @import("Renderer.zig");

    try wio.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .eventFn = wio.EventQueue.eventFn });
    defer wio.deinit();

    var events: wio.EventQueue = .empty;
    defer events.deinit();

    var window = try wio.Window.create(.{ .title = "test", .event_fn_data = &events });
    defer window.destroy();

    const ctx = try VulkanContext.init(std.testing.allocator, &window);
    defer ctx.deinit(std.testing.io);

    ctx.swapchain_extent = .{ .width = 640, .height = 480 };
    ctx.queue_mutex.lockUncancelable(std.testing.io);
    try ctx.createSwapchainLocked(false);
    ctx.queue_mutex.unlock(std.testing.io);

    var render_opts: Renderer.RenderOptions = .{};
    var render_opts_lock: std.Io.RwLock = .init;

    var renderer: VulkanRenderer = undefined;
    try renderer.init(std.testing.io, std.testing.allocator, ctx, &render_opts, &render_opts_lock);
    defer renderer.deinit(std.testing.io);
}
