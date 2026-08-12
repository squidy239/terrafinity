const std = @import("std");

const World = @import("../World.zig");

/// Shared interface between the terrafinity host and generator shared
/// libraries. Both sides are compiled by the same `zig build` with the same
/// compiler, so every type here has identical layout across the DLL boundary.
pub const ApiVersion: u32 = 2;

pub const GeneratorInfo = struct {
    name: []const u8,
    description: []const u8,
    version: u32,
    api_version: u32,
};

pub const CreateOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Budget for generator caches such as the terrain height cache.
    max_cache_bytes: u64,
};

/// The value of a single config parameter. Config trees are plain data: all
/// strings are allocated with the allocator that created the tree, so the
/// host can free, clone, and serialize them without knowing the generator's
/// concrete config type.
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
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
    entries: []const []const u8 = &.{},
    /// The host fills params with this flag set via `generator_config_set_seeds`.
    is_seed: bool = false,
    /// Excludes the field from the config tree entirely.
    skip: bool = false,
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
/// every struct at any nesting depth that has a field with that name.
fn fieldSpec(comptime field_specs: anytype, comptime name: []const u8) Spec {
    if (!@hasField(@TypeOf(field_specs), name)) return .{};
    const s = @field(field_specs, name);
    const is_spec = @hasField(@TypeOf(s), "min") or @hasField(@TypeOf(s), "max") or
        @hasField(@TypeOf(s), "step") or @hasField(@TypeOf(s), "entries") or
        @hasField(@TypeOf(s), "is_seed") or @hasField(@TypeOf(s), "skip");
    if (!is_spec) return .{};
    return .{
        .min = if (@hasField(@TypeOf(s), "min")) s.min else null,
        .max = if (@hasField(@TypeOf(s), "max")) s.max else null,
        .step = if (@hasField(@TypeOf(s), "step")) s.step else null,
        .entries = if (@hasField(@TypeOf(s), "entries")) s.entries else &.{},
        .is_seed = if (@hasField(@TypeOf(s), "is_seed")) s.is_seed else false,
        .skip = if (@hasField(@TypeOf(s), "skip")) s.skip else false,
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

test "emitZon output" {
    const allocator = std.testing.allocator;
    var config: TestConfig = .{ .items = &.{} };

    const tree = try fromStruct(TestConfig, allocator, &config, test_specs);
    defer free(allocator, tree);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try emitZon(&writer, tree);

    const expected =
        \\.{
        \\.enabled = true,
        \\.scale = 0.5,
        \\.count = 3,
        \\.seed = 0,
        \\.mode = .b,
        \\.inner = .{
        \\.freq = 0.1,
        \\.octaves = 4,
        \\},
        \\.items = .{
        \\},
        \\}
    ;
    try std.testing.expectEqualStrings(expected, std.Io.Writer.buffered(&writer));
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
