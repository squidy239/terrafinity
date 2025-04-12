const std = @import("std");

pub const BlockEncoding = union(enum) {
    blocks: *[32][32][32]i32,
    oneBlock: i32,
};

pub fn main() !void {
    std.debug.print("{any}\n", .{@sizeOf(BlockEncoding)});
}
