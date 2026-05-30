const std = @import("std");

const Block = @import("world/Block.zig").Block;
const Chunk = @import("world/Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
pub const FaceRotation = Chunk.Encoding.FaceRotation;
const ChunkPos = @import("world/World.zig").ChunkPos;

const Mesher = @This();

pub const Face = packed struct(u64) {
    const CoordInChunk = @Int(.unsigned, std.math.log2_int_ceil(usize, ChunkSize));
    z: CoordInChunk,
    y: CoordInChunk,
    x: CoordInChunk,
    rotation: FaceRotation,
    block_type: Block.Tag,
    _: @Int(.unsigned, @bitSizeOf(u64) - (3 * @bitSizeOf(CoordInChunk) + @bitSizeOf(FaceRotation) + @bitSizeOf(Block.Tag))) = undefined,
};

const batch_size = 64;
/// Entry point. Routes to 0-allocation uniform meshing or fully vectorized grid meshing.
/// neighbor_faces format: x+,x-,y+,y-,z+,z-, caller handles refs
pub fn mesh(allocator: std.mem.Allocator, maingrid: Chunk.Encoding, noalias neighbor_faces: *const [6]Chunk.Encoding.Face, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) !void {
    switch (maingrid) {
        .uniform => |main_block| {
            inline for (std.enums.values(FaceRotation)) |rotation| {
                const neighbor = &neighbor_faces[@intFromEnum(rotation)];
                if (!(neighbor.* == .uniform and main_block == neighbor.uniform))
                    try meshUniformChunkFace(allocator, main_block, neighbor, rotation, opaque_faces, transparent_faces);
            }
        },
        .grid => |grid| try meshBlockGrid(allocator, @ptrCast(grid), neighbor_faces, opaque_faces, transparent_faces),
    }
}

inline fn getNeighborVec(comptime rotation: FaceRotation, neighbor_face: *const Chunk.Encoding.Face, x: usize, y: usize) @Vector(ChunkSize, Block.Tag) {
    switch (neighbor_face.*) {
        .uniform => |block| return @splat(@intFromEnum(block)),
        .grid => |*face_grid| switch (comptime rotation) {
            .xminus, .xplus => return @bitCast(face_grid[y]),
            .yminus, .yplus => return @bitCast(face_grid[x]),
            .zminus, .zplus => unreachable,
        },
    }
}

inline fn getNeighborBlockZ(neighbor_face: *const Chunk.Encoding.Face, x: usize, y: usize) Block.Tag {
    switch (neighbor_face.*) {
        .uniform => |block| return @intFromEnum(block),
        .grid => |*grid| return @intFromEnum(grid[x][y]),
    }
}

fn meshUniformChunkFace(allocator: std.mem.Allocator, main_block: Block, neighbor_face: *const Chunk.Encoding.Face, comptime rotation: FaceRotation, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) !void {
    if (neighbor_face.* == .uniform and meshOne(main_block, neighbor_face.uniform) == .none) return;
    try opaque_faces.ensureUnusedCapacity(allocator, ChunkSize * ChunkSize);
    try transparent_faces.ensureUnusedCapacity(allocator, ChunkSize * ChunkSize);
    const one_uniform_vec: @Vector(ChunkSize, Block.Tag) = @splat(@intFromEnum(main_block));
    const two_uniform_vec: @Vector(ChunkSize, Block.Tag) = if (neighbor_face.* == .uniform) @splat(@intFromEnum(neighbor_face.uniform)) else undefined;

    for (0..ChunkSize) |i| {
        const two_vec: @Vector(ChunkSize, Block.Tag) = switch (neighbor_face.*) {
            .grid => |*grid| @bitCast(grid[i]),
            .uniform => two_uniform_vec,
        };

        const transparent, const @"opaque" = meshMany(ChunkSize, one_uniform_vec, two_vec);
         if (transparent != 0) addSideFaces(ChunkSize, transparent, comptime rotation, true, i, opaque_faces, transparent_faces, main_block);
         if (@"opaque" != 0) addSideFaces(ChunkSize, @"opaque", comptime rotation, false, i, opaque_faces, transparent_faces, main_block);
    }
}

inline fn addSideFaces(comptime len: usize, mask_start: @Int(.unsigned, len), comptime rotation: FaceRotation, comptime transparent: bool, i: usize, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face), block: Block) void {
    var mask = mask_start;
    const faces = switch (comptime transparent) {
        true => transparent_faces,
        false => opaque_faces,
    };
    while (mask != 0) {
        const j = @ctz(mask);
        mask &= (mask - 1);
        faces.addOneAssumeCapacity().* = .{
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
    }
}

fn meshBlockGrid(allocator: std.mem.Allocator, noalias grid: *const [ChunkSize][ChunkSize][ChunkSize]Block.Tag, noalias neighbor_faces: *const [6]Chunk.Encoding.Face, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) !void {
    for (0..ChunkSize) |x| {
        try opaque_faces.ensureUnusedCapacity(allocator, 6 * ChunkSize * ChunkSize);
        try transparent_faces.ensureUnusedCapacity(allocator, 6 * ChunkSize * ChunkSize);
        @prefetch(&grid[x-1..x+1], .{ .locality = 3, .rw = .read, .cache = .data });
        @prefetch(neighbor_faces, .{ .locality = 3, .rw = .read, .cache = .data });
        @prefetch(opaque_faces.items.ptr[opaque_faces.items.len .. opaque_faces.items.len + 256], .{ .locality = 3, .rw = .write });
        @prefetch(transparent_faces.items.ptr[transparent_faces.items.len .. transparent_faces.items.len + 256], .{ .locality = 3, .rw = .write });

        for (0..ChunkSize) |y| {
            const center_row: [ChunkSize]Block.Tag = grid[x][y];
            inline for (std.enums.values(FaceRotation)) |rotation| {
                const neighbor_face = &neighbor_faces[@intFromEnum(rotation)];
                const neighbor_vec: @Vector(ChunkSize, Block.Tag) = switch (comptime rotation) {
                    .xminus => if (x == 0) getNeighborVec(rotation, neighbor_face, x, y) else grid[x - 1][y],
                    .xplus => if (x == comptime ChunkSize - 1) getNeighborVec(rotation, neighbor_face, x, y) else grid[x + 1][y],
                    .yminus => if (y == 0) getNeighborVec(rotation, neighbor_face, x, y) else grid[x][y - 1],
                    .yplus => if (y == comptime ChunkSize - 1) getNeighborVec(rotation, neighbor_face, x, y) else grid[x][y + 1],
                    .zminus => std.simd.shiftElementsRight(center_row, 1, getNeighborBlockZ(neighbor_face, x, y)),
                    .zplus => std.simd.shiftElementsLeft(center_row, 1, getNeighborBlockZ(neighbor_face, x, y)),
                };
                computeRow(ChunkSize, center_row, neighbor_vec, rotation, @intCast(x), @intCast(y), transparent_faces, opaque_faces);
            }
        }
    }
}

inline fn computeRow(comptime len: usize, center_row: [len]Block.Tag, neighbor_vec: @Vector(len, Block.Tag), comptime rotation: FaceRotation, x: u8, y: u8, noalias transparent_faces: *std.ArrayList(Face), noalias opaque_faces: *std.ArrayList(Face)) void {
    const transparent, const @"opaque" = meshMany(len, center_row, neighbor_vec);
    if (transparent != 0) addGridFaces(len, transparent, rotation, true, center_row, x, y, opaque_faces, transparent_faces);
    if (@"opaque" != 0) addGridFaces(len, @"opaque", rotation, false, center_row, x, y, opaque_faces, transparent_faces);
}

inline fn addGridFaces(comptime len: usize, mask_copy: @Int(.unsigned, len), comptime rotation: FaceRotation, comptime transparent: bool, center_row: [len]Block.Tag, x: u8, y: u8, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) void {
    var mask = mask_copy;
    std.debug.assert(mask != 0);
    const faces_list = switch (comptime transparent) {
        true => transparent_faces,
        false => opaque_faces,
    };
    const face = Face{
        .rotation = rotation,
        .z = undefined,
        .y = @intCast(y),
        .x = @intCast(x),
        .block_type = undefined,
    };
    while (mask != 0) {
        const z = @ctz(mask);
        mask &= (mask - 1);
        faces_list.items.ptr[faces_list.items.len] = face;
        faces_list.items.ptr[faces_list.items.len].z = @intCast(z);
        faces_list.items.ptr[faces_list.items.len].block_type = center_row[z];
        faces_list.items.len += 1;
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

inline fn meshMany(len: usize, one: @Vector(len, Block.Tag), two: @Vector(len, Block.Tag)) struct { @Int(.unsigned, len), @Int(.unsigned, len) } {
    const LenInt = @Int(.unsigned, len);
    const not_same: LenInt = @bitCast(one != two);
    if (not_same == 0) return .{ 0, 0 };
    const ones_visible: LenInt = @bitCast(Block.isVisibleVector(len, one));
    const twos_transparent: LenInt = @bitCast(Block.isTransparentVector(len, two));
    const valid_face = not_same & ones_visible & twos_transparent;
    const ones_transparent: LenInt = @bitCast(Block.isTransparentVector(len, one));

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
            const v_one: @Vector(1, Block.Tag) = @splat(@intFromEnum(one));
            const v_two: @Vector(1, Block.Tag) = @splat(@intFromEnum(two));
            const transparent, const @"opaque" = meshMany(1, v_one, v_two);
            const actual: MeshResult = if (@"opaque" == 0 and transparent == 0) .none else if (transparent == 1) .transparent else .@"opaque";
            try std.testing.expectEqual(expected, actual);
        }
    }
}

test "MeshBehavior - Uniform Air Chunk" {
    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const maingrid: Chunk.Encoding = .{ .uniform = .air };
    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    try mesh(std.testing.allocator, maingrid, &neighbor_faces, &opaque_faces, &transparent_faces);

    try std.testing.expectEqual(@as(usize, 0), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);
}

test "MeshBehavior - Single Isolated Block" {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));

    grid[1][1][1] = .stone;

    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    try mesh(std.testing.allocator, .{ .grid = &grid }, &neighbor_faces, &opaque_faces, &transparent_faces);

    try std.testing.expectEqual(@as(usize, 6), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);

    for (opaque_faces.items) |face| {
        try std.testing.expect(face.x == 1);
        try std.testing.expect(face.y == 1);
        try std.testing.expect(face.z == 1);
        try std.testing.expect(face.block_type == @intFromEnum(Block.stone));
    }
}

test "MeshBehavior - Adjacent grid Culling" {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));

    grid[1][1][1] = .stone;
    grid[2][1][1] = .stone;

    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    try mesh(std.testing.allocator, .{ .grid = &grid }, &neighbor_faces, &opaque_faces, &transparent_faces);

    try std.testing.expectEqual(@as(usize, 10), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);
}

test "MeshBehavior - Completely Enclosed Block" {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));

    // Create a 3x3x3 solid cube of stone
    for (1..4) |x| {
        for (1..4) |y| {
            for (1..4) |z| {
                grid[x][y][z] = .stone;
            }
        }
    }

    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    try mesh(std.testing.allocator, .{ .grid = &grid }, &neighbor_faces, &opaque_faces, &transparent_faces);

    // A 3x3x3 cube has 27 blocks. The center block (2,2,2) is completely enclosed.
    // The surface area is exactly 3 * 3 blocks per face * 6 faces = 54 faces.
    try std.testing.expectEqual(@as(usize, 54), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);
}

test "MeshBehavior - Chunk Boundary Culling" {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));

    // Place a single block on the X=0 boundary
    grid[0][1][1] = .stone;

    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    // Make the adjacent chunk on the -X axis completely solid stone
    var neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });
    neighbor_faces[@intFromEnum(FaceRotation.xminus)] = .{ .uniform = .stone };

    try mesh(std.testing.allocator, .{ .grid = &grid }, &neighbor_faces, &opaque_faces, &transparent_faces);

    // A single block has 6 faces. The xminus face should be culled by the neighbor chunk.
    try std.testing.expectEqual(@as(usize, 5), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);
}

test "MeshBehavior - Uniform Solid Chunk" {
    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const maingrid: Chunk.Encoding = .{ .uniform = .stone };
    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    try mesh(std.testing.allocator, maingrid, &neighbor_faces, &opaque_faces, &transparent_faces);

    // A fully solid chunk exposed to air on all sides.
    // 6 faces * (ChunkSize * ChunkSize) blocks per face
    const expected_faces = 6 * (ChunkSize * ChunkSize);
    try std.testing.expectEqual(expected_faces, opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);
}

test "MeshBehavior - Uniform Solid Chunk Culled By Neighbor" {
    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const maingrid: Chunk.Encoding = .{ .uniform = .stone };
    var neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    // Solid chunk directly below this one (culling the yminus face)
    neighbor_faces[@intFromEnum(FaceRotation.yminus)] = .{ .uniform = .stone };

    try mesh(std.testing.allocator, maingrid, &neighbor_faces, &opaque_faces, &transparent_faces);

    // 5 exposed faces (yminus is culled)
    const expected_faces = 5 * (ChunkSize * ChunkSize);
    try std.testing.expectEqual(expected_faces, opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);
}

test "MeshBehavior - Transparent Block Routing" {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));

    // Place an opaque block and a transparent block
    grid[1][1][1] = .stone;
    grid[3][3][3] = .water;

    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    try mesh(std.testing.allocator, .{ .grid = &grid }, &neighbor_faces, &opaque_faces, &transparent_faces);

    // Stone generates 6 opaque faces, glass generates 6 transparent faces
    try std.testing.expectEqual(@as(usize, 6), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 6), transparent_faces.items.len);
}

test "MeshBehavior - Transparent to Opaque Interaction" {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));

    // Place stone at X=1, glass at X=2
    grid[1][1][1] = .stone;
    grid[2][1][1] = .water;

    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    try mesh(std.testing.allocator, .{ .grid = &grid }, &neighbor_faces, &opaque_faces, &transparent_faces);

    // Stone has 6 faces. The xplus face touches glass.
    // Because glass is transparent, the stone xplus face MUST still render.
    try std.testing.expectEqual(@as(usize, 6), opaque_faces.items.len);

    // Glass has 6 faces. The xminus face touches stone.
    // Because stone is opaque, the glass xminus face MUST be culled.
    try std.testing.expectEqual(@as(usize, 5), transparent_faces.items.len);
}

test "MeshBehavior - Grid to Grid Boundary Alignment" {
    var main_grid: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));
    // Main chunk has a block right on the X- boundary at (0, 5, 5)
    main_grid[0][5][5] = .stone;

    // Create the 2D boundary face for the neighbor
    var neighbor_face_grid: [ChunkSize][ChunkSize]Block = @splat(@splat(.air));
    // Since it's a 2D face, we just set Y=5, Z=5
    neighbor_face_grid[5][5] = .stone;

    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    var neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });
    neighbor_faces[@intFromEnum(FaceRotation.xminus)] = .{ .grid = neighbor_face_grid };

    try mesh(std.testing.allocator, .{ .grid = &main_grid }, &neighbor_faces, &opaque_faces, &transparent_faces);

    // The two blocks touch perfectly across the chunk boundary.
    // The xminus face of the main grid block should be culled.
    try std.testing.expectEqual(@as(usize, 5), opaque_faces.items.len);
}

test "MeshBehavior - Exact Rotation Generation" {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));
    grid[1][1][1] = .stone;

    var opaque_faces = std.ArrayList(Face).empty;
    defer opaque_faces.deinit(std.testing.allocator);
    var transparent_faces = std.ArrayList(Face).empty;
    defer transparent_faces.deinit(std.testing.allocator);

    const neighbor_faces: [6]Chunk.Encoding.Face = @splat(.{ .uniform = .air });

    try mesh(std.testing.allocator, .{ .grid = &grid }, &neighbor_faces, &opaque_faces, &transparent_faces);

    try std.testing.expectEqual(@as(usize, 6), opaque_faces.items.len);

    var seen_rotations: [6]bool = @splat(false);
    for (opaque_faces.items) |face| {
        seen_rotations[@intFromEnum(face.rotation)] = true;
    }

    // Ensure every single rotation enum was generated exactly once
    for (seen_rotations, 0..) |seen, i| {
        if (!seen) {
            std.debug.print("Failed to generate face rotation: {s}\n", .{@tagName(@as(FaceRotation, @enumFromInt(i)))});
            return error.MissingFaceRotation;
        }
    }
}

test "MeshBenchmark" {
    for (0..3) |i| {
        var grid: [ChunkSize][ChunkSize][ChunkSize]Block = @splat(@splat(@splat(.air)));
        if (i == 1) {
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
        }
        var alist: std.ArrayList(Face) = try .initCapacity(std.testing.allocator, 65536);
        defer alist.deinit(std.testing.allocator);

        const test_amount = if (@import("builtin").mode == .Debug) 100 else 100000;
        const st = std.Io.Timestamp.now(std.testing.io, .awake);

        for (0..test_amount) |_| {
            try mesh(std.testing.allocator, if (i == 0) .{ .uniform = .leaves } else .{ .grid = &grid }, &@splat(Chunk.Encoding.Face{ .grid = @splat(@splat(.water)) }), &alist, &alist);
            alist.clearRetainingCapacity();
        }

        const et = std.Io.Timestamp.now(std.testing.io, .awake);
        const dt = st.durationTo(et);
        const us_per_mesh = (@as(f64, @floatFromInt(dt.toMicroseconds())) / test_amount);
        std.log.warn("Mesh {s} benchmark: completed with an avg time of {d} us per mesh, {d} ns per block", .{ if (i == 0) "uniform" else if(i == 1) "grid" else "grid air", us_per_mesh, (us_per_mesh * std.time.ns_per_us) / (ChunkSize * ChunkSize * ChunkSize) });
    }
}

test "FuzzMesh" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(_: void, smith: *std.testing.Smith) !void {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
    const maingrid: Chunk.Encoding = .fuzzerMakeEncoding(&grid, smith);
    const neighbor_faces: [6]Chunk.Encoding.Face = smith.value([6]Chunk.Encoding.Face);

    var alist: std.ArrayList(Face) = .empty;
    defer alist.deinit(std.testing.allocator);

    try Mesher.mesh(std.testing.allocator, maingrid, &neighbor_faces, &alist, &alist);
}
