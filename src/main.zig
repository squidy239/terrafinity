const std = @import("std");
const builtin = @import("builtin");

const EntityTypes = @import("world/EntityTypes.zig");
pub const Block = @import("world/Block.zig").Block;
pub const Cache = @import("Cache").Cache;
pub const Chunk = @import("world/Chunk.zig");
pub const ChunkSize = Chunk.ChunkSize;
pub const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
pub const ConcurrentQueue = @import("ConcurrentQueue");
pub const Entity = @import("world/Entity.zig");
pub const ThreadPool = @import("ThreadPool");
pub const Loader = @import("Loader.zig");
const sdl = @import("sdl3");
pub const World = @import("world/World.zig");
pub const zm = @import("zm");
pub const ztracy = @import("ztracy");
const Ui = @import("Ui.zig");
const Game = @import("Game.zig");
const dvui = @import("dvui");
const SDLBackend = @import("sdl3-backend");
const Key = @import("Key.zig");
const utils = @import("libs/utils.zig");
const TrackingAllocator = @import("libs/TrackingAllocator.zig");

const config_path = "Config.zon";

pub fn main() !void {
    var running: std.atomic.Value(bool) = .init(true);

    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    const backing_allocator = if (builtin.mode == .Debug) debug_allocator.allocator() else std.heap.smp_allocator;
    var tracking_allocator = TrackingAllocator.init(backing_allocator, std.math.maxInt(usize));
    const allocator = tracking_allocator.get_allocator();
    defer if (debug_allocator.deinit() == .leak) std.log.err("mem leaked", .{});
    _ = try sdl.setMemoryFunctionsByAllocator(allocator);

    var config_lock: std.Thread.RwLock = .{};

    var config: Config = try .load(allocator, config_path);
    defer config.deinit(allocator);

    try config.save(config_path, &config_lock); //save the config to format it or create it if it dident exist

    sdl.errors.error_callback = &sdlErr;
    sdl.log.setLogOutputFunction(anyopaque, sdlLog, null);
    const init_flags: sdl.InitFlags = .{ .video = true, .events = true };
    defer sdl.shutdown();

    try sdl.init(init_flags);
    defer sdl.quit(init_flags);
    // Set OpenGL attributes
    try sdl.video.gl.setAttribute(.context_major_version, 4);
    try sdl.video.gl.setAttribute(.context_minor_version, 1);
    try sdl.video.gl.setAttribute(.context_profile_mask, @intFromEnum(sdl.video.gl.Profile.core));
    try sdl.video.gl.setAttribute(.multi_sample_samples, 4);
    try sdl.video.gl.setAttribute(.double_buffer, @intFromBool(true));
    var window = try sdl.video.Window.init("terrafinity", 800, 600, .{
        .open_gl = true,
        .resizable = true,
        .high_pixel_density = true,
    });

    defer window.deinit();
    errdefer if (sdl.errors.get()) |err| std.log.err("SDL error: {s}", .{err});

    SDLBackend.enableSDLLogging();

    try sdl.keyboard.startTextInput(window);
    defer sdl.keyboard.stopTextInput(window) catch unreachable;

    try sdl.video.gl.setAttribute(.share_with_current_context, 1);

    // Create SDL renderer for UI (uses OpenGL backend internally)
    const sdl_renderer = try sdl.render.Renderer.init(window, "opengl");
    defer sdl_renderer.deinit();

    try sdl_renderer.setDrawBlendMode(.blend);

    var backend = SDLBackend.init(@ptrCast(window.value), @ptrCast(sdl_renderer.value));
    defer backend.deinit();

    var ui_window = try dvui.Window.init(@src(), allocator, backend.backend(), .{});
    defer ui_window.deinit();

    var keymap = Key.Map.init(allocator);
    defer keymap.map.deinit();

    var singlepress = Key.Singlepress.initEmpty();
    //TODO load keymap from file
    try keymap.setActionKey(.{ .key = .escape }, .escape_menu);
    try keymap.setActionKey(.{ .key = .left_gui }, .escape_menu);

    singlepress.insert(.escape_menu);

    try keymap.setActionKey(.{ .key = .w }, .forward);
    try keymap.setActionKey(.{ .key = .s }, .backward);
    try keymap.setActionKey(.{ .key = .a }, .left);
    try keymap.setActionKey(.{ .key = .d }, .right);
    try keymap.setActionKey(.{ .key = .space }, .up);
    try keymap.setActionKey(.{ .key = .left_shift }, .down);

    var game: Game = undefined;

    var ui: Ui = .{
        .window = window,
        .config = &config,
        .config_lock = &config_lock,
        .game = &game,
        .menu_state = .{ .main = true },
        .config_path = config_path,
        .worlds_path = config.worlds_path,
    };
    try Ui.loadFonts(&ui_window);

    defer if (ui.menu_state.ingame) game.deinit(window);
    var frame_time: std.time.Timer = try .start();
    var action_set = Key.ActionSet.initEmpty();

    while (running.load(.unordered)) {
        try sdl.mouse.setWindowRelativeMode(window, ui.menu_state.playingGame());
        const scroll = try handleEvents(&keymap, singlepress, &action_set, &running, &backend, &ui_window);
        if (action_set.contains(.escape_menu)) ui.menu_state.handleEsc();
        const dt = frame_time.lap();
        const ms = sdl.mouse.getRelativeState();
        if (ui.menu_state.ingame) {
            const ig = ztracy.ZoneN(@src(), "ingame");
            defer ig.End();
            const mouse_moved = (ms[1] != 0 or ms[2] != 0);
            if (ui.menu_state.playingGame() and mouse_moved) game.handleMouseMotion(.{ ms[1], ms[2] }, game.getMouseSensitivity());
            try game.handleButtonActions(action_set, dt);
            game.handleScroll(scroll);

            const size = try window.getSizeInPixels();
            try game.renderer.setViewport(.{ @intCast(size[0]), @intCast(size[1]) });
            try game.renderer.clear(game.player.physics.getPos());
            try game.player.physics.update(&game.world, allocator);
            try game.renderer.drawChunks(game.player.physics.getPos());
            try game.world.updateEntitys(allocator);
            game.unloadChunkMeshes();
        }
        const dw = ztracy.ZoneN(@src(), "draw ui");
        try ui_window.begin(std.time.nanoTimestamp());
        var menuchanged: bool = false;

        if (ui.menu_state.esc and !menuchanged) menuchanged = try ui.escMenu();
        if (ui.menu_state.main and !menuchanged) menuchanged = try ui.mainPage(allocator);
        if (ui.menu_state.settings and !menuchanged) menuchanged = try ui.settingsMenu();
        if (ui.menu_state.newgame and !menuchanged) menuchanged = try ui.newGameMenu(allocator);

        _ = try ui_window.end(.{});
        dw.End();
        try backend.setCursor(ui_window.cursorRequested());
        const sf = ztracy.ZoneN(@src(), "sdl flush");
        try sdl_renderer.flush();
        sf.End();
        const sw = ztracy.ZoneN(@src(), "swap");
        try sdl.video.gl.swapWindow(window);
        sw.End();
        ztracy.FrameMark();
        std.debug.print("    using {d} bytes    \r", .{tracking_allocator.getUsedMemory()});
    }
}

fn handleEvents(key_map: *Key.Map, singlepress: Key.Singlepress, action_set: *Key.ActionSet, running: *std.atomic.Value(bool), ui_backend: *SDLBackend, win: *dvui.Window) !f32 {
    //set all single press buttons like escape to false
    var it = action_set.iterator();
    while (it.next()) |action| {
        if (singlepress.contains(action)) action_set.remove(action);
    }
    var scroll: f32 = 0;
    while (sdl.events.poll()) |event| {
        _ = try ui_backend.addEvent(win, @bitCast(event.toSdl()));
        switch (event) {
            .key_up => |key| {
                //TODO modifiers
                const action = key_map.getAction(Key.Key{ .key = key.key.?, .modifier = null }) orelse continue;
                action_set.remove(action);
            },
            .key_down => |key| {
                const action = key_map.getAction(Key.Key{ .key = key.key.?, .modifier = null }) orelse continue;
                action_set.insert(action);
            },
            .quit, .window_close_requested => {
                running.store(false, .unordered);
            },
            .terminating => {},
            .mouse_wheel => |wheel| {
                scroll += wheel.scroll_y;
            },
            else => {},
        }
    }
    return scroll;
}

test {
    @setEvalBranchQuota(10000);
    std.testing.refAllDeclsRecursive(@This());
}

///must be locked by the caller
pub const Config = struct {
    game_config: Game.Options = .{},
    worlds_path: []const u8 = "worlds",

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
        const configFile: ?std.fs.File = std.fs.cwd().openFile(path, .{ .mode = .read_only, .lock = .shared }) catch |err| sw: switch (err) {
            error.FileNotFound => {
                std.log.info("Config file not found, creating default config file", .{});
                break :sw null;
            },
            else => return err,
        };
        defer if (configFile) |file| file.close();
        var config: Config = undefined;
        config = if (configFile) |file| try utils.loadZON(Config, file, allocator, allocator) else .{};

        if (configFile == null) config.worlds_path = try allocator.dupe(u8, config.worlds_path); //world path must be owned by the allocator so it dosent free invalid memory
        return config;
    }

    pub fn save(self: *const Config, path: []const u8, config_lock: ?*std.Thread.RwLock) !void {
        const configFile = try std.fs.cwd().createFile(path, .{ .lock = .exclusive });
        defer configFile.close();
        var buffer: [512]u8 = undefined;
        var filewriter = configFile.writer(&buffer);
        {
            if (config_lock) |lock| lock.lockShared();
            defer if (config_lock) |lock| lock.unlockShared();
            try std.zon.stringify.serialize(self, .{}, &filewriter.interface);
        }
        try filewriter.end();
    }

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        std.zon.parse.free(allocator, self.*);
    }

    pub const structui_options: dvui.struct_ui.StructOptions(@This()) = .initWithDefaults(.{}, null);
};

fn sdlLog(
    user_data: ?*anyopaque,
    category: ?sdl.log.Category,
    priority: ?sdl.log.Priority,
    message: [:0]const u8,
) void {
    _ = user_data;
    _ = category;
    switch (priority orelse .info) {
        .warn => std.log.warn("{s}", .{message}),
        .debug => std.log.debug("{s}", .{message}),
        .info => std.log.info("{s}", .{message}),
        .err => std.log.err("{s}", .{message}),
        else => std.log.debug("{s}", .{message}),
    }
}

fn sdlErr(
    err: ?[]const u8,
) void {
    if (err) |val| {
        std.log.err("******* [Error! {s}] *******\n", .{val});
    } else {
        std.log.err("******* [Unknown Error!] *******\n", .{});
    }
}
