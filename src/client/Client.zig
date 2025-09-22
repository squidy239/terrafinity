const std = @import("std");
const zudp = @import("zudp").Connection;
const Network = @import("Network");
const Requests = @import("Requests");
pub const zm = @import("zm");
const gl = @import("gl");
const glfw = @import("zglfw");
pub const ztracy = @import("ztracy");
pub const World = @import("World").World;
pub const Renderer = @import("Renderer.zig").Renderer;
const Entity = @import("Entity").Entity;
const UpdateEntitiesThread = @import("Entity").TickEntitiesThread;
const EntityTypes = @import("EntityTypes");
pub const Chunk = @import("Chunk").Chunk;
pub const Block = @import("Block").Blocks;
pub const ThreadPool = @import("ThreadPool");
pub const Loader = @import("Loader.zig");
pub const SetThreadPriority = @import("ThreadPriority").setThreadPriority;
const builtin = @import("builtin");
const root = @import("root"); //TODO fix messy import system with root.Loader etc
const UserInput = @import("UserInput.zig");
pub const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Cache = @import("Cache").Cache;
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

var running = std.atomic.Value(bool).init(true);

pub fn main() !void {
    var proc: gl.ProcTable = undefined;
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer if (debug_allocator.deinit() == .leak) {
        std.debug.panic("mem leaked", .{});
    } else {
        std.debug.print("no leaks\n", .{});
    };
    const prioritySet = SetThreadPriority(.THREAD_PRIORITY_TIME_CRITICAL);
    if (prioritySet) std.debug.print("Render thread priority set\n", .{}) else std.debug.print("Could not set render thread priority\n", .{});
    const allocator = debug_allocator.allocator();
    var threadpool_allocator = std.heap.DebugAllocator(.{}){};
    defer if (threadpool_allocator.deinit() == .leak) {
        std.debug.panic("mem leaked", .{});
    } else {
        std.debug.print("no leaks\n", .{});
    };
    const threadpool_alloc = threadpool_allocator.allocator();
    const cpu_count = try std.Thread.getCpuCount();
    var pool: ThreadPool = undefined;
    try pool.init(.{ .n_jobs = cpu_count - 1, .allocator = threadpool_alloc });
    var rand = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    const seed = (2 << 63) - 1;
    std.log.info("using seed {d}\n", .{seed});
    var MainWorld = World{
        .allocator = allocator,
        .threadPool = &pool,
        .TerrainHeightCache = try Cache([2]i32, [32][32]i32, 8192).init(allocator),
        .Entitys = ConcurrentHashMap(u128, *Entity, std.hash_map.AutoContext(u128), 80, 32).init(allocator),
        .Chunks = ConcurrentHashMap([3]i32, *Chunk, std.hash_map.AutoContext([3]i32), 80, 32).init(allocator),
        .SpawnRange = 0,
        .SpawnCenterPos = [3]i32{ 0, 0, 0 },
        .Rand = rand.random(),
        .GenParams = .{
            .terrainmin = -2048,
            .terrainmax = 2048,
            .seed = seed,
            .TerrainNoise = .{
                .seed = @bitCast(std.hash.Murmur2_32.hashUint64(seed)),
                .fractal_type = .ridged,
                .octaves = 12,
                .noise_type = .perlin,
                .frequency = 0.005,
            },
            .CaveNoise = .{
                .seed = @bitCast(std.hash.Murmur2_32.hashUint64(seed)),
                .fractal_type = .ping_pong,
                .octaves = 8,
                .lacunarity = 2,
                .ping_pong_strength = 2.0,
                .gain = 0.5,
                .noise_type = .perlin,
                .frequency = 0.03,
            },
            .CaveExpansionMax = 4000,
            .CaveExpansionStart = undefined, //TODO
            .Cavesess = -0.7,
        },
    };
    const tempPlayer: EntityTypes.Player = .{
        .player_UUID = 0, //UUID 0 resurved for client
        .player_name = .fromString("squid"),
        .gameMode = .Spectator,
        .OnGround = false,
        .pos = MainWorld.GetPlayerSpawnPos() + @Vector(3, f64){ 0, 100, 0 },
        .bodyRotationAxis = @Vector(3, f16){ 0, 0, 0 },
        .headRotationAxis = @Vector(2, f16){ 0, 0 },
        .armSwings = [2]f16{ 0, 0 }, //right,left
        .hitboxmin = @Vector(3, f64){ -1, 0.8, -1 },
        .hitboxmax = @Vector(3, f64){ 1, 0.2, 1 },
        .Velocity = @splat(0),
    };
    const playerEntity = try tempPlayer.MakeEntity(allocator);

    for (0..0) |_| {
        const tempCube: EntityTypes.Cube = .{
            .velocity = @splat(0),
            .bodyRotationAxis = @splat(0),
            .pos = tempPlayer.pos,
            .timestamp = std.time.microTimestamp(),
        };
        _ = try MainWorld.SpawnEntity(rand.random().int(u128), tempCube);
    }
    const player = @as(*EntityTypes.Player, @ptrCast(@alignCast(playerEntity.ptr)));
    _ = playerEntity.ref_count.fetchAdd(1, .seq_cst);
    try MainWorld.Entitys.put(World.PlayerIDtoEntityId(player.player_UUID), playerEntity);
    _ = playerEntity.ref_count.fetchAdd(1, .seq_cst);
    var renderer = Renderer.Init(&pool, &MainWorld, &proc, &running, player, &playerEntity.lock, allocator) catch |err| {
        std.debug.panic("Failed to initialize renderer: {}\n", .{err});
        return err;
    };
    try EntityTypes.LoadMeshes(allocator);
    const unloaderThread = try std.Thread.spawn(.{}, Loader.ChunkUnloaderThread, .{ &MainWorld, &renderer.LoadDistance, &player.pos, &playerEntity.lock, 40 * std.time.ns_per_ms, &running });
    const loaderThread = try std.Thread.spawn(.{}, Loader.ChunkLoaderThread, .{ &renderer, 40 * std.time.ns_per_ms, &player.pos, &playerEntity.lock, &running });
    const updateEntitiesThread = try std.Thread.spawn(.{}, UpdateEntitiesThread, .{ &MainWorld, 5 * std.time.ns_per_ms, &running });

    defer {
        std.debug.print("started closing\n", .{});
        renderer.window.destroy();
        running.store(false, .monotonic);
        updateEntitiesThread.join();
        std.debug.print("entity update thread stopped\n", .{});
        loaderThread.join();
        unloaderThread.join();
        std.debug.print("loader and unloader threads stopped\n", .{});
        pool.deinit();
        std.debug.print("pool deinit\n", .{});
        EntityTypes.FreeMeshes();
        renderer.deinit();
        _ = playerEntity.ref_count.fetchSub(1, .seq_cst);
        std.debug.print("renderer deinit\n", .{});
        _ = playerEntity.ref_count.fetchSub(1, .seq_cst);
        MainWorld.Deinit() catch |err| std.debug.panic("error: {any}", .{err});
        std.debug.print("World Closed\n", .{});
    }
    UserInput.init(&renderer);

    _ = renderer.window.setCursorPosCallback(UserInput.MouseCallback);
    _ = renderer.window.setSizeCallback(UserInput.glfwSizeCallback);
    var st = std.time.nanoTimestamp();
    while (!renderer.window.shouldClose()) {
        const Frame = ztracy.ZoneNC(@src(), "Frame", 0xFFFFFFFF);
        defer Frame.End();
        try renderer.LoadMeshes(10_000_000);
        const glfinish = ztracy.ZoneNC(@src(), "glfinish", 0x00FF00);
        gl.Finish();
        glfinish.End();
        const swap = ztracy.ZoneNC(@src(), "swap", 456564);
        renderer.window.swapBuffers();
        swap.End();
        const poll = ztracy.ZoneNC(@src(), "poll", 456564);
        glfw.pollEvents();
        poll.End();
        const prossesinput = ztracy.ZoneNC(@src(), "prossesinput", 456765);
        try UserInput.processInput();
        prossesinput.End();
        const waitforlock = ztracy.ZoneNC(@src(), "waitforlock", 2222111);
        playerEntity.lock.lockShared();
        const playerPos = player.pos;
        playerEntity.lock.unlockShared();
        waitforlock.End();
        const printpos = @round(playerPos * @Vector(3, f64){ 100, 100, 100 }) / @Vector(3, f64){ 100, 100, 100 };
        std.debug.print("pos: x: {d} y: {d} z: {d}\t\t\r", .{ printpos[0], printpos[1], printpos[2] });
        //draw chunks
        const blueSky = @Vector(4, f32){ 0, 0.4, 0.8, 1.0 };
        const greySky = @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 };
        const skyColor = mix(blueSky, greySky, @floatCast(@min(1.0, @max(0, playerPos[1] / 4096))));
        const clear = ztracy.ZoneNC(@src(), "Clear", 32213);
        gl.ClearColor(skyColor[0], skyColor[1], skyColor[2], skyColor[3]);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.Clear(gl.DEPTH_BUFFER_BIT);
        clear.End();
        gl.UseProgram(renderer.shaderprogram);

        const drawChunks = ztracy.ZoneNC(@src(), "DrawChunks", 24342);
        renderer.DrawChunks(playerPos, skyColor);
        drawChunks.End();
        const drawEntities = ztracy.ZoneNC(@src(), "drawEntities", 24342);
        renderer.DrawEntities(playerPos);
        drawEntities.End();
        //unload meshes
        const meshDistance = [3]u32{ renderer.MeshDistance[0].load(.seq_cst), renderer.MeshDistance[1].load(.seq_cst), renderer.MeshDistance[2].load(.seq_cst) };
        const floatPlayerChunkPos = playerPos / @as(@Vector(3, f64), @splat(32));
        const playerChunkPos = @as(@Vector(3, i32), @intFromFloat(floatPlayerChunkPos));
        Loader.UnloadMeshes(&renderer, meshDistance, playerChunkPos);
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
