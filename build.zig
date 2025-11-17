const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    var exe = b.addExecutable(.{
        .name = "terrafinity",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/App.zig"),
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

    const check = b.option(bool, "check", "check if the game compiles") orelse false;
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
    //
    const stb_truetype_bindings = b.addTranslateC(.{
        .root_source_file = b.path("src/libs/gui/text/stb_truetype.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const stb_truetype_object = b.addObject(.{
        .name = "stb_truetype",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    stb_truetype_object.addCSourceFile(.{
        .file = b.path("src/libs/gui/text/stb_truetype.c"),
    });
    exe.addObject(stb_truetype_object);
    const ThreadPriority = b.addModule("ThreadPriority", .{ .root_source_file = b.path("src/libs/ThreadPriority.zig") });
    exe.root_module.addImport("ThreadPriority", ThreadPriority);

    //    exe.root_module.addImport("cache", cache.module("cache"));
    var Entitys = b.addModule("Entity", .{
        .root_source_file = b.path("src/world/Entity.zig"),
        .optimize = optimize,
    });

    exe.root_module.addImport("Entity", Entitys);
    const ConcurrentQueue = b.dependency("ConcurrentQueue", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("ConcurrentQueue", ConcurrentQueue.module("ConcurrentQueue"));

    const ThreadPool = b.addModule("ThreadPool", .{ .root_source_file = b.path("src/libs/ThreadPool.zig"), .optimize = optimize, .imports = &.{
        .{ .name = "ConcurrentQueue", .module = ConcurrentQueue.module("ConcurrentQueue") },
        .{ .name = "ThreadPriority", .module = ThreadPriority },
    } });
    exe.root_module.addImport("ThreadPool", ThreadPool);

    const obj_mod = b.dependency("obj", .{ .target = target, .optimize = optimize }).module("obj");
    exe.root_module.addImport("obj", obj_mod);

    const gl_bindings = @import("zigglgen").generateBindingsModule(b, .{
        .api = .gl,
        .version = .@"4.1",
        .profile = .core,
    });
    exe.root_module.addImport("gl", gl_bindings);

    const zigimg_dependency = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zigimg", zigimg_dependency.module("zigimg"));

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zglfw", zglfw.module("root"));

    const gui = b.addModule("gui", .{
        .root_source_file = b.path("src/libs/gui/gui.zig"),
        .optimize = optimize,
        .imports = &.{
            .{ .name = "TrueType", .module = stb_truetype_bindings.createModule() },
            .{ .name = "gl", .module = gl_bindings },
            .{ .name = "glfw", .module = zglfw.module("root") },
        },
    });

    exe.root_module.addImport("gui", gui);

    const EntityTypes = b.addModule("EntityTypes", .{
        .root_source_file = b.path("src/world/EntityTypes.zig"),
        .optimize = optimize,
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
        .optimize = optimize,
    });
    exe.root_module.addImport("Block", Block);

    const ConcurrentHashMap = b.addModule("ConcurrentHashMap", .{
        .root_source_file = b.path("src/libs/ConcurrentHashMap.zig"),
        .optimize = optimize,
        .imports = &.{.{ .name = "ztracy", .module = ztracy.module("root") }},
    });
    exe.root_module.addImport("ConcurrentHashMap", ConcurrentHashMap);

    const Interpolation = b.addModule("Interpolation", .{ .root_source_file = b.path("src/libs/Interpolation.zig") });
    exe.root_module.addImport("Interpolation", Interpolation);

    const Cache = b.addModule(
        "Cache",
        .{
            .root_source_file = b.path("src/libs/Cache.zig"),
            .imports = &.{
                .{ .name = "ConcurrentHashMap", .module = ConcurrentHashMap },
            },
            .optimize = optimize,
        },
    );
    exe.root_module.addImport("Cache", Cache);

    const Chunk = b.addModule("Chunk", .{
        .root_source_file = b.path("src/world/Chunk.zig"),
        .imports = &.{
            .{ .name = "Cache", .module = Cache }, .{ .name = "Block", .module = Block }, .{ .name = "Interpolation", .module = Interpolation }, .{
                .name = "ztracy",
                .module = ztracy.module("root"),
            },
        },
        .optimize = optimize,
    });
    exe.root_module.addImport("Chunk", Chunk);

    const world_module = b.addModule("World", .{
        .root_source_file = b.path("src/world/World.zig"),
        .imports = &.{ .{ .name = "Chunk", .module = Chunk }, .{ .name = "Block", .module = Block }, .{ .name = "Entity", .module = Entitys }, .{ .name = "ConcurrentHashMap", .module = ConcurrentHashMap }, .{ .name = "Cache", .module = Cache }, .{
            .name = "ztracy",
            .module = ztracy.module("root"),
        } },
        .optimize = optimize,
    });
    exe.root_module.addImport("World", world_module);

    const zm = b.dependency("zm", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zm", zm.module("zm"));

    if (target.result.os.tag != .emscripten) {
        exe.linkLibrary(zglfw.artifact("glfw"));
    }

    if (check) { //TODO redo this whole file
        exe.use_llvm = false;
        const checkStep = b.step("check", "Check if the game compiles");
        checkStep.dependOn(&exe.step);
        return;
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
