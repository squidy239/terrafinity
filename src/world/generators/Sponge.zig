const std = @import("std");
const builtin = @import("builtin");

const tracy = @import("tracy");
const Block = @import("../Block.zig").Block;
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;
const generator_api = @import("generator_api.zig");

/// Base-3 levels tested per voxel. 3^15 blocks cover any practical world.
const menger_levels = 15;
/// How far below the ceiling the spawn search looks for a floor.
const spawn_scan_depth: i64 = 512;

pub const InfiniteMengerGenerator = struct {
    params: Params,
    seed: u64,

    pub fn init(params: Params, seed: u64) InfiniteMengerGenerator {
        var clamped = params;
        // A zero scale divides by zero on every voxel. The config UI clamps too.
        if (clamped.fractal_scale < 1) clamped.fractal_scale = 1;
        return .{ .params = clamped, .seed = seed };
    }

    pub const Params = struct {
        sea_level: i32 = 0,
        fractal_scale: i32 = 4, // Smallest corridor width in blocks.
        max_height: i32 = 512, // The structure stops here and leaves open sky.
        /// The host fills a null seed before create.
        seed: ?u64 = null,

        pub const default = Params{};
    };

    /// Tests one point against the infinite sponge.
    inline fn isMengerSolid(pos: @Vector(3, i64), fractal_scale: i64) bool {
        const three: @Vector(3, i64) = @splat(3);
        // Widen walls by sampling in scaled coordinates.
        var digits_left = @divFloor(pos, @as(@Vector(3, i64), @splat(fractal_scale)));
        for (0..menger_levels) |_| {
            // Hollow cells have two or three centered digits.
            if (std.simd.countTrues(@mod(digits_left, three) == @as(@Vector(3, i64), @splat(1))) >= 2) return false;
            digits_left = @divFloor(digits_left, three);
        }
        return true;
    }

    pub fn genChunk(self: *InfiniteMengerGenerator, _: std.Io, blocks: *Chunk.Encoding, chunk_pos: ChunkPos, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "GenMengerMegastructure" });
        defer zone.end();

        const ratio: f32 = ChunkPos.levelToBlockRatioFloat(chunk_pos.level);
        const chunk_start: @Vector(3, f32) = @as(@Vector(3, f32), @floatFromInt(chunk_pos.position)) * @as(@Vector(3, f32), @splat(ratio));
        const block_step: f32 = ratio / @as(f32, ChunkSize);
        const max_height: i64 = self.params.max_height;
        const sea_level: i64 = self.params.sea_level;
        const fractal_scale: i64 = self.params.fractal_scale;

        // Chunks above the ceiling are open sky.
        if (chunk_start[1] > @as(f32, @floatFromInt(max_height))) return blocks.mergeUniform(.air);

        var block_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = comptime @splat(@splat(@splat(.air)));

        for (&block_grid, 0..) |*plane, x| {
            const bx = blockCoord(chunk_start[0], block_step, x);
            for (plane, 0..) |*row, y| {
                const by = blockCoord(chunk_start[1], block_step, y);
                if (by > max_height) continue;
                for (row, 0..) |*block, z| {
                    const pos: @Vector(3, i64) = .{ bx, by, blockCoord(chunk_start[2], block_step, z) };
                    block.* = if (!isMengerSolid(pos, fractal_scale))
                        // Voids below sea level hold water.
                        if (by <= sea_level) .water else .air
                    else if (by == max_height)
                        .grass
                    else if (!isMengerSolid(pos + @Vector(3, i64){ 0, 1, 0 }, fractal_scale))
                        if (by >= sea_level) .grass else .dirt
                    else if (!isMengerSolid(pos - @Vector(3, i64){ 0, 1, 0 }, fractal_scale) and by > sea_level)
                        // Sparse emissive markers break up dark ceilings.
                        if (@as(u64, @bitCast(pos[0] *% 73856093 +% pos[2] *% 19349663 +% pos[1] *% 83492791)) % 15 == 0) .snow else .stone
                    else
                        .stone;
                }
            }
        }

        if (Chunk.getUniform(&block_grid)) |block| blocks.mergeUniform(block) else blocks.mergeGrid(&block_grid, grid_buffer);
    }
};

/// Block coordinate covered by cell `i` of one chunk axis. It is exact at the
/// standard level, where a cell is one block. At finer levels a cell is smaller
/// than a block and resolves to the block that contains it.
inline fn blockCoord(chunk_start: f32, block_step: f32, i: usize) i64 {
    return @intFromFloat(@floor(chunk_start + @as(f32, @floatFromInt(i)) * block_step));
}

/// Highest solid block in the column at or below the ceiling, searched over
/// the depth the host resolves a spawn hint in. Null when the column is
/// hollow there, which happens wherever two base-3 digits line up.
fn columnTopSolid(params: *const InfiniteMengerGenerator.Params, bx: i64, bz: i64) ?i64 {
    const max_height: i64 = params.max_height;
    const fractal_scale: i64 = params.fractal_scale;
    const bottom = max_height - spawn_scan_depth;
    var y = max_height;
    while (y >= bottom) : (y -= 1) {
        if (InfiniteMengerGenerator.isMengerSolid(.{ bx, y, bz }, fractal_scale)) return y;
    }
    return null;
}

pub fn generator_propose_spawn(instance: *anyopaque, center: *const [3]f64, radius: f64, attempts: u32, nonce: u64) callconv(.c) generator_api.Spawnpoint {
    const self: *SpongeInstance = @ptrCast(@alignCast(instance));
    const params = &self.generator.params;
    var best: generator_api.SpawnBest = .{};
    // Disc samples honor `radius`. Later rings expand to escape hollow columns.
    for (0..@min(attempts, generator_api.spawn_attempt_cap)) |i| {
        const sample = generator_api.spawnSample(self.generator.seed, .{ center[0], center[2] }, radius, nonce, @intCast(i));
        // Round to the block the host resolves for this column (`@round` there).
        const bx: i64 = @intFromFloat(@round(sample[0]));
        const bz: i64 = @intFromFloat(@round(sample[1]));
        const top = columnTopSolid(params, bx, bz) orelse continue;
        // Neighbouring tops two blocks out read as the local slope.
        const top_x = columnTopSolid(params, bx + 2, bz) orelse top;
        const top_z = columnTopSolid(params, bx, bz + 2) orelse top;
        const slope: f32 = @floatFromInt(@max(@abs(top_x - top), @abs(top_z - top)));
        const height_above_water: f32 = @floatFromInt(top - @as(i64, params.sea_level));
        // Prefer floors at the ceiling: the hint then matches the flat play layer.
        const ceiling_gap: f64 = @floatFromInt(@as(i64, params.max_height) - top);
        generator_api.considerSpawnColumn(center, sample, height_above_water, slope / 2.0, @floatFromInt(top), ceiling_gap * 0.5, ceiling_gap <= 4.0, &best);
        if (i >= generator_api.spawn_samples_per_ring - 1 and best.good) break;
    }
    return best.point;
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

const field_specs = .{
    .seed = .{ .is_seed = true, .advanced = true },
    .sea_level = .{ .label = "Sea Level", .description = "Voids at or below this height fill with water.", .min = -512, .max = 512 },
    .fractal_scale = .{ .label = "Corridor Scale", .description = "Smallest corridor width in blocks.", .min = 1, .max = 64 },
    .max_height = .{ .label = "Maximum Height", .description = "The structure stops here and leaves open sky.", .min = 0, .max = 4096 },
};

const SpongeInstance = struct {
    generator: InfiniteMengerGenerator,
    source: World.ChunkSource,
};

const generator_info_data: generator_api.GeneratorInfo = .{
    .name = "Sponge",
    .description = "Infinite Menger sponge of stone corridors and open voids",
    .version = 1,
    .api_version = generator_api.ApiVersion,
};

pub fn generator_info() callconv(.c) *const generator_api.GeneratorInfo {
    return &generator_info_data;
}

const sponge_presets = [_]InfiniteMengerGenerator.Params{
    .default,
    blk: {
        var p = InfiniteMengerGenerator.Params.default;
        p.fractal_scale = 8;
        p.max_height = 768;
        break :blk p;
    },
    blk: {
        var p = InfiniteMengerGenerator.Params.default;
        p.fractal_scale = 2;
        break :blk p;
    },
};
const sponge_preset_names = [_][]const u8{ "Default", "Wide Halls", "Dense Lattice" };
const sponge_preset_default: usize = 0;

pub fn generator_preset_count() callconv(.c) usize {
    return sponge_presets.len;
}

pub fn generator_preset_name(index: usize) callconv(.c) *const []const u8 {
    return &sponge_preset_names[index];
}

pub fn generator_preset_default_index() callconv(.c) usize {
    return sponge_preset_default;
}

pub fn generator_preset_config(allocator: *const std.mem.Allocator, index: usize) callconv(.c) ?*generator_api.ConfigTree {
    return generator_api.presetConfig(InfiniteMengerGenerator.Params, field_specs, &sponge_presets, allocator, index);
}

pub fn generator_config_from_zon(allocator: *const std.mem.Allocator, bytes: [*]const u8, bytes_len: usize) callconv(.c) ?*generator_api.ConfigTree {
    return generator_api.configFromZon(InfiniteMengerGenerator.Params, field_specs, allocator, bytes, bytes_len);
}

pub fn generator_config_set_seeds(io: *const std.Io, config: *generator_api.ConfigTree) callconv(.c) void {
    generator_api.configSetSeeds(io, config);
}

pub fn generator_create(opts: *const generator_api.CreateOptions, config: *const generator_api.ConfigTree) callconv(.c) ?*anyopaque {
    var params: InfiniteMengerGenerator.Params = .default;
    generator_api.fromTree(InfiniteMengerGenerator.Params, opts.allocator, config, &params, field_specs) catch return null;
    const seed = params.seed orelse return null;
    const instance = opts.allocator.create(SpongeInstance) catch return null;
    errdefer opts.allocator.destroy(instance);
    instance.* = .{
        .generator = InfiniteMengerGenerator.init(params, seed),
        .source = undefined,
    };
    instance.source = .{
        .data = instance,
        .getTerrainHeight = null,
        .getBlocks = generator_api.instanceGenBlocks(SpongeInstance),
        .placeStructures = null,
        .deinit = generator_api.instanceDeinit(SpongeInstance),
        .save = null,
    };
    return instance;
}

pub fn generator_get_source(instance: *anyopaque) callconv(.c) *const World.ChunkSource {
    return generator_api.getSource(SpongeInstance, instance);
}

test {
    std.testing.refAllDecls(@This());
}
