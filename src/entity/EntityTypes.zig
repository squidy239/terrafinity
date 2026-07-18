const std = @import("std");

const tracy = @import("tracy");
const zm = @import("zm");

const Block = @import("../world/Block.zig").Block;
const Sphere = @import("../world/structures/Sphere.zig").Sphere;
const World = @import("../world/World.zig");
const Entity = @import("Entity.zig");
const Item = @import("Item.zig");
const Physics = @import("Physics.zig");

pub const Player = struct {
    pub const Type = Entity.Type.Player;
    player_name: Name,
    game_mode: std.atomic.Value(GameMode),
    fly_speed: std.atomic.Value(f32) = .init(100),
    walk_speed: std.atomic.Value(f32) = .init(8),
    jump_strength: std.atomic.Value(f32) = .init(8),
    fly_speed_linear: std.atomic.Value(f32) = .init(10),
    inventory_buffer: [10 * 16]?Item.Item = @splat(null),
    /// Main inventory and hotbar.
    main_inventory: Item.Inventory,
    /// Pitch, yaw, roll, in degrees.
    view_direction: @Vector(3, f32),
    view_direction_mutex: std.Io.Mutex = .init,

    physics: Physics.Interface(struct {
        gravity: Physics.Gravity,
        resistance: Physics.Resistance,
        mover: Physics.Mover,
    }),

    pub const Name = struct {
        data: [64]u8,
        len: u8,

        pub fn fromString(str: anytype) @This() {
            var name = @This(){
                .data = undefined,
                .len = str.len,
            };
            std.debug.assert(str.len < name.data.len);
            @memcpy(name.data[0..str.len], str);
            return name;
        }

        pub fn toString(self: @This()) []const u8 {
            return self.data[0..self.len];
        }
    };

    pub const GameMode = enum(u8) {
        Survival = 0,
        Creative = 1,
        Spectator = 3,
    };

    pub fn unload(entity: *Entity, io: std.Io, world: *World, uuid: u128, allocator: std.mem.Allocator, save: bool) error{SavingFailed}!void {
        _ = save;
        _ = uuid;
        _ = world;
        _ = io;
        const self: *@This() = @ptrCast(@alignCast(entity.ptr));
        allocator.destroy(self);
        allocator.destroy(entity);
    }

    pub fn getPos(ptr: *Entity.Implementation, io: std.Io) @Vector(3, f64) {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.physics.mutex.lockUncancelable(io);
        defer self.physics.mutex.unlock(io);

        return self.physics.pos;
    }

    pub fn switchGameMode(self: *@This(), gameMode: GameMode) void {
        self.game_mode.store(gameMode, .monotonic);

        switch (gameMode) {
            .Spectator => {
                self.physics.elements.mover.enabled.store(true, .monotonic);
                self.physics.elements.mover.zero_velocity.store(true, .monotonic);
                self.physics.elements.mover.collisions.store(false, .monotonic);
                self.physics.elements.gravity.enabled.store(false, .monotonic);
                self.physics.elements.resistance.enabled.store(false, .monotonic);
            },
            .Survival => {
                self.physics.elements.mover.enabled.store(true, .monotonic);
                self.physics.elements.mover.zero_velocity.store(false, .monotonic);
                self.physics.elements.mover.collisions.store(true, .monotonic);
                self.physics.elements.gravity.enabled.store(true, .monotonic);
                self.physics.elements.resistance.enabled.store(true, .monotonic);
            },
            .Creative => {
                self.physics.elements.mover.enabled.store(true, .monotonic);
                self.physics.elements.mover.zero_velocity.store(false, .monotonic);
                self.physics.elements.mover.collisions.store(true, .monotonic);
                self.physics.elements.gravity.enabled.store(false, .monotonic);
                self.physics.elements.resistance.enabled.store(true, .monotonic);
            },
        }
    }

    pub fn update(entity: *Entity, io: std.Io, world: *World, uuid: u128, allocator: std.mem.Allocator) error{ Canceled, Unrecoverable }!bool {
        _ = uuid;
        const self: *@This() = @ptrCast(@alignCast(entity.ptr));
        self.physics.update(world, io, allocator) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.Unrecoverable,
        };
        return false;
    }

    pub fn getInterface(self: *const @This()) Entity.Interface {
        _ = self;
        return .{
            .getPos = getPos,
            .unload = unload,
            .update = update,
        };
    }
};

pub const Explosive = struct {
    pub const Type: Entity.Type = .Explosive;
    pos: @Vector(3, f64),
    dir: @Vector(3, f32),
    timestamp: std.atomic.Value(i128),
    lock: std.Io.RwLock = .init,

    pub fn update(entity: *Entity, io: std.Io, world: *World, uuid: u128, allocator: std.mem.Allocator) error{ Canceled, Unrecoverable, OutOfMemory }!bool {
        const u = tracy.Zone.begin(.{ .src = @src(), .name = "updateCube" });
        defer u.end();
        const self: *@This() = @ptrCast(@alignCast(entity.ptr));
        var l = tracy.Zone.begin(.{ .src = @src(), .name = "lock" });
        defer l.end();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        const now_ns = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        const prev_ns = self.timestamp.load(.seq_cst);
        self.timestamp.store(now_ns, .seq_cst);
        const dt = @as(f32, @floatFromInt(now_ns - prev_ns)) * 1e-9;

        var dir = self.dir;
        var pos = self.pos;

        //dir[0] += (std.crypto.random.float(f64) - 0.5) * dt;
        //dir[1] += (std.crypto.random.float(f64) - 0.5) * dt;
        //dir[2] += (std.crypto.random.float(f64) - 0.5) * dt;
        if (!std.meta.eql(dir, @Vector(3, f32){ 0, 0, 0 })) dir = zm.Vec3f.norm(.{ .data = dir }).data;
        dir *= @splat(10 * dt);
        pos += dir;

        self.dir = dir;
        self.pos = pos;

        var worldReader = World.Reader{ .world = world };
        defer worldReader.clear(io);

        var g = tracy.Zone.begin(.{ .src = @src() });
        if (true or (worldReader.getBlockUncached(@trunc(pos), World.standard_level) catch unreachable) != .air) {
            g.end();
            var worldEditor = World.Editor{
                .world = world,
                .temp_allocator = allocator,
            };
            const sphere = Sphere(f32).init(@floatCast(pos), 8);
            try worldEditor.placeSamplerShape(.grass, sphere, World.standard_level);
            worldEditor.flush(io, allocator) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Unrecoverable,
            };
            return false;
        } else g.end();
        _ = uuid;
        return false;
    }

    pub fn unload(entity: *Entity, io: std.Io, world: *World, uuid: u128, allocator: std.mem.Allocator, save: bool) error{SavingFailed}!void {
        _ = save;
        _ = uuid;
        _ = world;
        _ = io;
        const self: *@This() = @ptrCast(@alignCast(entity.ptr));
        allocator.destroy(self);
        allocator.destroy(entity);
    }

    pub fn getPos(ptr: *Entity.Implementation, io: std.Io) @Vector(3, f64) {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        return self.pos;
    }

    pub fn getInterface(self: *const @This()) Entity.Interface {
        _ = self;
        return .{
            .getPos = getPos,
            .unload = unload,
            .update = update,
        };
    }
};
