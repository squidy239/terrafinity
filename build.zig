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

    const shader_include = b.path("src/Renderer/vulkan/shadow").getPath(b);
    const occlusion_include = b.path("src/Renderer/vulkan/occlusion").getPath(b);
    const shader_cmd = .{
        "glslc",
        "--target-env=vulkan1.3",
        "-O",
        if (optimize == .Debug) "-g" else "-Werror",
        "-Werror",
        "-I",
        shader_include,
        "-I",
        occlusion_include,
        "-o",
    };

    const vert_cmd = b.addSystemCommand(&shader_cmd);
    const vert_spv = vert_cmd.addOutputFileArg("vertexshader.spv");
    vert_cmd.addFileArg(b.path("src/Renderer/vulkan/chunk_renderer/vertexshader.vert"));
    vert_cmd.addFileInput(b.path("src/Renderer/vulkan/shadow/face_decode.glsl"));

    const frag_cmd = b.addSystemCommand(&shader_cmd);
    const frag_spv = frag_cmd.addOutputFileArg("fragshader.spv");
    frag_cmd.addFileArg(b.path("src/Renderer/vulkan/chunk_renderer/fragshader.frag"));
    frag_cmd.addFileInput(b.path("src/Renderer/vulkan/shadow/shadow.glsl"));

    const trans_frag_cmd = b.addSystemCommand(&shader_cmd);
    const trans_frag_spv = trans_frag_cmd.addOutputFileArg("transparent_frag.spv");
    trans_frag_cmd.addFileArg(b.path("src/Renderer/vulkan/chunk_renderer/transparent_frag.frag"));
    trans_frag_cmd.addFileInput(b.path("src/Renderer/vulkan/shadow/shadow.glsl"));

    const comp_vert_cmd = b.addSystemCommand(&shader_cmd);
    const comp_vert_spv = comp_vert_cmd.addOutputFileArg("composite_vert.spv");
    comp_vert_cmd.addFileArg(b.path("src/Renderer/vulkan/composite_vert.vert"));

    const comp_frag_cmd = b.addSystemCommand(&shader_cmd);
    const comp_frag_spv = comp_frag_cmd.addOutputFileArg("composite_frag.spv");
    comp_frag_cmd.addFileArg(b.path("src/Renderer/vulkan/composite_frag.frag"));

    const cull_cmd = b.addSystemCommand(&shader_cmd);
    const cull_spv = cull_cmd.addOutputFileArg("cull.spv");
    cull_cmd.addFileArg(b.path("src/Renderer/vulkan/chunk_renderer/cull.comp"));
    cull_cmd.addFileInput(b.path("src/Renderer/vulkan/occlusion/occlusion.glsl"));

    const pyramid_cmd = b.addSystemCommand(&shader_cmd);
    const pyramid_spv = pyramid_cmd.addOutputFileArg("depth_pyramid.spv");
    pyramid_cmd.addFileArg(b.path("src/Renderer/vulkan/occlusion/depth_pyramid.comp"));

    const sky_vert_cmd = b.addSystemCommand(&shader_cmd);
    const sky_vert_spv = sky_vert_cmd.addOutputFileArg("sky_vert.spv");
    sky_vert_cmd.addFileArg(b.path("src/Renderer/vulkan/sky/sky.vert"));

    const sky_frag_cmd = b.addSystemCommand(&shader_cmd);
    const sky_frag_spv = sky_frag_cmd.addOutputFileArg("sky_frag.spv");
    sky_frag_cmd.addFileArg(b.path("src/Renderer/vulkan/sky/sky.frag"));

    const shadow_vert_cmd = b.addSystemCommand(&shader_cmd);
    const shadow_vert_spv = shadow_vert_cmd.addOutputFileArg("shadow_vert.spv");
    shadow_vert_cmd.addFileArg(b.path("src/Renderer/vulkan/shadow/shadow.vert"));
    shadow_vert_cmd.addFileInput(b.path("src/Renderer/vulkan/shadow/face_decode.glsl"));

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
        .use_llvm = if(tracy_enabled) true else null,
    });

    exe.step.dependOn(&vert_cmd.step);
    exe.step.dependOn(&frag_cmd.step);
    exe.step.dependOn(&trans_frag_cmd.step);
    exe.step.dependOn(&comp_vert_cmd.step);
    exe.step.dependOn(&comp_frag_cmd.step);
    exe.step.dependOn(&cull_cmd.step);
    exe.step.dependOn(&pyramid_cmd.step);
    exe.step.dependOn(&sky_vert_cmd.step);
    exe.step.dependOn(&sky_frag_cmd.step);
    exe.step.dependOn(&shadow_vert_cmd.step);

    exe.root_module.addAnonymousImport("vert_spv", .{ .root_source_file = vert_spv });
    exe.root_module.addAnonymousImport("frag_spv", .{ .root_source_file = frag_spv });
    exe.root_module.addAnonymousImport("trans_frag_spv", .{ .root_source_file = trans_frag_spv });
    exe.root_module.addAnonymousImport("comp_vert_spv", .{ .root_source_file = comp_vert_spv });
    exe.root_module.addAnonymousImport("comp_frag_spv", .{ .root_source_file = comp_frag_spv });
    exe.root_module.addAnonymousImport("cull_spv", .{ .root_source_file = cull_spv });
    exe.root_module.addAnonymousImport("depth_pyramid_spv", .{ .root_source_file = pyramid_spv });
    exe.root_module.addAnonymousImport("sky_vert_spv", .{ .root_source_file = sky_vert_spv });
    exe.root_module.addAnonymousImport("sky_frag_spv", .{ .root_source_file = sky_frag_spv });
    exe.root_module.addAnonymousImport("shadow_vert_spv", .{ .root_source_file = shadow_vert_spv });

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
            .use_llvm = if(tracy_enabled) true else null,
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
        // Embed the built library so the executable can write it into the
        // generators directory at startup, like the config and textures.
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
        .use_llvm = if(tracy_enabled) true else null,
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

    // dvui
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

    // Vulkan bindings shared by the game and DVUI renderer.
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
    // DVUI platform backend: windowing and input via WIO, rendering via the upstream Vulkan renderer.
    const our_backend_mod = b.addModule("dvui_backend", .{
        .root_source_file = b.path("src/dvui_backend_wio.zig"),
        .target = target,
        .optimize = optimize,
    });
    our_backend_mod.addImport("wio", wio_mod);
    our_backend_mod.addImport("dvui", dvui_mod);
    our_backend_mod.addImport("vk", vulkan_zig_mod);
    our_backend_mod.addImport("dvui_vulkan_renderer", dvui_vulkan_renderer_mod);

    // Link the custom platform backend with DVUI.
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

    // Vulkan bindings (for our game renderer - imported as "vulkan")
    mod.addImport("vulkan", deps.vk);
}
