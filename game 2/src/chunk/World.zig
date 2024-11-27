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
pub fn Distance(c1: [3]i32, c2: [3]i32) f32 {
    const dx: f32 = @floatFromInt(c2[0] - c1[0]);
    const dy: f32 = @floatFromInt(c2[1] - c1[1]);
    const dz: f32 = @floatFromInt(c2[2] - c1[2]);
    return @sqrt(dx * dx + dy * dy + dz * dz);
}
pub fn DistanceOrder(playerworld: pw, a: [3]i32, b: [3]i32) std.math.Order {
    // Convert coordinates to float32 and scale them
    const pi = [3]i32{ @intFromFloat(playerworld.player.pos[0]), @intFromFloat(playerworld.player.pos[1]), @intFromFloat(playerworld.player.pos[2]) } / @Vector(3, i32){ 32, 32, 32 };

    const d1 = Distance(pi, a);
    const d2 = Distance(pi, b);

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
                const neighbors = GetAndLockNeighbors(self, chunkpos);
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
                for (neighbors) |n| if (n != null) {
                    n.?.lock.unlockShared();
                };
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
            chptr.lock.lockShared();
            defer chptr.lock.unlockShared();
            allocator.destroy(chnode);
            const chstate = self.Chunks.get(chptr.pos) orelse unreachable;
            std.debug.assert(chstate.state != ChunkState.InMemoryMeshUnloaded);
            const neighbors: [6]?*ChunkandMeta = GetAndLockNeighbors(self, chptr.pos);
            defer {
                for (neighbors) |n| {
                    if (n != null) n.?.lock.unlockShared();
                }
            }
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
                }
            }
            if (wfn > 0) {
                chstate.state = ChunkState.WaitingForNeighbors;

                continue :top;
            }
            std.debug.assert(wfn == 0);
            std.debug.assert(chstate.state != ChunkState.InMemoryAndMesh and chstate.state != ChunkState.InMemoryNoMesh);
            const mesh = try Render.MeshChunk_Normal(chptr, allocator, neighborptrs);

            if (mesh.len == 0) {
                allocator.free(mesh);
                chstate.state = ChunkState.InMemoryNoMesh;
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
    pub fn GetAndLockNeighbors(self: *@This(), pos: [3]i32) [6]?*ChunkandMeta {
        const getneighbors = ztracy.ZoneNC(@src(), "getneighbors", 0xFFFF00);
        defer getneighbors.End();
        var chunks: [6]?*ChunkandMeta = undefined;
        // BUG chunks are gotten before state TODO fix
        //if chunk state changes after ptr is gotten state and ptr could mismaatch
        //might need to change big parts of the system
        chunks[0] = self.Chunks.get([3]i32{ pos[0] + 1, pos[1], pos[2] });
        if (chunks[0] != null) chunks[0].?.lock.lockShared();
        chunks[1] = self.Chunks.get([3]i32{ pos[0] - 1, pos[1], pos[2] });
        if (chunks[1] != null) chunks[1].?.lock.lockShared();
        chunks[2] = self.Chunks.get([3]i32{ pos[0], pos[1] + 1, pos[2] });
        if (chunks[2] != null) chunks[2].?.lock.lockShared();
        chunks[3] = self.Chunks.get([3]i32{ pos[0], pos[1] - 1, pos[2] });
        if (chunks[3] != null) chunks[3].?.lock.lockShared();
        chunks[4] = self.Chunks.get([3]i32{ pos[0], pos[1], pos[2] + 1 });
        if (chunks[4] != null) chunks[4].?.lock.lockShared();
        chunks[5] = self.Chunks.get([3]i32{ pos[0], pos[1], pos[2] - 1 });
        if (chunks[5] != null) chunks[5].?.lock.lockShared();

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
                        const cg = self.Chunks.get(pos);
                        
                        if (cg == null) {
                            const c = try allocator.create(ChunkandMeta);
                            c.state = ChunkState.ToGenerate;
                            c.chunkmeshesindex = null;
                            c.neighborsmissing = null;
                            c.lock = .{};
                            c.chunkPtr = null;
                            c.pos = pos;
                            _ = try self.Chunks.put(pos, c);
                            _ = try self.ToGen.add(pos);
                            continue;
                        }
                        else if(cg.?.state == ChunkState.InMemoryMeshUnloaded){
                            cg.?.lock.lock();
                            cg.?.state = ChunkState.ReMesh;
                            cg.?.lock.unlock();

                            const cn = try allocator.create(std.DoublyLinkedList(*Chunk).Node);
                            cn.data = cg.?.chunkPtr.?;
                            self.ToMeshMutex.lock();
                            self.ToMesh.append(cn);
                            self.ToMeshMutex.unlock();
                        }
                    }
                    y += 1;
                    z = -@as(i32, @intCast(player.GenDistance[2]));
                }
                x += 1;
                y = -@as(i32, @intCast(player.GenDistance[1]));
            }
        }
    }

    pub fn AddToUnload(self: *@This(), player: *Entitys.Player, sleeptime: u64, allocator: std.mem.Allocator) !void {
        while (true) {
            std.time.sleep(sleeptime);
            const addToUnload = ztracy.ZoneNC(@src(), "AddToUnload", 0x9692de);
            defer addToUnload.End();
            const pi = [3]i32{ @intFromFloat(player.pos[0]), @intFromFloat(player.pos[1]), @intFromFloat(player.pos[2]) } / @Vector(3, i32){ 32, 32, 32 };
            const bktamount = self.Chunks.buckets.len;
            for (0..bktamount) |b| {
                std.debug.print("s", .{});
                self.Chunks.buckets[b].lock.lockShared();
                var it = self.Chunks.buckets[b].iteratorManualLock();
                defer self.Chunks.buckets[b].lock.unlockShared();
                while (true) {
                    const ch = it.next() orelse {
                        break;
                    };

                    if (@reduce(.Or, @abs(pi - ch.value_ptr.*.pos) > @as(@Vector(3, u32), ((player.MeshDistance))))) {
                        ch.value_ptr.*.lock.lockShared();
                        if ((ch.value_ptr.*.state == ChunkState.InMemoryAndMesh or ch.value_ptr.*.state == ChunkState.InMemoryNoMesh or ch.value_ptr.*.state == ChunkState.InMemoryMeshUnloaded)) {
                            ch.value_ptr.*.lock.unlockShared();
                            ch.value_ptr.*.lock.lock();
                            ch.value_ptr.*.chunkPtr.?.lock.lock();
                            //std.debug.print("\n\n u \n\n", .{});
                            if (ch.value_ptr.*.state == ChunkState.InMemoryAndMesh) {
                                ch.value_ptr.*.state = ChunkState.MeshOnly;
                            } else if (ch.value_ptr.*.state == ChunkState.InMemoryNoMesh or ch.value_ptr.*.state == ChunkState.InMemoryMeshUnloaded ) {
                                ch.value_ptr.*.state = ChunkState.Unknown;
                            }
                            const p = ch.value_ptr.*;
                            allocator.destroy(ch.value_ptr.*.chunkPtr.?);
                            self.Chunks.buckets[b].lock.unlockShared();
                            _ = self.Chunks.remove(ch.value_ptr.*.pos);
                            self.Chunks.buckets[b].lock.lockShared();
                            allocator.destroy(p);

                            // ch.value_ptr.*.lock.unlock();
                        } else ch.value_ptr.*.lock.unlockShared();
                    }
                }
            }
        }
    }
};
