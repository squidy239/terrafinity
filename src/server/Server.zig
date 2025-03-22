const std = @import("std");
const zudp = @import("zudp").Connection;
const Network = @import("Network");
const Requests = @import("Requests");
const server_version: Requests.Version = .Testing;
const World = @import("World").World;
const Entitys = @import("Entitys");
const Chunk = @import("Chunk").Chunk;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Cache = @import("cache").Cache;
const Handler = @import("Handler.zig").Handler;

pub const op = Network.Options{
    .verify = true,
    .compress_sizel1 = 128,
    .compress_sizel2 = 511,
    .compress_sizel3 = 2047,
    .datasplitsize = 512,
    .rate_limit_bytes_second = null,
};

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer if (debug_allocator.deinit() == .leak) {
        std.debug.panic("mem leaked", .{});
    } else {
        std.debug.print("no leaks\n", .{});
    };
    const allocator = debug_allocator.allocator();
    const cpu_count = try std.Thread.getCpuCount();
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .n_jobs = cpu_count, .allocator = allocator });
    defer pool.deinit();
    var MainWorld = World{
        .allocator = allocator,
        .threadPool = &pool,
        .TerrainHeightCache = try Cache([32][32]i32).init(allocator, .{}),
        .TerrainHeightCacheMutex = .{},
        .Players = ConcurrentHashMap(u128, *Entitys.Player, std.hash_map.AutoContext(u128), 80, 32).init(allocator),
        .Chunks = ConcurrentHashMap([3]i32, Chunk, std.hash_map.AutoContext([3]i32), 80, 32).init(allocator),
        .GenParams = .{
            .terrainmin = -256,
            .terrainmax = 512,
            .seed = 0,
            .TerrainNoise = .{
                .fractal_type = .ridged,
                .octaves = 10,
                .frequency = 0.01,
            },
        },
    };
    defer MainWorld.Deinit();
    //try MainWorld.LoadChunk([3]i32{ 0, 0, 0 });
    var server = try zudp.init("0.0.0.0", 22522, allocator);
    defer server.deinit();
    try server.SpawnTimeoutManager(500 * std.time.us_per_ms, 5 * std.time.ns_per_ms, 5, null, false);
    try server.SpawnListener(Handler, listenparams{ .world = &MainWorld, .server = &server }, 65536, 150);
    while (true) std.Thread.sleep(100000000000000);
}

//fn TimeoutFunctio

const listenparams = struct {
    world: *World,
    server: *zudp,
};
