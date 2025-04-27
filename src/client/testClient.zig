const std = @import("std");
const zudp = @import("zudp").Connection;
const Network = @import("Network");
const Requests = @import("Requests");
const Handler = @import("Handler.zig").Handler;
const World = @import("World").World;
threadlocal var receivebuffer: [524288]u8 = undefined;
const Chunk = @import("Chunk");

pub const op = Network.Options{
    .rate_limit_bytes_second = null,
    .compress_sizel1 = 64,
    .compress_sizel2 = 300,
    .compress_sizel3 = 1500,
    .datasplitsize = 360,
};

pub fn main() !void {
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
    try client.SpawnListener(Handler, listenparams{ .server = &client }, 65536, 150);
    var buf: [Requests.Ping.max_buffer_size]u8 = undefined;
    const ping_req = Requests.Ping.make(.{ .referrer = "test12345", .referrer_len = 9, .version = .Testing }, &buf);
    var buf2: [Requests.LoginStart.max_buffer_size]u8 = undefined;
    const login_req = Requests.LoginStart.make(.{
        .version = .Testing,
        .UUID = 0,
        .username_len = 6,
        .username = "player",
        .referrer_len = 9,
        .referrer = "127.0.0.1",
    }, &buf2);
    const server = try std.net.Address.parseIp("127.0.0.1", 22522);

    std.debug.print("starting testClient...\n", .{});
    while (true) {
        var bf: [32]u8 = undefined;
        const d = try std.io.getStdIn().reader().readUntilDelimiter(&bf, '\n');
        if (d.len == 0) continue;
        switch (d[0]) {
            'p' => try Network.SendPacket(.ServerboundPing, ping_req, op, true, &client, server.any),
            'l' => try Network.SendPacket(.ServerboundLoginStart, login_req, op, true, &client, server.any),
            else => {},
        }
    }
    std.Thread.sleep(10000000000);
}

const listenparams = struct {
    server: *zudp,
};
