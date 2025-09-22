const Block = @import("Block").Blocks;
const ztracy = @import("ztracy");
const Noise = @import("fastnoise.zig");
const Cache = @import("Cache").Cache;
const Interpolation = @import("Interpolation");
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
var temp2D: [4][4]f32 = undefined;
var valuesY: [4][4]f32 = undefined;
var valuesX2d: [16][4]f32 = undefined;
pub const Chunk = struct {
    blocks: BlockEncoding,
    lock: std.Thread.RwLock,
    genstate: std.atomic.Value(Genstate),
    ref_count: std.atomic.Value(u32), //must count being in a hashmap as a refrence
    pub fn GenChunk(Pos: [3]i32, TerrainHeightCache: *Cache([2]i32, [32][32]i32, 8192), gen_params: GenParams, allocator: std.mem.Allocator) !@This() {
        //TODO SIMD perlin for HUGE speed increce
        const thamountup: f32 = 1.0 / @as(f32, @floatFromInt(@abs(gen_params.terrainmax)));
        const thamountdown: f32 = 1.0 / @as(f32, @floatFromInt(@abs(gen_params.terrainmin)));
        const thamounts: [2]f32 = .{ thamountup, thamountdown };
        var chunk: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        const gc = ztracy.ZoneNC(@src(), "GenChunkHeights", 1);
        const heights = GetTerrainHeight([2]i32{ Pos[0], Pos[2] }, gen_params, TerrainHeightCache);
        //  std.debug.print("hit/miss percent: {d}%, theoretical percent: {d}%                 \r", .{ @as(f32, @floatFromInt(cacheHits.load(.seq_cst))) / @as(f32, @floatFromInt(cacheMisses.load(.seq_cst) + cacheHits.load(.seq_cst))), 20.0 / 21.0 });
        gc.End();
        var rng = std.Random.DefaultPrng.init(gen_params.seed +% @as(u64, @truncate(@as(u96, @bitCast(Pos)))));
        var rand = rng.random();
        var LastBlock: ?Block = null;
        var isOneBlock = true;
        const gen = ztracy.ZoneNC(@src(), "GenChunkBlocks", 867674577);
        const genterra = ztracy.ZoneNC(@src(), "GenTerrainBlocks", 22466);
        var block_height_vec: @Vector(ChunkSize, i32) = undefined;
        for (0..ChunkSize) |i| block_height_vec[i] = (Pos[1] * ChunkSize) + @as(i32, @intCast(i));
        for (heights, 0..) |row, x| {
            for (0..ChunkSize) |c| {
                for (row, 0..) |terrain_height, z| {
                    const block: Block = GetSurfaceBlock(block_height_vec[c], terrain_height, thamounts, gen_params.SeaLeval, &rand, gen_params.terrainblockRandomness);
                    chunk[x][c][z] = block;

                    if (LastBlock != null and LastBlock != block) isOneBlock = false;
                    LastBlock = block;
                }
            }
        }
        genterra.End();
        if (!(isOneBlock and LastBlock == Block.Air)) {
            const caves = ztracy.ZoneNC(@src(), "GenCaves", 13552);
            defer caves.End();
            var grid: [4][4][4]f32 = undefined; //TODO make threadlocal var
            const floatPos: @Vector(3, f32) = @Vector(3, f32){ @floatFromInt(Pos[0]), @floatFromInt(Pos[1]), @floatFromInt(Pos[2]) };

            const caveNoise = ztracy.ZoneNC(@src(), "caveNoise", 33211);
            // Sample at 4x4x4 points across the chunk area
            for (0..4) |x| {
                for (0..4) |y| {
                    for (0..4) |z| {
                        const sample_offset = @Vector(3, f32){ @as(f32, @floatFromInt(x)) * 32.0 / 3.0, @as(f32, @floatFromInt(y)) * 32.0 / 3.0, @as(f32, @floatFromInt(z)) * 32.0 / 3.0 } / @Vector(3, f32){ 32, 32, 32 };
                        const pos = floatPos + sample_offset;
                        grid[x][y][z] = gen_params.CaveNoise.genNoise3D(pos[0], pos[1], pos[2]);
                    }
                }
            }
            caveNoise.End();

            const inter = ztracy.ZoneNC(@src(), "Interpolate", 4221432);
            defer inter.End(); //TODO linear interpolate 3d noise for caves and maybe terrain and rivers, biomes and more
            const initinterp = ztracy.ZoneNC(@src(), "initinterp", 23434);
            var int = Interpolation.NaturalCubicInterpolator3D.init(grid);
            initinterp.End();
            const oneD32: f32 = comptime 1.0 / 32.0;
            comptime var zs: @Vector(32, f32) = undefined;
            comptime for (0..32) |i| {
                zs[i] = @as(f32, @floatFromInt(i)) * oneD32;
            };

            const xs: @Vector(32, f32) = comptime zs;

            const ys: @Vector(32, f32) = comptime zs;

            @setEvalBranchQuota(32000);
            inline for (0..ChunkSize) |x| {
                for (0..ChunkSize) |y| {
                    const realY = (floatPos[1] * ChunkSize) + @as(f32, @floatFromInt(y));
                    const m: f32 = 1 - (1 / -@min(-1, (realY / gen_params.CaveExpansionMax) - 1));
                    //std.debug.print("y: {d}, m:{d}\n", .{ -@min(-1, floatPos[1] + @as(f32, @floatFromInt(y))), m });
                    const cavesess: f32 = (gen_params.Cavesess + (m * 2));
                    //const n: @Vector(ChunkSize, f32) = Interpolation.trilinearInterpolateBatch(ChunkSize, f32, grid, @splat(xs[x]), @splat(ys[y]), zs);
                    //const air = n < cavesessvec;
                    inline for (0..ChunkSize) |z| {
                        const n = int.sampleComptimeXZ(xs[x], ys[y], zs[z]);
                        const isair = n < cavesess;
                        if (isair) {
                            chunk[x][y][z] = .Air;
                            if (LastBlock != null and LastBlock != .Air) isOneBlock = false;
                            LastBlock = .Air;
                        }
                    }
                }
            }
        }
        //
        //TODO caves (maybe tricubic interpolated 3d noise?)
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
        if (self.blocks != .oneBlock) return error.InvalidState;
        var blocks: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        @memset(&blocks, @splat(@splat(self.blocks.oneBlock)));
        const mem = try allocator.create([ChunkSize][ChunkSize][ChunkSize]Block);
        mem.* = blocks;
        self.blocks = BlockEncoding{ .blocks = mem };
    }

    fn GetSurfaceBlock(block_height: i32, terrain_height: i32, thamount: [2]f32, SeaLevel: i32, rand: *std.Random, blockRandomness: f32) Block {
        if (block_height < terrain_height - 5) {
            return Block.Stone;
        } else if (block_height < terrain_height) {
            return Block.Dirt;
        } else if (block_height == terrain_height) {
            return RandGround(rand, @as(f32, @floatFromInt(terrain_height)) * thamount[@intFromBool(terrain_height > SeaLevel)], block_height, SeaLevel, blockRandomness);
        } else if (block_height > terrain_height and block_height < SeaLevel) {
            return Block.Water;
        } else {
            return Block.Air;
        }
    }

    fn RandGround(rand: *std.Random, heightPercent: f32, block_height: i32, seaLevel: i32, blockRandomness: f32) Block {
        // std.debug.print("hp: {d}", .{heightPercent});
        //
        const a = std.math.lerp(heightPercent, rand.float(f32), blockRandomness);
        return if (block_height < seaLevel) Block.Dirt else if (a < 0.6) Block.Grass else if (a < 0.7) Block.Dirt else if (a < 0.8) Block.Stone else Block.Snow;
    }

    pub fn GetHeightsFromCache(Pos: [2]i32, TerrainHeightCache: *Cache([2]i32, [32][32]i32, 8192)) ?[ChunkSize][ChunkSize]i32 {
        const gth = ztracy.ZoneNC(@src(), "GetTerrainHeightsFromCache", 110029);
        defer gth.End();
        if (TerrainHeightCache.get(Pos)) |T| {
            @branchHint(.likely);
            _ = cacheHits.fetchAdd(1, .seq_cst);
            return T;
        }
        return null;
    }

    pub fn GetTerrainHeight(Pos: [2]i32, params: GenParams, TerrainHeightCache: *Cache([2]i32, [32][32]i32, 8192)) [ChunkSize][ChunkSize]i32 {
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
        const d32: f32 = comptime 1.0 / 32.0;
        var height: [ChunkSize][ChunkSize]i32 = undefined;
        const floatmin: f32 = @floatFromInt(params.terrainmin);
        const floatmax: f32 = @floatFromInt(params.terrainmax);
        const floatBounds = @Vector(2, f32){ floatmin, floatmax };
        for (0..ChunkSize) |ux| {
            const x: f32 = (@as(f32, @floatFromInt(ux)) * d32) + floatpos[0];
            for (0..ChunkSize) |uz| {
                const z: f32 = (@as(f32, @floatFromInt(uz)) * d32) + floatpos[1];
                const terrainNoise = params.TerrainNoise.genNoise2D(x, z);
                const largeterrainNoise = params.LargeTerrainNoise.genNoise2D(x, z);

                const noise = std.math.lerp(terrainNoise, largeterrainNoise, params.terrainNoiseBalance);
                //uses lower or upper terrain height bound depending on if noise is less or greater than 0
                const block_height: i32 = @intFromFloat(noise * @abs(floatBounds[@intFromBool(noise < 0)]));
                height[ux][uz] = block_height;
            }
        }
        _ = cacheMisses.fetchAdd(1, .seq_cst);
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
        terrainblockRandomness: f32, //must be from 0 to 1
        TerrainNoise: Noise.Noise(f32),
        terrainNoiseBalance: f32, //from 0 to 1, 0 is terrainnoise 1 is largeterrainnoise
        LargeTerrainNoise: Noise.Noise(f32),
        CaveNoise: Noise.Noise(f32),
        terrainmin: i32,
        terrainmax: i32,
        SeaLeval: i32,
        Cavesess: f32,
        CaveExpansionMax: f32,
        CaveExpansionStart: f32,
        seed: u64,
    };
};
