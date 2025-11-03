const std = @import("std");
const WorldEditor = @import("World.zig").World.WorldEditor;
const ztracy = @import("root").ztracy;
const Block = @import("World.zig").Block;
const zm = @import("root").zm;

pub const GiantTreeGenParams = struct {
    height: u32,
    base_radius: u32,
    main_branches: u32,
    branch_length: u32,
    canopy_radius: u32,
    branch_start_height_factor: f32,
    top_radius_factor: f32,
    canopy_density: f32,
    scale: f32 = 1.0,
};

fn getTaperedRadius(base_radius: u32, y: u32, height: u32, top_radius_factor: f32, scale: f32) u32 {
    const progress = (@as(f32, @floatFromInt(y))) / (@as(f32, @floatFromInt(height)) * scale);
    const base_r = @as(f32, @floatFromInt(base_radius));
    const top_r = base_r * top_radius_factor;
    std.debug.assert(progress >= 0 and progress <= 1);
    const radius = (base_r * (1.0 - progress) + top_r * progress) * scale;
    return @max(1, @as(u32, @intFromFloat(@round(radius))));
}

fn generateTrunk(editor: *WorldEditor, base: @Vector(3, i64), params: GiantTreeGenParams) !void {
    const f64scale = @as(f64, @floatCast(params.scale));
    const cone = WorldEditor.Cone(f64).init(@floatFromInt(base), .{ 0, 1, 0.0 }, @as(f64, @floatFromInt(params.height)) * f64scale, @as(f64, @floatFromInt(params.base_radius)) * f64scale, @as(f64, @floatFromInt(params.base_radius)) * @as(f64, @floatCast(params.top_radius_factor)) * f64scale);
    try editor.PlaceSamplerShape(.Wood, cone);
}

fn generateBranches(editor: *WorldEditor, base: @Vector(3, i64), params: GiantTreeGenParams) !void {
    const start_y = @as(f32, @floatFromInt(params.height)) * params.branch_start_height_factor;
    var branch: u32 = 0;
    while (branch < params.main_branches) : (branch += 1) {
        const angle = @as(f32, @floatFromInt(branch)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(params.main_branches));
        var step: u32 = 0;
        while (step < params.branch_length) : (step += 1) {
            const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(params.branch_length));
            const dist = t * @as(f32, @floatFromInt(params.branch_length));
            const x = base[0] + @as(i64, @intFromFloat(@cos(angle) * dist * params.scale));
            const z = base[2] + @as(i64, @intFromFloat(@sin(angle) * dist * params.scale));
            const y = base[1] + @as(i64, @intFromFloat((start_y + t * @as(f32, @floatFromInt(params.branch_length)) * 0.4) * params.scale));
            try editor.PlaceBlock(.Wood, .{ x, y, z });
        }
    }
}

fn generateCanopy(editor: *WorldEditor, base: @Vector(3, i64), params: GiantTreeGenParams, rng: std.Random) !void {
    const r: u32 = @intFromFloat(@as(f32, @floatFromInt(params.canopy_radius)) * params.scale);
    const r_sq = r * r;
    const r_y = @max(1, r * 7 / 10); // vertical squash
    const r_y_sq = r_y * r_y;

    const center_y = base[1] + (@as(i64, @intFromFloat(@as(f32, @floatFromInt(params.height)) * params.scale))) + r / 3;

    var x_off: i32 = -@as(i32, @intCast(r));
    while (x_off <= r) : (x_off += 1) {
        var y_off: i32 = -@as(i32, @intCast(r_y));
        while (y_off <= r_y) : (y_off += 1) {
            var z_off: i32 = -@as(i32, @intCast(r));
            while (z_off <= r) : (z_off += 1) {
                const dx = @as(f32, @floatFromInt(x_off));
                const dy = @as(f32, @floatFromInt(y_off));
                const dz = @as(f32, @floatFromInt(z_off));

                // ellipsoid check
                const inside = (dx * dx + dz * dz) / @as(f32, @floatFromInt(r_sq)) + (dy * dy) / @as(f32, @floatFromInt(r_y_sq)) <= 1.0;

                if (inside and rng.float(f32) < params.canopy_density) { // randomness for air gaps
                    try editor.PlaceBlock(.Leaves, .{ base[0] + x_off, center_y + y_off, base[2] + z_off });
                }
            }
        }
    }
}

pub fn PlaceTree(editor: *WorldEditor, base: @Vector(3, i64), rng: std.Random, params: GiantTreeGenParams) !void {
    const trunk = ztracy.ZoneNC(@src(), "gentrunk", 6435);
    try generateTrunk(editor, base, params);
    trunk.End();
    const branches = ztracy.ZoneNC(@src(), "genbranches", 6437);
    try generateBranches(editor, base, params);
    branches.End();
    const canopy = ztracy.ZoneNC(@src(), "gencanopy", 6438);
    try generateCanopy(editor, base, params, rng);
    canopy.End();
}

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
                const branch = WorldEditor.Cone(f64).init(pos, branchVec, @floatCast(length), @floatCast(@max(self.minRadius, lastRadius * step.baseLengthPercent)), @floatCast(@max(self.minRadius, radius)));
                try editor.PlaceSamplerShape(step.block, branch);
                const newPos = pos + (vecNormalize(branchVec) * @as(@Vector(3, f64), @splat(length - radius)));
                branchesCount += try self.placeStep(editor, newPos, branchVec, length, radius, recursionDepth + 1);
            }
        }
        return branchesCount;
    }

    pub const Step = struct {
        lengthPercent: f32 = 0.7,
        lengthPercentRandomness: f32 = 0.0,
        baseLengthPercent: f32 = 1.0,
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
        sample = vecNormalize(sample);
        return sample;
    }

    inline fn vecLength(v: @Vector(3, f64)) f64 {
        return @sqrt(@reduce(.Add, v * v));
    }

    inline fn ellipsoidToSphere(p: @Vector(3, f64), range: @Vector(3, f64)) @Vector(3, f64) {
        const scaled = @Vector(3, f64){
            if (range[0] != 0) p[0] / range[0] else 0.0,
            if (range[1] != 0) p[1] / range[1] else 0.0,
            if (range[2] != 0) p[2] / range[2] else 0.0,
        };
        return vecNormalize(scaled);
    }

    inline fn vecNormalize(v: @Vector(3, f64)) @Vector(3, f64) {
        const len = vecLength(v);
        return if (len > 0.00001) v / @as(@Vector(3, f64), @splat(len)) else v;
    }

    inline fn vecCross(a: @Vector(3, f64), b: @Vector(3, f64)) @Vector(3, f64) {
        return @Vector(3, f64){
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
        };
    }
};
