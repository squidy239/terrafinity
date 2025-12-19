const std = @import("std");
const ThreadPool = @import("root").ThreadPool;

pub const Block = @import("Chunk").Block;
const Cache = @import("Cache").Cache;
const Chunk = @import("Chunk").Chunk;
const ChunkSize = Chunk.ChunkSize;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Entity = @import("Entity").Entity;
const EntityTypes = @import("EntityTypes");
const ztracy = @import("ztracy");

pub const World = struct {
    pub const WorldStorage = @import("WorldStorage.zig");
    pub const DefaultGenerator = @import("Generator.zig").DefaultGenerator;
    threadlocal var prng: std.Random.DefaultPrng = .init(0);

    running: std.atomic.Value(bool),
    entityUpdaterThread: ?std.Thread,
    allocator: std.mem.Allocator,
    threadPool: *ThreadPool,

    Entitys: ConcurrentHashMap(u128, *Entity, std.hash_map.AutoContext(u128), 80, 256),

    Chunks: ConcurrentHashMap(ChunkPos, *Chunk, std.hash_map.AutoContext(ChunkPos), 80, 256),
    Config: WorldConfig,
    ///tries each source in order until of priority, 0 is highest
    ///if a source returns false, the next source will be tried
    ///at least one source must be able to load the chunk
    ChunkSources: [4]?ChunkSource,

    onEdit: ?struct {
        onEditFn: *const fn (chunkPos: ChunkPos, args: *anyopaque) void,
        callIfNeighborFacesChanged: bool,
        onEditFnArgs: *anyopaque,
    },

    ///the level where one block in a chunk is one block
    pub const StandardLevel = 0;

    ///the amount of divisions per axis in the tree structure
    pub const TreeDivisions = 2;
    pub const BlockPos = @Vector(3, i64);
    ///the level where one chunk is one block
    pub const ChunkLevel = -std.math.log(i32, TreeDivisions, ChunkSize);

    pub const ChunkPos = struct {
        ///the division level of the chunk, 0 is one chunk is one block, 1 is 0.5 chunks is one block id 1D, etc
        level: i32,
        position: @Vector(3, i32),

        pub inline fn levelToBlockRatio(level: i32) i64 {
            return std.math.powi(i32, TreeDivisions, level - ChunkLevel) catch |err| switch (err) {
                error.Overflow => unreachable,
                error.Underflow => 1,
            };
        }

        pub inline fn levelToBlockRatioFloat(level: i32) f32 {
            return std.math.pow(f32, @floatFromInt(TreeDivisions), @floatFromInt(level - ChunkLevel));
        }

        pub inline fn parent(self: ChunkPos) ChunkPos {
            return .{ .level = self.level + 1, .position = @divFloor(self.position, @as(@Vector(3, i32), @splat(TreeDivisions))) };
        }

        pub inline fn levelToLevelRatio(level1: i32, level2: i32) f64 {
            return std.math.pow(f64, @floatFromInt(TreeDivisions), @floatFromInt(level1 - level2));
        }

        pub inline fn toScale(level: i32) f32 {
            return levelToBlockRatioFloat(level) / ChunkSize;
        }
        
        ///returns the global block position of the chunk where one block is one block at default level
        pub inline fn toGlobalBlockPos(self: ChunkPos) BlockPos {
            return self.position * @as(@Vector(3, i64), @splat(levelToBlockRatio(self.level)));
        }
        
        pub inline fn posInParent(self: ChunkPos) @Vector(3, u8) {
            return @intCast(@mod(self.position, @Vector(3, i32){ TreeDivisions, TreeDivisions, TreeDivisions }));
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
        SpawnCenterPos: @Vector(3, f64),
        SpawnRange: u32,
    };

    ///sources must be thread safe
    pub const ChunkSource = struct {
        ///holds any data for the chunk source
        data: *anyopaque,

        ///must generate the chunk blocks into the blocks array, this may be called multiple times on the same chunk position
        ///returns true if the chunk was generated, false if it was unsuccessful, in which case the next chunk source will be tried
        getBlocks: ?*const fn (self: ChunkSource, world: *World, blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, Pos: ChunkPos) error{ Unrecoverable, OutOfMemory }!bool,

        ///This function is called for every LoadChunk call, it will be called many times for each chunk
        ///it is intended for structures or similar things
        ///all chunk sources will be tried
        ///onEditFn must be called if chunks are modified on any modified chunks once all modifications are complete
        ///this function is responsible for locking and adding refs to the chunk
        onLoad: ?*const fn (self: ChunkSource, world: *World, chunk: *Chunk, Pos: ChunkPos) error{ OutOfMemory, Unrecoverable }!void,

        ///This function is called for every UnloadChunk call, it will be called many times for each chunk
        ///all chunk sources will be tried
        onUnload: ?*const fn (self: ChunkSource, world: *World, chunk: *Chunk, Pos: ChunkPos) error{Unrecoverable}!void,

        ///should return the height of the terrain in blocks at the given chunk coordinates
        getTerrainHeight: ?*const fn (self: ChunkSource, world: *World, Pos: @Vector(2, i32)) error{ OutOfMemory, Unrecoverable }![ChunkSize][ChunkSize]i32, //TODO remove this and make a better way to get terrain height

        ///should deinit the chunk source
        deinit: ?*const fn (self: ChunkSource, world: *World) void,
    };

    ///gets the chunks blocks from the sources in order, returns the first source that succeeds
    fn getBlocks(self: *@This(), Pos: ChunkPos, blocks: *[ChunkSize][ChunkSize][ChunkSize]Block) error{ Unrecoverable, OutOfMemory, AllSourcesFailed }!void {
        for (self.ChunkSources) |source| {
            if (source) |s| {
                if (s.getBlocks) |getBlocksFn| {
                    if (try getBlocksFn(s, self, blocks, Pos)) return;
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

    fn onUnload(self: *@This(), chunk: *Chunk, Pos: ChunkPos) !void {
        for (self.ChunkSources) |source| {
            if (source) |s| {
                if (s.onUnload) |onUnloadFn| {
                    try onUnloadFn(s, self, chunk, Pos);
                }
            }
        }
    }

    pub fn UnloadEntity(self: *@This(), entityUUID: u128) void {
        const en = self.Entitys.fetchremove(entityUUID) orelse return;
        en.unload(self, entityUUID, self.allocator, true) catch std.log.err("error unloading entity\n", .{});
    }

    pub fn UnloadEntityNoLock(self: *@This(), entityUUID: u128, ref_amount: u32) void {
        const en = self.Entitys.fetchremoveandaddref(entityUUID) orelse return;
        _ = en.WaitForRefAmount(1 + ref_amount, null); //already done in fullfree but i am doing it here so there will be 1 ref when saving
        //TODO save entity to disk
        en.fullfree(self.allocator);
    }

    pub fn SpawnEntity(self: *@This(), uuid: ?u128, entity: anytype) !*Entity {
        const UUID = uuid orelse World.prng.random().int(u128);
        if (self.Entitys.contains(UUID)) return error.EntityAlreadyExists;
        const allocated_entity = try Entity.Make(entity, self.allocator);
        errdefer allocated_entity.unload(self, UUID, self.allocator, false) catch unreachable;
        const existing = try self.Entitys.putNoOverrideaddRef(UUID, allocated_entity);
        std.debug.assert(existing == null);
        return allocated_entity;
    }

    pub fn GetPlayerSpawnPos(self: *@This()) !@Vector(3, f64) {
        const pos = @Vector(2, i32){ @intFromFloat(self.Config.SpawnCenterPos[0]), @intFromFloat(self.Config.SpawnCenterPos[2]) } + @Vector(2, i32){ World.prng.random().intRangeAtMost(i32, -@as(i32, @intCast(self.Config.SpawnRange)), @as(i32, @intCast(self.Config.SpawnRange))), World.prng.random().intRangeAtMost(i32, -@as(i32, @intCast(self.Config.SpawnRange)), @as(i32, @intCast(self.Config.SpawnRange))) };
        // const height = try self.GetTerrainHeightAtCoords(pos);
        std.debug.print("Player spawn pos: {d}, {d}, {d}\n", .{ pos[0], 1000, pos[1] });
        return @Vector(3, f64){ @floatFromInt(pos[0]), @floatFromInt(1000), @floatFromInt(pos[1]) };
    }

    pub fn GetTerrainHeightAtCoords(self: *@This(), pos: @Vector(2, i64)) !i64 {
        const chunkPos = [2]i32{ @intCast(@divFloor(pos[0], ChunkSize)), @intCast(@divFloor(pos[1], ChunkSize)) };
        const posInChunk = [2]i32{ @intCast(@mod(pos[0], ChunkSize)), @intCast(@mod(pos[1], ChunkSize)) };
        const genSource = self.ChunkSources[self.ChunkSources.len - 1] orelse undefined;
        const height = (try genSource.getTerrainHeight.?(genSource, self, [2]i32{ chunkPos[0], chunkPos[1] }))[@intCast(posInChunk[0])][@intCast(posInChunk[1])];
        return height;
    }

    //TODO replace this with tick certen amount of entitys or certen amount of time
    pub fn TickEntitiesBucketTask(self: *@This(), complete: *std.atomic.Value(u32), bucketindex: usize, allocator: std.mem.Allocator) void {
        defer _ = complete.fetchAdd(1, .seq_cst);
        if (!self.running.load(.monotonic)) return;
        const bucket = &self.Entitys.buckets[bucketindex];
        const TickEntitiesTask = ztracy.ZoneNC(@src(), "TickEntitiesTask", 324);
        defer TickEntitiesTask.End();
        var keys: []u128 = undefined; //makes an array of keys not owned by the hashmap so update can unload the entity
        {
            bucket.lock.lockShared();
            defer bucket.lock.unlockShared();
            const keyit = bucket.hash_map.keyIterator();
            keys = allocator.dupe(u128, keyit.items[0..keyit.len]) catch |err| std.debug.panic("err: {any}\n", .{err});
        }
        defer allocator.free(keys);
        for (keys) |uuid| {
            const entity = bucket.getandaddref(uuid);
            if (entity) |en| {
                en.update(self, uuid, allocator) catch |err| {
                    switch (err) {
                        error.TimedOut => continue,
                        error.Unrecoverable => std.debug.panic("entity update err Unrecoverable\n", .{}),
                    }
                };
            }
        }
    }
    var tasksComplete: std.atomic.Value(u32) = .init(0);

    //TODO use async when it is added instead of this
    pub fn UpdateEntitiesThread(self: *@This(), interval_ns: u64) void {
        const enbktamount = self.Entitys.buckets.len;
        var st = std.time.nanoTimestamp();
        while (self.running.load(.seq_cst)) {
            const AddEntitiesToTick = ztracy.ZoneNC(@src(), "AddEntitiesToTick", 45354345);
            tasksComplete.store(0, .seq_cst);
            for (0..enbktamount) |bucket| {
                self.threadPool.spawn(TickEntitiesBucketTask, .{ self, &tasksComplete, bucket, self.allocator }, .VeryHigh) catch std.debug.panic("error adding task to pool", .{});
            }
            AddEntitiesToTick.End();
            std.Thread.sleep(interval_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
            st = std.time.nanoTimestamp();
            const WaitingForTasksToComplete = ztracy.ZoneNC(@src(), "WaitingForTasksToComplete", 2344326);
            var c: u32 = 0;
            while (tasksComplete.load(.seq_cst) < enbktamount and self.running.load(.monotonic)) { //checks if all tasks finished before spawning new ones, check if running because the tasks exit if its not
                std.Thread.yield() catch {};
                c += 1;
                if (c > 10000) break; //temporary very bad workaround for a bug in the threadpool
                //I think the bug is that popFirst in the queue might not return an item if their is one if it got out of sync
                //Im not fixing it now because I will switch to the Io async when 0.16 is released, entity updates will happen every frame for clients while chunks are being drawn and meshes loaded
            }
            WaitingForTasksToComplete.End();
        }
    }

    ///adds a ref and returns a chunk, generates it if it dosent exist and puts the chunk in the world hashmap. ref must be removed if not using chunk
    pub fn loadChunk(self: *@This(), Pos: ChunkPos, structures: bool) error{ OutOfMemory, AllSourcesFailed, Unrecoverable }!*Chunk {
        const lc = ztracy.ZoneNC(@src(), "loadChunk", 222222);
        defer lc.End();
        const chunk = self.Chunks.getandaddref(Pos);
        if (chunk == null) {
            var blocks: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
            try self.getBlocks(Pos, &blocks);
            const chunkptr: *Chunk = try .from(try .fromBlocks(&blocks, self.allocator), self.allocator);
            _ = chunkptr.add_ref();
            std.debug.assert(chunkptr.ref_count.load(.seq_cst) == 2);
            const existing = self.Chunks.putNoOverrideaddRef(Pos, chunkptr) catch |err| {
                chunkptr.free(self.allocator);
                self.allocator.destroy(chunkptr);
                return err;
            };
            //chptr is in hashmap past this point
            if (existing) |d| {
                chunkptr.release(); //ref was added before putting
                chunkptr.free(self.allocator);
                self.allocator.destroy(chunkptr);
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

    pub fn UnloadUnusedChunks(self: *@This(), unload_timeout: u64) !void {
        const unloadChunks = ztracy.ZoneNC(@src(), "unloadChunks", 1125878);
        defer unloadChunks.End();
        const bktamount = self.Chunks.buckets.len;
        var chunks: u64 = 0;
        if (1 == 1) return;//if this is still here i frogot to remov it
        var unload_chunk_buffer: [128]ChunkPos = undefined;
        for (0..bktamount) |b| {
            var tounload: std.ArrayList(ChunkPos) = .initBuffer(&unload_chunk_buffer);
            {
                self.Chunks.buckets[b].lock.lockShared();
                defer self.Chunks.buckets[b].lock.unlockShared();

                var it = self.Chunks.buckets[b].hash_map.iterator();
                const currenttime = std.time.microTimestamp();
                while (it.next()) |c| {
                    chunks += 1;
                    const chunk = c.value_ptr.*;
                    const lastaccess = chunk.last_access.load(.monotonic);
                    if (currenttime - lastaccess < unload_timeout) continue;
                    tounload.appendBounded(c.key_ptr.*) catch break;
                }
            }
            while (tounload.pop()) |Pos| {
                try self.UnloadChunk(Pos);
            }
        }
    }

    pub fn ChunkUnloaderThread(self: *@This(), intervel_ns: u64, unload_timeout: u64) void {
        while (self.running.load(.monotonic)) {
            const unloadChunks = ztracy.ZoneNC(@src(), "unloadChunks", 223);
            defer unloadChunks.End();
            const st = std.time.nanoTimestamp();
            defer std.Thread.sleep(intervel_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
            self.UnloadUnusedChunks(unload_timeout) catch |err| std.debug.panic("err:{any}\n", .{err});
        }
    }

    pub const Reader = struct {
        world: *World,
        lastChunkReadCache: ?struct { Pos: ChunkPos, chunk: *Chunk } = null,
        ///returns a block at the given position, Clear must be called after a series of calls to unlock the cached chunk
        ///better for many block reads
        pub inline fn GetBlockCached(self: *@This(), blockpos: BlockPos, level: i32) !Block {
            const chunkPos: ChunkPos = .fromLocalBlockPos(blockpos, level);
            const chunkBlockPos: @Vector(3, usize) = @intCast(@mod(blockpos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
            if (self.lastChunkReadCache == null or !std.meta.eql(self.lastChunkReadCache.?.Pos, chunkPos)) {
                self.Clear();
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
        pub inline fn GetBlockNoCache(self: *@This(), blockpos: BlockPos, level: i32) !Block {
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

        pub fn Clear(self: *@This()) void {
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
        editBuffer: std.AutoHashMapUnmanaged(ChunkPos, [ChunkSize][ChunkSize][ChunkSize]Block) = .{},
        tempallocator: std.mem.Allocator,
        level: i32,

        ///applies the edits in the buffer to the world, frees any temporary allocations
        pub fn flush(self: *@This()) !void {
            const flushh = ztracy.ZoneNC(@src(), "flush", 3563456);
            defer flushh.End();
            self.editBuffer.lockPointers();
            defer self.editBuffer.clearAndFree(self.tempallocator);
            defer self.editBuffer.unlockPointers();
            var it = self.editBuffer.iterator();
            var neghborsToRemesh: std.AutoHashMap(ChunkPos, void) = .init(self.tempallocator);
            defer neghborsToRemesh.deinit();
            while (it.next()) |diffChunk| {
                const encoding: Chunk.BlockEncoding = if (Chunk.IsOneBlock(diffChunk.value_ptr)) |oneBlock| .{ .oneBlock = oneBlock } else .{ .blocks = diffChunk.value_ptr };
                const chunk = try self.world.loadChunk(diffChunk.key_ptr.*, false);
                defer chunk.release();
                var sides: [6][ChunkSize][ChunkSize]Block = undefined;
                inline for (0..6) |side| {
                    sides[side] = chunk.extractFace(@enumFromInt(side), false);
                }
                try chunk.Merge(encoding, self.world.allocator, true);

                if (self.propagateChanges) {
                    var coords = diffChunk.key_ptr.*;
                    for (0..3) |_| {
                        var propagationEditor: @This() = .{ .propagateChanges = false, .level = coords.level + 1, .world = self.world, .tempallocator = self.tempallocator };
                        try propagationEditor.propagateToParentByCoords(coords);
                        try propagationEditor.flush();
                        coords = coords.parent();
                    }
                }
                var sides2: [6][ChunkSize][ChunkSize]Block = undefined;
                inline for (0..6) |side| {
                    sides2[side] = chunk.extractFace(@enumFromInt(side), false);
                }
                try neghborsToRemesh.put(diffChunk.key_ptr.*, {});
                if (self.world.onEdit.?.callIfNeighborFacesChanged) {
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
            var rit = neghborsToRemesh.iterator();
            while (rit.next()) |pos| {
                if (self.world.onEdit) |onEdit| onEdit.onEditFn(pos.key_ptr.*, onEdit.onEditFnArgs);
            }
        }

        pub inline fn placeBlock(self: *@This(), block: Block, pos: @Vector(3, i64)) !void {
            const chunkPos: ChunkPos = .fromLocalBlockPos(pos, self.level);
            const chunkBlockPos: @Vector(3, usize) = @intCast(@mod(pos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
            if (self.lastChunkCache != null and std.meta.eql(self.lastChunkCache.?.Pos, chunkPos)) {
                @branchHint(.likely);
                self.lastChunkCache.?.blocks[chunkBlockPos[0]][chunkBlockPos[1]][chunkBlockPos[2]] = block;
                return;
            }

            var chunk = (try self.editBuffer.getOrPutValue(self.tempallocator, chunkPos, comptime @splat(@splat(@splat(.Null))))).value_ptr;
            self.lastChunkCache = .{ .Pos = chunkPos, .blocks = chunk };
            chunk[(chunkBlockPos[0])][(chunkBlockPos[1])][(chunkBlockPos[2])] = block;
        }

        pub fn placeSamplerShape(self: *@This(), block: Block, shape: anytype) !void {
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
                            try self.placeBlock(block, i64blockpos);
                        }
                    }
                }
            }
        }

        const simplified_size = ChunkSize / TreeDivisions;

        pub fn propagateToParent(self: *@This(), chunk: *Chunk, Pos: ChunkPos) !void {
            const parent_pos = Pos.parent();
            std.debug.assert(self.level == parent_pos.level);
            var simplified_blocks: [simplified_size][simplified_size][simplified_size]Block = undefined;
            var isoneblock: bool = false;
            chunk.lockShared();
            defer chunk.unlockShared();
            switch (chunk.blocks) {
                .blocks => |blocks| {
                    simplified_blocks = simplifyBlocksAvg(blocks);
                },
                .oneBlock => |block| {
                    simplified_blocks = @splat(@splat(@splat(block)));
                    isoneblock = true;
                },
            }
            const block_pos = parent_pos.toLocalBlockPos() + Pos.posInParent() * @as(@Vector(3, u8), @splat(simplified_size));
            const parent = try self.world.loadChunk(parent_pos, false);
            if (isoneblock) {
                parent.lockShared();
                defer parent.unlockShared();
                if (parent.blocks == .oneBlock and parent.blocks.oneBlock == simplified_blocks[0][0][0]) return;
            }
            parent.lockExclusive();
            defer parent.releaseAndUnlock();
            _ = try parent.ToBlocks(self.world.allocator, false);
            for (0..simplified_size) |x| {
                for (0..simplified_size) |y| {
                    for (0..simplified_size) |z| {
                        const world_pos = @Vector(3, i64){ block_pos[0] + @as(i64, @intCast(x)), block_pos[1] + @as(i64, @intCast(y)), block_pos[2] + @as(i64, @intCast(z)) };
                        try self.placeBlock(simplified_blocks[x][y][z], world_pos);
                    }
                }
            }
        }

        pub fn propagateToParentByCoords(self: *@This(), chunk_pos: ChunkPos) !void {
            const chunk = try self.world.loadChunk(chunk_pos, false);
            try self.propagateToParent(chunk, chunk_pos);
        }

        fn simplifyBlocksAvg(
            blocks: *const [ChunkSize][ChunkSize][ChunkSize]Block,
        ) [simplified_size][simplified_size][simplified_size]Block {
            var simplified: [simplified_size][simplified_size][simplified_size]Block = undefined;

            for (0..simplified_size) |sx| {
                for (0..simplified_size) |sy| {
                    for (0..simplified_size) |sz| {
                        var unique_blocks: [8]Block = undefined;
                        var counts: [8]u8 = [_]u8{0} ** 8;
                        var unique_len: u8 = 0;

                        const bx0 = sx * TreeDivisions;
                        const by0 = sy * TreeDivisions;
                        const bz0 = sz * TreeDivisions;

                        for (0..TreeDivisions) |dx| {
                            for (0..TreeDivisions) |dy| {
                                for (0..TreeDivisions) |dz| {
                                    const b = blocks[bx0 + dx][by0 + dy][bz0 + dz];

                                    var found = false;
                                    var i: u8 = 0;
                                    while (i < unique_len) : (i += 1) {
                                        if (unique_blocks[i] == b) {
                                            counts[i] += 1;
                                            found = true;
                                            break;
                                        }
                                    }

                                    if (!found) {
                                        unique_blocks[unique_len] = b;
                                        counts[unique_len] = 1;
                                        unique_len += 1;
                                    }
                                }
                            }
                        }

                        // find most common
                        var best_i: u8 = 0;
                        var best_count: u8 = 0;

                        var i: u8 = 0;
                        while (i < unique_len) : (i += 1) {
                            if (counts[i] > best_count) {
                                best_count = counts[i];
                                best_i = i;
                            }
                        }

                        simplified[sx][sy][sz] = unique_blocks[best_i];
                    }
                }
            }

            return simplified;
        }
    };

    pub fn UnloadChunk(self: *@This(), Pos: ChunkPos) !void {
        const chunk = self.Chunks.fetchremove(Pos) orelse return; //removed from hashmap, no refs added or removed because they would cancel out
        try self.UnloadChunkByPtr(chunk, Pos);
    }

    pub fn UnloadChunkNoSave(self: *@This(), Pos: ChunkPos) void {
        const chunk = self.Chunks.fetchremove(Pos) orelse return; //removed from hashmap, no refs added or removed because they would cancel out
        self.UnloadChunkByPtrNoSave(chunk);
    }

    ///dosent remove chunk from hashmap, just frees it
    pub fn UnloadChunkByPtr(self: *@This(), chunk: *Chunk, Pos: ChunkPos) !void {
        try onUnload(self, chunk, Pos);
        _ = chunk.WaitForRefAmount(1, null);
        _ = chunk.free(self.allocator);
        self.allocator.destroy(chunk);
    }

    pub fn UnloadChunkByPtrNoSave(self: *@This(), chunk: *Chunk) void {
        _ = chunk.WaitForRefAmount(1, null);
        _ = chunk.free(self.allocator);
        self.allocator.destroy(chunk);
    }

    pub fn stop(self: *@This()) void {
        self.running.store(false, .monotonic);
        if (self.entityUpdaterThread) |thread| thread.join();
        self.entityUpdaterThread = null;
    }

    pub fn Deinit(self: *@This()) void {
        const deinitWorld = ztracy.ZoneNC(@src(), "deinitWorld", 88124);
        defer deinitWorld.End();
        self.stop();
        const bktamount = self.Chunks.buckets.len;
        for (0..bktamount) |b| {
            const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
            self.Chunks.buckets[b].lock.lock();
            lock.End();
            var it = self.Chunks.buckets[b].hash_map.iterator();
            defer self.Chunks.buckets[b].lock.unlock();
            while (it.next()) |c| {
                self.UnloadChunkByPtr(c.value_ptr.*, c.key_ptr.*) catch |err| std.log.err("error unloading chunk: {any}, {any}\n", .{ c.key_ptr.*, err });
            }
        }
        std.log.info("chunks unloaded", .{});
        const enbktamount = self.Entitys.buckets.len;
        for (0..enbktamount) |b| {
            const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
            self.Entitys.buckets[b].lock.lock();
            lock.End();
            var it = self.Entitys.buckets[b].hash_map.iterator();
            defer self.Entitys.buckets[b].lock.unlock();
            while (it.next()) |c| {
                c.value_ptr.*.unload(self, c.key_ptr.*, self.allocator, true) catch std.log.err("error unloading entity\n", .{});
            }
        }
        self.Entitys.deinit();
        std.log.info("entitys unloaded", .{});
        for (self.ChunkSources) |source| {
            if (source) |s| if (s.deinit) |deinit| deinit(s, self);
        }

        self.Chunks.deinit();
        std.log.info("world closed", .{});
    }
};

fn NormilizeInRange(num: anytype, oldLowerBound: anytype, oldUpperBound: anytype, newLowerBound: anytype, newUpperBound: anytype) @TypeOf(num, oldLowerBound, oldUpperBound, newLowerBound, newUpperBound) {
    return (num - oldLowerBound) / (oldUpperBound - oldLowerBound) * (newUpperBound - newLowerBound) + newLowerBound;
}
