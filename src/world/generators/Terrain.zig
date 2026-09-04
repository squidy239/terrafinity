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

    /// Sampling density for noise interpolators, relative to the chunk size:
    /// full is direct sampling (no interpolation), anything coarser evaluates
    /// noise on a border-shared lattice and interpolates up. For ChunkSize 32
    /// these are 32/16/8/4/2 samples per side.
    pub const InterpResolution = enum {
        full,
        half,
        quarter,
        eighth,
        sixteenth,

        pub fn size(self: InterpResolution) usize {
            return @as(usize, ChunkSize) >> @intFromEnum(self);
        }
    };

    /// Asymmetric height envelope plus the symmetric maximum that normalized
    /// deltas (erosion, surface noise) convert with.
    const Envelope = struct {
        bounds: [2]f32,
        max: f32,
        scale: f32,
    };

    /// Shared coordinate frame for the height pipeline, so the per-stage
    /// helpers take one context instead of six scalars.
    const HeightCtx = struct {
        params: *const Params,
        level: i32,
        pos: [2]f32,
        step: f32,
        one_d_scale: f32,
        env: Envelope,

        fn init(params: *const Params, level: i32, chunk_pos: [2]i32) HeightCtx {
            const scale = params.terrain_scale / World.ChunkPos.toScale(level);
            const min: f32 = @floatFromInt(params.terrain_min);
            const max: f32 = @floatFromInt(params.terrain_max);
            return .{
                .params = params,
                .level = level,
                .pos = .{ @floatFromInt(chunk_pos[0]), @floatFromInt(chunk_pos[1]) },
                .step = 1.0 / @as(comptime_float, ChunkSize),
                .one_d_scale = 1.0 / scale,
                .env = .{ .bounds = .{ min, max }, .max = @max(@abs(min), @abs(max)), .scale = scale },
            };
        }
    };

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

    pub fn deinit(self: World.ChunkSource, _: std.Io, allocator: std.mem.Allocator, _: *World) void {
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
        /// Deprecated: replaced by the erosion filter; kept with .skip so saved configs still parse.
        erosion_strength: f32 = 0.2,
        /// Applies the Phacelle erosion filter to the shaped height field.
        erosion_enabled: bool = true,
        /// Horizontal scale of the erosion pattern relative to the terrain.
        erosion_scale: f32 = 3.2929585,
        /// Total magnitude of the erosion filter across all octaves.
        erosion_filter_strength: f32 = 0.11260234,
        /// Gully magnitude relative to the peak-sharpening effect of the mask.
        erosion_gully_weight: f32 = 0.057686467,
        /// Exponent restricting fine gullies to slopes the coarse octaves carved.
        erosion_detail: f32 = 1.0999031,
        /// Number of gully octaves; coarse LODs drop the finest ones.
        erosion_octaves: u32 = 5,
        /// Frequency step between gully octaves.
        erosion_lacunarity: f32 = 2.0,
        /// Amplitude step between gully octaves.
        erosion_gain: f32 = 0.43301594,
        /// Phacelle cell size relative to the stripe width.
        erosion_cell_scale: f32 = 1.0069951,
        /// Ridge crispness; 1.0 can create loop artefacts where ridges meet.
        erosion_normalization: f32 = 0.50142545,
        /// Fade-in width of the erosion mask on ridge crests.
        erosion_ridge_rounding: f32 = 1.0,
        /// Fade-in width of the erosion mask in creases; 0 cuts in instantly.
        erosion_crease_rounding: f32 = 1.0,
        /// Slope magnitude substituted for the terrain gradient.
        erosion_assumed_slope: f32 = 0.0,
        /// How much of the gradient magnitude `erosion_assumed_slope` replaces.
        erosion_assumed_slope_amount: f32 = 0.0,
        /// Slope magnitude at which gullies apply in full; flatter ground fades
        /// out, so peaks and stream beds survive uncarved. Zero disables the fade.
        erosion_fade_slope: f32 = 0.093972616,
        /// Deprecated: kept so saved configs that set it still parse. Skipped in the config tree.
        erosion_fade_altitude: f32 = 0.5,
        /// Sampling density of the erosion height-delta lattice; the filter
        /// runs on the coarse lattice from full-resolution inputs and the
        /// deltas interpolate up. Full disables interpolation.
        erosion_interp: InterpResolution = .full,
        /// High-frequency noise layered on after erosion; its amount follows
        /// the pre-erosion gradient, so rocky detail collects on slopes while
        /// flats stay smooth.
        surface_noise: Noise.Noise(f32) = .{
            .frequency = 0.04,
            .noise_type = .simplex,
            .rotation_type = .improve_xy_planes,
            .fractal_type = .fbm,
            .octaves = 3,
            .lacunarity = 2,
            .gain = 0.5,
        },
        /// Maximum surface height delta in normalized units, converted with the
        /// symmetric envelope so coasts and seabed share the same relief.
        surface_noise_amplitude: f32 = 0.012,
        /// How much the pre-erosion gradient scales the amount: 0 is uniform,
        /// 1 scales it by the gradient so flat ground gets none.
        surface_noise_gradient_influence: f32 = 0.8,
        /// Pre-erosion gradient magnitude at which the full amount applies,
        /// in shaped units per block.
        surface_noise_gradient_scale: f32 = 0.01,
        /// Sampling density of the surface detail noise. Full disables interpolation.
        surface_interp: InterpResolution = .full,
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
        /// Beach elevation lost per unit slope, in blocks. The sand line is
        /// elev + falloff * slope <= beach_band, so steep shores get narrower
        /// beaches and cliffs meet the water with stone.
        sand_slope_falloff: f32 = 10,
        /// Slope above which the underwater floor is stone instead of sand.
        sea_floor_rock_slope: f32 = 0.6,
        /// How much the grass slope limit drops per unit of normalized
        /// altitude above ground_altitude_base. High meadows turn rocky sooner.
        grass_height_falloff: f32 = 0.3,
        /// How much the dirt band narrows per unit of normalized altitude
        /// above ground_altitude_base.
        dirt_height_falloff: f32 = 0.2,
        /// Normalized altitude where the grass/dirt falloffs start. Below this
        /// the lowland thresholds apply in full.
        ground_altitude_base: f32 = 0.0,
        /// How much the snow line rises per unit slope. Steep faces need more
        /// altitude to hold snow.
        snow_slope_gain: f32 = 0.35,
        /// Slope at or above which high ground sheds snow to bare stone.
        snow_cliff_slope: f32 = 1.0,
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
        /// Sampling density of the mountain (ridged) noise; warp and noise
        /// share the coarse lattice. Full disables interpolation.
        terrain_interp: InterpResolution = .full,
        /// Sampling density of the continental noise; the large warp follows
        /// this setting on the same lattice. Full disables interpolation.
        large_terrain_interp: InterpResolution = .full,
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
        /// Horizontal (X/Z) sampling density of the cave noise grid.
        cave_interp_h: InterpResolution = .eighth,
        /// Vertical (Y) sampling density of the cave noise grid, so grids
        /// like 4x8x4 are possible. Both stay at the legacy 4 default.
        cave_interp_v: InterpResolution = .eighth,
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
            const noise_salts = .{ 1, 3, 4, 4, 6 };
            inline for (.{ &self.cave_noise, &self.terrain_noise, &self.large_terrain_noise, &self.large_terrain_noise_warp, &self.surface_noise }, noise_salts) |noise, salt| {
                noise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(seed +% salt));
            }
        }

        /// Default parameter set; every field carries its default value in the
        /// declaration, so configs missing fields parse back with the defaults.
        pub const default = Params{};

        /// ErosionParams for the given LOD: coarser levels drop the finest
        /// octaves, whose wavelength falls below their sample spacing, while
        /// the rest stay absolute in world space so gullies match across levels.
        fn erosionFilterParams(self: *const Params, level: i32) erosion.ErosionParams {
            const drop: u32 = @intCast(@max(level, 0));
            return .{
                .filter_strength = self.erosion_filter_strength,
                .gully_weight = self.erosion_gully_weight,
                .detail = self.erosion_detail,
                .octaves = @max(1, self.erosion_octaves -| drop),
                .lacunarity = self.erosion_lacunarity,
                .gain = self.erosion_gain,
                .cell_scale = self.erosion_cell_scale,
                .normalization = self.erosion_normalization,
                .ridge_rounding = self.erosion_ridge_rounding,
                .crease_rounding = self.erosion_crease_rounding,
                .assumed_slope = self.erosion_assumed_slope,
                .assumed_slope_amount = self.erosion_assumed_slope_amount,
                .fade_slope = self.erosion_fade_slope,
                .fade_altitude = self.erosion_fade_altitude,
            };
        }
    };

    pub const TreeConfig = struct {
        placer: JitteredGrid(2, i32) = .{},
        enabled: bool = true,
        size_variation: f32 = 0.5,
        /// Hidden from the config tree (unreflectable); stays at the defaults.
        tree: Tree.Config = .small,
    };

    const GenContext = struct { params: *const Params, rand: *std.Random, chunk_scale: f32 };

    const GroundContext = struct { block_height: i64, sea_level: i64, block_randomness: f32, one_d_terrain_scale: f32, slope: f32, slope_randomness: f32, ground_threshold: f32, dirt_band: f32, snow_line: f32, beach_band_blocks: f32, sand_slope: f32, sand_slope_falloff_blocks: f32, sea_floor_rock_slope: f32, grass_height_falloff: f32, dirt_height_falloff: f32, ground_altitude_base: f32, snow_slope_gain: f32, snow_cliff_slope: f32 };

    pub fn genChunk(self: *DefaultGenerator, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, blocks: *Chunk.Encoding, world: *World, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) !void {
        @setFloatMode(.optimized);
        if (chunk_pos.level < 0) {
            try self.genDetailTest(io, allocator, chunk_pos, blocks, world, grid_buffer);
            return;
        }
        const chunk_scale_factor = 1.0 / ChunkPos.toScale(chunk_pos.level);
        const gen = tracy.Zone.begin(.{ .src = @src() });
        defer gen.end();
        // The height field is shaped * |bounds| * scale, so terrain_scale stretches the
        // vertical min/max envelope; cull against the scaled world height, not the raw params.
        const max_global_y: i64 = @round(@as(f32, @floatFromInt(self.params.terrain_max)) * self.params.terrain_scale);
        const min_global_y: i64 = @round(@as(f32, @floatFromInt(self.params.terrain_min)) * self.params.terrain_scale);
        if (chunk_pos.position[1] > ChunkPos.fromGlobalBlockPos(.{ 0, max_global_y, 0 }, chunk_pos.level).position[1]) {
            blocks.merge(.{ .uniform = .air }, grid_buffer);
            return;
        }
        var block_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.null)));
        if (chunk_pos.position[1] < ChunkPos.fromGlobalBlockPos(.{ 0, min_global_y, 0 }, chunk_pos.level).position[1]) {
            blocks.merge(.{ .uniform = .stone }, grid_buffer);
        } else {
            var rng = std.Random.DefaultPrng.init(self.params.seed.? +% @as(u64, @truncate(@as(u96, @bitCast(chunk_pos.position)))));
            var rand = rng.random();
            const heights = try self.getTerrainHeight(io, [2]i32{ chunk_pos.position[0], chunk_pos.position[2] }, chunk_pos.level);
            const gen_terrain_zone = tracy.Zone.begin(.{ .src = @src(), .name = "GenTerrainBlocks" });
            generateTerrain(&block_grid, chunk_pos, heights, .{ .params = &self.params, .rand = &rand, .chunk_scale = chunk_scale_factor });
            gen_terrain_zone.end();
            if (Chunk.getUniform(&block_grid) == Block.air) {
                blocks.merge(.{ .uniform = .air }, grid_buffer);
                return;
            }
        }
        generateCavesInterpolate(&block_grid, chunk_pos, chunk_scale_factor, &self.params);
        const one_block = Chunk.getUniform(&block_grid);
        if (one_block) |block| {
            blocks.merge(.{ .uniform = block }, grid_buffer);
        } else blocks.merge(.{ .grid = &block_grid }, grid_buffer);
    }

    /// Grass detail test: grows alternating blades, up to half a level-0
    /// block tall, in open air on top of grass or dirt for every level below
    /// 0. Each level reads level 0 directly, so all detail LODs align to the
    /// same blocks.
    /// Parent-hoisted: one fine chunk spans few level-0 parents, so each
    /// parent column is read once and fanned out to its fine voxels instead
    /// of re-reading the same parents per voxel.
    fn genDetailTest(_: *DefaultGenerator, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, blocks: *Chunk.Encoding, world: *World, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) !void {
        if (chunk_pos.level >= World.standard_level or chunk_pos.level <= -60) return;
        // One level-0 block spans 2^-level fine voxels per axis. Integer math
        // keeps the mapping bit-exact; the f64 levelToLevelRatio would round.
        const fine_per_block: i64 = @as(i64, 1) << @as(u6, @intCast(-chunk_pos.level));
        const half_block: i64 = @divExact(fine_per_block, 2);
        // Chunk origin in fine-voxel units. Global coords keep every level
        // aligned even where the chunk grid stops dividing the block grid.
        const base: World.BlockPos = chunk_pos.toLocalBlockPos();
        const parent_min: World.BlockPos = @divFloor(base, @as(World.BlockPos, @splat(fine_per_block)));
        const parent_max: World.BlockPos = @divFloor(base + @as(World.BlockPos, @splat(ChunkSize - 1)), @as(World.BlockPos, @splat(fine_per_block)));
        var reader = World.Reader{ .world = world };
        defer reader.clear(io);
        var detail_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.null)));
        var any_filled = false;
        var parent_x = parent_min[0];
        while (parent_x <= parent_max[0]) : (parent_x += 1) {
            var parent_z = parent_min[2];
            while (parent_z <= parent_max[2]) : (parent_z += 1) {
                var layers: [ChunkSize + 1]DetailLayer = undefined;
                const layer_count = try surfaceLayers(&reader, io, allocator, parent_x, parent_min[1], parent_max[1], parent_z, &layers);
                if (layer_count == 0) continue;
                if (fillBlades(&detail_grid, base, fine_per_block, half_block, parent_x, parent_z, layers[0..layer_count])) any_filled = true;
            }
        }
        if (!any_filled) {
            // Uniform air, not null: null meshes to nothing anyway, but only
            // after the full face-extraction round-trip, while air is skipped.
            blocks.merge(.{ .uniform = .air }, grid_buffer);
            return;
        }
        blocks.merge(.{ .grid = &detail_grid }, grid_buffer);
    }

    const DetailLayer = struct { y: i64, short: bool };

    /// Collects the parent heights in one (x, z) column whose block is open
    /// air above grass or dirt. Reads chain vertically: each block doubles as
    /// the next layer's below, so the scan costs one read per layer.
    fn surfaceLayers(reader: *World.Reader, io: std.Io, allocator: std.mem.Allocator, parent_x: i64, parent_min_y: i64, parent_max_y: i64, parent_z: i64, layers: *[ChunkSize + 1]DetailLayer) !usize {
        var layer_count: usize = 0;
        var below = try reader.getBlock(io, allocator, .{ parent_x, parent_min_y - 1, parent_z }, World.standard_level);
        var parent_y = parent_min_y;
        while (parent_y <= parent_max_y) : (parent_y += 1) {
            const current = try reader.getBlock(io, allocator, .{ parent_x, parent_y, parent_z }, World.standard_level);
            if ((below == .grass or below == .dirt) and current == .air) {
                layers[layer_count] = .{ .y = parent_y, .short = below == .dirt };
                layer_count += 1;
            }
            below = current;
        }
        return layer_count;
    }

    /// Fans one parent column's surface layers out to fine voxels. Returns
    /// whether any voxel was written. Matches the per-voxel checker, blade
    /// hash, and height gate exactly. Dirt layers grow at half height.
    fn fillBlades(detail_grid: *[ChunkSize][ChunkSize][ChunkSize]Block, base: World.BlockPos, fine_per_block: i64, half_block: i64, parent_x: i64, parent_z: i64, layers: []const DetailLayer) bool {
        const half: u32 = @intCast(half_block);
        const fine_lo_x = @max(parent_x * fine_per_block, base[0]);
        const fine_hi_x = @min(parent_x * fine_per_block + fine_per_block - 1, base[0] + ChunkSize - 1);
        const fine_lo_z = @max(parent_z * fine_per_block, base[2]);
        const fine_hi_z = @min(parent_z * fine_per_block + fine_per_block - 1, base[2] + ChunkSize - 1);
        var filled = false;
        var fine_x = fine_lo_x;
        while (fine_x <= fine_hi_x) : (fine_x += 1) {
            var fine_z = fine_lo_z;
            while (fine_z <= fine_hi_z) : (fine_z += 1) {
                if ((fine_x + fine_z) & 1 != 0) continue;
                const blade: u32 = @bitCast(Noise.hash2D(0, @truncate(fine_x), @truncate(fine_z)));
                const height: i64 = 1 + @as(i64, @intCast((blade >> 16) % half));
                for (layers) |layer| {
                    const h = if (layer.short) @max(@divFloor(height, 2), 1) else height;
                    const layer_base = layer.y * fine_per_block;
                    const lo = @max(layer_base, base[1]);
                    const hi = @min(@min(layer_base + fine_per_block - 1, base[1] + ChunkSize - 1), layer_base + h - 1);
                    if (hi < lo) continue;
                    var fine_y = lo;
                    while (fine_y <= hi) : (fine_y += 1) {
                        detail_grid[@intCast(fine_x - base[0])][@intCast(fine_y - base[1])][@intCast(fine_z - base[2])] = .grass;
                    }
                    filled = true;
                }
            }
        }
        return filled;
    }

    test "detail parent mapping matches renderer placement" {
        const levels = [_]i32{ -1, -2, -3, -4, -5, -6, -7, -8 };
        const positions = [_]i32{ -33, -3, -2, -1, 0, 1, 5, 100 };
        for (levels) |level| {
            const fine_per_block: i64 = @as(i64, 1) << @as(u6, @intCast(-level));
            const ratio = ChunkPos.levelToBlockRatioFloat(level);
            const scale = ChunkPos.toScale(level);
            for (positions) |c| {
                for (0..ChunkSize) |l| {
                    const world_lo: f32 = @as(f32, @floatFromInt(c)) * ratio + @as(f32, @floatFromInt(l)) * scale;
                    const g: i64 = @as(i64, c) * ChunkSize + @as(i64, @intCast(l));
                    const parent = @divFloor(g, fine_per_block);
                    const parent_f: f32 = @floatFromInt(parent);
                    try std.testing.expect(world_lo >= parent_f - 1e-4);
                    try std.testing.expect(world_lo + scale <= parent_f + 1 + 1e-4);
                    const frac_expected: f32 = @as(f32, @floatFromInt(@mod(g, fine_per_block))) * scale;
                    try std.testing.expect(@abs(world_lo - parent_f - frac_expected) < 1e-4);
                }
            }
        }
    }

    fn generateTerrain(chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_pos: ChunkPos, heights: [ChunkSize][ChunkSize]f32, ctx: GenContext) void {
        const terrain_scales: [2]f32 = .{ 1.0 / @as(f32, @floatFromInt(@abs(ctx.params.terrain_max))), 1.0 / @as(f32, @floatFromInt(@abs(ctx.params.terrain_min))) };
        const scale = ctx.params.terrain_scale * ctx.chunk_scale;
        const one_d_terrain_scale: f32 = 1.0 / scale;
        const sea_level: i32 = ctx.params.sea_level;
        const sea_level_f: f32 = @floatFromInt(sea_level);
        const BoolV = @Vector(ChunkSize, bool);
        const TagV = @Vector(ChunkSize, Block.Tag);
        const zero_v: FloatV = @splat(0);
        const one_v: FloatV = @splat(1);
        // Preserves the old integer test floor(th) - bh > ceil(dirt_depth * scale), translated to f32.
        const depth_threshold: f32 = @floor(ctx.params.dirt_depth * scale) + 1.0;

        const block_height_vec: [ChunkSize]i32 = std.simd.iota(i32, ChunkSize) + @as(@Vector(ChunkSize, i32), @splat(chunk_pos.position[1] * ChunkSize));
        // The differential is the slope (block-space gradient magnitude) and is LOD-invariant,
        // so it feeds randGround directly with no divisor or normalization.
        const differential = getDifferential(&heights);
        for (heights, chunk_blocks, 0..) |heights_row, *col, x| {
            const th: FloatV = heights_row;
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

                const base_tag: TagV = @splat(@intFromEnum(if (bh <= sea_level) Block.water else Block.air));
                const land_tag: TagV = @splat(@intFromEnum(if (bh <= sea_level) Block.sand else Block.dirt));
                const stone_tag: TagV = @splat(@intFromEnum(Block.stone));
                row.* = @bitCast(@select(Block.Tag, below_or, @select(Block.Tag, below_depth, stone_tag, land_tag), base_tag));

                var surface_bits: u32 = @as(u32, @bitCast(below_or)) & @as(u32, @bitCast(diff < one_v));
                while (surface_bits != 0) {
                    const z: usize = @ctz(surface_bits);
                    surface_bits &= surface_bits - 1;
                    row[z] = randGround(ctx.rand, heights_row[z] * terrain_scales[@intFromBool(heights_row[z] <= sea_level_f)], .{
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
                        .sand_slope_falloff_blocks = ctx.params.sand_slope_falloff * scale,
                        .sea_floor_rock_slope = ctx.params.sea_floor_rock_slope,
                        .grass_height_falloff = ctx.params.grass_height_falloff,
                        .dirt_height_falloff = ctx.params.dirt_height_falloff,
                        .ground_altitude_base = ctx.params.ground_altitude_base,
                        .snow_slope_gain = ctx.params.snow_slope_gain,
                        .snow_cliff_slope = ctx.params.snow_cliff_slope,
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
        switch (gen_params.cave_interp_h) {
            inline else => |htag| switch (gen_params.cave_interp_v) {
                inline else => |vtag| sampleCavesInterpolate(htag.size(), vtag.size(), chunk_blocks, chunk_pos, chunk_scale, gen_params),
            },
        }
    }

    /// Cave noise on an H×V×H lattice interpolated to the full grid. Uniform
    /// lattices reuse the grid fill; mixed ones sample explicit coordinates
    /// slab by slab. Full/full samples every voxel directly instead.
    fn sampleCavesInterpolate(comptime H: usize, comptime V: usize, chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_pos: ChunkPos, chunk_scale: f32, gen_params: *const Params) void {
        const float_pos: @Vector(3, f32) = .{ @floatFromInt(chunk_pos.position[0]), @floatFromInt(chunk_pos.position[1]), @floatFromInt(chunk_pos.position[2]) };
        const one_d_scale: f32 = 1.0 / (gen_params.terrain_scale * chunk_scale);
        const grid_origin = float_pos * @as(@Vector(3, f32), @splat(one_d_scale));
        if (comptime H == ChunkSize and V == ChunkSize) {
            carveCavesDirect(chunk_blocks, float_pos, grid_origin, one_d_scale, gen_params);
            return;
        }
        const cave_noise_zone = tracy.Zone.begin(.{ .src = @src(), .name = "caveNoise" });
        var grid_flat: [H * V * H]f32 = undefined;
        if (comptime H == V) {
            gen_params.cave_noise.fillGrid3D(&grid_flat, H, H, grid_origin[0], grid_origin[1], grid_origin[2], (1.0 / @as(f32, H - 1)) * one_d_scale);
        } else {
            sampleCaveGridMixed(H, V, grid_origin, one_d_scale, gen_params, &grid_flat);
        }
        cave_noise_zone.end();

        const CaveInterp = interpolation.MultilinearInterpolator(f32, 3, .{ H, V, H }, .{ ChunkSize, ChunkSize, ChunkSize });
        const cave_values = CaveInterp.init(@bitCast(grid_flat)).sampleGrid();
        carveCavesApply(chunk_blocks, float_pos, one_d_scale, gen_params, &cave_values);
    }

    /// Explicit coarse coordinates for mixed H/V lattices, one Y slab at a
    /// time; flat order matches the interpolator grid (z*V+y)*H+x.
    fn sampleCaveGridMixed(comptime H: usize, comptime V: usize, grid_origin: @Vector(3, f32), one_d_scale: f32, gen_params: *const Params, grid_flat: *[H * V * H]f32) void {
        const x_spacing = one_d_scale / @as(f32, H - 1);
        const y_spacing = one_d_scale / @as(f32, V - 1);
        for (0..V) |j| {
            var xs: [H * H]f32 = undefined;
            var ys: [H * H]f32 = undefined;
            var zs: [H * H]f32 = undefined;
            const y = grid_origin[1] + @as(f32, @floatFromInt(j)) * y_spacing;
            for (0..H) |c| {
                for (0..H) |a| {
                    xs[c * H + a] = grid_origin[0] + @as(f32, @floatFromInt(a)) * x_spacing;
                    ys[c * H + a] = y;
                    zs[c * H + a] = grid_origin[2] + @as(f32, @floatFromInt(c)) * x_spacing;
                }
            }
            gen_params.cave_noise.fillNoise3DGrid(grid_flat[j * H * H ..][0 .. H * H], &xs, &ys, &zs);
        }
    }

    /// Full-resolution cave sampling without an interpolator: one X/Y slice
    /// per Z step, carved straight into the blocks.
    fn carveCavesDirect(chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, float_pos: @Vector(3, f32), grid_origin: @Vector(3, f32), one_d_scale: f32, gen_params: *const Params) void {
        const cave_noise_zone = tracy.Zone.begin(.{ .src = @src(), .name = "caveNoise" });
        defer cave_noise_zone.end();
        const spacing = one_d_scale / @as(f32, ChunkSize - 1);
        const apply_zone = tracy.Zone.begin(.{ .src = @src(), .name = "caveApply" });
        defer apply_zone.end();
        for (0..ChunkSize) |j| {
            var slice: [ChunkSize * ChunkSize]f32 = undefined;
            gen_params.cave_noise.fillGrid3D(&slice, ChunkSize, 1, grid_origin[0], grid_origin[1], grid_origin[2] + @as(f32, @floatFromInt(j)) * spacing, spacing);
            for (0..ChunkSize) |y| {
                const real_y = ((float_pos[1] * ChunkSize) + @as(f32, @floatFromInt(y))) * one_d_scale;
                const cave_threshold: f32 = caveThresholdAt(real_y, gen_params.cave_threshold, gen_params.cave_expansion_max);
                const is_cave = @as(FloatV, slice[y * ChunkSize ..][0..ChunkSize].*) < @as(FloatV, @splat(cave_threshold));
                if (std.simd.firstTrue(is_cave) == null) continue;
                inline for (0..ChunkSize) |x| {
                    if (is_cave[x]) chunk_blocks[x][y][j] = .air;
                }
            }
        }
    }

    /// Thresholds an interpolated cave grid, carving air where noise falls
    /// below the depth-dependent threshold. Shared by every lattice density.
    fn carveCavesApply(chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, float_pos: @Vector(3, f32), one_d_scale: f32, gen_params: *const Params, cave_values: *const [ChunkSize][ChunkSize]FloatV) void {
        const apply_zone = tracy.Zone.begin(.{ .src = @src(), .name = "caveApply" });
        defer apply_zone.end();
        for (0..ChunkSize) |y| {
            const real_y = ((float_pos[1] * ChunkSize) + @as(f32, @floatFromInt(y))) * one_d_scale;
            const cave_threshold: f32 = caveThresholdAt(real_y, gen_params.cave_threshold, gen_params.cave_expansion_max);
            for (0..ChunkSize) |z| {
                const is_cave = cave_values[y][z] < @as(FloatV, @splat(cave_threshold));
                if (std.simd.firstTrue(is_cave) == null) continue;
                inline for (0..ChunkSize) |x| {
                    if (is_cave[x]) chunk_blocks[x][y][z] = .air;
                }
            }
        }
    }

    fn randGround(rand: *const std.Random, height_percent: f32, ctx: GroundContext) Block {
        // Both draws happen up front so every surface voxel consumes the same
        // RNG stream whatever branch it takes; neighbors stay independent of
        // each other's cover type.
        const slope_jitter = (rand.float(f32) * 2.0 - 1.0) * ctx.slope_randomness;
        const cover_rand = rand.float(f32);
        // Jitter the slope so the cover boundaries break up instead of tracing
        // smooth contours. Shared by every test so the slanted boundaries move
        // together with no gaps or overlaps.
        const a = ctx.slope + slope_jitter;
        const height_norm = height_percent * ctx.one_d_terrain_scale;
        const height_above = @max(height_norm - ctx.ground_altitude_base, 0);

        // Steep underwater cliffs are rock; only gentle seabed is sand.
        if (ctx.block_height < ctx.sea_level) return if (a < ctx.sea_floor_rock_slope) Block.sand else Block.stone;

        // Beaches taper with slope: higher gradients need lower ground to stay
        // sand. Keeps its own cap so beaches can be narrower or wider than grass.
        const elev: f32 = @floatFromInt(ctx.block_height - ctx.sea_level);
        if (elev <= ctx.beach_band_blocks - ctx.sand_slope_falloff_blocks * a and a < ctx.sand_slope) return Block.sand;

        // High ground turns rocky sooner and the dirt band narrows with altitude.
        const ground_threshold = ctx.ground_threshold - ctx.grass_height_falloff * height_above;
        const dirt_band = @max(ctx.dirt_band - ctx.dirt_height_falloff * height_above, 0);

        // Exposed rock: high steep faces shed snow and dirt to bare stone.
        if (height_norm >= ctx.snow_line and a >= ctx.snow_cliff_slope) return Block.stone;

        if (a < ground_threshold) {
            // Soft ground: grass or snow by altitude, with the snow line rising
            // on slopes so steep faces need more altitude to hold snow.
            const cover = std.math.lerp(height_norm, cover_rand, ctx.block_randomness);
            return if (cover < ctx.snow_line + ctx.snow_slope_gain * a) Block.grass else Block.snow;
        }
        // Dirt band above the ground threshold; steeper ground is stone.
        return if (a - dirt_band < ground_threshold) Block.dirt else Block.stone;
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
        const ctx = HeightCtx.init(params, level, chunk_pos);
        const erosion_on = params.erosion_enabled;
        const surface_on = params.surface_noise_amplitude > 0;
        var height: [ChunkSize][ChunkSize]f32 = undefined;

        // Domain warp is inherently per-point, so warp the base coordinate grid
        // into two irregular coordinate sets, then sample both in one batched pass.
        const base_coords_zone = tracy.Zone.begin(.{ .src = @src(), .name = "baseCoords" });
        var base_x: [sample_count]f32 = undefined;
        var base_z: [sample_count]f32 = undefined;
        fillCoordGrid(ChunkSize, 0, &base_x, &base_z, ctx.pos, ctx.step, ctx.one_d_scale);
        base_coords_zone.end();

        const warp_zone = tracy.Zone.begin(.{ .src = @src(), .name = "terrainWarp" });
        var terrain_noise_raw: [sample_count]f32 = undefined;
        var large_terrain_noise: [sample_count]f32 = undefined;
        switch (params.terrain_interp) {
            .full => {
                var terrain_warped_x: [sample_count]f32 = undefined;
                var terrain_warped_z: [sample_count]f32 = undefined;
                params.terrain_noise.fillWarp2DGrid(&terrain_warped_x, &terrain_warped_z, &base_x, &base_z);
                params.terrain_noise.fillNoise2DGrid(&terrain_noise_raw, &terrain_warped_x, &terrain_warped_z);
            },
            // Warp shares the noise lattice: warped coordinates are irregular,
            // so a separate warp density would need its own interpolation pass.
            inline else => |tag| sampleWarpNoiseCoarse(tag.size(), &params.terrain_noise, &params.terrain_noise, &ctx, &terrain_noise_raw),
        }
        switch (params.large_terrain_interp) {
            .full => {
                var large_warped_x: [sample_count]f32 = undefined;
                var large_warped_z: [sample_count]f32 = undefined;
                params.large_terrain_noise_warp.fillWarp2DGrid(&large_warped_x, &large_warped_z, &base_x, &base_z);
                params.large_terrain_noise.fillNoise2DGrid(&large_terrain_noise, &large_warped_x, &large_warped_z);
            },
            inline else => |tag| sampleWarpNoiseCoarse(tag.size(), &params.large_terrain_noise_warp, &params.large_terrain_noise, &ctx, &large_terrain_noise),
        }
        warp_zone.end();

        const heights_zone = tracy.Zone.begin(.{ .src = @src(), .name = "blockHeights" });
        // The filter consumes the pre-envelope shaped value; the envelope is
        // applied after, so both share the same world-space scale.
        var shaped_center: [ChunkSize][ChunkSize]f32 = undefined;
        for (0..ChunkSize) |x| {
            const raw: FloatV = @as(FloatV, terrain_noise_raw[x * ChunkSize ..][0..ChunkSize].*);
            const large = @as(FloatV, large_terrain_noise[x * ChunkSize ..][0..ChunkSize].*);
            shaped_center[x] = shapedRow(ChunkSize, params, large, raw);
        }
        heights_zone.end();

        // Central differences of the shaped field at +/- one sample spacing,
        // each evaluated from world coordinates alone so chunk borders stay
        // seamless. Feeds the erosion filter and the gradient-scaled surface
        // noise; accumulators are only read when one of them is active.
        var grad_x: [sample_count]f32 = @splat(0);
        var grad_z: [sample_count]f32 = @splat(0);
        if (erosion_on or (surface_on and params.surface_noise_gradient_influence > 0)) {
            computeGradient(&ctx, &base_x, &base_z, &grad_x, &grad_z);
        }

        // Surface detail in normalized units; converted with the symmetric
        // maximum in the final compose so coasts and seabed share the relief.
        var extra: [sample_count]f32 = @splat(0);
        if (surface_on) surfaceNorm(&ctx, &base_x, &base_z, &grad_x, &grad_z, &extra);
        if (erosion_on) applyErosion(&ctx, &base_x, &base_z, &grad_x, &grad_z, &shaped_center, &extra);
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |z| {
                height[x][z] = composeErodedHeight(shaped_center[x][z], extra[x * ChunkSize + z], ctx.env);
            }
        }
        return height;
    }

    /// Signed power curve: sign-preserving |v|^power, steepening (>1) or flattening (<1).
    inline fn signedPow(comptime N: usize, v: @Vector(N, f32), power: @Vector(N, f32)) @Vector(N, f32) {
        const magnitude = @exp2(power * @log2(@abs(v)));
        return @select(f32, v < @as(@Vector(N, f32), @splat(0)), -magnitude, magnitude);
    }

    /// Final height from the shaped field and a normalized delta (erosion,
    /// surface noise, or their sum). The base takes the asymmetric envelope,
    /// continuous through zero by construction; the delta converts with the
    /// symmetric maximum so relief matches on land and under water instead
    /// of ending in a cliff at the shoreline.
    inline fn composeErodedHeight(shaped: f32, delta: f32, env: Envelope) f32 {
        const base = if (shaped > 0) env.bounds[1] else env.bounds[0];
        return shaped * @abs(base) * env.scale + delta * env.max * env.scale;
    }

    /// Surface amount scaled by the pre-erosion gradient: influence 1 applies
    /// the full amount only where the gradient reaches `gradient_scale`.
    inline fn surfaceNoiseAmount(grad_mag: f32, params: *const Params) f32 {
        const steepness = std.math.clamp(grad_mag / @max(params.surface_noise_gradient_scale, 1e-6), 0, 1);
        return params.surface_noise_amplitude * std.math.lerp(1.0, steepness, params.surface_noise_gradient_influence);
    }

    /// N×N coordinate grid with dimension d holding ((i - pad) * d + pos) * o
    /// on x and (i - pad) * (d * o) + pos * o on z. The chunk grid (pad 0)
    /// and the fade ring share this layout, keeping the two association
    /// orders each sampler was tuned against.
    fn fillCoordGrid(comptime N: usize, pad: usize, x_out: *[N * N]f32, z_out: *[N * N]f32, pos: [2]f32, d: f32, o: f32) void {
        const pad_f: f32 = @floatFromInt(pad);
        const dxo = d * o;
        var row_z: [N]f32 = undefined;
        for (0..N) |j| row_z[j] = (@as(f32, @floatFromInt(j)) - pad_f) * dxo + pos[1] * o;
        for (0..N) |i| {
            x_out[i * N ..][0..N].* = @splat(((@as(f32, @floatFromInt(i)) - pad_f) * d + pos[0]) * o);
            @memcpy(z_out[i * N ..][0..N], &row_z);
        }
    }

    /// Coarse warp+noise pipeline for one height noise: evaluates warp and
    /// noise on a (G+1)² lattice and interpolates to the full grid. Node
    /// (a, b) sits exactly on full-res sample (a*stride, b*stride) with the
    /// far edge shared with the neighbor chunk, so borders stay consistent.
    fn sampleWarpNoiseCoarse(comptime G: usize, warp_state: *const Noise.Noise(f32), noise_state: *const Noise.Noise(f32), ctx: *const HeightCtx, out: *[sample_count]f32) void {
        const N = G + 1;
        const stride: f32 = @floatFromInt(ChunkSize / G);
        var coarse_x: [N * N]f32 = undefined;
        var coarse_z: [N * N]f32 = undefined;
        fillCoordGrid(N, 0, &coarse_x, &coarse_z, ctx.pos, ctx.step * stride, ctx.one_d_scale);
        var warped_x: [N * N]f32 = undefined;
        var warped_z: [N * N]f32 = undefined;
        warp_state.fillWarp2DGrid(&warped_x, &warped_z, &coarse_x, &coarse_z);
        var coarse: [N * N]f32 = undefined;
        noise_state.fillNoise2DGrid(&coarse, &warped_x, &warped_z);
        const Interp = interpolation.MultilinearInterpolator(f32, 2, .{ N, N }, .{ ChunkSize, ChunkSize });
        const samples = Interp.init(@bitCast(coarse)).sampleGrid();
        for (0..ChunkSize) |x| {
            const row: [ChunkSize]f32 = samples[x];
            for (0..ChunkSize) |z| out[x * ChunkSize + z] = row[z];
        }
    }

    /// Full-resolution flat index of coarse node (a, b): nodes decimate the
    /// full grid at stride, with the far edge clamped to the last sample
    /// (its true neighbor belongs to the next chunk).
    inline fn coarseSourceIndex(comptime stride: usize, a: usize, b: usize) usize {
        const fx: usize = @min(a * stride, ChunkSize - 1);
        const fz: usize = @min(b * stride, ChunkSize - 1);
        return fx * ChunkSize + fz;
    }

    /// Central differences of the shaped field at +/- one sample spacing on
    /// each axis, folded into the gradient accumulators. Every point is
    /// evaluated from world coordinates alone so chunk borders stay seamless.
    fn computeGradient(ctx: *const HeightCtx, base_x: []const f32, base_z: []const f32, grad_x: []f32, grad_z: []f32) void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "terrainGradient" });
        defer zone.end();
        var scratch: GradientScratch = undefined;
        const e = ctx.step * ctx.one_d_scale;
        const one_d_2e = 1.0 / (2.0 * e);
        inline for (0..2) |axis| {
            for ([2]f32{ 1.0, -1.0 }) |sign| {
                const offset: [2]f32 = if (axis == 0) .{ sign * e, 0 } else .{ 0, sign * e };
                addGradientSamples(ctx.params, &scratch, base_x, base_z, .{ grad_x, grad_z }[axis], offset, sign, one_d_2e);
            }
        }
    }

    /// Surface detail in normalized units; the amount follows the pre-erosion
    /// gradient so steep relief gains rocky detail while flats stay smooth.
    fn surfaceNorm(ctx: *const HeightCtx, base_x: []const f32, base_z: []const f32, grad_x: []f32, grad_z: []f32, out: []f32) void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "surfaceNoise" });
        defer zone.end();
        switch (ctx.params.surface_interp) {
            .full => {
                var raw: [sample_count]f32 = undefined;
                ctx.params.surface_noise.fillNoise2DGrid(&raw, base_x, base_z);
                const uses_gradient = ctx.params.surface_noise_gradient_influence > 0;
                for (0..sample_count) |i| {
                    const mag = if (uses_gradient) @sqrt(grad_x[i] * grad_x[i] + grad_z[i] * grad_z[i]) else 0.0;
                    out[i] = surfaceNoiseAmount(mag, ctx.params) * raw[i];
                }
            },
            inline else => |tag| surfaceNormCoarse(tag.size(), ctx, grad_x, grad_z, out),
        }
    }

    /// Coarse surface detail: noise runs on the border-shared lattice from
    /// world coordinates while the amount decimates the full-resolution
    /// gradient, then the product interpolates up.
    fn surfaceNormCoarse(comptime G: usize, ctx: *const HeightCtx, grad_x: []const f32, grad_z: []const f32, out: []f32) void {
        const N = G + 1;
        const stride: usize = ChunkSize / G;
        const stride_f: f32 = @floatFromInt(stride);
        var coarse_x: [N * N]f32 = undefined;
        var coarse_z: [N * N]f32 = undefined;
        fillCoordGrid(N, 0, &coarse_x, &coarse_z, ctx.pos, ctx.step * stride_f, ctx.one_d_scale);
        var raw: [N * N]f32 = undefined;
        ctx.params.surface_noise.fillNoise2DGrid(&raw, &coarse_x, &coarse_z);
        const uses_gradient = ctx.params.surface_noise_gradient_influence > 0;
        var prod: [N * N]f32 = undefined;
        for (0..N) |a| {
            for (0..N) |b| {
                const i = coarseSourceIndex(stride, a, b);
                const mag = if (uses_gradient) @sqrt(grad_x[i] * grad_x[i] + grad_z[i] * grad_z[i]) else 0.0;
                prod[a * N + b] = surfaceNoiseAmount(mag, ctx.params) * raw[a * N + b];
            }
        }
        const Interp = interpolation.MultilinearInterpolator(f32, 2, .{ N, N }, .{ ChunkSize, ChunkSize });
        const samples = Interp.init(@bitCast(prod)).sampleGrid();
        for (0..ChunkSize) |x| {
            const row: [ChunkSize]f32 = samples[x];
            for (0..ChunkSize) |z| out[x * ChunkSize + z] = row[z];
        }
    }

    /// Fade steepness from a coarse central difference of the shaped field:
    /// the fine gradient is dominated by high-octave noise and would flicker
    /// the fade mask between neighbors. Sampled from world coordinates alone
    /// so the fade stays seamless across chunk borders.
    fn fadeSteepness(ctx: *const HeightCtx, p_scale: f32, out: []f32) void {
        const stencil = 4;
        const N = ChunkSize + 2 * stencil;
        var ext_x: [N * N]f32 = undefined;
        var ext_z: [N * N]f32 = undefined;
        fillCoordGrid(N, stencil, &ext_x, &ext_z, ctx.pos, ctx.step, ctx.one_d_scale);
        var warp_x: [N * N]f32 = undefined;
        var warp_z: [N * N]f32 = undefined;
        var large_warp_x: [N * N]f32 = undefined;
        var large_warp_z: [N * N]f32 = undefined;
        ctx.params.terrain_noise.fillWarp2DGrid(&warp_x, &warp_z, &ext_x, &ext_z);
        ctx.params.large_terrain_noise_warp.fillWarp2DGrid(&large_warp_x, &large_warp_z, &ext_x, &ext_z);
        var noise: [N * N]f32 = undefined;
        var large_noise: [N * N]f32 = undefined;
        ctx.params.terrain_noise.fillNoise2DGrid(&noise, &warp_x, &warp_z);
        ctx.params.large_terrain_noise.fillNoise2DGrid(&large_noise, &large_warp_x, &large_warp_z);
        var shaped_ext: [N * N]f32 = undefined;
        for (0..N) |x| {
            const raw: @Vector(N, f32) = noise[x * N ..][0..N].*;
            const large: @Vector(N, f32) = large_noise[x * N ..][0..N].*;
            shaped_ext[x * N ..][0..N].* = shapedRow(N, ctx.params, large, raw);
        }
        const e = ctx.step * ctx.one_d_scale;
        const one_d_2e = 1.0 / (2.0 * e);
        const inv_stencil = 1.0 / @as(f32, @floatFromInt(stencil));
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |z| {
                const ex = x + stencil;
                const ez = z + stencil;
                const d_x = (shaped_ext[(ex + stencil) * N + ez] - shaped_ext[(ex - stencil) * N + ez]) * one_d_2e * inv_stencil;
                const d_z = (shaped_ext[ex * N + (ez + stencil)] - shaped_ext[ex * N + (ez - stencil)]) * one_d_2e * inv_stencil;
                out[x * ChunkSize + z] = @sqrt(d_x * d_x + d_z * d_z) * p_scale;
            }
        }
    }

    /// Runs the erosion filter per sample, accumulating height deltas into
    /// `extra` (which already holds the surface term). Slopes point downhill
    /// and heights stay normalized; the envelope applies once in the compose.
    fn applyErosion(ctx: *const HeightCtx, base_x: []const f32, base_z: []const f32, grad_x: []f32, grad_z: []f32, shaped: *const [ChunkSize][ChunkSize]f32, extra: []f32) void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "erosionFilter" });
        defer zone.end();
        // Near-zero scales would push the pattern to absurd frequencies.
        const p_scale = @max(ctx.params.erosion_scale, 0.01);
        var fade: [sample_count]f32 = undefined;
        fadeSteepness(ctx, p_scale, &fade);
        const eparams = ctx.params.erosionFilterParams(ctx.level);
        switch (ctx.params.erosion_interp) {
            .full => {
                for (0..ChunkSize) |x| {
                    for (0..ChunkSize) |z| {
                        const i = x * ChunkSize + z;
                        extra[i] += erosion.erosionFilter(
                            .{ base_x[i] / p_scale, base_z[i] / p_scale },
                            .{ shaped[x][z], -grad_x[i] * p_scale, -grad_z[i] * p_scale },
                            fade[i],
                            eparams,
                        ).height_delta;
                    }
                }
            },
            inline else => |tag| applyErosionCoarse(tag.size(), base_x, base_z, grad_x, grad_z, shaped, &fade, p_scale, eparams, extra),
        }
    }

    /// Coarse erosion: the filter runs on the border-shared lattice from
    /// decimated full-resolution inputs and the height deltas interpolate up.
    fn applyErosionCoarse(comptime G: usize, base_x: []const f32, base_z: []const f32, grad_x: []const f32, grad_z: []const f32, shaped: *const [ChunkSize][ChunkSize]f32, fade: []const f32, p_scale: f32, eparams: erosion.ErosionParams, extra: []f32) void {
        const N = G + 1;
        const stride: usize = ChunkSize / G;
        var delta: [N * N]f32 = undefined;
        for (0..N) |a| {
            for (0..N) |b| {
                const fx: usize = @min(a * stride, ChunkSize - 1);
                const fz: usize = @min(b * stride, ChunkSize - 1);
                const i = fx * ChunkSize + fz;
                delta[a * N + b] = erosion.erosionFilter(
                    .{ base_x[i] / p_scale, base_z[i] / p_scale },
                    .{ shaped[fx][fz], -grad_x[i] * p_scale, -grad_z[i] * p_scale },
                    fade[i],
                    eparams,
                ).height_delta;
            }
        }
        const Interp = interpolation.MultilinearInterpolator(f32, 2, .{ N, N }, .{ ChunkSize, ChunkSize });
        const samples = Interp.init(@bitCast(delta)).sampleGrid();
        for (0..ChunkSize) |x| {
            const row: [ChunkSize]f32 = samples[x];
            for (0..ChunkSize) |z| extra[x * ChunkSize + z] += row[z];
        }
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
    /// normalized, then contrast-scaled. Shared by the base grid, the
    /// gradient samples, and the fade ring; the lane count follows the args.
    inline fn shapedRow(comptime N: usize, params: *const Params, large: @Vector(N, f32), raw: @Vector(N, f32)) @Vector(N, f32) {
        const V = @Vector(N, f32);
        const height_power_v: V = @splat(params.height_power);
        const large_power_v: V = @splat(params.large_power);
        const small_power_v: V = @splat(params.small_power);
        const balance_v: V = @splat(params.terrain_noise_balance);
        const sum_norm: V = @splat(1.0 / (1.0 + params.terrain_noise_balance));
        // Shape each field independently, then add (large = continents, raw =
        // mountains) normalized by 1 + balance so peaks never hard-clamp
        // into plateaus at the height cap.
        const warped = (signedPow(N, large, large_power_v) + signedPow(N, raw, small_power_v) * balance_v) * sum_norm;
        return signedPow(N, warped, height_power_v);
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
            scratch.off_x[x * ChunkSize ..][0..ChunkSize].* = @as(FloatV, base_x[x * ChunkSize ..][0..ChunkSize].*) + offset_x_v;
            scratch.off_z[x * ChunkSize ..][0..ChunkSize].* = @as(FloatV, base_z[x * ChunkSize ..][0..ChunkSize].*) + offset_z_v;
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
            grad[x * ChunkSize ..][0..ChunkSize].* = @mulAdd(FloatV, shapedRow(ChunkSize, params, large, raw), @as(FloatV, @splat(sign * one_d_2e)), grad_row);
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

                    const lvl_x: f32 = @floatFromInt(chunk_pos.position[0] * ChunkSize + @as(i32, @intCast(x)));
                    const lvl_z: f32 = @floatFromInt(chunk_pos.position[2] * ChunkSize + @as(i32, @intCast(z)));

                    for (self.params.trees) |tree_conf| {
                        if (!tree_conf.enabled) continue;
                        const structure_seed = tree_conf.placer.getStructure(.{ @trunc(lvl_x), @trunc(lvl_z) }, @intCast(chunk_pos.level)) orelse continue;
                        const center_pos = chunk_pos.position * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize } + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) };
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
    .ground_threshold = .{ .min = 0, .max = 4 },
    .dirt_band = .{ .min = 0, .max = 1 },
    .erosion_strength = .{ .skip = true },
    .erosion_enabled = .{ .label = "Erosion Enabled", .description = "Applies the Phacelle erosion filter to the terrain." },
    .erosion_scale = .{ .label = "Erosion Scale", .description = "Horizontal scale of the erosion pattern relative to the terrain.", .min = 0.01, .max = 5.0 },
    .erosion_filter_strength = .{ .label = "Erosion Filter Strength", .description = "Total magnitude across all erosion octaves.", .min = 0, .max = 1 },
    .erosion_gully_weight = .{ .label = "Erosion Gully Weight", .description = "Gully magnitude relative to the peak-sharpening effect.", .min = 0, .max = 1 },
    .erosion_detail = .{ .label = "Erosion Detail", .description = "Lower values restrict fine gullies to the steepest slopes.", .min = 0.1, .max = 4 },
    .erosion_octaves = .{ .label = "Erosion Octaves", .min = 1, .max = 8 },
    .erosion_lacunarity = .{ .label = "Erosion Lacunarity", .min = 1, .max = 4 },
    .erosion_gain = .{ .label = "Erosion Gain", .min = 0, .max = 1 },
    .erosion_cell_scale = .{ .label = "Erosion Cell Scale", .description = "Phacelle cell size relative to the stripe width; prone to abrupt changes far from the origin.", .min = 0.0, .max = 10.0, .advanced = true },
    .erosion_normalization = .{ .label = "Erosion Normalization", .description = "Ridge crispness; 1.0 can create loop artefacts where ridges meet.", .min = 0, .max = 1, .advanced = true },
    .erosion_ridge_rounding = .{ .label = "Erosion Ridge Rounding", .min = 0, .max = 1, .advanced = true },
    .erosion_crease_rounding = .{ .label = "Erosion Crease Rounding", .min = 0, .max = 1, .advanced = true },
    .erosion_assumed_slope = .{ .label = "Erosion Assumed Slope", .description = "Slope magnitude substituted for the terrain gradient.", .min = 0, .max = 2, .advanced = true },
    .erosion_assumed_slope_amount = .{ .label = "Erosion Assumed Slope Amount", .description = "How much of the gradient magnitude the assumed slope replaces.", .min = 0, .max = 1, .advanced = true },
    .erosion_fade_slope = .{ .label = "Erosion Fade Slope", .description = "Terrain slope magnitude at which the gullies apply in full; flatter ground's erosion fades out so peaks and stream beds are preserved. 0 disables the fade.", .min = 0.0, .max = 1.0, .advanced = true },
    .erosion_fade_altitude = .{ .skip = true },
    .erosion_interp = .{ .label = "Erosion Resolution", .description = "Sampling density of the erosion height deltas; coarser is faster and smoother. Full disables interpolation." },
    .surface_noise_amplitude = .{ .label = "Surface Noise Amplitude", .description = "Maximum height delta of the surface noise layered on after erosion, in normalized units.", .min = 0.0, .max = 0.5 },
    .surface_noise_gradient_influence = .{ .label = "Surface Noise Gradient Influence", .description = "How much the pre-erosion terrain gradient scales the applied amount; 0 applies it everywhere, 1 only in proportion to the gradient.", .min = 0, .max = 1 },
    .surface_noise_gradient_scale = .{ .label = "Surface Noise Gradient Scale", .description = "Pre-erosion gradient magnitude at which the surface noise applies in full.", .min = 0, .max = 1, .advanced = true },
    .surface_interp = .{ .label = "Surface Noise Resolution", .description = "Sampling density of the surface detail noise; coarser is faster and smoother. Full disables interpolation." },
    .terrain_noise_balance = .{ .label = "Terrain Noise Balance", .min = 0, .max = 1 },
    .terrain_interp = .{ .label = "Terrain Detail Resolution", .description = "Sampling density of the mountain noise; warp and noise share the coarse lattice. Full disables interpolation." },
    .large_terrain_interp = .{ .label = "Continental Resolution", .description = "Sampling density of the continental noise; the large warp follows this setting. Full disables interpolation." },
    .height_power = .{ .label = "Height Power", .min = 0.25, .max = 4 },
    .large_power = .{ .label = "Large Shape Power", .min = 0.25, .max = 8 },
    .small_power = .{ .label = "Detail Power", .min = 0.25, .max = 8 },
    .cave_threshold = .{ .label = "Cave Threshold", .min = -100, .max = 100, .advanced = true },
    .cave_expansion_max = .{ .label = "Cave Expansion Maximum", .min = 0, .max = 20000, .advanced = true },
    .cave_expansion_start = .{ .label = "Cave Expansion Start", .min = 0, .max = 20000, .advanced = true },
    .cave_interp_h = .{ .label = "Cave Horizontal Resolution", .description = "Horizontal (X/Z) sampling density of the cave noise grid.", .advanced = true },
    .cave_interp_v = .{ .label = "Cave Vertical Resolution", .description = "Vertical (Y) sampling density of the cave noise grid; combine with horizontal for grids like 4x8x4.", .advanced = true },
    .gen_structures = .{ .label = "Generate Structures" },
    .dirt_depth = .{ .min = 1, .max = 32 },
    .snow_line = .{ .min = 0, .max = 1 },
    .beach_band = .{ .min = 0, .max = 256 },
    .sand_slope = .{ .min = 0, .max = 4 },
    .sand_slope_falloff = .{ .label = "Sand Slope Falloff", .description = "Beach elevation lost per unit slope, in blocks. Steep shores get narrower beaches.", .min = 0, .max = 256 },
    .sea_floor_rock_slope = .{ .label = "Sea Floor Rock Slope", .description = "Slope above which the underwater floor is stone instead of sand.", .min = 0, .max = 2 },
    .grass_height_falloff = .{ .label = "Grass Height Falloff", .description = "How much the grass slope limit drops per unit of altitude above the base. High meadows turn rocky sooner.", .min = 0, .max = 4 },
    .dirt_height_falloff = .{ .label = "Dirt Height Falloff", .description = "How much the dirt band narrows per unit of altitude above the base.", .min = 0, .max = 2 },
    .ground_altitude_base = .{ .label = "Ground Altitude Base", .description = "Normalized altitude where the grass and dirt falloffs start. Below this the lowland thresholds apply in full.", .min = -1, .max = 1 },
    .snow_slope_gain = .{ .label = "Snow Slope Gain", .description = "How much the snow line rises per unit slope. Steep faces need more altitude to hold snow.", .min = 0, .max = 2 },
    .snow_cliff_slope = .{ .label = "Snow Cliff Slope", .description = "Slope at or above which high ground sheds snow and dirt to bare stone.", .min = 0, .max = 4 },
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
    .default,
};
const terrain_preset_names = [_][]const u8{ "Continental", "Sculpted", "Plain" };
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

fn instanceDeinit(source: World.ChunkSource, _: std.Io, allocator: std.mem.Allocator, _: *World) void {
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

fn benchTerrainHeights(io: std.Io, params: *const DefaultGenerator.Params, label: []const u8) void {
    const iterations = if (@import("builtin").mode == .Debug) 50 else 500;
    var sink: f32 = 0;
    var height: [ChunkSize][ChunkSize]f32 = undefined;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |i| {
        height = DefaultGenerator.genTerrainHeight(params, @as(i32, @intCast(@mod(i, 3))) - 1, .{ 3, 5 });
        sink += height[0][0];
    }
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    const ns = @as(f64, @floatFromInt(start.durationTo(end).raw.toNanoseconds())) / @as(f64, @floatFromInt(iterations));
    std.debug.print("genTerrainHeight {s} {s}: {d:.1} ns/call (sink {d})\n", .{ @tagName(@import("builtin").mode), label, ns, sink });
}

test "benchmark genTerrainHeight" {
    const params = DefaultGenerator.Params.default;
    benchTerrainHeights(std.testing.io, &params, "erosion");
    var plain = params;
    plain.erosion_enabled = false;
    benchTerrainHeights(std.testing.io, &plain, "base");
    inline for ([_]DefaultGenerator.InterpResolution{ .half, .quarter, .eighth, .sixteenth }) |d| {
        var coarse = params;
        coarse.terrain_interp = d;
        coarse.large_terrain_interp = d;
        coarse.surface_interp = d;
        coarse.erosion_interp = d;
        var label_buf: [16]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "interp-{s}", .{@tagName(d)});
        benchTerrainHeights(std.testing.io, &coarse, label);
    }
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
    try std.testing.expectEqual(@as(u32, 5), params.erosion_octaves);
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
    try std.testing.expectEqual(DefaultGenerator.Params.default.erosion_fade_slope, params.erosion_fade_slope);
    try std.testing.expectEqual(DefaultGenerator.Params.default.erosion_fade_altitude, params.erosion_fade_altitude);
    try std.testing.expectEqual(DefaultGenerator.Params.default.terrain_scale, params.terrain_scale);
}

/// Pins border continuity between two adjacent chunks: the jump across the
/// border must stay within a few local steps. A coordinate-space bug jumps
/// by thousands of blocks instead.
fn expectSeamContinuous(west: [ChunkSize][ChunkSize]f32, east: [ChunkSize][ChunkSize]f32) !void {
    for (0..ChunkSize) |z| {
        const jump = @abs(west[ChunkSize - 1][z] - east[0][z]);
        // Neighboring samples on the same side of the border bound the local
        // slope, but the gully ripple can double it at a steep phase, so the
        // jump may reach a few times the local step.
        const step_w = @abs(west[ChunkSize - 1][z] - west[ChunkSize - 2][z]);
        const step_e = @abs(east[1][z] - east[0][z]);
        try std.testing.expect(jump <= (step_w + step_e) * 2.5 + 256.0);
    }
}

test "erosion seam continuity between adjacent chunks" {
    // The erosion filter evaluates every point from world coordinates alone,
    // so the height field stays continuous across chunk borders. This pins
    // the fix for the removed getDifferential stage, which reflected the last
    // row/column and distorted the final row of every chunk.
    const params = DefaultGenerator.Params.default;
    const west = DefaultGenerator.genTerrainHeight(&params, 0, .{ 0, 0 });
    const east = DefaultGenerator.genTerrainHeight(&params, 0, .{ 1, 0 });
    try expectSeamContinuous(west, east);
}

test "surface noise amount follows the pre-erosion gradient" {
    // Gradient influence 1 scales the amount by the normalized gradient:
    // flat ground gets none, a gradient at the scale gets the full amount.
    var params = DefaultGenerator.Params.default;
    params.surface_noise_gradient_scale = 0.01;
    params.surface_noise_amplitude = 0.5;
    params.surface_noise_gradient_influence = 1.0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), DefaultGenerator.surfaceNoiseAmount(0.0, &params), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), DefaultGenerator.surfaceNoiseAmount(0.005, &params), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), DefaultGenerator.surfaceNoiseAmount(0.01, &params), 1e-5);
    // Influence 0 keeps the amount uniform regardless of the gradient.
    params.surface_noise_gradient_influence = 0.0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), DefaultGenerator.surfaceNoiseAmount(0.0, &params), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), DefaultGenerator.surfaceNoiseAmount(1.0, &params), 1e-6);
}

test "surface noise stays seamless across adjacent chunks" {
    // The surface noise samples world coordinates alone, so the extra
    // roughness adds the same amount on both sides of a chunk border.
    var params = DefaultGenerator.Params.default;
    params.erosion_enabled = false;
    params.surface_noise_amplitude = 0.05;
    params.surface_noise_gradient_influence = 1.0;
    const west = DefaultGenerator.genTerrainHeight(&params, 0, .{ 0, 0 });
    const east = DefaultGenerator.genTerrainHeight(&params, 0, .{ 1, 0 });
    try expectSeamContinuous(west, east);
}

test "surface noise relief stays within the symmetric bound" {
    // Surface detail flows through composeErodedHeight with the symmetric
    // maximum (see "eroded height stays continuous across the shoreline"),
    // so its relief is identical on land and under water. This pins the
    // magnitude end to end: no sample may gain more than the normalized
    // amplitude converted with that envelope.
    var params = DefaultGenerator.Params.default;
    params.erosion_enabled = false;
    params.surface_noise_amplitude = 0.05;
    params.surface_noise_gradient_influence = 0.0;
    const scale = params.terrain_scale / World.ChunkPos.toScale(0);
    const max_bound: f32 = @floatFromInt(@max(@abs(params.terrain_min), @abs(params.terrain_max)));
    const rough = DefaultGenerator.genTerrainHeight(&params, 0, .{ 3, 5 });
    params.surface_noise_amplitude = 0.0;
    const base = DefaultGenerator.genTerrainHeight(&params, 0, .{ 3, 5 });
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |z| {
            try std.testing.expect(@abs(rough[x][z] - base[x][z]) <= 0.05 * max_bound * scale * 2.0 + 0.5);
        }
    }
}

test "eroded height stays continuous across the shoreline" {
    // The envelope switches sides at shaped == 0; the erosion delta must not
    // switch with it, or every gully crossing the sea would end in a cliff.
    const bounds: [2]f32 = .{ -4096, 8196 };
    const up = DefaultGenerator.composeErodedHeight(1e-6, 0.2, .{ .bounds = bounds, .max = 8196, .scale = 1.0 });
    const down = DefaultGenerator.composeErodedHeight(-1e-6, 0.2, .{ .bounds = bounds, .max = 8196, .scale = 1.0 });
    try std.testing.expect(@abs(up - down) < 1.0);
    // The delta keeps full relief below the sea, matching the land side.
    const deep = DefaultGenerator.composeErodedHeight(-0.5, 0.2, .{ .bounds = bounds, .max = 8196, .scale = 1.0 });
    try std.testing.expectApproxEqAbs(-0.5 * 4096 + 0.2 * 8196, deep, 1e-3);
}

test "erosion LOD consistency between level 0 and level 1" {
    // Coarser levels drop the finest octave, so a level-1 chunk must match
    // the box-filtered level-0 field up to the dropped octave's amplitude.
    const params = DefaultGenerator.Params.default;
    const coarse = DefaultGenerator.genTerrainHeight(&params, 1, .{ 1, 1 });
    var fine: [4][ChunkSize][ChunkSize]f32 = undefined;
    fine[0] = DefaultGenerator.genTerrainHeight(&params, 0, .{ 2, 2 });
    fine[1] = DefaultGenerator.genTerrainHeight(&params, 0, .{ 3, 2 });
    fine[2] = DefaultGenerator.genTerrainHeight(&params, 0, .{ 2, 3 });
    fine[3] = DefaultGenerator.genTerrainHeight(&params, 0, .{ 3, 3 });
    const max_abs_bound: f32 = @floatFromInt(@max(@abs(params.terrain_min), @abs(params.terrain_max)));
    // The dropped octave plus the coarser gradient sampling shift the gullies
    // slightly; allow 40% of the filter's total magnitude plus fixed slack,
    // far below what a coordinate or unit bug would produce.
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

test "interp resolution sizes follow chunk size" {
    try std.testing.expectEqual(@as(usize, ChunkSize), DefaultGenerator.InterpResolution.full.size());
    try std.testing.expectEqual(@as(usize, ChunkSize / 2), DefaultGenerator.InterpResolution.half.size());
    try std.testing.expectEqual(@as(usize, ChunkSize / 4), DefaultGenerator.InterpResolution.quarter.size());
    try std.testing.expectEqual(@as(usize, ChunkSize / 8), DefaultGenerator.InterpResolution.eighth.size());
    try std.testing.expectEqual(@as(usize, ChunkSize / 16), DefaultGenerator.InterpResolution.sixteenth.size());
}

fn heightsAtInterpDensity(d: DefaultGenerator.InterpResolution, chunk_pos: [2]i32) [ChunkSize][ChunkSize]f32 {
    var params = DefaultGenerator.Params.default;
    params.terrain_interp = d;
    params.large_terrain_interp = d;
    params.surface_interp = d;
    params.erosion_interp = d;
    return DefaultGenerator.genTerrainHeight(&params, 0, chunk_pos);
}

test "coarse interp densities stay finite and seamless" {
    // Every density evaluates from world coordinates alone, so borders stay
    // continuous; the error against full-res stays far below the envelope,
    // where a lattice origin bug would land.
    const full = heightsAtInterpDensity(.full, .{ 3, 5 });
    const max_abs_bound: f32 = @floatFromInt(@max(@abs(DefaultGenerator.Params.default.terrain_min), @abs(DefaultGenerator.Params.default.terrain_max)));
    inline for ([_]DefaultGenerator.InterpResolution{ .half, .quarter, .eighth, .sixteenth }) |d| {
        const coarse = heightsAtInterpDensity(d, .{ 3, 5 });
        const neighbor = heightsAtInterpDensity(d, .{ 4, 5 });
        var max_diff: f32 = 0;
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |z| {
                try std.testing.expect(std.math.isFinite(coarse[x][z]));
                max_diff = @max(max_diff, @abs(coarse[x][z] - full[x][z]));
            }
        }
        try expectSeamContinuous(coarse, neighbor);
        try std.testing.expect(max_diff <= max_abs_bound);
    }
}

test "cave densities carve without crashing" {
    // Every H/V combination only ever replaces stone with air; a high
    // threshold forces carving so the write path runs everywhere.
    var params = DefaultGenerator.Params.default;
    params.cave_threshold = 10.0;
    inline for ([_][2]DefaultGenerator.InterpResolution{
        .{ .eighth, .eighth },
        .{ .quarter, .eighth },
        .{ .eighth, .quarter },
        .{ .half, .half },
        .{ .full, .full },
    }) |combo| {
        params.cave_interp_h = combo[0];
        params.cave_interp_v = combo[1];
        var blocks: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.stone)));
        DefaultGenerator.sampleCavesInterpolate(combo[0].size(), combo[1].size(), &blocks, .{ .level = 0, .position = .{ 0, 0, 0 } }, 1.0, &params);
        var carved: usize = 0;
        for (blocks) |plane| {
            for (plane) |row| {
                for (row) |b| {
                    try std.testing.expect(b == .stone or b == .air);
                    carved += @intFromBool(b == .air);
                }
            }
        }
        try std.testing.expect(carved > 0);
    }
}

test "interp densities round trip through the config tree" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var params = DefaultGenerator.Params.default;
    params.terrain_interp = .quarter;
    params.large_terrain_interp = .eighth;
    params.surface_interp = .half;
    params.erosion_interp = .quarter;
    params.cave_interp_h = .half;
    params.cave_interp_v = .quarter;
    const tree = try generator_api.fromStruct(DefaultGenerator.Params, allocator, &params, field_specs);
    defer generator_api.free(allocator, tree);

    var restored = DefaultGenerator.Params.default;
    restored.trees = &.{};
    try generator_api.fromTree(DefaultGenerator.Params, arena.allocator(), tree, &restored, field_specs);
    try std.testing.expectEqual(DefaultGenerator.InterpResolution.quarter, restored.terrain_interp);
    try std.testing.expectEqual(DefaultGenerator.InterpResolution.eighth, restored.large_terrain_interp);
    try std.testing.expectEqual(DefaultGenerator.InterpResolution.half, restored.surface_interp);
    try std.testing.expectEqual(DefaultGenerator.InterpResolution.quarter, restored.erosion_interp);
    try std.testing.expectEqual(DefaultGenerator.InterpResolution.half, restored.cave_interp_h);
    try std.testing.expectEqual(DefaultGenerator.InterpResolution.quarter, restored.cave_interp_v);
    // Untouched fields keep their declaration defaults.
    try std.testing.expectEqual(DefaultGenerator.InterpResolution.full, DefaultGenerator.Params.default.terrain_interp);
    try std.testing.expectEqual(DefaultGenerator.InterpResolution.eighth, DefaultGenerator.Params.default.cave_interp_h);
    try std.testing.expectEqual(DefaultGenerator.InterpResolution.eighth, DefaultGenerator.Params.default.cave_interp_v);
}

fn testGroundContext(overrides: anytype) DefaultGenerator.GroundContext {
    const p = DefaultGenerator.Params.default;
    var ctx: DefaultGenerator.GroundContext = .{
        .block_height = 20,
        .sea_level = p.sea_level,
        .block_randomness = 0,
        .one_d_terrain_scale = 1,
        .slope = 0,
        .slope_randomness = 0,
        .ground_threshold = p.ground_threshold,
        .dirt_band = p.dirt_band,
        .snow_line = p.snow_line,
        .beach_band_blocks = p.beach_band,
        .sand_slope = p.sand_slope,
        .sand_slope_falloff_blocks = p.sand_slope_falloff,
        .sea_floor_rock_slope = p.sea_floor_rock_slope,
        .grass_height_falloff = p.grass_height_falloff,
        .dirt_height_falloff = p.dirt_height_falloff,
        .ground_altitude_base = p.ground_altitude_base,
        .snow_slope_gain = p.snow_slope_gain,
        .snow_cliff_slope = p.snow_cliff_slope,
    };
    inline for (std.meta.fields(@TypeOf(overrides))) |field| {
        @field(ctx, field.name) = @field(overrides, field.name);
    }
    return ctx;
}

fn testGround(height_percent: f32, ctx: DefaultGenerator.GroundContext) Block {
    var rng = std.Random.DefaultPrng.init(1);
    var rand = rng.random();
    return DefaultGenerator.randGround(&rand, height_percent, ctx);
}

test "sand beach tapers with slope" {
    // Beaches taper with slope: the same elevation is sand on flat ground but
    // grass on a slope, and dirt higher up. Low shores stay sand when steep.
    try std.testing.expectEqual(Block.sand, testGround(0, testGroundContext(.{ .block_height = 5, .slope = 0.0 })));
    try std.testing.expectEqual(Block.grass, testGround(0, testGroundContext(.{ .block_height = 5, .slope = 0.29 })));
    try std.testing.expectEqual(Block.dirt, testGround(0.3, testGroundContext(.{ .block_height = 5, .slope = 0.29 })));
    try std.testing.expectEqual(Block.sand, testGround(0, testGroundContext(.{ .block_height = 2, .slope = 0.29 })));
    try std.testing.expectEqual(Block.sand, testGround(0, testGroundContext(.{ .block_height = 6, .slope = 0.0 })));
}

test "grass threshold drops with altitude" {
    // Gentle high meadow turns to dirt while the same slope stays grass down low.
    try std.testing.expectEqual(Block.grass, testGround(0, testGroundContext(.{ .slope = 0.25 })));
    try std.testing.expectEqual(Block.dirt, testGround(0.4, testGroundContext(.{ .slope = 0.25 })));
}

test "dirt band narrows with altitude" {
    try std.testing.expectEqual(Block.dirt, testGround(0, testGroundContext(.{ .slope = 0.4 })));
    try std.testing.expectEqual(Block.stone, testGround(0.5, testGroundContext(.{ .slope = 0.4 })));
}

test "snow line rises with slope" {
    var ctx = testGroundContext(.{ .grass_height_falloff = 0.0, .dirt_height_falloff = 0.0 });
    ctx.slope = 0.0;
    try std.testing.expectEqual(Block.snow, testGround(0.65, ctx));
    ctx.slope = 0.2;
    try std.testing.expectEqual(Block.grass, testGround(0.65, ctx));
}

test "high cliffs shed to stone" {
    var ctx = testGroundContext(.{ .grass_height_falloff = 0.0, .dirt_height_falloff = 0.0 });
    ctx.slope = 0.1;
    try std.testing.expectEqual(Block.snow, testGround(0.8, ctx));
    ctx.slope = 1.2;
    try std.testing.expectEqual(Block.stone, testGround(0.8, ctx));
}

test "underwater floor is rock when steep" {
    try std.testing.expectEqual(Block.sand, testGround(0, testGroundContext(.{ .block_height = -5, .slope = 0.0 })));
    try std.testing.expectEqual(Block.stone, testGround(0, testGroundContext(.{ .block_height = -5, .slope = 1.0 })));
}

test "zero couplings reproduce the flat thresholds" {
    var ctx = testGroundContext(.{ .sand_slope_falloff_blocks = 0.0, .grass_height_falloff = 0.0, .dirt_height_falloff = 0.0, .snow_slope_gain = 0.0, .snow_cliff_slope = 10.0, .sea_floor_rock_slope = 10.0 });
    ctx.slope = 0.25;
    try std.testing.expectEqual(Block.grass, testGround(0, ctx));
    ctx.slope = 0.4;
    try std.testing.expectEqual(Block.dirt, testGround(0, ctx));
    ctx.slope = 0.9;
    try std.testing.expectEqual(Block.stone, testGround(0, ctx));
    ctx.slope = 1.0;
    ctx.block_height = -5;
    try std.testing.expectEqual(Block.sand, testGround(0, ctx));
}
