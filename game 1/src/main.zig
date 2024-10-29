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
const ztracy = @import("ztracy");
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
        .Chunks = std.HashMap([3]i32, *Chunk, Chunk.ChunkContext, 80).init(allocator),
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
    var lasttime: f64 = 0;
            var torender = std.ArrayList(*Chunk).init(allocator);
    var t = std.time.microTimestamp();
    while (!glfw.Window.shouldClose(window)) {
        const frametime = ztracy.ZoneNC(@src(), "frametime", 0x00_ff_00_00);
        defer frametime.End();
        const currenttime = glfw.getTime();
        gl.ClearColor(0, 0.2, 0.5, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.Clear(gl.DEPTH_BUFFER_BIT);
        prossesInput(@constCast(&window), currenttime - lasttime);
        const chx = @as(i32, @intFromFloat(player.pos[0] / 32.0));
        const chy = @as(i32, @intFromFloat(player.pos[1] / 32.0));
        const chz = @as(i32, @intFromFloat(player.pos[2] / 32.0));
        const render_distance = [_]i32{5, 2, 5};
        var x: i32 = -render_distance[0];
        var y: i32 = -render_distance[1];
        var z: i32 = -render_distance[2];
        var genedchunks: u32 = 0;
        const s = gl.GetError();
                            if (s != gl.NO_ERROR) std.debug.print("{}", .{s});
        if (std.time.microTimestamp()-t > std.time.us_per_ms*4000){
        t = std.time.microTimestamp();
        while (x < render_distance[0]) {
            while (y < render_distance[1]) {
                while (z < render_distance[2]) {
                     const perchunk = ztracy.ZoneNC(@src(), "perchunk", 0x00_ff_00_00);
                     defer perchunk.End();
                    //std.debug.print("::{}::", .{chx});
                    const g = ztracy.ZoneNC(@src(), "hashget", 0x00_ff_00_00);
                    var st = try std.time.Timer.start();
                    const chptr = overworld.Chunks.get([3]i32{ chx + x, chy + y, chz + z });
                    std.debug.print("{}\n", .{st.read()});
                    g.End();
                    if (chptr == null) {
                        if (genedchunks < 4000) {
                            const gen = ztracy.ZoneNC(@src(), "gen", 0x00_ff_00_00);
                            defer gen.End();
                            //std.debug.print("len: {}  \r", .{overworld.Chunks.count()});
                            const cp = try allocator.create(Chunk);
                            cp.* = ChunkGen.GenChunk(6, [3]i32{ chx + x, chy + y, chz + z });
                            _ = try overworld.Chunks.put([3]i32{ chx + x, chy + y, chz + z }, cp);
                            genedchunks += 1;
                            //z+=1;
                            continue;
                        }
                    } else {
                        if (chptr.?.vbo == null) {
                            const mesh = ztracy.ZoneNC(@src(), "mesh", 0x00_ff_00_00);
                            defer mesh.End();
                            var vv = (try Mesher.FaceMesh(chptr.?, allocator));
                            defer vv.deinit();
                            const v = try vv.toOwnedSlice();
                            chptr.?.vlen = @intCast(v.len);
                            var tempvbo: c_uint = 0;
                            var tempvao: c_uint = 0;
                            gl.GenVertexArrays(1, @ptrCast(&tempvao));
                            gl.BindVertexArray(tempvao);

                            gl.GenBuffers(1, @ptrCast(&tempvbo));
                            gl.BindBuffer(gl.ARRAY_BUFFER, tempvbo);
                            gl.BufferData(gl.ARRAY_BUFFER, @intCast(@sizeOf(f32) * v.len), v.ptr, gl.STATIC_DRAW);
            
                            gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 5 * @sizeOf(f32), 0);
                            gl.EnableVertexAttribArray(0);
                            gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 5 * @sizeOf(f32), 3 * @sizeOf(f32));
                            gl.EnableVertexAttribArray(1);
                            gl.BindVertexArray(0);
                            chptr.?.vao = tempvao;
                            chptr.?.vbo = tempvbo;
                            const a = gl.GetError();
                            if (a != gl.NO_ERROR) std.debug.panic("{}", .{a});
                            _ = try torender.append(chptr.?);
                        }
                    }
                    z += 1;
                }
                z = -render_distance[2];
                y += 1;
            }
            y = -render_distance[1];
            x += 1;
        }}
        for(torender.items)|c|{
            const drawchunk = ztracy.ZoneNC(@src(), "drawchunk", 0x00_ff_00_00);
            _ = try render.RenderChunkFrame(c.pos, c.vao.?, c.vbo.?, c.vlen.?, player.pos, player.cameraUp, player.cameraFront);
            drawchunk.End();
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
