const std = @import("std");
const utils = @import("utils.zig");

pub fn Sphere(comptime t: type) type {
    return struct {
        position: @Vector(3, t),
        radius: t,
        radius_squared: t,
        bounding_box: @Vector(6, t),
        pub fn init(pos: @Vector(3, t), radius: t) @This() {
            std.debug.assert(radius >= 0);
            var sphere: @This() = .{
                .position = pos,
                .radius = radius,
                .radius_squared = radius * radius,
                .bounding_box = undefined,
            };
            sphere.updateBoundingBox();
            return sphere;
        }

        pub fn isPointInside(self: *const @This(), p: @Vector(3, t)) bool {
            const diff = p - self.position;
            const dist2 = utils.dot(diff, diff);
            return dist2 <= self.radius_squared;
        }

        pub fn updateBoundingBox(self: *@This()) void {
            const r = self.radius;
            const lo_x = @floor(self.position[0] - r);
            const hi_x = @ceil(self.position[0] + r);
            const lo_y = @floor(self.position[1] - r);
            const hi_y = @ceil(self.position[1] + r);
            const lo_z = @floor(self.position[2] - r);
            const hi_z = @ceil(self.position[2] + r);
            self.bounding_box = @Vector(6, t){ @min(lo_x, hi_x), @max(lo_x, hi_x), @min(lo_y, hi_y), @max(lo_y, hi_y), @min(lo_z, hi_z), @max(lo_z, hi_z) };
        }
    };
}
