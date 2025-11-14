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
    updateEntitiesThread: ?std.Thread,

    // Distances
    MeshDistance: [3]std.atomic.Value(u32),
    GenerateDistance: [3]std.atomic.Value(u32),
    LoadDistance: [3]std.atomic.Value(u32),

    running: std.atomic.Value(bool),

    pub fn init(game:*@This(), allocator: std.mem.Allocator, secondary_allocator: std.mem.Allocator) !void {
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
        try game.pool.init(.{ .n_jobs = cpu_count - 1, .allocator = secondary_allocator });
        errdefer game.pool.deinit();
        game.world = .{
            .allocator = allocator,
            .threadPool = &game.pool,
            .Entitys = .init(secondary_allocator),
            .Chunks = .init(secondary_allocator),
            .random = undefined,
            .prng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp())),
            .Config = MainWorldConfig,
            .Generator = game.generator.getGenerator(),
            .onEdit = null,
        };
        game.world.random = game.world.prng.random();
        errdefer game.world.Deinit();
        game.player = try game.world.SpawnEntity(null, EntityTypes.Player{
            .player_UUID = 0, //UUID 0 resurved for client
            .player_name = .fromString("squid"),
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
            .ChunkRenderList = std.AutoArrayHashMap([3]i32, Renderer.MeshBufferIDs).init(allocator),
            .ChunkRenderListLock = . {},
            .LoadingChunks = ConcurrentHashMap([3]i32, bool, std.hash_map.AutoContext([3]i32), 80, 32).init(allocator),
            .MeshesToLoad = .init(allocator),
            .world = &game.world,
            .MeshesToUnload = .init(allocator),
            .allocator = allocator,
        };
        game.renderer = try .init(allocator, game.player);
    }

    pub fn deinit(self: *@This()) void {
        self.running.store(false, .monotonic);
        if(self.updateEntitiesThread) |thread| thread.join();
        if(self.loaderThread) |thread| thread.join();
        if(self.unloaderThread) |thread| thread.join();
        std.log.info("stopped threads", .{});

        self.renderer.deinit();

        self.chunkManager.pool.deinit();
        std.log.info("closed threadpool", .{});

        self.chunkManager.ChunkRenderListLock.lock();
        var it = self.chunkManager.ChunkRenderList.iterator();
        while (it.next()) |mesh| {
            mesh.value_ptr.free();
        }
        self.chunkManager.ChunkRenderList.deinit();
        self.chunkManager.LoadingChunks.deinit();
        while (self.chunkManager.MeshesToLoad.popFirst()) |mesh| {
            mesh.free(self.allocator);
        }
        self.chunkManager.MeshesToLoad.deinit(true);
        self.chunkManager.MeshesToUnload.deinit(true);

        self.world.Deinit();

        self.game_arena.deinit();
    }

    pub fn startThreads(self: *@This()) !void {
        self.loaderThread = try std.Thread.spawn(.{}, Loader.Loader.ChunkLoaderThread, .{ self, 40 * std.time.ns_per_ms });
        self.unloaderThread = try std.Thread.spawn(.{}, Loader.Loader.ChunkUnloaderThread, .{ self, 5 * std.time.ns_per_ms });
        self.updateEntitiesThread = try std.Thread.spawn(.{}, Entity.TickEntitiesThread, .{ &self.world, 5 * std.time.ns_per_ms, &self.running });
        self.chunkManager.world.onEdit = .{ .onEditFn = ChunkManager.onEditFn, .onEditFnArgs = @ptrCast(&self.chunkManager) };
    }
};