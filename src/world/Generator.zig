const std = @import("std");
const Interpolation = @import("root").Interpolation;

const Block = @import("Chunk").Block;
const Cache = @import("Cache").Cache;
const Chunk = @import("Chunk").Chunk;
const ChunkSize = Chunk.ChunkSize;
const ztracy = @import("ztracy");

const BufferFallbackAllocator = @import("BufferFallbackAllocator.zig");
const World = @import("World.zig").World;
const ChunkPos = World.ChunkPos;

pub const DefaultGenerator = struct {
    pub const Noise = @import("fastnoise.zig");
    params: GenParams,
    TerrainHeightCache: Cache(struct { pos: [2]i32, level: i32 }, [ChunkSize][ChunkSize]i32),

    pub fn getSource(self: *DefaultGenerator) World.ChunkSource {
        return .{
            .data = self,
            .getTerrainHeight = &getTerrainHeightAtCoords,
            .getBlocks = &genChunkBlocks,
            .onLoad = genStructures, //TODO
            .deinit = &deinit,
            .onUnload = null,
        };
    }

    fn getTerrainHeightAtCoords(source: World.ChunkSource, world: *World, Pos: @Vector(2, i32)) error{ OutOfMemory, Unrecoverable }![ChunkSize][ChunkSize]i32 {
        _ = world;
        const self: *DefaultGenerator = @ptrCast(@alignCast(source.data));
        return self.GetTerrainHeight(Pos, 0);
    }

    fn genChunkBlocks(source: World.ChunkSource, world: *World, blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, Pos: ChunkPos) error{ Unrecoverable, OutOfMemory }!bool {
        _ = world;
        const self: *DefaultGenerator = @ptrCast(@alignCast(source.data));
        try self.GenChunk(Pos, blocks);
        return true;
    }

    fn genStructures(source: World.ChunkSource, world: *World, chunk: *Chunk, Pos: ChunkPos) error{ OutOfMemory, Unrecoverable }!void {
        const self: *DefaultGenerator = @ptrCast(@alignCast(source.data));
        //if (Pos.level != World.StandardLevel) return; //dont generate structures on non LOD chunks for now
        self.GenerateStructures(world, chunk, Pos) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
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
        trees: []TreeConfig,
    };

    pub const TreeConfig = struct {
        enabled: bool = true,
        steps: []World.Editor.Tree.Step,
        baseRadius: f32,
        baseRadiusVariation: f32,
        trunkHeight: f32,
        trunkHeightVariation: f32,
        leafDensity: f32,
        leafSize: f32,
    };

    pub fn GenChunk(self: *DefaultGenerator, Pos: ChunkPos, blocks: *[ChunkSize][ChunkSize][ChunkSize]Block) !void {
        const chunkscale = 1.0 / ChunkPos.toScale(Pos.level);
        const gc = ztracy.ZoneNC(@src(), "GenChunkHeights", 1);
        const heights = self.GetTerrainHeight([2]i32{ Pos.position[0], Pos.position[2] }, Pos.level);
        //  std.debug.print("hit/miss percent: {d}%, theoretical percent: {d}%                 \r", .{ @as(f32, @floatFromInt(cacheHits.load(.seq_cst))) / @as(f32, @floatFromInt(cacheMisses.load(.seq_cst) + cacheHits.load(.seq_cst))), 20.0 / 21.0 });
        gc.End();
        var rng = std.Random.DefaultPrng.init(self.params.seed +% @as(u64, @truncate(@as(u96, @bitCast(Pos.position))))); //TODO make this more deterministic especially at diffrent scales
        var rand = rng.random();
        const gen = ztracy.ZoneNC(@src(), "GenChunkBlocks", 867674577);
        const genterra = ztracy.ZoneNC(@src(), "GenTerrainBlocks", 22466);
        GenerateTerrain(blocks, Pos, &heights, &self.params, &rand, @floatCast(chunkscale));
        genterra.End();
        var oneBlock = Chunk.IsOneBlock(blocks);
        if (oneBlock == null or oneBlock.? == Block.Stone or oneBlock.? == Block.Water) {
            GenerateCavesInterpolate(blocks, Pos, &heights, @floatCast(chunkscale), self.params);
            oneBlock = Chunk.IsOneBlock(blocks);
        }
        gen.End();
    }

    fn GenerateTerrain(chunkBlocks: *[ChunkSize][ChunkSize][ChunkSize]Block, Pos: ChunkPos, heights: *const [ChunkSize][ChunkSize]i32, gen_params: *const GenParams, rand: *std.Random, chunkScale: f32) void {
        const terrainScaleUp: f32 = 1.0 / @as(f32, @floatFromInt(@abs(gen_params.terrainmax)));
        const terrainScaleDown: f32 = 1.0 / @as(f32, @floatFromInt(@abs(gen_params.terrainmin)));
        const terrainScales: [2]f32 = .{ terrainScaleUp, terrainScaleDown };
        const scale = gen_params.terrainScale * chunkScale;
        const oneDterrainScale: f32 = 1.0 / scale;
        var block_height_vec: [ChunkSize]i64 = undefined;
        const chunkBlockPos = Pos.position * @as(@Vector(3, i64), @splat(ChunkSize));
        for (0..ChunkSize) |i| block_height_vec[i] = chunkBlockPos[1] + @as(i64, @intCast(i));
        for (heights, 0..) |row, x| {
            for (0..ChunkSize) |c| {
                for (row, 0..) |terrain_height, z| {
                    chunkBlocks[x][c][z] = GetSurfaceBlock(block_height_vec[c], terrain_height, terrainScales, gen_params.SeaLevel, rand, gen_params.terrainblockRandomness, oneDterrainScale);
                }
            }
        }
    }
    fn GenerateCavesInterpolate(chunkBlocks: *[ChunkSize][ChunkSize][ChunkSize]Block, Pos: ChunkPos, heights: *const [ChunkSize][ChunkSize]i32, chunkScale: f32, gen_params: GenParams) void {
        const caves = ztracy.ZoneNC(@src(), "GenCaves", 13552);
        defer caves.End();
        var grid: [4][4][4]f32 = undefined;
        const floatPos: @Vector(3, f32) = @Vector(3, f32){ @floatFromInt(Pos.position[0]), @floatFromInt(Pos.position[1]), @floatFromInt(Pos.position[2]) };
        const onedthreeVec: @Vector(3, f32) = comptime @splat(1.0 / 3.0);
        const oneDterrainScaleVec: @Vector(3, f32) = @splat(1.0 / (gen_params.terrainScale * chunkScale));
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

    fn GenerateCavesFull(chunkBlocks: *[ChunkSize][ChunkSize][ChunkSize]Block, Pos: ChunkPos, heights: *const [ChunkSize][ChunkSize]i32, chunkScale: f32, gen_params: GenParams) void {
        const caves = ztracy.ZoneNC(@src(), "GenCaves", 13552);
        defer caves.End();
        const floatPos: @Vector(3, f32) = @Vector(3, f32){ @floatFromInt(Pos.position[0]), @floatFromInt(Pos.position[1]), @floatFromInt(Pos.position[2]) };
        const oneDterrainScaleVec: @Vector(3, f32) = @splat(1.0 / (gen_params.terrainScale * chunkScale));
        _ = heights;
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |y| {
                for (0..ChunkSize) |z| {
                    const xyz = @Vector(3, f32){ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) } / @as(@Vector(3, f32), @splat(ChunkSize));
                    const pos = (floatPos + xyz) * oneDterrainScaleVec;
                    const noise = gen_params.CaveNoise.genNoise3D(pos[0], pos[1], pos[2]);
                    const realY = ((floatPos[1] * ChunkSize) + @as(f32, @floatFromInt(y))) * oneDterrainScaleVec[0];
                    const m: f32 = 1 - (1 / -@min(-1, (realY / gen_params.CaveExpansionMax) - 1));
                    const cavesess: f32 = (gen_params.Cavesess + (m * 2));
                    if (noise < cavesess) {
                        chunkBlocks[x][y][z] = .Air;
                    }
                }
            }
        }
    }

    fn GetSurfaceBlock(block_height: i64, terrain_height: i64, thamount: [2]f32, SeaLevel: i32, rand: *std.Random, blockRandomness: f32, oneDterrainScale: f32) Block {
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

    fn RandGround(rand: *std.Random, heightPercent: f32, block_height: i64, seaLevel: i64, blockRandomness: f32, oneDterrainScale: f32) Block {
        const a = std.math.lerp(heightPercent * oneDterrainScale, rand.float(f32), blockRandomness);
        return if (block_height < seaLevel) Block.Dirt else if (a < 0.25) Block.Grass else if (a < 0.4) Block.Dirt else if (a < 0.6) Block.Stone else Block.Snow;
    }

    pub fn GetTerrainHeight(self: *DefaultGenerator, Pos: [2]i32, level: i32) [ChunkSize][ChunkSize]i32 {
        const gth = ztracy.ZoneNC(@src(), "GetTerrainHeights", 662291);
        defer gth.End();
        if (self.TerrainHeightCache.get(.{ .pos = Pos, .level = level })) |cachedHeight| return cachedHeight;
        const generatedHeights = GenTerrainHeight(self.params, level, Pos);
        self.TerrainHeightCache.put(.{ .pos = Pos, .level = level }, generatedHeights) catch |err| std.debug.panic("{any}\n", .{err});
        return generatedHeights;
    }

    fn GenTerrainHeight(params: GenParams, level: i32, Pos: [2]i32) [ChunkSize][ChunkSize]i32 {
        const gth = ztracy.ZoneNC(@src(), "GenTerrainHeights", 662291);
        defer gth.End();
        const chunkSizeGenScale = 1.0 / @as(f32, @floatCast(World.ChunkPos.toScale(level)));
        const scale = (params.terrainScale * chunkSizeGenScale);
        const floatpos = @Vector(2, f32){ @floatFromInt(Pos[0]), @floatFromInt(Pos[1]) };
        const d32: f32 = comptime 1.0 / @as(comptime_float, ChunkSize);
        var height: [ChunkSize][ChunkSize]i32 = undefined;
        const floatmin: f32 = @floatFromInt(params.terrainmin);
        const floatmax: f32 = @floatFromInt(params.terrainmax);
        const floatBounds = [2]f32{ floatmin, floatmax };
        const oneDterrainscale: f32 = 1.0 / scale;
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
                const block_height: i32 = @intFromFloat(@round(E * @abs(floatBounds[@intFromBool(E > 0)]) * scale));
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
    fn GenerateStructures(self: *DefaultGenerator, world: *World, chunk: *Chunk, Pos: ChunkPos) !void {
        const genstructures = ztracy.ZoneNC(@src(), "generate_structures", 94);
        defer genstructures.End();
        chunk.addAndLockShared();
        var editorBuffer: [100_000]u8 = undefined;
        var bfa: BufferFallbackAllocator.BufferFallbackAllocator() = .{
            .buffer = &editorBuffer,
            .fallback_allocator = world.allocator,
            .fixed_buffer_allocator = undefined,
        };
        const tempAllocator = bfa.get();
        var worldEditor = World.Editor{ .world = world, .tempallocator = tempAllocator};
        defer _ = worldEditor.flush() catch |err| std.debug.panic("failed to flush WorldEditor: {any}\n", .{err});
        defer chunk.releaseAndUnlockShared();
        if (chunk.genstate.load(.seq_cst) != .TerrainGenerated) return;
        if (chunk.blocks != .blocks) return;
        if (!self.params.genStructures) return;
        const heights = self.GetTerrainHeight([2]i32{ Pos.position[0], Pos.position[2] }, Pos.level); //should still be in the cache
        const scale: f32 = self.params.terrainScale * (1.0 / ChunkPos.toScale(Pos.level));

        for (heights, 0..) |row, x| {
            for (row, 0..) |height, z| {
                if (@divFloor(height, ChunkSize) != Pos.position[1] or height < self.params.SeaLevel) continue;
                const y: usize = @intCast(@mod(height, ChunkSize));
                if (!chunk.blocks.blocks[x][y][z].plantsCanGrow()) continue;

                const realX: f32 = @as(f32, @floatFromInt((Pos.position[0] * ChunkSize) + @as(i32, @intCast(@mod(x, ChunkSize))))) / scale;
                const realZ: f32 = @as(f32, @floatFromInt((Pos.position[2] * ChunkSize) + @as(i32, @intCast(@mod(z, ChunkSize))))) / scale;

                const noise = self.params.TreeNoise.genNoise2D(realX, realZ);

                for (self.params.trees) |tree_conf| {
                    if (!tree_conf.enabled) continue;
                    if (isTree(noise, scale)) {
                        const centerPos = ((Pos.position * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize })) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) };
                        if (Pos.level > 2) {
                            try placeLowResTree(&worldEditor, centerPos, scale, tree_conf.trunkHeight, Pos.level);
                        } else {
                            const realY: f32 = @as(f32, @floatFromInt((Pos.position[1] * ChunkSize) + @as(i32, @intCast(@mod(y, ChunkSize))))) / scale;
                            const realPos = @Vector(3, f32){ realX, realY, realZ };
                            try placeTree(&worldEditor, centerPos, scale, realPos, tree_conf, self.params.seed, Pos.level);
                        }
                    }
                }
            }
        }
    }

    fn placeTree(editor: *World.Editor, pos: World.BlockPos, scale: f32, real_pos: @Vector(3, f32), conf: TreeConfig, seed: u64, level: i32) !void {
        const round_to: @Vector(3, f32) = @splat(1.0 / 5.0); //round so slight pos diffrences dont change tree properties
        const rounded_pos = @round(real_pos * round_to);
        const randomSeed = std.hash.Wyhash.hash(seed, std.mem.asBytes(&rounded_pos));
        var random = std.Random.DefaultPrng.init(randomSeed);
        const rand = random.random();
        const factor = ((rand.float(f32) - 0.5) * (conf.baseRadiusVariation));
        var placetree: World.Editor.Tree = .{
            .pos = @intCast(pos),
            .scale = scale,
            .rand = rand,
            .leafSize = conf.leafSize,
            .leafDensity = conf.leafDensity,
            .maxRecursionDepth = conf.steps.len - 1,
            .steps = conf.steps,
            .trunkHeight = conf.trunkHeight + conf.trunkHeight * factor,
            .baseRadius = conf.baseRadius + conf.baseRadius * factor,
        };
        _ = try placetree.place(editor, level);
    }

    fn placeLowResTree(editor: *World.Editor, pos: World.BlockPos, scale: f32, height: f32, level: i32) !void {
        const radius: f32 = (height * scale);
        if (radius < 0.5) {
            try editor.placeBlock(.Leaves, pos + @Vector(3, i64){ 0, 1, 0 }, level);
            return;
        }
        const sphere = World.Editor.Geometry.Sphere(f32).init(@floatFromInt(pos + @Vector(3, i64){ 0, @intFromFloat(radius), 0 }), radius);
        _ = try editor.placeSamplerShape(.Leaves, sphere, level);
    }

    fn isTree(noise: f32, scale: f32) bool {
        const cutoff = 0.0001; //any noise less than this will be a tree, if this is too high trees will be stacked on top of each other
        return noise < -1.0 + cutoff / scale;
    }
};
