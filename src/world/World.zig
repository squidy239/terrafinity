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

const ChunkSize = Chunk.ChunkSize;
pub const World = struct {
    pub const Structures = @import("Structures.zig");
    allocator: std.mem.Allocator,
    threadPool: *ThreadPool,
    TerrainHeightCache: Cache([2]i32, [ChunkSize][ChunkSize]i32, 8192),
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
        const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
        en.lock.lock();
        lock.End();
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
        const chunkPos = [2]i32{ @divFloor(pos[0], ChunkSize), @divFloor(pos[1], ChunkSize) };
        const posInChunk = [2]i32{ @mod(pos[0], ChunkSize), @mod(pos[1], ChunkSize) };
        const height = Chunk.GetTerrainHeight([2]i32{ chunkPos[0], chunkPos[1] }, self.GenParams, &self.TerrainHeightCache)[@intCast(posInChunk[0])][@intCast(posInChunk[1])];
        std.debug.print("Player spawn pos: {d}, {d}, {d}\n", .{ pos[0], height, pos[1] });
        return @Vector(3, f64){ @floatFromInt(pos[0]), @floatFromInt(height), @floatFromInt(pos[1]) };
    }

    pub fn GetTerrainHeightAtCoords(self: *@This(), pos: @Vector(2, i64)) i64 {
        const chunkPos = [2]i32{ @intCast(@divFloor(pos[0], ChunkSize)), @intCast(@divFloor(pos[1], ChunkSize)) };
        const posInChunk = [2]i32{ @intCast(@mod(pos[0], ChunkSize)), @intCast(@mod(pos[1], ChunkSize)) };
        const height = Chunk.GetTerrainHeight([2]i32{ chunkPos[0], chunkPos[1] }, self.GenParams, &self.TerrainHeightCache)[@intCast(posInChunk[0])][@intCast(posInChunk[1])];
        return height;
    }

    pub fn TickEntitys(self: *@This()) !void {
        const bktamount = self.Entitys.buckets.len;
        for (0..bktamount) |b| {
            const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
            self.Entitys.buckets[b].lock.lockShared();
            lock.End();
            var it = self.Entitys.buckets[b].hash_map.valueIterator();
            defer self.Entitys.buckets[b].lock.unlockShared();
            while (it.next()) |entity| {
                entity.*.ref_count.fetchAdd(1, .seq_cst);
                defer entity.*.ref_count.fetchSub(1, .seq_cst);
                const locke = ztracy.ZoneNC(@src(), "lockEntity", 2222111);
                entity.*.lock.lock();
                locke.End();
                defer entity.*.lock.unlock();
                entity.GetActive().update();
            }
        }
    }
    ///adds a ref and returns a chunk, generates it if it dosent exist and puts the chunk in the world hashmap. ref must be removed if not using chunk
    pub fn LoadChunk(self: *@This(), Pos: [3]i32, renderer: ?*Renderer, structures: bool) !*Chunk {
        const loadChunk = ztracy.ZoneNC(@src(), "loadChunk", 222222);
        defer loadChunk.End();
        const chunk = self.Chunks.getandaddref(Pos);
        if (chunk == null) {
            const ch = try Chunk.GenChunk(Pos, &self.TerrainHeightCache, self.GenParams, self.allocator);
            const ad = ztracy.ZoneNC(@src(), "allocChunkStruct", 234313);
            var chunkptr: *Chunk = try self.allocator.create(Chunk);
            ad.End();
            chunkptr.* = ch;
            if (structures) {
                try GenerateStructures(self, chunkptr, Pos, renderer);
                std.debug.assert(chunkptr.genstate.load(.seq_cst) == .StructuresGenerated);
            }
            _ = chunkptr.ref_count.fetchAdd(1, .seq_cst);
            std.debug.assert(chunkptr.ref_count.load(.seq_cst) == 2);
            const existing = try self.Chunks.putNoOverrideaddRef(Pos, chunkptr);
            //chptr is in hashmap past this point
            if (existing) |d| {
                //std.debug.print("miss\n", .{});
                chunkptr.release(); //ref was added before putting
                _ = chunkptr.free(self.allocator);
                self.allocator.destroy(chunkptr);
                return d;
            }
            return chunkptr;
        } else {
            if (structures and chunk.?.genstate.load(.seq_cst) == .TerrainGenerated) {
                try GenerateStructures(self, chunk.?, Pos, renderer);
            }
            return chunk.?;
        }
    }
    //threadlocal var stackfallback: std.heap.StackFallbackAllocator(500_000) = undefined; TODO readd stackfallback correctly
    fn GenerateStructures(self: *@This(), chunk: *Chunk, Pos: [3]i32, renderer: ?*Renderer) !void {
        const genstructures = ztracy.ZoneNC(@src(), "generate_structures", 94);
        defer genstructures.End();
        if (chunk.genstate.load(.seq_cst) != .TerrainGenerated) return;
        defer chunk.genstate.store(.StructuresGenerated, .seq_cst);
        if (chunk.blocks != .blocks) return;
        if (!self.GenParams.genStructures) return;
        const randomSeed = std.hash.Wyhash.hash(self.GenParams.seed, std.mem.asBytes(&Pos));
        var random = std.Random.DefaultPrng.init(randomSeed);
        const rand = random.random();
        const heights = Chunk.GetTerrainHeight([2]i32{ Pos[0], Pos[2] }, self.GenParams, &self.TerrainHeightCache); //should still be in the cache
        var sfa = std.heap.stackFallback(100_000, self.allocator);
        const tempAllocator = sfa.get();
        var worldEditor = try WorldEditor.init(self, renderer, chunk, Pos, false, tempAllocator); //temporary allocation
        defer _ = worldEditor.deinit() catch |err| std.debug.panic("failed to deinit WorldEditor: {any}\n", .{err});
        var structuresGenerated: u32 = 0;

        for (heights, 0..) |row, x| {
            for (row, 0..) |height, z| {
                if (@divFloor(height, ChunkSize) != Pos[1] or height < self.GenParams.SeaLevel) continue;
                const y: usize = @intCast(@mod(height, ChunkSize));

                if (chunk.blocks.blocks[x][y][z] == .Grass or chunk.blocks.blocks[x][y][z] == .Dirt) {
                    const treeChance: f64 = rand.float(f64) * self.GenParams.terrainScale; //TODO advance rng to make tree placement the same
                    if (true and treeChance < 0.000002) {
                        comptime var csteps: [10]Structures.Tree.Step = undefined;
                        comptime for (&csteps, 0..) |*step, r| {
                            step.* = switch (r) {
                                0...0 => Structures.Tree.Step{
                                    .lengthPercent = 1.0,
                                    .radiusPercent = 1.0,
                                    .branchCountMax = 1,
                                    .branchCountMin = 1,
                                    .branchRange = @splat(0.0),
                                    .lengthPercentRandomness = 0.5,

                                    
                                },
                                1...2 => Structures.Tree.Step{
                                    .lengthPercent = 0.7,
                                    .radiusPercent = 0.5,
                                    .branchRandomness = 0.3,
                                    .branchCountMax = 4,
                                    .branchCountMin = 3,
                                    .lengthPercentRandomness = 0.4,

                                    .branchRange = @splat(0.4),

                                },
                                3...5 => Structures.Tree.Step{
                                    .lengthPercent = 0.7,
                                    .radiusPercent = 0.7,
                                    .branchCountMax = 4,
                                    .branchCountMin = 3,
                                    .branchRandomness = 0.3,
                                    .lengthPercentRandomness = 0.3,

                                    .branchRange = @splat(0.6),


                                },
                                6...10 => Structures.Tree.Step{
                                    .lengthPercent = 0.7,
                                    .radiusPercent = 0.7,
                                    .branchCountMax = 4,
                                    .branchCountMin = 3,
                                    .branchRandomness = 0.3,
                                    .lengthPercentRandomness = 0.3,

                                    .branchRange = @splat(0.4),


                                },
                                else => unreachable,
                            };
                        };
                        const steps = csteps;
                        const centerPos = ((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize })) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) } + @Vector(3, i32){ 0, -10, 0 };
                        const tree = Structures.Tree{
                            .pos = @intCast(centerPos),
                            .baseRadius = 15,
                            .rand = rand,
                            .trunkHeight = 100,
                            .maxRecursionDepth = 9,
                            .leafDensity = 0.5,
                            .leafSize = 6,
                            .steps = &steps,
                        };

                        try tree.PlaceTree(&worldEditor);
                        worldEditor.empty();
                    } else if (treeChance < 0.00015) {
                        structuresGenerated += 1;
                        const factor = rand.float(f32) + 0.5;
                        const centerPos = ((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize })) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) };
                        const tree = Structures.Tree{
                            .pos = @intCast(centerPos),
                            .baseRadius = 4 * factor,
                            .rand = rand,
                            .trunkHeight = 15 * factor,
                            .steps = &@as([10]Structures.Tree.Step, @splat(.{
                                .branchCountMax = 4,
                                .branchCountMin = 3,
                                .lengthPercentRandomness = 0.2,
                                .branchRandomness = 0.1,

                                .radiusPercentRandomness = 0.2,
                            })),
                        };

                        try tree.PlaceTree(&worldEditor);

                        worldEditor.empty();
                    } else if (treeChance < 0.0015) {
                        structuresGenerated += 1;
                        const factor = rand.float(f32) + 0.5;
                        const centerPos = ((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize })) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) };
                        try Structures.PlaceTree(&worldEditor, centerPos, rand, .{
                            .height = @intFromFloat(25 * factor),
                            .base_radius = @intFromFloat(@round(4 * factor)),
                            .main_branches = 0,
                            .branch_length = 0,
                            .canopy_radius = @intFromFloat(12 * factor),
                            .top_radius_factor = 0.75,
                            .branch_start_height_factor = 0.90,
                            .canopy_density = 0.7,
                            .scale = self.GenParams.terrainScale,
                        });
                        worldEditor.empty();
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
        remeshWithThreadPool: bool = false,
        tempallocator: std.mem.Allocator,
        editBuffer: std.ArrayList(SetBlock) = .{},

        pub const SetBlock = struct {
            pos: @Vector(3, i64),
            block: Block,
        };

        ///allocator only makes temporary allocations, stackfallbackallocator should be used if clear is not called. mainchunk must not be locked
        pub fn init(world: *World, renderer: ?*Renderer, mainChunk: ?*Chunk, mainChunkPos: ?[3]i32, remeshWithThreadPool: bool, tempallocator: std.mem.Allocator) !@This() {
            const initworld = ztracy.ZoneNC(@src(), "initEditor", 45453);
            defer initworld.End();
            var Editor = @This(){
                .renderer = renderer,
                .chunkMap = std.AutoArrayHashMap([3]i32, *Chunk).init(tempallocator),
                .chunkLock = null,
                .mainChunkPos = mainChunkPos,
                .chunk = null,
                .world = world,
                .lastchunkpos = null,
                .tempallocator = tempallocator,
                .remeshWithThreadPool = remeshWithThreadPool,
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
        pub fn deinit(self: *@This()) !usize {
            const deinitworld = ztracy.ZoneNC(@src(), "deinitEditor", 43224);
            defer deinitworld.End();
            const remeshed = try self.clear();
            self.chunkMap.deinit();
            return remeshed;
        }
        ///unlocks main cached chunk
        pub fn empty(self: *@This()) void {
            if (self.chunkLock != null) {
                self.chunkLock.?.unlock();
                self.chunkLock = null;
            }
            self.chunk = null;
            self.lastchunkpos = null;
        }

        pub fn applyBuffered(self: *@This()) !void {
            for (self.editBuffer.items) |setBlock| {
                try self.PlaceBlock(setBlock.block, setBlock.pos);
            }
            self.editBuffer.shrinkAndFree(self.tempallocator, 0);
        }

        ///must be called after a series of actions to update renderer and empty chunk cache, returns amount remeshed.
        /// if StackFallbackAllocator is used, the WorldEditor should not be used after this call.
        pub fn clear(self: *@This()) !usize {
            const clearworld = ztracy.ZoneNC(@src(), "clearEditor", 67556);
            defer clearworld.End();
            var remeshed: usize = 0;
            try self.applyBuffered();
            self.empty();
            var it = self.chunkMap.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.release();
            }
            if (self.renderer != null) {
                it = self.chunkMap.iterator();
                while (it.next()) |entry| {
                    if (self.mainChunkPos == null or @reduce(.Or, @as(@Vector(3, i32), entry.key_ptr.*) != @as(@Vector(3, i32), self.mainChunkPos.?))) {
                        if (self.remeshWithThreadPool) {
                            try self.world.threadPool.spawn(Renderer.AddChunkToRenderTask, .{ self.renderer.?, entry.key_ptr.*, false, false }, .High);
                        } else {
                            addChunkToRenderNoErr(self.renderer.?, entry.key_ptr.*, false);
                        }
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

        fn LoadChunkNoErr(self: *World, Pos: [3]i32, renderer: ?*Renderer, structures: bool) ?*Chunk {
            return LoadChunk(self, Pos, renderer, structures) catch |err| std.debug.panic("err: {any}", .{err});
        }

        fn addChunkToRenderNoErr(r: *Renderer, Pos: [3]i32, genStructures: bool) void {
            r.AddChunkToRender(Pos, genStructures) catch |err| std.debug.panic("err: {any}", .{err});
        }
        pub fn PlaceBlockBuffered(self: *@This(), block: Block, pos: @Vector(3, i64)) !void {
            try self.editBuffer.append(self.tempallocator, .{ .pos = pos, .block = block });
        }

        pub fn PlaceBlock(self: *@This(), block: Block, pos: @Vector(3, i64)) !void {
            const nextchunk: @Vector(3, i32) = @intCast(@divFloor(pos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
            const nextchunkblockpos = @mod(pos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize });
            if (self.lastchunkpos == null or @reduce(.Or, self.lastchunkpos.? != nextchunk)) {
                if (self.chunkLock != null) {
                    self.chunkLock.?.unlock();
                    self.chunkLock = null;
                }
                self.chunk = self.chunkMap.get(nextchunk);
                if (self.chunk == null) {
                    self.chunk = LoadChunkNoErr(self.world, nextchunk, null, false);
                    //const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
                    self.chunk.?.lock.lockShared();
                    //lock.End();
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
                    //const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
                    self.chunkLock.?.lock();
                    //lock.End();
                }
            }
            self.lastchunkpos = nextchunk;
            std.debug.assert(self.chunkLock != null); //chunk is locked
            const blockEncoding = self.chunk.?.blocks;
            if (blockEncoding != .blocks) {
                std.debug.assert(self.chunkLock.? == &self.chunk.?.lock);
                if (self.chunk.?.blocks != .blocks) _ = try self.chunk.?.ToBlocks(self.world.allocator, false);
            }
            self.chunk.?.blocks.blocks[@intCast(nextchunkblockpos[0])][@intCast(nextchunkblockpos[1])][@intCast(nextchunkblockpos[2])] = block;
        }

        pub fn PlaceSamplerShape(self: *@This(), block: Block, shape: anytype) !void {
            const boundingBox = shape.boundingBox;
            //const T = comptime @TypeOf(shape.boundingBox[0]);
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
                            try self.PlaceBlock(block, i64blockpos);
                        }
                    }
                }
            }
        }

        pub fn GetBlock(self: *@This(), blockpos: @Vector(3, i64)) !Block {
            const nextchunk: @Vector(3, i32) = @intCast(@divFloor(blockpos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
            const nextchunkblockpos = @mod(blockpos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize });
            if (self.lastchunkpos == null or @reduce(.Or, self.lastchunkpos.? != nextchunk)) {
                if (self.chunkLock != null) {
                    self.chunkLock.?.unlock();
                    self.chunkLock = null;
                }
                self.chunk = self.chunkMap.get(nextchunk);
                if (self.chunk == null) {
                    self.chunk = LoadChunkNoErr(self.world, nextchunk, null, false);
                    try self.chunkMap.put(nextchunk, self.chunk.?);
                }
                if (self.chunk != null) {
                    std.debug.assert(self.chunkLock == null);
                    self.chunkLock = &self.chunk.?.lock;
                    const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
                    self.chunkLock.?.lock();
                    lock.End();
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

        pub fn Cone(comptime T: type) type {
            return struct {
                position: @Vector(3, T), // top center of cone
                axis: @Vector(3, T), // normalized axis (direction from top → base)
                length: T,
                radiusTop: T,
                radiusBase: T,
                boundingBox: @Vector(6, T),
                pub fn init(pos: @Vector(3, T), axisVec: @Vector(3, T), coneLength: T, baseR: T, topR: T) @This() {
                    // normalize axis
                    const normAxis = axisVec / @as(@Vector(3, T), @splat(@sqrt(dot(axisVec, axisVec))));
                    var cone: @This() = .{
                        .position = pos,
                        .axis = normAxis,
                        .length = coneLength,
                        .radiusTop = topR,
                        .radiusBase = baseR,
                        .boundingBox = undefined,
                    };
                    cone.updateBoundingBox();
                    return cone;
                }

                pub fn isPointInside(self: *const @This(), P: @Vector(3, T)) bool {
                    const v = P - self.position;
                    const t = dot(v, self.axis);

                    if (t < 0 or t > self.length) return false;

                    const len2 = dot(v, v);
                    const perp2 = len2 - t * t;

                    const r = self.radiusBase + (self.radiusTop - self.radiusBase) * (t / self.length);
                    return perp2 < r * r;
                }

                pub fn updateBoundingBox(self: *@This()) void {
                    const top = self.position;
                    const base = self.position + self.axis * @as(@Vector(3, T), @splat(self.length));
                    const rMax = @max(self.radiusTop, self.radiusBase);

                    const minX = @floor(@min(top[0], base[0]) - rMax);
                    const maxX = @ceil(@max(top[0], base[0]) + rMax);

                    const minY = @floor(@min(top[1], base[1]) - rMax);
                    const maxY = @ceil(@max(top[1], base[1]) + rMax);

                    const minZ = @floor(@min(top[2], base[2]) - rMax);
                    const maxZ = @ceil(@max(top[2], base[2]) + rMax);
                    self.boundingBox = @Vector(6, T){ minX, maxX, minY, maxY, minZ, maxZ };
                }
            };
        }

        inline fn dot(a: anytype, b: @TypeOf(a)) @typeInfo(@TypeOf(a)).vector.child {
            return @reduce(.Add, a * b);
        }
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
            const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
            self.Chunks.buckets[b].lock.lock();
            lock.End();
            var it = self.Chunks.buckets[b].hash_map.valueIterator();
            defer self.Chunks.buckets[b].lock.unlock();
            while (it.next()) |c| {
                try self.UnloadChunkByPtr(c.*);
                self.allocator.destroy(c.*);
            }
        }
        const enbktamount = self.Entitys.buckets.len;
        for (0..enbktamount) |b| {
            const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
            self.Entitys.buckets[b].lock.lock();
            lock.End();
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
