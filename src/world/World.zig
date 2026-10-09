const std = @import("std");
const builtin = @import("builtin");

const tracy = @import("tracy");

const Cache = @import("../libs/Cache.zig").Cache;
const SetAssociativeCache = @import("../libs/SetAssociativeCache.zig");

/// Layout shared by the chunk and grid caches, so eviction budgets stay in sync.
const chunk_cache_layout: SetAssociativeCache.Layout = .{};
pub const Block = @import("Block.zig").Block;
const Chunk = @import("Chunk.zig");
pub const ChunkSize = Chunk.ChunkSize;
pub const DefaultGenerator = @import("generators/Terrain.zig").DefaultGenerator;
pub const WorldStorage = @import("WorldStorage.zig");

const World = @This();

pub const standard_level = 0;
pub const scale_factor = 2;
pub const chunk_level = -std.math.log(i32, scale_factor, ChunkSize);

pub const BlockPos = @Vector(3, i64);

pub const ChunkPos = struct {
    level: i32,
    position: @Vector(3, i32),

    pub inline fn levelToBlockRatio(level: i32) i64 {
        const exp = level - chunk_level;
        if (exp < 0) return 1;
        if (exp >= 63) unreachable;
        return @as(i64, 1) << @intCast(exp);
    }

    pub inline fn levelToBlockRatioFloat(level: i32) f32 {
        return @exp2(@as(f32, @floatFromInt(level - chunk_level)));
    }

    pub inline fn levelToLevelRatio(level1: i32, level2: i32) f64 {
        return @exp2(@as(f64, @floatFromInt(level1 - level2)));
    }

    pub inline fn toScale(level: i32) f32 {
        return levelToBlockRatioFloat(level) / ChunkSize;
    }

    pub inline fn parent(self: ChunkPos) ChunkPos {
        return .{
            .level = self.level + 1,
            .position = @divFloor(self.position, @as(@Vector(3, i32), @splat(scale_factor))),
        };
    }

    pub inline fn posInParent(self: ChunkPos) @Vector(3, @Int(.unsigned, std.math.log2(scale_factor))) {
        return @intCast(@mod(self.position, @as(@Vector(3, i32), @splat(scale_factor))));
    }

    pub inline fn add(self: ChunkPos, delta: @Vector(3, i32)) ChunkPos {
        return .{ .position = self.position + delta, .level = self.level };
    }

    pub fn offset(self: ChunkPos, rotation: Chunk.Encoding.FaceRotation) ChunkPos {
        return self.add(rotation.direction());
    }

    pub inline fn toLevel(self: ChunkPos, level: i32) ChunkPos {
        const ratio_vec: @Vector(3, f64) = @splat(levelToLevelRatio(self.level, level));
        const pos_vec: @Vector(3, f64) = @floatFromInt(self.position);
        return .{ .position = @trunc(pos_vec * ratio_vec), .level = level };
    }

    /// Chunk origin in world blocks. Exact only for level >= chunk_level. Finer levels need fromGlobalBlockPos.
    pub inline fn toGlobalBlockPos(self: ChunkPos) BlockPos {
        return self.position * @as(@Vector(3, i64), @splat(levelToBlockRatio(self.level)));
    }

    pub inline fn toLocalBlockPos(self: ChunkPos) BlockPos {
        return self.position * @as(@Vector(3, i64), @splat(ChunkSize));
    }

    pub inline fn fromGlobalBlockPos(block_pos: BlockPos, level: i32) ChunkPos {
        if (level >= chunk_level) {
            return .{
                .position = @intCast(@divFloor(block_pos, @as(@Vector(3, i64), @splat(levelToBlockRatio(level))))),
                .level = level,
            };
        }
        // Finer levels span less than one block, so convert blocks to fine voxels first. Powers of two keep the conversion exact.
        const depth: u6 = if (level < -30) 30 else @intCast(-level);
        const fine_per_block: i64 = @as(i64, 1) << depth;
        return .{
            .position = @intCast(@divFloor(block_pos * @as(BlockPos, @splat(fine_per_block)), @as(BlockPos, @splat(ChunkSize)))),
            .level = level,
        };
    }

    pub inline fn fromLocalBlockPos(block_pos: BlockPos, level: i32) ChunkPos {
        return .{
            .position = @intCast(@divFloor(block_pos, @as(@Vector(3, i64), @splat(ChunkSize)))),
            .level = level,
        };
    }
};

/// Per-world settings. Spawning stays in EntityRegistry.SpawnConfig: spawning is
/// entity-domain, so this file must not depend on the entity layer.
pub const WorldConfig = struct {};

/// Hard ceiling for LOD propagation. Propagation also stops when a level
/// does not change its parent, so this only bounds the worst case.
const max_propagate_level = 24;

pub const ChunkSource = struct {
    pub const GetBlocksMetadata = struct {
        from_disk: bool,
        structures: bool,
    };

    data: *anyopaque,

    getBlocks: ?*const fn (
        self: ChunkSource,
        io: std.Io,
        allocator: std.mem.Allocator,
        world: *World,
        blocks: *Chunk.Encoding,
        chunk_pos: ChunkPos,
        grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block,
    ) error{ Unrecoverable, OutOfMemory, Canceled }!?GetBlocksMetadata,

    placeStructures: ?*const fn (
        self: ChunkSource,
        io: std.Io,
        allocator: std.mem.Allocator,
        world: *World,
        chunk: *Chunk,
        chunk_pos: ChunkPos,
    ) error{ OutOfMemory, Canceled, Unrecoverable }!void,

    save: ?*const fn (
        self: ChunkSource,
        io: std.Io,
        world: *World,
        chunk: *Chunk,
        chunk_pos: ChunkPos,
    ) error{Unrecoverable}!void,

    getTerrainHeight: ?*const fn (
        self: ChunkSource,
        world: *World,
        chunk_pos: @Vector(2, i32),
        level: i32,
    ) error{ OutOfMemory, Unrecoverable }![ChunkSize][ChunkSize]i32,

    deinit: ?*const fn (
        self: ChunkSource,
        io: std.Io,
        allocator: std.mem.Allocator,
        world: *World,
    ) void,
};

pub const EditCallback = struct {
    function: *const fn (
        io: std.Io,
        allocator: std.mem.Allocator,
        chunk_pos: ChunkPos,
        args: *anyopaque,
    ) error{ Canceled, OnEditFailed }!void,
    on_neighbor_face_change: bool,
    context: *anyopaque,
};

pub const ChunkValue = struct {
    chunk: Chunk,
    pos: ChunkPos,

    pub inline fn keyFromValue(value: *const ChunkValue) ChunkPos {
        return value.pos;
    }
};

pub const GridValue = struct {
    grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment),
    chunk: *Chunk,
    pos: ChunkPos,

    pub inline fn keyFromValue(value: *const GridValue) ChunkPos {
        return value.pos;
    }
};

inline fn chunkPosHash(item: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, item);
    return hasher.final();
}

const cache_shard_count = if (builtin.is_test) 1 else 256;
const ChunkMapType = Cache(ChunkPos, ChunkValue, ChunkValue.keyFromValue, chunkPosHash, chunk_cache_layout, cache_shard_count);
const GridMapType = Cache(ChunkPos, GridValue, GridValue.keyFromValue, chunkPosHash, chunk_cache_layout, cache_shard_count);

/// `skipVictim` re-arms the way it skips, so a fully pinned set never yields a
/// null victim. Cap the tries per insert so a pathological set fails loudly
/// instead of spinning. This is a bound, not a guarantee: the selector can
/// cycle past an evictable way.
const max_victim_skips = ChunkMapType.Shard.value_count_min *
    (1 << chunk_cache_layout.clock_bits);

chunks: ChunkMapType,
grids: GridMapType,
config: WorldConfig,
chunk_sources: [4]?ChunkSource,
edit_callback: ?EditCallback = null,

pub fn deinit(self: *World, io: std.Io, allocator: std.mem.Allocator) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const last_prot = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(last_prot);

    self.saveAll(io) catch |err| std.log.err("failed to save world: {any}", .{err});
    std.log.info("chunks unloaded", .{});

    for (self.chunk_sources) |source| {
        if (source) |s| if (s.deinit) |de| de(s, io, allocator, self);
    }

    self.grids.deinit(allocator);
    self.chunks.deinit(allocator);
    std.log.info("world closed", .{});
}

pub fn loadChunk(
    self: *World,
    io: std.Io,
    allocator: std.mem.Allocator,
    chunk_pos: ChunkPos,
    structures: bool,
) error{ OutOfMemory, Unrecoverable, Canceled }!*Chunk {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    if (try self.fetchChunk(io, chunk_pos)) |chunk| {
        errdefer chunk.release();
        if (structures) try self.tryGenStructures(io, allocator, chunk, chunk_pos);
        return chunk;
    }

    var grid_buffer: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = undefined;
    const encoding, const metadata = try self.getBlocks(io, allocator, chunk_pos, &grid_buffer);

    const new_chunk: Chunk = .{
        .encoding = encoding,
        .structures_generated = .init(metadata.structures),
        .ref_count = .init(2),
    };

    const chunk = try self.putChunk(io, new_chunk, chunk_pos);
    errdefer chunk.release();

    if (structures) try self.tryGenStructures(io, allocator, chunk, chunk_pos);
    return chunk;
}

/// Saves every modified chunk, waiting on chunk locks, and fails if any chunk
/// could not be persisted. Destructive callers (e.g. world recreation) must use
/// this instead of `trySaveAll`, which may skip contending shards.
pub fn saveAll(self: *World, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var failed = std.atomic.Value(bool).init(false);
    for (&self.chunks.shards, &self.chunks.shard_locks) |*shard, *lock| {
        group.async(io, saveShard, .{ self, shard, lock, io, .{ .blocking = &failed } });
    }
    try group.await(io);
    if (failed.load(.seq_cst)) return error.SaveFailed;
}

/// Best-effort periodic save: skips shards whose lock another task holds and logs
/// per-chunk failures instead of reporting them. Use `saveAll` when partial
/// persistence is not acceptable.
pub fn trySaveAll(self: *World, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    for (&self.chunks.shards, &self.chunks.shard_locks) |*shard, *lock| {
        group.async(io, saveShard, .{ self, shard, lock, io, .best_effort });
    }
    try group.await(io);
}

const save_window_size = 64;
const SaveWindowItem = struct {
    chunk: *Chunk,
    pos: ChunkPos,
};

fn saveShard(
    self: *World,
    shard: *ChunkMapType.Shard,
    lock: *std.Io.Mutex,
    io: std.Io,
    mode: union(enum) { blocking: *std.atomic.Value(bool), best_effort },
) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    while (true) {
        if (mode == .blocking) {
            lock.lockUncancelable(io);
        } else if (!lock.tryLock()) {
            return;
        }

        var window_buf: [save_window_size]SaveWindowItem = undefined;
        var window = std.ArrayList(SaveWindowItem).initBuffer(&window_buf);
        var it = shard.iterator();
        while (window.items.len < window.capacity) {
            const c = it.next() orelse break;
            if (!c.chunk.modified.load(.seq_cst)) continue;
            c.chunk.addRef();
            window.appendAssumeCapacity(.{ .chunk = &c.chunk, .pos = c.keyFromValue() });
        }
        lock.unlock(io);

        if (window.items.len == 0) return;

        var save_failed = false;
        var chunk_contended = false;
        for (window.items) |item| {
            const locked = if (mode == .blocking) blk: {
                item.chunk.encoding_lock.lockSharedUncancelable(io);
                break :blk true;
            } else item.chunk.encoding_lock.tryLockShared(io);

            if (!locked) {
                chunk_contended = true;
                item.chunk.release();
                continue;
            }
            defer item.chunk.encoding_lock.unlockShared(io);

            self.save(io, item.chunk, item.pos) catch |err| {
                save_failed = true;
                if (mode == .blocking) mode.blocking.store(true, .release);
                std.log.err("error saving chunk: {any}, {any}\n", .{ item.pos, err });
            };
            item.chunk.release();
        }

        if (save_failed or chunk_contended) return;
    }
}

pub const Reader = struct {
    world: *World,
    last_chunk_read_cache: ?struct { chunk_pos: ChunkPos, chunk: *Chunk } = null,

    pub fn getBlock(self: *Reader, io: std.Io, allocator: std.mem.Allocator, block_pos: BlockPos, level: i32) !Block {
        const chunk_pos: ChunkPos = .fromLocalBlockPos(block_pos, level);
        const local_pos: @Vector(3, usize) = @intCast(@mod(block_pos, @as(BlockPos, @splat(ChunkSize))));

        if (self.last_chunk_read_cache) |cache| {
            if (std.meta.eql(cache.chunk_pos, chunk_pos)) return readBlockFromEncoding(cache.chunk.encoding, local_pos);
        }

        self.clear(io);
        const chunk = try self.world.loadChunk(io, allocator, chunk_pos, false);
        errdefer chunk.release();
        try chunk.lockShared(io);
        self.last_chunk_read_cache = .{ .chunk_pos = chunk_pos, .chunk = chunk };
        return readBlockFromEncoding(chunk.encoding, local_pos);
    }

    pub fn clear(self: *Reader, io: std.Io) void {
        if (self.last_chunk_read_cache) |cache| {
            cache.chunk.releaseAndUnlockShared(io);
            self.last_chunk_read_cache = null;
        }
    }
};

pub const Editor = struct {
    pub const Tree = @import("structures/Tree.zig").Tree;

    world: *World,
    temp_allocator: std.mem.Allocator,
    propagate_changes: bool = true,

    last_chunk_cache: ?struct {
        chunk_pos: ChunkPos,
        grid: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block,
    } = null,

    edit_buffer: std.HashMapUnmanaged(
        ChunkPos,
        struct { grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) },
        HashContext,
        80,
    ) = .empty,

    const HashContext = struct {
        pub const hash = hashFn;
        pub const eql = std.hash_map.getAutoEqlFn(ChunkPos, @This());

        inline fn hashFn(ctx: @This(), pos: ChunkPos) u64 {
            _ = ctx;
            const first: u64 = @bitCast([2]i32{ pos.level, pos.position[0] });
            const second: u64 = @bitCast([2]i32{ pos.position[1], pos.position[2] });
            return first ^ second;
        }
    };

    /// First task error as its error int. 0 is never a valid error int, so it means no error.
    const ErrorStore = std.atomic.Value(@Int(.unsigned, @bitSizeOf(anyerror)));

    /// Returns `Canceled` to unwind the task, and records any other error in `err_store`.
    fn storeTaskError(err_store: *ErrorStore, err: anyerror) std.Io.Cancelable!void {
        if (err == error.Canceled) return error.Canceled;
        err_store.store(@intFromError(err), .seq_cst);
    }

    /// Waits for every task in `group`, then returns the first error a task recorded.
    fn awaitTasks(group: *std.Io.Group, io: std.Io, err_store: *const ErrorStore) !void {
        try group.await(io);
        if (err_store.raw != 0) return @errorFromInt(err_store.raw);
    }

    pub inline fn placeBlock(self: *Editor, block: Block, pos: @Vector(3, i64), level: i32) !void {
        const chunk_pos: ChunkPos = .fromLocalBlockPos(pos, level);
        const local_pos: @Vector(3, usize) = @intCast(@mod(pos, @as(BlockPos, @splat(ChunkSize))));

        if (self.last_chunk_cache) |cache| {
            if (std.meta.eql(cache.chunk_pos, chunk_pos)) {
                cache.grid[local_pos[0]][local_pos[1]][local_pos[2]] = block;
                return;
            }
        }

        const entry = try self.edit_buffer.getOrPut(self.temp_allocator, chunk_pos);
        if (!entry.found_existing) {
            const ptr: *[ChunkSize * ChunkSize][ChunkSize]Block = @ptrCast(entry.value_ptr);
            for (ptr) |*row| row.* = @splat(.null);
        }
        self.last_chunk_cache = .{ .chunk_pos = chunk_pos, .grid = &entry.value_ptr.grid };
        entry.value_ptr.grid[local_pos[0]][local_pos[1]][local_pos[2]] = block;
    }

    pub fn placeSamplerShape(self: *Editor, block: Block, shape: anytype, level: i32) !void {
        const zone: tracy.Zone = .begin(.{ .src = @src() });
        defer zone.end();

        const bb = shape.bounding_box;
        var y = bb[2];
        while (y <= bb[3]) : (y += 1) {
            var dx = bb[0];
            while (dx <= bb[1]) : (dx += 1) {
                var dz = bb[4];
                while (dz <= bb[5]) : (dz += 1) {
                    if (shape.isPointInside(.{ dx, y, dz })) {
                        const world_pos: @Vector(3, i64) = switch (comptime @typeInfo(@TypeOf(bb[0]))) {
                            .float => .{ @floor(dx), @floor(y), @floor(dz) },
                            .int => .{ @intCast(dx), @intCast(y), @intCast(dz) },
                            else => unreachable,
                        };
                        try self.placeBlock(block, world_pos, level);
                    }
                }
            }
        }
    }

    pub fn flush(self: *Editor, io: std.Io, allocator: std.mem.Allocator) !void {
        const zone: tracy.Zone = .begin(.{ .src = @src() });
        defer zone.end();
        defer self.clear();

        const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "flush_lock_edit_buffer" });
        defer zone_lock.end();
        self.edit_buffer.lockPointers();
        defer self.edit_buffer.unlockPointers();

        var remesh_neighbors: std.AutoHashMap(ChunkPos, void) = .init(self.temp_allocator);
        defer remesh_neighbors.deinit();

        var group: std.Io.Group = .init;
        defer group.cancel(io);

        var err_store: ErrorStore = .init(0);

        {
            const edit = tracy.Zone.begin(.{ .src = @src(), .name = "edit" });
            defer edit.end();
            // Each task writes only its own slot, indexed by edit-buffer iteration order.
            const sides_changed = try self.temp_allocator.alloc([6]bool, self.edit_buffer.count());
            defer self.temp_allocator.free(sides_changed);
            var it = self.edit_buffer.iterator();
            for (sides_changed) |*sides| {
                const diff_chunk = it.next().?;
                const encoding: Chunk.Encoding = .fromBlocks(&diff_chunk.value_ptr.grid);
                group.async(io, editChunk, .{ self, io, allocator, diff_chunk.key_ptr.*, encoding, sides, &err_store });
            }
            try awaitTasks(&group, io, &err_store);

            it = self.edit_buffer.iterator();
            for (sides_changed) |sides| {
                const chunk_pos = it.next().?.key_ptr.*;
                for (sides, std.enums.values(Chunk.Encoding.FaceRotation)) |changed, rotation| {
                    if (changed) try remesh_neighbors.put(chunk_pos.offset(rotation), {});
                }
            }
        }

        if (self.propagate_changes) {
            const propagate = tracy.Zone.begin(.{ .src = @src(), .name = "propagate" });
            defer propagate.end();
            try self.propagateEditedGroups(io, allocator, &group, &err_store);
        }

        {
            const callbacks = tracy.Zone.begin(.{ .src = @src(), .name = "callbacks" });
            defer callbacks.end();
            if (self.world.edit_callback) |callback| {
                var it = self.edit_buffer.keyIterator();
                while (it.next()) |pos| group.async(io, runEditCallback, .{ callback, io, allocator, pos.*, &err_store });
                var neighbor_it = remesh_neighbors.keyIterator();
                while (neighbor_it.next()) |pos| group.async(io, runEditCallback, .{ callback, io, allocator, pos.*, &err_store });
            }
            try awaitTasks(&group, io, &err_store);
        }
    }

    pub fn clear(self: *Editor) void {
        self.last_chunk_cache = null;
        self.edit_buffer.clearAndFree(self.temp_allocator);
    }

    fn propagateToParent(self: *Editor, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos) !bool {
        const zone = tracy.Zone.begin(.{ .src = @src() });
        defer zone.end();

        const chunk = try self.world.loadChunk(io, allocator, chunk_pos, false);
        defer chunk.release();

        const parent_pos = chunk_pos.parent();
        const simplified_size = ChunkSize / scale_factor;

        var simplified: [simplified_size][simplified_size][simplified_size]Block = undefined;
        var is_uniform = false;

        const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "propagateToParent_lock_shared" });
        defer zone_lock.end();
        try chunk.lockShared(io);
        switch (chunk.encoding) {
            .grid => |blocks| simplified = Chunk.Encoding.simplifyBlocks(blocks),
            .uniform => |block| {
                simplified = @splat(@splat(@splat(block)));
                is_uniform = true;
            },
        }
        chunk.unlockShared(io);

        const pos_in_parent = chunk_pos.posInParent() * @as(@Vector(3, u8), @splat(simplified_size));
        const block_pos = parent_pos.toLocalBlockPos() + pos_in_parent;

        const parent = try self.world.loadChunk(io, allocator, parent_pos, false);
        defer parent.release();

        try parent.lockShared(io);
        defer parent.unlockShared(io);

        if (is_uniform and parent.encoding == .uniform and parent.encoding.uniform == simplified[0][0][0]) return false;

        var changed_parent = false;
        for (0..simplified_size) |x| {
            for (0..simplified_size) |y| {
                for (0..simplified_size) |z| {
                    const world_pos = block_pos + @as(BlockPos, @intCast(@Vector(3, usize){ x, y, z }));
                    const current = switch (parent.encoding) {
                        .grid => parent.encoding.grid[pos_in_parent[0] + x][pos_in_parent[1] + y][pos_in_parent[2] + z],
                        .uniform => parent.encoding.uniform,
                    };
                    const desired = simplified[x][y][z];
                    if (current == desired) continue;
                    try self.placeBlock(desired, world_pos, parent_pos.level);
                    changed_parent = true;
                }
            }
        }
        return changed_parent;
    }

    fn mergeChunk(world: *World, io: std.Io, chunk_pos: ChunkPos, chunk: *Chunk, merge: Chunk.Encoding) ![6]bool {
        var grid_buffer: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = undefined;
        var sides_changed: [6]bool = @splat(false);

        const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "mergeChunk_lock_exclusive" });
        defer zone_lock.end();
        try chunk.lockExclusive(io);
        defer chunk.unlockExclusive(io);

        const track_face_changes = if (world.edit_callback) |cb| cb.on_neighbor_face_change else false;
        const old_sides = if (track_face_changes) chunk.encoding.extractAllFaces() else null;
        const was_grid = chunk.encoding == .grid;
        // A uniform chunk that merges into a grid borrows `grid_buffer`. Restore
        // this if no grid slot is free, or the chunk keeps a dead pointer.
        const old_encoding = chunk.encoding;

        chunk.encoding.merge(merge, &grid_buffer);

        if (was_grid and chunk.encoding != .grid) world.freeGrid(io, chunk_pos);
        if (!was_grid and chunk.encoding == .grid) {
            const grid_slot = blk: {
                const shard, const lock = world.chunks.getShardAndLock(chunk_pos);
                const zone_shard = tracy.Zone.begin(.{ .src = @src(), .name = "mergeChunk_lock_shard" });
                defer zone_shard.end();
                lock.lockUncancelable(io);
                defer lock.unlock(io);
                break :blk world.claimGrid(io, chunk, chunk_pos, shard) catch |err| {
                    chunk.encoding = old_encoding;
                    return err;
                };
            };
            fillGrid(chunk, grid_slot.?);
        }

        if (old_sides) |os| {
            inline for (std.enums.values(Chunk.Encoding.FaceRotation), os) |side, old| {
                const new = chunk.encoding.extractFace(side);
                sides_changed[@backingInt(side)] = !std.meta.eql(new, old);
            }
        }
        return sides_changed;
    }

    fn runEditCallback(
        callback: World.EditCallback,
        io: std.Io,
        allocator: std.mem.Allocator,
        chunk_pos: ChunkPos,
        err_store: *ErrorStore,
    ) std.Io.Cancelable!void {
        callback.function(io, allocator, chunk_pos, callback.context) catch |err| return storeTaskError(err_store, err);
    }

    fn editChunk(
        self: *const Editor,
        io: std.Io,
        allocator: std.mem.Allocator,
        chunk_pos: ChunkPos,
        encoding: Chunk.Encoding,
        sides_changed: *[6]bool,
        err_store: *ErrorStore,
    ) std.Io.Cancelable!void {
        const zone = tracy.Zone.begin(.{ .src = @src() });
        defer zone.end();

        const chunk = self.world.loadChunk(io, allocator, chunk_pos, false) catch |err| return storeTaskError(err_store, err);
        defer chunk.release();

        sides_changed.* = mergeChunk(self.world, io, chunk_pos, chunk, encoding) catch |err| return storeTaskError(err_store, err);
    }

    /// Propagates the edited chunks to their parents. Siblings that share one
    /// parent go in one group, so each parent merges and remeshes once.
    fn propagateEditedGroups(
        self: *const Editor,
        io: std.Io,
        allocator: std.mem.Allocator,
        group: *std.Io.Group,
        err_store: *ErrorStore,
    ) !void {
        var by_parent: std.AutoHashMap(ChunkPos, std.ArrayList(ChunkPos)) = .init(self.temp_allocator);
        defer {
            var vals = by_parent.valueIterator();
            while (vals.next()) |siblings| siblings.deinit(self.temp_allocator);
            by_parent.deinit();
        }
        var it = self.edit_buffer.iterator();
        while (it.next()) |entry| {
            const gop = try by_parent.getOrPut(entry.key_ptr.*.parent());
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.temp_allocator, entry.key_ptr.*);
        }

        // Distinct parents never touch the same chunk, so they propagate in parallel.
        var group_it = by_parent.iterator();
        while (group_it.next()) |entry| {
            group.async(io, propagateLodGroup, .{ self, io, allocator, entry.value_ptr.items, err_store });
        }
        try awaitTasks(group, io, err_store);
    }

    /// Climbs the LOD chain for one parent group, merging and flushing each
    /// level once. Stops when a level does not change its parent, or at
    /// max_propagate_level. It does not write to `siblings`.
    fn propagateLodGroup(
        self: *const Editor,
        io: std.Io,
        allocator: std.mem.Allocator,
        siblings: []const ChunkPos,
        err_store: *ErrorStore,
    ) std.Io.Cancelable!void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "propagate" });
        defer zone.end();

        var propagation_editor: Editor = .{
            .propagate_changes = false,
            .world = self.world,
            .temp_allocator = self.temp_allocator,
        };
        defer propagation_editor.clear();

        // All siblings share one parent, so the first level writes every
        // corner into a single editor and merges the parent exactly once.
        var current: []const ChunkPos = siblings;
        var parent_pos: ChunkPos = undefined;
        while (current[0].level < max_propagate_level) {
            var any_changed = false;
            for (current) |pos| {
                if (propagation_editor.propagateToParent(io, allocator, pos) catch |err| return storeTaskError(err_store, err)) any_changed = true;
            }
            // No child changed the parent, so the chain above it cannot change either.
            if (!any_changed) break;

            parent_pos = current[0].parent();
            propagation_editor.flush(io, allocator) catch |err| return storeTaskError(err_store, err);
            current = (&parent_pos)[0..1];
        }
    }
};

fn fetchChunk(self: *World, io: std.Io, chunk_pos: ChunkPos) !?*Chunk {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const shard, const lock = self.chunks.getShardAndLock(chunk_pos);
    const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "fetchChunk_lock_shard" });
    defer zone_lock.end();
    try lock.lock(io);
    defer lock.unlock(io);

    if (shard.get(chunk_pos)) |cv| {
        cv.chunk.addRef();
        return &cv.chunk;
    }
    return null;
}

fn canEvict(chunk: *Chunk, io: std.Io) bool {
    return chunk.ref_count.load(.seq_cst) == 1 and chunk.encoding_lock.tryLockShared(io);
}

fn putChunk(
    self: *World,
    io: std.Io,
    chunk: Chunk,
    chunk_pos: ChunkPos,
) !*Chunk {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    std.debug.assert(chunk.ref_count.raw == 2);

    const shard, const lock = self.chunks.getShardAndLock(chunk_pos);
    var skips: usize = 0;
    const chunk_ptr, const grid_slot = while (true) {
        const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "putChunk_lock_shard" });
        defer zone_lock.end();
        try lock.lock(io);
        defer lock.unlock(io);

        if (shard.get(chunk_pos)) |cv| {
            cv.chunk.addRef();
            return &cv.chunk;
        }

        if (shard.peekVictim(chunk_pos)) |victim| {
            if (!canEvict(&victim.chunk, io)) {
                if (skips >= max_victim_skips) return error.Unrecoverable;
                skips += 1;
                shard.skipVictim(chunk_pos);
                continue;
            }
            defer victim.chunk.encoding_lock.unlockShared(io);
            try self.save(io, &victim.chunk, victim.pos);
            if (victim.chunk.encoding == .grid) self.freeGrid(io, victim.pos);
        }

        _ = shard.upsert(&.{ .chunk = chunk, .pos = chunk_pos });
        const chunk_ptr = &shard.get(chunk_pos).?.chunk;
        chunk_ptr.encoding_lock.lockUncancelable(io);
        const grid_slot = self.claimGrid(io, chunk_ptr, chunk_pos, shard) catch |err| {
            chunk_ptr.encoding_lock.unlock(io);
            _ = shard.remove(chunk_pos);
            return err;
        };
        break .{ chunk_ptr, grid_slot };
    };
    defer chunk_ptr.encoding_lock.unlock(io);
    if (grid_slot) |slot| fillGrid(chunk_ptr, slot);
    return chunk_ptr;
}

fn freeGrid(self: *World, io: std.Io, chunk_pos: ChunkPos) void {
    _ = self.grids.remove(io, chunk_pos);
}

/// Copies the chunk's grid into its claimed slot. Runs outside the shard locks: the
/// caller's exclusive encoding lock already keeps the slot's chunk from eviction.
fn fillGrid(chunk_ptr: *Chunk, slot: *GridValue) void {
    slot.grid = chunk_ptr.encoding.grid.*;
    chunk_ptr.encoding.grid = &slot.grid;
}

/// Claims a grid-cache slot for a grid chunk, evicting a victim if needed, and
/// returns it for `fillGrid`. Returns null for a uniform chunk.
fn claimGrid(self: *World, io: std.Io, chunk_ptr: *Chunk, chunk_pos: ChunkPos, chunks_shard: anytype) error{Unrecoverable}!?*GridValue {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    comptime std.debug.assert(self.grids.shards.len == self.chunks.shards.len);

    if (chunk_ptr.encoding != .grid) return null;

    const grid_shard, const lock = self.grids.getShardAndLock(chunk_pos);
    const zone_lock = tracy.Zone.begin(.{ .src = @src(), .name = "claimGrid_lock_shard" });
    defer zone_lock.end();
    lock.lockUncancelable(io);
    defer lock.unlock(io);

    var skips: usize = 0;
    while (grid_shard.peekVictim(chunk_pos)) |victim| {
        std.debug.assert(victim.chunk != chunk_ptr);
        if (!canEvict(victim.chunk, io)) {
            if (skips >= max_victim_skips) return error.Unrecoverable;
            skips += 1;
            grid_shard.skipVictim(chunk_pos);
            continue;
        }
        // Release the encoding lock before `remove` poisons the owning value.
        {
            defer victim.chunk.encoding_lock.unlockShared(io);
            std.debug.assert(victim.chunk.encoding == .grid);
            // A failed save must abort the eviction: falling through would remove
            // the victim from `chunks` and overwrite its grids slot, losing it.
            try save(self, io, victim.chunk, victim.pos);
        }
        _ = chunks_shard.remove(victim.pos);
        break;
    }

    const slot = grid_shard.claim(chunk_pos);
    slot.chunk = chunk_ptr;
    slot.pos = chunk_pos;
    return slot;
}

fn getBlocks(
    self: *World,
    io: std.Io,
    allocator: std.mem.Allocator,
    chunk_pos: ChunkPos,
    grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block,
) error{ Unrecoverable, OutOfMemory, Canceled }!struct { Chunk.Encoding, ChunkSource.GetBlocksMetadata } {
    var encoding: Chunk.Encoding = .{ .uniform = .null };
    for (self.chunk_sources) |source| {
        if (source) |s| if (s.getBlocks) |get_blocks_fn| {
            if (try get_blocks_fn(s, io, allocator, self, &encoding, chunk_pos, grid_buffer)) |metadata| {
                return .{ encoding, metadata };
            }
        };
    }
    @panic("at least one ChunkSource must be able to generate a chunk");
}

fn runPlaceStructures(
    self: *World,
    io: std.Io,
    allocator: std.mem.Allocator,
    chunk: *Chunk,
    chunk_pos: ChunkPos,
) !void {
    for (self.chunk_sources) |source| {
        if (source) |s| if (s.placeStructures) |place_structures_fn| {
            try place_structures_fn(s, io, allocator, self, chunk, chunk_pos);
        };
    }
}

fn tryGenStructures(
    self: *World,
    io: std.Io,
    allocator: std.mem.Allocator,
    chunk: *Chunk,
    chunk_pos: ChunkPos,
) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    // Two loaders can both place structures. Set the flag only after placement, so no loader sees it early.
    if (chunk.structures_generated.load(.seq_cst)) return;
    try runPlaceStructures(self, io, allocator, chunk, chunk_pos);
    chunk.structures_generated.store(true, .seq_cst);
}

fn save(self: *World, io: std.Io, chunk: *Chunk, chunk_pos: ChunkPos) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    for (self.chunk_sources) |source| {
        if (source) |s| if (s.save) |save_fn| {
            try save_fn(s, io, self, chunk, chunk_pos);
        };
    }
}

inline fn readBlockFromEncoding(encoding: Chunk.Encoding, local_pos: @Vector(3, usize)) Block {
    return switch (encoding) {
        .grid => |g| g[local_pos[0]][local_pos[1]][local_pos[2]],
        .uniform => |b| b,
    };
}

test "ChunkPos" {
    const testing = std.testing;

    const pos1 = ChunkPos{ .level = 0, .position = .{ 1, 2, 3 } };
    try testing.expect(std.meta.eql(pos1.parent(), ChunkPos{ .level = 1, .position = .{ 0, 1, 1 } }));
    try testing.expectEqual(32, ChunkPos.levelToBlockRatio(0));
    try testing.expectEqual(64, ChunkPos.levelToBlockRatio(1));

    const pos2 = ChunkPos{ .level = 5, .position = .{ 32, 32, 32 } };
    try std.testing.expectEqual(BlockPos{ 32768, 32768, 32768 }, pos2.toGlobalBlockPos());

    const pos3 = ChunkPos.fromGlobalBlockPos(.{ 32, 64, 32 }, -5);
    try testing.expect(std.meta.eql(pos3, ChunkPos{ .level = -5, .position = .{ 32, 64, 32 } }));

    const neg6 = ChunkPos.fromGlobalBlockPos(.{ 64, 0, -1 }, -6);
    try testing.expect(std.meta.eql(neg6, ChunkPos{ .level = -6, .position = .{ 128, 0, -2 } }));
    const neg8 = ChunkPos.fromGlobalBlockPos(.{ 100, -7, 0 }, -8);
    try testing.expect(std.meta.eql(neg8, ChunkPos{ .level = -8, .position = .{ 800, -56, 0 } }));

    const pos4 = ChunkPos{ .level = 0, .position = .{ 1, 1, 1 } };
    const pos5 = pos4.toLevel(-5);
    try testing.expect(std.meta.eql(pos5, ChunkPos{ .level = -5, .position = .{ 32, 32, 32 } }));
}

pub fn makeTestingWorld(
    world: *World,
    generator: *DefaultGenerator,
    allocator: std.mem.Allocator,
    grids: usize,
    chunks: usize,
) !void {
    const gen = try DefaultGenerator.init(allocator, 1024 * 1024, .default, 0);
    errdefer {
        var g = gen;
        g.terrain_height_cache.deinit(allocator);
    }
    generator.* = gen;

    try initTestingCaches(world, allocator, grids, chunks);
    world.chunk_sources = .{ generator.getSource(), null, null, null };
}

/// Sets `world` to empty caches with room for at least `grids` grids and `chunks` chunks. The chunk sources stay undefined.
fn initTestingCaches(world: *World, allocator: std.mem.Allocator, grids: usize, chunks: usize) !void {
    var chunk_cache: ChunkMapType = try .init(allocator, testingCacheCount(chunks));
    errdefer chunk_cache.deinit(allocator);

    world.* = .{
        .chunks = chunk_cache,
        .grids = try .init(allocator, testingCacheCount(grids)),
        .config = .{},
        .chunk_sources = undefined,
    };
}

fn testingCacheCount(count: usize) usize {
    return @max(std.mem.alignForward(usize, count, 256), 256);
}

fn testLoadChunkAllocation(allocator: std.mem.Allocator, io: std.Io) !void {
    var world: World = undefined;
    var generator: DefaultGenerator = undefined;
    try makeTestingWorld(&world, &generator, allocator, 256, 256);
    defer world.deinit(io, allocator);

    (try world.loadChunk(io, allocator, .{ .position = .{ 0, 23, -4323 }, .level = 6 }, false)).release();
}

test "loadChunk allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testLoadChunkAllocation,
        .{std.Io.Threaded.global_single_threaded.io()},
    );
}

test "saveAll persists every modified chunk" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var world: World = undefined;
    var generator: DefaultGenerator = undefined;
    try makeTestingWorld(&world, &generator, allocator, 256, 256);
    defer world.deinit(io, allocator);

    var saves: u32 = 0;
    const saving_source: ChunkSource = .{
        .data = &saves,
        .getBlocks = null,
        .placeStructures = null,
        .getTerrainHeight = null,
        .deinit = null,
        .save = struct {
            fn save(source: ChunkSource, _: std.Io, _: *World, chunk: *Chunk, _: ChunkPos) error{Unrecoverable}!void {
                const count: *u32 = @ptrCast(@alignCast(source.data));
                count.* += 1;
                chunk.modified.store(false, .release);
            }
        }.save,
    };
    world.chunk_sources = .{ generator.getSource(), saving_source, null, null };

    const chunk = try world.loadChunk(io, allocator, .{ .position = .{ 0, 0, 0 }, .level = 0 }, false);
    defer chunk.release();
    chunk.modified.store(true, .seq_cst);

    try world.saveAll(io);
    try std.testing.expectEqual(@as(u32, 1), saves);
    try std.testing.expect(!chunk.modified.load(.seq_cst));
}
const FuzzGenerator = @import("generators/Fuzz.zig").FuzzGenerator;

test "fuzz world" {
    var world: World = undefined;
    var dba: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = dba.deinitLog(false);
    const allocator = dba.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    try initTestingCaches(&world, allocator, 1000, 1000);
    defer world.deinit(threaded.io(), allocator);
    try std.testing.fuzz(Context{ .io = threaded.io(), .allocator = allocator, .world = &world }, fuzzChunkLoad, .{});
}

const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    world: *World,
};

fn fuzzChunkLoad(context: Context, smith: *std.testing.Smith) !void {
    var generator: FuzzGenerator = try .init(smith);
    context.world.chunk_sources = .{ generator.getSource(), null, null, null };

    const test_chunk = try context.world.loadChunk(
        context.io,
        context.allocator,
        .{
            .level = smith.value(i32),
            .position = smith.value(@Vector(3, i32)),
        },
        smith.value(bool),
    );
    test_chunk.release();
}

test {
    std.testing.refAllDecls(@This());
}
