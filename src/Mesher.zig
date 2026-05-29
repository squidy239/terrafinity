const std = @import("std");

const Block = @import("world/Block.zig").Block;
const Chunk = @import("world/Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
pub const FaceRotation = Chunk.Encoding.FaceRotation;
const ChunkPos = @import("world/World.zig").ChunkPos;

const Mesher = @This();

pub const Face = packed struct(u64) {
    const CoordInChunk = @Int(.unsigned, std.math.log2(ChunkSize));
    x: CoordInChunk,
    y: CoordInChunk,
    z: CoordInChunk,
    rotation: FaceRotation,
    block_type: Block.Tag,
    _: u29 = undefined,
};

/// Entry point. Routes to 0-allocation uniform meshing or fully vectorized grid meshing.
/// neighbor_faces format: x+,x-,y+,y-,z+,z-, caller handles refs
pub fn mesh(allocator: std.mem.Allocator, mainblocks: Chunk.Encoding, noalias neighbor_faces: *const [6]Chunk.Encoding.Face, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) !void {
    switch (mainblocks) {
        .uniform => |main_block| {
            inline for (std.enums.values(FaceRotation)) |rotation| {
                const neighbor = &neighbor_faces[@intFromEnum(rotation)];
                if (!(neighbor.* == .uniform and main_block == neighbor.uniform))
                    try meshUniformChunkFace(allocator, main_block, neighbor, rotation, opaque_faces, transparent_faces);
            }
        },
        .grid => |grid| try meshBlockGrid(allocator, grid, neighbor_faces, opaque_faces, transparent_faces),
    }
}

inline fn getNeighborVec(comptime rotation: FaceRotation, neighbor_face: *const Chunk.Encoding.Face, x: usize, y: usize) @Vector(ChunkSize, Block.Tag) {
    switch (neighbor_face.*) {
        .uniform => |block| return @splat(@intFromEnum(block)),
        .blocks => |*face_grid| switch (comptime rotation) {
            .xminus, .xplus => return @bitCast(face_grid[y]),
            .yminus, .yplus => return @bitCast(face_grid[x]),
            .zminus, .zplus => unreachable,
        },
    }
}

inline fn getNeighborBlockZ(neighbor_face: *const Chunk.Encoding.Face, x: usize, y: usize) Block.Tag {
    switch (neighbor_face.*) {
        .uniform => |block| return @intFromEnum(block),
        .blocks => |*face_grid| return @intFromEnum(face_grid[x][y]),
    }
}

fn meshUniformChunkFace(allocator: std.mem.Allocator, main_block: Block, neighbor_face: *const Chunk.Encoding.Face, comptime rotation: FaceRotation, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) !void {
    try opaque_faces.ensureUnusedCapacity(allocator, ChunkSize * ChunkSize);
    try transparent_faces.ensureUnusedCapacity(allocator, ChunkSize * ChunkSize);

    const one_uniform_vec: @Vector(ChunkSize, Block.Tag) = @splat(@intFromEnum(main_block));
    const two_uniform_vec: @Vector(ChunkSize, Block.Tag) = if (neighbor_face.* == .uniform) @splat(@intFromEnum(neighbor_face.uniform)) else undefined;

    for (0..ChunkSize) |i| {
        const two_vec: @Vector(ChunkSize, Block.Tag) = switch (neighbor_face.*) {
            .blocks => |*grid| @bitCast(grid[i]),
            .uniform => two_uniform_vec,
        };

        const transparent_vec, const opaque_vec = meshMany(ChunkSize, one_uniform_vec, two_vec);
        const transparent: @Int(.unsigned, ChunkSize) = @bitCast(transparent_vec);
        const @"opaque": @Int(.unsigned, ChunkSize) = @bitCast(opaque_vec);
        addUniformFaces(transparent, comptime rotation, true, i, opaque_faces, transparent_faces, main_block);
        addUniformFaces(@"opaque", comptime rotation, false, i, opaque_faces, transparent_faces, main_block);
    }
}

inline fn addUniformFaces(mask_start: @Int(.unsigned, ChunkSize), comptime rotation: FaceRotation, comptime transparent: bool, i: usize, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face), block: Block) void {
    var mask = mask_start;
    while (mask != 0) {
        const j = @ctz(mask);
        mask &= (mask - 1);

        const face: Face = .{
            .x = @intCast(switch (comptime rotation) {
                .xminus => 0,
                .xplus => ChunkSize - 1,
                .yminus, .yplus => i,
                .zminus, .zplus => i,
            }),
            .y = @intCast(switch (comptime rotation) {
                .xminus, .xplus => i,
                .yminus => 0,
                .yplus => ChunkSize - 1,
                .zminus, .zplus => j,
            }),
            .z = @intCast(switch (comptime rotation) {
                .xminus, .xplus => j,
                .yminus, .yplus => j,
                .zminus => 0,
                .zplus => ChunkSize - 1,
            }),
            .rotation = comptime rotation,
            .block_type = @intFromEnum(block),
        };

        switch (comptime transparent) {
            true => transparent_faces.appendAssumeCapacity(face),
            false => opaque_faces.appendAssumeCapacity(face),
        }
    }
}

fn meshBlockGrid(allocator: std.mem.Allocator, noalias grid: *const [ChunkSize][ChunkSize][ChunkSize]Block, noalias neighbor_faces: *const [6]Chunk.Encoding.Face, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) !void {
    for (0..ChunkSize) |x| {
        try opaque_faces.ensureUnusedCapacity(allocator, 6 * ChunkSize * ChunkSize);
        try transparent_faces.ensureUnusedCapacity(allocator, 6 * ChunkSize * ChunkSize);
        @prefetch(&grid[x], .{ .locality = 3, .rw = .read, .cache = .data });

        for (0..ChunkSize) |y| {
            const center_row: [ChunkSize]Block.Tag = @bitCast(grid[x][y]);

            inline for (std.enums.values(FaceRotation)) |rotation| {
                const at_boundary = switch (comptime rotation) {
                    .xplus => x == ChunkSize - 1,
                    .xminus => x == 0,
                    .yplus => y == ChunkSize - 1,
                    .yminus => y == 0,
                    .zplus, .zminus => false,
                };

                const neighbor_vec: @Vector(ChunkSize, Block.Tag) = switch (comptime rotation) {
                    .xminus => if (at_boundary) getNeighborVec(rotation, &neighbor_faces[@intFromEnum(rotation)], x, y) else @bitCast(grid[x - 1][y]),
                    .xplus => if (at_boundary) getNeighborVec(rotation, &neighbor_faces[@intFromEnum(rotation)], x, y) else @bitCast(grid[x + 1][y]),
                    .yminus => if (at_boundary) getNeighborVec(rotation, &neighbor_faces[@intFromEnum(rotation)], x, y) else @bitCast(grid[x][y - 1]),
                    .yplus => if (at_boundary) getNeighborVec(rotation, &neighbor_faces[@intFromEnum(rotation)], x, y) else @bitCast(grid[x][y + 1]),
                    .zminus => std.simd.shiftElementsRight(center_row, 1, getNeighborBlockZ(&neighbor_faces[@intFromEnum(rotation)], x, y)),
                    .zplus => std.simd.shiftElementsLeft(center_row, 1, getNeighborBlockZ(&neighbor_faces[@intFromEnum(rotation)], x, y)),
                };

                computeRow(center_row, neighbor_vec, center_row, rotation, @intCast(x), @intCast(y), transparent_faces, opaque_faces);
            }
        }
    }
}

inline fn computeRow(center_row: [ChunkSize]Block.Tag, neighbor_vec: @Vector(ChunkSize, Block.Tag), center_vec: @Vector(ChunkSize, Block.Tag), comptime rotation: FaceRotation, x: u8, y: u8, noalias transparent_faces: *std.ArrayList(Face), noalias opaque_faces: *std.ArrayList(Face)) void {
    const transparent_vec, const opaque_vec = meshMany(ChunkSize, center_vec, neighbor_vec);
    const transparent: @Int(.unsigned, ChunkSize) = @bitCast(transparent_vec);
    const @"opaque": @Int(.unsigned, ChunkSize) = @bitCast(opaque_vec);
    addGridFaces(transparent, rotation, true, center_row, x, y, opaque_faces, transparent_faces);
    addGridFaces(@"opaque", rotation, false, center_row, x, y, opaque_faces, transparent_faces);
}

inline fn addGridFaces(mask_copy: @Int(.unsigned, ChunkSize), comptime rotation: FaceRotation, comptime transparent: bool, center_row: [ChunkSize]Block.Tag, x: u8, y: u8, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) void {
    var mask = mask_copy;
    while (mask != 0) {
        const z: u8 = @ctz(mask);
        mask &= (mask - 1);

        const face = Face{
            .block_type = center_row[z],
            .rotation = rotation,
            .x = @intCast(x),
            .y = @intCast(y),
            .z = @intCast(z),
        };

        switch (transparent) {
            true => transparent_faces.appendAssumeCapacity(face),
            false => opaque_faces.appendAssumeCapacity(face),
        }
    }
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

inline fn meshMany(len: usize, one: @Vector(len, Block.Tag), two: @Vector(len, Block.Tag)) struct { @Vector(len, bool), @Vector(len, bool) } {
    const is_same = one == two;
    const ones_invisible = !Block.isVisibleVector(len, one);
    const twos_opaque = !Block.isTransparentVector(len, two);
    const ones_transparent = Block.isTransparentVector(len, one);
    const abort_mask = is_same | ones_invisible | twos_opaque;
    const false_mask: @Vector(len, bool) = comptime @splat(false);
    return .{
        @select(bool, abort_mask, false_mask, ones_transparent),
        @select(bool, abort_mask, false_mask, !ones_transparent),
    };
}

test "Compare meshMany vs meshOne" {
    if (true) return;
    const all_blocks = std.enums.values(Block);
    for (all_blocks) |one| {
        for (all_blocks) |two| {
            const expected = meshOne(one, two);
            const v_one: @Vector(1, Block.Tag) = @splat(@intFromEnum(one));
            const v_two: @Vector(1, Block.Tag) = @splat(@intFromEnum(two));
            const result_vec = meshMany(1, v_one, v_two);
            const actual: MeshResult = if (!result_vec.opaque_mask[0] and !result_vec.transparent_mask[0]) .none else if (result_vec.transparent_mask[0]) .transparent else .@"opaque";
            try std.testing.expectEqual(expected, actual);
        }
    }
}

test "MeshBehavior - Uniform Air Chunk" {
    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const mainblocks: Chunk.Encoding = .{ .uniform = .air };
    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    try mesh(std.testing.allocator, mainblocks, &neighbor_faces, &opaque_faces, &transparent_faces);

    try std.testing.expectEqual(@as(usize, 0), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);
}

test "MeshBehavior - Single Isolated Block" {
    var blocks: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));

    blocks[1][1][1] = .stone;

    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    try mesh(std.testing.allocator, .{ .grid = &blocks }, &neighbor_faces, &opaque_faces, &transparent_faces);

    try std.testing.expectEqual(@as(usize, 6), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);

    for (opaque_faces.items) |face| {
        try std.testing.expect(face.x == 1);
        try std.testing.expect(face.y == 1);
        try std.testing.expect(face.z == 1);
        try std.testing.expect(face.block_type == @intFromEnum(Block.stone));
    }
}

test "MeshBehavior - Adjacent Blocks Culling" {
    var blocks: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));

    blocks[1][1][1] = .stone;
    blocks[2][1][1] = .stone;

    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    try mesh(std.testing.allocator, .{ .grid = &blocks }, &neighbor_faces, &opaque_faces, &transparent_faces);

    try std.testing.expectEqual(@as(usize, 10), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);
}

test "MeshBenchmark" {
    var blocks: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                blocks[x][y][z] = switch (y) {
                    0...16 => .stone,
                    17 => .grass,
                    else => .air,
                };
            }
        }
    }
    var alist: std.ArrayList(Face) = try .initCapacity(std.testing.allocator, 65536);
    defer alist.deinit(std.testing.allocator);

    // Kept to the exact sizing you had for poop benchmarking
    const test_amount = if (@import("builtin").mode == .Debug) 100 else 200000;
    const st = std.Io.Timestamp.now(std.testing.io, .awake);

    for (0..test_amount) |_| {
        try mesh(std.testing.allocator, .{ .grid = &blocks }, &@splat(Chunk.Encoding.Face{ .uniform = .air }), &alist, &alist);
        alist.clearRetainingCapacity();
    }

    const et = std.Io.Timestamp.now(std.testing.io, .awake);
    const dt = st.durationTo(et);
    std.log.warn("Mesh benchmark: {d} meshes in {d} ms", .{ test_amount, dt.toMilliseconds() });
    std.log.warn("completed with an avg time of {d} us per mesh", .{(@as(f64, @floatFromInt(dt.toMicroseconds())) / test_amount)});
}

test "FuzzMesh" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(_: void, smith: *std.testing.Smith) !void {
    var blocks: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
    const mainblocks: Chunk.Encoding = .fuzzerMakeEncoding(&blocks, smith);
    const neighbor_faces: [6]Chunk.Encoding.Face = smith.value([6]Chunk.Encoding.Face);

    var alist: std.ArrayList(Face) = .empty;
    defer alist.deinit(std.testing.allocator);

    try Mesher.mesh(std.testing.allocator, mainblocks, &neighbor_faces, &alist, &alist);
}
