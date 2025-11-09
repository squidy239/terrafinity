const std = @import("std");

pub fn outOfSquareRange(Pos: @Vector(3, i32), range: @Vector(3, i32)) bool {
    return @reduce(.Or, @as(@Vector(3, i32), @intCast(@abs(Pos))) > range);
}

pub fn loadZON(comptime T: type, file: std.fs.File, allocator: std.mem.Allocator) !struct { result: T, arena: std.heap.ArenaAllocator } {
    var arena = std.heap.ArenaAllocator.init(allocator);
    const arenAllocator = arena.allocator();
    var readBuf: [1024]u8 = undefined;
    const stat = try file.stat();

    var reader = file.reader(&readBuf);
    const slice = try reader.interface.readAlloc(allocator, stat.size);
    defer allocator.free(slice);
    @setEvalBranchQuota(100000000);
    return .{ .result = try std.zon.parse.fromSlice(T, arenAllocator, @ptrCast(slice), null, .{}), .arena = arena };
}