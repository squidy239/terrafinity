const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "voxelgame",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/Client.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
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
    //  const cache = b.dependency("cache", .{
    //       .target = target,
    //       .optimize = optimize,
    // });

    //    exe.root_module.addImport("cache", cache.module("cache"));
    var Entitys = b.addModule("Entity", .{
        .root_source_file = b.path("src/world/Entity.zig"),
    });
    exe.root_module.addImport("Entity", Entitys);

    const ThreadPool = b.addModule("ThreadPool", .{
        .root_source_file = b.path("src/libs/ThreadPool.zig"),
    });
    exe.root_module.addImport("ThreadPool", ThreadPool);

    const obj_mod = b.dependency("obj", .{ .target = target, .optimize = optimize }).module("obj");
    exe.root_module.addImport("obj", obj_mod);

    const gl_bindings = @import("zigglgen").generateBindingsModule(b, .{
        .api = .gl,
        .version = .@"4.6",
        .profile = .core,
    });
    exe.root_module.addImport("gl", gl_bindings);

    const zigimg_dependency = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zigimg", zigimg_dependency.module("zigimg"));

    const EntityTypes = b.addModule("EntityTypes", .{
        .root_source_file = b.path("src/world/EntityTypes.zig"),
        .imports = &.{
            .{ .name = "Entity", .module = Entitys },
            .{ .name = "obj", .module = obj_mod },
            .{ .name = "gl", .module = gl_bindings },
        },
    });

    Entitys.addImport("EntityTypes", EntityTypes);
    exe.root_module.addImport("EntityTypes", EntityTypes);

    const Block = b.addModule("Block", .{
        .root_source_file = b.path("src/world/Blocks.zig"),
    });
    exe.root_module.addImport("Block", Block);

    const ConcurrentHashMap = b.addModule("ConcurrentHashMap", .{ .root_source_file = b.path("src/libs/ConcurrentHashMap.zig") });
    exe.root_module.addImport("ConcurrentHashMap", ConcurrentHashMap);

    const Interpolation = b.addModule("Interpolation", .{ .root_source_file = b.path("src/libs/Interpolation.zig") });
    exe.root_module.addImport("Interpolation", Interpolation);

    const Cache = b.addModule("Cache", .{ .root_source_file = b.path("src/libs/Cache.zig"), .imports = &.{
        .{ .name = "ConcurrentHashMap", .module = ConcurrentHashMap },
    } });
    exe.root_module.addImport("Cache", Cache);

    const Chunk = b.addModule("Chunk", .{ .root_source_file = b.path("src/world/Chunk.zig"), .imports = &.{ .{ .name = "Cache", .module = Cache }, .{ .name = "Block", .module = Block }, .{ .name = "Interpolation", .module = Interpolation }, .{
        .name = "ztracy",
        .module = ztracy.module("root"),
    } } });
    exe.root_module.addImport("Chunk", Chunk);

    const ThreadPriority = b.addModule("ThreadPriority", .{ .root_source_file = b.path("src/libs/ThreadPriority.zig") });
    exe.root_module.addImport("ThreadPriority", ThreadPriority);

    const world_module = b.addModule("World", .{
        .root_source_file = b.path("src/world/World.zig"),
        .imports = &.{ .{ .name = "Chunk", .module = Chunk }, .{ .name = "Block", .module = Block }, .{ .name = "Entity", .module = Entitys }, .{ .name = "ConcurrentHashMap", .module = ConcurrentHashMap }, .{ .name = "Cache", .module = Cache }, .{
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

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zglfw", zglfw.module("root"));

    if (target.result.os.tag != .emscripten) {
        exe.linkLibrary(zglfw.artifact("glfw"));
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
