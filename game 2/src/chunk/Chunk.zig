const Blocks = @import("Blocks.zig").Blocks;
const std = @import("std");
const Noise = @import("./fastnoise.zig");
const gl = @import("gl");
const World = @import("./World.zig");
const ztracy = @import("ztracy");

const zm = @import("zm");
pub const ChunkSize = 32;

//3 render distances, one chunks will be loaded in, one the meshes will still be loaded, and one chunks will generate in
// if generation radis is bigger than loading radies than chunks will be compressed and written to the disk but the meshes will stay
// might have more render distances for entities

pub const ChunkState = enum(u8) {
    NotGenerated = 0,
    ToGenerate = 13,
    ReMesh = 24,
    AllAir = 1,
    Generating = 2,
    InMemoryNoMesh = 3,
    MeshOnly = 4,
    InMemoryAndMesh = 5,
    InMemoryMeshUnloaded = 8,
    Unknown = 6,
    WaitingForNeighbors = 7,
};

pub const ChunkandMeta = struct {
    chunkPtr: ?*Chunk,
    pos: [3]i32,
    neighborsmissing: ?u3,
    state: std.atomic.Value(ChunkState),
    lock: std.Thread.RwLock,
    chunkmeshesindex: ?usize,
    Unloading: bool,
};

pub const PtrState = struct {
    ChunkPtr: ?*Chunk,
    State: ChunkState,
};

pub const MeshBufferIDs = struct {
    time: i64,
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
    pub fn MeshChunk_Normal(chunk: *Chunk, allocator: std.mem.Allocator, neighbors: [6]?*Chunk) ![]u32 {
        for (0..6) |n| {
            if (neighbors[n] != null) {
                neighbors[n].?.lock.lockShared();
                defer neighbors[n].?.lock.unlockShared();
            }
        }

        const meshchunkreal = ztracy.ZoneNC(@src(), "meshchunkreal", 0x965792d);
        defer meshchunkreal.End();
        const initarraylist = ztracy.ZoneNC(@src(), "initarraylist", 0x965792d);
        var mesh = try std.ArrayList(u32).initCapacity(allocator, ChunkSize * ChunkSize * ChunkSize * 2);
        initarraylist.End();
        defer mesh.deinit();
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |y| {
                for (0..ChunkSize) |z| {
                    if (chunk.blocks[x][y][z] != Blocks.Air) {
                        if ((x == ChunkSize - 1 and neighbors[0] != null and neighbors[0].?.blocks[0][y][z] == Blocks.Air) or (x == ChunkSize - 1 and neighbors[0] == null)) {
                            _ = try mesh.appendSlice(&EncodeFace(1, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        } else if (x != ChunkSize - 1 and chunk.blocks[x + 1][y][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(1, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }

                        if ((x == 0 and neighbors[1] != null and neighbors[1].?.blocks[ChunkSize - 1][y][z] == Blocks.Air) or (x == 0 and neighbors[1] == null)) {
                            _ = try mesh.appendSlice(&EncodeFace(0, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        } else if (x != 0 and chunk.blocks[x - 1][y][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(0, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }

                        if ((y == ChunkSize - 1 and neighbors[2] != null and neighbors[2].?.blocks[x][0][z] == Blocks.Air) or (y == ChunkSize - 1 and neighbors[2] == null)) {
                            _ = try mesh.appendSlice(&EncodeFace(3, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        } else if (y != ChunkSize - 1 and chunk.blocks[x][y + 1][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(3, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }

                        if ((y == 0 and neighbors[3] != null and neighbors[3].?.blocks[x][ChunkSize - 1][z] == Blocks.Air) or (y == 0 and neighbors[3] == null)) {
                            _ = try mesh.appendSlice(&EncodeFace(2, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        } else if (y != 0 and chunk.blocks[x][y - 1][z] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(2, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }

                        if ((z == ChunkSize - 1 and neighbors[4] != null and neighbors[4].?.blocks[x][y][0] == Blocks.Air) or (z == ChunkSize - 1 and neighbors[4] == null)) {
                            _ = try mesh.appendSlice(&EncodeFace(5, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        } else if (z != ChunkSize - 1 and chunk.blocks[x][y][z + 1] == Blocks.Air) {
                            _ = try mesh.appendSlice(&EncodeFace(5, chunk.blocks[x][y][z], [3]usize{ x, y, z }));
                        }

                        if ((z == 0 and neighbors[5] != null and neighbors[5].?.blocks[x][y][ChunkSize - 1] == Blocks.Air) or (z == 0 and neighbors[5] == null)) {
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
        NewMeshIDs.time = std.time.milliTimestamp();
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

    pub fn GenChunk(Pos: [3]i32, TerrainNoise: Noise.Noise(f32), TerrainNoise2: Noise.Noise(f32), CaveNoise: Noise.Noise(f32), terrainmin: i32, terrainmax: i32, caveness: f32) ?Chunk {
        const gen = ztracy.ZoneNC(@src(), "genchunk", 0x692de);
        defer gen.End();

        // Pre-calculate chunk position offset
        const chunk_offset = @Vector(3, f32){
            @floatFromInt(Pos[0] * 32),
            @floatFromInt(Pos[1] * 32),
            @floatFromInt(Pos[2] * 32),
        };
        const init = ztracy.ZoneNC(@src(), "initchunk", 0x692de);
        // Initialize chunk with air blocks
        var chunk = InitChunkToBlock(Blocks.Air, Pos, null);
        init.End();
        var has_terrain = false;
        const terrain = ztracy.ZoneNC(@src(), "terrain", 0x692de);
        // Pre-calculate terrain heights for the entire chunk
        var terrain_heights: [ChunkSize][ChunkSize]i32 = undefined;
        for (0..ChunkSize) |xx| {
            const x = @as(f32, @floatFromInt(xx)) + chunk_offset[0];
            for (0..ChunkSize) |zz| {
                const z = @as(f32, @floatFromInt(zz)) + chunk_offset[2];
                const firstnoise = TerrainNoise.genNoise2D(x, z);
                const secondnoise = TerrainNoise2.genNoise2D(x, z);
                const P = 2.0; //Higher for stronger bias.
                const E = firstnoise * (if (secondnoise < 0.5)
                   (std.math.pow(f32,secondnoise * 2, P) / 2)
                else
                    (1 - (std.math.pow(f32,(1 - secondnoise) * 2, P) / 2)));
                terrain_heights[xx][zz] = @as(i32, @intFromFloat(((E)) * @as(f32, @floatFromInt(terrainmax - terrainmin)))) + terrainmin;
            }
        }
        terrain.End();
        const caves = ztracy.ZoneNC(@src(), "caves", 0x692dd7e);

        var rand_impl = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        // Process terrain generation in a more cache-friendly way
        for (0..ChunkSize) |xx| {
            const x = @as(f32, @floatFromInt(xx)) + chunk_offset[0];
            for (0..ChunkSize) |zz| {
                const z = @as(f32, @floatFromInt(zz)) + chunk_offset[2];
                const tn = terrain_heights[xx][zz];
                const chunk_y = @divFloor(tn, 32);

                if (chunk_y < Pos[1]) continue;

                const is_top_chunk = chunk_y > Pos[1];
                const height = if (is_top_chunk)
                    ChunkSize - 1
                else
                    @mod(tn, ChunkSize);

                // Process vertical column
                var yy: usize = 0;
                while (yy <= height) : (yy += 1) {
                    const y = @as(f32, @floatFromInt(yy)) + chunk_offset[1];
                    const cave_density = CaveNoise.genNoise3D(x, y, z);
                    if (cave_density < caveness) {
                        const block = if (!is_top_chunk) blk: {
                            var gm = (chunk.pos[1]*32)+@as(i32,@intCast(yy));
                            if(gm <= 0)gm = 1;
                            if (yy == height and (std.rand.uintAtMost(rand_impl.random(),u32,256) > gm)) break :blk Blocks.Grass;
                            if (yy > height - 5 and (std.rand.uintAtMost(rand_impl.random(),u32,512) > gm)) break :blk Blocks.Dirt;
                            break :blk Blocks.Stone;
                        } else Blocks.Stone;

                        chunk.blocks[xx][yy][zz] = block;
                        has_terrain = true;
                    }
                }
            }
        }
        caves.End();

        return if (has_terrain) chunk else null;
    }
    
};
test "ChunkGen"{
    var timer = try std.time.Timer.start();
    const chunk = Generator.GenChunk([3]i32{0,-5,0}, Noise.Noise(f32){
            .seed = 0,
            .noise_type = .perlin,
            .frequency = 0.00008,
            .fractal_type = .none,
        },
        Noise.Noise(f32){
            .seed = 0,
            .noise_type = .simplex,
            .fractal_type = .none,
            .frequency = 0.005,
        },
        Noise.Noise(f32){
            .seed = 0,
            .noise_type = .perlin,
            .frequency = 0.002,
            .fractal_type = .none,
        },
        -64,
        5024,180);
        _ = chunk;
        std.debug.print("\n\ntime: {} us", .{timer.read()/std.time.ns_per_us});
}
