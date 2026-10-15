const std = @import("std");
const utils = @import("utils.zig");

/// Truncated cone along an axis from `position`, with a linear radius change over `length`.
pub fn Cone(comptime T: type) type {
    return struct {
        position: @Vector(3, T),
        axis: @Vector(3, T),
        length: T,
        radius_base: T,
        precalc_radius: T,
        bounding_box: @Vector(6, T),
        pub fn init(pos: @Vector(3, T), axis_vec: @Vector(3, T), cone_length: T, base_r: T, top_r: T) @This() {
            const norm_axis = axis_vec / @as(@Vector(3, T), @splat(@sqrt(utils.dot(axis_vec, axis_vec))));
            const base = pos + norm_axis * @as(@Vector(3, T), @splat(cone_length));
            const r: @Vector(3, T) = @splat(@max(top_r, base_r));
            const lo = @floor(@min(pos, base) - r);
            const hi = @ceil(@max(pos, base) + r);
            return .{
                .position = pos,
                .axis = norm_axis,
                .length = cone_length,
                .radius_base = base_r,
                .precalc_radius = (top_r - base_r) / cone_length,
                .bounding_box = .{ lo[0], hi[0], lo[1], hi[1], lo[2], hi[2] },
            };
        }

        pub fn isPointInside(self: *const @This(), p: @Vector(3, T)) bool {
            const v = p - self.position;
            const dist = utils.dot(v, self.axis);

            if (dist < 0 or dist > self.length) {
                @branchHint(.unlikely);
                return false;
            }

            const r = @mulAdd(T, self.precalc_radius, dist, self.radius_base);
            return utils.dot(v, v) - dist * dist < r * r;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
