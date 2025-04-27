const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const runGame = true;
    const clientservertoggle = true;
    //std.debug.assert(!(isserver and isclient));
    const exe = b.addExecutable(.{
        .name = "voxelgame",
        .root_source_file = if (clientservertoggle and !runGame) b.path("src/server/Server.zig") else if (!clientservertoggle and !runGame) b.path("src/client/testClient.zig") else b.path("src/client/Client.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = .{
        .enable_ztracy = b.option(
            bool,
            "enable_ztracy",
            "Enable Tracy profile markers",
        ) orelse false,
        .enable_fibers = b.option(
            bool,
            "enable_fibers",
            "Enable Tracy fiber support",
        ) orelse false,
        .on_demand = b.option(
            bool,
            "on_demand",
            "Build tracy with TRACY_ON_DEMAND",
        ) orelse false,
    };

    const ztracy = b.dependency("ztracy", .{
        .enable_ztracy = options.enable_ztracy,
        .enable_fibers = options.enable_fibers,
        .on_demand = options.on_demand,
        .optimize = optimize,
    });
    exe.root_module.addImport("ztracy", ztracy.module("root"));

    exe.linkLibrary(ztracy.artifact("tracy"));

    // linux dependancy: sudo apt install libx11-dev
    const cache = b.dependency("cache", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("cache", cache.module("cache"));
    const Entitys = b.addModule("Entity", .{
        .root_source_file = b.path("src/world/Entity.zig"),
    });
    exe.root_module.addImport("Entity", Entitys);

    const EntityTypes = b.addModule("EntityTypes", .{
        .root_source_file = b.path("src/world/EntityTypes.zig"),
    });
    exe.root_module.addImport("EntityTypes", EntityTypes);

    const Block = b.addModule("Block", .{
        .root_source_file = b.path("src/world/Blocks.zig"),
    });
    exe.root_module.addImport("Block", Block);

    const Chunk = b.addModule("Chunk", .{ .root_source_file = b.path("src/world/Chunk.zig"), .imports = &.{ .{ .name = "cache", .module = cache.module("cache") }, .{ .name = "Block", .module = Block }, .{
        .name = "ztracy",
        .module = ztracy.module("root"),
    } } });
    exe.root_module.addImport("Chunk", Chunk);

    const ConcurrentHashMap = b.addModule("ConcurrentHashMap", .{ .root_source_file = b.path("src/libs/ConcurrentHashMap.zig") });
    exe.root_module.addImport("ConcurrentHashMap", ConcurrentHashMap);

    const Requests = b.addModule("Requests", .{ .root_source_file = b.path("src/protocol/Requests.zig"), .imports = &.{ .{ .name = "Entitys", .module = Entitys }, .{ .name = "Chunk", .module = Chunk } } });
    exe.root_module.addImport("Requests", Requests);

    const world_module = b.addModule("World", .{
        .root_source_file = b.path("src/world/World.zig"),
        .imports = &.{ .{ .name = "Chunk", .module = Chunk }, .{ .name = "Entity", .module = Entitys }, .{ .name = "ConcurrentHashMap", .module = ConcurrentHashMap }, .{ .name = "cache", .module = cache.module("cache") }, .{
            .name = "ztracy",
            .module = ztracy.module("root"),
        } },
    });
    exe.root_module.addImport("World", world_module);

    const zm = b.dependency("zm", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zm", zm.module("zm"));

    const zudp = b.dependency("zudp", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zudp", zudp.module("zudp"));

    const Network = b.addModule("Network", .{
        .root_source_file = b.path("src/protocol/Network.zig"),
        .imports = &.{
            .{ .name = "Requests", .module = Requests },
            .{ .name = "zudp", .module = zudp.module("zudp") },
        },
    });
    exe.root_module.addImport("Network", Network);

    const zglfw = b.dependency("zglfw", .{
        .optimize = std.builtin.OptimizeMode.ReleaseSafe,
    });
    exe.root_module.addImport("zglfw", zglfw.module("root"));

    if (target.result.os.tag != .emscripten) {
        exe.linkLibrary(zglfw.artifact("glfw"));
    }

    const gl_bindings = @import("zigglgen").generateBindingsModule(b, .{
        .api = .gl,
        .version = .@"4.1",
        .profile = .core,
    });
    exe.root_module.addImport("gl", gl_bindings);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
