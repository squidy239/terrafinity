const std = @import("std");

const Cache = @import("Cache").Cache;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const ztracy = @import("ztracy");

const Options = @import("../Game.zig").Options;
pub const Block = @import("Block.zig").Block;
const Chunk = @import("Chunk.zig");
pub const ChunkSize = Chunk.ChunkSize;
pub const DefaultGenerator = @import("Generator.zig").DefaultGenerator;
const Entity = @import("Entity.zig");
const EntityTypes = @import("EntityTypes.zig");
/// The main world object, this should not handle any rendering tasks.
/// Chunks use LODs for better performance.
/// All LODs should be stored since with infinite level every level combined
/// would only use 14.28571% more space than one LOD.
pub const WorldStorage = @import("WorldStorage.zig");

const World = @This();
threadlocal var prng: std.Random.DefaultPrng = .init(0);

entitys: ConcurrentHashMap(u128, *Entity, std.hash_map.AutoContext(u128), 80, 256),

chunks: ConcurrentHashMap(ChunkPos, *Chunk, std.hash_map.AutoContext(ChunkPos), 80, 256),
config: WorldConfig,

block_grid_pool_mutex: std.Io.Mutex = .init,
block_grid_count: u64 = 0,
block_grid_pool: std.heap.MemoryPoolExtra([ChunkSize][ChunkSize][ChunkSize]Block, .{ .growable = false, .alignment = .@"64" }),

chunk_pool_mutex: std.Io.Mutex = .init,
chunk_count: u64 = 0,
chunk_pool: std.heap.MemoryPoolExtra(Chunk, .{ .growable = false }),

/// Tries each source in order of priority (0 is highest).
/// If a source returns false, the next source will be tried.
/// At least one source must be able to load the chunk.
chunk_sources: [4]?ChunkSource,

onEdit: ?struct {
    onEditFn: *const fn (io: std.Io, allocator: std.mem.Allocator, chunkPos: ChunkPos, args: *anyopaque) error{OnEditFailed}!void,
    callIfNeighborFacesChanged: bool,
    onEditFnArgs: *anyopaque,
},

/// The level where one block in a chunk is one block.
pub const standard_level = 0;

/// The factor that each chunk is scaled each level.
pub const scale_factor = 2;

/// The level where one chunk is one block.
pub const chunk_level = -std.math.log(i32, scale_factor, ChunkSize);

pub const BlockPos = @Vector(3, i64);

pub const ChunkPos = struct {
    /// The division level of the chunk. 0 = one chunk is one block, 1 = 0.5 chunks is one block, etc.
    level: i32,
    position: @Vector(3, i32),

    pub inline fn levelToBlockRatio(level: i32) i64 {
        return std.math.powi(i32, scale_factor, level - chunk_level) catch |err| switch (err) {
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
                    children[x][y][z] = self.toLevel(self.level + 1).add(comptime .{ @intCast(x), @intCast(y), @intCast(z) });
                }
            }
        }
        return children;
    }

    /// Returns the global block position of the chunk where one block is one block at default level.
    pub inline fn toGlobalBlockPos(self: ChunkPos) BlockPos {
        return self.position * @as(@Vector(3, i64), @splat(levelToBlockRatio(self.level)));
    }

    pub inline fn posInParent(self: ChunkPos) @Vector(3, u8) {
        return @intCast(@mod(self.position, @Vector(3, i32){ scale_factor, scale_factor, scale_factor }));
    }

    /// Returns the local block pos of the chunk where one block is one block at the chunk's level.
    pub inline fn toLocalBlockPos(self: ChunkPos) BlockPos {
        return self.position * @as(@Vector(3, i64), @splat(ChunkSize));
    }

    pub inline fn toLevel(self: ChunkPos, level: i32) ChunkPos {
        const ratiovec: @Vector(3, f64) = @splat(levelToLevelRatio(self.level, level));
        const posvec: @Vector(3, f64) = @floatFromInt(self.position);
        return .{ .position = @intFromFloat(posvec * ratiovec), .level = level };
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

/// Sources must be thread safe.
pub const ChunkSource = struct {
    /// Holds any data for the chunk source.
    data: *anyopaque,

    /// Must generate the chunk blocks into the blocks array. May be called multiple times on the same position.
    /// Returns true if the chunk was generated, false if unsuccessful (next source will be tried).
    getBlocks: ?*const fn (self: ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, blocks: *Chunk.BlockEncoding, chunk_pos: ChunkPos) error{ Unrecoverable, OutOfMemory, Canceled }!bool,

    /// Called for every LoadChunk call (many times per chunk). Intended for structures or similar.
    /// All chunk sources will be tried.
    /// onEditFn must be called if chunks are modified, on any modified chunks, once all modifications are complete.
    /// This function is responsible for locking and adding refs to the chunk.
    onLoad: ?*const fn (self: ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, chunk: *Chunk, chunk_pos: ChunkPos) error{ OutOfMemory, Canceled, Unrecoverable }!void,

    /// Called for every UnloadChunk call (many times per chunk). All chunk sources will be tried.
    /// Does not have to be thread safe or lock the chunk since it is only called when the chunk has 1 ref.
    onUnload: ?*const fn (self: ChunkSource, io: std.Io, world: *World, chunk: *Chunk, chunk_pos: ChunkPos) error{Unrecoverable}!void,

    /// Should return the height of the terrain in blocks at the given chunk coordinates.
    getTerrainHeight: ?*const fn (self: ChunkSource, world: *World, chunk_pos: @Vector(2, i32), level: i32) error{ OutOfMemory, Unrecoverable }![ChunkSize][ChunkSize]i32,

    /// Should deinit the chunk source.
    deinit: ?*const fn (self: ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World) void,
};

/// Gets the chunk's blocks from sources in order; returns the first source that succeeds.
fn getBlocks(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos) error{ Unrecoverable, OutOfMemory, AllSourcesFailed, Canceled }!Chunk.BlockEncoding {
    var encoding: Chunk.BlockEncoding = .{ .one_block = .null };
    for (self.chunk_sources) |source| {
        if (source) |s| {
            if (s.getBlocks) |getBlocksFn| {
                if (try getBlocksFn(s, io, allocator, self, &encoding, chunk_pos)) return encoding;
            }
        }
    }
    return error.AllSourcesFailed;
}

fn onLoad(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk: *Chunk, chunk_pos: ChunkPos) !void {
    for (self.chunk_sources) |source| {
        if (source) |s| {
            if (s.onLoad) |onLoadFn| {
                try onLoadFn(s, io, allocator, self, chunk, chunk_pos);
            }
        }
    }
}

fn onUnload(self: *@This(), io: std.Io, chunk: *Chunk, chunk_pos: ChunkPos) !void {
    for (self.chunk_sources) |source| {
        if (source) |s| {
            if (s.onUnload) |onUnloadFn| {
                try onUnloadFn(s, io, self, chunk, chunk_pos);
            }
        }
    }
}

pub fn unloadEntity(self: *@This(), io: std.Io, allocator: std.mem.Allocator, entityUUID: u128) void {
    const en = self.entitys.fetchRemove(io, entityUUID) orelse return;
    en.unload(io, self, entityUUID, allocator, true) catch std.log.err("error unloading entity\n", .{});
}

pub fn spawnEntity(self: *@This(), io: std.Io, allocator: std.mem.Allocator, uuid: ?u128, entity: anytype, comptime return_entity: bool) !if (return_entity) *Entity else void {
    const UUID = uuid orelse World.prng.random().int(u128);
    if (self.entitys.contains(io, UUID)) return error.EntityAlreadyExists;
    const allocated_entity = try Entity.make(entity, allocator);
    errdefer allocated_entity.unload(io, self, UUID, allocator, false) catch unreachable;
    if (return_entity) _ = allocated_entity.ref_count.fetchAdd(1, .seq_cst);
    const existing = try self.entitys.putNoOverrideAddRef(io, allocator, UUID, allocated_entity);
    std.debug.assert(existing == null);
    if (return_entity) return allocated_entity;
}

pub fn getPlayerSpawnPos(self: *@This()) !@Vector(3, f64) {
    const pos = @Vector(2, i32){ @intFromFloat(self.config.SpawnCenterPos[0]), @intFromFloat(self.config.SpawnCenterPos[2]) } + @Vector(2, i32){
        World.prng.random().intRangeAtMost(i32, -@as(i32, @intCast(self.config.SpawnRange)), @as(i32, @intCast(self.config.SpawnRange))),
        World.prng.random().intRangeAtMost(i32, -@as(i32, @intCast(self.config.SpawnRange)), @as(i32, @intCast(self.config.SpawnRange))),
    };
    const height = 1000;
    std.log.info("Player spawn pos: {d}, {d}, {d}\n", .{ pos[0], height, pos[1] });
    return @Vector(3, f64){ @floatFromInt(pos[0]), @floatFromInt(height), @floatFromInt(pos[1]) };
}

pub fn getTerrainHeightAtCoords(self: *@This(), pos: @Vector(2, i64), level: i32) !i64 {
    const chunkPos = [2]i32{ @intCast(@divFloor(pos[0], ChunkSize)), @intCast(@divFloor(pos[1], ChunkSize)) };
    const posInChunk = [2]i32{ @intCast(@mod(pos[0], ChunkSize)), @intCast(@mod(pos[1], ChunkSize)) };
    const genSource = self.chunk_sources[self.chunk_sources.len - 1].?;
    const height = (try genSource.getTerrainHeight.?(genSource, self, [2]i32{ chunkPos[0], chunkPos[1] }, level))[@intCast(posInChunk[0])][@intCast(posInChunk[1])];
    return height;
}

/// Returns the genstate of a loaded chunk, null if the chunk is not loaded.
pub fn getGenState(self: *@This(), io: std.Io, chunk_pos: ChunkPos) ?Chunk.Genstate {
    const chunk = self.chunks.getAndAddRef(io, chunk_pos) orelse return null;
    defer chunk.release(io);
    return chunk.genstate.load(.seq_cst);
}

pub fn updateEntitys(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    const TickEntitiesTask = ztracy.ZoneN(@src(), "TickEntities");
    defer TickEntitiesTask.End();
    var it = self.entitys.iterator();
    defer it.deinit(io);
    while (try it.next(io)) |entry| {
        const uuid = entry.key_ptr.*;
        it.pause(io);
        const entity = self.entitys.getAndAddRef(io, uuid);
        if (entity) |en| {
            try en.update(io, allocator, self, uuid);
        }
        try it.unpause(io);
    }
}

/// Adds a ref and returns a chunk, generating it if it doesn't exist and putting it in the world hashmap.
/// Ref must be removed if not using the chunk.
pub fn loadChunk(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, structures: bool) error{ OutOfMemory, AllSourcesFailed, Unrecoverable, Canceled }!*Chunk {
    const lc = ztracy.ZoneNC(@src(), "loadChunk", 222222);
    defer lc.End();
    const chunk = self.chunks.getAndAddRef(io, chunk_pos);
    if (chunk == null) {
        const chunkencoding = try self.getBlocks(io, allocator, chunk_pos);
        const chunkptr: *Chunk = try .from(chunkencoding, io, &self.chunk_pool, &self.chunk_count, &self.chunk_pool_mutex);
        _ = chunkptr.add_ref(io);
        std.debug.assert(chunkptr.ref_count.load(.seq_cst) == 2);
        const existing = self.chunks.putNoOverrideAddRef(io, allocator, chunk_pos, chunkptr) catch |err| {
            chunkptr.release(io);
            chunkptr.free(io, &self.block_grid_pool, &self.block_grid_count, &self.block_grid_pool_mutex);
            self.destroyChunkPtr(io, chunkptr);
            return err;
        };
        if (existing) |d| {
            chunkptr.release(io);
            chunkptr.free(io, &self.block_grid_pool, &self.block_grid_count, &self.block_grid_pool_mutex);
            self.destroyChunkPtr(io, chunkptr);
            return d;
        }
        if (structures) {
            try onLoad(self, io, allocator, chunkptr, chunk_pos);
            chunkptr.genstate.store(.StructuresGenerated, .seq_cst);
        }
        return chunkptr;
    } else {
        if (structures and chunk.?.genstate.load(.seq_cst) == .TerrainGenerated) {
            try onLoad(self, io, allocator, chunk.?, chunk_pos);
            chunk.?.genstate.store(.StructuresGenerated, .seq_cst);
        }
        return chunk.?;
    }
}

pub fn unloadTimeout(self: *@This(), io: std.Io, max_grid_ms: u64, max_grids: u64, max_chunk_ms: u64, max_chunks: u64) !void {
    const unloadChunks = ztracy.ZoneNC(@src(), "unloadChunks", 1125878);
    defer unloadChunks.End();
    try self.block_grid_pool_mutex.lock(io);
    const grid_count = self.block_grid_count;
    self.block_grid_pool_mutex.unlock(io);
    try self.chunk_pool_mutex.lock(io);
    const chunk_count = self.chunk_count;
    self.chunk_pool_mutex.unlock(io);
    const grid_fraction: f32 = @min(1, @as(f32, @floatFromInt(grid_count)) / @as(f32, @floatFromInt(max_grids)));
    const chunk_fraction: f32 = @min(1, @as(f32, @floatFromInt(chunk_count)) / @as(f32, @floatFromInt(max_chunks)));
    const grid_timeout = memCurve(max_grid_ms, grid_fraction);
    const chunk_timeout = memCurve(max_chunk_ms, chunk_fraction);

    var chunks: usize = 0;
    var grids: usize = 0;
    var it = self.chunks.iterator();
    defer it.deinit(io);
    const currenttime = std.Io.Timestamp.now(io, .awake);
    while (try it.next(io)) |c| {
        chunks += 1;
        const chunk = c.value_ptr.*;
        const lastaccess = chunk.last_access.load(.unordered);
        const timeout = switch (chunk.blocks) {
            .blocks => @min(chunk_timeout, grid_timeout),
            .one_block => chunk_timeout,
        };
        if (chunk.blocks == .blocks) grids += 1;
        if (currenttime.nanoseconds - lastaccess < timeout) continue;
        _ = try self.tryUnloadChunkMapBucket(io, c.key_ptr.*, &it.map.buckets[it.bkt_index]);
    }
    std.log.debug("total chunks loaded: {d}, grids loaded: {d}\n", .{ chunks, grids });
}

fn memCurve(max_ms: u64, fraction: f32) u64 {
    const time: u64 = @intFromFloat(@as(f32, @floatFromInt(max_ms)) * (1 - fraction));
    return time;
}

pub const Reader = struct {
    world: *World,
    lastChunkReadCache: ?struct { chunk_pos: ChunkPos, chunk: *Chunk } = null,

    /// Returns a block at the given position. clear() must be called after a series of calls to unlock the cached chunk.
    /// Better for many block reads.
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
        return switch (self.lastChunkReadCache.?.chunk.blocks) {
            .blocks => |b| b[chunkBlockPos[0]][chunkBlockPos[1]][chunkBlockPos[2]],
            .one_block => |b| b,
        };
    }

    /// Returns a block at the given position. Better for fewer block reads.
    pub fn getBlockUncached(self: *@This(), io: std.Io, allocator: std.mem.Allocator, blockpos: BlockPos, level: i32) !Block {
        const chunkPos: ChunkPos = .fromLocalBlockPos(blockpos, level);
        const chunkBlockPos: @Vector(3, usize) = @intCast(@mod(blockpos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
        const chunk = try self.world.loadChunk(io, allocator, chunkPos, false);
        chunk.lockShared(io);
        defer chunk.releaseAndUnlockShared(io);
        return switch (chunk.blocks) {
            .blocks => |b| b[chunkBlockPos[0]][chunkBlockPos[1]][chunkBlockPos[2]],
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
    edit_buffer: std.HashMapUnmanaged(ChunkPos, [ChunkSize][ChunkSize][ChunkSize]Block, std.hash_map.AutoContext(ChunkPos), 50) = .empty,
    tempallocator: std.mem.Allocator,

    /// Applies the edits in the buffer to the world, frees any temporary allocations. Cleans up even if an error occurs.
    pub fn flush(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
        const flushh = ztracy.ZoneNC(@src(), "flush", 3563456);
        defer flushh.End();
        defer self.clear();
        self.edit_buffer.lockPointers();
        defer self.edit_buffer.unlockPointers();
        var it = self.edit_buffer.iterator();
        var neghborsToRemesh: std.AutoHashMap(ChunkPos, void) = .init(self.tempallocator);
        defer neghborsToRemesh.deinit();
        const callIfNeighborFacesChanged = if (self.world.onEdit) |onEdit| onEdit.callIfNeighborFacesChanged else false;
        var propagationEditor: @This() = .{ .propagate_changes = false, .world = self.world, .tempallocator = self.tempallocator };
        defer propagationEditor.clear();
        while (it.next()) |diffChunk| {
            const encoding: Chunk.BlockEncoding = .fromBlocks(diffChunk.value_ptr);
            const chunk = try self.world.loadChunk(io, allocator, diffChunk.key_ptr.*, false);
            defer chunk.release(io);
            var sides: [6]Chunk.ChunkFaceEncoding = undefined;
            if (callIfNeighborFacesChanged) {
                inline for (0..6) |side| {
                    sides[side] = try chunk.extractFace(io, @enumFromInt(side), false);
                }
            }
            try chunk.merge(io, encoding, &self.world.block_grid_pool, &self.world.block_grid_count, &self.world.block_grid_pool_mutex);

            if (self.propagate_changes) {
                var coords: ChunkPos = diffChunk.key_ptr.*;
                var i: usize = 0;
                while (i < 16) {
                    const changed = try propagationEditor.propagateToParentByCoords(io, allocator, coords);
                    if (!changed) break;
                    try propagationEditor.flush(io, allocator);
                    coords = coords.parent();
                    i += 1;
                }
            }
            var sides2: [6]Chunk.ChunkFaceEncoding = undefined;
            if (callIfNeighborFacesChanged) {
                inline for (0..6) |side| {
                    sides2[side] = try chunk.extractFace(io, @enumFromInt(side), false);
                }
            }
            if (callIfNeighborFacesChanged) {
                for (0..6) |side| {
                    if (!std.meta.eql(sides[side], sides2[side])) {
                        const toRemeshPos: ChunkPos = .{ .level = diffChunk.key_ptr.*.level, .position = diffChunk.key_ptr.*.position + switch (side) {
                            0 => @Vector(3, i32){ -1, 0, 0 },
                            1 => @Vector(3, i32){ 1, 0, 0 },
                            2 => @Vector(3, i32){ 0, -1, 0 },
                            3 => @Vector(3, i32){ 0, 1, 0 },
                            4 => @Vector(3, i32){ 0, 0, -1 },
                            5 => @Vector(3, i32){ 0, 0, 1 },
                            else => unreachable,
                        } };
                        try neghborsToRemesh.put(toRemeshPos, {});
                    }
                }
            }
        }
        it.index = 0;
        while (it.next()) |pos| {
            if (self.world.onEdit) |onEdit| try onEdit.onEditFn(io, allocator, pos.key_ptr.*, onEdit.onEditFnArgs);
        }
        var rit = neghborsToRemesh.iterator();
        while (rit.next()) |pos| {
            if (self.world.onEdit) |onEdit| try onEdit.onEditFn(io, allocator, pos.key_ptr.*, onEdit.onEditFnArgs);
        }
        if (self.propagate_changes) try propagationEditor.flush(io, allocator);
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
        const place = ztracy.ZoneNC(@src(), "PlaceSamplerShape", 6544564);
        defer place.End();
        const boundingBox = shape.boundingBox;
        var y = boundingBox[2];
        while (y < boundingBox[3]) : (y += 1) {
            var dx = boundingBox[0];
            while (dx <= boundingBox[1]) : (dx += 1) {
                var dz = boundingBox[4];
                while (dz <= boundingBox[5]) : (dz += 1) {
                    if (shape.isPointInside(.{ dx, y, dz })) {
                        const i64blockpos: @Vector(3, i64) = switch (comptime @typeInfo(@TypeOf(boundingBox[0]))) {
                            .float => .{ @intFromFloat(dx), @intFromFloat(y), @intFromFloat(dz) },
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

    //TODO improve this code
    /// Returns true if the parent chunk was changed.
    pub fn propagateToParent(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk: *Chunk, chunk_pos: ChunkPos) !bool {
        const parent_pos = chunk_pos.parent();
        var simplified_blocks: [simplified_size][simplified_size][simplified_size]Block = undefined;
        var isoneblock: bool = false;
        try chunk.lockShared(io);
        switch (chunk.blocks) {
            .blocks => |blocks| simplified_blocks = simplifyBlocksAvg(blocks),
            .one_block => |block| {
                simplified_blocks = @splat(@splat(@splat(block)));
                isoneblock = true;
            },
        }
        chunk.unlockShared(io);
        const pos_in_parent = chunk_pos.posInParent() * @as(@Vector(3, u8), @splat(simplified_size));
        const block_pos = parent_pos.toLocalBlockPos() + pos_in_parent;
        const parent = try self.world.loadChunk(io, allocator, parent_pos, false);
        defer parent.release(io);
        var changed_parent = false;
        try parent.lockShared(io);
        defer parent.unlockShared(io);
        if (isoneblock and parent.blocks == .one_block and parent.blocks.one_block == simplified_blocks[0][0][0]) return false;

        for (0..simplified_size) |x| {
            for (0..simplified_size) |y| {
                for (0..simplified_size) |z| {
                    const world_pos = @Vector(3, i64){
                        block_pos[0] + @as(i64, @intCast(x)),
                        block_pos[1] + @as(i64, @intCast(y)),
                        block_pos[2] + @as(i64, @intCast(z)),
                    };
                    const current_block = switch (parent.blocks) {
                        .blocks => parent.blocks.blocks[pos_in_parent[0] + x][pos_in_parent[1] + y][pos_in_parent[2] + z],
                        .one_block => parent.blocks.one_block,
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

    /// Returns true if the parent chunk was changed.
    pub fn propagateToParentByCoords(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos) !bool {
        const chunk = try self.world.loadChunk(io, allocator, chunk_pos, false);
        defer chunk.release(io);
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
};

fn getBestBlock(blocks: [scale_factor * scale_factor * scale_factor]Block) Block {
    var best: Block = blocks[0];
    var best_count: f32 = 1;
    inline for (0..blocks.len) |i| {
        const block = blocks[i];
        const weight = block.getPropagationWeight();
        var count: f32 = weight;
        inline for ((i + 1)..8) |j| {
            if (block == blocks[j]) count += weight;
        }
        if (count > best_count) {
            best = blocks[i];
            best_count = count;
        }
    }
    return best;
}

pub fn unloadChunk(self: *@This(), io: std.Io, chunk_pos: ChunkPos) !void {
    const chunk = self.chunks.fetchRemove(io, chunk_pos) orelse return;
    try self.unloadChunkByPtr(io, chunk, chunk_pos);
}

/// Tries to unload a chunk if it is not in use. Returns true if the chunk was unloaded.
pub fn tryUnloadChunkMapBucket(self: *@This(), io: std.Io, chunk_pos: ChunkPos, bkt: anytype) !bool {
    const chunk = bkt.hash_map.get(chunk_pos) orelse unreachable;
    if (chunk.ref_count.load(.seq_cst) != 1) {
        return false;
    }
    try self.unloadChunkByPtr(io, chunk, chunk_pos);
    std.debug.assert(bkt.hash_map.remove(chunk_pos));
    return true;
}

pub fn unloadChunkNoSave(self: *@This(), io: std.Io, chunk_pos: ChunkPos) void {
    const chunk = self.chunks.fetchRemove(io, chunk_pos) orelse return;
    self.unloadChunkByPtrNoSave(io, chunk);
}

/// Does not remove chunk from hashmap, just frees it.
pub fn unloadChunkByPtr(self: *@This(), io: std.Io, chunk: *Chunk, chunk_pos: ChunkPos) !void {
    _ = try chunk.waitForRefAmount(io, 1, null);
    try onUnload(self, io, chunk, chunk_pos);
    self.unloadChunkByPtrNoSave(io, chunk);
}

pub fn unloadChunkByPtrNoSave(self: *@This(), io: std.Io, chunk: *Chunk) void {
    _ = io.swapCancelProtection(.blocked);
    _ = chunk.waitForRefAmount(io, 1, null) catch unreachable;
    _ = io.swapCancelProtection(.unblocked);

    chunk.free(io, &self.block_grid_pool, &self.block_grid_count, &self.block_grid_pool_mutex);
    self.destroyChunkPtr(io, chunk);
}

fn destroyChunkPtr(self: *@This(), io: std.Io, chunk: *Chunk) void {
    self.chunk_pool_mutex.lockUncancelable(io);
    self.chunk_pool.destroy(chunk);
    self.chunk_count -= 1;
    self.chunk_pool_mutex.unlock(io);
}

pub fn deinit(self: *@This(), io: std.Io, allocator: std.mem.Allocator) void {
    const deinitWorld = ztracy.ZoneNC(@src(), "deinitWorld", 88124);
    defer deinitWorld.End();
    const last_prot = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(last_prot);
    {
        var it = self.chunks.iterator();
        defer it.deinit(io);
        while (it.next(io) catch unreachable) |c| {
            self.unloadChunkByPtr(io, c.value_ptr.*, c.key_ptr.*) catch |err| std.log.err("error unloading chunk: {any}, {any}\n", .{ c.key_ptr.*, err });
        }
    }
    std.log.info("chunks unloaded", .{});
    {
        var it = self.entitys.iterator();
        defer it.deinit(io);
        while (it.next(io) catch unreachable) |c| {
            c.value_ptr.*.unload(io, self, c.key_ptr.*, allocator, true) catch std.log.err("error unloading entity\n", .{});
        }
    }
    std.debug.assert(self.block_grid_pool_mutex.tryLock());
    self.block_grid_pool.deinit(allocator);
    std.debug.assert(self.chunk_pool_mutex.tryLock());
    self.chunk_pool.deinit(allocator);
    self.entitys.deinit(io, allocator);
    std.log.info("entitys unloaded", .{});
    for (self.chunk_sources) |source| {
        if (source) |s| if (s.deinit) |de| de(s, io, allocator, self);
    }
    self.chunks.deinit(io, allocator);
    std.log.info("world closed", .{});
}

fn normilizeInRange(num: anytype, oldLowerBound: anytype, oldUpperBound: anytype, newLowerBound: anytype, newUpperBound: anytype) @TypeOf(num, oldLowerBound, oldUpperBound, newLowerBound, newUpperBound) {
    return (num - oldLowerBound) / (oldUpperBound - oldLowerBound) * (newUpperBound - newLowerBound) + newLowerBound;
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
    if (@import("builtin").mode == .Debug) return error.SkipZigTest;
    const allocator = std.heap.smp_allocator;
    const io = std.testing.io;

    var generator: DefaultGenerator = .{ .params = .default, .terrain_height_cache = .init(1024) };
    generator.params.setSeeds(io);
    var world: World = .{
        .chunk_pool = try .initCapacity(allocator, 100000),
        .block_grid_pool = try .initCapacity(allocator, 6000),
        .onEdit = null,
        .chunk_sources = .{ generator.getSource(), null, null, null },
        .chunks = .init(),
        .entitys = .init(),
        .config = .{ .SpawnCenterPos = .{ 0, 0, 0 }, .SpawnRange = 0 },
    };
    defer world.deinit(io, allocator);

    var counter: std.atomic.Value(usize) = .init(0);
    var timer: std.time.Timer = try .start();
    const levels: [2]i32 = .{ 0, 4 };
    const square = 8;
    var lvl: i32 = levels[0];
    while (lvl < levels[1]) : (lvl += 1) {
        for (0..square) |x| {
            for (0..square) |y| {
                for (0..square) |z| {
                    _ = try io.concurrent(loadchunktest, .{ &world, io, allocator, ChunkPos{ .position = .{ @as(i32, @intCast(x)) - square / 2, @as(i32, @intCast(y)) - square / 2, @as(i32, @intCast(z)) - square / 2 }, .level = @intCast(lvl) }, true, &counter });
                }
            }
        }
    }
    while (counter.load(.seq_cst) != (levels[1] - levels[0]) * square * square * square) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    std.testing.log_level = .debug;
    std.log.info("loaded at {d} chunks per second\n", .{@as(f32, @floatFromInt(counter.load(.seq_cst))) / (@as(f32, @floatFromInt(timer.read())) / std.time.ns_per_s)});
}

fn loadchunktest(self: *World, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, structures: bool, counter: *std.atomic.Value(usize)) void {
    const ch = self.loadChunk(io, allocator, chunk_pos, structures) catch |err| std.debug.panic("err: {any}\n", .{err});
    ch.release(io);
    _ = counter.fetchAdd(1, .seq_cst);
}

fn testLoadChunkAllocation(allocator: std.mem.Allocator, io: std.Io) !void {
    var generator: DefaultGenerator = .{ .params = .default, .terrain_height_cache = .init(10) };
    generator.params.setSeeds(io);

    var world: World = undefined;
    world.chunk_pool = try std.heap.MemoryPoolExtra(Chunk, .{ .growable = false }).initCapacity(allocator, 10);
    world.block_grid_pool = std.heap.MemoryPoolExtra([ChunkSize][ChunkSize][ChunkSize]Block, .{ .growable = false, .alignment = .@"64" }).initCapacity(allocator, 10) catch |err| {
        world.chunk_pool.deinit(allocator);
        return err;
    };
    world.chunks = .init();
    world.entitys = .init();
    world.config = .{ .SpawnCenterPos = .{ 0, 0, 0 }, .SpawnRange = 0 };
    world.chunk_sources = .{ generator.getSource(), null, null, null };
    world.onEdit = null;
    world.chunk_count = 0;
    world.chunk_pool_mutex = .init;
    world.block_grid_count = 0;
    world.block_grid_pool_mutex = .init;

    defer world.deinit(io, allocator);

    const chunk = try world.loadChunk(io, allocator, .{ .position = .{ 0, 0, 0 }, .level = 0 }, false);
    chunk.release(io);
}
test "loadChunk allocation failure" {
    const io = std.testing.io;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testLoadChunkAllocation, .{io});
}

test {
    std.testing.refAllDecls(@This());
}
