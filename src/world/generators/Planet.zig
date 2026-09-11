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
    pub const Noise = @import("fastnoise");

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
                io.random(std.mem.asBytes(&random_seed));
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
        const chunk_start: @Vector(3, f32) = @as(@Vector(3, f32), @floatFromInt(chunk_pos.position)) * @as(@Vector(3, f32), @splat(ratio));
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

    fn fillPlanetChunk(self: *const Generator, block_grid: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_start: @Vector(3, f32), step_v: @Vector(3, f32), half_step: @Vector(3, f32), planet: Planet) void {
        const span = step_v * @as(@Vector(3, f32), @splat(ChunkSize));
        if (chunkDistanceSq(chunk_start, span, planet.center) > planet.solid_ceiling_sq) {
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

    fn fillSpaceChunk(self: *const Generator, block_grid: *[ChunkSize][ChunkSize][ChunkSize]Block, chunk_start: @Vector(3, f32), step_v: @Vector(3, f32), half_step: @Vector(3, f32)) void {
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                for (0..ChunkSize) |x| {
                    block_grid[x][y][z] = self.spaceBlock(blockCenter(chunk_start, step_v, half_step, x, y, z));
                }
            }
        }
    }

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

    fn fillNoiseGrid(self: *const Generator, noise_grid: *[ChunkSize * ChunkSize * ChunkSize]f32, chunk_start: @Vector(3, f32), half_step: @Vector(3, f32), step_v: @Vector(3, f32)) void {
        self.params.surface_noise.fillGrid3D(noise_grid, ChunkSize, ChunkSize, chunk_start[0] + half_step[0], chunk_start[1] + half_step[1], chunk_start[2] + half_step[2], step_v[0]);
    }

    /// True when the whole chunk sits inside the guaranteed stone ball. A box
    /// whose eight corners lie inside a ball lies entirely inside it.
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

        // Bump peaks near 5%, so higher fractions drown the planet. Spawn stays at 1-3% for landing islands.
        const ocean_frac: f32 = if (self.params.water)
            (if (is_spawn_cell) @as(f32, 0.01) else 0.03) + (if (is_spawn_cell) @as(f32, 0.02) else 0.07) * (@as(f32, @floatFromInt(h & 0xFF)) / 255.0)
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

fn chunkDistanceSq(chunk_start: @Vector(3, f32), span: @Vector(3, f32), center: @Vector(3, f32)) f32 {
    const lo = chunk_start;
    const hi = chunk_start + span;
    var closest: @Vector(3, f32) = undefined;
    inline for (0..3) |i| {
        closest[i] = std.math.clamp(center[i], lo[i], hi[i]);
    }
    const d_min = closest - center;
    return @reduce(.Add, d_min * d_min);
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
                    // Outside the safe range planet placement is undefined
                    // (jitter lookups miss, cell*box can overflow i32).
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

const SpawnBest = struct {
    point: generator_api.Spawnpoint = .{ .pos = .{ 0, 0, 0 }, .found = false },
    score: f64 = std.math.inf(f64),
    good: bool = false,
};

/// Surface point nearest the request. Blind discs rarely hit small spheres, so the search anchors here.
fn anchorPlanet(planet: Planet, point: @Vector(3, f32)) @Vector(3, f32) {
    const to_point = point - planet.center;
    const dist = @max(@sqrt(@reduce(.Add, to_point * to_point)), 1e-6);
    return planet.center + to_point / @as(@Vector(3, f32), @splat(dist)) * @as(@Vector(3, f32), @splat(planet.radius));
}

/// Near-side uniform sample. The anchor cap can be all ocean, so hit odds equal land fraction.
fn sphereSample(seed: u64, nonce: u64, i: u32, planet: Planet, facing: @Vector(3, f32)) [2]f64 {
    var hasher = std.hash.Wyhash.init(seed ^ nonce ^ 0x51ab129de09339a3 ^ @as(u64, i));
    const hu = hasher.final();
    const frac_a: f64 = @as(f64, @floatFromInt(hu & 0xFFFFFFFF)) / 4294967296.0;
    const frac_b: f64 = @as(f64, @floatFromInt(hu >> 32)) / 4294967296.0;
    const z_dir: f32 = @floatCast(2.0 * frac_a - 1.0);
    const ring_r: f32 = @sqrt(@max(1.0 - z_dir * z_dir, 0.0));
    const phi: f32 = @floatCast(std.math.tau * frac_b);
    var dir = @Vector(3, f32){ ring_r * @cos(phi), z_dir, ring_r * @sin(phi) };
    if (@reduce(.Add, dir * facing) < 0) dir = -dir;
    const surf = planet.center + dir * @as(@Vector(3, f32), @splat(planet.radius));
    return .{ surf[0], surf[2] };
}

fn considerPlanetColumn(gen: *const Generator, planet: Planet, center: *const [3]f64, sample: [2]f64, best: *SpawnBest) void {
    const column = planetColumnTop(gen, planet, @floatCast(sample[0]), @floatCast(sample[1])) orelse return;
    const dx = sample[0] - center[0];
    const dz = sample[1] - center[2];
    const scored = generator_api.scoreSpawnColumn(@sqrt(dx * dx + dz * dz), if (column.wet) -1.0 else 2.0, 0);
    if (scored.score < best.score) {
        best.score = scored.score;
        best.point = .{ .pos = .{ sample[0], @as(f64, column.top) + generator_api.spawn_hint_clearance, sample[1] }, .found = true };
        best.good = !scored.wet and !scored.steep;
    }
}

pub fn generator_propose_spawn(instance: *anyopaque, center: *const [3]f64, radius: f64, attempts: u32, nonce: u64) callconv(.c) generator_api.Spawnpoint {
    const self: *PlanetInstance = @ptrCast(@alignCast(instance));
    const seed = self.generator.params.seed orelse return generator_api.no_spawn;
    const point: @Vector(3, f32) = .{ @floatCast(center[0]), @floatCast(center[1]), @floatCast(center[2]) };
    const planet = nearestPlanet(&self.generator, point) orelse return generator_api.no_spawn;
    const anchor = anchorPlanet(planet, point);
    var best = SpawnBest{};
    // Discs around the anchor honor `radius`; the host re-validates the winner.
    const disc_budget = @min(attempts, 8 * generator_api.spawn_samples_per_ring);
    for (0..disc_budget) |i| {
        considerPlanetColumn(&self.generator, planet, center, generator_api.spawnSample(seed, .{ anchor[0], anchor[2] }, radius, nonce, @intCast(i)), &best);
        if (i >= generator_api.spawn_samples_per_ring - 1 and best.good) break;
    }
    if (!best.good) {
        const sphere_budget = @min(attempts, generator_api.spawn_attempt_cap);
        for (0..sphere_budget) |i| {
            considerPlanetColumn(&self.generator, planet, center, sphereSample(seed, nonce, @intCast(i), planet, point - planet.center), &best);
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

test "proposeSpawn lands on the spawn planet" {
    var params: Generator.Params = .default;
    params.seed = 42;
    // Dry planet: every surface column passes, so the result is fully
    // determined by the anchor + first ring.
    params.water = false;
    params.setSeeds(std.testing.io);
    const gen = Generator.init(std.testing.allocator, 0, params);
    var instance = PlanetInstance{ .generator = gen, .source = undefined };
    const center = [3]f64{ 0, 0, 0 };
    const a = generator_propose_spawn(&instance, &center, 0, 32, 1);
    const b = generator_propose_spawn(&instance, &center, 0, 32, 1);
    try std.testing.expect(a.found);
    try std.testing.expectEqual(a.pos[0], b.pos[0]);
    try std.testing.expectEqual(a.pos[1], b.pos[1]);
    try std.testing.expectEqual(a.pos[2], b.pos[2]);
    const planet = gen.planetAt(gen.spawn_cell).?;
    const reach: f64 = @as(f64, planet.radius + planet.bump_amp);
    const dx: f64 = a.pos[0] - @as(f64, planet.center[0]);
    const dy: f64 = a.pos[1] - @as(f64, planet.center[1]);
    const dz: f64 = a.pos[2] - @as(f64, planet.center[2]);
    try std.testing.expect(@abs(dx) <= reach);
    try std.testing.expect(@abs(dy) <= reach + 8.0);
    try std.testing.expect(@abs(dz) <= reach);
}
