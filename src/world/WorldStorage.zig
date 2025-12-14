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
            .getBlocks = getBlocks,
            .onLoad = null,
            .deinit = null,
            .onUnload = onUnload,
        };
    }
    ///should technically work but is very bad, TODO make better
    fn getBlocks(source: World.ChunkSource, world: *World, blocks: *[ChunkSize][ChunkSize][ChunkSize]Block, Pos: [3]i32) error{ Unrecoverable, OutOfMemory }!bool{
        _ = blocks;
        const self: *RegionStorage = @ptrCast(@alignCast(source.data));
        const regionPos = @divFloor(Pos, @Vector(3, i32){ Region.Size, Region.Size, Region.Size });
        loadRegion(self, world, regionPos) catch |err| switch (err) {
            error.FileNotFound => return false,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unrecoverable,
        };
        return false;
    }
        
    fn onUnload(source: World.ChunkSource, world: *World, chunk: *Chunk, Pos: [3]i32) error{Unrecoverable}!void {
        const self: *RegionStorage = @ptrCast(@alignCast(source.data));
        _ = world;
        saveChunk(self,chunk, Pos) catch return error.Unrecoverable;
    }

    pub fn saveChunk(self: *@This(), chunk: *Chunk, Pos: [3]i32) !void {
        const regionPos = @divFloor(Pos, @Vector(3, i32){ Region.Size, Region.Size, Region.Size });
        const posInRegion: @Vector(3, usize) = @intCast(@mod(Pos, @Vector(3, i32){ Region.Size, Region.Size, Region.Size }));
        var chunks: [Region.Size][Region.Size][Region.Size]?*Chunk = @splat(@splat(@splat(null)));
        
        chunks[posInRegion[0]][posInRegion[1]][posInRegion[2]] = chunk;
        
        try self.saveRegion(regionPos, chunks, .Raw);
    }

    pub fn saveRegion(self: *@This(), regionPos: @Vector(3, i32), chunks: [Region.Size][Region.Size][Region.Size]?*Chunk, encodeing: Region.ChunkSectionEncoding) !void {
        std.debug.assert(!std.meta.eql(chunks, @splat(@splat(@splat(null)))));
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
        try Region.merge(&reader.interface, &writer.interface, encodeing, chunks);
    }

    /// Loads a region from the given file.
    pub fn loadRegion(self: *@This(), world: *World, regionPos: [3]i32) !void {
        var fmt_buf: [64]u8 = undefined;
        var read_buf: [65536]u8 = undefined;

        const file = try self.params.path.openFile(try std.fmt.bufPrint(&fmt_buf, "{any}.tfr", .{regionPos}), .{ .lock = .shared, .mode = .read_only });
        var reader = file.reader(&read_buf);
        
        const fullheader = try Region.readHeader(&reader.interface);
        const firstchunks = try Region.loadAllOneBlockChunks(fullheader, world.allocator);
        const secondchunks = try Region.loadAllBlockChunks(&reader.interface, fullheader, world.allocator);
        
        for(0..Region.Size) |x| {
            for(0..Region.Size) |y| {
                for(0..Region.Size) |z| {
                    if(firstchunks[x][y][z] != null) {
                        const worldPos = regionPos * @Vector(3, i32){ Region.Size, Region.Size, Region.Size } + @Vector(3, i32){@intCast(x),@intCast(y), @intCast(z) };
                        const chunk = firstchunks[x][y][z].?;
                        const existing = try world.Chunks.putNoOverrideaddRef(worldPos, chunk);
                        if(existing) |c| {
                            chunk.free(world.allocator);
                            world.allocator.destroy(chunk);
                            c.release();
                        }
                            
                        
                    }
                    if(secondchunks[x][y][z] != null) {
                        const worldPos = regionPos * @Vector(3, i32){ Region.Size, Region.Size, Region.Size } + @Vector(3, i32){@intCast(x),@intCast(y), @intCast(z) };
                        const chunk = secondchunks[x][y][z].?;
                        const existing = try world.Chunks.putNoOverrideaddRef(worldPos, chunk);
                        if(existing) |c| {
                            chunk.free(world.allocator);
                            world.allocator.destroy(chunk);
                            c.release();
                        }
                    }
                }
            }
        }
    }

    const StorageParams = struct {
        path: std.fs.Dir,
    };
};
