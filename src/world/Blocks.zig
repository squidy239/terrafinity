const std = @import("std");

//const zstbi = @import("zstbi");

pub const Blocks = enum(i20) {
    Air = -1,
    GrassyDirt = 1,
    Grass = -4,
    Leaves = -2,
    Wood = 5,
    Dirt = 2,
    Stone = 3,
    Water = -3,
    OakRoots = 7,
    Snow = 11,

    pub fn Transperent(self: @This()) bool {
        return switch (self) {
            .Air, .Water, .Leaves, .Grass => true,
            else => false,
        };
    }

    pub fn Visible(self: @This()) bool {
        return self != Blocks.Air;
    }
};
