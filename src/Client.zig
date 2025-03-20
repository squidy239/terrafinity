const std = @import("std");
const zudp = @import("zudp").Connection;
const Network = @import("protocol/Network.zig");
const Requests = @import("protocol/Requests.zig");
const op = Network.Options{
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
    } else {};
    const allocator = debug_allocator.allocator();
    const cpu_count = try std.Thread.getCpuCount();
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .n_jobs = cpu_count, .allocator = allocator });
    defer pool.deinit();
    var client = try zudp.init("0.0.0.0", 54546, allocator);
    defer client.deinit();
    try client.SpawnTimeoutManager(500 * std.time.us_per_ms, 5 * std.time.ns_per_ms, 5, null, false);
    try client.SpawnListener(null, &pool, 65536, 150);
    var buf: [Requests.Ping.max_buffer_size]u8 = undefined;
    const req = Requests.Ping.make(.{ .referrer = "test12345", .referrer_len = 9 }, &buf);
    try Network.SendPacket(.Ping, req, op, Requests.Ping.max_buffer_size, &client, (try std.net.Address.parseIp("127.0.0.1", 22522)).any);
    std.Thread.sleep(10000000000);
}
