//! Decides which chunks are loaded and meshed. The streamer owns a `ChunkClipmap`
//! and changes it only inside `pass`, which never overlaps itself, so the clipmap
//! needs no locks: load tasks report back through `completions` and the next pass
//! applies them. A pass touches only what changed: the slabs the windows moved
//! through, the finished tasks, and the lingering list.
const std = @import("std");

const tracy = @import("tracy");

const ChunkClipmap = @import("ChunkClipmap.zig");
const World = @import("world/World.zig");

const ChunkStreamer = @This();

/// Extra chunks each window holds past the keep set, so a lingering mesh survives
/// this much travel at its level before eviction detaches it.
const lingering_margin = 2;
/// A detached mesh farther than this many window radii from the player is dropped
/// even while nothing covers it yet, which bounds the set and clears teleports.
const detached_reach = 2;
/// Streaming settings must hold still this long before the clipmap is rebuilt,
/// so dragging a slider rebuilds once, on release.
const settings_debounce_ms = 300;

current: ?Current = null,
pending_settings: ?struct { settings: Settings, since: std.Io.Timestamp } = null,
completions: Completions = .{},
/// Active chunks outside the keep set, waiting until something covers them.
lingering: std.ArrayList(World.ChunkPos) = .empty,
/// Meshes of chunks evicted from their window before anything covered them.
/// They have no cell; `unloadDetached` drops them once an ancestor shows the area.
detached: std.AutoHashMapUnmanaged(World.ChunkPos, void) = .empty,
/// Positions with a load task in flight. It survives eviction, so a chunk that leaves
/// and re-enters its window never gets a second load while the first runs, and every
/// load completion is the only one for its position.
loads_in_flight: std.AutoHashMapUnmanaged(World.ChunkPos, void) = .empty,
/// Load candidates of the running pass.
loads: std.ArrayList(World.ChunkPos) = .empty,
active_count: u64 = 0,
last_unload: std.Io.Timestamp = .zero,

const Current = struct {
    clipmap: ChunkClipmap,
    settings: Settings,

    fn keeps(current: Current, pos: World.ChunkPos) bool {
        const lvl = current.clipmap.levelAt(pos.level) orelse return false;
        return current.settings.keepRegion(pos.level, lvl.center).contains(pos.position);
    }
};

/// Widens a (horizontal, vertical) radius to xyz; z reuses the horizontal radius.
fn horizontal(v: @Vector(2, u32)) @Vector(3, u32) {
    return .{ v[0], v[1], v[0] };
}

pub const Settings = struct {
    lowest_level: i32,
    highest_level: i32,
    render_distance: @Vector(2, u32),
    lod_overlap: i32,

    /// The chunks of `level` to keep loaded around the window `center`.
    fn keepRegion(settings: Settings, level: i32, center: ChunkClipmap.Position) ChunkClipmap.Region {
        const distance = settings.render_distance;
        const hole = settings.holeRadius(level);
        return .{ .center = center, .outer = horizontal(distance), .hole = horizontal(hole) };
    }

    /// Stops each generation ring short of the child ring it feeds by the overlap. Detail levels never mark coverage, so the refinement floor stays at 0.
    fn holeRadius(settings: Settings, level: i32) @Vector(2, u32) {
        if (level <= settings.lowest_level or (settings.lowest_level < 0 and level == 0)) return @splat(0);
        const half: @Vector(2, i32) = @intCast(settings.render_distance / @as(@Vector(2, u32), @splat(World.scale_factor)));
        return @intCast(@max(half - @as(@Vector(2, i32), @splat(settings.lod_overlap)), @as(@Vector(2, i32), @splat(0))));
    }

    fn halfExtent(settings: Settings) @Vector(3, u32) {
        return horizontal(settings.render_distance) + @as(@Vector(3, u32), @splat(lingering_margin));
    }
};

/// Everything the keep gate depends on, snapshotted once per pass or task.
pub const View = struct {
    settings: Settings,
    player_block: World.BlockPos,

    /// Whether `pos` is within render distance at its level and outside the hole the finer level fills.
    pub fn keeps(view: View, pos: World.ChunkPos) bool {
        if (pos.level < view.settings.lowest_level or pos.level > view.settings.highest_level) return false;
        return view.settings.keepRegion(pos.level, ChunkClipmap.centerFor(view.player_block, pos.level)).contains(pos.position);
    }
};

const Kind = enum { load, remesh };

pub const Request = struct {
    pos: World.ChunkPos,
    /// Loads carry the settings they were queued under, so the task can skip a chunk the player has since left.
    kind: union(Kind) { load: Settings, remesh },
};

pub const Completion = struct {
    pos: World.ChunkPos,
    kind: Kind,
    /// The task left the chunk's mesh in the renderer, or the chunk has no faces.
    meshed: bool,
};

/// Hands task results to the streamer. Any thread may push; only the pass takes.
pub const Completions = struct {
    mutex: std.Io.Mutex = .init,
    list: std.ArrayList(Completion) = .empty,
    /// The pass's half of the double buffer, swapped with `list` by `take`.
    taken: std.ArrayList(Completion) = .empty,
    /// Tasks whose completion is not pushed yet. `list` always has room for all of
    /// them, so a task can report from a `defer`, even while it is being canceled.
    in_flight: usize = 0,
    /// Set while `list` holds completions no pass has taken. The frame thread reads it
    /// lock-free to decide whether a pass has work.
    pending: std.atomic.Value(bool) = .init(false),

    /// Makes room for `count` more tasks. Call before dispatching them.
    pub fn reserve(completions: *Completions, io: std.Io, gpa: std.mem.Allocator, count: usize) !void {
        try completions.mutex.lock(io);
        defer completions.mutex.unlock(io);
        try completions.list.ensureUnusedCapacity(gpa, completions.in_flight + count);
        completions.in_flight += count;
    }

    pub fn push(completions: *Completions, io: std.Io, completion: Completion) void {
        completions.mutex.lockUncancelable(io);
        defer completions.mutex.unlock(io);
        completions.list.appendAssumeCapacity(completion);
        completions.in_flight -= 1;
        completions.pending.store(true, .release);
    }

    /// Returns every pushed completion, valid until the next `take`. Only the pass may call it.
    fn take(completions: *Completions, io: std.Io, gpa: std.mem.Allocator) ![]const Completion {
        try completions.mutex.lock(io);
        defer completions.mutex.unlock(io);
        completions.taken.clearRetainingCapacity();
        try completions.taken.ensureTotalCapacity(gpa, completions.in_flight);
        std.mem.swap(std.ArrayList(Completion), &completions.taken, &completions.list);
        completions.pending.store(false, .release);
        return completions.taken.items;
    }

    fn deinit(completions: *Completions, gpa: std.mem.Allocator) void {
        std.debug.assert(completions.in_flight == 0);
        completions.list.deinit(gpa);
        completions.taken.deinit(gpa);
    }
};

/// Every task must have pushed its completion first.
pub fn deinit(streamer: *ChunkStreamer, gpa: std.mem.Allocator) void {
    if (streamer.current) |*current| current.clipmap.deinit(gpa);
    streamer.completions.deinit(gpa);
    streamer.lingering.deinit(gpa);
    streamer.detached.deinit(gpa);
    streamer.loads_in_flight.deinit(gpa);
    streamer.loads.deinit(gpa);
    streamer.* = undefined;
}

/// Brings the clipmap up to date with `view` and dispatches the loads that are missing.
/// `host` provides `dispatch(io, Request) void` and `removeMesh(io, ChunkPos) !void`.
pub fn pass(streamer: *ChunkStreamer, io: std.Io, gpa: std.mem.Allocator, view: View, now: std.Io.Timestamp, unload_interval_ms: u64, host: anytype) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "ChunkStreamer.pass" });
    defer zone.end();

    if (streamer.settingsSettled(view.settings, now)) {
        try streamer.rebuild(io, gpa, view, host);
    } else {
        try streamer.recenter(io, gpa, view.player_block, host);
    }

    try streamer.applyCompletions(io, gpa, host);
    try streamer.dispatchLoads(io, gpa, host);

    if (streamer.last_unload.durationTo(now).toMilliseconds() >= unload_interval_ms) {
        streamer.last_unload = now;
        try streamer.unloadLingering(io, host);
        try streamer.unloadDetached(io, gpa, host);
    }
}

/// Meshes the renderer holds for this streamer: active chunks plus detached ones.
pub fn meshCount(streamer: *const ChunkStreamer) u64 {
    return streamer.active_count + streamer.detached.count();
}

/// Whether the clipmap must be rebuilt for `settings`: always at first, otherwise once a change has held for the debounce.
fn settingsSettled(streamer: *ChunkStreamer, settings: Settings, now: std.Io.Timestamp) bool {
    const current = streamer.current orelse return true;
    if (std.meta.eql(current.settings, settings)) {
        streamer.pending_settings = null;
        return false;
    }
    if (streamer.pending_settings) |pending| {
        if (std.meta.eql(pending.settings, settings)) return pending.since.durationTo(now).toMilliseconds() >= settings_debounce_ms;
    }
    streamer.pending_settings = .{ .settings = settings, .since = now };
    return false;
}

/// Replaces the clipmap with one built for `view.settings`, carrying over every
/// chunk that still fits and recomputing coverage from the carried active chunks.
fn rebuild(streamer: *ChunkStreamer, io: std.Io, gpa: std.mem.Allocator, view: View, host: anytype) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "ChunkStreamer.rebuild" });
    defer zone.end();
    const settings = view.settings;
    var next: Current = .{
        .clipmap = try .init(gpa, settings.lowest_level, settings.highest_level, settings.halfExtent(), view.player_block),
        .settings = settings,
    };
    // Scoped so a failure after the hand-off to `streamer.current` cannot free the installed clipmap.
    if (streamer.current) |*old| {
        errdefer next.clipmap.deinit(gpa);
        for (old.clipmap.levels, 0..) |*lvl, index| {
            const level_index = old.clipmap.levelIndex(index);
            for (lvl.cells, 0..) |state, slot| {
                if (!state.active and !state.edited) continue;
                const pos: World.ChunkPos = .{ .level = level_index, .position = old.clipmap.positionAt(lvl.center, slot) };
                if (next.clipmap.get(pos)) |next_state| {
                    next_state.* = .{ .active = state.active, .edited = state.edited };
                    continue;
                }
                try streamer.detach(io, gpa, pos, state, host);
            }
        }
        old.clipmap.deinit(gpa);
    }
    streamer.current = next;
    streamer.pending_settings = null;
    streamer.lingering.clearRetainingCapacity();

    const current = &streamer.current.?;
    for (current.clipmap.levels, 0..) |*lvl, index| {
        const level_index = current.clipmap.levelIndex(index);
        const keep = current.settings.keepRegion(level_index, lvl.center);
        for (lvl.cells, 0..) |*state, slot| {
            if (!state.active) continue;
            const pos: World.ChunkPos = .{ .level = level_index, .position = current.clipmap.positionAt(lvl.center, slot) };
            streamer.setCoverage(pos, true);
            if (!keep.contains(pos.position)) try streamer.addLingering(gpa, pos, state);
        }
        const load: Visitor(@TypeOf(host)) = .{ .streamer = streamer, .io = io, .gpa = gpa, .host = host, .level = level_index };
        try keep.forEachDifference(null, load, @TypeOf(load).load);
    }
}

/// Moves every window to the player. Positions leaving a window are evicted first,
/// for all levels, so coverage bubbles through the windows they were counted in.
fn recenter(streamer: *ChunkStreamer, io: std.Io, gpa: std.mem.Allocator, player_block: World.BlockPos, host: anytype) !void {
    const current = &streamer.current.?;
    const clipmap = &current.clipmap;
    if (@reduce(.And, clipmap.levels[0].center == ChunkClipmap.centerFor(player_block, clipmap.lowest_level))) return;
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "ChunkStreamer.recenter" });
    defer zone.end();

    for (clipmap.levels, 0..) |*lvl, index| {
        const level_index = clipmap.levelIndex(index);
        const new_window = clipmap.window(ChunkClipmap.centerFor(player_block, level_index));
        const evict: Visitor(@TypeOf(host)) = .{ .streamer = streamer, .io = io, .gpa = gpa, .host = host, .level = level_index };
        try clipmap.window(lvl.center).forEachDifference(new_window, evict, @TypeOf(evict).evict);
    }

    for (clipmap.levels, 0..) |*lvl, index| {
        const level_index = clipmap.levelIndex(index);
        const old_keep = current.settings.keepRegion(level_index, lvl.center);
        lvl.center = ChunkClipmap.centerFor(player_block, level_index);
        const new_keep = current.settings.keepRegion(level_index, lvl.center);
        const visitor: Visitor(@TypeOf(host)) = .{ .streamer = streamer, .io = io, .gpa = gpa, .host = host, .level = level_index };
        try old_keep.forEachDifference(new_keep, visitor, @TypeOf(visitor).leave);
        try new_keep.forEachDifference(old_keep, visitor, @TypeOf(visitor).load);
    }
}

fn Visitor(comptime Host: type) type {
    return struct {
        streamer: *ChunkStreamer,
        io: std.Io,
        gpa: std.mem.Allocator,
        host: Host,
        level: i32,

        fn load(visitor: @This(), position: ChunkClipmap.Position) !void {
            try visitor.streamer.loads.append(visitor.gpa, .{ .level = visitor.level, .position = position });
        }

        fn evict(visitor: @This(), position: ChunkClipmap.Position) !void {
            const streamer = visitor.streamer;
            const pos: World.ChunkPos = .{ .level = visitor.level, .position = position };
            const state = streamer.current.?.clipmap.get(pos).?;
            if (state.isCovering()) streamer.setCoverage(pos, false);
            try streamer.detach(visitor.io, visitor.gpa, pos, state.*, visitor.host);
            state.* = .{};
        }

        fn leave(visitor: @This(), position: ChunkClipmap.Position) !void {
            const pos: World.ChunkPos = .{ .level = visitor.level, .position = position };
            const state = visitor.streamer.current.?.clipmap.get(pos) orelse return;
            if (state.active) try visitor.streamer.addLingering(visitor.gpa, pos, state);
        }
    };
}

/// Hands the mesh of a chunk losing its cell to the detached set, so its area stays
/// drawn until something covers it. An edit's mesh lacks structures and just goes.
fn detach(streamer: *ChunkStreamer, io: std.Io, gpa: std.mem.Allocator, pos: World.ChunkPos, state: ChunkClipmap.State, host: anytype) !void {
    if (state.active) {
        try streamer.detached.put(gpa, pos, {});
        streamer.active_count -= 1;
    } else if (state.edited) {
        try streamer.removeMesh(io, pos, host);
    }
}

/// Removes the mesh at `pos` and forgets any detached entry for it, so `unloadDetached` cannot revive the position as active without a mesh.
fn removeMesh(streamer: *ChunkStreamer, io: std.Io, pos: World.ChunkPos, host: anytype) !void {
    _ = streamer.detached.remove(pos);
    try host.removeMesh(io, pos);
}

fn addLingering(streamer: *ChunkStreamer, gpa: std.mem.Allocator, pos: World.ChunkPos, state: *ChunkClipmap.State) !void {
    try streamer.lingering.ensureUnusedCapacity(gpa, 1);
    streamer.addLingeringAssumeCapacity(pos, state);
}

fn addLingeringAssumeCapacity(streamer: *ChunkStreamer, pos: World.ChunkPos, state: *ChunkClipmap.State) void {
    if (state.lingering) return;
    streamer.lingering.appendAssumeCapacity(pos);
    state.lingering = true;
}

/// Applies every finished task. The caller runs passes cancel-protected and treats any error as fatal, so a partly applied batch is never resumed.
fn applyCompletions(streamer: *ChunkStreamer, io: std.Io, gpa: std.mem.Allocator, host: anytype) !void {
    const taken = try streamer.completions.take(io, gpa);
    try streamer.lingering.ensureUnusedCapacity(gpa, taken.len);
    try streamer.loads.ensureUnusedCapacity(gpa, taken.len);
    for (taken) |completion| try streamer.apply(io, completion, host);
}

/// Applies one task result. Capacity for one lingering and one load entry is reserved by the caller.
fn apply(streamer: *ChunkStreamer, io: std.Io, completion: Completion, host: anytype) !void {
    const current = &streamer.current.?;
    const pos = completion.pos;
    if (completion.kind == .load) _ = streamer.loads_in_flight.remove(pos);
    const state = current.clipmap.get(pos) orelse {
        // Evicted while the task ran. A detached chunk keeps the fresh mesh in place of its old one.
        if (completion.meshed and !streamer.detached.contains(pos)) try host.removeMesh(io, pos);
        return;
    };
    const keep = current.keeps(pos);
    switch (completion.kind) {
        .load => {
            if (completion.meshed) {
                // The fresh mesh replaces a detached one, which must not be revived after a later unload.
                _ = streamer.detached.remove(pos);
                streamer.markActive(pos, state);
                if (!keep) streamer.addLingeringAssumeCapacity(pos, state);
                return;
            }
            if (state.active) return;
            if (state.edited) try streamer.removeMesh(io, pos, host);
            state.edited = false;
            if (keep) streamer.loads.appendAssumeCapacity(pos);
        },
        // An edit meshed a chunk that is not active yet. That mesh lacks structures,
        // so the chunk gets a full load, or it is outside the keep set and goes away.
        .remesh => {
            if (!completion.meshed or state.active) return;
            const loading = streamer.loads_in_flight.contains(pos);
            if (!keep and !loading) return streamer.removeMesh(io, pos, host);
            state.edited = true;
            if (!loading) streamer.loads.appendAssumeCapacity(pos);
        },
    }
}

fn markActive(streamer: *ChunkStreamer, pos: World.ChunkPos, state: *ChunkClipmap.State) void {
    state.edited = false;
    if (state.active) return;
    const was_covering = state.isCovering();
    state.active = true;
    streamer.active_count += 1;
    if (!was_covering) streamer.setCoverage(pos, true);
}

/// Records that `pos` became covering (or stopped) in its parent, walking up while the parent's own coverage flips.
fn setCoverage(streamer: *ChunkStreamer, pos: World.ChunkPos, covered: bool) void {
    const clipmap = &streamer.current.?.clipmap;
    var child = pos;
    // Detail levels never mark coverage.
    while (child.level >= 0 and child.level < clipmap.highestLevel()) {
        const parent = child.parent();
        const state = clipmap.get(parent).?;
        const bit = ChunkClipmap.childBit(child);
        if ((state.covered_children & bit != 0) == covered) return;
        const was_covering = state.isCovering();
        if (covered) state.covered_children |= bit else state.covered_children &= ~bit;
        if (state.isCovering() == was_covering) return;
        child = parent;
    }
}

/// Dispatches a load for every keep-set candidate that is neither active nor loading, nearest rings first.
fn dispatchLoads(streamer: *ChunkStreamer, io: std.Io, gpa: std.mem.Allocator, host: anytype) !void {
    const current = &streamer.current.?;
    defer streamer.loads.clearRetainingCapacity();

    // Candidates can repeat; the total order makes repeats adjacent.
    std.mem.sort(World.ChunkPos, streamer.loads.items, &current.clipmap, loadsFirst);
    var unique: usize = 0;
    var previous: ?World.ChunkPos = null;
    for (streamer.loads.items) |pos| {
        if (previous) |prev| if (!loadsFirst(&current.clipmap, prev, pos)) continue;
        previous = pos;
        const state = current.clipmap.get(pos) orelse continue;
        if (state.active or !current.keeps(pos) or streamer.loads_in_flight.contains(pos)) continue;
        streamer.loads.items[unique] = pos;
        unique += 1;
    }
    if (unique == 0) return;

    try streamer.loads_in_flight.ensureUnusedCapacity(gpa, @intCast(unique));
    try streamer.completions.reserve(io, gpa, unique);
    // Marking loads in flight here keeps the dispatchers off shared state.
    const candidates = streamer.loads.items[0..unique];
    for (candidates) |pos| streamer.loads_in_flight.putAssumeCapacityNoClobber(pos, {});

    // One dispatcher per level: when the pool is full, `async` runs a load inline on
    // its dispatcher, and the other levels keep spawning on the threads that free up.
    var group: std.Io.Group = .init;
    var rest = candidates;
    while (rest.len > 0) {
        const level = rest[0].level;
        const end = for (rest, 0..) |pos, i| {
            if (pos.level != level) break i;
        } else rest.len;
        group.async(io, dispatchLevel(@TypeOf(host)), .{ io, host, rest[0..end], current.settings });
        rest = rest[end..];
    }
    // The pass blocks cancellation, and every dispatched load must be started.
    group.await(io) catch unreachable;
}

/// `Group.async` cannot take a generic function, so this binds the host type.
fn dispatchLevel(comptime Host: type) fn (std.Io, Host, []const World.ChunkPos, Settings) void {
    return struct {
        fn run(io: std.Io, host: Host, positions: []const World.ChunkPos, settings: Settings) void {
            for (positions) |pos| host.dispatch(io, .{ .pos = pos, .kind = .{ .load = settings } });
        }
    }.run;
}

/// Orders by level, then ring around the player, then position, so only equal positions tie.
fn loadsFirst(clipmap: *const ChunkClipmap, a: World.ChunkPos, b: World.ChunkPos) bool {
    if (a.level != b.level) return a.level < b.level;
    const a_ring = ring(clipmap, a);
    const b_ring = ring(clipmap, b);
    if (a_ring != b_ring) return a_ring < b_ring;
    inline for (0..3) |axis| if (a.position[axis] != b.position[axis]) return a.position[axis] < b.position[axis];
    return false;
}

fn ring(clipmap: *const ChunkClipmap, pos: World.ChunkPos) u32 {
    return @reduce(.Max, @abs(pos.position - clipmap.levels[@intCast(pos.level - clipmap.lowest_level)].center));
}

/// Removes lingering chunks that are covered again, keeping the rest for a later pass.
fn unloadLingering(streamer: *ChunkStreamer, io: std.Io, host: anytype) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "ChunkStreamer.unloadLingering" });
    defer zone.end();
    const current = &streamer.current.?;
    var kept: usize = 0;
    defer streamer.lingering.shrinkRetainingCapacity(kept);
    for (streamer.lingering.items) |pos| {
        // An evicted entry no longer owns its slot.
        const state = current.clipmap.get(pos) orelse continue;
        if (!state.lingering) continue;
        // A removal could land after an in-flight load's upload and strand it, so wait for the load.
        const loading = streamer.loads_in_flight.contains(pos);
        if (state.active and !current.keeps(pos) and (loading or !streamer.canUnload(pos, state.*))) {
            streamer.lingering.items[kept] = pos;
            kept += 1;
            continue;
        }
        state.lingering = false;
        if (!state.active or current.keeps(pos)) continue;
        state.active = false;
        streamer.active_count -= 1;
        if (!state.isCovering()) streamer.setCoverage(pos, false);
        try host.removeMesh(io, pos);
    }
}

/// Whether a lingering chunk's area is shown by something else: its children, or an active ancestor once the player is far enough that no refinement is pending.
fn canUnload(streamer: *ChunkStreamer, pos: World.ChunkPos, state: ChunkClipmap.State) bool {
    // Detail levels never mark coverage, so they unload as soon as they leave the keep set.
    if (pos.level < 0) return true;
    const current = &streamer.current.?;
    const clipmap = &current.clipmap;
    var ancestor = pos;
    while (ancestor.level < clipmap.highestLevel()) {
        ancestor = ancestor.parent();
        if (!clipmap.get(ancestor).?.active) continue;
        if (state.allCoveredChildren()) return true;
        // Keep this mesh while the player is close enough that the loader
        // could still be refining the area, so a stale low-res view does
        // not flash before the higher-res chunks land.
        const refine_region: ChunkClipmap.Region = .{ .center = clipmap.levelAt(pos.level).?.center, .outer = horizontal(current.settings.render_distance / @as(@Vector(2, u32), @splat(World.scale_factor))) };
        return !refine_region.contains(pos.position);
    }
    return streamer.pastTopLevel(ancestor) or state.allCoveredChildren();
}

/// Whether `top`, a top-level position, is past render distance, where nothing will ever load.
fn pastTopLevel(streamer: *const ChunkStreamer, top: World.ChunkPos) bool {
    const current = &streamer.current.?;
    const region: ChunkClipmap.Region = .{ .center = current.clipmap.levelAt(top.level).?.center, .outer = horizontal(current.settings.render_distance) };
    return !region.contains(top.position);
}

/// Returns detached chunks that are back in their window to their cell, and drops
/// the ones something else now shows or that are past `detached_reach`.
fn unloadDetached(streamer: *ChunkStreamer, io: std.Io, gpa: std.mem.Allocator, host: anytype) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "ChunkStreamer.unloadDetached" });
    defer zone.end();
    const current = &streamer.current.?;
    // Removing by pointer only tombstones the slot, so iteration stays valid.
    var it = streamer.detached.keyIterator();
    while (it.next()) |pos_ptr| {
        const pos = pos_ptr.*;
        if (current.clipmap.get(pos)) |state| {
            if (streamer.loads_in_flight.contains(pos)) {
                // The load replaces the mesh; if it is skipped instead, this flag removes it.
                state.edited = true;
            } else {
                streamer.markActive(pos, state);
                if (!current.keeps(pos)) try streamer.addLingering(gpa, pos, state);
            }
        } else if (!streamer.detachedShownElsewhere(pos)) {
            continue;
        } else {
            try host.removeMesh(io, pos);
        }
        streamer.detached.removeByPtr(pos_ptr);
    }
}

/// Whether a detached chunk's area no longer needs its mesh: an ancestor in its
/// window is active, nothing will ever load there, or it is past `detached_reach`.
fn detachedShownElsewhere(streamer: *const ChunkStreamer, pos: World.ChunkPos) bool {
    const current = &streamer.current.?;
    const clipmap = &current.clipmap;
    const lvl = clipmap.levelAt(pos.level) orelse return true;
    const reach: ChunkClipmap.Region = .{ .center = lvl.center, .outer = clipmap.half_extent * @as(@Vector(3, u32), @splat(detached_reach)) };
    if (!reach.contains(pos.position)) return true;
    var ancestor = pos;
    while (ancestor.level < clipmap.highestLevel()) {
        ancestor = ancestor.parent();
        const state = clipmap.get(ancestor) orelse continue;
        if (state.active) return true;
    }
    return streamer.pastTopLevel(ancestor);
}

/// A host that meshes chunks instantly into a set, deferring completions so the
/// fuzzer controls task order, skips, and edits.
const FakeHost = struct {
    meshes: std.AutoHashMapUnmanaged(World.ChunkPos, void) = .empty,
    requests: std.ArrayList(Request) = .empty,
    /// Per-level dispatchers call `dispatch` concurrently.
    requests_mutex: std.Io.Mutex = .init,

    fn dispatch(host: *FakeHost, io: std.Io, request: Request) void {
        host.requests_mutex.lockUncancelable(io);
        defer host.requests_mutex.unlock(io);
        host.requests.append(std.testing.allocator, request) catch @panic("OOM");
    }

    fn removeMesh(host: *FakeHost, _: std.Io, pos: World.ChunkPos) !void {
        _ = host.meshes.remove(pos);
    }

    fn finish(host: *FakeHost, streamer: *ChunkStreamer, request: Request, meshed: bool) void {
        if (meshed) host.meshes.put(std.testing.allocator, request.pos, {}) catch @panic("OOM");
        streamer.completions.push(std.testing.io, .{ .pos = request.pos, .kind = request.kind, .meshed = meshed });
    }

    fn deinit(host: *FakeHost) void {
        host.meshes.deinit(std.testing.allocator);
        host.requests.deinit(std.testing.allocator);
    }
};

fn fuzzSettings(smith: *std.testing.Smith) Settings {
    const lowest = smith.valueRangeAtMost(i32, -1, 1);
    return .{
        .lowest_level = lowest,
        .highest_level = lowest + smith.valueRangeAtMost(i32, 0, 3),
        .render_distance = .{ smith.valueRangeAtMost(u32, 1, 4), smith.valueRangeAtMost(u32, 1, 3) },
        .lod_overlap = smith.valueRangeAtMost(i32, -1, 2),
    };
}

fn fuzzStreamer(_: void, smith: *std.testing.Smith) !void {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var streamer: ChunkStreamer = .{};
    var host: FakeHost = .{};
    defer host.deinit();
    defer streamer.deinit(gpa);
    // Every reserved task reports before the streamer is torn down.
    defer for (host.requests.items) |request| host.finish(&streamer, request, false);

    var view: View = .{ .settings = fuzzSettings(smith), .player_block = @splat(0) };
    var now: std.Io.Timestamp = .zero;
    // A nonzero interval lets completions land between unload sweeps.
    const unload_interval_ms = smith.valueRangeAtMost(u64, 0, 800);
    for (0..smith.valueRangeAtMost(u8, 1, 40)) |_| {
        switch (smith.value(enum { walk, fly, teleport, settings, finish, edit })) {
            .walk => view.player_block += @as(World.BlockPos, .{ smith.valueRangeAtMost(i64, -40, 40), smith.valueRangeAtMost(i64, -40, 40), smith.valueRangeAtMost(i64, -40, 40) }),
            // Far enough to outrun the margin at the lowest levels, so evicted meshes detach.
            .fly => view.player_block += @as(World.BlockPos, .{ smith.valueRangeAtMost(i64, -600, 600), smith.valueRangeAtMost(i64, -600, 600), smith.valueRangeAtMost(i64, -600, 600) }),
            .teleport => view.player_block = .{ smith.value(i16), smith.value(i16), smith.value(i16) },
            .settings => view.settings = fuzzSettings(smith),
            .finish => for (0..smith.value(u4)) |_| {
                if (host.requests.items.len == 0) break;
                const request = host.requests.swapRemove(smith.index(host.requests.items.len));
                // A task skips about one load in eight, as when the player outran it.
                host.finish(&streamer, request, smith.boolWeighted(1, 7));
            },
            .edit => if (streamer.current) |current| {
                const lvl_index = smith.valueRangeAtMost(i32, current.clipmap.lowest_level, current.clipmap.highestLevel());
                const center = current.clipmap.levelAt(lvl_index).?.center;
                const pos: World.ChunkPos = .{ .level = lvl_index, .position = center + @as(ChunkClipmap.Position, .{ smith.valueRangeAtMost(i32, -3, 3), smith.valueRangeAtMost(i32, -3, 3), smith.valueRangeAtMost(i32, -3, 3) }) };
                if (view.keeps(pos)) {
                    try streamer.completions.reserve(io, gpa, 1);
                    host.finish(&streamer, .{ .pos = pos, .kind = .remesh }, true);
                }
            },
        }
        now.nanoseconds += @as(i96, smith.valueRangeAtMost(u16, 0, 400)) * std.time.ns_per_ms;
        try streamer.pass(io, gpa, view, now, unload_interval_ms, &host);
    }

    // Settle: let the debounce expire, then finish every task until the streamer stops
    // asking. Unloading one mesh can make another unloadable, so pass until nothing moves.
    now.nanoseconds += (settings_debounce_ms + 1) * std.time.ns_per_ms;
    var previous_meshes: u64 = std.math.maxInt(u64);
    for (0..64) |_| {
        if (host.requests.items.len == 0 and host.meshes.count() == previous_meshes) break;
        previous_meshes = host.meshes.count();
        while (host.requests.pop()) |request| host.finish(&streamer, request, true);
        try streamer.pass(io, gpa, view, now, 0, &host);
    } else @panic("streamer never settled");

    const current = &streamer.current.?;
    var active: u64 = 0;
    for (current.clipmap.levels, 0..) |*lvl, index| {
        const level_index = current.clipmap.levelIndex(index);
        for (lvl.cells, 0..) |state, slot| {
            const pos: World.ChunkPos = .{ .level = level_index, .position = current.clipmap.positionAt(lvl.center, slot) };
            if (state.active != host.meshes.contains(pos)) @panic("active flag disagrees with the renderer");
            if (current.keeps(pos) and !state.active) @panic("keep-set chunk not loaded");
            if (state.active and !current.keeps(pos) and streamer.canUnload(pos, state)) @panic("unloadable chunk still lingering");
            if (state.active) active += 1;
            // Recomputes coverage bottom-up and compares it with the stored bits.
            if (level_index >= 0 and level_index < current.clipmap.highestLevel()) {
                const marked = current.clipmap.get(pos.parent()).?.covered_children & ChunkClipmap.childBit(pos) != 0;
                if (marked != state.isCovering()) @panic("coverage bit disagrees with child");
            }
        }
    }
    if (active != streamer.active_count) @panic("active count drifted");
    var detached = streamer.detached.keyIterator();
    while (detached.next()) |pos| {
        if (current.clipmap.get(pos.*) != null) @panic("detached chunk inside its window");
        if (!host.meshes.contains(pos.*)) @panic("detached chunk lost its mesh");
        if (streamer.detachedShownElsewhere(pos.*)) @panic("droppable chunk still detached");
    }
    if (host.meshes.count() != streamer.meshCount()) @panic("mesh the streamer does not track");
    if (streamer.loads_in_flight.count() != 0) @panic("load still tracked after its completion");
}

test "ChunkStreamer settles to the keep set" {
    try std.testing.fuzz({}, fuzzStreamer, .{});
}

test {
    std.testing.refAllDecls(@This());
}
