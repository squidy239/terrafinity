const std = @import("std");

pub const Block = enum {
    Null,
    Air,
    Stone,
    Grass,
    Dirt,
    Wood,
    Leaves,
    Water, //id is 7 hardcoded for waves, TODO make this a property
    Snow,

    pub const Properties = struct {
        pub const transparent: std.EnumArray(Block, bool) = initTransparent();
        pub const visible: std.EnumArray(Block, bool) = initVisible();
        pub const solid: std.EnumArray(Block, bool) = initSolid();

        fn initTransparent() std.EnumArray(Block, bool) {
            var temptransperent = std.EnumArray(Block, bool).initUndefined();
            for (@typeInfo(Block).@"enum".fields) |blockInt| {
                const blockType: Block = @enumFromInt(blockInt.value);
                const istransparent = switch (blockType) {
                    .Air, .Water, .Leaves, .Null => true,
                    else => false,
                };
                temptransperent.set(blockType, istransparent);
            }
            return temptransperent;
        }

        fn initSolid() std.EnumArray(Block, bool) {
            var tempsolid = std.EnumArray(Block, bool).initUndefined();
            for (@typeInfo(Block).@"enum".fields) |blockInt| {
                const blockType: Block = @enumFromInt(blockInt.value);
                const issolid = switch (blockType) {
                    .Air, .Water, .Null => false,
                    else => true,
                };
                tempsolid.set(blockType, issolid);
            }
            return tempsolid;
        }

        fn initVisible() std.EnumArray(Block, bool) {
            var tempvisible = std.EnumArray(Block, bool).initUndefined();
            for (@typeInfo(Block).@"enum".fields) |blockInt| {
                const blockType: Block = @enumFromInt(blockInt.value);
                const isVisible = switch (blockType) {
                    .Air, .Null => false,
                    else => true,
                };
                tempvisible.set(blockType, isVisible);
            }
            return tempvisible;
        }
    };
};
