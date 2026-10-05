const std = @import("std");

const World = @import("../world/World.zig");
const EntityRegistry = @import("EntityRegistry.zig");

const Entity = @This();

pub const Implementation = opaque {};

/// Canceled unwinds the pass as a cancellation; any other error is fatal to the game.
pub const UpdateError = error{ Canceled, Unrecoverable, OutOfMemory };

/// Handed to every update. Call reschedule to run again later (zero fires on the
/// next drain) or delete to be reaped; returning parks the entity dormant.
pub const UpdateContext = struct {
    io: std.Io,
    world: *World,
    allocator: std.mem.Allocator,
    /// Watermark of the running drain.
    now_ns: u64,
    uuid: Handle,
    registry: *EntityRegistry,

    /// Re-arm from the drain watermark; recorded on the in-flight claim and
    /// applied after the update returns, so zero lands on the next drain.
    pub fn reschedule(self: UpdateContext, delay_ms: u64) void {
        _ = self.registry.rescheduleAt(self.io, self.uuid, self.now_ns, delay_ms);
    }

    pub fn delete(self: UpdateContext) void {
        _ = self.registry.markDeleted(self.io, self.uuid);
    }
};

uuid: Handle,
ptr: *Implementation,
ref_count: std.atomic.Value(u32),
deleted: std.atomic.Value(bool) = .init(false),
/// Index into the registry's timer slab; every resident entity owns one.
timer_slot: u32,
vtable: Interface,

pub const Interface = struct {
    /// Call ctx.reschedule to keep running or ctx.delete to remove; return parks.
    update: ?*const fn (ptr: *Implementation, ctx: UpdateContext) UpdateError!void = null,
    /// Frees the implementation. Must not acquire locks held where the entity system runs.
    unload: *const fn (ptr: *Implementation, io: std.Io, world: *World, uuid: Handle, allocator: std.mem.Allocator) void,
    getPos: ?*const fn (ptr: *Implementation, io: std.Io) @Vector(3, f64) = null,
};

pub inline fn keyFromValue(self: *const @This()) Handle {
    return self.uuid;
}

pub fn addRef(self: *@This()) void {
    _ = self.ref_count.fetchAdd(1, .seq_cst);
}

pub fn release(self: *@This()) void {
    _ = self.ref_count.fetchSub(1, .seq_cst);
}

/// Flags deletion; unloads once unreferenced.
pub fn markDeleted(self: *@This()) void {
    self.deleted.store(true, .seq_cst);
}

/// Weak reference to a resident entity, keyed by uuid. Resolve it with
/// `EntityRegistry.getAndAddRef`: a miss means the entity was evicted, and the
/// returned `*Entity` carries a caller-owned reference the caller must release.
/// A handle does not keep its entity resident; some owner must hold that ref.
pub const Handle = u64;
