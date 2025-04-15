const std = @import("std");
const Chunk = @import("Chunk").Chunk;
const Block = @import("Block").Blocks;
const ztracy = @import("ztracy");

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

pub const Face = packed struct(u64) {
    x: u5,
    y: u5,
    z: u5,
    rot: FaceRotation,
    isGreedy: bool,
    height: i6,
    width: i6,
    //  unused_bool: bool,
    BlockType: Block,
    _: u12,
};

threadlocal var faceBuffer: [ChunkSize * ChunkSize * ChunkSize * 6]Face = undefined;
threadlocal var TransparentfaceBuffer: [ChunkSize * ChunkSize * ChunkSize * 6]Face = undefined;

pub const Mesh = struct {
    faces: ?[]const Face,
    TransperentFaces: ?[]const Face,
    Pos: [3]i32,
    ///neighbor_faces format: x+,x-,y+,y-,z+,z-, caller handles refs
    pub fn MeshFromChunks(ChunkPos: [3]i32, mainblocks: *[ChunkSize][ChunkSize][ChunkSize]Block, neighbor_faces: [6][ChunkSize][ChunkSize]Block, allocator: std.mem.Allocator) !?@This() {
        const mdc = ztracy.ZoneNC(@src(), "MeshFromChunks", 222222);
        defer mdc.End();
        const blocks: [ChunkSize + 2][ChunkSize + 2][ChunkSize + 2]Block = GenerateExtendedChunk(mainblocks, neighbor_faces);
        //buffers are threadlocal so they only get init once, HUGE speedup
        var pos: usize = 0;
        var Tpos: usize = 0;
        const loop = ztracy.ZoneNC(@src(), "loopAllBlocks", 222222);
        for (1..ChunkSize + 1) |x| {
            for (1..ChunkSize + 1) |y| {
                for (1..ChunkSize + 1) |z| {
                    if (blocks[x][y][z].Visible()) {
                        const block = blocks[x][y][z];
                        const neighboring_blocks = [6]Block{
                            blocks[x + 1][y][z],
                            blocks[x - 1][y][z],
                            blocks[x][y + 1][z],
                            blocks[x][y - 1][z],
                            blocks[x][y][z + 1],
                            blocks[x][y][z - 1],
                        };
                        inline for (neighboring_blocks, 0..) |b, i| {
                            if (b.Transperent()) {
                                @branchHint(.unlikely);
                                const face = Face{
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
                                if (!block.Transperent()) {
                                    @branchHint(.likely);
                                    faceBuffer[pos] = face;
                                    pos += 1;
                                } else if (block != b) {
                                    @branchHint(.unlikely);
                                    TransparentfaceBuffer[Tpos] = face;
                                    Tpos += 1;
                                }
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
    fn GenerateExtendedChunk(mainblocks: *[ChunkSize][ChunkSize][ChunkSize]Block, neighbor_faces: [6][ChunkSize][ChunkSize]Block) [ChunkSize + 2][ChunkSize + 2][ChunkSize + 2]Block {
        const gec = ztracy.ZoneNC(@src(), "GenerateExtendedChunk", 9328);
        defer gec.End();
        var blocks: [ChunkSize + 2][ChunkSize + 2][ChunkSize + 2]Block = undefined; // Initialize with Air blocks

        // Copy main blocks
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |y| {
                for (0..ChunkSize) |z| {
                    blocks[x + 1][y + 1][z + 1] = mainblocks[x][y][z];
                }
            }
        }

        // Copy neighbor faces
        // Face 4: -Z face (z=0)
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |y| {
                blocks[x + 1][y + 1][0] = neighbor_faces[5][x][y];
            }
        }

        // Face 5: +Z face (z=ChunkSize+1)
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |y| {
                blocks[x + 1][y + 1][ChunkSize + 1] = neighbor_faces[4][x][y];
            }
        }

        // Face 0: -X face (x=0)
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                blocks[0][y + 1][z + 1] = neighbor_faces[1][y][z];
            }
        }

        // Face 1: +X face (x=ChunkSize+1)
        for (0..ChunkSize) |y| {
            for (0..ChunkSize) |z| {
                blocks[ChunkSize + 1][y + 1][z + 1] = neighbor_faces[0][y][z];
            }
        }

        // Face 2: -Y face (y=0)
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |z| {
                blocks[x + 1][0][z + 1] = neighbor_faces[3][x][z];
            }
        }

        // Face 3: +Y face (y=ChunkSize+1)
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |z| {
                blocks[x + 1][ChunkSize + 1][z + 1] = neighbor_faces[2][x][z];
            }
        }

        return blocks;
    }
};
