const std = @import("std");
const zudp = @import("zudp").Connection;
const Network = @import("Network");
const Requests = @import("Requests");
const op = @import("testClient.zig").op;

pub fn Handler(args: anytype, mem: []const u8, sender: *const std.posix.sockaddr) void {
    HandlePacket(args, mem, sender) catch |err| std.debug.panic("handler err: {any}\n", .{err});
}
fn HandlePacket(args: anytype, mem: []const u8, sender: *const std.posix.sockaddr) !void {
    const server: *zudp = args.server;
    const p = try Network.LoadPacket(mem);
    switch (p.pktType) {
        Requests.PacketType.ClientboundPong => {
            const pong = try Requests.Pong.load(p.data);
            std.debug.print("Pong reiceved:\nversion:{any}, \nserver name: {s},\nMOTD:{s}\n\n", .{ pong.version, pong.server_name, pong.MOTD });
        },
        Requests.PacketType.ClientboundDisconnect => {
            const login_failed = try Requests.Disconnect.load(p.data);
            std.debug.print("login failed, server message: {s}\n", .{login_failed.message});
        },
        Requests.PacketType.ClientboundLoginData => {
            const login_data = try Requests.LoginData.load(p.data);
            std.debug.print("logging in at pos {d}\n", .{login_data.pos});
            const login_complete = Requests.LoginComplete{ .ipVerifyNumber = login_data.ipVerifyNumber };
            try Network.SendPacket(.ServerboundLoginComplete, std.mem.asBytes(&login_complete), op, true, server, sender.*);
        },
        else => std.debug.print("invalid packettype reiceived:{any}\n", .{p}),
    }
}
