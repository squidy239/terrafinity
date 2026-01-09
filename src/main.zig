const std = @import("std");
const builtin = @import("builtin");

const EntityTypes = @import("world/EntityTypes.zig");
const gl = @import("gl");
pub const Block = @import("world/Block.zig").Block;
pub const Cache = @import("Cache").Cache;
pub const Chunk = @import("world/Chunk.zig");
pub const ChunkSize = Chunk.ChunkSize;
pub const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
pub const ConcurrentQueue = @import("ConcurrentQueue");
pub const Entity = @import("world/Entity.zig");
pub const ThreadPool = @import("ThreadPool");
pub const Loader = @import("Loader.zig");
pub const ChunkManager = @import("ChunkManager.zig").ChunkManager;
const sdl = @import("sdl3");
pub const World = @import("world/World.zig");
pub const zm = @import("zm");
pub const ztracy = @import("ztracy");
const Game = @import("Game.zig");
const dvui = @import("dvui");
pub const Renderer = @import("client/Renderer.zig");
const SDLBackend = @import("sdl3-backend");

var lastx: f64 = undefined;
var lasty: f64 = undefined;
var cameraFront = @Vector(3, f64){ 0, 1, 0 };
var cameraUp = @Vector(3, f64){ 0, 1, 0 };
var pitch: f64 = 1;
var yaw: f64 = 1;
pub var height: u32 = 800;
pub var width: u32 = 600;

var primary_allocator: std.mem.Allocator = undefined;

var proc_table: gl.ProcTable = undefined;

// SDL Renderer for UI overlay
var sdl_renderer: ?sdl.render.Renderer = null;

pub fn main() !void {
    var running: std.atomic.Value(bool) = .init(true);

    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    const allocator = if (builtin.mode == .Debug) debug_allocator.allocator() else std.heap.smp_allocator;
    defer if (debug_allocator.deinit() == .leak) std.log.err("mem leaked", .{});

    sdl.errors.error_callback = &sdlErr;
    sdl.log.setAllPriorities(.info);
    sdl.log.setLogOutputFunction(anyopaque, sdlLog, null);
    const init_flags: sdl.InitFlags = .{ .video = true, .events = true };
    defer sdl.shutdown();
    try sdl.init(init_flags);
    defer sdl.quit(init_flags);

    // Set OpenGL attributes
    try sdl.video.gl.setAttribute(.context_major_version, 4);
    try sdl.video.gl.setAttribute(.context_minor_version, 1);
    try sdl.video.gl.setAttribute(.context_profile_mask, @intFromEnum(sdl.video.gl.Profile.core));
    try sdl.video.gl.setAttribute(.multi_sample_samples, 4);
    //try sdl.video.gl.setAttribute(.double_buffer, @intFromBool(true));
    const window = try sdl.video.Window.init("terrafinity", width, height, .{
        .open_gl = true,
    });
    defer window.deinit();

    // Create SDL renderer for UI (uses OpenGL backend internally)
    SDLBackend.enableSDLLogging();

    const game_render_context = try sdl.video.gl.Context.init(window);
    defer game_render_context.deinit() catch unreachable;

    const ui_context = try sdl.video.gl.Context.init(window);
    defer ui_context.deinit() catch unreachable;

    errdefer if (sdl.errors.get()) |err| std.log.err("SDL error: {s}", .{err});
    const renderer = try sdl.render.Renderer.init(window, "opengl");
    defer renderer.deinit();

    try renderer.setDrawBlendMode(.blend);
    // Create OpenGL context

    try game_render_context.makeCurrent(window);

    // Initialize OpenGL
    if (!proc_table.init(sdl.c.SDL_GL_GetProcAddress)) return error.InitFailed;
    gl.makeProcTableCurrent(&proc_table);

    gl.Viewport(0, 0, @intFromFloat(@as(f32, @floatFromInt(width))), @intFromFloat(@as(f32, @floatFromInt(height))));

    gl.Enable(gl.MULTISAMPLE);
    gl.Enable(gl.DEPTH_TEST);
    gl.Enable(gl.CULL_FACE);
    gl.CullFace(gl.BACK);
    gl.FrontFace(gl.CW);
    gl.DepthFunc(gl.LESS);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var backend = SDLBackend.init(@ptrCast(window.value), @ptrCast(renderer.value));
    defer backend.deinit();

    var ui_window = try dvui.Window.init(@src(), allocator, backend.backend(), .{});
    defer ui_window.deinit();

    const running_watch = try sdl.events.addWatch(std.atomic.Value(bool), runningWatcher, &running);
    defer sdl.events.removeWatch(running_watch, &running);

    var path = try std.fs.cwd().openDir("test_world", .{});
    defer path.close();

    var game: Game = undefined;
    try game.init(allocator, allocator, window, path);
    defer game.deinit(window);

    try game.startThreads();
    while (running.load(.unordered)) {
        sdl.events.pump();

        const size = try window.getSize();
        const viewport_pixels = @Vector(2, f32){ @floatFromInt(size[0]), @floatFromInt(size[1]) };

        try game_render_context.makeCurrent(window);

        // Render game with OpenGL
        _ = try game.renderer.Draw(&game, viewport_pixels);
        try ui_context.makeCurrent(window);

        try drawUi(null, dvui_floating_stuff, &backend, renderer, &ui_window, {});

        try sdl.video.gl.swapWindow(window);
    }
}

fn drawUi(
    UserData: ?type,
    func: if (UserData != null) *const fn (UserData) void else *const fn () void,
    backend: *SDLBackend,
    renderer: sdl.render.Renderer,
    ui_window: *dvui.Window,
    context: if (UserData != null) ?UserData.* else void,
) !void {
    try ui_window.begin(std.time.nanoTimestamp());

    _ = try backend.addAllEvents(ui_window);

    if (UserData != null) {
        func(context.?);
    } else {
        func();
    }

    _ = try ui_window.end(.{});

    if (ui_window.cursorRequestedFloating()) |cursor| {
        try backend.setCursor(cursor);
    } else {
        try backend.setCursor(.bad);
    }

    try renderer.flush();
}

fn runningWatcher(running: ?*std.atomic.Value(bool), event: *sdl.events.Event) bool {
    switch (event.*) {
        .quit, .terminating, .window_close_requested => {
            running.?.store(false, .unordered);
            return true;
        },
        else => return false,
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}

fn dvui_floating_stuff() void {
    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.title) });
    const lorem = "This example shows how to use dvui for floating windows on top of an existing application.";
    tl.addText(lorem, .{});
    tl.deinit();

    var tl2 = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
    tl2.addText("The dvui is painting only floating windows and dialogs.", .{});
    tl2.addText("\n\n", .{});
    tl2.addText("Framerate is managed by the application", .{});
    tl2.addText("\n\n", .{});
    tl2.addText("Cursor is only being set by dvui for floating windows.", .{});
    tl2.addText("\n\n", .{});
    if (dvui.useFreeType) {
        tl2.addText("Fonts are being rendered by FreeType 2.", .{});
    } else {
        tl2.addText("Fonts are being rendered by stb_truetype.", .{});
    }
    tl2.deinit();

    const label = if (dvui.Examples.show_demo_window) "Hide Demo Window" else "Show Demo Window";
    if (dvui.button(@src(), label, .{}, .{})) {
        dvui.Examples.show_demo_window = !dvui.Examples.show_demo_window;
    }

    if (dvui.button(@src(), "Debug Window", .{}, .{})) {
        dvui.toggleDebugWindow();
    }

    dvui.Examples.demo();
}

fn sdlLog(
    user_data: ?*anyopaque,
    category: ?sdl.log.Category,
    priority: ?sdl.log.Priority,
    message: [:0]const u8,
) void {
    _ = user_data;
    _ = category;
    switch (priority orelse .info) {
        .warn => std.log.warn("{s}", .{message}),
        .debug => std.log.debug("{s}", .{message}),
        .info => std.log.info("{s}", .{message}),
        .err => std.log.err("{s}", .{message}),
        else => std.log.debug("{s}", .{message}),
    }
}

fn sdlErr(
    err: ?[]const u8,
) void {
    if (err) |val| {
        std.log.err("******* [Error! {s}] *******\n", .{val});
    } else {
        std.log.err("******* [Unknown Error!] *******\n", .{});
    }
}
