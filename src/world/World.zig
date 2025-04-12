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

    ///adds a ref and returns a chunk, generates it if it dosent exist and puts the chunk in the world hashmap. ref must be removed if not using chunk
    pub fn LoadChunk(self: *@This(), Pos: [3]i32) !*Chunk {
        const loadChunk = ztracy.ZoneNC(@src(), "loadChunk", 222222);
        defer loadChunk.End();
        const chunk = self.Chunks.getandaddref(Pos);
        if (chunk == null) {
            const ch = try Chunk.GenChunk(Pos, &self.TerrainHeightCache, &self.TerrainHeightCacheMutex, self.GenParams, self.allocator);
            const ad = ztracy.ZoneNC(@src(), "allocChunkStruct", 234313);
            const chunkptr = try self.allocator.create(Chunk);
            ad.End();
            chunkptr.* = ch;
            chunkptr.add_ref();
            try self.Chunks.put(Pos, chunkptr);
            return chunkptr;
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
        std.debug.print("www\n", .{});

        while (true) {
            const chunk = self.Chunks.getandaddref(Pos) orelse return;
            _ = self.Chunks.removemanuallock(Pos);
            chunk.release();

            if (chunk.free(self.allocator, 100) == false) continue;
            self.allocator.destroy(chunk);
            break;
        }
    }

    pub fn Deinit(self: *@This()) !void {
        const bktamount = self.Chunks.buckets.len;
        for (0..bktamount) |b| {
            self.Chunks.buckets[b].lock.lock();
            var it = self.Chunks.buckets[b].hash_map.iterator();
            defer self.Chunks.buckets[b].lock.unlock();
            while (it.next()) |c| {
                try self.UnloadChunk(c.key_ptr.*);
            }
        }
        self.Chunks.deinit();
        std.debug.print("lll\n", .{});
        const pbktamount = self.Chunks.buckets.len;
        for (0..pbktamount) |b| {
            self.Players.buckets[b].lock.lock();
            var it = self.Players.buckets[b].hash_map.valueIterator();
            defer self.Players.buckets[b].lock.unlock();
            while (it.next()) |p| {
                //TODO send disconnect
                _ = p;
            }
        }
        std.debug.print("bbb\n", .{});
        self.Players.deinit();
        self.TerrainHeightCache.deinit();
    }
};
