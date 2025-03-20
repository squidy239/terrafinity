const std = @import("std");
const zudp = @import("zudp").Connection;
const Network = @import("protocol/Network.zig");
const Requests = @import("protocol/Requests.zig");
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

    var server = try zudp.init("0.0.0.0", 22522, allocator);
    defer server.deinit();
    try server.SpawnTimeoutManager(500 * std.time.us_per_ms, 5 * std.time.ns_per_ms, 5, null, false);
    try server.SpawnListener(Handler, listenparams{ .threadpool = &pool, .server = &server }, 65536, 150);
    while (true) std.Thread.sleep(100000000000);
}

const listenparams = struct {
    threadpool: *std.Thread.Pool,
    server: *zudp,
};

pub fn Handler(args: anytype, mem: []const u8, sender: *const std.posix.sockaddr) void {
    const op = Network.Options{
        .verify = true,
        .compress_sizel1 = 128,
        .compress_sizel2 = 511,
        .compress_sizel3 = 2047,
        .datasplitsize = 512,
        .rate_limit_bytes_second = null,
    };
    const server: *zudp = args.server;
    var receivebuffer: [524288]u8 = undefined;
    const p = Network.LoadPacket(mem, &receivebuffer) catch |err| {
        std.log.warn("voxelgame loadpacket error: {any}\n", .{err});
        return;
    };
    switch (p.pktType) {
        Requests.PacketType.Ping => {
            const ping = Requests.Ping.load(p.data);
            var buf: [Requests.Pong.max_buffer_size]u8 = undefined;
            const req = Requests.Pong.make(.{ .server_name_len = 11, .server_name = "test server", .MOTD_len = 17, .MOTD = "message123456789" }, &buf);
            Network.SendPacket(.Pong, req, op, Requests.Pong.max_buffer_size, server, sender.*) catch |err| {
                std.log.err("error sending pong: {any}\n", .{err});
                return;
            };
            std.debug.print("Ping reiceved: {any}\n", .{ping});
        },

        else => std.debug.print("invalid packettype reiceived\n", .{}),
    }
}
