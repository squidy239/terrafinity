const std = @import("std");
const Entitys = @import("Entitys.zig");
const World = @import("../chunk/World.zig").World;
const ChunkStates = @import("../chunk/Chunk.zig").ChunkState;
const Blocks = @import("../chunk/Blocks.zig").Blocks;

pub fn PlayerPhysics(playerr: *Entitys.Player, timeElapsed: u64, world: *World) void {
    playerr.lock.lock();
    defer playerr.lock.unlock();

    const dt = @as(f64, @floatFromInt(timeElapsed)) / std.time.ns_per_s;

    // Air resistance calculation
    playerr.Movement += AirResistance(playerr.Movement, dt);
    // Apply gravity
    playerr.Movement[1] -= 9.81 * dt;

    // Calculate next position
    const next_pos = playerr.pos + playerr.Movement * @as(@Vector(3, f64), @splat(dt));

    // Collision detection
    var final_pos = playerr.pos;

    // Check collisions for each axis separately
    inline for (0..3) |axis| {
        var test_pos = final_pos;
        test_pos[axis] = next_pos[axis];

        const chunk_pos = @as(@Vector(3, i32), @intFromFloat(test_pos / @as(@Vector(3, f64), @splat(32.0))));
        const block_pos = @as(@Vector(3, i32), @intFromFloat(test_pos));
        
        // Check surrounding chunks for collisions
        var collided = false;
        for ([_]i32{-1, 0, 1}) |dx| {
            for ([_]i32{-1, 0, 1}) |dy| {
                for ([_]i32{-1, 0, 1}) |dz| {
                    const check_chunk_pos = chunk_pos + @Vector(3, i32){ dx, dy, dz };
                    if (world.Chunks.get(check_chunk_pos)) |chunk| {
                        chunk.lock.lockShared();
                        defer chunk.lock.unlockShared();
                        const cs = chunk.state.load(.seq_cst);
                        if (cs == ChunkStates.InMemoryAndMesh or cs == ChunkStates.InMemoryNoMesh  or cs == ChunkStates.InMemoryMeshGenerating or cs == ChunkStates.InMemoryMeshUnloaded) {
                            // Check if there's a block at the player's position
                            const rel_pos = block_pos - (check_chunk_pos * @Vector(3, i32){32, 32, 32});
                            if (rel_pos[0] >= 0 and rel_pos[0] < 32 and
                                rel_pos[1] >= 0 and rel_pos[1] < 32 and
                                rel_pos[2] >= 0 and rel_pos[2] < 32)
                            {
                                if (chunk.ChunkData != null) {
                                    const data = chunk.DecodeAndGetBlocks();
                                    if (data[@intCast(rel_pos[0])][@intCast(rel_pos[1])][@intCast(rel_pos[2])] != Blocks.Air) {
                                        collided = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if (collided) {
            playerr.Movement[axis] = 0;
        } else {
            final_pos[axis] = next_pos[axis];
        }
    }

    playerr.pos = final_pos;
}


fn AirResistance(Movement:@Vector(3, f64),DeltaTime:f64)[3]f64{
    const air_density: @Vector(3, f64) = comptime @splat(0.1);
    //player, will add paramiters for other entitys
    const drag_co: @Vector(3, f64) = comptime @splat(0.1);
    const surface_area: @Vector(3, f64) = comptime @Vector(3, f64){ 1.0, 0.5, 1.0 };

    const velocity_squared = Movement * Movement;
    const speed = @sqrt(@reduce(.Add, velocity_squared));

    if (speed > 0.0) {
        @branchHint(.likely);
        // Apply drag force
        const drag_magnitude = @as(@Vector(3, f64), @splat(0.5)) * air_density * @abs(velocity_squared) * drag_co * surface_area;
        const drag_direction = Movement / @as(@Vector(3, f64), @splat(speed));
        const drag = drag_direction * @as(@Vector(3, f64), -drag_magnitude);
        return  drag * @as(@Vector(3, f64), @splat(DeltaTime));
    }
    else return comptime @Vector(3, f64){0.0,0.0,0.0};
}