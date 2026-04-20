const std = @import("std");

pub fn build(b: *std.Build) void {
    // Build options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Tracy profiling options
    const tracy_options = .{
        .enable_ztracy = b.option(bool, "enable_ztracy", "Enable Tracy profile markers") orelse false,
        .enable_fibers = b.option(bool, "enable_fibers", "Enable Tracy fiber support") orelse false,
        .on_demand = b.option(bool, "on_demand", "Build tracy with TRACY_ON_DEMAND") orelse true,
    };

    // Create root module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Set up dependencies and imports
    setupDependencies(b, root_module, target, optimize, tracy_options);

    // Create executable
    var exe = b.addExecutable(.{
        .name = "terrafinity",
        .root_module = root_module,
        .use_llvm = true,
        .use_lld = false,
    });

    // Link libraries
    const ztracy = b.dependency("ztracy", .{
        .enable_ztracy = tracy_options.enable_ztracy,
        .enable_fibers = tracy_options.enable_fibers,
        .on_demand = tracy_options.on_demand,
        .optimize = optimize,
    });
    exe.root_module.linkLibrary(ztracy.artifact("tracy"));

    const check_step = b.step("check", "");
    check_step.dependOn(&b.addTest(.{
        .root_module = root_module,
    }).step);

    // Install and run steps
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Test step
    const tests = b.addTest(.{
        .root_module = root_module,
        .use_llvm = true,
        .use_lld = false,
    });
    b.installArtifact(tests);

    const run_test = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test.step);
}

fn setupDependencies(
    b: *std.Build,
    root_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tracy_options: anytype,
) void {
    // Tracy profiling
    const ztracy = b.dependency("ztracy", .{
        .enable_ztracy = tracy_options.enable_ztracy,
        .enable_fibers = tracy_options.enable_fibers,
        .on_demand = tracy_options.on_demand,
        .optimize = optimize,
    });
    root_module.addImport("ztracy", ztracy.module("root"));

    // RocksDB (requires: sudo apt-get install librocksdb-dev)
    const dep_rocksdb = b.dependency("rocksdb", .{
        .enable_zstd = true,
        .enable_lz4 = true,
        .optimize = optimize,
    });
    root_module.addImport("rocksdb", dep_rocksdb.module("bindings"));

    // SDL3
    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("sdl3", sdl3.module("sdl3"));

    // ConcurrentHashMap
    const ConcurrentHashMap = b.addModule("ConcurrentHashMap", .{
        .root_source_file = b.path("src/libs/ConcurrentHashMap.zig"),
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztracy", .module = ztracy.module("root") },
        },
    });
    root_module.addImport("ConcurrentHashMap", ConcurrentHashMap);

    // Cache
    const Cache = b.addModule("Cache", .{
        .root_source_file = b.path("src/libs/Cache.zig"),
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ConcurrentHashMap", .module = ConcurrentHashMap },
        },
    });
    root_module.addImport("Cache", Cache);

    // OBJ parser
    const obj_mod = b.dependency("obj", .{
        .target = target,
        .optimize = optimize,
    }).module("obj");
    root_module.addImport("obj", obj_mod);

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .freetype = false,
        .@"tree-sitter" = false,
        .backend = .sdl3,
        .@"log-error-trace" = false,
    });
    root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    root_module.addImport("sdl3-backend", dvui_dep.module("sdl3"));

    // OpenGL bindings
    const gl_bindings = @import("zigglgen").generateBindingsModule(b, .{
        .api = .gl,
        .version = .@"4.5",
        .profile = .core,
    });
    root_module.addImport("gl", gl_bindings);

    // Image library
    const zigimg_dependency = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("zigimg", zigimg_dependency.module("zigimg"));

    // Math library
    const zm = b.dependency("zm", .{
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("zm", zm.module("zm"));
}
