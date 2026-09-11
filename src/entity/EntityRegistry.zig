const std = @import("std");
const builtin = @import("builtin");

const Cache = @import("../libs/Cache.zig").Cache;
const tracy = @import("tracy");

pub const Entity = @import("Entity.zig");
const EntityTypes = @import("EntityTypes.zig");
const World = @import("../world/World.zig");

/// Where entities appear: user settings plus the resolved canonical spawn. Spawning stays here because the GUI edits only the settings.
pub const SpawnConfig = struct {
    center: @Vector(3, f64) = .{ 0, 0, 0 },
    range: u32 = 0,
    mode: EntityTypes.Player.GameMode = .Spectator,
    pos: @Vector(3, f64) = .{ 0, 0, 0 },
    found: bool = false,
};

inline fn uuidHash(uuid: u128) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, uuid);
    return hasher.final();
}

const EntityMapType = Cache(
    u128,
    Entity,
    Entity.keyFromValue,
    uuidHash,
    .{},
    if (builtin.is_test) 1 else 32,
);

/// Ways per cache set; after this many skips every way is pinned and the insert cannot succeed.
const max_victim_skips = EntityMapType.Shard.value_count_max_multiple;

const window_size = 64;

map: EntityMapType,
/// Live entity ids for the update pass; deliberately uncapped. Evicted entities leave stale ids the pass drops on lookup miss.
queue: std.ArrayList(u128) = .empty,
/// Acquire before any cache shard lock, never after, so spawn cannot deadlock against update.
queue_mutex: std.Io.Mutex = .init,

pub fn init(allocator: std.mem.Allocator, value_count_max: u64) !@This() {
    return .{ .map = try .init(allocator, value_count_max, .{ .name = "entity cache" }) };
}

pub fn count(self: *const @This()) u64 {
    return self.map.count();
}

/// Spawns an entity, queues it for updates, and returns it with a caller-owned reference. Evicts an unpinned entity when the set is full.
pub fn spawn(
    self: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    world: *World,
    entity: anytype,
) !*Entity {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    var random_uuid: u128 = undefined;
    io.random(std.mem.asBytes(&random_uuid));

    const Impl = @TypeOf(entity);
    const impl = try allocator.create(Impl);
    errdefer allocator.destroy(impl);
    impl.* = entity;

    try self.queue_mutex.lock(io);
    defer self.queue_mutex.unlock(io);

    // Reserve first so a failed insert leaves the queue untouched.
    try self.queue.ensureUnusedCapacity(allocator, 1);
    const stored = try self.insert(io, allocator, world, .{
        .type = Impl.Type,
        .uuid = random_uuid,
        .ptr = @ptrCast(impl),
        .ref_count = .init(2),
        .vtable = impl.getInterface(),
    });
    self.queue.appendAssumeCapacity(random_uuid);
    return stored;
}

fn insert(self: *@This(), io: std.Io, allocator: std.mem.Allocator, world: *World, entity: Entity) !*Entity {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const shard, const lock = self.map.getShardAndLock(entity.uuid);
    var skips: usize = 0;
    while (true) {
        // Deliberately flat: Zig runs while-body defers on `continue`, so this
        // unlock still runs below. Do not wrap the body in an extra block scope.
        try lock.lock(io);
        defer lock.unlock(io);
        if (shard.get(entity.uuid) != null) return error.EntityUuidExists;

        if (shard.peek_victim(entity.uuid)) |victim| {
            if (victim.ref_count.load(.seq_cst) != 1) {
                if (skips >= max_victim_skips) return error.EntityCacheSetFull;
                skips += 1;
                shard.skip_victim(entity.uuid);
                continue;
            }
            // Eviction runs under the shard lock per unloadEntity's contract.
            unloadEntity(io, allocator, world, victim.*);
            victim.* = undefined;
        }

        _ = shard.upsert(&entity);
        return shard.get(entity.uuid).?;
    }
}

/// Unloads an evicted entity under its shard lock. Unload code must not reenter this registry: reentry deadlocks on the held lock or inverts the lock order.
fn unloadEntity(io: std.Io, allocator: std.mem.Allocator, world: *World, entity: Entity) void {
    const save = !entity.deleted.load(.seq_cst);
    entity.vtable.unload(entity.ptr, io, world, entity.uuid, allocator, save) catch |err|
        std.log.err("error unloading entity: {any}", .{err});
}

/// Returns the cached entity with an added caller-owned reference, or null on miss. Deleted entities may still appear until unloaded.
pub fn getAndAddRef(self: *@This(), io: std.Io, uuid: u128) ?*Entity {
    const shard, const lock = self.map.getShardAndLock(uuid);
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    const entity = shard.get(uuid) orelse return null;
    entity.addRef();
    return entity;
}

/// Flags a cached entity for deletion; returns false on miss. Unloads once unreferenced, deleting saved state.
pub fn markDeleted(self: *@This(), io: std.Io, uuid: u128) bool {
    const shard, const lock = self.map.getShardAndLock(uuid);
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    const entity = shard.get(uuid) orelse return false;
    entity.markDeleted();
    return true;
}

/// Updates every queued entity and reaps deleted ones. Concurrent update passes are safe, but not concurrent deinit.
pub fn update(self: *@This(), io: std.Io, allocator: std.mem.Allocator, world: *World) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    var window: [window_size]*Entity = undefined;
    var reaps: [window_size]Entity = undefined;
    var i: usize = 0;
    while (true) {
        var window_len: usize = 0;
        var reap_len: usize = 0;

        // Collect under the lock, then update after release so spawns never wait on entity work.
        try self.queue_mutex.lock(io);
        while (i < self.queue.items.len and window_len < window.len and reap_len < reaps.len) {
            const uuid = self.queue.items[i];
            const entity = self.getAndAddRef(io, uuid) orelse {
                // Evicted; the id is stale.
                _ = self.queue.swapRemove(i);
                continue;
            };
            if (entity.deleted.load(.seq_cst)) {
                // Count 2 means only the cache and this pass hold it.
                if (entity.ref_count.load(.seq_cst) == 2) {
                    if (self.map.remove(io, uuid)) |removed| {
                        reaps[reap_len] = removed;
                        reap_len += 1;
                        _ = self.queue.swapRemove(i);
                        continue;
                    }
                }
                // Still referenced elsewhere; retry later.
                entity.release();
                i += 1;
                continue;
            }

            window[window_len] = entity;
            window_len += 1;
            i += 1;
        }
        const exhausted = i >= self.queue.items.len;
        self.queue_mutex.unlock(io);

        var update_error: ?Entity.UpdateError = null;
        for (window[0..window_len]) |entity| {
            defer entity.release();
            if (update_error != null) continue;

            const update_fn = entity.vtable.update orelse continue;
            const should_delete = update_fn(entity.ptr, io, world, entity.uuid, allocator) catch |err| {
                update_error = err;
                continue;
            };
            if (should_delete) entity.markDeleted();
        }

        for (reaps[0..reap_len]) |entity| {
            unloadEntity(io, allocator, world, entity);
        }

        if (update_error) |err| return err;
        if (exhausted) break;
    }
}

/// Unloads every entity. Callers must release all references and stop update passes first; panics on outstanding refs.
pub fn deinit(self: *@This(), io: std.Io, allocator: std.mem.Allocator, world: *World) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    for (self.queue.items) |uuid| {
        const entity = self.getAndAddRef(io, uuid) orelse continue;
        if (entity.ref_count.load(.seq_cst) != 2)
            std.debug.panic("entity {d} still referenced during shutdown", .{uuid});
        if (self.map.remove(io, uuid)) |removed| {
            unloadEntity(io, allocator, world, removed);
        } else {
            entity.release();
        }
    }
    std.debug.assert(self.map.count() == 0);

    self.map.deinit(allocator);
    self.queue.deinit(allocator);
    std.log.info("entities unloaded", .{});
}

const testing = std.testing;

const test_world: *World = undefined;

var test_unloaded: std.atomic.Value(u32) = .init(0);

const TestEntity = struct {
    pub const Type = Entity.Type.Player;

    unloaded: *std.atomic.Value(u32),
    updates: ?*std.atomic.Value(u32) = null,
    delete: bool = false,

    pub fn getInterface(self: *const @This()) Entity.Interface {
        _ = self;
        return .{ .unload = unloadFn, .update = updateFn };
    }

    fn unloadFn(ptr: *Entity.Implementation, io: std.Io, world: *World, uuid: u128, allocator: std.mem.Allocator, save: bool) error{SavingFailed}!void {
        _ = io;
        _ = world;
        _ = uuid;
        _ = save;
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = self.unloaded.fetchAdd(1, .seq_cst);
        allocator.destroy(self);
    }

    fn updateFn(ptr: *Entity.Implementation, io: std.Io, world: *World, uuid: u128, allocator: std.mem.Allocator) Entity.UpdateError!bool {
        _ = io;
        _ = world;
        _ = uuid;
        _ = allocator;
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.updates) |updates| _ = updates.fetchAdd(1, .seq_cst);
        return self.delete;
    }
};

fn spawnAndGet(alloc: std.mem.Allocator, io: std.Io) !void {
    var registry = try init(alloc, EntityMapType.value_count_min);
    defer registry.deinit(io, alloc, test_world);

    const entity = try registry.spawn(io, alloc, test_world, TestEntity{ .unloaded = &test_unloaded });
    entity.release();
    const fetched = registry.getAndAddRef(io, entity.uuid);
    try testing.expect(fetched != null);
    if (fetched) |en| en.release();
}

test "spawn and get" {
    test_unloaded.store(0, .seq_cst);
    try spawnAndGet(testing.allocator, testing.io);
    try testing.expectEqual(@as(u32, 1), test_unloaded.load(.seq_cst));
}

test "spawn allocation failure" {
    test_unloaded.store(0, .seq_cst);
    try testing.checkAllAllocationFailures(testing.allocator, spawnAndGet, .{testing.io});
    try testing.expectEqual(@as(u32, 1), test_unloaded.load(.seq_cst));
}

test "eviction unloads an entity when the cache is full" {
    test_unloaded.store(0, .seq_cst);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    for (0..EntityMapType.value_count_min + 1) |_| {
        const entity = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded });
        entity.release();
    }

    try testing.expectEqual(EntityMapType.value_count_min, registry.count());
    try testing.expectEqual(@as(u32, 1), test_unloaded.load(.seq_cst));
}

test "pinned entities are not evicted" {
    test_unloaded.store(0, .seq_cst);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const pinned = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded });
    defer pinned.release();

    for (0..EntityMapType.value_count_min) |_| {
        const entity = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded });
        entity.release();
    }

    try testing.expectEqual(EntityMapType.value_count_min, registry.count());
    try testing.expectEqual(@as(u32, 1), test_unloaded.load(.seq_cst));
    const fetched = registry.getAndAddRef(testing.io, pinned.uuid);
    try testing.expect(fetched != null);
    if (fetched) |en| en.release();
}

test "spawn fails when every way is pinned" {
    test_unloaded.store(0, .seq_cst);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    var pinned: [EntityMapType.value_count_min]*Entity = undefined;
    for (&pinned) |*slot| {
        slot.* = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded });
    }
    defer for (pinned) |entity| entity.release();

    try testing.expectError(error.EntityCacheSetFull, registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded }));
    try testing.expectEqual(@as(u32, 0), test_unloaded.load(.seq_cst));
}

test "evicted entities leave stale ids that update drops" {
    test_unloaded.store(0, .seq_cst);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    for (0..EntityMapType.value_count_min + 4) |_| {
        const entity = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded });
        entity.release();
    }

    try testing.expectEqual(EntityMapType.value_count_min, registry.count());
    try testing.expectEqual(@as(u32, 4), test_unloaded.load(.seq_cst));
    try testing.expectEqual(@as(usize, @intCast(EntityMapType.value_count_min + 4)), registry.queue.items.len);

    try registry.update(testing.io, testing.allocator, test_world);
    try testing.expectEqual(@as(u64, EntityMapType.value_count_min), registry.count());
    try testing.expectEqual(@as(usize, @intCast(EntityMapType.value_count_min)), registry.queue.items.len);
}

test "deleted entities are reaped by update" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded, .updates = &updates });
    entity.release();

    try testing.expect(registry.markDeleted(testing.io, entity.uuid));
    try registry.update(testing.io, testing.allocator, test_world);
    try testing.expectEqual(@as(u64, 0), registry.count());
    try testing.expectEqual(@as(u32, 1), test_unloaded.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), updates.load(.seq_cst));
    try testing.expectEqual(false, registry.markDeleted(testing.io, entity.uuid));
}

test "update requesting deletion is reaped on the next pass" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded, .updates = &updates, .delete = true });
    entity.release();

    try registry.update(testing.io, testing.allocator, test_world);
    try testing.expectEqual(@as(u64, 1), registry.count());
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), test_unloaded.load(.seq_cst));

    try registry.update(testing.io, testing.allocator, test_world);
    try testing.expectEqual(@as(u64, 0), registry.count());
    try testing.expectEqual(@as(u32, 1), test_unloaded.load(.seq_cst));
}

fn fuzzRegistry(_: void, smith: *std.testing.Smith) !void {
    test_unloaded.store(0, .seq_cst);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    var updates: std.atomic.Value(u32) = .init(0);
    var pinned: [4]?*Entity = @splat(null);
    defer for (&pinned) |maybe_entity| {
        if (maybe_entity) |en| en.release();
    };
    var pin_i: usize = 0;

    for (0..smith.value(u8)) |_| {
        var random_uuid: u128 = undefined;
        testing.io.random(std.mem.asBytes(&random_uuid));
        switch (smith.value(enum { spawn, pin, unpin, get, mark_deleted, update })) {
            .spawn => {
                const entity = registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded, .updates = &updates }) catch continue;
                entity.release();
            },
            .pin => {
                const entity = registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded, .updates = &updates }) catch continue;
                if (pinned[pin_i]) |old| old.release();
                pinned[pin_i] = entity;
                pin_i = (pin_i + 1) % pinned.len;
            },
            .unpin => {
                const i = smith.value(u2);
                if (pinned[i]) |en| {
                    en.release();
                    pinned[i] = null;
                }
            },
            .get => {
                const entity = registry.getAndAddRef(testing.io, random_uuid) orelse continue;
                entity.release();
            },
            .mark_deleted => {
                _ = registry.markDeleted(testing.io, random_uuid);
            },
            .update => {
                if (registry.update(testing.io, testing.allocator, test_world)) |_| {
                    if (registry.queue.items.len != registry.count()) @panic("update queue out of sync with cache");
                } else |_| {}
            },
        }
    }

    if (registry.count() > EntityMapType.value_count_min) @panic("cache exceeds capacity");
}

test "FuzzEntityRegistry" {
    try std.testing.fuzz({}, fuzzRegistry, .{});
}
