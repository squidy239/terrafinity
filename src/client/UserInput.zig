const std = @import("std");
const gl = @import("gl");
const glfw = @import("zglfw");
const ztracy = @import("ztracy");
const Renderer = @import("Renderer.zig").Renderer;
const zm = @import("zm");
var render: *Renderer = undefined;
var last_mouse_pos: [2]f64 = [2]f64{ 0, 0 };
var isinit = false;
var lastmicrotime: i64 = undefined;

pub fn init(ren: *Renderer) void {
    render = ren;
    lastmicrotime = std.time.microTimestamp();
    isinit = true;
}
const KeyboardKey = enum(u7) {
    W,
    A,
    S,
    D,
    CTRL,
    SPACE,
    SHIFT,
    G,
};

const KeyboardAction = enum(u8) {
    Forward,
    Right,
    Back,
    Left,
    CTRL,
    JUMP,
    SHIFT,
    G,
};
const ToggleSettings = struct {
    Fullscreen: bool,
    Sprinting: bool,
    CursorEscaped: bool,
};
var ts = ToggleSettings{
    .Fullscreen = false,
    .Sprinting = false,
    .CursorEscaped = true,
};

const PlayerInput = struct { //server  will have a max deltatime
    microTimestamp: i64,
    keyToggled: KeyboardAction, //TODO figure out best format so send inputs, only ones changed or all each frame
};

pub fn processInput() !void {
    std.debug.assert(isinit);
    const timestamp = std.time.microTimestamp();
    const dt = timestamp - lastmicrotime;
    lastmicrotime = timestamp;
    var posAdjustment: @Vector(3, f64) = @splat(0);
    defer {
        render.playerLock.lock();
        render.player.pos += posAdjustment;
        render.playerLock.unlock();
    }
    var cameraSpeed: @Vector(3, f64) = @Vector(3, f64){ 0.02, 0.02, 0.02 } * @as(@Vector(3, f64), @splat(@as(f64, @floatFromInt(dt)) * 0.01)); // adjust accordingly
    if (ts.Sprinting) {
        cameraSpeed *= @splat(8);
    }
    if (render.window.getKey(glfw.Key.w) == .press)
        posAdjustment += cameraSpeed * render.cameraFront;
    if (render.window.getKey(glfw.Key.s) == .press)
        posAdjustment -= cameraSpeed * render.cameraFront;
    if (render.window.getKey(glfw.Key.a) == .press)
        posAdjustment -= zm.vec.normalize(zm.vec.cross(render.cameraFront, Renderer.cameraUp)) * cameraSpeed;
    if (render.window.getKey(glfw.Key.d) == .press)
        posAdjustment += zm.vec.normalize(zm.vec.cross(render.cameraFront, Renderer.cameraUp)) * cameraSpeed;
    if (render.window.getMouseButton(glfw.MouseButton.left) == .press) {
        if (ts.CursorEscaped) {
            ts.CursorEscaped = false;
            _ = try glfw.Window.setInputMode(render.window, glfw.InputMode.cursor, glfw.InputMode.ValueType(glfw.InputMode.cursor).disabled);
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
}

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
