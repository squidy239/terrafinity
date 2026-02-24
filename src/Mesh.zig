const std = @import("std");

const Block = @import("world/Block.zig").Block;
const Chunk = @import("world/Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const ChunkPos = @import("world/World.zig").ChunkPos;
const Obj = @import("obj");
const ztracy = @import("ztracy");

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
    isGreedy: bool,
    height: i6,
    width: i6,
    BlockType: u20,
    _: u12,
};

//TODO make neighbor faces like blockencoding to handle empty chunks better
///neighbor_faces format: x+,x-,y+,y-,z+,z-, caller handles refs
pub fn fromChunks(mainblocks: Chunk.BlockEncoding, neighbor_faces: *const [6][ChunkSize][ChunkSize]Block, writer: *std.Io.Writer) !void {
    const mdc = ztracy.ZoneNC(@src(), "MeshFromChunks", 222222);
    defer mdc.End();
    const ecp = ztracy.ZoneNC(@src(), "extendedChunkparent", 1111);
    var ExtendedBlocks: [ChunkSize + 2][ChunkSize + 2][ChunkSize + 2]Block = undefined;
    GenerateExtendedChunk(&ExtendedBlocks, mainblocks, neighbor_faces);
    ecp.End();
    if (@bitSizeOf(Block) > 20) @compileError("@bitSizeOf(Block) must be <= 20");
    try meshSimple(&ExtendedBlocks, writer);
}

fn meshSimple(extendedBlocks: *const [ChunkSize + 2][ChunkSize + 2][ChunkSize + 2]Block, writer: *std.Io.Writer) !void {
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
                    inner: {
                        if (!neighboring_blocks[i].isTransparent()) break :inner;
                        if (!block_transparent) {
                            const face = Face{
                                .BlockType = @intFromEnum(block),
                                .isGreedy = false,
                                .height = 1,
                                .width = 1,
                                .rot = @enumFromInt(i),
                                .x = @intCast(x - 1),
                                .y = @intCast(y - 1),
                                .z = @intCast(z - 1),
                                ._ = undefined,
                            };
                            try writer.writeAll(std.mem.asBytes(&face));
                        } else if (block != neighboring_blocks[i]) {
                            const face = Face{
                                .BlockType = @intFromEnum(block),
                                .isGreedy = false,
                                .height = 1,
                                .width = 1,
                                .rot = @enumFromInt(i),
                                .x = @intCast(x - 1),
                                .y = @intCast(y - 1),
                                .z = @intCast(z - 1),
                                ._ = undefined,
                            };
                            try writer.writeAll(std.mem.asBytes(&face));
                        }
                    }
                }
            }
        }
    }
    loop.End();
}

///x+,x-,y+,y-,z+,z-
fn GenerateExtendedChunk(blocksToPut: *[ChunkSize + 2][ChunkSize + 2][ChunkSize + 2]Block, mainblocks: Chunk.BlockEncoding, neighbor_faces: *const [6][ChunkSize][ChunkSize]Block) void {
    const gec = ztracy.ZoneNC(@src(), "GenerateExtendedChunk", 9328);
    defer gec.End();

    switch (mainblocks) {
        .blocks => |blocks| {
            for (0..ChunkSize) |x| {
                for (0..ChunkSize) |y| {
                    for (0..ChunkSize) |z| {
                        blocksToPut[x + 1][y + 1][z + 1] = blocks[x][y][z];
                    }
                }
            }
        },
        .oneBlock => |block| {
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
            blocksToPut[x + 1][y + 1][0] = neighbor_faces[5][x][y];
        }
    }

    // Face 5: +Z face (z=ChunkSize+1)
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |y| {
            blocksToPut[x + 1][y + 1][ChunkSize + 1] = neighbor_faces[4][x][y];
        }
    }

    // Face 0: -X face (x=0)
    for (0..ChunkSize) |y| {
        for (0..ChunkSize) |z| {
            blocksToPut[0][y + 1][z + 1] = neighbor_faces[1][y][z];
        }
    }

    // Face 1: +X face (x=ChunkSize+1)
    for (0..ChunkSize) |y| {
        for (0..ChunkSize) |z| {
            blocksToPut[ChunkSize + 1][y + 1][z + 1] = neighbor_faces[0][y][z];
        }
    }

    // Face 2: -Y face (y=0)
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |z| {
            blocksToPut[x + 1][0][z + 1] = neighbor_faces[3][x][z];
        }
    }

    // Face 3: +Y face (y=ChunkSize+1)
    for (0..ChunkSize) |x| {
        for (0..ChunkSize) |z| {
            blocksToPut[x + 1][ChunkSize + 1][z + 1] = neighbor_faces[2][x][z];
        }
    }
}
