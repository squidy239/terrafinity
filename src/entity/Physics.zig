const std = @import("std");

const zm = @import("zm");

const Block = @import("../world/Block.zig").Block;
const World = @import("../world/World.zig");

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

            inline for (std.meta.fields(@TypeOf(self.elements))) |field| {
                const field_data = &@field(&self.elements, field.name);
                try field_data.update(io, self, delta_t, world, allocator);
            }
        }
    };
}

pub const SimpleMover = struct {
    pub fn update(self: *@This(), io: std.Io, physics: anytype, delta_t: f64, world: *World, allocator: std.mem.Allocator) !void {
        _ = self;
        _ = world;
        _ = allocator;
        physics.mutex.lockUncancelable(io);
        defer physics.mutex.unlock(io);
        physics.pos += physics.velocity * @as(@Vector(3, f64), @splat(delta_t));
    }
};

pub const Mover = struct {
    collisions: std.atomic.Value(bool),
    zero_velocity: std.atomic.Value(bool),
    bounding_box: zm.AABB(3, f64),
    enabled: std.atomic.Value(bool),

    pub fn update(self: *@This(), io: std.Io, physics: anytype, delta_t: f64, world: *World, allocator: std.mem.Allocator) !void {
        if (!self.enabled.load(.monotonic)) return;
        defer if (self.zero_velocity.load(.monotonic)) {
            physics.mutex.lockUncancelable(io);
            defer physics.mutex.unlock(io);
            physics.velocity = .{ 0, 0, 0 };
        };

        physics.mutex.lockUncancelable(io);
        var pos_offset = physics.velocity * @as(@Vector(3, f64), @splat(delta_t));
        physics.mutex.unlock(io);

        if (!self.collisions.load(.monotonic)) {
            physics.mutex.lockUncancelable(io);
            defer physics.mutex.unlock(io);
            physics.pos += pos_offset;
            return;
        }

        var reader = World.Reader{ .world = world };
        defer reader.clear(io);

        physics.mutex.lockUncancelable(io);
        defer physics.mutex.unlock(io);

        const max_move: @Vector(3, f64) = @splat(0.4);
        while (!std.meta.eql(pos_offset, @Vector(3, f64){ 0, 0, 0 })) {
            const step = std.math.clamp(pos_offset, -max_move, max_move);
            pos_offset -= step;
            physics.pos += step;

            while (try self.checkCollision(io, allocator, physics.pos, &reader)) |mtv| {
                physics.pos -= mtv;
                if (mtv[0] != 0) physics.velocity[0] = 0;
                if (mtv[1] != 0) physics.velocity[1] = 0;
                if (mtv[2] != 0) physics.velocity[2] = 0;
            }
        }
    }

    fn checkRange(self: *const @This()) i16 {
        const size = self.bounding_box.size();
        return @intFromFloat(@ceil(@max(size.data[0], size.data[1], size.data[2]) / 2));
    }

    pub fn checkCollision(self: *const @This(), io: std.Io, allocator: std.mem.Allocator, pos: @Vector(3, f64), reader: *World.Reader) !?@Vector(3, f64) {
        const base: World.BlockPos = @round(pos);
        var best_mtv: @Vector(3, f64) = @splat(0.0);
        var best_mag: f64 = 0.0;
        var found = false;
        const dist = self.checkRange();

        var x: i16 = -dist;
        while (x <= dist) : (x += 1) {
            var y: i16 = -dist;
            while (y <= dist) : (y += 1) {
                var z: i16 = -dist;
                while (z <= dist) : (z += 1) {
                    const block_pos = base + World.BlockPos{ x, y, z };
                    const block = try reader.getBlock(io, allocator, block_pos, World.standard_level);
                    if (!block.isSolid()) continue;

                    const mtv = self.penetrationForBlock(block_pos, pos);
                    if (std.meta.eql(mtv, @Vector(3, f64){ 0, 0, 0 })) continue;

                    const mag = @max(@abs(mtv[0]), @max(@abs(mtv[1]), @abs(mtv[2])));
                    if (!found or mag > best_mag) {
                        best_mag = mag;
                        best_mtv = mtv;
                        found = true;
                    }
                }
            }
        }

        return if (found) best_mtv else null;
    }

    pub fn getShortestGroundDistance(self: *const @This(), io: std.Io, allocator: std.mem.Allocator, pos: @Vector(3, f64), reader: *World.Reader) !f64 {
        const base: World.BlockPos = @round(pos);
        var best: f64 = 1e13;
        const dist = self.checkRange();

        var x: i16 = -dist;
        while (x <= dist) : (x += 1) {
            var y: i16 = -dist;
            while (y <= dist) : (y += 1) {
                var z: i16 = -dist;
                while (z <= dist) : (z += 1) {
                    const block_pos_int = base + World.BlockPos{ @as(i64, x), @as(i64, y), @as(i64, z) };
                    const block_pos: @Vector(3, f64) = @floatFromInt(block_pos_int);
                    const block = try reader.getBlock(io, allocator, @trunc(block_pos), World.standard_level);
                    if (!block.isSolid()) continue;

                    const block_aabb = zm.AABB(3, f64).init(
                        .{ .data = block_pos + @Vector(3, f64){ -0.5, -0.5, -0.5 } },
                        .{ .data = block_pos + @Vector(3, f64){ 0.5, 0.5, 0.5 } },
                    );
                    var self_aabb = self.bounding_box;
                    self_aabb.min = self_aabb.min.add(.{ .data = pos });
                    self_aabb.max = self_aabb.max.add(.{ .data = pos });

                    if (getAabbPenetration(block_aabb, self_aabb)[1] != 0) {
                        best = @min(getAabbIntersect(block_aabb, self_aabb)[1], best);
                    }
                }
            }
        }
        return best;
    }

    fn penetrationForBlock(self: *const @This(), block_pos: World.BlockPos, entity_pos: @Vector(3, f64)) @Vector(3, f64) {
        const float_pos: @Vector(3, f64) = @floatFromInt(block_pos);
        const block_aabb = zm.AABB(3, f64).init(
            .{ .data = float_pos + @Vector(3, f64){ -0.5, -0.5, -0.5 } },
            .{ .data = float_pos + @Vector(3, f64){ 0.5, 0.5, 0.5 } },
        );
        var self_aabb = self.bounding_box;
        self_aabb.min = self_aabb.min.add(.{ .data = entity_pos });
        self_aabb.max = self_aabb.max.add(.{ .data = entity_pos });
        return getAabbPenetration(block_aabb, self_aabb);
    }

    fn getAabbIntersect(a: zm.AABB(3, f64), b: zm.AABB(3, f64)) @Vector(3, f64) {
        if (a.max.data[0] <= b.min.data[0] or a.min.data[0] >= b.max.data[0] or
            a.max.data[1] <= b.min.data[1] or a.min.data[1] >= b.max.data[1] or
            a.max.data[2] <= b.min.data[2] or a.min.data[2] >= b.max.data[2])
        {
            return @splat(0);
        }

        const ox = @min(a.max.data[0], b.max.data[0]) - @max(a.min.data[0], b.min.data[0]);
        const oy = @min(a.max.data[1], b.max.data[1]) - @max(a.min.data[1], b.min.data[1]);
        const oz = @min(a.max.data[2], b.max.data[2]) - @max(a.min.data[2], b.min.data[2]);

        const ca = (a.min.add(a.max)).mul(.{ .data = .{ 0.5, 0.5, 0.5 } });
        const cb = (b.min.add(b.max)).mul(.{ .data = .{ 0.5, 0.5, 0.5 } });

        return .{
            if (ca.data[0] < cb.data[0]) -ox else ox,
            if (ca.data[1] < cb.data[1]) -oy else oy,
            if (ca.data[2] < cb.data[2]) -oz else oz,
        };
    }

    fn getAabbPenetration(a: zm.AABB(3, f64), b: zm.AABB(3, f64)) @Vector(3, f64) {
        const i = getAabbIntersect(a, b);
        if (std.meta.eql(i, @Vector(3, f64){ 0, 0, 0 })) return @splat(0);

        const ax = @abs(i[0]);
        const ay = @abs(i[1]);
        const az = @abs(i[2]);

        if (ax < ay and ax < az) return .{ i[0], 0, 0 };
        if (ay < ax and ay < az) return .{ 0, i[1], 0 };
        return .{ 0, 0, i[2] };
    }
};

pub const Gravity = struct {
    enabled: std.atomic.Value(bool) = .init(true),
    up: @Vector(3, f64) = .{ 0, 1, 0 },
    strength: std.atomic.Value(f64) = .init(20.0),

    pub fn update(self: *@This(), io: std.Io, physics: anytype, delta_t: f64, world: *World, allocator: std.mem.Allocator) !void {
        if (!self.enabled.load(.monotonic)) return;
        _ = world;
        _ = allocator;
        const offset = @as(@Vector(3, f64), @splat(self.strength.load(.monotonic) * delta_t)) * self.up;
        physics.mutex.lockUncancelable(io);
        defer physics.mutex.unlock(io);
        physics.velocity -= offset;
    }
};

pub const Resistance = struct {
    enabled: std.atomic.Value(bool) = .init(true),
    fraction_per_second: std.atomic.Value(f64) = .init(0.1),

    pub fn update(self: *@This(), io: std.Io, physics: anytype, delta_t: f64, world: *World, allocator: std.mem.Allocator) !void {
        _ = world;
        _ = allocator;
        if (!self.enabled.load(.monotonic)) return;
        physics.mutex.lockUncancelable(io);
        defer physics.mutex.unlock(io);
        const factor = self.fraction_per_second.load(.monotonic) * delta_t;
        const lerp_factor: @Vector(3, f64) = @splat(factor);
        const one: @Vector(3, f64) = @splat(1);
        physics.velocity = physics.velocity * (one - lerp_factor);
    }
};

test "AABB intersection" {
    const aabb1 = zm.AABB(3, f64).init(.{ .data = .{ 0, 0, 0 } }, .{ .data = .{ 1, 1, 1 } });
    const aabb2 = zm.AABB(3, f64).init(.{ .data = .{ 0.5, 0.5, 0.5 } }, .{ .data = .{ 1.5, 1.5, 1.5 } });
    const aabb3 = zm.AABB(3, f64).init(.{ .data = .{ 2, 2, 2 } }, .{ .data = .{ 3, 3, 3 } });

    const intersect12 = Mover.getAabbIntersect(aabb1, aabb2);
    try std.testing.expect(intersect12[0] != 0 and intersect12[1] != 0 and intersect12[2] != 0);

    const intersect13 = Mover.getAabbIntersect(aabb1, aabb3);
    try std.testing.expect(std.meta.eql(intersect13, .{ 0, 0, 0 }));
}

test "AABB penetration" {
    const aabb1 = zm.AABB(3, f64).init(.{ .data = .{ 0, 0, 0 } }, .{ .data = .{ 1, 1, 1 } });
    const aabb2 = zm.AABB(3, f64).init(.{ .data = .{ 0.8, 0.9, 0.7 } }, .{ .data = .{ 1.8, 1.9, 1.7 } });

    const penetration = Mover.getAabbPenetration(aabb1, aabb2);
    try std.testing.expect(penetration[0] == 0 and penetration[1] != 0 and penetration[2] == 0);
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

test "simpleMover" {
    const testing = std.testing;
    const physics_interface = Interface(struct { mover: SimpleMover });
    var physics_object = physics_interface{
        .elements = .{ .mover = .{} },
        .last_update = .now(testing.io, .awake),
        .pos = .{ 0, 0, 0 },
        .velocity = .{ 0, 10, 0 },
    };
    _ = physics_object.lapUpdateTimer(testing.io);
    try testing.io.sleep(.fromMilliseconds(10), .awake);
    try physics_object.update(undefined, testing.io, std.testing.allocator);
    physics_object.mutex.lockUncancelable(testing.io);
    defer physics_object.mutex.unlock(testing.io);
    try testing.expect(physics_object.pos[1] > 0);
}
