const std = @import("std");

const World = @import("../world/World.zig");
const EntityRegistry = @import("EntityRegistry.zig");

const Entity = @This();

pub const Implementation = opaque {};

pub const UpdateError = error{ Canceled, Unrecoverable, OutOfMemory };

/// Handed to every update. An entity drives its own continuation: call
/// reschedule to run again after a delay (zero fires on the next drain, never
/// the current one) or delete to be reaped. Returning without either parks the
/// entity dormant until an external schedule wakes it.
pub const UpdateContext = struct {
    io: std.Io,
    world: *World,
    allocator: std.mem.Allocator,
    /// Watermark of the running drain, in nanoseconds.
    now_ns: u64,
    uuid: u128,
    registry: *EntityRegistry,

    /// Re-arm this entity's timer delay_ms from the drain watermark. Safe from
    /// inside update: the in-flight claim records it and settle applies it
    /// after the return, so zero lands on the next drain, never this one.
    pub fn reschedule(self: UpdateContext, delay_ms: u64) void {
        _ = self.registry.rescheduleAt(self.io, self.uuid, self.now_ns, delay_ms);
    }

    /// Flag this entity for deletion; the drain reaps it once unreferenced.
    pub fn delete(self: UpdateContext) void {
        _ = self.registry.markDeleted(self.io, self.uuid);
    }
};

type: Type,
uuid: u128,
ptr: *Implementation,
ref_count: std.atomic.Value(u32),
/// Flags deletion; unloads once only the cache-owned ref remains. Safe from any thread.
deleted: std.atomic.Value(bool) = .init(false),
/// Index into the registry's timer slab, or no_timer while the slot is free.
/// Written under the scheduler mutex plus the entity shard lock; readable with
/// either held while a reference is pinned.
timer_slot: u32 = no_timer,
vtable: Interface,

/// Sentinel for timer_slot: the entity holds no timer-slab slot.
pub const no_timer: u32 = std.math.maxInt(u32);

pub const Interface = struct {
    /// Runs one due update. Call ctx.reschedule to keep the entity running or
    /// ctx.delete to remove it; return to park.
    update: ?*const fn (ptr: *Implementation, ctx: UpdateContext) UpdateError!void = null,
    /// Frees the implementation after this call. Must not acquire locks held where the entity system runs.
    unload: *const fn (ptr: *Implementation, io: std.Io, world: *World, uuid: u128, allocator: std.mem.Allocator, save: bool) error{SavingFailed}!void,
    getPos: ?*const fn (ptr: *Implementation, io: std.Io) @Vector(3, f64) = null,
};

pub inline fn keyFromValue(self: *const @This()) u128 {
    return self.uuid;
}

pub fn addRef(self: *@This()) void {
    _ = self.ref_count.fetchAdd(1, .seq_cst);
}

pub fn release(self: *@This()) void {
    _ = self.ref_count.fetchSub(1, .seq_cst);
}

/// Flags deletion; unloads once unreferenced, deleting saved state.
pub fn markDeleted(self: *@This()) void {
    self.deleted.store(true, .seq_cst);
}

pub fn isDeleted(self: *const @This()) bool {
    return self.deleted.load(.seq_cst);
}

pub fn getPos(self: *@This(), io: std.Io) ?@Vector(3, f64) {
    if (self.vtable.getPos) |getPosFn| {
        return getPosFn(self.ptr, io);
    }
    return null;
}

pub const Type = enum(u32) {
    Player = 0,
    Explosive = 2,
};
