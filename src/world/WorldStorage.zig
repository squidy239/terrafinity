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
database: rocksdb.database.DB,
options: rocksdb.DBOptions,
column_families: []const rocksdb.ColumnFamily,

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
pub fn init(path: []const u8, config: rocksdb.DBOptions, allocator: std.mem.Allocator) !@This() {
    var storage: @This() = undefined;
    storage.isinit = true;
    storage.options = config;
    var err_str: ?rocksdb.Data = null;
    defer if (err_str) |s| {
        std.log.err("{s}", .{s.data});
        s.deinit();
    };
    storage.database, storage.column_families = try rocksdb.DB.open(allocator, path, config, null, false, &err_str);
    errdefer storage.database.deinit();
    errdefer allocator.free(storage.column_families);

    return storage;
}

const ChunkKey = packed struct {
    x: i32,
    y: i32,
    z: i32,
    level: i32,
};

fn onUnload(source: World.ChunkSource, io: std.Io, world: *World, chunk: *Chunk, Pos: World.ChunkPos) error{Unrecoverable}!void {
    _ = world;
    const self: *@This() = @ptrCast(@alignCast(source.data));
    self.saveChunk(io, chunk, Pos) catch return error.Unrecoverable;
}

const EncodingTagType = std.meta.Tag(std.meta.Tag(Chunk.BlockEncoding)); //get the type of the tagged unions tag
const BlockTagType = std.meta.Tag(Block);
///saves a chunk to the database if it has been modified
pub fn saveChunk(self: *@This(), io: std.Io, chunk: *Chunk, chunk_pos: World.ChunkPos) !void {
    if (chunk.modified.load(.seq_cst) == false) return;
    var key: ChunkKey = .{ .x = chunk_pos.position[0], .y = chunk_pos.position[1], .z = chunk_pos.position[2], .level = chunk_pos.level };
    const buf_size = (ChunkSize * ChunkSize * ChunkSize * @sizeOf(Block)) + @sizeOf(EncodingTagType);
    var buffer: [buf_size]u8 = undefined;
    var buf_writer = std.Io.Writer.fixed(&buffer);
    chunk.lock.lockSharedUncancelable(io);
    buf_writer.writeInt(EncodingTagType, @intFromEnum(std.meta.activeTag(chunk.blocks)), .little) catch unreachable;
    switch (chunk.blocks) {
        .blocks => buf_writer.writeSliceEndian(Block, @as([]Block, @ptrCast(chunk.blocks.blocks)), .little) catch unreachable,
        .oneBlock => buf_writer.writeInt(BlockTagType, @intFromEnum(chunk.blocks.oneBlock), .little) catch unreachable,
    }
    chunk.lock.unlockShared(io);
    if (builtin.target.cpu.arch.endian() == .big) std.mem.byteSwapAllFields(ChunkKey, &key);
    const keybytes = std.mem.asBytes(&key);
    var err_str: ?rocksdb.Data = null;
    defer if (err_str) |s| {
        std.log.err("{s}", .{s.data});
        s.deinit();
    };
    try self.database.put(self.column_families[0].handle, keybytes, buf_writer.buffered(), &err_str);
}

pub fn getBlocks(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, blocks: *Chunk.BlockEncoding, Pos: World.ChunkPos) error{ Unrecoverable, OutOfMemory, Canceled }!bool {
    const self: *@This() = @ptrCast(@alignCast(source.data));
    _ = allocator;
    var key = ChunkKey{ .x = Pos.position[0], .y = Pos.position[1], .z = Pos.position[2], .level = Pos.level };
    if (builtin.target.cpu.arch.endian() == .big) std.mem.byteSwapAllFields(ChunkKey, &key);
    const keybytes = std.mem.asBytes(&key);
    var err_str: ?rocksdb.Data = null;
    defer if (err_str) |s| s.deinit();
    const value = (self.database.get(self.column_families[0].handle, keybytes, &err_str) catch return error.Unrecoverable) orelse return false;
    defer value.deinit();

    var buf_reader = std.Io.Reader.fixed(value.data);
    const encoding: std.meta.Tag(Chunk.BlockEncoding) = @enumFromInt(buf_reader.takeInt(EncodingTagType, .little) catch unreachable);
    switch (encoding) {
        .blocks => {
            try blocks.toBlocks(io, &world.block_grid_pool, &world.block_grid_count, &world.block_grid_pool_mutex);
            buf_reader.readSliceEndian(Block, @as([]Block, @ptrCast(blocks.blocks)), .little) catch unreachable;
        },
        .oneBlock => try blocks.merge(io, .{ .oneBlock = @enumFromInt(buf_reader.takeInt(BlockTagType, .little) catch unreachable) }, &world.block_grid_pool, &world.block_grid_count, &world.block_grid_pool_mutex, null),
    }
    return true;
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
    allocator.free(self.column_families);
}
