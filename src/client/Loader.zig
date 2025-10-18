const std = @import("std");
const root = @import("root");
const SetThreadPriority = root.SetThreadPriority;
const World = @import("World").World;
const Renderer = @import("Renderer.zig").Renderer;
const gl = @import("gl");
const ztracy = @import("ztracy");
const Chunk = @import("Chunk").Chunk;
const ChunkSize = Chunk.ChunkSize;

threadlocal var meshesToUnloadBuffer: [1024]Renderer.MeshBufferIDs = undefined;
threadlocal var meshesToUnloadBufferPos: u16 = 0;
threadlocal var chunksToUnloadBuffer: [1024][3]i32 = undefined;
threadlocal var chunksToUnloadBufferPos: u16 = 0;
///Loads all chunks in gendistance and unloads all chunks out of loaddistance
pub fn ChunkLoaderThread(renderer: *Renderer, intervel_ns: u64, pos: *@Vector(3, f64), posLock: *std.Thread.RwLock, running: *std.atomic.Value(bool)) void {
    _ = SetThreadPriority(.THREAD_PRIORITY_BELOW_NORMAL);
    while (running.load(.monotonic)) {
        const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
        posLock.lockShared();
        lock.End();
        const playerPos = pos.*;
        posLock.unlockShared();
        const addChunkstoLoad = ztracy.ZoneNC(@src(), "addChunksToLoad", 223);
        const st = std.time.nanoTimestamp();
        defer std.Thread.sleep(intervel_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
        const genDistance = [3]u32{ renderer.GenerateDistance[0].load(.seq_cst), renderer.GenerateDistance[1].load(.seq_cst), renderer.GenerateDistance[2].load(.seq_cst) };
        const eyePosChunk = @as(@Vector(3, i32), @intFromFloat(@round(playerPos / @Vector(3, f64){ ChunkSize, ChunkSize, ChunkSize })));
        LoadChunksSingleplayer(renderer, eyePosChunk, genDistance);
        addChunkstoLoad.End();
    }
}

pub fn ChunkUnloaderThread(world: *World, loadDistancePtr: *[3]std.atomic.Value(u32), pos: *@Vector(3, f64), posLock: *std.Thread.RwLock, intervel_ns: u64, running: *std.atomic.Value(bool)) void {
    _ = SetThreadPriority(.THREAD_PRIORITY_IDLE);
    while (running.load(.monotonic)) {
        const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
        posLock.lockShared();
        lock.End();
        const playerPos = pos.*;
        posLock.unlockShared();
        const unloadChunks = ztracy.ZoneNC(@src(), "unloadChunks", 223);
        const st = std.time.nanoTimestamp();
        defer std.Thread.sleep(intervel_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
        const loadDistance = [3]u32{ loadDistancePtr[0].load(.seq_cst), loadDistancePtr[1].load(.seq_cst), loadDistancePtr[2].load(.seq_cst) };
        const floatPlayerChunkPos = playerPos / @as(@Vector(3, f64), @splat(32));
        const playerChunkPos = @as(@Vector(3, i32), @intFromFloat(floatPlayerChunkPos));
        UnloadChunks(world, playerChunkPos, loadDistance) catch |err| std.debug.panic("err:{any}\n", .{err});
        unloadChunks.End();
    }
}
///loads chunks from top to bottom and in a spiral on a y level
threadlocal var lastLoadPlayerChunkPos: ?@Vector(3, i32) = undefined;
threadlocal var lastGenDistance: ?@Vector(3, u32) = undefined;

fn LoadChunksSingleplayer(renderer: *Renderer, playerChunkPos: @Vector(3, i32), distance: @Vector(3, u32)) void { //TODO optimize by spliting into stages and make hashmap calls happen with a array under one lock
    defer {
        lastLoadPlayerChunkPos = playerChunkPos;
        lastGenDistance = distance;
    }
    if (lastLoadPlayerChunkPos != null and lastGenDistance != null) {
        if (@reduce(.And, lastLoadPlayerChunkPos.? == playerChunkPos) and @reduce(.And, lastGenDistance.? == distance)) return;
    }

    var amount_loaded: u64 = 0;
    var amount_tested: u64 = 0;

    var xz: [2]i32 = .{ 0, 0 };
    var c: usize = 0;
    //defer std.debug.print("amount_tested: {d}\n", .{amount_tested});

    while (true) {
        if (amount_tested >= 4 * distance[0] * distance[2]) { //* 4 because loaddistance is distance from the player, not a full square
            break;
        }

        const m = Move(xz, &c);

        var cc: i32 = 0;
        while (Line(&xz, &cc, m)) {
            amount_tested += 1;
            std.debug.assert(cc <= 2 * @max(distance[0], distance[2]));
            var y: i32 = -@as(i32, @intCast(distance[1]));
            while (y < distance[1]) {
                defer y += 1;
                const ChunkPos = [3]i32{ xz[0] + playerChunkPos[0], y + playerChunkPos[1], xz[1] + playerChunkPos[2] };
                if (renderer.LoadingChunks.contains(ChunkPos)) {
                    continue;
                }
                const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
                renderer.ChunkRenderListLock.lockShared();
                lock.End();
                const loaded = renderer.ChunkRenderList.contains(ChunkPos);
                renderer.ChunkRenderListLock.unlockShared();
                if ((!loaded or ((renderer.world.Chunks.get(ChunkPos) orelse continue).genstate.load(.seq_cst) == .TerrainGenerated))) {
                    amount_loaded += 1;
                    renderer.LoadingChunks.put(ChunkPos, true) catch |err| std.debug.panic("err:{any}\n", .{err});
                    renderer.pool.spawn(Renderer.AddChunkToRenderTask, .{ renderer, ChunkPos, true, true }, .Medium) catch |err| std.debug.panic("pool spawn failed: {any}\n", .{err});
                }
            }
        }
    }
    //if (amount_loaded > 0) std.log.info("added {d} chunks to load\n", .{amount_loaded});
}

test "test" {
    const excoords: [10][2]i32 = [10][2]i32{ [2]i32{ 0, 0 }, [2]i32{ 0, 1 }, [2]i32{ 1, 1 }, [2]i32{ 1, 0 }, [2]i32{ 1, -1 }, [2]i32{ 0, -1 }, [2]i32{ -1, -1 }, [2]i32{ -1, 0 }, [2]i32{ -1, 1 }, [2]i32{ -1, 2 } };
    var newexcoords: [10][2]i32 = @splat(@splat(0));

    var xz: [2]i32 = @splat(0);
    var c: usize = 0;
    var ta: usize = 0;
    for (0..10) |_| {
        var cc: i32 = 0;
        const m = Move(xz, &c);
        while (Line(&xz, &cc, m)) {
            if (ta < 10) newexcoords[ta] = xz;
            std.debug.print("x: {d}, y:{d}, c:{d}, cc:{d}\n", .{ xz[0], xz[1], c, cc });
            ta += 1;
        }
    }
    try std.testing.expectEqualDeep(excoords, newexcoords);
}

fn Move(xzin: [2]i32, c: *usize) [2]i32 {
    const movf: f32 = (@as(f32, @floatFromInt(c.*)) / 2.0);
    const mov: i32 = @intFromFloat(@ceil(movf + 0.01));
    var xz = xzin;
    switch (@mod(c.*, 4)) {
        0 => xz[1] += mov,
        1 => xz[0] += mov,
        2 => xz[1] -= mov,
        3 => xz[0] -= mov,
        else => unreachable,
    }
    c.* += 1;
    return xz;
}

fn Line(xz: *[2]i32, c: *i32, end: [2]i32) bool {
    defer c.* += 1;
    if (c.* == 0) return true;
    if (xz[0] == end[0] and xz[1] == end[1]) return false;
    std.debug.assert(xz[0] == end[0] or xz[1] == end[1]);
    if (xz[0] == end[0]) {
        if (xz[1] < end[1]) {
            xz[1] += 1;
        } else {
            xz[1] -= 1;
        }
    } else {
        if (xz[0] < end[0]) {
            xz[0] += 1;
        } else {
            xz[0] -= 1;
        }
    }
    if (xz[0] == end[0] and xz[1] == end[1]) return false;
    return true;
}
threadlocal var lastPlayerChunkPos: ?@Vector(3, i32) = undefined;
threadlocal var lastloadDistance: ?@Vector(3, u32) = undefined;
threadlocal var bufferFull: bool = false;
fn UnloadChunks(world: *World, playerChunkPos: @Vector(3, i32), loadDistance: @Vector(3, u32)) !void {
    const unloadChunks = ztracy.ZoneNC(@src(), "unloadChunks", 1125878);
    defer unloadChunks.End();
    defer {
        lastPlayerChunkPos = playerChunkPos;
        lastloadDistance = loadDistance;
    }
    if (lastPlayerChunkPos != null and lastPlayerChunkPos != null) {
        if (@reduce(.And, lastPlayerChunkPos.? == playerChunkPos) and @reduce(.And, lastloadDistance.? == loadDistance) and !bufferFull) return;
    }
    const bktamount = world.Chunks.buckets.len;
    var chunks: u64 = 0;
    for (0..bktamount) |b| {
        const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
        world.Chunks.buckets[b].lock.lockShared();
        lock.End();
        var it = world.Chunks.buckets[b].hash_map.iterator();
        defer world.Chunks.buckets[b].lock.unlockShared();
        while (it.next()) |c| {
            chunks += 1;
            if (chunksToUnloadBufferPos < chunksToUnloadBuffer.len and outOfSquareRange(c.key_ptr.* - playerChunkPos, [3]i32{ @intCast(loadDistance[0]), @intCast(loadDistance[1]), @intCast(loadDistance[2]) })) {
                chunksToUnloadBuffer[chunksToUnloadBufferPos] = c.key_ptr.*;
                chunksToUnloadBufferPos += 1;
            }
        }
    }
    for (chunksToUnloadBuffer[0..chunksToUnloadBufferPos]) |Pos| {
        try world.UnloadChunk(Pos);
    }
    std.debug.print("tried to unload {d} chunks, {d} chunks loaded\n", .{ chunksToUnloadBufferPos, chunks });
    bufferFull = chunksToUnloadBufferPos == chunksToUnloadBuffer.len;
    chunksToUnloadBufferPos = 0;
}

fn outOfSquareRange(Pos: @Vector(3, i32), range: @Vector(3, i32)) bool {
    return @reduce(.Or, @as(@Vector(3, i32), @intCast(@abs(Pos))) > range);
}
