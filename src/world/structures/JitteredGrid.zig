const std = @import("std");

box_size: u31 = 128,
inner_box_size: u31 = 128,

pub fn getStructure(self: *const @This(), position: @Vector(2, i32), level: u31) ?@Vector(2, u32) {
    const scale = std.math.pow(u31, 2, level);
    const scale_vec: @Vector(2, u31) = @splat(scale);
    const box_size_vec: @Vector(2, u31) = @splat(self.box_size);
    const real_position = scale_vec * position;
    const structure_pos_in_box = self.findStructureInBox(@divFloor(real_position, box_size_vec));
    const pos_in_box = @as(@Vector(2, u32), @intCast(@mod(real_position, box_size_vec)));
    const tree_in_range = @reduce(.And, structure_pos_in_box >= pos_in_box) and @reduce(.And, structure_pos_in_box < pos_in_box + scale_vec);
    return if (tree_in_range) structure_pos_in_box else asrt: {
        std.debug.assert(scale <= self.box_size);
        break :asrt null;
    };
}

fn findStructureInBox(self: *const @This(), box_position: @Vector(2, i32)) @Vector(2, u32) {
    const box_pos_int: u64 = @bitCast(box_position);
    const box_pos_hash_vec: @Vector(2, u32) = @bitCast(std.hash.int(box_pos_int));
    const pos_in_cell = box_pos_hash_vec % @as(@Vector(
        2,
        u31,
    ), @splat(self.inner_box_size));
    return pos_in_cell;
}

test {
    if (true) return error.SkipZigTest;
    const placer: @This() = .{};
    for (0..96) |i| {
        for (0..96) |j| {
            std.debug.print("{d}", .{@intFromBool(placer.isStructure(.{ @intCast(i), @intCast(j) }, 6))});
        }
        std.debug.print("\n", .{});
    }
}
