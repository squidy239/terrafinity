const std = @import("std");

const zstbi = @import("zstbi");

pub const Blocks = enum(u20) {
    Air = 0,
    Grass = 1,
    Leaves = 4,
    Wood = 5,
    Dirt = 2,
    Stone = 3,
    Water = 6,
};

pub const Textures = struct {
    pub fn LoadAtlas(file: [:0]const u8, allocator: std.mem.Allocator) !zstbi.Image {
        zstbi.init(allocator);
        //defer zstbi.deinit();
        zstbi.setFlipVerticallyOnLoad(true);
        return zstbi.Image.loadFromFile(file, 0);
    }
};
