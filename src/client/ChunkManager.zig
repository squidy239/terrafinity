const std = @import("std");
const ConcurrentQueue = @import("root").ConcurrentQueue;
const root = @import("root");
const MeshBufferIDs = root.Renderer.MeshBufferIDs;
const Renderer = root.Renderer;
const Game = @import("Game.zig").Game;
const ThreadPool = @import("root").ThreadPool;

const Block = @import("Block").Blocks;
const Chunk = @import("Chunk").Chunk;
const ChunkSize = Chunk.ChunkSize;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const World = @import("World").World;
const ztracy = @import("ztracy");

const Mesher = @import("Mesher.zig");
const outOfSquareRange = @import("utils.zig").outOfSquareRange;

pub const ChunkManager = struct {
    allocator: std.mem.Allocator,
    pool: *ThreadPool,
    LoadingChunks: ConcurrentHashMap([3]i32, bool, std.hash_map.AutoContext([3]i32), 80, 32),
    MeshesToLoad: ConcurrentQueue.ConcurrentQueue(Mesher.Mesh, 32, true),
    MeshesToUnload: ConcurrentQueue.ConcurrentQueue([3]i32, 32, true),
    ChunkRenderListLock: std.Thread.RwLock,
    world: *World,
    ChunkRenderList: std.AutoArrayHashMap([3]i32, MeshBufferIDs),

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
        const mesh = Mesher.Mesh.MeshFromChunks(Pos, blocks, &neighbor_faces, 1, self.allocator);
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

    ///Adds a chunk to the render list, generates it or its neighbors if it dosent exist
    pub fn AddChunkToRenderTask(game: *Game, Pos: [3]i32, genStructures: bool, cullOutsideGenDistance: bool) void {
        if (cullOutsideGenDistance) {
            const playerPos = game.player.GetPos().?;
            const floatPlayerChunkPos = playerPos / @as(@Vector(3, f64), @splat(ChunkSize));
            const GenDistance = [3]u32{ game.GenerateDistance[0].load(.seq_cst), game.GenerateDistance[1].load(.seq_cst), game.GenerateDistance[2].load(.seq_cst) };
            const playerChunkPos = @as(@Vector(3, i32), @intFromFloat(@round(floatPlayerChunkPos)));
            if (game.running.load(.monotonic) and !outOfSquareRange(Pos - playerChunkPos, [3]i32{ @intCast(GenDistance[0] + 2), @intCast(GenDistance[1] + 2), @intCast(GenDistance[2] + 2) })) {
                game.chunkManager.AddChunkToRender(Pos, genStructures) catch |err| std.debug.panic("addchunktorenderError:{any}", .{err});
            } else {
                _ = game.chunkManager.LoadingChunks.remove(Pos);
            }
        } else game.chunkManager.AddChunkToRender(Pos, genStructures) catch |err| std.debug.panic("addchunktorenderError:{any}", .{err});
    }

    pub fn onEditFn(chunkPos: [3]i32, args: *anyopaque) void {
        const manager = @as(*ChunkManager, @ptrCast(@alignCast(args)));
        manager.AddChunkToRender(chunkPos, false) catch |err| std.log.err("err: {any}", .{err});
    }
};
