const std = @import("std");

//const zstbi = @import("zstbi");

pub const Blocks = enum(u20) {
    Air = 0,
    TallGrass = 1,
    Grass = 4,
    Leaves = 6,
    Wood = 5,
    Dirt = 2,
    Stone = 3,
    Water = 8,
    OakRoots = 7,
    Snow = 11,
    ERROR = 888,

    pub fn Transperent(self: @This()) bool {
        return switch (self) {
            .Air, .Water, .Leaves, .TallGrass => true,
            else => false,
        };
    }

    pub fn Visible(self: @This()) bool {
        return self != Blocks.Air;
    }
};
