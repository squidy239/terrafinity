const std = @import("std");
const builtin = @import("builtin");

const tracy = @import("tracy");

const Cache = @import("../../libs/Cache.zig").Cache;
const Block = @import("../Block.zig").Block;
const BFA = @import("../BufferFirstAllocator.zig");
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const Interpolation = @import("../Interpolation.zig");
const JitteredGrid = @import("../structures/JitteredGrid.zig");
const Tree = @import("../structures/Tree.zig").Tree;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;

pub const DefaultGenerator = struct {
    pub const Noise = @import("fastnoise.zig");
    const thc_fragments = if (builtin.is_test) 1 else 8;

    params: Params,
    terrain_height_cache: Cache(ChunkHeightsKey, ChunkHeightsValue, ChunkHeightsValue.key_from_value, ChunkHeightsKey.hash, .{}, thc_fragments),

    const ChunkHeightsValue = struct {
        value: [ChunkSize][ChunkSize]i32,
        key: ChunkHeightsKey,

        pub inline fn key_from_value(value: *const ChunkHeightsValue) ChunkHeightsKey {
            return value.key;
        }
    };

    const ChunkHeightsKey = packed struct {
        x: i32,
        z: i32,
        level: i32,

        pub inline fn hash(key: ChunkHeightsKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, key);
            return hasher.final();
        }
    };

    pub fn init(allocator: std.mem.Allocator, max_cache_bytes: usize, params: Params) !DefaultGenerator {
        const terrain_height_cache_size = @max(std.math.floorPowerOfTwo(u64, max_cache_bytes / @sizeOf(ChunkHeightsValue)), 256 * thc_fragments);
        std.log.info("Creating terrain height cache with size {d} ({d} bytes)", .{ terrain_height_cache_size, terrain_height_cache_size * @sizeOf(ChunkHeightsValue) });
        return DefaultGenerator{
            .terrain_height_cache = try .init(allocator, terrain_height_cache_size, .{ .name = "terrain_height_cache" }),
            .params = params,
        };
    }

    pub fn getSource(self: *DefaultGenerator) World.ChunkSource {
        return .{
            .data = self,
            .getTerrainHeight = null,
            .getBlocks = &genChunkBlocks,
            .placeStructures = genStructures,
            .deinit = &deinit,
            .save = null,
        };
    }

    fn genChunkBlocks(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, blocks: *Chunk.Encoding, chunk_pos: ChunkPos, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) error{ Unrecoverable, OutOfMemory, Canceled }!?World.ChunkSource.GetBlocksMetadata {
        const self: *DefaultGenerator = @ptrCast(@alignCast(source.data));
        try self.genChunk(io, allocator, chunk_pos, blocks, world, grid_buffer);
        return .{ .from_disk = false, .structures = false };
    }

    fn genStructures(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, chunk: *Chunk, chunk_pos: ChunkPos) error{ OutOfMemory, Canceled, Unrecoverable }!void {
        const self: *DefaultGenerator = @ptrCast(@alignCast(source.data));
        self.generateStructures(io, allocator, world, chunk, chunk_pos) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.Unrecoverable,
        };
    }

    pub fn deinit(self: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World) void {
        _ = world;
        _ = io;
        const generator: *DefaultGenerator = @ptrCast(@alignCast(self.data));
        generator.terrain_height_cache.deinit(allocator);
    }

    pub const Params = struct {
        terrain_block_randomness: f32,
        terrain_noise: Noise.Noise(f32),
        terrain_noise_balance: f32,
        large_terrain_noise: Noise.Noise(f32),
        large_terrain_noise_warp: Noise.Noise(f32),
        cave_noise: Noise.Noise(f32),
        terrain_min: i32,
        terrain_max: i32,
        sea_level: i32,
        cave_threshold: f32,
        cave_expansion_max: f32,
        cave_expansion_start: f32,
        /// If null, a random seed will be generated. Will be set after setSeeds is called.
        seed: ?u64,
        terrain_scale: f32,
        gen_structures: bool,
        trees: []const TreeConfig,

        pub fn setSeeds(self: *Params, io: std.Io) void {
            if (self.seed == null) {
                var random_seed: u64 = undefined;
                io.random(@ptrCast(&random_seed));
                self.seed = random_seed;
            }
            self.cave_noise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(self.seed.? +% 1));
            self.terrain_noise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(self.seed.? +% 3));
            self.large_terrain_noise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(self.seed.? +% 4));
            self.large_terrain_noise_warp.seed = @bitCast(std.hash.Murmur2_32.hashUint64(self.seed.? +% 4));
        }

        pub const default = Params{
            .terrain_block_randomness = 0.25,
            .terrain_noise = .{
                .frequency = 0.002,
                .noise_type = .perlin,
                .rotation_type = .none,
                .fractal_type = .ridged,
                .octaves = 12,
                .lacunarity = 2,
                .gain = 0.5,
                .weighted_strength = 0,
                .ping_pong_strength = 2,
                .cellular_distance = .euclidean_sq,
                .cellular_return = .distance,
                .cellular_jitter_mod = 1,
                .domain_warp_type = .simplex,
                .domain_warp_amp = 10,
            },
            .terrain_noise_balance = 0.9,
            .large_terrain_noise = .{
                .frequency = 0.0008,
                .noise_type = .perlin,
                .rotation_type = .none,
                .fractal_type = .none,
                .octaves = 1,
                .lacunarity = 2,
                .gain = 0.5,
                .weighted_strength = 0,
                .ping_pong_strength = 2,
                .cellular_distance = .euclidean_sq,
                .cellular_return = .distance,
                .cellular_jitter_mod = 1,
                .domain_warp_type = .simplex,
                .domain_warp_amp = 1,
            },
            .large_terrain_noise_warp = .{
                .frequency = 0.002,
                .noise_type = .simplex,
                .rotation_type = .improve_xy_planes,
                .fractal_type = .independent,
                .octaves = 1,
                .lacunarity = 2,
                .gain = 0.5,
                .weighted_strength = 0,
                .ping_pong_strength = 2,
                .cellular_distance = .euclidean_sq,
                .cellular_return = .distance,
                .cellular_jitter_mod = 1,
                .domain_warp_type = .simplex,
                .domain_warp_amp = 400,
            },
            .cave_noise = .{
                .frequency = 0.08,
                .noise_type = .perlin,
                .rotation_type = .none,
                .fractal_type = .ping_pong,
                .octaves = 4,
                .lacunarity = 2,
                .gain = 0.5,
                .weighted_strength = 0,
                .ping_pong_strength = 2,
                .cellular_distance = .euclidean_sq,
                .cellular_return = .distance,
                .domain_warp_type = .simplex,
                .domain_warp_amp = 1,
            },
            .terrain_min = -4096,
            .terrain_max = 8196,
            .sea_level = 0,
            .cave_threshold = -10000.0,
            .cave_expansion_max = 8192,
            .cave_expansion_start = 0,
            .seed = null,
            .terrain_scale = 1,
            .gen_structures = true,
            .trees = &.{ .{
                .placer = .{ .box_size = 2048, .inner_box_size = 1800 },
                .enabled = true,
                .size_variation = 0.5,
                .tree = .huge,
            }, .{
                .placer = .{ .box_size = 32, .inner_box_size = 25 },
                .enabled = true,
                .size_variation = 0.5,
                .tree = .small,
            } },
        };
    };

    pub const TreeConfig = struct {
        placer: JitteredGrid = .{},
        enabled: bool = true,
        size_variation: f32,
        tree: Tree.Config,
    };

    pub fn genChunk(self: *DefaultGenerator, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, blocks: *Chunk.Encoding, world: *World, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) !void {
        @setFloatMode(.optimized);
        const chunk_scale = 1.0 / ChunkPos.toScale(chunk_pos.level);
        const gen = tracy.Zone.begin(.{ .src = @src() });
        defer gen.end();
        _ = world;
        if (chunk_pos.position[1] > ChunkPos.fromGlobalBlockPos(.{ 0, self.params.terrain_max, 0 }, chunk_pos.level).position[1]) {
            blocks.merge(.{ .uniform = .air }, grid_buffer);
            return;
        }
        var heights: ?[ChunkSize][ChunkSize]i32 = null;
        var block_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = comptime @splat(@splat(@splat(.null)));
        if (chunk_pos.position[1] < ChunkPos.fromGlobalBlockPos(.{ 0, self.params.terrain_min, 0 }, chunk_pos.level).position[1]) {
            blocks.merge(.{ .uniform = .stone }, grid_buffer);
        } else {
            var rng = std.Random.DefaultPrng.init(self.params.seed.? +% @as(u64, @truncate(@as(u96, @bitCast(chunk_pos.position)))));
            var rand = rng.random();
            heights = try self.getTerrainHeight(io, allocator, [2]i32{ chunk_pos.position[0], chunk_pos.position[2] }, chunk_pos.level);
            const gen_terra = tracy.Zone.begin(.{ .src = @src(), .name = "GenTerrainBlocks" });
            generateTerrain(&block_grid, chunk_pos, heights.?, &self.params, &rand, @floatCast(chunk_scale));
            gen_terra.end();
            const one_block = Chunk.getUniform(&block_grid);
            if (one_block != null and one_block.? == .air) {
                blocks.merge(.{ .uniform = .air }, grid_buffer);
                return;
            }
        }
        generateCavesInterpolate(&block_grid, chunk_pos, @floatCast(chunk_scale), self.params);
        const one_block = Chunk.getUniform(&block_grid);
        if (one_block) |block| {
            blocks.merge(.{ .uniform = block }, grid_buffer);
        } else blocks.merge(.{ .grid = &block_grid }, grid_buffer);
    }

    fn generateTerrain(chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_pos: ChunkPos, heights: [ChunkSize][ChunkSize]i32, gen_params: *const Params, rand: *std.Random, chunk_scale: f32) void {
        const terrain_scale_up: f32 = 1.0 / @as(f32, @floatFromInt(@abs(gen_params.terrain_max)));
        const terrain_scale_down: f32 = 1.0 / @as(f32, @floatFromInt(@abs(gen_params.terrain_min)));
        const terrain_scales: [2]f32 = .{ terrain_scale_up, terrain_scale_down };
        const scale = gen_params.terrain_scale * chunk_scale;
        const one_d_terrain_scale: f32 = 1.0 / scale;
        var block_height_vec: [ChunkSize]i64 = undefined;
        const chunk_block_pos = chunk_pos.position * @as(@Vector(3, i64), @splat(ChunkSize));
        for (0..ChunkSize) |i| block_height_vec[i] = chunk_block_pos[1] + @as(i64, @intCast(i));
        for (heights, 0..) |row, x| {
            for (0..ChunkSize) |c| {
                for (row, 0..) |terrain_height, z| {
                    chunk_blocks[x][c][z] = getSurfaceBlock(block_height_vec[c], terrain_height, terrain_scales, gen_params.sea_level, rand, gen_params.terrain_block_randomness, one_d_terrain_scale, scale);
                }
            }
        }
    }

    fn generateCavesInterpolate(chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_pos: ChunkPos, chunk_scale: f32, gen_params: Params) void {
        const caves = tracy.Zone.begin(.{ .src = @src() });
        defer caves.end();
        var grid: [4][4][4]f32 = undefined;
        const float_pos: @Vector(3, f32) = @Vector(3, f32){ @floatFromInt(chunk_pos.position[0]), @floatFromInt(chunk_pos.position[1]), @floatFromInt(chunk_pos.position[2]) };
        const one_third_vec: @Vector(3, f32) = comptime @splat(1.0 / 3.0);
        const one_d_terrain_scale_vec: @Vector(3, f32) = @splat(1.0 / (gen_params.terrain_scale * chunk_scale));
        const cave_noise_zone = tracy.Zone.begin(.{ .src = @src(), .name = "caveNoise" });
        for (0..4) |x| {
            for (0..4) |y| {
                for (0..4) |z| {
                    const xyz = @Vector(3, f32){ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
                    const sample_offset = xyz * one_third_vec;
                    const pos = (float_pos + sample_offset) * one_d_terrain_scale_vec;
                    grid[x][y][z] = gen_params.cave_noise.genNoise3D(pos[0], pos[1], pos[2]);
                }
            }
        }
        cave_noise_zone.end();

        const inter = tracy.Zone.begin(.{ .src = @src() });
        defer inter.end();
        const init_interp = tracy.Zone.begin(.{ .src = @src(), .name = "init_interp" });
        var interpolator = Interpolation.NaturalCubicInterpolator3D.init(grid);
        init_interp.end();
        const one_d_32: f32 = comptime 1.0 / @as(comptime_float, ChunkSize);
        comptime var zs: @Vector(ChunkSize, f32) = undefined;
        comptime for (0..ChunkSize) |i| {
            zs[i] = @as(f32, @floatFromInt(i)) * one_d_32;
        };
        const xs: @Vector(ChunkSize, f32) = comptime zs;
        const ys: @Vector(ChunkSize, f32) = comptime zs;

        @setEvalBranchQuota(32000);
        inline for (0..ChunkSize) |x| {
            for (0..ChunkSize) |y| {
                const real_y = ((float_pos[1] * ChunkSize) + @as(f32, @floatFromInt(y))) * one_d_terrain_scale_vec[0];
                const m: f32 = 1 - (1 / -@min(-1, (real_y / gen_params.cave_expansion_max) - 1));
                const cave_threshold: f32 = gen_params.cave_threshold + (m * 2);
                inline for (0..ChunkSize) |z| {
                    if (interpolator.sampleComptimeXZ(xs[x], ys[y], zs[z]) < cave_threshold) {
                        chunk_blocks[x][y][z] = .air;
                    }
                }
            }
        }
    }

    fn getSurfaceBlock(block_height: i64, terrain_height: i64, terrain_height_scales: [2]f32, sea_level: i32, rand: *std.Random, block_randomness: f32, one_d_terrain_scale: f32, terrain_scale: f32) Block {
        if (block_height < terrain_height - @as(i64, @ceil(5.0 * terrain_scale))) {
            return Block.stone;
        } else if (block_height < terrain_height) {
            return Block.dirt;
        } else if (block_height == terrain_height) {
            return randGround(rand, @as(f32, @floatFromInt(terrain_height)) * terrain_height_scales[@intFromBool(terrain_height <= sea_level)], block_height, sea_level, block_randomness, one_d_terrain_scale);
        } else if (block_height > terrain_height and block_height <= sea_level) {
            return Block.water;
        } else {
            return Block.air;
        }
    }

    fn randGround(rand: *const std.Random, height_percent: f32, block_height: i64, sea_level: i64, block_randomness: f32, one_d_terrain_scale: f32) Block {
        const a = std.math.lerp(height_percent * one_d_terrain_scale, rand.float(f32), block_randomness);
        return if (block_height < sea_level) Block.dirt else if (a < 0.25) Block.grass else if (a < 0.4) Block.dirt else if (a < 0.6) Block.stone else Block.snow;
    }

    pub fn getTerrainHeight(self: *DefaultGenerator, io: std.Io, allocator: std.mem.Allocator, chunk_pos: [2]i32, level: i32) ![ChunkSize][ChunkSize]i32 {
        _ = allocator;
        const gth = tracy.Zone.begin(.{ .src = @src() });
        defer gth.end();
        if (self.terrain_height_cache.get(io, .{ .x = chunk_pos[0], .z = chunk_pos[1], .level = level })) |cached_height| return cached_height.value;
        const generated_heights = genTerrainHeight(self.params, level, chunk_pos);
        _ = self.terrain_height_cache.upsert(io, &.{ .key = .{ .x = chunk_pos[0], .z = chunk_pos[1], .level = level }, .value = generated_heights });
        return generated_heights;
    }

    fn genTerrainHeight(params: Params, level: i32, chunk_pos: [2]i32) [ChunkSize][ChunkSize]i32 {
        const gth = tracy.Zone.begin(.{ .src = @src() });
        defer gth.end();
        const chunk_size_gen_scale = 32.0 / World.ChunkPos.levelToBlockRatioFloat(level);
        const scale = params.terrain_scale * chunk_size_gen_scale;
        const float_pos = @Vector(2, f32){ @floatFromInt(chunk_pos[0]), @floatFromInt(chunk_pos[1]) };
        const d32: f32 = comptime 1.0 / @as(comptime_float, ChunkSize);
        var height: [ChunkSize][ChunkSize]i32 = undefined;
        const float_min: f32 = @floatFromInt(params.terrain_min);
        const float_max: f32 = @floatFromInt(params.terrain_max);
        const float_bounds = [2]f32{ float_min, float_max };
        const one_d_terrain_scale: f32 = 1.0 / scale;
        for (0..ChunkSize) |ux| {
            const x: f32 = ((@as(f32, @floatFromInt(ux)) * d32) + float_pos[0]) * one_d_terrain_scale;
            for (0..ChunkSize) |uz| {
                const z: f32 = ((@as(f32, @floatFromInt(uz)) * d32) + float_pos[1]) * one_d_terrain_scale;
                var gen_x = x;
                var gen_z = z;
                params.terrain_noise.domainWarp2D(&gen_x, &gen_z);
                var large_gen_x = x;
                var large_gen_z = z;
                params.large_terrain_noise_warp.domainWarp2D(&large_gen_x, &large_gen_z);
                var terrain_noise = std.math.pow(f32, params.terrain_noise.genNoise2D(gen_x, gen_z), 1);
                const large_terrain_noise = params.large_terrain_noise.genNoise2D(large_gen_x, large_gen_z);
                if (terrain_noise < 0.0) terrain_noise = 0.0;
                const P = 2.0;
                const E = large_terrain_noise * (if (terrain_noise < 0.5)
                    (std.math.pow(f32, terrain_noise * 2, P) * 0.5)
                else
                    (1 - (std.math.pow(f32, (1 - terrain_noise) * 2, P) * 0.5)));
                const block_height: i32 = @floor(E * @abs(float_bounds[@intFromBool(E > 0)]) * scale);
                height[ux][uz] = block_height;
            }
        }
        return height;
    }

    fn generateStructures(self: *DefaultGenerator, io: std.Io, allocator: std.mem.Allocator, world: *World, chunk: *Chunk, chunk_pos: ChunkPos) !void {
        const gen_structures_zone = tracy.Zone.begin(.{ .src = @src() });
        defer gen_structures_zone.end();
        if (chunk_pos.level < 0) return;
        var editor_buffer: [100_000]u8 = undefined;
        var bfa: BFA = .init(&editor_buffer, allocator);
        var world_editor = World.Editor{ .world = world, .temp_allocator = bfa.allocator(), .propagate_changes = false };
        defer world_editor.clear();

        {
            try chunk.addAndLockShared(io);
            defer chunk.releaseAndUnlockShared(io);

            if (chunk.structures_generated.load(.seq_cst)) return;
            if (!self.params.gen_structures) return;
            const heights = try self.getTerrainHeight(io, allocator, [2]i32{ chunk_pos.position[0], chunk_pos.position[2] }, chunk_pos.level);
            const scale: f32 = self.params.terrain_scale * (1.0 / ChunkPos.toScale(chunk_pos.level));

            for (heights, 0..) |row, x| {
                for (row, 0..) |height, z| {
                    if (@divFloor(height, ChunkSize) != chunk_pos.position[1] or height < self.params.sea_level) continue;
                    const y: usize = @intCast(@mod(height, ChunkSize));
                    const block = switch (chunk.encoding) {
                        .grid => chunk.encoding.grid[x][y][z],
                        .uniform => chunk.encoding.uniform,
                    };
                    if (!block.plantsCanGrow()) continue;

                    const lvl_x: f32 = @as(f32, @floatFromInt((chunk_pos.position[0] * ChunkSize) + @as(i32, @intCast(@mod(x, ChunkSize)))));
                    const lvl_z: f32 = @as(f32, @floatFromInt((chunk_pos.position[2] * ChunkSize) + @as(i32, @intCast(@mod(z, ChunkSize)))));

                    for (self.params.trees) |tree_conf| {
                        if (!tree_conf.enabled) continue;
                        const is_tree = tree_conf.placer.getStructure(.{ @intFromFloat(lvl_x), @intFromFloat(lvl_z) }, @intCast(chunk_pos.level));
                        if (is_tree) |seed| {
                            const center_pos = ((chunk_pos.position * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize })) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) };
                            const tree_seed = self.params.seed.? ^ @as(u64, @bitCast(seed));
                            var random = std.Random.DefaultPrng.init(@bitCast(tree_seed));
                            const rand = random.random();
                            const factor = ((rand.float(f32) + 0.5) * tree_conf.size_variation);
                            if (-chunk_pos.level + std.math.log2_int(u32, @trunc(tree_conf.tree.trunk_height)) < 2) {
                                try placeLowResTree(&world_editor, center_pos, scale * factor, tree_conf.tree.trunk_height, chunk_pos.level);
                            } else {
                                try placeTree(&world_editor, center_pos, scale * factor, tree_conf, tree_seed, chunk_pos.level);
                            }
                        }
                    }
                }
            }
        }
        try world_editor.flush(io, allocator);
    }

    fn placeTree(editor: *World.Editor, pos: World.BlockPos, scale: f32, config: TreeConfig, seed: u64, level: i32) !void {
        var random = std.Random.DefaultPrng.init(seed);
        const rand = random.random();
        var place_tree: World.Editor.Tree = .{
            .pos = @intCast(pos),
            .scale = scale,
            .config = config.tree,
            .rand = rand,
        };
        _ = try place_tree.place(seed, editor, level);
    }

    fn placeLowResTree(editor: *World.Editor, pos: World.BlockPos, scale: f32, height: f32, level: i32) !void {
        const diameter: f32 = height * scale;
        if (diameter < 0.25) return;
        if (diameter < 1.0) {
            try editor.placeBlock(.leaves, pos + @Vector(3, i64){ 0, 1, 0 }, level);
            return;
        }
        const sphere = World.Editor.Geometry.Sphere(f32).init(@floatFromInt(pos + @Vector(3, i64){ 0, @ceil(diameter / 2.0), 0 }), diameter);
        _ = try editor.placeSamplerShape(.leaves, sphere, level);
    }
};
