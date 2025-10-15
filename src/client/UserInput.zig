const std = @import("std");
const gl = @import("gl");
const glfw = @import("zglfw");
const ztracy = @import("ztracy");
const zm = @import("zm");
const Renderer = @import("Renderer.zig").Renderer;
const World = @import("root").World;
const ChunkSize = @import("Chunk").Chunk.ChunkSize;
const gui = @import("gui");
var render: *Renderer = undefined;
var worldEditor: World.WorldEditor = undefined;
var last_mouse_pos: [2]f64 = [2]f64{ 0, 0 };
var isinit = false;
var menu: gui.Element = undefined;
var lastmicrotime: i64 = 0;
var lastfullscreentoggle: i64 = 0;
var benchmarkStartTime: i64 = 0;
pub fn init(ren: *Renderer) !void {
    render = ren;
    worldEditor = try World.WorldEditor.init(render.world, render, null, null, render.allocator);
    lastmicrotime = std.time.microTimestamp();
    //menu is temporay test code 
    menu = try gui.Element.create(std.heap.c_allocator, render.screen_dimensions, textEscMenu, &.{try gui.Element.create(std.heap.c_allocator, [2]u32{800,600} , textEscMenuButton, null),try gui.Element.create(std.heap.c_allocator, [2]u32{800,600} , textContinueMenuButton, null),}); 
    menu.init();
    isinit = true;
}

pub fn deinit() void {
    _ = worldEditor.deinit();
    menu.deinit();
    isinit = false;
}

fn onHoverEsc(element: *gui.Element, mouse_pos: [2]f64, window: *glfw.Window, toggle: bool) void {
    _ = element;
    _ = mouse_pos;
    if(toggle and window.getMouseButton(glfw.MouseButton.left) == .press){
        std.debug.print("quitting\n", .{});
        window.setShouldClose(true);
    }
}

fn onHoverC(element: *gui.Element, mouse_pos: [2]f64, window: *glfw.Window, toggle: bool) void {
    _ = element;
    _ = mouse_pos;
    if (toggle and window.getMouseButton(glfw.MouseButton.left) == .press) {
        if (ts.CursorEscaped) {
            ts.CursorEscaped = false;
            _ = glfw.Window.setInputMode(render.window, glfw.InputMode.cursor, glfw.InputMode.ValueType(glfw.InputMode.cursor).disabled) catch std.debug.panic("err cant set input mode\n", .{});
        }
    }
}

const ToggleSettings = struct {
    Fullscreen: bool,
    Sprinting: bool,
    SuperSpeed: bool,
    CursorEscaped: bool,
    Benchmark: bool,
};
var ts = ToggleSettings{
    .Fullscreen = false,
    .Sprinting = false,
    .SuperSpeed = false,
    .CursorEscaped = true,
    .Benchmark = false,
};

const textEscMenu = gui.Element.CreationOptions{
    .elementBackground = .{ .solid = .{ 0.8, 0.8, 0.8, 0.95 } },
    .position = .{ .xPercent = 50, .yPercent = 50 },
    .size = .{
        .widthPercent = 75,
        .heightPercent = 75,
    },
};

const textEscMenuButton = gui.Element.CreationOptions{
    .elementBackground = .{ .solid = .{ 0.8, 0.3, 0.3, 1 } },
    .position = .{ .xPercent = 50, .yPercent = 60 },
    .size = .{
        .widthPercent = 60,
        .heightPercent = 10,
    },
    .textOptions = .{
        .text = "Quit",
        .scale = .{ .relative = 4 },
        .startPosition = .{
            .xPercent = 45,
            .yPercent = 100,
        },
    },
    .onHover = onHoverEsc,
};

const textContinueMenuButton = gui.Element.CreationOptions{
    .elementBackground = .{ .solid = .{ 0.3, 0.8, 0.3, 1 } },
    .position = .{ .xPercent = 50, .yPercent = 80 },
    .size = .{
        .widthPercent = 60,
        .heightPercent = 10,
    },
    .textOptions = .{
        .text = "Back to Game",
        .scale = .{ .relative = 4 },
        .startPosition = .{
            .xPercent = 35,
            .yPercent = 100,
        },
    },
    .onHover = onHoverC,
};


pub fn menuDraw() void {
    if(ts.CursorEscaped)menu.Draw(render.screen_dimensions, render.window);
}
pub fn processInput() !void {
    std.debug.assert(isinit);
    const timestamp = std.time.microTimestamp();
    const dt = timestamp - lastmicrotime;
    lastmicrotime = timestamp;
    var posAdjustment: @Vector(3, f64) = @splat(0);
    defer {
        render.playerLock.lock();
        std.debug.assert(@reduce(.Or, posAdjustment == posAdjustment)); //posAdjustment is not NaN
        render.player.pos += posAdjustment;
        render.playerLock.unlock();
    }
    var cameraSpeed: @Vector(3, f64) = @Vector(3, f64){ 0.002, 0.002, 0.002 } * @as(@Vector(3, f64), @splat(@as(f64, @floatFromInt(dt)) * 0.01)); // adjust accordingly
    if (ts.Sprinting) {
        cameraSpeed *= @splat(8);
    }
    if (ts.SuperSpeed) {
        cameraSpeed *= @splat(32);
    }
    if (render.window.getKey(glfw.Key.w) == .press)
        posAdjustment += cameraSpeed * render.cameraFront;
    if (render.window.getKey(glfw.Key.s) == .press)
        posAdjustment -= cameraSpeed * render.cameraFront;
    if (render.window.getKey(glfw.Key.a) == .press) {
        const cross = zm.vec.cross(render.cameraFront, Renderer.cameraUp);
        if (@reduce(.Or, cross != @Vector(3, f64){ 0, 0, 0 }))
            posAdjustment -= zm.vec.normalize(cross) * cameraSpeed;
    }
    if (render.window.getKey(glfw.Key.d) == .press) {
        const cross = zm.vec.cross(render.cameraFront, Renderer.cameraUp);
        if (@reduce(.Or, cross != @Vector(3, f64){ 0, 0, 0 }))
            posAdjustment += zm.vec.normalize(cross) * cameraSpeed;
    }
    if (render.window.getKey(glfw.Key.F11) == .press and std.time.milliTimestamp() - lastfullscreentoggle > 500) {
        if (ts.Fullscreen) {
            render.window.setMonitor(null, 0, 0, @intCast(render.screen_dimensions[0]), @intCast(render.screen_dimensions[1]), 0);
            ts.Fullscreen = false;
            lastfullscreentoggle = std.time.milliTimestamp();
        } else {
            const mon = glfw.getPrimaryMonitor().?;
            const dim = try mon.getPhysicalSize();
            render.window.setMonitor(mon, 0, 0, dim[0], dim[1], 0);
            ts.Fullscreen = true;
            lastfullscreentoggle = std.time.milliTimestamp();
        }
    }
    if (render.window.getKey(glfw.Key.escape) == .press or render.window.getKey(glfw.Key.left_super) == .press) {
        if (!ts.CursorEscaped) {
            ts.CursorEscaped = true;
            _ = try glfw.Window.setInputMode(render.window, glfw.InputMode.cursor, glfw.InputMode.ValueType(glfw.InputMode.cursor).normal);
        }
    }
    if (render.window.getKey(glfw.Key.left_control) == .press) {
        ts.Sprinting = true;
    } else ts.Sprinting = false;
    if (render.window.getKey(glfw.Key.left_shift) == .press) {
        ts.SuperSpeed = true;
    } else ts.SuperSpeed = false;
    if (render.window.getKey(glfw.Key.r) == .press)
        try render.AddChunkToRender(@divFloor(@as(@Vector(3, i32), @intFromFloat(render.player.pos)), @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize }), true);

    if (render.window.getKey(glfw.Key.b) == .press) {
        defer _ = worldEditor.clear();
        // try worldEditor.PlaceBlock(.{ .block = .Stone, .pos = @as(@Vector(3, i64), @intFromFloat(render.player.pos)) });

        for (0..512) |x| {
            for (0..512) |y| {
                for (0..512) |z| {
                    try worldEditor.PlaceBlock(.{ .block = .Stone, .pos = @as(@Vector(3, i64), @intFromFloat(render.player.pos)) + @Vector(3, i64){ @intCast(x), @intCast(y), @intCast(z) } });
                }
            }
        }
    }

    if (render.window.getKey(glfw.Key.i) == .press) {
        render.playerLock.lockShared();
        const playerPos = render.player.pos;
        render.playerLock.unlockShared();
        const chpos: @Vector(3, i32) = @intFromFloat(@round(playerPos / @as(@Vector(3, f64), @splat(ChunkSize))));
        std.debug.print("inspected: {any}, data: {any}", .{ chpos, render.world.Chunks.get(chpos) });
        std.debug.print("cameraFront: {any}, cameraUp: {any}\n", .{ render.cameraFront, Renderer.cameraUp });
        std.debug.print("block: {any}\n", .{worldEditor.GetBlock(@intFromFloat(playerPos))});
        _ = worldEditor.clear();
    }
    if (render.window.getKey(glfw.Key.p) == .press) {
        ts.Benchmark = true;
        benchmarkStartTime = std.time.microTimestamp();
    }
    if (ts.Benchmark) {
        render.playerLock.lock();
        var t: f64 = @floatFromInt(std.time.microTimestamp() - benchmarkStartTime);
        const speedUpFactor = 0.000000000005; //the bigger this number is the faster the acceleration
        t *= ((t * speedUpFactor));
        render.player.pos = std.math.lerp(render.player.pos, render.world.SpawnCenterPos + @Vector(3, f64){ t, @floatFromInt(100 + render.world.GetTerrainHeightAtCoords(@Vector(2, i64){ @intFromFloat(render.world.SpawnCenterPos[0] + t), @intFromFloat(render.world.SpawnCenterPos[2]) })), 0.0 }, @Vector(3, f64){ 1, 0.2, 1 });
        const pos = render.player.pos;
        render.playerLock.unlock();
        const chpos: @Vector(3, i32) = @intFromFloat(@round(pos / @as(@Vector(3, f64), @splat(ChunkSize))));
        if (render.world.Chunks.get(chpos) == null) {
            std.debug.print("benchmark finished, reached: {d}, chunk: {d}\n", .{ (t), chpos });
            std.debug.print("ended on: {any}, data: {any}", .{ (chpos), render.world.Chunks.get(chpos) });
            ts.Benchmark = false;
        }
    }
    if (render.window.getKey(glfw.Key.end) == .press) {
        ts.Benchmark = false;
    }
}

fn BuildStructTask() void {
    render.playerLock.lockShared();
    const playerPos = render.player.pos;
    render.playerLock.unlockShared();
    render.world.PrintStructure(@intFromFloat(playerPos), render, GenCube, CubeState, 256, null, null) catch |err| {
        std.debug.print("Error: {any}", .{err});
    };
}
pub fn GenCube(state: anytype, genParams: anytype) ?World.Step {
    var State: *CubeState = state;
    const stage = State.stage;
    State.stage += 1;
    if (stage >= (genParams * genParams * genParams)) return null;
    return World.Step{ .block = .Stone, .pos = .{ @divFloor(stage, genParams * genParams), @mod(@divFloor(stage, genParams), genParams), @mod(stage, genParams) } };
}

const CubeState = struct {
    stage: i64 = 0,
};

pub export fn MouseCallback(window: *glfw.Window, xpos: f64, ypos: f64) void {
    _ = window;
    std.debug.assert(isinit);
    if (ts.CursorEscaped) return;
    const xoffset: f64 = (xpos - last_mouse_pos[0]) * render.mouseSensitivity;
    const yoffset: f64 = (ypos - last_mouse_pos[1]) * render.mouseSensitivity;
    last_mouse_pos[0] = xpos;
    last_mouse_pos[1] = ypos;
    const player = render.player;
    render.playerLock.lock();
    var newHeadRotationAxis = player.headRotationAxis;
    var newBodyRotationAxis = player.bodyRotationAxis;
    newHeadRotationAxis -= @Vector(2, f32){ @floatCast(yoffset), @floatCast(xoffset) };
    newHeadRotationAxis[0] = @max(-89.99999, newHeadRotationAxis[0]);
    newHeadRotationAxis[0] = @min(89.99999, newHeadRotationAxis[0]);

    if (getDiff(@Vector(3, f32){ newHeadRotationAxis[0], newHeadRotationAxis[1], 0 }, newBodyRotationAxis) > 20) newBodyRotationAxis = @Vector(3, f32){ newHeadRotationAxis[0], newHeadRotationAxis[1], 0 }; //adjust degrees, currently at 20

    player.headRotationAxis = newHeadRotationAxis;
    player.bodyRotationAxis = newBodyRotationAxis;
    render.playerLock.unlock();

    var cameraFront: @Vector(3, f64) = undefined;
    cameraFront[0] = @floatCast(@sin(std.math.degreesToRadians(newHeadRotationAxis[1])) * @cos(std.math.degreesToRadians(newHeadRotationAxis[0])));
    cameraFront[1] = @floatCast(@sin(std.math.degreesToRadians(newHeadRotationAxis[0])));
    cameraFront[2] = @floatCast(@cos(std.math.degreesToRadians(newHeadRotationAxis[1])) * @cos(std.math.degreesToRadians(newHeadRotationAxis[0])));
    render.cameraFront = zm.vec.normalize(cameraFront);
}

fn getDiff(a: @Vector(3, f32), b: @Vector(3, f32)) f32 {
    var diff: f32 = 0;
    inline for (0..3) |i| {
        diff += @abs(a[i] - b[i]);
    }
    return diff;
}

pub export fn glfwSizeCallback(window: *glfw.Window, w: c_int, h: c_int) void {
    std.debug.assert(isinit);
    render.screen_dimensions[0] = @intCast(w);
    render.screen_dimensions[1] = @intCast(h);
    const xz = window.getContentScale();
    gl.Viewport(0, 0, @intFromFloat(@as(f32, @floatFromInt(w)) * xz[0]), @intFromFloat(@as(f32, @floatFromInt(h)) * xz[1]));
}
