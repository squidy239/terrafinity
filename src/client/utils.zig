const std = @import("std");

pub fn outOfSquareRange(Pos: @Vector(3, i32), range: @Vector(3, i32)) bool {
    return @reduce(.Or, @as(@Vector(3, i32), @intCast(@abs(Pos))) > range);
}

pub fn loadZON(comptime T: type, file: std.fs.File, temp_allocator: std.mem.Allocator, allocator: std.mem.Allocator) !T {
    var readBuf: [1024]u8 = undefined;
    const stat = try file.stat();

    var reader = file.reader(&readBuf);
    const slice = try reader.interface.readAlloc(temp_allocator, stat.size);
    defer temp_allocator.free(slice);
    @setEvalBranchQuota(100000000);
    return try std.zon.parse.fromSlice(T, allocator, @ptrCast(slice), null, .{});
}
