const std = @import("std");

pub fn outOfSquareRange(chunk_pos: @Vector(3, i32), range: @Vector(3, i32)) bool {
    return @reduce(.Or, @as(@Vector(3, i32), @intCast(@abs(chunk_pos))) > range);
}

pub fn loadZON(comptime T: type, io: std.Io, file: std.Io.File, temp_allocator: std.mem.Allocator, allocator: std.mem.Allocator) !T {
    var buf: [1024]u8 = undefined;
    const stat = try file.stat(io);
    var reader = file.reader(io, &buf);
    const slice = try temp_allocator.alloc(u8, stat.size + 1);
    defer temp_allocator.free(slice);
    try reader.interface.readSliceAll(slice[0..stat.size]);
    slice[stat.size] = 0;
    @setEvalBranchQuota(100000000);
    const result = try std.zon.parse.fromSliceAlloc(T, allocator, slice[0..stat.size :0], null, .{});
    return result;
}
