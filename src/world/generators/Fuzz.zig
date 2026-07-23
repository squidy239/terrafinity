const std = @import("std");

const Block = @import("../Block.zig").Block;
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("../World.zig");
const ChunkPos = World.ChunkPos;

pub const FuzzGenerator = struct {
    smith: *std.testing.Smith,
    
    pub fn init(smith: *std.testing.Smith) !FuzzGenerator {
        return FuzzGenerator{ .smith = smith };
    }

    pub fn getSource(self: *FuzzGenerator) World.ChunkSource {
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
        _ = io;
        _ = allocator;
        _ = world;
        _ = chunk_pos;
        
        const self: *FuzzGenerator = @ptrCast(@alignCast(source.data));
        blocks.* = .fuzzerMakeEncoding(grid_buffer, self.smith);
        return self.smith.value(World.ChunkSource.GetBlocksMetadata);
    }

    pub fn deinit(self: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World) void {
        _ = self;
        _ = world;
        _ = io;
        _ = allocator;
    }
};
