const glfw = @import("glfw");
const gl = @import("gl");
const zm = @import("zm");
const std = @import("std");
const zstbi = @import("zstbi");
const glfw_log = std.log.scoped(.glfw);
const gl_log = std.log.scoped(.gl);
const vsync = false;
const Chunk = @import("./chunk/chunk.zig").Chunk;
const render = @import("./render.zig");
const Entity = @import("./entitys.zig");
const ChunkGen = @import("./chunk/GenerateChunk.zig");
const Mesher = @import("./chunk/MeshChunk.zig");
const ArrayList = std.ArrayList;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var width: f32 = 800;
var height: f32 = 600;
var lastX: f64 = 0;
var lastY: f64 = 0;
var procs: gl.ProcTable = undefined;
var fullscreen: bool = false;
var player = Entity.Player{
    .cameraFront = @Vector(3, f32){ 0.0, 0.0, -1.0 },
    .pos = @Vector(3, f32){ 0.0, 0.0, 3.0 },
    .cameraUp = @Vector(3, f32){ 0.0, 1.0, 0.0 },
    .speed = @Vector(3, f32){ 500.0, 500.0, 500.0 },
    .pitch = 0.0,
    .yaw = 0.0,
    .roll = 0.0,
    .gamemode = Entity.Player.GameModes.Spectator,
};

pub fn main() !void {}
