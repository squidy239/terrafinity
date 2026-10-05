const std = @import("std");

pub const Block = enum(Tag) {
    pub const Tag = u16;
    stone = normal_start,
    grass = normal_start + 1,
    dirt = normal_start + 2,
    wood = normal_start + 3,
    snow = normal_start + 4,
    leaves = normal_start + 5,
    sand = normal_start + 6,

    water = transparent_end - 1, // Wave shader hardcodes this position. TODO: expose it as a property.

    air = invis_end - 1,
    null = invis_end - 2,
    fine_grass = invis_end - 3,
    pub const invis_end = 2 << 10;
    pub const transparent_end = 2 << 11;
    pub const normal_start = transparent_end;

    pub fn isTransparent(self: Block) bool {
        return @intFromEnum(self) < transparent_end;
    }

    pub inline fn isVisible(self: Block) bool {
        return @intFromEnum(self) >= invis_end;
    }

    pub inline fn isTransparentVector(comptime len: usize, vector: @Vector(len, @typeInfo(Block).@"enum".tag_type)) @Vector(len, bool) {
        return vector < comptime @as(@Vector(len, @typeInfo(Block).@"enum".tag_type), @splat(transparent_end));
    }

    pub inline fn isVisibleVector(comptime len: usize, vector: @Vector(len, @typeInfo(Block).@"enum".tag_type)) @Vector(len, bool) {
        return vector >= comptime @as(@Vector(len, @typeInfo(Block).@"enum".tag_type), @splat(invis_end));
    }

    pub const FluidProperties = struct {
        /// Upward acceleration as a fraction of gravity when fully submerged; 1 floats.
        buoyancy: f64,
        /// Drag relative to water, which is 1.
        resistance: f64,
    };

    /// Fluid behaviour for blocks a body moves through without colliding, or null
    /// for everything else. Water floats and drags; leaves do not float and drag hard.
    pub inline fn fluidProperties(self: Block) ?FluidProperties {
        return switch (self) {
            .water => .{ .buoyancy = 1.0, .resistance = 1.0 },
            .leaves => .{ .buoyancy = 0.0, .resistance = 4.0 },
            else => null,
        };
    }

    pub inline fn isFluid(self: Block) bool {
        return self.fluidProperties() != null;
    }

    /// Visible blocks a body cannot enter. Fluids are moved through, not collided with.
    pub inline fn isSolid(self: Block) bool {
        if (self == .null) unreachable;
        return self.isVisible() and !self.isFluid();
    }

    pub inline fn plantsCanGrow(self: Block) bool {
        return switch (self) {
            .null => unreachable,
            .grass, .dirt => true,
            else => false,
        };
    }

    pub const visible_count: usize = blk: {
        var count: usize = 0;
        for (std.meta.fields(@This())) |field| {
            if (@field(@This(), field.name).isVisible()) count += 1;
        }
        break :blk count;
    };
};

test "Block properties" {
    const testing = std.testing;
    try testing.expect(Block.air.isTransparent());
    try testing.expect(!Block.stone.isTransparent());
    try testing.expect(Block.stone.isSolid());
    try testing.expect(!Block.air.isSolid());
    try testing.expect(Block.grass.isVisible());
    try testing.expect(!Block.air.isVisible());
    try testing.expect(!Block.fine_grass.isVisible());
    try testing.expect(!Block.fine_grass.isSolid());
}

test "Fluid blocks carry movement properties" {
    const testing = std.testing;
    const water = Block.water.fluidProperties().?;
    try testing.expect(Block.water.isFluid());
    try testing.expect(!Block.water.isSolid());
    try testing.expect(water.buoyancy > 0);

    // Leaves are a fluid the body does not collide with; they do not float it and
    // resist far more than water, so a canopy only slows the fall.
    const leaves = Block.leaves.fluidProperties().?;
    try testing.expect(Block.leaves.isVisible());
    try testing.expect(Block.leaves.isFluid());
    try testing.expect(!Block.leaves.isSolid());
    try testing.expectEqual(@as(f64, 0), leaves.buoyancy);
    try testing.expect(leaves.resistance > water.resistance);

    try testing.expect(Block.stone.isSolid());
    try testing.expect(Block.stone.fluidProperties() == null);
}

test "water dense index matches shader" {
    const testing = std.testing;
    // The wave shader hardcodes the water dense index. This test fails if the tag value shifts.
    try testing.expectEqual(3, std.enums.EnumIndexer(Block).indexOf(.water));
}
