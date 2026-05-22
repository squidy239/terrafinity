const std = @import("std");

const tracy = @import("tracy");
const Block = @import("../Block.zig").Block;
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;

pub const InfiniteMengerGenerator = struct {
    params: Params,

    pub fn init(allocator: std.mem.Allocator, max_cache_bytes: usize, params: Params) !InfiniteMengerGenerator {
        _ = allocator;
        _ = max_cache_bytes;
        return InfiniteMengerGenerator{
            .params = params,
        };
    }

    pub fn getSource(self: *InfiniteMengerGenerator) World.ChunkSource {
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
        const self: *InfiniteMengerGenerator = @ptrCast(@alignCast(source.data));
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
        sea_level: i64 = 0,
        fractal_scale: i64 = 4, // Multiplies the size of the corridors (4 = smallest corridor is 4x4 blocks wide)
        max_height: i64 = 512, // The megastructure stops at this height to reveal the sky
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

    /// Pure mathematical evaluation of an infinite Menger Sponge
    inline fn isMengerSolid(bx: i64, by: i64, bz: i64, fractal_scale: i64) bool {
        // Scale down the world coordinates by the fractal scale so we have thick walls
        const scaled_x = @divFloor(bx, fractal_scale);
        const scaled_y = @divFloor(by, fractal_scale);
        const scaled_z = @divFloor(bz, fractal_scale);

        var scale: i64 = 1;

        // 15 iterations covers a coordinate space of 3^15 (14,348,907 blocks wide)
        // Adjust higher if you plan on flying out further than 14 million blocks!
        for (0..15) |_| {
            // Get the current base-3 digit for X, Y, and Z
            const px = @mod(@divFloor(scaled_x, scale), 3);
            const py = @mod(@divFloor(scaled_y, scale), 3);
            const pz = @mod(@divFloor(scaled_z, scale), 3);

            // A Menger Sponge removes the center sub-cubes.
            // In a 3x3x3 grid, the center cubes are the ones where at least two coordinates are the middle index (1).
            var middle_count: u8 = 0;
            if (px == 1) middle_count += 1;
            if (py == 1) middle_count += 1;
            if (pz == 1) middle_count += 1;

            // If 2 or 3 of the axes are in the middle, this space is hollowed out.
            if (middle_count >= 2) return false;

            scale *= 3;
        }

        return true;
    }

    pub fn genChunk(self: *InfiniteMengerGenerator, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, blocks: *Chunk.Encoding, world: *World, grid_buffer: *[ChunkSize][ChunkSize][ChunkSize]Block) !void {
        _ = allocator;
        _ = io;
        _ = world;
        const gen = tracy.Zone.begin(.{ .src = @src(), .name = "GenMengerMegastructure" });
        defer gen.end();

        const block_scale = @as(i64, @intFromFloat(ChunkPos.toScale(chunk_pos.level)));

        // Skip chunk if it's completely above the megastructure ceiling
        if (chunk_pos.position[1] * @as(i32, @intCast(ChunkSize * block_scale)) > self.params.max_height) {
            blocks.merge(.{ .one_block = .air }, grid_buffer);
            return;
        }

        var blockgrid: [ChunkSize][ChunkSize][ChunkSize]Block = comptime @splat(@splat(@splat(.air)));

        for (0..ChunkSize) |x| {
            const bx = (chunk_pos.position[0] * ChunkSize + @as(i64, @intCast(x))) * block_scale;
            for (0..ChunkSize) |y| {
                const by = (chunk_pos.position[1] * ChunkSize + @as(i64, @intCast(y))) * block_scale;

                // Cut off the top flatly to leave an open sky
                if (by > self.params.max_height) {
                    // Loop naturally skips filling these, leaving them as `.air`
                    continue;
                }

                for (0..ChunkSize) |z| {
                    const bz = (chunk_pos.position[2] * ChunkSize + @as(i64, @intCast(z))) * block_scale;

                    const is_solid = isMengerSolid(bx, by, bz, self.params.fractal_scale);

                    if (is_solid) {
                        // Contextual geometry checks: Is there air above or below?
                        const block_above_solid = isMengerSolid(bx, by + 1, bz, self.params.fractal_scale);
                        const block_below_solid = isMengerSolid(bx, by - 1, bz, self.params.fractal_scale);

                        // If it's the absolute top layer of the megastructure ceiling
                        if (by == self.params.max_height) {
                            blockgrid[x][y][z] = .grass;
                        }
                        // If it's an interior floor
                        else if (!block_above_solid) {
                            if (by >= self.params.sea_level) {
                                blockgrid[x][y][z] = .grass; // Overgrown flat walkways
                            } else {
                                blockgrid[x][y][z] = .dirt; // Muddy flooded floors
                            }
                        }
                        // If it's an interior ceiling above water
                        else if (!block_below_solid and by > self.params.sea_level) {
                            // Plant sparse bioluminescent "lights" on the ceilings
                            const hash = @as(u64, @bitCast(bx * 73856093 + bz * 19349663 + by * 83492791));
                            if (hash % 15 == 0) {
                                blockgrid[x][y][z] = .snow;
                            } else {
                                blockgrid[x][y][z] = .stone;
                            }
                        }
                        // Core structural mass
                        else {
                            blockgrid[x][y][z] = .stone;
                        }
                    } else {
                        // Fill structural voids below the sea level with water
                        if (by <= self.params.sea_level) {
                            blockgrid[x][y][z] = .water;
                        } else {
                            blockgrid[x][y][z] = .air;
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
