const std = @import("std");
//this was made with AI but i may rewrite it because it is very slow, i spent like 10 hours trying to get trycubic interpolation working just to realise it dosent work with chunks ):
pub const interp = @import("t.zig").NaturalCubicInterpolator3D;
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
pub fn splineEval(Type: type, values: [4]Type, m: [4]Type, t: Type) Type {
    const one_third: Type = comptime 1.0 / 3.0;
    const i: usize = @intFromFloat(@min(@floor(t / one_third), 2));
    const localT: Type = t * 3.0 - @as(Type, @floatFromInt(i));

    const a = 1.0 - localT;
    const h2_6 = comptime 1.0 / 6.0;
    return a * values[i] + localT * values[i + 1] + ((a * a * a - a) * m[i] + (localT * localT * localT - localT) * m[i + 1]) * h2_6;
}

//pub fn splineEvalSimd(Type: type, comptime len: usize, values: *[len][4]Type, m: [len][4]Type, t: Type) @Vector(len, f32) {
//    const one_third: @Vector(len, Type) = comptime @splat(1.0 / 3.0);
//  const i: usize = @intFromFloat(@min(@floor(t / one_third[0]), 2));
//    const localT: @Vector(len, Type) = @splat(t * 3.0 - @as(Type, @floatFromInt(i)));
//    const tvalues = transpose(Type, 4, len, values.*);
//    const tm = transpose(Type, 4, len, m);
// const a = @as(@Vector(len, Type), @splat(1.0)) - localT;
// const h2_6: @Vector(len, Type) = comptime @splat(1.0 / 6.0);
//   return a * tvalues[i] + localT * tvalues[i + 1] + ((a * a * a - a) * tm[i] + (localT * localT * localT - localT) * tm[i + 1]) * h2_6;
//}

/// Tricubic natural cubic spline interpolation for 4x4x4 grid
threadlocal var coeffsXc: [4][4][4][4]f32 = undefined;

pub fn tricubicNaturalSplineInterpolate(Type: type, grid: *[4][4][4]Type, x: Type, y: Type, z: Type) Type {
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
    var tangX: [4][4][4]f32 = undefined;
    var tangY: [4][4][4]f32 = undefined;
    var tangZ: [4][4][4]f32 = undefined;
    tricubicNaturalSplineInterpolate(f32, &grid, &tangX, &tangY, &tangZ);
    // var temp2D: [4][4]f32 = undefined;
    ////  var valuesY: [4][4]f32 = undefined;
    //   var valuesX2d: [16][4]f32 = undefined;
    for (0..(32 * 32 * 32 * 32)) |_| {
        grid[std.crypto.random.intRangeLessThan(usize, 0, 4)][2][3] = std.crypto.random.float(f32) * 10;
        a += tricubicNaturalSplineInterpolate(f32, grid, tangX, tangY, tangZ, 0, std.crypto.random.float(f32), 0);
        a += 1;
    }
    const et = std.time.nanoTimestamp();
    const elapsed = et - st;
    std.debug.print("Elapsed time: {d} s, a: {d}\n", .{ @as(f128, @floatFromInt(elapsed)) / std.time.ns_per_s, a });
}
