const std = @import("std");

const Block = @import("Block.zig").Block;
const ztracy = @import("ztracy");

pub const ChunkSize = 32;
blocks: BlockEncoding,
lock: std.Io.RwLock,
genstate: std.atomic.Value(Genstate),
ref_count: std.atomic.Value(u32),

///time is in us
last_access: std.atomic.Value(i128),

///if this false negitive it means the chunk has not been modified after its load, otherwise it has
modified: std.atomic.Value(bool) = .init(false),

pub const BlockEncoding = union(enum(u8)) {
    blocks: *[ChunkSize][ChunkSize][ChunkSize]Block,
    oneBlock: Block,

    pub fn merge(self: *@This(), io: std.Io, mergeBlocks: BlockEncoding, memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Io.Mutex) void {
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
                            pool_mutex.lockUncancelable(io);
                            memory_pool.destroy(@alignCast(self.blocks));
                            pool_count.* -= 1;
                            pool_mutex.unlock(io);
                            self.* = .{ .oneBlock = mergeBlocks.oneBlock };
                        }
                    },
                }
            },
            .blocks => {
                self.toBlocks(io, memory_pool, pool_count, pool_mutex) catch return;
                const tag = @typeInfo(Block).@"enum".tag_type;
                const flatArray: *[ChunkSize * ChunkSize * ChunkSize]tag = @ptrCast(self.blocks);
                const flatMergeArray: *[ChunkSize * ChunkSize * ChunkSize]tag = @ptrCast(mergeBlocks.blocks);
                const pred = flatArray.* == @as(@Vector(ChunkSize * ChunkSize * ChunkSize, tag), @splat(@intFromEnum(Block.null)));
                flatArray.* = @select(tag, pred, flatArray.*, flatMergeArray.*);

                if (IsOneBlock(self.blocks)) |block| {
                    const f = ztracy.ZoneNC(@src(), "free", 4322);
                    defer f.End();
                    pool_mutex.lockUncancelable(io);
                    memory_pool.destroy(@alignCast(self.blocks));
                    pool_count.* -= 1;
                    pool_mutex.unlock(io);
                    self.* = .{ .oneBlock = block };
                }
            },
        }
    }

    pub fn toBlocks(self: *@This(), io: std.Io, memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Io.Mutex) !void {
        if (self.* == .blocks) return;
        const t = ztracy.ZoneNC(@src(), "toBlocks", 10);
        defer t.End();
        const a = ztracy.ZoneNC(@src(), "alloc", 54334);
        var mem: *[ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        while (true) {
            pool_mutex.lockUncancelable(io);
            mem = memory_pool.create(undefined) catch {
                pool_mutex.unlock(io);
                try io.sleep(.fromMicroseconds(100), .awake);
                std.log.err("Failed to allocate memory for chunk blocks, retrying...", .{});
                continue;
            };
            pool_count.* += 1;
            pool_mutex.unlock(io);
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

/// Returns a chunk made from a given blockencoding. The chunk is allocated from the pool.
pub fn from(blockEncoding: BlockEncoding, io: std.Io, chunk_pool: anytype, pool_count: *u64, pool_mutex: *std.Io.Mutex) !*@This() {
    var chunk: *@This() = undefined;
    while (true) {
        try pool_mutex.lock(io);
        chunk = chunk_pool.create(undefined) catch {
            pool_mutex.unlock(io);
            std.log.err("Failed to allocate memory for chunk, retrying...", .{});
            try io.sleep(.fromMicroseconds(1), .awake);
            continue;
        };
        pool_count.* += 1;
        pool_mutex.unlock(io);
        break;
    }
    chunk.* = .{
        .blocks = blockEncoding,
        .lock = .init,
        .last_access = .init(std.Io.Timestamp.now(io, .awake).nanoseconds),
        .genstate = std.atomic.Value(Genstate).init(.TerrainGenerated),
        .ref_count = std.atomic.Value(u32).init(1),
    };
    return chunk;
}

/// Checks if the block array is all the same block.
pub fn IsOneBlock(blockArray: *const [ChunkSize][ChunkSize][ChunkSize]Block) ?Block {
    const firstBlockVec: @Vector(ChunkSize, @typeInfo(Block).@"enum".tag_type) = @splat(@intFromEnum(blockArray[0][0][0]));
    var isOneBlock: @Vector(ChunkSize, bool) = comptime @splat(true);
    const linearBlockArray: *const [ChunkSize * ChunkSize][ChunkSize]@typeInfo(Block).@"enum".tag_type = @ptrCast(blockArray);
    for (linearBlockArray) |blocks| isOneBlock &= (blocks == firstBlockVec);
    return if (@reduce(.And, isOneBlock)) blockArray[0][0][0] else null;
}

/// Merges the chunk with mergeBlocks, copying all non-null mergeBlocks to blocks.
pub fn merge(self: *@This(), io: std.Io, mergeBlocks: BlockEncoding, memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Io.Mutex, comptime lock: bool) void {
    self.add_ref(io);
    defer self.release(io);
    if (lock) self.lockExclusive(io);
    defer if (lock) self.unlockExclusive(io);
    self.blocks.merge(io, mergeBlocks, memory_pool, pool_count, pool_mutex);
}

pub fn extractFace(self: *@This(), io: std.Io, comptime face: enum { xPlus, xMinus, yPlus, yMinus, zPlus, zMinus }, comptime removeRef: bool) [ChunkSize][ChunkSize]Block {
    self.addAndLockShared(io);
    defer {
        if (removeRef) self.release();
        self.releaseAndUnlockShared(io);
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

/// Returns true if the chunk was converted to blocks, false if it was already blocks.
pub fn ToBlocks(self: *@This(), io: std.Io, memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Io.Mutex, comptime lock: bool) !bool {
    self.add_ref(io);
    defer self.release(io);
    if (lock) self.lockExclusive(io);
    defer if (lock) self.unlockExclusive(io);
    if (self.blocks != .oneBlock) return false;
    try self.blocks.toBlocks(io, memory_pool, pool_count, pool_mutex);
    return true;
}

/// Frees the chunk's blocks, does not free the chunk itself.
/// The chunk must only have 1 ref before calling — use WaitForRefAmount.
pub fn free(self: *@This(), io: std.Io, memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Io.Mutex) void {
    std.debug.assert(self.ref_count.load(.seq_cst) == 1);
    self.lockExclusive(io);
    switch (self.blocks) {
        .blocks => {
            pool_mutex.lockUncancelable(io);
            memory_pool.destroy(@alignCast(self.blocks.blocks));
            pool_count.* -= 1;
            pool_mutex.unlock(io);
        },
        .oneBlock => {},
    }
}

//TODO better timeout with Io
pub fn waitForRefAmount(self: *const @This(), io: std.Io, amount: u32, maxMicroTime: ?u64) error{Canceled}!bool {
    if (self.ref_count.load(.seq_cst) == amount) return true;
    const st = std.Io.Timestamp.now(io, .awake);
    while (self.ref_count.load(.seq_cst) != amount) {
        @branchHint(.unlikely);
        if (maxMicroTime != null and st.untilNow(io, .awake).toMicroseconds() > maxMicroTime.?) return false;
        try std.Io.sleep(io, .fromMicroseconds(1), .awake);
    }
    return true;
}

pub fn touch(self: *@This(), io: std.Io) void {
    self.last_access.store(std.Io.Timestamp.now(io, .awake).toNanoseconds(), .unordered);
}

pub fn touchModify(self: *@This(), io: std.Io) void {
    self.touch(io);
    self.modified.store(true, .seq_cst);
}

pub fn add_ref(self: *@This(), io: std.Io) void {
    _ = self.ref_count.fetchAdd(1, .seq_cst);
    self.touch(io);
}

pub fn release(self: *@This(), io: std.Io) void {
    _ = self.ref_count.fetchSub(1, .seq_cst);
    self.touch(io);
}

pub fn lockExclusive(self: *@This(), io: std.Io) void {
    self.lock.lockUncancelable(io);
    self.touchModify(io);
}

pub fn unlockExclusive(self: *@This(), io: std.Io) void {
    self.lock.unlock(io);
    self.touchModify(io);
}

pub fn lockShared(self: *@This(), io: std.Io) void {
    self.lock.lockSharedUncancelable(io);
    self.touch(io);
}

pub fn unlockShared(self: *@This(), io: std.Io) void {
    self.lock.unlockShared(io);
    self.touch(io);
}

pub fn addAndLockShared(self: *@This(), io: std.Io) void {
    self.lockShared(io);
    _ = self.ref_count.fetchAdd(1, .seq_cst);
}

pub fn addAndLock(self: *@This(), io: std.Io) void {
    self.lockExclusive(io);
    _ = self.ref_count.fetchAdd(1, .seq_cst);
}

pub fn releaseAndUnlock(self: *@This(), io: std.Io) void {
    self.unlockExclusive(io);
    _ = self.ref_count.fetchSub(1, .seq_cst);
}

pub fn releaseAndUnlockShared(self: *@This(), io: std.Io) void {
    self.unlockShared(io);
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
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var chunk = try from(.{ .oneBlock = .stone }, io, allocator);
    defer allocator.destroy(chunk);
    defer chunk.free(io, allocator);

    const converted = try chunk.ToBlocks(io, allocator, true);
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
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var blocks1: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));
    blocks1[0][0][0] = .dirt;

    var blocks2: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.null)));
    blocks2[0][0][1] = .grass;

    const chunk1_encoding = try BlockEncoding.fromBlocks(&blocks1, allocator);
    var chunk1 = try from(chunk1_encoding, io, allocator);
    defer allocator.destroy(chunk1);
    defer chunk1.free(io, allocator);

    const chunk2_encoding = try BlockEncoding.fromBlocks(&blocks2, allocator);

    chunk1.merge(io, chunk2_encoding, allocator, true);

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
