const std = @import("std");
const zudp = @import("zudp").Connection;
const World = @import("World").World;
const Network = @import("Network");
const Requests = @import("Requests");
const Entitys = @import("Entitys");
const op = @import("Server.zig").op;

pub fn Handler(args: anytype, mem: []const u8, sender: *const std.posix.sockaddr) void {
    handleMessage(args, mem, sender) catch |err| std.log.err("server handler error: {any}\n", .{err});
}

pub fn handleMessage(args: anytype, mem: []const u8, sender: *const std.posix.sockaddr) !void {
    const server: *zudp = args.server;
    const world: *World = args.world;
    const p = try Network.LoadPacket(mem);
    switch (p.pktType) {
        Requests.PacketType.ServerboundPing => try HandlePing(p.data, server, sender, world),
        Requests.PacketType.ServerboundLoginStart => try HandleLoginStart(p.data, server, sender, world),
        Requests.PacketType.ServerboundLoginComplete => try HandleLoginComplete(p.data, server, sender, world),
        else => std.log.warn("invalid packettype reiceived: {any}\n", .{p.pktType}),
    }
}

fn HandlePing(data: []const u8, server: *zudp, sender: *const std.posix.sockaddr, world: *World) !void {
    _ = world;
    const ping = try Requests.Ping.load(data);
    var buf: [Requests.Pong.max_buffer_size]u8 = undefined;
    const motd = "server message";
    const req = Requests.Pong.make(.{
        .version = .Testing,
        .server_name_len = 11,
        .server_name = "test server",
        .MOTD_len = motd.len,
        .MOTD = motd,
    }, &buf);
    try Network.SendPacket(.ClientboundPong, req, op, true, server, sender.*);
    std.log.debug("Ping reiceved from {any} by referer: {s}\n", .{ sender.data[2..6], ping.referrer });
}

fn HandleLoginStart(data: []const u8, server: *zudp, sender: *const std.posix.sockaddr, world: *World) !void {
    const login = try Requests.LoginStart.load(data);
    const login_allowed = !std.mem.eql(u8, login.username, "banned player"); //and not already connected
    if (login_allowed) {
        //login succeded
        var reqBuffer: [Requests.LoginData.max_buffer_size]u8 = undefined;
        const req = Requests.LoginData{
            .ipVerifyNumber = std.crypto.random.int(u64),
            .pos = @Vector(3, f64){ 0, 100, 0 },
            .GameMode = .Spectator,
            .Velocity = @Vector(3, f64){ 0, 0, 0 },
            .genParams = world.GenParams,
            .maxGenDistance = [3]u32{ 20, 20, 20 },
        };
        try Network.SendPacket(.ClientboundLoginData, req.make(&reqBuffer), op, true, server, sender.*);
        std.debug.print("{s} started logging in with UUID {x}\n", .{ login.username, login.UUID });
    } else {
        //login failed
        std.debug.print("{s} failed to log in with UUID {x}\n", .{ login.username, login.UUID });
        const message = "login failed";
        var buf: [Requests.Disconnect.max_buffer_size]u8 = undefined;
        const req = Requests.Disconnect.make(.{ .message = message, .message_len = message.len }, &buf);
        try Network.SendPacket(.ClientboundDisconnect, req, op, true, server, sender.*);
    }
}

fn HandleLoginComplete(data: []const u8, server: *zudp, sender: *const std.posix.sockaddr, world: *World) !void {
    _ = world;
    _ = server;
    _ = sender;
    const loginComplete: Requests.LoginComplete = std.mem.bytesToValue(Requests.LoginComplete, data);
    std.debug.print("login complete rcved, random id: {d}\n", .{loginComplete.ipVerifyNumber});
}
