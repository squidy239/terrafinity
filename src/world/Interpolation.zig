const std = @import("std");
const ChunkSize = @import("Chunk.zig").ChunkSize;

/// Creates a SIMD trilinear interpolator type over a coarse control grid.
///
/// `Float` is the floating-point type of the grid and samples; `gx`/`gy`/`gz`
/// are the grid densities along each axis, `nx`/`ny`/`nz` the number of
/// samples along each axis. The grid is stored with X along the SIMD lanes,
/// so interpolation along X is one vector operation per (y, z) slice. The
/// per-sample lerp factors are precomputed at compile time; Y and Z use the
/// FMA-friendly `v0 + t * (v1 - v0)` form, X uses masked vector multiplies,
/// and the final stage runs fused with the stage before it so no intermediate
/// result round-trips through memory.
pub fn TrilinearInterpolator3D(
    comptime Float: type,
    comptime gx: usize,
    comptime gy: usize,
    comptime gz: usize,
    comptime nx: usize,
    comptime ny: usize,
    comptime nz: usize,
) type {
    if (@typeInfo(Float) != .float) @compileError("Float must be a floating-point type");
    if (gx < 2 or gy < 2 or gz < 2) @compileError("grid densities must be at least 2");

    const weights_x = computeAxisWeights(Float, gx, nx);
    const lerp_y = computeAxisLerpData(Float, gy, ny);
    const lerp_z = computeAxisLerpData(Float, gz, nz);

    return struct {
        const Self = @This();

        /// Control-point grid, X along the SIMD lane dimension.
        grid: [gz][gy]@Vector(gx, Float),

        pub fn init(grid: [gz][gy][gx]Float) Self {
            var self: Self = undefined;
            for (0..gz) |z| {
                for (0..gy) |y| {
                    self.grid[z][y] = grid[z][y];
                }
            }
            return self;
        }

        /// Sample at normalized coordinates in [0, 1].
        pub fn sample(self: *const Self, tx: Float, ty: Float, tz: Float) Float {
            const cx = cellOf(Float, gx, tx);
            const cy = cellOf(Float, gy, ty);
            const cz = cellOf(Float, gz, tz);
            const fx = fracOf(Float, gx, tx);
            const fy = fracOf(Float, gy, ty);
            const fz = fracOf(Float, gz, tz);

            var result: Float = 0;
            inline for (0..2) |oz| {
                inline for (0..2) |oy| {
                    const row: [gx]Float = self.grid[cz + oz][cy + oy];
                    const wy: Float = if (oy == 0) 1.0 - fy else fy;
                    const wz: Float = if (oz == 0) 1.0 - fz else fz;
                    inline for (0..2) |ox| {
                        const wx: Float = if (ox == 0) 1.0 - fx else fx;
                        result += wx * wy * wz * row[cx + ox];
                    }
                }
            }
            return result;
        }

        /// Interpolate a regular `nx` by `ny` by `nz` sample grid covering the
        /// unit cube. Row `[y][z]` is a vector of `nx` samples along X.
        pub fn sampleGrid(self: *const Self) [ny][nz]@Vector(nx, Float) {
            @setFloatMode(.optimized);
            var after_x: [gz][gy]@Vector(nx, Float) = undefined;
            for (0..gz) |cz| {
                for (0..gy) |cy| {
                    var acc: @Vector(nx, Float) = @splat(0);
                    const row = self.grid[cz][cy];
                    inline for (0..gx - 1) |cell| {
                        acc += weights_x.lo[cell] * @as(@Vector(nx, Float), @splat(row[cell]));
                        acc += weights_x.hi[cell] * @as(@Vector(nx, Float), @splat(row[cell + 1]));
                    }
                    after_x[cz][cy] = acc;
                }
            }

            var result: [ny][nz]@Vector(nx, Float) = undefined;
            for (0..ny) |y| {
                const cy = lerp_y.cell[y];
                const fy = @as(@Vector(nx, Float), @splat(lerp_y.frac[y]));
                var y_lerp: [gz]@Vector(nx, Float) = undefined;
                for (0..gz) |cz| {
                    y_lerp[cz] = after_x[cz][cy] + fy * (after_x[cz][cy + 1] - after_x[cz][cy]);
                }
                for (0..nz) |z| {
                    const cz = lerp_z.cell[z];
                    const fz = @as(@Vector(nx, Float), @splat(lerp_z.frac[z]));
                    result[y][z] = y_lerp[cz] + fz * (y_lerp[cz + 1] - y_lerp[cz]);
                }
            }
            return result;
        }
    };
}

fn AxisWeights(comptime Float: type, comptime g: usize, comptime n: usize) type {
    return struct {
        lo: [g - 1][n]Float,
        hi: [g - 1][n]Float,
    };
}

/// For each grid cell, the lerp weights of the samples that land in it; all
/// other lanes are zero. Sample `i` has coordinate `i / n` along the axis.
fn computeAxisWeights(comptime Float: type, comptime g: usize, comptime n: usize) AxisWeights(Float, g, n) {
    @setEvalBranchQuota(10_000);
    var weights: AxisWeights(Float, g, n) = undefined;
    inline for (0..g - 1) |cell| {
        var lo: [n]Float = @splat(0);
        var hi: [n]Float = @splat(0);
        for (0..n) |i| {
            const scaled = @as(Float, @floatFromInt(i * (g - 1))) / @as(Float, @floatFromInt(n));
            const sample_cell: usize = @intFromFloat(scaled);
            if (sample_cell == cell) {
                const frac = scaled - @as(Float, @floatFromInt(sample_cell));
                lo[i] = 1.0 - frac;
                hi[i] = frac;
            }
        }
        weights.lo[cell] = lo;
        weights.hi[cell] = hi;
    }
    return weights;
}

fn AxisLerpData(comptime Float: type, comptime n: usize) type {
    return struct {
        cell: [n]usize,
        frac: [n]Float,
    };
}

/// The grid cell each sample falls in, and its lerp fraction within it.
fn computeAxisLerpData(comptime Float: type, comptime g: usize, comptime n: usize) AxisLerpData(Float, n) {
    const scaled = std.simd.iota(Float, n) * @as(@Vector(n, Float), @splat(@as(Float, @floatFromInt(g - 1)) / @as(Float, @floatFromInt(n))));
    const cells: @Vector(n, usize) = @intFromFloat(scaled);
    return .{
        .cell = @as([n]usize, cells),
        .frac = @as([n]Float, scaled - @as(@Vector(n, Float), @floatFromInt(cells))),
    };
}

fn cellOf(comptime Float: type, comptime g: usize, t: Float) usize {
    return @intFromFloat(@min(t * @as(Float, @floatFromInt(g - 1)), @as(Float, @floatFromInt(g - 2))));
}

fn fracOf(comptime Float: type, comptime g: usize, t: Float) Float {
    const scaled = t * @as(Float, @floatFromInt(g - 1));
    return scaled - @as(Float, @floatFromInt(cellOf(Float, g, t)));
}

fn randGrid(comptime Float: type, comptime gx: usize, comptime gy: usize, comptime gz: usize) [gz][gy][gx]Float {
    var grid: [gz][gy][gx]Float = undefined;
    var rng = std.Random.DefaultPrng.init(1234);
    const rand = rng.random();
    for (&grid) |*plane| {
        for (plane) |*row| {
            for (row) |*value| {
                value.* = rand.float(Float) * 2.0 - 1.0;
            }
        }
    }
    return grid;
}

test "sample returns grid points exactly" {
    const Grid = TrilinearInterpolator3D(f32, 4, 6, 5, 8, 8, 8);
    const interp = Grid.init(randGrid(f32, 4, 6, 5));
    inline for (0..5) |z| {
        inline for (0..6) |y| {
            inline for (0..4) |x| {
                const expected = interp.grid[z][y][x];
                const actual = interp.sample(
                    @as(f32, @floatFromInt(x)) / 3.0,
                    @as(f32, @floatFromInt(y)) / 5.0,
                    @as(f32, @floatFromInt(z)) / 4.0,
                );
                try std.testing.expectEqual(expected, actual);
            }
        }
    }
}

test "sampleGrid matches scalar sample" {
    const Grid = TrilinearInterpolator3D(f32, 8, 8, 8, 16, 16, 16);
    const interp = Grid.init(randGrid(f32, 8, 8, 8));
    const samples = interp.sampleGrid();
    for (0..16) |y| {
        for (0..16) |z| {
            const row: [16]f32 = samples[y][z];
            for (0..16) |x| {
                const expected = interp.sample(
                    @as(f32, @floatFromInt(x)) / 16.0,
                    @as(f32, @floatFromInt(y)) / 16.0,
                    @as(f32, @floatFromInt(z)) / 16.0,
                );
                try std.testing.expectApproxEqAbs(expected, row[x], 1e-4);
            }
        }
    }
}

test "f64 asymmetric grid density matches scalar sample" {
    const Grid = TrilinearInterpolator3D(f64, 8, 16, 8, 16, 16, 16);
    const interp = Grid.init(randGrid(f64, 8, 16, 8));
    const samples = interp.sampleGrid();
    for (0..16) |y| {
        for (0..16) |z| {
            const row: [16]f64 = samples[y][z];
            for (0..16) |x| {
                const expected = interp.sample(
                    @as(f64, @floatFromInt(x)) / 16.0,
                    @as(f64, @floatFromInt(y)) / 16.0,
                    @as(f64, @floatFromInt(z)) / 16.0,
                );
                try std.testing.expectApproxEqAbs(expected, row[x], 1e-12);
            }
        }
    }
}

test "sampleGrid reproduces linear fields" {
    const Grid = TrilinearInterpolator3D(f32, 8, 16, 8, 32, 32, 32);
    var grid: [8][16][8]f32 = undefined;
    for (0..8) |z| {
        for (0..16) |y| {
            for (0..8) |x| {
                grid[z][y][x] = 0.5 * @as(f32, @floatFromInt(x)) - 0.25 * @as(f32, @floatFromInt(y)) + 0.125 * @as(f32, @floatFromInt(z));
            }
        }
    }
    const interp = Grid.init(grid);
    const samples = interp.sampleGrid();
    for (0..32) |y| {
        for (0..32) |z| {
            const row: [32]f32 = samples[y][z];
            for (0..32) |x| {
                const tx = @as(f32, @floatFromInt(x)) / 32.0;
                const ty = @as(f32, @floatFromInt(y)) / 32.0;
                const tz = @as(f32, @floatFromInt(z)) / 32.0;
                const expected = 3.5 * tx - 3.75 * ty + 0.875 * tz;
                try std.testing.expectApproxEqAbs(expected, row[x], 1e-3);
            }
        }
    }
}

test "benchmark sampleGrid" {
    const iterations = if (@import("builtin").mode == .Debug) 100 else 2000;
    const io = std.testing.io;
    const samples_per_pass: f64 = @floatFromInt(iterations * ChunkSize * ChunkSize * ChunkSize);

    inline for (.{ .{ 4, 4, 4 }, .{ 8, 8, 8 }, .{ 16, 16, 16 }, .{ 8, 16, 8 } }) |density| {
        const Grid = TrilinearInterpolator3D(f32, density[0], density[1], density[2], ChunkSize, ChunkSize, ChunkSize);
        const interp = Grid.init(randGrid(f32, density[0], density[1], density[2]));

        var sink: f32 = 0;
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        for (0..iterations) |_| {
            const samples = interp.sampleGrid();
            sink += samples[0][0][0];
        }
        const end = std.Io.Clock.Timestamp.now(io, .awake);
        const ns_per_sample = @as(f64, @floatFromInt(start.durationTo(end).raw.toNanoseconds())) / samples_per_pass;
        std.debug.print("grid {d}x{d}x{d}: {d:.1} ns/sample, {d:.2} us per chunk (sink {d})\n", .{ density[0], density[1], density[2], ns_per_sample, ns_per_sample * @as(f64, @floatFromInt(ChunkSize * ChunkSize * ChunkSize)) / 1000.0, sink });
    }
}
