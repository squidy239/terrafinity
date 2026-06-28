// 3D natural cubic spline interpolator for a 4×4×4 grid.
//
// Uses a transposed grid layout so that each SIMD vector holds values along
// the fast-varying dimension, enabling vectorised interpolation along X.
pub const NaturalCubicInterpolator3D = struct {
    // X-direction cubic coefficients, transposed: coeffs_x_vec[z * 4 + y] is a
    // vector of 4 coefficients for the X spline along the (y, z) slice.
    coeffs_x_vec: [4][16]f32,

    // Y-direction cubic coefficients: coeffs_y_vec[z * 4 + x] is a vector of
    // 4 coefficients for the Y spline along the (x, z) column.
    coeffs_y_vec: [4][4]f32,

    // Z-direction cubic coefficients for the single (x=0, y=0) column.
    coeffs_z_vec: [4]f32,

    // Grid data stored in transposed form so that each SIMD lane holds values
    // along the X axis for a fixed (y, z).
    transposed_grid: [4][16]f32,

    const Self = @This();
    const one_over_six: f32 = 1.0 / 6.0;

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
            .coeffs_x_vec = undefined,
            .coeffs_y_vec = undefined,
            .coeffs_z_vec = undefined,
            .transposed_grid = transpose(f32, 16, 4, vgrid),
        };

        self.precomputeCoefficients(grid);
        return self;
    }

    fn precomputeCoefficients(self: *Self, grid: [4][4][4]f32) void {
        var raw_coeffs_x: [4][4][4][4]f32 = undefined;
        var raw_coeffs_x_vec: [16][4]f32 = undefined;

        // X-direction: one spline per (y, z) slice.
        for (0..4) |y| {
            for (0..4) |z| {
                const values = [4]f32{
                    grid[0][y][z],
                    grid[1][y][z],
                    grid[2][y][z],
                    grid[3][y][z],
                };
                raw_coeffs_x[0][y][z] = computeCubicCoefficients(f32, values);
            }
        }
        for (0..4) |yi| {
            for (0..4) |zi| {
                const idx = yi * 4 + zi;
                raw_coeffs_x_vec[idx] = raw_coeffs_x[0][yi][zi];
            }
        }
        self.coeffs_x_vec = transpose(f32, 16, 4, raw_coeffs_x_vec);

        // Y-direction: one spline per (x, z) column, stored with x fixed at 0.
        var raw_coeffs_y: [4][4]f32 = undefined;
        for (0..4) |z| {
            const values = [4]f32{
                grid[0][0][z],
                grid[0][1][z],
                grid[0][2][z],
                grid[0][3][z],
            };
            raw_coeffs_y[z] = computeCubicCoefficients(f32, values);
        }
        self.coeffs_y_vec = transpose(f32, 4, 4, raw_coeffs_y);

        // Z-direction: one spline along the (0, 0) row.
        const values = [4]f32{
            grid[0][0][0],
            grid[0][0][1],
            grid[0][0][2],
            grid[0][0][3],
        };
        self.coeffs_z_vec = computeCubicCoefficients(f32, values);
    }

    /// Sample the interpolated value at the given (x, y, z) coordinates.
    pub fn sample(interp: *const Self, x: f32, y: f32, z: f32) f32 {
        // Step 1: interpolate along X.
        const x_result: [4]@Vector(4, f32) = @bitCast(splineEvalSimd(
            f32,
            16,
            @bitCast(interp.transposed_grid),
            interp.coeffs_x_vec,
            x,
        ));
        // Step 2: interpolate along Y.
        const y_result = splineEvalSimd(f32, 4, x_result, interp.coeffs_y_vec, y);
        // Step 3: interpolate along Z.
        return splineEval(f32, y_result, interp.coeffs_z_vec, z);
    }

    /// Sample with comptime x and z so those dimensions can be partially
    /// constant-folded at compile time.
    pub fn sampleComptimeXz(interp: *const Self, comptime x: f32, y: f32, comptime z: f32) f32 {
        const x_result: [4]@Vector(4, f32) = @bitCast(splineEvalSimdComptimeT(
            f32,
            16,
            interp.transposed_grid,
            interp.coeffs_x_vec,
            x,
        ));
        const y_result = splineEvalSimd(f32, 4, x_result, interp.coeffs_y_vec, y);
        return splineEvalComptimeT(f32, y_result, interp.coeffs_z_vec, z);
    }

    /// Full comptime sample — the result is a compile-time constant when
    /// called with comptime arguments.
    pub fn sampleComptime(interp: *const Self, comptime x: f32, comptime y: f32, comptime z: f32) f32 {
        const x_result: [4]@Vector(4, f32) = @bitCast(splineEvalSimdComptimeT(
            f32,
            16,
            interp.transposed_grid,
            interp.coeffs_x_vec,
            x,
        ));
        const y_result = splineEvalSimdComptimeT(f32, 4, x_result, interp.coeffs_y_vec, y);
        return splineEvalComptimeT(f32, y_result, interp.coeffs_z_vec, z);
    }

    /// Compute the second-derivative coefficients for a natural cubic spline
    /// given four sample values.  The boundary conditions m₀ = m₃ = 0 are
    /// enforced (natural spline).
    fn computeCubicCoefficients(Type: type, values: [4]Type) [4]Type {
        var m: [4]Type = .{ 0, 0, 0, 0 };
        const delta0 = values[1] - values[0];
        const delta1 = values[2] - values[1];
        const delta2 = values[3] - values[2];
        const b1 = 6 * (delta1 - delta0);
        const b2 = 6 * (delta2 - delta1);
        m[1] = (b1 * 4 - b2) / 15;
        m[2] = (4 * b2 - b1) / 15;
        return m;
    }

    /// Evaluate a 1D natural cubic spline at parameter `t ∈ [0, 3)`.
    fn splineEval(Type: type, values: [4]Type, m: [4]Type, t: Type) Type {
        const one_third: Type = comptime 1.0 / 3.0;
        const seg_idx: usize = @trunc(@min(@floor(t / one_third), 2));
        const local_t: Type = t * 3.0 - @as(Type, @floatFromInt(seg_idx));
        const a = 1.0 - local_t;
        return (a * values[seg_idx]
            + local_t * values[seg_idx + 1]
            + ((a * a * a - a) * m[seg_idx]
                + (local_t * local_t * local_t - local_t) * m[seg_idx + 1])
            * one_over_six);
    }

    /// Compile-time variant of [`splineEval`].
    fn splineEvalComptimeT(Type: type, values: [4]Type, m: [4]Type, comptime t: Type) Type {
        const one_third: Type = comptime 1.0 / 3.0;
        const seg_idx: usize = comptime @trunc(@min(@floor(t / one_third), 2));
        const local_t: Type = comptime t * 3.0 - @as(Type, @floatFromInt(seg_idx));
        const a = comptime 1.0 - local_t;
        return (a * values[seg_idx]
            + local_t * values[seg_idx + 1]
            + ((comptime (a * a * a - a)) * m[seg_idx]
                + (comptime (local_t * local_t * local_t - local_t)) * m[seg_idx + 1])
            * one_over_six);
    }

    /// Transpose an N×M 2D array into an M×N array at compile time.
    fn transpose(comptime T: type, comptime N: usize, comptime M: usize, arr: [N][M]T) [M][N]T {
        var result: [M][N]T = undefined;
        inline for (0..N) |i| {
            inline for (0..M) |j| {
                result[j][i] = arr[i][j];
            }
        }
        return result;
    }

    /// SIMD-aware spline evaluation.  `values` holds the four control values
    /// as a single SIMD vector; `m` holds the four second-derivative
    /// coefficients (one per lane).
    fn splineEvalSimd(
        comptime T: type,
        comptime len: usize,
        values: [4]@Vector(len, T),
        m: [4][len]T,
        t: T,
    ) @Vector(len, T) {
        const seg_idx: usize = @trunc(@min(@floor(t * 3), 2));
        const local_t: T = t * 3.0 - @as(T, @floatFromInt(seg_idx));
        const local_t_vec: @Vector(len, T) = @splat(local_t);
        const a_vec: @Vector(len, T) = @splat(1.0 - local_t);
        const one_over_six_vec: @Vector(len, T) = comptime @splat(one_over_six);
        return (a_vec * values[seg_idx]
            + local_t_vec * values[seg_idx + 1]
            + ((a_vec * a_vec * a_vec - a_vec) * m[seg_idx]
                + (local_t_vec * local_t_vec * local_t_vec - local_t_vec) * m[seg_idx + 1])
            * one_over_six_vec);
    }

    /// Compile-time SIMD variant of [`splineEvalSimd`].
    fn splineEvalSimdComptimeT(
        comptime T: type,
        comptime len: usize,
        values: [4][len]T,
        m: [4][len]T,
        comptime t: T,
    ) @Vector(len, T) {
        const seg_idx: usize = comptime @trunc(@min(@floor(t * 3), 2));
        const local_t: T = comptime t * 3.0 - @as(T, @floatFromInt(seg_idx));
        const local_t_vec: @Vector(len, T) = comptime @splat(local_t);
        const a_vec: @Vector(len, T) = comptime @splat(1.0 - local_t);
        const one_over_six_vec: @Vector(len, T) = comptime @splat(one_over_six);
        return (a_vec * values[seg_idx]
            + local_t_vec * values[seg_idx + 1]
            + ((comptime (a_vec * a_vec * a_vec - a_vec)) * m[seg_idx]
                + (comptime (local_t_vec * local_t_vec * local_t_vec - local_t_vec)) * m[seg_idx + 1])
            * one_over_six_vec);
    }
};
