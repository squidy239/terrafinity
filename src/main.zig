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
const utils = @import("libs/utils.zig");

var proc_table: gl.ProcTable = undefined;

const MenuState = struct {
    ingame: bool = false,
    settings: bool = false,
    main: bool = false,
    esc: bool = false,

    pub fn playingGame(self: MenuState) bool {
        return std.meta.eql(self, MenuState{ .ingame = true });
    }
};

const press_start_2p: []const u8 = @embedFile("assets/press-start-2p/PressStart2P.ttf");
const menu_background: []const u8 = @embedFile("assets/terrain.png");
const pixel_font = getFontNameByName("Press Start 2P");

pub fn main() !void {
    var running: std.atomic.Value(bool) = .init(true);

    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    const allocator = if (builtin.mode == .Debug) debug_allocator.allocator() else std.heap.smp_allocator;
    defer if (debug_allocator.deinit() == .leak) std.log.err("mem leaked", .{});

    const configFile = try std.fs.cwd().openFile("Config.zon", .{ .mode = .read_only });
    var config = try utils.loadZON(Config, configFile, allocator, allocator);
    defer std.zon.parse.free(allocator, config);
    configFile.close();

    sdl.errors.error_callback = &sdlErr;
    sdl.log.setAllPriorities(.info);
    sdl.log.setLogOutputFunction(anyopaque, sdlLog, null);
    const init_flags: sdl.InitFlags = .{ .video = true, .events = true };
    defer sdl.shutdown();

    //try wayland since its not default
    var d: usize = 0;
    while (sdl.video.getDriverName(d)) |name| : (d += 1) {
        if (std.mem.eql(u8, name, "wayland")) {
            sdl.hints.set(.video_driver, "wayland") catch {};
            break;
        }
    }

    try sdl.init(init_flags);
    defer sdl.quit(init_flags);

    // Set OpenGL attributes
    try sdl.video.gl.setAttribute(.context_major_version, 4);
    try sdl.video.gl.setAttribute(.context_minor_version, 1);
    try sdl.video.gl.setAttribute(.context_profile_mask, @intFromEnum(sdl.video.gl.Profile.core));
    try sdl.video.gl.setAttribute(.multi_sample_samples, 4);
    try sdl.video.gl.setAttribute(.double_buffer, @intFromBool(true));
    const window = try sdl.video.Window.init("terrafinity", 800, 600, .{
        .open_gl = true,
        .resizable = true,
        .high_pixel_density = true,
    });

    defer window.deinit();
    errdefer if (sdl.errors.get()) |err| std.log.err("SDL error: {s}", .{err});

    // Create SDL renderer for UI (uses OpenGL backend internally)
    SDLBackend.enableSDLLogging();

    const sdl_renderer = try sdl.render.Renderer.init(window, "opengl");
    defer sdl_renderer.deinit();

    const game_render_context = try sdl.video.gl.Context.init(window);
    defer game_render_context.deinit() catch unreachable;

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

    try ui_window.addFont("Press Start 2P", press_start_2p, null);

    var menu_state: MenuState = .{ .main = true };
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
        try ui_window.begin(std.time.nanoTimestamp());

        if (menu_state.main) try mainPage(&game, allocator, window, &config, &menu_state, game_render_context);
        if (menu_state.esc) try escMenu(&game, window, &menu_state);

        _ = try ui_window.end(.{});
        try backend.setCursor(ui_window.cursorRequested());

        try sdl_renderer.flush();
        try sdl.video.gl.swapWindow(window);
    }
}

fn openGame(gameptr: *Game, allocator: std.mem.Allocator, window: sdl.video.Window, game_config: Game.GameConfig, join: Game.Join, menu_state: *MenuState, render_context: sdl.video.gl.Context) !void {
    std.debug.assert(!menu_state.ingame);
    try render_context.makeCurrent(window);
    try gameptr.init(allocator, game_config, window, join);
    menu_state.ingame = true;
    try gameptr.startThreads();
    std.log.info("opening game\n", .{});
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

fn mainPage(gameptr: *Game, allocator: std.mem.Allocator, window: sdl.video.Window, config: *Config, menu_state: *MenuState, game_render_context: sdl.video.gl.Context) !void {
    const menuarea = dvui.overlay(@src(), .{ .expand = .both });
    defer menuarea.deinit();
    //background
    _ = dvui.image(@src(), .{ .source = .{ .imageFile = .{ .bytes = menu_background } }, .shrink = .vertical }, .{ .expand = .both });

    const mainpage = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer mainpage.deinit();

    try sidebar(allocator, config, menu_state);

    const menu = dvui.box(@src(), .{}, .{ .background = false, .color_fill = .{ .r = 24, .g = 24, .b = 24, .a = 255 }, .expand = .both });
    defer menu.deinit();

    const top = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    const terrafinity = dvui.textLayout(@src(), .{ .break_lines = false }, .{ .gravity_x = 0.5, .color_fill = .transparent });

    terrafinity.addText("terrafinity", .{ .font = .{ .size = 64, .family = pixel_font } });
    terrafinity.deinit();
    top.deinit();
    try continueMenu(gameptr, allocator, window, config, menu_state, game_render_context);
}

fn sidebar(allocator: std.mem.Allocator, config: *Config, menu_state: *MenuState) !void {
    const bar = dvui.box(@src(), .{ .dir = .vertical }, .{ .background = true, .color_fill = .{ .r = 48, .g = 77, .b = 48, .a = 225 }, .expand = .vertical, .min_size_content = .width(128) });
    defer bar.deinit();

    if (dvui.button(@src(), "Home", .{}, .{ .gravity_x = 0.5, .color_fill = .blue, .margin = .all(16), .expand = .horizontal, .padding = .{ .y = 16, .h = 16 } }))
        menu_state.* = .{ .main = true };
    if (dvui.button(@src(), "Settings", .{}, .{ .gravity_x = 0.5, .color_fill = .blue, .margin = .all(16), .expand = .horizontal, .padding = .{ .y = 16, .h = 16 } }))
        menu_state.* = .{ .settings = true };

    _ = allocator;
    _ = config;
}

fn continueMenu(gameptr: *Game, allocator: std.mem.Allocator, window: sdl.video.Window, config: *const Config, menu_state: *MenuState, game_render_context: sdl.video.gl.Context) !void {
    const continue_games = dvui.scrollArea(@src(), .{
        .horizontal_bar = .hide,
        .vertical = .none,
        .horizontal = .auto,
    }, .{
        .expand = .horizontal,
        .margin = .{ .w = 16, .x = 16 },
        .color_fill = .transparent,
        .min_size_content = .height(384),
    });
    defer continue_games.deinit();

    const container = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .vertical });
    defer container.deinit();

    const new_game = menuCard(@src(), .{}, .{ .expand = .vertical });
    if (dvui.button(@src(), "+", .{}, .{ .expand = .both, .color_fill = .blue, .font = .{ .size = 96, .weight = .bold, .family = getFontNameByName("Vera Sans") } })) {
        //TODO open new game menu
    }

    new_game.deinit();

    var worlds_path: std.fs.Dir = try std.fs.cwd().openDir(config.worlds_path, .{ .iterate = true });
    defer worlds_path.close();
    var it = worlds_path.iterate();
    var i: usize = 0;
    while (try it.next()) |item| : (i += 1) {
        if (item.kind != .directory) continue;
        const game = menuCard(@src(), .{}, .{ .id_extra = i, .expand = .vertical });
        defer game.deinit();

        const text = dvui.textLayout(@src(), .{}, .{ .gravity_x = 0.5 });
        text.addText(item.name, .{
            .font = .{ .family = pixel_font },
        });
        text.deinit();
        if (dvui.button(@src(), "Play", .{}, .{ .gravity_x = 0.5, .gravity_y = 1.0, .expand = .horizontal, .margin = .{ .x = 64, .w = 64 }, .font = .{ .family = pixel_font }, .color_fill = .blue })) {
            std.log.info("Joining game: {s}", .{item.name});
            const jpath = try std.fs.path.join(allocator, &[_][]const u8{ config.worlds_path, item.name });
            defer allocator.free(jpath);
            const join: Game.Join = .{ .world_folder = jpath };
            try openGame(gameptr, allocator, window, config.game_config, join, menu_state, game_render_context); //TODO popup when game cant be opened
            menu_state.main = false;
        }
    }
}

fn getFontNameByName(comptime name: []const u8) [50:0]u8 {
    comptime var f: [50:0]u8 = @splat(0);
    comptime @memcpy(f[0..name.len], name);
    return f;
}

fn menuCard(src: std.builtin.SourceLocation, init_opts: dvui.BoxWidget.InitOptions, opts: dvui.Options) *dvui.BoxWidget {
    var options: dvui.Options = .{
        .min_size_content = .all(256),
        .color_fill = .{ .r = 48, .g = 48, .b = 48, .a = 255 },
        .background = true,
        .corner_radius = .all(0),
        .border = .all(8),
        .margin = .all(16),
        .gravity_y = 0.5,
        .color_border = .{ .r = 48, .g = 77, .b = 48, .a = 255 },
    };
    var card = dvui.widgetAlloc(dvui.BoxWidget);
    card.init(src, init_opts, options.override(opts));
    card.data().was_allocated_on_widget_stack = true;

    const hover: bool = hovered(card.data(), .{});
    if (hover) {
        card.data().options.margin = .all(0);
        calculateWidget(card);
    }
    card.drawBackground();
    return card;
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

const Config = struct {
    game_config: Game.GameConfig,
    worlds_path: []const u8,
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

fn hovered(wd: *const dvui.WidgetData, opts: HoverOptions) bool {
    const click_rect = opts.rect orelse wd.borderRectScale().r;
    for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = wd.id, .r = click_rect }))
            continue;
        if (e.evt == .mouse) {
            if (e.evt.mouse.action == .position) {
                // Usually you don't want to mark .position events as
                // handled, so that multiple widgets can all do hover
                // highlighting.

                // a single .position mouse event is at the end of each
                // frame, so this means the mouse ended above us
                if (opts.hover_cursor) |cursor| {
                    dvui.cursorSet(cursor);
                }
                return true;
            }
        }
    }
    return false;
}

const HoverOptions = struct {
    hover_cursor: ?dvui.enums.Cursor = .hand,
    rect: ?dvui.Rect.Physical = null,
};

fn calculateWidget(widget: *dvui.BoxWidget) void {
    widget.data().register();
    widget.child_rect = widget.data().contentRect().justSize();
    if (widget.data_prev) |dp| {
        if (widget.init_opts.equal_space) {
            if (dp.packed_children > 0) {
                switch (widget.init_opts.dir) {
                    .horizontal => widget.pixels_per_w = widget.child_rect.w / dp.packed_children,
                    .vertical => widget.pixels_per_w = widget.child_rect.h / dp.packed_children,
                }
            }
        } else {
            var packed_weight = dp.total_weight;
            if (widget.init_opts.num_packed_expanded) |num| {
                packed_weight = @floatFromInt(num);
            }

            if (packed_weight > 0) {
                switch (widget.init_opts.dir) {
                    .horizontal => widget.pixels_per_w = @max(0, widget.child_rect.w - dp.min_space_taken) / packed_weight,
                    .vertical => widget.pixels_per_w = @max(0, widget.child_rect.h - dp.min_space_taken) / packed_weight,
                }
            }
        }
    }
}
