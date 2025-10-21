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

    pub fn samplePrecalc(interp: *const Self, x: PrecalcData(f32, true, 16), y: PrecalcData(f32, true, 4), z: PrecalcData(f32, false, null)) f32 {
        // Step 1: X interpolation
        var xresult: [4][4]f32 = @bitCast(splineEvalSimdPrecalc(f32, 16, &interp.tvgrid, &interp.coeffs_x_vectorized, x));
        // Step 2: Y interpolation
        const yresult = splineEvalSimdPrecalc(f32, 4, &xresult, &interp.coeffs_y_vectorized, y);
        // Step 3: Z interpolation
        return splineEvalPrecalc(f32, yresult, interp.coeffs_z_vectorized, z);
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
        var xresult: [4]@Vector(4, f32) = @bitCast(splineEvalSimdComptimeT(f32, 16, &interp.tvgrid, &interp.coeffs_x_vectorized, x));
        // Step 2: Y interpolation
        const yresult = splineEvalSimd(f32, 4, &xresult, &interp.coeffs_y_vectorized, y);
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

    pub inline fn splineEvalPrecalc(Type: type, values: [4]Type, m: [4]Type, t: PrecalcData(Type, false, null)) Type {
        const i: usize = t.i;
        return t.a_v * values[i] + t.localT * values[i + 1] + ((t.a_v_precalc) * m[i] + (t.localT_precalc) * m[i + 1]) * h2_6;
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

    pub inline fn splineEvalSimd(comptime T: type, comptime len: usize, values: *const [4]@Vector(len, T), m: *const [4][len]T, t: T) @Vector(len, T) {
        const i: usize = @intFromFloat(@min(@floor(t * 3), 2));
        const localT: T = t * 3.0 - @as(f32, @floatFromInt(i));
        const localT_v: @Vector(len, T) = @splat(localT);
        const a_v: @Vector(len, T) = @splat(1.0 - localT);
        const h2_6_v: @Vector(len, T) = comptime @splat(2 / 6);
        return a_v * values[i] + localT_v * values[i + 1] + ((a_v * a_v * a_v - a_v) * m[i] + (localT_v * localT_v * localT_v - localT_v) * m[i + 1]) * h2_6_v;
    }

    pub inline fn splineEvalSimdPrecalc(comptime T: type, comptime len: usize, values: *const [4][len]T, m: *const [4][len]T, precalc: PrecalcData(T, true, len)) @Vector(len, T) {
        const i: usize = precalc.i;
        const localT = precalc.localT;
        const h2_6_v: @Vector(len, T) = comptime @splat(2 / 6);
        return precalc.a_v * values[i] + localT * values[i + 1] + ((precalc.a_v_precalc) * m[i] + (precalc.localT_precalc) * m[i + 1]) * h2_6_v;
    }

    pub fn PrecalcData(T: type, isSimd: bool, len: ?usize) type {
        std.debug.assert((isSimd and len != null) or (!isSimd and len == null));
        return struct {
            i: usize,
            localT: if (isSimd) @Vector(len.?, T) else T,
            localT_precalc: if (isSimd) @Vector(len.?, T) else T,
            a_v: if (isSimd) @Vector(len.?, T) else T,
            a_v_precalc: if (isSimd) @Vector(len.?, T) else T,
        };
    }

    pub fn Precalc(comptime Type: type, t: Type) PrecalcData(Type, false, null) {
        const one_third: Type = comptime 1.0 / 3.0;
        const i: usize = @intFromFloat(@min(@floor(t / one_third), 2));
        const localT = t * 3.0 - @as(Type, @floatFromInt(i));
        const a_v = 1.0 - localT;
        return PrecalcData(Type, false, null){
            .i = i,
            .localT = localT,
            .localT_precalc = localT * localT * localT - localT,
            .a_v = a_v,
            .a_v_precalc = a_v * a_v * a_v - a_v,
        };
    }

    pub fn PrecalcSimd(comptime Type: type, comptime len: usize, t: Type) PrecalcData(Type, true, len) {
        const one_third: Type = comptime 1.0 / 3.0;
        const i: usize = @intFromFloat(@min(@floor(t / one_third), 2));
        const localT = t * 3.0 - @as(Type, @floatFromInt(i));
        const a_v = 1.0 - localT;
        return PrecalcData(Type, true, len){
            .i = i,
            .localT = @splat(localT),
            .localT_precalc = @splat(localT * localT * localT - localT),
            .a_v = @splat(a_v),
            .a_v_precalc = @splat(a_v * a_v * a_v - a_v),
        };
    }

    pub inline fn splineEvalSimdComptimeT(comptime T: type, comptime len: usize, values: *const [4][len]T, m: *const [4][len]T, comptime t: T) @Vector(len, T) {
        const i: usize = comptime @intFromFloat(@min(@floor(t * 3), 2));
        const localT: T = comptime t * 3.0 - @as(f32, @floatFromInt(i));
        const localT_v: @Vector(len, T) = comptime @splat(localT);
        const a_v: @Vector(len, T) = comptime @splat(1.0 - localT);
        const h2_6_v: @Vector(len, T) = comptime @splat(2 / 6);
        return a_v * values[i] + localT_v * values[i + 1] + ((comptime (a_v * a_v * a_v - a_v)) * m[i] + (comptime (localT_v * localT_v * localT_v - localT_v)) * m[i + 1]) * h2_6_v;
    }
};

test "speed" {
    var grid: [4][4][4]f32 = @splat(@splat(@splat(std.crypto.random.float(f32))));
    var rand = std.Random.DefaultPrng.init(0);
    // const random = rand.random();
    grid[0][2][3] = 43.0;
    var st = std.time.nanoTimestamp();
    var a: f32 = 0.0;
    const it = 8;
    // var temp2D: [4][4]f32 = undefined;
    ////  var valuesY: [4][4]f32 = undefined;
    //   var valuesX2d: [16][4]f32 = undefined;
    for (0..it) |_| {
        //  a += trilinearInterpolate(f32, &grid, 0, 0, 0);
    }
    a += @reduce(.Add, trilinearInterpolateBatch(it, f32, grid, @splat(0), @splat(0), @splat(0)));
    var et = std.time.nanoTimestamp();
    const elapsed1 = et - st;
    std.debug.print("trilinearInterpolate Elapsed time: {d} us, a: {d}\n", .{ @as(f128, @floatFromInt(elapsed1)) / std.time.ns_per_us, a });
    rand = std.Random.DefaultPrng.init(0);
    grid[0][2][3] = 43.0;
    st = std.time.nanoTimestamp();
    a = 0.0;
    var interpolator = NaturalCubicInterpolator3D.init(grid);
    // var temp2D: [4][4]f32 = undefined;
    ////  var valuesY: [4][4]f32 = undefined;
    //   var valuesX2d: [16][4]f32 = undefined;
    const prex = NaturalCubicInterpolator3D.PrecalcSimd(f32, 16, 0);
    const prey = NaturalCubicInterpolator3D.PrecalcSimd(f32, 4, 0);
    const prez = NaturalCubicInterpolator3D.Precalc(f32, 0);
    for (0..it) |_| {
        a += interpolator.samplePrecalc(prex, prey, prez);
    }

    et = std.time.nanoTimestamp();
    const elapsed2 = et - st;
    std.debug.print("new Elapsed time: {d} us, a: {d}\n", .{ @as(f128, @floatFromInt(elapsed2)) / std.time.ns_per_us, a });
    std.debug.print("speed increased by: {d} times\n", .{@as(f128, @floatFromInt(elapsed1)) / @as(f128, @floatFromInt(elapsed2))});
}
pub fn trilinearInterpolate(
    comptime Type: type,
    grid: *[4][4][4]Type,
    xyz: @Vector(3, Type),
) Type {
    // Scale from [0,1] to [0,3]
    const gx = xyz[0] * 3.0;
    const gy = xyz[1] * 3.0;
    const gz = xyz[2] * 3.0;

    // Cube indices [0..2]
    const i: usize = @intFromFloat(@floor(@min(gx, 2.9999)));
    const j: usize = @intFromFloat(@floor(@min(gy, 2.9999)));
    const k: usize = @intFromFloat(@floor(@min(gz, 2.9999)));

    // Local position inside cube
    const tx = gx - @as(Type, @floatFromInt(i));
    const ty = gy - @as(Type, @floatFromInt(j));
    const tz = gz - @as(Type, @floatFromInt(k));

    // Interpolation weights (precompute tensor product)
    const wx: @Vector(2, Type) = .{ 1.0 - tx, tx };
    const wy: @Vector(2, Type) = .{ 1.0 - ty, ty };
    const wz: @Vector(2, Type) = .{ 1.0 - tz, tz };

    // Gather 8 cube corners into SIMD vector
    const corners: @Vector(8, Type) = .{
        grid[i][j][k],
        grid[i + 1][j][k],
        grid[i][j + 1][k],
        grid[i + 1][j + 1][k],
        grid[i][j][k + 1],
        grid[i + 1][j][k + 1],
        grid[i][j + 1][k + 1],
        grid[i + 1][j + 1][k + 1],
    };

    // SIMD weights (tensor product expanded directly)
    const weights: @Vector(8, Type) = .{
        wx[0] * wy[0] * wz[0],
        wx[1] * wy[0] * wz[0],
        wx[0] * wy[1] * wz[0],
        wx[1] * wy[1] * wz[0],
        wx[0] * wy[0] * wz[1],
        wx[1] * wy[0] * wz[1],
        wx[0] * wy[1] * wz[1],
        wx[1] * wy[1] * wz[1],
    };

    // Final interpolation = dot product
    return @reduce(.Add, corners * weights);
}

pub fn trilinearInterpolateBatch(comptime N: usize, comptime Type: type, grid: [4][4][4]Type, comptime xs: [N]Type, ys: [N]Type, comptime zs: [N]Type) @Vector(N, Type) {
    var out: [N]Type = comptime undefined;

    const one: Type = comptime 1.0;
    const three: Type = comptime 3.0;
    const max_index_f: Type = comptime 2.9999;

    inline for (0..N) |idx| {
        const x = comptime xs[idx];
        const y = ys[idx];
        const z = comptime zs[idx];

        // scale into [0..3]
        const gx = comptime x * three;
        const gy = y * three;
        const gz = comptime z * three;

        // compute integer cube indices in [0..2]
        const i: usize = comptime @intFromFloat(@floor(@min(gx, max_index_f)));
        const j: usize = @intFromFloat(@floor(@min(gy, max_index_f)));
        const k: usize = comptime @intFromFloat(@floor(@min(gz, max_index_f)));

        // local coordinates [0,1]
        const tx = gx - comptime @as(Type, @floatFromInt(i));
        const ty = gy - @as(Type, @floatFromInt(j));
        const tz = gz - comptime @as(Type, @floatFromInt(k));

        // interpolation weights
        const wx0 = comptime one - tx;
        const wx1 = comptime tx;
        const wy0 = one - ty;
        const wy1 = ty;
        const wz0 = comptime one - tz;
        const wz1 = comptime tz;
        const weights: @Vector(8, Type) = .{
            (comptime wx0 * wz0) * wy0,
            (comptime wx1 * wz0) * wy0,
            (comptime wx0 * wz0) * wy1,
            (comptime wx1 * wz0) * wy1,
            (comptime wx0 * wz1) * wy0,
            (comptime wx1 * wz1) * wy0,
            (comptime wx0 * wz1) * wy1,
            (comptime wx1 * wz1) * wy1,
        };
        const corners: @Vector(8, Type) = .{
            grid[i][j][k],
            grid[i + 1][j][k],
            grid[i][j + 1][k],
            grid[i + 1][j + 1][k],
            grid[i][j][k + 1],
            grid[i + 1][j][k + 1],
            grid[i][j + 1][k + 1],
            grid[i + 1][j + 1][k + 1],
        };
        // final dot product
        out[idx] = @reduce(.Add, corners * weights);
    }
    return out;
}
