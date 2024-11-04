const Blocks = @import("Blocks.zig").Blocks;
const std = @import("std");
const Noise = @import("./fastnoise.zig");
const gl = @import("gl");
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
pub const MeshBufferIDs = struct {
    vbo: c_uint,
    vao: c_uint,
    vlen: c_uint,
    pos: [3]i32,
    count: u32,
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
    pub fn MeshChunk_Normal(chunk: *Chunk, allocator: std.mem.Allocator) ![]u32 {
        var mesh = std.ArrayList(u32).init(allocator);
        defer mesh.deinit();
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |y| {
                for (0..ChunkSize) |z| {

                    // 2 is top or bottom
                    //4 is side
                    if (chunk.blocks[x][y][z] != Blocks.Air) {
                        if (x == 31) {} else if (chunk.blocks[x + 1][y][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(1, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }

                        if (x == 0) {} else if (chunk.blocks[x - 1][y][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(0, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }
                        if (y == 31) {} else if (chunk.blocks[x][y + 1][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(3, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }
                        if (y == 0) {} else if (chunk.blocks[x][y - 1][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(2, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }
                        if (z == 31) {} else if (chunk.blocks[x][y][z + 1] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(5, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }
                        if (z == 0) {} else if (chunk.blocks[x][y][z - 1] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(4, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }
                    }
                }
            }
        }
        //std.debug.print("{d}", .{mesh.items});
        //return error.w;
        return mesh.toOwnedSlice();
    }

    pub fn CreateOrUpdateMeshVBO(mesh: []u32, pos: [3]i32, indecies: c_uint, facebuffer: c_uint, MeshIDs: ?MeshBufferIDs, usage: comptime_int) MeshBufferIDs {
        var NewMeshIDs: MeshBufferIDs = undefined;
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
        std.debug.print("mesh made:{d}faces\n", .{mesh.len});
        gl.BindVertexArray(0);
        return MeshIDs orelse NewMeshIDs;
    }
};

pub const Generator = struct {
    pub fn InitChunkToBlock(block: Blocks, pos: [3]i32, neighbors: ?[6]?*Chunk) Chunk {
        return Chunk{
            .pos = pos,
            .blockdata = null,
            .blocks = [_][32][32]Blocks{[_][32]Blocks{[_]Blocks{block} ** 32} ** 32} ** 32,
            .neighbors = neighbors orelse [6]?*Chunk{ null, null, null, null, null, null },
        };
    }

    pub fn GenChunk(seed: i32, Pos: [3]i32) Chunk {
        var chunk = InitChunkToBlock(Blocks.Air, Pos, null);
        const TerrainNoise = Noise.Noise(f32){
            .seed = seed,
            .noise_type = .perlin,
            .frequency = 0.08,
            .fractal_type = .none,
        };

        for (0..32) |x| {
            for (0..32) |z| {
                const h = TerrainNoise.genNoise2DRange((@as(f32, @floatFromInt(x)) / 32) + @as(f32, @floatFromInt(Pos[0])), (@as(f32, @floatFromInt(z)) / 32) + @as(f32, @floatFromInt(Pos[2])), i32, -128, 128);
                //std.debug.print("{}", .{h});
                const d = @divFloor(h, @as(i32, 32));
                if (d == Pos[1]) {
                    const y: usize = @intCast(@mod(h, 32));
                    chunk.blocks[x][y][z] = (Blocks.Grass);
                    for (0..y) |yy| {
                        chunk.blocks[x][yy][z] = (Blocks.Stone);
                    }
                } else if (d > Pos[1]) {
                    for (0..32) |yy| {
                        chunk.blocks[x][yy][z] = (Blocks.Stone);
                    }
                }
                //else {std.debug.print("{} ", .{@divFloor(h, @as(i32, 32))});}

            }
        }
        return chunk;
    }
};

pub const Chunk = struct {
    pos: [3]i32,
    blocks: [ChunkSize][ChunkSize][ChunkSize]Blocks,
    blockdata: ?*std.AutoHashMap([3]u5, []u32),
    neighbors: [6]?*Chunk,
};
