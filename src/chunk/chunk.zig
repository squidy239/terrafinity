const std = @import("std");

pub const Chunk = struct {
    blocks: [32][32][32]u32,
    pos: [3]i32,
    vertices: ?[]f32,
};

pub const ChunkDiff = struct {};
