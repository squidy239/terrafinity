const Blocks = @import("Blocks.zig").Blocks;
const std = @import("std");
pub const chunksize = 32;

pub const Chunk = struct {
    pos: [3]i32,
    blocks: [chunksize][chunksize][chunksize]Blocks,
    blockdata: ?*std.AutoHashMap([3]u5, []u32),
};
