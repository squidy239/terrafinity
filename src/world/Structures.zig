const std = @import("std");
const Step = @import("World.zig").World.WorldEditor.Step;
const Block = @import("World.zig").Block;
const WorldEditor = @import("World.zig").World.WorldEditor;

//many structures are made with AI
// In Structures.zig

pub fn GenMassiveTree(state: anytype, genParams: anytype) ?Step {
    var State: *MassiveTreeState = state;
    const stage = State.stage;
    State.stage += 1;

    const base_radius = genParams.base_radius;
    const height = genParams.height;
    const branch_start_height = height * 3 / 10;
    const total_trunk_blocks = calculateTrunkBlocks(base_radius, height);
    const main_branches = genParams.main_branches;
    const branch_length = genParams.branch_length;

    // Phase 1: Generate tapered trunk with root flare
    if (stage < total_trunk_blocks) {
        const trunk_pos = getTrunkPosition(stage, base_radius, height);
        if (trunk_pos) |pos| {
            return Step{ .block = .Wood, .pos = pos };
        }
        return GenMassiveTree(state, genParams);
    }

    // Phase 2: Generate main branches
    const branch_stage = stage - total_trunk_blocks;
    const branch_blocks_per_main = branch_length * branch_length; // Approximate blocks per branch system
    const current_main_branch = @divFloor(branch_stage, branch_blocks_per_main);

    if (current_main_branch < main_branches) {
        const local_branch_stage = branch_stage - current_main_branch * branch_blocks_per_main;
        const branch_angle = @as(f32, @floatFromInt(current_main_branch)) * 2.0 * 3.14159 / @as(f32, @floatFromInt(main_branches));
        const branch_y = @as(i64, branch_start_height) + @divFloor(@as(i64, @intCast(current_main_branch)) * (@as(i64, height) - branch_start_height), @as(i64, @intCast(main_branches)));

        if (getBranchPosition(local_branch_stage, branch_angle, branch_y, branch_length, genParams.branch_subdivisions)) |branch_pos| {
            return Step{ .block = .Wood, .pos = branch_pos };
        }
        return GenMassiveTree(state, genParams);
    }

    // Phase 3: Generate leaves on branch ends
    const leaf_stage = branch_stage - @as(i64, @intCast(main_branches)) * branch_blocks_per_main;
    const leaves_per_branch = genParams.leaf_density;
    const total_leaf_clusters = main_branches * leaves_per_branch;
    const current_leaf_cluster = @divFloor(leaf_stage, 27); // 3x3x3 leaf cluster

    if (current_leaf_cluster < total_leaf_clusters) {
        const cluster_branch = @divFloor(current_leaf_cluster, leaves_per_branch);
        const cluster_index = @mod(current_leaf_cluster, leaves_per_branch);
        const local_leaf_stage = leaf_stage - current_leaf_cluster * 27;

        const branch_angle = @as(f32, @floatFromInt(cluster_branch)) * 2.0 * 3.14159 / @as(f32, @floatFromInt(main_branches));
        const branch_end_x = @as(i64, @intFromFloat(@cos(branch_angle) * @as(f32, @floatFromInt(branch_length))));
        const branch_end_z = @as(i64, @intFromFloat(@sin(branch_angle) * @as(f32, @floatFromInt(branch_length))));
        const branch_end_y = @as(i64, branch_start_height) + @divFloor(@as(i64, @intCast(cluster_branch)) * (@as(i64, height) - branch_start_height), @as(i64, @intCast(main_branches))) + branch_length / 3;

        // Add variation to leaf cluster positions
        const cluster_offset_x = (@mod(cluster_index * 7, 5)) - 2;
        const cluster_offset_z = (@mod(cluster_index * 11, 5)) - 2;
        const cluster_offset_y = (@mod(cluster_index * 3, 3)) - 1;

        const leaf_x = @mod(local_leaf_stage, 3) - 1;
        const leaf_y = @mod(@divFloor(local_leaf_stage, 3), 3) - 1;
        const leaf_z = @divFloor(local_leaf_stage, 9) - 1;

        return Step{ .block = .Leaves, .pos = .{ branch_end_x + cluster_offset_x + leaf_x, branch_end_y + cluster_offset_y + leaf_y, branch_end_z + cluster_offset_z + leaf_z } };
    }

    return null;
}

fn calculateTrunkBlocks(base_radius: u32, height: u32) i64 {
    var total: i64 = 0;
    for (0..height) |y| {
        const radius_at_height = @max(1, base_radius - (@as(u32, @intCast(y)) * base_radius) / (height * 2));
        total += @as(i64, (2 * radius_at_height + 1) * (2 * radius_at_height + 1));
    }
    return total;
}

fn getTrunkPosition(stage: i64, base_radius: u32, height: u32) ?@Vector(3, i64) {
    var current_stage: i64 = 0;
    for (0..height) |y| {
        const radius_at_height = @max(1, base_radius - (@as(u32, @intCast(y)) * base_radius) / (height * 2));
        const blocks_at_height = (2 * radius_at_height + 1) * (2 * radius_at_height + 1);

        if (current_stage + @as(i64, blocks_at_height) > stage) {
            const local_stage = stage - current_stage;
            const diameter = 2 * radius_at_height + 1;
            const x = @mod(local_stage, @as(i64, diameter)) - @as(i64, radius_at_height);
            const z = @divFloor(local_stage, @as(i64, diameter)) - @as(i64, radius_at_height);

            // Circular trunk shape
            if (x * x + z * z <= @as(i64, radius_at_height * radius_at_height)) {
                return @Vector(3, i64){ x, @as(i64, @intCast(y)), z };
            }
        }
        current_stage += @as(i64, blocks_at_height);
    }
    return null;
}

fn getBranchPosition(local_stage: i64, angle: f32, start_y: i64, length: u32, subdivisions: u32) ?@Vector(3, i64) {
    const segment_length = @divFloor(@as(i64, @intCast(length)), @as(i64, @intCast(subdivisions)));
    const segment = @divFloor(local_stage, segment_length + 1);

    if (segment >= subdivisions) return null;

    const pos_in_segment = @mod(local_stage, segment_length + 1);
    const progress = @as(f32, @floatFromInt(segment * segment_length + pos_in_segment)) / @as(f32, @floatFromInt(length));

    // Branch curves slightly upward and tapers
    const x = @as(i64, @intFromFloat(@cos(angle) * progress * @as(f32, @floatFromInt(length))));
    const z = @as(i64, @intFromFloat(@sin(angle) * progress * @as(f32, @floatFromInt(length))));
    const y = start_y + @as(i64, @intFromFloat(progress * @as(f32, @floatFromInt(length)) * 0.3)); // Slight upward curve

    return @Vector(3, i64){ x, y, z };
}

pub const MassiveTreeState = struct {
    stage: i64 = 0,
};

pub const MassiveTreeGenParams = struct {
    base_radius: u32,
    height: u32,
    main_branches: u32,
    branch_length: u32,
    branch_subdivisions: u32,
    leaf_density: u32, // Leaf clusters per branch
};

pub fn GenGiantTree(state: anytype, genParams: anytype) ?Step {
    var State: *GiantTreeState = state;
    const stage = State.stage;
    State.stage += 1;

    const p: GiantTreeGenParams = genParams;
    const trunk_height = p.height;
    const trunk_radius = p.base_radius;
    const branch_start_y = @as(u32, @intFromFloat(@as(f32, @floatFromInt(trunk_height)) * genParams.branch_start_height_factor));
    const num_branches = p.main_branches;
    const branch_length = p.branch_length;
    const canopy_radius = p.canopy_radius;
    const num_roots = p.num_roots;
    const root_length = p.root_length;

    // Phase 1: Trunk
    const trunk_blocks = calculateGiantTrunkBlocks(trunk_radius, trunk_height, p.top_radius_factor);
    if (stage < trunk_blocks) {
        if (getGiantTrunkPosition(stage, trunk_radius, trunk_height, p.top_radius_factor)) |pos| {
            return Step{ .block = .Wood, .pos = pos };
        }
        return GenGiantTree(state, genParams); // Skip empty space in square iteration
    }

    // Phase 2: Buttress Roots
    var current_stage = trunk_blocks;
    const root_blocks_per_root = root_length * root_length; // Approximation
    if (stage < current_stage + num_roots * root_blocks_per_root) {
        const root_stage = stage - current_stage;
        const root_index = @divFloor(root_stage, root_blocks_per_root);
        const local_root_stage = @mod(root_stage, root_blocks_per_root);
        const root_angle = @as(f32, @floatFromInt(root_index)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(num_roots));

        if (getButtressRootPosition(local_root_stage, root_angle, root_length, trunk_radius)) |pos| {
            return Step{ .block = .Wood, .pos = pos };
        }
        return GenGiantTree(state, genParams);
    }
    current_stage += num_roots * root_blocks_per_root;

    // Phase 3: Branches
    const branch_blocks_per_branch = branch_length * branch_length; // Approximation
    if (stage < current_stage + num_branches * branch_blocks_per_branch) {
        const branch_stage = stage - current_stage;
        const branch_index = @divFloor(branch_stage, branch_blocks_per_branch);
        const local_branch_stage = @mod(branch_stage, branch_blocks_per_branch);

        const branch_angle = @as(f32, @floatFromInt(branch_index)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(num_branches)) + (@as(f32, @floatFromInt(@mod(branch_index, 2))) * std.math.pi / @as(f32, @floatFromInt(num_branches)));
        const y_offset = @as(f32, @floatFromInt(@mod(branch_index, 4))) * 2.0;
        const start_y = @as(f32, @floatFromInt(branch_start_y)) + y_offset;

        if (getGiantBranchPosition(local_branch_stage, branch_angle, start_y, branch_length)) |pos| {
            return Step{ .block = .Wood, .pos = pos };
        }
        return GenGiantTree(state, genParams);
    }
    current_stage += num_branches * branch_blocks_per_branch;

    // Phase 4: Canopy
    const canopy_volume = 4 * std.math.pi * std.math.pow(f32, @as(f32, @floatFromInt(canopy_radius)), 3) / 3; // Sphere volume
    const canopy_blocks_approx = @as(i64, @intFromFloat(canopy_volume * 0.6)); // Approx fill ratio
    if (stage < current_stage + canopy_blocks_approx) {
        const canopy_center_y = trunk_height + canopy_radius / 3;
        if (getCanopyPosition(stage, canopy_radius, State.rand.random())) |pos| {
            return Step{ .block = .Leaves, .pos = .{ pos[0], pos[1] + canopy_center_y, pos[2] } };
        }
        return GenGiantTree(state, genParams);
    }

    return null;
}

fn getTaperedRadius(base_radius: u32, y: u32, height: u32, top_radius_factor: f32) u32 {
    const progress = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height));
    const base_r = @as(f32, @floatFromInt(base_radius));
    const top_r = base_r * top_radius_factor;
    const radius = base_r * (1.0 - progress) + top_r * progress;
    return @max(1, @as(u32, @intFromFloat(radius)));
}

fn calculateGiantTrunkBlocks(base_radius: u32, height: u32, top_radius_factor: f32) i64 {
    var total: i64 = 0;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const radius = getTaperedRadius(base_radius, y, height, top_radius_factor);
        total += (2 * radius + 1) * (2 * radius + 1);
    }
    return total;
}

fn getGiantTrunkPosition(stage: i64, base_radius: u32, height: u32, top_radius_factor: f32) ?@Vector(3, i64) {
    var current_blocks: i64 = 0;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const radius = getTaperedRadius(base_radius, y, height, top_radius_factor);
        const r_sq = radius * radius;
        const blocks_at_height = (2 * radius + 1) * (2 * radius + 1);

        if (stage < current_blocks + blocks_at_height) {
            const local_stage = stage - current_blocks;
            const diameter = 2 * radius + 1;
            const x = @mod(local_stage, @as(i64, @intCast(diameter))) - @as(i64, @intCast(radius));
            const z = @divFloor(local_stage, @as(i64, @intCast(diameter))) - @as(i64, @intCast(radius));

            if (x * x + z * z <= @as(i64, r_sq)) {
                return .{ x, @intCast(y), z };
            }
            return null;
        }
        current_blocks += blocks_at_height;
    }
    return null;
}

fn getButtressRootPosition(local_stage: i64, angle: f32, length: u32, trunk_radius: u32) ?@Vector(3, i64) {
    const l = @as(f32, @floatFromInt(length));
    const progress = std.math.sqrt(@as(f32, @floatFromInt(local_stage)) / (l * l));
    if (progress > 1.0) return null;

    const dist_from_trunk = @as(f32, @floatFromInt(trunk_radius)) + progress * l;
    const root_height = @max(0, @as(i64, @intFromFloat(l / 2.0 * (1.0 - progress * progress))));

    const x = @as(i64, @intFromFloat(@cos(angle) * dist_from_trunk));
    const z = @as(i64, @intFromFloat(@sin(angle) * dist_from_trunk));

    return .{ x, root_height, z };
}

fn getGiantBranchPosition(local_stage: i64, angle: f32, start_y: f32, length: u32) ?@Vector(3, i64) {
    const l = @as(f32, @floatFromInt(length));
    const progress = std.math.sqrt(@as(f32, @floatFromInt(local_stage)) / (l * l));
    if (progress > 1.0) return null;

    const branch_dist = progress * l;
    const x = @as(i64, @intFromFloat(@cos(angle) * branch_dist));
    const z = @as(i64, @intFromFloat(@sin(angle) * branch_dist));
    const y = @as(i64, @intFromFloat(start_y + progress * l * 0.4)); // Upward curve

    return .{ x, y, z };
}

fn getCanopyPosition(_: i64, radius: u32, rand: std.Random) ?@Vector(3, i64) {
    const r_f = @as(f32, @floatFromInt(radius));

    // Sample uniformly within a sphere
    const u = rand.float(f32) * 2.0 - 1.0;
    const theta = rand.float(f32) * 2.0 * std.math.pi;
    const r_sample = std.math.pow(f32, rand.float(f32), 1.0 / 3.0) * r_f;

    const x = @as(i64, @intFromFloat(r_sample * std.math.sqrt(1 - u * u) * @cos(theta)));
    const y = @as(i64, @intFromFloat(r_sample * u));
    const z = @as(i64, @intFromFloat(r_sample * std.math.sqrt(1 - u * u) * @sin(theta)));

    // Reject points outside a slightly squashed ellipsoid for a more natural canopy shape
    const x_f = @as(f32, @floatFromInt(x));
    const y_f = @as(f32, @floatFromInt(y));
    const z_f = @as(f32, @floatFromInt(z));

    if ((x_f * x_f + z_f * z_f) / (r_f * r_f) + (y_f * y_f) / ((r_f * 0.7) * (r_f * 0.7)) > 1.0) {
        return null;
    }

    return .{ x, y, z };
}

pub const GiantTreeState = struct {
    stage: i64 = 0,
    rand: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),
};

pub const GiantTreeGenParams = struct {
    height: u32,
    base_radius: u32,
    main_branches: u32,
    branch_length: u32,
    canopy_radius: u32,
    num_roots: u32,
    root_length: u32,
    branch_start_height_factor: f32,
    top_radius_factor: f32,
};

pub fn GenTree(state: anytype, genParams: anytype) ?Step {
    var State: *TreeState = state;
    const stage = State.stage;
    State.stage += 1;

    const trunk_height = genParams.height;
    const leaf_radius = genParams.leaf_radius;
    const leaf_height = genParams.leaf_height;

    // Generate trunk
    if (stage < trunk_height) {
        return Step{ .block = .Wood, .pos = .{ 0, stage, 0 } };
    }

    // Generate leaves in layers
    const leaf_stage = stage - trunk_height;
    const leaf_layer = @divFloor(leaf_stage, (2 * leaf_radius + 1) * (2 * leaf_radius + 1));

    if (leaf_layer >= leaf_height) return null;

    const layer_pos = leaf_stage - leaf_layer * (2 * leaf_radius + 1) * (2 * leaf_radius + 1);
    const x = @divFloor(layer_pos, 2 * leaf_radius + 1) - @as(i64, leaf_radius);
    const z = @mod(layer_pos, 2 * leaf_radius + 1) - @as(i64, leaf_radius);
    const y = trunk_height + leaf_layer;

    // Create spherical leaf pattern
    const distance_sq = x * x + z * z + (leaf_layer - leaf_height / 2) * (leaf_layer - leaf_height / 2);
    const radius_sq = leaf_radius * leaf_radius;

    if (distance_sq <= radius_sq) {
        // Don't replace the trunk with leaves
        if (x == 0 and z == 0) {
            State.stage += 1; // Skip this position but continue
            return GenTree(state, genParams);
        }
        return Step{ .block = .Leaves, .pos = .{ x, y, z } }; // Using Grass as leaves since no Leaf block is visible
    } else {
        State.stage += 1; // Skip this position
        return GenTree(state, genParams);
    }
}

pub const TreeState = struct {
    stage: i64 = 0,
};

pub const TreeGenParams = struct {
    height: u32,
    leaf_radius: u32,
    leaf_height: u32,
};
