const std = @import("std");
const ConcurrentQueue = @import("ConcurrentQueue");

const root = @import("main.zig");
const ChunkManager = root.ChunkManager;
const DrawElementsIndirectCommand = root.Renderer.DrawElementsIndirectCommand;
const MeshBufferIDs = root.Renderer.MeshBufferIDs;
const Renderer = root.Renderer;
const UBO = root.Renderer.UBO;
const ThreadPool = @import("ThreadPool");

const Chunk = @import("Chunk");
const ChunkSize = Chunk.ChunkSize;
const Entity = @import("Entity").Entity;
const gl = @import("gl");
const World = @import("world/World.zig");
const ztracy = @import("ztracy");

const Game = @import("Game.zig");
const Mesher = @import("Mesher.zig");
const outOfSquareRange = @import("libs/utils.zig").outOfSquareRange;

pub fn UnloadMeshes(game: *Game.Game, gen_distance: @Vector(2, u32), playerPos: @Vector(3, f64)) void {
    const unload = ztracy.ZoneNC(@src(), "UnloadMeshes", 75645);
    defer unload.End();
    var meshesToUnloadBuffer: [256]World.ChunkPos = undefined;
    var meshesToUnloadBufferPos: usize = 0;
    const mesh_distance = gen_distance;
    {
        const loop = ztracy.ZoneNC(@src(), "loopMeshes", 6788676);
        defer loop.End();
        var list_it = game.chunkManager.ChunkRenderList.iterator();
        defer list_it.deinit();
        while (list_it.next()) |entry| {
            const Pos: World.ChunkPos = entry.key_ptr.*;
            const innerRadius = game.getInnerGenRadius(Pos.level);
            if (meshesToUnloadBufferPos >= meshesToUnloadBuffer.len) break;
            const keep = keepLoaded(playerPos, Pos, innerRadius, mesh_distance);
            if (keep) continue;
            meshesToUnloadBuffer[meshesToUnloadBufferPos] = Pos;
            meshesToUnloadBufferPos += 1;
        }
    }

    if (meshesToUnloadBufferPos > 0) {
        const free = ztracy.ZoneNC(@src(), "freeMeshes", 8799877);
        defer free.End();
        for (meshesToUnloadBuffer[0..meshesToUnloadBufferPos]) |Pos| {
            const mesh = game.chunkManager.ChunkRenderList.fetchremove(Pos);
            if (mesh) |m| m.free();
        }
        meshesToUnloadBufferPos = 0;
    }
}

pub fn keepLoaded(playerPos: @Vector(3, f64), Pos: World.ChunkPos, innerChunkRange: ?@Vector(2, u32), outerChunkRange: ?@Vector(2, u32)) bool {
    const playerChunkPos = @floor(playerPos / @as(@Vector(3, f64), @splat(World.ChunkPos.levelToBlockRatioFloat(Pos.level))));
    const center: @Vector(3, f64) = @floatFromInt(Pos.position);
    if (innerChunkRange) |icr| {
        const inner: @Vector(3, f64) = .{ @floatFromInt(icr[0]), @floatFromInt(icr[1]), @floatFromInt(icr[0]) };
        const insideInner =
            @reduce(.And, playerChunkPos > center - inner) and
            @reduce(.And, playerChunkPos < center + inner);
        if (insideInner) return false;
    }

    if (outerChunkRange) |ocr| {
        const outer: @Vector(3, f64) = .{ @floatFromInt(ocr[0]), @floatFromInt(ocr[1]), @floatFromInt(ocr[0]) };
        const outsideOuter =
            @reduce(.Or, playerChunkPos < center - outer) or
            @reduce(.Or, playerChunkPos > center + outer);
        if (outsideOuter) return false;
    }
    return true;
}

///Loads all chunks in gendistance and unloads all chunks out of loadistance
pub fn ChunkLoaderThread(game: *Game.Game, intervel_ns: u64) void {
    std.debug.assert(game.player.type == .Player);
    while (game.running.load(.monotonic)) {
        const playerPos = game.player.getPos().?;
        const addChunkstoLoad = ztracy.ZoneNC(@src(), "addChunksToLoad", 223);
        const st = std.time.nanoTimestamp();
        defer std.Thread.sleep(intervel_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
        const genDistance = game.getGenDistance();
        var level = game.levels[0];
        while (level < game.levels[1]) : (level += 1) {
            loadChunksSpiral(game, (playerPos), genDistance, game.getInnerGenRadius(level), level) catch unreachable;
        }

        addChunkstoLoad.End();
    }
}

///loads chunks from top to bottom and in a spiral on a y level
fn loadChunksSpiral(game: *Game.Game, playerPos: @Vector(3, f64), dist: @Vector(2, u32), innerdistance: @Vector(2, u32), level: i32) !void {
    const playerChunkPos = World.ChunkPos.fromGlobalBlockPos(@intFromFloat(playerPos), level);
    var amount_loaded: u64 = 0;
    var amount_tested: u64 = 0;

    var xz: [2]i32 = .{ 0, 0 };
    var c: usize = 0;

    const distance = dist;
    while (true) {
        if (amount_tested >= 4 * distance[0] * distance[0]) {
            break;
        }

        const m = Move(xz, &c);

        var cc: i32 = 0;
        while (Line(&xz, &cc, m)) {
            amount_tested += 1;
            std.debug.assert(cc <= 2 * @max(distance[0], distance[0]));
            var y: i32 = -@as(i32, @intCast(distance[1]));
            while (y < distance[1]) {
                defer y += 1;
                const ChunkPos: World.ChunkPos = .{ .position = [3]i32{ xz[0] + playerChunkPos.position[0], y + playerChunkPos.position[1], xz[1] + playerChunkPos.position[2] }, .level = level };

                const in_range = keepLoaded(playerPos, ChunkPos, innerdistance, distance);
                if (!in_range or game.chunkManager.LoadingChunks.contains(ChunkPos)) {
                    continue;
                }

                const loaded = game.chunkManager.ChunkRenderList.contains(ChunkPos);

                if ((!loaded or (game.chunkManager.world.getGenState(ChunkPos) orelse continue) == .TerrainGenerated)) {
                    amount_loaded += 1;
                    try game.chunkManager.LoadingChunks.put(ChunkPos, undefined);
                    const priority: ThreadPool.Priority = switch (level) {
                        std.math.minInt(i32)...-1 => .High,
                        0...2 => .High,
                        3...5 => .Medium,
                        6...10 => .Low,
                        11...20 => .VeryLow,
                        else => .VeryLow,
                    };
                    try game.chunkManager.pool.spawn(ChunkManager.AddChunkToRenderTask, .{ game, ChunkPos, true }, priority);
                }
            }
        }
    }
}

pub fn LoadMeshes(renderer: *Renderer, game: *Game.Game, glSync: ?*gl.sync, min_us: u32, max_us: u32) !u64 {
    const loadMeshes = ztracy.ZoneNC(@src(), "LoadMeshes", 156567756);
    defer loadMeshes.End();
    const st = std.time.microTimestamp();
    var amount: u64 = 0;
    const player_pos = game.player.getPos().?;
    while (true) {
        var syncStatus: c_int = undefined;
        if (glSync) |sync| gl.GetSynciv(sync, gl.SYNC_STATUS, @sizeOf(c_int), null, @ptrCast(&syncStatus)) else syncStatus = gl.UNSIGNALED;
        if (std.time.microTimestamp() - st > max_us or (syncStatus == gl.SIGNALED and std.time.microTimestamp() - st > min_us)) break;
        const mesh = game.chunkManager.MeshesToLoad.popFirst() orelse break;
        defer mesh.free(game.allocator);
        defer _ = game.chunkManager.LoadingChunks.remove(mesh.Pos);
        const isempty = mesh.faces == null and mesh.TransperentFaces == null;
        const inside_range = keepLoaded(player_pos, mesh.Pos, game.getInnerGenRadius(mesh.Pos.level), game.getGenDistance());
        if (isempty or !inside_range) {
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
        const mesh_buffer_ids = LoadMesh(renderer, mesh, oldtime);
        {
            const oldChunk = try game.chunkManager.ChunkRenderList.fetchPut(mesh.Pos, mesh_buffer_ids);
            if (oldChunk) |old_mesh| {
                old_mesh.free();
            }
        }
    }
    return amount;
}

fn LoadMesh(renderer: *Renderer, mesh: Mesher.Mesh, CreationTime: ?i64) MeshBufferIDs {
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
