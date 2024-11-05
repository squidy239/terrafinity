const std = @import("std");
const RenderIDs = @import("./Chunk.zig").MeshBufferIDs;
const Chunk = @import("./Chunk.zig").Chunk;

fn DistanceOrder(context:)
pub const World = struct {
    ChunkMeshes:std.ArrayList(RenderIDs),
    Chunks:std.ArrayList(Chunk),
    Entitys:std.DoublyLinkedList(type),
    GenDistance:[3]i32,
    LoadDistance:[3]i32,
    MeshDistance:[3]i32,
    ToGen:std.PriorityQueue([3]i32, void,),

};