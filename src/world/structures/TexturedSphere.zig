const std = @import("std");

const Block = @import("../World.zig").Block;
const World = @import("../World.zig");
const Sphere = @import("Sphere.zig").Sphere;
const utils = @import("utils.zig");

pub fn TexturedSphere(comptime t: type, sampler_fn: fn (x: t, y: t, args: anytype) t, sampler_args_type: type) type {
    return struct {
        sphere: Sphere(t),
        inner_sphere: Sphere(t),
        bounding_box: @Vector(6, t),
        sampler_args: sampler_args_type,

        pub fn init(pos: @Vector(3, t), radius: t, sampler_args: sampler_args_type, min_radius_fraction: t) @This() {
            const sphere: Sphere(t) = .init(pos, radius);
            const inner_sphere: Sphere(t) = .init(pos, radius * min_radius_fraction);

            return .{
                .sphere = sphere,
                .inner_sphere = inner_sphere,
                .sampler_args = sampler_args,
                .bounding_box = sphere.bounding_box,
            };
        }

        pub fn isPointInside(self: *const @This(), p: @Vector(3, t)) bool {
            if (!self.sphere.isPointInside(p)) return false;
            if (self.inner_sphere.isPointInside(p)) return true;
            const shape_p = p - self.sphere.position;
            const coords = projectEquirectangular(shape_p, self.sphere.radius);
            const sample_amount = sampler_fn(coords[0], coords[1], self.sampler_args);
            const sample_block_pos = self.sphere.position + (shape_p / @as(@Vector(3, t), @splat(sample_amount)));
            return self.sphere.isPointInside(sample_block_pos);
        }
    };
}

pub fn noiseSphere(editor: *World.Editor, center_pos: @Vector(3, f64), radius: f64, min_radius_factor: f32, noise: World.DefaultGenerator.Noise.Noise(f32), block: Block, level: i32) !void {
    const explosion_sphere = TexturedSphere(f64, noiseTexture, NoiseParams).init(center_pos, radius, NoiseParams{ .noise = noise, .min_radius = min_radius_factor }, min_radius_factor);
    try editor.placeSamplerShape(block, explosion_sphere, level);
}
const NoiseParams = struct {
    noise: World.DefaultGenerator.Noise.Noise(f32),
    minRadius: f32,
};
fn noiseTexture(u: f64, v: f64, args: anytype) f64 {
    const sampled = args.noise.genNoise2DRange(@floatCast(u), @floatCast(v), f32, 0, 1);
    return @floatCast(std.math.lerp(sampled, @as(f32, 1.0), @as(f32, args.minRadius)));
}

pub fn projectEquirectangular(shapeP: @Vector(3, f64), sphere_radius: f64) @Vector(2, f64) {
    const x = shapeP[0];
    const y = shapeP[1];
    const z = shapeP[2];

    const r = std.math.sqrt(x * x + y * y + z * z);
    if (r == 0) return @Vector(2, f64){ 0.0, 0.0 };

    const phi = std.math.asin(std.math.clamp(y / r, -1.0, 1.0)); // latitude
    const lambda = std.math.atan2(z, x); // longitude

    return @Vector(2, f64){ sphere_radius * lambda, sphere_radius * phi };
}
