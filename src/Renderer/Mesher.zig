const std = @import("std");

const Block = @import("../world/Block.zig").Block;
const Chunk = @import("../world/Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
pub const FaceRotation = Chunk.Encoding.FaceRotation;

const Mesher = @This();

pub const max_face_bytes = ChunkSize * ChunkSize * ChunkSize * 6 * @sizeOf(Face);

pub const Face = packed struct(u64) {
    const CoordInChunk = Chunk.Int;
    block_type: Block.Tag,

    // Each length extends the face toward higher coordinates by that many faces plus one.
    z_length: CoordInChunk = 0,
    y_length: CoordInChunk = 0,
    x_length: CoordInChunk = 0,

    z: CoordInChunk,
    y: CoordInChunk,
    x: CoordInChunk,

    rotation: FaceRotation,

    _: @Int(.unsigned, 64 - (6 * @bitSizeOf(CoordInChunk) + @bitSizeOf(FaceRotation) + @bitSizeOf(Block.Tag))) = undefined,
};

/// One side exposes at most ChunkSize*ChunkSize faces (an unmerged uniform side is the worst case).
/// Six rotations emit at most this many faces into one list, so one reserve per list covers the loop.
const max_uniform_faces_per_list = 6 * ChunkSize * ChunkSize;
pub fn mesh(allocator: std.mem.Allocator, main_grid: Chunk.Encoding, noalias neighbor_faces: *const [6]Chunk.Encoding.Face, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) !void {
    switch (main_grid) {
        .uniform => |main_block| {
            if (!main_block.isVisible()) return;
            // Probe before reserving: a fully-occluded uniform chunk emits
            // zero faces, and reserving first would grow both lists by
            // max_uniform_faces_per_list (~96KB total) for nothing.
            if (!uniformChunkExposed(main_block, neighbor_faces)) return;
            // One reserve per list up front, so every append in the
            // rotation loop below is infallible and needs no rollback.
            try opaque_faces.ensureUnusedCapacity(allocator, max_uniform_faces_per_list);
            try transparent_faces.ensureUnusedCapacity(allocator, max_uniform_faces_per_list);
            const opaque_before = opaque_faces.items.len;
            const transparent_before = transparent_faces.items.len;
            inline for (std.enums.values(FaceRotation)) |rotation| {
                meshUniformChunkFace(main_block, &neighbor_faces[@backingInt(rotation)], rotation, opaque_faces, transparent_faces);
            }
            std.debug.assert(opaque_faces.items.len - opaque_before <= max_uniform_faces_per_list);
            std.debug.assert(transparent_faces.items.len - transparent_before <= max_uniform_faces_per_list);
        },
        .grid => |grid| try meshBlockGrid(allocator, @ptrCast(grid), neighbor_faces, opaque_faces, transparent_faces),
    }
}

inline fn uniformChunkExposed(main_block: Block, neighbor_faces: *const [6]Chunk.Encoding.Face) bool {
    inline for (std.enums.values(FaceRotation)) |rotation| {
        if (uniformFaceExposed(main_block, &neighbor_faces[@backingInt(rotation)])) return true;
    }
    return false;
}

inline fn uniformFaceExposed(main_block: Block, neighbor_face: *const Chunk.Encoding.Face) bool {
    switch (neighbor_face.*) {
        .uniform => |block| return meshOne(main_block, block) != .none,
        .grid => |*face_grid| {
            for (face_grid.*) |row| {
                for (row) |cell| {
                    if (meshOne(main_block, cell) != .none) return true;
                }
            }
            return false;
        },
    }
}

inline fn getNeighborVec(comptime rotation: FaceRotation, neighbor_face: *const Chunk.Encoding.Face, x: usize, y: usize) @Vector(ChunkSize, Block.Tag) {
    switch (neighbor_face.*) {
        .uniform => |block| return @splat(@backingInt(block)),
        .grid => |*face_grid| switch (comptime rotation) {
            .xminus, .xplus => return @bitCast(face_grid[y]),
            .yminus, .yplus => return @bitCast(face_grid[x]),
            .zminus, .zplus => unreachable,
        },
    }
}

fn meshUniformChunkFace(main_block: Block, neighbor_face: *const Chunk.Encoding.Face, comptime rotation: FaceRotation, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) void {
    if (neighbor_face.* == .uniform and meshOne(main_block, neighbor_face.uniform) == .none) return;
    if (!main_block.isVisible()) return;
    const one_uniform_vec: @Vector(ChunkSize, Block.Tag) = @splat(@backingInt(main_block));
    const ones_visible: @Int(.unsigned, ChunkSize) = std.math.maxInt(@Int(.unsigned, ChunkSize));
    const ones_transparent: @Int(.unsigned, ChunkSize) = @bitCast(Block.isTransparentVector(ChunkSize, one_uniform_vec));

    const uniform_two_vec: @Vector(ChunkSize, Block.Tag) = if (neighbor_face.* == .uniform) @splat(@backingInt(neighbor_face.uniform)) else undefined;
    for (0..ChunkSize) |row_index| {
        const two_vec: @Vector(ChunkSize, Block.Tag) = switch (neighbor_face.*) {
            .uniform => uniform_two_vec,
            .grid => |*grid| @bitCast(grid[row_index]),
        };
        const transparent, const @"opaque" = meshMany(ChunkSize, one_uniform_vec, ones_visible, ones_transparent, two_vec);
        if (transparent != 0) addSideFaces(ChunkSize, transparent, comptime rotation, true, @intCast(row_index), opaque_faces, transparent_faces, main_block);
        if (@"opaque" != 0) addSideFaces(ChunkSize, @"opaque", comptime rotation, false, @intCast(row_index), opaque_faces, transparent_faces, main_block);
    }
}

inline fn addSideFaces(comptime len: usize, mask_start: @Int(.unsigned, len), comptime rotation: FaceRotation, comptime transparent: bool, row_index: u8, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face), block: Block) void {
    var mask = mask_start;
    const faces = switch (comptime transparent) {
        true => transparent_faces,
        false => opaque_faces,
    };
    // Reserve-bound check: the up-front reserve must cover this call's popcount faces.
    // It fails loudly in debug instead of overflowing addOneAssumeCapacity.
    std.debug.assert(faces.capacity - faces.items.len >= @as(usize, @popCount(mask_start)));
    const row: Face.CoordInChunk = @intCast(row_index);
    const x_fixed: Face.CoordInChunk = switch (comptime rotation) {
        .xminus => 0,
        .xplus => ChunkSize - 1,
        .yminus, .yplus, .zminus, .zplus => row,
    };
    const y_is_lane: bool = comptime rotation == .zminus or rotation == .zplus;
    const y_fixed: Face.CoordInChunk = switch (comptime rotation) {
        .yminus => 0,
        .yplus => ChunkSize - 1,
        .xminus, .xplus => row,
        .zminus, .zplus => undefined,
    };
    const z_fixed: Face.CoordInChunk = switch (comptime rotation) {
        .zminus => 0,
        .zplus => ChunkSize - 1,
        .xminus, .xplus, .yminus, .yplus => undefined,
    };
    // Mirror addGridFaces: merge a contiguous run along z (the lane axis of the
    // x/y rotations, whose face plane contains it) and never water, whose
    // shader animation is anchored per face. z rotations keep one face per lane.
    const merge_block = block != Block.water;
    var last: Face = undefined;
    var pending = false;
    while (mask != 0) {
        const lane = @ctz(mask);
        mask &= (mask - 1);
        const lane_coord: Face.CoordInChunk = @intCast(lane);
        if (pending and !y_is_lane and merge_block and lane_coord == last.z + last.z_length + 1) {
            last.z_length += 1;
            continue;
        }
        if (pending) faces.appendAssumeCapacity(last);
        last = .{
            .x = x_fixed,
            .y = if (y_is_lane) lane_coord else y_fixed,
            .z = if (y_is_lane) z_fixed else lane_coord,
            .rotation = comptime rotation,
            .block_type = @backingInt(block),
        };
        pending = true;
    }
    if (pending) faces.appendAssumeCapacity(last);
}

/// Worst-case faces for one x-slice: each (y, rotation) row emits at most ChunkSize faces.
/// One slice holds at most 6 * ChunkSize * ChunkSize faces, which only amortizes growth.
const max_faces_per_x_slice = 6 * ChunkSize * ChunkSize;
/// On allocation failure both face lists roll back to their entry lengths, so a
/// failed grid-path mesh leaves no partial chunk behind.
/// The uniform path needs no rollback: it reserves up front, then appends infallibly.
fn meshBlockGrid(allocator: std.mem.Allocator, noalias grid: *const [ChunkSize][ChunkSize][ChunkSize]Block.Tag, noalias neighbor_faces: *const [6]Chunk.Encoding.Face, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) !void {
    const opaque_checkpoint = opaque_faces.items.len;
    const transparent_checkpoint = transparent_faces.items.len;
    errdefer {
        opaque_faces.shrinkRetainingCapacity(opaque_checkpoint);
        transparent_faces.shrinkRetainingCapacity(transparent_checkpoint);
    }
    try opaque_faces.ensureUnusedCapacity(allocator, max_faces_per_x_slice);
    try transparent_faces.ensureUnusedCapacity(allocator, max_faces_per_x_slice);
    const zplus_mask: @Vector(ChunkSize, i32) = blk: {
        comptime var mask = std.simd.iota(i32, ChunkSize) + @as(@Vector(ChunkSize, i32), @splat(1));
        mask[ChunkSize - 1] = 0;
        break :blk mask;
    };
    const zminus_mask: @Vector(ChunkSize, i32) = blk: {
        comptime var mask = std.simd.iota(i32, ChunkSize) - @as(@Vector(ChunkSize, i32), @splat(1));
        mask[0] = 0;
        break :blk mask;
    };
    var x: u8 = 0;
    while (x < ChunkSize) : (x += 1) {
        const zminus_neighbors: [ChunkSize]Block.Tag = switch (neighbor_faces[@backingInt(FaceRotation.zminus)]) {
            .uniform => |block| @splat(@backingInt(block)),
            .grid => |*g| @bitCast(g[x]),
        };

        const zplus_neighbors: [ChunkSize]Block.Tag = switch (neighbor_faces[@backingInt(FaceRotation.zplus)]) {
            .uniform => |block| @splat(@backingInt(block)),
            .grid => |*g| @bitCast(g[x]),
        };

        const xplus_uniform: ?@Vector(ChunkSize, Block.Tag) = if (x == ChunkSize - 1) switch (neighbor_faces[@backingInt(FaceRotation.xplus)]) {
            .uniform => |block| @splat(@backingInt(block)),
            .grid => null,
        } else null;
        const xminus_uniform: ?@Vector(ChunkSize, Block.Tag) = if (x == 0) switch (neighbor_faces[@backingInt(FaceRotation.xminus)]) {
            .uniform => |block| @splat(@backingInt(block)),
            .grid => null,
        } else null;

        var y: u8 = 0;
        while (y < ChunkSize) : (y += 1) {
            const center_row: @Vector(ChunkSize, Block.Tag) = @bitCast(grid[x][y]); // Measured faster than coercing the row.
            const ones_visible: @Int(.unsigned, ChunkSize) = @bitCast(Block.isVisibleVector(ChunkSize, center_row));
            if (ones_visible == 0) continue;
            const ones_transparent: @Int(.unsigned, ChunkSize) = @bitCast(Block.isTransparentVector(ChunkSize, center_row));
            const neighbor_vecs: [std.enums.values(FaceRotation).len]@Vector(ChunkSize, Block.Tag) = .{
                if (xplus_uniform) |v| v else if (x == ChunkSize - 1) getNeighborVec(.xplus, &neighbor_faces[@backingInt(FaceRotation.xplus)], x, y) else grid[x + 1][y],
                if (xminus_uniform) |v| v else if (x == 0) getNeighborVec(.xminus, &neighbor_faces[@backingInt(FaceRotation.xminus)], x, y) else grid[x - 1][y],
                if (y == comptime ChunkSize - 1) getNeighborVec(.yplus, &neighbor_faces[@backingInt(FaceRotation.yplus)], x, y) else grid[x][y + 1],
                if (y == 0) getNeighborVec(.yminus, &neighbor_faces[@backingInt(FaceRotation.yminus)], x, y) else grid[x][y - 1],
                sh: {
                    var shifted_row = @shuffle(Block.Tag, center_row, undefined, zplus_mask);
                    shifted_row[comptime ChunkSize - 1] = zplus_neighbors[y];
                    break :sh shifted_row;
                },
                sh: {
                    var shifted_row = @shuffle(Block.Tag, center_row, undefined, zminus_mask);
                    shifted_row[comptime 0] = zminus_neighbors[y];
                    break :sh shifted_row;
                },
            };
            inline for (neighbor_vecs, std.enums.values(FaceRotation)) |neighbor_vec, rotation| {
                var transparent, var @"opaque" = meshMany(ChunkSize, center_row, ones_visible, ones_transparent, neighbor_vec);
                if (@"opaque" != 0) try addGridFaces(ChunkSize, allocator, &@"opaque", rotation, false, &grid[x][y], @intCast(x), @intCast(y), opaque_faces, transparent_faces);
                if (transparent != 0) try addGridFaces(ChunkSize, allocator, &transparent, rotation, true, &grid[x][y], @intCast(x), @intCast(y), opaque_faces, transparent_faces);
            }
        }
    }
}

fn addGridFaces(comptime len: usize, allocator: std.mem.Allocator, noalias mask: *@Int(.unsigned, len), comptime rotation: FaceRotation, comptime transparent: bool, noalias center_row: *const [len]Block.Tag, x: Face.CoordInChunk, y: Face.CoordInChunk, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) !void {
    std.debug.assert(mask.* != 0);
    const faces_list = switch (comptime transparent) {
        true => transparent_faces,
        false => opaque_faces,
    };
    const greedy_z = comptime switch (rotation) {
        .zminus, .zplus => false,
        else => true,
    };

    const water_tag = @backingInt(Block.water);
    var last: Face = undefined;
    var pending = false;
    while (mask.* != 0) : (mask.* &= (mask.* - 1)) {
        const z: Face.CoordInChunk = @intCast(@ctz(mask.*));
        const block = center_row[z];
        if (pending and greedy_z and last.block_type == block and block != water_tag and z == last.z + last.z_length + 1) {
            @branchHint(.unpredictable);
            last.z_length += 1;
            continue;
        }
        if (pending) try faces_list.append(allocator, last);
        last = .{
            .z = z,
            .z_length = 0,
            .rotation = rotation,
            .y = y,
            .x = x,
            .block_type = block,
        };
        pending = true;
    }
    std.debug.assert(pending); // mask can't be 0
    try faces_list.append(allocator, last);
}

pub const MeshResult = enum(Tag) {
    pub const Tag = u8;
    none,
    transparent,
    @"opaque",
};

inline fn meshOne(one: Block, two: Block) MeshResult {
    if (one == two or !one.isVisible() or !two.isTransparent()) return .none;
    return if (one.isTransparent()) .transparent else .@"opaque";
}

fn meshMany(comptime len: usize, one: @Vector(len, Block.Tag), ones_visible: @Int(.unsigned, len), ones_transparent: @Int(.unsigned, len), two: @Vector(len, Block.Tag)) struct { @Int(.unsigned, len), @Int(.unsigned, len) } {
    const LenInt = @Int(.unsigned, len);
    const not_same: LenInt = @bitCast(one != two);
    if (not_same == 0) return .{ 0, 0 };
    const twos_transparent: LenInt = @bitCast(Block.isTransparentVector(len, two));
    const valid_face = not_same & ones_visible & twos_transparent;

    return .{
        (valid_face & ones_transparent),
        (valid_face & ~ones_transparent),
    };
}

test "Compare meshMany vs meshOne" {
    const all_blocks = std.enums.values(Block);
    for (all_blocks) |one| {
        for (all_blocks) |two| {
            const expected = meshOne(one, two);
            const v_one: @Vector(1, Block.Tag) = @splat(@backingInt(one));
            const v_two: @Vector(1, Block.Tag) = @splat(@backingInt(two));
            const ones_visible: @Int(.unsigned, 1) = @bitCast(Block.isVisibleVector(1, v_one));
            const ones_transparent: @Int(.unsigned, 1) = @bitCast(Block.isTransparentVector(1, v_one));
            const transparent, const @"opaque" = meshMany(1, v_one, ones_visible, ones_transparent, v_two);
            const actual: MeshResult = if (@"opaque" == 0 and transparent == 0) .none else if (transparent == 1) .transparent else .@"opaque";
            try std.testing.expectEqual(expected, actual);
        }
    }
}

test "MeshBehavior - Uniform Air and Solid Chunks" {
    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    // Phase 1: uniform air emits nothing.
    const air_grid: Chunk.Encoding = .{ .uniform = .air };
    const air_neighbors: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });
    try mesh(std.testing.allocator, air_grid, &air_neighbors, &opaque_faces, &transparent_faces);
    try std.testing.expectEqual(@as(usize, 0), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);

    // Phase 2: uniform solid exposed to air emits its boundary faces (merged along z per row).
    const solid_grid: Chunk.Encoding = .{ .uniform = .stone };
    try mesh(std.testing.allocator, solid_grid, &air_neighbors, &opaque_faces, &transparent_faces);
    try std.testing.expectEqual(4 * ChunkSize + 2 * (ChunkSize * ChunkSize), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);
}

test "MeshBehavior - Single Isolated Block and Rotations" {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));

    grid[1][1][1] = .stone;

    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    try mesh(std.testing.allocator, .{ .grid = &grid }, &neighbor_faces, &opaque_faces, &transparent_faces);

    try std.testing.expectEqual(@as(usize, 6), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);

    var seen_rotations: [6]bool = @splat(false);
    for (opaque_faces.items) |face| {
        try std.testing.expect(face.x == 1);
        try std.testing.expect(face.y == 1);
        try std.testing.expect(face.z == 1);
        try std.testing.expect(face.block_type == @backingInt(Block.stone));
        seen_rotations[@backingInt(face.rotation)] = true;
    }

    // Second phase: every rotation enum was generated exactly once.
    for (seen_rotations) |seen| {
        if (!seen) return error.MissingFaceRotation;
    }
}

test "MeshBehavior - Adjacent Culling and Enclosed Greedy Count" {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));

    grid[1][1][1] = .stone;
    grid[2][1][1] = .stone;

    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    // Phase 1: two adjacent blocks share one culled face (12 - 2 = 10).
    try mesh(std.testing.allocator, .{ .grid = &grid }, &neighbor_faces, &opaque_faces, &transparent_faces);
    try std.testing.expectEqual(@as(usize, 10), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);

    // Phase 2: a 3x3x3 solid cube. The center block is fully enclosed; the
    // surface area is 3 * 3 blocks per face * 6 faces = 54 faces, reduced to
    // 30 by z-axis greedy meshing.
    grid = @splat(@splat(@splat(.air)));
    for (1..4) |x| {
        for (1..4) |y| {
            for (1..4) |z| {
                grid[x][y][z] = .stone;
            }
        }
    }
    opaque_faces.clearRetainingCapacity();
    try mesh(std.testing.allocator, .{ .grid = &grid }, &neighbor_faces, &opaque_faces, &transparent_faces);
    try std.testing.expectEqual(@as(usize, 30), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);
}

test "MeshBehavior - Chunk Boundary Culling Uniform and Grid" {
    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    // Phase 1 (uniform neighbor): block on the X=0 boundary, solid stone
    // neighbor on -X culls exactly one face.
    {
        var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));
        grid[0][1][1] = .stone;
        var neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });
        neighbor_faces[@backingInt(FaceRotation.xminus)] = .{ .uniform = .stone };
        try mesh(std.testing.allocator, .{ .grid = &grid }, &neighbor_faces, &opaque_faces, &transparent_faces);
        try std.testing.expectEqual(@as(usize, 5), opaque_faces.items.len);
        try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);
        opaque_faces.clearRetainingCapacity();
    }

    // Phase 2 (uniform main): solid chunk with a solid neighbor below culls
    // the whole yminus face.
    {
        var neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });
        neighbor_faces[@backingInt(FaceRotation.yminus)] = .{ .uniform = .stone };
        try mesh(std.testing.allocator, .{ .uniform = .stone }, &neighbor_faces, &opaque_faces, &transparent_faces);
        try std.testing.expectEqual(3 * ChunkSize + 2 * (ChunkSize * ChunkSize), opaque_faces.items.len);
        try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);
        opaque_faces.clearRetainingCapacity();
    }

    // Phase 3 (grid neighbor): blocks touching exactly across the boundary
    // cull the shared face.
    {
        var main_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));
        main_grid[0][5][5] = .stone;
        var neighbor_face_grid: [ChunkSize][ChunkSize]Block = @splat(@splat(.air));
        neighbor_face_grid[5][5] = .stone;
        var neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });
        neighbor_faces[@backingInt(FaceRotation.xminus)] = .{ .grid = neighbor_face_grid };
        try mesh(std.testing.allocator, .{ .grid = &main_grid }, &neighbor_faces, &opaque_faces, &transparent_faces);
        try std.testing.expectEqual(@as(usize, 5), opaque_faces.items.len);
        try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);
    }
}

test "MeshBehavior - Transparent Routing and Opaque Interaction" {
    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    // Phase 1 (interaction): stone at X=1 next to water at X=2. The opaque
    // face against transparent water still renders; the transparent face
    // against opaque stone is culled.
    {
        var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));
        grid[1][1][1] = .stone;
        grid[2][1][1] = .water;
        try mesh(std.testing.allocator, .{ .grid = &grid }, &neighbor_faces, &opaque_faces, &transparent_faces);
        try std.testing.expectEqual(@as(usize, 6), opaque_faces.items.len);
        try std.testing.expectEqual(@as(usize, 5), transparent_faces.items.len);
        opaque_faces.clearRetainingCapacity();
        transparent_faces.clearRetainingCapacity();
    }

    // Phase 2 (routing): separated opaque and transparent blocks route to
    // their own lists.
    {
        var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));
        grid[1][1][1] = .stone;
        grid[3][3][3] = .water;
        try mesh(std.testing.allocator, .{ .grid = &grid }, &neighbor_faces, &opaque_faces, &transparent_faces);
        try std.testing.expectEqual(@as(usize, 6), opaque_faces.items.len);
        try std.testing.expectEqual(@as(usize, 6), transparent_faces.items.len);
    }
}

test "FuzzMesh" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(_: void, smith: *std.testing.Smith) !void {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = undefined;
    const main_grid: Chunk.Encoding = .fuzzerMakeEncoding(&grid, smith);
    const neighbor_faces: [6]Chunk.Encoding.Face = smith.value([6]Chunk.Encoding.Face);

    var opaque_faces: std.ArrayList(Face) = .empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces: std.ArrayList(Face) = .empty;
    defer transparent_faces.deinit(std.testing.allocator);

    try Mesher.mesh(std.testing.allocator, main_grid, &neighbor_faces, &opaque_faces, &transparent_faces);
}
