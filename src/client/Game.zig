const std = @import("std");
const World = @import("World").World;
const ChunkManager = @import("ChunkManager.zig").ChunkManager;
const Renderer = @import("Renderer.zig");
const ThreadPool = @import("root").ThreadPool;
const Entity = @import("Entity");
const EntityTypes = @import("EntityTypes");
const utils = @import("utils.zig");
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const builtin = @import("builtin");
const Chunk = @import("Chunk").Chunk;
const Loader = @import("Loader.zig");
const UserInput = @import("UserInput.zig");
const glfw = @import("zglfw");

pub const Game = struct {
    allocator: std.mem.Allocator,
    world: World,
    player: *Entity.Entity,
    pool: ThreadPool,
    chunkManager: ChunkManager,
    renderer: Renderer.Renderer,
    generator: World.DefaultGenerator,
    region_storage: World.WorldStorage.RegionStorage,
    game_arena: std.heap.ArenaAllocator,

    // Threads
    loaderThread: ?std.Thread,
    unloaderThread: ?std.Thread,

    //The radius in which chunk generate chunks to generate horizontal, vertical
    GenerateDistance: std.atomic.Value(packed struct { xz: u32, y: u32 }),

    ///the smallest level for general world generation
    SmallestLevel: i32 = 0,

    ///start, end
    levels: [2]i32,

    running: std.atomic.Value(bool),

    pub fn init(game: *@This(), allocator: std.mem.Allocator, secondary_allocator: std.mem.Allocator, window: *glfw.Window, game_path: std.fs.Dir) !void {
        game.game_arena = .init(secondary_allocator);
        errdefer game.game_arena.deinit();
        const worldConfigFile = try std.fs.cwd().openFile("config/WorldConfig.zon", .{ .mode = .read_only });
        defer worldConfigFile.close();
        const generatorConfigFile = try std.fs.cwd().openFile("config/GeneratorConfig.zon", .{ .mode = .read_only });
        defer generatorConfigFile.close();

        const MainWorldConfig = try utils.loadZON(World.WorldConfig, worldConfigFile, secondary_allocator, game.game_arena.allocator());
        var GeneratorConfig = try utils.loadZON(World.DefaultGenerator.GenParams, generatorConfigFile, secondary_allocator, game.game_arena.allocator());

        GeneratorConfig.CaveNoise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 1));
        GeneratorConfig.TreeNoise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 2));
        GeneratorConfig.TerrainNoise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 3));
        GeneratorConfig.LargeTerrainNoise.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 4));
        GeneratorConfig.LargeTerrainNoiseWarp.seed = @bitCast(std.hash.Murmur2_32.hashUint64(GeneratorConfig.seed +% 4));

        const GenDist: [2]u32 = [2]u32{ 6, 6 };
        game.allocator = allocator;
        const terrain_height_cache_memory = 10_000_000; //10 mb
        const thc_size = @divFloor(terrain_height_cache_memory, @sizeOf(i32) * Chunk.ChunkSize * Chunk.ChunkSize);
        game.generator = World.DefaultGenerator{
            .TerrainHeightCache = try .init(secondary_allocator, thc_size),
            .params = GeneratorConfig,
        };
        game.levels = [2]i32{ 0, 10 };
        game_path.makeDir("RegionStorage") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        game.region_storage = .{
            .params = .{ .path = try game_path.openDir("RegionStorage", .{ .iterate = true }) },
        };
        errdefer game.generator.TerrainHeightCache.deinit();
        game.running = .init(true);
        game.GenerateDistance = .init(.{ .xz = GenDist[0], .y = GenDist[1] });
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
        errdefer game.world.Deinit();

        for (0..0) |_| {
            _ = try game.world.SpawnEntity(null, EntityTypes.Cube{
                .lock = .{},
                .pos = @splat(0),
                .velocity = @splat(0),
                .timestamp = std.time.microTimestamp(),
            });
        }

        game.player = try game.world.SpawnEntity(null, EntityTypes.Player{
            .player_name = .fromString("squid"),
            .physics = .{
                .elements = .{
                    .mover = .{
                        .collisions = true,
                        .boundingBox = .init(.{ -0.5, -2, -0.5 }, .{ 0.5, 2, 0.5 }),
                    },
                    .gravity = .{},
                },
                .pos = try game.world.GetPlayerSpawnPos(),
                .velocity = @splat(0),
                .updateTimer = try .start(),
            },
            .gameMode = .Spectator,
            .headRotationAxis = @Vector(2, f16){ 0, 0 },
        });
        game.chunkManager = .{
            .pool = &game.pool,
            .ChunkRenderList = .init(allocator),
            .LoadingChunks = .init(allocator),
            .MeshesToLoad = .init(allocator),
            .world = &game.world,
            .allocator = allocator,
        };
        game.renderer = try .init(allocator, game.player);
        try UserInput.init(game);
        _ = window.setCursorPosCallback(UserInput.MouseCallback);
    }

    pub fn getGenDistance(self: *@This()) @Vector(2, u32) {
        const dist = self.GenerateDistance.load(.monotonic);
        return .{ dist.xz, dist.y };
    }

    pub fn getRenderDistance(self: *@This()) @Vector(2, u32) {
        return self.getGenDistance() + @Vector(2, u32){ 2, 2 };
    }

    pub fn getInnerGenRadius(self: *@This(), level: i32) @Vector(2, u32) {
        if (level <= World.StandardLevel) return @splat(0);
        const inner_radius = self.getGenDistance() / @Vector(2, u32){ World.TreeDivisions, World.TreeDivisions };
        return inner_radius -| @Vector(2, u32){ 1, 1 }; //subtract 1 so their is one chunk of overlap
    }

    pub fn getInnerRenderRadius(self: *@This(), level: i32) @Vector(2, u32) {
        return self.getInnerGenRadius(level) -| @Vector(2, u32){ 1, 1 };
    }

    pub fn Frame(self: *@This(), viewport_pixels: @Vector(2, f32), viewport_millimeters: @Vector(2, f32), window: *glfw.Window) ![2]u64 {
        try UserInput.processInput(window);
        const r = try self.renderer.Draw(self, viewport_pixels);
        UserInput.menuDraw(viewport_pixels, viewport_millimeters, window);
        return r;
    }

    pub fn deinit(self: *@This(), window: *glfw.Window) void {
        self.running.store(false, .monotonic);
        self.world.stop();
        if (self.loaderThread) |thread| thread.join();
        if (self.unloaderThread) |thread| thread.join();

        std.log.info("stopped threads", .{});
        _ = window.setCursorPosCallback(null);

        UserInput.deinit();
        self.renderer.deinit();

        self.chunkManager.pool.deinit();
        std.log.info("closed threadpool", .{});

        const bktamount = self.chunkManager.ChunkRenderList.buckets.len;
        for (0..bktamount) |b| {
            self.chunkManager.ChunkRenderList.buckets[b].lock.lock();
            var it = self.chunkManager.ChunkRenderList.buckets[b].hash_map.valueIterator();
            defer self.chunkManager.ChunkRenderList.buckets[b].lock.unlock();
            while (it.next()) |mesh| {
                mesh.free();
            }
        }
        self.chunkManager.ChunkRenderList.deinit();
        self.chunkManager.LoadingChunks.deinit();
        while (self.chunkManager.MeshesToLoad.popFirst()) |mesh| {
            mesh.free(self.allocator);
        }
        self.chunkManager.MeshesToLoad.deinit(true);

        self.world.Deinit();

        self.game_arena.deinit();
    }

    pub fn startThreads(self: *@This()) !void {
        self.loaderThread = try std.Thread.spawn(.{}, Loader.ChunkLoaderThread, .{ self, 100 * std.time.ns_per_ms });
        self.unloaderThread = try std.Thread.spawn(.{}, World.ChunkUnloaderThread, .{ &self.world, 5000 * std.time.ns_per_ms, 10 * std.time.us_per_s });
        self.world.entityUpdaterThread = try std.Thread.spawn(.{}, World.UpdateEntitiesThread, .{ &self.world, 5 * std.time.ns_per_ms });
        self.chunkManager.world.onEdit = .{ .onEditFn = ChunkManager.onEditFn, .onEditFnArgs = @ptrCast(&self.chunkManager), .callIfNeighborFacesChanged = true };
    }
};
