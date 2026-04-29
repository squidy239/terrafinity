const std = @import("std");
const builtin = @import("builtin");

const EntityTypes = @import("world/EntityTypes.zig");
pub const Block = @import("world/Block.zig").Block;
pub const Cache = @import("Cache").Cache;
pub const Chunk = @import("world/Chunk.zig");
pub const ChunkSize = Chunk.ChunkSize;
pub const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
pub const Entity = @import("world/Entity.zig");
pub const World = @import("world/World.zig");
pub const zm = @import("zm");
pub const ztracy = @import("ztracy");
const Ui = @import("Ui.zig");
const Game = @import("Game.zig");
const dvui = @import("dvui");
const Key = @import("Key.zig");
const utils = @import("libs/utils.zig");
const wio_backend = @import("wio-backend");
const wio = @import("wio");
const gl = @import("gl");

pub fn main(init: std.process.Init) !void {
    var running: std.atomic.Value(bool) = .init(true);

    var tracy_allocator = ztracy.TracyAllocator.init(init.gpa);

    const gpa = tracy_allocator.allocator();
    const io = init.io;

    //TODO make this an argument once std.cli is added
    const config_path: []const u8 = "Config.zon";
    const worlds_path: []const u8 = "worlds";

    var config_lock: std.Io.RwLock = .init;

    var config: Config = try .load(gpa, io, config_path);
    defer config.deinit(gpa);

    try config.save(io, config_path, &config_lock); //save the config to format it or create it if it dident exist

    try wio.init(gpa, io, .{});
    defer wio.deinit();

    const gloptions: wio.GlOptions = .{
        .major_version = 4,
        .minor_version = 5,
        .profile = .core,
        .forward_compatible = true,
        .debug = builtin.mode == .Debug,
        .samples = 4,
        .alpha_bits = 0,
    };

    var window = try wio.createWindow(.{ .title = "terrafinity", .gl_options = gloptions });
    defer window.destroy();

    window.setMode(.maximized);

    var ui_context = try window.glCreateContext(.{ .options = gloptions });
    defer ui_context.destroy();
    window.glMakeContextCurrent(ui_context);

    var proc_table: gl.ProcTable = undefined;
    if (!gl.ProcTable.init(&proc_table, wio.glGetProcAddress))
        return error.FailedToInitProcTable;
    gl.makeProcTableCurrent(&proc_table);
    setCallback();

    var backend = try wio_backend.init(.{ .io = io, .window = window });
    defer backend.deinit();

    var render_backend = try dvui.render_backend.init(gpa, wio.glGetProcAddress, "450");
    defer render_backend.deinit();

    var ui_window = try dvui.Window.init(@src(), gpa, backend.backend(&render_backend), .{});
    defer ui_window.deinit();

    try Ui.loadFonts(&ui_window);

    var keymap = Key.Map.init(gpa);
    defer keymap.map.deinit();

    var singlepress = Key.Singlepress.empty;
    //TODO load keymap from file
    try keymap.setActionKey(io, .{ .key = .escape }, .escape_menu);
    try keymap.setActionKey(io, .{ .key = .left_gui }, .escape_menu);

    singlepress.insert(.escape_menu);

    try keymap.setActionKey(io, .{ .key = .w }, .forward);
    try keymap.setActionKey(io, .{ .key = .s }, .backward);
    try keymap.setActionKey(io, .{ .key = .a }, .left);
    try keymap.setActionKey(io, .{ .key = .d }, .right);
    try keymap.setActionKey(io, .{ .key = .space }, .up);
    try keymap.setActionKey(io, .{ .key = .left_shift }, .down);
    try keymap.setActionKey(io, .{ .key = .f }, .use_item_primary);

    var game: Game = undefined;

    var ui: Ui = .{
        .proc_table = &proc_table,
        .window = &window,
        .config = &config,
        .config_lock = &config_lock,
        .game = &game,
        .menu_state = .{ .main = true },
        .config_path = config_path,
        .worlds_path = worlds_path,
        .ui_context = &ui_context,
        .gloptions = gloptions,
    };

    defer if (ui.menu_state.ingame) game.deinit(io);
    var frame_time: std.Io.Timestamp = .now(io, .awake);
    var action_set = Key.ActionSet.empty;
    while (running.load(.unordered)) {
        wio.update();
        try handleEvents(io, &keymap, singlepress, &action_set, &running, &backend, &window, &ui_window, &ui, frame_time.untilNow(io, .awake));
        if (action_set.contains(.escape_menu)) ui.menu_state.handleEsc();
        frame_time = .now(io, .awake);
        if (ui.menu_state.ingame) {
            try game.frame(io, gpa);
            window.glMakeContextCurrent(ui_context);
        }
        {
            const dw = ztracy.ZoneN(@src(), "draw ui");
            defer dw.End();
            window.glMakeContextCurrent(ui_context);
            try ui_window.begin(std.Io.Timestamp.now(io, .awake).toNanoseconds());
            var menuchanged: bool = false;
            {
                const ov = dvui.overlay(@src(), .{ .expand = .both });
                defer ov.deinit();

                if (ui.menu_state.debug_info and ui.menu_state.ingame and !menuchanged) try ui.debugInfo(io);
                if (ui.menu_state.esc and !menuchanged) menuchanged = try ui.escMenu(io);
                if (ui.menu_state.main and !menuchanged) menuchanged = ui.mainPage(io, gpa) catch |err| err: {
                    var error_buffer: [65536]u8 = undefined;
                    var error_writer: std.Io.Writer = .fixed(&error_buffer);

                    switch (err) {
                        error.RocksDBOpen => error_writer.print("World is already open in another instance.", .{}) catch unreachable,
                        error.OutOfMemory => error_writer.print("Out of memory.", .{}) catch unreachable,
                        error.ParseZon => error_writer.print("A ZON file in this world has an invalid format.", .{}) catch unreachable,
                        else => error_writer.print("{any}", .{err}) catch unreachable,
                    }

                    dvui.dialog(@src(), frame_time, .{ .message = error_writer.buffered(), .title = "                There was a problem opening the world                " });
                    break :err false;
                };
                if (ui.menu_state.settings and !menuchanged) menuchanged = try ui.settingsMenu(io);
                if (ui.menu_state.newgame and !menuchanged) menuchanged = try ui.newGameMenu(io, gpa);
            }
            _ = try ui_window.end(.{});
        }

        const sw = ztracy.ZoneN(@src(), "swap");
        window.glSwapBuffers();
        sw.End();
        ztracy.FrameMark();
    }
}

test {
    std.testing.refAllDecls(@This());
}

///must be locked by the caller
pub const Config = struct {
    game_config: Game.Options = .{},

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
        const configFile: ?std.Io.File = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .lock = .shared }) catch |err| sw: switch (err) {
            error.FileNotFound => {
                std.log.info("Config file not found, creating default config file", .{});
                break :sw null;
            },
            else => return err,
        };
        defer if (configFile) |file| file.close(io);
        var config: Config = undefined;
        config = if (configFile) |file| try utils.loadZON(Config, io, file, allocator, allocator) else .{};

        return config;
    }

    pub fn save(self: *const Config, io: std.Io, path: []const u8, config_lock: ?*std.Io.RwLock) !void {
        const configFile = try std.Io.Dir.cwd().createFile(io, path, .{ .lock = .exclusive });
        defer configFile.close(io);
        var buffer: [512]u8 = undefined;
        var filewriter = configFile.writer(io, &buffer);
        {
            if (config_lock) |lock| lock.lockSharedUncancelable(io);
            defer if (config_lock) |lock| lock.unlockShared(io);
            try std.zon.stringify.serialize(self, .{}, &filewriter.interface);
        }
        try filewriter.end();
    }

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        std.zon.parse.free(allocator, self.*);
    }

    pub const structui_options: dvui.struct_ui.StructOptions(@This()) = .initWithDefaults(.{}, null);
};

var window_size: wio.Size = .{ .height = 480, .width = 640 };
fn handleEvents(
    io: std.Io,
    key_map: *Key.Map,
    singlepress: Key.Singlepress,
    action_set: *Key.ActionSet,
    running: *std.atomic.Value(bool),
    ui_backend: *wio_backend,
    win: *wio.Window,
    ui_window: *dvui.Window,
    ui: *Ui,
    dt: std.Io.Duration,
) !void {
    ui_backend.setTextInputRect(ui_window.textInputRequested());
    if (ui.menu_state.playingGame()) {
        win.setCursorMode(.relative);
    } else {
        win.setCursorMode(.normal);
        ui_backend.setCursor(ui_window.cursorRequested());
    }

    //set all single press buttons like escape to false
    var it = action_set.iterator();
    while (it.next()) |action| {
        if (singlepress.contains(action)) action_set.remove(action);
    }
    while (win.getEvent()) |event| {
        _ = try ui_backend.addEvent(ui_window, event);
        switch (event) {
            .button_press => |key| {
                const action = key_map.getAction(io, Key.Key{ .key = key }) orelse continue;
                action_set.insert(action);
            },
            .button_release => |key| {
                const action = key_map.getAction(io, Key.Key{ .key = key }) orelse continue;
                action_set.remove(action);
            },
            .close => {
                running.store(false, .unordered);
            },
            .scroll_vertical => |scroll| {
                if (ui.menu_state.ingame) try ui.game.handleScroll(io, scroll);
            },
            .mouse_relative => |mouse| {
                const mouse_moved = (mouse.x != 0 or mouse.y != 0);
                if (ui.menu_state.ingame and mouse_moved) ui.game.handleMouseMotion(mouse, ui.game.getMouseSensitivity(io));
            },
            .size_physical => |size| {
                window_size = size;
            },
            else => {},
        }
    }
    if (ui.menu_state.ingame) try ui.game.renderer.setViewport(.{ window_size.width, window_size.height });
    if (ui.menu_state.ingame) try ui.game.handleButtonActions(io, action_set, dt);
}

pub fn setCallback() void {
    switch (builtin.mode) {
        .Debug, .ReleaseSafe => {},
        .ReleaseFast, .ReleaseSmall => return,
    }
    gl.Enable(gl.DEBUG_OUTPUT);
    gl.DebugMessageCallback(glCallback, null);
}

fn glCallback(source: gl.@"enum", kind: gl.@"enum", id: gl.uint, severity: gl.@"enum", length: gl.sizei, message: [*:0]const u8, userParam: ?*const anyopaque) callconv(.c) void {
    _ = kind;
    _ = id;
    _ = userParam;
    switch (severity) {
        gl.DEBUG_SEVERITY_NOTIFICATION => return,
        gl.DEBUG_SEVERITY_HIGH => std.debug.panic("{d}: {s}", .{ source, message[0..@intCast(length)] }),
        gl.DEBUG_SEVERITY_MEDIUM => std.log.warn("{d}: {s}", .{ source, message[0..@intCast(length)] }),
        gl.DEBUG_SEVERITY_LOW => std.log.info("{d}: {s}", .{ source, message[0..@intCast(length)] }),
        else => unreachable,
    }
}
