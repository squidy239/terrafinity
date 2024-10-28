const std = @import("std");
const Chunk = @import("../chunk/Chunk.zig").Chunk;
const ChunkSize = @import("../chunk/Chunk.zig").chunksize;
const Blocks = @import("../chunk/Blocks.zig").Blocks;
pub fn MeshChunk_Normal(chunk: *Chunk, allocator: std.mem.Allocator) ![]u64 {
    //bitpacking structure
    //pos|5 x 5 y 5 z| faces|1 1 1 1 1 1| blocktype|20| 23 leftover bits
    //64 bits total 41 used
    
    var mesh = std.ArrayList(u64).init(allocator);
    defer mesh.deinit();
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                if (chunk.blocks[x][y][z] != Blocks.Air) {
                    // i hate this code
                    // set to all 0s
                    var EncodedBlock: u64 = 0;
                    var r: bool = false;
                    //inserts bits that say which sides face air
                    if (x == 32) {} else if (chunk.blocks[x + 1][y][z] == Blocks.Air) {
                        EncodedBlock |= @as(u64, 0b1) << @bitSizeOf(u64) - 16;
                        r = true;
                    }

                    if (x == 0) {} else if (chunk.blocks[x - 1][y][z] == Blocks.Air) {
                        EncodedBlock |= @as(u64, 0b1) << @bitSizeOf(u64) - 17;
                        r = true;
                    }
                    if (y == 32) {} else if (chunk.blocks[x][y + 1][z] == Blocks.Air) {
                        EncodedBlock |= @as(u64, 0b1) << @bitSizeOf(u64) - 18;
                        r = true;
                    }
                    if (y == 0) {} else if (chunk.blocks[x][y - 1][z] == Blocks.Air) {
                        EncodedBlock |= @as(u64, 0b1) << @bitSizeOf(u64) - 19;
                        r = true;
                    }
                    if (z == 32) {} else if (chunk.blocks[x][y][z + 1] == Blocks.Air) {
                        EncodedBlock |= @as(u64, 0b1) << @bitSizeOf(u64) - 20;
                        r = true;
                    }
                    if (z == 0) {} else if (chunk.blocks[x][y][z - 1] == Blocks.Air) {
                        EncodedBlock |= @as(u64, 0b1) << @bitSizeOf(u64) - 21;
                        r = true;
                    }
                    if (!r) continue;
                    //block location bits
                    EncodedBlock |= @as(i64, @intCast(x)) - ChunkSize << @bitSizeOf(u64) - 5;
                    EncodedBlock |= @as(i64, @intCast(y)) - ChunkSize << @bitSizeOf(u64) - 10;
                    EncodedBlock |= @as(i64, @intCast(z)) - ChunkSize << @bitSizeOf(u64) - 15;
                    //block type bits
                    EncodedBlock |= @as(u64, @intCast(chunk.blocks[x][y][z])) << @bitSizeOf(u64) - 41;
                    mesh.append(EncodedBlock);
                }
            }
        }
    }
    return try mesh.toOwnedSlice();
}
