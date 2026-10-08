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
const ChunkStreamer = @import("ChunkStreamer.zig");
const utils = @import("libs/utils.zig");
pub const Renderer = @import("Renderer.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const Chunk = @import("world/Chunk.zig");
const generator_loader = @import("world/generator_loader.zig");
const generator_api = @import("world/generators/generator_api.zig");
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
/// Only `streamPass` touches it, except `completions`, which tasks push to.
streamer: ChunkStreamer = .{},

entity_registry: EntityRegistry,

/// The player's block, published by the frame thread for stream passes and load
/// tasks, the only readers off that thread.
player_block: World.BlockPos = @splat(0),
player_block_mutex: std.Io.Mutex = .init,

last_stream: std.Io.Timestamp = .zero,
stream_is_running: std.atomic.Value(bool) = .init(false),
stream_future: ?std.Io.Future(@typeInfo(@TypeOf(streamPass)).@"fn".return_type.?) = null,

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
/// True when `handleButtonActions` ran this frame; otherwise the frame zeroes stale movement.
input_handled: bool = false,

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
} = .{},

pub const Options = struct {
    mouse_sensitivity: f32 = 0.5,
    scroll_sensitivity: f32 = 0.1,

    lowest_level: i32 = 0,
    highest_level: i32 = 10,

    render_distance_x: u32 = 8,
    render_distance_y: u32 = 6,

    lod_overlap: i32 = 1,

    mesh_unload_frequency_ms: u64 = 500,
    save_frequency_ms: u64 = 5000,

    terrain_height_cache_bytes: u64 = 268435456,
    chunk_cache_bytes: u64 = 1073741824,
    grid_cache_bytes: u64 = 1073741824,
    entity_cache_bytes: u64 = 67108864,

    sphere_size: u32 = 100,
    sphere_block: World.Block = .air,

    save_mode: World.WorldStorage.SaveMode = .only_modified,

    /// Player body extent in blocks. Width spans X and Z; height spans Y.
    player_width: f32 = 1.0,
    player_height: f32 = 4.0,
    /// Rise walked over automatically when a horizontal move is blocked.
    step_height: f32 = 1.0,
    /// Rate the body climbs a step, in blocks per second.
    step_climb_speed: f32 = 20.0,
    /// Peak jump height in blocks; converted to launch speed against gravity.
    jump_height: f32 = 1.6,
    /// Ground movement speed in blocks per second.
    move_speed: f32 = 8.0,
    /// Speed while the sprint key is held, as a multiple of `move_speed`. Clamped
    /// to at least 1 so the key can never slow the player down.
    sprint_multiplier: f32 = 1.6,
    /// Player inventory grid in slots, read when the player spawns. The first row is the hotbar.
    inventory_width: u32 = 10,
    inventory_height: u32 = 16,

    render_options: Renderer.RenderOptions = .{},

    pub const structui_options: dvui.struct_ui.StructOptions(@This()) = .initWithDefaults(.{
        .highest_level = .{ .number = .{ .display = .read_write, .min = 1, .max = 24, .widget_type = .slider } },
        .lowest_level = .{ .number = .{ .display = .none } },
        .render_distance_x = .{ .number = .{ .min = 6, .max = 32, .widget_type = .slider } },
        .mouse_sensitivity = .{ .number = .{ .min = 0, .max = 5, .widget_type = .slider } },
        .render_distance_y = .{ .number = .{ .min = 6, .max = 32, .widget_type = .slider } },
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

        const selection = try loadOptionalZon(GeneratorSelection, io, world_folder, "config/generator.zon", allocator);
        return .{
            .generator_name = selection.generator,
            .world_config = try utils.loadZon(World.WorldConfig, io, world_config_file, allocator, allocator),
            .spawn = try loadOptionalZon(EntityRegistry.SpawnConfig, io, world_folder, "config/Spawn.zon", allocator),
        };
    }

    /// Loads `sub_path`, or returns the type's defaults when the file does not exist.
    fn loadOptionalZon(comptime T: type, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, allocator: std.mem.Allocator) !T {
        const file = dir.openFile(io, sub_path, .{ .lock = .shared }) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        defer file.close(io);
        return utils.loadZon(T, io, file, allocator, allocator);
    }

    /// Writes the world options into the config directory of the given folder, creating missing files.
    pub fn save(self: WorldOptions, io: std.Io, folder: []const u8) !void {
        var world_folder = try std.Io.Dir.cwd().openDir(io, folder, .{});
        defer world_folder.close(io);

        world_folder.createDirPath(io, "config") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        try utils.saveZon(io, world_folder, "config/World.zon", self.world_config);
        try utils.saveZon(io, world_folder, "config/generator.zon", GeneratorSelection{ .generator = self.generator_name });
        try utils.saveZon(io, world_folder, "config/Spawn.zon", self.spawn);
    }
};

const GeneratorSelection = struct { generator: []const u8 = "Terrain" };

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

    const config_dir = try std.Io.Dir.path.join(allocator, &.{ folder, "config" });
    errdefer allocator.free(config_dir);

    const generator_config = try generator_plugin.loadConfig(allocator, io, config_dir);
    errdefer generator_api.free(allocator, generator_config);

    generator_plugin.api.config_set_seeds(&io, generator_config);

    const create_opts: generator_api.CreateOptions = .{ .allocator = allocator, .io = io, .max_cache_bytes = game.options.terrain_height_cache_bytes };
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

    const storage_path = try std.Io.Dir.path.joinZ(game.allocator, &.{ folder, "storage" });
    {
        defer game.allocator.free(storage_path);
        game.world_storage = try .init(storage_path, game.allocator, &game.options.save_mode, game_options_lock);
    }

    game.options_lock.lockSharedUncancelable(io);
    const chunk_cache_capacity = cacheCapacity(World.ChunkValue, @TypeOf(game.world.chunks).value_count_min, game.options.chunk_cache_bytes, "chunk");
    const chunk_grid_capacity = cacheCapacity(World.GridValue, @TypeOf(game.world.grids).value_count_min, game.options.grid_cache_bytes, "grid");
    const entity_cache_capacity = cacheCapacity(EntityRegistry.Entity, @TypeOf(game.entity_registry.map).value_count_min, game.options.entity_cache_bytes, "entity");
    game.options_lock.unlockShared(io);

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

    game.entity_registry = try .init(game.allocator, entity_cache_capacity);
    errdefer game.entity_registry.deinit(io, game.allocator, &game.world);

    game.spawn = world_options.spawn;
    const spawn_pos = try game.resolveSpawnPos(io, allocator, folder, &world_options);
    try game.spawnPlayer(io, allocator, spawn_pos);
}

/// Converts a byte budget into a power-of-two cache capacity of at least `min` values.
fn cacheCapacity(comptime V: type, min: u64, bytes: u64, name: []const u8) u64 {
    const capacity = @max(std.math.floorPowerOfTwo(u64, @max(1, bytes / @sizeOf(V))), min);
    std.log.info("Creating {s} cache with size {d} ({d} bytes)", .{ name, capacity, capacity * @sizeOf(V) });
    return capacity;
}

const spawn_scan_above: f64 = 512;
const spawn_scan_below: f64 = 1024;
const spawn_max_nudges: u32 = 8;
const spawn_rounds: u32 = 64;
// Attempt budgets double as search reach (rings advance per sample):
// phase 1 roams far for the canonical pick, phase 2 stays near home.
const spawn_phase1_attempts: u32 = 128;
const spawn_phase2_attempts: u32 = 64;

/// Clear vertical blocks a spawn column needs for a body of this height. The clamp
/// keeps the float-to-int cast defined for a config that names a negative height.
fn spawnRequiredAir(height: f32) u32 {
    return @max(1, @as(u32, @intFromFloat(@ceil(@max(height, 1.0)))));
}

const SpawnResolution = union(enum) { ok: @Vector(3, f64), ocean, no_ground, blocked };

/// Resolves one generator-proposed column to feet. The hint Y ignores erosion and structures, so scan down for solid ground with clear air above it.
fn resolveSpawnColumn(game: *@This(), io: std.Io, allocator: std.mem.Allocator, x: f64, z: f64, y_hint: f64) !SpawnResolution {
    const height: f64 = @floatCast(game.options.player_height);
    const half_height = height / 2;
    const required_air = spawnRequiredAir(game.options.player_height);
    const mover = Physics.Mover{ .bounding_box = Physics.Mover.boxFor(@floatCast(game.options.player_width), height) };
    var reader = World.Reader{ .world = &game.world };
    defer reader.clear(io);
    const bx: i64 = @intFromFloat(@round(x));
    const bz: i64 = @intFromFloat(@round(z));
    // Erosion shifts analytic estimates by hundreds of blocks, so scan a wide window. The first solid block from the top is the surface.
    var y: i64 = @intFromFloat(@floor(y_hint + spawn_scan_above));
    const bottom: i64 = @intFromFloat(@floor(y_hint - spawn_scan_below));
    var air_run: u32 = 0;
    var air_wet: u32 = 0;
    var saw_liquid = false;
    while (y >= bottom) : (y -= 1) {
        const block = try reader.getBlock(io, allocator, .{ bx, y, bz }, World.standard_level);
        // Only buoyant fluids read as open water; a leaf canopy must not reject a spawn.
        const liquid = if (block.fluidProperties()) |props| props.buoyancy > 0 else false;
        if (liquid) saw_liquid = true;
        if (!block.isSolid()) {
            air_run += 1;
            air_wet = (air_wet << 1 | @intFromBool(liquid)) & 0xf;
            continue;
        }
        if (air_run >= required_air) {
            if (air_wet != 0) return .ocean;
            // The box overlaps neighbor columns, so nudge up on slopes instead of rejecting the spot.
            var feet = @Vector(3, f64){ x, @as(f64, @floatFromInt(y)) + 0.5 + half_height + 0.01, z };
            for (0..spawn_max_nudges + 1) |_| {
                if (!try mover.collides(io, allocator, feet, &reader)) break;
                feet[1] += 1.0;
            } else return .blocked;
            return .{ .ok = feet };
        }
        air_run = 0;
        air_wet = 0;
    }
    return if (saw_liquid) .ocean else .no_ground;
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
/// Forgets the found spawn so the next world load searches again, and persists that.
pub fn resetSpawn(self: *@This(), io: std.Io) !void {
    self.spawn.pos = .{ 0, 0, 0 };
    self.spawn.found = false;
    var world_folder = try std.Io.Dir.cwd().openDir(io, self.world_path, .{});
    defer world_folder.close(io);
    try utils.saveZon(io, world_folder, "config/Spawn.zon", self.spawn);
}

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
    std.log.err("spawn phase 1 failed: all tested spawn locations blocked around {d:.1}, {d:.1}, {d:.1}", .{ game.spawn.center[0], game.spawn.center[1], game.spawn.center[2] });
    return error.GeneratorSpawnFailed;
}

fn stopBackgroundWork(self: *@This(), io: std.Io) void {
    self.running.store(false, .unordered);

    cancelFuture(io, &self.save_future);
    cancelFuture(io, &self.stream_future);
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
    self.streamer.deinit(self.allocator);
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
    const player_pos = self.player.body.pos;
    const view_direction = self.player.view_direction;
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

    self.player.body.pos = player_pos;
    self.player.view_direction = view_direction;
    self.publishPlayerBlock(io);
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

    try restartFutures(self, io);
    try self.startStreamPass(io, allocator);
    try startEntityDrain(self, io, allocator);
    // Apply any tuning edits before the body integrates this frame.
    self.player.applyTuning(self.playerTuning(io));
    // A menu gates gameplay input off, so no movement step replaced the velocity
    // this frame; zero the stale drift (Survival keeps Y so gravity still pulls).
    if (!self.input_handled) {
        const body = &self.player.body;
        body.velocity = if (self.player.game_mode == .Survival) @Vector(3, f64){ 0, body.velocity[1], 0 } else @as(@Vector(3, f64), @splat(0));
    }
    self.input_handled = false;
    // The player is updated synchronously every frame so the camera never waits
    // on the background drain.
    try self.updatePlayer(io, allocator, EntityRegistry.nowNs(io));
    self.publishPlayerBlock(io);
    asyncs.end();
    self.debug_menu.entities.store(self.entity_registry.count(), .unordered);
    const player_pos = self.player.body.pos;

    try self.renderer.draw(io, .{ .width = viewport[0], .height = viewport[1] }, frame_ctx, player_pos);

    self.debug_menu.opaque_drawn.store(self.vulkan_renderer.frame_stats.opaque_drawn, .unordered);
    self.debug_menu.transparent_drawn.store(self.vulkan_renderer.frame_stats.transparent_drawn, .unordered);
    self.debug_menu.occluded.store(self.vulkan_renderer.frame_stats.hiz_occluded, .unordered);
    self.debug_menu.frustum_culled.store(self.vulkan_renderer.frame_stats.frustum_culled, .unordered);
    self.debug_menu.opaque_faces.store(self.vulkan_renderer.frame_stats.opaque_faces, .unordered);
    self.debug_menu.transparent_faces.store(self.vulkan_renderer.frame_stats.transparent_faces, .unordered);

    try self.handleErrors();
}

fn restartFutures(self: *@This(), io: std.Io) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "restartFutures" });
    defer z.end();
    self.options_lock.lockSharedUncancelable(io);
    const save_frequency_ms = self.options.save_frequency_ms;
    self.options_lock.unlockShared(io);
    try restartFuture(io, &self.save_is_running, &self.last_save, &self.save_future, save_frequency_ms, saveFuture, .{ self, io });
}

/// How often a pass runs without finished tasks, which bounds how late streaming notices the player moving.
const stream_poll_ms = 16;

/// Starts a pass when none runs and tasks finished or the poll interval passed.
/// A pass is short-lived, so it never holds a worker the chunk loads need.
fn startStreamPass(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    if (self.stream_is_running.load(.seq_cst)) return;
    if (!self.running.load(.unordered)) return;
    const now: std.Io.Timestamp = .now(io, .awake);
    const due = self.last_stream.durationTo(now).toMilliseconds() >= stream_poll_ms;
    if (!due and !self.streamer.completions.pending.load(.acquire)) return;
    self.last_stream = now;
    try spawnTask(io, &self.stream_is_running, &self.stream_future, streamPass, .{ self, io, allocator });
}

/// The only caller of `streamer.pass`; `stream_is_running` keeps passes from overlapping.
fn streamPass(self: *@This(), io: std.Io, allocator: std.mem.Allocator) Io.Cancelable!void {
    defer self.stream_is_running.store(false, .seq_cst);
    const host: StreamHost = .{ .game = self, .allocator = allocator };
    self.options_lock.lockSharedUncancelable(io);
    const unload_interval_ms = self.options.mesh_unload_frequency_ms;
    self.options_lock.unlockShared(io);
    // A canceled pass would drop the completions it took, stranding their loads.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    self.streamer.pass(io, self.allocator, self.snapshotView(io), .now(io, .awake), unload_interval_ms, host) catch |err| return self.deferError(err);
    self.debug_menu.meshes.store(self.streamer.meshCount(), .unordered);
}

/// What the streamer needs from the game: chunk tasks and mesh removal.
const StreamHost = struct {
    game: *Game,
    allocator: std.mem.Allocator,

    pub fn dispatch(host: StreamHost, io: std.Io, request: ChunkStreamer.Request) void {
        host.game.groupAsync(io, streamChunk, .{ host.game, io, host.allocator, request });
    }

    pub fn removeMesh(host: StreamHost, io: std.Io, pos: World.ChunkPos) !void {
        return host.game.renderer.removeChunk(io, pos);
    }
};

fn restartFuture(
    io: std.Io,
    running: *std.atomic.Value(bool),
    last: *std.Io.Timestamp,
    future: anytype,
    frequency_ms: u64,
    comptime function: anytype,
    args: anytype,
) !void {
    if (running.load(.seq_cst)) return;
    if (last.durationTo(.now(io, .awake)).toMilliseconds() <= frequency_ms) return;
    last.* = .now(io, .awake);
    try spawnTask(io, running, future, function, args);
}

/// Reaps the finished previous pass and starts the next one with `running` set.
fn spawnTask(io: std.Io, running: *std.atomic.Value(bool), future: anytype, comptime function: anytype, args: anytype) !void {
    if (future.*) |*f| try f.await(io);
    running.store(true, .seq_cst);
    future.* = io.concurrent(function, args) catch io.async(function, args);
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
    self.entity_registry.drain(io, allocator, &self.world, EntityRegistry.nowNs(io)) catch |err| if (err != error.Canceled) return err;
}

/// Starts the drain when the previous pass finished, mirroring restartFuture
/// without a frequency gate: at most one drain runs, and a slow drain simply
/// skips frames instead of overlapping.
fn startEntityDrain(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    if (self.entity_update_is_running.load(.seq_cst)) return;
    // Never spawn into teardown; stopBackgroundWork owns shutdown from here.
    if (!self.running.load(.unordered)) return;
    try spawnTask(io, &self.entity_update_is_running, &self.entity_drain_future, updateEntities, .{ self, io, allocator });
}

/// Runs the player on the frame thread, outside the wheel.
fn updatePlayer(self: *@This(), io: std.Io, allocator: std.mem.Allocator, now_ns: u64) !void {
    // Cancellation is teardown, not a fault; every other update error is fatal.
    self.entity_registry.updateNow(io, allocator, &self.world, self.player_entity, now_ns) catch |err| if (err != error.Canceled) return err;
}

fn handleErrors(self: *@This()) !void {
    const err = @errorFromInt(self.deferred_error.swap(@intFromError(error.NoError), .seq_cst));
    std.debug.assert(err != error.Canceled);
    if (err != error.NoError) return err;
}

pub fn groupAsync(self: *Game, io: std.Io, function: anytype, args: anytype) void {
    const wrapper = struct {
        pub fn handler(game: *Game, fn_args: @TypeOf(args)) Io.Cancelable!void {
            @call(.always_inline, function, fn_args) catch |err| return game.deferError(err);
        }
    };
    self.group.async(io, wrapper.handler, .{ self, args });
}

/// Hands a background task's error to the next frame; cancellation passes through.
fn deferError(self: *Game, err: anyerror) Io.Cancelable!void {
    if (err == error.Canceled) return error.Canceled;
    const existing_error = self.deferred_error.cmpxchgStrong(@intFromError(error.NoError), @intFromError(err), .seq_cst, .seq_cst);
    if (existing_error) |er| std.log.err("{s}", .{@errorName(@errorFromInt(er))});
}

pub fn handleMouseMotion(self: *@This(), io: std.Io, mouse_motion: wio.Position) void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "handleMouseMotion" });
    defer z.end();
    const sensitivity = self.getMouseSensitivity(io);

    const view_dir_diff: @Vector(2, f32) = @Vector(2, f32){ mouse_motion.y, mouse_motion.x } * @as(@Vector(2, f32), @splat(sensitivity));

    const small_f32 = 0.00001;

    const view_direction = &self.player.view_direction;
    view_direction.* -= @Vector(3, f32){ view_dir_diff[0], view_dir_diff[1], 0 };
    view_direction[0] = std.math.clamp(view_direction[0], -90 + small_f32, 90 - small_f32);

    self.renderer.updateCameraDirection(view_direction.*);
}

pub fn handleScroll(self: *@This(), io: std.Io, scroll: f32) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "handleScroll" });
    defer z.end();
    self.options_lock.lockSharedUncancelable(io);
    const scroll_sensitivity = self.options.scroll_sensitivity;
    self.options_lock.unlockShared(io);
    switch (self.player.game_mode) {
        .Creative, .Spectator => self.player.fly_speed_linear -= scroll * scroll_sensitivity,
        .Survival => {},
    }
}

pub fn handleButtonActions(self: *Game, io: std.Io, actions: *const Key.ActionSet) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "handleButtonActions" });
    defer z.end();
    self.input_handled = true;
    switch (self.player.game_mode) {
        .Creative, .Spectator => self.flyMove(actions),
        .Survival => try self.walkMove(io, actions),
    }
    self.setSelectedSlot(actions);
    if (actions.contains(.spawn_explosive)) self.spawnExplosive(io) catch |err|
        std.log.err("error spawning explosive: {any}", .{err});
    const item = self.player.selectedItem() orelse return;
    self.options_lock.lockSharedUncancelable(io);
    const use: Item.UseContext = .{
        .actions = actions.*,
        .player_pos = self.player.body.pos,
        .looking = self.getCameraFront(),
        .sphere_size = self.options.sphere_size,
        .sphere_block = self.options.sphere_block,
    };
    self.options_lock.unlockShared(io);
    groupAsync(self, io, itemAction, .{ self, io, item, use });
}

fn setSelectedSlot(self: *@This(), actions: *const Key.ActionSet) void {
    const player = self.player;
    const inventory = &player.main_inventory;
    const first_hotbar = @backingInt(Key.Action.hotbar_key_0);
    const hotbar_key_count = 10;
    inline for (0..hotbar_key_count) |slot| {
        if (actions.contains(@fromBackingInt(@intCast(first_hotbar + slot)))) player.selectSlot(player.selected_row, @intCast(slot));
    }
    const row = player.selected_row;
    const col = player.selected_col;
    if (actions.contains(.hotbar_left)) player.selectSlot(row, if (col == 0) inventory.width - 1 else col - 1);
    if (actions.contains(.hotbar_right)) player.selectSlot(row, (col + 1) % inventory.width);
    if (actions.contains(.hotbar_up) or actions.contains(.hotbar_scroll_up)) player.selectSlot(if (row == 0) inventory.height - 1 else row - 1, col);
    if (actions.contains(.hotbar_down) or actions.contains(.hotbar_scroll_down)) player.selectSlot((row + 1) % inventory.height, col);
}

fn spawnExplosive(self: *@This(), io: std.Io) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "spawnExplosive" });
    defer z.end();
    const looking = self.getCameraFront();
    const spawn_distance: f64 = 2;
    const pos = self.player.body.pos + @as(@Vector(3, f64), @floatCast(looking)) * @as(@Vector(3, f64), @splat(spawn_distance));
    const entity = try self.entity_registry.spawn(io, self.allocator, &self.world, EntityTypes.Explosive.init(
        pos,
        looking,
        std.Io.Timestamp.now(io, .awake).toNanoseconds(),
    ), .{ .initial_delay_ms = 0 });
    entity.release();
}

/// Runs the selected hotbar item for one frame's inputs. Item behavior lives in
/// `Item.use`, so a raw click does nothing unless the matching tool is selected.
fn itemAction(self: *@This(), io: std.Io, item: Item.Item, use: Item.UseContext) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "itemAction" });
    defer z.end();
    var editor: World.Editor = .{ .world = &self.world, .temp_allocator = self.allocator };
    defer editor.clear();
    try item.use(&editor, use);
    try editor.flush(io, self.allocator);
}

/// Fly wish direction from held keys, one unit per held axis key.
fn wishDirection(camera_front: @Vector(3, f32), actions: *const Key.ActionSet) @Vector(3, f64) {
    var vel: @Vector(3, f64) = .{ 0, 0, 0 };
    if (actions.contains(.forward)) vel += @as(@Vector(3, f64), @floatCast(camera_front));
    if (actions.contains(.backward)) vel -= @as(@Vector(3, f64), @floatCast(camera_front));
    if (actions.contains(.up)) vel += .{ 0, 1, 0 };
    if (actions.contains(.down)) vel -= .{ 0, 1, 0 };
    const cross = zm.Vec3f.crossRH(.{ .data = camera_front }, .{ .data = Renderer.cameraUp });
    // Zero exactly when front is parallel to up, so strafe is undefined.
    if (cross.lenSq() > 0) {
        const r: @Vector(3, f64) = @floatCast(@as(@Vector(3, f32), cross.norm().data));
        if (actions.contains(.right)) vel += r;
        if (actions.contains(.left)) vel -= r;
    }
    return vel;
}

fn flyMove(self: *@This(), actions: *const Key.ActionSet) void {
    self.player.fly(wishDirection(self.getCameraFront(), actions));
}

fn walkMove(self: *@This(), io: std.Io, actions: *const Key.ActionSet) !void {
    const now = std.Io.Timestamp.now(io, .awake);
    try self.player.walk(io, self.allocator, &self.world, .{
        .wish = wishDirectionHorizontal(self.player.view_direction, actions),
        .sprint = actions.contains(.sprint),
        .jump = actions.contains(.up),
        .elapsed_ns = @intCast(@max(self.last_frametime.durationTo(now).nanoseconds, 0)),
        .tuning = self.playerTuning(io),
    });
}

/// Unit horizontal wish from yaw only, so looking up or down never scales walking.
fn wishDirectionHorizontal(view_direction: @Vector(3, f32), actions: *const Key.ActionSet) @Vector(2, f64) {
    const yaw = std.math.degreesToRadians(view_direction[1]);
    const forward: @Vector(2, f64) = .{ @sin(yaw), @cos(yaw) };
    const right: @Vector(2, f64) = .{ -forward[1], forward[0] };
    var wish: @Vector(2, f64) = .{ 0, 0 };
    if (actions.contains(.forward)) wish += forward;
    if (actions.contains(.backward)) wish -= forward;
    if (actions.contains(.right)) wish += right;
    if (actions.contains(.left)) wish -= right;
    const length = @sqrt(@reduce(.Add, wish * wish));
    return if (length > 0) wish / @as(@Vector(2, f64), @splat(length)) else wish;
}

/// The tunable body size, movement, step, and jump from the options.
fn playerTuning(self: *@This(), io: std.Io) EntityTypes.Player.Tuning {
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return .{
        .width = self.options.player_width,
        .height = self.options.player_height,
        .step_height = self.options.step_height,
        .step_climb_speed = self.options.step_climb_speed,
        .jump_height = self.options.jump_height,
        .walk_speed = self.options.move_speed,
        .sprint_multiplier = self.options.sprint_multiplier,
    };
}

fn getCameraFront(self: *@This()) @Vector(3, f32) {
    return Renderer.cameraFrontFromViewDirection(self.player.view_direction);
}

/// Publishes the block holding the player, the integer origin every chunk-window computation shares.
fn publishPlayerBlock(self: *@This(), io: std.Io) void {
    self.player_block_mutex.lockUncancelable(io);
    defer self.player_block_mutex.unlock(io);
    self.player_block = @intFromFloat(@floor(self.player.body.pos));
}

/// The last published player block; safe from any task.
fn playerBlock(self: *@This(), io: std.Io) World.BlockPos {
    self.player_block_mutex.lockUncancelable(io);
    defer self.player_block_mutex.unlock(io);
    return self.player_block;
}

fn snapshotView(self: *@This(), io: std.Io) ChunkStreamer.View {
    const player_block = self.playerBlock(io);
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return .{ .player_block = player_block, .settings = .{
        .lowest_level = self.options.lowest_level,
        .highest_level = self.options.highest_level,
        .render_distance = .{ self.options.render_distance_x, self.options.render_distance_y },
        .lod_overlap = self.options.lod_overlap,
    } };
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

/// Runs one streamer request and always reports it back, so a canceled or failed
/// task never strands the chunk as loading.
fn streamChunk(self: *@This(), io: std.Io, allocator: std.mem.Allocator, request: ChunkStreamer.Request) !void {
    var meshed = false;
    defer self.streamer.completions.push(io, .{ .pos = request.pos, .kind = request.kind, .meshed = meshed });
    switch (request.kind) {
        // The task may start long after it was queued, so skip a chunk the player has left.
        .load => |settings| {
            const view: ChunkStreamer.View = .{ .settings = settings, .player_block = self.playerBlock(io) };
            if (!view.keeps(request.pos)) return;
        },
        .remesh => {},
    }
    try self.meshChunk(io, allocator, request.pos, request.kind == .load);
    meshed = true;
}

/// Generates a missing chunk and its neighbors, then adds or replaces its mesh.
fn meshChunk(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: World.ChunkPos, generate_structures: bool) !void {
    const gen_mesh_add = tracy.Zone.begin(.{ .src = @src(), .name = "GenMeshAndAdd" });
    defer gen_mesh_add.end();
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
}

fn remesh(game: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: World.ChunkPos) !void {
    try game.streamer.completions.reserve(io, game.allocator, 1);
    try game.streamChunk(io, allocator, .{ .pos = chunk_pos, .kind = .remesh });
}

fn editorCallback(io: std.Io, allocator: std.mem.Allocator, chunk_pos: World.ChunkPos, args: *anyopaque) !void {
    const game: *@This() = @ptrCast(@alignCast(args));
    // Remesh even outside the keep set, or a lingering or detached mesh keeps showing pre-edit blocks; the streamer drops a mesh nothing needs.
    // Levels outside the streamed range hold no meshes, and edits propagate past them.
    const settings = game.snapshotView(io).settings;
    if (chunk_pos.level < settings.lowest_level or chunk_pos.level > settings.highest_level) return;
    // A transient remesh failure leaves the edited chunk active but unmessed until the
    // next edit; log it and continue. A storage-level Unrecoverable still aborts.
    remesh(game, io, allocator, chunk_pos) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Unrecoverable => {
            std.log.err("remesh after edit failed at {any}: {any}", .{ chunk_pos, err });
            return error.OnEditFailed;
        },
        else => |e| std.log.err("remesh after edit failed at {any}: {any}", .{ chunk_pos, e }),
    };
}

fn spawnPlayer(game: *@This(), io: std.Io, allocator: std.mem.Allocator, spawn_pos: @Vector(3, f64)) !void {
    const z: tracy.Zone = .begin(.{ .src = @src(), .name = "spawnPlayer" });
    defer z.end();
    var inventory: Item.Inventory = try .init(allocator, @max(game.options.inventory_width, 1), @max(game.options.inventory_height, 1));
    errdefer inventory.deinit(allocator);
    fillStarterRow(&inventory);
    const player_entity = try game.entity_registry.spawn(io, allocator, &game.world, EntityTypes.Player{
        .body = .{
            .pos = spawn_pos,
            .mover = .{ .bounding_box = Physics.Mover.boxFor(@floatCast(game.options.player_width), @floatCast(game.options.player_height)) },
            .last_update = .now(io, .awake),
        },
        .game_mode = game.spawn.mode,
        .view_direction = .{ 0.0001, -0.4, 0.001 },
        .main_inventory = inventory,
    }, .{});
    game.player_entity = player_entity;
    // The held reference keeps the player resident; the frame lane drives it.
    game.player = @ptrCast(@alignCast(player_entity.ptr));
    game.publishPlayerBlock(io);
    game.renderer.updateCameraDirection(game.player.view_direction);
}

/// Placeholder starter row so the hotbar has icons to show; real item grants come
/// later. Tool items get slots first, so block items are capped to fit the row.
fn fillStarterRow(inventory: *Item.Inventory) void {
    const tools = Item.extra_item_types[0..@min(Item.extra_item_types.len, inventory.width)];
    const block_slots = @min(Item.block_types.len, inventory.width - tools.len);
    for (Item.block_types[0..block_slots], 0..) |block, col| {
        inventory.set(0, @intCast(col), .{ .item_type = Item.fromBlock(block).?, .amount = 1 });
    }
    for (tools, block_slots..) |item_type, col| {
        inventory.set(0, @intCast(col), .{ .item_type = item_type, .amount = 1 });
    }
}
