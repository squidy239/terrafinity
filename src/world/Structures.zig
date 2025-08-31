const std = @import("std");
const Step = @import("World.zig").World.Step;
const Block = @import("World.zig").Block;

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
