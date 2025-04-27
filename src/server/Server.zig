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
    .compress_sizel1 = 128,
    .compress_sizel2 = 511,
    .compress_sizel3 = 2047,
    .datasplitsize = 512,
    .rate_limit_bytes_second = null,
};

const maxGenDistance = [3]u32{ 20, 20, 20 };

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
    var prng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
    const rand = prng.random();
    var MainWorld = World{
        .allocator = allocator,
        .threadPool = &pool,
        .SpawnRange = 100,
        .SpawnCenterPos = [3]i32{ 0, 0, 0 },
        .SpawnRand = rand,
        .TerrainHeightCache = try Cache([32][32]i32).init(allocator, .{}),
        .TerrainHeightCacheMutex = .{},
        .Entitys = ConcurrentHashMap(u128, *Entitys.Entity, std.hash_map.AutoContext(u128), 80, 32).init(allocator),
        .Chunks = ConcurrentHashMap([3]i32, *Chunk, std.hash_map.AutoContext([3]i32), 80, 32).init(allocator),
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
    defer MainWorld.Deinit() catch |err| std.debug.panic("err:{any}\n", .{err});
    //try MainWorld.LoadChunk([3]i32{ 0, 0, 0 });
    var server = try zudp.init("0.0.0.0", 22522, allocator);
    defer server.deinit();
    try server.SpawnTimeoutManager(500 * std.time.us_per_ms, 5 * std.time.ns_per_ms, 5, null, false);
    try server.SpawnListener(Handler, listenparams{ .world = &MainWorld, .server = &server }, 65536, 150);
    while (true) std.Thread.sleep(100000000000000);
}

//fn TimeoutFunctio

pub const Server = struct {
    allocator: std.mem.Allocator,
    world: World,
    zudpServer: zudp,
    IPverifyNumberHashMap: ConcurrentHashMap(std.posix.sockaddr, u64, std.hash_map.AutoContext(std.posix.sockaddr), 80, 8),
    PlayersByAddr: ConcurrentHashMap(std.posix.sockaddr, *Entitys.Player, std.hash_map.AutoContext(std.posix.sockaddr), 80, 32), //TODO change to ket:addr, val:connection state including uuid
    NetworkOptions: Network.Options,
    maxGenDistance: [3]u32,
    ServerDescription: []const u8,
    ServerName: []const u8,
    ReferrerRules: []const ReferrerRule,
    AllowedDeniedPlayerList: std.AutoHashMap(u128, bool), //true to allow, false to deny
};
const ReferrerRule = struct {
    AllowDeny: bool, //true to allow trafic, false to deny
    Referrer: []const u8,
};
const listenparams = struct {
    world: *World,
    server: *zudp,
};
