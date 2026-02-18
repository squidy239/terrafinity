const std = @import("std");
const builtin = @import("builtin");

const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const dvui = @import("dvui");
const sdl = @import("sdl3");
const ThreadPool = @import("ThreadPool");
const zm = @import("zm");
const ztracy = @import("ztracy");

const Key = @import("Key.zig");
const TrackingAllocator = @import("libs/TrackingAllocator.zig");
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
pool: ThreadPool,
opengl_renderer: Renderer.OpenGl,
renderer: Renderer,
generator: World.DefaultGenerator,
world_storage: World.WorldStorage,
game_arena: std.heap.ArenaAllocator,
tracking_allocator: TrackingAllocator,

loaded_or_meshed: ConcurrentHashMap(World.ChunkPos, void, std.hash_map.AutoContext(World.ChunkPos), 80, 128),

// Threads
loaderThread: ?std.Thread,
unloaderThread: ?std.Thread,

options: *Options,
options_lock: *std.Thread.RwLock,
running: std.atomic.Value(bool),

pub const Options = struct {
    mouse_sensitivity: f32 = 0.5,
    scroll_sensitivity: f32 = 0.1,

    lowest_level: i32 = 0,
    highest_level: i32 = 10,

    generation_distance_x: u32 = 8,
    generation_distance_y: u32 = 6,

    max_chunk_timeout_ms: u64 = 10000,
    memory_target: u64 = 2 * 1024 * 1024 * 1024, //1 GiB
    ///how often the unloader thread will try to unload chunks
    unloader_frequency_ms: u64 = 1000,

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

    pub fn fromWorldFolder(folder: []const u8, allocator: std.mem.Allocator) !WorldOptions {
        var world_folder = try std.fs.cwd().openDir(folder, .{});
        defer world_folder.close();

        const worldConfigFile = try world_folder.openFile("config/World.zon", .{ .lock = .shared });
        defer worldConfigFile.close();

        const generatorConfigFile = try world_folder.openFile("config/DefaultGenerator.zon", .{ .lock = .shared });
        defer generatorConfigFile.close();

        var generator_config = try utils.loadZON(World.DefaultGenerator.Params, generatorConfigFile, allocator, allocator);
        generator_config.setSeeds();
        return .{
            .generator_config = generator_config,
            .world_config = try utils.loadZON(World.WorldConfig, worldConfigFile, allocator, allocator),
        };
    }

    ///saves the world options to the config directory in the given folder, creating the files if they do not exist
    pub fn save(self: WorldOptions, folder: []const u8) !void {
        var wbuffer: [1024]u8 = undefined;
        var gbuffer: [1024]u8 = undefined;

        var world_folder = try std.fs.cwd().openDir(folder, .{});
        defer world_folder.close();

        world_folder.makeDir("config") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const worldConfigFile = try world_folder.createFile("config/World.zon", .{ .lock = .exclusive });
        defer worldConfigFile.close();

        var worldconfwriter = worldConfigFile.writer(&wbuffer);

        const generatorConfigFile = try world_folder.createFile("config/DefaultGenerator.zon", .{ .lock = .exclusive });
        defer generatorConfigFile.close();

        var generatorconfwriter = generatorConfigFile.writer(&gbuffer);

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
pub fn init(game: *@This(), allocator: std.mem.Allocator, game_options: *Options, game_options_lock: *std.Thread.RwLock, folder: []const u8, window: sdl.video.Window) !void {
    game.* = .{
        .game_arena = .init(allocator),
        .options = game_options,
        .options_lock = game_options_lock,
        .running = .init(true),
        .allocator = undefined,
        .pool = undefined,
        .opengl_renderer = undefined,
        .renderer = undefined,
        .generator = undefined,
        .loaded_or_meshed = .init(allocator),
        .tracking_allocator = .init(allocator, std.math.maxInt(usize)),
        .world_storage = undefined,
        .world = undefined,
        .player = undefined,
        .loaderThread = null,
        .unloaderThread = null,
    };
    try game.opengl_renderer.init(allocator, window);
    game.renderer = game.opengl_renderer.interface;
    game.allocator = game.tracking_allocator.get_allocator();
    errdefer game.game_arena.deinit();
    const arena = game.game_arena.allocator();
    std.fs.cwd().makeDir(folder) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var world_options = WorldOptions.fromWorldFolder(folder, arena) catch |err| switch (err) {
        error.FileNotFound => WorldOptions.default,
        else => return err,
    };
    world_options.generator_config.setSeeds();
    try world_options.save(folder);

    const terrain_height_cache_memory = 100 * 1024 * 1024;
    const thc_size = @divFloor(terrain_height_cache_memory, @sizeOf(i32) * Chunk.ChunkSize * Chunk.ChunkSize);
    game.generator = World.DefaultGenerator{
        .terrain_height_cache = try .init(game.allocator, thc_size),
        .params = world_options.generator_config,
    };
    errdefer game.generator.terrain_height_cache.deinit();
    const storage_path = try std.fs.path.joinZ(game.allocator, &[_][]const u8{ folder, "storage" });
    {
        defer game.allocator.free(storage_path);
        game.world_storage = try .init(storage_path, .{}, game.allocator);
    }

    const cpu_count = try std.Thread.getCpuCount();
    try game.pool.init(.{ .n_jobs = cpu_count, .allocator = game.allocator });
    errdefer game.pool.deinit();
    game.world = .{
        .running = .init(true),
        .allocator = game.allocator,
        .threadPool = &game.pool,
        .Entitys = .init(game.allocator),
        .Chunks = .init(game.allocator),
        .Config = world_options.world_config,
        .ChunkSources = .{ null, null, game.world_storage.getSource(), game.generator.getSource() },
        .onEdit = null,
    };
    errdefer game.world.deinit();

    for (0..0) |_| {
        _ = try game.world.spawnEntity(null, EntityTypes.Cube{
            .lock = .{},
            .pos = @splat(0),
            .velocity = @splat(0),
            .timestamp = std.time.microTimestamp(),
        });
    }

    const playerentity = try game.world.spawnEntity(null, EntityTypes.Player{
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
            .pos = try game.world.getPlayerSpawnPos(),
            .velocity = @splat(0),
            .updateTimer = try .start(),
        },
        .gameMode = .init(.Spectator),
        .viewDirection = @Vector(3, f32){ 0.0001, -0.4, 0.001 },
    });
    game.player = @ptrCast(@alignCast(playerentity.ptr));
    game.opengl_renderer.updateCameraDirection(game.player.getViewDirection());
}

pub fn getGenDistance(self: *@This()) @Vector(2, u32) {
    self.options_lock.lockShared();
    defer self.options_lock.unlockShared();
    return .{ self.options.generation_distance_x, self.options.generation_distance_y };
}

pub fn getLevels(self: *@This()) [2]i32 {
    self.options_lock.lockShared();
    defer self.options_lock.unlockShared();
    return .{ self.options.lowest_level, self.options.highest_level };
}

pub fn getInnerGenRadius(self: *@This(), gendistance: @Vector(2, u32), level: i32) @Vector(2, u32) {
    if (level <= self.getLevels()[0]) return @splat(0);
    const inner_radius = gendistance / @Vector(2, u32){ World.scale_factor, World.scale_factor };
    return inner_radius -| @Vector(2, u32){ 1, 1 }; //subtract 1 so their is one chunk of overlap
}

pub fn handleMouseMotion(self: *@This(), mouse_motion: [2]f32, sensitivity: f32) void {
    var viewDirDiff: @Vector(2, f32) = @splat(0);
    viewDirDiff += @Vector(2, f32){ mouse_motion[1], mouse_motion[0] };
    viewDirDiff *= @splat(sensitivity);

    const smallf32 = 0.00001;

    self.player.viewDirectionLock.lock();
    self.player.viewDirection -= @Vector(3, f32){ viewDirDiff[0], viewDirDiff[1], 0 };
    self.player.viewDirection[0] = std.math.clamp(self.player.viewDirection[0], -90 + smallf32, 90 - smallf32);
    self.opengl_renderer.updateCameraDirection(self.player.viewDirection);
    self.player.viewDirectionLock.unlock();
}

pub fn handleScroll(self: *@This(), scroll: f32) void {
    self.options_lock.lockShared();
    const scroll_sensitivity = self.options.scroll_sensitivity;
    self.options_lock.unlockShared();
    switch (self.player.gameMode.load(.seq_cst)) {
        .Creative, .Spectator => {
            const fsl = self.player.fly_speed_linear.fetchAdd(scroll * scroll_sensitivity, .seq_cst);
            _ = self.player.fly_speed.store(@min(@as(f32, @floatFromInt(std.math.maxInt(i32))), std.math.pow(f32, 2, fsl)), .seq_cst);
        },
        .Survival => {},
    }
}

pub fn getMouseSensitivity(self: *@This()) f32 {
    self.options_lock.lockShared();
    defer self.options_lock.unlockShared();
    return self.options.mouse_sensitivity;
}

pub fn handleButtonActions(self: *@This(), actions: Key.ActionSet, delta_time_ns: u64) !void {
    const delta_time_seconds = @as(f32, @floatFromInt(delta_time_ns)) / std.time.ns_per_s;

    switch (self.player.gameMode.load(.unordered)) {
        .Creative, .Spectator => try self.flyMove(actions, delta_time_seconds),
        else => @panic("TODO"),
    }
}

fn flyMove(self: *@This(), actions: Key.ActionSet, delta_time_seconds: f32) !void {
    const veldiff: @Vector(3, f32) = @splat(self.player.fly_speed.load(.unordered) * delta_time_seconds);
    const c = zm.vec.cross(self.opengl_renderer.cameraFront, Renderer.OpenGl.cameraUp);
    const cross: ?@Vector(3, f64) = if (std.meta.eql(c, @Vector(3, f64){ 0, 0, 0 })) null else zm.vec.normalize(c); //prevent divide by zero

    if (actions.contains(.forward)) _ = self.player.physics.fetchAddVelocity(veldiff * self.opengl_renderer.cameraFront);
    if (actions.contains(.backward)) _ = self.player.physics.fetchAddVelocity(-veldiff * self.opengl_renderer.cameraFront);
    if (actions.contains(.up)) _ = self.player.physics.fetchAddVelocity(@Vector(3, f64){ 0, veldiff[1], 0 });
    if (actions.contains(.down)) _ = self.player.physics.fetchAddVelocity(@Vector(3, f64){ 0, -veldiff[1], 0 });
    if (actions.contains(.right) and cross != null) _ = self.player.physics.fetchAddVelocity(veldiff * cross.?);
    if (actions.contains(.left) and cross != null) _ = self.player.physics.fetchAddVelocity(-veldiff * cross.?);
}

///Adds a chunk to the render list replacing it if it already exists, generates it or its neighbors if it dosent exist
pub fn addChunkToRender(self: *@This(), Pos: World.ChunkPos, genStructures: bool, playAnimation: bool) !void {
    const GenMeshAndAdd = ztracy.ZoneNC(@src(), "GenMeshAndAdd", 324342342);
    defer GenMeshAndAdd.End();
    const chunk = try self.world.loadChunk(Pos, genStructures);
    defer chunk.release();
    const neighbor_faces = [6][ChunkSize][ChunkSize]Block{
        (try self.world.loadChunk(Pos.add(.{ 1, 0, 0 }), false)).extractFace(.xMinus, true),
        (try self.world.loadChunk(Pos.add(.{ -1, 0, 0 }), false)).extractFace(.xPlus, true),
        (try self.world.loadChunk(Pos.add(.{ 0, 1, 0 }), false)).extractFace(.yMinus, true),
        (try self.world.loadChunk(Pos.add(.{ 0, -1, 0 }), false)).extractFace(.yPlus, true),
        (try self.world.loadChunk(Pos.add(.{ 0, 0, 1 }), false)).extractFace(.zMinus, true),
        (try self.world.loadChunk(Pos.add(.{ 0, 0, -1 }), false)).extractFace(.zPlus, true),
    };
    const exbl = ztracy.ZoneNC(@src(), "extractBlocks", 3222);
    const lock = ztracy.ZoneNC(@src(), "lock", 2222111);
    chunk.lockShared();
    defer chunk.unlockShared();
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
    try self.opengl_renderer.render_buffer.put(Pos, written);
    _ = playAnimation;
}

pub fn unloadChunkMeshes(self: *@This()) void {
    const unload = ztracy.ZoneNC(@src(), "UnloadMeshes", 75645);
    defer unload.End();

    const playerpos = self.player.physics.getPos();
    const renderdistance = self.getGenDistance();
    const levels = self.getLevels();
    var buffer: [1024]World.ChunkPos = undefined;
    var tounload: std.ArrayList(World.ChunkPos) = .initBuffer(&buffer);

    {
        if (!self.opengl_renderer.render_buffer.lock.tryLock()) return;
        defer self.opengl_renderer.render_buffer.lock.unlock();
        var it = self.opengl_renderer.render_buffer.map.iterator();
        defer it.deinit();
        const loop = ztracy.ZoneNC(@src(), "loopMeshes", 6788676);
        defer loop.End();
        while (it.next()) |entry| {
            const Pos = entry.key_ptr.*;
            const innerRadius: @Vector(2, u32) = self.getInnerGenRadius(renderdistance, Pos.level);
            const keep = Loader.keepLoaded(levels[0], levels[1], playerpos, Pos, innerRadius, renderdistance);
            if (keep) continue;
            tounload.appendBounded(Pos) catch break;
        }
    }
    for (tounload.items) |Pos| {
        self.opengl_renderer.render_buffer.remove(Pos);
        _ = self.loaded_or_meshed.remove(Pos); //TODO no mesh entrys in this leak
    }
}

pub fn addChunkToRenderAsync(self: *@This(), Pos: World.ChunkPos, genStructures: bool) !void {
    try self.loaded_or_meshed.put(Pos, {});
    errdefer _ = self.loaded_or_meshed.remove(Pos);
    const priority: ThreadPool.Priority = switch (Pos.level) {
        std.math.minInt(i32)...1 => .High,
        2...3 => .Medium,
        4...8 => .Low,
        9...std.math.maxInt(i32) => .VeryLow,
    };
    try self.pool.spawn(addChunkToRenderTask, .{ self, Pos, genStructures }, priority);
}

fn addChunkToRenderTask(self: *@This(), Pos: World.ChunkPos, genStructures: bool) void {
    self.options_lock.lockShared();
    const lowest_level = self.options.lowest_level;
    const highest_level = self.options.highest_level;
    self.options_lock.unlockShared();

    const inside_range = Loader.keepLoaded(lowest_level, highest_level, self.player.physics.getPos(), Pos, self.getInnerGenRadius(self.getGenDistance(), Pos.level), self.getGenDistance());
    const running = self.running.load(.monotonic);
    if (!inside_range or !running) {
        _ = self.loaded_or_meshed.remove(Pos);
        return;
    }
    self.addChunkToRender(Pos, genStructures, true) catch |err| std.debug.panic("addchunktorenderError:{any}", .{err});
}
pub fn onEditFn(chunkPos: World.ChunkPos, args: *anyopaque) !void {
    const game: *@This() = @ptrCast(@alignCast(args));
    game.addChunkToRender(chunkPos, false, false) catch return error.OnEditFailed;
}

pub fn deinit(self: *@This(), window: sdl.video.Window) void {
    self.running.store(false, .monotonic);
    self.world.stop();
    if (self.loaderThread) |thread| thread.join();
    if (self.unloaderThread) |thread| thread.join();

    std.log.info("stopped threads", .{});

    self.pool.deinit();
    std.log.info("closed threadpool", .{});
    self.opengl_renderer.deinit();
    self.loaded_or_meshed.deinit();

    self.world.deinit();

    self.game_arena.deinit();
    _ = window;
}

pub fn startThreads(self: *@This()) !void {
    self.loaderThread = try std.Thread.spawn(.{}, Loader.ChunkLoaderThread, .{ self, 100 * std.time.ns_per_ms });
    self.unloaderThread = try std.Thread.spawn(.{}, World.chunkUnloaderThread, .{ &self.world, self.options, self.options_lock, &self.tracking_allocator.used_memory });
    self.world.onEdit = .{ .onEditFn = onEditFn, .onEditFnArgs = @ptrCast(self), .callIfNeighborFacesChanged = true };
}
