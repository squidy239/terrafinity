const std = @import("std");
const tracy = @import("tracy");

const Cache = @import("../../libs/Cache.zig").Cache;
const Block = @import("../Block.zig").Block;
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;

pub const Generator = struct {
    pub const Noise = @import("fastnoise.zig");

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

        pub fn setSeeds(self: *@This(), io: std.Io) void {
            _ = io;
            _ = self;
        }
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

    pub fn deinit(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World) void {
        _ = io;
        _ = world;
        const self: *Generator = @ptrCast(@alignCast(source.data));
        self.terrain_height_cache.deinit(allocator);
    }

    pub fn getSource(self: *Generator) World.ChunkSource {
        return .{
            .data = self,
            .getTerrainHeight = null,
            .getBlocks = &genChunkBlocks,
            .placeStructures = null, // trees are generated inline during block gen
            .deinit = &deinit,
            .save = null,
        };
    }

    fn genChunkBlocks(
        source: World.ChunkSource,
        io: std.Io,
        allocator: std.mem.Allocator,
        world: *World,
        blocks: *Chunk.Encoding,
        chunk_pos: ChunkPos,
        grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block,
    ) error{ Unrecoverable, OutOfMemory, Canceled }!?World.ChunkSource.GetBlocksMetadata {
        const self: *Generator = @ptrCast(@alignCast(source.data));
        _ = allocator;
        _ = world;

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

        // If the entire chunk rests below the absolute absolute world zero, it starts as water.
        const fill_block: Block = if (chunk_offset[1] < 0.0) .water else .air;
        @memset(&block_grid, @splat(@splat(fill_block)));

        var has_terrain = chunk_offset[1] < 0.0;

        const terrain_heights = self.getTerrainHeight(io, .{ Pos[0], Pos[2] }, chunk_pos.level) catch return error.Unrecoverable;

        var rand_impl = std.Random.DefaultPrng.init(@intCast(std.Io.Timestamp.now(io, .awake).toMilliseconds()));

        const scaled_dirt_depth = @as(i32, @intFromFloat(5.0 / @max(1.0, level_scale)));
        const tree_chance: f32 = 0.01 * self.params.scale;

        for (0..ChunkSize) |xx| {
            // Absolute global X coordinate for noise evaluation
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
                    // Absolute global Y coordinate
                    const global_y = (chunk_offset[1] + @as(f32, @floatFromInt(yy))) * level_scale;

                    const cave_density: f32 = if (self.params.caves)
                        self.params.cave_noise.genNoise3D(global_x * self.params.scale, global_y * self.params.scale, global_z * self.params.scale)
                    else
                        0.0;

                    if (cave_density < self.params.caveness) {
                        const yy_i: i32 = @intCast(yy);
                        block_grid[xx][yy][zz] = if (!is_top_chunk) blk: {
                            // Scale density logic natively matching world absolute depth
                            var gm: i32 = @intFromFloat(global_y * self.params.scale);
                            if (gm <= 0) gm = 1;

                            const rand = rand_impl.random();
                            if (yy_i == height and
                                rand.intRangeLessThan(i32, 0, 256) > gm and
                                Pos[1] >= 0)
                            {
                                break :blk .grass;
                            } else if (yy_i >= dirt_threshold and
                                rand.intRangeLessThan(i32, 0, 512) > gm)
                            {
                                break :blk .dirt;
                            }
                            break :blk .stone;
                        } else .stone;
                        has_terrain = true;
                    } else {
                        block_grid[xx][yy][zz] = .air;
                    }
                }

                if (self.params.trees and
                    Pos[1] >= 0 and
                    !is_top_chunk and
                    block_grid[xx][@intCast(height)][zz] == .grass and
                    rand_impl.random().float(f32) < tree_chance)
                {
                    generateTree(
                        &block_grid,
                        xx,
                        zz,
                        height,
                        self.params.scale,
                        level_scale,
                        &rand_impl,
                    );
                }
            }
        }

        if (!has_terrain) {
            blocks.merge(.{ .uniform = .air }, grid_buffer);
            return .{ .from_disk = false, .structures = false };
        }

        if (Chunk.getUniform(&block_grid)) |uniform_block| {
            blocks.mergeUniform(uniform_block);
        } else {
            blocks.mergeGrid(&block_grid, grid_buffer);
        }

        return .{ .from_disk = false, .structures = false };
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

        switch (tree_type) {
            0 => { // Spherical canopy
                var layer_width: i8 = @intCast(canopy_width);
                while (layer_width >= 0) : (layer_width -= 1) {
                    const layer_y_i: i32 = surface_y + @as(i32, @intCast(trunk_height)) + @as(i32, layer_width);
                    if (layer_y_i < 0 or layer_y_i >= ChunkSize) continue;
                    const layer_y: usize = @intCast(layer_y_i);

                    var dx: i8 = -layer_width;
                    while (dx <= layer_width) : (dx += 1) {
                        var dz: i8 = -layer_width;
                        while (dz <= layer_width) : (dz += 1) {
                            if (dx *| dx +| dz * dz <= layer_width * layer_width) {
                                const leaf_x = @as(i32, @intCast(x)) + dx;
                                const leaf_z = @as(i32, @intCast(z)) + dz;
                                if (leaf_x >= 0 and leaf_x < ChunkSize and leaf_z >= 0 and leaf_z < ChunkSize) {
                                    chunk_blocks[@intCast(leaf_x)][layer_y][@intCast(leaf_z)] = .leaves;
                                }
                            }
                        }
                    }
                }
            },
            1 => { // Conical canopy
                var layer: u8 = 0;
                while (layer < canopy_width) : (layer += 1) {
                    const layer_y_i: i32 = surface_y + @as(i32, @intCast(trunk_height)) + @as(i32, @intCast(layer));
                    if (layer_y_i < 0 or layer_y_i >= ChunkSize) continue;
                    const layer_y: usize = @intCast(layer_y_i);
                    const current_width = canopy_width - layer;

                    var dx: i8 = -@as(i8, @intCast(current_width));
                    while (dx <= @as(i8, @intCast(current_width))) : (dx += 1) {
                        var dz: i8 = -@as(i8, @intCast(current_width));
                        while (dz <= @as(i8, @intCast(current_width))) : (dz += 1) {
                            const leaf_x = @as(i32, @intCast(x)) + dx;
                            const leaf_z = @as(i32, @intCast(z)) + dz;
                            if (leaf_x >= 0 and leaf_x < ChunkSize and leaf_z >= 0 and leaf_z < ChunkSize) {
                                chunk_blocks[@intCast(leaf_x)][layer_y][@intCast(leaf_z)] = .leaves;
                            }
                        }
                    }
                }
            },
            else => {},
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
