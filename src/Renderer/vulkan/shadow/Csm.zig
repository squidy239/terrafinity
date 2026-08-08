const std = @import("std");

/// Cascaded shadow map CPU math: split radii, per-slice bounding-sphere fit, light
/// basis, scene-AABB depth range, absolute-space texel snapping, camera-relative
/// matrix emission, origin compensation, and the update schedule. Pure math — no
/// Vulkan types, fully unit-tested.
pub const MAX_CASCADES = 32;
/// Capacity of the schedule table. The default schedule covers four cascades; larger
/// counts fall back to a plain rotation (see `defaultSchedule`).
pub const schedule_capacity = 32;

pub const Vec3f = @Vector(3, f32);
pub const Vec3d = @Vector(3, f64);

pub const world_up: Vec3f = .{ 0.0, 1.0, 0.0 };

/// Engine camera near plane; the PSSM log term degenerates below 1.0 so the plan
/// clamps splits to `max(near, 1.0)`.
pub const engine_near: f32 = 0.01;
pub const clamped_split_near: f32 = 1.0;

pub const ShadowConfig = struct {
    enabled: bool = true,
    cascade_count: u32 = 4,
    shadow_map_size: u32 = 2048,
    depth_format: enum { d16, d32 } = .d16,
    // Covers the coarse LOD band beyond the near terrain so far-away low-detail chunks
    // keep shadows; the far fade hides the map's edge.
    max_shadow_distance: f32 = 4096,
    pssm_lambda: f32 = 0.35,
    use_cascade_override: bool = false,
    cascade_split_override: [MAX_CASCADES]f32 = .{ 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4194304, 8388608, 16777216, 33554432, 67108864, 134217728, 268435456, 536870912, 1073741824, 2147483648, 4294967296, 8589934592, 17179869184, 34359738368, 68719476736 },
    /// Index into the schedule table for each frame: frame_number % period. Cascade 0
    /// (near) refreshes every 2 frames; the rest on a longer rotation.
    schedule: [schedule_capacity]u8 = .{ 0, 1, 0, 2, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    schedule_period: u8 = 6,
    /// When true, every cascade is re-computed and re-rasterized each frame instead of
    /// refreshing one cascade per frame on the schedule. Eliminates the shadow swimming
    /// that the staggered schedule causes when the camera moves, at the cost of rastering
    /// all cascades every frame.
    refresh_all_each_frame: bool = false,
    // A depression's far wall casts a very long shadow at a near-horizontal sun (length
    // ~ depth / tan(elevation)); clamping the elevation up keeps those shadows sane.
    min_sun_elevation_deg: f32 = 15,
    max_depth_range: f32 = 4096,
    min_chunk_texels: f32 = 0,
    // Back-face culling matches the main pass; the voxel shell's outward faces are the
    // occluders, and faces away from the light are already in shadow.
    shadow_cull_mode: enum { none, back } = .back,
    depth_bias_constant: f32 = 2.0,
    depth_bias_slope: f32 = 2.0,
    // Caps the slope-scale bias so steep faces (cavity walls, cliffs) cannot saturate
    // their stored depth and punch holes/peter-pan the shadow at geometry edges.
    depth_bias_clamp: f32 = 4.0,
    normal_bias_scale: f32 = 1.5,
    pcf_radius_texels: f32 = 2.0,
    blend_fraction: f32 = 0.15,
    fade_fraction: f32 = 0.85,
    shadow_strength: f32 = 1.0,
    debug_cascade_colors: bool = false,
};

/// The light looks along `forward` (the direction light travels). `right`/`up` follow
/// the lookAtRH construction (s = f × up, u = s × f).
pub const LightBasis = struct {
    right: Vec3f,
    up: Vec3f,
    forward: Vec3f,
};

pub const SliceSphere = struct {
    /// Center offset along the camera front, in blocks.
    center_offset: f32,
    radius: f32,
};

/// Per-cascade output of `computeCascade`.
pub const Cascade = struct {
    /// Snapped absolute sphere center in world blocks.
    center_abs: Vec3d,
    /// Fitted slice radius plus staleness padding, in blocks.
    radius: f32,
    /// World blocks per shadow texel: 2*radius / map_size.
    texel: f32,
    /// Ortho depth range along `light_dir`, in blocks.
    near_plane: f32,
    far_plane: f32,
    /// Latched light direction (direction light travels).
    light_dir: Vec3f,
    /// Camera-relative light view-projection for the frame this cascade was committed
    /// on, zm row-major data (bitcastable).
    viewproj: [16]f32,
};

/// Everything needed to rebuild a cascade's matrix at any camera origin. Light-space
/// coordinates of a world point are origin-independent, so committing this data and
/// rebuilding the view per frame is exact by construction.
pub const CommittedCascade = struct {
    center_abs: Vec3d,
    radius: f32,
    near_plane: f32,
    far_plane: f32,
    light_dir: Vec3f,
};

pub const CascadeContext = struct {
    cfg: ShadowConfig,
    fov_y: f32,
    aspect: f32,
    camera_front: Vec3f,
    view_pos: Vec3d,
    /// Direction light travels (already latched and elevation-clamped).
    light_dir: Vec3f,
    scene_min: Vec3d,
    scene_max: Vec3d,
    /// Measured camera movement in blocks per frame, used for staleness padding.
    per_frame_dist: f32,
};

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

pub fn sunDayFromSunDir(sun_dir: Vec3f) f32 {
    return smoothstep(-0.1, 0.25, sun_dir[1]);
}

pub fn dot3f(a: Vec3f, b: Vec3f) f32 {
    return @reduce(.Add, a * b);
}

pub fn dot3d(a: Vec3d, b: Vec3d) f64 {
    return @reduce(.Add, a * b);
}

pub fn cross3f(a: Vec3f, b: Vec3f) Vec3f {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

pub fn normalize3f(v: Vec3f) Vec3f {
    return v / @as(Vec3f, @splat(@sqrt(dot3f(v, v))));
}

pub fn normalize3d(v: Vec3d) Vec3d {
    return v / @as(Vec3d, @splat(@sqrt(dot3d(v, v))));
}

/// Sun direction points from the scene toward the sun (matching the sky shader, which
/// draws the disc along it). The shaders' face_normals are inward, so the lighting uses
/// dot(normal, -sun_dir); the shadow view looks along -sun_dir (the direction light
/// travels), which is what `lightDirFromSunDir` returns.
pub fn lightDirFromSunDir(sun_dir: Vec3f) Vec3f {
    return normalize3f(-sun_dir);
}

/// Raises a sun near or below the horizon to `min_elevation_deg`, preserving azimuth.
/// The caller gates all shadow work on `sun_day > 0`; this only stabilizes the basis
/// once the sun is (nominally) up.
pub fn clampSunElevation(sun_dir: Vec3f, min_elevation_deg: f32) Vec3f {
    const min_rad = std.math.degreesToRadians(min_elevation_deg);
    const elevation = std.math.asin(std.math.clamp(sun_dir[1], -1.0, 1.0));
    if (elevation >= min_rad) return normalize3f(sun_dir);

    const horiz = Vec3f{ sun_dir[0], 0.0, sun_dir[2] };
    const horiz_len = @sqrt(dot3f(horiz, horiz));
    if (horiz_len < 1e-6) {
        // Sun straight overhead; any azimuth is degenerate, leave the direction alone.
        return normalize3f(sun_dir);
    }
    const azimuth = horiz / @as(Vec3f, @splat(horiz_len));
    return azimuth * @as(Vec3f, @splat(@cos(min_rad))) + Vec3f{ 0.0, @sin(min_rad), 0.0 };
}

/// Practical split radii from the plan's PSSM formula. The last split equals `far`;
/// entries past `count` are undefined and must not be read. The config is live-editable,
/// so `far`/`count` are sanitized rather than asserted: an absurdly small distance or
/// zero count degrades to a minimal usable set instead of panicking.
pub fn pssmSplits(near: f32, far: f32, count: u32, lambda: f32) [MAX_CASCADES]f32 {
    const safe_count = @max(@min(count, MAX_CASCADES), 1);
    const n = @max(near, clamped_split_near);
    const safe_far = @max(far, n + 1.0);
    var splits: [MAX_CASCADES]f32 = undefined;
    const count_f: f32 = @floatFromInt(safe_count);
    for (0..safe_count) |i| {
        const t: f32 = @floatFromInt(i + 1);
        const uniform_i = n + (safe_far - n) * t / count_f;
        const log_i = n * std.math.pow(f32, safe_far / n, t / count_f);
        splits[i] = lambda * log_i + (1.0 - lambda) * uniform_i;
    }
    return splits;
}

/// Effective per-cascade outer split radii honoring the config override.
pub fn splitRadii(cfg: ShadowConfig) [MAX_CASCADES]f32 {
    const count = @min(cfg.cascade_count, MAX_CASCADES);
    if (cfg.use_cascade_override) {
        var splits = cfg.cascade_split_override;
        var last: f32 = -1.0;
        for (0..count) |i| {
            if (splits[i] <= last) splits[i] = last + 1.0;
            last = splits[i];
        }
        if (splits[count - 1] != cfg.max_shadow_distance) {
            splits[count - 1] = cfg.max_shadow_distance;
        }
        // Live edits can leave the last split at or below the clamped near; force it up
        // so every cascade has a usable (positive) radius.
        if (splits[count - 1] <= clamped_split_near) {
            splits[count - 1] = clamped_split_near + 1.0;
        }
        return splits;
    }
    return pssmSplits(engine_near, cfg.max_shadow_distance, count, cfg.pssm_lambda);
}

/// Circumscribed sphere of the frustum slice [near, far]: center `c` along the view
/// axis with c = (near+far)(1+tx^2+ty^2)/2, radius from the far corners. Rotation
/// invariant (depends only on fov/aspect/splits), so texel snapping stays meaningful.
pub fn fitSliceSphere(fov_y: f32, aspect: f32, near: f32, far: f32) SliceSphere {
    std.debug.assert(far > near and near > 0.0);
    const tan_half_y = @tan(fov_y / 2.0);
    const tan_half_x = aspect * tan_half_y;
    const t2 = tan_half_x * tan_half_x + tan_half_y * tan_half_y;
    const center = (near + far) * (1.0 + t2) / 2.0;
    const radius_sq = t2 * far * far + (far - center) * (far - center);
    return .{ .center_offset = center, .radius = @sqrt(@max(radius_sq, 0.0)) };
}

/// Orthonormal basis with the light looking along `light_dir`, following the lookAtRH
/// construction (s = f × up, u = s × f). Degenerate when light_dir is parallel to world_up.
pub fn buildLightBasis(light_dir: Vec3f, up_ref: Vec3f) LightBasis {
    const f = normalize3f(light_dir);
    const up_choice: Vec3f = if (@abs(dot3f(f, up_ref)) > 0.99)
        .{ 0.0, 0.0, 1.0 }
    else
        up_ref;
    const s = normalize3f(cross3f(f, up_choice));
    const u = normalize3f(cross3f(s, f));
    return .{ .right = s, .up = u, .forward = f };
}

/// Snaps the sphere center so its light-space XY lands on the texel grid, in absolute
/// f64 world coordinates (otherwise the grid would move with the player). Rounding to
/// the nearest texel keeps the offset at most half a texel, so the camera stays close
/// to the box center and fragments near the split boundary are least likely to fall
/// outside their cascade's box.
pub fn snapCenter(center: Vec3d, radius: f32, shadow_map_size: u32, basis: LightBasis) Vec3d {
    std.debug.assert(shadow_map_size > 0);
    const texel: f64 = 2.0 * @as(f64, radius) / @as(f64, shadow_map_size);
    const ls_x = dot3d(center, basis.right);
    const ls_y = dot3d(center, basis.up);
    const snapped_x = @round(ls_x / texel) * texel;
    const snapped_y = @round(ls_y / texel) * texel;
    const right: Vec3d = .{ basis.right[0], basis.right[1], basis.right[2] };
    const up: Vec3d = .{ basis.up[0], basis.up[1], basis.up[2] };
    return center + right * @as(Vec3d, @splat(snapped_x - ls_x)) + up * @as(Vec3d, @splat(snapped_y - ls_y));
}

/// Ortho depth range from the live scene AABB projected on the light axis, extended by
/// the sphere radius so the whole receiver slice is covered. The projection matrix AND
/// the compute cull use this same range: geometry outside it is neither drawn nor
/// rejected as an occluder, so no depth-clamped false occluders can paint the map's
/// edges. The depthClamp on the pipeline only affects the rasterization of geometry
/// whose AABB straddles the range boundary.
pub fn depthRange(scene_min: Vec3d, scene_max: Vec3d, center: Vec3d, light_dir: Vec3f, radius: f32, max_depth_range: f32) struct { near: f32, far: f32 } {
    const l: Vec3d = .{ light_dir[0], light_dir[1], light_dir[2] };
    var z_min: f64 = std.math.inf(f64);
    var z_max: f64 = -std.math.inf(f64);
    inline for ([2]f64{ scene_min[0], scene_max[0] }) |x| {
        inline for ([2]f64{ scene_min[1], scene_max[1] }) |y| {
            inline for ([2]f64{ scene_min[2], scene_max[2] }) |z| {
                const corner: Vec3d = .{ x, y, z };
                const proj = dot3d(corner - center, l);
                z_min = @min(z_min, proj);
                z_max = @max(z_max, proj);
            }
        }
    }
    const r: f64 = radius;
    var near: f64 = @min(z_min, -r);
    var far: f64 = @max(z_max, r);
    // Bound the total depth range for depth precision. The box is camera-centered, so
    // the range must stay centered on the camera (depth 0): centering on the unclamped
    // range's midpoint would push it to wherever the farthest occluder is, leaving the
    // receivers themselves out of range. The range spans at least the box, and at most
    // max_depth_range centered on the camera.
    const half: f64 = @as(f64, max_depth_range) / 2.0;
    if (far - near > 2.0 * half) {
        near = -half;
        far = half;
    }
    return .{ .near = @floatCast(near), .far = @floatCast(far) };
}

/// How many frames a cascade can go without a refresh: `period / occurrences`, rounded
/// up. Unknown cascades fall back to the full period.
pub fn scheduleStaleness(schedule: [schedule_capacity]u8, period: u8, cascade: u32) u32 {
    const period_u = @max(@as(u32, period), 1);
    var occurrences: u32 = 0;
    for (schedule[0..@intCast(@min(@as(u32, period), schedule_capacity))]) |c| {
        if (c == cascade) occurrences += 1;
    }
    if (occurrences == 0) return period_u;
    return (period_u + occurrences - 1) / occurrences;
}

/// Every cascade < `count` must be refreshed by the table, or its map is never written.
pub fn validateSchedule(schedule: [schedule_capacity]u8, period: u8, count: u32) bool {
    if (period == 0 or period > schedule_capacity) return false;
    if (count == 0 or count > MAX_CASCADES) return false;
    for (0..count) |c| {
        var found = false;
        for (schedule[0..period]) |entry| {
            if (entry == c) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// A valid table that refreshes every cascade once per period.
pub fn defaultSchedule(count: u32) [schedule_capacity]u8 {
    var schedule: [schedule_capacity]u8 = @splat(0);
    for (0..@intCast(count)) |i| schedule[i] = @intCast(i);
    return schedule;
}

/// Staleness padding: a cascade's footprint can grow by up to `staleness_frames` frames
/// of camera motion since its last update. `per_frame_dist` is the measured camera
/// movement in blocks per frame (NOT the max fly speed — that would grow the box while
/// standing still and cause texel-swimming flicker).
pub fn stalenessPadding(staleness_frames: u32, per_frame_dist: f32) f32 {
    return @as(f32, @floatFromInt(staleness_frames)) * @max(per_frame_dist, 0.0);
}

/// Emits the camera-relative light view-projection for one cascade, constructed directly
/// in GLSL column-major layout (translation in the 4th column, indices 12-14, bottom row
/// (0,0,0,1)) so w stays 1. This is the AGENTS.md fix: zm's row-major lookAtRH/ortho
/// place the translation in the last column of each row, which a GLSL `M * v` reads as a
/// projective w term when the light eye is off-origin. The light looks along `light_dir`
/// from `center`; the box is [+-radius] in XY with the scene-derived depth range. The
/// eye is placed at `center - view_pos` (f64 subtract) so the result matches
/// `MeshData.relative_position` exactly.
///
/// Vulkan's NDC depth range is [0, 1], so the matrix emits `f·d == near` as 0 and
/// `f·d == far` as 1. This matches the shadow pipeline's LESS_OR_EQUAL compare and
/// clear to 1.0.
fn buildViewProj(
    center: Vec3d,
    light_dir: Vec3f,
    radius: f32,
    near_plane: f32,
    far_plane: f32,
    view_pos: Vec3d,
) [16]f32 {
    const basis = buildLightBasis(light_dir, world_up);
    const s = basis.right;
    const u = basis.up;
    const f = basis.forward;
    const fnf = far_plane - near_plane;
    const t: Vec3f = .{ @floatCast(view_pos[0] - center[0]), @floatCast(view_pos[1] - center[1]), @floatCast(view_pos[2] - center[2]) };
    const s_t = dot3f(s, t);
    const u_t = dot3f(u, t);
    const f_t = dot3f(f, t);
    var m: [16]f32 = undefined;
    m[0] = s[0] / radius;
    m[1] = u[0] / radius;
    m[2] = f[0] / fnf;
    m[3] = 0.0;
    m[4] = s[1] / radius;
    m[5] = u[1] / radius;
    m[6] = f[1] / fnf;
    m[7] = 0.0;
    m[8] = s[2] / radius;
    m[9] = u[2] / radius;
    m[10] = f[2] / fnf;
    m[11] = 0.0;
    m[12] = s_t / radius;
    m[13] = u_t / radius;
    m[14] = (f_t - near_plane) / fnf;
    m[15] = 1.0;
    return m;
}

/// Full per-cascade fit for one frame. Boxes are **concentric on the camera**: cascade i
/// covers the sphere of radius `split_radius[i]` around the camera, so the box is
/// rotation-invariant (no shadow swimming when the player looks around) and covers every
/// direction including behind and below the camera (no leaks through un-covered terrain).
/// The sphere-fit-to-frustum-slice alternative (`fitSliceSphere`) is kept as a utility
/// but is not used: it moves the box with the camera front and leaves regions outside
/// the frustum wedge un-covered.
pub fn computeCascade(ctx: CascadeContext, cascade_index: u32) Cascade {
    const count = @min(ctx.cfg.cascade_count, MAX_CASCADES);
    std.debug.assert(cascade_index < count);
    const splits = splitRadii(ctx.cfg);

    const radius = splits[cascade_index] + stalenessPadding(
        scheduleStaleness(ctx.cfg.schedule, ctx.cfg.schedule_period, cascade_index),
        ctx.per_frame_dist,
    );

    const basis = buildLightBasis(ctx.light_dir, world_up);
    const center_snapped = snapCenter(ctx.view_pos, radius, ctx.cfg.shadow_map_size, basis);
    const range = depthRange(ctx.scene_min, ctx.scene_max, center_snapped, ctx.light_dir, radius, ctx.cfg.max_depth_range);
    const texel = 2.0 * radius / @as(f32, @floatFromInt(ctx.cfg.shadow_map_size));

    return .{
        .center_abs = center_snapped,
        .radius = radius,
        .texel = texel,
        .near_plane = range.near,
        .far_plane = range.far,
        .light_dir = ctx.light_dir,
        .viewproj = buildViewProj(center_snapped, ctx.light_dir, radius, range.near, range.far, ctx.view_pos),
    };
}

/// Rebuilds a committed cascade's view-projection at the current camera origin. A
/// matrix committed on frame N and rebuilt on frame N+1 maps the same world point to
/// the same light-space coordinates, so a shadow map rasterised on frame N samples
/// correctly on frame N+1. This replaces origin-compensation by matrix composition:
/// the eye is placed at `center - view_pos` (f64 subtract), matching
/// `MeshData.relative_position` exactly.
pub fn viewProjAtOrigin(committed: CommittedCascade, view_pos: Vec3d) [16]f32 {
    return buildViewProj(committed.center_abs, committed.light_dir, committed.radius, committed.near_plane, committed.far_plane, view_pos);
}

pub fn committedOf(cascade: Cascade) CommittedCascade {
    return .{
        .center_abs = cascade.center_abs,
        .radius = cascade.radius,
        .near_plane = cascade.near_plane,
        .far_plane = cascade.far_plane,
        .light_dir = cascade.light_dir,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn approxEqF32(a: f32, b: f32, eps: f32) bool {
    return @abs(a - b) <= eps;
}

test "pssmSplits monotonic, endpoints, lambda extremes" {
    const splits = pssmSplits(0.01, 256.0, 3, 0.35);
    try testing.expect(splits[0] < splits[1] and splits[1] < splits[2]);
    try testing.expect(splits[0] >= clamped_split_near);
    try testing.expectApproxEqAbs(splits[2], 256.0, 1e-3);
    // ~58/125/256 at lambda 0.35 per the plan.
    try testing.expectApproxEqAbs(splits[0], 58.0, 2.0);
    try testing.expectApproxEqAbs(splits[1], 125.0, 3.0);

    const uniform = pssmSplits(0.01, 256.0, 3, 0.0);
    try testing.expectApproxEqAbs(uniform[0], 86.0, 1e-3);
    try testing.expectApproxEqAbs(uniform[1], 171.0, 1e-3);

    const log_heavy = pssmSplits(0.01, 256.0, 3, 1.0);
    try testing.expectApproxEqAbs(log_heavy[2], 256.0, 1e-3);
    try testing.expect(log_heavy[0] < uniform[0]);
}

test "splitRadii honours override and forces monotonic" {
    var cfg = ShadowConfig{};
    cfg.max_shadow_distance = 256;
    cfg.cascade_count = 3;
    cfg.use_cascade_override = true;
    cfg.cascade_split_override = .{ 32, 96, 256, 512, 1024, 2048, 4096, 8192, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const splits = splitRadii(cfg);
    try testing.expect(splits[0] == 32.0);
    try testing.expect(splits[1] == 96.0);
    try testing.expect(splits[2] == 256.0);
    try testing.expect(splits[2] == cfg.max_shadow_distance);

    // Non-monotonic override is repaired; last is forced to max_shadow_distance.
    cfg.cascade_split_override = .{ 96, 32, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const repaired = splitRadii(cfg);
    try testing.expect(repaired[0] < repaired[1] and repaired[1] < repaired[2]);
    try testing.expect(repaired[2] == cfg.max_shadow_distance);
}

test "eight cascades are supported beyond the original four" {
    var cfg = ShadowConfig{};
    cfg.max_shadow_distance = 4096;
    cfg.cascade_count = 8;
    cfg.use_cascade_override = true;
    cfg.cascade_split_override = .{ 32, 64, 128, 256, 512, 1024, 2048, 4096, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const splits = splitRadii(cfg);
    for (0..8) |i| {
        try testing.expect(splits[i] > 0.0);
        if (i > 0) try testing.expect(splits[i] > splits[i - 1]);
    }
    try testing.expect(splits[7] == cfg.max_shadow_distance);

    // The PSSM path fills all eight entries too.
    cfg.use_cascade_override = false;
    const pssm = splitRadii(cfg);
    for (0..8) |i| {
        if (i > 0) try testing.expect(pssm[i] > pssm[i - 1]);
    }
    try testing.expect(pssm[7] == cfg.max_shadow_distance);

    // A plain rotation schedule validates for eight cascades.
    try testing.expect(validateSchedule(defaultSchedule(8), 8, 8));
    try testing.expectEqual(@as(u32, 8), scheduleStaleness(defaultSchedule(8), 8, 7));
}

test "fitSliceSphere contains all 8 corners" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const fov = std.math.degreesToRadians(rand.float(f32) * 110.0 + 40.0);
        const aspect = rand.float(f32) * 2.0 + 0.5;
        const near = rand.float(f32) * 50.0 + 0.5;
        const far = near + rand.float(f32) * 400.0 + 10.0;
        const sphere = fitSliceSphere(fov, aspect, near, far);

        const tan_y = @tan(fov / 2.0);
        const tan_x = aspect * tan_y;
        for ([2]f32{ near, far }) |z| {
            for ([2]f32{ -tan_x * z, tan_x * z }) |x| {
                for ([2]f32{ -tan_y * z, tan_y * z }) |y| {
                    // f64 check: the axial formula balances far/near corner distances
                    // exactly in real arithmetic, but f32 rounding at extreme fov/aspect
                    // pushes corners a hair outside the squared radius.
                    const dist_sq: f64 = @as(f64, x) * x + @as(f64, y) * y + (@as(f64, z) - sphere.center_offset) * (@as(f64, z) - sphere.center_offset);
                    const r_sq: f64 = sphere.radius * sphere.radius;
                    try testing.expect(dist_sq <= r_sq * (1.0 + 1e-5) + 1.0);
                }
            }
        }
        try testing.expect(sphere.radius > 0.0);
    }
}

test "buildLightBasis degeneracy and orthonormality" {
    // Vertical light (parallel to world_up) must still produce a finite basis via the
    // {0,0,1} fallback up.
    const vertical = buildLightBasis(.{ 0.0, 1.0, 0.0 }, world_up);
    try testing.expect(std.math.isFinite(vertical.right[0]) and std.math.isFinite(vertical.up[2]));
    try testing.expect(vertical.right[2] == 0.0);

    // Anti-parallel (straight down) likewise.
    const down = buildLightBasis(.{ 0.0, -1.0, 0.0 }, world_up);
    try testing.expect(std.math.isFinite(down.right[0]));

    // Orthonormal + right-handed view (x×y == -forward).
    const oblique = buildLightBasis(normalize3f(.{ 0.5, 0.3, 0.8 }), world_up);
    try testing.expectApproxEqAbs(1.0, @sqrt(dot3f(oblique.right, oblique.right)), 1e-5);
    try testing.expectApproxEqAbs(0.0, dot3f(oblique.right, oblique.up), 1e-5);
    try testing.expectApproxEqAbs(0.0, dot3f(oblique.up, oblique.forward), 1e-5);
    try testing.expectApproxEqAbs(1.0, @sqrt(dot3f(oblique.forward, oblique.forward)), 1e-5);
    const handedness = dot3f(cross3f(oblique.right, oblique.up), -oblique.forward);
    try testing.expect(handedness > 0.99);
}

test "sign: surface with N=+Y at noon is lit" {
    const sun_dir: Vec3f = .{ 0.0, 1.0, 0.0 }; // noon, toward the sun
    const light_dir = lightDirFromSunDir(sun_dir);
    try testing.expectApproxEqAbs(0.0, light_dir[0], 1e-6);
    try testing.expectApproxEqAbs(-1.0, light_dir[1], 1e-6);
    // The shader's face_normals are the inward (geometric) normals of the cube winding:
    // a TOP face has inward normal -Y. Lighting uses dot(normal, -sun_dir), which for
    // the top face at noon is dot((-Y), (-Y)) = +1 -> lit. The inward top normal also
    // aligns with the direction the light travels (-sun_dir, down).
    const inward_top_normal: Vec3f = .{ 0.0, -1.0, 0.0 };
    try testing.expect(dot3f(inward_top_normal, -sun_dir) > 0.9);
    try testing.expect(dot3f(inward_top_normal, light_dir) > 0.9);
}

test "clampSunElevation engages near the horizon and leaves high sun alone" {
    const low = clampSunElevation(normalize3f(.{ 1.0, 0.03, 0.0 }), 4.0);
    try testing.expect(low[1] >= @sin(std.math.degreesToRadians(4.0)) - 1e-5);
    try testing.expect(low[0] > 0.0); // azimuth preserved

    const high = clampSunElevation(normalize3f(.{ 0.2, 0.9, 0.3 }), 4.0);
    try testing.expectApproxEqAbs(high[1], 0.9 / @sqrt(0.04 + 0.81 + 0.09), 1e-4);

    // Below horizon is still clamped to a usable basis; gating is the caller's job.
    const below = clampSunElevation(normalize3f(.{ 0.0, -0.5, 0.8 }), 4.0);
    try testing.expect(below[1] >= @sin(std.math.degreesToRadians(4.0)) - 1e-5);
}

/// The [16]f32 view-projection data is emitted for GLSL, which stores mat4
/// column-major (M[i][j] = flat[j*4+i]) and multiplies column vectors: out = M * v.
fn mulVec(m: [16]f32, v: [4]f32) [4]f32 {
    var out: [4]f32 = @splat(0.0);
    for (0..4) |i| {
        inline for (0..4) |j| out[i] += m[j * 4 + i] * v[j];
    }
    return out;
}

fn worldVec(w: Vec3d) [4]f32 {
    return .{ @floatCast(w[0]), @floatCast(w[1]), @floatCast(w[2]), 1.0 };
}

test "snapping stability under camera rotation" {
    const sun_dir: Vec3f = normalize3f(.{ 0.3, 0.8, 0.2 });
    const light_dir = lightDirFromSunDir(sun_dir);
    const basis = buildLightBasis(light_dir, world_up);

    const cfg = ShadowConfig{ .cascade_count = 3, .shadow_map_size = 2048 };
    const view_pos: Vec3d = .{ 1234.5, 987.6, 42.0 };
    const scene_min: Vec3d = .{ 1000.0, 800.0, -50.0 };
    const scene_max: Vec3d = .{ 1500.0, 1200.0, 500.0 };

    var prev_radius: f32 = -1.0;
    var prev_texel: f32 = -1.0;
    var angle: f32 = 0.0;
    while (angle < 1.0) : (angle += 0.1) {
        const pitch = std.math.degreesToRadians(angle);
        const front = normalize3f(.{ @sin(pitch), 0.4, @cos(pitch) });
        const cascade = computeCascade(.{
            .cfg = cfg,
            .fov_y = std.math.degreesToRadians(70.0),
            .aspect = 1.6,
            .camera_front = front,
            .view_pos = view_pos,
            .light_dir = light_dir,
            .scene_min = scene_min,
            .scene_max = scene_max,
            .per_frame_dist = 10.0 / 60.0,
        }, 0);

        if (prev_radius >= 0.0) {
            try testing.expectEqual(prev_radius, cascade.radius);
            try testing.expectEqual(prev_texel, cascade.texel);
        }
        prev_radius = cascade.radius;
        prev_texel = cascade.texel;

        // The snapped center's light-space XY is an exact texel multiple.
        const ls_x = dot3d(cascade.center_abs, basis.right);
        const ls_y = dot3d(cascade.center_abs, basis.up);
        const t: f64 = cascade.texel;
        try testing.expectApproxEqAbs(ls_x / t, @round(ls_x / t), 1e-4);
        try testing.expectApproxEqAbs(ls_y / t, @round(ls_y / t), 1e-4);
    }
}

test "depth range covers scene and clamps at max_depth_range" {
    const light_dir = lightDirFromSunDir(normalize3f(.{ 0.2, 0.9, 0.1 }));
    const center: Vec3d = .{ 0.0, 0.0, 0.0 };
    const scene_min: Vec3d = .{ -300.0, -200.0, -100.0 };
    const scene_max: Vec3d = .{ 300.0, 200.0, 100.0 };

    const range = depthRange(scene_min, scene_max, center, light_dir, 64.0, 4096.0);
    // Every scene corner projects inside [near, far].
    const l: Vec3d = .{ light_dir[0], light_dir[1], light_dir[2] };
    inline for ([2]f64{ scene_min[0], scene_max[0] }) |x| {
        inline for ([2]f64{ scene_min[1], scene_max[1] }) |y| {
            inline for ([2]f64{ scene_min[2], scene_max[2] }) |z| {
                const proj = dot3d(Vec3d{ x, y, z } - center, l);
                try testing.expect(proj >= @as(f64, range.near) - 1e-3);
                try testing.expect(proj <= @as(f64, range.far) + 1e-3);
            }
        }
    }

    // At low elevation the AABB spans a long light axis, forcing the clamp.
    const flat_light = lightDirFromSunDir(normalize3f(.{ 0.5, 0.07, 0.1 }));
    const clamped = depthRange(scene_min, scene_max, center, flat_light, 64.0, 100.0);
    try testing.expectApproxEqAbs(clamped.far - clamped.near, 100.0, 1e-3);
}

test "depth range maps near/far to Vulkan depth" {
    const sun_dir: Vec3f = normalize3f(.{ 0.3, 0.8, 0.2 });
    const light_dir = lightDirFromSunDir(sun_dir);
    const cfg = ShadowConfig{ .cascade_count = 4, .shadow_map_size = 2048 };
    const view_pos: Vec3d = .{ 1234.5, 987.6, 42.0 };
    const scene_min: Vec3d = .{ 1000.0, 800.0, -50.0 };
    const scene_max: Vec3d = .{ 1500.0, 1200.0, 500.0 };
    const ctx = CascadeContext{
        .cfg = cfg,
        .fov_y = std.math.degreesToRadians(70.0),
        .aspect = 1.6,
        .camera_front = normalize3f(.{ 0.1, 0.3, 0.9 }),
        .view_pos = view_pos,
        .light_dir = light_dir,
        .scene_min = scene_min,
        .scene_max = scene_max,
        .per_frame_dist = 10.0 / 60.0,
    };
    const cascade = computeCascade(ctx, 1);
    const f: Vec3d = .{ light_dir[0], light_dir[1], light_dir[2] };

    // World points on the cascade's near/far planes (light-space depth f·(p-center)
    // equals near/far exactly), projected through the committed matrix.
    const near_world = cascade.center_abs + f * @as(Vec3d, @splat(cascade.near_plane));
    const far_world = cascade.center_abs + f * @as(Vec3d, @splat(cascade.far_plane));
    const near_clip = mulVec(cascade.viewproj, worldVec(near_world - view_pos));
    const far_clip = mulVec(cascade.viewproj, worldVec(far_world - view_pos));

    // Vulkan NDC depth is [0, 1], matching the shadow pass's clear and LESS_OR_EQUAL
    // compare. A receiver is shadowed exactly when its projected depth exceeds the
    // stored occluder.
    try testing.expectApproxEqAbs(near_clip[2], 0.0, 1e-4);
    try testing.expectApproxEqAbs(far_clip[2], 1.0, 1e-4);
    // w stays 1 because this is an affine orthographic matrix.
    try testing.expectApproxEqAbs(near_clip[3], 1.0, 1e-5);
    try testing.expectApproxEqAbs(far_clip[3], 1.0, 1e-5);
}

test "rebuilt matrix at a new origin reproduces the committed one" {
    const sun_dir: Vec3f = normalize3f(.{ 0.3, 0.8, 0.2 });
    const light_dir = lightDirFromSunDir(sun_dir);
    const cfg = ShadowConfig{ .cascade_count = 3, .shadow_map_size = 2048 };
    const scene_min: Vec3d = .{ -300.0, -200.0, -100.0 };
    const scene_max: Vec3d = .{ 300.0, 200.0, 100.0 };

    const origin_a: Vec3d = .{ 1000.0, 0.0, 1000.0 };
    const origin_b: Vec3d = .{ 1012.5, -3.25, 1008.75 };
    const front = normalize3f(.{ 0.1, 0.3, 0.9 });

    const ctx = CascadeContext{
        .cfg = cfg,
        .fov_y = std.math.degreesToRadians(70.0),
        .aspect = 1.6,
        .camera_front = front,
        .view_pos = origin_a,
        .light_dir = light_dir,
        .scene_min = scene_min,
        .scene_max = scene_max,
        .per_frame_dist = 10.0 / 60.0,
    };
    const cascade_a = computeCascade(ctx, 1);

    // Rebuilding the committed cascade at a new origin must map the same world point
    // to the same clip coordinates the committed matrix produced.
    const world_pt: Vec3d = .{ 1050.0, 150.0, 950.0 };
    const clip_committed = mulVec(cascade_a.viewproj, worldVec(world_pt - origin_a));
    const rebuilt = viewProjAtOrigin(committedOf(cascade_a), origin_b);
    const clip_rebuilt = mulVec(rebuilt, worldVec(world_pt - origin_b));
    for (0..4) |i| {
        try testing.expectApproxEqAbs(clip_committed[i], clip_rebuilt[i], 1e-3);
    }
}

test "splitRadii handles degenerate live-edited config without panicking" {
    // max_shadow_distance at or below the clamped near (1.0) must degrade to a usable
    // minimal radius rather than asserting.
    var cfg = ShadowConfig{};
    cfg.max_shadow_distance = 0.0;
    const splits = splitRadii(cfg);
    try testing.expect(splits[0] > clamped_split_near);
    try testing.expect(splits[3] > splits[2] and splits[2] > splits[1]);

    cfg.max_shadow_distance = 1.0;
    const splits_one = splitRadii(cfg);
    try testing.expect(splits_one[3] > clamped_split_near);

    // Zero cascade_count also degrades instead of indexing out of bounds.
    cfg.cascade_count = 0;
    cfg.use_cascade_override = false;
    const splits_zero = splitRadii(cfg);
    try testing.expect(splits_zero[0] > 0.0);

    // Override path forces the last split above the near even if the distance is tiny.
    cfg.cascade_count = 3;
    cfg.use_cascade_override = true;
    cfg.max_shadow_distance = 0.5;
    cfg.cascade_split_override = .{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 3.0, 3.1, 3.2 };
    const splits_ov = splitRadii(cfg);
    try testing.expect(splits_ov[2] > clamped_split_near);
}

test "schedule validator and staleness" {
    const schedule: [schedule_capacity]u8 = .{ 0, 1, 0, 2, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expect(validateSchedule(schedule, 6, 4));
    try testing.expect(validateSchedule(schedule, 6, 3));
    try testing.expect(!validateSchedule(schedule, 6, 5)); // cascade 4 never refreshed
    try testing.expect(!validateSchedule(schedule, 0, 3));
    try testing.expect(validateSchedule(.{ 0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 4, 4));
    try testing.expect(validateSchedule(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 1, 1)); // period-1 all-cascades

    try testing.expectEqual(@as(u32, 2), scheduleStaleness(schedule, 6, 0));
    try testing.expectEqual(@as(u32, 6), scheduleStaleness(schedule, 6, 1));
    try testing.expectEqual(@as(u32, 6), scheduleStaleness(schedule, 6, 2));
    try testing.expectEqual(@as(u32, 6), scheduleStaleness(schedule, 6, 3));
    try testing.expectEqual(@as(u32, 6), scheduleStaleness(schedule, 6, 4));
}

test "staleness padding monotonic in movement, zero at zero" {
    try testing.expectEqual(@as(f32, 0.0), stalenessPadding(4, 0.0));
    try testing.expect(stalenessPadding(4, 0.5) < stalenessPadding(4, 1.0));
    try testing.expect(stalenessPadding(4, 1.0) > stalenessPadding(2, 1.0));
}

test "sunDayFromSunDir mirrors the shader gate" {
    try testing.expect(sunDayFromSunDir(.{ 0.0, 1.0, 0.0 }) == 1.0);
    try testing.expect(sunDayFromSunDir(.{ 0.0, -1.0, 0.0 }) == 0.0);
    try testing.expect(sunDayFromSunDir(.{ 0.0, 0.0, 1.0 }) > 0.0 and sunDayFromSunDir(.{ 0.0, 0.0, 1.0 }) < 1.0);
}
