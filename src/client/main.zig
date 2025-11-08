const std = @import("std");
const builtin = @import("builtin");

pub const Block = @import("Block").Blocks;
pub const Cache = @import("Cache").Cache;
pub const Chunk = @import("Chunk").Chunk;
const ChunkSize = Chunk.ChunkSize;
pub const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
pub const ConcurrentQueue = @import("ConcurrentQueue");
const Entity = @import("Entity").Entity;
const EntityTypes = @import("EntityTypes");
const gl = @import("gl");
const glfw = @import("zglfw");
pub const gui = @import("gui");
pub const SetThreadPriority = @import("ThreadPriority").setThreadPriority;
pub const ThreadPool = @import("ThreadPool");
const UpdateEntitiesThread = @import("Entity").TickEntitiesThread;
pub const World = @import("World").World;
pub const zm = @import("zm");
pub const ztracy = @import("ztracy");

pub const menu = @import("menu.zig");
pub const Renderer = @import("Renderer.zig").Renderer;
const UserInput = @import("UserInput.zig");

var lastx: f64 = undefined;
var lasty: f64 = undefined;
var cameraFront = @Vector(3, f64){ 0, 1, 0 };
var cameraUp = @Vector(3, f64){ 0, 1, 0 };
var pitch: f64 = 1;
var yaw: f64 = 1;
var height: u32 = 800;
var width: u32 = 600;

var mainMenu: gui.Element = undefined;
var optionsMenu: gui.Element = undefined;

var currentMenuPage: menuPage = undefined;

var currentMenu: ?*gui.Element = undefined;
var currentRenderer: ?Renderer = undefined;
var currentWorld: ?World = undefined;

var running = std.atomic.Value(bool).init(true);

fn InitWindowAndProcs(proc_table: *gl.ProcTable) !*glfw.Window {
    //try glfw.initHint(.platform, glfw.Platform.x11); //renderdoc wont work with wayland
    try glfw.init();
    std.debug.print("using: {s}\n", .{@tagName(glfw.getPlatform())});
    const gl_versions = [_][2]c_int{ [2]c_int{ 4, 6 }, [2]c_int{ 4, 5 }, [2]c_int{ 4, 4 }, [2]c_int{ 4, 3 }, [2]c_int{ 4, 2 }, [2]c_int{ 4, 1 }, [2]c_int{ 4, 0 }, [2]c_int{ 3, 3 } };
    var window: ?*glfw.Window = null;
    for (gl_versions) |version| {
        std.log.info("trying OpenGL version {d}.{d}\n", .{ version[0], version[1] });
        glfw.windowHint(.context_version_major, version[0]);
        glfw.windowHint(.context_version_minor, version[1]);
        glfw.windowHint(.opengl_forward_compat, true);
        glfw.windowHint(.client_api, .opengl_api);
        glfw.windowHint(.doublebuffer, true);
        glfw.windowHint(.samples, 8);
        window = glfw.Window.create(@intCast(width), @intCast(height), "voxelgame", null) catch continue;
        glfw.makeContextCurrent(window);
        if (proc_table.init(glfw.getProcAddress)) {
            std.log.info("using OpenGL version {d}.{d}\n", .{ version[0], version[1] });
            break;
        } else {
            window.?.destroy();
        }
    }
    if (window == null) return error.FailedToCreateWindow;
    gl.makeProcTableCurrent(proc_table);
    const xz = window.?.getContentScale();
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
    return window.?;
}

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{ .backing_allocator_zeroes = false }).init;
    const allocator = debug_allocator.allocator();
    defer if (debug_allocator.deinit() == .leak) std.log.err("mem leaked", .{});
    var proc: gl.ProcTable = undefined;
    const window = try InitWindowAndProcs(&proc);
    _ = window.setSizeCallback(glfwSizeCallback);
    gui.init(allocator);
    defer gui.deinit();
    mainMenu = try gui.Element.create(allocator, menu.mainMenu);
    mainMenu.init(GetViewportPixels(window), @as(@Vector(2, f32), @floatFromInt(try GetViewportMillimeters(window))));
    defer mainMenu.deinit();

    optionsMenu = try gui.Element.create(allocator, menu.optionsMenu);
    optionsMenu.init(GetViewportPixels(window), @as(@Vector(2, f32), @floatFromInt(try GetViewportMillimeters(window))));
    defer optionsMenu.deinit();

    currentMenu = &mainMenu;
    currentMenu = currentMenu;
    defer {
        window.destroy();
        glfw.pollEvents();
    }
    while (window.shouldClose() == false) {
        const viewport_pixels = GetViewportPixels(window);
        const viewport_millimeters: [2]f32 = @as(@Vector(2, f32), @floatFromInt(try GetViewportMillimeters(window)));
        if (currentMenu != null) currentMenu.?.Draw(viewport_pixels, viewport_millimeters, window);
        window.swapBuffers();
        glfw.pollEvents();
    }
}

pub export fn glfwSizeCallback(window: *glfw.Window, w: c_int, h: c_int) void {
    width = @intCast(w);
    height = @intCast(h);
    const xz = window.getContentScale();
    gl.Viewport(0, 0, @intFromFloat(@as(f32, @floatFromInt(width)) * xz[0]), @intFromFloat(@as(f32, @floatFromInt(height)) * xz[1]));
}

pub fn GetViewportPixels(window: *glfw.Window) @Vector(2, f32) {
    return @Vector(2, f32){ (@as(f32, @floatFromInt(width)) * window.getContentScale()[0]), (@as(f32, @floatFromInt(height)) * window.getContentScale()[1]) };
}

pub fn GetViewportMillimeters(window: *glfw.Window) !@Vector(2, i32) {
    _ = window;
    return @as(@Vector(2, i32), (try glfw.getPrimaryMonitor().?.getPhysicalSize()));
}

const menuPage = enum {
    mainMenu,
    optionsMenu,
    worldRender,
};

pub fn SwitchMenu(newMenu: menuPage) void {
    std.debug.assert(currentMenuPage != newMenu);
    std.debug.assert((currentRenderer == null and currentWorld == null) or currentMenuPage == .worldRender);
    currentMenu = switch (newMenu) {
        .mainMenu => &mainMenu,
        .optionsMenu => &optionsMenu,
        .worldRender => null,
    };
    currentMenuPage = newMenu;
}

pub fn CreateRenderer() !void {}
