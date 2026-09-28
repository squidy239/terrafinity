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

/// Scheduler tick in nanoseconds: bucket width of the timing wheel.
const tick_ns: u64 = std.time.ns_per_ms;
/// Wheel buckets; deadlines further than wheel_buckets * tick_ns out park in overflow.
const wheel_buckets: u32 = 1024;
const horizon_ns: u64 = wheel_buckets * tick_ns;
/// Max timers detached per splice and splices per drain; bounds one drain pass.
const drain_batch: u32 = 64;
const drain_splices_max: u32 = 64;
/// Revisit delay for deleted-but-referenced entities and faulted updates.
const retry_ns: u64 = 5 * std.time.ns_per_ms;
/// Sentinel for empty link fields.
const none: u32 = std.math.maxInt(u32);
/// Where a timer node is linked: a wheel bucket, the overflow chain, or nowhere.
const Bucket = union(enum) {
    wheel: u10,
    overflow,
    parked,
};

comptime {
    if (wheel_buckets > 1 << 10) @compileError("wheel_buckets must fit in Bucket.wheel");
}

/// One scheduler timer. A slot is held for every resident entity and freed on
/// eviction or reap, so the slab never exceeds cache capacity. Eviction cancels
/// through the deferred path, never under a shard lock.
const TimerNode = struct {
    used: bool = false,
    uuid: u128 = 0,
    deadline_ns: u64 = 0,
    next: u32 = none,
    prev: u32 = none,
    /// Wheel bucket, overflow chain, or parked (linked nowhere).
    bucket: Bucket = .parked,
    /// Drain generation that armed this timer; only older generations pop, so a
    /// re-arm inside a drain waits for the next pass.
    armed_gen: u64 = 0,
    in_flight: bool = false,
    pending_armed: bool = false,
    pending_deadline_ns: u64 = 0,
};

/// Eviction recorded under the shard lock and applied after it is released.
const DeferredCancel = struct {
    slot: u32,
    uuid: u128,
};

/// Per-drain parameters shared by the dispatch helpers.
const DrainCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    world: *World,
    watermark: u64,
    seq: u64,
    update_error: *?Entity.UpdateError,
};

const Due = struct {
    slot: u32,
    uuid: u128,
};

const SettleAction = union(enum) {
    free,
    park,
    link: u64,
    /// Re-link with the node's existing deadline (error leftovers lose nothing).
    keep,
};

map: EntityMapType,
/// Admission mutex for spawn plus all scheduler state. Acquire before any
/// cache shard lock, never after, so spawn cannot deadlock against the drain.
scheduler_mutex: std.Io.Mutex = .init,
/// Timer slab, one slot per resident entity at most. Bounded by init capacity.
timers: []TimerNode = &.{},
timer_used: u64 = 0,
free_head: u32 = none,
buckets: [wheel_buckets]u32 = @splat(none),
overflow_head: u32 = none,
/// Drain generation; each drain bumps it so re-arms wait for the next pass.
drain_seq: u64 = 0,
/// Uuid owned by the pinned per-frame lane (the player). The wheel refuses it
/// in schedule and markDeleted, so the lane owns it exclusively. Written once
/// under the scheduler mutex before drains run; afterwards read-only.
pinned_uuid: ?u128 = null,

/// Creates the cache and a timer slab sized to it plus one spare spawn slot.
pub fn init(allocator: std.mem.Allocator, value_count_max: u64) !@This() {
    // One spare slot beyond cache capacity: spawn reserves before the cache
    // insert runs, and the insert may evict (freeing a slot) rather than fail.
    // Serialized spawns need at most one in-flight reservation, so the spare
    // always covers it and allocation only fails on a broken invariant.
    const capacity: usize = @intCast(value_count_max + 1);
    var self: @This() = .{ .map = try .init(allocator, value_count_max, .{ .name = "entity cache" }) };
    errdefer self.map.deinit(allocator);

    self.timers = try allocator.alloc(TimerNode, capacity);
    errdefer allocator.free(self.timers);

    for (self.timers, 0..) |*node, i| {
        node.next = if (i + 1 < capacity) @intCast(i + 1) else none;
    }
    self.free_head = if (capacity > 0) 0 else none;
    return self;
}

/// Monotonic scheduler clock in nanoseconds, clamped at zero.
pub fn nowNs(io: std.Io) u64 {
    const raw = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    return @intCast(@max(raw, @as(@TypeOf(raw), 0)));
}

/// Counts resident entities.
pub fn count(self: *const @This()) u64 {
    return self.map.count();
}

/// Marks one uuid as pinned outside the wheel. schedule and markDeleted refuse
/// it afterwards, so the pinned per-frame lane owns it exclusively.
pub fn setPinned(self: *@This(), io: std.Io, uuid: u128) void {
    self.scheduler_mutex.lockUncancelable(io);
    defer self.scheduler_mutex.unlock(io);
    self.pinned_uuid = uuid;
}

/// Spawns an entity and returns it with a caller-owned reference, evicting an
/// unpinned entity when full. initial_delay_ms arms the first update; null parks dormant.
pub fn spawn(
    self: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    world: *World,
    entity: anytype,
    initial_delay_ms: ?u64,
) !*Entity {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    var random_uuid: u128 = undefined;
    io.random(std.mem.asBytes(&random_uuid));

    const Impl = @TypeOf(entity);
    const impl = try allocator.create(Impl);
    errdefer allocator.destroy(impl);
    impl.* = entity;

    // Sampled before any lock; holders never suspend mid-section.
    const now = nowNs(io);

    try self.scheduler_mutex.lock(io);
    defer self.scheduler_mutex.unlock(io);

    // Reserve first so a failed insert leaves every structure untouched. The
    // slab is 1:1 with the cache, so exhaustion aliases the cache-full error.
    const slot = self.allocSlotLocked() orelse return error.EntityCacheSetFull;
    errdefer self.freeSlotLocked(slot);

    const result = try self.insert(io, allocator, world, .{
        .type = Impl.Type,
        .uuid = random_uuid,
        .ptr = @ptrCast(impl),
        .ref_count = .init(2),
        .timer_slot = slot,
        .vtable = impl.getInterface(),
    });

    self.timers[slot].uuid = random_uuid;
    if (initial_delay_ms) |delay| {
        self.linkLocked(slot, random_uuid, now +| delay *| std.time.ns_per_ms, self.drain_seq -| 1, now);
    }
    self.applyDeferredLocked(result.evicted);
    return result.entity;
}

/// Result of a cache insert: the stored entity plus the eviction the caller
/// must apply to the scheduler once the shard lock is released.
const InsertResult = struct {
    entity: *Entity,
    evicted: ?DeferredCancel,
};

fn insert(
    self: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    world: *World,
    entity: Entity,
) !InsertResult {
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

        var evicted: ?DeferredCancel = null;
        if (shard.peek_victim(entity.uuid)) |victim| {
            if (victim.ref_count.load(.seq_cst) != 1) {
                if (skips >= max_victim_skips) return error.EntityCacheSetFull;
                skips += 1;
                shard.skip_victim(entity.uuid);
                continue;
            }
            // Record the victim's timer for cancellation after the shard lock
            // is released; the scheduler is never touched under it.
            if (victim.timer_slot != Entity.no_timer) {
                evicted = .{ .slot = victim.timer_slot, .uuid = victim.uuid };
            }
            // Eviction runs under the shard lock per unloadEntity's contract.
            unloadEntity(io, allocator, world, victim.*);
            victim.* = undefined;
        }

        _ = shard.upsert(&entity);
        return .{ .entity = shard.get(entity.uuid).?, .evicted = evicted };
    }
}

/// Unloads an evicted entity under its shard lock. Unload code must not reenter this registry: reentry deadlocks on the held lock or inverts the lock order.
fn unloadEntity(io: std.Io, allocator: std.mem.Allocator, world: *World, entity: Entity) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const save = !entity.deleted.load(.seq_cst);
    entity.vtable.unload(entity.ptr, io, world, entity.uuid, allocator, save) catch |err|
        std.log.err("error unloading entity: {any}", .{err});
}

/// Returns the cached entity with an added caller-owned reference, or null on miss. Deleted entities may still appear until unloaded.
pub fn getAndAddRef(self: *@This(), io: std.Io, uuid: u128) ?*Entity {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const shard, const lock = self.map.getShardAndLock(uuid);
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    const entity = shard.get(uuid) orelse return null;
    entity.addRef();
    return entity;
}

/// Flags a cached entity for deletion; returns false on miss. The drain reaps
/// once unreferenced. Ensures a reap-check timer so dormant entities cannot
/// leak after deletion.
pub fn markDeleted(self: *@This(), io: std.Io, uuid: u128) bool {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    // Sampled before any lock; holders never suspend mid-section.
    const now = nowNs(io);
    self.scheduler_mutex.lockUncancelable(io);
    defer self.scheduler_mutex.unlock(io);
    // The pinned lane owns its entity exclusively; refusing keeps the raw
    // player view from ever dangling through a wheel reap.
    if (self.pinned_uuid == uuid) return false;
    const shard, const lock = self.map.getShardAndLock(uuid);
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    const entity = shard.get(uuid) orelse return false;
    entity.markDeleted();
    const slot = entity.timer_slot;
    if (slot == Entity.no_timer) return true;
    const node = &self.timers[slot];
    if (!node.used or node.uuid != uuid) return true;
    if (node.in_flight) {
        node.pending_armed = true;
        node.pending_deadline_ns = now +| retry_ns;
        return true;
    }
    switch (node.bucket) {
        .parked => self.linkLocked(slot, uuid, now +| retry_ns, self.drain_seq -| 1, now),
        else => {},
    }
    return true;
}

/// Arms or re-arms an entity's timer delay_ms from now; zero means the next
/// drain. Returns false when the uuid is not resident. Safe from any thread; a
/// timer detached mid-drain records the wake as pending instead of racing it.
pub fn schedule(self: *@This(), io: std.Io, uuid: u128, delay_ms: u64) bool {
    // Sampled before any lock; holders never suspend mid-section.
    return self.rescheduleAt(io, uuid, nowNs(io), delay_ms);
}

/// Same as schedule but measures the delay from base_ns instead of the wall
/// clock. An update reschedules from the drain watermark so its delay is
/// independent of how long the drain itself ran, keeping zero deterministic.
pub fn rescheduleAt(self: *@This(), io: std.Io, uuid: u128, base_ns: u64, delay_ms: u64) bool {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    self.scheduler_mutex.lockUncancelable(io);
    defer self.scheduler_mutex.unlock(io);
    // The pinned lane runs its entity every frame itself; the wheel never owns it.
    if (self.pinned_uuid == uuid) return false;
    const shard, const lock = self.map.getShardAndLock(uuid);
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    const entity = shard.get(uuid) orelse return false;
    const slot = entity.timer_slot;
    if (slot == Entity.no_timer) return false;
    const node = &self.timers[slot];
    if (!node.used or node.uuid != uuid) return false;

    const deadline = base_ns +| delay_ms *| std.time.ns_per_ms;
    if (node.in_flight) {
        node.pending_armed = true;
        node.pending_deadline_ns = deadline;
        return true;
    }
    self.linkLocked(slot, uuid, deadline, self.drain_seq -| 1, base_ns);
    return true;
}

/// Runs the pinned per-frame lane for entities the wheel never owns, like the
/// player. Pinned entities always reschedule by lane contract; deletion and
/// dormancy are ignored because the lane owns its entity's liveness.
pub fn updatePinned(
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
    // The lane reruns every frame regardless, so reschedule is a no-op and
    // delete is refused for the pinned uuid; the entity owns its own liveness.
    try update_fn(entity.ptr, .{
        .io = io,
        .world = world,
        .allocator = allocator,
        .now_ns = now_ns,
        .uuid = entity.uuid,
        .registry = self,
    });
}

/// Runs every timer due at the watermark and re-arms from each decision.
/// Bounded per pass; leftover due timers wait for the next call.
pub fn drain(self: *@This(), io: std.Io, allocator: std.mem.Allocator, world: *World, now_ns: u64) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const seq = self.beginDrain(io);
    var update_error: ?Entity.UpdateError = null;
    const ctx: DrainCtx = .{
        .io = io,
        .allocator = allocator,
        .world = world,
        .watermark = now_ns,
        .seq = seq,
        .update_error = &update_error,
    };

    var splices: u32 = 0;
    while (splices < drain_splices_max) : (splices += 1) {
        try io.checkCancel();
        var batch: [drain_batch]Due = undefined;
        const batch_len = try self.spliceDue(ctx, &batch, splices == 0);
        if (batch_len == 0) break;

        for (batch[0..batch_len]) |due| {
            if (update_error != null) {
                self.settleClaim(ctx, due.slot, due.uuid, .keep);
                continue;
            }
            self.runDue(ctx, due.slot, due.uuid);
        }
        if (update_error != null) break;
    }

    if (update_error) |err| return err;
}

fn beginDrain(self: *@This(), io: std.Io) u64 {
    self.scheduler_mutex.lockUncancelable(io);
    defer self.scheduler_mutex.unlock(io);
    self.drain_seq += 1;
    return self.drain_seq;
}

/// Cascades overflow into the wheel, then detaches up to batch capacity of due
/// timers older than this drain's generation. No suspension points inside, so a
/// cancelable lock acquisition is the only failure edge.
fn spliceDue(self: *@This(), ctx: DrainCtx, batch: *[drain_batch]Due, cascade: bool) !usize {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    try self.scheduler_mutex.lock(ctx.io);
    defer self.scheduler_mutex.unlock(ctx.io);

    if (cascade) self.cascadeOverflowLocked(ctx.watermark);
    return self.detachDueLocked(ctx.watermark, ctx.seq, batch);
}

/// Moves overflow timers inside the wheel horizon; runs once per drain so
/// far-future populations cannot multiply the per-splice cost.
fn cascadeOverflowLocked(self: *@This(), watermark: u64) void {
    const cascade = tracy.Zone.begin(.{ .src = @src(), .name = "cascade" });
    defer cascade.end();

    var curr = self.overflow_head;
    while (curr != none) {
        const next = self.timers[curr].next;
        const node = &self.timers[curr];
        if (node.deadline_ns -| watermark <= horizon_ns) {
            const slot = curr;
            self.unlinkLocked(slot);
            self.pushWheelLocked(slot);
        }
        curr = next;
    }
}

/// Detaches due timers older than this drain's generation into batch.
fn detachDueLocked(self: *@This(), watermark: u64, seq: u64, batch: *[drain_batch]Due) usize {
    const detach = tracy.Zone.begin(.{ .src = @src(), .name = "detach" });
    defer detach.end();

    var batch_len: usize = 0;
    for (&self.buckets) |*head| {
        if (batch_len >= batch.len) break;
        var curr = head.*;
        while (curr != none and batch_len < batch.len) {
            const next = self.timers[curr].next;
            const node = &self.timers[curr];
            if (node.in_flight or node.armed_gen >= seq or node.deadline_ns > watermark) {
                curr = next;
                continue;
            }
            batch[batch_len] = .{ .slot = curr, .uuid = node.uuid };
            batch_len += 1;
            self.unlinkLocked(curr);
            self.timers[curr].in_flight = true;
            curr = next;
        }
    }
    return batch_len;
}

fn runDue(self: *@This(), ctx: DrainCtx, slot: u32, uuid: u128) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const entity = self.getAndAddRef(ctx.io, uuid) orelse {
        // Evicted mid-flight; the deferred cancel already flagged or freed it.
        self.settleClaim(ctx, slot, uuid, .free);
        return;
    };

    if (entity.deleted.load(.seq_cst)) {
        self.reapDeleted(ctx, entity, slot, uuid);
        return;
    }
    self.runUpdate(ctx, entity, slot, uuid);
}

/// Reaps a deleted entity once only the cache holds it, else re-arms a retry.
/// The pin blocks slot reuse, so the pointer stays valid across the lookup
/// and removal sections; the null fallthrough is unreachable in production.
fn reapDeleted(self: *@This(), ctx: DrainCtx, entity: *Entity, slot: u32, uuid: u128) void {
    // Count 2 means only the cache and this pass hold it.
    if (entity.ref_count.load(.seq_cst) == 2) {
        if (self.map.remove(ctx.io, uuid)) |removed| {
            self.settleClaim(ctx, slot, uuid, .free);
            unloadEntity(ctx.io, ctx.allocator, ctx.world, removed);
            return;
        }
    }
    // Still referenced elsewhere; retry later.
    entity.release();
    self.settleClaim(ctx, slot, uuid, .{ .link = ctx.watermark +| retry_ns });
}

fn runUpdate(self: *@This(), ctx: DrainCtx, entity: *Entity, slot: u32, uuid: u128) void {
    const update_fn = entity.vtable.update orelse {
        // Entities without update stay parked; the slot is retained 1:1.
        entity.release();
        self.settleClaim(ctx, slot, uuid, .park);
        return;
    };

    const update_ctx: Entity.UpdateContext = .{
        .io = ctx.io,
        .world = ctx.world,
        .allocator = ctx.allocator,
        .now_ns = ctx.watermark,
        .uuid = uuid,
        .registry = self,
    };
    update_fn(entity.ptr, update_ctx) catch |err| {
        entity.release();
        self.settleClaim(ctx, slot, uuid, .{ .link = ctx.watermark +| retry_ns });
        if (ctx.update_error.* == null) ctx.update_error.* = err;
        return;
    };
    // A reschedule or delete issued during the update was recorded on the
    // in-flight claim and wins in settleClaim; with neither, the entity parks.
    entity.release();
    self.settleClaim(ctx, slot, uuid, .park);
}

/// Ends one detached claim, acquiring the scheduler mutex: no caller holds it
/// or any shard lock here, so this cannot nest. Honors eviction cancels and
/// mid-flight wakes first, then applies the fallback. Re-arms stamp the
/// draining generation, so they wait for the next pass even with zero delay.
fn settleClaim(self: *@This(), ctx: DrainCtx, slot: u32, uuid: u128, action: SettleAction) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    self.scheduler_mutex.lockUncancelable(ctx.io);
    defer self.scheduler_mutex.unlock(ctx.io);
    const node = &self.timers[slot];
    if (!node.used or node.uuid != uuid or !node.in_flight) return;
    node.in_flight = false;
    if (node.pending_armed) {
        node.pending_armed = false;
        const pending = node.pending_deadline_ns;
        self.linkLocked(slot, uuid, pending, ctx.seq, ctx.watermark);
        return;
    }
    switch (action) {
        .free => self.freeSlotLocked(slot),
        .park => {},
        .link => |deadline| self.linkLocked(slot, uuid, deadline, ctx.seq, ctx.watermark),
        .keep => self.linkLocked(slot, uuid, node.deadline_ns, ctx.seq, ctx.watermark),
    }
}

fn allocSlotLocked(self: *@This()) ?u32 {
    const slot = self.free_head;
    if (slot == none) return null;
    const node = &self.timers[slot];
    self.free_head = node.next;
    node.* = .{ .used = true };
    self.timer_used += 1;
    return slot;
}

fn freeSlotLocked(self: *@This(), slot: u32) void {
    const node = &self.timers[slot];
    std.debug.assert(node.used);
    self.unlinkLocked(slot);
    node.used = false;
    node.in_flight = false;
    node.pending_armed = false;
    node.next = self.free_head;
    self.free_head = slot;
    self.timer_used -= 1;
}

fn unlinkLocked(self: *@This(), slot: u32) void {
    const node = &self.timers[slot];
    const head: *u32 = switch (node.bucket) {
        .overflow => &self.overflow_head,
        .parked => return,
        .wheel => |b| &self.buckets[b],
    };
    if (node.prev != none) {
        self.timers[node.prev].next = node.next;
    } else {
        head.* = node.next;
    }
    if (node.next != none) {
        self.timers[node.next].prev = node.prev;
    }
    node.next = none;
    node.prev = none;
    node.bucket = .parked;
}

fn linkLocked(self: *@This(), slot: u32, uuid: u128, deadline_ns: u64, armed_gen: u64, now_ns: u64) void {
    self.unlinkLocked(slot);
    const node = &self.timers[slot];
    std.debug.assert(node.used);
    node.uuid = uuid;
    node.deadline_ns = deadline_ns;
    node.armed_gen = armed_gen;
    node.in_flight = false;
    node.pending_armed = false;
    if (deadline_ns -| now_ns > horizon_ns) {
        node.bucket = .overflow;
        self.pushFrontLocked(&self.overflow_head, slot);
    } else {
        self.pushWheelLocked(slot);
    }
}

fn pushWheelLocked(self: *@This(), slot: u32) void {
    const node = &self.timers[slot];
    const bucket: u10 = @intCast((node.deadline_ns / tick_ns) % wheel_buckets);
    node.bucket = .{ .wheel = bucket };
    self.pushFrontLocked(&self.buckets[bucket], slot);
}

fn pushFrontLocked(self: *@This(), head: *u32, slot: u32) void {
    const node = &self.timers[slot];
    node.next = head.*;
    node.prev = none;
    if (head.* != none) self.timers[head.*].prev = slot;
    head.* = slot;
}

fn applyDeferredLocked(self: *@This(), deferred: ?DeferredCancel) void {
    const cancel = deferred orelse return;
    const node = &self.timers[cancel.slot];
    if (!node.used or node.uuid != cancel.uuid) return;
    // Freeing an in-flight slot is safe: the victim is already out of the cache,
    // so its claim can only miss the lookup and no-op on settle, and any slot
    // reuse fails the claim's uuid check.
    self.freeSlotLocked(cancel.slot);
}

/// Unloads every entity. Callers must stop all registry activity first: no live
/// references, no running drains, and no concurrent spawn, schedule, or
/// markDeleted. Panics on outstanding refs.
pub fn deinit(self: *@This(), io: std.Io, allocator: std.mem.Allocator, world: *World) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    // Every resident entity holds a timer slot, so the slab is the census.
    // No drain runs here, so no slot is ever in flight.
    for (self.timers, 0..) |_, i| {
        const idx: u32 = @intCast(i);
        self.scheduler_mutex.lockUncancelable(io);
        if (!self.timers[idx].used) {
            self.scheduler_mutex.unlock(io);
            continue;
        }
        const uuid = self.timers[idx].uuid;
        self.scheduler_mutex.unlock(io);

        const entity = self.getAndAddRef(io, uuid) orelse {
            self.scheduler_mutex.lockUncancelable(io);
            defer self.scheduler_mutex.unlock(io);
            const node = &self.timers[idx];
            std.debug.assert(!node.in_flight);
            if (node.used and node.uuid == uuid) self.freeSlotLocked(idx);
            continue;
        };
        if (entity.ref_count.load(.seq_cst) != 2)
            std.debug.panic("entity {d} still referenced during shutdown", .{uuid});
        if (self.map.remove(io, uuid)) |removed| {
            self.scheduler_mutex.lockUncancelable(io);
            const node = &self.timers[idx];
            std.debug.assert(!node.in_flight);
            if (node.used and node.uuid == uuid) self.freeSlotLocked(idx);
            self.scheduler_mutex.unlock(io);
            unloadEntity(io, allocator, world, removed);
        } else {
            entity.release();
        }
    }
    std.debug.assert(self.map.count() == 0);
    std.debug.assert(self.timer_used == 0);

    self.map.deinit(allocator);
    allocator.free(self.timers);
    self.timers = &.{};
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
    delay_ms: u64 = 0,
    run_limit: u32 = std.math.maxInt(u32),

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

    fn updateFn(ptr: *Entity.Implementation, ctx: Entity.UpdateContext) Entity.UpdateError!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ran = if (self.updates) |updates|
            updates.fetchAdd(1, .seq_cst) + 1
        else
            1;

        if (self.delete) return ctx.delete();
        // Past the run limit the entity stops rescheduling, so it parks.
        if (ran > self.run_limit) return;
        ctx.reschedule(self.delay_ms);
    }
};

fn spawnAndGet(alloc: std.mem.Allocator, io: std.Io) !void {
    var registry = try init(alloc, EntityMapType.value_count_min);
    defer registry.deinit(io, alloc, test_world);

    const entity = try registry.spawn(io, alloc, test_world, TestEntity{ .unloaded = &test_unloaded }, 0);
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
        const entity = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded }, 0);
        entity.release();
    }

    try testing.expectEqual(EntityMapType.value_count_min, registry.count());
    try testing.expectEqual(@as(u32, 1), test_unloaded.load(.seq_cst));
}

test "pinned entities are not evicted" {
    test_unloaded.store(0, .seq_cst);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const pinned = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded }, 0);
    defer pinned.release();

    for (0..EntityMapType.value_count_min) |_| {
        const entity = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded }, 0);
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
        slot.* = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded }, 0);
    }
    defer for (pinned) |entity| entity.release();

    // The timer slab is sized 1:1 with the cache, so slab exhaustion aliases the cache-full error.
    try testing.expectError(error.EntityCacheSetFull, registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded }, 0));
    try testing.expectEqual(@as(u32, 0), test_unloaded.load(.seq_cst));
}

test "evicted timers never fire" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    for (0..EntityMapType.value_count_min + 4) |_| {
        const entity = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded, .updates = &updates }, 0);
        entity.release();
    }

    try testing.expectEqual(EntityMapType.value_count_min, registry.count());
    try testing.expectEqual(@as(u32, 4), test_unloaded.load(.seq_cst));

    // One drain runs each resident exactly once; evicted timers stay silent.
    const t0 = nowNs(testing.io);
    try registry.drain(testing.io, testing.allocator, test_world, t0);
    try testing.expectEqual(EntityMapType.value_count_min, registry.count());
    try testing.expectEqual(@as(u32, @intCast(EntityMapType.value_count_min)), updates.load(.seq_cst));
    try testing.expectEqual(registry.count(), registry.timer_used);
}

test "deleted entities are reaped by the drain" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded, .updates = &updates }, 0);
    entity.release();

    try testing.expect(registry.markDeleted(testing.io, entity.uuid));
    try registry.drain(testing.io, testing.allocator, test_world, nowNs(testing.io));
    try testing.expectEqual(@as(u64, 0), registry.count());
    try testing.expectEqual(@as(u32, 1), test_unloaded.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), updates.load(.seq_cst));
    try testing.expectEqual(false, registry.markDeleted(testing.io, entity.uuid));
}

test "update requesting deletion is reaped on a later drain" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded, .updates = &updates, .delete = true }, 0);
    entity.release();

    const t0 = nowNs(testing.io);
    const ms = std.time.ns_per_ms;
    try registry.drain(testing.io, testing.allocator, test_world, t0);
    try testing.expectEqual(@as(u64, 1), registry.count());
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), test_unloaded.load(.seq_cst));

    // The reap-check re-arms a few milliseconds out, so an early drain changes nothing.
    try registry.drain(testing.io, testing.allocator, test_world, t0 + ms);
    try testing.expectEqual(@as(u64, 1), registry.count());

    // Sample after the retry armed, so its deadline provably precedes t1 + 10ms.
    const t1 = nowNs(testing.io);
    try registry.drain(testing.io, testing.allocator, test_world, t1 + 10 * ms);
    try testing.expectEqual(@as(u64, 0), registry.count());
    try testing.expectEqual(@as(u32, 1), test_unloaded.load(.seq_cst));
}

test "zero delay fires on the next drain, never the same one" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded, .updates = &updates }, 0);
    entity.release();

    // One drain runs each due timer exactly once even though every re-arm is zero.
    const t0 = nowNs(testing.io);
    try registry.drain(testing.io, testing.allocator, test_world, t0);
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));

    // The zero re-arm stamped this drain's generation, so the next drain runs it again.
    try registry.drain(testing.io, testing.allocator, test_world, t0);
    try testing.expectEqual(@as(u32, 2), updates.load(.seq_cst));
}

test "delayed updates wait for their deadline" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try registry.spawn(
        testing.io,
        testing.allocator,
        test_world,
        TestEntity{ .unloaded = &test_unloaded, .updates = &updates, .delay_ms = 100, .run_limit = 0 },
        100,
    );
    entity.release();

    const t0 = nowNs(testing.io);
    const ms = std.time.ns_per_ms;
    try registry.drain(testing.io, testing.allocator, test_world, t0);
    try testing.expectEqual(@as(u32, 0), updates.load(.seq_cst));
    try registry.drain(testing.io, testing.allocator, test_world, t0 + 50 * ms);
    try testing.expectEqual(@as(u32, 0), updates.load(.seq_cst));
    try registry.drain(testing.io, testing.allocator, test_world, t0 + 100 * ms);
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));

    // One-shot: the run parked dormant, so later drains stay quiet.
    try registry.drain(testing.io, testing.allocator, test_world, t0 + 200 * ms);
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));
}

test "dormant entities sleep until woken" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try registry.spawn(
        testing.io,
        testing.allocator,
        test_world,
        TestEntity{ .unloaded = &test_unloaded, .updates = &updates, .run_limit = 0 },
        null,
    );
    const uuid = entity.uuid;
    entity.release();

    const t0 = nowNs(testing.io);
    try registry.drain(testing.io, testing.allocator, test_world, t0);
    try registry.drain(testing.io, testing.allocator, test_world, t0);
    try testing.expectEqual(@as(u32, 0), updates.load(.seq_cst));

    var random_uuid: u128 = undefined;
    testing.io.random(std.mem.asBytes(&random_uuid));
    try testing.expectEqual(false, registry.schedule(testing.io, random_uuid, 0));
    try testing.expect(registry.schedule(testing.io, uuid, 0));

    // The wake stamps fresh wall time, so drain with a timestamp taken after it.
    try registry.drain(testing.io, testing.allocator, test_world, nowNs(testing.io));
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));

    // A double wake still fires once, and a later wake fires again.
    try testing.expect(registry.schedule(testing.io, uuid, 0));
    try testing.expect(registry.schedule(testing.io, uuid, 0));
    try registry.drain(testing.io, testing.allocator, test_world, nowNs(testing.io));
    try testing.expectEqual(@as(u32, 2), updates.load(.seq_cst));
}

test "beyond-horizon deadlines wait in overflow" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try registry.spawn(
        testing.io,
        testing.allocator,
        test_world,
        TestEntity{ .unloaded = &test_unloaded, .updates = &updates, .run_limit = 0 },
        5000,
    );
    entity.release();

    const t0 = nowNs(testing.io);
    const ms = std.time.ns_per_ms;
    try registry.drain(testing.io, testing.allocator, test_world, t0);
    try testing.expectEqual(@as(u32, 0), updates.load(.seq_cst));
    try registry.drain(testing.io, testing.allocator, test_world, t0 + 2000 * ms);
    try testing.expectEqual(@as(u32, 0), updates.load(.seq_cst));
    try registry.drain(testing.io, testing.allocator, test_world, t0 + 5000 * ms);
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));
    try registry.drain(testing.io, testing.allocator, test_world, t0 + 6000 * ms);
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));
}

test "pinned lane runs outside the wheel" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try registry.spawn(
        testing.io,
        testing.allocator,
        test_world,
        TestEntity{ .unloaded = &test_unloaded, .updates = &updates },
        null,
    );
    defer entity.release();
    registry.setPinned(testing.io, entity.uuid);

    try registry.updatePinned(testing.io, testing.allocator, test_world, entity, nowNs(testing.io));
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));

    // The wheel never fires it: the pin refuses the lane's reschedule.
    try registry.drain(testing.io, testing.allocator, test_world, nowNs(testing.io));
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));
    try testing.expectEqual(@as(u64, 1), registry.count());
}

test "pinned uuids refuse wheel scheduling" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try registry.spawn(
        testing.io,
        testing.allocator,
        test_world,
        TestEntity{ .unloaded = &test_unloaded, .updates = &updates },
        null,
    );
    const uuid = entity.uuid;
    entity.release();

    registry.setPinned(testing.io, uuid);
    try testing.expectEqual(false, registry.schedule(testing.io, uuid, 0));
    try testing.expectEqual(false, registry.markDeleted(testing.io, uuid));

    try registry.drain(testing.io, testing.allocator, test_world, nowNs(testing.io));
    try testing.expectEqual(@as(u32, 0), updates.load(.seq_cst));
    try testing.expectEqual(@as(u64, 1), registry.count());
}

test "deinit unloads dormant entities" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);

    const dormant = try registry.spawn(
        testing.io,
        testing.allocator,
        test_world,
        TestEntity{ .unloaded = &test_unloaded, .updates = &updates },
        null,
    );
    dormant.release();
    const active = try registry.spawn(
        testing.io,
        testing.allocator,
        test_world,
        TestEntity{ .unloaded = &test_unloaded, .updates = &updates, .run_limit = 0 },
        0,
    );
    active.release();

    try registry.drain(testing.io, testing.allocator, test_world, nowNs(testing.io));
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));

    registry.deinit(testing.io, testing.allocator, test_world);
    try testing.expectEqual(@as(u32, 2), test_unloaded.load(.seq_cst));
}

test "mid-flight wakes apply as pending" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    const entity = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded, .updates = &updates }, 0);
    const uuid = entity.uuid;
    entity.release();

    // Detach by hand to force the in-flight state a concurrent wake would see.
    const t0 = nowNs(testing.io);
    var update_error: ?Entity.UpdateError = null;
    const seq = registry.beginDrain(testing.io);
    const ctx: DrainCtx = .{
        .io = testing.io,
        .allocator = testing.allocator,
        .world = test_world,
        .watermark = t0,
        .seq = seq,
        .update_error = &update_error,
    };
    var batch: [drain_batch]Due = undefined;
    try testing.expectEqual(@as(usize, 1), try registry.spliceDue(ctx, &batch, true));

    // A wake now records pending instead of racing the detached claim. The base
    // is the fixed t0 so the pending deadline cannot outrun the drain watermark.
    try testing.expect(registry.rescheduleAt(testing.io, uuid, t0, 50));

    // Settling honors the pending wake over the park fallback.
    registry.settleClaim(ctx, batch[0].slot, uuid, .park);

    // Nothing ran yet; the pending deadline fires on a later drain.
    try testing.expectEqual(@as(u32, 0), updates.load(.seq_cst));
    try registry.drain(testing.io, testing.allocator, test_world, t0 + 60 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 1), updates.load(.seq_cst));
    try testing.expectEqual(null, update_error);
}

test "evicting an in-flight timer reclaims its slot at once" {
    test_unloaded.store(0, .seq_cst);
    var updates: std.atomic.Value(u32) = .init(0);
    var registry = try init(testing.allocator, EntityMapType.value_count_min);
    defer registry.deinit(testing.io, testing.allocator, test_world);

    // Fill the cache with due timers so the next spawn must evict a resident.
    for (0..EntityMapType.value_count_min) |_| {
        const entity = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded, .updates = &updates }, 0);
        entity.release();
    }

    // Detach every timer by hand and leave the claims in flight.
    const t0 = nowNs(testing.io);
    var update_error: ?Entity.UpdateError = null;
    const seq = registry.beginDrain(testing.io);
    const ctx: DrainCtx = .{
        .io = testing.io,
        .allocator = testing.allocator,
        .world = test_world,
        .watermark = t0,
        .seq = seq,
        .update_error = &update_error,
    };
    var batch: [drain_batch]Due = undefined;
    const detached = try registry.spliceDue(ctx, &batch, true);
    try testing.expectEqual(@as(usize, EntityMapType.value_count_min), detached);

    // The victim is in flight, so the spawn itself must reclaim its slot; wait
    // for settle and the spare is gone with a resident evicted.
    const spawner = try registry.spawn(testing.io, testing.allocator, test_world, TestEntity{ .unloaded = &test_unloaded, .updates = &updates }, null);
    spawner.release();
    try testing.expectEqual(registry.count(), registry.timer_used);

    // Settling the stale claims must not disturb the reused slots.
    for (batch[0..detached]) |due| registry.settleClaim(ctx, due.slot, due.uuid, .park);
    try testing.expectEqual(registry.count(), registry.timer_used);
    try testing.expectEqual(null, update_error);
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
    // Recently seen uuids bias wake/delete ops toward residents instead of
    // certain misses; stale entries simply miss and exercise that path.
    var recent: [4]u128 = @splat(0);
    var recent_i: usize = 0;

    for (0..smith.value(u8)) |_| {
        var random_uuid: u128 = undefined;
        testing.io.random(std.mem.asBytes(&random_uuid));
        const target = if (smith.value(bool)) recent[smith.value(u2)] else random_uuid;
        switch (smith.value(enum { spawn, pin, unpin, get, mark_deleted, schedule, update })) {
            .spawn => {
                const delay: ?u64 = if (smith.value(bool)) @as(u64, smith.value(u16)) % 6000 else null;
                const entity = registry.spawn(testing.io, testing.allocator, test_world, TestEntity{
                    .unloaded = &test_unloaded,
                    .updates = &updates,
                    .delay_ms = smith.value(u6),
                    .run_limit = smith.value(u2),
                }, delay) catch continue;
                recent[recent_i] = entity.uuid;
                recent_i = (recent_i + 1) % recent.len;
                entity.release();
            },
            .pin => {
                const entity = registry.spawn(testing.io, testing.allocator, test_world, TestEntity{
                    .unloaded = &test_unloaded,
                    .updates = &updates,
                    .delay_ms = smith.value(u6),
                    .run_limit = smith.value(u2),
                }, smith.value(u6)) catch continue;
                recent[recent_i] = entity.uuid;
                recent_i = (recent_i + 1) % recent.len;
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
