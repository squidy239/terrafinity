const std = @import("std");

pub fn outOfSquareRange(Pos: @Vector(3, i32), range: @Vector(3, i32)) bool {
    return @reduce(.Or, @as(@Vector(3, i32), @intCast(@abs(Pos))) > range);
}

pub fn loadZON(comptime T: type, file: std.fs.File, temp_allocator: std.mem.Allocator, allocator: std.mem.Allocator) !T {
    var buf: [1024]u8 = undefined;
    const stat = try file.stat();
    var reader = file.reader(&buf);
    const slice = try temp_allocator.alloc(u8, stat.size + 1);
    defer temp_allocator.free(slice);
    try reader.interface.readSliceAll(slice[0..stat.size]);
    slice[stat.size] = 0;
    @setEvalBranchQuota(100000000);
    const result = try std.zon.parse.fromSlice(T, allocator, slice[0..stat.size :0], null, .{});
    return result;
}
