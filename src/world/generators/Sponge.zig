const std = @import("std");
const builtin = @import("builtin");

const tracy = @import("tracy");
const Block = @import("../Block.zig").Block;
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;
const generator_api = @import("generator_api.zig");

/// Base-3 levels tested per voxel; 3^15 blocks cover any practical world.
const menger_levels = 15;
/// How far below the ceiling the spawn search looks for a floor.
const spawn_scan_depth: i64 = 512;

pub const InfiniteMengerGenerator = struct {
    params: Params,

    pub fn init(allocator: std.mem.Allocator, max_cache_bytes: usize, params: Params) InfiniteMengerGenerator {
        _ = allocator;
        _ = max_cache_bytes;
        var clamped = params;
        // A zero scale would divide by zero on every voxel; the config UI clamps too.
        if (clamped.fractal_scale < 1) clamped.fractal_scale = 1;
        return .{ .params = clamped };
    }

    pub fn getSource(self: *InfiniteMengerGenerator) World.ChunkSource {
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
        const self: *InfiniteMengerGenerator = @ptrCast(@alignCast(source.data));
        self.genChunk(io, allocator, chunk_pos, blocks, world, grid_buffer);
        return .{ .from_disk = false, .structures = false };
    }

    pub fn deinit(self: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World) void {
        _ = self;
        _ = world;
        _ = io;
        _ = allocator;
    }

    pub const Params = struct {
        sea_level: i32 = 0,
        fractal_scale: i32 = 4, // Smallest corridor width in blocks.
        max_height: i32 = 512, // The structure stops here and leaves open sky.
        seed: ?u64 = null,

        pub const default = Params{};

        pub fn setSeeds(self: *Params, io: std.Io) void {
            if (self.seed == null) {
                var random_seed: u64 = undefined;
                io.random(std.mem.asBytes(&random_seed));
                self.seed = random_seed;
            }
        }
    };

    /// Tests one point against the infinite sponge.
    inline fn isMengerSolid(bx: i64, by: i64, bz: i64, fractal_scale: i64) bool {
        // Widen walls by sampling in scaled coordinates.
        const scaled_x = @divFloor(bx, fractal_scale);
        const scaled_y = @divFloor(by, fractal_scale);
        const scaled_z = @divFloor(bz, fractal_scale);

        var scale: i64 = 1;

        for (0..menger_levels) |_| {
            const px = @mod(@divFloor(scaled_x, scale), 3);
            const py = @mod(@divFloor(scaled_y, scale), 3);
            const pz = @mod(@divFloor(scaled_z, scale), 3);

            // Hollow cells have two or three centered digits.
            var middle_count: u8 = 0;
            if (px == 1) middle_count += 1;
            if (py == 1) middle_count += 1;
            if (pz == 1) middle_count += 1;

            if (middle_count >= 2) return false;

            scale *= 3;
        }

        return true;
    }

    pub fn genChunk(self: *InfiniteMengerGenerator, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, blocks: *Chunk.Encoding, world: *World, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) void {
        _ = allocator;
        _ = io;
        _ = world;
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "GenMengerMegastructure" });
        defer zone.end();

        const ratio: f32 = ChunkPos.levelToBlockRatioFloat(chunk_pos.level);
        const chunk_start: @Vector(3, f32) = @as(@Vector(3, f32), @floatFromInt(chunk_pos.position)) * @as(@Vector(3, f32), @splat(ratio));
        const block_step: f32 = ratio / @as(f32, ChunkSize);
        const max_height: i64 = self.params.max_height;
        const sea_level: i64 = self.params.sea_level;
        const fractal_scale: i64 = self.params.fractal_scale;

        // Chunks above the ceiling are open sky.
        if (chunk_start[1] > @as(f32, @floatFromInt(max_height))) {
            blocks.merge(.{ .uniform = .air }, grid_buffer);
            return;
        }

        var block_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = comptime @splat(@splat(@splat(.air)));

        for (0..ChunkSize) |x| {
            const bx = blockCoord(chunk_start[0], block_step, x);
            for (0..ChunkSize) |y| {
                const by = blockCoord(chunk_start[1], block_step, y);

                if (by > max_height) continue;

                for (0..ChunkSize) |z| {
                    const bz = blockCoord(chunk_start[2], block_step, z);

                    if (!isMengerSolid(bx, by, bz, fractal_scale)) {
                        // Voids below sea level hold water.
                        block_grid[x][y][z] = if (by <= sea_level) .water else .air;
                    } else if (by == max_height) {
                        block_grid[x][y][z] = .grass;
                    } else if (!isMengerSolid(bx, by + 1, bz, fractal_scale)) {
                        block_grid[x][y][z] = if (by >= sea_level) .grass else .dirt;
                    } else if (!isMengerSolid(bx, by - 1, bz, fractal_scale) and by > sea_level) {
                        // Sparse emissive markers break up dark ceilings.
                        const hash: u64 = @bitCast(bx *% 73856093 +% bz *% 19349663 +% by *% 83492791);
                        block_grid[x][y][z] = if (hash % 15 == 0) .snow else .stone;
                    } else {
                        block_grid[x][y][z] = .stone;
                    }
                }
            }
        }

        if (Chunk.getUniform(&block_grid)) |uniform| {
            blocks.merge(.{ .uniform = uniform }, grid_buffer);
        } else {
            blocks.merge(.{ .grid = &block_grid }, grid_buffer);
        }
    }
};

/// Block coordinate covered by cell `i` of one chunk axis. Exact at the
/// standard level, where a cell is one block; finer levels cover sub-block
/// cells and resolve to the block that contains them.
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
        if (InfiniteMengerGenerator.isMengerSolid(bx, y, bz, fractal_scale)) return y;
    }
    return null;
}

const SpawnBest = struct {
    point: generator_api.Spawnpoint = .{ .pos = .{ 0, 0, 0 }, .found = false },
    score: f64 = std.math.inf(f64),
    good: bool = false,
};

/// Scores one sampled column, keeping the best even when it is wet or steep.
fn considerSpongeColumn(params: *const InfiniteMengerGenerator.Params, center: *const [3]f64, sample: [2]f64, best: *SpawnBest) void {
    // Round to the block the host resolves for this column (`@round` there).
    const bx: i64 = @intFromFloat(@round(sample[0]));
    const bz: i64 = @intFromFloat(@round(sample[1]));
    const top = columnTopSolid(params, bx, bz) orelse return;
    // Neighbouring tops two blocks out read as the local slope.
    const top_x = columnTopSolid(params, bx + 2, bz) orelse top;
    const top_z = columnTopSolid(params, bx, bz + 2) orelse top;
    const slope: f32 = @floatFromInt(@max(@abs(top_x - top), @abs(top_z - top)));
    const dx = sample[0] - center[0];
    const dz = sample[1] - center[2];
    const height_above_water: f32 = @floatFromInt(top - @as(i64, params.sea_level));
    const scored = generator_api.scoreSpawnColumn(@sqrt(dx * dx + dz * dz), height_above_water, slope / 2.0);
    // Prefer floors at the ceiling: the hint then matches the flat play layer.
    const ceiling_gap: f64 = @floatFromInt(@as(i64, params.max_height) - top);
    const score = scored.score + ceiling_gap * 0.5;
    if (score < best.score) {
        best.score = score;
        best.point = .{
            .pos = .{ sample[0], @as(f64, @floatFromInt(top)) + generator_api.spawn_hint_clearance, sample[1] },
            .found = true,
        };
        best.good = !scored.wet and !scored.steep and ceiling_gap <= 4.0;
    }
}

pub fn generator_propose_spawn(instance: *anyopaque, center: *const [3]f64, radius: f64, attempts: u32, nonce: u64) callconv(.c) generator_api.Spawnpoint {
    const self: *SpongeInstance = @ptrCast(@alignCast(instance));
    const params = &self.generator.params;
    const seed = params.seed orelse return generator_api.no_spawn;
    var best = SpawnBest{};
    // Disc samples honor `radius`; later rings expand to escape hollow columns.
    const capped = @min(attempts, generator_api.spawn_attempt_cap);
    for (0..capped) |i| {
        const sample = generator_api.spawnSample(seed, .{ center[0], center[2] }, radius, nonce, @intCast(i));
        considerSpongeColumn(params, center, sample, &best);
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
    if (params.seed == null) params.setSeeds(opts.io);
    const instance = opts.allocator.create(SpongeInstance) catch return null;
    errdefer opts.allocator.destroy(instance);
    instance.* = .{
        .generator = InfiniteMengerGenerator.init(opts.allocator, opts.max_cache_bytes, params),
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
