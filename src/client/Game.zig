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
    game_arena: std.heap.ArenaAllocator,

    // Threads
    loaderThread: ?std.Thread,
    unloaderThread: ?std.Thread,

    // Distances
    MeshDistance: [3]std.atomic.Value(u32),
    GenerateDistance: [3]std.atomic.Value(u32),
    LoadDistance: [3]std.atomic.Value(u32),

    running: std.atomic.Value(bool),

    pub fn init(game: *@This(), allocator: std.mem.Allocator, secondary_allocator: std.mem.Allocator, window: *glfw.Window) !void {
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

        const GenDist: [2]u32 = if (builtin.mode == .Debug) [2]u32{ 10, 10 } else [2]u32{ 20, 20 }; //x,y
        const LoadDist: [2]u32 = if (builtin.mode == .Debug) [2]u32{ 12, 12 } else [2]u32{ 22, 22 }; //x,y
        const MeshDist: [2]u32 = if (builtin.mode == .Debug) [2]u32{ 12, 12 } else [2]u32{ 22, 22 }; //x,y

        game.allocator = allocator;
        game.generator = World.DefaultGenerator{
            .TerrainHeightCache = try .init(secondary_allocator, 4096),
            .params = GeneratorConfig,
        };
        errdefer game.generator.TerrainHeightCache.deinit();
        game.running = .init(true);
        game.GenerateDistance = [3]std.atomic.Value(u32){ std.atomic.Value(u32).init(GenDist[0]), std.atomic.Value(u32).init(GenDist[1]), std.atomic.Value(u32).init(GenDist[0]) };
        game.LoadDistance = [3]std.atomic.Value(u32){ std.atomic.Value(u32).init(LoadDist[0]), std.atomic.Value(u32).init(LoadDist[1]), std.atomic.Value(u32).init(LoadDist[0]) };
        game.MeshDistance = [3]std.atomic.Value(u32){ std.atomic.Value(u32).init(MeshDist[0]), std.atomic.Value(u32).init(MeshDist[1]), std.atomic.Value(u32).init(MeshDist[0]) };
        const cpu_count = try std.Thread.getCpuCount();
        try game.pool.init(.{ .n_jobs = cpu_count , .allocator = secondary_allocator });
        errdefer game.pool.deinit();
        game.world = .{
            .running = .init(true),
            .entityUpdaterThread = null,
            .allocator = allocator,
            .threadPool = &game.pool,
            .Entitys = .init(secondary_allocator),
            .Chunks = .init(secondary_allocator),
            .Config = MainWorldConfig,
            .ChunkSources = .{ null, null, null, game.generator.getGenerator() },
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
            .lock = .{},
            .gameMode = .Spectator,
            .OnGround = false,
            .pos = try game.world.GetPlayerSpawnPos() + @Vector(3, f64){ 0, 0, 0 },
            .bodyRotationAxis = @Vector(3, f16){ 0, 0, 0 },
            .headRotationAxis = @Vector(2, f16){ 0, 0 },
            .armSwings = [2]f16{ 0, 0 }, //right,left
            .hitboxmin = @Vector(3, f64){ -1, 0.8, -1 },
            .hitboxmax = @Vector(3, f64){ 1, 0.2, 1 },
            .Velocity = @splat(0),
        });
        game.chunkManager = .{
            .pool = &game.pool,
            .ChunkRenderList = .init(allocator),
            .LoadingChunks = ConcurrentHashMap([3]i32, bool, std.hash_map.AutoContext([3]i32), 80, 32).init(allocator),
            .MeshesToLoad = .init(allocator),
            .world = &game.world,
            .allocator = allocator,
        };
        game.renderer = try .init(allocator, game.player);
        try UserInput.init(game);
        _ = window.setCursorPosCallback(UserInput.MouseCallback);
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
        self.loaderThread = try std.Thread.spawn(.{}, Loader.Loader.ChunkLoaderThread, .{ self, 50 * std.time.ns_per_ms });
        self.unloaderThread = try std.Thread.spawn(.{}, Loader.Loader.ChunkUnloaderThread, .{ self, 50 * std.time.ns_per_ms });
        self.world.entityUpdaterThread = try std.Thread.spawn(.{}, World.UpdateEntitiesThread, .{ &self.world, 5 * std.time.ns_per_ms });
        self.chunkManager.world.onEdit = .{ .onEditFn = ChunkManager.onEditFn, .onEditFnArgs = @ptrCast(&self.chunkManager), .callIfNeighborFacesChanged = true };
    }
};
