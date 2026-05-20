const std = @import("std");

const tracy = @import("tracy");
const Block = @import("../Block.zig").Block;
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;

pub const FractalTerrainGenerator = struct {
    params: Params,

    pub fn init(allocator: std.mem.Allocator, max_cache_bytes: usize, params: Params) !FractalTerrainGenerator {
        _ = allocator;
        _ = max_cache_bytes;
        return FractalTerrainGenerator{
            .params = params,
        };
    }

    pub fn getSource(self: *FractalTerrainGenerator) World.ChunkSource {
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
        terrain_scale: f32 = 4.0, // A scale of 4 means each fractal "pixel" is 4x4x4 voxels wide
        pub const default = Params{};
        pub fn setSeeds(self: *Params, io: std.Io) void {
            if (self.seed == null) {
                var randomseed: u64 = undefined;
                io.random(@ptrCast(&randomseed));
                self.seed = randomseed;
            }
        }
    };

    pub fn genChunk(self: *FractalTerrainGenerator, io: std.Io, allocator: std.mem.Allocator, chunk_pos: ChunkPos, blocks: *Chunk.Encoding, world: *World, grid_buffer: *[ChunkSize][ChunkSize][ChunkSize]Block) !void {
        _ = allocator;
        _ = io;
        _ = world;
        const gen = tracy.Zone.begin(.{ .src = @src() });
        defer gen.end();

        const block_scale = @as(i64, @intFromFloat(ChunkPos.toScale(chunk_pos.level)));

        // Skip generation if completely above terrain max
        if (chunk_pos.position[1] * @as(i32, @intCast(ChunkSize * block_scale)) > self.params.terrainmax) {
            _ = try World.mergeEncoding(blocks, .{ .one_block = .air }, grid_buffer);
            return;
        }

        // Generate solid rock if completely below terrain min to create an ultimate floor
        if ((chunk_pos.position[1] + 1) * @as(i32, @intCast(ChunkSize * block_scale)) < self.params.terrainmin) {
            _ = try World.mergeEncoding(blocks, .{ .one_block = .stone }, grid_buffer);
            return;
        }

        var blockgrid: [ChunkSize][ChunkSize][ChunkSize]Block = comptime @splat(@splat(@splat(.null)));
        const genterra = tracy.Zone.begin(.{ .src = @src(), .name = "Gen3DSierpinskiBlocks" });

        const chunkBlockPos = chunk_pos.position * @as(@Vector(3, i64), @splat(ChunkSize));
        const scale_divider: i64 = @max(1, @as(i64, @intFromFloat(self.params.terrain_scale)));

        for (0..ChunkSize) |x| {
            const bx = (chunkBlockPos[0] + @as(i64, @intCast(x))) * block_scale;
            for (0..ChunkSize) |y| {
                const by = (chunkBlockPos[1] + @as(i64, @intCast(y))) * block_scale;
                for (0..ChunkSize) |z| {
                    const bz = (chunkBlockPos[2] + @as(i64, @intCast(z))) * block_scale;

                    if (by > self.params.terrainmax) {
                        blockgrid[x][y][z] = .air;
                        continue;
                    }
                    if (by < self.params.terrainmin) {
                        blockgrid[x][y][z] = .stone;
                        continue;
                    }

                    const is_solid = isSierpinskiTetrahedron(bx, by, bz, scale_divider);

                    if (is_solid) {
                        // Check if the block directly above is solid. If not, paint it as a top layer.
                        const block_above_solid = isSierpinskiTetrahedron(bx, by + 1, bz, scale_divider);

                        if (!block_above_solid and by >= self.params.SeaLevel) {
                            blockgrid[x][y][z] = .grass;
                        } else if (by < self.params.SeaLevel) {
                            blockgrid[x][y][z] = .stone;
                        } else {
                            blockgrid[x][y][z] = .dirt;
                        }
                    } else {
                        // Fill empty gaps below sea level with water
                        if (by <= self.params.SeaLevel) {
                            blockgrid[x][y][z] = .water;
                        } else {
                            blockgrid[x][y][z] = .air;
                        }
                    }
                }
            }
        }

        genterra.end();

        const oneblock = Chunk.isOneBlock(&blockgrid);
        if (oneblock) |block| {
            _ = try World.mergeEncoding(blocks, .{ .one_block = block }, grid_buffer);
        } else {
            _ = try World.mergeEncoding(blocks, .{ .grid = &blockgrid }, grid_buffer);
        }
    }

    /// Pure bitwise evaluation for a 3D Sierpinski Tetrahedron
    inline fn isSierpinskiTetrahedron(bx: i64, by: i64, bz: i64, scale_divider: i64) bool {
        const scaled_x = @divFloor(bx, scale_divider);
        const scaled_y = @divFloor(by, scale_divider);
        const scaled_z = @divFloor(bz, scale_divider);

        // Taking the absolute value guarantees two things:
        // 1. Negative Two's Complement bits don't ruin the bitwise AND logic.
        // 2. The fractal perfectly mirrors across the X, Y, and Z axis origins.
        const sx = @as(u64, @intCast(@abs(scaled_x)));
        const sy = @as(u64, @intCast(@abs(scaled_y)));
        const sz = @as(u64, @intCast(@abs(scaled_z)));

        // The condition for a point inside a 3D Sierpinski Tetrahedron:
        // No two coordinates can share a 1-bit in the same position.
        return (sx & sy) == 0 and (sy & sz) == 0 and (sz & sx) == 0;
    }
};
