const std = @import("std");

pub const Block = enum(u16) {
    Null,
    Air,
    Stone,
    Grass,
    Dirt,
    Wood,
    Leaves,
    Water, //id is 7 hardcoded for waves, TODO make this a property
    Snow,

    pub inline fn isTransparent(self: Block) bool {
        return switch (self) {
            .Air, .Water, .Leaves, .Null => true,
            else => false,
        };
    }

    pub inline fn isSolid(self: Block) bool {
        return switch (self) {
            .Air, .Water, .Null => false,
            else => true,
        };
    }

    pub inline fn isVisible(self: Block) bool {
        return switch (self) {
            .Air, .Null => false,
            else => true,
        };
    }

    pub inline fn getPropagationWeight(self: Block) f32 {
        return switch (self) {
            .Grass => 1.1,
            .Air => 0.1,
            else => 1,
        };
    }

    pub inline fn plantsCanGrow(self: Block) bool {
        return switch (self) {
            .Grass, .Dirt => true,
            else => false,
        };
    }
};
