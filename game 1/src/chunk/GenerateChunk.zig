const Blocks = @import("Materials.zig").Materials;
const Noise = @import("fastnoise.zig");
const Chunk = @import("./chunk.zig").Chunk;
const std = @import("std");

pub fn initctoblock(block: Blocks, pos: [3]i32) Chunk {
    return Chunk{
        .blocks = [_][32][32]u32{[_][32]u32{[_]u32{@intFromEnum(block)} ** 32} ** 32} ** 32,
        .pos = pos,
        .vbo = null,
        .vao = null,
        .vlen = null,
    };
}

fn IntToF32(i: anytype) f32 {
    return @as(f32, @floatFromInt(i));
}

pub fn GenChunk(seed: i32, Pos: [3]i32) Chunk {
    var chunk = initctoblock(Blocks.Air, Pos);
    const TerrainNoise = Noise.Noise(f32){
        .seed = seed,
        .noise_type = .cellular,
        .frequency = 0.08,
        .fractal_type = .progressive,
    };
    //if (@abs(@divFloor(TerrainNoise.genNoise2DRange(IntToF32(Pos[0]), IntToF32(Pos[1]),i32,-256,256),@as(i32,32))-(Pos[2]*32)) > 100){
    //    return null;
    //}

    for (0..32) |x| {
        for (0..32) |z| {
            const h = TerrainNoise.genNoise2DRange((IntToF32(x) / 32) + (IntToF32(Pos[0])), (IntToF32(z) / 32) + (IntToF32(Pos[2])), i32, -128, 128);
            //std.debug.print("{}", .{h});
            const d = @divFloor(h, @as(i32, 32));
            if (d == Pos[1]) {
                const y: usize = @intCast(@mod(h, 32));
                chunk.blocks[x][y][z] = @intFromEnum(Blocks.Grass);
                for (0..y) |yy| {
                    chunk.blocks[x][yy][z] = @intFromEnum(Blocks.Stone);
                }
            } else if (d > Pos[1]) {
                for (0..32) |yy| {
                    chunk.blocks[x][yy][z] = @intFromEnum(Blocks.Stone);
                }
            }
            //else {std.debug.print("{} ", .{@divFloor(h, @as(i32, 32))});}

        }
    }
    return chunk;
}
