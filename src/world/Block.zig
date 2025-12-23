const std = @import("std");

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
            .air, .water, .leaves, .null => true,
            else => false,
        };
    }

    pub inline fn isSolid(self: Block) bool {
        return switch (self) {
            .air, .water, .null => false,
            else => true,
        };
    }

    pub inline fn isVisible(self: Block) bool {
        return switch (self) {
            .air, .null => false,
            else => true,
        };
    }

    pub inline fn getPropagationWeight(self: Block) f32 {
        return switch (self) {
            .grass => 1.1,
            .air => 0.1,
            else => 1,
        };
    }

    pub inline fn plantsCanGrow(self: Block) bool {
        return switch (self) {
            .grass, .dirt => true,
            else => false,
        };
    }
};
