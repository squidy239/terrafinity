const std = @import("std");
const RenderIDs = @import("./Chunk.zig").MeshBufferIDs;
const Chunk = @import("./Chunk.zig").Chunk;
const ChunkState = @import("./Chunk.zig").ChunkState;
const Generator = @import("./Chunk.zig").Generator;
const Render = @import("./Chunk.zig").Render;
const ztracy = @import("ztracy");
const ConcurrentHashMap = @import("../libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const Noise = @import("./fastnoise.zig");
const PtrState = @import("./Chunk.zig").PtrState;
const gl = @import("gl");
const Entitys = @import("../entities/Entitys.zig");
pub const pw = struct { player: *Entitys.Player, world: *World };
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
    Chunks: ConcurrentHashMap([3]i32, Chunk,std.hash_map.AutoContext([3]i32),80,16),
    ChunkStates: ConcurrentHashMap([3]i32, ChunkState,std.hash_map.AutoContext([3]i32),80,16),
    Entitys: std.AutoHashMap(Entitys.EntityUUID, type),
    ToGen: std.PriorityQueue([3]i32, pw, DistanceOrder),
    ToGenMutex: std.Thread.Mutex,
    MeshesToLoad: std.DoublyLinkedList(ChunkMesh),
    MeshesToLoadMutex: std.Thread.RwLock,
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

            //seed 0
            const chunk: Chunk = Generator.GenChunk(chunkpos, self.TerrainNoise, self.CaveNoise, self.min, self.max, self.caveness) orelse {
                _ = try self.ChunkStates.put(chunkpos, ChunkState.AllAir);
                continue;
            };
            //std.debug.print("l{any}", .{chunk.pos});
            _ = player;
            _ = try self.Chunks.put(chunkpos, chunk);

            //std.debug.print("|{d}|", .{c});
            const meshchunk = ztracy.ZoneNC(@src(), "meshchunk", 0x9692d);
            //if(1 == 1)continue;
            const gn = ztracy.ZoneNC(@src(), "getnehbors", 0x9692d);
            const n = GetNeighborfull(self, chunkpos);
            gn.End();
            const mesh = try Render.MeshChunk_Normal(@constCast(&chunk), allocator, n);
            meshchunk.End();

            if (mesh.len == 0) {
                _ = try self.ChunkStates.put(chunkpos, ChunkState.InMemoryNoMesh);
                allocator.free(mesh);
                continue;
            }
            const putmesh = ztracy.ZoneNC(@src(), "putmesh", 0x9692d);
            defer putmesh.End();
            _ = try self.ChunkStates.put(chunkpos, ChunkState.InMemoryAndMesh);
            var node = try allocator.create(std.DoublyLinkedList(ChunkMesh).Node);
            node.data = ChunkMesh{ .faces = mesh, .position = chunkpos };
            self.MeshesToLoadMutex.lockShared();
            self.MeshesToLoad.append((node));
            self.MeshesToLoadMutex.unlockShared();
        }
    }

    //pub fn MeshChunks(self: *@This(), sleeptime: u64, maxtime: u128, allocator: std.mem.Allocator) !void {

    //}

    pub fn GetNeighbors(self: *@This(), pos: [3]i32) [6]PtrState {
        var chunks: [6]PtrState = undefined;
        {
            const ptr = self.Chunks.getPtr([3]i32{ pos[0] + 1, pos[1], pos[2] });
            if (ptr != null) {
                chunks[0] = PtrState{ .ChunkPtr = ptr, .State = (self.ChunkStates.get([3]i32{ pos[0] + 1, pos[1], pos[2] }) orelse unreachable) };
            } else {
                chunks[0] = PtrState{ .ChunkPtr = null, .State = (self.ChunkStates.get([3]i32{ pos[0] + 1, pos[1], pos[2] }) orelse ChunkState.NotGenerated) };
            }
        }

        {
            const ptr = self.Chunks.getPtr([3]i32{ pos[0] - 1, pos[1], pos[2] });
            if (ptr != null) {
                chunks[1] = PtrState{ .ChunkPtr = ptr, .State = (self.ChunkStates.get([3]i32{ pos[0] - 1, pos[1], pos[2] }) orelse unreachable) };
            } else {
                chunks[1] = PtrState{ .ChunkPtr = null, .State = (self.ChunkStates.get([3]i32{ pos[0] - 1, pos[1], pos[2] }) orelse ChunkState.NotGenerated) };
            }
        }
        {
            const ptr = self.Chunks.getPtr([3]i32{ pos[0], pos[1] + 1, pos[2] });
            if (ptr != null) {
                chunks[2] = PtrState{ .ChunkPtr = ptr, .State = (self.ChunkStates.get([3]i32{ pos[0], pos[1] + 1, pos[2] }) orelse unreachable) };
            } else {
                chunks[2] = PtrState{ .ChunkPtr = null, .State = (self.ChunkStates.get([3]i32{ pos[0], pos[1] + 1, pos[2] }) orelse ChunkState.NotGenerated) };
            }
        }
        {
            const ptr = self.Chunks.getPtr([3]i32{ pos[0], pos[1] - 1, pos[2] });
            if (ptr != null) {
                chunks[3] = PtrState{ .ChunkPtr = ptr, .State = (self.ChunkStates.get([3]i32{ pos[0], pos[1] - 1, pos[2] }) orelse unreachable) };
            } else {
                chunks[3] = PtrState{ .ChunkPtr = null, .State = (self.ChunkStates.get([3]i32{ pos[0], pos[1] - 1, pos[2] }) orelse ChunkState.NotGenerated) };
            }
        }
        {
            const ptr = self.Chunks.getPtr([3]i32{ pos[0], pos[1], pos[2] + 1 });
            if (ptr != null) {
                chunks[4] = PtrState{ .ChunkPtr = ptr, .State = (self.ChunkStates.get([3]i32{ pos[0], pos[1], pos[2] + 1 }) orelse unreachable) };
            } else {
                chunks[4] = PtrState{ .ChunkPtr = null, .State = (self.ChunkStates.get([3]i32{ pos[0], pos[1], pos[2] + 1 }) orelse ChunkState.NotGenerated) };
            }
        }
        {
            const ptr = self.Chunks.getPtr([3]i32{ pos[0], pos[1], pos[2] - 1 });
            if (ptr != null) {
                chunks[5] = PtrState{ .ChunkPtr = ptr, .State = (self.ChunkStates.get([3]i32{ pos[0], pos[1], pos[2] - 1 }) orelse unreachable) };
            } else {
                chunks[5] = PtrState{ .ChunkPtr = null, .State = (self.ChunkStates.get([3]i32{ pos[0], pos[1], pos[2] - 1 }) orelse ChunkState.NotGenerated) };
            }
        }
        return chunks;
    }

    fn GetNeighborfull(self: *@This(), pos: [3]i32) [6]?Chunk {
        var chunks: [6]?Chunk = undefined;
        chunks[0] = self.Chunks.get([3]i32{ pos[0] + 1, pos[1], pos[2] }) orelse null;
        chunks[1] = self.Chunks.get([3]i32{ pos[0] - 1, pos[1], pos[2] }) orelse null;
        chunks[2] = self.Chunks.get([3]i32{ pos[0], pos[1] + 1, pos[2] }) orelse null;
        chunks[3] = self.Chunks.get([3]i32{ pos[0], pos[1] - 1, pos[2] }) orelse null;
        chunks[4] = self.Chunks.get([3]i32{ pos[0], pos[1], pos[2] + 1 }) orelse null;
        chunks[5] = self.Chunks.get([3]i32{ pos[0], pos[1], pos[2] - 1 }) orelse null;
        return chunks;
    }

    //TODO
    // pub fn MeshChunksLoop(self:*@This(), sleeptime:u64,maxtime:u64,allocator:std.mem.Allocator)!void{

    //}

    pub fn LoadMeshes(self: *@This(), ebo: c_uint, facebuffer: c_uint, allocator: std.mem.Allocator,maxtime:u64) !void {
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

    pub fn AddToGen(self: *@This(), player: *Entitys.Player, sleeptime: u64) !void {
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
                        _ = self.ChunkStates.get(pos) orelse {
                            _ = try self.ToGen.add(pos);
                            _ = try self.ChunkStates.put(pos, ChunkState.Generating);
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
