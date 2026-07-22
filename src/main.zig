const std = @import("std");
const dvui = @import("dvui");
const options = @import("options");
pub const tracy = @import("tracy");
pub const tracy_impl = @import("tracy_impl");
const wio = @import("wio");
const vk = @import("vulkan");
const Renderer = @import("Renderer.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const dvui_vk_renderer = @import("dvui_vk_renderer");

pub const Entity = @import("entity/Entity.zig");
const EntityTypes = @import("entity/EntityTypes.zig");
const Game = @import("Game.zig");
const Key = @import("Key.zig");
pub const Cache = @import("libs/Cache.zig").Cache;
pub const ConcurrentHashMap = @import("libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const utils = @import("libs/utils.zig");
const Ui = @import("Ui.zig");
pub const Block = @import("world/Block.zig").Block;
pub const Chunk = @import("world/Chunk.zig");
pub const ChunkSize = Chunk.ChunkSize;
pub const World = @import("world/World.zig");

pub const tracy_options: tracy.Options = .{
    .on_demand = true,
    .verbose = false,
};

pub fn main(init: std.process.Init) !void {
    var running: std.atomic.Value(bool) = .init(true);
    const gpa = init.gpa;
    const io = init.io;

    const config_path: []const u8 = "Config.zon";
    const worlds_path: []const u8 = "worlds";

    var config_lock: std.Io.RwLock = .init;
    var config: Config = try .load(gpa, io, config_path);
    defer config.deinit(gpa);
    try config.save(io, config_path, &config_lock);

    try wio.init(.{ .allocator = gpa, .io = io, .eventFn = wio.EventQueue.eventFn });
    defer wio.deinit();

    var events: wio.EventQueue = .empty;
    defer events.deinit();

    var window = try wio.Window.create(.{ .title = "terrafinity", .event_fn_data = &events });
    defer window.destroy();
    window.setMode(.maximized);

    pollInitialSize(io, &events, &window_size);
    var vk_ctx = try VulkanContext.init(gpa, &window);
    defer vk_ctx.deinit(io);

    try createSwapchainForUi(io, vk_ctx, config.game_config.render_options.present_mode);

    var backend = try dvui.backend.init(.{ .io = io, .window = window, .size = window_size, .framebuffer = window_size });
    defer backend.deinit();

    const vk_memory = dvui_vk_renderer.VkMemory.init(vk_ctx.mem_props) orelse return error.NoSuitableMemory;
    try backend.initVulkan(
        vk_ctx.dev,
        vk_ctx.pdev,
        vk_memory,
        vk_ctx.graphics_queue,
        vk_ctx.ui_command_pool,
        gpa,
        VulkanContext.max_frames_in_flight,
        vk_ctx.swapchain_format,
    );

    const dvui_backend = dvui.Backend.init(&backend);
    var ui_window = try dvui.Window.init(@src(), gpa, dvui_backend, .{});
    defer ui_window.deinit();

    try Ui.loadFonts(&ui_window);

    var keymap = Key.Map.init(gpa);
    defer keymap.map.deinit();

    var single_press = Key.Singlepress.empty;
    try keymap.setActionKey(io, .{ .key = .escape }, .escape_menu);
    try keymap.setActionKey(io, .{ .key = .left_gui }, .escape_menu);
    try keymap.setActionKey(io, .{ .key = .f11 }, .fullscreen);
    single_press.insert(.escape_menu);
    single_press.insert(.fullscreen);

    inline for (.{ .{ .key = .w, .action = .forward }, .{ .key = .s, .action = .backward }, .{ .key = .a, .action = .left }, .{ .key = .d, .action = .right }, .{ .key = .space, .action = .up }, .{ .key = .left_shift, .action = .down }, .{ .key = .mouse_left, .action = .use_item_primary }, .{ .key = .mouse_right, .action = .use_item_secondary }, .{ .key = .f, .action = .use_item_tertiary } }) |bind| {
        try keymap.setActionKey(io, .{ .key = bind.key }, bind.action);
    }

    var game: Game = undefined;
    if (options.test_play != null) {
        vk_ctx.swapchain_gamma.store(config.game_config.render_options.gamma_correction, .monotonic);
        try game.init(io, gpa, &config.game_config, &config_lock, worlds_path, vk_ctx);
    }
    var ui: Ui = .{
        .window = &window,
        .vk_ctx = vk_ctx,
        .config = &config,
        .config_lock = &config_lock,
        .game = &game,
        .menu_state = if (options.test_play != null) .{ .ingame = true } else .{ .main = true },
        .config_path = config_path,
        .worlds_path = worlds_path,
        .running = &running,
        .ui_window = &ui_window,
        .menu_background = undefined,
    };
    try ui.initAssets(gpa);
    defer ui.deinit();
    defer if (ui.menu_state.ingame) game.deinit(io);

    const start_time: std.Io.Timestamp = .now(io, .awake);
    var frame_time: std.Io.Timestamp = start_time;
    var action_set = Key.ActionSet.empty;
    var prev_window_size = window_size;
    var current_window_mode: wio.WindowMode = .maximized;
    var pre_fullscreen_window_mode: wio.WindowMode = .maximized;

    var ui_cmd_buffers: [VulkanContext.max_frames_in_flight]vk.CommandBuffer = undefined;
    const ui_cmd_bufs_slice: []vk.CommandBuffer = &ui_cmd_buffers;
    try vk_ctx.dev.allocateCommandBuffers(&.{
        .command_pool = vk_ctx.ui_command_pool,
        .level = .primary,
        .command_buffer_count = VulkanContext.max_frames_in_flight,
    }, ui_cmd_bufs_slice.ptr);

    while (running.load(.unordered)) {
        wio.update();
        try handleEvents(io, &keymap, single_press, &action_set, &running, &backend, &window, &events, &ui_window, &ui);
        if (action_set.contains(.escape_menu)) ui.menu_state.handle_esc();
        if (action_set.contains(.fullscreen)) {
            if (current_window_mode == .fullscreen) {
                window.setMode(pre_fullscreen_window_mode);
                current_window_mode = pre_fullscreen_window_mode;
            } else {
                pre_fullscreen_window_mode = current_window_mode;
                current_window_mode = .fullscreen;
                window.setMode(current_window_mode);
            }
            vk_ctx.swapchain_needs_recreate.store(true, .monotonic);
        }
        frame_time = .now(io, .awake);

        if (prev_window_size.width != window_size.width or prev_window_size.height != window_size.height) {
            vk_ctx.swapchain_extent = .{ .width = @as(u32, @intCast(window_size.width)), .height = @as(u32, @intCast(window_size.height)) };
            vk_ctx.swapchain_needs_recreate.store(true, .monotonic);
            prev_window_size = window_size;
        }

        if (options.test_play) |timeout| {
            if (start_time.untilNow(io, .awake).toSeconds() >= timeout) {
                std.log.info("Test play timeout reached", .{});
                running.store(false, .unordered);
                break;
            }
        }

        if (vk_ctx.swapchain_needs_recreate.load(.monotonic)) {
            recreateSwapchainForMenuOrGame(io, vk_ctx, &ui, &game, config.game_config.render_options.present_mode);
            continue;
        }

        const frame_ctx = vk_ctx.beginFrame() catch |err| switch (err) {
            error.OutOfDate, error.SurfaceLostKHR => {
                recreateSwapchainForMenuOrGame(io, vk_ctx, &ui, &game, config.game_config.render_options.present_mode);
                continue;
            },
            error.DrawFailed => {
                std.log.err("beginFrame failed: draw error", .{});
                continue;
            },
            else => return err,
        };

        const is_ingame = ui.menu_state.ingame;
        if (is_ingame) {
            const draw_ctx: Renderer.FrameDrawContext = .{
                .frame_index = frame_ctx.frame_index,
                .cmd_buffer = frame_ctx.cmd_buffer,
                .output_image = vk_ctx.swapchain_images[frame_ctx.image_index],
                .output_view = vk_ctx.swapchain_views[frame_ctx.image_index],
                .swapchain_image_layout = &vk_ctx.swapchain_image_layouts[frame_ctx.image_index],
            };
            try game.frame(io, gpa, draw_ctx, .{ vk_ctx.swapchain_extent.width, vk_ctx.swapchain_extent.height });
        }

        try recordUiPass(io, gpa, vk_ctx, &backend, &ui_window, &ui, ui_cmd_buffers[frame_ctx.frame_index], frame_ctx, frame_time);

        const submit_game = is_ingame and ui.menu_state.ingame;
        try vk_ctx.submitFrameWithExtra(io, frame_ctx, ui_cmd_buffers[frame_ctx.frame_index], submit_game);

        vk_ctx.present(io, frame_ctx) catch |err| switch (err) {
            error.OutOfDate, error.SurfaceLostKHR => {
                vk_ctx.swapchain_needs_recreate.store(true, .monotonic);
            },
            else => {
                std.log.err("present failed: {}", .{err});
            },
        };

        tracy.frameMark(null);
    }
    window.disableRelativeMouse();
}

test {
    std.testing.refAllDecls(@This());
}

pub const Config = struct {
    game_config: Game.Options = .{},

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
        const config_file: ?std.Io.File = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .lock = .shared }) catch |err| sw: switch (err) {
            error.FileNotFound => {
                std.log.info("Config file not found, creating default config file", .{});
                break :sw null;
            },
            else => return err,
        };
        defer if (config_file) |file| file.close(io);
        var config: Config = undefined;
        config = if (config_file) |file| try utils.loadZon(Config, io, file, allocator, allocator) else blk: {
            var default_config: Config = .{};
            default_config.game_config.render_options.selected_pack = try allocator.dupe(u8, "default");
            break :blk default_config;
        };
        return config;
    }

    pub fn save(self: *const Config, io: std.Io, path: []const u8, config_lock: ?*std.Io.RwLock) !void {
        const config_file = try std.Io.Dir.cwd().createFile(io, path, .{ .lock = .exclusive });
        defer config_file.close(io);
        var buffer: [512]u8 = undefined;
        var file_writer = config_file.writer(io, &buffer);
        {
            if (config_lock) |lock| lock.lockSharedUncancelable(io);
            defer if (config_lock) |lock| lock.unlockShared(io);
            try std.zon.stringify.serialize(self, .{}, &file_writer.interface);
        }
        try file_writer.end();
    }

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        allocator.free(self.game_config.render_options.selected_pack);
    }

    pub const structui_options: dvui.struct_ui.StructOptions(@This()) = .initWithDefaults(.{}, null);
};

var window_size: wio.Size = .{ .height = 480, .width = 640 };

fn pollInitialSize(io: std.Io, events: *wio.EventQueue, size: *wio.Size) void {
    _ = io;
    var count: u32 = 0;
    while (count < 100) : (count += 1) {
        wio.update();
        while (events.pop()) |event| {
            if (event == .size_physical) {
                size.* = event.size_physical;
                return;
            }
        }
    }
}

fn createSwapchainForUi(io: std.Io, vk_ctx: *VulkanContext, present_mode: VulkanContext.PresentMode) !void {
    vk_ctx.swapchain_extent = .{ .width = @as(u32, @intCast(window_size.width)), .height = @as(u32, @intCast(window_size.height)) };
    vk_ctx.present_mode = present_mode;
    vk_ctx.queue_mutex.lockUncancelable(io);
    try vk_ctx.createSwapchainLocked(false);
    vk_ctx.queue_mutex.unlock(io);
}

fn recreateSwapchainForMenuOrGame(io: std.Io, vk_ctx: *VulkanContext, ui: *Ui, game: *Game, present_mode: VulkanContext.PresentMode) void {
    vk_ctx.queue_mutex.lockUncancelable(io);
    defer vk_ctx.queue_mutex.unlock(io);
    vk_ctx.dev.queueWaitIdle(vk_ctx.graphics_queue) catch |err| {
        std.log.err("queueWaitIdle failed during swapchain recreate: {}", .{err});
    };

    vk_ctx.present_mode = present_mode;
    if (ui.menu_state.ingame) {
        game.renderer.recreateSwapchain(io);
    } else {
        vk_ctx.createSwapchainLocked(false) catch |err| {
            std.log.err("createSwapchainLocked failed: {}", .{err});
            return;
        };
    }
    vk_ctx.swapchain_needs_recreate.store(false, .monotonic);
}

fn recordUiPass(
    io: std.Io,
    gpa: std.mem.Allocator,
    vk_ctx: *VulkanContext,
    backend: *dvui.backend,
    ui_window: *dvui.Window,
    ui: *Ui,
    cmd: vk.CommandBuffer,
    frame_ctx: VulkanContext.FrameContext,
    frame_time: std.Io.Timestamp,
) !void {
    const extent = vk_ctx.swapchain_extent;
    const image_index = frame_ctx.image_index;
    const image = vk_ctx.swapchain_images[image_index];
    const view = vk_ctx.swapchain_views[image_index];
    const initial_layout = vk_ctx.swapchain_image_layouts[image_index];
    try vk_ctx.dev.resetCommandBuffer(cmd, .{});
    try vk_ctx.dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });

    transitionImageLayout(vk_ctx.dev, cmd, image, initial_layout, .color_attachment_optimal);
    vk_ctx.swapchain_image_layouts[image_index] = .color_attachment_optimal;

    const color_attachment = vk.RenderingAttachmentInfo{
        .image_view = view,
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .load_op = .load,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } },
    };
    vk_ctx.dev.cmdBeginRendering(cmd, &vk.RenderingInfo{
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = (&color_attachment)[0..1],
    });

    backend.setCommandBuffer(cmd, extent);
    backend.beginFrame();
    try drawUi(io, gpa, ui_window, ui, frame_time);
    vk_ctx.dev.cmdEndRendering(cmd);

    transitionImageLayout(vk_ctx.dev, cmd, image, .color_attachment_optimal, .present_src_khr);
    vk_ctx.swapchain_image_layouts[image_index] = .present_src_khr;
    try vk_ctx.dev.endCommandBuffer(cmd);
}

fn transitionImageLayout(dev: vk.DeviceProxy, cmd: vk.CommandBuffer, image: vk.Image, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) void {
    const src_stage: vk.PipelineStageFlags2 = switch (old_layout) {
        .undefined => .{ .top_of_pipe_bit = true },
        .present_src_khr => .{ .bottom_of_pipe_bit = true },
        .color_attachment_optimal => .{ .color_attachment_output_bit = true },
        else => .{ .all_commands_bit = true },
    };
    const src_access: vk.AccessFlags2 = switch (old_layout) {
        .undefined => .{},
        .present_src_khr => .{},
        .color_attachment_optimal => .{ .color_attachment_write_bit = true },
        else => .{ .memory_read_bit = true, .memory_write_bit = true },
    };
    const barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        .dst_stage_mask = if (new_layout == .color_attachment_optimal) .{ .color_attachment_output_bit = true } else .{ .bottom_of_pipe_bit = true },
        .dst_access_mask = if (new_layout == .color_attachment_optimal) .{ .color_attachment_write_bit = true } else .{},
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    dev.cmdPipelineBarrier2(cmd, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = (&barrier)[0..1],
    });
}

fn drawUi(io: std.Io, gpa: std.mem.Allocator, ui_window: *dvui.Window, ui: *Ui, frame_time: std.Io.Timestamp) !void {
    const dw = tracy.Zone.begin(.{ .src = @src(), .name = "draw ui" });
    defer dw.end();

    try ui_window.begin(std.Io.Timestamp.now(io, .awake).toNanoseconds());
    var menu_changed: bool = false;
    {
        const ov = dvui.overlay(@src(), .{ .expand = .both });
        defer ov.deinit();

        if (ui.menu_state.debug_info and ui.menu_state.ingame and !menu_changed) ui.debugInfo(io) catch |err| {
            std.log.err("debugInfo failed: {}", .{err});
        };
        if (ui.menu_state.crosshair and ui.menu_state.ingame and !menu_changed) ui.crossHair();
        if (ui.menu_state.esc and !menu_changed) menu_changed = ui.escMenu(io) catch false;
        if (ui.menu_state.main and !menu_changed) menu_changed = ui.mainPage(io, gpa) catch |err| blk: {
            showWorldError(frame_time, err);
            break :blk false;
        };
        if (ui.menu_state.settings and !menu_changed) menu_changed = ui.settingsMenu(io) catch false;
        if (ui.menu_state.newgame and !menu_changed) menu_changed = ui.newGameMenu(io, gpa) catch |err| blk: {
            showWorldError(frame_time, err);
            break :blk false;
        };
    }
    _ = try ui_window.end(.{});
}

fn showWorldError(frame_time: std.Io.Timestamp, err: anyerror) void {
    var error_buffer: [65536]u8 = undefined;
    var error_writer: std.Io.Writer = .fixed(&error_buffer);
    switch (err) {
        error.RocksDBOpen => error_writer.print("World is already open in another instance.", .{}) catch unreachable,
        error.OutOfMemory => error_writer.print("Out of memory.", .{}) catch unreachable,
        error.ParseZon => error_writer.print("A ZON file in this world has an invalid format.", .{}) catch unreachable,
        error.WorldNameMissing => error_writer.print("World needs a name.", .{}) catch unreachable,
        else => error_writer.print("{any}", .{err}) catch unreachable,
    }
    dvui.dialog(@src(), frame_time, .{ .message = error_writer.buffered(), .title = "                There was a problem                " });
}

fn handleEvents(
    io: std.Io,
    key_map: *Key.Map,
    single_press: Key.Singlepress,
    action_set: *Key.ActionSet,
    running: *std.atomic.Value(bool),
    backend: *dvui.backend,
    win: *wio.Window,
    events: *wio.EventQueue,
    ui_window: *dvui.Window,
    ui: *Ui,
) !void {
    backend.setTextInputRect(ui_window.textInputRequested());
    if (ui.menu_state.is_playing_game()) {
        win.enableRelativeMouse(.{ .unaccelerated = true });
    } else {
        win.disableRelativeMouse();
        backend.setCursor(ui_window.cursorRequested());
    }

    var it = action_set.iterator();
    while (it.next()) |action| {
        if (single_press.contains(action)) action_set.remove(action);
    }

    while (events.pop()) |event| {
        _ = try backend.addEvent(ui_window, event);
        switch (event) {
            .button_press => |key| {
                const action = key_map.getAction(io, Key.Key{ .key = key }) orelse continue;
                action_set.insert(action);
            },
            .button_release => |key| {
                const action = key_map.getAction(io, Key.Key{ .key = key }) orelse continue;
                action_set.remove(action);
            },
            .close => running.store(false, .unordered),
            .scroll_vertical => |scroll| {
                if (ui.menu_state.ingame) try ui.game.handleScroll(io, scroll);
            },
            .mouse_relative => |mouse| {
                const mouse_moved = (mouse.x != 0 or mouse.y != 0);
                if (ui.menu_state.ingame and mouse_moved) ui.game.handleMouseMotion(io, mouse);
            },
            .size_physical => |size| window_size = size,
            else => {},
        }
    }

    if (ui.menu_state.ingame) {
        try ui.game.handleButtonActions(io, action_set);
    }
}
