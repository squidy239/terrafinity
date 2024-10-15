const std = @import("std");

pub const Player = struct {
    pos: @Vector(3, f32),
    cameraFront: @Vector(3, f32),
    cameraUp: @Vector(3, f32),
    speed: @Vector(3, f32),
    pitch: f64,
    yaw: f64,
    roll: f64,
    gamemode: GameModes,
    pub const GameModes = enum(u32) {
        Spectator = 3,
    };
};
