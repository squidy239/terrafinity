const Blocks = @import("./blocks.zig").Blocks;
const Chunk = @import("./chunk.zig").Chunk;
pub fn initctoblock(block:Blocks,pos:@Vector(3, i32)) !Chunk{
        //const allocator = GeneralPurposeAllocator.allocator();
        return Chunk{
        .blocks=[_][32][32]u32{ [_][32]u32{[_]u32{@intFromEnum(block)} ** 32} ** 32} ** 32,
        .pos = pos,
        };
    }

//pub fn GenChunk(){}