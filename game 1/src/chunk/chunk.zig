const std = @import("std");

pub const Chunk = struct {
    blocks: [32][32][32]u32,
    pos: [3]i32,
    vbo: ?c_uint,
    vao: ?c_uint,
    vlen: ?c_uint,
    pub const ChunkContext = struct {
        pub fn hash(_: ChunkContext, c: @Vector(3, i32)) u64 {
            const x: u64 = @bitReverse(@as(u64, @bitCast(@as(i64, @intCast(c[0])))) *% 1239);
            const y: u64 = @bitReverse(@as(u64, @bitCast(@as(i64, @intCast(c[1])))) *% 44291);
            const z: u64 = @bitReverse(@as(u64, @bitCast(@as(i64, @intCast(c[2])))) *% 937);

            return x +% y +% z;
        }
        pub fn eql(_: ChunkContext, a: @Vector(3, i32), b: @Vector(3, i32)) bool {
            return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
        }
    };
};
