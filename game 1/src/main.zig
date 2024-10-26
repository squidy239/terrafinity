const glfw = @import("glfw");
const gl = @import("gl");
const zm = @import("zm");
const std = @import("std");
const zstbi = @import("zstbi");
const glfw_log = std.log.scoped(.glfw);
const gl_log = std.log.scoped(.gl);
const vsync = false;
const Chunk = @import("./chunk/chunk.zig").Chunk;
const world = @import("./world.zig");
const render = @import("./render.zig");
const Materials = @import("./chunk/Materials.zig").Materials;
const Entity = @import("./entitys.zig");
const ChunkGen = @import("./chunk/GenerateChunk.zig");
const Mesher = @import("./chunk/MeshChunk.zig");
const ArrayList = std.ArrayList;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var width: f32 = 800;
var height: f32 = 600;
var lastX: f64 = 0;
var lastY: f64 = 0;
var procs: gl.ProcTable = undefined;
var fullscreen: bool = false;
var player = Entity.Player{
    .cameraFront = @Vector(3, f32){ 0.0, 0.0, -1.0 },
    .pos = @Vector(3, f32){ 0.0, 0.0, 3.0 },
    .cameraUp = @Vector(3, f32){ 0.0, 1.0, 0.0 },
    .speed = @Vector(3, f32){ 50.0, 50.0, 50.0 },
    .pitch = 0.0,
    .yaw = 0.0,
    .roll = 0.0,
    .gamemode = Entity.Player.GameModes.Spectator,
};
pub fn main() !void {
    const allocator = gpa.allocator();
    if (!glfw.init(.{})) {
        glfw_log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        return error.GLFWInitFailed;
    }

    defer glfw.terminate();

    const window = glfw.Window.create(@intFromFloat(width), @intFromFloat(height), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", null, null, .{
        .context_version_major = 4,
        .context_version_minor = 6,
        .opengl_profile = .opengl_core_profile,
        .opengl_forward_compat = true,
    }) orelse {
        glfw_log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        return error.CreateWindowFailed;
    };

    defer window.destroy();
    glfw.makeContextCurrent(window);

    var overworld = world.World{
        .Chunks = std.HashMap(@Vector(3, i32), Chunk, Chunk.ChunkContext, 50).init(allocator),
    };

    if (!procs.init(glfw.getProcAddress)) {
        @panic("could not get glproc");
    }
    gl.makeProcTableCurrent(&procs);
    window.setSizeCallback(framebuffer_size_callback);
    glfw.Window.setInputMode(window, glfw.Window.InputMode.cursor, glfw.Window.InputModeCursor.disabled);
    glfw.Window.setCursorPosCallback(window, MouseCallback);
  
    _ = try render.InitRenderer();
      const e = gl.GetError();
                            if (e != gl.NO_ERROR) std.debug.print("{}", .{e});
    _ = try overworld.Chunks.put(@Vector(3, i32){ 0, 10, 0 }, ChunkGen.initctoblock(Materials.Air, @Vector(3, i32){ 0, 0, 0 }));
    var lasttime: f64 = 0;
    while (!glfw.Window.shouldClose(window)) {
        const currenttime = glfw.getTime();
        gl.ClearColor(0, 0.2, 0.5, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.Clear(gl.DEPTH_BUFFER_BIT);
        prossesInput(@constCast(&window), currenttime - lasttime);
        const chx = @as(i32, @intFromFloat(player.pos[0] / 32.0));
        const chy = @as(i32, @intFromFloat(player.pos[1] / 32.0));
        const chz = @as(i32, @intFromFloat(player.pos[2] / 32.0));
        const render_distance = [_]i32{ 2, 2, 2 };
        var x: i32 = -render_distance[0];
        var y: i32 = -render_distance[1];
        var z: i32 = -render_distance[2];
        var genedchunks: u32 = 0;
        const s = gl.GetError();
                            if (s != gl.NO_ERROR) std.debug.print("{}", .{s});
        while (x < render_distance[0]) {
            while (y < render_distance[1]) {
                while (z < render_distance[2]) {
                    //std.debug.print("::{}::", .{chx});
                    const chptr = overworld.Chunks.getPtr(@Vector(3, i32){ chx + x, chy + y, chz + z });
                    //const st = std.time.microTimestamp();
                    if (chptr == null) {
                        if (genedchunks < 40) {
                            //std.debug.print("len: {}  \r", .{overworld.Chunks.count()});
                            _ = try overworld.Chunks.put(@Vector(3, i32){ chx + x, chy + y, chz + z }, ChunkGen.GenChunk(0, @Vector(3, i32){ chx + x, chy + y, chz + z }));
                            genedchunks += 1;
                            //z+=1;
                            continue;
                        }
                    } else {
                        if (chptr.?.vbo == null) {
                            var vv = (try Mesher.FaceMesh(chptr.?, allocator));
                            defer vv.deinit();
                            const v = try vv.toOwnedSlice();
                            chptr.?.vlen = @intCast(v.len);
                            var tempvbo: c_uint = 0;
                            var tempvao: c_uint = 0;
                            std.debug.print("\n\ncreating||\n", .{});
                            gl.CreateVertexArrays(1, &tempvao);
                            chptr.?.vao = tempvao;
                            const b = gl.GetError();
                            if (b != gl.NO_ERROR) std.debug.print("{}", .{b});
                            gl.BindVertexArray(chptr.?.vao.?);
                            gl.CreateBuffers(1, &tempvbo);
                            chptr.?.vbo = tempvbo;
                            gl.BindBuffer(gl.ARRAY_BUFFER, chptr.?.vbo.?);
                            std.debug.print("||bind,{}||\n", .{v.len});
                            gl.BufferData(gl.ARRAY_BUFFER, @intCast(v.len), v.ptr, gl.STATIC_DRAW);
                            std.debug.print("||set||\n\n", .{});
                            gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 5 * @sizeOf(f32), 0);
                            gl.EnableVertexAttribArray(0);
                            gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 5 * @sizeOf(f32), 3 * @sizeOf(f32));
                            gl.EnableVertexAttribArray(1);
                            gl.BindVertexArray(0);
                            const a = gl.GetError();
                            if (a != gl.NO_ERROR) std.debug.panic("{}", .{a});
                        }

                        _ = try render.RenderChunkFrame(chptr.?.pos, chptr.?.vao.?, chptr.?.vbo.?, chptr.?.vlen.?, player.pos, player.cameraUp, player.cameraFront);
                    }
                    //std.debug.print("{}\n", .{std.time.microTimestamp()-st});
                    z += 1;
                }
                z = -render_distance[2];
                y += 1;
            }
            y = -render_distance[1];
            x += 1;
        }
        window.swapBuffers();
        glfw.pollEvents();
        lasttime = currenttime;
    }
}

fn framebuffer_size_callback(window: glfw.Window, width1: i32, height1: i32) void {
    _ = window;
    gl.Viewport(0, 0, width1, height1);
    width = @floatFromInt(width1);
    height = @floatFromInt(height1);
}

fn MouseCallback(window: glfw.Window, xpos: f64, ypos: f64) void {
    _ = window;
    const sensitivity = 0.1;
    const yoffset = (ypos - lastY) * sensitivity;
    const xoffset = (xpos - lastX) * sensitivity;
    lastX = xpos;
    lastY = ypos;
    player.yaw -= xoffset;
    player.pitch -= yoffset;
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
        if (!fullscreen) {
            window.maximize();
            fullscreen = true;
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
