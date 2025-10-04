const std = @import("std");

//const zstbi = @import("zstbi");
threadlocal var returnVec: @Vector(6, bool) = undefined;
pub const Blocks = enum(u20) {
    Null = 0,
    Air = 1,
    Grass = 2,
    Dirt = 3,
    Stone = 4,
    Wood = 5,
    Leaves = 6,
    Water = 7,
    Snow = 8,

    pub const invisibleBlocksAmount = 2; //All invisible blocks must come before visible blocks
    pub inline fn Transperent(self: @This()) bool {
        return self == .Air or self == .Water or self == .Leaves;
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
