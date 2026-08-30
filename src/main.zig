const std = @import("std");

const dvui = @import("dvui");
const dvui_vulkan_renderer = @import("dvui_vulkan_renderer");
const options = @import("options");
pub const tracy = @import("tracy");
pub const tracy_impl = @import("tracy_impl");
const vk = @import("vulkan");
const wio = @import("wio");

pub const Entity = @import("entity/Entity.zig");
const EntityTypes = @import("entity/EntityTypes.zig");
const Game = @import("Game.zig");
const Key = @import("Key.zig");
pub const Cache = @import("libs/Cache.zig").Cache;
pub const ConcurrentHashMap = @import("libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const utils = @import("libs/utils.zig");
const Renderer = @import("Renderer.zig");
const Ui = @import("Ui.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
pub const Block = @import("world/Block.zig").Block;
pub const Chunk = @import("world/Chunk.zig");
pub const ChunkSize = Chunk.ChunkSize;
pub const generator_loader = @import("world/generator_loader.zig");
pub const World = @import("world/World.zig");

pub const tracy_options: tracy.Options = .{
    .on_demand = true,
    .verbose = false,
};

pub fn main(init: std.process.Init) !void {
    var running: std.atomic.Value(bool) = .init(true);
    const gpa = init.gpa;
    const io = init.io;

    const config_path: []const u8 = "Config.zon";
    const worlds_path: []const u8 = "worlds";

    var config_lock: std.Io.RwLock = .init;
    var config: Config = try .load(gpa, io, config_path);
    defer config.deinit(gpa);
    try config.save(io, config_path, &config_lock);

    try writeEmbeddedGenerators(io);
    var generators = try generator_loader.Registry.init(gpa, io, "generators");
    defer generators.deinit(io);

    try wio.init(.{ .allocator = gpa, .io = io, .eventFn = wio.EventQueue.eventFn });
    defer wio.deinit();

    var events: wio.EventQueue = .empty;
    defer events.deinit();

    var window = try wio.Window.create(.{ .title = "terrafinity", .event_fn_data = &events });
    defer window.destroy();
    window.setMode(.maximized);

    pollInitialSize(&events, &window_size);
    var vk_ctx = try VulkanContext.init(gpa, &window);
    defer vk_ctx.deinit(io);

    vk_ctx.swapchain_extent = .{ .width = @as(u32, @intCast(window_size.width)), .height = @as(u32, @intCast(window_size.height)) };
    vk_ctx.present_mode = config.game_config.render_options.present_mode;
    try vk_ctx.createSwapchainLocked(io, false);

    var backend = try dvui.backend.init(.{ .io = io, .window = window, .size = window_size, .framebuffer = window_size });
    defer backend.deinit();

    const vk_memory = dvui_vulkan_renderer.VkMemory.init(
        vk_ctx.mem_props,
        vk_ctx.props.limits.non_coherent_atom_size,
    ) orelse return error.NoSuitableMemory;
    try backend.initVulkan(
        vk_ctx.dev,
        vk_memory,
        gpa,
        VulkanContext.max_frames_in_flight,
        vk_ctx.swapchain_format,
        vk_ctx.queue_family_index,
    );

    const dvui_backend = dvui.Backend.init(&backend);
    var ui_window = try dvui.Window.init(@src(), gpa, dvui_backend, .{});
    defer ui_window.deinit();

    var keymap = Key.Map.init(gpa);
    defer keymap.map.deinit();

    var single_press = Key.Singlepress.empty;
    try keymap.setActionKey(io, .{ .key = .escape }, .escape_menu);
    try keymap.setActionKey(io, .{ .key = .left_gui }, .escape_menu);
    try keymap.setActionKey(io, .{ .key = .f11 }, .fullscreen);
    try keymap.setActionKey(io, .{ .key = .f2 }, .screenshot);
    try keymap.setActionKey(io, .{ .key = .f3 }, .debug_menu);
    single_press.insert(.escape_menu);
    single_press.insert(.fullscreen);
    single_press.insert(.spawn_explosive);
    single_press.insert(.screenshot);
    single_press.insert(.debug_menu);

    inline for (.{
        .{ .key = .w, .action = .forward },
        .{ .key = .s, .action = .backward },
        .{ .key = .a, .action = .left },
        .{ .key = .d, .action = .right },
        .{ .key = .space, .action = .up },
        .{ .key = .left_shift, .action = .down },
        .{ .key = .mouse_left, .action = .use_item_primary },
        .{ .key = .mouse_right, .action = .use_item_secondary },
        .{ .key = .f, .action = .use_item_tertiary },
        .{ .key = .t, .action = .spawn_explosive },
    }) |bind| {
        try keymap.setActionKey(io, .{ .key = bind.key }, bind.action);
    }

    var game: Game = undefined;
    if (options.test_play != null) {
        const test_play_folder = try std.fs.path.join(gpa, &.{ worlds_path, "test_play" });
        defer gpa.free(test_play_folder);
        vk_ctx.swapchain_gamma.store(config.game_config.render_options.gamma_correction, .monotonic);
        try game.init(io, gpa, &config.game_config, &config_lock, test_play_folder, vk_ctx, &generators);
    }
    var ui: Ui = .{
        .window = &window,
        .vk_ctx = vk_ctx,
        .config = &config,
        .config_lock = &config_lock,
        .game = &game,
        .generators = &generators,
        .menu_state = if (options.test_play != null) .{ .ingame = true } else .{ .main = true },
        .config_path = config_path,
        .worlds_path = worlds_path,
        .running = &running,
        .config_section_states = .init(gpa),
        .ui_window = &ui_window,
        .menu_background = undefined,
    };
    try ui.initAssets(gpa);
    defer ui.deinit(gpa);
    defer if (ui.menu_state.ingame) game.deinit(io);

    const start_time: std.Io.Timestamp = .now(io, .awake);
    var frame_time: std.Io.Timestamp = start_time;
    var action_set = Key.ActionSet.empty;
    var prev_window_size = window_size;
    var current_window_mode: wio.WindowMode = .maximized;
    var pre_fullscreen_window_mode: wio.WindowMode = .maximized;
    var swapchain_recreate_failures: u32 = 0;

    var ui_cmd_buffers: [VulkanContext.max_frames_in_flight]vk.CommandBuffer = undefined;
    try vk_ctx.dev.allocateCommandBuffers(&.{
        .command_pool = vk_ctx.ui_command_pool,
        .level = .primary,
        .command_buffer_count = VulkanContext.max_frames_in_flight,
    }, &ui_cmd_buffers);
    defer {
        vk_ctx.deviceWaitIdleLocked(io) catch {};
        vk_ctx.dev.freeCommandBuffers(vk_ctx.ui_command_pool, &ui_cmd_buffers);
    }

    // Screenshot auto handling
    var screenshot_after_triggered: bool = false;
    var screenshot_after_should_exit: bool = false;
    var screenshot_after_saved: bool = false;

    while (running.load(.unordered)) {
        wio.update();
        try handleEvents(io, &keymap, single_press, &action_set, &running, &backend, &window, &events, &ui_window, &ui, vk_ctx);
        if (action_set.contains(.escape_menu)) ui.menu_state.handle_esc();
        if (action_set.contains(.fullscreen)) {
            if (current_window_mode == .fullscreen) {
                window.setMode(pre_fullscreen_window_mode);
                current_window_mode = pre_fullscreen_window_mode;
            } else {
                pre_fullscreen_window_mode = current_window_mode;
                current_window_mode = .fullscreen;
                window.setMode(current_window_mode);
            }
            vk_ctx.requestSwapchainRecreate();
        }
        if (action_set.contains(.screenshot)) {
            const res = config.game_config.render_options.screenshot_resolution;
            vk_ctx.requestScreenshot(res);
            std.log.info("Screenshot requested via F2 with resolution {s}", .{res.label()});
        }
        if (action_set.contains(.debug_menu)) {
            ui.menu_state.debug_info = !ui.menu_state.debug_info;
            std.log.info("Debug menu toggled via F3: {any}", .{ui.menu_state.debug_info});
        }
        frame_time = .now(io, .awake);

        if (!std.meta.eql(prev_window_size, window_size)) {
            vk_ctx.swapchain_extent = .{ .width = @as(u32, @intCast(window_size.width)), .height = @as(u32, @intCast(window_size.height)) };
            vk_ctx.requestSwapchainRecreate();
            prev_window_size = window_size;
        }

        if (options.test_play) |timeout| {
            if (start_time.untilNow(io, .awake).toSeconds() >= timeout) {
                std.log.info("Test play timeout reached", .{});
                running.store(false, .unordered);
                break;
            }
        }

        // Auto screenshot after N seconds (similar to test_play)
        if (options.screenshot_after) |screenshot_timeout| {
            if (!screenshot_after_triggered and start_time.untilNow(io, .awake).toSeconds() >= screenshot_timeout) {
                std.log.info("Screenshot after timeout reached ({d}s), requesting screenshot", .{screenshot_timeout});
                // Use current resolution setting
                const res = config.game_config.render_options.screenshot_resolution;
                vk_ctx.requestScreenshot(res);
                screenshot_after_triggered = true;
                // If test_play is not set, we will exit after screenshot is saved
                if (options.test_play == null) {
                    screenshot_after_should_exit = true;
                }
            }
        }

        if (vk_ctx.swapchain_needs_recreate.load(.monotonic)) {
            try recreateSwapchainOrFail(io, vk_ctx, &ui, &game, config.game_config.render_options.present_mode, config.game_config.render_options.gamma_correction, &swapchain_recreate_failures);
            continue;
        }

        const frame_ctx = vk_ctx.beginFrame() catch |err| switch (err) {
            error.OutOfDate => {
                try recreateSwapchainOrFail(io, vk_ctx, &ui, &game, config.game_config.render_options.present_mode, config.game_config.render_options.gamma_correction, &swapchain_recreate_failures);
                continue;
            },
            error.SurfaceLost => {
                std.log.err("Vulkan surface lost; windowing-layer surface recreation is not implemented", .{});
                return err;
            },
            error.DrawFailed => {
                std.log.err("beginFrame failed: draw error", .{});
                continue;
            },
            else => return err,
        };

        const was_ingame = ui.menu_state.ingame;
        if (was_ingame) {
            try game.frame(io, gpa, .{
                .frame_index = frame_ctx.frame_index,
                .cmd_buffer = frame_ctx.cmd_buffer,
                .output_image = vk_ctx.swapchain_images[frame_ctx.image_index],
                .output_view = vk_ctx.swapchain_views[frame_ctx.image_index],
                .swapchain_image_layout = &vk_ctx.swapchain_image_layouts[frame_ctx.image_index],
            }, .{ vk_ctx.swapchain_extent.width, vk_ctx.swapchain_extent.height });
        }

        try ui.recordCommandBuffer(io, gpa, &backend, ui_cmd_buffers[frame_ctx.frame_index], frame_ctx, frame_time);

        const prepass_cmd = backend.takePrepass();
        try vk_ctx.submitFrameWithExtra(io, frame_ctx, prepass_cmd, ui_cmd_buffers[frame_ctx.frame_index], was_ingame);

        vk_ctx.present(io, frame_ctx) catch |err| switch (err) {
            error.OutOfDate => vk_ctx.swapchain_needs_recreate.store(true, .monotonic),
            error.SurfaceLost => {
                std.log.err("Vulkan surface lost during present; windowing-layer surface recreation is not implemented", .{});
                return err;
            },
            else => std.log.err("present failed: {}", .{err}),
        };

        // Handle screenshot saving after GPU work completes
        if (vk_ctx.screenshot_pending_save) {
            // Wait for the frame to finish (timeline semaphore)
            const current_frame_val = vk_ctx.frame_number.load(.acquire);
            const wait_info: vk.SemaphoreWaitInfo = .{
                .semaphore_count = 1,
                .p_semaphores = (&vk_ctx.graphics_timeline_semaphore)[0..1],
                .p_values = (&current_frame_val)[0..1],
            };
            _ = vk_ctx.dev.waitSemaphores(&wait_info, std.math.maxInt(u64)) catch |err| {
                std.log.err("Failed to wait for screenshot frame: {any}", .{err});
            };

            // Save screenshot
            if (vk_ctx.savePendingScreenshot(io, gpa)) |saved_path| {
                defer gpa.free(saved_path);
                std.log.info("Screenshot saved: {s}", .{saved_path});
                if (screenshot_after_should_exit and !screenshot_after_saved) {
                    screenshot_after_saved = true;
                    std.log.info("Auto screenshot completed, exiting", .{});
                    running.store(false, .unordered);
                    break;
                }
            } else |err| {
                std.log.err("Failed to save screenshot: {any}", .{err});
                vk_ctx.screenshot_pending_save = false;
            }
        }

        if (ui.menu_state.pending_game_deinit) {
            ui.menu_state.pending_game_deinit = false;
            vk_ctx.deviceWaitIdleLocked(io) catch {};
            game.deinit(io);
            vk_ctx.swapchain_needs_recreate.store(true, .monotonic);
        }

        if (ui.menu_state.pending_world_recreate) {
            ui.menu_state.pending_world_recreate = false;
            if (vk_ctx.deviceWaitIdleLocked(io)) |_| {
                game.recreateWorld(io, gpa, vk_ctx, &generators) catch |err| {
                    std.log.err("terrain world recreation failed: {any}", .{err});
                    ui.terrain_recreate_error = @errorName(err);
                    const game_closed = switch (err) {
                        error.RecreatePathAllocationFailed,
                        error.RecreateConfigSaveFailed,
                        error.RecreateChunkSaveFailed,
                        error.RecreateStorageClearFailed,
                        => false,
                        else => true,
                    };
                    if (game_closed) ui.menu_state = .{ .main = true };
                };
            } else |err| {
                std.log.err("could not wait for the GPU before terrain recreation: {any}", .{err});
                ui.terrain_recreate_error = @errorName(err);
            }
        }

        tracy.frameMark(null);
    }
    window.disableRelativeMouse();
    vk_ctx.deviceWaitIdleLocked(io) catch {};
}

test {
    std.testing.refAllDecls(@This());
}

pub const Config = struct {
    game_config: Game.Options = .{},

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
        const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .lock = .shared }) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.info("Config file not found, creating default", .{});
                var default_config: Config = .{};
                default_config.game_config.render_options.selected_pack = try allocator.dupe(u8, "default");
                return default_config;
            },
            else => return err,
        };
        defer file.close(io);
        return try utils.loadZon(Config, io, file, allocator, allocator);
    }

    pub fn save(self: *const Config, io: std.Io, path: []const u8, config_lock: ?*std.Io.RwLock) !void {
        const config_file = try std.Io.Dir.cwd().createFile(io, path, .{ .lock = .exclusive });
        defer config_file.close(io);
        var buffer: [512]u8 = undefined;
        var file_writer = config_file.writer(io, &buffer);
        {
            if (config_lock) |lock| lock.lockSharedUncancelable(io);
            defer if (config_lock) |lock| lock.unlockShared(io);
            try std.zon.stringify.serialize(self, .{}, &file_writer.interface);
        }
        try file_writer.end();
    }

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        allocator.free(self.game_config.render_options.selected_pack);
    }

    pub const structui_options: dvui.struct_ui.StructOptions(@This()) = .initWithDefaults(.{}, null);
};

var window_size: wio.Size = .{ .height = 480, .width = 640 };
var window_logical_size: wio.Size = .{ .height = 480, .width = 640 };
var window_scale: f32 = 1.0;

const embedded_generators = [_]struct { file_name: []const u8, bytes: []const u8 }{
    .{ .file_name = "terrain.generator", .bytes = @embedFile("terrain_generator_bin") },
    .{ .file_name = "voxelgame.generator", .bytes = @embedFile("voxelgame_generator_bin") },
    .{ .file_name = "planet.generator", .bytes = @embedFile("planet_generator_bin") },
};

fn writeEmbeddedGenerators(io: std.Io) !void {
    var generators_dir = std.Io.Dir.cwd().createDirPathOpen(io, "generators", .{}) catch |err| switch (err) {
        error.PathAlreadyExists => try std.Io.Dir.cwd().openDir(io, "generators", .{}),
        else => return err,
    };
    defer generators_dir.close(io);

    for (embedded_generators) |embedded| {
        const file = try generators_dir.createFile(io, embedded.file_name, .{ .lock = .exclusive });
        defer file.close(io);
        var buffer: [512]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll(embedded.bytes);
        try writer.end();
    }
}

fn pollInitialSize(events: *wio.EventQueue, size: *wio.Size) void {
    for (0..100) |_| {
        wio.update();
        while (events.pop()) |event| {
            if (event == .size_physical) {
                size.* = event.size_physical;
                return;
            }
        }
    }
}

const max_swapchain_recreate_failures: u32 = 120;

fn recreateSwapchainOrFail(
    io: std.Io,
    vk_ctx: *VulkanContext,
    ui: *Ui,
    game: *Game,
    present_mode: VulkanContext.PresentMode,
    gamma_correction: bool,
    consecutive_failures: *u32,
) !void {
    recreateSwapchainForMenuOrGame(io, vk_ctx, ui, game, present_mode, gamma_correction) catch |err| {
        consecutive_failures.* += 1;
        if (consecutive_failures.* >= max_swapchain_recreate_failures) {
            std.log.err("swapchain recreation failed {d} consecutive times; last error: {}", .{ consecutive_failures.*, err });
            return err;
        }
        std.log.warn("swapchain recreation failed (attempt {d} of {d}): {}", .{ consecutive_failures.*, max_swapchain_recreate_failures, err });
        return;
    };
    consecutive_failures.* = 0;
}

fn recreateSwapchainForMenuOrGame(io: std.Io, vk_ctx: *VulkanContext, ui: *Ui, game: *Game, present_mode: VulkanContext.PresentMode, gamma_correction: bool) !void {
    vk_ctx.dev.queueWaitIdle(vk_ctx.graphics_queue) catch |err| {
        std.log.err("queueWaitIdle failed during swapchain recreate: {}", .{err});
        return err;
    };

    vk_ctx.present_mode = present_mode;
    if (ui.menu_state.ingame) {
        try game.renderer.recreateSwapchain(io);
    } else {
        try vk_ctx.createSwapchainLocked(io, gamma_correction);
    }
    vk_ctx.swapchain_needs_recreate.store(false, .monotonic);
}

fn handleEvents(
    io: std.Io,
    key_map: *Key.Map,
    single_press: Key.Singlepress,
    action_set: *Key.ActionSet,
    running: *std.atomic.Value(bool),
    backend: *dvui.backend,
    win: *wio.Window,
    events: *wio.EventQueue,
    ui_window: *dvui.Window,
    ui: *Ui,
    vk_ctx: *VulkanContext,
) !void {
    backend.setTextInputRect(ui_window.textInputRequested());
    if (ui.menu_state.is_playing_game()) {
        win.enableRelativeMouse(.{ .unaccelerated = true });
    } else {
        win.disableRelativeMouse();
        backend.setCursor(ui_window.cursorRequested());
    }

    var it = action_set.iterator();
    while (it.next()) |action| {
        if (single_press.contains(action)) action_set.remove(action);
    }

    while (events.pop()) |event| {
        _ = try backend.addEvent(ui_window, event);
        switch (event) {
            .button_press => |key| if (key_map.getAction(io, .{ .key = key })) |action| {
                action_set.insert(action);
            },
            .button_release => |key| if (key_map.getAction(io, .{ .key = key })) |action| {
                action_set.remove(action);
            },
            .close => running.store(false, .unordered),
            .scroll_vertical => |scroll| if (ui.menu_state.is_playing_game()) {
                try ui.game.handleScroll(io, scroll);
            },
            .mouse_relative => |mouse| if (ui.menu_state.is_playing_game() and (mouse.x != 0 or mouse.y != 0)) {
                ui.game.handleMouseMotion(io, mouse);
            },
            .size_logical => |size| window_logical_size = size,
            .size_physical => |size| window_size = size,
            .scale => |scale| {
                window_scale = scale;
                window_size = window_logical_size.multiply(scale);
                vk_ctx.requestSwapchainRecreate();
            },
            else => {},
        }
    }

    if (ui.menu_state.is_playing_game()) {
        try ui.game.handleButtonActions(io, action_set);
    }
}
