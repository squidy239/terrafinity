const std = @import("std");

const tracy = @import("tracy");
const Block = @import("../Block.zig").Block;
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;

pub const CosmicGeodeMultiverseGenerator = struct {
    params: Params,

    pub fn init(allocator: std.mem.Allocator, max_cache_bytes: usize, params: Params) !CosmicGeodeMultiverseGenerator {
        _ = allocator;
        _ = max_cache_bytes;
        return CosmicGeodeMultiverseGenerator{
            .params = params,
        };
    }

    pub fn getSource(self: *CosmicGeodeMultiverseGenerator) World.ChunkSource {
        return .{
            .data = self,
            .getTerrainHeight = null,
            .getBlocks = &genChunkBlocks,
            .onLoad = null,
            .deinit = &deinit,
            .onUnload = null,
        };
    }

    fn genChunkBlocks(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, blocks: *Chunk.Encoding, chunk_pos: ChunkPos, grid_buffer: *[ChunkSize][ChunkSize][ChunkSize]Block) error{ Unrecoverable, OutOfMemory, Canceled }!?World.ChunkSource.GetBlocksMetadata {
        const self: *CosmicGeodeMultiverseGenerator = @ptrCast(@alignCast(source.data));
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
        seed: ?u64 = null,

        pub const default = Params{};

        pub fn setSeeds(self: *Params, io: std.Io) void {
            if (self.seed == null) {
                var randomseed: u64 = undefined;
                io.random(@ptrCast(&randomseed));
                self.seed = randomseed;
            }
        }
    };

    const Geode = struct {
        x: i64,
        y: i64,
        z: i64,
        outer_r: i64,
        outer_r_sq: i64,
        inner_r: i64,
        inner_r_sq: i64,
        water_level: i64,
    };

    /// A fast, wrapping 3D integer hash function used for placing universes and details
    inline fn hash3D(x: i64, y: i64, z: i64, seed: u64) u64 {
        var h = seed;
        h = h +% @as(u64, @bitCast(x)) *% 73856093;
        h = h ^ (h >> 19);
        h = h +% @as(u64, @bitCast(y)) *% 19349663;
        h = h ^ (h >> 23);
        h = h +% @as(u64, @bitCast(z)) *% 83492791;
        h = h ^ (h >> 17);
        h = h *% 1000000007;
        return h;
    }

    pub fn genChunk(self: *CosmicGeodeMultiverseGenerator, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, blocks: *Chunk.Encoding, world: *World, grid_buffer: *[ChunkSize][ChunkSize][ChunkSize]Block) !void {
        _ = io;
        _ = world;
        const gen = tracy.Zone.begin(.{ .src = @src(), .name = "GenCosmicGeodes" });
        defer gen.end();

        const block_scale = @as(i64, @intFromFloat(ChunkPos.toScale(chunk_pos.level)));

        const chunk_center_x = (chunk_pos.position[0] * ChunkSize + (ChunkSize / 2)) * block_scale;
        const chunk_center_y = (chunk_pos.position[1] * ChunkSize + (ChunkSize / 2)) * block_scale;
        const chunk_center_z = (chunk_pos.position[2] * ChunkSize + (ChunkSize / 2)) * block_scale;

        var local_geodes: std.ArrayList(Geode) = .empty;
        defer local_geodes.deinit(allocator);

        // -------------------------------------------------------------
        // 1. Resolve Massive Geodes (Macro Grid)
        // -------------------------------------------------------------
        const grid_size: i64 = 1000; // Colossal spacing
        const mc_x = @divFloor(chunk_center_x, grid_size);
        const mc_y = @divFloor(chunk_center_y, grid_size);
        const mc_z = @divFloor(chunk_center_z, grid_size);

        // Search the 3x3x3 macro cells around this chunk
        for (0..3) |dx| {
            const cx = mc_x + @as(i64, @intCast(dx)) - 1;
            for (0..3) |dy| {
                const cy = mc_y + @as(i64, @intCast(dy)) - 1;
                for (0..3) |dz| {
                    const cz = mc_z + @as(i64, @intCast(dz)) - 1;

                    const h = hash3D(cx, cy, cz, self.params.seed.?);

                    // Center point offset within the 1000x1000x1000 box
                    const px = cx * grid_size + @as(i64, @intCast((h >> 10) % @as(u64, @intCast(grid_size))));
                    const py = cy * grid_size + @as(i64, @intCast((h >> 20) % @as(u64, @intCast(grid_size))));
                    const pz = cz * grid_size + @as(i64, @intCast((h >> 30) % @as(u64, @intCast(grid_size))));

                    // Outer radius between 400 and 800 blocks.
                    // This guarantees they will intersect adjacent universes.
                    const outer_radius = 400 + @as(i64, @intCast((h >> 40) % 400));

                    // Shell thickness between 15 and 45 blocks
                    const shell_thickness = 15 + @as(i64, @intCast((h >> 50) % 30));
                    const inner_radius = outer_radius - shell_thickness;

                    // Each geode gets its own unique water level independent of the rest of the universe!
                    // Ranges from the bottom of the geode up to slightly above the center.
                    const local_water_height = py - inner_radius + @as(i64, @intCast(h % @as(u64, @intCast(inner_radius + 200))));

                    try local_geodes.append(allocator, .{
                        .x = px,
                        .y = py,
                        .z = pz,
                        .outer_r = outer_radius,
                        .outer_r_sq = outer_radius * outer_radius,
                        .inner_r = inner_radius,
                        .inner_r_sq = inner_radius * inner_radius,
                        .water_level = local_water_height,
                    });
                }
            }
        }

        // -------------------------------------------------------------
        // 2. Render Voxels
        // -------------------------------------------------------------
        var blockgrid: [ChunkSize][ChunkSize][ChunkSize]Block = comptime @splat(@splat(@splat(.air)));
        const geodes = local_geodes.items;

        for (0..ChunkSize) |x| {
            const bx = (chunk_pos.position[0] * ChunkSize + @as(i64, @intCast(x))) * block_scale;
            for (0..ChunkSize) |y| {
                const by = (chunk_pos.position[1] * ChunkSize + @as(i64, @intCast(y))) * block_scale;
                for (0..ChunkSize) |z| {
                    const bz = (chunk_pos.position[2] * ChunkSize + @as(i64, @intCast(z))) * block_scale;

                    var geode_count: u32 = 0;
                    var primary_geode: ?*const Geode = null;
                    var primary_dist_sq: i64 = 0;

                    // Check which geodes enclose this voxel
                    for (geodes) |*g| {
                        const dist_sq = (bx - g.x) * (bx - g.x) + (by - g.y) * (by - g.y) + (bz - g.z) * (bz - g.z);
                        if (dist_sq <= g.outer_r_sq) {
                            geode_count += 1;
                            primary_geode = g;
                            primary_dist_sq = dist_sq;
                        }
                    }

                    if (geode_count == 0) {
                        // We are in the deep void between universes.
                        // Generate sparse stars using the integer hash.
                        if (hash3D(bx, by, bz, self.params.seed.?) % 15000 == 0) {
                            blockgrid[x][y][z] = .snow;
                        } else {
                            blockgrid[x][y][z] = .air;
                        }
                    } else if (geode_count > 1) {
                        // MATHEMATICAL MAGIC:
                        // We are inside the overlapping zone of TWO OR MORE massive geodes.
                        // Forcing this space to be `.air` perfectly carves out massive circular
                        // portals between the adjacent worlds.
                        blockgrid[x][y][z] = .air;
                    } else {
                        // We belong to exactly ONE universe
                        const g = primary_geode.?;

                        if (primary_dist_sq < g.inner_r_sq) {
                            // --------------------------------
                            // THE HOLLOW INTERIOR
                            // --------------------------------
                            if (by <= g.water_level) {
                                blockgrid[x][y][z] = .water;
                            } else {
                                // Instead of just empty air, let's generate alien, floating
                                // geometric structures purely using trigonometry (no noise).
                                // Using f64 prevents precision loss at huge coordinate scales.
                                const fx = @as(f64, @floatFromInt(bx));
                                const fy = @as(f64, @floatFromInt(by));
                                const fz = @as(f64, @floatFromInt(bz));

                                const trig_island = std.math.sin(fx / 45.0) * std.math.cos(fz / 45.0) * std.math.sin(fy / 30.0);

                                if (trig_island > 0.8) {
                                    blockgrid[x][y][z] = .grass;
                                } else if (trig_island > 0.75) {
                                    blockgrid[x][y][z] = .dirt;
                                } else {
                                    blockgrid[x][y][z] = .air;
                                }
                            }
                        } else {
                            // --------------------------------
                            // THE GEODE SHELL
                            // --------------------------------
                            // If we are within 3 blocks of the inner surface, we give it environmental texturing
                            const lining_thickness_sq = (g.inner_r + 3) * (g.inner_r + 3);

                            if (primary_dist_sq <= lining_thickness_sq) {
                                if (by <= g.water_level) {
                                    blockgrid[x][y][z] = .dirt; // Flooded floors
                                } else if (by < g.y) {
                                    blockgrid[x][y][z] = .grass; // Lush overgrowth on the lower hemisphere
                                } else {
                                    // The upper hemisphere gets bioluminescent starry crystal ceilings
                                    if (hash3D(bx, by, bz, self.params.seed.?) % 60 == 0) {
                                        blockgrid[x][y][z] = .snow;
                                    } else {
                                        blockgrid[x][y][z] = .stone;
                                    }
                                }
                            } else {
                                // Deep structural crust
                                blockgrid[x][y][z] = .stone;
                            }
                        }
                    }
                }
            }
        }

        const oneblock = Chunk.isOneBlock(&blockgrid);
        if (oneblock) |block| {
            blocks.merge(.{ .one_block = block }, grid_buffer);
        } else {
            blocks.merge(.{ .grid = &blockgrid }, grid_buffer);
        }
    }
};
