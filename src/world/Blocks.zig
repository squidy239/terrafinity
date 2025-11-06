const std = @import("std");

pub const Blocks = enum {
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
        pub const transperent: std.EnumArray(Blocks, bool) = initTransperent();
        pub const visible: std.EnumArray(Blocks, bool) = initVisible();

        fn initTransperent() std.EnumArray(Blocks, bool) {
            var temptransperent = std.EnumArray(Blocks, bool).initUndefined();
            for (@typeInfo(Blocks).@"enum".fields) |blockInt| {
                const blockType: Blocks = @enumFromInt(blockInt.value);
                const istransparent = switch (blockType) {
                    .Air, .Water, .Leaves, .Null => true,
                    else => false,
                };
                temptransperent.set(blockType, istransparent);
            }
            return temptransperent;
        }

        fn initVisible() std.EnumArray(Blocks, bool) {
            var tempvisible = std.EnumArray(Blocks, bool).initUndefined();
            for (@typeInfo(Blocks).@"enum".fields) |blockInt| {
                const blockType: Blocks = @enumFromInt(blockInt.value);
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
