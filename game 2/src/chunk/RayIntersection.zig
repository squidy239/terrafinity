const std = @import("std");
const World = @import("World.zig").World;
const Blocks = @import("Blocks.zig").Blocks;
const Chunk = @import("Chunk.zig").Chunk;
const ChunkState = @import("Chunk.zig").ChunkState;


inline fn IsTransparent(block: Blocks) bool {
    return switch (block) {
        Blocks.Air, Blocks.Water, Blocks.Leaves => true,
        else => false,
    };
}

inline fn sign(value: f64) f64 {
    if (value > 0.0) {return 1.0;}
    else if (value < 0.0) {return -1.0;}
    else{@branchHint(.unlikely);return 0.0;}
}

pub fn BreakFirstBlockOnRay(start: @Vector(3, f64), length: f64, direction: @Vector(3, f64),world:*World,allocator:std.mem.Allocator) !void {
    var CachedChunk:?*Chunk = null;
    const vector3_32 = comptime @as(@Vector(3,f64),@splat(32.0));

    var current_voxel = @floor(start+@Vector(3, f64){0.5,0.5,0.5});
    const step = @Vector(3,f64){sign(direction[0]),sign(direction[1]),sign(direction[2])};
    const delta_t = @as(@Vector(3, f64),@splat(1.0))/@abs(direction);
    var t_max = (current_voxel + step) / direction;
    
   
        
    
    while (@min(t_max[0],t_max[1],t_max[2]) < length) {
    
        const chunkpos = @as(@Vector(3, i32),@intFromFloat(@floor(current_voxel/vector3_32)));
        if(CachedChunk == null or @reduce(.And, CachedChunk.?.pos != chunkpos)){
            //std.debug.print("recaching\n", .{});
            CachedChunk = world.Chunks.get(chunkpos) orelse return;
        }//todo lock
        
        const PosInChunk = @as(@Vector(3, usize),@intFromFloat(@mod(current_voxel,vector3_32)));
        const state = CachedChunk.?.state.load(.seq_cst);
        if(state != ChunkState.InMemoryAndMesh and state != ChunkState.InMemoryNoMesh and state != ChunkState.InMemoryMeshLoading and state != ChunkState.InMemoryMeshGenerating and state != ChunkState.InMemoryMeshGenerating)
        {return;}
        if(!IsTransparent(CachedChunk.?.DecodeAndGetBlocks()[PosInChunk[0]][PosInChunk[1]][PosInChunk[2]])){
        std.debug.print("\nhit:{any}\n", .{CachedChunk.?.DecodeAndGetBlocks()[PosInChunk[0]][PosInChunk[1]][PosInChunk[2]]});
        const blocks = CachedChunk.?.DecodeAndGetBlocks();
        blocks[PosInChunk[0]][PosInChunk[1]][PosInChunk[2]] = Blocks.Air;
        _ = try World.RemeshChunk(world, CachedChunk.?.pos, allocator);
        _ = try World.RemeshChunk(world, CachedChunk.?.pos + @Vector(3,i32){1,0,0}, allocator);
        _ = try World.RemeshChunk(world, CachedChunk.?.pos + @Vector(3,i32){-1,0,0}, allocator);
        _ = try World.RemeshChunk(world, CachedChunk.?.pos + @Vector(3,i32){0,1,0}, allocator);
        _ = try World.RemeshChunk(world, CachedChunk.?.pos + @Vector(3,i32){0,-1,0}, allocator);
        _ = try World.RemeshChunk(world, CachedChunk.?.pos + @Vector(3,i32){0,0,1}, allocator);
        _ = try World.RemeshChunk(world, CachedChunk.?.pos + @Vector(3,i32){0,0,-1}, allocator);

        return;
        }
            
        
    if (t_max[0] < t_max[1] and t_max[0] < t_max[2]){
             t_max[0] += delta_t[0];
             current_voxel[0] += step[0];
    }
    else if (t_max[1] < t_max[2]){
             t_max[1] += delta_t[1];
             current_voxel[1] += step[1];
    }
    else{
             t_max[2] += delta_t[2];
             current_voxel[2] += step[2];
    }
    
}
}


fn TraverseRay(start: @Vector(3, f32), length: f32, direction: @Vector(3, f32)) void {
    var current_voxel = @floor(start);
    const step = direction / @abs(direction);
    const delta_t = @as(@Vector(3, f32),@splat(1.0))/@abs(direction);
    var t_max = (current_voxel + step) / direction;
    
    while (@min(t_max[0],t_max[1],t_max[2]) < length) {
    
        std.debug.print("\n{d}", .{current_voxel});
    
    if (t_max[0] < t_max[1] and t_max[0] < t_max[2]){
             t_max[0] += delta_t[0];
             current_voxel[0] += step[0];
    }
    else if (t_max[1] < t_max[2]){
             t_max[1] += delta_t[1];
             current_voxel[1] += step[1];
    }
    else{
             t_max[2] += delta_t[2];
             current_voxel[2] += step[2];
    }
    
}
}

test "ray" {
    TraverseRay(@Vector(3, f32){0.0,0.0,0.0}, 5.0, @Vector(3, f32){0.5,-1.0,0.6});
}

