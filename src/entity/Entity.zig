const std = @import("std");

const World = @import("../world/World.zig");

const Entity = @This();

pub const Implementation = opaque {};

pub const UpdateError = error{ Canceled, Unrecoverable, OutOfMemory };

type: Type,
uuid: u128,
ptr: *Implementation,
ref_count: std.atomic.Value(u32),
/// Set to true when the entity should stop updating and be unloaded as soon
/// as its ref count settles to the cache owned ref. Safe to call from any
/// thread at any time.
deleted: std.atomic.Value(bool) = .init(false),
vtable: Interface,

pub const Interface = struct {
    /// Updates the entity. Returns true when the entity requests deletion.
    update: ?*const fn (ptr: *Implementation, io: std.Io, world: *World, uuid: u128, allocator: std.mem.Allocator) UpdateError!bool = null,
    /// Frees the implementation and everything it allocated.
    /// The ptr is not valid after this. Implementations must not acquire locks
    /// that are held anywhere the entity system is called into.
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

/// Marks the entity for deletion. It stops being updated and is unloaded,
/// deleting any saved state, once no other references remain.
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
