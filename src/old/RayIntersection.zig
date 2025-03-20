const std = @import("std");

const Entitys = @import("../entities/Entitys.zig");
const Blocks = @import("Blocks.zig").Blocks;
const Chunk = @import("Chunk.zig").Chunk;
const ChunkState = @import("Chunk.zig").ChunkState;
const World = @import("World.zig").World;

inline fn IsTransparent(block: Blocks) bool {
    return switch (block) {
        Blocks.Air, Blocks.Water, Blocks.Leaves => true,
        else => false,
    };
}

inline fn sign(value: f64) f64 {
    if (value > 0.0) {
        return 1.0;
    } else if (value < 0.0) {
        return -1.0;
    } else {
        @branchHint(.unlikely);
        return 0.0;
    }
}

const BlockHit = struct {
    chunk: [3]i32,
    posinchunk: [3]u5,
    material: Blocks,
    side: u3,
    time: i64,
};

pub fn GetFirstBlockOnRay(start: @Vector(3, f64), length: f64, direction: @Vector(3, f64), world: *World) !?BlockHit {
    var CachedChunk: ?*Chunk = null;
    var current_voxel = @round(start);
    const step = direction / @abs(direction);
    const delta_t = @abs(@as(@Vector(3, f64), @splat(1.0)) / direction);

    var t_max = @Vector(3, f64){
        if (direction[0] > 0) ((current_voxel[0] + 0.5) - start[0]) / direction[0] else ((current_voxel[0] - 0.5) - start[0]) / direction[0],
        if (direction[1] > 0) ((current_voxel[1] + 0.5) - start[1]) / direction[1] else ((current_voxel[1] - 0.5) - start[1]) / direction[1],
        if (direction[2] > 0) ((current_voxel[2] + 0.5) - start[2]) / direction[2] else ((current_voxel[2] - 0.5) - start[2]) / direction[2],
    };

    while (@min(t_max[0], t_max[1], t_max[2]) < length) {
        {
            const chunkpos = @as(@Vector(3, i32), @intFromFloat(@floor(current_voxel / @as(@Vector(3, f64), @splat(32.0)))));
            if (CachedChunk == null or @reduce(.Or, CachedChunk.?.pos != chunkpos)) {
                //std.debug.print("recaching\n", .{});
                CachedChunk = world.Chunks.get(chunkpos) orelse return null;
            } //todo lock

            const PosInChunk = @as(@Vector(3, usize), @intFromFloat(@mod(current_voxel, @as(@Vector(3, f64), @splat(32.0)))));
            const state = CachedChunk.?.state.load(.seq_cst);
            if (state != ChunkState.InMemoryAndMesh and state != ChunkState.InMemoryNoMesh and state != ChunkState.InMemoryMeshLoading and state != ChunkState.InMemoryMeshGenerating and state != ChunkState.InMemoryMeshGenerating) {
                return null;
            }
            const blocks = CachedChunk.?.DecodeAndGetBlocks() orelse return null;
            if (blocks[PosInChunk[0]][PosInChunk[1]][PosInChunk[2]] != Blocks.Air and blocks[PosInChunk[0]][PosInChunk[1]][PosInChunk[2]] != Blocks.Water) {
                var side: u3 = undefined;

                if (t_max[0] < t_max[1] and t_max[0] < t_max[2]) {
                    // X-axis intersection
                    side = if (step[0] > 0) 1 else 0;
                } else if (t_max[1] < t_max[2]) {
                    // Y-axis intersection
                    side = if (step[1] > 0) 3 else 2;
                } else {
                    // Z-axis intersection
                    side = if (step[2] > 0) 5 else 4;
                }
                return BlockHit{
                    .chunk = CachedChunk.?.pos,
                    .material = blocks[PosInChunk[0]][PosInChunk[1]][PosInChunk[2]],
                    .posinchunk = @as(@Vector(3, u5), @intCast(PosInChunk)),
                    .side = side,
                    .time = std.time.timestamp(),
                };
            }
        }

        if (t_max[0] < t_max[1] and t_max[0] < t_max[2]) {
            t_max[0] += delta_t[0];
            current_voxel[0] += step[0];
        } else if (t_max[1] < t_max[2]) {
            t_max[1] += delta_t[1];
            current_voxel[1] += step[1];
        } else {
            t_max[2] += delta_t[2];
            current_voxel[2] += step[2];
        }
    }
    return null;
}

fn TraverseRay(start: @Vector(3, f32), length: f32, direction: @Vector(3, f32)) void {
    var current_voxel = @floor(start);
    const step = direction / @abs(direction);
    const delta_t = @as(@Vector(3, f32), @splat(1.0)) / @abs(direction);
    var t_max = (current_voxel + step) / direction;

    while (@min(t_max[0], t_max[1], t_max[2]) < length) {
        std.debug.print("\n{d}", .{current_voxel});

        if (t_max[0] < t_max[1] and t_max[0] < t_max[2]) {
            t_max[0] += delta_t[0];
            current_voxel[0] += step[0];
        } else if (t_max[1] < t_max[2]) {
            t_max[1] += delta_t[1];
            current_voxel[1] += step[1];
        } else {
            t_max[2] += delta_t[2];
            current_voxel[2] += step[2];
        }
    }
}

test "ray" {
    TraverseRay(@Vector(3, f32){ 0.0, 0.0, 0.0 }, 5.0, @Vector(3, f32){ 0.5, -1.0, 0.6 });
}
