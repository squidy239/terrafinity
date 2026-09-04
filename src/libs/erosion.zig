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

/// Wave offset of the Phacelle pattern; 0.25 lands the flat-pattern null at
/// cos(0.25 * tau) ≈ 0 so featureless ground is left undisturbed.
const wave_offset: f32 = 0.25;
/// Slope multiplier gating the ridge-map fade per octave.
const ridge_onset: f32 = 2.0;
/// Per-octave decay of the mask rounding width.
const rounding_decay: f32 = 0.5;
/// Gradient magnitude below which the seeded direction is float noise; the
/// seed blends toward the assumed-slope direction there so flats stay
/// deterministic across build modes.
const gradient_floor: f32 = 1e-4;

/// Applies the erosion filter at position `p`. `height_and_slope` carries the
/// height in normalized units and the downhill slope. `fade_steepness` is the
/// locally averaged slope magnitude: the pattern fades out on flat ground
/// (inverted-quadratic mask), so a summit or stream bed is never carved.
/// Each octave steers off the slope accumulated by the previous one; that
/// loop order is load-bearing.
pub fn erosionFilter(p: [2]f32, height_and_slope: [3]f32, fade_steepness: f32, params: ErosionParams) ErosionResult {
    const steepness = if (params.fade_slope > 0.0)
        std.math.clamp(fade_steepness / params.fade_slope, 0.0, 1.0)
    else
        1.0;
    var octave: Octave = .{ .strength = params.filter_strength };
    var state = State{
        .gully = seedSlope(height_and_slope, params),
        .height = height_and_slope[0],
        .slope = .{ height_and_slope[1], height_and_slope[2] },
        .mask = slopeFadeMask(steepness),
    };
    for (0..params.octaves) |_| {
        state.apply(p, octave, params);
        octave.advance(params);
    }
    return .{
        .height_delta = state.height - height_and_slope[0],
        .slope_dx = state.slope[0] - height_and_slope[1],
        .slope_dy = state.slope[1] - height_and_slope[2],
        .magnitude = state.magnitude,
        .ridge_map = state.ridge_fade * (1.0 - state.ridge_mask),
    };
}

/// Per-octave frequency, strength, and mask rounding width.
const Octave = struct {
    freq: f32 = 1.0,
    strength: f32,
    rounding: f32 = 1.0,

    fn advance(self: *Octave, params: ErosionParams) void {
        self.strength *= params.gain;
        self.freq *= params.lacunarity;
        self.rounding *= rounding_decay;
    }
};

/// Accumulated filter state threaded through the octave chain.
const State = struct {
    gully: [2]f32,
    height: f32,
    slope: [2]f32,
    target: f32 = 0.0,
    mask: f32,
    ridge_fade: f32 = 0.0,
    ridge_mask: f32 = 1.0,
    magnitude: f32 = 0.0,

    fn apply(self: *State, p: [2]f32, octave: Octave, params: ErosionParams) void {
        const wave = phacelle.phacelleNoise(
            .{ p[0] * octave.freq, p[1] * octave.freq },
            safeNormalize(self.gully),
            params.cell_scale,
            wave_offset,
            params.normalization,
        );
        // Chain rule for the caller's coordinate scaling, plus the sign flip
        // that makes the slope point downhill.
        const side: [2]f32 = .{ wave.side_x * -octave.freq, wave.side_y * -octave.freq };
        const sloping = @abs(wave.sin);

        // Straight gullies: adding the normalized slope fakes constant steepness
        // so tributaries branch at clean angles instead of curling along flanks.
        const side_sign: f32 = if (wave.sin < 0) -1.0 else 1.0;
        self.gully[0] += side_sign * side[0] * octave.strength * params.gully_weight;
        self.gully[1] += side_sign * side[1] * octave.strength * params.gully_weight;

        // Where the mask is low the previous octave's height carries over so
        // gullies continue instead of re-starting.
        const gullies: [3]f32 = .{ wave.cos, wave.sin * side[0], wave.sin * side[1] };
        const faded: [3]f32 = .{
            std.math.lerp(self.target, gullies[0] * params.gully_weight, self.mask),
            std.math.lerp(0.0, gullies[1] * params.gully_weight, self.mask),
            std.math.lerp(0.0, gullies[2] * params.gully_weight, self.mask),
        };
        self.height += faded[0] * octave.strength;
        self.slope[0] += faded[1] * octave.strength;
        self.slope[1] += faded[2] * octave.strength;
        self.magnitude += octave.strength;
        self.target = faded[0];

        // The mask fades the octave in with the wave slope; creases cut in
        // instantly (zero rounding) while crests fade in smoothly.
        const rounding = std.math.lerp(
            params.crease_rounding,
            params.ridge_rounding,
            std.math.clamp(wave.cos + 0.5, 0.0, 1.0),
        ) * octave.rounding;
        self.mask = powInv(self.mask, params.detail) * easeOut(smoothStart(sloping, rounding));

        // Ridge map: tracks the wave where the terrain is sloped. Ported for
        // completeness; its tuning is pending the ridge-map terrain features.
        self.ridge_fade = std.math.lerp(self.ridge_fade, gullies[0], self.ridge_mask);
        self.ridge_mask *= easeOut(sloping * ridge_onset);
    }
};

/// Initial gully slope from the terrain gradient: the magnitude is replaced
/// by the assumed slope so extreme gradients do not over-feed the mask and
/// only the direction survives into the first octave.
fn seedSlope(height_and_slope: [3]f32, params: ErosionParams) [2]f32 {
    const slope = .{ height_and_slope[1], height_and_slope[2] };
    const mag = @sqrt(slope[0] * slope[0] + slope[1] * slope[1]);
    const dir = safeNormalize(slope);
    const assumed_len = @sqrt(params.assumed_slope * params.assumed_slope + 1.0);
    const assumed: [2]f32 = .{ params.assumed_slope / assumed_len, 1.0 / assumed_len };
    const blend = std.math.clamp(gradient_floor / @max(mag, 1e-20), 0.0, 1.0);
    const mixed: [2]f32 = .{
        std.math.lerp(dir[0], assumed[0], blend),
        std.math.lerp(dir[1], assumed[1], blend),
    };
    const amount = std.math.lerp(mag, params.assumed_slope, params.assumed_slope_amount);
    return .{ mixed[0] * amount, mixed[1] * amount };
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
/// At zero the mask latches closed, which is what keeps flat ground uncarved.
fn powInv(x: f32, power: f32) f32 {
    return @exp(@log(x) / power);
}

/// Unit vector, falling back to +x for degenerate input (flat terrain).
fn safeNormalize(v: [2]f32) [2]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1]);
    if (len > 1e-6) return .{ v[0] / len, v[1] / len };
    return .{ 1.0, 0.0 };
}

/// Height-delta spread along points `origin + i * step` at fixed
/// height/slope/steepness.
fn sweepRange(params: ErosionParams, count: usize, origin: [2]f32, step: [2]f32, hs: [3]f32, steep: f32) f32 {
    var range: f32 = 0;
    var first: ?f32 = null;
    for (0..count) |i| {
        const t = @as(f32, @floatFromInt(i));
        const result = erosionFilter(.{ t * step[0] + origin[0], t * step[1] + origin[1] }, hs, steep, params);
        if (first) |f| {
            range = @max(range, @abs(result.height_delta - f));
        } else {
            first = result.height_delta;
        }
    }
    return range;
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
    const range_full = sweepRange(params, 32, .{ 0.5, 0.0 }, .{ 0.0, 0.125 }, .{ 0.0, params.fade_slope, 0.0 }, params.fade_slope);
    // Half the steepness keeps three quarters of the mask, but the wave
    // contribution is also cut by the mask, so the window swings shrink.
    const range_half = sweepRange(params, 32, .{ 0.5, 0.0 }, .{ 0.0, 0.125 }, .{ 0.0, params.fade_slope * 0.5, 0.0 }, params.fade_slope * 0.5);
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
    const range = sweepRange(params, 8, .{ 0.25, 1.0 }, .{ 0.5, 0.0 }, .{ 0.0, 0.0, 0.0 }, 0.0);
    try std.testing.expect(range > 0.05);
}
