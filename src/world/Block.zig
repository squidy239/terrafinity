const std = @import("std");
const builtin = @import("builtin");

pub const Block = enum(u16) {
    stone = normal_start,
    grass = normal_start + 1,
    dirt = normal_start + 2,
    wood = normal_start + 3,
    snow = normal_start + 4,

    //transparent blocks, >50,000
    water = transparent_end - 1, //id is 7 hardcoded for waves, TODO make this a property
    leaves = transparent_end - 2,

    //invisible blocks, > 60,000
    air = invis_end - 1,
    null = invis_end - 2,
    const invis_end = 2 << 10;
    const transparent_end = 2 << 11;
    const normal_start = transparent_end;

    pub inline fn isTransparent(self: Block) bool {
        return @intFromEnum(self) < transparent_end;
    }

    pub inline fn isVisible(self: Block) bool {
        return @intFromEnum(self) >= invis_end;
    }

    pub inline fn isSolid(self: Block) bool {
        return switch (self) {
            .null => unreachable,
            .air,
            .water,
            => false,
            else => true,
        };
    }

    pub inline fn getPropagationWeight(self: Block) f32 {
        return switch (self) {
            .null => unreachable,
            .snow => 2.0,
            .grass => 2.0,
            .dirt => 0.3,
            else => 1,
        };
    }

    pub inline fn plantsCanGrow(self: Block) bool {
        return switch (self) {
            .null => unreachable,
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
