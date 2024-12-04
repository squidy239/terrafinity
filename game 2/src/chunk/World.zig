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
    ToMesh: std.DoublyLinkedList([3]i32),
    ToMeshMutex: std.Thread.Mutex,
    ToUnload: std.DoublyLinkedList([3]i32),
    ToUnloadMutex: std.Thread.Mutex,
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
                self.Chunks.get(chunkpos).?.state.store(ChunkState.AllAir, .seq_cst);
                const neighbors = GetAndLockNeighbors(self, chunkpos);
                defer {for (neighbors) |n| if (n != null) {
                    n.?.lock.unlockShared();
                };}
                for (0..6) |i| {
                    if (neighbors[i] != null and neighbors[i].?.state.load(.seq_cst) == ChunkState.WaitingForNeighbors) {
                        neighbors[i].?.state.store(ChunkState.ReMesh, .seq_cst) ;
                        const cn = try allocator.create(std.DoublyLinkedList([3]i32).Node);
                        cn.data = neighbors[i].?.pos;
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
            p.state.store(ChunkState.Generating, .seq_cst);
            p.chunkPtr = chptr;
            ap.End();
            const WAITFORTOMESHMUTEX = ztracy.ZoneNC(@src(), "WAITFORTOMESHMUTEX", 0x9692d);
            WAITFORTOMESHMUTEX.End();
            const cn = try allocator.create(std.DoublyLinkedList([3]i32).Node);
            cn.data = chptr.pos;
            self.ToMeshMutex.lock();
            self.ToMesh.append(cn);
            self.ToMeshMutex.unlock();
        }
    }

pub fn MeshChunksai(self: *@This(), sleeptime: u64, allocator: std.mem.Allocator) !void {
    while (true) {
        const meshchunk = ztracy.ZoneNC(@src(), "meshchunk", 0x9692d);
        defer meshchunk.End();

        // Retrieve next chunk to mesh
        const chnode: *std.DoublyLinkedList([3]i32).Node = blk: {
            self.ToMeshMutex.lock();
            defer self.ToMeshMutex.unlock();

            break :blk self.ToMesh.popFirst() orelse {
                // No chunks to mesh, sleep and continue
                const sleeping = ztracy.ZoneNC(@src(), "sleeping", 0x9832fd2d);
                std.time.sleep(sleeptime);
                sleeping.End();
                continue;
            };
        };
        defer allocator.destroy(chnode);

        const pos: [3]i32 = chnode.data;

        // Retrieve and validate chunk state
        const chstate = self.Chunks.get(pos) orelse {
            std.debug.print("Warning: Chunk not found at position {any}\n", .{pos});
            continue;
        };

        chstate.lock.lockShared();
        defer chstate.lock.unlockShared();

        // Validate chunk state
        const current_state = chstate.state.load(.seq_cst);
        if (current_state != ChunkState.Generating and current_state != ChunkState.ReMesh) {
            std.debug.print("Warning: Invalid chunk state {any} for position {any}\n", .{current_state, pos});
            continue;
        }

        // Get neighbors with careful locking
        var neighbors: [6]?*ChunkandMeta = undefined;
        var neighbor_locks_acquired = [_]bool{false} ** 6;
        defer {
            // Ensure we unlock any locks we've acquired
            for (0..6) |i| {
                if (neighbor_locks_acquired[i] and neighbors[i] != null) {
                    neighbors[i].?.lock.unlockShared();
                }
            }
        }

        // Attempt to get and lock neighbors
        var waiting_for_neighbors: u3 = 0;
        var neighborptrs: [6]?*Chunk = [6]?*Chunk{ null, null, null, null, null, null };
        
        neighbors = GetAndLockNeighbors(self, pos);

        // Process neighbors
        for (0..6) |i| {
            if (neighbors[i]) |neighbor| {
                neighbor_locks_acquired[i] = true;

                if (neighbor.chunkPtr) |chunk_ptr| {
                    neighborptrs[i] = chunk_ptr;
                } else if (neighbor.state.load(.seq_cst) != ChunkState.AllAir) {
                    waiting_for_neighbors += 1;
                }

                // Handle neighbors waiting for mesh generation
                if (neighbor.state.load(.seq_cst) == ChunkState.WaitingForNeighbors and 
                    current_state == ChunkState.Generating) 
                {
                    // Carefully update neighbor state
                    neighbor.state.store(ChunkState.ReMesh, .seq_cst);
                    
                    // Create and add to mesh queue
                    const cn = try allocator.create(std.DoublyLinkedList([3]i32).Node);
                    cn.data = neighbor.pos;
                    
                    self.ToMeshMutex.lock();
                    defer self.ToMeshMutex.unlock();
                    self.ToMesh.append(cn);
                }
            } else {
                waiting_for_neighbors += 1;
            }
        }

        // If waiting for neighbors, reschedule chunk
        if (waiting_for_neighbors > 0) {
            chstate.state.store(ChunkState.WaitingForNeighbors, .seq_cst);
            continue;
        }

        // Generate mesh
        const mesh = Render.MeshChunk_Normal(
            chstate.chunkPtr orelse {
                std.debug.print("Error: Chunk pointer is null at {any}\n", .{pos});
                continue;
            }, 
            allocator, 
            neighborptrs
        ) catch |err| {
            std.debug.print("Error meshing chunk: {}\n", .{err});
            continue;
        };
        errdefer allocator.free(mesh);

        // Handle empty mesh
        if (mesh.len == 0) {
            chstate.state.store(ChunkState.InMemoryNoMesh, .seq_cst);
            continue;
        }

        // Store mesh for loading
        const putmesh = ztracy.ZoneNC(@src(), "putmesh", 0x9692d);
        defer putmesh.End();

        chstate.state.store(ChunkState.InMemoryAndMesh, .seq_cst);
        
        const node = try allocator.create(std.DoublyLinkedList(ChunkMesh).Node);
        node.data = ChunkMesh{ .faces = mesh, .position = pos };

        self.MeshesToLoadMutex.lock();
        defer self.MeshesToLoadMutex.unlock();
        self.MeshesToLoad.append(node);
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
            const pos: [3]i32 = chnode.data;
            allocator.destroy(chnode);
            const chstate = self.Chunks.get(pos) orelse {std.debug.print("warning", .{});continue;};
            chstate.lock.lockShared();
            defer chstate.lock.unlockShared();
            //std.debug.print("\n{any}", .{chstate.state.load(.seq_cst)});
            std.debug.assert(chstate.state.load(.seq_cst) == ChunkState.Generating or chstate.state.load(.seq_cst) == ChunkState.ReMesh);
            const neighbors: [6]?*ChunkandMeta = GetAndLockNeighbors(self, pos);
            //const neighbors = [6]?*ChunkandMeta{null,null,null,null,null,null};
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
                } else if (neighbors[i] == null or neighbors[i].?.state.load(.seq_cst) != ChunkState.AllAir) {
                    wfn += 1;
                }

                if (neighbors[i] != null and neighbors[i].?.state.load(.seq_cst) == ChunkState.WaitingForNeighbors and chstate.state.load(.seq_cst) == ChunkState.Generating) {
                    //neighbors[i].?.lock.lock();
                    neighbors[i].?.state.store(ChunkState.ReMesh, .seq_cst);
                    //neighbors[i].?.lock.unlock();
                    const cn = try allocator.create(std.DoublyLinkedList([3]i32).Node);
                    cn.data = neighbors[i].?.pos;
                    self.ToMeshMutex.lock();
                    self.ToMesh.append(cn);
                    self.ToMeshMutex.unlock();
                }
            }
            if (wfn > 0) {
                //std.debug.print("\nl{any}", .{chstate.lock.impl});
                chstate.state.store(ChunkState.WaitingForNeighbors, .seq_cst);

                continue :top;
            }
            std.debug.assert(wfn == 0);
            std.debug.assert(chstate.state.load(.seq_cst) == ChunkState.Generating or chstate.state.load(.seq_cst) == ChunkState.ReMesh);
            const mesh = try Render.MeshChunk_Normal(chstate.chunkPtr.?, allocator, neighborptrs);

            if (mesh.len == 0) {
                //chstate.lock.lock();
                chstate.state.store(ChunkState.InMemoryNoMesh, .seq_cst);
                //chstate.lock.unlock();
                allocator.free(mesh);
                continue :top;
            }

            const putmesh = ztracy.ZoneNC(@src(), "putmesh", 0x9692d);
            defer putmesh.End();
            //chstate.lock.lock();
            chstate.state.store(ChunkState.InMemoryAndMesh, .seq_cst);
            //chstate.lock.unlock();
            var node = try allocator.create(std.DoublyLinkedList(ChunkMesh).Node);
            node.data = ChunkMesh{ .faces = mesh, .position = pos };
            self.MeshesToLoadMutex.lock();
            self.MeshesToLoad.append((node));
            self.MeshesToLoadMutex.unlock();
        }
    }


    pub fn GetAndLockNeighbors(self: *@This(), pos: [3]i32) [6]?*ChunkandMeta {
        const getneighbors = ztracy.ZoneNC(@src(), "getneighbors", 0xFFFF00);
        defer getneighbors.End();
        var chunks: [6]?*ChunkandMeta = [6]?*ChunkandMeta{null,null,null,null,null,null};
        // BUG chunks are gotten before state TODO fix
        //if chunk state changes after ptr is gotten state and ptr could mismaatch
        //might need to change big parts of the system
        chunks[0] = self.Chunks.getandlockchunkshared([3]i32{ pos[0] + 1, pos[1], pos[2] });
        chunks[1] = self.Chunks.getandlockchunkshared([3]i32{ pos[0] - 1, pos[1], pos[2] });
        chunks[2] = self.Chunks.getandlockchunkshared([3]i32{ pos[0], pos[1] + 1, pos[2] });
        chunks[3] = self.Chunks.getandlockchunkshared([3]i32{ pos[0], pos[1] - 1, pos[2] });
        chunks[4] = self.Chunks.getandlockchunkshared([3]i32{ pos[0], pos[1], pos[2] + 1 });
        chunks[5] = self.Chunks.getandlockchunkshared([3]i32{ pos[0], pos[1], pos[2] - 1 });

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
            defer allocator.destroy(mesh);
            self.MeshesToLoadMutex.unlock();
            const vbo = Render.CreateOrUpdateMeshVBO(mesh.data.faces, mesh.data.position, ebo, facebuffer, null, gl.STATIC_DRAW);
            
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
                            c.state.store(ChunkState.ToGenerate, .seq_cst);
                            c.chunkmeshesindex = null;
                            c.neighborsmissing = null;
                            c.lock = .{};
                            c.Unloading = false;
                            c.chunkPtr = null;
                            std.debug.assert(pos[0] != -1431655766);
                            c.pos = pos;
                            _ = try self.Chunks.put(pos, c);
                            _ = try self.ToGen.add(pos);
                            continue;
                        } else if (cg.?.state.load(.seq_cst) == ChunkState.InMemoryMeshUnloaded) {
                            cg.?.state.store(ChunkState.ReMesh, .seq_cst);

                            const cn = try allocator.create(std.DoublyLinkedList([3]i32).Node);
                            cn.data = cg.?.pos;
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
                self.Chunks.buckets[b].lock.lockShared();
                var it = self.Chunks.buckets[b].hash_map.valueIterator();
                defer self.Chunks.buckets[b].lock.unlockShared();
                inner:while (true) {
                    const ch = it.next() orelse {
                        break:inner;
                    };
                    if (!ch.*.Unloading and @reduce(.Or, @abs(pi - ch.*.pos) > @as(@Vector(3, u32), ((player.LoadDistance))))) {
                            const unloadpos = try allocator.create(std.DoublyLinkedList([3]i32).Node);
                            const hash_code = self.Chunks.ctx.hash(ch.*.pos);
                            const bucket_index = @mod(hash_code, 32);
                            unloadpos.data = ch.*.pos;

                            if(self.Chunks.buckets[b].hash_map.get(ch.*.pos) == null or bucket_index != b){
                                std.debug.print("\n\nerr{any}, len:{}", .{ch.*.pos,self.ToUnload.len});
                                ch.*.pos = ch.*.chunkPtr.?.pos;
                                continue;
                            }
                            //maybie atomic later
                            ch.*.Unloading = true;
                            self.ToUnloadMutex.lock();
                            self.ToUnload.append(unloadpos);
                            self.ToUnloadMutex.unlock();
                    }
             
                }
            }
        }

    }

   pub fn UnloadLoop(self: *@This(), sleeptime: u64, allocator: std.mem.Allocator)!void{
        top:while (true) {
            const Unload = ztracy.ZoneNC(@src(), "Unloadchunks", 0x9692de);
            defer Unload.End();

            self.ToUnloadMutex.lock();
            const chunktounload = self.ToUnload.popFirst() orelse {
                self.ToUnloadMutex.unlock();
                const sleeping = ztracy.ZoneNC(@src(), "sleeping", 0x9832fd2d);
                std.time.sleep(sleeptime);
                sleeping.End();
                continue:top;
            };
            defer allocator.destroy(chunktounload);
            self.ToUnloadMutex.unlock();
            //std.debug.print("\nu", .{});
            UnloadChunk(self, self.Chunks.get(chunktounload.data) orelse {std.debug.print("\n\nerr unloading chunk {any}, len:{}\n\n", .{chunktounload.data,self.ToUnload.len});continue;}, allocator);
        }
    }

    pub fn UnloadChunk(self:*@This(),chunk:*ChunkandMeta, allocator : std.mem.Allocator)void{
        std.debug.assert(chunk.Unloading == true);
        const state = chunk.state.load(.seq_cst);
        switch (state) {
            ChunkState.InMemoryAndMesh => {
                chunk.lock.lock();
                chunk.state.store(ChunkState.MeshOnly, .seq_cst);
                const c = chunk.chunkPtr.?;
                chunk.chunkPtr = null;
                chunk.lock.unlock();
                c.lock.lock();
                allocator.destroy(c);
            },
            ChunkState.InMemoryMeshUnloaded,ChunkState.InMemoryNoMesh, ChunkState.WaitingForNeighbors => {
                
                _ = self.Chunks.remove(chunk.pos);
                chunk.lock.lock();
                chunk.chunkPtr.?.lock.lock();
                allocator.destroy(chunk.chunkPtr.?);
                allocator.destroy(chunk);
                
            },
            ChunkState.AllAir => {
                _ = self.Chunks.remove(chunk.pos);
                std.debug.assert(chunk.chunkPtr == null);
                chunk.lock.lock();
                allocator.destroy(chunk);
            },
            else => {},
        }
    }
};
       