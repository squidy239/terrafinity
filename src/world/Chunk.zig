const std = @import("std");
const builtin = @import("builtin");

const tracy = @import("tracy");

const Block = @import("Block.zig").Block;

pub const ChunkSize = 32;
blocks: Encoding,
lock: std.Io.RwLock = .init,
structures_generated: std.atomic.Value(bool),
ref_count: std.atomic.Value(u32),

last_access: std.atomic.Value(i128),

///if this false negitive it means the chunk has not been modified after its load, otherwise it has
modified: std.atomic.Value(bool) = .init(false),

pub const Encoding = union(enum) {
    grid: *[ChunkSize][ChunkSize][ChunkSize]Block,
    one_block: Block,

    pub fn merge(self: *Encoding, io: std.Io, mergeBlocks: Encoding, memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Io.Mutex) !void {
        const m = tracy.Zone.begin(.{ .src = @src() });
        defer m.end();
        if (mergeBlocks == .one_block and (mergeBlocks.one_block == .null)) return;
        switch (mergeBlocks) {
            .one_block => {
                switch (self.*) {
                    .one_block => {
                        if (mergeBlocks.one_block != .null) {
                            self.* = mergeBlocks;
                        }
                    },
                    .grid => {
                        if (mergeBlocks.one_block != .null) {
                            //safe because caller holds the lock
                            try pool_mutex.lock(io);
                            memory_pool.destroy(@alignCast(self.grid));
                            pool_count.* -= 1;
                            pool_mutex.unlock(io);

                            self.* = .{ .one_block = mergeBlocks.one_block };
                        }
                    },
                }
            },
            .grid => {
                try self.toBlocks(io, memory_pool, pool_count, pool_mutex);
                const tag = @typeInfo(Block).@"enum".tag_type;
                const flatArray: *[ChunkSize * ChunkSize * ChunkSize]tag = @ptrCast(self.grid);
                const flatMergeArray: *[ChunkSize * ChunkSize * ChunkSize]tag = @ptrCast(mergeBlocks.grid);

                selectBlocks(tag, ChunkSize * ChunkSize * ChunkSize, flatArray, flatMergeArray);
                if (isOneBlock(self.grid)) |block| {
                    @branchHint(.unlikely);
                    const f = tracy.Zone.begin(.{ .src = @src(), .name = "free" });
                    defer f.end();

                    try pool_mutex.lock(io);
                    memory_pool.destroy(@alignCast(self.grid));
                    pool_count.* -= 1;
                    pool_mutex.unlock(io);

                    self.* = .{ .one_block = block };
                }
            },
        }
    }

    pub fn toBlocks(self: *Encoding, io: std.Io, memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Io.Mutex) !void {
        if (self.* == .grid) return;
        const t = tracy.Zone.begin(.{ .src = @src() });
        defer t.end();
        var mem: *[ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        {
            const a = tracy.Zone.begin(.{ .src = @src() });
            defer a.end();
            while (true) {
                try pool_mutex.lock(io);
                mem = memory_pool.create(undefined) catch {
                    pool_mutex.unlock(io);
                    try io.sleep(.fromMicroseconds(100), .awake);
                    std.log.debug("Failed to allocate memory for chunk blocks, retrying...", .{});
                    continue;
                };
                pool_count.* += 1;
                pool_mutex.unlock(io);
                break;
            }
        }
        const flatblocks: *[ChunkSize * ChunkSize * ChunkSize]Block = @ptrCast(mem);
        @memset(flatblocks, self.one_block);
        self.* = .{ .grid = mem };
    }

    pub fn fromBlocks(blocks: *[ChunkSize][ChunkSize][ChunkSize]Block) Encoding {
        return if (isOneBlock(blocks)) |one_block| .{ .one_block = one_block } else .{ .grid = blocks };
    }

    pub const FaceRotation = enum(u4) { xplus, xminus, yplus, yminus, zplus, zminus };

    pub fn extractFace(self: Encoding, comptime rotation: FaceRotation) Face {
        switch (self) {
            .grid => |grid| {
                var result: [ChunkSize][ChunkSize]Block = undefined;
                switch (comptime rotation) {
                    .xplus => result = grid[ChunkSize - 1],
                    .xminus => result = grid[0],
                    .yplus => for (&result, 0..) |*row, i| {
                        row.* = grid[i][ChunkSize - 1];
                    },
                    .yminus => for (&result, 0..) |*row, i| {
                        row.* = grid[i][0];
                    },
                    .zplus => {
                        for (&result, 0..) |*row, i| {
                            for (row, 0..) |*item, j| {
                                item.* = grid[i][j][ChunkSize - 1];
                            }
                        }
                    },
                    .zminus => {
                        for (&result, 0..) |*row, i| {
                            for (row, 0..) |*item, j| {
                                item.* = grid[i][j][0];
                            }
                        }
                    },
                }
                return .{ .blocks = result };
            },
            .one_block => |block| return .{ .one_block = block },
        }
    }

    pub const Face = union(enum) {
        blocks: [ChunkSize][ChunkSize]Block,
        one_block: Block,
    };

    test "merge" {
        try std.testing.fuzz(std.testing.io, testOne, .{});
    }

    fn testOne(io: std.Io, smith: *std.testing.Smith) !void {
        var pool: std.heap.MemoryPool([ChunkSize][ChunkSize][ChunkSize]Block) = try .initCapacity(std.testing.allocator, 1);
        defer pool.deinit(std.testing.allocator);
        var g1: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        var g2: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        var b1: Encoding = .fuzzerMakeEncoding(&g1, smith);
        const b2: Encoding = .fuzzerMakeEncoding(&g2, smith);
        var pc: u64 = 2;
        var pm: std.Io.Mutex = .init;
        try b1.merge(io, b2, &pool, &pc, &pm);
    }

    pub fn fuzzerMakeEncoding(grid: *[ChunkSize][ChunkSize][ChunkSize]Block, smith: *std.testing.Smith) Encoding {
        @disableInstrumentation();
        @setRuntimeSafety(false);
        return switch (smith.value(@typeInfo(Encoding).@"union".tag_type.?)) {
            .grid => blk: {
                grid.* = smith.value([ChunkSize][ChunkSize][ChunkSize]Block);
                break :blk Encoding{ .grid = grid };
            },
            .one_block => .{ .one_block = smith.value(Block) },
        };
    }
};

/// Returns a chunk made from a given blockencoding. The chunk is allocated from the pool.
pub fn from(blockEncoding: Encoding, io: std.Io, chunk: *@This()) !*@This() {
    chunk.* = .{
        .blocks = blockEncoding,
        .last_access = .init(std.Io.Timestamp.now(io, .awake).nanoseconds),
        .structures_generated = .init(false),
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
pub fn merge(self: *@This(), io: std.Io, mergeBlocks: Encoding, memory_pool: anytype, pool_count: *u64, pool_mutex: *std.Io.Mutex) !void {
    try self.addAndLock(io);
    defer self.releaseAndUnlock(io);
    try self.blocks.merge(io, mergeBlocks, memory_pool, pool_count, pool_mutex);
}

pub fn extractFace(self: *@This(), io: std.Io, comptime rotation: Encoding.FaceRotation, comptime removeRef: bool) !Encoding.Face {
    defer if (removeRef) self.release(io);
    try self.addAndLockShared(io);
    defer self.releaseAndUnlockShared(io);
    return self.blocks.extractFace(rotation);
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
        .grid => {
            pool_mutex.lockUncancelable(io);
            memory_pool.destroy(@alignCast(self.blocks.grid));
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
    self.touch(io);
    _ = self.ref_count.fetchSub(1, .seq_cst);
}

pub fn lockExclusive(self: *@This(), io: std.Io) !void {
    try self.lock.lock(io);
    self.touchModify(io);
}

pub fn unlockExclusive(self: *@This(), io: std.Io) void {
    self.touchModify(io);
    self.lock.unlock(io);
}

pub fn lockShared(self: *@This(), io: std.Io) !void {
    try self.lock.lockShared(io);
    self.touch(io);
}

pub fn unlockShared(self: *@This(), io: std.Io) void {
    self.touch(io);
    self.lock.unlockShared(io);
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

    var chunk_data: @This() = undefined;

    var block_pool = try std.heap.MemoryPool([ChunkSize][ChunkSize][ChunkSize]Block).initCapacity(allocator, 1);
    defer block_pool.deinit(allocator);
    var block_count: u64 = 0;
    var block_mutex: std.Io.Mutex = .init;

    var chunk = try from(.{ .one_block = .stone }, io, &chunk_data);

    const converted = try chunk.toBlocks(io, &block_pool, &block_count, &block_mutex, true);
    try testing.expect(converted);

    switch (chunk.blocks) {
        .one_block => unreachable,
        .grid => |blocks| {
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

    var chunk_data: @This() = undefined;

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

    const chunk1_encoding = Encoding.fromBlocks(blocks1);
    var chunk1 = try from(chunk1_encoding, io, &chunk_data);

    const chunk2_encoding = Encoding.fromBlocks(&blocks2);

    try chunk1.merge(io, chunk2_encoding, &block_pool, &block_count, &block_mutex);

    switch (chunk1.blocks) {
        .one_block => return error.TestFailed,
        .grid => |blocks| {
            try testing.expect(blocks[0][0][0] == .dirt);
            try testing.expect(blocks[0][0][1] == .grass);
            try testing.expect(blocks[1][1][1] == .air);
        },
    }

    chunk1.free(io, &block_pool, &block_count, &block_mutex);
}

fn testToBlocksAllocation(allocator: std.mem.Allocator, io: std.Io) !void {
    var chunk_data: @This() = undefined;

    var block_pool = try std.heap.MemoryPool([ChunkSize][ChunkSize][ChunkSize]Block).initCapacity(allocator, 1);
    defer block_pool.deinit(allocator);
    var block_count: u64 = 0;
    var block_mutex: std.Io.Mutex = .init;

    var chunk = try from(.{ .one_block = .stone }, io, &chunk_data);

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
