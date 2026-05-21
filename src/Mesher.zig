const std = @import("std");
const tracy = @import("tracy");

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
    BlockType: Block,
    _: u29 = undefined,
};

///neighbor_faces format: x+,x-,y+,y-,z+,z-, caller handles refs
pub fn mesh(allocator: std.mem.Allocator, mainblocks: Chunk.Encoding, neighbor_faces: *const [6]Chunk.Encoding.Face, opaque_faces: *std.ArrayList(Face), transparent_faces: *std.ArrayList(Face)) !void {
    const mdc = tracy.Zone.begin(.{ .src = @src() });
    defer mdc.end();
    inline for (std.enums.values(FaceRotation)) |rotation| {
        try meshChunkFace(allocator, mainblocks.extractFace(rotation), neighbor_faces[@intFromEnum(rotation)], rotation, opaque_faces, transparent_faces);
    }
    switch (mainblocks) {
        .one_block => {}, // Done meshing, blocks wont make mesh if they are the same type
        .grid => |grid| try meshBlockGrid(allocator, grid, opaque_faces, transparent_faces),
    }
}

fn meshChunkFace(allocator: std.mem.Allocator, one: Chunk.Encoding.Face, two: Chunk.Encoding.Face, comptime rotation: Chunk.Encoding.FaceRotation, opaque_faces: *std.ArrayList(Face), transparent_faces: *std.ArrayList(Face)) !void {
    if (one == .one_block and two == .one_block and one.one_block == two.one_block) return;
    const grid_one: [ChunkSize][ChunkSize]Block = switch (one) {
        .blocks => |grid| grid,
        .one_block => |block| @splat(@splat(block)),
    };
    const grid_two: [ChunkSize][ChunkSize]Block = switch (two) {
        .blocks => |grid| grid,
        .one_block => |block| @splat(@splat(block)),
    };
    try meshChunkFaceGrid(allocator, &grid_one, &grid_two, rotation, opaque_faces, transparent_faces);
}

fn meshChunkFaceGrid(allocator: std.mem.Allocator, grid_one: *const [ChunkSize][ChunkSize]Block, grid_two: *const [ChunkSize][ChunkSize]Block, comptime rotation: Chunk.Encoding.FaceRotation, opaque_faces: *std.ArrayList(Face), transparent_faces: *std.ArrayList(Face)) !void {
    for (grid_one, grid_two, 0..) |row_one, row_two, i| {
        for (row_one, row_two, 0..) |one, two, j| {
            const transparent = meshOne(one, two) orelse continue;
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
                .BlockType = one,
            };
            if (transparent) {
                try transparent_faces.append(allocator, face);
            } else {
                try opaque_faces.append(allocator, face);
            }
        }
    }
}

fn meshBlockGrid(allocator: std.mem.Allocator, grid: *const [ChunkSize][ChunkSize][ChunkSize]Block, opaque_faces: *std.ArrayList(Face), transparent_faces: *std.ArrayList(Face)) !void {
    const ms = tracy.Zone.begin(.{ .src = @src() });
    defer ms.end();
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |y| {
            @setEvalBranchQuota(100000);
            inline for (0..ChunkSize) |z| {
                const block = grid[x][y][z];
                if (block.isVisible()) {
                    inline for (std.enums.values(FaceRotation)) |rotation| {
                        const at_boundary = switch (comptime rotation) {
                            .xplus => x == ChunkSize - 1,
                            .xminus => x == 0,
                            .yplus => y == ChunkSize - 1,
                            .yminus => y == 0,
                            .zplus => z == ChunkSize - 1,
                            .zminus => z == 0,
                        };
                        if (!at_boundary) {
                            const neighbor = switch (comptime rotation) {
                                .xminus => grid[x - 1][y][z],
                                .xplus => grid[x + 1][y][z],
                                .yminus => grid[x][y - 1][z],
                                .yplus => grid[x][y + 1][z],
                                .zminus => grid[x][y][z - 1],
                                .zplus => grid[x][y][z + 1],
                            };

                            const result = meshOne(block, neighbor);
                            if (result) |transparent| {
                                const face = Face{
                                    .BlockType = block,
                                    .rotation = rotation,
                                    .x = @intCast(x),
                                    .y = @intCast(y),
                                    .z = @intCast(z),
                                };
                                if (transparent) {
                                    try transparent_faces.append(allocator, face);
                                } else {
                                    try opaque_faces.append(allocator, face);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

///returns false if the face is opaque, true if transparent, null if it should not be meshed
inline fn meshOne(one: Block, two: Block) ?bool {
    if (one == two or !one.isVisible() or !two.isTransparent()) return null;
    return one.isTransparent();
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
    var alist: std.ArrayList(Face) = .empty;
    defer alist.deinit(std.testing.allocator);
    const test_amount = 1000;
    const st = std.Io.Timestamp.now(std.testing.io, .awake);
    for (0..test_amount) |_| {
        try mesh(std.testing.allocator, .{ .grid = &blocks }, &@splat(Chunk.Encoding.Face{ .one_block = .air }), &alist, &alist);
        alist.clearRetainingCapacity();
    }
    const et = std.Io.Timestamp.now(std.testing.io, .awake);
    const dt = st.durationTo(et);
    std.log.info("Mesh benchmark: {d} meshes in {d} ms", .{ test_amount, dt.toMilliseconds() });
    std.log.info("completed with an avg time of {d} us per mesh", .{(@as(f64, @floatFromInt(dt.toMicroseconds())) / test_amount)});
}

test "FuzzMesh" {
    if (true) return error.SkipZigTest;
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
