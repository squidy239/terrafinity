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
    const column_families: [1]rocksdb.ColumnFamilyDescription = .{.{ .name = "default", .options = .{ .compression = .zstd } }};
    storage.database, storage.column_families = try rocksdb.DB.open(allocator, path, config, &column_families, false, &err_str);

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
    const save = ztracy.ZoneN(@src(), "saveChunk");
    defer save.End();
    if (chunk.modified.load(.seq_cst) == false) switch (chunk.blocks) {
        .blocks => return,
        .oneBlock => {}, //save chunk if it is just one block
    };

    const key: ChunkKey = .{ .x = chunk_pos.position[0], .y = chunk_pos.position[1], .z = chunk_pos.position[2], .level = chunk_pos.level };
    try chunk.lock.lockShared(io);
    const bytes = switch (chunk.blocks) {
        .blocks => |blocks| std.mem.asBytes(blocks),
        .oneBlock => |block| std.mem.asBytes(&block),
    };
    var err_str: ?rocksdb.Data = null;
    try self.database.put(self.column_families[0].handle, std.mem.asBytes(&key), bytes, &err_str);
    chunk.lock.unlockShared(io);

    if (err_str) |s| {
        std.log.err("{s}", .{s.data});
        s.deinit();
    }
}

pub fn getBlocks(source: World.ChunkSource, io: std.Io, allocator: std.mem.Allocator, world: *World, blocks: *Chunk.BlockEncoding, Pos: World.ChunkPos) error{ Unrecoverable, OutOfMemory, Canceled }!bool {
    const load = ztracy.ZoneN(@src(), "getBlocks");
    defer load.End();

    const self: *@This() = @ptrCast(@alignCast(source.data));
    _ = allocator;
    var key = ChunkKey{ .x = Pos.position[0], .y = Pos.position[1], .z = Pos.position[2], .level = Pos.level };
    var err_str: ?rocksdb.Data = null;
    const value = (self.database.get(self.column_families[0].handle, std.mem.asBytes(&key), &err_str) catch return error.Unrecoverable) orelse return false;

    if (err_str) |s| {
        std.log.err("{s}", .{s.data});
        s.deinit();
    }

    defer value.deinit();

    const encoding_type: std.meta.Tag(Chunk.BlockEncoding) = switch (value.data.len) {
        @sizeOf(Block) => .oneBlock,
        @sizeOf([ChunkSize][ChunkSize][ChunkSize]Block) => .blocks,
        else => unreachable,
    };

    const mergeblocks: Chunk.BlockEncoding = switch (encoding_type) {
        .blocks => .{ .blocks = @ptrCast(@alignCast(@constCast(value.data))) },
        .oneBlock => .{ .oneBlock = std.mem.bytesToValue(Block, value.data) },
    };

    try blocks.merge(io, mergeblocks, &world.block_grid_pool, &world.block_grid_count, &world.block_grid_pool_mutex);
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
