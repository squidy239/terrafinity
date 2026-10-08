const std = @import("std");
const utils = @import("utils.zig");

pub fn Sphere(comptime T: type) type {
    return struct {
        position: @Vector(3, T),
        radius: T,
        bounding_box: @Vector(6, T),
        pub fn init(pos: @Vector(3, T), radius: T) @This() {
            std.debug.assert(radius >= 0);
            const r3: @Vector(3, T) = @splat(radius);
            const lo = @floor(pos - r3);
            const hi = @ceil(pos + r3);
            return .{ .position = pos, .radius = radius, .bounding_box = .{ lo[0], hi[0], lo[1], hi[1], lo[2], hi[2] } };
        }
        /// True when `p` lies inside the sphere surface.
        pub fn isPointInside(self: *const @This(), p: @Vector(3, T)) bool {
            const diff = p - self.position;
            return utils.dot(diff, diff) <= self.radius * self.radius;
        }
    };
}
