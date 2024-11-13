const std = @import("std");
const gl = @import("gl");
const zm = @import("zm");
const zstbi = @import("zstbi");
const glfw = @import("glfw");
const ztracy = @import("ztracy");
var procs: gl.ProcTable = undefined;
var gpa = (std.heap.GeneralPurposeAllocator(.{.thread_safe = true }){});
const allocator = gpa.allocator();
var width: u32 = 800;
var height: u32 = 600;
const Entitys = @import("./entities/Entitys.zig");
const Chunk = @import("./chunk/Chunk.zig").Chunk;
const ChunkStates = @import("./chunk/Chunk.zig").ChunkState;
const Generator = @import("./chunk/Chunk.zig").Generator;
const Render = @import("./chunk/Chunk.zig").Render;
const RenderIDs = @import("./chunk/Chunk.zig").MeshBufferIDs;
const World = @import("./chunk/World.zig").World;
const pw = @import("./chunk/World.zig").pw;
const Noise = @import("./chunk/fastnoise.zig");
var fast = false;
const DistanceOrder = @import("./chunk/World.zig").DistanceOrder;
const vertices = [_]f32{
    -0.5, -0.5, 0.0, // bottom left corner
    -0.5, 0.5, 0.0, // top left corner
    0.5, 0.5,  0.0, // top right corner
    0.5, -0.5, 0.0,
}; // bottom right corner

const indices = [_]u32{
    0, 1, 2, // first triangle (bottom left - top left - top right)
    0, 2, 3,
};
var lastX: f64 = undefined;
var lastY: f64 = undefined;
var player: Entitys.Player = Entitys.Player{
    .yaw = 0,
    .cameraFront = @Vector(3, f32){ 0.0, 0.0, 1.0 },
    .cameraUp = @Vector(3, f32){ 0.0, 1.0, 0.0 },
    .pitch = 0,
    .roll = 0,
    .speed = @Vector(3, f32){ 100.0, 100.0, 100.0 },
    .pos = @Vector(3, f32){ 0.0, 0.0, -4.0 },
    .GenDistance = [3]u32{ 40, 20, 40 },
    .LoadDistance = [3]u32{ 40, 20, 40 },
    .MeshDistance = [3]u32{ 40, 20, 40 },
};

var fullscreen: bool = false;
pub fn main() !void {
    const cpu_count = try std.Thread.getCpuCount();
    var pool: std.Thread.Pool = undefined;
    _ = try pool.init(std.Thread.Pool.Options{ .allocator = allocator, .n_jobs = @intCast(cpu_count) });
    defer pool.deinit();
    lastX = @floatFromInt(width / 2);
    lastY = @floatFromInt(height / 2);
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

    const vertexshader = gl.CreateShader(gl.VERTEX_SHADER);
    gl.ShaderSource(vertexshader, 1, @ptrCast(&@embedFile("./vertexshader.vs")), null);
    gl.CompileShader(vertexshader);

    const fragshader = gl.CreateShader(gl.FRAGMENT_SHADER);
    gl.ShaderSource(fragshader, 1, @ptrCast(&@embedFile("./fragshader.fs")), null);
    gl.CompileShader(fragshader);

    const shaderprogram = gl.CreateProgram();
    //gl.BindTextures(gl.TEXTURE_2D, 1, @ptrCast(&texture));
    gl.AttachShader(shaderprogram, vertexshader);
    gl.AttachShader(shaderprogram, fragshader);
    gl.LinkProgram(shaderprogram);
    // gl.PolygonMode(gl.FRONT_AND_BACK, gl.F);
    //gl.Enable(gl.DEPTH_TEST);
    var linkstatus: c_int = undefined;
    gl.GetProgramiv(shaderprogram, gl.LINK_STATUS, &linkstatus);
    if (linkstatus == gl.FALSE) {
        var vsbuffer: [1000]u8 = undefined;
        var fsbuffer: [1000]u8 = undefined;
        var plog: [1000]u8 = undefined;
        gl.GetShaderInfoLog(vertexshader, 1000, null, &vsbuffer);
        gl.GetShaderInfoLog(fragshader, 1000, null, &fsbuffer);
        gl.GetProgramInfoLog(shaderprogram, 1000, null, &plog);
        std.debug.panic("{s}\n\n{s}\n\n{s}", .{ vsbuffer, fsbuffer, plog });
        return error.ShaderCompilationFailed;
    }
    gl.UseProgram(shaderprogram);
    //var vao: c_uint = undefined;
    //gl.GenVertexArrays(1, @ptrCast(&vao));
    //gl.BindVertexArray(vao);
    var ebo: c_uint = undefined;
    gl.GenBuffers(1, @ptrCast(&ebo));
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo);
    gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @sizeOf(u32) * indices.len, &indices, gl.STATIC_DRAW);

    var facebuffer: c_uint = undefined;
    gl.GenBuffers(1, @ptrCast(&facebuffer));
    gl.BindBuffer(gl.ARRAY_BUFFER, facebuffer);
    gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(f32) * vertices.len, &vertices, gl.STATIC_DRAW);

    gl.VertexAttribPointer(0, 3, gl.FLOAT, 0, 3 * @sizeOf(f32), 0);
    gl.EnableVertexAttribArray(0);

    gl.VertexAttribPointer(0, 3, gl.FLOAT, 0, 3 * @sizeOf(f32), 0);
    gl.EnableVertexAttribArray(0);
    //const startime = std.time.nanoTimestamp();
    //var LoadedChunks = std.AutoHashMap([3]i32, Chunk).init(allocator);
    //var ToMesh = std.PriorityQueue(*Chunk).init(allocator);
    //var ToGen = std.PriorityQueue().init(allocator);
    var inputtimer = try std.time.Timer.start();
    var gentimer = try std.time.Timer.start();

    //const gen_distance = [3]u32{ 5, 5, 5 };
    //const load_distance = [3]u32{ 5, 5, 5 };
    //const mesh_distance = [3]u32{ 5, 5, 5 };
    var MainWorld = World{
        .ChunksMutex = undefined,
        .ChunkStatesMutex = undefined,
        .ChunkMeshes = std.ArrayList(RenderIDs).init(allocator),
        .Chunks = std.AutoHashMap([3]i32, Chunk).init(allocator),
        .Entitys = std.AutoHashMap(Entitys.EntityUUID, type).init(allocator),
        .ToGen = std.PriorityQueue([3]i32, pw, DistanceOrder).init(allocator, pw{ .player = &player, .world = undefined }),
        .ChunkStates = std.AutoHashMap([3]i32, ChunkStates).init(allocator),
        .ToLoad = null,
        .ToLoadMutex = undefined,
        .ToLoadPos = null,
        .TerrainNoise = Noise.Noise(f32){
            .seed = 0,
            .noise_type = .simplex,
            .frequency = 0.01,
            .fractal_type = .none,
        },
        .min = -256,
        .max = 512,
    };
    MainWorld.ToLoadMutex.lock();
    MainWorld.ToGen.context.world = &MainWorld;
    MainWorld.ToLoadMutex.unlock();
    gl.Enable(gl.DEPTH_TEST);
    //gl.Enable(gl.CULL_FACE);

    _ = try pool.spawn(World.GenChunk, .{ &MainWorld, 0.01 * std.time.ns_per_ms, 1000, player, allocator });

    _ = try pool.spawn(World.AddToGen, .{ &MainWorld, &player, 20 * std.time.ns_per_ms });
    //_ = try MainWorld.ChunkMeshes.resize(MainWorld.ChunkMeshes.capacity + player.MeshDistance[0] * player.MeshDistance[1] + player.MeshDistance[2]);
    while (!window.shouldClose()) {
        const tracy_zone = ztracy.ZoneNC(@src(), "Frametime", 0x00_ff_00_00);
        defer tracy_zone.End();
        gl.ClearColor(0, 0.3, 0.5, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.Clear(gl.DEPTH_BUFFER_BIT);
        if (gentimer.read() > std.time.ns_per_ms * 2) {
            if (MainWorld.ToGen.count() > 0) {
                //std.debug.print("gen\n", .{});
                const LoadMeshes = ztracy.ZoneNC(@src(), "LoadMeshes", 0x4aeb2a);
                defer LoadMeshes.End();
                _ = try MainWorld.LoadMeshes(ebo, facebuffer);
            } else {
                //std.debug.print("0", .{});
            }
            gentimer.reset();
        }
        const proj = zm.Mat4f.perspective(zm.toRadians(90.0), @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)), 0.1, 10000.0);
        const projectionlocation = gl.GetUniformLocation(shaderprogram, "projection");
        gl.UniformMatrix4fv(projectionlocation, 1, gl.TRUE, @ptrCast(&(proj)));
        const view = zm.Mat4f.lookAt(player.pos, player.pos + player.cameraFront, player.cameraUp);
        const viewlocation = gl.GetUniformLocation(shaderprogram, "view");
        gl.UniformMatrix4fv(viewlocation, 1, gl.TRUE, @ptrCast(&(view)));
        const modellocation = gl.GetUniformLocation(shaderprogram, "chunkpos");
        //std.debug.print("{any}\n", .{player});
        //std.debug.print("{d}\n", .{MainWorld.ChunkMeshes.items.len});
        const drawtime = ztracy.ZoneNC(@src(), "Drawtime", 0xf5bf42);
        for (MainWorld.ChunkMeshes.items) |mesh| {
            gl.Uniform3i(modellocation, mesh.pos[0], mesh.pos[1], mesh.pos[2]);
            gl.BindVertexArray(mesh.vao);
            //gl.BindBuffer(gl.ARRAY_BUFFER, mesh.vbo);
            //gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, 40000);
            gl.DrawElementsInstanced(gl.TRIANGLES, indices.len, gl.UNSIGNED_INT, null, @intCast(mesh.count / 2));
        }
        drawtime.End();
        prossesInput(&window, @as(f64, @floatFromInt(inputtimer.lap())) / std.time.ns_per_s);
        window.swapBuffers();
        glfw.pollEvents();
        std.debug.print("{d}\r", .{player.pos});
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
    if (window.getKey(glfw.Key.left_control) == glfw.Action.press and !fast) {
        player.speed += @splat(100.0);
        fast = true;
    }
    if (window.getKey(glfw.Key.left_control) == glfw.Action.release and fast) {
        player.speed -= @splat(100.0);
        fast = false;
    }

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
