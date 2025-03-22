const std = @import("std");
const zudp = @import("zudp").Connection;
const Network = @import("Network");
const Requests = @import("Requests");
const World = @import("World").World;
const Entitys = @import("Entitys");
const Chunk = @import("Chunk").Chunk;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Cache = @import("cache").Cache;

const op = Network.Options{
    .verify = true,
    .compress_sizel1 = 128,
    .compress_sizel2 = 511,
    .compress_sizel3 = 2047,
    .datasplitsize = 512,
    .rate_limit_bytes_second = null,
};

const Multyplayer = false;
pub fn main() !void {}

pub fn SinglePlayerWorld() !void {
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

    while (true) std.Thread.sleep(100000000000000);
}

pub fn MultiPlayerWorld() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer if (debug_allocator.deinit() == .leak) {
        std.debug.panic("mem leaked", .{});
    } else {};
    const allocator = debug_allocator.allocator();
    const cpu_count = try std.Thread.getCpuCount();
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .n_jobs = cpu_count, .allocator = allocator });
    defer pool.deinit();
    var client = try zudp.init("0.0.0.0", 0, allocator);

    defer client.deinit();
    try client.SpawnTimeoutManager(500 * std.time.us_per_ms, 5 * std.time.ns_per_ms, 5, null, false);
    try client.SpawnListener(Handler, &pool, 65536, 150);
    var buf: [Requests.Ping.max_buffer_size]u8 = undefined;
    const ping_req = Requests.Ping.make(.{ .referrer = "test12345", .referrer_len = 9 }, &buf);
    var buf2: [Requests.Unverifyed_Login.max_buffer_size]u8 = undefined;
    const login_req = Requests.Unverifyed_Login.make(.{
        .version = .Testing,
        .UUID = 0,
        .username_len = 13,
        .username = "banned player",
        .referrer_len = 9,
        .referrer = "127.0.0.1",
        .GenDistance = [2]u32{ 8, 8 },
    }, &buf2);

    while (true) {
        var bf: [32]u8 = undefined;
        const d = try std.io.getStdIn().reader().readUntilDelimiter(&bf, '\n');
        if (d.len == 0) continue;
        switch (d[0]) {
            'p' => try Network.SendPacket(.Ping, ping_req, op, Requests.Ping.max_buffer_size, &client, (try std.net.Address.parseIp("127.0.0.1", 22522)).any),
            'l' => try Network.SendPacket(.Unverifyed_Login, login_req, op, Requests.Unverifyed_Login.max_buffer_size, &client, (try std.net.Address.parseIp("127.0.0.1", 22522)).any),
            else => {},
        }
    }
    std.Thread.sleep(10000000000);
}

pub fn Handler(args: anytype, mem: []const u8, sender: *const std.posix.sockaddr) void {
    //const server: *zudp = args.server;
    _ = sender;
    _ = args;
    var receivebuffer: [524288]u8 = undefined;
    const p = Network.LoadPacket(mem, &receivebuffer) catch |err| {
        std.log.warn("voxelgame loadpacket error: {any}\n", .{err});
        return;
    };
    switch (p.pktType) {
        Requests.PacketType.Pong => {
            const pong = Requests.Pong.load(p.data) catch |err| {
                std.debug.print("err: {any}", .{err});
                return;
            };
            std.debug.print("Pong reiceved:\nversion:{any}, \nserver name: {s},\nMOTD:{s}\n\n", .{ pong.version, pong.server_name, pong.MOTD });
        },

        else => std.debug.print("invalid packettype reiceived\n", .{}),
    }
}
