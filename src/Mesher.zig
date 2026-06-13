const std = @import("std");

const Block = @import("world/Block.zig").Block;
const Chunk = @import("world/Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
pub const FaceRotation = Chunk.Encoding.FaceRotation;
const ChunkPos = @import("world/World.zig").ChunkPos;

const Mesher = @This();

pub const Face = packed struct(u64) {
    const CoordInChunk = Chunk.Int;
    block_type: Block.Tag,
    zlength: CoordInChunk = 0, // 0 = 1 in length, etc
    z: CoordInChunk,
    y: CoordInChunk,
    x: CoordInChunk,
    rotation: FaceRotation,
    _: @Int(.unsigned, 64 - (4 * @bitSizeOf(CoordInChunk) + @bitSizeOf(FaceRotation) + @bitSizeOf(Block.Tag))) = undefined,
};

/// Entry point. Routes to 0-allocation uniform meshing or fully vectorized grid meshing.
/// neighbor_faces format: x+,x-,y+,y-,z+,z-, caller handles refs
pub fn mesh(allocator: std.mem.Allocator, maingrid: Chunk.Encoding, noalias neighbor_faces: *const [6]Chunk.Encoding.Face, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) !void {
    switch (maingrid) {
        .uniform => |main_block| {
            inline for (std.enums.values(FaceRotation)) |rotation| {
                try meshUniformChunkFace(allocator, main_block, &neighbor_faces[@intFromEnum(rotation)], rotation, opaque_faces, transparent_faces);
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

fn meshUniformChunkFace(allocator: std.mem.Allocator, main_block: Block, neighbor_face: *const Chunk.Encoding.Face, comptime rotation: FaceRotation, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) !void {
    if (neighbor_face.* == .uniform and meshOne(main_block, neighbor_face.uniform) == .none) return;
    const one_visible = main_block.isVisible();
    if (!one_visible) return;
    try opaque_faces.ensureUnusedCapacity(allocator, ChunkSize * ChunkSize);
    try transparent_faces.ensureUnusedCapacity(allocator, ChunkSize * ChunkSize);
    const ones_visible: @Int(.unsigned, ChunkSize) = @bitCast(@as(@Vector(ChunkSize, bool), @splat(one_visible)));
    const one_uniform_vec: @Vector(ChunkSize, Block.Tag) = @splat(@intFromEnum(main_block));
    const ones_transparent: @Int(.unsigned, ChunkSize) = @bitCast(Block.isTransparentVector(ChunkSize, one_uniform_vec));

    const two_uniform_vec: @Vector(ChunkSize, Block.Tag) = if (neighbor_face.* == .uniform) @splat(@intFromEnum(neighbor_face.uniform)) else undefined;

    for (0..ChunkSize) |i| {
        const two_vec: @Vector(ChunkSize, Block.Tag) = switch (neighbor_face.*) {
            .grid => |*grid| @bitCast(grid[i]),
            .uniform => two_uniform_vec,
        };

        const transparent, const @"opaque" = meshMany(ChunkSize, one_uniform_vec, ones_visible, ones_transparent, two_vec);
        if (transparent != 0) addSideFaces(ChunkSize, transparent, comptime rotation, true, @intCast(i), opaque_faces, transparent_faces, main_block);
        if (@"opaque" != 0) addSideFaces(ChunkSize, @"opaque", comptime rotation, false, @intCast(i), opaque_faces, transparent_faces, main_block);
    }
}

inline fn addSideFaces(comptime len: usize, mask_start: @Int(.unsigned, len), comptime rotation: FaceRotation, comptime transparent: bool, i: u8, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face), block: Block) void {
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
    var x: u8 = 0;
    while (x < ChunkSize - 1) : (x += 1) {
        try opaque_faces.ensureUnusedCapacity(allocator, 6 * ChunkSize * ChunkSize);
        try transparent_faces.ensureUnusedCapacity(allocator, 6 * ChunkSize * ChunkSize);

        const zminus_neighbors: [ChunkSize]Block.Tag = switch (neighbor_faces[@intFromEnum(FaceRotation.zminus)]) {
            .uniform => |block| @splat(@intFromEnum(block)),
            .grid => |*g| @bitCast(g[x]),
        };

        const zplus_neighbors: [ChunkSize]Block.Tag = switch (neighbor_faces[@intFromEnum(FaceRotation.zplus)]) {
            .uniform => |block| @splat(@intFromEnum(block)),
            .grid => |*g| @bitCast(g[x]),
        };

        var y: u8 = 0;
        while (y < ChunkSize - 1) : (y += 1) {
            const center_row: @Vector(ChunkSize, Block.Tag) = @bitCast(grid[x][y]); // bitCast is MUCH faster than coerceing for some reason
            const ones_visible: @Int(.unsigned, ChunkSize) = @bitCast(Block.isVisibleVector(ChunkSize, center_row));
            if (ones_visible == 0) continue;
            const ones_transparent: @Int(.unsigned, ChunkSize) = @bitCast(Block.isTransparentVector(ChunkSize, center_row));
            const neighbor_vecs: [std.enums.values(FaceRotation).len]@Vector(ChunkSize, Block.Tag) = .{
                if (x == comptime ChunkSize - 1) getNeighborVec(.xplus, &neighbor_faces[@intFromEnum(FaceRotation.xplus)], x, y) else grid[x + 1][y],
                if (x == 0) getNeighborVec(.xminus, &neighbor_faces[@intFromEnum(FaceRotation.xminus)], x, y) else grid[x - 1][y],
                if (y == comptime ChunkSize - 1) getNeighborVec(.yplus, &neighbor_faces[@intFromEnum(FaceRotation.yplus)], x, y) else grid[x][y + 1],
                if (y == 0) getNeighborVec(.yminus, &neighbor_faces[@intFromEnum(FaceRotation.yminus)], x, y) else grid[x][y - 1],
                sh: {
                    comptime var mask = std.simd.iota(i32, ChunkSize) + @as(@Vector(ChunkSize, i32), @splat(1));
                    mask[ChunkSize - 1] = 0;
                    var t = @shuffle(Block.Tag, center_row, undefined, mask);
                    t[comptime ChunkSize - 1] = zplus_neighbors[y];
                    break :sh t;
                },
                sh: {
                    comptime var mask = std.simd.iota(i32, ChunkSize) - @as(@Vector(ChunkSize, i32), @splat(1));
                    mask[0] = 0;
                    var t = @shuffle(Block.Tag, center_row, undefined, mask);
                    t[comptime 0] = zminus_neighbors[y];
                    break :sh t;
                },
            };
            inline for (neighbor_vecs, std.enums.values(FaceRotation)) |neighbor_vec, rotation| {
                var transparent, var @"opaque" = meshMany(ChunkSize, center_row, ones_visible, ones_transparent, neighbor_vec);
                if (@"opaque" != 0) addGridFaces(ChunkSize, &@"opaque", rotation, false, &grid[x][y], @intCast(x), @intCast(y), opaque_faces, transparent_faces);
                if (transparent != 0) addGridFaces(ChunkSize, &transparent, rotation, true, &grid[x][y], @intCast(x), @intCast(y), opaque_faces, transparent_faces);
            }
        }
    }
}

fn addGridFaces(comptime len: usize, noalias mask: *@Int(.unsigned, len), comptime rotation: FaceRotation, comptime transparent: bool, noalias center_row: *const [len]Block.Tag, x: Face.CoordInChunk, y: Face.CoordInChunk, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) void {
    const faces_list = switch (comptime transparent) {
        true => transparent_faces,
        false => opaque_faces,
    };
    const face = Face{
        .z = undefined,
        .rotation = rotation,
        .y = y,
        .x = x,
        .block_type = undefined,
    };
    const greedyz = comptime switch (rotation) {
        .zminus, .zplus => false,
        else => true,
    };

    var last: Face = face;
    var last_exists: bool = false;
    var last_zlen: u8 = undefined;
    while (mask.* != 0) : (mask.* &= (mask.* - 1)) {
        const z: Face.CoordInChunk = @intCast(@ctz(mask.*));
        const block = center_row[z];
        if (last_exists) {
            if (comptime greedyz) if (last.block_type == block) {
                @branchHint(.unpredictable);
                last_zlen += 1;
                continue;
            };
            last.zlength = @intCast(last_zlen);
            faces_list.appendAssumeCapacity(last);
        }
        last_zlen = 0;
        last_exists = true;
        last.block_type = block;
        last.z = z;
    }
    std.debug.assert(last_exists);
    last.zlength = @intCast(last_zlen);
    faces_list.appendAssumeCapacity(last);
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
            const v_one: @Vector(1, Block.Tag) = @splat(@intFromEnum(one));
            const v_two: @Vector(1, Block.Tag) = @splat(@intFromEnum(two));
            const ones_visible: @Int(.unsigned, 1) = @bitCast(Block.isVisibleVector(1, v_one));
            const ones_transparent: @Int(.unsigned, 1) = @bitCast(Block.isTransparentVector(1, v_one));
            const transparent, const @"opaque" = meshMany(1, v_one, ones_visible, ones_transparent, v_two);
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

    for (opaque_faces.items) |face| {
        try std.testing.expect(face.x == 1);
        try std.testing.expect(face.y == 1);
        try std.testing.expect(face.z == 1);
        try std.testing.expect(face.block_type == @intFromEnum(Block.stone));
    }
}

test "MeshBehavior - Adjacent grid Culling" {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));

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
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));

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
    // It becomes 30 with z axis greedy meshing
    try std.testing.expectEqual(@as(usize, 30), opaque_faces.items.len);
    try std.testing.expectEqual(@as(usize, 0), transparent_faces.items.len);
}

test "MeshBehavior - Chunk Boundary Culling" {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));

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
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));

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
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));

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
    var main_grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));
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
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));
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
    inline for (0..4) |i| {
        var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = @splat(@splat(@splat(.air)));
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
        if (i == 3) {
            var prng = std.Random.DefaultPrng.init(0);
            for (&grid) |*plane| {
                for (plane) |*row| {
                    for (row) |*block| {
                        block.* = prng.random().enumValue(Block);
                    }
                }
            }
        }
        var alist: std.ArrayList(Face) = try .initCapacity(std.testing.allocator, 65536);
        defer alist.deinit(std.testing.allocator);

        const test_amount = if (@import("builtin").mode == .Debug) 100 else (if (i == 3) 10000 else 500000);
        const st = std.Io.Timestamp.now(std.testing.io, .awake);

        for (0..test_amount) |_| {
            try mesh(std.testing.allocator, if (i == 0) .{ .uniform = .leaves } else .{ .grid = &grid }, &@splat(Chunk.Encoding.Face{ .grid = @splat(@splat(.water)) }), &alist, &alist);
            alist.clearRetainingCapacity();
        }

        const et = std.Io.Timestamp.now(std.testing.io, .awake);
        const dt = st.durationTo(et);
        const us_per_mesh = (@as(f64, @floatFromInt(dt.toMicroseconds())) / test_amount);
        std.log.warn("Mesh {s} benchmark: completed with an avg time of {d} us per mesh, {d} ns per block", .{ if (i == 0) "uniform" else if (i == 1) "grid" else if (i == 2) "grid air" else "random", us_per_mesh, (us_per_mesh * std.time.ns_per_us) / (ChunkSize * ChunkSize * ChunkSize) });
    }
}

test "FuzzMesh" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(_: void, smith: *std.testing.Smith) !void {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = undefined;
    const maingrid: Chunk.Encoding = .fuzzerMakeEncoding(&grid, smith);
    const neighbor_faces: [6]Chunk.Encoding.Face = smith.value([6]Chunk.Encoding.Face);

    var alist: std.ArrayList(Face) = .empty;
    defer alist.deinit(std.testing.allocator);

    try Mesher.mesh(std.testing.allocator, maingrid, &neighbor_faces, &alist, &alist);
}
