const std = @import("std");
const Chunk = @import("./chunk.zig").Chunk;
const Blocks = @import("./Materials.zig").Materials;
const GenChunk = @import("./GenerateChunk.zig");
const Materials = @import("./Materials.zig").Materials;

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

pub fn GetFace(chunk: *Chunk, side: u3) *[32][32]u32 {
    switch (side) {
        0 => return &chunk.blocks[0],
        1 => return &chunk.blocks[31],
        2 => return &chunk.blocks[0..31][0],
        3 => return &chunk.blocks[0..31][0],
        4 => return &chunk.blocks[0..31][0..31][0],
        5 => return &chunk.blocks[0..31][0..31][30],
        else => return &chunk.blocks[0],
    }
}

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

pub fn FaceMesh(chunk: *Chunk, allocator: std.mem.Allocator) !std.ArrayList(f32) {
    var verts = std.ArrayList(f32).init(allocator);
    errdefer verts.deinit();
    const blocks = chunk.blocks;
    for (0..32) |x| {
        for (0..32) |y| {
            for (0..32) |z| {
                if (blocks[x][y][z] != @intFromEnum(Materials.Air)) {
                    if (x != 31) {
                        if (blocks[x + 1][y][z] == @intFromEnum(Materials.Air)) {
                            _ = try verts.appendSlice(translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z), 3)[0..30]);
                        }
                    } //else {if(sides[0][x+1][y][z] == @intFromEnum(Materials.Air)){
                    //   _ = try verts.appendSlice(translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z),3)[0..30]);

                    // }}

                    if (x != 0 and blocks[x - 1][y][z] == @intFromEnum(Materials.Air)) {
                        _ = try verts.appendSlice(translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z), 2)[0..30]);
                    }
                    if (y != 31 and blocks[x][y + 1][z] == @intFromEnum(Materials.Air)) {
                        _ = try verts.appendSlice(translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z), 5)[0..30]);
                    }
                    if (y != 0 and blocks[x][y - 1][z] == @intFromEnum(Materials.Air)) {
                        _ = try verts.appendSlice(translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z), 4)[0..30]);
                    }
                    if (z != 31 and blocks[x][y][z + 1] == @intFromEnum(Materials.Air)) {
                        _ = try verts.appendSlice(translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z), 1)[0..30]);
                    }
                    if (z != 0 and blocks[x][y][z - 1] == @intFromEnum(Materials.Air)) {
                        _ = try verts.appendSlice(translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z), 0)[0..30]);
                    }
                }
            }
        }
    }
    return verts;
}
