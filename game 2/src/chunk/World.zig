const std = @import("std");

const gl = @import("gl");
const ztracy = @import("ztracy");

const Entitys = @import("../entities/Entitys.zig");
const ConcurrentHashMap = @import("../libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const Blocks = @import("./Blocks.zig").Blocks;
const RenderIDs = @import("./Chunk.zig").MeshBufferIDs;
const Chunk = @import("./Chunk.zig").Chunk;
const ChunkState = @import("./Chunk.zig").ChunkState;
const Generator = @import("./Chunk.zig").Generator;
const Render = @import("./Chunk.zig").Render;
const ChunkandMeta = @import("./Chunk.zig").ChunkandMeta;
const ChunkSize = @import("./Chunk.zig").ChunkSize;
const PtrState = @import("./Chunk.zig").PtrState;
const Noise = @import("./fastnoise.zig");

pub const pw = struct { player: *Entitys.Player, world: *World };
//time:2299371800 11/22/2024
pub fn Distance(c1: [3]i32, c2: [3]i32) f32 {
    const dx: f32 = @floatFromInt(c2[0] - c1[0]);
    const dy: f32 = @floatFromInt(c2[1] - c1[1]);
    const dz: f32 = @floatFromInt(c2[2] - c1[2]);
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

pub fn DistanceFloat(c1: [3]f32, c2: [3]f32) f32 {
    const dx: f32 = (c2[0] - c1[0]);
    const dy: f32 = (c2[1] - c1[1]);
    const dz: f32 = (c2[2] - c1[2]);
    return @sqrt(dx * dx + dy * dy + dz * dz);
}
pub fn DistanceOrder(player: Entitys.Player, a: [3]i32, b: [3]i32) std.math.Order {
    // Convert coordinates to float32 and scale them
    const pi = [3]i32{ @intFromFloat(player.pos[0]), @intFromFloat(player.pos[1]), @intFromFloat(player.pos[2]) } / @Vector(3, i32){ 32, 32, 32 };

    const d1 = Distance(pi, a);
    const d2 = Distance(pi, b);

    if (d1 < d2) {
        return std.math.Order.gt;
    } else if (d1 > d2) {
        return std.math.Order.lt;
    } else {
        return std.math.Order.eq;
    }
}
pub const ChunkMesh = struct {
    position: [3]i32,
    faces: []u32,
    scale:f32,
};
pub const World = struct {
    pool: std.Thread.Pool,
    ChunkMeshes: std.ArrayList(RenderIDs),
    Chunks: ConcurrentHashMap([3]i32, *ChunkandMeta, std.hash_map.AutoContext([3]i32), 80, 32),
    Entitys: std.AutoHashMap(Entitys.EntityUUID, type),
    MeshesToLoad: std.DoublyLinkedList(ChunkMesh),
    MeshesToLoadMutex: std.Thread.Mutex,
    ToUnload: std.DoublyLinkedList([3]i32),
    ToUnloadMutex: std.Thread.Mutex,
    TerrainNoise: Noise.Noise(f32),
    TerrainNoise2: Noise.Noise(f32),
    CaveNoise: Noise.Noise(f32),
    caveness: f32,
    min: i32,
    max: i32,
    pub fn GenChunk(self: *@This(), chunkpos: [3]i32, player: Entitys.Player,scale:f32, allocator: std.mem.Allocator) void {
        const GenChunktime = ztracy.ZoneNC(@src(), "GenChunk", 0x9692de);
        defer GenChunktime.End();
        _ = player;
        //seed 0
        const caves = false;
        const chunk: Chunk = Generator.GenChunk(chunkpos, self.TerrainNoise, self.TerrainNoise2, self.CaveNoise, self.min, self.max, self.caveness, scale  , caves) orelse {
            self.Chunks.get(chunkpos).?.state.store(ChunkState.AllAir, .seq_cst);
            const neighbors = GetAndLockNeighbors(self, chunkpos);
            defer {
                for (neighbors) |n| if (n != null) {
                    n.?.lock.unlockShared();
                };
            }
            for (0..6) |i| {
                if (neighbors[i] != null and neighbors[i].?.state.load(.seq_cst) == ChunkState.WaitingForNeighbors) {
                    neighbors[i].?.state.store(ChunkState.ReMesh, .seq_cst);
                    _ = self.pool.spawn(MeshChunk, .{ self, neighbors[i].?.pos, allocator }) catch |err| {
                        std.debug.panic("\n{any}", .{err});
                    };
                }
            }

            return;
        };
        //uses TONS of memory, TODO fix memory usage
        const ap = ztracy.ZoneNC(@src(), "allocanput", 0x9692d);
        defer ap.End();
        const chptr = allocator.create(Chunk) catch |err| {
            std.debug.panic("\n{any}", .{err});
        };
        chptr.* = chunk;
        const p = self.Chunks.get(chunkpos).?;
        if (p.state.load(.seq_cst) == ChunkState.ToGenerate or p.state.load(.seq_cst) == ChunkState.InMemoryMeshUnloaded) {
            p.state.store(ChunkState.Generating, .seq_cst);
            p.chunkPtr = chptr;
            _ = self.pool.spawn(MeshChunk, .{ self, chptr.pos, allocator }) catch |err| {
                std.debug.panic("\n{any}", .{err});
            };
        } else {
            std.debug.panic("sssERROR\n{any}\n", .{p.state.load(.seq_cst)});
        }
    }

    pub fn MeshChunk(self: *@This(), pos: [3]i32, allocator: std.mem.Allocator) void {
        const meshchunk = ztracy.ZoneNC(@src(), "meshchunk", 0x9692d);
        defer meshchunk.End();
        const chstate = self.Chunks.get(pos) orelse {
            std.debug.print("warning", .{});
            return;
        };
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
                neighbors[i].?.state.store(ChunkState.ReMesh, .seq_cst);
                self.pool.spawn(MeshChunk, .{ self, neighbors[i].?.pos, allocator }) catch |err| {
                    std.debug.panic("\n{any}", .{err});
                };
            }
        }
        if (wfn > 0) {
            //std.debug.print("\nl{any}", .{chstate.lock.impl});
            chstate.state.store(ChunkState.WaitingForNeighbors, .seq_cst);

            return;
        }
        std.debug.assert(wfn == 0);
        std.debug.assert(chstate.state.load(.seq_cst) == ChunkState.Generating or chstate.state.load(.seq_cst) == ChunkState.ReMesh);
        const mesh = Render.MeshChunk_Normal(chstate.chunkPtr.?, allocator, neighborptrs) catch |err| {
            std.debug.panic("\n{any}", .{err});
        };

        if (mesh.len == 0) {
            //chstate.lock.lock();
            chstate.state.store(ChunkState.InMemoryNoMesh, .seq_cst);
            //chstate.lock.unlock();
            allocator.free(mesh);
            return;
        }

        const putmesh = ztracy.ZoneNC(@src(), "putmesh", 0x9692d);
        defer putmesh.End();
        //chstate.lock.lock();
        chstate.state.store(ChunkState.InMemoryAndMesh, .seq_cst);
        //chstate.lock.unlock();
        var node = allocator.create(std.DoublyLinkedList(ChunkMesh).Node) catch |err| {
            std.debug.panic("\n{any}", .{err});
        };
        node.data = ChunkMesh{ .faces = mesh, .position = pos, .scale = chstate.scale};
        self.MeshesToLoadMutex.lock();
        self.MeshesToLoad.append((node));
        self.MeshesToLoadMutex.unlock();
    }

    pub fn RemeshChunk(self: *@This(), pos: [3]i32, allocator: std.mem.Allocator) !bool {
        var ch = self.Chunks.get(pos);
        if (ch != null and ch.?.chunkPtr != null) {
            ch.?.state.store(ChunkState.ReMesh, .seq_cst);
            _ = try self.pool.spawn(MeshChunk, .{ self, pos, allocator });
            return true;
        }
        return false;
    }
    pub fn GetAndLockNeighbors(self: *@This(), pos: [3]i32) [6]?*ChunkandMeta {
        const getneighbors = ztracy.ZoneNC(@src(), "getneighbors", 0xFFFF00);
        defer getneighbors.End();
        var chunks: [6]?*ChunkandMeta = [6]?*ChunkandMeta{ null, null, null, null, null, null };
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
            const vbo = Render.CreateMeshVBO(mesh.data.faces, mesh.data.position, ebo, facebuffer, mesh.data.scale, gl.STATIC_DRAW);

            _ = try self.ChunkMeshes.append(vbo);
            i += 1;
        }
    }

    pub fn AddToGen(self: *@This(), player: *Entitys.Player, sleeptime: u64, allocator: std.mem.Allocator) !void {
        const buffer = try allocator.alloc(u8, @sizeOf(i32) * 3 * player.GenDistance[0] * player.GenDistance[1] * player.GenDistance[2] * 2 * 2 * 2 * 32);
        defer allocator.free(buffer);
        var fba = std.heap.FixedBufferAllocator.init(buffer);
        const fballoc = fba.allocator();
        var SortToGen = std.PriorityQueue([3]i32, Entitys.Player, DistanceOrder).init(fballoc, player.*);
        _ = try SortToGen.ensureUnusedCapacity(player.GenDistance[0] * player.GenDistance[1] * player.GenDistance[2]);

        defer SortToGen.deinit();
        while (true) {
            std.time.sleep(sleeptime);

            const Addtogen = ztracy.ZoneNC(@src(), "Addtogen", 0x9692de);
            defer Addtogen.End();
            const p = @Vector(3, i32){ @as(i32, @intFromFloat(player.pos[0] / 32.0)), @as(i32, @intFromFloat(player.pos[1] / 32.0)), @as(i32, @intFromFloat(player.pos[2] / 32.0)) };
            var x = -@as(i32, @intCast(player.GenDistance[0]));
            var y = -@as(i32, @intCast(player.GenDistance[1]));
            var z = -@as(i32, @intCast(player.GenDistance[2]));
            while (x < player.GenDistance[0]) {
                while (y < player.GenDistance[1]) {
                    while (z < player.GenDistance[2]) {
                        const pos = [3]i32{ @as(i32, @intCast(x)), @as(i32, @intCast(y)), @as(i32, @intCast(z)) } + p;

                        z += 1;

                        const cg = self.Chunks.get(pos);

                        if (cg == null) {
                            const c = try allocator.create(ChunkandMeta);
                            c.state.store(ChunkState.ToGenerate, .seq_cst);
                            c.chunkmeshesindex = null;
                            c.neighborsmissing = null;
                            c.lock = .{};
                            c.Unloading = false;
                            c.chunkPtr = null;
                            //scale
                            c.scale = 1.0;
                            //
                            std.debug.assert(pos[0] != -1431655766);
                            c.pos = pos;
                            _ = try self.Chunks.put(pos, c);
                            //_ = try self.pool.spawn(GenChunk, .{self,pos,player.*,allocator,});
                            _ = try SortToGen.add(pos);
                            continue;
                        } else if (cg.?.state.load(.seq_cst) == ChunkState.InMemoryMeshUnloaded) {
                            cg.?.state.store(ChunkState.ReMesh, .seq_cst);
                            _ = try self.pool.spawn(MeshChunk, .{ self, cg.?.pos, allocator });
                        }
                       // else if (1.0+DistanceFloat(@as(@Vector(3,f32),@floatFromInt(@as(@Vector(3, i32),pos))),player.pos/@Vector(3, f32){32.0,32.0,32.0}) != cg.?.scale and cg.?.state.load(.seq_cst) == ChunkState.InMemoryAndMesh){
                        // _ = try SortToGen.add(cg.?.pos);
                        //not done

                    
                       // }
                        // not working
                        else if (false and cg.?.state.load(.seq_cst) == ChunkState.MeshOnly) {
                            cg.?.state.store(ChunkState.InMemoryAndMesh, .seq_cst); //unsafe
                            _ = try SortToGen.add(cg.?.pos);
                        }
                    }
                    y += 1;
                    z = -@as(i32, @intCast(player.GenDistance[2]));
                }
                x += 1;
                y = -@as(i32, @intCast(player.GenDistance[1]));
            }
            const spawntask = ztracy.ZoneNC(@src(), "spawntasks", 0x969d55);
            defer spawntask.End();
            while (SortToGen.removeOrNull()) |pos| {
                _ = try self.pool.spawn(GenChunk, .{
                    self,
                    pos,
                    player.*,
                    self.Chunks.get(pos).?.scale,
                    allocator,
                });
            }
            //if(@reduce(.Or, @abs(pos - @as(@Vector(3, i32),@intFromFloat(player.pos/@Vector(3, f32){32.0,32.0,32.0}))) < @as(@Vector(3, u32), (@Vector(3, u32){2,2,2}))))1 else 2;
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
                inner: while (true) {
                    const ch = it.next() orelse {
                        break :inner;
                    };
                    if (!ch.*.Unloading and @reduce(.Or, @abs(pi - ch.*.pos) > @as(@Vector(3, u32), ((player.LoadDistance))))) {
                        const unloadpos = try allocator.create(std.DoublyLinkedList([3]i32).Node);
                        const hash_code = self.Chunks.ctx.hash(ch.*.pos);
                        const bucket_index = @mod(hash_code, 32);
                        unloadpos.data = ch.*.pos;

                        if (self.Chunks.buckets[b].hash_map.get(ch.*.pos) == null or bucket_index != b) {
                            std.debug.print("\n\nerr{any}, len:{}", .{ ch.*.pos, self.ToUnload.len });
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

    pub fn UnloadLoop(self: *@This(), sleeptime: u64, allocator: std.mem.Allocator) !void {
        top: while (true) {
            const Unload = ztracy.ZoneNC(@src(), "Unloadchunks", 0x9692de);
            defer Unload.End();

            self.ToUnloadMutex.lock();
            const chunktounload = self.ToUnload.popFirst() orelse {
                self.ToUnloadMutex.unlock();
                const sleeping = ztracy.ZoneNC(@src(), "sleeping", 0x9832fd2d);
                std.time.sleep(sleeptime);
                sleeping.End();
                continue :top;
            };
            defer allocator.destroy(chunktounload);
            self.ToUnloadMutex.unlock();
            //std.debug.print("\nu", .{});
            UnloadChunk(self, self.Chunks.get(chunktounload.data) orelse {
                std.debug.print("\n\nerr unloading chunk {any}, len:{}\n\n", .{ chunktounload.data, self.ToUnload.len });
                continue;
            }, allocator);
        }
    }

    pub fn UnloadChunk(self: *@This(), chunk: *ChunkandMeta, allocator: std.mem.Allocator) void {
        std.debug.assert(chunk.Unloading == true);
        const state = chunk.state.load(.seq_cst);
        switch (state) {
            //not working
            ChunkState.InMemoryAndMesh => {
                chunk.lock.lock();
                chunk.state.store(ChunkState.MeshOnly, .seq_cst);
                const c = chunk.chunkPtr.?;
                chunk.chunkPtr = null;
                chunk.lock.unlock();
                c.lock.lock();
                allocator.destroy(c);
            },
            ChunkState.InMemoryMeshUnloaded, ChunkState.InMemoryNoMesh, ChunkState.WaitingForNeighbors => {
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
