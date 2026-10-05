const std = @import("std");

const Block = @import("../Block.zig").Block;
const Chunk = @import("../Chunk.zig");
const ChunkSize = Chunk.ChunkSize;
const World = @import("../World.zig");

/// Shared host-generator interface. Both sides share one compiler, so layouts match across the boundary.
/// Version is semver: minor grows for compatible additions, major for breaking changes.
pub const ApiVersion: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 };

/// Whether a plugin built against `plugin_version` can run on this host.
/// Major must always match; while major is 0 (pre-1.0, including now) the
/// minor and patch must match exactly, since anything may still break.
pub fn apiCompatible(plugin_version: std.SemanticVersion) bool {
    if (plugin_version.major != ApiVersion.major) return false;
    if (ApiVersion.major == 0) return plugin_version.minor == ApiVersion.minor and plugin_version.patch == ApiVersion.patch;
    return plugin_version.minor <= ApiVersion.minor;
}

pub const GeneratorInfo = struct {
    name: []const u8,
    description: []const u8,
    version: u32,
    api_version: std.SemanticVersion,
};

pub const CreateOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Budget for generator caches such as the terrain height cache.
    max_cache_bytes: u64,
};

/// The value of a single config parameter. Config trees are plain data: all
/// Config keys, values, and choice entries are allocated with the allocator
/// that created the tree. Presentation metadata in `Spec` is borrowed from the
/// generator library, so it remains valid while that library is loaded.
pub const Value = union(enum) {
    group: Group,
    array: Array,
    f32: f32,
    i32: i32,
    u32: u32,
    u64: u64,
    bool: bool,
    string: []const u8,
    /// Index into `Spec.entries`.
    choice: usize,
};

/// Rendering hints for a param. `entries` doubles as the dropdown options for
/// `.choice` values and as preset names for struct-valued params.
pub const Spec = struct {
    /// Optional user-facing label. The host derives one from the field name when empty.
    label: []const u8 = "",
    /// Optional explanation shown by the host UI.
    description: []const u8 = "",
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
    entries: []const []const u8 = &.{},
    /// The host fills params with this flag set via `generator_config_set_seeds`.
    is_seed: bool = false,
    /// Excludes the field from the config tree entirely.
    skip: bool = false,
    /// Hides the field until the host's advanced settings are enabled.
    advanced: bool = false,
};

pub const Param = struct {
    name: []const u8,
    spec: Spec = .{},
    value: Value,
};

pub const Group = struct {
    params: []Param,
};

pub const Array = struct {
    /// Template for new items added by the host UI.
    element: *Param,
    items: []Param,
};

pub const ConfigTree = Group;

/// Proposed spawn in world blocks. `found == false` abstains, and the host fails loudly.
pub const Spawnpoint = extern struct {
    pos: [3]f64,
    found: bool = false,
};

/// Shared spawn-search tuning, so behavior matches across plugins.
pub const spawn_samples_per_ring: u32 = 8;
pub const spawn_max_ring: u32 = 20;
pub const spawn_ring_step: f64 = 16.0;
/// Full-schedule upper bound. Hosts pass smaller budgets for cheaper searches.
pub const spawn_attempt_cap: u32 = (spawn_max_ring + 1) * spawn_samples_per_ring;
pub const spawn_slope_weight: f64 = 64.0;
pub const spawn_ocean_penalty: f64 = 1e9;
pub const spawn_steep_penalty: f64 = 1e6;
pub const spawn_steep_limit: f32 = 1.0;
pub const spawn_water_margin: f32 = 1.0;
/// Feet hint height above the estimated top. The host resolves exact feet.
pub const spawn_hint_clearance: f32 = 2.6;

/// Splits a 64-bit hash into two uniform [0, 1) fractions.
pub fn hashFracs(h: u64) [2]f64 {
    return .{
        @as(f64, @floatFromInt(h & 0xFFFFFFFF)) / 4294967296.0,
        @as(f64, @floatFromInt(h >> 32)) / 4294967296.0,
    };
}

/// Deterministic disc sample shared by every spawn search. `radius` is soft: ring 0
/// stays within `radius`, later rings double outward to escape oceans.
pub fn spawnSample(seed: u64, center: [2]f64, radius: f64, nonce: u64, i: u32) [2]f64 {
    var hasher = std.hash.Wyhash.init(seed ^ nonce ^ 0x9e3779b97f4a7c15);
    std.hash.autoHash(&hasher, i);
    const fracs = hashFracs(hasher.final());
    // Larger budgets search farther, not denser, so retries escape the basin.
    const ring = @min(i / spawn_samples_per_ring, spawn_max_ring);
    const extra: f64 = spawn_ring_step * (@exp2(@as(f64, @floatFromInt(ring))) - 1.0);
    const r = radius + extra;
    if (r <= 0) return center;
    // Sqrt spreads samples evenly, so near-center candidates win distance terms.
    const dist = r * @sqrt(fracs[0]);
    const angle = std.math.tau * fracs[1] + @as(f64, @floatFromInt(i % spawn_samples_per_ring)) * (std.math.tau / @as(f64, spawn_samples_per_ring));
    return .{ center[0] + @cos(angle) * dist, center[1] + @sin(angle) * dist };
}

/// Column score. Water and steep columns stay tracked, so ocean seeds still return a point.
const SpawnScore = struct {
    score: f64,
    wet: bool,
    steep: bool,
};

fn scoreSpawnColumn(dist: f64, height_above_water: f32, slope: f32) SpawnScore {
    const wet = height_above_water <= spawn_water_margin;
    const steep = slope >= spawn_steep_limit;
    return .{
        .score = dist + @as(f64, slope) * spawn_slope_weight + (if (wet) spawn_ocean_penalty else 0) + (if (steep) spawn_steep_penalty else 0),
        .wet = wet,
        .steep = steep,
    };
}

/// Shared best-candidate tracker for the pick-test-retry loops.
pub const SpawnBest = struct {
    point: Spawnpoint = .{ .pos = .{ 0, 0, 0 }, .found = false },
    score: f64 = std.math.inf(f64),
    good: bool = false,
};

/// Folds one sampled column into `best`. Scores distance from `center` plus
/// `extra_score` (a generator-specific penalty, 0 when unused); `extra_good`
/// joins the shared wet/steep gate for early exit.
pub fn considerSpawnColumn(center: *const [3]f64, sample: [2]f64, height_above_water: f32, slope: f32, top: f64, extra_score: f64, extra_good: bool, best: *SpawnBest) void {
    const dx = sample[0] - center[0];
    const dz = sample[1] - center[2];
    const scored = scoreSpawnColumn(@sqrt(dx * dx + dz * dz), height_above_water, slope);
    const score = scored.score + extra_score;
    if (score >= best.score) return;
    best.score = score;
    best.point = .{ .pos = .{ sample[0], top + spawn_hint_clearance, sample[1] }, .found = true };
    best.good = !scored.wet and !scored.steep and extra_good;
}

/// Shared pick-test-retry loop for heightfield generators. Pure; the host re-validates the winner.
pub fn proposeSpawnField(
    seed: ?u64,
    center: [3]f64,
    radius: f64,
    attempts: u32,
    nonce: u64,
    sea_level: f32,
    context: anytype,
    comptime columnHeight: anytype,
) Spawnpoint {
    const live_seed = seed orelse return no_spawn;
    var best = SpawnBest{};
    const capped = @min(attempts, spawn_attempt_cap);
    for (0..capped) |i| {
        // Analytic test only; the host re-validates the winner.
        const sample = spawnSample(live_seed, .{ center[0], center[2] }, radius, nonce, @intCast(i));
        const sx: f32 = @floatCast(sample[0]);
        const sz: f32 = @floatCast(sample[1]);
        const h = columnHeight(context, sx, sz);
        const hx = columnHeight(context, sx + 2, sz);
        const hz = columnHeight(context, sx, sz + 2);
        const slope = @max(@abs(hx - h), @abs(hz - h)) / 2.0;
        // Top solid block is floor(h); the hint only needs the column.
        considerSpawnColumn(&center, sample, h - sea_level, slope, @floor(h), 0, true, &best);
        if (i >= spawn_samples_per_ring - 1 and best.good) break;
    }
    return best.point;
}

/// Vtable each generator exports. Aggregates cross as pointers; teardown runs through `get_source`.
pub const GeneratorApi = extern struct {
    info: *const fn () callconv(.c) *const GeneratorInfo,
    create: *const fn (opts: *const CreateOptions, config: *const ConfigTree) callconv(.c) ?*anyopaque,
    get_source: *const fn (instance: *anyopaque) callconv(.c) *const World.ChunkSource,
    preset_count: *const fn () callconv(.c) usize,
    /// Name of the preset at `index`. The slice lives as long as the library.
    preset_name: *const fn (index: usize) callconv(.c) *const []const u8,
    preset_default_index: *const fn () callconv(.c) usize,
    /// Config tree for the preset at `index`. The host frees it with `generator_api.free`.
    preset_config: *const fn (allocator: *const std.mem.Allocator, index: usize) callconv(.c) ?*ConfigTree,
    /// Null on invalid bytes; the host then uses the default preset.
    config_from_zon: *const fn (allocator: *const std.mem.Allocator, bytes: [*]const u8, bytes_len: usize) callconv(.c) ?*ConfigTree,
    /// Fills unset seeds. Runs before `create` so seeds persist.
    config_set_seeds: *const fn (io: *const std.Io, config: *ConfigTree) callconv(.c) void,
    /// Spawn near `center` with a soft `radius`. Pure and deterministic; Y is a hint the host resolves.
    /// `found == false` fails the spawn loudly.
    propose_spawn: *const fn (
        instance: *anyopaque,
        center: *const [3]f64,
        radius: f64,
        attempts: u32,
        nonce: u64,
    ) callconv(.c) Spawnpoint,
};

pub const api_export_name = "generator_api";

/// Config tree helpers shared by host and generators.
/// Every string belongs to the creating allocator, so `free` walks the whole tree.
pub fn free(allocator: std.mem.Allocator, tree: *ConfigTree) void {
    freeGroup(allocator, tree);
    allocator.destroy(tree);
}

pub fn clone(allocator: std.mem.Allocator, tree: *const ConfigTree) error{OutOfMemory}!*ConfigTree {
    const new = try allocator.create(ConfigTree);
    errdefer allocator.destroy(new);
    new.params = try cloneParams(allocator, tree.params);
    return new;
}

/// Content equality for change detection. Templates compare by pointee.
pub fn eql(a: *const ConfigTree, b: *const ConfigTree) bool {
    if (a.params.len != b.params.len) return false;
    for (a.params, b.params) |*pa, *pb| {
        if (!paramEql(pa, pb)) return false;
    }
    return true;
}

fn paramEql(a: *const Param, b: *const Param) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (a.spec.min != b.spec.min or a.spec.max != b.spec.max) return false;
    if (a.spec.step != b.spec.step or a.spec.is_seed != b.spec.is_seed) return false;
    if (a.spec.advanced != b.spec.advanced) return false;
    if (!entriesEql(a.spec.entries, b.spec.entries)) return false;
    return valueEql(&a.value, &b.value);
}

fn entriesEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ea, eb| {
        if (!std.mem.eql(u8, ea, eb)) return false;
    }
    return true;
}

fn valueEql(a: *const Value, b: *const Value) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    switch (a.*) {
        .group => |*ga| return eql(ga, &b.group),
        .array => |*aa| {
            if (aa.items.len != b.array.items.len) return false;
            if (!paramEql(aa.element, b.array.element)) return false;
            for (aa.items, b.array.items) |*ia, *ib| {
                if (!paramEql(ia, ib)) return false;
            }
            return true;
        },
        .string => |sa| return std.mem.eql(u8, sa, b.string),
        .f32 => |va| return va == b.f32,
        .i32 => |va| return va == b.i32,
        .u32 => |va| return va == b.u32,
        .u64 => |va| return va == b.u64,
        .bool => |va| return va == b.bool,
        .choice => |va| return va == b.choice,
    }
}

pub fn arrayAdd(allocator: std.mem.Allocator, array: *Array) error{OutOfMemory}!void {
    const old_len = array.items.len;
    // Clone first so either failure leaves the array untouched.
    const item = try cloneParam(allocator, array.element);
    errdefer freeParam(allocator, &item);
    array.items = try allocator.realloc(array.items, old_len + 1);
    array.items[old_len] = item;
}

pub fn arrayRemove(allocator: std.mem.Allocator, array: *Array, index: usize) void {
    std.debug.assert(index < array.items.len);
    // Copy into a fresh shrink so a failed alloc leaves the array whole.
    const new_items = allocator.alloc(Param, array.items.len - 1) catch return;
    const removed = array.items[index];
    @memcpy(new_items[0..index], array.items[0..index]);
    @memcpy(new_items[index..], array.items[index + 1 ..]);
    allocator.free(array.items);
    array.items = new_items;
    freeParam(allocator, &removed);
}

pub fn emitZon(w: *std.Io.Writer, tree: *const ConfigTree) !void {
    try emitGroup(w, tree);
}

fn emitGroup(w: *std.Io.Writer, group: *const Group) std.Io.Writer.Error!void {
    try w.print(".{{\n", .{});
    for (group.params) |*param| {
        try emitParam(w, param);
        try w.print(",\n", .{});
    }
    try w.print("}}", .{});
}

fn emitParam(w: *std.Io.Writer, param: *const Param) std.Io.Writer.Error!void {
    try w.print(".{s} = ", .{param.name});
    switch (param.value) {
        .choice => |index| {
            if (index >= param.spec.entries.len) return w.print("null", .{});
            const entry = param.spec.entries[index];
            if (std.zig.isValidId(entry)) return w.print(".{s}", .{entry});
            try emitString(w, entry);
        },
        else => try emitValue(w, &param.value),
    }
}

fn emitValue(w: *std.Io.Writer, value: *const Value) std.Io.Writer.Error!void {
    switch (value.*) {
        .group => |*group| try emitGroup(w, group),
        .array => |*array| {
            try w.print(".{{\n", .{});
            for (array.items) |*item| {
                try emitValue(w, &item.value);
                try w.print(",\n", .{});
            }
            try w.print("}}", .{});
        },
        .f32 => |v| try emitFloat(w, v),
        .i32 => |v| try w.print("{d}", .{v}),
        .u32 => |v| try w.print("{d}", .{v}),
        .u64 => |v| try w.print("{d}", .{v}),
        .bool => |v| try w.print("{}", .{v}),
        .string => |s| try emitString(w, s),
        .choice => unreachable, // handled by emitParam
    }
}

fn emitFloat(w: *std.Io.Writer, value: f32) std.Io.Writer.Error!void {
    var buffer: [64]u8 = undefined;
    const s = std.mem.print(&buffer, "{d}", .{value}) catch unreachable;
    if (std.mem.findAny(u8, s, ".eE") == null) {
        try w.print("{s}.0", .{s});
    } else {
        try w.print("{s}", .{s});
    }
}

fn emitString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.print("\"", .{});
    for (s) |c| switch (c) {
        '"' => try w.print("\\\"", .{}),
        '\\' => try w.print("\\\\", .{}),
        '\n' => try w.print("\\n", .{}),
        '\r' => try w.print("\\r", .{}),
        '\t' => try w.print("\\t", .{}),
        else => try w.writeByte(c),
    };
    try w.print("\"", .{});
}

/// Looks up a field's spec entry. The spec map is flat: entries apply to
/// every struct at any nesting depth that has a field with the same name.
fn fieldSpec(comptime field_specs: anytype, comptime name: []const u8) Spec {
    if (!@hasField(@TypeOf(field_specs), name)) return .{};
    const s = @field(field_specs, name);
    const is_spec = @hasField(@TypeOf(s), "label") or @hasField(@TypeOf(s), "description") or
        @hasField(@TypeOf(s), "min") or @hasField(@TypeOf(s), "max") or
        @hasField(@TypeOf(s), "step") or @hasField(@TypeOf(s), "entries") or
        @hasField(@TypeOf(s), "is_seed") or @hasField(@TypeOf(s), "skip") or
        @hasField(@TypeOf(s), "advanced");
    if (!is_spec) return .{};
    return .{
        .label = if (@hasField(@TypeOf(s), "label")) s.label else "",
        .description = if (@hasField(@TypeOf(s), "description")) s.description else "",
        .min = if (@hasField(@TypeOf(s), "min")) s.min else null,
        .max = if (@hasField(@TypeOf(s), "max")) s.max else null,
        .step = if (@hasField(@TypeOf(s), "step")) s.step else null,
        .entries = if (@hasField(@TypeOf(s), "entries")) s.entries else &.{},
        .is_seed = if (@hasField(@TypeOf(s), "is_seed")) s.is_seed else false,
        .skip = if (@hasField(@TypeOf(s), "skip")) s.skip else false,
        .advanced = if (@hasField(@TypeOf(s), "advanced")) s.advanced else false,
    };
}

/// Builds a config tree from a struct. Unhandled field types are skipped.
pub fn fromStruct(comptime T: type, allocator: std.mem.Allocator, value: *const T, comptime field_specs: anytype) error{OutOfMemory}!*ConfigTree {
    const tree = try allocator.create(ConfigTree);
    errdefer allocator.destroy(tree);
    tree.params = try paramsFromStruct(T, allocator, value, field_specs);
    return tree;
}

/// Applies a tree onto a struct. Missing or mismatched params keep their values.
pub fn fromTree(comptime T: type, allocator: std.mem.Allocator, tree: *const ConfigTree, out: *T, comptime field_specs: anytype) error{OutOfMemory}!void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        if (findParam(tree, name)) |param| {
            try applyField(F, allocator, &@field(out, name), param, fieldSpec(field_specs, name), field_specs);
        }
    }
}

fn paramsFromStruct(comptime T: type, allocator: std.mem.Allocator, value: *const T, comptime field_specs: anytype) error{OutOfMemory}![]Param {
    var list: std.ArrayList(Param) = .empty;
    errdefer {
        for (list.items) |*p| freeParam(allocator, p);
        list.deinit(allocator);
    }
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        const maybe_param = try paramFromTypeValue(F, allocator, name, @field(value, name), fieldSpec(field_specs, name), field_specs);
        if (maybe_param) |param| {
            list.append(allocator, param) catch |err| {
                freeParam(allocator, &param);
                return err;
            };
        }
    }
    return list.toOwnedSlice(allocator);
}

fn paramFromTypeValue(comptime T: type, allocator: std.mem.Allocator, comptime name: []const u8, field_value: anytype, comptime spec: Spec, comptime field_specs: anytype) error{OutOfMemory}!?Param {
    if (spec.skip) return null;
    const n = try allocator.dupe(u8, name);
    errdefer allocator.free(n);
    var spec_copy = try dupeSpec(allocator, &spec);
    errdefer allocator.free(spec_copy.entries);
    if (spec_copy.entries.len == 0 and @typeInfo(T) == .@"enum") {
        spec_copy.entries = try dupeEnumEntries(T, allocator);
    }
    const v = (try valueFromField(T, allocator, field_value, field_specs)) orelse {
        allocator.free(n);
        allocator.free(spec_copy.entries);
        return null;
    };
    return .{ .name = n, .spec = spec_copy, .value = v };
}

fn dupeEnumEntries(comptime T: type, allocator: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
    const field_names = @typeInfo(T).@"enum".field_names;
    const names: [field_names.len][]const u8 = blk: {
        var arr: [field_names.len][]const u8 = undefined;
        for (&arr, field_names) |*dst, name| dst.* = name;
        break :blk arr;
    };
    return dupeEntries(allocator, &names);
}

fn valueFromField(comptime T: type, allocator: std.mem.Allocator, field_value: anytype, comptime field_specs: anytype) error{OutOfMemory}!?Value {
    const field_type = @typeInfo(@TypeOf(field_value));
    const value = if (field_type == .pointer and field_type.pointer.size != .slice) field_value.* else field_value;
    switch (@typeInfo(T)) {
        .float => return .{ .f32 = @floatCast(value) },
        .int => |info| {
            if (info.signedness == .signed) {
                if (info.bits <= 32) return .{ .i32 = @intCast(value) };
                return null;
            }
            if (info.bits <= 32) return .{ .u32 = @intCast(value) };
            return .{ .u64 = @intCast(value) };
        },
        .bool => return .{ .bool = value },
        .@"enum" => return .{ .choice = @backingInt(value) },
        .optional => |info| {
            if (@typeInfo(info.child) != .int) return null;
            if (value) |v| return .{ .u64 = @intCast(v) };
            return .{ .u64 = 0 };
        },
        .@"struct" => {
            const tree = try fromStruct(T, allocator, &value, field_specs);
            defer allocator.destroy(tree);
            return .{ .group = tree.* };
        },
        .pointer => |info| {
            if (info.size != .slice) return null;
            if (@typeInfo(info.child) != .@"struct") return null;
            const Child = info.child;
            const items = @as([]const Child, if (@typeInfo(T) == .array) &value else value);
            const element = try allocator.create(Param);
            errdefer allocator.destroy(element);
            var zero: Child = .{};
            const sample = if (items.len > 0) &items[0] else &zero;
            element.* = (try paramFromTypeValue(Child, allocator, "item", sample, .{}, field_specs)) orelse return null;
            errdefer freeParam(allocator, element);
            const new_items = try allocator.alloc(Param, items.len);
            var count: usize = 0;
            errdefer {
                for (new_items[0..count]) |*p| freeParam(allocator, p);
                allocator.free(new_items);
            }
            for (items, new_items) |*item, *dst| {
                dst.* = (try paramFromTypeValue(Child, allocator, "item", item, .{}, field_specs)) orelse return null;
                count += 1;
            }
            return .{ .array = .{ .element = element, .items = new_items } };
        },
        else => return null,
    }
}

fn applyField(comptime T: type, allocator: std.mem.Allocator, field_ptr: *T, param: *const Param, comptime spec: Spec, comptime field_specs: anytype) error{OutOfMemory}!void {
    if (spec.skip) return;
    switch (@typeInfo(T)) {
        .float => {
            if (param.value != .f32) return;
            field_ptr.* = param.value.f32;
        },
        .int => {
            const source: i128 = switch (param.value) {
                .i32 => |v| v,
                .u32 => |v| v,
                .u64 => |v| @as(i128, @intCast(v)),
                else => return,
            };
            field_ptr.* = std.math.cast(T, source) orelse return;
        },
        .bool => {
            if (param.value != .bool) return;
            field_ptr.* = param.value.bool;
        },
        .@"enum" => {
            if (param.value != .choice) return;
            if (param.value.choice >= @typeInfo(T).@"enum".field_names.len) return;
            field_ptr.* = @fromBackingInt(@intCast(param.value.choice));
        },
        .optional => |info| {
            if (param.value != .u64) return;
            if (@typeInfo(info.child) != .int) return;
            if (param.value.u64 == 0) {
                field_ptr.* = null;
            } else {
                field_ptr.* = std.math.cast(info.child, param.value.u64) orelse return;
            }
        },
        .@"struct" => {
            if (param.value != .group) return;
            const info = @typeInfo(T).@"struct";
            inline for (info.field_names, info.field_types) |name, F| {
                if (findParam(&param.value.group, name)) |child| {
                    try applyField(F, allocator, &@field(field_ptr, name), child, fieldSpec(field_specs, name), field_specs);
                }
            }
        },
        .pointer => |info| {
            if (param.value != .array) return;
            if (info.size != .slice) return;
            if (@typeInfo(info.child) != .@"struct") return;
            const Child = info.child;
            const items = param.value.array.items;
            const new_items = try allocator.alloc(Child, items.len);
            errdefer allocator.free(new_items);
            for (new_items) |*item| item.* = .{};
            for (items, new_items) |*item, *dst| {
                if (item.value == .group) {
                    try applyField(Child, allocator, dst, item, .{}, field_specs);
                }
            }
            field_ptr.* = new_items;
        },
        else => return,
    }
}

fn findParam(group: *const ConfigTree, name: []const u8) ?*const Param {
    for (group.params) |*param| {
        if (std.mem.eql(u8, param.name, name)) return param;
    }
    return null;
}

fn dupeSpec(allocator: std.mem.Allocator, spec: *const Spec) error{OutOfMemory}!Spec {
    return .{
        // label/description/advanced stay borrowed from the loaded generator library.
        .label = spec.label,
        .description = spec.description,
        .min = spec.min,
        .max = spec.max,
        .step = spec.step,
        .entries = try dupeEntries(allocator, spec.entries),
        .is_seed = spec.is_seed,
        .skip = spec.skip,
        .advanced = spec.advanced,
    };
}

fn dupeEntries(allocator: std.mem.Allocator, entries: []const []const u8) error{OutOfMemory}![]const []const u8 {
    if (entries.len == 0) return &.{};
    const new = try allocator.alloc([]const u8, entries.len);
    var count: usize = 0;
    errdefer {
        for (new[0..count]) |e| allocator.free(e);
        allocator.free(new);
    }
    for (entries, new) |entry, *dst| {
        dst.* = try allocator.dupe(u8, entry);
        count += 1;
    }
    return new;
}

fn freeGroup(allocator: std.mem.Allocator, group: *const Group) void {
    for (group.params) |*param| freeParam(allocator, param);
    allocator.free(group.params);
}

fn freeParam(allocator: std.mem.Allocator, param: *const Param) void {
    allocator.free(param.name);
    for (param.spec.entries) |entry| allocator.free(entry);
    allocator.free(param.spec.entries);
    switch (param.value) {
        .string => |s| allocator.free(s),
        .group => |*group| freeGroup(allocator, group),
        .array => |*array| {
            freeParam(allocator, array.element);
            allocator.destroy(array.element);
            for (array.items) |*item| freeParam(allocator, item);
            allocator.free(array.items);
        },
        else => {},
    }
}

fn cloneParams(allocator: std.mem.Allocator, params: []const Param) error{OutOfMemory}![]Param {
    const new = try allocator.alloc(Param, params.len);
    var count: usize = 0;
    errdefer {
        for (new[0..count]) |*p| freeParam(allocator, p);
        allocator.free(new);
    }
    for (params, new) |*src, *dst| {
        dst.* = try cloneParam(allocator, src);
        count += 1;
    }
    return new;
}

fn cloneParam(allocator: std.mem.Allocator, src: *const Param) error{OutOfMemory}!Param {
    const name = try allocator.dupe(u8, src.name);
    errdefer allocator.free(name);
    const spec = try dupeSpec(allocator, &src.spec);
    errdefer allocator.free(spec.entries);
    var value: Value = undefined;
    switch (src.value) {
        .string => |s| value = .{ .string = try allocator.dupe(u8, s) },
        .group => |*group| value = .{ .group = .{ .params = try cloneParams(allocator, group.params) } },
        .array => |*array| value = .{ .array = try cloneArray(allocator, array) },
        else => value = src.value,
    }
    return .{ .name = name, .spec = spec, .value = value };
}

fn cloneArray(allocator: std.mem.Allocator, src: *const Array) error{OutOfMemory}!Array {
    const element = try allocator.create(Param);
    errdefer allocator.destroy(element);
    element.* = try cloneParam(allocator, src.element);
    errdefer freeParam(allocator, element);
    const items = try cloneParams(allocator, src.items);
    return .{ .element = element, .items = items };
}

/// Shared boilerplate behind the per-generator C wrappers. Addresses still point at static tables.
pub fn presetConfig(comptime Params: type, comptime field_specs: anytype, comptime presets: anytype, allocator: *const std.mem.Allocator, index: usize) ?*ConfigTree {
    if (index >= presets.len) return null;
    return fromStruct(Params, allocator.*, &presets[index], field_specs) catch null;
}

pub fn configFromZon(comptime Params: type, comptime field_specs: anytype, allocator: *const std.mem.Allocator, bytes: [*]const u8, bytes_len: usize) ?*ConfigTree {
    @setEvalBranchQuota(100000000);
    // The parsed params may hold comptime-backed defaults (e.g. tree presets),
    // so free them as a whole arena instead of walking the struct.
    var arena = std.heap.ArenaAllocator.init(allocator.*);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const params = std.zon.parse.fromSlice(Params, .{
        .gpa = allocator.*,
        .arena = arena.allocator(),
        .source = bytes[0..bytes_len :0],
        .diagnostics = &diagnostics,
    }) catch |err| {
        if (err == error.ParseZon) diagnostics.log("generator config");
        return null;
    };
    return fromStruct(Params, allocator.*, &params, field_specs) catch null;
}

pub fn configSetSeeds(io: *const std.Io, config: *ConfigTree) void {
    var random_seed: u64 = undefined;
    io.*.random(std.mem.asBytes(&random_seed));
    for (config.params) |*param| {
        if (param.spec.is_seed and param.value == .u64 and param.value.u64 == 0) {
            param.value.u64 = random_seed;
        }
    }
}

/// Abstention every `propose_spawn` returns when its seed is unset. The host fails loudly.
pub const no_spawn: Spawnpoint = .{ .pos = .{ 0, 0, 0 }, .found = false };

pub fn getSource(comptime Instance: type, instance: *anyopaque) *const World.ChunkSource {
    const self: *Instance = @ptrCast(@alignCast(instance));
    return &self.source;
}

/// Vtable slot types behind each `generator_create` source table.
const BlocksFn = @TypeOf(@as(World.ChunkSource, undefined).getBlocks);
const DeinitFn = @TypeOf(@as(World.ChunkSource, undefined).deinit);
const BlocksRet = error{ Unrecoverable, OutOfMemory, Canceled }!?World.ChunkSource.GetBlocksMetadata;
const GridBuf = *align(Chunk.Encoding.GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block;

/// Shared getBlocks: `.getBlocks = instanceGenBlocks(Foo)`. Picks full/short `genChunk` args by arity, `try` by fallibility.
pub fn instanceGenBlocks(comptime Instance: type) BlocksFn {
    return &struct {
        fn f(source: World.ChunkSource, io: std.Io, alloc: std.mem.Allocator, world: *World, blocks: *Chunk.Encoding, pos: World.ChunkPos, grid: GridBuf) BlocksRet {
            const self: *Instance = @ptrCast(@alignCast(source.data));
            const Gen = @TypeOf(self.generator);
            const info = @typeInfo(@TypeOf(Gen.genChunk)).@"fn";
            const fallible = @typeInfo(info.return_type orelse void) == .error_union;
            if (comptime info.param_types.len > 5) {
                if (comptime fallible) try self.generator.genChunk(io, alloc, pos, blocks, world, grid) else self.generator.genChunk(io, alloc, pos, blocks, world, grid);
            } else if (comptime fallible) try self.generator.genChunk(io, blocks, pos, grid) else self.generator.genChunk(io, blocks, pos, grid);
            return .{ .from_disk = false, .structures = false };
        }
    }.f;
}

/// Shared deinit: `.deinit = instanceDeinit(Foo)`. Drops the height cache/arena when present, then frees the instance.
pub fn instanceDeinit(comptime Instance: type) DeinitFn {
    return &struct {
        fn f(source: World.ChunkSource, io: std.Io, alloc: std.mem.Allocator, world: *World) void {
            _ = .{ io, world };
            const self: *Instance = @ptrCast(@alignCast(source.data));
            if (@hasField(@TypeOf(self.generator), "terrain_height_cache")) self.generator.terrain_height_cache.deinit(alloc);
            if (@hasField(Instance, "arena")) self.arena.deinit();
            alloc.destroy(self);
        }
    }.f;
}

const TestConfig = struct {
    enabled: bool = true,
    scale: f32 = 0.5,
    count: u32 = 3,
    seed: ?u64 = null,
    mode: TestMode = .b,
    inner: Inner = .{},
    items: []const Item = &.{},

    const TestMode = enum { a, b, c };
    const Inner = struct {
        freq: f32 = 0.1,
        octaves: u32 = 4,
    };
    const Item = struct {
        enabled: bool = true,
        value: f32 = 1.5,
    };
};

const test_specs = .{
    .scale = .{ .min = 0, .max = 2 },
    .freq = .{ .min = 0, .max = 1 },
    .octaves = .{ .min = 1, .max = 8 },
    .seed = .{ .is_seed = true },
    .value = .{ .min = 0, .max = 10 },
};

test "fromStruct fromTree round trip" {
    const allocator = std.testing.allocator;
    var config: TestConfig = .{ .items = &.{
        .{ .enabled = false, .value = 3.25 },
        .{ .value = 0.125 },
    } };

    const tree = try fromStruct(TestConfig, allocator, &config, test_specs);
    defer free(allocator, tree);

    var back: TestConfig = .{ .items = &.{} };
    defer if (back.items.len > 0) allocator.free(back.items);
    try fromTree(TestConfig, allocator, tree, &back, test_specs);

    try std.testing.expectEqual(true, back.enabled);
    try std.testing.expectEqual(@as(f32, 0.5), back.scale);
    try std.testing.expectEqual(@as(u32, 3), back.count);
    try std.testing.expectEqual(@as(?u64, null), back.seed);
    try std.testing.expectEqual(TestConfig.TestMode.b, back.mode);
    try std.testing.expectEqual(@as(f32, 0.1), back.inner.freq);
    try std.testing.expectEqual(@as(u32, 4), back.inner.octaves);
    try std.testing.expectEqual(@as(usize, 2), back.items.len);
    try std.testing.expectEqual(false, back.items[0].enabled);
    try std.testing.expectEqual(@as(f32, 3.25), back.items[0].value);
    try std.testing.expectEqual(@as(f32, 0.125), back.items[1].value);
}

test "fromStruct allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var config: TestConfig = .{ .items = &.{} };
            const tree = try fromStruct(TestConfig, allocator, &config, test_specs);
            free(allocator, tree);
        }
    }.testFn, .{});
}

test "clone and array add remove" {
    const allocator = std.testing.allocator;
    var config: TestConfig = .{ .items = &.{} };

    const tree = try fromStruct(TestConfig, allocator, &config, test_specs);
    defer free(allocator, tree);

    const copy = try clone(allocator, tree);
    defer free(allocator, copy);
    try std.testing.expect(eql(tree, copy));
    try std.testing.expect(eql(copy, tree));

    const array = &tree.params[6].value.array;
    try arrayAdd(allocator, array);
    try std.testing.expectEqual(@as(usize, 1), array.items.len);
    arrayRemove(allocator, array, 0);
    try std.testing.expectEqual(@as(usize, 0), array.items.len);
}

test "arrayAdd allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            var config: TestConfig = .{ .items = &.{} };
            const tree = try fromStruct(TestConfig, allocator, &config, test_specs);
            defer free(allocator, tree);
            const array = &tree.params[6].value.array;
            try arrayAdd(allocator, array);
            try arrayAdd(allocator, array);
        }
    }.testFn, .{});
}

test "arrayRemove keeps both items owned when its allocation fails" {
    const allocator = std.testing.allocator;
    var config: TestConfig = .{ .items = &.{} };
    const tree = try fromStruct(TestConfig, allocator, &config, test_specs);
    defer free(allocator, tree);
    const array = &tree.params[6].value.array;
    try arrayAdd(allocator, array);
    try arrayAdd(allocator, array);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    arrayRemove(failing.allocator(), array, 0);

    // The failed removal must leave the array whole: freeing the tree below
    // detects a leaked tail or a double-freed duplicate item.
    try std.testing.expectEqual(@as(usize, 2), array.items.len);
}

test "apiCompatible enforces semver" {
    try std.testing.expect(apiCompatible(ApiVersion));
    try std.testing.expect(!apiCompatible(.{ .major = 1, .minor = 0, .patch = 0 }));
    try std.testing.expect(!apiCompatible(.{ .major = 0, .minor = 1, .patch = 0 }));
    try std.testing.expect(!apiCompatible(.{ .major = 0, .minor = 0, .patch = 1 }));
}

test "spawnSample radius zero returns center" {
    const center = [2]f64{ 10, -20 };
    for (0..8) |i| {
        const p = spawnSample(42, center, 0, 7, @intCast(i));
        try std.testing.expectEqual(center[0], p[0]);
        try std.testing.expectEqual(center[1], p[1]);
    }
}

test "spawnSample is deterministic and ring 0 stays in radius" {
    const center = [2]f64{ 0, 0 };
    const a = spawnSample(42, center, 32, 1, 9);
    const b = spawnSample(42, center, 32, 1, 9);
    try std.testing.expectEqual(a[0], b[0]);
    try std.testing.expectEqual(a[1], b[1]);
    for (0..spawn_samples_per_ring) |i| {
        const p = spawnSample(99, center, 32, 5, @intCast(i));
        const d = @sqrt(p[0] * p[0] + p[1] * p[1]);
        try std.testing.expect(d <= 32.0);
    }
}
