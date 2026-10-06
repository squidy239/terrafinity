const std = @import("std");
const builtin = @import("builtin");

const Cache = @import("../libs/Cache.zig").Cache;
const tracy = @import("tracy");

pub const Entity = @import("Entity.zig");
/// Entity identity; see `Entity.Handle`.
const Handle = Entity.Handle;
const EntityTypes = @import("EntityTypes.zig");
const World = @import("../world/World.zig");

/// User settings for where entities appear.
pub const SpawnConfig = struct {
    center: @Vector(3, f64) = .{ 0, 0, 0 },
    range: u32 = 0,
    mode: EntityTypes.Player.GameMode = .Spectator,
    pos: @Vector(3, f64) = .{ 0, 0, 0 },
    found: bool = false,
};

inline fn uuidHash(uuid: Handle) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, uuid);
    return hasher.final();
}

const EntityMapType = Cache(
    Handle,
    Entity,
    Entity.keyFromValue,
    uuidHash,
    .{},
    if (builtin.is_test) 1 else 32,
);

const max_victim_skips = EntityMapType.Shard.value_count_max_multiple;

/// Wheel bucket width; deadlines past the horizon park in overflow.
const tick_ns: u64 = std.time.ns_per_ms;
const wheel_buckets: u32 = 1024;
const horizon_ns: u64 = wheel_buckets * tick_ns;
const drain_batch: u32 = 64;
const drain_splices_max: u32 = 64;
/// Revisit delay for deleted-but-referenced entities.
const retry_ns: u64 = 5 * std.time.ns_per_ms;
const none: u32 = std.math.maxInt(u32);
const Bucket = enum { wheel, overflow, parked };

const TimerNode = struct {
    used: bool = false,
    uuid: Handle = 0,
    deadline_ns: u64 = 0,
    next: u32 = none,
    prev: u32 = none,
    bucket: Bucket = .parked,
    /// Wheel bucket index; meaningful only while bucket == .wheel.
    bucket_index: u10 = 0,
    /// Drain generation that armed this timer; only older generations pop, so a
    /// re-arm inside a drain waits for the next pass.
    armed_gen: u64 = 0,
    in_flight: bool = false,
    pending_armed: bool = false,
    pending_deadline_ns: u64 = 0,
};

const DrainCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    world: *World,
    watermark: u64,
    seq: u64,
};

const Due = struct {
    slot: u32,
    uuid: Handle,
};

const SettleAction = union(enum) {
    free,
    park,
    link: u64,
    keep,
};

pub const DeleteResult = enum { marked, missing };

pub const SpawnOptions = struct {
    /// Arms the first update; null parks dormant.
    initial_delay_ms: ?u64 = null,
};

map: EntityMapType,
/// Guards spawn plus all scheduler state; acquire before any shard lock, never
/// after, so spawn cannot deadlock against the drain.
scheduler_mutex: std.Io.Mutex = .init,
timers: std.ArrayList(TimerNode) = .empty,
timer_used: u64 = 0,
free_head: u32 = none,
buckets: [wheel_buckets]u32 = @splat(none),
overflow_head: u32 = none,
/// Lower bound on the earliest overflow deadline; cascade waits until it reaches the horizon.
overflow_next_ns: u64 = std.math.maxInt(u64),
drain_seq: u64 = 0,

pub fn init(allocator: std.mem.Allocator, value_count_max: u64) !@This() {
    return .{ .map = try .init(allocator, value_count_max, .{ .name = "entity cache" }) };
}

/// Monotonic scheduler clock, clamped at zero.
pub fn nowNs(io: std.Io) u64 {
    const raw = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    return @intCast(@max(raw, @as(@TypeOf(raw), 0)));
}

pub fn count(self: *const @This()) u64 {
    return self.map.count();
}

/// Spawns an entity with a caller-owned reference, evicting a wheel entity when full.
pub fn spawn(
    self: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    world: *World,
    entity: anytype,
    options: SpawnOptions,
) !*Entity {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    var random_uuid: Handle = undefined;
    io.random(std.mem.asBytes(&random_uuid));

    const impl = try allocator.create(@TypeOf(entity));
    errdefer allocator.destroy(impl);
    impl.* = entity;

    // The clock is sampled before locking; holders must not suspend mid-section.
    const now = nowNs(io);

    try self.scheduler_mutex.lock(io);
    defer self.scheduler_mutex.unlock(io);

    // Reserve before insert so a failed insert leaves every structure untouched.
    const slot = try self.allocSlotLocked(allocator);
    errdefer self.freeSlotLocked(slot);

    const result = try self.insert(io, .{
        .uuid = random_uuid,
        .ptr = @ptrCast(impl),
        .ref_count = .init(2),
        .timer_slot = slot,
        .vtable = impl.getInterface(),
    });

    self.timers.items[slot].uuid = random_uuid;
    if (options.initial_delay_ms) |delay| {
        self.linkLocked(slot, now +| delay *| std.time.ns_per_ms, self.drain_seq -| 1, now);
    }
    if (result.evicted) |victim| {
        // Freeing an in-flight slot is safe: the victim is out of the cache, so its
        // claim can only miss the lookup and no-op on settle, and slot reuse fails
        // the claim's uuid check.
        const node = &self.timers.items[victim.timer_slot];
        if (node.used and node.uuid == victim.uuid) self.freeSlotLocked(victim.timer_slot);
        unloadEntity(io, allocator, world, victim);
    }
    return result.entity;
}

/// Result of a cache insert: the entity plus the eviction for the caller to apply.
const InsertResult = struct {
    entity: *Entity,
    evicted: ?Entity,
};

fn insert(self: *@This(), io: std.Io, entity: Entity) !InsertResult {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const shard, const lock = self.map.getShardAndLock(entity.uuid);
    var skips: usize = 0;
    while (true) {
        // Flat on purpose: Zig runs while-body defers on `continue`, so this
        // unlock still runs below. Do not wrap the body in an extra scope.
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
        }

        // upsert displaces exactly the way peek_victim simulated, so its result is
        // the victim the caller unloads once the shard lock is released.
        const evicted = shard.upsert(&entity).evicted;
        return .{ .entity = shard.get(entity.uuid).?, .evicted = evicted };
    }
}

/// Unload must not reenter this registry: the eviction path holds the scheduler mutex.
fn unloadEntity(io: std.Io, allocator: std.mem.Allocator, world: *World, entity: Entity) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    entity.vtable.unload(entity.ptr, io, world, entity.uuid, allocator);
}

/// Returns the entity with an added caller-owned reference, or null on miss.
pub fn getAndAddRef(self: *@This(), io: std.Io, uuid: Handle) ?*Entity {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const shard, const lock = self.map.getShardAndLock(uuid);
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    const entity = shard.get(uuid) orelse return null;
    entity.addRef();
    return entity;
}

/// Flags a resident entity for deletion. A far-future timer is replaced by the
/// reap check.
pub fn markDeleted(self: *@This(), io: std.Io, uuid: Handle) DeleteResult {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const now = nowNs(io);
    self.scheduler_mutex.lockUncancelable(io);
    defer self.scheduler_mutex.unlock(io);
    const shard, const lock = self.map.getShardAndLock(uuid);
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    const entity = shard.get(uuid) orelse return .missing;
    entity.markDeleted();
    const node = &self.timers.items[entity.timer_slot];
    std.debug.assert(node.used and node.uuid == uuid);
    const retry_deadline = now +| retry_ns;
    if (node.in_flight) {
        node.pending_armed = true;
        node.pending_deadline_ns = retry_deadline;
        return .marked;
    }
    // Only postpone an already-later deadline; soon-due timers keep their deadline.
    if (node.bucket == .parked or node.deadline_ns > retry_deadline)
        self.linkLocked(entity.timer_slot, retry_deadline, self.drain_seq -| 1, now);
    return .marked;
}

/// Arms or re-arms an entity's timer from now; zero means the next drain.
/// Returns false when the uuid is not resident.
pub fn schedule(self: *@This(), io: std.Io, uuid: Handle, delay_ms: u64) bool {
    return self.rescheduleAt(io, uuid, nowNs(io), delay_ms);
}

/// rescheduleAt from a caller-supplied base: an update passes the drain
/// watermark so its delay excludes the drain's own runtime.
pub fn rescheduleAt(self: *@This(), io: std.Io, uuid: Handle, base_ns: u64, delay_ms: u64) bool {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    self.scheduler_mutex.lockUncancelable(io);
    defer self.scheduler_mutex.unlock(io);
    const shard, const lock = self.map.getShardAndLock(uuid);
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    const entity = shard.get(uuid) orelse return false;
    const slot = entity.timer_slot;
    const node = &self.timers.items[slot];
    std.debug.assert(node.used and node.uuid == uuid);

    const deadline = base_ns +| delay_ms *| std.time.ns_per_ms;
    if (node.in_flight) {
        node.pending_armed = true;
        node.pending_deadline_ns = deadline;
        return true;
    }
    self.linkLocked(slot, deadline, self.drain_seq -| 1, base_ns);
    return true;
}

/// Runs one update for an entity the caller owns and holds by reference, outside
/// the wheel. The caller keeps it resident; nothing schedules or reaps it.
pub fn updateNow(
    self: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    world: *World,
    entity: *Entity,
    now_ns: u64,
) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const update_fn = entity.vtable.update orelse return;
    try update_fn(entity.ptr, .{
        .io = io,
        .world = world,
        .allocator = allocator,
        .now_ns = now_ns,
        .uuid = entity.uuid,
        .registry = self,
    });
}

/// Runs every due timer and re-arms from each decision; leftovers wait for the next call.
/// An update error ends the pass: the rest of the batch is re-armed and the error propagates.
pub fn drain(self: *@This(), io: std.Io, allocator: std.mem.Allocator, world: *World, now_ns: u64) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    self.scheduler_mutex.lockUncancelable(io);
    self.drain_seq += 1;
    const seq = self.drain_seq;
    self.scheduler_mutex.unlock(io);
    const ctx: DrainCtx = .{
        .io = io,
        .allocator = allocator,
        .world = world,
        .watermark = now_ns,
        .seq = seq,
    };

    for (0..drain_splices_max) |splices| {
        try io.checkCancel();
        var batch: [drain_batch]Due = undefined;
        const batch_len = try self.spliceDue(ctx, &batch, splices == 0);
        if (batch_len == 0) break;

        for (batch[0..batch_len], 0..) |due, i| {
            self.runDue(ctx, due.slot, due.uuid) catch |err| {
                // The pass ends here; re-arm the remainder so no claim is left in flight.
                for (batch[i + 1 .. batch_len]) |rest| self.settleClaim(ctx, rest.slot, rest.uuid, .keep);
                return err;
            };
        }
    }
}

/// Cascades overflow into the wheel, then detaches due timers older than this drain.
fn spliceDue(self: *@This(), ctx: DrainCtx, batch: *[drain_batch]Due, cascade: bool) !usize {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    try self.scheduler_mutex.lock(ctx.io);
    defer self.scheduler_mutex.unlock(ctx.io);

    if (cascade) self.cascadeOverflowLocked(ctx.watermark);
    return self.detachDueLocked(ctx.watermark, ctx.seq, batch);
}

/// Moves overflow timers inside the wheel horizon.
fn cascadeOverflowLocked(self: *@This(), watermark: u64) void {
    // Skip the walk until an overflow deadline reaches the horizon.
    if (self.overflow_next_ns -| watermark > horizon_ns) return;

    const cascade = tracy.Zone.begin(.{ .src = @src(), .name = "cascade" });
    defer cascade.end();

    var next_ns: u64 = std.math.maxInt(u64);
    var curr = self.overflow_head;
    while (curr != none) {
        const node = &self.timers.items[curr];
        const next = node.next;
        if (node.deadline_ns -| watermark <= horizon_ns) {
            self.unlinkLocked(curr);
            self.pushWheelLocked(curr);
        } else {
            next_ns = @min(next_ns, node.deadline_ns);
        }
        curr = next;
    }
    self.overflow_next_ns = next_ns;
}

/// Detaches due timers older than this drain's generation into the batch.
fn detachDueLocked(self: *@This(), watermark: u64, seq: u64, batch: *[drain_batch]Due) usize {
    const detach = tracy.Zone.begin(.{ .src = @src(), .name = "detach" });
    defer detach.end();

    var batch_len: usize = 0;
    for (&self.buckets) |*head| {
        if (batch_len >= batch.len) break;
        var curr = head.*;
        while (curr != none and batch_len < batch.len) {
            const node = &self.timers.items[curr];
            const slot = curr;
            curr = node.next;
            if (node.in_flight or node.armed_gen >= seq or node.deadline_ns > watermark) continue;
            batch[batch_len] = .{ .slot = slot, .uuid = node.uuid };
            batch_len += 1;
            self.unlinkLocked(slot);
            node.in_flight = true;
        }
    }
    return batch_len;
}

fn runDue(self: *@This(), ctx: DrainCtx, slot: u32, uuid: Handle) Entity.UpdateError!void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const entity = self.getAndAddRef(ctx.io, uuid) orelse {
        // Evicted mid-flight; its slot was freed (or reused) before this claim settled.
        self.settleClaim(ctx, slot, uuid, .free);
        return;
    };

    if (entity.deleted.load(.seq_cst)) {
        self.reapDeleted(ctx, entity, slot, uuid);
        return;
    }
    return self.runUpdate(ctx, entity, slot, uuid);
}

/// Reaps a deleted entity once only the cache holds it, else re-arms a retry.
/// Checking the refcount and removing share one shard lock, so a concurrent
/// getAndAddRef lands either before (a ref appears) or after (a miss).
fn reapDeleted(self: *@This(), ctx: DrainCtx, entity: *Entity, slot: u32, uuid: Handle) void {
    const shard, const lock = self.map.getShardAndLock(uuid);
    lock.lockUncancelable(ctx.io);
    var removed: ?Entity = null;
    if (shard.get(uuid)) |resident| {
        if (resident.ref_count.load(.seq_cst) == 2) removed = shard.remove(uuid);
    }
    lock.unlock(ctx.io);

    if (removed) |value| {
        self.settleClaim(ctx, slot, uuid, .free);
        unloadEntity(ctx.io, ctx.allocator, ctx.world, value);
        return;
    }
    entity.release();
    self.settleClaim(ctx, slot, uuid, .{ .link = ctx.watermark +| retry_ns });
}

fn runUpdate(self: *@This(), ctx: DrainCtx, entity: *Entity, slot: u32, uuid: Handle) Entity.UpdateError!void {
    // A failed update parks too; a reschedule or delete recorded during the update wins in settleClaim.
    defer {
        entity.release();
        self.settleClaim(ctx, slot, uuid, .park);
    }
    const update_fn = entity.vtable.update orelse return;
    try update_fn(entity.ptr, .{
        .io = ctx.io,
        .world = ctx.world,
        .allocator = ctx.allocator,
        .now_ns = ctx.watermark,
        .uuid = uuid,
        .registry = self,
    });
}

/// Ends one detached claim; a mid-flight wake wins over the fallback. Re-arms
/// stamp the draining generation, so a zero delay waits for the next pass.
fn settleClaim(self: *@This(), ctx: DrainCtx, slot: u32, uuid: Handle, action: SettleAction) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    self.scheduler_mutex.lockUncancelable(ctx.io);
    defer self.scheduler_mutex.unlock(ctx.io);
    const node = &self.timers.items[slot];
    if (!node.used or node.uuid != uuid or !node.in_flight) return;
    node.in_flight = false;
    if (node.pending_armed) {
        node.pending_armed = false;
        const pending = node.pending_deadline_ns;
        self.linkLocked(slot, pending, ctx.seq, ctx.watermark);
        return;
    }
    switch (action) {
        .free => self.freeSlotLocked(slot),
        .park => {},
        .link => |deadline| self.linkLocked(slot, deadline, ctx.seq, ctx.watermark),
        .keep => self.linkLocked(slot, node.deadline_ns, ctx.seq, ctx.watermark),
    }
}

/// Reserves a slot, growing the slab when the free list is empty. The slab
/// stays bounded by the cache: a spawn holds at most one extra slot while
/// insert evicts a victim and frees its slot.
fn allocSlotLocked(self: *@This(), allocator: std.mem.Allocator) !u32 {
    const slot: u32 = if (self.free_head != none) blk: {
        const popped = self.free_head;
        self.free_head = self.timers.items[popped].next;
        break :blk popped;
    } else blk: {
        try self.timers.append(allocator, .{});
        break :blk @intCast(self.timers.items.len - 1);
    };
    self.timers.items[slot] = .{ .used = true };
    self.timer_used += 1;
    return slot;
}

fn freeSlotLocked(self: *@This(), slot: u32) void {
    const node = &self.timers.items[slot];
    std.debug.assert(node.used);
    self.unlinkLocked(slot);
    node.used = false;
    node.next = self.free_head;
    self.free_head = slot;
    self.timer_used -= 1;
}

fn unlinkLocked(self: *@This(), slot: u32) void {
    const node = &self.timers.items[slot];
    const head: *u32 = switch (node.bucket) {
        .overflow => &self.overflow_head,
        .parked => return,
        .wheel => &self.buckets[node.bucket_index],
    };
    if (node.prev != none) {
        self.timers.items[node.prev].next = node.next;
    } else {
        head.* = node.next;
    }
    if (node.next != none) {
        self.timers.items[node.next].prev = node.prev;
    }
    node.next = none;
    node.prev = none;
    node.bucket = .parked;
}

fn linkLocked(self: *@This(), slot: u32, deadline_ns: u64, armed_gen: u64, now_ns: u64) void {
    self.unlinkLocked(slot);
    const node = &self.timers.items[slot];
    std.debug.assert(node.used);
    node.deadline_ns = deadline_ns;
    node.armed_gen = armed_gen;
    node.in_flight = false;
    node.pending_armed = false;
    if (deadline_ns -| now_ns > horizon_ns) {
        node.bucket = .overflow;
        self.overflow_next_ns = @min(self.overflow_next_ns, deadline_ns);
        self.pushFrontLocked(&self.overflow_head, slot);
    } else {
        self.pushWheelLocked(slot);
    }
}

fn pushWheelLocked(self: *@This(), slot: u32) void {
    const node = &self.timers.items[slot];
    node.bucket_index = @intCast((node.deadline_ns / tick_ns) % wheel_buckets);
    node.bucket = .wheel;
    self.pushFrontLocked(&self.buckets[node.bucket_index], slot);
}

fn pushFrontLocked(self: *@This(), head: *u32, slot: u32) void {
    const node = &self.timers.items[slot];
    node.next = head.*;
    node.prev = none;
    if (head.* != none) self.timers.items[head.*].prev = slot;
    head.* = slot;
}

/// Unloads every entity. Callers must stop all registry activity first: no live
/// references, no running drains, no concurrent spawn/schedule/markDeleted, so
/// the scheduler lock is not taken here.
pub fn deinit(self: *@This(), io: std.Io, allocator: std.mem.Allocator, world: *World) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    // Every resident entity holds a timer slot, so the slab is the census.
    // No drain runs here, so no slot is ever in flight.
    for (self.timers.items, 0..) |node, i| {
        if (!node.used) continue;
        std.debug.assert(!node.in_flight);
        const entity = self.getAndAddRef(io, node.uuid).?;
        if (entity.ref_count.load(.seq_cst) != 2)
            std.debug.panic("entity {d} still referenced during shutdown", .{node.uuid});
        const removed = self.map.remove(io, node.uuid).?;
        self.freeSlotLocked(@intCast(i));
        unloadEntity(io, allocator, world, removed);
    }
    std.debug.assert(self.map.count() == 0);
    std.debug.assert(self.timer_used == 0);

    self.map.deinit(allocator);
    self.timers.deinit(allocator);
    std.log.info("entities unloaded", .{});
}

const testing = std.testing;

const test_world: *World = undefined;

var test_unloaded: std.atomic.Value(u32) = .init(0);

const TestEntity = struct {
    unloaded: *std.atomic.Value(u32),
    updates: ?*std.atomic.Value(u32) = null,
    del: bool = false,
    delay_ms: u64 = 0,
    run_limit: u32 = std.math.maxInt(u32),

    pub fn getInterface(_: *const @This()) Entity.Interface {
        return .{ .unload = unloadFn, .update = updateFn };
    }

    fn unloadFn(ptr: *Entity.Implementation, _: std.Io, _: *World, _: Handle, allocator: std.mem.Allocator) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = self.unloaded.fetchAdd(1, .seq_cst);
        allocator.destroy(self);
    }

    fn updateFn(ptr: *Entity.Implementation, ctx: Entity.UpdateContext) Entity.UpdateError!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ran = if (self.updates) |updates|
            updates.fetchAdd(1, .seq_cst) + 1
        else
            1;

        if (self.del) return ctx.delete();
        if (ran > self.run_limit) return;
        ctx.reschedule(self.delay_ms);
    }
};

fn spawnTest(registry: *@This(), entity: TestEntity, options: SpawnOptions) !*Entity {
    return registry.spawn(testing.io, testing.allocator, test_world, entity, options);
}

fn drainAt(registry: *@This(), now_ns: u64) !void {
    try registry.drain(testing.io, testing.allocator, test_world, now_ns);
}

fn spawnAndGet(alloc: std.mem.Allocator, io: std.Io) !void {
    var registry = try init(alloc, EntityMapType.value_count_min);
    defer registry.deinit(io, alloc, test_world);

    const entity = try registry.spawn(io, alloc, test_world, TestEntity{ .unloaded = &test_unloaded }, .{ .initial_delay_ms = 0 });
    entity.release();
    const fetched = registry.getAndAddRef(io, entity.uuid);
    try testing.expect(fetched != null);
    if (fetched) |en| en.release();
}

test "spawn allocation failure" {
    test_unloaded.store(0, .seq_cst);
    try testing.checkAllAllocationFailures(testing.allocator, spawnAndGet, .{testing.io});
    try testing.expectEqual(@as(u32, 1), test_unloaded.load(.seq_cst));
}

test "held entities are not evicted" {
    test_unloaded.store(0, .seq_cst);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const held = try spawnTest(&registry, .{ .unloaded = &test_unloaded }, .{});
    defer held.release();
    for (0..EntityMapType.value_count_min) |_| {
        const entity = try spawnTest(&registry, .{ .unloaded = &test_unloaded }, .{ .initial_delay_ms = 0 });
        entity.release();
    }

    try testing.expectEqual(EntityMapType.value_count_min, registry.count());
    try testing.expectEqual(@as(u32, 1), test_unloaded.load(.seq_cst));
    const fetched = registry.getAndAddRef(testing.io, held.uuid);
    try testing.expect(fetched != null);
    if (fetched) |en| en.release();
}

test "evicted timers never fire" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    for (0..EntityMapType.value_count_min + 4) |_| {
        const entity = try spawnTest(&registry, .{ .unloaded = &test_unloaded, .updates = &updates }, .{ .initial_delay_ms = 0 });
        entity.release();
    }

    try testing.expectEqual(EntityMapType.value_count_min, registry.count());
    try testing.expectEqual(@as(u32, 4), test_unloaded.load(.seq_cst));
    try drainAt(&registry, nowNs(testing.io));
    try testing.expectEqual(@as(u32, EntityMapType.value_count_min), updates.load(.seq_cst));
    try testing.expectEqual(registry.count(), registry.timer_used);
}

test "deletion reaps without waiting for a prior deadline" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const due = try spawnTest(&registry, .{ .unloaded = &test_unloaded, .updates = &updates }, .{ .initial_delay_ms = 0 });
    due.release();
    const far = try spawnTest(&registry, .{ .unloaded = &test_unloaded, .updates = &updates }, .{ .initial_delay_ms = 60_000 });
    far.release();

    try testing.expectEqual(DeleteResult.marked, registry.markDeleted(testing.io, due.uuid));
    try testing.expectEqual(DeleteResult.marked, registry.markDeleted(testing.io, far.uuid));
    try drainAt(&registry, nowNs(testing.io));
    try testing.expectEqual(@as(u64, 1), registry.count());
    try drainAt(&registry, nowNs(testing.io) + 10 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u64, 0), registry.count());
    try testing.expectEqual(@as(u32, 2), test_unloaded.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), updates.load(.seq_cst));
    try testing.expectEqual(DeleteResult.missing, registry.markDeleted(testing.io, due.uuid));
}

test "handle resolves only while referenced, then misses" {
    test_unloaded.store(0, .seq_cst);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try spawnTest(&registry, .{ .unloaded = &test_unloaded }, .{});
    const handle = entity.uuid;
    entity.release();

    const held = registry.getAndAddRef(testing.io, handle) orelse return error.MissingEntity;
    try testing.expectEqual(entity.uuid, held.uuid);
    held.release();

    // Deleted and reaped: the weak handle now misses.
    try testing.expectEqual(DeleteResult.marked, registry.markDeleted(testing.io, entity.uuid));
    const t0 = nowNs(testing.io);
    try drainAt(&registry, t0);
    try drainAt(&registry, t0 + 10 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u64, 0), registry.count());
    try testing.expect(registry.getAndAddRef(testing.io, handle) == null);
}

test "zero delay fires on the next drain, never the same one" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try spawnTest(&registry, .{ .unloaded = &test_unloaded, .updates = &updates }, .{ .initial_delay_ms = 0 });
    entity.release();

    const t0 = nowNs(testing.io);
    try drainAt(&registry, t0);
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));
    try drainAt(&registry, t0);
    try testing.expectEqual(@as(u32, 2), updates.load(.seq_cst));
}

test "dormant entities sleep until woken" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try spawnTest(&registry, .{ .unloaded = &test_unloaded, .updates = &updates, .run_limit = 0 }, .{});
    const uuid = entity.uuid;
    entity.release();

    try drainAt(&registry, nowNs(testing.io));
    try testing.expectEqual(@as(u32, 0), updates.load(.seq_cst));

    var random_uuid: Handle = undefined;
    testing.io.random(std.mem.asBytes(&random_uuid));
    try testing.expectEqual(false, registry.schedule(testing.io, random_uuid, 0));
    try testing.expect(registry.schedule(testing.io, uuid, 0));
    try drainAt(&registry, nowNs(testing.io));
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));

    try testing.expect(registry.schedule(testing.io, uuid, 0));
    try testing.expect(registry.schedule(testing.io, uuid, 0));
    try drainAt(&registry, nowNs(testing.io));
    try testing.expectEqual(@as(u32, 2), updates.load(.seq_cst));
}

test "a held entity runs only when the caller drives it" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try spawnTest(&registry, .{ .unloaded = &test_unloaded, .updates = &updates, .run_limit = 0 }, .{});
    defer entity.release();

    try registry.updateNow(testing.io, testing.allocator, test_world, entity, nowNs(testing.io));
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));

    // Never armed, so the drain leaves it alone.
    try drainAt(&registry, nowNs(testing.io));
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));
    try testing.expectEqual(@as(u64, 1), registry.count());
}

fn fuzzRegistry(_: void, smith: *std.testing.Smith) !void {
    test_unloaded.store(0, .seq_cst);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    var updates: std.atomic.Value(u32) = .init(0);
    var held: [4]?*Entity = @splat(null);
    defer for (&held) |maybe_entity| {
        if (maybe_entity) |en| en.release();
    };
    var hold_i: usize = 0;
    // Recent uuids bias wake/delete ops toward residents; stale entries miss.
    var recent: [4]Handle = @splat(0);
    var recent_i: usize = 0;

    for (0..smith.value(u8)) |_| {
        var random_uuid: Handle = undefined;
        testing.io.random(std.mem.asBytes(&random_uuid));
        const target = if (smith.value(bool)) recent[smith.value(u2)] else random_uuid;
        switch (smith.value(enum { spawn, hold, drop, get, mark_deleted, schedule, update })) {
            .spawn => {
                const delay: ?u64 = if (smith.value(bool)) @as(u64, smith.value(u16)) % 6000 else null;
                const entity = registry.spawn(testing.io, testing.allocator, test_world, TestEntity{
                    .unloaded = &test_unloaded,
                    .updates = &updates,
                    .del = smith.value(bool),
                    .delay_ms = smith.value(u6),
                    .run_limit = smith.value(u2),
                }, .{ .initial_delay_ms = delay }) catch continue;
                recent[recent_i] = entity.uuid;
                recent_i = (recent_i + 1) % recent.len;
                entity.release();
            },
            .hold => {
                const entity = registry.spawn(testing.io, testing.allocator, test_world, TestEntity{
                    .unloaded = &test_unloaded,
                    .updates = &updates,
                    .run_limit = smith.value(u2),
                }, .{}) catch continue;
                recent[recent_i] = entity.uuid;
                recent_i = (recent_i + 1) % recent.len;
                if (held[hold_i]) |old| old.release();
                held[hold_i] = entity;
                hold_i = (hold_i + 1) % held.len;
            },
            .drop => {
                const i = smith.value(u2);
                if (held[i]) |en| {
                    en.release();
                    held[i] = null;
                }
            },
            .get => {
                const entity = registry.getAndAddRef(testing.io, random_uuid) orelse continue;
                entity.release();
            },
            .mark_deleted => {
                _ = registry.markDeleted(testing.io, target);
            },
            .schedule => {
                _ = registry.schedule(testing.io, target, smith.value(u6));
            },
            .update => {
                registry.drain(testing.io, testing.allocator, test_world, nowNs(testing.io)) catch |err|
                    std.debug.panic("drain failed in fuzz: {any}", .{err});
            },
        }
        if (registry.timer_used != registry.count()) @panic("scheduler out of sync with cache");
    }

    if (registry.count() > EntityMapType.value_count_min) @panic("cache exceeds capacity");
}

test "FuzzEntityRegistry" {
    try std.testing.fuzz({}, fuzzRegistry, .{});
}

test {
    std.testing.refAllDecls(@This());
}
