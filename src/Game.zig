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

//The radius in which chunk generate chunks to generate horizontal, vertical
GenerateDistance: std.atomic.Value(packed struct { xz: u32, y: u32 }),

///the smallest level for general world generation
SmallestLevel: i32 = 0,

levels: [2]i32,

chunk_timeout: u64,

running: std.atomic.Value(bool),

pub const GameConfig = struct {
    ///start, end
    levels: [2]i32,
    generation_distance: [2]u32,
    ///after this of time in seconds a chunk will be unloadeed if it is not used
    chunk_timeout: u64,
};
pub fn init(game: *@This(), allocator: std.mem.Allocator, secondary_allocator: std.mem.Allocator, window: sdl.video.Window, game_path: std.fs.Dir) !void {
    game.game_arena = .init(secondary_allocator);
    errdefer game.game_arena.deinit();
    const arena = game.game_arena.allocator();
    const worldConfigFile = try std.fs.cwd().openFile("config/WorldConfig.zon", .{ .mode = .read_only });
    defer worldConfigFile.close();

    const generatorConfigFile = try std.fs.cwd().openFile("config/GeneratorConfig.zon", .{ .mode = .read_only });
    defer generatorConfigFile.close();

    const gameConfigFile = try std.fs.cwd().openFile("config/GameConfig.zon", .{ .mode = .read_only });
    defer gameConfigFile.close();

    game.loaderThread = null;
    game.unloaderThread = null;

    const config = try utils.loadZON(GameConfig, gameConfigFile, secondary_allocator, arena);

    const MainWorldConfig = try utils.loadZON(World.WorldConfig, worldConfigFile, secondary_allocator, arena);
    var GeneratorConfig = try utils.loadZON(World.DefaultGenerator.GenParams, generatorConfigFile, secondary_allocator, arena);

    GeneratorConfig.CaveNoise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 1));
    GeneratorConfig.TreeNoise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 2));
    GeneratorConfig.TerrainNoise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 3));
    GeneratorConfig.LargeTerrainNoise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 4));
    GeneratorConfig.LargeTerrainNoiseWarp.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 4));

    game.allocator = allocator;
    const terrain_height_cache_memory = 10_000_000; //10 mb
    const thc_size = @divFloor(terrain_height_cache_memory, @sizeOf(i32) * Chunk.ChunkSize * Chunk.ChunkSize);
    game.generator = World.DefaultGenerator{
        .TerrainHeightCache = try .init(secondary_allocator, thc_size),
        .params = GeneratorConfig,
    };
    game.levels = config.levels;
    game.chunk_timeout = config.chunk_timeout;
    _ = game_path;
    game.region_storage = try .init("test_world/storage", .{}, allocator);
    errdefer game.generator.TerrainHeightCache.deinit();
    game.running = .init(true);
    game.GenerateDistance = .init(.{ .xz = config.generation_distance[0], .y = config.generation_distance[1] });
    const cpu_count = try std.Thread.getCpuCount();
    try game.pool.init(.{ .n_jobs = cpu_count, .allocator = secondary_allocator });
    errdefer game.pool.deinit();
    game.world = .{
        .running = .init(true),
        .entityUpdaterThread = null,
        .allocator = allocator,
        .threadPool = &game.pool,
        .Entitys = .init(secondary_allocator),
        .Chunks = .init(secondary_allocator),
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
    const dist = self.GenerateDistance.load(.monotonic);
    return .{ dist.xz, dist.y };
}

pub fn getInnerGenRadius(self: *@This(), level: i32) @Vector(2, u32) {
    if (level <= self.levels[0]) return @splat(0);
    const inner_radius = self.getGenDistance() / @Vector(2, u32){ World.scale_factor, World.scale_factor };
    return inner_radius -| @Vector(2, u32){ 1, 1 }; //subtract 1 so their is one chunk of overlap
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
    if (actions.contains(.forward)) {
        std.debug.print("forward\n", .{});
        _ = self.player.physics.fetchAddVelocity(veldiff * self.player.viewDirection);
    }
    if (actions.contains(.backward)) _ = self.player.physics.fetchAddVelocity(-veldiff * self.player.viewDirection);

    //TODO remaining actions
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
    self.unloaderThread = try std.Thread.spawn(.{}, World.chunkUnloaderThread, .{ &self.world, 1000 * std.time.ns_per_ms, self.chunk_timeout * std.time.us_per_s });
    self.world.entityUpdaterThread = try std.Thread.spawn(.{}, World.updateEntitiesThread, .{ &self.world, 5 * std.time.ns_per_ms });
    self.chunkManager.world.onEdit = .{ .onEditFn = ChunkManager.onEditFn, .onEditFnArgs = @ptrCast(&self.chunkManager), .callIfNeighborFacesChanged = true };
}
