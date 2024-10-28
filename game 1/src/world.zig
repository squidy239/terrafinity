const std = @import("std");
const Entitys = @import("./entitys.zig");
const Chunk = @import("./chunk/chunk.zig").Chunk;
pub const h = "hello3";
pub const vertices = [_][30]f32{
    [_]f32{
        -0.5, -0.5, -0.5, 0.0, 0.0,
        0.5,  -0.5, -0.5, 1.0, 0.0,
        0.5,  0.5,  -0.5, 1.0, 1.0,
        0.5,  0.5,  -0.5, 1.0, 1.0,
        -0.5, 0.5,  -0.5, 0.0, 1.0,
        -0.5, -0.5, -0.5, 0.0, 0.0,
    },
    [_]f32{
        -0.5, -0.5, 0.5, 0.0, 0.0,
        0.5,  -0.5, 0.5, 1.0, 0.0,
        0.5,  0.5,  0.5, 1.0, 1.0,
        0.5,  0.5,  0.5, 1.0, 1.0,
        -0.5, 0.5,  0.5, 0.0, 1.0,
        -0.5, -0.5, 0.5, 0.0, 0.0,
    },
    [_]f32{
        -0.5, 0.5,  0.5,  1.0, 0.0,
        -0.5, 0.5,  -0.5, 1.0, 1.0,
        -0.5, -0.5, -0.5, 0.0, 1.0,
        -0.5, -0.5, -0.5, 0.0, 1.0,
        -0.5, -0.5, 0.5,  0.0, 0.0,
        -0.5, 0.5,  0.5,  1.0, 0.0,
    },
    [_]f32{
        0.5, 0.5,  0.5,  1.0, 0.0,
        0.5, 0.5,  -0.5, 1.0, 1.0,
        0.5, -0.5, -0.5, 0.0, 1.0,
        0.5, -0.5, -0.5, 0.0, 1.0,
        0.5, -0.5, 0.5,  0.0, 0.0,
        0.5, 0.5,  0.5,  1.0, 0.0,
    },
    [_]f32{
        -0.5, -0.5, -0.5, 0.0, 1.0,
        0.5,  -0.5, -0.5, 1.0, 1.0,
        0.5,  -0.5, 0.5,  1.0, 0.0,
        0.5,  -0.5, 0.5,  1.0, 0.0,
        -0.5, -0.5, 0.5,  0.0, 0.0,
        -0.5, -0.5, -0.5, 0.0, 1.0,
    },
    [_]f32{
        -0.5, 0.5, -0.5, 0.0, 1.0,
        0.5,  0.5, -0.5, 1.0, 1.0,
        0.5,  0.5, 0.5,  1.0, 0.0,
        0.5,  0.5, 0.5,  1.0, 0.0,
        -0.5, 0.5, 0.5,  0.0, 0.0,
        -0.5, 0.5, -0.5, 0.0, 1.0,
    },
};

var GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator(.{}){};

pub fn translatedface(x: f32, y: f32, z: f32, face: u8) [30]f32 {
    var v: [30]f32 = vertices[face];
    for (0..30) |i| {
        if (i % 5 == 0) {
            v[i] += x;
        } else if (i % 5 == 1) {
            v[i] += y;
        } else if (i % 5 == 2) {
            v[i] += z;
        }
    }
    return v;
}

pub fn CalculateVertices(chunk: *Chunk, allocator: std.mem.Allocator) !std.ArrayList(f32) {
    var verts = std.ArrayList(f32).init(allocator);
    errdefer verts.deinit();
    const blocks = chunk.blocks;
    for (0..32) |x| {
        for (0..32) |y| {
            for (0..32) |z| {
                if (blocks[x][y][z] != @intFromEnum(Materials.Air)) {
                    if (x != 31 and blocks[x + 1][y][z] == @intFromEnum(Materials.Air) or x == 31) {
                        _ = try verts.appendSlice(translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z), 3)[0..30]);
                    }
                    if (x != 0 and blocks[x - 1][y][z] == @intFromEnum(Materials.Air) or x == 0) {
                        _ = try verts.appendSlice(translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z), 2)[0..30]);
                    }
                    if (y != 31 and blocks[x][y + 1][z] == @intFromEnum(Materials.Air) or y == 31) {
                        _ = try verts.appendSlice(translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z), 5)[0..30]);
                    }
                    if (y != 0 and blocks[x][y - 1][z] == @intFromEnum(Materials.Air) or y == 0) {
                        _ = try verts.appendSlice(translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z), 4)[0..30]);
                    }
                    if (z != 31 and blocks[x][y][z + 1] == @intFromEnum(Materials.Air) or z == 31) {
                        _ = try verts.appendSlice(translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z), 1)[0..30]);
                    }
                    if (z != 0 and blocks[x][y][z - 1] == @intFromEnum(Materials.Air) or z == 0) {
                        _ = try verts.appendSlice(translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z), 0)[0..30]);
                    }
                }
            }
        }
    }
    return verts;
}

pub const World = struct {
    Chunks: std.HashMap([3]i32, *Chunk, Chunk.ChunkContext, 80),
};

pub const Materials = enum(u32) {
    Air = 0,
    Dirt = 1,
    Grass = 2,
    Stone = 3,
    TestBlock = 888,
};
