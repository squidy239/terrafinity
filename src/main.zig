const std = @import("std");
const builtin = @import("builtin");

const EntityTypes = @import("world/EntityTypes.zig");
const gl = @import("gl");
pub const Block = @import("world/Block.zig").Block;
pub const Cache = @import("Cache").Cache;
pub const Chunk = @import("world/Chunk.zig");
pub const ChunkSize = Chunk.ChunkSize;
pub const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
pub const ConcurrentQueue = @import("ConcurrentQueue");
pub const Entity = @import("world/Entity.zig");
pub const ThreadPool = @import("ThreadPool");
pub const Loader = @import("Loader.zig");
pub const ChunkManager = @import("ChunkManager.zig").ChunkManager;
const sdl = @import("sdl3");
pub const World = @import("world/World.zig");
pub const zm = @import("zm");
pub const ztracy = @import("ztracy");
const Game = @import("Game.zig");
const dvui = @import("dvui");
pub const Renderer = @import("client/Renderer.zig");
const SDLBackend = @import("sdl3-backend");
const Key = @import("Key.zig");

var proc_table: gl.ProcTable = undefined;

const MenuState = struct {
    ingame: bool = false,
    options: bool = false,
    main: bool = false,
    esc: bool = false,
    
    pub fn playingGame(self: MenuState) bool {
        return std.meta.eql(self, MenuState{.ingame = true});
    }
};

pub fn main() !void {
    var running: std.atomic.Value(bool) = .init(true);

    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    const allocator = if (builtin.mode == .Debug) debug_allocator.allocator() else std.heap.smp_allocator;
    defer if (debug_allocator.deinit() == .leak) std.log.err("mem leaked", .{});

    sdl.errors.error_callback = &sdlErr;
    sdl.log.setAllPriorities(.info);
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
    //try sdl.video.gl.setAttribute(.double_buffer, @intFromBool(true));
    const window = try sdl.video.Window.init("terrafinity", 800, 600, .{
        .open_gl = true,
    });
    defer window.deinit();

    // Create SDL renderer for UI (uses OpenGL backend internally)
    SDLBackend.enableSDLLogging();

    const game_render_context = try sdl.video.gl.Context.init(window);
    defer game_render_context.deinit() catch unreachable;

    const ui_context = try sdl.video.gl.Context.init(window);
    defer ui_context.deinit() catch unreachable;

    errdefer if (sdl.errors.get()) |err| std.log.err("SDL error: {s}", .{err});
    const sdl_renderer = try sdl.render.Renderer.init(window, "opengl");
    defer sdl_renderer.deinit();

    try sdl_renderer.setDrawBlendMode(.blend);

    try game_render_context.makeCurrent(window);

    // Initialize OpenGL
    if (!proc_table.init(sdl.c.SDL_GL_GetProcAddress)) return error.InitFailed;
    gl.makeProcTableCurrent(&proc_table);

    gl.Viewport(0, 0, @intFromFloat(@as(f32, @floatFromInt(800))), @intFromFloat(@as(f32, @floatFromInt(600))));

    gl.Enable(gl.MULTISAMPLE);
    gl.Enable(gl.DEPTH_TEST);
    gl.Enable(gl.CULL_FACE);
    gl.CullFace(gl.BACK);
    gl.FrontFace(gl.CW);
    gl.DepthFunc(gl.LESS);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var backend = SDLBackend.init(@ptrCast(window.value), @ptrCast(sdl_renderer.value));
    defer backend.deinit();

    var ui_window = try dvui.Window.init(@src(), allocator, backend.backend(), .{});
    defer ui_window.deinit();

    var path = try std.fs.cwd().openDir("test_world", .{});
    defer path.close();

    var menu_state: MenuState = .{ .main = true };
    var keymap = Key.Map.init(allocator);
    defer keymap.map.deinit();

    var singlepress = Key.Singlepress.initEmpty();
    //TODO load keymap from file
    try keymap.setActionKey(.{ .key = .escape }, .escape_menu);
    singlepress.insert(.escape_menu);

    try keymap.setActionKey(.{ .key = .w }, .forward);
    try keymap.setActionKey(.{ .key = .s }, .backward);
    try keymap.setActionKey(.{ .key = .a }, .left);
    try keymap.setActionKey(.{ .key = .d }, .right);
    try keymap.setActionKey(.{ .key = .space }, .jump);

    var game: Game = undefined;
    defer if (menu_state.ingame) game.deinit(window);
    var frame_time: std.time.Timer = try .start();
    var action_set = Key.ActionSet.initEmpty();
    while (running.load(.unordered)) {
        try sdl.mouse.setWindowRelativeMode(window, menu_state.playingGame());
        try handleEvents(&keymap, singlepress, &action_set, &running, &backend, &ui_window);
        const dt = frame_time.lap();
        const ms = sdl.mouse.getRelativeState();
        if (menu_state.ingame) {
            const mouse_moved = (ms[1] != 0 or ms[2] != 0);
            if (menu_state.playingGame() and mouse_moved) game.handleMouseMotion(.{ ms[1], ms[2] });
            try game.handleKeyboardActions(action_set, dt);
            if (action_set.contains(.escape_menu)) menu_state.esc = !menu_state.esc;

            const size = try window.getSize();
            const viewport_pixels = @Vector(2, f32){ @floatFromInt(size[0]), @floatFromInt(size[1]) };
            try game_render_context.makeCurrent(window);
            _ = try game.renderer.Draw(&game, viewport_pixels);
        }
        try ui_context.makeCurrent(window);
        try ui_window.begin(std.time.nanoTimestamp());

        if (menu_state.main) try mainMenu(&game, allocator, window, path, &menu_state, game_render_context, ui_context);
        if (menu_state.esc) try escMenu(&game, window, &menu_state);

        _ = try ui_window.end(.{});
        if (ui_window.cursorRequestedFloating()) |cursor| {
            try backend.setCursor(cursor);
        } else {
            try backend.setCursor(.arrow);
        }

        try sdl_renderer.flush();
        try sdl.video.gl.swapWindow(window);
    }
}

fn openGame(gameptr: *Game, allocator: std.mem.Allocator, window: sdl.video.Window, path: std.fs.Dir, menu_state: *MenuState, game_context: sdl.video.gl.Context, ui_context: sdl.video.gl.Context) !void {
    try game_context.makeCurrent(window);
    std.debug.assert(!menu_state.ingame);
    try gameptr.init(allocator, allocator, window, path);
    menu_state.ingame = true;
    try gameptr.startThreads();
    std.log.info("opening game\n", .{});
    try ui_context.makeCurrent(window);
}

fn handleEvents(key_map: *Key.Map, singlepress: Key.Singlepress, action_set: *Key.ActionSet, running: *std.atomic.Value(bool), ui_backend: *SDLBackend, window: *dvui.Window) !void {
    //set all single press buttons like escape to false
    var it = action_set.iterator();
    while (it.next()) |action| {
        if (singlepress.contains(action)) action_set.remove(action);
    }
    while (sdl.events.poll()) |event| {
        _ = try ui_backend.addEvent(window, @bitCast(event.toSdl()));
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
            .quit, .terminating, .window_close_requested => {
                running.store(false, .unordered);
            },
            else => {},
        }
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}

fn mainMenu(gameptr: *Game, allocator: std.mem.Allocator, window: sdl.video.Window, path: std.fs.Dir, menu_state: *MenuState, game_render_context: sdl.video.gl.Context, ui_context: sdl.video.gl.Context) !void {
    const size = try window.getSizeInPixels();
    const menu = dvui.menu(@src(), .vertical, .{ .background = true, .color_fill = .{ .r = 0, .g = 200, .b = 200, .a = 150 }, .expand = .both });
    if (dvui.button(@src(), "Play", .{}, .{ .min_size_content = .width(@as(f32, @floatFromInt(size[0])) * 0.75), .gravity_x = 0.5, .style = .app3 })) {
        try openGame(gameptr, allocator, window, path, menu_state, game_render_context, ui_context);
        menu_state.main = false;
    }
    menu.deinit();
}

fn escMenu(gameptr: *Game, window: sdl.video.Window, menu_state: *MenuState) !void {
    std.debug.assert(menu_state.ingame);
    const size = try window.getSizeInPixels();
    const menu = dvui.menu(@src(), .vertical, .{ .background = true, .color_fill = .{ .r = 0, .g = 200, .b = 200, .a = 150 }, .expand = .both });
    if (dvui.button(@src(), "Back To Game", .{}, .{ .min_size_content = .width(@as(f32, @floatFromInt(size[0])) * 0.75), .gravity_x = 0.5, .style = .app3 })) {
        menu_state.esc = false;
    }

    if (dvui.button(@src(), "Quit", .{}, .{ .min_size_content = .width(@as(f32, @floatFromInt(size[0])) * 0.75), .gravity_x = 0.5, .style = .app3 })) {
        menu_state.main = true;
        menu_state.esc = false;
        menu_state.ingame = false;
        gameptr.deinit(window);
        gameptr.* = undefined;
    }
    menu.deinit();
}

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
