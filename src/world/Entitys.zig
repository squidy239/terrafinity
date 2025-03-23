const std = @import("std");
pub var EntityId: u32 = 0;

pub const EntityType = enum(u20) {
    Player,
};

pub const GameMode = enum(u8) {
    Survival = 0,
    Creative = 1,
    Spectator = 3,
};

pub const Player = struct {
    player_UUID: u128,
    player_name: []const u8,
    lock: std.Thread.RwLock,
    ref_count: std.atomic.Value(u32), //must count being in a hashmap as a refrence
    gameMode: GameMode,
    OnGround: bool,
    pos: @Vector(3, f64),
    pitch: f32,
    yaw: f32,
    inWater: bool,
    roll: f32,
    eyepitch: f32,
    eyeyaw: f32,
    eyeroll: f32,
    hitboxmin: @Vector(3, f64),
    hitboxmax: @Vector(3, f64),
    Movement: @Vector(3, f64),
    speed: @Vector(3, f32),
    GenDistance: [3]u32,
    ip: ?std.posix.sockaddr,
};
