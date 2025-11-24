const std = @import("std");
const zm = @import("root").zm;
const ztracy = @import("root").ztracy;

const Block = @import("../World.zig").Block;
const WorldEditor = @import("../World.zig").World.WorldEditor;

const utils = @import("utils.zig");

pub const Tree = struct {
    pos: @Vector(3, i64),
    baseRadius: f32,
    trunkHeight: f32,
    branchRandomness: f32 = 0.2,
    maxRecursionDepth: usize = 8,
    leafSize: f32 = 2.0,
    leafDensity: f32 = 0.75,
    ///must be at least maxRecursionDepth
    steps: []const Step,
    rand: std.Random,
    branchCounter: usize = 0,
    minRadius: f32 = 0.75,
    minLength: f32 = 2.0,
    scale: f32 = 1.0,

    pub fn place(self: *const @This(), editor: *WorldEditor) !u64 {
        std.debug.assert(self.steps.len > self.maxRecursionDepth);
        const trunkVec: @Vector(3, f64) = @Vector(3, f64){ 0, 1, 0 } + rand3Vec(f32, self.rand, -0.05, 0.05);
        return try self.placeStep(editor, @floatFromInt(self.pos), trunkVec, self.trunkHeight * self.scale, self.baseRadius * self.scale, 0);
    }

    fn placeStep(self: *const @This(), editor: *WorldEditor, pos: @Vector(3, f64), direction: @Vector(3, f64), lastLength: f32, lastRadius: f32, recursionDepth: usize) !u64 {
        const pstep = ztracy.ZoneNC(@src(), "placeStep", 678678);
        defer pstep.End();

        std.debug.assert(self.steps.len > self.maxRecursionDepth);
        const step = self.steps[recursionDepth];
        const firstBranches = self.rand.intRangeAtMost(usize, step.branchCountMin, step.branchCountMax);
        var branchesCount: u64 = 0;
        for (0..firstBranches) |i| {
            const branchVec = branchDirection(i, direction, step.branchRange, firstBranches) + rand3Vec(f32, self.rand, -step.branchRandomness, step.branchRandomness);
            const length = lastLength * step.lengthPercent + self.rand.float(f32) * step.lengthPercentRandomness;
            const radius = lastRadius * step.radiusPercent + self.rand.float(f32) * step.radiusPercentRandomness;
            if (length < self.minLength * self.scale or recursionDepth >= self.maxRecursionDepth) {
                const halfLeaf = self.leafSize * self.scale * 0.5;
                var y = -halfLeaf;
                while (y < halfLeaf) : (y += 1) {
                    var x = -halfLeaf;
                    while (x <= halfLeaf) : (x += 1) {
                        var z = -halfLeaf;
                        while (z <= halfLeaf) : (z += 1) {
                            const block: Block = if (self.rand.float(f32) < self.leafDensity) step.endBlock else .Air;
                            try editor.PlaceBlock(block, @intFromFloat(@round(pos + @Vector(3, f64){ @floor(x - 0.0001), @floor(y - 0.0001), @floor(z - 0.0001) })));
                        }
                    }
                }
            } else {
                branchesCount += 1;
                const branch = WorldEditor.Geometry.Cone(f64).init(pos, branchVec, @floatCast(length), @floatCast(@max(self.minRadius, lastRadius * step.baseRadiusPercent)), @floatCast(@max(self.minRadius, radius)));
                try editor.PlaceSamplerShape(step.block, branch);
                const newPos = pos + (utils.vecNormalize(branchVec) * @as(@Vector(3, f64), @splat(length - radius)));
                branchesCount += try self.placeStep(editor, newPos, branchVec, length, radius, recursionDepth + 1);
            }
        }
        return branchesCount;
    }

    pub const Step = struct {
        lengthPercent: f32 = 0.7,
        lengthPercentRandomness: f32 = 0.0,
        baseRadiusPercent: f32 = 1.0,
        radiusPercent: f32 = 0.65,
        radiusPercentRandomness: f32 = 0.0,
        branchCountMin: usize = 2.0,
        branchCountMax: usize = 4.0,
        minBranchWidth: ?f32 = null,
        branchRandomness: f32 = 0.0,
        branchRange: @Vector(3, f32) = @splat(0.2),
        block: Block = Block.Wood,
        endBlock: Block = Block.Leaves,
    };

    fn rand3Vec(comptime T: type, rand: std.Random, rangeBase: T, rangeTop: T) @Vector(3, T) {
        const vec = @Vector(3, T){ rand.float(T), rand.float(T), rand.float(T) };
        return NormilizeInRange(@Vector(3, T), vec, @splat(0), @splat(1), @splat(rangeBase), @splat(rangeTop));
    }
    pub fn NormilizeInRange(comptime T: type, num: T, oldLowerBound: T, oldUpperBound: T, newLowerBound: T, newUpperBound: T) T {
        return (num - oldLowerBound) / (oldUpperBound - oldLowerBound) * (newUpperBound - newLowerBound) + newLowerBound;
    }

    ///range is per-axis angular range: 0–2 mapped to 0–360° each
    pub fn branchDirection(iteration: usize, base: @Vector(3, f64), range: @Vector(3, f64), branch_count: usize) @Vector(3, f64) {
        const pi = std.math.pi;
        const n = @as(f64, @floatFromInt(branch_count));
        const i = @as(f64, @floatFromInt(iteration));
        const offset = 2.0 / n;
        const increment = pi * (3.0 - @sqrt(5.0));
        const y = (i * offset) - 1.0 + (offset * 0.5);
        const r = @sqrt(@max(0.0, 1.0 - y * y));
        const azimuth = i * increment;
        const x = @cos(azimuth) * r;
        const z = @sin(azimuth) * r;
        var sample = @Vector(3, f64){ x, y, z };

        sample = ellipsoidToSphere(sample, range);
        sample = sample * range;

        sample += base;
        sample = utils.vecNormalize(sample);
        return sample;
    }

    inline fn ellipsoidToSphere(p: @Vector(3, f64), range: @Vector(3, f64)) @Vector(3, f64) {
        const scaled = @Vector(3, f64){
            if (range[0] != 0) p[0] / range[0] else 0.0,
            if (range[1] != 0) p[1] / range[1] else 0.0,
            if (range[2] != 0) p[2] / range[2] else 0.0,
        };
        return utils.vecNormalize(scaled);
    }
};
