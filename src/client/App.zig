const std = @import("std");
const builtin = @import("builtin");

const EntityTypes = @import("EntityTypes");
const gl = @import("gl");
const glfw = @import("zglfw");
pub const Block = @import("Chunk").Block;
pub const Cache = @import("Cache").Cache;
pub const Chunk = @import("Chunk").Chunk;
pub const rocksdb = @import("rocksdb");
const ChunkSize = Chunk.ChunkSize;
pub const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
pub const ConcurrentQueue = @import("ConcurrentQueue");
const Entity = @import("Entity").Entity;
pub const gui = @import("gui");
pub const ThreadPool = @import("ThreadPool");
pub const Loader = @import("Loader.zig");
pub const ChunkManager = @import("ChunkManager.zig").ChunkManager;

pub const World = @import("World");
pub const Interpolation = @import("Interpolation");
pub const zm = @import("zm");
pub const ztracy = @import("ztracy");
const Game = @import("Game.zig");
pub const menu = @import("menu.zig");
pub const Renderer = @import("Renderer.zig");
const UserInput = @import("UserInput.zig");

var lastx: f64 = undefined;
var lasty: f64 = undefined;
var cameraFront = @Vector(3, f64){ 0, 1, 0 };
var cameraUp = @Vector(3, f64){ 0, 1, 0 };
var pitch: f64 = 1;
var yaw: f64 = 1;
pub var height: u32 = 800;
pub var width: u32 = 600;

var mainMenu: gui.Element = undefined;
var optionsMenu: gui.Element = undefined;

var currentMenuPage: menuPage = .mainMenu;

var currentMenu: ?*gui.Element = undefined;
var window: *glfw.Window = undefined;

var primary_allocator: std.mem.Allocator = undefined;
var secondary_allocator: std.mem.Allocator = undefined;

var game: ?Game.Game = null;

fn InitWindowAndProcs(proc_table: *gl.ProcTable) !void {
    //try glfw.initHint(.platform, glfw.Platform.x11); //renderdoc wont work with wayland
    try glfw.init();
    var createdWindow: ?*glfw.Window = null;
    std.debug.print("using: {s}\n", .{@tagName(glfw.getPlatform())});
    const gl_versions = [_][2]c_int{ [2]c_int{ 4, 6 }, [2]c_int{ 4, 5 }, [2]c_int{ 4, 4 }, [2]c_int{ 4, 3 }, [2]c_int{ 4, 2 }, [2]c_int{ 4, 1 }, [2]c_int{ 4, 0 }, [2]c_int{ 3, 3 } };
    for (gl_versions) |version| {
        std.log.info("trying OpenGL version {d}.{d}\n", .{ version[0], version[1] });
        glfw.windowHint(.context_version_major, version[0]);
        glfw.windowHint(.context_version_minor, version[1]);
        glfw.windowHint(.opengl_forward_compat, true);
        glfw.windowHint(.client_api, .opengl_api);
        glfw.windowHint(.doublebuffer, true);
        glfw.windowHint(.samples, 8);
        createdWindow = glfw.Window.create(@intCast(width), @intCast(height), "terrafinity", null) catch continue;
        glfw.makeContextCurrent(createdWindow.?);
        if (proc_table.init(glfw.getProcAddress)) {
            std.log.info("using OpenGL version {d}.{d}\n", .{ version[0], version[1] });
            break;
        } else {
            createdWindow.?.destroy();
        }
    }
    if (createdWindow == null) return error.FailedToCreateWindow;
    gl.makeProcTableCurrent(proc_table);
    const xz = createdWindow.?.getContentScale();
    gl.Viewport(0, 0, @intFromFloat(@as(f32, @floatFromInt(width)) * xz[0]), @intFromFloat(@as(f32, @floatFromInt(height)) * xz[1]));
    glfw.swapInterval(0);
    gl.Enable(gl.MULTISAMPLE);
    gl.Enable(gl.DEPTH_TEST);
    gl.Enable(gl.CULL_FACE);
    gl.CullFace(gl.BACK);
    gl.FrontFace(gl.CW);
    gl.DepthFunc(gl.LESS);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    window = createdWindow.?;
}

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{ .backing_allocator_zeroes = false }).init;
    primary_allocator = debug_allocator.allocator();
    secondary_allocator = primary_allocator;
    defer if (debug_allocator.deinit() == .leak) std.log.err("mem leaked", .{});
    var proc: gl.ProcTable = undefined;
    try InitWindowAndProcs(&proc);
    _ = window.setSizeCallback(glfwSizeCallback);
    gui.init(secondary_allocator);
    defer gui.deinit();
    mainMenu = try gui.Element.create(secondary_allocator, menu.mainMenu);
    mainMenu.init(GetViewportPixels(window), @as(@Vector(2, f32), @floatFromInt(try GetViewportMillimeters(window))));
    defer mainMenu.deinit();

    optionsMenu = try gui.Element.create(secondary_allocator, menu.optionsMenu);
    optionsMenu.init(GetViewportPixels(window), @as(@Vector(2, f32), @floatFromInt(try GetViewportMillimeters(window))));
    defer optionsMenu.deinit();

    currentMenu = &mainMenu;

    try EntityTypes.LoadMeshes(secondary_allocator);

    defer {
        if (game != null) {
            game.?.deinit(window);
            game = null;
        }
        EntityTypes.FreeMeshes();
        window.destroy();
        glfw.pollEvents();
    }
    while (window.shouldClose() == false) {
        const viewport_pixels = GetViewportPixels(window);
        const viewport_millimeters: [2]f32 = @as(@Vector(2, f32), @floatFromInt(try GetViewportMillimeters(window)));
        if (game != null) {
            _ = try game.?.Frame(viewport_pixels, viewport_millimeters, window);
        }
        if (currentMenu) |m| {
            m.Draw(viewport_pixels, viewport_millimeters, window);
        }

        window.swapBuffers();
        glfw.pollEvents();
    }
}

pub export fn glfwSizeCallback(windoww: *glfw.Window, w: c_int, h: c_int) void {
    width = @intCast(w);
    height = @intCast(h);
    const xz = windoww.getContentScale();
    gl.Viewport(0, 0, @intFromFloat(@as(f32, @floatFromInt(width)) * xz[0]), @intFromFloat(@as(f32, @floatFromInt(height)) * xz[1]));
}

pub fn GetViewportPixels(windoww: *glfw.Window) @Vector(2, f32) {
    return @Vector(2, f32){ (@as(f32, @floatFromInt(width)) * windoww.getContentScale()[0]), (@as(f32, @floatFromInt(height)) * windoww.getContentScale()[1]) };
}

pub fn GetViewportMillimeters(windoww: *glfw.Window) !@Vector(2, i32) {
    _ = windoww;
    return @as(@Vector(2, i32), (try glfw.getPrimaryMonitor().?.getPhysicalSize()));
}

const menuPage = enum {
    mainMenu,
    optionsMenu,
    worldRender,
};

pub fn SwitchMenu(newMenu: menuPage) !void {
    std.log.debug("switching menu page from: {any} to {any}", .{ currentMenuPage, newMenu });
    std.debug.assert(currentMenuPage != newMenu);
    std.debug.assert((game == null) or currentMenuPage == .worldRender);
    currentMenu = switch (newMenu) {
        .mainMenu => &mainMenu,
        .optionsMenu => &optionsMenu,
        .worldRender => null,
    };
    if (newMenu == .worldRender) {
        std.debug.assert(game == null);
        game = .{
            .allocator = undefined,
            .world = undefined,
            .chunk_timeout = undefined,
            .player = undefined,
            .pool = undefined,
            .chunkManager = undefined,
            .GenerateDistance = undefined,
            .renderer = undefined,
            .generator = undefined,
            .game_arena = undefined,
            .loaderThread = undefined,
            .unloaderThread = undefined,
            .levels = undefined,
            .running = undefined,
            .region_storage = undefined,
        };
        std.fs.cwd().makeDir("test_world") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        try game.?.init(primary_allocator, secondary_allocator, window, try std.fs.cwd().openDir("test_world", .{ .iterate = true }));
        try game.?.startThreads();
    }
    currentMenuPage = newMenu;
}
