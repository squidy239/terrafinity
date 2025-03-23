const std = @import("std");
const Chunk = @import("Chunk").Chunk;
const Block = @import("Block").Blocks;

const ChunkSize = 32;

pub const FaceRotation = enum(u4) {
    xPlus = 0,
    xMunus = 1,
    yPlus = 2,
    yMunus = 3,
    zPlus = 4,
    zMunus = 5,
    diagonalPlus = 6,
    diagonalMinus = 7,
};

pub const Face = packed struct {
    BlockType: Block,
    x: u5,
    y: u5,
    z: u5,
    isGreedy: bool,
    height: i6,
    width: i6,
    rot: FaceRotation,
};

pub const Mesh = struct {
    faces: ?[]const Face,
    TransperentFaces: ?[]const Face,
    Pos: [3]i32,
    pub fn MeshFromChunks(ChunkPos: [3]i32, mainblocks: *[ChunkSize][ChunkSize][ChunkSize]Block, neighbor_faces: [6][ChunkSize][ChunkSize]Block, allocator: std.mem.Allocator) !?@This() {
        const blocks: [ChunkSize + 2][ChunkSize + 2][ChunkSize + 2]Block = GenerateExtendedChunk(mainblocks, neighbor_faces);
        var faceBuffer: [ChunkSize * ChunkSize * ChunkSize * 6]Face = undefined;
        var pos: usize = 0;
        var TransparentfaceBuffer: [ChunkSize * ChunkSize * ChunkSize * 6]Face = undefined;
        var Tpos: usize = 0;
        for (1..ChunkSize + 1) |x| {
            for (1..ChunkSize + 1) |y| {
                for (1..ChunkSize + 1) |z| {
                    const block = blocks[x][y][z];
                    if (block.Visible()) {
                        const neighboring_blocks = [6]Block{
                            blocks[x + 1][y][z],
                            blocks[x - 1][y][z],
                            blocks[x][y + 1][z],
                            blocks[x][y - 1][z],
                            blocks[x][y][z + 1],
                            blocks[x][y][z - 1],
                        };
                        for (neighboring_blocks, 0..) |b, i| {
                            if (b.Transperent()) {
                                const face = Face{
                                    .BlockType = block,
                                    .isGreedy = false,
                                    .height = 1,
                                    .width = 1,
                                    .rot = @enumFromInt(i),
                                    .x = x,
                                    .y = y,
                                    .z = z,
                                };
                                if (block.Transperent()) {
                                    TransparentfaceBuffer[Tpos] = face;
                                    Tpos += 1;
                                } else {
                                    @branchHint(.likely);
                                    faceBuffer[pos] = face;
                                    pos += 1;
                                }
                                pos += 1;
                            }
                        }
                    }
                }
            }
        }
        if (pos > 0 or Tpos > 0) {
            return @This(){
                .faces = if (pos > 0) try allocator.dupe(Face, faceBuffer[0..pos]) else null,
                .TransperentFaces = if (pos > 0) try allocator.dupe(Face, faceBuffer[0..pos]) else null,
                .Pos = ChunkPos,
            };
        } else return null;
    }

    fn GenerateExtendedChunk(mainblocks: *[ChunkSize][ChunkSize][ChunkSize]Block, neighbor_faces: [6][ChunkSize][ChunkSize]Block) [ChunkSize + 2][ChunkSize + 2][ChunkSize + 2]Block {
        var blocks: [ChunkSize + 2][ChunkSize + 2][ChunkSize + 2]Block = undefined;
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                // Copy an entire row of blocks at once
                @memcpy(
                    &blocks[1][y + 1][z + 1],
                    &mainblocks[0][y][z],
                );
            }
        }

        // For the XY faces (constant Z), we can use memcpy for entire rows
        // Face 4: -Z face (z=0)
        for (0..ChunkSize) |y| {
            @memcpy(
                &blocks[1][y + 1][0],
                &neighbor_faces[4][0][y],
            );
        }

        // Face 5: +Z face (z=ChunkSize+1)
        for (0..ChunkSize) |y| {
            @memcpy(
                &blocks[1][y + 1][ChunkSize + 1],
                &neighbor_faces[5][0][y],
            );
        }

        // The other faces require individual element copying
        // Face 0: -X face (x=0)
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                blocks[0][y + 1][z + 1] = neighbor_faces[0][y][z];
            }
        }

        // Face 1: +X face (x=ChunkSize+1)
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                blocks[ChunkSize + 1][y + 1][z + 1] = neighbor_faces[1][y][z];
            }
        }

        // Face 2: -Y face (y=0)
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |z| {
                blocks[x + 1][0][z + 1] = neighbor_faces[2][x][z];
            }
        }

        // Face 3: +Y face (y=ChunkSize+1)
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |z| {
                blocks[x + 1][ChunkSize + 1][z + 1] = neighbor_faces[3][x][z];
            }
        }
        return blocks;
    }
};
