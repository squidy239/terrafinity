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
    terrain_height_cache: Cache(ChunkHeightsKey, ChunkHeightsValue, ChunkHeightsValue.key_from_value, ChunkHeightsKey.hash, .{}, thc_fragments),

    const ChunkHeightsValue = struct {
        value: [ChunkSize][ChunkSize]i32,
        key: ChunkHeightsKey,

        pub inline fn key_from_value(v: *const ChunkHeightsValue) ChunkHeightsKey {
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
        terrain_noise: Noise.Noise(f32),
        terrain_noise2: Noise.Noise(f32),
        cave_noise: Noise.Noise(f32),
        terrain_min: i32,
        terrain_max: i32,
        caveness: f32,
        scale: f32,
        caves: bool,
        trees: bool,

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

    pub fn init(allocator: std.mem.Allocator, max_cache_bytes: usize, params: Params) !Generator {
        const cache_size = @max(
            std.math.floorPowerOfTwo(u64, max_cache_bytes / @sizeOf(ChunkHeightsValue)),
            256 * thc_fragments,
        );
        std.log.info("Creating terrain height cache with size {d} ({d} bytes)", .{
            cache_size, cache_size * @sizeOf(ChunkHeightsValue),
        });
        return .{
            .terrain_height_cache = try .init(allocator, cache_size, .{ .name = "terrain_height_cache" }),
            .params = params,
        };
    }

    pub fn genChunk(
        self: *Generator,
        io: std.Io,
        blocks: *Chunk.Encoding,
        chunk_pos: ChunkPos,
        grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block,
    ) error{ Unrecoverable, OutOfMemory, Canceled }!void {
        var block_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = comptime @splat(@splat(@splat(.null)));
        const gen_zone: tracy.Zone = .begin(.{ .src = @src(), .name = "gen" });
        defer gen_zone.end();

        const level_scale = World.ChunkPos.toScale(chunk_pos.level);

        const Pos = [3]i32{
            @intCast(chunk_pos.position[0]),
            @intCast(chunk_pos.position[1]),
            @intCast(chunk_pos.position[2]),
        };
        const chunk_offset = [3]f32{
            @floatFromInt(Pos[0] * @as(i32, ChunkSize)),
            @floatFromInt(Pos[1] * @as(i32, ChunkSize)),
            @floatFromInt(Pos[2] * @as(i32, ChunkSize)),
        };

        // If the entire chunk rests below world zero, it starts as water.
        const fill_block: Block = if (chunk_offset[1] < 0.0) .water else .air;
        @memset(&block_grid, @splat(@splat(fill_block)));
        var has_terrain = chunk_offset[1] < 0.0;

        const terrain_heights = self.getTerrainHeight(io, .{ Pos[0], Pos[2] }, chunk_pos.level) catch return error.Unrecoverable;

        var rand_impl = std.Random.DefaultPrng.init(@intCast(std.Io.Timestamp.now(io, .awake).toMilliseconds()));

        const scaled_dirt_depth = @as(i32, @intFromFloat(5.0 / @max(1.0, level_scale)));
        const tree_chance: f32 = 0.01 * self.params.scale;

        for (0..ChunkSize) |xx| {
            const global_x = (chunk_offset[0] + @as(f32, @floatFromInt(xx))) * level_scale;

            for (0..ChunkSize) |zz| {
                const global_z = (chunk_offset[2] + @as(f32, @floatFromInt(zz))) * level_scale;

                const tn = terrain_heights[xx][zz];
                const chunk_y = @divFloor(tn, @as(i32, ChunkSize));

                if (chunk_y < Pos[1]) continue;

                const is_top_chunk = chunk_y > Pos[1];
                const height: i32 = if (is_top_chunk) @as(i32, ChunkSize) - 1 else @mod(tn, @as(i32, ChunkSize));
                std.debug.assert(height >= 0 and height < ChunkSize);

                const dirt_threshold = @max(0, height - scaled_dirt_depth);

                var yy: usize = 0;
                while (yy <= @as(usize, @intCast(height))) : (yy += 1) {
                    const global_y = (chunk_offset[1] + @as(f32, @floatFromInt(yy))) * level_scale;

                    block_grid[xx][yy][zz] = self.genBlock(
                        &rand_impl,
                        .{ global_x, global_y, global_z },
                        @intCast(yy),
                        height,
                        dirt_threshold,
                        is_top_chunk,
                        Pos[1],
                    );
                    if (block_grid[xx][yy][zz] != .air) has_terrain = true;
                }

                if (self.params.trees and
                    Pos[1] >= 0 and
                    !is_top_chunk and
                    block_grid[xx][@intCast(height)][zz] == .grass and
                    rand_impl.random().float(f32) < tree_chance)
                {
                    generateTree(&block_grid, xx, zz, height, self.params.scale, level_scale, &rand_impl);
                }
            }
        }

        if (!has_terrain) {
            blocks.merge(.{ .uniform = .air }, grid_buffer);
            return;
        }

        if (Chunk.getUniform(&block_grid)) |uniform_block| {
            blocks.mergeUniform(uniform_block);
        } else {
            blocks.mergeGrid(&block_grid, grid_buffer);
        }
    }

    fn genBlock(
        self: *const Generator,
        prng: *std.Random.DefaultPrng,
        global: [3]f32,
        yy: i32,
        height: i32,
        dirt_threshold: i32,
        is_top_chunk: bool,
        pos_y: i32,
    ) Block {
        const cave_density: f32 = if (self.params.caves)
            self.params.cave_noise.genNoise3D(global[0] * self.params.scale, global[1] * self.params.scale, global[2] * self.params.scale)
        else
            0.0;
        if (cave_density >= self.params.caveness) return .air;
        if (is_top_chunk) return .stone;

        // Scale density logic natively matching world absolute depth
        const gm = @max(1, @as(i32, @intFromFloat(global[1] * self.params.scale)));

        const rand = prng.random();
        if (yy == height and rand.intRangeLessThan(i32, 0, 256) > gm and pos_y >= 0) return .grass;
        if (yy >= dirt_threshold and rand.intRangeLessThan(i32, 0, 512) > gm) return .dirt;
        return .stone;
    }

    fn generateTree(
        chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block,
        x: usize,
        z: usize,
        height: i32,
        scale: f32,
        level_scale: f32,
        rand: *std.Random.DefaultPrng,
    ) void {
        const combined_scale = scale * level_scale;
        if (combined_scale > 16.0) return; // Prevent trees generating at very low detail LODs

        const scale_max = @max(1.0, combined_scale);
        const tree_type = @as(u8, @intFromFloat(@as(f32, @floatFromInt(rand.random().intRangeAtMost(u8, 0, 1))) / scale_max));
        const tree_height = @as(u8, @intFromFloat(@as(f32, @floatFromInt(rand.random().intRangeAtMost(u8, 4, 16))) / scale_max));

        if (tree_height == 0) return;

        const trunk_height_calc = @as(i32, tree_height) - @as(i32, @intFromFloat(2.0 / scale_max));
        const trunk_height = @as(u8, @intCast(@max(1, trunk_height_calc)));
        const canopy_width = @max(1, tree_height / 2);
        const surface_y = height;

        var yy: usize = 0;
        while (yy < @as(usize, trunk_height)) : (yy += 1) {
            const block_y = surface_y + @as(i32, @intCast(yy));
            if (block_y >= 0 and block_y < ChunkSize) {
                chunk_blocks[x][@intCast(block_y)][z] = .wood;
            }
        }

        const trunk_top = surface_y + @as(i32, @intCast(trunk_height));
        switch (tree_type) {
            0 => { // Spherical canopy
                var layer_width: i8 = @intCast(canopy_width);
                while (layer_width >= 0) : (layer_width -= 1) {
                    setLeafLayer(chunk_blocks, x, z, trunk_top + layer_width, layer_width, true);
                }
            },
            1 => { // Conical canopy
                var layer: u8 = 0;
                while (layer < canopy_width) : (layer += 1) {
                    setLeafLayer(chunk_blocks, x, z, trunk_top + @as(i32, layer), @intCast(canopy_width - layer), false);
                }
            },
            else => {},
        }
    }

    /// Fills a square layer of leaves around the trunk, optionally rounded.
    fn setLeafLayer(
        chunk_blocks: *[ChunkSize][ChunkSize][ChunkSize]Block,
        x: usize,
        z: usize,
        layer_y_i: i32,
        width: i8,
        round: bool,
    ) void {
        if (layer_y_i < 0 or layer_y_i >= ChunkSize) return;
        const layer_y: usize = @intCast(layer_y_i);

        var dx: i8 = -width;
        while (dx <= width) : (dx += 1) {
            var dz: i8 = -width;
            while (dz <= width) : (dz += 1) {
                if (round and dx *| dx +| dz * dz > width * width) continue;
                const leaf_x = @as(i32, @intCast(x)) + dx;
                const leaf_z = @as(i32, @intCast(z)) + dz;
                if (leaf_x >= 0 and leaf_x < ChunkSize and leaf_z >= 0 and leaf_z < ChunkSize) {
                    chunk_blocks[@intCast(leaf_x)][layer_y][@intCast(leaf_z)] = .leaves;
                }
            }
        }
    }

    fn getTerrainHeight(self: *Generator, io: std.Io, chunk_pos: [2]i32, level: i32) ![ChunkSize][ChunkSize]i32 {
        if (self.terrain_height_cache.get(io, .{ .x = chunk_pos[0], .z = chunk_pos[1], .level = level })) |cached| {
            return cached.value;
        }
        const generated = self.genTerrainHeight(chunk_pos, level);
        _ = self.terrain_height_cache.upsert(io, &.{
            .key = .{ .x = chunk_pos[0], .z = chunk_pos[1], .level = level },
            .value = generated,
        });
        return generated;
    }

    fn genTerrainHeight(self: *Generator, chunk_pos: [2]i32, level: i32) [ChunkSize][ChunkSize]i32 {
        const zone: tracy.Zone = .begin(.{ .src = @src(), .name = "GenTerrainHeight" });
        defer zone.end();

        const level_scale = World.ChunkPos.toScale(level);

        const chunk_offset_x: f32 = @floatFromInt(chunk_pos[0] * @as(i32, ChunkSize));
        const chunk_offset_z: f32 = @floatFromInt(chunk_pos[1] * @as(i32, ChunkSize));

        // Variance and limits must be evaluated in absolute coordinates
        const terrain_variance = @as(f32, @floatFromInt(self.params.terrain_max - self.params.terrain_min));
        const terrain_min_f = @as(f32, @floatFromInt(self.params.terrain_min));

        var terrain_heights: [ChunkSize][ChunkSize]i32 = undefined;
        for (0..ChunkSize) |xx| {
            const global_x = (chunk_offset_x + @as(f32, @floatFromInt(xx))) * level_scale;
            for (0..ChunkSize) |zz| {
                const global_z = (chunk_offset_z + @as(f32, @floatFromInt(zz))) * level_scale;

                _ = self.params.terrain_noise;
                const noise = self.params.terrain_noise2.genNoise2D(global_x * self.params.scale, global_z * self.params.scale);

                // Calculate the true physical world height
                const absolute_world_height = (noise * terrain_variance) + terrain_min_f;

                // Map it backwards down to the local chunk's block scale index
                terrain_heights[xx][zz] = @as(i32, @intFromFloat(absolute_world_height / level_scale));
            }
        }
        return terrain_heights;
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
        // Caves on, carved by strong simplex noise.
        p.caves = true;
        p.caveness = 0.3;
        p.cave_noise.fractal_type = .fbm;
        p.cave_noise.octaves = 5;
        break :blk p;
    },
    blk: {
        var p = Generator.Params.default;
        // Flat plains: single low-frequency octave, wide variance.
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
    if (index >= voxelgame_presets.len) return null;
    return generator_api.fromStruct(Generator.Params, allocator.*, &voxelgame_presets[index], field_specs) catch null;
}

pub fn generator_config_from_zon(allocator: *const std.mem.Allocator, bytes: [*]const u8, bytes_len: usize) callconv(.c) ?*generator_api.ConfigTree {
    @setEvalBranchQuota(100000000);
    var arena = std.heap.ArenaAllocator.init(allocator.*);
    defer arena.deinit();
    const params = std.zon.parse.fromSliceAlloc(Generator.Params, arena.allocator(), bytes[0..bytes_len :0], null, .{}) catch return null;
    return generator_api.fromStruct(Generator.Params, allocator.*, &params, field_specs) catch null;
}

pub fn generator_config_set_seeds(io: *const std.Io, config: *generator_api.ConfigTree) callconv(.c) void {
    _ = io;
    _ = config;
}

const VoxelgameInstance = struct {
    generator: Generator,
    source: World.ChunkSource,
};

pub fn generator_create(opts: *const generator_api.CreateOptions, config: *const generator_api.ConfigTree) callconv(.c) ?*anyopaque {
    var params: Generator.Params = .default;
    generator_api.fromTree(Generator.Params, opts.allocator, config, &params, field_specs) catch return null;
    const instance = opts.allocator.create(VoxelgameInstance) catch return null;
    errdefer opts.allocator.destroy(instance);
    instance.* = .{
        .generator = Generator.init(opts.allocator, opts.max_cache_bytes, params) catch return null,
        .source = undefined,
    };
    instance.source = .{
        .data = instance,
        .getTerrainHeight = null,
        .getBlocks = &instanceGenBlocks,
        .placeStructures = null, // trees are generated inline during block gen
        .deinit = &instanceDeinit,
        .save = null,
    };
    return instance;
}

pub fn generator_get_source(instance: *anyopaque) callconv(.c) *const World.ChunkSource {
    const self: *VoxelgameInstance = @ptrCast(@alignCast(instance));
    return &self.source;
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
};

comptime {
    @export(&generator_api_vtable, .{ .name = generator_api.api_export_name });
}

fn instanceGenBlocks(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, blocks: *Chunk.Encoding, chunk_pos: ChunkPos, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) error{ Unrecoverable, OutOfMemory, Canceled }!?World.ChunkSource.GetBlocksMetadata {
    _ = allocator;
    _ = world;
    const self: *VoxelgameInstance = @ptrCast(@alignCast(source.data));
    try self.generator.genChunk(io, blocks, chunk_pos, grid_buffer);
    return .{ .from_disk = false, .structures = false };
}

fn instanceDeinit(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World) void {
    _ = io;
    _ = world;
    const self: *VoxelgameInstance = @ptrCast(@alignCast(source.data));
    self.generator.terrain_height_cache.deinit(allocator);
    allocator.destroy(self);
}
