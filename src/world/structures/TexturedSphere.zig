// Will be used later; keep — do not delete as dead code.
const std = @import("std");

const Sphere = @import("Sphere.zig").Sphere;

pub fn TexturedSphere(comptime T: type, sampler_fn: fn (x: T, y: T, args: anytype) T, SamplerArgsType: type) type {
    return struct {
        sphere: Sphere(T),
        inner_sphere: Sphere(T),
        bounding_box: @Vector(6, T),
        sampler_args: SamplerArgsType,

        pub fn init(pos: @Vector(3, T), radius: T, sampler_args: SamplerArgsType, min_radius_fraction: T) @This() {
            const sphere = Sphere(T).init(pos, radius);
            return .{ .sphere = sphere, .inner_sphere = Sphere(T).init(pos, radius * min_radius_fraction), .sampler_args = sampler_args, .bounding_box = sphere.bounding_box };
        }

        /// True for points inside the outer sphere and outside the carved noise.
        pub fn isPointInside(self: *const @This(), p: @Vector(3, T)) bool {
            if (!self.sphere.isPointInside(p)) return false;
            if (self.inner_sphere.isPointInside(p)) return true;
            const shape_p = p - self.sphere.position;
            const coords = projectEquirectangular(shape_p, self.sphere.radius);
            const sample_amount = sampler_fn(coords[0], coords[1], self.sampler_args);
            const sample_block_pos = self.sphere.position + (shape_p / @as(@Vector(3, T), @splat(sample_amount)));
            return self.sphere.isPointInside(sample_block_pos);
        }
    };
}
/// Maps a sphere-centered offset to flat texture coordinates. Returns origin for a zero offset.
pub fn projectEquirectangular(shape_p: @Vector(3, f64), sphere_radius: f64) @Vector(2, f64) {
    const x = shape_p[0];
    const y = shape_p[1];
    const z = shape_p[2];

    const r = std.math.sqrt(x * x + y * y + z * z);
    if (r == 0) return @Vector(2, f64){ 0.0, 0.0 };

    const phi = std.math.asin(std.math.clamp(y / r, -1.0, 1.0));
    const lambda = std.math.atan2(z, x);

    return @Vector(2, f64){ sphere_radius * lambda, sphere_radius * phi };
}
