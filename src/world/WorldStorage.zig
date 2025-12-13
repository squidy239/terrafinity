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
            .onUnload = onUnload,
        };
    }

    fn onUnload(source: World.ChunkSource, world: *World, chunk: *Chunk, Pos: [3]i32) error{Unrecoverable}!void {
        _ = chunk;
        const self: *RegionStorage = @ptrCast(@alignCast(source.data));
        saveChunk(self, world, Pos) catch return error.Unrecoverable;
    }

    pub fn saveChunk(self: *@This(), world: *World, Pos: [3]i32) !void {
        const regionPos = @divFloor(Pos, @Vector(3, i32){ Region.Size, Region.Size, Region.Size });
        const posInRegion: @Vector(3, usize) = @intCast(@mod(Pos, @Vector(3, i32){ Region.Size, Region.Size, Region.Size }));
        var chunksToSave: [Region.Size][Region.Size][Region.Size]bool = @splat(@splat(@splat(false)));
        chunksToSave[posInRegion[0]][posInRegion[1]][posInRegion[2]] = true;
        try self.saveRegion(world, regionPos, chunksToSave, .Raw, false);
    }

    pub fn saveRegion(self: *@This(), world: *World, regionPos: @Vector(3, i32), chunksToSave: [Region.Size][Region.Size][Region.Size]bool, encodeing: Region.ChunkSectionEncoding, unloadSaved: bool) !void {
        var fmt_buf: [256]u8 = undefined;
        var read_buf: [65536]u8 = undefined;
        var write_buf: [65536]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&fmt_buf, "{any}.tfr", .{regionPos});
        const file = self.params.path.openFile(file_name, .{ .mode = .read_write, .lock = .exclusive }) catch |err| switch (err) {
            error.FileNotFound => try self.params.path.createFile(file_name, .{ .read = true }),
            else => return err,
        };
        defer file.close();
        var reader = file.reader(&read_buf);
        var writer = file.writer(&write_buf);
        const regionChunkPos = regionPos * @Vector(3, i32){ Region.Size, Region.Size, Region.Size };
        var chunks: [Region.Size][Region.Size][Region.Size]?*Chunk = @splat(@splat(@splat(null)));
        for (0..Region.Size) |x| {
            for (0..Region.Size) |y| {
                for (0..Region.Size) |z| {
                    if (chunksToSave[x][y][z]) {
                        const chunk = world.Chunks.getandaddref(regionChunkPos + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) });
                        chunks[x][y][z] = chunk;
                        std.debug.print("sc", .{});
                    }
                }
            }
        }
        try Region.merge(&reader.interface, &writer.interface, encodeing, chunks);
        for (0..Region.Size) |x| {
            for (0..Region.Size) |y| {
                for (0..Region.Size) |z| {
                    if (chunks[x][y][z]) |chunk| {
                        if (unloadSaved) {
                            world.UnloadChunkNoSave(regionChunkPos + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) });
                        } else chunk.release();
                    }
                }
            }
        }
    }

    /// Loads a region from the given file.
    pub fn loadRegion(self: *@This(), world: *World, regionPos: [3]i32, chunks: [Region.Size][Region.Size][Region.Size]bool) !void {
        var fmt_buf: [64]u8 = undefined;
        var read_buf: [65536]u8 = undefined;
        var write_buf: [65536]u8 = undefined;

        const file = try self.params.path.openFile(std.fmt.bufPrint(&fmt_buf, "{any}.tfr", .{regionPos}), .{ .lock = .exclusive, .mode = .read_only });
        var reader = file.reader(&read_buf);
        var writer = file.writer(&write_buf);

        _ = &reader;
        _ = &writer;
        _ = world;
        _ = chunks;
    }

    const StorageParams = struct {
        path: std.fs.Dir,
    };
};
