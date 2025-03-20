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
    pub fn GenChunk(Pos: [3]i32, TerrainHeightCache: ?*cache.Cache([32][32]i32), TerrainHeightCacheMutex: ?*std.Thread.Mutex, TerrainNoise: Noise.Noise(f32), terrainmin: i32, terrainmax: i32, seed: u64, allocator: std.mem.Allocator) !@This() {
        const thamount: f32 = @floatFromInt(terrainmax + terrainmin);
        var heights: [ChunkSize][ChunkSize]i32 = undefined;
        var chunk: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;

        if (TerrainHeightCache != null and TerrainHeightCache != null) {
            TerrainHeightCacheMutex.?.lock();
            if (TerrainHeightCache.?.get(std.mem.sliceAsBytes(&Pos))) |T| {
                @branchHint(.likely);
                T.borrow();
                heights = T.value;
                T.release();
                TerrainHeightCacheMutex.?.unlock();
            } else {
                TerrainHeightCacheMutex.?.unlock();
                heights = GenTerrainHeight(Pos, TerrainNoise, terrainmin, terrainmax);
            }
        } else heights = GenTerrainHeight(Pos, TerrainNoise, terrainmin, terrainmax);

        var rng = std.Random.DefaultPrng.init(seed + @as(u64, @truncate(@as(u96, @bitCast(Pos)))));
        var rand = rng.random();
        for (heights, 0..) |row, x| {
            for (row, 0..) |terrain_height, z| {
                for (0..ChunkSize) |c| {
                    const block_height = (Pos[1] * 32) + @as(i32, @intCast(c));
                    chunk[x][c][z] = if (block_height < terrain_height - 5) Block.Stone else if (block_height < terrain_height - 1) Block.Dirt else if (block_height == terrain_height) RandGround(&rand, @as(f32, @floatFromInt(terrain_height)) / thamount) else Block.Air;
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
        const a = rand.float(f32) + heightPercent;
        return if (a < 0.5) Block.Grass else if (a < 0.7) Block.Dirt else if (a < 0.85) Block.Stone else Block.Snow;
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

    ///simultaneous frees on the safe chunk will block forever
    fn free(self: *@This(), allocator: std.mem.Allocator) void {
        self.addAndlock();
        while (self.ref_count.load(.acquire) != 1) {
            std.atomic.spinLoopHint();
        }
        allocator.free(self.blocks);
    }

    fn add(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .release);
    }

    fn release(self: *@This()) void {
        _ = self.ref_count.fetchSub(1, .release);
    }

    fn addAndLockShared(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .release);
        self.lock.lockShared();
    }

    fn addAndlock(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .release);
        self.lock.lock();
    }

    fn addAndlockSharednoBlock(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .release);
        self.lock.tryLockShared();
    }

    fn addAndlocknoBlock(self: *@This()) void {
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
};

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    var chunk = try Chunk.GenChunk([3]i32{ 0, 0, 0 }, null, null, Noise.Noise(f32){}, -200, 200, 0, alloc);
    defer chunk.free(alloc);
    std.debug.print("chunk: {any}", .{std.mem.bytesAsValue([ChunkSize][ChunkSize][ChunkSize]Block, chunk.blocks)});
}
