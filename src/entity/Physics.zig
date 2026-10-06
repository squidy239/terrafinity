const std = @import("std");

const zm = @import("zm");

const World = @import("../world/World.zig");
const Chunk = @import("../world/Chunk.zig");

pub fn Interface(physics_elements: anytype) type {
    return struct {
        elements: physics_elements,
        last_update: std.Io.Timestamp,
        last_update_lock: std.Io.RwLock = .init,
        pos: @Vector(3, f64),
        velocity: @Vector(3, f64),
        mutex: std.Io.Mutex = .init,

        pub fn lapUpdateTimer(self: *@This(), io: std.Io) std.Io.Duration {
            self.last_update_lock.lockUncancelable(io);
            defer self.last_update_lock.unlock(io);
            const old = self.last_update;
            self.last_update = .now(io, .awake);
            return old.durationTo(self.last_update);
        }

        pub fn update(self: *@This(), world: *World, io: std.Io, allocator: std.mem.Allocator) !void {
            const elapsed = @as(f64, @floatFromInt(self.lapUpdateTimer(io).nanoseconds)) / std.time.ns_per_s;
            const delta_t = @min(elapsed, 0.1);

            inline for (@typeInfo(@TypeOf(self.elements)).@"struct".field_names) |name| {
                const field_data = &@field(&self.elements, name);
                try field_data.update(io, self, delta_t, world, allocator);
            }
        }
    };
}

pub const Mover = struct {
    /// Downward probe that decides whether the body rests on something.
    pub const ground_probe: f64 = 0.02;
    /// Extra clearance on a step probe so a raised box does not graze a ceiling.
    pub const skin: f64 = 0.001;
    /// Caps separation work when the body is wedged and cannot fully separate.
    pub const max_resolve_iterations: u32 = 8;
    /// Largest substep, independent of body size.
    pub const max_substep_size: f64 = 0.4;
    /// Substeps are capped because a fast flyer covers many blocks per update.
    pub const max_substeps: u32 = 4096;

    const CellIter = struct {
        lo: [3]i64,
        hi: [3]i64,
        at: [3]i64,

        fn next(self: *CellIter) ?World.BlockPos {
            self.at[2] += 1;
            if (self.at[2] > self.hi[2]) {
                self.at[2] = self.lo[2];
                self.at[1] += 1;
                if (self.at[1] > self.hi[1]) {
                    self.at[1] = self.lo[1];
                    self.at[0] += 1;
                }
            }
            if (self.at[0] > self.hi[0] or self.at[1] > self.hi[1] or self.at[2] > self.hi[2]) return null;
            return .{ self.at[0], self.at[1], self.at[2] };
        }
    };

    collisions: std.atomic.Value(bool),
    zero_velocity: std.atomic.Value(bool),
    bounding_box: zm.AABB(3, f64),
    enabled: std.atomic.Value(bool),
    /// Rise the body climbs automatically when a horizontal move is blocked.
    step_height: f64 = 1.0,
    /// Rate the body climbs a step, so the rise reads as motion, not a teleport.
    step_climb_speed: f64 = 20.0,
    /// Absolute Y the body is climbing toward while stepping up; null when idle.
    /// Only the frame lane touches this, which drives the mover and reads it in the
    /// same frame, so it needs no lock.
    climb_target_y: ?f64 = null,

    /// Body box centered on the position, sized in blocks. Width spans X and Z, height spans Y.
    pub fn boxFor(width: f64, height: f64) zm.AABB(3, f64) {
        const half_width = width / 2;
        const half_height = height / 2;
        return .init(
            .{ .data = .{ -half_width, -half_height, -half_width } },
            .{ .data = .{ half_width, half_height, half_width } },
        );
    }

    pub fn update(self: *@This(), io: std.Io, physics: anytype, delta_t: f64, world: *World, allocator: std.mem.Allocator) !void {
        if (!self.enabled.load(.monotonic)) return;

        physics.mutex.lockUncancelable(io);
        defer physics.mutex.unlock(io);
        defer if (self.zero_velocity.load(.monotonic)) {
            physics.velocity = .{ 0, 0, 0 };
        };

        if (self.collisions.load(.monotonic)) {
            var reader = World.Reader{ .world = world };
            defer reader.clear(io);
            try self.moveAndCollide(io, allocator, physics, delta_t, &reader);
        } else {
            physics.pos += physics.velocity * @as(@Vector(3, f64), @splat(delta_t));
        }
    }

    /// Integrates in size-aware substeps and resolves one axis at a time, so only
    /// the blocked axis loses velocity and short rises become automatic steps.
    fn moveAndCollide(self: *@This(), io: std.Io, allocator: std.mem.Allocator, physics: anytype, delta_t: f64, reader: *World.Reader) !void {
        self.advanceClimb(physics, delta_t);

        const pos_offset = physics.velocity * @as(@Vector(3, f64), @splat(delta_t));
        const max_move: @Vector(3, f64) = @splat(self.maxSubstep());
        var remaining = pos_offset;
        var substeps: u32 = 0;
        while (!std.meta.eql(remaining, @Vector(3, f64){ 0, 0, 0 }) and substeps < max_substeps) : (substeps += 1) {
            const step = std.math.clamp(remaining, -max_move, max_move);
            remaining -= step;
            inline for (0..3) |axis| {
                try self.moveAxis(io, allocator, &physics.pos, &physics.velocity, axis, step[axis], reader);
            }
        }
    }

    /// Substeps shrink with the body so a small or fast mover cannot tunnel, while
    /// a large, slow one is not over-stepped.
    fn maxSubstep(self: *const @This()) f64 {
        const size = self.bounding_box.size();
        const min_extent = @min(size.data[0], @min(size.data[1], size.data[2]));
        return @max(@min(max_substep_size, min_extent / 2), 0.001);
    }

    fn moveAxis(self: *@This(), io: std.Io, allocator: std.mem.Allocator, pos: *@Vector(3, f64), velocity: *@Vector(3, f64), comptime axis: usize, amount: f64, reader: *World.Reader) !void {
        if (amount == 0) return;
        pos.*[axis] += amount;
        if (!try self.pushOut(io, allocator, pos, axis, reader)) return;
        // Start a step only while not rising, so a jump is never captured by one.
        if (axis != 1 and velocity.*[1] <= 0 and try self.tryStepUp(io, allocator, pos.*, axis, amount, reader)) return;
        velocity.*[axis] = 0;
    }

    /// Pushes the body out of every overlapping solid block along one axis only.
    fn pushOut(self: *@This(), io: std.Io, allocator: std.mem.Allocator, pos: *@Vector(3, f64), comptime axis: usize, reader: *World.Reader) !bool {
        var pushed = false;
        var iteration: u32 = 0;
        while (iteration < max_resolve_iterations) : (iteration += 1) {
            const push = try self.deepestPushOnAxis(io, allocator, pos.*, axis, reader);
            if (push == 0) break;
            pushed = true;
            pos.*[axis] += push;
        }
        return pushed;
    }

    /// Raises the body toward a pending step target at a bounded rate. Vertical
    /// velocity is cleared while climbing so gravity cannot fight the rise, which
    /// keeps a step smooth instead of an instant snap.
    fn advanceClimb(self: *@This(), physics: anytype, delta_t: f64) void {
        const target = self.climb_target_y orelse return;
        physics.velocity[1] = 0;
        const raised = @min(target, physics.pos[1] + self.step_climb_speed * delta_t);
        physics.pos[1] = raised;
        if (raised >= target) self.climb_target_y = null;
    }

    /// Detects a step ahead: when the raised, forward-moved body is clear and ground
    /// lies within `step_height`, records a climb target instead of teleporting up.
    fn tryStepUp(self: *@This(), io: std.Io, allocator: std.mem.Allocator, pos: @Vector(3, f64), comptime axis: usize, amount: f64, reader: *World.Reader) !bool {
        // A climb already in progress keeps the body rising; do not recompute it.
        if (self.climb_target_y != null) return true;

        var raised = pos;
        raised[1] += self.step_height + skin;
        if (try self.collides(io, allocator, raised, reader)) return false;

        raised[axis] += amount;
        if (try self.collides(io, allocator, raised, reader)) return false;

        var landing = raised;
        landing[1] -= self.step_height + skin;
        if (!try self.pushOut(io, allocator, &landing, 1, reader)) return false;
        if (landing[1] <= pos[1]) return false;
        self.climb_target_y = landing[1];
        return true;
    }

    /// A wall beside the feet is not ground: only a collidable block within the probe depth counts.
    pub fn isSupported(self: *const @This(), io: std.Io, allocator: std.mem.Allocator, pos: @Vector(3, f64), reader: *World.Reader) !bool {
        const probe = pos - @Vector(3, f64){ 0, ground_probe, 0 };
        return self.collides(io, allocator, probe, reader);
    }

    pub fn collides(self: *const @This(), io: std.Io, allocator: std.mem.Allocator, pos: @Vector(3, f64), reader: *World.Reader) !bool {
        var cells = self.overlappingCells(pos);
        while (cells.next()) |block_pos| {
            if (self.blockOverlap(block_pos, pos) == null) continue;
            const block = try reader.getBlock(io, allocator, block_pos, World.standard_level);
            if (block.isSolid()) return true;
        }
        return false;
    }

    /// The fluid the body box sits in, volume-weighted over the fluid blocks it overlaps.
    pub const Medium = struct {
        /// Fraction of the body box inside fluid blocks, 0..1.
        fluid_fraction: f64 = 0,
        /// Volume-weighted buoyancy of that fluid; 0 when dry.
        buoyancy: f64 = 0,
        /// Volume-weighted resistance of that fluid; 0 when dry.
        resistance: f64 = 0,
    };

    /// Measures the fluid the body box sits in; it drives swim, wade, and canopy drag.
    pub fn mediumAt(self: *const @This(), io: std.Io, allocator: std.mem.Allocator, pos: @Vector(3, f64), reader: *World.Reader) !Medium {
        const lo = self.lowCorner(pos);
        const hi = self.highCorner(pos);
        const body_volume = (hi[0] - lo[0]) * (hi[1] - lo[1]) * (hi[2] - lo[2]);
        if (body_volume <= 0) return .{};

        var fluid_volume: f64 = 0;
        var buoyancy: f64 = 0;
        var resistance: f64 = 0;
        var cells = self.overlappingCells(pos);
        while (cells.next()) |block_pos| {
            const overlap = self.blockOverlap(block_pos, pos) orelse continue;
            const block = try reader.getBlock(io, allocator, block_pos, World.standard_level);
            const props = block.fluidProperties() orelse continue;
            const volume = overlap[0] * overlap[1] * overlap[2];
            fluid_volume += volume;
            buoyancy += props.buoyancy * volume;
            resistance += props.resistance * volume;
        }
        if (fluid_volume <= 0) return .{};
        return .{
            .fluid_fraction = @min(fluid_volume / body_volume, 1),
            .buoyancy = buoyancy / fluid_volume,
            .resistance = resistance / fluid_volume,
        };
    }

    fn deepestPushOnAxis(self: *const @This(), io: std.Io, allocator: std.mem.Allocator, pos: @Vector(3, f64), comptime axis: usize, reader: *World.Reader) !f64 {
        var best: f64 = 0;
        var cells = self.overlappingCells(pos);
        while (cells.next()) |block_pos| {
            const push = self.pushForBlockOnAxis(block_pos, pos, axis);
            if (@abs(push) <= @abs(best)) continue;
            const block = try reader.getBlock(io, allocator, block_pos, World.standard_level);
            if (block.isSolid()) best = push;
        }
        return best;
    }

    /// Signed overlap of a body span and a block cell along one axis; <= 0 means separated.
    fn overlapOnAxis(body_min: f64, body_max: f64, block_center: f64) f64 {
        return @min(body_max, block_center + 0.5) - @max(body_min, block_center - 0.5);
    }

    fn blockOverlap(self: *const @This(), block_pos: World.BlockPos, pos: @Vector(3, f64)) ?[3]f64 {
        const lo = self.lowCorner(pos);
        const hi = self.highCorner(pos);
        var overlap: [3]f64 = undefined;
        inline for (0..3) |axis| {
            overlap[axis] = overlapOnAxis(lo[axis], hi[axis], @floatFromInt(block_pos[axis]));
            if (overlap[axis] <= 0) return null;
        }
        return overlap;
    }

    fn pushForBlockOnAxis(self: *const @This(), block_pos: World.BlockPos, pos: @Vector(3, f64), comptime axis: usize) f64 {
        const overlap = self.blockOverlap(block_pos, pos) orelse return 0;
        const self_center = (self.lowCorner(pos)[axis] + self.highCorner(pos)[axis]) * 0.5;
        const block_center: f64 = @floatFromInt(block_pos[axis]);
        return if (self_center < block_center) -overlap[axis] else overlap[axis];
    }

    fn lowCorner(self: *const @This(), pos: @Vector(3, f64)) @Vector(3, f64) {
        return pos + self.bounding_box.min.data;
    }

    fn highCorner(self: *const @This(), pos: @Vector(3, f64)) @Vector(3, f64) {
        return pos + self.bounding_box.max.data;
    }

    /// Cells the body can overlap, plus a one-cell shell so a contact on the boundary
    /// is not missed. Each axis is bounded from the box, not from its largest extent.
    fn overlappingCells(self: *const @This(), pos: @Vector(3, f64)) CellIter {
        const lo = self.lowCorner(pos);
        const hi = self.highCorner(pos);
        var first: [3]i64 = undefined;
        var last: [3]i64 = undefined;
        inline for (0..3) |axis| {
            first[axis] = @as(i64, @intFromFloat(@floor(lo[axis]))) - 1;
            last[axis] = @as(i64, @intFromFloat(@floor(hi[axis]))) + 1;
        }
        // The first `next` advances before yielding, so start one step behind.
        return .{ .lo = first, .hi = last, .at = .{ first[0], first[1], first[2] - 1 } };
    }
};

pub const Gravity = struct {
    enabled: std.atomic.Value(bool) = .init(true),
    up: @Vector(3, f64) = .{ 0, 1, 0 },
    strength: std.atomic.Value(f64) = .init(20.0),

    pub fn update(self: *@This(), io: std.Io, physics: anytype, delta_t: f64, _: *World, _: std.mem.Allocator) !void {
        if (!self.enabled.load(.monotonic)) return;
        const offset = @as(@Vector(3, f64), @splat(self.strength.load(.monotonic) * delta_t)) * self.up;
        physics.mutex.lockUncancelable(io);
        defer physics.mutex.unlock(io);
        physics.velocity -= offset;
    }
};

fn testMover(collisions: bool, width: f64, height: f64) Mover {
    return .{
        .collisions = .init(collisions),
        .zero_velocity = .init(false),
        .bounding_box = Mover.boxFor(width, height),
        .enabled = .init(true),
    };
}

/// `below` fills chunks under y = 0, and a `band` of `band_height` layers sits on
/// it over world x in [0, 16); everything else is air.
fn BandSource(comptime below: World.Block, comptime band: World.Block, comptime band_height: usize) type {
    return struct {
        fn getBlocks(_: World.ChunkSource, _: std.Io, _: std.mem.Allocator, _: *World, blocks: *Chunk.Encoding, chunk_pos: World.ChunkPos, grid_buffer: *align(Chunk.Encoding.GridAlignment) [World.ChunkSize][World.ChunkSize][World.ChunkSize]World.Block) error{ Unrecoverable, OutOfMemory, Canceled }!?World.ChunkSource.GetBlocksMetadata {
            if (chunk_pos.position[1] != 0) {
                blocks.* = .{ .uniform = if (chunk_pos.position[1] < 0) below else .air };
                return .{ .from_disk = false, .structures = false };
            }
            const base_x: i64 = @as(i64, chunk_pos.position[0]) * World.ChunkSize;
            for (grid_buffer, 0..) |*plane, x| {
                const world_x = base_x + @as(i64, @intCast(x));
                for (plane, 0..) |*column, y| {
                    column.* = @splat(if (y < band_height and world_x >= 0 and world_x < 16) band else .air);
                }
            }
            blocks.* = .{ .grid = grid_buffer };
            return .{ .from_disk = false, .structures = false };
        }
    };
}

/// Installs a single chunk source on a testing world; the other slots stay empty.
fn setTestSource(world: *World, get_blocks: anytype) void {
    world.chunk_sources = .{ .{
        .data = undefined,
        .getBlocks = get_blocks,
        .placeStructures = null,
        .save = null,
        .getTerrainHeight = null,
        .deinit = null,
    }, null, null, null };
}

test "Mover box is centered on the position" {
    const box = Mover.boxFor(2, 6);
    try std.testing.expectEqual(@as(f64, -1), box.min.data[0]);
    try std.testing.expectEqual(@as(f64, 1), box.max.data[0]);
    try std.testing.expectEqual(@as(f64, -3), box.min.data[1]);
    try std.testing.expectEqual(@as(f64, 3), box.max.data[1]);
}

test "Mover substep follows the smallest extent" {
    const small = testMover(true, 0.2, 0.2);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), small.maxSubstep(), 1e-9);

    const big = testMover(true, 4, 16);
    try std.testing.expectApproxEqAbs(Mover.max_substep_size, big.maxSubstep(), 1e-9);
}

test "Mover push direction and overlap" {
    const mover = testMover(true, 1, 4);

    // Body centered on the origin with a block directly below: push out upward.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), mover.pushForBlockOnAxis(.{ 0, -1, 0 }, .{ 0, 0, 0 }, 1), 1e-9);
    // A block overhead pushes down.
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), mover.pushForBlockOnAxis(.{ 0, 1, 0 }, .{ 0, 0, 0 }, 1), 1e-9);
    // A block two cells to the side does not overlap on X.
    try std.testing.expectEqual(@as(f64, 0), mover.pushForBlockOnAxis(.{ 5, 0, 0 }, .{ 0, 0, 0 }, 1));
}

test "Gravity" {
    const testing = std.testing;
    const physics_interface = Interface(struct { gravity: Gravity });
    var physics_object = physics_interface{
        .elements = .{ .gravity = .{} },
        .last_update = .now(testing.io, .awake),
        .pos = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
    };
    _ = physics_object.lapUpdateTimer(testing.io);
    try testing.io.sleep(.fromMilliseconds(10), .awake);
    try physics_object.update(undefined, testing.io, std.testing.allocator);
    physics_object.mutex.lockUncancelable(testing.io);
    defer physics_object.mutex.unlock(testing.io);
    try testing.expect(physics_object.velocity[1] < 0);
}

test "Mover update dispatch" {
    const testing = std.testing;
    const physics_interface = Interface(struct { mover: Mover });
    var physics_object = physics_interface{
        .elements = .{ .mover = testMover(false, 1, 1) },
        .last_update = .now(testing.io, .awake),
        .pos = .{ 0, 0, 0 },
        .velocity = .{ 4, 0, 0 },
    };

    // Backdate 50ms so pos advances by velocity * ~0.05. Collisions stay off, so the `undefined` world is never dereferenced.
    physics_object.last_update.nanoseconds -|= std.time.ns_per_s / 20;
    const before: std.Io.Timestamp = physics_object.last_update;
    try physics_object.update(undefined, testing.io, testing.allocator);
    try testing.expect(physics_object.last_update.nanoseconds > before.nanoseconds);

    // Timer lapped forward; bounds reject a zero timer while tolerating scheduling delay toward the clamp.
    try testing.expect(physics_object.pos[0] > 0.1);
    try testing.expect(physics_object.pos[0] < 0.5);
    try testing.expect(physics_object.pos[1] == 0);
    try testing.expect(physics_object.pos[2] == 0);

    // Clamp: backdate 1s so the step uses velocity * 0.1. Collisions stay off, so the world stays undereferenced.
    const clamped_base = physics_object.pos[0];
    physics_object.last_update.nanoseconds -|= std.time.ns_per_s;
    try physics_object.update(undefined, testing.io, testing.allocator);
    const clamped_step = physics_object.pos[0] - clamped_base;
    try testing.expect(clamped_step > 0.3);
    try testing.expect(clamped_step < 0.5);
}

test "Mover lands on a flat floor and reports support" {
    const testing = std.testing;
    const io = testing.io;
    const allocator = testing.allocator;

    var world: World = undefined;
    var generator: World.DefaultGenerator = undefined;
    try World.makeTestingWorld(&world, &generator, allocator, 256, 256);
    defer generator.terrain_height_cache.deinit(allocator);
    defer world.deinit(io, allocator);

    // Solid below the y = 0 chunk boundary, air above, so the floor top sits at y = -0.5.
    const FlatSource = struct {
        fn getBlocks(_: World.ChunkSource, _: std.Io, _: std.mem.Allocator, _: *World, blocks: *Chunk.Encoding, chunk_pos: World.ChunkPos, _: *align(Chunk.Encoding.GridAlignment) [World.ChunkSize][World.ChunkSize][World.ChunkSize]World.Block) error{ Unrecoverable, OutOfMemory, Canceled }!?World.ChunkSource.GetBlocksMetadata {
            blocks.* = .{ .uniform = if (chunk_pos.position[1] < 0) .stone else .air };
            return .{ .from_disk = false, .structures = false };
        }
    };
    setTestSource(&world, FlatSource.getBlocks);

    const physics_interface = Interface(struct { mover: Mover });
    var physics_object = physics_interface{
        .elements = .{ .mover = testMover(true, 1, 2) },
        .last_update = .now(io, .awake),
        .pos = .{ 0.5, 0.6, 0.5 },
        .velocity = .{ 0, -5, 0 },
    };

    var reader = World.Reader{ .world = &world };
    defer reader.clear(io);

    physics_object.last_update.nanoseconds -|= std.time.ns_per_s / 20;
    try physics_object.update(&world, io, allocator);

    // Feet stop on the block top at y = -0.5, so the center rests at y = 0.5.
    try testing.expectApproxEqAbs(@as(f64, 0.5), physics_object.pos[1], 0.03);

    physics_object.mutex.lockUncancelable(io);
    defer physics_object.mutex.unlock(io);
    try testing.expect(try physics_object.elements.mover.isSupported(io, allocator, physics_object.pos, &reader));
    try testing.expect(!try physics_object.elements.mover.collides(io, allocator, physics_object.pos, &reader));
    try testing.expect(!try physics_object.elements.mover.isSupported(io, allocator, .{ 0.5, 3, 0.5 }, &reader));
}

test "Mover climb advances at a bounded rate" {
    var mover = testMover(true, 1, 2);
    var physics: struct { pos: @Vector(3, f64), velocity: @Vector(3, f64) } = .{
        .pos = .{ 0, 0, 0 },
        .velocity = .{ 0, -9, 0 },
    };
    mover.climb_target_y = 0.5;

    mover.advanceClimb(&physics, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), physics.pos[1], 1e-9);
    try std.testing.expectEqual(@as(f64, 0), physics.velocity[1]);
    try std.testing.expect(mover.climb_target_y != null);

    // Reaching the target settles exactly on it and clears the climb.
    mover.advanceClimb(&physics, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), physics.pos[1], 1e-9);
    try std.testing.expectEqual(@as(?f64, null), mover.climb_target_y);
}

test "Mover steps up a one-block rise" {
    const testing = std.testing;
    const io = testing.io;
    const allocator = testing.allocator;

    var world: World = undefined;
    var generator: World.DefaultGenerator = undefined;
    try World.makeTestingWorld(&world, &generator, allocator, 256, 256);
    defer generator.terrain_height_cache.deinit(allocator);
    defer world.deinit(io, allocator);

    // Floor below the y = 0 chunk boundary, and a one-block plateau over world x in [0, 16).
    setTestSource(&world, BandSource(.stone, .stone, 1).getBlocks);

    const physics_interface = Interface(struct { mover: Mover });
    var physics_object = physics_interface{
        .elements = .{ .mover = testMover(true, 1, 2) },
        .last_update = .now(io, .awake),
        .pos = .{ -2, 0.5, 0.5 },
        .velocity = .{ 4, 0, 0 },
    };

    var frames: u32 = 0;
    while (physics_object.pos[0] < 1.0 and frames < 400) : (frames += 1) {
        physics_object.last_update.nanoseconds -|= std.time.ns_per_s / 60;
        try physics_object.update(&world, io, allocator);
    }

    // Walked into the rise, climbed it, and kept going along the top at y = 1.5.
    try testing.expect(physics_object.pos[0] >= 1.0);
    try testing.expectApproxEqAbs(@as(f64, 1.5), physics_object.pos[1], 0.05);
}

test "Mover medium measures fluid and leaf overlap" {
    const testing = std.testing;
    const io = testing.io;
    const allocator = testing.allocator;

    var world: World = undefined;
    var generator: World.DefaultGenerator = undefined;
    try World.makeTestingWorld(&world, &generator, allocator, 256, 256);
    defer generator.terrain_height_cache.deinit(allocator);
    defer world.deinit(io, allocator);

    // Water below the chunk boundary, a leaf band in the y = 0 chunk's lowest layers.
    setTestSource(&world, BandSource(.water, .leaves, 4).getBlocks);

    const mover = testMover(true, 1, 2);
    var reader = World.Reader{ .world = &world };
    defer reader.clear(io);

    // Box spans y = [-1.5, 0.5]: half in water below -0.5, half in leaves above.
    const pos = @Vector(3, f64){ 0, -0.5, 0 };
    const medium = try mover.mediumAt(io, allocator, pos, &reader);
    // Both halves are fluid, so the blended buoyancy is water's half and the
    // resistance averages water's 1 with leaves' 4.
    try testing.expectApproxEqAbs(@as(f64, 1.0), medium.fluid_fraction, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), medium.buoyancy, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.5), medium.resistance, 1e-9);

    // Neither water nor leaves blocks the body or counts as ground.
    try testing.expect(!try mover.collides(io, allocator, pos, &reader));
    try testing.expect(!try mover.isSupported(io, allocator, pos, &reader));
}
