const std = @import("std");

const tracy = @import("tracy");

const Block = @import("../Block.zig").Block;
const WorldEditor = @import("../World.zig").Editor;
const Cone = @import("Cone.zig").Cone;
const utils = @import("utils.zig");

pub const Tree = struct {
    pos: @Vector(3, i64),
    config: Config,
    scale: f32 = 1.0,
    rand: std.Random,

    pub const StepConfig = struct {
        length_percent: f32 = 0.7,
        length_percent_randomness: f32 = 0.0,
        base_radius_percent: f32 = 1.0,
        radius_percent: f32 = 0.65,
        radius_percent_randomness: f32 = 0.0,
        branch_count_min: usize = 2,
        branch_count_max: usize = 4,
        min_branch_width: ?f32 = null,
        branch_randomness: f32 = 0.0,
        branch_range: @Vector(3, f32) = @splat(0.2),
        block_type: Block = Block.wood,
        end_block: Block = Block.leaves,
    };
    pub const Config = struct {
        pub const small: Config = @import("Trees/small.zon");
        pub const huge: Config = @import("Trees/huge.zon");

        base_radius: f32,
        base_radius_variation: f32,
        trunk_height: f32,
        trunk_height_variation: f32,

        branch_variation: f32 = 0.2,
        max_recursion_depth: usize = 8,

        leaf_size: f32 = 2.0,
        leaf_density: f32 = 0.75,
        ///must be at least max_recursion_depth
        steps: []const StepConfig,
        min_radius: f32 = 0.5,
        min_length: f32 = 2.0,
    };
    const StepGenData = struct {
        pos: @Vector(3, f64),
        direction: @Vector(3, f64),
        last_length: f32,
        last_radius: f32,
        recursion_depth: usize,
    };

    threadlocal var index: usize = 0;
    pub fn place(self: *const @This(), seed: u64, editor: *WorldEditor, level: i32) !u64 {
        @setFloatMode(.optimized);
        var step_buffer: [64]StepGenData = undefined;
        std.debug.assert(step_buffer.len > self.config.steps.len);
        std.debug.assert(self.config.steps.len > self.config.max_recursion_depth);

        var prng = std.Random.Sfc64.init(seed);
        const rand = prng.random();

        var stack = std.ArrayList(StepGenData).initBuffer(&step_buffer);
        var branches: u64 = 0;
        const trunk_vec: @Vector(3, f64) = @Vector(3, f64){ 0, 1, 0 } + rand3Vec(f32, -0.05, 0.05);

        try stack.appendBounded(.{
            .pos = @floatFromInt(self.pos),
            .direction = trunk_vec,
            .last_length = self.config.trunk_height * self.scale + rand.float(f32) * self.config.trunk_height_variation,
            .last_radius = self.config.base_radius * self.scale + rand.float(f32) * self.config.base_radius_variation,
            .recursion_depth = 0,
        });

        const half_leaf = self.config.leaf_size * self.scale * 0.5;

        while (stack.pop()) |data| {
            const pstep = tracy.Zone.begin(.{ .src = @src(), .name = "placeStep" });
            defer pstep.end();
            std.debug.assert(self.config.steps.len > self.config.max_recursion_depth);
            const step = self.config.steps[data.recursion_depth];
            const first_branches = self.rand.intRangeAtMost(usize, step.branch_count_min, step.branch_count_max);

            for (0..first_branches) |i| {
                const length = data.last_length * step.length_percent + getRand(&index) * step.length_percent_randomness;
                if (length < self.config.min_length * self.scale or data.recursion_depth >= self.config.max_recursion_depth) {
                    const l = tracy.Zone.begin(.{ .src = @src(), .name = "leaves" });
                    defer l.end();
                    var y = -half_leaf;
                    while (y < half_leaf) : (y += 1) {
                        var x = -half_leaf;
                        while (x < half_leaf) : (x += 1) {
                            var z = -half_leaf;
                            while (z < half_leaf) : (z += 1) {
                                const block: Block = if (getRand(&index) < self.config.leaf_density) step.end_block else .null; // Places null to keep whatever block is currently in the world
                                try editor.placeBlock(block, @round(data.pos + @Vector(3, f32){ x, y, z }), level);
                            }
                        }
                    }
                } else {
                    const b = tracy.Zone.begin(.{ .src = @src(), .name = "branch" });
                    defer b.end();
                    branches += 1;
                    const branch_vec = branchDirection(i, data.direction, step.branch_range, first_branches) + rand3Vec(f32, -step.branch_randomness, step.branch_randomness);
                    const radius = data.last_radius * step.radius_percent + getRand(&index) * step.radius_percent_randomness;
                    const branch = Cone(f64).init(data.pos, branch_vec, @floatCast(length), @floatCast(@max(self.config.min_radius, data.last_radius * step.base_radius_percent)), @floatCast(@max(self.config.min_radius, radius)));
                    try editor.placeSamplerShape(step.block_type, branch, level);
                    const new_pos = data.pos + (utils.vecNormalize(branch_vec) * @as(@Vector(3, f64), @splat(length - radius)));
                    try stack.appendBounded(.{
                        .pos = new_pos,
                        .direction = branch_vec,
                        .last_length = length,
                        .last_radius = radius,
                        .recursion_depth = data.recursion_depth + 1,
                    });
                }
            }
        }
        return branches;
    }

    fn rand3Vec(comptime t: type, range_base: t, range_top: t) @Vector(3, t) {
        const vec = @Vector(3, t){ getRand(&index), getRand(&index), getRand(&index) };
        return normalizeInRange(@Vector(3, t), vec, @splat(0), @splat(1), @splat(range_base), @splat(range_top));
    }
    pub fn normalizeInRange(comptime t: type, num: t, old_lower_bound: t, old_upper_bound: t, new_lower_bound: t, new_upper_bound: t) t {
        if (std.meta.eql(old_upper_bound, old_lower_bound)) return new_lower_bound;
        return (num - old_lower_bound) / (old_upper_bound - old_lower_bound) * (new_upper_bound - new_lower_bound) + new_lower_bound;
    }

    ///range is per-axis angular range: 0–2 mapped to 0–360° each
    pub fn branchDirection(iteration: usize, base: @Vector(3, f64), range: @Vector(3, f64), branch_count: usize) @Vector(3, f64) {
        @setFloatMode(.optimized);
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

    fn ellipsoidToSphere(p: @Vector(3, f64), range: @Vector(3, f64)) @Vector(3, f64) {
        const scaled = @Vector(3, f64){
            if (range[0] != 0) p[0] / range[0] else 0.0,
            if (range[1] != 0) p[1] / range[1] else 0.0,
            if (range[2] != 0) p[2] / range[2] else 0.0,
        };
        return utils.vecNormalize(scaled);
    }
};

fn getRand(i: *usize) f32 {
    const v = rand_table[i.*];
    i.* +%= 1;
    i.* = i.* % rand_table.len;
    return v;
}

const rand_table = makeTable(1000);

fn makeTable(len: usize) [len]f32 {
    @setEvalBranchQuota(1000000000);
    var random = std.Random.DefaultPrng.init(0);
    const rand = random.random();
    var table: [len]f32 = undefined;
    var i: usize = 0;
    while (i < table.len) : (i += 1) {
        table[i] = rand.float(f32);
    }
    return table;
}
