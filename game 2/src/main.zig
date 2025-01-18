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
const Physics = @import("./entities/Physics.zig");
const pw = @import("./chunk/World.zig").pw;
const ChunkMesh = @import("./chunk/World.zig").ChunkMesh;
const DistanceOrder = @import("./chunk/World.zig").DistanceOrder;
const Entitys = @import("./entities/Entitys.zig");
const ConcurrentHashMap = @import("./libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const RayIntersection = @import("./chunk//RayIntersection.zig");

var procs: gl.ProcTable = undefined;
var gpa = (std.heap.GeneralPurposeAllocator(.{
    .thread_safe = true,
    //.safety = false,

}){});
var c_allocator = std.heap.ThreadSafeAllocator{ .child_allocator = std.heap.c_allocator };
var main_c_allocator = std.heap.ThreadSafeAllocator{ .child_allocator = std.heap.c_allocator };

const allocator = gpa.allocator();
var width: u32 = 800;
var height: u32 = 600;
var Worldptr: *World = undefined;
var lastfullscreenedtime: i128 = 0;
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

var lastX: f64 = undefined;
var lastY: f64 = undefined;

//change gamemode here
const GameMode = Entitys.GameMode.Spectator;
//

var player: Entitys.Player = Entitys.Player{
    .yaw = 0,
    .gameMode = GameMode,
    .inWater = false,
    .cameraFront = @Vector(3, f64){ 0.0, 0.0, 0.0 },
    .cameraUp = @Vector(3, f64){ 0.0, 1.0, 0.0 },
    .pitch = 0,
    .roll = 0,
    .hitboxmin = @Vector(3, f64){ 0.3, 2.0, 0.3 },
    .hitboxmax = @Vector(3, f64){ 0.3, 0.3, 0.3 },
    .Movement = @Vector(3, f64){ 0.0, 0.0, 0.0 },
    .speed = switch (GameMode) {
        Entitys.GameMode.Spectator => @Vector(3, f32){ 200.0, 200.0, 200.0 },
        Entitys.GameMode.Creative => @Vector(3, f32){ 20.0, 20.0, 20.0 },
        Entitys.GameMode.Survival => @Vector(3, f32){ 15.0, 5.0, 15.0 },
    },
    .pos = @Vector(3, f64){ 0.0, 10.0, 0.0 },
    .OnGround = false,
    .GenDistance = [3]u32{ 20, 20, 20 },
    .LoadDistance = [3]u32{ 20, 20, 20 },
    .MeshDistance = [3]u32{ 20, 20, 20 },
    .lock = .{},
};

var fullscreen: bool = false;
//time:2500 ms 11/24/2024
//
pub fn main() !void {
    const cpu_count = try std.Thread.getCpuCount();
    lastX = @floatFromInt(width / 2);
    lastY = @floatFromInt(height / 2);
    const pt = if (glfw.platformSupported(.wayland)) glfw.PlatformType.wayland else glfw.PlatformType.any;
    if (!glfw.init(.{ .platform = pt })) {
        std.debug.panic("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        return error.GLFWInitFailed;
    }

    var window = glfw.Window.create(width, height, "voxelgame", null, null, .{
        .context_version_major = 4,
        .context_version_minor = 6,
        .opengl_profile = .opengl_core_profile,
        .opengl_forward_compat = true,
        .samples = 4,
        //.transparent_framebuffer = true,
        //.decorated = false,

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

    //shader herema

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
        .TransparentChunkMeshes = std.ArrayList(RenderIDs).init(allocator),
        //using seprate allocator
        .TerrainHeightCache = try cache.Cache([32][32]i32).init(c_allocator.allocator(), .{ .segment_count = 1, .gets_per_promote = 1, .max_size = 1000 }),
        .TerrainHeightCacheMutex = .{},
        .MeshesToLoadMutex = .{},
        .ToUnloadMutex = .{},
        .ToUnload = std.DoublyLinkedList([3]i32){},
        .TerrainNoise = Noise.Noise(f32){
            .seed = 0,
            .noise_type = .perlin,
            .frequency = 0.00008,
            .fractal_type = .none,
            .octaves = 1,
        },
        .CaveNoise = Noise.Noise(f32){
            .seed = 0,
            .noise_type = .simplex_smooth,
            .fractal_type = .none,
            .frequency = 0.009,
            .octaves = 1,
        },
        .TerrainNoise2 = Noise.Noise(f32){
            .seed = 0,
            .noise_type = .perlin,
            .frequency = 0.0002,
            .fractal_type = .ridged,
            .octaves = 12,
        },

        .min = 0,
        .max = 5024,
        // 0 is most cavey 1 is least cavey
        .caveness = 0.4,
    };

    var physicsTimer = try std.time.Timer.start();

    var g = try std.Thread.spawn(.{}, World.AddToGen, .{ &MainWorld, &player, 20 * std.time.ns_per_ms, allocator });
    //TODO put in threadpool
    //var ph = try std.Thread.spawn(.{}, Physics.PlayerPhysicsLoop, .{ &player, &physicsTimer, &MainWorld });
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
    //var atlas = try Textures.LoadAtlas("./Textures/BlockTextures.png", allocator);
    //var BlockTextures: c_uint = undefined;
    //gl.GenTextures(1, @ptrCast(&BlockTextures));

    //gl.BindTexture(gl.TEXTURE_2D, BlockTextures);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    //gl.TextureParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    //gl.TextureParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    //gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, @intCast(atlas.width), @intCast(atlas.height), 0, gl.RGBA, gl.UNSIGNED_BYTE, @ptrCast(atlas.data));
    // gl.GenerateMipmap(gl.TEXTURE_2D);
    //const AtlasHeightLocation = gl.GetUniformLocation(shaderprogram, "AtlasHeight");
    //gl.Uniform1ui(AtlasHeightLocation, @intCast(atlas.height));
    //atlas.deinit();
    //clean up
    defer {
        MainWorld.running.store(false, .seq_cst);
        window.destroy();
        gl.DeleteBuffers(1, @ptrCast(&ebo));
        gl.DeleteBuffers(1, @ptrCast(&facebuffer));
        gl.DeleteProgram(shaderprogram);
        for (MainWorld.ChunkMeshes.items) |mesh| {
            gl.DeleteBuffers(1, @constCast(@ptrCast(&mesh.vbo)));
            gl.DeleteVertexArrays(1, @constCast(@ptrCast(&mesh.vao)));
        }
        glfw.terminate();
        ul.join();
        std.debug.print("ooo", .{});
        g.join();
        u.join();
        std.debug.print("\nggg", .{});
        //ph.join();
        std.debug.print("\nph", .{});
        //gl.DeleteTextures(1, @ptrCast(&BlockTextures));
        // Clean up GLFW
        MainWorld.deinit(allocator);
    }
    //higher cpu count than system somehow benifits this
    std.debug.print("\ncpu_count: {}\n", .{cpu_count});

    var starttimer = try std.time.Timer.start();
    var unloadTimer = try std.time.Timer.start();

    // var genbenchmark = true;
    // var meshbenchmark = true;
    const projviewlocation = gl.GetUniformLocation(shaderprogram, "projview");
    const relativechunkposlocation = gl.GetUniformLocation(shaderprogram, "relativechunkpos");
    const chunkposlocation = gl.GetUniformLocation(shaderprogram, "chunkpos");
    const tlocation = gl.GetUniformLocation(shaderprogram, "chunktime");
    const sunlocation = gl.GetUniformLocation(shaderprogram, "sunrot");
    const scalelocation = gl.GetUniformLocation(shaderprogram, "scale");
    const timelocation = gl.GetUniformLocation(shaderprogram, "time");

    var frame: u64 = 0;
    while (!window.shouldClose()) {
        //need to submit draw calls quicker and batch chunk loading
        frame +|= 1;
        //_ = try MainWorld.pool.spawn(Physics.PlayerPhysics, .{&player, &physicsTimer, &MainWorld});
        const tracy_zone = ztracy.ZoneNC(@src(), "Frametime", 0x00_ff_00_00);
        defer tracy_zone.End();
        gl.ClearColor(0, 0.3, 0.5, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.Clear(gl.DEPTH_BUFFER_BIT);
        const projview = @as(@Vector(16, f32), @floatCast(zm.Mat4d.perspective(zm.toRadians(90.0), @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)), 0.1, 2000).multiply(zm.Mat4d.lookAt(@Vector(3, f32){ 0, 0, 0 }, @Vector(3, f32){ 0, 0, 0 } + player.cameraFront, player.cameraUp)).data));
        gl.UniformMatrix4fv(projviewlocation, 1, gl.TRUE, @ptrCast(&(projview)));
        const sunrot = zm.Mat4f.rotation(@Vector(3, f32){ 1.0, 0.0, 0.0 }, zm.toRadians(@as(f32, @floatFromInt(@mod(@divFloor(std.time.milliTimestamp(), 100), 360)))));
        gl.UniformMatrix4fv(sunlocation, 1, gl.TRUE, @ptrCast(&(sunrot)));

        //std.debug.print("{d}\n", .{MainWorld.ChunkMeshes.items.len});
        const drawtime = ztracy.ZoneNC(@src(), "Drawtime", 0xf5bf42);
        const it = MainWorld.ChunkMeshes.items;
        player.lock.lockShared();
        const ploc = player.pos;
        player.lock.unlockShared();
        var drawnchunks: u64 = 0;
        const millitimestamp = std.time.milliTimestamp();
        gl.Uniform1d(timelocation, @floatFromInt(millitimestamp)); //bool
        inline for (0..2) |i| {
            if (i == 1) gl.Disable(gl.CULL_FACE);
            defer gl.Enable(gl.CULL_FACE);
            for (it) |mesh| {
                gl.BindVertexArray(mesh.vao[i] orelse continue);
                drawnchunks += 1;
                var tr = millitimestamp - mesh.time;
                if (tr > 1000) {
                    @branchHint(.likely);
                    tr = 1000;
                }
                gl.Uniform1f(scalelocation, mesh.scale);
                gl.Uniform1i(tlocation, @intCast(tr));
                gl.Uniform3i(chunkposlocation, mesh.pos[0], mesh.pos[1], mesh.pos[2]);
                //                                                                                                                                                                                                     //player height
                gl.Uniform3f(relativechunkposlocation, @floatCast((@as(f64, @floatFromInt(mesh.pos[0])) * mesh.scale * 32.0) - ploc[0]), @floatCast((@as(f64, @floatFromInt(mesh.pos[1])) * mesh.scale * 32.0) - ploc[1]), @floatCast((@as(f64, @floatFromInt(mesh.pos[2])) * mesh.scale * 32.0) - ploc[2]));
                //TODO frustrum cullling and LODs
                gl.DrawElementsInstanced(gl.TRIANGLES, indices.len, gl.UNSIGNED_INT, null, @intCast(mesh.count[i] / 2));
            }
        }
        drawtime.End();

        const prossesinput = ztracy.ZoneNC(@src(), "prossesInput", 0x00_ff_00_00);
        glfw.pollEvents();
        try prossesInput(window, @as(f64, @floatFromInt(inputtimer.lap())) / std.time.ns_per_s);
        prossesinput.End();
        const physics = ztracy.ZoneNC(@src(), "physics", 754574);
        Physics.PlayerPhysics(&player, &physicsTimer, &MainWorld);
        physics.End();

        {
            //std.debug.print("gen\n", .{});
            const loadmeshestop = ztracy.ZoneNC(@src(), "loadmeshestop", 0x00_ff_00_00);
            defer loadmeshestop.End();
            _ = try MainWorld.LoadMeshes(ebo, facebuffer, allocator, &MainWorld, 4 * std.time.ns_per_ms);
        }

        if (unloadTimer.read() > 2 * std.time.ns_per_ms) {
            const unload = ztracy.ZoneNC(@src(), "unload", 0x00_ff_00_00);
            defer unload.End();
            unloadTimer.reset();
            World.UnloadMeshes(&player, &MainWorld);
        }
        std.debug.print("{d} chunks drawn, pos:{d}, avg fps:{d}, onGround:{}              \r", .{ drawnchunks, @round(player.pos), @divFloor(frame + 1, @divFloor(starttimer.read(), std.time.ns_per_s) + 1), player.OnGround });

        const poll = ztracy.ZoneNC(@src(), "finish", 0x00_ff_00_00);
        gl.Finish();
        poll.End();
        const swap = ztracy.ZoneNC(@src(), "swap", 0x00_ff_00_00);
        window.swapBuffers();
        swap.End();
    }
    std.debug.print("\n\nclosing", .{});
}

fn glfwSizeCallback(window: glfw.Window, w: u32, h: u32) void {
    width = w;
    height = h;
    gl.Viewport(0, 0, @intCast(w), @intCast(h));
    _ = window;
}

fn MouseCallback(window: glfw.Window, xpos: f64, ypos: f64) void {
    if (glfw.Window.getInputModeCursor(window) == glfw.Window.InputModeCursor.disabled) {
        @branchHint(.likely);
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
    if (window.getMouseButton(.left) == glfw.Action.press) {
        if (glfw.Window.getInputModeCursor(window) != glfw.Window.InputModeCursor.disabled){
            glfw.Window.setInputModeCursor(window, .disabled);}
        else {
            RayIntersection.BreakFirstBlockOnRay(player.pos+@Vector(3,f64){0.0,player.hitboxmin[1],0.0}, 20.0, player.cameraFront, Worldptr,allocator) catch |err|{std.debug.panic("\n\n{any}\n\n", .{err});};
        }
    }
}

fn prossesInput(window: glfw.Window, dt: f64) !void {
    player.lock.lock();
    defer player.lock.unlock();
    const deltaTime: f32 = @floatCast(dt);
    var cf = player.cameraFront;
    if (player.gameMode != Entitys.GameMode.Spectator) cf[1] = 0;
    const cameraSpeed: zm.Vec3f = zm.Vec3f{ deltaTime, deltaTime, deltaTime } * player.speed;
    if (window.getKey(glfw.Key.w) == glfw.Action.press) {
        if (player.gameMode != Entitys.GameMode.Survival or player.OnGround or player.inWater) {
            player.Movement += (cameraSpeed * cf);
        } else if (player.gameMode == Entitys.GameMode.Survival) {
            player.Movement += (cameraSpeed * cf * @Vector(3, f64){ 0.1, 0.1, 0.1 });
        }
    }
    if (window.getKey(glfw.Key.s) == glfw.Action.press) {
        if (player.gameMode != Entitys.GameMode.Survival or player.OnGround or player.inWater) {
            player.Movement -= (cameraSpeed * cf);
        } else if (player.gameMode == Entitys.GameMode.Survival) {
            player.Movement -= (cameraSpeed * cf * @Vector(3, f64){ 0.1, 0.1, 0.1 });
        }
    }

    if (window.getKey(glfw.Key.a) == glfw.Action.press) {
        if (player.gameMode != Entitys.GameMode.Survival or player.OnGround or player.inWater) {
            player.Movement -= zm.vec.normalize(zm.vec.cross(cf, player.cameraUp)) * cameraSpeed;
        } else if (player.gameMode == Entitys.GameMode.Survival) {
            player.Movement -= (zm.vec.normalize(zm.vec.cross(cf, player.cameraUp)) * cameraSpeed * @Vector(3, f64){ 0.1, 0.1, 0.1 });
        }
    }

    if (window.getKey(glfw.Key.d) == glfw.Action.press and (player.gameMode != Entitys.GameMode.Survival or player.OnGround or player.inWater)) {
        if (player.gameMode != Entitys.GameMode.Survival or player.OnGround or player.inWater) {
            player.Movement += zm.vec.normalize(zm.vec.cross(cf, player.cameraUp)) * cameraSpeed;
        } else if (player.gameMode == Entitys.GameMode.Survival) {
            player.Movement += (zm.vec.normalize(zm.vec.cross(cf, player.cameraUp)) * cameraSpeed * @Vector(3, f64){ 0.1, 0.1, 0.1 });
        }
    }

    if (window.getKey(glfw.Key.space) == glfw.Action.press and (player.gameMode != Entitys.GameMode.Survival or player.OnGround or player.inWater)) {
        if (player.gameMode == Entitys.GameMode.Survival and (!player.inWater or player.OnGround)) {
            player.Movement[1] += player.speed[1];
        } else player.Movement[1] += cameraSpeed[1];
    }
    if (window.getKey(glfw.Key.left_shift) == glfw.Action.press or window.getKey(glfw.Key.right_shift) == glfw.Action.press)
        player.Movement[1] -= cameraSpeed[1];
    if (window.getKey(glfw.Key.left_control) == glfw.Action.press and !fast) {
        if (player.gameMode != Entitys.GameMode.Survival) {
            player.speed *= @splat(30.0);
        } else {
            player.speed *= @Vector(3, f32){ 2.0, 1.0, 2.0 };
        }
        fast = true;
    }
    if (window.getKey(glfw.Key.left_control) == glfw.Action.release and fast) {
        if (player.gameMode != Entitys.GameMode.Survival) {
            player.speed /= @splat(30.0);
        } else {
            player.speed /= @Vector(3, f32){ 2.0, 1.0, 2.0 };
        }
        fast = false;
    }
    if (window.getKey(glfw.Key.escape) == glfw.Action.press or window.getKey(glfw.Key.left_super) == glfw.Action.press) {
        if (glfw.Window.getInputModeCursor(window) != glfw.Window.InputModeCursor.normal)
            glfw.Window.setInputModeCursor(window, .normal);
    }
    
    if (window.getKey(glfw.Key.b) == glfw.Action.press) {
        std.debug.print("\n\n{any}\n\n", .{(Worldptr.Chunks.get(@as(@Vector(3, i32), @intFromFloat((player.pos+@Vector(3, f64){16,16,16})/@Vector(3, f64){32,32,32}))) orelse {return;}).state});
    }

    if (window.getKey(glfw.Key.F11) == glfw.Action.press and (std.time.nanoTimestamp() - lastfullscreenedtime) > 400 * std.time.ns_per_ms) {
        defer lastfullscreenedtime = std.time.nanoTimestamp();
        //std.debug.print("\n fs:{} < {}", .{lastfullscreenedtime -  std.time.nanoTimestamp(),400 * std.time.ns_per_ms});
        const w = glfw.Monitor.getPrimary().?.getVideoMode().?.getWidth();
        const h = glfw.Monitor.getPrimary().?.getVideoMode().?.getHeight();
        if (!fullscreen) {
            width = w;
            height = h;
            window.setMonitor(glfw.Monitor.getPrimary(), 0, 0, w, h, null);
            fullscreen = true;
        } else {
            window.setMonitor(null, 100, 100, 800, 600, null);
            width = 800;
            height = 600;
            fullscreen = false;
        }
    }
}
