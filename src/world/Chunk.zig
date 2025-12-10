const std = @import("std");

pub const Block = @import("Block.zig").Block;

pub const Chunk = struct {
    pub const ChunkSize = 32;
    blocks: BlockEncoding,
    lock: std.Thread.RwLock,
    genstate: std.atomic.Value(Genstate),
    ref_count: std.atomic.Value(u32), //must count being in a hashmap as a refrence
    pub const BlockEncoding = union(enum(u4)) {
        blocks: *[ChunkSize][ChunkSize][ChunkSize]Block,
        oneBlock: Block,
    };

    pub const Genstate = enum(u8) {
        TerrainGenerated,
        StructuresGenerated,
    };

    ///Returns a chunk made from a given block array. The blocks and returned chunk are allocated by the allocator.
    pub fn FromBlocks(blocks: *const [ChunkSize][ChunkSize][ChunkSize]Block, allocator: std.mem.Allocator) !*@This() {
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

    ///Returns a chunk thats all one block. The returned chunk is allocated by the allocator.
    pub fn FromOneBlock(block: Block, allocator: std.mem.Allocator) !*@This() {
        const chunk = try allocator.create(@This());
        chunk.* = .{
            .blocks = .{ .oneBlock = block },
            .lock = .{},
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
                _ = try self.ToBlocks(allocator, false);
                const flatArray: *[ChunkSize * ChunkSize * ChunkSize]@typeInfo(Block).@"enum".tag_type = @ptrCast(self.blocks.blocks);
                const flatMergeArray: *const [ChunkSize * ChunkSize * ChunkSize]@typeInfo(Block).@"enum".tag_type = @ptrCast(mergeBlocks.blocks);
                fastMerge(@typeInfo(Block).@"enum".tag_type, @intFromEnum(Block.Null), flatArray, flatMergeArray);
                if (IsOneBlock(self.blocks.blocks)) |block| {
                    allocator.free(self.blocks.blocks);
                    self.blocks = .{ .oneBlock = block };
                }
            },
        }
    }

    fn fastMerge(comptime T: type, comptime skipValue: T, array: []T, merge: []const T) void {
        const bits = @bitSizeOf(T);

        if (bits >= 8) {
            for (array, merge) |*item, mergeItem| {
                if (mergeItem != skipValue) item.* = mergeItem;
            }
            return;
        }

        const ByteVec = @Vector(32, u8);
        const array_bytes = std.mem.sliceAsBytes(array);
        const merge_bytes = std.mem.sliceAsBytes(merge);

        const skip_byte: u8 = skipValue;
        const skip_vec: ByteVec = @splat(skip_byte);

        const vec_len = array_bytes.len / 32;
        var i: usize = 0;

        while (i < vec_len) : (i += 1) {
            const arr_vec: ByteVec = array_bytes[i * 32 ..][0..32].*;
            const merge_vec: ByteVec = merge_bytes[i * 32 ..][0..32].*;

            const is_not_skip = merge_vec != skip_vec;

            const result = @select(u8, is_not_skip, merge_vec, arr_vec);
            array_bytes[i * 32 ..][0..32].* = result;
        }

        const remainder_start = vec_len * 32;
        for (array_bytes[remainder_start..], merge_bytes[remainder_start..]) |*a, m| {
            if (m != skip_byte) a.* = m;
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
    pub fn ToBlocks(self: *Chunk, allocator: std.mem.Allocator, comptime lock: bool) !bool {
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
