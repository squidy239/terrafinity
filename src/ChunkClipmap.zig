//! Per-level toroidal windows of chunk streaming state centered on the player.
//! Each level is a dense grid indexed by `@mod(position, dims)`, so a window that
//! moves by one chunk hands over one slab of slots and nothing else moves.
//! A single owner (the chunk streamer) reads and writes it, so cells are plain values.
const std = @import("std");

const World = @import("world/World.zig");

const ChunkClipmap = @This();

comptime {
    // `State.covered_children` holds one bit per child.
    std.debug.assert(World.scale_factor == 2);
}

pub const Position = @Vector(3, i32);

/// Level `lowest_level + i` lives in `levels[i]`.
lowest_level: i32,
/// Half-size of every window per axis; a window spans `2 * half_extent + 1` chunks.
half_extent: @Vector(3, u32),
levels: []Level,

pub const Level = struct {
    center: Position,
    cells: []State,
};

pub const State = packed struct(u16) {
    /// One bit per child (`childBit`), set while that child is active or fully covered.
    covered_children: u8 = 0,
    /// The renderer holds this chunk's mesh, or the chunk has no faces.
    active: bool = false,
    /// The chunk is in the streamer's lingering list.
    lingering: bool = false,
    /// An edit meshed this chunk while it was not active, so the renderer may hold a mesh the flags above do not account for.
    edited: bool = false,
    _padding: u5 = 0,

    pub fn allCoveredChildren(state: State) bool {
        return state.covered_children == std.math.maxInt(u8);
    }

    pub fn isCovering(state: State) bool {
        return state.active or state.allCoveredChildren();
    }
};

/// Positions within `outer` of `center` on every axis, minus those strictly within `hole` on every axis.
pub const Region = struct {
    center: Position,
    outer: @Vector(3, u32),
    hole: @Vector(3, u32) = @splat(0),

    pub fn contains(region: Region, position: Position) bool {
        const offset = @as(@Vector(3, i64), @intCast(position)) - @as(@Vector(3, i64), @intCast(region.center));
        const distance = @abs(offset);
        if (@reduce(.Or, distance > @as(@Vector(3, u64), @intCast(region.outer)))) return false;
        return !@reduce(.And, distance < @as(@Vector(3, u64), @intCast(region.hole)));
    }

    /// Calls `visit(context, position)` once for each position in `a` that is not in `b`.
    /// Work is one interval subtraction per row of `a`, plus one call per visited position.
    pub fn forEachDifference(a: Region, b: ?Region, context: anytype, visit: anytype) !void {
        const center: @Vector(3, i64) = @intCast(a.center);
        const outer: @Vector(3, i64) = @intCast(a.outer);
        const low = center - outer;
        const high = center + outer;
        var x = low[0];
        while (x <= high[0]) : (x += 1) {
            var y = low[1];
            while (y <= high[1]) : (y += 1) {
                const remove = if (b) |region| region.rowSpans(x, y) else no_spans;
                for (a.rowSpans(x, y)) |keep| {
                    var cursor = keep[0];
                    for (remove) |cut| {
                        if (cut[1] < cursor) continue;
                        if (cut[0] > keep[1]) break;
                        try visitSpan(x, y, cursor, @min(keep[1], cut[0] - 1), context, visit);
                        cursor = @max(cursor, cut[1] + 1);
                    }
                    try visitSpan(x, y, cursor, keep[1], context, visit);
                }
            }
        }
    }

    /// Lies past every cursor, so the subtraction in `forEachDifference` skips it.
    const empty_span: [2]i64 = .{ std.math.maxInt(i64), std.math.minInt(i64) };
    const no_spans: [2][2]i64 = .{ empty_span, empty_span };

    fn span(low: i64, high: i64) [2]i64 {
        return if (low > high) empty_span else .{ low, high };
    }

    /// Inclusive, sorted, disjoint z intervals of the row at (`x`, `y`); unused ones are empty.
    fn rowSpans(region: Region, x: i64, y: i64) [2][2]i64 {
        const center: @Vector(3, i64) = @intCast(region.center);
        const dx = @abs(x - center[0]);
        const dy = @abs(y - center[1]);
        if (dx > region.outer[0] or dy > region.outer[1]) return no_spans;
        const low = center[2] - region.outer[2];
        const high = center[2] + region.outer[2];
        if (dx < region.hole[0] and dy < region.hole[1] and region.hole[2] > 0) {
            return .{ span(low, @min(high, center[2] - region.hole[2])), span(@max(low, center[2] + region.hole[2]), high) };
        }
        return .{ .{ low, high }, empty_span };
    }

    fn visitSpan(x: i64, y: i64, low: i64, high: i64, context: anytype, visit: anytype) !void {
        var z = low;
        while (z <= high) : (z += 1) try visit(context, Position{ @intCast(x), @intCast(y), @intCast(z) });
    }
};

/// Allocates empty windows for `lowest_level..highest_level`, centered on `player_block`.
pub fn init(gpa: std.mem.Allocator, lowest_level: i32, highest_level: i32, half_extent: @Vector(3, u32), player_block: World.BlockPos) !ChunkClipmap {
    std.debug.assert(lowest_level <= highest_level);
    const levels = try gpa.alloc(Level, @intCast(highest_level - lowest_level + 1));
    var initialized: usize = 0;
    errdefer {
        for (levels[0..initialized]) |level| gpa.free(level.cells);
        gpa.free(levels);
    }
    const cell_count = @reduce(.Mul, @as(@Vector(3, usize), @intCast(dimsFor(half_extent))));
    for (levels, 0..) |*level, index| {
        const level_index = lowest_level + @as(i32, @intCast(index));
        level.* = .{ .center = centerFor(player_block, level_index), .cells = try gpa.alloc(State, cell_count) };
        @memset(level.cells, .{});
        initialized += 1;
    }
    return .{ .lowest_level = lowest_level, .half_extent = half_extent, .levels = levels };
}

pub fn deinit(clipmap: *ChunkClipmap, gpa: std.mem.Allocator) void {
    for (clipmap.levels) |level| gpa.free(level.cells);
    gpa.free(clipmap.levels);
    clipmap.* = undefined;
}

/// The window center for `level`: the chunk holding `player_block`.
pub fn centerFor(player_block: World.BlockPos, level: i32) Position {
    return World.ChunkPos.fromGlobalBlockPos(player_block, level).position;
}

pub fn highestLevel(clipmap: ChunkClipmap) i32 {
    return clipmap.lowest_level + @as(i32, @intCast(clipmap.levels.len)) - 1;
}

/// The level index of `clipmap.levels[index]`.
pub fn levelIndex(clipmap: ChunkClipmap, index: usize) i32 {
    return clipmap.lowest_level + @as(i32, @intCast(index));
}

pub fn levelAt(clipmap: ChunkClipmap, level_index: i32) ?*Level {
    if (level_index < clipmap.lowest_level or level_index > clipmap.highestLevel()) return null;
    return &clipmap.levels[@intCast(level_index - clipmap.lowest_level)];
}

pub fn window(clipmap: ChunkClipmap, center: Position) Region {
    return .{ .center = center, .outer = clipmap.half_extent };
}

/// The state of `pos`, or null when `pos` is outside every window.
pub fn get(clipmap: ChunkClipmap, pos: World.ChunkPos) ?*State {
    const lvl = clipmap.levelAt(pos.level) orelse return null;
    if (!clipmap.window(lvl.center).contains(pos.position)) return null;
    return &lvl.cells[clipmap.slotIndex(pos.position)];
}

/// The window position that owns `slot` in a window centered on `center`.
pub fn positionAt(clipmap: ChunkClipmap, center: Position, slot: usize) Position {
    const dims = dimsFor(clipmap.half_extent);
    const wrapped: Position = .{
        @intCast(slot % @as(usize, @intCast(dims[0]))),
        @intCast(slot / @as(usize, @intCast(dims[0])) % @as(usize, @intCast(dims[1]))),
        @intCast(slot / @as(usize, @intCast(dims[0] * dims[1]))),
    };
    const origin = center - @as(Position, @intCast(clipmap.half_extent));
    return origin + @mod(wrapped - origin, dims);
}

/// Bit for `pos` in its parent's `covered_children`.
pub fn childBit(pos: World.ChunkPos) u8 {
    const in_parent: @Vector(3, u8) = @intCast(pos.posInParent());
    return @as(u8, 1) << @intCast(in_parent[0] + 2 * in_parent[1] + 4 * in_parent[2]);
}

fn slotIndex(clipmap: ChunkClipmap, position: Position) usize {
    const dims = dimsFor(clipmap.half_extent);
    const wrapped: @Vector(3, usize) = @intCast(@mod(position, dims));
    return wrapped[0] + @as(usize, @intCast(dims[0])) * (wrapped[1] + @as(usize, @intCast(dims[1])) * wrapped[2]);
}

fn dimsFor(half_extent: @Vector(3, u32)) Position {
    return @as(Position, @intCast(half_extent)) * @as(Position, @splat(2)) + @as(Position, @splat(1));
}

fn testRegion(smith: *std.testing.Smith) Region {
    return .{
        .center = .{ smith.value(i4), smith.value(i4), smith.value(i4) },
        .outer = .{ smith.value(u3), smith.value(u3), smith.value(u3) },
        .hole = .{ smith.value(u3), smith.value(u3), smith.value(u3) },
    };
}

/// Marks visited positions in a 64^3 grid around the origin and panics on a repeat.
const VisitGrid = struct {
    seen: std.StaticBitSet(64 * 64 * 64) = .empty,

    fn index(position: Position) usize {
        const shifted: @Vector(3, usize) = @intCast(position + @as(Position, @splat(32)));
        return shifted[0] + 64 * (shifted[1] + 64 * shifted[2]);
    }

    fn visit(grid: *VisitGrid, position: Position) !void {
        if (grid.seen.isSet(index(position))) @panic("position visited twice");
        grid.seen.set(index(position));
    }
};

fn fuzzDifference(_: void, smith: *std.testing.Smith) !void {
    const a = testRegion(smith);
    const b: ?Region = if (smith.value(bool)) testRegion(smith) else null;
    var grid: VisitGrid = .{};
    try a.forEachDifference(b, &grid, VisitGrid.visit);

    var x: i32 = -24;
    while (x < 24) : (x += 1) {
        var y: i32 = -24;
        while (y < 24) : (y += 1) {
            var z: i32 = -24;
            while (z < 24) : (z += 1) {
                const position: Position = .{ x, y, z };
                const expected = a.contains(position) and !(if (b) |region| region.contains(position) else false);
                if (grid.seen.isSet(VisitGrid.index(position)) != expected) @panic("difference disagrees with contains");
            }
        }
    }
}

test "ChunkClipmap region difference matches contains" {
    try std.testing.fuzz({}, fuzzDifference, .{});
}

fn clipmapAllocDeinit(gpa: std.mem.Allocator) !void {
    var clipmap: ChunkClipmap = try .init(gpa, -1, 2, .{ 2, 1, 2 }, .{ 0, 0, 0 });
    clipmap.deinit(gpa);
}

test "ChunkClipmap checkAllAllocationFailures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, clipmapAllocDeinit, .{});
}

test {
    std.testing.refAllDecls(@This());
}
