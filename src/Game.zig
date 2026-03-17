const std = @import("std");
const builtin = @import("builtin");

const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const dvui = @import("dvui");
const sdl = @import("sdl3");
const zm = @import("zm");
const ztracy = @import("ztracy");

const Key = @import("Key.zig");
const utils = @import("libs/utils.zig");
const Loader = @import("Loader.zig");
const Mesh = @import("Mesh.zig");
pub const Renderer = @import("Renderer.zig");
const Chunk = @import("world/Chunk.zig");
const Entity = @import("world/Entity.zig");
const EntityTypes = @import("world/EntityTypes.zig");
const World = @import("world/World.zig");
const ChunkSize = World.ChunkSize;
const Block = World.Block;

allocator: std.mem.Allocator,
world: World,
player: *EntityTypes.Player,
opengl_renderer: Renderer.OpenGl,
renderer: Renderer,
generator: World.DefaultGenerator,
world_storage: World.WorldStorage,
game_arena: std.heap.ArenaAllocator,
loaded_or_meshed: ConcurrentHashMap(World.ChunkPos, void, std.hash_map.AutoContext(World.ChunkPos), 80, 128),

selected_inventory_row: std.atomic.Value(u32) = .init(0),
selected_inventory_col: std.atomic.Value(u32) = .init(0),

last_chunk_load: std.Io.Timestamp = .zero,
chunk_load_is_running: std.atomic.Value(bool) = .init(false),

last_chunk_unload: std.Io.Timestamp = .zero,
chunk_unload_is_running: std.atomic.Value(bool) = .init(false),

select: std.Io.Select(SelectUnion),
select_buffer: [65536]SelectUnion = undefined,

options: *Options,
options_lock: *std.Io.RwLock,
running: std.atomic.Value(bool),

const SelectUnion = union(enum) {
    addChunkToRender: @typeInfo(@TypeOf(addChunkToRender)).@"fn".return_type.?,
    loadChunks: @typeInfo(@TypeOf(loadChunks)).@"fn".return_type.?,
    unloadChunks: @typeInfo(@TypeOf(World.unloadTimeout)).@"fn".return_type.?,
};

pub const Options = struct {
    mouse_sensitivity: f32 = 0.5,
    scroll_sensitivity: f32 = 0.1,

    lowest_level: i32 = 0,
    highest_level: i32 = 10,

    generation_distance_x: u32 = 8,
    generation_distance_y: u32 = 6,

    max_chunk_timeout_ms: u64 = 60000,
    max_grid_timeout_ms: u64 = 60000,

    chunk_capacity: u64 = 262144,
    block_grid_capacity: u64 = 8196,

    unloader_frequency_ms: u64 = 1000,
    loader_frequency_ms: u64 = 250,

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
        var world_folder = try std.Io.Dir.cwd().openDir(io, folder, .{});
        defer world_folder.close(io);

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

const gl = @import("gl");

pub fn init(game: *@This(), io: std.Io, allocator: std.mem.Allocator, game_options: *Options, game_options_lock: *std.Io.RwLock, folder: []const u8, window: sdl.video.Window) !void {
    game.* = .{
        .game_arena = .init(allocator),
        .options = game_options,
        .options_lock = game_options_lock,
        .select = .init(io, &game.select_buffer),
        .running = .init(true),
        .allocator = undefined,
        .opengl_renderer = undefined,
        .renderer = undefined,
        .generator = undefined,
        .loaded_or_meshed = .init(),
        .world_storage = undefined,
        .world = undefined,
        .player = undefined,
    };
    try game.opengl_renderer.init(io, allocator, window);
    game.renderer = game.opengl_renderer.interface;
    game.allocator = allocator;
    errdefer game.game_arena.deinit();
    const arena = game.game_arena.allocator();
    std.Io.Dir.cwd().createDirPath(io, folder) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var world_options = WorldOptions.fromWorldFolder(folder, io, arena) catch |err| switch (err) {
        error.FileNotFound => WorldOptions.default,
        else => return err,
    };
    world_options.generator_config.setSeeds(io);
    try world_options.save(io, folder);

    const terrain_height_cache_memory = 100 * 1024 * 1024;
    const thc_size = @divFloor(terrain_height_cache_memory, @sizeOf(i32) * Chunk.ChunkSize * Chunk.ChunkSize);
    game.generator = World.DefaultGenerator{
        .terrain_height_cache = .init(thc_size),
        .params = world_options.generator_config,
    };
    errdefer game.generator.terrain_height_cache.deinit(io, allocator);
    const storage_path = try std.fs.path.joinZ(game.allocator, &[_][]const u8{ folder, "storage" });
    {
        defer game.allocator.free(storage_path);
        game.world_storage = try .init(storage_path, .{}, game.allocator);
    }

    game.options_lock.lockSharedUncancelable(io);
    const grid_capacity = game.options.block_grid_capacity;
    const chunk_capacity = game.options.chunk_capacity;
    game.options_lock.unlockShared(io);
    game.world = .{
        .chunk_pool = try .initCapacity(game.allocator, chunk_capacity),
        .block_grid_pool = try .initCapacity(game.allocator, grid_capacity),
        .Entitys = .init(),
        .Chunks = .init(),
        .Config = world_options.world_config,
        .ChunkSources = .{ null, null, game.world_storage.getSource(), game.generator.getSource() },
        .onEdit = null,
    };
    errdefer game.world.deinit(io, allocator);

    const playerentity = try game.world.spawnEntity(io, allocator, null, EntityTypes.Player{
        .player_name = .fromString("squid"),
        .fly_speed = .init(100),
        .fly_speed_linear = .init(10),
        .physics = .{
            .elements = .{
                .mover = .{
                    .collisions = false,
                    .boundingBox = .init(.{ -0.5, -2, -0.5 }, .{ 0.5, 2, 0.5 }),
                    .enabled = true,
                    .zeroVelocity = true,
                },
                .gravity = .{
                    .enabled = false,
                },
                .resistance = .{ .fraction_per_second = 0.1, .enabled = false },
            },
            .pos = .{ .vector = try game.world.getPlayerSpawnPos() },
            .velocity = .{ .vector = @splat(0) },
            .last_update = .now(io, .awake),
        },
        .gameMode = .init(.Spectator),
        .viewDirection = .{ .vector = @Vector(3, f32){ 0.0001, -0.4, 0.001 } },
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
    game.opengl_renderer.updateCameraDirection(game.player.viewDirection.load(.seq_cst));
}

pub fn getGenDistance(self: *@This(), io: std.Io) !@Vector(2, u32) {
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return .{ self.options.generation_distance_x, self.options.generation_distance_y };
}

pub fn frame(self: *@This(), io: std.Io, allocator: std.mem.Allocator, size: @Vector(2, u32)) !void {
    var entitys_future = io.concurrent(World.updateEntitys, .{ &self.world, io, allocator }) catch io.async(World.updateEntitys, .{ &self.world, io, allocator });
    defer entitys_future.cancel(io);
    try updateLoadAndUnload(self, io, allocator);
    try self.renderer.setViewport(size);
    try self.renderer.clear(self.player.physics.pos.load(.seq_cst));
    try self.player.physics.update(&self.world, io, allocator);
    try self.renderer.drawChunks(io, self.player.physics.pos.load(.seq_cst));

    var unload_meshes = io.async(@This().unloadChunkMeshes, .{ self, io });
    defer unload_meshes.cancel(io);
    entitys_future.await(io);
    unload_meshes.await(io);
}

pub fn updateLoadAndUnload(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    self.options_lock.lockSharedUncancelable(io);
    const loader_frequency_ms = self.options.loader_frequency_ms;
    const unloader_frequency_ms = self.options.unloader_frequency_ms;
    const max_grid_timeout_ms = self.options.max_grid_timeout_ms;
    const max_chunk_timeout_ms = self.options.max_chunk_timeout_ms;
    const block_grid_capacity = self.options.block_grid_capacity;
    const chunk_capacity = self.options.chunk_capacity;
    self.options_lock.unlockShared(io);

    if (!self.chunk_load_is_running.load(.seq_cst) and self.last_chunk_load.durationTo(.now(io, .awake)).toMilliseconds() > loader_frequency_ms) {
        self.last_chunk_load = .now(io, .awake);
        self.chunk_load_is_running.store(true, .seq_cst);
        self.select.concurrent(.loadChunks, @This().loadChunks, .{ self, io, allocator }) catch self.select.async(.loadChunks, @This().loadChunks, .{ self, io, allocator });
    }

    if (!self.chunk_unload_is_running.load(.seq_cst) and self.last_chunk_unload.durationTo(.now(io, .awake)).toMilliseconds() > unloader_frequency_ms) {
        self.last_chunk_load = .now(io, .awake);
        self.chunk_unload_is_running.store(true, .seq_cst);
        self.select.concurrent(.unloadChunks, unloadWrapper, .{ self, io, max_grid_timeout_ms, block_grid_capacity, max_chunk_timeout_ms, chunk_capacity }) catch self.select.async(.unloadChunks, unloadWrapper, .{ self, io, max_grid_timeout_ms, block_grid_capacity, max_chunk_timeout_ms, chunk_capacity });
    }
}

fn unloadWrapper(self: *@This(), io: std.Io, max_grid_ms: u64, max_grids: u64, max_chunk_ms: u64, max_chunks: u64) !void {
    defer self.chunk_unload_is_running.store(false, .seq_cst);
    try self.world.unloadTimeout(io, max_grid_ms, max_grids, max_chunk_ms, max_chunks);
}

pub fn handleSelectFutures(self: *@This()) !            try self.select.concurrent(.unloadChunks, unloadWrapper, .{ self, io, max_grid_timeout_ms, block_grid_capacity, max_chunk_timeout_ms, chunk_capacity });
void {
    var select_completion_buffer: [1024]SelectUnion = undefined;
    while (true) {
        const completed = try self.select.awaitMany(&select_completion_buffer, 0);
        if (completed == 0) break;
        for (select_completion_buffer[0..completed]) |completed_union| {
            switch (completed_union) {
                .addChunkToRender => |f| try f,
                .loadChunks => |f| try f,
                .unloadChunks => |f| try f,
            }
        }
    }
}

pub fn getLevels(self: *@This(), io: std.Io) ![2]i32 {
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return .{ self.options.lowest_level, self.options.highest_level };
}

pub fn getInnerGenRadius(self: *@This(), io: std.Io, gendistance: @Vector(2, u32), level: i32) !@Vector(2, u32) {
    if (level <= (try self.getLevels(io))[0]) return @splat(0);
    const inner_radius = gendistance / @Vector(2, u32){ World.scale_factor, World.scale_factor };
    return inner_radius -| @Vector(2, u32){ 1, 1 };
}

pub fn handleMouseMotion(self: *@This(), mouse_motion: [2]f32, sensitivity: f32) void {
    var viewDirDiff: @Vector(2, f32) = @splat(0);
    viewDirDiff += @Vector(2, f32){ mouse_motion[1], mouse_motion[0] };
    viewDirDiff *= @splat(sensitivity);

    const smallf32 = 0.00001;

    _ = self.player.viewDirection.fetchAdd(-@Vector(3, f32){ viewDirDiff[0], viewDirDiff[1], 0 }, .seq_cst);
    _ = @atomicRmw(f32, &self.player.viewDirection.vector[0], .Max, -90 + smallf32, .seq_cst);
    _ = @atomicRmw(f32, &self.player.viewDirection.vector[0], .Min, 90 - smallf32, .seq_cst);
    self.opengl_renderer.updateCameraDirection(self.player.viewDirection.load(.seq_cst));
}

pub fn handleScroll(self: *@This(), io: std.Io, scroll: f32) !void {
    self.options_lock.lockSharedUncancelable(io);
    const scroll_sensitivity = self.options.scroll_sensitivity;
    self.options_lock.unlockShared(io);
    switch (self.player.gameMode.load(.seq_cst)) {
        .Creative, .Spectator => {
            const fsl = self.player.fly_speed_linear.fetchAdd(scroll * scroll_sensitivity, .seq_cst);
            _ = self.player.fly_speed.store(@min(@as(f32, @floatFromInt(std.math.maxInt(i32))), std.math.pow(f32, 2, fsl)), .seq_cst);
        },
        .Survival => {},
    }
}

pub fn getMouseSensitivity(self: *@This(), io: std.Io) f32 {
    self.options_lock.lockSharedUncancelable(io);
    defer self.options_lock.unlockShared(io);
    return self.options.mouse_sensitivity;
}

pub fn handleButtonActions(self: *@This(), io: std.Io, actions: Key.ActionSet, delta_time: std.Io.Duration) !void {
    const delta_time_seconds = @as(f32, @floatFromInt(delta_time.toNanoseconds())) / std.time.ns_per_s;

    switch (self.player.gameMode.load(.unordered)) {
        .Creative, .Spectator => try self.flyMove(io, actions, delta_time_seconds),
        else => @panic("TODO"),
    }
    self.setSelectedSlot(actions);
    try self.itemAction(io, actions);
}

fn setSelectedSlot(self: *@This(), actions: Key.ActionSet) void {
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

pub fn itemAction(self: *@This(), io: std.Io, actions: Key.ActionSet) !void {
    if (actions.contains(.use_item_primary)) try self.world.spawnEntity(io, self.allocator, null, EntityTypes.Explosive{
        .pos = .{ .vector = self.player.physics.pos.load(.seq_cst) },
        .dir = .{ .vector = @splat(0) },
        .timestamp = .init(std.Io.Timestamp.now(io, .awake).nanoseconds),
    }, false);
}

fn flyMove(self: *@This(), io: std.Io, actions: Key.ActionSet, delta_time_seconds: f32) !void {
    _ = io;
    const veldiff: @Vector(3, f32) = @splat(self.player.fly_speed.load(.unordered) * delta_time_seconds);
    const c = zm.vec.cross(self.opengl_renderer.cameraFront, Renderer.OpenGl.cameraUp);
    const cross: ?@Vector(3, f64) = if (std.meta.eql(c, @Vector(3, f64){ 0, 0, 0 })) null else zm.vec.normalize(c);

    if (actions.contains(.forward)) _ = self.player.physics.velocity.fetchAdd(veldiff * self.opengl_renderer.cameraFront, .seq_cst);
    if (actions.contains(.backward)) _ = self.player.physics.velocity.fetchAdd(-veldiff * self.opengl_renderer.cameraFront, .seq_cst);
    if (actions.contains(.up)) _ = self.player.physics.velocity.fetchAdd(@Vector(3, f64){ 0, veldiff[1], 0 }, .seq_cst);
    if (actions.contains(.down)) _ = self.player.physics.velocity.fetchAdd(@Vector(3, f64){ 0, -veldiff[1], 0 }, .seq_cst);
    if (actions.contains(.right) and cross != null) _ = self.player.physics.velocity.fetchAdd(veldiff * cross.?, .seq_cst);
    if (actions.contains(.left) and cross != null) _ = self.player.physics.velocity.fetchAdd(-veldiff * cross.?, .seq_cst);
}

/// Adds a chunk to the render list replacing it if it already exists, generates it or its neighbors if it doesn't exist.
pub fn addChunkToRender(self: *@This(), io: std.Io, allocator: std.mem.Allocator, Pos: World.ChunkPos, genStructures: bool) !void {
    const GenMeshAndAdd = ztracy.ZoneNC(@src(), "GenMeshAndAdd", 324342342);
    defer GenMeshAndAdd.End();
    const chunk = try self.world.loadChunk(io, allocator, Pos, genStructures);
    defer chunk.release(io);
    const neighbor_faces = [6]Chunk.ChunkFaceEncoding{
        (try self.world.loadChunk(io, allocator, Pos.add(.{ 1, 0, 0 }), false)).extractFace(io, .xMinus, true),
        (try self.world.loadChunk(io, allocator, Pos.add(.{ -1, 0, 0 }), false)).extractFace(io, .xPlus, true),
        (try self.world.loadChunk(io, allocator, Pos.add(.{ 0, 1, 0 }), false)).extractFace(io, .yMinus, true),
        (try self.world.loadChunk(io, allocator, Pos.add(.{ 0, -1, 0 }), false)).extractFace(io, .yPlus, true),
        (try self.world.loadChunk(io, allocator, Pos.add(.{ 0, 0, 1 }), false)).extractFace(io, .zMinus, true),
        (try self.world.loadChunk(io, allocator, Pos.add(.{ 0, 0, -1 }), false)).extractFace(io, .zPlus, true),
    };
    const exbl = ztracy.ZoneNC(@src(), "extractBlocks", 3222);
    const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
    chunk.lockShared(io);
    defer chunk.unlockShared(io);
    lock.End();
    exbl.End();
    var sfa = std.heap.stackFallback(65536, self.allocator);
    var alloc_writer: std.Io.Writer.Allocating = .init(sfa.get());
    defer alloc_writer.deinit();
    try Mesh.fromChunks(
        chunk.blocks,
        &neighbor_faces,
        &alloc_writer.writer,
    );
    const written = alloc_writer.written();
    if (written.len == 0) return;
    try self.opengl_renderer.ensureContext();
    try self.opengl_renderer.render_buffer.put(io, Pos, written);
}

pub fn unloadChunkMeshes(self: *@This(), io: std.Io) void {
    const unload = ztracy.ZoneNC(@src(), "UnloadMeshes", 75645);
    defer unload.End();

    const playerpos = self.player.physics.pos.load(.seq_cst);
    const renderdistance = try self.getGenDistance(io);
    const levels = try self.getLevels(io);
    var buffer: [1024]World.ChunkPos = undefined;
    var tounload: std.ArrayList(World.ChunkPos) = .initBuffer(&buffer);

    {
        if (!self.opengl_renderer.render_buffer.lock.tryLock()) return;
        defer self.opengl_renderer.render_buffer.lock.unlock(io);
        var it = self.opengl_renderer.render_buffer.map.iterator();
        defer it.deinit(io);
        const loop = ztracy.ZoneNC(@src(), "loopMeshes", 6788676);
        defer loop.End();
        while (it.next(io)) |entry| {
            const Pos = entry.key_ptr.*;
            const innerRadius: @Vector(2, u32) = try self.getInnerGenRadius(io, renderdistance, Pos.level);
            const keep = keepLoaded(levels[0], levels[1], playerpos, Pos, innerRadius, renderdistance);
            if (keep) continue;
            tounload.appendBounded(Pos) catch break;
        }
    }
    for (tounload.items) |Pos| {
        self.opengl_renderer.render_buffer.remove(io, Pos);
        _ = self.loaded_or_meshed.remove(io, Pos);
    }
}

pub fn addChunkToRenderAsync(self: *@This(), io: std.Io, allocator: std.mem.Allocator, Pos: World.ChunkPos, genStructures: bool) !void {
    try self.loaded_or_meshed.put(io, allocator, Pos, {});
    errdefer _ = self.loaded_or_meshed.remove(io, Pos);
    self.select.async(.addChunkToRender, addChunkToRender, .{ self, io, allocator, Pos, genStructures });
}

fn addChunkToRenderTask(self: *@This(), io: std.Io, Pos: World.ChunkPos, genStructures: bool) void {
    (self.options_lock.lockSharedUncancelable(io)) catch return;
    const lowest_level = self.options.lowest_level;
    const highest_level = self.options.highest_level;
    self.options_lock.unlockShared(io);

    const gendistance = self.getGenDistance(io) catch return;
    const inner_radius = self.getInnerGenRadius(io, gendistance, Pos.level) catch return;
    const inside_range = Loader.keepLoaded(lowest_level, highest_level, self.player.physics.getPos(), Pos, inner_radius, gendistance);
    const running = self.running.load(.monotonic);
    if (!inside_range or !running) {
        _ = self.loaded_or_meshed.remove(io, Pos);
        return;
    }
    self.addChunkToRender(io, Pos, genStructures) catch |err| std.debug.panic("addchunktorenderError:{any}", .{err});
}

pub fn onEditFn(io: std.Io, allocator: std.mem.Allocator, chunkPos: World.ChunkPos, args: *anyopaque) !void {
    const game: *@This() = @ptrCast(@alignCast(args));
    const lowest_level = game.options.lowest_level;
    const highest_level = game.options.highest_level;
    const inside_range = keepLoaded(lowest_level, highest_level, game.player.physics.pos.load(.seq_cst), chunkPos, game.getInnerGenRadius(io, game.getGenDistance(io) catch return, chunkPos.level) catch return, game.getGenDistance(io) catch return);
    if (!inside_range) return;
    game.addChunkToRender(io, allocator, chunkPos, false) catch return error.OnEditFailed;
}

pub fn keepLoaded(lowest_level: ?i32, highest_level: ?i32, playerPos: @Vector(3, f64), Pos: World.ChunkPos, innerChunkRange: ?@Vector(2, u32), outerChunkRange: ?@Vector(2, u32)) bool {
    if (lowest_level) |l| {
        if (Pos.level < l) return false;
    }
    if (highest_level) |h| {
        if (Pos.level > h) return false;
    }

    const playerChunkPos = @floor(playerPos / @as(@Vector(3, f64), @splat(World.ChunkPos.levelToBlockRatioFloat(Pos.level))));
    const center: @Vector(3, f64) = @floatFromInt(Pos.position);

    if (innerChunkRange) |icr| {
        const inner: @Vector(3, f64) = .{ @floatFromInt(icr[0]), @floatFromInt(icr[1]), @floatFromInt(icr[0]) };
        const insideInner =
            @reduce(.And, playerChunkPos > center - inner) and
            @reduce(.And, playerChunkPos < center + inner);
        if (insideInner) return false;
    }

    if (outerChunkRange) |ocr| {
        const outer: @Vector(3, f64) = .{ @floatFromInt(ocr[0]), @floatFromInt(ocr[1]), @floatFromInt(ocr[0]) };
        const outsideOuter =
            @reduce(.Or, playerChunkPos < center - outer) or
            @reduce(.Or, playerChunkPos > center + outer);
        if (outsideOuter) return false;
    }
    return true;
}

///Loads all chunks in gendistance and unloads all chunks out of loadistance
pub fn loadChunks(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
    defer self.chunk_load_is_running.store(false, .seq_cst);
    const playerPos = self.player.physics.pos.load(.seq_cst);
    const addChunkstoLoad = ztracy.ZoneNC(@src(), "addChunksToLoad", 223);
    const genDistance = try self.getGenDistance(io);
    const levels = try self.getLevels(io);
    var level = levels[0];
    var amount_loaded: u64 = 0;
    while (level < levels[1]) : (level += 1) {
        amount_loaded += try loadChunksSpiral(self, io, allocator, playerPos, genDistance, try self.getInnerGenRadius(io, genDistance, level), level);
    }
    addChunkstoLoad.End();
}

///loads chunks from top to bottom and in a spiral on a y level
fn loadChunksSpiral(game: *@This(), io: std.Io, allocator: std.mem.Allocator, playerPos: @Vector(3, f64), dist: @Vector(2, u32), innerdistance: @Vector(2, u32), level: i32) !u64 {
    const playerChunkPos = World.ChunkPos.fromGlobalBlockPos(@intFromFloat(playerPos), level);
    var amount_loaded: u64 = 0;
    var amount_tested: u64 = 0;

    var xz: [2]i32 = .{ 0, 0 };
    var c: usize = 0;

    const distance = dist;
    while (true) {
        if (amount_tested >= 4 * distance[0] * distance[0]) {
            break;
        }

        const m = Move(xz, &c);

        var cc: i32 = 0;
        while (Line(&xz, &cc, m)) {
            amount_tested += 1;
            std.debug.assert(cc <= 2 * @max(distance[0], distance[0]));
            var y: i32 = -@as(i32, @intCast(distance[1]));
            while (y < distance[1]) {
                defer y += 1;
                const Pos: World.ChunkPos = .{ .position = [3]i32{ xz[0] + playerChunkPos.position[0], y + playerChunkPos.position[1], xz[1] + playerChunkPos.position[2] }, .level = level };

                const in_range = keepLoaded(null, null, playerPos, Pos, innerdistance, distance);
                if (!in_range)
                    continue;

                const loaded = game.loaded_or_meshed.contains(io, Pos);

                if (!loaded) {
                    amount_loaded += 1;
                    try game.addChunkToRenderAsync(io, allocator, Pos, true);
                }
            }
        }
    }
    return amount_loaded;
}

fn Move(xzin: [2]i32, c: *usize) [2]i32 {
    const movf: f32 = (@as(f32, @floatFromInt(c.*)) / 2.0);
    const mov: i32 = @intFromFloat(@ceil(movf + 0.01));
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

fn Line(xz: *[2]i32, c: *i32, end: [2]i32) bool {
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

pub fn deinit(self: *@This(), io: std.Io, window: sdl.video.Window) void {
    self.running.store(false, .monotonic);

    std.log.info("stopped threads", .{});

    self.opengl_renderer.deinit(io);
    self.loaded_or_meshed.deinit(io, self.allocator);
    self.world.deinit(io, self.allocator);

    self.game_arena.deinit();
    _ = window;
}

pub fn startThreads(self: *@This(), io: std.Io) !void {
    _ = io;
    //    self.unloaderThread = try std.Thread.spawn(.{}, World.chunkUnloaderThread, .{ &self.world, io, self.options, self.options_lock });
    self.world.onEdit = .{ .onEditFn = onEditFn, .onEditFnArgs = @ptrCast(self), .callIfNeighborFacesChanged = true };
}
