const std = @import("std");

const Obj = @import("obj");
const ztracy = @import("ztracy");

const Block = @import("world/Block.zig").Block;
const Chunk = @import("world/Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const ChunkPos = @import("world/World.zig").ChunkPos;

pub const FaceRotation = enum(u4) {
    xPlus = 0,
    xMinus = 1,
    yPlus = 2,
    yMinus = 3,
    zPlus = 4,
    zMinus = 5,
};

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
    const mdc = ztracy.ZoneNC(@src(), "MeshFromChunks", 222222);
    defer mdc.End();
    if (shouldSkip(neighbor_faces, mainblocks)) return;
    try meshSimple(mainblocks, neighbor_faces, opaque_writer);
}

fn shouldSkip(neighbor_faces: *const [6]Chunk.Encoding.Face, mainblocks: Chunk.Encoding) bool {
    var all_invisible: bool = true;
    for (neighbor_faces) |face| {
        all_invisible |= (face == .one_block and !face.one_block.isVisible());
    }
    all_invisible |= mainblocks == .one_block and !mainblocks.one_block.isVisible();
    return !all_invisible;
}

//fn meshFace(blocks: Chunk.Encoding, neighbor_face: *Chunk.Encoding.Face, opaque_writer: *std.Io.Writer, transparent_writer: *std.Io.Writer) !void {}

fn meshSimple(mainblocks: Chunk.Encoding, neighbor_faces: *const [6]Chunk.Encoding.Face, opaque_writer: *std.Io.Writer) !void {
    const ecp = ztracy.ZoneNC(@src(), "extendedChunkparent", 1111);
    var extendedBlocks: [ChunkSize + 2][ChunkSize + 2][ChunkSize + 2]Block = undefined;
    GenerateExtendedChunk(&extendedBlocks, mainblocks, neighbor_faces);
    ecp.End();
    const loop = ztracy.ZoneNC(@src(), "loopAllBlocks", 222222);
    for (1..ChunkSize + 1) |x| {
        for (1..ChunkSize + 1) |y| {
            for (1..ChunkSize + 1) |z| {
                const block = extendedBlocks[x][y][z];
                if (!block.isVisible()) continue;
                const neighboring_blocks = [6]Block{
                    extendedBlocks[x + 1][y][z],
                    extendedBlocks[x - 1][y][z],
                    extendedBlocks[x][y + 1][z],
                    extendedBlocks[x][y - 1][z],
                    extendedBlocks[x][y][z + 1],
                    extendedBlocks[x][y][z - 1],
                };
                const block_transparent = block.isTransparent();
                inline for (0..6) |i| {
                    if (neighboring_blocks[i].isTransparent() and (!block_transparent or block != neighboring_blocks[i])) {
                        const face = Face{
                            .BlockType = block,
                            .rot = @enumFromInt(i),
                            .x = @intCast(x - 1),
                            .y = @intCast(y - 1),
                            .z = @intCast(z - 1),
                        };
                        try opaque_writer.writeAll(std.mem.asBytes(&face));
                    }
                }
            }
        }
    }
    loop.End();
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
    try meshSimple(mainblocks, &neighbor_faces, &writer.writer);
}

///x+,x-,y+,y-,z+,z-
fn GenerateExtendedChunk(blocksToPut: *[ChunkSize + 2][ChunkSize + 2][ChunkSize + 2]Block, mainblocks: Chunk.Encoding, neighbor_faces: *const [6]Chunk.Encoding.Face) void {
    const gec = ztracy.ZoneNC(@src(), "GenerateExtendedChunk", 9328);
    defer gec.End();

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
