const std = @import("std");
const Renderer = @import("root").Renderer;
const ThreadPool = @import("root").ThreadPool;

pub const Block = @import("Block").Blocks;
const Cache = @import("Cache").Cache;
const Chunk = @import("Chunk").Chunk;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Entity = @import("Entity").Entity;
const EntityTypes = @import("EntityTypes");
const ztracy = @import("ztracy");

const Structures = @import("Structures.zig");

const ChunkSize = 32;
pub const World = struct {
    allocator: std.mem.Allocator,
    threadPool: *ThreadPool,
    TerrainHeightCache: Cache([2]i32, [32][32]i32, 8192),
    SpawnRange: u32,
    SpawnCenterPos: @Vector(3, f64),
    Rand: std.Random,
    Entitys: ConcurrentHashMap(u128, *Entity, std.hash_map.AutoContext(u128), 80, 32),
    Chunks: ConcurrentHashMap([3]i32, *Chunk, std.hash_map.AutoContext([3]i32), 80, 32),
    GenParams: Chunk.GenParams,

    pub fn PlayerIDtoEntityId(playerID: u128) u128 {
        return std.hash.int(playerID);
    }
    pub fn UnloadEntity(self: *@This(), entityUUID: u128) !void {
        const en = self.Entitys.fetchremoveandaddref(entityUUID) orelse return;
        en.WaitForRefAmount(1, null); //already done in fullfree but i am doing it here so there will be 1 ref when saving
        en.lock.lock();
        //TODO save entity to disk
        en.fullfree(self.allocator);
    }

    pub fn SpawnEntity(self: *@This(), UUID: u128, entity: anytype) !?*Entity {
        if (self.Entitys.contains(UUID)) return error.EntityAlreadyExists;
        const allocated_entity = try entity.MakeEntity(self.allocator);
        errdefer allocated_entity.fullfree(self.allocator);
        const existing = try self.Entitys.putNoOverrideaddRef(UUID, allocated_entity);
        if (existing) |_| {
            allocated_entity.fullfree(self.allocator);
            return null;
        }

        return allocated_entity;
    }

    pub fn GetPlayerSpawnPos(self: *@This()) @Vector(3, f64) {
        const pos = @Vector(2, i32){ @intFromFloat(self.SpawnCenterPos[0]), @intFromFloat(self.SpawnCenterPos[2]) } + @Vector(2, i32){ self.Rand.intRangeAtMost(i32, -@as(i32, @intCast(self.SpawnRange)), @as(i32, @intCast(self.SpawnRange))), self.Rand.intRangeAtMost(i32, -@as(i32, @intCast(self.SpawnRange)), @as(i32, @intCast(self.SpawnRange))) };
        const chunkPos = [2]i32{ @divFloor(pos[0], 32), @divFloor(pos[1], 32) };
        const posInChunk = [2]i32{ @mod(pos[0], 32), @mod(pos[1], 32) };
        const height = Chunk.GetTerrainHeight([2]i32{ chunkPos[0], chunkPos[1] }, self.GenParams, &self.TerrainHeightCache)[@intCast(posInChunk[0])][@intCast(posInChunk[1])];
        std.debug.print("Player spawn pos: {d}, {d}, {d}\n", .{ pos[0], height, pos[1] });
        return @Vector(3, f64){ @floatFromInt(pos[0]), @floatFromInt(height), @floatFromInt(pos[1]) };
    }

    pub fn GetTerrainHeightAtCoords(self: *@This(), pos: @Vector(2, i64)) i64 {
        const chunkPos = [2]i32{ @intCast(@divFloor(pos[0], 32)), @intCast(@divFloor(pos[1], 32)) };
        const posInChunk = [2]i32{ @intCast(@mod(pos[0], 32)), @intCast(@mod(pos[1], 32)) };
        const height = Chunk.GetTerrainHeight([2]i32{ chunkPos[0], chunkPos[1] }, self.GenParams, &self.TerrainHeightCache)[@intCast(posInChunk[0])][@intCast(posInChunk[1])];
        return height;
    }

    pub fn TickEntitys(self: *@This()) !void {
        const bktamount = self.Entitys.buckets.len;
        for (0..bktamount) |b| {
            self.Entitys.buckets[b].lock.lockShared();
            var it = self.Entitys.buckets[b].hash_map.valueIterator();
            defer self.Entitys.buckets[b].lock.unlockShared();
            while (it.next()) |entity| {
                entity.*.ref_count.fetchAdd(1, .seq_cst);
                defer entity.*.ref_count.fetchSub(1, .seq_cst);
                entity.*.lock.lock();
                defer entity.*.lock.unlock();
                entity.GetActive().update();
            }
        }
    }
    ///adds a ref and returns a chunk, generates it if it dosent exist and puts the chunk in the world hashmap. ref must be removed if not using chunk
    pub fn LoadChunk(self: *@This(), Pos: [3]i32, renderer: ?*Renderer, structures: bool) *Chunk {
        const loadChunk = ztracy.ZoneNC(@src(), "loadChunk", 222222);
        defer loadChunk.End();
        const chunk = self.Chunks.getandaddref(Pos);
        if (chunk == null) {
            const ch = Chunk.GenChunk(Pos, &self.TerrainHeightCache, self.GenParams, self.allocator) catch std.debug.panic("err", .{});
            const ad = ztracy.ZoneNC(@src(), "allocChunkStruct", 234313);
            var chunkptr: *Chunk = self.allocator.create(Chunk) catch std.debug.panic("err", .{});
            ad.End();
            chunkptr.* = ch;
            if (structures) {
                GenerateStructures(self, chunkptr, Pos, renderer) catch std.debug.panic("err", .{});
                std.debug.assert(chunkptr.genstate.load(.seq_cst) == .StructuresGenerated);
            }
            _ = chunkptr.ref_count.fetchAdd(1, .seq_cst);
            std.debug.assert(chunkptr.ref_count.load(.seq_cst) == 2);
            const existing = self.Chunks.putNoOverrideaddRef(Pos, chunkptr) catch std.debug.panic("err", .{}); //duplacate can happen with 2 simultanius loads, both detect no chunk in hashmap
            //chptr is in hashmap past this point
            if (existing) |d| {
                @branchHint(.unlikely);
                // chunkptr.lock.unlock();
                chunkptr.release(); //ref was added before putting
                _ = chunkptr.free(self.allocator);
                self.allocator.destroy(chunkptr);
                return d;
            }
            return chunkptr;
        } else {
            if (structures and chunk.?.genstate.load(.seq_cst) == .TerrainGenerated) {
                GenerateStructures(self, chunk.?, Pos, renderer) catch std.debug.panic("err", .{});
            }
            return chunk.?;
        }
    }
    threadlocal var stackfallback: std.heap.StackFallbackAllocator(500_000) = undefined;
    fn GenerateStructures(self: *@This(), chunk: *Chunk, Pos: [3]i32, renderer: ?*Renderer) !void {
        const genstructures = ztracy.ZoneNC(@src(), "generate_structures", 94);
        defer genstructures.End();
        if (chunk.genstate.load(.seq_cst) != .TerrainGenerated) return;
        defer chunk.genstate.store(.StructuresGenerated, .seq_cst);
        const randomSeed = std.hash.Wyhash.hash(self.GenParams.seed, std.mem.asBytes(&Pos));
        var random = std.Random.DefaultPrng.init(randomSeed);
        const rand = random.random();
        stackfallback = std.heap.StackFallbackAllocator(500_000){ .fallback_allocator = self.allocator, .buffer = undefined, .fixed_buffer_allocator = undefined };
        const sfa = stackfallback.get();
        var worldEditor = try WorldEditor.init(self, renderer, chunk, Pos, sfa);
        defer _ = worldEditor.deinit();
        var structuresGenerated: u32 = 0;
        if (chunk.blocks == .blocks) {
            for (0..ChunkSize) |x| {
                for (0..ChunkSize) |z| {
                    for (0..ChunkSize) |y| {
                        if (chunk.blocks.blocks[x][y][z] == .Grass) {
                            const treeChance: f64 = rand.float(f64);

                            if (treeChance < 0.00001) {
                                structuresGenerated += 1;
                                const factor = (rand.float(f32) * 2) + 0.5;
                                try PrintStructure(&worldEditor, ((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize })) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) }, Structures.GenGiantTree, Structures.GiantTreeState, Structures.GiantTreeGenParams{
                                    .height = @intFromFloat(100 * factor),
                                    .base_radius = @intFromFloat(15 * factor),
                                    .main_branches = 0,
                                    .branch_length = 0,
                                    .canopy_radius = @intFromFloat(30 * factor),
                                    .num_roots = 0,
                                    .top_radius_factor = 0.75,
                                    .branch_start_height_factor = 0.95,
                                    .root_length = 0,
                                });
                            } else if (treeChance < 0.00015) {
                                structuresGenerated += 1;
                                const factor = rand.float(f32) + 0.5;
                                try PrintStructure(&worldEditor, ((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize })) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) }, Structures.GenGiantTree, Structures.GiantTreeState, Structures.GiantTreeGenParams{
                                    .height = @intFromFloat(50 * factor),
                                    .base_radius = @intFromFloat(6 * factor),
                                    .main_branches = 0,
                                    .branch_length = 0,
                                    .canopy_radius = @intFromFloat(20 * factor),
                                    .num_roots = 6,
                                    .top_radius_factor = 0.75,
                                    .branch_start_height_factor = 0.90,
                                    .root_length = 3,
                                });
                            } else if (treeChance < 0.0015) {
                                structuresGenerated += 1;
                                const factor = rand.float(f32) + 0.5;
                                try PrintStructure(&worldEditor, ((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize })) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) }, Structures.GenGiantTree, Structures.GiantTreeState, Structures.GiantTreeGenParams{
                                    .height = @intFromFloat(25 * factor),
                                    .base_radius = @intFromFloat(@round(3 * factor)),
                                    .main_branches = 0,
                                    .branch_length = 0,
                                    .canopy_radius = @intFromFloat(12 * factor),
                                    .num_roots = 4,
                                    .top_radius_factor = 0.75,
                                    .branch_start_height_factor = 0.90,
                                    .root_length = 2,
                                });
                            }
                        }
                    }
                }
            }
        }
    }
    ///adds a ref and loads chunk, ref must be removed if not using chunk
    pub fn LoadChunkFromBlocks(self: *@This(), Pos: [3]i32, blocks: [ChunkSize][ChunkSize][ChunkSize]Block) !*Chunk {
        const chunk = self.Chunks.getandaddref(Pos);
        if (chunk == null) {
            const ch = Chunk{
                .blocks = self.allocator.dupe(u8, std.mem.asBytes(blocks)),
                .encoding = .Blocks,
                .lock = .{},
            };
            const chunkptr = try self.allocator.create(Chunk);
            chunkptr.* = ch;
            chunkptr.add_ref();
            try self.Chunks.put(Pos, chunkptr);
            return chunkptr;
        } else return chunk.?;
    }

    ///generates and places a structure at the given position, mainChunk is a chunk out of the hashmap that will be treated as the chunk at its pos, mainchunk cannot be locked. remeshes if there is a renderer. dosent remesh mainchunk
    pub fn PrintStructure(worldEditor: *WorldEditor, BlockPos: @Vector(3, i64), GenStructure: fn (state: anytype, genParams: anytype) ?WorldEditor.Step, GenState: type, GenParams: anytype) !void {
        const structure = ztracy.ZoneNC(@src(), "print_structure", 94);
        defer structure.End();
        var structureGenData: GenState = .{};
        while (GenStructure(&structureGenData, GenParams)) |nextstep| {
            var step = nextstep;
            step.pos += BlockPos;
            try worldEditor.PlaceBlock(step);
        }
    }

    pub const WorldEditor = struct {
        chunk: ?*Chunk = undefined,
        chunkMap: std.AutoArrayHashMap([3]i32, *Chunk),
        lastchunkpos: ?@Vector(3, i32),
        mainChunkPos: ?[3]i32,
        chunkLock: ?*std.Thread.RwLock, //if it is not null its locked
        renderer: ?*Renderer,
        world: *World,
        allocator: std.mem.Allocator,
        ///allocator only makes temporary allocations, stackfallbackallocator should be used. mainchunk must not be locked
        pub fn init(world: *World, renderer: ?*Renderer, mainChunk: ?*Chunk, mainChunkPos: ?[3]i32, allocator: std.mem.Allocator) !@This() {
            const initworld = ztracy.ZoneNC(@src(), "initEditor", 45453);
            defer initworld.End();
            var Editor = @This(){
                .renderer = renderer,
                .chunkMap = std.AutoArrayHashMap([3]i32, *Chunk).init(allocator),
                .chunkLock = null,
                .mainChunkPos = mainChunkPos,
                .chunk = null,
                .world = world,
                .lastchunkpos = null,
                .allocator = allocator,
            };
            if (mainChunk != null) {
                mainChunk.?.add_ref();
                Editor.chunkMap.put(mainChunkPos.?, mainChunk.?) catch |err| {
                    std.debug.panic("error putting chunk into hashmap: {any}", .{err});
                };
            }
            return Editor;
        }

        //clears and frees memory, returns amount of chunks remeshed
        pub fn deinit(self: *@This()) usize {
            const deinitworld = ztracy.ZoneNC(@src(), "deinitEditor", 43224);
            defer deinitworld.End();
            const remeshed = self.clear();
            self.chunkMap.deinit();
            return remeshed;
        }

        ///must be called after a series of actions to update renderer and empty chunk cache, returns amount remeshed
        pub fn clear(self: *@This()) usize {
            const clearworld = ztracy.ZoneNC(@src(), "clearEditor", 67556);
            defer clearworld.End();
            var remeshed: usize = 0;
            if (self.chunkLock != null) {
                self.chunkLock.?.unlock();
                self.chunkLock = null;
            }
            self.chunk = null;
            self.lastchunkpos = null;
            var it = self.chunkMap.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.release();
            }
            if (self.renderer != null) {
                it = self.chunkMap.iterator();
                while (it.next()) |entry| {
                    if (self.mainChunkPos == null or @reduce(.Or, @as(@Vector(3, i32), entry.key_ptr.*) != @as(@Vector(3, i32), self.mainChunkPos.?))) {
                        self.renderer.?.AddChunkToRender(entry.key_ptr.*, false) catch |err| {
                            std.log.err("error adding chunk to render: {any}", .{err});
                        };
                        remeshed += 1;
                    }
                }
            }
            var v: usize = 0;
            while (self.chunkMap.count() != @intFromBool(self.mainChunkPos != null)) {
                defer v += 1;

                var toClear: [100][3]i32 = undefined;
                var clearit = self.chunkMap.iterator();
                var i: usize = 0;
                while (clearit.next()) |entry| {
                    if (i >= toClear.len) break;
                    toClear[i] = entry.key_ptr.*;
                    i += 1;
                }
                for (toClear[0..i]) |chunkpos| {
                    if (self.mainChunkPos == null or !(chunkpos[0] == self.mainChunkPos.?[0] and chunkpos[1] == self.mainChunkPos.?[1] and chunkpos[2] == self.mainChunkPos.?[2])) _ = self.chunkMap.swapRemove(chunkpos);
                }
            }
            return remeshed;
        }

        pub fn PlaceBlock(self: *@This(), step: Step) !void {
            const nextblockpos = step.pos;
            const nextchunk: @Vector(3, i32) = @intCast(@divFloor(nextblockpos, @Vector(3, i64){ 32, 32, 32 }));
            const nextchunkblockpos = @mod(nextblockpos, @Vector(3, i64){ 32, 32, 32 });
            if (self.lastchunkpos == null or @reduce(.Or, self.lastchunkpos.? != nextchunk)) {
                if (self.chunkLock != null) {
                    self.chunkLock.?.unlock();
                    self.chunkLock = null;
                }
                self.chunk = self.chunkMap.get(nextchunk);
                if (self.chunk == null) {
                    self.chunk = self.world.LoadChunk(nextchunk, null, false);
                    self.chunk.?.lock.lockShared();
                    const blockEncoding = self.chunk.?.blocks;
                    self.chunk.?.lock.unlockShared();
                    if (blockEncoding != .blocks) {
                        if (self.chunk.?.blocks != .blocks) _ = try self.chunk.?.ToBlocks(self.world.allocator, true);
                    }
                    try self.chunkMap.put(nextchunk, self.chunk.?);
                }
                if (self.chunk != null) {
                    std.debug.assert(self.chunkLock == null);
                    self.chunkLock = &self.chunk.?.lock;
                    self.chunkLock.?.lock();
                }
            }
            self.lastchunkpos = nextchunk;
            std.debug.assert(self.chunkLock != null); //chunk is locked
            const blockEncoding = self.chunk.?.blocks;
            if (blockEncoding != .blocks) {
                std.debug.assert(self.chunkLock.? == &self.chunk.?.lock);
                if (self.chunk.?.blocks != .blocks) _ = try self.chunk.?.ToBlocks(self.world.allocator, false);
            }
            self.chunk.?.blocks.blocks[@intCast(nextchunkblockpos[0])][@intCast(nextchunkblockpos[1])][@intCast(nextchunkblockpos[2])] = step.block;
        }

        pub fn GetBlock(self: *@This(), blockpos: @Vector(3, i64)) !Block {
            const nextchunk: @Vector(3, i32) = @intCast(@divFloor(blockpos, @Vector(3, i64){ 32, 32, 32 }));
            const nextchunkblockpos = @mod(blockpos, @Vector(3, i64){ 32, 32, 32 });
            if (self.lastchunkpos == null or @reduce(.Or, self.lastchunkpos.? != nextchunk)) {
                if (self.chunkLock != null) {
                    self.chunkLock.?.unlock();
                    self.chunkLock = null;
                }
                self.chunk = self.chunkMap.get(nextchunk);
                if (self.chunk == null) {
                    self.chunk = self.world.LoadChunk(nextchunk, null, false);
                    try self.chunkMap.put(nextchunk, self.chunk.?);
                }
                if (self.chunk != null) {
                    std.debug.assert(self.chunkLock == null);
                    self.chunkLock = &self.chunk.?.lock;
                    self.chunkLock.?.lock();
                }
            }
            self.lastchunkpos = nextchunk;
            const blockEncoding = self.chunk.?.blocks;
            if (blockEncoding == .blocks) {
                return self.chunk.?.blocks.blocks[@intCast(nextchunkblockpos[0])][@intCast(nextchunkblockpos[1])][@intCast(nextchunkblockpos[2])];
            } else if (blockEncoding == .oneBlock) {
                return self.chunk.?.blocks.oneBlock;
            } else unreachable;
        }

        pub const Step = struct { block: Block, pos: @Vector(3, i64) };
    };

    pub fn UnloadChunk(self: *@This(), Pos: [3]i32) !void {
        const chunk = self.Chunks.fetchremoveandaddref(Pos) orelse return; //removed from hashmap, no refs added or removed because they would cancel out
        _ = chunk.WaitForRefAmount(1, null);
        _ = chunk.free(self.allocator);
        self.allocator.destroy(chunk);
    }
    ///dosent remove chunk from hashmap, just frees it
    pub fn UnloadChunkByPtr(self: *@This(), chunk: *Chunk) !void {
        _ = chunk.WaitForRefAmount(1, null);
        _ = chunk.free(self.allocator);
    }

    pub fn Deinit(self: *@This()) !void {
        const deinitWorld = ztracy.ZoneNC(@src(), "deinitWorld", 88124);
        defer deinitWorld.End();
        const bktamount = self.Chunks.buckets.len;
        for (0..bktamount) |b| {
            self.Chunks.buckets[b].lock.lock();
            var it = self.Chunks.buckets[b].hash_map.valueIterator();
            defer self.Chunks.buckets[b].lock.unlock();
            while (it.next()) |c| {
                try self.UnloadChunkByPtr(c.*);
                self.allocator.destroy(c.*);
            }
        }
        const enbktamount = self.Entitys.buckets.len;
        for (0..enbktamount) |b| {
            self.Entitys.buckets[b].lock.lock();
            var it = self.Entitys.buckets[b].hash_map.valueIterator();
            defer self.Entitys.buckets[b].lock.unlock();
            while (it.next()) |c| {
                c.*.fullfree(self.allocator);
            }
        }
        self.Entitys.deinit();
        self.TerrainHeightCache.deinit();
        self.Chunks.deinit();
    }
};
