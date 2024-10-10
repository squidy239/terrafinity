const std = @import("std");
const Chunk = @import("./chunk.zig").Chunk;
const Blocks = @import("./blocks.zig").Blocks;

pub fn MeshChunk_Onion(chunk:*Chunk, allocator:std.mem.Allocator)[]f32{
    var v = std.ArrayList(i8).init(allocator);
    defer v.deinit();
    
}


pub fn GetFace([][][]u32,depth:u4,side:u4)[]u32{
    var face:[8]u32 = undefined; 
    face = chunk.blocks[0..32]
}