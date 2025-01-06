const std = @import("std");
pub var EntityId: u32 = 0;

pub const EntityTypeCodes = enum(u20) {
    Player = 0,
};

pub const EntityUUID = struct {
    EntityType: EntityTypeCodes,
    UUID: u32,
};

pub const Player = struct {
    pos: @Vector(3, f64),
    pitch: f32,
    yaw: f32,
    roll: f32,
    Movement: @Vector(3, f64),
    speed: @Vector(3, f32),
    cameraUp: @Vector(3, f64),
    cameraFront: @Vector(3, f64),
    GenDistance: [3]u32,
    LoadDistance: [3]u32,
    MeshDistance: [3]u32,
    lock: std.Thread.RwLock,
};
