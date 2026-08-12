const std = @import("std");
const builtin = @import("builtin");

const tracy = @import("tracy");

const Cache = @import("../../libs/Cache.zig").Cache;
const Block = @import("../Block.zig").Block;
const Bfa = @import("../BufferFirstAllocator.zig");
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const generator_api = @import("generator_api.zig");
const interpolation = @import("../Interpolation.zig");
const JitteredGrid = @import("../structures/JitteredGrid.zig").JitteredGrid;
const Sphere = @import("../structures/Sphere.zig").Sphere;
const Tree = @import("../structures/Tree.zig").Tree;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;

pub const DefaultGenerator = struct {
    pub const Noise = @import("fastnoise.zig");
    const thc_fragments = if (builtin.is_test) 1 else 8;

    params: Params,
    terrain_height_cache: Cache(ChunkHeightsKey, ChunkHeightsValue, ChunkHeightsValue.keyFromValue, ChunkHeightsKey.hash, .{}, thc_fragments),

    const ChunkHeightsValue = struct {
        value: [ChunkSize][ChunkSize]f32,
        key: ChunkHeightsKey,

        pub inline fn keyFromValue(value: *const ChunkHeightsValue) ChunkHeightsKey {
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
        slope_randomness: f32,
        ground_threshold: f32,
        dirt_band: f32,
        erosion_strength: f32,
        terrain_noise: Noise.Noise(f32),
        terrain_noise_balance: f32,
        ridge_sharpness: f32,
        large_terrain_noise: Noise.Noise(f32),
        large_terrain_noise_warp: Noise.Noise(f32),
        cave_noise: Noise.Noise(f32),
        terrain_min: i32,
        terrain_max: i32,
        sea_level: i32,
        height_power: f32,
        dirt_depth: f32,
        snow_line: f32,
        cave_threshold: f32,
        cave_expansion_max: f32,
        cave_expansion_start: f32,
        /// If null, a random seed will be generated. Will be set after setSeeds is called.
        seed: ?u64,
        terrain_scale: f32,
        gen_structures: bool,
        trees: []const TreeConfig,

        pub fn setSeeds(self: *Params, io: std.Io) void {
            const seed = self.seed orelse blk: {
                var random_seed: u64 = undefined;
                io.random(std.mem.asBytes(&random_seed));
                self.seed = random_seed;
                break :blk random_seed;
            };
            // Salts differentiate the noise streams; the large warp shares salt 4 with the large height noise.
            const noise_salts = .{ 1, 3, 4, 4 };
            inline for (.{ &self.cave_noise, &self.terrain_noise, &self.large_terrain_noise, &self.large_terrain_noise_warp }, noise_salts) |noise, salt| {
                noise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(seed +% salt));
            }
        }

        pub const default = Params{
            .terrain_block_randomness = 0.25,
            .slope_randomness = 0.15,
            .ground_threshold = 0.3,
            .dirt_band = 0.2,
            .erosion_strength = 0.2,
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
            .terrain_noise_balance = 1,
            .ridge_sharpness = 2,
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
            .height_power = 1,
            .dirt_depth = 5,
            .snow_line = 0.6,
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
        placer: JitteredGrid(2, i32) = .{},
        enabled: bool = true,
        size_variation: f32 = 0.5,
        /// Hidden from the config tree (unreflectable); stays at the defaults.
        tree: Tree.Config = .small,
    };

    const GenContext = struct { params: *const Params, rand: *std.Random, chunk_scale: f32 };

    const GroundContext = struct { block_height: i64, sea_level: i64, block_randomness: f32, one_d_terrain_scale: f32, slope: f32, slope_randomness: f32, ground_threshold: f32, dirt_band: f32, snow_line: f32 };

    pub fn genChunk(self: *DefaultGenerator, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, blocks: *Chunk.Encoding, world: *World, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) !void {
        @setFloatMode(.optimized);
        const chunk_scale_factor = 1.0 / ChunkPos.toScale(chunk_pos.level);
        const gen = tracy.Zone.begin(.{ .src = @src() });
        defer gen.end();
        _ = world;
        if (chunk_pos.position[1] > ChunkPos.fromGlobalBlockPos(.{ 0, self.params.terrain_max, 0 }, chunk_pos.level).position[1]) {
            blocks.merge(.{ .uniform = .air }, grid_buffer);
            return;
        }
        var block_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = comptime @splat(@splat(@splat(.null)));
        const is_below_min = chunk_pos.position[1] < ChunkPos.fromGlobalBlockPos(.{ 0, self.params.terrain_min, 0 }, chunk_pos.level).position[1];
        if (!is_below_min) {
            var rng = std.Random.DefaultPrng.init(self.params.seed.? +% @as(u64, @truncate(@as(u96, @bitCast(chunk_pos.position)))));
            var rand = rng.random();
            const heights = try self.getTerrainHeight(io, allocator, [2]i32{ chunk_pos.position[0], chunk_pos.position[2] }, chunk_pos.level);
            const gen_terrain_zone = tracy.Zone.begin(.{ .src = @src(), .name = "GenTerrainBlocks" });
            generateTerrain(&block_grid, chunk_pos, heights, .{ .params = &self.params, .rand = &rand, .chunk_scale = chunk_scale_factor });
            gen_terrain_zone.end();
            const one_block = Chunk.getUniform(&block_grid);
            if (one_block == Block.air) {
                blocks.merge(.{ .uniform = .air }, grid_buffer);
                return;
            }
        }
        if (is_below_min) blocks.merge(.{ .uniform = .stone }, grid_buffer);
        generateCavesInterpolate(&block_grid, chunk_pos, chunk_scale_factor, self.params);
        const one_block = Chunk.getUniform(&block_grid);
        if (one_block) |block| {
            blocks.merge(.{ .uniform = block }, grid_buffer);
        } else blocks.merge(.{ .grid = &block_grid }, grid_buffer);
    }

    fn generateTerrain(chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_pos: ChunkPos, heights: [ChunkSize][ChunkSize]f32, ctx: GenContext) void {
        const terrain_scales: [2]f32 = .{ 1.0 / @as(f32, @floatFromInt(@abs(ctx.params.terrain_max))), 1.0 / @as(f32, @floatFromInt(@abs(ctx.params.terrain_min))) };
        const scale = ctx.params.terrain_scale * ctx.chunk_scale;
        const one_d_terrain_scale: f32 = 1.0 / scale;
        const sea_level: i32 = ctx.params.sea_level;
        const sea_level_f: f32 = @floatFromInt(sea_level);
        const IntV = @Vector(ChunkSize, i32);
        const FloatV = @Vector(ChunkSize, f32);
        const BoolV = @Vector(ChunkSize, bool);
        const TagV = @Vector(ChunkSize, Block.Tag);
        const zero_v: FloatV = @splat(0);
        const one_v: FloatV = @splat(1);
        // Preserves the old integer test floor(th) - bh > ceil(dirt_depth * scale), translated to f32.
        const depth_threshold: f32 = @ceil(ctx.params.dirt_depth * scale) + 1.0;

        const block_height_vec: [ChunkSize]i32 = std.simd.iota(i32, ChunkSize) + @as(IntV, @splat(chunk_pos.position[1] * ChunkSize));
        // Get the full column-to-column height differential once, like the erosion pass,
        // then index it when placing blocks. Normalizing by the rock depth ties "full bias"
        // to cliff-scale drops.
        const differential = getDifferential(heights);
        var slope_grid: [ChunkSize][ChunkSize]f32 = undefined;
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |z| {
                slope_grid[x][z] = std.math.pow(f32, @min(differential[x][z] / depth_threshold, 1.0), 2.0);
            }
        }
        for (heights, chunk_blocks, 0..) |heights_row, *col, x| {
            const th: FloatV = heights_row;
            const th_arr: [ChunkSize]f32 = th;
            for (block_height_vec, col) |bh, *row| {
                const diff: FloatV = th - @as(FloatV, @splat(@as(f32, @floatFromInt(bh))));
                const below_depth: BoolV = diff >= @as(FloatV, @splat(depth_threshold));
                const below_or: BoolV = diff >= zero_v;
                const below_depth_bits: u32 = @bitCast(below_depth);
                const below_or_bits: u32 = @bitCast(below_or);
                if (below_depth_bits == @as(u32, @bitCast(@as(BoolV, @splat(true))))) {
                    row.* = @splat(Block.stone);
                    continue;
                }
                if (below_or_bits == 0) {
                    row.* = @splat(if (bh <= sea_level) Block.water else Block.air);
                    continue;
                }

                var tags: TagV = @splat(@intFromEnum(Block.air));
                tags = @select(Block.Tag, below_or, @select(Block.Tag, below_depth, @as(TagV, @splat(@intFromEnum(Block.stone))), @as(TagV, @splat(@intFromEnum(Block.dirt)))), tags);
                if (bh <= sea_level) {
                    tags = @select(Block.Tag, @as(BoolV, @bitCast(~below_or_bits)), @as(TagV, @splat(@intFromEnum(Block.water))), tags);
                }
                row.* = @bitCast(tags);

                var surface_bits: u32 = @as(u32, @bitCast(below_or)) & @as(u32, @bitCast(diff < one_v));
                const surface_zone = tracy.Zone.begin(.{ .src = @src(), .name = "surfaceBlocks" });
                defer surface_zone.end();
                while (surface_bits != 0) {
                    const z: usize = @ctz(surface_bits);
                    surface_bits &= surface_bits - 1;
                    row[z] = randGround(ctx.rand, th_arr[z] * terrain_scales[@intFromBool(th_arr[z] <= sea_level_f)], .{
                        .block_height = bh,
                        .sea_level = sea_level,
                        .block_randomness = ctx.params.terrain_block_randomness,
                        .one_d_terrain_scale = one_d_terrain_scale,
                        .slope = slope_grid[x][z],
                        .slope_randomness = ctx.params.slope_randomness,
                        .ground_threshold = ctx.params.ground_threshold,
                        .dirt_band = ctx.params.dirt_band,
                        .snow_line = ctx.params.snow_line,
                    });
                }
            }
        }
    }

    fn caveThresholdAt(real_y: f32, cave_threshold: f32, cave_expansion_max: f32) f32 {
        // Caves grow larger below the expansion start, capped above it.
        return cave_threshold + (1.0 - 1.0 / @max(1.0, 1.0 - real_y / cave_expansion_max)) * 2.0;
    }

    fn generateCavesInterpolate(chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_pos: ChunkPos, chunk_scale: f32, gen_params: Params) void {
        const caves = tracy.Zone.begin(.{ .src = @src() });
        defer caves.end();
        const cave_grid_size: usize = 4;
        const CaveInterp = interpolation.TrilinearInterpolator3D(f32, cave_grid_size, cave_grid_size, cave_grid_size, ChunkSize, ChunkSize, ChunkSize);
        const float_pos: @Vector(3, f32) = .{ @floatFromInt(chunk_pos.position[0]), @floatFromInt(chunk_pos.position[1]), @floatFromInt(chunk_pos.position[2]) };
        const one_d_terrain_scale_vec: @Vector(3, f32) = @splat(1.0 / (gen_params.terrain_scale * chunk_scale));
        const cave_noise_zone = tracy.Zone.begin(.{ .src = @src(), .name = "caveNoise" });
        var grid_flat: [cave_grid_size * cave_grid_size * cave_grid_size]f32 = undefined;
        const grid_origin = float_pos * one_d_terrain_scale_vec;
        gen_params.cave_noise.fillGrid3D(&grid_flat, cave_grid_size, cave_grid_size, grid_origin[0], grid_origin[1], grid_origin[2], (1.0 / @as(f32, cave_grid_size - 1)) * one_d_terrain_scale_vec[0]);
        const grid: [cave_grid_size][cave_grid_size][cave_grid_size]f32 = @bitCast(grid_flat);
        cave_noise_zone.end();

        const inter = tracy.Zone.begin(.{ .src = @src() });
        defer inter.end();
        const init_interp = tracy.Zone.begin(.{ .src = @src(), .name = "init_interp" });
        const interpolator = CaveInterp.init(grid);
        init_interp.end();
        const cave_values = interpolator.sampleGrid();

        const apply_zone = tracy.Zone.begin(.{ .src = @src(), .name = "caveApply" });
        defer apply_zone.end();
        for (0..ChunkSize) |y| {
            const real_y = ((float_pos[1] * ChunkSize) + @as(f32, @floatFromInt(y))) * one_d_terrain_scale_vec[0];
            const cave_threshold: f32 = caveThresholdAt(real_y, gen_params.cave_threshold, gen_params.cave_expansion_max);
            for (0..ChunkSize) |z| {
                const is_cave = cave_values[y][z] < @as(@Vector(ChunkSize, f32), @splat(cave_threshold));
                if (std.simd.firstTrue(is_cave)) |_| {
                    inline for (0..ChunkSize) |x| {
                        if (is_cave[x]) chunk_blocks[x][y][z] = .air;
                    }
                }
            }
        }
    }

    fn randGround(rand: *const std.Random, height_percent: f32, ctx: GroundContext) Block {
        if (ctx.block_height < ctx.sea_level) return Block.dirt;

        // Jitter the slope so ground, dirt, and stone boundaries break up instead
        // of tracing smooth contours.
        const a = ctx.slope + (rand.float(f32) * 2.0 - 1.0) * ctx.slope_randomness;

        if (a < ctx.ground_threshold) {
            // Soft ground: grass or snow by altitude.
            const cover = std.math.lerp(height_percent * ctx.one_d_terrain_scale, rand.float(f32), ctx.block_randomness);
            return if (cover < ctx.snow_line) Block.grass else Block.snow;
        }
        // Dirt occupies a band of width `dirt_band` above the ground threshold;
        // steeper ground is stone.
        return if (a - ctx.dirt_band < ctx.ground_threshold) Block.dirt else Block.stone;
    }

    pub fn getTerrainHeight(self: *DefaultGenerator, io: std.Io, allocator: std.mem.Allocator, chunk_pos: [2]i32, level: i32) ![ChunkSize][ChunkSize]f32 {
        _ = allocator;
        const gth = tracy.Zone.begin(.{ .src = @src() });
        defer gth.end();
        if (self.terrain_height_cache.get(io, .{ .x = chunk_pos[0], .z = chunk_pos[1], .level = level })) |cached_height| return cached_height.value;
        const generated_heights = genTerrainHeight(self.params, level, chunk_pos);
        _ = self.terrain_height_cache.upsert(io, &.{ .key = .{ .x = chunk_pos[0], .z = chunk_pos[1], .level = level }, .value = generated_heights });
        return generated_heights;
    }

    fn genTerrainHeight(params: Params, level: i32, chunk_pos: [2]i32) [ChunkSize][ChunkSize]f32 {
        const gth = tracy.Zone.begin(.{ .src = @src() });
        defer gth.end();
        const scale = params.terrain_scale * (@as(f32, @floatFromInt(ChunkSize)) / World.ChunkPos.levelToBlockRatioFloat(level));
        const float_pos: @Vector(2, f32) = .{ @floatFromInt(chunk_pos[0]), @floatFromInt(chunk_pos[1]) };
        const d32: f32 = comptime 1.0 / @as(comptime_float, ChunkSize);
        var height: [ChunkSize][ChunkSize]f32 = undefined;
        const float_bounds: [2]f32 = .{ @floatFromInt(params.terrain_min), @floatFromInt(params.terrain_max) };
        const one_d_terrain_scale: f32 = 1.0 / scale;
        const sample_count = ChunkSize * ChunkSize;
        const FloatV = @Vector(ChunkSize, f32);

        // Domain warp is inherently per-point, so warp the base coordinate grid
        // into two irregular coordinate sets, then sample both in one batched pass.
        const base_coords_zone = tracy.Zone.begin(.{ .src = @src(), .name = "baseCoords" });
        var base_x: [sample_count]f32 = undefined;
        var base_z: [sample_count]f32 = undefined;
        const z_iota: FloatV = std.simd.iota(f32, ChunkSize);
        for (0..ChunkSize) |x| {
            const row_x_arr: [ChunkSize]f32 = @splat(((@as(f32, @floatFromInt(x)) * d32) + float_pos[0]) * one_d_terrain_scale);
            const row_z_arr: [ChunkSize]f32 = z_iota * @as(FloatV, @splat(d32 * one_d_terrain_scale)) + @as(FloatV, @splat(float_pos[1] * one_d_terrain_scale));
            @memcpy(base_x[x * ChunkSize ..][0..ChunkSize], &row_x_arr);
            @memcpy(base_z[x * ChunkSize ..][0..ChunkSize], &row_z_arr);
        }
        base_coords_zone.end();

        const warp_zone = tracy.Zone.begin(.{ .src = @src(), .name = "terrainWarp" });
        var terrain_warped_x: [sample_count]f32 = undefined;
        var terrain_warped_z: [sample_count]f32 = undefined;
        var large_warped_x: [sample_count]f32 = undefined;
        var large_warped_z: [sample_count]f32 = undefined;
        params.terrain_noise.fillWarp2DGrid(&terrain_warped_x, &terrain_warped_z, &base_x, &base_z);
        params.large_terrain_noise_warp.fillWarp2DGrid(&large_warped_x, &large_warped_z, &base_x, &base_z);
        warp_zone.end();

        const noise_zone = tracy.Zone.begin(.{ .src = @src(), .name = "terrainNoise" });
        var terrain_noise_raw: [sample_count]f32 = undefined;
        var large_terrain_noise: [sample_count]f32 = undefined;
        params.terrain_noise.fillNoise2DGrid(&terrain_noise_raw, &terrain_warped_x, &terrain_warped_z);
        params.large_terrain_noise.fillNoise2DGrid(&large_terrain_noise, &large_warped_x, &large_warped_z);
        noise_zone.end();

        const heights_zone = tracy.Zone.begin(.{ .src = @src(), .name = "blockHeights" });
        const zero_v: FloatV = @splat(0);
        const one_v: FloatV = @splat(1);
        const two_v: FloatV = @splat(2);
        const half_v: FloatV = @splat(0.5);
        const sharpness_v: FloatV = @splat(params.ridge_sharpness);
        const height_power_v: FloatV = @splat(params.height_power);
        const balance_v: FloatV = @splat(params.terrain_noise_balance);
        for (0..ChunkSize) |x| {
            const raw: FloatV = @as(FloatV, terrain_noise_raw[x * ChunkSize ..][0..ChunkSize].*);
            const inv = one_v - raw;
            // Detail shaping: raw valleys dip toward zero, peaks rise; sharpness
            // steeps the curve, balance mixes it against the pure large shape.
            const pow_a = half_v * @exp2(sharpness_v * @log2(@abs(raw * two_v)));
            const pow_b = one_v - half_v * @exp2(sharpness_v * @log2(inv * two_v));
            const shaping = @select(f32, raw < half_v, pow_a, pow_b);
            const large = @as(FloatV, large_terrain_noise[x * ChunkSize ..][0..ChunkSize].*);
            const mixed = one_v + (shaping - one_v) * balance_v;
            const warped = large * mixed;
            // Vertical contrast: a signed power curve sharpens peaks and flattens
            // lowlands while staying inside the min/max envelope.
            const magnitude = @exp2(height_power_v * @log2(@abs(warped)));
            const shaped = @select(f32, warped < zero_v, -magnitude, magnitude);
            const bounds = @select(f32, shaped > zero_v, @as(FloatV, @splat(float_bounds[1])), @as(FloatV, @splat(float_bounds[0])));
            const height_row: @Vector(ChunkSize, f32) = shaped * @abs(bounds) * @as(FloatV, @splat(scale));
            height[x] = height_row;
        }
        heights_zone.end();

        const erosion_zone = tracy.Zone.begin(.{ .src = @src(), .name = "erosion" });
        // Erosion: columns steeper than their neighbor shed height, rounding peaks and ridges.
        const differential = getDifferential(height);
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |z| {
                height[x][z] -= differential[x][z] * params.erosion_strength;
            }
        }
        erosion_zone.end();
        return height;
    }

    fn getDifferential(height: [ChunkSize][ChunkSize]f32) [ChunkSize][ChunkSize]f32 {
        var differential: [ChunkSize][ChunkSize]f32 = undefined;
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |z| {
                const nz = height[x][if (z + 1 < ChunkSize) z + 1 else z - 1];
                const nx = height[if (x + 1 < ChunkSize) x + 1 else x - 1][z];
                differential[x][z] = @max(@abs(height[x][z] - nz), @abs(height[x][z] - nx));
            }
        }
        return differential;
    }

    fn generateStructures(self: *DefaultGenerator, io: std.Io, allocator: std.mem.Allocator, world: *World, chunk: *Chunk, chunk_pos: ChunkPos) !void {
        const gen_structures_zone = tracy.Zone.begin(.{ .src = @src() });
        defer gen_structures_zone.end();
        if (chunk_pos.level < 0) return;
        const editor_buffer_size: usize = 100_000;
        var editor_buffer: [editor_buffer_size]u8 = undefined;
        var bfa: Bfa = .init(&editor_buffer, allocator);
        var world_editor = World.Editor{ .world = world, .temp_allocator = bfa.allocator(), .propagate_changes = false };
        defer world_editor.clear();

        {
            try chunk.addAndLockShared(io);
            defer chunk.releaseAndUnlockShared(io);

            if (chunk.structures_generated.load(.seq_cst)) return;
            if (!self.params.gen_structures) return;
            const heights = try self.getTerrainHeight(io, allocator, [2]i32{ chunk_pos.position[0], chunk_pos.position[2] }, chunk_pos.level);
            const scale: f32 = self.params.terrain_scale * (1.0 / ChunkPos.toScale(chunk_pos.level));
            const min_full_tree_lod: i32 = 2;

            for (heights, 0..) |row, x| {
                for (row, 0..) |height, z| {
                    const height_i: i32 = @floor(height);
                    if (@divFloor(height_i, ChunkSize) != chunk_pos.position[1] or height_i < self.params.sea_level) continue;
                    const y: usize = @intCast(@mod(height_i, ChunkSize));
                    const block = switch (chunk.encoding) {
                        .grid => chunk.encoding.grid[x][y][z],
                        .uniform => chunk.encoding.uniform,
                    };
                    if (!block.plantsCanGrow()) continue;

                    const lvl_x: f32 = @floatFromInt((chunk_pos.position[0] * ChunkSize) + @as(i32, @intCast(x)));
                    const lvl_z: f32 = @floatFromInt((chunk_pos.position[2] * ChunkSize) + @as(i32, @intCast(z)));

                    for (self.params.trees) |tree_conf| {
                        if (!tree_conf.enabled) continue;
                        const structure_seed = tree_conf.placer.getStructure(.{ @trunc(lvl_x), @trunc(lvl_z) }, @intCast(chunk_pos.level)) orelse continue;
                        const center_pos = ((chunk_pos.position * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize })) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) };
                        const tree_seed = self.params.seed.? ^ @as(u64, @bitCast(structure_seed));
                        var random = std.Random.DefaultPrng.init(@bitCast(tree_seed));
                        const rand = random.random();
                        const factor = (rand.float(f32) + 0.5) * tree_conf.size_variation;
                        const lod = -chunk_pos.level + std.math.log2_int(u32, @trunc(tree_conf.tree.trunk_height));
                        if (lod < min_full_tree_lod) {
                            try placeLowResTree(&world_editor, center_pos, scale * factor, tree_conf.tree.trunk_height, chunk_pos.level);
                            continue;
                        }
                        _ = try (World.Editor.Tree{ .pos = @intCast(center_pos), .scale = scale * factor, .config = tree_conf.tree, .rand = rand }).place(tree_seed, &world_editor, chunk_pos.level);
                    }
                }
            }
        }
        try world_editor.flush(io, allocator);
    }

    fn placeLowResTree(editor: *World.Editor, pos: World.BlockPos, scale: f32, height: f32, level: i32) !void {
        const min_visible_diameter: f32 = 0.25;
        const single_block_diameter: f32 = 1.0;
        const diameter: f32 = height * scale;
        if (diameter < min_visible_diameter) return;
        if (diameter < single_block_diameter) {
            try editor.placeBlock(.leaves, pos + @Vector(3, i64){ 0, 1, 0 }, level);
            return;
        }
        const sphere = Sphere(f32).init(@floatFromInt(pos + @Vector(3, i64){ 0, @ceil(diameter / 2.0), 0 }), diameter);
        _ = try editor.placeSamplerShape(.leaves, sphere, level);
    }
};

pub const generator_api_vtable: generator_api.GeneratorApi = .{
    .info = &generatorInfo,
    .create = &generatorCreate,
    .get_source = &generatorGetSource,
    .preset_count = &generatorPresetCount,
    .preset_name = &generatorPresetName,
    .preset_default_index = &generatorPresetDefaultIndex,
    .preset_config = &generatorPresetConfig,
    .config_from_zon = &generatorConfigFromZon,
    .config_set_seeds = &generatorConfigSetSeeds,
};

comptime {
    @export(&generator_api_vtable, .{ .name = generator_api.api_export_name });
}

const field_specs = .{
    .seed = .{ .is_seed = true },
    .terrain_block_randomness = .{ .min = 0, .max = 1 },
    .slope_randomness = .{ .min = 0, .max = 1 },
    .ground_threshold = .{ .min = 0, .max = 1 },
    .dirt_band = .{ .min = 0, .max = 1 },
    .erosion_strength = .{ .min = 0, .max = 10 },
    .terrain_min = .{ .min = -100000, .max = 0 },
    .terrain_max = .{ .min = 0, .max = 100000 },
    .sea_level = .{ .min = -1000, .max = 1000 },
    .cave_threshold = .{ .min = -100, .max = 100 },
    .cave_expansion_max = .{ .min = 0, .max = 20000 },
    .cave_expansion_start = .{ .min = 0, .max = 20000 },
    .terrain_scale = .{ .min = 0.1, .max = 4 },
    .terrain_noise_balance = .{ .min = 0, .max = 1 },
    .ridge_sharpness = .{ .min = 1, .max = 8 },
    .height_power = .{ .min = 0.25, .max = 4 },
    .dirt_depth = .{ .min = 1, .max = 32 },
    .snow_line = .{ .min = 0, .max = 1 },
    .frequency = .{ .min = 0, .max = 0.5 },
    .octaves = .{ .min = 1, .max = 16 },
    .lacunarity = .{ .min = 1, .max = 4 },
    .gain = .{ .min = 0, .max = 1 },
    .weighted_strength = .{ .min = 0, .max = 1 },
    .ping_pong_strength = .{ .min = 0, .max = 8 },
    .cellular_jitter_mod = .{ .min = 0, .max = 1 },
    .domain_warp_amp = .{ .min = 0, .max = 2000 },
    .size_variation = .{ .min = 0, .max = 2 },
    .box_size = .{ .min = 16, .max = 4096 },
    .inner_box_size = .{ .min = 16, .max = 4096 },
    .tree = .{ .skip = true },
};

const TerrainInstance = struct {
    generator: DefaultGenerator,
    arena: std.heap.ArenaAllocator,
    source: World.ChunkSource,
};

const generator_info_data: generator_api.GeneratorInfo = .{
    .name = "Terrain",
    .description = "Fractal terrain with caves and trees",
    .version = 1,
    .api_version = generator_api.ApiVersion,
};

pub fn generatorInfo() callconv(.c) *const generator_api.GeneratorInfo {
    return &generator_info_data;
}

const terrain_presets = [_]DefaultGenerator.Params{
    .default,
    blk: {
        var p = DefaultGenerator.Params.default;
        // Sculpted: heavy erosion and ping-pong large-scale noise round the
        // terrain into flowing hills.
        p.erosion_strength = 3.7537832;
        p.large_terrain_noise.fractal_type = .ping_pong;
        p.large_terrain_noise.octaves = 5;
        p.large_terrain_noise_warp.fractal_type = .none;
        p.cave_noise.domain_warp_amp = 827.6712;
        break :blk p;
    },
};
const terrain_preset_names = [_][]const u8{ "Default", "Sculpted" };
const terrain_preset_default: usize = 0;

pub fn generatorPresetCount() callconv(.c) usize {
    return terrain_presets.len;
}

pub fn generatorPresetName(index: usize) callconv(.c) *const []const u8 {
    return &terrain_preset_names[index];
}

pub fn generatorPresetDefaultIndex() callconv(.c) usize {
    return terrain_preset_default;
}

pub fn generatorPresetConfig(allocator: *const std.mem.Allocator, index: usize) callconv(.c) ?*generator_api.ConfigTree {
    if (index >= terrain_presets.len) return null;
    return generator_api.fromStruct(DefaultGenerator.Params, allocator.*, &terrain_presets[index], field_specs) catch null;
}

pub fn generatorConfigFromZon(allocator: *const std.mem.Allocator, bytes: [*]const u8, bytes_len: usize) callconv(.c) ?*generator_api.ConfigTree {
    @setEvalBranchQuota(100000000);
    // The parsed params may hold comptime-backed defaults (e.g. tree presets),
    // so free them as a whole arena instead of walking the struct.
    var arena = std.heap.ArenaAllocator.init(allocator.*);
    defer arena.deinit();
    const params = std.zon.parse.fromSliceAlloc(DefaultGenerator.Params, arena.allocator(), bytes[0..bytes_len :0], null, .{}) catch return null;
    return generator_api.fromStruct(DefaultGenerator.Params, allocator.*, &params, field_specs) catch null;
}

pub fn generatorConfigSetSeeds(io: *const std.Io, config: *generator_api.ConfigTree) callconv(.c) void {
    var random_seed: u64 = undefined;
    io.*.random(std.mem.asBytes(&random_seed));
    for (config.params) |*param| {
        if (param.spec.is_seed and param.value == .u64 and param.value.u64 == 0) {
            param.value.u64 = random_seed;
        }
    }
}

pub fn generatorCreate(opts: *const generator_api.CreateOptions, config: *const generator_api.ConfigTree) callconv(.c) ?*anyopaque {
    var arena = std.heap.ArenaAllocator.init(opts.allocator);
    errdefer arena.deinit();
    var params: DefaultGenerator.Params = .default;
    generator_api.fromTree(DefaultGenerator.Params, arena.allocator(), config, &params, field_specs) catch return null;
    if (params.seed == null) params.setSeeds(opts.io);
    const instance = opts.allocator.create(TerrainInstance) catch return null;
    errdefer opts.allocator.destroy(instance);
    instance.* = .{
        .arena = arena,
        .generator = DefaultGenerator.init(opts.allocator, opts.max_cache_bytes, params) catch return null,
        .source = .{
            .data = instance,
            .getTerrainHeight = null,
            .getBlocks = &instanceGenBlocks,
            .placeStructures = instanceGenStructures,
            .deinit = &instanceDeinit,
            .save = null,
        },
    };
    return instance;
}

pub fn generatorGetSource(instance: *anyopaque) callconv(.c) *const World.ChunkSource {
    const self: *TerrainInstance = @ptrCast(@alignCast(instance));
    return &self.source;
}

fn instanceGenBlocks(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, blocks: *Chunk.Encoding, chunk_pos: ChunkPos, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) error{ Unrecoverable, OutOfMemory, Canceled }!?World.ChunkSource.GetBlocksMetadata {
    const self: *TerrainInstance = @ptrCast(@alignCast(source.data));
    try self.generator.genChunk(io, allocator, chunk_pos, blocks, world, grid_buffer);
    return .{ .from_disk = false, .structures = false };
}

fn instanceGenStructures(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, chunk: *Chunk, chunk_pos: ChunkPos) error{ OutOfMemory, Canceled, Unrecoverable }!void {
    const self: *TerrainInstance = @ptrCast(@alignCast(source.data));
    self.generator.generateStructures(io, allocator, world, chunk, chunk_pos) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.Unrecoverable,
    };
}

fn instanceDeinit(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World) void {
    _ = io;
    _ = world;
    const self: *TerrainInstance = @ptrCast(@alignCast(source.data));
    self.generator.terrain_height_cache.deinit(allocator);
    self.arena.deinit();
    allocator.destroy(self);
}

test "benchmark generateTerrain" {
    const iterations = if (@import("builtin").mode == .Debug) 100 else 2000;
    const io = std.testing.io;
    var seed_rng = std.Random.DefaultPrng.init(0xC0FFEE);
    const seed_rand = seed_rng.random();
    var heights: [ChunkSize][ChunkSize]f32 = undefined;
    for (&heights) |*row| {
        for (row) |*height| {
            height.* = @floatFromInt(seed_rand.intRangeAtMost(i32, -256, 256));
        }
    }
    const flat_stone: [ChunkSize][ChunkSize]f32 = @splat(@splat(200.0));

    benchHeights(io, "random", heights, iterations);
    benchHeights(io, "uniform", flat_stone, iterations);
}

fn benchHeights(io: std.Io, label: []const u8, heights: [ChunkSize][ChunkSize]f32, iterations: usize) void {
    const params = DefaultGenerator.Params.default;
    const chunk_scale: f32 = 1.0;
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.null)));
    var sink: u64 = 0;

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |i| {
        const pos = ChunkPos{ .level = 0, .position = .{ @intCast(@mod(i, 7)), @intCast(@mod(i, 3)), @intCast(@mod(i, 11)) } };
        var rng = std.Random.DefaultPrng.init(i +% 1);
        var rand = rng.random();
        DefaultGenerator.generateTerrain(&grid, pos, heights, .{ .params = &params, .rand = &rand, .chunk_scale = chunk_scale });
        sink += @intFromEnum(grid[@mod(i, ChunkSize)][0][0]);
    }
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    const vec_ns = @as(f64, @floatFromInt(start.durationTo(end).raw.toNanoseconds())) / @as(f64, @floatFromInt(iterations));

    std.debug.print("generateTerrain {s} ({s}): vector {d:.1} ns/call (sink {d})\n", .{ @tagName(@import("builtin").mode), label, vec_ns, sink });
}

test "benchmark genTerrainHeight" {
    const iterations = if (@import("builtin").mode == .Debug) 50 else 500;
    const io = std.testing.io;
    const params = DefaultGenerator.Params.default;
    var sink: f32 = 0;
    var height: [ChunkSize][ChunkSize]f32 = undefined;

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |i| {
        height = DefaultGenerator.genTerrainHeight(params, @as(i32, @intCast(@mod(i, 3))) - 1, .{ 3, 5 });
        sink += height[0][0];
    }
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    const ns = @as(f64, @floatFromInt(start.durationTo(end).raw.toNanoseconds())) / @as(f64, @floatFromInt(iterations));

    std.debug.print("genTerrainHeight {s}: {d:.1} ns/call (sink {d})\n", .{ @tagName(@import("builtin").mode), ns, sink });
}
