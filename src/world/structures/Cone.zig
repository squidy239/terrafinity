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
            const top = self.position;
            const base = self.position + self.axis * @as(@Vector(3, t), @splat(self.length));
            const r_max = @max(self.radius_top, self.radius_base);

            const min_x = @floor(@min(top[0], base[0]) - r_max);
            const max_x = @ceil(@max(top[0], base[0]) + r_max);

            const min_y = @floor(@min(top[1], base[1]) - r_max);
            const max_y = @ceil(@max(top[1], base[1]) + r_max);

            const min_z = @floor(@min(top[2], base[2]) - r_max);
            const max_z = @ceil(@max(top[2], base[2]) + r_max);
            self.bounding_box = @Vector(6, t){ min_x, max_x, min_y, max_y, min_z, max_z };
        }
    };
}
