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

pub fn DistanceOrder(player: *Entitys.Player, a: [3]i32, b: [3]i32) std.math.Order {
    // Convert coordinates to float32 and scale them
    const aa = [3]f32{ @floatFromInt(a[0] * 3 * 32), @floatFromInt(a[1] * 3 * 32), @floatFromInt(a[2] * 3 * 32) };
    const bb = [3]f32{ @floatFromInt(b[0] * 3 * 32), @floatFromInt(b[1] * 3 * 32), @floatFromInt(b[2] * 3 * 32) };
    const player_location = [3]f32{ player.pos[0] * 32, player.pos[1] * 32, player.pos[2] * 32 };

    // Calculate squared differences for each dimension
    const dx1 = player_location[0] - aa[0];
    const dy1 = player_location[1] - aa[1];
    const dz1 = player_location[2] - aa[2];

    const dx2 = player_location[0] - bb[0];
    const dy2 = player_location[1] - bb[1];
    const dz2 = player_location[2] - bb[2];

    // Calculate Euclidean distances (squared differences)
    const d1 = (dx1 * dx1 + dy1 * dy1 + dz1 * dz1);
    const d2 = (dx2 * dx2 + dy2 * dy2 + dz2 * dz2);

    // Compare distances and return appropriate order
    if (d1 < d2) {
        return std.math.Order.lt;
    } else if (d1 > d2) {
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
    ToGen: std.PriorityQueue([3]i32, *Entitys.Player, DistanceOrder),
    ToLoad: ?[][]u32,
    ToLoadPos: ?[][3]i32,
    ToLoadMutex: std.Thread.Mutex,
    ChunksMutex: std.Thread.Mutex,
    ChunkStatesMutex: std.Thread.Mutex,

    pub fn GenChunk(self: *@This(), sleeptime: u64, maxcount: u32, player: Entitys.Player, allocator: std.mem.Allocator) !void {
        
        
        const TerrainNoise = Noise.Noise(f32){
            .seed = 0,
            .noise_type = .simplex,
            .frequency = 0.01,
            .fractal_type = .none,
        };

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
                const chunk = Generator.GenChunk(chunkpos,TerrainNoise) orelse {
                    self.ChunkStatesMutex.lock();
                    _ = try self.ChunkStates.put(chunkpos, ChunkState.NotImportant);
                    self.ChunkStatesMutex.unlock();
                    continue;
                };
                _ = player;
                self.ChunkStatesMutex.lock();
                //_ = try self.Chunks.put(chunkpos, chunk);
                _ = try self.ChunkStates.put(chunkpos, ChunkState.Mesh);
                self.ChunkStatesMutex.unlock();
                const mesh = try Render.MeshChunk_Normal(@constCast(&chunk), allocator, GetNeighbors(self, chunkpos));
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

    fn GetNeighbors(self: *@This(), pos: [3]i32) [6]?*Chunk {
        var chunks: [6]?*Chunk = undefined;
        chunks[0] = self.Chunks.getPtr([3]i32{ pos[0] + 1, pos[1], pos[2] }) orelse null;
        chunks[1] = self.Chunks.getPtr([3]i32{ pos[0] - 1, pos[1], pos[2] }) orelse null;
        chunks[2] = self.Chunks.getPtr([3]i32{ pos[0], pos[1] + 1, pos[2] }) orelse null;
        chunks[3] = self.Chunks.getPtr([3]i32{ pos[0], pos[1] - 1, pos[2] }) orelse null;
        chunks[4] = self.Chunks.getPtr([3]i32{ pos[0], pos[1], pos[2] + 1 }) orelse null;
        chunks[5] = self.Chunks.getPtr([3]i32{ pos[0], pos[1], pos[2] - 1 }) orelse null;
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
            var x = -@as(i32,@intCast(player.GenDistance[0]));
            var y = -@as(i32,@intCast(player.GenDistance[1]));
            var z = -@as(i32,@intCast(player.GenDistance[2]));
            while (x < player.GenDistance[0]) {
                while (y < player.GenDistance[1]) {
                    while (z < player.GenDistance[2]) {
                        

                        var pos = [3]i32{ @as(i32, @intCast(x)), @as(i32, @intCast(y)), @as(i32, @intCast(z)) };
                        pos[0] += @as(i32, @intFromFloat(player.pos[0] / 32.0));
                        pos[1] += @as(i32, @intFromFloat(player.pos[1] / 32.0));
                        pos[2] += @as(i32, @intFromFloat(player.pos[2] / 32.0));

                        z+=1;

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
