const std = @import("std");
const Mesh = @import("Mesher.zig");
const Chunk = @import("Chunk");
const World = @import("World").World;
const Mesher = @import("Mesher.zig");
const Block = @import("Block").Blocks;
const ChunkSize = 32;

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    pool: *std.Thread.Pool,
    world: *World,
    MeshesToLoad: std.ArrayList(Mesh),
    MeshesToLoadLock: std.Thread.Mutex,
    MeshDistance: [3]u32,

    ///Adds a chunk to the render list, generates it or its neighbors if it dosent exist
    pub fn AddChunkToRender(self: *@This(), Pos: [3]i32) !void {
        const chunk = try self.world.LoadChunk(Pos);
        chunk.addAndLockShared();
        defer chunk.releaseAndUnlockShared();

        const neighbor_faces = [6][ChunkSize][ChunkSize]Block{
            (try self.world.LoadChunk(Pos + [3]i32{ 1, 0, 0 })).extractFace(1),
            (try self.world.LoadChunk(Pos + [3]i32{ -1, 0, 0 })).extractFace(0),
            (try self.world.LoadChunk(Pos + [3]i32{ 0, 1, 0 })).extractFace(3),
            (try self.world.LoadChunk(Pos + [3]i32{ 0, -1, 0 })).extractFace(2),
            (try self.world.LoadChunk(Pos + [3]i32{ 0, 0, 1 })).extractFace(5),
            (try self.world.LoadChunk(Pos + [3]i32{ 0, 0, -1 })).extractFace(4),
        };
        const mesh = try Mesher.Mesh.MeshFromChunks(Pos, std.mem.bytesAsSlice([ChunkSize][ChunkSize][ChunkSize]Block, chunk.blocks), neighbor_faces, self.allocator);
        if(mesh)|m|{
            self.MeshesToLoad.append(m);
        }
    }
};
