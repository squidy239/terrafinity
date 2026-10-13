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
const Key = @import("Key.zig");
const utils = @import("libs/utils.zig");
const ShadowConfig = @import("Renderer/vulkan/shadow/Csm.zig").ShadowConfig;
const SkyConfig = @import("Renderer/vulkan/sky/SkyRenderer.zig").SkyConfig;
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const generator_loader = @import("world/generator_loader.zig");
const generator_api = @import("world/generators/generator_api.zig");
const World = @import("world/World.zig");

const press_start_2p: []const u8 = @embedFile("assets/press-start-2p/PressStart2P.ttf");
const menu_background_image: []const u8 = @embedFile("assets/terrain.png");
const pixel_font = dvui.Font.array("Press Start 2P");
const Ui = @This();

const NewGameState = struct {
    world_config: World.WorldConfig = .{},
    spawn_config: EntityRegistry.SpawnConfig = .{},
    /// Index into the generator registry, chosen when the page first opens.
    generator_index: ?usize = null,
    config: ?*generator_api.ConfigTree = null,
    preset_index: usize = 0,
};

const main_theme: dvui.Theme = blk: {
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

vk_ctx: *VulkanContext,
config: *Config,
config_lock: *std.Io.RwLock,
game: *Game,
generators: *generator_loader.Registry,
config_path: []const u8,
/// Owned by the loop thread, which reads it for input and edits it here.
keymap: *Key.Keymap,
keymap_path: []const u8,
/// The binding slot waiting for the next button press, set from the settings page.
key_capture: ?Key.Slot = null,
worlds_path: []const u8,
menu_background: dvui.Texture,
/// One icon per item type, null when the pack has no file (draw the missing texture).
item_textures: std.enums.EnumArray(Item.ItemType, ?dvui.Texture) = .initFill(null),
/// Set by `initAssets`, like `menu_background`.
missing_item_texture: dvui.Texture = undefined,
ui_window: *dvui.Window,
running: *std.atomic.Value(bool),
config_section_states: std.AutoHashMap(u64, bool),
new_game: NewGameState = .{},

/// World awaiting deletion confirmation, owned by the Ui allocator.
delete_world_name: ?[]const u8 = null,
terrain_recreate_error: ?[]const u8 = null,
/// A world load that failed outside the menu (test play), shown on the next frame.
world_error: ?anyerror = null,
world_list: std.ArrayList(FolderData) = .empty,
world_list_dirty: bool = true,
/// The frame saves settings edits when the menu closes, not on every edited frame.
config_dirty: bool = false,

menu_state: struct {
    ingame: bool = false,
    /// The full-screen page drawn over the game view. `.game` shows no page.
    /// The inventory carries the slot the cursor picked up, so closing it drops the pick.
    page: union(enum) { game, main, settings, newgame, esc, inventory: ?GridSlot } = .main,
    /// Preferences live beside the page so navigation never resets them.
    debug_info: bool = true,
    crosshair: bool = true,

    pending_game_deinit: bool = false,
    pending_world_recreate: bool = false,
    terrain_developer_settings: bool = false,

    /// Reports whether gameplay input is active. Every menu is drawn full-screen over
    /// the game view, so an open one takes the input the player would otherwise get.
    pub fn isPlayingGame(self: @This()) bool {
        return self.ingame and self.page == .game;
    }

    /// Opens the escape menu in a game, or closes it or the inventory when one is open.
    pub fn handleEsc(self: *@This()) void {
        if (!self.ingame) return;
        self.page = switch (self.page) {
            .esc, .inventory => .game,
            else => .esc,
        };
    }

    /// Opens the inventory during play, or closes it when it is open. Other pages ignore it.
    pub fn toggleInventory(self: *@This()) void {
        if (!self.ingame) return;
        self.page = switch (self.page) {
            .game => .{ .inventory = null },
            .inventory => .game,
            else => return,
        };
    }

    fn enterGame(self: *@This()) void {
        self.ingame = true;
        self.page = .game;
    }

    /// Goes back to the main menu and closes the terrain developer window.
    pub fn leaveGame(self: *@This()) void {
        self.ingame = false;
        self.page = .main;
        self.terrain_developer_settings = false;
    }
},

/// RGBA texture upload shared by the background and item icons.
fn createTexture(self: *Ui, pixels: [*]const u8, width: u32, height: u32, interpolation: dvui.enums.TextureInterpolation) !dvui.Texture {
    return self.ui_window.backend.textureCreate(pixels, .{
        .width = width,
        .height = height,
        .format = .rgba_32,
        .interpolation = interpolation,
    });
}

/// Uploads the menu background and the item icons.
pub fn initAssets(self: *Ui, io: std.Io, allocator: std.mem.Allocator) !void {
    var image = try zignal.Image(zignal.Rgba(u8)).loadFromBytes(io, allocator, menu_background_image);
    defer image.deinit(allocator);
    self.menu_background = try self.createTexture(@ptrCast(image.asBytes().ptr), @intCast(image.cols), @intCast(image.rows), .linear);
    try self.loadItemTextures(io, allocator);
}

/// Loads `packs/<pack>/items/<ItemType>.png`. A missing or undecodable file falls
/// back to the 1x1 magenta missing texture, so a new icon file needs no code change.
fn loadItemTextures(self: *Ui, io: std.Io, allocator: std.mem.Allocator) !void {
    const pack = try utils.openPackDir(io, allocator, self.config.game_config.render_options.selected_pack, "items");
    defer allocator.free(pack.path);
    defer pack.dir.close(io);

    const missing_pixels: [4]u8 = .{ 255, 0, 255, 255 };
    self.missing_item_texture = try self.createTexture(@ptrCast(&missing_pixels), 1, 1, .nearest);

    for (std.enums.values(Item.ItemType)) |item_type| {
        const filename = try allocator.print("{s}.png", .{@tagName(item_type)});
        defer allocator.free(filename);
        self.item_textures.set(item_type, try self.loadItemTexture(io, allocator, pack.dir, filename));
    }
}

fn loadItemTexture(self: *Ui, io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, filename: []const u8) !?dvui.Texture {
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

    var image = zignal.Image(zignal.Rgba(u8)).loadFromBytes(io, allocator, bytes) catch |err| {
        std.log.warn("could not decode item icon items/{s}: {any}", .{ filename, err });
        return null;
    };
    defer image.deinit(allocator);

    return try self.createTexture(@ptrCast(image.asBytes().ptr), @intCast(image.cols), @intCast(image.rows), .nearest);
}

/// Destroys the textures and frees the memory that the Ui owns.
pub fn deinit(self: *Ui, allocator: std.mem.Allocator) void {
    self.ui_window.backend.textureDestroy(self.menu_background);
    for (self.item_textures.values) |texture| {
        if (texture) |t| self.ui_window.backend.textureDestroy(t);
    }
    self.ui_window.backend.textureDestroy(self.missing_item_texture);
    if (self.new_game.config) |config| generator_api.free(allocator, config);
    if (self.delete_world_name) |name| allocator.free(name);
    self.config_section_states.deinit();
    for (self.world_list.items) |entry| allocator.free(entry.name);
    self.world_list.deinit(allocator);
    self.* = undefined;
}

fn showWorldError(frame_time: std.Io.Timestamp, err: anyerror) void {
    var error_buffer: [65536]u8 = undefined;
    const message: []const u8 = switch (err) {
        error.RocksDBOpen => "World is already open in another instance.",
        error.OutOfMemory => "Out of memory.",
        error.ParseZon => "A ZON file in this world has an invalid format.",
        error.WorldNameMissing => "World needs a name.",
        error.WorldNameExists => "A world with this name already exists.",
        error.InvalidName => "World names can't contain '/'.",
        error.GeneratorSpawnFailed => "The generator could not find a safe spawn point.",
        else => std.mem.print(&error_buffer, "{any}", .{err}) catch unreachable,
    };
    dvui.dialog(@src(), frame_time, .{ .message = message, .title = "                There was a problem                " });
}

fn drawFrame(self: *Ui, io: std.Io, gpa: std.mem.Allocator, frame_time: std.Io.Timestamp) !void {
    const dw = tracy.Zone.begin(.{ .src = @src(), .name = "draw ui" });
    defer dw.end();

    try self.ui_window.begin(std.Io.Timestamp.now(io, .awake).toNanoseconds());
    dvui.themeSet(main_theme);
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

        if (self.world_error) |err| {
            showWorldError(frame_time, err);
            self.world_error = null;
        }

        const menu = &self.menu_state;
        if (menu.ingame) {
            if (menu.debug_info) self.debugInfo() catch |err| std.log.err("debugInfo failed: {}", .{err});
            if (menu.crosshair) crossHair();
            if (menu.page != .inventory) self.hotbar();
        }
        switch (menu.page) {
            .game => {},
            .inventory => |*held| self.inventoryMenu(held),
            .esc => self.escMenu(),
            .main => self.mainPage(io, gpa) catch |err| showWorldError(frame_time, err),
            .settings => self.settingsMenu(io, gpa) catch |err| std.log.err("settingsMenu failed: {}", .{err}),
            .newgame => self.newGameMenu(io, gpa) catch |err| showWorldError(frame_time, err),
        }
        if (menu.ingame and menu.terrain_developer_settings) self.drawTerrainDeveloperSettings(io, gpa);
    }
    _ = try self.ui_window.end(.{});
    if (self.menu_state.page == .settings) return;
    self.key_capture = null;
    if (!self.config_dirty) return;
    self.config_dirty = false;
    try self.config.save(io, self.config_path, self.config_lock);
}

/// Records the UI pass over the swapchain image and moves the image to present layout.
pub fn recordCommandBuffer(
    self: *Ui,
    io: std.Io,
    gpa: std.mem.Allocator,
    backend: *dvui.backend,
    cmd: vk.CommandBuffer,
    frame_ctx: VulkanContext.FrameContext,
    frame_time: std.Io.Timestamp,
) !void {
    const vk_ctx = self.vk_ctx;
    const extent = vk_ctx.swapchain_extent;
    const image_index = frame_ctx.image_index;
    const image = vk_ctx.swapchain_images[image_index];
    try vk_ctx.dev.resetCommandBuffer(cmd, .{});
    try vk_ctx.dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit = true } });

    VulkanContext.transitionImageLayout(vk_ctx.dev, cmd, image, vk_ctx.swapchain_image_layouts[image_index], .color_attachment_optimal);
    vk_ctx.swapchain_image_layouts[image_index] = .color_attachment_optimal;

    const color_attachment: vk.RenderingAttachmentInfo = .{
        .image_view = vk_ctx.swapchain_views[image_index],
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .load_op = .load,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } },
    };
    vk_ctx.dev.cmdBeginRendering(cmd, &.{
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = (&color_attachment)[0..1],
    });

    backend.beginFrame(.{ .cmd_buffer = cmd, .extent = extent });
    defer backend.target = null;
    try self.drawFrame(io, gpa, frame_time);
    vk_ctx.dev.cmdEndRendering(cmd);

    // The screenshot copy runs before the move to present layout and does that move itself.
    const copied = vk_ctx.screenshot_requested.swap(false, .acq_rel) and copy: {
        vk_ctx.recordScreenshotCopyFromColorAttachment(cmd, image, extent) catch |err| {
            std.log.err("Screenshot copy recording failed: {any}", .{err});
            break :copy false;
        };
        break :copy true;
    };
    if (!copied) VulkanContext.transitionImageLayout(vk_ctx.dev, cmd, image, .color_attachment_optimal, .present_src_khr);
    vk_ctx.swapchain_image_layouts[image_index] = .present_src_khr;
    try vk_ctx.dev.endCommandBuffer(cmd);
}

fn menuCard(src: std.lang.SourceLocation, opts: dvui.Options) *dvui.BoxWidget {
    var options: dvui.Options = .{
        .min_size_content = .all(256),
        .color_fill = .{ .color = .{ .r = 48, .g = 48, .b = 48, .a = 255 } },
        .background = true,
        .corners = .all(0),
        .border = .all(8),
        .margin = .all(16),
        .gravity_y = 0.5,
        .color_border = .{ .color = .{ .r = 48, .g = 77, .b = 48, .a = 225 } },
    };
    var card = dvui.widgetAlloc(dvui.BoxWidget);
    card.init(src, .{}, options.override(opts));
    if (hovered(card.data())) {
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

fn escMenu(self: *Ui) void {
    std.debug.assert(self.menu_state.ingame);
    const button_options: dvui.Options = .{ .min_size_content = .width(640 * 0.75), .gravity_x = 0.5 };
    const menu = dvui.box(@src(), .{}, .{ .background = true, .color_fill = .{ .color = .{ .r = 0, .g = 200, .b = 200, .a = 150 } }, .expand = .both });
    defer menu.deinit();
    if (dvui.button(@src(), "Back To Game", .{}, button_options)) {
        self.menu_state.page = .game;
        return;
    }

    if (dvui.button(@src(), "Settings", .{}, button_options)) {
        self.menu_state.page = .settings;
        return;
    }

    if (dvui.button(@src(), "Quit", .{}, button_options)) {
        self.menu_state.leaveGame();
        self.menu_state.pending_game_deinit = true;
        // External changes may add or remove worlds, so refresh the list on entry.
        self.world_list_dirty = true;
    }
}

fn debugInfo(self: *Ui) !void {
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
        .color_fill = .{ .color = .{ .r = 32, .g = 32, .b = 32, .a = 128 } },
        .border = .all(8),
        .color_border = .green,
    });
    defer text.deinit();

    const chunk_hits = self.game.world.chunks.hits();
    const chunk_misses = self.game.world.chunks.misses();

    const total = chunk_hits + chunk_misses;
    const chunk_hit_ratio: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(chunk_hits)) / @as(f32, @floatFromInt(total));
    const pos: @Vector(3, i64) = @intFromFloat(@round(self.game.player.body.pos));
    const spawn: @Vector(3, i64) = @intFromFloat(@round(self.game.spawn.pos));
    const stats = self.game.vulkan_renderer.frame_stats;
    const str = try std.mem.print(
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
            @trunc(self.game.debug_menu.fps),
            self.game.debug_menu.meshes.load(.unordered),
            stats.opaque_drawn,
            stats.transparent_drawn,
            stats.hiz_occluded,
            stats.frustum_culled,
            stats.opaque_faces,
            stats.transparent_faces,
            pos[0],
            pos[1],
            pos[2],
            spawn[0],
            spawn[1],
            spawn[2],
            self.game.world.chunks.count(),
            self.game.world.grids.count(),
            self.game.entity_registry.count(),
            chunk_hit_ratio,
        },
    );
    text.addText(str, .{ .background = false });
}

fn settingsMenu(self: *Ui, io: std.Io, allocator: std.mem.Allocator) !void {
    const page = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer page.deinit();

    if (!self.menu_state.ingame) self.sidebar();
    const settings = dvui.scrollArea(@src(), .{ .vertical_bar = .auto }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = .{ .r = 48, .g = 77, .b = 84, .a = 225 } },
    });
    defer settings.deinit();

    const content = pageContent(0);
    defer content.deinit();

    if (self.menu_state.ingame) {
        const game_mode_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .padding = .{ .y = 4, .h = 4 } });
        defer game_mode_row.deinit();
        dvui.labelNoFmt(@src(), "Game Mode", .{}, .{ .gravity_y = 0.5, .padding = .{ .x = 8, .w = 8 } });
        _ = dvui.dropdownEnum(
            @src(),
            EntityTypes.Player.GameMode,
            .{ .choice = &self.game.player.game_mode },
            .{ .null_selectable = false },
            .{},
        );
    }

    try self.config_lock.lock(io);
    const first_config = self.config.*;
    self.config_lock.unlock(io);

    const first_render = &first_config.game_config.render_options;
    var working_config = first_config;
    const options = &working_config.game_config;
    options.render_options.selected_pack = try allocator.dupe(u8, first_render.selected_pack);

    dvui.labelNoFmt(@src(), "Settings", .{}, .{ .font = .{ .size = 28 }, .gravity_x = 0.5 });
    drawGeneralSettings(self, io, options);
    drawRenderSettings(self, allocator, options);

    normalizeSettings(options);

    // eql matches slices by pointer, so share the pack slice and compare its content separately.
    var working_no_pack = working_config;
    working_no_pack.game_config.render_options.selected_pack = first_render.selected_pack;
    const config_changed = !std.meta.eql(first_config, working_no_pack) or !std.mem.eql(u8, first_render.selected_pack, options.render_options.selected_pack);
    const swapchain_changed = first_render.gamma_correction != options.render_options.gamma_correction or
        first_render.present_mode != options.render_options.present_mode or
        first_render.anti_aliasing != options.render_options.anti_aliasing;
    if (config_changed) {
        // The working pack moves into config below. Free it if the lock path exits early.
        errdefer allocator.free(options.render_options.selected_pack);
        try self.config_lock.lock(io);
        allocator.free(self.config.game_config.render_options.selected_pack);
        self.config.* = working_config;
        self.config_lock.unlock(io);
    } else allocator.free(options.render_options.selected_pack);

    if (swapchain_changed) self.vk_ctx.requestSwapchainRecreate();

    self.config_dirty = self.config_dirty or config_changed;
}

const settings_root_id: u64 = 0x73657474696e6773;

fn settingsId(path: []const u8) u64 {
    return configId(settings_root_id, path);
}

/// Draws a toggle header and returns whether its section draws open on this frame.
fn sectionHeader(self: *Ui, id: u64, default_open: bool, comptime fmt: []const u8, args: anytype) bool {
    const expanded = self.config_section_states.get(id) orelse default_open;
    var title_buffer: [300]u8 = undefined;
    const title = sectionTitle(&title_buffer, expanded, fmt, args);
    const toggled = dvui.button(@src(), title, .{}, .{
        .expand = .horizontal,
        .id_extra = @intCast(id),
        .color_fill = .{ .color = .{ .r = 44, .g = 77, .b = 44, .a = 255 } },
        .margin = .{ .y = 8 },
        .padding = .{ .y = 8, .h = 8 },
    });
    if (!toggled) return expanded;
    self.config_section_states.put(id, !expanded) catch |err| std.log.warn("Ui: config section state store failed: {any}", .{err});
    return false;
}

/// Indented, framed container for a config section or array item.
fn configBox(src: std.lang.SourceLocation, id: u64, color_fill: dvui.Color, padding: dvui.Rect) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .id_extra = @intCast(id),
        .background = true,
        .color_fill = .{ .color = color_fill },
        .margin = .{ .x = 12, .w = 12 },
        .padding = padding,
    });
}

fn settingsSection(self: *Ui, src: std.lang.SourceLocation, label: []const u8, id: u64, default_open: bool) ?*dvui.BoxWidget {
    return self.collapsibleSection(src, label, id, default_open, 8);
}

/// Draws a toggle header and returns the open section's box, or null when collapsed.
fn collapsibleSection(self: *Ui, src: std.lang.SourceLocation, label: []const u8, id: u64, default_open: bool, padding_y: f32) ?*dvui.BoxWidget {
    if (!self.sectionHeader(id, default_open, "{s}", .{label})) return null;
    return configBox(src, id, .{ .r = 24, .g = 40, .b = 28, .a = 255 }, .{ .x = 16, .w = 16, .y = padding_y, .h = padding_y });
}

fn sectionTitle(buffer: []u8, expanded: bool, comptime fmt: []const u8, args: anytype) []const u8 {
    const marker: []const u8 = if (expanded) "[-] " else "[+] ";
    return std.mem.print(buffer, "{s}" ++ fmt, .{marker} ++ args) catch unreachable;
}

fn settingsSlider(name: []const u8, value: anytype, min: f64, max: f64, id: u64) void {
    var float_value: f32 = @floatFromInt(value.*);
    if (!configSlider(name, &float_value, .{}, min, max, id)) return;
    if (@typeInfo(@TypeOf(value.*)).int.signedness == .unsigned and float_value < 0) return;
    value.* = @intFromFloat(float_value);
}

fn settingsInterval(name: []const u8, value: *u64, id: u64) void {
    configTextNumber(u64, name, value, id);
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
        const component_label = std.mem.print(&label_buffer, "{s} {s}", .{ label, name }) catch unreachable;
        _ = configSlider(component_label, value, .{}, min, max, configId(id, name));
    }
}

fn settingsColor(label: []const u8, color: *[4]f32, id: u64) void {
    settingsComponents(label, &.{ "Red", "Green", "Blue", "Alpha" }, color, 0, 1, id);
}

fn settingsVector(label: []const u8, vector: *[4]f32, id: u64) void {
    settingsComponents(label, &.{ "X", "Y", "Z" }, vector[0..3], -1, 1, id);
}

/// Draws one widget per `.{ label, field }` row, picked by the type of `target.field`.
/// Number rows add `min, max` and draw a slider. Arrays draw as colors. Each row's id is
/// `configId(parent_id, prefix ++ field)`.
fn drawFields(target: anytype, parent_id: u64, comptime prefix: []const u8, comptime rows: anytype) void {
    inline for (rows) |row| {
        const value = &@field(target, row[1]);
        const id = configId(parent_id, prefix ++ row[1]);
        switch (@typeInfo(@TypeOf(value.*))) {
            .float => _ = configSlider(row[0], value, .{}, row[2], row[3], id),
            .int => settingsSlider(row[0], value, row[2], row[3], id),
            .bool => settingsCheckbox(row[0], value, id),
            .@"enum" => settingsEnum(row[0], @TypeOf(value.*), value, id),
            .array => settingsColor(row[0], value, id),
            else => @compileError("no settings widget for field " ++ row[1]),
        }
    }
}

fn drawAdvancedSkySettings(sky: *SkyConfig, root_id: u64) void {
    settingsSubheading("Sky Colors", configId(root_id, "colors"));
    drawFields(sky, root_id, "", .{
        .{ "Sun Color", "sun_color" },
        .{ "Sun Glow Color", "sun_glow_color" },
        .{ "Moon Color", "moon_color" },
        .{ "Zenith Color", "zenith_color" },
        .{ "Horizon Color", "horizon_color" },
        .{ "Ground Color", "ground_color" },
        .{ "Sun Scattering Color", "sun_scatter" },
    });

    settingsSubheading("Moon", configId(root_id, "moon"));
    drawFields(sky, root_id, "", .{
        .{ "Moon Size", "moon_angular_radius", 0, 0.2 },
        .{ "Moon Phase", "moon_phase", 0, 1 },
    });

    settingsSubheading("Distant Planets", configId(root_id, "planets"));
    for (&sky.planet_dirs, &sky.planet_colors, &sky.planet_radii, 0..) |*direction, *color, *radius, i| {
        const planet_id = configIndexId(configId(root_id, "planet"), i);
        var label_buffer: [32]u8 = undefined;
        const label = std.mem.print(&label_buffer, "Planet {d}", .{i + 1}) catch unreachable;
        settingsSubheading(label, planet_id);
        settingsVector("Direction", direction, configId(planet_id, "direction"));
        settingsColor("Color", color, configId(planet_id, "color"));
        _ = configSlider("Size", radius, .{}, 0, 0.2, configId(planet_id, "radius"));
    }

    settingsSubheading("Star Field", configId(root_id, "stars"));
    drawFields(sky, root_id, "", .{.{ "Star Pattern Seed", "star_seed", 0, 1000 }});
}

fn drawAdvancedShadowSettings(shadow: *ShadowConfig, root_id: u64) void {
    settingsSubheading("Cascade Distribution", configId(root_id, "distribution"));
    drawFields(shadow, root_id, "", .{
        .{ "Depth Format", "depth_format" },
        .{ "Distribution Balance", "pssm_lambda", 0, 1 },
        .{ "Nearest Cascade Radius", "min_split_radius", 1, 1000 },
        .{ "Cascades Per Frame", "cascades_per_frame", 1, 16 },
    });

    settingsSubheading("Refresh Schedule", configId(root_id, "refresh"));
    drawFields(shadow, root_id, "", .{
        .{ "Refresh Distribution", "refresh_lambda", 0, 1 },
        .{ "Nearest Refresh (frames)", "min_refresh_frames", 1, 4096 },
        .{ "Farthest Refresh (frames)", "max_refresh_frames", 1, 16384 },
    });

    settingsSubheading("Shadow Filtering", configId(root_id, "filtering"));
    drawFields(shadow, root_id, "", .{
        .{ "Cascade Blend", "cascade_blend", 0, 1 },
        .{ "Outer Fade", "last_cascade_fade", 0, 1 },
        .{ "Blur Radius (blocks)", "blur_radius", 0, 32 },
        .{ "Normal Bias", "normal_bias_scale", 0, 16 },
    });

    settingsSubheading("Shadow Bias", configId(root_id, "bias"));
    drawFields(shadow, root_id, "", .{
        .{ "Constant Bias", "depth_bias_constant", -16, 16 },
        .{ "Slope Bias", "depth_bias_slope", -16, 16 },
        .{ "Bias Clamp", "depth_bias_clamp", 0, 16 },
    });

    settingsSubheading("Advanced Limits", configId(root_id, "limits"));
    drawFields(shadow, root_id, "", .{
        .{ "Minimum Sun Elevation (degrees)", "min_sun_elevation_deg", 0, 45 },
        .{ "Maximum Depth Range", "max_depth_range", 1, 131072 },
        .{ "Minimum Chunk Size (texels)", "min_chunk_texels", 0, 16 },
    });
}

fn drawTerrainDeveloperSettings(self: *Ui, io: std.Io, allocator: std.mem.Allocator) void {
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
            .color_fill = .{ .color = .{ .r = 96, .g = 24, .b = 24, .a = 255 } },
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

    const generator = &self.game.generator;
    dvui.labelNoFmt(@src(), generator.generator.info.name, .{}, .{ .font = .{ .size = 20 }, .gravity_x = 0.5 });
    if (generator.generator.info.description.len > 0) {
        dvui.labelNoFmt(@src(), generator.generator.info.description, .{}, .{ .gravity_x = 0.5, .padding = .{ .y = 4, .h = 8 } });
    }
    drawConfigTree(self, allocator, generator.config);

    if (self.game.spawn.found) {
        dvui.labelNoFmt(@src(), "World spawn is set. Clearing it re-picks on the next world load.", .{}, .{ .gravity_x = 0.5, .padding = .{ .y = 4, .h = 4 } });
    }
    if (dvui.button(@src(), "Reset World Spawn", .{}, .{
        .expand = .horizontal,
        .margin = .{ .y = 4 },
        .padding = .{ .y = 12, .h = 12 },
    })) {
        self.game.resetSpawn(io) catch |err| std.log.err("reset world spawn failed to save: {any}", .{err});
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

fn drawGeneralSettings(self: *Ui, io: std.Io, options: *Game.Options) void {
    if (self.settingsSection(@src(), "Controls", settingsId("controls"), true)) |section| {
        defer section.deinit();
        drawFields(options, settings_root_id, "controls.", .{
            .{ "Mouse Sensitivity", "mouse_sensitivity", 0, 5 },
            .{ "Scroll Sensitivity", "scroll_sensitivity", 0, 5 },
        });
    }

    if (self.settingsSection(@src(), "Key Bindings", settingsId("keymap"), false)) |section| {
        defer section.deinit();
        self.drawKeyBindings(io);
    }

    if (self.settingsSection(@src(), "Player", settingsId("player"), true)) |section| {
        defer section.deinit();
        _ = configSlider("Width (blocks)", &options.player_width, .{}, 0.2, 8, settingsId("player.width"));
        _ = configSlider("Height (blocks)", &options.player_height, .{}, 1, 16, settingsId("player.height"));
        drawFields(options, settings_root_id, "player.", .{
            .{ "Step Height (blocks)", "step_height", 0, 4 },
            .{ "Step Climb Speed (blocks/s)", "step_climb_speed", 1, 64 },
            .{ "Jump Height (blocks)", "jump_height", 0, 8 },
            .{ "Movement Speed (blocks/s)", "move_speed", 0, 64 },
            .{ "Sprint Multiplier", "sprint_multiplier", 1, 3 },
        });
    }

    if (self.settingsSection(@src(), "Admin", settingsId("admin"), false)) |section| {
        defer section.deinit();
        dvui.labelNoFmt(@src(), "Shrinking a grid deletes the items that no longer fit.", .{}, .{ .font = .{ .size = 16 }, .color_text = .red, .padding = .{ .x = 8, .w = 8 } });
        drawFields(options, settings_root_id, "admin.", .{
            .{ "Hotbar Width", "hotbar_width", 1, 16 },
            .{ "Hotbar Height", "hotbar_height", 1, 8 },
            .{ "Inventory Width", "inventory_width", 1, 16 },
            .{ "Inventory Height", "inventory_height", 1, 8 },
        });
        if (self.menu_state.ingame and dvui.button(@src(), "Terrain Developer Settings", .{}, .{ .margin = .{ .y = 8 } })) {
            self.menu_state.terrain_developer_settings = true;
        }
    }

    if (self.settingsSection(@src(), "World Streaming", settingsId("streaming"), true)) |section| {
        defer section.deinit();
        drawFields(options, settings_root_id, "streaming.", .{
            .{ "Minimum Detail Level", "lowest_level", -8, 24 },
            .{ "Maximum Detail Level", "highest_level", 0, 24 },
            .{ "Horizontal Render Distance", "render_distance_x", 6, 64 },
            .{ "Vertical Render Distance", "render_distance_y", 6, 64 },
            .{ "LOD Overlap (chunks)", "lod_overlap", -4, 8 },
        });
        settingsInterval("Mesh Unload Interval (ms)", &options.mesh_unload_frequency_ms, settingsId("streaming.mesh_unload_frequency_ms"));
        settingsInterval("Autosave Interval (ms)", &options.save_frequency_ms, settingsId("streaming.save_frequency_ms"));
    }

    if (self.settingsSection(@src(), "Storage and Tools", settingsId("storage"), false)) |section| {
        defer section.deinit();
        configTextNumber(u64, "Terrain Height Cache (bytes)", &options.terrain_height_cache_bytes, settingsId("storage.terrain_height_cache_bytes"));
        configTextNumber(u64, "Chunk Cache (bytes)", &options.chunk_cache_bytes, settingsId("storage.chunk_cache_bytes"));
        configTextNumber(u64, "Grid Cache (bytes)", &options.grid_cache_bytes, settingsId("storage.grid_cache_bytes"));
        configTextNumber(u64, "Entity Cache (bytes)", &options.entity_cache_bytes, settingsId("storage.entity_cache_bytes"));
        drawFields(options, settings_root_id, "storage.", .{
            .{ "Sphere Size (blocks)", "sphere_size", 1, 512 },
            .{ "Sphere Block", "sphere_block" },
            .{ "Save Mode", "save_mode" },
        });
    }
}

/// Binds `button` to the slot waiting for a press, or cancels the wait on Escape.
/// Returns true when the editor uses the press.
pub fn captureButton(self: *Ui, io: std.Io, button: wio.Button) bool {
    const slot = self.key_capture orelse return false;
    self.key_capture = null;
    if (button == .escape) return true;
    self.keymap.binding(slot.action).slot(slot.which).* = button;
    self.saveKeymap(io);
    return true;
}

fn saveKeymap(self: *Ui, io: std.Io) void {
    self.keymap.save(io, self.keymap_path) catch |err| std.log.err("saving keymap failed: {any}", .{err});
}

const ButtonUses = std.enums.EnumArray(wio.Button, u8);

/// Counts the slots each button fills, so the editor can mark buttons that trigger several actions.
fn buttonUses(keymap: *const Key.Keymap) ButtonUses {
    var uses: ButtonUses = .initFill(0);
    for (std.enums.values(Key.Action)) |action| {
        for (keymap.get(action).buttons()) |maybe_button| {
            if (maybe_button) |button| uses.getPtr(button).* += 1;
        }
    }
    return uses;
}

fn drawKeyBindings(self: *Ui, io: std.Io) void {
    const uses = buttonUses(self.keymap);
    var changed = false;
    for (std.enums.values(Key.Action)) |action| changed = self.bindingRow(action, &uses) or changed;
    if (dvui.button(@src(), "Reset All", .{}, .{ .gravity_x = 0.5, .margin = .{ .y = 8 } })) {
        self.keymap.* = .{};
        changed = true;
    }
    if (changed) self.saveKeymap(io);
}

/// Draws one action's label, both slots, and its reset button. Returns whether the binding changed.
fn bindingRow(self: *Ui, action: Key.Action, uses: *const ButtonUses) bool {
    const id = configId(settingsId("keymap"), @tagName(action));
    var label_buffer: [64]u8 = undefined;
    const row = configRow(titleCase(@tagName(action), &label_buffer), id);
    defer row.deinit();

    const binding = self.keymap.binding(action);
    var changed = false;
    for (std.enums.values(Key.Binding.Which)) |which| {
        changed = self.bindingSlot(.{ .action = action, .which = which }, binding.slot(which), uses, configId(id, @tagName(which))) or changed;
    }
    if (dvui.button(@src(), "Reset", .{}, .{ .id_extra = @intCast(configId(id, "reset")), .gravity_y = 0.5 })) {
        binding.* = Key.Keymap.get(.{}, action);
        changed = true;
    }
    return changed;
}

/// Draws a slot button that waits for a press when clicked, plus its clear button. Returns true when the user clears the slot.
fn bindingSlot(self: *Ui, slot: Key.Slot, button: *?wio.Button, uses: *const ButtonUses, id: u64) bool {
    var name_buffer: [64]u8 = undefined;
    const text = if (std.meta.eql(self.key_capture, slot)) "Press a key..." else if (button.*) |bound| titleCase(@tagName(bound), &name_buffer) else "Unbound";
    const conflict = if (button.*) |bound| uses.get(bound) > 1 else false;
    if (dvui.button(@src(), text, .{}, .{
        .id_extra = @intCast(id),
        .min_size_content = .width(160),
        .gravity_y = 0.5,
        .color_fill = if (conflict) .red else null,
    })) self.key_capture = slot;
    if (!dvui.button(@src(), "x", .{}, .{ .id_extra = @intCast(configId(id, "clear")), .gravity_y = 0.5 })) return false;
    button.* = null;
    return true;
}

fn drawRenderSettings(self: *Ui, allocator: std.mem.Allocator, options: *Game.Options) void {
    const render_options = &options.render_options;
    if (self.settingsSection(@src(), "Rendering", settingsId("rendering"), true)) |section| {
        defer section.deinit();
        drawFields(render_options, settings_root_id, "rendering.", .{.{ "Field of View", "fov", 30, 150 }});
        configTextNumber(f32, "Day/Night Cycle Length (seconds)", &render_options.day_length_sec, settingsId("rendering.day_length_sec"));
        drawFields(render_options, settings_root_id, "rendering.", .{
            .{ "Gamma Correction", "gamma_correction" },
            .{ "Presentation Mode", "present_mode" },
            .{ "Anti Aliasing", "anti_aliasing" },
        });
        configTextString(allocator, "Texture Pack", &render_options.selected_pack, settingsId("rendering.selected_pack"));
        drawFields(render_options, settings_root_id, "rendering.", .{
            .{ "See Through Transparent Blocks", "inside_transparent" },
            .{ "Occlusion Culling", "occlusion_culling" },
        });
    }

    if (self.settingsSection(@src(), "Sky", settingsId("sky"), false)) |section| {
        defer section.deinit();
        drawFields(&render_options.sky, settings_root_id, "sky.", .{
            .{ "Sun Brightness", "sun_intensity", 0, 10 },
            .{ "Sun Glow Strength", "sun_glow_power", 0, 1000 },
            .{ "Sun Size", "sun_angular_radius", 0, 0.2 },
            .{ "Distant Planet Count", "planet_count", 0, 4 },
            .{ "Star Density", "star_density", 0, 200 },
            .{ "Minimum Star Brightness", "star_brightness_min", 0, 1 },
            .{ "Maximum Star Brightness", "star_brightness_max", 0, 1 },
            .{ "Horizon Transition", "transition_power", 0, 8 },
            .{ "Exposure", "exposure", 0, 4 },
        });

        if (self.settingsSection(@src(), "Advanced", settingsId("sky.advanced"), false)) |advanced| {
            defer advanced.deinit();
            drawAdvancedSkySettings(&render_options.sky, settingsId("sky.advanced"));
        }
    }

    if (self.settingsSection(@src(), "Shadows", settingsId("shadows"), true)) |section| {
        defer section.deinit();
        drawFields(&render_options.shadow, settings_root_id, "shadows.", .{
            .{ "Enabled", "enabled" },
            .{ "Cascade Count", "cascade_count", 1, 16 },
            .{ "Lowest Shadow Level", "lowest_shadow_level", -4, 24 },
            .{ "Shadow Map Resolution", "shadow_map_size", 512, 8192 },
            .{ "Shadow Distance", "max_shadow_distance", 1000, 250000 },
            .{ "Shadow Opacity", "shadow_strength", 0, 1 },
            .{ "Debug Cascade Colors", "debug_cascade_colors" },
        });

        if (self.settingsSection(@src(), "Advanced", settingsId("shadows.advanced"), false)) |advanced| {
            defer advanced.deinit();
            drawAdvancedShadowSettings(&render_options.shadow, settingsId("shadows.advanced"));
        }
    }

    if (self.settingsSection(@src(), "Screenshots", settingsId("screenshots"), true)) |section| {
        defer section.deinit();
        settingsEnum("Screenshot Resolution", VulkanContext.ScreenshotResolution, &render_options.screenshot_resolution, settingsId("screenshots.resolution"));
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

fn crossHair() void {
    _ = dvui.label(@src(), "+", .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5, .color_fill = .transparent, .font = .{ .size = 32 } });
}

const selected_slot_color: dvui.Color = .{ .r = 90, .g = 140, .b = 220, .a = 255 };
const slot_border_color: dvui.Color = .{ .r = 150, .g = 150, .b = 150, .a = 160 };
const item_icon_size: f32 = 36;
/// Space between the main grid and the hotbar on the inventory page.
const hotbar_gap: f32 = 12;

/// Hotbar along the bottom. Number keys move the selection. Slots do not take
/// clicks: play has no cursor, and the inventory page draws its own clickable hotbar.
fn hotbar(self: *Ui) void {
    const column = bottomColumn();
    defer column.deinit();
    self.gridPanel(.hotbar, null);
}

/// The column the hotbar sits in, so the inventory page can draw the hotbar in the same place.
fn bottomColumn() *dvui.BoxWidget {
    return dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_x = 0.5, .gravity_y = 1.0, .margin = .{ .y = 12 } });
}

/// The main grid right above the hotbar, over a dimmed game view. Clicking a slot
/// picks it up and clicking another moves it there (see `Item.moveStack`), across
/// both grids. `held` only names the slot, so closing the page can never lose an item.
fn inventoryMenu(self: *Ui, held: *?GridSlot) void {
    {
        const backdrop = dvui.overlay(@src(), .{ .expand = .both, .background = true, .color_fill = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 120 } } });
        defer backdrop.deinit();
        const column = bottomColumn();
        defer column.deinit();
        self.gridPanel(.main, held);
        _ = dvui.spacer(@src(), .{ .min_size_content = .height(hotbar_gap) });
        self.gridPanel(.hotbar, held);
    }
    if (held.*) |slot| self.cursorIcon(self.gridSlot(slot).*.?);
}

/// One slot in one of the player's grids.
const GridSlot = struct {
    grid: EntityTypes.Player.Grid,
    slot: Item.Inventory.Slot,
};

/// Draws one grid. With `held`, slots take clicks. Without it, the grid only shows the items.
fn gridPanel(self: *Ui, grid: EntityTypes.Player.Grid, held: ?*?GridSlot) void {
    const player = self.game.player;
    const inventory = player.inventories.getPtr(grid);
    const panel = dvui.box(@src(), .{}, .{
        .id_extra = @backingInt(grid),
        .gravity_x = 0.5,
        .background = true,
        .color_fill = .{ .color = .{ .r = 40, .g = 40, .b = 40, .a = 160 } },
        .padding = .all(2),
        .border = .all(2),
        .color_border = .{ .color = slot_border_color },
    });
    defer panel.deinit();

    for (0..inventory.height()) |row| {
        const bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = row });
        defer bar.deinit();
        for (0..inventory.width) |col| {
            const here: GridSlot = .{ .grid = grid, .slot = .{ .row = @intCast(row), .col = @intCast(col) } };
            const selected = grid == .hotbar and row == player.selected_row and col == player.selected_col;
            const slot = itemSlot(col, selected);
            defer slot.deinit();
            if (held) |pick| {
                if (dvui.clicked(slot.data(), .{})) self.clickSlot(pick, here);
                // The held item follows the cursor instead of drawing in its slot.
                if (std.meta.eql(pick.*, here)) continue;
            }
            const item = self.gridSlot(here).* orelse continue;
            self.itemIcon(item);
            // Like Minecraft, names only show on the open page while the cursor is empty.
            if (held) |pick| if (pick.* == null) itemTooltip(slot.data(), item.item_type);
        }
    }
}

fn gridSlot(self: *Ui, slot: GridSlot) *?Item.Item {
    return self.game.player.inventories.getPtr(slot.grid).at(slot.slot);
}

fn itemTooltip(slot: *const dvui.WidgetData, item_type: Item.ItemType) void {
    const name = switch (item_type) {
        inline else => |tag| comptime itemName(@tagName(tag)),
    };
    dvui.tooltip(@src(), .{ .active_rect = slot.borderRectScale().r, .delay = 0 }, "{s}", .{name}, .{});
}

/// Display name from an item tag. Each snake_case or PascalCase word starts
/// uppercase, and a space goes between words ("fine_grass" -> "Fine Grass", "PlaceRod" -> "Place Rod").
fn itemName(comptime tag: []const u8) []const u8 {
    var name: []const u8 = "";
    for (tag, 0..) |character, i| {
        if (character == '_') continue;
        const word_start = i == 0 or tag[i - 1] == '_' or std.ascii.isUpper(character);
        const separator = if (word_start and name.len > 0) " " else "";
        name = name ++ separator ++ .{if (word_start) std.ascii.toUpper(character) else character};
    }
    return name;
}

test itemName {
    try std.testing.expectEqualStrings("Place Rod", comptime itemName("PlaceRod"));
    try std.testing.expectEqualStrings("Fine Grass", comptime itemName("fine_grass"));
}

/// Picks up `slot` when the cursor holds nothing, otherwise moves the held item onto it.
fn clickSlot(self: *Ui, held: *?GridSlot, slot: GridSlot) void {
    if (held.*) |from| {
        Item.moveStack(self.gridSlot(from), self.gridSlot(slot));
        held.* = null;
    } else if (self.gridSlot(slot).* != null) {
        held.* = slot;
    }
}

/// One slot frame. Its children stack on top of each other, so the amount overlays the icon.
fn itemSlot(id_extra: usize, selected: bool) *dvui.OverlayWidget {
    return dvui.overlay(@src(), .{
        .id_extra = id_extra,
        .min_size_content = .all(item_icon_size + 4),
        .padding = .all(2),
        .margin = .all(2),
        .border = .all(2),
        .color_border = .{ .color = slot_border_color },
        .color_fill = .{ .color = if (selected) selected_slot_color else .transparent },
        .background = true,
    });
}

/// The item's icon, with its amount in the corner when the stack holds more than one.
fn itemIcon(self: *Ui, item: Item.Item) void {
    const texture = self.itemTexture(item.item_type);
    _ = dvui.image(@src(), .{ .source = .{ .texture = texture } }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .min_size_content = .all(item_icon_size),
    });
    if (item.amount <= 1) return;
    dvui.label(@src(), "{d}", .{item.amount}, .{
        .gravity_x = 1.0,
        .gravity_y = 1.0,
        .padding = .all(0),
        .font = .{ .size = 10 },
    });
}

/// Draws the held item centered on the mouse, above the page drawn before it.
fn cursorIcon(self: *Ui, item: Item.Item) void {
    const texture = self.itemTexture(item.item_type);
    const scale = dvui.windowRectScale().s;
    const size = item_icon_size * scale;
    const mouse = dvui.currentWindow().mouse_pt;
    const rect: dvui.Rect.Physical = .{ .x = mouse.x - size / 2, .y = mouse.y - size / 2, .w = size, .h = size };
    dvui.renderTexture(texture, .{ .r = rect, .s = scale }, .{}) catch |err| std.log.warn("inventory: drawing the held item failed: {any}", .{err});
}

/// The pack's icon for an item, or the missing texture when the pack has none.
fn itemTexture(self: *const Ui, item_type: Item.ItemType) dvui.Texture {
    return self.item_textures.get(item_type) orelse self.missing_item_texture;
}

fn newGameGenerator(self: *Ui) ?*generator_loader.Generator {
    const index = self.new_game.generator_index orelse return null;
    return &self.generators.generators.items[index];
}

fn selectNewGameGenerator(self: *Ui, allocator: std.mem.Allocator, index: usize) !void {
    if (self.new_game.generator_index == index) return;
    const generator = &self.generators.generators.items[index];
    const config = generator.defaultConfig(allocator) orelse return error.OutOfMemory;
    if (self.new_game.config) |old_config| generator_api.free(allocator, old_config);
    self.new_game.preset_index = generator.defaultPresetIndex();
    self.new_game.config = config;
    self.new_game.generator_index = index;
}

fn selectNewGamePreset(self: *Ui, allocator: std.mem.Allocator, index: usize) !void {
    const generator = self.newGameGenerator() orelse return;
    const config = generator.presetConfig(allocator, index) orelse return error.OutOfMemory;
    errdefer generator_api.free(allocator, config);
    if (self.new_game.config) |old_config| generator_api.free(allocator, old_config);
    self.new_game.config = config;
    self.new_game.preset_index = index;
}

const max_generator_dropdown_entries: usize = 16;

fn newGameMenu(self: *Ui, io: std.Io, allocator: std.mem.Allocator) !void {
    const page = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer page.deinit();

    if (!self.menu_state.ingame) self.sidebar();

    const options = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = .{ .color = .{ .r = 48, .g = 77, .b = 84, .a = 225 } } });
    defer options.deinit();

    const content = pageContent(1);
    defer content.deinit();

    try self.ensureNewGameGenerator(allocator);

    const create = dvui.button(@src(), "Create World", .{}, .{ .gravity_x = 0.5, .color_fill = .blue, .margin = .all(16), .expand = .horizontal, .padding = .{ .y = 16, .h = 16 } });

    {
        const world_name_widget = dvui.textEntry(@src(), .{ .placeholder = "World Name" }, .{ .gravity_x = 0.5 });
        defer world_name_widget.deinit();
        if (create) return self.createWorld(io, allocator, world_name_widget.textGet());
    }

    drawSpawnConfig(&self.new_game.spawn_config);

    try self.generatorDropdown(allocator);
    try self.presetDropdown(allocator);

    const scroll = dvui.scrollArea(@src(), .{ .vertical = .auto }, .{ .expand = .both });
    defer scroll.deinit();
    if (self.new_game.config) |config| drawConfigTree(self, allocator, config);
}

fn ensureNewGameGenerator(self: *Ui, allocator: std.mem.Allocator) !void {
    const generators = self.generators.generators.items;
    if (self.new_game.generator_index != null or generators.len == 0) return;
    const initial = for (generators, 0..) |generator, i| {
        if (std.mem.eql(u8, generator.info.name, Game.WorldOptions.default.generator_name)) break i;
    } else 0;
    try self.selectNewGameGenerator(allocator, initial);
}

fn createWorld(self: *Ui, io: std.Io, allocator: std.mem.Allocator, world_name: []const u8) !void {
    if (world_name.len == 0) return error.WorldNameMissing;
    if (!std.unicode.utf8ValidateSlice(world_name)) return error.InvalidName;
    if (std.mem.findScalar(u8, world_name, '/') != null) return error.InvalidName;

    std.log.info("Creating world: {s}", .{world_name});
    var worlds_dir = try std.Io.Dir.cwd().createDirPathOpen(io, self.worlds_path, .{});
    defer worlds_dir.close(io);
    if (try worldExists(io, worlds_dir, world_name)) return error.WorldNameExists;
    var world_folder = try worlds_dir.createDirPathOpen(io, world_name, .{});
    defer world_folder.close(io);
    const game_path = try std.Io.Dir.path.join(allocator, &.{ self.worlds_path, world_name });
    defer allocator.free(game_path);
    const world_options: Game.WorldOptions = .{
        .generator_name = if (self.newGameGenerator()) |generator| generator.info.name else Game.WorldOptions.default.generator_name,
        .world_config = self.new_game.world_config,
        .spawn = self.new_game.spawn_config,
    };
    try world_options.save(io, game_path);
    try self.saveGeneratorConfig(allocator, io, game_path);
    // Mark the list stale before the fallible open so a failed open still refreshes.
    self.world_list_dirty = true;
    try self.openGame(io, allocator, game_path);
    self.menu_state.enterGame();
}

fn worldExists(io: std.Io, dir: std.Io.Dir, name: []const u8) !bool {
    dir.access(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn saveGeneratorConfig(self: *Ui, allocator: std.mem.Allocator, io: std.Io, game_path: []const u8) !void {
    const generator = self.newGameGenerator() orelse return;
    const config = self.new_game.config orelse return;
    generator.api.config_set_seeds(&io, config);
    const config_dir = try std.Io.Dir.path.join(allocator, &.{ game_path, "config" });
    defer allocator.free(config_dir);
    try generator.saveConfig(allocator, io, config_dir, config);
}

const newgame_spawn_id: u64 = 0x7370776e6366673f;

fn newgameSpawnId(path: []const u8) u64 {
    return configId(newgame_spawn_id, path);
}

fn spawnFloatRow(label: []const u8, value: f64, id: u64) f64 {
    var as_f32: f32 = @floatCast(value);
    configTextNumber(f32, label, &as_f32, id);
    return as_f32;
}

/// Draws only the editable spawn settings. The resolved `pos` and `found` stay hidden.
fn drawSpawnConfig(spawn: *EntityRegistry.SpawnConfig) void {
    dvui.labelNoFmt(@src(), "Spawn", .{}, .{ .font = .{ .size = 24 } });
    spawn.center[0] = spawnFloatRow("Center X", spawn.center[0], newgameSpawnId("center_x"));
    spawn.center[1] = spawnFloatRow("Center Y", spawn.center[1], newgameSpawnId("center_y"));
    spawn.center[2] = spawnFloatRow("Center Z", spawn.center[2], newgameSpawnId("center_z"));
    var as_u64: u64 = spawn.range;
    configTextNumber(u64, "Range", &as_u64, newgameSpawnId("range"));
    spawn.range = @intCast(@min(as_u64, std.math.maxInt(u32)));
    settingsEnum("Game Mode", EntityTypes.Player.GameMode, &spawn.mode, newgameSpawnId("mode"));
}

fn generatorDropdown(self: *Ui, allocator: std.mem.Allocator) !void {
    const generators = self.generators.generators.items;
    if (generators.len == 0) return;
    const count = @min(generators.len, max_generator_dropdown_entries);
    var names_buffer: [max_generator_dropdown_entries][]const u8 = undefined;
    for (names_buffer[0..count], generators[0..count]) |*name, *generator| name.* = generator.info.name;
    const selected = self.new_game.generator_index orelse 0;
    const previous = if (selected < count) selected else 0;
    var choice: usize = previous;
    dvui.labelNoFmt(@src(), "Generator", .{}, .{ .font = .{ .size = 24 } });
    _ = dvui.dropdown(@src(), names_buffer[0..count], .{ .choice = &choice }, .{}, .{});
    if (choice != previous) try self.selectNewGameGenerator(allocator, choice);
}

fn presetDropdown(self: *Ui, allocator: std.mem.Allocator) !void {
    const generator = self.newGameGenerator() orelse return;
    const count = @min(generator.presetCount(), max_generator_dropdown_entries);
    if (count == 0) return;
    var names_buffer: [max_generator_dropdown_entries][]const u8 = undefined;
    for (names_buffer[0..count], 0..) |*dest, i| dest.* = generator.presetName(i);
    const previous = if (self.new_game.preset_index < count) self.new_game.preset_index else 0;
    var choice: usize = previous;
    dvui.labelNoFmt(@src(), "Preset", .{}, .{ .font = .{ .size = 24 } });
    _ = dvui.dropdown(@src(), names_buffer[0..count], .{ .choice = &choice }, .{}, .{});
    if (choice != previous) try self.selectNewGamePreset(allocator, choice);
}

fn mainPage(self: *Ui, io: std.Io, allocator: std.mem.Allocator) !void {
    const menuarea = dvui.overlay(@src(), .{ .expand = .both });
    defer menuarea.deinit();
    _ = dvui.image(@src(), .{ .source = .{ .texture = self.menu_background }, .shrink = .vertical }, .{ .expand = .both });

    const page = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer page.deinit();

    self.sidebar();

    const menu = dvui.box(@src(), .{}, .{ .background = false, .color_fill = .{ .color = .{ .r = 24, .g = 24, .b = 24, .a = 255 } }, .expand = .both });
    defer menu.deinit();

    const top = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    const terrafinity = dvui.textLayout(@src(), .{ .break_lines = false }, .{ .gravity_x = 0.5, .color_fill = .transparent });
    terrafinity.addText("terrafinity", .{ .font = .{ .size = 64, .family = pixel_font } });
    terrafinity.deinit();
    top.deinit();
    try self.continueMenu(io, allocator);
}

fn sidebar(self: *Ui) void {
    const bar = dvui.box(@src(), .{ .dir = .vertical }, .{ .background = true, .color_fill = .{ .color = .{ .r = 48, .g = 77, .b = 48, .a = 225 } }, .expand = .vertical, .min_size_content = .width(128) });
    defer bar.deinit();
    const button_options: dvui.Options = .{ .gravity_x = 0.5, .color_fill = .blue, .margin = .all(16), .expand = .horizontal, .padding = .{ .y = 16, .h = 16 } };

    if (dvui.button(@src(), "Home", .{}, button_options)) {
        self.menu_state.page = .main;
        // External changes may add or remove worlds, so refresh the list on entry.
        self.world_list_dirty = true;
        return;
    }
    if (dvui.button(@src(), "Settings", .{}, button_options)) {
        self.menu_state.page = .settings;
        return;
    }
    if (dvui.button(@src(), "Quit", .{}, button_options.override(.{ .color_fill = .olive }))) self.running.store(false, .unordered);
}

const FolderData = struct {
    access_time: std.Io.Timestamp,
    name: []const u8,
};

fn continueMenu(self: *Ui, io: std.Io, allocator: std.mem.Allocator) !void {
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
        const new_game = menuCard(@src(), .{ .expand = .vertical });
        defer new_game.deinit();
        if (dvui.button(@src(), "+", .{}, .{ .expand = .both, .color_fill = .blue, .font = .{ .size = 96, .weight = .bold, .family = comptime dvui.Font.array("Vera Sans") } })) {
            self.menu_state.page = .newgame;
            return;
        }
    }

    if (self.world_list_dirty) try self.refreshWorldList(io, allocator);
    for (self.world_list.items, 0..) |item, i| {
        const game = menuCard(@src(), .{ .id_extra = i, .expand = .vertical });
        defer game.deinit();

        const text = dvui.textLayout(@src(), .{}, .{ .gravity_x = 0.5 });
        text.addText(item.name, .{ .font = .{ .family = pixel_font } });
        text.deinit();

        const bottom = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 1.0, .expand = .horizontal });
        defer bottom.deinit();

        if (dvui.button(@src(), "Play", .{}, .{ .gravity_x = 0.0, .expand = .horizontal, .margin = .{ .x = 8, .w = 8, .h = 4 }, .font = .{ .family = pixel_font }, .color_fill = .blue, .corners = .all(2) })) {
            std.log.info("Joining game: {s}", .{item.name});
            const world_path = try std.Io.Dir.path.join(allocator, &.{ self.worlds_path, item.name });
            defer allocator.free(world_path);
            try self.openGame(io, allocator, world_path);
            self.menu_state.enterGame();
            return;
        }

        if (dvui.button(@src(), "Delete", .{}, .{ .gravity_x = 0.0, .expand = .none, .margin = .{ .w = 8, .h = 4 }, .font = .{ .family = pixel_font }, .color_fill = .red, .corners = .all(2) })) {
            if (self.delete_world_name) |old| allocator.free(old);
            self.delete_world_name = try allocator.dupe(u8, item.name);
        }
    }

    if (self.delete_world_name) |name| try self.deleteWorldDialog(io, allocator, name);
}

/// Reads the worlds folder again and sorts the list with the newest world first.
fn refreshWorldList(self: *Ui, io: std.Io, allocator: std.mem.Allocator) !void {
    var worlds_folder = try std.Io.Dir.cwd().createDirPathOpen(io, self.worlds_path, .{ .open_options = .{ .iterate = true } });
    defer worlds_folder.close(io);
    while (self.world_list.pop()) |world| allocator.free(world.name);
    var it = worlds_folder.iterate();
    while (try it.next(io)) |item| {
        if (item.kind != .directory) continue;
        const stat = try worlds_folder.statFile(io, item.name, .{});
        const world: FolderData = .{ .access_time = stat.ctime, .name = try allocator.dupe(u8, item.name) };
        errdefer allocator.free(world.name);
        try self.world_list.append(allocator, world);
    }
    std.sort.pdq(FolderData, self.world_list.items, {}, newerFirst);
    self.world_list_dirty = false;
}

/// Asks the user to confirm the deletion of `name`, which `delete_world_name` owns.
fn deleteWorldDialog(self: *Ui, io: std.Io, allocator: std.mem.Allocator, name: []const u8) !void {
    var open: bool = true;
    const confirm = dvui.floatingWindow(
        @src(),
        .{ .modal = true, .resize = .none, .open_flag = &open },
        .{ .max_size_content = .width(480) },
    );
    defer confirm.deinit();

    dvui.labelNoFmt(@src(), "Delete world", .{}, .{ .gravity_x = 0.5, .font = .{ .size = 24 } });

    var message_buffer: [512]u8 = undefined;
    const message = std.mem.print(&message_buffer, "Are you sure you want to delete \"{s}\"? This cannot be undone.", .{name}) catch unreachable;
    const message_text = dvui.textLayout(@src(), .{}, .{ .gravity_x = 0.5 });
    message_text.addText(message, .{});
    message_text.deinit();

    const buttons = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
    defer buttons.deinit();

    const canceled = dvui.button(@src(), "Cancel", .{}, .{ .margin = .all(8) });
    if (!canceled and dvui.button(@src(), "Delete", .{}, .{ .margin = .all(8), .color_fill = .red })) {
        self.delete_world_name = null;
        defer allocator.free(name);
        // A failed delete can leave a stale entry, so refresh the list on every path.
        self.world_list_dirty = true;
        var worlds_folder = try std.Io.Dir.cwd().createDirPathOpen(io, self.worlds_path, .{});
        defer worlds_folder.close(io);
        return worlds_folder.deleteTree(io, name);
    }
    // Esc and a click outside the modal also dismiss the dialog.
    if (open and !canceled) return;
    allocator.free(name);
    self.delete_world_name = null;
}

fn newerFirst(_: void, a: FolderData, b: FolderData) bool {
    return a.access_time.nanoseconds > b.access_time.nanoseconds;
}

fn openGame(self: *Ui, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    self.vk_ctx.swapchain_gamma.store(self.config.game_config.render_options.gamma_correction, .monotonic);
    try self.game.init(io, allocator, &self.config.game_config, self.config_lock, path, self.vk_ctx, self.generators);
    std.log.info("opening game", .{});
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

    const packed_weight: f32 = if (widget.init_opts.num_packed_expanded) |num| @floatFromInt(num) else data_prev.total_weight;
    if (packed_weight <= 0) return;
    widget.pixels_per_w = @max(0, child_size - data_prev.min_space_taken) / packed_weight;
}

/// Reports whether the mouse is over the widget, and shows the hand cursor when it is.
fn hovered(wd: *const dvui.WidgetData) bool {
    const hover_rect = wd.borderRectScale().r;
    for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = wd.id, .r = hover_rect })) continue;
        if (e.evt != .mouse or e.evt.mouse.action != .position) continue;
        dvui.cursorSet(.hand);
        return true;
    }
    return false;
}

fn drawConfigTree(self: *Ui, allocator: std.mem.Allocator, tree: *generator_api.ConfigTree) void {
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

fn drawParams(self: *Ui, allocator: std.mem.Allocator, params: *[]generator_api.Param, parent_id: u64) void {
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

fn drawParam(self: *Ui, allocator: std.mem.Allocator, param: *generator_api.Param, id: u64) void {
    if (!paramVisible(param)) return;

    var label_buffer: [256]u8 = undefined;
    const label = configLabel(param, &label_buffer);
    switch (param.value) {
        .group => |*group| {
            const box = self.collapsibleSection(@src(), label, id, defaultSectionExpanded(param.name), 4) orelse return;
            defer box.deinit();
            drawParams(self, allocator, &group.params, id);
        },
        .array => |*array| drawArray(self, allocator, label, array, id),
        .f32 => _ = configSlider(label, &param.value.f32, param.spec, 0, 1, id),
        .i32 => configSliderInt(label, &param.value.i32, param.spec, id),
        .u32 => configSliderUInt(label, &param.value.u32, param.spec, id),
        .u64 => configTextNumber(u64, label, &param.value.u64, id),
        .bool => _ = dvui.checkbox(@src(), &param.value.bool, label, .{ .id_extra = @intCast(id) }),
        .string => configTextString(allocator, label, &param.value.string, id),
        .choice => configChoiceDropdown(label, param.spec, &param.value.choice, id),
    }
    if (param.spec.description.len == 0) return;
    dvui.labelNoFmt(@src(), param.spec.description, .{}, .{
        .id_extra = @intCast(id),
        .color_fill = .{ .color = .{ .r = 160, .g = 180, .b = 160, .a = 255 } },
        .font = .{ .size = 11 },
        .padding = .{ .x = 8, .w = 8 },
    });
}

fn drawArray(self: *Ui, allocator: std.mem.Allocator, name: []const u8, array: *generator_api.Array, id: u64) void {
    if (!self.sectionHeader(id, true, "{s} ({d})", .{ name, array.items.len })) return;

    const contents = configBox(@src(), configId(id, "contents"), .{ .r = 16, .g = 24, .b = 16, .a = 255 }, .{ .x = 8, .w = 8, .y = 4, .h = 4 });
    defer contents.deinit();

    for (array.items, 0..) |*item, i| {
        const item_id = configIndexId(id, i);
        const item_expanded = self.config_section_states.get(item_id) orelse (i == 0);
        var item_title_buffer: [64]u8 = undefined;
        const item_title = sectionTitle(&item_title_buffer, item_expanded, "Item {d}", .{i + 1});
        if (dvui.button(@src(), item_title, .{}, .{
            .expand = .horizontal,
            .id_extra = @intCast(configId(item_id, "header")),
            .color_fill = .{ .color = .{ .r = 61, .g = 107, .b = 61, .a = 255 } },
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

fn configLabel(param: *const generator_api.Param, buffer: *[256]u8) []const u8 {
    return titleCase(if (param.spec.label.len > 0) param.spec.label else param.name, buffer);
}

/// Writes `source` with underscores as spaces and each word capitalized, truncated to `buffer`.
fn titleCase(source: []const u8, buffer: []u8) []const u8 {
    const length = @min(source.len, buffer.len);
    for (buffer[0..length], source[0..length], 0..) |*dest, character, i| {
        const word_start = i == 0 or source[i - 1] == '_';
        dest.* = if (character == '_') ' ' else if (word_start) std.ascii.toUpper(character) else character;
    }
    return buffer[0..length];
}

fn defaultSectionExpanded(name: []const u8) bool {
    return !std.mem.endsWith(u8, name, "_noise") and !std.mem.eql(u8, name, "terrain_noise2");
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

/// Draws a labeled text entry over `buffer` and returns the text the user typed.
fn configTextRow(name: []const u8, buffer: []u8, id: u64) []u8 {
    const row = configRow(name, id);
    defer row.deinit();
    var widget = dvui.textEntry(@src(), .{ .text = .{ .buffer = buffer }, .placeholder = name }, .{ .id_extra = @intCast(id), .expand = .horizontal });
    defer widget.deinit();
    return widget.textGet();
}

/// Numeric text field that writes `value` only when the text parses within range.
fn configTextNumber(comptime T: type, name: []const u8, value: *T, id: u64) void {
    const row = configRow(name, id);
    defer row.deinit();
    // Finite bounds reject overflowing float input such as "1e99".
    const is_float = @typeInfo(T) == .float;
    _ = dvui.textEntryNumber(@src(), T, .{
        .value = value,
        .placeholder = name,
        .min = if (is_float) -std.math.floatMax(T) else null,
        .max = if (is_float) std.math.floatMax(T) else null,
    }, .{ .id_extra = @intCast(id), .expand = .horizontal });
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

test {
    std.testing.refAllDecls(Ui);
}
