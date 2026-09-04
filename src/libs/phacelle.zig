// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Phacelle noise by Rune Skovbo Johansen (https://www.runevision.com),
// ported to Zig from the GLSL used in the "Fast and Gorgeous Erosion
// Filter" example (Shadertoy wXcfWn, © 2025 Rune Skovbo Johansen).
// The cell jitter hash is replaced with the integer hash from
// fastnoise.zig (MIT) so the pattern stays exact far from the origin.
// The 4x4 cell loop is vectorized, and the exp bell weight is replaced
// with a deterministic polynomial (bellWeight).

const std = @import("std");
const fastnoise = @import("fastnoise");

/// The cosine and sine waves of the Phacelle pattern, plus the side
/// direction scaled by the cell frequency. The sine is the analytical
/// derivative of the cosine wave; `.side` is that derivative's direction
/// and magnitude with respect to the scaled input coordinates.
pub const Phacelle = struct {
    cos: f32,
    sin: f32,
    side_x: f32,
    side_y: f32,
};

/// Salt for the cell jitter hash; fixed so the erosion pattern is stable
/// across the whole world.
const jitter_salt: i32 = 0x51AB3A9D;

/// The neighbourhood spans 4x4 cells; the wave from all 16 blends into one
/// vector op per wave term instead of 16 scalar transcendental evaluations.
const cell_span = 4;
const cell_lanes = cell_span * cell_span;
const CellIntV = @Vector(cell_lanes, i32);
const CellFloatV = @Vector(cell_lanes, f32);

/// Maps squared cell distance into the bell weight's Chebyshev interval, and
/// the cutoff beyond which the reference's floor term already forces the
/// weight to zero (distance 1.5).
const weight_scale = 8.0 / 9.0;
const weight_cutoff = 1.0;

/// Jitter offset for a cell block, in [-0.5, 0.5] per axis, derived from the
/// low and high 16 bits of each cell hash.
fn cellJitter(cell_x: CellIntV, cell_y: CellIntV) [2]CellFloatV {
    const h = fastnoise.hash2DVec(cell_lanes, jitter_salt, cell_x, cell_y);
    const bits: @Vector(cell_lanes, u32) = @bitCast(h);
    const mask: @Vector(cell_lanes, u32) = @splat(0xFFFF);
    const shift: @Vector(cell_lanes, u5) = @splat(16);
    const c65535: CellFloatV = @splat(65535.0);
    const c2: CellFloatV = @splat(2.0);
    const c1: CellFloatV = @splat(1.0);
    const c_half: CellFloatV = @splat(0.5);
    const u = @as(CellFloatV, @floatFromInt(bits & mask)) / c65535;
    const v = @as(CellFloatV, @floatFromInt(bits >> shift)) / c65535;
    return .{ (u * c2 - c1) * c_half, (v * c2 - c1) * c_half };
}

/// Chebyshev coefficients (highest degree first) of the cell weight
/// exp(-2t) - 0.01111 over t in [0, 2.25], evaluated at s = t * 8/9 - 1.
const bell_coeffs: [11]f32 = .{
    0.000000212,
    -0.000001902,
    0.000015425,
    -0.000111589,
    0.000709754,
    -0.003896942,
    0.018029496,
    -0.068001814,
    0.199367670,
    -0.422433230,
    0.276321950,
};

/// Bell-curve weight over the squared cell distance, evaluated by Clenshaw's
/// recurrence in Chebyshev form: a dozen FMAs replace the vector exp of the
/// reference (~3e-7 max error). The caller masks s > 1 where the reference's
/// floor term has already cut the weight to zero.
fn bellWeight(s: CellFloatV) CellFloatV {
    const two_s: CellFloatV = @as(CellFloatV, @splat(2.0)) * s;
    var b_2: CellFloatV = @splat(0);
    var b_1: CellFloatV = @splat(0);
    for (bell_coeffs) |a_k| {
        const b_k = @mulAdd(CellFloatV, two_s, b_1, @as(CellFloatV, @splat(a_k)) - b_2);
        b_2 = b_1;
        b_1 = b_k;
    }
    return b_1 - s * b_2;
}

/// Stripe pattern aligned with `norm_dir`, blended across a 4x4 neighbourhood
/// of jittered cells. Each cell contributes a wave whose phase ramps
/// perpendicular to `norm_dir`; blending the cells keeps the pattern a
/// continuous wave even where neighbouring phases disagree. Returns the
/// cosine and sine waves and the side direction in cell-scaled units.
pub fn phacelleNoise(p: [2]f32, norm_dir: [2]f32, freq: f32, offset: f32, normalization: f32) Phacelle {
    const tau = std.math.tau;
    // Orthogonal to the stripe direction; the magnitude carries the cell
    // scale and the wave count per unit.
    const side: [2]f32 = .{ -norm_dir[1] * freq * tau, norm_dir[0] * freq * tau };
    const scaled: [2]f32 = .{ p[0] * freq, p[1] * freq };
    const base: [2]i32 = .{ @intFromFloat(@floor(scaled[0])), @intFromFloat(@floor(scaled[1])) };
    const acc = blendWaves(cellDiffs(scaled, base), side, offset * tau);
    // Dividing by max(1 - normalization, |acc|) crisps the ridges: wherever
    // the cells align, the output magnitude snaps to one.
    const mag = @max(1.0 - normalization, @sqrt(acc[0] * acc[0] + acc[1] * acc[1]));
    return .{
        .cos = acc[0] / mag,
        .sin = acc[1] / mag,
        .side_x = side[0],
        .side_y = side[1],
    };
}

/// Offset of the sample from each neighbouring cell center, including the
/// hash jitter. Lane l covers the neighbour cell (l % 4 - 1, l / 4 - 1).
fn cellDiffs(scaled: [2]f32, base: [2]i32) [2]CellFloatV {
    const lane = std.simd.iota(i32, cell_lanes);
    const span: CellIntV = @splat(cell_span);
    const one: CellIntV = @splat(1);
    const cell_x = @as(CellIntV, @splat(base[0])) + @mod(lane, span) - one;
    const cell_y = @as(CellIntV, @splat(base[1])) + @divTrunc(lane, span) - one;
    // The cell point sits at the cell center plus a hash jitter; a half-unit
    // jitter keeps all 16 neighbouring cells relevant.
    const rand = cellJitter(cell_x, cell_y);
    const half: CellFloatV = @splat(0.5);
    return .{
        @as(CellFloatV, @splat(scaled[0])) - (@as(CellFloatV, @floatFromInt(cell_x)) + half) - rand[0],
        @as(CellFloatV, @splat(scaled[1])) - (@as(CellFloatV, @floatFromInt(cell_y)) + half) - rand[1],
    };
}

/// Cosine/sine accumulations of the cell waves, bell-weighted by distance.
fn blendWaves(diff: [2]CellFloatV, side: [2]f32, wave_input: f32) [2]f32 {
    // The phase ramps perpendicular to the stripe direction; the distance is
    // mapped to the weight's Chebyshev interval.
    const phase = diff[0] * @as(CellFloatV, @splat(side[0])) + diff[1] * @as(CellFloatV, @splat(side[1])) + @as(CellFloatV, @splat(wave_input));
    const s = (diff[0] * diff[0] + diff[1] * diff[1]) * @as(CellFloatV, @splat(weight_scale)) - @as(CellFloatV, @splat(1.0));
    const zero: CellFloatV = @splat(0);
    const w = @select(f32, s <= @as(CellFloatV, @splat(weight_cutoff)), @max(bellWeight(s), zero), zero);
    return .{
        @reduce(.Add, @cos(phase) * w),
        @reduce(.Add, @sin(phase) * w),
    };
}

test "phacelle stripes align with the input direction" {
    // With a constant input direction the pattern varies across the stripes
    // and stays almost constant along them, with unit magnitude in cell
    // interiors after normalization.
    var along_var_sum: f32 = 0;
    var across_var_sum: f32 = 0;
    var mag_sum: f32 = 0;
    var samples: usize = 0;
    const count = 16;
    for (0..count) |ix| {
        for (0..count) |iy| {
            const p = [2]f32{ @as(f32, @floatFromInt(ix)) * 0.25, @as(f32, @floatFromInt(iy)) * 0.25 };
            const r = phacelleNoise(p, .{ 1.0, 0.0 }, 1.0, 0.25, 0.5);
            mag_sum += @sqrt(r.cos * r.cos + r.sin * r.sin);
            samples += 1;
            if (ix + 1 < count and iy + 1 < count) {
                const east = phacelleNoise(.{ p[0] + 0.25, p[1] }, .{ 1.0, 0.0 }, 1.0, 0.25, 0.5);
                const north = phacelleNoise(.{ p[0], p[1] + 0.25 }, .{ 1.0, 0.0 }, 1.0, 0.25, 0.5);
                const d_along = r.cos - east.cos;
                const d_across = r.cos - north.cos;
                along_var_sum += d_along * d_along;
                across_var_sum += d_across * d_across;
            }
        }
    }
    const mean_mag = mag_sum / @as(f32, @floatFromInt(samples));
    try std.testing.expect(mean_mag > 0.7);
    // The division by max(1 - normalization, |acc|) caps the magnitude at one.
    try std.testing.expect(mean_mag <= 1.001);
    // Across-stripe variation dominates along-stripe variation.
    try std.testing.expect(across_var_sum > 2.0 * along_var_sum);
}

test "phacelle is deterministic and translation-stable at cell scale" {
    // The same input always yields the same output, and shifting by a whole
    // number of cells keeps the pattern identical up to the jittered cells.
    const a = phacelleNoise(.{ 1.3, -2.7 }, .{ 0.0, 1.0 }, 1.0, 0.25, 0.5);
    const b = phacelleNoise(.{ 1.3, -2.7 }, .{ 0.0, 1.0 }, 1.0, 0.25, 0.5);
    try std.testing.expectEqual(a.cos, b.cos);
    try std.testing.expectEqual(a.sin, b.sin);
}

test "bell weight matches its exp reference" {
    // The polynomial replaces the reference's exp; pin it to within 1e-5
    // absolute so a coefficient typo cannot silently reshape the pattern.
    const zero_v: CellFloatV = @splat(0);
    const one_v: CellFloatV = @splat(1.0);
    for (0..64) |i| {
        const d2: f32 = 2.25 * @as(f32, @floatFromInt(i)) / 64.0;
        const s = @as(CellFloatV, @splat(d2 * (8.0 / 9.0) - 1.0));
        const got_v = @select(f32, s <= one_v, @max(bellWeight(s), zero_v), zero_v);
        const got = got_v[0];
        const expected = @max(0.0, @exp(-2.0 * d2) - 0.01111);
        try std.testing.expect(@abs(got - expected) < 1e-5);
    }
    // Beyond distance 1.5 the weight is masked to zero.
    const far_v = @select(f32, @as(CellFloatV, @splat(1.5)) <= one_v, @max(bellWeight(@as(CellFloatV, @splat(1.5))), zero_v), zero_v);
    try std.testing.expect(far_v[0] == 0.0);
}
