const std = @import("std");
//this was made with AI but i may rewrite it because it is very slow, i spent like 10 hours trying to get trycubic interpolation working just to realise it dosent work with chunks ):

/// Compute natural cubic spline second derivatives for 4 points (exact)
pub fn computeNaturalCubicCoeffs(Type: type, values: [4]Type) [4]Type {
    var m: [4]Type = .{ 0, 0, 0, 0 }; // second derivatives, m0 = m3 = 0 (natural boundary)

    const delta0 = (values[1] - values[0]);
    const delta1 = (values[2] - values[1]);
    const delta2 = (values[3] - values[2]);
    const b1 = 6 * (delta1 - delta0);
    const b2 = 6 * (delta2 - delta1);
    m[1] = (b1 * 4 - b2) / 15;
    m[2] = (4 * b2 - 1 * b1) / 15;

    return m;
}

/// Evaluate a 1D natural cubic spline segment
pub inline fn splineEval(Type: type, values: [4]Type, m: [4]Type, t: Type) Type {
    const one_third: Type = comptime 1.0 / 3.0;
    var i: usize = 0;
    var localT: Type = 0.0;

    if (t <= one_third) {
        i = 0;
        localT = t * 3.0;
    } else if (t <= comptime 2 * one_third) {
        i = 1;
        localT = t * 3.0 - 1.0;
    } else {
        i = 2;
        localT = t * 3.0 - 2.0;
    }

    const a = 1.0 - localT;
    const b = localT;
    const h2_6 = comptime 1.0 / 6.0;

    const term1 = (a * a * a - a) * m[i];
    const term2 = (b * b * b - b) * m[i + 1];

    return a * values[i] + b * values[i + 1] + (term1 + term2) * h2_6;
}

/// Tricubic natural cubic spline interpolation for 4x4x4 grid
pub fn tricubicNaturalSplineInterpolate(Type: type, grid: [4][4][4]Type, x: Type, y: Type, z: Type) Type {
    var temp2D: [4][4]Type = undefined;
    var coeffsX: [4]Type = undefined;

    // Step 1: interpolate along X for each (y,z) row
    var valuesX: [4]Type = undefined;
    for (0..4) |yi| {
        for (0..4) |zi| {
            valuesX = .{ grid[0][yi][zi], grid[1][yi][zi], grid[2][yi][zi], grid[3][yi][zi] };
            coeffsX = computeNaturalCubicCoeffs(Type, valuesX);
            temp2D[yi][zi] = splineEval(Type, valuesX, coeffsX, x);
        }
    }

    // Step 2: interpolate along Y for each Z
    var temp1D: [4]Type = undefined;
    var valuesY: [4]Type = undefined;
    for (0..4) |zi| {
        valuesY = .{ temp2D[0][zi], temp2D[1][zi], temp2D[2][zi], temp2D[3][zi] };
        coeffsX = computeNaturalCubicCoeffs(Type, valuesY);
        temp1D[zi] = splineEval(Type, valuesY, coeffsX, y);
    }

    // Step 3: interpolate along Z
    const valuesZ: [4]Type = temp1D;
    coeffsX = computeNaturalCubicCoeffs(Type, valuesZ);
    return splineEval(Type, valuesZ, coeffsX, z);
}

test "speed" {
    var grid: [4][4][4]f32 = undefined;

    grid[0][2][3] = 43.0;
    const st = std.time.nanoTimestamp();
    var a: f32 = 0.0;
    for (0..100_000) |_| {
        grid[std.crypto.random.intRangeLessThan(usize, 0, 4)][2][3] = std.crypto.random.float(f32) * 10;
        a += tricubicNaturalSplineInterpolate(f32, grid, 0, std.crypto.random.float(f32), 0);
    }
    const et = std.time.nanoTimestamp();
    const elapsed = et - st;
    std.debug.print("Elapsed time: {d}, a: {d} s\n", .{ @as(f128, @floatFromInt(elapsed)) / std.time.ns_per_s, a });
}
