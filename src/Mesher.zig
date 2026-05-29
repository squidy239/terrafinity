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
    try opaque_faces.ensureUnusedCapacity(allocator, ChunkSize * ChunkSize);
    try transparent_faces.ensureUnusedCapacity(allocator, ChunkSize * ChunkSize);
    const one_uniform_vec: @Vector(ChunkSize, Block.Tag) = @splat(@intFromEnum(main_block));
    const two_uniform_vec: @Vector(ChunkSize, Block.Tag) = if (neighbor_face.* == .uniform) @splat(@intFromEnum(neighbor_face.uniform)) else undefined;

    for (0..ChunkSize) |i| {
        const two_vec: @Vector(ChunkSize, Block.Tag) = switch (neighbor_face.*) {
            .grid => |*grid| @bitCast(grid[i]),
            .uniform => two_uniform_vec,
        };

        const transparent_vec, const opaque_vec = meshMany(ChunkSize, one_uniform_vec, two_vec);
        const transparent: @Int(.unsigned, ChunkSize) = @bitCast(transparent_vec);
        const @"opaque": @Int(.unsigned, ChunkSize) = @bitCast(opaque_vec);
        addUniformFaces(ChunkSize, transparent, comptime rotation, true, i, opaque_faces, transparent_faces, main_block);
        addUniformFaces(ChunkSize, @"opaque", comptime rotation, false, i, opaque_faces, transparent_faces, main_block);
    }
}

inline fn addUniformFaces(comptime len: usize, mask_start: @Int(.unsigned, len), comptime rotation: FaceRotation, comptime transparent: bool, i: usize, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face), block: Block) void {
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
    @setEvalBranchQuota(20000);

    comptime {
        if (64 % ChunkSize != 0) @compileError("ChunkSize must be a divisor of 64 (e.g., 16, 32, 64)");
    }

    const rows_per_batch = 64 / ChunkSize;

    for (0..ChunkSize) |x| {
        try opaque_faces.ensureUnusedCapacity(allocator, 6 * ChunkSize * ChunkSize);
        try transparent_faces.ensureUnusedCapacity(allocator, 6 * ChunkSize * ChunkSize);
        @prefetch(&grid[x], .{ .locality = 3, .rw = .read, .cache = .data });
        @prefetch(neighbor_faces, .{ .locality = 3, .rw = .read, .cache = .data });
        @prefetch(opaque_faces.items.ptr[opaque_faces.items.len .. opaque_faces.items.len + 1024], .{ .locality = 3, .rw = .write });
        @prefetch(transparent_faces.items.ptr[transparent_faces.items.len .. transparent_faces.items.len + 512], .{ .locality = 3, .rw = .write });

        var y: usize = 0;
        while (y < ChunkSize) : (y += rows_per_batch) {
            inline for (std.enums.values(FaceRotation)) |rotation| {
                var center_virtual: [64]Block.Tag = @bitCast(grid[x][y .. y + rows_per_batch][0..2].*);
                var neighbor_virtual: [64]Block.Tag = undefined;
                const small: bool = true;
                if (small) {
                    inline for (0..rows_per_batch) |r| {
                        const local_y = y + r;
                        const offset = r * ChunkSize;

                        neighbor_virtual[offset .. offset + ChunkSize].* = switch (comptime rotation) {
                            .xminus => if (x == 0) getNeighborVec(rotation, &neighbor_faces[@intFromEnum(rotation)], x, local_y) else @bitCast(grid[x - 1][local_y]),
                            .xplus => if (x == comptime ChunkSize - 1) getNeighborVec(rotation, &neighbor_faces[@intFromEnum(rotation)], x, local_y) else @bitCast(grid[x + 1][local_y]),
                            .yminus => if (local_y == 0) getNeighborVec(rotation, &neighbor_faces[@intFromEnum(rotation)], x, local_y) else @bitCast(grid[x][local_y - 1]),
                            .yplus => if (local_y == comptime ChunkSize - 1) getNeighborVec(rotation, &neighbor_faces[@intFromEnum(rotation)], x, local_y) else @bitCast(grid[x][local_y + 1]),
                            .zminus => std.simd.shiftElementsRight(center_virtual[offset .. offset + ChunkSize].*, 1, getNeighborBlockZ(&neighbor_faces[@intFromEnum(rotation)], x, local_y)),
                            .zplus => std.simd.shiftElementsLeft(center_virtual[offset .. offset + ChunkSize].*, 1, getNeighborBlockZ(&neighbor_faces[@intFromEnum(rotation)], x, local_y)),
                        };
                    }
                }
                computeRow64(center_virtual, neighbor_virtual, rotation, @intCast(x), @intCast(y), transparent_faces, opaque_faces);
            }
        }
    }
}

inline fn computeRow64(center_virtual: [64]Block.Tag, neighbor_virtual: @Vector(64, Block.Tag), comptime rotation: FaceRotation, x: u8, y_base: u8, noalias transparent_faces: *std.ArrayList(Face), noalias opaque_faces: *std.ArrayList(Face)) void {
    const transparent_vec, const opaque_vec = meshMany(64, center_virtual, neighbor_virtual);
    const transparent: u64 = @bitCast(transparent_vec);
    const @"opaque": u64 = @bitCast(opaque_vec);
    if (transparent != 0) addGridFaces64(transparent, rotation, true, center_virtual, x, y_base, opaque_faces, transparent_faces);
    if (@"opaque" != 0) addGridFaces64(@"opaque", rotation, false, center_virtual, x, y_base, opaque_faces, transparent_faces);
}

inline fn addGridFaces64(mask_copy: u64, comptime rotation: FaceRotation, comptime transparent: bool, center_virtual: [64]Block.Tag, x: u8, y_base: u8, noalias opaque_faces: *std.ArrayList(Face), noalias transparent_faces: *std.ArrayList(Face)) void {
    var mask = mask_copy;
    std.debug.assert(mask != 0);
    const faces_list = switch (comptime transparent) {
        true => transparent_faces,
        false => opaque_faces,
    };
    const face = Face{
        .rotation = rotation,
        .z = undefined,
        .y = undefined,
        .x = @intCast(x),
        .block_type = undefined,
    };
    while (mask != 0) {
        const bit_idx = @ctz(mask);
        mask &= (mask - 1);

        faces_list.items.ptr[faces_list.items.len] = face;
        faces_list.items.ptr[faces_list.items.len].z = @intCast(bit_idx % ChunkSize);
        faces_list.items.ptr[faces_list.items.len].y = @intCast(y_base + (bit_idx / ChunkSize));
        faces_list.items.ptr[faces_list.items.len].block_type = center_virtual[bit_idx];
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

inline fn meshMany(len: usize, one: @Vector(len, Block.Tag), two: @Vector(len, Block.Tag)) struct { @Vector(len, bool), @Vector(len, bool) } {
    const false_mask: @Vector(len, bool) = comptime @splat(false);
    const is_same = one == two;
    if (@reduce(.And, is_same)) return .{ false_mask, false_mask };
    const ones_invisible = !Block.isVisibleVector(len, one);
    const twos_opaque = !Block.isTransparentVector(len, two);
    const ones_transparent = Block.isTransparentVector(len, one);
    const abort_mask = is_same | ones_invisible | twos_opaque;
    return .{
        @select(bool, abort_mask, false_mask, ones_transparent),
        @select(bool, abort_mask, false_mask, !ones_transparent),
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
            const actual: MeshResult = if (!@"opaque"[0] and !transparent[0]) .none else if (transparent[0]) .transparent else .@"opaque";
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

test "MeshBenchmark" {
    for (0..2) |i| {
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
            try mesh(std.testing.allocator, .{ .grid = &grid }, &@splat(Chunk.Encoding.Face{ .uniform = .air }), &alist, &alist);
            alist.clearRetainingCapacity();
        }

        const et = std.Io.Timestamp.now(std.testing.io, .awake);
        const dt = st.durationTo(et);
        const us_per_mesh = (@as(f64, @floatFromInt(dt.toMicroseconds())) / test_amount);
        std.log.warn("Mesh {s} benchmark: completed with an avg time of {d} us per mesh, {d} ns per block", .{ if (i == 0) "air" else "grid", us_per_mesh, (us_per_mesh * std.time.ns_per_us) / (ChunkSize * ChunkSize * ChunkSize) });
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
