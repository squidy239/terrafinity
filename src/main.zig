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
const SDLBackend = @import("sdl3gpu-backend");

var lastx: f64 = undefined;
var lasty: f64 = undefined;
var cameraFront = @Vector(3, f64){ 0, 1, 0 };
var cameraUp = @Vector(3, f64){ 0, 1, 0 };
var pitch: f64 = 1;
var yaw: f64 = 1;
pub var height: u32 = 800;
pub var width: u32 = 600;

var primary_allocator: std.mem.Allocator = undefined;

var game: ?Game.Game = null;
var proc_table: gl.ProcTable = undefined;

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
    try sdl.video.gl.setAttribute(.context_major_version, 4);
    try sdl.video.gl.setAttribute(.context_minor_version, 1);
    try sdl.video.gl.setAttribute(.context_profile_mask, @intFromEnum(sdl.video.gl.Profile.core));
    try sdl.video.gl.setAttribute(.context_flags, @intFromEnum(sdl.video.gl.ContextFlag.forward_compatible));
    try sdl.video.gl.setAttribute(.multi_sample_samples, 4);
    try sdl.video.gl.setAttribute(.double_buffer, @intFromBool(true));

    const window = try sdl.video.Window.init("terrafinity", width, height, .{ .open_gl = true });
    defer window.deinit();

    const ui_gpu = try sdl.gpu.Device.init(.{ .spirv = true }, builtin.mode == .Debug, null);
    defer ui_gpu.deinit();

    try ui_gpu.claimWindow(window);
    try ui_gpu.setSwapchainParameters(window, .sdr, .immediate);

    var backend = SDLBackend.init(@ptrCast(window.value), @ptrCast(ui_gpu.value), allocator);
    defer backend.deinit();

    var ui_window = try dvui.Window.init(@src(), allocator, backend.backend(), .{});
    defer ui_window.deinit();

    const context = try sdl.video.gl.Context.init(window);
    defer context.deinit() catch unreachable; //why can deinit fail?
    try context.makeCurrent(window);

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

    const running_watch = try sdl.events.addWatch(std.atomic.Value(bool), runningWatcher, &running);
    defer sdl.events.removeWatch(running_watch, &running);
    while (running.load(.unordered)) {
        sdl.events.pump(); //TODO make this happen more then every frame, maybie have renderers be on seprate threads.
        try drawUi(null, dvui_floating_stuff, &backend, window, &ui_window, &ui_gpu, {});
    }
}

fn drawUi(UserData: ?type, func: if (UserData != null) *const fn (UserData) void else *const fn () void, backend: *SDLBackend, window: sdl.video.Window, ui_window: *dvui.Window, ui_gpu: *const sdl.gpu.Device, context: if (UserData != null) ?UserData.* else void) !void {
    const cmd = try ui_gpu.acquireCommandBuffer();

    const swapchain_texture = try cmd.waitAndAcquireSwapchainTexture(window);
    const texture = swapchain_texture.@"0" orelse return error.NoSwapchainTexture;

    backend.cmd = @ptrCast(cmd.value);
    backend.swapchain_texture = @ptrCast(texture.value);

    try ui_window.begin(std.time.nanoTimestamp());

    _ = try backend.addAllEvents(ui_window);

    var color_target = sdl.gpu.ColorTargetInfo{ .texture = texture };
    color_target.clear_color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    color_target.load = .clear;
    color_target.store = .store;

    const clearPass = cmd.beginRenderPass(@ptrCast(&color_target), null);
    clearPass.end();

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
    try backend.textInputRect(ui_window.textInputRequested());
    try backend.renderPresent();
    try cmd.submit();
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
    var float = dvui.floatingWindow(@src(), .{}, .{ .max_size_content = .{ .w = 400, .h = 400 } });
    defer float.deinit();

    float.dragAreaSet(dvui.windowHeader("Floating Window", "", null));

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

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

    // look at demo() for examples of dvui widgets, shows in a floating window
    dvui.Examples.demo();
}

fn sdlLog(
    user_data: ?*anyopaque,
    category: ?sdl.log.Category,
    priority: ?sdl.log.Priority,
    message: [:0]const u8,
) void {
    _ = user_data;
    const category_str: ?[]const u8 = if (category) |val| switch (val) {
        .application => "Application",
        .errors => "Errors",
        .assert => "Assert",
        .system => "System",
        .audio => "Audio",
        .video => "Video",
        .render => "Render",
        .input => "Input",
        .testing => "Testing",
        .gpu => "Gpu",
        else => null,
    } else null;
    const priority_str: [:0]const u8 = if (priority) |val| switch (val) {
        .trace => "Trace",
        .verbose => "Verbose",
        .debug => "Debug",
        .info => "Info",
        .warn => "Warn",
        .err => "Error",
        .critical => "Critical",
    } else "Unknown";
    if (category_str) |val| {
        std.log.info("[{s}:{s}] {s}\n", .{ val, priority_str, message });
    } else {
        std.log.info("[Custom_{?}:{s}] {s}\n", .{ category, priority_str, message });
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
