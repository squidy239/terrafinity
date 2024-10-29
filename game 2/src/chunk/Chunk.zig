const Blocks = @import("Blocks.zig").Blocks;
const std = @import("std");
const Noise = @import("./fastnoise.zig");
const gl = @import("gl");
pub const ChunkSize = 32;

//3 render distances, one chunks will be loaded in, one the meshes will still be loaded, and one chunks will generate in
// if generation radis is bigger than loading radies than chunks will be compressed and written to the disk but the meshes will stay
// might have more render distances for entities
pub const MeshBufferIDs = struct {
    vbo: c_uint,
    vao: c_uint,
    vlen: c_uint,
};

pub const Chunk = struct {
    pos: [3]i32,
    MeshIDs:?MeshBufferIDs,
    blocks: [ChunkSize][ChunkSize][ChunkSize]Blocks,
    blockdata: ?*std.AutoHashMap([3]u5, []u32),
    neighbors: [6]?*Chunk,

    Generator: struct {
        pub fn InitChunkToBlock(block: Blocks, pos: [3]i32, neighbors: ?[6]?*Chunk) Chunk {
            return Chunk{
                .pos = pos,
                .blockdata = null,
                .blocks = [_][32][32]Blocks{[_][32]Blocks{[_]Blocks{block} ** 32} ** 32} ** 32,
                .neighbors = neighbors orelse [6]?*Chunk{ null, null, null, null, null, null },
                .vbo = null,
                .vao = null,
                .vlen = null,
            };
        }

        pub fn GenChunk(seed: i32, Pos: [3]i32) Chunk {
            var chunk = InitChunkToBlock(Blocks.Air, Pos, null);
            const TerrainNoise = Noise.Noise(f32){
                .seed = seed,
                .noise_type = .cellular,
                .frequency = 0.08,
                .fractal_type = .progressive,
            };

            for (0..32) |x| {
                for (0..32) |z| {
                    const h = TerrainNoise.genNoise2DRange((@as(@floatFromInt(x), f32) / 32) + @as(@floatFromInt(Pos[0]), f32), (@as(@floatFromInt(y), f32) / 32) + @as(@floatFromInt(Pos[2]), f32), i32, -128, 128);
                    //std.debug.print("{}", .{h});
                    const d = @divFloor(h, @as(i32, 32));
                    if (d == Pos[1]) {
                        const y: usize = @intCast(@mod(h, 32));
                        chunk.blocks[x][y][z] = @intFromEnum(Blocks.Grass);
                        for (0..y) |yy| {
                            chunk.blocks[x][yy][z] = @intFromEnum(Blocks.Stone);
                        }
                    } else if (d > Pos[1]) {
                        for (0..32) |yy| {
                            chunk.blocks[x][yy][z] = @intFromEnum(Blocks.Stone);
                        }
                    }
                    //else {std.debug.print("{} ", .{@divFloor(h, @as(i32, 32))});}

                }
            }
            return chunk;
        }
    },

    Render: struct {

        pub fn MeshChunk_Normal(chunk: *Chunk, allocator: std.mem.Allocator) ![]u64 {
            //bitpacking structure
            //pos|5 x 5 y 5 z| faces|1 1 1 1 1 1| blocktype|20| 23 leftover bits
            //64 bits total 41 used

            var mesh = std.ArrayList(u64).init(allocator);
            defer mesh.deinit();
            for (0..ChunkSize) |x| {
                for (0..ChunkSize) |y| {
                    for (0..ChunkSize) |z| {
                        if (chunk.blocks[x][y][z] != Blocks.Air) {
                            // set to all 0s
                            var EncodedBlock: u64 = 0;
                            var r: bool = false;
                            //inserts bits that say which sides face air
                            if (x == 32) {} else if (chunk.blocks[x + 1][y][z] == Blocks.Air) {
                                EncodedBlock |= @as(u64, 0b1) << @bitSizeOf(u64) - 16;
                                r = true;
                            }

                            if (x == 0) {} else if (chunk.blocks[x - 1][y][z] == Blocks.Air) {
                                EncodedBlock |= @as(u64, 0b1) << @bitSizeOf(u64) - 17;
                                r = true;
                            }
                            if (y == 32) {} else if (chunk.blocks[x][y + 1][z] == Blocks.Air) {
                                EncodedBlock |= @as(u64, 0b1) << @bitSizeOf(u64) - 18;
                                r = true;
                            }
                            if (y == 0) {} else if (chunk.blocks[x][y - 1][z] == Blocks.Air) {
                                EncodedBlock |= @as(u64, 0b1) << @bitSizeOf(u64) - 19;
                                r = true;
                            }
                            if (z == 32) {} else if (chunk.blocks[x][y][z + 1] == Blocks.Air) {
                                EncodedBlock |= @as(u64, 0b1) << @bitSizeOf(u64) - 20;
                                r = true;
                            }
                            if (z == 0) {} else if (chunk.blocks[x][y][z - 1] == Blocks.Air) {
                                EncodedBlock |= @as(u64, 0b1) << @bitSizeOf(u64) - 21;
                                r = true;
                            }
                            if (!r) continue;
                            //block location bits
                            EncodedBlock |= @as(i64, @intCast(x)) - ChunkSize << @bitSizeOf(u64) - 5;
                            EncodedBlock |= @as(i64, @intCast(y)) - ChunkSize << @bitSizeOf(u64) - 10;
                            EncodedBlock |= @as(i64, @intCast(z)) - ChunkSize << @bitSizeOf(u64) - 15;
                            //block type bits
                            EncodedBlock |= @as(u64, @intCast(chunk.blocks[x][y][z])) << @bitSizeOf(u64) - 41;
                            mesh.append(EncodedBlock);
                        }
                    }
                }
            }
            return try mesh.toOwnedSlice();
        }
    },

    pub fn CreateOrUpdateMeshVBO(mesh:[]u64, MeshIDs:?MeshBufferIDs)MeshBufferIDs{
                if(MeshIDs != null){
                    gl.BindVertexArray(MeshIDs.?.vao);
                    gl.BindBuffer(gl.ARRAY_BUFFER, MeshIDs.?.vbo);

                }
                else {
                    var NewMeshIDs:MeshBufferIDs = undefined;
                    gl.GenVertexArrays(1, &NewMeshIDs.vao);
                    gl.GenBuffers(1, &NewMeshIDs.vbo);
                }

                //TODO
                gl.BufferData(gl.ARRAY_BUFFER, @intCast(@sizeOf(f32) * v.len), v.ptr, gl.STATIC_DRAW);
                gl.VertexAttribPointer(0, 1, gl.INT, gl.FALSE, @sizeOf(f64), 0);
                gl.EnableVertexAttribArray(0);
                 gl.VertexAttribPointer(1, 1, gl.INT, gl.FALSE, @sizeOf(f64), 0);
                gl.EnableVertexAttribArray(1);
                 gl.VertexAttribPointer(2, 1, gl.INT, gl.FALSE, @sizeOf(f64), 0);
                gl.EnableVertexAttribArray(2);
                gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 5 * @sizeOf(f64), 3 * @sizeOf(f32));
                gl.EnableVertexAttribArray(1);
                gl.BindVertexArray(0);
    }

};

pub fn main() void {
    std.debug.print("{}", .{@sizeOf(Chunk)});
}
