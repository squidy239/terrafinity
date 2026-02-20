const std = @import("std");
const Block = @import("Block.zig").Block;
const Cache = @import("Cache").Cache;
const Chunk = @import("Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("World.zig");
const rocksdb = @import("rocksdb");
const ztracy = @import("ztracy");
const builtin = @import("builtin");

isinit: bool,
config: Config,
database: rocksdb.Database(.Multiple),
options: *rocksdb.c.rocksdb_options_t,

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
pub fn init(path: [:0]const u8, config: Config, allocator: std.mem.Allocator) !@This() {
    const cpu_count = try std.Thread.getCpuCount();
    var storage: @This() = undefined;
    storage.isinit = true;
    storage.config = config;

    storage.options = rocksdb.c.rocksdb_options_create() orelse return error.OutOfMemory;

    rocksdb.c.rocksdb_options_set_create_if_missing(storage.options, 1);
    rocksdb.c.rocksdb_options_increase_parallelism(storage.options, @intCast(cpu_count));
    rocksdb.c.rocksdb_options_set_compression(storage.options, @intFromEnum(config.compression));

    storage.database = try .openRaw(allocator, path, storage.options);
    return storage;
}

const ChunkKey = packed struct {
    x: i32,
    y: i32,
    z: i32,
    level: i32,
};

fn onUnload(source: World.ChunkSource, world: *World, chunk: *Chunk, Pos: World.ChunkPos) error{Unrecoverable}!void {
    _ = world;
    const self: *@This() = @ptrCast(@alignCast(source.data));
    self.saveChunk(chunk, Pos) catch return error.Unrecoverable;
}

const EncodingTagType = std.meta.Tag(std.meta.Tag(Chunk.BlockEncoding)); //get the type of the tagged unions tag
const BlockTagType = std.meta.Tag(Block);
///saves a chunk to the database if it has been modified
pub fn saveChunk(self: *@This(), chunk: *Chunk, chunk_pos: World.ChunkPos) !void {
    if (chunk.modified.load(.seq_cst) == false) return;
    var key: ChunkKey = .{ .x = chunk_pos.position[0], .y = chunk_pos.position[1], .z = chunk_pos.position[2], .level = chunk_pos.level };
    const buf_size = (ChunkSize * ChunkSize * ChunkSize * @sizeOf(Block)) + @sizeOf(EncodingTagType);
    var buffer: [buf_size]u8 = undefined;
    var buf_writer = std.io.Writer.fixed(&buffer);
    chunk.lock.lockShared();
    buf_writer.writeInt(EncodingTagType, @intFromEnum(std.meta.activeTag(chunk.blocks)), .little) catch unreachable;
    switch (chunk.blocks) {
        .blocks => buf_writer.writeSliceEndian(Block, @as([]Block, @ptrCast(chunk.blocks.blocks)), .little) catch unreachable,
        .oneBlock => buf_writer.writeInt(BlockTagType, @intFromEnum(chunk.blocks.oneBlock), .little) catch unreachable,
    }
    chunk.lock.unlockShared();
    if (builtin.target.cpu.arch.endian() == .big) std.mem.byteSwapAllFields(ChunkKey, &key);
    const keybytes = std.mem.asBytes(&key);
    try self.database.put(keybytes, buf_writer.buffered(), .{});
}

pub fn getBlocks(source: World.ChunkSource, world: *World, blocks: *Chunk.BlockEncoding, Pos: World.ChunkPos) error{ Unrecoverable, OutOfMemory }!bool {
    const self: *@This() = @ptrCast(@alignCast(source.data));
    var key = ChunkKey{ .x = Pos.position[0], .y = Pos.position[1], .z = Pos.position[2], .level = Pos.level };
    if (builtin.target.cpu.arch.endian() == .big) std.mem.byteSwapAllFields(ChunkKey, &key);
    const keybytes = std.mem.asBytes(&key);
    const value = self.database.get(keybytes, .{}) catch return error.Unrecoverable;
    if (value == null) return false;

    var buf_reader = std.Io.Reader.fixed(value.?);
    const encoding: std.meta.Tag(Chunk.BlockEncoding) = @enumFromInt(buf_reader.takeInt(EncodingTagType, .little) catch unreachable);
    switch (encoding) {
        .blocks => {
            blocks.toBlocks(&world.block_grid_pool, &world.block_grid_pool_mutex);
            buf_reader.readSliceEndian(Block, @as([]Block, @ptrCast(blocks.blocks)), .little) catch unreachable;
        },
        .oneBlock => blocks.merge(.{ .oneBlock = @enumFromInt(buf_reader.takeInt(BlockTagType, .little) catch unreachable) }, &world.block_grid_pool, &world.block_grid_pool_mutex),
    }
    rocksdb.free(value.?);
    return true;
}

fn deinitSource(source: World.ChunkSource, world: *World) void {
    _ = world;
    const self: *@This() = @ptrCast(@alignCast(source.data));
    self.deinit();
}

pub fn deinit(self: *@This()) void {
    std.debug.assert(self.isinit);
    self.isinit = false;
    self.database.deinit();
    rocksdb.c.rocksdb_options_destroy(self.options);
}

pub const Config = struct {
    compression: enum(i32) {
        none = rocksdb.c.rocksdb_no_compression,
        snappy = rocksdb.c.rocksdb_snappy_compression,
        bz2 = rocksdb.c.rocksdb_bz2_compression,
        zlib = rocksdb.c.rocksdb_zlib_compression,
        lz4 = rocksdb.c.rocksdb_lz4_compression,
        lz4hc = rocksdb.c.rocksdb_lz4hc_compression,
        xpress = rocksdb.c.rocksdb_xpress_compression,
        zstd = rocksdb.c.rocksdb_zstd_compression,
    } = .lz4,
};
