const std = @import("std");

const tracy = @import("tracy");
const Block = @import("../Block.zig").Block;
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;

pub const AlienHiveGyroidGenerator = struct {
    params: Params,
    seed_offset: f32, // Used to shift the infinite math so every seed is a new world

    pub fn init(allocator: std.mem.Allocator, max_cache_bytes: usize, params: Params) !AlienHiveGyroidGenerator {
        _ = allocator;
        _ = max_cache_bytes;

        // Create a random offset from the seed so the Gyroid coordinates shift
        var prng = std.Random.DefaultPrng.init(params.seed orelse 12345);
        const offset = prng.random().float(f32) * 10000.0;

        return AlienHiveGyroidGenerator{
            .params = params,
            .seed_offset = offset,
        };
    }

    pub fn getSource(self: *AlienHiveGyroidGenerator) World.ChunkSource {
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
        const self: *AlienHiveGyroidGenerator = @ptrCast(@alignCast(source.data));
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
        scale: f32 = 32.0,        // How wide the giant alien tunnels are
        wall_thickness: f32 = 0.2, // Thickness threshold for the surface
        sea_level: i32 = 0,
        
        pub const default = Params{};

        pub fn setSeeds(self: *Params, io: std.Io) void {
            if (self.seed == null) {
                var randomseed: u64 = undefined;
                io.random(@ptrCast(&randomseed));
                self.seed = randomseed;
            }
        }
    };

    /// Core Gyroid mathematical function
    inline fn evalGyroid(x: f32, y: f32, z: f32) f32 {
        return std.math.sin(x) * std.math.cos(y) +
               std.math.sin(y) * std.math.cos(z) +
               std.math.sin(z) * std.math.cos(x);
    }

    /// Combines a massive Gyroid with a small one for organic texture
    inline fn getDensity(self: *const AlienHiveGyroidGenerator, bx: i64, by: i64, bz: i64) f32 {
        const rx = (@as(f32, @floatFromInt(bx)) + self.seed_offset) / self.params.scale;
        const ry = (@as(f32, @floatFromInt(by)) + self.seed_offset) / self.params.scale;
        const rz = (@as(f32, @floatFromInt(bz)) + self.seed_offset) / self.params.scale;

        // Base massive tunnel structure
        const base_gyroid = evalGyroid(rx, ry, rz);
        
        // High-frequency detail for bumpy organic walls
        const detail_gyroid = evalGyroid(rx * 4.0, ry * 4.0, rz * 4.0) * 0.25;

        return base_gyroid + detail_gyroid;
    }

    pub fn genChunk(self: *AlienHiveGyroidGenerator, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, blocks: *Chunk.Encoding, world: *World, grid_buffer: *[ChunkSize][ChunkSize][ChunkSize]Block) !void {
        _ = allocator;
        _ = io;
        _ = world;
        const gen = tracy.Zone.begin(.{ .src = @src(), .name = "GenAlienHive" });
        defer gen.end();

        const block_scale = @as(i64, @intFromFloat(ChunkPos.toScale(chunk_pos.level)));
        var blockgrid: [ChunkSize][ChunkSize][ChunkSize]Block = comptime @splat(@splat(@splat(.air)));

        for (0..ChunkSize) |x| {
            const bx = (chunk_pos.position[0] * ChunkSize + @as(i64, @intCast(x))) * block_scale;
            for (0..ChunkSize) |y| {
                const by = (chunk_pos.position[1] * ChunkSize + @as(i64, @intCast(y))) * block_scale;
                for (0..ChunkSize) |z| {
                    const bz = (chunk_pos.position[2] * ChunkSize + @as(i64, @intCast(z))) * block_scale;

                    const density = self.getDensity(bx, by, bz);
                    const is_solid = density > self.params.wall_thickness;

                    if (is_solid) {
                        // Contextual texturing based on orientation (floor vs ceiling)
                        const above_density = self.getDensity(bx, by + 1, bz);
                        const below_density = self.getDensity(bx, by - 1, bz);
                        
                        const is_floor = above_density <= self.params.wall_thickness;
                        const is_ceiling = below_density <= self.params.wall_thickness;

                        if (is_floor) {
                            if (by < self.params.sea_level + 2) {
                                blockgrid[x][y][z] = .dirt; // Muddy banks near the water
                            } else {
                                blockgrid[x][y][z] = .grass; // Lush overgrowth on walkways
                            }
                        } else if (is_ceiling) {
                            // Create glowing bioluminescent pods on the ceilings using snow
                            const pseudo_random = @as(u64, @bitCast(bx * 73856093 + bz * 19349663 + by * 83492791));
                            if (pseudo_random % 20 == 0) {
                                blockgrid[x][y][z] = .snow;
                            } else {
                                blockgrid[x][y][z] = .stone;
                            }
                        } else {
                            blockgrid[x][y][z] = .stone; // Core organic wall mass
                        }
                    } else {
                        // Fill empty gaps with water if below sea level
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
            _ = try World.mergeEncoding(blocks, .{ .one_block = block }, grid_buffer);
        } else {
            _ = try World.mergeEncoding(blocks, .{ .grid = &blockgrid }, grid_buffer);
        }
    }
};