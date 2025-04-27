const std = @import("std");

//const zstbi = @import("zstbi");
threadlocal var returnVec: @Vector(6, bool) = undefined;
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

    pub inline fn Transperent6array(selfArray: [6]@This()) @Vector(6, bool) {
        @setRuntimeSafety(false);
        inline for (selfArray, 0..) |item, i| {
            returnVec[i] = item.Transperent();
        }

        return returnVec;
    }

    pub inline fn Visible(self: @This()) bool {
        return self != Blocks.Air;
    }
};
