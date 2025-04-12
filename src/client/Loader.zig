const std = @import("std");
const World = @import("World").World;
const Renderer = @import("Renderer.zig").Renderer;
const zudp = @import("zudp").Connection;
const ztracy = @import("ztracy");

//singleplayer if conn is null
pub fn ChunkLoaderThread(renderer: *Renderer, conn: ?zudp, intervel_ns: u64, running: *std.atomic.Value(bool)) void {
    while (running.load(.monotonic)) {
        const addChunkstoLoad = ztracy.ZoneNC(@src(), "addChunksToLoad", 223);
        const st = std.time.nanoTimestamp();
        defer std.Thread.sleep(intervel_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
        const loadDistance = [3]u32{ renderer.GenerateDistance[0].load(.seq_cst), renderer.GenerateDistance[1].load(.seq_cst), renderer.GenerateDistance[2].load(.seq_cst) };
        if (conn) |connection| {
            //multiplayer
            _ = connection;
        } else {
            //singleplayer
            LoadChunksSingleplayer(renderer, loadDistance);
        }
        addChunkstoLoad.End();
    }
}

fn LoadChunksSingleplayer(renderer: *Renderer, distance: [3]u32) void {
    var amount_loaded: u64 = 0;
    const eyePosChunk = @as(@Vector(3, i32), @intFromFloat(@round(renderer.eyePos / @Vector(3, f64){ 32, 32, 32 })));
    var x: i32 = -@as(i32, @intCast(distance[0]));
    var y: i32 = -@as(i32, @intCast(distance[1]));
    var z: i32 = -@as(i32, @intCast(distance[2]));
    while (x < distance[0]) {
        while (y < distance[1]) {
            while (z < distance[2]) {
                const ChunkPos = [3]i32{ x + eyePosChunk[0], y + eyePosChunk[1], z + eyePosChunk[2] };
                renderer.LoadingChunksLock.lockShared();
                const loading = renderer.LoadingChunks.contains(ChunkPos);
                renderer.LoadingChunksLock.unlockShared();
                renderer.ChunkRenderListLock.lockShared();
                const loaded = renderer.ChunkRenderList.contains(ChunkPos);
                renderer.ChunkRenderListLock.unlockShared();
                if (!loading) amount_loaded += 1;
                if (!loading) {
                    renderer.LoadingChunksLock.lock();
                    renderer.LoadingChunksLock.unlock();
                    renderer.LoadingChunks.put(ChunkPos, true) catch |err| std.debug.panic("err:{any}\n", .{err});
                }
                if (!loading and !loaded) renderer.pool.spawn(Renderer.AddChunkToRenderNoError, .{ renderer, ChunkPos }) catch |err| std.debug.panic("pool spawn failed: {any}\n", .{err});
                z += 1;
            }
            z = -@as(i32, @intCast(distance[2]));
            y += 1;
        }
        y = -@as(i32, @intCast(distance[1]));
        x += 1;
    }
    if (amount_loaded > 0) std.debug.print("added {d} chunks to load\n", .{amount_loaded});
}
