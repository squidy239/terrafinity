const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    const sanitize = b.option(bool, "sanitize", "Enable sanitizers") orelse false;
    
    const tracy_options = .{
        .enable_ztracy = b.option(bool, "enable_ztracy", "Enable Tracy profile markers") orelse false,
        .enable_fibers = b.option(bool, "enable_fibers", "Enable Tracy fiber support") orelse false,
        .on_demand = b.option(bool, "on_demand", "Build tracy with TRACY_ON_DEMAND") orelse true,
    };

    const ztracy = b.dependency("ztracy", .{
        .enable_ztracy = tracy_options.enable_ztracy,
        .enable_fibers = tracy_options.enable_fibers,
        .on_demand = tracy_options.on_demand,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize,
        .sanitize_c = if (sanitize) .full else .off,
        .stack_protector = sanitize,
        .stack_check = sanitize,
    });

    setupDependencies(b, root_module, target, optimize, ztracy, sanitize);

    const exe = b.addExecutable(.{
        .name = "terrafinity",
        .root_module = root_module,
        .use_llvm = true,
    });
    exe.root_module.linkLibrary(ztracy.artifact("tracy"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const check_step = b.step("check", "");
    check_step.dependOn(&b.addTest(.{ .root_module = root_module }).step);

    const tests = b.addTest(.{
        .root_module = root_module,
        .use_llvm = true,
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn setupDependencies(
    b: *std.Build,
    root_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ztracy: *std.Build.Dependency,
    sanitize: bool,
) void {
    root_module.addImport("ztracy", ztracy.module("root"));

    const dep_rocksdb = b.dependency("rocksdb", .{
        .enable_zstd = true,
        .enable_lz4 = true,
        .optimize = optimize,
        .sanitize_thread = sanitize,
    });
    const rocksdb_mod = dep_rocksdb.module("bindings");
    rocksdb_mod.single_threaded = false;
    rocksdb_mod.sanitize_thread = sanitize;
    rocksdb_mod.sanitize_c = if (sanitize) .full else .off;
    root_module.addImport("rocksdb", rocksdb_mod);

    const ConcurrentHashMap = b.addModule("ConcurrentHashMap", .{
        .root_source_file = b.path("src/libs/ConcurrentHashMap.zig"),
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztracy", .module = ztracy.module("root") },
        },
    });
    root_module.addImport("ConcurrentHashMap", ConcurrentHashMap);

    const Cache = b.addModule("Cache", .{
        .root_source_file = b.path("src/libs/Cache.zig"),
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ConcurrentHashMap", .module = ConcurrentHashMap },
        },
    });
    root_module.addImport("Cache", Cache);

    const obj_mod = b.dependency("obj", .{
        .target = target,
        .optimize = optimize,
    }).module("obj");
    root_module.addImport("obj", obj_mod);

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
