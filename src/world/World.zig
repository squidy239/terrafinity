const std = @import("std");
const ThreadPool = @import("root").ThreadPool;

pub const Block = @import("Block").Blocks;
const Cache = @import("Cache").Cache;
const Chunk = @import("Chunk").Chunk;
const ChunkSize = Chunk.ChunkSize;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Entity = @import("Entity").Entity;
const EntityTypes = @import("EntityTypes");
const ztracy = @import("ztracy");

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
    pub fn LoadChunk(self: *@This(), Pos: [3]i32, structures: bool, comptime onEditFn: ?fn (chunkPos: [3]i32, args: anytype) void, onEditFnArgs: anytype) error{OutOfMemory}!*Chunk {
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
                try GenerateStructures(self, chunkptr, Pos, onEditFn, onEditFnArgs);
                std.debug.assert(chunkptr.genstate.load(.seq_cst) == .StructuresGenerated);
            }
            _ = chunkptr.ref_count.fetchAdd(1, .seq_cst);
            std.debug.assert(chunkptr.ref_count.load(.seq_cst) == 2);
            const existing = try self.Chunks.putNoOverrideaddRef(Pos, chunkptr);
            //chptr is in hashmap past this point
            if (existing) |d| {
                chunkptr.release(); //ref was added before putting
                chunkptr.free(self.allocator);
                self.allocator.destroy(chunkptr);
                return d;
            }
            return chunkptr;
        } else {
            if (structures and chunk.?.genstate.load(.seq_cst) == .TerrainGenerated) {
                try GenerateStructures(self, chunk.?, Pos, onEditFn, onEditFnArgs);
            }
            return chunk.?;
        }
    }

    fn GenerateStructures(self: *@This(), chunk: *Chunk, Pos: [3]i32, comptime onEditFn: ?fn (chunkPos: [3]i32, args: anytype) void, onEditFnArgs: anytype) !void {
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
        var worldEditor = WorldEditor{ .remeshWithThreadPool = false, .world = self, .tempallocator = tempAllocator };
        defer _ = worldEditor.flush(onEditFn, onEditFnArgs) catch |err| std.debug.panic("failed to flush WorldEditor: {any}\n", .{err});
        var structuresGenerated: u32 = 0;

        for (heights, 0..) |row, x| {
            for (row, 0..) |height, z| {
                const realX:f32 = @as(f32, @floatFromInt((Pos[0] * ChunkSize) + @as(i32, @intCast(@mod(x, ChunkSize))))) / self.GenParams.terrainScale;
                const realZ:f32 = @as(f32, @floatFromInt((Pos[2] * ChunkSize) + @as(i32, @intCast(@mod(z, ChunkSize))))) / self.GenParams.terrainScale;
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
                            .maxRecursionDepth = 8,
                            .leafDensity = 0.5,
                            .leafSize = 6,
                            .scale = self.GenParams.terrainScale,
                            .steps = &steps,
                        };

                        _ = try tree.place(&worldEditor);
                    } else if (self.GenParams.TreeNoise.genNoise2D(realX, realZ) < -0.99995 ) {
                        structuresGenerated += 1;
                        const factor = rand.float(f32) + 0.5;//TODO replace a lot of rand with hashes
                        const centerPos = ((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize })) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) };
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
                                    .lengthPercent = 0.6,
                                    .radiusPercent = 0.4,
                                    .branchRandomness = 0.3,
                                    .branchCountMax = 8,
                                    .branchCountMin = 5,
                                    .lengthPercentRandomness = 0.4,
                                    .baseRadiusPercent = 0.75,
                                    
                                    .branchRange = @splat(0.8),
                                },
                                3...5 => Structures.Tree.Step{
                                    .lengthPercent = 0.7,
                                    .radiusPercent = 0.8,
                                    .branchCountMax = 4,
                                    .branchCountMin = 3,
                                    .branchRandomness = 0.3,
                                    .lengthPercentRandomness = 0.3,
                                    .branchRange = @splat(0.6),
                                },
                                6...10 => Structures.Tree.Step{
                                    .lengthPercent = 0.6,
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
                        const tree = Structures.Tree{
                            .pos = @intCast(centerPos),
                            .baseRadius = 3 * factor,
                            .rand = rand,
                            .trunkHeight = 25 * factor,
                            .steps = &steps,
                            .maxRecursionDepth = 6,
                            .leafDensity = 0.5,
                            .scale = self.GenParams.terrainScale,
                            .leafSize = 3,
                        };

                        _ = try tree.place(&worldEditor);
                    } else if (false and treeChance < 0.0015) {
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


    pub const WorldEditor = struct {
        world: *World,
        lastChunkCache: ?struct { Pos: [3]i32, blocks: *[ChunkSize][ChunkSize][ChunkSize]Block } = null,
        lastChunkReadCache: ?struct { Pos: [3]i32, chunk: *Chunk } = null,

        editBuffer: std.AutoHashMapUnmanaged([3]i32, [ChunkSize][ChunkSize][ChunkSize]Block) = .{},
        tempallocator: std.mem.Allocator,
        remeshWithThreadPool: bool,

        ///applies the edits in the buffer to the world, frees any temporary allocations
        pub fn flush(self: *@This(), comptime onEditFn: ?fn (chunkPos: [3]i32, args: anytype) void, onEditFnArgs: anytype) !void {
            self.editBuffer.lockPointers();
            var it = self.editBuffer.iterator();
            while (it.next()) |diffChunk| {
                const encoding: Chunk.BlockEncoding = if (Chunk.IsOneBlock(diffChunk.value_ptr)) |oneBlock| .{ .oneBlock = oneBlock } else .{ .blocks = diffChunk.value_ptr };
                const chunk = try self.world.LoadChunk(diffChunk.key_ptr.*, false, null, void);
                defer chunk.release();

                try chunk.Merge(encoding, self.world.allocator, true);
            }
            it.index = 0;
            while (it.next()) |diffChunk| {
                if (onEditFn != null) onEditFn.?(diffChunk.key_ptr.*, onEditFnArgs);
            }
            self.editBuffer.unlockPointers();
            self.editBuffer.clearAndFree(self.tempallocator);
        }

        pub fn PlaceBlock(self: *@This(), block: Block, pos: @Vector(3, i64)) !void {
            const chunkPos: @Vector(3, i32) = @intCast(@divFloor(pos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
            const chunkBlockPos = @mod(pos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize });
            if (self.lastChunkCache != null and @reduce(.And, self.lastChunkCache.?.Pos == chunkPos)) {
                @branchHint(.likely);
                self.lastChunkCache.?.blocks[@intCast(chunkBlockPos[0])][@intCast(chunkBlockPos[1])][@intCast(chunkBlockPos[2])] = block;
                return;
            }
            
            var chunk = (try self.editBuffer.getOrPutValue(self.tempallocator, chunkPos, comptime @splat(@splat(@splat(.Null))))).value_ptr;
            chunk[@intCast(chunkBlockPos[0])][@intCast(chunkBlockPos[1])][@intCast(chunkBlockPos[2])] = block;
            self.lastChunkCache = .{ .Pos = chunkPos, .blocks = chunk };
        }

        ///returns a block at the given position, ClearReader must be called after a series of calls to unlock the cached chunk
        pub fn GetBlock(self: *@This(), blockpos: @Vector(3, i64), comptime onEditFn: ?fn (chunkPos: [3]i32, args: anytype) void, onEditFnArgs: anytype) !Block {
            const chunkPos: @Vector(3, i32) = @intCast(@divFloor(blockpos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
            const chunkBlockPos = @mod(blockpos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize });
            if (self.lastChunkReadCache == null or @reduce(.Or, self.lastChunkCache.?.Pos != chunkPos)) {
                if (self.lastChunkReadCache != null) {
                    self.lastChunkReadCache.?.chunk.releaseAndUnlockShared();
                    self.lastChunkReadCache = null;
                }
                self.lastChunkReadCache = .{ .Pos = chunkPos, .chunk = try self.world.LoadChunk(chunkPos, true, onEditFn, onEditFnArgs) };
                self.lastChunkReadCache.?.chunk.lock.lockShared();
            }
            const blockEncoding = self.lastChunkReadCache.?.chunk.blocks;
            return switch (blockEncoding) {
                .blocks => self.lastChunkReadCache.?.chunk.blocks.blocks[@intCast(chunkBlockPos[0])][@intCast(chunkBlockPos[1])][@intCast(chunkBlockPos[2])],
                .oneBlock => self.lastChunkReadCache.?.chunk.blocks.oneBlock,
            };
        }

        pub fn ClearReader(self: *@This()) void {
            if (self.lastChunkReadCache) |cache| {
                cache.chunk.releaseAndUnlockShared();
                self.lastChunkReadCache = null;
            }
        }

        pub fn PlaceSamplerShape(self: *@This(), block: Block, shape: anytype) !void {
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
                            try self.PlaceBlock(block, i64blockpos);
                        }
                    }
                }
            }
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
        
        pub fn Sphere(comptime T: type) type {
            return struct {
                position: @Vector(3, T),
                radius: T,
                boundingBox: @Vector(6, T),
                pub fn init(pos: @Vector(3, T), radius: T) @This() {
                    var sphere: @This() = .{
                        .position = pos,
                        .radius = radius,
                        .boundingBox = undefined,
                    };
                    sphere.updateBoundingBox();
                    return sphere;
                }
                
                pub fn isPointInside(self: *const @This(), P: @Vector(3, T)) bool {
                    const diff = P - self.position;
                    const dist2 = dot(diff, diff);
                    return dist2 <= self.radius * self.radius;
                }
                
                pub fn updateBoundingBox(self: *@This()) void {
                    const r = self.radius;
                    
                    const minX = @floor(@min(self.position[0] - r, self.position[0] + r));
                    const maxX = @ceil(@max(self.position[0] - r, self.position[0] + r));
                    
                    const minY = @floor(@min(self.position[1] - r, self.position[1] + r));
                    const maxY = @ceil(@max(self.position[1] - r, self.position[1] + r));
                    
                    const minZ = @floor(@min(self.position[2] - r, self.position[2] + r));
                    const maxZ = @ceil(@max(self.position[2] - r, self.position[2] + r));
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
        chunk.free(self.allocator);
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
