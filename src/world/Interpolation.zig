const std = @import("std");
const math = std.math;
const print = std.debug.print;

// 3D Monotone Cubic Interpolator for 4x4x4 grid
pub const NaturalCubicInterpolator3D = struct {
    // Precomputed cubic coefficients for all directions
    coeffs_x_vectorized: [4]@Vector(16, f32), // X-direction coefficients for each (y,z)
    coeffs_y_vectorized: [4]@Vector(4, f32), // Y-direction coefficients for each (x,z)
    coeffs_z_vectorized: [4]f32, // Z-direction coefficients for each (x,y)

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
            .coeffs_z_vectorized = undefined,
            .tvgrid = transpose(f32, 16, 4, vgrid),
        };

        // Precompute ALL cubic coefficients
        self.precomputeCoeffs(grid);
        return self;
    }

    fn precomputeCoeffs(self: *Self, grid: [4][4][4]f32) void {
        var coeffs_x: [4][4][4][4]f32 = undefined;
        var coeffs_x_vec: [16][4]f32 = undefined;

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
        var coeffs_z: [4]f32 = undefined;
        const values = [4]f32{ grid[0][0][0], grid[0][0][1], grid[0][0][2], grid[0][0][3] };
        coeffs_z = computeNaturalCubicCoeffs(f32, values);
        self.coeffs_z_vectorized = coeffs_z;
    }
    
    pub fn sample(interp: *const Self, x: f32, y: f32, z: f32) f32 {
        // Step 1: X interpolation
        var xresult: [4][4]f32 = @bitCast(splineEvalSimd(f32, 16, &interp.tvgrid, &interp.coeffs_x_vectorized, x));
        // Step 2: Y interpolation
        const yresult = splineEvalSimd(f32, 4, &xresult, &interp.coeffs_y_vectorized, y);
        // Step 3: Z interpolation
        return splineEval(f32, yresult, interp.coeffs_z_vectorized, z);
    }

    pub fn sampleComptimeXZ(interp: *const Self, comptime x: f32, y: f32, comptime z: f32) f32 {
        // Step 1: X interpolation
        const xresult: [4]@Vector(4, f32) = @bitCast(splineEvalSimdComptimeT(f32, 16, interp.tvgrid, interp.coeffs_x_vectorized, x));
        // Step 2: Y interpolation
        const yresult = splineEvalSimd(f32, 4, xresult, interp.coeffs_y_vectorized, y);
        // Step 3: Z interpolation
        return splineEvalComptimeT(f32, yresult, interp.coeffs_z_vectorized, z);
    }

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

    const h2_6 = 1.0 / 6.0;
    /// Evaluate a 1D natural cubic spline segment
    pub inline fn splineEval(Type: type, values: [4]Type, m: [4]Type, t: Type) Type {
        const one_third: Type = comptime 1.0 / 3.0;
        const i: usize = @intFromFloat(@min(@floor(t / one_third), 2));
        const localT: Type = t * 3.0 - @as(Type, @floatFromInt(i));
        const a = 1.0 - localT;
        return a * values[i] + localT * values[i + 1] + ((a * a * a - a) * m[i] + (localT * localT * localT - localT) * m[i + 1]) * h2_6;
    }

    pub inline fn splineEvalComptimeT(Type: type, values: [4]Type, m: [4]Type, comptime t: Type) Type {
        const one_third: Type = comptime 1.0 / 3.0;
        const i: usize = comptime @intFromFloat(@min(@floor(t / one_third), 2));
        const localT: Type = comptime t * 3.0 - @as(Type, @floatFromInt(i));
        const a = comptime 1.0 - localT;
        return a * values[i] + localT * values[i + 1] + ((comptime (a * a * a - a)) * m[i] + (comptime (localT * localT * localT - localT)) * m[i + 1]) * h2_6;
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

    pub inline fn splineEvalSimd(comptime T: type, comptime len: usize, values: [4]@Vector(len, T), m: [4][len]T, t: T) @Vector(len, T) {
        const i: usize = @intFromFloat(@min(@floor(t * 3), 2));
        const localT: T = t * 3.0 - @as(f32, @floatFromInt(i));
        const localT_v: @Vector(len, T) = @splat(localT);
        const a_v: @Vector(len, T) = @splat(1.0 - localT);
        const h2_6_v: @Vector(len, T) = comptime @splat(2 / 6);
        return a_v * values[i] + localT_v * values[i + 1] + ((a_v * a_v * a_v - a_v) * m[i] + (localT_v * localT_v * localT_v - localT_v) * m[i + 1]) * h2_6_v;
    }

    pub inline fn splineEvalSimdComptimeT(comptime T: type, comptime len: usize, values: [4][len]T, m: [4][len]T, comptime t: T) @Vector(len, T) {
        const i: usize = comptime @intFromFloat(@min(@floor(t * 3), 2));
        const localT: T = comptime t * 3.0 - @as(f32, @floatFromInt(i));
        const localT_v: @Vector(len, T) = comptime @splat(localT);
        const a_v: @Vector(len, T) = comptime @splat(1.0 - localT);
        const h2_6_v: @Vector(len, T) = comptime @splat(2 / 6);
        return a_v * values[i] + localT_v * values[i + 1] + ((comptime (a_v * a_v * a_v - a_v)) * m[i] + (comptime (localT_v * localT_v * localT_v - localT_v)) * m[i + 1]) * h2_6_v;
    }
};