const std = @import("std");
const RenderIDs = @import("./Chunk.zig").MeshBufferIDs;
const Chunk = @import("./Chunk.zig").Chunk;
const Generator = @import("./Chunk.zig").Generator;
const Render = @import("./Chunk.zig").Render;
const gl = @import("gl");
const Entitys = @import("../entities/Entitys.zig");

pub fn DistanceOrder(player: *Entitys.Player, a: [3]i32, b: [3]i32) std.math.Order {
    const aa = [3]f32{ @floatFromInt(a[0] * 3 * 32), @floatFromInt(a[1] * 3 * 32), @floatFromInt(a[2] * 3 * 32) };
    const bb = [3]f32{ @floatFromInt(b[0] * 3 * 32), @floatFromInt(b[1] * 3 * 32), @floatFromInt(b[2] * 3 * 32) };
    const player_location = [3]f32{ player.pos[0] * 32, player.pos[1] * 32, player.pos[2] * 32 };
    const d1 = @sqrt((player_location[0] - aa[0]) + (player_location[1] - aa[1]) + (player_location[2] - aa[2]));
    const d2 = @sqrt((player_location[0] - bb[0]) + (player_location[1] - bb[1]) + (player_location[2] - bb[2]));
    if (d1 < d2) return std.math.Order.lt;
    if (d1 > d2) return std.math.Order.gt;
    return std.math.Order.eq;
}
pub const World = struct {
    ChunkMeshes: std.ArrayList(RenderIDs),
    Chunks: std.AutoHashMap([3]i32, Chunk),
    Entitys: std.AutoHashMap(Entitys.EntityUUID, type),
    ToGen: std.PriorityQueue([3]i32, *Entitys.Player, DistanceOrder),

    pub fn GenChunk(self: *@This(), maxchunks: u32, player: Entitys.Player, allocator: std.mem.Allocator, ebo: c_uint, facebuffer: c_uint) !void {
        var count: u32 = 0;
        while (count < maxchunks) {
            const chunkpos = self.ToGen.removeOrNull() orelse return;

            //seed 0
            const chunk = Generator.GenChunk(0, chunkpos);
            _ = player;
            //if (chunkpos[0] <= player.LoadDistance[0] and chunkpos[1] <= player.LoadDistance[1] and chunkpos[2] <= player.LoadDistance[2]) {
            _ = try self.Chunks.put(chunkpos, chunk);
            //}
            const mesh = try Render.MeshChunk_Normal(@constCast(&chunk), allocator);
            if (mesh.len == 0) continue;
            _ = try self.ChunkMeshes.append(Render.CreateOrUpdateMeshVBO(mesh, chunkpos, ebo, facebuffer, null, gl.STATIC_DRAW));
            std.debug.print("{d}\n", .{chunkpos});
            count += 1;
        }
    }

    pub fn AddToGen(self: *@This(), player: Entitys.Player) !void {
        for (0..player.GenDistance[0]) |x| {
            for (0..player.GenDistance[1]) |y| {
                for (0..player.GenDistance[2]) |z| {
                    var pos = [3]i32{ @as(i32, @intCast(x)), @as(i32, @intCast(y)), @as(i32, @intCast(z)) };
                    pos[0] += @as(i32, @intFromFloat(player.pos[0] / 32));
                    pos[1] += @as(i32, @intFromFloat(player.pos[1] / 32));
                    pos[2] += @as(i32, @intFromFloat(player.pos[2] / 32));

                    pos[0] -= @intCast(player.GenDistance[0] / 2);
                    pos[1] -= @intCast(player.GenDistance[1] / 2);
                    pos[2] -= @intCast(player.GenDistance[2] / 2);

                    if (!self.Chunks.contains(pos))
                        _ = try self.ToGen.add(pos);
                    //std.debug.print("{d}", .{pos});
                }
            }
        }
    }
};
