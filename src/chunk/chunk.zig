pub const Chunk = struct {
    blocks: [32][32][32]u32,
    pos:@Vector(3, i32),
};

pub const ChunkDiff = struct {
    
};