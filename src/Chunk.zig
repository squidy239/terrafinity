const std = @import("std");
const cache = @import("cache");

const gl = @import("gl");
const zm = @import("zm");
const ztracy = @import("ztracy");

const Noise = @import("./fastnoise.zig");
const World = @import("./World.zig");
const Blocks = @import("Blocks.zig").Blocks;

pub const ChunkSize = 32;

//3 render distances, one chunks will be loaded in, one the meshes will still be loaded, and one chunks will generate in
// if generation radis is bigger than loading radies than chunks will be compressed and written to the disk but the meshes will stay
// might have more render distances for entities

pub const ChunkState = enum(u8) {
    NotGenerated = 0,
    ToGenerate = 13,
    ReMesh = 24,
    AllAir = 1,
    MeshAgain = 12,
    InMemoryMeshLoading = 11,
    Generating = 2,
    InMemoryNoMesh = 3,
    MeshOnly = 4,
    InMemoryMeshGenerating = 9,
    InMemoryAndMesh = 5,
    InMemoryMeshUnloaded = 8,
    Unknown = 6,
    GeneratingAndMesh = 10,
    WaitingForNeighbors = 7,
};

pub const CompressionType = enum(u8) {
    None = 0,
    Flate = 1,
};

pub const Chunk = struct {
    ChunkData: ?[]u8,
    CompressionType: CompressionType,
    pos: [3]i32,
    neighborsmissing: ?u3,
    state: std.atomic.Value(ChunkState),
    lock: std.Thread.RwLock,
    Unloading: bool,
    ref_count: std.atomic.Value(u32),
    scale: f32,
    pub fn EncodeAndPutBlocks(self: *@This(), blocks: [32][32][32]Blocks, commtype: CompressionType, allocator: std.mem.Allocator, lock: bool) !void {
        const encodeandputblocks = ztracy.ZoneNC(@src(), "encodeandputblocks", 1838292929);
        defer encodeandputblocks.End();
        if (lock) {
            self.lock.lock();
            defer self.lock.unlock();
        }
        switch (commtype) {
            CompressionType.None => {
                const by = std.mem.toBytes(blocks);
                const alloc = ztracy.ZoneNC(@src(), "alloc", 737737373);
                const p = try allocator.alloc(u8, by.len);
                alloc.End();
                @memcpy(p, &by);
                self.CompressionType = commtype;
                self.ChunkData = p;
            },
            CompressionType.Flate => {
                var list = std.ArrayList(u8).init(allocator);
                defer list.deinit();

                var compressor = try std.compress.zlib.compressor(list.writer(), .{ .level = .fast });
                _ = try compressor.write(&std.mem.toBytes(blocks));
                _ = try compressor.finish();
                self.CompressionType = commtype;
                self.ChunkData = try list.toOwnedSlice();
            },

            //else => {@branchHint(.cold);std.debug.panic("\n\nInvalid CompressionType: {}\n", .{commtype});},
        }
    }
    pub fn DecodeAndGetBlocks(self: *@This()) ?*align(1) [32][32][32]Blocks {
        const decodeandgetblocks = ztracy.ZoneNC(@src(), "decodeandgetblocks", 1838292929);
        defer decodeandgetblocks.End();
        self.lock.lockShared();
        defer self.lock.unlockShared();
        switch (self.CompressionType) {
            CompressionType.None => return std.mem.bytesAsValue([32][32][32]Blocks, self.ChunkData orelse return null),
            CompressionType.Flate => {
                std.debug.panic("Flate decoding not working", .{});
                //too slow bc of memcpy
            },
            //else => {
            //    @branchHint(.cold);
            //     std.debug.panic("\n\nInvalid CompressionType: {}\n", .{self.CompressionType});
            // },
        }
    }
    pub fn addRef(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    pub fn release(self: *@This()) void {
        _ = self.ref_count.fetchSub(1, .seq_cst);
    }
    pub fn clean(self: *@This(), chunk: *Chunk, allocator: std.mem.Allocator) void {
        const state = chunk.state.load(.seq_cst);

        switch (state) {
            ChunkState.InMemoryAndMesh => {
                chunk.lock.lock();
                defer chunk.lock.unlock();
                chunk.state.store(ChunkState.MeshOnly, .seq_cst);
                allocator.free(chunk.ChunkData.?);
                chunk.ChunkData = null;
            },

            ChunkState.InMemoryMeshUnloaded, ChunkState.InMemoryNoMesh, ChunkState.WaitingForNeighbors => {
                _ = self.Chunks.remove(chunk.pos);
                chunk.lock.lock();
                allocator.free(chunk.ChunkData.?);
                allocator.destroy(chunk);
            },
            ChunkState.AllAir => {
                std.debug.assert(chunk.ChunkData == null);
                _ = self.Chunks.remove(chunk.pos);
                chunk.lock.lock();
                allocator.destroy(chunk);
            },
        }
    }
};

pub const MeshBufferIDs = struct {
    time: i64,
    vbo: [2]?c_uint,
    vao: [2]?c_uint,
    pos: [3]i32,
    count: [2]u32,
    scale: f32,
};

pub const Render = struct {
    const vertices = [_]f32{
        -0.5, -0.5, 0.0, // bottom left corner
        -0.5, 0.5, 0.0, // top left corner
        0.5, 0.5,  0.0, // top right corner
        0.5, -0.5, 0.0,
    }; // bottom right corner
    fn EncodeAndPutFace(side: u3, blocktype: Blocks, pos: [3]usize, mesh: *std.ArrayList(u32), transparentmesh: *std.ArrayList(u32)) !void {
        var EncodedBlock = [2]u32{ 0, 0 };
        //bitpacking structure
        //pos|5 x 5 y 5 z| face|3| blocktype|20| 26 leftover bits
        EncodedBlock[0] |= @as(u32, @intCast(pos[0])) << (@bitSizeOf(u32) - 5);
        EncodedBlock[0] |= @as(u32, @intCast(pos[1])) << (@bitSizeOf(u32) - 10);
        EncodedBlock[0] |= @as(u32, @intCast(pos[2])) << (@bitSizeOf(u32) - 15);
        //block type bits
        EncodedBlock[0] |= @as(u32, @intCast(side)) << (@bitSizeOf(u32) - 18);
        EncodedBlock[1] |= @as(u32, @intCast(@intFromEnum(blocktype))) << (@bitSizeOf(u32) - 20);
        if (IsTransparentNoCompare(blocktype)) {
            @branchHint(.unlikely);
            _ = try transparentmesh.append(EncodedBlock[0]);
            _ = try transparentmesh.append(EncodedBlock[1]);
        } else {
            @branchHint(.likely);
            _ = try mesh.append(EncodedBlock[0]);
            _ = try mesh.append(EncodedBlock[1]);
        }
    }

    inline fn IsTransparentNoCompare(block: Blocks) bool {
        return switch (block) {
            Blocks.Air, Blocks.Water, Blocks.Leaves => true,
            else => false,
        };
    }

    inline fn IsTransparent(block: Blocks, block2: Blocks) bool {
        return switch (block) {
            Blocks.Air, Blocks.Water, Blocks.Leaves => !(block == block2),
            else => false,
        };
    }

    fn IsAir(block: Blocks) bool {
        return block == Blocks.Air;
    }
    //nehbors +x -x +y -y +z -z
    //        0   1  2  3  4  5
    pub fn MeshChunk_Normal(chunk: *Chunk, allocator: std.mem.Allocator, neighbors: [6]?*Chunk) ![2]?[]u32 {
        const meshchunkreal = ztracy.ZoneNC(@src(), "meshchunkreal", 0x965792d);
        defer meshchunkreal.End();
        const convertfrombytes = ztracy.ZoneNC(@src(), "convertfrombytes", 2387947234);
        //std.debug.print("{any}", .{neighbors});
        //std.compress.flate.decompress(std.io.bufferedReader(chunk.ChunkData),std.io.bufferedWriter(&blocks));
        const blocks = chunk.DecodeAndGetBlocks() orelse return error.nullblocks;

        var neighborblocks: [6]*align(1) [32][32][32]Blocks = undefined;
        for (0..6) |n| {
            if (neighbors[n] != null and neighbors[n].?.ChunkData != null) {
                neighborblocks[n] = neighbors[n].?.DecodeAndGetBlocks() orelse return error.nullblocks;
            }
        }
        convertfrombytes.End();

        const initarraylist = ztracy.ZoneNC(@src(), "initarraylist", 0x965792d);
        var buffer: [ChunkSize * ChunkSize * ChunkSize * 6 * @sizeOf(u32) * 2]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        var mesh = try std.ArrayList(u32).initCapacity(fba.allocator(), ChunkSize * ChunkSize * ChunkSize * 6);
        var transparentmesh = try std.ArrayList(u32).initCapacity(fba.allocator(), ChunkSize * ChunkSize * ChunkSize * 6);
        defer mesh.deinit();
        defer transparentmesh.deinit();

        initarraylist.End();
        for (0..ChunkSize) |x| {
            for (0..ChunkSize) |y| {
                for (0..ChunkSize) |z| {
                    if (blocks[x][y][z] != Blocks.Air) {
                        @branchHint(.likely);
                        if (false and blocks[x][y][z] == Blocks.Leaves) {
                            @branchHint(.unlikely);
                            _ = try EncodeAndPutFace(1, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                            _ = try EncodeAndPutFace(0, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                            _ = try EncodeAndPutFace(3, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                            _ = try EncodeAndPutFace(2, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                            _ = try EncodeAndPutFace(5, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                            _ = try EncodeAndPutFace(4, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                            continue;
                        }
                        if ((x == ChunkSize - 1 and neighbors[0] != null and IsTransparent(neighborblocks[0][0][y][z], blocks[x][y][z])) or (x == ChunkSize - 1 and neighbors[0] == null)) {
                            @branchHint(.unlikely);
                            _ = try EncodeAndPutFace(1, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                        } else if (x != ChunkSize - 1 and IsTransparent(blocks[x + 1][y][z], blocks[x][y][z])) {
                            _ = try EncodeAndPutFace(1, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                        }

                        if ((x == 0 and neighbors[1] != null and IsTransparent(neighborblocks[1][ChunkSize - 1][y][z], blocks[x][y][z])) or (x == 0 and neighbors[1] == null)) {
                            @branchHint(.unlikely);
                            _ = try EncodeAndPutFace(0, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                        } else if (x != 0 and IsTransparent(blocks[x - 1][y][z], blocks[x][y][z])) {
                            _ = try EncodeAndPutFace(0, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                        }

                        if ((y == ChunkSize - 1 and neighbors[2] != null and IsTransparent(neighborblocks[2][x][0][z], blocks[x][y][z])) or (y == ChunkSize - 1 and neighbors[2] == null)) {
                            @branchHint(.unlikely);
                            _ = try EncodeAndPutFace(3, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                        } else if (y != ChunkSize - 1 and IsTransparent(blocks[x][y + 1][z], blocks[x][y][z])) {
                            _ = try EncodeAndPutFace(3, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                        }

                        if ((y == 0 and neighbors[3] != null and IsTransparent(neighborblocks[3][x][ChunkSize - 1][z], blocks[x][y][z])) or (y == 0 and neighbors[3] == null)) {
                            @branchHint(.unlikely);
                            _ = try EncodeAndPutFace(2, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                        } else if (y != 0 and IsTransparent(blocks[x][y - 1][z], blocks[x][y][z])) {
                            _ = try EncodeAndPutFace(2, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                        }

                        if ((z == ChunkSize - 1 and neighbors[4] != null and IsTransparent(neighborblocks[4][x][y][0], blocks[x][y][z])) or (z == ChunkSize - 1 and neighbors[4] == null)) {
                            @branchHint(.unlikely);
                            _ = try EncodeAndPutFace(5, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                        } else if (z != ChunkSize - 1 and IsTransparent(blocks[x][y][z + 1], blocks[x][y][z])) {
                            _ = try EncodeAndPutFace(5, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                        }

                        if ((z == 0 and neighbors[5] != null and IsTransparent(neighborblocks[5][x][y][ChunkSize - 1], blocks[x][y][z])) or (z == 0 and neighbors[5] == null)) {
                            @branchHint(.unlikely);
                            _ = try EncodeAndPutFace(4, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                        } else if (z != 0 and IsTransparent(blocks[x][y][z - 1], blocks[x][y][z])) {
                            _ = try EncodeAndPutFace(4, blocks[x][y][z], [3]usize{ x, y, z }, &mesh, &transparentmesh);
                        }
                    }
                }
            }
        }
        mesh.shrinkAndFree(mesh.items.len);
        transparentmesh.shrinkAndFree(transparentmesh.items.len);
        return [2]?[]u32{ if (mesh.items.len == 0) null else try allocator.dupe(u32, mesh.items), if (transparentmesh.items.len == 0) null else try allocator.dupe(u32, transparentmesh.items) };
    }

    pub fn CreateMeshVBOs(mesh: ?[]u32, transparentmesh: ?[]u32, pos: [3]i32, indecies: c_uint, facebuffer: c_uint, scale: f32, usage: comptime_int, animation: bool) MeshBufferIDs {
        //TODO optimize by batching
        const createvbo = ztracy.ZoneNC(@src(), "createvbo", 0x00_ff_00_00);
        defer createvbo.End();
        var NewMeshIDs: MeshBufferIDs = .{
            .vao = [2]?c_uint{ 0, 0 },
            .vbo = [2]?c_uint{ 0, 0 },
            .count = [2]u32{ 0, 0 },
            .scale = scale,
            .pos = pos,
            .time = 0,
        };
        const mm = ztracy.ZoneNC(@src(), "opaque", 0x00_ff_00_00);

        if (mesh != null) {
            gl.GenVertexArrays(1, @ptrCast(&NewMeshIDs.vao[0].?));
            const o = ztracy.ZoneNC(@src(), "1", 0x00_ff_00_00);
            gl.GenBuffers(1, @ptrCast(&NewMeshIDs.vbo[0].?));
            o.End();
            gl.BindVertexArray(NewMeshIDs.vao[0].?);
            gl.BindBuffer(gl.ARRAY_BUFFER, NewMeshIDs.vbo[0].?);
            gl.BufferData(gl.ARRAY_BUFFER, @intCast(@sizeOf(u32) * mesh.?.len), mesh.?.ptr, usage);
            NewMeshIDs.count[0] = @intCast(mesh.?.len);
            gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, indecies);
            gl.BindBuffer(gl.ARRAY_BUFFER, facebuffer);
            gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(f32), 0);
            gl.EnableVertexAttribArray(0);
            gl.BindBuffer(gl.ARRAY_BUFFER, NewMeshIDs.vbo[0].?);
            gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(u32), 0);
            gl.EnableVertexAttribArray(1);
            gl.VertexAttribDivisor(1, 1);
            //std.debug.print("mesh made:{d}faces\n", .{mesh.len});
        } else {
            NewMeshIDs.vao[0] = null;
            NewMeshIDs.vbo[0] = null;
        }
        mm.End();

        const t = ztracy.ZoneNC(@src(), "transparent", 0x00_ff_00_00);
        if (transparentmesh != null) {
            gl.GenVertexArrays(1, @ptrCast(&NewMeshIDs.vao[1]));
            gl.GenBuffers(1, @ptrCast(&NewMeshIDs.vbo[1]));
            gl.BindVertexArray(NewMeshIDs.vao[1].?);
            gl.BindBuffer(gl.ARRAY_BUFFER, NewMeshIDs.vbo[1].?);
            gl.BufferData(gl.ARRAY_BUFFER, @intCast(@sizeOf(u32) * transparentmesh.?.len), transparentmesh.?.ptr, usage);
            NewMeshIDs.pos = pos;
            NewMeshIDs.scale = scale;
            NewMeshIDs.count[1] = @intCast(transparentmesh.?.len);
            gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, indecies);
            gl.BindBuffer(gl.ARRAY_BUFFER, facebuffer);
            gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(f32), 0);
            gl.EnableVertexAttribArray(0);
            gl.BindBuffer(gl.ARRAY_BUFFER, NewMeshIDs.vbo[1].?);
            gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(u32), 0);
            gl.EnableVertexAttribArray(1);
            gl.VertexAttribDivisor(1, 1);
        } else {
            NewMeshIDs.vao[1] = null;
            NewMeshIDs.vbo[1] = null;
        }
        t.End();
        gl.BindBuffer(gl.ARRAY_BUFFER, 0);
        gl.BindVertexArray(0);
        if (animation) NewMeshIDs.time = std.time.milliTimestamp();
        return NewMeshIDs;
    }
};
pub const Generator = struct {
    pub fn InitChunk(pos: [3]i32) Chunk {
        return Chunk{
            .pos = pos,
            .ChunkData = null,
            .lock = .{},
            .CompressionType = CompressionType.None,
            .state = .{ .raw = ChunkState.Generating },
            .Unloading = false,
            .scale = 1.0,
            .neighborsmissing = null,
        };
        //this is annoying but zig dosent compile for relesefast when i directly initalize the array // old comment will remove
    }

    fn generateTree(chunkblocks: *[32][32][32]Blocks, x: usize, z: usize, height: i32, scale: f32, rand: *std.Random.DefaultPrng) void {
        // Determine tree type and size based on randomness
        if (scale > 16.0) return;
        const tree_type = @as(u8, @intFromFloat(@as(f32, @floatFromInt(rand.random().intRangeAtMost(u8, 0, 1))) / scale));
        const tree_height = @as(u8, @intFromFloat(@as(f32, @floatFromInt(rand.random().intRangeAtMost(u8, 4, 16))) / scale));
        const trunk_height = tree_height - @as(u8, @intFromFloat(2.0 / scale));
        const canopy_width = tree_height / 2;

        // Find the top surface block
        const surface_y = height;

        // Generate trunk
        var yy: usize = 0;
        while (yy < trunk_height) : (yy += 1) {
            if (surface_y + @as(i32, @intCast(yy)) < chunkblocks[0].len) {
                chunkblocks[x][@as(usize, @intCast(surface_y)) + yy][z] = Blocks.Wood; //log
            }
        }

        // Generate canopy based on tree type
        switch (tree_type) {
            0 => { // Spherical canopy
                var layer_width: i8 = @intCast(canopy_width);
                while (layer_width >= 0) : (layer_width -= 1) {
                    const layer_y = @as(usize, @intCast(surface_y + trunk_height + layer_width));

                    // Skip if out of chunk bounds
                    if (layer_y >= chunkblocks[0].len) continue;

                    // Generate circular layer of leaves
                    var dx: i8 = -layer_width;
                    while (dx <= layer_width) : (dx += 1) {
                        var dz: i8 = -layer_width;
                        while (dz <= layer_width) : (dz += 1) {
                            // Use circular coverage
                            if (dx *| dx +| dz * dz <= layer_width * layer_width) {
                                const leaf_x = @as(i32, @intCast(x)) + dx;
                                const leaf_z = @as(i32, @intCast(z)) + dz;

                                // Ensure we're within chunk bounds
                                if (leaf_x < chunkblocks.len and leaf_z < chunkblocks[0][0].len and leaf_x > 0 and leaf_z > 0) {
                                    chunkblocks[@intCast(leaf_x)][(layer_y)][@intCast(leaf_z)] = Blocks.Leaves; //leavs
                                }
                            }
                        }
                    }
                }
            },
            1 => { // Conical canopy
                var layer: u8 = 0;
                while (layer < canopy_width) : (layer += 1) {
                    const layer_y = surface_y + trunk_height + layer;

                    // Skip if out of chunk bounds
                    if (layer_y >= chunkblocks[0].len) continue;

                    // Triangular/conical shape
                    const current_width = canopy_width - layer;

                    var dx: i8 = -@as(i8, @intCast(current_width));
                    while (dx <= current_width) : (dx += 1) {
                        var dz: i8 = -@as(i8, @intCast(current_width));
                        while (dz <= current_width) : (dz += 1) {
                            const leaf_x = @as(i32, @intCast(x)) + dx;
                            const leaf_z = @as(i32, @intCast(z)) + dz;

                            // Ensure we're within chunk bounds
                            if (leaf_x < chunkblocks.len and leaf_z < chunkblocks[0][0].len and leaf_x > 0 and leaf_z > 0) {
                                chunkblocks[@intCast(leaf_x)][@intCast(layer_y)][@intCast(leaf_z)] = Blocks.Leaves; //leavs
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    pub fn GenChunk(Pos: [3]i32, TerrainHeightCache: *cache.Cache([32][32]i32), TerrainHeightCacheMutex: *std.Thread.Mutex, TerrainNoise: Noise.Noise(f32), TerrainNoise2: Noise.Noise(f32), CaveNoise: Noise.Noise(f32), terrainmin: i32, terrainmax: i32, caveness: f32, scale: f32, caves: bool, trees: bool) ?[32][32][32]Blocks {
        const gen = ztracy.ZoneNC(@src(), "genchunk", 0x692de);
        defer gen.End();
        // Pre-calculate chunk position offset
        //@setFloatMode(.optimized);
        const chunk_offset = @Vector(3, f32){
            @floatFromInt(Pos[0] << 5), // times 32 bitshift
            @floatFromInt(Pos[1] << 5),
            @floatFromInt(Pos[2] << 5),
        };

        const thdiff = @as(f32, @floatFromInt(terrainmax - terrainmin)) / scale;
        var blocks: [32][32][32]Blocks = undefined;
        @memset(&blocks, @splat(@splat(if (chunk_offset[1] < 0) Blocks.Water else Blocks.Air)));
        //
        var has_terrain = chunk_offset[1] < 0;
        const terrain = ztracy.ZoneNC(@src(), "terrain", 0x692de);
        // Pre-calculate terrain heights for the entire chunk
        var terrain_heights: [ChunkSize][ChunkSize]i32 = undefined;
        TerrainHeightCacheMutex.lock();
        if (TerrainHeightCache.get(&std.mem.toBytes([2]i32{ Pos[0], Pos[2] }))) |c| {
            @branchHint(.likely);
            terrain_heights = c.value;
            c.release();
            TerrainHeightCacheMutex.unlock();
        } else {
            TerrainHeightCacheMutex.unlock();

            for (0..ChunkSize) |xx| {
                const x = @as(f32, @floatFromInt(xx)) + chunk_offset[0];
                for (0..ChunkSize) |zz| {
                    const z = @as(f32, @floatFromInt(zz)) + chunk_offset[2];
                    _ = TerrainNoise;
                    const noise = TerrainNoise2.genNoise2D(x * scale, z * scale);
                    terrain_heights[xx][zz] = @as(i32, @intFromFloat(noise * thdiff)) + terrainmin;
                }
            }
            TerrainHeightCacheMutex.lock();
            _ = TerrainHeightCache.put(&std.mem.toBytes([2]i32{ Pos[0], Pos[2] }), terrain_heights, .{ .ttl = 20 }) catch |err| {
                std.debug.panic("{any}\n", .{err});
            };
            TerrainHeightCacheMutex.unlock();
        }
        terrain.End();
        const cavess = ztracy.ZoneNC(@src(), "caves", 0x692dd7e);

        var rand_impl = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));

        // Tree generation parameters
        const tree_chance = 0.01 * scale; // 10% chance of tree generation

        // Process terrain generation in a more cache-friendly way
        for (0..ChunkSize) |xx| {
            const x = @as(f32, @floatFromInt(xx)) + chunk_offset[0];
            for (0..ChunkSize) |zz| {
                const z = @as(f32, @floatFromInt(zz)) + chunk_offset[2];
                const tn = terrain_heights[xx][zz];
                const chunk_y = @divFloor(tn, ChunkSize);

                if (chunk_y < Pos[1]) continue;

                const is_top_chunk = chunk_y > Pos[1];
                const height = if (is_top_chunk)
                    ChunkSize - 1
                else
                    @mod(tn, ChunkSize);
                std.debug.assert(height < ChunkSize);
                std.debug.assert(xx < ChunkSize and zz < ChunkSize);
                // Process vertical column
                var yy: usize = 0;
                while (yy <= height) : (yy += 1) {
                    const y = @as(f32, @floatFromInt(yy)) + chunk_offset[1];
                    const cave_density = if (caves) CaveNoise.genNoise3D(x * scale, y * scale, z * scale) else 0.0;
                    if (cave_density < caveness) {
                        blocks[xx][yy][zz] = if (!is_top_chunk) blk: {
                            var gm = @as(i32, @intFromFloat(@as(f32, @floatFromInt(Pos[1] * ChunkSize)) * scale)) + @as(i32, @intCast(yy));
                            if (gm <= 0) gm = 1;
                            if (yy == height and (std.Random.uintAtMost(rand_impl.random(), u32, 256) > gm) and Pos[1] >= 0) {
                                break :blk Blocks.Grass;
                            } else if (yy > height - 5 and (std.Random.uintAtMost(rand_impl.random(), u32, 512) > gm)) break :blk Blocks.Dirt;
                            break :blk Blocks.Stone;
                        } else Blocks.Stone;

                        has_terrain = true;
                    } else blocks[xx][yy][zz] = Blocks.Air;
                }

                // Tree generation
                if (trees and Pos[1] >= 0 and !is_top_chunk and
                    blocks[xx][@intCast(height)][zz] == Blocks.Grass and
                    rand_impl.random().float(f32) < tree_chance)
                {
                    generateTree(&blocks, xx, zz, @as(i32, @intFromFloat(@as(f32, @floatFromInt(height)) / scale)), scale, &rand_impl);
                }
            }
        }
        cavess.End();
        return if (has_terrain) blocks else null;
    }
};
test "ChunkGen" {
    var timer = try std.time.Timer.start();
    const chunk = Generator.GenChunk([3]i32{ 0, -5, 0 }, Noise.Noise(f32){
        .seed = 0,
        .noise_type = .perlin,
        .frequency = 0.00008,
        .fractal_type = .none,
    }, Noise.Noise(f32){
        .seed = 0,
        .noise_type = .simplex,
        .fractal_type = .none,
        .frequency = 0.005,
    }, Noise.Noise(f32){
        .seed = 0,
        .noise_type = .perlin,
        .frequency = 0.002,
        .fractal_type = .none,
    }, -64, 5024, 180);
    _ = chunk;
    std.debug.print("\n\ntime: {} us", .{timer.read() / std.time.ns_per_us});
}
