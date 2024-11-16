const std = @import("std");
const RenderIDs = @import("./Chunk.zig").MeshBufferIDs;
const Chunk = @import("./Chunk.zig").Chunk;
const ChunkState = @import("./Chunk.zig").ChunkState;
const Generator = @import("./Chunk.zig").Generator;
const Render = @import("./Chunk.zig").Render;
const ztracy = @import("ztracy");
const Noise = @import("./fastnoise.zig");
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
        // std.debug.print("lt|{d}||{d}||{d}|\n", .{a,player_location,b});
        return std.math.Order.lt;
    } else if (d1 > d2) {
        // std.debug.print("gt|{d}||{d}|\n", .{a,b});
        return std.math.Order.gt;
    } else {
        return std.math.Order.eq;
    }
}
pub const World = struct {
    ChunkMeshes: std.ArrayList(RenderIDs),
    Chunks: std.AutoHashMap([3]i32, Chunk),
    ChunkStates: std.AutoHashMap([3]i32, ChunkState),
    Entitys: std.AutoHashMap(Entitys.EntityUUID, type),
    ToGen: std.PriorityQueue([3]i32, pw, DistanceOrder),
    ToLoad: ?[][]u32,
    ToLoadPos: ?[][3]i32,
    //  ToMesh: std.TailQueue(*Chunk),
    ToLoadMutex: std.Thread.Mutex,
    ChunksMutex: std.Thread.Mutex,
    ChunkStatesMutex: std.Thread.Mutex,
    TerrainNoise: Noise.Noise(f32),
    CaveNoise: Noise.Noise(f32),
    caveness:u8,
    min: i32,
    max: i32,
    pub fn GenChunk(self: *@This(), sleeptime: u64, maxcount: u32, player: Entitys.Player, allocator: std.mem.Allocator) !void {
        while (true) {
            std.time.sleep(sleeptime);
            const GenChunks = ztracy.ZoneNC(@src(), "GenChunks", 0x9692de);
            defer GenChunks.End();
            var count: u32 = 0;
            if (self.ToLoad != null or self.ToLoadPos != null) continue;
            //std.debug.print("al\n", .{});
            var l = std.ArrayList([]u32).init(allocator);
            var P = std.ArrayList([3]i32).init(allocator);
            defer l.deinit();
            defer P.deinit();
            while (count < maxcount) {
                count += 1;
                self.ToLoadMutex.lock();
                const chunkpos = self.ToGen.removeOrNull() orelse {
                    self.ToLoadMutex.unlock();
                    break;
                };
                self.ToLoadMutex.unlock();
                //seed 0
                const chunk = Generator.GenChunk(chunkpos, self.TerrainNoise, self.CaveNoise, self.min, self.max ,self.caveness) orelse {
                    self.ChunkStatesMutex.lock();
                    _ = try self.ChunkStates.put(chunkpos, ChunkState.NotImportant);
                    self.ChunkStatesMutex.unlock();
                    continue;
                };
                _ = player;
                self.ChunkStatesMutex.lock();
                self.ChunksMutex.lock();
                _ = try self.Chunks.put(chunkpos, chunk);
                self.ChunksMutex.unlock();
                _ = try self.ChunkStates.put(chunkpos, ChunkState.Mesh);
                self.ChunkStatesMutex.unlock();
                const meshchunk = ztracy.ZoneNC(@src(), "meshchunk", 0x9692d);
                const mesh = try Render.MeshChunk_Normal(@constCast(&chunk), allocator, GetNeighbors(self, chunkpos));
                meshchunk.End();
                if (mesh.len == 0) continue;
                //std.debug.print("aa{any}\n", .{chunkpos});
                _ = try l.append(mesh);
                _ = try P.append(chunkpos);

                //_ = try self.ChunkMeshes.append(Render.CreateOrUpdateMeshVBO(mesh, chunkpos, ebo, facebuffer, null, gl.STATIC_DRAW));

            }

            self.ToLoadMutex.lock();
            self.ToLoad = try l.toOwnedSlice();
            self.ToLoadPos = try P.toOwnedSlice();
            //std.debug.print("{any}", .{self.ToLoadPos});
            self.ToLoadMutex.unlock();
        }
    }

    //pub fn MeshChunks(self: *@This(), sleeptime: u64, maxtime: u128, allocator: std.mem.Allocator) !void {

    //}

    fn GetNeighbors(self: *@This(), pos: [3]i32) [6]?*Chunk {
        var chunks: [6]?*Chunk = undefined;
        self.ChunksMutex.lock();
        chunks[0] = self.Chunks.getPtr([3]i32{ pos[0] + 1, pos[1], pos[2] }) orelse null;
        chunks[1] = self.Chunks.getPtr([3]i32{ pos[0] - 1, pos[1], pos[2] }) orelse null;
        chunks[2] = self.Chunks.getPtr([3]i32{ pos[0], pos[1] + 1, pos[2] }) orelse null;
        chunks[3] = self.Chunks.getPtr([3]i32{ pos[0], pos[1] - 1, pos[2] }) orelse null;
        chunks[4] = self.Chunks.getPtr([3]i32{ pos[0], pos[1], pos[2] + 1 }) orelse null;
        chunks[5] = self.Chunks.getPtr([3]i32{ pos[0], pos[1], pos[2] - 1 }) orelse null;
        self.ChunksMutex.unlock();
        return chunks;
    }

    pub fn LoadMeshes(self: *@This(), ebo: c_uint, facebuffer: c_uint) !void {
        self.ToLoadMutex.lock();
        defer self.ToLoadMutex.unlock();
        const len: u32 = @intCast((self.ToLoad orelse return).len);
        var i: u32 = 0;
        while (i < len) {
            //std.debug.print("{any}", .{self.ToLoadPos.?[i][0..3]});
            _ = try self.ChunkMeshes.append(Render.CreateOrUpdateMeshVBO(self.ToLoad.?[i], self.ToLoadPos.?[i][0..3], ebo, facebuffer, null, gl.STATIC_DRAW));
            i += 1;
            //std.debug.print("ll\n", .{});
        }
        self.ToLoad = null;
        self.ToLoadPos = null;
    }

    pub fn AddToGen(self: *@This(), player: *Entitys.Player, sleeptime: u64) !void {
        while (true) {
            std.time.sleep(sleeptime);
            const Addtogen = ztracy.ZoneNC(@src(), "Addtogen", 0x9692de);
            defer Addtogen.End();
            //std.debug.print("o", .{});

            //TODO fix should be negitive render distance adds wrong chunks check game1 to fix
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

                        self.ChunkStatesMutex.lock();
                        defer self.ChunkStatesMutex.unlock();
                        _ = self.ChunkStates.get(pos) orelse {
                            self.ToLoadMutex.lock();
                            _ = try self.ToGen.add(pos);
                            self.ToLoadMutex.unlock();
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
