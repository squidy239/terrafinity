const std = @import("std");
const builtin = @import("builtin");

const tracy = @import("tracy");

const Options = @import("../Game.zig").Options;
const Cache = @import("../libs/Cache.zig").Cache;
pub const Block = @import("Block.zig").Block;
const Chunk = @import("Chunk.zig");
pub const ChunkSize = Chunk.ChunkSize;
pub const DefaultGenerator = @import("generators/Terrain.zig").DefaultGenerator;
pub const OldGenerator = @import("generators/Voxelgame.zig").Generator;
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
        return std.math.powi(i64, scale_factor, level - chunk_level) catch |err| switch (err) {
            error.Overflow => unreachable,
            error.Underflow => 1,
        };
    }

    pub inline fn levelToBlockRatioFloat(level: i32) f32 {
        return std.math.pow(f32, @floatFromInt(scale_factor), @floatFromInt(level - chunk_level));
    }

    pub inline fn levelToBlockRatioF64(level: i32) f64 {
        return std.math.pow(f64, @floatFromInt(scale_factor), @floatFromInt(level - chunk_level));
    }

    pub inline fn levelToLevelRatio(level1: i32, level2: i32) f64 {
        return std.math.pow(f64, @floatFromInt(scale_factor), @floatFromInt(level1 - level2));
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
        return @intCast(@mod(self.position, comptime @Vector(3, i32){ scale_factor, scale_factor, scale_factor }));
    }

    pub inline fn listChildren(self: ChunkPos) [scale_factor][scale_factor][scale_factor]ChunkPos {
        var children: [scale_factor][scale_factor][scale_factor]ChunkPos = undefined;
        inline for (0..scale_factor) |x| {
            inline for (0..scale_factor) |y| {
                inline for (0..scale_factor) |z| {
                    children[x][y][z] = self.toLevel(self.level - 1)
                        .add(comptime .{ @intCast(x), @intCast(y), @intCast(z) });
                }
            }
        }
        return children;
    }

    pub inline fn add(self: ChunkPos, delta: @Vector(3, i32)) ChunkPos {
        return .{ .position = self.position + delta, .level = self.level };
    }

    pub fn offset(self: ChunkPos, rotation: Chunk.Encoding.FaceRotation) ChunkPos {
        return .{ .level = self.level, .position = self.position + rotation.direction() };
    }

    pub inline fn toLevel(self: ChunkPos, level: i32) ChunkPos {
        const ratio_vec: @Vector(3, f64) = @splat(levelToLevelRatio(self.level, level));
        const pos_vec: @Vector(3, f64) = @floatFromInt(self.position);
        return .{ .position = @trunc(pos_vec * ratio_vec), .level = level };
    }

    pub inline fn toGlobalBlockPos(self: ChunkPos) BlockPos {
        return self.position * @as(@Vector(3, i64), @splat(levelToBlockRatio(self.level)));
    }

    pub inline fn toLocalBlockPos(self: ChunkPos) BlockPos {
        return self.position * @as(@Vector(3, i64), @splat(ChunkSize));
    }

    pub inline fn fromGlobalBlockPos(block_pos: BlockPos, level: i32) ChunkPos {
        return .{
            .position = @intCast(@divFloor(block_pos, @as(@Vector(3, i64), @splat(levelToBlockRatio(level))))),
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

pub const WorldConfig = struct {
    spawn_center_pos: @Vector(3, f64) = .{ 0, 0, 0 },
    spawn_range: u32 = 0,
};

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

    /// May be called on the same chunk multiple times and must result in the same state each time
    placeStructures: ?*const fn (
        self: ChunkSource,
        io: std.Io,
        allocator: std.mem.Allocator,
        world: *World,
        chunk: *Chunk,
        chunk_pos: ChunkPos,
    ) error{ OutOfMemory, Canceled, Unrecoverable }!void,

    /// Idempotent, caller must hold at least a shared lock on the chunk
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

    pub inline fn key_from_value(value: *const ChunkValue) ChunkPos {
        return value.pos;
    }
};

pub const GridValue = struct {
    grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment),
    chunk: *Chunk,
    pos: ChunkPos,

    pub inline fn key_from_value(value: *const GridValue) ChunkPos {
        return value.pos;
    }
};

inline fn chunkPosHash(item: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, item);
    return hasher.final();
}

const ChunkMapType = Cache(
    ChunkPos,
    ChunkValue,
    ChunkValue.key_from_value,
    chunkPosHash,
    .{},
    if (builtin.is_test) 1 else 32,
);

chunks: ChunkMapType,
grids: Cache(ChunkPos, GridValue, GridValue.key_from_value, chunkPosHash, .{}, if (builtin.is_test) 1 else 32),
config: WorldConfig,
chunk_sources: [4]?ChunkSource,
edit_callback: ?EditCallback = null,

pub fn deinit(self: *World, io: std.Io, allocator: std.mem.Allocator) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const last_prot = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(last_prot);

    self.saveAll(io);
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
        .saved = .init(metadata.from_disk),
        .structures_generated = .init(metadata.structures),
        .ref_count = .init(2),
    };

    const result = try self.putChunk(io, new_chunk, chunk_pos);
    const chunk = switch (result) {
        .existing => |existing| existing,
        .inserted => |inserted| inserted,
    };

    if (structures) try self.tryGenStructures(io, allocator, chunk, chunk_pos);
    return chunk;
}

pub fn saveAll(self: *World, io: std.Io) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);

    for (&self.chunks.shards, &self.chunks.shard_locks) |*shard, *lock| {
        group.async(io, saveShard, .{ self, shard, lock, io });
    }
    group.await(io) catch unreachable;
}

pub fn trySaveAll(self: *World, io: std.Io) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    for (&self.chunks.shards, &self.chunks.shard_locks) |*shard, *lock| {
        group.async(io, trySaveShard, .{ self, shard, lock, io });
    }
    try group.await(io);
}

pub fn saveShard(self: *World, shard: *ChunkMapType.Shard, lock: *std.Io.Mutex, io: std.Io) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    lock.lockUncancelable(io);
    defer lock.unlock(io);

    var it = shard.iterator();
    while (it.next()) |c| {
        c.chunk.encoding_lock.lockSharedUncancelable(io);
        defer c.chunk.encoding_lock.unlockShared(io);
        self.save(io, &c.chunk, c.key_from_value()) catch |err|
            std.log.err("error saving chunk: {any}, {any}\n", .{ c.key_from_value(), err });
    }
}

pub const Reader = struct {
    world: *World,
    last_chunk_read_cache: ?struct { chunk_pos: ChunkPos, chunk: *Chunk } = null,

    pub fn getBlock(self: *Reader, io: std.Io, allocator: std.mem.Allocator, block_pos: BlockPos, level: i32) !Block {
        const chunk_pos: ChunkPos = .fromLocalBlockPos(block_pos, level);
        const local_pos: @Vector(3, usize) = @intCast(@mod(block_pos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));

        if (self.last_chunk_read_cache == null or !std.meta.eql(self.last_chunk_read_cache.?.chunk_pos, chunk_pos)) {
            self.clear(io);
            const chunk = try self.world.loadChunk(io, allocator, chunk_pos, false);
            try chunk.lockShared(io);
            self.last_chunk_read_cache = .{ .chunk_pos = chunk_pos, .chunk = chunk };
        }

        return readBlockFromEncoding(self.last_chunk_read_cache.?.chunk.encoding, local_pos);
    }

    pub fn getBlockUncached(self: *Reader, io: std.Io, allocator: std.mem.Allocator, block_pos: BlockPos, level: i32) !Block {
        const chunk_pos: ChunkPos = .fromLocalBlockPos(block_pos, level);
        const local_pos: @Vector(3, usize) = @intCast(@mod(block_pos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));

        const chunk = try self.world.loadChunk(io, allocator, chunk_pos, false);
        chunk.lockShared(io);
        defer chunk.releaseAndUnlockShared(io);

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
    pub const Geometry = @import("structures/Geometry.zig");
    pub const Tree = @import("structures/Tree.zig").Tree;
    pub const TexturedSphere = @import("structures/TexturedSphere.zig");

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

    const EditErrorStruct = packed struct(u32) {
        exists: bool = false,
        err: @Int(.unsigned, @bitSizeOf(anyerror)) = undefined,
        _: @Int(.unsigned, 32 - @bitSizeOf(anyerror) - 1) = undefined,
    };

    pub inline fn placeBlock(self: *Editor, block: Block, pos: @Vector(3, i64), level: i32) !void {
        const chunk_pos: ChunkPos = .fromLocalBlockPos(pos, level);
        const local_pos: @Vector(3, usize) = @intCast(@mod(pos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));

        if (self.last_chunk_cache == null or !std.meta.eql(self.last_chunk_cache.?.chunk_pos, chunk_pos)) {
            const entry = try self.edit_buffer.getOrPut(self.temp_allocator, chunk_pos);
            if (!entry.found_existing) {
                const ptr: *[ChunkSize * ChunkSize][ChunkSize]Block = @ptrCast(entry.value_ptr);
                for (ptr) |*row| row.* = @splat(.null);
            }
            self.last_chunk_cache = .{ .chunk_pos = chunk_pos, .grid = &entry.value_ptr.grid };
        }
        self.last_chunk_cache.?.grid[local_pos[0]][local_pos[1]][local_pos[2]] = block;
    }

    pub fn placeSamplerShape(self: *Editor, block: Block, shape: anytype, level: i32) !void {
        const zone: tracy.Zone = .begin(.{ .src = @src() });
        defer zone.end();

        const bb = shape.boundingBox;
        var y = bb[2];
        while (y <= bb[3]) : (y += 1) {
            var dx = bb[0];
            while (dx <= bb[1]) : (dx += 1) {
                var dz = bb[4];
                while (dz <= bb[5]) : (dz += 1) {
                    if (shape.isPointInside(.{ dx, y, dz })) {
                        const world_pos: @Vector(3, i64) = switch (comptime @typeInfo(@TypeOf(bb[0]))) {
                            .float => .{ @trunc(dx), @trunc(y), @trunc(dz) },
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

        self.edit_buffer.lockPointers();
        defer self.edit_buffer.unlockPointers();

        var remesh_neighbors: std.AutoHashMap(ChunkPos, void) = .init(self.temp_allocator);
        defer remesh_neighbors.deinit();
        var remesh_mutex: std.Io.Mutex = .init;

        var group: std.Io.Group = .init;
        defer group.cancel(io);

        var err_store: std.atomic.Value(EditErrorStruct) = .init(.{});

        var it = self.edit_buffer.iterator();
        while (it.next()) |diff_chunk| {
            const chunk_pos = diff_chunk.key_ptr.*;
            const encoding: Chunk.Encoding = .fromBlocks(&diff_chunk.value_ptr.grid);
            group.async(io, editChunk, .{ self, io, allocator, chunk_pos, encoding, &remesh_neighbors, &remesh_mutex, &err_store });
        }
        try group.await(io);
        if (err_store.raw.exists) return @errorFromInt(err_store.raw.err);

        it.index = 0;
        while (it.next()) |pos| {
            if (self.world.edit_callback) |cb| group.async(io, runEditCallback, .{ cb, io, allocator, pos.key_ptr.*, &err_store });
        }
        var rit = remesh_neighbors.iterator();
        while (rit.next()) |pos| {
            if (self.world.edit_callback) |cb| group.async(io, runEditCallback, .{ cb, io, allocator, pos.key_ptr.*, &err_store });
        }
        try group.await(io);
        if (err_store.raw.exists) return @errorFromInt(err_store.raw.err);
    }

    pub fn clear(self: *Editor) void {
        self.last_chunk_cache = null;
        self.edit_buffer.clearAndFree(self.temp_allocator);
    }

    pub fn propagateToParent(
        self: *Editor,
        io: std.Io,
        allocator: std.mem.Allocator,
        chunk: *Chunk,
        chunk_pos: ChunkPos,
    ) !bool {
        const zone = tracy.Zone.begin(.{ .src = @src() });
        defer zone.end();

        const parent_pos = chunk_pos.parent();
        const simplified_size = ChunkSize / scale_factor;

        var simplified: [simplified_size][simplified_size][simplified_size]Block = undefined;
        var is_uniform = false;

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

        if (is_uniform and parent.encoding == .uniform and
            parent.encoding.uniform == simplified[0][0][0]) return false;

        var changed_parent = false;
        for (0..simplified_size) |x| {
            for (0..simplified_size) |y| {
                for (0..simplified_size) |z| {
                    const world_pos = @Vector(3, i64){
                        block_pos[0] + @as(i64, @intCast(x)),
                        block_pos[1] + @as(i64, @intCast(y)),
                        block_pos[2] + @as(i64, @intCast(z)),
                    };
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

    pub fn propagateToParentByCoords(
        self: *Editor,
        io: std.Io,
        allocator: std.mem.Allocator,
        chunk_pos: ChunkPos,
    ) !bool {
        const chunk = try self.world.loadChunk(io, allocator, chunk_pos, false);
        defer chunk.release();
        return self.propagateToParent(io, allocator, chunk, chunk_pos);
    }

    pub fn mergeChunk(world: *World, io: std.Io, chunk_pos: ChunkPos, chunk: *Chunk, merge: Chunk.Encoding) ![6]bool {
        var grid_buffer: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = undefined;
        var sides_changed: [6]bool = @splat(false);

        try chunk.lockExclusive(io);
        defer chunk.unlockExclusive(io);

        const track_face_changes = if (world.edit_callback) |cb| cb.on_neighbor_face_change else false;
        const old_sides = if (track_face_changes) chunk.encoding.extractAllFaces() else null;
        const was_grid = chunk.encoding == .grid;

        chunk.encoding.merge(merge, &grid_buffer);

        if (was_grid and chunk.encoding != .grid) world.freeGrid(io, chunk_pos);
        if (!was_grid and chunk.encoding == .grid) {
            const shard, const lock = world.chunks.getShardAndLock(chunk_pos);
            lock.lockUncancelable(io);
            defer lock.unlock(io);
            world.ownGrid(io, chunk, chunk_pos, shard);
        }

        if (old_sides) |os| {
            inline for (std.enums.values(Chunk.Encoding.FaceRotation), os) |side, old| {
                const new = chunk.encoding.extractFace(side);
                sides_changed[@intFromEnum(side)] = !std.meta.eql(new, old);
            }
        }
        return sides_changed;
    }

    fn runEditCallback(
        callback: World.EditCallback,
        io: std.Io,
        allocator: std.mem.Allocator,
        chunk_pos: ChunkPos,
        err_store: *std.atomic.Value(EditErrorStruct),
    ) std.Io.Cancelable!void {
        callback.function(io, allocator, chunk_pos, callback.context) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => |e| err_store.store(.{ .exists = true, .err = @intFromError(e) }, .seq_cst),
        };
    }

    fn editChunk(
        self: *const Editor,
        io: std.Io,
        allocator: std.mem.Allocator,
        chunk_pos: ChunkPos,
        encoding: Chunk.Encoding,
        remesh_neighbors: *std.AutoHashMap(ChunkPos, void),
        remesh_mutex: *std.Io.Mutex,
        err_store: *std.atomic.Value(EditErrorStruct),
    ) std.Io.Cancelable!void {
        const zone = tracy.Zone.begin(.{ .src = @src() });
        defer zone.end();

        const chunk = self.world.loadChunk(io, allocator, chunk_pos, false) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return err_store.store(.{ .exists = true, .err = @intFromError(err) }, .seq_cst),
        };
        defer chunk.release();

        const sides_changed = try mergeChunk(self.world, io, chunk_pos, chunk, encoding);

        for (sides_changed, std.enums.values(Chunk.Encoding.FaceRotation)) |changed, rotation| {
            if (!changed) continue;
            const neighbor_pos: ChunkPos = .{ .level = chunk_pos.level, .position = chunk_pos.position + rotation.direction() };
            try remesh_mutex.lock(io);
            defer remesh_mutex.unlock(io);
            remesh_neighbors.put(neighbor_pos, {}) catch |err|
                return err_store.store(.{ .exists = true, .err = @intFromError(err) }, .seq_cst);
        }

        if (self.propagate_changes) {
            try self.propagateLod(io, allocator, chunk_pos, err_store);
        }
    }

    fn propagateLod(
        self: *const Editor,
        io: std.Io,
        allocator: std.mem.Allocator,
        start_pos: ChunkPos,
        err_store: *std.atomic.Value(EditErrorStruct),
    ) std.Io.Cancelable!void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "propagate" });
        defer zone.end();

        var propagation_editor: Editor = .{
            .propagate_changes = false,
            .world = self.world,
            .temp_allocator = self.temp_allocator,
        };
        defer propagation_editor.clear();

        var coords = start_pos;
        for (0..16) |_| {
            const changed = propagation_editor.propagateToParentByCoords(io, allocator, coords) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return err_store.store(.{ .exists = true, .err = @intFromError(err) }, .seq_cst),
            };
            if (!changed) break;

            coords = coords.parent();
            propagation_editor.flush(io, allocator) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return err_store.store(.{ .exists = true, .err = @intFromError(err) }, .seq_cst),
            };
        }
    }
};

fn fetchChunk(self: *World, io: std.Io, chunk_pos: ChunkPos) !?*Chunk {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    const shard, const lock = self.chunks.getShardAndLock(chunk_pos);
    try lock.lock(io);
    defer lock.unlock(io);

    if (shard.get(chunk_pos)) |cv| {
        cv.chunk.addRef();
        return &cv.chunk;
    }
    return null;
}

fn putChunk(
    self: *World,
    io: std.Io,
    chunk: Chunk,
    chunk_pos: ChunkPos,
) !union(enum) { existing: *Chunk, inserted: *Chunk } {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    std.debug.assert(chunk.ref_count.raw == 2);

    const shard, const lock = self.chunks.getShardAndLock(chunk_pos);
    while (true) {
        try lock.lock(io);
        defer lock.unlock(io);

        if (shard.get(chunk_pos)) |cv| {
            cv.chunk.addRef();
            return .{ .existing = &cv.chunk };
        }

        if (shard.peek_victim(chunk_pos)) |victim| {
            if (victim.chunk.ref_count.load(.seq_cst) != 1) {
                shard.skip_victim(chunk_pos);
                continue;
            }
            std.debug.assert(victim.chunk.encoding_lock.tryLockShared(io));
            victim.chunk.encoding_lock.unlockShared(io);
            try self.save(io, &victim.chunk, victim.pos);
            if (victim.chunk.encoding == .grid) self.freeGrid(io, victim.pos);
            victim.* = undefined;
        }

        _ = shard.upsert(&.{ .chunk = chunk, .pos = chunk_pos });
        const chunk_ptr = &shard.get(chunk_pos).?.chunk;
        chunk_ptr.encoding_lock.lockUncancelable(io);
        self.ownGrid(io, chunk_ptr, chunk_pos, shard);
        chunk_ptr.encoding_lock.unlock(io);
        return .{ .inserted = chunk_ptr };
    }
}

fn freeGrid(self: *World, io: std.Io, chunk_pos: ChunkPos) void {
    _ = self.grids.remove(io, chunk_pos);
}

fn ownGrid(self: *World, io: std.Io, chunk_ptr: *Chunk, chunk_pos: ChunkPos, chunks_shard: anytype) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    comptime std.debug.assert(self.grids.shards.len == self.chunks.shards.len);

    if (chunk_ptr.encoding != .grid) return;

    const grid_shard, const lock = self.grids.getShardAndLock(chunk_pos);
    lock.lockUncancelable(io);
    defer lock.unlock(io);

    while (grid_shard.peek_victim(chunk_pos)) |victim| {
        std.debug.assert(victim.chunk != chunk_ptr);
        if (victim.chunk.ref_count.load(.seq_cst) != 1) {
            grid_shard.skip_victim(chunk_pos);
            continue;
        }
        std.debug.assert(victim.chunk.encoding_lock.tryLockShared(io));
        victim.chunk.encoding_lock.unlockShared(io);
        std.debug.assert(victim.chunk.encoding == .grid);
        save(self, io, victim.chunk, victim.pos) catch |err|
            std.log.err("Failed to save chunk: {}", .{err});
        victim.chunk.* = undefined;
        _ = chunks_shard.remove(victim.pos);
        break;
    }

    _ = grid_shard.upsert(&GridValue{ .chunk = chunk_ptr, .grid = chunk_ptr.encoding.grid.*, .pos = chunk_pos });
    chunk_ptr.encoding.grid = &grid_shard.get(chunk_pos).?.grid;
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
        if (source) |s| {
            if (s.getBlocks) |getBlocksFn| {
                if (try getBlocksFn(s, io, allocator, self, &encoding, chunk_pos, grid_buffer)) |metadata| {
                    return .{ encoding, metadata };
                }
            }
        }
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
        if (source) |s| {
            if (s.placeStructures) |placeStructuresFn| {
                try placeStructuresFn(s, io, allocator, self, chunk, chunk_pos);
            }
        }
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

    if (!chunk.structures_generated.load(.seq_cst)) {
        try runPlaceStructures(self, io, allocator, chunk, chunk_pos);
        chunk.structures_generated.store(true, .seq_cst);
    }
}

fn save(self: *World, io: std.Io, chunk: *Chunk, chunk_pos: ChunkPos) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    for (self.chunk_sources) |source| {
        if (source) |s| {
            if (s.save) |saveFn| {
                try saveFn(s, io, self, chunk, chunk_pos);
            }
        }
    }
}

fn trySaveShard(self: *World, shard: *ChunkMapType.Shard, lock: *std.Io.Mutex, io: std.Io) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    if (!lock.tryLock()) return;
    defer lock.unlock(io);

    var it = shard.iterator();
    while (it.next()) |c| {
        if (!c.chunk.encoding_lock.tryLockShared(io)) continue;
        defer c.chunk.encoding_lock.unlockShared(io);
        self.save(io, &c.chunk, c.key_from_value()) catch |err|
            std.log.err("error saving chunk: {any}, {any}\n", .{ c.key_from_value(), err });
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

    const pos4 = ChunkPos{ .level = 0, .position = .{ 1, 1, 1 } };
    const pos5 = pos4.toLevel(-5);
    try testing.expect(std.meta.eql(pos5, ChunkPos{ .level = -5, .position = .{ 32, 32, 32 } }));
}

test "cube benchmark" {
    const allocator = std.heap.smp_allocator;
    const io = std.testing.io;

    var generator = try DefaultGenerator.init(allocator, 1024 * 1024, .default);
    errdefer generator.terrain_height_cache.deinit(allocator);
    generator.params.setSeeds(io);

    const chunk_cache = try Cache(ChunkPos, ChunkValue, ChunkValue.key_from_value, chunkPosHash, .{}, 1).init(
        allocator,
        131072,
        .{ .name = "benchmark chunk cache" },
    );
    errdefer {
        var c = chunk_cache;
        c.deinit(allocator);
    }

    const grid_cache = try Cache(ChunkPos, GridValue, GridValue.key_from_value, chunkPosHash, .{}, 1).init(
        allocator,
        8192,
        .{ .name = "benchmark grid cache" },
    );
    errdefer {
        var g = grid_cache;
        g.deinit(allocator);
    }

    var world: World = .{
        .chunks = chunk_cache,
        .grids = grid_cache,
        .edit_callback = null,
        .chunk_sources = .{ generator.getSource(), null, null, null },
        .config = .{ .spawn_center_pos = .{ 0, 0, 0 }, .spawn_range = 0 },
    };
    defer world.deinit(io, allocator);

    var counter: std.atomic.Value(usize) = .init(0);
    const start_time: std.Io.Timestamp = .now(io, .awake);
    const levels: [2]i32 = .{ 0, 4 };
    const square = 4;

    var group: std.Io.Group = .init;
    var level: i32 = levels[0];
    while (level < levels[1]) : (level += 1) {
        for (0..square) |x| {
            for (0..square) |y| {
                for (0..square) |z| {
                    const pos = ChunkPos{
                        .position = .{
                            @as(i32, @intCast(x)) - square / 2,
                            @as(i32, @intCast(y)) - square / 2,
                            @as(i32, @intCast(z)) - square / 2,
                        },
                        .level = @intCast(level),
                    };
                    group.async(io, loadChunkTest, .{ &world, io, allocator, pos, true, &counter });
                }
            }
        }
    }
    try group.await(io);

    std.testing.log_level = .debug;
    const elapsed_s = @as(f32, @floatFromInt(start_time.untilNow(io, .awake).nanoseconds)) / std.time.ns_per_s;
    std.log.info("loaded at {d} chunks per second\n", .{@as(f32, @floatFromInt(counter.load(.seq_cst))) / elapsed_s});
}

fn loadChunkTest(
    self: *World,
    io: std.Io,
    allocator: std.mem.Allocator,
    chunk_pos: ChunkPos,
    structures: bool,
    counter: *std.atomic.Value(usize),
) void {
    const test_chunk = self.loadChunk(io, allocator, chunk_pos, structures) catch |err|
        std.debug.panic("err: {any}\n", .{err});
    test_chunk.release();
    _ = counter.fetchAdd(1, .seq_cst);
}

fn makeTestingWorld(
    world: *World,
    generator: *DefaultGenerator,
    allocator: std.mem.Allocator,
    grids: usize,
    chunks: usize,
) !void {
    const gen = try DefaultGenerator.init(allocator, 1024 * 1024, .default);
    errdefer {
        var g = gen;
        g.terrain_height_cache.deinit(allocator);
    }
    generator.* = gen;
    generator.params.seed = 0;

    const chunk_count = @max(std.mem.alignForward(usize, chunks, 256), 256);
    const grid_count = @max(std.mem.alignForward(usize, grids, 256), 256);

    const chunk_cache = try Cache(ChunkPos, ChunkValue, ChunkValue.key_from_value, chunkPosHash, .{}, 1).init(
        allocator,
        chunk_count,
        .{ .name = "test chunk cache" },
    );
    errdefer {
        var c = chunk_cache;
        c.deinit(allocator);
    }

    const grid_cache = try Cache(ChunkPos, GridValue, GridValue.key_from_value, chunkPosHash, .{}, 1).init(
        allocator,
        grid_count,
        .{ .name = "test grid cache" },
    );
    errdefer {
        var g = grid_cache;
        g.deinit(allocator);
    }

    world.* = .{
        .chunks = chunk_cache,
        .grids = grid_cache,
        .config = .{ .spawn_center_pos = .{ 0, 0, 0 }, .spawn_range = 0 },
        .chunk_sources = .{ generator.getSource(), null, null, null },
    };
}

fn testLoadChunkAllocation(allocator: std.mem.Allocator, io: std.Io) !void {
    var world: World = undefined;
    var generator: DefaultGenerator = undefined;
    try makeTestingWorld(&world, &generator, allocator, 256, 256);
    defer world.deinit(io, allocator);

    (try world.loadChunk(io, allocator, .{ .position = .{ 0, 432, 76564678 }, .level = -1 }, false)).release();
    (try world.loadChunk(io, allocator, .{ .position = .{ 0, 0, 0 }, .level = 0 }, false)).release();
    (try world.loadChunk(io, allocator, .{ .position = .{ 0, 432, 0 }, .level = 1 }, false)).release();
    (try world.loadChunk(io, allocator, .{ .position = .{ 970, 0, -655 }, .level = 2 }, false)).release();
    (try world.loadChunk(io, allocator, .{ .position = .{ 432234, 0, 0 }, .level = 3 }, false)).release();
    (try world.loadChunk(io, allocator, .{ .position = .{ 0, 54, 0 }, .level = 4 }, false)).release();
    (try world.loadChunk(io, allocator, .{ .position = .{ 54, 0, 54 }, .level = 5 }, false)).release();
    (try world.loadChunk(io, allocator, .{ .position = .{ 0, 23, -4323 }, .level = 6 }, false)).release();
}

test "loadChunk allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testLoadChunkAllocation,
        .{std.Io.Threaded.global_single_threaded.io()},
    );
}

test "fuzz world" {
    var world: World = undefined;
    var generator: DefaultGenerator = undefined;
    try makeTestingWorld(&world, &generator, std.testing.allocator, 1000, 100);
    defer world.deinit(std.testing.io, std.testing.allocator);
    try std.testing.fuzz(&world, fuzzChunkLoad, .{});
}

fn fuzzChunkLoad(world: *World, smith: *std.testing.Smith) !void {
    const test_chunk = try world.loadChunk(
        std.testing.io,
        std.testing.allocator,
        .{
            .level = smith.valueRangeAtMost(i32, -2, 12),
            .position = @mod(smith.value(@Vector(3, i32)), @Vector(3, i32){ 1000, 1000, 1000 }),
        },
        smith.value(bool),
    );
    test_chunk.release();
}

test {
    std.testing.refAllDecls(@This());
}
