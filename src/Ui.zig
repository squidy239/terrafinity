const std = @import("std");

const dvui = @import("dvui");
const wio = @import("wio");
const zignal = @import("zignal");
const tracy = @import("tracy");
const vk = @import("vulkan");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;

const Config = @import("main.zig").Config;
const EntityTypes = @import("entity/EntityTypes.zig");
const Game = @import("Game.zig");
const generator_api = @import("world/generators/generator_api.zig");
const generator_loader = @import("world/generator_loader.zig");
const utils = @import("libs/utils.zig");
const World = @import("world/World.zig");

const press_start_2p: []const u8 = @embedFile("assets/press-start-2p/PressStart2P.ttf");
const menu_background_image: []const u8 = @embedFile("assets/terrain.png");
const pixel_font = sliceToBounded("Press Start 2P", 50);
const Ui = @This();

pub const main_theme: dvui.Theme = blk: {
    const text: dvui.Color = .{ .r = 216, .g = 240, .b = 216, .a = 255 };
    const fill: dvui.Color = .{ .r = 16, .g = 24, .b = 16, .a = 255 };
    const border: dvui.Color = .{ .r = 77, .g = 129, .b = 77, .a = 255 };
    const accent: dvui.Color = .{ .r = 156, .g = 204, .b = 0, .a = 255 };
    const control_fill: dvui.Color = .{ .r = 44, .g = 77, .b = 44, .a = 255 };
    const control_hover: dvui.Color = .{ .r = 61, .g = 107, .b = 61, .a = 255 };
    const highlight_fill: dvui.Color = .{ .r = 0, .g = 128, .b = 128, .a = 255 };
    const highlight_hover: dvui.Color = .{ .r = 0, .g = 160, .b = 160, .a = 255 };
    break :blk .{
        .name = "Terrafinity",
        .dark = true,
        .embedded_fonts = &.{
            .{ .family = dvui.Font.array("Press Start 2P"), .bytes = press_start_2p },
        },
        .font_body = .find(.{ .family = "Press Start 2P", .size = 14 }),
        .font_heading = .find(.{ .family = "Press Start 2P", .size = 14 }),
        .font_title = .find(.{ .family = "Press Start 2P", .size = 24 }),
        .font_mono = .find(.{ .family = "Press Start 2P", .size = 14 }),
        .focus = accent,
        .text_select = accent,
        .fill = fill,
        .text = text,
        .border = border,
        .max_default_corner_radius = 0.0,
        .control = .{
            .fill = control_fill,
            .fill_hover = control_hover,
            .fill_press = accent,
            .text = text,
            .text_press = .black,
            .border = accent,
        },
        .window = .{ .fill = fill },
        .highlight = .{
            .fill = highlight_fill,
            .fill_hover = highlight_hover,
            .fill_press = accent,
            .text = .white,
        },
    };
};

pub const menu_theme: dvui.Theme = blk: {
    const mt: dvui.Theme = main_theme;
    break :blk mt;
};

window: *wio.Window,
vk_ctx: *VulkanContext,
config: *Config,
config_lock: *std.Io.RwLock,
game: *Game,
generators: *generator_loader.Registry,
config_path: []const u8,
worlds_path: []const u8,
menu_background: dvui.Texture,
ui_window: *dvui.Window,
running: *std.atomic.Value(bool),

menu_state: struct {
    ingame: bool = false,
    debug_info: bool = true,
    settings: bool = false,
    main: bool = false,
    esc: bool = false,
    newgame: bool = false,
    crosshair: bool = true,

    pending_game_deinit: bool = false,

    /// Returns true if the player is ingame without a menu open
    pub fn is_playing_game(self: @This()) bool {
        return self.ingame and !self.settings and !self.main and !self.esc and !self.newgame;
    }

    pub fn handle_esc(self: *@This()) void {
        if (self.ingame) self.*.esc = !self.*.esc;
        self.settings = false;
    }
},

pub fn initAssets(self: *@This(), allocator: std.mem.Allocator) !void {
    var image = try zignal.Image(zignal.Rgba(u8)).loadFromBytes(allocator, menu_background_image);
    defer image.deinit(allocator);
    self.menu_background = try self.ui_window.backend.textureCreate(@ptrCast(image.asBytes().ptr), .{
        .width = @intCast(image.cols),
        .height = @intCast(image.rows),
        .format = .rgba_32,
        .interpolation = .linear,
    });
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.ui_window.backend.textureDestroy(self.menu_background);
    if (new_game_config) |config| generator_api.free(allocator, config);
    if (new_game_generator_name_allocated) allocator.free(new_game_generator_name);
    new_game_config = null;
    new_game_generator = null;
}

fn showWorldError(frame_time: std.Io.Timestamp, err: anyerror) void {
    var error_buffer: [65536]u8 = undefined;
    var error_writer: std.Io.Writer = .fixed(&error_buffer);
    switch (err) {
        error.RocksDBOpen => error_writer.print("World is already open in another instance.", .{}) catch unreachable,
        error.OutOfMemory => error_writer.print("Out of memory.", .{}) catch unreachable,
        error.ParseZon => error_writer.print("A ZON file in this world has an invalid format.", .{}) catch unreachable,
        error.WorldNameMissing => error_writer.print("World needs a name.", .{}) catch unreachable,
        error.WorldNameExists => error_writer.print("A world with this name already exists.", .{}) catch unreachable,
        error.InvalidName => error_writer.print("World names can't contain '/'.", .{}) catch unreachable,
        else => error_writer.print("{any}", .{err}) catch unreachable,
    }
    dvui.dialog(@src(), frame_time, .{ .message = error_writer.buffered(), .title = "                There was a problem                " });
}

pub fn drawFrame(self: *@This(), io: std.Io, gpa: std.mem.Allocator, frame_time: std.Io.Timestamp) !void {
    const dw = tracy.Zone.begin(.{ .src = @src(), .name = "draw ui" });
    defer dw.end();

    try self.ui_window.begin(std.Io.Timestamp.now(io, .awake).toNanoseconds());
    dvui.themeSet(main_theme);
    var menu_changed: bool = false;
    {
        const ov = dvui.overlay(@src(), .{ .expand = .both });
        defer ov.deinit();

        if (self.menu_state.debug_info and self.menu_state.ingame and !menu_changed) self.debugInfo(io) catch |err| {
            std.log.err("debugInfo failed: {}", .{err});
        };
        if (self.menu_state.crosshair and self.menu_state.ingame and !menu_changed) self.crossHair();
        if (self.menu_state.esc and !menu_changed) menu_changed = self.escMenu(io) catch false;
        if (self.menu_state.main and !menu_changed) menu_changed = self.mainPage(io, gpa) catch |err| blk: {
            showWorldError(frame_time, err);
            break :blk false;
        };
        if (self.menu_state.settings and !menu_changed) menu_changed = self.settingsMenu(io) catch false;
        if (self.menu_state.newgame and !menu_changed) menu_changed = self.newGameMenu(io, gpa) catch |err| blk: {
            showWorldError(frame_time, err);
            break :blk false;
        };
    }
    _ = try self.ui_window.end(.{});
}

pub fn recordCommandBuffer(
    self: *@This(),
    io: std.Io,
    gpa: std.mem.Allocator,
    backend: *dvui.backend,
    cmd: vk.CommandBuffer,
    frame_ctx: VulkanContext.FrameContext,
    frame_time: std.Io.Timestamp,
) !void {
    const extent = self.vk_ctx.swapchain_extent;
    const image_index = frame_ctx.image_index;
    const image = self.vk_ctx.swapchain_images[image_index];
    const view = self.vk_ctx.swapchain_views[image_index];
    const initial_layout = self.vk_ctx.swapchain_image_layouts[image_index];
    try self.vk_ctx.dev.resetCommandBuffer(cmd, .{});
    try self.vk_ctx.dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });

    VulkanContext.transitionImageLayout(self.vk_ctx.dev, cmd, image, initial_layout, .color_attachment_optimal);
    self.vk_ctx.swapchain_image_layouts[image_index] = .color_attachment_optimal;

    const color_attachment = vk.RenderingAttachmentInfo{
        .image_view = view,
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .load_op = .load,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } },
    };
    self.vk_ctx.dev.cmdBeginRendering(cmd, &vk.RenderingInfo{
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = (&color_attachment)[0..1],
    });

    backend.setCommandBuffer(cmd, extent);
    defer backend.setCommandBuffer(.null_handle, .{ .width = 0, .height = 0 });
    backend.beginFrame();
    try self.drawFrame(io, gpa, frame_time);
    self.vk_ctx.dev.cmdEndRendering(cmd);

    VulkanContext.transitionImageLayout(self.vk_ctx.dev, cmd, image, .color_attachment_optimal, .present_src_khr);
    self.vk_ctx.swapchain_image_layouts[image_index] = .present_src_khr;
    try self.vk_ctx.dev.endCommandBuffer(cmd);
}

fn menuCard(src: std.builtin.SourceLocation, init_opts: dvui.BoxWidget.InitOptions, opts: dvui.Options) *dvui.BoxWidget {
    var options: dvui.Options = .{
        .min_size_content = .all(256),
        .color_fill = .{ .r = 48, .g = 48, .b = 48, .a = 255 },
        .background = true,
        .corner_radius = .all(0),
        .border = .all(8),
        .margin = .all(16),
        .gravity_y = 0.5,
        .color_border = .{ .r = 48, .g = 77, .b = 48, .a = 225 },
    };
    var card = dvui.widgetAlloc(dvui.BoxWidget);
    card.init(src, init_opts, options.override(opts));
    const hover: bool = hovered(card.data(), .{});
    if (hover) {
        card.data().options.margin = .all(0);
        calculateWidget(card);
    }
    card.drawBackground();
    return card;
}

pub fn escMenu(self: *@This(), io: std.Io) !bool {
    _ = io;
    std.debug.assert(self.menu_state.ingame);
    const size = @Vector(2, usize){ 640, 480 };
    const menu = dvui.box(@src(), .{}, .{ .background = true, .color_fill = .{ .r = 0, .g = 200, .b = 200, .a = 150 }, .expand = .both });
    defer menu.deinit();
    if (dvui.button(@src(), "Back To Game", .{}, .{ .min_size_content = .width(@as(f32, @floatFromInt(size[0])) * 0.75), .gravity_x = 0.5 })) {
        self.menu_state.esc = false;
        return true;
    }

    if (dvui.button(@src(), "Settings", .{}, .{ .min_size_content = .width(@as(f32, @floatFromInt(size[0])) * 0.75), .gravity_x = 0.5 })) {
        self.menu_state.settings = true;
        self.menu_state.esc = false;
        return true;
    }

    if (dvui.button(@src(), "Quit", .{}, .{ .min_size_content = .width(@as(f32, @floatFromInt(size[0])) * 0.75), .gravity_x = 0.5 })) {
        self.menu_state.main = true;
        self.menu_state.esc = false;
        self.menu_state.ingame = false;
        self.menu_state.pending_game_deinit = true;
        return true;
    }

    return false;
}

pub fn debugInfo(self: *@This(), io: std.Io) !void {
    var fmt_buffer: [16000]u8 = undefined;
    const box = dvui.box(@src(), .{}, .{
        .gravity_x = 0.0,
        .gravity_y = 0.0,
    });
    defer box.deinit();
    const text = dvui.textLayout(@src(), .{}, .{
        .gravity_y = 1.0,
        .padding = .{ .w = 32, .h = 32 },
        .background = true,
        .color_fill = .{ .r = 32, .g = 32, .b = 32, .a = 128 },
        .border = .all(8),
        .color_border = .green,
    });
    defer text.deinit();

    const chunk_count = self.game.world.chunks.count();
    const grid_count = self.game.world.grids.count();
    const chunk_hits = self.game.world.chunks.hits();
    const chunk_misses = self.game.world.chunks.misses();

    const chunk_hit_ratio = @as(f32, @floatFromInt(chunk_hits)) / @as(f32, @floatFromInt(chunk_hits + chunk_misses));
    const player_pos = self.game.getPlayerPos(io);
    const pos: @Vector(3, i64) = @intFromFloat(@round(player_pos));
    const str = try std.fmt.bufPrint(
        &fmt_buffer,
        \\FPS: {d}
        \\meshes loaded: {d}
        \\opaque faces: {d}
        \\transparent faces: {d}
        \\pos: {d}, {d}, {d}
        \\chunks cached: {d}
        \\grids cached: {d}
        \\chunk hit ratio: {d:.2}
    ,
        .{
            @trunc(self.game.debug_menu.fps.load(.unordered)),
            self.game.debug_menu.meshes.load(.unordered),
            self.game.debug_menu.opaque_faces.load(.unordered),
            self.game.debug_menu.transparent_faces.load(.unordered),
            pos[0],
            pos[1],
            pos[2],
            chunk_count,
            grid_count,
            chunk_hit_ratio,
        },
    );
    text.addText(str, .{ .background = false });
}

fn sliceToBounded(comptime slice: []const u8, comptime max: usize) [max:0]u8 {
    var f: [max:0]u8 = undefined;
    @memcpy(f[0..slice.len], slice);
    f[slice.len] = 0;
    return f;
}

pub fn settingsMenu(self: *@This(), io: std.Io) !bool {
    const page = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer page.deinit();

    const menu_changed: bool = if (!self.menu_state.ingame) self.sidebar() else false;

    const settings = dvui.scrollArea(
        @src(),
        .{ .vertical_bar = .auto },
        .{
            .expand = .both,
            .background = true,
            .color_fill = .{ .r = 48, .g = 77, .b = 84, .a = 225 },
        },
    );
    defer settings.deinit();

    if (self.menu_state.ingame) {
        var gm: EntityTypes.Player.GameMode = self.game.player.game_mode.load(.monotonic);
        _ = dvui.dropdownEnum(
            @src(),
            EntityTypes.Player.GameMode,
            .{ .choice = &gm },
            .{ .null_selectable = false },
            .{ .gravity_x = 0.5 },
        );
        self.game.player.switchGameMode(gm);
    }

    try self.config_lock.lock(io);
    const firstconfig = self.config.*;

    dvui.structUI(@src(), "Settings", self.config, 32, .{Config.structui_options}, .{});

    // Remove config strings from struct_ui's string_map to prevent double-free.
    // struct_ui.deinit (called by Window.deinit) would otherwise free these strings,
    // and then Config.deinit would free them again via allocator.free.
    _ = dvui.struct_ui.string_map.remove(&self.config.game_config.render_options.selected_pack);

    const config_changed = !std.meta.eql(firstconfig, self.config.*);
    const gamma_changed = firstconfig.game_config.render_options.gamma_correction != self.config.game_config.render_options.gamma_correction;
    const present_mode_changed = firstconfig.game_config.render_options.present_mode != self.config.game_config.render_options.present_mode;
    self.config_lock.unlock(io);

    if (gamma_changed or present_mode_changed) {
        self.vk_ctx.swapchain_needs_recreate.store(true, .monotonic);
    }

    if (config_changed) try self.config.save(io, self.config_path, self.config_lock);
    return menu_changed;
}

pub fn crossHair(self: *@This()) void {
    _ = self;
    _ = dvui.label(@src(), "+", .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5, .color_fill = .transparent, .font = .{ .size = 32 } });
}

var new_game_world_config: World.WorldConfig = .{};
var new_game_generator_name: []const u8 = "Terrain";
var new_game_generator_name_allocated = false;
var new_game_generator: ?*generator_loader.Generator = null;
var new_game_config: ?*generator_api.ConfigTree = null;
var new_game_preset_index: usize = 0;

fn selectNewGameGenerator(allocator: std.mem.Allocator, generator: *generator_loader.Generator) !void {
    if (new_game_generator == generator) return;
    if (new_game_config) |config| generator_api.free(allocator, config);
    if (new_game_generator_name_allocated) allocator.free(new_game_generator_name);
    new_game_preset_index = generator.defaultPresetIndex();
    new_game_config = generator.defaultConfig(allocator) orelse return error.OutOfMemory;
    new_game_generator = generator;
    new_game_generator_name = try allocator.dupe(u8, generator.info.name);
    new_game_generator_name_allocated = true;
}

fn selectNewGamePreset(allocator: std.mem.Allocator, index: usize) !void {
    const generator = new_game_generator orelse return;
    if (new_game_config) |config| generator_api.free(allocator, config);
    new_game_config = generator.presetConfig(allocator, index) orelse return error.OutOfMemory;
    new_game_preset_index = index;
}

const max_generator_dropdown_entries: usize = 16;

pub fn newGameMenu(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !bool {
    const page = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer page.deinit();

    const menu_changed: bool = if (!self.menu_state.ingame) self.sidebar() else false;

    const options = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = .{ .r = 48, .g = 77, .b = 84, .a = 225 } });
    defer options.deinit();

    try self.ensureNewGameGenerator(allocator);

    const create = dvui.button(@src(), "Create World", .{}, .{ .gravity_x = 0.5, .color_fill = .blue, .margin = .all(16), .expand = .horizontal, .padding = .{ .y = 16, .h = 16 } });

    {
        const world_name_widget = dvui.textEntry(@src(), .{ .placeholder = "World Name" }, .{ .gravity_x = 0.5 });
        defer world_name_widget.deinit();
        if (create) return try self.createWorld(io, allocator, world_name_widget.textGet());
    }

    dvui.structUI(@src(), "World", &new_game_world_config, 32, .{}, .{ .background = false, .color_fill = .transparent });

    try self.generatorDropdown(allocator);
    try self.presetDropdown(allocator);

    const scroll = dvui.scrollArea(@src(), .{ .vertical = .auto }, .{ .expand = .both });
    defer scroll.deinit();
    if (new_game_config) |config| _ = drawConfigTree(allocator, config);

    return menu_changed;
}

fn ensureNewGameGenerator(self: *@This(), allocator: std.mem.Allocator) !void {
    if (new_game_generator != null) return;
    const initial = self.generators.findByName(new_game_generator_name) orelse
        (if (self.generators.generators.items.len > 0) &self.generators.generators.items[0] else null);
    if (initial) |generator| try selectNewGameGenerator(allocator, generator);
}

fn createWorld(self: *@This(), io: std.Io, allocator: std.mem.Allocator, world_name: []const u8) !bool {
    if (world_name.len == 0) return error.WorldNameMissing;
    if (!std.unicode.utf8ValidateSlice(world_name)) return error.InvalidName;
    if (std.mem.findScalar(u8, world_name, '/') != null) return error.InvalidName;

    std.log.info("Creating world: {any}\n", .{world_name});
    var worlds_dir = try std.Io.Dir.cwd().createDirPathOpen(io, self.worlds_path, .{});
    defer worlds_dir.close(io);
    if (try worldExists(io, worlds_dir, world_name)) return error.WorldNameExists;
    var world_folder = try worlds_dir.createDirPathOpen(io, world_name, .{});
    defer world_folder.close(io);
    const game_path = try std.fs.path.join(allocator, &.{ self.worlds_path, world_name });
    defer allocator.free(game_path);
    const world_options: Game.WorldOptions = .{
        .generator_name = new_game_generator_name,
        .world_config = new_game_world_config,
    };
    try world_options.save(io, game_path);
    try saveGeneratorConfig(allocator, io, game_path);
    try self.openGame(io, allocator, game_path);
    self.menu_state.ingame = true;
    self.menu_state.newgame = false;
    return true;
}

fn worldExists(io: std.Io, dir: std.Io.Dir, name: []const u8) !bool {
    _ = std.Io.Dir.statFile(dir, io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn saveGeneratorConfig(allocator: std.mem.Allocator, io: std.Io, game_path: []const u8) !void {
    const generator = new_game_generator orelse return;
    const config = new_game_config orelse return;
    generator.api.config_set_seeds(&io, config);
    const config_dir = try std.fs.path.join(allocator, &.{ game_path, "config" });
    defer allocator.free(config_dir);
    try generator.saveConfig(allocator, io, config_dir, config);
}

fn generatorDropdown(self: *@This(), allocator: std.mem.Allocator) !void {
    if (self.generators.generators.items.len == 0) return;
    const count = @min(self.generators.generators.items.len, max_generator_dropdown_entries);
    var names_buffer: [max_generator_dropdown_entries][]const u8 = undefined;
    for (self.generators.generators.items[0..count], 0..) |*generator, i| names_buffer[i] = generator.info.name;
    const previous = self.selectedGeneratorIndex(count);
    var choice: usize = previous;
    dvui.labelNoFmt(@src(), "Generator", .{}, .{ .font = .{ .size = 24 } });
    _ = dvui.dropdown(@src(), names_buffer[0..count], .{ .choice = &choice }, .{}, .{});
    if (choice != previous) try selectNewGameGenerator(allocator, &self.generators.generators.items[choice]);
}

fn presetDropdown(self: *@This(), allocator: std.mem.Allocator) !void {
    _ = self;
    const generator = new_game_generator orelse return;
    const count = generator.presetCount();
    if (count == 0) return;
    var names_buffer: [max_generator_dropdown_entries][]const u8 = undefined;
    const n = @min(count, max_generator_dropdown_entries);
    for (0..n) |i| names_buffer[i] = generator.presetName(i);
    if (new_game_preset_index >= n) new_game_preset_index = 0;
    const previous = new_game_preset_index;
    dvui.labelNoFmt(@src(), "Preset", .{}, .{ .font = .{ .size = 24 } });
    _ = dvui.dropdown(@src(), names_buffer[0..n], .{ .choice = &new_game_preset_index }, .{}, .{});
    if (new_game_preset_index != previous) try selectNewGamePreset(allocator, new_game_preset_index);
}

fn selectedGeneratorIndex(self: *@This(), count: usize) usize {
    if (new_game_generator) |selected| {
        for (self.generators.generators.items[0..count], 0..) |*generator, i| {
            if (generator == selected) return i;
        }
    }
    return 0;
}

pub fn mainPage(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !bool {
    const menuarea = dvui.overlay(@src(), .{ .expand = .both });
    defer menuarea.deinit();
    _ = dvui.image(@src(), .{ .source = .{ .texture = self.menu_background }, .shrink = .vertical }, .{ .expand = .both });

    const page = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer page.deinit();

    var changed: bool = self.sidebar();

    const menu = dvui.box(@src(), .{}, .{ .background = false, .color_fill = .{ .r = 24, .g = 24, .b = 24, .a = 255 }, .expand = .both });
    defer menu.deinit();

    const top = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    const terrafinity = dvui.textLayout(@src(), .{ .break_lines = false }, .{ .gravity_x = 0.5, .color_fill = .transparent });
    terrafinity.addText("terrafinity", .{ .font = .{ .size = 64, .family = pixel_font } });
    terrafinity.deinit();
    top.deinit();
    changed |= try self.continueMenu(io, allocator);
    return changed;
}

pub fn sidebar(self: *@This()) bool {
    const bar = dvui.box(@src(), .{ .dir = .vertical }, .{ .background = true, .color_fill = .{ .r = 48, .g = 77, .b = 48, .a = 225 }, .expand = .vertical, .min_size_content = .width(128) });
    defer bar.deinit();

    if (dvui.button(@src(), "Home", .{}, .{ .gravity_x = 0.5, .color_fill = .blue, .margin = .all(16), .expand = .horizontal, .padding = .{ .y = 16, .h = 16 } })) {
        self.menu_state = .{ .main = true };
        return true;
    }
    if (dvui.button(@src(), "Settings", .{}, .{ .gravity_x = 0.5, .color_fill = .blue, .margin = .all(16), .expand = .horizontal, .padding = .{ .y = 16, .h = 16 } })) {
        self.menu_state = .{ .settings = true };
        return true;
    }
    if (dvui.button(@src(), "Quit", .{}, .{ .gravity_x = 0.5, .color_fill = .olive, .margin = .all(16), .expand = .horizontal, .padding = .{ .y = 16, .h = 16 } })) {
        self.running.store(false, .unordered);
        return true;
    }
    return false;
}

const FolderData = struct {
    access_time: std.Io.Timestamp,
    name: []const u8,
};

pub fn continueMenu(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !bool {
    const continue_games = dvui.scrollArea(@src(), .{
        .horizontal_bar = .show,
        .vertical = .none,
        .horizontal = .auto,
    }, .{
        .expand = .horizontal,
        .margin = .{ .w = 16, .x = 16 },
        .color_fill = .transparent,
        .min_size_content = .height(384),
    });
    defer continue_games.deinit();

    const container = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .vertical });
    defer container.deinit();

    {
        const new_game = menuCard(@src(), .{}, .{ .expand = .vertical });
        defer new_game.deinit();
        if (dvui.button(@src(), "+", .{}, .{ .expand = .both, .color_fill = .blue, .font = .{ .size = 96, .weight = .bold, .family = comptime sliceToBounded("Vera Sans", 50) } })) {
            self.menu_state = .{ .newgame = true };
            return true;
        }
    }

    var worlds_folder = try std.Io.Dir.cwd().createDirPathOpen(io, self.worlds_path, .{ .open_options = .{ .iterate = true } });
    defer worlds_folder.close(io);

    var list: std.ArrayList(FolderData) = .empty;

    defer {
        for (list.items) |data| {
            allocator.free(data.name);
        }
        list.deinit(allocator);
    }

    var it = worlds_folder.iterate();
    while (try it.next(io)) |item| {
        if (item.kind != .directory) continue;
        const stat = try std.Io.Dir.statFile(worlds_folder, io, item.name, .{});
        const data = FolderData{ .access_time = stat.ctime, .name = try allocator.dupe(u8, item.name) };
        errdefer allocator.free(data.name);
        try list.append(allocator, data);
    }

    std.sort.pdq(FolderData, list.items, {}, lessThanFn);

    for (list.items, 0..) |item, i| {
        const game = menuCard(@src(), .{}, .{ .id_extra = i, .expand = .vertical });
        defer game.deinit();

        const text = dvui.textLayout(@src(), .{}, .{ .gravity_x = 0.5 });
        text.addText(item.name, .{ .font = .{ .family = pixel_font } });
        text.deinit();
        if (dvui.button(@src(), "Play", .{}, .{ .gravity_x = 0.5, .gravity_y = 1.0, .expand = .horizontal, .margin = .{ .x = 64, .w = 64 }, .font = .{ .family = pixel_font }, .color_fill = .blue })) {
            std.log.info("Joining game: {s}", .{item.name});
            const jpath = try std.fs.path.join(allocator, &.{ self.worlds_path, item.name });
            defer allocator.free(jpath);
            try self.openGame(io, allocator, jpath);
            self.menu_state.ingame = true;
            self.menu_state.main = false;
            return true;
        }
    }
    return false;
}

fn lessThanFn(_: void, a: FolderData, b: FolderData) bool {
    return a.access_time.nanoseconds > b.access_time.nanoseconds;
}

fn openGame(self: *@This(), io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    self.vk_ctx.swapchain_gamma.store(self.config.game_config.render_options.gamma_correction, .monotonic);
    try self.game.init(io, allocator, &self.config.game_config, self.config_lock, path, self.vk_ctx, self.generators);
    std.log.info("opening game\n", .{});
}

fn calculateWidget(widget: *dvui.BoxWidget) void {
    widget.data().register();
    widget.child_rect = widget.data().contentRect().justSize();
    if (widget.data_prev) |dp| {
        if (widget.init_opts.equal_space) {
            if (dp.packed_children > 0) {
                switch (widget.init_opts.dir) {
                    .horizontal => widget.pixels_per_w = widget.child_rect.w / dp.packed_children,
                    .vertical => widget.pixels_per_w = widget.child_rect.h / dp.packed_children,
                }
            }
        } else {
            var packed_weight = dp.total_weight;
            if (widget.init_opts.num_packed_expanded) |num| {
                packed_weight = @floatFromInt(num);
            }
            if (packed_weight > 0) {
                switch (widget.init_opts.dir) {
                    .horizontal => widget.pixels_per_w = @max(0, widget.child_rect.w - dp.min_space_taken) / packed_weight,
                    .vertical => widget.pixels_per_w = @max(0, widget.child_rect.h - dp.min_space_taken) / packed_weight,
                }
            }
        }
    }
}

fn hovered(wd: *const dvui.WidgetData, opts: HoverOptions) bool {
    const hover_rect = opts.rect orelse wd.borderRectScale().r;
    for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = wd.id, .r = hover_rect })) continue;
        if (e.evt != .mouse or e.evt.mouse.action != .position) continue;
        if (opts.hover_cursor) |cursor| dvui.cursorSet(cursor);
        return true;
    }
    return false;
}

fn drawConfigTree(allocator: std.mem.Allocator, tree: *generator_api.ConfigTree) bool {
    const before = tree.*;
    var id_counter: usize = 0;
    const box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer box.deinit();
    drawParams(allocator, &tree.params, &id_counter);
    return !generator_api.eql(&before, tree);
}

fn drawParams(allocator: std.mem.Allocator, params: *[]generator_api.Param, id_counter: *usize) void {
    for (params.*) |*param| drawParam(allocator, param, id_counter);
}

fn drawParam(allocator: std.mem.Allocator, param: *generator_api.Param, id_counter: *usize) void {
    const id = id_counter.*;
    id_counter.* += 1;
    switch (param.value) {
        .group => |*group| {
            const box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .id_extra = id });
            defer box.deinit();
            configHeading(param.name, id);
            drawParams(allocator, &group.params, id_counter);
        },
        .array => |*array| drawArray(allocator, param.name, array, id),
        .f32 => configSliderF32(param.name, &param.value.f32, param.spec, id),
        .i32 => configSliderInt(param.name, &param.value.i32, param.spec, id),
        .u32 => configSliderUInt(param.name, &param.value.u32, param.spec, id),
        .u64 => configTextU64(param.name, &param.value.u64, id),
        .bool => _ = dvui.checkbox(@src(), &param.value.bool, param.name, .{ .id_extra = id }),
        .string => configTextString(allocator, param.name, &param.value.string, id),
        .choice => configChoiceDropdown(param.name, param.spec, &param.value.choice, id),
    }
}

fn drawArray(allocator: std.mem.Allocator, name: []const u8, array: *generator_api.Array, id: usize) void {
    configHeading(name, id);
    for (array.items, 0..) |*item, i| {
        const item_id = id + i * 2 + 1;
        const box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .id_extra = item_id });
        defer box.deinit();
        if (item.value == .group) {
            var inner_id: usize = item_id;
            drawParams(allocator, &item.value.group.params, &inner_id);
        }
        if (dvui.button(@src(), "remove", .{}, .{ .id_extra = item_id + 1 })) generator_api.arrayRemove(allocator, array, i);
    }
    if (dvui.button(@src(), "add", .{}, .{ .id_extra = id + 100000 })) generator_api.arrayAdd(allocator, array) catch {};
}

fn configHeading(text: []const u8, id: usize) void {
    dvui.labelNoFmt(@src(), text, .{}, .{ .font = .{ .size = 24 }, .id_extra = id });
}

fn configSlider(name: []const u8, value: *f32, spec: generator_api.Spec, default_min: f64, default_max: f64, id: usize) bool {
    dvui.labelNoFmt(@src(), name, .{}, .{ .id_extra = id });
    const min: f32 = @floatCast(spec.min orelse default_min);
    const max: f32 = @floatCast(spec.max orelse default_max);
    const step: ?f32 = if (spec.step) |s| @floatCast(s) else null;
    return dvui.sliderEntry(@src(), null, .{ .value = value, .min = min, .max = max, .interval = step }, .{ .id_extra = id });
}

fn configSliderF32(name: []const u8, value: *f32, spec: generator_api.Spec, id: usize) void {
    _ = configSlider(name, value, spec, 0, 1, id);
}

fn configSliderInt(name: []const u8, value: *i32, spec: generator_api.Spec, id: usize) void {
    var float_value: f32 = @floatFromInt(value.*);
    if (configSlider(name, &float_value, spec, -100, 100, id)) value.* = @intFromFloat(float_value);
}

fn configSliderUInt(name: []const u8, value: *u32, spec: generator_api.Spec, id: usize) void {
    var float_value: f32 = @floatFromInt(value.*);
    if (configSlider(name, &float_value, spec, 0, 100, id) and float_value >= 0) value.* = @intFromFloat(float_value);
}

fn configTextU64(name: []const u8, value: *u64, id: usize) void {
    var buffer: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&buffer, "{d}", .{value.*}) catch unreachable;
    var widget = dvui.textEntry(@src(), .{ .text = .{ .buffer = &buffer }, .placeholder = name }, .{ .id_extra = id });
    defer widget.deinit();
    const parsed = std.fmt.parseUnsigned(u64, widget.textGet(), 10) catch return;
    value.* = parsed;
}

fn configTextString(allocator: std.mem.Allocator, name: []const u8, value: *[]const u8, id: usize) void {
    var buffer: [256]u8 = undefined;
    const cur_len = @min(value.len, buffer.len - 1);
    @memcpy(buffer[0..cur_len], value.*[0..cur_len]);
    buffer[cur_len] = 0;
    var widget = dvui.textEntry(@src(), .{ .text = .{ .buffer = &buffer }, .placeholder = name }, .{ .id_extra = id });
    defer widget.deinit();
    const text = widget.textGet();
    if (std.mem.eql(u8, value.*, text)) return;
    if (allocator.dupe(u8, text)) |new_value| {
        if (value.len > 0) allocator.free(value.*);
        value.* = new_value;
    } else |_| {}
}

fn configChoiceDropdown(name: []const u8, spec: generator_api.Spec, choice: *usize, id: usize) void {
    dvui.labelNoFmt(@src(), name, .{}, .{ .id_extra = id });
    if (choice.* >= spec.entries.len and spec.entries.len > 0) choice.* = 0;
    _ = dvui.dropdown(@src(), spec.entries, .{ .choice = choice }, .{}, .{ .id_extra = id });
}

const HoverOptions = struct {
    hover_cursor: ?dvui.enums.Cursor = .hand,
    rect: ?dvui.Rect.Physical = null,
};
