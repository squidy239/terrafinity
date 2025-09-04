const std = @import("std");
const math = std.math;
const print = std.debug.print;
const Allocator = std.mem.Allocator;

// 3D Monotone Cubic Interpolator for 4x4x4 grid
pub const NaturalCubicInterpolator3D = struct {
    // Precomputed cubic coefficients for all directions
    coeffs_x_vectorized: [4][16]f32, // X-direction coefficients for each (y,z)
    coeffs_y_vectorized: [4][4]f32, // Y-direction coefficients for each (x,z)
    coeffs_z: [4][4][4][4]f32, // Z-direction coefficients for each (x,y)

    //transposed vectorized grid data
    tvgrid: [4][16]f32,

    const Self = @This();

    pub fn init(grid: [4][4][4]f32) Self {
        var vgrid: [16][4]f32 = undefined;

        inline for (0..4) |yi| {
            inline for (0..4) |zi| {
                const idx = yi * 4 + zi;
                vgrid[idx] = @Vector(4, f32){
                    grid[0][yi][zi],
                    grid[1][yi][zi],
                    grid[2][yi][zi],
                    grid[3][yi][zi],
                };
            }
        }

        var self = Self{
            .coeffs_x_vectorized = undefined,
            .coeffs_y_vectorized = undefined,
            .coeffs_z = undefined,
            .tvgrid = transpose(f32, 16, 4, vgrid),
        };

        // Precompute ALL cubic coefficients
        self.precomputeCoeffs(grid);
        return self;
    }

    fn precomputeCoeffs(self: *Self, grid: [4][4][4]f32) void {
        var coeffs_x: [4][4][4][4]f32 = undefined;
        var coeffs_x_vec: [16]@Vector(4, f32) = undefined;

        // Precompute X-direction coefficients
        for (0..4) |y| {
            for (0..4) |z| {
                const values = [4]f32{ grid[0][y][z], grid[1][y][z], grid[2][y][z], grid[3][y][z] };
                coeffs_x[0][y][z] = computeNaturalCubicCoeffs(f32, values);
            }
        }
        for (0..4) |yi| {
            for (0..4) |zi| {
                const idx = yi * 4 + zi;
                coeffs_x_vec[idx] = coeffs_x[0][yi][zi];
            }
        }
        self.coeffs_x_vectorized = transpose(f32, 16, 4, coeffs_x_vec);
        var coeffs_y: [4][4]f32 = undefined;
        // Precompute Y-direction coefficients
        for (0..4) |z| {
            const values = [4]f32{ grid[0][0][z], grid[0][1][z], grid[0][2][z], grid[0][3][z] };
            coeffs_y[z] = computeNaturalCubicCoeffs(f32, values);
        }
        self.coeffs_y_vectorized = transpose(f32, 4, 4, coeffs_y);

        // Precompute Z-direction coefficients
        for (0..4) |x| {
            for (0..4) |y| {
                const values = [4]f32{ grid[x][y][0], grid[x][y][1], grid[x][y][2], grid[x][y][3] };
                self.coeffs_z[x][y][0] = computeNaturalCubicCoeffs(f32, values);
            }
        }
    }

    pub inline fn sample(self: *const Self, x: f32, y: f32, z: f32) f32 {
        return tricubicNaturalSplineInterpolateFast(self, x, y, z);
    }
};

/// Fast tricubic interpolation using precomputed coefficients
/// var temp2D: [4][4]f32 = undefined;
threadlocal var temp1D: [4]f32 = undefined;
threadlocal var temp2D: [4][4]f32 = undefined;
fn tricubicNaturalSplineInterpolateFast(interp: *const NaturalCubicInterpolator3D, x: f32, y: f32, z: f32) f32 {
    // Step 1: X interpolation - vectorized where possible\
    // one SIMD splineEval over 16 splines
    const xresult: @Vector(16, f32) = splineEvalSimd(f32, 16, &interp.tvgrid, &interp.coeffs_x_vectorized, x);

    // Step 2: Y interpolation
    temp2D = @bitCast(xresult);
    const yresult = splineEvalSimd(f32, 4, &temp2D, &interp.coeffs_y_vectorized, y);
    // Step 3: Z interpolation

    const coeff = computeNaturalCubicCoeffs(f32, yresult);
    return splineEval(f32, yresult, coeff, z);
}

/// Original functions for compatibility
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
pub fn transpose(comptime T: type, comptime N: usize, comptime M: usize, arr: [N][M]T) [M][N]T {
    var result: [M][N]T = undefined;

    inline for (0..N) |i| {
        inline for (0..M) |j| {
            result[j][i] = arr[i][j];
        }
    }

    return result;
}

pub fn splineEvalSimd(comptime T: type, comptime len: usize, values: *const [4][len]T, m: *const [4][len]T, t: T) @Vector(len, T) {
    const h2_6 = 1.0 / 6.0;

    // same for all splines
    const i: usize = @intFromFloat(@min(@floor(t * 3), 2));
    const localT: T = t * 3.0 - @as(f32, @floatFromInt(i));

    const localT_v: @Vector(len, T) = @splat(localT);
    const a_v: @Vector(len, T) = @splat(1.0 - localT);
    const h2_6_v: @Vector(len, T) = comptime @splat(h2_6);
    return a_v * values[i] +
        localT_v * values[i + 1] +
        ((a_v * a_v * a_v - a_v) * m[i] +
            (localT_v * localT_v * localT_v - localT_v) * m[i + 1]) * h2_6_v;
}

/// Tricubic natural cubic spline interpolation for 4x4x4 grid
pub fn tricubicNaturalSplineInterpolate(Type: type, grid: [4][4][4]Type, x: Type, y: Type, z: Type) Type {
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
    var st = std.time.nanoTimestamp();
    var a: f32 = 0.0;
    const it = 32 * 32 * 32 * 32;
    // var temp2D: [4][4]f32 = undefined;
    ////  var valuesY: [4][4]f32 = undefined;
    //   var valuesX2d: [16][4]f32 = undefined;
    for (0..it) |_| {
        a += tricubicNaturalSplineInterpolate(f32, grid, 0, 3, 0);
    }
    var et = std.time.nanoTimestamp();
    const elapsed1 = et - st;
    std.debug.print("Elapsed time: {d} us, a: {d}\n", .{ @as(f128, @floatFromInt(elapsed1)) / std.time.ns_per_us, a });

    grid[0][2][3] = 43.0;
    st = std.time.nanoTimestamp();
    a = 0.0;
    var interpolator = NaturalCubicInterpolator3D.init(grid);
    // var temp2D: [4][4]f32 = undefined;
    ////  var valuesY: [4][4]f32 = undefined;
    //   var valuesX2d: [16][4]f32 = undefined;
    for (0..it) |_| {
        a += interpolator.sample(0, 3, 0);
    }
    et = std.time.nanoTimestamp();
    const elapsed2 = et - st;
    std.debug.print("new Elapsed time: {d} us, a: {d}\n", .{ @as(f128, @floatFromInt(elapsed2)) / std.time.ns_per_us, a });
    std.debug.print("speed increased by: {d} times\n", .{@as(f128, @floatFromInt(elapsed1)) / @as(f128, @floatFromInt(elapsed2))});
}
