const Block = @import("Block").Blocks;
const ztracy = @import("ztracy");
const Noise = @import("fastnoise.zig");
const Cache = @import("Cache").Cache;
const std = @import("std");
const ChunkSize = 32;

pub const BlockEncoding = union(enum) {
    blocks: *[ChunkSize][ChunkSize][ChunkSize]Block,
    oneBlock: Block,
};

pub const Genstate = enum(u8) {
    TerrainGenerated,
    StructuresGenerated,
};

pub const Function = enum(u8) {
    GenerateStructures,
    GenerateStructuresHH,
    LoadChunk,
    GenChunk,
};

var cacheHits: std.atomic.Value(u32) = .init(0);
var cacheMisses: std.atomic.Value(u32) = .init(0);
pub const Chunk = struct {
    debugTag: Function,
    blocks: BlockEncoding,
    lock: std.Thread.RwLock,
    genstate: std.atomic.Value(Genstate),
    ref_count: std.atomic.Value(u32), //must count being in a hashmap as a refrence
    pub fn GenChunk(Pos: [3]i32, TerrainHeightCache: *Cache([2]i32, [32][32]i32, 1024), gen_params: GenParams, allocator: std.mem.Allocator) !@This() {
        //TODO SIMD perlin for HUGE speed increce
        const thamount: f32 = @floatFromInt(gen_params.terrainmax - gen_params.terrainmin);
        var chunk: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        const gc = ztracy.ZoneNC(@src(), "GenChunkHeights", 1);
        const heights = GetTerrainHeight([2]i32{ Pos[0], Pos[2] }, gen_params, TerrainHeightCache);
        //  std.debug.print("hit/miss percent: {d}%, theoretical percent: {d}%                 \r", .{ @as(f32, @floatFromInt(cacheHits.load(.seq_cst))) / @as(f32, @floatFromInt(cacheMisses.load(.seq_cst) + cacheHits.load(.seq_cst))), 20.0 / 21.0 });
        gc.End();
        var rng = std.Random.DefaultPrng.init(gen_params.seed +% @as(u64, @truncate(@as(u96, @bitCast(Pos)))));
        var rand = rng.random();
        var LastBlock: ?Block = null;
        var isOneBlock = true;
        const SeaLevel: i32 = 0;
        const gen = ztracy.ZoneNC(@src(), "GenChunkBlocks", 867674577);
        for (heights, 0..) |row, x| {
            for (row, 0..) |terrain_height, z| {
                for (0..ChunkSize) |c| {
                    const block_height = (Pos[1] * ChunkSize) + @as(i32, @intCast(c));
                    const block = if (block_height < terrain_height - 5) Block.Stone else if (block_height < terrain_height) Block.Dirt else if (block_height == terrain_height) RandGround(&rand, @as(f32, @floatFromInt(terrain_height)) / thamount, block_height, SeaLevel) else if (block_height > terrain_height and block_height < SeaLevel) Block.Water else Block.Air;
                    chunk[x][c][z] = block;
                    if (LastBlock != null and LastBlock != block) isOneBlock = false;
                    LastBlock = block;
                }
            }
        }
        gen.End();
        if (Pos[0] == 0) {}
        const ad = ztracy.ZoneNC(@src(), "allocBlocks", 234313);
        defer ad.End();
        var blockEncoding: BlockEncoding = undefined;
        if (isOneBlock) {
            blockEncoding = BlockEncoding{ .oneBlock = LastBlock.? };
        } else {
            const mem = try allocator.create([ChunkSize][ChunkSize][ChunkSize]Block);
            mem.* = chunk;
            blockEncoding = BlockEncoding{ .blocks = mem };
        }
        return @This(){
            .blocks = blockEncoding,
            .lock = .{},
            .debugTag = .GenChunk,
            .genstate = std.atomic.Value(Genstate).init(.TerrainGenerated),
            .ref_count = std.atomic.Value(u32).init(1),
        };
    }
    pub const FaceRotation = enum(u3) {
        xPlus = 0,
        xMinus = 1,
        yPlus = 2,
        yMinus = 3,
        zPlus = 4,
        zMinus = 5,
    };

    pub fn extractFace(self: *@This(), face: FaceRotation, comptime removeRef: bool) [ChunkSize][ChunkSize]Block {
        const ef = ztracy.ZoneNC(@src(), "ExtractFace", 9999);
        defer ef.End();
        self.addAndLockShared();

        defer {
            if (removeRef) self.release();
            self.releaseAndUnlockShared();
        }
        // Determine dimensions of the resulting 2D array
        var cube: *[ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        var Tempcube: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;

        switch (self.blocks) {
            .blocks => cube = self.blocks.blocks,
            .oneBlock => {
                var dd: [ChunkSize][ChunkSize]Block = undefined;
                @memset(&dd, @splat(self.blocks.oneBlock));
                Tempcube = @splat((dd));
                cube = &Tempcube;
            },
        }
        var result: [ChunkSize][ChunkSize]Block = undefined;

        for (&result, 0..) |*row, i| {
            for (row, 0..) |*item, j| {
                item.* = switch (face) {
                    .xPlus => cube[ChunkSize - 1][i][j],
                    .xMinus => cube[0][i][j],
                    .yPlus => cube[i][ChunkSize - 1][j],
                    .yMinus => cube[i][0][j],
                    .zPlus => cube[i][j][ChunkSize - 1],
                    .zMinus => cube[i][j][0],
                };
            }
        }

        return result;
    }
    ///caller must hold lock and a ref
    pub fn ToBlocks(self: *Chunk, allocator: std.mem.Allocator) !void {
        std.debug.assert(self.blocks == .oneBlock);
        var blocks: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        @memset(&blocks, @splat(@splat(self.blocks.oneBlock)));
        const mem = try allocator.create([ChunkSize][ChunkSize][ChunkSize]Block);
        mem.* = blocks;
        self.blocks = BlockEncoding{ .blocks = mem };
    }

    fn RandGround(rand: *std.Random, heightPercent: f32, block_height: i32, seaLevel: i32) Block {
        const a = (rand.float(f32) + (heightPercent * 5)) / 6;

        return if (block_height < seaLevel) Block.Dirt else if (a < 0.6) Block.Grass else if (a < 0.7) Block.Dirt else if (a < 0.8) Block.Stone else Block.Snow;
    }

    pub fn GetHeightsFromCache(Pos: [2]i32, TerrainHeightCache: *Cache([2]i32, [32][32]i32, 1024)) ?[ChunkSize][ChunkSize]i32 {
        const gth = ztracy.ZoneNC(@src(), "GetTerrainHeightsFromCache", 110029);
        defer gth.End();
        if (TerrainHeightCache.get(Pos)) |T| {
            @branchHint(.likely);
            _ = cacheHits.fetchAdd(1, .seq_cst);
            return T;
        }
        return null;
    }

    pub fn GetTerrainHeight(Pos: [2]i32, params: GenParams, TerrainHeightCache: *Cache([2]i32, [32][32]i32, 1024)) [ChunkSize][ChunkSize]i32 {
        const gth = ztracy.ZoneNC(@src(), "GetTerrainHeights", 662291);
        defer gth.End();
        _ = cacheHits.fetchAdd(1, .seq_cst);
        if (GetHeightsFromCache(Pos, TerrainHeightCache)) |cachedHeight| return cachedHeight;
        const generatedHeights = GenTerrainHeight(params, Pos);
        TerrainHeightCache.put(Pos, generatedHeights) catch |err| std.debug.panic("{any}\n", .{err});
        return generatedHeights;
    }

    fn GenTerrainHeight(params: GenParams, Pos: [2]i32) [ChunkSize][ChunkSize]i32 {
        const gth = ztracy.ZoneNC(@src(), "GenTerrainHeights", 662291);
        defer gth.End();
        const floatpos = @Vector(2, f32){ @floatFromInt(Pos[0]), @floatFromInt(Pos[1]) };
        var height: [ChunkSize][ChunkSize]i32 = undefined;
        for (0..ChunkSize) |ux| {
            const x: f32 = (@as(f32, @floatFromInt(ux)) / 32) + floatpos[0];
            for (0..ChunkSize) |uz| {
                const z: f32 = (@as(f32, @floatFromInt(uz)) / 32) + floatpos[1];
                height[ux][uz] = params.TerrainNoise.genNoise2DRange(x, z, i32, params.terrainmin, params.terrainmax);
            }
        }
        _ = cacheMisses.fetchAdd(1, .seq_cst);
        _ = cacheHits.fetchSub(1, .seq_cst);
        return height;
    }

    pub fn GetBlock(self: *@This(), x: u5, y: u5, z: u5) Block {
        switch (self.blocks) {
            .oneBlock => return self.blocks.oneBlock,
            .blocks => self.blocks.blocks[x][y][z],
        }
    }
    ///their must oly be 1 ref before calling, use WaitForRefAmount
    pub fn free(self: *@This(), allocator: std.mem.Allocator) bool {
        const freeChunk = ztracy.ZoneNC(@src(), "freeChunk", 11999);
        defer freeChunk.End();
        std.debug.assert(self.ref_count.load(.seq_cst) == 1);
        if (self.blocks != .blocks) {
            std.debug.assert(self.blocks == .oneBlock);
            return true;
        }
        self.lock.lock();
        allocator.destroy(self.blocks.blocks);
        return true;
    }

    pub fn WaitForRefAmount(self: *@This(), comptime amount: u32, comptime maxMicroTime: ?u64) bool {
        const wait = ztracy.ZoneNC(@src(), "WaitForRefAmount", 5554);
        defer wait.End();
        if (self.ref_count.load(.seq_cst) == amount) return true;
        const st = std.time.microTimestamp();
        while (self.ref_count.load(.seq_cst) != amount) {
            if (maxMicroTime != null and (std.time.microTimestamp() - st) > maxMicroTime.?) return false;
            std.Thread.yield() catch |err| std.debug.print("yield err:{any}\n", .{err});
        }
        return true;
    }
    pub fn add_ref(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    pub fn release(self: *@This()) void {
        _ = self.ref_count.fetchSub(1, .seq_cst);
    }

    pub fn addAndLockShared(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
        self.lock.lockShared();
    }

    pub fn addAndlock(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
        self.lock.lock();
    }

    pub fn addAndlockSharednoBlock(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
        self.lock.tryLockShared();
    }

    pub fn addAndlocknoBlock(self: *@This()) void {
        self.lock.tryLock();
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    pub fn releaseAndUnlock(self: *@This()) void {
        self.lock.unlock();
        _ = self.ref_count.fetchSub(1, .seq_cst);
    }

    pub fn releaseAndUnlockShared(self: *@This()) void {
        self.lock.unlockShared();
        _ = self.ref_count.fetchSub(1, .seq_cst);
    }

    pub const GenParams = struct {
        TerrainNoise: Noise.Noise(f32),
        terrainmin: i32,
        terrainmax: i32,
        seed: u64,
    };
};
