const std = @import("std");
const tracy = @import("tracy");

const Block = @import("world/Block.zig").Block;
const Chunk = @import("world/Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
pub const FaceRotation = Chunk.Encoding.FaceRotation;
const ChunkPos = @import("world/World.zig").ChunkPos;

const Mesher = @This();
pub const Face = packed struct(u64) {
    x: u5,
    y: u5,
    z: u5,
    rot: FaceRotation,
    isGreedy: bool = false,
    height: i6 = 1,
    width: i6 = 1,
    BlockType: Block,
    _: u16 = undefined,
};

///neighbor_faces format: x+,x-,y+,y-,z+,z-, caller handles refs
pub fn mesh(allocator: std.mem.Allocator, mainblocks: Chunk.Encoding, neighbor_faces: *const [6]Chunk.Encoding.Face, opaque_faces: *std.ArrayList(Face), transparent_faces: *std.ArrayList(Face)) !void {
    const mdc = tracy.Zone.begin(.{ .src = @src() });
    defer mdc.end();
    if (shouldSkip(neighbor_faces, mainblocks)) return;
    inline for (0..6) |i| {
        try meshChunkFace(allocator, mainblocks.extractFace(@enumFromInt(i)), neighbor_faces[i], @enumFromInt(i), opaque_faces, transparent_faces);
    }
    switch (mainblocks) {
        .one_block => {}, // Done meshing, blocks wont make mesh if they are the same type
        .grid => |grid| try meshBlockGrid(allocator, grid, opaque_faces, transparent_faces),
    }
}

fn shouldSkip(neighbor_faces: *const [6]Chunk.Encoding.Face, mainblocks: Chunk.Encoding) bool {
    if (mainblocks != .one_block or mainblocks.one_block.isVisible()) return false;
    for (neighbor_faces) |face| {
        if (face != .one_block or face.one_block.isVisible()) return false;
    }
    return true;
}

fn meshChunkFace(allocator: std.mem.Allocator, one: Chunk.Encoding.Face, two: Chunk.Encoding.Face, comptime rotation: Chunk.Encoding.FaceRotation, opaque_faces: *std.ArrayList(Face), transparent_faces: *std.ArrayList(Face)) !void {
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
            const result = meshOne(one, two);
            if (result) |transparent| {
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
                    .rot = comptime rotation,
                    .isGreedy = false,
                    .height = 1,
                    .width = 1,
                    .BlockType = one,
                };
                if (transparent) {
                    std.debug.assert(one.isTransparent());
                    try transparent_faces.append(allocator, face);
                } else {
                    std.debug.assert(!one.isTransparent());
                    try opaque_faces.append(allocator, face);
                }
            }
        }
    }
}

fn meshBlockGrid(allocator: std.mem.Allocator, grid: *const [ChunkSize][ChunkSize][ChunkSize]Block, opaque_faces: *std.ArrayList(Face), transparent_faces: *std.ArrayList(Face)) !void {
    const ms = tracy.Zone.begin(.{ .src = @src() });
    defer ms.end();
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                const block = grid[x][y][z];
                if (!block.isVisible()) continue;

                inline for (0..6) |i| {
                    var c: bool = false;
                    if (i == 0 and x == ChunkSize - 1) c = true;
                    if (i == 1 and x == 0) c = true;
                    if (i == 2 and y == ChunkSize - 1) c = true;
                    if (i == 3 and y == 0) c = true;
                    if (i == 4 and z == ChunkSize - 1) c = true;
                    if (i == 5 and z == 0) c = true;
                    if (!c) {
                        const neighbor = switch (comptime i) {
                            0 => grid[x + 1][y][z],
                            1 => grid[x - 1][y][z],
                            2 => grid[x][y + 1][z],
                            3 => grid[x][y - 1][z],
                            4 => grid[x][y][z + 1],
                            5 => grid[x][y][z - 1],
                            else => unreachable,
                        };
                        const result = meshOne(block, neighbor);
                        if (result) |transparent| {
                            const face = Face{
                                .BlockType = block,
                                .rot = @enumFromInt(i),
                                .x = @intCast(x),
                                .y = @intCast(y),
                                .z = @intCast(z),
                            };
                            if (transparent) {
                                std.debug.assert(block.isTransparent());
                                try transparent_faces.append(allocator, face);
                            } else {
                                std.debug.assert(!block.isTransparent());
                                try opaque_faces.append(allocator, face);
                            }
                        }
                    }
                }
            }
        }
    }
}

///returns false if the face is opaque, true if transparent, null if it should not be meshed
fn meshOne(one: Block, two: Block) ?bool {
    if (one == two or !one.isVisible() or !two.isTransparent()) return null;
    return if (one.isTransparent()) true else false;
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
    }
    const et = std.Io.Timestamp.now(std.testing.io, .awake);
    const dt = st.durationTo(et);
    std.log.info("Mesh benchmark: {d} meshes in {d} ms", .{ test_amount, dt.toMilliseconds() });
    std.log.info("completed with an avg time of {d} us per mesh\n", .{(@as(f64, @floatFromInt(dt.toMicroseconds())) / test_amount)});
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
