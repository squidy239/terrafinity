const std = @import("std");
const Interpolation = @import("root").Interpolation;

const Block = @import("Block").Blocks;
const Cache = @import("Cache").Cache;
const Chunk = @import("Chunk").Chunk;
const ChunkSize = Chunk.ChunkSize;
const ztracy = @import("ztracy");

const BufferFallbackAllocator = @import("BufferFallbackAllocator.zig");
const World = @import("World.zig").World;

pub const DefaultGenerator = struct {
    pub const Noise = @import("fastnoise.zig");
    params: GenParams,
    TerrainHeightCache: Cache([2]i32, [ChunkSize][ChunkSize]i32),

    pub fn getGenerator(self: *DefaultGenerator) World.ChunkSource {
        return .{
            .data = self,
            .getTerrainHeight = &getTerrainHeightAtCoords,
            .getBlocks = &genChunkBlocks,
            .onLoad = &genStructures,
            .deinit = &deinit,
            .onUnload = null,
        };
    }

    fn getTerrainHeightAtCoords(self: World.ChunkSource, world: *World, Pos: @Vector(2, i32)) error{ OutOfMemory, Unrecoverable }![ChunkSize][ChunkSize]i32 {
        _ = world;
        const generator: *DefaultGenerator = @ptrCast(@alignCast(self.data));
        return GetTerrainHeight(Pos, generator.params, &generator.TerrainHeightCache);
    }

    fn genChunkBlocks(self: World.ChunkSource, world: *World, blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, Pos: [3]i32) error{ Unrecoverable, OutOfMemory }!bool {
        _ = world;
        const generator: *DefaultGenerator = @ptrCast(@alignCast(self.data));
        try GenChunk(Pos, &generator.TerrainHeightCache, generator.params, blocks);
        return true;
    }

    fn genStructures(self: World.ChunkSource, world: *World, chunk: *Chunk, Pos: [3]i32) error{ OutOfMemory, Unrecoverable }!void {
        const generator: *DefaultGenerator = @ptrCast(@alignCast(self.data));
        try GenerateStructures(world, generator.params, chunk, Pos, &generator.TerrainHeightCache);
    }

    fn deinit(self: World.ChunkSource, world: *World) void {
        _ = world;
        const generator: *DefaultGenerator = @ptrCast(@alignCast(self.data));
        generator.TerrainHeightCache.deinit();
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
        LargeTrees: []const World.Tree.Step,
        MediumTrees: []const World.Tree.Step,
    };

    pub fn GenChunk(Pos: [3]i32, TerrainHeightCache: *Cache([2]i32, [ChunkSize][ChunkSize]i32), gen_params: GenParams, blocks: *[ChunkSize][ChunkSize][ChunkSize]Block) !void {
        //TODO make terrain generation more customisable and move it to a diffrent file
        const gc = ztracy.ZoneNC(@src(), "GenChunkHeights", 1);
        const heights = GetTerrainHeight([2]i32{ Pos[0], Pos[2] }, gen_params, TerrainHeightCache);
        //  std.debug.print("hit/miss percent: {d}%, theoretical percent: {d}%                 \r", .{ @as(f32, @floatFromInt(cacheHits.load(.seq_cst))) / @as(f32, @floatFromInt(cacheMisses.load(.seq_cst) + cacheHits.load(.seq_cst))), 20.0 / 21.0 });
        gc.End();
        var rng = std.Random.DefaultPrng.init(gen_params.seed +% @as(u64, @truncate(@as(u96, @bitCast(Pos)))));
        var rand = rng.random();
        const gen = ztracy.ZoneNC(@src(), "GenChunkBlocks", 867674577);
        const genterra = ztracy.ZoneNC(@src(), "GenTerrainBlocks", 22466);
        GenerateTerrain(blocks, Pos, &heights, &gen_params, &rand);
        genterra.End();
        var oneBlock = Chunk.IsOneBlock(blocks);
        if (oneBlock == null or oneBlock.? == Block.Stone or oneBlock.? == Block.Water) {
            GenerateCaves(blocks, Pos, &heights, &gen_params);
            oneBlock = Chunk.IsOneBlock(blocks);
        }
        gen.End();
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

    pub fn GetHeightsFromCache(Pos: [2]i32, TerrainHeightCache: *Cache([2]i32, [ChunkSize][ChunkSize]i32)) ?[ChunkSize][ChunkSize]i32 {
        const gth = ztracy.ZoneNC(@src(), "GetTerrainHeightsFromCache", 110029);
        defer gth.End();
        if (TerrainHeightCache.get(Pos)) |T| {
            @branchHint(.likely);
            return T;
        }
        return null;
    }

    pub fn GetTerrainHeight(Pos: [2]i32, params: GenParams, TerrainHeightCache: *Cache([2]i32, [ChunkSize][ChunkSize]i32)) [ChunkSize][ChunkSize]i32 {
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
    threadlocal var editorBuffer: [1_000_000]u8 = undefined;
    fn GenerateStructures(self: *World, genParams: GenParams, chunk: *Chunk, Pos: [3]i32, terrainHeightCache: *Cache([2]i32, [ChunkSize][ChunkSize]i32)) !void {
        const genstructures = ztracy.ZoneNC(@src(), "generate_structures", 94);
        defer genstructures.End();
        chunk.addAndLockShared();
        var bfa: BufferFallbackAllocator.BufferFallbackAllocator() = .{
            .buffer = &editorBuffer,
            .fallback_allocator = self.allocator,
            .fixed_buffer_allocator = undefined,
        };
        const tempAllocator = bfa.get();
        var worldEditor = World.WorldEditor{ .world = self, .tempallocator = tempAllocator };
        defer _ = worldEditor.flush() catch |err| std.debug.panic("failed to flush WorldEditor: {any}\n", .{err});
        defer chunk.releaseAndUnlockShared();
        if (chunk.genstate.load(.seq_cst) != .TerrainGenerated) return;
        if (chunk.blocks != .blocks) return;
        if (!genParams.genStructures) return;
        const randomSeed = std.hash.Wyhash.hash(genParams.seed, std.mem.asBytes(&Pos));
        var random = std.Random.DefaultPrng.init(randomSeed);
        const rand = random.random();
        const heights = GetTerrainHeight([2]i32{ Pos[0], Pos[2] }, genParams, terrainHeightCache); //should still be in the cache

        var structuresGenerated: u32 = 0;

        for (heights, 0..) |row, x| {
            for (row, 0..) |height, z| {
                const realX: f32 = @as(f32, @floatFromInt((Pos[0] * ChunkSize) + @as(i32, @intCast(@mod(x, ChunkSize))))) / genParams.terrainScale;
                const realZ: f32 = @as(f32, @floatFromInt((Pos[2] * ChunkSize) + @as(i32, @intCast(@mod(z, ChunkSize))))) / genParams.terrainScale;
                if (@divFloor(height, ChunkSize) != Pos[1] or height < genParams.SeaLevel) continue;
                const y: usize = @intCast(@mod(height, ChunkSize));

                if (chunk.blocks.blocks[x][y][z] == .Grass or chunk.blocks.blocks[x][y][z] == .Dirt) {
                    //TODO find a way to make it deterministi becuase a diffrent thread may remove grass or dirt blocks
                    const treeChance: f64 = rand.float(f64) * genParams.terrainScale; //TODO advance rng to make tree placement the same
                    if (true and treeChance < 0.000002) {
                        const steps = genParams.LargeTrees;
                        const centerPos = ((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize })) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) } + @Vector(3, i32){ 0, -10, 0 };
                        const tree = World.Tree{
                            .pos = @intCast(centerPos),
                            .baseRadius = 15,
                            .rand = rand,
                            .trunkHeight = 100,
                            .maxRecursionDepth = 8,
                            .leafDensity = 0.5,
                            .leafSize = 6,
                            .scale = genParams.terrainScale,
                            .steps = steps,
                        };

                        _ = try tree.place(&worldEditor);
                    } else if (genParams.TreeNoise.genNoise2D(realX, realZ) < -0.99995) {
                        structuresGenerated += 1;
                        const factor = rand.float(f32) + 0.5; //TODO replace a lot of rand with hashes
                        const centerPos = ((Pos * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize })) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) };
                        const steps = genParams.MediumTrees;
                        const tree = World.Tree{
                            .pos = @intCast(centerPos),
                            .baseRadius = 3 * factor,
                            .rand = rand,
                            .trunkHeight = 25 * factor,
                            .steps = steps,
                            .maxRecursionDepth = 6,
                            .leafDensity = 0.5,
                            .scale = genParams.terrainScale,
                            .leafSize = 3,
                        };

                        _ = try tree.place(&worldEditor);
                    }
                }
            }
        }
    }
};
