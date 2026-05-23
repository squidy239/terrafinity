const std = @import("std");
const Block = @import("Block.zig").Block;
const Chunk = @import("Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("World.zig");
const rocksdb = @import("rocksdb");
const tracy = @import("tracy");

isinit: bool,
database: rocksdb.database.DB,
options: rocksdb.DBOptions,
chunkdata_column: rocksdb.ColumnFamily,
chunk_grid_column: rocksdb.ColumnFamily,

pub fn getSource(self: *@This()) World.ChunkSource {
    return .{
        .data = self,
        .getTerrainHeight = null,
        .getBlocks = getBlocks,
        .placeStructures = null,
        .deinit = deinitSource,
        .save = save,
    };
}

////opens the database, creates it if it doesnt exist
pub fn init(path: []const u8, allocator: std.mem.Allocator) !@This() {
    var storage: @This() = undefined;
    storage.isinit = true;
    storage.options = .{
        .create_if_missing = true,
        .create_missing_column_families = true,
        .compression = .zstd,
    };
    var err_str: ?rocksdb.Data = null;
    defer if (err_str) |s| {
        std.log.err("{s}", .{s.data});
        s.deinit();
    };

    const column_families: [3]rocksdb.ColumnFamilyDescription = .{
        .{ .name = "chunk_data", .options = .{
            .compression = .no_compression,
            .optimize_filters_for_hits = false,
        } },
        .{ .name = "chunk_grid", .options = .{
            .compression = .zstd,
            .block_size = @sizeOf([ChunkSize][ChunkSize][ChunkSize]Block),
        } },
        .{ .name = "default", .options = .{} }, // unused
    };
    storage.database, const columns = try rocksdb.DB.open(allocator, path, storage.options, &column_families, false, &err_str);
    storage.chunkdata_column = columns[0];
    storage.chunk_grid_column = columns[1];
    allocator.free(columns);

    return storage;
}

const ChunkKey = packed struct {
    x: i32,
    y: i32,
    z: i32,
    level: i32,
};

const ChunkData = packed struct {
    structures_generated: bool,
    encoding: EncodingTagType,
    one_block: Block, //This is only valid if encoding is .one_block
};

fn save(source: World.ChunkSource, io: std.Io, world: *World, chunk: *Chunk, chunk_pos: World.ChunkPos) error{Unrecoverable}!void {
    _ = world;
    const self: *@This() = @ptrCast(@alignCast(source.data));
    self.saveChunk(io, chunk, chunk_pos) catch return error.Unrecoverable;
}

const EncodingTagType = std.meta.Tag(Chunk.Encoding); //get the type of the tagged unions tag

///saves a chunk to the database if it has been modified
pub fn saveChunk(self: *@This(), io: std.Io, chunk: *Chunk, chunk_pos: World.ChunkPos) !void {
    const z = tracy.Zone.begin(.{ .src = @src() });
    defer z.end();
    _ = io;
    if (chunk.modified.load(.seq_cst) == false) switch (chunk.encoding) {
        .grid => return,
        .one_block => if (chunk.saved.load(.unordered)) return, //save chunk if it is just one block and has not been saved yet
    };

    const key: ChunkKey = .{ .x = chunk_pos.position[0], .y = chunk_pos.position[1], .z = chunk_pos.position[2], .level = chunk_pos.level };
    const data: ChunkData = .{
        .encoding = chunk.encoding,
        .structures_generated = chunk.structures_generated.load(.seq_cst),
        .one_block = if (chunk.encoding == .one_block) chunk.encoding.one_block else undefined,
    };
    var err_str: ?rocksdb.Data = null;
    defer if (err_str) |s| {
        std.log.err("{s}", .{s.data});
        s.deinit();
    };
    switch (chunk.encoding) {
        .grid => |blocks| {
            var write: rocksdb.WriteBatch = .init();
            write.put(self.chunk_grid_column.handle, std.mem.asBytes(&key), std.mem.asBytes(blocks));
            write.put(self.chunkdata_column.handle, std.mem.asBytes(&key), std.mem.asBytes(&data));
            try self.database.write(write, &err_str);
        },
        .one_block => {
            try self.database.put(self.chunkdata_column.handle, std.mem.asBytes(&key), std.mem.asBytes(&data), &err_str);
        },
    }
    chunk.modified.store(false, .seq_cst);
    chunk.saved.store(true, .unordered);
}

pub fn getBlocks(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, blocks: *Chunk.Encoding, chunk_pos: World.ChunkPos, grid_buffer: *[ChunkSize][ChunkSize][ChunkSize]World.Block) error{ Unrecoverable, OutOfMemory, Canceled }!?World.ChunkSource.GetBlocksMetadata {
    const load = tracy.Zone.begin(.{ .src = @src() });
    defer load.end();
    _ = io;
    _ = world;
    const self: *@This() = @ptrCast(@alignCast(source.data));
    _ = allocator;
    var key = ChunkKey{ .x = chunk_pos.position[0], .y = chunk_pos.position[1], .z = chunk_pos.position[2], .level = chunk_pos.level };
    var err_str: ?rocksdb.Data = null;
    defer if (err_str) |s| {
        std.log.err("{s}", .{s.data});
        s.deinit();
    };

    const data_bytes = (self.database.get(self.chunkdata_column.handle, std.mem.asBytes(&key), &err_str) catch return error.Unrecoverable) orelse return null;

    const data = std.mem.bytesToValue(ChunkData, data_bytes.data);
    data_bytes.deinit();

    if (err_str) |s| {
        std.log.err("{s}", .{s.data});
        s.deinit();
    }

    var grid_bytes: ?rocksdb.Data = null;
    defer if (grid_bytes) |b| b.deinit();
    const mergeblocks: Chunk.Encoding = switch (data.encoding) {
        .grid => gr: {
            grid_bytes = (self.database.get(self.chunk_grid_column.handle, std.mem.asBytes(&key), &err_str) catch return error.Unrecoverable) orelse return null;
            break :gr .{ .grid = @ptrCast(@alignCast(@constCast(grid_bytes.?.data))) };
        },
        .one_block => .{ .one_block = data.one_block },
    };

    blocks.merge(mergeblocks, grid_buffer);
    return .{ .from_disk = true, .structures = data.structures_generated };
}

fn deinitSource(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World) void {
    _ = world;
    _ = io;
    const self: *@This() = @ptrCast(@alignCast(source.data));
    self.deinit(allocator);
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    std.debug.assert(self.isinit);
    self.isinit = false;
    var es1: ?rocksdb.Data = null;
    defer if (es1) |s| s.deinit();
    self.database.flush(self.chunk_grid_column.handle, &es1) catch |err| std.log.warn("Flush failed: {any}\n", .{err});
    var es2: ?rocksdb.Data = null;
    defer if (es2) |s| s.deinit();
    self.database.flush(self.chunkdata_column.handle, &es2) catch |err| std.log.warn("Flush failed: {any}\n", .{err});
    self.database.deinit();
    _ = allocator;
}
