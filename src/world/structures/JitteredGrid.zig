const std = @import("std");

/// Tiles N-dimensional space into box_size cells; each cell deterministically
/// holds one structure at a jittered offset. getStructure returns the
/// structure of the cell containing `position` only for positions within
/// `2^level` units of it, so each structure is owned by one cell per level.
/// `T` is the integer coordinate type (signed or unsigned).
pub fn JitteredGrid(comptime N: usize, comptime T: type) type {
    if (N == 0) @compileError("JitteredGrid needs at least one dimension");
    if (@typeInfo(T) != .int) @compileError("JitteredGrid coordinate type must be an integer");

    return struct {
        const Self = @This();
        pub const Vector = @Vector(N, T);
        const U = @Int(.unsigned, @bitSizeOf(T));

        /// Grid cell size in world units at level 0.
        box_size: @Int(.unsigned, @bitSizeOf(T) - 1) = 128,
        /// Upper bound of the jitter offset inside a cell.
        inner_box_size: @Int(.unsigned, @bitSizeOf(T) - 1) = 128,

        pub fn getStructure(self: *const Self, position: Vector, level: std.math.Log2Int(T)) ?Vector {
            std.debug.assert(self.box_size > 0);
            std.debug.assert(self.inner_box_size > 0 and self.inner_box_size <= self.box_size);
            const scale: T = @as(T, 1) << @intCast(level);
            std.debug.assert(scale > 0);

            const scale_vec: Vector = @splat(scale);
            const box_size_vec: Vector = @splat(self.box_size);
            const real_position = scale_vec * position;
            const box_position = @divFloor(real_position, box_size_vec);
            const structure_pos = self.findStructureInBox(box_position);
            const pos_in_box = @mod(real_position, box_size_vec); // [0, box_size) for positive divisor

            const in_range = @reduce(.And, structure_pos >= pos_in_box) and
                @reduce(.And, structure_pos < pos_in_box + scale_vec);
            return if (in_range) structure_pos else null;
        }

        fn findStructureInBox(self: *const Self, box_position: Vector) Vector {
            const box_pos_int: @Int(.unsigned, N * @bitSizeOf(T)) = @bitCast(box_position);
            const box_pos_hash_vec: @Vector(N, U) = @bitCast(std.hash.int(box_pos_int));
            const inner: U = @intCast(self.inner_box_size);
            const pos_in_cell = box_pos_hash_vec % @as(@Vector(N, U), @splat(inner));
            return @bitCast(pos_in_cell);
        }
    };
}
