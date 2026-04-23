const std = @import("std");
const builtin = @import("builtin");

const ztracy = @import("ztracy");

const Block = @import("Block.zig").Block;

pub const ChunkSize = 32;
blocks: BlockEncoding,
lock: std.Io.RwLock = .init,
genstate: std.atomic.Value(Genstate),
ref_count: std.atomic.Value(u32),

last_access: std.atomic.Value(i128),

///if this false negitive it means the chunk has not been modified after its load, otherwise it has
modified: std.atomic.Value(bool) = .init(false),

pub const BlockEncoding = union(enum(u8)) {
    blocks: *[ChunkSize][ChunkSize][ChunkSize]Block,
    one_block: Block,

    pub fn merge(self: *@This(), io: std.Io, mergeBlocks: BlockEncoding, memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Io.Mutex) !void {
        const m = ztracy.ZoneNC(@src(), "merge", 10);
        defer m.End();
        if (mergeBlocks == .one_block and (mergeBlocks.one_block == .null)) return;
        switch (mergeBlocks) {
            .one_block => {
                switch (self.*) {
                    .one_block => {
                        if (mergeBlocks.one_block != .null) {
                            self.* = mergeBlocks;
                        }
                    },
                    .blocks => {
                        if (mergeBlocks.one_block != .null) {
                            //safe because caller holds the lock
                            try pool_mutex.lock(io);
                            memory_pool.destroy(@alignCast(self.blocks));
                            pool_count.* -= 1;
                            pool_mutex.unlock(io);

                            self.* = .{ .one_block = mergeBlocks.one_block };
                        }
                    },
                }
            },
            .blocks => {
                try self.toBlocks(io, memory_pool, pool_count, pool_mutex);
                const tag = @typeInfo(Block).@"enum".tag_type;
                const flatArray: *[ChunkSize * ChunkSize * ChunkSize]tag = @ptrCast(self.blocks);
                const flatMergeArray: *[ChunkSize * ChunkSize * ChunkSize]tag = @ptrCast(mergeBlocks.blocks);

                selectBlocks(tag, ChunkSize * ChunkSize * ChunkSize, flatArray, flatMergeArray);
                if (isOneBlock(self.blocks)) |block| {
                    @branchHint(.unlikely);
                    const f = ztracy.ZoneNC(@src(), "free", 4322);
                    defer f.End();

                    try pool_mutex.lock(io);
                    memory_pool.destroy(@alignCast(self.blocks));
                    pool_count.* -= 1;
                    pool_mutex.unlock(io);

                    self.* = .{ .one_block = block };
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
            try pool_mutex.lock(io);
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
        @memset(flatblocks, self.one_block);
        self.* = .{ .blocks = mem };
    }

    pub fn fromBlocks(blocks: *[ChunkSize][ChunkSize][ChunkSize]Block) BlockEncoding {
        return if (isOneBlock(blocks)) |one_block| .{ .one_block = one_block } else .{ .blocks = blocks };
    }

    test "merge" {
        try std.testing.fuzz(std.testing.io, testOne, .{});
    }

    fn testOne(io: std.Io, smith: *std.testing.Smith) !void {
        var pool: std.heap.MemoryPool([ChunkSize][ChunkSize][ChunkSize]Block) = try .initCapacity(std.testing.allocator, 1);
        defer pool.deinit(std.testing.allocator);
        var g1: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        var g2: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        var b1: BlockEncoding = switch (smith.value(@typeInfo(BlockEncoding).@"union".tag_type.?)) {
            .blocks => blk: {
                g1 = smith.value([ChunkSize][ChunkSize][ChunkSize]Block);
                break :blk BlockEncoding{ .blocks = &g1 };
            },
            .one_block => .{ .one_block = smith.value(Block) },
        };
        const b2: BlockEncoding = switch (smith.value(@typeInfo(BlockEncoding).@"union".tag_type.?)) {
            .blocks => blk: {
                g2 = smith.value([ChunkSize][ChunkSize][ChunkSize]Block);
                break :blk BlockEncoding{ .blocks = &g2 };
            },
            .one_block => .{ .one_block = smith.value(Block) },
        };
        var pc: u64 = 2;
        var pm: std.Io.Mutex = .init;
        try b1.merge(io, b2, &pool, &pc, &pm);
    }
};

pub const ChunkFaceEncoding = union(enum(u8)) {
    blocks: [ChunkSize][ChunkSize]Block,
    one_block: Block,
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
        .last_access = .init(std.Io.Timestamp.now(io, .awake).nanoseconds),
        .genstate = std.atomic.Value(Genstate).init(.TerrainGenerated),
        .ref_count = std.atomic.Value(u32).init(1),
    };
    return chunk;
}

///checks if the block array is all the same block
pub fn isOneBlock(blockArray: *const [ChunkSize][ChunkSize][ChunkSize]Block) ?Block {
    const firstBlockVec: @Vector(ChunkSize, @typeInfo(Block).@"enum".tag_type) = @splat(@intFromEnum(blockArray[0][0][0]));
    var oneblock: @Vector(ChunkSize, bool) = comptime @splat(true);
    const linearBlockArray: *const [ChunkSize * ChunkSize][ChunkSize]@typeInfo(Block).@"enum".tag_type = @ptrCast(blockArray);
    for (linearBlockArray) |blocks| oneblock &= (blocks == firstBlockVec);
    return if (@reduce(.And, oneblock)) blockArray[0][0][0] else null;
}

/// Merges the chunk with mergeBlocks, copying all non-null mergeBlocks to blocks.
pub fn merge(self: *@This(), io: std.Io, mergeBlocks: BlockEncoding, memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Io.Mutex) !void {
    try self.addAndLock(io);
    defer self.releaseAndUnlock(io);
    try self.blocks.merge(io, mergeBlocks, memory_pool, pool_count, pool_mutex);
}

pub fn extractFace(self: *@This(), io: std.Io, comptime face: enum { xPlus, xMinus, yPlus, yMinus, zPlus, zMinus }, comptime removeRef: bool) !ChunkFaceEncoding {
    try self.addAndLockShared(io);
    defer {
        if (removeRef) self.release(io);
        self.releaseAndUnlockShared(io);
    }
    var cube: *const [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
    switch (self.blocks) {
        .blocks => cube = self.blocks.blocks,
        .one_block => |block| return .{ .one_block = block },
    }
    var result: [ChunkSize][ChunkSize]Block = undefined;
    @setEvalBranchQuota(10000);
    inline for (&result, 0..) |*row, i| {
        inline for (row, 0..) |*item, j| {
            item.* = switch (comptime face) {
                .xPlus => cube[ChunkSize - 1][i][comptime j],
                .xMinus => cube[0][comptime i][comptime j],
                .yPlus => cube[comptime i][ChunkSize - 1][comptime j],
                .yMinus => cube[comptime i][0][comptime j],
                .zPlus => cube[comptime i][comptime j][ChunkSize - 1],
                .zMinus => cube[comptime i][comptime j][0],
            };
        }
    }
    return .{ .blocks = result };
}

/// Returns true if the chunk was converted to blocks, false if it was already blocks.
pub fn toBlocks(self: *@This(), io: std.Io, memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Io.Mutex, comptime lock: bool) !bool {
    self.add_ref(io);
    defer self.release(io);
    if (lock) try self.lockExclusive(io);
    defer if (lock) self.unlockExclusive(io);
    if (self.blocks != .one_block) return false;
    try self.blocks.toBlocks(io, memory_pool, pool_count, pool_mutex);
    return true;
}

/// Frees the chunk's blocks, does not free the chunk itself.
/// The chunk must only have 1 ref before calling — use WaitForRefAmount.
pub fn free(self: *@This(), io: std.Io, memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Io.Mutex) void {
    std.debug.assert(self.ref_count.load(.seq_cst) == 1);
    _ = io.swapCancelProtection(.blocked);
    self.lockExclusive(io) catch unreachable;
    _ = io.swapCancelProtection(.unblocked);
    defer self.unlockExclusive(io);
    switch (self.blocks) {
        .blocks => {
            pool_mutex.lockUncancelable(io);
            memory_pool.destroy(@alignCast(self.blocks.blocks));
            pool_count.* -= 1;
            pool_mutex.unlock(io);
        },
        .one_block => {},
    }
}

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

fn selectBlocks(comptime T: type, comptime len: usize, flatArray: *[len]T, flatMergeArray: *const [len]T) void {
    if (comptime std.simd.suggestVectorLength(T)) |vlen| {
        const VT = @Vector(vlen, T);
        var i: usize = 0;
        while (i + vlen <= len) : (i += vlen) {
            const a: VT = flatArray.*[i..][0..vlen].*;
            const b: VT = flatMergeArray[i..][0..vlen].*;
            const pred = b == comptime @as(VT, @splat(@intFromEnum(Block.null)));
            const result = @select(T, pred, a, b);
            flatArray.*[i..][0..vlen].* = result;
        }
        // handle remainder scalarly
        while (i < len) : (i += 1) {
            if (flatMergeArray[i] != comptime @intFromEnum(Block.null)) {
                flatArray.*[i] = flatMergeArray[i];
            }
        }
    } else {
        for (0..len) |i| {
            if (flatMergeArray[i] != comptime @intFromEnum(Block.null)) {
                flatArray.*[i] = flatMergeArray[i];
            }
        }
    }
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

pub fn lockExclusive(self: *@This(), io: std.Io) !void {
    try self.lock.lock(io);
    self.touchModify(io);
}

pub fn unlockExclusive(self: *@This(), io: std.Io) void {
    self.lock.unlock(io);
    self.touchModify(io);
}

pub fn lockShared(self: *@This(), io: std.Io) !void {
    try self.lock.lockShared(io);
    self.touch(io);
}

pub fn unlockShared(self: *@This(), io: std.Io) void {
    self.lock.unlockShared(io);
    self.touch(io);
}

pub fn addAndLockShared(self: *@This(), io: std.Io) !void {
    _ = self.ref_count.fetchAdd(1, .seq_cst);
    errdefer _ = self.ref_count.fetchSub(1, .seq_cst);
    try self.lockShared(io);
}

pub fn addAndLock(self: *@This(), io: std.Io) !void {
    _ = self.ref_count.fetchAdd(1, .seq_cst);
    errdefer _ = self.ref_count.fetchSub(1, .seq_cst);
    try self.lockExclusive(io);
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
    try testing.expect(isOneBlock(&one_block_chunk) == null);

    var all_stone_chunk: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.stone)));
    try testing.expect(isOneBlock(&all_stone_chunk) != null);
    try testing.expect(isOneBlock(&all_stone_chunk).? == .stone);
}

test "toBlocks" {
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var chunk_pool = try std.heap.MemoryPool(@This()).initCapacity(allocator, 1);
    defer chunk_pool.deinit(allocator);
    var chunk_count: u64 = 0;
    var chunk_mutex: std.Io.Mutex = .init;

    var block_pool = try std.heap.MemoryPool([ChunkSize][ChunkSize][ChunkSize]Block).initCapacity(allocator, 1);
    defer block_pool.deinit(allocator);
    var block_count: u64 = 0;
    var block_mutex: std.Io.Mutex = .init;

    var chunk = try from(.{ .one_block = .stone }, io, &chunk_pool, &chunk_count, &chunk_mutex);

    const converted = try chunk.toBlocks(io, &block_pool, &block_count, &block_mutex, true);
    try testing.expect(converted);

    switch (chunk.blocks) {
        .one_block => unreachable,
        .blocks => |blocks| {
            try testing.expect(blocks[0][0][0] == .stone);
            try testing.expect(blocks[10][20][30] == .stone);
        },
    }

    chunk.free(io, &block_pool, &block_count, &block_mutex);
}

test "merge_test" { // avoid collision with BlockEncoding.merge or the file merge
    const testing = std.testing;
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var chunk_pool = try std.heap.MemoryPool(@This()).initCapacity(allocator, 1);
    defer chunk_pool.deinit(allocator);
    var chunk_count: u64 = 0;
    var chunk_mutex: std.Io.Mutex = .init;

    var block_pool = try std.heap.MemoryPool([ChunkSize][ChunkSize][ChunkSize]Block).initCapacity(allocator, 1);
    defer block_pool.deinit(allocator);
    var block_count: u64 = 0;
    var block_mutex: std.Io.Mutex = .init;

    const blocks1 = try block_pool.create(allocator);
    @memset(@as(*[ChunkSize * ChunkSize * ChunkSize]Block, @ptrCast(blocks1)), .air);
    blocks1[0][0][0] = .dirt;
    block_count += 1;

    var blocks2: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.null)));
    blocks2[0][0][1] = .grass;

    const chunk1_encoding = BlockEncoding.fromBlocks(blocks1);
    var chunk1 = try from(chunk1_encoding, io, &chunk_pool, &chunk_count, &chunk_mutex);

    const chunk2_encoding = BlockEncoding.fromBlocks(&blocks2);

    try chunk1.merge(io, chunk2_encoding, &block_pool, &block_count, &block_mutex);

    switch (chunk1.blocks) {
        .one_block => return error.TestFailed,
        .blocks => |blocks| {
            try testing.expect(blocks[0][0][0] == .dirt);
            try testing.expect(blocks[0][0][1] == .grass);
            try testing.expect(blocks[1][1][1] == .air);
        },
    }

    chunk1.free(io, &block_pool, &block_count, &block_mutex);
}

fn testToBlocksAllocation(allocator: std.mem.Allocator, io: std.Io) !void {
    var chunk_pool = try std.heap.MemoryPool(@This()).initCapacity(allocator, 1);
    defer chunk_pool.deinit(allocator);
    var chunk_count: u64 = 0;
    var chunk_mutex: std.Io.Mutex = .init;

    var block_pool = try std.heap.MemoryPool([ChunkSize][ChunkSize][ChunkSize]Block).initCapacity(allocator, 1);
    defer block_pool.deinit(allocator);
    var block_count: u64 = 0;
    var block_mutex: std.Io.Mutex = .init;

    var chunk = try from(.{ .one_block = .stone }, io, &chunk_pool, &chunk_count, &chunk_mutex);

    _ = try chunk.toBlocks(io, &block_pool, &block_count, &block_mutex, true);

    chunk.free(io, &block_pool, &block_count, &block_mutex);
}

test "toBlocks allocation failure" {
    const io = std.testing.io;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testToBlocksAllocation, .{io});
}

test {
    std.testing.refAllDecls(@This());
}
