const std = @import("std");
const builtin = @import("builtin");

pub const Block = enum(u16) {
    null = 0,
    air = 1,
    stone = 2,
    grass = 3,
    dirt = 4,
    wood = 5,
    leaves = 6,
    water = 7, //id is 7 hardcoded for waves, TODO make this a property
    snow = 8,

    pub inline fn isTransparent(self: Block) bool {
        return switch (self) {
            .null => if (comptime builtin.is_test) true else unreachable,
            .air, .water, .leaves => true,
            else => false,
        };
    }

    pub inline fn isSolid(self: Block) bool {
        return switch (self) {
            .null => if (comptime builtin.is_test) false else unreachable,
            .air,
            .water,
            => false,
            else => true,
        };
    }

    pub inline fn isVisible(self: Block) bool {
        return switch (self) {
            .null => if (comptime builtin.is_test) false else unreachable,
            .air,
            => false,
            else => true,
        };
    }

    pub inline fn getPropagationWeight(self: Block) f32 {
        return switch (self) {
            .null => if (comptime builtin.is_test) 1 else unreachable,
            .grass => 1.1,
            .air => 0.7,
            else => 1,
        };
    }

    pub inline fn plantsCanGrow(self: Block) bool {
        return switch (self) {
            .null => if (comptime builtin.is_test) false else unreachable,
            .grass, .dirt => true,
            else => false,
        };
    }
};

test "Block properties" {
    const testing = std.testing;
    try testing.expect(Block.air.isTransparent());
    try testing.expect(!Block.stone.isTransparent());
    try testing.expect(Block.stone.isSolid());
    try testing.expect(!Block.air.isSolid());
    try testing.expect(Block.grass.isVisible());
    try testing.expect(!Block.air.isVisible());
}
