const std = @import("std");

const zm = @import("zm");

const Block = @import("Block.zig").Block;
const World = @import("World.zig");
const AtomicVector = @import("../libs/utils.zig").AtomicVector;

///gets a Physics interface, all functions are thread-safe
pub fn getInterface(physicsElements: anytype) type {
    return struct {
        elements: physicsElements,
        last_update: std.Io.Timestamp,
        last_update_lock: std.Io.RwLock = .init,
        pos: AtomicVector(3, f64),
        velocity: AtomicVector(3, f64),

        pub fn lapUpdateTimer(self: *@This(), io: std.Io) std.Io.Duration {
            self.last_update_lock.lockUncancelable(io);
            const ola = self.last_update;
            self.last_update = .now(io, .awake);
            self.last_update_lock.unlock(io);
            return ola.durationTo(self.last_update);
        }

        pub fn update(self: *@This(), world: *World, io: std.Io, allocator: std.mem.Allocator) !void {
            //deltaT is seconds
            const deltaT: f64 = @as(f64, @floatFromInt(self.lapUpdateTimer(io).nanoseconds)) / std.time.ns_per_s;

            inline for (std.meta.fields(@TypeOf(self.elements))) |field| {
                const fieldData = &@field(&self.elements, field.name);
                try fieldData.update(io, self, deltaT, world, allocator);
            }
        }
    };
}

pub const simpleMover = struct {
    pub fn update(self: *@This(), io: std.Io, physics: anytype, deltaT: f64, world: *World, allocator: std.mem.Allocator) !void {
        _ = self;
        _ = world;
        _ = io;
        _ = allocator;
        const posOffset = physics.velocity.load(.seq_cst) * @as(@Vector(3, f64), @splat(deltaT));
        _ = physics.pos.fetchAdd(posOffset, .seq_cst);
    }
};

pub const Mover = struct {
    collisions: bool,
    zeroVelocity: bool,
    boundingBox: zm.AABB(3, f64),
    enabled: bool,

    pub fn update(self: *@This(), io: std.Io, physics: anytype, deltaT: f64, world: *World, allocator: std.mem.Allocator) !void {
        if (!self.enabled) return;
        defer if (self.zeroVelocity) physics.velocity.store(.{ 0, 0, 0 }, .seq_cst);
        var posOffset = physics.velocity.load(.seq_cst) * @as(@Vector(3, f64), @splat(deltaT));
        if (!self.collisions) {
            _ = physics.pos.fetchAdd(posOffset, .seq_cst);
            return;
        }
        const maxMove: @Vector(3, f64) = @splat(0.4);
        var reader = World.Reader{ .world = world };
        defer reader.clear(io);
        while (!std.meta.eql(posOffset, @Vector(3, f64){ 0, 0, 0 })) {
            const move = std.math.clamp(posOffset, -maxMove, maxMove);
            posOffset -= move;
            var newPos = physics.pos.fetchAdd(move, .seq_cst);
            while (try self.collision(io, allocator, newPos, &reader)) |mtv| {
                newPos = physics.pos.fetchAdd(-mtv, .seq_cst);
                if (mtv[0] != 0.0) @atomicStore(f64, &physics.velocity.vector[0], 0.0, .seq_cst);
                if (mtv[1] != 0.0) @atomicStore(f64, &physics.velocity.vector[1], 0.0, .seq_cst);
                if (mtv[2] != 0.0) @atomicStore(f64, &physics.velocity.vector[2], 0.0, .seq_cst);
            }
        }
    }

    pub fn collision(self: *const @This(), io: std.Io, allocator: std.mem.Allocator, pos: @Vector(3, f64), reader: *World.Reader) !?@Vector(3, f64) {
        defer reader.clear(io);

        const base = @floor(pos); // floor entity pos once
        var bestMtv: @Vector(3, f64) = @splat(0.0);
        var bestMagnitude: f64 = 0.0;
        var found: bool = false;
        const size = self.boundingBox.size();
        const checkDistance: i16 = @intFromFloat(@ceil(@max(size.data[0], size.data[1], size.data[2]) / 2));
        var x: i16 = -@as(i16, checkDistance);
        while (x <= checkDistance) : (x += 1) {
            var y: i16 = -@as(i16, checkDistance);
            while (y <= checkDistance) : (y += 1) {
                var z: i16 = -@as(i16, checkDistance);
                while (z <= checkDistance) : (z += 1) {
                    const offset = @Vector(3, f64){ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
                    const blockPos = base + offset;

                    const block = try reader.getBlock(io, allocator, @intFromFloat(blockPos), World.standard_level);
                    if (!block.isSolid()) continue;

                    const blockAABB = zm.AABB(3, f64).init(.{ .data = blockPos + @Vector(3, f64){ -0.5, -0.5, -0.5 } }, .{ .data = blockPos + @Vector(3, f64){ 0.5, 0.5, 0.5 } });

                    var selfAABB = self.boundingBox;
                    selfAABB.min = selfAABB.min.add(.{ .data = pos });
                    selfAABB.max = selfAABB.max.add(.{ .data = pos });

                    const mtv = getAABBpenetration(blockAABB, selfAABB); // single-axis MTV or zero

                    if (mtv[0] == 0.0 and mtv[1] == 0.0 and mtv[2] == 0.0) continue;

                    const mag = @max(@abs(mtv[0]), @max(@abs(mtv[1]), @abs(mtv[2])));

                    if (!found or mag > bestMagnitude) {
                        bestMagnitude = mag;
                        bestMtv = mtv;
                        found = true;
                    }
                }
            }
        }

        if (!found) return null;
        return bestMtv;
    }

    // Return signed per-axis intersection vector (zero if no overlap)
    fn getAABBintersect(a: zm.AABB(3, f64), b: zm.AABB(3, f64)) @Vector(3, f64) {
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
    fn getAABBpenetration(a: zm.AABB(3, f64), b: zm.AABB(3, f64)) @Vector(3, f64) {
        const i = getAABBintersect(a, b);
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
    enabled: bool = true,
    up: @Vector(3, f64) = .{ 0, 1, 0 },
    ///the strength of the gravity in blocks per second squared
    strength: f64 = 9.8,

    pub fn update(self: *@This(), io: std.Io, physics: anytype, deltaT: f64, world: *World, allocator: std.mem.Allocator) !void {
        if (!self.enabled) return;
        _ = world;
        _ = allocator;
        _ = io;
        const velOffset = @as(@Vector(3, f64), @splat(self.strength)) * self.up * @as(@Vector(3, f64), @splat(deltaT));
        _ = physics.velocity.fetchAdd(-velOffset, .seq_cst);
    }
};

pub const Resistance = struct {
    enabled: bool = true,
    ///after one second the velocity will be this fraction of the original velocity
    fraction_per_second: f64 = 0.1,

    pub fn update(self: *@This(), io: std.Io, physics: anytype, deltaT: f64, world: *World, allocator: std.mem.Allocator) !void {
        if (!self.enabled) return;
        _ = world;
        _ = allocator;
        _ = deltaT;
        _ = physics;
        _ = io;
    }
};

test "AABB intersection" {
    if (true) return error.SkipZigTest;
    const testing = std.testing;

    const aabb1 = zm.AABB(3, f64).init(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    const aabb2 = zm.AABB(3, f64).init(.{ 0.5, 0.5, 0.5 }, .{ 1.5, 1.5, 1.5 });
    const aabb3 = zm.AABB(3, f64).init(.{ 2, 2, 2 }, .{ 3, 3, 3 });

    const intersect12 = Mover.getAABBintersect(aabb1, aabb2);
    try testing.expect(intersect12[0] != 0 and intersect12[1] != 0 and intersect12[2] != 0);

    const intersect13 = Mover.getAABBintersect(aabb1, aabb3);
    try testing.expect(std.meta.eql(intersect13, .{ 0, 0, 0 }));
}

test "AABB penetration" {
    if (true) return error.SkipZigTest;

    const testing = std.testing;

    const aabb1 = zm.AABB(3, f64).init(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    const aabb2 = zm.AABB(3, f64).init(.{ 0.8, 0.9, 0.7 }, .{ 1.8, 1.9, 1.7 });

    const penetration = Mover.getAABBpenetration(aabb1, aabb2);
    try testing.expect(penetration[0] == 0 and penetration[1] != 0 and penetration[2] == 0);
}

test "Gravity" {
    if (true) return error.SkipZigTest;

    const testing = std.testing;
    const physics_interface = getInterface(struct { gravity: Gravity });
    var physics_object = physics_interface{
        .elements = .{ .gravity = .{} },
        .last_update = .now(testing.io, .awake),
        .pos = .{ .vector = .{ 0, 0, 0 } },
        .velocity = .{ .vector = .{ 0, 0, 0 } },
    };
    _ = physics_object.lapUpdateTimer(testing.io);
    try testing.io.sleep(.fromMilliseconds(10), .awake);
    try physics_object.update(undefined, testing.io, std.testing.allocator); //world is not used so this is ok
    try testing.expect(physics_object.velocity.load(.seq_cst)[1] < 0);
}

test "simpleMover" {
    if (true) return error.SkipZigTest;

    const testing = std.testing;
    const physics_interface = getInterface(struct { mover: simpleMover });
    var physics_object = physics_interface{
        .elements = .{ .mover = .{} },
        .last_update = .now(testing.io, .awake),
        .pos = .{ .vector = .{ 0, 0, 0 } },
        .velocity = .{ .vector = .{ 0, 0, 0 } },
    };
    _ = physics_object.lapUpdateTimer(testing.io);
    try testing.io.sleep(.fromMilliseconds(10), .awake);
    try physics_object.update(undefined, testing.io, std.testing.allocator); //world is not used so this is ok
    try testing.expect(physics_object.pos.load(.seq_cst)[0] > 0);
}
