const std = @import("std");

//const zstbi = @import("zstbi");

pub const Blocks = enum(u20) {
    Air = 0,
    TallGrass = 1,
    Grass = 4,
    Water = 6,
    Wood = 5,
    Dirt = 2,
    Stone = 3,
    Leaves = 8,
    OakRoots = 7,
    Snow = 11,
    ERROR = 888,

    pub inline fn Transperent(self: @This()) bool {
        return self == .Air or self == .Water or self == .Leaves or self == .TallGrass;
    }

    pub inline fn Visible(self: @This()) bool {
        return self != Blocks.Air;
    }
};
