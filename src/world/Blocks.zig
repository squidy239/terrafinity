const std = @import("std");

//const zstbi = @import("zstbi");
threadlocal var returnVec: @Vector(6, bool) = undefined;
pub const Blocks = enum(u20) {
    Air = 0,
    Grass = 1,
    Dirt = 2,
    Stone = 3,
    Wood = 4,
    Leaves = 5,
    Water = 6,
    Snow = 7,

    pub const invisibleBlocksAmount = 1; //All invisible blocks must come before visible blocks
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
