const std = @import("std");

box_size: u31 = 8,
inner_box_size: u31 = 3,

pub fn isStructure(self: *const @This(), position: @Vector(2, i32), level: u31) bool {
    const scale = std.math.pow(u31, 2, level);
    if(scale > self.box_size) return true;
    const real_position = @as(@Vector(2, u31), @splat(scale)) * position;
    const pos_in_box = self.findStructureInBox(@divFloor(real_position, @as(@Vector(2, u31), @splat(self.box_size))));
    return @reduce(.And, pos_in_box == @as(@Vector(2, u32), @intCast(@rem(real_position, @as(@Vector(2, u31), @splat(self.box_size))))));
}

fn findStructureInBox(self: *const @This(), box_position: @Vector(2, i32)) @Vector(2, u32) {
    const box_pos_int: u64 = @bitCast(box_position);
    const box_pos_hash_vec:@Vector(2, u32) = @bitCast(std.hash.int(box_pos_int));
    const pos_in_cell = box_pos_hash_vec % @as(@Vector(2, u31, ), @splat(self.inner_box_size));
    return pos_in_cell;
}

test {
    const placer: @This() = .{};
    for(0..96)|i|{
        for(0..96)|j|{
            std.debug.print("{d}", .{@intFromBool(placer.isStructure(.{@intCast(i), @intCast(j)}, 0))});
        }
        std.debug.print("\n", .{});
    }
}