const std = @import("std");
const builtin = @import("builtin");

const options = @import("options");
const tracy = @import("tracy");
const vk = @import("vulkan");
const wio = @import("wio");

const Renderer = @import("Renderer.zig");
const zignal = @import("zignal");
const core = @import("Renderer/vulkan/core.zig");
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

/// Lists screenshot resolutions. Native keeps the current swapchain size.
pub const ScreenshotResolution = enum {
    native,
    @"720p",
    @"1080p",
    @"1440p",
    @"4k",
    @"8k",

    pub fn label(self: @This()) []const u8 {
        return switch (self) {
            .native => "Native (Window)",
            .@"720p" => "1280 x 720 (HD)",
            .@"1080p" => "1920 x 1080 (Full HD)",
            .@"1440p" => "2560 x 1440 (QHD)",
            .@"4k" => "3840 x 2160 (4K UHD)",
            .@"8k" => "7680 x 4320 (8K UHD)",
        };
    }

    pub fn targetExtent(self: @This(), native: vk.Extent2D) vk.Extent2D {
        return switch (self) {
            .native => native,
            .@"720p" => .{ .width = 1280, .height = 720 },
            .@"1080p" => .{ .width = 1920, .height = 1080 },
            .@"1440p" => .{ .width = 2560, .height = 1440 },
            .@"4k" => .{ .width = 3840, .height = 2160 },
            .@"8k" => .{ .width = 7680, .height = 4320 },
        };
    }
};

pub const VulkanContext = @This();

pub const max_frames_in_flight: u32 = 2;

allocator: std.mem.Allocator,
surface: vk.SurfaceKHR = .null_handle,

instance: vk.InstanceProxy,

debug_callback: vk.DebugUtilsMessengerEXT,

pdev: vk.PhysicalDevice,
props: vk.PhysicalDeviceProperties,
mem_props: vk.PhysicalDeviceMemoryProperties,
sampler_anisotropy: bool = false,
pipeline_creation_feedback: bool = false,
depth_clamp: bool = false,
depth_bias_clamp: bool = false,

dev: vk.DeviceProxy,

graphics_queue: vk.Queue,
present_queue: vk.Queue,
queue_family_index: u32,
present_queue_family_index: u32,

command_pool: vk.CommandPool,
upload_command_pool: vk.CommandPool = .null_handle,
cmd_buffers: [max_frames_in_flight]vk.CommandBuffer = undefined,

image_acquired_semaphores: [max_frames_in_flight]vk.Semaphore = @splat(.null_handle),

swapchain: vk.SwapchainKHR = .null_handle,
swapchain_format: vk.Format = .b8g8r8a8_srgb,
swapchain_images: []SwapchainImage = &.{},
swapchain_extent: vk.Extent2D = .{ .width = 800, .height = 600 },
// The frame loop thread owns these flags, like every other swapchain field.
swapchain_needs_recreate: bool = false,
suboptimal_recreate_requested: bool = false,

transfer_queue: vk.Queue = undefined,
transfer_queue_family_index: u32 = undefined,
ui_command_pool: vk.CommandPool = .null_handle,
transfer_semaphore: vk.Semaphore = .null_handle,
transfer_semaphore_value: std.atomic.Value(u64) = .init(0),
graphics_timeline_semaphore: vk.Semaphore = .null_handle,
gpu_profiler: GpuProfiler = .{},
// Cross-thread frame counter: read with .acquire by submitBatch / waitSubmittedFrames and
// advanced with .release by submitFrameWithExtra; the pair orders the two submit paths.
frame_number: std.atomic.Value(u64) = .init(0),
queue_mutex: std.Io.Mutex = .init,
/// Serializes transfer-queue submissions against the face-buffer grow, so a transfer
/// submit does not queue behind graphics submits, present, or scene growth stalls.
transfer_queue_mutex: std.Io.Mutex = .init,

/// Routes Vulkan host allocations to `allocator`.
vkalloc: vk.AllocationCallbacks,

screenshot_staging: ?ScreenshotStaging = null,
/// Set by `requestScreenshot`; the next UI pass records the copy.
screenshot_request: ?ScreenshotResolution = null,
/// Set when a submitted frame copies the swapchain image; `savePendingScreenshot` saves it.
pending_screenshot: ?PendingScreenshot = null,

/// One swapchain image and the resources indexed by its image index.
pub const SwapchainImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    layout: vk.ImageLayout,
    render_complete: vk.Semaphore,
};

/// A host-visible buffer that receives screenshot copies. It grows and is never shrunk.
const ScreenshotStaging = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    mapped: [*]u8,
    size: vk.DeviceSize,
};

const PendingScreenshot = struct {
    extent: vk.Extent2D,
    resolution: ScreenshotResolution,
};

fn getProcAddr(instance: ?vk.Instance, procname: [*:0]const u8) ?*const fn () void {
    return @ptrCast(wio.vkGetInstanceProcAddr(@intFromPtr(instance), procname));
}

fn selectPhysicalDevice(self: *VulkanContext, allocator: std.mem.Allocator) !vk.PhysicalDevice {
    var pdev_count: u32 = undefined;
    _ = try self.instance.enumeratePhysicalDevices(&pdev_count, null);
    const pdevs = try allocator.alloc(vk.PhysicalDevice, pdev_count);
    defer allocator.free(pdevs);
    _ = try self.instance.enumeratePhysicalDevices(&pdev_count, pdevs.ptr);

    var selected_pdev: ?vk.PhysicalDevice = null;
    var best_score: u32 = 0;

    for (pdevs) |pdev| {
        var robustness2_features: vk.PhysicalDeviceRobustness2FeaturesEXT = .{};
        var features13: vk.PhysicalDeviceVulkan13Features = .{ .p_next = @ptrCast(&robustness2_features) };
        var features12: vk.PhysicalDeviceVulkan12Features = .{ .p_next = @ptrCast(&features13) };
        var features11: vk.PhysicalDeviceVulkan11Features = .{ .p_next = @ptrCast(&features12) };
        var features2: vk.PhysicalDeviceFeatures2 = .{ .features = .{}, .p_next = @ptrCast(&features11) };
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

        _ = self.selectQueueFamilies(pdev, allocator) catch |err| switch (err) {
            error.NoGraphicsQueue, error.NoPresentQueue => continue,
            else => return err,
        };

        const ext_props = try self.instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
        defer allocator.free(ext_props);
        const has_required_extensions = for (required_device_extensions) |name| {
            if (!hasExtension(ext_props, name)) break false;
        } else true;
        if (!has_required_extensions) continue;

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
            if (std.mem.find(u8, device_name, "NVIDIA") != null) score = 1;
        }
        if (score > best_score) {
            best_score = score;
            selected_pdev = pdev;
            self.sampler_anisotropy = anisotropy_supported;
            self.depth_clamp = features2.features.depth_clamp == .true;
            self.depth_bias_clamp = features2.features.depth_bias_clamp == .true;
        }
    }
    return selected_pdev orelse error.NoSuitablePhysicalDevice;
}

const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
    vk.extensions.ext_robustness_2.name,
    vk.extensions.khr_push_descriptor.name,
};

fn hasExtension(ext_props: []const vk.ExtensionProperties, name: [*:0]const u8) bool {
    for (ext_props) |ext| {
        if (std.mem.eql(u8, std.mem.sliceTo(&ext.extension_name, 0), std.mem.span(name))) return true;
    }
    return false;
}

fn selectQueueFamilies(self: *VulkanContext, pdev: vk.PhysicalDevice, allocator: std.mem.Allocator) !struct { graphics: u32, present: u32, transfer: u32 } {
    const queue_families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
    defer allocator.free(queue_families);
    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;
    var transfer_family: ?u32 = null;
    var transfer_score: u8 = 0;
    for (queue_families, 0..) |qf, family| {
        const family_idx: u32 = @intCast(family);
        if (graphics_family == null and qf.queue_flags.graphics) graphics_family = family_idx;
        if (present_family == null and (try self.instance.getPhysicalDeviceSurfaceSupportKHR(pdev, family_idx, self.surface)) == .true) present_family = family_idx;
        if (qf.queue_flags.transfer) {
            const score: u8 = if (!qf.queue_flags.graphics and !qf.queue_flags.compute) 3 else if (!qf.queue_flags.graphics) 2 else 1;
            if (score > transfer_score) {
                transfer_family = family_idx;
                transfer_score = score;
            }
        }
    }
    const final_graphics = graphics_family orelse return error.NoGraphicsQueue;
    var final_present = present_family orelse return error.NoPresentQueue;
    if (final_present != final_graphics and
        (try self.instance.getPhysicalDeviceSurfaceSupportKHR(pdev, final_graphics, self.surface)) == .true)
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
        .vkalloc = host_allocation.callbacks(&self.allocator),
        .debug_callback = .null_handle,
        .allocator = allocator,
        .instance = undefined,
        .pdev = undefined,
        .props = undefined,
        .mem_props = undefined,
        .dev = undefined,
        .graphics_queue = undefined,
        .present_queue = undefined,
        .queue_family_index = undefined,
        .present_queue_family_index = undefined,
        .command_pool = undefined,
    };

    const vkb: vk.BaseWrapper = .load(getProcAddr);

    const app_info: vk.ApplicationInfo = .{
        .p_application_name = "Terrafinity",
        .application_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
        .p_engine_name = "No Engine",
        .engine_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
        .api_version = vk.API_VERSION_1_3.toU32(),
    };

    var extension_names: std.ArrayList([*:0]const u8) = .empty;
    defer extension_names.deinit(allocator);

    try extension_names.appendSlice(allocator, wio.getRequiredVulkanInstanceExtensions());

    const extensions = try vkb.enumerateInstanceExtensionPropertiesAlloc(null, allocator);
    defer allocator.free(extensions);
    const has_portability = hasExtension(extensions, vk.extensions.khr_portability_enumeration.name);
    const has_debug_utils = hasExtension(extensions, vk.extensions.ext_debug_utils.name);
    if (has_portability) try extension_names.append(allocator, vk.extensions.khr_portability_enumeration.name);
    if (has_debug_utils) try extension_names.append(allocator, vk.extensions.ext_debug_utils.name);

    const validation_layer: [*:0]const u8 = "VK_LAYER_KHRONOS_validation";
    var enable_validation = false;
    if (builtin.mode == .debug) {
        const layers = try vkb.enumerateInstanceLayerPropertiesAlloc(allocator);
        defer allocator.free(layers);
        enable_validation = for (layers) |layer| {
            if (std.mem.eql(u8, std.mem.sliceTo(&layer.layer_name, 0), std.mem.span(validation_layer))) break true;
        } else false;
        if (enable_validation) std.log.info("Enabling Vulkan validation layer", .{});
    }

    const instance_create_info: vk.InstanceCreateInfo = .{
        .flags = .{ .enumerate_portability_khr = has_portability },
        .p_application_info = &app_info,
        .enabled_layer_count = @intFromBool(enable_validation),
        .pp_enabled_layer_names = (&validation_layer)[0..1],
        .enabled_extension_count = @intCast(extension_names.items.len),
        .pp_enabled_extension_names = @ptrCast(extension_names.items.ptr),
    };

    // Allocate the wrapper first so nothing fallible sits between creating the instance and owning it.
    const instance_wrapper = try allocator.create(vk.InstanceWrapper);
    errdefer allocator.destroy(instance_wrapper);
    const instance_handle = try vkb.createInstance(&instance_create_info, &self.vkalloc);
    instance_wrapper.* = .load(instance_handle, getProcAddr);
    self.instance = .init(instance_handle, instance_wrapper);
    errdefer self.instance.destroyInstance(&self.vkalloc);

    if (has_debug_utils) {
        self.debug_callback = try self.instance.createDebugUtilsMessengerEXT(&.{
            .message_severity = .{ .info_ext = true, .verbose_ext = true, .error_ext = true, .warning_ext = true },
            .message_type = .{ .device_address_binding_ext = true, .validation_ext = true, .performance_ext = true, .general_ext = true },
            .pfn_user_callback = &debugCallback,
        }, &self.vkalloc);
    }
    errdefer if (self.debug_callback != .null_handle) self.instance.destroyDebugUtilsMessengerEXT(self.debug_callback, &self.vkalloc);

    var surface: vk.SurfaceKHR = .null_handle;
    try window.vkCreateSurface(@intFromPtr(self.instance.handle), &self.vkalloc, @ptrCast(&surface));

    self.surface = surface;
    errdefer self.instance.destroySurfaceKHR(self.surface, &self.vkalloc);

    self.pdev = try self.selectPhysicalDevice(allocator);
    self.props = self.instance.getPhysicalDeviceProperties(self.pdev);
    self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);

    const ext_props = try self.instance.enumerateDeviceExtensionPropertiesAlloc(self.pdev, null, allocator);
    defer allocator.free(ext_props);
    self.pipeline_creation_feedback = hasExtension(ext_props, vk.extensions.ext_pipeline_creation_feedback.name);
    std.log.info("Physical device supports VK_EXT_pipeline_creation_feedback: {}", .{self.pipeline_creation_feedback});

    const queue_families = try self.selectQueueFamilies(self.pdev, allocator);
    self.queue_family_index = queue_families.graphics;
    self.present_queue_family_index = queue_families.present;
    self.transfer_queue_family_index = queue_families.transfer;

    var device_extension_buf: [5][*:0]const u8 = undefined;
    var device_extensions: std.ArrayList([*:0]const u8) = .initBuffer(&device_extension_buf);
    // selectPhysicalDevice rejects devices missing any of these.
    device_extensions.appendSliceAssumeCapacity(&required_device_extensions);
    if (self.pipeline_creation_feedback) {
        device_extensions.appendAssumeCapacity(vk.extensions.ext_pipeline_creation_feedback.name);
    }
    // Mandatory to enable when exposed by portability implementations (e.g. MoltenVK).
    if (hasExtension(ext_props, vk.extensions.khr_portability_subset.name)) {
        device_extensions.appendAssumeCapacity(vk.extensions.khr_portability_subset.name);
    }

    const queue_priority: f32 = 1.0;
    var queue_create_infos: [3]vk.DeviceQueueCreateInfo = undefined;
    var queue_count: u32 = 0;
    const families: [3]u32 = .{ queue_families.graphics, queue_families.present, queue_families.transfer };
    for (families, 0..) |f, i| {
        if (std.mem.findScalar(u32, families[0..i], f) != null) continue;
        queue_create_infos[queue_count] = .{
            .queue_family_index = f,
            .queue_count = 1,
            .p_queue_priorities = (&queue_priority)[0..1],
        };
        queue_count += 1;
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

    const dev_wrapper = try allocator.create(vk.DeviceWrapper);
    errdefer allocator.destroy(dev_wrapper);
    const dev_handle = try self.instance.createDevice(self.pdev, &device_info, &self.vkalloc);
    dev_wrapper.* = .load(dev_handle, gdpa);
    self.dev = .init(dev_handle, dev_wrapper);
    errdefer self.dev.destroyDevice(&self.vkalloc);

    self.graphics_queue = self.dev.getDeviceQueue(queue_families.graphics, 0);
    self.present_queue = self.dev.getDeviceQueue(queue_families.present, 0);
    self.transfer_queue = self.dev.getDeviceQueue(queue_families.transfer, 0);

    const pool_info: vk.CommandPoolCreateInfo = .{
        .flags = .{ .reset_command_buffer = true },
        .queue_family_index = queue_families.graphics,
    };
    self.command_pool = try self.dev.createCommandPool(&pool_info, &self.vkalloc);
    errdefer self.dev.destroyCommandPool(self.command_pool, &self.vkalloc);

    // Graphics family on purpose: single-time upload command buffers from this pool are
    // submitted to the graphics queue (see core.SingleTime.endLocked in vulkan/core.zig).
    const upload_pool_info: vk.CommandPoolCreateInfo = .{
        .flags = .{ .reset_command_buffer = true, .transient = true },
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
    };
    self.transfer_semaphore = try self.dev.createSemaphore(&timeline_sem_info, &self.vkalloc);
    errdefer self.dev.destroySemaphore(self.transfer_semaphore, &self.vkalloc);

    self.graphics_timeline_semaphore = try self.dev.createSemaphore(&timeline_sem_info, &self.vkalloc);
    errdefer self.dev.destroySemaphore(self.graphics_timeline_semaphore, &self.vkalloc);

    errdefer self.destroyImageAcquiredSemaphores();
    for (&self.image_acquired_semaphores) |*semaphore| {
        semaphore.* = try self.dev.createSemaphore(&.{}, &self.vkalloc);
    }

    const cmd_alloc_info: vk.CommandBufferAllocateInfo = .{
        .command_pool = self.command_pool,
        .level = .primary,
        .command_buffer_count = max_frames_in_flight,
    };
    try self.dev.allocateCommandBuffers(&cmd_alloc_info, &self.cmd_buffers);

    return self;
}

pub fn deinit(self: *VulkanContext, io: std.Io) void {
    self.queue_mutex.lockUncancelable(io);

    self.dev.deviceWaitIdle() catch |err| {
        std.log.err("deviceWaitIdle failed during VulkanContext.deinit: {}", .{err});
    };

    self.dev.resetCommandPool(self.command_pool, .{}) catch |err| std.log.err("resetCommandPool failed during VulkanContext.deinit: {any}", .{err});
    self.dev.resetCommandPool(self.ui_command_pool, .{}) catch |err| std.log.err("resetCommandPool (ui) failed during VulkanContext.deinit: {any}", .{err});

    self.destroySwapchainImages(self.swapchain_images);
    self.allocator.free(self.swapchain_images);
    if (self.swapchain != .null_handle) self.dev.destroySwapchainKHR(self.swapchain, &self.vkalloc);

    self.dev.freeCommandBuffers(self.command_pool, &self.cmd_buffers);
    self.destroyImageAcquiredSemaphores();

    self.gpu_profiler.deinit();

    self.dev.destroyCommandPool(self.command_pool, &self.vkalloc);
    self.dev.destroyCommandPool(self.upload_command_pool, &self.vkalloc);
    self.dev.destroyCommandPool(self.ui_command_pool, &self.vkalloc);

    self.dev.destroySemaphore(self.transfer_semaphore, &self.vkalloc);
    self.dev.destroySemaphore(self.graphics_timeline_semaphore, &self.vkalloc);
    self.destroyScreenshotStaging();

    self.dev.destroyDevice(&self.vkalloc);
    self.instance.destroySurfaceKHR(self.surface, &self.vkalloc);

    if (self.debug_callback != .null_handle) self.instance.destroyDebugUtilsMessengerEXT(self.debug_callback, &self.vkalloc);
    self.instance.destroyInstance(&self.vkalloc);
    self.allocator.destroy(self.instance.wrapper);
    self.allocator.destroy(self.dev.wrapper);

    self.queue_mutex.unlock(io);
    self.allocator.destroy(self);
}

fn destroyImageAcquiredSemaphores(self: *VulkanContext) void {
    for (self.image_acquired_semaphores) |semaphore| {
        if (semaphore != .null_handle) self.dev.destroySemaphore(semaphore, &self.vkalloc);
    }
}

/// Destroys the view and the semaphore of each entry. The caller frees the slice.
fn destroySwapchainImages(self: *VulkanContext, images: []const SwapchainImage) void {
    for (images) |entry| {
        self.dev.destroyImageView(entry.view, &self.vkalloc);
        self.dev.destroySemaphore(entry.render_complete, &self.vkalloc);
    }
}

/// Creates the swapchain, or replaces it when a recreation is requested. Without a request,
/// an existing swapchain stays, so a renderer init reuses the swapchain of the menu.
pub fn createSwapchainLocked(self: *VulkanContext, io: std.Io, gamma_correction: bool, present_mode: PresentMode) !void {
    if (self.swapchain_extent.width == 0 or self.swapchain_extent.height == 0) {
        return error.InvalidWindowSize;
    }
    if (self.swapchain != .null_handle and !self.swapchain_needs_recreate) return;

    std.log.info("VulkanContext.createSwapchain: Starting swapchain creation...", .{});

    // Surface queries can block on the window system, so they run without holding either queue mutex.
    const caps = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.pdev, self.surface);

    const actual_extent = if (caps.current_extent.width != std.math.maxInt(u32))
        caps.current_extent
    else
        vk.Extent2D{
            .width = std.math.clamp(self.swapchain_extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(self.swapchain_extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
        };

    // A 0x0 surface extent means the window is minimized; keep the existing swapchain
    // instead of treating it as a failed recreate (which would spin the retry loop).
    // On first creation there is none to keep, so fall through and fail loudly.
    if (self.swapchain != .null_handle and (actual_extent.width == 0 or actual_extent.height == 0)) {
        std.log.info("Swapchain: surface reports a 0x0 extent (window minimized), keeping existing swapchain", .{});
        return;
    }

    const surface_format = try self.chooseSurfaceFormat(gamma_correction);
    const vk_present_mode = try self.choosePresentMode(present_mode);

    const min_for_mode: u32 = switch (vk_present_mode) {
        .mailbox_khr => @max(caps.min_image_count, 3),
        .immediate_khr => @max(caps.min_image_count, 2),
        else => caps.min_image_count,
    };
    const raw_count = min_for_mode + 1;
    const image_count = if (caps.max_image_count > 0) @min(raw_count, caps.max_image_count) else raw_count;

    std.log.info("Swapchain: present_mode={s}, images={d} (min={d}, max={d})", .{
        @tagName(vk_present_mode),
        image_count,
        caps.min_image_count,
        caps.max_image_count,
    });

    // Only frames and presents touch the swapchain and the graphics command pools, so
    // uploads keep running. Callers must NOT hold the queue mutex.
    self.queue_mutex.lockUncancelable(io);
    defer self.queue_mutex.unlock(io);

    self.waitSubmittedFrames() catch |err| std.log.err("waiting for frames failed during swapchain creation: {}", .{err});
    self.dev.queueWaitIdle(self.present_queue) catch |err| std.log.err("present queue wait failed during swapchain creation: {}", .{err});
    try self.dev.resetCommandPool(self.command_pool, .{});
    try self.dev.resetCommandPool(self.ui_command_pool, .{});

    const old_swapchain = self.swapchain;
    const queue_family_indices: [2]u32 = .{ self.queue_family_index, self.present_queue_family_index };
    const shared = self.queue_family_index != self.present_queue_family_index;
    const new_swapchain = try self.dev.createSwapchainKHR(&.{
        .surface = self.surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = actual_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment = true, .transfer_dst = true, .transfer_src = true },
        .image_sharing_mode = if (shared) .concurrent else .exclusive,
        .queue_family_index_count = if (shared) queue_family_indices.len else 0,
        .p_queue_family_indices = if (shared) &queue_family_indices else null,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_khr = true },
        .present_mode = vk_present_mode,
        .clipped = .true,
        .old_swapchain = old_swapchain,
    }, &self.vkalloc);
    errdefer self.dev.destroySwapchainKHR(new_swapchain, &self.vkalloc);

    // All fallible work ends here, so after a failed recreation deinit still owns every handle in self.
    const new_images = try self.createSwapchainImages(new_swapchain, surface_format.format);

    self.destroySwapchainImages(self.swapchain_images);
    self.allocator.free(self.swapchain_images);
    if (old_swapchain != .null_handle) self.dev.destroySwapchainKHR(old_swapchain, &self.vkalloc);
    self.swapchain = new_swapchain;
    self.swapchain_images = new_images;
    self.swapchain_extent = actual_extent;
    self.swapchain_format = surface_format.format;
    self.swapchain_needs_recreate = false;
}

/// Returns the first preferred format that the surface supports, else the first surface format.
fn chooseSurfaceFormat(self: *VulkanContext, gamma_correction: bool) !vk.SurfaceFormatKHR {
    const surface_formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.pdev, self.surface, self.allocator);
    defer self.allocator.free(surface_formats);

    const preferred_formats: [2]vk.Format = if (gamma_correction)
        .{ .b8g8r8a8_srgb, .r8g8b8a8_srgb }
    else
        .{ .b8g8r8a8_unorm, .r8g8b8a8_unorm };
    for (preferred_formats) |preferred| {
        for (surface_formats) |surface_format| {
            if (surface_format.format == preferred) return surface_format;
        }
    }
    return surface_formats[0];
}

/// Returns the Vulkan mode for `present_mode`, or FIFO when the surface does not support it.
fn choosePresentMode(self: *VulkanContext, present_mode: PresentMode) !vk.PresentModeKHR {
    const present_modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(self.pdev, self.surface, self.allocator);
    defer self.allocator.free(present_modes);

    const requested_mode: vk.PresentModeKHR = switch (present_mode) {
        .vsync => .fifo_khr,
        .mailbox => .mailbox_khr,
        .immediate => .immediate_khr,
    };
    if (std.mem.findScalar(vk.PresentModeKHR, present_modes, requested_mode) != null) return requested_mode;
    // FIFO is the only mode every surface must support.
    std.log.warn("Present mode '{s}' not available, using fallback 'fifo_khr' instead", .{@tagName(requested_mode)});
    return .fifo_khr;
}

/// Creates a view and a render-complete semaphore for each image of `swapchain`.
fn createSwapchainImages(self: *VulkanContext, swapchain: vk.SwapchainKHR, format: vk.Format) ![]SwapchainImage {
    const images = try self.dev.getSwapchainImagesAllocKHR(swapchain, self.allocator);
    defer self.allocator.free(images);
    const entries = try self.allocator.alloc(SwapchainImage, images.len);
    var created: usize = 0;
    errdefer {
        self.destroySwapchainImages(entries[0..created]);
        self.allocator.free(entries);
    }
    for (images, entries) |image, *entry| {
        const view = try self.dev.createImageView(&core.imageViewCreateInfo(image, format, .{ .color = true }), &self.vkalloc);
        errdefer self.dev.destroyImageView(view, &self.vkalloc);
        entry.* = .{ .image = image, .view = view, .layout = .undefined, .render_complete = try self.dev.createSemaphore(&.{}, &self.vkalloc) };
        created += 1;
    }
    return entries;
}

pub fn transitionImageLayout(dev: vk.DeviceProxy, cmd: vk.CommandBuffer, image: vk.Image, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) void {
    const src_stage: vk.PipelineStageFlags2 = switch (old_layout) {
        .undefined => .{ .top_of_pipe = true },
        .present_src_khr, .color_attachment_optimal => .{ .color_attachment_output = true },
        else => .{ .all_commands = true },
    };
    const src_access: vk.AccessFlags2 = switch (old_layout) {
        .undefined, .present_src_khr => .{},
        .color_attachment_optimal => .{ .color_attachment_write = true },
        else => .{ .memory_read = true, .memory_write = true },
    };
    const barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        // present_src_khr uses bottom_of_pipe with an empty access mask on purpose: the present
        // engine's reads are ordered by the render-complete semaphore, not by barrier access.
        .dst_stage_mask = if (new_layout == .color_attachment_optimal) .{ .color_attachment_output = true } else .{ .bottom_of_pipe = true },
        .dst_access_mask = if (new_layout == .color_attachment_optimal) .{ .color_attachment_write = true, .color_attachment_read = true } else .{},
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .{ .color = true },
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

/// Waits until every submitted frame finishes on the GPU. Unlike deviceWaitIdle it
/// takes no queue lock and does not wait out the transfer queue's upload backlog.
pub fn waitSubmittedFrames(self: *VulkanContext) !void {
    return self.waitFrame(self.frame_number.load(.acquire));
}

/// Waits until the GPU finishes frame `frame_number`. Frame 0 is the initial timeline value, so it never blocks.
fn waitFrame(self: *VulkanContext, frame_number: u64) !void {
    const wait_info: vk.SemaphoreWaitInfo = .{
        .semaphore_count = 1,
        .p_semaphores = (&self.graphics_timeline_semaphore)[0..1],
        .p_values = (&frame_number)[0..1],
    };
    if (try self.dev.waitSemaphores(&wait_info, std.math.maxInt(u64)) != .success) return error.WaitFailed;
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

/// Requests a swapchain recreation before the next frame and resets the suboptimal guard.
pub fn requestSwapchainRecreate(self: *VulkanContext) void {
    self.suboptimal_recreate_requested = false;
    self.swapchain_needs_recreate = true;
}

/// Sets the swapchain extent to the window size and requests a recreation.
pub fn setExtentFromWindow(self: *VulkanContext, size: wio.Size) void {
    // xdg-shell reports a 0x0 content size while the window is minimized; keep the last
    // valid extent so rendering keeps working until the window is shown again.
    if (size.width == 0 or size.height == 0) return;
    self.swapchain_extent = .{ .width = @intCast(size.width), .height = @intCast(size.height) };
    self.requestSwapchainRecreate();
}

/// The frame slot, the acquired swapchain image, and the command buffer of one frame.
pub const FrameContext = struct {
    frame_index: u32,
    image_index: u32,
    cmd_buffer: vk.CommandBuffer,
};

/// Waits until the frame slot is free, then acquires the next swapchain image.
pub fn beginFrame(self: *VulkanContext) !FrameContext {
    const frame_number = self.frame_number.load(.acquire);
    const current_frame: u32 = @intCast(frame_number % max_frames_in_flight);
    if (frame_number >= max_frames_in_flight) {
        self.waitFrame(frame_number - max_frames_in_flight + 1) catch return error.DrawFailed;
    }
    self.gpu_profiler.prepareFrame(current_frame);

    const acquired = acquire: {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "acquireNextImage" });
        defer zone.end();
        break :acquire self.dev.acquireNextImageKHR(
            self.swapchain,
            std.math.maxInt(u64),
            self.image_acquired_semaphores[current_frame],
            .null_handle,
        ) catch |err| try self.swapchainError(err);
    };
    self.noteSuboptimal(acquired.result);
    return .{
        .frame_index = current_frame,
        .image_index = acquired.image_index,
        .cmd_buffer = self.cmd_buffers[current_frame],
    };
}

/// Maps acquire/present failures to the frame loop's errors, flagging recreation when the swapchain is out of date.
fn swapchainError(self: *VulkanContext, err: anytype) !noreturn {
    switch (err) {
        error.OutOfDateKHR => {
            self.swapchain_needs_recreate = true;
            return error.OutOfDate;
        },
        error.SurfaceLostKHR => return error.SurfaceLost,
        else => |other| return other,
    }
}

/// Requests one recreation on the first suboptimal result; some platforms keep reporting it after a valid recreation.
fn noteSuboptimal(self: *VulkanContext, result: vk.Result) void {
    if (result != .suboptimal_khr or self.suboptimal_recreate_requested) return;
    self.suboptimal_recreate_requested = true;
    self.swapchain_needs_recreate = true;
}

pub fn submitFrameWithExtra(self: *VulkanContext, io: std.Io, ctx: FrameContext, prepass_cmd_buffer: ?vk.CommandBuffer, ui_cmd_buffer: ?vk.CommandBuffer, include_game: bool) !void {
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
        .{ .semaphore = self.image_acquired_semaphores[ctx.frame_index], .value = 0, .stage_mask = .{ .all_commands = true }, .device_index = 0 },
        .{ .semaphore = self.transfer_semaphore, .value = current_transfer_val, .stage_mask = .{ .vertex_attribute_input = true }, .device_index = 0 },
        .{ .semaphore = self.graphics_timeline_semaphore, .value = prev_graphics_val, .stage_mask = .{ .top_of_pipe = true }, .device_index = 0 },
    };

    const signal_semaphore_infos: [2]vk.SemaphoreSubmitInfo = .{
        .{ .semaphore = self.swapchain_images[ctx.image_index].render_complete, .value = 0, .stage_mask = .{ .bottom_of_pipe = true }, .device_index = 0 },
        .{ .semaphore = self.graphics_timeline_semaphore, .value = current_graphics_val, .stage_mask = .{ .all_commands = true }, .device_index = 0 },
    };

    const submitted: [3]?vk.CommandBuffer = .{ if (include_game) ctx.cmd_buffer else null, prepass_cmd_buffer, ui_cmd_buffer };
    var cmd_buffer_infos: [submitted.len]vk.CommandBufferSubmitInfo = undefined;
    var cmd_buffer_count: u32 = 0;
    for (submitted) |maybe_cmd_buffer| if (maybe_cmd_buffer) |cmd_buffer| {
        cmd_buffer_infos[cmd_buffer_count] = .{ .command_buffer = cmd_buffer, .device_mask = 0 };
        cmd_buffer_count += 1;
    };

    const submit_info: vk.SubmitInfo2 = .{
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
        .p_wait_semaphores = (&self.swapchain_images[ctx.image_index].render_complete)[0..1],
        .swapchain_count = 1,
        .p_swapchains = (&self.swapchain)[0..1],
        .p_image_indices = (&ctx.image_index)[0..1],
    };
    const present_result = blk: {
        const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "present_lock_queue" });
        self.queue_mutex.lockUncancelable(io);
        zone_lock.end();
        defer self.queue_mutex.unlock(io);

        const zone_present = tracy.Zone.begin(.{ .src = @src(), .name = "queuePresent" });
        defer zone_present.end();
        break :blk self.dev.queuePresentKHR(self.present_queue, &present_info) catch |err| try self.swapchainError(err);
    };
    self.noteSuboptimal(present_result);
}

const vklog = std.log.scoped(.vulkan);

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    _: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    const cb_data = p_callback_data orelse return .false;
    const msg = std.mem.span(cb_data.p_message orelse return .false);

    if (message_severity.error_ext) {
        vklog.err("Id: {d}, {s}", .{ cb_data.message_id_number, msg });
    } else if (message_severity.warning_ext) {
        vklog.warn("Id: {d}, {s}", .{ cb_data.message_id_number, msg });
    } else if (message_severity.info_ext) {
        vklog.info("Id: {d}, {s}", .{ cb_data.message_id_number, msg });
    } else if (message_severity.verbose_ext) {
        vklog.debug("Id: {d}, {s}", .{ cb_data.message_id_number, msg });
    }

    return .false;
}

/// Requests a screenshot of the next frame at `resolution`.
pub fn requestScreenshot(self: *VulkanContext, resolution: ScreenshotResolution) void {
    self.screenshot_request = resolution;
}

/// Returns a staging buffer of at least `size` bytes.
fn ensureScreenshotStaging(self: *VulkanContext, size: vk.DeviceSize) !vk.Buffer {
    if (self.screenshot_staging) |staging| if (staging.size >= size) return staging.buffer;
    self.destroyScreenshotStaging();
    const buffer = try self.dev.createBuffer(&.{ .size = size, .usage = .{ .transfer_dst = true }, .sharing_mode = .exclusive }, &self.vkalloc);
    errdefer self.dev.destroyBuffer(buffer, &self.vkalloc);
    const reqs = self.dev.getBufferMemoryRequirements(buffer);
    const mem_type = try core.findMemoryType(self.mem_props, reqs.memory_type_bits, .{ .host_visible = true, .host_coherent = true });
    const memory = try self.dev.allocateMemory(&.{ .allocation_size = reqs.size, .memory_type_index = mem_type }, &self.vkalloc);
    errdefer self.dev.freeMemory(memory, &self.vkalloc);
    try self.dev.bindBufferMemory(buffer, memory, 0);
    const mapped: [*]u8 = @ptrCast(try self.dev.mapMemory(memory, 0, reqs.size, .{}));
    self.screenshot_staging = .{ .buffer = buffer, .memory = memory, .mapped = mapped, .size = reqs.size };
    return buffer;
}

fn destroyScreenshotStaging(self: *VulkanContext) void {
    const staging = self.screenshot_staging orelse return;
    self.dev.unmapMemory(staging.memory);
    self.dev.destroyBuffer(staging.buffer, &self.vkalloc);
    self.dev.freeMemory(staging.memory, &self.vkalloc);
    self.screenshot_staging = null;
}

/// Records the requested screenshot copy of `image`, which also moves `image` to present layout.
/// Returns false and records nothing when no screenshot is requested.
pub fn recordRequestedScreenshot(self: *VulkanContext, cmd: vk.CommandBuffer, image: vk.Image, extent: vk.Extent2D) !bool {
    const resolution = self.screenshot_request orelse return false;
    self.screenshot_request = null;
    const buffer = try self.ensureScreenshotStaging(@as(vk.DeviceSize, extent.width) * extent.height * 4);
    const to_transfer = core.makeImageBarrier2(image, .color_attachment_optimal, .transfer_src_optimal, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }, .{ .copy = true }, .{ .transfer_read = true }, .{ .color = true });
    core.pipelineBarrier(cmd, self.dev, vk.ImageMemoryBarrier2, (&to_transfer)[0..1]);
    const region: vk.BufferImageCopy = .{ .buffer_offset = 0, .buffer_row_length = 0, .buffer_image_height = 0, .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 }, .image_offset = .{ .x = 0, .y = 0, .z = 0 }, .image_extent = .{ .width = extent.width, .height = extent.height, .depth = 1 } };
    self.dev.cmdCopyImageToBuffer(cmd, image, .transfer_src_optimal, buffer, (&region)[0..1]);
    const to_present = core.makeImageBarrier2(image, .transfer_src_optimal, .present_src_khr, .{ .copy = true }, .{ .transfer_read = true }, .{ .bottom_of_pipe = true }, .{}, .{ .color = true });
    core.pipelineBarrier(cmd, self.dev, vk.ImageMemoryBarrier2, (&to_present)[0..1]);
    self.pending_screenshot = .{ .extent = extent, .resolution = resolution };
    return true;
}

/// Waits for the submitted copy, then saves the pending screenshot as a PNG.
/// Returns false when no screenshot is pending. A failed save discards the screenshot.
pub fn savePendingScreenshot(self: *VulkanContext, io: std.Io, allocator: std.mem.Allocator) !bool {
    const pending = self.pending_screenshot orelse return false;
    self.pending_screenshot = null;
    // A failed wait leaves the staging contents undefined, so the save does not run.
    try self.waitSubmittedFrames();

    const native = pending.extent;
    const target = pending.resolution.targetExtent(native);
    try std.Io.Dir.cwd().createDirPath(io, "screenshots");
    // In-place BGRA->RGBA swizzle for the BGRA swapchain formats only: the r8g8b8a8
    // fallback already stores the bytes in the order zignal writes out.
    const src_bytes = self.screenshot_staging.?.mapped[0 .. @as(usize, native.width) * native.height * 4];
    if (self.swapchain_format == .b8g8r8a8_srgb or self.swapchain_format == .b8g8r8a8_unorm) {
        for (std.mem.bytesAsSlice([4]u8, src_bytes)) |*pixel| std.mem.swap(u8, &pixel[0], &pixel[2]);
    }
    const Image = zignal.Image(zignal.Rgba(u8));
    const src_img: Image = .initFromBytes(native.height, native.width, src_bytes);

    var path_buf: [256]u8 = undefined;
    const ts = std.Io.Timestamp.now(io, .real).toSeconds();
    const path = try std.mem.print(&path_buf, "screenshots/screenshot_{d}_{d}x{d}.png", .{ ts, target.width, target.height });
    if (std.meta.eql(target, native)) {
        try src_img.save(io, allocator, path);
    } else {
        const dst_bytes = try allocator.alloc(u8, @as(usize, target.width) * target.height * 4);
        defer allocator.free(dst_bytes);
        const dst_img: Image = .initFromBytes(target.height, target.width, dst_bytes);
        src_img.resize(io, allocator, dst_img, .bilinear);
        try dst_img.save(io, allocator, path);
    }
    std.log.info("Screenshot saved: {s}", .{path});
    return true;
}

/// Vulkan host allocation callbacks backed by a Zig allocator. A header before each block records its layout.
const host_allocation = struct {
    const Header = struct {
        size: usize,
        padding: usize,
        align_bytes: usize,
    };

    /// Returns callbacks that allocate from `allocator`, which must outlive every Vulkan object.
    fn callbacks(allocator: *std.mem.Allocator) vk.AllocationCallbacks {
        return .{
            .p_user_data = allocator,
            .pfn_allocation = allocate,
            .pfn_reallocation = reallocate,
            .pfn_free = free,
        };
    }

    fn header(memory: [*]u8) *Header {
        return @ptrCast(@alignCast(memory - @sizeOf(Header)));
    }

    fn allocate(p_user_data: ?*anyopaque, size: usize, alignment: usize, _: vk.SystemAllocationScope) callconv(.c) ?*anyopaque {
        if (size == 0) return null;
        const allocator: *std.mem.Allocator = @ptrCast(@alignCast(p_user_data orelse return null));
        const align_bytes = @max(alignment, @alignOf(usize));
        const padding = std.mem.alignForward(usize, @sizeOf(Header), align_bytes);
        const raw = allocator.rawAlloc(size + padding, .fromByteUnits(align_bytes), @returnAddress()) orelse return null;
        const memory = raw + padding;
        header(memory).* = .{ .size = size + padding, .padding = padding, .align_bytes = align_bytes };
        return memory;
    }

    fn reallocate(
        p_user_data: ?*anyopaque,
        p_original: ?*anyopaque,
        size: usize,
        alignment: usize,
        allocation_scope: vk.SystemAllocationScope,
    ) callconv(.c) ?*anyopaque {
        const original: [*]u8 = @ptrCast(p_original orelse return allocate(p_user_data, size, alignment, allocation_scope));
        if (size == 0) {
            free(p_user_data, original);
            return null;
        }
        const new_memory: [*]u8 = @ptrCast(allocate(p_user_data, size, alignment, allocation_scope) orelse return null);
        const old_header = header(original);
        const copy_size = @min(size, old_header.size - old_header.padding);
        @memcpy(new_memory[0..copy_size], original[0..copy_size]);
        free(p_user_data, original);
        return new_memory;
    }

    fn free(p_user_data: ?*anyopaque, p_memory: ?*anyopaque) callconv(.c) void {
        const memory: [*]u8 = @ptrCast(p_memory orelse return);
        const allocator: *std.mem.Allocator = @ptrCast(@alignCast(p_user_data orelse return));
        const block = header(memory);
        allocator.rawFree((memory - block.padding)[0..block.size], .fromByteUnits(block.align_bytes), @returnAddress());
    }
};

test {
    std.testing.refAllDecls(@This());
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
    try ctx.createSwapchainLocked(std.testing.io, false, .mailbox);

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
