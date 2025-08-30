const std = @import("std");
const ThreadPool = @import("root").ThreadPool;

const Block = @import("Block").Blocks;
const Cache = @import("Cache").Cache;
const Chunk = @import("Chunk").Chunk;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Entity = @import("Entity").Entity;
const EntityTypes = @import("EntityTypes");
const Renderer = @import("root").Renderer;
const ztracy = @import("ztracy");

const ChunkSize = 32;
pub const World = struct {
    allocator: std.mem.Allocator,
    threadPool: *ThreadPool,
    TerrainHeightCache: Cache([2]i32, [32][32]i32, 1024),
    SpawnRange: u32,
    SpawnCenterPos: [3]i32,
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
        const pos = [2]i32{ self.Rand.intRangeAtMost(i32, self.SpawnCenterPos[0] - @as(i32, @intCast(self.SpawnRange)), @as(i32, @intCast(self.SpawnRange))), self.Rand.intRangeAtMost(i32, self.SpawnCenterPos[2] - @as(i32, @intCast(self.SpawnRange)), @as(i32, @intCast(self.SpawnRange))) };
        const chunkPos = [2]i32{ @divFloor(pos[0], 32), @divFloor(pos[1], 32) };
        const posInChunk = [2]i32{ @mod(pos[0], 32), @mod(pos[1], 32) };
        const height = Chunk.GetTerrainHeight([2]i32{ chunkPos[0], chunkPos[1] }, self.GenParams, &self.TerrainHeightCache)[@intCast(posInChunk[0])][@intCast(posInChunk[1])];
        return @Vector(3, f64){ @floatFromInt(pos[0]), @floatFromInt(height), @floatFromInt(pos[1]) };
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
            if (structures and chunk.?.genstate.load(.seq_cst) == .TerrainGenerated) GenerateStructures(self, chunk.?, Pos, renderer) catch std.debug.panic("err", .{});
            return chunk.?;
        }
    }
    fn GenerateStructures(self: *@This(), chunk: *Chunk, Pos: [3]i32, renderer: ?*Renderer) !void {
        const genstructures = ztracy.ZoneNC(@src(), "generate_structures", 94);
        defer genstructures.End();
        if (chunk.genstate.load(.seq_cst) != .TerrainGenerated) return;
        defer chunk.genstate.store(.StructuresGenerated, .seq_cst);
        var random = std.Random.DefaultPrng.init(0); //TODO make seed hash of Pos and world seed
        const rand = random.random();
        if (chunk.blocks == .blocks) {
            for (0..ChunkSize) |x| {
                for (0..ChunkSize) |z| {
                    for (0..ChunkSize) |y| {
                        if (chunk.blocks.blocks[x][y][z] == .Grass and rand.int(u8) > 250) {
                            try self.PrintStructure(((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize })) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) }, renderer, GenChunkCube, CubeState, 8, chunk, Pos);
                        }
                    }
                }
            }
        }
        //if (Pos[1] == 20) try self.GenStructure((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize }), renderer, GenChunkCube, CubeState, 8, chunk, Pos);
        //   if (@mod(Pos[0], 2) == 0 and Pos[1] == 21 and @mod(Pos[2], 2) == 0) try self.GenStructure((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize }), renderer, GenChunkCube, CubeState, 16, chunk, Pos);
        //  if (@mod(Pos[0], 4) == 0 and Pos[1] == 22 and @mod(Pos[2], 4) == 0) try self.GenStructure((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize }), renderer, GenChunkCube, CubeState, 32, chunk, Pos);
        // if (@mod(Pos[0], 8) == 0 and Pos[1] == 25 and @mod(Pos[2], 8) == 0) try self.GenStructure((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize }), renderer, GenChunkCube, CubeState, 64, chunk, Pos);
        //    if (@mod(Pos[0], 12) == 0 and Pos[1] == 30 and @mod(Pos[2], 12) == 0) try self.GenStructure((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize }), renderer, GenChunkCube, CubeState, 128, chunk, Pos);
        //   if (@mod(Pos[0], 24) == 0 and Pos[1] == 38 and @mod(Pos[2], 24) == 0) try self.GenStructure((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize }), renderer, GenChunkCube, CubeState, 256, chunk, Pos);
        //  if (@mod(Pos[0], 64) == 0 and Pos[1] == 50 and @mod(Pos[2], 64) == 0) try self.GenStructure((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize }), renderer, GenChunkCube, CubeState, 512, chunk, Pos);
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

    threadlocal var PrintStructureBuffer: [500000]u8 = undefined;
    ///generates and places a structure at the given position, mainChunk is a chunk out of the hashmap that will be treated as the chunk at its pos, mainchunk cannot be locked. remeshes if there is a renderer. dosent remesh mainchunk
    pub fn PrintStructure(self: *@This(), BlockPos: @Vector(3, i64), renderer: ?*Renderer, GenStructure: fn (state: anytype, genParams: anytype) ?step, GenState: type, GenParams: anytype, mainChunk: ?*Chunk, mainChunkPos: ?[3]i32) !void {
        const genstructures = ztracy.ZoneNC(@src(), "genstructure", 4369);
        defer genstructures.End();
        //std.debug.print("genstruct at {d}, {d}, {d}\n", .{ BlockPos[0], BlockPos[1], BlockPos[2] });
        var fb = std.heap.FixedBufferAllocator.init(&PrintStructureBuffer);
        const fba = fb.allocator();
        var ChunkMap = std.AutoArrayHashMap([3]i32, *Chunk).init(fba);
        defer ChunkMap.deinit();
        var NeghborsToRemeshMap = std.AutoArrayHashMap([3]i32, void).init(fba);
        defer NeghborsToRemeshMap.deinit();

        if (mainChunk != null) {
            mainChunk.?.add_ref();
            //   mainChunk.?.lock.lock();
            if (mainChunk.?.blocks != .blocks) {
                std.debug.assert(mainChunk.?.blocks == .oneBlock);
                try mainChunk.?.ToBlocks(self.allocator);
            }
            ChunkMap.put(mainChunkPos.?, mainChunk.?) catch |err| {
                std.debug.panic("error putting chunk into hashmap: {any}", .{err});
            };
        }
        var chunk: ?*Chunk = undefined;

        var blocks: *[ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        var lastchunkpos: ?@Vector(3, i32) = null;
        var chunkLock: ?*std.Thread.RwLock = null; //if it is not null its locked
        defer {
            var it = ChunkMap.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.release();
            }
            if (renderer != null) { //bug is caused by every neghbor needing to be remeshed TODO fix
                it = ChunkMap.iterator();
                while (it.next()) |entry| {
                    if (mainChunkPos == null or @reduce(.Or, @as(@Vector(3, i32), entry.key_ptr.*) != @as(@Vector(3, i32), mainChunkPos.?))) {
                        renderer.?.AddChunkToRender(entry.key_ptr.*, false) catch |err| {
                            std.log.err("error adding chunk to render: {any}", .{err});
                        };
                    }
                }
                var it2 = NeghborsToRemeshMap.iterator();
                while (it2.next()) |entry| {
                    renderer.?.AddChunkToRender(entry.key_ptr.*, false) catch |err| {
                        std.log.err("error adding chunk to render: {any}", .{err});
                    };
                }
            }
        }
        var structureGenData: GenState = .{};
        const loop = ztracy.ZoneNC(@src(), "loop", 454369);
        defer loop.End();
        while (GenStructure(&structureGenData, GenParams)) |nextstep| {
            const nextblockpos = nextstep.pos + BlockPos;
            const nextchunk: @Vector(3, i32) = @intCast(@divFloor(nextblockpos, @Vector(3, i64){ 32, 32, 32 }));
            const nextchunkblockpos = @mod(nextblockpos, @Vector(3, i64){ 32, 32, 32 });
            if (lastchunkpos == null or @reduce(.Or, lastchunkpos.? != nextchunk)) {
                if (chunkLock != null) {
                    chunkLock.?.unlock();
                    chunkLock = null;
                }
                chunk = ChunkMap.get(nextchunk);
                if (chunk == null) {
                    chunk = self.LoadChunk(nextchunk, null, false);
                    chunk.?.lock.lockShared();
                    const blockEncoding = chunk.?.blocks;
                    chunk.?.lock.unlockShared();
                    if (blockEncoding != .blocks) {
                        chunk.?.lock.lock();
                        defer chunk.?.lock.unlock();
                        if (chunk.?.blocks != .blocks) try chunk.?.ToBlocks(self.allocator);
                    }
                    try ChunkMap.put(nextchunk, chunk.?);
                }
                if (chunk != null) {
                    std.debug.assert(chunkLock == null);
                    chunkLock = &chunk.?.lock;
                    chunkLock.?.lock();
                }
            }
            blocks = chunk.?.blocks.blocks;
            lastchunkpos = nextchunk;
            blocks[@intCast(nextchunkblockpos[0])][@intCast(nextchunkblockpos[1])][@intCast(nextchunkblockpos[2])] = nextstep.block;
            const e0 = nextchunkblockpos == @Vector(3, i64){ 0, 0, 0 };
            const e1 = nextchunkblockpos == @Vector(3, i64){ 31, 31, 31 };
            if (@reduce(.Or, e0) or @reduce(.Or, e1)) {
                //  std.debug.print("e0: {any} = pos - {any}, e1: {any}, ncbp: {any}\n", .{ e0, @as(@Vector(3, i32), @intFromBool(e0)), e1, nextchunkblockpos });
                for (0..3) |i| {
                    if (e0[i]) {
                        try NeghborsToRemeshMap.put(nextchunk - @as(@Vector(3, i32), @intFromBool(e0)), void{});
                    }
                    if (e1[i]) {
                        try NeghborsToRemeshMap.put(nextchunk + @as(@Vector(3, i32), @intFromBool(e1)), void{});
                    }
                }
            }
        }
        if (chunkLock != null) {
            chunkLock.?.unlock();
            chunkLock = null;
        }
    }

    pub const Structure = enum {
        eightcube,
        chunkcube,
        fourchunkcube,
    };

    pub fn GenChunkCube(state: anytype, genParams: anytype) ?step {
        var State: *CubeState = state;
        const stage = State.stage;
        State.stage += 1;
        if (stage >= (genParams * genParams * genParams)) return null;
        return step{ .block = .Dirt, .pos = .{ @divFloor(stage, genParams * genParams), @mod(@divFloor(stage, genParams), genParams), @mod(stage, genParams) } };
    }

    const CubeState = struct {
        stage: i64 = 0,
    };

    pub fn GenTestTree(state: anytype, genParams: anytype) ?step {
        var State: *TestTreeState = state;
        const stage = State.stage;
        State.stage += 1;
        if (stage >= (genParams.height)) return null;
        return step{ .block = .Wood, .pos = .{ 0, stage, 0 } };
    }

    const TestTreeState = struct {
        stage: i64 = 0,
    };

    const TreeGenParams = struct {
        height: u32,
    };

    pub const step = struct { block: Block, pos: @Vector(3, i64) };

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
        self.Chunks.deinit();
        const enbktamount = self.Entitys.buckets.len;
        for (0..enbktamount) |b| {
            self.Entitys.buckets[b].lock.lock();
            var it = self.Entitys.buckets[b].hash_map.valueIterator();
            defer self.Entitys.buckets[b].lock.unlock();
            while (it.next()) |c| {
                //  std.debug.print("freed: {any}\n", .{c.*.*});
                c.*.fullfree(self.allocator);
            }
        }
        self.Entitys.deinit();
        self.TerrainHeightCache.deinit();
    }
};
