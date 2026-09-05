const std = @import("std");

const tracy = @import("tracy");

const Block = @import("Block.zig").Block;

pub const ChunkSize = 32;
pub const Int = @Int(.unsigned, std.math.log2_int_ceil(usize, ChunkSize));

encoding: Encoding,
encoding_lock: std.Io.RwLock = .init,
ref_count: std.atomic.Value(u32) = .init(1),

structures_generated: std.atomic.Value(bool) = .init(false),

/// if this is false it means the chunk has not been modified after its load, otherwise it has
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

    pub fn merge(blocks: *Encoding, merge_blocks: Encoding, grid_buffer: *align(GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block) void {
        const m = tracy.Zone.begin(.{ .src = @src() });
        defer m.end();
        switch (merge_blocks) {
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
        const flat_array: *[ChunkSize * ChunkSize * ChunkSize]tag = @ptrCast(blocks.grid);
        const flat_merge_array: *const [ChunkSize * ChunkSize * ChunkSize]tag = @ptrCast(merge_grid);

        selectBlocks(tag, ChunkSize * ChunkSize * ChunkSize, flat_array, flat_merge_array);
        if (getUniform(blocks.grid)) |block| blocks.* = .{ .uniform = block };
    }

    // Workaround for https://codeberg.org/ziglang/zig/issues/35254
    fn selectBlocks(comptime T: type, comptime len: usize, flat_array: *[len]T, flat_merge_array: *const [len]T) void {
        if (comptime std.simd.suggestVectorLength(T)) |vlen| {
            const VT = @Vector(vlen, T);
            var i: usize = 0;
            while (i + vlen <= len) : (i += vlen) {
                const a: VT = flat_array.*[i..][0..vlen].*;
                const b: VT = flat_merge_array[i..][0..vlen].*;
                const pred = b == comptime @as(VT, @splat(@intFromEnum(Block.null)));
                const result = @select(T, pred, a, b);
                flat_array.*[i..][0..vlen].* = result;
            }
            while (i < len) : (i += 1) {
                if (flat_merge_array[i] != comptime @intFromEnum(Block.null)) {
                    flat_array.*[i] = flat_merge_array[i];
                }
            }
        } else {
            for (flat_merge_array[0..len], flat_array.*[0..len]) |src, *dest| {
                if (src != comptime @intFromEnum(Block.null)) {
                    dest.* = src;
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

    pub const FaceRotation = enum(u3) {
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

        pub fn invert(self: FaceRotation) FaceRotation {
            return switch (self) {
                .xplus => .xminus,
                .xminus => .xplus,
                .yplus => .yminus,
                .yminus => .yplus,
                .zplus => .zminus,
                .zminus => .zplus,
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
        return switch (smith.value(@typeInfo(Encoding).@"union".tag_type.?)) {
            .grid => blk: {
                grid.* = smith.value([ChunkSize][ChunkSize][ChunkSize]Block);
                break :blk .fromBlocks(grid);
            },
            .uniform => .{ .uniform = smith.value(Block) },
        };
    }

    const scale_factor = 2;
    const simplified_size = ChunkSize / scale_factor;

    const area_factor = scale_factor * scale_factor;
    // The u8 vote score packs exposed-first ordering as exp * (area_factor + 1) + tot, so its max must fit in u8.
    comptime {
        if ((area_factor + 1) * area_factor + area_factor > std.math.maxInt(u8)) @compileError("findBestBlock u8 score overflows; widen score or lower scale_factor");
    }

    fn getExposureMask(x: usize, y: usize, grid: *const [ChunkSize][ChunkSize][ChunkSize]Block.Tag, center: @Vector(ChunkSize, Block.Tag)) @Vector(ChunkSize, bool) {
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

    pub fn findBestBlock(
        comptime len: usize,
        rows: [area_factor]@Vector(len, Block.Tag),
        exposures: [area_factor]@Vector(len, bool),
    ) @Vector(len / scale_factor, Block.Tag) {
        const ds_len = len / scale_factor;
        const stride_mask = comptime blk: {
            var m: @Vector(ds_len, i32) = undefined;
            for (0..ds_len) |i| m[i] = @intCast(i * scale_factor);
            break :blk m;
        };

        // Downsample first: odd lanes are discarded by the stride anyway, so vote in half-width vectors.
        var r: [area_factor]@Vector(ds_len, Block.Tag) = undefined;
        var e: [area_factor]@Vector(ds_len, bool) = undefined;
        inline for (0..area_factor) |i| {
            r[i] = @shuffle(Block.Tag, rows[i], undefined, stride_mask);
            e[i] = @shuffle(bool, exposures[i], undefined, stride_mask);
        }

        // Exposed-first, then total; tot <= area_factor so one u8 orders both. Min score 1 beats the zero init.
        const weight: @Vector(ds_len, u8) = @splat(area_factor + 1);
        var best_v = r[0];
        var best_score: @Vector(ds_len, u8) = @splat(0);
        inline for (0..area_factor) |i| {
            var tot: @Vector(ds_len, u8) = @splat(1);
            var exp: @Vector(ds_len, u8) = @intFromBool(e[i]);
            inline for (0..area_factor) |j| {
                if (i != j) {
                    const match = r[i] == r[j];
                    tot += @intFromBool(match);
                    exp += @intFromBool(match & e[j]);
                }
            }
            const score = exp * weight + tot;
            const wins = score > best_score;
            best_v = @select(Block.Tag, wins, r[i], best_v);
            best_score = @select(u8, wins, score, best_score);
        }
        return best_v;
    }

    pub fn simplifyBlocks(grid: *align(GridAlignment) const [ChunkSize][ChunkSize][ChunkSize]Block) [simplified_size][simplified_size][simplified_size]Block {
        var simplified_grid: [simplified_size][simplified_size][simplified_size]Block align(GridAlignment) = undefined;
        for (0..simplified_size) |nx| {
            const x = nx * scale_factor;

            for (0..simplified_size) |ny| {
                const y = ny * scale_factor;

                var rows: [area_factor]@Vector(ChunkSize, Block.Tag) = undefined;
                var rows_all_eql: bool = true;
                inline for (0..scale_factor) |dx| {
                    inline for (0..scale_factor) |dy| {
                        const idx = dx * scale_factor + dy;
                        rows[idx] = @bitCast(grid[x + dx][y + dy]);
                        rows_all_eql &= @reduce(.And, @as(@Vector(ChunkSize, Block.Tag), @splat(rows[0][0])) == rows[idx]);
                    }
                }
                if (rows_all_eql) {
                    simplified_grid[nx][ny] = @splat(@enumFromInt(rows[0][0]));
                    continue;
                }
                var exposures: [area_factor]@Vector(ChunkSize, bool) = undefined;

                inline for (0..scale_factor) |dx| {
                    inline for (0..scale_factor) |dy| {
                        const idx = dx * scale_factor + dy;
                        exposures[idx] = getExposureMask(x + dx, y + dy, @ptrCast(grid), rows[idx]);
                    }
                }

                simplified_grid[nx][ny] = @bitCast(findBestBlock(ChunkSize, rows, exposures));
            }
        }
        return simplified_grid;
    }
};

///checks if the block array is all the same block
pub fn getUniform(block_array: *const [ChunkSize][ChunkSize][ChunkSize]Block) ?Block {
    const first_block_vec: @Vector(ChunkSize, @typeInfo(Block).@"enum".tag_type) = @splat(@intFromEnum(block_array[0][0][0]));
    var uniform: @Vector(ChunkSize, bool) = comptime @splat(true);
    const linear_block_array: *const [ChunkSize * ChunkSize][ChunkSize]@typeInfo(Block).@"enum".tag_type = @ptrCast(block_array);
    // Early-out in batches of 8 rows: amortizes the horizontal reduce while still
    // bailing long before the full 1024-row fold on any mismatch.
    for (linear_block_array, 0..) |blocks, idx| {
        uniform &= (blocks == first_block_vec);
        if ((idx & 7) == 7 and !@reduce(.And, uniform)) return null;
    }
    return if (@reduce(.And, uniform)) block_array[0][0][0] else null;
}

pub fn extractFace(self: *@This(), io: std.Io, comptime rotation: Encoding.FaceRotation, comptime remove_ref: bool) !Encoding.Face {
    defer if (remove_ref) self.release();
    try self.addAndLockShared(io);
    defer self.releaseAndUnlockShared(io);
    return self.encoding.extractFace(rotation);
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

    var diff_first: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));
    diff_first[0][0][0] = .stone;
    try testing.expectEqual(@as(?Block, null), getUniform(&diff_first));

    var diff_last: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));
    diff_last[ChunkSize - 1][ChunkSize - 1][ChunkSize - 1] = .stone;
    try testing.expectEqual(@as(?Block, null), getUniform(&diff_last));

    var diff_interior: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.stone)));
    diff_interior[ChunkSize / 2][ChunkSize / 2][ChunkSize / 2] = .air;
    try testing.expectEqual(@as(?Block, null), getUniform(&diff_interior));
}

test {
    std.testing.refAllDecls(@This());
}
