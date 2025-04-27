const Block = @import("Block").Blocks;
const ztracy = @import("ztracy");
const Noise = @import("fastnoise.zig");
const cache = @import("cache");
const std = @import("std");
const ChunkSize = 32;

pub const BlockEncoding = union(enum) {
    blocks: *[32][32][32]Block,
    oneBlock: Block,
};

pub const Chunk = struct {
    blocks: BlockEncoding,
    lock: std.Thread.RwLock,
    ref_count: std.atomic.Value(u32), //must count being in a hashmap as a refrence
    pub fn GenChunk(Pos: [3]i32, TerrainHeightCache: ?*cache.Cache([32][32]i32), TerrainHeightCacheMutex: ?*std.Thread.Mutex, gen_params: GenParams, allocator: std.mem.Allocator) !@This() {
        //TODO SIMD perlin for HUGE speed increce
        const thamount: f32 = @floatFromInt(gen_params.terrainmax - gen_params.terrainmin);
        var chunk: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        const gc = ztracy.ZoneNC(@src(), "GenChunkHeights", 1);
        const heights = GetHeightsFromCache(Pos, TerrainHeightCache, TerrainHeightCacheMutex) orelse GenTerrainHeight(Pos, gen_params);
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

    fn RandGround(rand: *std.Random, heightPercent: f32, block_height: i32, seaLevel: i32) Block {
        const a = (rand.float(f32) + (heightPercent * 5)) / 6;

        return if (block_height < seaLevel) Block.Dirt else if (a < 0.6) Block.Grass else if (a < 0.7) Block.Dirt else if (a < 0.8) Block.Stone else Block.Snow;
    }

    pub fn GetHeightsFromCache(Pos: [3]i32, TerrainHeightCache: ?*cache.Cache([32][32]i32), TerrainHeightCacheMutex: ?*std.Thread.Mutex) ?[ChunkSize][ChunkSize]i32 {
        const gth = ztracy.ZoneNC(@src(), "GetTerrainHeightsFromCache", 110029);
        defer gth.End();
        if (TerrainHeightCache != null and TerrainHeightCache != null) {
            TerrainHeightCacheMutex.?.lock();
            defer TerrainHeightCacheMutex.?.unlock();
            if (TerrainHeightCache.?.get(std.mem.sliceAsBytes(&Pos))) |T| {
                @branchHint(.likely);
                T.borrow();
                defer T.release();
                return T.value;
            } else return null;
        } else return null;
    }

    pub fn GenTerrainHeight(Pos: [3]i32, params: GenParams) [ChunkSize][ChunkSize]i32 {
        const gth = ztracy.ZoneNC(@src(), "GenTerrainHeights", 662291);
        defer gth.End();
        const floatpos = @Vector(3, f32){ @floatFromInt(Pos[0]), @floatFromInt(Pos[1]), @floatFromInt(Pos[2]) };
        var height: [ChunkSize][ChunkSize]i32 = undefined;
        for (0..ChunkSize) |ux| {
            // /32 with multiplying
            const x: f32 = (@as(f32, @floatFromInt(ux)) * 0.03125) + floatpos[0];
            for (0..ChunkSize) |uz| {
                const z: f32 = (@as(f32, @floatFromInt(uz)) * 0.03125) + floatpos[2];
                height[ux][uz] = params.TerrainNoise.genNoise2DRange(x, z, i32, params.terrainmin, params.terrainmax);
            }
        }
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

test "fastnoiselite" {
    var gridOne: [16][16]u8 = undefined;
    var gridTwo: [16][16]u8 = undefined;
    const noise = Noise.Noise(f64){
        .seed = std.crypto.random.int(i32),
        .noise_type = .perlin,
    };
    const noise2 = Noise.Noise(f64){
        .seed = std.crypto.random.int(i32),
        .noise_type = .perlin,
    };
    std.debug.print("eql: {any} == {any}\n", .{ singlePerlin2D(123312321, 0, 0), singlePerlin2D(-321355, 0, 0) });
    for (0..16) |xx| {
        for (0..16) |zz| {
            gridOne[xx][zz] = noise.genNoise2DAsType(@floatFromInt(xx), @floatFromInt(zz), u8);
        }
    }
    for (0..16) |xx| {
        for (0..16) |zz| {
            gridTwo[xx][zz] = noise2.genNoise2DAsType(@floatFromInt(xx), @floatFromInt(zz), u8);
        }
    }
    std.debug.print("grid1: \n", .{});

    for (gridOne) |row| {
        std.debug.print("{d}\n", .{row});
    }
    std.debug.print("grid2: \n", .{});
    for (gridTwo) |row| {
        std.debug.print("{d}\n", .{row});
    }

    std.debug.print("isequal: {any}\n", .{std.mem.eql([16]u8, &gridOne, &gridTwo)});
    // std.debug.print("n1:{d},\n n2:{d}\n", . gridOne, gridTwo });
}
pub fn singlePerlin2D(seed: i32, x: f32, y: f32) f32 {
    var x0 = fastFloor(x + 5);
    var y0 = fastFloor(y + 3);

    const xd0: f32 = x - @as(f32, @floatFromInt(x0));
    const yd0: f32 = y - @as(f32, @floatFromInt(y0));
    const xd1: f32 = xd0 - 1;
    const yd1: f32 = yd0 - 1;

    const xs: f32 = interpQuintic(xd0);
    const ys: f32 = interpQuintic(yd0);

    x0 *%= prime_x;
    y0 *%= prime_y;
    const x1 = x0 +% prime_x;
    const y1 = y0 +% prime_y;
    const xf0: f32 = lerp(gradCoord2D(seed, x0, y0, xd0, yd0), gradCoord2D(seed, x1, y0, xd1, yd0), xs);
    const xf1: f32 = lerp(gradCoord2D(seed, x0, y1, xd0, yd1), gradCoord2D(seed, x1, y1, xd1, yd1), xs);
    std.debug.print("xf0:{d}, xf1:{d},ys:{d},xs:{d}, gc:{d}\n", .{ xf0, xf1, ys, xs, gradCoord2D(seed, x0, y0, xd0, yd0) });
    return lerp(xf0, xf1, ys) * 1.4247691104677813;
}

inline fn interpQuintic(t: f32) f32 {
    return t * t * t * (t * (t * 6 - 15) + 10);
}

inline fn hash2D(seed: i32, x_primed: i32, y_primed: i32) i32 {
    const hash: i32 = seed ^ x_primed ^ y_primed;
    return hash *% 0x27D4EB2D;
}

inline fn gradCoord2D(seed: i32, x_primed: i32, y_primed: i32, xd: f32, yd: f32) f32 {
    var hash = hash2D(seed, x_primed, y_primed);
    hash ^= (hash >> 15);
    const index: usize = @intCast(hash & (127 << 1));
    return xd * gradients_2d[index] + yd * gradients_2d[index | 1];
}

const gradients_2d = [256]f32{
    0.130526192220052,  0.99144486137381,   0.38268343236509,   0.923879532511287,  0.608761429008721,  0.793353340291235,  0.793353340291235,  0.608761429008721,
    0.923879532511287,  0.38268343236509,   0.99144486137381,   0.130526192220051,  0.99144486137381,   -0.130526192220051, 0.923879532511287,  -0.38268343236509,
    0.793353340291235,  -0.60876142900872,  0.608761429008721,  -0.793353340291235, 0.38268343236509,   -0.923879532511287, 0.130526192220052,  -0.99144486137381,
    -0.130526192220052, -0.99144486137381,  -0.38268343236509,  -0.923879532511287, -0.608761429008721, -0.793353340291235, -0.793353340291235, -0.608761429008721,
    -0.923879532511287, -0.38268343236509,  -0.99144486137381,  -0.130526192220052, -0.99144486137381,  0.130526192220051,  -0.923879532511287, 0.38268343236509,
    -0.793353340291235, 0.608761429008721,  -0.608761429008721, 0.793353340291235,  -0.38268343236509,  0.923879532511287,  -0.130526192220052, 0.99144486137381,
    0.130526192220052,  0.99144486137381,   0.38268343236509,   0.923879532511287,  0.608761429008721,  0.793353340291235,  0.793353340291235,  0.608761429008721,
    0.923879532511287,  0.38268343236509,   0.99144486137381,   0.130526192220051,  0.99144486137381,   -0.130526192220051, 0.923879532511287,  -0.38268343236509,
    0.793353340291235,  -0.60876142900872,  0.608761429008721,  -0.793353340291235, 0.38268343236509,   -0.923879532511287, 0.130526192220052,  -0.99144486137381,
    -0.130526192220052, -0.99144486137381,  -0.38268343236509,  -0.923879532511287, -0.608761429008721, -0.793353340291235, -0.793353340291235, -0.608761429008721,
    -0.923879532511287, -0.38268343236509,  -0.99144486137381,  -0.130526192220052, -0.99144486137381,  0.130526192220051,  -0.923879532511287, 0.38268343236509,
    -0.793353340291235, 0.608761429008721,  -0.608761429008721, 0.793353340291235,  -0.38268343236509,  0.923879532511287,  -0.130526192220052, 0.99144486137381,
    0.130526192220052,  0.99144486137381,   0.38268343236509,   0.923879532511287,  0.608761429008721,  0.793353340291235,  0.793353340291235,  0.608761429008721,
    0.923879532511287,  0.38268343236509,   0.99144486137381,   0.130526192220051,  0.99144486137381,   -0.130526192220051, 0.923879532511287,  -0.38268343236509,
    0.793353340291235,  -0.60876142900872,  0.608761429008721,  -0.793353340291235, 0.38268343236509,   -0.923879532511287, 0.130526192220052,  -0.99144486137381,
    -0.130526192220052, -0.99144486137381,  -0.38268343236509,  -0.923879532511287, -0.608761429008721, -0.793353340291235, -0.793353340291235, -0.608761429008721,
    -0.923879532511287, -0.38268343236509,  -0.99144486137381,  -0.130526192220052, -0.99144486137381,  0.130526192220051,  -0.923879532511287, 0.38268343236509,
    -0.793353340291235, 0.608761429008721,  -0.608761429008721, 0.793353340291235,  -0.38268343236509,  0.923879532511287,  -0.130526192220052, 0.99144486137381,
    0.130526192220052,  0.99144486137381,   0.38268343236509,   0.923879532511287,  0.608761429008721,  0.793353340291235,  0.793353340291235,  0.608761429008721,
    0.923879532511287,  0.38268343236509,   0.99144486137381,   0.130526192220051,  0.99144486137381,   -0.130526192220051, 0.923879532511287,  -0.38268343236509,
    0.793353340291235,  -0.60876142900872,  0.608761429008721,  -0.793353340291235, 0.38268343236509,   -0.923879532511287, 0.130526192220052,  -0.99144486137381,
    -0.130526192220052, -0.99144486137381,  -0.38268343236509,  -0.923879532511287, -0.608761429008721, -0.793353340291235, -0.793353340291235, -0.608761429008721,
    -0.923879532511287, -0.38268343236509,  -0.99144486137381,  -0.130526192220052, -0.99144486137381,  0.130526192220051,  -0.923879532511287, 0.38268343236509,
    -0.793353340291235, 0.608761429008721,  -0.608761429008721, 0.793353340291235,  -0.38268343236509,  0.923879532511287,  -0.130526192220052, 0.99144486137381,
    0.130526192220052,  0.99144486137381,   0.38268343236509,   0.923879532511287,  0.608761429008721,  0.793353340291235,  0.793353340291235,  0.608761429008721,
    0.923879532511287,  0.38268343236509,   0.99144486137381,   0.130526192220051,  0.99144486137381,   -0.130526192220051, 0.923879532511287,  -0.38268343236509,
    0.793353340291235,  -0.60876142900872,  0.608761429008721,  -0.793353340291235, 0.38268343236509,   -0.923879532511287, 0.130526192220052,  -0.99144486137381,
    -0.130526192220052, -0.99144486137381,  -0.38268343236509,  -0.923879532511287, -0.608761429008721, -0.793353340291235, -0.793353340291235, -0.608761429008721,
    -0.923879532511287, -0.38268343236509,  -0.99144486137381,  -0.130526192220052, -0.99144486137381,  0.130526192220051,  -0.923879532511287, 0.38268343236509,
    -0.793353340291235, 0.608761429008721,  -0.608761429008721, 0.793353340291235,  -0.38268343236509,  0.923879532511287,  -0.130526192220052, 0.99144486137381,
    0.38268343236509,   0.923879532511287,  0.923879532511287,  0.38268343236509,   0.923879532511287,  -0.38268343236509,  0.38268343236509,   -0.923879532511287,
    -0.38268343236509,  -0.923879532511287, -0.923879532511287, -0.38268343236509,  -0.923879532511287, 0.38268343236509,   -0.38268343236509,  0.923879532511287,
};

inline fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + t * (b - a);
}
inline fn fastFloor(f: f32) i32 {
    return @intFromFloat(if (f >= 0) f else f - 1);
}

const prime_x: i32 = 501125321;
/// A constant prime-number used in y-axis calculations.
const prime_y: i32 = 1136930381;
/// A constant prime-number used in z-axis calculations.
const prime_z: i32 = 1720413743;
