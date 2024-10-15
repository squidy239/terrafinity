const Blocks = @import("Materials.zig").Materials;
const Noise = @import("fastnoise.zig");
const Chunk = @import("./chunk.zig").Chunk;
const std = @import("std");

pub fn initctoblock(block: Blocks, pos: [3]i32) Chunk {
    return Chunk{
        .blocks = [_][32][32]u32{[_][32]u32{[_]u32{@intFromEnum(block)} ** 32} ** 32} ** 32,
        .pos = pos,
        .vertices = null,
    };
}

fn IntToF32(i: anytype) f32 {
    return @as(f32, @floatFromInt(i));
}

pub fn GenChunk(seed: i32, Pos: [3]i32) Chunk {
    var chunk = initctoblock(Blocks.Air, Pos);
    const TerrainNoise = Noise.Noise(f32){
        .seed = seed,
        .noise_type = .simplex,
        .frequency = 0.02,
        .fractal_type = .progressive,
    };
    //if (@abs(@divFloor(TerrainNoise.genNoise2DRange(IntToF32(Pos[0]), IntToF32(Pos[1]),i32,-256,256),@as(i32,32))-(Pos[2]*32)) > 100){
    //    return null;
    //}

    for (0..32) |x| {
        for (0..32) |z| {
            const h = TerrainNoise.genNoise2DRange((IntToF32(x) / 32) + (IntToF32(Pos[0])), (IntToF32(z) / 32) + (IntToF32(Pos[2])), i32, -256, 256);
            //std.debug.print("{}", .{h});
            if (@divFloor(h, @as(i32, 32)) == Pos[1]) {
                chunk.blocks[x][@abs(@mod(h, 32))][z] = @intFromEnum(Blocks.Grass);
                for (0..@abs(@mod(h, 32))) |hi| {
                    chunk.blocks[x][hi][z] = @intFromEnum(Blocks.Stone);
                }
            }
        }
    }
    return chunk;
}
