const std = @import("std");

const dvui = @import("dvui");
const tracy = @import("tracy");
const vk = @import("vulkan");
const wio = @import("wio");
const zignal = @import("zignal");

const Config = @import("main.zig").Config;
const EntityRegistry = @import("entity/EntityRegistry.zig");
const EntityTypes = @import("entity/EntityTypes.zig");
const Item = @import("entity/Item.zig");
const Game = @import("Game.zig");
const utils = @import("libs/utils.zig");
const ShadowConfig = @import("Renderer/vulkan/shadow/Csm.zig").ShadowConfig;
const SkyConfig = @import("Renderer/vulkan/sky/SkyRenderer.zig").SkyConfig;
const Renderer = @import("Renderer.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const Screenshot = @import("Screenshot.zig");
const generator_loader = @import("world/generator_loader.zig");
const generator_api = @import("world/generators/generator_api.zig");
const World = @import("world/World.zig");

const press_start_2p: []const u8 = @embedFile("assets/press-start-2p/PressStart2P.ttf");
const menu_background_image: []const u8 = @embedFile("assets/terrain.png");
const pixel_font = sliceToBounded("Press Start 2P", 50);
const Ui = @This();

const NewGameState = struct {
    world_config: World.WorldConfig = .{},
    spawn_config: EntityRegistry.SpawnConfig = .{},
    generator_name: []const u8 = "Terrain",
    generator_name_allocated: bool = false,
    generator: ?*generator_loader.Generator = null,
    config: ?*generator_api.ConfigTree = null,
    preset_index: usize = 0,
};

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
        .corner = .round(5),
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

window: *wio.Window,
vk_ctx: *VulkanContext,
config: *Config,
config_lock: *std.Io.RwLock,
game: *Game,
generators: *generator_loader.Registry,
config_path: []const u8,
worlds_path: []const u8,
menu_background: dvui.Texture,
/// One icon per item type, null when the pack has no file (draw the missing texture).
hotbar_item_textures: std.enums.EnumArray(Item.ItemType, ?dvui.Texture) = .initFill(null),
hotbar_missing_texture: ?dvui.Texture = null,
ui_window: *dvui.Window,
running: *std.atomic.Value(bool),
config_section_states: std.AutoHashMap(u64, bool),
new_game: NewGameState = .{},

/// World awaiting deletion confirmation, owned by the Ui allocator.
delete_world_name: ?[]const u8 = null,
terrain_recreate_error: ?[]const u8 = null,
world_list: std.ArrayList(FolderData) = .empty,
world_list_dirty: bool = true,

menu_state: struct {
    ingame: bool = false,
    debug_info: bool = true,
    settings: bool = false,
    main: bool = false,
    esc: bool = false,
    newgame: bool = false,
    crosshair: bool = true,

    pending_game_deinit: bool = false,
    pending_world_recreate: bool = false,
    terrain_developer_settings: bool = false,

    /// Reports whether gameplay input is active. Every menu is drawn full-screen over
    /// the game view, so an open one takes the input the player would otherwise get.
    pub fn is_playing_game(self: @This()) bool {
        const menu_open = self.settings or self.main or self.esc or self.newgame;
        return self.ingame and !menu_open;
    }

    pub fn handle_esc(self: *@This()) void {
        if (self.ingame) self.*.esc = !self.*.esc;
        self.settings = false;
    }
},

/// RGBA texture upload shared by the background and item icons.
fn createTexture(self: *@This(), pixels: [*]const u8, width: u32, height: u32, interpolation: dvui.enums.TextureInterpolation) !dvui.Texture {
    return self.ui_window.backend.textureCreate(pixels, .{
        .width = width,
        .height = height,
        .format = .rgba_32,
        .interpolation = interpolation,
    });
}

pub fn initAssets(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    var image = try zignal.Image(zignal.Rgba(u8)).loadFromBytes(allocator, menu_background_image);
    defer image.deinit(allocator);
    self.menu_background = try self.createTexture(@ptrCast(image.asBytes().ptr), @intCast(image.cols), @intCast(image.rows), .linear);
    try self.loadItemTextures(io, allocator);
}

/// Loads `packs/<pack>/items/<ItemType>.png`. A missing or undecodable file falls
/// back to the 1x1 magenta missing texture, so dropping a file in just works.
fn loadItemTextures(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    const selected_pack = self.config.game_config.render_options.selected_pack;
    const pack = try utils.openPackDir(io, allocator, selected_pack, "items");
    defer allocator.free(pack.path);
    defer pack.dir.close(io);

    const missing_pixels: [4]u8 = .{ 255, 0, 255, 255 };
    self.hotbar_missing_texture = try self.createTexture(@ptrCast(&missing_pixels), 1, 1, .nearest);

    inline for (std.meta.fields(Item.ItemType)) |field| {
        const item_type: Item.ItemType = @enumFromInt(field.value);
        const filename = try std.fmt.allocPrint(allocator, "{s}.png", .{field.name});
        defer allocator.free(filename);
        self.hotbar_item_textures.getPtr(item_type).* = try self.loadItemTexture(io, allocator, pack.dir, filename);
    }
}

fn loadItemTexture(self: *@This(), io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, filename: []const u8) !?dvui.Texture {
    const file = dir.openFile(io, filename, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(bytes);
    var buf: [1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    try reader.interface.readSliceAll(bytes);

    var image = zignal.Image(zignal.Rgba(u8)).loadFromBytes(allocator, bytes) catch |err| {
        std.log.warn("hotbar: could not decode items/{s}: {any}", .{ filename, err });
        return null;
    };
    defer image.deinit(allocator);

    return try self.createTexture(@ptrCast(image.asBytes().ptr), @intCast(image.cols), @intCast(image.rows), .nearest);
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.ui_window.backend.textureDestroy(self.menu_background);
    for (&self.hotbar_item_textures.values) |*texture| {
        if (texture.*) |t| self.ui_window.backend.textureDestroy(t);
    }
    if (self.hotbar_missing_texture) |t| self.ui_window.backend.textureDestroy(t);
    if (self.new_game.config) |config| generator_api.free(allocator, config);
    if (self.new_game.generator_name_allocated) allocator.free(self.new_game.generator_name);
    if (self.delete_world_name) |name| allocator.free(name);
    self.config_section_states.deinit();
    for (self.world_list.items) |entry| allocator.free(entry.name);
    self.world_list.deinit(allocator);
    self.new_game = .{};
    self.delete_world_name = null;
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
        error.GeneratorSpawnFailed => error_writer.print("The generator could not find a safe spawn point.", .{}) catch unreachable,
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

        if (self.terrain_recreate_error) |message| {
            dvui.dialog(@src(), frame_time, .{
                .message = message,
                .title = "Terrain recreation failed",
            });
            self.terrain_recreate_error = null;
        }

        if (self.menu_state.debug_info and self.menu_state.ingame and !menu_changed) self.debugInfo(io) catch |err| {
            std.log.err("debugInfo failed: {}", .{err});
        };
        if (self.menu_state.crosshair and self.menu_state.ingame and !menu_changed) self.crossHair();
        if (self.menu_state.ingame and !menu_changed) self.hotbar(io);
        if (self.menu_state.esc and !menu_changed) menu_changed = self.escMenu(io) catch false;
        if (self.menu_state.main and !menu_changed) menu_changed = self.mainPage(io, gpa) catch |err| blk: {
            showWorldError(frame_time, err);
            break :blk false;
        };
        if (self.menu_state.settings and !menu_changed) menu_changed = self.settingsMenu(io, gpa) catch false;
        if (self.menu_state.newgame and !menu_changed) menu_changed = self.newGameMenu(io, gpa) catch |err| blk: {
            showWorldError(frame_time, err);
            break :blk false;
        };
        if (self.menu_state.ingame and self.menu_state.terrain_developer_settings) self.drawTerrainDeveloperSettings(io, gpa);
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

    // Copy the frame for the screenshot before the image transitions to present.
    if (self.vk_ctx.screenshot_requested.load(.acquire)) {
        self.vk_ctx.screenshot_requested.store(false, .release);
        self.vk_ctx.recordScreenshotCopyFromColorAttachment(cmd, image, extent) catch |err| {
            std.log.err("Screenshot copy recording failed: {any}", .{err});
            VulkanContext.transitionImageLayout(self.vk_ctx.dev, cmd, image, .color_attachment_optimal, .present_src_khr);
            self.vk_ctx.swapchain_image_layouts[image_index] = .present_src_khr;
        };
        // Both branches above leave the image in present layout, so this only records it.
        if (self.vk_ctx.screenshot_pending_save) {
            self.vk_ctx.swapchain_image_layouts[image_index] = .present_src_khr;
        }
    } else {
        VulkanContext.transitionImageLayout(self.vk_ctx.dev, cmd, image, .color_attachment_optimal, .present_src_khr);
        self.vk_ctx.swapchain_image_layouts[image_index] = .present_src_khr;
    }
    try self.vk_ctx.dev.endCommandBuffer(cmd);
}

fn menuCard(src: std.builtin.SourceLocation, init_opts: dvui.BoxWidget.InitOptions, opts: dvui.Options) *dvui.BoxWidget {
    var options: dvui.Options = .{
        .min_size_content = .all(256),
        .color_fill = .{ .r = 48, .g = 48, .b = 48, .a = 255 },
        .background = true,
        .corners = .all(0),
        .border = .all(8),
        .margin = .all(16),
        .gravity_y = 0.5,
        .color_border = .{ .r = 48, .g = 77, .b = 48, .a = 225 },
    };
    var card = dvui.widgetAlloc(dvui.BoxWidget);
    card.init(src, init_opts, options.override(opts));
    if (hovered(card.data(), .{})) {
        card.data().options.margin = .all(0);
        calculateWidget(card);
    }
    card.drawBackground();
    return card;
}

/// Centered, fixed-width column shared by the settings and new-game pages.
fn pageContent(id_extra: usize) *dvui.BoxWidget {
    return dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .id_extra = id_extra,
        .max_size_content = .width(960),
        .gravity_x = 0.5,
        .padding = .{ .x = 24, .w = 24, .y = 16, .h = 16 },
    });
}

pub fn escMenu(self: *@This(), io: std.Io) !bool {
    _ = io;
    std.debug.assert(self.menu_state.ingame);
    const button_width: f32 = 640 * 0.75;
    const menu = dvui.box(@src(), .{}, .{ .background = true, .color_fill = .{ .r = 0, .g = 200, .b = 200, .a = 150 }, .expand = .both });
    defer menu.deinit();
    if (dvui.button(@src(), "Back To Game", .{}, .{ .min_size_content = .width(button_width), .gravity_x = 0.5 })) {
        self.menu_state.esc = false;
        return true;
    }

    if (dvui.button(@src(), "Settings", .{}, .{ .min_size_content = .width(button_width), .gravity_x = 0.5 })) {
        self.menu_state.settings = true;
        self.menu_state.esc = false;
        return true;
    }

    if (dvui.button(@src(), "Quit", .{}, .{ .min_size_content = .width(button_width), .gravity_x = 0.5 })) {
        self.menu_state.main = true;
        self.menu_state.esc = false;
        self.menu_state.ingame = false;
        self.menu_state.pending_game_deinit = true;
        // External changes may add or remove worlds, so refresh the list on entry.
        self.world_list_dirty = true;
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

    const total = chunk_hits + chunk_misses;
    const chunk_hit_ratio: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(chunk_hits)) / @as(f32, @floatFromInt(total));
    const player_pos = self.game.getPlayerPos(io);
    const pos: @Vector(3, i64) = @intFromFloat(@round(player_pos));
    const spawn: @Vector(3, i64) = @intFromFloat(@round(self.game.spawn.pos));
    const str = try std.fmt.bufPrint(
        &fmt_buffer,
        \\FPS: {d}
        \\meshes loaded: {d}
        \\opaque drawn: {d}
        \\transparent drawn: {d}
        \\occluded: {d}
        \\frustum culled: {d}
        \\opaque faces: {d}
        \\transparent faces: {d}
        \\pos: {d}, {d}, {d}
        \\spawn: {d}, {d}, {d}
        \\chunks cached: {d}
        \\grids cached: {d}
        \\entities cached: {d}
        \\chunk hit ratio: {d:.2}
    ,
        .{
            @trunc(self.game.debug_menu.fps.load(.unordered)),
            self.game.debug_menu.meshes.load(.unordered),
            self.game.debug_menu.opaque_drawn.load(.unordered),
            self.game.debug_menu.transparent_drawn.load(.unordered),
            self.game.debug_menu.occluded.load(.unordered),
            self.game.debug_menu.frustum_culled.load(.unordered),
            self.game.debug_menu.opaque_faces.load(.unordered),
            self.game.debug_menu.transparent_faces.load(.unordered),
            pos[0],
            pos[1],
            pos[2],
            spawn[0],
            spawn[1],
            spawn[2],
            chunk_count,
            grid_count,
            self.game.debug_menu.entities.load(.unordered),
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

pub fn settingsMenu(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !bool {
    const page = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer page.deinit();

    const menu_changed: bool = if (!self.menu_state.ingame) self.sidebar() else false;
    const settings = dvui.scrollArea(@src(), .{ .vertical_bar = .auto }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .r = 48, .g = 77, .b = 84, .a = 225 },
    });
    defer settings.deinit();

    const content = pageContent(0);
    defer content.deinit();

    if (self.menu_state.ingame) {
        const game_mode_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .padding = .{ .y = 4, .h = 4 } });
        defer game_mode_row.deinit();
        dvui.labelNoFmt(@src(), "Game Mode", .{}, .{ .gravity_y = 0.5, .padding = .{ .x = 8, .w = 8 } });
        var game_mode: EntityTypes.Player.GameMode = self.game.player.game_mode.load(.monotonic);
        _ = dvui.dropdownEnum(
            @src(),
            EntityTypes.Player.GameMode,
            .{ .choice = &game_mode },
            .{ .null_selectable = false },
            .{},
        );
        self.game.player.switchGameMode(game_mode);
    }

    try self.config_lock.lock(io);
    const first_config = self.config.*;
    self.config_lock.unlock(io);

    var working_config = first_config;
    working_config.game_config.render_options.selected_pack = try allocator.dupe(u8, first_config.game_config.render_options.selected_pack);
    const options = &working_config.game_config;

    dvui.labelNoFmt(@src(), "Settings", .{}, .{ .font = .{ .size = 28 }, .gravity_x = 0.5 });
    drawGeneralSettings(self, options);
    drawRenderSettings(self, allocator, options);

    if (self.menu_state.ingame and dvui.button(@src(), "Terrain Developer Settings", .{}, .{
        .gravity_x = 0.5,
        .expand = .none,
        .padding = .{ .x = 6, .w = 6, .y = 4, .h = 4 },
        .margin = .{ .y = 8 },
        .font = .{ .size = 10 },
        .color_fill = .{ .r = 44, .g = 77, .b = 44, .a = 255 },
    })) {
        self.menu_state.terrain_developer_settings = true;
    }

    normalizeSettings(options);

    // eql matches slices by pointer, so share the pack slice and compare its content separately.
    var working_no_pack = working_config;
    working_no_pack.game_config.render_options.selected_pack = first_config.game_config.render_options.selected_pack;
    const config_changed = !std.meta.eql(first_config, working_no_pack) or !std.mem.eql(u8, first_config.game_config.render_options.selected_pack, working_config.game_config.render_options.selected_pack);
    const gamma_changed = first_config.game_config.render_options.gamma_correction != options.render_options.gamma_correction;
    const present_mode_changed = first_config.game_config.render_options.present_mode != options.render_options.present_mode;
    const aa_changed = first_config.game_config.render_options.anti_aliasing != options.render_options.anti_aliasing;
    if (config_changed) {
        // The working pack moves into config below; free it if the lock path exits early.
        errdefer allocator.free(working_config.game_config.render_options.selected_pack);
        try self.config_lock.lock(io);
        allocator.free(self.config.game_config.render_options.selected_pack);
        self.config.* = working_config;
        self.config_lock.unlock(io);
    } else allocator.free(working_config.game_config.render_options.selected_pack);

    if (gamma_changed or present_mode_changed or aa_changed) {
        self.vk_ctx.requestSwapchainRecreate();
    }

    if (config_changed) try self.config.save(io, self.config_path, self.config_lock);
    return menu_changed;
}

const settings_root_id: u64 = 0x73657474696e6773;

fn settingsId(path: []const u8) u64 {
    return configId(settings_root_id, path);
}

fn toggleConfigSection(self: *@This(), src: std.builtin.SourceLocation, title: []const u8, id: u64, expanded: bool) bool {
    const toggled = dvui.button(src, title, .{}, .{
        .expand = .horizontal,
        .id_extra = @intCast(id),
        .color_fill = .{ .r = 44, .g = 77, .b = 44, .a = 255 },
        .margin = .{ .y = 8 },
        .padding = .{ .y = 8, .h = 8 },
    });
    if (!toggled) return false;
    self.config_section_states.put(id, !expanded) catch |err| std.log.warn("Ui: config section state store failed: {any}", .{err});
    return true;
}

/// Indented, framed container for a config section or array item.
fn configBox(src: std.builtin.SourceLocation, id: u64, color_fill: dvui.Color, padding: dvui.Rect) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .id_extra = @intCast(id),
        .background = true,
        .color_fill = color_fill,
        .margin = .{ .x = 12, .w = 12 },
        .padding = padding,
    });
}

fn settingsSection(self: *@This(), src: std.builtin.SourceLocation, label: []const u8, id: u64, default_open: bool) ?*dvui.BoxWidget {
    const expanded = self.config_section_states.get(id) orelse default_open;
    var title_buffer: [260]u8 = undefined;
    const title = configSectionTitle(label, expanded, &title_buffer);
    if (self.toggleConfigSection(@src(), title, id, expanded)) return null;
    if (!expanded) return null;
    return configBox(src, id, .{ .r = 24, .g = 40, .b = 28, .a = 255 }, .{ .x = 16, .w = 16, .y = 8, .h = 8 });
}

fn settingsSlider(name: []const u8, value: anytype, min: f64, max: f64, id: u64) void {
    var float_value: f32 = @floatFromInt(value.*);
    if (!configSlider(name, &float_value, .{}, min, max, id)) return;
    if (@typeInfo(@TypeOf(value.*)).int.signedness == .unsigned and float_value < 0) return;
    value.* = @intFromFloat(float_value);
}

fn settingsInterval(name: []const u8, value: *u64, id: u64) void {
    configTextU64(name, value, id);
    value.* = @max(value.*, 1);
}

fn settingsCheckbox(label: []const u8, value: *bool, id: u64) void {
    const row = configRow(label, id);
    defer row.deinit();
    _ = dvui.checkbox(@src(), value, "", .{ .id_extra = @intCast(configId(id, "value")) });
}

fn settingsEnum(label: []const u8, comptime T: type, value: *T, id: u64) void {
    const row = configRow(label, id);
    defer row.deinit();
    _ = dvui.dropdownEnum(@src(), T, .{ .choice = value }, .{ .null_selectable = false }, .{
        .id_extra = @intCast(configId(id, "value")),
        .expand = .horizontal,
    });
}

fn settingsSubheading(label: []const u8, id: u64) void {
    dvui.labelNoFmt(@src(), label, .{}, .{
        .id_extra = @intCast(id),
        .font = .{ .size = 16 },
        .padding = .{ .y = 8, .h = 2 },
    });
}

fn settingsComponents(label: []const u8, names: []const []const u8, values: []f32, min: f64, max: f64, id: u64) void {
    for (values, names) |*value, name| {
        var label_buffer: [96]u8 = undefined;
        const component_label = std.fmt.bufPrint(&label_buffer, "{s} {s}", .{ label, name }) catch unreachable;
        _ = configSlider(component_label, value, .{}, min, max, configId(id, name));
    }
}

fn settingsColor(label: []const u8, color: *[4]f32, id: u64) void {
    settingsComponents(label, &.{ "Red", "Green", "Blue", "Alpha" }, color, 0, 1, id);
}

fn settingsVector(label: []const u8, vector: *[4]f32, id: u64) void {
    settingsComponents(label, &.{ "X", "Y", "Z" }, vector[0..3], -1, 1, id);
}

fn drawAdvancedSkySettings(sky: *SkyConfig, root_id: u64) void {
    settingsSubheading("Sky Colors", configId(root_id, "colors"));
    settingsColor("Sun Color", &sky.sun_color, configId(root_id, "sun_color"));
    settingsColor("Sun Glow Color", &sky.sun_glow_color, configId(root_id, "sun_glow_color"));
    settingsColor("Moon Color", &sky.moon_color, configId(root_id, "moon_color"));
    settingsColor("Zenith Color", &sky.zenith_color, configId(root_id, "zenith_color"));
    settingsColor("Horizon Color", &sky.horizon_color, configId(root_id, "horizon_color"));
    settingsColor("Ground Color", &sky.ground_color, configId(root_id, "ground_color"));
    settingsColor("Sun Scattering Color", &sky.sun_scatter, configId(root_id, "sun_scatter"));

    settingsSubheading("Moon", configId(root_id, "moon"));
    _ = configSlider("Moon Size", &sky.moon_angular_radius, .{}, 0, 0.2, configId(root_id, "moon_angular_radius"));
    _ = configSlider("Moon Phase", &sky.moon_phase, .{}, 0, 1, configId(root_id, "moon_phase"));

    settingsSubheading("Distant Planets", configId(root_id, "planets"));
    for (&sky.planet_dirs, &sky.planet_colors, &sky.planet_radii, 0..) |*direction, *color, *radius, i| {
        const planet_id = configIndexId(configId(root_id, "planet"), i);
        var label_buffer: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "Planet {d}", .{i + 1}) catch unreachable;
        settingsSubheading(label, planet_id);
        settingsVector("Direction", direction, configId(planet_id, "direction"));
        settingsColor("Color", color, configId(planet_id, "color"));
        _ = configSlider("Size", radius, .{}, 0, 0.2, configId(planet_id, "radius"));
    }

    settingsSubheading("Star Field", configId(root_id, "stars"));
    _ = configSlider("Star Pattern Seed", &sky.star_seed, .{}, 0, 1000, configId(root_id, "star_seed"));
}

const ShadowDepthFormat = @TypeOf(@as(ShadowConfig, undefined).depth_format);

fn drawAdvancedShadowSettings(shadow: *ShadowConfig, root_id: u64) void {
    settingsSubheading("Cascade Distribution", configId(root_id, "distribution"));
    settingsEnum("Depth Format", ShadowDepthFormat, &shadow.depth_format, configId(root_id, "depth_format"));
    _ = configSlider("Distribution Balance", &shadow.pssm_lambda, .{}, 0, 1, configId(root_id, "pssm_lambda"));
    _ = configSlider("Nearest Cascade Radius", &shadow.min_split_radius, .{}, 1, 1000, configId(root_id, "min_split_radius"));
    settingsSlider("Cascades Per Frame", &shadow.cascades_per_frame, 1, 16, configId(root_id, "cascades_per_frame"));

    settingsSubheading("Refresh Schedule", configId(root_id, "refresh"));
    _ = configSlider("Refresh Distribution", &shadow.refresh_lambda, .{}, 0, 1, configId(root_id, "refresh_lambda"));
    settingsSlider("Nearest Refresh (frames)", &shadow.min_refresh_frames, 1, 4096, configId(root_id, "min_refresh_frames"));
    settingsSlider("Farthest Refresh (frames)", &shadow.max_refresh_frames, 1, 16384, configId(root_id, "max_refresh_frames"));

    settingsSubheading("Shadow Filtering", configId(root_id, "filtering"));
    _ = configSlider("Cascade Blend", &shadow.cascade_blend, .{}, 0, 1, configId(root_id, "cascade_blend"));
    _ = configSlider("Outer Fade", &shadow.last_cascade_fade, .{}, 0, 1, configId(root_id, "last_cascade_fade"));
    _ = configSlider("Blur Radius (blocks)", &shadow.blur_radius, .{}, 0, 32, configId(root_id, "blur_radius"));
    _ = configSlider("Normal Bias", &shadow.normal_bias_scale, .{}, 0, 16, configId(root_id, "normal_bias_scale"));

    settingsSubheading("Shadow Bias", configId(root_id, "bias"));
    _ = configSlider("Constant Bias", &shadow.depth_bias_constant, .{}, -16, 16, configId(root_id, "depth_bias_constant"));
    _ = configSlider("Slope Bias", &shadow.depth_bias_slope, .{}, -16, 16, configId(root_id, "depth_bias_slope"));
    _ = configSlider("Bias Clamp", &shadow.depth_bias_clamp, .{}, 0, 16, configId(root_id, "depth_bias_clamp"));

    settingsSubheading("Advanced Limits", configId(root_id, "limits"));
    _ = configSlider("Minimum Sun Elevation (degrees)", &shadow.min_sun_elevation_deg, .{}, 0, 45, configId(root_id, "min_sun_elevation_deg"));
    _ = configSlider("Maximum Depth Range", &shadow.max_depth_range, .{}, 1, 131072, configId(root_id, "max_depth_range"));
    _ = configSlider("Minimum Chunk Size (texels)", &shadow.min_chunk_texels, .{}, 0, 16, configId(root_id, "min_chunk_texels"));
}

fn drawTerrainDeveloperSettings(self: *@This(), io: std.Io, allocator: std.mem.Allocator) void {
    var open = true;
    const window = dvui.floatingWindow(
        @src(),
        .{ .modal = false, .resize = .none, .open_flag = &open },
        .{ .max_size_content = .{ .w = 760, .h = 720 } },
    );
    defer window.deinit();

    window.dragAreaSet(dvui.windowHeader("Terrain Developer Settings", "", &open));
    if (!open) {
        self.menu_state.terrain_developer_settings = false;
        return;
    }

    const contents = dvui.scrollArea(@src(), .{ .vertical_bar = .auto }, .{ .expand = .both });
    defer contents.deinit();

    {
        const warning = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .r = 96, .g = 24, .b = 24, .a = 255 },
            .border = .all(4),
            .color_border = .red,
            .padding = .{ .x = 16, .w = 16, .y = 12, .h = 12 },
            .margin = .{ .y = 8 },
        });
        defer warning.deinit();

        dvui.labelNoFmt(@src(), "WARNING: THIS WILL DELETE THE WORLD", .{}, .{
            .font = .{ .size = 18 },
            .color_fill = .white,
            .gravity_x = 0.5,
        });
        dvui.labelNoFmt(@src(), "Recreating the terrain permanently deletes this world's saved chunks and regenerates them from the settings below.", .{}, .{
            .color_fill = .white,
            .gravity_x = 0.5,
            .padding = .{ .y = 8, .h = 8 },
        });
    }

    if (self.game.generator) |*generator| {
        dvui.labelNoFmt(@src(), generator.generator.info.name, .{}, .{ .font = .{ .size = 20 }, .gravity_x = 0.5 });
        if (generator.generator.info.description.len > 0) {
            dvui.labelNoFmt(@src(), generator.generator.info.description, .{}, .{ .gravity_x = 0.5, .padding = .{ .y = 4, .h = 8 } });
        }
        drawConfigTree(self, allocator, generator.config);
    } else {
        dvui.labelNoFmt(@src(), "No generator is loaded.", .{}, .{ .gravity_x = 0.5 });
    }

    if (self.game.spawn.found) {
        dvui.labelNoFmt(@src(), "World spawn is set. Clearing it re-picks on the next world load.", .{}, .{ .gravity_x = 0.5, .padding = .{ .y = 4, .h = 4 } });
    }
    if (dvui.button(@src(), "Reset World Spawn", .{}, .{
        .expand = .horizontal,
        .margin = .{ .y = 4 },
        .padding = .{ .y = 12, .h = 12 },
    })) {
        self.game.spawn.pos = .{ 0, 0, 0 };
        self.game.spawn.found = false;
        const opts = Game.WorldOptions{
            .generator_name = if (self.game.generator) |*generator| generator.generator.info.name else "Terrain",
            .world_config = self.game.world.config,
            .spawn = self.game.spawn,
        };
        opts.save(io, self.game.world_path) catch |err|
            std.log.err("reset world spawn failed to save: {any}", .{err});
    }
    if (dvui.button(@src(), "Recreate World", .{}, .{
        .expand = .horizontal,
        .color_fill = .red,
        .margin = .{ .y = 12 },
        .padding = .{ .y = 12, .h = 12 },
    })) {
        self.menu_state.pending_world_recreate = true;
    }
    if (dvui.button(@src(), "Close", .{}, .{ .gravity_x = 0.5, .margin = .{ .y = 8 } })) {
        self.menu_state.terrain_developer_settings = false;
    }
}

fn drawGeneralSettings(self: *@This(), options: *Game.Options) void {
    if (self.settingsSection(@src(), "Controls", settingsId("controls"), true)) |section| {
        defer section.deinit();
        _ = configSlider("Mouse Sensitivity", &options.mouse_sensitivity, .{}, 0, 5, settingsId("controls.mouse_sensitivity"));
        _ = configSlider("Scroll Sensitivity", &options.scroll_sensitivity, .{}, 0, 5, settingsId("controls.scroll_sensitivity"));
    }

    if (self.settingsSection(@src(), "Player", settingsId("player"), true)) |section| {
        defer section.deinit();
        _ = configSlider("Width (blocks)", &options.player_width, .{}, 0.2, 8, settingsId("player.width"));
        _ = configSlider("Height (blocks)", &options.player_height, .{}, 1, 16, settingsId("player.height"));
        _ = configSlider("Step Height (blocks)", &options.step_height, .{}, 0, 4, settingsId("player.step_height"));
        _ = configSlider("Step Climb Speed (blocks/s)", &options.step_climb_speed, .{}, 1, 64, settingsId("player.step_climb_speed"));
        _ = configSlider("Jump Height (blocks)", &options.jump_height, .{}, 0, 8, settingsId("player.jump_height"));
        _ = configSlider("Movement Speed (blocks/s)", &options.move_speed, .{}, 0, 64, settingsId("player.move_speed"));
        _ = configSlider("Sprint Multiplier", &options.sprint_multiplier, .{}, 1, 3, settingsId("player.sprint_multiplier"));
    }

    if (self.settingsSection(@src(), "World Streaming", settingsId("streaming"), true)) |section| {
        defer section.deinit();
        settingsSlider("Minimum Detail Level", &options.lowest_level, -8, 24, settingsId("streaming.lowest_level"));
        settingsSlider("Maximum Detail Level", &options.highest_level, 0, 24, settingsId("streaming.highest_level"));
        settingsSlider("Horizontal Render Distance", &options.render_distance_x, 6, 64, settingsId("streaming.render_distance_x"));
        settingsSlider("Vertical Render Distance", &options.render_distance_y, 6, 64, settingsId("streaming.render_distance_y"));
        settingsSlider("LOD Overlap (chunks)", &options.lod_overlap, -4, 8, settingsId("streaming.lod_overlap"));
        settingsInterval("Chunk Load Interval (ms)", &options.loader_frequency_ms, settingsId("streaming.loader_frequency_ms"));
        settingsInterval("Mesh Unload Interval (ms)", &options.mesh_unload_frequency_ms, settingsId("streaming.mesh_unload_frequency_ms"));
        settingsInterval("Autosave Interval (ms)", &options.save_frequency_ms, settingsId("streaming.save_frequency_ms"));
    }

    if (self.settingsSection(@src(), "Storage and Tools", settingsId("storage"), false)) |section| {
        defer section.deinit();
        configTextU64("Terrain Height Cache (bytes)", &options.terrain_height_cache_bytes, settingsId("storage.terrain_height_cache_bytes"));
        configTextU64("Chunk Cache (bytes)", &options.chunk_cache_bytes, settingsId("storage.chunk_cache_bytes"));
        configTextU64("Grid Cache (bytes)", &options.grid_cache_bytes, settingsId("storage.grid_cache_bytes"));
        configTextU64("Entity Cache (bytes)", &options.entity_cache_bytes, settingsId("storage.entity_cache_bytes"));
        settingsSlider("Sphere Size (blocks)", &options.sphere_size, 1, 512, settingsId("storage.sphere_size"));
        settingsEnum("Sphere Block", World.Block, &options.sphere_block, settingsId("storage.sphere_block"));
        settingsEnum("Save Mode", World.WorldStorage.SaveMode, &options.save_mode, settingsId("storage.save_mode"));
    }
}

fn drawRenderSettings(self: *@This(), allocator: std.mem.Allocator, options: *Game.Options) void {
    const render_options = &options.render_options;
    if (self.settingsSection(@src(), "Rendering", settingsId("rendering"), true)) |section| {
        defer section.deinit();
        _ = configSlider("Field of View", &render_options.fov, .{}, 30, 150, settingsId("rendering.fov"));
        _ = configTextf32("Day/Night Cycle Length (seconds)", &render_options.day_length_sec, settingsId("rendering.day_length_sec"));
        settingsCheckbox("Gamma Correction", &render_options.gamma_correction, settingsId("rendering.gamma_correction"));
        settingsEnum("Presentation Mode", VulkanContext.PresentMode, &render_options.present_mode, settingsId("rendering.present_mode"));
        settingsEnum("Anti Aliasing", Renderer.AntiAliasing, &render_options.anti_aliasing, settingsId("rendering.anti_aliasing"));
        configTextString(allocator, "Texture Pack", &render_options.selected_pack, settingsId("rendering.selected_pack"));
        settingsCheckbox("See Through Transparent Blocks", &render_options.inside_transparent, settingsId("rendering.inside_transparent"));
        settingsCheckbox("Occlusion Culling", &render_options.occlusion_culling, settingsId("rendering.occlusion_culling"));
    }

    if (self.settingsSection(@src(), "Sky", settingsId("sky"), false)) |section| {
        defer section.deinit();
        _ = configSlider("Sun Brightness", &render_options.sky.sun_intensity, .{}, 0, 10, settingsId("sky.sun_intensity"));
        _ = configSlider("Sun Glow Strength", &render_options.sky.sun_glow_power, .{}, 0, 1000, settingsId("sky.sun_glow_power"));
        _ = configSlider("Sun Size", &render_options.sky.sun_angular_radius, .{}, 0, 0.2, settingsId("sky.sun_angular_radius"));
        _ = configSlider("Distant Planet Count", &render_options.sky.planet_count, .{}, 0, 4, settingsId("sky.planet_count"));
        _ = configSlider("Star Density", &render_options.sky.star_density, .{}, 0, 200, settingsId("sky.star_density"));
        _ = configSlider("Minimum Star Brightness", &render_options.sky.star_brightness_min, .{}, 0, 1, settingsId("sky.star_brightness_min"));
        _ = configSlider("Maximum Star Brightness", &render_options.sky.star_brightness_max, .{}, 0, 1, settingsId("sky.star_brightness_max"));
        _ = configSlider("Horizon Transition", &render_options.sky.transition_power, .{}, 0, 8, settingsId("sky.transition_power"));
        _ = configSlider("Exposure", &render_options.sky.exposure, .{}, 0, 4, settingsId("sky.exposure"));

        if (self.settingsSection(@src(), "Advanced", settingsId("sky.advanced"), false)) |advanced| {
            defer advanced.deinit();
            drawAdvancedSkySettings(&render_options.sky, settingsId("sky.advanced"));
        }
    }

    if (self.settingsSection(@src(), "Shadows", settingsId("shadows"), true)) |section| {
        defer section.deinit();
        settingsCheckbox("Enabled", &render_options.shadow.enabled, settingsId("shadows.enabled"));
        settingsSlider("Cascade Count", &render_options.shadow.cascade_count, 1, 16, settingsId("shadows.cascade_count"));
        settingsSlider("Lowest Shadow Level", &render_options.shadow.lowest_shadow_level, -4, 24, settingsId("shadows.lowest_shadow_level"));
        settingsSlider("Shadow Map Resolution", &render_options.shadow.shadow_map_size, 512, 8192, settingsId("shadows.shadow_map_size"));
        _ = configSlider("Shadow Distance", &render_options.shadow.max_shadow_distance, .{}, 1000, 250000, settingsId("shadows.max_shadow_distance"));
        _ = configSlider("Shadow Opacity", &render_options.shadow.shadow_strength, .{}, 0, 1, settingsId("shadows.shadow_strength"));
        settingsCheckbox("Debug Cascade Colors", &render_options.shadow.debug_cascade_colors, settingsId("shadows.debug_cascade_colors"));

        if (self.settingsSection(@src(), "Advanced", settingsId("shadows.advanced"), false)) |advanced| {
            defer advanced.deinit();
            drawAdvancedShadowSettings(&render_options.shadow, settingsId("shadows.advanced"));
        }
    }

    if (self.settingsSection(@src(), "Screenshots", settingsId("screenshots"), true)) |section| {
        defer section.deinit();
        settingsEnum("Screenshot Resolution", Screenshot.Resolution, &render_options.screenshot_resolution, settingsId("screenshots.resolution"));
        dvui.labelNoFmt(@src(), "Press F2 to take screenshot. Saved to screenshots/ folder as PNG", .{}, .{ .padding = .{ .y = 4, .h = 4 } });
    }
}

fn normalizeSettings(options: *Game.Options) void {
    const render_options = &options.render_options;
    options.lowest_level = std.math.clamp(options.lowest_level, -8, 24);
    options.highest_level = @max(std.math.clamp(options.highest_level, 1, 24), options.lowest_level);
    options.lod_overlap = std.math.clamp(options.lod_overlap, -4, 8);
    render_options.shadow.lowest_shadow_level = std.math.clamp(render_options.shadow.lowest_shadow_level, -4, 24);
    render_options.sky.star_brightness_min = std.math.clamp(render_options.sky.star_brightness_min, 0, 1);
    render_options.sky.star_brightness_max = @max(std.math.clamp(render_options.sky.star_brightness_max, 0, 1), render_options.sky.star_brightness_min);
}

pub fn crossHair(self: *@This()) void {
    _ = self;
    _ = dvui.label(@src(), "+", .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5, .color_fill = .transparent, .font = .{ .size = 32 } });
}

const selected_slot_color: dvui.Color = .{ .r = 90, .g = 140, .b = 220, .a = 255 };
const hotbar_border_color: dvui.Color = .{ .r = 150, .g = 150, .b = 150, .a = 160 };

/// Hotbar along the bottom. Number keys move the selection. Slots do not take
/// clicks: play has no cursor, and an open menu is drawn over the bar.
fn hotbar(self: *@This(), io: std.Io) void {
    const inventory = &self.game.player.main_inventory;
    const selected_row = self.game.selectedRow();
    const selected_col = self.game.selectedCol();

    const bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_x = 0.5,
        .gravity_y = 1.0,
        .margin = .{ .y = 12 },
        .padding = .all(2),
        .border = .all(2),
        .color_border = hotbar_border_color,
    });
    defer bar.deinit();

    for (0..inventory.width) |index| {
        const col: u32 = @intCast(index);
        const item = inventory.get(io, selected_row, col);
        self.hotbarSlot(col, item, col == selected_col);
    }
}

fn hotbarSlot(self: *@This(), index: u32, item: ?Item.Item, selected: bool) void {
    const color_fill: dvui.Color = if (selected) selected_slot_color else .transparent;
    const slot = dvui.box(@src(), .{}, .{
        .id_extra = index,
        .min_size_content = .{ .w = 40, .h = 40 },
        .padding = .all(2),
        .margin = .all(2),
        .border = .all(2),
        .color_border = hotbar_border_color,
        .color_fill = color_fill,
        .background = true,
    });
    defer slot.deinit();

    if (item) |it| {
        const texture = self.hotbar_item_textures.get(it.item_type) orelse self.hotbar_missing_texture;
        if (texture) |tex| {
            _ = dvui.image(@src(), .{ .source = .{ .texture = tex } }, .{
                .id_extra = index,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 36, .h = 36 },
            });
        }
    }
}

fn selectNewGameGenerator(self: *@This(), allocator: std.mem.Allocator, generator: *generator_loader.Generator) !void {
    if (self.new_game.generator == generator) return;

    const config = generator.defaultConfig(allocator) orelse return error.OutOfMemory;
    errdefer generator_api.free(allocator, config);
    const name = try allocator.dupe(u8, generator.info.name);
    errdefer allocator.free(name);

    if (self.new_game.config) |old_config| generator_api.free(allocator, old_config);
    if (self.new_game.generator_name_allocated) allocator.free(self.new_game.generator_name);
    self.new_game.preset_index = generator.defaultPresetIndex();
    self.new_game.config = config;
    self.new_game.generator = generator;
    self.new_game.generator_name = name;
    self.new_game.generator_name_allocated = true;
}

fn selectNewGamePreset(self: *@This(), allocator: std.mem.Allocator, index: usize) !void {
    const generator = self.new_game.generator orelse return;
    const config = generator.presetConfig(allocator, index) orelse return error.OutOfMemory;
    errdefer generator_api.free(allocator, config);
    if (self.new_game.config) |old_config| generator_api.free(allocator, old_config);
    self.new_game.config = config;
    self.new_game.preset_index = index;
}

const max_generator_dropdown_entries: usize = 16;

pub fn newGameMenu(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !bool {
    const page = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer page.deinit();

    const menu_changed: bool = if (!self.menu_state.ingame) self.sidebar() else false;

    const options = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = .{ .r = 48, .g = 77, .b = 84, .a = 225 } });
    defer options.deinit();

    const content = pageContent(1);
    defer content.deinit();

    try self.ensureNewGameGenerator(allocator);

    const create = dvui.button(@src(), "Create World", .{}, .{ .gravity_x = 0.5, .color_fill = .blue, .margin = .all(16), .expand = .horizontal, .padding = .{ .y = 16, .h = 16 } });

    {
        const world_name_widget = dvui.textEntry(@src(), .{ .placeholder = "World Name" }, .{ .gravity_x = 0.5 });
        defer world_name_widget.deinit();
        if (create) return try self.createWorld(io, allocator, world_name_widget.textGet());
    }

    drawSpawnConfig(&self.new_game.spawn_config);

    try self.generatorDropdown(allocator);
    try self.presetDropdown(allocator);

    const scroll = dvui.scrollArea(@src(), .{ .vertical = .auto }, .{ .expand = .both });
    defer scroll.deinit();
    if (self.new_game.config) |config| drawConfigTree(self, allocator, config);

    return menu_changed;
}

fn ensureNewGameGenerator(self: *@This(), allocator: std.mem.Allocator) !void {
    if (self.new_game.generator != null) return;
    const initial = self.generators.findByName(self.new_game.generator_name) orelse
        (if (self.generators.generators.items.len > 0) &self.generators.generators.items[0] else null);
    if (initial) |generator| try self.selectNewGameGenerator(allocator, generator);
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
        .generator_name = self.new_game.generator_name,
        .world_config = self.new_game.world_config,
        .spawn = self.new_game.spawn_config,
    };
    try world_options.save(io, game_path);
    try self.saveGeneratorConfig(allocator, io, game_path);
    // Mark the list stale before the fallible open so a failed open still refreshes.
    self.world_list_dirty = true;
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

fn saveGeneratorConfig(self: *@This(), allocator: std.mem.Allocator, io: std.Io, game_path: []const u8) !void {
    const generator = self.new_game.generator orelse return;
    const config = self.new_game.config orelse return;
    generator.api.config_set_seeds(&io, config);
    const config_dir = try std.fs.path.join(allocator, &.{ game_path, "config" });
    defer allocator.free(config_dir);
    try generator.saveConfig(allocator, io, config_dir, config);
}

const newgame_spawn_id: u64 = 0x7370776e6366673f;

fn newgameSpawnId(path: []const u8) u64 {
    return configId(newgame_spawn_id, path);
}

fn spawnFloatRow(label: []const u8, value: *f64, id: u64) void {
    var as_f32: f32 = @floatCast(value.*);
    configTextf32(label, &as_f32, id);
    value.* = as_f32;
}

/// Only the settings are editable; the resolved pos/found stay hidden here.
fn drawSpawnConfig(spawn: *EntityRegistry.SpawnConfig) void {
    dvui.labelNoFmt(@src(), "Spawn", .{}, .{ .font = .{ .size = 24 } });
    spawnFloatRow("Center X", &spawn.center[0], newgameSpawnId("center_x"));
    spawnFloatRow("Center Y", &spawn.center[1], newgameSpawnId("center_y"));
    spawnFloatRow("Center Z", &spawn.center[2], newgameSpawnId("center_z"));
    var as_u64: u64 = spawn.range;
    configTextU64("Range", &as_u64, newgameSpawnId("range"));
    spawn.range = @intCast(@min(as_u64, std.math.maxInt(u32)));
    settingsEnum("Game Mode", EntityTypes.Player.GameMode, &spawn.mode, newgameSpawnId("mode"));
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
    if (choice != previous) try self.selectNewGameGenerator(allocator, &self.generators.generators.items[choice]);
}

fn presetDropdown(self: *@This(), allocator: std.mem.Allocator) !void {
    const generator = self.new_game.generator orelse return;
    const count = generator.presetCount();
    if (count == 0) return;
    var names_buffer: [max_generator_dropdown_entries][]const u8 = undefined;
    const n = @min(count, max_generator_dropdown_entries);
    for (names_buffer[0..n], 0..) |*dest, i| dest.* = generator.presetName(i);
    if (self.new_game.preset_index >= n) self.new_game.preset_index = 0;
    const previous = self.new_game.preset_index;
    dvui.labelNoFmt(@src(), "Preset", .{}, .{ .font = .{ .size = 24 } });
    _ = dvui.dropdown(@src(), names_buffer[0..n], .{ .choice = &self.new_game.preset_index }, .{}, .{});
    if (self.new_game.preset_index != previous) try self.selectNewGamePreset(allocator, self.new_game.preset_index);
}

fn selectedGeneratorIndex(self: *@This(), count: usize) usize {
    const selected = self.new_game.generator orelse return 0;
    for (self.generators.generators.items[0..count], 0..) |*generator, i| {
        if (generator == selected) return i;
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
        // External changes may add or remove worlds, so refresh the list on entry.
        self.world_list_dirty = true;
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

    if (self.world_list_dirty) {
        var worlds_folder = try std.Io.Dir.cwd().createDirPathOpen(io, self.worlds_path, .{ .open_options = .{ .iterate = true } });
        defer worlds_folder.close(io);
        while (self.world_list.pop()) |data| allocator.free(data.name);
        var it = worlds_folder.iterate();
        while (try it.next(io)) |item| {
            if (item.kind != .directory) continue;
            const stat = try std.Io.Dir.statFile(worlds_folder, io, item.name, .{});
            const data = FolderData{ .access_time = stat.ctime, .name = try allocator.dupe(u8, item.name) };
            errdefer allocator.free(data.name);
            try self.world_list.append(allocator, data);
        }
        std.sort.pdq(FolderData, self.world_list.items, {}, lessThanFn);
        self.world_list_dirty = false;
    }
    for (self.world_list.items, 0..) |item, i| {
        const game = menuCard(@src(), .{}, .{ .id_extra = i, .expand = .vertical });
        defer game.deinit();

        const text = dvui.textLayout(@src(), .{}, .{ .gravity_x = 0.5 });
        text.addText(item.name, .{ .font = .{ .family = pixel_font } });
        text.deinit();

        const bottom = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 1.0, .expand = .horizontal });
        defer bottom.deinit();

        if (dvui.button(@src(), "Play", .{}, .{ .gravity_x = 0.0, .expand = .horizontal, .margin = .{ .x = 8, .w = 8, .h = 4 }, .font = .{ .family = pixel_font }, .color_fill = .blue, .corners = .all(2) })) {
            std.log.info("Joining game: {s}", .{item.name});
            const jpath = try std.fs.path.join(allocator, &.{ self.worlds_path, item.name });
            defer allocator.free(jpath);
            try self.openGame(io, allocator, jpath);
            self.menu_state.ingame = true;
            self.menu_state.main = false;
            return true;
        }

        if (dvui.button(@src(), "Delete", .{}, .{ .gravity_x = 0.0, .expand = .none, .margin = .{ .w = 8, .h = 4 }, .font = .{ .family = pixel_font }, .color_fill = .red, .corners = .all(2) })) {
            if (self.delete_world_name) |old| allocator.free(old);
            self.delete_world_name = try allocator.dupe(u8, item.name);
        }
    }

    if (self.delete_world_name) |name| {
        var open: bool = true;
        const confirm = dvui.floatingWindow(
            @src(),
            .{ .modal = true, .resize = .none, .open_flag = &open },
            .{ .max_size_content = .width(480) },
        );
        defer confirm.deinit();

        dvui.labelNoFmt(@src(), "Delete world", .{}, .{ .gravity_x = 0.5, .font = .{ .size = 24 } });

        var message_buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "Are you sure you want to delete \"{s}\"? This cannot be undone.", .{name}) catch unreachable;
        const message_text = dvui.textLayout(@src(), .{}, .{ .gravity_x = 0.5 });
        message_text.addText(message, .{});
        message_text.deinit();

        const buttons = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
        defer buttons.deinit();

        if (dvui.button(@src(), "Cancel", .{}, .{ .margin = .all(8) })) {
            allocator.free(name);
            self.delete_world_name = null;
        }
        if (self.delete_world_name != null and dvui.button(@src(), "Delete", .{}, .{ .margin = .all(8), .color_fill = .red })) {
            const pending = self.delete_world_name.?;
            self.delete_world_name = null;
            defer allocator.free(pending);
            var worlds_folder = std.Io.Dir.cwd().createDirPathOpen(io, self.worlds_path, .{}) catch |err| {
                self.world_list_dirty = true;
                return err;
            };
            defer worlds_folder.close(io);
            worlds_folder.deleteTree(io, pending) catch |err| {
                // Stale cached entry: drop it from the cache on next refresh.
                self.world_list_dirty = true;
                return err;
            };
            self.world_list_dirty = true;
            return true;
        }
        // Dismissed via Esc or clicking outside the modal.
        if (!open and self.delete_world_name != null) {
            allocator.free(name);
            self.delete_world_name = null;
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
    const data_prev = widget.data_prev orelse return;
    const child_size = switch (widget.init_opts.dir) {
        .horizontal => widget.child_rect.w,
        .vertical => widget.child_rect.h,
    };
    if (widget.init_opts.equal_space) {
        if (data_prev.packed_children == 0) return;
        widget.pixels_per_w = child_size / data_prev.packed_children;
        return;
    }

    const packed_weight = if (widget.init_opts.num_packed_expanded) |num|
        @as(f32, @floatFromInt(num))
    else
        data_prev.total_weight;
    if (packed_weight <= 0) return;
    widget.pixels_per_w = @max(0, child_size - data_prev.min_space_taken) / packed_weight;
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

fn drawConfigTree(self: *@This(), allocator: std.mem.Allocator, tree: *generator_api.ConfigTree) void {
    const box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer box.deinit();
    drawParams(self, allocator, &tree.params, config_root_id);
}

const config_root_id: u64 = 0x7465727261696e;

fn configId(parent_id: u64, name: []const u8) u64 {
    return std.hash.Wyhash.hash(parent_id, name);
}

fn configIndexId(parent_id: u64, index: usize) u64 {
    return std.hash.Wyhash.hash(parent_id, std.mem.asBytes(&index));
}

fn drawParams(self: *@This(), allocator: std.mem.Allocator, params: *[]generator_api.Param, parent_id: u64) void {
    for (params.*) |*param| drawParam(self, allocator, param, configId(parent_id, param.name));
}

fn paramVisible(param: *const generator_api.Param) bool {
    return switch (param.value) {
        .group => |group| {
            for (group.params) |*child| if (paramVisible(child)) return true;
            return false;
        },
        else => true,
    };
}

fn drawParam(self: *@This(), allocator: std.mem.Allocator, param: *generator_api.Param, id: u64) void {
    if (!paramVisible(param)) return;

    var label_buffer: [256]u8 = undefined;
    const label = configLabel(param, &label_buffer);
    switch (param.value) {
        .group => |*group| {
            const expanded = self.config_section_states.get(id) orelse defaultSectionExpanded(param.name);
            var title_buffer: [260]u8 = undefined;
            const title = configSectionTitle(label, expanded, &title_buffer);
            if (self.toggleConfigSection(@src(), title, id, expanded)) return;
            if (!expanded) return;
            const box = configBox(@src(), id, .{ .r = 24, .g = 40, .b = 28, .a = 255 }, .{ .x = 16, .w = 16, .y = 4, .h = 4 });
            defer box.deinit();
            drawParams(self, allocator, &group.params, id);
        },
        .array => |*array| drawArray(self, allocator, label, array, id),
        .f32 => _ = configSlider(label, &param.value.f32, param.spec, 0, 1, id),
        .i32 => configSliderInt(label, &param.value.i32, param.spec, id),
        .u32 => configSliderUInt(label, &param.value.u32, param.spec, id),
        .u64 => configTextU64(label, &param.value.u64, id),
        .bool => _ = dvui.checkbox(@src(), &param.value.bool, label, .{ .id_extra = @intCast(id) }),
        .string => configTextString(allocator, label, &param.value.string, id),
        .choice => configChoiceDropdown(label, param.spec, &param.value.choice, id),
    }
    if (param.spec.description.len == 0) return;
    dvui.labelNoFmt(@src(), param.spec.description, .{}, .{
        .id_extra = @intCast(id),
        .color_fill = .{ .r = 160, .g = 180, .b = 160, .a = 255 },
        .font = .{ .size = 11 },
        .padding = .{ .x = 8, .w = 8 },
    });
}

fn drawArray(self: *@This(), allocator: std.mem.Allocator, name: []const u8, array: *generator_api.Array, id: u64) void {
    const expanded = self.config_section_states.get(id) orelse true;
    var title_buffer: [300]u8 = undefined;
    const title = configArrayTitle(name, expanded, array.items.len, &title_buffer);
    if (self.toggleConfigSection(@src(), title, id, expanded)) return;
    if (!expanded) return;

    const contents = configBox(@src(), configId(id, "contents"), .{ .r = 16, .g = 24, .b = 16, .a = 255 }, .{ .x = 8, .w = 8, .y = 4, .h = 4 });
    defer contents.deinit();

    for (array.items, 0..) |*item, i| {
        const item_id = configIndexId(id, i);
        const item_expanded = self.config_section_states.get(item_id) orelse (i == 0);
        var item_title_buffer: [64]u8 = undefined;
        const item_title = configItemTitle(item_expanded, i, &item_title_buffer);
        if (dvui.button(@src(), item_title, .{}, .{
            .expand = .horizontal,
            .id_extra = @intCast(configId(item_id, "header")),
            .color_fill = .{ .r = 61, .g = 107, .b = 61, .a = 255 },
            .margin = .{ .y = 4 },
            .padding = .{ .y = 6, .h = 6 },
        })) {
            self.config_section_states.put(item_id, !item_expanded) catch |err| std.log.warn("Ui: config section state store failed: {any}", .{err});
            continue;
        }
        if (!item_expanded) continue;

        const item_box = configBox(@src(), configId(item_id, "contents"), .{ .r = 24, .g = 40, .b = 28, .a = 255 }, .{ .x = 12, .w = 12, .y = 4, .h = 4 });
        defer item_box.deinit();
        if (item.value == .group) drawParams(self, allocator, &item.value.group.params, item_id);
        if (dvui.button(@src(), "Remove", .{}, .{ .id_extra = @intCast(configId(item_id, "remove")) })) {
            generator_api.arrayRemove(allocator, array, i);
            break;
        }
    }

    if (dvui.button(@src(), "Add item", .{}, .{ .id_extra = @intCast(configId(id, "add")), .margin = .{ .y = 6 } })) generator_api.arrayAdd(allocator, array) catch |err| std.log.warn("Ui: adding array item failed: {any}", .{err});
}

fn configArrayTitle(name: []const u8, expanded: bool, count: usize, buffer: *[300]u8) []const u8 {
    const marker: []const u8 = if (expanded) "[-] " else "[+] ";
    return std.fmt.bufPrint(buffer, "{s}{s} ({d})", .{ marker, name, count }) catch unreachable;
}

fn configItemTitle(expanded: bool, index: usize, buffer: *[64]u8) []const u8 {
    const marker: []const u8 = if (expanded) "[-] " else "[+] ";
    return std.fmt.bufPrint(buffer, "{s}Item {d}", .{ marker, index + 1 }) catch unreachable;
}

fn configLabel(param: *const generator_api.Param, buffer: *[256]u8) []const u8 {
    const source = if (param.spec.label.len > 0) param.spec.label else param.name;
    var length: usize = 0;
    var word_start = true;
    for (source) |character| {
        if (length >= buffer.len) break;
        if (character == '_') {
            buffer[length] = ' ';
            length += 1;
            word_start = true;
            continue;
        }
        buffer[length] = if (word_start) std.ascii.toUpper(character) else character;
        length += 1;
        word_start = false;
    }
    return buffer[0..length];
}

fn defaultSectionExpanded(name: []const u8) bool {
    return !std.mem.endsWith(u8, name, "_noise") and !std.mem.eql(u8, name, "terrain_noise2");
}

fn configSectionTitle(label: []const u8, expanded: bool, buffer: *[260]u8) []const u8 {
    const marker: []const u8 = if (expanded) "[-] " else "[+] ";
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ marker, label }) catch unreachable;
}

/// Horizontal row with the fixed-width label every config widget shares.
fn configRow(name: []const u8, id: u64) *dvui.BoxWidget {
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = @intCast(configId(id, "row")), .padding = .{ .y = 3, .h = 3 } });
    dvui.labelNoFmt(@src(), name, .{}, .{ .id_extra = @intCast(id), .min_size_content = .width(240), .gravity_y = 0.5 });
    return row;
}

fn configSlider(name: []const u8, value: *f32, spec: generator_api.Spec, default_min: f64, default_max: f64, id: u64) bool {
    const row = configRow(name, id);
    defer row.deinit();
    const min: f32 = @floatCast(spec.min orelse default_min);
    const max: f32 = @floatCast(spec.max orelse default_max);
    const step: ?f32 = if (spec.step) |s| @floatCast(s) else null;
    return dvui.sliderEntry(@src(), null, .{ .value = value, .min = min, .max = max, .interval = step }, .{ .id_extra = @intCast(id), .expand = .horizontal });
}

fn configSliderInt(name: []const u8, value: *i32, spec: generator_api.Spec, id: u64) void {
    var float_value: f32 = @floatFromInt(value.*);
    if (configSlider(name, &float_value, spec, -100, 100, id)) value.* = @intFromFloat(float_value);
}

fn configSliderUInt(name: []const u8, value: *u32, spec: generator_api.Spec, id: u64) void {
    var float_value: f32 = @floatFromInt(value.*);
    if (configSlider(name, &float_value, spec, 0, 100, id) and float_value >= 0) value.* = @intFromFloat(float_value);
}

/// Labeled text entry over `buffer`; returns the text the user typed.
fn configTextRow(name: []const u8, buffer: []u8, id: u64) []u8 {
    const row = configRow(name, id);
    defer row.deinit();
    var widget = dvui.textEntry(@src(), .{ .text = .{ .buffer = buffer }, .placeholder = name }, .{ .id_extra = @intCast(id), .expand = .horizontal });
    defer widget.deinit();
    return widget.textGet();
}

fn configTextU64(name: []const u8, value: *u64, id: u64) void {
    var buffer: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value.*}) catch unreachable;
    buffer[text.len] = 0;
    const parsed = std.fmt.parseUnsigned(u64, configTextRow(name, &buffer, id), 10) catch return;
    value.* = parsed;
}

fn configTextf32(name: []const u8, value: *f32, id: u64) void {
    // "{d}" prints full decimal: the longest f32 expansion is 47 characters.
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value.*}) catch unreachable;
    buffer[text.len] = 0;
    const parsed = std.fmt.parseFloat(f32, configTextRow(name, &buffer, id)) catch return;
    if (std.math.isFinite(parsed)) value.* = parsed;
}

fn configTextString(allocator: std.mem.Allocator, name: []const u8, value: *[]const u8, id: u64) void {
    var buffer: [256]u8 = undefined;
    const cur_len = @min(value.len, buffer.len - 1);
    @memcpy(buffer[0..cur_len], value.*[0..cur_len]);
    buffer[cur_len] = 0;
    const text = configTextRow(name, &buffer, id);
    if (std.mem.eql(u8, value.*, text)) return;
    const new_value = allocator.dupe(u8, text) catch return;
    if (value.len > 0) allocator.free(value.*);
    value.* = new_value;
}

fn configChoiceDropdown(name: []const u8, spec: generator_api.Spec, choice: *usize, id: u64) void {
    const row = configRow(name, id);
    defer row.deinit();
    if (choice.* >= spec.entries.len and spec.entries.len > 0) choice.* = 0;
    _ = dvui.dropdown(@src(), spec.entries, .{ .choice = choice }, .{}, .{ .id_extra = @intCast(id), .expand = .horizontal });
}

const HoverOptions = struct {
    hover_cursor: ?dvui.enums.Cursor = .hand,
    rect: ?dvui.Rect.Physical = null,
};
