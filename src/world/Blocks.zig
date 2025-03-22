const std = @import("std");

//const zstbi = @import("zstbi");

pub const Blocks = enum(u24) {
    Air = 0,
    Grass = 1,
    Leaves = 4,
    Wood = 5,
    Dirt = 2,
    Stone = 3,
    Water = 6,
    OakRoots = 7,
    OakLog = 8,
    OakLeaves = 9,
    OakRootCluster = 10,
    Snow = 11,
};
