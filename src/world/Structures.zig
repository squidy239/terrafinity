const std = @import("std");
const WorldEditor = @import("World.zig").World.WorldEditor;
const ztracy = @import("root").ztracy;
const Block = @import("World.zig").Block;

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
    const top_r = base_r * top_radius_factor ;
    std.debug.assert(progress >= 0 and progress <= 1);
    const radius = (base_r * (1.0 - progress) + top_r * progress) * scale;
    return @max(1, @as(u32, @intFromFloat(radius)));
}

fn generateTrunk(editor: *WorldEditor, base: @Vector(3, i64), params: GiantTreeGenParams) !void {
    var y: u32 = 0;
    const sh:u32 = @intFromFloat(@as(f32, @floatFromInt(params.height)) * params.scale);
    while (y < sh) : (y += 1) {
        const r = getTaperedRadius(params.base_radius, y, params.height, params.top_radius_factor, params.scale);
        var dx: i32 = -@as(i32, @intCast(r));
        while (dx <= @as(i32, @intCast(r))) : (dx += 1) {
            var dz: i32 = -@as(i32, @intCast(r));
            while (dz <= @as(i32, @intCast(r))) : (dz += 1) {
                if (dx * dx + dz * dz <= @as(i32, @intCast(r)) * @as(i32, @intCast(r))) {
                    try editor.PlaceBlock(.{
                        .block = .Wood,
                        .pos = .{ base[0] + dx, base[1] + @as(i64, @intCast(y)), base[2] + dz },
                    });
                }
            }
        }
    }
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
            const x = base[0] + @as(i64, @intFromFloat(@cos(angle) * dist  * params.scale));
            const z = base[2] + @as(i64, @intFromFloat(@sin(angle) * dist  * params.scale));
            const y = base[1] + @as(i64, @intFromFloat((start_y + t * @as(f32, @floatFromInt(params.branch_length)) * 0.4)  * params.scale));
            try editor.PlaceBlock(.{ .block = .Wood, .pos = .{ x, y, z } });
        }
    }
}

fn generateCanopy(editor: *WorldEditor, base: @Vector(3, i64), params: GiantTreeGenParams, rng: std.Random) !void {
    const r:u32 = @intFromFloat(@as(f32, @floatFromInt(params.canopy_radius)) * params.scale);
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
                    try editor.PlaceBlock(.{
                        .block = .Leaves,
                        .pos = .{ base[0] + x_off, center_y + y_off, base[2] + z_off },
                    });
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
