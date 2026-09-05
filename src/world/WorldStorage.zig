const std = @import("std");

const rocksdb = @import("rocksdb");
const tracy = @import("tracy");

const Block = @import("Block.zig").Block;
const Chunk = @import("Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("World.zig");

pub const SaveMode = enum {
    /// Save every chunk in full, whether or not it was modified
    everything,
    /// Save modified grids and all uniform chunks
    modified_grids_all_uniforms,
    /// Save only modified chunks
    only_modified,
};

is_init: bool,
database: rocksdb.database.DB,
options: rocksdb.DBOptions,
chunkdata_column: rocksdb.ColumnFamily,
chunk_grid_column: rocksdb.ColumnFamily,
save_mode: *SaveMode,
options_lock: *std.Io.RwLock,

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
pub fn init(path: []const u8, allocator: std.mem.Allocator, save_mode: *SaveMode, options_lock: *std.Io.RwLock) !@This() {
    var storage: @This() = undefined;
    storage.is_init = true;
    storage.save_mode = save_mode;
    storage.options_lock = options_lock;
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
            .compression = .zstd,
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

/// Removes every persisted chunk from both storage column families using RocksDB range tombstones.
pub fn clear(self: *@This()) !void {
    var write: rocksdb.WriteBatch = .init();
    defer write.deinit();

    const start_key: []const u8 = &.{};
    var limit_key: [@sizeOf(ChunkKey) + 1]u8 = @splat(std.math.maxInt(u8));
    write.deleteRange(self.chunk_grid_column.handle, start_key, &limit_key);
    write.deleteRange(self.chunkdata_column.handle, start_key, &limit_key);

    var err_str: ?rocksdb.Data = null;
    defer if (err_str) |s| s.deinit();
    try self.database.write(write, &err_str);
    try self.database.flush(self.chunk_grid_column.handle, &err_str);
    try self.database.flush(self.chunkdata_column.handle, &err_str);
}

/// Saves a chunk to the database according to the configured save mode.
pub fn saveChunk(self: *@This(), io: std.Io, chunk: *Chunk, chunk_pos: World.ChunkPos) !void {
    const z = tracy.Zone.begin(.{ .src = @src() });
    defer z.end();

    try self.options_lock.lockShared(io);
    const save_mode = self.save_mode.*;
    self.options_lock.unlockShared(io);
    switch (save_mode) {
        .everything => {},
        .modified_grids_all_uniforms => switch (chunk.encoding) {
            .uniform => {},
            .grid => if (!chunk.modified.load(.seq_cst)) return,
        },
        .only_modified => if (!chunk.modified.load(.seq_cst)) return,
    }

    const was_modified = chunk.modified.swap(false, .acq_rel);
    errdefer if (was_modified) chunk.modified.store(true, .release);

    // Null is "no data", never content: persisting it would pin an empty row
    // that shadows live generation on every later load. Drop it in all modes,
    // clearing the flag so the background saver does not retry it forever.
    if (chunk.encoding == .uniform and chunk.encoding.uniform == .null) {
        return;
    }

    const key: ChunkKey = .{ .x = chunk_pos.position[0], .y = chunk_pos.position[1], .z = chunk_pos.position[2], .level = chunk_pos.level };
    const data: ChunkData = .{
        .encoding = chunk.encoding,
        .structures_generated = chunk.structures_generated.load(.seq_cst),
        .one_block = if (chunk.encoding == .uniform) chunk.encoding.uniform else undefined,
    };
    var err_str: ?rocksdb.Data = null;
    defer if (err_str) |s| {
        std.log.err("{s}", .{s.data});
        s.deinit();
    };
    switch (chunk.encoding) {
        .grid => |blocks| {
            var write: rocksdb.WriteBatch = .init();
            defer write.deinit();
            write.put(self.chunk_grid_column.handle, std.mem.asBytes(&key), std.mem.asBytes(blocks));
            write.put(self.chunkdata_column.handle, std.mem.asBytes(&key), std.mem.asBytes(&data));
            try self.database.write(write, &err_str);
        },
        .uniform => {
            try self.database.put(self.chunkdata_column.handle, std.mem.asBytes(&key), std.mem.asBytes(&data), &err_str);
        },
    }
    chunk.saved.store(true, .unordered);
}

pub fn getBlocks(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, blocks: *Chunk.Encoding, chunk_pos: World.ChunkPos, grid_buffer: *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]World.Block) error{ Unrecoverable, OutOfMemory, Canceled }!?World.ChunkSource.GetBlocksMetadata {
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

    if (data_bytes.data.len != @sizeOf(ChunkData)) {
        data_bytes.deinit();
        return error.Unrecoverable;
    }
    var data = std.mem.bytesToValue(ChunkData, data_bytes.data);
    data_bytes.deinit();

    var grid_bytes: ?rocksdb.Data = null;
    defer if (grid_bytes) |b| b.deinit();
    if (data.encoding == .uniform) {
        blocks.mergeUniform(data.one_block);
    } else {
        // Single retry: assumes any storage race settles after one re-read;
        // a still-missing grid is treated as corruption (Unrecoverable), not retried.
        grid_bytes = self.database.get(self.chunk_grid_column.handle, std.mem.asBytes(&key), &err_str) catch return error.Unrecoverable;
        if (grid_bytes == null) { // encoding may have changed; refetch data once
            const new_data_bytes = (self.database.get(self.chunkdata_column.handle, std.mem.asBytes(&key), &err_str) catch return error.Unrecoverable) orelse return null;
            defer new_data_bytes.deinit();
            if (new_data_bytes.data.len != @sizeOf(ChunkData)) return error.Unrecoverable;
            data = std.mem.bytesToValue(ChunkData, new_data_bytes.data);
            if (data.encoding == .uniform) {
                blocks.mergeUniform(data.one_block);
                return .{ .from_disk = true, .structures = data.structures_generated };
            }
            grid_bytes = (self.database.get(self.chunk_grid_column.handle, std.mem.asBytes(&key), &err_str) catch return error.Unrecoverable) orelse return error.Unrecoverable;
        }
        if (grid_bytes.?.data.len != @sizeOf([ChunkSize][ChunkSize][ChunkSize]World.Block)) return error.Unrecoverable;
        blocks.mergeGrid(@ptrCast(@alignCast(grid_bytes.?.data)), grid_buffer);
    }

    return .{ .from_disk = true, .structures = data.structures_generated };
}

fn deinitSource(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World) void {
    _ = world;
    _ = io;
    const self: *@This() = @ptrCast(@alignCast(source.data));
    self.deinit(allocator);
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    std.debug.assert(self.is_init);
    self.is_init = false;
    var es1: ?rocksdb.Data = null;
    defer if (es1) |s| s.deinit();
    self.database.flush(self.chunk_grid_column.handle, &es1) catch |err| std.log.warn("Flush failed: {any}\n", .{err});
    var es2: ?rocksdb.Data = null;
    defer if (es2) |s| s.deinit();
    self.database.flush(self.chunkdata_column.handle, &es2) catch |err| std.log.warn("Flush failed: {any}\n", .{err});
    self.database.deinit();
    _ = allocator;
}
