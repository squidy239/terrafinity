const std = @import("std");
const Io = std.Io;

const dvui = @import("dvui");
const tracy = @import("tracy");
const wio = @import("wio");
const zm = @import("zm");

const Entity = @import("entity/Entity.zig");
const EntityRegistry = @import("entity/EntityRegistry.zig");
const EntityTypes = @import("entity/EntityTypes.zig");
const Item = @import("entity/Item.zig");
const Physics = @import("entity/Physics.zig");
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
const World = @import("world/World.zig");

const Game = @This();

allocator: std.mem.Allocator,
/// Path to this world's directory, retained so the world can be recreated in place.
world_path: []const u8,
world: World,
/// View into the player implementation. Only valid while player_entity holds
/// its reference.
player: *EntityTypes.Player,
/// Holds the reference that keeps the player entity resident in the cache.
player_entity: *Entity,
vulkan_renderer: Renderer.Vulkan,
renderer: Renderer,
generator: ?generator_loader.GeneratorInstance,
world_storage: World.WorldStorage,
spawn: EntityRegistry.SpawnConfig,
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

/// Background entity-drain task, started when idle like the chunk loader. The
/// previous pass is joined before a new one starts; the new pass then runs
/// concurrently with draw. The player runs synchronously on the frame thread instead.
entity_update_is_running: std.atomic.Value(bool) = .init(false),
entity_drain_future: ?std.Io.Future(@typeInfo(@TypeOf(updateEntities)).@"fn".return_type.?) = null,

group: std.Io.Group = .init,
/// The next frame handles this error and closes the game.
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
    covered_children: [World.scale_factor][World.scale_factor][World.scale_factor]bool = empty_coverage,
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

/// Bubbles coverage to the parent while the aggregate flips and prunes empty ghosts.
/// Callers pass a `highest` snapshot so one walk uses a consistent cutoff.
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
    if (pos.level < 0) return;
    const parent = pos.parent();
    if (parent.level > highest) return;
    const pos_in_parent = pos.posInParent();

    var bubble_up = false;
    {
        const bucket = self.loaded_or_meshed.getBucket(parent);
        const p = pos_in_parent;

        // Skip the exclusive lock when the slot already holds the target value.
        // The synthetic entry on a miss only fills the examined slot.
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

        // Another thread may flip the slot while this thread waits, so check again.
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

fn canUnloadMeshView(self: *@This(), io: std.Io, view: ViewSnapshot, chunk_pos: World.ChunkPos) bool {
    if (chunk_pos.level < 0) {
        if (!view.keepChunkLoaded(chunk_pos)) return true;
        return false;
    }
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
                // loader stalls. Level bounds apply: the loader never refines
                // out-of-bounds levels, so stale levels drain without lingering.
                const refine_radius = view.render_distance / @Vector(2, u32){ World.scale_factor, World.scale_factor };
                return !keepLoaded(view.lowest_level, view.highest_level, view.player_pos, chunk_pos, null, refine_radius);
            }
        }
    }
    std.debug.assert(parent.level == view.highest_level);

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
    view: ViewSnapshot,
) !void {
    if (!self.canUnloadMeshView(io, view, chunk_pos)) return;
    const bucket = self.loaded_or_meshed.getBucket(chunk_pos);
    var was_covering: bool = false;
    var is_covering: bool = false;
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
            _ = bucket.hash_map.remove(chunk_pos);
        } else {
            try bucket.hash_map.put(allocator, chunk_pos, state);
        }
    }
    if (was_covering and !is_covering) {
        try self.markSubtree(io, allocator, chunk_pos, false, view.highest_level);
    }
}

pub const Options = struct {
    mouse_sensitivity: f32 = 0.5,
    scroll_sensitivity: f32 = 0.1,

    lowest_level: i32 = 0,
    highest_level: i32 = 10,

    render_distance_x: u32 = 8,
    render_distance_y: u32 = 6,

    lod_overlap: i32 = 1,

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
    pub const default: @This() = .{ .generator_name = "Terrain", .world_config = .{}, .spawn = .{} };
    /// Name of the generator shared library this world uses.
    generator_name: []const u8,
    world_config: World.WorldConfig,
    spawn: EntityRegistry.SpawnConfig,

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

        var spawn_state: EntityRegistry.SpawnConfig = .{};
        const spawn_config_file = world_folder.openFile(io, "config/Spawn.zon", .{ .lock = .shared }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (spawn_config_file) |file| {
            defer file.close(io);
            spawn_state = try utils.loadZon(EntityRegistry.SpawnConfig, io, file, allocator, allocator);
        }

        return .{
            .generator_name = generator_name,
            .world_config = try utils.loadZon(World.WorldConfig, io, world_config_file, allocator, allocator),
            .spawn = spawn_state,
        };
    }

    /// Writes the world options into the config directory of the given folder, creating missing files.
    pub fn save(self: WorldOptions, io: std.Io, folder: []const u8) !void {
        var wbuffer: [1024]u8 = undefined;
        var gbuffer: [1024]u8 = undefined;
        var sbuffer: [1024]u8 = undefined;

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

        const spawn_config_file = try world_folder.createFile(io, "config/Spawn.zon", .{ .lock = .exclusive });
        defer spawn_config_file.close(io);

        var spawn_config_writer = spawn_config_file.writer(io, &sbuffer);

        try std.zon.stringify.serialize(self.world_config, .{}, &world_config_writer.interface);
        try std.zon.stringify.serialize(GeneratorSelection{ .generator = self.generator_name }, .{}, &generator_config_writer.interface);
        try std.zon.stringify.serialize(self.spawn, .{}, &spawn_config_writer.interface);

        try world_config_writer.end();
        try generator_config_writer.end();
        try spawn_config_writer.end();
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
        .spawn = undefined,
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

    game.spawn = world_options.spawn;
    const spawn_pos = try game.resolveSpawnPos(io, allocator, folder, &world_options);
    try game.spawnPlayer(io, allocator, spawn_pos);
}

const spawn_scan_above: f64 = 512;
const spawn_scan_below: f64 = 1024;
const spawn_required_air: u32 = 4;
const spawn_max_nudges: u32 = 8;
const spawn_rounds: u32 = 3;
// Attempt budgets double as search reach (rings advance per sample):
// phase 1 roams far for the canonical pick, phase 2 stays near home.
const spawn_phase1_attempts: u32 = 128;
const spawn_phase2_attempts: u32 = 64;

const SpawnResolution = union(enum) {
    ok: @Vector(3, f64),
    ocean,
    no_ground,
    blocked,
};

/// Resolves one generator-proposed column to feet. The hint Y ignores erosion and structures, so scan down for solid ground with clear air above it.
fn resolveSpawnColumn(game: *@This(), io: std.Io, allocator: std.mem.Allocator, x: f64, z: f64, y_hint: f64) !SpawnResolution {
    const mover = Physics.Mover{
        .collisions = .init(true),
        .zero_velocity = .init(true),
        .bounding_box = .init(.{ .data = .{ -0.5, -2, -0.5 } }, .{ .data = .{ 0.5, 2, 0.5 } }),
        .enabled = .init(true),
    };
    var reader = World.Reader{ .world = &game.world };
    defer reader.clear(io);
    const bx: i64 = @intFromFloat(@round(x));
    const bz: i64 = @intFromFloat(@round(z));
    // Erosion shifts analytic estimates by hundreds of blocks, so scan a wide window. The first solid block from the top is the surface.
    var y: i64 = @intFromFloat(@floor(y_hint + spawn_scan_above));
    const bottom: i64 = @intFromFloat(@floor(y_hint - spawn_scan_below));
    var air_run: u32 = 0;
    var air_wet: u32 = 0;
    var saw_water = false;
    while (y >= bottom) : (y -= 1) {
        const block = try reader.getBlock(io, allocator, .{ bx, y, bz }, World.standard_level);
        if (block == .water) saw_water = true;
        if (!block.isSolid()) {
            air_run += 1;
            air_wet = (air_wet << 1 | @intFromBool(block == .water)) & 0xf;
            continue;
        }
        if (air_run >= spawn_required_air) {
            if (air_wet != 0) return .ocean;
            // The box overlaps neighbor columns, so nudge up on slopes instead of rejecting the spot.
            var feet = @Vector(3, f64){ x, @as(f64, @floatFromInt(y)) + 0.5 + 2 + 0.01, z };
            for (0..spawn_max_nudges + 1) |_| {
                if (try mover.checkCollision(io, allocator, feet, &reader) == null) break;
                feet[1] += 1.0;
            } else return .blocked;
            return .{ .ok = feet };
        }
        air_run = 0;
        air_wet = 0;
    }
    return if (saw_water) .ocean else .no_ground;
}

/// Runs one propose-plus-resolve batch for both spawn phases. Abstention fails hard because no fallback spawn exists without a radius bound.
fn trySpawnRounds(game: *@This(), io: std.Io, allocator: std.mem.Allocator, center: [3]f64, radius: f64, attempts: u32, phase: u8) !?@Vector(3, f64) {
    const generator = game.generator orelse return error.GeneratorNotFound;
    for (0..spawn_rounds) |round| {
        var nonce: u64 = undefined;
        io.random(std.mem.asBytes(&nonce));
        const spot = generator.generator.api.propose_spawn(generator.instance, &center, radius, attempts, nonce);
        if (!spot.found) {
            std.log.err("spawn phase {d} round {d}: generator abstained", .{ phase, round });
            return error.GeneratorSpawnFailed;
        }
        const resolved = try game.resolveSpawnColumn(io, allocator, spot.pos[0], spot.pos[2], spot.pos[1]);
        switch (resolved) {
            .ok => |pos| return pos,
            .ocean, .no_ground, .blocked => std.log.warn("spawn phase {d} round {d}: {s} at candidate {d:.1}, {d:.1}, {d:.1}", .{ phase, round, @tagName(resolved), spot.pos[0], spot.pos[1], spot.pos[2] }),
        }
    }
    return null;
}

/// Picks the canonical spawn once, then jitters around it on later joins. The generator proposes columns and the host scan fixes feet Y.
fn resolveSpawnPos(game: *@This(), io: std.Io, allocator: std.mem.Allocator, folder: []const u8, world_options: *WorldOptions) !@Vector(3, f64) {
    if (game.spawn.found) {
        // Same radius on retry: growing it would abandon the island.
        if (try game.trySpawnRounds(io, allocator, game.spawn.pos, @floatFromInt(game.spawn.range), spawn_phase2_attempts, 2)) |pos| return pos;
        // No fallback spawn exists; degrade to the canonical point itself.
        std.log.warn("spawn phase 2 exhausted, degrading to canonical spawn", .{});
        return game.spawn.pos;
    }
    if (try game.trySpawnRounds(io, allocator, game.spawn.center, @floatFromInt(game.spawn.range), spawn_phase1_attempts, 1)) |pos| {
        std.log.info("spawn phase 1 accepted {d:.1}, {d:.1}, {d:.1}", .{ pos[0], pos[1], pos[2] });
        game.spawn.pos = pos;
        game.spawn.found = true;
        world_options.spawn = game.spawn;
        try world_options.save(io, folder);
        return pos;
    }
    std.log.err("spawn phase 1 failed after {d} rounds around {d:.1}, {d:.1}, {d:.1}", .{
        spawn_rounds,
        game.spawn.center[0],
        game.spawn.center[1],
        game.spawn.center[2],
    });
    return error.GeneratorSpawnFailed;
}

fn stopBackgroundWork(self: *@This(), io: std.Io) void {
    self.running.store(false, .unordered);

    cancelFuture(io, &self.mesh_unload_future);
    cancelFuture(io, &self.save_future);
    cancelFuture(io, &self.load_future);
    cancelFuture(io, &self.entity_drain_future);
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

/// Discards chunks and reopens the world with the current generator configuration.
/// The caller waits for the GPU first because the renderer is fully recreated.
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
    // A full save is required before clear(): a skipped shard would be destroyed unsaved.
    self.world.saveAll(io) catch {
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
        // Cancel waits for the task and reports its final result. A task that
        // stopped because of the cancel reports error.Canceled, which is expected.
        _ = f.cancel(io) catch |err| {
            if (@intFromError(err) != @intFromError(error.Canceled)) {
                std.log.err("background task failed: {any}", .{err});
            }
        };
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

    try restartFutures(self, io, allocator);
    try startEntityDrain(self, io, allocator);
    // The player is updated synchronously every frame so the camera never waits
    // on the background drain.
    try self.updatePlayer(io, allocator, EntityRegistry.nowNs(io));
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
    // Hold the shared lock once for all frequencies; the awaits and spawns below run lock-free.
    self.options_lock.lockSharedUncancelable(io);
    const loader_frequency_ms = self.options.loader_frequency_ms;
    const mesh_unload_frequency_ms = self.options.mesh_unload_frequency_ms;
    const save_frequency_ms = self.options.save_frequency_ms;
    self.options_lock.unlockShared(io);

    try restartFuture(io, &self.chunk_load_is_running, &self.last_chunk_load, &self.load_future, loader_frequency_ms, loadChunks, .{ self, io, allocator });
    try restartFuture(io, &self.mesh_unload_is_running, &self.last_mesh_unload, &self.mesh_unload_future, mesh_unload_frequency_ms, unloadChunkMeshes, .{ self, io });
    try restartFuture(io, &self.save_is_running, &self.last_save, &self.save_future, save_frequency_ms, saveFuture, .{ self, io });
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

/// Background entity-drain body: runs every due timer once, then clears the
/// running flag so the next frame starts it again.
fn updateEntities(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    defer self.entity_update_is_running.store(false, .seq_cst);
    // Cancellation is teardown, not a fault; every other update error is fatal.
    self.entity_registry.drain(io, allocator, &self.world, EntityRegistry.nowNs(io)) catch |err| switch (err) {
        error.Canceled => {},
        else => return err,
    };
}

/// Starts the drain when the previous pass finished, mirroring restartFuture
/// without a frequency gate: at most one drain runs, and a slow drain simply
/// skips frames instead of overlapping.
fn startEntityDrain(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    if (self.entity_update_is_running.load(.seq_cst)) return;
    // Never spawn into teardown; stopBackgroundWork owns shutdown from here.
    if (!self.running.load(.unordered)) return;
    if (self.entity_drain_future) |*f| try f.await(io);

    self.entity_update_is_running.store(true, .seq_cst);
    self.entity_drain_future = io.concurrent(updateEntities, .{ self, io, allocator }) catch io.async(updateEntities, .{ self, io, allocator });
}

/// Runs the player on the frame thread, outside the wheel.
fn updatePlayer(self: *@This(), io: std.Io, allocator: std.mem.Allocator, now_ns: u64) !void {
    // Cancellation is teardown, not a fault; every other update error is fatal.
    self.entity_registry.updateNow(io, allocator, &self.world, self.player_entity, now_ns) catch |err| switch (err) {
        error.Canceled => {},
        else => return err,
    };
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
    const inventory = &self.player.main_inventory;
    const first_hotbar = @intFromEnum(Key.Action.hotbar_key_0);
    const hotbar_key_count = 10;
    inline for (0..hotbar_key_count) |slot| {
        if (actions.contains(@enumFromInt(first_hotbar + slot))) self.selectSlot(self.selectedRow(), @intCast(slot));
    }
    const row = self.selectedRow();
    const col = self.selectedCol();
    if (actions.contains(.hotbar_left)) self.selectSlot(row, if (col == 0) inventory.width - 1 else col - 1);
    if (actions.contains(.hotbar_right)) self.selectSlot(row, (col + 1) % inventory.width);
    if (actions.contains(.hotbar_up) or actions.contains(.hotbar_scroll_up)) self.selectSlot(if (row == 0) inventory.height - 1 else row - 1, col);
    if (actions.contains(.hotbar_down) or actions.contains(.hotbar_scroll_down)) self.selectSlot((row + 1) % inventory.height, col);
}

pub fn selectedRow(self: *const @This()) u32 {
    return self.selected_inventory_row.load(.seq_cst);
}

pub fn selectedCol(self: *const @This()) u32 {
    return self.selected_inventory_col.load(.seq_cst);
}

/// Moves the selection, clamping to the inventory grid.
pub fn selectSlot(self: *@This(), row: u32, col: u32) void {
    const inventory = &self.player.main_inventory;
    self.selected_inventory_row.store(@min(row, inventory.height - 1), .seq_cst);
    self.selected_inventory_col.store(@min(col, inventory.width - 1), .seq_cst);
}

fn spawnExplosive(self: *@This(), io: std.Io) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "spawnExplosive" });
    defer z.end();
    const player_pos = self.getPlayerPos(io);
    const looking = self.getCameraFront(io);
    const spawn_distance: f64 = 2;
    const pos = player_pos + @as(@Vector(3, f64), @floatCast(looking)) * @as(@Vector(3, f64), @splat(spawn_distance));
    const entity = try self.entity_registry.spawn(io, self.allocator, &self.world, EntityTypes.Explosive.init(
        pos,
        looking,
        std.Io.Timestamp.now(io, .awake).toNanoseconds(),
    ), .{ .initial_delay_ms = 0 });
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
    const cone_length: f32 = 100;
    const cone_radius: f32 = 10;
    const cone: Cone(f32) = .init(@floatCast(player_pos), looking, cone_length, cone_radius, cone_radius);
    if (actions.contains(.use_item_primary)) try editor.placeSamplerShape(.air, cone, World.standard_level);
    if (actions.contains(.use_item_secondary)) try editor.placeSamplerShape(.stone, cone, World.standard_level);
    if (actions.contains(.use_item_tertiary)) {
        try editor.placeSamplerShape(sphere_block, Sphere(f32).init(@floatCast(player_pos), @floatFromInt(sphere_size)), World.standard_level);
    }
    try editor.flush(io, self.allocator);
}

/// Frame wish direction from held keys. Y carries only fly up/down; walk ignores it.
fn wishDirection(camera_front: @Vector(3, f32), speed: @Vector(3, f32), actions: *const Key.ActionSet, flying: bool) @Vector(3, f64) {
    var vel: @Vector(3, f64) = .{ 0, 0, 0 };
    if (actions.contains(.forward)) vel += @as(@Vector(3, f64), @floatCast(speed * camera_front));
    if (actions.contains(.backward)) vel += @as(@Vector(3, f64), @floatCast(-speed * camera_front));
    if (flying) {
        if (actions.contains(.up)) vel += .{ 0, speed[1], 0 };
        if (actions.contains(.down)) vel += .{ 0, -speed[1], 0 };
    }
    const cross = zm.Vec3f.crossRH(.{ .data = camera_front }, .{ .data = Renderer.cameraUp });
    // Zero exactly when front is parallel to up, so strafe is undefined.
    if (cross.lenSq() > 0) {
        const r = cross.norm().data;
        if (actions.contains(.right)) vel += @as(@Vector(3, f64), @floatCast(speed * r));
        if (actions.contains(.left)) vel += @as(@Vector(3, f64), @floatCast(-speed * r));
    }
    return vel;
}

fn flyMove(self: *@This(), io: std.Io, actions: *const Key.ActionSet) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "flyMove" });
    defer z.end();
    const camera_front = self.getCameraFront(io);
    const speed: @Vector(3, f32) = @splat(self.player.fly_speed.load(.unordered));

    self.player.physics.mutex.lockUncancelable(io);
    defer self.player.physics.mutex.unlock(io);

    // Reset velocity so fly input is frame-independent.
    self.player.physics.velocity = wishDirection(camera_front, speed, actions, true);
}

fn walkMove(self: *@This(), io: std.Io, actions: *const Key.ActionSet) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "walkMove" });
    defer z.end();
    const now = std.Io.Timestamp.now(io, .awake);
    const dt_ns = now.nanoseconds -| self.last_frametime.nanoseconds;
    const dt_f64 = @as(f64, @floatFromInt(dt_ns)) / std.time.ns_per_s;
    const camera_front = self.getCameraFront(io);
    const speed: @Vector(3, f32) = @splat(self.player.walk_speed.load(.unordered));

    var block_reader: World.Reader = .{ .world = &self.world };
    defer block_reader.clear(io);

    const player_pos = self.getPlayerPos(io);
    const ground_dist = try self.player.physics.elements.mover.getShortestGroundDistance(io, self.allocator, player_pos - @Vector(3, f64){ 0.001, 0.001, 0.001 }, &block_reader);
    const on_ground = ground_dist <= 0;
    const speed_multiplier: @Vector(3, f64) = @splat(if (on_ground) 1.0 else 0.35);

    self.player.physics.mutex.lockUncancelable(io);
    defer self.player.physics.mutex.unlock(io);

    if (actions.contains(.up) and on_ground) {
        self.player.physics.velocity[1] = self.player.jump_strength.load(.unordered);
    }

    const vel_diff = wishDirection(camera_front, speed, actions, false) * speed_multiplier;

    if (on_ground) {
        self.player.physics.velocity[0] = vel_diff[0];
        self.player.physics.velocity[2] = vel_diff[2];
    } else {
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

const Levels = struct {
    lowest: i32,
    highest: i32,
};

fn getLevels(self: *@This(), io: std.Io) Levels {
    const z = tracy.Zone.begin(.{ .src = @src(), .name = "getLevels" });
    defer z.end();
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return .{ .lowest = self.options.lowest_level, .highest = self.options.highest_level };
}

/// Snapshots everything geometry culling depends on. Bulk passes take it once so per-entry checks stay lock-free.
const ViewSnapshot = struct {
    lowest_level: i32,
    highest_level: i32,
    player_pos: @Vector(3, f64),
    render_distance: @Vector(2, u32),
    lod_overlap: i32,

    fn innerGenRadius(self: @This(), level: i32) @Vector(2, u32) {
        return innerRadiusFor(self.lowest_level, self.render_distance, self.lod_overlap, level);
    }

    fn keepChunkLoaded(self: @This(), chunk_pos: World.ChunkPos) bool {
        return keepLoaded(self.lowest_level, self.highest_level, self.player_pos, chunk_pos, self.innerGenRadius(chunk_pos.level), self.render_distance);
    }
};

/// Stops each generation ring short of the child ring it feeds by the overlap. Detail levels never mark coverage, so the refinement floor stays at 0.
fn innerRadiusFor(lowest_level: i32, gen_distance: @Vector(2, u32), lod_overlap: i32, level: i32) @Vector(2, u32) {
    if (level <= lowest_level or (lowest_level < 0 and level == 0)) return @splat(0);
    const half: @Vector(2, i32) = @intCast(gen_distance / @Vector(2, u32){ World.scale_factor, World.scale_factor });
    const hole: @Vector(2, i32) = @max(half - @as(@Vector(2, i32), @splat(lod_overlap)), @as(@Vector(2, i32), @splat(0)));
    return @intCast(hole);
}

fn snapshotView(self: *@This(), io: std.Io) ViewSnapshot {
    // One short shared hold covers every options field; per-entry checks stay lock-free.
    self.options_lock.lockSharedUncancelable(io);
    const lowest_level = self.options.lowest_level;
    const highest_level = self.options.highest_level;
    const render_distance: @Vector(2, u32) = .{ self.options.render_distance_x, self.options.render_distance_y };
    const lod_overlap = self.options.lod_overlap;
    self.options_lock.unlockShared(io);
    return .{
        .lowest_level = lowest_level,
        .highest_level = highest_level,
        .player_pos = self.getPlayerPos(io),
        .render_distance = render_distance,
        .lod_overlap = lod_overlap,
    };
}

fn getMouseSensitivity(self: *@This(), io: std.Io) f32 {
    const z = tracy.Zone.begin(.{ .src = @src(), .name = "getMouseSensitivity" });
    defer z.end();
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return self.options.mouse_sensitivity;
}

fn isUniformInvisible(io: std.Io, chunk: *Chunk) !bool {
    try chunk.lockShared(io);
    defer chunk.unlockShared(io);
    return switch (chunk.encoding) {
        .uniform => |block| !block.isVisible(),
        .grid => false,
    };
}

/// Generates a missing chunk and its neighbors, then adds or replaces its mesh.
fn addChunkToRender(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: World.ChunkPos, generate_structures: bool, view: ViewSnapshot) !void {
    const gen_mesh_add = tracy.Zone.begin(.{ .src = @src(), .name = "GenMeshAndAdd" });
    defer gen_mesh_add.end();
    // A dying task would strand the queued flag and skip the chunk forever, so always release it. Failures then retry on a later pass.
    defer self.clearQueuedFlag(io, chunk_pos);
    // Queued tasks capture a stale segment snapshot, so re-snapshot the keep gate here. The passed view remains only the coverage cutoff.
    const gate_view = self.snapshotView(io);
    if (!gate_view.keepChunkLoaded(chunk_pos) and self.canUnloadMeshView(io, gate_view, chunk_pos)) {
        try self.renderer.removeChunk(io, chunk_pos);
        try self.tryRemoveChunkFromLoaded(io, self.allocator, chunk_pos, gate_view);
        return;
    }

    const chunk = try self.world.loadChunk(io, allocator, chunk_pos, generate_structures);
    defer chunk.release();

    // Uniform invisible chunks produce no faces, so skip extraction unless an old mesh needs clearing. A concurrent edit queues its own pass, so this read cannot strand a mesh.
    if (!try isUniformInvisible(io, chunk) or self.renderer.hasMesh(io, chunk_pos)) {
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

    if (!was_covering and is_covering)
        try self.markSubtree(io, allocator, chunk_pos, true, view.highest_level);
}

fn clearQueuedFlag(self: *@This(), io: std.Io, chunk_pos: World.ChunkPos) void {
    const bucket = self.loaded_or_meshed.getBucket(chunk_pos);
    // getPtr drops its lock before returning, so the write needs its own.
    bucket.lock.lockUncancelable(io);
    defer bucket.lock.unlock(io);
    if (bucket.hash_map.getPtr(chunk_pos)) |state| state.is_queued = false;
}

fn addChunkToRenderAsync(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: World.ChunkPos, gen_structures: bool, view: ViewSnapshot) !void {
    {
        const bucket = self.loaded_or_meshed.getBucket(chunk_pos);
        try bucket.lock.lock(io);
        defer bucket.lock.unlock(io);
        const entry = try bucket.hash_map.getOrPutValue(allocator, chunk_pos, .{ .structures_generated = gen_structures });
        entry.value_ptr.is_queued = true;
    }

    self.groupAsync(io, addChunkToRender, .{ self, io, allocator, chunk_pos, gen_structures, view });
}

fn editorCallback(io: std.Io, allocator: std.mem.Allocator, chunk_pos: World.ChunkPos, args: *anyopaque) !void {
    const game: *@This() = @ptrCast(@alignCast(args));
    game.addChunkToRender(io, allocator, chunk_pos, false, game.snapshotView(io)) catch return error.OnEditFailed;
}

fn keepLoaded(lowest_level: ?i32, highest_level: ?i32, player_pos: @Vector(3, f64), chunk_pos: World.ChunkPos, inner_chunk_range: ?@Vector(2, u32), outer_chunk_range: ?@Vector(2, u32)) bool {
    if (lowest_level) |l| if (chunk_pos.level < l) return false;
    if (highest_level) |h| if (chunk_pos.level > h) return false;

    // Derive the player chunk through the same integer path as the loader. A float divide can disagree at exact boundaries from pow dust.
    const player_block: World.BlockPos = @intFromFloat(@floor(player_pos));
    const player_chunk_pos: @Vector(3, f64) = World.ChunkPos.fromGlobalBlockPos(player_block, chunk_pos.level).position;
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

fn loadChunks(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    const z = tracy.Zone.begin(.{ .src = @src(), .name = "addChunksToLoad" });
    defer z.end();
    defer self.chunk_load_is_running.store(false, .seq_cst);
    var levels = self.getLevels(io);
    var level = levels.lowest;
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var error_int: std.atomic.Value(@Int(.unsigned, @bitSizeOf(anyerror))) = .init(@intFromError(error.NoError));
    while (level <= levels.highest) : (level += 1) {
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

/// Walks one level top to bottom in a spiral around the player chunk.
fn loadChunksSpiral(game: *@This(), io: std.Io, allocator: std.mem.Allocator, level: i32, error_int: *std.atomic.Value(@Int(.unsigned, @bitSizeOf(anyerror)))) Io.Cancelable!void {
    const spiral_zone: tracy.Zone = .begin(.{ .src = @src(), .name = "loadChunksSpiral" });
    defer spiral_zone.end();
    var view = game.snapshotView(io);
    var player_pos = view.player_pos;
    var player_chunk_pos = World.ChunkPos.fromGlobalBlockPos(@floor(player_pos), level);

    var outer_radius = view.render_distance;
    var inner_radius = view.innerGenRadius(level);

    var amount_loaded: u64 = 0;
    var amount_tested: u64 = 0;

    var spiral_pos: [2]i32 = .{ 0, 0 };
    var segment_index: usize = 0;
    var first_segment = true;

    while (true) {
        if (!game.running.load(.unordered)) return;
        if (amount_tested >= (2 * outer_radius[0] + 1) * (2 * outer_radius[0] + 1)) break;

        // One snapshot per segment keeps the filter and its tasks on the same center and radii. A player-chunk crossing resets the spiral.
        if (first_segment) {
            first_segment = false;
        } else {
            const fresh = game.snapshotView(io);
            const fresh_chunk_pos = World.ChunkPos.fromGlobalBlockPos(@floor(fresh.player_pos), level);
            if (!std.meta.eql(player_chunk_pos, fresh_chunk_pos)) {
                view = fresh;
                player_pos = fresh.player_pos;
                player_chunk_pos = fresh_chunk_pos;
                outer_radius = fresh.render_distance;
                inner_radius = fresh.innerGenRadius(level);
                segment_index = 0;
                spiral_pos = .{ 0, 0 };
                amount_tested = 0;
                continue;
            }
            view = fresh;
            player_pos = fresh.player_pos;
            outer_radius = fresh.render_distance;
            inner_radius = fresh.innerGenRadius(level);
        }

        try io.checkCancel();

        const segment_end = spiralSegmentEnd(spiral_pos, &segment_index);
        var line_step: i32 = 0;
        while (advanceSpiralLine(&spiral_pos, &line_step, segment_end)) {
            if (!game.running.load(.unordered)) return;
            amount_tested += 1;

            var y: i32 = -@as(i32, @intCast(outer_radius[1]));
            while (y <= outer_radius[1]) : (y += 1) {
                const chunk_pos: World.ChunkPos = .{ .position = [3]i32{ spiral_pos[0] + player_chunk_pos.position[0], y + player_chunk_pos.position[1], spiral_pos[1] + player_chunk_pos.position[2] }, .level = level };

                if (!keepLoaded(null, null, player_pos, chunk_pos, inner_radius, outer_radius)) continue;

                const needs_load = if (game.loaded_or_meshed.get(io, chunk_pos)) |node_data|
                    (!node_data.is_active and !node_data.is_queued) or !node_data.structures_generated
                else
                    true;

                if (needs_load) {
                    amount_loaded += 1;
                    game.addChunkToRenderAsync(io, allocator, chunk_pos, true, view) catch |err| switch (err) {
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

            ctx.game.tryRemoveChunkFromLoaded(ctx.io, ctx.game.allocator, chunk_pos, ctx.view) catch |err| {
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
        try self.tryRemoveChunkFromLoaded(io, self.allocator, key, view);
        try it.unpause(io);
    }
}

fn spawnPlayer(game: *@This(), io: std.Io, allocator: std.mem.Allocator, spawn_pos: @Vector(3, f64)) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "spawnPlayer" });
    defer z.end();
    const default_game_mode = game.spawn.mode;
    const initial_view_direction: @Vector(3, f32) = .{ 0.0001, -0.4, 0.001 };
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
            .pos = spawn_pos,
            .velocity = @splat(0),
            .last_update = .now(io, .awake),
        },
        .game_mode = .init(default_game_mode),
        .view_direction = initial_view_direction,
        .main_inventory = undefined,
    }, .{});
    game.player_entity = player_entity;
    // The held reference keeps the player resident; the frame lane drives it.
    game.player = @ptrCast(@alignCast(player_entity.ptr));
    // The literal physics flags above match Spectator, so normalize them to the configured mode.
    game.player.switchGameMode(default_game_mode);
    game.player.main_inventory = .initBuffer(
        10,
        16,
        &game.player.inventory_buffer,
    );
    // Placeholder starter row so the hotbar has icons to show; real item grants come later.
    inline for (0..std.meta.fields(Item.ItemType).len) |col| {
        if (col < game.player.main_inventory.width) {
            const item_type: Item.ItemType = @enumFromInt(col);
            _ = game.player.main_inventory.set(io, 0, @intCast(col), .{ .item_type = item_type, .amount = 1 });
        }
    }
    game.player.view_direction_mutex.lockUncancelable(io);
    const view_direction = game.player.view_direction;
    game.player.view_direction_mutex.unlock(io);
    game.renderer.updateCameraDirection(view_direction);
}

fn spiralSegmentEnd(start: [2]i32, segment_index: *usize) [2]i32 {
    const directions: [4][2]i32 = .{ .{ 0, 1 }, .{ 1, 0 }, .{ 0, -1 }, .{ -1, 0 } };
    const segment_length: i32 = @intCast(segment_index.* / 2 + 1);
    const direction = directions[segment_index.* % 4];
    segment_index.* += 1;
    return .{ start[0] + direction[0] * segment_length, start[1] + direction[1] * segment_length };
}

fn advanceSpiralLine(position: *[2]i32, step: *i32, target: [2]i32) bool {
    defer step.* += 1;
    if (step.* == 0) return true;
    if (position[0] == target[0] and position[1] == target[1]) return false;
    std.debug.assert(position[0] == target[0] or position[1] == target[1]);
    if (position[0] == target[0]) {
        position[1] += if (position[1] < target[1]) 1 else -1;
    } else {
        position[0] += if (position[0] < target[0]) 1 else -1;
    }
    return !(position[0] == target[0] and position[1] == target[1]);
}
