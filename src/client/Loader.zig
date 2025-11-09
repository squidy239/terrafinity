const std = @import("std");
const ChunkManager = @import("root").ChunkManager;
const ConcurrentQueue = @import("root").ConcurrentQueue;
const DrawElementsIndirectCommand = @import("root").Renderer.DrawElementsIndirectCommand;
const MeshBufferIDs = @import("root").Renderer.MeshBufferIDs;
const Renderer = @import("root").Renderer.Renderer;
const SetThreadPriority = @import("root").SetThreadPriority;
const ThreadPool = @import("root").ThreadPool;
const UBO = @import("root").Renderer.UBO;

const Chunk = @import("Chunk").Chunk;
const ChunkSize = Chunk.ChunkSize;
const Entity = @import("Entity").Entity;
const gl = @import("gl");
const World = @import("World").World;
const ztracy = @import("ztracy");

const Mesher = @import("Mesher.zig");
const outOfSquareRange = @import("utils.zig").outOfSquareRange;

pub const Loader = struct {
    threadlocal var meshesToUnloadBuffer: [1024][3]i32 = undefined;
    threadlocal var meshesToUnloadBufferPos: usize = 0;
    pub fn UnloadMeshes(chunkManager: *ChunkManager, meshDistance: [3]u32, playerChunkPos: @Vector(3, i32)) void {
        const unload = ztracy.ZoneNC(@src(), "UnloadMeshes", 75645);
        defer unload.End();
        while (chunkManager.MeshesToUnload.popFirst()) |Pos| {
            const meshIds = chunkManager.ChunkRenderList.fetchSwapRemove(Pos);
            if (meshIds) |m| m.value.free();
        }

        {
            const loop = ztracy.ZoneNC(@src(), "loopMeshes", 6788676);
            defer loop.End();
            chunkManager.ChunkRenderListLock.lockShared();
            defer chunkManager.ChunkRenderListLock.unlockShared();
            chunkManager.ChunkRenderList.lockPointers();
            defer chunkManager.ChunkRenderList.unlockPointers();
            const positions = chunkManager.ChunkRenderList.keys();
            for (positions) |Pos| {
                if (meshesToUnloadBufferPos < meshesToUnloadBuffer.len and outOfSquareRange(Pos - playerChunkPos, [3]i32{ @intCast(meshDistance[0]), @intCast(meshDistance[1]), @intCast(meshDistance[2]) })) {
                    meshesToUnloadBuffer[meshesToUnloadBufferPos] = Pos;
                    meshesToUnloadBufferPos += 1;
                }
            }
        }
        if (meshesToUnloadBufferPos > 0) {
            const free = ztracy.ZoneNC(@src(), "freeMeshes", 8799877);
            defer free.End();
            if (!chunkManager.ChunkRenderListLock.tryLock()) {
                return;
            }
            for (meshesToUnloadBuffer[0..meshesToUnloadBufferPos]) |Pos| {
                const mesh = chunkManager.ChunkRenderList.fetchSwapRemove(Pos);
                if (mesh) |m| m.value.free();
            }
            chunkManager.ChunkRenderListLock.unlock();
            meshesToUnloadBufferPos = 0;
        }
    }

    threadlocal var chunksToUnloadBuffer: [1024][3]i32 = undefined;
    threadlocal var chunksToUnloadBufferPos: u16 = 0;
    ///Loads all chunks in gendistance and unloads all chunks out of loaddistance
    pub fn ChunkLoaderThread(renderer: *Renderer, intervel_ns: u64, player: *Entity, running: *std.atomic.Value(bool)) void {
        _ = SetThreadPriority(.THREAD_PRIORITY_BELOW_NORMAL);
        std.debug.assert(player.type == .Player);
        while (running.load(.monotonic)) {
            const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
            player.lock.lockShared();
            lock.End();
            const playerPos = player.GetPos().?;
            player.lock.unlockShared();
            const addChunkstoLoad = ztracy.ZoneNC(@src(), "addChunksToLoad", 223);
            const st = std.time.nanoTimestamp();
            defer std.Thread.sleep(intervel_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
            const genDistance = @Vector(3, u32){ renderer.GenerateDistance[0].load(.monotonic), renderer.GenerateDistance[1].load(.monotonic), renderer.GenerateDistance[2].load(.monotonic) };
            const eyePosChunk = @as(@Vector(3, i32), @intFromFloat(@round(playerPos / @Vector(3, f64){ ChunkSize, ChunkSize, ChunkSize })));
            LoadChunksSingleplayer(renderer, eyePosChunk, genDistance);
            addChunkstoLoad.End();
        }
    }
    //TODO unload until done
    pub fn ChunkUnloaderThread(world: *World, loadDistancePtr: *[3]std.atomic.Value(u32), player: *Entity, intervel_ns: u64, running: *std.atomic.Value(bool)) void {
        _ = SetThreadPriority(.THREAD_PRIORITY_IDLE);
        while (running.load(.monotonic)) {
            const playerPos = player.GetPos().?;
            const unloadChunks = ztracy.ZoneNC(@src(), "unloadChunks", 223);
            const st = std.time.nanoTimestamp();
            defer std.Thread.sleep(intervel_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
            const loadDistance = @Vector(3, u32){ loadDistancePtr[0].load(.monotonic), loadDistancePtr[1].load(.monotonic), loadDistancePtr[2].load(.monotonic) };
            const floatPlayerChunkPos = playerPos / @as(@Vector(3, f64), @splat(32));
            const playerChunkPos = @as(@Vector(3, i32), @intFromFloat(floatPlayerChunkPos));
            UnloadChunks(world, playerChunkPos, loadDistance) catch |err| std.debug.panic("err:{any}\n", .{err});
            unloadChunks.End();
        }
    }
    ///loads chunks from top to bottom and in a spiral on a y level
    threadlocal var lastLoadPlayerChunkPos: ?@Vector(3, i32) = undefined;
    threadlocal var lastGenDistance: ?@Vector(3, u32) = undefined;

    fn LoadChunksSingleplayer(self: *Renderer, playerChunkPos: @Vector(3, i32), distance: @Vector(3, u32)) void { //TODO optimize by spliting into stages and make hashmap calls happen with a array under one lock
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
                    if (self.chunkManager.LoadingChunks.contains(ChunkPos)) {
                        continue;
                    }
                    const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
                    self.chunkManager.ChunkRenderListLock.lockShared();
                    lock.End();
                    const loaded = self.chunkManager.ChunkRenderList.contains(ChunkPos);
                    self.chunkManager.ChunkRenderListLock.unlockShared();
                    if ((!loaded or ((self.chunkManager.world.Chunks.get(ChunkPos) orelse continue).genstate.load(.seq_cst) == .TerrainGenerated))) {
                        amount_loaded += 1;
                        self.chunkManager.LoadingChunks.put(ChunkPos, true) catch |err| std.debug.panic("err:{any}\n", .{err});
                        self.chunkManager.pool.spawn(ChunkManager.AddChunkToRenderTask, .{ self, ChunkPos, true, true }, .Medium) catch |err| std.debug.panic("pool spawn failed: {any}\n", .{err});
                    }
                }
            }
        }
        //if (amount_loaded > 0) std.log.info("added {d} chunks to load\n", .{amount_loaded});
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
        //std.debug.print("tried to unload {d} chunks, {d} chunks loaded\n", .{ chunksToUnloadBufferPos, chunks });
        bufferFull = chunksToUnloadBufferPos == chunksToUnloadBuffer.len;
        chunksToUnloadBufferPos = 0;
    }

    ///must be called on main thread
    pub fn LoadMeshes(self: *Renderer, glSync: ?*gl.sync, min_us: u32, max_us: u32) !u64 {
        const loadMeshes = ztracy.ZoneNC(@src(), "LoadMeshes", 156567756);
        defer loadMeshes.End();
        const st = std.time.microTimestamp();
        var amount: u64 = 0;
        //      self.playerLock.lockShared();
        //    const playerPos = self.player.pos;
        //  self.playerLock.unlockShared();
        //   const meshDistance = [3]u32{ self.MeshDistance[0].load(.seq_cst), self.MeshDistance[1].load(.seq_cst), self.MeshDistance[2].load(.seq_cst) };
        //  const floatPlayerChunkPos = playerPos / @as(@Vector(3, f64), @splat(ChunkSize));
        //   const playerChunkPos = @as(@Vector(3, i32), @intFromFloat(floatPlayerChunkPos));
        while (true) {
            var syncStatus: c_int = undefined;
            if (glSync) |sync| gl.GetSynciv(sync, gl.SYNC_STATUS, @sizeOf(c_int), null, @ptrCast(&syncStatus)) else syncStatus = gl.UNSIGNALED;
            if (std.time.microTimestamp() - st > max_us or (syncStatus == gl.SIGNALED and std.time.microTimestamp() - st > min_us)) break;
            const mesh = self.chunkManager.MeshesToLoad.popFirst() orelse break;
            defer mesh.free(self.allocator);
            defer _ = self.chunkManager.LoadingChunks.remove(mesh.Pos);
            std.debug.assert(mesh.TransperentFaces != null or mesh.faces != null);
            // if(outOfSquareRange(mesh.Pos - playerChunkPos, [3]i32{ @intCast(meshDistance[0]), @intCast(meshDistance[1]), @intCast(meshDistance[2]) }))continue;//causes a bug TODO fix
            self.chunkManager.ChunkRenderListLock.lockShared();
            const ex = self.chunkManager.ChunkRenderList.get(mesh.Pos);
            self.chunkManager.ChunkRenderListLock.unlockShared();
            defer amount += 1;
            var oldtime: ?i64 = null;
            if (ex) |m| {
                oldtime = m.time;
            }
            const mesh_buffer_ids = Loader.LoadMesh(self, mesh, oldtime);
            {
                self.chunkManager.ChunkRenderListLock.lock();
                defer self.chunkManager.ChunkRenderListLock.unlock();
                const oldChunk = try self.chunkManager.ChunkRenderList.fetchPut(mesh.Pos, mesh_buffer_ids);
                if (oldChunk) |old_mesh| {
                    old_mesh.value.free();
                }
            }
        }
        return amount;
    }

    ///caller must free mesh, must be called from main thread, creation time is to keep animation state the same when remeshing
    fn LoadMesh(self: *Renderer, mesh: Mesher.Mesh, CreationTime: ?i64) MeshBufferIDs {
        var NewMeshIDs: MeshBufferIDs = .{
            .vao = [2]?c_uint{ null, null },
            .vbo = [2]?c_uint{ null, null },
            .count = [2]u32{ 0, 0 },
            .drawCommand = [2]?c_uint{ null, null },
            .UBO = undefined,
            .pos = mesh.Pos,
            .time = 0,
            .scale = mesh.scale,
        };

        gl.GenBuffers(1, @ptrCast(&NewMeshIDs.UBO));
        gl.BindBuffer(gl.UNIFORM_BUFFER, NewMeshIDs.UBO);
        const UniformBuffer = UBO{
            .chunkPos = mesh.Pos,
            .scale = 1,
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
                gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.indecies);
                gl.BindBuffer(gl.ARRAY_BUFFER, self.facebuffer);
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
