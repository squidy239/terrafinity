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
    pub const DefaultGenerator = @import("Generator.zig").DefaultGenerator;
    pub const Tree = @import("structures/Tree.zig").Tree;
    pub const TexturedSphere = @import("structures/TexturedSphere.zig");
    allocator: std.mem.Allocator,
    threadPool: *ThreadPool,
    prng: std.Random.DefaultPrng,
    random: std.Random,
    Entitys: ConcurrentHashMap(u128, *Entity, std.hash_map.AutoContext(u128), 80, 32),
    Chunks: ConcurrentHashMap([3]i32, *Chunk, std.hash_map.AutoContext([3]i32), 80, 32),
    Config: WorldConfig,
    Generator: ChunkGenerator,
    onEdit: ?struct {
        onEditFn: *const fn (chunkPos: [3]i32, args: *anyopaque) void,
        onEditFnArgs: *anyopaque,
    },
    pub const WorldConfig = struct {
        SpawnCenterPos: @Vector(3, f64),
        SpawnRange: u32,
    };

    pub const ChunkGenerator = struct {
        ///onEditFn must be called on any modified chunks once all modifications are complete
        ///this function is responsible for locking and adding refs to the chunk
        ///must set chunk.genstate to StructuresGenerated
        pub const AfterGenerationFunction = fn (self: *ChunkGenerator, world: *World, chunk: *Chunk, Pos: [3]i32) error{ OutOfMemory, Unrecoverable }!void;
        ///generate the chunk blocks, this may be called multiple times on the same chunk position
        pub const ChunkGenerationFunction = fn (self: *ChunkGenerator, world: *World, blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, Pos: [3]i32) error{ OutOfMemory, GenerationError }!void;
        ///must return the height of the terrain in blocks at the given chunk coordinates
        pub const GetTerrainHeightAtPosFunction = fn (self: *ChunkGenerator, world: *World, Pos: @Vector(2, i32)) error{ OutOfMemory, Unrecoverable }![ChunkSize][ChunkSize]i32;

        pub const DeinitFunction = fn (self: *ChunkGenerator, world: *World) void;

        data: *anyopaque,
        genChunkBlocks: *const ChunkGenerationFunction,
        afterGeneration: *const AfterGenerationFunction,
        getTerrainHeight: *const GetTerrainHeightAtPosFunction,
        deinit: *const DeinitFunction,
    };

    pub fn PlayerIDtoEntityId(playerID: u128) u128 {
        return std.hash.int(playerID);
    }
    pub fn UnloadEntity(self: *@This(), entityUUID: u128) void {
        const en = self.Entitys.fetchremoveandaddref(entityUUID) orelse return;
        _ = en.WaitForRefAmount(1, null); //already done in fullfree but i am doing it here so there will be 1 ref when saving
        const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
        en.lock.lock();
        lock.End();
        //TODO save entity to disk
        en.fullfree(self.allocator);
    }
    
    pub fn UnloadEntityNoLock(self: *@This(), entityUUID: u128, ref_amount:u32) void {
        const en = self.Entitys.fetchremoveandaddref(entityUUID) orelse return;
        _ = en.WaitForRefAmount(1 + ref_amount, null); //already done in fullfree but i am doing it here so there will be 1 ref when saving
        //TODO save entity to disk
        en.fullfree(self.allocator);
    }

    pub fn SpawnEntity(self: *@This(), UUID: ?u128, entity: anytype) !*Entity {
        const uuid = UUID orelse self.random.int(u128);
        if (self.Entitys.contains(uuid)) return error.EntityAlreadyExists;
        const allocated_entity = try entity.MakeEntity(self.allocator);
        errdefer allocated_entity.fullfree(self.allocator);
        const existing = try self.Entitys.putNoOverrideaddRef(uuid, allocated_entity);
        if (existing) |_| {
            allocated_entity.fullfree(self.allocator);
            return error.EntityAlreadyExists;
        }

        return allocated_entity;
    }

    pub fn GetPlayerSpawnPos(self: *@This()) !@Vector(3, f64) {
        const pos = @Vector(2, i32){ @intFromFloat(self.Config.SpawnCenterPos[0]), @intFromFloat(self.Config.SpawnCenterPos[2]) } + @Vector(2, i32){ self.random.intRangeAtMost(i32, -@as(i32, @intCast(self.Config.SpawnRange)), @as(i32, @intCast(self.Config.SpawnRange))), self.random.intRangeAtMost(i32, -@as(i32, @intCast(self.Config.SpawnRange)), @as(i32, @intCast(self.Config.SpawnRange))) };
        const chunkPos = [2]i32{ @divFloor(pos[0], ChunkSize), @divFloor(pos[1], ChunkSize) };
        const posInChunk = [2]i32{ @mod(pos[0], ChunkSize), @mod(pos[1], ChunkSize) };
        const height = (try self.Generator.getTerrainHeight(&self.Generator, self, chunkPos))[@intCast(posInChunk[0])][@intCast(posInChunk[1])];
        std.debug.print("Player spawn pos: {d}, {d}, {d}\n", .{ pos[0], height, pos[1] });
        return @Vector(3, f64){ @floatFromInt(pos[0]), @floatFromInt(height), @floatFromInt(pos[1]) };
    }

    pub fn GetTerrainHeightAtCoords(self: *@This(), pos: @Vector(2, i64)) !i64 {
        const chunkPos = [2]i32{ @intCast(@divFloor(pos[0], ChunkSize)), @intCast(@divFloor(pos[1], ChunkSize)) };
        const posInChunk = [2]i32{ @intCast(@mod(pos[0], ChunkSize)), @intCast(@mod(pos[1], ChunkSize)) };
        const height = (try self.Generator.getTerrainHeight(&self.Generator, self, [2]i32{ chunkPos[0], chunkPos[1] }))[@intCast(posInChunk[0])][@intCast(posInChunk[1])];
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
    pub fn LoadChunk(self: *@This(), Pos: [3]i32, structures: bool) error{ OutOfMemory, GenerationError, Unrecoverable }!*Chunk {
        const loadChunk = ztracy.ZoneNC(@src(), "loadChunk", 222222);
        defer loadChunk.End();
        const chunk = self.Chunks.getandaddref(Pos);
        if (chunk == null) {
            var blocks: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
            try self.Generator.genChunkBlocks(&self.Generator, self, &blocks, Pos);
            const chunkptr: *Chunk = try .FromBlocks(&blocks, self.allocator);
            errdefer {
                chunkptr.free(self.allocator);
                self.allocator.destroy(chunkptr);
            }
            if (structures) { //TODO move structures to Generator
                try self.Generator.afterGeneration(&self.Generator, self, chunkptr, Pos);
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
                try self.Generator.afterGeneration(&self.Generator, self, chunk.?, Pos);
            }
            return chunk.?;
        }
    }

    pub const WorldEditor = struct {
        world: *World,
        lastChunkCache: ?struct { Pos: [3]i32, blocks: *[ChunkSize][ChunkSize][ChunkSize]Block } = null,
        lastChunkReadCache: ?struct { Pos: [3]i32, chunk: *Chunk } = null,

        editBuffer: std.AutoHashMapUnmanaged([3]i32, [ChunkSize][ChunkSize][ChunkSize]Block) = .{},
        tempallocator: std.mem.Allocator,

        ///applies the edits in the buffer to the world, frees any temporary allocations
        ///this also calls ClearReader to unlock any chunks that were read
        pub fn flush(self: *@This()) !void {
            self.ClearReader();
            self.editBuffer.lockPointers();
            defer self.editBuffer.clearAndFree(self.tempallocator);
            defer self.editBuffer.unlockPointers();
            var it = self.editBuffer.iterator();
            while (it.next()) |diffChunk| {
                const encoding: Chunk.BlockEncoding = if (Chunk.IsOneBlock(diffChunk.value_ptr)) |oneBlock| .{ .oneBlock = oneBlock } else .{ .blocks = diffChunk.value_ptr };
                const chunk = try self.world.LoadChunk(diffChunk.key_ptr.*, false);
                defer chunk.release();
                try chunk.Merge(encoding, self.world.allocator, true);
            }
            it.index = 0;
            while (it.next()) |diffChunk| {
                if (self.world.onEdit) |onEdit| onEdit.onEditFn(diffChunk.key_ptr.*, onEdit.onEditFnArgs);
            }
        }

        pub inline fn PlaceBlock(self: *@This(), block: Block, pos: @Vector(3, i64)) !void {
            const chunkPos: @Vector(3, i32) = @intCast(@divFloor(pos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
            const chunkBlockPos:@Vector(3, usize) = @intCast(@mod(pos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
            if (self.lastChunkCache != null and std.meta.eql(self.lastChunkCache.?.Pos, chunkPos)) {
                @branchHint(.likely);
                self.lastChunkCache.?.blocks[chunkBlockPos[0]][chunkBlockPos[1]][chunkBlockPos[2]] = block;
                return;
            }

            var chunk = (try self.editBuffer.getOrPutValue(self.tempallocator, chunkPos, comptime @splat(@splat(@splat(.Null))))).value_ptr;
            self.lastChunkCache = .{ .Pos = chunkPos, .blocks = chunk };
            chunk[(chunkBlockPos[0])][(chunkBlockPos[1])][(chunkBlockPos[2])] = block;
        }

        ///returns a block at the given position, ClearReader must be called after a series of calls to unlock the cached chunk
        pub inline fn GetBlock(self: *@This(), blockpos: @Vector(3, i64)) !Block {
            const chunkPos: @Vector(3, i32) = @intCast(@divFloor(blockpos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize }));
            const chunkBlockPos = @mod(blockpos, @Vector(3, i64){ ChunkSize, ChunkSize, ChunkSize });
            if (self.lastChunkReadCache == null or @reduce(.Or, self.lastChunkReadCache.?.Pos != chunkPos)) {
                if (self.lastChunkReadCache != null) {
                    self.lastChunkReadCache.?.chunk.releaseAndUnlockShared();
                    self.lastChunkReadCache = null;
                }
                self.lastChunkReadCache = .{ .Pos = chunkPos, .chunk = try self.world.LoadChunk(chunkPos, true) };
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
    pub fn UnloadChunkByPtr(self: *@This(), chunk: *Chunk) void {
        _ = chunk.WaitForRefAmount(1, null);
        _ = chunk.free(self.allocator);
    }

    pub fn Deinit(self: *@This()) void {
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
                self.UnloadChunkByPtr(c.*);
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
        self.Generator.deinit(&self.Generator, self);
        self.Chunks.deinit();
    }
};

fn NormilizeInRange(num: anytype, oldLowerBound: anytype, oldUpperBound: anytype, newLowerBound: anytype, newUpperBound: anytype) @TypeOf(num, oldLowerBound, oldUpperBound, newLowerBound, newUpperBound) {
    return (num - oldLowerBound) / (oldUpperBound - oldLowerBound) * (newUpperBound - newLowerBound) + newLowerBound;
}
