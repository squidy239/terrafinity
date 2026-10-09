const std = @import("std");
const builtin = @import("builtin");

const Cache = @import("../libs/Cache.zig").Cache;
const tracy = @import("tracy");

pub const Entity = @import("Entity.zig");
/// Entity identity. See `Entity.Handle`.
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
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&uuid));
}

const EntityMapType = Cache(
    Handle,
    Entity,
    Entity.keyFromValue,
    uuidHash,
    .{},
    if (builtin.is_test) 1 else 32,
);

const max_victim_skips = EntityMapType.Shard.value_count_min;

/// Wheel bucket width. Deadlines past the horizon park in overflow.
const tick_ns: u64 = std.time.ns_per_ms;
const wheel_buckets: u32 = 1024;
const horizon_ns: u64 = wheel_buckets * tick_ns;
const drain_batch: u32 = 64;
const drain_splices_max: u32 = 64;
/// Revisit delay for deleted-but-referenced entities.
const retry_ns: u64 = 5 * std.time.ns_per_ms;
const none: u32 = std.math.maxInt(u32);
/// The list a slot is linked into. A free slot sits on the free list through `next`.
const Link = union(enum) { free, parked, overflow, wheel: u10 };

/// A drain's hold on a detached slot.
const Claim = union(enum) {
    idle,
    in_flight,
    /// In flight, with a re-arm recorded during the update. The re-arm wins on settle.
    rearm: u64,
};

const TimerNode = struct {
    link: Link = .free,
    claim: Claim = .idle,
    uuid: Handle = 0,
    deadline_ns: u64 = 0,
    next: u32 = none,
    prev: u32 = none,
    /// Drain generation that armed this timer. Only older generations pop, so a
    /// re-arm inside a drain waits for the next pass.
    armed_gen: u64 = 0,
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
};

pub const DeleteResult = enum { marked, missing };

pub const SpawnOptions = struct {
    /// Delay of the first update. Null parks the entity dormant.
    initial_delay_ms: ?u64 = null,
};

map: EntityMapType,
/// Guards spawn and all scheduler state. Lock it before any shard lock, never
/// after, so spawn cannot deadlock against the drain.
scheduler_mutex: std.Io.Mutex = .init,
timers: std.ArrayList(TimerNode) = .empty,
free_head: u32 = none,
buckets: [wheel_buckets]u32 = @splat(none),
overflow_head: u32 = none,
/// Lower bound on the earliest overflow deadline. The cascade waits until it reaches the horizon.
overflow_next_ns: u64 = std.math.maxInt(u64),
drain_seq: u64 = 0,

pub fn init(allocator: std.mem.Allocator, value_count_max: u64) !@This() {
    return .{ .map = try .init(allocator, value_count_max) };
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

    // Read the clock before the lock. Lock holders must not suspend in the section.
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
        if (node.link != .free and node.uuid == victim.uuid) self.freeSlotLocked(victim.timer_slot);
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

        if (shard.peekVictim(entity.uuid)) |victim| {
            if (victim.ref_count.load(.seq_cst) != 1) {
                if (skips >= max_victim_skips) return error.EntityCacheSetFull;
                skips += 1;
                shard.skipVictim(entity.uuid);
                continue;
            }
        }

        // upsert displaces exactly the way peekVictim simulated, so its result is
        // the victim that the caller unloads after it releases the shard lock.
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

/// Flags a resident entity for deletion. The reap check replaces a far-future timer.
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
    std.debug.assert(node.link != .free and node.uuid == uuid);
    const retry_deadline = now +| retry_ns;
    if (node.claim != .idle) {
        node.claim = .{ .rearm = retry_deadline };
    } else if (node.link == .parked or node.deadline_ns > retry_deadline) {
        // Move only a later deadline forward. A timer that is due sooner keeps its deadline.
        self.linkLocked(entity.timer_slot, retry_deadline, self.drain_seq -| 1, now);
    }
    return .marked;
}

/// Arms or re-arms an entity's timer from now. Zero means the next drain.
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
    std.debug.assert(node.link != .free and node.uuid == uuid);

    const deadline = base_ns +| delay_ms *| std.time.ns_per_ms;
    if (node.claim != .idle) {
        node.claim = .{ .rearm = deadline };
    } else {
        self.linkLocked(slot, deadline, self.drain_seq -| 1, base_ns);
    }
    return true;
}

/// Runs one update for an entity the caller owns and holds by reference, outside
/// the wheel. The caller keeps it resident. Nothing schedules or reaps it.
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

/// Runs every due timer and re-arms from each decision. Leftovers wait for the next call.
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
                // The pass ends here. Re-arm the remainder so that no claim stays in flight.
                // A detached timer was due, so the watermark keeps it due for the next pass.
                for (batch[i + 1 .. batch_len]) |rest| self.settleClaim(ctx, rest.slot, rest.uuid, .{ .link = ctx.watermark });
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
            if (node.claim != .idle or node.armed_gen >= seq or node.deadline_ns > watermark) continue;
            batch[batch_len] = .{ .slot = slot, .uuid = node.uuid };
            batch_len += 1;
            self.unlinkLocked(slot);
            node.claim = .in_flight;
        }
    }
    return batch_len;
}

fn runDue(self: *@This(), ctx: DrainCtx, slot: u32, uuid: Handle) Entity.UpdateError!void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const entity = self.getAndAddRef(ctx.io, uuid) orelse {
        // Eviction freed (or reused) the slot before this claim settled.
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
    // A failed update parks too. A reschedule or delete recorded during the update wins in settleClaim.
    defer {
        entity.release();
        self.settleClaim(ctx, slot, uuid, .park);
    }
    try self.updateNow(ctx.io, ctx.allocator, ctx.world, entity, ctx.watermark);
}

/// Ends one detached claim. A mid-flight wake wins over the fallback. Re-arms
/// stamp the draining generation, so a zero delay waits for the next pass.
fn settleClaim(self: *@This(), ctx: DrainCtx, slot: u32, uuid: Handle, action: SettleAction) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    self.scheduler_mutex.lockUncancelable(ctx.io);
    defer self.scheduler_mutex.unlock(ctx.io);
    const node = &self.timers.items[slot];
    if (node.link == .free or node.uuid != uuid or node.claim == .idle) return;
    const claim = node.claim;
    node.claim = .idle;
    const deadline = switch (claim) {
        .rearm => |rearm| rearm,
        else => switch (action) {
            .free => return self.freeSlotLocked(slot),
            .park => return,
            .link => |link| link,
        },
    };
    self.linkLocked(slot, deadline, ctx.seq, ctx.watermark);
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
    self.timers.items[slot] = .{ .link = .parked };
    return slot;
}

fn freeSlotLocked(self: *@This(), slot: u32) void {
    const node = &self.timers.items[slot];
    std.debug.assert(node.link != .free);
    self.unlinkLocked(slot);
    node.link = .free;
    node.next = self.free_head;
    self.free_head = slot;
}

fn unlinkLocked(self: *@This(), slot: u32) void {
    const node = &self.timers.items[slot];
    const head: *u32 = switch (node.link) {
        .overflow => &self.overflow_head,
        .free, .parked => return,
        .wheel => |bucket| &self.buckets[bucket],
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
    node.link = .parked;
}

fn linkLocked(self: *@This(), slot: u32, deadline_ns: u64, armed_gen: u64, now_ns: u64) void {
    self.unlinkLocked(slot);
    const node = &self.timers.items[slot];
    std.debug.assert(node.link != .free);
    node.deadline_ns = deadline_ns;
    node.armed_gen = armed_gen;
    node.claim = .idle;
    if (deadline_ns -| now_ns > horizon_ns) {
        node.link = .overflow;
        self.overflow_next_ns = @min(self.overflow_next_ns, deadline_ns);
        self.pushFrontLocked(&self.overflow_head, slot);
    } else {
        self.pushWheelLocked(slot);
    }
}

fn pushWheelLocked(self: *@This(), slot: u32) void {
    const node = &self.timers.items[slot];
    const bucket: u10 = @intCast((node.deadline_ns / tick_ns) % wheel_buckets);
    node.link = .{ .wheel = bucket };
    self.pushFrontLocked(&self.buckets[bucket], slot);
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
        if (node.link == .free) continue;
        std.debug.assert(node.claim == .idle);
        const entity = self.getAndAddRef(io, node.uuid).?;
        if (entity.ref_count.load(.seq_cst) != 2)
            std.debug.panic("entity {d} still referenced during shutdown", .{node.uuid});
        const removed = self.map.remove(io, node.uuid).?;
        self.freeSlotLocked(@intCast(i));
        unloadEntity(io, allocator, world, removed);
    }
    std.debug.assert(self.map.count() == 0);

    self.map.deinit(allocator);
    self.timers.deinit(allocator);
    std.log.info("entities unloaded", .{});
}

const testing = std.testing;

/// Slots in use. Every resident entity owns exactly one.
fn usedSlots(self: *const @This()) u64 {
    var used: u64 = 0;
    for (self.timers.items) |node| used += @intFromBool(node.link != .free);
    return used;
}

const test_world: *World = undefined;

var test_unloaded: std.atomic.Value(u32) = .init(0);

const TestEntity = struct {
    unloaded: *std.atomic.Value(u32) = &test_unloaded,
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

/// Resets the unload counter and builds a minimum-capacity registry.
fn initTest() !@This() {
    test_unloaded.store(0, .seq_cst);
    return init(testing.allocator, EntityMapType.value_count_min);
}

fn deinitTest(registry: *@This()) void {
    registry.deinit(testing.io, testing.allocator, test_world);
}

fn spawnTest(registry: *@This(), entity: TestEntity, options: SpawnOptions) !*Entity {
    return registry.spawn(testing.io, testing.allocator, test_world, entity, options);
}

fn drainAt(registry: *@This(), now_ns: u64) !void {
    try registry.drain(testing.io, testing.allocator, test_world, now_ns);
}

fn spawnAndGet(alloc: std.mem.Allocator, io: std.Io) !void {
    var registry = try init(alloc, EntityMapType.value_count_min);
    defer registry.deinit(io, alloc, test_world);

    const entity = try registry.spawn(io, alloc, test_world, TestEntity{}, .{ .initial_delay_ms = 0 });
    entity.release();
    (registry.getAndAddRef(io, entity.uuid) orelse return error.MissingEntity).release();
}

test "spawn allocation failure" {
    test_unloaded.store(0, .seq_cst);
    try testing.checkAllAllocationFailures(testing.allocator, spawnAndGet, .{testing.io});
    try testing.expectEqual(1, test_unloaded.load(.seq_cst));
}

test "held entities are not evicted" {
    var registry = try initTest();
    defer registry.deinitTest();

    const held = try spawnTest(&registry, .{}, .{});
    defer held.release();
    for (0..EntityMapType.value_count_min) |_| {
        const entity = try spawnTest(&registry, .{}, .{ .initial_delay_ms = 0 });
        entity.release();
    }

    try testing.expectEqual(EntityMapType.value_count_min, registry.count());
    try testing.expectEqual(1, test_unloaded.load(.seq_cst));
    (registry.getAndAddRef(testing.io, held.uuid) orelse return error.MissingEntity).release();
}

test "evicted timers never fire" {
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try initTest();
    defer registry.deinitTest();

    for (0..EntityMapType.value_count_min + 4) |_| {
        const entity = try spawnTest(&registry, .{ .updates = &updates }, .{ .initial_delay_ms = 0 });
        entity.release();
    }

    try testing.expectEqual(EntityMapType.value_count_min, registry.count());
    try testing.expectEqual(4, test_unloaded.load(.seq_cst));
    try drainAt(&registry, nowNs(testing.io));
    try testing.expectEqual(EntityMapType.value_count_min, updates.load(.seq_cst));
    try testing.expectEqual(registry.count(), registry.usedSlots());
}

test "deletion reaps without waiting for a prior deadline" {
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try initTest();
    defer registry.deinitTest();

    const due = try spawnTest(&registry, .{ .updates = &updates }, .{ .initial_delay_ms = 0 });
    due.release();
    const far = try spawnTest(&registry, .{ .updates = &updates }, .{ .initial_delay_ms = 60_000 });
    far.release();

    try testing.expectEqual(DeleteResult.marked, registry.markDeleted(testing.io, due.uuid));
    try testing.expectEqual(DeleteResult.marked, registry.markDeleted(testing.io, far.uuid));
    try drainAt(&registry, nowNs(testing.io));
    try testing.expectEqual(1, registry.count());
    try drainAt(&registry, nowNs(testing.io) + 10 * std.time.ns_per_ms);
    try testing.expectEqual(0, registry.count());
    try testing.expectEqual(2, test_unloaded.load(.seq_cst));
    try testing.expectEqual(0, updates.load(.seq_cst));
    try testing.expectEqual(DeleteResult.missing, registry.markDeleted(testing.io, due.uuid));
}

test "handle resolves only while referenced, then misses" {
    var registry = try initTest();
    defer registry.deinitTest();

    const entity = try spawnTest(&registry, .{}, .{});
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
    try testing.expectEqual(0, registry.count());
    try testing.expect(registry.getAndAddRef(testing.io, handle) == null);
}

test "zero delay fires on the next drain, never the same one" {
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try initTest();
    defer registry.deinitTest();

    const entity = try spawnTest(&registry, .{ .updates = &updates }, .{ .initial_delay_ms = 0 });
    entity.release();

    const t0 = nowNs(testing.io);
    try drainAt(&registry, t0);
    try testing.expectEqual(1, updates.load(.seq_cst));
    try drainAt(&registry, t0);
    try testing.expectEqual(2, updates.load(.seq_cst));
}

test "dormant entities sleep until woken" {
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try initTest();
    defer registry.deinitTest();

    const entity = try spawnTest(&registry, .{ .updates = &updates, .run_limit = 0 }, .{});
    const uuid = entity.uuid;
    entity.release();

    try drainAt(&registry, nowNs(testing.io));
    try testing.expectEqual(0, updates.load(.seq_cst));

    var random_uuid: Handle = undefined;
    testing.io.random(std.mem.asBytes(&random_uuid));
    try testing.expectEqual(false, registry.schedule(testing.io, random_uuid, 0));
    try testing.expect(registry.schedule(testing.io, uuid, 0));
    try drainAt(&registry, nowNs(testing.io));
    try testing.expectEqual(1, updates.load(.seq_cst));

    try testing.expect(registry.schedule(testing.io, uuid, 0));
    try testing.expect(registry.schedule(testing.io, uuid, 0));
    try drainAt(&registry, nowNs(testing.io));
    try testing.expectEqual(2, updates.load(.seq_cst));
}

test "a held entity runs only when the caller drives it" {
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try initTest();
    defer registry.deinitTest();

    const entity = try spawnTest(&registry, .{ .updates = &updates, .run_limit = 0 }, .{});
    defer entity.release();

    try registry.updateNow(testing.io, testing.allocator, test_world, entity, nowNs(testing.io));
    try testing.expectEqual(1, updates.load(.seq_cst));

    // Never armed, so the drain leaves it alone.
    try drainAt(&registry, nowNs(testing.io));
    try testing.expectEqual(1, updates.load(.seq_cst));
    try testing.expectEqual(1, registry.count());
}

fn fuzzRegistry(_: void, smith: *std.testing.Smith) !void {
    var registry = try initTest();
    defer registry.deinitTest();

    var updates: std.atomic.Value(u32) = .init(0);
    var held: [4]?*Entity = @splat(null);
    defer for (&held) |maybe_entity| {
        if (maybe_entity) |en| en.release();
    };
    var hold_i: usize = 0;
    // Recent uuids bias wake/delete ops toward residents. Stale entries miss.
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
        if (registry.usedSlots() != registry.count()) @panic("scheduler out of sync with cache");
    }

    if (registry.count() > EntityMapType.value_count_min) @panic("cache exceeds capacity");
}

test "FuzzEntityRegistry" {
    try std.testing.fuzz({}, fuzzRegistry, .{});
}

test {
    std.testing.refAllDecls(@This());
}
