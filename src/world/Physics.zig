const std = @import("std");
const World = @import("root").World;
const Block = @import("root").Block;
const zm = @import("root").zm;
///gets a Physics interface, all functions are thread-safe
pub fn getInterface(physicsElements: anytype) type {
    return struct {
        elements: physicsElements,
        updateTimer: std.time.Timer,
        updateTimerLock: std.Thread.RwLock = .{},
        pos: @Vector(3, f64),
        posLock: std.Thread.RwLock = .{},
        velocity: @Vector(3, f64),
        velocityLock: std.Thread.RwLock = .{},

        pub fn getPos(self: *@This()) @Vector(3, f64) {
            self.posLock.lockShared();
            defer self.posLock.unlockShared();
            return self.pos;
        }

        pub fn lapUpdateTimer(self: *@This()) u64 {
            self.updateTimerLock.lock();
            defer self.updateTimerLock.unlock();
            return self.updateTimer.lap();
        }

        pub fn fetchAddPos(self: *@This(), offset: @Vector(3, f64)) @Vector(3, f64) {
            self.posLock.lock();
            defer self.posLock.unlock();
            self.pos += offset;
            return self.pos;
        }

        pub fn getVelocity(self: *@This()) @Vector(3, f64) {
            self.velocityLock.lockShared();
            defer self.velocityLock.unlockShared();
            return self.velocity;
        }

        pub fn fetchAddVelocity(self: *@This(), offset: @Vector(3, f64)) @Vector(3, f64) {
            self.velocityLock.lock();
            defer self.velocityLock.unlock();
            self.velocity += offset;
            return self.velocity;
        }

        pub fn update(self: *@This(), world: *World, allocator: std.mem.Allocator) !void {
            //deltaT is seconds
            const deltaT: f64 = @as(f64, @floatFromInt(self.lapUpdateTimer())) / std.time.ns_per_s;

            inline for (std.meta.fields(@TypeOf(self.elements))) |field| {
                const fieldData = &@field(&self.elements, field.name);
                try fieldData.update(self, deltaT, world, allocator);
            }
        }
    };
}

pub const simpleMover = struct {
    pub fn update(self: *@This(), physics: anytype, deltaT: f64, world: *World, allocator: std.mem.Allocator) !void {
        _ = self;
        _ = world;
        _ = allocator;
        const posOffset = physics.getVelocity() * @as(@Vector(3, f64), @splat(deltaT));
        _ = physics.fetchAddPos(posOffset);
    }
};

pub const Mover = struct {
    comptime moveDistance: f64 = 0.5,
    collisions: bool,
    boundingBox: zm.AABB,

    pub fn update(self: *@This(), physics: anytype, deltaT: f64, world: *World, allocator: std.mem.Allocator) !void {
        _ = allocator;
        const maxMove: @Vector(3, f64) = @splat(0.4);
        var reader = World.WorldReader{ .world = world };
        defer reader.Clear();
        var posOffset = physics.getVelocity() * @as(@Vector(3, f64), @splat(deltaT));
        while (!std.meta.eql(posOffset, @Vector(3, f64){ 0, 0, 0 })) {
            const move = std.math.clamp(posOffset, -maxMove, maxMove);
            posOffset -= move;
            var newPos = physics.fetchAddPos(move);

            while (try self.collision(newPos, &reader)) |mtv| {
                newPos = physics.fetchAddPos(-mtv);
                physics.velocityLock.lock();
                if (mtv[0] != 0.0) physics.velocity[0] = 0.0;
                if (mtv[1] != 0.0) physics.velocity[1] = 0.0;
                if (mtv[2] != 0.0) physics.velocity[2] = 0.0;
                physics.velocityLock.unlock();
            }
        }
    }

    pub fn collision(self: *const @This(), pos: @Vector(3, f64), reader: *World.WorldReader) !?@Vector(3, f64) {
        defer reader.Clear();

        const base = @floor(pos); // floor entity pos once
        var bestMtv: @Vector(3, f64) = @splat(0.0);
        var bestMagnitude: f64 = 0.0;
        var found: bool = false;
        const size = self.boundingBox.size();
        const checkDistance: i16 = @intFromFloat(@ceil(@max(size[0], size[1], size[2]) / 2));
        var x: i16 = -@as(i16, checkDistance);
        while (x <= checkDistance) : (x += 1) {
            var y: i16 = -@as(i16, checkDistance);
            while (y <= checkDistance) : (y += 1) {
                var z: i16 = -@as(i16, checkDistance);
                while (z <= checkDistance) : (z += 1) {
                    const offset = @Vector(3, f64){ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
                    const blockPos = base + offset;

                    const block = try reader.GetBlockCached(@intFromFloat(blockPos), 5);
                    if (!Block.Properties.solid.get(block)) continue;

                    const blockAABB = zm.AABB.init(blockPos + @Vector(3, f64){ -0.5, -0.5, -0.5 }, blockPos + @Vector(3, f64){ 0.5, 0.5, 0.5 });

                    var selfAABB = self.boundingBox;
                    selfAABB.min += pos;
                    selfAABB.max += pos;

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
    fn getAABBintersect(a: zm.AABB, b: zm.AABB) @Vector(3, f64) {
        if (a.max[0] <= b.min[0] or a.min[0] >= b.max[0] or
            a.max[1] <= b.min[1] or a.min[1] >= b.max[1] or
            a.max[2] <= b.min[2] or a.min[2] >= b.max[2])
        {
            return @Vector(3, f64){ 0.0, 0.0, 0.0 };
        }

        const ox = @min(a.max[0], b.max[0]) - @max(a.min[0], b.min[0]);
        const oy = @min(a.max[1], b.max[1]) - @max(a.min[1], b.min[1]);
        const oz = @min(a.max[2], b.max[2]) - @max(a.min[2], b.min[2]);

        // Use centers to derive direction so this MTV is the vector you should ADD to `a` to separate it.
        const ca = (a.min + a.max) * @Vector(3, f64){ 0.5, 0.5, 0.5 };
        const cb = (b.min + b.max) * @Vector(3, f64){ 0.5, 0.5, 0.5 };

        const sx = if (ca[0] < cb[0]) -ox else ox;
        const sy = if (ca[1] < cb[1]) -oy else oy;
        const sz = if (ca[2] < cb[2]) -oz else oz;

        return @Vector(3, f64){ sx, sy, sz };
    }

    // Choose the smallest absolute axis to form the minimum translation vector.
    fn getAABBpenetration(a: zm.AABB, b: zm.AABB) @Vector(3, f64) {
        const i = getAABBintersect(a, b);
        const ax = @abs(i[0]);
        const ay = @abs(i[1]);
        const az = @abs(i[2]);

        if (ax == 0.0 and ay == 0.0 and az == 0.0) return @splat(0.0);

        if (ax <= ay and ax <= az) return @Vector(3, f64){ i[0], 0.0, 0.0 };
        if (ay <= ax and ay <= az) return @Vector(3, f64){ 0.0, i[1], 0.0 };
        return @Vector(3, f64){ 0.0, 0.0, i[2] };
    }
};

pub const Gravity = struct {
    up: @Vector(3, f64) = .{ 0, 1, 0 },
    ///the strength of the gravity in meters per second squared
    strength: f64 = 9.8,

    pub fn update(self: *@This(), physics: anytype, deltaT: f64, world: *World, allocator: std.mem.Allocator) !void {
        _ = world;
        _ = allocator;
        const velOffset = @as(@Vector(3, f64), @splat(self.strength)) * self.up * @as(@Vector(3, f64), @splat(deltaT));
        _ = physics.fetchAddVelocity(-velOffset);
    }
};
