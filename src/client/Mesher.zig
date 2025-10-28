const std = @import("std");
const Chunk = @import("Chunk").Chunk;
const Block = @import("Block").Blocks;
const Obj = @import("obj");
const ztracy = @import("ztracy");

const ChunkSize = Chunk.ChunkSize;

pub const FaceRotation = enum(u4) {
    xPlus = 0,
    xMinus = 1,
    yPlus = 2,
    yMinus = 3,
    zPlus = 4,
    zMinus = 5,
    diagonalPlus = 6,
    diagonalMinus = 7,
};

pub const Face = packed struct(u64) {
    x: u5,
    y: u5,
    z: u5,
    rot: FaceRotation,
    isGreedy: bool,
    height: i6,
    width: i6,
    BlockType: Block,
    _: u12,
};
threadlocal var faceBuffer: [ChunkSize * ChunkSize * ChunkSize * 6]Face = undefined;
threadlocal var TransparentfaceBuffer: [ChunkSize * ChunkSize * ChunkSize * 6]Face = undefined;
threadlocal var extendedBlocks: [ChunkSize + 2][ChunkSize + 2][ChunkSize + 2]Block = undefined;

//TODO make better mesher, greedy meshing? 
//maybie for each face move in and mesh the 2d face

pub const Mesh = struct {
    faces: ?[]const Face,
    TransperentFaces: ?[]const Face,
    Pos: [3]i32,
    ///neighbor_faces format: x+,x-,y+,y-,z+,z-, caller handles refs
    pub fn MeshFromChunks(ChunkPos: [3]i32, mainblocks: *[ChunkSize][ChunkSize][ChunkSize]Block, neighbor_faces: *const [6][ChunkSize][ChunkSize]Block, allocator: std.mem.Allocator) !?@This() {
        const mdc = ztracy.ZoneNC(@src(), "MeshFromChunks", 222222);
        defer mdc.End();
        const ecp = ztracy.ZoneNC(@src(), "extendedChunkparent", 1111);
        GenerateExtendedChunk(&extendedBlocks, mainblocks, neighbor_faces);
        //buffers are threadlocal so they only get init once, HUGE speedup
        var pos: usize = 0;
        var Tpos: usize = 0;
        ecp.End();
        const loop = ztracy.ZoneNC(@src(), "loopAllBlocks", 222222);
        for (1..ChunkSize + 1) |x| {
            for (1..ChunkSize + 1) |y| {
                for (1..ChunkSize + 1) |z| {
                    const block = extendedBlocks[x][y][z];
                    if (!block.Visible()) continue;
                    const neighboring_blocks = @Vector(6, @typeInfo(Block).@"enum".tag_type){
                        @intFromEnum(extendedBlocks[x + 1][y][z]),
                        @intFromEnum(extendedBlocks[x - 1][y][z]),
                        @intFromEnum(extendedBlocks[x][y + 1][z]),
                        @intFromEnum(extendedBlocks[x][y - 1][z]),
                        @intFromEnum(extendedBlocks[x][y][z + 1]),
                        @intFromEnum(extendedBlocks[x][y][z - 1]),
                    };
                    const neighboring_blocks_transparent = Block.TransperentVec(6, neighboring_blocks);
                    const block_transparent = block.Transperent();
                    inline for (0..6) |i| {
                        inner: {
                            if (!neighboring_blocks_transparent[i]) break:inner;
                            if (!block_transparent) {
                                std.debug.assert(pos < faceBuffer.len);
                                faceBuffer[pos] = Face{
                                    .BlockType = block,
                                    .isGreedy = false,
                                    .height = 1,
                                    .width = 1,
                                    .rot = @enumFromInt(i),
                                    .x = @intCast(x - 1),
                                    .y = @intCast(y - 1),
                                    .z = @intCast(z - 1),
                                    ._ = undefined,
                                };
                                pos += 1;
                            } else if (@intFromEnum(block) != neighboring_blocks[i]) {
                                std.debug.assert(Tpos < TransparentfaceBuffer.len);
                                TransparentfaceBuffer[Tpos] = Face{
                                    .BlockType = block,
                                    .isGreedy = false,
                                    .height = 1,
                                    .width = 1,
                                    .rot = @enumFromInt(i),
                                    .x = @intCast(x - 1),
                                    .y = @intCast(y - 1),
                                    .z = @intCast(z - 1),
                                    ._ = undefined,
                                };
                                Tpos += 1;
                            }
                        }
                    }
                }
            }
        }
        loop.End();
        if (pos > 0 or Tpos > 0) {
            //std.debug.print("mlen:{d}, faces:{any}\n", .{ pos, (faceBuffer[0..pos]) });
            const aa = ztracy.ZoneNC(@src(), "AllocFaces", 222344);
            defer aa.End();
            return @This(){
                .faces = if (pos > 0) try allocator.dupe(Face, faceBuffer[0..pos]) else null,
                .TransperentFaces = if (Tpos > 0) try allocator.dupe(Face, TransparentfaceBuffer[0..Tpos]) else null,
                .Pos = ChunkPos,
            };
        } else return null;
    }

    pub fn free(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.faces) |f| allocator.free(f);
        if (self.TransperentFaces) |f| allocator.free(f);
    }
    ///x+,x-,y+,y-,z+,z-
    fn GenerateExtendedChunk(blocksToPut: *[ChunkSize + 2][ChunkSize + 2][ChunkSize + 2]Block, mainblocks: *const [ChunkSize][ChunkSize][ChunkSize]Block, neighbor_faces: *const [6][ChunkSize][ChunkSize]Block) void {
        const gec = ztracy.ZoneNC(@src(), "GenerateExtendedChunk", 9328);
        defer gec.End();

        // Copy main blocks
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |y| {
                for (0..ChunkSize) |z| {
                    blocksToPut[x + 1][y + 1][z + 1] = mainblocks[x][y][z];
                }
            }
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
};
