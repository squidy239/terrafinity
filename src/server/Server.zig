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

pub const Server = struct {
    allocator: std.mem.Allocator,
    world: World,
    zudpServer: zudp,
    PlayersByAddr: ConcurrentHashMap(std.posix.sockaddr, *Entitys.Player, std.hash_map.AutoContext(std.posix.sockaddr), 80, 32), //TODO change to ket:addr, val:connection state including uuid
    playerData: std.AutoArrayHashMap(u128, PlayerData),
    NetworkOptions: Network.Options,
    maxGenDistance: [3]u32,
    ServerDescription: []const u8,
    ServerName: []const u8,
    ReferrerRules: []const ReferrerRule,
    AllowedDeniedPlayerList: std.AutoHashMap(u128, bool), //true to allow, false to deny

    pub const PlayerData = struct {
        EntityId: u128,
        ip: ?std.posix.sockaddr,
        entityDistanceChunks: [3]u32,
        loginState: enum {
            Reqested, //login was reqested by client
            ServerDataSent,
            Connected,
        },
    };
};
const ReferrerRule = struct {
    AllowDeny: bool, //true to allow trafic, false to deny
    Referrer: []const u8,
};
const listenparams = struct {
    world: *World,
    server: *zudp,
};
