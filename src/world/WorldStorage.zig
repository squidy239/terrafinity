const std = @import("std");
const Block = @import("Block.zig").Block;
const Cache = @import("Cache").Cache;
const Chunk = @import("Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("World.zig");
const rocksdb = @import("rocksdb");
const tracy = @import("tracy");
const builtin = @import("builtin");

isinit: bool,
database: rocksdb.database.DB,
options: rocksdb.DBOptions,
chunk_metadata_column: rocksdb.ColumnFamily,
chunk_grid_column: rocksdb.ColumnFamily,
chunk_oneblock_column: rocksdb.ColumnFamily,

pub fn getSource(self: *@This()) World.ChunkSource {
    return .{
        .data = self,
        .getTerrainHeight = null,
        .getBlocks = getBlocks,
        .onLoad = null,
        .deinit = deinitSource,
        .onUnload = onUnload,
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

    const column_families: [4]rocksdb.ColumnFamilyDescription = .{
        .{ .name = "chunk_metadata", .options = .{ .compression = .lz4 } },
        .{ .name = "chunk_grid", .options = .{ .compression = .zstd } },
        .{ .name = "chunk_oneblock", .options = .{ .compression = .lz4 } },
        .{ .name = "default", .options = .{} }, // unused
    };
    storage.database, const columns = try rocksdb.DB.open(allocator, path, storage.options, &column_families, false, &err_str);
    storage.chunk_metadata_column = columns[0];
    storage.chunk_grid_column = columns[1];
    storage.chunk_oneblock_column = columns[2];
    allocator.free(columns);

    return storage;
}

const ChunkKey = packed struct {
    x: i32,
    y: i32,
    z: i32,
    level: i32,
};

const ChunkMetadata = packed struct(u8) {
    structures_generated: bool,
    encoding: EncodingTagType,
    _: u6 = undefined,
};

fn onUnload(source: World.ChunkSource, io: std.Io, world: *World, chunk: *Chunk, chunk_pos: World.ChunkPos) error{Unrecoverable}!void {
    _ = world;
    const self: *@This() = @ptrCast(@alignCast(source.data));
    self.saveChunk(io, chunk, chunk_pos) catch return error.Unrecoverable;
}

const EncodingTagType = std.meta.Tag(Chunk.Encoding); //get the type of the tagged unions tag
const BlockTagType = std.meta.Tag(Block);
///saves a chunk to the database if it has been modified
pub fn saveChunk(self: *@This(), io: std.Io, chunk: *Chunk, chunk_pos: World.ChunkPos) !void {
    const save = tracy.Zone.begin(.{ .src = @src() });
    defer save.end();
    if (chunk.modified.load(.seq_cst) == false) switch (chunk.encoding) {
        .grid => return,
        .one_block => if (chunk.saved.load(.unordered)) return, //save chunk if it is just one block and has not been saved yet
    };

    const key: ChunkKey = .{ .x = chunk_pos.position[0], .y = chunk_pos.position[1], .z = chunk_pos.position[2], .level = chunk_pos.level };
    try chunk.encoding_lock.lockShared(io);
    var write: rocksdb.WriteBatch = .init();
    const metadata: ChunkMetadata = .{
        .encoding = chunk.encoding,
        .structures_generated = chunk.structures_generated.load(.seq_cst),
    };
    write.put(self.chunk_metadata_column.handle, std.mem.asBytes(&key), std.mem.asBytes(&metadata));
    switch (chunk.encoding) {
        .grid => |blocks| write.put(self.chunk_grid_column.handle, std.mem.asBytes(&key), std.mem.asBytes(blocks)),
        .one_block => |block| write.put(self.chunk_oneblock_column.handle, std.mem.asBytes(&key), std.mem.asBytes(&block)),
    }
    var err_str: ?rocksdb.Data = null;
    defer if (err_str) |s| {
        std.log.err("{s}", .{s.data});
        s.deinit();
    };
    try self.database.write(write, &err_str);
    chunk.encoding_lock.unlockShared(io);
    chunk.saved.store(true, .unordered);
}

pub fn getBlocks(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, blocks: *Chunk.Encoding, chunk_pos: World.ChunkPos) error{ Unrecoverable, OutOfMemory, Canceled }!?World.ChunkSource.GetBlocksMetadata {
    const load = tracy.Zone.begin(.{ .src = @src() });
    defer load.end();

    const self: *@This() = @ptrCast(@alignCast(source.data));
    _ = allocator;
    var key = ChunkKey{ .x = chunk_pos.position[0], .y = chunk_pos.position[1], .z = chunk_pos.position[2], .level = chunk_pos.level };
    var err_str: ?rocksdb.Data = null;
    defer if (err_str) |s| {
        std.log.err("{s}", .{s.data});
        s.deinit();
    };

    const metadata_bytes = (self.database.get(self.chunk_metadata_column.handle, std.mem.asBytes(&key), &err_str) catch return error.Unrecoverable) orelse return null;

    const metadata = std.mem.bytesToValue(ChunkMetadata, metadata_bytes.data);
    metadata_bytes.deinit();

    if (err_str) |s| {
        std.log.err("{s}", .{s.data});
        s.deinit();
    }

    var data_bytes: rocksdb.Data = undefined;
    defer data_bytes.deinit();
    const mergeblocks: Chunk.Encoding = switch (metadata.encoding) {
        .grid => gr: {
            data_bytes = (self.database.get(self.chunk_grid_column.handle, std.mem.asBytes(&key), &err_str) catch return error.Unrecoverable) orelse return null;
            break :gr .{ .grid = @ptrCast(@alignCast(@constCast(data_bytes.data))) };
        },
        .one_block => ob: {
            data_bytes = (self.database.get(self.chunk_oneblock_column.handle, std.mem.asBytes(&key), &err_str) catch return error.Unrecoverable) orelse return null;
            break :ob .{ .one_block = std.mem.bytesToValue(Block, data_bytes.data) };
        },
    };

    try world.mergeEncoding(blocks, io, mergeblocks);
    return .{ .from_disk = true, .structures = metadata.structures_generated };
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
    self.database.deinit();
    _ = allocator;
}
