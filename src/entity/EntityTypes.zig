const std = @import("std");

const tracy = @import("tracy");
const zm = @import("zm");

const Sphere = @import("../world/structures/Sphere.zig").Sphere;
const World = @import("../world/World.zig");
const Entity = @import("Entity.zig");
const Item = @import("Item.zig");
const Physics = @import("Physics.zig");

/// The pinned player. Only the frame thread touches it, so it needs no locks; other
/// tasks get copies of what they need.
pub const Player = struct {
    game_mode: GameMode,
    /// Base-2 log of the fly speed, so scrolling scales it evenly.
    fly_speed_linear: f32 = 10,
    main_inventory: Item.Inventory,
    /// The inventory slot the player holds.
    selected_row: u32 = 0,
    selected_col: u32 = 0,
    view_direction: @Vector(3, f32),

    jump_held: bool = false,
    jump_rising: bool = false,
    /// Remaining window to still jump after leaving the ground.
    coyote_ns: u64 = 0,
    /// Remaining window for a jump pressed just before landing.
    jump_buffer_ns: u64 = 0,

    body: Physics.Body,

    pub const GameMode = enum(u8) {
        Survival = 0,
        Creative = 1,
        Spectator = 3,
    };

    pub fn unload(ptr: *Entity.Implementation, _: std.Io, _: *World, _: Entity.Handle, allocator: std.mem.Allocator) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.main_inventory.deinit(allocator);
        allocator.destroy(self);
    }

    fn rules(game_mode: GameMode) Physics.Body.Rules {
        return .{
            .gravity = game_mode == .Survival,
            .collisions = game_mode != .Spectator,
            .zero_velocity = game_mode == .Spectator,
        };
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
        tuning: Tuning,
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

    pub fn selectedItem(self: *const @This()) ?Item.Item {
        return self.main_inventory.get(self.selected_row, self.selected_col);
    }

    /// Moves the selection, clamping to the inventory grid.
    pub fn selectSlot(self: *@This(), row: u32, col: u32) void {
        self.selected_row = @min(row, self.main_inventory.height - 1);
        self.selected_col = @min(col, self.main_inventory.width - 1);
    }

    /// Sets the velocity straight from the wish, so fly input is frame-independent.
    pub fn fly(self: *@This(), wish: @Vector(3, f64)) void {
        const speed: f64 = @min(@as(f32, @floatFromInt(std.math.maxInt(i32))), std.math.pow(f32, 2, self.fly_speed_linear));
        self.body.velocity = wish * @as(@Vector(3, f64), @splat(speed));
    }

    /// Steers the velocity for one frame.
    pub fn walk(self: *@This(), io: std.Io, allocator: std.mem.Allocator, world: *World, input: WalkInput) !void {
        const z: tracy.Zone = .begin(.{ .src = @src(), .name = "walkMove" });
        defer z.end();
        const dt_s = @min(@as(f64, @floatFromInt(input.elapsed_ns)) / std.time.ns_per_s, max_physics_dt);

        var block_reader: World.Reader = .{ .world = world };
        defer block_reader.clear(io);

        const mover = &self.body.mover;
        const on_ground = try mover.isSupported(io, allocator, self.body.pos, &block_reader);
        const climbing = mover.climb_target_y != null;
        const medium = try mover.mediumAt(io, allocator, self.body.pos, &block_reader);
        const fluid = medium.fluid_fraction;

        const base_speed: f64 = @max(input.tuning.walk_speed, 0);
        const sprint: f64 = if (input.sprint) @max(input.tuning.sprint_multiplier, 1.0) else 1.0;
        const jump_speed = @sqrt(2 * self.body.gravity * @max(input.tuning.jump_height, 0.0));

        var velocity = self.body.velocity;
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

        if (fluid > 0) applyFluid(&velocity, medium, self.body.gravity, input.jump, dt_s);

        velocity[1] = @max(velocity[1], -walk_terminal_speed);
        self.body.velocity = velocity;
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

    /// Clamps and applies tuning to the live body.
    pub fn applyTuning(self: *@This(), tuning: Tuning) void {
        const z: tracy.Zone = .begin(.{ .src = @src(), .name = "applyTuning" });
        defer z.end();
        const mover = &self.body.mover;
        mover.step_height = std.math.clamp(@as(f64, tuning.step_height), 0, max_step_height);
        mover.step_climb_speed = @max(@as(f64, tuning.step_climb_speed), 1.0);

        const height: f64 = tuning.height;
        const new_box = Physics.Mover.boxFor(tuning.width, height);
        const box_changed = !std.meta.eql(mover.bounding_box.min.data, new_box.min.data) or
            !std.meta.eql(mover.bounding_box.max.data, new_box.max.data);
        if (!box_changed) return;

        // Keep the feet planted when the height changes.
        const old_height = mover.bounding_box.size().data[1];
        mover.bounding_box = new_box;
        self.body.pos[1] += (height - old_height) / 2;
    }

    pub fn update(ptr: *Entity.Implementation, ctx: Entity.UpdateContext) error{ Canceled, Unrecoverable }!void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "updatePlayer" });
        defer zone.end();

        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.body.update(ctx.io, ctx.allocator, ctx.world, rules(self.game_mode)) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.Unrecoverable,
        };
    }

    pub fn getInterface(_: *const @This()) Entity.Interface {
        return .{ .unload = unload, .update = update };
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
