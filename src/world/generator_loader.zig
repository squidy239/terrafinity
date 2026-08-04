const std = @import("std");

const generator_api = @import("generators/generator_api.zig");
const World = @import("World.zig");

pub const ConfigTree = generator_api.ConfigTree;

/// A loaded generator shared library and its resolved exports.
pub const Generator = struct {
    lib: std.DynLib,
    info: generator_api.GeneratorInfo,
    api: *const generator_api.GeneratorApi,

    pub fn deinit(self: *Generator) void {
        self.lib.close();
        self.* = undefined;
    }

    /// Path of the config file this generator's tree is stored under,
    /// `<lowercased name>_generator.zon` inside the world's config directory.
    pub fn configPath(self: *const Generator, allocator: std.mem.Allocator, config_dir: []const u8) ![]const u8 {
        const lower_name = try allocator.dupe(u8, self.info.name);
        defer allocator.free(lower_name);
        for (lower_name) |*c| c.* = std.ascii.toLower(c.*);
        return std.fmt.allocPrint(allocator, "{s}/{s}_generator.zon", .{ config_dir, lower_name });
    }

    /// Loads the generator's config tree from disk, falling back to defaults
    /// when the file is missing or unparseable.
    pub fn loadConfig(self: *Generator, allocator: std.mem.Allocator, io: std.Io, config_dir: []const u8) !*ConfigTree {
        const path = try self.configPath(allocator, config_dir);
        defer allocator.free(path);

        const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .lock = .shared }) catch |err| switch (err) {
            error.FileNotFound => return self.api.config_default(&allocator) orelse return error.OutOfMemory,
            else => return err,
        };
        defer file.close(io);

        const stat = try file.stat(io);
        const bytes = try allocator.alloc(u8, stat.size + 1);
        defer allocator.free(bytes);
        var buffer: [1024]u8 = undefined;
        var reader = file.reader(io, &buffer);
        try reader.interface.readSliceAll(bytes[0..stat.size]);
        bytes[stat.size] = 0;

        if (self.api.config_from_zon(&allocator, bytes[0..stat.size].ptr, stat.size)) |tree| return tree;
        std.log.warn("generator {s}: invalid config, using defaults", .{self.info.name});
        return self.api.config_default(&allocator) orelse return error.OutOfMemory;
    }

    pub fn saveConfig(self: *Generator, allocator: std.mem.Allocator, io: std.Io, config_dir: []const u8, tree: *ConfigTree) !void {
        const path = try self.configPath(allocator, config_dir);
        defer allocator.free(path);

        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .lock = .exclusive });
        defer file.close(io);

        var buffer: [512]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try generator_api.emitZon(&writer.interface, tree);
        try writer.end();
    }
};

/// Loads every generator shared library found in `dir`.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    generators: std.ArrayListUnmanaged(Generator) = .empty,

    /// A missing directory yields an empty registry; individual libraries
    /// that fail to load are skipped with a logged error.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !Registry {
        var registry: Registry = .{ .allocator = allocator };
        errdefer registry.deinit(io);

        var dir_handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return registry,
            else => return err,
        };
        defer dir_handle.close(io);

        var it = dir_handle.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const path = try std.fs.path.join(allocator, &.{ dir, entry.name });
            defer allocator.free(path);
            registry.loadGenerator(io, path) catch |err|
                std.log.err("failed to load generator {s}: {s}", .{ path, @errorName(err) });
        }
        return registry;
    }

    fn loadGenerator(self: *Registry, io: std.Io, path: []const u8) !void {
        _ = io;
        var lib = try std.DynLib.open(path);
        errdefer lib.close();

        const api = lib.lookup(*const generator_api.GeneratorApi, generator_api.api_export_name) orelse
            return error.MissingExport;
        const info = api.info().*;
        if (info.api_version != generator_api.ApiVersion) return error.ApiVersionMismatch;

        const generator = Generator{
            .lib = lib,
            .info = info,
            .api = api,
        };
        try self.generators.append(self.allocator, generator);
        std.log.info("loaded generator {s} v{d}", .{ info.name, info.version });
    }

    pub fn deinit(self: *Registry, io: std.Io) void {
        _ = io;
        for (self.generators.items) |*generator| generator.deinit();
        self.generators.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn findByName(self: *Registry, name: []const u8) ?*Generator {
        for (self.generators.items) |*generator| {
            if (std.mem.eql(u8, generator.info.name, name)) return generator;
        }
        return null;
    }
};

/// A generator instance together with the config tree it was created from.
/// The host keeps the tree alive so it can be edited and re-applied. The
/// underlying generator is torn down through the `deinit` callback of
/// `source`, which `World.deinit` invokes.
pub const GeneratorInstance = struct {
    generator: *Generator,
    instance: *anyopaque,
    config: *ConfigTree,
    allocator: std.mem.Allocator,
    source: World.ChunkSource,
    /// Path to the world's config directory, used for config file I/O.
    config_dir: []const u8,

    /// Frees the config tree and path. Does not deinit the generator itself;
    /// that is the world's responsibility through `chunk_sources`.
    pub fn deinit(self: *GeneratorInstance) void {
        generator_api.free(self.allocator, self.config);
        self.allocator.free(self.config_dir);
        self.* = undefined;
    }

    pub fn saveConfig(self: *GeneratorInstance, io: std.Io) !void {
        try self.generator.saveConfig(self.allocator, io, self.config_dir, self.config);
    }
};
