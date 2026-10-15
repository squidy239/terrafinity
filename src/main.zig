const std = @import("std");

const dvui = @import("dvui");
const dvui_vulkan_renderer = @import("dvui_vulkan_renderer");
const options = @import("options");
pub const tracy = @import("tracy");
pub const tracy_options = @import("tracy_options");
const vk = @import("vulkan");
const wio = @import("wio");

pub const Entity = @import("entity/Entity.zig");
const Game = @import("Game.zig");
const Key = @import("Key.zig");
pub const SpatialHash = @import("libs/spatial_hash.zig").SpatialHash;
const utils = @import("libs/utils.zig");
const Renderer = @import("Renderer.zig");
const Ui = @import("Ui.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
pub const generator_loader = @import("world/generator_loader.zig");

pub fn main(init: std.process.Init) !void {
    var running: std.atomic.Value(bool) = .init(true);
    const gpa = init.gpa;
    const io = init.io;

    const config_path = "Config.zon";
    const keymap_path = "Keymap.zon";
    const worlds_path = "worlds";

    var config_lock: std.Io.RwLock = .init;
    var config: Config = try .load(gpa, io, config_path);
    defer config.deinit(gpa);
    try config.save(io, config_path, &config_lock);
    defer config.save(io, config_path, &config_lock) catch |err| std.log.err("Saving config on exit failed: {any}", .{err});
    var keymap: Key.Keymap = try .load(io, gpa, keymap_path);

    try writeEmbeddedGenerators(io);
    var generators = try generator_loader.Registry.init(gpa, io, "generators");
    defer generators.deinit(io);

    try wio.init(.{ .allocator = gpa, .io = io, .eventFn = wio.EventQueue.eventFn });
    defer wio.deinit();

    var events: wio.EventQueue = .empty;
    defer events.deinit();

    var window = try wio.Window.create(.{ .title = "terrafinity", .event_fn_data = &events });
    defer window.destroy();
    // The fullscreen action swaps the two modes.
    var window_modes: [2]wio.WindowMode = .{ .maximized, .fullscreen };
    window.setMode(window_modes[0]);

    var input: Input = .{ .window_size = pollInitialSize(&events) };
    var vk_ctx = try VulkanContext.init(gpa, &window);
    defer vk_ctx.deinit(io);

    vk_ctx.setExtentFromWindow(input.window_size);
    try vk_ctx.createSwapchainLocked(io, false, config.game_config.render_options.present_mode);

    var backend = try dvui.backend.init(.{
        .io = io,
        .window = window,
        .size = input.window_size,
        .framebuffer = input.window_size,
        .gpa = gpa,
        .dev = vk_ctx.dev,
        .memory = dvui_vulkan_renderer.VkMemory.init(vk_ctx.mem_props, vk_ctx.props.limits.non_coherent_atom_size) orelse return error.NoSuitableMemory,
        .max_frames = VulkanContext.max_frames_in_flight,
        .swapchain_format = vk_ctx.swapchain_format,
        .queue_family_index = vk_ctx.queue_family_index,
    });
    defer backend.deinit();

    var ui_window = try dvui.Window.init(@src(), gpa, dvui.Backend.init(&backend), .{});
    defer ui_window.deinit();

    var game: Game = undefined;
    var test_play_error: ?anyerror = null;
    if (options.test_play != null) {
        const test_play_folder = try std.Io.Dir.path.join(gpa, &.{ worlds_path, "test_play" });
        defer gpa.free(test_play_folder);
        // Fall back to the main menu with an error dialog instead of crashing.
        game.init(io, gpa, &config.game_config, &config_lock, test_play_folder, vk_ctx, &generators) catch |err| {
            std.log.err("test play world failed to load: {s}", .{@errorName(err)});
            test_play_error = err;
        };
    }
    const in_game = options.test_play != null and test_play_error == null;
    var ui: Ui = .{
        .vk_ctx = vk_ctx,
        .config = &config,
        .config_lock = &config_lock,
        .game = &game,
        .generators = &generators,
        .menu_state = .{ .page = if (in_game) .game else .main },
        .world_error = test_play_error,
        .config_path = config_path,
        .keymap = &keymap,
        .keymap_path = keymap_path,
        .worlds_path = worlds_path,
        .running = &running,
        .config_section_states = .init(gpa),
        .ui_window = &ui_window,
        .textures = try .load(io, gpa, ui_window.backend, config.game_config.render_options.selected_pack),
    };
    defer ui.deinit(gpa);
    defer if (ui.menu_state.inGame()) game.deinit(io);

    const start_time: std.Io.Timestamp = .now(io, .awake);
    var swapchain_recreate_failures: u32 = 0;

    var ui_cmd_buffers: [VulkanContext.max_frames_in_flight]vk.CommandBuffer = undefined;
    try vk_ctx.dev.allocateCommandBuffers(&.{
        .command_pool = vk_ctx.ui_command_pool,
        .level = .primary,
        .command_buffer_count = VulkanContext.max_frames_in_flight,
    }, &ui_cmd_buffers);
    defer {
        vk_ctx.deviceWaitIdleLocked(io) catch |err| std.log.err("failed to wait for device idle during shutdown: {any}", .{err});
        vk_ctx.dev.freeCommandBuffers(vk_ctx.ui_command_pool, &ui_cmd_buffers);
    }

    // Null after the loop requests the automatic screenshot.
    var screenshot_after = options.screenshot_after;
    var exit_on_screenshot = false;

    while (running.load(.unordered)) {
        wio.update();
        // Captured before the escape toggle, so gameplay input follows the page the events arrived on.
        const playing = ui.menu_state.page == .game;
        try handleEvents(io, &input, &backend, &window, &events, &ui);
        // The previous frame's text focus still holds here, since dvui resets it in `begin`.
        const action_set = input.buttons.takeActions(&keymap, ui_window.textInputRequested() != null);
        applyActions(action_set, &ui, &window, &window_modes);
        const frame_time: std.Io.Timestamp = .now(io, .awake);
        const elapsed_s = start_time.untilNow(io, .awake).toSeconds();

        if (options.test_play) |timeout| if (elapsed_s >= timeout) {
            std.log.info("Test play timeout reached", .{});
            running.store(false, .unordered);
            break;
        };

        if (screenshot_after) |screenshot_timeout| if (elapsed_s >= screenshot_timeout) {
            std.log.info("Screenshot after timeout reached ({d}s), requesting screenshot", .{screenshot_timeout});
            vk_ctx.requestScreenshot(config.game_config.render_options.screenshot_resolution);
            screenshot_after = null;
            // Exit after the save completes when no play session owns the loop.
            exit_on_screenshot = options.test_play == null;
        };

        // A pending recreation takes the same path as an out-of-date swapchain.
        const begun = if (vk_ctx.swapchain_needs_recreate) error.OutOfDate else vk_ctx.beginFrame();
        const frame_ctx = begun catch |err| switch (err) {
            error.OutOfDate => {
                try recreateSwapchainOrFail(io, &ui, config.game_config.render_options, &swapchain_recreate_failures);
                continue;
            },
            error.SurfaceLost => return surfaceLost(err),
            error.DrawFailed => {
                std.log.err("beginFrame failed: draw error", .{});
                continue;
            },
            else => return err,
        };

        const was_ingame = ui.menu_state.inGame();
        if (was_ingame) {
            try game.frame(io, gpa, .{
                .frame_index = frame_ctx.frame_index,
                .cmd_buffer = frame_ctx.cmd_buffer,
                .output_image = vk_ctx.swapchain_images[frame_ctx.image_index].image,
                .output_view = vk_ctx.swapchain_images[frame_ctx.image_index].view,
                .swapchain_image_layout = &vk_ctx.swapchain_images[frame_ctx.image_index].layout,
            }, .{ vk_ctx.swapchain_extent.width, vk_ctx.swapchain_extent.height }, if (playing) &action_set else null);
        }

        try ui.recordCommandBuffer(io, gpa, &backend, ui_cmd_buffers[frame_ctx.frame_index], frame_ctx, frame_time);

        try vk_ctx.submitFrameWithExtra(io, frame_ctx, backend.takePrepass(), ui_cmd_buffers[frame_ctx.frame_index], was_ingame);

        vk_ctx.present(io, frame_ctx) catch |err| switch (err) {
            error.OutOfDate => vk_ctx.swapchain_needs_recreate = true,
            error.SurfaceLost => return surfaceLost(err),
            else => std.log.err("present failed: {}", .{err}),
        };

        const screenshot_saved = vk_ctx.savePendingScreenshot(io, gpa) catch |err| saved: {
            std.log.err("Failed to save screenshot: {any}", .{err});
            break :saved false;
        };
        if (screenshot_saved and exit_on_screenshot) {
            std.log.info("Auto screenshot completed, exiting", .{});
            running.store(false, .unordered);
            break;
        }

        if (ui.menu_state.pending_game_deinit) {
            ui.menu_state.pending_game_deinit = false;
            vk_ctx.deviceWaitIdleLocked(io) catch |err| std.log.err("failed to wait for device idle before game deinit: {any}", .{err});
            game.deinit(io);
            vk_ctx.swapchain_needs_recreate = true;
        }

        if (ui.menu_state.pending_world_recreate) {
            ui.menu_state.pending_world_recreate = false;
            recreateWorld(io, gpa, &ui, &generators);
        }

        tracy.frameMark(null);
    }
    window.disableRelativeMouse();
    try vk_ctx.deviceWaitIdleLocked(io);
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
        return utils.loadZon(Config, io, file, allocator, allocator);
    }

    pub fn save(self: *const Config, io: std.Io, path: []const u8, config_lock: *std.Io.RwLock) !void {
        const config_file = try std.Io.Dir.cwd().createFile(io, path, .{ .lock = .exclusive });
        defer config_file.close(io);
        var buffer: [512]u8 = undefined;
        var file_writer = config_file.writer(io, &buffer);
        {
            config_lock.lockSharedUncancelable(io);
            defer config_lock.unlockShared(io);
            try std.zon.stringify.serialize(self, .{}, &file_writer.interface);
        }
        try file_writer.end();
    }

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        allocator.free(self.game_config.render_options.selected_pack);
    }
};

const embedded_generators: [5]struct { file_name: []const u8, bytes: []const u8 } = .{
    .{ .file_name = "terrain.generator", .bytes = @embedFile("terrain_generator_bin") },
    .{ .file_name = "voxelgame.generator", .bytes = @embedFile("voxelgame_generator_bin") },
    .{ .file_name = "planet.generator", .bytes = @embedFile("planet_generator_bin") },
    .{ .file_name = "fractal.generator", .bytes = @embedFile("fractal_generator_bin") },
    .{ .file_name = "sponge.generator", .bytes = @embedFile("sponge_generator_bin") },
};

fn writeEmbeddedGenerators(io: std.Io) !void {
    var generators_dir = try std.Io.Dir.cwd().createDirPathOpen(io, "generators", .{});
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

/// The number of event polls to wait for the first window size before keeping the default.
const max_initial_size_polls = 100;

fn pollInitialSize(events: *wio.EventQueue) wio.Size {
    for (0..max_initial_size_polls) |_| {
        wio.update();
        while (events.pop()) |event| if (event == .size_physical) return event.size_physical;
    }
    return Input.default_size;
}

fn surfaceLost(err: anyerror) anyerror {
    std.log.err("Vulkan surface lost; windowing-layer surface recreation is not implemented", .{});
    return err;
}

/// Applies the menu, window, screenshot, and debug actions of one frame.
fn applyActions(action_set: Key.ActionSet, ui: *Ui, window: *wio.Window, window_modes: *[2]wio.WindowMode) void {
    if (action_set.contains(.escape_menu)) ui.menu_state.handleEsc();
    if (action_set.contains(.inventory)) ui.menu_state.toggleInventory();
    if (action_set.contains(.fullscreen)) {
        std.mem.swap(wio.WindowMode, &window_modes[0], &window_modes[1]);
        window.setMode(window_modes[0]);
        ui.vk_ctx.requestSwapchainRecreate();
    }
    if (action_set.contains(.screenshot)) {
        const resolution = ui.config.game_config.render_options.screenshot_resolution;
        ui.vk_ctx.requestScreenshot(resolution);
        std.log.info("Screenshot requested with resolution {s}", .{resolution.label()});
    }
    if (action_set.contains(.debug_menu)) {
        ui.menu_state.debug_info = !ui.menu_state.debug_info;
        std.log.info("Debug menu toggled: {any}", .{ui.menu_state.debug_info});
    }
}

const max_swapchain_recreate_failures: u32 = 120;

/// Recreates the swapchain. Returns an error only after `max_swapchain_recreate_failures` failures in a row.
fn recreateSwapchainOrFail(io: std.Io, ui: *Ui, render_options: Renderer.RenderOptions, consecutive_failures: *u32) !void {
    recreateSwapchain(io, ui, render_options) catch |err| {
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

/// Recreates the swapchain through the game renderer while in game, else directly for the menu.
fn recreateSwapchain(io: std.Io, ui: *Ui, render_options: Renderer.RenderOptions) !void {
    const vk_ctx = ui.vk_ctx;
    try vk_ctx.dev.queueWaitIdle(vk_ctx.graphics_queue);
    if (ui.menu_state.inGame()) {
        try ui.game.renderer.recreateSwapchain(io);
    } else {
        try vk_ctx.createSwapchainLocked(io, render_options.gamma_correction, render_options.present_mode);
    }
    vk_ctx.swapchain_needs_recreate = false;
}

/// Rebuilds the terrain world. A failure that closes the game also leaves it in the menu.
fn recreateWorld(io: std.Io, gpa: std.mem.Allocator, ui: *Ui, generators: *generator_loader.Registry) void {
    ui.vk_ctx.deviceWaitIdleLocked(io) catch |err| {
        std.log.err("could not wait for the GPU before terrain recreation: {any}", .{err});
        ui.terrain_recreate_error = @errorName(err);
        return;
    };
    ui.game.recreateWorld(io, gpa, ui.vk_ctx, generators) catch |err| {
        std.log.err("terrain world recreation failed: {any}", .{err});
        ui.terrain_recreate_error = @errorName(err);
        switch (err) {
            error.RecreatePathAllocationFailed,
            error.RecreateConfigSaveFailed,
            error.RecreateChunkSaveFailed,
            error.RecreateStorageClearFailed,
            => {},
            else => ui.menu_state.leaveGame(),
        }
    };
}

/// Loop-thread input state carried between frames.
const Input = struct {
    buttons: Key.Buttons = .{},
    logical_size: wio.Size = default_size,
    window_size: wio.Size = default_size,

    /// The size until the window reports its real size.
    const default_size: wio.Size = .{ .height = 480, .width = 640 };

    /// Applies a physical size, recreating the swapchain only when it changed.
    fn resize(self: *Input, vk_ctx: *VulkanContext, size: wio.Size) void {
        if (std.meta.eql(self.window_size, size)) return;
        self.window_size = size;
        vk_ctx.setExtentFromWindow(size);
    }
};

fn handleEvents(io: std.Io, input: *Input, backend: *dvui.backend, win: *wio.Window, events: *wio.EventQueue, ui: *Ui) !void {
    const playing = ui.menu_state.page == .game;
    if (playing) win.enableRelativeMouse(.{ .unaccelerated = true }) else win.disableRelativeMouse();

    while (events.pop()) |event| {
        // A press bound in the editor reaches neither dvui nor gameplay, so it cannot click or open a menu.
        if (event == .button_press and ui.captureButton(io, event.button_press)) continue;
        _ = try backend.addEvent(ui.ui_window, event);
        switch (event) {
            .button_press => |button| input.buttons.press(button),
            .button_release => |button| input.buttons.release(button),
            .unfocused => {
                input.buttons.releaseAll();
                ui.key_capture = null;
            },
            .close => ui.running.store(false, .unordered),
            .scroll_vertical => |scroll| if (playing) try ui.game.handleScroll(io, scroll),
            .mouse_relative => |mouse| if (playing and (mouse.x != 0 or mouse.y != 0)) ui.game.handleMouseMotion(io, mouse),
            .size_logical => |size| input.logical_size = size,
            .size_physical => |size| input.resize(ui.vk_ctx, size),
            .scale => |scale| {
                input.resize(ui.vk_ctx, input.logical_size.multiply(scale));
                ui.vk_ctx.requestSwapchainRecreate();
            },
            else => {},
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
