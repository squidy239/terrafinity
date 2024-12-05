const std = @import("std");
const gl = @import("gl");
const zm = @import("zm");
const zstbi = @import("zstbi");
const glfw = @import("glfw");
const ztracy = @import("ztracy");
var procs: gl.ProcTable = undefined;
var gpa = (std.heap.GeneralPurposeAllocator(.{
    .thread_safe = true,
    .safety = false,
    
}){});
const c_allocator = std.heap.c_allocator;
const allocator = gpa.allocator();
var width: u32 = 800;
const ConcurrentHashMap = @import("./libs/ConcurrentHashMap.zig").ConcurrentHashMap;
var height: u32 = 600;
const Entitys = @import("./entities/Entitys.zig");
const Textures = @import("./chunk/Blocks.zig").Textures;
const Chunk = @import("./chunk/Chunk.zig").Chunk;
const ChunkStates = @import("./chunk/Chunk.zig").ChunkState;
const Generator = @import("./chunk/Chunk.zig").Generator;
const Render = @import("./chunk/Chunk.zig").Render;
const Blocks = @import("./chunk/Blocks.zig").Blocks;

const RenderIDs = @import("./chunk/Chunk.zig").MeshBufferIDs;
const World = @import("./chunk/World.zig").World;
const ChunkandMeta = @import("./chunk/Chunk.zig").ChunkandMeta;
const pw = @import("./chunk/World.zig").pw;
var Worldptr:*World = undefined;
const ChunkMesh = @import("./chunk/World.zig").ChunkMesh;
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
    .speed = @Vector(3, f32){ 10.0, 10.0, 10.0 },
    .pos = @Vector(3, f32){ 0.0, 30.0, 0.0 },
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

    gl.VertexAttribPointer(0, 3, gl.FLOAT, 0, 3 * @sizeOf(f32), 0);
    gl.EnableVertexAttribArray(0);
    var inputtimer = try std.time.Timer.start();
    var MainWorld = World{
        .ChunkMeshes = std.ArrayList(RenderIDs).init(allocator),
        .Chunks = ConcurrentHashMap([3]i32, *ChunkandMeta, std.hash_map.AutoContext([3]i32), 80, 32).init(allocator),
        .Entitys = std.AutoHashMap(Entitys.EntityUUID, type).init(allocator),
        .ToGen = std.PriorityQueue([3]i32, pw, DistanceOrder).init(c_allocator, pw{ .player = &player, .world = undefined }),
        .MeshesToLoad = std.DoublyLinkedList(ChunkMesh){},
        .MeshesToLoadMutex = .{},
        .ToGenMutex = .{},
        .ToMesh = std.DoublyLinkedList([3]i32){},
        .ToUnloadMutex = .{},
        .ToUnload = std.DoublyLinkedList([3]i32){},
        .ToMeshMutex = .{},
        .TerrainNoise = Noise.Noise(f32){
            .seed = 0,
            .noise_type = .perlin,
            .frequency = 0.00008,
            .fractal_type = .none,
        },
        .CaveNoise = Noise.Noise(f32){
            .seed = 0,
            .noise_type = .simplex,
            .fractal_type = .none,
            .frequency = 0.005,
        },
        .TerrainNoise2 = Noise.Noise(f32){
            .seed = 0,
            .noise_type = .perlin,
            .frequency = 0.002,
            .fractal_type = .none,
        },
        .min = -64,
        .max = 5024,
        // 0 is most cavey 255 is least cavey
        .caveness = 0.4,
    };
    MainWorld.ToGen.context.world = &MainWorld;
    Worldptr = &MainWorld;
    gl.Enable(gl.DEPTH_TEST);
    gl.Enable(gl.CULL_FACE);
    gl.CullFace(gl.BACK);
    gl.FrontFace(gl.CW);

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

    _ = try std.Thread.spawn(.{ .stack_size = 32 * 1024 * 8 }, World.AddToGen, .{ &MainWorld, &player, 20 * std.time.ns_per_ms, allocator });
    _ = try std.Thread.spawn(.{ .stack_size = 32 * 1024 * 80 }, World.AddToUnload, .{ &MainWorld, &player, 100 * std.time.ns_per_ms, allocator });
    _ = try std.Thread.spawn(.{ .stack_size = 32 * 1024 * 80 }, World.UnloadLoop, .{ &MainWorld, 100 * std.time.ns_per_ms, allocator });
    //higher cpu count than system somehow benifits this
    for (0..@intFromFloat(@as(f32, @floatFromInt(cpu_count)) / @as(f32, 1.5))) |_| {
        _ = try std.Thread.spawn(.{ .stack_size = 32 * 1024 * 8 }, World.GenChunk, .{ &MainWorld, player, allocator });
    }
    for (0..cpu_count / 2) |_| {
        _ = try std.Thread.spawn(.{ .stack_size = 32 * 1024 * 8 }, World.MeshChunks, .{ &MainWorld, 1 * std.time.ns_per_ms, allocator });
    }

    const projectionlocation = gl.GetUniformLocation(shaderprogram, "projection");
    var benchmarktimer = try std.time.Timer.start();
    var unloadTimer = try std.time.Timer.start();
    var genbenchmark = true;
    var meshbenchmark = true;
    while (!window.shouldClose()) {
        const tracy_zone = ztracy.ZoneNC(@src(), "Frametime", 0x00_ff_00_00);
        defer tracy_zone.End();
        gl.ClearColor(0, 0.3, 0.5, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.Clear(gl.DEPTH_BUFFER_BIT);
        {
            //std.debug.print("gen\n", .{});
            const loadmeshestop = ztracy.ZoneNC(@src(), "loadmeshestop", 0x00_ff_00_00);
            defer loadmeshestop.End();
            _ = try MainWorld.LoadMeshes(ebo, facebuffer, allocator, 2 * std.time.ns_per_ms);
        }
        const proj = zm.Mat4f.perspective(zm.toRadians(114.0), @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)), 0.05, 10000.0);
        gl.UniformMatrix4fv(projectionlocation, 1, gl.TRUE, @ptrCast(&(proj)));
        const view = zm.Mat4f.lookAt(player.pos, player.pos + player.cameraFront, player.cameraUp);
        const viewlocation = gl.GetUniformLocation(shaderprogram, "view");
        gl.UniformMatrix4fv(viewlocation, 1, gl.TRUE, @ptrCast(&(view)));
        const chunkposlocation = gl.GetUniformLocation(shaderprogram, "chunkpos");
        const tlocation = gl.GetUniformLocation(shaderprogram, "chunktime");
        //std.debug.print("{any}\n", .{player});
        //std.debug.print("{d}\n", .{MainWorld.ChunkMeshes.items.len});
        const drawtime = ztracy.ZoneNC(@src(), "Drawtime", 0xf5bf42);
        const it = MainWorld.ChunkMeshes.items;
        if (MainWorld.ToGen.count() == 0 and genbenchmark and benchmarktimer.read() > 1000000000) {
            std.debug.print("finished gen, time:{d} ms\n", .{benchmarktimer.read() / std.time.ns_per_ms});
            genbenchmark = false;
            //return;
        }
        if (genbenchmark == false and MainWorld.ToMesh.len == 0 and meshbenchmark and benchmarktimer.read() > 1000000000) {
            std.debug.print("finished mesh, time:{d} ms\n", .{benchmarktimer.read() / std.time.ns_per_ms});
            meshbenchmark = false;
            //return;
        }
        for (it) |mesh| {
            const drawchunk = ztracy.ZoneNC(@src(), "drawchunk", 0x9692d);
            defer drawchunk.End();
            var tr = std.time.milliTimestamp() - mesh.time;
            if (tr > 1000) tr = 1000;
            gl.Uniform1i(tlocation, @intCast(tr));
            gl.Uniform3i(chunkposlocation, mesh.pos[0], mesh.pos[1], mesh.pos[2]);
            gl.BindVertexArray(mesh.vao);
            //TODO occlusion queries and backface culling and frustrum cullling and early z-rejection
            gl.DrawElementsInstanced(gl.TRIANGLES, indices.len, gl.UNSIGNED_INT, null, @intCast(mesh.count / 2));
        }

        drawtime.End();
        const prossesinput = ztracy.ZoneNC(@src(), "prossesInput", 0x00_ff_00_00);
        try prossesInput(&window, @as(f64, @floatFromInt(inputtimer.lap())) / std.time.ns_per_s);
        prossesinput.End();
        const swap = ztracy.ZoneNC(@src(), "swap", 0x00_ff_00_00);
        window.swapBuffers();
        swap.End();
        const poll = ztracy.ZoneNC(@src(), "poll", 0x00_ff_00_00);
        glfw.pollEvents();
        poll.End();
        //std.debug.print("{d}\r", .{player.pos});
        const unload = ztracy.ZoneNC(@src(), "unload", 0x00_ff_00_00);
        unload.End();
        if (unloadTimer.read() > 2 * std.time.ns_per_ms) {
            unloadTimer.reset();
            const pi = [3]i32{ @intFromFloat(player.pos[0]), @intFromFloat(player.pos[1]), @intFromFloat(player.pos[2]) } / @Vector(3, i32){ 32, 32, 32 };
            //std.debug.print("\n\n{}\n\n", .{it.len});
            std.debug.assert(it.len == MainWorld.ChunkMeshes.items.len);
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
                        std.debug.assert(p.chunkPtr == null);
                        _ = MainWorld.Chunks.remove(p.pos);
                        if (!p.lock.tryLock()) {
                            continue;
                        }
                        allocator.destroy(p);
                    } else {
                        std.debug.print("\n\n\n{} != InMemoryAndMesh or MeshOnly\n", .{p.state});
                    }

                    var l = MainWorld.ChunkMeshes.swapRemove(i);
                    gl.DeleteBuffers(1, @ptrCast(&l.vbo));
                    gl.DeleteVertexArrays(1, @ptrCast(&l.vao));
                }
            }
        }
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
    if (window.getKey(glfw.Key.b) == glfw.Action.press) {
        const chpos = player.pos/@Vector(3, f32){32.0,32.0,32.0};
        const intchpos = @Vector(3, i32){@as(i32,@intFromFloat(@round(chpos[0]))),@as(i32,@intFromFloat(@round(chpos[1]))),@as(i32,@intFromFloat(@round(chpos[2])))};
        var ch = Worldptr.Chunks.get(intchpos);
        if(ch != null and ch.?.chunkPtr != null){
            ch.?.chunkPtr.?.lock.lock();
            std.debug.print("\npos:{d}, fchpos:{d}, chpos:{d}\n", .{player.pos,chpos, intchpos});
            ch.?.chunkPtr.?.* = Generator.InitChunkToBlock(Blocks.Air, intchpos, null);
            _ = try World.RemeshChunk(Worldptr, intchpos+@Vector(3,i32){1,0,0}, allocator);
            _ = try World.RemeshChunk(Worldptr, intchpos+@Vector(3,i32){-1,0,0}, allocator);
            _ = try World.RemeshChunk(Worldptr, intchpos+@Vector(3,i32){0,1,0}, allocator);
            _ = try World.RemeshChunk(Worldptr, intchpos+@Vector(3,i32){0,-1,0}, allocator);
            _ = try World.RemeshChunk(Worldptr, intchpos+@Vector(3,i32){0,0,1}, allocator);
            _ = try World.RemeshChunk(Worldptr, intchpos+@Vector(3,i32){0,0,-1}, allocator);
            _ = try World.RemeshChunk(Worldptr, intchpos+@Vector(3,i32){0,0,0}, allocator);


            

        }
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
