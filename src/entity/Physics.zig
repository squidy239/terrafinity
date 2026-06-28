const std = @import("std");

const zm = @import("zm");

const Block = @import("../world/Block.zig").Block;
const World = @import("../world/World.zig");

///gets a Physics interface, all functions are thread-safe
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
            const ola = self.last_update;
            self.last_update = .now(io, .awake);
            return ola.durationTo(self.last_update);
        }

        pub fn update(self: *@This(), world: *World, io: std.Io, allocator: std.mem.Allocator) !void {
            //delta_t is seconds
            const delta_t: f64 = @as(f64, @floatFromInt(self.lapUpdateTimer(io).nanoseconds)) / std.time.ns_per_s;

            inline for (std.meta.fields(@TypeOf(self.elements))) |field| {
                const fieldData = &@field(&self.elements, field.name);
                try fieldData.update(io, self, delta_t, world, allocator);
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
        const pos_offset = physics.velocity * @as(@Vector(3, f64), @splat(delta_t));
        physics.pos += pos_offset;
    }
};

pub const Mover = struct {
    collisions: std.atomic.Value(bool),
    zero_velocity: std.atomic.Value(bool),
    bounding_box: zm.AABB(3, f64),
    enabled: std.atomic.Value(bool),

    pub fn update(self: *@This(), io: std.Io, physics: anytype, delta_t: f64, world: *World, allocator: std.mem.Allocator) !void {
        if (!self.enabled.load(.monotonic)) return;
        defer {
            if (self.zero_velocity.load(.monotonic)) {
                physics.mutex.lockUncancelable(io);
                physics.velocity = .{ 0, 0, 0 };
                physics.mutex.unlock(io);
            }
        }
        physics.mutex.lockUncancelable(io);
        var pos_offset = physics.velocity * @as(@Vector(3, f64), @splat(delta_t));
        physics.mutex.unlock(io);

        if (!self.collisions.load(.monotonic)) {
            physics.mutex.lockUncancelable(io);
            physics.pos += pos_offset;
            physics.mutex.unlock(io);
            return;
        }
        const max_move: @Vector(3, f64) = @splat(0.4);
        var reader = World.Reader{ .world = world };
        defer reader.clear(io);
        physics.mutex.lockUncancelable(io);
        defer physics.mutex.unlock(io);
        while (!std.meta.eql(pos_offset, @Vector(3, f64){ 0, 0, 0 })) {
            const move = std.math.clamp(pos_offset, -max_move, max_move);
            pos_offset -= move;
            physics.pos += move;
            var current_pos = physics.pos;
            while (try self.checkCollision(io, allocator, current_pos, &reader)) |mtv| {
                physics.pos -= mtv;
                current_pos = physics.pos;
                if (mtv[0] != 0.0) physics.velocity[0] = 0.0;
                if (mtv[1] != 0.0) physics.velocity[1] = 0.0;
                if (mtv[2] != 0.0) physics.velocity[2] = 0.0;
            }
        }
    }

    pub fn checkCollision(self: *const @This(), io: std.Io, allocator: std.mem.Allocator, pos: @Vector(3, f64), reader: *World.Reader) !?@Vector(3, f64) {
        defer reader.clear(io);

        const base: World.BlockPos = @round(pos);
        var best_mtv: @Vector(3, f64) = @splat(0.0);
        var best_magnitude: f64 = 0.0;
        var found: bool = false;
        const size = self.bounding_box.size();
        const check_distance: i16 = @ceil(@max(size.data[0], size.data[1], size.data[2]) / 2);
        var x: i16 = -check_distance;
        while (x <= check_distance) : (x += 1) {
            var y: i16 = -check_distance;
            while (y <= check_distance) : (y += 1) {
                var z: i16 = -check_distance;
                while (z <= check_distance) : (z += 1) {
                    const block_pos = base + World.BlockPos{ x, y, z };

                    const block = try reader.getBlock(io, allocator, block_pos, World.standard_level);
                    if (!block.isSolid()) continue;

                    const float_block_pos: @Vector(3, f64) = @floatFromInt(block_pos);

                    const block_aabb = zm.AABB(3, f64).init(.{ .data = float_block_pos + @Vector(3, f64){ -0.5, -0.5, -0.5 } }, .{ .data = float_block_pos + @Vector(3, f64){ 0.5, 0.5, 0.5 } });

                    var self_aabb = self.bounding_box;
                    self_aabb.min = self_aabb.min.add(.{ .data = pos });
                    self_aabb.max = self_aabb.max.add(.{ .data = pos });

                    const mtv = getAabbPenetration(block_aabb, self_aabb); // single-axis MTV or zero

                    if (mtv[0] == 0.0 and mtv[1] == 0.0 and mtv[2] == 0.0) continue;

                    const mag = @max(@abs(mtv[0]), @max(@abs(mtv[1]), @abs(mtv[2])));

                    if (!found or mag > best_magnitude) {
                        best_magnitude = mag;
                        best_mtv = mtv;
                        found = true;
                    }
                }
            }
        }

        if (!found) return null;
        return best_mtv;
    }

    pub fn getShortestGroundDistance(self: *const @This(), io: std.Io, allocator: std.mem.Allocator, pos: @Vector(3, f64), reader: *World.Reader) !f64 {
        defer reader.clear(io);

        const base = @round(pos); // floor entity pos once
        var best: f64 = 10000000000000.0;
        const size = self.bounding_box.size();
        const check_distance: i16 = @ceil(@max(size.data[0], size.data[1], size.data[2]));
        var x: i16 = -check_distance;
        while (x <= check_distance) : (x += 1) {
            var y: i16 = -check_distance;
            while (y <= check_distance) : (y += 1) {
                var z: i16 = -check_distance;
                while (z <= check_distance) : (z += 1) {
                    const offset = @Vector(3, f64){ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
                    const block_pos = base + offset;

                    const block = try reader.getBlock(io, allocator, @trunc(block_pos), World.standard_level);
                    if (!block.isSolid()) continue;
                    const block_aabb = zm.AABB(3, f64).init(.{ .data = block_pos + @Vector(3, f64){ -0.5, -0.5, -0.5 } }, .{ .data = block_pos + @Vector(3, f64){ 0.5, 0.5, 0.5 } });

                    var self_aabb = self.bounding_box;
                    self_aabb.min = self_aabb.min.add(.{ .data = pos });
                    self_aabb.max = self_aabb.max.add(.{ .data = pos });
                    if (getAabbPenetration(block_aabb, self_aabb)[1] != 0) best = @min(getAabbIntersect(block_aabb, self_aabb)[1], best);
                }
            }
        }
        return best;
    }

    // Return signed per-axis intersection vector (zero if no overlap)
    fn getAabbIntersect(a: zm.AABB(3, f64), b: zm.AABB(3, f64)) @Vector(3, f64) {
        if (a.max.data[0] <= b.min.data[0] or a.min.data[0] >= b.max.data[0] or
            a.max.data[1] <= b.min.data[1] or a.min.data[1] >= b.max.data[1] or
            a.max.data[2] <= b.min.data[2] or a.min.data[2] >= b.max.data[2])
        {
            return @Vector(3, f64){ 0.0, 0.0, 0.0 };
        }

        const ox = @min(a.max.data[0], b.max.data[0]) - @max(a.min.data[0], b.min.data[0]);
        const oy = @min(a.max.data[1], b.max.data[1]) - @max(a.min.data[1], b.min.data[1]);
        const oz = @min(a.max.data[2], b.max.data[2]) - @max(a.min.data[2], b.min.data[2]);

        // Use centers to derive direction so this MTV is the vector you should ADD to `a` to separate it.
        const ca = (a.min.add(a.max)).mul(.{ .data = .{ 0.5, 0.5, 0.5 } });
        const cb = (b.min.add(b.max)).mul(.{ .data = .{ 0.5, 0.5, 0.5 } });

        const sx = if (ca.data[0] < cb.data[0]) -ox else ox;
        const sy = if (ca.data[1] < cb.data[1]) -oy else oy;
        const sz = if (ca.data[2] < cb.data[2]) -oz else oz;

        return @Vector(3, f64){ sx, sy, sz };
    }

    // Choose the smallest absolute axis to form the minimum translation vector.
    fn getAabbPenetration(a: zm.AABB(3, f64), b: zm.AABB(3, f64)) @Vector(3, f64) {
        const i = getAabbIntersect(a, b);
        const ax = @abs(i[0]);
        const ay = @abs(i[1]);
        const az = @abs(i[2]);

        if (ax == 0.0 and ay == 0.0 and az == 0.0) return @splat(0.0);

        if (ax < ay and ax < az) return @Vector(3, f64){ i[0], 0.0, 0.0 };
        if (ay < ax and ay < az) return @Vector(3, f64){ 0.0, i[1], 0.0 };
        return @Vector(3, f64){ 0.0, 0.0, i[2] };
    }
};

pub const Gravity = struct {
    enabled: std.atomic.Value(bool) = .init(true),
    up: @Vector(3, f64) = .{ 0, 1, 0 },
    ///the strength of the gravity in blocks per second squared
    strength: std.atomic.Value(f64) = .init(20.0),

    pub fn update(self: *@This(), io: std.Io, physics: anytype, delta_t: f64, world: *World, allocator: std.mem.Allocator) !void {
        if (!self.enabled.load(.monotonic)) return;
        _ = world;
        _ = allocator;
        const vel_offset = @as(@Vector(3, f64), @splat(self.strength.load(.monotonic))) * self.up * @as(@Vector(3, f64), @splat(delta_t));
        physics.mutex.lockUncancelable(io);
        defer physics.mutex.unlock(io);
        physics.velocity -= vel_offset;
    }
};

pub const Resistance = struct {
    enabled: std.atomic.Value(bool) = .init(true),
    ///after one second the velocity will be this fraction of the original velocity
    fraction_per_second: std.atomic.Value(f64) = .init(0.1),

    pub fn update(self: *@This(), io: std.Io, physics: anytype, delta_t: f64, world: *World, allocator: std.mem.Allocator) !void {
        _ = world;
        _ = allocator;
        if (!self.enabled.load(.monotonic)) return;
        physics.mutex.lockUncancelable(io);
        defer physics.mutex.unlock(io);
        const old_vel: @Vector(3, f64) = physics.velocity;
        const new_vel = std.math.lerp(old_vel, @Vector(3, f64){ 0, 0, 0 }, @as(@Vector(3, f64), @splat(self.fraction_per_second.load(.monotonic) * delta_t)));
        physics.velocity = new_vel;
    }
};

test "AABB intersection" {
    const testing = std.testing;

    const aabb1 = zm.AABB(3, f64).init(.{ .data = .{ 0, 0, 0 } }, .{ .data = .{ 1, 1, 1 } });
    const aabb2 = zm.AABB(3, f64).init(.{ .data = .{ 0.5, 0.5, 0.5 } }, .{ .data = .{ 1.5, 1.5, 1.5 } });
    const aabb3 = zm.AABB(3, f64).init(.{ .data = .{ 2, 2, 2 } }, .{ .data = .{ 3, 3, 3 } });

    const intersect12 = Mover.getAabbIntersect(aabb1, aabb2);
    try testing.expect(intersect12[0] != 0 and intersect12[1] != 0 and intersect12[2] != 0);

    const intersect13 = Mover.getAabbIntersect(aabb1, aabb3);
    try testing.expect(std.meta.eql(intersect13, .{ 0, 0, 0 }));
}

test "AABB penetration" {
    const testing = std.testing;

    const aabb1 = zm.AABB(3, f64).init(.{ .data = .{ 0, 0, 0 } }, .{ .data = .{ 1, 1, 1 } });
    const aabb2 = zm.AABB(3, f64).init(.{ .data = .{ 0.8, 0.9, 0.7 } }, .{ .data = .{ 1.8, 1.9, 1.7 } });

    const penetration = Mover.getAabbPenetration(aabb1, aabb2);
    try testing.expect(penetration[0] == 0 and penetration[1] != 0 and penetration[2] == 0);
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
    try physics_object.update(undefined, testing.io, std.testing.allocator); //world is not used so this is ok
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
    try physics_object.update(undefined, testing.io, std.testing.allocator); //world is not used so this is ok
    physics_object.mutex.lockUncancelable(testing.io);
    defer physics_object.mutex.unlock(testing.io);
    try testing.expect(physics_object.pos[1] > 0);
}
