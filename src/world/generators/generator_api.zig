const std = @import("std");

const World = @import("../World.zig");

/// Shared interface between the terrafinity host and generator shared
/// libraries. Both sides are compiled by the same `zig build` with the same
/// compiler, so every type here has identical layout across the DLL boundary.
///
/// The API version is semver: bump minor for backward-compatible additions
/// (e.g. appended vtable entries the host guards), major for breaking
/// changes (removed/changed entries, shared layout changes).
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

/// A generator-proposed spawn position in world blocks. Returned by value
/// from `propose_spawn`; `found == false` means the generator abstains and
/// the host must fail the spawn loudly (there is no fallback spawn point).
/// Deliberately position-only: no view direction, no player identity.
pub const Spawnpoint = extern struct {
    pos: [3]f64,
    found: bool = false,
};

/// Shared spawn-search tuning: every generator samples, scores, and caps
/// identically so behavior matches across plugins.
pub const spawn_samples_per_ring: u32 = 8;
pub const spawn_max_ring: u32 = 20;
pub const spawn_ring_step: f64 = 16.0;
/// Upper bound covering the full ring schedule; the host passes smaller
/// `attempts` budgets when it wants cheaper, nearer searches.
pub const spawn_attempt_cap: u32 = (spawn_max_ring + 1) * spawn_samples_per_ring;
pub const spawn_slope_weight: f64 = 64.0;
pub const spawn_ocean_penalty: f64 = 1e9;
pub const spawn_steep_penalty: f64 = 1e6;
pub const spawn_steep_limit: f32 = 1.0;
pub const spawn_water_margin: f32 = 1.0;
/// Hint feet sit this far above the estimated ground top; the host resolves
/// exact feet, so hints only need to land the column scan window.
pub const spawn_hint_clearance: f32 = 2.6;

/// Deterministic disc sample shared by every `propose_spawn`
/// implementation, so all generators expand identically. `radius` is soft:
/// ring 0 samples within `radius` of `center` (exactly `center` when
/// `radius == 0`), later rings grow by powers of two so a `0` radius still
/// means "closest to center" while guaranteeing escape from oceans.
/// Deterministic in `(seed, center, radius, nonce, i)`: per-join variation
/// comes from the host-supplied `nonce`, never from hidden RNG.
pub fn spawnSample(seed: u64, center: [2]f64, radius: f64, nonce: u64, i: u32) [2]f64 {
    var hasher = std.hash.Wyhash.init(seed ^ nonce ^ 0x9e3779b97f4a7c15);
    std.hash.autoHash(&hasher, i);
    const h = hasher.final();
    const frac_low: f64 = @as(f64, @floatFromInt(h & 0xFFFFFFFF)) / 4294967296.0;
    const frac_high: f64 = @as(f64, @floatFromInt(h >> 32)) / 4294967296.0;
    // Rings advance with the sample index so a larger `attempts` budget
    // searches farther, not just denser: ring 12 reaches ~65km, ring 20
    // the whole world. Reach must not be coupled to a CPU cap, or retries
    // re-search the same basin forever.
    const ring = @min(i / spawn_samples_per_ring, spawn_max_ring);
    const extra: f64 = spawn_ring_step * (@exp2(@as(f64, @floatFromInt(ring))) - 1.0);
    const r = radius + extra;
    if (r <= 0) return center;
    // Uniform disc: sqrt distributes area-evenly so near-center candidates
    // win the distance term more often, keeping island worlds clustered.
    const dist = r * @sqrt(frac_low);
    const angle = std.math.tau * frac_high + @as(f64, @floatFromInt(i % spawn_samples_per_ring)) * (std.math.tau / @as(f64, spawn_samples_per_ring));
    return .{ center[0] + @cos(angle) * dist, center[1] + @sin(angle) * dist };
}

/// Analytic column score shared by every `propose_spawn` implementation.
/// `height_above_water` is height minus sea level (or raw height where the
/// generator has no sea); slope is blocks per block. Water/steep columns
/// stay tracked as best-effort so all-ocean seeds still return something.
pub const SpawnScore = struct {
    score: f64,
    wet: bool,
    steep: bool,
};

pub fn scoreSpawnColumn(dist: f64, height_above_water: f32, slope: f32) SpawnScore {
    const wet = height_above_water <= spawn_water_margin;
    const steep = slope >= spawn_steep_limit;
    return .{
        .score = dist + @as(f64, slope) * spawn_slope_weight + (if (wet) spawn_ocean_penalty else 0) + (if (steep) spawn_steep_penalty else 0),
        .wet = wet,
        .steep = steep,
    };
}

/// Shared pick-test-retry loop for heightfield generators: samples the
/// disc schedule, scores each column, tracks the best. `columnHeight`
/// returns the terrain height at world (x, z); `sea_level` gates water.
/// Pure and deterministic; the host re-validates the winner.
pub fn proposeSpawnField(
    seed: u64,
    center: [3]f64,
    radius: f64,
    attempts: u32,
    nonce: u64,
    sea_level: f32,
    context: anytype,
    comptime columnHeight: anytype,
) Spawnpoint {
    var best: Spawnpoint = .{ .pos = .{ 0, 0, 0 }, .found = false };
    var best_score: f64 = std.math.inf(f64);
    var best_good = false;
    const capped = @min(attempts, spawn_attempt_cap);
    for (0..capped) |i| {
        // Cheap analytic test per pick; the host re-validates the winner
        // against real blocks, so misses here only cost retries.
        const sample = spawnSample(seed, .{ center[0], center[2] }, radius, nonce, @intCast(i));
        const sx: f32 = @floatCast(sample[0]);
        const sz: f32 = @floatCast(sample[1]);
        const h = columnHeight(context, sx, sz);
        const hx = columnHeight(context, sx + 2, sz);
        const hz = columnHeight(context, sx, sz + 2);
        const slope = @max(@abs(hx - h), @abs(hz - h)) / 2.0;
        const dx = sample[0] - center[0];
        const dz = sample[1] - center[2];
        const scored = scoreSpawnColumn(@sqrt(dx * dx + dz * dz), h - sea_level, slope);
        if (scored.score < best_score) {
            best_score = scored.score;
            // Top solid block is floor(h); the hint only needs the column.
            best = .{ .pos = .{ sample[0], @floor(h) + spawn_hint_clearance, sample[1] }, .found = true };
            best_good = !scored.wet and !scored.steep;
        }
        // Stop after a full first ring once the tracked best passes.
        if (i >= spawn_samples_per_ring - 1 and best_good) break;
    }
    return best;
}

/// The vtable every generator exports under `api_export_name`.
///
/// The functions use the C calling convention, so aggregate types cross the
/// boundary as pointers. The generator instance is torn down through the
/// `deinit` callback of the `World.ChunkSource` returned by `get_source`, so
/// no separate deinit entry is needed.
pub const GeneratorApi = extern struct {
    info: *const fn () callconv(.c) *const GeneratorInfo,
    create: *const fn (opts: *const CreateOptions, config: *const ConfigTree) callconv(.c) ?*anyopaque,
    get_source: *const fn (instance: *anyopaque) callconv(.c) *const World.ChunkSource,
    /// Number of named presets the generator ships with.
    preset_count: *const fn () callconv(.c) usize,
    /// Name of the preset at `index`. The returned pointer references a static
    /// slice owned by the generator; it stays valid for the life of the library.
    preset_name: *const fn (index: usize) callconv(.c) *const []const u8,
    /// Index of the preset used as the default when no config is supplied.
    preset_default_index: *const fn () callconv(.c) usize,
    /// Builds the config tree for the preset at `index`. All strings are
    /// allocated with the given allocator; the host frees the whole tree with
    /// `generator_api.free`.
    preset_config: *const fn (allocator: *const std.mem.Allocator, index: usize) callconv(.c) ?*ConfigTree,
    /// Returns null if the bytes are not a valid config; the host then falls
    /// back to the default preset.
    config_from_zon: *const fn (allocator: *const std.mem.Allocator, bytes: [*]const u8, bytes_len: usize) callconv(.c) ?*ConfigTree,
    /// Returns null on failure. Fills in unspecified seeds (params with `Spec.is_seed`, value 0) and
    /// must be called before `create` so the chosen seeds can be persisted.
    config_set_seeds: *const fn (io: *const std.Io, config: *ConfigTree) callconv(.c) void,
    /// Proposes a spawn position near `center`. `radius` is soft (0 means
    /// "closest to center"): the generator samples with `spawnSample` and
    /// roams beyond `radius` when nothing passes. `attempts` bounds the
    /// inner analytic loop; `nonce` varies per call so joins spread without
    /// player identity. Pure: no chunk I/O, deterministic in its inputs.
    /// The returned Y is only a hint — erosion, caves, and structures are
    /// invisible to the generator, so the host scans the column to resolve
    /// exact feet. The host must call this when present; `found == false`
    /// is a hard spawn failure. Returned by value: sound because both
    /// sides share one compiler, the same guarantee the vtable relies on.
    propose_spawn: *const fn (
        instance: *anyopaque,
        center: *const [3]f64,
        radius: f64,
        attempts: u32,
        nonce: u64,
    ) callconv(.c) Spawnpoint,
};

pub const api_export_name = "generator_api";

/// Config tree support: shared by the host (free, clone, eql, emitZon) and by
/// the generators (fromStruct, fromTree reflection).
/// Frees a config tree. Every string in the tree is owned by the allocator
/// that created it, so this walks the whole tree.
pub fn free(allocator: std.mem.Allocator, tree: *ConfigTree) void {
    freeGroup(allocator, tree);
    allocator.destroy(tree);
}

/// Deep copy of a config tree; all strings are duplicated.
pub fn clone(allocator: std.mem.Allocator, tree: *const ConfigTree) error{OutOfMemory}!*ConfigTree {
    const new = try allocator.create(ConfigTree);
    errdefer allocator.destroy(new);
    new.params = try cloneParams(allocator, tree.params);
    return new;
}

/// Content equality; used for change detection. Pointer fields (array
/// element templates) are compared by pointee, not identity.
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

/// Adds a new item to an array param, cloned from the element template.
pub fn arrayAdd(allocator: std.mem.Allocator, array: *Array) error{OutOfMemory}!void {
    const old_len = array.items.len;
    array.items = try allocator.realloc(array.items, old_len + 1);
    errdefer array.items = allocator.realloc(array.items, old_len) catch array.items[0..old_len];
    array.items[old_len] = try cloneParam(allocator, array.element);
}

/// Removes an item from an array param, freeing it.
pub fn arrayRemove(allocator: std.mem.Allocator, array: *Array, index: usize) void {
    std.debug.assert(index < array.items.len);
    freeParam(allocator, &array.items[index]);
    std.mem.copyForwards(Param, array.items[index..], array.items[index + 1 ..]);
    array.items = allocator.realloc(array.items, array.items.len - 1) catch return;
}

/// Emits the tree as ZON, in the same format the generators parse back with
/// `std.zon.parse`.
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
    const s = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    if (std.mem.indexOfAny(u8, s, ".eE") == null) {
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

/// Builds a config tree from a struct via comptime reflection. Unhandled
/// field types are skipped.
pub fn fromStruct(comptime T: type, allocator: std.mem.Allocator, value: *const T, comptime field_specs: anytype) error{OutOfMemory}!*ConfigTree {
    const tree = try allocator.create(ConfigTree);
    errdefer allocator.destroy(tree);
    tree.params = try paramsFromStruct(T, allocator, value, field_specs);
    return tree;
}

/// Applies a config tree back onto a struct. Params missing from the tree or
/// mismatching the field type leave the field at its current value.
pub fn fromTree(comptime T: type, allocator: std.mem.Allocator, tree: *const ConfigTree, out: *T, comptime field_specs: anytype) error{OutOfMemory}!void {
    inline for (std.meta.fields(T)) |f| {
        if (findParam(tree, f.name)) |param| {
            _ = try applyField(f.type, allocator, &@field(out, f.name), param, fieldSpec(field_specs, f.name), field_specs);
        }
    }
}

fn paramsFromStruct(comptime T: type, allocator: std.mem.Allocator, value: *const T, comptime field_specs: anytype) error{OutOfMemory}![]Param {
    var list: std.ArrayListUnmanaged(Param) = .empty;
    errdefer {
        for (list.items) |*p| freeParam(allocator, p);
        list.deinit(allocator);
    }
    inline for (std.meta.fields(T)) |f| {
        const maybe_param = try paramFromTypeValue(f.type, allocator, f.name, @field(value, f.name), fieldSpec(field_specs, f.name), field_specs);
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
    const names: [std.meta.fields(T).len][]const u8 = blk: {
        var arr: [std.meta.fields(T).len][]const u8 = undefined;
        inline for (std.meta.fields(T), 0..) |f, i| arr[i] = f.name;
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
        .@"enum" => return .{ .choice = @intFromEnum(value) },
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

fn applyField(comptime T: type, allocator: std.mem.Allocator, field_ptr: *T, param: *const Param, comptime spec: Spec, comptime field_specs: anytype) error{OutOfMemory}!bool {
    if (spec.skip) return false;
    switch (@typeInfo(T)) {
        .float => {
            if (param.value != .f32) return false;
            field_ptr.* = param.value.f32;
        },
        .int => {
            const source: i128 = switch (param.value) {
                .i32 => |v| v,
                .u32 => |v| v,
                .u64 => |v| @as(i128, @intCast(v)),
                else => return false,
            };
            field_ptr.* = std.math.cast(T, source) orelse return false;
        },
        .bool => {
            if (param.value != .bool) return false;
            field_ptr.* = param.value.bool;
        },
        .@"enum" => {
            if (param.value != .choice) return false;
            if (param.value.choice >= std.meta.fields(T).len) return false;
            field_ptr.* = @enumFromInt(param.value.choice);
        },
        .optional => |info| {
            if (param.value != .u64) return false;
            if (@typeInfo(info.child) != .int) return false;
            if (param.value.u64 == 0) {
                field_ptr.* = null;
            } else {
                field_ptr.* = std.math.cast(info.child, param.value.u64) orelse return false;
            }
        },
        .@"struct" => {
            if (param.value != .group) return false;
            inline for (std.meta.fields(T)) |f| {
                if (findParam(&param.value.group, f.name)) |child| {
                    _ = try applyField(f.type, allocator, &@field(field_ptr, f.name), child, fieldSpec(field_specs, f.name), field_specs);
                }
            }
        },
        .pointer => |info| {
            if (param.value != .array) return false;
            if (info.size != .slice) return false;
            if (@typeInfo(info.child) != .@"struct") return false;
            const Child = info.child;
            const items = param.value.array.items;
            const new_items = try allocator.alloc(Child, items.len);
            errdefer allocator.free(new_items);
            for (new_items) |*item| item.* = .{};
            for (items, new_items) |*item, *dst| {
                if (item.value == .group) {
                    _ = try applyField(Child, allocator, dst, item, .{}, field_specs);
                }
            }
            field_ptr.* = new_items;
        },
        else => return false,
    }
    return true;
}

fn findParam(group: *const ConfigTree, name: []const u8) ?*const Param {
    for (group.params) |*param| {
        if (std.mem.eql(u8, param.name, name)) return param;
    }
    return null;
}

fn dupeSpec(allocator: std.mem.Allocator, spec: *const Spec) error{OutOfMemory}!Spec {
    return .{
        .min = spec.min,
        .max = spec.max,
        .step = spec.step,
        .entries = try dupeEntries(allocator, spec.entries),
        .is_seed = spec.is_seed,
        .skip = spec.skip,
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
    const items = try allocator.alloc(Param, src.items.len);
    var count: usize = 0;
    errdefer {
        for (items[0..count]) |*p| freeParam(allocator, p);
        allocator.free(items);
    }
    for (src.items, items) |*s, *d| {
        d.* = try cloneParam(allocator, s);
        count += 1;
    }
    return .{ .element = element, .items = items };
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

test "apiCompatible enforces semver" {
    // At 0.0.0 (pre-1.0) only an exact match loads.
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
