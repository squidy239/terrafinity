const std = @import("std");

const tracy = @import("tracy");
const zm = @import("zm");

const Sphere = @import("../world/structures/Sphere.zig").Sphere;
const World = @import("../world/World.zig");
const Entity = @import("Entity.zig");
const Item = @import("Item.zig");
const Physics = @import("Physics.zig");

pub const Player = struct {
    player_name: Name,
    game_mode: std.atomic.Value(GameMode),
    fly_speed: std.atomic.Value(f32) = .init(1024),
    walk_speed: std.atomic.Value(f32) = .init(8),
    /// Speed multiple while the sprint key is held; at least 1.
    sprint_multiplier: std.atomic.Value(f32) = .init(1.6),
    jump_strength: std.atomic.Value(f32) = .init(8),
    fly_speed_linear: std.atomic.Value(f32) = .init(10),
    inventory_buffer: [10 * 16]?Item.Item = @splat(null),
    main_inventory: Item.Inventory,
    view_direction: @Vector(3, f32),
    view_direction_mutex: std.Io.Mutex = .init,

    // Jump-feel state, driven only on the frame lane.
    jump_held: bool = false,
    jump_rising: bool = false,
    /// Remaining window to still jump after leaving the ground.
    coyote_ns: u64 = 0,
    /// Remaining window for a jump pressed just before landing.
    jump_buffer_ns: u64 = 0,

    physics: Physics.Interface(struct {
        gravity: Physics.Gravity,
        mover: Physics.Mover,
    }),

    pub const Name = struct {
        data: [64]u8,
        len: u8,

        pub fn fromString(str: anytype) @This() {
            std.debug.assert(str.len < 64);
            var name: @This() = .{ .data = undefined, .len = @intCast(str.len) };
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

    pub const unload = Entity.DestroyUnload(@This()).unload;

    pub fn getPos(ptr: *Entity.Implementation, io: std.Io) @Vector(3, f64) {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.physics.mutex.lockUncancelable(io);
        defer self.physics.mutex.unlock(io);
        return self.physics.pos;
    }

    pub fn switchGameMode(self: *@This(), game_mode: GameMode) void {
        self.game_mode.store(game_mode, .monotonic);
        self.physics.elements.mover.enabled.store(true, .monotonic);

        const is_spectator = game_mode == .Spectator;
        const is_survival = game_mode == .Survival;

        self.physics.elements.mover.zero_velocity.store(is_spectator, .monotonic);
        self.physics.elements.mover.collisions.store(!is_spectator, .monotonic);
        self.physics.elements.gravity.enabled.store(is_survival, .monotonic);
    }

    // Locomotion feel, in blocks and seconds. Horizontal speed comes from the player.
    const walk_accel_ground: f64 = 60.0;
    /// Deceleration per unit of walk speed, so stopping time stays constant as speed changes.
    const walk_decel_ground: f64 = 90.0;
    const walk_accel_air: f64 = 20.0;
    const walk_accel_water: f64 = 40.0;
    const walk_decel_water: f64 = 40.0;
    const walk_terminal_speed: f64 = 60.0;
    const coyote_window_ns: u64 = 100 * std.time.ns_per_ms;
    const jump_buffer_window_ns: u64 = 150 * std.time.ns_per_ms;
    /// Fraction of upward speed kept when the jump key is released early.
    const jump_cut_factor: f64 = 0.5;
    const max_physics_dt: f64 = 0.1;
    /// Step settle walks one block per resolve pass, so keep the step within reach.
    const max_step_height: f64 = 4.0;

    const fluid_drag: f64 = 8.0;
    const fluid_swim_accel: f64 = 24.0;
    const fluid_swim_speed: f64 = 4.0;
    const fluid_speed_loss: f64 = 1.0;
    /// Buoyancy-weighted submersion past which the body cannot jump.
    const fluid_jump_block: f64 = 0.3;

    /// One frame of walking input.
    pub const WalkInput = struct {
        /// Unit horizontal direction, or zero when no movement key is held.
        wish: @Vector(2, f64),
        sprint: bool,
        jump: bool,
        elapsed_ns: u64,
    };

    /// User-tunable body and movement settings, before clamping.
    pub const Tuning = struct {
        width: f32,
        height: f32,
        step_height: f32,
        step_climb_speed: f32,
        jump_height: f32,
        walk_speed: f32,
        sprint_multiplier: f32,
    };

    pub fn viewDirection(self: *@This(), io: std.Io) @Vector(3, f32) {
        self.view_direction_mutex.lockUncancelable(io);
        defer self.view_direction_mutex.unlock(io);
        return self.view_direction;
    }

    /// Sets the velocity straight from the wish, so fly input is frame-independent.
    pub fn fly(self: *@This(), io: std.Io, wish: @Vector(3, f64)) void {
        const speed: f64 = self.fly_speed.load(.unordered);
        self.physics.mutex.lockUncancelable(io);
        defer self.physics.mutex.unlock(io);
        self.physics.velocity = wish * @as(@Vector(3, f64), @splat(speed));
    }

    /// Steers the velocity for one frame on the frame lane. World reads run before the physics lock.
    pub fn walk(self: *@This(), io: std.Io, allocator: std.mem.Allocator, world: *World, input: WalkInput) !void {
        const z: tracy.Zone = .begin(.{ .src = @src(), .name = "walkMove" });
        defer z.end();
        const dt_s = @min(@as(f64, @floatFromInt(input.elapsed_ns)) / std.time.ns_per_s, max_physics_dt);

        var block_reader: World.Reader = .{ .world = world };
        defer block_reader.clear(io);

        const mover = &self.physics.elements.mover;
        const player_pos = getPos(@ptrCast(self), io);
        const on_ground = try mover.isSupported(io, allocator, player_pos, &block_reader);
        const climbing = mover.climb_target_y != null;
        const medium = try mover.mediumAt(io, allocator, player_pos, &block_reader);
        const fluid = medium.fluid_fraction;

        const base_speed: f64 = self.walk_speed.load(.unordered);
        const sprint: f64 = if (input.sprint) self.sprint_multiplier.load(.unordered) else 1.0;
        const jump_speed: f64 = self.jump_strength.load(.unordered);
        const gravity: f64 = self.physics.elements.gravity.strength.load(.monotonic);

        self.physics.mutex.lockUncancelable(io);
        defer self.physics.mutex.unlock(io);
        var velocity = self.physics.velocity;
        const moving = input.wish[0] != 0 or input.wish[1] != 0;

        // A step in progress counts as ground, so the body can launch off it.
        const buoyant = medium.buoyancy * fluid;
        const jumped = self.applyJump(&velocity, on_ground or climbing, buoyant, input.jump, jump_speed, input.elapsed_ns);
        if (jumped) mover.climb_target_y = null;

        // Sprint scales the target, so it still has to fight the same fluid drag.
        const speed = targetSpeed(base_speed, sprint, fluid, medium.resistance);
        const control = if (fluid > 0) walk_accel_water else if (on_ground) walk_accel_ground else walk_accel_air;
        const decel = base_speed * @as(f64, if (fluid > 0) walk_decel_water else walk_decel_ground);
        const steers = on_ground or fluid > 0;

        const current: @Vector(2, f64) = .{ velocity[0], velocity[2] };
        const target = input.wish * @as(@Vector(2, f64), @splat(speed));
        const horizontal = if (steers or moving)
            approachHorizontal(current, target, (if (moving) control else decel) * dt_s)
        else
            current;
        velocity[0] = horizontal[0];
        velocity[2] = horizontal[1];

        if (fluid > 0) applyFluid(&velocity, medium, gravity, input.jump, dt_s);

        velocity[1] = @max(velocity[1], -walk_terminal_speed);
        self.physics.velocity = velocity;
    }

    /// Jump feel: coyote time, an input buffer, and release-to-shorten. A step in
    /// progress counts as ground; a jump abandons the step. Returns whether a jump
    /// fired, so the caller can cancel any pending climb.
    fn applyJump(self: *@This(), velocity: *@Vector(3, f64), grounded: bool, buoyant: f64, jump_pressed: bool, jump_speed: f64, dt_ns: u64) bool {
        const can_jump = grounded and buoyant < fluid_jump_block;
        const jump_edge = jump_pressed and !self.jump_held;
        self.jump_held = jump_pressed;
        self.coyote_ns = if (can_jump) coyote_window_ns else self.coyote_ns -| dt_ns;
        self.jump_buffer_ns = if (jump_edge) jump_buffer_window_ns else self.jump_buffer_ns -| dt_ns;
        if (self.jump_buffer_ns > 0 and self.coyote_ns > 0) {
            velocity[1] = jump_speed;
            self.jump_buffer_ns = 0;
            self.coyote_ns = 0;
            self.jump_rising = true;
            return true;
        }
        if (!self.jump_rising) return false;
        if (!jump_pressed and velocity[1] > 0) velocity[1] *= jump_cut_factor;
        if (!jump_pressed or velocity[1] <= 0) self.jump_rising = false;
        return false;
    }

    /// Target horizontal speed in blocks per second. Sprint scales the base speed and
    /// fluid divides it back down by how much of the body it covers and how hard it
    /// resists, so sprinting in water is still slower than sprinting on land.
    fn targetSpeed(base_speed: f64, sprint: f64, fluid: f64, resistance: f64) f64 {
        return sprint * base_speed / (1 + fluid_speed_loss * fluid * resistance);
    }

    /// Buoyancy lifts with the submerged fraction and drag drains every axis, scaled by
    /// the fluid's resistance. The swim clamp only applies to a buoyant fluid, so leaves
    /// slow the fall instead of holding the body at swim speed.
    fn applyFluid(velocity: *@Vector(3, f64), medium: Physics.Mover.Medium, gravity: f64, jump_pressed: bool, dt_s: f64) void {
        const submerged = medium.fluid_fraction;
        const buoyant = medium.buoyancy * submerged;
        const drag = @min(1.0, fluid_drag * medium.resistance * dt_s * submerged);
        velocity[0] -= velocity[0] * drag;
        velocity[2] -= velocity[2] * drag;
        velocity[1] += gravity * buoyant * dt_s;
        velocity[1] -= velocity[1] * drag;
        if (buoyant <= 0) return;
        if (jump_pressed) velocity[1] = @min(velocity[1] + fluid_swim_accel * dt_s, fluid_swim_speed);
        velocity[1] = std.math.clamp(velocity[1], -fluid_swim_speed, fluid_swim_speed);
    }

    /// Moves a horizontal velocity toward a target by at most `max_delta`.
    fn approachHorizontal(current: @Vector(2, f64), target: @Vector(2, f64), max_delta: f64) @Vector(2, f64) {
        const delta = target - current;
        const length = @sqrt(@reduce(.Add, delta * delta));
        if (length == 0 or length <= max_delta) return target;
        return current + delta / @as(@Vector(2, f64), @splat(length)) * @as(@Vector(2, f64), @splat(max_delta));
    }

    /// Clamps and applies tuning to the live body. Runs on the frame lane, where the body integrates.
    pub fn applyTuning(self: *@This(), io: std.Io, tuning: Tuning) void {
        const z: tracy.Zone = .begin(.{ .src = @src(), .name = "applyTuning" });
        defer z.end();
        const mover = &self.physics.elements.mover;
        mover.step_height = std.math.clamp(@as(f64, tuning.step_height), 0, max_step_height);
        mover.step_climb_speed = @max(@as(f64, tuning.step_climb_speed), 1.0);

        self.walk_speed.store(@max(tuning.walk_speed, 0), .monotonic);
        self.sprint_multiplier.store(@max(tuning.sprint_multiplier, 1.0), .monotonic);

        const gravity: f64 = self.physics.elements.gravity.strength.load(.monotonic);
        const jump_height: f64 = @max(tuning.jump_height, 0.0);
        self.jump_strength.store(@floatCast(@sqrt(2 * gravity * jump_height)), .monotonic);

        const height: f64 = tuning.height;
        const new_box = Physics.Mover.boxFor(tuning.width, height);
        const box_changed = !std.meta.eql(mover.bounding_box.min.data, new_box.min.data) or
            !std.meta.eql(mover.bounding_box.max.data, new_box.max.data);
        if (!box_changed) return;

        self.physics.mutex.lockUncancelable(io);
        defer self.physics.mutex.unlock(io);
        // Keep the feet planted when the height changes.
        const old_height = mover.bounding_box.size().data[1];
        mover.bounding_box = new_box;
        self.physics.pos[1] += (height - old_height) / 2;
    }

    pub fn update(ptr: *Entity.Implementation, ctx: Entity.UpdateContext) error{ Canceled, Unrecoverable }!void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "updatePlayer" });
        defer zone.end();

        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.physics.update(ctx.world, ctx.io, ctx.allocator) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.Unrecoverable,
        };
    }

    pub fn getInterface(_: *const @This()) Entity.Interface {
        return .{ .getPos = getPos, .unload = unload, .update = update };
    }
};

pub const Explosive = struct {
    /// Blocks travelled per second along the unit direction.
    const travel_speed: f32 = 10;
    /// Blast sphere radius in blocks.
    const blast_radius: f32 = 8;
    /// Largest integration step; a long drain gap must not skip past the blast radius.
    const max_step_s: f32 = 0.1;

    pos: @Vector(3, f64),
    /// Unit travel direction fixed at spawn; `update` integrates it into `pos` without renormalizing.
    dir: @Vector(3, f32),
    timestamp: i96,

    pub fn init(pos: @Vector(3, f64), dir: @Vector(3, f32), timestamp: i96) @This() {
        const unit = if (std.meta.eql(dir, @Vector(3, f32){ 0, 0, 0 }))
            dir
        else
            zm.Vec3f.norm(.{ .data = dir }).data;
        return .{ .pos = pos, .dir = unit, .timestamp = timestamp };
    }

    pub fn update(ptr: *Entity.Implementation, ctx: Entity.UpdateContext) error{ Canceled, Unrecoverable, OutOfMemory }!void {
        const u = tracy.Zone.begin(.{ .src = @src(), .name = "updateExplosive" });
        defer u.end();
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const len_sq = @reduce(.Add, self.dir * self.dir);
        std.debug.assert(len_sq == 0 or std.math.approxEqAbs(f32, len_sq, 1, 1e-5));

        var editor = World.Editor{ .world = ctx.world, .temp_allocator = ctx.allocator };
        try editor.placeSamplerShape(.air, Sphere(f32).init(@floatCast(self.pos), blast_radius), World.standard_level);

        // The drain supplies the watermark; sampling the wall here would drift under late firing.
        const now_i96: i96 = @intCast(ctx.now_ns);
        const dt = @min(@as(f32, @floatFromInt(now_i96 - self.timestamp)) / std.time.ns_per_s, max_step_s);
        self.timestamp = now_i96;

        const move = self.dir * @as(@Vector(3, f32), @splat(travel_speed * dt));
        self.pos += @as(@Vector(3, f64), @floatCast(move));

        try editor.placeSamplerShape(.grass, Sphere(f32).init(@floatCast(self.pos), blast_radius), World.standard_level);
        editor.flush(ctx.io, ctx.allocator) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unrecoverable,
        };
        ctx.reschedule(0);
    }

    pub const unload = Entity.DestroyUnload(@This()).unload;

    pub fn getInterface(_: *const @This()) Entity.Interface {
        return .{ .unload = unload, .update = update };
    }
};
