const Block = @import("Blocks.zig").Blocks;
//const ztracy = @import("ztracy");
const Noise = @import("fastnoise.zig");
const cache = @import("cache");
const std = @import("std");
const ChunkSize = 32;

pub const Encoding = enum(u8) {
    Blocks,
    OneBlock,
};
//TODO cache with arrayhashmap
pub const Chunk = struct {
    encoding: Encoding,
    blocks: []u8,
    lock: std.Thread.RwLock,
    ref_count: std.atomic.Value(u32), //must count being in a hashmap as a refrence
    pub fn GenChunk(Pos: [3]i32, TerrainHeightCache: ?*cache.Cache([32][32]i32), TerrainHeightCacheMutex: ?*std.Thread.Mutex, gen_params: GenParams, allocator: std.mem.Allocator) !@This() {
        const thamount: f32 = @floatFromInt(gen_params.terrainmax - gen_params.terrainmin);
        var chunk: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        const heights = GetHeightsFromCache(Pos, TerrainHeightCache, TerrainHeightCacheMutex) orelse GenTerrainHeight(Pos, gen_params.TerrainNoise, gen_params.terrainmin, gen_params.terrainmax);
        var rng = std.Random.DefaultPrng.init(gen_params.seed + @as(u64, @truncate(@as(u96, @bitCast(Pos)))));
        var rand = rng.random();
        for (heights, 0..) |row, x| {
            for (row, 0..) |terrain_height, z| {
                for (0..ChunkSize) |c| {
                    const block_height = (Pos[1] * 32) + @as(i32, @intCast(c));
                    const block = if (block_height < terrain_height - 5) Block.Stone else if (block_height < terrain_height) Block.Dirt else if (block_height == terrain_height) RandGround(&rand, @as(f32, @floatFromInt(terrain_height)) / thamount) else Block.Air;
                    chunk[x][c][z] = block;
                }
            }
        }

        return @This(){
            .encoding = Encoding.Blocks,
            .blocks = try allocator.dupe(u8, std.mem.sliceAsBytes(&chunk)),
            .lock = .{},
            .ref_count = std.atomic.Value(u32).init(1),
        };
    }

    fn RandGround(rand: *std.Random, heightPercent: f32) Block {
        const a = (rand.float(f32) + (heightPercent * 5)) / 6;
        return if (a < 0.7) Block.Grass else if (a < 0.8) Block.Dirt else if (a < 0.93) Block.Stone else Block.Snow;
    }

    fn GetHeightsFromCache(Pos: [3]i32, TerrainHeightCache: ?*cache.Cache([32][32]i32), TerrainHeightCacheMutex: ?*std.Thread.Mutex) ?[ChunkSize][ChunkSize]i32 {
        if (TerrainHeightCache != null and TerrainHeightCache != null) {
            TerrainHeightCacheMutex.?.lock();
            if (TerrainHeightCache.?.get(std.mem.sliceAsBytes(&Pos))) |T| {
                @branchHint(.likely);
                T.borrow();
                defer T.release();
                defer TerrainHeightCacheMutex.?.unlock();
                return T.value;
            } else return null;
        } else return null;
    }

    fn GenTerrainHeight(Pos: [3]i32, TerrainNoise: Noise.Noise(f32), terrainmin: i32, terrainmax: i32) [ChunkSize][ChunkSize]i32 {
        const floatpos = @Vector(3, f32){ @floatFromInt(Pos[0]), @floatFromInt(Pos[1]), @floatFromInt(Pos[2]) };
        var height: [ChunkSize][ChunkSize]i32 = undefined;
        for (0..ChunkSize) |ux| {
            // /32 with multiplying
            const x: f32 = (@as(f32, @floatFromInt(ux)) * 0.03125) + floatpos[0];
            for (0..ChunkSize) |uz| {
                const z: f32 = (@as(f32, @floatFromInt(uz)) * 0.03125) + floatpos[2];
                height[ux][uz] = TerrainNoise.genNoise2DRange(x, z, i32, terrainmin, terrainmax);
            }
        }
        return height;
    }

    pub fn free(self: *@This(), allocator: std.mem.Allocator, max_tries: u32) bool {
        var tries: u32 = 0;
        while (self.ref_count.load(.acquire) != 1) {
            tries += 1;
            if (tries > max_tries) return false;
            std.atomic.spinLoopHint();
        }
        self.lock.lock();
        allocator.free(self.blocks);
        return true;
    }

    pub fn add_ref(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .release);
    }

    pub fn release(self: *@This()) void {
        _ = self.ref_count.fetchSub(1, .release);
    }

    pub fn addAndLockShared(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .release);
        self.lock.lockShared();
    }

    pub fn addAndlock(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .release);
        self.lock.lock();
    }

    pub fn addAndlockSharednoBlock(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .release);
        self.lock.tryLockShared();
    }

    pub fn addAndlocknoBlock(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .release);
        self.lock.tryLock();
    }

    pub fn releaseAndUnlock(self: *@This()) void {
        _ = self.ref_count.fetchSub(1, .release);
        self.lock.unlock();
    }

    pub fn releaseAndUnlockShared(self: *@This()) void {
        _ = self.ref_count.fetchSub(1, .release);
        self.lock.unlockShared();
    }

    pub const GenParams = struct {
        TerrainNoise: Noise.Noise(f32),
        terrainmin: i32,
        terrainmax: i32,
        seed: u64,
    };
};

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    var chunk = try Chunk.GenChunk([3]i32{ 0, 0, 0 }, null, null, Noise.Noise(f32){}, -200, 200, 0, alloc);
    defer chunk.free(alloc);
    std.debug.print("chunk: {any}", .{std.mem.bytesAsValue([ChunkSize][ChunkSize][ChunkSize]Block, chunk.blocks)});
}
