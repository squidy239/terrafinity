const std = @import("std");
const gl = @import("gl");
const glfw = @import("zglfw");
const ztracy = @import("ztracy");
const Renderer = @import("Renderer.zig").Renderer;
const zm = @import("zm");
var render:*Renderer = undefined;
var last_mouse_pos:[2]f64 = [2]f64{0,0};
var isinit = false;
var lastmicrotime:i64 = undefined;

pub fn init(ren:*Renderer)void{
    render = ren;
    lastmicrotime = std.time.microTimestamp();
    isinit = true;
}

pub fn processInput() void {
    const timestamp = std.time.microTimestamp();
    const dt = timestamp - lastmicrotime;
    lastmicrotime = timestamp;
    const cameraSpeed: @Vector(3, f64) = @Vector(3, f64){0.2,0.2,0.2} * @as(@Vector(3, f64),@splat(@as(f64,@floatFromInt(dt))*0.01)); // adjust accordingly
    if (render.window.getKey(glfw.Key.w) == .press)
        render.eyePos += cameraSpeed * render.cameraFront;
    if (render.window.getKey(glfw.Key.s) == .press)
        render.eyePos -= cameraSpeed * render.cameraFront;
    if (render.window.getKey(glfw.Key.a) == .press)
        render.eyePos -= zm.vec.normalize(zm.vec.cross(render.cameraFront, Renderer.cameraUp)) * cameraSpeed;
    if (render.window.getKey(glfw.Key.d) == .press)
        render.eyePos += zm.vec.normalize(zm.vec.cross(render.cameraFront, Renderer.cameraUp)) * cameraSpeed;
}

pub export fn MouseCallback(window: *glfw.Window, xpos: f64, ypos: f64) void {
    _ = window;
    const xoffset:f64 = (xpos - last_mouse_pos[0]) * render.mouseSensitivity;
    const yoffset:f64 = (ypos - last_mouse_pos[1]) * render.mouseSensitivity;
    last_mouse_pos[0] = xpos;
    last_mouse_pos[1] = ypos;
    const newyaw = render.rotationAxis[1] - (xoffset);
    var newpitch = render.rotationAxis[0] - (yoffset);
    if (newpitch > 89.9)
        newpitch = 89.9;
    if (newpitch < -89.9)
        newpitch = -89.9;
    render.rotationAxis = @Vector(3, f64){newpitch,newyaw,0};//no roll
    var cameraFront:@Vector(3, f64) = undefined;
    cameraFront[0] = @floatCast(@sin(std.math.degreesToRadians(newyaw)) * @cos(std.math.degreesToRadians(newpitch)));
    cameraFront[1] = @floatCast(@sin(std.math.degreesToRadians(newpitch)));
    cameraFront[2] = @floatCast(@cos(std.math.degreesToRadians(newyaw)) * @cos(std.math.degreesToRadians(newpitch)));

    render.cameraFront = zm.vec.normalize(cameraFront);
}

pub export fn glfwSizeCallback(window: *glfw.Window, w: c_int, h: c_int) void {
    std.debug.assert(isinit);
    render.screen_dimensions[0] = @intCast(w);
    render.screen_dimensions[1] = @intCast(h);
    gl.Viewport(0, 0, @intCast(w), @intCast(h));
    _ = window;
}
