const std = @import("std");
const World = @import("world/World.zig");
const ChunkManager = @import("ChunkManager.zig").ChunkManager;
const Renderer = @import("client/Renderer.zig");
const ThreadPool = @import("ThreadPool");
const Entity = @import("world/Entity.zig");
const EntityTypes = @import("world/EntityTypes.zig");
const utils = @import("libs/utils.zig");
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const builtin = @import("builtin");
const Chunk = @import("world/Chunk.zig");
const Loader = @import("Loader.zig");
const sdl = @import("sdl3");
const Key = @import("Key.zig");
const zm = @import("zm");
const dvui = @import("dvui");

allocator: std.mem.Allocator,
world: World,
player: *EntityTypes.Player,
pool: ThreadPool,
chunkManager: ChunkManager,
renderer: Renderer,
generator: World.DefaultGenerator,
region_storage: World.WorldStorage,
game_arena: std.heap.ArenaAllocator,

// Threads
loaderThread: ?std.Thread,
unloaderThread: ?std.Thread,

options: *Options,
options_lock: *std.Thread.RwLock,
running: std.atomic.Value(bool),

pub const Options = struct {
    unloader_frequency_ms: u64 = 1000,
    ///start, end
    levels: [2]i32,
    ///x, y
    generation_distance: [2]u32,

    ///after this of time in microseconds a chunk will be unloaded if it is not used
    chunk_timeout_ms: u64,

    pub const structui_options: dvui.struct_ui.StructOptions(@This()) = .initWithDefaults(.{
        .chunk_timeout_ms = .{ .number = .{ .display = .read_write } },
    }, null);
};

///This holds data used to join a game type, multiplayer protocols will be added later
pub const Join = union(enum) {
    world_folder: []const u8,
};

pub fn init(game: *@This(), allocator: std.mem.Allocator, game_options: *Options, window: sdl.video.Window, join_data: Join) !void {
    std.debug.assert(join_data == .world_folder);
    game.game_arena = .init(allocator);
    errdefer game.game_arena.deinit();
    const arena = game.game_arena.allocator();

    var world_folder = try std.fs.cwd().openDir(join_data.world_folder, .{});
    defer world_folder.close();

    const worldConfigFile = try world_folder.openFile("config/WorldConfig.zon", .{ .mode = .read_only });
    defer worldConfigFile.close();

    const generatorConfigFile = try world_folder.openFile("config/GeneratorConfig.zon", .{ .mode = .read_only });
    defer generatorConfigFile.close();

    game.loaderThread = null;
    game.unloaderThread = null;

    const MainWorldConfig = try utils.loadZON(World.WorldConfig, worldConfigFile, allocator, arena);
    var GeneratorConfig = try utils.loadZON(World.DefaultGenerator.GenParams, generatorConfigFile, allocator, arena);

    GeneratorConfig.CaveNoise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 1));
    GeneratorConfig.TreeNoise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 2));
    GeneratorConfig.TerrainNoise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 3));
    GeneratorConfig.LargeTerrainNoise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 4));
    GeneratorConfig.LargeTerrainNoiseWarp.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 4));

    game.allocator = allocator;
    const terrain_height_cache_memory = 10_000_000; //10 mb
    const thc_size = @divFloor(terrain_height_cache_memory, @sizeOf(i32) * Chunk.ChunkSize * Chunk.ChunkSize);
    game.generator = World.DefaultGenerator{
        .TerrainHeightCache = try .init(allocator, thc_size),
        .params = GeneratorConfig,
    };
    game.options = game_options;
    const storage_path = try std.fs.path.joinZ(allocator, &[_][]const u8{ join_data.world_folder, "storage" });
    {
        defer allocator.free(storage_path);
        game.region_storage = try .init(storage_path, .{}, allocator);
    }
    errdefer game.generator.TerrainHeightCache.deinit();
    game.running = .init(true);

    const cpu_count = try std.Thread.getCpuCount();
    try game.pool.init(.{ .n_jobs = cpu_count, .allocator = allocator });
    errdefer game.pool.deinit();
    game.world = .{
        .running = .init(true),
        .entityUpdaterThread = null,
        .allocator = allocator,
        .threadPool = &game.pool,
        .Entitys = .init(allocator),
        .Chunks = .init(allocator),
        .Config = MainWorldConfig,
        .ChunkSources = .{ null, null, game.region_storage.getSource(), game.generator.getSource() },
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
        .physics = .{
            .elements = .{
                .mover = .{
                    .collisions = true,
                    .boundingBox = .init(.{ -0.5, -2, -0.5 }, .{ 0.5, 2, 0.5 }),
                },
                .gravity = .{},
                .resistance = .{ .fraction_per_second = 0.1 },
            },
            .pos = try game.world.getPlayerSpawnPos(),
            .velocity = @splat(0),
            .updateTimer = try .start(),
        },
        .gameMode = .init(.Creative),
        .viewDirection = @Vector(3, f32){ 0.0001, -0.4, 0.001 },
    });
    game.player = @ptrCast(@alignCast(playerentity.ptr));
    game.chunkManager = .{
        .pool = &game.pool,
        .ChunkRenderList = .init(allocator),
        .LoadingChunks = .init(allocator),
        .MeshesToLoad = .init(allocator),
        .world = &game.world,
        .allocator = allocator,
    };
    game.renderer = try .init(allocator, game.player);
    _ = window;
}

pub fn getGenDistance(self: *@This()) @Vector(2, u32) {
    self.options_lock.lockShared();
    defer self.options_lock.unlockShared();
    return self.options.generation_distance;
}

pub fn getLevels(self: *@This()) [2]i32 {
    self.options_lock.lockShared();
    defer self.options_lock.unlockShared();
    return self.options.levels;
}

pub fn getInnerGenRadius(self: *@This(), level: i32) @Vector(2, u32) {
    if (level <= self.getLevels()[0]) return @splat(0);
    const inner_radius = self.getGenDistance() / @Vector(2, u32){ World.scale_factor, World.scale_factor };
    return inner_radius -| @Vector(2, u32){ 1, 1 }; //subtract 1 so their is one chunk of overlap
}

pub fn handleMouseMotion(self: *@This(), mouse_motion: [2]f32) void {
    const sensitivity: f32 = 0.5;
    var viewDirDiff: @Vector(2, f32) = @splat(0);
    viewDirDiff += @Vector(2, f32){ mouse_motion[1], mouse_motion[0] };
    viewDirDiff *= @splat(sensitivity);

    const smallf32 = 0.00001;

    self.player.viewDirectionLock.lock();
    self.player.viewDirection -= @Vector(3, f32){ viewDirDiff[0], viewDirDiff[1], 0 };
    self.player.viewDirection[0] = std.math.clamp(self.player.viewDirection[0], -90 + smallf32, 90 - smallf32);
    self.player.viewDirectionLock.unlock();
    self.renderer.updateCameraDirection();
}

pub fn handleKeyboardActions(self: *@This(), actions: Key.ActionSet, delta_time_ns: u64) !void {
    const delta_time_seconds = @as(f32, @floatFromInt(delta_time_ns)) / std.time.ns_per_s;

    switch (self.player.gameMode.load(.unordered)) {
        .Creative => try self.flyMove(actions, delta_time_seconds),
        else => @panic("TODO"),
    }
}

fn flyMove(self: *@This(), actions: Key.ActionSet, delta_time_seconds: f32) !void {
    const veldiff: @Vector(3, f32) = @splat(self.player.fly_speed.load(.unordered) * delta_time_seconds);
    const c = zm.vec.cross(self.renderer.cameraFront, Renderer.cameraUp);
    const cross: ?@Vector(3, f64) = if (std.meta.eql(c, @Vector(3, f64){ 0, 0, 0 })) null else zm.vec.normalize(c); //prevent divide by zero

    if (actions.contains(.forward)) _ = self.player.physics.fetchAddVelocity(veldiff * self.renderer.cameraFront);
    if (actions.contains(.backward)) _ = self.player.physics.fetchAddVelocity(-veldiff * self.renderer.cameraFront);
    if (actions.contains(.up)) _ = self.player.physics.fetchAddVelocity(@Vector(3, f64){ 0, veldiff[1], 0 });
    if (actions.contains(.down)) _ = self.player.physics.fetchAddVelocity(@Vector(3, f64){ 0, -veldiff[1], 0 });
    if (actions.contains(.right) and cross != null) _ = self.player.physics.fetchAddVelocity(veldiff * cross.?);
    if (actions.contains(.left) and cross != null) _ = self.player.physics.fetchAddVelocity(-veldiff * cross.?);
}

pub fn deinit(self: *@This(), window: sdl.video.Window) void {
    self.running.store(false, .monotonic);
    self.world.stop();
    if (self.loaderThread) |thread| thread.join();
    if (self.unloaderThread) |thread| thread.join();

    std.log.info("stopped threads", .{});

    self.renderer.deinit();

    self.chunkManager.pool.deinit();
    std.log.info("closed threadpool", .{});

    var it = self.chunkManager.ChunkRenderList.iterator();
    while (it.next()) |entry| {
        const mesh = entry.value_ptr;
        mesh.free();
    }

    it.deinit();
    self.chunkManager.ChunkRenderList.deinit();
    self.chunkManager.LoadingChunks.deinit();
    while (self.chunkManager.MeshesToLoad.popFirst()) |mesh| {
        mesh.free(self.allocator);
    }
    self.chunkManager.MeshesToLoad.deinit(true);

    self.world.deinit();

    self.game_arena.deinit();
    _ = window;
}

pub fn startThreads(self: *@This()) !void {
    self.loaderThread = try std.Thread.spawn(.{}, Loader.ChunkLoaderThread, .{ self, 100 * std.time.ns_per_ms });
    self.unloaderThread = try std.Thread.spawn(.{}, World.chunkUnloaderThread, .{ &self.world, self.options, self.options_lock });
    self.world.entityUpdaterThread = try std.Thread.spawn(.{}, World.updateEntitiesThread, .{ &self.world, 5 * std.time.ns_per_ms });
    self.chunkManager.world.onEdit = .{ .onEditFn = ChunkManager.onEditFn, .onEditFnArgs = @ptrCast(&self.chunkManager), .callIfNeighborFacesChanged = true };
}
