const std = @import("std");
const Io = std.Io;

const dvui = @import("dvui");
const tracy = @import("tracy");
const wio = @import("wio");
const zm = @import("zm");

const Entity = @import("entity/Entity.zig");
const EntityRegistry = @import("entity/EntityRegistry.zig");
const EntityTypes = @import("entity/EntityTypes.zig");
const Key = @import("Key.zig");
const ConcurrentHashMap = @import("libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const utils = @import("libs/utils.zig");
pub const Renderer = @import("Renderer.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const Chunk = @import("world/Chunk.zig");
const generator_loader = @import("world/generator_loader.zig");
const generator_api = @import("world/generators/generator_api.zig");
const Cone = @import("world/structures/Cone.zig").Cone;
const Sphere = @import("world/structures/Sphere.zig").Sphere;
const TexturedSphere = @import("world/structures/TexturedSphere.zig");
const World = @import("world/World.zig");

const Game = @This();

allocator: std.mem.Allocator,
/// Path to this world's directory, retained so the world can be recreated in place.
world_path: []const u8,
world: World,
/// View into the player implementation. Only valid while player_entity holds
/// its reference.
player: *EntityTypes.Player,
/// Holds the reference that keeps the player entity pinned in the cache.
player_entity: *Entity,
vulkan_renderer: Renderer.Vulkan,
renderer: Renderer,
generator: ?generator_loader.GeneratorInstance,
world_storage: World.WorldStorage,
game_arena: std.heap.ArenaAllocator,
loaded_or_meshed: ConcurrentHashMap(World.ChunkPos, NodeData, std.hash_map.AutoContext(World.ChunkPos), 128),

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
    entities: std.atomic.Value(u64) = .init(0),
    opaque_drawn: std.atomic.Value(u32) = .init(0),
    transparent_drawn: std.atomic.Value(u32) = .init(0),
    occluded: std.atomic.Value(u32) = .init(0),
    frustum_culled: std.atomic.Value(u32) = .init(0),
    opaque_faces: std.atomic.Value(u64) = .init(0),
    transparent_faces: std.atomic.Value(u64) = .init(0),
    shadow_faces: std.atomic.Value(u64) = .init(0),
    shadow_cascade: std.atomic.Value(u32) = .init(std.math.maxInt(u32)),
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

    const empty_coverage = @as([World.scale_factor][World.scale_factor][World.scale_factor]bool, @splat(@splat(@splat(false))));
    const full_coverage = @as([World.scale_factor][World.scale_factor][World.scale_factor]bool, @splat(@splat(@splat(true))));

    pub fn noCoveredChildren(state: NodeData) bool {
        return std.meta.eql(state.covered_children, empty_coverage);
    }

    pub fn allCoveredChildren(state: NodeData) bool {
        return std.meta.eql(state.covered_children, full_coverage);
    }

    pub fn isCovering(state: NodeData) bool {
        return state.allCoveredChildren() or state.is_active;
    }
};

/// Sets or clears pos's covered slot in its parent, bubbling up while the parent's
/// aggregate flips. Setting creates the parent ghost if absent; clearing prunes it
/// when it tracks nothing. The aggregate is monotonic in the slot value, so
/// `was != is` is the directed transition condition for both directions of the walk.
/// `highest` is a snapshot of `highest_level` taken at the outermost call; reusing
/// it for the recursive bubble-up avoids N extra RwLock acquisitions and gives a
/// consistent cutoff for the whole walk (concurrent `highest_level` changes take
/// effect on the next top-level call).
fn markSubtree(
    self: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    pos: World.ChunkPos,
    covered: bool,
    highest: i32,
) !void {
    const zone = tracy.Zone.begin(.{ .src = @src(), .name = "mark_subtree" });
    defer zone.end();
    const parent = pos.parent();
    if (parent.level > highest) return;
    const pos_in_parent = pos.posInParent();

    var bubble_up = false;
    {
        const bucket = self.loaded_or_meshed.getBucket(parent);
        const p = pos_in_parent;

        // Fast path: read under the shared lock and skip the exclusive lock
        // entirely when the slot already holds the target value. The synthetic
        // NodeData on miss has `structures_generated = false` only to satisfy
        // the type; only `covered_children[p]` is examined here.
        {
            const mark_subtree_fast = tracy.Zone.begin(.{ .src = @src(), .name = "mark_subtree_fast" });
            defer mark_subtree_fast.end();
            const initial = bucket.get(io, parent) orelse if (covered)
                @as(NodeData, .{ .structures_generated = false })
            else
                return;
            if (initial.covered_children[p[0]][p[1]][p[2]] == covered) return;
        }

        const mark_subtree_write = tracy.Zone.begin(.{ .src = @src(), .name = "mark_subtree_write" });
        defer mark_subtree_write.end();
        try bucket.lock.lock(io);
        defer bucket.lock.unlock(io);

        var state: NodeData = if (covered)
            bucket.hash_map.get(parent) orelse .{ .structures_generated = false }
        else
            bucket.hash_map.get(parent) orelse return;

        // Re-check after acquiring the exclusive lock; another thread may have
        // flipped the slot while we waited.
        if (state.covered_children[p[0]][p[1]][p[2]] == covered) {
            return;
        }

        const was_covering = state.isCovering();
        state.covered_children[p[0]][p[1]][p[2]] = covered;
        const is_covering = state.isCovering();

        if (!covered and state.noCoveredChildren() and !state.is_active and !state.is_queued) {
            _ = bucket.hash_map.remove(parent);
        } else {
            try bucket.hash_map.put(allocator, parent, state);
        }

        bubble_up = was_covering != is_covering;
    }

    if (bubble_up) {
        try self.markSubtree(io, allocator, parent, covered, highest);
    }
}

fn canUnloadMesh(self: *@This(), io: std.Io, chunk_pos: World.ChunkPos) bool {
    return self.canUnloadMeshView(io, self.snapshotView(io), chunk_pos);
}

fn canUnloadMeshView(self: *@This(), io: std.Io, view: ViewSnapshot, chunk_pos: World.ChunkPos) bool {
    var parent = chunk_pos;
    if (parent.level > view.highest_level) return true;
    while (parent.level < view.highest_level) {
        parent = parent.parent();
        std.debug.assert(parent.level <= view.highest_level);
        if (self.loaded_or_meshed.get(io, parent)) |par| {
            if (par.is_active) {
                const state = self.loaded_or_meshed.get(io, chunk_pos) orelse return true;
                if (state.allCoveredChildren()) return true;
                // Keep this mesh while the player is close enough that the loader
                // could still be refining the area, so a stale low-res view does
                // not flash before the higher-res chunks land. The check is
                // geometric only, so it cannot race the loader or leak if the
                // loader stalls.
                const refine_radius = view.render_distance / @Vector(2, u32){ World.scale_factor, World.scale_factor };
                return !keepLoaded(null, null, view.player_pos, chunk_pos, null, refine_radius);
            }
        }
    }
    std.debug.assert(parent.level == view.highest_level);

    // Check if the highest level parent is out of render distance.
    if (!keepLoaded(null, null, view.player_pos, parent, null, view.render_distance)) return true;

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

        // Leave ghost nodes that still track coverage alone.
        if (!was_active and !was_queued) {
            std.debug.assert(!state.noCoveredChildren());
            return;
        }

        was_covering = state.isCovering();

        state.is_active = false;
        state.is_queued = false;

        is_covering = state.isCovering();

        if (state.noCoveredChildren()) {
            _ = bucket.hash_map.remove(chunk_pos); // ghost with nothing to track
        } else {
            try bucket.hash_map.put(allocator, chunk_pos, state);
        }
    }

    if (was_covering and !is_covering) {
        _, const highest = self.getLevels(io);
        try self.markSubtree(io, allocator, chunk_pos, false, highest);
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
    entity_cache_bytes: u64 = 67108864,

    sphere_size: u32 = 100,
    sphere_block: World.Block = .air,

    save_mode: World.WorldStorage.SaveMode = .only_modified,

    render_options: Renderer.RenderOptions = .{},

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
    pub const default: @This() = .{ .generator_name = "Terrain", .world_config = .{} };
    /// Name of the generator shared library this world uses.
    generator_name: []const u8,
    world_config: World.WorldConfig,

    pub fn fromWorldFolder(folder: []const u8, io: std.Io, allocator: std.mem.Allocator) !WorldOptions {
        var world_folder = try std.Io.Dir.cwd().createDirPathOpen(io, folder, .{});
        defer world_folder.close(io);

        try world_folder.setTimestamps(io, ".", .{ .access_timestamp = .now });

        const world_config_file = try world_folder.openFile(io, "config/World.zon", .{ .lock = .shared });
        defer world_config_file.close(io);

        var generator_name: []const u8 = "Terrain";
        const generator_config_file = world_folder.openFile(io, "config/generator.zon", .{ .lock = .shared }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (generator_config_file) |file| {
            defer file.close(io);
            const selection = try utils.loadZon(GeneratorSelection, io, file, allocator, allocator);
            generator_name = selection.generator;
        }

        return .{
            .generator_name = generator_name,
            .world_config = try utils.loadZon(World.WorldConfig, io, world_config_file, allocator, allocator),
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

        const generator_config_file = try world_folder.createFile(io, "config/generator.zon", .{ .lock = .exclusive });
        defer generator_config_file.close(io);

        var generator_config_writer = generator_config_file.writer(io, &gbuffer);

        try std.zon.stringify.serialize(self.world_config, .{}, &world_config_writer.interface);
        try std.zon.stringify.serialize(GeneratorSelection{ .generator = self.generator_name }, .{}, &generator_config_writer.interface);

        try world_config_writer.end();
        try generator_config_writer.end();
    }
};

const GeneratorSelection = struct {
    generator: []const u8 = "Terrain",
};

pub fn init(
    game: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    game_options: *Options,
    game_options_lock: *std.Io.RwLock,
    folder: []const u8,
    vk_ctx: *VulkanContext,
    generators: *generator_loader.Registry,
) !void {
    const owned_world_path = try allocator.dupe(u8, folder);
    game.* = .{
        .last_frametime = .now(io, .awake),
        .game_arena = .init(allocator),
        .options = game_options,
        .world_path = owned_world_path,
        .options_lock = game_options_lock,
        .running = .init(true),
        .allocator = undefined,
        .vulkan_renderer = undefined,
        .renderer = undefined,
        .generator = null,
        .loaded_or_meshed = .init,
        .world_storage = undefined,
        .world = undefined,
        .player = undefined,
        .player_entity = undefined,
        .entity_registry = undefined,
    };

    errdefer allocator.free(game.world_path);
    try Renderer.Vulkan.init(&game.vulkan_renderer, io, allocator, vk_ctx, &game.options.render_options, game.options_lock);
    errdefer game.vulkan_renderer.deinit(io);

    game.renderer = game.vulkan_renderer.interface;
    game.allocator = allocator;

    const arena = game.game_arena.allocator();
    errdefer game.game_arena.deinit();

    var world_options = WorldOptions.fromWorldFolder(folder, io, arena) catch |err| switch (err) {
        error.FileNotFound => WorldOptions.default,
        else => return err,
    };
    try world_options.save(io, folder);

    const generator_plugin = generators.findByName(world_options.generator_name) orelse
        return error.GeneratorNotFound;

    const config_dir = try std.fs.path.join(allocator, &.{ folder, "config" });
    errdefer allocator.free(config_dir);

    const generator_config = try generator_plugin.loadConfig(allocator, io, config_dir);
    errdefer generator_api.free(allocator, generator_config);

    generator_plugin.api.config_set_seeds(&io, generator_config);

    const create_opts: generator_api.CreateOptions = .{
        .allocator = allocator,
        .io = io,
        .max_cache_bytes = game.options.terrain_height_cache_bytes,
    };
    const generator_instance = generator_plugin.api.create(&create_opts, generator_config) orelse return error.OutOfMemory;
    const generator_source = generator_plugin.api.get_source(generator_instance).*;

    var source_deinited = false;
    errdefer if (!source_deinited) if (generator_source.deinit) |de| de(generator_source, io, allocator, undefined);

    game.generator = .{
        .generator = generator_plugin,
        .instance = generator_instance,
        .config = generator_config,
        .allocator = allocator,
        .source = generator_source,
        .config_dir = config_dir,
    };
    try game.generator.?.saveConfig(io);

    const storage_path = try std.fs.path.joinZ(game.allocator, &.{ folder, "storage" });
    {
        defer game.allocator.free(storage_path);
        game.world_storage = try .init(storage_path, game.allocator, &game.options.save_mode, game_options_lock);
    }

    game.options_lock.lockSharedUncancelable(io);
    const chunk_cache_capacity = @max(std.math.floorPowerOfTwo(u64, @max(1, game.options.chunk_cache_bytes / @sizeOf(World.ChunkValue))), @TypeOf(game.world.chunks).value_count_min);
    const chunk_grid_capacity = @max(std.math.floorPowerOfTwo(u64, @max(1, game.options.grid_cache_bytes / @sizeOf(World.GridValue))), @TypeOf(game.world.grids).value_count_min);
    game.options_lock.unlockShared(io);
    std.log.info("Creating chunk cache with size {d} ({d} bytes)", .{ chunk_cache_capacity, chunk_cache_capacity * @sizeOf(World.ChunkValue) });
    std.log.info("Creating grid cache with size {d} ({d} bytes)", .{ chunk_grid_capacity, chunk_grid_capacity * @sizeOf(World.GridValue) });

    game.world = .{
        .chunks = try .init(allocator, chunk_cache_capacity, .{ .name = "chunk cache" }),
        .grids = try .init(allocator, chunk_grid_capacity, .{ .name = "grid cache" }),
        .config = world_options.world_config,
        .chunk_sources = .{ null, null, game.world_storage.getSource(), game.generator.?.source },
        .edit_callback = .{
            .function = editorCallback,
            .context = @ptrCast(game),
            .on_neighbor_face_change = true,
        },
    };
    errdefer game.world.deinit(io, allocator);
    source_deinited = true;

    game.options_lock.lockSharedUncancelable(io);
    const entity_cache_capacity = @max(std.math.floorPowerOfTwo(u64, @max(1, game.options.entity_cache_bytes / @sizeOf(EntityRegistry.Entity))), @TypeOf(game.entity_registry.map).value_count_min);
    game.options_lock.unlockShared(io);
    std.log.info("Creating entity cache with size {d} ({d} bytes)", .{ entity_cache_capacity, entity_cache_capacity * @sizeOf(EntityRegistry.Entity) });

    game.entity_registry = try .init(game.allocator, entity_cache_capacity);
    errdefer game.entity_registry.deinit(io, game.allocator, &game.world);

    try game.spawnPlayer(io, allocator);
}

fn stopBackgroundWork(self: *@This(), io: std.Io) void {
    self.running.store(false, .unordered);

    cancelFuture(io, &self.mesh_unload_future);
    cancelFuture(io, &self.save_future);
    cancelFuture(io, &self.load_future);
    self.group.cancel(io);
    self.group.await(io) catch {};
}

pub fn deinit(self: *@This(), io: std.Io) void {
    self.stopBackgroundWork(io);

    self.vulkan_renderer.deinit(io);
    self.player_entity.release();
    self.entity_registry.deinit(io, self.allocator, &self.world);
    self.world.deinit(io, self.allocator);
    if (self.generator) |*generator| generator.deinit();
    self.loaded_or_meshed.deinit(io, self.allocator);
    self.allocator.free(self.world_path);

    self.game_arena.deinit();
    self.* = undefined;
}

/// Discards all generated and edited chunks, then opens a fresh world using the
/// current generator configuration. The caller must wait for the GPU before
/// calling this because the renderer is fully recreated.
pub fn recreateWorld(
    self: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    vk_ctx: *VulkanContext,
    generators: *generator_loader.Registry,
) !void {
    const game_options = self.options;
    const options_lock = self.options_lock;
    const player_pos = self.getPlayerPos(io);
    self.player.view_direction_mutex.lockUncancelable(io);
    const view_direction = self.player.view_direction;
    self.player.view_direction_mutex.unlock(io);
    const world_path = allocator.dupe(u8, self.world_path) catch return error.RecreatePathAllocationFailed;
    defer allocator.free(world_path);

    if (self.generator) |*generator| {
        generator.generator.api.config_set_seeds(&io, generator.config);
        generator.saveConfig(io) catch return error.RecreateConfigSaveFailed;
    }

    self.stopBackgroundWork(io);
    self.world.trySaveAll(io) catch {
        self.running.store(true, .unordered);
        return error.RecreateChunkSaveFailed;
    };
    self.world_storage.clear() catch {
        self.running.store(true, .unordered);
        return error.RecreateStorageClearFailed;
    };

    self.deinit(io);
    try self.init(io, allocator, game_options, options_lock, world_path, vk_ctx, generators);

    self.player.physics.mutex.lockUncancelable(io);
    self.player.physics.pos = player_pos;
    self.player.physics.mutex.unlock(io);
    self.player.view_direction_mutex.lockUncancelable(io);
    self.player.view_direction = view_direction;
    self.player.view_direction_mutex.unlock(io);
    self.renderer.updateCameraDirection(view_direction);
}

fn cancelFuture(io: std.Io, future: anytype) void {
    if (future.*) |*f| {
        f.cancel(io) catch {};
        _ = f.await(io) catch {};
        future.* = null;
    }
}

pub fn frame(self: *@This(), io: std.Io, allocator: std.mem.Allocator, frame_ctx: Renderer.FrameDrawContext, viewport: @Vector(2, u32)) !void {
    const frame_zone: tracy.Zone = .begin(.{ .src = @src(), .name = "frame" });
    defer frame_zone.end();
    const now: std.Io.Timestamp = .now(io, .awake);
    const frame_time = self.last_frametime.durationTo(now);
    self.last_frametime = now;
    const frame_ns = @max(frame_time.nanoseconds, 1);
    const current_fps: f32 = std.time.ns_per_s / @as(f32, @floatFromInt(frame_ns));
    const fps = self.debug_menu.fps.load(.unordered);
    self.debug_menu.fps.store(std.math.lerp(fps, current_fps, 0.01), .unordered);

    const asyncs: tracy.Zone = .begin(.{ .src = @src(), .name = "asyncs" });

    var entities_future = io.async(EntityRegistry.update, .{ &self.entity_registry, io, allocator, &self.world });
    defer entities_future.cancel(io) catch {};
    try restartFutures(self, io, allocator);
    try entities_future.await(io);
    asyncs.end();
    self.debug_menu.entities.store(self.entity_registry.count(), .unordered);
    const player_pos = self.player.getInterface().getPos.?(@ptrCast(self.player), io);

    try self.renderer.draw(io, .{ .width = viewport[0], .height = viewport[1] }, frame_ctx, player_pos);

    self.debug_menu.opaque_drawn.store(self.vulkan_renderer.frame_stats.opaque_drawn, .unordered);
    self.debug_menu.transparent_drawn.store(self.vulkan_renderer.frame_stats.transparent_drawn, .unordered);
    self.debug_menu.occluded.store(self.vulkan_renderer.frame_stats.hiz_occluded, .unordered);
    self.debug_menu.frustum_culled.store(self.vulkan_renderer.frame_stats.frustum_culled, .unordered);
    self.debug_menu.opaque_faces.store(self.vulkan_renderer.frame_stats.opaque_faces, .unordered);
    self.debug_menu.transparent_faces.store(self.vulkan_renderer.frame_stats.transparent_faces, .unordered);
    self.debug_menu.shadow_faces.store(self.vulkan_renderer.frame_stats.shadow_faces, .unordered);
    self.debug_menu.shadow_cascade.store(if (self.vulkan_renderer.frame_stats.shadow_cascade) |c| c else std.math.maxInt(u32), .unordered);

    try self.handleErrors();
}

fn restartFutures(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "restartFutures" });
    defer z.end();
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);

    try restartFuture(io, &self.chunk_load_is_running, &self.last_chunk_load, &self.load_future, self.options.loader_frequency_ms, loadChunks, .{ self, io, allocator });
    try restartFuture(io, &self.mesh_unload_is_running, &self.last_mesh_unload, &self.mesh_unload_future, self.options.mesh_unload_frequency_ms, unloadChunkMeshes, .{ self, io });
    try restartFuture(io, &self.save_is_running, &self.last_save, &self.save_future, self.options.save_frequency_ms, saveFuture, .{ self, io });
}

fn restartFuture(
    io: std.Io,
    running: *std.atomic.Value(bool),
    last: *std.Io.Timestamp,
    future: anytype,
    frequency_ms: u64,
    comptime function: anytype,
    args: anytype,
) !void {
    if (!running.load(.seq_cst) and last.durationTo(.now(io, .awake)).toMilliseconds() > frequency_ms) {
        if (future.*) |*f| try f.await(io);

        running.store(true, .seq_cst);
        last.* = .now(io, .awake);
        future.* = io.concurrent(function, args) catch io.async(function, args);
    }
}

fn saveFuture(self: *@This(), io: std.Io) !void {
    defer self.save_is_running.store(false, .seq_cst);
    try self.world.trySaveAll(io);
}

fn handleErrors(self: *@This()) !void {
    const err = @errorFromInt(self.deferred_error.swap(@intFromError(error.NoError), .seq_cst));
    std.debug.assert(err != error.Canceled);
    if (err != error.NoError) return err;
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

pub fn handleMouseMotion(self: *@This(), io: std.Io, mouse_motion: wio.Position) void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "handleMouseMotion" });
    defer z.end();
    const sensitivity = self.getMouseSensitivity(io);

    const view_dir_diff: @Vector(2, f32) = @Vector(2, f32){ mouse_motion.y, mouse_motion.x } * @as(@Vector(2, f32), @splat(sensitivity));

    const small_f32 = 0.00001;

    self.player.view_direction_mutex.lockUncancelable(io);
    defer self.player.view_direction_mutex.unlock(io);
    var current_view_dir = self.player.view_direction;
    current_view_dir -= @Vector(3, f32){ view_dir_diff[0], view_dir_diff[1], 0 };
    current_view_dir[0] = std.math.clamp(current_view_dir[0], -90 + small_f32, 90 - small_f32);
    self.player.view_direction = current_view_dir;

    self.renderer.updateCameraDirection(current_view_dir);
}

pub fn handleScroll(self: *@This(), io: std.Io, scroll: f32) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "handleScroll" });
    defer z.end();
    self.options_lock.lockSharedUncancelable(io);
    const scroll_sensitivity = self.options.scroll_sensitivity;
    self.options_lock.unlockShared(io);
    switch (self.player.game_mode.load(.seq_cst)) {
        .Creative, .Spectator => {
            const scroll_delta = -scroll * scroll_sensitivity;
            const fly_speed_linear_old = self.player.fly_speed_linear.fetchAdd(scroll_delta, .seq_cst);
            const fly_speed_linear_new = fly_speed_linear_old + scroll_delta;
            _ = self.player.fly_speed.store(@min(@as(f32, @floatFromInt(std.math.maxInt(i32))), std.math.pow(f32, 2, fly_speed_linear_new)), .seq_cst);
        },
        .Survival => {},
    }
}

pub fn handleButtonActions(self: *Game, io: std.Io, actions: *const Key.ActionSet) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "handleButtonActions" });
    defer z.end();
    switch (self.player.game_mode.load(.unordered)) {
        .Creative, .Spectator => try self.flyMove(io, actions),
        .Survival => try self.walkMove(io, actions),
    }
    self.setSelectedSlot(actions);
    if (actions.contains(.spawn_explosive)) self.spawnExplosive(io) catch |err|
        std.log.err("error spawning explosive: {any}", .{err});
    groupAsync(self, io, itemAction, .{ self, io, actions.* });
}

fn setSelectedSlot(self: *@This(), actions: *const Key.ActionSet) void {
    const first_hotbar = @intFromEnum(Key.Action.hotbar_key_0);
    inline for (0..10) |i| {
        if (actions.contains(@enumFromInt(first_hotbar + i))) self.selected_inventory_col.store(i, .seq_cst);
    }
    if (actions.contains(.hotbar_scroll_up)) _ = self.selected_inventory_row.fetchAdd(1, .seq_cst);
    if (actions.contains(.hotbar_scroll_down)) _ = self.selected_inventory_row.fetchSub(1, .seq_cst);
}

fn spawnExplosive(self: *@This(), io: std.Io) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "spawnExplosive" });
    defer z.end();
    const player_pos = self.getPlayerPos(io);
    const looking = self.getCameraFront(io);
    const pos = player_pos + @as(@Vector(3, f64), @floatCast(looking)) * @as(@Vector(3, f64), @splat(2));
    const entity = try self.entity_registry.spawn(io, self.allocator, &self.world, EntityTypes.Explosive{
        .pos = pos,
        .dir = looking,
        .timestamp = std.Io.Timestamp.now(io, .awake).toNanoseconds(),
    });
    entity.release();
}

fn itemAction(self: *@This(), io: std.Io, actions: Key.ActionSet) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "itemAction" });
    defer z.end();
    const player_pos = self.getPlayerPos(io);
    const looking = self.getCameraFront(io);

    try self.options_lock.lockShared(io);
    const sphere_size = self.options.sphere_size;
    const sphere_block = self.options.sphere_block;
    self.options_lock.unlockShared(io);

    var editor: World.Editor = .{ .world = &self.world, .temp_allocator = self.allocator };
    defer editor.clear();
    const cone: Cone(f32) = .init(@floatCast(player_pos), looking, 100, 10, 10);
    if (actions.contains(.use_item_primary)) try editor.placeSamplerShape(.air, cone, 0);
    if (actions.contains(.use_item_secondary)) try editor.placeSamplerShape(.stone, cone, 0);
    if (actions.contains(.use_item_tertiary)) {
        try editor.placeSamplerShape(sphere_block, Sphere(f32).init(@floatCast(player_pos), @floatFromInt(sphere_size)), 0);
    }
    try editor.flush(io, self.allocator);
}

fn strafeDirection(camera_front: @Vector(3, f32)) ?zm.Vec3f {
    const cross = zm.Vec3f.crossRH(.{ .data = camera_front }, .{ .data = Renderer.cameraUp });
    if (std.meta.eql(cross.data, @Vector(3, f64){ 0, 0, 0 })) return null;
    return cross.norm();
}

fn flyMove(self: *@This(), io: std.Io, actions: *const Key.ActionSet) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "flyMove" });
    defer z.end();
    const camera_front = self.getCameraFront(io);
    const speed: @Vector(3, f32) = @splat(self.player.fly_speed.load(.unordered));
    const right_dir = strafeDirection(camera_front);

    self.player.physics.mutex.lockUncancelable(io);
    defer self.player.physics.mutex.unlock(io);

    // Reset velocity so fly input is frame-independent.
    self.player.physics.velocity = .{ 0, 0, 0 };

    var vel: @Vector(3, f64) = .{ 0, 0, 0 };
    if (actions.contains(.forward)) vel += @as(@Vector(3, f64), @floatCast(speed * camera_front));
    if (actions.contains(.backward)) vel += @as(@Vector(3, f64), @floatCast(-speed * camera_front));
    if (actions.contains(.up)) vel += .{ 0, speed[1], 0 };
    if (actions.contains(.down)) vel += .{ 0, -speed[1], 0 };
    if (right_dir) |r| {
        if (actions.contains(.right)) vel += @as(@Vector(3, f64), @floatCast(speed * r.data));
        if (actions.contains(.left)) vel += @as(@Vector(3, f64), @floatCast(-speed * r.data));
    }
    self.player.physics.velocity = vel;
}

fn walkMove(self: *@This(), io: std.Io, actions: *const Key.ActionSet) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "walkMove" });
    defer z.end();
    const now = std.Io.Timestamp.now(io, .awake);
    const dt_ns = now.nanoseconds -| self.last_frametime.nanoseconds;
    const delta_time_seconds = @as(f32, @floatFromInt(dt_ns)) / std.time.ns_per_s;
    const camera_front = self.getCameraFront(io);
    const speed: @Vector(3, f32) = @splat(self.player.walk_speed.load(.unordered));
    const right_dir = strafeDirection(camera_front);

    var block_reader: World.Reader = .{ .world = &self.world };
    defer block_reader.clear(io);

    const player_pos = self.getPlayerPos(io);
    const ground_dist = try self.player.physics.elements.mover.getShortestGroundDistance(io, self.allocator, player_pos - @Vector(3, f64){ 0.001, 0.001, 0.001 }, &block_reader);
    const on_ground = ground_dist <= 0;
    const speed_multiplier: @Vector(3, f32) = @splat(if (on_ground) 1.0 else 0.35);

    self.player.physics.mutex.lockUncancelable(io);
    defer self.player.physics.mutex.unlock(io);

    if (actions.contains(.up) and on_ground) {
        self.player.physics.velocity[1] = self.player.jump_strength.load(.unordered);
    }

    var vel_diff: @Vector(3, f64) = @splat(0.0);
    if (actions.contains(.forward)) vel_diff += @as(@Vector(3, f64), @floatCast(speed * camera_front));
    if (actions.contains(.backward)) vel_diff += @as(@Vector(3, f64), @floatCast(-speed * camera_front));
    if (right_dir) |r| {
        if (actions.contains(.right)) vel_diff += @as(@Vector(3, f64), @floatCast(speed * r.data));
        if (actions.contains(.left)) vel_diff += @as(@Vector(3, f64), @floatCast(-speed * r.data));
    }
    vel_diff = vel_diff * speed_multiplier;

    if (on_ground) {
        self.player.physics.velocity[0] = vel_diff[0];
        self.player.physics.velocity[2] = vel_diff[2];
    } else {
        const dt_f64 = @as(f64, @floatCast(delta_time_seconds));
        self.player.physics.velocity[0] += vel_diff[0] * dt_f64;
        self.player.physics.velocity[2] += vel_diff[2] * dt_f64;
    }
}

pub fn getPlayerPos(self: *@This(), io: std.Io) @Vector(3, f64) {
    const z = tracy.Zone.begin(.{ .src = @src(), .name = "getPlayerPos" });
    defer z.end();
    self.player.physics.mutex.lockUncancelable(io);
    defer self.player.physics.mutex.unlock(io);
    return self.player.physics.pos;
}

fn getCameraFront(self: *@This(), io: std.Io) @Vector(3, f32) {
    const z = tracy.Zone.begin(.{ .src = @src(), .name = "getCameraFront" });
    defer z.end();
    self.player.view_direction_mutex.lockUncancelable(io);
    defer self.player.view_direction_mutex.unlock(io);
    return Renderer.cameraFrontFromViewDirection(self.player.view_direction);
}

fn getLevels(self: *@This(), io: std.Io) struct { i32, i32 } {
    const z = tracy.Zone.begin(.{ .src = @src(), .name = "getLevels" });
    defer z.end();
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return .{ self.options.lowest_level, self.options.highest_level };
}

fn getRenderDistance(self: *@This(), io: std.Io) @Vector(2, u32) {
    const z = tracy.Zone.begin(.{ .src = @src(), .name = "getRenderDistance" });
    defer z.end();
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return .{ self.options.render_distance_x, self.options.render_distance_y };
}

/// Consistent snapshot of everything geometry culling depends on. Taken once
/// per bulk pass so per-entry checks are lock-free pure functions.
const ViewSnapshot = struct {
    lowest_level: i32,
    highest_level: i32,
    player_pos: @Vector(3, f64),
    render_distance: @Vector(2, u32),

    fn innerGenRadius(self: @This(), level: i32) @Vector(2, u32) {
        return innerRadiusFor(self.lowest_level, self.render_distance, level);
    }

    fn keepChunkLoaded(self: @This(), chunk_pos: World.ChunkPos) bool {
        return keepLoaded(self.lowest_level, self.highest_level, self.player_pos, chunk_pos, self.innerGenRadius(chunk_pos.level), self.render_distance);
    }
};

/// Levels above the lowest are refined by their children, so their generation ring
/// stops one chunk short of the child ring it feeds.
fn innerRadiusFor(lowest_level: i32, gen_distance: @Vector(2, u32), level: i32) @Vector(2, u32) {
    if (level <= lowest_level) return @splat(0);
    const inner_radius = gen_distance / @Vector(2, u32){ World.scale_factor, World.scale_factor };
    return inner_radius -| @Vector(2, u32){ 1, 1 };
}

fn snapshotView(self: *@This(), io: std.Io) ViewSnapshot {
    const lowest_level, const highest_level = self.getLevels(io);
    return .{
        .lowest_level = lowest_level,
        .highest_level = highest_level,
        .player_pos = self.getPlayerPos(io),
        .render_distance = self.getRenderDistance(io),
    };
}

fn getInnerGenRadius(self: *@This(), io: std.Io, gen_distance: @Vector(2, u32), level: i32) @Vector(2, u32) {
    const z = tracy.Zone.begin(.{ .src = @src(), .name = "getInnerGenRadius" });
    defer z.end();
    const lowest_level, _ = self.getLevels(io);
    return innerRadiusFor(lowest_level, gen_distance, level);
}

fn getMouseSensitivity(self: *@This(), io: std.Io) f32 {
    const z = tracy.Zone.begin(.{ .src = @src(), .name = "getMouseSensitivity" });
    defer z.end();
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return self.options.mouse_sensitivity;
}

fn isUniformAir(io: std.Io, chunk: *Chunk) !bool {
    try chunk.lockShared(io);
    defer chunk.unlockShared(io);
    return switch (chunk.encoding) {
        .uniform => |block| block == .air,
        .grid => false,
    };
}

/// Adds a chunk to the render list replacing it if it already exists, generates it or its neighbors if it doesn't exist.
fn addChunkToRender(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: World.ChunkPos, generate_structures: bool) !void {
    const GenMeshAndAdd = tracy.Zone.begin(.{ .src = @src(), .name = "GenMeshAndAdd" });
    defer GenMeshAndAdd.end();

    // Prevent an old version of the chunk from staying loaded. One snapshot keeps both
    // halves of the decision consistent.
    const view = self.snapshotView(io);
    if (!view.keepChunkLoaded(chunk_pos) and self.canUnloadMeshView(io, view, chunk_pos)) {
        try self.renderer.removeChunk(io, chunk_pos);
        try self.tryRemoveChunkFromLoaded(io, self.allocator, chunk_pos);
        return;
    }

    const chunk = try self.world.loadChunk(io, allocator, chunk_pos, generate_structures);
    defer chunk.release();

    // Uniform air produces no faces against any neighbor, so the extraction and
    // renderer round-trip are pure overhead unless an old mesh must be cleared.
    // A concurrent edit that turns this chunk non-air queues its own pass, so
    // reading the encoding outside the meshing lock cannot strand a missing mesh.
    if (!try isUniformAir(io, chunk) or self.renderer.hasMesh(io, chunk_pos)) {
        var neighbor_faces: [6]Chunk.Encoding.Face = undefined;
        {
            const zone_faces = tracy.Zone.begin(.{ .src = @src(), .name = "extract_faces" });
            defer zone_faces.end();
            inline for (&neighbor_faces, std.enums.values(Chunk.Encoding.FaceRotation)) |*face, rotation|
                face.* = try (try self.world.loadChunk(io, allocator, chunk_pos.offset(rotation), false)).extractFace(io, rotation.invert(), true);
        }

        const chunk_add = tracy.Zone.begin(.{ .src = @src(), .name = "chunk_add" });
        defer chunk_add.end();
        try chunk.lockShared(io);
        defer chunk.unlockShared(io);
        try self.renderer.addChunk(io, chunk_pos, chunk.encoding, &neighbor_faces);
    }
    const mark = tracy.Zone.begin(.{ .src = @src(), .name = "mark" });
    defer mark.end();

    var was_covering = false;
    var is_covering = false;
    {
        const mark_write = tracy.Zone.begin(.{ .src = @src(), .name = "mark_write" });
        defer mark_write.end();
        const bucket = self.loaded_or_meshed.getBucket(chunk_pos);
        try bucket.lock.lock(io);
        defer bucket.lock.unlock(io);
        var state: NodeData = bucket.hash_map.get(chunk_pos) orelse .{ .structures_generated = generate_structures };

        was_covering = state.isCovering();

        state.is_active = true;
        state.is_queued = false;
        if (generate_structures) state.structures_generated = true;

        is_covering = state.isCovering();
        try bucket.hash_map.put(allocator, chunk_pos, state);
    }

    if (!was_covering and is_covering) {
        const mark_get_levels = tracy.Zone.begin(.{ .src = @src(), .name = "mark_get_levels" });
        defer mark_get_levels.end();
        _, const highest = self.getLevels(io);
        try self.markSubtree(io, allocator, chunk_pos, true, highest);
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
    return self.snapshotView(io).keepChunkLoaded(chunk_pos);
}

fn keepLoaded(lowest_level: ?i32, highest_level: ?i32, player_pos: @Vector(3, f64), chunk_pos: World.ChunkPos, inner_chunk_range: ?@Vector(2, u32), outer_chunk_range: ?@Vector(2, u32)) bool {
    if (lowest_level) |l| if (chunk_pos.level < l) return false;
    if (highest_level) |h| if (chunk_pos.level > h) return false;

    const player_chunk_pos = @trunc(player_pos / @as(@Vector(3, f64), @splat(World.ChunkPos.levelToBlockRatioF64(chunk_pos.level))));
    const chunk_center: @Vector(3, f64) = chunk_pos.position;

    if (inner_chunk_range) |icr| {
        const inner: @Vector(3, f64) = .{ icr[0], icr[1], icr[0] };
        if (isInside(player_chunk_pos, chunk_center, inner)) return false;
    }

    if (outer_chunk_range) |ocr| {
        const outer: @Vector(3, f64) = .{ ocr[0], ocr[1], ocr[0] };
        if (isOutside(player_chunk_pos, chunk_center, outer)) return false;
    }
    return true;
}

fn isInside(point: @Vector(3, f64), center: @Vector(3, f64), radius: @Vector(3, f64)) bool {
    return @reduce(.And, point > (center - radius)) and @reduce(.And, point < center + radius);
}

fn isOutside(point: @Vector(3, f64), center: @Vector(3, f64), radius: @Vector(3, f64)) bool {
    return @reduce(.Or, point < center - radius) or @reduce(.Or, point > center + radius);
}

///Loads all chunks in render distance
fn loadChunks(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    const z = tracy.Zone.begin(.{ .src = @src(), .name = "addChunksToLoad" });
    defer z.end();
    defer self.chunk_load_is_running.store(false, .seq_cst);
    var levels = self.getLevels(io);
    var level = levels[0];
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var error_int: std.atomic.Value(@Int(.unsigned, @bitSizeOf(anyerror))) = .init(@intFromError(error.NoError));
    while (level <= levels[1]) : (level += 1) {
        levels = self.getLevels(io);
        group.async(io, loadChunksSpiral, .{ self, io, allocator, level, &error_int });
    }
    try group.await(io);

    const load_error = @errorFromInt(error_int.swap(@intFromError(error.NoError), .seq_cst));
    switch (load_error) {
        error.NoError => {},
        error.Canceled => unreachable,
        else => |e| return e,
    }
}

///loads chunks from top to bottom and in a spiral on a y level
fn loadChunksSpiral(game: *@This(), io: std.Io, allocator: std.mem.Allocator, level: i32, error_int: *std.atomic.Value(@Int(.unsigned, @bitSizeOf(anyerror)))) Io.Cancelable!void {
    const spiral_zone: tracy.Zone = .begin(.{ .src = @src(), .name = "loadChunksSpiral" });
    defer spiral_zone.end();
    try game.player.physics.mutex.lock(io);
    var player_pos = game.player.physics.pos;
    game.player.physics.mutex.unlock(io);
    var player_chunk_pos = World.ChunkPos.fromGlobalBlockPos(@trunc(player_pos), level);

    var outer_radius = game.getRenderDistance(io);
    var inner_radius = game.getInnerGenRadius(io, outer_radius, level);

    var amount_loaded: u64 = 0;
    var amount_tested: u64 = 0;

    var xz: [2]i32 = .{ 0, 0 };
    var c: usize = 0;

    while (true) {
        if (!game.running.load(.unordered)) return;
        if (amount_tested >= 4 * outer_radius[0] * outer_radius[0]) break;

        if (game.player.physics.mutex.tryLock()) {
            defer game.player.physics.mutex.unlock(io);
            const new_player_chunk_pos = World.ChunkPos.fromGlobalBlockPos(@trunc(game.player.physics.pos), level);
            if (!std.meta.eql(player_chunk_pos, new_player_chunk_pos)) {
                player_chunk_pos = new_player_chunk_pos;
                player_pos = game.player.physics.pos;
                c = 0;
                xz = .{ 0, 0 };
                amount_tested = 0;
                continue;
            }
        }

        try io.checkCancel();
        outer_radius = game.getRenderDistance(io);
        inner_radius = game.getInnerGenRadius(io, outer_radius, level);

        const m = move(xz, &c);
        var cc: i32 = 0;
        while (line(&xz, &cc, m)) {
            if (!game.running.load(.unordered)) return;
            amount_tested += 1;

            var y: i32 = -@as(i32, @intCast(outer_radius[1]));
            while (y < outer_radius[1]) : (y += 1) {
                const chunk_pos: World.ChunkPos = .{ .position = [3]i32{ xz[0] + player_chunk_pos.position[0], y + player_chunk_pos.position[1], xz[1] + player_chunk_pos.position[2] }, .level = level };

                if (!keepLoaded(null, null, player_pos, chunk_pos, inner_radius, outer_radius)) continue;

                const needs_load = if (game.loaded_or_meshed.get(io, chunk_pos)) |node_data|
                    (!node_data.is_active and !node_data.is_queued) or !node_data.structures_generated
                else
                    true;

                if (needs_load) {
                    amount_loaded += 1;
                    game.addChunkToRenderAsync(io, allocator, chunk_pos, true) catch |err| switch (err) {
                        error.Canceled => return error.Canceled,
                        else => |e| error_int.store(@intFromError(e), .unordered),
                    };
                }
            }
        }
    }
}

fn unloadChunkMeshes(self: *@This(), io: std.Io) !void {
    const unload = tracy.Zone.begin(.{ .src = @src(), .name = "UnloadMeshes" });
    defer unload.end();
    defer self.mesh_unload_is_running.store(false, .seq_cst);

    const view = self.snapshotView(io);

    const ChunkCollector = struct {
        game: *Game,
        io: std.Io,
        view: ViewSnapshot,
        chunks: u64 = 0,
        unloaded: u64 = 0,
        err: ?anyerror = null,

        pub fn callback(userdata: *anyopaque, chunk_pos: World.ChunkPos) error{Failed}!void {
            const ctx: *@This() = @ptrCast(@alignCast(userdata));
            ctx.chunks += 1;
            if (ctx.view.keepChunkLoaded(chunk_pos)) return;
            if (!ctx.game.canUnloadMeshView(ctx.io, ctx.view, chunk_pos)) return;

            ctx.game.tryRemoveChunkFromLoaded(ctx.io, ctx.game.allocator, chunk_pos) catch |err| {
                ctx.err = err;
                return error.Failed;
            };

            ctx.game.renderer.removeChunk(ctx.io, chunk_pos) catch |err| {
                ctx.err = err;
                return error.Failed;
            };
            ctx.unloaded += 1;
        }
    };
    var ctx = ChunkCollector{
        .game = self,
        .io = io,
        .view = view,
    };

    self.renderer.forEachMesh(io, &ctx, ChunkCollector.callback) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Failed => if (ctx.err) |e| return e,
    };
    self.debug_menu.meshes.store(ctx.chunks, .unordered);

    var it = self.loaded_or_meshed.iterator();
    defer it.deinit(io);
    while (try it.next(io)) |entry| {
        const key = entry.key_ptr.*;
        if (view.keepChunkLoaded(key)) continue;
        if (!entry.value_ptr.is_active and !entry.value_ptr.is_queued) continue;

        it.pause(io);
        try self.tryRemoveChunkFromLoaded(io, self.allocator, key);
        try it.unpause(io);
    }
}

fn spawnPlayer(game: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "spawnPlayer" });
    defer z.end();
    const player_entity = try game.entity_registry.spawn(io, allocator, &game.world, EntityTypes.Player{
        .player_name = .fromString("squid"),
        .physics = .{
            .elements = .{
                .mover = .{
                    .collisions = .init(false),
                    .bounding_box = .init(.{ .data = .{ -0.5, -2, -0.5 } }, .{ .data = .{ 0.5, 2, 0.5 } }),
                    .enabled = .init(true),
                    .zero_velocity = .init(true),
                },
                .gravity = .{
                    .enabled = .init(false),
                },
                .resistance = .{ .fraction_per_second = .init(0.1), .enabled = .init(false) },
            },
            .pos = .{ 0, 1000, 0 },
            .velocity = @splat(0),
            .last_update = .now(io, .awake),
        },
        .game_mode = .init(.Spectator),
        .view_direction = @Vector(3, f32){ 0.0001, -0.4, 0.001 },
        .main_inventory = undefined,
    });
    game.player_entity = player_entity;
    game.player = @ptrCast(@alignCast(player_entity.ptr));
    game.player.main_inventory = .initBuffer(
        10,
        16,
        &game.player.inventory_buffer,
    );
    game.player.view_direction_mutex.lockUncancelable(io);
    const view_direction = game.player.view_direction;
    game.player.view_direction_mutex.unlock(io);
    game.renderer.updateCameraDirection(view_direction);
}

fn move(xz_in: [2]i32, c: *usize) [2]i32 {
    const directions = [_][2]i32{ .{ 0, 1 }, .{ 1, 0 }, .{ 0, -1 }, .{ -1, 0 } };
    const mov: i32 = @intCast(c.* / 2 + 1);
    const dir = directions[c.* % 4];
    c.* += 1;
    return .{ xz_in[0] + dir[0] * mov, xz_in[1] + dir[1] * mov };
}

fn line(xz: *[2]i32, c: *i32, end: [2]i32) bool {
    defer c.* += 1;
    if (c.* == 0) return true;
    if (xz[0] == end[0] and xz[1] == end[1]) return false;
    std.debug.assert(xz[0] == end[0] or xz[1] == end[1]);
    if (xz[0] == end[0]) {
        xz[1] += if (xz[1] < end[1]) 1 else -1;
    } else {
        xz[0] += if (xz[0] < end[0]) 1 else -1;
    }
    return !(xz[0] == end[0] and xz[1] == end[1]);
}

test {
    std.testing.refAllDecls(@This());
}
