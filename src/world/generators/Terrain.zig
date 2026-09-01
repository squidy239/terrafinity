const std = @import("std");
const builtin = @import("builtin");

const tracy = @import("tracy");

const Cache = @import("../../libs/Cache.zig").Cache;
const Block = @import("../Block.zig").Block;
const Bfa = @import("../BufferFirstAllocator.zig");
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const erosion = @import("../../libs/erosion.zig");
const generator_api = @import("generator_api.zig");
const interpolation = @import("../Interpolation.zig");
const JitteredGrid = @import("../structures/JitteredGrid.zig").JitteredGrid;
const Sphere = @import("../structures/Sphere.zig").Sphere;
const Tree = @import("../structures/Tree.zig").Tree;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;

pub const DefaultGenerator = struct {
    pub const Noise = @import("fastnoise");
    const thc_fragments = if (builtin.is_test) 1 else 8;
    const sample_count = ChunkSize * ChunkSize;
    const FloatV = @Vector(ChunkSize, f32);

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
        self.generateStructures(io, allocator, world, chunk, chunk_pos) catch |err| return mapStructureError(err);
    }

    pub fn deinit(self: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World) void {
        _ = world;
        _ = io;
        const generator: *DefaultGenerator = @ptrCast(@alignCast(self.data));
        generator.terrain_height_cache.deinit(allocator);
    }

    pub const Params = struct {
        /// If null, a random seed will be generated. Will be set after setSeeds is called.
        seed: ?u64 = null,
        terrain_scale: f32 = 1,
        terrain_block_randomness: f32 = 0.25,
        slope_randomness: f32 = 0.15,
        ground_threshold: f32 = 0.3,
        dirt_band: f32 = 0.2,
        /// Deprecated: replaced by the erosion filter; kept so saved configs still parse.
        /// Skipped in the config tree, so it needs a declaration default for
        /// the parser to fill it back in on load.
        erosion_strength: f32 = 0.2,
        /// Applies the Phacelle erosion filter to the shaped height field.
        erosion_enabled: bool = true,
        /// Horizontal scale of the erosion pattern relative to the terrain.
        erosion_scale: f32 = 0.15,
        /// Total magnitude of the erosion filter across all octaves.
        erosion_filter_strength: f32 = 0.22,
        /// Gully magnitude relative to the peak-sharpening effect of the mask.
        erosion_gully_weight: f32 = 0.5,
        /// Exponent restricting fine gullies to slopes the coarse octaves carved.
        erosion_detail: f32 = 1.5,
        /// Number of gully octaves; coarse LODs drop the finest ones.
        erosion_octaves: u32 = 4,
        /// Frequency step between gully octaves.
        erosion_lacunarity: f32 = 2.0,
        /// Amplitude step between gully octaves.
        erosion_gain: f32 = 0.5,
        /// Phacelle cell size relative to the stripe width.
        erosion_cell_scale: f32 = 0.7,
        /// Ridge crispness; 1.0 can create loop artefacts where ridges meet.
        erosion_normalization: f32 = 0.5,
        /// Fade-in width of the erosion mask on ridge crests.
        erosion_ridge_rounding: f32 = 0.1,
        /// Fade-in width of the erosion mask in creases; 0 cuts in instantly.
        erosion_crease_rounding: f32 = 0.0,
        /// Slope magnitude substituted for the terrain gradient.
        erosion_assumed_slope: f32 = 0.7,
        /// How much of the gradient magnitude `erosion_assumed_slope` replaces.
        erosion_assumed_slope_amount: f32 = 1.0,
        terrain_min: i32 = -4096,
        terrain_max: i32 = 8196,
        sea_level: i32 = 0,
        height_power: f32 = 1,
        /// Power applied to the continental (large) noise before combining.
        large_power: f32 = 1,
        /// Power applied to the mountain (small/ridged) noise before combining.
        small_power: f32 = 1,
        dirt_depth: f32 = 5,
        snow_line: f32 = 0.6,
        beach_band: f32 = 6,
        sand_slope: f32 = 0.3,
        /// Weight of the mountain (ridged) noise added on top of the continental noise.
        terrain_noise_balance: f32 = 1,
        terrain_noise: Noise.Noise(f32) = .{
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
        large_terrain_noise: Noise.Noise(f32) = .{
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
        large_terrain_noise_warp: Noise.Noise(f32) = .{
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
        cave_noise: Noise.Noise(f32) = .{
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
        cave_threshold: f32 = -10000.0,
        cave_expansion_max: f32 = 8192,
        cave_expansion_start: f32 = 0,
        gen_structures: bool = true,
        trees: []const TreeConfig = &.{
            .{
                .placer = .{ .box_size = 2048, .inner_box_size = 1800 },
                .enabled = true,
                .size_variation = 0.5,
                .tree = .huge,
            },
            .{
                .placer = .{ .box_size = 32, .inner_box_size = 25 },
                .enabled = true,
                .size_variation = 0.5,
                .tree = .small,
            },
        },

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

        /// Default parameter set; every field carries its default value in the
        /// declaration, so configs missing fields parse back with the defaults.
        pub const default = Params{};
    };

    pub const TreeConfig = struct {
        placer: JitteredGrid(2, i32) = .{},
        enabled: bool = true,
        size_variation: f32 = 0.5,
        /// Hidden from the config tree (unreflectable); stays at the defaults.
        tree: Tree.Config = .small,
    };

    const GenContext = struct { params: *const Params, rand: *std.Random, chunk_scale: f32 };

    const GroundContext = struct { block_height: i64, sea_level: i64, block_randomness: f32, one_d_terrain_scale: f32, slope: f32, slope_randomness: f32, ground_threshold: f32, dirt_band: f32, snow_line: f32, beach_band_blocks: f32, sand_slope: f32 };

    pub fn genChunk(self: *DefaultGenerator, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, blocks: *Chunk.Encoding, world: *World, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) !void {
        @setFloatMode(.optimized);
        const chunk_scale_factor = 1.0 / ChunkPos.toScale(chunk_pos.level);
        const gen = tracy.Zone.begin(.{ .src = @src() });
        defer gen.end();
        _ = world;
        _ = allocator;
        // The height field is shaped * |bounds| * scale, so terrain_scale stretches the
        // vertical min/max envelope; cull against the scaled world height, not the raw params.
        const max_global_y: i64 = @round(@as(f32, @floatFromInt(self.params.terrain_max)) * self.params.terrain_scale);
        const min_global_y: i64 = @round(@as(f32, @floatFromInt(self.params.terrain_min)) * self.params.terrain_scale);
        if (chunk_pos.position[1] > ChunkPos.fromGlobalBlockPos(.{ 0, max_global_y, 0 }, chunk_pos.level).position[1]) {
            blocks.merge(.{ .uniform = .air }, grid_buffer);
            return;
        }
        var block_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.null)));
        const is_below_min = chunk_pos.position[1] < ChunkPos.fromGlobalBlockPos(.{ 0, min_global_y, 0 }, chunk_pos.level).position[1];
        if (!is_below_min) {
            var rng = std.Random.DefaultPrng.init(self.params.seed.? +% @as(u64, @truncate(@as(u96, @bitCast(chunk_pos.position)))));
            var rand = rng.random();
            const heights = try self.getTerrainHeight(io, [2]i32{ chunk_pos.position[0], chunk_pos.position[2] }, chunk_pos.level);
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
        generateCavesInterpolate(&block_grid, chunk_pos, chunk_scale_factor, &self.params);
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
        const BoolV = @Vector(ChunkSize, bool);
        const TagV = @Vector(ChunkSize, Block.Tag);
        const zero_v: FloatV = @splat(0);
        const one_v: FloatV = @splat(1);
        // Preserves the old integer test floor(th) - bh > ceil(dirt_depth * scale), translated to f32.
        const depth_threshold: f32 = @floor(ctx.params.dirt_depth * scale) + 1.0;

        const block_height_vec: [ChunkSize]i32 = std.simd.iota(i32, ChunkSize) + @as(IntV, @splat(chunk_pos.position[1] * ChunkSize));
        // The differential is the slope (block-space gradient magnitude) and is LOD-invariant,
        // so it feeds randGround directly with no divisor or normalization.
        const differential = getDifferential(&heights);
        for (heights, chunk_blocks, 0..) |heights_row, *col, x| {
            const th: FloatV = heights_row;
            const th_arr: [ChunkSize]f32 = th;
            for (block_height_vec, col) |bh, *row| {
                const diff: FloatV = th - @as(FloatV, @splat(@as(f32, @floatFromInt(bh))));
                const below_depth: BoolV = diff >= @as(FloatV, @splat(depth_threshold));
                const below_or: BoolV = diff >= zero_v;
                if (@reduce(.And, below_depth)) {
                    row.* = @splat(Block.stone);
                    continue;
                }
                if (!@reduce(.Or, below_or)) {
                    row.* = @splat(if (bh <= sea_level) Block.water else Block.air);
                    continue;
                }

                var tags: TagV = @splat(@intFromEnum(Block.air));
                const land_tag: TagV = @splat(@intFromEnum(if (bh <= sea_level) Block.sand else Block.dirt));
                tags = @select(Block.Tag, below_or, @select(Block.Tag, below_depth, @as(TagV, @splat(@intFromEnum(Block.stone))), land_tag), tags);
                if (bh <= sea_level) {
                    tags = @select(Block.Tag, !below_or, @as(TagV, @splat(@intFromEnum(Block.water))), tags);
                }
                row.* = @bitCast(tags);

                var surface_bits: u32 = @as(u32, @bitCast(below_or)) & @as(u32, @bitCast(diff < one_v));
                while (surface_bits != 0) {
                    const z: usize = @ctz(surface_bits);
                    surface_bits &= surface_bits - 1;
                    row[z] = randGround(ctx.rand, th_arr[z] * terrain_scales[@intFromBool(th_arr[z] <= sea_level_f)], .{
                        .block_height = bh,
                        .sea_level = sea_level,
                        .block_randomness = ctx.params.terrain_block_randomness,
                        .one_d_terrain_scale = one_d_terrain_scale,
                        .slope = differential[x][z],
                        .slope_randomness = ctx.params.slope_randomness,
                        .ground_threshold = ctx.params.ground_threshold,
                        .dirt_band = ctx.params.dirt_band,
                        .snow_line = ctx.params.snow_line,
                        .beach_band_blocks = ctx.params.beach_band * scale,
                        .sand_slope = ctx.params.sand_slope,
                    });
                }
            }
        }
    }

    fn caveThresholdAt(real_y: f32, cave_threshold: f32, cave_expansion_max: f32) f32 {
        // Caves grow larger below the expansion start, capped above it.
        return cave_threshold + (1.0 - 1.0 / @max(1.0, 1.0 - real_y / cave_expansion_max)) * 2.0;
    }

    fn generateCavesInterpolate(chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_pos: ChunkPos, chunk_scale: f32, gen_params: *const Params) void {
        const caves = tracy.Zone.begin(.{ .src = @src() });
        defer caves.end();
        const cave_grid_size: usize = 4;
        const CaveInterp = interpolation.MultilinearInterpolator(f32, 3, .{ cave_grid_size, cave_grid_size, cave_grid_size }, .{ ChunkSize, ChunkSize, ChunkSize });
        const float_pos: @Vector(3, f32) = .{ @floatFromInt(chunk_pos.position[0]), @floatFromInt(chunk_pos.position[1]), @floatFromInt(chunk_pos.position[2]) };
        const one_d_terrain_scale_vec: @Vector(3, f32) = @splat(1.0 / (gen_params.terrain_scale * chunk_scale));
        const cave_noise_zone = tracy.Zone.begin(.{ .src = @src(), .name = "caveNoise" });
        var grid_flat: [cave_grid_size * cave_grid_size * cave_grid_size]f32 = undefined;
        const grid_origin = float_pos * one_d_terrain_scale_vec;
        gen_params.cave_noise.fillGrid3D(&grid_flat, cave_grid_size, cave_grid_size, grid_origin[0], grid_origin[1], grid_origin[2], (1.0 / @as(f32, cave_grid_size - 1)) * one_d_terrain_scale_vec[0]);
        const grid: [cave_grid_size][cave_grid_size][cave_grid_size]f32 = @bitCast(grid_flat);
        cave_noise_zone.end();

        const interpolator = CaveInterp.init(grid);
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
        if (ctx.block_height < ctx.sea_level) return Block.sand;

        // Jitter the slope so ground, dirt, and stone boundaries break up instead
        // of tracing smooth contours.
        const a = ctx.slope + (rand.float(f32) * 2.0 - 1.0) * ctx.slope_randomness;

        // Sand beaches on the gentle shoreline use their own slope threshold,
        // so they can be narrower or wider than the grass band.
        if (@as(f32, @floatFromInt(ctx.block_height - ctx.sea_level)) <= ctx.beach_band_blocks and a < ctx.sand_slope) return Block.sand;

        if (a < ctx.ground_threshold) {
            // Soft ground: grass or snow by altitude.
            const cover = std.math.lerp(height_percent * ctx.one_d_terrain_scale, rand.float(f32), ctx.block_randomness);
            return if (cover < ctx.snow_line) Block.grass else Block.snow;
        }
        // Dirt occupies a band of width `dirt_band` above the ground threshold;
        // steeper ground is stone.
        return if (a - ctx.dirt_band < ctx.ground_threshold) Block.dirt else Block.stone;
    }

    pub fn getTerrainHeight(self: *DefaultGenerator, io: std.Io, chunk_pos: [2]i32, level: i32) ![ChunkSize][ChunkSize]f32 {
        const gth = tracy.Zone.begin(.{ .src = @src() });
        defer gth.end();
        if (self.terrain_height_cache.get(io, .{ .x = chunk_pos[0], .z = chunk_pos[1], .level = level })) |cached_height| return cached_height.value;
        const generated_heights = genTerrainHeight(&self.params, level, chunk_pos);
        _ = self.terrain_height_cache.upsert(io, &.{ .key = .{ .x = chunk_pos[0], .z = chunk_pos[1], .level = level }, .value = generated_heights });
        return generated_heights;
    }

    fn genTerrainHeight(params: *const Params, level: i32, chunk_pos: [2]i32) [ChunkSize][ChunkSize]f32 {
        const gth = tracy.Zone.begin(.{ .src = @src() });
        defer gth.end();
        const scale = params.terrain_scale / World.ChunkPos.toScale(level);
        const float_pos: @Vector(2, f32) = .{ @floatFromInt(chunk_pos[0]), @floatFromInt(chunk_pos[1]) };
        const d32: f32 = comptime 1.0 / @as(comptime_float, ChunkSize);
        var height: [ChunkSize][ChunkSize]f32 = undefined;
        const float_bounds: [2]f32 = .{ @floatFromInt(params.terrain_min), @floatFromInt(params.terrain_max) };
        const one_d_terrain_scale: f32 = 1.0 / scale;
        const erosion_on = params.erosion_enabled;

        // Domain warp is inherently per-point, so warp the base coordinate grid
        // into two irregular coordinate sets, then sample both in one batched pass.
        const base_coords_zone = tracy.Zone.begin(.{ .src = @src(), .name = "baseCoords" });
        var base_x: [sample_count]f32 = undefined;
        var base_z: [sample_count]f32 = undefined;
        const z_iota: FloatV = std.simd.iota(f32, ChunkSize);
        const row_z_arr: [ChunkSize]f32 = z_iota * @as(FloatV, @splat(d32 * one_d_terrain_scale)) + @as(FloatV, @splat(float_pos[1] * one_d_terrain_scale));
        for (0..ChunkSize) |x| {
            const row_x_arr: [ChunkSize]f32 = @splat(((@as(f32, @floatFromInt(x)) * d32) + float_pos[0]) * one_d_terrain_scale);
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
        // The filter consumes the pre-envelope shaped value; the envelope is
        // applied after, so both share the same world-space scale.
        var shaped_center: [ChunkSize][ChunkSize]f32 = undefined;
        for (0..ChunkSize) |x| {
            const raw: FloatV = @as(FloatV, terrain_noise_raw[x * ChunkSize ..][0..ChunkSize].*);
            const large = @as(FloatV, large_terrain_noise[x * ChunkSize ..][0..ChunkSize].*);
            shaped_center[x] = shapedRow(params, large, raw);
        }
        if (!erosion_on) {
            const zero_v: FloatV = @splat(0);
            for (0..ChunkSize) |x| {
                const shaped: FloatV = shaped_center[x];
                const bounds = @select(f32, shaped > zero_v, @as(FloatV, @splat(float_bounds[1])), @as(FloatV, @splat(float_bounds[0])));
                height[x] = shaped * @abs(bounds) * @as(FloatV, @splat(scale));
            }
        }
        heights_zone.end();

        if (erosion_on) {
            const erosion_zone = tracy.Zone.begin(.{ .src = @src(), .name = "erosionFilter" });
            // The terrain gradient comes from central differences of the shaped
            // field sampled at +/- one sample spacing. Every point is evaluated
            // from world coordinates alone, so chunk borders cannot distort the
            // last row or column as the old neighbor-differencing stage did.
            const grad_zone = tracy.Zone.begin(.{ .src = @src(), .name = "erosionGradient" });
            var scratch: GradientScratch = undefined;
            var grad_x: [sample_count]f32 = @splat(0);
            var grad_z: [sample_count]f32 = @splat(0);
            const e = d32 * one_d_terrain_scale;
            const one_d_2e = 1.0 / (2.0 * e);
            addGradientSamples(params, &scratch, &base_x, &base_z, &grad_x, .{ e, 0 }, 1.0, one_d_2e);
            addGradientSamples(params, &scratch, &base_x, &base_z, &grad_x, .{ -e, 0 }, -1.0, one_d_2e);
            addGradientSamples(params, &scratch, &base_x, &base_z, &grad_z, .{ 0, e }, 1.0, one_d_2e);
            addGradientSamples(params, &scratch, &base_x, &base_z, &grad_z, .{ 0, -e }, -1.0, one_d_2e);
            grad_zone.end();

            // Coarser LODs drop the finest octaves, whose wavelength falls
            // below their sample spacing; the remaining octaves stay absolute
            // in world space so the gullies match across levels.
            const lod_octave_drop: u32 = @intCast(@max(level, 0));
            const erosion_p_scale = @max(params.erosion_scale, 0.001);
            const erosion_params = erosion.ErosionParams{
                .filter_strength = params.erosion_filter_strength,
                .gully_weight = params.erosion_gully_weight,
                .detail = params.erosion_detail,
                .octaves = @max(1, params.erosion_octaves -| lod_octave_drop),
                .lacunarity = params.erosion_lacunarity,
                .gain = params.erosion_gain,
                .cell_scale = params.erosion_cell_scale,
                .normalization = params.erosion_normalization,
                .ridge_rounding = params.erosion_ridge_rounding,
                .crease_rounding = params.erosion_crease_rounding,
                .assumed_slope = params.erosion_assumed_slope,
                .assumed_slope_amount = params.erosion_assumed_slope_amount,
            };
            for (0..ChunkSize) |x| {
                for (0..ChunkSize) |z| {
                    const i = x * ChunkSize + z;
                    const shaped = shaped_center[x][z];
                    // The filter expects the slope pointing downhill, so the
                    // gradient is negated. Heights stay in normalized units
                    // through the filter and get the base envelope on the way
                    // out, so the gully size tracks terrain_scale automatically.
                    // Larger erosion_scale means larger gullies; zero is guarded
                    // against since the filter divides coordinates by it.
                    const result = erosion.erosionFilter(
                        // "Tiles" p: the erosion detail sits at 0.15x the terrain
                        // features, so the scale divides the coordinates; the
                        // slope scales by the inverse factor to stay a
                        // derivative of the transformed coordinates.
                        .{ base_x[i] / erosion_p_scale, base_z[i] / erosion_p_scale },
                        .{ shaped, -grad_x[i] * erosion_p_scale, -grad_z[i] * erosion_p_scale },
                        0.0,
                        erosion_params,
                    );
                    const bounds = if (shaped > 0) float_bounds[1] else float_bounds[0];
                    height[x][z] = (shaped + result.height_delta) * @abs(bounds) * scale;
                }
            }
            erosion_zone.end();
        }
        return height;
    }

    /// Signed power curve: sign-preserving |v|^power, steepening (>1) or flattening (<1).
    inline fn signedPow(v: @Vector(ChunkSize, f32), power: @Vector(ChunkSize, f32)) @Vector(ChunkSize, f32) {
        const magnitude = @exp2(power * @log2(@abs(v)));
        return @select(f32, v < @as(@Vector(ChunkSize, f32), @splat(0)), -magnitude, magnitude);
    }

    fn getDifferential(height: *const [ChunkSize][ChunkSize]f32) [ChunkSize][ChunkSize]f32 {
        var differential: [ChunkSize][ChunkSize]f32 = undefined;
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |z| {
                const nz = height[x][if (z + 1 < ChunkSize) z + 1 else z - 1];
                const nx = height[if (x + 1 < ChunkSize) x + 1 else x - 1][z];
                const gz = height[x][z] - nz;
                const gx = height[x][z] - nx;
                differential[x][z] = @sqrt(gx * gx + gz * gz);
            }
        }
        return differential;
    }

    /// Shaped height row: signed-power continents and mountains combined and
    /// normalized, then contrast-scaled. Shared by the base grid and the
    /// gradient sample passes.
    inline fn shapedRow(params: *const Params, large: FloatV, raw: FloatV) FloatV {
        const height_power_v: FloatV = @splat(params.height_power);
        const large_power_v: FloatV = @splat(params.large_power);
        const small_power_v: FloatV = @splat(params.small_power);
        const balance_v: FloatV = @splat(params.terrain_noise_balance);
        const sum_norm: FloatV = @splat(1.0 / (1.0 + params.terrain_noise_balance));
        // Signed power per noise: steepens (>1) or flattens (<1) each field
        // before combining, so continents and mountains are shaped independently.
        const large_shaped = signedPow(large, large_power_v);
        const raw_shaped = signedPow(raw, small_power_v);
        // Additive: large = continents, raw = mountains (peaks and valleys).
        // Normalize by 1 + balance so the sum stays in [-1,1] without hard-clamping
        // peaks into flat plateaus at the world height cap.
        const warped = (large_shaped + raw_shaped * balance_v) * sum_norm;
        // Vertical contrast: a signed power curve sharpens peaks and flattens
        // lowlands while staying inside the min/max envelope.
        return signedPow(warped, height_power_v);
    }

    const GradientScratch = struct {
        off_x: [sample_count]f32,
        off_z: [sample_count]f32,
        warp_x: [sample_count]f32,
        warp_z: [sample_count]f32,
        large_warp_x: [sample_count]f32,
        large_warp_z: [sample_count]f32,
        noise: [sample_count]f32,
        large_noise: [sample_count]f32,
    };

    /// Samples the shaped field at `base + offset` and folds the difference
    /// into `grad` with the given sign, scaled by the inverse sample distance.
    fn addGradientSamples(params: *const Params, scratch: *GradientScratch, base_x: []const f32, base_z: []const f32, grad: []f32, offset: [2]f32, sign: f32, one_d_2e: f32) void {
        const offset_x_v: FloatV = @splat(offset[0]);
        const offset_z_v: FloatV = @splat(offset[1]);
        for (0..ChunkSize) |x| {
            const ox: FloatV = @as(FloatV, base_x[x * ChunkSize ..][0..ChunkSize].*) + offset_x_v;
            const oz: FloatV = @as(FloatV, base_z[x * ChunkSize ..][0..ChunkSize].*) + offset_z_v;
            scratch.off_x[x * ChunkSize ..][0..ChunkSize].* = ox;
            scratch.off_z[x * ChunkSize ..][0..ChunkSize].* = oz;
        }
        params.terrain_noise.fillWarp2DGrid(&scratch.warp_x, &scratch.warp_z, &scratch.off_x, &scratch.off_z);
        params.large_terrain_noise_warp.fillWarp2DGrid(&scratch.large_warp_x, &scratch.large_warp_z, &scratch.off_x, &scratch.off_z);
        params.terrain_noise.fillNoise2DGrid(&scratch.noise, &scratch.warp_x, &scratch.warp_z);
        params.large_terrain_noise.fillNoise2DGrid(&scratch.large_noise, &scratch.large_warp_x, &scratch.large_warp_z);
        for (0..ChunkSize) |x| {
            const raw: FloatV = @as(FloatV, scratch.noise[x * ChunkSize ..][0..ChunkSize].*);
            const large = @as(FloatV, scratch.large_noise[x * ChunkSize ..][0..ChunkSize].*);
            const grad_row: FloatV = @as(FloatV, grad[x * ChunkSize ..][0..ChunkSize].*);
            // Fused multiply-add keeps the accumulation bit-identical across
            // build modes: an unfused mul+add contracts into fma only in
            // optimized builds, and on low-slope terrain those ulps become
            // entirely different gradient directions.
            const delta = @mulAdd(FloatV, shapedRow(params, large, raw), @as(FloatV, @splat(sign * one_d_2e)), grad_row);
            grad[x * ChunkSize ..][0..ChunkSize].* = delta;
        }
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
            const heights = try self.getTerrainHeight(io, [2]i32{ chunk_pos.position[0], chunk_pos.position[2] }, chunk_pos.level);
            const scale: f32 = self.params.terrain_scale / ChunkPos.toScale(chunk_pos.level);
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

fn mapStructureError(err: anyerror) error{ OutOfMemory, Canceled, Unrecoverable } {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.Unrecoverable,
    };
}

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
    .seed = .{ .is_seed = true, .advanced = true },
    .noise_type = .{ .advanced = true },
    .rotation_type = .{ .advanced = true },
    .fractal_type = .{ .advanced = true },
    .cellular_distance = .{ .advanced = true },
    .cellular_return = .{ .advanced = true },
    .domain_warp_type = .{ .advanced = true },
    .frequency = .{ .min = 0, .max = 0.5, .advanced = true },
    .octaves = .{ .min = 1, .max = 16, .advanced = true },
    .lacunarity = .{ .min = 1, .max = 4, .advanced = true },
    .gain = .{ .min = 0, .max = 1, .advanced = true },
    .weighted_strength = .{ .min = 0, .max = 1, .advanced = true },
    .ping_pong_strength = .{ .min = 0, .max = 8, .advanced = true },
    .cellular_jitter_mod = .{ .min = 0, .max = 1, .advanced = true },
    .domain_warp_amp = .{ .min = 0, .max = 2000, .advanced = true },
    .terrain_scale = .{ .label = "Terrain Scale", .description = "Scales the generated terrain height range.", .min = 0.1, .max = 4 },
    .terrain_min = .{ .label = "Minimum Height", .min = -100000, .max = 0 },
    .terrain_max = .{ .label = "Maximum Height", .min = 0, .max = 100000 },
    .sea_level = .{ .label = "Sea Level", .min = -1000, .max = 1000 },
    .terrain_block_randomness = .{ .label = "Block Randomness", .min = 0, .max = 1 },
    .slope_randomness = .{ .label = "Slope Randomness", .min = 0, .max = 1 },
    .ground_threshold = .{ .min = 0, .max = 1 },
    .dirt_band = .{ .min = 0, .max = 1 },
    .erosion_strength = .{ .skip = true },
    .erosion_enabled = .{ .label = "Erosion Enabled", .description = "Applies the Phacelle erosion filter to the terrain." },
    .erosion_scale = .{ .label = "Erosion Scale", .description = "Horizontal scale of the erosion pattern relative to the terrain.", .min = 0.0, .max = 5.0 },
    .erosion_filter_strength = .{ .label = "Erosion Filter Strength", .description = "Total magnitude across all erosion octaves.", .min = 0, .max = 1 },
    .erosion_gully_weight = .{ .label = "Erosion Gully Weight", .description = "Gully magnitude relative to the peak-sharpening effect.", .min = 0, .max = 1 },
    .erosion_detail = .{ .label = "Erosion Detail", .description = "Lower values restrict fine gullies to the steepest slopes.", .min = 0.1, .max = 4 },
    .erosion_octaves = .{ .label = "Erosion Octaves", .min = 1, .max = 8 },
    .erosion_lacunarity = .{ .label = "Erosion Lacunarity", .min = 1, .max = 4 },
    .erosion_gain = .{ .label = "Erosion Gain", .min = 0, .max = 1 },
    .erosion_cell_scale = .{ .label = "Erosion Cell Scale", .description = "Phacelle cell size relative to the stripe width; prone to abrupt changes far from the origin.", .min = 0.0, .max = 1, .advanced = true },
    .erosion_normalization = .{ .label = "Erosion Normalization", .description = "Ridge crispness; 1.0 can create loop artefacts where ridges meet.", .min = 0, .max = 1, .advanced = true },
    .erosion_ridge_rounding = .{ .label = "Erosion Ridge Rounding", .min = 0, .max = 1, .advanced = true },
    .erosion_crease_rounding = .{ .label = "Erosion Crease Rounding", .min = 0, .max = 1, .advanced = true },
    .erosion_assumed_slope = .{ .label = "Erosion Assumed Slope", .description = "Slope magnitude substituted for the terrain gradient.", .min = 0, .max = 2, .advanced = true },
    .erosion_assumed_slope_amount = .{ .label = "Erosion Assumed Slope Amount", .description = "How much of the gradient magnitude the assumed slope replaces.", .min = 0, .max = 1, .advanced = true },
    .terrain_noise_balance = .{ .label = "Terrain Noise Balance", .min = 0, .max = 1 },
    .height_power = .{ .label = "Height Power", .min = 0.25, .max = 4 },
    .large_power = .{ .label = "Large Shape Power", .min = 0.25, .max = 8 },
    .small_power = .{ .label = "Detail Power", .min = 0.25, .max = 8 },
    .cave_threshold = .{ .label = "Cave Threshold", .min = -100, .max = 100, .advanced = true },
    .cave_expansion_max = .{ .label = "Cave Expansion Maximum", .min = 0, .max = 20000, .advanced = true },
    .cave_expansion_start = .{ .label = "Cave Expansion Start", .min = 0, .max = 20000, .advanced = true },
    .gen_structures = .{ .label = "Generate Structures" },
    .dirt_depth = .{ .min = 1, .max = 32 },
    .snow_line = .{ .min = 0, .max = 1 },
    .beach_band = .{ .min = 0, .max = 32 },
    .sand_slope = .{ .min = 0, .max = 1 },
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

const continental_preset = blk: {
    var p = DefaultGenerator.Params.default;
    // Continental: broad flat landmasses from low-frequency ping-pong noise, no structures.
    p.terrain_block_randomness = 0.0;
    p.slope_randomness = 0.0;
    p.ground_threshold = 0.5;
    p.dirt_band = 0.7;
    p.terrain_min = -512;
    p.terrain_max = 2048;
    p.large_power = 1.5;
    p.small_power = 1.5;
    p.dirt_depth = 2.0;
    p.terrain_noise_balance = 0.3;
    p.terrain_noise.frequency = 0.008;
    p.terrain_noise.fractal_type = .ping_pong;
    p.terrain_noise.domain_warp_type = .basic_grid;
    p.terrain_noise.domain_warp_amp = 0.0;
    p.large_terrain_noise.fractal_type = .ping_pong;
    p.large_terrain_noise.octaves = 4;
    p.large_terrain_noise_warp.noise_type = .perlin;
    p.large_terrain_noise_warp.rotation_type = .improve_xy_planes;
    p.large_terrain_noise_warp.fractal_type = .none;
    p.large_terrain_noise_warp.octaves = 0;
    p.large_terrain_noise_warp.domain_warp_amp = 100.0;
    p.cave_noise.domain_warp_amp = 827.6712;
    p.gen_structures = false;
    break :blk p;
};

const terrain_presets = [_]DefaultGenerator.Params{
    continental_preset,
    blk: {
        var p = DefaultGenerator.Params.default;
        // Sculpted: heavy erosion and ping-pong large-scale noise round the
        // terrain into flowing hills.
        p.large_terrain_noise.fractal_type = .ping_pong;
        p.large_terrain_noise.octaves = 5;
        p.large_terrain_noise_warp.fractal_type = .none;
        p.cave_noise.domain_warp_amp = 827.6712;
        break :blk p;
    },
    blk: {
        var p = continental_preset;
        // Eroded: Continental landmasses carved by the new erosion filter;
        // heavy gully weight and a finer cell scale emphasize branching gullies.
        p.erosion_enabled = true;
        p.erosion_filter_strength = 0.38;
        p.erosion_gully_weight = 0.75;
        p.erosion_detail = 2.0;
        p.erosion_octaves = 5;
        p.erosion_cell_scale = 0.55;
        break :blk p;
    },
    .default,
};
const terrain_preset_names = [_][]const u8{ "Continental", "Sculpted", "Plain", "Eroded" };
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
    self.generator.generateStructures(io, allocator, world, chunk, chunk_pos) catch |err| return mapStructureError(err);
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

    var start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |i| {
        height = DefaultGenerator.genTerrainHeight(&params, @as(i32, @intCast(@mod(i, 3))) - 1, .{ 3, 5 });
        sink += height[0][0];
    }
    var end = std.Io.Clock.Timestamp.now(io, .awake);
    const eroded_ns = @as(f64, @floatFromInt(start.durationTo(end).raw.toNanoseconds())) / @as(f64, @floatFromInt(iterations));
    std.debug.print("genTerrainHeight {s} erosion: {d:.1} ns/call (sink {d})\n", .{ @tagName(@import("builtin").mode), eroded_ns, sink });

    var plain_params = params;
    plain_params.erosion_enabled = false;
    sink = 0;
    start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |i| {
        height = DefaultGenerator.genTerrainHeight(&plain_params, @as(i32, @intCast(@mod(i, 3))) - 1, .{ 3, 5 });
        sink += height[0][0];
    }
    end = std.Io.Clock.Timestamp.now(io, .awake);
    const plain_ns = @as(f64, @floatFromInt(start.durationTo(end).raw.toNanoseconds())) / @as(f64, @floatFromInt(iterations));
    std.debug.print("genTerrainHeight {s} base: {d:.1} ns/call (sink {d})\n", .{ @tagName(@import("builtin").mode), plain_ns, sink });
}

test "legacy config with erosion_strength parses" {
    @setEvalBranchQuota(100000000);
    // Old saved configs set erosion_strength, which is skipped in the config
    // tree but must still parse; the new erosion_* fields fall back to their
    // declaration defaults so no world config migration is needed.
    const legacy = ".{ .seed = null, .terrain_scale = 2, .erosion_strength = 1.5, .terrain_block_randomness = 0.1 }";
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..legacy.len], legacy);
    buf[legacy.len] = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const params = try std.zon.parse.fromSliceAlloc(DefaultGenerator.Params, arena.allocator(), buf[0..legacy.len :0], null, .{});
    try std.testing.expectEqual(@as(f32, 1.5), params.erosion_strength);
    try std.testing.expectEqual(@as(f32, 2), params.terrain_scale);
    try std.testing.expect(params.erosion_enabled);
    try std.testing.expectEqual(@as(u32, 4), params.erosion_octaves);
}

test "config tree round trips through zon" {
    @setEvalBranchQuota(100000000);
    // The emitted tree omits skipped fields (erosion_strength); the parser
    // must fill them back in from the declaration defaults, or every saved
    // config would fail to load and be replaced by the preset.
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tree = try generator_api.fromStruct(DefaultGenerator.Params, allocator, &DefaultGenerator.Params.default, field_specs);
    defer generator_api.free(allocator, tree);

    var buf: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try generator_api.emitZon(&w, tree);
    const emitted = w.buffered();

    var source: [16384]u8 = undefined;
    @memcpy(source[0..emitted.len], emitted);
    source[emitted.len] = 0;
    const params = try std.zon.parse.fromSliceAlloc(DefaultGenerator.Params, arena.allocator(), source[0..emitted.len :0], null, .{});
    try std.testing.expectEqual(DefaultGenerator.Params.default.erosion_strength, params.erosion_strength);
    try std.testing.expectEqual(DefaultGenerator.Params.default.erosion_octaves, params.erosion_octaves);
    try std.testing.expectEqual(DefaultGenerator.Params.default.erosion_enabled, params.erosion_enabled);
    try std.testing.expectEqual(DefaultGenerator.Params.default.terrain_scale, params.terrain_scale);
}

test "erosion seam continuity between adjacent chunks" {
    // The erosion filter evaluates every point from world coordinates alone,
    // so the height field stays continuous across chunk borders. This pins
    // the fix for the removed getDifferential stage, which reflected the last
    // row/column and distorted the final row of every chunk.
    const params = DefaultGenerator.Params.default;
    const west = DefaultGenerator.genTerrainHeight(&params, 0, .{ 0, 0 });
    const east = DefaultGenerator.genTerrainHeight(&params, 0, .{ 1, 0 });
    for (0..ChunkSize) |z| {
        const jump = @abs(west[ChunkSize - 1][z] - east[0][z]);
        // Neighboring samples on the same side of the border bound the local
        // slope, but the gully ripple can double it at a steep phase, so the
        // jump may reach a few times the local step. A coordinate-space bug
        // jumps by thousands of blocks instead.
        const step_w = @abs(west[ChunkSize - 1][z] - west[ChunkSize - 2][z]);
        const step_e = @abs(east[1][z] - east[0][z]);
        try std.testing.expect(jump <= (step_w + step_e) * 2.5 + 256.0);
    }
}

test "erosion LOD consistency between level 0 and level 1" {
    // The filter drops its finest octave per LOD level (its wavelength falls
    // below the coarser sample spacing), so a level-1 chunk must match the
    // box-filtered level-0 field up to the dropped octave's amplitude.
    const params = DefaultGenerator.Params.default;
    const coarse = DefaultGenerator.genTerrainHeight(&params, 1, .{ 1, 1 });
    var fine: [4][ChunkSize][ChunkSize]f32 = undefined;
    fine[0] = DefaultGenerator.genTerrainHeight(&params, 0, .{ 2, 2 });
    fine[1] = DefaultGenerator.genTerrainHeight(&params, 0, .{ 3, 2 });
    fine[2] = DefaultGenerator.genTerrainHeight(&params, 0, .{ 2, 3 });
    fine[3] = DefaultGenerator.genTerrainHeight(&params, 0, .{ 3, 3 });
    const max_abs_bound: f32 = @floatFromInt(@max(@abs(params.terrain_min), @abs(params.terrain_max)));
    // The dropped octave plus the coarser gradient sampling shift the gullies
    // slightly; allow about 40% of the filter's total magnitude on top of a
    // fixed slack, far below what a coordinate or unit bug would produce.
    const filter_amp: f32 = params.erosion_filter_strength / (1.0 - params.erosion_gain) * params.erosion_gully_weight;
    const limit = max_abs_bound * filter_amp * 0.4 + 128.0;
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |z| {
            // A level-1 sample at (x, z) coincides exactly with the level-0
            // samples (2x, 2z) and (2x+1, 2z) inside the chunk at (x / h), so
            // the covering four fine samples are box-filtered and compared
            // against the coarse height at half the fine envelope. h is the
            // number of coarse samples per fine-chunk edge; the factor 2 is the
            // level scale.
            const h = ChunkSize / 2;
            const cx: usize = @intCast(x / h);
            const fx: usize = @intCast(2 * (x % h));
            const cz: usize = @intCast(z / h);
            const fz: usize = @intCast(2 * (z % h));
            const avg = (fine[cx + 2 * cz][fx][fz] + fine[cx + 2 * cz][fx + 1][fz] + fine[cx + 2 * cz][fx][fz + 1] + fine[cx + 2 * cz][fx + 1][fz + 1]) * 0.25;
            const diff = @abs(coarse[x][z] - avg * 0.5);
            try std.testing.expect(diff <= limit);
        }
    }
}
