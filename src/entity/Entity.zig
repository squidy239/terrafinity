const std = @import("std");

const World = @import("../world/World.zig");

const Entity = @This();

pub const Implementation = opaque {};

pub const UpdateError = error{ Canceled, Unrecoverable, OutOfMemory };

type: Type,
uuid: u128,
ptr: *Implementation,
ref_count: std.atomic.Value(u32),
/// Flags deletion; unloads once only the cache-owned ref remains. Safe from any thread.
deleted: std.atomic.Value(bool) = .init(false),
vtable: Interface,

pub const Interface = struct {
    /// Returns true when the entity requests deletion.
    update: ?*const fn (ptr: *Implementation, io: std.Io, world: *World, uuid: u128, allocator: std.mem.Allocator) UpdateError!bool = null,
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
