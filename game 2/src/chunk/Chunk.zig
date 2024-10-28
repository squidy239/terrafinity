const Blocks = @import("Blocks.zig").Blocks;
const std = @import("std");
pub const chunksize = 32;

//3 render distances, one chunks will be loaded in, one the meshes will still be loaded, and one chunks will generate in
// if generation radis is bigger than loading radies than chunks will be compressed and written to the disk but the meshes will stay
// might have more render distances for entities
pub const Chunk = struct {
    pos: [3]i32,
    vbo: ?c_uint,
    vao: ?c_uint,
    vlen: ?c_uint,
    blocks: [chunksize][chunksize][chunksize]Blocks,
    blockdata: ?*std.AutoHashMap([3]u5, []u32),
    neighbors: [6]?*Chunk,
};

pub fn main() void {
    std.debug.print("{}", .{@sizeOf(Chunk)});
}
