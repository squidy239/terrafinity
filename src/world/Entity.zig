const std = @import("std");
const Renderer = @import("../Game.zig").Renderer;
const World = @import("World.zig");
const ztracy = @import("ztracy");

const EntityTypes = @import("EntityTypes");

const Entity = @This();

type: Type,
ptr: *anyopaque,
ref_count: std.atomic.Value(u32) = .init(0),
vtable: interface,

pub const interface = struct {
    ///updates the entity, returns true if the entity was unloaded
    update: ?*const fn (self: *Entity, world: *World, uuid: u128, allocator: std.mem.Allocator) error{ TimedOut, Unrecoverable }!bool = null,
    ///unloads the entity and frees all resorces allocated by it
    ///the entity ptr is not valid after this
    unload: *const fn (self: *Entity, world: *World, uuid: u128, allocator: std.mem.Allocator, save: bool) error{SavingFailed}!void,
    getPos: ?*const fn (self: *anyopaque) @Vector(3, f64) = null,
    draw: ?*const fn (self: *anyopaque, world: *World, uuid: u128, allocator: std.mem.Allocator, playerPos: @Vector(3, f64), renderer: *Renderer) error{Unrecoverable}!void = null,
};

///this function removes a ref from entity when it returns
///the entity may be unloaded by this function
pub fn update(self: *@This(), world: *World, uuid: u128, allocator: std.mem.Allocator) !void {
    if (self.vtable.update) |updateFn| {
        const unloaded = try updateFn(self, world, uuid, allocator);
        if (!unloaded) _ = self.ref_count.fetchSub(1, .seq_cst);
    } else _ = self.ref_count.fetchSub(1, .seq_cst);
}

pub fn draw(self: *@This(), playerPos: @Vector(3, f64), uuid: u128, world: *World, r: *Renderer) !void {
    if (self.vtable.draw) |drawFn| {
        return try drawFn(self.ptr, world, uuid, world.allocator, playerPos, r);
    }
}
pub fn getPos(self: *@This()) ?@Vector(3, f64) {
    if (self.vtable.getPos) |getPosFn| {
        return getPosFn(self.ptr);
    }
    return null;
}

///unloads the entity and frees all resorces allocated by it
///the entity ptr is not valid after this
pub fn unload(self: *@This(), world: *World, uuid: u128, allocator: std.mem.Allocator, save: bool) !void {
    const unloadEntity = ztracy.ZoneNC(@src(), "unloadEntity", 5657656);
    defer unloadEntity.End();
    std.debug.assert(self.waitForRefAmount(1, 10 * std.time.us_per_s));
    return self.vtable.unload(self, world, uuid, allocator, save);
}

pub fn waitForRefAmount(self: *@This(), amount: u32, comptime maxMicroTime: ?u64) bool {
    if (self.ref_count.load(.seq_cst) == amount) return true;
    const st = std.time.microTimestamp();
    while (self.ref_count.load(.seq_cst) != amount) {
        if (maxMicroTime != null and (std.time.microTimestamp() - st) > maxMicroTime.?) return false;
        std.Thread.yield() catch {};
    }
    return true;
}

pub fn make(tempentity: anytype, allocator: std.mem.Allocator) !*Entity {
    const mem = try allocator.create(@TypeOf(tempentity));
    mem.* = tempentity;

    const en = Entity{
        .type = @TypeOf(tempentity).Type,
        .ptr = mem,
        .ref_count = .init(1),
        .vtable = tempentity.getInterface(),
    };

    const entity = try allocator.create(Entity);
    entity.* = en;
    return entity;
}

pub const Type = enum(u32) {
    Player = 0,
    Cube = 1,
    Explosive = 2,
};
