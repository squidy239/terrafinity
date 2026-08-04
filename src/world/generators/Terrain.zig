const std = @import("std");
const builtin = @import("builtin");

const tracy = @import("tracy");

const Cache = @import("../../libs/Cache.zig").Cache;
const Block = @import("../Block.zig").Block;
const BFA = @import("../BufferFirstAllocator.zig");
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const Interpolation = @import("../Interpolation.zig");
const JitteredGrid = @import("../structures/JitteredGrid.zig").JitteredGrid;
const Sphere = @import("../structures/Sphere.zig").Sphere;
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
        const chunk_scale_factor = 1.0 / ChunkPos.toScale(chunk_pos.level);
        const gen = tracy.Zone.begin(.{ .src = @src() });
        defer gen.end();
        _ = world;
        if (chunk_pos.position[1] > ChunkPos.fromGlobalBlockPos(.{ 0, self.params.terrain_max, 0 }, chunk_pos.level).position[1]) {
            blocks.merge(.{ .uniform = .air }, grid_buffer);
            return;
        }
        var block_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = comptime @splat(@splat(@splat(.null)));
        if (chunk_pos.position[1] < ChunkPos.fromGlobalBlockPos(.{ 0, self.params.terrain_min, 0 }, chunk_pos.level).position[1]) {
            blocks.merge(.{ .uniform = .stone }, grid_buffer);
        } else {
            var rng = std.Random.DefaultPrng.init(self.params.seed.? +% @as(u64, @truncate(@as(u96, @bitCast(chunk_pos.position)))));
            var rand = rng.random();
            const heights = try self.getTerrainHeight(io, allocator, [2]i32{ chunk_pos.position[0], chunk_pos.position[2] }, chunk_pos.level);
            const gen_terrain_zone = tracy.Zone.begin(.{ .src = @src(), .name = "GenTerrainBlocks" });
            generateTerrain(&block_grid, chunk_pos, heights, &self.params, &rand, chunk_scale_factor);
            gen_terrain_zone.end();
            const one_block = Chunk.getUniform(&block_grid);
            if (one_block != null and one_block.? == .air) {
                blocks.merge(.{ .uniform = .air }, grid_buffer);
                return;
            }
        }
        generateCavesInterpolate(&block_grid, chunk_pos, chunk_scale_factor, self.params);
        const one_block = Chunk.getUniform(&block_grid);
        if (one_block) |block| {
            blocks.merge(.{ .uniform = block }, grid_buffer);
        } else blocks.merge(.{ .grid = &block_grid }, grid_buffer);
    }

    fn generateTerrain(chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_pos: ChunkPos, heights: [ChunkSize][ChunkSize]i32, gen_params: *const Params, rand: *std.Random, chunk_scale: f32) void {
        const terrain_scales: [2]f32 = .{
            1.0 / @as(f32, @floatFromInt(@abs(gen_params.terrain_max))),
            1.0 / @as(f32, @floatFromInt(@abs(gen_params.terrain_min))),
        };
        const scale = gen_params.terrain_scale * chunk_scale;
        const one_d_terrain_scale: f32 = 1.0 / scale;
        const sea_level: i32 = gen_params.sea_level;
        const IntV = @Vector(ChunkSize, i32);
        const BoolV = @Vector(ChunkSize, bool);
        const TagV = @Vector(ChunkSize, Block.Tag);
        const zero_v: IntV = @splat(0);

        const block_height_vec: [ChunkSize]i32 = std.simd.iota(i32, ChunkSize) + @as(IntV, @splat(chunk_pos.position[1] * ChunkSize));
        for (heights, 0..) |heights_row, x| {
            const th: IntV = heights_row;
            const th_arr: [ChunkSize]i32 = th;
            for (0..ChunkSize) |y| {
                const bh: i32 = block_height_vec[y];
                const diff: IntV = th - @as(IntV, @splat(bh));
                const below_depth: BoolV = diff > @as(IntV, @splat(@ceil(5.0 * scale)));
                const below_or: BoolV = diff >= zero_v;
                const below_depth_bits: u32 = @bitCast(below_depth);
                const below_or_bits: u32 = @bitCast(below_or);
                if (below_depth_bits == @as(u32, @bitCast(@as(BoolV, @splat(true))))) {
                    chunk_blocks[x][y] = @splat(Block.stone);
                    continue;
                }
                if (below_or_bits == 0) {
                    chunk_blocks[x][y] = @splat(if (bh <= sea_level) Block.water else Block.air);
                    continue;
                }

                var tags: TagV = @splat(@intFromEnum(Block.air));
                tags = @select(Block.Tag, below_or, @select(Block.Tag, below_depth, @as(TagV, @splat(@intFromEnum(Block.stone))), @as(TagV, @splat(@intFromEnum(Block.dirt)))), tags);
                if (bh <= sea_level) {
                    tags = @select(Block.Tag, @as(BoolV, @bitCast(~below_or_bits)), @as(TagV, @splat(@intFromEnum(Block.water))), tags);
                }
                chunk_blocks[x][y] = @bitCast(tags);

                var surface_bits: u32 = @bitCast(diff == zero_v);
                const surface_zone = tracy.Zone.begin(.{ .src = @src(), .name = "surfaceBlocks" });
                defer surface_zone.end();
                while (surface_bits != 0) {
                    const z: usize = @ctz(surface_bits);
                    surface_bits &= surface_bits - 1;
                    chunk_blocks[x][y][z] = randGround(rand, @as(f32, @floatFromInt(th_arr[z])) * terrain_scales[@intFromBool(th_arr[z] <= sea_level)], bh, sea_level, gen_params.terrain_block_randomness, one_d_terrain_scale);
                }
            }
        }
    }

    fn generateCavesInterpolate(chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_pos: ChunkPos, chunk_scale: f32, gen_params: Params) void {
        const caves = tracy.Zone.begin(.{ .src = @src() });
        defer caves.end();
        const cave_grid_size: usize = 4;
        const CaveInterp = Interpolation.TrilinearInterpolator3D(f32, cave_grid_size, cave_grid_size, cave_grid_size, ChunkSize, ChunkSize, ChunkSize);
        var grid: [cave_grid_size][cave_grid_size][cave_grid_size]f32 = undefined;
        const float_pos: @Vector(3, f32) = .{ @floatFromInt(chunk_pos.position[0]), @floatFromInt(chunk_pos.position[1]), @floatFromInt(chunk_pos.position[2]) };
        const one_d_terrain_scale_vec: @Vector(3, f32) = @splat(1.0 / (gen_params.terrain_scale * chunk_scale));
        const cave_noise_zone = tracy.Zone.begin(.{ .src = @src(), .name = "caveNoise" });
        var grid_flat: [cave_grid_size * cave_grid_size * cave_grid_size]f32 = undefined;
        const grid_origin = float_pos * one_d_terrain_scale_vec;
        gen_params.cave_noise.fillGrid3D(&grid_flat, cave_grid_size, cave_grid_size, grid_origin[0], grid_origin[1], grid_origin[2], (1.0 / @as(f32, cave_grid_size - 1)) * one_d_terrain_scale_vec[0]);
        for (0..cave_grid_size) |z| {
            for (0..cave_grid_size) |y| {
                for (0..cave_grid_size) |x| {
                    grid[z][y][x] = grid_flat[(z * cave_grid_size + y) * cave_grid_size + x];
                }
            }
        }
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
            const cave_threshold: f32 = gen_params.cave_threshold + ((1 - (1 / -@min(-1, (real_y / gen_params.cave_expansion_max) - 1))) * 2);
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

    fn randGround(rand: *const std.Random, height_percent: f32, block_height: i64, sea_level: i64, block_randomness: f32, one_d_terrain_scale: f32) Block {
        const r = std.math.lerp(height_percent * one_d_terrain_scale, rand.float(f32), block_randomness);
        return if (block_height < sea_level) Block.dirt else if (r < 0.25) Block.grass else if (r < 0.4) Block.dirt else if (r < 0.6) Block.stone else Block.snow;
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
        const scale = params.terrain_scale * (32.0 / World.ChunkPos.levelToBlockRatioFloat(level));
        const float_pos: @Vector(2, f32) = .{ @floatFromInt(chunk_pos[0]), @floatFromInt(chunk_pos[1]) };
        const d32: f32 = comptime 1.0 / @as(comptime_float, ChunkSize);
        var height: [ChunkSize][ChunkSize]i32 = undefined;
        const float_bounds = [2]f32{ @floatFromInt(params.terrain_min), @floatFromInt(params.terrain_max) };
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
        for (0..ChunkSize) |x| {
            var noise_row: [ChunkSize]f32 = undefined;
            @memcpy(&noise_row, terrain_noise_raw[x * ChunkSize ..][0..ChunkSize]);
            const raw: FloatV = @max(@as(FloatV, noise_row), zero_v);
            const inv = one_v - raw;
            const pow_a = (raw * two_v) * (raw * two_v) * half_v;
            const pow_b = one_v - (inv * two_v) * (inv * two_v) * half_v;
            @memcpy(&noise_row, large_terrain_noise[x * ChunkSize ..][0..ChunkSize]);
            const warped = @as(FloatV, noise_row) * @select(f32, raw < half_v, pow_a, pow_b);
            const bounds = @select(f32, warped > zero_v, @as(FloatV, @splat(float_bounds[1])), @as(FloatV, @splat(float_bounds[0])));
            const height_row: @Vector(ChunkSize, i32) = @floor(warped * @abs(bounds) * @as(FloatV, @splat(scale)));
            height[x] = @as([ChunkSize]i32, height_row);
        }
        heights_zone.end();
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

                    const lvl_x: f32 = @floatFromInt((chunk_pos.position[0] * ChunkSize) + @as(i32, @intCast(x)));
                    const lvl_z: f32 = @floatFromInt((chunk_pos.position[2] * ChunkSize) + @as(i32, @intCast(z)));

                    for (self.params.trees) |tree_conf| {
                        if (!tree_conf.enabled) continue;
                        const is_tree = tree_conf.placer.getStructure(.{ @trunc(lvl_x), @trunc(lvl_z) }, @intCast(chunk_pos.level));
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
        const sphere = Sphere(f32).init(@floatFromInt(pos + @Vector(3, i64){ 0, @ceil(diameter / 2.0), 0 }), diameter);
        _ = try editor.placeSamplerShape(.leaves, sphere, level);
    }
};

test "benchmark generateTerrain" {
    const iterations = if (@import("builtin").mode == .Debug) 100 else 2000;
    const io = std.testing.io;
    var seed_rng = std.Random.DefaultPrng.init(0xC0FFEE);
    const seed_rand = seed_rng.random();
    var heights: [ChunkSize][ChunkSize]i32 = undefined;
    for (&heights) |*row| {
        for (row) |*height| {
            height.* = seed_rand.intRangeAtMost(i32, -256, 256);
        }
    }
    const flat_stone: [ChunkSize][ChunkSize]i32 = @splat(@splat(200));

    benchHeights(io, "random", heights, iterations);
    benchHeights(io, "uniform", flat_stone, iterations);
}

fn benchHeights(io: std.Io, label: []const u8, heights: [ChunkSize][ChunkSize]i32, iterations: usize) void {
    const params = DefaultGenerator.Params.default;
    const chunk_scale: f32 = 1.0;
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.null)));
    var sink: u64 = 0;

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |i| {
        const pos = ChunkPos{ .level = 0, .position = .{ @intCast(@mod(i, 7)), @intCast(@mod(i, 3)), @intCast(@mod(i, 11)) } };
        var rng = std.Random.DefaultPrng.init(i +% 1);
        var rand = rng.random();
        DefaultGenerator.generateTerrain(&grid, pos, heights, &params, &rand, chunk_scale);
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
    var sink: i32 = 0;
    var height: [ChunkSize][ChunkSize]i32 = undefined;

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |i| {
        height = DefaultGenerator.genTerrainHeight(params, @as(i32, @intCast(@mod(i, 3))) - 1, .{ 3, 5 });
        sink += height[0][0];
    }
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    const ns = @as(f64, @floatFromInt(start.durationTo(end).raw.toNanoseconds())) / @as(f64, @floatFromInt(iterations));

    std.debug.print("genTerrainHeight {s}: {d:.1} ns/call (sink {d})\n", .{ @tagName(@import("builtin").mode), ns, sink });
}
