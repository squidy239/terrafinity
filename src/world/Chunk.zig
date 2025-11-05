const std = @import("std");

const Block = @import("Block").Blocks;
const Cache = @import("Cache").Cache;
const Interpolation = @import("Interpolation");
const ztracy = @import("ztracy");

const Noise = @import("fastnoise.zig");

var cacheHits: std.atomic.Value(u32) = .init(0);
var cacheMisses: std.atomic.Value(u32) = .init(0);

pub const Chunk = struct {
    pub const ChunkSize = 32;
    blocks: BlockEncoding,
    lock: std.Thread.RwLock,
    genstate: std.atomic.Value(Genstate),
    ref_count: std.atomic.Value(u32), //must count being in a hashmap as a refrence
    pub const BlockEncoding = union(enum) {
        blocks: *[ChunkSize][ChunkSize][ChunkSize]Block,
        oneBlock: Block,
    };

    pub const Genstate = enum(u8) {
        TerrainGenerated,
        StructuresGenerated,
    };
    pub fn GenChunk(Pos: [3]i32, TerrainHeightCache: *Cache([2]i32, [ChunkSize][ChunkSize]i32, 8192), gen_params: GenParams, allocator: std.mem.Allocator) !@This() {
        //TODO make terrain generation more customisable and move it to a diffrent file
        var chunk: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        const gc = ztracy.ZoneNC(@src(), "GenChunkHeights", 1);
        const heights = GetTerrainHeight([2]i32{ Pos[0], Pos[2] }, gen_params, TerrainHeightCache);
        //  std.debug.print("hit/miss percent: {d}%, theoretical percent: {d}%                 \r", .{ @as(f32, @floatFromInt(cacheHits.load(.seq_cst))) / @as(f32, @floatFromInt(cacheMisses.load(.seq_cst) + cacheHits.load(.seq_cst))), 20.0 / 21.0 });
        gc.End();
        var rng = std.Random.DefaultPrng.init(gen_params.seed +% @as(u64, @truncate(@as(u96, @bitCast(Pos)))));
        var rand = rng.random();
        const gen = ztracy.ZoneNC(@src(), "GenChunkBlocks", 867674577);
        const genterra = ztracy.ZoneNC(@src(), "GenTerrainBlocks", 22466);
        GenerateTerrain(&chunk, Pos, &heights, &gen_params, &rand);
        genterra.End();
        var oneBlock = IsOneBlock(&chunk);
        if (oneBlock == null or oneBlock.? == Block.Stone or oneBlock.? == Block.Water) {
            GenerateCaves(&chunk, Pos, &heights, &gen_params);
            oneBlock = IsOneBlock(&chunk);
        }
        gen.End();
        const ad = ztracy.ZoneNC(@src(), "allocBlocks", 234313);
        defer ad.End();
        var blockEncoding: BlockEncoding = undefined;
        if (oneBlock != null) {
            blockEncoding = BlockEncoding{ .oneBlock = oneBlock.? };
        } else {
            const mem = try allocator.create([ChunkSize][ChunkSize][ChunkSize]Block);
            mem.* = chunk;
            blockEncoding = BlockEncoding{ .blocks = mem };
        }
        return @This(){
            .blocks = blockEncoding,
            .lock = .{},
            .genstate = std.atomic.Value(Genstate).init(.TerrainGenerated),
            .ref_count = std.atomic.Value(u32).init(1),
        };
    }
    fn GenerateTerrain(chunkBlocks: *[ChunkSize][ChunkSize][ChunkSize]Block, Pos: [3]i32, heights: *const [ChunkSize][ChunkSize]i32, gen_params: *const GenParams, rand: *std.Random) void {
        const terrainScaleUp: f32 = 1.0 / @as(f32, @floatFromInt(@abs(gen_params.terrainmax)));
        const terrainScaleDown: f32 = 1.0 / @as(f32, @floatFromInt(@abs(gen_params.terrainmin)));
        const terrainScales: [2]f32 = .{ terrainScaleUp, terrainScaleDown };
        const oneDterrainScale: f32 = 1.0 / gen_params.terrainScale;
        var block_height_vec: [ChunkSize]i32 = undefined;
        for (0..ChunkSize) |i| block_height_vec[i] = (Pos[1] * ChunkSize) + @as(i32, @intCast(i));
        for (heights, 0..) |row, x| {
            for (0..ChunkSize) |c| {
                for (row, 0..) |terrain_height, z| {
                    chunkBlocks[x][c][z] = GetSurfaceBlock(block_height_vec[c], terrain_height, terrainScales, gen_params.SeaLevel, rand, gen_params.terrainblockRandomness, oneDterrainScale);
                }
            }
        }
    }
    ///generates caves in the chunk, returns true if the chunk is one block
    fn GenerateCaves(chunkBlocks: *[ChunkSize][ChunkSize][ChunkSize]Block, Pos: [3]i32, heights: *const [ChunkSize][ChunkSize]i32, gen_params: *const GenParams) void {
        const caves = ztracy.ZoneNC(@src(), "GenCaves", 13552);
        defer caves.End();
        var grid: [4][4][4]f32 = undefined;
        const floatPos: @Vector(3, f32) = @Vector(3, f32){ @floatFromInt(Pos[0]), @floatFromInt(Pos[1]), @floatFromInt(Pos[2]) };
        const onedthreeVec: @Vector(3, f32) = comptime @splat(1.0 / 3.0);
        const oneDterrainScaleVec: @Vector(3, f32) = @splat(1.0 / gen_params.terrainScale);
        const caveNoise = ztracy.ZoneNC(@src(), "caveNoise", 33211);
        // Sample at 4x4x4 points across the chunk area
        for (0..4) |x| {
            for (0..4) |y| {
                for (0..4) |z| {
                    const xyz = @Vector(3, f32){ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
                    const sample_offset = xyz * onedthreeVec;
                    const pos = (floatPos + sample_offset) * oneDterrainScaleVec;

                
                    grid[x][y][z] = gen_params.CaveNoise.genNoise3D(pos[0], pos[1], pos[2]); 
                }
            }
        }
        caveNoise.End();

        const inter = ztracy.ZoneNC(@src(), "Interpolate", 4221432);
        defer inter.End(); //TODO terrain and rivers, biomes and more
        const initinterp = ztracy.ZoneNC(@src(), "initinterp", 23434);
        var int = Interpolation.NaturalCubicInterpolator3D.init(grid);
        initinterp.End();
        const oneD32: f32 = comptime 1.0 / @as(comptime_float, ChunkSize);
        comptime var zs: @Vector(ChunkSize, f32) = undefined;
        comptime for (0..ChunkSize) |i| {
            zs[i] = @as(f32, @floatFromInt(i)) * oneD32;
        };
        const xs: @Vector(ChunkSize, f32) = comptime zs;
        const ys: @Vector(ChunkSize, f32) = comptime zs;

        _ = heights;
        @setEvalBranchQuota(32000);
        inline for (0..ChunkSize) |x| {
            for (0..ChunkSize) |y| {
                const realY = ((floatPos[1] * ChunkSize) + @as(f32, @floatFromInt(y))) * oneDterrainScaleVec[0];
                const m: f32 = 1 - (1 / -@min(-1, (realY / gen_params.CaveExpansionMax) - 1));
                const cavesess: f32 = (gen_params.Cavesess + (m * 2));
                inline for (0..ChunkSize) |z| {
                    const isCave = int.sampleComptimeXZ(xs[x], ys[y], zs[z]) < cavesess;
                    if (isCave) {
                        chunkBlocks[x][y][z] = .Air;
                    }
                }
            }
        }
    }

    ///checks if the block array is all the same block
    pub fn IsOneBlock(blockArray: *const [ChunkSize][ChunkSize][ChunkSize]Block) ?Block {
        const issOneBlock = ztracy.ZoneNC(@src(), "isOneBlock", 354354);
        defer issOneBlock.End();
        const firstBlockVec: @Vector(ChunkSize, @typeInfo(Block).@"enum".tag_type) = @splat(@intFromEnum(blockArray[0][0][0]));
        var isOneBlock: @Vector(ChunkSize, bool) = comptime @splat(true);
        const linearBlockArray: *const [ChunkSize * ChunkSize][ChunkSize]@typeInfo(Block).@"enum".tag_type = @ptrCast(blockArray);
        for (linearBlockArray) |blocks| isOneBlock &= (blocks == firstBlockVec);
        return if (@reduce(.And, isOneBlock)) blockArray[0][0][0] else null;
    }

    ///merges the chunk with the mergeBlocks, copies all non null mergeBlocks to blocks
    pub fn Merge(self: *@This(), mergeBlocks: BlockEncoding, allocator: std.mem.Allocator, comptime lock: bool) !void {
        const merge = ztracy.ZoneNC(@src(), "Merge", 756657567);
        defer merge.End();
        self.add_ref();
        defer self.release();
        if (lock) self.lock.lock();
        defer if (lock) self.lock.unlock();
        if (mergeBlocks == .oneBlock and (mergeBlocks.oneBlock == .Null)) return;
        switch (mergeBlocks) {
            .oneBlock => {
                switch (self.blocks) {
                    .oneBlock => {
                        if (mergeBlocks.oneBlock != .Null)
                            self.blocks = mergeBlocks;
                    },
                    .blocks => {
                        if (mergeBlocks.oneBlock != .Null) {
                            allocator.free(self.blocks.blocks);
                            self.blocks = .{ .oneBlock = mergeBlocks.oneBlock };
                        }
                    },
                }
            },
            .blocks => {
                const bl = ztracy.ZoneNC(@src(), "Blocks", 642342342);
                defer bl.End();
                _ = try self.ToBlocks(allocator, false);
                const flatArray: *[ChunkSize * ChunkSize * ChunkSize]Block = @ptrCast(self.blocks.blocks);
                const flatMergeArray: *const [ChunkSize * ChunkSize * ChunkSize]Block = @ptrCast(mergeBlocks.blocks);
                for (flatArray, flatMergeArray) |*item, mergeItem| {
                    if (mergeItem != .Null) item.* = mergeItem;
                }
            },
        }
    }

    pub fn extractFace(self: *@This(), comptime face: enum { xPlus, xMinus, yPlus, yMinus, zPlus, zMinus }, comptime removeRef: bool) [ChunkSize][ChunkSize]Block {
        const ef = ztracy.ZoneNC(@src(), "ExtractFace", 9999);
        defer ef.End();
        self.addAndLockShared();
        defer {
            if (removeRef) self.release();
            self.releaseAndUnlockShared();
        }
        var cube: *const [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        switch (self.blocks) {
            .blocks => cube = self.blocks.blocks,
            .oneBlock => {
                return @splat(@splat(self.blocks.oneBlock));
            },
        }
        var result: [ChunkSize][ChunkSize]Block = undefined;
        for (&result, 0..) |*row, i| {
            for (row, 0..) |*item, j| {
                item.* = switch (comptime face) {
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
    ///returns true if the chunk was converted to blocks, false if it was already blocks
    pub fn ToBlocks(self: *Chunk, allocator: std.mem.Allocator, comptime lock: bool) !bool {
        const toblocks = ztracy.ZoneNC(@src(), "toBlocks", 645);
        defer toblocks.End();
        self.add_ref();
        defer self.release();
        if (lock) self.lock.lock();
        defer if (lock) self.lock.unlock();
        if (self.blocks != .oneBlock) return false;
        var blocks: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        @memset(&blocks, @splat(@splat(self.blocks.oneBlock)));
        const mem = try allocator.create([ChunkSize][ChunkSize][ChunkSize]Block);
        mem.* = blocks;
        std.debug.assert(self.blocks != .blocks);
        self.blocks = BlockEncoding{ .blocks = mem };
        return true;
    }

    fn GetSurfaceBlock(block_height: i32, terrain_height: i32, thamount: [2]f32, SeaLevel: i32, rand: *std.Random, blockRandomness: f32, oneDterrainScale: f32) Block {
        if (block_height < terrain_height - 5) {
            return Block.Stone;
        } else if (block_height < terrain_height) {
            return Block.Dirt;
        } else if (block_height == terrain_height) {
            return RandGround(rand, @as(f32, @floatFromInt(terrain_height)) * thamount[@intFromBool(terrain_height <= SeaLevel)], block_height, SeaLevel, blockRandomness, oneDterrainScale);
        } else if (block_height > terrain_height and block_height <= SeaLevel) {
            return Block.Water;
        } else {
            return Block.Air;
        }
    }

    fn RandGround(rand: *std.Random, heightPercent: f32, block_height: i32, seaLevel: i32, blockRandomness: f32, oneDterrainScale: f32) Block {
        const a = std.math.lerp(heightPercent * oneDterrainScale, rand.float(f32), blockRandomness);
        return if (block_height < seaLevel) Block.Dirt else if (a < 0.25) Block.Grass else if (a < 0.4) Block.Dirt else if (a < 0.6) Block.Stone else Block.Snow;
    }

    pub fn GetHeightsFromCache(Pos: [2]i32, TerrainHeightCache: *Cache([2]i32, [ChunkSize][ChunkSize]i32, 8192)) ?[ChunkSize][ChunkSize]i32 {
        const gth = ztracy.ZoneNC(@src(), "GetTerrainHeightsFromCache", 110029);
        defer gth.End();
        if (TerrainHeightCache.get(Pos)) |T| {
            @branchHint(.likely);
            _ = cacheHits.fetchAdd(1, .seq_cst);
            return T;
        }
        return null;
    }

    pub fn GetTerrainHeight(Pos: [2]i32, params: GenParams, TerrainHeightCache: *Cache([2]i32, [ChunkSize][ChunkSize]i32, 8192)) [ChunkSize][ChunkSize]i32 {
        const gth = ztracy.ZoneNC(@src(), "GetTerrainHeights", 662291);
        defer gth.End();
        if (GetHeightsFromCache(Pos, TerrainHeightCache)) |cachedHeight| return cachedHeight;
        const generatedHeights = GenTerrainHeight(params, Pos);
        TerrainHeightCache.put(Pos, generatedHeights) catch |err| std.debug.panic("{any}\n", .{err});
        return generatedHeights;
    }

    fn GenTerrainHeight(params: GenParams, Pos: [2]i32) [ChunkSize][ChunkSize]i32 {
        const gth = ztracy.ZoneNC(@src(), "GenTerrainHeights", 662291);
        defer gth.End();
        const floatpos = @Vector(2, f32){ @floatFromInt(Pos[0]), @floatFromInt(Pos[1]) };
        const d32: f32 = comptime 1.0 / @as(comptime_float, ChunkSize);
        var height: [ChunkSize][ChunkSize]i32 = undefined;
        const floatmin: f32 = @floatFromInt(params.terrainmin);
        const floatmax: f32 = @floatFromInt(params.terrainmax);
        const floatBounds = [2]f32{ floatmin, floatmax };
        const oneDterrainscale: f32 = 1.0 / params.terrainScale;
        for (0..ChunkSize) |ux| {
            const x: f32 = ((@as(f32, @floatFromInt(ux)) * d32) + floatpos[0]) * oneDterrainscale;
            for (0..ChunkSize) |uz| {
                const z: f32 = ((@as(f32, @floatFromInt(uz)) * d32) + floatpos[1]) * oneDterrainscale;
                var genX = x;
                var genZ = z;
                params.TerrainNoise.domainWarp2D(&genX, &genZ);
                var largegenX = x;
                var largegenZ = z;
                params.LargeTerrainNoiseWarp.domainWarp2D(&largegenX, &largegenZ);
                var terrainNoise = std.math.pow(f32, params.TerrainNoise.genNoise2D(genX, genZ), 1);
                const largeterrainNoise = params.LargeTerrainNoise.genNoise2D(largegenX, largegenZ);
                // largeterrainNoise = scaleHeight(largeterrainNoise);
                //  largeterrainNoise = @min(0.2, largeterrainNoise);
              //  const noise = terrainNoise * largeterrainNoise; //std.math.lerp(terrainNoise, largeterrainNoise, params.terrainNoiseBalance);
                if (terrainNoise < 0.0) terrainNoise = 0.0;
                const P = 2.0; //Higher for stronger bias.
                const E = largeterrainNoise * (if (terrainNoise < 0.5)
                    (std.math.pow(f32, terrainNoise * 2, P) * 0.5)
                else
                    (1 - (std.math.pow(f32, (1 - terrainNoise) * 2, P) * 0.5)));

                //      std.debug.print("ltn:{any}, n:{any}, mix: {any}, o: {any}\n", .{largeterrainNoise, terrainNoise, noise, params.LargeTerrainNoise.genNoise2D(largegenX, largegenZ)});
                //uses lower or upper terrain height bound depending on if noise is less or greater than 0
                const block_height: i32 = @intFromFloat(E * @abs(floatBounds[@intFromBool(E > 0)]) * params.terrainScale);
                height[ux][uz] = block_height;
            }
        }
        _ = cacheMisses.fetchAdd(1, .seq_cst);
        return height;
    }

    fn scaleHeight(height: f32) f32 {
        const terms = comptime [_]f32{ -2.5408277295123904e-003, 1.2812501147500588e+000, -1.6573684564075566e+000, 1.0594173030800080e-001, 1.5586796210829328e+000, -8.8744433151283975e-001 };

        var t: f32 = 1;
        var r: f32 = 0;
        inline for (terms) |c| {
            r += c * t;
            t *= height;
        }
        return r;
    }

    ///frees the chunk's blocks, does not free the chunk itself
    ///the chunk must only be 1 ref before calling, use WaitForRefAmount
    ///locks the chunk
    pub fn free(self: *@This(), allocator: std.mem.Allocator) void {
        const freeChunk = ztracy.ZoneNC(@src(), "freeChunk", 11999);
        defer freeChunk.End();
        std.debug.assert(self.ref_count.load(.seq_cst) == 1);
        self.lock.lock();
        switch (self.blocks) {
            .blocks => {
                allocator.destroy(self.blocks.blocks);
            },
            .oneBlock => {},
        }
    }

    pub fn WaitForRefAmount(self: *const @This(), comptime amount: u32, comptime maxMicroTime: ?u64) bool {
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
        terrainblockRandomness: f32, //must be from 0 to 1
        TerrainNoise: Noise.Noise(f32),
        TreeNoise: Noise.Noise(f32),
        terrainNoiseBalance: f32, //from 0 to 1, 0 is terrainnoise 1 is largeterrainnoise
        LargeTerrainNoise: Noise.Noise(f32),
        LargeTerrainNoiseWarp: Noise.Noise(f32),
        CaveNoise: Noise.Noise(f32),
        terrainmin: i32,
        terrainmax: i32,
        SeaLevel: i32,
        Cavesess: f32,
        CaveExpansionMax: f32,
        CaveExpansionStart: f32,
        seed: u64,
        terrainScale: f32,
        genStructures: bool,
    };
};
