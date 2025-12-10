const std = @import("std");
const Block = @import("Chunk").Block;
const Cache = @import("Cache").Cache;
const Chunk = @import("Chunk").Chunk;
const ChunkSize = Chunk.ChunkSize;
const Region = @import("Region.zig").Region;
const World = @import("World.zig").World;

pub const RegionStorage = struct {
    params: StorageParams,

    pub fn getSource(self: *@This()) World.ChunkSource {
        return .{
            .data = self,
            .getTerrainHeight = null,
            .getBlocks = null,
            .onLoad = null,
            .deinit = null,
            .onUnload = null,
        };
    }
    
    fn saveChunk(self: *@This(), world: *World, chunk: *Chunk, Pos: [3]i32)!void{
        var fmt_buf: [64]u8 = undefined;
        var read_buf: [65536]u8 = undefined;
        var write_buf: [65536]u8 = undefined;

        const regionPos = [3]i32{@divFloor(Pos[0], Region.Size),@divFloor(Pos[1], Region.Size),@divFloor(Pos[2], Region.Size)};
        const file = try self.params.path.createFile(std.fmt.bufPrint(&fmt_buf, "{any}.tfr", .{regionPos}), .{ .lock = .exclusive, .mode = .read_write });
        var reader = file.reader(&read_buf);
        const header = try Region.readHeader(&reader);
        Region.write(writer: *Writer, chunkSectionEncoding: ChunkSectionEncoding, chunks: [?][?][?]?*Chunk)
    }

    const StorageParams = struct {
        path: std.fs.Dir,
    };
};
