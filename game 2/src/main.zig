const std = @import("std");
const gl = @import("gl");
const zm = @import("zm");
const zstbi = @import("zstbi");
const glfw = @import("glfw");
var procs: gl.ProcTable = undefined;
var gpa = (std.heap.GeneralPurposeAllocator(.{}){});
const allocator = gpa.allocator();
var width: u32 = 800;
var height: u32 = 600;
const Entitys = @import("./entities/Entitys.zig");
var lastX: f64 = 0;
const Chunk = @import("./chunk/Chunk.zig").Chunk;
const chunkgen = @import("./chunk/GenChunk.zig");
var lastY: f64 = 0;
var player: Entitys.Player = Entitys.Player{
    .yaw = 0,
    .cameraFront = @Vector(3, f32){ 1.0, 0.0, 3.0 },
    .cameraUp = @Vector(3, f32){ 0.0, 0.0, -1.0 },
    .pitch = 0,
    .roll = 0,
    .speed = @Vector(3, f32){ 1.0, 1.0, 1.0 },
    .pos = @Vector(3, f32){ 0.0, 0.0, 0.0 },
};
var fullscreen: bool = false;
pub fn main() !void {
    if (!glfw.init(.{})) {
        std.debug.panic("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        return error.GLFWInitFailed;
    }

    var window = glfw.Window.create(width, height, "voxelgame", null, null, .{
        .context_version_major = 4,
        .context_version_minor = 6,
        .opengl_profile = .opengl_core_profile,
        .opengl_forward_compat = true,
        .samples = 4,
    }) orelse {
        std.debug.panic("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        return error.CreateWindowFailed;
    };
    defer window.destroy();
    glfw.makeContextCurrent(window);
    if (!procs.init(glfw.getProcAddress)) {
        std.debug.panic("could not get glproc", .{});
    }

    gl.makeProcTableCurrent(&procs);

    glfw.Window.setFramebufferSizeCallback(window, glfwSizeCallback);
    glfw.Window.setInputMode(window, glfw.Window.InputMode.cursor, glfw.Window.InputModeCursor.disabled);
    glfw.Window.setCursorPosCallback(window, MouseCallback);

    const startime = std.time.nanoTimestamp();
    var LoadedChunks = std.AutoHashMap([3]i32, Chunk).init(allocator);
    var inputtimer = try std.time.Timer.start();
    var gentimer = try std.time.Timer.start();
    const gen_distance = [3]u32{ 5, 5, 5 };
    const load_distance = [3]u32{ 5, 5, 5 };
    const mesh_distance = [3]u32{ 5, 5, 5 };
    var chunkmeshes = std.ArrayList(*Chunk).init(allocator);
    while (!window.shouldClose()) {
        if (gentimer.read() > std.time.ns_per_ms * 40) {
            _ = try LoadedChunks.ensureTotalCapacity(load_distance[0] * load_distance[1] * load_distance[2]);
            gentimer.reset();
            for (0..gen_distance[0]) |x| {
                for (0..gen_distance[1]) |y| {
                    for (0..gen_distance[2]) |z| {
                        if (@abs([3]i32{ x, y, z }) < load_distance and !LoadedChunks.contains([3]i32{ x, y, z })) {
                            LoadedChunks.put([3]i32{ x, y, z }, chunkgen.GenChunk(0, [3]i32{ x, y, z }));
                        }
                    }
                }
            }
        }
        prossesInput(&window, inputtimer.lap());
        window.swapBuffers();
        glfw.pollEvents();
    }
}

fn glfwSizeCallback(window: glfw.Window, w: u32, h: u32) void {
    width = w;
    height = h;
    gl.Viewport(0, 0, @intCast(w), @intCast(h));
    _ = window;
}

fn MouseCallback(window: glfw.Window, xpos: f64, ypos: f64) void {
    _ = window;
    const sensitivity = 0.1;
    const yoffset = (ypos - lastY) * sensitivity;
    const xoffset = (xpos - lastX) * sensitivity;
    lastX = xpos;
    lastY = ypos;
    player.yaw -= @floatCast(xoffset);
    player.pitch -= @floatCast(yoffset);
    if (player.pitch > 89.0)
        player.pitch = 89.0;
    if (player.pitch < -89.0)
        player.pitch = -89.0;
    player.cameraFront[0] = @floatCast(@sin(zm.toRadians(player.yaw)) * @cos(zm.toRadians(player.pitch)));
    player.cameraFront[1] = @floatCast(@sin(zm.toRadians(player.pitch)));
    player.cameraFront[2] = @floatCast(@cos(zm.toRadians(player.yaw)) * @cos(zm.toRadians(player.pitch)));
}
fn i32Range(comptime a: i32, comptime b: i32) [b - a]i32 {
    comptime {
        var range = std.mem.zeroes([b - a]i32);
        for (range[0..], 0..) |*v, i| v.* = a + @as(i32, i);
        return range;
    }
}
fn prossesInput(window: *glfw.Window, dt: f64) void {
    const deltaTime: f32 = @floatCast(dt);
    const cameraSpeed: zm.Vec3f = zm.Vec3f{ deltaTime, deltaTime, deltaTime } * player.speed;
    if (window.getKey(glfw.Key.w) == glfw.Action.press)
        player.pos += (cameraSpeed * player.cameraFront);
    if (window.getKey(glfw.Key.s) == glfw.Action.press)
        player.pos -= (cameraSpeed * player.cameraFront);
    if (window.getKey(glfw.Key.a) == glfw.Action.press)
        player.pos -= normalize(cross(player.cameraFront, player.cameraUp)) * cameraSpeed;
    if (window.getKey(glfw.Key.d) == glfw.Action.press)
        player.pos += normalize(cross(player.cameraFront, player.cameraUp)) * cameraSpeed;
    if (window.getKey(glfw.Key.space) == glfw.Action.press)
        player.pos[1] += cameraSpeed[1];
    if (window.getKey(glfw.Key.left_shift) == glfw.Action.press or window.getKey(glfw.Key.right_shift) == glfw.Action.press)
        player.pos[1] -= cameraSpeed[1];

    if (window.getKey(glfw.Key.F11) == glfw.Action.press) {
        const w = glfw.Monitor.getPrimary().?.getVideoMode().?.getWidth();
        const h = glfw.Monitor.getPrimary().?.getVideoMode().?.getHeight();
        if (!fullscreen) {
            width = w;
            height = h;
            window.setMonitor(glfw.Monitor.getPrimary(), 0, 0, w, h, null);
            fullscreen = true;
        } else {
            window.setMonitor(null, 0, 0, 800, 600, null);
            width = 800;
            height = 600;
            fullscreen = false;
        }
    }
}
fn normalize(self: anytype) @TypeOf(self) {
    return self / @as(@TypeOf(self), @splat(len(self)));
}
fn cross(self: anytype, other: @TypeOf(self)) @TypeOf(self) {
    if (dimensions(@TypeOf(self)) != 3) @compileError("cross is only defined for vectors of length 3.");
    return @TypeOf(self){
        self[1] * other[2] - self[2] * other[1],
        self[2] * other[0] - self[0] * other[2],
        self[0] * other[1] - self[1] * other[0],
    };
}

fn dimensions(T: type) comptime_int {
    return @typeInfo(T).Vector.len;
}

fn len(self: anytype) VecElement(@TypeOf(self)) {
    return @sqrt(@reduce(.Add, self * self));
}
pub fn VecElement(T: type) type {
    return @typeInfo(T).Vector.child;
}
