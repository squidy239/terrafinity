const std = @import("std");
const utils = @import("utils.zig");

pub fn Cone(comptime t: type) type {
    return struct {
        position: @Vector(3, t), // top center of cone
        axis: @Vector(3, t), // normalized axis (direction from top → base)
        one_d_length: t,
        length: t,
        radius_top: t,
        radius_base: t,
        precalc_radius: t,
        bounding_box: @Vector(6, t),
        pub fn init(pos: @Vector(3, t), axis_vec: @Vector(3, t), cone_length: t, base_r: t, top_r: t) @This() {
            // normalize axis
            const norm_axis = axis_vec / @as(@Vector(3, t), @splat(@sqrt(utils.dot(axis_vec, axis_vec))));
            var cone: @This() = .{
                .position = pos,
                .axis = norm_axis,
                .one_d_length = 1.0 / cone_length,
                .length = cone_length,
                .radius_top = top_r,
                .radius_base = base_r,
                .precalc_radius = (top_r - base_r) / cone_length,
                .bounding_box = undefined,
            };
            cone.updateBoundingBox();
            return cone;
        }

        pub fn isPointInside(self: *const @This(), p: @Vector(3, t)) bool {
            const v = p - self.position;
            const dist = utils.dot(v, self.axis);

            if (dist < 0 or dist > self.length) {
                @branchHint(.unlikely);
                return false;
            }

            const r = @mulAdd(t, self.precalc_radius, dist, self.radius_base);
            return utils.dot(v, v) - dist * dist < r * r;
        }

        pub fn updateBoundingBox(self: *@This()) void {
            const base = self.position + self.axis * @as(@Vector(3, t), @splat(self.length));
            const r: @Vector(3, t) = @splat(@max(self.radius_top, self.radius_base));
            const lo = @floor(@min(self.position, base) - r);
            const hi = @ceil(@max(self.position, base) + r);
            self.bounding_box = .{ lo[0], hi[0], lo[1], hi[1], lo[2], hi[2] };
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
