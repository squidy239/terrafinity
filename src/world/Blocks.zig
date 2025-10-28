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

    pub inline fn TransperentVec(comptime len: usize, blocks: @Vector(len, @typeInfo(@This()).@"enum".tag_type)) @Vector(len, bool) {
        const transperentBlocks = comptime [_]Blocks{ .Air, .Water, .Leaves };
        comptime var transperentBlocksVec: [transperentBlocks.len]@Vector(len, @typeInfo(@This()).@"enum".tag_type) = undefined;
        comptime for (transperentBlocks, &transperentBlocksVec) |b, *v| {
            v.* = @splat(@intFromEnum(b));
        };
        var isTransparent: @Vector(len, bool) = @splat(false);
        inline for (transperentBlocksVec) |b| isTransparent |= (blocks == b);
        return isTransparent;
    }

    pub inline fn Visible(self: @This()) bool {
        return self != Blocks.Air;
    }
};
