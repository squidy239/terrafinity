const std = @import("std");
const dvui = @import("dvui");
const options = @import("options");
pub const tracy = @import("tracy");
pub const tracy_impl = @import("tracy_impl");
const wio = @import("wio");
const vk = @import("vulkan");
const Renderer = @import("Renderer.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const dvui_vk_renderer = @import("dvui_vk_renderer");

pub const Entity = @import("entity/Entity.zig");
const EntityTypes = @import("entity/EntityTypes.zig");
const Game = @import("Game.zig");
const Key = @import("Key.zig");
pub const Cache = @import("libs/Cache.zig").Cache;
pub const ConcurrentHashMap = @import("libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const utils = @import("libs/utils.zig");
const Ui = @import("Ui.zig");
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

    pollInitialSize(io, &events, &window_size);
    var vk_ctx = try VulkanContext.init(gpa, &window);
    defer vk_ctx.deinit(io);

    vk_ctx.swapchain_extent = .{ .width = @as(u32, @intCast(window_size.width)), .height = @as(u32, @intCast(window_size.height)) };
    vk_ctx.present_mode = config.game_config.render_options.present_mode;
    vk_ctx.queue_mutex.lockUncancelable(io);
    try vk_ctx.createSwapchainLocked(false);
    vk_ctx.queue_mutex.unlock(io);

    var backend = try dvui.backend.init(.{ .io = io, .window = window, .size = window_size, .framebuffer = window_size });
    defer backend.deinit();

    const vk_memory = dvui_vk_renderer.VkMemory.init(vk_ctx.mem_props) orelse return error.NoSuitableMemory;
    try backend.initVulkan(
        vk_ctx.dev,
        vk_ctx.pdev,
        vk_memory,
        vk_ctx.graphics_queue,
        vk_ctx.ui_command_pool,
        gpa,
        VulkanContext.max_frames_in_flight,
        vk_ctx.swapchain_format,
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
    single_press.insert(.escape_menu);
    single_press.insert(.fullscreen);

    inline for (.{ .{ .key = .w, .action = .forward }, .{ .key = .s, .action = .backward }, .{ .key = .a, .action = .left }, .{ .key = .d, .action = .right }, .{ .key = .space, .action = .up }, .{ .key = .left_shift, .action = .down }, .{ .key = .mouse_left, .action = .use_item_primary }, .{ .key = .mouse_right, .action = .use_item_secondary }, .{ .key = .f, .action = .use_item_tertiary } }) |bind| {
        try keymap.setActionKey(io, .{ .key = bind.key }, bind.action);
    }

    var game: Game = undefined;
    if (options.test_play != null) {
        vk_ctx.swapchain_gamma.store(config.game_config.render_options.gamma_correction, .monotonic);
        try game.init(io, gpa, &config.game_config, &config_lock, worlds_path, vk_ctx, &generators);
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
    const ui_cmd_bufs_slice: []vk.CommandBuffer = &ui_cmd_buffers;
    try vk_ctx.dev.allocateCommandBuffers(&.{
        .command_pool = vk_ctx.ui_command_pool,
        .level = .primary,
        .command_buffer_count = VulkanContext.max_frames_in_flight,
    }, ui_cmd_bufs_slice.ptr);
    defer vk_ctx.dev.freeCommandBuffers(vk_ctx.ui_command_pool, ui_cmd_bufs_slice);

    while (running.load(.unordered)) {
        wio.update();
        try handleEvents(io, &keymap, single_press, &action_set, &running, &backend, &window, &events, &ui_window, &ui);
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
            vk_ctx.swapchain_needs_recreate.store(true, .monotonic);
        }
        frame_time = .now(io, .awake);

        if (prev_window_size.width != window_size.width or prev_window_size.height != window_size.height) {
            vk_ctx.swapchain_extent = .{ .width = @as(u32, @intCast(window_size.width)), .height = @as(u32, @intCast(window_size.height)) };
            vk_ctx.swapchain_needs_recreate.store(true, .monotonic);
            prev_window_size = window_size;
        }

        if (options.test_play) |timeout| {
            if (start_time.untilNow(io, .awake).toSeconds() >= timeout) {
                std.log.info("Test play timeout reached", .{});
                running.store(false, .unordered);
                break;
            }
        }

        if (vk_ctx.swapchain_needs_recreate.load(.monotonic)) {
            recreateSwapchainOrFail(io, vk_ctx, &ui, &game, config.game_config.render_options.present_mode, config.game_config.render_options.gamma_correction, &swapchain_recreate_failures) catch |err| return err;
            continue;
        }

        const frame_ctx = vk_ctx.beginFrame() catch |err| switch (err) {
            error.OutOfDate => {
                recreateSwapchainOrFail(io, vk_ctx, &ui, &game, config.game_config.render_options.present_mode, config.game_config.render_options.gamma_correction, &swapchain_recreate_failures) catch |recreate_err| return recreate_err;
                continue;
            },
            error.SurfaceLost => {
                // Surface recreation requires destroying and recreating the VkSurfaceKHR through
                // the windowing layer, which is not implemented; a retry against the lost surface
                // would keep failing, so terminate instead of spinning on errors.
                std.log.err("Vulkan surface lost; windowing-layer surface recreation is not implemented", .{});
                return err;
            },
            error.DrawFailed => {
                std.log.err("beginFrame failed: draw error", .{});
                continue;
            },
            else => return err,
        };

        const is_ingame = ui.menu_state.ingame;
        if (is_ingame) {
            const draw_ctx: Renderer.FrameDrawContext = .{
                .frame_index = frame_ctx.frame_index,
                .cmd_buffer = frame_ctx.cmd_buffer,
                .output_image = vk_ctx.swapchain_images[frame_ctx.image_index],
                .output_view = vk_ctx.swapchain_views[frame_ctx.image_index],
                .swapchain_image_layout = &vk_ctx.swapchain_image_layouts[frame_ctx.image_index],
            };
            try game.frame(io, gpa, draw_ctx, .{ vk_ctx.swapchain_extent.width, vk_ctx.swapchain_extent.height });
        }

        try ui.recordCommandBuffer(io, gpa, &backend, ui_cmd_buffers[frame_ctx.frame_index], frame_ctx, frame_time);

        const submit_game = is_ingame and ui.menu_state.ingame;
        try vk_ctx.submitFrameWithExtra(io, frame_ctx, ui_cmd_buffers[frame_ctx.frame_index], submit_game);

        vk_ctx.present(io, frame_ctx) catch |err| switch (err) {
            error.OutOfDate => {
                // present() already flagged swapchain_needs_recreate; recreate on the next loop pass.
                vk_ctx.swapchain_needs_recreate.store(true, .monotonic);
            },
            error.SurfaceLost => {
                std.log.err("Vulkan surface lost during present; windowing-layer surface recreation is not implemented", .{});
                return err;
            },
            else => {
                std.log.err("present failed: {}", .{err});
            },
        };

        if (ui.menu_state.pending_game_deinit) {
            ui.menu_state.pending_game_deinit = false;
            _ = vk_ctx.dev.deviceWaitIdle() catch {};
            game.deinit(io);
            vk_ctx.swapchain_needs_recreate.store(true, .monotonic);
        }

        tracy.frameMark(null);
    }
    window.disableRelativeMouse();
    _ = vk_ctx.dev.deviceWaitIdle() catch {};
}

test {
    std.testing.refAllDecls(@This());
}

pub const Config = struct {
    game_config: Game.Options = .{},

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
        const config_file: ?std.Io.File = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .lock = .shared }) catch |err| sw: switch (err) {
            error.FileNotFound => {
                std.log.info("Config file not found, creating default config file", .{});
                break :sw null;
            },
            else => return err,
        };
        defer if (config_file) |file| file.close(io);
        var config: Config = undefined;
        config = if (config_file) |file| try utils.loadZon(Config, io, file, allocator, allocator) else blk: {
            var default_config: Config = .{};
            default_config.game_config.render_options.selected_pack = try allocator.dupe(u8, "default");
            break :blk default_config;
        };
        return config;
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

const embedded_generators = [_]struct { file_name: []const u8, bytes: []const u8 }{
    .{ .file_name = "terrain.generator", .bytes = @embedFile("terrain_generator_bin") },
    .{ .file_name = "voxelgame.generator", .bytes = @embedFile("voxelgame_generator_bin") },
    .{ .file_name = "planet.generator", .bytes = @embedFile("planet_generator_bin") },
};

/// Writes the embedded generator libraries into the `generators` directory so
/// the registry can load them, mirroring how the config file is created.
fn writeEmbeddedGenerators(io: std.Io) !void {
    var generators_dir = std.Io.Dir.cwd().createDirPathOpen(io, "generators", .{}) catch |err| switch (err) {
        error.PathAlreadyExists => try std.Io.Dir.cwd().openDir(io, "generators", .{}),
        else => return err,
    };
    defer generators_dir.close(io);

    for (embedded_generators) |embedded| {
        const existing = generators_dir.openFile(io, embedded.file_name, .{ .mode = .read_only }) catch null;
        if (existing) |file| {
            defer file.close(io);
            const stat = try file.stat(io);
            if (stat.size == embedded.bytes.len) continue;
        }
        const file = try generators_dir.createFile(io, embedded.file_name, .{ .lock = .exclusive });
        defer file.close(io);
        var buffer: [512]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll(embedded.bytes);
        try writer.end();
    }
}

fn pollInitialSize(io: std.Io, events: *wio.EventQueue, size: *wio.Size) void {
    _ = io;
    var count: u32 = 0;
    while (count < 100) : (count += 1) {
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

// Recreates the swapchain while tracking consecutive failures: a persistent recreation error would
// otherwise retry every frame (each attempt stalls the GPU with a deviceWaitIdle) and spin forever.
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
    vk_ctx.queue_mutex.lockUncancelable(io);
    defer vk_ctx.queue_mutex.unlock(io);
    vk_ctx.dev.queueWaitIdle(vk_ctx.graphics_queue) catch |err| {
        std.log.err("queueWaitIdle failed during swapchain recreate: {}", .{err});
        return err;
    };

    vk_ctx.present_mode = present_mode;
    if (ui.menu_state.ingame) {
        try game.renderer.recreateSwapchain(io);
    } else {
        try vk_ctx.createSwapchainLocked(gamma_correction);
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
            .button_press => |key| {
                const action = key_map.getAction(io, Key.Key{ .key = key }) orelse continue;
                action_set.insert(action);
            },
            .button_release => |key| {
                const action = key_map.getAction(io, Key.Key{ .key = key }) orelse continue;
                action_set.remove(action);
            },
            .close => running.store(false, .unordered),
            .scroll_vertical => |scroll| {
                if (ui.menu_state.is_playing_game()) try ui.game.handleScroll(io, scroll);
            },
            .mouse_relative => |mouse| {
                const mouse_moved = (mouse.x != 0 or mouse.y != 0);
                if (ui.menu_state.is_playing_game() and mouse_moved) ui.game.handleMouseMotion(io, mouse);
            },
            .size_physical => |size| window_size = size,
            else => {},
        }
    }

    if (ui.menu_state.is_playing_game()) {
        try ui.game.handleButtonActions(io, action_set);
    }
}
