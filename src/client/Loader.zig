const std = @import("std");
const root = @import("root");
const ChunkManager = root.ChunkManager;
const ConcurrentQueue = @import("root").ConcurrentQueue;
const DrawElementsIndirectCommand = root.Renderer.DrawElementsIndirectCommand;
const MeshBufferIDs = root.Renderer.MeshBufferIDs;
const Renderer = root.Renderer;
const Game = @import("Game.zig");
const ThreadPool = @import("root").ThreadPool;
const UBO = root.Renderer.UBO;

const Chunk = @import("Chunk").Chunk;
const ChunkSize = Chunk.ChunkSize;
const Entity = @import("Entity").Entity;
const gl = @import("gl");
const World = @import("World").World;
const ztracy = @import("ztracy");

const Mesher = @import("Mesher.zig");
const outOfSquareRange = @import("utils.zig").outOfSquareRange;

pub const Loader = struct {
    threadlocal var meshesToUnloadBuffer: [1024]World.ChunkPos = undefined;
    threadlocal var meshesToUnloadBufferPos: usize = 0;
    pub fn UnloadMeshes(chunkManager: *ChunkManager, meshDistance: [3]u32, genDistance: @Vector(3, u32), playerPos: @Vector(3, i64), smallestLevel: i32) void {
        const unload = ztracy.ZoneNC(@src(), "UnloadMeshes", 75645);
        defer unload.End();
        {
            const loop = ztracy.ZoneNC(@src(), "loopMeshes", 6788676);
            defer loop.End();
            const innerRadius = getInnerRadius(genDistance);
            const bktamount = chunkManager.ChunkRenderList.buckets.len;
            outer: for (0..bktamount) |b| {
                chunkManager.ChunkRenderList.buckets[b].lock.lock();
                var it = chunkManager.ChunkRenderList.buckets[b].hash_map.keyIterator();
                defer chunkManager.ChunkRenderList.buckets[b].lock.unlock();
                while (it.next()) |key| {
                    const Pos = key.*;
                    if (meshesToUnloadBufferPos >= meshesToUnloadBuffer.len) break :outer;
                    const keep = keepLoaded(playerPos, Pos, if (Pos.level <= smallestLevel) @splat(0) else innerRadius, meshDistance);
                    if (keep) continue;
                    meshesToUnloadBuffer[meshesToUnloadBufferPos] = Pos;
                    meshesToUnloadBufferPos += 1;
                }
            }
        }
        if (meshesToUnloadBufferPos > 0) {
            const free = ztracy.ZoneNC(@src(), "freeMeshes", 8799877);
            defer free.End();
            for (meshesToUnloadBuffer[0..meshesToUnloadBufferPos]) |Pos| {
                const mesh = chunkManager.ChunkRenderList.fetchremove(Pos);
                if (mesh) |m| m.free();
            }
            meshesToUnloadBufferPos = 0;
        }
    }

    pub fn keepLoaded(playerPos: World.BlockPos, Pos: World.ChunkPos, innerChunkRange: @Vector(3, u32), outerChunkRange: @Vector(3, u32)) bool {
        const playerChunkPos = World.ChunkPos.fromBlockPos(playerPos, Pos.level);
        const inner: @Vector(3, i32) = @intCast(innerChunkRange);
        const outer: @Vector(3, i32) = @intCast(outerChunkRange);

        const player = playerChunkPos.position;
        const center = Pos.position;

        const insideInner =
            @reduce(.And, player > center - inner) and
            @reduce(.And, player < center + inner);

        const outsideOuter =
            @reduce(.Or, player < center - outer) or
            @reduce(.Or, player > center + outer);

        return !insideInner and !outsideOuter;
    }

    threadlocal var chunksToUnloadBuffer: [1024][3]i32 = undefined;
    threadlocal var chunksToUnloadBufferPos: u16 = 0;
    ///Loads all chunks in gendistance and unloads all chunks out of loadistance
    pub fn ChunkLoaderThread(game: *Game.Game, intervel_ns: u64) void {
        std.debug.assert(game.player.type == .Player);
        while (game.running.load(.monotonic)) {
            const playerPos = game.player.getPos().?;
            const addChunkstoLoad = ztracy.ZoneNC(@src(), "addChunksToLoad", 223);
            const st = std.time.nanoTimestamp();
            defer std.Thread.sleep(intervel_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
            const genDistance = @Vector(3, u32){ game.GenerateDistance[0].load(.monotonic), game.GenerateDistance[1].load(.monotonic), game.GenerateDistance[2].load(.monotonic) };
            const innerRadius = getInnerRadius(genDistance);
            var level = game.levels[0];
            while (level < game.levels[1]) {
                const currentInnerRadius: @Vector(3, u32) = if (level <= game.SmallestLevel) @splat(0) else innerRadius;
                LoadChunksSingleplayer(game, @intFromFloat(playerPos), genDistance, currentInnerRadius, level);
                level += 1;
            }

            addChunkstoLoad.End();
        }
    }

    fn getInnerRadius(genDistance: @Vector(3, u32)) @Vector(3, u32) {
        return (genDistance / @Vector(3, u32){ World.TreeDivisions, World.TreeDivisions, World.TreeDivisions }) -| @Vector(3, u32){ 1, 1, 1 };
    }

    pub fn ChunkUnloaderThread(game: *Game.Game, intervel_ns: u64) void {
        _ = game;
        _ = intervel_ns;
        // while (game.running.load(.monotonic)) {
        //     const playerPos = game.player.getPos().?;
        //   const unloadChunks = ztracy.ZoneNC(@src(), "unloadChunks", 223);
        //    const st = std.time.nanoTimestamp();
        //  defer std.Thread.sleep(intervel_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
        //  const loadDistance = @Vector(3, u32){ game.LoadDistance[0].load(.monotonic), game.LoadDistance[1].load(.monotonic), game.LoadDistance[2].load(.monotonic) };
        //  const floatPlayerChunkPos = playerPos / @as(@Vector(3, f64), @splat(32));
        // const playerChunkPos = @as(@Vector(3, i32), @intFromFloat(floatPlayerChunkPos));
        //UnloadChunks(&game.world, playerChunkPos, loadDistance) catch |err| std.debug.panic("err:{any}\n", .{err});
        // unloadChunks.End();
        //  }
    }

    ///loads chunks from top to bottom and in a spiral on a y level
    // threadlocal var lastLoadPlayerPos: ?@Vector(3, i64) = undefined;
    // threadlocal var lastGenDistance: ?@Vector(3, u32) = undefined;

    fn LoadChunksSingleplayer(game: *Game.Game, playerPos: @Vector(3, i64), distance: @Vector(3, u32), innerdistance: @Vector(3, u32), level: i32) void { //TODO optimize by spliting into stages and make hashmap calls happen with a array under one lock
        const playerChunkPos = World.ChunkPos.fromBlockPos((playerPos), level);
        //  defer {
        //    lastLoadPlayerPos = playerPos;
        //  lastGenDistance = distance;
        //  }
        //if (lastLoadPlayerPos != null and lastGenDistance != null) {
        //    if (@reduce(.And, lastLoadPlayerPos.? == playerPos) and @reduce(.And, lastGenDistance.? == distance)) return;
        // }

        var amount_loaded: u64 = 0;
        var amount_tested: u64 = 0;

        var xz: [2]i32 = .{ 0, 0 };
        var c: usize = 0;

        while (true) {
            if (amount_tested >= 4 * distance[0] * distance[2]) {
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
                    const ChunkPos: World.ChunkPos = .{ .position = [3]i32{ xz[0] + playerChunkPos.position[0], y + playerChunkPos.position[1], xz[1] + playerChunkPos.position[2] }, .level = level };
                    const insideInner = @reduce(.And, @Vector(3, u32){ @abs(xz[0]), @abs(y), @abs(xz[1]) } < innerdistance);
                    
                    if (insideInner or game.chunkManager.LoadingChunks.contains(ChunkPos)) {
                        continue;
                    }

                    const loaded = game.chunkManager.ChunkRenderList.contains(ChunkPos);
                    if ((!loaded or ((game.chunkManager.world.Chunks.get(ChunkPos) orelse continue).genstate.load(.seq_cst) == .TerrainGenerated))) {
                        amount_loaded += 1;
                        game.chunkManager.LoadingChunks.put(ChunkPos, true) catch |err| std.debug.panic("err:{any}\n", .{err});
                        game.chunkManager.pool.spawn(ChunkManager.AddChunkToRenderTask, .{ game, ChunkPos, true, true }, .Medium) catch |err| std.debug.panic("pool spawn failed: {any}\n", .{err});
                    }
                }
            }
        }
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
        bufferFull = chunksToUnloadBufferPos == chunksToUnloadBuffer.len;
        chunksToUnloadBufferPos = 0;
    }

    pub fn LoadMeshes(renderer: *Renderer.Renderer, game: *Game.Game, glSync: ?*gl.sync, min_us: u32, max_us: u32) !u64 {
        const loadMeshes = ztracy.ZoneNC(@src(), "LoadMeshes", 156567756);
        defer loadMeshes.End();
        const st = std.time.microTimestamp();
        var amount: u64 = 0;
        while (true) {
            var syncStatus: c_int = undefined;
            if (glSync) |sync| gl.GetSynciv(sync, gl.SYNC_STATUS, @sizeOf(c_int), null, @ptrCast(&syncStatus)) else syncStatus = gl.UNSIGNALED;
            if (std.time.microTimestamp() - st > max_us or (syncStatus == gl.SIGNALED and std.time.microTimestamp() - st > min_us)) break;
            const mesh = game.chunkManager.MeshesToLoad.popFirst() orelse break;
            defer mesh.free(game.allocator);
            defer _ = game.chunkManager.LoadingChunks.remove(mesh.Pos);
            if (mesh.TransperentFaces == null and mesh.faces == null) {
                _ = game.chunkManager.ChunkRenderList.remove(mesh.Pos);
                continue;
            }
            const ex = game.chunkManager.ChunkRenderList.get(mesh.Pos);
            defer amount += 1;
            var oldtime: ?i64 = null;
            if (ex) |m| {
                oldtime = m.time;
            }
            if (!mesh.animation) {
                oldtime = 0;
            }
            const mesh_buffer_ids = Loader.LoadMesh(renderer, mesh, oldtime);
            {
                const oldChunk = try game.chunkManager.ChunkRenderList.fetchPut(mesh.Pos, mesh_buffer_ids);
                if (oldChunk) |old_mesh| {
                    old_mesh.free();
                }
            }
        }
        return amount;
    }

    fn LoadMesh(renderer: *Renderer.Renderer, mesh: Mesher.Mesh, CreationTime: ?i64) MeshBufferIDs {
        var NewMeshIDs: MeshBufferIDs = .{
            .vao = [2]?c_uint{ null, null },
            .vbo = [2]?c_uint{ null, null },
            .count = [2]u32{ 0, 0 },
            .drawCommand = [2]?c_uint{ null, null },
            .UBO = undefined,
            .pos = mesh.Pos.position,
            .time = 0,
            .scale = @floatCast(World.ChunkPos.toScale(mesh.Pos.level)),
        };

        gl.GenBuffers(1, @ptrCast(&NewMeshIDs.UBO));
        gl.BindBuffer(gl.UNIFORM_BUFFER, NewMeshIDs.UBO);
        const UniformBuffer = UBO{
            .chunkPos = mesh.Pos.position,
            .scale = @floatCast(World.ChunkPos.toScale(mesh.Pos.level)),
            .creationTime = @floatFromInt(CreationTime orelse std.time.milliTimestamp()),
            ._0 = undefined,
        };
        gl.BufferData(gl.UNIFORM_BUFFER, @sizeOf(UBO), @ptrCast(&UniformBuffer), gl.STATIC_DRAW);

        inline for (0..2) |i| {
            const faces = if (i == 0) mesh.faces else mesh.TransperentFaces;
            if (faces) |f| {
                var a: c_uint = undefined;
                var b: c_uint = undefined;
                gl.GenVertexArrays(1, @ptrCast(&a));
                gl.BindVertexArray(a);
                gl.GenBuffers(1, @ptrCast(&b));
                gl.BindBuffer(gl.ARRAY_BUFFER, b);
                NewMeshIDs.vao[i] = a;
                NewMeshIDs.vbo[i] = b;
                const bytes = std.mem.sliceAsBytes(f);
                gl.BufferData(gl.ARRAY_BUFFER, @intCast(@sizeOf(Mesher.Face) * f.len), bytes.ptr, gl.STATIC_DRAW);
                NewMeshIDs.count[i] = @intCast(f.len);
                gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, renderer.indecies);
                gl.BindBuffer(gl.ARRAY_BUFFER, renderer.facebuffer);
                gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(f32), 0);
                gl.EnableVertexAttribArray(0);
                gl.BindBuffer(gl.ARRAY_BUFFER, b);
                gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(u32), 0);
                gl.EnableVertexAttribArray(1);
                gl.VertexAttribDivisor(1, 1);
                var indirectBuff: c_uint = undefined;
                gl.GenBuffers(1, @ptrCast(&indirectBuff));
                gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, indirectBuff);
                const IndirectCommand: DrawElementsIndirectCommand = .{
                    .count = 6,
                    .baseInstance = 0,
                    .baseVertex = 0,
                    .firstIndex = 0,
                    .instanceCount = @intCast(NewMeshIDs.count[i]),
                };
                gl.BufferData(gl.DRAW_INDIRECT_BUFFER, @sizeOf(DrawElementsIndirectCommand), &IndirectCommand, gl.STATIC_DRAW);
                NewMeshIDs.drawCommand[i] = indirectBuff;
            }
        }
        NewMeshIDs.time = CreationTime orelse std.time.milliTimestamp();

        gl.BindBuffer(gl.ARRAY_BUFFER, 0);
        gl.BindVertexArray(0);
        return NewMeshIDs;
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
};
