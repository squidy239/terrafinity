const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sanitize = b.option(bool, "sanitize_thread", "Enable thread sanitizer") orelse null;
    const test_play = b.option(bool, "test_play", "Run test play") orelse null;

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize,
    });

    setupDependencies(b, root_module, target, optimize);

    const exe = b.addExecutable(.{
        .name = "terrafinity",
        .root_module = root_module,
        .use_llvm = true,
    });
    var options: *std.Build.Step.Options = .create(b);
    options.addOption(bool, "test_play", test_play orelse false);
    exe.root_module.addOptions("options", options);
    b.installArtifact(exe);

    // Ephor static analysis
    const ephor_dep = b.dependency("ephor", .{ .target = target, .optimize = .ReleaseSafe });
    const ephor_artifact = ephor_dep.artifact("ephor");
    const ephor_cmd = b.addRunArtifact(ephor_artifact);
    if (b.args) |args| {
        ephor_cmd.addArgs(args);
    }
    const ephor_step = b.step("ephor", "Run ephor static analysis");
    ephor_step.dependOn(&ephor_cmd.step);

    // Ephor upgrade
    const ephor_upgrade_cmd = b.addRunArtifact(ephor_artifact);
    ephor_upgrade_cmd.addArgs(&.{"upgrade"});
    const ephor_upgrade_step = b.step("ephor-upgrade", "Upgrade ephor to latest version");
    ephor_upgrade_step.dependOn(&ephor_upgrade_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = root_module,
        .use_llvm = true,
    });
    tests.root_module.addCSourceFile(.{
        .file = b.path("sanitizer_stubs.c"),
        .flags = &.{"-fno-sanitize-coverage=trace-cmp,trace-div,trace-gep,trace-pc,trace-pc-guard,indirect-calls"},
    });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addInstallArtifact(tests, .{}).step);
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn setupDependencies(
    b: *std.Build,
    root_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const dep_rocksdb = b.dependency("rocksdb", .{
        .enable_zstd = true,
        .enable_lz4 = true,
        .optimize = .ReleaseFast,
    });
    const rocksdb_mod = dep_rocksdb.module("bindings");
    rocksdb_mod.single_threaded = false;
    rocksdb_mod.sanitize_thread = false;
    root_module.addImport("rocksdb", rocksdb_mod);

    const ConcurrentHashMap = b.addModule("ConcurrentHashMap", .{
        .root_source_file = b.path("src/libs/ConcurrentHashMap.zig"),
        .optimize = optimize,
    });
    root_module.addImport("ConcurrentHashMap", ConcurrentHashMap);

    const Cache = b.addModule("Cache", .{
        .root_source_file = b.path("src/libs/Cache.zig"),
        .optimize = optimize,
    });
    root_module.addImport("Cache", Cache);

    const obj_mod = b.dependency("obj", .{
        .target = target,
        .optimize = optimize,
    }).module("obj");
    root_module.addImport("obj", obj_mod);

    // Allow the user to enable or disable Tracy support with a build flag
    const tracy_enabled = b.option(
        bool,
        "tracy",
        "Build with Tracy support.",
    ) orelse false;

    // Get the Tracy dependency
    const tracy = b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
    });

    // Make Tracy available as an import
    root_module.addImport("tracy", tracy.module("tracy"));

    // Pick an implementation based on the build flags.
    // Don't build both, we don't want to link with Tracy at all unless we intend to enable it.
    if (tracy_enabled) {
        // The user asked to enable Tracy, use the real implementation
        root_module.addImport("tracy_impl", tracy.module("tracy_impl_enabled"));
    } else {
        // The user asked to disable Tracy, use the dummy implementation
        root_module.addImport("tracy_impl", tracy.module("tracy_impl_disabled"));
    }

    const wio = b.dependency("wio", .{
        .target = target,
        .optimize = optimize,
        .enable_opengl = true,
        .win32_manifest = false,
    });
    root_module.addImport("wio", wio.module("wio"));

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .freetype = false,
        .@"tree-sitter" = false,
        .tvg = false,
        .backend = .wio,
    });
    root_module.addImport("dvui", dvui_dep.module("dvui_wio"));
    root_module.addImport("wio-backend", dvui_dep.module("wio"));

    const gl_bindings = @import("zigglgen").generateBindingsModule(b, .{
        .api = .gl,
        .version = .@"4.5",
        .profile = .core,
    });
    root_module.addImport("gl", gl_bindings);

    const zigimg_dependency = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("zigimg", zigimg_dependency.module("zigimg"));

    const zm = b.dependency("zm", .{
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("zm", zm.module("zm"));
}
