const std = @import("std");
const builtin = @import("builtin");

const tracy = @import("tracy");

const Cache = @import("../../libs/Cache.zig").Cache;
const Block = @import("../Block.zig").Block;
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
    const sample_step = 1.0 / @as(comptime_float, ChunkSize);
    const FloatV = @Vector(ChunkSize, f32);

    /// Sampling density for noise interpolators; coarser densities evaluate on a border-shared lattice and interpolate up.
    pub const InterpResolution = enum {
        full,
        half,
        quarter,
        eighth,
        sixteenth,

        pub fn size(self: InterpResolution) usize {
            return @as(usize, ChunkSize) >> @backingInt(self);
        }
    };

    /// Height field the grass detail slope reads: cached level-0 parent or this chunk's own fine level.
    pub const GrassDetailGradient = enum {
        parent,
        fine,
    };

    /// Asymmetric height bounds plus the symmetric maximum normalized deltas convert with.
    const Envelope = struct {
        bounds: [2]f32,
        max: f32,
        scale: f32,

        fn init(params: *const Params, scale: f32) Envelope {
            const min: f32 = @floatFromInt(params.terrain_min);
            const max: f32 = @floatFromInt(params.terrain_max);
            return .{ .bounds = .{ min, max }, .max = @max(@abs(min), @abs(max)), .scale = scale };
        }
    };

    /// Shared height-pipeline coordinates so helpers take one context instead of six scalars.
    const HeightCtx = struct {
        params: *const Params,
        level: i32,
        pos: [2]f32,
        one_d_scale: f32,
        env: Envelope,

        fn init(params: *const Params, level: i32, chunk_pos: [2]i32) HeightCtx {
            const scale = @max(params.terrain_scale, 1e-6) / World.ChunkPos.toScale(level);
            return .{
                .params = params,
                .level = level,
                .pos = .{ @floatFromInt(chunk_pos[0]), @floatFromInt(chunk_pos[1]) },
                .one_d_scale = 1.0 / scale,
                .env = .init(params, scale),
            };
        }
    };

    params: Params,
    seed: u64,
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

    pub fn init(allocator: std.mem.Allocator, max_cache_bytes: usize, params: Params, seed: u64) !DefaultGenerator {
        const terrain_height_cache_size = @max(std.math.floorPowerOfTwo(u64, max_cache_bytes / @sizeOf(ChunkHeightsValue)), 256 * thc_fragments);
        std.log.info("Creating terrain height cache with size {d} ({d} bytes)", .{ terrain_height_cache_size, terrain_height_cache_size * @sizeOf(ChunkHeightsValue) });
        return DefaultGenerator{
            .terrain_height_cache = try .init(allocator, terrain_height_cache_size, .{ .name = "terrain_height_cache" }),
            .params = params,
            .seed = seed,
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
        /// The host fills a null seed before create; every noise seed derives from it.
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
        /// Slope for full gullies; flatter ground fades out so peaks and stream beds survive. Zero disables the fade.
        erosion_fade_slope: f32 = 0.093972616,
        /// Deprecated: kept so saved configs that set it still parse. Skipped in the config tree.
        erosion_fade_altitude: f32 = 0.5,
        /// Sampling density of the erosion delta lattice; coarse runs the filter on decimated inputs and interpolates up.
        erosion_interp: InterpResolution = .full,
        /// High-frequency noise applied after erosion; its amount follows the pre-erosion gradient so detail collects on slopes.
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
        /// Beach elevation lost per unit slope; steep shores get narrower beaches and cliffs meet water with stone.
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
        grass_detail_gradient_source: GrassDetailGradient = .parent,
        /// Slope keeping full grass-blade hash height, fading to nothing on flat ground. Zero disables the fade.
        grass_detail_slope_scale: f32 = 0.5,
        /// Sampling density of the grass slope lattice; coarser is faster
        /// and smoother. Full disables interpolation.
        grass_detail_gradient_interp: InterpResolution = .quarter,
        /// How much the snow line rises per unit slope. Steep faces need more
        /// altitude to hold snow.
        snow_slope_gain: f32 = 0.35,
        /// Slope at or above which high ground sheds snow to bare stone.
        snow_cliff_slope: f32 = 1.0,
        /// Crossfades the continental noise (0) into the mountain (ridged) noise (1).
        terrain_noise_balance: f32 = 0.5,
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

        /// Mixes the world seed into every noise seed, so configured noise seeds still vary the result.
        pub fn setSeeds(self: *Params, seed: u64) void {
            // Salts differentiate the noise streams; the large warp shares salt 4 with the large height noise.
            const noise_salts = .{ 1, 3, 4, 4, 6 };
            inline for (.{ &self.cave_noise, &self.terrain_noise, &self.large_terrain_noise, &self.large_terrain_noise_warp, &self.surface_noise }, noise_salts) |noise, salt| {
                noise.seed ^= @bitCast(std.hash.Murmur2_32.hashUint64(seed +% salt));
            }
        }

        /// Default parameters; declaration defaults let older configs missing new fields still parse.
        pub const default = Params{};

        /// ErosionParams for the given LOD; coarser levels drop finest octaves whose wavelength falls below their spacing.
        fn erosionFilterParams(self: *const Params, level: i32) erosion.ErosionParams {
            if (self.erosion_detail <= 0) std.log.warn("erosion: detail {d} <= 0; clamping", .{self.erosion_detail});
            const drop: u32 = @intCast(@max(level, 0));
            return .{
                .filter_strength = self.erosion_filter_strength,
                .gully_weight = self.erosion_gully_weight,
                .detail = @max(self.erosion_detail, erosion.min_detail),
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
        // Cull against the scaled world height since terrain_scale stretches the envelope.
        const max_global_y: i64 = @round(@as(f32, @floatFromInt(self.params.terrain_max)) * self.params.terrain_scale);
        const min_global_y: i64 = @round(@as(f32, @floatFromInt(self.params.terrain_min)) * self.params.terrain_scale);
        if (chunk_pos.position[1] > ChunkPos.fromGlobalBlockPos(.{ 0, max_global_y, 0 }, chunk_pos.level).position[1]) {
            blocks.merge(.{ .uniform = .air }, grid_buffer);
            return;
        }
        // generateTerrain overwrites every voxel; Debug prefills .null so partial writes trip the assert below.
        var block_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = undefined;
        if (builtin.mode == .debug) block_grid = @splat(@splat(@splat(.null)));
        if (chunk_pos.position[1] < ChunkPos.fromGlobalBlockPos(.{ 0, min_global_y, 0 }, chunk_pos.level).position[1]) {
            block_grid = @splat(@splat(@splat(.stone)));
        } else {
            var rng = std.Random.DefaultPrng.init(self.seed +% @as(u64, @truncate(@as(u96, @bitCast(chunk_pos.position)))));
            var rand = rng.random();
            const heights = try self.getTerrainHeight(io, [2]i32{ chunk_pos.position[0], chunk_pos.position[2] }, chunk_pos.level);
            const gen_terrain_zone = tracy.Zone.begin(.{ .src = @src(), .name = "GenTerrainBlocks" });
            generateTerrain(&block_grid, chunk_pos, heights, .{ .params = &self.params, .rand = &rand, .chunk_scale = chunk_scale_factor });
            gen_terrain_zone.end();
            if (builtin.mode == .debug) {
                for (&block_grid) |*plane| {
                    for (plane) |*column| {
                        for (column) |*cell| std.debug.assert(cell.* != .null);
                    }
                }
            }
            if (Chunk.getUniform(&block_grid) == Block.air) {
                blocks.merge(.{ .uniform = .air }, grid_buffer);
                return;
            }
        }
        generateCavesInterpolate(&block_grid, chunk_pos, chunk_scale_factor, &self.params);
        if (chunk_pos.level == World.standard_level) try stampFineGrass(io, allocator, world, chunk_pos, &block_grid);
        const one_block = Chunk.getUniform(&block_grid);
        if (one_block) |block| {
            blocks.merge(.{ .uniform = block }, grid_buffer);
        } else blocks.merge(.{ .grid = &block_grid }, grid_buffer);
    }

    /// Stamps air above grass/dirt with invisible fine_grass markers. The bottom row reads through the world so boundary-straddling surfaces are covered.
    fn stampFineGrass(io: std.Io, allocator: std.mem.Allocator, world: *World, chunk_pos: ChunkPos, block_grid: *[ChunkSize][ChunkSize][ChunkSize]Block) !void {
        var reader = World.Reader{ .world = world };
        defer reader.clear(io);
        const base: World.BlockPos = chunk_pos.toLocalBlockPos();
        for (block_grid, 0..) |*plane, x| {
            for (plane, 0..) |*column, y| {
                for (column, 0..) |*cell, z| {
                    if (cell.* != .air) continue;
                    if (y > 0) {
                        const below = block_grid[x][y - 1][z];
                        if (below != .grass and below != .dirt) continue;
                    } else {
                        const below = try reader.getBlock(io, allocator, .{ base[0] + @as(i64, @intCast(x)), base[1] - 1, base[2] + @as(i64, @intCast(z)) }, World.standard_level);
                        if (below != .grass and below != .dirt) continue;
                    }
                    cell.* = .fine_grass;
                }
            }
        }
    }

    /// Grows alternating blades where level 0 stamped fine_grass. Every detail level reads level 0 directly so all LODs align; parent columns are read once and fanned out.
    fn genDetailTest(self: *DefaultGenerator, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, blocks: *Chunk.Encoding, world: *World, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) !void {
        if (chunk_pos.level >= World.standard_level or chunk_pos.level <= -60) return;
        // Integer math keeps the block mapping bit-exact where f64 would round.
        const fine_per_block: i64 = @as(i64, 1) << @as(u6, @intCast(-chunk_pos.level));
        const base: World.BlockPos = chunk_pos.toLocalBlockPos();
        const block_min: World.BlockPos = @divFloor(base, @as(World.BlockPos, @splat(fine_per_block)));
        const block_max: World.BlockPos = @divFloor(base + @as(World.BlockPos, @splat(ChunkSize - 1)), @as(World.BlockPos, @splat(fine_per_block)));
        var reader = World.Reader{ .world = world };
        defer reader.clear(io);
        var detail_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.null)));
        const slope_scale = self.params.grass_detail_slope_scale;
        const slope_interp = self.params.grass_detail_gradient_interp;
        var level_slopes = LevelSlopes{ .generator = self, .io = io, .interp = slope_interp };
        // Hoisted so `fine` can point at it past the block below; left undefined (never read) when the branch is not taken.
        var fine_slopes: [ChunkSize][ChunkSize]f32 = undefined;
        const fine: ?*const [ChunkSize][ChunkSize]f32 = blk: {
            if (self.params.grass_detail_gradient_source != .fine) break :blk null;
            fine_slopes = try self.fineDetailSlopes(io, chunk_pos, slope_interp);
            for (&fine_slopes) |*row| {
                for (row) |*slope| slope.* = bladeHeightScale(slope.*, slope_scale);
            }
            break :blk &fine_slopes;
        };
        try fanBladeColumns(&reader, io, allocator, .{ .detail_grid = &detail_grid, .base = base, .fine_per_block = fine_per_block }, block_min, block_max, fine, &level_slopes, slope_scale, blocks, grid_buffer);
    }

    /// Fans stamped level-0 columns out to fine voxels, scaling per-voxel from the fine grid when present,
    /// then merges the result: air when nothing was stamped, else the detail grid.
    fn fanBladeColumns(reader: *World.Reader, io: std.Io, allocator: std.mem.Allocator, batch: BladeBatch, block_min: World.BlockPos, block_max: World.BlockPos, fine: ?*const [ChunkSize][ChunkSize]f32, parent_slopes: *LevelSlopes, slope_scale: f32, blocks: *Chunk.Encoding, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) !void {
        var any_filled = false;
        var block_x = block_min[0];
        while (block_x <= block_max[0]) : (block_x += 1) {
            var block_z = block_min[2];
            while (block_z <= block_max[2]) : (block_z += 1) {
                var layers: [ChunkSize + 1]i64 = undefined;
                const layer_count = try surfaceLayers(reader, io, allocator, block_x, block_min[1], block_max[1], block_z, &layers);
                if (layer_count == 0) continue;
                const scale: BladeScale = if (fine) |grid| .{ .fine = grid } else .{ .uniform = bladeHeightScale(try parent_slopes.slopeAt(block_x, block_z), slope_scale) };
                if (fillBlades(batch, .{ .block_x = block_x, .block_z = block_z, .layers = layers[0..layer_count], .scale = scale })) any_filled = true;
            }
        }
        if (!any_filled) {
            // Air skips meshing directly while null pays the face-extraction round-trip.
            blocks.merge(.{ .uniform = .air }, grid_buffer);
            return;
        }
        blocks.merge(.{ .grid = @alignCast(batch.detail_grid) }, grid_buffer);
    }

    /// Slope grid at this chunk's own level; runs the height pipeline on the lattice and bypasses the height cache.
    fn fineDetailSlopes(self: *DefaultGenerator, io: std.Io, chunk_pos: ChunkPos, interp: InterpResolution) ![ChunkSize][ChunkSize]f32 {
        if (interp == .full) {
            const heights = try self.getTerrainHeight(io, .{ chunk_pos.position[0], chunk_pos.position[2] }, chunk_pos.level);
            return grassSlopes(&heights, interp);
        }
        var density_params = self.params;
        density_params.terrain_interp = interp;
        density_params.large_terrain_interp = interp;
        density_params.surface_interp = interp;
        density_params.erosion_interp = interp;
        const heights = genTerrainHeight(&density_params, chunk_pos.level, .{ chunk_pos.position[0], chunk_pos.position[2] });
        return grassSlopes(&heights, interp);
    }

    /// Collects stamped level-0 block heights in one column, reading level 0 directly.
    fn surfaceLayers(reader: *World.Reader, io: std.Io, allocator: std.mem.Allocator, block_x: i64, block_min_y: i64, block_max_y: i64, block_z: i64, layers: *[ChunkSize + 1]i64) !usize {
        var layer_count: usize = 0;
        var block_y = block_min_y;
        while (block_y <= block_max_y) : (block_y += 1) {
            const current = try reader.getBlock(io, allocator, .{ block_x, block_y, block_z }, World.standard_level);
            if (current == .fine_grass) {
                layers[layer_count] = block_y;
                layer_count += 1;
            }
        }
        return layer_count;
    }

    /// Lazily fetched level-0 slope grids; at most four overlap one detail chunk.
    const LevelSlopes = struct {
        generator: *DefaultGenerator,
        io: std.Io,
        interp: InterpResolution,
        keys: [4][2]i32 = undefined,
        grids: [4][ChunkSize][ChunkSize]f32 = undefined,
        count: usize = 0,

        fn slopeAt(self: *LevelSlopes, block_x: i64, block_z: i64) !f32 {
            const chunk: [2]i32 = .{ @intCast(@divFloor(block_x, ChunkSize)), @intCast(@divFloor(block_z, ChunkSize)) };
            for (self.keys[0..self.count], self.grids[0..self.count]) |key, *grid| {
                if (key[0] == chunk[0] and key[1] == chunk[1]) return gridAt(grid, block_x, block_z);
            }
            const heights = try self.generator.getTerrainHeight(self.io, chunk, World.standard_level);
            const slot = if (self.count < self.keys.len) self.count else 0;
            self.keys[slot] = chunk;
            self.grids[slot] = grassSlopes(&heights, self.interp);
            self.count = @min(self.count + 1, self.keys.len);
            return gridAt(&self.grids[slot], block_x, block_z);
        }

        fn gridAt(grid: *const [ChunkSize][ChunkSize]f32, block_x: i64, block_z: i64) f32 {
            const local_x: usize = @intCast(@mod(block_x, ChunkSize));
            const local_z: usize = @intCast(@mod(block_z, ChunkSize));
            return grid[local_x][local_z];
        }
    };

    /// Blade height fraction kept on the given slope; flat grows nothing and non-positive scales disable the fade.
    fn bladeHeightScale(slope: f32, slope_scale: f32) f32 {
        if (slope_scale <= 0) return 1;
        if (slope <= 0) return 0;
        return @min(slope / slope_scale, 1);
    }

    const BladeBatch = struct {
        detail_grid: *[ChunkSize][ChunkSize][ChunkSize]Block,
        base: World.BlockPos,
        fine_per_block: i64,
    };

    /// Blade height scale: per fine voxel from this level's slope grid, or one value from the parent column.
    const BladeScale = union(enum) {
        fine: *const [ChunkSize][ChunkSize]f32,
        uniform: f32,
    };

    const BladeColumn = struct {
        block_x: i64,
        block_z: i64,
        layers: []const i64,
        scale: BladeScale,
    };

    /// Fans one column's stamped layers to fine voxels; blades sit on alternating voxels at slope-scaled hash heights.
    fn fillBlades(batch: BladeBatch, column: BladeColumn) bool {
        const fine_lo_x = @max(column.block_x * batch.fine_per_block, batch.base[0]);
        const fine_hi_x = @min(column.block_x * batch.fine_per_block + batch.fine_per_block - 1, batch.base[0] + ChunkSize - 1);
        const fine_lo_z = @max(column.block_z * batch.fine_per_block, batch.base[2]);
        const fine_hi_z = @min(column.block_z * batch.fine_per_block + batch.fine_per_block - 1, batch.base[2] + ChunkSize - 1);
        var layer_los: [ChunkSize + 1]i64 = undefined;
        var layer_caps: [ChunkSize + 1]i64 = undefined;
        var layer_bases: [ChunkSize + 1]i64 = undefined;
        for (column.layers, 0..) |layer_y, i| {
            const layer_base = layer_y * batch.fine_per_block;
            layer_bases[i] = layer_base;
            layer_los[i] = @max(layer_base, batch.base[1]);
            layer_caps[i] = @min(layer_base + batch.fine_per_block - 1, batch.base[1] + ChunkSize - 1);
        }
        var filled = false;
        var fine_x = fine_lo_x;
        while (fine_x <= fine_hi_x) : (fine_x += 1) {
            const gx: usize = @intCast(fine_x - batch.base[0]);
            // Step by 2 from the matching phase to visit only even x+z voxels.
            var fine_z = fine_lo_z + ((fine_x + fine_lo_z) & 1);
            while (fine_z <= fine_hi_z) : (fine_z += 2) {
                const gz: usize = @intCast(fine_z - batch.base[2]);
                const blade: u32 = @bitCast(Noise.hash2D(0, @truncate(fine_x), @truncate(fine_z)));
                const height: i64 = 1 + @as(i64, @intCast((blade >> 16) % @as(u32, @intCast(batch.fine_per_block))));
                const scale = switch (column.scale) {
                    .fine => |grid| grid[gx][gz],
                    .uniform => |value| value,
                };
                // NaN scales fail the comparison below and skip the blade.
                const scaled_f = @as(f32, @floatFromInt(height)) * scale;
                if (!(scaled_f >= 1)) continue;
                const scaled: i64 = @intFromFloat(scaled_f);
                for (0..column.layers.len) |i| {
                    const hi = @min(layer_caps[i], layer_bases[i] + scaled - 1);
                    const lo = layer_los[i];
                    if (hi < lo) continue;
                    const gy_lo: usize = @intCast(lo - batch.base[1]);
                    const gy_hi: usize = @intCast(hi - batch.base[1]);
                    var gy = gy_lo;
                    while (gy <= gy_hi) : (gy += 1) {
                        batch.detail_grid[gx][gy][gz] = .grass;
                    }
                    filled = true;
                }
            }
        }
        return filled;
    }

    test "blade height scales with slope" {
        try std.testing.expectEqual(0, bladeHeightScale(0, 0.5));
        try std.testing.expectEqual(1, bladeHeightScale(0.5, 0.5));
        try std.testing.expectEqual(1, bladeHeightScale(2, 0.5));
        try std.testing.expectApproxEqAbs(0.5, bladeHeightScale(0.25, 0.5), 1e-6);
        try std.testing.expectEqual(1, bladeHeightScale(0, 0));
    }

    test "blades sit on alternating voxels" {
        // Negative base exercises two's-complement parity in the stride phase.
        const base: World.BlockPos = .{ -8, -8, -8 };
        var grid: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.null)));
        const batch = BladeBatch{ .detail_grid = &grid, .base = base, .fine_per_block = 8 };
        const filled = fillBlades(batch, .{ .block_x = -1, .block_z = -1, .layers = &.{0}, .scale = .{ .uniform = 1 } });
        try std.testing.expect(filled);
        for (grid, 0..) |plane, gx| {
            for (plane, 0..) |row, gy| {
                for (row, 0..) |b, gz| {
                    if (b != .grass) continue;
                    const fine_x: i64 = base[0] + @as(i64, @intCast(gx));
                    const fine_z: i64 = base[2] + @as(i64, @intCast(gz));
                    try std.testing.expect((fine_x + fine_z) & 1 == 0);
                    const fine_y: i64 = base[1] + @as(i64, @intCast(gy));
                    try std.testing.expect(fine_y >= 0 and fine_y < 8);
                }
            }
        }
    }

    test "blades follow the fine slope grid, not the column slope" {
        const base: World.BlockPos = .{ -8, -8, -8 };
        var slopes: [ChunkSize][ChunkSize]f32 = @splat(@splat(0));
        var grid: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.null)));
        const batch = BladeBatch{ .detail_grid = &grid, .base = base, .fine_per_block = 8 };
        try std.testing.expect(!fillBlades(batch, .{ .block_x = -1, .block_z = -1, .layers = &.{0}, .scale = .{ .fine = &slopes } }));
        slopes[0][0] = 1;
        try std.testing.expect(fillBlades(batch, .{ .block_x = -1, .block_z = -1, .layers = &.{0}, .scale = .{ .fine = &slopes } }));
        for (grid, 0..) |plane, gx| {
            for (plane, 0..) |row, gy| {
                for (row, 0..) |b, gz| {
                    if (b != .grass) continue;
                    try std.testing.expectEqual(0, gx);
                    try std.testing.expectEqual(0, gz);
                    const fine_y: i64 = base[1] + @as(i64, @intCast(gy));
                    try std.testing.expect(fine_y >= 0 and fine_y < 8);
                }
            }
        }
    }

    test "coarse grass slopes stay bounded by the full density" {
        // Lattice differences average full-res steps, so coarse values cannot exceed the largest full-res slope.
        const heights = DefaultGenerator.genTerrainHeight(&DefaultGenerator.Params.default, 0, .{ 3, 5 });
        const slopes_full = DefaultGenerator.grassSlopes(&heights, .full);
        const expected = DefaultGenerator.getDifferential(&heights);
        try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&expected), std.mem.asBytes(&slopes_full)));
        const full = expected;
        var max_full: f32 = 0;
        for (full) |row| {
            for (row) |s| {
                try std.testing.expect(std.math.isFinite(s));
                max_full = @max(max_full, s);
            }
        }
        try std.testing.expect(max_full > 0);
        inline for ([_]DefaultGenerator.InterpResolution{ .half, .quarter, .eighth, .sixteenth }) |d| {
            const coarse = DefaultGenerator.grassSlopes(&heights, d);
            for (coarse) |row| {
                for (row) |s| {
                    try std.testing.expect(std.math.isFinite(s));
                    try std.testing.expect(s <= max_full + 1e-3);
                }
            }
        }
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
        // A zero bound would make the reciprocal infinite and turn a whole band into stone.
        const terrain_scales: [2]f32 = .{ 1.0 / @as(f32, @floatFromInt(@max(@abs(ctx.params.terrain_max), 1))), 1.0 / @as(f32, @floatFromInt(@max(@abs(ctx.params.terrain_min), 1))) };
        const scale = @max(ctx.params.terrain_scale, 1e-6) * ctx.chunk_scale;
        const one_d_terrain_scale: f32 = 1.0 / scale;
        const sea_level: i32 = ctx.params.sea_level;
        const sea_level_f: f32 = @floatFromInt(sea_level);
        const BoolV = @Vector(ChunkSize, bool);
        const TagV = @Vector(ChunkSize, Block.Tag);
        const zero_v: FloatV = @splat(0);
        const one_v: FloatV = @splat(1);
        const depth_threshold: f32 = @floor(ctx.params.dirt_depth * scale) + 1.0;
        const block_height_vec: [ChunkSize]i32 = std.simd.iota(i32, ChunkSize) + @as(@Vector(ChunkSize, i32), @splat(chunk_pos.position[1] * ChunkSize));

        // Only the voxel height and slope vary per surface hit.
        var ground: GroundContext = .{
            .block_height = undefined,
            .sea_level = sea_level,
            .block_randomness = ctx.params.terrain_block_randomness,
            .one_d_terrain_scale = one_d_terrain_scale,
            .slope = undefined,
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
        };
        // The differential feeds randGround directly; each column computes its row lazily on first surface hit.
        for (heights, chunk_blocks, 0..) |heights_row, *col, x| {
            var differential_row: [ChunkSize]f32 = undefined;
            var differential_ready = false;
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

                const base_tag: TagV = @splat(@backingInt(if (bh <= sea_level) Block.water else Block.air));
                const land_tag: TagV = @splat(@backingInt(if (bh <= sea_level) Block.sand else Block.dirt));
                const stone_tag: TagV = @splat(@backingInt(Block.stone));
                row.* = @bitCast(@select(Block.Tag, below_or, @select(Block.Tag, below_depth, stone_tag, land_tag), base_tag));

                var surface_bits: u32 = @as(u32, @bitCast(below_or)) & @as(u32, @bitCast(diff < one_v));
                while (surface_bits != 0) {
                    if (!differential_ready) {
                        differential_row = differentialRow(&heights, x);
                        differential_ready = true;
                    }
                    const z: usize = @ctz(surface_bits);
                    surface_bits &= surface_bits - 1;
                    ground.block_height = bh;
                    ground.slope = differential_row[z];
                    row[z] = randGround(ctx.rand, heights_row[z] * terrain_scales[@intFromBool(heights_row[z] <= sea_level_f)], ground);
                }
            }
        }
    }

    fn caveThresholdAt(real_y: f32, cave_threshold: f32, cave_expansion_max: f32) f32 {
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

    /// Cave noise on an HxVxH lattice interpolated to the full grid; full/full samples every voxel directly.
    fn sampleCavesInterpolate(comptime H: usize, comptime V: usize, chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_pos: ChunkPos, chunk_scale: f32, gen_params: *const Params) void {
        const float_pos: @Vector(3, f32) = .{ @floatFromInt(chunk_pos.position[0]), @floatFromInt(chunk_pos.position[1]), @floatFromInt(chunk_pos.position[2]) };
        const one_d_scale: f32 = 1.0 / (@max(gen_params.terrain_scale, 1e-6) * chunk_scale);
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
        const cave_values = CaveInterp.init(std.mem.bytesAsValue(CaveInterp.Points, std.mem.asBytes(&grid_flat)).*).sampleGrid();
        carveCavesApply(chunk_blocks, float_pos, one_d_scale, gen_params, &cave_values);
    }

    /// Coarse coordinates for mixed H/V lattices; X/Z fill once since only the Y row varies per slab.
    fn sampleCaveGridMixed(comptime H: usize, comptime V: usize, grid_origin: @Vector(3, f32), one_d_scale: f32, gen_params: *const Params, grid_flat: *[H * V * H]f32) void {
        const x_spacing = one_d_scale / @as(f32, H - 1);
        const y_spacing = one_d_scale / @as(f32, V - 1);
        var xs: [H * H]f32 = undefined;
        var zs: [H * H]f32 = undefined;
        for (0..H) |c| {
            for (0..H) |a| {
                xs[c * H + a] = grid_origin[0] + @as(f32, @floatFromInt(a)) * x_spacing;
                zs[c * H + a] = grid_origin[2] + @as(f32, @floatFromInt(c)) * x_spacing;
            }
        }
        for (0..V) |j| {
            var ys: [H * H]f32 = @splat(grid_origin[1] + @as(f32, @floatFromInt(j)) * y_spacing);
            gen_params.cave_noise.fillNoise3DGrid(grid_flat[j * H * H ..][0 .. H * H], &xs, &ys, &zs);
        }
    }

    /// Full-resolution cave sampling without an interpolator, carved straight into the blocks.
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

    /// Carves air where interpolated cave noise falls below the depth-dependent threshold.
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
        // Draw up front so every voxel consumes the same RNG stream whatever branch it takes.
        const slope_jitter = (rand.float(f32) * 2.0 - 1.0) * ctx.slope_randomness;
        const cover_rand = rand.float(f32);
        // Jitter the shared slope so cover boundaries break up and move together with no gaps.
        const a = ctx.slope + slope_jitter;
        const height_norm = height_percent * ctx.one_d_terrain_scale;
        const height_above = @max(height_norm - ctx.ground_altitude_base, 0);

        if (ctx.block_height < ctx.sea_level) return if (a < ctx.sea_floor_rock_slope) Block.sand else Block.stone;

        // Beaches taper with slope and keep their own cap, independent of the grass width.
        const elev: f32 = @floatFromInt(ctx.block_height - ctx.sea_level);
        if (elev <= ctx.beach_band_blocks - ctx.sand_slope_falloff_blocks * a and a < ctx.sand_slope) return Block.sand;

        const ground_threshold = ctx.ground_threshold - ctx.grass_height_falloff * height_above;
        const dirt_band = @max(ctx.dirt_band - ctx.dirt_height_falloff * height_above, 0);

        if (height_norm >= ctx.snow_line and a >= ctx.snow_cliff_slope) return Block.stone;

        if (a < ground_threshold) {
            const cover = std.math.lerp(height_norm, cover_rand, ctx.block_randomness);
            return if (cover < ctx.snow_line + ctx.snow_slope_gain * a) Block.grass else Block.snow;
        }
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

        // Warp is per-point, so warp the base grid once and sample both noises in one batched pass.
        const base_coords_zone = tracy.Zone.begin(.{ .src = @src(), .name = "baseCoords" });
        var base_x: [sample_count]f32 = undefined;
        var base_z: [sample_count]f32 = undefined;
        fillCoordGrid(ChunkSize, 0, &base_x, &base_z, ctx.pos, sample_step, ctx.one_d_scale);
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
            // Warp shares the noise lattice since warped coordinates are irregular.
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
        // The filter consumes the pre-envelope shaped value; the envelope applies after in the compose.
        var shaped_center: [ChunkSize][ChunkSize]f32 = undefined;
        for (0..ChunkSize) |x| {
            const raw: FloatV = @as(FloatV, terrain_noise_raw[x * ChunkSize ..][0..ChunkSize].*);
            const large = @as(FloatV, large_terrain_noise[x * ChunkSize ..][0..ChunkSize].*);
            shaped_center[x] = shapedRow(ChunkSize, params, large, raw);
        }
        heights_zone.end();

        // Central differences from world coordinates alone keep chunk borders seamless.
        var grad_x: [sample_count]f32 = @splat(0);
        var grad_z: [sample_count]f32 = @splat(0);
        if (erosion_on or (surface_on and params.surface_noise_gradient_influence > 0)) {
            computeGradient(&ctx, &base_x, &base_z, &grad_x, &grad_z);
        }

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

    /// Final height from the shaped field and a normalized delta. The delta converts with the symmetric maximum so gullies cross the shoreline without cliffs.
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

    /// NxN coordinate grid shared by the chunk grid and the fade ring, keeping the sampler association orders aligned.
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

    /// Coarse warp+noise pipeline on a border-shared lattice, interpolated to the full grid so borders stay consistent.
    fn sampleWarpNoiseCoarse(comptime G: usize, warp_state: *const Noise.Noise(f32), noise_state: *const Noise.Noise(f32), ctx: *const HeightCtx, out: *[sample_count]f32) void {
        const N = G + 1;
        const stride: f32 = @floatFromInt(ChunkSize / G);
        var coarse_x: [N * N]f32 = undefined;
        var coarse_z: [N * N]f32 = undefined;
        fillCoordGrid(N, 0, &coarse_x, &coarse_z, ctx.pos, sample_step * stride, ctx.one_d_scale);
        var warped_x: [N * N]f32 = undefined;
        var warped_z: [N * N]f32 = undefined;
        warp_state.fillWarp2DGrid(&warped_x, &warped_z, &coarse_x, &coarse_z);
        var coarse: [N * N]f32 = undefined;
        noise_state.fillNoise2DGrid(&coarse, &warped_x, &warped_z);
        out.* = upsample(N, &coarse);
    }

    /// Interpolates a border-shared N x N lattice up to the flat full-resolution grid.
    fn upsample(comptime N: usize, lattice: *const [N * N]f32) [sample_count]f32 {
        const Interp = interpolation.MultilinearInterpolator(f32, 2, .{ N, N }, .{ ChunkSize, ChunkSize });
        const samples = Interp.init(std.mem.bytesAsValue(Interp.Points, std.mem.asBytes(lattice)).*).sampleGrid();
        var out: [sample_count]f32 = undefined;
        for (samples, 0..) |row, x| out[x * ChunkSize ..][0..ChunkSize].* = row;
        return out;
    }

    /// Flat index of coarse node (a, b); the far edge clamps to the last sample since its neighbor belongs to the next chunk.
    inline fn coarseSourceIndex(comptime stride: usize, a: usize, b: usize) usize {
        const fx: usize = @min(a * stride, ChunkSize - 1);
        const fz: usize = @min(b * stride, ChunkSize - 1);
        return fx * ChunkSize + fz;
    }

    /// Central differences folded into the gradient accumulators, evaluated from world coordinates so borders stay seamless.
    fn computeGradient(ctx: *const HeightCtx, base_x: []const f32, base_z: []const f32, grad_x: []f32, grad_z: []f32) void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "terrainGradient" });
        defer zone.end();
        var scratch: GradientScratch = undefined;
        const e = sample_step * ctx.one_d_scale;
        const one_d_2e = 1.0 / (2.0 * e);
        inline for (0..2) |axis| {
            for ([2]f32{ 1.0, -1.0 }) |sign| {
                const offset: [2]f32 = if (axis == 0) .{ sign * e, 0 } else .{ 0, sign * e };
                addGradientSamples(ctx.params, &scratch, base_x, base_z, .{ grad_x, grad_z }[axis], offset, sign, one_d_2e);
            }
        }
    }

    /// Surface detail in normalized units; the amount follows the pre-erosion gradient so detail collects on relief.
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

    /// Coarse surface detail; noise runs on the lattice while the amount decimates the full-resolution gradient.
    fn surfaceNormCoarse(comptime G: usize, ctx: *const HeightCtx, grad_x: []const f32, grad_z: []const f32, out: []f32) void {
        const N = G + 1;
        const stride: usize = ChunkSize / G;
        const stride_f: f32 = @floatFromInt(stride);
        var coarse_x: [N * N]f32 = undefined;
        var coarse_z: [N * N]f32 = undefined;
        fillCoordGrid(N, 0, &coarse_x, &coarse_z, ctx.pos, sample_step * stride_f, ctx.one_d_scale);
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
        @memcpy(out, &upsample(N, &prod));
    }

    /// Fade steepness from a coarse central difference; the fine gradient would flicker the mask between neighbors.
    fn fadeSteepness(ctx: *const HeightCtx, p_scale: f32, out: []f32) void {
        const stencil = 4;
        const N = ChunkSize + 2 * stencil;
        var ext_x: [N * N]f32 = undefined;
        var ext_z: [N * N]f32 = undefined;
        fillCoordGrid(N, stencil, &ext_x, &ext_z, ctx.pos, sample_step, ctx.one_d_scale);
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
        const e = sample_step * ctx.one_d_scale;
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

    /// Runs the erosion filter per sample into `extra`; slopes point downhill and the envelope applies once in the compose.
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
                        );
                    }
                }
            },
            inline else => |tag| applyErosionCoarse(tag.size(), base_x, base_z, grad_x, grad_z, shaped, &fade, p_scale, eparams, extra),
        }
    }

    /// Coarse erosion; the filter runs on the border-shared lattice from decimated inputs and interpolates up.
    fn applyErosionCoarse(comptime G: usize, base_x: []const f32, base_z: []const f32, grad_x: []const f32, grad_z: []const f32, shaped: *const [ChunkSize][ChunkSize]f32, fade: []const f32, p_scale: f32, eparams: erosion.ErosionParams, extra: []f32) void {
        const N = G + 1;
        const stride: usize = ChunkSize / G;
        var delta: [N * N]f32 = undefined;
        for (0..N) |a| {
            for (0..N) |b| {
                const i = coarseSourceIndex(stride, a, b);
                delta[a * N + b] = erosion.erosionFilter(
                    .{ base_x[i] / p_scale, base_z[i] / p_scale },
                    .{ shaped[i / ChunkSize][i % ChunkSize], -grad_x[i] * p_scale, -grad_z[i] * p_scale },
                    fade[i],
                    eparams,
                );
            }
        }
        for (extra, upsample(N, &delta)) |*sum, value| sum.* += value;
    }

    fn getDifferential(height: *const [ChunkSize][ChunkSize]f32) [ChunkSize][ChunkSize]f32 {
        var differential: [ChunkSize][ChunkSize]f32 = undefined;
        for (&differential, 0..) |*row, x| row.* = differentialRow(height, x);
        return differential;
    }

    /// Forward-difference slope magnitude of row `x`; the last row and column difference backward.
    fn differentialRow(height: *const [ChunkSize][ChunkSize]f32, x: usize) [ChunkSize]f32 {
        var row: [ChunkSize]f32 = undefined;
        for (&row, height[x], height[if (x + 1 < ChunkSize) x + 1 else x - 1], 0..) |*out, h, nx, z| {
            const gz = h - height[x][if (z + 1 < ChunkSize) z + 1 else z - 1];
            const gx = h - nx;
            out.* = @sqrt(gx * gx + gz * gz);
        }
        return row;
    }

    /// Grass slope grid at the configured density; coarser densities decimate and interpolate up.
    fn grassSlopes(height: *const [ChunkSize][ChunkSize]f32, interp: InterpResolution) [ChunkSize][ChunkSize]f32 {
        return switch (interp) {
            .full => getDifferential(height),
            inline else => |tag| grassSlopesCoarse(tag.size(), height),
        };
    }

    /// Coarse grass slopes on a decimated lattice, interpolated up; the far edge clamps to the last sample.
    fn grassSlopesCoarse(comptime G: usize, height: *const [ChunkSize][ChunkSize]f32) [ChunkSize][ChunkSize]f32 {
        const N = G + 1;
        const stride: usize = ChunkSize / G;
        const stride_f: f32 = @floatFromInt(stride);
        var lattice: [N * N]f32 = undefined;
        for (0..N) |a| {
            for (0..N) |b| {
                const fx: usize = @min(a * stride, ChunkSize - 1);
                const fz: usize = @min(b * stride, ChunkSize - 1);
                // Either neighbor sits one stride away, so one divisor fits all.
                const bx: usize = if (fx >= stride) fx - stride else fx + stride;
                const bz: usize = if (fz >= stride) fz - stride else fz + stride;
                const gx = (height[fx][fz] - height[bx][fz]) / stride_f;
                const gz = (height[fx][fz] - height[fx][bz]) / stride_f;
                lattice[a * N + b] = @sqrt(gx * gx + gz * gz);
            }
        }
        return std.mem.bytesAsValue([ChunkSize][ChunkSize]f32, std.mem.asBytes(&upsample(N, &lattice))).*;
    }

    /// Shaped height row shared by the base grid, gradient samples, and fade ring; the lane count follows the args.
    inline fn shapedRow(comptime N: usize, params: *const Params, large: @Vector(N, f32), raw: @Vector(N, f32)) @Vector(N, f32) {
        const V = @Vector(N, f32);
        const height_power_v: V = @splat(params.height_power);
        const large_power_v: V = @splat(params.large_power);
        const small_power_v: V = @splat(params.small_power);
        const balance_v: V = @splat(params.terrain_noise_balance);
        // Shape each field independently, then crossfade: 0 is all continental, 1 is all mountain.
        const shaped = std.math.lerp(signedPow(N, large, large_power_v), signedPow(N, raw, small_power_v), balance_v);
        return signedPow(N, shaped, height_power_v);
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

    /// Folds the shaped field at `base + offset` into `grad`, scaled by the inverse sample distance.
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
            // Fuse the accumulation so Debug and optimized builds agree bit-identically on low-slope gradients.
            grad[x * ChunkSize ..][0..ChunkSize].* = @mulAdd(FloatV, shapedRow(ChunkSize, params, large, raw), @as(FloatV, @splat(sign * one_d_2e)), grad_row);
        }
    }

    fn generateStructures(self: *DefaultGenerator, io: std.Io, allocator: std.mem.Allocator, world: *World, chunk: *Chunk, chunk_pos: ChunkPos) !void {
        const gen_structures_zone = tracy.Zone.begin(.{ .src = @src() });
        defer gen_structures_zone.end();
        if (chunk_pos.level < 0 or !self.params.gen_structures) return;
        const editor_buffer_size: usize = 100_000;
        var editor_buffer: [editor_buffer_size]u8 = undefined;
        var bfa: std.heap.BufferFirstAllocator = .init(&editor_buffer, allocator);
        var world_editor = World.Editor{ .world = world, .temp_allocator = bfa.allocator(), .propagate_changes = false };
        defer world_editor.clear();

        {
            try chunk.addAndLockShared(io);
            defer chunk.releaseAndUnlockShared(io);

            if (chunk.structures_generated.load(.seq_cst)) return;
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

                    const center_pos = chunk_pos.position * @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize } + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) };
                    for (self.params.trees) |tree_conf| {
                        if (!tree_conf.enabled) continue;
                        const structure_seed = tree_conf.placer.getStructure(.{ @trunc(lvl_x), @trunc(lvl_z) }, @intCast(chunk_pos.level)) orelse continue;
                        const tree_seed = self.seed ^ @as(u64, @bitCast(structure_seed));
                        var random = std.Random.DefaultPrng.init(@bitCast(tree_seed));
                        const rand = random.random();
                        const factor = (rand.float(f32) + 0.5) * tree_conf.size_variation;
                        const lod = -chunk_pos.level + std.math.log2_int(u32, @trunc(tree_conf.tree.trunk_height));
                        if (lod < min_full_tree_lod) {
                            try placeLowResTree(&world_editor, center_pos, scale * factor, tree_conf.tree.trunk_height, chunk_pos.level);
                            continue;
                        }
                        _ = try (World.Editor.Tree{ .pos = @intCast(center_pos), .scale = scale * factor, .config = tree_conf.tree }).place(tree_seed, &world_editor, chunk_pos.level);
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

/// Single-point shaped height mirroring the full-resolution grid path; close enough for land/water classification.
fn columnSpawnHeight(params: *const DefaultGenerator.Params, x: f32, z: f32) f32 {
    const scale = @max(params.terrain_scale, 1e-6);
    const base_x = x / (@as(f32, ChunkSize) * scale);
    const base_z = z / (@as(f32, ChunkSize) * scale);
    var wx = base_x;
    var wz = base_z;
    params.terrain_noise.domainWarp2D(&wx, &wz);
    const raw = params.terrain_noise.genNoise2D(wx, wz);
    var lx = base_x;
    var lz = base_z;
    params.large_terrain_noise_warp.domainWarp2D(&lx, &lz);
    const large = params.large_terrain_noise.genNoise2D(lx, lz);
    const shaped = DefaultGenerator.shapedRow(1, params, @as(@Vector(1, f32), @splat(large)), @as(@Vector(1, f32), @splat(raw)))[0];
    return DefaultGenerator.composeErodedHeight(shaped, 0, .init(params, scale));
}

pub fn generatorProposeSpawn(instance: *anyopaque, center: *const [3]f64, radius: f64, attempts: u32, nonce: u64) callconv(.c) generator_api.Spawnpoint {
    const self: *TerrainInstance = @ptrCast(@alignCast(instance));
    return generator_api.proposeSpawnField(self.generator.seed, center.*, radius, attempts, nonce, @floatFromInt(self.generator.params.sea_level), &self.generator.params, columnSpawnHeight);
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
    .propose_spawn = &generatorProposeSpawn,
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
    .invert = .{ .label = "Invert", .description = "Swaps the sign of the generated noise, so peaks become valleys." },
    .terrain_scale = .{ .label = "Terrain Scale", .description = "Scales the generated terrain height range.", .min = 0.1, .max = 4 },
    .terrain_min = .{ .label = "Minimum Height", .min = -100000, .max = -1 },
    .terrain_max = .{ .label = "Maximum Height", .min = 1, .max = 100000 },
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
    .terrain_noise_balance = .{ .label = "Terrain Noise Balance", .description = "Blends the continental noise (0) into the mountain (ridged) noise (1).", .min = 0, .max = 1 },
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
    .grass_detail_gradient_source = .{ .label = "Grass Detail Gradient Source", .description = "Height field the grass blade slope is computed from: parent level-0 heights (one evaluation cached across detail levels) or this chunk's own fine level." },
    .grass_detail_slope_scale = .{ .label = "Grass Detail Slope Scale", .description = "Slope in blocks per block at which grass blades keep full height. Flat ground grows nothing; 0 keeps full height everywhere.", .min = 0, .max = 4 },
    .grass_detail_gradient_interp = .{ .label = "Grass Gradient Resolution", .description = "Sampling density of the grass slope lattice; coarser is faster and smoother. Full disables interpolation." },
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
    p.terrain_block_randomness = 0.0;
    p.slope_randomness = 0.0;
    p.ground_threshold = 0.5;
    p.dirt_band = 0.7;
    p.terrain_min = -512;
    p.terrain_max = 2048;
    p.large_power = 1.5;
    p.small_power = 1.5;
    p.dirt_depth = 2.0;
    // 0.3 under the old additive blend (mountain share 0.3/1.3), preserved for the crossfade.
    p.terrain_noise_balance = 0.3 / 1.3;
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
        // Sculpted: heavy erosion rounds the terrain into flowing hills.
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
    return generator_api.presetConfig(DefaultGenerator.Params, field_specs, &terrain_presets, allocator, index);
}

pub fn generatorConfigFromZon(allocator: *const std.mem.Allocator, bytes: [*]const u8, bytes_len: usize) callconv(.c) ?*generator_api.ConfigTree {
    return generator_api.configFromZon(DefaultGenerator.Params, field_specs, allocator, bytes, bytes_len);
}

pub fn generatorConfigSetSeeds(io: *const std.Io, config: *generator_api.ConfigTree) callconv(.c) void {
    generator_api.configSetSeeds(io, config);
}

pub fn generatorCreate(opts: *const generator_api.CreateOptions, config: *const generator_api.ConfigTree) callconv(.c) ?*anyopaque {
    return createInstance(opts, config) catch return null;
}

fn createInstance(opts: *const generator_api.CreateOptions, config: *const generator_api.ConfigTree) !*TerrainInstance {
    var arena = std.heap.ArenaAllocator.init(opts.allocator);
    errdefer arena.deinit();
    var params: DefaultGenerator.Params = .default;
    try generator_api.fromTree(DefaultGenerator.Params, arena.allocator(), config, &params, field_specs);
    const seed = params.seed orelse return error.MissingSeed;
    params.setSeeds(seed);
    const instance = try opts.allocator.create(TerrainInstance);
    errdefer opts.allocator.destroy(instance);
    instance.* = .{
        .arena = arena,
        .generator = try DefaultGenerator.init(opts.allocator, opts.max_cache_bytes, params, seed),
        .source = .{
            .data = instance,
            .getTerrainHeight = null,
            .getBlocks = generator_api.instanceGenBlocks(TerrainInstance),
            .placeStructures = instanceGenStructures,
            .deinit = generator_api.instanceDeinit(TerrainInstance),
            .save = null,
        },
    };
    return instance;
}

pub fn generatorGetSource(instance: *anyopaque) callconv(.c) *const World.ChunkSource {
    return generator_api.getSource(TerrainInstance, instance);
}

fn instanceGenStructures(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, chunk: *Chunk, chunk_pos: ChunkPos) error{ OutOfMemory, Canceled, Unrecoverable }!void {
    const self: *TerrainInstance = @ptrCast(@alignCast(source.data));
    self.generator.generateStructures(io, allocator, world, chunk, chunk_pos) catch |err| return mapStructureError(err);
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
        sink += @backingInt(grid[@mod(i, ChunkSize)][0][0]);
    }
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    const vec_ns = @as(f64, @floatFromInt(start.durationTo(end).raw.toNanoseconds())) / @as(f64, @floatFromInt(iterations));

    std.debug.print("generateTerrain {s} ({s}): vector {d:.1} ns/call (sink {d})\n", .{ @tagName(@import("builtin").mode), label, vec_ns, sink });
}

fn benchTerrainHeights(io: std.Io, params: *const DefaultGenerator.Params, label: []const u8) void {
    const iterations = if (@import("builtin").mode == .debug) 50 else 500;
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

test "benchmark generateTerrain" {
    // Random and uniform height fields exercise distinct fill paths; the printed sink keeps the calls live.
    const iterations = if (builtin.mode == .debug) 100 else 2000;
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

test "benchmark genTerrainHeight" {
    benchTerrainHeights(std.testing.io, &DefaultGenerator.Params.default, "levels -1..1");
}

test "legacy config with erosion_strength parses" {
    @setEvalBranchQuota(100000000);
    // Skipped fields must still parse from declaration defaults so old configs load without migration.
    const legacy = ".{ .seed = null, .terrain_scale = 2, .erosion_strength = 1.5, .terrain_block_randomness = 0.1 }";
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..legacy.len], legacy);
    buf[legacy.len] = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const params = try std.zon.parse.fromSlice(DefaultGenerator.Params, .{
        .gpa = std.testing.allocator,
        .arena = arena.allocator(),
        .source = buf[0..legacy.len :0],
        .diagnostics = &diagnostics,
    });
    try std.testing.expectEqual(@as(f32, 1.5), params.erosion_strength);
    try std.testing.expectEqual(@as(f32, 2), params.terrain_scale);
    try std.testing.expect(params.erosion_enabled);
    try std.testing.expectEqual(@as(u32, 5), params.erosion_octaves);
}

test "config tree round trips through zon" {
    @setEvalBranchQuota(100000000);
    // Skipped fields refill from declaration defaults so saved configs keep loading.
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
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const params = try std.zon.parse.fromSlice(DefaultGenerator.Params, .{
        .gpa = std.testing.allocator,
        .arena = arena.allocator(),
        .source = source[0..emitted.len :0],
        .diagnostics = &diagnostics,
    });
    try std.testing.expectEqual(DefaultGenerator.Params.default.erosion_strength, params.erosion_strength);
    try std.testing.expectEqual(DefaultGenerator.Params.default.erosion_octaves, params.erosion_octaves);
    try std.testing.expectEqual(DefaultGenerator.Params.default.erosion_enabled, params.erosion_enabled);
    try std.testing.expectEqual(DefaultGenerator.Params.default.erosion_fade_slope, params.erosion_fade_slope);
    try std.testing.expectEqual(DefaultGenerator.Params.default.erosion_fade_altitude, params.erosion_fade_altitude);
    try std.testing.expectEqual(DefaultGenerator.Params.default.terrain_scale, params.terrain_scale);
}

test "columnSpawnHeight matches grid without erosion" {
    // With lattices off the single-point sampler must agree with the grid path (~1 ULP).
    var params = DefaultGenerator.Params.default;
    params.seed = 42;
    params.setSeeds(42);
    params.erosion_enabled = false;
    params.surface_noise_amplitude = 0;
    const grid = DefaultGenerator.genTerrainHeight(&params, 0, .{ 3, 5 });
    for ([_]usize{ 0, 7, 31 }) |x| {
        for ([_]usize{ 0, 11, 31 }) |z| {
            const world_x: f32 = @floatFromInt(3 * ChunkSize + @as(i32, @intCast(x)));
            const world_z: f32 = @floatFromInt(5 * ChunkSize + @as(i32, @intCast(z)));
            try std.testing.expectApproxEqAbs(grid[x][z], columnSpawnHeight(&params, world_x, world_z), 1e-3);
        }
    }
}

test "proposeSpawn is deterministic and plausible" {
    var params = DefaultGenerator.Params.default;
    params.seed = 42;
    params.setSeeds(42);
    var generator = try DefaultGenerator.init(std.testing.allocator, 0, params, 42);
    defer generator.terrain_height_cache.deinit(std.testing.allocator);
    var instance = TerrainInstance{ .generator = generator, .arena = undefined, .source = undefined };
    const center = [3]f64{ 0, 0, 0 };
    const a = generatorProposeSpawn(&instance, &center, 64, 32, 1);
    const b = generatorProposeSpawn(&instance, &center, 64, 32, 1);
    try std.testing.expect(a.found);
    try std.testing.expectEqual(a.pos[0], b.pos[0]);
    try std.testing.expectEqual(a.pos[1], b.pos[1]);
    try std.testing.expectEqual(a.pos[2], b.pos[2]);
    try std.testing.expect(std.math.isFinite(a.pos[1]));
}

/// Pins border continuity: the jump across a chunk border must stay within a few local steps.
fn expectSeamContinuous(west: [ChunkSize][ChunkSize]f32, east: [ChunkSize][ChunkSize]f32) !void {
    for (0..ChunkSize) |z| {
        const jump = @abs(west[ChunkSize - 1][z] - east[0][z]);
        // Neighboring samples bound the local slope, but gully ripple can double it at a steep phase.
        const step_w = @abs(west[ChunkSize - 1][z] - west[ChunkSize - 2][z]);
        const step_e = @abs(east[1][z] - east[0][z]);
        try std.testing.expect(jump <= (step_w + step_e) * 2.5 + 256.0);
    }
}

test "erosion seam continuity between adjacent chunks" {
    // World-coordinate evaluation keeps the height field continuous across chunk borders.
    const params = DefaultGenerator.Params.default;
    const west = DefaultGenerator.genTerrainHeight(&params, 0, .{ 0, 0 });
    const east = DefaultGenerator.genTerrainHeight(&params, 0, .{ 1, 0 });
    try expectSeamContinuous(west, east);
}

test "surface noise amount follows the pre-erosion gradient" {
    var params = DefaultGenerator.Params.default;
    params.surface_noise_gradient_scale = 0.01;
    params.surface_noise_amplitude = 0.5;
    params.surface_noise_gradient_influence = 1.0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), DefaultGenerator.surfaceNoiseAmount(0.0, &params), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), DefaultGenerator.surfaceNoiseAmount(0.005, &params), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), DefaultGenerator.surfaceNoiseAmount(0.01, &params), 1e-5);
    params.surface_noise_gradient_influence = 0.0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), DefaultGenerator.surfaceNoiseAmount(0.0, &params), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), DefaultGenerator.surfaceNoiseAmount(1.0, &params), 1e-6);
}

test "surface noise stays seamless across adjacent chunks" {
    var params = DefaultGenerator.Params.default;
    params.erosion_enabled = false;
    params.surface_noise_amplitude = 0.05;
    params.surface_noise_gradient_influence = 1.0;
    const west = DefaultGenerator.genTerrainHeight(&params, 0, .{ 0, 0 });
    const east = DefaultGenerator.genTerrainHeight(&params, 0, .{ 1, 0 });
    try expectSeamContinuous(west, east);
}

test "surface noise relief stays within the symmetric bound" {
    // Relief converts with the symmetric envelope, so it matches on land and under water.
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
    // The delta must not switch sides with the envelope, or gullies crossing the sea would end in cliffs.
    const bounds: [2]f32 = .{ -4096, 8196 };
    const up = DefaultGenerator.composeErodedHeight(1e-6, 0.2, .{ .bounds = bounds, .max = 8196, .scale = 1.0 });
    const down = DefaultGenerator.composeErodedHeight(-1e-6, 0.2, .{ .bounds = bounds, .max = 8196, .scale = 1.0 });
    try std.testing.expect(@abs(up - down) < 1.0);
    const deep = DefaultGenerator.composeErodedHeight(-0.5, 0.2, .{ .bounds = bounds, .max = 8196, .scale = 1.0 });
    try std.testing.expectApproxEqAbs(-0.5 * 4096 + 0.2 * 8196, deep, 1e-3);
}

test "erosion LOD consistency between level 0 and level 1" {
    // Coarser levels drop the finest octave; level 1 must match box-filtered level 0 up to that amplitude.
    const params = DefaultGenerator.Params.default;
    const coarse = DefaultGenerator.genTerrainHeight(&params, 1, .{ 1, 1 });
    var fine: [4][ChunkSize][ChunkSize]f32 = undefined;
    fine[0] = DefaultGenerator.genTerrainHeight(&params, 0, .{ 2, 2 });
    fine[1] = DefaultGenerator.genTerrainHeight(&params, 0, .{ 3, 2 });
    fine[2] = DefaultGenerator.genTerrainHeight(&params, 0, .{ 2, 3 });
    fine[3] = DefaultGenerator.genTerrainHeight(&params, 0, .{ 3, 3 });
    const max_abs_bound: f32 = @floatFromInt(@max(@abs(params.terrain_min), @abs(params.terrain_max)));
    // The dropped octave shifts gullies slightly; allow 40% of the filter magnitude plus fixed slack.
    const filter_amp: f32 = params.erosion_filter_strength / (1.0 - params.erosion_gain) * params.erosion_gully_weight;
    const limit = max_abs_bound * filter_amp * 0.4 + 128.0;
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |z| {
            // Each coarse sample covers four fine samples box-filtered at half the fine envelope.
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

fn heightsAtInterpDensity(density: DefaultGenerator.InterpResolution, chunk_pos: [2]i32) [ChunkSize][ChunkSize]f32 {
    var params = DefaultGenerator.Params.default;
    params.terrain_interp = density;
    params.large_terrain_interp = density;
    params.surface_interp = density;
    params.erosion_interp = density;
    return DefaultGenerator.genTerrainHeight(&params, 0, chunk_pos);
}

test "coarse interp densities stay finite and seamless" {
    try std.testing.expectEqual(@as(usize, ChunkSize), DefaultGenerator.InterpResolution.full.size());
    try std.testing.expectEqual(@as(usize, ChunkSize / 2), DefaultGenerator.InterpResolution.half.size());
    try std.testing.expectEqual(@as(usize, ChunkSize / 4), DefaultGenerator.InterpResolution.quarter.size());
    try std.testing.expectEqual(@as(usize, ChunkSize / 8), DefaultGenerator.InterpResolution.eighth.size());
    try std.testing.expectEqual(@as(usize, ChunkSize / 16), DefaultGenerator.InterpResolution.sixteenth.size());
    // World-coordinate evaluation keeps borders continuous; error against full-res stays far below the envelope.
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
    // A high threshold forces carving so the write path runs everywhere.
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
    params.grass_detail_gradient_source = .fine;
    params.grass_detail_slope_scale = 1.5;
    params.grass_detail_gradient_interp = .eighth;
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
    try std.testing.expectEqual(DefaultGenerator.GrassDetailGradient.fine, restored.grass_detail_gradient_source);
    try std.testing.expectApproxEqAbs(1.5, restored.grass_detail_slope_scale, 1e-6);
    try std.testing.expectEqual(DefaultGenerator.InterpResolution.eighth, restored.grass_detail_gradient_interp);
    try std.testing.expectEqual(DefaultGenerator.InterpResolution.full, DefaultGenerator.Params.default.terrain_interp);
    try std.testing.expectEqual(DefaultGenerator.InterpResolution.eighth, DefaultGenerator.Params.default.cave_interp_h);
    try std.testing.expectEqual(DefaultGenerator.InterpResolution.eighth, DefaultGenerator.Params.default.cave_interp_v);
}

test "terrain noise balance zero excludes the mountain noise" {
    // balance is the mountain (ridged) noise weight; at zero nothing about that
    // noise may change the height, even with erosion and surface detail enabled.
    var params = DefaultGenerator.Params.default;
    params.seed = 7;
    params.setSeeds(7);
    params.terrain_noise_balance = 0;
    const base = DefaultGenerator.genTerrainHeight(&params, 0, .{ 2, 3 });

    var changed = params;
    changed.terrain_noise.frequency *= 3.7;
    changed.terrain_noise.seed +%= 99991;
    const mountain_changed = DefaultGenerator.genTerrainHeight(&changed, 0, .{ 2, 3 });
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |z| try std.testing.expectEqual(base[x][z], mountain_changed[x][z]);
    }
}

test "terrain noise balance crossfades continental into mountain" {
    // Default shape powers and height_power are 1, so shapedRow reduces to lerp(large, raw, balance).
    const large: @Vector(1, f32) = .{0.8};
    const raw: @Vector(1, f32) = .{0.2};
    var params = DefaultGenerator.Params.default;

    params.terrain_noise_balance = 0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), DefaultGenerator.shapedRow(1, &params, large, raw)[0], 1e-5);
    params.terrain_noise_balance = 1;
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), DefaultGenerator.shapedRow(1, &params, large, raw)[0], 1e-5);
    params.terrain_noise_balance = 0.5;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), DefaultGenerator.shapedRow(1, &params, large, raw)[0], 1e-5);
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
    inline for (@typeInfo(@TypeOf(overrides)).@"struct".field_names) |name| {
        @field(ctx, name) = @field(overrides, name);
    }
    return ctx;
}

fn testGround(height_percent: f32, ctx: DefaultGenerator.GroundContext) Block {
    var rng = std.Random.DefaultPrng.init(1);
    var rand = rng.random();
    return DefaultGenerator.randGround(&rand, height_percent, ctx);
}

test "sand beach tapers with slope" {
    try std.testing.expectEqual(Block.sand, testGround(0, testGroundContext(.{ .block_height = 5, .slope = 0.0 })));
    try std.testing.expectEqual(Block.grass, testGround(0, testGroundContext(.{ .block_height = 5, .slope = 0.29 })));
    try std.testing.expectEqual(Block.dirt, testGround(0.3, testGroundContext(.{ .block_height = 5, .slope = 0.29 })));
    try std.testing.expectEqual(Block.sand, testGround(0, testGroundContext(.{ .block_height = 2, .slope = 0.29 })));
    try std.testing.expectEqual(Block.sand, testGround(0, testGroundContext(.{ .block_height = 6, .slope = 0.0 })));
}

test "grass threshold drops with altitude" {
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

test "continental seed keeps land within search reach" {
    // Pins the search-reach coupling fix: capped attempts must not cap ring expansion.
    var params = continental_preset;
    params.seed = 14214860294789680370;
    params.setSeeds(params.seed.?);
    var land: u32 = 0;
    var z: f32 = -8192;
    while (z <= 8192) : (z += 512) {
        var x: f32 = -8192;
        while (x <= 8192) : (x += 512) {
            if (columnSpawnHeight(&params, x, z) > 1.0) land += 1;
        }
    }
    try std.testing.expect(land > 100);
}
