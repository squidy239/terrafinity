const std = @import("std");

const tracy = @import("tracy");

const Options = @import("../Game.zig").Options;
const Cache = @import("../libs/Cache.zig").Cache;
pub const Block = @import("Block.zig").Block;
const Chunk = @import("Chunk.zig");
pub const ChunkSize = Chunk.ChunkSize;
pub const DefaultGenerator = @import("generators/Terrain.zig").DefaultGenerator;
pub const WorldStorage = @import("WorldStorage.zig");

const World = @This();

pub const ChunkValue = struct {
    chunk: Chunk,
    pos: ChunkPos,

    pub inline fn key_from_value(value: *const ChunkValue) ChunkPos {
        return value.pos;
    }
};

pub const GridValue = struct {
    grid: [ChunkSize][ChunkSize][ChunkSize]Block,
    chunk: *Chunk,
    pos: ChunkPos,

    pub inline fn key_from_value(value: *const GridValue) ChunkPos {
        return value.pos;
    }
};

inline fn hash(item: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, item);
    return hasher.final();
}
const ChunkMapType = Cache(ChunkPos, ChunkValue, ChunkValue.key_from_value, hash, .{}, 32);

grids: Cache(ChunkPos, GridValue, GridValue.key_from_value, hash, .{}, 32),
chunks: ChunkMapType,
config: WorldConfig,

chunk_sources: [4]?ChunkSource,

edit_callback: ?EditCallback = null,

pub const EditCallback = struct {
    function: *const fn (io: std.Io, allocator: std.mem.Allocator, chunkPos: ChunkPos, args: *anyopaque) error{ Canceled, OnEditFailed }!void,
    on_neghbor_face_change: bool,
    context: *anyopaque,
};

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

    pub inline fn parent(self: ChunkPos) ChunkPos {
        return .{ .level = self.level + 1, .position = @divFloor(self.position, @as(@Vector(3, i32), @splat(scale_factor))) };
    }

    pub inline fn levelToLevelRatio(level1: i32, level2: i32) f64 {
        return std.math.pow(f64, @floatFromInt(scale_factor), @floatFromInt(level1 - level2));
    }

    pub inline fn toScale(level: i32) f32 {
        return levelToBlockRatioFloat(level) / ChunkSize;
    }

    pub inline fn listChildren(self: ChunkPos) [scale_factor][scale_factor][scale_factor]ChunkPos {
        var children: [scale_factor][scale_factor][scale_factor]ChunkPos = undefined;
        inline for (0..scale_factor) |x| {
            inline for (0..scale_factor) |y| {
                inline for (0..scale_factor) |z| {
                    children[x][y][z] = self.toLevel(self.level - 1).add(comptime .{ @intCast(x), @intCast(y), @intCast(z) });
                }
            }
        }
        return children;
    }

    pub inline fn toGlobalBlockPos(self: ChunkPos) BlockPos {
        return self.position * @as(@Vector(3, i64), @splat(levelToBlockRatio(self.level)));
    }

    pub inline fn posInParent(self: ChunkPos) @Vector(3, @Int(.unsigned, std.math.log2(scale_factor))) {
        return @intCast(@mod(self.position, comptime @Vector(3, i32){ scale_factor, scale_factor, scale_factor }));
    }

    pub inline fn toLocalBlockPos(self: ChunkPos) BlockPos {
        return self.position * @as(@Vector(3, i64), @splat(ChunkSize));
    }

    pub inline fn toLevel(self: ChunkPos, level: i32) ChunkPos {
        const ratiovec: @Vector(3, f64) = @splat(levelToLevelRatio(self.level, level));
        const posvec: @Vector(3, f64) = @floatFromInt(self.position);
        return .{ .position = @trunc(posvec * ratiovec), .level = level };
    }

    pub inline fn fromGlobalBlockPos(blockPos: BlockPos, level: i32) ChunkPos {
        return .{ .position = @intCast(@divFloor(blockPos, @as(@Vector(3, i64), @splat(levelToBlockRatio(level))))), .level = level };
    }

    pub inline fn fromLocalBlockPos(blockPos: BlockPos, level: i32) ChunkPos {
        return .{ .position = @intCast(@divFloor(blockPos, @as(@Vector(3, i64), @splat(ChunkSize)))), .level = level };
    }

    pub inline fn add(self: ChunkPos, pos: @Vector(3, i32)) ChunkPos {
        return .{ .position = self.position + pos, .level = self.level };
    }
};

pub const WorldConfig = struct {
    SpawnCenterPos: @Vector(3, f64) = .{ 0, 0, 0 },
    SpawnRange: u32 = 0,
};

pub const ChunkSource = struct {
    pub const GetBlocksMetadata = struct {
        from_disk: bool,
        structures: bool,
    };

    data: *anyopaque,

    getBlocks: ?*const fn (self: ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, blocks: *Chunk.Encoding, chunk_pos: ChunkPos, grid_buffer: *[ChunkSize][ChunkSize][ChunkSize]Block) error{ Unrecoverable, OutOfMemory, Canceled }!?GetBlocksMetadata,

    /// May be called on the same chunk multiple times and must result in the same state each time
    placeStructures: ?*const fn (self: ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, chunk: *Chunk, chunk_pos: ChunkPos) error{ OutOfMemory, Canceled, Unrecoverable }!void,

    /// Idempotent, caller must hold at least a shared lock on the chunk
    save: ?*const fn (self: ChunkSource, io: std.Io, world: *World, chunk: *Chunk, chunk_pos: ChunkPos) error{Unrecoverable}!void,

    getTerrainHeight: ?*const fn (self: ChunkSource, world: *World, chunk_pos: @Vector(2, i32), level: i32) error{ OutOfMemory, Unrecoverable }![ChunkSize][ChunkSize]i32,

    deinit: ?*const fn (self: ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World) void,
};

fn fetchChunk(self: *@This(), io: std.Io, chunk_pos: ChunkPos) !?*Chunk {
    const z = tracy.Zone.begin(.{ .src = @src() });
    defer z.end();
    const shard, const lock = self.chunks.getShardAndLock(chunk_pos);
    try lock.lock(io);
    defer lock.unlock(io);
    const chunk = shard.get(chunk_pos);
    if (chunk) |ch| {
        ch.chunk.addRef();
        return &ch.chunk;
    }
    return null;
}

fn putChunk(self: *@This(), io: std.Io, chunk: Chunk, chunk_pos: ChunkPos) !union(enum) { existing: *Chunk, inserted: *Chunk } {
    const z = tracy.Zone.begin(.{ .src = @src() });
    defer z.end();
    std.debug.assert(chunk.ref_count.raw == 2);
    const shard, const lock = self.chunks.getShardAndLock(chunk_pos);
    while (true) {
        try lock.lock(io);
        defer lock.unlock(io);
        if (shard.get(chunk_pos)) |ch| {
            ch.chunk.addRef();
            return .{ .existing = &ch.chunk };
        }
        if (shard.peek_victim(chunk_pos)) |victim| {
            if (victim.chunk.ref_count.load(.seq_cst) != 1) {
                shard.skip_victim(chunk_pos);
                continue;
            }
            std.debug.assert(victim.chunk.encoding_lock.tryLockShared(io)); // This chunk cannot be used by another thread since it has 1 ref
            victim.chunk.encoding_lock.unlockShared(io);
            try self.save(io, &victim.chunk, victim.pos);
            if (victim.chunk.encoding == .grid) self.freeGrid(io, victim.pos);
            victim.* = undefined;
        }
        _ = shard.upsert(&.{
            .chunk = chunk,
            .pos = chunk_pos,
        });
        const chunkptr = &shard.get(chunk_pos).?.chunk;
        chunkptr.encoding_lock.lockUncancelable(io);
        self.ownGrid(io, chunkptr, chunk_pos, shard);
        chunkptr.encoding_lock.unlock(io);
        return .{ .inserted = chunkptr };
    }
}

fn freeGrid(self: *@This(), io: std.Io, chunk_pos: ChunkPos) void {
    _ = self.grids.remove(io, chunk_pos);
}

/// Caller must hold a write lock on the chunk
fn ownGrid(self: *@This(), io: std.Io, chunk_ptr: *Chunk, chunk_pos: ChunkPos, chunks_shard: anytype) void {
    const z = tracy.Zone.begin(.{ .src = @src() });
    defer z.end();
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
        std.debug.assert(victim.chunk.encoding_lock.tryLockShared(io)); // This chunk cannot be used by another thread since it has 1 ref
        victim.chunk.encoding_lock.unlockShared(io);

        std.debug.assert(victim.chunk.encoding == .grid);
        save(self, io, victim.chunk, victim.pos) catch |err| std.log.err("Failed to save chunk: {}", .{err}); //TODO make this stop close the world
        victim.chunk.* = undefined;
        _ = chunks_shard.remove(victim.pos);
        break;
    }
    _ = grid_shard.upsert(&GridValue{ .chunk = chunk_ptr, .grid = chunk_ptr.encoding.grid.*, .pos = chunk_pos });

    chunk_ptr.encoding.grid = &grid_shard.get(chunk_pos).?.grid;
}

fn getBlocks(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, grid_buffer: *[ChunkSize][ChunkSize][ChunkSize]Block) error{ Unrecoverable, OutOfMemory, Canceled }!struct { Chunk.Encoding, ChunkSource.GetBlocksMetadata } {
    var encoding: Chunk.Encoding = .{ .one_block = .null };
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

fn onLoad(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk: *Chunk, chunk_pos: ChunkPos) !void {
    for (self.chunk_sources) |source| {
        if (source) |s| {
            if (s.placeStructures) |onLoadFn| {
                try onLoadFn(s, io, allocator, self, chunk, chunk_pos);
            }
        }
    }
}

fn save(self: *@This(), io: std.Io, chunk: *Chunk, chunk_pos: ChunkPos) !void {
    const z = tracy.Zone.begin(.{ .src = @src() });
    defer z.end();
    for (self.chunk_sources) |source| {
        if (source) |s| {
            if (s.save) |saveChunk| {
                try saveChunk(s, io, self, chunk, chunk_pos);
            }
        }
    }
}

pub fn loadChunk(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, structures: bool) error{ OutOfMemory, Unrecoverable, Canceled }!*Chunk {
    const lc = tracy.Zone.begin(.{ .src = @src() });
    defer lc.end();
    const chunk = try self.fetchChunk(io, chunk_pos);
    if (chunk == null) {
        var grid_buffer: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        const chunkencoding, const metadata = try self.getBlocks(io, allocator, chunk_pos, &grid_buffer);
        const newchunk: Chunk = .{
            .encoding = chunkencoding,
            .saved = .init(metadata.from_disk),
            .structures_generated = .init(metadata.structures),
            .ref_count = .init(2),
        };
        const result = try self.putChunk(io, newchunk, chunk_pos);
        switch (result) {
            .existing => |existing| {
                if (structures) try self.tryGenStructures(io, allocator, existing, chunk_pos);
                return existing;
            },
            .inserted => |inserted| {
                if (structures) try self.tryGenStructures(io, allocator, inserted, chunk_pos);
                return inserted;
            },
        }
    } else {
        errdefer chunk.?.release();
        if (structures) try self.tryGenStructures(io, allocator, chunk.?, chunk_pos);
        return chunk.?;
    }
}

fn tryGenStructures(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk: *Chunk, chunk_pos: ChunkPos) !void {
    const z = tracy.Zone.begin(.{ .src = @src() });
    defer z.end();
    if (!chunk.structures_generated.load(.seq_cst)) {
        try onLoad(self, io, allocator, chunk, chunk_pos);
        chunk.structures_generated.store(true, .seq_cst);
    }
}

pub const Reader = struct {
    world: *World,
    lastChunkReadCache: ?struct { chunk_pos: ChunkPos, chunk: *Chunk } = null,

    pub fn getBlock(self: *@This(), io: std.Io, allocator: std.mem.Allocator, blockpos: BlockPos, level: i32) !Block {
        const chunkPos: ChunkPos = .fromLocalBlockPos(blockpos, level);
        const chunkBlockPos: @Vector(3, usize) = @intCast(@mod(blockpos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
        if (self.lastChunkReadCache == null or !std.meta.eql(self.lastChunkReadCache.?.chunk_pos, chunkPos)) {
            self.clear(io);
            self.lastChunkReadCache = .{
                .chunk_pos = chunkPos,
                .chunk = try self.world.loadChunk(io, allocator, chunkPos, false),
            };
            try self.lastChunkReadCache.?.chunk.lockShared(io);
        }
        return switch (self.lastChunkReadCache.?.chunk.encoding) {
            .grid => |b| b[chunkBlockPos[0]][chunkBlockPos[1]][chunkBlockPos[2]],
            .one_block => |b| b,
        };
    }

    pub fn getBlockUncached(self: *@This(), io: std.Io, allocator: std.mem.Allocator, blockpos: BlockPos, level: i32) !Block {
        const chunkPos: ChunkPos = .fromLocalBlockPos(blockpos, level);
        const chunkBlockPos: @Vector(3, usize) = @intCast(@mod(blockpos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
        const chunk = try self.world.loadChunk(io, allocator, chunkPos, false);
        chunk.lockShared(io);
        defer chunk.releaseAndUnlockShared(io);
        return switch (chunk.encoding) {
            .grid => |b| b[chunkBlockPos[0]][chunkBlockPos[1]][chunkBlockPos[2]],
            .one_block => |b| b,
        };
    }

    pub fn clear(self: *@This(), io: std.Io) void {
        if (self.lastChunkReadCache) |cache| {
            cache.chunk.releaseAndUnlockShared(io);
            self.lastChunkReadCache = null;
        }
    }
};

pub const Editor = struct {
    pub const Geometry = @import("structures/Geometry.zig");
    pub const Tree = @import("structures/Tree.zig").Tree;
    pub const TexturedSphere = @import("structures/TexturedSphere.zig");
    world: *World,
    last_chunk_cache: ?struct { chunk_pos: ChunkPos, blocks: *[ChunkSize][ChunkSize][ChunkSize]Block } = null,
    propagate_changes: bool = true,
    edit_buffer: std.HashMapUnmanaged(ChunkPos, [ChunkSize][ChunkSize][ChunkSize]Block, std.hash_map.AutoContext(ChunkPos), 80) = .empty,
    tempallocator: std.mem.Allocator,

    pub fn flush(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
        const flushh = tracy.Zone.begin(.{ .src = @src() });
        defer flushh.end();
        defer self.clear();
        self.edit_buffer.lockPointers();
        defer self.edit_buffer.unlockPointers();
        var it = self.edit_buffer.iterator();
        var remesh_neghbors_queue: std.AutoHashMap(ChunkPos, void) = .init(self.tempallocator);
        defer remesh_neghbors_queue.deinit();
        var remesh_queue_mutex: std.Io.Mutex = .init;
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        var edit_err: std.atomic.Value(EditErrorStruct) = .init(.{});
        while (it.next()) |diffChunk| {
            const chunk_pos = diffChunk.key_ptr.*;
            const encoding: Chunk.Encoding = .fromBlocks(diffChunk.value_ptr);
            group.async(io, editChunk, .{ self, io, allocator, chunk_pos, encoding, &remesh_neghbors_queue, &remesh_queue_mutex, &edit_err });
        }
        try group.await(io);
        if (edit_err.raw.exists) return @errorFromInt(edit_err.raw.err);
        it.index = 0;
        while (it.next()) |pos| {
            if (self.world.edit_callback) |onEdit| group.async(io, runEditFn, .{ onEdit, io, allocator, pos.key_ptr.*, &edit_err });
        }
        var rit = remesh_neghbors_queue.iterator();
        while (rit.next()) |pos| {
            if (self.world.edit_callback) |onEdit| group.async(io, runEditFn, .{ onEdit, io, allocator, pos.key_ptr.*, &edit_err });
        }
        try group.await(io);
        if (edit_err.raw.exists) return @errorFromInt(edit_err.raw.err);
    }

    const EditErrorStruct = packed struct(u32) {
        exists: bool = false,
        err: @Int(.unsigned, @bitSizeOf(anyerror)) = undefined,
        _: @Int(.unsigned, 32 - @bitSizeOf(anyerror) - 1) = undefined,
    };
    fn runEditFn(callback: World.EditCallback, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, callback_err: *std.atomic.Value(EditErrorStruct)) std.Io.Cancelable!void {
        callback.function(io, allocator, chunk_pos, callback.context) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => |e| callback_err.store(.{ .exists = true, .err = @intFromError(e) }, .seq_cst),
        };
    }

    fn editChunk(self: *const @This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, encoding: Chunk.Encoding, remesh_neghbors_queue: *std.AutoHashMap(ChunkPos, void), remesh_queue_mutex: *std.Io.Mutex, edit_err: *std.atomic.Value(EditErrorStruct)) std.Io.Cancelable!void {
        const z = tracy.Zone.begin(.{ .src = @src() });
        defer z.end();

        const chunk = self.world.loadChunk(io, allocator, chunk_pos, false) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return edit_err.store(.{ .exists = true, .err = @intFromError(err) }, .seq_cst),
        };
        defer chunk.release();
        const sides_changed = try mergeChunk(self.world, io, chunk_pos, chunk, encoding);

        for (sides_changed, std.enums.values(Chunk.Encoding.FaceRotation)) |changed, rotation| {
            if (!changed) continue;
            const toRemeshPos: ChunkPos = .{ .level = chunk_pos.level, .position = chunk_pos.position + rotation.direction() };
            try remesh_queue_mutex.lock(io);
            defer remesh_queue_mutex.unlock(io);
            remesh_neghbors_queue.put(toRemeshPos, {}) catch |err| return edit_err.store(.{ .exists = true, .err = @intFromError(err) }, .seq_cst);
        }
        if (self.propagate_changes) {
            const pr = tracy.Zone.begin(.{ .src = @src(), .name = "propagate" });
            defer pr.end();
            var propagation_editor: @This() = .{ .propagate_changes = false, .world = self.world, .tempallocator = self.tempallocator };
            defer propagation_editor.clear();
            var coords: ChunkPos = chunk_pos;
            var i: usize = 0;
            while (i < 16) {
                const changed = propagation_editor.propagateToParentByCoords(io, allocator, coords) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return edit_err.store(.{ .exists = true, .err = @intFromError(err) }, .seq_cst),
                };
                if (!changed) break;
                coords = coords.parent();
                i += 1;
                propagation_editor.flush(io, allocator) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return edit_err.store(.{ .exists = true, .err = @intFromError(err) }, .seq_cst),
                };
            }
        }
    }

    pub fn mergeChunk(world: *World, io: std.Io, chunk_pos: ChunkPos, chunk: *Chunk, merge: Chunk.Encoding) ![6]bool {
        var grid_buffer: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        var sides_changed: [6]bool = @splat(false);

        try chunk.lockExclusive(io);
        defer chunk.unlockExclusive(io);

        const callIfNeighborFacesChanged = if (world.edit_callback) |onEdit| onEdit.on_neghbor_face_change else false;
        const old_sides = if (callIfNeighborFacesChanged) chunk.encoding.extractAllFaces() else null;
        const was_grid: bool = chunk.encoding == .grid;

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

    pub fn clear(self: *@This()) void {
        self.last_chunk_cache = null;
        self.edit_buffer.clearAndFree(self.tempallocator);
    }

    pub fn placeBlock(self: *@This(), block: Block, pos: @Vector(3, i64), level: i32) !void {
        const chunkPos: ChunkPos = .fromLocalBlockPos(pos, level);
        const chunkBlockPos: @Vector(3, usize) = @intCast(@mod(pos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
        if (self.last_chunk_cache != null and std.meta.eql(self.last_chunk_cache.?.chunk_pos, chunkPos)) {
            @branchHint(.likely);
            self.last_chunk_cache.?.blocks[chunkBlockPos[0]][chunkBlockPos[1]][chunkBlockPos[2]] = block;
            return;
        }
        const chunk = (try self.edit_buffer.getOrPutValue(self.tempallocator, chunkPos, comptime @splat(@splat(@splat(.null))))).value_ptr;
        self.last_chunk_cache = .{ .chunk_pos = chunkPos, .blocks = chunk };
        chunk[chunkBlockPos[0]][chunkBlockPos[1]][chunkBlockPos[2]] = block;
    }

    pub fn placeSamplerShape(self: *@This(), block: Block, shape: anytype, level: i32) !void {
        const place = tracy.Zone.begin(.{ .src = @src() });
        defer place.end();
        const boundingBox = shape.boundingBox;
        var y = boundingBox[2];
        while (y <= boundingBox[3]) : (y += 1) {
            var dx = boundingBox[0];
            while (dx <= boundingBox[1]) : (dx += 1) {
                var dz = boundingBox[4];
                while (dz <= boundingBox[5]) : (dz += 1) {
                    if (shape.isPointInside(.{ dx, y, dz })) {
                        const i64blockpos: @Vector(3, i64) = switch (comptime @typeInfo(@TypeOf(boundingBox[0]))) {
                            .float => .{ @trunc(dx), @trunc(y), @trunc(dz) },
                            .int => .{ @intCast(dx), @intCast(y), @intCast(dz) },
                            else => unreachable,
                        };
                        try self.placeBlock(block, i64blockpos, level);
                    }
                }
            }
        }
    }

    const simplified_size = ChunkSize / scale_factor;

    pub fn propagateToParent(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk: *Chunk, chunk_pos: ChunkPos) !bool {
        const zone = tracy.Zone.begin(.{ .src = @src() });
        defer zone.end();

        const parent_pos = chunk_pos.parent();
        var simplified_blocks: [simplified_size][simplified_size][simplified_size]Block = undefined;
        var isoneblock: bool = false;
        try chunk.lockShared(io);
        switch (chunk.encoding) {
            .grid => |blocks| simplified_blocks = simplifyBlocksAvg(blocks),
            .one_block => |block| {
                simplified_blocks = @splat(@splat(@splat(block)));
                isoneblock = true;
            },
        }
        chunk.unlockShared(io);
        const pos_in_parent = chunk_pos.posInParent() * @as(@Vector(3, u8), @splat(simplified_size));
        const block_pos = parent_pos.toLocalBlockPos() + pos_in_parent;
        const parent = try self.world.loadChunk(io, allocator, parent_pos, false);
        defer parent.release();
        var changed_parent = false;
        try parent.lockShared(io);
        defer parent.unlockShared(io);
        if (isoneblock and parent.encoding == .one_block and parent.encoding.one_block == simplified_blocks[0][0][0]) return false;

        for (0..simplified_size) |x| {
            for (0..simplified_size) |y| {
                for (0..simplified_size) |z| {
                    const world_pos = @Vector(3, i64){
                        block_pos[0] + @as(i64, @intCast(x)),
                        block_pos[1] + @as(i64, @intCast(y)),
                        block_pos[2] + @as(i64, @intCast(z)),
                    };
                    const current_block = switch (parent.encoding) {
                        .grid => parent.encoding.grid[pos_in_parent[0] + x][pos_in_parent[1] + y][pos_in_parent[2] + z],
                        .one_block => parent.encoding.one_block,
                    };
                    const correct_block = simplified_blocks[x][y][z];
                    if (current_block == correct_block) continue;
                    try self.placeBlock(correct_block, world_pos, parent_pos.level);
                    changed_parent = true;
                }
            }
        }
        return changed_parent;
    }

    pub fn propagateToParentByCoords(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos) !bool {
        const chunk = try self.world.loadChunk(io, allocator, chunk_pos, false);
        defer chunk.release();
        return try self.propagateToParent(io, allocator, chunk, chunk_pos);
    }

    fn simplifyBlocksAvg(blocks: *const [ChunkSize][ChunkSize][ChunkSize]Block) [simplified_size][simplified_size][simplified_size]Block {
        var simplified: [simplified_size][simplified_size][simplified_size]Block = undefined;
        var unique_blocks: [scale_factor][scale_factor][scale_factor]Block = undefined;
        for (0..simplified_size) |sx| {
            for (0..simplified_size) |sy| {
                for (0..simplified_size) |sz| {
                    inline for (0..scale_factor) |dx| {
                        inline for (0..scale_factor) |dy| {
                            inline for (0..scale_factor) |dz| {
                                unique_blocks[dx][dy][dz] = blocks[sx * scale_factor + dx][sy * scale_factor + dy][sz * scale_factor + dz];
                            }
                        }
                    }
                    simplified[sx][sy][sz] = getBestBlock(@bitCast(unique_blocks));
                }
            }
        }
        return simplified;
    }

    fn getBestBlock(blocks: @Vector(scale_factor * scale_factor * scale_factor, @typeInfo(Block).@"enum".tag_type)) Block {
        var best: Block = undefined;
        var best_count: f32 = -1.0;
        inline for (0..scale_factor * scale_factor * scale_factor) |i| {
            const block_int = blocks[i];
            const block: Block = @enumFromInt(block_int);
            const weight = block.getPropagationWeight();
            const count = std.simd.countElementsWithValue(blocks, block_int);
            if (count * weight > best_count) {
                best = @enumFromInt(block_int);
                best_count = count * weight;
            }
        }
        return best;
    }
};

pub fn saveAll(self: *@This(), io: std.Io) void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    for (&self.chunks.shards, &self.chunks.shard_locks) |*shard, *lock| {
        group.async(io, saveShard, .{ self, shard, lock, io });
    }
    group.await(io) catch unreachable;
}

pub fn saveShard(self: *@This(), shard: *ChunkMapType.Shard, lock: *std.Io.Mutex, io: std.Io) void {
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    var it = shard.iterator();
    while (it.next()) |c| {
        c.chunk.encoding_lock.lockSharedUncancelable(io);
        defer c.chunk.encoding_lock.unlockShared(io);
        self.save(io, &c.chunk, c.key_from_value()) catch |err| std.log.err("error saving chunk: {any}, {any}\n", .{ c.key_from_value(), err });
    }
}

pub fn trySaveAll(self: *@This(), io: std.Io) !void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (&self.chunks.shards, &self.chunks.shard_locks) |*shard, *lock| {
        group.async(io, trySaveShard, .{ self, shard, lock, io });
    }
    try group.await(io);
}

fn trySaveShard(self: *World, shard: *ChunkMapType.Shard, lock: *std.Io.Mutex, io: std.Io) void {
    if (!lock.tryLock()) return;
    defer lock.unlock(io);
    var it = shard.iterator();
    while (it.next()) |c| {
        if (!c.chunk.encoding_lock.tryLockShared(io)) continue;
        defer c.chunk.encoding_lock.unlockShared(io);
        self.save(io, &c.chunk, c.key_from_value()) catch |err| std.log.err("error saving chunk: {any}, {any}\n", .{ c.key_from_value(), err });
    }
}

pub fn deinit(self: *@This(), io: std.Io, allocator: std.mem.Allocator) void {
    const deinitWorld = tracy.Zone.begin(.{ .src = @src() });
    defer deinitWorld.end();
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

    const chunk_cache = try Cache(ChunkPos, ChunkValue, ChunkValue.key_from_value, hash, .{}, 32).init(allocator, 131072, .{ .name = "benchmark chunk cache" });
    errdefer {
        var c = chunk_cache;
        c.deinit(allocator);
    }

    const grid_cache = try Cache(ChunkPos, GridValue, GridValue.key_from_value, hash, .{}, 32).init(allocator, 8192, .{ .name = "benchmark grid cache" });
    errdefer {
        var g = grid_cache;
        g.deinit(allocator);
    }

    var world: World = .{
        .chunks = chunk_cache,
        .grids = grid_cache,
        .edit_callback = null,
        .chunk_sources = .{ generator.getSource(), null, null, null },
        .config = .{ .SpawnCenterPos = .{ 0, 0, 0 }, .SpawnRange = 0 },
    };
    defer world.deinit(io, allocator);

    var counter: std.atomic.Value(usize) = .init(0);
    const st: std.Io.Timestamp = .now(io, .awake);
    const levels: [2]i32 = .{ 0, 4 };
    const square = 4;
    var lvl: i32 = levels[0];
    var group: std.Io.Group = .init;
    while (lvl < levels[1]) : (lvl += 1) {
        for (0..square) |x| {
            for (0..square) |y| {
                for (0..square) |z| {
                    group.async(io, loadchunktest, .{ &world, io, allocator, ChunkPos{ .position = .{ @as(i32, @intCast(x)) - square / 2, @as(i32, @intCast(y)) - square / 2, @as(i32, @intCast(z)) - square / 2 }, .level = @intCast(lvl) }, true, &counter });
                }
            }
        }
    }
    try group.await(io);
    std.testing.log_level = .debug;
    std.log.info("loaded at {d} chunks per second\n", .{@as(f32, @floatFromInt(counter.load(.seq_cst))) / (@as(f32, @floatFromInt(st.untilNow(io, .awake).nanoseconds)) / std.time.ns_per_s)});
}

fn loadchunktest(self: *World, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, structures: bool, counter: *std.atomic.Value(usize)) void {
    const ch = self.loadChunk(io, allocator, chunk_pos, structures) catch |err| std.debug.panic("err: {any}\n", .{err});
    ch.release();
    _ = counter.fetchAdd(1, .seq_cst);
}

fn makeTestingWorld(world: *World, generator: *DefaultGenerator, allocator: std.mem.Allocator, grids: usize, chunks: usize) !void {
    const gen = try DefaultGenerator.init(allocator, 1024 * 1024, .default);
    errdefer {
        var g = gen;
        g.terrain_height_cache.deinit(allocator);
    }
    generator.* = gen;
    generator.params.seed = 0;

    const chunk_count = @max(std.mem.alignForward(usize, chunks, 8192), 8192);
    const grid_count = @max(std.mem.alignForward(usize, grids, 8192), 8192);

    const chunk_cache = try Cache(ChunkPos, ChunkValue, ChunkValue.key_from_value, hash, .{}, 32).init(allocator, chunk_count, .{ .name = "test chunk cache" });
    errdefer {
        var c = chunk_cache;
        c.deinit(allocator);
    }

    const grid_cache = try Cache(ChunkPos, GridValue, GridValue.key_from_value, hash, .{}, 32).init(allocator, grid_count, .{ .name = "test grid cache" });
    errdefer {
        var g = grid_cache;
        g.deinit(allocator);
    }

    world.* = .{
        .chunks = chunk_cache,
        .grids = grid_cache,
        .config = .{ .SpawnCenterPos = .{ 0, 0, 0 }, .SpawnRange = 0 },
        .chunk_sources = .{ generator.getSource(), null, null, null },
    };
}

fn testLoadChunkAllocation(allocator: std.mem.Allocator, io: std.Io) !void {
    var world: World = undefined;
    var generator: DefaultGenerator = undefined;
    try makeTestingWorld(&world, &generator, allocator, 2, 2);
    defer world.deinit(io, allocator);

    const chunk = try world.loadChunk(io, allocator, .{ .position = .{ 0, 0, 0 }, .level = 0 }, true);
    chunk.release();
}

test "loadChunk allocation failure" {
    const io = std.testing.io;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testLoadChunkAllocation, .{io});
}

test "fuzz world" {
    var world: World = undefined;
    var generator: DefaultGenerator = undefined;
    try makeTestingWorld(&world, &generator, std.testing.allocator, 1000, 100);
    defer world.deinit(std.testing.io, std.testing.allocator);
    try std.testing.fuzz(&world, fuzzChunkLoad, .{});
}

fn fuzzChunkLoad(world: *World, smith: *std.testing.Smith) !void {
    const ch = try world.loadChunk(std.testing.io, std.testing.allocator, .{ .level = smith.valueRangeAtMost(i32, -2, 12), .position = @mod(smith.value(@Vector(3, i32)), @Vector(3, i32){ 1000, 1000, 1000 }) }, smith.value(bool));
    ch.release();
}

test {
    std.testing.refAllDecls(@This());
}
