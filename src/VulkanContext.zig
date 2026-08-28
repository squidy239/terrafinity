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

const Renderer = @import("Renderer.zig");
const Mesher = @import("Renderer/Mesher.zig");
const core = @import("Renderer/vulkan/core.zig");
const gpu = @import("Renderer/vulkan/gpu.zig");
const VulkanRenderer = @import("Renderer/vulkan/VulkanRenderer.zig").VulkanRenderer;
const GpuProfiler = @import("Renderer/vulkan/tracy_gpu.zig").GpuProfiler;
const Block = @import("world/Block.zig").Block;
const Chunk = @import("world/Chunk.zig");
const World = @import("world/World.zig");

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
pipeline_creation_feedback: bool = false,
depth_clamp: bool = false,
depth_bias_clamp: bool = false,

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
suboptimal_recreate_requested: std.atomic.Value(bool) = .init(false),

present_mode: PresentMode = .mailbox,
last_present_mode_requested: PresentMode = .mailbox,

transfer_queue: vk.Queue = undefined,
transfer_queue_family_index: u32 = undefined,
ui_command_pool: vk.CommandPool = .null_handle,
transfer_semaphore: vk.Semaphore = .null_handle,
transfer_semaphore_value: std.atomic.Value(u64) = .init(0),
graphics_timeline_semaphore: vk.Semaphore = .null_handle,
gpu_profiler: GpuProfiler = .{},
// Cross-thread frame counter: read with .acquire by submitBatch / drainInFlightFrames and
// advanced with .release by submitFrameWithExtra; the pair orders the two submit paths.
frame_number: std.atomic.Value(u64) = .init(0),
queue_mutex: std.Io.Mutex = .init,
/// Serializes transfer-queue submissions against the face-buffer grow, so a transfer
/// submit does not queue behind graphics submits, present, or scene growth stalls.
transfer_queue_mutex: std.Io.Mutex = .init,

vulkan_host_allocator: VulkanHostAllocator = undefined,
vkalloc: vk.AllocationCallbacks = undefined,

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
        var features11: vk.PhysicalDeviceVulkan11Features = .{
            .shader_draw_parameters = .false,
            .p_next = @ptrCast(&features12),
        };
        var features2: vk.PhysicalDeviceFeatures2 = .{
            .features = .{ .multi_draw_indirect = .false, .draw_indirect_first_instance = .false },
            .p_next = @ptrCast(&features11),
        };
        self.instance.getPhysicalDeviceFeatures2(pdev, &features2);

        const props = self.instance.getPhysicalDeviceProperties(pdev);
        // An instance API of 1.3 does not guarantee every enumerated device exposes device API 1.3.
        if (props.api_version < vk.API_VERSION_1_3.toU32()) continue;

        const anisotropy_supported = features2.features.sampler_anisotropy == .true;
        const required = features2.features.multi_draw_indirect == .true and
            features2.features.draw_indirect_first_instance == .true and
            features2.features.shader_int_64 == .true and features2.features.independent_blend == .true and
            features11.shader_draw_parameters == .true and
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

        const ext_props = try self.instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
        defer allocator.free(ext_props);
        var has_swapchain = false;
        var has_robustness2 = false;
        var has_push_desc = false;
        for (ext_props) |ext| {
            const name = std.mem.sliceTo(&ext.extension_name, 0);
            if (std.mem.eql(u8, name, vk.extensions.khr_swapchain.name)) {
                has_swapchain = true;
            } else if (std.mem.eql(u8, name, vk.extensions.ext_robustness_2.name)) {
                has_robustness2 = true;
            } else if (std.mem.eql(u8, name, vk.extensions.khr_push_descriptor.name)) {
                has_push_desc = true;
            }
        }
        if (!has_swapchain or !has_robustness2 or !has_push_desc) continue;

        const surface_formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(pdev, self.surface, allocator);
        defer allocator.free(surface_formats);
        const present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(pdev, self.surface, allocator);
        defer allocator.free(present_modes);
        if (surface_formats.len == 0 or present_modes.len == 0) continue;

        var score: u32 = if (props.device_type == .discrete_gpu) 10 else if (props.device_type == .integrated_gpu) 5 else 1;
        // NVIDIA's Vulkan driver produces false-positive thread sanitizer errors,
        // making TSAN builds unusable with NVIDIA hardware. Demote to lowest priority
        // so the integrated GPU (or another vendor's discrete GPU) is preferred instead.
        if (options.sanitize_thread) {
            const device_name = std.mem.sliceTo(&props.device_name, 0);
            if (std.mem.indexOf(u8, device_name, "NVIDIA") != null) score = 1;
        }
        if (score > best_score) {
            best_score = score;
            selected_pdev = pdev;
            self.sampler_anisotropy = anisotropy_supported;
            self.depth_clamp = features2.features.depth_clamp == .true;
            self.depth_bias_clamp = features2.features.depth_bias_clamp == .true;
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
        .vulkan_host_allocator = .{ .allocator = allocator },
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

    self.vkalloc = self.vulkan_host_allocator.getCallbacks();
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

    self.instance_handle = try self.vkb.createInstance(&instance_create_info, &self.vkalloc);
    errdefer if (self.instance_wrapper == null) {
        var local_wrapper = InstanceWrapper.load(self.instance_handle, getProcAddr);
        const local_instance = InstanceProxy.init(self.instance_handle, &local_wrapper);
        local_instance.destroyInstance(&self.vkalloc);
    };

    const instance_wrapper_ptr = try allocator.create(InstanceWrapper);

    instance_wrapper_ptr.* = .load(self.instance_handle, getProcAddr);
    self.instance_wrapper = instance_wrapper_ptr;
    self.instance = .init(self.instance_handle, instance_wrapper_ptr);
    errdefer {
        self.instance.destroyInstance(&self.vkalloc);
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
        self.debug_callback = try self.instance.createDebugUtilsMessengerEXT(&callback_create_info, &self.vkalloc);
    }
    errdefer if (self.debug_callback != .null_handle) self.instance.destroyDebugUtilsMessengerEXT(self.debug_callback, &self.vkalloc);

    var surface: vk.SurfaceKHR = .null_handle;
    try window.vkCreateSurface(@intFromEnum(self.instance.handle), &self.vkalloc, @ptrCast(&surface));

    self.surface = surface;
    errdefer self.instance.destroySurfaceKHR(self.surface, &self.vkalloc);

    self.pdev = try self.selectPhysicalDevice(allocator);
    self.props = self.instance.getPhysicalDeviceProperties(self.pdev);
    self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);

    const ext_props = try self.instance.enumerateDeviceExtensionPropertiesAlloc(self.pdev, null, allocator);
    defer allocator.free(ext_props);
    var has_push_desc = false;
    var has_portability_subset = false;
    for (ext_props) |ext| {
        const name = std.mem.sliceTo(&ext.extension_name, 0);
        if (std.mem.eql(u8, name, "VK_KHR_push_descriptor")) {
            has_push_desc = true;
        } else if (std.mem.eql(u8, name, "VK_KHR_portability_subset")) {
            has_portability_subset = true;
        }
        if (std.mem.eql(u8, name, "VK_EXT_pipeline_creation_feedback")) {
            self.pipeline_creation_feedback = true;
        }
    }
    std.log.info("Physical device supports VK_KHR_push_descriptor: {}", .{has_push_desc});
    std.log.info("Physical device supports VK_EXT_pipeline_creation_feedback: {}", .{self.pipeline_creation_feedback});

    const queue_families = try self.selectQueueFamilies(allocator);
    self.queue_family_index = queue_families.graphics;
    self.present_queue_family_index = queue_families.present;
    self.transfer_queue_family_index = queue_families.transfer;

    // khr_swapchain (1) + ext_robustness_2 (1) + push_descriptor (1) + pipeline_creation_feedback (1) + portability_subset (1) = max 5
    const max_device_extensions = 5;
    comptime {
        const min_unconditional: usize = 2;
        if (max_device_extensions < min_unconditional + 3) @compileError("device_extension_buf too small: need at least " ++ std.fmt.comptimePrint("{d}", .{min_unconditional + 3}) ++ ", got " ++ std.fmt.comptimePrint("{d}", .{max_device_extensions}));
    }
    var device_extension_buf: [max_device_extensions][*:0]const u8 = undefined;
    var device_extensions = std.ArrayList([*:0]const u8).initBuffer(&device_extension_buf);

    device_extensions.appendAssumeCapacity(vk.extensions.khr_swapchain.name);
    device_extensions.appendAssumeCapacity(vk.extensions.ext_robustness_2.name);
    // Guaranteed by selectPhysicalDevice, which rejects devices missing push descriptors.
    if (has_push_desc) {
        device_extensions.appendAssumeCapacity(vk.extensions.khr_push_descriptor.name);
    }
    if (self.pipeline_creation_feedback) {
        device_extensions.appendAssumeCapacity(vk.extensions.ext_pipeline_creation_feedback.name);
    }
    // Mandatory to enable when exposed by portability implementations (e.g. MoltenVK).
    if (has_portability_subset) {
        device_extensions.appendAssumeCapacity(vk.extensions.khr_portability_subset.name);
    }

    const queue_priority: f32 = 1.0;
    var queue_create_infos: [3]vk.DeviceQueueCreateInfo = undefined;
    var queue_count: u32 = 0;
    const families: [3]u32 = .{ queue_families.graphics, queue_families.present, queue_families.transfer };
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
            .draw_indirect_first_instance = .true,
            .shader_int_64 = .true,
            .independent_blend = .true,
            .sampler_anisotropy = if (self.sampler_anisotropy) .true else .false,
            .depth_clamp = if (self.depth_clamp) .true else .false,
            .depth_bias_clamp = if (self.depth_bias_clamp) .true else .false,
        },
        .p_next = @ptrCast(&features11),
    };

    const device_info: vk.DeviceCreateInfo = .{
        .queue_create_info_count = @intCast(queue_count),
        .p_queue_create_infos = queue_create_infos[0..queue_count].ptr,
        .enabled_extension_count = @intCast(device_extensions.items.len),
        .pp_enabled_extension_names = device_extensions.items.ptr,
        .p_next = @ptrCast(&features),
    };

    // Fetch vkGetDeviceProcAddr before device creation so the MissingDeviceProcAddr error path
    // cannot leave a live device behind.
    const gdpa = self.instance.wrapper.dispatch.vkGetDeviceProcAddr orelse return error.MissingDeviceProcAddr;

    self.dev_handle = try self.instance.createDevice(self.pdev, &device_info, &self.vkalloc);

    // The raw handle must be destroyed even if the wrapper setup below fails, otherwise it would
    // leak and the instance errdefer would destroy the instance while the device is still alive.
    // vkDestroyDevice is a device-level command, so reach it through a scratch DeviceWrapper.
    var owns_raw_device = true;
    errdefer if (owns_raw_device) {
        var scratch_wrapper = DeviceWrapper.load(self.dev_handle, gdpa);
        scratch_wrapper.destroyDevice(self.dev_handle, &self.vkalloc);
    };

    const dev_wrapper_ptr = try allocator.create(DeviceWrapper);
    dev_wrapper_ptr.* = .load(self.dev_handle, gdpa);

    self.dev_wrapper = dev_wrapper_ptr;
    self.dev = .init(self.dev_handle, dev_wrapper_ptr);

    owns_raw_device = false;
    errdefer {
        self.dev.destroyDevice(&self.vkalloc);
        allocator.destroy(dev_wrapper_ptr);
        self.dev_wrapper = null;
    }

    self.graphics_queue = self.dev.getDeviceQueue(queue_families.graphics, 0);
    self.present_queue = self.dev.getDeviceQueue(queue_families.present, 0);
    self.transfer_queue = self.dev.getDeviceQueue(queue_families.transfer, 0);

    const pool_info: vk.CommandPoolCreateInfo = .{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = queue_families.graphics,
    };
    self.command_pool = try self.dev.createCommandPool(&pool_info, &self.vkalloc);
    errdefer self.dev.destroyCommandPool(self.command_pool, &self.vkalloc);

    // Graphics family on purpose: single-time upload command buffers from this pool are
    // submitted to the graphics queue (see core.SingleTime.endLocked in vulkan/core.zig).
    const upload_pool_info: vk.CommandPoolCreateInfo = .{
        .flags = .{ .reset_command_buffer_bit = true, .transient_bit = true },
        .queue_family_index = queue_families.graphics,
    };
    self.upload_command_pool = try self.dev.createCommandPool(&upload_pool_info, &self.vkalloc);
    errdefer self.dev.destroyCommandPool(self.upload_command_pool, &self.vkalloc);

    self.gpu_profiler = try GpuProfiler.init(
        self.dev,
        self.graphics_queue,
        self.upload_command_pool,
        &self.vkalloc,
        self.props.limits.timestamp_period,
    );
    errdefer self.gpu_profiler.deinit();

    self.ui_command_pool = try self.dev.createCommandPool(&pool_info, &self.vkalloc);
    errdefer self.dev.destroyCommandPool(self.ui_command_pool, &self.vkalloc);

    var timeline_info: vk.SemaphoreTypeCreateInfo = .{
        .semaphore_type = .timeline,
        .initial_value = 0,
    };
    const timeline_sem_info: vk.SemaphoreCreateInfo = .{
        .p_next = &timeline_info,
        .flags = .{},
    };
    self.transfer_semaphore = try self.dev.createSemaphore(&timeline_sem_info, &self.vkalloc);
    errdefer self.dev.destroySemaphore(self.transfer_semaphore, &self.vkalloc);

    self.graphics_timeline_semaphore = try self.dev.createSemaphore(&timeline_sem_info, &self.vkalloc);
    errdefer self.dev.destroySemaphore(self.graphics_timeline_semaphore, &self.vkalloc);

    self.image_acquired_semaphores = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    @memset(self.image_acquired_semaphores, .null_handle);
    errdefer {
        for (self.image_acquired_semaphores) |sem| if (sem != .null_handle) self.dev.destroySemaphore(sem, &self.vkalloc);
        allocator.free(self.image_acquired_semaphores);
    }

    self.render_complete_semaphores = try allocator.alloc(vk.Semaphore, max_frames_in_flight);
    @memset(self.render_complete_semaphores, .null_handle);
    errdefer {
        for (self.render_complete_semaphores) |sem| if (sem != .null_handle) self.dev.destroySemaphore(sem, &self.vkalloc);
        allocator.free(self.render_complete_semaphores);
    }

    const semaphore_create_info: vk.SemaphoreCreateInfo = .{ .flags = .{} };
    for (self.image_acquired_semaphores, self.render_complete_semaphores) |*acq, *complete| {
        acq.* = try self.dev.createSemaphore(&semaphore_create_info, &self.vkalloc);
        complete.* = try self.dev.createSemaphore(&semaphore_create_info, &self.vkalloc);
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
        self.dev.destroySwapchainKHR(self.swapchain, &self.vkalloc);
        self.swapchain = .null_handle;
    }

    self.dev.freeCommandBuffers(self.command_pool, self.cmd_buffers);
    self.allocator.free(self.cmd_buffers);
    self.cmd_buffers = &.{};

    for (self.image_acquired_semaphores) |sem| if (sem != .null_handle) self.dev.destroySemaphore(sem, &self.vkalloc);
    self.allocator.free(self.image_acquired_semaphores);
    self.image_acquired_semaphores = &.{};

    for (self.render_complete_semaphores) |sem| if (sem != .null_handle) self.dev.destroySemaphore(sem, &self.vkalloc);
    self.allocator.free(self.render_complete_semaphores);
    self.render_complete_semaphores = &.{};

    self.gpu_profiler.deinit();

    self.dev.destroyCommandPool(self.command_pool, &self.vkalloc);
    if (self.upload_command_pool != .null_handle) self.dev.destroyCommandPool(self.upload_command_pool, &self.vkalloc);
    if (self.ui_command_pool != .null_handle) self.dev.destroyCommandPool(self.ui_command_pool, &self.vkalloc);

    self.dev.destroySemaphore(self.transfer_semaphore, &self.vkalloc);
    self.dev.destroySemaphore(self.graphics_timeline_semaphore, &self.vkalloc);

    self.dev.destroyDevice(&self.vkalloc);
    if (self.surface != .null_handle) self.instance.destroySurfaceKHR(self.surface, &self.vkalloc);

    if (self.instance_wrapper) |wrapper| {
        if (self.debug_callback != .null_handle) {
            self.instance.destroyDebugUtilsMessengerEXT(self.debug_callback, &self.vkalloc);
            self.debug_callback = .null_handle;
        }
        self.instance.destroyInstance(&self.vkalloc);
        self.allocator.destroy(wrapper);
    }
    if (self.dev_wrapper) |wrapper| {
        self.allocator.destroy(wrapper);
    }

    self.queue_mutex.unlock(io);
    self.allocator.destroy(self);
}

fn destroySwapchainResources(self: *VulkanContext) void {
    for (self.swapchain_views) |view| if (view != .null_handle) self.dev.destroyImageView(view, &self.vkalloc);
    self.allocator.free(self.swapchain_images);
    self.allocator.free(self.swapchain_views);
    self.allocator.free(self.swapchain_image_layouts);
    self.swapchain_images = &.{};
    self.swapchain_views = &.{};
    self.swapchain_image_layouts = &.{};
}

pub fn createSwapchainLocked(self: *VulkanContext, io: std.Io, gamma_correction: bool) !void {
    if (self.swapchain_extent.width == 0 or self.swapchain_extent.height == 0) {
        return error.InvalidWindowSize;
    }

    // The cache only applies when nothing forced a recreation: after OUT_OF_DATE / suboptimal the
    // configuration may be unchanged while the swapchain is still stale, so the flag must bypass it.
    if (self.swapchain != .null_handle and !self.swapchain_needs_recreate.load(.acquire)) {
        const current_gamma = self.swapchain_gamma.load(.monotonic);
        const extent_same = self.swapchain_extent_actual.width == self.swapchain_extent.width and
            self.swapchain_extent_actual.height == self.swapchain_extent.height;
        if (current_gamma == gamma_correction and extent_same and self.present_mode == self.last_present_mode_requested) return;
    }

    // Lock order is transfer then graphics, matching deviceWaitIdleLocked and the
    // uploader submit path; taking them in the opposite order would deadlock those
    // paths against a swapchain recreation during a resize. Callers must NOT hold
    // either mutex.
    self.transfer_queue_mutex.lockUncancelable(io);
    defer self.transfer_queue_mutex.unlock(io);
    self.queue_mutex.lockUncancelable(io);
    defer self.queue_mutex.unlock(io);

    std.log.info("VulkanContext.createSwapchain: Starting swapchain creation...", .{});

    const caps = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.pdev, self.surface);

    _ = self.dev.deviceWaitIdle() catch |err| {
        std.log.err("deviceWaitIdle failed during swapchain creation: {}", .{err});
    };
    self.dev.resetCommandPool(self.command_pool, .{}) catch {};
    if (self.ui_command_pool != .null_handle) self.dev.resetCommandPool(self.ui_command_pool, .{}) catch {};

    const old_swapchain = self.swapchain;
    self.destroySwapchainResources();

    const actual_extent = if (caps.current_extent.width != std.math.maxInt(u32))
        caps.current_extent
    else
        vk.Extent2D{
            .width = std.math.clamp(self.swapchain_extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(self.swapchain_extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
        };

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
        .image_format = surface_format.format,
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
    }, &self.vkalloc);

    errdefer self.dev.destroySwapchainKHR(new_swapchain, &self.vkalloc);

    const new_images = try self.dev.getSwapchainImagesAllocKHR(new_swapchain, self.allocator);
    errdefer self.allocator.free(new_images);

    const new_views = try self.allocator.alloc(vk.ImageView, new_images.len);
    @memset(new_views, .null_handle);
    errdefer {
        for (new_views) |view| {
            if (view != .null_handle) self.dev.destroyImageView(view, &self.vkalloc);
        }
        self.allocator.free(new_views);
    }

    for (new_images, new_views) |image, *view| {
        view.* = try self.dev.createImageView(&.{
            .flags = .{},
            .image = image,
            .view_type = .@"2d",
            .format = surface_format.format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        }, &self.vkalloc);
    }

    // Finish all fallible work before tearing down the old swapchain and semaphores:
    // a mid-creation failure then leaves self.swapchain / self.render_complete_semaphores
    // still referencing valid, owned resources for deinit to clean up.
    const new_render_complete = try self.allocator.alloc(vk.Semaphore, new_images.len);
    @memset(new_render_complete, .null_handle);
    errdefer {
        for (new_render_complete) |sem| if (sem != .null_handle) self.dev.destroySemaphore(sem, &self.vkalloc);
        self.allocator.free(new_render_complete);
    }
    const semaphore_create_info: vk.SemaphoreCreateInfo = .{ .flags = .{} };
    for (new_render_complete) |*complete| {
        complete.* = try self.dev.createSemaphore(&semaphore_create_info, &self.vkalloc);
    }

    const new_layouts = try self.allocator.alloc(vk.ImageLayout, new_images.len);
    errdefer self.allocator.free(new_layouts);
    @memset(new_layouts, .undefined);

    if (old_swapchain != .null_handle) {
        self.dev.destroySwapchainKHR(old_swapchain, &self.vkalloc);
    }
    for (self.render_complete_semaphores) |sem| {
        if (sem != .null_handle) self.dev.destroySemaphore(sem, &self.vkalloc);
    }
    self.allocator.free(self.render_complete_semaphores);

    self.render_complete_semaphores = new_render_complete;
    self.swapchain = new_swapchain;
    self.swapchain_images = new_images;
    self.swapchain_views = new_views;
    self.swapchain_image_layouts = new_layouts;
    self.last_present_mode_requested = self.present_mode;
    // Cache/state fields commit only after creation succeeds, so a failed recreation cannot leave
    // a stale config that makes a retry early-return without a valid replacement swapchain.
    self.swapchain_extent = actual_extent;
    self.swapchain_extent_actual = actual_extent;
    self.swapchain_gamma.store(gamma_correction, .monotonic);
    self.swapchain_format = surface_format.format;
    self.swapchain_needs_recreate.store(false, .monotonic);
}

pub fn transitionImageLayout(dev: vk.DeviceProxy, cmd: vk.CommandBuffer, image: vk.Image, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) void {
    const src_stage: vk.PipelineStageFlags2 = switch (old_layout) {
        .undefined => .{ .top_of_pipe_bit = true },
        .present_src_khr => .{ .color_attachment_output_bit = true },
        .color_attachment_optimal => .{ .color_attachment_output_bit = true },
        else => .{ .all_commands_bit = true },
    };
    const src_access: vk.AccessFlags2 = switch (old_layout) {
        .undefined => .{},
        .present_src_khr => .{},
        .color_attachment_optimal => .{ .color_attachment_write_bit = true },
        else => .{ .memory_read_bit = true, .memory_write_bit = true },
    };
    const barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        // present_src_khr uses bottom_of_pipe with an empty access mask on purpose: the present
        // engine's reads are ordered by the render-complete semaphore, not by barrier access.
        .dst_stage_mask = if (new_layout == .color_attachment_optimal) .{ .color_attachment_output_bit = true } else .{ .bottom_of_pipe_bit = true },
        .dst_access_mask = if (new_layout == .color_attachment_optimal) .{ .color_attachment_write_bit = true, .color_attachment_read_bit = true } else .{},
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    dev.cmdPipelineBarrier2(cmd, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = (&barrier)[0..1],
    });
}

/// Waits for device idle while excluding both submit paths: deviceWaitIdle must
/// not run concurrently with any queue submission, and transfer submits only hold
/// the transfer mutex. Lock order is transfer then graphics, like allocRegion.
pub fn deviceWaitIdleLocked(self: *VulkanContext, io: std.Io) !void {
    self.transfer_queue_mutex.lockUncancelable(io);
    defer self.transfer_queue_mutex.unlock(io);
    self.queue_mutex.lockUncancelable(io);
    defer self.queue_mutex.unlock(io);
    _ = try self.dev.deviceWaitIdle();
}

pub fn currentFrame(self: *VulkanContext) u32 {
    return self.current_frame_idx.load(.monotonic);
}

pub fn requestSwapchainRecreate(self: *VulkanContext) void {
    self.suboptimal_recreate_requested.store(false, .release);
    self.swapchain_needs_recreate.store(true, .release);
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
    self.gpu_profiler.prepareFrame(current_frame);
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
            error.OutOfDateKHR => {
                self.swapchain_needs_recreate.store(true, .monotonic);
                return error.OutOfDate;
            },
            error.SurfaceLostKHR => return error.SurfaceLost,
            else => return err,
        };
    };

    if (acquire_result.result == .suboptimal_khr and
        !self.suboptimal_recreate_requested.swap(true, .acq_rel))
    {
        self.swapchain_needs_recreate.store(true, .release);
    }

    return acquire_result.image_index;
}

pub fn submitFrameWithExtra(self: *VulkanContext, io: std.Io, ctx: FrameContext, prepass_cmd_buffer: vk.CommandBuffer, ui_cmd_buffer: vk.CommandBuffer, include_game: bool) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "submitFrame" });
    defer zone.end();

    const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "submitFrame_lock_queue" });
    self.queue_mutex.lockUncancelable(io);
    zone_lock.end();
    defer self.queue_mutex.unlock(io);

    const current_transfer_val = self.transfer_semaphore_value.load(.monotonic);
    // Commit the frame number only after the submit succeeds: a failed submit must
    // not claim a value the GPU never signals, or every later wait on it (transfer
    // batches, drains, the beginFrame throttle) would block forever.
    const current_graphics_val = self.frame_number.load(.monotonic) + 1;
    // On frame 0 prev_graphics_val is 0, equal to the timeline's initial value, so the wait
    // on it below is immediately satisfied; it only gates on prior frames from then on.
    const prev_graphics_val = current_graphics_val - 1;

    const wait_semaphore_infos: [3]vk.SemaphoreSubmitInfo = .{
        // ALL_COMMANDS_BIT ensures the semaphore dependency covers all pipeline stages
        // the validation layer tracks for the swapchain acquire. COLOR_ATTACHMENT_OUTPUT
        // alone is insufficient because VkPipelineStageFlags2 access scopes only include
        // explicitly specified stages, and the present engine read barriers span multiple stages.
        .{ .semaphore = self.image_acquired_semaphores[ctx.frame_index], .value = 0, .stage_mask = .{ .all_commands_bit = true }, .device_index = 0 },
        .{ .semaphore = self.transfer_semaphore, .value = current_transfer_val, .stage_mask = .{ .vertex_attribute_input_bit = true }, .device_index = 0 },
        .{ .semaphore = self.graphics_timeline_semaphore, .value = prev_graphics_val, .stage_mask = .{ .top_of_pipe_bit = true }, .device_index = 0 },
    };

    const signal_semaphore_infos: [2]vk.SemaphoreSubmitInfo = .{
        .{ .semaphore = self.render_complete_semaphores[ctx.image_index], .value = 0, .stage_mask = .{ .bottom_of_pipe_bit = true }, .device_index = 0 },
        .{ .semaphore = self.graphics_timeline_semaphore, .value = current_graphics_val, .stage_mask = .{ .all_commands_bit = true }, .device_index = 0 },
    };

    var cmd_buffer_infos: [3]vk.CommandBufferSubmitInfo = undefined;
    var cmd_buffer_count: u32 = 0;
    if (include_game) {
        cmd_buffer_infos[0] = .{ .command_buffer = ctx.cmd_buffer, .device_mask = 0 };
        cmd_buffer_count += 1;
    }
    if (prepass_cmd_buffer != .null_handle) {
        cmd_buffer_infos[cmd_buffer_count] = .{ .command_buffer = prepass_cmd_buffer, .device_mask = 0 };
        cmd_buffer_count += 1;
    }
    if (ui_cmd_buffer != .null_handle) {
        cmd_buffer_infos[cmd_buffer_count] = .{ .command_buffer = ui_cmd_buffer, .device_mask = 0 };
        cmd_buffer_count += 1;
    }

    const submit_info: vk.SubmitInfo2 = .{
        .flags = .{},
        .wait_semaphore_info_count = wait_semaphore_infos.len,
        .p_wait_semaphore_infos = &wait_semaphore_infos,
        .command_buffer_info_count = cmd_buffer_count,
        .p_command_buffer_infos = cmd_buffer_infos[0..cmd_buffer_count].ptr,
        .signal_semaphore_info_count = signal_semaphore_infos.len,
        .p_signal_semaphore_infos = &signal_semaphore_infos,
    };

    const zone_submit = tracy.Zone.begin(.{ .src = @src(), .name = "queueSubmit2" });
    defer zone_submit.end();
    try self.dev.queueSubmit2(self.graphics_queue, (&submit_info)[0..1], .null_handle);
    self.gpu_profiler.markSubmitted(ctx.frame_index);
    self.frame_number.store(current_graphics_val, .release);
}

pub fn present(self: *VulkanContext, io: std.Io, ctx: FrameContext) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "present" });
    defer zone.end();

    const present_info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = (&self.render_complete_semaphores[ctx.image_index])[0..1],
        .swapchain_count = 1,
        .p_swapchains = (&self.swapchain)[0..1],
        .p_image_indices = (&ctx.image_index)[0..1],
        .p_results = null,
    };
    const next_frame = (ctx.frame_index + 1) % max_frames_in_flight;
    const present_result = blk: {
        const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "present_lock_queue" });
        self.queue_mutex.lockUncancelable(io);
        zone_lock.end();
        defer self.queue_mutex.unlock(io);

        const zone_present = tracy.Zone.begin(.{ .src = @src(), .name = "queuePresent" });
        defer zone_present.end();
        break :blk self.dev.queuePresentKHR(self.present_queue, &present_info) catch |err| switch (err) {
            error.OutOfDateKHR => {
                self.swapchain_needs_recreate.store(true, .monotonic);
                self.current_frame_idx.store(next_frame, .monotonic);
                return error.OutOfDate;
            },
            error.SurfaceLostKHR => {
                self.current_frame_idx.store(next_frame, .monotonic);
                return error.SurfaceLost;
            },
            else => return err,
        };
    };
    if (present_result == .success or present_result == .suboptimal_khr) {
        if (present_result == .suboptimal_khr and
            !self.suboptimal_recreate_requested.swap(true, .acq_rel))
        {
            self.swapchain_needs_recreate.store(true, .release);
        }
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
    _ = message_types;
    _ = p_user_data;
    const cb_data = p_callback_data orelse return .false;
    const msg = std.mem.span(cb_data.p_message orelse return .false);

    // No suppressions for the latest validation layer version, previous ones have false positives
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

pub const VulkanHostAllocator = struct {
    allocator: std.mem.Allocator,

    const Header = struct {
        size: usize,
        padding: usize,
        align_bytes: usize,
    };

    pub fn getCallbacks(self: *VulkanHostAllocator) vk.AllocationCallbacks {
        return .{
            .p_user_data = self,
            .pfn_allocation = allocationCallback,
            .pfn_reallocation = reallocationCallback,
            .pfn_free = freeCallback,
            .pfn_internal_allocation = null,
            .pfn_internal_free = null,
        };
    }

    fn allocationCallback(
        p_user_data: ?*anyopaque,
        size: usize,
        alignment: usize,
        allocation_scope: vk.SystemAllocationScope,
    ) callconv(.c) ?*anyopaque {
        _ = allocation_scope;
        if (size == 0) return null;

        const user_data = p_user_data orelse return null;
        const self: *VulkanHostAllocator = @ptrCast(@alignCast(user_data));

        const align_bytes = @max(alignment, @alignOf(usize));
        const padding = std.mem.alignForward(usize, @sizeOf(Header), align_bytes);
        const total_bytes = size + padding;

        const raw_mem = self.allocator.rawAlloc(
            total_bytes,
            .fromByteUnits(align_bytes),
            @returnAddress(),
        ) orelse return null;

        const header_ptr: *Header = @ptrCast(@alignCast(raw_mem + padding - @sizeOf(Header)));
        header_ptr.* = .{
            .size = total_bytes,
            .padding = padding,
            .align_bytes = align_bytes,
        };

        return raw_mem + padding;
    }

    fn reallocationCallback(
        p_user_data: ?*anyopaque,
        p_original: ?*anyopaque,
        size: usize,
        alignment: usize,
        allocation_scope: vk.SystemAllocationScope,
    ) callconv(.c) ?*anyopaque {
        const original_ptr = p_original orelse {
            return allocationCallback(p_user_data, size, alignment, allocation_scope);
        };

        if (size == 0) {
            freeCallback(p_user_data, p_original);
            return null;
        }

        const new_ptr = allocationCallback(p_user_data, size, alignment, allocation_scope) orelse return null;

        const orig_bytes: [*]u8 = @ptrCast(original_ptr);
        const header_ptr: *Header = @ptrCast(@alignCast(orig_bytes - @sizeOf(Header)));

        const old_payload_size = header_ptr.size - header_ptr.padding;
        const copy_size = @min(size, old_payload_size);

        const new_bytes: [*]u8 = @ptrCast(new_ptr);
        @memcpy(new_bytes[0..copy_size], orig_bytes[0..copy_size]);

        freeCallback(p_user_data, p_original);
        return new_ptr;
    }

    fn freeCallback(p_user_data: ?*anyopaque, p_memory: ?*anyopaque) callconv(.c) void {
        const memory = p_memory orelse return;
        const user_data = p_user_data orelse return;
        const self: *VulkanHostAllocator = @ptrCast(@alignCast(user_data));

        const mem_bytes: [*]u8 = @ptrCast(memory);
        const header_ptr: *Header = @ptrCast(@alignCast(mem_bytes - @sizeOf(Header)));

        const raw_ptr = mem_bytes - header_ptr.padding;
        const full_slice = raw_ptr[0..header_ptr.size];

        self.allocator.rawFree(
            full_slice,
            .fromByteUnits(header_ptr.align_bytes),
            @returnAddress(),
        );
    }
};

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
    try wio.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .eventFn = wio.EventQueue.eventFn });
    defer wio.deinit();

    var events: wio.EventQueue = .empty;
    defer events.deinit();

    var window = try wio.Window.create(.{ .title = "test", .event_fn_data = &events });
    defer window.destroy();

    const ctx = try VulkanContext.init(std.testing.allocator, &window);
    defer ctx.deinit(std.testing.io);

    ctx.swapchain_extent = .{ .width = 640, .height = 480 };
    try ctx.createSwapchainLocked(std.testing.io, false);

    var render_opts: Renderer.RenderOptions = .{};
    var render_opts_lock: std.Io.RwLock = .init;

    var renderer: VulkanRenderer = undefined;
    try renderer.init(std.testing.io, std.testing.allocator, ctx, &render_opts, &render_opts_lock);
    defer renderer.deinit(std.testing.io);
}

test "VulkanRenderer mesh upload" {
    try wio.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .eventFn = wio.EventQueue.eventFn });
    defer wio.deinit();

    var events: wio.EventQueue = .empty;
    defer events.deinit();

    var window = try wio.Window.create(.{ .title = "test", .event_fn_data = &events });
    defer window.destroy();

    const ctx = try VulkanContext.init(std.testing.allocator, &window);
    defer ctx.deinit(std.testing.io);

    ctx.swapchain_extent = .{ .width = 640, .height = 480 };
    try ctx.createSwapchainLocked(std.testing.io, false);

    var render_opts: Renderer.RenderOptions = .{};
    var render_opts_lock: std.Io.RwLock = .init;

    var renderer: VulkanRenderer = undefined;
    try renderer.init(std.testing.io, std.testing.allocator, ctx, &render_opts, &render_opts_lock);
    defer renderer.deinit(std.testing.io);

    var iface = renderer.interface;

    var grid: [World.ChunkSize][World.ChunkSize][World.ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));
    grid[1][1][1] = .stone;
    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    const chunk_pos: World.ChunkPos = .{ .level = 0, .position = .{ 0, 0, 0 } };
    try iface.addChunk(std.testing.io, chunk_pos, .{ .grid = &grid }, &neighbor_faces);
}

test "StagingRing alloc wrap-around" {
    try wio.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .eventFn = wio.EventQueue.eventFn });
    defer wio.deinit();

    var events: wio.EventQueue = .empty;
    defer events.deinit();

    var window = try wio.Window.create(.{ .title = "test", .event_fn_data = &events });
    defer window.destroy();

    const ctx = try VulkanContext.init(std.testing.allocator, &window);
    defer ctx.deinit(std.testing.io);

    var backing = core.VulkanBackingAllocator.init(ctx.dev, ctx.mem_props, std.testing.io, std.testing.allocator, ctx.queue_family_index, ctx.transfer_queue_family_index, ctx.vkalloc);
    defer backing.deinit();

    const cpu_alloc = backing.allocator(.cpu_to_gpu);

    const ring_capacity: vk.DeviceSize = Mesher.max_face_bytes;
    var ring = try gpu.StagingRing.init(std.testing.allocator, cpu_alloc, ring_capacity);
    defer ring.deinit(cpu_alloc);

    const staging_info = backing.getBufferAndOffset(.cpu_to_gpu, ring.mapping.ptr);
    ring.resolve(staging_info.buffer);

    const s1 = try ring.alloc(std.testing.io, 8);
    try std.testing.expect(s1 != null);
    @memset(s1.?, 0xab);

    const s2 = try ring.alloc(std.testing.io, 8);
    try std.testing.expect(s2 != null);
    @memset(s2.?, 0xcd);

    try std.testing.expect(s1.?[0] == 0xab);
    try std.testing.expect(s2.?[0] == 0xcd);

    const s3 = try ring.alloc(std.testing.io, ring.mapping.len);
    try std.testing.expect(s3 == null);

    ring.retire(std.testing.io, 1);

    const s4 = try ring.alloc(std.testing.io, 8);
    try std.testing.expect(s4 != null);
}

fn stagingRingAllocDeinit(alloc: std.mem.Allocator) !void {
    var ring = try gpu.StagingRing.init(alloc, alloc, Mesher.max_face_bytes);
    defer ring.deinit(alloc);
    ring.resolve(@enumFromInt(1));
    // Exercises the alloc path, whose entry bookkeeping allocation must propagate
    // OutOfMemory instead of being mistaken for a full ring.
    const slice = try ring.alloc(std.testing.io, 8);
    try std.testing.expect(slice != null);
}

test "StagingRing checkAllAllocationFailures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, stagingRingAllocDeinit, .{});
}

test "StagingRing allocPair atomicity" {
    const io = std.testing.io;
    var ring = try gpu.StagingRing.init(std.testing.allocator, std.testing.allocator, 1024);
    defer ring.deinit(std.testing.allocator);
    ring.resolve(@enumFromInt(1));

    // Zero sizes yield null slots without consuming space.
    const empty = (try ring.allocPair(io, .{ 0, 0 })).?;
    try std.testing.expectEqual(null, empty[0]);
    try std.testing.expectEqual(null, empty[1]);

    const pair = (try ring.allocPair(io, .{ 8, 16 })).?;
    try std.testing.expectEqual(@as(usize, 8), pair[0].?.len);
    try std.testing.expectEqual(@as(usize, 16), pair[1].?.len);

    // A pair that does not fit as a whole is refused entirely; nothing is consumed.
    try std.testing.expectEqual(null, try ring.allocPair(io, .{ 512, 512 }));

    // After both slices retire, the refused pair fits again.
    ring.bind(io, pair[0].?, 1);
    ring.bind(io, pair[1].?, 1);
    ring.retire(io, 1);
    const big = (try ring.allocPair(io, .{ 512, 512 })).?;
    try std.testing.expect(big[0] != null and big[1] != null);

    // A pair larger than the whole ring fails loudly instead of spinning forever.
    try std.testing.expectError(error.StagingTooLarge, ring.allocPair(io, .{ 1024, 1024 }));
}

fn stagingRingAllocPairDeinit(alloc: std.mem.Allocator) !void {
    var ring = try gpu.StagingRing.init(alloc, alloc, Mesher.max_face_bytes);
    defer ring.deinit(alloc);
    ring.resolve(@enumFromInt(1));
    // The entry bookkeeping reservation must propagate OutOfMemory before mutating
    // the ring, so a failed pair leaves no partial state behind.
    const pair = try ring.allocPair(std.testing.io, .{ 8, 8 });
    try std.testing.expect(pair != null);
}

test "StagingRing allocPair checkAllAllocationFailures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, stagingRingAllocPairDeinit, .{});
}

test "GpuRegionAllocator init and deinit" {
    try wio.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .eventFn = wio.EventQueue.eventFn });
    defer wio.deinit();

    var events: wio.EventQueue = .empty;
    defer events.deinit();

    var window = try wio.Window.create(.{ .title = "test", .event_fn_data = &events });
    defer window.destroy();

    const ctx = try VulkanContext.init(std.testing.allocator, &window);
    defer ctx.deinit(std.testing.io);

    var backing = core.VulkanBackingAllocator.init(ctx.dev, ctx.mem_props, std.testing.io, std.testing.allocator, ctx.queue_family_index, ctx.transfer_queue_family_index, ctx.vkalloc);
    defer backing.deinit();

    const gpu_alloc = backing.allocator(.gpu_only);

    var alloc = try gpu.GpuRegionAllocator.init(std.testing.allocator, gpu_alloc, 64 * 1024 * 1024);
    defer alloc.deinit(gpu_alloc);

    const buf_info = backing.getBufferAndOffset(.gpu_only, alloc.buffer_slice.ptr);
    alloc.resolve(buf_info.buffer, buf_info.offset);
}

test "GpuRegionAllocator grow and retire old buffer" {
    try wio.init(.{ .allocator = std.testing.allocator, .io = std.testing.io, .eventFn = wio.EventQueue.eventFn });
    defer wio.deinit();

    var events: wio.EventQueue = .empty;
    defer events.deinit();

    var window = try wio.Window.create(.{ .title = "test", .event_fn_data = &events });
    defer window.destroy();

    const ctx = try VulkanContext.init(std.testing.allocator, &window);
    defer ctx.deinit(std.testing.io);

    var backing = core.VulkanBackingAllocator.init(ctx.dev, ctx.mem_props, std.testing.io, std.testing.allocator, ctx.queue_family_index, ctx.transfer_queue_family_index, ctx.vkalloc);
    defer backing.deinit();

    const gpu_alloc = backing.allocator(.gpu_only);

    var alloc = try gpu.GpuRegionAllocator.init(std.testing.allocator, gpu_alloc, 64 * 1024 * 1024);

    const buf_info = backing.getBufferAndOffset(.gpu_only, alloc.buffer_slice.ptr);
    alloc.resolve(buf_info.buffer, buf_info.offset);

    const grow_info = try alloc.grow(std.testing.io, gpu_alloc);
    gpu_alloc.free(grow_info.old_slice);
    const grow_info2 = try alloc.grow(std.testing.io, gpu_alloc);
    gpu_alloc.free(grow_info2.old_slice);

    alloc.deinit(gpu_alloc);
}
