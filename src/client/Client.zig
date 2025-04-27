const std = @import("std");
const zudp = @import("zudp").Connection;
const Network = @import("Network");
const Requests = @import("Requests");
const zm = @import("zm");
const gl = @import("gl");
const glfw = @import("zglfw");
const ztracy = @import("ztracy");
const World = @import("World").World;
const Renderer = @import("Renderer.zig").Renderer;
const Entity = @import("Entity").Entity;
const Chunk = @import("Chunk").Chunk;
const Loader = @import("Loader.zig");
const UserInput = @import("UserInput.zig");
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Cache = @import("cache").Cache;
var lastx: f64 = undefined;
var lasty: f64 = undefined;
var cameraFront = @Vector(3, f64){ 0, 1, 0 };
var cameraUp = @Vector(3, f64){ 0, 1, 0 };
var pitch: f64 = 1;
var yaw: f64 = 1;
var height: u32 = 800;
var width: u32 = 600;

const op = Network.Options{
    .verify = true,
    .compress_sizel1 = 128,
    .compress_sizel2 = 511,
    .compress_sizel3 = 2047,
    .datasplitsize = 512,
    .rate_limit_bytes_second = null,
};

const Multyplayer = false;
//TODO list
//chunk loader thread(singleplayer and multiplayer)
//server world and server chunk load response
//player log into server, verify client ip
//player send all keyboard inputs to server at a configurable max rate, default maybie 144?
//server sends back updated player position so no hacking, player visually moves client side but gets corrected if move is wrong
//entitys
//need to redo physecs completely, trace player path, configurable gravity and each gas or liquid has its own propertys (not just air)
//finally do textures
//new trees
//AUTH server and fully functional multyplayer
//blockdata(hashmap with blockpos as key)
//GUI
//website for game

var running = std.atomic.Value(bool).init(true);

pub fn main() !void {
    var proc: gl.ProcTable = undefined;

    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer if (debug_allocator.deinit() == .leak) {
        std.debug.panic("mem leaked", .{});
    } else {
        std.debug.print("no leaks\n", .{});
    };
    //const allocator = debug_allocator.allocator();

    const allocator = debug_allocator.allocator();
    var sfa = std.heap.stackFallback(5000000, allocator);
    var sfalloc = std.heap.ThreadSafeAllocator{ .child_allocator = sfa.get() };
    const cpu_count = try std.Thread.getCpuCount();
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .n_jobs = cpu_count - 2, .allocator = sfalloc.allocator() });
    var rand = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    const seed = rand.random().int(u64);
    std.log.info("using seed {d}\n", .{seed});
    var MainWorld = World{
        .allocator = allocator,
        .threadPool = &pool,
        .TerrainHeightCache = try Cache([32][32]i32).init(sfalloc.allocator(), .{}),
        .TerrainHeightCacheMutex = .{},
        .Entitys = ConcurrentHashMap(u128, *Entity, std.hash_map.AutoContext(u128), 80, 32).init(allocator),
        .Chunks = ConcurrentHashMap([3]i32, *Chunk, std.hash_map.AutoContext([3]i32), 80, 32).init(allocator),
        .SpawnRange = 0,
        .SpawnCenterPos = [3]i32{ 0, 0, 0 },
        .SpawnRand = rand.random(),
        .GenParams = .{
            .terrainmin = -256,
            .terrainmax = 256,
            .seed = seed,
            .TerrainNoise = .{
                .seed = @bitCast(std.hash.Murmur2_32.hashUint64(seed)),
                .fractal_type = .ridged,
                .octaves = 16,
                .noise_type = .value,
                .frequency = 0.07,
            },
        },
    };

    std.debug.print("gp: {any}\n", .{MainWorld.GenParams.TerrainNoise});
    var renderer = try Renderer.Init(&pool, &MainWorld, &proc, MainWorld.GetPlayerSpawnPos(), &running, allocator);
    const unloaderThread = try std.Thread.spawn(.{}, Loader.ChunkUnloaderThread, .{ &MainWorld, &renderer.LoadDistance, &renderer.eyePos, 40 * std.time.ns_per_ms, &running });
    const loaderThread = try std.Thread.spawn(.{}, Loader.ChunkLoaderThread, .{ &renderer, null, 40 * std.time.ns_per_ms, &running });
    defer {
        std.debug.print("started closing\n", .{});
        renderer.window.destroy();
        running.store(false, .monotonic);
        loaderThread.join();
        unloaderThread.join();
        std.debug.print("loader and unloader Threads stopped\n", .{});
        pool.deinit();
        std.debug.print("pool deinit\n", .{});
        renderer.deinit();
        std.debug.print("renderer deinit\n", .{});
        MainWorld.Deinit() catch |err| std.debug.panic("error: {any}", .{err});
        std.debug.print("World Closed\n", .{});
    }
    UserInput.init(&renderer);

    _ = renderer.window.setCursorPosCallback(UserInput.MouseCallback);
    _ = renderer.window.setSizeCallback(UserInput.glfwSizeCallback);
    var st = std.time.nanoTimestamp();
    while (!renderer.window.shouldClose()) {
        const loadmeshes = ztracy.ZoneNC(@src(), "loadmeshes", 2222111);
        try renderer.LoadMeshes(10000);
        loadmeshes.End();
        renderer.window.swapBuffers();
        glfw.pollEvents();
        try UserInput.processInput();
        std.debug.print("pos:{d}, front:{d}\t\t\r", .{ renderer.eyePos, renderer.cameraFront });
        const blueSky = @Vector(4, f32){ 0, 0.4, 0.8, 1.0 };
        const greySky = @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 };
        const skyColor = mix(blueSky, greySky, @floatCast(@min(1.0, @max(0, renderer.eyePos[1] / 4096))));
        gl.ClearColor(skyColor[0], skyColor[1], skyColor[2], skyColor[3]);

        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.Clear(gl.DEPTH_BUFFER_BIT);
        gl.Uniform4f(renderer.uniforms.skyColor, skyColor[0], skyColor[1], skyColor[2], skyColor[3]);
        gl.Uniform1f(renderer.uniforms.fogDensity, 0.001 + @as(f32, @floatCast(renderer.eyePos[1] / 800000)));
        const projview = @as(@Vector(16, f32), @floatCast(zm.Mat4.perspective(std.math.degreesToRadians(90.0), @as(f32, @floatFromInt(renderer.screen_dimensions[0])) / @as(f32, @floatFromInt(renderer.screen_dimensions[1])), 0.1, @floatFromInt(200 * 32)).multiply(zm.Mat4.lookAt(@Vector(3, f32){ 0, 0, 0 }, @Vector(3, f32){ 0, 0, 0 } + renderer.cameraFront, Renderer.cameraUp)).data));
        gl.UniformMatrix4fv(renderer.uniforms.projviewlocation, 1, gl.TRUE, @ptrCast(&(projview)));
        const sunrot = zm.Mat4.rotation(@Vector(3, f32){ 1.0, 0.0, 0.0 }, std.math.degreesToRadians(@as(f32, @floatFromInt(@mod(@divFloor(std.time.milliTimestamp(), 100), 360)))));
        gl.UniformMatrix4fv(renderer.uniforms.sunlocation, 1, gl.TRUE, @ptrCast(&(sunrot)));

        const drawChunks = ztracy.ZoneNC(@src(), "DrawChunks", 24342);
        renderer.DrawChunks();
        const meshDistance = [3]u32{ renderer.MeshDistance[0].load(.seq_cst), renderer.MeshDistance[1].load(.seq_cst), renderer.MeshDistance[2].load(.seq_cst) };
        Loader.UnloadMeshes(&renderer, meshDistance);
        drawChunks.End();
        st = std.time.nanoTimestamp();
    }
}

fn processInput(window: *glfw.Window, cameraPos: *@Vector(3, f64), camerafront: @Vector(3, f64), cameraup: @Vector(3, f64)) void {
    const cameraSpeed: @Vector(3, f64) = @splat(2); // adjust accordingly
    if (window.getKey(glfw.Key.w) == .press)
        cameraPos.* += cameraSpeed * camerafront;
    if (window.getKey(glfw.Key.s) == .press)
        cameraPos.* -= cameraSpeed * camerafront;
    if (window.getKey(glfw.Key.a) == .press)
        cameraPos.* -= zm.vec.normalize(zm.vec.cross(camerafront, cameraup)) * cameraSpeed;
    if (window.getKey(glfw.Key.d) == .press)
        cameraPos.* += zm.vec.normalize(zm.vec.cross(camerafront, cameraup)) * cameraSpeed;
}

fn mix(start: @Vector(4, f32), end: @Vector(4, f32), interpValue: f32) @Vector(4, f32) {
    const iv: @Vector(4, f32) = @splat(interpValue);
    const ones: @Vector(4, f32) = comptime @splat(1);
    return start * (ones - iv) + end * iv;
}
