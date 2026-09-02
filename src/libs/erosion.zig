// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Erosion filter by Rune Skovbo Johansen (https://www.runevision.com),
// ported to Zig from the GLSL of the "Fast and Gorgeous Erosion Filter"
// example (Shadertoy wXcfWn, © 2025 Rune Skovbo Johansen). The filter
// steers Phacelle noise stripes down the slope of a height field, stacking
// octaves so tributaries branch off the accumulated gradient.

const std = @import("std");
const phacelle = @import("phacelle.zig");

pub const ErosionParams = struct {
    /// Total magnitude applied across all octaves.
    filter_strength: f32 = 0.22,
    /// Gully magnitude relative to the peak-sharpening effect of the mask.
    gully_weight: f32 = 0.5,
    /// Exponent controlling how strongly coarse octaves restrict fine ones;
    /// lower values hide fine gullies except on the steepest slopes.
    detail: f32 = 1.5,
    /// Number of gully octaves.
    octaves: u32 = 4,
    /// Frequency step between octaves.
    lacunarity: f32 = 2.0,
    /// Amplitude step between octaves.
    gain: f32 = 0.5,
    /// Cell size relative to the stripe width.
    cell_scale: f32 = 0.7,
    /// Ridge crispness; 1.0 can create loop artefacts where ridges meet.
    normalization: f32 = 0.5,
    /// Fade-in width of the mask on ridge crests.
    ridge_rounding: f32 = 0.1,
    /// Fade-in width of the mask in creases; 0 cuts in instantly.
    crease_rounding: f32 = 0.0,
    /// Slope magnitude substituted for the terrain gradient.
    assumed_slope: f32 = 0.7,
    /// How much of the gradient magnitude `assumed_slope` replaces.
    assumed_slope_amount: f32 = 1.0,
    /// Terrain slope magnitude at which the gullies run at their full
    /// frequency; flatter terrain's stripes widen and the pattern collapses
    /// to its constant cell value. Zero disables the modulation.
    fade_slope: f32 = 0.001,
    /// Deprecated: kept so saved configs that set the old altitude fade
    /// target still parse. Skipped in the config tree.
    fade_altitude: f32 = 0.5,
};

pub const ErosionResult = struct {
    /// Height change in normalized height units.
    height_delta: f32,
    slope_dx: f32,
    slope_dy: f32,
    /// Total strength summed over the octaves.
    magnitude: f32,
    /// −1 in creases and +1 on ridges where the filter is active; currently
    /// informational only, no terrain feature consumes it yet.
    ridge_map: f32,
};

/// Applies the erosion filter at position `p`. `height_and_slope` carries the
/// height in normalized units and the downhill slope. `fade_steepness` is the
/// locally averaged terrain slope magnitude used for peak and valley
/// preservation: the pattern's contribution fades out smoothly on flat
/// ground (an inverted-quadratic mask in the steepness), so a summit or a
/// stream bed is never carved by a gully crossing it. The per-octave loop
/// order is load-bearing: each octave steers off the slope accumulated by the
/// previous one.
pub fn erosionFilter(p: [2]f32, height_and_slope: [3]f32, fade_steepness: f32, params: ErosionParams) ErosionResult {
    // Fade-in widths of the mask per octave, in normalized slope units.
    const onset_octave: f32 = 1.0;
    const onset_ridge: f32 = 2.0;
    // Per-octave decay of the rounding multiplier.
    const rounding_decay: f32 = 0.5;

    var freq: f32 = 1.0;
    var strength = params.filter_strength;
    var rounding_mult: f32 = 1.0;

    // The terrain gradient seeds the gully direction; its magnitude is
    // replaced by the assumed slope so extreme gradients do not over-feed
    // the mask. Only the direction survives into the first octave.
    const slope_mag = @sqrt(height_and_slope[1] * height_and_slope[1] + height_and_slope[2] * height_and_slope[2]);
    const slope_dir = safeNormalize(.{ height_and_slope[1], height_and_slope[2] });
    // Below the finite-difference noise floor the gradient direction is
    // float noise (and differs between build modes), so blend toward the
    // assumed-slope direction there; flat areas stay deterministic.
    const gradient_floor: f32 = 1e-4;
    const assumed_x = params.assumed_slope;
    const assumed_len = @sqrt(assumed_x * assumed_x + 1.0);
    const assumed_dir: [2]f32 = .{ assumed_x / assumed_len, 1.0 / assumed_len };
    const blend = std.math.clamp(gradient_floor / @max(slope_mag, 1e-20), 0.0, 1.0);
    const dir: [2]f32 = .{
        std.math.lerp(slope_dir[0], assumed_dir[0], blend),
        std.math.lerp(slope_dir[1], assumed_dir[1], blend),
    };
    const assumed_mag = std.math.lerp(slope_mag, params.assumed_slope, params.assumed_slope_amount);
    var gully_slope: [2]f32 = .{ dir[0] * assumed_mag, dir[1] * assumed_mag };

    // Peak and valley preservation: the pattern fades out where the terrain
    // is flat, per the inverted-quadratic mask seeded into the octave chain.
    // The steepness comes in separately from the caller, smoothed over a wide
    // stencil: the per-sample gradient here is dominated by fine noise
    // octaves, and feeding it into the mask directly would flicker the
    // erosion amplitude between neighbors.
    const steepness = if (params.fade_slope > 0.0)
        std.math.clamp(fade_steepness / params.fade_slope, 0.0, 1.0)
    else
        1.0;

    var height = height_and_slope[0];
    var slope_x = height_and_slope[1];
    var slope_y = height_and_slope[2];
    var target: f32 = 0.0;
    var combi_mask: f32 = slopeFadeMask(steepness);
    var ridge_fade: f32 = 0.0;
    var ridge_mask: f32 = 1.0;
    var magnitude: f32 = 0.0;

    for (0..params.octaves) |_| {
        const wave = phacelle.phacelleNoise(
            .{ p[0] * freq, p[1] * freq },
            safeNormalize(gully_slope),
            params.cell_scale,
            0.25,
            params.normalization,
        );
        // The chain rule for the caller's coordinate scaling, plus the sign
        // flip that makes the slope point downhill.
        const side_x = wave.side_x * -freq;
        const side_y = wave.side_y * -freq;
        const sloping = @abs(wave.sin);

        // Straight gullies: adding the normalized slope fakes constant
        // steepness so tributaries branch at clean angles instead of curling
        // along ridge flanks.
        const side_sign: f32 = if (wave.sin < 0) -1.0 else 1.0;
        gully_slope[0] += side_sign * side_x * strength * params.gully_weight;
        gully_slope[1] += side_sign * side_y * strength * params.gully_weight;

        const gullies_x = wave.cos;
        const gullies_y = wave.sin * side_x;
        const gullies_z = wave.sin * side_y;

        // Stacked fading: where the mask is low, the previous octave's height
        // carries over so the gullies continue instead of re-starting.
        const faded_x = std.math.lerp(target, gullies_x * params.gully_weight, combi_mask);
        const faded_y = std.math.lerp(0.0, gullies_y * params.gully_weight, combi_mask);
        const faded_z = std.math.lerp(0.0, gullies_z * params.gully_weight, combi_mask);

        height += faded_x * strength;
        slope_x += faded_y * strength;
        slope_y += faded_z * strength;
        magnitude += strength;
        target = faded_x;

        // The mask fades the octave in with the wave slope; creases cut in
        // instantly (zero rounding) while ridge crests fade in smoothly.
        const rounding_for_octave = std.math.lerp(
            params.crease_rounding,
            params.ridge_rounding,
            std.math.clamp(wave.cos + 0.5, 0.0, 1.0),
        ) * rounding_mult;
        const new_mask = easeOut(smoothStart(sloping * onset_octave, rounding_for_octave * onset_octave));
        combi_mask = powInv(combi_mask, params.detail) * new_mask;

        // Ridge map: tracks the wave where the terrain is sloped. Ported for
        // completeness; its tuning is pending the ridge-map terrain features.
        ridge_fade = std.math.lerp(ridge_fade, gullies_x, ridge_mask);
        ridge_mask *= easeOut(sloping * onset_ridge);

        strength *= params.gain;
        freq *= params.lacunarity;
        rounding_mult *= rounding_decay;
    }

    return .{
        .height_delta = height - height_and_slope[0],
        .slope_dx = slope_x - height_and_slope[1],
        .slope_dy = slope_y - height_and_slope[2],
        .magnitude = magnitude,
        .ridge_map = ridge_fade * (1.0 - ridge_mask),
    };
}

/// Smooth ramp from 0 to 1 over the width `smoothing`; instant step at zero
/// when the width is zero.
fn smoothStart(t: f32, smoothing: f32) f32 {
    if (smoothing <= 0) return if (t > 0) 1.0 else 0.0;
    const m = std.math.clamp(t / smoothing, 0.0, 1.0);
    return m * m * (3.0 - 2.0 * m);
}

/// Eased ramp from 0 to 1 across [0, 1].
fn easeOut(t: f32) f32 {
    const m = std.math.clamp(t, 0.0, 1.0);
    return m * m * (3.0 - 2.0 * m);
}

/// Slope fade mask: an inverted quadratic in the steepness, so the fade
/// engages gradually as the terrain flattens instead of snapping like a
/// sqrt-shaped curve would near zero slope.
fn slopeFadeMask(steepness: f32) f32 {
    return 1.0 - (1.0 - steepness) * (1.0 - steepness);
}

/// Raises `x` to the power 1/`power`; below 1 this crushes the previous mask,
/// restricting fine octaves to areas the coarse octaves already carved.
fn powInv(x: f32, power: f32) f32 {
    return @exp(@log(x) / power);
}

/// Unit vector, falling back to +x for degenerate input (flat terrain).
fn safeNormalize(v: [2]f32) [2]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1]);
    if (len > 1e-6) return .{ v[0] / len, v[1] / len };
    return .{ 1.0, 0.0 };
}

test "erosion filter stripes a slope along the gully direction" {
    // A constant slope of 0.5 along x with one octave and full gully weight
    // produces stripes that vary across the slope and stay flat along it.
    const params = ErosionParams{ .octaves = 1, .gully_weight = 1.0 };
    var along_var: f32 = 0;
    var across_var: f32 = 0;
    var delta_range: f32 = 0;
    var first: ?f32 = null;
    const count = 16;
    for (0..count) |ix| {
        for (0..count) |iy| {
            const p = [2]f32{ @as(f32, @floatFromInt(ix)) * 0.25, @as(f32, @floatFromInt(iy)) * 0.25 };
            const result = erosionFilter(p, .{ 0.25 * p[0], -0.5, 0.0 }, 0.5, params);
            if (first) |f| {
                delta_range = @max(delta_range, @abs(result.height_delta - f));
            } else {
                first = result.height_delta;
            }
            if (ix + 1 < count and iy + 1 < count) {
                const east = erosionFilter(.{ p[0] + 0.25, p[1] }, .{ 0.25 * (p[0] + 0.25), -0.5, 0.0 }, 0.5, params);
                const north = erosionFilter(.{ p[0], p[1] + 0.25 }, .{ 0.25 * p[0], -0.5, 0.0 }, 0.5, params);
                const d_along = result.height_delta - east.height_delta;
                const d_across = result.height_delta - north.height_delta;
                along_var += d_along * d_along;
                across_var += d_across * d_across;
            }
        }
    }
    try std.testing.expect(delta_range > 0.05);
    try std.testing.expect(across_var > 2.0 * along_var);
}

test "erosion filter height delta stays within the octave budget" {
    // Across a mixed field the magnitude of the height change is bounded by
    // the sum of the per-octave strengths times the normalized wave range.
    const params = ErosionParams{};
    const max_delta: f32 = params.filter_strength / (1.0 - params.gain) * params.gully_weight * 1.1;
    const count = 8;
    for (0..count) |ix| {
        for (0..count) |iy| {
            const p = [2]f32{ @as(f32, @floatFromInt(ix)) * 0.5 - 1.5, @as(f32, @floatFromInt(iy)) * 0.5 - 1.5 };
            const slope_mag = @sqrt(0.16 * p[0] * p[0] + 0.09 * p[1] * p[1]);
            const result = erosionFilter(p, .{ 0.0, -0.4 * p[0], -0.3 * p[1] }, slope_mag, params);
            try std.testing.expect(@abs(result.height_delta) <= max_delta);
        }
    }
}

test "erosion filter runs with zero crease rounding" {
    // The default crease rounding of 0 must not hit a division by zero in
    // the mask's smoothStart helper.
    const params = ErosionParams{};
    try std.testing.expect(params.crease_rounding == 0.0);
    const count = 4;
    for (0..count) |ix| {
        for (0..count) |iy| {
            const p = [2]f32{ @as(f32, @floatFromInt(ix)) * 0.7 - 1.0, @as(f32, @floatFromInt(iy)) * 0.7 - 1.0 };
            const result = erosionFilter(p, .{ 0.0, -0.5, 0.0 }, 0.5, params);
            try std.testing.expect(std.math.isFinite(result.height_delta));
            try std.testing.expect(std.math.isFinite(result.ridge_map));
        }
    }
}

test "flat terrain collapses the pattern to no carving" {
    // Zero steepness closes the fade mask, so the pattern contributes nothing:
    // no gully cuts a summit or a stream bed, at any altitude or pattern
    // position.
    const params = ErosionParams{};
    for ([_][2]f32{ .{ 0.3, 0.4 }, .{ 7.7, -3.1 }, .{ -12.5, 88.2 } }) |p| {
        for ([_]f32{ 0.9, 0.25, 0.0, -0.25, -0.9 }) |height| {
            const result = erosionFilter(p, .{ height, 0.0, 0.0 }, 0.0, params);
            try std.testing.expectEqual(@as(f32, 0.0), result.height_delta);
        }
    }
}

test "steep slopes keep the full pattern regardless of altitude" {
    // Above the fade slope the mask is fully open, so the pattern varies
    // with position even at peak altitude: steep flanks keep their gullies.
    const params = ErosionParams{};
    var delta_range: f32 = 0;
    var first: ?f32 = null;
    const count = 12;
    for (0..count) |ix| {
        for (0..count) |iy| {
            const p = [2]f32{ @as(f32, @floatFromInt(ix)) * 0.25, @as(f32, @floatFromInt(iy)) * 0.25 };
            const result = erosionFilter(p, .{ 0.9, -2.0 * params.fade_slope, 0.0 }, 2.0 * params.fade_slope, params);
            if (first) |f| {
                delta_range = @max(delta_range, @abs(result.height_delta - f));
            } else {
                first = result.height_delta;
            }
        }
    }
    try std.testing.expect(delta_range > 0.05);
}

test "the pattern fades gradually with the steepness" {
    // Below the fade slope the amplitude follows the mask, so over a fixed
    // window the carve shrinks as the steepness drops while the stripe
    // spacing stays put: flats smooth out without phase noise.
    const params = ErosionParams{};
    var range_full: f32 = 0;
    var range_half: f32 = 0;
    const count = 32;
    var first_full: ?f32 = null;
    var first_half: ?f32 = null;
    for (0..count) |iy| {
        const p = [2]f32{ 0.5, @as(f32, @floatFromInt(iy)) * 0.125 };
        const full = erosionFilter(p, .{ 0.0, params.fade_slope, 0.0 }, params.fade_slope, params);
        if (first_full) |f| {
            range_full = @max(range_full, @abs(full.height_delta - f));
        } else {
            first_full = full.height_delta;
        }
        // Half the steepness keeps three quarters of the mask, but the wave
        // contribution is also cut by the mask, so the window swings shrink.
        const half = erosionFilter(p, .{ 0.0, params.fade_slope * 0.5, 0.0 }, params.fade_slope * 0.5, params);
        if (first_half) |f| {
            range_half = @max(range_half, @abs(half.height_delta - f));
        } else {
            first_half = half.height_delta;
        }
    }
    try std.testing.expect(range_full > range_half);
}

test "slope fade mask follows the inverted quadratic" {
    // Fully closed on flat terrain, fully open at full steepness, and
    // quadratic in between: at half steepness it keeps three quarters of the
    // pattern, unlike a linear (0.5) or sqrt (0.29) fade.
    try std.testing.expectEqual(@as(f32, 0.0), slopeFadeMask(0.0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), slopeFadeMask(0.5), 1e-6);
    try std.testing.expectEqual(@as(f32, 1.0), slopeFadeMask(1.0));
}

test "zero fade slope disables the fade" {
    // With the modulation off every slope gets the full mask, so even a
    // completely flat point keeps the pattern.
    const params = ErosionParams{ .fade_slope = 0.0 };
    var delta_range: f32 = 0;
    var first: ?f32 = null;
    for (0..8) |i| {
        const p = [2]f32{ @as(f32, @floatFromInt(i)) * 0.5 + 0.25, 1.0 };
        const result = erosionFilter(p, .{ 0.0, 0.0, 0.0 }, 0.0, params);
        if (first) |f| {
            delta_range = @max(delta_range, @abs(result.height_delta - f));
        } else {
            first = result.height_delta;
        }
    }
    try std.testing.expect(delta_range > 0.05);
}
