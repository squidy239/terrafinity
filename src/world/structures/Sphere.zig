const std = @import("std");
const utils = @import("utils.zig");

pub fn Sphere(comptime T: type) type {
    return struct {
        position: @Vector(3, T),
        radius: T,
        radius_squared: T,
        bounding_box: @Vector(6, T),
        pub fn init(pos: @Vector(3, T), radius: T) @This() {
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
        /// True when `p` lies inside the sphere surface.
        pub fn isPointInside(self: *const @This(), p: @Vector(3, T)) bool {
            const diff = p - self.position;
            const dist2 = utils.dot(diff, diff);
            return dist2 <= self.radius_squared;
        }
        /// Refreshes the cached box. Call again after any move.
        pub fn updateBoundingBox(self: *@This()) void {
            const r3: @Vector(3, T) = @splat(self.radius);
            const lo = @floor(self.position - r3);
            const hi = @ceil(self.position + r3);
            self.bounding_box = @Vector(6, T){ lo[0], hi[0], lo[1], hi[1], lo[2], hi[2] };
        }
    };
}
