const utils = @import("utils.zig");

pub fn Sphere(comptime t: type) type {
    return struct {
        position: @Vector(3, t),
        radius: t,
        radius_squared: t,
        bounding_box: @Vector(6, t),
        pub fn init(pos: @Vector(3, t), radius: t) @This() {
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

            const min_x = @floor(@min(self.position[0] - r, self.position[0] + r));
            const max_x = @ceil(@max(self.position[0] - r, self.position[0] + r));

            const min_y = @floor(@min(self.position[1] - r, self.position[1] + r));
            const max_y = @ceil(@max(self.position[1] - r, self.position[1] + r));

            const min_z = @floor(@min(self.position[2] - r, self.position[2] + r));
            const max_z = @ceil(@max(self.position[2] - r, self.position[2] + r));
            self.bounding_box = @Vector(6, t){ min_x, max_x, min_y, max_y, min_z, max_z };
        }
    };
}
