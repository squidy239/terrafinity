const std = @import("std");
const ConcurrentQueue = @import("ConcurrentQueue");

const root = @import("main.zig");
const UBO = root.Renderer.UBO;
const ThreadPool = @import("ThreadPool");

const Chunk = @import("Chunk");
const ChunkSize = Chunk.ChunkSize;
const Entity = @import("Entity").Entity;
const World = @import("world/World.zig");
const ztracy = @import("ztracy");

const Game = @import("Game.zig");

pub fn keepLoaded(lowest_level: ?i32, highest_level: ?i32, playerPos: @Vector(3, f64), Pos: World.ChunkPos, innerChunkRange: ?@Vector(2, u32), outerChunkRange: ?@Vector(2, u32)) bool {
    if (lowest_level) |l| {
        if (Pos.level < l) return false;
    }
    if (highest_level) |h| {
        if (Pos.level > h) return false;
    }

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
pub fn ChunkLoaderThread(game: *Game, intervel_ns: u64) void {
    while (game.running.load(.monotonic)) {
        const playerPos = game.player.physics.getPos();
        const addChunkstoLoad = ztracy.ZoneNC(@src(), "addChunksToLoad", 223);
        const st = std.time.nanoTimestamp();
        defer std.Thread.sleep(intervel_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
        const genDistance = game.getGenDistance();
        const levels = game.getLevels();
        var level = levels[0];
        var amount_loaded: u64 = 0;
        while (level < levels[1]) : (level += 1) {
            amount_loaded += loadChunksSpiral(game, (playerPos), genDistance, game.getInnerGenRadius(genDistance, level), level) catch unreachable;
        }
        std.debug.print("loaded {d} chunks, count: {d}\n", .{ amount_loaded, game.loaded_or_meshed.count() });
        addChunkstoLoad.End();
    }
}

///loads chunks from top to bottom and in a spiral on a y level
fn loadChunksSpiral(game: *Game, playerPos: @Vector(3, f64), dist: @Vector(2, u32), innerdistance: @Vector(2, u32), level: i32) !u64 {
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
                const Pos: World.ChunkPos = .{ .position = [3]i32{ xz[0] + playerChunkPos.position[0], y + playerChunkPos.position[1], xz[1] + playerChunkPos.position[2] }, .level = level };

                const in_range = keepLoaded(null, null, playerPos, Pos, innerdistance, distance);
                if (!in_range)
                    continue;

                const loaded = game.loaded_or_meshed.contains(Pos);

                if (!loaded) {
                    amount_loaded += 1;
                    try game.addChunkToRenderAsync(Pos, true);
                }
            }
        }
    }
    return amount_loaded;
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
