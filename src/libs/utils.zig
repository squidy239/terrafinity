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

///items in the vector are updated individually, not as a whole
pub fn AtomicVector(len: comptime_int, comptime T: type) type {
    return struct {
        vector: @Vector(len, T),

        pub fn load(self: *const @This(), comptime ordering: std.builtin.AtomicOrder) @Vector(len, T) {
            var vec: @Vector(len, T) = undefined;
            inline for (0..len) |i| {
                vec[i] = @atomicLoad(T, &self.vector[i], ordering);
            }
            return vec;
        }

        pub fn store(self: *@This(), new: @Vector(len, T), comptime ordering: std.builtin.AtomicOrder) void {
            inline for (0..len) |i| {
                @atomicStore(T, &self.vector[i], new[i], ordering);
            }
        }

        pub fn fetchAdd(self: *@This(), offset: @Vector(len, T), comptime ordering: std.builtin.AtomicOrder) @Vector(len, T) {
            var vec: @Vector(len, T) = undefined;
            inline for (0..len) |i| {
                vec[i] = @atomicRmw(T, &self.vector[i], .Add, offset[i], ordering);
            }
            return vec;
        }

        pub fn rmw(self: *@This(), offset: @Vector(len, T), operator: std.builtin.AtomicRmwOp, comptime ordering: std.builtin.AtomicOrder) @Vector(len, T) {
            var vec: @Vector(len, T) = undefined;
            inline for (0..len) |i| {
                vec[i] = @atomicRmw(T, &self.vector[i], operator, offset[i], ordering);
            }
            return vec;
        }
    };
}
