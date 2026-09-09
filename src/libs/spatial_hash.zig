const std = @import("std");
const ConcurrentHashMap = @import("ConcurrentHashMap.zig").ConcurrentHashMap;

/// Exact hierarchical spatial hash over AABBs (a hash-mapped linear octree).
///
/// Each box is stored once at its home level `ceil(log2(extent))` in the cell
/// containing its minimum corner, plus one replica in every coarser ancestor
/// cell. A query therefore never descends into fine levels: it scans its own
/// level (which holds every smaller box via replicas) and each coarser level
/// that currently holds boxes. Empty space costs hash lookups, never cell
/// enumeration, so a 1e12 query over a sparse field stays flat.
///
/// Bounds (`max_levels` is a fixed 48): insert/remove/move cost O(levels) hash
/// ops; a query visits at most 64 cells per involved level plus one constant-
/// time narrowphase test per entry found there. Per-cell entry lists are
/// output-sensitive: adversarial clustering inside one cell degrades that
/// cell linearly. Updates hold one bucket lock at a time and are linearizable
/// per cell, not atomic across cells; concurrent queries may observe a move
/// mid-update. Concurrent mutations of the SAME id are unsound (the
/// index-then-chain sequence can double-detach and corrupt counts): partition
/// mutations by id across threads, as across any other shared structure.
/// A failed `upsert` leaves no orphans and no stale index: the id ends absent,
/// so retrying the `upsert` heals the map. `move` is remove-then-upsert and
/// shares that contract: if the upsert half fails, the id is absent.
pub fn SpatialHash(comptime bucket_amount: u32) type {
    return struct {
        const Map = @This();
        pub const Id = u64;
        pub const Vec = @Vector(3, f64);
        pub const Aabb = struct { min: Vec, max: Vec };
        /// A copy of the stored box, so hits stay valid without holding locks.
        pub const Hit = struct { id: Id, box: Aabb };
        pub const Stats = struct { cells_visited: usize = 0, entries_tested: usize = 0 };

        const max_levels = 48;
        const max_coord: f64 = 4e18;
        const CellKey = struct { level: u8, x: i64, y: i64, z: i64 };
        const Entry = struct { id: Id, box: Aabb, home: u8 };
        const CellData = struct { entries: std.ArrayListUnmanaged(Entry) = .empty };
        const Cells = ConcurrentHashMap(CellKey, CellData, std.hash_map.AutoContext(CellKey), bucket_amount);
        const Index = ConcurrentHashMap(Id, CellKey, std.hash_map.AutoContext(Id), bucket_amount);

        cells: Cells = .init,
        index: Index = .init,
        home_count: [max_levels]std.atomic.Value(usize) = .{std.atomic.Value(usize).init(0)} ** max_levels,

        /// Inserts or replaces the box for `id`. On allocation failure the id
        /// ends absent (never stale): the partial chain unwinds and any entry
        /// detached from a previous box is not restored.
        pub fn upsert(self: *Map, io: std.Io, allocator: std.mem.Allocator, id: Id, box: Aabb) !void {
            assertValid(box);
            const home = keyFor(box);
            if (self.index.get(io, id)) |old| {
                if (std.meta.eql(old, home)) {
                    // Same chain: refresh boxes in place; counts and index stand.
                    const entry: Entry = .{ .id = id, .box = box, .home = home.level };
                    var key = home;
                    while (true) {
                        try self.attach(io, allocator, key, entry);
                        if (key.level + 1 >= max_levels) break;
                        key = parentKey(key);
                    }
                    return;
                }
                self.detach(io, allocator, id, old);
            }
            _ = self.home_count[home.level].fetchAdd(1, .monotonic);
            var committed = false;
            defer if (!committed) {
                self.detach(io, allocator, id, home);
                _ = self.index.fetchRemove(io, id);
            };
            const entry: Entry = .{ .id = id, .box = box, .home = home.level };
            var key = home;
            while (true) {
                try self.attach(io, allocator, key, entry);
                if (key.level + 1 >= max_levels) break;
                key = parentKey(key);
            }
            try self.index.put(io, allocator, id, home);
            committed = true;
        }

        /// Removes `id`; returns false when absent.
        pub fn remove(self: *Map, io: std.Io, allocator: std.mem.Allocator, id: Id) bool {
            const home = self.index.fetchRemove(io, id) orelse return false;
            self.detach(io, allocator, id, home);
            return true;
        }

        /// Moves an existing id to a new box (inserts when absent); reports whether it existed.
        /// Shares `upsert`'s failure contract: if the write half fails, the id is absent.
        pub fn move(self: *Map, io: std.Io, allocator: std.mem.Allocator, id: Id, box: Aabb) !bool {
            const existed = self.index.get(io, id) != null;
            try self.upsert(io, allocator, id, box);
            return existed;
        }

        /// Appends every stored box strictly overlapping `box` (touching faces miss).
        /// On allocation failure `out` may hold partial results; discard it.
        pub fn query(self: *Map, io: std.Io, allocator: std.mem.Allocator, box: Aabb, out: *std.ArrayListUnmanaged(Hit), stats: ?*Stats) !void {
            assertValid(box);
            const own = levelFor(extentOf(box));
            try self.scanLevel(io, allocator, box, own, false, out, stats);
            var level = own + 1;
            while (level < max_levels) : (level += 1) {
                // Pruning hint only: fetchSub runs after the chain is fully
                // detached, so zero means no committed entries from any
                // completed update. Races with in-flight updates follow the
                // per-cell contract above; relaxed ordering suffices.
                if (self.home_count[level].load(.monotonic) == 0) continue;
                try self.scanLevel(io, allocator, box, level, true, out, stats);
            }
        }

        /// Number of live boxes. Advisory under concurrent mutation.
        pub fn count(self: *Map, io: std.Io) usize {
            _ = io;
            var total: usize = 0;
            for (&self.home_count) |*c| total += c.load(.monotonic);
            return total;
        }

        pub fn deinit(self: *Map, io: std.Io, allocator: std.mem.Allocator) void {
            for (&self.cells.buckets) |*bucket| {
                bucket.lock.lockUncancelable(io);
                var it = bucket.hash_map.iterator();
                while (it.next()) |kv| kv.value_ptr.entries.deinit(allocator);
                bucket.hash_map.clearAndFree(allocator);
                bucket.lock.unlock(io);
            }
            for (&self.index.buckets) |*bucket| {
                bucket.lock.lockUncancelable(io);
                bucket.hash_map.clearAndFree(allocator);
                bucket.lock.unlock(io);
            }
        }

        fn attach(self: *Map, io: std.Io, allocator: std.mem.Allocator, key: CellKey, entry: Entry) !void {
            const bucket = self.cells.getBucket(key);
            bucket.lock.lockUncancelable(io);
            defer bucket.lock.unlock(io);
            const slot = try bucket.hash_map.getOrPut(allocator, key);
            if (!slot.found_existing) slot.value_ptr.* = .{};
            // Idempotent by id: replaces on re-attach (same-chain refresh,
            // allocation-failure retry), appends otherwise. `upsert` always
            // detaches the old chain first, so duplicates cannot accumulate.
            for (slot.value_ptr.entries.items) |*old| {
                if (old.id == entry.id) {
                    old.* = entry;
                    return;
                }
            }
            try slot.value_ptr.entries.append(allocator, entry);
        }

        fn detach(self: *Map, io: std.Io, allocator: std.mem.Allocator, id: Id, home: CellKey) void {
            var key = home;
            while (true) {
                const bucket = self.cells.getBucket(key);
                bucket.lock.lockUncancelable(io);
                if (bucket.hash_map.getPtr(key)) |cell| {
                    for (cell.entries.items, 0..) |candidate, i| {
                        if (candidate.id != id) continue;
                        _ = cell.entries.swapRemove(i);
                        break;
                    }
                    if (cell.entries.items.len == 0) {
                        cell.entries.deinit(allocator);
                        _ = bucket.hash_map.remove(key);
                    }
                }
                bucket.lock.unlock(io);
                if (key.level + 1 >= max_levels) break;
                key = parentKey(key);
            }
            const prev = self.home_count[home.level].fetchSub(1, .monotonic);
            std.debug.assert(prev > 0);
        }

        fn scanLevel(self: *Map, io: std.Io, allocator: std.mem.Allocator, box: Aabb, level: u8, homes_only: bool, out: *std.ArrayListUnmanaged(Hit), stats: ?*Stats) !void {
            const size = sizeFor(level);
            // Own level: overlapped cells plus the neighbor shell, since a
            // min-anchored box can spill one cell past its anchor in +xyz.
            // Coarser levels hold bigger boxes directly and need the shell for
            // the same reason. At most 4 cells per axis (64 total): the query
            // spans at most 2 cells at any visited level.
            const pad: Vec = @splat(size);
            const range_lo = box.min - pad;
            const range_hi = box.max + pad;
            const x0 = cellOf(range_lo[0], level);
            const y0 = cellOf(range_lo[1], level);
            const z0 = cellOf(range_lo[2], level);
            const x1 = cellOf(range_hi[0], level);
            const y1 = cellOf(range_hi[1], level);
            const z1 = cellOf(range_hi[2], level);
            var x = x0;
            while (x <= x1) : (x += 1) {
                var y = y0;
                while (y <= y1) : (y += 1) {
                    var z = z0;
                    while (z <= z1) : (z += 1) {
                        try self.scanCell(io, allocator, box, .{ .level = level, .x = x, .y = y, .z = z }, homes_only, out, stats);
                    }
                }
            }
        }

        fn scanCell(self: *Map, io: std.Io, allocator: std.mem.Allocator, box: Aabb, key: CellKey, homes_only: bool, out: *std.ArrayListUnmanaged(Hit), stats: ?*Stats) !void {
            if (stats) |s| s.cells_visited += 1;
            const bucket = self.cells.getBucket(key);
            bucket.lock.lockSharedUncancelable(io);
            defer bucket.lock.unlockShared(io);
            const cell = bucket.hash_map.get(key) orelse return;
            for (cell.entries.items) |entry| {
                if (homes_only and entry.home != key.level) continue;
                if (stats) |s| s.entries_tested += 1;
                if (overlaps(box, entry.box)) try out.append(allocator, .{ .id = entry.id, .box = entry.box });
            }
        }

        fn sizeFor(level: u8) f64 {
            return @floatFromInt(@as(u64, 1) << @intCast(level));
        }

        fn levelFor(extent: f64) u8 {
            var size: f64 = 1.0;
            var level: u8 = 0;
            while (size < extent and level + 1 < max_levels) {
                size *= 2.0;
                level += 1;
            }
            return level;
        }

        fn extentOf(box: Aabb) f64 {
            const span = box.max - box.min;
            return @max(span[0], span[1], span[2]);
        }

        fn cellOf(coord: f64, level: u8) i64 {
            return @intFromFloat(@floor(coord / sizeFor(level)));
        }

        fn keyFor(box: Aabb) CellKey {
            const level = levelFor(extentOf(box));
            return .{ .level = level, .x = cellOf(box.min[0], level), .y = cellOf(box.min[1], level), .z = cellOf(box.min[2], level) };
        }

        fn parentKey(key: CellKey) CellKey {
            return .{ .level = key.level + 1, .x = @divFloor(key.x, 2), .y = @divFloor(key.y, 2), .z = @divFloor(key.z, 2) };
        }

        fn overlaps(a: Aabb, b: Aabb) bool {
            const lo = @max(a.min, b.min);
            const hi = @min(a.max, b.max);
            return lo[0] < hi[0] and lo[1] < hi[1] and lo[2] < hi[2];
        }

        fn assertValid(box: Aabb) void {
            std.debug.assert(@reduce(.And, box.min <= box.max));
            // cellOf divides by >= 1 and must fit i64; reject absurd magnitudes.
            inline for (0..3) |i| {
                std.debug.assert(std.math.isFinite(box.min[i]) and std.math.isFinite(box.max[i]));
                std.debug.assert(@abs(box.min[i]) < max_coord and @abs(box.max[i]) < max_coord);
            }
        }
    };
}

const TestMap = SpatialHash(32);

fn fillHits(map: *TestMap, io: std.Io, allocator: std.mem.Allocator, box: TestMap.Aabb) !std.ArrayListUnmanaged(TestMap.Hit) {
    var out: std.ArrayListUnmanaged(TestMap.Hit) = .empty;
    errdefer out.deinit(allocator);
    try map.query(io, allocator, box, &out, null);
    return out;
}

fn hitIds(hits: []const TestMap.Hit) [16]TestMap.Id {
    var ids: [16]TestMap.Id = @splat(std.math.maxInt(TestMap.Id));
    for (hits, 0..) |hit, i| ids[i] = hit.id;
    std.mem.sort(TestMap.Id, ids[0..hits.len], {}, std.sort.asc(TestMap.Id));
    return ids;
}

test "SpatialHash crud and touching faces" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var map: TestMap = .{};
    defer map.deinit(io, allocator);

    const a: TestMap.Aabb = .{ .min = .{ 0, 0, 0 }, .max = .{ 2, 2, 2 } };
    const touching: TestMap.Aabb = .{ .min = .{ 2, 0, 0 }, .max = .{ 4, 2, 2 } };
    const overlap: TestMap.Aabb = .{ .min = .{ 1, 1, 1 }, .max = .{ 3, 3, 3 } };
    try map.upsert(io, allocator, 1, a);
    try map.upsert(io, allocator, 2, touching);
    try std.testing.expectEqual(@as(usize, 2), map.count(io));

    var probe = try fillHits(&map, io, allocator, overlap);
    defer probe.deinit(allocator);
    // Overlaps both a and touching; touching-vs-a contact alone is not a hit.
    try std.testing.expectEqualSlices(TestMap.Id, &.{ 1, 2 }, hitIds(probe.items)[0..probe.items.len]);

    var face_probe = try fillHits(&map, io, allocator, a);
    defer face_probe.deinit(allocator);
    // a vs touching share only a face: miss. a vs itself: hit.
    try std.testing.expectEqualSlices(TestMap.Id, &.{1}, hitIds(face_probe.items)[0..face_probe.items.len]);

    try std.testing.expect(map.remove(io, allocator, 1));
    try std.testing.expect(!map.remove(io, allocator, 1));
    try std.testing.expectEqual(@as(usize, 1), map.count(io));

    try std.testing.expect(!try map.move(io, allocator, 3, a));
    try std.testing.expect(try map.move(io, allocator, 2, .{ .min = .{ 100, 100, 100 }, .max = .{ 101, 101, 101 } }));
    var moved_probe = try fillHits(&map, io, allocator, overlap);
    defer moved_probe.deinit(allocator);
    try std.testing.expectEqualSlices(TestMap.Id, &.{3}, hitIds(moved_probe.items)[0..moved_probe.items.len]);
}

test "SpatialHash cross-scale differential" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var map: TestMap = .{};
    defer map.deinit(io, allocator);

    var rng: u64 = 0x243f6a8885a308d3;
    const next = struct {
        fn run(state: *u64) u64 {
            state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
            return state.* >> 11;
        }
    }.run;
    const unit = struct {
        fn run(state: *u64) f64 {
            return @as(f64, @floatFromInt(next(state) % 1_000_000)) / 1_000_000.0;
        }
    }.run;

    const box_count = 200;
    var boxes: [box_count]TestMap.Aabb = undefined;
    for (&boxes) |*box| {
        const extent = std.math.pow(f64, 10.0, -3.0 + 15.0 * unit(&rng));
        const center: TestMap.Vec = .{ (unit(&rng) - 0.5) * 2e6, (unit(&rng) - 0.5) * 2e6, (unit(&rng) - 0.5) * 2e6 };
        const half: TestMap.Vec = @splat(extent / 2);
        box.* = .{ .min = center - half, .max = center + half };
        try map.upsert(io, allocator, @intCast(box - &boxes[0]), box.*);
    }
    try std.testing.expectEqual(@as(usize, box_count), map.count(io));

    var queries: [60]TestMap.Aabb = undefined;
    for (&queries, 0..) |*q, i| {
        if (i < 20) {
            // Stored boxes perturbed across cell/level boundaries.
            const stored = boxes[next(&rng) % box_count];
            const shift: TestMap.Vec = @splat((unit(&rng) - 0.5) * 4.0);
            q.* = .{ .min = stored.min + shift, .max = stored.max + shift };
        } else if (i < 40) {
            const extent = std.math.pow(f64, 10.0, -3.0 + 15.0 * unit(&rng));
            const center: TestMap.Vec = .{ (unit(&rng) - 0.5) * 2e6, (unit(&rng) - 0.5) * 2e6, (unit(&rng) - 0.5) * 2e6 };
            const half: TestMap.Vec = @splat(extent / 2);
            q.* = .{ .min = center - half, .max = center + half };
        } else {
            // Degenerate point queries.
            const at: TestMap.Vec = .{ (unit(&rng) - 0.5) * 2e6, (unit(&rng) - 0.5) * 2e6, (unit(&rng) - 0.5) * 2e6 };
            q.* = .{ .min = at, .max = at };
        }
    }

    var got: std.ArrayListUnmanaged(TestMap.Id) = .empty;
    defer got.deinit(allocator);
    var want: std.ArrayListUnmanaged(TestMap.Id) = .empty;
    defer want.deinit(allocator);
    for (queries) |q| {
        var hits = try fillHits(&map, io, allocator, q);
        defer hits.deinit(allocator);
        got.clearRetainingCapacity();
        for (hits.items) |hit| {
            try got.append(allocator, hit.id);
            // Payload must match the stored box exactly.
            try std.testing.expectEqual(boxes[hit.id], hit.box);
        }
        want.clearRetainingCapacity();
        for (boxes, 0..) |stored, id| {
            const lo = @max(q.min, stored.min);
            const hi = @min(q.max, stored.max);
            if (lo[0] < hi[0] and lo[1] < hi[1] and lo[2] < hi[2]) try want.append(allocator, @intCast(id));
        }
        std.mem.sort(TestMap.Id, got.items, {}, std.sort.asc(TestMap.Id));
        std.mem.sort(TestMap.Id, want.items, {}, std.sort.asc(TestMap.Id));
        try std.testing.expectEqualSlices(TestMap.Id, want.items, got.items);
    }
}

test "SpatialHash sparse bound and level growth" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var map: TestMap = .{};
    defer map.deinit(io, allocator);

    try map.upsert(io, allocator, 1, .{ .min = .{ 0.1, 0.1, 0.1 }, .max = .{ 0.2, 0.2, 0.2 } });
    try map.upsert(io, allocator, 2, .{ .min = .{ -1e12, -1e12, -1e12 }, .max = .{ 1e12, 1e12, 1e12 } });
    // Grow id 1 across levels: tiny to building-sized.
    try std.testing.expect(try map.move(io, allocator, 1, .{ .min = .{ 0, 0, 0 }, .max = .{ 300, 10, 10 } }));
    try std.testing.expectEqual(@as(usize, 2), map.count(io));

    var out: std.ArrayListUnmanaged(TestMap.Hit) = .empty;
    defer out.deinit(allocator);
    var stats: TestMap.Stats = .{};
    // Far-away point: misses everything, and must not enumerate fine cells.
    try map.query(io, allocator, .{ .min = .{ 5e5, 5e5, 5e5 }, .max = .{ 5e5, 5e5, 5e5 } }, &out, &stats);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    var occupied_levels: usize = 0;
    for (&map.home_count) |*c| occupied_levels += @intFromBool(c.load(.monotonic) > 0);
    try std.testing.expect(stats.cells_visited <= 64 * (1 + occupied_levels));
    try std.testing.expect(stats.entries_tested <= out.items.len + 64 * (1 + occupied_levels));
}

test "SpatialHash concurrent disjoint smoke" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var map: TestMap = .{};
    defer map.deinit(io, allocator);
    var failed = std.atomic.Value(bool).init(false);
    const Worker = struct {
        fn run(m: *TestMap, _io: std.Io, alloc: std.mem.Allocator, base: TestMap.Id, failed_flag: *std.atomic.Value(bool)) void {
            var i: TestMap.Id = 0;
            while (i < 50) : (i += 1) {
                const id = base + i;
                const f: f64 = @floatFromInt(id);
                m.upsert(_io, alloc, id, .{ .min = .{ f, f, f }, .max = .{ f + 1, f + 1, f + 1 } }) catch {
                    failed_flag.store(true, .seq_cst);
                    return;
                };
                var out: std.ArrayListUnmanaged(TestMap.Hit) = .empty;
                defer out.deinit(alloc);
                m.query(_io, alloc, .{ .min = .{ f, f, f }, .max = .{ f + 1, f + 1, f + 1 } }, &out, null) catch {
                    failed_flag.store(true, .seq_cst);
                    return;
                };
                if (out.items.len == 0 or !m.remove(_io, alloc, id)) failed_flag.store(true, .seq_cst);
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, k| thread.* = std.Thread.spawn(.{}, Worker.run, .{ &map, io, allocator, @as(TestMap.Id, k * 1000), &failed }) catch {
        failed.store(true, .seq_cst);
        break;
    };
    for (&threads) |*thread| thread.join();
    try std.testing.expect(!failed.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), map.count(io));
}

test "SpatialHash replace under allocation failure" {
    // A failed replace must leave the id absent with balanced counts: no
    // stale index entry pointing at a detached chain (which would underflow
    // home_count on the next remove and corrupt count()).
    const test_fn = struct {
        fn run(allocator: std.mem.Allocator, io: std.Io) !void {
            var map: TestMap = .{};
            defer map.deinit(io, allocator);
            const tiny: TestMap.Aabb = .{ .min = .{ 0, 0, 0 }, .max = .{ 0.5, 0.5, 0.5 } };
            const huge: TestMap.Aabb = .{ .min = .{ -1000, -1000, -1000 }, .max = .{ 1000, 1000, 1000 } };
            try map.upsert(io, allocator, 1, tiny);
            map.upsert(io, allocator, 1, huge) catch |err| {
                if (err != error.OutOfMemory) return err;
                try std.testing.expectEqual(@as(usize, 0), map.count(io));
                try std.testing.expect(!map.remove(io, allocator, 1));
                var out: std.ArrayListUnmanaged(TestMap.Hit) = .empty;
                defer out.deinit(allocator);
                try map.query(io, allocator, huge, &out, null);
                try std.testing.expectEqual(@as(usize, 0), out.items.len);
                return error.OutOfMemory;
            };
            try std.testing.expectEqual(@as(usize, 1), map.count(io));
            var out: std.ArrayListUnmanaged(TestMap.Hit) = .empty;
            defer out.deinit(allocator);
            try map.query(io, allocator, tiny, &out, null);
            try std.testing.expectEqual(@as(usize, 1), out.items.len);
            try std.testing.expectEqual(huge, out.items[0].box);
        }
    }.run;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_fn, .{std.testing.io});
}

test "SpatialHash checkAllAllocationFailures" {
    const test_fn = struct {
        fn run(allocator: std.mem.Allocator, io: std.Io) !void {
            var map: TestMap = .{};
            defer map.deinit(io, allocator);
            try map.upsert(io, allocator, 1, .{ .min = .{ 0, 0, 0 }, .max = .{ 2, 2, 2 } });
            try map.upsert(io, allocator, 2, .{ .min = .{ -100, -100, -100 }, .max = .{ 100, 100, 100 } });
            var out: std.ArrayListUnmanaged(TestMap.Hit) = .empty;
            defer out.deinit(allocator);
            try map.query(io, allocator, .{ .min = .{ 1, 1, 1 }, .max = .{ 3, 3, 3 } }, &out, null);
            _ = map.remove(io, allocator, 1);
        }
    }.run;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_fn, .{std.testing.io});
}
