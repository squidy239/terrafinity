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
    const cone = VectorAlignedCone(f64).init(@splat(0.0), .{ 0, 1, 0.0 },@as(f64, @floatFromInt(params.height)) * f64scale, @as(f64, @floatFromInt(params.base_radius)) * f64scale, @as(f64, @floatFromInt(params.base_radius)) * @as(f64, @floatCast(params.top_radius_factor)) * f64scale);
    const boundingBox = cone.boundingBox;
    var y: i32 = @intFromFloat(boundingBox[2]);
    std.debug.print("bb: {any}\n", .{boundingBox});
    while (y < @as(i32, @intFromFloat(boundingBox[3]))) : (y += 1) {
        var dx: i32 = @intFromFloat(boundingBox[0]);
        while (dx <= @as(i32, @intFromFloat(boundingBox[1]))) : (dx += 1) {
            var dz: i32 = @intFromFloat(boundingBox[4]);
            while (dz <= @as(i32, @intFromFloat(boundingBox[5]))) : (dz += 1) {
                const pos: @Vector(3, i64) = .{ base[0] + dx, base[1] + @as(i64, @intCast(y)), base[2] + dz };
                if (cone.isPointInside(@floatFromInt(pos - base))) {
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
            const x = base[0] + @as(i64, @intFromFloat(@cos(angle) * dist * params.scale));
            const z = base[2] + @as(i64, @intFromFloat(@sin(angle) * dist * params.scale));
            const y = base[1] + @as(i64, @intFromFloat((start_y + t * @as(f32, @floatFromInt(params.branch_length)) * 0.4) * params.scale));
            try editor.PlaceBlock(.{ .block = .Wood, .pos = .{ x, y, z } });
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


pub fn VectorAlignedCone(comptime T: type) type {
    return struct {
        position: @Vector(3, T), // top center of cone
        axis: @Vector(3, T),     // normalized axis (direction from top → base)
        length: T,
        radiusTop: T,
        radiusBase: T,
        boundingBox: @Vector(6, T),
        pub fn init(pos: @Vector(3, T), axisVec: @Vector(3, T), coneLength: T, topR: T, baseR: T) @This() {
            // normalize axis
            const normAxis = axisVec / @as(@Vector(3, T), @splat(@sqrt(dot(axisVec, axisVec))));
            var cone: @This() = .{
                .position = pos,
                .axis = normAxis,
                .length = coneLength,
                .radiusTop = topR,
                .radiusBase = baseR,
                .boundingBox = undefined,
            };
            cone.updateBoundingBox();
            return cone;
        }

        pub fn isPointInside(self: *const @This(), P: @Vector(3, T)) bool {
            const v = P - self.position;
            const t = dot(v, self.axis);
        
            if (t < 0 or t > self.length) return false;
        
            const len2 = dot(v, v);
            const perp2 = len2 - t * t;
        
            // if axis points opposite direction (down), swap radius order
            const rTop = if (self.axis[1] >= 0) self.radiusTop else self.radiusBase;
            const rBase = if (self.axis[1] >= 0) self.radiusBase else self.radiusTop;
        
            const r = rTop + (rBase - rTop) * (t / self.length);
            return perp2 <= r * r;
        }

        pub fn updateBoundingBox(self: *@This()) void {
            const top = self.position;
            const base = self.position + self.axis * @as(@Vector(3, T), @splat(self.length));
            const rMax = @max(self.radiusTop, self.radiusBase);
            
            const minX = @floor(@min(top[0], base[0]) - rMax);
            const maxX = @ceil(@max(top[0], base[0]) + rMax);
            
            const minY = @floor(@min(top[1], base[1]) - rMax);
            const maxY = @ceil(@max(top[1], base[1]) + rMax);
            
            const minZ = @floor(@min(top[2], base[2]) - rMax);
            const maxZ = @ceil(@max(top[2], base[2]) + rMax);
            self.boundingBox = @Vector(6, T){ minX, maxX, minY, maxY, minZ, maxZ};
        }
        
        const Cone = @This();
        pub const Iterator = struct {
            iteraton:usize = 0,
            cone: *const Cone,
            x_off: T,
            y_off: T,
            z_off: T,
            resolution: T,
            pub fn next(self: *@This()) ?@Vector(3, T) {
                defer self.iteraton += 1;
                const zLength = self.cone.boundingBox[5] - self.cone.boundingBox[4];
                const yLength = self.cone.boundingBox[3] - self.cone.boundingBox[2];
                const z = @rem(self.iteraton, zLength);
                const y = (self.iteraton / zLength) % yLength;
                const x = self.iteraton / (yLength * zLength); 
                var pos = @Vector(3, T){x, y, z};
                pos = pos + self.cone.position;
                if(self.cone.isPointInside(pos)){
                    return pos;
                } else { return self.next(); //TODO make work, dont want recursion  
                }
            }
        };
        pub fn iterator(self: *const @This(), resolution: T) type{
            if(resolution != 1)std.debug.panic("resolutions not fully implemented\n", .{});
            return Iterator{
                .cone = self,
                .iteraton = 0,
                .x_off = 0,
                .y_off = 0,
                .z_off = 0,
                .resolution = resolution,
            };
        }
    };
}

pub fn dot(a: anytype, b: @TypeOf(a)) @typeInfo(@TypeOf(a)).vector.child {
    return @reduce(.Add, a * b);
}
