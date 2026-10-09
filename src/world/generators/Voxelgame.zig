const std = @import("std");

const tracy = @import("tracy");

const Cache = @import("../../libs/Cache.zig").Cache;
const Block = @import("../Block.zig").Block;
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;
const generator_api = @import("generator_api.zig");

pub const Generator = struct {
    pub const Noise = @import("fastnoise");

    const thc_fragments = 8;

    params: Params,
    seed: u64,
    terrain_height_cache: Cache(ChunkHeightsKey, ChunkHeightsValue, ChunkHeightsValue.keyFromValue, ChunkHeightsKey.hash, .{}, thc_fragments),

    const ChunkHeightsValue = struct {
        value: [ChunkSize][ChunkSize]i32,
        key: ChunkHeightsKey,

        pub inline fn keyFromValue(v: *const ChunkHeightsValue) ChunkHeightsKey {
            return v.key;
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

    pub const Params = struct {
        /// The host fills a null seed before create. Every noise seed derives from it.
        seed: ?u64 = null,
        terrain_noise: Noise.Noise(f32),
        terrain_noise2: Noise.Noise(f32),
        cave_noise: Noise.Noise(f32),
        terrain_min: i32,
        terrain_max: i32,
        caveness: f32,
        scale: f32,
        caves: bool,
        trees: bool,

        fn setSeeds(self: *Params, seed: u64) void {
            self.terrain_noise.seed ^= @bitCast(std.hash.Murmur2_32.hashUint64(seed +% 1));
            self.terrain_noise2.seed ^= @bitCast(std.hash.Murmur2_32.hashUint64(seed +% 2));
            self.cave_noise.seed ^= @bitCast(std.hash.Murmur2_32.hashUint64(seed +% 3));
        }

        pub const default: Params = .{
            .terrain_noise = Noise.Noise(f32){
                .seed = 0,
                .noise_type = .perlin,
                .frequency = 0.00008,
                .fractal_type = .none,
                .octaves = 1,
            },
            .cave_noise = Noise.Noise(f32){
                .seed = 0,
                .noise_type = .simplex_smooth,
                .fractal_type = .none,
                .frequency = 0.009,
                .octaves = 1,
            },
            .terrain_noise2 = Noise.Noise(f32){
                .seed = -2735234,
                .noise_type = .perlin,
                .frequency = 0.0002,
                .fractal_type = .ridged,
                .octaves = 12,
            },
            .terrain_min = -512,
            .terrain_max = 512,
            .caveness = 0.4,
            .caves = false,
            .trees = true,
            .scale = 1.0,
        };
    };

    pub fn init(allocator: std.mem.Allocator, max_cache_bytes: usize, params: Params, seed: u64) !Generator {
        var seeded = params;
        seeded.setSeeds(seed);
        const cache_size = @max(
            std.math.floorPowerOfTwo(u64, max_cache_bytes / @sizeOf(ChunkHeightsValue)),
            256 * thc_fragments,
        );
        std.log.info("Creating terrain height cache with size {d} ({d} bytes)", .{
            cache_size, cache_size * @sizeOf(ChunkHeightsValue),
        });
        return .{
            .terrain_height_cache = try .init(allocator, cache_size),
            .params = seeded,
            .seed = seed,
        };
    }

    pub fn genChunk(
        self: *Generator,
        io: std.Io,
        blocks: *Chunk.Encoding,
        chunk_pos: ChunkPos,
        grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block,
    ) error{ Unrecoverable, OutOfMemory, Canceled }!void {
        var block_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = undefined;
        const gen_zone: tracy.Zone = .begin(.{ .src = @src(), .name = "gen" });
        defer gen_zone.end();

        const level_scale = World.ChunkPos.toScale(chunk_pos.level);
        const pos = chunk_pos.position;
        const chunk_offset: @Vector(3, f32) = @floatFromInt(pos * @as(@Vector(3, i32), @splat(ChunkSize)));

        // If the entire chunk rests below world zero, it starts as water.
        var has_terrain = pos[1] < 0;
        @memset(&block_grid, @splat(@splat(if (has_terrain) .water else .air)));

        const terrain_heights = self.getTerrainHeight(io, .{ pos[0], pos[2] }, chunk_pos.level) catch return error.Unrecoverable;

        var rand_impl = std.Random.DefaultPrng.init(self.seed +% @as(u64, @truncate(@as(u96, @bitCast(pos)))));

        const scaled_dirt_depth = @as(i32, @intFromFloat(5.0 / @max(1.0, level_scale)));
        const tree_chance: f32 = 0.01 * self.params.scale;
        const is_above_zero = pos[1] >= 0;

        for (&block_grid, terrain_heights, 0..) |*plane, column_heights, xx| {
            for (column_heights, 0..) |terrain_height, zz| {
                const chunk_y = @divFloor(terrain_height, @as(i32, ChunkSize));
                if (chunk_y < pos[1]) continue;

                const is_top_chunk = chunk_y > pos[1];
                const height: i32 = if (is_top_chunk) ChunkSize - 1 else @mod(terrain_height, ChunkSize);
                const column: Column = .{
                    .height = height,
                    .dirt_threshold = @max(0, height - scaled_dirt_depth),
                    .is_top_chunk = is_top_chunk,
                    .is_above_zero = is_above_zero,
                };

                for (plane[0..@intCast(column.height + 1)], 0..) |*row, yy| {
                    const local: @Vector(3, f32) = @floatFromInt(@Vector(3, usize){ xx, yy, zz });
                    row[zz] = self.genBlock(&rand_impl, (chunk_offset + local) * @as(@Vector(3, f32), @splat(level_scale)), @intCast(yy), column);
                    if (row[zz] != .air) has_terrain = true;
                }

                if (!self.params.trees or is_top_chunk or !is_above_zero) continue;
                if (plane[@intCast(column.height)][zz] != .grass) continue;
                if (rand_impl.random().float(f32) >= tree_chance) continue;
                generateTree(&block_grid, xx, zz, column.height, self.params.scale * level_scale, &rand_impl);
            }
        }

        if (!has_terrain) return blocks.mergeUniform(.air);
        if (Chunk.getUniform(&block_grid)) |block| blocks.mergeUniform(block) else blocks.mergeGrid(&block_grid, grid_buffer);
    }

    /// Per-column inputs for `genBlock`.
    const Column = struct {
        /// Local y of the column top in this chunk.
        height: i32,
        dirt_threshold: i32,
        /// The terrain surface lies in a chunk above this one.
        is_top_chunk: bool,
        is_above_zero: bool,
    };

    fn genBlock(self: *const Generator, prng: *std.Random.DefaultPrng, global: @Vector(3, f32), yy: i32, column: Column) Block {
        const scaled = global * @as(@Vector(3, f32), @splat(self.params.scale));
        const cave_density: f32 = if (self.params.caves) self.params.cave_noise.genNoise3D(scaled[0], scaled[1], scaled[2]) else 0.0;
        if (cave_density >= self.params.caveness) return .air;
        if (column.is_top_chunk) return .stone;

        // Absolute depth keeps cover stable across detail levels.
        const gm = @max(1, @as(i32, @intFromFloat(scaled[1])));

        const rand = prng.random();
        if (yy == column.height and rand.intRangeLessThan(i32, 0, 256) > gm and column.is_above_zero) return .grass;
        if (yy >= column.dirt_threshold and rand.intRangeLessThan(i32, 0, 512) > gm) return .dirt;
        return .stone;
    }

    fn generateTree(
        chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block,
        x: usize,
        z: usize,
        height: i32,
        combined_scale: f32,
        rand: *std.Random.DefaultPrng,
    ) void {
        if (combined_scale > 16.0) return; // Trees stop past very low detail.

        const scale_max = @max(1.0, combined_scale);
        const tree_type = @as(u8, @intFromFloat(@as(f32, @floatFromInt(rand.random().intRangeAtMost(u8, 0, 1))) / scale_max));
        const tree_height = @as(u8, @intFromFloat(@as(f32, @floatFromInt(rand.random().intRangeAtMost(u8, 4, 16))) / scale_max));

        if (tree_height == 0) return;

        const trunk_height = @max(1, @as(i32, tree_height) - @as(i32, @intFromFloat(2.0 / scale_max)));
        const canopy_width = @max(1, tree_height / 2);

        for (@intCast(height)..@intCast(@min(ChunkSize, height + trunk_height))) |y| chunk_blocks[x][y][z] = .wood;

        const trunk_top = height + trunk_height;
        switch (tree_type) {
            0 => { // Spherical canopy
                for (0..canopy_width + 1) |layer_width| {
                    setLeafLayer(chunk_blocks, x, z, trunk_top + @as(i32, @intCast(layer_width)), layer_width, true);
                }
            },
            1 => { // Conical canopy
                for (0..canopy_width) |layer| {
                    setLeafLayer(chunk_blocks, x, z, trunk_top + @as(i32, @intCast(layer)), canopy_width - layer, false);
                }
            },
            else => {},
        }
    }

    fn setLeafLayer(
        chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block,
        x: usize,
        z: usize,
        y: i32,
        width: usize,
        round: bool,
    ) void {
        if (y < 0 or y >= ChunkSize) return;
        const z_min = z -| width;
        for (chunk_blocks[x -| width..@min(ChunkSize, x + width + 1)], x -| width..) |*plane, leaf_x| {
            for (plane[@intCast(y)][z_min..@min(ChunkSize, z + width + 1)], z_min..) |*block, leaf_z| {
                const dx = @max(leaf_x, x) - @min(leaf_x, x);
                const dz = @max(leaf_z, z) - @min(leaf_z, z);
                if (round and dx * dx + dz * dz > width * width) continue;
                block.* = .leaves;
            }
        }
    }

    fn getTerrainHeight(self: *Generator, io: std.Io, chunk_pos: [2]i32, level: i32) ![ChunkSize][ChunkSize]i32 {
        const key: ChunkHeightsKey = .{ .x = chunk_pos[0], .z = chunk_pos[1], .level = level };
        if (self.terrain_height_cache.get(io, key)) |cached| return cached.value;
        const generated = self.genTerrainHeight(chunk_pos, level);
        _ = self.terrain_height_cache.upsert(io, &.{ .key = key, .value = generated });
        return generated;
    }

    fn genTerrainHeight(self: *const Generator, chunk_pos: [2]i32, level: i32) [ChunkSize][ChunkSize]i32 {
        const zone: tracy.Zone = .begin(.{ .src = @src(), .name = "GenTerrainHeight" });
        defer zone.end();

        const level_scale = World.ChunkPos.toScale(level);
        const chunk_offset_x: f32 = @floatFromInt(chunk_pos[0] * ChunkSize);
        const chunk_offset_z: f32 = @floatFromInt(chunk_pos[1] * ChunkSize);

        var terrain_heights: [ChunkSize][ChunkSize]i32 = undefined;
        for (&terrain_heights, 0..) |*column_heights, xx| {
            const global_x = (chunk_offset_x + @as(f32, @floatFromInt(xx))) * level_scale;
            for (column_heights, 0..) |*terrain_height, zz| {
                const global_z = (chunk_offset_z + @as(f32, @floatFromInt(zz))) * level_scale;
                terrain_height.* = @intFromFloat(self.worldHeight(global_x, global_z) / level_scale);
            }
        }
        return terrain_heights;
    }

    /// Returns the terrain surface height at the world position `x, z`.
    fn worldHeight(self: *const Generator, x: f32, z: f32) f32 {
        const variance: f32 = @floatFromInt(self.params.terrain_max - self.params.terrain_min);
        const min: f32 = @floatFromInt(self.params.terrain_min);
        return self.params.terrain_noise2.genNoise2D(x * self.params.scale, z * self.params.scale) * variance + min;
    }
};

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
    .terrain_min = .{ .label = "Minimum Height", .min = -100000, .max = 0 },
    .terrain_max = .{ .label = "Maximum Height", .min = 0, .max = 100000 },
    .caveness = .{ .label = "Cave Density", .min = -1, .max = 1 },
    .scale = .{ .label = "Terrain Scale", .min = 0.1, .max = 4 },
    .caves = .{ .label = "Generate Caves" },
    .trees = .{ .label = "Generate Trees" },
};

const generator_info_data: generator_api.GeneratorInfo = .{
    .name = "Voxelgame",
    .description = "Voxel-style terrain with noise caves and trees",
    .version = 1,
    .api_version = generator_api.ApiVersion,
};

pub fn generator_info() callconv(.c) *const generator_api.GeneratorInfo {
    return &generator_info_data;
}

const voxelgame_presets = [_]Generator.Params{
    .default,
    blk: {
        var p = Generator.Params.default;
        p.caves = true;
        p.caveness = 0.3;
        p.cave_noise.fractal_type = .fbm;
        p.cave_noise.octaves = 5;
        break :blk p;
    },
    blk: {
        var p = Generator.Params.default;
        p.terrain_noise2.octaves = 1;
        p.terrain_noise2.fractal_type = .none;
        p.terrain_min = -128;
        p.terrain_max = 128;
        break :blk p;
    },
};
const voxelgame_preset_names = [_][]const u8{ "Default", "Caverns", "Plains" };
const voxelgame_preset_default: usize = 0;

pub fn generator_preset_count() callconv(.c) usize {
    return voxelgame_presets.len;
}

pub fn generator_preset_name(index: usize) callconv(.c) *const []const u8 {
    return &voxelgame_preset_names[index];
}

pub fn generator_preset_default_index() callconv(.c) usize {
    return voxelgame_preset_default;
}

pub fn generator_preset_config(allocator: *const std.mem.Allocator, index: usize) callconv(.c) ?*generator_api.ConfigTree {
    return generator_api.presetConfig(Generator.Params, field_specs, &voxelgame_presets, allocator, index);
}

pub fn generator_config_from_zon(allocator: *const std.mem.Allocator, bytes: [*]const u8, bytes_len: usize) callconv(.c) ?*generator_api.ConfigTree {
    return generator_api.configFromZon(Generator.Params, field_specs, allocator, bytes, bytes_len);
}

pub fn generator_config_set_seeds(io: *const std.Io, config: *generator_api.ConfigTree) callconv(.c) void {
    generator_api.configSetSeeds(io, config);
}

const VoxelgameInstance = struct {
    generator: Generator,
    source: World.ChunkSource,
};

pub fn generator_create(opts: *const generator_api.CreateOptions, config: *const generator_api.ConfigTree) callconv(.c) ?*anyopaque {
    return createInstance(opts, config) catch return null;
}

fn createInstance(opts: *const generator_api.CreateOptions, config: *const generator_api.ConfigTree) !*VoxelgameInstance {
    var params: Generator.Params = .default;
    try generator_api.fromTree(Generator.Params, opts.allocator, config, &params, field_specs);
    const seed = params.seed orelse return error.MissingSeed;
    const instance = try opts.allocator.create(VoxelgameInstance);
    errdefer opts.allocator.destroy(instance);
    instance.* = .{
        .generator = try Generator.init(opts.allocator, opts.max_cache_bytes, params, seed),
        .source = .{
            .data = instance,
            .getTerrainHeight = null,
            .getBlocks = generator_api.instanceGenBlocks(VoxelgameInstance),
            .placeStructures = null, // genChunk places trees.
            .deinit = generator_api.instanceDeinit(VoxelgameInstance),
            .save = null,
        },
    };
    return instance;
}

pub fn generator_get_source(instance: *anyopaque) callconv(.c) *const World.ChunkSource {
    return generator_api.getSource(VoxelgameInstance, instance);
}

pub fn generator_propose_spawn(instance: *anyopaque, center: *const [3]f64, radius: f64, attempts: u32, nonce: u64) callconv(.c) generator_api.Spawnpoint {
    const self: *VoxelgameInstance = @ptrCast(@alignCast(instance));
    // No sea level: water fills below y = 0, handled by the shared margin.
    return generator_api.proposeSpawnField(self.generator.seed, center.*, radius, attempts, nonce, 0, &self.generator, Generator.worldHeight);
}

pub const generator_api_vtable: generator_api.GeneratorApi = .{
    .info = &generator_info,
    .create = &generator_create,
    .get_source = &generator_get_source,
    .preset_count = &generator_preset_count,
    .preset_name = &generator_preset_name,
    .preset_default_index = &generator_preset_default_index,
    .preset_config = &generator_preset_config,
    .config_from_zon = &generator_config_from_zon,
    .config_set_seeds = &generator_config_set_seeds,
    .propose_spawn = &generator_propose_spawn,
};

comptime {
    @export(&generator_api_vtable, .{ .name = generator_api.api_export_name });
}

test "proposeSpawn is deterministic and plausible" {
    var generator = try Generator.init(std.testing.allocator, 0, .default, 42);
    defer generator.terrain_height_cache.deinit(std.testing.allocator);
    var instance: VoxelgameInstance = .{ .generator = generator, .source = undefined };
    const center: [3]f64 = @splat(0);
    const a = generator_propose_spawn(&instance, &center, 0, 32, 1);
    const b = generator_propose_spawn(&instance, &center, 0, 32, 1);
    try std.testing.expect(a.found);
    try std.testing.expectEqual(a.pos, b.pos);
    try std.testing.expect(std.math.isFinite(a.pos[1]));
}

test {
    std.testing.refAllDecls(@This());
}
