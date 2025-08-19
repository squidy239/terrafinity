const std = @import("std");
const Cache = @import("Cache").Cache;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Chunk = @import("Chunk").Chunk;
const Entity = @import("Entity").Entity;
const EntityTypes = @import("EntityTypes");
const ThreadPool = @import("root").ThreadPool;
const Block = @import("Block").Blocks;
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

    pub fn SpawnEntity(self: *@This(), UUID: u128, entity: anytype) !void {
        if (self.Entitys.contains(UUID)) return error.PlayerAlreadyConnected;
        const allocated_entity = try entity.MakeEntity(self.allocator);
        errdefer allocated_entity.fullfree(self.allocator);
        const existing = try self.Entitys.putNoOverrideaddRef(UUID, allocated_entity);
        if (existing) |_| {
            allocated_entity.fullfree(self.allocator);
        }
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
    pub fn LoadChunk(self: *@This(), Pos: [3]i32) !*Chunk {
        const loadChunk = ztracy.ZoneNC(@src(), "loadChunk", 222222);
        defer loadChunk.End();
        const chunk = self.Chunks.getandaddref(Pos);
        if (chunk == null) {
            const ch = try Chunk.GenChunk(Pos, &self.TerrainHeightCache, self.GenParams, self.allocator);
            const ad = ztracy.ZoneNC(@src(), "allocChunkStruct", 234313);
            var chunkptr = try self.allocator.create(Chunk);
            @memset(std.mem.asBytes(chunkptr), 0);
            ad.End();

            chunkptr.* = ch;
            chunkptr.ref_count.raw = 2; //add ref before hashmap non atomicly
            const existing = try self.Chunks.putNoOverrideaddRef(Pos, chunkptr); //duplacate can happen with 2 simultanius loads, both detect no chunk in hashmap
            //chptr is in hashmap past this point
            if (existing) |d| {
                @branchHint(.unlikely);
                chunkptr.release(); //ref was added before putting
                _ = chunkptr.free(self.allocator);
                self.allocator.destroy(chunkptr);
                return d;
            } else return chunkptr;
        } else return chunk.?;
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
