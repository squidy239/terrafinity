const Blocks = @import("Blocks.zig").Blocks;
const std = @import("std");
const Noise = @import("./fastnoise.zig");
const gl = @import("gl");
const World = @import("./World.zig");
const ztracy = @import("ztracy");

const zm = @import("zm");
pub const ChunkSize = 32;
test "Gen+Mesh" {
    const chunk = Chunk.Generator().GenChunk(3, [3]i32{ 0, -4, 0 });
    const mesh = try Chunk.Render().MeshChunk_Normal(@constCast(&chunk), std.testing.allocator);
    std.debug.print("{any}", .{mesh});

    _ = try std.testing.expect(mesh.len > 0);
    std.testing.allocator.free(mesh);
    //std.debug.print("len:{d}, {any}", .{ mesh.len, chunk.blocks[0][0][0] });
}
//3 render distances, one chunks will be loaded in, one the meshes will still be loaded, and one chunks will generate in
// if generation radis is bigger than loading radies than chunks will be compressed and written to the disk but the meshes will stay
// might have more render distances for entities

pub const ChunkState = enum(u8) {
    NotGenerated = 0,
    AllAir = 1,
    Generating = 2,
    InMemoryNoMesh = 3,
    MeshOnly = 4,
    WaitingForNeighbors = 5,
    InMemoryAndMesh = 6,
    Unknown = 7,
};

pub const PtrState = struct {
    ChunkPtr: ?*Chunk,
    State: ChunkState,
};

pub const MeshBufferIDs = struct {
    vbo: c_uint,
    vao: c_uint,
    pos: [3]i32,
    count: u32,
};

pub const Chunk = struct {
    pos: [3]i32,
    blocks: [ChunkSize][ChunkSize][ChunkSize]Blocks,
    blockdata: ?*std.AutoHashMap([3]u5, []u32),
    neighbors: [6]PtrState,
    lock: std.Thread.RwLock,
};

pub const Render = struct {
    const vertices = [_]f32{
        -0.5, -0.5, 0.0, // bottom left corner
        -0.5, 0.5, 0.0, // top left corner
        0.5, 0.5,  0.0, // top right corner
        0.5, -0.5, 0.0,
    }; // bottom right corner
    fn EncodeFace(side: u3, blocktype: Blocks, pos: [3]usize) [2]u32 {
        var EncodedBlock = [2]u32{ 0, 0 };
        //bitpacking structure
        //pos|5 x 5 y 5 z| face|3| blocktype|20| 26 leftover bits
        EncodedBlock[0] |= @as(u32, @intCast(pos[0])) << (@bitSizeOf(u32) - 5);
        EncodedBlock[0] |= @as(u32, @intCast(pos[1])) << (@bitSizeOf(u32) - 10);
        EncodedBlock[0] |= @as(u32, @intCast(pos[2])) << (@bitSizeOf(u32) - 15);
        //block type bits
        EncodedBlock[0] |= @as(u32, @intCast(side)) << (@bitSizeOf(u32) - 18);
        EncodedBlock[1] |= @as(u32, @intCast(@intFromEnum(blocktype))) << (@bitSizeOf(u32) - 20);
        return EncodedBlock;
    }

    //nehbors +x -x +y -y +z -z
    //        0   1  2  3  4  5
    pub fn MeshChunk_Normal(chunk: *Chunk, allocator: std.mem.Allocator, neighbors: [6]?Chunk) ![]u32 {
        const meshchunkreal = ztracy.ZoneNC(@src(), "meshchunkreal", 0x965792d);
        defer meshchunkreal.End();
        var mesh = std.ArrayList(u32).init(allocator);
        defer mesh.deinit();
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |y| {
                for (0..ChunkSize) |z| {
                    if (chunk.blocks[x][y][z] != Blocks.Air) {
                        if (x == ChunkSize - 1 and neighbors[0] != null and neighbors[0].?.blocks[0][y][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(1, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        } else if (x != ChunkSize - 1 and chunk.blocks[x + 1][y][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(1, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }

                        if (x == 0 and neighbors[1] != null and neighbors[1].?.blocks[ChunkSize - 1][y][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(0, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        } else if (x != 0 and chunk.blocks[x - 1][y][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(0, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }

                        if (y == ChunkSize - 1 and neighbors[2] != null and neighbors[2].?.blocks[x][0][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(3, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        } else if (y != ChunkSize - 1 and chunk.blocks[x][y + 1][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(3, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }

                        if (y == 0 and neighbors[3] != null and neighbors[3].?.blocks[x][ChunkSize - 1][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(2, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        } else if (y != 0 and chunk.blocks[x][y - 1][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(2, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }

                        if (z == ChunkSize - 1 and neighbors[4] != null and neighbors[4].?.blocks[x][y][0] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(5, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        } else if (z != ChunkSize - 1 and chunk.blocks[x][y][z + 1] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(5, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }

                        if (z == 0 and neighbors[5] != null and neighbors[5].?.blocks[x][y][ChunkSize - 1] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(4, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        } else if (z != 0 and chunk.blocks[x][y][z - 1] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(4, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }
                    }
                }
            }
        }
        return mesh.toOwnedSlice();
    }

    pub fn CreateOrUpdateMeshVBO(mesh: []u32, pos: [3]i32, indecies: c_uint, facebuffer: c_uint, MeshIDs: ?MeshBufferIDs, usage: comptime_int) MeshBufferIDs {
        const createvbo = ztracy.ZoneNC(@src(), "createvbo", 0x00_ff_00_00);
        defer createvbo.End();
        var NewMeshIDs: MeshBufferIDs = undefined;
        std.debug.assert(mesh.len > 0);
        if (MeshIDs != null) {
            gl.BindVertexArray(MeshIDs.?.vao);
            gl.BindBuffer(gl.ARRAY_BUFFER, MeshIDs.?.vbo);
        } else {
            gl.GenVertexArrays(1, @ptrCast(&NewMeshIDs.vao));
            gl.GenBuffers(1, @ptrCast(&NewMeshIDs.vbo));

            gl.BindVertexArray(NewMeshIDs.vao);
            gl.BindBuffer(gl.ARRAY_BUFFER, NewMeshIDs.vbo);
        }

        gl.BufferData(gl.ARRAY_BUFFER, @intCast(@sizeOf(u32) * mesh.len), mesh.ptr, usage);
        NewMeshIDs.pos = pos;
        NewMeshIDs.count = @intCast(mesh.len);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, indecies);
        gl.BindBuffer(gl.ARRAY_BUFFER, facebuffer);
        gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(f32), 0);
        gl.EnableVertexAttribArray(0);
        gl.BindBuffer(gl.ARRAY_BUFFER, NewMeshIDs.vbo);
        gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(u32), 0);
        gl.EnableVertexAttribArray(1);
        gl.VertexAttribDivisor(1, 1);
        gl.BindBuffer(gl.ARRAY_BUFFER, 0);
        //std.debug.print("mesh made:{d}faces\n", .{mesh.len});
        gl.BindVertexArray(0);
        return MeshIDs orelse NewMeshIDs;
    }
};
pub const Generator = struct {
    pub fn InitChunkToBlock(block: Blocks, pos: [3]i32, neighbors: ?[6]PtrState) Chunk {
        var ch = Chunk{
            .pos = pos,
            .blockdata = null,
            .blocks = undefined,
            .lock = .{},
            .neighbors = neighbors orelse [6]PtrState{
                PtrState{ .ChunkPtr = null, .State = ChunkState.Unknown },
                PtrState{ .ChunkPtr = null, .State = ChunkState.Unknown },
                PtrState{ .ChunkPtr = null, .State = ChunkState.Unknown },
                PtrState{ .ChunkPtr = null, .State = ChunkState.Unknown },
                PtrState{ .ChunkPtr = null, .State = ChunkState.Unknown },
                PtrState{ .ChunkPtr = null, .State = ChunkState.Unknown },
            },
        };
        //this is annoying but zig dosent compile for relesefast when i directly initalize the array
        @memset(&ch.blocks, [1][ChunkSize]Blocks{[1]Blocks{block} ** ChunkSize} ** ChunkSize);
        return ch;
    }

    pub fn PollHeight5(xz: [2]i32, TerrainNoise: Noise.Noise(f32), min: i32, max: i32) i32 {
        const p1 = TerrainNoise.genNoise2DRange(16.0 / @as(f32, @floatFromInt(ChunkSize)) + @as(f32, @floatFromInt(xz[0])), (16.0 / @as(f32, @floatFromInt(ChunkSize))) + @as(f32, @floatFromInt(xz[1])), i32, min, max);
        const p2 = TerrainNoise.genNoise2DRange((@as(f32, @floatFromInt(0)) / @as(f32, @floatFromInt(ChunkSize))) + @as(f32, @floatFromInt(xz[0])), (@as(f32, @floatFromInt(0)) / @as(f32, @floatFromInt(ChunkSize))) + @as(f32, @floatFromInt(xz[1])), i32, min, max);
        const p3 = TerrainNoise.genNoise2DRange((@as(f32, @floatFromInt(0)) / @as(f32, @floatFromInt(ChunkSize))) + @as(f32, @floatFromInt(xz[0])), (@as(f32, @floatFromInt(32)) / @as(f32, @floatFromInt(ChunkSize))) + @as(f32, @floatFromInt(xz[1])), i32, min, max);
        const p4 = TerrainNoise.genNoise2DRange((@as(f32, @floatFromInt(32)) / @as(f32, @floatFromInt(ChunkSize))) + @as(f32, @floatFromInt(xz[0])), (@as(f32, @floatFromInt(0)) / @as(f32, @floatFromInt(ChunkSize))) + @as(f32, @floatFromInt(xz[1])), i32, min, max);
        const p5 = TerrainNoise.genNoise2DRange((@as(f32, @floatFromInt(32)) / @as(f32, @floatFromInt(ChunkSize))) + @as(f32, @floatFromInt(xz[0])), (@as(f32, @floatFromInt(32)) / @as(f32, @floatFromInt(ChunkSize))) + @as(f32, @floatFromInt(xz[1])), i32, min, max);
        return @divFloor(p1 + p2 + p3 + p4 + p5, 5);
    }

    pub fn GenChunk(Pos: [3]i32, TerrainNoise: Noise.Noise(f32), CaveNoise: Noise.Noise(f32), terrainmin: i32, terrainmax: i32, caveness: u8) ?Chunk {
        const tpoos = Pos * @Vector(3, i32){ 32, 32, 32 };
        var poos: [3]f32 = undefined;
        poos[0] = @as(f32, @floatFromInt(tpoos[0]));
        poos[1] = @as(f32, @floatFromInt(tpoos[1]));
        poos[2] = @as(f32, @floatFromInt(tpoos[2]));
        const gen = ztracy.ZoneNC(@src(), "genchunk", 0x692de);
        defer gen.End();
        var IsImportent: bool = false;
        const setair = ztracy.ZoneNC(@src(), "setair", 0x692de);
        var chunk = InitChunkToBlock(Blocks.Air, Pos, null);
        setair.End();
        var x: f32 = 0;
        var y: f32 = 0;
        var z: f32 = 0;
        var xx: usize = 0;
        var yy: usize = 0;
        var zz: usize = 0;

        //Terrain
        while (xx < ChunkSize) {
            while (zz < ChunkSize) {
                const tn = TerrainNoise.genNoise2DRange(x + poos[0], z + poos[2], i32, terrainmin, terrainmax);
                var h: i32 = 0;
                var Histopofchunk = false;
                var c = false;
                if (@divFloor(tn, 32) == Pos[1]) {
                    h = @mod(tn, ChunkSize);
                    c = true;
                }
                //
                else if (@divFloor(tn, 32) > Pos[1]) {
                    h = ChunkSize - 1;
                    c = true;
                    Histopofchunk = true;
                }
                if (c) {
                    while (yy <= h) {
                        const cn = CaveNoise.genNoise3DAsType(x + poos[0], y + poos[1], z + poos[2], u8);
                        //const cn = 180;
                        if (cn < caveness) {
                            if (!Histopofchunk and yy == h) {
                                chunk.blocks[xx][yy][zz] = Blocks.Grass;
                            } else if (!Histopofchunk and yy > h - 5) {
                                chunk.blocks[xx][yy][zz] = Blocks.Dirt;
                            } else {
                                chunk.blocks[xx][yy][zz] = Blocks.Stone;
                            }
                            IsImportent = true;
                        }
                        y += 1.0;
                        yy += 1;
                    }
                }

                z += 1.0;
                zz += 1;
                y = 0.0;
                yy = 0;
            }
            z = 0.0;
            zz = 0;
            xx += 1;
            x += 1.0;
        }
        if (IsImportent) {
            return chunk;
        } else {
            return null;
        }
    }
};
