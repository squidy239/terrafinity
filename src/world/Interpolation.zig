const std = @import("std");

/// Creates a SIMD N-linear interpolator type over a coarse control grid.
///
/// `dims[k]` is the control-grid density along axis `k`, `samples[k]` the
/// number of samples along it. Axis 0 is stored along the SIMD lanes, so
/// interpolation along it is one vector operation per remaining-axis slice.
/// The per-sample lerp factors are precomputed at compile time; axes 1..N-1
/// use the FMA-friendly `v0 + t * (v1 - v0)` form, axis 0 uses masked vector
/// multiplies, and every stage runs fused inside the loop of the stage before
/// it, so no intermediate result round-trips through memory.
///
/// Layout conventions (identical to the hand-written 3D version):
///   `Grid`    = `[dims[N-1]]...[dims[1]][dims[0]]Float`  (axis 0 innermost)
///   `Samples` = `[samples[1]]...[samples[N-1]]@Vector(samples[0], Float)`
pub fn MultilinearInterpolator(
    comptime Float: type,
    comptime N: usize,
    comptime dims: [N]usize,
    comptime samples: [N]usize,
) type {
    if (@typeInfo(Float) != .float) @compileError("Float must be a floating-point type");
    if (N == 0) @compileError("need at least one dimension");
    for (dims) |d| if (d < 2) @compileError("grid densities must be at least 2");
    for (samples) |s| if (s < 1) @compileError("sample counts must be at least 1");

    return struct {
        const Self = @This();

        /// A vector of samples along axis 0.
        pub const Lane = @Vector(samples[0], Float);
        /// A vector of control points along axis 0.
        pub const Row = @Vector(dims[0], Float);

        /// Control points / samples left once axes `< from` are reduced away.
        fn gridCount(comptime from: usize) usize {
            var p: usize = 1;
            for (from..N) |i| p *= dims[i];
            return p;
        }
        fn sampleCount(comptime from: usize) usize {
            var p: usize = 1;
            for (from..N) |i| p *= samples[i];
            return p;
        }

        /// Number of control-point rows: one per coordinate of axes 1..N-1.
        pub const rows = gridCount(1);
        pub const total_samples = sampleCount(1);

        pub const Grid = blk: {
            var T: type = [dims[0]]Float;
            for (1..N) |i| T = [dims[i]]T;
            break :blk T;
        };

        pub const Samples = blk: {
            var T: type = Lane;
            var i: usize = N;
            while (i > 1) : (i -= 1) T = [samples[i - 1]]T;
            break :blk T;
        };

        /// Row stride of each axis; axis 1 is fastest-varying. `[0]` unused.
        const row_stride = blk: {
            var s: [N]usize = undefined;
            s[0] = 0;
            var acc: usize = 1;
            for (1..N) |d| {
                s[d] = acc;
                acc *= dims[d];
            }
            break :blk s;
        };

        /// Control-point grid: axis 0 along the SIMD lanes, the remaining axes
        /// flattened with axis 1 fastest-varying.
        cells: [rows]Row,

        pub fn init(grid: Grid) Self {
            var self: Self = undefined;
            var pos: usize = 0;
            collectRows(Grid, &grid, &self.cells, &pos);
            return self;
        }

        /// Collects the `[dims[0]]Float` control rows of a nested grid, in memory order.
        fn collectRows(comptime T: type, value: *const T, cells: []Row, pos: *usize) void {
            const info = @typeInfo(T);
            if (info == .array and @typeInfo(info.array.child) != .float) {
                for (value) |*elem| collectRows(info.array.child, elem, cells, pos);
            } else {
                cells[pos.*] = value.*;
                pos.* += 1;
            }
        }

        fn rowIndex(coord: [N]usize) usize {
            var r: usize = 0;
            inline for (1..N) |d| r += coord[d] * row_stride[d];
            return r;
        }

        /// The control point at integer grid coordinates.
        pub fn at(self: *const Self, coord: [N]usize) Float {
            const row: [dims[0]]Float = self.cells[rowIndex(coord)];
            return row[coord[0]];
        }

        /// Sample at normalized coordinates in [0, 1]^N.
        ///
        /// Association note: this accumulates per-corner weights
        /// (`w * w0 * corner`, the expanded `(1-f)*a + f*b` product form),
        /// while `reduceLaneAxis`/`reduceAxis` evaluate the FMA-friendly
        /// `a + f*(b-a)` lane form. The two are algebraically identical but
        /// reassociated, so floating-point results can differ by a few ULPs;
        /// the `sampleGrid` cross-check tests compare with an absolute
        /// tolerance for exactly this reason. Neither form is bit-level
        /// reference; do not tighten those tests to exact equality without
        /// re-associating one path to match the other.
        ///
        /// Tolerances absorb the numeric gap, not exact-threshold branches:
        /// an input landing exactly on a downstream comparison (blade
        /// `scaled_f >= 1` in `fillBlades`, `slope <= 0` in
        /// `bladeHeightScale`, cave `value < threshold` in
        /// `carveCavesApply`, snow cover against `snow_line + gain * slope`
        /// in `randGround`, all fed via `sampleGrid`) can flip sides versus
        /// the pre-patch order.
        pub fn sample(self: *const Self, t: [N]Float) Float {
            const corners = 1 << N;
            var cell: [N]usize = undefined;
            var frac: [N]Float = undefined;
            inline for (0..N) |d| {
                cell[d] = cellOf(Float, dims[d], t[d]);
                frac[d] = fracOf(Float, dims[d], t[d]);
            }

            var result: Float = 0;
            inline for (0..corners) |corner| {
                var w: Float = 1;
                var row: usize = 0;
                inline for (1..N) |d| {
                    const o = (corner >> @intCast(d)) & 1;
                    w *= if (o == 0) 1.0 - frac[d] else frac[d];
                    row += (cell[d] + o) * row_stride[d];
                }
                const o0 = corner & 1;
                const w0: Float = if (o0 == 0) 1.0 - frac[0] else frac[0];
                const cell_row: [dims[0]]Float = self.cells[row];
                result += w * w0 * cell_row[cell[0] + o0];
            }
            return result;
        }

        /// Reduce one control-point row along axis 0 into `samples[0]` lanes.
        ///
        /// Association note: evaluates `a + f*(b-a)` (FMA-friendly), reassociated
        /// relative to `sample`'s corner-weight product form. The forms agree
        /// algebraically and differ by a few ULPs in floating point, which the
        /// `sampleGrid` cross-check tolerances absorb. Kept as-is deliberately:
        /// re-associating to match `sample` bit-for-bit would cost the FMA.
        inline fn reduceLaneAxis(self: *const Self, row: usize) Lane {
            @setFloatMode(.optimized);
            const lerp = comptime computeAxisLerpData(Float, dims[0], samples[0]);
            const points = self.cells[row];
            var acc: Lane = undefined;
            inline for (0..samples[0]) |i| {
                const c = lerp.cell[i];
                const f = lerp.frac[i];
                acc[i] = points[c] + f * (points[c + 1] - points[c]);
            }
            return acc;
        }

        /// Reduce `axis` (the innermost index of `in`) and recurse; the last
        /// axis writes straight into `out`, so it is fused with its parent.
        ///
        /// Same association as `reduceLaneAxis` (`a + f*(b-a)`); see `sample`
        /// for why this differs by a few ULPs from the scalar product form.
        fn reduceAxis(
            comptime axis: usize,
            in: *const [gridCount(axis)]Lane,
            out: []Lane,
        ) void {
            @setFloatMode(.optimized);
            const lerp = comptime computeAxisLerpData(Float, dims[axis], samples[axis]);
            for (0..samples[axis]) |i| {
                const c = lerp.cell[i];
                const f: Lane = @splat(lerp.frac[i]);
                if (axis == N - 1) {
                    out[i] = in[c] + f * (in[c + 1] - in[c]);
                } else {
                    const stride = dims[axis];
                    const inner = comptime gridCount(axis + 1);
                    const chunk = sampleCount(axis + 1);
                    var buf: [inner]Lane = undefined;
                    for (0..inner) |j| {
                        const lo = in[j * stride + c];
                        const hi = in[j * stride + c + 1];
                        buf[j] = lo + f * (hi - lo);
                    }
                    reduceAxis(axis + 1, &buf, out[i * chunk ..][0..chunk]);
                }
            }
        }

        /// Interpolate a regular sample grid covering the unit cube.
        pub fn sampleGrid(self: *const Self) Samples {
            @setFloatMode(.optimized);
            var result: Samples = undefined;
            // result and a flat lane array share one contiguous layout; a flat
            // view lets reduceAxis write each lane in place, with no extra copy.
            const out: *[total_samples]Lane = @ptrCast(&result);

            var stage: [rows]Lane = undefined;
            for (0..rows) |r| stage[r] = self.reduceLaneAxis(r);

            if (N == 1) {
                out[0] = stage[0];
            } else {
                reduceAxis(1, &stage, out);
            }
            return result;
        }
    };
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

/// Fills a nested control-grid array with deterministic pseudo-random values.
fn randGrid(comptime G: type) G {
    var grid: G = undefined;
    var rng = std.Random.DefaultPrng.init(1234);
    fillRand(G, &grid, rng.random());
    return grid;
}

/// Writes pseudo-random values into a nested array of floats, at any depth.
fn fillRand(comptime T: type, value: *T, rand: std.Random) void {
    const info = @typeInfo(T);
    if (info == .array) {
        for (value) |*elem| fillRand(info.array.child, elem, rand);
    } else if (info == .float) {
        value.* = rand.float(T) * 2.0 - 1.0;
    } else {
        @compileError("control grids are nested arrays of floats");
    }
}

/// The first scalar of a nested grid/sample array, whatever its depth.
fn firstScalar(comptime Float: type, value: anytype) Float {
    const T = @TypeOf(value);
    if (@typeInfo(T) == .array) return firstScalar(Float, value[0]);
    if (@typeInfo(T) == .vector) return value[0];
    return value;
}

/// Renders `[n0]x[n1]x...` for an axis size list, at comptime.
fn axisLabel(comptime sizes: []const usize) []const u8 {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    inline for (sizes, 0..) |s, i| {
        if (i != 0) {
            buf[pos] = 'x';
            pos += 1;
        }
        var tmp: [20]u8 = undefined;
        const text = std.fmt.bufPrint(&tmp, "{d}", .{s}) catch unreachable;
        @memcpy(buf[pos..][0..text.len], text);
        pos += text.len;
    }
    const out: [pos]u8 = buf[0..pos].*;
    return &out;
}

fn benchGrid(
    comptime Float: type,
    comptime N: usize,
    comptime dims: [N]usize,
    comptime samples: [N]usize,
    comptime iterations: usize,
    io: std.Io,
) void {
    const Grid = MultilinearInterpolator(Float, N, dims, samples);
    const volume: usize = comptime blk: {
        var v: usize = 1;
        for (samples) |s| v *= s;
        break :blk v;
    };
    const samples_per_pass: f64 = @floatFromInt(iterations * volume);
    const interp = Grid.init(randGrid(Grid.Grid));

    var sink: Float = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        sink += firstScalar(Float, interp.sampleGrid());
    }
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    const ns_per_sample = @as(f64, @floatFromInt(start.durationTo(end).raw.toNanoseconds())) / samples_per_pass;
    std.debug.print(
        "{s} -> {s}: {d:.3} ns/sample, {d:.3} us per pass (sink {d})\n",
        .{
            comptime axisLabel(&dims),
            comptime axisLabel(&samples),
            ns_per_sample,
            ns_per_sample * @as(f64, @floatFromInt(volume)) * @as(f64, @floatFromInt(iterations)) / 1000.0,
            sink,
        },
    );
}

test "sample returns grid points exactly" {
    const Grid = MultilinearInterpolator(f32, 3, .{ 4, 6, 5 }, .{ 8, 8, 8 });
    const grid = randGrid(Grid.Grid);
    const interp = Grid.init(grid);
    inline for (0..5) |z| {
        inline for (0..6) |y| {
            inline for (0..4) |x| {
                const expected = grid[z][y][x];
                const actual = interp.sample(.{
                    @as(f32, @floatFromInt(x)) / 3.0,
                    @as(f32, @floatFromInt(y)) / 5.0,
                    @as(f32, @floatFromInt(z)) / 4.0,
                });
                try std.testing.expectEqual(expected, actual);
            }
        }
    }
}

test "sampleGrid matches scalar sample" {
    inline for (.{
        .{ .Float = f32, .dims = [3]usize{ 8, 8, 8 }, .tol = 1e-4 },
        .{ .Float = f64, .dims = [3]usize{ 8, 16, 8 }, .tol = 1e-12 },
    }) |cfg| {
        const Grid = MultilinearInterpolator(cfg.Float, 3, cfg.dims, .{ 16, 16, 16 });
        const interp = Grid.init(randGrid(Grid.Grid));
        const samples = interp.sampleGrid();
        for (0..16) |y| {
            for (0..16) |z| {
                const row: [16]cfg.Float = samples[y][z];
                for (0..16) |x| {
                    const expected = interp.sample(.{
                        @as(cfg.Float, @floatFromInt(x)) / 16.0,
                        @as(cfg.Float, @floatFromInt(y)) / 16.0,
                        @as(cfg.Float, @floatFromInt(z)) / 16.0,
                    });
                    try std.testing.expectApproxEqAbs(expected, row[x], cfg.tol);
                }
            }
        }
    }
}

test "sampleGrid reproduces linear fields" {
    const Grid = MultilinearInterpolator(f32, 3, .{ 8, 16, 8 }, .{ 32, 32, 32 });
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
