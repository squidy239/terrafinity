const std = @import("std");

const ztracy = @import("ztracy");

const Blocks = @import("../chunk/Blocks.zig").Blocks;
const ChunkStates = @import("../chunk/Chunk.zig").ChunkState;
const World = @import("../chunk/World.zig").World;
const Entitys = @import("Entitys.zig");

pub fn PlayerPhysicsLoop(playerr: *Entitys.Player, timer: *std.time.Timer, world: *World) void {
    while (world.running.load(.seq_cst)) : (std.Thread.sleep(2 * std.time.ns_per_ms)) {
        PlayerPhysics(playerr, timer, world);
    }
}
pub fn PlayerPhysics(playerr: *Entitys.Player, timer: *std.time.Timer, world: *World) void {
    const tracy_zone = ztracy.ZoneNC(@src(), "PlayerPhysics", 34234);
    defer tracy_zone.End();
    playerr.lock.lock();
    defer playerr.lock.unlock();
    const dt = @as(f64, @floatCast(@as(f128, @floatFromInt(timer.lap())) / std.time.ns_per_s));
    if (playerr.gameMode != Entitys.GameMode.Spectator) {
        playerr.Movement[1] -= 9.81 * dt;
        // Air resistance calculation
        playerr.Movement += AirResistance(playerr.Movement, dt, @splat(0.1));
        var p = playerr.pos;
        p += (playerr.Movement * @as(@Vector(3, f64), @splat(dt)));
        const c = BlockPlayerCollision(playerr, p, world, @Vector(3, f64){ 10.0, 10.0, 10.0 }, dt);
        p += c;
        //std.debug.print("\ndt:{d}\n", .{dt});
        playerr.pos = p;
        //std.debug.print("\nc:{d}, m:{d}\n", .{c,(playerr.Movement * @as(@Vector(3, f64), @splat(dt)))});
    } else {
        //same drag as ground for spectator mode
        playerr.Movement[0] /= 1.0 + (4.0 * dt);
        playerr.Movement[1] /= 1.0 + (4.0 * dt);
        playerr.Movement[2] /= 1.0 + (4.0 * dt);
        playerr.Movement[0] -= if (playerr.Movement[0] > 0) @min(0.2 * dt, playerr.Movement[0]) else if (playerr.Movement[0] < 0) @max(-0.2 * dt, playerr.Movement[0]) else 0;
        playerr.Movement[1] -= if (playerr.Movement[1] > 0) @min(0.2 * dt, playerr.Movement[1]) else if (playerr.Movement[1] < 0) @max(-0.2 * dt, playerr.Movement[1]) else 0;
        playerr.Movement[2] -= if (playerr.Movement[2] > 0) @min(0.2 * dt, playerr.Movement[2]) else if (playerr.Movement[2] < 0) @max(-0.2 * dt, playerr.Movement[2]) else 0;
        playerr.pos += playerr.Movement * @as(@Vector(3, f64), @splat(dt));
    }
}

fn AirResistance(Movement: @Vector(3, f64), DeltaTime: f64, drag_co: @Vector(3, f64)) [3]f64 {
    const air_density: @Vector(3, f64) = comptime @splat(0.1);
    //player, will add paramiters for other entitys
    const surface_area: @Vector(3, f64) = comptime @Vector(3, f64){ 1.0, 0.5, 1.0 };

    const velocity_squared = Movement * Movement;
    const speed = @sqrt(@reduce(.Add, velocity_squared));

    if (speed > 0.0) {
        @branchHint(.likely);
        const drag_magnitude = @as(@Vector(3, f64), @splat(0.5)) * air_density * @abs(velocity_squared) * drag_co * surface_area;
        const drag_direction = Movement / @as(@Vector(3, f64), @splat(speed));
        const drag = drag_direction * @as(@Vector(3, f64), -drag_magnitude);
        return drag * @as(@Vector(3, f64), @splat(DeltaTime));
    } else return comptime @Vector(3, f64){ 0.0, 0.0, 0.0 };
}

fn BlockPlayerCollision(playerr: *Entitys.Player, playerpos: @Vector(3, f64), world: *World, check_radius: @Vector(3, f64), dt: f64) [3]f64 {
    const tracy_zone = ztracy.ZoneNC(@src(), "BlockCollision", 47539753);
    defer tracy_zone.End();
    //std.debug.print("\nrad: {d}\n", .{check_radius});
    var buffer: [100000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();
    const player_min = playerpos - playerr.hitboxmin;
    const player_max = playerpos + playerr.hitboxmax;
    var playerposcorrection = @Vector(3, f64){ 0.0, 0.0, 0.0 };
    const min_check = @floor(player_min - check_radius);
    const max_check = @ceil(player_max + check_radius);
    var list = std.PriorityQueue(@Vector(3, f64), @Vector(3, f64), DistanceOrder).init(allocator, playerpos);
    defer list.deinit();

    var x = min_check[0];
    while (x < max_check[0]) : (x += 1.0) {
        var y = min_check[1];
        while (y < max_check[1]) : (y += 1.0) {
            var z = min_check[2];
            while (z < max_check[2]) : (z += 1.0) {
                const block_pos = @Vector(3, f64){ x, y, z };

                // Check if the player's bounding box overlaps with this block
                const a = @Vector(6, f64){ player_min[0], player_min[1], player_min[2], player_max[0], player_max[1], player_max[2] };
                const b = @Vector(6, f64){ block_pos[0] - 0.5, block_pos[1] - 0.5, block_pos[2] - 0.5, block_pos[0] + 0.5, block_pos[1] + 0.5, block_pos[2] + 0.5 };
                if (@reduce(.And, GetOverlap(a, b) > @Vector(3, f64){ 0.0, 0.0, 0.0 })) {
                    list.add(block_pos) catch |err| {
                        std.debug.panic("\n\n{any}\n", .{err});
                    };
                }
            }
        }
    }

    var xb = false;
    var yb = false;
    var zb = false;
    var og = false;
    var iw = false;
    for (list.items) |pos| {
        if (xb and yb and zb) break;
        const c = ztracy.ZoneNC(@src(), "Calculate", 3423450984);
        defer c.End();
        const chunk_pos = @as(@Vector(3, i32), @intFromFloat(@floor(pos / @as(@Vector(3, f64), @splat(32.0)))));
        const block_in_chunk = @as(@Vector(3, usize), @intFromFloat(@mod(pos, @as(@Vector(3, f64), @splat(32.0)))));
        if (world.Chunks.get(chunk_pos)) |chunk| {
            if (chunk.ChunkData != null) {
                chunk.lock.lockShared();
                defer chunk.lock.unlockShared();

                const blocks = chunk.DecodeAndGetBlocks() orelse {std.debug.panic("\n\nerror:physics:no blocks in chunk\n\n", .{});};
                if (blocks[block_in_chunk[0]][block_in_chunk[1]][block_in_chunk[2]] != Blocks.Air and blocks[block_in_chunk[0]][block_in_chunk[1]][block_in_chunk[2]] != Blocks.Water) {
                    const a = @Vector(6, f64){ player_min[0], player_min[1], player_min[2], player_max[0], player_max[1], player_max[2] };
                    const b = @Vector(6, f64){ pos[0] - 0.5, pos[1] - 0.5, pos[2] - 0.5, pos[0] + 0.5, pos[1] + 0.5, pos[2] + 0.5 };
                    // Collision detected, stop movement
                    const overlap = GetOverlap(a, b);

                    // Find the smallest overlap
                    var min_overlap = overlap[0];
                    var direction: u8 = 0; // 0 = x, 1 = y, 2 = z
                    if ((overlap[1]) < (min_overlap)) {
                        min_overlap = overlap[1];
                        direction = 1;
                    }
                    if ((overlap[2]) < (min_overlap)) {
                        min_overlap = overlap[2];
                        direction = 2;
                    }
                    // Adjust position to resolve collision
                    switch (direction) {
                        0 => {
                            if (!xb) {
                                xb = true;
                                if (playerr.Movement[0] > 0) {
                                    playerposcorrection[0] -= overlap[0];
                                } else {
                                    playerposcorrection[0] += overlap[0];
                                }
                                playerr.Movement[0] = 0;
                            }
                        },
                        1 => {
                            if (!yb) {
                                yb = true;
                                if (playerr.Movement[1] > 0) {
                                    playerposcorrection[1] -= overlap[1];
                                } else {
                                    playerposcorrection[1] += overlap[1];

                                    //friction when on block
                                    //std.debug.print("\ndt:{d}", .{dt});
                                    playerr.Movement[0] /= 1.0 + (4.0 * dt);
                                    playerr.Movement[2] /= 1.0 + (4.0 * dt);

                                    playerr.Movement[0] -= if (playerr.Movement[0] > 0) @min(0.2 * dt, playerr.Movement[0]) else if (playerr.Movement[0] < 0) @max(-0.2 * dt, playerr.Movement[0]) else 0;
                                    playerr.Movement[2] -= if (playerr.Movement[2] > 0) @min(0.2 * dt, playerr.Movement[2]) else if (playerr.Movement[2] < 0) @max(-0.2 * dt, playerr.Movement[2]) else 0;
                                    og = true;
                                }
                                playerr.Movement[1] = 0;
                            }
                        },
                        2 => {
                            if (!zb) {
                                zb = true;
                                if (playerr.Movement[2] > 0) {
                                    playerposcorrection[2] -= overlap[2];
                                } else {
                                    playerposcorrection[2] += overlap[2];
                                }
                                playerr.Movement[2] =  0;
                            }
                        },
                        else => unreachable,
                    }
                } else if (blocks[block_in_chunk[0]][block_in_chunk[1]][block_in_chunk[2]] == Blocks.Water) {
                    const a = @Vector(6, f64){ player_min[0], player_min[1], player_min[2], player_max[0], player_max[1], player_max[2] };
                    const b = @Vector(6, f64){ pos[0] - 0.5, pos[1] - 0.5, pos[2] - 0.5, pos[0] + 0.5, pos[1] + 0.5, pos[2] + 0.5 };
                    // water
                    const overlap: f64 = @reduce(.Mul, GetOverlap(a, b));
                    iw = true;
                    playerr.Movement[1] += 13.0 * dt * overlap; //boyency
                    playerr.Movement += LiquidResistance(playerr.Movement, dt, @splat(0.1), @splat(10.0)) * @as(@Vector(3, f64), @splat(overlap));
                }
            }
        }
    }
    playerr.OnGround = og;
    playerr.inWater = iw;
    return playerposcorrection;
}

fn LiquidResistance(Movement: @Vector(3, f64), DeltaTime: f64, drag_co: @Vector(3, f64), viscosity: @Vector(3, f64)) [3]f64 {
    //player, will add paramiters for other entitys
    const surface_area: @Vector(3, f64) = comptime @Vector(3, f64){ 1.0, 0.5, 1.0 };

    const velocity_squared = Movement * Movement;
    const speed = @sqrt(@reduce(.Add, velocity_squared));

    if (speed > 0.0) {
        @branchHint(.likely);
        const drag_magnitude = @as(@Vector(3, f64), @splat(0.5)) * viscosity * @abs(velocity_squared) * drag_co * surface_area;
        const drag_direction = Movement / @as(@Vector(3, f64), @splat(speed));
        const drag = drag_direction * @as(@Vector(3, f64), -drag_magnitude);
        return drag * @as(@Vector(3, f64), @splat(DeltaTime));
    } else return comptime @Vector(3, f64){ 0.0, 0.0, 0.0 };
}

pub fn DistanceOrder(playerpos: @Vector(3, f64), a: @Vector(3, f64), b: @Vector(3, f64)) std.math.Order {
    // Convert coordinates to float32 and scale them
    const d1 = Distance(playerpos, a);
    const d2 = Distance(playerpos, b);

    if (d1 < d2) {
        return std.math.Order.gt;
    } else if (d1 > d2) {
        return std.math.Order.lt;
    } else {
        @branchHint(.unlikely);
        return std.math.Order.eq;
    }
}

inline fn Distance(c1: [3]f64, c2: [3]f64) f64 {
    const dx: f64 = (c2[0] - c1[0]);
    const dy: f64 = (c2[1] - c1[1]);
    const dz: f64 = (c2[2] - c1[2]);
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

fn CheckOverlap(a: @Vector(6, f64), b: @Vector(6, f64)) bool {
    const cx = a[3] > b[0] and b[3] > a[0];
    const cy = a[4] > b[1] and b[4] > a[1];
    const cz = a[5] > b[2] and b[5] > a[2];
    return cx and cy and cz;
}

pub fn GetOverlap(a: @Vector(6, f64), b: @Vector(6, f64)) @Vector(3, f64) {
    return @Vector(3, f64){ (@min(a[3], b[3]) - @max(a[0], b[0])), (@min(a[4], b[4]) - @max(a[1], b[1])), (@min(a[5], b[5]) - @max(a[2], b[2])) };
}
