const std = @import("std");

const Block = @import("Block.zig").Block;

pub const ChunkSize = 32;
encoding: Encoding,
encoding_lock: std.Io.RwLock = .init,
ref_count: std.atomic.Value(u32) = .init(1),

structures_generated: std.atomic.Value(bool) = .init(false),

///if this false negitive it means the chunk has not been modified after its load, otherwise it has
modified: std.atomic.Value(bool) = .init(false),
///if this is false, the chunk has not been saved ever, if it is true a version of this chunk has been saved.
///This may not be the current version and modified should be used to check this
saved: std.atomic.Value(bool) = .init(false),

pub const Encoding = union(enum(u1)) {
    grid: *[ChunkSize][ChunkSize][ChunkSize]Block,
    one_block: Block,

    pub fn fromBlocks(blocks: *[ChunkSize][ChunkSize][ChunkSize]Block) Encoding {
        return if (isOneBlock(blocks)) |one_block| .{ .one_block = one_block } else .{ .grid = blocks };
    }

    pub const FaceRotation = enum(u4) {
        xplus,
        xminus,
        yplus,
        yminus,
        zplus,
        zminus,

        pub fn direction(self: FaceRotation) @Vector(3, i32) {
            return switch (self) {
                .xplus => @Vector(3, i32){ 1, 0, 0 },
                .xminus => @Vector(3, i32){ -1, 0, 0 },
                .yplus => @Vector(3, i32){ 0, 1, 0 },
                .yminus => @Vector(3, i32){ 0, -1, 0 },
                .zplus => @Vector(3, i32){ 0, 0, 1 },
                .zminus => @Vector(3, i32){ 0, 0, -1 },
            };
        }
    };

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
pub fn from(blockEncoding: Encoding, chunk: *@This()) !*@This() {
    chunk.* = .{
        .encoding = blockEncoding,
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

pub fn extractFace(self: *@This(), io: std.Io, comptime rotation: Encoding.FaceRotation, comptime removeRef: bool) !Encoding.Face {
    defer if (removeRef) self.release();
    try self.addAndLockShared(io);
    defer self.releaseAndUnlockShared(io);
    return self.encoding.extractFace(rotation);
}

pub fn waitForRefAmount(self: *const @This(), io: std.Io, amount: u32, maxMicroTime: ?u64) error{Canceled}!bool {
    std.debug.assert(self.encoding == .grid or self.encoding == .one_block);
    if (self.ref_count.load(.seq_cst) == amount) return true;
    const st = std.Io.Timestamp.now(io, .awake);
    while (self.ref_count.load(.seq_cst) != amount) {
        @branchHint(.unlikely);
        if (maxMicroTime != null and st.untilNow(io, .awake).toMicroseconds() > maxMicroTime.?) return false;
        try std.Io.sleep(io, .fromMicroseconds(1), .awake);
    }
    return true;
}

pub fn modify(self: *@This()) void {
    self.modified.store(true, .seq_cst);
}

pub fn addRef(self: *@This()) void {
    _ = self.ref_count.fetchAdd(1, .seq_cst);
}

pub fn release(self: *@This()) void {
    _ = self.ref_count.fetchSub(1, .seq_cst);
}

pub fn lockExclusive(self: *@This(), io: std.Io) !void {
    try self.encoding_lock.lock(io);
    self.modify();
}

pub fn unlockExclusive(self: *@This(), io: std.Io) void {
    self.modify();
    self.encoding_lock.unlock(io);
}

pub fn lockShared(self: *@This(), io: std.Io) !void {
    try self.encoding_lock.lockShared(io);
}

pub fn unlockShared(self: *@This(), io: std.Io) void {
    self.encoding_lock.unlockShared(io);
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

test {
    std.testing.refAllDecls(@This());
}
