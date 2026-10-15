const std = @import("std");

/// Parses a zon file into `T` and ignores unknown fields.
pub fn loadZon(comptime T: type, io: std.Io, file: std.Io.File, temp_allocator: std.mem.Allocator, allocator: std.mem.Allocator) !T {
    var buf: [1024]u8 = undefined;
    const stat = try file.stat(io);
    var reader = file.reader(io, &buf);
    const slice = try temp_allocator.alloc(u8, stat.size + 1);
    defer temp_allocator.free(slice);
    try reader.interface.readSliceAll(slice[0..stat.size]);
    slice[stat.size] = 0;
    @setEvalBranchQuota(100000000);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(T, .{
        .gpa = temp_allocator,
        .arena = allocator,
        .source = slice[0..stat.size :0],
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| {
        if (err == error.ParseZon) diagnostics.log(@typeName(T));
        return err;
    };
}

/// Serializes `value` as zon into `sub_path`, replacing the file under an exclusive lock.
pub fn saveZon(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, value: anytype) !void {
    const file = try dir.createFile(io, sub_path, .{ .lock = .exclusive });
    defer file.close(io);
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try std.zon.stringify.serialize(value, .{}, &writer.interface);
    try writer.end();
}

pub const PackDir = struct {
    path: []u8,
    dir: std.Io.Dir,
    is_default: bool,
};

/// Opens a subdirectory of the selected texture pack, creating it for the built-in
/// `default` pack so its contents can be authored in place. The returned `path`
/// must be freed by the caller.
pub fn openPackDir(io: std.Io, allocator: std.mem.Allocator, selected_pack: []const u8, comptime subdir: []const u8) !PackDir {
    const pack_path = try allocator.print("packs/{s}/{s}/", .{ selected_pack, subdir });
    errdefer allocator.free(pack_path);
    const is_default = std.mem.eql(u8, selected_pack, "default");
    const dir = if (is_default)
        try std.Io.Dir.cwd().createDirPathOpen(io, pack_path, .{ .open_options = .{ .iterate = true } })
    else
        try std.Io.Dir.cwd().openDir(io, pack_path, .{ .iterate = true });
    return .{ .path = pack_path, .dir = dir, .is_default = is_default };
}

/// Joins the fields of `enums` into one exhaustive enum backed by `Tag`, numbering
/// the values sequentially in argument order. A name in more than one input fails
/// to compile.
pub fn joinEnums(comptime Tag: type, comptime enums: []const type) type {
    return comptime blk: {
        var total: usize = 0;
        for (enums) |E| total += @typeInfo(E).@"enum".field_names.len;

        var names: [total][]const u8 = undefined;
        var values: [total]Tag = undefined;
        var i: usize = 0;
        for (enums) |E| {
            for (@typeInfo(E).@"enum".field_names) |name| {
                names[i] = name;
                values[i] = @intCast(i);
                i += 1;
            }
        }
        break :blk @Enum(Tag, .exhaustive, &names, &values);
    };
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
