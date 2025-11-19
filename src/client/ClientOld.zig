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
pub const Interpolation = @import("Interpolation");
pub const ThreadPool = @import("ThreadPool");
pub const World = @import("World").World;
pub const zm = @import("zm");
pub const ztracy = @import("ztracy");
const Game = @import("Game.zig").Game;
pub const ChunkManager = @import("ChunkManager.zig").ChunkManager;
pub const Loader = @import("Loader.zig").Loader;
pub const menu = @import("menu.zig");
pub const Renderer = @import("Renderer.zig");
const UserInput = @import("UserInput.zig");

var lastx: f64 = undefined;
var lasty: f64 = undefined;
var cameraFront = @Vector(3, f64){ 0, 1, 0 };
var cameraUp = @Vector(3, f64){ 0, 1, 0 };
var pitch: f64 = 1;
var yaw: f64 = 1;
pub var height: u32 = 900;
pub var width: u32 = 506;

pub fn main() !void {
    var proc: gl.ProcTable = undefined;
    var main_debug_allocator = std.heap.DebugAllocator(.{ .backing_allocator_zeroes = false }).init;
    var secondary_debug_allocator = std.heap.DebugAllocator(.{ .backing_allocator_zeroes = false }).init;
    defer if (main_debug_allocator.deinit() == .leak or secondary_debug_allocator.deinit() == .leak) {
        std.debug.panic("mem leaked", .{});
    } else {
        std.debug.print("no leaks\n", .{});
    };
    const smp_allocator = std.heap.smp_allocator;
    const allocator = if (builtin.mode == .ReleaseFast) smp_allocator else main_debug_allocator.allocator();
    const secondary_allocator = if (builtin.mode == .ReleaseFast) smp_allocator else secondary_debug_allocator.allocator();
    const window = try initWindowAndProcs(&proc);

    var game: Game = undefined;
    try game.init(allocator, secondary_allocator);
    try game.startThreads();
    try EntityTypes.LoadMeshes(allocator);

    defer {
        game.deinit();
        UserInput.deinit();
        EntityTypes.FreeMeshes();
        glfw.terminate();
        window.destroy();
        glfw.pollEvents(); //must be called to close the window
    }

    try UserInput.init(&game, window);
    _ = window.setCursorPosCallback(UserInput.MouseCallback);
    _ = window.setSizeCallback(glfwSizeCallback);
    gui.init(secondary_allocator);
    defer gui.deinit();

    var f3t: bool = true;
    var f3noholdt: bool = true;
    var fpsBox = try gui.Element.create(allocator, menu.fpsoptions);
    const viewport_pixels: @Vector(2, f32) = GetViewportPixels(window);
    const viewport_millimeters: @Vector(2, f32) = @floatFromInt(@as(@Vector(2, i32), try glfw.getPrimaryMonitor().?.getPhysicalSize()));
    fpsBox.init(viewport_pixels, viewport_millimeters);
    defer fpsBox.deinit();
    var lastFps: ?f128 = null;
    while (!window.shouldClose()) {
        const Frame = ztracy.ZoneNC(@src(), "Frame", 0xFFFFFFFF);
        defer Frame.End();
        const frameStart = std.time.nanoTimestamp();
        const waitforlock = ztracy.ZoneNC(@src(), "waitforlock", 2222111);
        const playerPos = game.player.GetPos().?;
        waitforlock.End();
        const viewport_pixels_loop: @Vector(2, f32) = GetViewportPixels(window);
        const viewport_millimeters_loop: @Vector(2, f32) = @floatFromInt(@as(@Vector(2, i32), try glfw.getPrimaryMonitor().?.getPhysicalSize()));
        const drawn = try game.renderer.Draw(&game, viewport_pixels_loop);
        if (f3t) fpsBox.Draw(viewport_pixels_loop, viewport_millimeters_loop, window);
        UserInput.menuDraw(viewport_pixels_loop, viewport_millimeters_loop, window);
        const drawText = ztracy.ZoneNC(@src(), "DrawLargeText", 24342);
        drawText.End();
        //unload meshes
        const swap = ztracy.ZoneNC(@src(), "swap", 456564);
        window.swapBuffers();
        swap.End();
        const poll = ztracy.ZoneNC(@src(), "poll", 456564);
        glfw.pollEvents();
        poll.End();
        const prossesinput = ztracy.ZoneNC(@src(), "prossesinput", 456765);
        try UserInput.processInput(window);
        if (glfw.getKey(window, glfw.Key.F3) == .press) {
            if (f3noholdt) f3t = !f3t;
            f3noholdt = false;
        } else f3noholdt = true; //TODO use this toggle type for fullscreen and other toggle settings
        prossesinput.End();
        var fps = (std.time.ns_per_s / @as(f128, @floatFromInt(std.time.nanoTimestamp() - frameStart)));
        if (lastFps != null) fps = std.math.lerp(fps, lastFps.?, 0.90);
        lastFps = fps;
        const printpos = @round(playerPos * @Vector(3, f64){ 100, 100, 100 }) / @Vector(3, f64){ 100, 100, 100 };
        const printText = try std.fmt.allocPrint(secondary_allocator, "pos: {d}, {d}, {d}\nFPS: {d}\n{d}/{d} chunks drawn\ntotal chunks loaded: {d}\nwidth: {d}, heeight: {d}\n", .{ printpos[0], printpos[1], printpos[2], @round(fps), drawn[0], drawn[1], game.world.Chunks.count(), width, height });
        defer secondary_allocator.free(printText);
        try fpsBox.options.text.?.SetText(printText);
    }
}

fn processInput(window: *glfw.Window, cameraPos: *@Vector(3, f64), camerafront: @Vector(3, f64), cameraup: @Vector(3, f64)) void {
    const cameraSpeed: @Vector(3, f64) = @splat(2); // adjust accordingly
    if (window.getKey(glfw.Key.w) == .press)
        cameraPos.* += cameraSpeed * camerafront;
    if (window.getKey(glfw.Key.s) == .press)
        cameraPos.* -= cameraSpeed * camerafront;
    if (window.getKey(glfw.Key.a) == .press)
        cameraPos.* -= zm.vec.normalize(zm.vec.cross(camerafront, cameraup)) * cameraSpeed;
    if (window.getKey(glfw.Key.d) == .press)
        cameraPos.* += zm.vec.normalize(zm.vec.cross(camerafront, cameraup)) * cameraSpeed;
}

fn onHover(element: *gui.Element, mouse_pos: [2]f64, window: *glfw.Window, toggle: bool) void {
    _ = mouse_pos;
    if (!element.options.Visible) return;
    if (toggle) {
        if (window.getMouseButton(glfw.MouseButton.left) == .press) {
            //  element.options.size.widthPixels = 1;
            element.options.size.heightPixels += 16;
            element.options.position.yPixels += 8;
            element.update(element.screen_dimensions);
        }
    }
}

fn deflateElement(element: *gui.Element, window: *glfw.Window) void {
    if (!element.options.Visible) return;
    const time = std.time.timestamp();
    const eid = (element.options.position.xPercent * 10 * 0.5);
    if (@rem(time, 5) == @as(i64, @intFromFloat((eid))) and window.getKey(glfw.Key.m) == .press) {
        element.options.size.heightPixels += 2;
        element.options.position.yPixels += 1;
        element.update(element.screen_dimensions);
    }
    const wp = element.options.size.widthPixels;
    const hp = element.options.size.heightPixels;
    const yp = element.options.position.yPixels;
    element.options.size.widthPixels = std.math.lerp(element.options.size.widthPixels, -10, 0.01);
    element.options.size.heightPixels = std.math.lerp(element.options.size.heightPixels, -10, 0.001);
    element.options.position.yPixels = std.math.lerp(element.options.position.yPixels, 0, 0.001);
    if (wp != element.options.size.widthPixels or hp != element.options.size.heightPixels or yp != element.options.position.yPixels) element.update(element.screen_dimensions);
}

fn initWindowAndProcs(proc_table: *gl.ProcTable) !*glfw.Window {
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
        window = glfw.Window.create(@intCast(width), @intCast(height), "terrafinity", null) catch continue;
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
    gl.Enable(gl.MULTISAMPLE);
    gl.Viewport(0, 0, @intFromFloat(@as(f32, @floatFromInt(width)) * xz[0]), @intFromFloat(@as(f32, @floatFromInt(height)) * xz[1]));
    glfw.swapInterval(0);
    gl.Enable(gl.DEPTH_TEST);
    gl.Enable(gl.CULL_FACE);
    gl.CullFace(gl.BACK);
    gl.FrontFace(gl.CW);
    gl.DepthFunc(gl.LESS);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    return window.?;
}

pub export fn glfwSizeCallback(window: *glfw.Window, w: c_int, h: c_int) void {
    width = @intCast(w);
    height = @intCast(h);
    const xz = window.getContentScale();
    gl.Viewport(0, 0, @intFromFloat(@as(f32, @floatFromInt(w)) * xz[0]), @intFromFloat(@as(f32, @floatFromInt(h)) * xz[1]));
}

pub fn GetViewportPixels(window: *glfw.Window) @Vector(2, f32) {
    return @Vector(2, f32){ (@as(f32, @floatFromInt(width)) * window.getContentScale()[0]), (@as(f32, @floatFromInt(height)) * window.getContentScale()[1]) };
}
