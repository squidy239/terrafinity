const std = @import("std");
const ConcurrentQueue = @import("ConcurrentQueue");
const Renderer = @import("client/Renderer.zig");
const MeshBufferIDs = Renderer.MeshBufferIDs;
const Game = @import("Game.zig");
const ThreadPool = @import("ThreadPool");
const Loader = @import("Loader.zig");
const Block = @import("world/Block.zig").Block;
const Chunk = @import("world/Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const World = @import("world/World.zig");
const ztracy = @import("ztracy");

const Mesher = @import("Mesher.zig");
const outOfSquareRange = @import("libs/utils.zig").outOfSquareRange;

pub const ChunkManager = struct {
    allocator: std.mem.Allocator,
    pool: *ThreadPool,
    LoadingChunks: ConcurrentHashMap(World.ChunkPos, void, std.hash_map.AutoContext(World.ChunkPos), 80, 32),
    MeshesToLoad: ConcurrentQueue.ConcurrentQueue(Mesher.Mesh, 32, true),
    world: *World,
    ChunkRenderList: ConcurrentHashMap(World.ChunkPos, MeshBufferIDs, std.hash_map.AutoContext(World.ChunkPos), 80, 32),

    ///Adds a chunk to the render list replacing it if it already exists, generates it or its neighbors if it dosent exist
    threadlocal var blocks: *[ChunkSize][ChunkSize][ChunkSize]Block = undefined;
    threadlocal var Tempcube: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
    pub fn AddChunkToRender(self: *@This(), Pos: World.ChunkPos, genStructures: bool, playAnimation: bool) !void {
        const GenMeshAndAdd = ztracy.ZoneNC(@src(), "GenMeshAndAdd", 324342342);
        defer GenMeshAndAdd.End();
        const chunk = try self.world.loadChunk(Pos, genStructures);
        const neighbor_faces = [6][ChunkSize][ChunkSize]Block{
            (try self.world.loadChunk(Pos.add(.{ 1, 0, 0 }), false)).extractFace(.xMinus, true),
            (try self.world.loadChunk(Pos.add(.{ -1, 0, 0 }), false)).extractFace(.xPlus, true),
            (try self.world.loadChunk(Pos.add(.{ 0, 1, 0 }), false)).extractFace(.yMinus, true),
            (try self.world.loadChunk(Pos.add(.{ 0, -1, 0 }), false)).extractFace(.yPlus, true),
            (try self.world.loadChunk(Pos.add(.{ 0, 0, 1 }), false)).extractFace(.zMinus, true),
            (try self.world.loadChunk(Pos.add(.{ 0, 0, -1 }), false)).extractFace(.zPlus, true),
        };
        const exbl = ztracy.ZoneNC(@src(), "extractBlocks", 3222);
        const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
        chunk.lockShared();
        lock.End();
        switch (chunk.blocks) {
            .blocks => blocks = chunk.blocks.blocks,
            .oneBlock => {
                @memset(@as(*[ChunkSize * ChunkSize * ChunkSize]Block, @ptrCast(&Tempcube)), chunk.blocks.oneBlock);
                blocks = &Tempcube;
            },
        }
        exbl.End();
        const scale: f32 = @floatCast(World.ChunkPos.toScale(Pos.level));
        const mesh = Mesher.Mesh.meshFromChunks(Pos, blocks, &neighbor_faces, scale, playAnimation, self.allocator);
        chunk.releaseAndUnlockShared();
        if (try mesh) |m| {
            _ = try self.MeshesToLoad.append(m);
        } else {
            const removeChunk = self.ChunkRenderList.contains(Pos);
            if (removeChunk) {
                const emptyMesh: Mesher.Mesh = .{ .Pos = Pos, .TransperentFaces = null, .faces = null, .scale = scale, .animation = playAnimation };
                _ = try self.MeshesToLoad.append(emptyMesh);
            }
        }
    }

    ///Adds a chunk to the render list, generates it or its neighbors if it dosent exist
    pub fn AddChunkToRenderTask(game: *Game, Pos: World.ChunkPos, genStructures: bool) void {
        const inside_range = Loader.keepLoaded((game.player.physics.getPos()), Pos, game.getInnerGenRadius(Pos.level), game.getGenDistance());
        const running = game.running.load(.monotonic);
        if (!inside_range or !running) {
            _ = game.chunkManager.LoadingChunks.remove(Pos);
            return;
        }
        game.chunkManager.AddChunkToRender(Pos, genStructures, true) catch |err| std.debug.panic("addchunktorenderError:{any}", .{err});
    }

    pub fn onEditFn(chunkPos: World.ChunkPos, args: *anyopaque) !void {
        const manager = @as(*ChunkManager, @ptrCast(@alignCast(args)));
        manager.AddChunkToRender(chunkPos, false, false) catch return error.OnEditFailed;
    }
};
