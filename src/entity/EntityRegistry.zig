const std = @import("std");
const builtin = @import("builtin");

const Cache = @import("../libs/Cache.zig").Cache;
const tracy = @import("tracy");

pub const Entity = @import("Entity.zig");
const World = @import("../world/World.zig");

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

/// Ways per cache set (value_count_max_multiple). Each skip advances the
/// eviction clock hand one way, so after this many skips every way in the
/// set is pinned and the insert can never succeed.
const max_victim_skips = EntityMapType.Shard.value_count_max_multiple;

const window_size = 64;

map: EntityMapType,
/// Live entity ids for the update pass; dynamically sized and deliberately
/// not capped by the cache. The entities form a memory hierarchy: this queue
/// is the authoritative live set, the cache below it is the bounded resident
/// tier, and an entity evicted from the cache leaves a stale id here that the
/// pass drops when the lookup misses.
queue: std.ArrayList(u128) = .empty,
/// Always acquired before a cache shard lock, never after, so spawn (which
/// inserts into the cache while holding it) cannot deadlock against update.
queue_mutex: std.Io.Mutex = .init,

pub fn init(allocator: std.mem.Allocator, value_count_max: u64) !@This() {
    return .{ .map = try .init(allocator, value_count_max, .{ .name = "entity cache" }) };
}

/// Number of entities currently held by the cache.
pub fn count(self: *const @This()) u64 {
    return self.map.count();
}

/// Spawns an entity, inserts it into the cache and queues its id for
/// updates, evicting an unpinned entity if the target set is full. The
/// returned entity carries a reference for the caller that must be released
/// when the caller is done using it.
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

    // Reserve before touching the cache so a failed insert leaves the queue
    // untouched and a successful one commits with an infallible append.
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
            unloadEntity(io, allocator, world, victim.*);
            victim.* = undefined;
        }

        _ = shard.upsert(&entity);
        return shard.get(entity.uuid).?;
    }
}

fn unloadEntity(io: std.Io, allocator: std.mem.Allocator, world: *World, entity: Entity) void {
    const save = !entity.deleted.load(.seq_cst);
    entity.vtable.unload(entity.ptr, io, world, entity.uuid, allocator, save) catch |err|
        std.log.err("error unloading entity: {any}", .{err});
}

/// Returns the entity for a uuid with an added reference, or null if it is
/// not cached. The caller must release the reference when done. A deleted
/// entity may still be returned while it waits to be unloaded; check
/// isDeleted if that matters.
pub fn getAndAddRef(self: *@This(), io: std.Io, uuid: u128) ?*Entity {
    const shard, const lock = self.map.getShardAndLock(uuid);
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    const entity = shard.get(uuid) orelse return null;
    entity.addRef();
    return entity;
}

/// Marks a cached entity for deletion. It stops being updated and is
/// unloaded, deleting any saved state, once no other references remain.
/// Returns false if the uuid is not cached.
pub fn markDeleted(self: *@This(), io: std.Io, uuid: u128) bool {
    const shard, const lock = self.map.getShardAndLock(uuid);
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    const entity = shard.get(uuid) orelse return false;
    entity.markDeleted();
    return true;
}

/// Updates every queued entity and reaps deleted ones. Entities whose update
/// requests deletion are reaped on the next pass. Safe to run concurrently
/// with other update passes, but not with deinit.
pub fn update(self: *@This(), io: std.Io, allocator: std.mem.Allocator, world: *World) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    var window: [window_size]*Entity = undefined;
    var reaps: [window_size]Entity = undefined;
    var i: usize = 0;
    while (true) {
        var window_len: usize = 0;
        var reap_len: usize = 0;

        // Collect under the lock, then run updates and unloads after release
        // so spawns are never blocked behind entity work.
        try self.queue_mutex.lock(io);
        while (i < self.queue.items.len and window_len < window.len and reap_len < reaps.len) {
            const uuid = self.queue.items[i];
            const entity = self.getAndAddRef(io, uuid) orelse {
                // Evicted from the cache; the id is stale.
                _ = self.queue.swapRemove(i);
                continue;
            };

            if (entity.deleted.load(.seq_cst)) {
                // The count includes the ref getAndAddRef just took: 2 means
                // only the cache and this pass hold it.
                if (entity.ref_count.load(.seq_cst) == 2) {
                    if (self.map.remove(io, uuid)) |removed| {
                        reaps[reap_len] = removed;
                        reap_len += 1;
                        _ = self.queue.swapRemove(i);
                        continue;
                    }
                }
                // Still referenced elsewhere; retry on a later pass.
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

/// Unloads every entity. All references must have been released and no
/// update pass may still be running before this.
pub fn deinit(self: *@This(), io: std.Io, allocator: std.mem.Allocator, world: *World) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    for (self.queue.items) |uuid| {
        // Stale ids (evicted entities) are simply skipped.
        const entity = self.getAndAddRef(io, uuid) orelse continue;
        if (entity.ref_count.load(.seq_cst) != 2)
            std.log.warn("entity {d} still referenced during shutdown", .{uuid});
        if (self.map.remove(io, uuid)) |removed| {
            unloadEntity(io, allocator, world, removed);
        } else {
            entity.release();
        }
    }
    // Every cached entity is queued, so the cache must have drained fully.
    std.debug.assert(self.map.count() == 0);

    self.map.deinit(allocator);
    self.queue.deinit(allocator);
    std.log.info("entities unloaded", .{});
}

const testing = std.testing;

// No test entity dereferences the world, so an undefined pointer is fine.
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

    for (0..EntityMapType.value_count_min) |_| {
        _ = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded });
    }

    try testing.expectError(error.EntityCacheSetFull, registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded }));
    try testing.expectEqual(@as(u32, 0), test_unloaded.load(.seq_cst));
}

test "evicted entities leave stale ids that update drops" {
    test_unloaded.store(0, .seq_cst);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    // Spawning past cache capacity evicts victims while their ids stay
    // queued, so the queue holds more ids than the cache has slots.
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
                    // After a full pass the queue holds exactly the cached entities.
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
