const std = @import("std");
const RenderIDs = @import("./Chunk.zig").MeshBufferIDs;
const Chunk = @import("./Chunk.zig").Chunk;
const ChunkState = @import("./Chunk.zig").ChunkState;
const Generator = @import("./Chunk.zig").Generator;
const Render = @import("./Chunk.zig").Render;
const ChunkandMeta = @import("./Chunk.zig").ChunkandMeta;
const ChunkSize = @import("./Chunk.zig").ChunkSize;
const ztracy = @import("ztracy");
const ConcurrentHashMap = @import("../libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const Noise = @import("./fastnoise.zig");
const PtrState = @import("./Chunk.zig").PtrState;
const gl = @import("gl");
const Entitys = @import("../entities/Entitys.zig");
pub const pw = struct { player: *Entitys.Player, world: *World };
//time:2299371800 11/22/2024
pub fn DistanceOrder(playerworld: pw, a: [3]i32, b: [3]i32) std.math.Order {
    // Convert coordinates to float32 and scale them
    const aa = [3]f32{ @floatFromInt(a[0]), @floatFromInt(a[1]), @floatFromInt(a[2]) };
    const bb = [3]f32{ @floatFromInt(b[0]), @floatFromInt(b[1]), @floatFromInt(b[2]) };
    const player_location = [3]f32{ playerworld.player.pos[0] / 32, playerworld.player.pos[1] / 32, playerworld.player.pos[2] / 32 };

    const d1 = @sqrt(std.math.pow(f32, player_location[0] - aa[0], 2.0) + std.math.pow(f32, player_location[1] - aa[1], 2.0) + std.math.pow(f32, player_location[2] - aa[2], 2.0));
    const d2 = @sqrt(std.math.pow(f32, player_location[0] - bb[0], 2.0) + std.math.pow(f32, player_location[1] - bb[1], 2.0) + std.math.pow(f32, player_location[2] - bb[2], 2.0));

    if (d1 < d2) {
        return std.math.Order.lt;
    } else if (d1 > d2) {
        return std.math.Order.gt;
    } else {
        return std.math.Order.eq;
    }
}
pub const ChunkMesh = struct {
    position: [3]i32,
    faces: []u32,
};
pub const World = struct {
    ChunkMeshes: std.ArrayList(RenderIDs),
    Chunks: ConcurrentHashMap([3]i32, *ChunkandMeta, std.hash_map.AutoContext([3]i32), 80, 32),
    Entitys: std.AutoHashMap(Entitys.EntityUUID, type),
    ToGen: std.PriorityQueue([3]i32, pw, DistanceOrder),
    ToGenMutex: std.Thread.Mutex,
    MeshesToLoad: std.DoublyLinkedList(ChunkMesh),
    MeshesToLoadMutex: std.Thread.Mutex,
    ToMesh: std.DoublyLinkedList(*Chunk),
    ToMeshMutex: std.Thread.Mutex,
    TerrainNoise: Noise.Noise(f32),
    CaveNoise: Noise.Noise(f32),
    caveness: u8,
    min: i32,
    max: i32,
    pub fn GenChunk(self: *@This(), player: Entitys.Player, allocator: std.mem.Allocator) !void {
        while (true) {
            const GenChunktime = ztracy.ZoneNC(@src(), "GenChunk", 0x9692de);
            defer GenChunktime.End();
            self.ToGenMutex.lock();
            const chunkpos = self.ToGen.removeOrNull() orelse {
                self.ToGenMutex.unlock();
                std.time.sleep(2 * std.time.ns_per_ms);
                continue;
            };

            self.ToGenMutex.unlock();
            //need to fix mutexes with new system TODO
            //seed 0
            const chunk: Chunk = Generator.GenChunk(chunkpos, self.TerrainNoise, self.CaveNoise, self.min, self.max, self.caveness) orelse {
                self.Chunks.get(chunkpos).?.state = ChunkState.AllAir;
                const neighbors = GetNeighbors(self, chunkpos);
                for (0..6) |i| {
                    if (neighbors[i] != null and neighbors[i].?.state == ChunkState.WaitingForNeighbors) {
                        neighbors[i].?.state = ChunkState.ReMesh;
                        const cn = try allocator.create(std.DoublyLinkedList(*Chunk).Node);
                        cn.data = neighbors[i].?.chunkPtr.?;
                        self.ToMeshMutex.lock();
                        self.ToMesh.append(cn);
                        self.ToMeshMutex.unlock();
                    }
                }
                continue;
            };
            _ = player;
            //uses TONS of memory, TODO fix memory usage
            const ap = ztracy.ZoneNC(@src(), "allocanput", 0x9692d);
            const chptr = try allocator.create(Chunk);
            chptr.* = chunk;
            const p = self.Chunks.get(chunkpos).?;
            p.state = ChunkState.Generating;
            p.chunkPtr = chptr;
            ap.End();
            const WAITFORTOMESHMUTEX = ztracy.ZoneNC(@src(), "WAITFORTOMESHMUTEX", 0x9692d);
            WAITFORTOMESHMUTEX.End();
            const cn = try allocator.create(std.DoublyLinkedList(*Chunk).Node);
            cn.data = chptr;
            self.ToMeshMutex.lock();
            self.ToMesh.append(cn);
            self.ToMeshMutex.unlock();
        }
    }

    pub fn MeshChunks(self: *@This(), sleeptime: u64, allocator: std.mem.Allocator) !void {
        top: while (true) {
            const meshchunk = ztracy.ZoneNC(@src(), "meshchunk", 0x9692d);
            defer meshchunk.End();
            const WAITFORTOMESHMUTEX = ztracy.ZoneNC(@src(), "WAITFORTOMESHMUTEX", 0x9692d);
            self.ToMeshMutex.lock();
            WAITFORTOMESHMUTEX.End();
            const chnode = self.ToMesh.popFirst() orelse {
                self.ToMeshMutex.unlock();
                const sleeping = ztracy.ZoneNC(@src(), "sleeping", 0x9832fd2d);
                std.time.sleep(sleeptime);
                sleeping.End();
                continue;
            };
            self.ToMeshMutex.unlock();
            const chptr: *Chunk = chnode.data;
            allocator.destroy(chnode);
            const chstate = self.Chunks.get(chptr.pos) orelse unreachable;
            const neighbors:[6]?*ChunkandMeta = GetNeighbors(self, chptr.pos);
            var neighborptrs: [6]?*Chunk = [6]?*Chunk{ null, null, null, null, null, null };
            var wfn: u3 = 0;
            for (0..6) |i| {
                
                if (neighbors[i] != null and neighbors[i].?.chunkPtr != null) {
                    neighborptrs[i] = neighbors[i].?.chunkPtr.?;
                } else if (neighbors[i] == null or neighbors[i].?.state != ChunkState.AllAir) {
                    wfn += 1;
                }

                if (neighbors[i] != null and neighbors[i].?.state == ChunkState.WaitingForNeighbors and chstate.state == ChunkState.Generating) {

                        neighbors[i].?.state = ChunkState.ReMesh;
                        const cn = try allocator.create(std.DoublyLinkedList(*Chunk).Node);
                        cn.data = neighbors[i].?.chunkPtr.?;
                        self.ToMeshMutex.lock();
                        self.ToMesh.append(cn);
                        self.ToMeshMutex.unlock();
            }}
            if (wfn > 0) {             
                    chstate.neighborsmissing = wfn;   
                    chstate.state = ChunkState.WaitingForNeighbors;
                continue :top;
            }
            std.debug.assert(wfn == 0);
            const mesh = try Render.MeshChunk_Normal(chptr, allocator, neighborptrs);

            if (mesh.len == 0) {
                chstate.state = ChunkState.InMemoryNoMesh;
                allocator.free(mesh);
                continue :top;
            }
            const putmesh = ztracy.ZoneNC(@src(), "putmesh", 0x9692d);
            defer putmesh.End();
            chstate.state = ChunkState.InMemoryAndMesh;
            var node = try allocator.create(std.DoublyLinkedList(ChunkMesh).Node);
            node.data = ChunkMesh{ .faces = mesh, .position = chptr.pos };
            self.MeshesToLoadMutex.lock();
            self.MeshesToLoad.append((node));
            self.MeshesToLoadMutex.unlock();
        }
    }
    pub fn GetNeighbors(self: *@This(), pos: [3]i32) [6]?*ChunkandMeta {
        const getneighbors = ztracy.ZoneNC(@src(), "getneighbors", 0xFFFF00);
        defer getneighbors.End();
        var chunks: [6]?*ChunkandMeta = undefined;
        // BUG chunks are gotten before state TODO fix
        //if chunk state changes after ptr is gotten state and ptr could mismaatch
        //might need to change big parts of the system
            chunks[0] = self.Chunks.get([3]i32{ pos[0] + 1, pos[1], pos[2] });
            chunks[1] = self.Chunks.get([3]i32{ pos[0] - 1, pos[1], pos[2] });
            chunks[2] = self.Chunks.get([3]i32{ pos[0], pos[1] + 1, pos[2] });
            chunks[3] = self.Chunks.get([3]i32{ pos[0], pos[1] - 1, pos[2] });
            chunks[4] = self.Chunks.get([3]i32{ pos[0], pos[1], pos[2] + 1 });
            chunks[5] = self.Chunks.get([3]i32{ pos[0], pos[1], pos[2] - 1 });

        return chunks;
    }


    pub fn LoadMeshes(self: *@This(), ebo: c_uint, facebuffer: c_uint, allocator: std.mem.Allocator, maxtime: u64) !void {
        const loadmeshes = ztracy.ZoneNC(@src(), "LoadMeshes", 0x4aeb2a);
        defer loadmeshes.End();
        var timer = try std.time.Timer.start();
        //std.debug.print("{any}", .{self.MeshesToLoad.last});
        //const len: u32 = @intCast((self.ToLoad orelse return).len);
        var i: u32 = 0;
        while (timer.read() < maxtime) {
            const loadmesh = ztracy.ZoneNC(@src(), "loadmesh", 0xFF0000);
            defer loadmesh.End();
            //std.debug.print("\n||{}\n", .{i});
            self.MeshesToLoadMutex.lock();
            const mesh = self.MeshesToLoad.popFirst() orelse {
                self.MeshesToLoadMutex.unlock();
                return;
            };
            self.MeshesToLoadMutex.unlock();
            std.debug.assert(mesh.data.faces.len > 0);
            const vbo = Render.CreateOrUpdateMeshVBO(mesh.data.faces, mesh.data.position, ebo, facebuffer, null, gl.STATIC_DRAW);
            allocator.destroy(mesh);
            _ = try self.ChunkMeshes.append(vbo);
            i += 1;
        }
    }

    pub fn AddToGen(self: *@This(), player: *Entitys.Player, sleeptime: u64, allocator: std.mem.Allocator) !void {
        while (true) {
            std.time.sleep(sleeptime);

            const Addtogen = ztracy.ZoneNC(@src(), "Addtogen", 0x9692de);
            defer Addtogen.End();

            var x = -@as(i32, @intCast(player.GenDistance[0]));
            var y = -@as(i32, @intCast(player.GenDistance[1]));
            var z = -@as(i32, @intCast(player.GenDistance[2]));
            while (x < player.GenDistance[0]) {
                while (y < player.GenDistance[1]) {
                    while (z < player.GenDistance[2]) {
                        var pos = [3]i32{ @as(i32, @intCast(x)), @as(i32, @intCast(y)), @as(i32, @intCast(z)) };
                        pos[0] += @as(i32, @intFromFloat(player.pos[0] / 32.0));
                        pos[1] += @as(i32, @intFromFloat(player.pos[1] / 32.0));
                        pos[2] += @as(i32, @intFromFloat(player.pos[2] / 32.0));

                        z += 1;
                        self.ToGenMutex.lock();
                        defer self.ToGenMutex.unlock();
                        _ = self.Chunks.get(pos) orelse {
                            const c = try allocator.create(ChunkandMeta);
                            c.state = ChunkState.ToGenerate;
                            c.chunkmeshesindex = null;
                            c.neighborsmissing = null;
                            c.chunkPtr = null;
                            c.lock = .{};
                            _ = try self.Chunks.put(pos,c);
                            _ = try self.ToGen.add(pos);
                            continue;
                        };
                    }
                    y += 1;
                    z = -@as(i32, @intCast(player.GenDistance[2]));
                }
                x += 1;
                y = -@as(i32, @intCast(player.GenDistance[1]));
            }
        }
    }
};
