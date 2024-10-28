const std = @import("std");
const Chunk = @import("./Chunk.zig").Chunk;
const Block = @import("./Blocks.zig").Blocks;

pub fn InitChunkToBlock(block: Block, pos: [3]i32) Chunk {
    return Chunk{
        .pos = pos,
        .blockdata = null,
        .blocks = [_][32][32]Block{[_][32]Block{[_]Block{block} ** 32} ** 32} ** 32,
    };
}
