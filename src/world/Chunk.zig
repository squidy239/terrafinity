const std = @import("std");

const Block = @import("Block.zig").Block;

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
    ///Returns a block encoding made from a given block array owned by the allocator.
    pub fn fromBlocks(blocks: *const [ChunkSize][ChunkSize][ChunkSize]Block, allocator: std.mem.Allocator) !BlockEncoding {
        const oneBlock = IsOneBlock(blocks);
        var blockEncoding: BlockEncoding = undefined;
        if (oneBlock) |block| {
            blockEncoding = BlockEncoding{ .oneBlock = block };
        } else {
            const mem = try allocator.create([ChunkSize][ChunkSize][ChunkSize]Block);
            mem.* = blocks.*;
            blockEncoding = BlockEncoding{ .blocks = mem };
        }
        return blockEncoding;
    }
};

pub const Genstate = enum(u8) {
    TerrainGenerated,
    StructuresGenerated,
};

///Returns a chunk made from a given blockencoding. The blocks and returned chunk are allocated by the allocator.
pub fn from(blockEncoding: BlockEncoding, allocator: std.mem.Allocator) !*@This() {
    const chunk = try allocator.create(@This());
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
pub fn Merge(self: *@This(), mergeBlocks: BlockEncoding, allocator: std.mem.Allocator, comptime lock: bool) !void {
    self.add_ref();
    defer self.release();
    if (lock) self.lockExclusive();
    defer if (lock) self.unlockExclusive();
    if (mergeBlocks == .oneBlock and (mergeBlocks.oneBlock == .null)) return;
    switch (mergeBlocks) {
        .oneBlock => {
            switch (self.blocks) {
                .oneBlock => {
                    if (mergeBlocks.oneBlock != .null)
                        self.blocks = mergeBlocks;
                },
                .blocks => {
                    if (mergeBlocks.oneBlock != .null) {
                        allocator.free(self.blocks.blocks);
                        self.blocks = .{ .oneBlock = mergeBlocks.oneBlock };
                    }
                },
            }
        },
        .blocks => {
            _ = try self.ToBlocks(allocator, false);
            const flatArray: *[ChunkSize * ChunkSize * ChunkSize]Block = @ptrCast(self.blocks.blocks);
            const flatMergeArray: *const [ChunkSize * ChunkSize * ChunkSize]Block = @ptrCast(mergeBlocks.blocks);
            for (flatArray, flatMergeArray) |*item, mergeItem| {
                if (mergeItem != .null) item.* = mergeItem;
            }
            if (IsOneBlock(self.blocks.blocks)) |block| {
                allocator.free(self.blocks.blocks);
                self.blocks = .{ .oneBlock = block };
            }
        },
    }
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
pub fn ToBlocks(self: *@This(), allocator: std.mem.Allocator, comptime lock: bool) !bool {
    self.add_ref();
    defer self.release();
    if (lock) self.lockExclusive();
    defer if (lock) self.unlockExclusive();
    if (self.blocks != .oneBlock) return false;
    var blocks: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
    @memset(&blocks, @splat(@splat(self.blocks.oneBlock)));
    const mem = try allocator.create([ChunkSize][ChunkSize][ChunkSize]Block);
    mem.* = blocks;
    std.debug.assert(self.blocks != .blocks);
    self.blocks = BlockEncoding{ .blocks = mem };
    return true;
}

///frees the chunk's blocks, does not free the chunk itself
///the chunk must only be 1 ref before calling, use WaitForRefAmount
///locks the chunk
pub fn free(self: *@This(), allocator: std.mem.Allocator) void {
    std.debug.assert(self.ref_count.load(.seq_cst) == 1);
    self.lockExclusive();
    switch (self.blocks) {
        .blocks => {
            allocator.destroy(self.blocks.blocks);
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
    self.last_access.store(std.time.microTimestamp(), .monotonic);
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
