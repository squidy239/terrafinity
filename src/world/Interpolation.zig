const std = @import("std");
const builtin = @import("builtin");

/// SIMD N-linear interpolator over a coarse control grid.
/// Axis 0 lies along the SIMD lanes, so each lerp along axes 1 to N-1 computes `sample_counts[0]` samples in one vector operation.
/// `Points` is `[rows][dims[0]]Float`, with axis 1 the fastest-changing row axis. `Samples` is `[sample_counts[1]]...[sample_counts[N-1]]@Vector(sample_counts[0], Float)`.
pub fn MultilinearInterpolator(
    comptime Float: type,
    comptime N: usize,
    comptime dims: [N]usize,
    comptime sample_counts: [N]usize,
) type {
    if (@typeInfo(Float) != .float) @compileError("Float must be a floating-point type");
    if (N == 0) @compileError("N must be at least 1");
    for (dims) |size| if (size < 2) @compileError("each grid size in dims must be at least 2");
    for (sample_counts) |count| if (count < 1) @compileError("each sample count must be at least 1");

    return struct {
        const Self = @This();

        /// A vector of samples along axis 0.
        pub const Lane = @Vector(sample_counts[0], Float);
        /// Normalized coordinates in [0, 1]^N.
        pub const Coordinates = [N]Float;
        /// One row of axis-0 control points for each coordinate of axes 1 to N-1.
        pub const Points = [row_count][dims[0]]Float;
        /// Axis 1 is outermost.
        pub const Samples = blk: {
            var T: type = Lane;
            for (1..N) |i| T = [sample_counts[N - i]]T;
            break :blk T;
        };

        const row_count = product(dims[1..]);
        const lane_count = product(sample_counts[1..]);

        points: Points,

        /// A caller with a flat array of control points passes `@bitCast(flat)`.
        pub fn init(points: Points) Self {
            return .{ .points = points };
        }

        /// Interpolates at normalized coordinates in [0, 1]^N.
        /// This sums corner-weight products in a different operation order than `sampleGrid`, so tests that compare the two use an absolute tolerance.
        pub fn sample(self: *const Self, t: Coordinates) Float {
            const flat = std.mem.bytesAsSlice(Float, std.mem.asBytes(&self.points));
            var result: Float = 0;
            inline for (0..1 << N) |corner| {
                var weight: Float = 1;
                var index: usize = 0;
                inline for (t, dims, 0..) |coordinate, size, axis| {
                    std.debug.assert(coordinate >= 0 and coordinate <= 1);
                    const scaled = coordinate * (size - 1);
                    const lower: usize = @intFromFloat(@min(scaled, size - 2));
                    const fraction = scaled - @as(Float, @floatFromInt(lower));
                    const offset = (corner >> axis) & 1;
                    weight *= if (offset == 0) 1 - fraction else fraction;
                    index += (lower + offset) * comptime product(dims[0..axis]);
                }
                result += weight * flat[index];
            }
            return result;
        }

        /// Lerps one row of control points along axis 0 into one lane for each sample.
        fn reduceLaneAxis(row: [dims[0]]Float) Lane {
            const table = comptime axisLerpTable(Float, dims[0], sample_counts[0]);
            var lanes: Lane = undefined;
            inline for (table.lower, table.fraction, 0..) |index, fraction, i| {
                lanes[i] = std.math.lerp(row[index], row[index + 1], fraction);
            }
            return lanes;
        }

        /// Lerps `in` along `axis`, then reduces the next axis. The last axis writes directly into `out`.
        fn reduceAxis(
            comptime axis: usize,
            in: *const [product(dims[axis..])]Lane,
            out: *[product(sample_counts[axis..])]Lane,
        ) void {
            const table = comptime axisLerpTable(Float, dims[axis], sample_counts[axis]);
            const chunk = comptime product(sample_counts[axis + 1 ..]);
            for (table.lower, table.fraction, 0..) |index, fraction, i| {
                const f: Lane = @splat(fraction);
                if (axis == N - 1) {
                    out[i] = std.math.lerp(in[index], in[index + 1], f);
                    continue;
                }
                var next: [product(dims[axis + 1 ..])]Lane = undefined;
                for (&next, 0..) |*dest, j| {
                    const pair = in[j * dims[axis] + index ..][0..2];
                    dest.* = std.math.lerp(pair[0], pair[1], f);
                }
                reduceAxis(axis + 1, &next, out[i * chunk ..][0..chunk]);
            }
        }

        /// Interpolates a regular sample grid. Sample i of an axis sits at t = i / count, so t = 1 is the first sample of the next chunk.
        pub fn sampleGrid(self: *const Self) Samples {
            var result: Samples = undefined;
            // `Samples` has the same layout as a flat array of lanes, so `reduceAxis` writes the lanes in place.
            const out = std.mem.bytesAsValue([lane_count]Lane, std.mem.asBytes(&result));

            var stage: [row_count]Lane = undefined;
            // A by-value capture of `self.points` copies the whole grid, which costs ~20% at 32^3.
            for (&stage, &self.points) |*lane, *row| lane.* = reduceLaneAxis(row.*);

            if (N == 1) out.* = stage else reduceAxis(1, &stage, out);
            return result;
        }
    };
}

/// The product of the grid sizes. An empty list gives 1.
fn product(comptime sizes: []const usize) usize {
    var result: usize = 1;
    for (sizes) |size| result *= size;
    return result;
}

/// For `count` samples at t = i / count on a grid of `size` points: the lower grid index of each sample and its lerp fraction.
fn axisLerpTable(comptime Float: type, comptime size: usize, comptime count: usize) struct { lower: [count]usize, fraction: [count]Float } {
    var lower: [count]usize = undefined;
    var fraction: [count]Float = undefined;
    for (&lower, &fraction, 0..) |*index, *f, i| {
        const scaled = i * (size - 1);
        index.* = scaled / count;
        f.* = @as(Float, @floatFromInt(scaled % count)) / count;
    }
    return .{ .lower = lower, .fraction = fraction };
}

const test_seed = 1234;

/// Returns control points for `Interpolator` with deterministic pseudo-random values in [-1, 1).
fn randomPoints(comptime Interpolator: type) Interpolator.Points {
    var points: Interpolator.Points = undefined;
    var prng: std.Random.DefaultPrng = .init(test_seed);
    const random = prng.random();
    for (&points) |*row| for (row) |*value| {
        value.* = random.float(@TypeOf(value.*)) * 2 - 1;
    };
    return points;
}

/// Walks `samples` from `axis` inward and compares each sample with `reference.sample(t)`.
fn expectSamples(reference: anytype, samples: anytype, t: anytype, comptime axis: usize) !void {
    const Float = @TypeOf(t[0]);
    if (@typeInfo(@TypeOf(samples)) == .vector) {
        const row: [@typeInfo(@TypeOf(samples)).vector.len]Float = samples;
        for (row, 0..) |actual, x| {
            t[0] = @as(Float, @floatFromInt(x)) / row.len;
            try std.testing.expectApproxEqAbs(reference.sample(t.*), actual, 1e-5);
        }
        return;
    }
    for (samples, 0..) |inner, i| {
        t[axis] = @as(Float, @floatFromInt(i)) / samples.len;
        try expectSamples(reference, inner, t, axis + 1);
    }
}

const benchmark_passes = if (builtin.mode == .debug) 100 else 2000;

/// Prints the time that `sampleGrid` takes per sample and per pass for one f32 grid shape.
fn benchmarkSampleGrid(comptime N: usize, comptime dims: [N]usize, comptime sample_counts: [N]usize, io: std.Io) void {
    const Interpolator = MultilinearInterpolator(f32, N, dims, sample_counts);
    const interpolator: Interpolator = .init(randomPoints(Interpolator));

    const start: std.Io.Timestamp = .now(io, .awake);
    for (0..benchmark_passes) |_| std.mem.doNotOptimizeAway(interpolator.sampleGrid());
    const elapsed = start.untilNow(io, .awake);

    const pass_ns = @as(f64, @floatFromInt(elapsed.nanoseconds)) / benchmark_passes;
    const samples_per_pass: f64 = comptime product(&sample_counts);
    std.debug.print("{any} -> {any}: {d:.3} ns/sample, {d:.3} us/pass\n", .{
        dims, sample_counts, pass_ns / samples_per_pass, pass_ns / std.time.ns_per_us,
    });
}

test {
    std.testing.refAllDecls(@This());
}

test "sample returns grid points exactly" {
    const Interpolator = MultilinearInterpolator(f32, 3, .{ 4, 6, 5 }, .{ 8, 8, 8 });
    const points = randomPoints(Interpolator);
    const interpolator: Interpolator = .init(points);
    // Grid point (x, y, z) sits at t = (x/3, y/5, z/4). The test is exact only because
    // each t * (size - 1) rounds back to the integer for these sizes.
    for (points, 0..) |row, r| for (row, 0..) |expected, x| {
        const coord: @Vector(3, f32) = .{ @floatFromInt(x), @floatFromInt(r % 6), @floatFromInt(r / 6) };
        try std.testing.expectEqual(expected, interpolator.sample(coord / @Vector(3, f32){ 3, 5, 4 }));
    };
}

test "sampleGrid matches sample" {
    // Covers 1D to 4D, f32 and f64, odd sizes, downsampling, and a single-lane axis 0.
    inline for (.{
        MultilinearInterpolator(f32, 3, .{ 8, 8, 8 }, .{ 16, 16, 16 }),
        MultilinearInterpolator(f64, 3, .{ 8, 16, 8 }, .{ 16, 16, 16 }),
        MultilinearInterpolator(f64, 1, .{5}, .{7}),
        MultilinearInterpolator(f64, 2, .{ 5, 3 }, .{ 7, 9 }),
        MultilinearInterpolator(f64, 2, .{ 9, 9 }, .{ 4, 3 }),
        MultilinearInterpolator(f64, 2, .{ 2, 3 }, .{ 1, 4 }),
        MultilinearInterpolator(f64, 4, .{ 4, 3, 4, 2 }, .{ 8, 5, 8, 3 }),
    }) |Interpolator| {
        const interpolator: Interpolator = .init(randomPoints(Interpolator));
        var t: Interpolator.Coordinates = undefined;
        try expectSamples(interpolator, interpolator.sampleGrid(), &t, 1);
    }
}

test "sampleGrid reproduces linear fields" {
    const Interpolator = MultilinearInterpolator(f32, 3, .{ 8, 16, 8 }, .{ 32, 32, 32 });
    // f(x, y, z) = 0.5x - 0.25y + 0.125z on grid points. In normalized coordinates the
    // slopes scale by (size - 1), so the expected field is 3.5u - 3.75v + 0.875w.
    var points: Interpolator.Points = undefined;
    for (&points, 0..) |*row, r| for (row, 0..) |*point, x| {
        const coord: @Vector(3, f32) = .{ @floatFromInt(x), @floatFromInt(r % 16), @floatFromInt(r / 16) };
        point.* = @reduce(.Add, coord * @Vector(3, f32){ 0.5, -0.25, 0.125 });
    };
    const linear_field = struct {
        fn sample(_: @This(), t: [3]f32) f32 {
            return 3.5 * t[0] - 3.75 * t[1] + 0.875 * t[2];
        }
    };
    const interpolator: Interpolator = .init(points);
    var t: [3]f32 = undefined;
    try expectSamples(linear_field{}, interpolator.sampleGrid(), &t, 1);
}

test "benchmark sampleGrid" {
    // Keep each sample count at 32^3 or less. A larger grid makes `sampleGrid`
    // return a `Samples` value of several MiB, which overflows the Debug test stack.
    // Each shape is `.{ dims, sample_counts }`.
    inline for (.{
        .{ .{ 4, 4 }, .{ 32, 32 } },
        .{ .{ 8, 8 }, .{ 128, 128 } },
        .{ .{ 4, 4, 4 }, .{ 32, 32, 32 } },
        .{ .{ 32, 32, 32 }, .{ 32, 32, 32 } },
        .{ .{ 8, 16, 8 }, .{ 32, 32, 32 } },
        .{ .{ 4, 4, 4, 4 }, .{ 8, 8, 8, 8 } },
    }) |shape| benchmarkSampleGrid(shape[0].len, shape[0], shape[1], std.testing.io);
}
