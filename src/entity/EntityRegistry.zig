const std = @import("std");

const ConcurrentHashMap = @import("../libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const tracy = @import("tracy");

const Entity = @import("Entity.zig");
const World = @import("../world/World.zig");

map: ConcurrentHashMap(u128, *Entity, std.hash_map.AutoContext(u128), 80, 32) = .init,

pub fn init() @This() {
    return .{
        .map = .init,
    };
}

pub fn unload(
    self: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    world: *World,
    entity_uuid: u128,
) void {
    const en = self.map.fetchRemove(io, entity_uuid) orelse return;
    en.unload(io, world, entity_uuid, allocator, true) catch
        std.log.err("error unloading entity\n", .{});
}

pub fn spawn(
    self: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    entity: anytype,
    comptime return_entity: bool,
) !if (return_entity) *Entity else void {
    const uuid_value = blk: {
        var random_uuid: u128 = undefined;
        io.random(std.mem.asBytes(&random_uuid));
        break :blk random_uuid;
    };
    const allocated_entity = try Entity.make(entity, allocator);
    //errdefer allocated_entity.unload(io, world, uuid_value, allocator, false) catch unreachable;

    if (return_entity) _ = allocated_entity.ref_count.fetchAdd(1, .seq_cst);
    std.debug.assert((try self.map.putNoOverrideAddRef(io, allocator, uuid_value, allocated_entity)) == null);
    if (return_entity) return allocated_entity;
}

pub fn update(
    self: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    world: *World,
) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    var it = self.map.iterator();
    defer it.deinit(io);

    while (try it.next(io)) |entry| {
        const uuid = entry.key_ptr.*;
        it.pause(io);
        const entity = self.map.getAndAddRef(io, uuid);
        if (entity) |en| {
            try en.update(io, allocator, world, uuid);
        }
        try it.unpause(io);
    }
}

pub fn deinit(
    self: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    world: *World,
) void {
    {
        var it = self.map.iterator();
        defer it.deinit(io);
        while (it.next(io) catch unreachable) |c| {
            c.value_ptr.*.unload(io, world, c.key_ptr.*, allocator, true) catch
                std.log.err("error unloading entity\n", .{});
        }
    }
    self.map.deinit(io, allocator);
    std.log.info("entities unloaded", .{});
}
