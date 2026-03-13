const std = @import("std");

const Block = @import("Block.zig").Block;
const ztracy = @import("ztracy");

pub const ChunkSize = 32;
blocks: BlockEncoding,
lock: std.Thread.RwLock,
genstate: std.atomic.Value(Genstate),
ref_count: std.atomic.Value(u32),

///time is in us
last_access: std.atomic.Value(i64),

///if this false negitive it means the chunk has not been modified after its load, otherwise it has
modified: std.atomic.Value(bool) = .init(false),

pub const BlockEncoding = union(enum(u8)) {
    blocks: *[ChunkSize][ChunkSize][ChunkSize]Block,
    oneBlock: Block,

    pub fn merge(self: *@This(), mergeBlocks: BlockEncoding, memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Thread.Mutex) void {
        const m = ztracy.ZoneNC(@src(), "merge", 10);
        defer m.End();

        if (mergeBlocks == .oneBlock and (mergeBlocks.oneBlock == .null)) return;
        switch (mergeBlocks) {
            .oneBlock => {
                switch (self.*) {
                    .oneBlock => {
                        if (mergeBlocks.oneBlock != .null)
                            self.* = mergeBlocks;
                    },
                    .blocks => {
                        if (mergeBlocks.oneBlock != .null) {
                            pool_mutex.lock();
                            memory_pool.destroy(@alignCast(self.blocks));
                            pool_count.* -= 1;
                            pool_mutex.unlock();
                            self.* = .{ .oneBlock = mergeBlocks.oneBlock };
                        }
                    },
                }
            },
            .blocks => {
                self.toBlocks(memory_pool, pool_count, pool_mutex);
                const tag = @typeInfo(Block).@"enum".tag_type;
                const flatArray: *[ChunkSize * ChunkSize * ChunkSize]tag = @ptrCast(self.blocks);
                const flatMergeArray: *[ChunkSize * ChunkSize * ChunkSize]tag = @ptrCast(mergeBlocks.blocks);
                const pred = flatArray.* == @as(@Vector(ChunkSize * ChunkSize * ChunkSize, tag), @splat(@intFromEnum(Block.null)));
                flatArray.* = @select(tag, pred, flatArray.*, flatMergeArray.*);

                if (IsOneBlock(self.blocks)) |block| {
                    const f = ztracy.ZoneNC(@src(), "free", 4322);
                    defer f.End();
                    pool_mutex.lock();
                    memory_pool.destroy(@alignCast(self.blocks)); //if it was created in the pool it has the alignment of the pool
                    pool_count.* -= 1;
                    pool_mutex.unlock();
                    self.* = .{ .oneBlock = block };
                }
            },
        }
    }

    pub fn toBlocks(self: *@This(), memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Thread.Mutex) void {
        if (self.* == .blocks) return;
        const t = ztracy.ZoneNC(@src(), "toBlocks", 10);
        defer t.End();
        const a = ztracy.ZoneNC(@src(), "alloc", 54334);
        var mem: *[ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        while (true) {
            pool_mutex.lock();
            mem = memory_pool.create() catch {
                pool_mutex.unlock();
                std.log.err("Failed to allocate memory for chunk blocks, retrying...", .{});
                std.Thread.yield() catch {};
                continue;
            };
            pool_count.* += 1;
            pool_mutex.unlock();
            break;
        }
        a.End();
        const flatblocks: *[ChunkSize * ChunkSize * ChunkSize]Block = @ptrCast(mem);
        @memset(flatblocks, self.oneBlock);
        self.* = .{ .blocks = mem };
    }
};

pub const Genstate = enum(u8) {
    TerrainGenerated,
    StructuresGenerated,
};

///Returns a chunk made from a given blockencoding. The blocks and returned chunk are allocated by the allocator.
pub fn from(blockEncoding: BlockEncoding, chunk_pool: anytype, pool_count: *u64, pool_mutex: *std.Thread.Mutex) *@This() {
    var chunk: *@This() = undefined;
    while (true) {
        pool_mutex.lock();
        chunk = chunk_pool.create() catch {
            pool_mutex.unlock();
            std.log.err("Failed to allocate memory for chunk, retrying...", .{});
            std.Thread.yield() catch {};
            continue;
        };
        pool_count.* += 1;
        pool_mutex.unlock();
        break;
    }
    chunk.* = .{
        .blocks = blockEncoding,
        .lock = .{},
        .last_access = .init(std.time.microTimestamp()),
        .genstate = std.atomic.Value(Genstate).init(.TerrainGenerated),
        .ref_count = std.atomic.Value(u32).init(1),
    };
    return chunk;
}

///checks if the block array is all the same block
pub fn IsOneBlock(blockArray: *const [ChunkSize][ChunkSize][ChunkSize]Block) ?Block {
    const firstBlockVec: @Vector(ChunkSize, @typeInfo(Block).@"enum".tag_type) = @splat(@intFromEnum(blockArray[0][0][0]));
    var isOneBlock: @Vector(ChunkSize, bool) = comptime @splat(true);
    const linearBlockArray: *const [ChunkSize * ChunkSize][ChunkSize]@typeInfo(Block).@"enum".tag_type = @ptrCast(blockArray);
    for (linearBlockArray) |blocks| isOneBlock &= (blocks == firstBlockVec);
    return if (@reduce(.And, isOneBlock)) blockArray[0][0][0] else null;
}

///merges the chunk with the mergeBlocks, copies all non null mergeBlocks to blocks
pub fn merge(self: *@This(), mergeBlocks: BlockEncoding, memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Thread.Mutex, comptime lock: bool) void {
    self.add_ref();
    defer self.release();
    if (lock) self.lockExclusive();
    defer if (lock) self.unlockExclusive();
    self.blocks.merge(mergeBlocks, memory_pool, pool_count, pool_mutex);
}

pub fn extractFace(self: *@This(), comptime face: enum { xPlus, xMinus, yPlus, yMinus, zPlus, zMinus }, comptime removeRef: bool) [ChunkSize][ChunkSize]Block {
    self.addAndLockShared();
    defer {
        if (removeRef) self.release();
        self.releaseAndUnlockShared();
    }
    var cube: *const [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
    switch (self.blocks) {
        .blocks => cube = self.blocks.blocks,
        .oneBlock => {
            return @splat(@splat(self.blocks.oneBlock));
        },
    }
    var result: [ChunkSize][ChunkSize]Block = undefined;
    for (&result, 0..) |*row, i| {
        inline for (row, 0..) |*item, j| {
            item.* = switch (comptime face) {
                .xPlus => cube[ChunkSize - 1][i][j],
                .xMinus => cube[0][i][j],
                .yPlus => cube[i][ChunkSize - 1][j],
                .yMinus => cube[i][0][j],
                .zPlus => cube[i][j][ChunkSize - 1],
                .zMinus => cube[i][j][0],
            };
        }
    }
    return result;
}
///returns true if the chunk was converted to blocks, false if it was already blocks
pub fn ToBlocks(self: *@This(), memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Thread.Mutex, comptime lock: bool) !bool {
    self.add_ref();
    defer self.release();
    if (lock) self.lockExclusive();
    defer if (lock) self.unlockExclusive();
    if (self.blocks != .oneBlock) return false;
    self.blocks.toBlocks(memory_pool, pool_count, pool_mutex);
    return true;
}

///frees the chunk's blocks, does not free the chunk itself
///the chunk must only be 1 ref before calling, use WaitForRefAmount
///locks the chunk
pub fn free(self: *@This(), memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Thread.Mutex) void {
    std.debug.assert(self.ref_count.load(.seq_cst) == 1);
    self.lockExclusive();
    switch (self.blocks) {
        .blocks => {
            pool_mutex.lock();
            memory_pool.destroy(@alignCast(self.blocks.blocks));
            pool_count.* -= 1;
            pool_mutex.unlock();
        },
        .oneBlock => {},
    }
}

pub fn WaitForRefAmount(self: *const @This(), amount: u32, maxMicroTime: ?u64) bool {
    if (self.ref_count.load(.seq_cst) == amount) return true;
    const st = std.time.microTimestamp();
    while (self.ref_count.load(.seq_cst) != amount) {
        if (maxMicroTime != null and (std.time.microTimestamp() - st) > maxMicroTime.?) return false;
        std.Thread.yield() catch |err| std.debug.print("yield err:{any}\n", .{err});
    }
    return true;
}

pub fn touch(self: *@This()) void {
    self.last_access.store(std.time.microTimestamp(), .unordered);
}

pub fn touchModify(self: *@This()) void {
    self.touch();
    self.modified.store(true, .seq_cst);
}

pub fn add_ref(self: *@This()) void {
    _ = self.ref_count.fetchAdd(1, .seq_cst);
    self.touch();
}

pub fn release(self: *@This()) void {
    _ = self.ref_count.fetchSub(1, .seq_cst);
    self.touch();
}

pub fn lockExclusive(self: *@This()) void {
    self.lock.lock();
    self.touchModify();
}

pub fn unlockExclusive(self: *@This()) void {
    self.lock.unlock();
    self.touchModify();
}

pub fn lockShared(self: *@This()) void {
    self.lock.lockShared();
    self.touch();
}

pub fn unlockShared(self: *@This()) void {
    self.lock.unlockShared();
    self.touch();
}

pub fn addAndLockShared(self: *@This()) void {
    _ = self.ref_count.fetchAdd(1, .seq_cst);
    self.lockShared();
}
pub fn addAndlock(self: *@This()) void {
    _ = self.ref_count.fetchAdd(1, .seq_cst);
    self.lockExclusive();
}

pub fn releaseAndUnlock(self: *@This()) void {
    self.unlockExclusive();
    _ = self.ref_count.fetchSub(1, .seq_cst);
}

pub fn releaseAndUnlockShared(self: *@This()) void {
    self.unlockShared();
    _ = self.ref_count.fetchSub(1, .seq_cst);
}

test "IsOneBlock" {
    const testing = std.testing;
    var one_block_chunk: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));
    one_block_chunk[0][0][0] = .stone;
    try testing.expect(IsOneBlock(&one_block_chunk) == null);

    var all_stone_chunk: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.stone)));
    try testing.expect(IsOneBlock(&all_stone_chunk) != null);
    try testing.expect(IsOneBlock(&all_stone_chunk).? == .stone);
}

test "ToBlocks" {
    if (true) return error.SkipZigTest;
    const testing = std.testing;
    const allocator = std.testing.allocator;
    var chunk = try from(.{ .oneBlock = .stone }, allocator);
    defer allocator.destroy(chunk);
    defer chunk.free(allocator);

    const converted = try chunk.ToBlocks(allocator, true);
    try testing.expect(converted);

    switch (chunk.blocks) {
        .oneBlock => unreachable,
        .blocks => |blocks| {
            try testing.expect(blocks[0][0][0] == .stone);
            try testing.expect(blocks[10][20][30] == .stone);
        },
    }
}

test "Merge" {
    if (true) return error.SkipZigTest;
    const testing = std.testing;
    const allocator = std.testing.allocator;

    var blocks1: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));
    blocks1[0][0][0] = .dirt;

    var blocks2: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.null)));
    blocks2[0][0][1] = .grass;

    const chunk1_encoding = try BlockEncoding.fromBlocks(&blocks1, allocator);
    var chunk1 = try from(chunk1_encoding, allocator);
    defer allocator.destroy(chunk1);
    defer chunk1.free(allocator);

    const chunk2_encoding = try BlockEncoding.fromBlocks(&blocks2, allocator);

    try chunk1.merge(chunk2_encoding, allocator, true);

    allocator.destroy(chunk2_encoding.blocks);

    switch (chunk1.blocks) {
        .oneBlock => return error.TestFailed,
        .blocks => |blocks| {
            try testing.expect(blocks[0][0][0] == .dirt);
            try testing.expect(blocks[0][0][1] == .grass);
            try testing.expect(blocks[1][1][1] == .air);
        },
    }
}
