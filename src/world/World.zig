const std = @import("std");

const Cache = @import("Cache").Cache;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const ThreadPool = @import("ThreadPool");
const ztracy = @import("ztracy");

pub const Block = @import("Block.zig").Block;
const Chunk = @import("Chunk.zig");
pub const ChunkSize = Chunk.ChunkSize;
pub const DefaultGenerator = @import("Generator.zig").DefaultGenerator;
const Entity = @import("Entity.zig");
const EntityTypes = @import("EntityTypes.zig");
///The main world object, this should not handle any rendering tasks
///chunks use LODs for better performance
///all LODs should be stored since with infinite level every level combined
///would only use 14.28571% more space then one LOD
pub const WorldStorage = @import("WorldStorage.zig");

const World = @This();
threadlocal var prng: std.Random.DefaultPrng = .init(0);

running: std.atomic.Value(bool),
allocator: std.mem.Allocator,
thread_pool: *ThreadPool,

Entitys: ConcurrentHashMap(u128, *Entity, std.hash_map.AutoContext(u128), 80, 256),

Chunks: ConcurrentHashMap(ChunkPos, *Chunk, std.hash_map.AutoContext(ChunkPos), 80, 256),
Config: WorldConfig,

block_grid_pool_mutex: std.Thread.Mutex = .{},
block_grid_count: u64 = 0,
block_grid_pool: std.heap.MemoryPoolExtra([ChunkSize][ChunkSize][ChunkSize]Block, .{ .growable = false, .alignment = .@"64" }),

chunk_pool_mutex: std.Thread.Mutex = .{},
chunk_count: u64 = 0,
chunk_pool: std.heap.MemoryPoolExtra(Chunk, .{ .growable = false }),

///tries each source in order until of priority, 0 is highest
///if a source returns false, the next source will be tried
///at least one source must be able to load the chunk
ChunkSources: [4]?ChunkSource,

onEdit: ?struct {
    onEditFn: *const fn (chunkPos: ChunkPos, args: *anyopaque) error{OnEditFailed}!void,
    callIfNeighborFacesChanged: bool,
    onEditFnArgs: *anyopaque,
},

///the level where one block in a chunk is one block
pub const standard_level = 0;

///the factor that each chunk is scaled each level
pub const scale_factor = 2;

///the level where one chunk is one block
pub const chunk_level = -std.math.log(i32, scale_factor, ChunkSize);

pub const BlockPos = @Vector(3, i64);

pub const ChunkPos = struct {
    ///the division level of the chunk, 0 is one chunk is one block, 1 is 0.5 chunks is one block id 1D, etc
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

    ///returns the global block position of the chunk where one block is one block at default level
    pub inline fn toGlobalBlockPos(self: ChunkPos) BlockPos {
        return self.position * @as(@Vector(3, i64), @splat(levelToBlockRatio(self.level)));
    }

    pub inline fn posInParent(self: ChunkPos) @Vector(3, u8) {
        return @intCast(@mod(self.position, @Vector(3, i32){ scale_factor, scale_factor, scale_factor }));
    }

    ///returns the local block pos of the chunk where one block is one block at the chunks level
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

///sources must be thread safe
pub const ChunkSource = struct {
    ///holds any data for the chunk source
    data: *anyopaque,

    ///must generate the chunk blocks into the blocks array, this may be called multiple times on the same chunk position
    ///returns true if the chunk was generated, false if it was unsuccessful, in which case the next chunk source will be tried
    getBlocks: ?*const fn (self: ChunkSource, world: *World, blocks: *Chunk.BlockEncoding, Pos: ChunkPos) error{ Unrecoverable, OutOfMemory }!bool,

    ///This function is called for every LoadChunk call, it will be called many times for each chunk
    ///it is intended for structures or similar things
    ///all chunk sources will be tried
    ///onEditFn must be called if chunks are modified on any modified chunks once all modifications are complete
    ///this function is responsible for locking and adding refs to the chunk
    onLoad: ?*const fn (self: ChunkSource, world: *World, chunk: *Chunk, Pos: ChunkPos) error{ OutOfMemory, Unrecoverable }!void,

    ///This function is called for every UnloadChunk call, it will be called many times for each chunk
    ///all chunk sources will be tried
    ///this function does not have to be thread safe or lock the chunk sonce it is only called when the chunk has 1 ref
    onUnload: ?*const fn (self: ChunkSource, world: *World, chunk: *Chunk, Pos: ChunkPos) error{Unrecoverable}!void,

    ///should return the height of the terrain in blocks at the given chunk coordinates
    getTerrainHeight: ?*const fn (self: ChunkSource, world: *World, Pos: @Vector(2, i32), level: i32) error{ OutOfMemory, Unrecoverable }![ChunkSize][ChunkSize]i32, //TODO remove this and make a better way to get terrain height

    ///should deinit the chunk source
    deinit: ?*const fn (self: ChunkSource, world: *World) void,
};

///gets the chunks blocks from the sources in order, returns the first source that succeeds
fn getBlocks(self: *@This(), Pos: ChunkPos) error{ Unrecoverable, OutOfMemory, AllSourcesFailed }!Chunk.BlockEncoding {
    var encoding: Chunk.BlockEncoding = .{ .oneBlock = .null };
    for (self.ChunkSources) |source| {
        if (source) |s| {
            if (s.getBlocks) |getBlocksFn| {
                if (try getBlocksFn(s, self, &encoding, Pos)) return encoding;
            }
        }
    }
    return error.AllSourcesFailed;
}

fn onLoad(self: *@This(), chunk: *Chunk, Pos: ChunkPos) error{ Unrecoverable, OutOfMemory }!void {
    for (self.ChunkSources) |source| {
        if (source) |s| {
            if (s.onLoad) |onLoadFn| {
                try onLoadFn(s, self, chunk, Pos);
            }
        }
    }
}

fn getBlockHeight(self: *@This(), block_pos: BlockPos, level: i32) !i64 {
    for (self.ChunkSources) |source| {
        if (source) |s| {
            if (s.getTerrainHeight) |getTerrainHeight| {
                return try getTerrainHeight(s, self, block_pos, level);
            }
        }
    }
    return error.AllSourcesFailed;
}

fn onUnload(self: *@This(), chunk: *Chunk, Pos: ChunkPos) !void {
    for (self.ChunkSources) |source| {
        if (source) |s| {
            if (s.onUnload) |onUnloadFn| {
                try onUnloadFn(s, self, chunk, Pos);
            }
        }
    }
}

pub fn unloadEntity(self: *@This(), entityUUID: u128) void {
    const en = self.Entitys.fetchremove(entityUUID) orelse return;
    en.unload(self, entityUUID, self.allocator, true) catch std.log.err("error unloading entity\n", .{});
}

pub fn spawnEntity(self: *@This(), uuid: ?u128, entity: anytype, comptime return_entity: bool) !if (return_entity) *Entity else void {
    const UUID = uuid orelse World.prng.random().int(u128);
    if (self.Entitys.contains(UUID)) return error.EntityAlreadyExists;
    const allocated_entity = try Entity.make(entity, self.allocator);
    errdefer allocated_entity.unload(self, UUID, self.allocator, false) catch unreachable;
    if (return_entity) _ = allocated_entity.ref_count.fetchAdd(1, .seq_cst); //add a ref for hashmap, putNoOverrideaddRef only adds a ref to an existing one
    const existing = try self.Entitys.putNoOverrideaddRef(UUID, allocated_entity);
    std.debug.assert(existing == null);
    if (return_entity) return allocated_entity;
}

pub fn getPlayerSpawnPos(self: *@This()) !@Vector(3, f64) {
    const pos = @Vector(2, i32){ @intFromFloat(self.Config.SpawnCenterPos[0]), @intFromFloat(self.Config.SpawnCenterPos[2]) } + @Vector(2, i32){ World.prng.random().intRangeAtMost(i32, -@as(i32, @intCast(self.Config.SpawnRange)), @as(i32, @intCast(self.Config.SpawnRange))), World.prng.random().intRangeAtMost(i32, -@as(i32, @intCast(self.Config.SpawnRange)), @as(i32, @intCast(self.Config.SpawnRange))) };
    const height = 1000;
    std.log.info("Player spawn pos: {d}, {d}, {d}\n", .{ pos[0], height, pos[1] });
    return @Vector(3, f64){ @floatFromInt(pos[0]), @floatFromInt(height), @floatFromInt(pos[1]) };
}

pub fn getTerrainHeightAtCoords(self: *@This(), pos: @Vector(2, i64), level: i32) !i64 {
    const chunkPos = [2]i32{ @intCast(@divFloor(pos[0], ChunkSize)), @intCast(@divFloor(pos[1], ChunkSize)) };
    const posInChunk = [2]i32{ @intCast(@mod(pos[0], ChunkSize)), @intCast(@mod(pos[1], ChunkSize)) };
    const genSource = self.ChunkSources[self.ChunkSources.len - 1].?;
    const height = (try genSource.getTerrainHeight.?(genSource, self, [2]i32{ chunkPos[0], chunkPos[1] }, level))[@intCast(posInChunk[0])][@intCast(posInChunk[1])];
    return height;
}

///returns the genstate of a loaded chunk, null if the chunk is not loaded
pub fn getGenState(self: *@This(), Pos: ChunkPos) ?Chunk.Genstate {
    const chunk = self.Chunks.getandaddref(Pos) orelse return null;
    defer chunk.release();
    return chunk.genstate.load(.seq_cst);
}

//TODO replace this with tick certen amount of entitys or certen amount of time
pub fn updateEntitys(self: *@This(), update_finished: *std.atomic.Value(bool), allocator: std.mem.Allocator) void {
    const TickEntitiesTask = ztracy.ZoneN(@src(), "TickEntities");
    defer TickEntitiesTask.End();
    defer update_finished.store(true, .seq_cst);
    var it = self.Entitys.iterator();
    defer it.deinit();
    while (it.next()) |entry| {
        const uuid = entry.key_ptr.*;
        it.pause();
        defer it.unpause();
        const entity = self.Entitys.getandaddref(uuid);
        if (entity) |en| {
            en.update(self, uuid, allocator) catch |err| {
                switch (err) {
                    error.TimedOut => continue,
                    else => @panic("err"),
                }
            };
        }
    }
}

///adds a ref and returns a chunk, generates it if it dosent exist and puts the chunk in the world hashmap. ref must be removed if not using chunk
pub fn loadChunk(self: *@This(), Pos: ChunkPos, structures: bool) error{ OutOfMemory, AllSourcesFailed, Unrecoverable }!*Chunk {
    const lc = ztracy.ZoneNC(@src(), "loadChunk", 222222);
    defer lc.End();
    const chunk = self.Chunks.getandaddref(Pos);
    if (chunk == null) {
        const chunkencoding = try self.getBlocks(Pos);
        const chunkptr: *Chunk = .from(chunkencoding, &self.chunk_pool, &self.chunk_count, &self.chunk_pool_mutex);
        _ = chunkptr.add_ref();
        std.debug.assert(chunkptr.ref_count.load(.seq_cst) == 2);
        const existing = self.Chunks.putNoOverrideaddRef(Pos, chunkptr) catch |err| {
            chunkptr.free(&self.block_grid_pool, &self.block_grid_count, &self.block_grid_pool_mutex);
            self.destroyChunkPtr(chunkptr);
            return err;
        };
        //chptr is in hashmap past this point
        if (existing) |d| {
            chunkptr.release(); //ref was added before putting
            chunkptr.free(&self.block_grid_pool, &self.block_grid_count, &self.block_grid_pool_mutex);
            self.destroyChunkPtr(chunkptr);
            return d;
        }
        if (structures) {
            try onLoad(self, chunkptr, Pos);
            chunkptr.genstate.store(.StructuresGenerated, .seq_cst);
        }
        return chunkptr;
    } else {
        if (structures and chunk.?.genstate.load(.seq_cst) == .TerrainGenerated) {
            try onLoad(self, chunk.?, Pos);
            chunk.?.genstate.store(.StructuresGenerated, .seq_cst);
        }
        return chunk.?;
    }
}

pub fn unloadTimeout(self: *@This(), max_grid_ms: u64, max_grids: u64, max_chunk_ms: u64, max_chunks: u64) !void {
    const unloadChunks = ztracy.ZoneNC(@src(), "unloadChunks", 1125878);
    defer unloadChunks.End();
    self.block_grid_pool_mutex.lock();
    const grid_count = self.block_grid_count;
    self.block_grid_pool_mutex.unlock();
    self.chunk_pool_mutex.lock();
    const chunk_count = self.chunk_count;
    self.chunk_pool_mutex.unlock();
    const grid_fraction: f32 = @min(1, @as(f32, @floatFromInt(grid_count)) / @as(f32, @floatFromInt(max_grids)));
    const chunk_fraction: f32 = @min(1, @as(f32, @floatFromInt(chunk_count)) / @as(f32, @floatFromInt(max_chunks)));
    const grid_timeout = memCurve(max_grid_ms, grid_fraction);
    const chunk_timeout = memCurve(max_chunk_ms, chunk_fraction);

    var chunks: usize = 0;
    var grids: usize = 0;
    var unload_chunk_buffer: [32784]ChunkPos = undefined;
    var tounload: std.ArrayList(ChunkPos) = .initBuffer(&unload_chunk_buffer);
    var it = self.Chunks.iterator();
    defer it.deinit();
    while (true) {
        tounload.clearRetainingCapacity();
        {
            const currenttime = std.time.microTimestamp();
            while (it.next()) |c| {
                chunks += 1;
                const chunk = c.value_ptr.*;
                const lastaccess = chunk.last_access.load(.unordered);
                const timeout = switch (chunk.blocks) {
                    .blocks => @min(chunk_timeout, grid_timeout),
                    .oneBlock => chunk_timeout,
                };
                if (chunk.blocks == .blocks) grids += 1;
                if (currenttime - lastaccess < timeout) continue;
                tounload.appendBounded(c.key_ptr.*) catch break;
            }
        }
        if (tounload.items.len == 0) break;
        it.pause();
        defer it.unpause();
        while (tounload.pop()) |Pos| {
            _ = try self.tryUnloadChunk(Pos);
        }
    }
    std.log.debug("total chunks loaded: {d}, grids loaded: {d}\n", .{ chunks, grids });
}

///returns chunk timeout seconds
fn memCurve(max_ms: u64, fraction: f32) u64 {
    const time: u64 = @intFromFloat(@as(f32, @floatFromInt(max_ms)) * (1 - fraction));
    return time;
}

const Options = @import("../Game.zig").Options;
//TODO when 0.16 is out get rid of this and make it happen after the time on asynchronously from the main loop
pub fn chunkUnloaderThread(self: *@This(), options: *Options, options_lock: *std.Thread.RwLock) void {
    while (self.running.load(.monotonic)) {
        const unloadChunks = ztracy.ZoneNC(@src(), "unloadChunks", 223);
        defer unloadChunks.End();
        const st = std.time.nanoTimestamp();
        options_lock.lockShared();
        const max_grid_timeout_ms = options.max_grid_timeout_ms;
        const max_chunk_timeout_ms = options.max_chunk_timeout_ms;
        const block_grid_capacity = options.block_grid_capacity;
        const chunk_capacity = options.chunk_capacity;
        const intervel_ns = options.unloader_frequency_ms * std.time.ns_per_ms;
        options_lock.unlockShared();
        self.unloadTimeout(max_grid_timeout_ms, block_grid_capacity, max_chunk_timeout_ms, chunk_capacity) catch |err| std.debug.panic("err:{any}\n", .{err});
        std.Thread.sleep(intervel_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
    }
}

pub const Reader = struct {
    world: *World,
    lastChunkReadCache: ?struct { Pos: ChunkPos, chunk: *Chunk } = null,
    ///returns a block at the given position, Clear must be called after a series of calls to unlock the cached chunk
    ///better for many block reads
    pub inline fn getBlock(self: *@This(), blockpos: BlockPos, level: i32) !Block {
        const chunkPos: ChunkPos = .fromLocalBlockPos(blockpos, level);
        const chunkBlockPos: @Vector(3, usize) = @intCast(@mod(blockpos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
        if (self.lastChunkReadCache == null or !std.meta.eql(self.lastChunkReadCache.?.Pos, chunkPos)) {
            self.clear();
            self.lastChunkReadCache = .{ .Pos = chunkPos, .chunk = try self.world.loadChunk(chunkPos, false) };
            self.lastChunkReadCache.?.chunk.lockShared();
        }
        const blockEncoding = self.lastChunkReadCache.?.chunk.blocks;
        return switch (blockEncoding) {
            .blocks => self.lastChunkReadCache.?.chunk.blocks.blocks[chunkBlockPos[0]][chunkBlockPos[1]][chunkBlockPos[2]],
            .oneBlock => self.lastChunkReadCache.?.chunk.blocks.oneBlock,
        };
    }

    ///returns a block at the given position, better for fewer block reads
    pub inline fn getBlockUncached(self: *@This(), blockpos: BlockPos, level: i32) !Block {
        const chunkPos: ChunkPos = .fromLocalBlockPos(blockpos, level);
        const chunkBlockPos: @Vector(3, usize) = @intCast(@mod(blockpos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
        const chunk = try self.world.loadChunk(chunkPos, false);
        chunk.lockShared();
        defer chunk.releaseAndUnlockShared();
        const blockEncoding = chunk.blocks;
        return switch (blockEncoding) {
            .blocks => chunk.blocks.blocks[chunkBlockPos[0]][chunkBlockPos[1]][chunkBlockPos[2]],
            .oneBlock => chunk.blocks.oneBlock,
        };
    }

    pub fn clear(self: *@This()) void {
        if (self.lastChunkReadCache) |cache| {
            cache.chunk.releaseAndUnlockShared();
            self.lastChunkReadCache = null;
        }
    }
};

pub const Editor = struct {
    pub const Geometry = @import("structures/Geometry.zig");
    pub const Tree = @import("structures/Tree.zig").Tree;
    pub const TexturedSphere = @import("structures/TexturedSphere.zig");
    world: *World,
    lastChunkCache: ?struct { Pos: ChunkPos, blocks: *[ChunkSize][ChunkSize][ChunkSize]Block } = null,
    propagateChanges: bool = true,
    editBuffer: std.HashMapUnmanaged(ChunkPos, [ChunkSize][ChunkSize][ChunkSize]Block, std.hash_map.AutoContext(ChunkPos), 50) = .empty,
    tempallocator: std.mem.Allocator,

    ///applies the edits in the buffer to the world, frees any temporary allocations. cleans up even if an error occurs
    pub fn flush(self: *@This()) !void {
        const flushh = ztracy.ZoneNC(@src(), "flush", 3563456);
        defer flushh.End();
        self.lastChunkCache = null;
        self.editBuffer.lockPointers();
        defer self.editBuffer.clearAndFree(self.tempallocator);
        defer self.editBuffer.unlockPointers();
        var it = self.editBuffer.iterator();
        var neghborsToRemesh: std.AutoHashMap(ChunkPos, void) = .init(self.tempallocator);
        defer neghborsToRemesh.deinit();
        const callIfNeighborFacesChanged = if (self.world.onEdit) |onEdit| onEdit.callIfNeighborFacesChanged else false;
        var propagationEditor: @This() = .{ .propagateChanges = false, .world = self.world, .tempallocator = self.tempallocator };
        while (it.next()) |diffChunk| {
            const encoding: Chunk.BlockEncoding = if (Chunk.IsOneBlock(diffChunk.value_ptr)) |oneBlock| .{ .oneBlock = oneBlock } else .{ .blocks = diffChunk.value_ptr };
            const chunk = try self.world.loadChunk(diffChunk.key_ptr.*, false);
            defer chunk.release();
            var sides: [6][ChunkSize][ChunkSize]Block = undefined;
            if (callIfNeighborFacesChanged) {
                inline for (0..6) |side| {
                    sides[side] = chunk.extractFace(@enumFromInt(side), false);
                }
            }
            chunk.merge(encoding, &self.world.block_grid_pool, &self.world.block_grid_count, &self.world.block_grid_pool_mutex, true);

            if (self.propagateChanges) {
                var coords: ChunkPos = diffChunk.key_ptr.*;
                var i: usize = 0;
                while (i < 16) { //16 is the upper limit so it wont break
                    const changed = try propagationEditor.propagateToParentByCoords(coords);
                    if (!changed) break;
                    try propagationEditor.flush(); //have to flush at each propagation so others dont get stale data
                    coords = coords.parent();
                    i += 1;
                }
            }
            var sides2: [6][ChunkSize][ChunkSize]Block = undefined;
            if (callIfNeighborFacesChanged) {
                inline for (0..6) |side| {
                    sides2[side] = chunk.extractFace(@enumFromInt(side), false);
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
            if (self.world.onEdit) |onEdit| try onEdit.onEditFn(pos.key_ptr.*, onEdit.onEditFnArgs);
        }
        var rit = neghborsToRemesh.iterator();
        while (rit.next()) |pos| {
            if (self.world.onEdit) |onEdit| try onEdit.onEditFn(pos.key_ptr.*, onEdit.onEditFnArgs);
        }
        if (self.propagateChanges) try propagationEditor.flush();
    }

    pub inline fn placeBlock(self: *@This(), block: Block, pos: @Vector(3, i64), level: i32) !void {
        const chunkPos: ChunkPos = .fromLocalBlockPos(pos, level);
        const chunkBlockPos: @Vector(3, usize) = @intCast(@mod(pos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
        if (self.lastChunkCache != null and std.meta.eql(self.lastChunkCache.?.Pos, chunkPos)) {
            @branchHint(.likely);
            self.lastChunkCache.?.blocks[chunkBlockPos[0]][chunkBlockPos[1]][chunkBlockPos[2]] = block;
            return;
        }

        const chunk = (try self.editBuffer.getOrPutValue(self.tempallocator, chunkPos, comptime @splat(@splat(@splat(.null))))).value_ptr;
        self.lastChunkCache = .{ .Pos = chunkPos, .blocks = chunk };
        chunk[(chunkBlockPos[0])][(chunkBlockPos[1])][(chunkBlockPos[2])] = block;
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

    ///returns true if the parent chunk was changed
    pub fn propagateToParent(self: *@This(), chunk: *Chunk, Pos: ChunkPos) !bool {
        const parent_pos = Pos.parent();
        var simplified_blocks: [simplified_size][simplified_size][simplified_size]Block = undefined;
        var isoneblock: bool = false;
        chunk.lockShared();
        switch (chunk.blocks) {
            .blocks => |blocks| {
                simplified_blocks = simplifyBlocksAvg(blocks);
            },
            .oneBlock => |block| {
                simplified_blocks = @splat(@splat(@splat(block)));
                isoneblock = true;
            },
        }
        chunk.unlockShared();
        const pos_in_parent = Pos.posInParent() * @as(@Vector(3, u8), @splat(simplified_size));
        const block_pos = parent_pos.toLocalBlockPos() + pos_in_parent;
        const parent = try self.world.loadChunk(parent_pos, false);
        defer parent.release();
        var changed_parent = false;
        parent.lockShared();
        defer parent.unlockShared();
        if (isoneblock and parent.blocks == .oneBlock and parent.blocks.oneBlock == simplified_blocks[0][0][0]) return false;
        _ = try parent.ToBlocks(&self.world.block_grid_pool, &self.world.block_grid_count, &self.world.block_grid_pool_mutex, false);
        for (0..simplified_size) |x| {
            for (0..simplified_size) |y| {
                for (0..simplified_size) |z| {
                    const world_pos = @Vector(3, i64){ block_pos[0] + @as(i64, @intCast(x)), block_pos[1] + @as(i64, @intCast(y)), block_pos[2] + @as(i64, @intCast(z)) };
                    const current_block = parent.blocks.blocks[pos_in_parent[0] + x][pos_in_parent[1] + y][pos_in_parent[2] + z];
                    const correct_block = simplified_blocks[x][y][z];
                    if (current_block == correct_block) continue;
                    try self.placeBlock(correct_block, world_pos, parent_pos.level);
                    changed_parent = true;
                }
            }
        }
        return changed_parent;
    }

    ///returns true if the parent chunk was changed
    pub fn propagateToParentByCoords(self: *@This(), chunk_pos: ChunkPos) !bool {
        const chunk = try self.world.loadChunk(chunk_pos, false);
        defer chunk.release();
        return try self.propagateToParent(chunk, chunk_pos);
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

inline fn getBestBlock(blocks: [scale_factor * scale_factor * scale_factor]Block) Block {
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

pub fn unloadChunk(self: *@This(), Pos: ChunkPos) !void {
    const chunk = self.Chunks.fetchremove(Pos) orelse return; //removed from hashmap, no refs added or removed because they would cancel out
    try self.unloadChunkByPtr(chunk, Pos);
}

///tries to unload a chunk if it is not in use, returns true if the chunk was unloaded by this function
pub fn tryUnloadChunk(self: *@This(), Pos: ChunkPos) !bool {
    const chunk = self.Chunks.getandaddref(Pos) orelse return false;
    if (chunk.ref_count.load(.seq_cst) != 2) {
        chunk.release();
        return false;
    }
    _ = self.Chunks.remove(Pos);
    chunk.release();
    try self.unloadChunkByPtr(chunk, Pos);
    return true;
}

pub fn unloadChunkNoSave(self: *@This(), Pos: ChunkPos) void {
    const chunk = self.Chunks.fetchremove(Pos) orelse return; //removed from hashmap, no refs added or removed because they would cancel out
    self.unloadChunkByPtrNoSave(chunk);
}

///dosent remove chunk from hashmap, just frees it
pub fn unloadChunkByPtr(self: *@This(), chunk: *Chunk, Pos: ChunkPos) !void {
    _ = chunk.WaitForRefAmount(1, null);
    try onUnload(self, chunk, Pos);
    self.unloadChunkByPtrNoSave(chunk);
}

pub fn unloadChunkByPtrNoSave(self: *@This(), chunk: *Chunk) void {
    _ = chunk.WaitForRefAmount(1, null);
    _ = chunk.free(&self.block_grid_pool, &self.block_grid_count, &self.block_grid_pool_mutex);
    self.destroyChunkPtr(chunk);
}

fn destroyChunkPtr(self: *@This(), chunk: *Chunk) void {
    self.chunk_pool_mutex.lock();
    self.chunk_pool.destroy(chunk);
    self.chunk_count -= 1;
    self.chunk_pool_mutex.unlock();
}

pub fn stop(self: *@This()) void {
    self.running.store(false, .monotonic);
}

pub fn deinit(self: *@This()) void {
    const deinitWorld = ztracy.ZoneNC(@src(), "deinitWorld", 88124);
    defer deinitWorld.End();
    self.stop();
    {
        var it = self.Chunks.iterator();
        defer it.deinit();
        while (it.next()) |c| {
            self.unloadChunkByPtr(c.value_ptr.*, c.key_ptr.*) catch |err| std.log.err("error unloading chunk: {any}, {any}\n", .{ c.key_ptr.*, err });
        }
    }
    std.log.info("chunks unloaded", .{});
    {
        var it = self.Entitys.iterator();
        defer it.deinit();
        while (it.next()) |c| {
            c.value_ptr.*.unload(self, c.key_ptr.*, self.allocator, true) catch std.log.err("error unloading entity\n", .{});
        }
    }
    std.debug.assert(self.block_grid_pool_mutex.tryLock());
    self.block_grid_pool.deinit();
    std.debug.assert(self.chunk_pool_mutex.tryLock());
    self.chunk_pool.deinit();
    self.Entitys.deinit();
    std.log.info("entitys unloaded", .{});
    for (self.ChunkSources) |source| {
        if (source) |s| if (s.deinit) |de| de(s, self);
    }

    self.Chunks.deinit();
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

test "world" {
    var threadPool: ThreadPool = undefined;
    try threadPool.init(.{ .allocator = std.testing.allocator, .n_jobs = 16 });
    defer threadPool.deinit();

    var world: World = .{
        .chunk_pool = try .initPreheated(std.testing.allocator, 1000),
        .block_grid_pool = try .initPreheated(std.testing.allocator, 1000),
        .thread_pool = &threadPool,
        .allocator = std.testing.allocator,
        .onEdit = null,
        .ChunkSources = @splat(null),
        .running = .init(true),
        .Chunks = .init(std.testing.allocator),
        .Entitys = .init(std.testing.allocator),
        .Config = .{ .SpawnCenterPos = .{ 0, 0, 0 }, .SpawnRange = 0 },
    };
    defer world.deinit();
    try std.testing.expectEqual(error.AllSourcesFailed, world.loadChunk(ChunkPos{ .level = standard_level, .position = .{ 0, 0, 0 } }, true));
}

test "cube benchmark" {
    if (@import("builtin").mode == .Debug) return error.SkipZigTest;
    const allocator = std.heap.smp_allocator;
    const cpu_count = try std.Thread.getCpuCount();
    var threadPool: ThreadPool = undefined;
    try threadPool.init(.{ .allocator = allocator, .n_jobs = cpu_count });

    var generator: DefaultGenerator = .{ .params = .default, .terrain_height_cache = try .init(allocator, 1024) };
    generator.params.setSeeds();
    var world: World = .{
        .chunk_pool = try .initPreheated(allocator, 100000),
        .block_grid_pool = try .initPreheated(allocator, 6000),
        .thread_pool = &threadPool,
        .allocator = allocator,
        .onEdit = null,
        .ChunkSources = .{ generator.getSource(), null, null, null },
        .running = .init(true),
        .Chunks = .init(allocator),
        .Entitys = .init(allocator),
        .Config = .{ .SpawnCenterPos = .{ 0, 0, 0 }, .SpawnRange = 0 },
    };
    defer world.deinit();
    defer threadPool.deinit();

    var counter: std.atomic.Value(usize) = .init(0);
    var timer: std.time.Timer = try .start();
    const levels: [2]i32 = .{ 0, 16 };
    const square = 32;
    var lvl: i32 = levels[0];
    while (lvl < levels[1]) : (lvl += 1) {
        for (0..square) |x| {
            for (0..square) |y| {
                for (0..square) |z| {
                    try threadPool.spawn(loadchunktest, .{ &world, ChunkPos{ .position = .{ @as(i32, @intCast(x)) - square / 2, @as(i32, @intCast(y)) - square / 2, @as(i32, @intCast(z)) - square / 2 }, .level = @intCast(lvl) }, true, &counter }, .Medium);
                }
            }
        }
    }
    while (counter.load(.seq_cst) != (levels[1] - levels[0]) * square * square * square) {}
    std.testing.log_level = .debug;
    std.log.info("loaded at {d} chunks per second\n", .{@as(f32, @floatFromInt(counter.load(.seq_cst))) / (@as(f32, @floatFromInt(timer.read())) / std.time.ns_per_s)});
}

fn loadchunktest(self: *World, Pos: ChunkPos, structures: bool, counter: *std.atomic.Value(usize)) void {
    const ch = self.loadChunk(Pos, structures) catch |err| std.debug.panic("err: {any}\n", .{err});
    ch.release();
    _ = counter.fetchAdd(1, .seq_cst);
}
