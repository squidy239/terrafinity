const std = @import("std");

pub const BlockEncoding = union {
    blocks: [32][32][32]i32,
    oneBlock: i32,
};

pub fn main() !void {
    const a = BlockEncoding{ .oneBlock = 22 };
    std.debug.print("{any}\n", .{std.mem.asBytes(&a).len});
}
