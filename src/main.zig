const std = @import("std");
const builtin = @import("builtin");

const EntityTypes = @import("world/EntityTypes.zig");
pub const Block = @import("world/Block.zig").Block;
pub const Cache = @import("Cache").Cache;
pub const Chunk = @import("world/Chunk.zig");
pub const ChunkSize = Chunk.ChunkSize;
pub const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
pub const Entity = @import("world/Entity.zig");
const wio = @import("wio");
pub const World = @import("world/World.zig");
pub const zm = @import("zm");
pub const ztracy = @import("ztracy");
const Ui = @import("Ui.zig");
const Game = @import("Game.zig");
const dvui = @import("dvui");
const Key = @import("Key.zig");
const utils = @import("libs/utils.zig");

pub fn main(init: std.process.Init) !void {
    var running: std.atomic.Value(bool) = .init(true);

    var tracy_allocator = ztracy.TracyAllocator.init(init.gpa);
    const allocator = tracy_allocator.allocator();
    const io = init.io;

    //TODO make this an argument once std.cli is added
    const config_path: []const u8 = "Config.zon";
    const worlds_path: []const u8 = "worlds";


    var config_lock: std.Io.RwLock = .init;

    var config: Config = try .load(allocator, io, config_path);
    defer config.deinit(allocator);

    try config.save(io, config_path, &config_lock); //save the config to format it or create it if it dident exist
    
    try wio.init(allocator, io, .{});
    defer wio.deinit();
    

    var window = try wio.createWindow(.{ .title = "terrafinity" });
    defer window.destroy();
    
    //var ui_context = try window.glCreateContext(.{ .major_version = 4, .minor_version = 5, .forward_compatible = true});
    //defer ui_context.destroy();
    //window.glMakeContextCurrent(&ui_context);


    var keymap = Key.Map.init(allocator);
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
    try game.init(io, allocator, &config.game_config, &config_lock, worlds_path, &window);
    var ui: Ui = .{
        .window = &window,
        .config = &config,
        .config_lock = &config_lock,
        .game = &game,
        .menu_state = .{ .main = true },
        .config_path = config_path,
        .worlds_path = worlds_path,
    };

    defer if (ui.menu_state.ingame) game.deinit(io);
    var frame_time: std.Io.Timestamp = .now(io, .awake);
    var action_set = Key.ActionSet.empty;
    while (running.load(.unordered)) {
        window.setMode(if (ui.menu_state.playingGame()) .fullscreen else .normal);
        if (action_set.contains(.escape_menu)) ui.menu_state.handleEsc();
        const dt = frame_time.untilNow(io, .awake);
        frame_time = .now(io, .awake);
        const ms: [3]u32 = .{ 0, 0 , 0};
        if (ui.menu_state.ingame) {
            const ig = ztracy.ZoneN(@src(), "ingame");
            defer ig.End();
            const mouse_moved = (ms[1] != 0 or ms[2] != 0);
            if (ui.menu_state.playingGame() and mouse_moved) game.handleMouseMotion(.{ ms[1], ms[2] }, game.getMouseSensitivity(io));
            try game.handleButtonActions(io, action_set, dt);
                const size = @Vector(2, usize){640, 480};

            try game.frame(io, allocator, @intCast(@as(@Vector(2, usize), size)));
        }
        const dw = ztracy.ZoneN(@src(), "draw ui");
        dw.End();
        const sf = ztracy.ZoneN(@src(), "sdl flush");
        sf.End();
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

fn sdlErr(
    err: ?[]const u8,
) void {
    if (err) |val| {
        std.log.err("******* [Error! {s}] *******\n", .{val});
    } else {
        std.log.err("******* [Unknown Error!] *******\n", .{});
    }
}

test {
    std.testing.refAllDecls(@This());
}
