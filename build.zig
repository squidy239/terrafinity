const std = @import("std");

const dvui = @import("dvui");

const Block = @import("src/world/Block.zig").Block;

const ThreadSanitizeMode = enum {
    None,
    Normal,
    Full,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tracy_enabled = b.option(bool, "tracy", "Build with Tracy support.") orelse false;

    const sanitize = b.option(ThreadSanitizeMode, "sanitize_thread", "Enable thread sanitizer") orelse .None;
    const test_play = b.option(u32, "test_play", "Run test play") orelse null;
    const screenshot_after = b.option(u32, "screenshot_after", "Automatically take a screenshot after N seconds (like test_play)") orelse null;

    const shader_include = b.path("src/Renderer/vulkan/shadow").getPath(b);
    const occlusion_include = b.path("src/Renderer/vulkan/occlusion").getPath(b);
    const shader_base_cmd = .{
        "glslc",
        "--target-env=vulkan1.3",
        "-O",
        if (optimize == .Debug) "-g" else "-Werror",
        "-I",
        shader_include,
        "-I",
        occlusion_include,
        "-o",
    };

    const ShaderDef = struct {
        name: []const u8,
        out: []const u8,
        src: []const u8,
        deps: []const []const u8 = &.{},
    };

    const shaders = [_]ShaderDef{
        .{ .name = "vert", .out = "vertexshader.spv", .src = "src/Renderer/vulkan/chunk_renderer/vertexshader.vert", .deps = &.{"src/Renderer/vulkan/shadow/face_decode.glsl"} },
        .{ .name = "frag", .out = "fragshader.spv", .src = "src/Renderer/vulkan/chunk_renderer/fragshader.frag", .deps = &.{"src/Renderer/vulkan/shadow/shadow.glsl"} },
        .{ .name = "trans_frag", .out = "transparent_frag.spv", .src = "src/Renderer/vulkan/chunk_renderer/transparent_frag.frag", .deps = &.{"src/Renderer/vulkan/shadow/shadow.glsl"} },
        .{ .name = "comp_vert", .out = "composite_vert.spv", .src = "src/Renderer/vulkan/composite_vert.vert" },
        .{ .name = "comp_frag", .out = "composite_frag.spv", .src = "src/Renderer/vulkan/composite_frag.frag" },
        .{ .name = "cull", .out = "cull.spv", .src = "src/Renderer/vulkan/chunk_renderer/cull.comp", .deps = &.{"src/Renderer/vulkan/occlusion/occlusion.glsl"} },
        .{ .name = "pyramid", .out = "depth_pyramid.spv", .src = "src/Renderer/vulkan/occlusion/depth_pyramid.comp" },
        .{ .name = "sky_vert", .out = "sky_vert.spv", .src = "src/Renderer/vulkan/sky/sky.vert" },
        .{ .name = "sky_frag", .out = "sky_frag.spv", .src = "src/Renderer/vulkan/sky/sky.frag" },
        .{ .name = "shadow_vert", .out = "shadow_vert.spv", .src = "src/Renderer/vulkan/shadow/shadow.vert", .deps = &.{"src/Renderer/vulkan/shadow/face_decode.glsl"} },
    };

    var shader_cmds: [shaders.len]*std.Build.Step.Run = undefined;
    var shader_outs: [shaders.len]std.Build.LazyPath = undefined;

    for (shaders, 0..) |def, i| {
        const cmd = b.addSystemCommand(&shader_base_cmd);
        const out = cmd.addOutputFileArg(def.out);
        cmd.addFileArg(b.path(def.src));
        for (def.deps) |dep| cmd.addFileInput(b.path(dep));
        shader_cmds[i] = cmd;
        shader_outs[i] = out;
    }

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize != .None,
    });

    const deps = createDependencies(b, target, optimize, sanitize, tracy_enabled);
    configureModule(&deps, root_module);

    const exe = b.addExecutable(.{
        .name = "terrafinity",
        .root_module = root_module,
        .use_llvm = if (tracy_enabled) true else null,
    });

    for (shader_cmds) |cmd| exe.step.dependOn(&cmd.step);

    const shader_import_names = [_][]const u8{
        "vert_spv", "frag_spv", "trans_frag_spv", "comp_vert_spv", "comp_frag_spv",
        "cull_spv", "depth_pyramid_spv", "sky_vert_spv", "sky_frag_spv", "shadow_vert_spv",
    };
    for (shader_import_names, shader_outs) |import_name, out| {
        exe.root_module.addAnonymousImport(import_name, .{ .root_source_file = out });
    }

    for (generator_sources) |generator_source| {
        const generator = b.addLibrary(.{
            .name = generator_source.name,
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/generator_root.zig"),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize != .None,
            }),
            .use_llvm = if (tracy_enabled) true else null,
        });
        const generator_options = b.addOptions();
        generator_options.addOption(GeneratorKind, "generator", generator_source.kind);
        generator.root_module.addOptions("generator_select", generator_options);
        configureModule(&deps, generator.root_module);
        exe.step.dependOn(&b.addInstallFileWithDir(
            generator.getEmittedBin(),
            .{ .custom = "generators" },
            generator_source.file_name,
        ).step);
        exe.root_module.addAnonymousImport(generator_source.embed_name, .{
            .root_source_file = generator.getEmittedBin(),
        });
    }

    const visible_count = comptime blk: {
        var count: usize = 0;
        for (std.meta.fields(Block)) |field| {
            if (!@field(Block, field.name).isVisible()) continue;
            count += 1;
        }
        break :blk count;
    };

    var buffer: [visible_count][:0]const u8 = undefined;
    var default_textures: std.ArrayList([:0]const u8) = std.ArrayList([:0]const u8).initBuffer(&buffer);
    inline for (std.meta.fields(Block)) |field| {
        if (!@field(Block, field.name).isVisible()) continue;
        default_textures.appendAssumeCapacity(@embedFile("packs/default/blocks/" ++ field.name ++ ".png"));
    }

    var textures_options: *std.Build.Step.Options = .create(b);
    textures_options.addOption([]const [:0]const u8, "default", default_textures.items);
    exe.root_module.addOptions("textures", textures_options);

    var materials_options: *std.Build.Step.Options = .create(b);
    materials_options.addOption([]const u8, "default", @embedFile("packs/default/blocks/materials.zon"));
    exe.root_module.addOptions("materials", materials_options);

    var build_options: *std.Build.Step.Options = .create(b);
    build_options.addOption(?u32, "test_play", test_play);
    build_options.addOption(?u32, "screenshot_after", screenshot_after);
    build_options.addOption(bool, "sanitize_thread", sanitize != .None);
    exe.root_module.addOptions("options", build_options);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = root_module,
        .use_llvm = if (tracy_enabled) true else null,
        .filters = b.option([]const []const u8, "test_filter", "Only run tests whose name contains the given substrings") orelse &.{},
    });

    tests.root_module.addCSourceFile(.{
        .file = b.path("sanitizer_stubs.c"),
        .flags = &.{"-fno-sanitize-coverage=trace-cmp,trace-div,trace-gep,trace-pc,trace-pc-guard,indirect-calls"},
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addInstallArtifact(tests, .{}).step);
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

const GeneratorKind = enum { terrain, planet, voxelgame };

const generator_sources = [_]struct { kind: GeneratorKind, name: []const u8, file_name: []const u8, embed_name: []const u8 }{
    .{ .kind = .terrain, .name = "terrain_generator", .file_name = "terrain.generator", .embed_name = "terrain_generator_bin" },
    .{ .kind = .voxelgame, .name = "voxelgame_generator", .file_name = "voxelgame.generator", .embed_name = "voxelgame_generator_bin" },
    .{ .kind = .planet, .name = "planet_generator", .file_name = "planet.generator", .embed_name = "planet_generator_bin" },
};

const Deps = struct {
    rocksdb: *std.Build.Module,
    obj: *std.Build.Module,
    tracy: *std.Build.Module,
    tracy_impl: *std.Build.Module,
    wio: *std.Build.Module,
    dvui: *std.Build.Module,
    dvui_vulkan_renderer: *std.Build.Module,
    vk: *std.Build.Module,
    zignal: *std.Build.Module,
    zm: *std.Build.Module,
    fastnoise: *std.Build.Module,
};

fn createDependencies(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitize: ThreadSanitizeMode,
    tracy_enabled: bool,
) Deps {
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

    const obj_mod = b.dependency("obj", .{
        .target = target,
        .optimize = optimize,
    }).module("obj");

    const tracy = b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
    });
    const tracy_mod = tracy.module("tracy");
    const tracy_impl_mod = if (tracy_enabled) tracy.module("tracy_impl_enabled") else tracy.module("tracy_impl_disabled");

    const wio_mod = b.dependency("wio", .{
        .target = target,
        .optimize = optimize,
        .enable_opengl = false,
        .enable_vulkan = true,
        .win32_manifest = false,
    }).module("wio");

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .libc = true,
        .@"stb-image" = true,
        .@"tree-sitter" = false,
        .tvg = true,
        .backend = .custom,
    });
    const dvui_mod = dvui_dep.module("dvui");

    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const registry = vulkan_headers.path("registry/vk.xml");
    const vk_gen = b.dependency("vulkan", .{}).artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addFileArg(registry);
    const vulkan_zig_mod = b.addModule("vk", .{
        .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
    });
    const dvui_vulkan_renderer_mod = b.addModule("dvui_vulkan_renderer", .{
        .root_source_file = dvui_dep.path("src/backends/render/vulkan/renderer.zig"),
        .target = target,
        .optimize = optimize,
    });
    dvui_vulkan_renderer_mod.addImport("vk", vulkan_zig_mod);
    dvui_vulkan_renderer_mod.addImport("dvui", dvui_mod);

    const our_backend_mod = b.addModule("dvui_backend", .{
        .root_source_file = b.path("src/dvui_backend_wio.zig"),
        .target = target,
        .optimize = optimize,
    });
    our_backend_mod.addImport("wio", wio_mod);
    our_backend_mod.addImport("dvui", dvui_mod);
    our_backend_mod.addImport("vk", vulkan_zig_mod);
    our_backend_mod.addImport("dvui_vulkan_renderer", dvui_vulkan_renderer_mod);

    dvui.linkBackend(dvui_mod, our_backend_mod);

    const zignal_mod = b.dependency("zignal", .{
        .target = target,
        .optimize = optimize,
    }).module("zignal");

    const zm_mod = b.dependency("zm", .{
        .target = target,
        .optimize = optimize,
    }).module("zm");

    const fastnoise_mod = b.addModule("fastnoise", .{
        .root_source_file = b.path("src/libs/fastnoise.zig"),
        .target = target,
        .optimize = optimize,
    });

    return .{
        .rocksdb = rocksdb_mod,
        .obj = obj_mod,
        .tracy = tracy_mod,
        .tracy_impl = tracy_impl_mod,
        .wio = wio_mod,
        .dvui = dvui_mod,
        .dvui_vulkan_renderer = dvui_vulkan_renderer_mod,
        .vk = vulkan_zig_mod,
        .zignal = zignal_mod,
        .zm = zm_mod,
        .fastnoise = fastnoise_mod,
    };
}

fn configureModule(deps: *const Deps, mod: *std.Build.Module) void {
    mod.addImport("rocksdb", deps.rocksdb);
    mod.addImport("obj", deps.obj);
    mod.addImport("tracy", deps.tracy);
    mod.addImport("tracy_impl", deps.tracy_impl);
    mod.addImport("wio", deps.wio);
    mod.addImport("dvui", deps.dvui);
    mod.addImport("dvui_vulkan_renderer", deps.dvui_vulkan_renderer);
    mod.addImport("vk", deps.vk);
    mod.addImport("zignal", deps.zignal);
    mod.addImport("zm", deps.zm);
    mod.addImport("fastnoise", deps.fastnoise);
    mod.addImport("vulkan", deps.vk);
}
