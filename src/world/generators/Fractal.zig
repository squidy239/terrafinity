const std = @import("std");
const builtin = @import("builtin");

const tracy = @import("tracy");
const Block = @import("../Block.zig").Block;
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;
const generator_api = @import("generator_api.zig");

pub const FractalTerrainGenerator = struct {
    params: Params,

    pub fn init(allocator: std.mem.Allocator, max_cache_bytes: usize, params: Params) FractalTerrainGenerator {
        _ = allocator;
        _ = max_cache_bytes;
        return .{
            .params = params,
        };
    }

    pub fn getSource(self: *FractalTerrainGenerator) World.ChunkSource {
        return .{
            .data = self,
            .getTerrainHeight = null,
            .getBlocks = &genChunkBlocks,
            .placeStructures = null,
            .deinit = &deinit,
            .save = null,
        };
    }

    fn genChunkBlocks(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, blocks: *Chunk.Encoding, chunk_pos: ChunkPos, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) error{ Unrecoverable, OutOfMemory, Canceled }!?World.ChunkSource.GetBlocksMetadata {
        const self: *FractalTerrainGenerator = @ptrCast(@alignCast(source.data));
        try self.genChunk(io, allocator, chunk_pos, blocks, world, grid_buffer);
        return .{ .from_disk = false, .structures = false };
    }

    pub fn deinit(self: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World) void {
        _ = self;
        _ = world;
        _ = io;
        _ = allocator;
    }

    pub const Params = struct {
        terrainmin: i32 = -128,
        terrainmax: i32 = 128,
        SeaLevel: i32 = 0,
        seed: ?u64 = null,
        terrain_scale: f32 = 4.0, // One fractal cell spans 4x4x4 voxels.

        pub const default: Params = .{};

        pub fn setSeeds(self: *Params, io: std.Io) void {
            if (self.seed == null) {
                var random_seed: u64 = undefined;
                io.random(std.mem.asBytes(&random_seed));
                self.seed = random_seed;
            }
        }
    };

    pub fn genChunk(self: *FractalTerrainGenerator, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, blocks: *Chunk.Encoding, world: *World, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) !void {
        _ = allocator;
        _ = io;
        _ = world;
        const gen = tracy.Zone.begin(.{ .src = @src() });
        defer gen.end();

        const block_scale: i64 = @intFromFloat(ChunkPos.toScale(chunk_pos.level));
        const chunk_span: i64 = ChunkSize * block_scale;
        const min_y: i64 = self.params.terrainmin;
        const max_y: i64 = self.params.terrainmax;
        const chunk_min_y: i64 = @as(i64, chunk_pos.position[1]) * chunk_span;

        // Chunks above the ceiling are open sky.
        if (chunk_min_y > max_y) {
            blocks.merge(.{ .uniform = .air }, grid_buffer);
            return;
        }

        // Chunks below the floor are solid rock.
        if (chunk_min_y + chunk_span < min_y) {
            blocks.merge(.{ .uniform = .stone }, grid_buffer);
            return;
        }

        var block_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = comptime @splat(@splat(@splat(.null)));
        const gen_terra = tracy.Zone.begin(.{ .src = @src(), .name = "Gen3DSierpinskiBlocks" });

        const chunk_block_pos = @as(@Vector(3, i64), chunk_pos.position) * @as(@Vector(3, i64), @splat(ChunkSize));
        const scale_divider: i64 = @max(1, @as(i64, @intFromFloat(self.params.terrain_scale)));

        for (0..ChunkSize) |x| {
            const bx = (chunk_block_pos[0] + @as(i64, @intCast(x))) * block_scale;
            for (0..ChunkSize) |y| {
                const by = (chunk_block_pos[1] + @as(i64, @intCast(y))) * block_scale;
                for (0..ChunkSize) |z| {
                    const bz = (chunk_block_pos[2] + @as(i64, @intCast(z))) * block_scale;

                    if (by > max_y) {
                        block_grid[x][y][z] = .air;
                        continue;
                    }
                    if (by < min_y) {
                        block_grid[x][y][z] = .stone;
                        continue;
                    }

                    const is_solid = isSierpinskiTetrahedron(bx, by, bz, scale_divider);

                    if (is_solid) {
                        const block_above_solid = isSierpinskiTetrahedron(bx, by + 1, bz, scale_divider);

                        if (!block_above_solid and by >= self.params.SeaLevel) {
                            block_grid[x][y][z] = .grass;
                        } else if (by < self.params.SeaLevel) {
                            block_grid[x][y][z] = .stone;
                        } else {
                            block_grid[x][y][z] = .dirt;
                        }
                    } else {
                        // Gaps below sea level hold water.
                        if (by <= self.params.SeaLevel) {
                            block_grid[x][y][z] = .water;
                        } else {
                            block_grid[x][y][z] = .air;
                        }
                    }
                }
            }
        }
        gen_terra.end();

        const one_block = Chunk.getUniform(&block_grid);
        if (one_block) |block| {
            blocks.merge(.{ .uniform = block }, grid_buffer);
        } else {
            blocks.merge(.{ .grid = &block_grid }, grid_buffer);
        }
    }

    /// Topmost solid voxel of the column at `x, z`, or null when the whole
    /// `[terrainmin, terrainmax]` band is open. Reuses the generator's own
    /// solidity test so spawn agrees with generated blocks.
    fn columnTopSolid(self: *const FractalTerrainGenerator, x: i64, z: i64) ?i64 {
        const scale_divider: i64 = @max(1, @as(i64, @intFromFloat(self.params.terrain_scale)));
        var y: i64 = self.params.terrainmax;
        while (y >= self.params.terrainmin) : (y -= 1) {
            if (isSierpinskiTetrahedron(x, y, z, scale_divider)) return y;
        }
        return null;
    }

    /// Tests one point against the Sierpinski tetrahedron with bitwise logic.
    inline fn isSierpinskiTetrahedron(bx: i64, by: i64, bz: i64, scale_divider: i64) bool {
        const scaled_x = @divFloor(bx, scale_divider);
        const scaled_y = @divFloor(by, scale_divider);
        const scaled_z = @divFloor(bz, scale_divider);

        // Absolute values keep two's-complement bits out of the AND logic and mirror the fractal at the origins.
        const sx = @as(u64, @intCast(@abs(scaled_x)));
        const sy = @as(u64, @intCast(@abs(scaled_y)));
        const sz = @as(u64, @intCast(@abs(scaled_z)));

        // Inside means no two coordinates share a 1-bit in any position.
        return (sx & sy) == 0 and (sy & sz) == 0 and (sz & sx) == 0;
    }
};

const field_specs = .{
    .seed = .{ .is_seed = true, .advanced = true },
    .terrainmin = .{ .label = "Minimum Height", .description = "Floor of the generated fractal band.", .min = -8192, .max = 0 },
    .terrainmax = .{ .label = "Maximum Height", .description = "Ceiling of the generated fractal band.", .min = 0, .max = 8192 },
    .SeaLevel = .{ .label = "Sea Level", .description = "Voids at or below this height fill with water.", .min = -8192, .max = 8192 },
    .terrain_scale = .{ .label = "Terrain Scale", .description = "Blocks per fractal cell; larger makes coarser structures.", .min = 1, .max = 16, .step = 1 },
};

const FractalInstance = struct {
    generator: FractalTerrainGenerator,
    source: World.ChunkSource,
};

const generator_info_data: generator_api.GeneratorInfo = .{
    .name = "Fractal",
    .description = "3D Sierpinski tetrahedron terrain",
    .version = 1,
    .api_version = generator_api.ApiVersion,
};

pub fn generator_info() callconv(.c) *const generator_api.GeneratorInfo {
    return &generator_info_data;
}

const fractal_presets = [_]FractalTerrainGenerator.Params{
    .default,
    blk: {
        var p = FractalTerrainGenerator.Params.default;
        p.terrain_scale = 2.0;
        break :blk p;
    },
    blk: {
        var p = FractalTerrainGenerator.Params.default;
        p.terrain_scale = 8.0;
        break :blk p;
    },
};
const fractal_preset_names = [_][]const u8{ "Default", "Fine Fractal", "Coarse Fractal" };
const fractal_preset_default: usize = 0;

pub fn generator_preset_count() callconv(.c) usize {
    return fractal_presets.len;
}

pub fn generator_preset_name(index: usize) callconv(.c) *const []const u8 {
    return &fractal_preset_names[index];
}

pub fn generator_preset_default_index() callconv(.c) usize {
    return fractal_preset_default;
}

pub fn generator_preset_config(allocator: *const std.mem.Allocator, index: usize) callconv(.c) ?*generator_api.ConfigTree {
    return generator_api.presetConfig(FractalTerrainGenerator.Params, field_specs, &fractal_presets, allocator, index);
}

pub fn generator_config_from_zon(allocator: *const std.mem.Allocator, bytes: [*]const u8, bytes_len: usize) callconv(.c) ?*generator_api.ConfigTree {
    return generator_api.configFromZon(FractalTerrainGenerator.Params, field_specs, allocator, bytes, bytes_len);
}

pub fn generator_config_set_seeds(io: *const std.Io, config: *generator_api.ConfigTree) callconv(.c) void {
    generator_api.configSetSeeds(io, config);
}

pub fn generator_create(opts: *const generator_api.CreateOptions, config: *const generator_api.ConfigTree) callconv(.c) ?*anyopaque {
    var params: FractalTerrainGenerator.Params = .default;
    generator_api.fromTree(FractalTerrainGenerator.Params, opts.allocator, config, &params, field_specs) catch return null;
    if (params.seed == null) params.setSeeds(opts.io);
    const instance = opts.allocator.create(FractalInstance) catch return null;
    errdefer opts.allocator.destroy(instance);
    instance.* = .{
        .generator = FractalTerrainGenerator.init(opts.allocator, opts.max_cache_bytes, params),
        .source = undefined,
    };
    instance.source = .{
        .data = instance,
        .getTerrainHeight = null,
        .getBlocks = generator_api.instanceGenBlocks(FractalInstance),
        .placeStructures = null,
        .deinit = generator_api.instanceDeinit(FractalInstance),
        .save = null,
    };
    return instance;
}

pub fn generator_get_source(instance: *anyopaque) callconv(.c) *const World.ChunkSource {
    return generator_api.getSource(FractalInstance, instance);
}

/// Samples columns near `center` and reports the first solid one. `y_hint` is
/// the band ceiling; the host scans down from there to resolve exact feet.
pub fn generator_propose_spawn(instance: *anyopaque, center: *const [3]f64, radius: f64, attempts: u32, nonce: u64) callconv(.c) generator_api.Spawnpoint {
    const self: *FractalInstance = @ptrCast(@alignCast(instance));
    const seed = self.generator.params.seed orelse return generator_api.no_spawn;
    const y_hint: f64 = @floatFromInt(self.generator.params.terrainmax);
    const capped = @min(attempts, generator_api.spawn_attempt_cap);
    for (0..capped) |i| {
        const sample = generator_api.spawnSample(seed, .{ center[0], center[2] }, radius, nonce, @intCast(i));
        const x: i64 = @intFromFloat(@round(sample[0]));
        const z: i64 = @intFromFloat(@round(sample[1]));
        if (self.generator.columnTopSolid(x, z) != null) {
            return .{ .pos = .{ sample[0], y_hint, sample[1] }, .found = true };
        }
    }
    return generator_api.no_spawn;
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
    // Test binaries link several generators, so only non-test builds export the shared symbol.
    if (!builtin.is_test) @export(&generator_api_vtable, .{ .name = generator_api.api_export_name });
}
