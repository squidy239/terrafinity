const std = @import("std");

const dvui = @import("dvui");
const gl = @import("gl");
const tracy = @import("tracy");
const wio = @import("wio");
const zm = @import("zm");

const Entity = @import("entity/Entity.zig");
const EntityRegistry = @import("entity/EntityRegistry.zig");
const EntityTypes = @import("entity/EntityTypes.zig");
const Key = @import("Key.zig");
const ConcurrentHashMap = @import("libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const utils = @import("libs/utils.zig");
const Mesher = @import("Mesher.zig");
pub const Renderer = @import("Renderer.zig");
const BFA = @import("world/BufferFirstAllocator.zig");
const Chunk = @import("world/Chunk.zig");
const Geometry = @import("world/structures/Geometry.zig");
const TexturedSphere = @import("world/structures/TexturedSphere.zig");
const World = @import("world/World.zig");
const Io = std.Io;
const Game = @This();

allocator: std.mem.Allocator,
world: World,
player: *EntityTypes.Player,
opengl_renderer: Renderer.OpenGl,
renderer: Renderer,
generator: World.DefaultGenerator,
world_storage: World.WorldStorage,
game_arena: std.heap.ArenaAllocator,
loaded_or_meshed: ConcurrentHashMap(World.ChunkPos, NodeData, std.hash_map.AutoContext(World.ChunkPos), 80, 128),

entity_registry: EntityRegistry,

selected_inventory_row: std.atomic.Value(u32) = .init(0),
selected_inventory_col: std.atomic.Value(u32) = .init(0),

last_chunk_load: std.Io.Timestamp = .zero,
chunk_load_is_running: std.atomic.Value(bool) = .init(false),
load_future: ?std.Io.Future(@typeInfo(@TypeOf(loadChunks)).@"fn".return_type.?) = null,

last_mesh_unload: std.Io.Timestamp = .zero,
mesh_unload_is_running: std.atomic.Value(bool) = .init(false),
mesh_unload_future: ?std.Io.Future(@typeInfo(@TypeOf(unloadChunkMeshes)).@"fn".return_type.?) = null,

last_save: std.Io.Timestamp = .zero,
save_is_running: std.atomic.Value(bool) = .init(false),
save_future: ?std.Io.Future(@typeInfo(@TypeOf(saveFuture)).@"fn".return_type.?) = null,

group: std.Io.Group = .init,
/// This error is handeled on the next frame and will close the game
deferred_error: std.atomic.Value(@Int(.unsigned, @bitSizeOf(anyerror))) = .init(@intFromError(error.NoError)),

options: *Options,
options_lock: *std.Io.RwLock,
running: std.atomic.Value(bool),

last_frametime: std.Io.Timestamp,

debug_menu: struct {
    fps: std.atomic.Value(f32) = .init(0),
    meshes: std.atomic.Value(u64) = .init(0),
} = .{},

const NodeData = struct {
    /// How many direct children are currently subtree-covered.
    covered_children: [World.scale_factor][World.scale_factor][World.scale_factor]bool = @splat(@splat(@splat(false))),
    /// True when this chunk is queued or currently in the renderer.
    /// False for ghost entries that exist only to track child coverage.
    is_active: bool = false,
    /// True when this chunk is queued for rendering but not yet processed.
    is_queued: bool = false,

    structures_generated: bool,

    pub fn noCoveredChildren(state: NodeData) bool {
        return std.meta.eql(state.covered_children, @as([World.scale_factor][World.scale_factor][World.scale_factor]bool, @splat(@splat(@splat(false)))));
    }

    pub fn allCoveredChildren(state: NodeData) bool {
        return std.meta.eql(state.covered_children, @as([World.scale_factor][World.scale_factor][World.scale_factor]bool, @splat(@splat(@splat(true)))));
    }
};

fn markCovered(self: *@This(), io: std.Io, allocator: std.mem.Allocator, pos: World.ChunkPos) !void {
    _, const highest = self.getLevels(io);
    const parent = pos.parent();
    const pos_in_parent = pos.posInParent();
    if (parent.level > highest) return;

    var bubble_up = false;
    {
        const bucket = self.loaded_or_meshed.getBucket(parent);
        try bucket.lock.lock(io);
        defer bucket.lock.unlock(io);
        var state: Game.NodeData = bucket.hash_map.get(parent) orelse .{ .structures_generated = false };

        const was_covering = state.allCoveredChildren() or state.is_active;
        state.covered_children[pos_in_parent[0]][pos_in_parent[1]][pos_in_parent[2]] = true;
        const is_covering = state.allCoveredChildren() or state.is_active;

        // The thread sanitizer warning that points here may be indirectly related to https://codeberg.org/ziglang/zig/issues/35250
        // If its not I have no idea but I will come back to it once 35250 is fixed
        // It repos better with 1 loaded_or_meshed bucket and 128 threads for Io
        try bucket.hash_map.put(allocator, parent, state);

        bubble_up = !was_covering and is_covering;
    }

    if (bubble_up) {
        try self.markCovered(io, allocator, parent);
    }
}

fn markUncovered(self: *@This(), io: std.Io, allocator: std.mem.Allocator, pos: World.ChunkPos) !void {
    const parent = pos.parent();
    const pos_in_parent = pos.posInParent();

    var bubble_up = false;
    {
        const bucket = self.loaded_or_meshed.getBucket(parent);
        try bucket.lock.lock(io);
        defer bucket.lock.unlock(io);
        var state = bucket.hash_map.get(parent) orelse return;

        const was_covering = state.allCoveredChildren() or state.is_active;
        state.covered_children[pos_in_parent[0]][pos_in_parent[1]][pos_in_parent[2]] = false;
        const is_covering = state.allCoveredChildren() or state.is_active;

        const remove_node = state.noCoveredChildren() and !state.is_active and !state.is_queued;
        if (remove_node) {
            _ = bucket.hash_map.remove(parent);
        } else {
            try bucket.hash_map.put(allocator, parent, state);
        }

        bubble_up = was_covering and !is_covering;
    }

    if (bubble_up) {
        try self.markUncovered(io, allocator, parent);
    }
}

fn canUnloadMesh(self: *@This(), io: std.Io, chunk_pos: World.ChunkPos) bool {
    var parent = chunk_pos;
    _, const highest_level = self.getLevels(io);
    if (parent.level > highest_level) return true;
    while (parent.level < highest_level) {
        parent = parent.parent();
        std.debug.assert(parent.level <= highest_level);
        if (self.loaded_or_meshed.get(io, parent)) |par| {
            if (par.is_active) return true;
        }
    }
    std.debug.assert(parent.level == highest_level);

    {
        // Check if the highest level parent is out of render distance.
        self.player.physics.mutex.lockUncancelable(io);
        const player_pos = self.player.physics.pos;
        self.player.physics.mutex.unlock(io);
        const render_distance = self.getRenderDistance(io);
        const inside_range = keepLoaded(null, null, player_pos, parent, null, render_distance);
        if (!inside_range) return true;
    }
    const bucket = self.loaded_or_meshed.getBucket(chunk_pos);
    bucket.lock.lockSharedUncancelable(io);
    defer bucket.lock.unlockShared(io);
    const state = bucket.hash_map.get(chunk_pos) orelse return false;
    return state.allCoveredChildren();
}

fn tryRemoveChunkFromLoaded(
    self: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    chunk_pos: World.ChunkPos,
) !void {
    if (!self.canUnloadMesh(io, chunk_pos)) return;
    const bucket = self.loaded_or_meshed.getBucket(chunk_pos);
    var was_covering: bool = undefined;
    var is_covering: bool = undefined;
    {
        try bucket.lock.lock(io);
        defer bucket.lock.unlock(io);

        var state = bucket.hash_map.get(chunk_pos) orelse return;

        const was_active = state.is_active;
        const was_queued = state.is_queued;

        // Only return if it's a completely dead ghost node
        if (!was_active and !was_queued) {
            std.debug.assert(!state.noCoveredChildren());
            return;
        }

        was_covering = state.allCoveredChildren() or state.is_active;

        state.is_active = false;
        state.is_queued = false;

        is_covering = state.allCoveredChildren() or state.is_active;

        if (state.noCoveredChildren()) {
            _ = bucket.hash_map.remove(chunk_pos); // ghost with nothing to track
        } else {
            try bucket.hash_map.put(allocator, chunk_pos, state);
        }
    }

    if (was_covering and !is_covering) {
        try self.markUncovered(io, allocator, chunk_pos);
    }
}

pub const Options = struct {
    mouse_sensitivity: f32 = 0.5,
    scroll_sensitivity: f32 = 0.1,

    lowest_level: i32 = 0,
    highest_level: i32 = 10,

    render_distance_x: u32 = 8,
    render_distance_y: u32 = 6,

    loader_frequency_ms: u64 = 250,
    mesh_unload_frequency_ms: u64 = 500,
    save_frequency_ms: u64 = 5000,

    terrain_height_cache_bytes: u64 = 268435456,
    chunk_cache_bytes: u64 = 1073741824,
    grid_cache_bytes: u64 = 1073741824,

    sphere_size: u32 = 100,
    sphere_block: World.Block = .air,

    render_options: Renderer.OpenGl.RenderOptions = .{},

    pub const structui_options: dvui.struct_ui.StructOptions(@This()) = .initWithDefaults(.{
        .highest_level = .{ .number = .{
            .display = .read_write,
            .min = 1,
            .max = 24,
            .widget_type = .slider,
        } },
        .lowest_level = .{ .number = .{
            .display = .none,
        } },
        .render_distance_x = .{ .number = .{
            .min = 6,
            .max = 32,
            .widget_type = .slider,
        } },
        .mouse_sensitivity = .{ .number = .{
            .min = 0,
            .max = 5,
            .widget_type = .slider,
        } },
        .render_distance_y = .{ .number = .{
            .min = 6,
            .max = 32,
            .widget_type = .slider,
        } },
    }, null);
};

pub const WorldOptions = struct {
    pub const default: @This() = .{ .generator_config = .default, .world_config = .{} };
    generator_config: World.DefaultGenerator.Params,
    world_config: World.WorldConfig,

    pub fn fromWorldFolder(folder: []const u8, io: std.Io, allocator: std.mem.Allocator) !WorldOptions {
        var world_folder = try std.Io.Dir.cwd().createDirPathOpen(io, folder, .{});
        defer world_folder.close(io);

        try world_folder.setTimestamps(io, ".", .{ .access_timestamp = .now });

        const world_config_file = try world_folder.openFile(io, "config/World.zon", .{ .lock = .shared });
        defer world_config_file.close(io);

        const generator_config_file = try world_folder.openFile(io, "config/DefaultGenerator.zon", .{ .lock = .shared });
        defer generator_config_file.close(io);

        var generator_config = try utils.loadZON(World.DefaultGenerator.Params, io, generator_config_file, allocator, allocator);
        generator_config.setSeeds(io);
        return .{
            .generator_config = generator_config,
            .world_config = try utils.loadZON(World.WorldConfig, io, world_config_file, allocator, allocator),
        };
    }

    /// Saves the world options to the config directory in the given folder, creating the files if they do not exist.
    pub fn save(self: WorldOptions, io: std.Io, folder: []const u8) !void {
        var wbuffer: [1024]u8 = undefined;
        var gbuffer: [1024]u8 = undefined;

        var world_folder = try std.Io.Dir.cwd().openDir(io, folder, .{});
        defer world_folder.close(io);

        world_folder.createDirPath(io, "config") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const world_config_file = try world_folder.createFile(io, "config/World.zon", .{ .lock = .exclusive });
        defer world_config_file.close(io);

        var world_config_writer = world_config_file.writer(io, &wbuffer);

        const generator_config_file = try world_folder.createFile(io, "config/DefaultGenerator.zon", .{ .lock = .exclusive });
        defer generator_config_file.close(io);

        var generator_config_writer = generator_config_file.writer(io, &gbuffer);

        try std.zon.stringify.serialize(self.world_config, .{}, &world_config_writer.interface);
        try std.zon.stringify.serialize(self.generator_config, .{}, &generator_config_writer.interface);

        try world_config_writer.end();
        try generator_config_writer.end();
    }

    pub fn deinit(self: WorldOptions, allocator: std.mem.Allocator) void {
        std.zon.parse.free(allocator, self.world_config);
        std.zon.parse.free(allocator, self.generator_config);
    }
};

pub fn init(
    game: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    game_options: *Options,
    game_options_lock: *std.Io.RwLock,
    folder: []const u8,
    window: *wio.Window,
    gl_options: wio.GlOptions,
    share_context: *wio.GlContext,
    proc_table: *const gl.ProcTable,
) !void {
    game.* = .{
        .last_frametime = .now(io, .awake),
        .game_arena = .init(allocator),
        .options = game_options,
        .options_lock = game_options_lock,
        .running = .init(true),
        .allocator = undefined,
        .opengl_renderer = undefined,
        .renderer = undefined,
        .generator = undefined,
        .loaded_or_meshed = .init,
        .world_storage = undefined,
        .world = undefined,
        .player = undefined,
        .entity_registry = .init(),
    };

    try game.opengl_renderer.init(io, allocator, window, gl_options, share_context, proc_table, &game_options.render_options, game_options_lock);
    errdefer game.opengl_renderer.deinit(io);

    game.renderer = game.opengl_renderer.interface;
    game.allocator = allocator;

    const arena = game.game_arena.allocator();
    errdefer game.game_arena.deinit();

    var world_options = WorldOptions.fromWorldFolder(folder, io, arena) catch |err| switch (err) {
        error.FileNotFound => WorldOptions.default,
        else => return err,
    };
    world_options.generator_config.setSeeds(io);
    try world_options.save(io, folder);

    game.generator = try .init(allocator, game.options.terrain_height_cache_bytes, world_options.generator_config);
    errdefer World.DefaultGenerator.deinit(game.generator.getSource(), io, allocator, undefined);

    const storage_path = try std.fs.path.joinZ(game.allocator, &[_][]const u8{ folder, "storage" });
    {
        defer game.allocator.free(storage_path);
        game.world_storage = try .init(storage_path, game.allocator);
    }

    game.options_lock.lockSharedUncancelable(io);
    const chunk_cache_capacity = @max(std.math.floorPowerOfTwo(u64, game.options.chunk_cache_bytes / @sizeOf(World.ChunkValue)), game.world.chunks.shards.len * 256);
    const chunk_grid_capacity = @max(std.math.floorPowerOfTwo(u64, game.options.grid_cache_bytes / @sizeOf(World.GridValue)), game.world.grids.shards.len * 256);
    game.options_lock.unlockShared(io);
    std.log.info("Creating chunk cache with size {d} ({d} bytes)", .{ chunk_cache_capacity, chunk_cache_capacity * @sizeOf(World.ChunkValue) });
    std.log.info("Creating grid cache with size {d} ({d} bytes)", .{ chunk_grid_capacity, chunk_grid_capacity * @sizeOf(World.GridValue) });

    game.world = .{
        .chunks = try .init(allocator, chunk_cache_capacity, .{ .name = "chunk cache" }),
        .grids = try .init(allocator, chunk_grid_capacity, .{ .name = "grid cache" }),
        .config = world_options.world_config,
        .chunk_sources = .{ null, null, game.world_storage.getSource(), game.generator.getSource() },
        .edit_callback = .{
            .function = editorCallback,
            .context = @ptrCast(game),
            .on_neighbor_face_change = true,
        },
    };
    errdefer game.world.deinit(io, allocator);

    try game.spawnPlayer(io, allocator);
}

pub fn deinit(self: *@This(), io: std.Io) void {
    self.running.store(false, .unordered);

    if (self.mesh_unload_future) |*future| future.cancel(io) catch {};
    if (self.save_future) |*future| future.cancel(io) catch {};
    if (self.load_future) |*future| future.cancel(io) catch {};
    self.group.cancel(io);

    self.opengl_renderer.deinit(io);
    self.entity_registry.deinit(io, self.allocator, &self.world);
    self.world.deinit(io, self.allocator);
    self.loaded_or_meshed.deinit(io, self.allocator);

    self.game_arena.deinit();
    self.* = undefined;
}

pub fn frame(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    const now: std.Io.Timestamp = .now(io, .awake);
    const frame_time = self.last_frametime.durationTo(now);
    self.last_frametime = now;
    const current_fps: f32 = std.time.ns_per_s / @as(f32, @floatFromInt(frame_time.nanoseconds));
    const fps = self.debug_menu.fps.load(.unordered);
    self.debug_menu.fps.store(std.math.lerp(fps, current_fps, 0.01), .unordered);

    var entities_future = io.async(EntityRegistry.update, .{ &self.entity_registry, io, allocator, &self.world });
    defer entities_future.cancel(io) catch {};
    try restartFutures(self, io, allocator);

    self.player.physics.mutex.lockUncancelable(io);
    const player_pos = self.player.physics.pos;
    self.player.physics.mutex.unlock(io);

    try self.renderer.clear(player_pos);
    try self.player.physics.update(&self.world, io, allocator);

    self.player.physics.mutex.lockUncancelable(io);
    const player_pos_updated = self.player.physics.pos;
    self.player.physics.mutex.unlock(io);

    try self.renderer.drawChunks(io, player_pos_updated);
    try self.handleErrors();
    try entities_future.await(io);
}

fn restartFutures(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    self.options_lock.lockSharedUncancelable(io);
    const loader_frequency_ms = self.options.loader_frequency_ms;
    const mesh_unload_frequency_ms = self.options.mesh_unload_frequency_ms;
    const save_frequency_ms = self.options.save_frequency_ms;
    self.options_lock.unlockShared(io);

    if (!self.chunk_load_is_running.load(.seq_cst) and self.last_chunk_load.durationTo(.now(io, .awake)).toMilliseconds() > loader_frequency_ms) {
        if (self.load_future) |*f| try f.await(io);

        self.chunk_load_is_running.store(true, .seq_cst);
        self.last_chunk_load = .now(io, .awake);
        self.load_future = io.concurrent(loadChunks, .{ self, io, allocator }) catch io.async(loadChunks, .{ self, io, allocator });
    }

    if (!self.mesh_unload_is_running.load(.seq_cst) and self.last_mesh_unload.durationTo(.now(io, .awake)).toMilliseconds() > mesh_unload_frequency_ms) {
        if (self.mesh_unload_future) |*f| try f.await(io);

        self.mesh_unload_is_running.store(true, .seq_cst);
        self.last_mesh_unload = .now(io, .awake);
        self.mesh_unload_future = io.concurrent(unloadChunkMeshes, .{ self, io }) catch io.async(unloadChunkMeshes, .{ self, io });
    }

    if (!self.save_is_running.load(.seq_cst) and self.last_save.durationTo(.now(io, .awake)).toMilliseconds() > save_frequency_ms) {
        if (self.save_future) |*f| try f.await(io);

        self.save_is_running.store(true, .seq_cst);
        self.last_save = .now(io, .awake);
        self.save_future = io.concurrent(saveFuture, .{ self, io }) catch io.async(saveFuture, .{ self, io });
    }
}

fn saveFuture(self: *@This(), io: std.Io) !void {
    defer self.save_is_running.store(false, .seq_cst);
    try self.world.trySaveAll(io);
}

fn handleErrors(self: *@This()) !void {
    const err = @errorFromInt(self.deferred_error.swap(@intFromError(error.NoError), .seq_cst));
    switch (err) {
        error.Canceled => unreachable, // This should not be here
        error.NoError => {},
        else => |e| return e,
    }
}

pub fn groupAsync(self: *Game, io: std.Io, function: anytype, args: anytype) void {
    const wrapper = struct {
        pub fn handler(game: *Game, fn_args: @TypeOf(args)) Io.Cancelable!void {
            @call(.always_inline, function, fn_args) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => |e| {
                    const existing_error = game.deferred_error.cmpxchgStrong(@intFromError(error.NoError), @intFromError(e), .seq_cst, .seq_cst);
                    if (existing_error) |er| std.log.err("{s}", .{@errorName(@errorFromInt(er))});
                },
            };
        }
    };
    self.group.async(io, wrapper.handler, .{ self, args });
}

pub fn handleMouseMotion(self: *@This(), io: std.Io, mouse_motion: wio.RelativePosition) void {
    const sensitivity = self.getMouseSensitivity(io);

    var view_dir_diff: @Vector(2, f32) = @splat(0);
    view_dir_diff += @Vector(2, f32){ mouse_motion.y, mouse_motion.x };
    view_dir_diff *= @splat(sensitivity);

    const small_f32 = 0.00001;

    self.player.viewDirection_mutex.lockUncancelable(io);
    defer self.player.viewDirection_mutex.unlock(io);
    var current_view_dir = self.player.viewDirection;
    current_view_dir -= @Vector(3, f32){ view_dir_diff[0], view_dir_diff[1], 0 };
    current_view_dir[0] = std.math.clamp(current_view_dir[0], -90 + small_f32, 90 - small_f32);
    self.player.viewDirection = current_view_dir;

    self.renderer.updateCameraDirection(current_view_dir);
}

pub fn handleScroll(self: *@This(), io: std.Io, scroll: f32) !void {
    self.options_lock.lockSharedUncancelable(io);
    const scroll_sensitivity = self.options.scroll_sensitivity;
    self.options_lock.unlockShared(io);
    switch (self.player.gameMode.load(.seq_cst)) {
        .Creative, .Spectator => {
            const fly_speed_linear_old = self.player.fly_speed_linear.fetchAdd(-scroll * scroll_sensitivity, .seq_cst);
            _ = self.player.fly_speed.store(@min(@as(f32, @floatFromInt(std.math.maxInt(i32))), std.math.pow(f32, 2, fly_speed_linear_old)), .seq_cst);
        },
        .Survival => {},
    }
}

pub fn handleButtonActions(self: *Game, io: std.Io, actions: *const Key.ActionSet, delta_time: std.Io.Duration) !void {
    const delta_time_seconds = @as(f32, @floatFromInt(delta_time.toNanoseconds())) / std.time.ns_per_s;

    switch (self.player.gameMode.load(.unordered)) {
        .Creative, .Spectator => try self.flyMove(io, actions, delta_time_seconds),
        .Survival => try self.walkMove(io, actions, delta_time_seconds),
    }
    self.setSelectedSlot(actions);
    groupAsync(self, io, itemAction, .{ self, io, actions.* });
}

fn setSelectedSlot(self: *@This(), actions: *const Key.ActionSet) void {
    if (actions.contains(.hotbar_key_0)) self.selected_inventory_col.store(0, .seq_cst);
    if (actions.contains(.hotbar_key_1)) self.selected_inventory_col.store(1, .seq_cst);
    if (actions.contains(.hotbar_key_2)) self.selected_inventory_col.store(2, .seq_cst);
    if (actions.contains(.hotbar_key_3)) self.selected_inventory_col.store(3, .seq_cst);
    if (actions.contains(.hotbar_key_4)) self.selected_inventory_col.store(4, .seq_cst);
    if (actions.contains(.hotbar_key_5)) self.selected_inventory_col.store(5, .seq_cst);
    if (actions.contains(.hotbar_key_6)) self.selected_inventory_col.store(6, .seq_cst);
    if (actions.contains(.hotbar_key_7)) self.selected_inventory_col.store(7, .seq_cst);
    if (actions.contains(.hotbar_key_8)) self.selected_inventory_col.store(8, .seq_cst);
    if (actions.contains(.hotbar_key_9)) self.selected_inventory_col.store(9, .seq_cst);
    if (actions.contains(.hotbar_scroll_up)) _ = self.selected_inventory_row.fetchAdd(1, .seq_cst);
    if (actions.contains(.hotbar_scroll_down)) _ = self.selected_inventory_row.fetchSub(1, .seq_cst);
}

fn itemAction(self: *@This(), io: std.Io, actions: Key.ActionSet) !void {
    self.player.physics.mutex.lockUncancelable(io);
    const player_pos = self.player.physics.pos;
    self.player.physics.mutex.unlock(io);
    const looking = self.renderer.getCameraFront();

    try self.options_lock.lockShared(io);
    const sphere_size = self.options.sphere_size;
    const sphere_block = self.options.sphere_block;
    self.options_lock.unlockShared(io);

    var editor: World.Editor = .{ .world = &self.world, .temp_allocator = self.allocator };
    defer editor.clear();
    if (actions.contains(.use_item_primary)) {
        const cone: Geometry.Cone(f32) = .init(@floatCast(player_pos), looking, 100, 10, 10);
        try editor.placeSamplerShape(.air, cone, 0);
    }
    if (actions.contains(.use_item_secondary)) {
        const cone: Geometry.Cone(f32) = .init(@floatCast(player_pos), looking, 100, 10, 10);
        try editor.placeSamplerShape(.stone, cone, 0);
    }
    if (actions.contains(.use_item_tertiary)) {
        try editor.placeSamplerShape(sphere_block, Geometry.Sphere(f32).init(@floatCast(player_pos), @floatFromInt(sphere_size)), 0);
    }
    try editor.flush(io, self.allocator);
}

fn moveCameraFront(dir: @Vector(3, f32)) @Vector(3, f32) {
    return @Vector(3, f32){
        @sin(std.math.degreesToRadians(dir[1])) * @cos(std.math.degreesToRadians(0)),
        @sin(std.math.degreesToRadians(0)),
        @cos(std.math.degreesToRadians(dir[1])) * @cos(std.math.degreesToRadians(0)),
    };
}
fn flyMove(self: *@This(), io: std.Io, actions: *const Key.ActionSet, delta_time_seconds: f32) !void {
    self.player.viewDirection_mutex.lockUncancelable(io);
    const camera_front = moveCameraFront(self.player.viewDirection);
    self.player.viewDirection_mutex.unlock(io);
    const vel_diff: @Vector(3, f32) = @splat(self.player.fly_speed.load(.unordered) * delta_time_seconds);
    const cross_product = zm.Vec3f.crossRH(.{ .data = camera_front }, .{ .data = Renderer.OpenGl.cameraUp });
    const cross_norm = if (std.meta.eql(cross_product.data, @Vector(3, f64){ 0, 0, 0 })) null else cross_product.norm();

    {
        self.player.physics.mutex.lockUncancelable(io);
        defer self.player.physics.mutex.unlock(io);
        if (actions.contains(.forward)) self.player.physics.velocity += @as(@Vector(3, f64), @floatCast(vel_diff * camera_front));
        if (actions.contains(.backward)) self.player.physics.velocity += @as(@Vector(3, f64), @floatCast(-vel_diff * camera_front));
        if (actions.contains(.up)) self.player.physics.velocity += @Vector(3, f64){ 0, @floatCast(vel_diff[1]), 0 };
        if (actions.contains(.down)) self.player.physics.velocity += @Vector(3, f64){ 0, @floatCast(-vel_diff[1]), 0 };
        if (actions.contains(.right) and cross_norm != null) self.player.physics.velocity += @as(@Vector(3, f64), @floatCast(vel_diff * cross_norm.?.data));
        if (actions.contains(.left) and cross_norm != null) self.player.physics.velocity += @as(@Vector(3, f64), @floatCast(-vel_diff * cross_norm.?.data));
    }
    try self.player.physics.update(&self.world, io, self.allocator);
}

fn walkMove(self: *@This(), io: std.Io, actions: *const Key.ActionSet, delta_time_seconds: f32) !void {
    self.player.viewDirection_mutex.lockUncancelable(io);
    const camera_front = moveCameraFront(self.player.viewDirection);
    self.player.viewDirection_mutex.unlock(io);
    const speed: @Vector(3, f32) = @splat(self.player.walk_speed.load(.unordered));
    const cross_product = zm.Vec3f.crossRH(.{ .data = camera_front }, .{ .data = Renderer.OpenGl.cameraUp });
    const cross_norm = if (std.meta.eql(cross_product.data, @Vector(3, f64){ 0, 0, 0 })) null else cross_product.norm();
    var block_reader: World.Reader = .{ .world = &self.world };
    defer block_reader.clear(io);

    self.player.physics.mutex.lockUncancelable(io);
    const player_pos = self.player.physics.pos;
    self.player.physics.mutex.unlock(io);

    const ground_dist = try self.player.physics.elements.mover.shortestGroundDistance(io, self.allocator, player_pos - @Vector(3, f64){ 0.001, 0.001, 0.001 }, &block_reader);
    const on_ground = ground_dist <= 0;
    const speed_multiplier: @Vector(3, f32) = @splat(if (on_ground) 1.0 else 0.35);
    {
        self.player.physics.mutex.lockUncancelable(io);
        defer self.player.physics.mutex.unlock(io);
        if (actions.contains(.up) and on_ground) self.player.physics.velocity[1] = self.player.jump_strength.load(.unordered);
        var vel_diff: @Vector(3, f64) = @splat(0.0);
        if (actions.contains(.forward)) vel_diff += @as(@Vector(3, f64), @floatCast(speed * camera_front));
        if (actions.contains(.backward)) vel_diff += @as(@Vector(3, f64), @floatCast(-speed * camera_front));
        if (actions.contains(.right) and cross_norm != null) vel_diff += @as(@Vector(3, f64), @floatCast(speed * cross_norm.?.data));
        if (actions.contains(.left) and cross_norm != null) vel_diff += @as(@Vector(3, f64), @floatCast(-speed * cross_norm.?.data));
        vel_diff = vel_diff * speed_multiplier;
        if (on_ground) {
            self.player.physics.velocity[0] = vel_diff[0];
            self.player.physics.velocity[2] = vel_diff[2];
        } else {
            self.player.physics.velocity[0] += vel_diff[0] * delta_time_seconds;
            self.player.physics.velocity[2] += vel_diff[2] * delta_time_seconds;
        }
    }
    try self.player.physics.update(&self.world, io, self.allocator);
}

pub fn getLevels(self: *@This(), io: std.Io) struct { i32, i32 } {
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return .{ self.options.lowest_level, self.options.highest_level };
}

fn getRenderDistance(self: *@This(), io: std.Io) @Vector(2, u32) {
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return .{ self.options.render_distance_x, self.options.render_distance_y };
}

fn getInnerGenRadius(self: *@This(), io: std.Io, gen_distance: @Vector(2, u32), level: i32) @Vector(2, u32) {
    if (level <= (self.getLevels(io))[0]) return @splat(0);
    const inner_radius = gen_distance / @Vector(2, u32){ World.scale_factor, World.scale_factor };
    return inner_radius -| @Vector(2, u32){ 1, 1 };
}

fn getMouseSensitivity(self: *@This(), io: std.Io) f32 {
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return self.options.mouse_sensitivity;
}

/// Adds a chunk to the render list replacing it if it already exists, generates it or its neighbors if it doesn't exist.
fn addChunkToRender(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: World.ChunkPos, generate_structures: bool) !void {
    const GenMeshAndAdd = tracy.Zone.begin(.{ .src = @src(), .name = "GenMeshAndAdd" });
    defer GenMeshAndAdd.end();

    // Prevent an old version of the chunk from staying loaded
    if (!self.keepChunkLoaded(io, chunk_pos) and self.canUnloadMesh(io, chunk_pos)) {
        self.renderer.removeChunk(io, chunk_pos);
        try self.tryRemoveChunkFromLoaded(io, self.allocator, chunk_pos);
        return;
    }

    const chunk = try self.world.loadChunk(io, allocator, chunk_pos, generate_structures);
    defer chunk.release();
    var neighbor_faces: [6]Chunk.Encoding.Face = undefined;
    inline for (&neighbor_faces, std.enums.values(Chunk.Encoding.FaceRotation)) |*face, rotation|
        face.* = try (try self.world.loadChunk(io, allocator, chunk_pos.offset(rotation), false)).extractFace(io, rotation.invert(), true);

    var buffer: [65536]u8 = undefined;
    var bfa: BFA = .init(&buffer, self.allocator);
    var opaque_faces: std.ArrayList(Mesher.Face) = .empty;
    defer opaque_faces.deinit(bfa.allocator());
    var transparent_faces: std.ArrayList(Mesher.Face) = .empty;
    defer transparent_faces.deinit(bfa.allocator());
    {
        try chunk.lockShared(io);
        defer chunk.unlockShared(io);
        try Mesher.mesh(
            bfa.allocator(),
            chunk.encoding,
            &neighbor_faces,
            &opaque_faces,
            &transparent_faces,
        );
    }

    {
        const chunk_add = tracy.Zone.begin(.{ .src = @src(), .name = "chunk_add" });
        defer chunk_add.end();
        if (opaque_faces.items.len > 0 or transparent_faces.items.len > 0) {
            try self.renderer.addChunk(io, chunk_pos, opaque_faces.items, transparent_faces.items);
        } else {
            self.renderer.removeChunk(io, chunk_pos);
        }
    }
    const mark = tracy.Zone.begin(.{ .src = @src(), .name = "mark" });
    defer mark.end();

    var was_covering = false;
    var is_covering = false;
    {
        const bucket = self.loaded_or_meshed.getBucket(chunk_pos);
        try bucket.lock.lock(io);
        defer bucket.lock.unlock(io);
        var state: NodeData = bucket.hash_map.get(chunk_pos) orelse .{ .structures_generated = generate_structures };

        was_covering = state.allCoveredChildren() or state.is_active;

        state.is_active = true;
        state.is_queued = false;

        is_covering = state.allCoveredChildren() or state.is_active;
        try bucket.hash_map.put(allocator, chunk_pos, state);
    }

    if (!was_covering and is_covering) {
        try self.markCovered(io, allocator, chunk_pos);
    }
}

fn addChunkToRenderAsync(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: World.ChunkPos, gen_structures: bool) !void {
    {
        const bucket = self.loaded_or_meshed.getBucket(chunk_pos);
        try bucket.lock.lock(io);
        defer bucket.lock.unlock(io);
        const entry = try bucket.hash_map.getOrPutValue(allocator, chunk_pos, .{ .structures_generated = gen_structures });
        entry.value_ptr.is_queued = true;
    }

    self.groupAsync(io, addChunkToRender, .{ self, io, allocator, chunk_pos, gen_structures });
}

fn editorCallback(io: std.Io, allocator: std.mem.Allocator, chunk_pos: World.ChunkPos, args: *anyopaque) !void {
    const game: *@This() = @ptrCast(@alignCast(args));
    game.addChunkToRender(io, allocator, chunk_pos, false) catch return error.OnEditFailed;
}

fn keepChunkLoaded(self: *@This(), io: std.Io, chunk_pos: World.ChunkPos) bool {
    const lowest_level, const highest_level = self.getLevels(io);
    self.player.physics.mutex.lockUncancelable(io);
    const player_pos = self.player.physics.pos;
    self.player.physics.mutex.unlock(io);
    const gen_distance = self.getRenderDistance(io);
    const inner_gen_radius = self.getInnerGenRadius(io, gen_distance, chunk_pos.level);
    const inside_range = keepLoaded(lowest_level, highest_level, player_pos, chunk_pos, inner_gen_radius, gen_distance);
    return inside_range;
}

fn keepLoaded(lowest_level: ?i32, highest_level: ?i32, player_pos: @Vector(3, f64), chunk_pos: World.ChunkPos, inner_chunk_range: ?@Vector(2, u32), outer_chunk_range: ?@Vector(2, u32)) bool {
    if (lowest_level) |l| {
        if (chunk_pos.level < l) return false;
    }
    if (highest_level) |h| {
        if (chunk_pos.level > h) return false;
    }

    const player_chunk_pos = @trunc(player_pos / @as(@Vector(3, f64), @splat(World.ChunkPos.levelToBlockRatioFloat(chunk_pos.level))));
    const chunk_center: @Vector(3, f64) = chunk_pos.position;

    if (inner_chunk_range) |icr| {
        const inner: @Vector(3, f64) = .{ icr[0], icr[1], icr[0] };
        const inside_inner =
            @reduce(.And, player_chunk_pos > (chunk_center - inner)) and
            @reduce(.And, player_chunk_pos < chunk_center + inner);
        if (inside_inner) return false;
    }

    if (outer_chunk_range) |ocr| {
        const outer: @Vector(3, f64) = .{ ocr[0], ocr[1], ocr[0] };
        const outside_outer =
            @reduce(.Or, player_chunk_pos < chunk_center - outer) or
            @reduce(.Or, player_chunk_pos > chunk_center + outer);
        if (outside_outer) return false;
    }
    return true;
}

///Loads all chunks in render distance
fn loadChunks(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    const z = tracy.Zone.begin(.{ .src = @src(), .name = "addChunksToLoad" });
    defer z.end();
    defer self.chunk_load_is_running.store(false, .seq_cst);
    var levels = self.getLevels(io);
    var level = levels[0];
    var amount_loaded: u64 = 0;
    while (level <= levels[1]) : (level += 1) {
        levels = self.getLevels(io);
        try self.player.physics.mutex.lock(io);
        const player_pos = self.player.physics.pos;
        self.player.physics.mutex.unlock(io);
        amount_loaded += try loadChunksSpiral(self, io, allocator, player_pos, level);
    }
}

///loads chunks from top to bottom and in a spiral on a y level
fn loadChunksSpiral(game: *@This(), io: std.Io, allocator: std.mem.Allocator, player_pos: @Vector(3, f64), level: i32) !u64 {
    const player_chunk_pos = World.ChunkPos.fromGlobalBlockPos(@trunc(player_pos), level);

    var outer_radius = game.getRenderDistance(io);
    var inner_radius = game.getInnerGenRadius(io, outer_radius, level);

    var amount_loaded: u64 = 0;
    var amount_tested: u64 = 0;

    var xz: [2]i32 = .{ 0, 0 };
    var c: usize = 0;

    while (true) {
        if (amount_tested >= 4 * outer_radius[0] * outer_radius[0]) {
            break;
        }

        const m = move(xz, &c);

        var cc: i32 = 0;
        while (line(&xz, &cc, m)) {
            amount_tested += 1;

            var y: i32 = -@as(i32, @intCast(outer_radius[1]));
            try io.checkCancel();
            //update radiuses more frequently incase they are set way too high
            outer_radius = game.getRenderDistance(io);
            inner_radius = game.getInnerGenRadius(io, outer_radius, level);
            while (y < outer_radius[1]) {
                defer y += 1;
                const chunk_pos: World.ChunkPos = .{ .position = [3]i32{ xz[0] + player_chunk_pos.position[0], y + player_chunk_pos.position[1], xz[1] + player_chunk_pos.position[2] }, .level = level };

                const in_range = keepLoaded(null, null, player_pos, chunk_pos, inner_radius, outer_radius);
                if (!in_range)
                    continue;

                const node_data = game.loaded_or_meshed.get(io, chunk_pos);

                if (node_data == null or (!node_data.?.is_active and !node_data.?.is_queued) or !node_data.?.structures_generated) {
                    amount_loaded += 1;
                    try game.addChunkToRenderAsync(io, allocator, chunk_pos, true);
                }
            }
        }
    }
    return amount_loaded;
}

fn unloadChunkMeshes(self: *@This(), io: std.Io) std.Io.Cancelable!void {
    const unload = tracy.Zone.begin(.{ .src = @src(), .name = "UnloadMeshes" });
    defer unload.end();
    defer self.mesh_unload_is_running.store(false, .seq_cst);

    const ChunkCollector = struct {
        game: *Game,
        io: std.Io,
        chunks: u64 = 0,
        unloaded: u64 = 0,

        pub fn callback(userdata: *anyopaque, chunk_pos: World.ChunkPos) void {
            const ctx: *@This() = @ptrCast(@alignCast(userdata));
            ctx.chunks += 1;
            if (ctx.game.keepChunkLoaded(ctx.io, chunk_pos)) return;
            if (!ctx.game.canUnloadMesh(ctx.io, chunk_pos)) return; // children not ready
            const prev = ctx.io.swapCancelProtection(.blocked);

            ctx.game.tryRemoveChunkFromLoaded(ctx.io, ctx.game.allocator, chunk_pos) catch |err| switch (err) {
                error.Canceled => unreachable,
                else => @panic("TODO handle error"),
            };

            _ = ctx.io.swapCancelProtection(prev);

            ctx.game.renderer.removeChunk(ctx.io, chunk_pos);
            ctx.unloaded += 1;
        }
    };
    var ctx = ChunkCollector{
        .game = self,
        .io = io,
    };

    try self.renderer.forEachChunk(io, &ctx, ChunkCollector.callback);
    self.debug_menu.meshes.store(ctx.chunks, .unordered);

    var it = self.loaded_or_meshed.iterator();
    defer it.deinit(io);
    while (try it.next(io)) |entry| {
        const key = entry.key_ptr.*;
        if (self.keepChunkLoaded(io, key)) continue;
        if (!entry.value_ptr.is_active and !entry.value_ptr.is_queued) continue;

        it.pause(io);
        self.tryRemoveChunkFromLoaded(io, self.allocator, key) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => @panic("TODO handle error"),
        };
        try it.unpause(io);
    }
}

fn spawnPlayer(game: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    const player_entity = try game.entity_registry.spawn(io, allocator, EntityTypes.Player{
        .player_name = .fromString("squid"),
        .physics = .{
            .elements = .{
                .mover = .{
                    .collisions = .init(false),
                    .boundingBox = .init(.{ .data = .{ -0.5, -2, -0.5 } }, .{ .data = .{ 0.5, 2, 0.5 } }),
                    .enabled = .init(true),
                    .zeroVelocity = .init(true),
                },
                .gravity = .{
                    .enabled = .init(false),
                },
                .resistance = .{ .fraction_per_second = .init(0.1), .enabled = .init(false) },
            },
            .pos = .{ 0, 100, 0 },
            .velocity = @splat(0),
            .last_update = .now(io, .awake),
        },
        .gameMode = .init(.Spectator),
        .viewDirection = @Vector(3, f32){ 0.0001, -0.4, 0.001 },
        .main_inventory = undefined,
    }, true);
    player_entity.release();
    game.player = @ptrCast(@alignCast(player_entity.ptr));
    game.player.main_inventory = .initBuffer(
        10,
        16,
        &game.player.inventory_buffer,
    );
    _ = game.player.main_inventory.set(io, 0, 0, .{ .item_type = .Explosive, .amount = 65536 });
    game.player.viewDirection_mutex.lockUncancelable(io);
    const view_direction = game.player.viewDirection;
    game.player.viewDirection_mutex.unlock(io);
    game.renderer.updateCameraDirection(view_direction);
}

fn move(xz_in: [2]i32, c: *usize) [2]i32 {
    const mov_f: f32 = (@as(f32, @floatFromInt(c.*)) / 2.0);
    const mov: i32 = @ceil(mov_f + 0.01);
    var xz = xz_in;
    switch (@mod(c.*, 4)) {
        0 => xz[1] += mov,
        1 => xz[0] += mov,
        2 => xz[1] -= mov,
        3 => xz[0] -= mov,
        else => unreachable,
    }
    c.* += 1;
    return xz;
}

fn line(xz: *[2]i32, c: *i32, end: [2]i32) bool {
    defer c.* += 1;
    if (c.* == 0) return true;
    if (xz[0] == end[0] and xz[1] == end[1]) return false;
    std.debug.assert(xz[0] == end[0] or xz[1] == end[1]);
    if (xz[0] == end[0]) {
        if (xz[1] < end[1]) {
            xz[1] += 1;
        } else {
            xz[1] -= 1;
        }
    } else {
        if (xz[0] < end[0]) {
            xz[0] += 1;
        } else {
            xz[0] -= 1;
        }
    }
    if (xz[0] == end[0] and xz[1] == end[1]) return false;
    return true;
}

test {
    std.testing.refAllDecls(@This());
}
