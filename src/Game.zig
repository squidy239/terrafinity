const std = @import("std");

const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const dvui = @import("dvui");
const gl = @import("gl");
const tracy = @import("tracy");
const wio = @import("wio");
const zm = @import("zm");

const Key = @import("Key.zig");
const utils = @import("libs/utils.zig");
const Mesher = @import("Mesher.zig");
pub const Renderer = @import("Renderer.zig");
const Chunk = @import("world/Chunk.zig");
const Entity = @import("world/Entity.zig");
const EntityTypes = @import("world/EntityTypes.zig");
const World = @import("world/World.zig");

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

selected_inventory_row: std.atomic.Value(u32) = .init(0),
selected_inventory_col: std.atomic.Value(u32) = .init(0),

last_chunk_load: std.Io.Timestamp = .zero,
chunk_load_is_running: std.atomic.Value(bool) = .init(false),
load_future: ?std.Io.Future(@typeInfo(@TypeOf(loadChunks)).@"fn".return_type.?) = null,

last_mesh_unload: std.Io.Timestamp = .zero,
mesh_unload_is_running: std.atomic.Value(bool) = .init(false),
mesh_unload_future: ?std.Io.Future(@typeInfo(@TypeOf(unloadChunkMeshes)).@"fn".return_type.?) = null,

select: std.Io.Select(SelectUnion),
select_buffer: [65536]SelectUnion = undefined,

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

    {
        const bucket = self.loaded_or_meshed.getBucket(parent);
        try bucket.lock.lock(io);
        defer bucket.lock.unlock(io);
        var state: Game.NodeData = bucket.hash_map.get(parent) orelse .{};
        state.covered_children[pos_in_parent[0]][pos_in_parent[1]][pos_in_parent[2]] = true;
        
        try bucket.hash_map.put(allocator, parent, state);
        const mark_parent_covered = state.allCoveredChildren() or state.is_active;
        if(!mark_parent_covered) return;
    }
    try self.markCovered(io, allocator, parent);
}

fn markUncovered(self: *@This(), io: std.Io, allocator: std.mem.Allocator, pos: World.ChunkPos) !void {
    _, const highest = self.getLevels(io);
    const parent = pos.parent();
    const pos_in_parent = pos.posInParent();
    if (parent.level > highest) return;
    {
        const bucket = self.loaded_or_meshed.getBucket(parent);
        try bucket.lock.lock(io);
        defer bucket.lock.unlock(io);
        var state = bucket.hash_map.get(parent) orelse return;
        state.covered_children[pos_in_parent[0]][pos_in_parent[1]][pos_in_parent[2]] = false;
        const remove_node = state.noCoveredChildren() and !state.is_active and !state.is_queued;
        if (remove_node) {
            _ = bucket.hash_map.remove(parent);
            //now mark uncovered out of this block
        } else {
            try bucket.hash_map.put(allocator, parent, state);
        }
        const mark_parent_uncovered = state.allCoveredChildren() and !state.is_active;
        if(!mark_parent_uncovered) return;
    }
    try self.markUncovered(io, allocator, parent);
}

fn canUnloadMesh(self: *@This(), io: std.Io, chunk_pos: World.ChunkPos) bool {
    const parent = chunk_pos.parent();
    if (self.loaded_or_meshed.get(io, parent)) |par| {//TODO handle top level out of range
        if (par.is_active) return true;
    }
    const bucket = self.loaded_or_meshed.getBucket(chunk_pos);
    bucket.lock.lockSharedUncancelable(io);
    defer bucket.lock.unlockShared(io);
    const state = bucket.hash_map.get(chunk_pos) orelse return false;
    return state.allCoveredChildren();
}

fn removeChunkFromLoaded(
    self: *@This(),
    io: std.Io,
    allocator: std.mem.Allocator,
    chunk_pos: World.ChunkPos,
) !void {
    const bucket = self.loaded_or_meshed.getBucket(chunk_pos);
    try bucket.lock.lock(io);
    var state = bucket.hash_map.get(chunk_pos) orelse {
        bucket.lock.unlock(io);
        return;
    };

    const was_active = state.is_active;
    const was_queued = state.is_queued;

    // Only return if it's a completely dead ghost node
    if (!was_active and !was_queued) {
        std.debug.assert(!state.noCoveredChildren());
        bucket.lock.unlock(io);
        return;
    }

    state.is_active = false;
    state.is_queued = false;

    if (state.noCoveredChildren()) {
        _ = bucket.hash_map.remove(chunk_pos); // ghost with nothing to track
    } else {
        try bucket.hash_map.put(allocator, chunk_pos, state);
    }
    bucket.lock.unlock(io);

    if (state.noCoveredChildren()) {
        try self.markUncovered(io, allocator, chunk_pos);
    }
}

const SelectUnion = union(enum) {
    addChunkToRender: @typeInfo(@TypeOf(addChunkToRender)).@"fn".return_type.?,
};

pub const Options = struct {
    mouse_sensitivity: f32 = 0.5,
    scroll_sensitivity: f32 = 0.1,

    lowest_level: i32 = 0,
    highest_level: i32 = 10,

    generation_distance_x: u32 = 8,
    generation_distance_y: u32 = 6,

    loader_frequency_ms: u64 = 250,
    terrain_height_cache_bytes: u64 = 268435456,
    chunk_cache_bytes: u64 = 1073741824,
    grid_cache_bytes: u64 = 1073741824,

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
        .generation_distance_x = .{ .number = .{
            .min = 6,
            .max = 32,
            .widget_type = .slider,
        } },
        .mouse_sensitivity = .{ .number = .{
            .min = 0,
            .max = 5,
            .widget_type = .slider,
        } },
        .generation_distance_y = .{ .number = .{
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

        const worldConfigFile = try world_folder.openFile(io, "config/World.zon", .{ .lock = .shared });
        defer worldConfigFile.close(io);

        const generatorConfigFile = try world_folder.openFile(io, "config/DefaultGenerator.zon", .{ .lock = .shared });
        defer generatorConfigFile.close(io);

        var generator_config = try utils.loadZON(World.DefaultGenerator.Params, io, generatorConfigFile, allocator, allocator);
        generator_config.setSeeds(io);
        return .{
            .generator_config = generator_config,
            .world_config = try utils.loadZON(World.WorldConfig, io, worldConfigFile, allocator, allocator),
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

        const worldConfigFile = try world_folder.createFile(io, "config/World.zon", .{ .lock = .exclusive });
        defer worldConfigFile.close(io);

        var worldconfwriter = worldConfigFile.writer(io, &wbuffer);

        const generatorConfigFile = try world_folder.createFile(io, "config/DefaultGenerator.zon", .{ .lock = .exclusive });
        defer generatorConfigFile.close(io);

        var generatorconfwriter = generatorConfigFile.writer(io, &gbuffer);

        try std.zon.stringify.serialize(self.world_config, .{}, &worldconfwriter.interface);
        try std.zon.stringify.serialize(self.generator_config, .{}, &generatorconfwriter.interface);

        try worldconfwriter.end();
        try generatorconfwriter.end();
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
        .select = .init(io, &game.select_buffer),
        .running = .init(true),
        .allocator = undefined,
        .opengl_renderer = undefined,
        .renderer = undefined,
        .generator = undefined,
        .loaded_or_meshed = .init,
        .world_storage = undefined,
        .world = undefined,
        .player = undefined,
    };

    try game.opengl_renderer.init(io, allocator, window, gl_options, share_context, proc_table);
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
    errdefer game.generator.terrain_height_cache.deinit(allocator);

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
        .onEdit = .{
            .onEditFn = onEditFn,
            .onEditFnArgs = @ptrCast(game),
            .callIfNeighborFacesChanged = true,
        },
    };
    errdefer game.world.deinit(io, allocator);

    try game.spawnPlayer(io, allocator);
}

pub fn deinit(self: *@This(), io: std.Io) void {
    self.running.store(false, .monotonic);

    self.select.cancelDiscard(); // This must be called first to close the queue or it could hang
    if (self.load_future) |*future| future.cancel(io) catch {};
    self.select.cancelDiscard();
    if (self.mesh_unload_future) |*future| future.cancel(io) catch {};

    self.opengl_renderer.deinit(io);
    self.loaded_or_meshed.deinit(io, self.allocator);
    self.world.deinit(io, self.allocator);

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

    var entitys_future = io.async(World.updateEntitys, .{ &self.world, io, allocator });
    defer entitys_future.cancel(io) catch {};
    try updateLoadAndUnload(self, io, allocator);

    self.player.physics.mutex.lockUncancelable(io);
    const player_pos = self.player.physics.pos;
    self.player.physics.mutex.unlock(io);

    try self.renderer.clear(player_pos);
    try self.player.physics.update(&self.world, io, allocator);

    self.player.physics.mutex.lockUncancelable(io);
    const player_pos_updated = self.player.physics.pos;
    self.player.physics.mutex.unlock(io);

    try self.renderer.drawChunks(io, player_pos_updated);
    try self.handleSelectFutures();
    try entitys_future.await(io);
}

fn updateLoadAndUnload(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    self.options_lock.lockSharedUncancelable(io);
    const loader_frequency_ms = self.options.loader_frequency_ms;
    self.options_lock.unlockShared(io);

    if (!self.chunk_load_is_running.load(.seq_cst) and self.last_chunk_load.durationTo(.now(io, .awake)).toMilliseconds() > loader_frequency_ms) {
        if (self.load_future) |*f| try f.await(io);

        self.chunk_load_is_running.store(true, .seq_cst);
        self.last_chunk_load = .now(io, .awake);
        //this requires concurrency incase the Select buffer is full.
        //it catches becuase that is unlikely and I want it to work in single threaded mode.
        //TODO find a way to make it safely async
        self.load_future = io.concurrent(loadChunks, .{ self, io, allocator }) catch io.async(loadChunks, .{ self, io, allocator });
    }

    if (!self.mesh_unload_is_running.load(.seq_cst) and self.last_mesh_unload.durationTo(.now(io, .awake)).toMilliseconds() > loader_frequency_ms) {
        if (self.mesh_unload_future) |*f| try f.await(io);

        self.mesh_unload_is_running.store(true, .seq_cst);
        self.last_mesh_unload = .now(io, .awake);
        self.mesh_unload_future = io.async(unloadChunkMeshes, .{ self, io });
    }
}

fn handleSelectFutures(self: *@This()) !void {
    var select_completion_buffer: [1024]SelectUnion = undefined;
    while (true) {
        const completed = try self.select.awaitMany(&select_completion_buffer, 0);
        if (completed == 0) break;
        for (select_completion_buffer[0..completed]) |completed_union| {
            switch (completed_union) {
                .addChunkToRender => |f| try f,
            }
        }
    }
}

pub fn handleMouseMotion(self: *@This(), io: std.Io, mouse_motion: wio.RelativePosition) void {
    const sensitivity = self.getMouseSensitivity(io);

    var viewDirDiff: @Vector(2, f32) = @splat(0);
    viewDirDiff += @Vector(2, f32){ mouse_motion.y, mouse_motion.x };
    viewDirDiff *= @splat(sensitivity);

    const smallf32 = 0.00001;

    self.player.viewDirection_mutex.lockUncancelable(io);
    defer self.player.viewDirection_mutex.unlock(io);
    var currentViewDir = self.player.viewDirection;
    currentViewDir -= @Vector(3, f32){ viewDirDiff[0], viewDirDiff[1], 0 };
    currentViewDir[0] = std.math.clamp(currentViewDir[0], -90 + smallf32, 90 - smallf32);
    self.player.viewDirection = currentViewDir;

    self.renderer.updateCameraDirection(currentViewDir);
}

pub fn handleScroll(self: *@This(), io: std.Io, scroll: f32) !void {
    self.options_lock.lockSharedUncancelable(io);
    const scroll_sensitivity = self.options.scroll_sensitivity;
    self.options_lock.unlockShared(io);
    switch (self.player.gameMode.load(.seq_cst)) {
        .Creative, .Spectator => {
            const fsl = self.player.fly_speed_linear.fetchAdd(-scroll * scroll_sensitivity, .seq_cst);
            _ = self.player.fly_speed.store(@min(@as(f32, @floatFromInt(std.math.maxInt(i32))), std.math.pow(f32, 2, fsl)), .seq_cst);
        },
        .Survival => {},
    }
}

pub fn handleButtonActions(self: *@This(), io: std.Io, actions: *const Key.ActionSet, delta_time: std.Io.Duration) !void {
    const delta_time_seconds = @as(f32, @floatFromInt(delta_time.toNanoseconds())) / std.time.ns_per_s;

    switch (self.player.gameMode.load(.unordered)) {
        .Creative, .Spectator => try self.flyMove(io, actions, delta_time_seconds),
        .Survival => try self.walkMove(io, actions, delta_time_seconds),
    }
    self.setSelectedSlot(actions);
    try self.itemAction(io, actions);
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

fn itemAction(self: *@This(), io: std.Io, actions: *const Key.ActionSet) !void {
    if (actions.contains(.use_item_primary)) {
        self.player.physics.mutex.lockUncancelable(io);
        const ppos = self.player.physics.pos;
        self.player.physics.mutex.unlock(io);
        try self.world.spawnEntity(io, self.allocator, null, EntityTypes.Explosive{
            .pos = ppos,
            .dir = @splat(0),
            .timestamp = .init(std.Io.Timestamp.now(io, .awake).toNanoseconds()),
        }, false);
    }
}

fn flyMove(self: *@This(), io: std.Io, actions: *const Key.ActionSet, delta_time_seconds: f32) !void {
    const cameraFront = self.renderer.getCameraFront();
    const veldiff: @Vector(3, f32) = @splat(self.player.fly_speed.load(.unordered) * delta_time_seconds);
    const c = zm.Vec3f.crossRH(.{ .data = cameraFront }, .{ .data = Renderer.OpenGl.cameraUp });
    const cross = if (std.meta.eql(c.data, @Vector(3, f64){ 0, 0, 0 })) null else c.norm();

    self.player.physics.mutex.lockUncancelable(io);
    defer self.player.physics.mutex.unlock(io);
    if (actions.contains(.forward)) self.player.physics.velocity += @as(@Vector(3, f64), @floatCast(veldiff * cameraFront));
    if (actions.contains(.backward)) self.player.physics.velocity += @as(@Vector(3, f64), @floatCast(-veldiff * cameraFront));
    if (actions.contains(.up)) self.player.physics.velocity += @Vector(3, f64){ 0, @floatCast(veldiff[1]), 0 };
    if (actions.contains(.down)) self.player.physics.velocity += @Vector(3, f64){ 0, @floatCast(-veldiff[1]), 0 };
    if (actions.contains(.right) and cross != null) self.player.physics.velocity += @as(@Vector(3, f64), @floatCast(veldiff * cross.?.data));
    if (actions.contains(.left) and cross != null) self.player.physics.velocity += @as(@Vector(3, f64), @floatCast(-veldiff * cross.?.data));
}

fn walkMove(self: *@This(), io: std.Io, actions: *const Key.ActionSet, delta_time_seconds: f32) !void {
    const cameraFront = self.renderer.getCameraFront();
    const veldiff: @Vector(3, f32) = @splat(self.player.fly_speed.load(.unordered) * delta_time_seconds);
    const c = zm.Vec3f.crossRH(.{ .data = cameraFront }, .{ .data = Renderer.OpenGl.cameraUp });
    const cross = if (std.meta.eql(c.data, @Vector(3, f64){ 0, 0, 0 })) null else c.norm();
    var block_reader: World.Reader = .{ .world = &self.world };
    defer block_reader.clear(io);

    self.player.physics.mutex.lockUncancelable(io);
    const player_pos = self.player.physics.pos;
    self.player.physics.mutex.unlock(io);

    if (try self.player.physics.elements.mover.collision(io, self.allocator, player_pos, &block_reader)) |_| {
        block_reader.clear(io);
        self.player.physics.mutex.lockUncancelable(io);
        defer self.player.physics.mutex.unlock(io);
        if (actions.contains(.up)) self.player.physics.velocity += @Vector(3, f64){ 0, @floatCast(veldiff[1]), 0 };
        if (actions.contains(.down)) self.player.physics.velocity += @Vector(3, f64){ 0, @floatCast(-veldiff[1]), 0 };
        if (actions.contains(.forward)) self.player.physics.velocity += @as(@Vector(3, f64), @floatCast(veldiff * cameraFront));
        if (actions.contains(.backward)) self.player.physics.velocity += @as(@Vector(3, f64), @floatCast(-veldiff * cameraFront));
        if (actions.contains(.right) and cross != null) self.player.physics.velocity += @as(@Vector(3, f64), @floatCast(veldiff * cross.?.data));
        if (actions.contains(.left) and cross != null) self.player.physics.velocity += @as(@Vector(3, f64), @floatCast(-veldiff * cross.?.data));
    }
}

pub fn getLevels(self: *@This(), io: std.Io) struct { i32, i32 } {
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return .{ self.options.lowest_level, self.options.highest_level };
}

fn getGenDistance(self: *@This(), io: std.Io) @Vector(2, u32) {
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return .{ self.options.generation_distance_x, self.options.generation_distance_y };
}

fn getInnerGenRadius(self: *@This(), io: std.Io, gendistance: @Vector(2, u32), level: i32) @Vector(2, u32) {
    if (level <= (self.getLevels(io))[0]) return @splat(0);
    const inner_radius = gendistance / @Vector(2, u32){ World.scale_factor, World.scale_factor };
    return inner_radius -| @Vector(2, u32){ 1, 1 };
}

fn getMouseSensitivity(self: *@This(), io: std.Io) f32 {
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return self.options.mouse_sensitivity;
}

/// Adds a chunk to the render list replacing it if it already exists, generates it or its neighbors if it doesn't exist.
fn addChunkToRender(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: World.ChunkPos, genStructures: bool) !void {
    const GenMeshAndAdd = tracy.Zone.begin(.{ .src = @src(), .name = "GenMeshAndAdd" });
    defer GenMeshAndAdd.end();

    // Prevent an old version of the chunk from staying loaded
    if (!self.keepChunkLoaded(io, chunk_pos)) {
        self.renderer.removeChunk(io, chunk_pos);
        try self.removeChunkFromLoaded(io, self.allocator, chunk_pos);
        return;
    }

    const chunk = try self.world.loadChunk(io, allocator, chunk_pos, genStructures);
    defer chunk.release();
    const neighbor_faces = [6]Chunk.Encoding.Face{
        try (try self.world.loadChunk(io, allocator, chunk_pos.add(.{ 1, 0, 0 }), false)).extractFace(io, .xminus, true),
        try (try self.world.loadChunk(io, allocator, chunk_pos.add(.{ -1, 0, 0 }), false)).extractFace(io, .xplus, true),
        try (try self.world.loadChunk(io, allocator, chunk_pos.add(.{ 0, 1, 0 }), false)).extractFace(io, .yminus, true),
        try (try self.world.loadChunk(io, allocator, chunk_pos.add(.{ 0, -1, 0 }), false)).extractFace(io, .yplus, true),
        try (try self.world.loadChunk(io, allocator, chunk_pos.add(.{ 0, 0, 1 }), false)).extractFace(io, .zminus, true),
        try (try self.world.loadChunk(io, allocator, chunk_pos.add(.{ 0, 0, -1 }), false)).extractFace(io, .zplus, true),
    };

    var sfa = std.heap.stackFallback(65536, self.allocator);
    const fallback_allocator = sfa.get();
    var opaque_faces: std.ArrayList(Mesher.Face) = .empty;
    defer opaque_faces.deinit(fallback_allocator);
    var transparent_faces: std.ArrayList(Mesher.Face) = .empty;
    defer transparent_faces.deinit(fallback_allocator);
    {
        try chunk.lockShared(io);
        defer chunk.unlockShared(io);
        try Mesher.mesh(
            fallback_allocator,
            chunk.encoding,
            &neighbor_faces,
            &opaque_faces,
            &transparent_faces,
        );
    }
    if (opaque_faces.items.len > 0 or transparent_faces.items.len > 0) {
        try self.renderer.addChunk(io, chunk_pos, opaque_faces.items, transparent_faces.items);
    }

    var was_active = false;
    {
        const bucket = self.loaded_or_meshed.getBucket(chunk_pos);
        try bucket.lock.lock(io);
        defer bucket.lock.unlock(io);
        var state: NodeData = bucket.hash_map.get(chunk_pos) orelse .{};
        was_active = state.is_active;
        state.is_active = true;
        state.is_queued = false;
        try bucket.hash_map.put(allocator, chunk_pos, state);
    }

    if (!was_active) {
        try self.markCovered(io, allocator, chunk_pos);
    }
}

fn addChunkToRenderAsync(self: *@This(), io: std.Io, allocator: std.mem.Allocator, chunk_pos: World.ChunkPos, genStructures: bool) !void {
    var was_active = false;
    {
        const bucket = self.loaded_or_meshed.getBucket(chunk_pos);
        try bucket.lock.lock(io);
        defer bucket.lock.unlock(io);
        const entry = try bucket.hash_map.getOrPutValue(allocator, chunk_pos, .{});
        was_active = entry.value_ptr.is_active;
        entry.value_ptr.is_queued = true;
    }

    self.select.async(.addChunkToRender, addChunkToRender, .{ self, io, allocator, chunk_pos, genStructures });
}

fn onEditFn(io: std.Io, allocator: std.mem.Allocator, chunkPos: World.ChunkPos, args: *anyopaque) !void {
    const game: *@This() = @ptrCast(@alignCast(args));
    game.addChunkToRender(io, allocator, chunkPos, false) catch return error.OnEditFailed;
}

fn keepChunkLoaded(self: *@This(), io: std.Io, chunk_pos: World.ChunkPos) bool {
    const lowest_level, const highest_level = self.getLevels(io);
    self.player.physics.mutex.lockUncancelable(io);
    const playerpos = self.player.physics.pos;
    self.player.physics.mutex.unlock(io);
    const gendistance = self.getGenDistance(io);
    const innergenradius = self.getInnerGenRadius(io, gendistance, chunk_pos.level);
    const inside_range = keepLoaded(lowest_level, highest_level, playerpos, chunk_pos, innergenradius, gendistance);
    return inside_range;
}

fn keepLoaded(lowest_level: ?i32, highest_level: ?i32, playerPos: @Vector(3, f64), chunk_pos: World.ChunkPos, innerChunkRange: ?@Vector(2, u32), outerChunkRange: ?@Vector(2, u32)) bool {
    if (lowest_level) |l| {
        if (chunk_pos.level < l) return false;
    }
    if (highest_level) |h| {
        if (chunk_pos.level > h) return false;
    }

    const player_chunk_pos = @trunc(playerPos / @as(@Vector(3, f64), @splat(World.ChunkPos.levelToBlockRatioFloat(chunk_pos.level))));
    const chunk_center: @Vector(3, f64) = chunk_pos.position;

    if (innerChunkRange) |icr| {
        const inner: @Vector(3, f64) = .{ icr[0], icr[1], icr[0] };
        const insideInner =
            @reduce(.And, player_chunk_pos > (chunk_center - inner)) and
            @reduce(.And, player_chunk_pos < chunk_center + inner);
        if (insideInner) return false;
    }

    if (outerChunkRange) |ocr| {
        const outer: @Vector(3, f64) = .{ ocr[0], ocr[1], ocr[0] };
        const outsideOuter =
            @reduce(.Or, player_chunk_pos < chunk_center - outer) or
            @reduce(.Or, player_chunk_pos > chunk_center + outer);
        if (outsideOuter) return false;
    }
    return true;
}

///Loads all chunks in gendistance and unloads all chunks out of loadistance
fn loadChunks(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    defer self.chunk_load_is_running.store(false, .seq_cst);
    self.player.physics.mutex.lockUncancelable(io);
    const playerPos = self.player.physics.pos;
    self.player.physics.mutex.unlock(io);
    const addChunkstoLoad = tracy.Zone.begin(.{ .src = @src(), .name = "addChunksToLoad" });

    var levels = self.getLevels(io);
    var level = levels[0];
    var amount_loaded: u64 = 0;
    while (level < levels[1]) : (level += 1) {
        levels = self.getLevels(io);
        amount_loaded += try loadChunksSpiral(self, io, allocator, playerPos, level);
    }
    addChunkstoLoad.end();
}

///loads chunks from top to bottom and in a spiral on a y level
fn loadChunksSpiral(game: *@This(), io: std.Io, allocator: std.mem.Allocator, playerPos: @Vector(3, f64), level: i32) !u64 {
    const playerChunkPos = World.ChunkPos.fromGlobalBlockPos(@trunc(playerPos), level);

    var outer_radius = game.getGenDistance(io);
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
            outer_radius = game.getGenDistance(io);
            inner_radius = game.getInnerGenRadius(io, outer_radius, level);
            while (y < outer_radius[1]) {
                defer y += 1;
                const chunk_pos: World.ChunkPos = .{ .position = [3]i32{ xz[0] + playerChunkPos.position[0], y + playerChunkPos.position[1], xz[1] + playerChunkPos.position[2] }, .level = level };

                const in_range = keepLoaded(null, null, playerPos, chunk_pos, inner_radius, outer_radius);
                if (!in_range)
                    continue;

                const node_data = game.loaded_or_meshed.get(io, chunk_pos);

                if (node_data == null or (!node_data.?.is_active and !node_data.?.is_queued)) {
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

    const chunkCollector = struct {
        game: *Game,
        io: std.Io,
        chunks: u64 = 0,
        unloaded: u64 = 0,

        pub fn callback(userdata: *anyopaque, chunk_pos: World.ChunkPos) void {
            const ctx: *@This() = @ptrCast(@alignCast(userdata));
            ctx.chunks += 1;
            if (ctx.game.keepChunkLoaded(ctx.io, chunk_pos)) return;
            if (!ctx.game.canUnloadMesh(ctx.io, chunk_pos)) return; // children not ready

            ctx.game.removeChunkFromLoaded(ctx.io, ctx.game.allocator, chunk_pos) catch @panic("TODO figure out how to handle this");
            ctx.game.renderer.removeChunk(ctx.io, chunk_pos);
            ctx.unloaded += 1;
        }
    };
    var ctx = chunkCollector{
        .game = self,
        .io = io,
    };

    try self.renderer.forEachChunk(io, &ctx, chunkCollector.callback);
    self.debug_menu.meshes.store(ctx.chunks, .unordered);

    var it = self.loaded_or_meshed.iterator();
    defer it.deinit(io);
    while (try it.next(io)) |entry| {
        const key = entry.key_ptr.*;
        if (self.keepChunkLoaded(io, key)) continue;
        if (!entry.value_ptr.is_active and !entry.value_ptr.is_queued) continue;

        it.pause(io);
        self.removeChunkFromLoaded(io, self.allocator, key) catch @panic("TODO handle error");
        try it.unpause(io);
    }
}

fn spawnPlayer(game: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    const playerentity = try game.world.spawnEntity(io, allocator, null, EntityTypes.Player{
        .player_name = .fromString("squid"),
        .fly_speed = .init(100),
        .fly_speed_linear = .init(10),
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
            .pos = try game.world.getPlayerSpawnPos(),
            .velocity = @splat(0),
            .last_update = .now(io, .awake),
        },
        .gameMode = .init(.Spectator),
        .viewDirection = @Vector(3, f32){ 0.0001, -0.4, 0.001 },
        .main_inventory = undefined,
    }, true);
    playerentity.release();
    game.player = @ptrCast(@alignCast(playerentity.ptr));
    game.player.main_inventory = .initBuffer(
        10,
        16,
        &game.player.inventory_buffer,
    );
    _ = game.player.main_inventory.set(io, 0, 0, .{ .item_type = .Explosive, .amount = 65536 });
    game.player.viewDirection_mutex.lockUncancelable(io);
    const viewDirection = game.player.viewDirection;
    game.player.viewDirection_mutex.unlock(io);
    game.renderer.updateCameraDirection(viewDirection);
}

fn move(xzin: [2]i32, c: *usize) [2]i32 {
    const movf: f32 = (@as(f32, @floatFromInt(c.*)) / 2.0);
    const mov: i32 = @ceil(movf + 0.01);
    var xz = xzin;
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
