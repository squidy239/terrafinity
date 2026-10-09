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
    seed: u64,

    pub const Params = struct {
        terrainmin: i32 = -128,
        terrainmax: i32 = 128,
        SeaLevel: i32 = 0,
        /// The host fills a null seed before create.
        seed: ?u64 = null,
        terrain_scale: f32 = 4.0, // One fractal cell spans 4x4x4 voxels.

        pub const default: Params = .{};
    };

    pub fn genChunk(self: *FractalTerrainGenerator, _: std.Io, blocks: *Chunk.Encoding, chunk_pos: ChunkPos, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) void {
        const gen = tracy.Zone.begin(.{ .src = @src() });
        defer gen.end();

        const block_scale: i64 = @intFromFloat(ChunkPos.toScale(chunk_pos.level));
        const chunk_span: i64 = ChunkSize * block_scale;
        const chunk_min_y: i64 = @as(i64, chunk_pos.position[1]) * chunk_span;

        // Chunks above the ceiling are open sky.
        if (chunk_min_y > self.params.terrainmax) return blocks.mergeUniform(.air);
        // Chunks below the floor are solid rock.
        if (chunk_min_y + chunk_span < self.params.terrainmin) return blocks.mergeUniform(.stone);

        var block_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = undefined;
        const gen_terra = tracy.Zone.begin(.{ .src = @src(), .name = "Gen3DSierpinskiBlocks" });

        const chunk_block_pos = @as(@Vector(3, i64), chunk_pos.position) * @as(@Vector(3, i64), @splat(ChunkSize));
        const cell_size = self.cellSize();
        for (&block_grid, 0..) |*plane, x| {
            for (plane, 0..) |*row, y| {
                for (row, 0..) |*block, z| {
                    const local: @Vector(3, i64) = .{ @intCast(x), @intCast(y), @intCast(z) };
                    block.* = self.blockAt((chunk_block_pos + local) * @as(@Vector(3, i64), @splat(block_scale)), block_scale, cell_size);
                }
            }
        }
        gen_terra.end();

        if (Chunk.getUniform(&block_grid)) |block| blocks.mergeUniform(block) else blocks.mergeGrid(&block_grid, grid_buffer);
    }

    fn blockAt(self: *const FractalTerrainGenerator, pos: @Vector(3, i64), block_scale: i64, cell_size: i64) Block {
        const y = pos[1];
        if (y > self.params.terrainmax) return .air;
        if (y < self.params.terrainmin) return .stone;
        // Gaps at or below sea level hold water.
        if (!isSolid(pos, cell_size)) return if (y <= self.params.SeaLevel) .water else .air;
        if (y < self.params.SeaLevel) return .stone;
        return if (isSolid(pos + @Vector(3, i64){ 0, block_scale, 0 }, cell_size)) .dirt else .grass;
    }

    fn cellSize(self: *const FractalTerrainGenerator) i64 {
        return @max(1, @as(i64, @intFromFloat(self.params.terrain_scale)));
    }

    /// Topmost solid voxel of the column at `x, z`, or null when the whole
    /// `[terrainmin, terrainmax]` band is open. Reuses the generator's own
    /// solidity test so spawn agrees with generated blocks.
    fn columnTopSolid(self: *const FractalTerrainGenerator, x: i64, z: i64) ?i64 {
        const cell_size = self.cellSize();
        var y: i64 = self.params.terrainmax;
        while (y >= self.params.terrainmin) : (y -= 1) {
            if (isSolid(.{ x, y, z }, cell_size)) return y;
        }
        return null;
    }

    /// Tests one point against the Sierpinski tetrahedron with bitwise logic.
    inline fn isSolid(pos: @Vector(3, i64), cell_size: i64) bool {
        // Absolute values keep two's-complement bits out of the AND logic and mirror the fractal at the origins.
        const cell = @abs(@divFloor(pos, @as(@Vector(3, i64), @splat(cell_size))));
        // Inside means no two coordinates share a 1-bit in any position.
        return @reduce(.Or, cell & std.simd.rotateElementsLeft(cell, 1)) == 0;
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
    .{ .terrain_scale = 2.0 },
    .{ .terrain_scale = 8.0 },
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
    const seed = params.seed orelse return null;
    const instance = opts.allocator.create(FractalInstance) catch return null;
    errdefer opts.allocator.destroy(instance);
    instance.* = .{
        .generator = .{ .params = params, .seed = seed },
        .source = .{
            .data = instance,
            .getTerrainHeight = null,
            .getBlocks = generator_api.instanceGenBlocks(FractalInstance),
            .placeStructures = null,
            .deinit = generator_api.instanceDeinit(FractalInstance),
            .save = null,
        },
    };
    return instance;
}

pub fn generator_get_source(instance: *anyopaque) callconv(.c) *const World.ChunkSource {
    return generator_api.getSource(FractalInstance, instance);
}

/// Samples columns near `center` and reports the first solid one. `y_hint` is
/// the band ceiling. The host scans down from there to find the exact feet position.
pub fn generator_propose_spawn(instance: *anyopaque, center: *const [3]f64, radius: f64, attempts: u32, nonce: u64) callconv(.c) generator_api.Spawnpoint {
    const self: *FractalInstance = @ptrCast(@alignCast(instance));
    const y_hint: f64 = @floatFromInt(self.generator.params.terrainmax);
    for (0..@min(attempts, generator_api.spawn_attempt_cap)) |i| {
        const sample = generator_api.spawnSample(self.generator.seed, .{ center[0], center[2] }, radius, nonce, @intCast(i));
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

test {
    std.testing.refAllDecls(@This());
}
