const std = @import("std");

const cache = @import("cache");
const gl = @import("gl");
const glfw = @import("glfw");
const zm = @import("zm");
const zstbi = @import("zstbi");
const ztracy = @import("ztracy");

const Textures = @import("./chunk/Blocks.zig").Textures;
const Blocks = @import("./chunk/Blocks.zig").Blocks;
const Chunk = @import("./chunk/Chunk.zig").Chunk;
const ChunkStates = @import("./chunk/Chunk.zig").ChunkState;
const Generator = @import("./chunk/Chunk.zig").Generator;
const Render = @import("./chunk/Chunk.zig").Render;
const RenderIDs = @import("./chunk/Chunk.zig").MeshBufferIDs;
const Noise = @import("./chunk/fastnoise.zig");
const World = @import("./chunk/World.zig").World;
const pw = @import("./chunk/World.zig").pw;
const ChunkMesh = @import("./chunk/World.zig").ChunkMesh;
const DistanceOrder = @import("./chunk/World.zig").DistanceOrder;
const Entitys = @import("./entities/Entitys.zig");
const ConcurrentHashMap = @import("./libs/ConcurrentHashMap.zig").ConcurrentHashMap;

var procs: gl.ProcTable = undefined;
var gpa = (std.heap.GeneralPurposeAllocator(.{
    .thread_safe = true,
    //.safety = false,

}){});
var c_allocator = std.heap.ThreadSafeAllocator{ .child_allocator = std.heap.c_allocator };
const allocator = c_allocator.allocator();
var width: u32 = 800;
var height: u32 = 600;
var Worldptr: *World = undefined;
var fast = false;
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

const trivertices = [_]f32{
    -2.0, -2.0, 0.0, // bottom left corner
    -0.0, 2.0,  0.0, // top left corner
    2.0,  -2.0, 0.0,
}; // bottom right corner

var lastX: f64 = undefined;
var lastY: f64 = undefined;

var player: Entitys.Player = Entitys.Player{
    .yaw = 0,
    .cameraFront = @Vector(3, f64){ 0.0, 0.0, 1.0 },
    .cameraUp = @Vector(3, f64){ 0.0, 1.0, 0.0 },
    .pitch = 0,
    .roll = 0,
    .speed = @Vector(3, f32){ 10.0, 10.0, 10.0 },
    .pos = @Vector(3, f64){ 0.0, 0.0, 0.0 },
    .GenDistance = [3]u32{ 20, 10, 20 },
    .LoadDistance = [3]u32{ 20, 10, 20},
    .MeshDistance = [3]u32{ 20, 10, 20 },
};

var fullscreen: bool = false;
//time:2500 ms 11/24/2024
//
pub fn main() !void {
    const cpu_count = try std.Thread.getCpuCount();
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
    
    glfw.makeContextCurrent(window);
    if (!procs.init(glfw.getProcAddress)) {
        std.debug.panic("could not get glproc", .{});
    }
    
    gl.makeProcTableCurrent(&procs);
    glfw.Window.setFramebufferSizeCallback(window, glfwSizeCallback);
    glfw.Window.setInputMode(window, glfw.Window.InputMode.cursor, glfw.Window.InputModeCursor.disabled);
    glfw.Window.setCursorPosCallback(window, MouseCallback);
    glfw.swapInterval(0);
    const vertexshader = gl.CreateShader(gl.VERTEX_SHADER);
    gl.ShaderSource(vertexshader, 1, @ptrCast(&@embedFile("./vertexshader.vert")), null);
    gl.CompileShader(vertexshader);

    const fragshader = gl.CreateShader(gl.FRAGMENT_SHADER);
    gl.ShaderSource(fragshader, 1, @ptrCast(&@embedFile("./fragshader.frag")), null);
    gl.CompileShader(fragshader);

    const shaderprogram = gl.CreateProgram();
    gl.AttachShader(shaderprogram, vertexshader);
    gl.AttachShader(shaderprogram, fragshader);
    gl.LinkProgram(shaderprogram);
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
    gl.DeleteShader(vertexshader);
    gl.DeleteShader(fragshader);

    var ebo: c_uint = undefined;
    gl.GenBuffers(1, @ptrCast(&ebo));
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo);
    gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @sizeOf(u32) * indices.len, &indices, gl.STATIC_DRAW);

    var facebuffer: c_uint = undefined;
    gl.GenBuffers(1, @ptrCast(&facebuffer));
    gl.BindBuffer(gl.ARRAY_BUFFER, facebuffer);
    gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(f32) * vertices.len, &vertices, gl.STATIC_DRAW);
    //gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(f32) * trivertices.len, &trivertices, gl.STATIC_DRAW);

    gl.VertexAttribPointer(0, 3, gl.FLOAT, 0, 3 * @sizeOf(f32), 0);
    gl.EnableVertexAttribArray(0);
    var inputtimer = try std.time.Timer.start();
    var MainWorld = World{
        .running = std.atomic.Value(bool).init(true),
        .pool = undefined,
        .ChunkMeshes = std.ArrayList(RenderIDs).init(allocator),
        .Chunks = ConcurrentHashMap([3]i32, *Chunk, std.hash_map.AutoContext([3]i32), 80, 32).init(allocator),
        .Entitys = std.AutoHashMap(Entitys.EntityUUID, type).init(allocator),
        .MeshesToLoad = std.DoublyLinkedList(ChunkMesh){},
        //using seprate allocator
        .TerrainHeightCache = try cache.Cache([32][32]i32).init(c_allocator.allocator(), .{ .segment_count = 1, .gets_per_promote = 1, .max_size = 100}),
        .TerrainHeightCacheMutex = .{},
        .MeshesToLoadMutex = .{},
        .ToUnloadMutex = .{},
        .ToUnload = std.DoublyLinkedList([3]i32){},
        .TerrainNoise = Noise.Noise(f32){
            .seed = 0,
            .noise_type = .perlin,
            .frequency = 0.00008,
            .fractal_type = .none,
        },
        .CaveNoise = Noise.Noise(f32){
            .seed = 0,
            .noise_type = .perlin,
            .fractal_type = .none,
            .frequency = 0.005,
        },
        .TerrainNoise2 = Noise.Noise(f32){
            .seed = 0,
            .noise_type = .perlin,
            .frequency = 0.0002,
            .fractal_type = .ridged,
            .octaves = 10,
        },

        .min = 0,
        .max = 5024,
        // 0 is most cavey 1 is least cavey
        .caveness = 0.2,
    };
    var g = try std.Thread.spawn(.{}, World.AddToGen, .{ &MainWorld, &player, 20 * std.time.ns_per_ms, allocator });
    //TODO put in threadpool
    var u = try std.Thread.spawn(.{}, World.AddToUnload, .{ &MainWorld, &player, 1000 * std.time.ns_per_ms, allocator });
    var ul = try std.Thread.spawn(.{}, World.UnloadLoop, .{ &MainWorld, 1000 * std.time.ns_per_ms, allocator });
    //i am using a diffrent allocator for thread pool so it dosent get slowed down by other allocations, it makes a big diffrence
    _ = try MainWorld.pool.init(.{ .n_jobs = @intCast(cpu_count - 1), .allocator = c_allocator.allocator() });
  
    
    
    Worldptr = &MainWorld;
    gl.Enable(gl.DEPTH_TEST);
    gl.Enable(gl.CULL_FACE);
    gl.CullFace(gl.BACK);
    gl.FrontFace(gl.CW);
    gl.DepthFunc(gl.LESS);
    //load textures
    var atlas = try Textures.LoadAtlas("./Textures/BlockTextures.png", allocator);
    var BlockTextures: c_uint = undefined;
    gl.GenTextures(1, @ptrCast(&BlockTextures));

    gl.BindTexture(gl.TEXTURE_2D, BlockTextures);
    //gl.Enable(gl.BLEND);
    //gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.TextureParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.TextureParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, @intCast(atlas.width), @intCast(atlas.height), 0, gl.RGBA, gl.UNSIGNED_BYTE, @ptrCast(atlas.data));
    gl.GenerateMipmap(gl.TEXTURE_2D);
    const AtlasHeightLocation = gl.GetUniformLocation(shaderprogram, "AtlasHeight");
    gl.Uniform1ui(AtlasHeightLocation, @intCast(atlas.height));
    atlas.deinit();
    //clean up
    defer {
    MainWorld.running.store(false, .monotonic);
    window.destroy();
    ul.join();
    g.join();
    u.join();
    MainWorld.deinit(allocator);
     gl.DeleteTextures(1, @ptrCast(&BlockTextures));
     gl.DeleteBuffers(1, @ptrCast(&ebo));
     gl.DeleteBuffers(1, @ptrCast(&facebuffer));
    gl.DeleteProgram(shaderprogram);
    
    // Clean up GLFW
    glfw.terminate();
    }
    //higher cpu count than system somehow benifits this
    std.debug.print("\ncpu_count: {}\n", .{cpu_count});

    // var benchmarktimer = try std.time.Timer.start();
    var unloadTimer = try std.time.Timer.start();
    // var genbenchmark = true;
    // var meshbenchmark = true;
    const projviewlocation = gl.GetUniformLocation(shaderprogram, "projview");
    const relativechunkposlocation = gl.GetUniformLocation(shaderprogram, "relativechunkpos");
    const chunkposlocation = gl.GetUniformLocation(shaderprogram, "chunkpos");
    const tlocation = gl.GetUniformLocation(shaderprogram, "chunktime");
    const scalelocation = gl.GetUniformLocation(shaderprogram, "scale");
    var frame:u64 = 0;
    while (!window.shouldClose()) {
        frame+|=1;
        const tracy_zone = ztracy.ZoneNC(@src(), "Frametime", 0x00_ff_00_00);
        defer tracy_zone.End();
        gl.ClearColor(0, 0.3, 0.5, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.Clear(gl.DEPTH_BUFFER_BIT);
        const projview = @as(@Vector(16, f32),@floatCast(zm.Mat4d.perspective(zm.toRadians(90.0), @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)), 1.0, 200000).multiply( zm.Mat4d.lookAt(@Vector(3, f32){0,0,0}, @Vector(3, f32){0,0,0} + player.cameraFront, player.cameraUp)).data));
        gl.UniformMatrix4fv(projviewlocation, 1, gl.TRUE, @ptrCast(&(projview)));
        
        //std.debug.print("{d}\n", .{MainWorld.ChunkMeshes.items.len});
        const drawtime = ztracy.ZoneNC(@src(), "Drawtime", 0xf5bf42);
        const it = MainWorld.ChunkMeshes.items;

        for (it) |mesh| {
            var tr = std.time.milliTimestamp() - mesh.time;
            if (tr > 1000) tr = 1000;
            gl.Uniform1f(scalelocation, mesh.scale);
            gl.Uniform1i(tlocation, @intCast(tr));
            gl.Uniform3i(chunkposlocation, mesh.pos[0], mesh.pos[1],mesh.pos[2]);
            gl.Uniform3f(relativechunkposlocation, @floatCast((@as(f64,@floatFromInt(mesh.pos[0]))*mesh.scale*32.0)-player.pos[0]), @floatCast((@as(f64,@floatFromInt(mesh.pos[1]))*mesh.scale*32.0)-player.pos[1]), @floatCast((@as(f64,@floatFromInt(mesh.pos[2]))*mesh.scale*32.0)-player.pos[2]));
            gl.BindVertexArray(mesh.vao);
            //TODO frustrum cullling and LODs
            gl.DrawElementsInstanced(gl.TRIANGLES, indices.len, gl.UNSIGNED_INT, null, @intCast(mesh.count / 2));
        }
        std.debug.assert(it.len == MainWorld.ChunkMeshes.items.len);
        drawtime.End();
        {
            //std.debug.print("gen\n", .{});
            const loadmeshestop = ztracy.ZoneNC(@src(), "loadmeshestop", 0x00_ff_00_00);
            defer loadmeshestop.End();
            _ = try MainWorld.LoadMeshes(ebo, facebuffer, allocator, 4 * std.time.ns_per_ms);
        }
        //std.debug.print("{d}\r", .{player.pos});
        const unload = ztracy.ZoneNC(@src(), "unload", 0x00_ff_00_00);
        unload.End();
        if (unloadTimer.read() > 2 * std.time.ns_per_ms) {
            unloadTimer.reset();
            const pi:@Vector(3, i32) = @intFromFloat(player.pos / @Vector(3, f64){ 32, 32, 32 });
            //std.debug.print("\n\n{}\n\n", .{it.len});
            var i = MainWorld.ChunkMeshes.items.len;
            while (i > 0) {
                i -= 1;
                const mesh = MainWorld.ChunkMeshes.items[i];
                const p = MainWorld.Chunks.get(mesh.pos).?;
                
                if (@reduce(.Or, @abs(pi - mesh.pos) > @as(@Vector(3, u32), ((player.MeshDistance)))) or p.state.load(.seq_cst) == ChunkStates.ReMesh) {
                    if (p.state.load(.seq_cst) == ChunkStates.InMemoryAndMesh) {
                        p.lock.lock();
                        p.state.store(ChunkStates.InMemoryMeshUnloaded, .seq_cst);
                        p.lock.unlock();
                    } else if (p.state.load(.seq_cst) == ChunkStates.MeshOnly) {
                        
                        std.debug.assert(p.ChunkData == null or p.Unloading == true);
                        _ = MainWorld.Chunks.remove(p.pos);
                    } else {
                        std.debug.print("\n\n\n{} != InMemoryAndMesh or MeshOnly\n", .{p.state});
                    }

                    var l = MainWorld.ChunkMeshes.swapRemove(i);
                    gl.DeleteBuffers(1, @ptrCast(&l.vbo));
                    gl.DeleteVertexArrays(1, @ptrCast(&l.vao));
                }
            }
        }
        const prossesinput = ztracy.ZoneNC(@src(), "prossesInput", 0x00_ff_00_00);
        try prossesInput(&window, @as(f64, @floatFromInt(inputtimer.lap())) / std.time.ns_per_s);
        prossesinput.End();
        const swap = ztracy.ZoneNC(@src(), "swap", 0x00_ff_00_00);
        window.swapBuffers();
        swap.End();
        const poll = ztracy.ZoneNC(@src(), "poll", 0x00_ff_00_00);
        glfw.pollEvents();
        poll.End();
        std.debug.print("pos:{d}, frame{d}\r", .{player.pos,frame});
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
    if (player.pitch > 89.9)
        player.pitch = 89.9;
    if (player.pitch < -89.9)
        player.pitch = -89.9;
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

fn prossesInput(window: *glfw.Window, dt: f64) !void {
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
        player.speed *= @splat(30.0);
        fast = true;
    }
    if (window.getKey(glfw.Key.left_control) == glfw.Action.release and fast) {
        player.speed /= @splat(30.0);
        fast = false;
    }
    if (window.getKey(glfw.Key.b) == glfw.Action.press) { //breaking is broken
    }

    if (window.getKey(glfw.Key.F11) == glfw.Action.press) {
        std.time.sleep(400 * std.time.ns_per_ms);
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
    return @typeInfo(T).vector.len;
}

fn len(self: anytype) VecElement(@TypeOf(self)) {
    return @sqrt(@reduce(.Add, self * self));
}
pub fn VecElement(T: type) type {
    return @typeInfo(T).vector.child;
}
pub fn lookAt(eye: @Vector(3, f64), target: @Vector(3, f64), up: @Vector(3, f64)) zm.Mat4f {
    const f = zm.vec.normalize(target - eye);
    const s = zm.vec.normalize(zm.vec.cross(f, up));
    const u = zm.vec.normalize(zm.vec.cross(s, f));
    
    return zm.Mat4f {
        .data = .{
            @floatCast(s[0]),  @floatCast(s[1]),  @floatCast(s[2]),  @floatCast(-zm.vec.dot(s, eye)),
            @floatCast(u[0]),  @floatCast(u[1]),  @floatCast(u[2]),  @floatCast(-zm.vec.dot(u, eye)),
            @floatCast(-f[0]), @floatCast(-f[1]), @floatCast(-f[2]), @floatCast(zm.vec.dot(f, eye)),
            0,     0,     0,     1,
        },
    };
}

