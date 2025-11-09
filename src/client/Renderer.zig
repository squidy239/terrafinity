const std = @import("std");
const builtin = @import("builtin");
const ConcurrentQueue = @import("root").ConcurrentQueue;
const SetThreadPriority = @import("root").SetThreadPriority;
const ThreadPool = @import("root").ThreadPool;

const Block = @import("Block").Blocks;
const Chunk = @import("Chunk").Chunk;
const ChunkSize = Chunk.ChunkSize;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Entity = @import("Entity").Entity;
const gl = @import("gl");
const glfw = @import("zglfw");
const Player = @import("EntityTypes").Player;
const UpdateEntitiesThread = @import("Entity").TickEntitiesThread;
const World = @import("World").World;
const zm = @import("zm");
const ztracy = @import("ztracy");

const Mesher = @import("Mesher.zig");
const Textures = @import("textures.zig");

pub const Renderer = struct {
    pub const cameraUp = @Vector(3, f64){ 0, 1, 0 };
    allocator: std.mem.Allocator,
    pool: ThreadPool,
    world: *World,
    running: std.atomic.Value(bool),
    facebuffer: c_uint,
    player: *Entity,
    cameraFront: @Vector(3, f64),
    mouseSensitivity: f64,
    indecies: c_uint,
    entityshaderprogram: c_uint,
    shaderprogram: c_uint,
    blockAtlasTextureId: c_uint,
    LoadingChunks: ConcurrentHashMap([3]i32, bool, std.hash_map.AutoContext([3]i32), 80, 32),
    uniforms: UniformLocations,
    MeshesToLoad: ConcurrentQueue.ConcurrentQueue(Mesher.Mesh, 32, true),
    MeshesToUnload: ConcurrentQueue.ConcurrentQueue([3]i32, 32, true),

    ChunkRenderList: std.AutoArrayHashMap([3]i32, MeshBufferIDs),
    ChunkRenderListLock: std.Thread.RwLock,
    MeshDistance: [3]std.atomic.Value(u32),
    GenerateDistance: [3]std.atomic.Value(u32),
    LoadDistance: [3]std.atomic.Value(u32),
    renderScale: f32,
    loaderThread: ?std.Thread,
    unloaderThread: ?std.Thread,
    updateEntitiesThread: ?std.Thread,

    ///must be called on main thread
    pub fn init(world: *World, player: *Entity, allocator: std.mem.Allocator) !@This() {
        const GenDist: [2]u32 = if (builtin.mode == .Debug) [2]u32{ 10, 10 } else [2]u32{ 20, 20 }; //x,y
        const LoadDist: [2]u32 = if (builtin.mode == .Debug) [2]u32{ 12, 12 } else [2]u32{ 22, 22 }; //x,y
        const MeshDist: [2]u32 = if (builtin.mode == .Debug) [2]u32{ 12, 12 } else [2]u32{ 22, 22 }; //x,y
        std.debug.assert(player.type == .Player);
        _ = player.ref_count.fetchAdd(1, .seq_cst);
        var renderer = @This(){
            .allocator = allocator,
            .pool = undefined,
            .world = world,
            .running = .init(true),
            .mouseSensitivity = 0.2,
            .cameraFront = @Vector(3, f64){ 0.0001, -0.4, 0.001 },
            .facebuffer = undefined,
            .indecies = undefined,
            .shaderprogram = undefined,
            .entityshaderprogram = undefined,
            .MeshesToLoad = try .init(allocator),
            .MeshesToUnload = try .init(allocator),
            .blockAtlasTextureId = undefined,
            .uniforms = undefined,
            .player = player,
            .ChunkRenderList = std.AutoArrayHashMap([3]i32, MeshBufferIDs).init(allocator),
            .ChunkRenderListLock = .{},
            .LoadingChunks = ConcurrentHashMap([3]i32, bool, std.hash_map.AutoContext([3]i32), 80, 32).init(allocator),
            .GenerateDistance = [3]std.atomic.Value(u32){ std.atomic.Value(u32).init(GenDist[0]), std.atomic.Value(u32).init(GenDist[1]), std.atomic.Value(u32).init(GenDist[0]) },
            .LoadDistance = [3]std.atomic.Value(u32){ std.atomic.Value(u32).init(LoadDist[0]), std.atomic.Value(u32).init(LoadDist[1]), std.atomic.Value(u32).init(LoadDist[0]) }, //should be 2 or over gendistance
            .MeshDistance = [3]std.atomic.Value(u32){ std.atomic.Value(u32).init(MeshDist[0]), std.atomic.Value(u32).init(MeshDist[1]), std.atomic.Value(u32).init(MeshDist[0]) }, //must 2 or over gendistance to prevent infinite loop of loading and unloading
            .renderScale = 1.0,
            .loaderThread = null,
            .unloaderThread = null,
            .updateEntitiesThread = null,
        };
        try renderer.CompileShaders();
        renderer.LoadFacebuffer();
        renderer.uniforms = UniformLocations.GetLocations(renderer.shaderprogram, renderer.entityshaderprogram);
        renderer.blockAtlasTextureId = try Textures.loadTextureArray(try std.fs.cwd().openDir("packs/default/Blocks/", .{ .iterate = true }), allocator);
        return renderer;
    }

    pub fn Start(self: *@This()) !void {
        const cpu_count = try std.Thread.getCpuCount();
        try self.pool.init(.{ .n_jobs = cpu_count - 1, .allocator = self.allocator });
        self.loaderThread = try std.Thread.spawn(.{}, Renderer.ChunkLoaderThread, .{ self, 40 * std.time.ns_per_ms, self.player, &self.running });
        self.unloaderThread = try std.Thread.spawn(.{}, Renderer.ChunkUnloaderThread, .{ self.world, &self.LoadDistance, self.player, 5 * std.time.ns_per_ms, &self.running });
        self.updateEntitiesThread = try std.Thread.spawn(.{}, UpdateEntitiesThread, .{ self.world, 5 * std.time.ns_per_ms, &self.running });
    }

    pub fn onEditFn(chunkPos: [3]i32, args: *anyopaque) void {
        const renderer = @as(*Renderer, @ptrCast(@alignCast(args)));
        renderer.AddChunkToRender(chunkPos, false) catch |err| std.log.err("err: {any}", .{err});
    }

    ///threadpool should be deinitualised before calling, dosent destroy window
    pub fn deinit(self: *@This()) void {
        self.running.store(false, .monotonic);
        if (self.updateEntitiesThread) |thread| thread.join();
        if (self.loaderThread) |thread| thread.join();
        if (self.unloaderThread) |thread| thread.join();
        std.log.info("stopped threads", .{});
        self.pool.deinit();
        std.log.info("closed threadpool", .{});
        _ = self.player.ref_count.fetchSub(1, .seq_cst);
        gl.DeleteTextures(1, @ptrCast(&self.blockAtlasTextureId));
        gl.DeleteBuffers(1, @ptrCast(&self.indecies));
        gl.DeleteBuffers(1, @ptrCast(&self.facebuffer));
        gl.DeleteProgram(self.shaderprogram);
        gl.DeleteProgram(self.entityshaderprogram);
        self.ChunkRenderListLock.lock();
        var it = self.ChunkRenderList.iterator();
        while (it.next()) |mesh| {
            mesh.value_ptr.free();
        }
        self.ChunkRenderList.deinit();
        self.LoadingChunks.deinit();
        while (self.MeshesToLoad.popFirst()) |mesh| {
            FreeMesh(mesh, self.allocator);
        }
        self.MeshesToLoad.deinit(true);
        self.MeshesToUnload.deinit(true);
        std.log.info("renderer deinit", .{});
    }

    fn CompileShaders(self: *@This()) !void {
        const vertexshader = gl.CreateShader(gl.VERTEX_SHADER);
        gl.ShaderSource(vertexshader, 1, @ptrCast(&@embedFile("./vertexshader.vert")), null);
        gl.CompileShader(vertexshader);

        const fragshader = gl.CreateShader(gl.FRAGMENT_SHADER);
        gl.ShaderSource(fragshader, 1, @ptrCast(&@embedFile("./fragshader.frag")), null);
        gl.CompileShader(fragshader);

        const shaderprogram = gl.CreateProgram();
        gl.AttachShader(shaderprogram, vertexshader);
        gl.AttachShader(shaderprogram, fragshader);
        gl.LinkProgram(shaderprogram);
        var linkstatus: c_int = undefined;
        gl.GetProgramiv(shaderprogram, gl.LINK_STATUS, @ptrCast(&linkstatus));
        if (linkstatus == gl.FALSE) {
            var vsbuffer: [1000]u8 = undefined;
            var fsbuffer: [1000]u8 = undefined;
            var plog: [1000]u8 = undefined;
            gl.GetShaderInfoLog(vertexshader, 1000, null, &vsbuffer);
            gl.GetShaderInfoLog(fragshader, 1000, null, &fsbuffer);
            gl.GetProgramInfoLog(shaderprogram, 1000, null, &plog);
            std.debug.panic("{s}\n\n{s}\n\n{s}", .{ vsbuffer, fsbuffer, plog });
            return error.ShaderCompilationFailed;
        }
        gl.DeleteShader(vertexshader);
        gl.DeleteShader(fragshader);
        self.shaderprogram = shaderprogram;

        const entityvertexshader = gl.CreateShader(gl.VERTEX_SHADER);
        gl.ShaderSource(entityvertexshader, 1, @ptrCast(&@embedFile("./EntityVertexShader.vert")), null);
        gl.CompileShader(entityvertexshader);

        const entityfragshader = gl.CreateShader(gl.FRAGMENT_SHADER);
        gl.ShaderSource(entityfragshader, 1, @ptrCast(&@embedFile("./EntityFragmentShader.frag")), null);
        gl.CompileShader(entityfragshader);

        const entityshaderprogram = gl.CreateProgram();
        gl.AttachShader(entityshaderprogram, entityvertexshader);
        gl.AttachShader(entityshaderprogram, entityfragshader);
        gl.LinkProgram(entityshaderprogram);
        var elinkstatus: c_int = undefined;
        gl.GetProgramiv(entityshaderprogram, gl.LINK_STATUS, @ptrCast(&elinkstatus));
        if (elinkstatus == gl.FALSE) {
            var vsbuffer: [1000]u8 = undefined;
            var fsbuffer: [1000]u8 = undefined;
            var plog: [1000]u8 = undefined;
            gl.GetShaderInfoLog(entityvertexshader, 1000, null, &vsbuffer);
            gl.GetShaderInfoLog(entityfragshader, 1000, null, &fsbuffer);
            gl.GetProgramInfoLog(entityshaderprogram, 1000, null, &plog);
            std.debug.panic("{s}\n\n{s}\n\n{s}", .{ vsbuffer, fsbuffer, plog });
            return error.ShaderCompilationFailed;
        }
        gl.DeleteShader(entityvertexshader);
        gl.DeleteShader(entityfragshader);
        self.entityshaderprogram = entityshaderprogram;
    }

    fn LoadFacebuffer(self: *@This()) void {
        const vertices = [_]f32{
            -0.5, -0.5, 0.0, // bottom left corner
            -0.5, 0.5, 0.0, // top left corner
            0.5, 0.5,  0.0, // top right corner
            0.5, -0.5, 0.0,
        }; // bottom right corner

        const indices = [_]u32{
            0, 1, 2, // first triangle (bottom left - top left - top right)
            0, 2, 3,
        };

        gl.GenBuffers(1, @ptrCast(&self.indecies));
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.indecies);
        gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @sizeOf(u32) * indices.len, &indices, gl.STATIC_DRAW);

        gl.GenBuffers(1, @ptrCast(&self.facebuffer));
        gl.BindBuffer(gl.ARRAY_BUFFER, self.facebuffer);
        gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(f32) * vertices.len, &vertices, gl.STATIC_DRAW);
        gl.VertexAttribPointer(0, 3, gl.FLOAT, 0, 3 * @sizeOf(f32), 0);
        gl.EnableVertexAttribArray(0);
    }
    pub fn Draw(self: *@This(), viewport_pixels: @Vector(2, f32)) ![2]u64 {
        const playerPos = self.player.GetPos().?;
        //draw chunks
        const blueSky = @Vector(4, f32){ 0, 0.4, 0.8, 1.0 };
        const greySky = @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 };
        const skyColor = std.math.lerp(blueSky, greySky, @as(@Vector(4, f32), @splat(@as(f32, @floatCast(@min(1.0, @max(0, playerPos[1] / 4096)))))));
        const clear = ztracy.ZoneNC(@src(), "Clear", 32213);
        gl.ClearColor(skyColor[0], skyColor[1], skyColor[2], skyColor[3]);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.Clear(gl.DEPTH_BUFFER_BIT);
        clear.End();

        const drawChunks = ztracy.ZoneNC(@src(), "DrawChunks", 24342);
        const drawn = self.DrawChunks(playerPos, skyColor, viewport_pixels);
        drawChunks.End();
        const drawEntities = ztracy.ZoneNC(@src(), "drawEntities", 24342);
        self.DrawEntities(playerPos, viewport_pixels);
        drawEntities.End();
        const meshDistance = [3]u32{ self.MeshDistance[0].load(.seq_cst), self.MeshDistance[1].load(.seq_cst), self.MeshDistance[2].load(.seq_cst) };
        const floatPlayerChunkPos = playerPos / @as(@Vector(3, f64), @splat(ChunkSize));
        const playerChunkPos = @as(@Vector(3, i32), @intFromFloat(floatPlayerChunkPos));
        const unloadMeshes = ztracy.ZoneNC(@src(), "unloadMeshes", 54333);
        self.UnloadMeshes(meshDistance, playerChunkPos);
        unloadMeshes.End();
        {
            const glSync = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0) orelse null;
            defer if (glSync) |sync| gl.DeleteSync(sync);
            _ = try self.LoadMeshes(glSync, 1 * std.time.us_per_ms, 20 * std.time.us_per_ms);
        }
        return drawn;
    }
    fn DrawChunks(self: *@This(), playerPos: @Vector(3, f64), skyColor: @Vector(4, f32), viewport_pixels: @Vector(2, f32)) [2]u64 {
        gl.FrontFace(gl.CW);
        gl.UseProgram(self.shaderprogram);
        gl.BindTexture(gl.TEXTURE_2D_ARRAY, self.blockAtlasTextureId);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.indecies);
        const sunrot = zm.Mat4f.rotation(@Vector(3, f32){ 1.0, 0.0, 0.0 }, std.math.degreesToRadians(180));
        const projdist = 2 * 32 * @max(@max(self.MeshDistance[0].load(.seq_cst), self.MeshDistance[1].load(.seq_cst)), self.MeshDistance[2].load(.seq_cst));
        const view = zm.Mat4.lookAt(@Vector(3, f32){ 0, 0, 0 }, self.cameraFront, Renderer.cameraUp);
        const projection = zm.Mat4.perspective(std.math.degreesToRadians(90.0), viewport_pixels[0] / viewport_pixels[1], 0.1, @floatFromInt(projdist));
        const projview = @as(@Vector(16, f32), @floatCast(projection.multiply(view).data));
        gl.Uniform4f(self.uniforms.skyColor, skyColor[0], skyColor[1], skyColor[2], skyColor[3]);
        gl.Uniform1f(self.uniforms.fogDensity, 0);
        gl.UniformMatrix4fv(self.uniforms.sunlocation, 1, gl.TRUE, @ptrCast(&(sunrot)));
        gl.UniformMatrix4fv(self.uniforms.projviewlocation, 1, gl.TRUE, @ptrCast(&(projview)));
        self.ChunkRenderListLock.lockShared();
        defer self.ChunkRenderListLock.unlockShared();

        //std.debug.print("{d}\n", .{MainWorld.ChunkMeshes.items.len});
        var drawnchunks: u64 = 0;
        var torenderchunks: u64 = 0;
        const millitimestamp = std.time.milliTimestamp();
        gl.Uniform1d(self.uniforms.timelocation, @floatFromInt(millitimestamp));
        gl.Uniform3d(self.uniforms.playerposlocation, playerPos[0], playerPos[1], playerPos[2]);
        const frustrum = Frustum.extractFrustumPlanes(projview);
        inline for (0..2) |i| {
            if (i == 1) gl.Disable(gl.CULL_FACE);
            defer gl.Enable(gl.CULL_FACE);

            var it = self.ChunkRenderList.iterator();
            while (it.next()) |item| {
                torenderchunks += 1;
                const buffer_ids = item.value_ptr;
                const Pos: @Vector(3, i32) = item.key_ptr.*;
                const chunkSizeVec: @Vector(3, f32) = @splat(@floatCast(ChunkSize * buffer_ids.scale));
                const relativeChunkPos: @Vector(3, f32) = @floatCast((@as(@Vector(3, f32), @floatFromInt(Pos)) * chunkSizeVec) - playerPos);
                const cull = frustrum.boxInFrustum(.{ .max = relativeChunkPos + chunkSizeVec, .min = relativeChunkPos });
                if (!cull) continue;
                drawnchunks += 1;
                gl.BindVertexArray(buffer_ids.vao[i] orelse continue);
                gl.BindBufferBase(gl.UNIFORM_BUFFER, 0, buffer_ids.UBO);
                gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, buffer_ids.drawCommand[i].?);
                gl.DrawElementsIndirect(gl.TRIANGLES, gl.UNSIGNED_INT, 0);
            }
        }
        return [2]u64{ drawnchunks, torenderchunks };
    }

    pub fn DrawEntities(self: *@This(), playerPos: @Vector(3, f64), viewport_pixels: @Vector(2, f32)) void {
        gl.FrontFace(gl.CCW);
        gl.UseProgram(self.entityshaderprogram);
        const projview = @as(@Vector(16, f32), @floatCast(zm.Mat4.perspective(std.math.degreesToRadians(90.0), viewport_pixels[0] / viewport_pixels[1], 0.1, @floatFromInt(2000 * 32)).multiply(zm.Mat4.lookAt(@Vector(3, f32){ 0, 0, 0 }, @Vector(3, f32){ 0, 0, 0 } + self.cameraFront, Renderer.cameraUp)).data));
        gl.UniformMatrix4fv(self.uniforms.entityprojviewlocation, 1, gl.TRUE, @ptrCast(&(projview)));
        const enbktamount = self.world.Entitys.buckets.len;
        for (0..enbktamount) |b| {
            self.world.Entitys.buckets[b].lock.lockShared();
            var it = self.world.Entitys.buckets[b].hash_map.valueIterator();
            defer self.world.Entitys.buckets[b].lock.unlockShared();
            while (it.next()) |c| {
                // std.debug.print("drawn: {any}\n", .{c.*.*});
                _ = c.*.ref_count.fetchAdd(1, .seq_cst);
                defer _ = c.*.ref_count.fetchSub(1, .seq_cst);
                try c.*.draw(playerPos, self);
            }
        }
    }
    ///Adds a chunk to the render list replacing it if it already exists, generates it or its neighbors if it dosent exist
    threadlocal var blocks: *[ChunkSize][ChunkSize][ChunkSize]Block = undefined;
    threadlocal var Tempcube: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
    pub fn AddChunkToRender(self: *@This(), Pos: [3]i32, genStructures: bool) !void {
        const GenMeshAndAdd = ztracy.ZoneNC(@src(), "GenMeshAndAdd", 324342342);
        defer GenMeshAndAdd.End();
        const chunk = try self.world.LoadChunk(Pos, genStructures);
        const neighbor_faces = [6][ChunkSize][ChunkSize]Block{
            (try self.world.LoadChunk(Pos + @Vector(3, i32){ 1, 0, 0 }, false)).extractFace(.xMinus, true),
            (try self.world.LoadChunk(Pos + @Vector(3, i32){ -1, 0, 0 }, false)).extractFace(.xPlus, true),
            (try self.world.LoadChunk(Pos + @Vector(3, i32){ 0, 1, 0 }, false)).extractFace(.yMinus, true),
            (try self.world.LoadChunk(Pos + @Vector(3, i32){ 0, -1, 0 }, false)).extractFace(.yPlus, true),
            (try self.world.LoadChunk(Pos + @Vector(3, i32){ 0, 0, 1 }, false)).extractFace(.zMinus, true),
            (try self.world.LoadChunk(Pos + @Vector(3, i32){ 0, 0, -1 }, false)).extractFace(.zPlus, true),
        };
        const exbl = ztracy.ZoneNC(@src(), "extractBlocks", 3222);
        const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
        chunk.lock.lockShared();
        lock.End();
        switch (chunk.blocks) {
            .blocks => blocks = chunk.blocks.blocks,
            .oneBlock => {
                @memset(@as(*[ChunkSize * ChunkSize * ChunkSize]Block, @ptrCast(&Tempcube)), chunk.blocks.oneBlock);
                blocks = &Tempcube;
            },
        }
        exbl.End();
        const mesh = Mesher.Mesh.MeshFromChunks(Pos, blocks, &neighbor_faces, self.renderScale, self.allocator);
        chunk.releaseAndUnlockShared();
        if (try mesh) |m| {
            _ = try self.MeshesToLoad.append(m);
        } else {
            self.ChunkRenderListLock.lockShared();
            const removeChunk = self.ChunkRenderList.contains(Pos);
            self.ChunkRenderListLock.unlockShared();
            if (removeChunk) _ = try self.MeshesToUnload.append(Pos);
        }
    }
    threadlocal var meshesToUnloadBuffer: [1024][3]i32 = undefined;
    threadlocal var meshesToUnloadBufferPos: usize = 0;
    pub fn UnloadMeshes(renderer: *@This(), meshDistance: [3]u32, playerChunkPos: @Vector(3, i32)) void {
        const unload = ztracy.ZoneNC(@src(), "UnloadMeshes", 75645);
        defer unload.End();
        while (renderer.MeshesToUnload.popFirst()) |Pos| {
            const meshIds = renderer.ChunkRenderList.fetchSwapRemove(Pos);
            if (meshIds) |m| m.value.free();
        }

        {
            const loop = ztracy.ZoneNC(@src(), "loopMeshes", 6788676);
            defer loop.End();
            renderer.ChunkRenderListLock.lockShared();
            defer renderer.ChunkRenderListLock.unlockShared();
            renderer.ChunkRenderList.lockPointers();
            defer renderer.ChunkRenderList.unlockPointers();
            const positions = renderer.ChunkRenderList.keys();
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
            if (!renderer.ChunkRenderListLock.tryLock()) {
                return;
            }
            for (meshesToUnloadBuffer[0..meshesToUnloadBufferPos]) |Pos| {
                const mesh = renderer.ChunkRenderList.fetchSwapRemove(Pos);
                if (mesh) |m| m.value.free();
            }
            renderer.ChunkRenderListLock.unlock();
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

    ///Adds a chunk to the render list, generates it or its neighbors if it dosent exist
    pub fn AddChunkToRenderTask(self: *@This(), Pos: [3]i32, genStructures: bool, cullOutsideGenDistance: bool) void {
        if (cullOutsideGenDistance) {
            const playerPos = self.player.GetPos().?;
            const floatPlayerChunkPos = playerPos / @as(@Vector(3, f64), @splat(ChunkSize));
            const GenDistance = [3]u32{ self.GenerateDistance[0].load(.seq_cst), self.GenerateDistance[1].load(.seq_cst), self.GenerateDistance[2].load(.seq_cst) };
            const playerChunkPos = @as(@Vector(3, i32), @intFromFloat(@round(floatPlayerChunkPos)));
            if (self.running.load(.monotonic) and !outOfSquareRange(Pos - playerChunkPos, [3]i32{ @intCast(GenDistance[0] + 2), @intCast(GenDistance[1] + 2), @intCast(GenDistance[2] + 2) })) {
                self.AddChunkToRender(Pos, genStructures) catch |err| std.debug.panic("addchunktorenderError:{any}", .{err});
            } else {
                _ = self.LoadingChunks.remove(Pos);
            }
        } else self.AddChunkToRender(Pos, genStructures) catch |err| std.debug.panic("addchunktorenderError:{any}", .{err});
    }

    fn outOfSquareRange(Pos: @Vector(3, i32), range: @Vector(3, i32)) bool {
        return @reduce(.Or, @as(@Vector(3, i32), @intCast(@abs(Pos))) > range);
    }
    ///must be called on main thread
    pub fn LoadMeshes(self: *@This(), glSync: ?*gl.sync, min_us: u32, max_us: u32) !u64 {
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
            const mesh = self.MeshesToLoad.popFirst() orelse break;
            defer FreeMesh(mesh, self.allocator);
            defer _ = self.LoadingChunks.remove(mesh.Pos);
            std.debug.assert(mesh.TransperentFaces != null or mesh.faces != null);
            // if(outOfSquareRange(mesh.Pos - playerChunkPos, [3]i32{ @intCast(meshDistance[0]), @intCast(meshDistance[1]), @intCast(meshDistance[2]) }))continue;//causes a bug TODO fix
            self.ChunkRenderListLock.lockShared();
            const ex = self.ChunkRenderList.get(mesh.Pos);
            self.ChunkRenderListLock.unlockShared();
            defer amount += 1;
            var oldtime: ?i64 = null;
            if (ex) |m| {
                oldtime = m.time;
            }
            const mesh_buffer_ids = self.LoadMesh(mesh, oldtime);
            {
                self.ChunkRenderListLock.lock();
                defer self.ChunkRenderListLock.unlock();
                const oldChunk = try self.ChunkRenderList.fetchPut(mesh.Pos, mesh_buffer_ids);
                if (oldChunk) |old_mesh| {
                    old_mesh.value.free();
                }
            }
        }
        return amount;
    }

    fn getLen(arraylist: anytype, lock: *std.Thread.RwLock) usize {
        lock.lockShared();
        defer lock.unlockShared();
        return arraylist.items.len;
    }

    pub fn FreeMesh(mesh: Mesher.Mesh, allocator: std.mem.Allocator) void {
        if (mesh.faces) |faces| allocator.free(faces);
        if (mesh.TransperentFaces) |tfaces| allocator.free(tfaces);
    }

    ///caller must free mesh, must be called from main thread, creation time is to keep animation state the same when remeshing
    fn LoadMesh(self: *@This(), mesh: Mesher.Mesh, CreationTime: ?i64) MeshBufferIDs {
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

    pub const MeshBufferIDs = struct {
        time: i64,
        vbo: [2]?c_uint,
        vao: [2]?c_uint,
        drawCommand: [2]?c_uint,
        UBO: c_uint,
        pos: [3]i32,
        count: [2]u32,
        scale: f32,

        pub fn free(self: *const @This()) void {
            inline for (0..2) |i| {
                if (self.vbo[i]) |vbo| gl.DeleteBuffers(1, @ptrCast(@constCast(&vbo)));
                if (self.vao[i]) |vao| gl.DeleteVertexArrays(1, @ptrCast(@constCast(&vao)));
                if (self.drawCommand[i]) |drawCommand| gl.DeleteBuffers(1, @ptrCast(@constCast(&drawCommand)));
                gl.DeleteBuffers(1, @ptrCast(&self.UBO));
            }
        }
    };

    const DrawElementsIndirectCommand = packed struct {
        count: c_uint,
        instanceCount: c_uint,
        firstIndex: c_uint,
        baseVertex: c_uint,
        baseInstance: c_uint,
    };

    pub const UBO = packed struct {
        scale: f32,
        _0: u32,
        creationTime: f64,
        chunkPos: @Vector(3, i32),
    };

    const Frustum = struct {
        frus: [6]@Vector(4, f64),

        pub const Box = struct {
            min: @Vector(3, f64),
            max: @Vector(3, f64),
        };

        fn extractFrustumPlanes(mat: @Vector(16, f64)) Frustum {
            // zm row-major
            const m00 = mat[0];
            const m01 = mat[1];
            const m02 = mat[2];
            const m03 = mat[3];
            const m10 = mat[4];
            const m11 = mat[5];
            const m12 = mat[6];
            const m13 = mat[7];
            const m20 = mat[8];
            const m21 = mat[9];
            const m22 = mat[10];
            const m23 = mat[11];
            const m30 = mat[12];
            const m31 = mat[13];
            const m32 = mat[14];
            const m33 = mat[15];

            var planes: [6]@Vector(4, f64) = undefined;

            planes[0] = @Vector(4, f64){ m30 + m00, m31 + m01, m32 + m02, m33 + m03 }; // Left
            planes[1] = @Vector(4, f64){ m30 - m00, m31 - m01, m32 - m02, m33 - m03 }; // Right
            planes[2] = @Vector(4, f64){ m30 + m10, m31 + m11, m32 + m12, m33 + m13 }; // Bottom
            planes[3] = @Vector(4, f64){ m30 - m10, m31 - m11, m32 - m12, m33 - m13 }; // Top
            planes[4] = @Vector(4, f64){ m30 + m20, m31 + m21, m32 + m22, m33 + m23 }; // Near
            planes[5] = @Vector(4, f64){ m30 - m20, m31 - m21, m32 - m22, m33 - m23 }; // Far

            // Normalize planes
            for (0..6) |i| {
                const n = @Vector(3, f64){ planes[i][0], planes[i][1], planes[i][2] };
                const len = @sqrt(zm.vec.dot(n, n));
                planes[i] /= @splat(len);
            }

            return Frustum{ .frus = planes };
        }

        pub fn boxInFrustum(self: *const @This(), box: Box) bool {
            // Check box against each of the 6 frustum planes
            inline for (0..6) |i| {
                var out: u32 = 0;
                const plane = self.frus[i];

                // Test all 8 corners of the box against this plane
                // Corner 1: min.x, min.y, min.z
                out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.min[0], box.min[1], box.min[2], 1.0 }) < 0.0);
                // Corner 2: max.x, min.y, min.z
                out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.max[0], box.min[1], box.min[2], 1.0 }) < 0.0);
                // Corner 3: min.x, max.y, min.z
                out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.min[0], box.max[1], box.min[2], 1.0 }) < 0.0);
                // Corner 4: max.x, max.y, min.z
                out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.max[0], box.max[1], box.min[2], 1.0 }) < 0.0);
                // Corner 5: min.x, min.y, max.z
                out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.min[0], box.min[1], box.max[2], 1.0 }) < 0.0);
                // Corner 6: max.x, min.y, max.z
                out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.max[0], box.min[1], box.max[2], 1.0 }) < 0.0);
                // Corner 7: min.x, max.y, max.z
                out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.min[0], box.max[1], box.max[2], 1.0 }) < 0.0);
                // Corner 8: max.x, max.y, max.z
                out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.max[0], box.max[1], box.max[2], 1.0 }) < 0.0);

                // If all 8 corners are outside this plane, the box is completely outside the frustum
                if (out == 8) return false;
            }

            return true;
        }

        pub fn sphereInFrustum(self: *const @This(), center: @Vector(3, f64), radius: f64) bool {
            for (self.frus) |plane| {
                const dist = plane[0] * center[0] + plane[1] * center[1] + plane[2] * center[2] + plane[3];
                if (dist < -radius) return false;
            }
            return true;
        }
    };

    const UniformLocations = struct {
        projviewlocation: c_int,
        entityprojviewlocation: c_int,
        relativechunkposlocation: c_int,
        relativeEntityposlocation: c_int,
        EntityRotationlocation: c_int,
        sunlocation: c_int,
        playerposlocation: c_int,
        fogDensity: c_int,
        skyColor: c_int,
        timelocation: c_int,

        pub fn GetLocations(shaderprogram: c_uint, entityshaderprogram: c_uint) @This() {
            return @This(){
                .projviewlocation = gl.GetUniformLocation(shaderprogram, "projview"),
                .entityprojviewlocation = gl.GetUniformLocation(entityshaderprogram, "ProjView"),
                .relativechunkposlocation = gl.GetUniformLocation(shaderprogram, "relativechunkpos"),
                .relativeEntityposlocation = gl.GetUniformLocation(entityshaderprogram, "RelativePos"),
                .EntityRotationlocation = gl.GetUniformLocation(entityshaderprogram, "Rotation"),
                .playerposlocation = gl.GetUniformLocation(shaderprogram, "playerPos"),
                .sunlocation = gl.GetUniformLocation(shaderprogram, "sunrot"),
                .skyColor = gl.GetUniformLocation(shaderprogram, "skyColor"),
                .fogDensity = gl.GetUniformLocation(shaderprogram, "fogDensity"),
                .timelocation = gl.GetUniformLocation(shaderprogram, "time"),
            };
        }
    };
};
