const std = @import("std");
const zudp = @import("zudp").Connection;
const Network = @import("Network");
const Requests = @import("Requests");
const zm = @import("zm");
const gl = @import("gl");
const glfw = @import("zglfw");
const ztracy = @import("ztracy");
const World = @import("World").World;
const Renderer = @import("Renderer.zig").Renderer;
const Entitys = @import("Entitys");
const Chunk = @import("Chunk").Chunk;
const Loader = @import("Loader.zig");
const UserInput = @import("UserInput.zig");
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Cache = @import("cache").Cache;
var lastx: f64 = undefined;
var lasty: f64 = undefined;
var cameraFront = @Vector(3, f64){ 0, 1, 0 };
var cameraUp = @Vector(3, f64){ 0, 1, 0 };
var pitch: f64 = 1;
var yaw: f64 = 1;
var height: u32 = 800;
var width: u32 = 600;

const op = Network.Options{
    .verify = true,
    .compress_sizel1 = 128,
    .compress_sizel2 = 511,
    .compress_sizel3 = 2047,
    .datasplitsize = 512,
    .rate_limit_bytes_second = null,
};

const Multyplayer = false;
//TODO list
//chunk loader thread(singleplayer and multiplayer)
//server world and server chunk load response
//player log into server, verify client ip
//player send all keyboard inputs to server at a configurable max rate, default maybie 144?
//server sends back updated player position so no hacking, player visually moves client side but gets corrected if move is wrong
//entitys
//need to redo physecs completely, trace player path, configurable gravity and each gas or liquid has its own propertys (not just air)
//finally do textures
//new trees
//AUTH server and fully functional multyplayer
//blockdata(hashmap with blockpos as key)
//GUI
//website for game

var running = std.atomic.Value(bool).init(true);

pub fn main() !void {
    var proc: gl.ProcTable = undefined;

    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer if (debug_allocator.deinit() == .leak) {
        std.debug.panic("mem leaked", .{});
    } else {
        std.debug.print("no leaks\n", .{});
    };
    //const allocator = debug_allocator.allocator();

    const allocator = debug_allocator.allocator();
    var sfa = std.heap.stackFallback(5000000, allocator);
    var sfalloc = std.heap.ThreadSafeAllocator{.child_allocator = sfa.get()};
    const cpu_count = try std.Thread.getCpuCount();
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .n_jobs = cpu_count-2, .allocator = sfalloc.allocator()});
    var MainWorld = World{
        .allocator = allocator,
        .threadPool = &pool,
        .TerrainHeightCache = try Cache([32][32]i32).init(sfalloc.allocator(), .{}),
        .TerrainHeightCacheMutex = .{},
        .Players = ConcurrentHashMap(u128, *Entitys.Player, std.hash_map.AutoContext(u128), 80, 32).init(sfalloc.allocator()),
        .Chunks = ConcurrentHashMap([3]i32, *Chunk, std.hash_map.AutoContext([3]i32), 80, 32).init(sfalloc.allocator()),
        .GenParams = .{
            .terrainmin = -100,
            .terrainmax = 256,
            .seed = 23,
            .TerrainNoise = .{
                .fractal_type = .ridged,
                .octaves = 10,
                .frequency = 0.01,
            },
        },
    };
    
    var renderer = try Renderer.Init(&pool, &MainWorld, &proc, @Vector(3, f64){ 0, 0, 0 }, allocator);
    const loaderThread = try std.Thread.spawn(.{}, Loader.ChunkLoaderThread, .{ &renderer, null, 40 * std.time.ns_per_ms, &running });
    defer {
        std.debug.print("started closing\n", .{});
        renderer.window.destroy();
        running.store(false, .monotonic);
        pool.deinit();
        std.debug.print("pool deinit\n", .{});
        loaderThread.join();
        std.debug.print("loaderThread stopped\n", .{});
        renderer.deinit();
        std.debug.print("renderer deinit\n", .{});
        MainWorld.Deinit() catch |err| std.debug.panic("error: {any}", err);
        std.debug.print("World Closed\n", .{});
    }
    UserInput.init(&renderer);
    
    _ = renderer.window.setCursorPosCallback(UserInput.MouseCallback);
    _ = renderer.window.setSizeCallback(UserInput.glfwSizeCallback);
    _ = try glfw.Window.setInputMode(renderer.window, glfw.InputMode.cursor, glfw.InputMode.ValueType(glfw.InputMode.cursor).disabled);
    var st = std.time.nanoTimestamp();
    while (!renderer.window.shouldClose()) {
        const loadmeshes = ztracy.ZoneNC(@src(), "loadmeshes", 2222111);
        try renderer.LoadMeshes(10000);
        loadmeshes.End();
        renderer.window.swapBuffers();
        glfw.pollEvents();
        UserInput.processInput();
        // std.debug.print("pos:{d}, front:{d}, up:{d}\n", .{ eyePos, cameraFront, cameraUp })
        const drawChunks = ztracy.ZoneNC(@src(), "DrawChunks", 24342);
        renderer.DrawChunks();
        drawChunks.End();
        st = std.time.nanoTimestamp();
    }
}

fn processInput(window: *glfw.Window, cameraPos: *@Vector(3, f64), camerafront: @Vector(3, f64), cameraup: @Vector(3, f64)) void {
    const cameraSpeed: @Vector(3, f64) = @splat(2); // adjust accordingly
    if (window.getKey(glfw.Key.w) == .press)
        cameraPos.* += cameraSpeed * camerafront;
    if (window.getKey(glfw.Key.s) == .press)
        cameraPos.* -= cameraSpeed * camerafront;
    if (window.getKey(glfw.Key.a) == .press)
        cameraPos.* -= zm.vec.normalize(zm.vec.cross(camerafront, cameraup)) * cameraSpeed;
    if (window.getKey(glfw.Key.d) == .press)
        cameraPos.* += zm.vec.normalize(zm.vec.cross(camerafront, cameraup)) * cameraSpeed;
}


pub fn MultiPlayerWorld() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer if (debug_allocator.deinit() == .leak) {
        std.debug.panic("mem leaked", .{});
    } else {};
    const allocator = debug_allocator.allocator();
    const cpu_count = try std.Thread.getCpuCount();
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .n_jobs = cpu_count, .allocator = allocator });
    defer pool.deinit();
    var client = try zudp.init("0.0.0.0", 0, allocator);

    defer client.deinit();
    try client.SpawnTimeoutManager(500 * std.time.us_per_ms, 5 * std.time.ns_per_ms, 5, null, false);
    try client.SpawnListener(Handler, &pool, 65536, 150);
    var buf: [Requests.Ping.max_buffer_size]u8 = undefined;
    const ping_req = Requests.Ping.make(.{ .referrer = "test12345", .referrer_len = 9 }, &buf);
    var buf2: [Requests.Unverifyed_Login.max_buffer_size]u8 = undefined;
    const login_req = Requests.Unverifyed_Login.make(.{
        .version = .Testing,
        .UUID = 0,
        .username_len = 13,
        .username = "banned player",
        .referrer_len = 9,
        .referrer = "127.0.0.1",
        .GenDistance = [2]u32{ 8, 8 },
    }, &buf2);

    while (true) {
        var bf: [32]u8 = undefined;
        const d = try std.io.getStdIn().reader().readUntilDelimiter(&bf, '\n');
        if (d.len == 0) continue;
        switch (d[0]) {
            'p' => try Network.SendPacket(.Ping, ping_req, op, Requests.Ping.max_buffer_size, &client, (try std.net.Address.parseIp("127.0.0.1", 22522)).any),
            'l' => try Network.SendPacket(.Unverifyed_Login, login_req, op, Requests.Unverifyed_Login.max_buffer_size, &client, (try std.net.Address.parseIp("127.0.0.1", 22522)).any),
            else => {},
        }
    }
    std.Thread.sleep(10000000000);
}

pub fn Handler(args: anytype, mem: []const u8, sender: *const std.posix.sockaddr) void {
    //const server: *zudp = args.server;
    _ = sender;
    _ = args;
    var receivebuffer: [524288]u8 = undefined;
    const p = Network.LoadPacket(mem, &receivebuffer) catch |err| {
        std.log.warn("voxelgame loadpacket error: {any}\n", .{err});
        return;
    };
    switch (p.pktType) {
        Requests.PacketType.Pong => {
            const pong = Requests.Pong.load(p.data) catch |err| {
                std.debug.print("err: {any}", .{err});
                return;
            };
            std.debug.print("Pong reiceved:\nversion:{any}, \nserver name: {s},\nMOTD:{s}\n\n", .{ pong.version, pong.server_name, pong.MOTD });
        },

        else => std.debug.print("invalid packettype reiceived\n", .{}),
    }
}


