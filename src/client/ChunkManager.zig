const std = @import("std");
const ConcurrentQueue = @import("root").ConcurrentQueue;
const root = @import("root");
const MeshBufferIDs = root.Renderer.MeshBufferIDs;
const Renderer = root.Renderer;
const Game = @import("Game.zig").Game;
const ThreadPool = @import("root").ThreadPool;
const Loader = @import("Loader.zig");
const Block = @import("Chunk").Block;
const Chunk = @import("Chunk").Chunk;
const ChunkSize = Chunk.ChunkSize;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const World = @import("World");
const ztracy = @import("ztracy");

const Mesher = @import("Mesher.zig");
const outOfSquareRange = @import("utils.zig").outOfSquareRange;

pub const ChunkManager = struct {
    allocator: std.mem.Allocator,
    pool: *ThreadPool,
    LoadingChunks: ConcurrentHashMap(World.ChunkPos, bool, std.hash_map.AutoContext(World.ChunkPos), 80, 32),
    MeshesToLoad: ConcurrentQueue.ConcurrentQueue(Mesher.Mesh, 32, true),
    world: *World,
    ChunkRenderList: ConcurrentHashMap(i32, *LevelRenderList, std.hash_map.AutoContext(i32), 80, 16),

    pub const LevelRenderList = ConcurrentHashMap(@Vector(3, i32), MeshBufferIDs, std.hash_map.AutoContext(@Vector(3, i32)), 80, 16);

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
        const mesh = Mesher.Mesh.MeshFromChunks(Pos, blocks, &neighbor_faces, scale, playAnimation, self.allocator);
        chunk.releaseAndUnlockShared();
        if (try mesh) |m| {
            _ = try self.MeshesToLoad.append(m);
        } else {
            const removeChunk = self.chunkInRenderList(Pos);
            if (removeChunk) {
                const emptyMesh: Mesher.Mesh = .{ .Pos = Pos, .TransperentFaces = null, .faces = null, .scale = scale, .animation = playAnimation };
                _ = try self.MeshesToLoad.append(emptyMesh);
            }
        }
    }

    pub fn chunkInRenderList(self: *@This(), Pos: World.ChunkPos) bool {
        const level_list = self.ChunkRenderList.get(Pos.level) orelse return false;
        return level_list.contains(Pos.position);
    }

    pub fn fetchremoveFromList(self: *@This(), Pos: World.ChunkPos) ?MeshBufferIDs {
        const level_list = self.ChunkRenderList.get(Pos.level) orelse return null;
        return level_list.fetchremove(Pos.position);
    }

    pub fn removeFromList(self: *@This(), Pos: World.ChunkPos) bool {
        const level_list = self.ChunkRenderList.get(Pos.level) orelse return false;
        return level_list.remove(Pos.position);
    }

    pub fn getFromList(self: *@This(), Pos: World.ChunkPos) ?MeshBufferIDs {
        const level_list = self.ChunkRenderList.get(Pos.level) orelse return null;
        return level_list.get(Pos.position);
    }

    pub fn fetchputToList(self: *@This(), Pos: World.ChunkPos, mesh: MeshBufferIDs) !?MeshBufferIDs {
        var level_list = self.ChunkRenderList.get(Pos.level);

        if (level_list == null) {
            const new_list = try self.allocator.create(LevelRenderList);
            new_list.* = LevelRenderList.init(self.allocator);
            if (try self.ChunkRenderList.fetchPut(Pos.level, new_list)) |old_list| {
                new_list.deinit();
                self.allocator.destroy(new_list);
                level_list = old_list;
            } else {
                level_list = new_list;
            }
        }

        return try level_list.?.fetchPut(Pos.position, mesh);
    }

    ///Adds a chunk to the render list, generates it or its neighbors if it dosent exist
    pub fn AddChunkToRenderTask(game: *Game, Pos: World.ChunkPos, genStructures: bool) void {
        const inside_range = Loader.keepLoaded(@intFromFloat(game.player.getPos().?), Pos, game.getInnerGenRadius(Pos.level), game.getGenDistance());
        const running = game.running.load(.monotonic);
        if (!inside_range or !running) return;
        game.chunkManager.AddChunkToRender(Pos, genStructures, true) catch |err| std.debug.panic("addchunktorenderError:{any}", .{err});
    }

    pub fn onEditFn(chunkPos: World.ChunkPos, args: *anyopaque) !void {
        const manager = @as(*ChunkManager, @ptrCast(@alignCast(args)));
        manager.AddChunkToRender(chunkPos, false, false) catch return error.OnEditFailed;
    }
};
