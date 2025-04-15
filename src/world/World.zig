const std = @import("std");
const Cache = @import("cache").Cache;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Chunk = @import("Chunk").Chunk;
const Entitys = @import("Entitys");
const Block = @import("Block").Blocks;
const ztracy = @import("ztracy");
const ChunkSize = 32;
pub const World = struct {
    allocator: std.mem.Allocator,
    threadPool: *std.Thread.Pool,
    TerrainHeightCache: Cache([32][32]i32),
    TerrainHeightCacheMutex: std.Thread.Mutex,
    Entitys: ConcurrentHashMap(u128, *Entitys.Entity, std.hash_map.AutoContext(u128), 80, 32),
    Chunks: ConcurrentHashMap([3]i32, *Chunk, std.hash_map.AutoContext([3]i32), 80, 32),
    GenParams: Chunk.GenParams,

    pub fn PlayerIDtoEntityId(playerID: u128) u128 {
        return std.hash.int(playerID);
    }
    pub fn RemovePlayer(self: *@This(), entityUUID: u128, max_tries: ?u32) !void {
        const en = self.Entitys.getandaddref(entityUUID) orelse return error.PlayerNotFound;
        if (en.entity != .Player) return error.UUIDnotPlayer;
        en.lock.lock();
        var tries: u32 = 0;
        while (en.ref_count.load(.seq_cst) != 1) {
            std.atomic.spinLoopHint();
            tries += 1;
            if (tries > max_tries) return error.MaxTries;
        }
        self.allocator.destroy(en.entity.Player);
    }

    pub fn AddPlayer(self: *@This(), UUID: u128, player: Entitys.Player) !void {
        std.debug.assert(UUID == player.player_UUID);
        if (self.Players.get(UUID) != null) return error.PlayerAlreadyConnected;
        var pl = try self.allocator.create(Entitys.Player);
        errdefer self.allocator.destroy(pl);
        pl.* = player;
        pl.ref_count.store(1, .seq_cst);
        try self.Players.put(UUID, pl);
    }

    ///adds a ref and returns a chunk, generates it if it dosent exist and puts the chunk in the world hashmap. ref must be removed if not using chunk
    pub fn LoadChunk(self: *@This(), Pos: [3]i32) !*Chunk {
        const loadChunk = ztracy.ZoneNC(@src(), "loadChunk", 222222);
        defer loadChunk.End();
        const chunk = self.Chunks.getandaddref(Pos);
        if (chunk == null) {
            const ch = try Chunk.GenChunk(Pos, &self.TerrainHeightCache, &self.TerrainHeightCacheMutex, self.GenParams, self.allocator);
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
        //  std.debug.print("lll\n", .{});
        const pbktamount = self.Entitys.buckets.len;
        for (0..pbktamount) |b| {
            self.Entitys.buckets[b].lock.lock();
            var it = self.Entitys.buckets[b].hash_map.valueIterator();
            defer self.Entitys.buckets[b].lock.unlock();
            while (it.next()) |p| {
                try p.*.free(self.allocator, null);
                //TODO send disconnect if entity is player
            }
        }
        self.Entitys.deinit();
        self.TerrainHeightCache.deinit();
    }
};
