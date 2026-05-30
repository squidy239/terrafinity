const std = @import("std");

const Block = @import("Block.zig").Block;
const tracy = @import("tracy");

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
    uniform: Block,

    pub fn fromBlocks(blocks: *[ChunkSize][ChunkSize][ChunkSize]Block) Encoding {
        return if (getUniform(blocks)) |one_block| .{ .uniform = one_block } else .{ .grid = blocks };
    }

    pub fn merge(blocks: *Encoding, mergeBlocks: Encoding, grid_buffer: *[ChunkSize][ChunkSize][ChunkSize]Block) void {
        const m = tracy.Zone.begin(.{ .src = @src() });
        defer m.end();
        switch (mergeBlocks) {
            .uniform => {
                if (mergeBlocks.uniform == .null) return;
                switch (blocks.*) {
                    .uniform => blocks.* = mergeBlocks,
                    .grid => blocks.* = .{ .uniform = mergeBlocks.uniform },
                }
            },
            .grid => {
                toBlocks(blocks, grid_buffer);
                const tag = @typeInfo(Block).@"enum".tag_type;
                const flatArray: *[ChunkSize * ChunkSize * ChunkSize]tag = @ptrCast(blocks.grid);
                const flatMergeArray: *[ChunkSize * ChunkSize * ChunkSize]tag = @ptrCast(mergeBlocks.grid);

                selectBlocks(tag, ChunkSize * ChunkSize * ChunkSize, flatArray, flatMergeArray);
                if (getUniform(blocks.grid)) |block| blocks.* = .{ .uniform = block };
            },
        }
    }

    // Workaround for https://codeberg.org/ziglang/zig/issues/35254
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

    pub fn toBlocks(blocks: *Encoding, grid_buffer: *[ChunkSize][ChunkSize][ChunkSize]Block) void {
        if (blocks.* == .grid) return;
        switch (blocks.*) {
            .uniform => |block| {
                grid_buffer.* = @splat(@splat(@splat(block)));
                blocks.* = .{ .grid = grid_buffer };
            },
            .grid => {},
        }
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
                return if (getFaceUniform(&result)) |block| .{ .uniform = block } else .{ .grid = result };
            },
            .uniform => |block| return .{ .uniform = block },
        }
    }

    pub fn extractAllFaces(self: Encoding) [6]Face {
        var result: [6]Face = undefined;
        inline for (std.enums.values(FaceRotation)) |side| {
            result[@intFromEnum(side)] = self.extractFace(side);
        }
        return result;
    }

    pub const Face = union(enum) {
        grid: [ChunkSize][ChunkSize]Block,
        uniform: Block,
    };

    pub fn getFaceUniform(self: *const [ChunkSize][ChunkSize]Block) ?Block {
        const flat_blocks: *const [ChunkSize * ChunkSize]@typeInfo(Block).@"enum".tag_type = @ptrCast(self);
        const block_vector: @Vector(ChunkSize * ChunkSize, @typeInfo(Block).@"enum".tag_type) = flat_blocks.*;
        const count = std.simd.countElementsWithValue(block_vector, block_vector[0]);
        return if (count == ChunkSize * ChunkSize) self[0][0] else null;
    }

    pub fn fuzzerMakeEncoding(grid: *[ChunkSize][ChunkSize][ChunkSize]Block, smith: *std.testing.Smith) Encoding {
        @disableInstrumentation();
        @setRuntimeSafety(false);
        return switch (smith.value(@typeInfo(Encoding).@"union".tag_type.?)) {
            .grid => blk: {
                grid.* = smith.value([ChunkSize][ChunkSize][ChunkSize]Block);
                break :blk Encoding{ .grid = grid };
            },
            .uniform => .{ .uniform = smith.value(Block) },
        };
    }
    const simplified_size = ChunkSize / 2;
    const scale_factor = 2;
    pub fn simplifyBlocksAvg(blocks: *const [ChunkSize][ChunkSize][ChunkSize]Block) [simplified_size][simplified_size][simplified_size]Block {
        var simplified: [simplified_size][simplified_size][simplified_size]Block = undefined;
        var unique_blocks: [scale_factor][scale_factor][scale_factor]Block.Tag = undefined;
        for (0..simplified_size) |sx| {
            for (0..simplified_size) |sy| {
                for (0..simplified_size) |sz| {
                    inline for (0..scale_factor) |dx| {
                        inline for (0..scale_factor) |dy| {
                            inline for (0..scale_factor) |dz| {
                                unique_blocks[dx][dy][dz] = @intFromEnum(blocks[sx * scale_factor + dx][sy * scale_factor + dy][sz * scale_factor + dz]);
                            }
                        }
                    }
                    const unique_vector: @Vector(scale_factor * scale_factor * scale_factor, Block.Tag) = @bitCast(unique_blocks);
                    if (std.simd.countElementsWithValue(unique_vector, unique_blocks[0][0][0]) == scale_factor * scale_factor * scale_factor){
                        simplified[sx][sy][sz] = @enumFromInt(unique_blocks[0][0][0]);
                    } else {
                        simplified[sx][sy][sz] = getBestBlock(unique_vector);
                    }
                }
            }
        }
        return simplified;
    }

    fn getBestBlock(blocks: @Vector(scale_factor * scale_factor * scale_factor, @typeInfo(Block).@"enum".tag_type)) Block {
        var best: Block = undefined;
        var best_count: f32 = -1.0;
        inline for (0..scale_factor * scale_factor * scale_factor) |i| {
            const block_int = blocks[i];
            const block: Block = @enumFromInt(block_int);
            const weight = block.getPropagationWeight();
            const count = std.simd.countElementsWithValue(blocks, block_int);
            if (count * weight > best_count) {
                best = @enumFromInt(block_int);
                best_count = count * weight;
            }
        }
        return best;
    }

    test "SimplifyBlocksAvgBenchmark" {
        var grid: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |y| {
                for (0..ChunkSize) |z| {
                    grid[x][y][z] = switch (y) {
                        0...16 => .stone,
                        17 => .grass,
                        else => .air,
                    };
                }
            }
        }
        const test_amount = if (@import("builtin").mode == .Debug) 100 else 100000;
        const st = std.Io.Timestamp.now(std.testing.io, .awake);

        for (0..test_amount) |_| {
            const res = simplifyBlocksAvg(&grid);
            std.mem.doNotOptimizeAway(res);
        }

        const et = std.Io.Timestamp.now(std.testing.io, .awake);
        const dt = st.durationTo(et);
        const us_per_mesh = (@as(f64, @floatFromInt(dt.toMicroseconds())) / test_amount);
        std.log.warn("Simplify benchmark: completed with an avg time of {d} us per chunk, {d} ns per block", .{ us_per_mesh, (us_per_mesh * std.time.ns_per_us) / (ChunkSize * ChunkSize * ChunkSize) });
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
pub fn getUniform(blockArray: *const [ChunkSize][ChunkSize][ChunkSize]Block) ?Block {
    const firstBlockVec: @Vector(ChunkSize, @typeInfo(Block).@"enum".tag_type) = @splat(@intFromEnum(blockArray[0][0][0]));
    var uniform: @Vector(ChunkSize, bool) = comptime @splat(true);
    const linearBlockArray: *const [ChunkSize * ChunkSize][ChunkSize]@typeInfo(Block).@"enum".tag_type = @ptrCast(blockArray);
    for (linearBlockArray) |blocks| uniform &= (blocks == firstBlockVec);
    return if (@reduce(.And, uniform)) blockArray[0][0][0] else null;
}

pub fn extractFace(self: *@This(), io: std.Io, comptime rotation: Encoding.FaceRotation, comptime removeRef: bool) !Encoding.Face {
    defer if (removeRef) self.release();
    try self.addAndLockShared(io);
    defer self.releaseAndUnlockShared(io);
    return self.encoding.extractFace(rotation);
}

pub fn waitForRefAmount(self: *const @This(), io: std.Io, amount: u32, maxMicroTime: ?u64) error{Canceled}!bool {
    std.debug.assert(self.encoding == .grid or self.encoding == .uniform);
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

test "getUniform" {
    const testing = std.testing;

    var all_stone: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.stone)));
    try testing.expectEqual(Block.stone, getUniform(&all_stone));

    var all_air: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));
    try testing.expectEqual(Block.air, getUniform(&all_air));

    var diff_first: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));
    diff_first[0][0][0] = .stone;
    try testing.expectEqual(@as(?Block, null), getUniform(&diff_first));

    var diff_last: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));
    diff_last[ChunkSize - 1][ChunkSize - 1][ChunkSize - 1] = .stone;
    try testing.expectEqual(@as(?Block, null), getUniform(&diff_last));

    var diff_middle: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.stone)));
    diff_middle[ChunkSize / 2][ChunkSize / 2][ChunkSize / 2] = .air;
    try testing.expectEqual(@as(?Block, null), getUniform(&diff_middle));

    var diff_row_end: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.stone)));
    diff_row_end[0][0][ChunkSize - 1] = .air;
    try testing.expectEqual(@as(?Block, null), getUniform(&diff_row_end));
}

test {
    std.testing.refAllDecls(@This());
}
