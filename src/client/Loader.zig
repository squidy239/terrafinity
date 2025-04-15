const std = @import("std");
const World = @import("World").World;
const Renderer = @import("Renderer.zig").Renderer;
const zudp = @import("zudp").Connection;
const gl = @import("gl");
const ztracy = @import("ztracy");

threadlocal var meshesToUnloadBuffer: [1024]Renderer.MeshBufferIDs = undefined;
threadlocal var meshesToUnloadBufferPos: u16 = 0;
threadlocal var chunksToUnloadBuffer: [8192][3]i32 = undefined;
threadlocal var chunksToUnloadBufferPos: u16 = 0;
///Loads all chunks in gendistance and unloads all chunks out of loaddistance
pub fn ChunkLoaderThread(renderer: *Renderer, conn: ?zudp, intervel_ns: u64, running: *std.atomic.Value(bool)) void {
    while (running.load(.monotonic)) {
        const addChunkstoLoad = ztracy.ZoneNC(@src(), "addChunksToLoad", 223);
        const st = std.time.nanoTimestamp();
        defer std.Thread.sleep(intervel_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
        const genDistance = [3]u32{ renderer.GenerateDistance[0].load(.seq_cst), renderer.GenerateDistance[1].load(.seq_cst), renderer.GenerateDistance[2].load(.seq_cst) };
        if (conn) |connection| {
            //multiplayer
            _ = connection;
        } else {
            //singleplayer
            LoadChunksSingleplayer(renderer, genDistance);
        }
        addChunkstoLoad.End();
    }
}

pub fn ChunkUnloaderThread(world: *World, loadDistancePtr: *[3]std.atomic.Value(u32), player_pos: *@Vector(3, f64), intervel_ns: u64, running: *std.atomic.Value(bool)) void {
    while (running.load(.monotonic)) {
        const unloadChunks = ztracy.ZoneNC(@src(), "unloadChunks", 223);
        const st = std.time.nanoTimestamp();
        defer std.Thread.sleep(intervel_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
        const loadDistance = [3]u32{ loadDistancePtr[0].load(.seq_cst), loadDistancePtr[1].load(.seq_cst), loadDistancePtr[2].load(.seq_cst) };
        UnloadChunks(world, player_pos.*, loadDistance) catch |err| std.debug.panic("err:{any}\n", .{err});
        unloadChunks.End();
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
                const loading = renderer.LoadingChunks.contains(ChunkPos);
                renderer.ChunkRenderListLock.lockShared();
                const loaded = renderer.ChunkRenderList.contains(ChunkPos);
                renderer.ChunkRenderListLock.unlockShared();
                if (!loading and !loaded) {
                    amount_loaded += 1;
                    renderer.LoadingChunks.put(ChunkPos, true) catch |err| std.debug.panic("err:{any}\n", .{err});
                    renderer.pool.spawn(Renderer.AddChunkToRenderTask, .{ renderer, ChunkPos }) catch |err| std.debug.panic("pool spawn failed: {any}\n", .{err});
                }
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

fn UnloadChunks(world: *World, player_pos: @Vector(3, f64), loadDistance: [3]u32) !void {
    const unloadChunks = ztracy.ZoneNC(@src(), "unloadChunks", 1125878);
    defer unloadChunks.End();
    const bktamount = world.Chunks.buckets.len;
    const floatPlayerChunkPos = player_pos / @as(@Vector(3, f64), @splat(32));
    const playerChunkPos = @as(@Vector(3, i32), @intFromFloat(floatPlayerChunkPos));

    for (0..bktamount) |b| {
        world.Chunks.buckets[b].lock.lock();
        var it = world.Chunks.buckets[b].hash_map.iterator();
        defer world.Chunks.buckets[b].lock.unlock();
        while (it.next()) |c| {
            if (chunksToUnloadBufferPos < chunksToUnloadBuffer.len and outOfSquareRange(c.key_ptr.* - playerChunkPos, [3]i32{ @intCast(loadDistance[0]), @intCast(loadDistance[1]), @intCast(loadDistance[2]) })) {
                chunksToUnloadBuffer[chunksToUnloadBufferPos] = c.key_ptr.*;
                chunksToUnloadBufferPos += 1;
            }
        }
    }
    for (chunksToUnloadBuffer[0..chunksToUnloadBufferPos]) |Pos| {
        try world.UnloadChunk(Pos);
    }
    if (chunksToUnloadBufferPos > 0) std.debug.print("tried to unload {d} chunks\n", .{chunksToUnloadBufferPos});
    chunksToUnloadBufferPos = 0;
}

pub fn UnloadMeshes(renderer: *Renderer, meshDistance: [3]u32) void {
    {
        renderer.ChunkRenderListLock.lockShared();
        defer renderer.ChunkRenderListLock.unlockShared();
        renderer.ChunkRenderList.lockPointers();
        defer renderer.ChunkRenderList.unlockPointers();
        const values = renderer.ChunkRenderList.values();
        for (values) |mesh| {
            const floatPlayerChunkPos = renderer.eyePos / @as(@Vector(3, f64), @splat(32));
            const playerChunkPos = @as(@Vector(3, i32), @intFromFloat(floatPlayerChunkPos));
            if (meshesToUnloadBufferPos < 1024 and outOfSquareRange(mesh.pos - playerChunkPos, [3]i32{ @intCast(meshDistance[0]), @intCast(meshDistance[1]), @intCast(meshDistance[2]) })) {
                meshesToUnloadBuffer[meshesToUnloadBufferPos] = mesh;
                meshesToUnloadBufferPos += 1;
            }
        }
    }
    if (meshesToUnloadBufferPos > 0) {
        renderer.ChunkRenderListLock.lock();
        for (meshesToUnloadBuffer[0..meshesToUnloadBufferPos]) |mesh| {
            _ = renderer.ChunkRenderList.swapRemove(mesh.pos);
        }
        renderer.ChunkRenderListLock.unlock();
        for (meshesToUnloadBuffer[0..meshesToUnloadBufferPos]) |mesh| {
            //std.debug.print("mesh:{any}\n", .{mesh});
            inline for (0..2) |i| {
                if (mesh.vbo[i]) |vbo| gl.DeleteBuffers(1, @constCast(@ptrCast(&vbo)));
                if (mesh.vao[i]) |vao| gl.DeleteVertexArrays(1, @constCast(@ptrCast(&vao)));
            }
        }
        meshesToUnloadBufferPos = 0;
    }
}

fn outOfSquareRange(Pos: @Vector(3, i32), range: @Vector(3, i32)) bool {
    return @reduce(.Or, @as(@Vector(3, i32), @intCast(@abs(Pos))) > range);
}
