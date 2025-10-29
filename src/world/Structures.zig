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
    baseRadius: f64,
    trunkHeight: f64,
    branchRandomness: f64 = 0.2,
    branchRange: @Vector(3, f64) = @splat(0.1),
    maxRecursionDepth: usize = 20,
    leafSize: f64 = 1.0,
    rand: std.Random,

    pub fn PlaceTree(self: *const @This(), editor: *WorldEditor) !void {
        var pos: @Vector(3, f64) = @floatFromInt(self.pos);
        const trunkVec: @Vector(3, f64) = @Vector(3, f64){ 0, 1, 0 } + rand3Vec(self.rand, -0.25, 0.25);
        const trunk = WorldEditor.Cone(f64).init(@floatFromInt(self.pos), trunkVec, self.trunkHeight, self.baseRadius, self.baseRadius);
        try editor.PlaceSamplerShape(.Wood, trunk);
        pos += trunkVec * @as(@Vector(3, f64), @splat(self.trunkHeight)) * @Vector(3, f64){ 0.9, 0.9, 0.9 };
        const step: Step = .{};
        try self.placeStep(editor, step, pos, trunkVec, self.trunkHeight, self.baseRadius, 1);
    }

    fn placeBranches(self: *const @This(), editor: *WorldEditor, pos: @Vector(3, f64), direction: @Vector(3, f64), iteration: usize) !void {
        const firstBranches = self.rand.intRangeAtMost(usize, 2, 4);
        const branchLengthPercent = std.math.pow(f64, self.BranchLengthPercent, @floatFromInt(iteration));
        const topbranchRadiusPercent = std.math.pow(f64, self.BranchRadiusPercent, @floatFromInt(iteration));
        const bottombranchRadiusPercent = std.math.pow(f64, self.BranchRadiusPercent, @floatFromInt(iteration -| 1));

        for (0..firstBranches) |i| {
            const branchVec = branchDirection(i, direction, self.branchRange, firstBranches) + rand3Vec(self.rand, -self.branchRandomness, self.branchRandomness);
            const branch = WorldEditor.Cone(f64).init((pos), branchVec, self.trunkHeight * branchLengthPercent, self.baseRadius * bottombranchRadiusPercent, self.baseRadius * topbranchRadiusPercent);
            if (branch.length < 1.0) {
                try editor.PlaceBlock(.Leaves, @intFromFloat(@round(branch.position)));
            } else {
                const block = if (branch.length < 2.0) Block.Leaves else Block.Wood;
                try editor.PlaceSamplerShape(block, branch);
                if (iteration < self.maxRecursionDepth) {
                    try self.placeBranches(editor, pos + branchVec * @as(@Vector(3, f64), @splat(branch.length)) * @Vector(3, f64){ 0.9, 0.9, 0.9 }, branchVec, iteration + 1);
                }
            }
        }
    }

    fn placeStep(self: *const @This(), editor: *WorldEditor, step: Step, pos: @Vector(3, f64), direction: @Vector(3, f64), lastLength: f64, lastRadius: f64, recursionDepth: usize) !void {
        const firstBranches = self.rand.intRangeAtMost(usize, step.branchCountMin, step.branchCountMax);

        for (0..firstBranches) |i| {
            const branchVec = branchDirection(i, direction, self.branchRange, firstBranches) + rand3Vec(self.rand, -step.branchRandomness, step.branchRandomness);
            const length = lastLength * step.lengthPercent + self.rand.float(f64) * step.lengthPercentRandomness;
            const radius = lastRadius * step.radiusPercent + self.rand.float(f64) * step.radiusPercentRandomness;
            const branch = WorldEditor.Cone(f64).init(pos, branchVec, length, lastRadius, radius);
            if (length < self.leafSize or recursionDepth > self.maxRecursionDepth) {
                if (self.leafSize <= 1.0) {
                    try editor.PlaceBlock(.Leaves, @intFromFloat(@floor(pos)));
                } else {
                    const halfLeaf = self.leafSize * 0.5;
                    var y = -halfLeaf;
                    while (y < halfLeaf) : (y += 1) {
                        var x = -halfLeaf;
                        while (x <= halfLeaf) : (x += 1) {
                            var z = -halfLeaf;
                            while (z <= halfLeaf) : (z += 1) {
                                try editor.PlaceBlock(.Leaves, @intFromFloat(@floor(pos + @Vector(3, f64){ x, y, z })));
                            }
                        }
                    }
                }
            } else {
                try editor.PlaceSamplerShape(.Wood, branch);
                const newPos = pos + (branchVec * @as(@Vector(3, f64), @splat(length)) * @Vector(3, f64){ 0.9, 0.9, 0.9 });
                try self.placeStep(editor, step, newPos, branchVec, length, radius, recursionDepth + 1);
            }
        }
    }

    pub const Step = struct {
        lengthPercent: f64 = 0.7,
        lengthPercentRandomness: f64 = 0.0,
        radiusPercent: f64 = 0.65,
        radiusPercentRandomness: f64 = 0.0,
        branchCountMin: usize = 2.0,
        branchCountMax: usize = 4.0,
        branchRandomness: f64 = 0.2,
    };

    fn rand3Vec(rand: std.Random, rangeBase: f64, rangeTop: f64) @Vector(3, f64) {
        const vec = @Vector(3, f64){ rand.float(f64), rand.float(f64), rand.float(f64) };
        return NormilizeInRange(@Vector(3, f64), vec, @splat(0), @splat(1), @splat(rangeBase), @splat(rangeTop));
    }
    pub fn NormilizeInRange(comptime T: type, num: T, oldLowerBound: T, oldUpperBound: T, newLowerBound: T, newUpperBound: T) T {
        return (num - oldLowerBound) / (oldUpperBound - oldLowerBound) * (newUpperBound - newLowerBound) + newLowerBound;
    }

    pub fn branchDirection(iteration: usize, base: @Vector(3, f64), range: @Vector(3, f64), branch_count: usize) @Vector(3, f64) {
        const pi = std.math.pi;

        // 1. Compute orientation and angle from range vector
        const range_len = vecLength(range);
        const max_angle_rad = pi;
        const cone_angle = range_len * max_angle_rad; // 0–280° mapped from 0–1
        // 2. Create orthonormal basis
        const up = if (@abs(base[2]) < 0.999)
            @Vector(3, f32){ 0.0, 0.0, 1.0 }
        else
            @Vector(3, f32){ 1.0, 0.0, 0.0 };

        const right = vecNormalize(vecCross(up, base));
        const forward = vecNormalize(vecCross(base, right));

        // 3. Azimuth angle for this branch
        const azimuth = (2.0 * pi * @as(f64, @floatFromInt(iteration))) / @as(f64, @floatFromInt(branch_count));

        // 4. Build local cone offset direction
        const x: @Vector(3, f64) = @splat(std.math.sin(cone_angle) * std.math.cos(azimuth));
        const y: @Vector(3, f64) = @splat(std.math.sin(cone_angle) * std.math.sin(azimuth));
        const z: @Vector(3, f64) = @splat(std.math.cos(cone_angle));

        var branch = x * right + y * forward + z * base;

        // 5. Lean the branch toward the range vector’s direction
        branch = vecNormalize(branch);

        return vecNormalize(branch);
    }

    inline fn vecLength(v: @Vector(3, f64)) f64 {
        return @sqrt(@reduce(.Add, v * v));
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
