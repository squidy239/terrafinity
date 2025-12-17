const utils = @import("utils.zig");

const std = @import("std");
const zm = @import("root").zm;
const ztracy = @import("root").ztracy;

const Block = @import("../World.zig").Block;
const World = @import("../World.zig").World;

pub fn TexturedSphere(comptime T: type, samplerFn: fn (x: T, y: T, args: anytype) T, samplerArgsType: type) type {
    return struct {
        sphere: World.WorldEditor.Geometry.Sphere(T),
        innerSphere: World.WorldEditor.Geometry.Sphere(T),
        boundingBox: @Vector(6, T),
        samplerArgs: samplerArgsType,

        pub fn init(pos: @Vector(3, T), radius: T, samplerArgs: samplerArgsType, minRadiusFraction: T) @This() {
            var sphere: World.WorldEditor.Geometry.Sphere(T) = .{
                .position = pos,
                .radius = radius,
                .boundingBox = undefined,
            };
            sphere.updateBoundingBox();

            var innersphere: World.WorldEditor.Geometry.Sphere(T) = .{
                .position = pos,
                .radius = radius * minRadiusFraction,
                .boundingBox = undefined,
            };
            innersphere.updateBoundingBox();
            return .{
                .sphere = sphere,
                .innerSphere = innersphere,
                .samplerArgs = samplerArgs,
                .boundingBox = sphere.boundingBox,
            };
        }

        pub fn isPointInside(self: *const @This(), P: @Vector(3, T)) bool {
            if (!self.sphere.isPointInside(P)) return false;
            if (self.innerSphere.isPointInside(P)) return true;
            const shapeP = P - self.sphere.position;
            const coords = projectEquirectangular(shapeP, self.sphere.radius);
            const sampleAmount = samplerFn(coords[0], coords[1], self.samplerArgs);
            const sampleBlockPos = self.sphere.position + (shapeP / @as(@Vector(3, T), @splat(sampleAmount)));
            return self.sphere.isPointInside(sampleBlockPos);
        }
    };
}

pub fn NoiseSphere(editor: *World.WorldEditor, centerPos: @Vector(3, f64), radius: f64, minRadiusFactor: f32, noise: World.DefaultGenerator.Noise.Noise(f32), block: Block, level: i32) !void {
    const explosionSphere = TexturedSphere(f64, noiseTexture, NoiseParams).init(centerPos, radius, NoiseParams{ .noise = noise, .minRadius = minRadiusFactor }, minRadiusFactor);
    try editor.PlaceSamplerShape(block, explosionSphere, level);
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

    const X = sphere_radius * lambda;
    const Y = sphere_radius * phi;

    return @Vector(2, f64){ X, Y };
}
