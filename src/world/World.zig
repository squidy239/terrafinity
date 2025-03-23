const std = @import("std");
const Cache = @import("cache").Cache;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Chunk = @import("Chunk").Chunk;
const Entitys = @import("Entitys");

pub const World = struct {
    allocator: std.mem.Allocator,
    threadPool: *std.Thread.Pool,
    TerrainHeightCache: Cache([32][32]i32),
    TerrainHeightCacheMutex: std.Thread.Mutex,
    Players: ConcurrentHashMap(u128, *Entitys.Player, std.hash_map.AutoContext(u128), 80, 32),
    Chunks: ConcurrentHashMap([3]i32, *Chunk, std.hash_map.AutoContext([3]i32), 80, 32),
    GenParams: Chunk.GenParams,

    pub fn RemovePlayer(self: *@This(), UUID: u128, max_tries: ?u32) !void {
        const pl = self.Players.get(UUID) orelse return error.PlayerNotFound;
        pl.ref_count.fetchAdd(1, .seq_cst);
        pl.lock.lock();
        var tries: u32 = 0;
        while (pl.ref_count.load(.seq_cst) != 1) {
            std.atomic.spinLoopHint();
            tries += 1;
            if (tries > max_tries) return error.MaxTries;
        }
        self.allocator.destroy(pl);
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

    ///adds a ref and returns a chunk, generates it if it dosent exist and puts the chunk in the world hashmap
    pub fn LoadChunk(self: *@This(), Pos: [3]i32) !*Chunk {
        const chunk = self.Chunks.getandaddref(Pos);
        if (chunk == null) {
            Chunk.GenChunk(Pos, &self.TerrainHeightCache, &self.TerrainHeightCacheMutex, self.GenParams, self.allocator);
            const chunkptr = try self.allocator.create(Chunk);
            chunkptr.* = chunk;
            chunkptr.add_ref();
            try self.Chunks.put(Pos, chunkptr);
            return chunkptr;
        } else return chunk.?;
    }

    pub fn UnloadChunk(self: *@This(), Pos: [3]i32) !void {
        while (true) {
            const chunk = self.Chunks.getandaddref(Pos) orelse return;
            self.Chunks.remove(Pos);
            chunk.release();
            if (chunk.free(self.allocator, 100) == false) continue;
            self.allocator.destroy(chunk);
            break;
        }
    }

    pub fn Deinit(self: *@This()) void {
        const bktamount = self.Chunks.buckets.len;
        for (0..bktamount) |b| {
            self.Chunks.buckets[b].lock.lockShared();
            var it = self.Chunks.buckets[b].hash_map.iterator();
            defer self.Chunks.buckets[b].lock.unlockShared();
            while (it.next()) |c| {
                self.UnloadChunk(c.key_ptr.*);
            }
        }
        self.Chunks.deinit();

        const pbktamount = self.Chunks.buckets.len;
        for (0..pbktamount) |b| {
            self.Players.buckets[b].lock.lockShared();
            var it = self.Players.buckets[b].hash_map.valueIterator();
            defer self.Players.buckets[b].lock.unlockShared();
            while (it.next()) |p| {
                //TODO send disconnect
                _ = p;
            }
        }
        self.Players.deinit();
        self.TerrainHeightCache.deinit();
    }
};
