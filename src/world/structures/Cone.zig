const std = @import("std");
const utils = @import("utils.zig");

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

test "cone bounding box spans endpoints expanded by max radius" {
    const C = Cone(f32);
    const up = C.init(.{ 0, 0, 0 }, .{ 0, 1, 0 }, 4, 1, 1);
    const up_expected: @Vector(6, f32) = .{ -1, 1, -1, 5, -1, 1 };
    const diagonal = C.init(.{ 10, 0, 5 }, .{ 1, -1, 1 }, 3, 1, 1);
    const diagonal_expected: @Vector(6, f32) = .{ 9, 13, -3, 1, 4, 8 };
    const down = C.init(.{ 0, 10, 0 }, .{ 0, -1, 0 }, 4, 2, 0);
    const down_expected: @Vector(6, f32) = .{ -2, 2, 4, 12, -2, 2 };
    const actuals = [_]@Vector(6, f32){ up.bounding_box, diagonal.bounding_box, down.bounding_box };
    const expecteds = [_]@Vector(6, f32){ up_expected, diagonal_expected, down_expected };
    for (actuals, expecteds) |actual, expected| {
        inline for (0..6) |i| try std.testing.expectEqual(expected[i], actual[i]);
    }
}
