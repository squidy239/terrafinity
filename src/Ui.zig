const dvui = @import("dvui");
const std = @import("std");
const Game = @import("Game.zig");
const sdl = @import("sdl3");
const Config = @import("main.zig").Config;
const World = @import("world/World.zig");
const utils = @import("libs/utils.zig");

const press_start_2p: []const u8 = @embedFile("assets/press-start-2p/PressStart2P.ttf");
const menu_background: []const u8 = @embedFile("assets/terrain.png");
const pixel_font = sliceToBounded("Press Start 2P", 50);

const Ui = @This();

window: sdl.video.Window,
config: *Config,
config_lock: *std.Thread.RwLock,
game: *Game,
config_path: []const u8,
worlds_path: []const u8,

menu_state: struct {
    ingame: bool = false,
    settings: bool = false,
    main: bool = false,
    esc: bool = false,
    newgame: bool = false,

    pub fn playingGame(self: @This()) bool {
        return std.meta.eql(self, @This(){ .ingame = true });
    }

    pub fn handleEsc(self: *@This()) void {
        if (self.ingame) self.*.esc = !self.*.esc;
        self.settings = false;
    }
},

fn menuCard(src: std.builtin.SourceLocation, init_opts: dvui.BoxWidget.InitOptions, opts: dvui.Options) *dvui.BoxWidget {
    var options: dvui.Options = .{
        .min_size_content = .all(256),
        .color_fill = .{ .r = 48, .g = 48, .b = 48, .a = 255 },
        .background = true,
        .corner_radius = .all(0),
        .border = .all(8),
        .margin = .all(16),
        .gravity_y = 0.5,
        .color_border = .{ .r = 48, .g = 77, .b = 48, .a = 225 },
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

pub fn escMenu(self: *@This()) !bool {
    std.debug.assert(self.menu_state.ingame);
    const size = try self.window.getSizeInPixels();
    const menu = dvui.box(@src(), .{}, .{ .background = true, .color_fill = .{ .r = 0, .g = 200, .b = 200, .a = 150 }, .expand = .both });
    defer menu.deinit();
    if (dvui.button(@src(), "Back To Game", .{}, .{ .min_size_content = .width(@as(f32, @floatFromInt(size[0])) * 0.75), .gravity_x = 0.5 })) {
        self.menu_state.esc = false;
        return true;
    }

    if (dvui.button(@src(), "Settings", .{}, .{ .min_size_content = .width(@as(f32, @floatFromInt(size[0])) * 0.75), .gravity_x = 0.5 })) {
        self.menu_state.settings = true;
        self.menu_state.esc = false;
        return true;
    }

    if (dvui.button(@src(), "Quit", .{}, .{ .min_size_content = .width(@as(f32, @floatFromInt(size[0])) * 0.75), .gravity_x = 0.5 })) {
        self.menu_state.main = true;
        self.menu_state.esc = false;
        self.menu_state.ingame = false;
        self.game.deinit(self.window);
        self.game.* = undefined;
        return true;
    }

    return false;
}

fn sliceToBounded(comptime slice: []const u8, comptime max: usize) [max:0]u8 {
    var f: [max:0]u8 = undefined;
    @memcpy(f[0..slice.len], slice);
    f[slice.len] = 0;
    return f;
}

pub fn settingsMenu(self: *@This()) !bool {
    const page = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer page.deinit();

    const menuchanged: bool = if (!self.menu_state.ingame) self.sidebar() else false;

    const settings = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = .{ .r = 48, .g = 77, .b = 84, .a = 225 } });
    defer settings.deinit();

    self.config_lock.lock();
    const firstconfig = self.config.*;
    dvui.structUI(@src(), "Settings", self.config, 32, .{ Config.structui_options, Game.Options.structui_options });

    const config_changed = !std.meta.eql(firstconfig, self.config.*);
    self.config_lock.unlock();

    if (config_changed) try self.config.save(self.config_path, self.config_lock);
    return menuchanged;
}

var new_world_options: Game.WorldOptions = .default;
pub fn newGameMenu(self: *@This(), allocator: std.mem.Allocator, game_render_context: sdl.video.gl.Context) !bool {
    const page = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer page.deinit();

    const menuchanged: bool = if (!self.menu_state.ingame) self.sidebar() else false;

    const options = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = .{ .r = 48, .g = 77, .b = 84, .a = 225 } });
    defer options.deinit();
    const create = dvui.button(@src(), "Create World", .{}, .{ .gravity_x = 0.5, .color_fill = .blue, .margin = .all(16), .expand = .horizontal, .padding = .{ .y = 16, .h = 16 } });

    {
        const world_name_widget = dvui.textEntry(@src(), .{ .placeholder = "World Name" }, .{ .gravity_x = 0.5 });
        defer world_name_widget.deinit();
        if (create) {
            const world_name = world_name_widget.textGet();
            std.log.info("creating world: {any}\n", .{world_name});
            std.fs.cwd().makeDir(self.worlds_path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            var path = try std.fs.cwd().openDir(self.worlds_path, .{});
            defer path.close();
            try path.makeDir(world_name);
            var worldfolder = try path.openDir(world_name, .{});
            defer worldfolder.close();
            const game_path = try std.fs.path.join(allocator, &[_][]const u8{ self.worlds_path, world_name });
            defer allocator.free(game_path);
            try new_world_options.save(game_path);
            try openGame(self.game, allocator, self.window, &self.config.game_config, self.config_lock, game_path, game_render_context);
            self.menu_state.ingame = true;
            self.menu_state.newgame = false;
            return true;
        }
    }
    dvui.structUI(@src(), "World Options", &new_world_options, 32, .{});

    return menuchanged;
}

pub fn mainPage(self: *@This(), allocator: std.mem.Allocator, game_render_context: sdl.video.gl.Context) !bool {
    const menuarea = dvui.overlay(@src(), .{ .expand = .both });
    defer menuarea.deinit();
    //background
    _ = dvui.image(@src(), .{ .source = .{ .imageFile = .{ .bytes = menu_background } }, .shrink = .vertical }, .{ .expand = .both });

    const page = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer page.deinit();

    var changed: bool = self.sidebar();

    const menu = dvui.box(@src(), .{}, .{ .background = false, .color_fill = .{ .r = 24, .g = 24, .b = 24, .a = 255 }, .expand = .both });
    defer menu.deinit();

    const top = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    const terrafinity = dvui.textLayout(@src(), .{ .break_lines = false }, .{ .gravity_x = 0.5, .color_fill = .transparent });

    terrafinity.addText("terrafinity", .{ .font = .{ .size = 64, .family = pixel_font } });
    terrafinity.deinit();
    top.deinit();
    changed |= try self.continueMenu(allocator, game_render_context);
    return changed;
}

pub fn sidebar(self: *@This()) bool {
    const bar = dvui.box(@src(), .{ .dir = .vertical }, .{ .background = true, .color_fill = .{ .r = 48, .g = 77, .b = 48, .a = 225 }, .expand = .vertical, .min_size_content = .width(128) });
    defer bar.deinit();

    if (dvui.button(@src(), "Home", .{}, .{ .gravity_x = 0.5, .color_fill = .blue, .margin = .all(16), .expand = .horizontal, .padding = .{ .y = 16, .h = 16 } })) {
        self.menu_state = .{ .main = true };
        return true;
    }
    if (dvui.button(@src(), "Settings", .{}, .{ .gravity_x = 0.5, .color_fill = .blue, .margin = .all(16), .expand = .horizontal, .padding = .{ .y = 16, .h = 16 } })) {
        self.menu_state = .{ .settings = true };
        return true;
    }
    return false;
}

pub fn continueMenu(self: *@This(), allocator: std.mem.Allocator, game_render_context: sdl.video.gl.Context) !bool {
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

    {
        const new_game = menuCard(@src(), .{}, .{ .expand = .vertical });
        defer new_game.deinit();
        if (dvui.button(@src(), "+", .{}, .{ .expand = .both, .color_fill = .blue, .font = .{ .size = 96, .weight = .bold, .family = comptime sliceToBounded("Vera Sans", 50) } })) {
            self.menu_state = .{ .newgame = true };
            new_world_options = Game.WorldOptions.default;
            return true;
        }
    }
    self.config_lock.lockShared();
    const worlds_path = self.config.worlds_path;
    self.config_lock.unlockShared();
    var worlds_folder: std.fs.Dir = try std.fs.cwd().openDir(worlds_path, .{ .iterate = true });
    defer worlds_folder.close();
    var it = worlds_folder.iterate();
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
            const jpath = try std.fs.path.join(allocator, &[_][]const u8{ self.config.worlds_path, item.name });
            defer allocator.free(jpath);
            try openGame(self.game, allocator, self.window, &self.config.game_config, self.config_lock, jpath, game_render_context); //TODO popup when game cant be opened
            self.menu_state.ingame = true;
            self.menu_state.main = false;
            return true;
        }
    }
    return false;
}

fn openGame(gameptr: *Game, allocator: std.mem.Allocator, window: sdl.video.Window, game_config: *Game.Options, options_lock: *std.Thread.RwLock, folder: []const u8, render_context: sdl.video.gl.Context) !void {
    try render_context.makeCurrent(window);
    try gameptr.init(allocator, game_config, options_lock, folder, window);
    errdefer gameptr.deinit(window);
    try gameptr.startThreads();
    std.log.info("opening game\n", .{});
}

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

pub fn loadFonts(window: *dvui.Window) !void {
    try window.addFont("Press Start 2P", press_start_2p, null);
}

const HoverOptions = struct {
    hover_cursor: ?dvui.enums.Cursor = .hand,
    rect: ?dvui.Rect.Physical = null,
};
