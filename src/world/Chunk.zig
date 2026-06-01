const std = @import("std");

const tracy = @import("tracy");

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
    pub const GridAlignment = 64;
    grid: *align(GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block,
    uniform: Block,

    pub fn fromBlocks(blocks: *align(GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) Encoding {
        return if (getUniform(blocks)) |one_block| .{ .uniform = one_block } else .{ .grid = blocks };
    }

    pub fn merge(blocks: *Encoding, mergeBlocks: Encoding, grid_buffer: *align(GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) void {
        const m = tracy.Zone.begin(.{ .src = @src() });
        defer m.end();
        switch (mergeBlocks) {
            .uniform => |uniform| mergeUniform(blocks, uniform),
            .grid => |grid| mergeGrid(blocks, grid, grid_buffer),
        }
    }

    pub fn mergeUniform(blocks: *Encoding, uniform: Block) void {
        if (uniform == .null) return;
        blocks.* = .{ .uniform = uniform };
    }

    pub fn mergeGrid(blocks: *Encoding, merge_grid: *const [ChunkSize][ChunkSize][ChunkSize]Block, grid_buffer: *align(GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) void {
        toGrid(blocks, grid_buffer);
        const tag = @typeInfo(Block).@"enum".tag_type;
        const flatArray: *[ChunkSize * ChunkSize * ChunkSize]tag = @ptrCast(blocks.grid);
        const flatMergeArray: *const [ChunkSize * ChunkSize * ChunkSize]tag = @ptrCast(merge_grid);

        selectBlocks(tag, ChunkSize * ChunkSize * ChunkSize, flatArray, flatMergeArray);
        if (getUniform(blocks.grid)) |block| blocks.* = .{ .uniform = block };
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

    pub fn toGrid(blocks: *Encoding, grid_buffer: *align(GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) void {
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
                var result: [ChunkSize][ChunkSize]Block align(GridAlignment) = undefined;
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
        grid: [ChunkSize][ChunkSize]Block align(GridAlignment),
        uniform: Block,
    };

    pub fn getFaceUniform(self: *align(GridAlignment) const [ChunkSize][ChunkSize]Block) ?Block {
        const flat_blocks: *const [ChunkSize * ChunkSize]@typeInfo(Block).@"enum".tag_type = @ptrCast(self);
        const block_vector: @Vector(ChunkSize * ChunkSize, @typeInfo(Block).@"enum".tag_type) = flat_blocks.*;
        const count = std.simd.countElementsWithValue(block_vector, block_vector[0]);
        return if (count == ChunkSize * ChunkSize) self[0][0] else null;
    }

    pub fn fuzzerMakeEncoding(grid: *align(GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block, smith: *std.testing.Smith) Encoding {
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

    const scale_factor = 2;
    const simplified_size = ChunkSize / scale_factor;

    const area_factor = scale_factor * scale_factor;
    const volume_factor = scale_factor * scale_factor * scale_factor;

    inline fn getExposureMask(x: usize, y: usize, grid: *const [ChunkSize][ChunkSize][ChunkSize]Block.Tag, center: @Vector(ChunkSize, Block.Tag)) @Vector(ChunkSize, bool) {
        const center_trans = Block.isTransparentVector(ChunkSize, center);
        var exposure_mask: @Vector(ChunkSize, bool) = @splat(false);

        // Z-Axis
        exposure_mask |= std.simd.shiftElementsRight(center_trans, 1, true);
        exposure_mask |= std.simd.shiftElementsLeft(center_trans, 1, true);

        // X-Axis
        exposure_mask |= if (x == 0) center_trans else Block.isTransparentVector(ChunkSize, @bitCast(grid[x - 1][y]));
        exposure_mask |= if (x == ChunkSize - 1) center_trans else Block.isTransparentVector(ChunkSize, @bitCast(grid[x + 1][y]));

        // Y-Axis
        exposure_mask |= if (y == 0) center_trans else Block.isTransparentVector(ChunkSize, @bitCast(grid[x][y - 1]));
        exposure_mask |= if (y == ChunkSize - 1) center_trans else Block.isTransparentVector(ChunkSize, @bitCast(grid[x][y + 1]));

        return exposure_mask;
    }


    pub inline fn findBestBlock(
        comptime len: usize,
        rows: [area_factor]@Vector(len, Block.Tag),
        exposures: [area_factor]@Vector(len, bool),
    ) @Vector(len / scale_factor, Block.Tag) {
        var v: [volume_factor]@Vector(len, Block.Tag) = undefined;
        var exp: [volume_factor]@Vector(len, bool) = undefined;

        inline for (0..area_factor) |i| {
            inline for (0..scale_factor) |dz| {
                v[i * scale_factor + dz] = rows[i];
                exp[i * scale_factor + dz] = exposures[i];
            }
        }

        var total_counts: [volume_factor]@Vector(len, u8) = undefined;
        var exp_counts: [volume_factor]@Vector(len, u8) = undefined;

        inline for (0..volume_factor) |i| {
            total_counts[i] = @splat(0);
            exp_counts[i] = @splat(0);

            inline for (0..volume_factor) |j| {
                const match = v[i] == v[j];
                total_counts[i] += @intFromBool(match);
                exp_counts[i] += @intFromBool(match & exp[j]);
            }
        }

        var best_v = v[0];
        var best_tot = total_counts[0];
        var best_exp = exp_counts[0];

        inline for (1..volume_factor) |i| {
            const exp_differs = best_exp != exp_counts[i];
            const exp_wins = best_exp >= exp_counts[i];
            const total_wins = best_tot >= total_counts[i];
            const a_wins = @select(bool, exp_differs, exp_wins, total_wins);

            best_v = @select(Block.Tag, a_wins, best_v, v[i]);
            best_tot = @select(u8, a_wins, best_tot, total_counts[i]);
            best_exp = @select(u8, a_wins, best_exp, exp_counts[i]);
        }

        const stride_mask = comptime blk: {
            const downsampled_len = len / scale_factor;
            var m: @Vector(downsampled_len, i32) = undefined;
            for (0..downsampled_len) |i| m[i] = @intCast(i * scale_factor);
            break :blk m;
        };

        return @shuffle(Block.Tag, best_v, undefined, stride_mask);
    }

    pub fn simplifyBlocks(grid: *align(GridAlignment) const [ChunkSize][ChunkSize][ChunkSize]Block) [simplified_size][simplified_size][simplified_size]Block {
        var simplified_grid: [simplified_size][simplified_size][simplified_size]Block.Tag align(GridAlignment) = undefined;
        for (0..simplified_size) |nx| {
            const x = nx * scale_factor;

            for (0..simplified_size) |ny| {
                const y = ny * scale_factor;

                var rows: [area_factor]@Vector(ChunkSize, Block.Tag) = undefined;
                var exposures: [area_factor]@Vector(ChunkSize, bool) = undefined;

                // Dynamically build the 2D area arrays based on scale_factor
                inline for (0..scale_factor) |dx| {
                    inline for (0..scale_factor) |dy| {
                        const idx = dx * scale_factor + dy;
                        rows[idx] = grid[x + dx][y + dy];
                        exposures[idx] = getExposureMask(x + dx, y + dy, grid, rows[idx]);
                    }
                }

                simplified_grid[nx][ny] = findBestBlock(ChunkSize, rows, exposures);
            }
        }
        return simplified_grid;
    }

    test "SimplifyBlocksAvgBenchmark" {
        var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(GridAlignment) = @splat(@splat(@splat(.air)));
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
            const res = simplifyBlocks(&grid);
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
