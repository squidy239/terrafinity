const std = @import("std");
const builtin = @import("builtin");
const tracy = @import("tracy");

const Block = @import("../Block.zig").Block;
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const generator_api = @import("generator_api.zig");
const JitteredGrid = @import("../structures/JitteredGrid.zig").JitteredGrid;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;

/// Planet placement grid. One grid unit is one level-0 chunk (ChunkSize blocks).
const Grid = JitteredGrid(3, i32);

/// Shifts the grid so every generated cell index is positive: JitteredGrid only
/// returns structures found from positions at or above the cell origin, which
/// fails for cells at negative coordinates.
const grid_shift: i32 = 1 << 20;

/// A single planet rendered as a sphere with a noise-bumped surface.
const Planet = struct {
    /// Center in level-0 block coordinates.
    center: @Vector(3, f32),
    /// Mean sphere radius in blocks; the surface sits at radius + bump.
    radius: f32,
    /// Upper bound of the surface bump in blocks (radius * 0.05).
    bump_amp: f32,
    /// d2 <= stone_floor_sq guarantees deep stone for any bump.
    stone_floor_sq: f32,
    /// d2 > solid_ceiling_sq guarantees outside the solid surface for any bump.
    solid_ceiling_sq: f32,
    /// d2 <= sea_sq places water.
    sea_sq: f32,
};

pub const Generator = struct {
    pub const Noise = @import("fastnoise.zig");

    params: Params,
    /// Planet radius upper bound, clamped to box_size / 2 so the sphere always
    /// fits inside its grid cell.
    max_radius: i32,
    placer: Grid,
    /// Level passed to placer.getStructure; scale == box_size, so querying the
    /// cell origin always satisfies the in-range check (jitter < box_size).
    placer_level: u5,
    /// Cell index bound that keeps the placer arithmetic inside i32.
    safe_cell: i32,
    /// Grid cell containing the origin, guaranteed to hold the spawn planet.
    spawn_cell: @Vector(3, i32),

    pub const Params = struct {
        seed: ?u64 = null,
        /// Percentage of grid cells that hold a planet.
        density: u32 = 40,
        /// Planet grid cell size in level-0 chunks; rounded up to a power of two.
        box_size: i32 = 4096,
        /// Planet radius upper bound in level-0 chunks.
        max_radius: i32 = 1024,
        /// Places a guaranteed planet near the origin so the player spawns above a world.
        spawn_planet: bool = true,
        water: bool = true,
        stars: bool = true,
        /// Surface bump used to sculpt continents on the planets.
        surface_noise: Noise.Noise(f32) = .{
            .seed = 0,
            .frequency = 0.0004,
            .noise_type = .perlin,
            .octaves = 1,
        },

        pub const default: Params = .{};

        pub fn setSeeds(self: *Params, io: std.Io) void {
            if (self.seed == null) {
                var random_seed: u64 = undefined;
                io.random(@ptrCast(&random_seed));
                self.seed = random_seed;
            }
            self.surface_noise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(self.seed.? +% 3));
        }
    };

    pub fn init(allocator: std.mem.Allocator, max_cache_bytes: usize, params: Params) Generator {
        _ = allocator;
        _ = max_cache_bytes;
        const box: u32 = nextPowerOfTwo(u32, @intCast(std.math.clamp(params.box_size, 1024, 16384)));
        const max_radius: i32 = @intCast(@min(@as(u32, @intCast(params.max_radius)), box / 2));
        return .{
            .params = params,
            .max_radius = max_radius,
            .placer = .{
                .box_size = @intCast(box),
                .inner_box_size = @intCast(box / 2),
            },
            .placer_level = @intCast(@ctz(box)),
            .safe_cell = @intCast(@divTrunc(@as(i64, std.math.maxInt(i32)) - 1, box)),
            .spawn_cell = @splat(@intCast(@divTrunc(@as(i64, grid_shift), @as(i64, box)))),
        };
    }

    pub fn getSource(self: *Generator) World.ChunkSource {
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
        _ = allocator;
        _ = world;
        const self: *Generator = @ptrCast(@alignCast(source.data));
        self.genChunk(io, blocks, chunk_pos, grid_buffer);
        return .{ .from_disk = false, .structures = false };
    }

    pub fn deinit(self: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World) void {
        _ = self;
        _ = io;
        _ = allocator;
        _ = world;
    }

    pub fn genChunk(self: *Generator, io: std.Io, blocks: *Chunk.Encoding, chunk_pos: ChunkPos, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) void {
        @setFloatMode(.optimized);
        _ = io;
        const zone = tracy.Zone.begin(.{ .src = @src() });
        defer zone.end();
        if (chunk_pos.level > 25) {
            blocks.merge(.{ .uniform = .air }, grid_buffer);
            return;
        }
        const ratio: f32 = ChunkPos.levelToBlockRatioFloat(chunk_pos.level);
        const chunk_start: @Vector(3, f32) = @floatFromInt(chunk_pos.toGlobalBlockPos());
        // Local blocks span ratio / ChunkSize level-0 blocks each (one at level 0).
        const block_step: f32 = ratio / @as(f32, ChunkSize);
        const step_v: @Vector(3, f32) = @splat(block_step);
        const half_step: @Vector(3, f32) = @splat(block_step * 0.5);
        const span = step_v * @as(@Vector(3, f32), @splat(ChunkSize));

        var block_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = comptime @splat(@splat(@splat(.null)));

        // Fast paths need every chunk corner in the same grid cell, so the
        // planet is fixed for the whole chunk.
        var corner_cells: [8]@Vector(3, i32) = undefined;
        var one_cell = true;
        inline for (0..8) |i| {
            const corner = chunk_start + cornerOffset(i) * span;
            const cell = self.cellOf(corner) orelse {
                one_cell = false;
                break;
            };
            corner_cells[i] = cell;
            if (i > 0 and !@reduce(.And, cell == corner_cells[0])) one_cell = false;
        }

        if (one_cell) {
            const cell = corner_cells[0];
            if (self.planetAt(cell)) |planet| {
                if (cornersDeepStone(chunk_start, span, planet)) {
                    blocks.merge(.{ .uniform = .stone }, grid_buffer);
                    return;
                }
                self.fillPlanetChunk(&block_grid, chunk_start, step_v, half_step, planet);
            } else {
                self.fillSpaceChunk(&block_grid, chunk_start, step_v, half_step);
            }
        } else {
            self.fillGenericChunk(&block_grid, chunk_start, step_v, half_step);
        }
        mergeGrid(blocks, &block_grid, grid_buffer);
    }

    /// Fills the chunk where every block is tested against the same planet.
    fn fillPlanetChunk(self: *const Generator, block_grid: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_start: @Vector(3, f32), step_v: @Vector(3, f32), half_step: @Vector(3, f32), planet: Planet) void {
        const span = step_v * @as(@Vector(3, f32), @splat(ChunkSize));
        if (chunkDistanceSq(chunk_start, span, planet.center).min > planet.solid_ceiling_sq) {
            // No block can be solid; only the water shell can cover the chunk.
            for (0..ChunkSize) |y| {
                for (0..ChunkSize) |z| {
                    for (0..ChunkSize) |x| {
                        const diff = blockCenter(chunk_start, step_v, half_step, x, y, z) - planet.center;
                        const d2 = @reduce(.Add, diff * diff);
                        block_grid[x][y][z] = if (d2 <= planet.sea_sq) .water else .air;
                    }
                }
            }
            return;
        }
        // The chunk intersects the surface band; sample the bump noise in one
        // vectorized pass over the whole chunk.
        var noise_grid: [ChunkSize * ChunkSize * ChunkSize]f32 = undefined;
        self.fillNoiseGrid(&noise_grid, chunk_start, half_step, step_v);
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                const noise_base = ChunkSize * (y + ChunkSize * z);
                for (0..ChunkSize) |x| {
                    const center = blockCenter(chunk_start, step_v, half_step, x, y, z);
                    block_grid[x][y][z] = planetBlock(center, planet, noise_grid[noise_base + x]);
                }
            }
        }
    }

    /// Fills the chunk where no planet can reach any block.
    fn fillSpaceChunk(self: *const Generator, block_grid: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_start: @Vector(3, f32), step_v: @Vector(3, f32), half_step: @Vector(3, f32)) void {
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                for (0..ChunkSize) |x| {
                    block_grid[x][y][z] = self.spaceBlock(blockCenter(chunk_start, step_v, half_step, x, y, z));
                }
            }
        }
    }

    /// Fills the chunk with per-block cell lookups (chunk spans multiple cells).
    fn fillGenericChunk(self: *const Generator, block_grid: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_start: @Vector(3, f32), step_v: @Vector(3, f32), half_step: @Vector(3, f32)) void {
        var noise_grid: [ChunkSize * ChunkSize * ChunkSize]f32 = undefined;
        self.fillNoiseGrid(&noise_grid, chunk_start, half_step, step_v);
        var current_planet: ?Planet = null;
        var current_cell: @Vector(3, i32) = undefined;
        var has_cell = false;
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                const noise_base = ChunkSize * (y + ChunkSize * z);
                for (0..ChunkSize) |x| {
                    const center = blockCenter(chunk_start, step_v, half_step, x, y, z);
                    const cell = self.cellOf(center) orelse {
                        block_grid[x][y][z] = self.spaceBlock(center);
                        continue;
                    };
                    if (!has_cell or !@reduce(.And, cell == current_cell)) {
                        current_cell = cell;
                        has_cell = true;
                        current_planet = self.planetAt(cell);
                    }
                    block_grid[x][y][z] = if (current_planet) |planet| planetBlock(center, planet, noise_grid[noise_base + x]) else self.spaceBlock(center);
                }
            }
        }
    }

    /// Samples the surface bump noise at the chunk's block centers.
    fn fillNoiseGrid(self: *const Generator, noise_grid: *[ChunkSize * ChunkSize * ChunkSize]f32, chunk_start: @Vector(3, f32), half_step: @Vector(3, f32), step_v: @Vector(3, f32)) void {
        self.params.surface_noise.fillGrid3D(noise_grid, ChunkSize, ChunkSize, chunk_start[0] + half_step[0], chunk_start[1] + half_step[1], chunk_start[2] + half_step[2], step_v[0]);
    }

    /// True when the whole chunk box sits inside the planet's guaranteed stone
    /// region, so every block is deep stone without per-block work. Valid for
    /// single-cell chunks: the stone region is a ball, and a box whose eight
    /// corners lie inside a ball lies entirely inside it.
    fn cornersDeepStone(chunk_start: @Vector(3, f32), span: @Vector(3, f32), planet: Planet) bool {
        inline for (0..8) |i| {
            const corner = chunk_start + cornerOffset(i) * span;
            const diff = corner - planet.center;
            const d2 = @reduce(.Add, diff * diff);
            if (d2 > planet.stone_floor_sq) return false;
        }
        return true;
    }

    /// Grid cell containing `center`, or null when the cell lies outside the
    /// safe index range where planet placement is defined.
    fn cellOf(self: *const Generator, center: @Vector(3, f32)) ?@Vector(3, i32) {
        const grid_pos = center / @as(@Vector(3, f32), @splat(@as(f32, ChunkSize))) +
            @as(@Vector(3, f32), @splat(@floatFromInt(grid_shift)));
        const cell_f = @floor(grid_pos / @as(@Vector(3, f32), @splat(@floatFromInt(self.placer.box_size))));
        const safe_f: f32 = @floatFromInt(self.safe_cell);
        if (@reduce(.Or, cell_f < @as(@Vector(3, f32), @splat(0))) or
            @reduce(.Or, cell_f > @as(@Vector(3, f32), @splat(safe_f)))) return null;
        return @intFromFloat(cell_f);
    }

    /// Planet owned by `cell`, if any. The sphere always fits inside the cell,
    /// so every block inside a planet finds it through its own cell.
    fn planetAt(self: *const Generator, cell: @Vector(3, i32)) ?Planet {
        const is_spawn_cell = @reduce(.And, cell == self.spawn_cell);
        const h = std.hash.Wyhash.hash(self.params.seed.? +% 0x9e3779b97f4a7c15, std.mem.asBytes(&cell));
        if (!is_spawn_cell and h % 100 >= self.params.density) return null;

        const box = self.placer.box_size;
        const radius_units: i32 = if (is_spawn_cell)
            @min(512, self.max_radius)
        else
            @max(32, @as(i32, @intFromFloat(@as(f32, @floatFromInt(self.max_radius)) * (0.5 + 0.5 * (@as(f32, @floatFromInt((h >> 12) & 0xFFFF)) / 65535.0)))));

        var center_units: @Vector(3, i32) = undefined;
        if (is_spawn_cell) {
            // Center at (512, 512, 512) inside the spawn cell puts the surface
            // ~375 units below the origin.
            center_units = cell * @as(@Vector(3, i32), @splat(box)) + @as(@Vector(3, i32), @splat(512));
        } else {
            const jittered = self.placer.getStructure(cell, self.placer_level).?;
            const box_v: @Vector(3, i32) = @splat(box);
            const offset = jittered - cell * box_v;
            center_units = cell * box_v + clampVector(offset, radius_units, box - radius_units);
        }

        const ocean_frac: f32 = if (self.params.water)
            0.03 + 0.07 * (@as(f32, @floatFromInt(h & 0xFF)) / 255.0)
        else
            0;
        const radius: f32 = @as(f32, @floatFromInt(radius_units)) * @as(f32, ChunkSize);
        const bump_amp: f32 = radius * 0.05;
        return .{
            .center = @as(@Vector(3, f32), @floatFromInt(center_units)) * @as(@Vector(3, f32), @splat(@as(f32, ChunkSize))) -
                @as(@Vector(3, f32), @splat(@as(f32, ChunkSize * grid_shift))),
            .radius = radius,
            .bump_amp = bump_amp,
            .stone_floor_sq = (radius - bump_amp - 5.0) * (radius - bump_amp - 5.0),
            .solid_ceiling_sq = (radius + bump_amp) * (radius + bump_amp),
            .sea_sq = (radius * (1 + ocean_frac)) * (radius * (1 + ocean_frac)),
        };
    }

    fn planetBlock(center: @Vector(3, f32), planet: Planet, surface_noise: f32) Block {
        const diff = center - planet.center;
        const d2 = @reduce(.Add, diff * diff);
        if (d2 <= planet.stone_floor_sq) return .stone;
        // Outside the bump range no block can be solid; only water or space.
        if (d2 > planet.solid_ceiling_sq) return if (d2 <= planet.sea_sq) .water else .air;
        const bump = surface_noise * planet.radius * 0.05;
        const terrain_radius = planet.radius + bump;
        if (d2 <= terrain_radius * terrain_radius) {
            const stone_r = terrain_radius - 5.0;
            const dirt_r = terrain_radius - 1.5;
            if (d2 <= stone_r * stone_r) return .stone;
            if (d2 <= dirt_r * dirt_r) return .dirt;
            if (@abs(diff[1]) > terrain_radius * 0.8) return .snow;
            return .grass;
        }
        return if (d2 <= planet.sea_sq) .water else .air;
    }

    fn spaceBlock(self: *const Generator, center: @Vector(3, f32)) Block {
        if (!self.params.stars) return .air;
        const pos: @Vector(3, i64) = @intFromFloat(center);
        const h = std.hash.Wyhash.hash(self.params.seed.? +% 0x517cc1b727220a95, std.mem.asBytes(&pos));
        return if (h % 4096 == 0) .snow else .air;
    }
};

fn clampVector(v: @Vector(3, i32), lo: i32, hi: i32) @Vector(3, i32) {
    const lo_v: @Vector(3, i32) = @splat(lo);
    const hi_v: @Vector(3, i32) = @splat(hi);
    return @min(@max(v, lo_v), hi_v);
}

fn blockCenter(chunk_start: @Vector(3, f32), step_v: @Vector(3, f32), half_step: @Vector(3, f32), x: usize, y: usize, z: usize) @Vector(3, f32) {
    return chunk_start + @as(@Vector(3, f32), .{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) }) * step_v + half_step;
}

/// Squared distance range from the chunk box to a point. The closest box point
/// is the clamped center; the farthest is a corner.
fn chunkDistanceSq(chunk_start: @Vector(3, f32), span: @Vector(3, f32), center: @Vector(3, f32)) struct { min: f32, max: f32 } {
    const lo = chunk_start;
    const hi = chunk_start + span;
    var closest: @Vector(3, f32) = undefined;
    var farthest: @Vector(3, f32) = undefined;
    inline for (0..3) |i| {
        closest[i] = std.math.clamp(center[i], lo[i], hi[i]);
        farthest[i] = if (@abs(lo[i] - center[i]) > @abs(hi[i] - center[i])) lo[i] else hi[i];
    }
    const d_min = closest - center;
    const d_max = farthest - center;
    return .{
        .min = @reduce(.Add, d_min * d_min),
        .max = @reduce(.Add, d_max * d_max),
    };
}

fn cornerOffset(comptime i: usize) @Vector(3, f32) {
    return .{ @floatFromInt(i & 1), @floatFromInt((i >> 1) & 1), @floatFromInt((i >> 2) & 1) };
}

fn mergeGrid(blocks: *Chunk.Encoding, block_grid: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) void {
    if (Chunk.getUniform(block_grid)) |uniform| {
        blocks.merge(.{ .uniform = uniform }, grid_buffer);
    } else {
        blocks.merge(.{ .grid = block_grid }, grid_buffer);
    }
}

fn nextPowerOfTwo(comptime T: type, value: T) T {
    const shift: std.math.Log2Int(T) = @intCast(@bitSizeOf(T) - @clz(value - 1));
    return @as(T, 1) << shift;
}

pub const generator_api_vtable: generator_api.GeneratorApi = .{
    .info = &generator_info,
    .create = &generator_create,
    .get_source = &generator_get_source,
    .config_default = &generator_config_default,
    .config_from_zon = &generator_config_from_zon,
    .config_set_seeds = &generator_config_set_seeds,
};

comptime {
    // Multiple generators export the same symbol, so test binaries that link
    // more than one of them must skip the exports.
    if (!builtin.is_test) @export(&generator_api_vtable, .{ .name = generator_api.api_export_name });
}

const field_specs = .{
    .seed = .{ .is_seed = true },
    .density = .{ .min = 1, .max = 100 },
    .box_size = .{ .min = 1024, .max = 16384 },
    .max_radius = .{ .min = 128, .max = 1024 },
    .frequency = .{ .min = 0, .max = 0.5 },
    .octaves = .{ .min = 1, .max = 16 },
    .lacunarity = .{ .min = 1, .max = 4 },
    .gain = .{ .min = 0, .max = 1 },
};

const PlanetInstance = struct {
    generator: Generator,
    source: World.ChunkSource,
};

const generator_info_data: generator_api.GeneratorInfo = .{
    .name = "Planets",
    .description = "Spherical planets scattered in space",
    .version = 1,
    .api_version = generator_api.ApiVersion,
};

pub fn generator_info() callconv(.c) *const generator_api.GeneratorInfo {
    return &generator_info_data;
}

pub fn generator_config_default(allocator: *const std.mem.Allocator) callconv(.c) ?*generator_api.ConfigTree {
    return generator_api.fromStruct(Generator.Params, allocator.*, &Generator.Params.default, field_specs) catch null;
}

pub fn generator_config_from_zon(allocator: *const std.mem.Allocator, bytes: [*]const u8, bytes_len: usize) callconv(.c) ?*generator_api.ConfigTree {
    @setEvalBranchQuota(100000000);
    var arena = std.heap.ArenaAllocator.init(allocator.*);
    defer arena.deinit();
    const params = std.zon.parse.fromSliceAlloc(Generator.Params, arena.allocator(), bytes[0..bytes_len :0], null, .{}) catch return null;
    return generator_api.fromStruct(Generator.Params, allocator.*, &params, field_specs) catch null;
}

pub fn generator_config_set_seeds(io: *const std.Io, config: *generator_api.ConfigTree) callconv(.c) void {
    var random_seed: u64 = undefined;
    io.*.random(@ptrCast(&random_seed));
    for (config.params) |*param| {
        if (param.spec.is_seed and param.value == .u64 and param.value.u64 == 0) {
            param.value.u64 = random_seed;
        }
    }
}

pub fn generator_create(opts: *const generator_api.CreateOptions, config: *const generator_api.ConfigTree) callconv(.c) ?*anyopaque {
    var params: Generator.Params = .default;
    generator_api.fromTree(Generator.Params, opts.allocator, config, &params, field_specs) catch return null;
    if (params.seed == null) params.setSeeds(opts.io);
    const instance = opts.allocator.create(PlanetInstance) catch return null;
    errdefer opts.allocator.destroy(instance);
    instance.* = .{
        .generator = Generator.init(opts.allocator, opts.max_cache_bytes, params),
        .source = undefined,
    };
    instance.source = .{
        .data = instance,
        .getTerrainHeight = null,
        .getBlocks = &instanceGenBlocks,
        .placeStructures = null,
        .deinit = &instanceDeinit,
        .save = null,
    };
    return instance;
}

pub fn generator_get_source(instance: *anyopaque) callconv(.c) *const World.ChunkSource {
    const self: *PlanetInstance = @ptrCast(@alignCast(instance));
    return &self.source;
}

fn instanceGenBlocks(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, blocks: *Chunk.Encoding, chunk_pos: ChunkPos, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) error{ Unrecoverable, OutOfMemory, Canceled }!?World.ChunkSource.GetBlocksMetadata {
    _ = allocator;
    _ = world;
    const self: *PlanetInstance = @ptrCast(@alignCast(source.data));
    self.generator.genChunk(io, blocks, chunk_pos, grid_buffer);
    return .{ .from_disk = false, .structures = false };
}

fn instanceDeinit(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World) void {
    _ = io;
    _ = world;
    const self: *PlanetInstance = @ptrCast(@alignCast(source.data));
    allocator.destroy(self);
}

test "planet spheres stay inside their cell" {
    var params: Generator.Params = .default;
    params.seed = 42;
    params.setSeeds(std.testing.io);
    const gen = Generator.init(std.testing.allocator, 0, params);
    var rng = std.Random.DefaultPrng.init(7);
    const rand = rng.random();
    for (0..2000) |_| {
        const cell = @Vector(3, i32){
            rand.intRangeAtMost(i32, 0, 200),
            rand.intRangeAtMost(i32, 0, 200),
            rand.intRangeAtMost(i32, 0, 200),
        };
        const planet = gen.planetAt(cell) orelse continue;
        const box = gen.placer.box_size;
        const shifted_center: @Vector(3, i32) = @intFromFloat(
            planet.center / @as(@Vector(3, f32), @splat(@as(f32, ChunkSize))) +
                @as(@Vector(3, f32), @splat(@floatFromInt(grid_shift))),
        );
        const radius_units: i32 = @intFromFloat(planet.radius / @as(f32, ChunkSize));
        inline for (0..3) |i| {
            try std.testing.expect(shifted_center[i] >= cell[i] * box + radius_units);
            try std.testing.expect(shifted_center[i] <= (cell[i] + 1) * box - radius_units);
        }
    }
}

test "spawn planet sits below the origin" {
    var params: Generator.Params = .default;
    params.seed = 42;
    params.setSeeds(std.testing.io);
    const gen = Generator.init(std.testing.allocator, 0, params);
    const planet = gen.planetAt(gen.spawn_cell).?;
    const diff = -planet.center;
    const d2 = @reduce(.Add, diff * diff);
    try std.testing.expect(d2 > planet.radius * planet.radius);
    const d = @sqrt(d2);
    try std.testing.expect(d - planet.radius < 400.0 * @as(f32, ChunkSize));
}

test "genChunk fills the spawn planet with stone" {
    var blocks: Chunk.Encoding = .{ .uniform = .air };
    var grid_buffer: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = undefined;
    var params: Generator.Params = .default;
    params.seed = 42;
    params.setSeeds(std.testing.io);
    var gen = Generator.init(std.testing.allocator, 0, params);
    gen.genChunk(std.testing.io, &blocks, .{ .level = 0, .position = .{ 500, 500, 500 } }, &grid_buffer);
    blocks.toGrid(&grid_buffer);
    try std.testing.expectEqual(Block.stone, grid_buffer[0][0][0]);
}
