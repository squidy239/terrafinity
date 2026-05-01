const std = @import("std");

const Obj = @import("obj");
const tracy = @import("tracy");

const Block = @import("world/Block.zig").Block;
const Chunk = @import("world/Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
pub const FaceRotation = Chunk.Encoding.FaceRotation;
const ChunkPos = @import("world/World.zig").ChunkPos;

const Mesh = @This();
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
pub fn fromChunks(mainblocks: Chunk.Encoding, neighbor_faces: *const [6]Chunk.Encoding.Face, opaque_writer: *std.Io.Writer) !void {
    const mdc = tracy.Zone.begin(.{ .src = @src(), .name = "MeshFromChunks" });
    defer mdc.end();
    if (shouldSkip(neighbor_faces, mainblocks)) return;
    inline for (0..6) |i| {
        try meshChunkFace(mainblocks.extractFace(@enumFromInt(i)), neighbor_faces[i], @enumFromInt(i), opaque_writer, opaque_writer);
    }
    try meshSimple(mainblocks, opaque_writer);
}

fn shouldSkip(neighbor_faces: *const [6]Chunk.Encoding.Face, mainblocks: Chunk.Encoding) bool {
    if (mainblocks != .one_block or mainblocks.one_block.isVisible()) return false;
    for (neighbor_faces) |face| {
        if (face != .one_block or face.one_block.isVisible()) return false;
    }
    return true;
}

fn meshChunkFace(one: Chunk.Encoding.Face, two: Chunk.Encoding.Face, comptime rotation: Chunk.Encoding.FaceRotation, opaque_writer: *std.Io.Writer, transparent_writer: *std.Io.Writer) !void {
    const grid_one: [ChunkSize][ChunkSize]Block = switch (one) {
        .blocks => |grid| grid,
        .one_block => |block| @splat(@splat(block)),
    };
    const grid_two: [ChunkSize][ChunkSize]Block = switch (two) {
        .blocks => |grid| grid,
        .one_block => |block| @splat(@splat(block)),
    };
    try meshChunkFaceGrid(&grid_one, &grid_two, rotation, opaque_writer, transparent_writer);
}

fn meshChunkFaceGrid(grid_one: *const [ChunkSize][ChunkSize]Block, grid_two: *const [ChunkSize][ChunkSize]Block, comptime rotation: Chunk.Encoding.FaceRotation, opaque_writer: *std.Io.Writer, transparent_writer: *std.Io.Writer) !void {
    for (grid_one, grid_two, 0..) |row_one, row_two, i| {
        for (row_one, row_two, 0..) |one, two, j| {
            const result = meshOne(one, two);
            if (result == .none) continue;
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
            if (result == .transparent) try transparent_writer.writeAll(std.mem.asBytes(&face));
            if (result == .@"opaque") try opaque_writer.writeAll(std.mem.asBytes(&face));
        }
    }
}

fn meshSimple(mainblocks: Chunk.Encoding, opaque_writer: *std.Io.Writer) !void {
    const ms = tracy.Zone.begin(.{ .src = @src(), .name = "meshSimple" });
    defer ms.end();
    const grid: *const [ChunkSize][ChunkSize][ChunkSize]Block = switch (mainblocks) {
        .grid => |g| g,
        .one_block => return,
    };
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
                        const face = meshOne(block, neighbor);
                        if (face != .none) {
                            const face_data = Face{
                                .BlockType = block,
                                .rot = @enumFromInt(i),
                                .x = @intCast(x),
                                .y = @intCast(y),
                                .z = @intCast(z),
                            };
                            try opaque_writer.writeAll(std.mem.asBytes(&face_data));
                        }
                    }
                }
            }
        }
    }
}

fn meshOne(one: Block, two: Block) enum { none, transparent, @"opaque" } {
    if (one == two or !one.isVisible() or !two.isTransparent()) return .none;
    return if (one.isTransparent()) .transparent else .@"opaque";
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
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.Discarding.init(&buf);
    const test_amount = 100; // reduced from 100000
    const st = std.Io.Timestamp.now(std.testing.io, .awake);
    for (0..test_amount) |_| {
        try fromChunks(.{ .grid = &blocks }, &@splat(Chunk.Encoding.Face{ .one_block = .air }), &writer.writer);
    }
    const et = std.Io.Timestamp.now(std.testing.io, .awake);
    const dt = st.durationTo(et);
    std.log.info("Mesh benchmark: {d} meshes in {d} ms", .{ test_amount, dt.toMilliseconds() });
    std.log.info("completed with an avg time of {d} us per mesh\n", .{(@as(f64, @floatFromInt(dt.toMicroseconds())) / test_amount)});
}

test "FuzzMesh" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(_: void, smith: *std.testing.Smith) !void {
    var blocks: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
    const mainblocks: Chunk.Encoding = .fuzzerMakeEncoding(&blocks, smith);
    const neighbor_faces: [6]Chunk.Encoding.Face = smith.value([6]Chunk.Encoding.Face);
    var writer = std.Io.Writer.Discarding.init(&.{});
    try Mesh.fromChunks(mainblocks, &neighbor_faces, &writer.writer);
}

///x+,x-,y+,y-,z+,z-
fn GenerateExtendedChunk(blocksToPut: *[ChunkSize + 2][ChunkSize + 2][ChunkSize + 2]Block, mainblocks: Chunk.Encoding, neighbor_faces: *const [6]Chunk.Encoding.Face) void {
    const gec = tracy.Zone.begin(.{ .src = @src(), .name = "GenerateExtendedChunk" });
    defer gec.end();

    switch (mainblocks) {
        .grid => |blocks| {
            for (0..ChunkSize) |x| {
                for (0..ChunkSize) |y| {
                    for (0..ChunkSize) |z| {
                        blocksToPut[x + 1][y + 1][z + 1] = blocks[x][y][z];
                    }
                }
            }
        },
        .one_block => |block| {
            for (0..ChunkSize) |x| {
                for (0..ChunkSize) |y| {
                    for (0..ChunkSize) |z| {
                        blocksToPut[x + 1][y + 1][z + 1] = block;
                    }
                }
            }
        },
    }

    // Copy neighbor faces
    // Face 4: -Z face (z=0)
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |y| {
            blocksToPut[x + 1][y + 1][0] = switch (neighbor_faces[5]) {
                .blocks => |b| b[x][y],
                .one_block => |b| b,
            };
        }
    }

    // Face 5: +Z face (z=ChunkSize+1)
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |y| {
            blocksToPut[x + 1][y + 1][ChunkSize + 1] = switch (neighbor_faces[4]) {
                .blocks => |b| b[x][y],
                .one_block => |b| b,
            };
        }
    }

    // Face 0: -X face (x=0)
    for (0..ChunkSize) |y| {
        for (0..ChunkSize) |z| {
            blocksToPut[0][y + 1][z + 1] = switch (neighbor_faces[1]) {
                .blocks => |b| b[y][z],
                .one_block => |b| b,
            };
        }
    }

    // Face 1: +X face (x=ChunkSize+1)
    for (0..ChunkSize) |y| {
        for (0..ChunkSize) |z| {
            blocksToPut[ChunkSize + 1][y + 1][z + 1] = switch (neighbor_faces[0]) {
                .blocks => |b| b[y][z],
                .one_block => |b| b,
            };
        }
    }

    // Face 2: -Y face (y=0)
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |z| {
            blocksToPut[x + 1][0][z + 1] = switch (neighbor_faces[3]) {
                .blocks => |b| b[x][z],
                .one_block => |b| b,
            };
        }
    }

    // Face 3: +Y face (y=ChunkSize+1)
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |z| {
            blocksToPut[x + 1][ChunkSize + 1][z + 1] = switch (neighbor_faces[2]) {
                .blocks => |b| b[x][z],
                .one_block => |b| b,
            };
        }
    }
}
