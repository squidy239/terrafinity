const std = @import("std");

const Block = @import("Block").Blocks;
const ztracy = @import("ztracy");

pub const Chunk = struct {
    pub const ChunkSize = 32;
    blocks: BlockEncoding,
    lock: std.Thread.RwLock,
    genstate: std.atomic.Value(Genstate),
    ref_count: std.atomic.Value(u32), //must count being in a hashmap as a refrence
    pub const BlockEncoding = union(enum) {
        blocks: *[ChunkSize][ChunkSize][ChunkSize]Block,
        oneBlock: Block,
    };

    pub const Genstate = enum(u8) {
        TerrainGenerated,
        StructuresGenerated,
    };

    ///Returns a chunk made from a given block array. The blocks and returned chunk are allocated by the allocator.
    pub fn FromBlocks(blocks: *const [ChunkSize][ChunkSize][ChunkSize]Block, allocator: std.mem.Allocator) !*@This() {
        const fb = ztracy.ZoneNC(@src(), "chunkFromBlocks", 76465434);
        defer fb.End();
        const oneBlock = IsOneBlock(blocks);
        var blockEncoding: BlockEncoding = undefined;
        if (oneBlock) |block| {
            blockEncoding = BlockEncoding{ .oneBlock = block };
        } else {
            const mem = try allocator.create([ChunkSize][ChunkSize][ChunkSize]Block);
            mem.* = blocks.*;
            blockEncoding = BlockEncoding{ .blocks = mem };
        }
        const chunk = try allocator.create(@This());
        chunk.* = .{
            .blocks = blockEncoding,
            .lock = .{},
            .genstate = std.atomic.Value(Genstate).init(.TerrainGenerated),
            .ref_count = std.atomic.Value(u32).init(1),
        };
        return chunk;
    }

    ///checks if the block array is all the same block
    pub fn IsOneBlock(blockArray: *const [ChunkSize][ChunkSize][ChunkSize]Block) ?Block {
        const issOneBlock = ztracy.ZoneNC(@src(), "isOneBlock", 354354);
        defer issOneBlock.End();
        const firstBlockVec: @Vector(ChunkSize, @typeInfo(Block).@"enum".tag_type) = @splat(@intFromEnum(blockArray[0][0][0]));
        var isOneBlock: @Vector(ChunkSize, bool) = comptime @splat(true);
        const linearBlockArray: *const [ChunkSize * ChunkSize][ChunkSize]@typeInfo(Block).@"enum".tag_type = @ptrCast(blockArray);
        for (linearBlockArray) |blocks| isOneBlock &= (blocks == firstBlockVec);
        return if (@reduce(.And, isOneBlock)) blockArray[0][0][0] else null;
    }

    ///merges the chunk with the mergeBlocks, copies all non null mergeBlocks to blocks
    pub fn Merge(self: *@This(), mergeBlocks: BlockEncoding, allocator: std.mem.Allocator, comptime lock: bool) !void {
        const merge = ztracy.ZoneNC(@src(), "Merge", 756657567);
        defer merge.End();
        self.add_ref();
        defer self.release();
        if (lock) self.lock.lock();
        defer if (lock) self.lock.unlock();
        if (mergeBlocks == .oneBlock and (mergeBlocks.oneBlock == .Null)) return;
        switch (mergeBlocks) {
            .oneBlock => {
                switch (self.blocks) {
                    .oneBlock => {
                        if (mergeBlocks.oneBlock != .Null)
                            self.blocks = mergeBlocks;
                    },
                    .blocks => {
                        if (mergeBlocks.oneBlock != .Null) {
                            allocator.free(self.blocks.blocks);
                            self.blocks = .{ .oneBlock = mergeBlocks.oneBlock };
                        }
                    },
                }
            },
            .blocks => {
                const bl = ztracy.ZoneNC(@src(), "Blocks", 642342342);
                defer bl.End();
                _ = try self.ToBlocks(allocator, false);
                const flatArray: *[ChunkSize * ChunkSize * ChunkSize]Block = @ptrCast(self.blocks.blocks);
                const flatMergeArray: *const [ChunkSize * ChunkSize * ChunkSize]Block = @ptrCast(mergeBlocks.blocks);
                for (flatArray, flatMergeArray) |*item, mergeItem| {
                    if (mergeItem != .Null) item.* = mergeItem;
                }
                if (IsOneBlock(self.blocks.blocks)) |block| {
                    allocator.free(self.blocks.blocks);
                    self.blocks = .{ .oneBlock = block };
                }
            },
        }
    }

    pub fn extractFace(self: *@This(), comptime face: enum { xPlus, xMinus, yPlus, yMinus, zPlus, zMinus }, comptime removeRef: bool) [ChunkSize][ChunkSize]Block {
        const ef = ztracy.ZoneNC(@src(), "ExtractFace", 9999);
        defer ef.End();
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
    pub fn ToBlocks(self: *Chunk, allocator: std.mem.Allocator, comptime lock: bool) !bool {
        const toblocks = ztracy.ZoneNC(@src(), "toBlocks", 645);
        defer toblocks.End();
        self.add_ref();
        defer self.release();
        if (lock) self.lock.lock();
        defer if (lock) self.lock.unlock();
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
        const freeChunk = ztracy.ZoneNC(@src(), "freeChunk", 11999);
        defer freeChunk.End();
        std.debug.assert(self.ref_count.load(.seq_cst) == 1);
        self.lock.lock();
        switch (self.blocks) {
            .blocks => {
                allocator.destroy(self.blocks.blocks);
            },
            .oneBlock => {},
        }
    }

    pub fn WaitForRefAmount(self: *const @This(), amount: u32, maxMicroTime: ?u64) bool {
        const wait = ztracy.ZoneNC(@src(), "WaitForRefAmount", 5554);
        defer wait.End();
        if (self.ref_count.load(.seq_cst) == amount) return true;
        const st = std.time.microTimestamp();
        while (self.ref_count.load(.seq_cst) != amount) {
            if (maxMicroTime != null and (std.time.microTimestamp() - st) > maxMicroTime.?) return false;
            std.Thread.yield() catch |err| std.debug.print("yield err:{any}\n", .{err});
        }
        return true;
    }
    pub fn add_ref(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    pub fn release(self: *@This()) void {
        _ = self.ref_count.fetchSub(1, .seq_cst);
    }
    pub fn addAndLockShared(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
        self.lock.lockShared();
    }
    pub fn addAndlock(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
        self.lock.lock();
    }

    pub fn releaseAndUnlock(self: *@This()) void {
        self.lock.unlock();
        _ = self.ref_count.fetchSub(1, .seq_cst);
    }

    pub fn releaseAndUnlockShared(self: *@This()) void {
        self.lock.unlockShared();
        _ = self.ref_count.fetchSub(1, .seq_cst);
    }
};
