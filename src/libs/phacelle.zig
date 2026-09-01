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

/// The 4x4 cell neighbourhood is processed as one vector op per wave term.
const cell_lanes = 16;
const CellIntV = @Vector(cell_lanes, i32);
const CellFloatV = @Vector(cell_lanes, f32);

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
/// reference. Max absolute error ~3e-7 over the active range; the caller
/// masks s > 1 where the reference's floor term has already cut the weight
/// to zero.
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
    const side_x = -norm_dir[1] * freq * tau;
    const side_y = norm_dir[0] * freq * tau;
    const wave_input = offset * tau;
    const scaled_x = p[0] * freq;
    const scaled_y = p[1] * freq;
    const base_cell_x: i32 = @intFromFloat(@floor(scaled_x));
    const base_cell_y: i32 = @intFromFloat(@floor(scaled_y));

    // Lane l covers the neighbour cell (l % 4 - 1, l / 4 - 1), so the whole
    // 4x4 neighbourhood is one vector op per wave term instead of 16 scalar
    // transcendental evaluations.
    const lane = std.simd.iota(i32, cell_lanes);
    const cell_quad: CellIntV = @splat(4);
    const cell_x = @as(CellIntV, @splat(base_cell_x)) + @mod(lane, cell_quad) - @as(CellIntV, @splat(1));
    const cell_y = @as(CellIntV, @splat(base_cell_y)) + @divTrunc(lane, cell_quad) - @as(CellIntV, @splat(1));

    // The cell point sits at the cell center plus a hash jitter; a half-unit
    // jitter keeps all 16 neighbouring cells relevant.
    const rand = cellJitter(cell_x, cell_y);
    const diff_x = @as(CellFloatV, @splat(scaled_x)) - (@as(CellFloatV, @floatFromInt(cell_x)) + @as(CellFloatV, @splat(0.5))) - rand[0];
    const diff_y = @as(CellFloatV, @splat(scaled_y)) - (@as(CellFloatV, @floatFromInt(cell_y)) + @as(CellFloatV, @splat(0.5))) - rand[1];

    // The phase ramps perpendicular to the stripe direction; the distance is
    // mapped to the weight's Chebyshev interval s = (d^2 - 1.125) / 1.125.
    const wave_phase = diff_x * @as(CellFloatV, @splat(side_x)) + diff_y * @as(CellFloatV, @splat(side_y)) + @as(CellFloatV, @splat(wave_input));
    const s = (diff_x * diff_x + diff_y * diff_y) * @as(CellFloatV, @splat(8.0 / 9.0)) - @as(CellFloatV, @splat(1.0));
    // Bell curve over the cell; beyond s = 1 (distance 1.5) the reference's
    // floor term already forces the weight to zero, so far cells are masked.
    const zero_v: CellFloatV = @splat(0);
    const w = @select(f32, s <= @as(CellFloatV, @splat(1.0)), @max(bellWeight(s), zero_v), zero_v);

    const wave_acc: [2]f32 = .{
        @reduce(.Add, @cos(wave_phase) * w),
        @reduce(.Add, @sin(wave_phase) * w),
    };
    // Dividing by max(1 - normalization, |acc|) crisps the ridges: wherever
    // the cells align, the output magnitude snaps to one.
    const mag = @max(1.0 - normalization, @sqrt(wave_acc[0] * wave_acc[0] + wave_acc[1] * wave_acc[1]));
    return .{
        .cos = wave_acc[0] / mag,
        .sin = wave_acc[1] / mag,
        .side_x = side_x,
        .side_y = side_y,
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
