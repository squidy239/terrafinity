const std = @import("std");

const ThreadSanitizeMode = enum {
    None,
    Normal,
    Full,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sanitize = b.option(ThreadSanitizeMode, "sanitize_thread", "Enable thread sanitizer") orelse .None;
    const test_play = b.option(u32, "test_play", "Run test play") orelse null;

    // Compile shaders using glslc

    const shader_cmd = .{
        "glslc",
        "--target-env=vulkan1.3",
        "-O",
        "-Werror",
        "-o",
    };

    const vert_cmd = b.addSystemCommand(&shader_cmd);
    const vert_spv = vert_cmd.addOutputFileArg("vertexshader.spv");
    vert_cmd.addFileArg(b.path("src/Renderer/vulkan/vertexshader.vert"));

    const frag_cmd = b.addSystemCommand(&shader_cmd);
    const frag_spv = frag_cmd.addOutputFileArg("fragshader.spv");
    frag_cmd.addFileArg(b.path("src/Renderer/vulkan/fragshader.frag"));

    const trans_frag_cmd = b.addSystemCommand(&shader_cmd);
    const trans_frag_spv = trans_frag_cmd.addOutputFileArg("transparent_frag.spv");
    trans_frag_cmd.addFileArg(b.path("src/Renderer/vulkan/transparent_frag.frag"));

    const comp_vert_cmd = b.addSystemCommand(&shader_cmd);
    const comp_vert_spv = comp_vert_cmd.addOutputFileArg("composite_vert.spv");
    comp_vert_cmd.addFileArg(b.path("src/Renderer/vulkan/composite_vert.vert"));

    const comp_frag_cmd = b.addSystemCommand(&shader_cmd);
    const comp_frag_spv = comp_frag_cmd.addOutputFileArg("composite_frag.spv");
    comp_frag_cmd.addFileArg(b.path("src/Renderer/vulkan/composite_frag.frag"));

    const cull_cmd = b.addSystemCommand(&shader_cmd);
    const cull_spv = cull_cmd.addOutputFileArg("cull.spv");
    cull_cmd.addFileArg(b.path("src/Renderer/vulkan/cull.comp"));

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize != .None,
    });

    setupDependencies(b, root_module, target, optimize, sanitize);

    const exe = b.addExecutable(.{
        .name = "terrafinity",
        .root_module = root_module,
        .use_llvm = true,
    });

    exe.step.dependOn(&vert_cmd.step);
    exe.step.dependOn(&frag_cmd.step);
    exe.step.dependOn(&trans_frag_cmd.step);
    exe.step.dependOn(&comp_vert_cmd.step);
    exe.step.dependOn(&comp_frag_cmd.step);
    exe.step.dependOn(&cull_cmd.step);

    exe.root_module.addAnonymousImport("vert_spv", .{ .root_source_file = vert_spv });
    exe.root_module.addAnonymousImport("frag_spv", .{ .root_source_file = frag_spv });
    exe.root_module.addAnonymousImport("trans_frag_spv", .{ .root_source_file = trans_frag_spv });
    exe.root_module.addAnonymousImport("comp_vert_spv", .{ .root_source_file = comp_vert_spv });
    exe.root_module.addAnonymousImport("comp_frag_spv", .{ .root_source_file = comp_frag_spv });
    exe.root_module.addAnonymousImport("cull_spv", .{ .root_source_file = cull_spv });

    var options: *std.Build.Step.Options = .create(b);
    options.addOption(?u32, "test_play", test_play);
    options.addOption(bool, "sanitize_thread", sanitize != .None);
    exe.root_module.addOptions("options", options);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = root_module,
        .use_llvm = true,
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
    sanitize: ThreadSanitizeMode,
) void {
    const dep_rocksdb = b.dependency("rocksdb", .{
        .enable_zstd = true,
        .enable_lz4 = true,
        .target = target,
        .optimize = switch (optimize) {
            .Debug, .ReleaseSafe => std.builtin.OptimizeMode.ReleaseSafe,
            .ReleaseFast => std.builtin.OptimizeMode.ReleaseFast,
            .ReleaseSmall => std.builtin.OptimizeMode.ReleaseSmall,
        },
        .sanitize_thread = sanitize == .Full,
    });
    const rocksdb_mod = dep_rocksdb.module("bindings");
    rocksdb_mod.single_threaded = false;

    root_module.addImport("rocksdb", rocksdb_mod);

    const obj_mod = b.dependency("obj", .{
        .target = target,
        .optimize = optimize,
    }).module("obj");
    root_module.addImport("obj", obj_mod);

    const tracy_enabled = b.option(
        bool,
        "tracy",
        "Build with Tracy support.",
    ) orelse false;

    const tracy = b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
    });

    root_module.addImport("tracy", tracy.module("tracy"));
    if (tracy_enabled) {
        root_module.addImport("tracy_impl", tracy.module("tracy_impl_enabled"));
    } else {
        root_module.addImport("tracy_impl", tracy.module("tracy_impl_disabled"));
    }

    const wio = b.dependency("wio", .{
        .target = target,
        .optimize = optimize,
        .enable_opengl = true,
        .enable_vulkan = true,
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

    // Vulkan bindings generation
    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const registry = vulkan_headers.path("registry/vk.xml");
    const vk_gen = b.dependency("vulkan", .{}).artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addFileArg(registry);
    const vulkan_zig = b.addModule("vulkan", .{
        .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
    });
    root_module.addImport("vulkan", vulkan_zig);
}
