const std = @import("std");
const builtin = @import("builtin");

const tracy = @import("tracy");

const Block = @import("../Block.zig").Block;
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const JitteredGrid = @import("../structures/JitteredGrid.zig").JitteredGrid;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;
const generator_api = @import("generator_api.zig");

/// Planet placement grid. One grid unit is one level-0 chunk (ChunkSize blocks).
const Grid = JitteredGrid(3, i32);

/// Shifts the grid positive: lookups fail for negative cells.
const grid_shift: i32 = 1 << 20;
/// Chunks above this level are empty space.
const max_level = 25;
/// Surface bump amplitude as a fraction of the planet radius.
const bump_fraction = 0.05;
/// Stone starts this many blocks below the surface.
const stone_depth = 5.0;

const Planet = struct {
    /// Center in level-0 block coordinates.
    center: @Vector(3, f32),
    /// Mean sphere radius in blocks. The surface sits at radius + bump.
    radius: f32,
    /// Upper bound of the surface bump in blocks (radius * bump_fraction).
    bump_amp: f32,
    /// d2 <= stone_floor_sq guarantees deep stone for any bump.
    stone_floor_sq: f32,
    /// d2 > solid_ceiling_sq guarantees outside the solid surface for any bump.
    solid_ceiling_sq: f32,
    /// d2 <= sea_sq places water.
    sea_sq: f32,
};

pub const Generator = struct {
    pub const Noise = @import("fastnoise");

    params: Params,
    seed: u64,
    /// Planet radius upper bound, clamped to box_size / 2 so the sphere always
    /// fits inside its grid cell.
    max_radius: i32,
    placer: Grid,
    /// Level passed to placer.getStructure. Its scale equals box_size, so a query at
    /// the cell origin always passes the in-range check (jitter < box_size).
    placer_level: u5,
    /// Cell index bound that keeps the placer arithmetic inside i32.
    safe_cell: i32,
    /// Grid cell containing the origin, guaranteed to hold the spawn planet.
    spawn_cell: @Vector(3, i32),

    pub const Params = struct {
        /// The host fills a null seed before create.
        seed: ?u64 = null,
        /// Percentage of grid cells that hold a planet.
        density: u32 = 40,
        /// Planet grid cell size in level-0 chunks, rounded up to a power of two.
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
    };

    pub fn init(params: Params, seed: u64) Generator {
        var seeded = params;
        seeded.surface_noise.seed ^= @bitCast(std.hash.Murmur2_32.hashUint64(seed +% 3));
        const box: u32 = std.math.ceilPowerOfTwoAssert(u32, @intCast(std.math.clamp(params.box_size, 1024, 16384)));
        const max_radius: i32 = @intCast(@min(@as(u32, @intCast(params.max_radius)), box / 2));
        return .{
            .params = seeded,
            .seed = seed,
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

    pub fn genChunk(self: *Generator, _: std.Io, blocks: *Chunk.Encoding, chunk_pos: ChunkPos, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) void {
        @setFloatMode(.optimized);
        const zone = tracy.Zone.begin(.{ .src = @src() });
        defer zone.end();
        if (chunk_pos.level > max_level) return blocks.mergeUniform(.air);
        const ratio: f32 = ChunkPos.levelToBlockRatioFloat(chunk_pos.level);
        const sampler: ChunkSampler = .{
            .start = @as(@Vector(3, f32), @floatFromInt(chunk_pos.position)) * @as(@Vector(3, f32), @splat(ratio)),
            .step = @splat(ratio / @as(f32, ChunkSize)),
        };

        var block_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = undefined;
        if (self.chunkCell(sampler)) |cell| {
            if (self.planetAt(cell)) |planet| {
                if (sampler.insideBall(planet.center, planet.stone_floor_sq)) return blocks.mergeUniform(.stone);
                self.fillPlanetChunk(&block_grid, sampler, planet);
            } else {
                self.fillSpaceChunk(&block_grid, sampler);
            }
        } else {
            self.fillGenericChunk(&block_grid, sampler);
        }
        if (Chunk.getUniform(&block_grid)) |block| blocks.mergeUniform(block) else blocks.mergeGrid(&block_grid, grid_buffer);
    }

    /// Grid cell that holds the whole chunk, or null when the chunk spans
    /// several cells or leaves the safe range. Cells are boxes, so the two
    /// extreme corners decide.
    fn chunkCell(self: *const Generator, sampler: ChunkSampler) ?@Vector(3, i32) {
        const first = self.cellOf(sampler.start) orelse return null;
        const last = self.cellOf(sampler.start + sampler.span()) orelse return null;
        return if (@reduce(.And, first == last)) first else null;
    }

    fn fillPlanetChunk(self: *const Generator, block_grid: *[ChunkSize][ChunkSize][ChunkSize]Block, sampler: ChunkSampler, planet: Planet) void {
        if (sampler.distanceSq(planet.center) > planet.solid_ceiling_sq) {
            // No block can be solid. Only the water shell can cover the chunk.
            for (0..ChunkSize) |y| {
                for (0..ChunkSize) |z| {
                    for (0..ChunkSize) |x| {
                        const diff = sampler.blockCenter(x, y, z) - planet.center;
                        block_grid[x][y][z] = if (@reduce(.Add, diff * diff) <= planet.sea_sq) .water else .air;
                    }
                }
            }
            return;
        }
        // The chunk intersects the surface band. Sample the bump noise in one
        // vectorized pass over the whole chunk.
        var noise_grid: [ChunkSize * ChunkSize * ChunkSize]f32 = undefined;
        self.fillNoiseGrid(&noise_grid, sampler);
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                const noise_row = noise_grid[ChunkSize * (y + ChunkSize * z) ..][0..ChunkSize];
                for (noise_row, 0..) |noise, x| {
                    block_grid[x][y][z] = planetBlock(sampler.blockCenter(x, y, z), planet, noise);
                }
            }
        }
    }

    fn fillSpaceChunk(self: *const Generator, block_grid: *[ChunkSize][ChunkSize][ChunkSize]Block, sampler: ChunkSampler) void {
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                for (0..ChunkSize) |x| {
                    block_grid[x][y][z] = self.spaceBlock(sampler.blockCenter(x, y, z));
                }
            }
        }
    }

    fn fillGenericChunk(self: *const Generator, block_grid: *[ChunkSize][ChunkSize][ChunkSize]Block, sampler: ChunkSampler) void {
        var noise_grid: [ChunkSize * ChunkSize * ChunkSize]f32 = undefined;
        self.fillNoiseGrid(&noise_grid, sampler);
        var current_planet: ?Planet = null;
        var current_cell: ?@Vector(3, i32) = null;
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                const noise_row = noise_grid[ChunkSize * (y + ChunkSize * z) ..][0..ChunkSize];
                for (noise_row, 0..) |noise, x| {
                    const center = sampler.blockCenter(x, y, z);
                    const cell = self.cellOf(center) orelse {
                        block_grid[x][y][z] = self.spaceBlock(center);
                        continue;
                    };
                    if (current_cell == null or !@reduce(.And, cell == current_cell.?)) {
                        current_cell = cell;
                        current_planet = self.planetAt(cell);
                    }
                    block_grid[x][y][z] = if (current_planet) |planet| planetBlock(center, planet, noise) else self.spaceBlock(center);
                }
            }
        }
    }

    fn fillNoiseGrid(self: *const Generator, noise_grid: *[ChunkSize * ChunkSize * ChunkSize]f32, sampler: ChunkSampler) void {
        const origin = sampler.blockCenter(0, 0, 0);
        self.params.surface_noise.fillGrid3D(noise_grid, ChunkSize, ChunkSize, origin[0], origin[1], origin[2], sampler.step[0]);
    }

    /// Grid cell containing `center`, or null when the cell lies outside the
    /// safe index range that planet placement supports.
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
        const h = std.hash.Wyhash.hash(self.seed +% 0x9e3779b97f4a7c15, std.mem.asBytes(&cell));
        if (!is_spawn_cell and h % 100 >= self.params.density) return null;

        const box = self.placer.box_size;
        const radius_units: i32 = if (is_spawn_cell)
            @min(512, self.max_radius)
        else
            @max(32, @as(i32, @intFromFloat(@as(f32, @floatFromInt(self.max_radius)) * (0.5 + 0.5 * (@as(f32, @floatFromInt((h >> 12) & 0xFFFF)) / 65535.0)))));

        const cell_origin = cell * @as(@Vector(3, i32), @splat(box));
        // Center at (512, 512, 512) inside the spawn cell puts the surface
        // ~375 units below the origin.
        const offset: @Vector(3, i32) = if (is_spawn_cell) @splat(512) else std.math.clamp(
            self.placer.getStructure(cell, self.placer_level).? - cell_origin,
            @as(@Vector(3, i32), @splat(radius_units)),
            @as(@Vector(3, i32), @splat(box - radius_units)),
        );
        const center_units = cell_origin + offset;

        // Bump peaks near 5%, so higher fractions drown the planet. Spawn stays at 1-3% for landing islands.
        const ocean_frac: f32 = if (self.params.water)
            (if (is_spawn_cell) @as(f32, 0.01) else 0.03) + (if (is_spawn_cell) @as(f32, 0.02) else 0.07) * (@as(f32, @floatFromInt(h & 0xFF)) / 255.0)
        else
            0;
        const radius: f32 = @as(f32, @floatFromInt(radius_units)) * @as(f32, ChunkSize);
        const bump_amp: f32 = radius * bump_fraction;
        return .{
            .center = @as(@Vector(3, f32), @floatFromInt(center_units)) * @as(@Vector(3, f32), @splat(@as(f32, ChunkSize))) -
                @as(@Vector(3, f32), @splat(@as(f32, ChunkSize * grid_shift))),
            .radius = radius,
            .bump_amp = bump_amp,
            .stone_floor_sq = (radius - bump_amp - stone_depth) * (radius - bump_amp - stone_depth),
            .solid_ceiling_sq = (radius + bump_amp) * (radius + bump_amp),
            .sea_sq = (radius * (1 + ocean_frac)) * (radius * (1 + ocean_frac)),
        };
    }

    fn planetBlock(center: @Vector(3, f32), planet: Planet, surface_noise: f32) Block {
        const diff = center - planet.center;
        const d2 = @reduce(.Add, diff * diff);
        if (d2 <= planet.stone_floor_sq) return .stone;
        // Outside the bump range no block can be solid, so only water or space remains.
        if (d2 > planet.solid_ceiling_sq) return if (d2 <= planet.sea_sq) .water else .air;
        const terrain_radius = planet.radius + surface_noise * planet.bump_amp;
        if (d2 <= terrain_radius * terrain_radius) {
            const stone_r = terrain_radius - stone_depth;
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
        const h = std.hash.Wyhash.hash(self.seed +% 0x517cc1b727220a95, std.mem.asBytes(&pos));
        return if (h % 4096 == 0) .snow else .air;
    }
};

/// Block cells of one chunk in level-0 block coordinates.
const ChunkSampler = struct {
    /// Minimum corner of the chunk.
    start: @Vector(3, f32),
    /// Cell size on each axis.
    step: @Vector(3, f32),

    fn span(self: ChunkSampler) @Vector(3, f32) {
        return self.step * @as(@Vector(3, f32), @splat(ChunkSize));
    }

    fn blockCenter(self: ChunkSampler, x: usize, y: usize, z: usize) @Vector(3, f32) {
        const index: @Vector(3, f32) = .{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
        return self.start + (index + @as(@Vector(3, f32), @splat(0.5))) * self.step;
    }

    /// Squared distance from `point` to the nearest point of the chunk box.
    fn distanceSq(self: ChunkSampler, point: @Vector(3, f32)) f32 {
        const gap = std.math.clamp(point, self.start, self.start + self.span()) - point;
        return @reduce(.Add, gap * gap);
    }

    /// True when the whole chunk box lies inside the ball. The farthest
    /// corner takes the larger gap on each axis.
    fn insideBall(self: ChunkSampler, center: @Vector(3, f32), radius_sq: f32) bool {
        const far = @max(@abs(self.start - center), @abs(self.start + self.span() - center));
        return @reduce(.Add, far * far) <= radius_sq;
    }
};

/// Nearest planet surface to `point`, searching expanding cell rings so a
/// `0` radius still means "closest" while guaranteeing escape from voids.
fn nearestPlanet(self: *const Generator, point: @Vector(3, f32)) ?Planet {
    const base = self.cellOf(point) orelse self.spawn_cell;
    var best: ?Planet = null;
    var best_gap: f32 = std.math.inf(f32);
    var ring: i32 = 0;
    while (ring <= 2) : (ring += 1) {
        var dx: i32 = -ring;
        while (dx <= ring) : (dx += 1) {
            var dy: i32 = -ring;
            while (dy <= ring) : (dy += 1) {
                var dz: i32 = -ring;
                while (dz <= ring) : (dz += 1) {
                    if (@max(@abs(dx), @max(@abs(dy), @abs(dz))) != ring) continue;
                    const cell = base + @Vector(3, i32){ dx, dy, dz };
                    // Planet placement fails outside the safe range: jitter
                    // lookups miss, and cell*box can overflow i32.
                    if (@reduce(.Or, cell < @as(@Vector(3, i32), @splat(0))) or
                        @reduce(.Or, cell > @as(@Vector(3, i32), @splat(self.safe_cell)))) continue;
                    const planet = self.planetAt(cell) orelse continue;
                    const diff = planet.center - point;
                    const gap = @sqrt(@reduce(.Add, diff * diff)) - planet.radius;
                    if (gap < best_gap) {
                        best_gap = gap;
                        best = planet;
                    }
                }
            }
        }
        if (best != null) return best;
    }
    if (self.params.spawn_planet) return self.planetAt(self.spawn_cell);
    return best;
}

/// Exact column top from real block walks, so noise and water agree with the world.
/// Analytic samples fail near the limb, where bump error amplifies manyfold.
fn planetColumnTop(self: *const Generator, planet: Planet, x: f32, z: f32) ?struct { top: f32, wet: bool } {
    const ddx = x - planet.center[0];
    const ddz = z - planet.center[2];
    const hd_sq = ddx * ddx + ddz * ddz;
    const reach = planet.radius + planet.bump_amp;
    if (hd_sq > reach * reach) return null;
    // The surface can sit anywhere on the chord, so the walk spans it and stops at the first solid.
    const half_chord = @sqrt(reach * reach - hd_sq);
    var y = planet.center[1] + half_chord + 4.0;
    const bottom = planet.center[1] - half_chord - 4.0;
    var wet = false;
    // First solid from the top is the surface: no caves or floaters exist
    // in `planetBlock`, and the host enforces player-box clearance itself.
    while (y >= bottom) : (y -= 1.0) {
        const block = Generator.planetBlock(.{ x, y, z }, planet, self.params.surface_noise.genNoise3D(x, y, z));
        if (block == .water) wet = true;
        if (block.isSolid()) return .{ .top = y, .wet = wet };
    }
    return null;
}
/// Near-side uniform sample. The anchor cap can be all ocean, so hit odds equal land fraction.
fn sphereSample(seed: u64, nonce: u64, i: u32, planet: Planet, facing: @Vector(3, f32)) [2]f64 {
    var hasher = std.hash.Wyhash.init(seed ^ nonce ^ 0x51ab129de09339a3 ^ @as(u64, i));
    const fracs = generator_api.hashFracs(hasher.final());
    const z_dir: f32 = @floatCast(2.0 * fracs[0] - 1.0);
    const ring_r: f32 = @sqrt(@max(1.0 - z_dir * z_dir, 0.0));
    const phi: f32 = @floatCast(std.math.tau * fracs[1]);
    var dir = @Vector(3, f32){ ring_r * @cos(phi), z_dir, ring_r * @sin(phi) };
    if (@reduce(.Add, dir * facing) < 0) dir = -dir;
    const surf = planet.center + dir * @as(@Vector(3, f32), @splat(planet.radius));
    return .{ surf[0], surf[2] };
}

/// Scores one sampled planet column into `best`, keeping wet/steep losers so ocean seeds still return a point.
fn considerPlanetColumn(gen: *const Generator, planet: Planet, center: *const [3]f64, sample: [2]f64, best: *generator_api.SpawnBest) void {
    const column = planetColumnTop(gen, planet, @floatCast(sample[0]), @floatCast(sample[1])) orelse return;
    generator_api.considerSpawnColumn(center, sample, if (column.wet) -1.0 else 2.0, 0, column.top, 0, true, best);
}

pub fn generator_propose_spawn(instance: *anyopaque, center: *const [3]f64, radius: f64, attempts: u32, nonce: u64) callconv(.c) generator_api.Spawnpoint {
    const self: *PlanetInstance = @ptrCast(@alignCast(instance));
    const seed = self.generator.seed;
    const point: @Vector(3, f32) = .{ @floatCast(center[0]), @floatCast(center[1]), @floatCast(center[2]) };
    const planet = nearestPlanet(&self.generator, point) orelse return generator_api.no_spawn;
    // Blind discs rarely hit small spheres, so anchor the search on the surface point nearest the request.
    const to_point = point - planet.center;
    const dist = @max(@sqrt(@reduce(.Add, to_point * to_point)), 1e-6);
    const anchor = planet.center + to_point / @as(@Vector(3, f32), @splat(dist)) * @as(@Vector(3, f32), @splat(planet.radius));
    var best: generator_api.SpawnBest = .{};
    // Discs around the anchor honor `radius`. The host checks the winner again.
    const disc_budget = @min(attempts, 8 * generator_api.spawn_samples_per_ring);
    for (0..disc_budget) |i| {
        considerPlanetColumn(&self.generator, planet, center, generator_api.spawnSample(seed, .{ anchor[0], anchor[2] }, radius, nonce, @intCast(i)), &best);
        if (i >= generator_api.spawn_samples_per_ring - 1 and best.good) break;
    }
    if (!best.good) {
        const sphere_budget = @min(attempts, generator_api.spawn_attempt_cap);
        for (0..sphere_budget) |i| {
            considerPlanetColumn(&self.generator, planet, center, sphereSample(seed, nonce, @intCast(i), planet, to_point), &best);
        }
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
    .density = .{ .label = "Planet Density", .min = 1, .max = 100 },
    .box_size = .{ .label = "Planet Cell Size", .min = 1024, .max = 16384 },
    .max_radius = .{ .label = "Maximum Radius", .min = 128, .max = 1024 },
    .spawn_planet = .{ .label = "Spawn Planet", .description = "Guarantees a planet near the starting position." },
    .water = .{ .label = "Water" },
    .stars = .{ .label = "Stars" },
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

const planet_presets = [_]Generator.Params{
    .default,
    blk: {
        var p = Generator.Params.default;
        p.density = 80;
        p.box_size = 2048;
        p.max_radius = 384;
        break :blk p;
    },
    blk: {
        var p = Generator.Params.default;
        p.density = 15;
        p.box_size = 8192;
        p.max_radius = 1024;
        break :blk p;
    },
};
const planet_preset_names = [_][]const u8{ "Default", "Dense Worlds", "Giant Worlds" };
const planet_preset_default: usize = 0;

pub fn generator_preset_count() callconv(.c) usize {
    return planet_presets.len;
}

pub fn generator_preset_name(index: usize) callconv(.c) *const []const u8 {
    return &planet_preset_names[index];
}

pub fn generator_preset_default_index() callconv(.c) usize {
    return planet_preset_default;
}

pub fn generator_preset_config(allocator: *const std.mem.Allocator, index: usize) callconv(.c) ?*generator_api.ConfigTree {
    return generator_api.presetConfig(Generator.Params, field_specs, &planet_presets, allocator, index);
}

pub fn generator_config_from_zon(allocator: *const std.mem.Allocator, bytes: [*]const u8, bytes_len: usize) callconv(.c) ?*generator_api.ConfigTree {
    return generator_api.configFromZon(Generator.Params, field_specs, allocator, bytes, bytes_len);
}

pub fn generator_config_set_seeds(io: *const std.Io, config: *generator_api.ConfigTree) callconv(.c) void {
    generator_api.configSetSeeds(io, config);
}

pub fn generator_create(opts: *const generator_api.CreateOptions, config: *const generator_api.ConfigTree) callconv(.c) ?*anyopaque {
    var params: Generator.Params = .default;
    generator_api.fromTree(Generator.Params, opts.allocator, config, &params, field_specs) catch return null;
    const seed = params.seed orelse return null;
    const instance = opts.allocator.create(PlanetInstance) catch return null;
    errdefer opts.allocator.destroy(instance);
    instance.* = .{
        .generator = Generator.init(params, seed),
        .source = undefined,
    };
    instance.source = .{
        .data = instance,
        .getTerrainHeight = null,
        .getBlocks = generator_api.instanceGenBlocks(PlanetInstance),
        .placeStructures = null,
        .deinit = generator_api.instanceDeinit(PlanetInstance),
        .save = null,
    };
    return instance;
}

pub fn generator_get_source(instance: *anyopaque) callconv(.c) *const World.ChunkSource {
    return generator_api.getSource(PlanetInstance, instance);
}

test "planet spheres stay inside their cell" {
    const gen = Generator.init(.default, 42);
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
        const radius_units: @Vector(3, i32) = @splat(@intFromFloat(planet.radius / @as(f32, ChunkSize)));
        const cell_origin = cell * @as(@Vector(3, i32), @splat(box));
        try std.testing.expect(@reduce(.And, shifted_center >= cell_origin + radius_units));
        try std.testing.expect(@reduce(.And, shifted_center <= cell_origin + @as(@Vector(3, i32), @splat(box)) - radius_units));
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "spawn planet sits below the origin" {
    const gen = Generator.init(.default, 42);
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
    var gen = Generator.init(.default, 42);
    gen.genChunk(std.testing.io, &blocks, .{ .level = 0, .position = .{ 500, 500, 500 } }, &grid_buffer);
    blocks.toGrid(&grid_buffer);
    try std.testing.expectEqual(Block.stone, grid_buffer[0][0][0]);
}

test "proposeSpawn lands on the spawn planet" {
    // Dry planet: every surface column passes, so the result is fully
    // determined by the anchor + first ring.
    const gen = Generator.init(.{ .water = false }, 42);
    var instance = PlanetInstance{ .generator = gen, .source = undefined };
    const center = [3]f64{ 0, 0, 0 };
    const a = generator_propose_spawn(&instance, &center, 0, 32, 1);
    const b = generator_propose_spawn(&instance, &center, 0, 32, 1);
    try std.testing.expect(a.found);
    try std.testing.expectEqual(a.pos, b.pos);
    const planet = gen.planetAt(gen.spawn_cell).?;
    const reach: f64 = @as(f64, planet.radius + planet.bump_amp);
    const dx: f64 = a.pos[0] - @as(f64, planet.center[0]);
    const dy: f64 = a.pos[1] - @as(f64, planet.center[1]);
    const dz: f64 = a.pos[2] - @as(f64, planet.center[2]);
    try std.testing.expect(@abs(dx) <= reach);
    try std.testing.expect(@abs(dy) <= reach + 8.0);
    try std.testing.expect(@abs(dz) <= reach);
}
