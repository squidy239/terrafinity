const std = @import("std");
const Block = @import("Chunk").Block;
const Cache = @import("Cache").Cache;
const Chunk = @import("Chunk").Chunk;
const ChunkSize = Chunk.ChunkSize;
const World = @import("World.zig");
const rocksdb = @import("root").rocksdb;
const ztracy = @import("ztracy");
const builtin = @import("builtin");

isinit: bool,
config: Config,
database: rocksdb.Database(.Multiple),

pub fn getSource(self: *@This()) World.ChunkSource {
    return .{
        .data = self,
        .getTerrainHeight = null,
        .getBlocks = null,
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
    
    const options = rocksdb.c.rocksdb_options_create() orelse return error.OutOfMemory;
    defer rocksdb.c.rocksdb_options_destroy(options);
    
    rocksdb.c.rocksdb_options_set_create_if_missing(options, 1);
    rocksdb.c.rocksdb_options_increase_parallelism(options, @intCast(cpu_count));
    rocksdb.c.rocksdb_options_optimize_level_style_compaction(options, config.memory_budget);
    
    storage.database = try .openRaw(allocator, path, options);
    

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

fn deinitSource(source: World.ChunkSource, world: *World) void{
    _ = world;
    const self: *@This() = @ptrCast(@alignCast(source.data));
    self.deinit();
}

pub fn deinit(self: *@This()) void {
    std.debug.assert(self.isinit);
    self.isinit = false;
    self.database.deinit();
}

pub const Config = struct {
    memory_budget: u64 = 512 * 1024 * 1024, // 512MiB
};
