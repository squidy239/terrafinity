const std = @import("std");
const Csm = @import("Csm.zig");

// A pit in flat ground. Ground surface at Y=0. Pit opening X,Z in [-4,4], floor at Y=-4.
// Build the opaque shell faces and software-rasterize them into a depth map from the light,
// then compute the shadow factor for ground receivers around the pit.

const Vec3f = Csm.Vec3f;

fn cross3d(a: @Vector(3, f64), b: @Vector(3, f64)) @Vector(3, f64) {
    return .{
        a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0],
    };
}
const Vec3d = Csm.Vec3d;

const Quad = struct { a: [3]f32, b: [3]f32, c: [3]f32, d: [3]f32 };

const MAXQ = 4096;
var quads: [MAXQ]Quad = undefined;
var nquads: usize = 0;
fn addQuad(a: [3]f32, b: [3]f32, c: [3]f32, d: [3]f32) void {
    quads[nquads] = .{ .a = a, .b = b, .c = c, .d = d };
    nquads += 1;
}

fn rayTri(origin: Vec3d, dir: Vec3d, v0: Vec3d, v1: Vec3d, v2: Vec3d, best: *f32) bool {
    const e1 = v1 - v0;
    const e2 = v2 - v0;
    const pvec = cross3d(dir, e2);
    const det = Csm.dot3d(e1, pvec);
    if (@abs(det) < 1e-9) return false;
    const inv = 1.0 / det;
    const tvec = origin - v0;
    const u = Csm.dot3d(tvec, pvec) * inv;
    if (u < 0 or u > 1) return false;
    const qvec = cross3d(tvec, e1);
    const v = Csm.dot3d(dir, qvec) * inv;
    if (v < 0 or u + v > 1) return false;
    const t = Csm.dot3d(e2, qvec) * inv;
    if (t < 0) return false;
    if (t < best.*) best.* = @floatCast(t);
    return true;
}

fn rayQuad(origin: Vec3d, dir: Vec3d, q: Quad, out: *f32) bool {
    // Moller-Trumbore against triangles (a,b,c) and (a,c,d). Axis-aligned quads only.
    const a = Vec3d{ q.a[0], q.a[1], q.a[2] };
    const b = Vec3d{ q.b[0], q.b[1], q.b[2] };
    const c = Vec3d{ q.c[0], q.c[1], q.c[2] };
    const d = Vec3d{ q.d[0], q.d[1], q.d[2] };
    var hit = false;
    var best: f32 = std.math.inf(f32);
    const tris = [4][3]Vec3d{ .{ a, b, c }, .{ a, c, d }, .{ c, b, a }, .{ d, c, a } };
    for (tris) |tri| {
        if (rayTri(origin, dir, tri[0], tri[1], tri[2], &best)) hit = true;
    }
    if (hit) out.* = best;
    return hit;
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    // Light: sun at elevation ~45 from +X. sun_dir toward sun; light travels -sun_dir.
    const sun_elev = std.math.degreesToRadians(15.0);
    const sun_dir: Vec3f = .{ @cos(sun_elev), @sin(sun_elev), 0.0 };
    const light_dir = Csm.lightDirFromSunDir(sun_dir);

    // Build the cascade centered just above the pit.
    const view_pos: Vec3d = .{ 0.0, 8.0, 0.0 };
    const cfg = Csm.ShadowConfig{ .cascade_count = 1, .shadow_map_size = 512, .max_shadow_distance = 24 };
    const scene_min: Vec3d = .{ -20, -8, -20 };
    const scene_max: Vec3d = .{ 20, 2, 20 };
    const ctx = Csm.CascadeContext{
        .cfg = cfg,
        .fov_y = std.math.degreesToRadians(70.0),
        .aspect = 1.0,
        .camera_front = .{ 0.0, 0.0, 1.0 },
        .view_pos = view_pos,
        .light_dir = light_dir,
        .scene_min = scene_min,
        .scene_max = scene_max,
        .per_frame_dist = 0.0,
    };
    const cascade = Csm.computeCascade(ctx, 0);
    const committed = Csm.committedOf(cascade);

    // CAVE under solid ground. Ground top at Y=0 everywhere (you walk on it).
    // Cave interior: hollow region Y in [-5,-1], x,z in [-2,2]. Cave floor at Y=-5,
    // roof underside (ceiling) at Y=-1 faces down. Walls vertical.
    const pit = 2.0;
    const floor_y: f32 = -5.0;
    const ceil_y: f32 = -1.0;
    // Ground top: full plane at Y=0 over [-R,R]
    const R: i32 = 8;
    var gx: i32 = -R;
    while (gx < R) : (gx += 1) {
        var gz: i32 = -R;
        while (gz < R) : (gz += 1) {
            addQuad(.{ @floatFromInt(gx), 0.0, @floatFromInt(gz) }, .{ @floatFromInt(gx + 1), 0.0, @floatFromInt(gz) }, .{ @floatFromInt(gx + 1), 0.0, @floatFromInt(gz + 1) }, .{ @floatFromInt(gx), 0.0, @floatFromInt(gz + 1) });
        }
    }
    // Cave floor (faces up) at floor_y
    addQuad(.{ -pit, floor_y, -pit }, .{ pit, floor_y, -pit }, .{ pit, floor_y, pit }, .{ -pit, floor_y, pit });
    // Cave walls (vertical, from floor_y to ceil_y)
    addQuad(.{ pit, floor_y, -pit }, .{ pit, floor_y, pit }, .{ pit, ceil_y, pit }, .{ pit, ceil_y, -pit }); // +X
    addQuad(.{ -pit, floor_y, pit }, .{ -pit, floor_y, -pit }, .{ -pit, ceil_y, -pit }, .{ -pit, ceil_y, pit }); // -X
    addQuad(.{ -pit, floor_y, pit }, .{ pit, floor_y, pit }, .{ pit, ceil_y, pit }, .{ -pit, ceil_y, pit }); // +Z
    addQuad(.{ pit, floor_y, -pit }, .{ -pit, floor_y, -pit }, .{ -pit, ceil_y, -pit }, .{ pit, ceil_y, -pit }); // -Z
    // (roof underside/ceiling at ceil_y is back-facing from the light and culled; omitted.)

    // Rasterize: for each texel, cast ray from light (direction = light travel = light_dir),
    // find nearest depth. The light "eye" is far away; ray origin = -light_dir * big, then
    // ray direction = light_dir (travel). Use plane-aligned origin via matrix inverse is hard;
    // instead cast along light_dir from the texel's plane. Simplest: cast along -light_dir from
    // +inf, keep nearest intersection distance t, depth = dot(hitpoint - center, light_dir).
    const map_size = cfg.shadow_map_size;
    const radius = cascade.radius;
    // Build light basis to map texel (u,v) -> light-space XY -> world.
    const basis = Csm.buildLightBasis(light_dir, Csm.world_up);

    // Precompute per-texel nearest world depth.
    var stored = try alloc.alloc(f32, map_size * map_size);
    defer alloc.free(stored);
    for (stored) |*s| s.* = 1.0;

    for (0..map_size) |ty| {
        for (0..map_size) |tx| {
            // light-space XY in [-1,1]
            const lx = (2.0 * @as(f32, @floatFromInt(tx)) + 1.0) / @as(f32, @floatFromInt(map_size)) - 1.0;
            const ly = (2.0 * @as(f32, @floatFromInt(ty)) + 1.0) / @as(f32, @floatFromInt(map_size)) - 1.0;
            // world point = center + right*lx*radius + up*ly*radius
            const c: Vec3d = cascade.center_abs;
            const wp: Vec3d = c +
                Vec3d{ basis.right[0], basis.right[1], basis.right[2] } * @as(Vec3d, @splat(@as(f64, lx) * radius)) +
                Vec3d{ basis.up[0], basis.up[1], basis.up[2] } * @as(Vec3d, @splat(@as(f64, ly) * radius));
            // Cast ray along light_dir from far away.
            const origin = wp - Vec3d{ light_dir[0], light_dir[1], light_dir[2] } * @as(Vec3d, @splat(10000.0));
            const dir = Vec3d{ light_dir[0], light_dir[1], light_dir[2] };
            var t: f32 = undefined;
            var nearest_world_depth: f64 = 1.0; // depth in [0,1]? we'll store light-axis projection normalized
            for (quads[0..nquads]) |q| {
                if (rayQuad(origin, dir, q, &t)) {
                    const hp = origin + dir * @as(Vec3d, @splat(@as(f64, t)));
                    // light-axis projection relative to near/far
                    const proj = Csm.dot3d(hp - c, Vec3d{ light_dir[0], light_dir[1], light_dir[2] });
                    const nd = (proj - @as(f64, cascade.near_plane)) / @as(f64, cascade.far_plane - cascade.near_plane);
                    if (nd < nearest_world_depth) {
                        nearest_world_depth = nd;
                    }
                }
            }
            stored[ty * map_size + tx] = @floatCast(std.math.clamp(nearest_world_depth, 0.0, 1.0));
        }
    }

    // Now probe ground receivers just outside each rim, compute shader-style shadow.
    var shadowed_count: usize = 0;
    var total: usize = 0;
    const offsets = [_]f32{ 0.02, 0.1, 0.3, 0.6, 1.0 };
    for (offsets) |d| {
        const receivers = [_][3]f32{
            .{ pit + d, 0.0, 0.0 }, // +X ground above
            .{ -pit - d, 0.0, 0.0 }, // -X
            .{ 0.0, 0.0, pit + d }, // +Z
            .{ 0.0, 0.0, -pit - d }, // -Z
        };
        for (receivers) |r| {
            total += 1;
            const rec: Vec3d = .{ r[0], r[1], r[2] };
            // normal-offset bias: outward = +Y, inward = -Y
            const inward: Vec3f = .{ 0, -1, 0 };
            const ndotl = @max(Csm.dot3f(inward, -sun_dir), 0.0);
            const texel = cascade.texel;
            const bias = @min(cfg.normal_bias_scale * texel / @max(ndotl, 0.2), texel * 3.0);
            const p: Vec3d = rec - Vec3d{ 0, -1, 0 } * @as(Vec3d, @splat(@as(f64, bias))); // pos - inward*bias = pos + Y*bias (up)

            // project via matrix
            const m = Csm.viewProjAtOrigin(committed, view_pos);
            const rel = p - view_pos;
            const x: f32 = @floatCast(rel[0]);
            const y: f32 = @floatCast(rel[1]);
            const z: f32 = @floatCast(rel[2]);
            const cx = m[0] * x + m[4] * y + m[8] * z + m[12];
            const cy = m[1] * x + m[5] * y + m[9] * z + m[13];
            const cw = 1.0;
            const ndc_x = cx / cw;
            const ndc_y = cy / cw;
            if (ndc_x < -1 or ndc_x > 1 or ndc_y < -1 or ndc_y > 1) {
                std.debug.print("  receiver ({d:.1},{d:.1},{d:.1}) OUTSIDE box (no shadow, lit)\n", .{ r[0], r[1], r[2] });
                continue;
            }
            const uvx2 = ndc_x * 0.5 + 0.5;
            const uvy2 = ndc_y * 0.5 + 0.5;
            const texel_uv = texel / (2.0 * radius);
            const pcf = 2.0 * texel_uv;
            var sum: f32 = 0.0;
            var taps: usize = 0;
            for ([3]f32{ -1, 0, 1 }) |dx| {
                for ([3]f32{ -1, 0, 1 }) |dy| {
                    const ux = uvx2 + dx * pcf;
                    const uy = uvy2 + dy * pcf;
                    if (ux < 0 or ux > 1 or uy < 0 or uy > 1) continue;
                    const txi2: usize = @intCast(@min(@as(usize, @intFromFloat(ux * @as(f32, @floatFromInt(map_size)))), map_size - 1));
                    const tyi2: usize = @intCast(@min(@as(usize, @intFromFloat(uy * @as(f32, @floatFromInt(map_size)))), map_size - 1));
                    sum += stored[tyi2 * map_size + txi2];
                    taps += 1;
                }
            }
            const stored_depth = if (taps == 0) 1.0 else sum / @as(f32, @floatFromInt(taps));
            const zproj = m[2] * x + m[6] * y + m[10] * z + m[14];
            const rec_depth = zproj;
            const shadowed = rec_depth > stored_depth; // LESS_OR_EQUAL: shadowed iff rec deeper
            std.debug.print("  receiver ({d:.2},{d:.1},{d:.1}): rec_depth={d:.3} stored={d:.3} -> {s}\n", .{ r[0], r[1], r[2], rec_depth, stored_depth, if (shadowed) "SHADOWED" else "lit" });
            if (shadowed) shadowed_count += 1;
        }
    }
    std.debug.print("shadowed/total = {d}/{d}\n", .{ shadowed_count, total });
}
