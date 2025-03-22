const std = @import("std");
const zudp = @import("zudp").Connection;
const World = @import("World").World;
const Network = @import("Network");
const Requests = @import("Requests");
const Entitys = @import("Entitys");

const op = @import("Server.zig").op;

pub fn Handler(args: anytype, mem: []const u8, sender: *const std.posix.sockaddr) void {
    const server: *zudp = args.server;
    const world: *World = args.world;

    var receivebuffer: [524288]u8 = undefined;
    const p = Network.LoadPacket(mem, &receivebuffer) catch |err| {
        std.log.warn("voxelgame loadpacket error: {any}\n", .{err});
        return;
    };
    switch (p.pktType) {
        Requests.PacketType.Ping => HandlePing(p.data, server, sender, world),
        Requests.PacketType.Unverifyed_Login => Handle_Unverifyed_Login(p.data, server, sender, world),
        else => std.log.warn("invalid packettype reiceived\n", .{}),
    }
}

fn HandlePing(data: []const u8, server: *zudp, sender: *const std.posix.sockaddr, world: *World) void {
    _ = world;
    const ping = Requests.Ping.load(data) catch |err| {
        std.debug.print("err:{any}\n", .{err});
        return;
    };
    var buf: [Requests.Pong.max_buffer_size]u8 = undefined;
    const motd = "server message";
    const req = Requests.Pong.make(.{
        .version = .Testing,
        .server_name_len = 11,
        .server_name = "test server",
        .MOTD_len = motd.len,
        .MOTD = motd,
    }, &buf);
    Network.SendPacket(.Pong, req, op, Requests.Pong.max_buffer_size, server, sender.*) catch |err| {
        std.log.err("error sending pong: {any}\n", .{err});
        return;
    };
    std.log.debug("Ping reiceved from {any} by referer: {s}\n", .{ sender.data[2..6], ping.referrer });
}

fn Handle_Unverifyed_Login(data: []const u8, server: *zudp, sender: *const std.posix.sockaddr, world: *World) void {
    const login = Requests.Unverifyed_Login.load(data) catch |err| {
        std.debug.print("err:{any}\n", .{err});
        return;
    };
    if (!std.mem.eql(u8, login.username, "banned player")) {
        //login succeded
        std.debug.print("{s} logged in with UUID {x}\n", .{ login.username, login.UUID });
        world.AddPlayer(login.UUID, Entitys.Player{
            .GenDistance = [3]u32{ login.GenDistance[0], login.GenDistance[1], login.GenDistance[0] },
            .pos = @Vector(3, f64){ 0.0, 0.0, 0.0 },
            .Movement = @Vector(3, f64){ 0.0, 0.0, 0.0 },
            .ref_count = .init(1),
            .lock = .{},
            .OnGround = false,
            .gameMode = .Spectator,
            .ip = sender.*,
            .inWater = false,
            .pitch = 0,
            .eyepitch = 0,
            .eyeroll = 0,
            .eyeyaw = 0,
            .yaw = 0,
            .roll = 0,
            .speed = @Vector(3, f64){ 0.0, 0.0, 0.0 },
            .player_UUID = login.UUID,
            .player_name = login.username,
            .hitboxmin = @Vector(3, f64){ 0.3, 2.0, 0.3 },
            .hitboxmax = @Vector(3, f64){ 0.3, 0.3, 0.3 },
        }) catch |err| std.debug.print("error adding player: {any}", .{err});
    } else {
        //login failed
        std.debug.print("{s} failed to log in with UUID {x}\n", .{ login.username, login.UUID });
        const message = "login failed";
        var buf: [Requests.Login_Failed.max_buffer_size]u8 = undefined;
        const req = Requests.Login_Failed.make(.{ .message = message, .message_len = message.len }, &buf);
        Network.SendPacket(.Login_Failed, req, op, Requests.Login_Failed.max_buffer_size, server, sender.*) catch |err| {
            std.log.err("error sending logn failed: {any}\n", .{err});
            return;
        };
    }
}
