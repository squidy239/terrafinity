const std = @import("std");
const zudp = @import("zudp").Connection;
const Network = @import("Network");
const Requests = @import("Requests");
const zm = @import("zm");
const gl = @import("gl");
const glfw = @import("zglfw");
const World = @import("World").World;
const Renderer = @import("Renderer.zig").Renderer;
const Entitys = @import("Entitys");
const Chunk = @import("Chunk").Chunk;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Cache = @import("cache").Cache;
var lastx: f64 = undefined;
var lasty: f64 = undefined;
var eyePos = @Vector(3, f64){ 0, 0, 0 };
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

pub fn main() !void {
    var proc: gl.ProcTable = undefined;

    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer if (debug_allocator.deinit() == .leak) {
        std.debug.panic("mem leaked", .{});
    } else {
        std.debug.print("no leaks\n", .{});
    };
    const allocator = debug_allocator.allocator();
    const cpu_count = try std.Thread.getCpuCount();
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .n_jobs = cpu_count, .allocator = allocator });
    defer pool.deinit();
    var MainWorld = World{
        .allocator = allocator,
        .threadPool = &pool,
        .TerrainHeightCache = try Cache([32][32]i32).init(allocator, .{}),
        .TerrainHeightCacheMutex = .{},
        .Players = ConcurrentHashMap(u128, *Entitys.Player, std.hash_map.AutoContext(u128), 80, 32).init(allocator),
        .Chunks = ConcurrentHashMap([3]i32, *Chunk, std.hash_map.AutoContext([3]i32), 80, 32).init(allocator),
        .GenParams = .{
            .terrainmin = 0,
            .terrainmax = 32,
            .seed = 23,
            .TerrainNoise = .{
                .fractal_type = .ridged,
                .octaves = 10,
                .frequency = 0.01,
            },
        },
    };
    defer MainWorld.Deinit() catch |err| std.debug.panic("error: {any}", err);
    try MainWorld.AddPlayer(0, .{
        .GenDistance = [3]u32{ 20, 20, 20 },
        .pos = @Vector(3, f64){ 0.0, 0.0, 0.0 },
        .Movement = @Vector(3, f64){ 0.0, 0.0, 0.0 },
        .ref_count = .init(1),
        .lock = .{},
        .OnGround = false,
        .gameMode = .Spectator,
        .ip = null,
        .inWater = false,
        .pitch = 0,
        .eyepitch = 0,
        .eyeroll = 0,
        .eyeyaw = 0,
        .yaw = 0,
        .roll = 0,
        .speed = @Vector(3, f64){ 0.0, 0.0, 0.0 },
        .player_UUID = 0,
        .player_name = "squid",
        .hitboxmin = @Vector(3, f64){ 0.3, 2.0, 0.3 },
        .hitboxmax = @Vector(3, f64){ 0.3, 0.3, 0.3 },
    });
    var renderer = try Renderer.Init(&pool, &MainWorld, &proc, allocator);
    _ = renderer.window.setCursorPosCallback(MouseCallback);
    _ = renderer.window.setSizeCallback(glfwSizeCallback);
    gl.Enable(gl.DEPTH_TEST);
    //gl.Enable(gl.CULL_FACE);
    gl.CullFace(gl.BACK);
    gl.FrontFace(gl.CW);
    gl.DepthFunc(gl.LESS);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    _ = try glfw.Window.setInputMode(renderer.window, glfw.InputMode.cursor, glfw.InputMode.ValueType(glfw.InputMode.cursor).disabled);

    var x: i32 = -32;
    var y: i32 = -32;
    var z: i32 = -32;
    while (x < 32) {
        while (y < 32) {
            while (z < 32) {
                try pool.spawn(Renderer.AddChunkToRenderNoError, .{ &renderer, [3]i32{ x, y, z } });
                z += 1;
            }
            z = -32;
            y += 1;
        }
        y = -32;
        x += 1;
    }
    std.debug.print("b", .{});
    var st = std.time.nanoTimestamp();
    while (!renderer.window.shouldClose()) {
        try renderer.LoadMeshes(100);
        renderer.window.swapBuffers();
        glfw.pollEvents();
        processInput(renderer.window, &eyePos, cameraFront, cameraUp);
        // std.debug.print("pos:{d}, front:{d}, up:{d}\n", .{ eyePos, cameraFront, cameraUp })

        renderer.DrawChunks(.{ .eyePos = eyePos, .cameraFront = cameraFront, .cameraUp = cameraUp });
        st = std.time.nanoTimestamp();
    }
}

fn processInput(window: *glfw.Window, cameraPos: *@Vector(3, f64), camerafront: @Vector(3, f64), cameraup: @Vector(3, f64)) void {
    const cameraSpeed: @Vector(3, f64) = @splat(0.5); // adjust accordingly
    if (window.getKey(glfw.Key.w) == .press)
        cameraPos.* += cameraSpeed * camerafront;
    if (window.getKey(glfw.Key.s) == .press)
        cameraPos.* -= cameraSpeed * camerafront;
    if (window.getKey(glfw.Key.a) == .press)
        cameraPos.* -= zm.vec.normalize(zm.vec.cross(camerafront, cameraup)) * cameraSpeed;
    if (window.getKey(glfw.Key.d) == .press)
        cameraPos.* += zm.vec.normalize(zm.vec.cross(camerafront, cameraup)) * cameraSpeed;
}

export fn MouseCallback(window: *glfw.Window, xpos: f64, ypos: f64) void {
    _ = window;
    const sensitivity = 0.1;
    const yoffset = (ypos - lasty) * sensitivity;
    const xoffset = (xpos - lastx) * sensitivity;
    //std.debug.print("yo:{d},xo:{d},xpos:{d},ypos:{d}\n", .{ xoffset, yoffset, ypos, xpos });
    lastx = xpos;
    lasty = ypos;
    yaw -= @floatCast(xoffset);
    pitch -= @floatCast(yoffset);
    //  std.debug.print("p:{d},y:{d}\n", .{ pitch, yaw });
    if (pitch > 89.9)
        pitch = 89.9;
    if (pitch < -89.9)
        pitch = -89.9;
    cameraFront[0] = @floatCast(@sin(std.math.degreesToRadians(yaw)) * @cos(std.math.degreesToRadians(pitch)));
    cameraFront[1] = @floatCast(@sin(std.math.degreesToRadians(pitch)));
    cameraFront[2] = @floatCast(@cos(std.math.degreesToRadians(yaw)) * @cos(std.math.degreesToRadians(pitch)));

    cameraFront = zm.vec.normalize(cameraFront);
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

export fn glfwSizeCallback(window: *glfw.Window, w: c_int, h: c_int) void {
    width = @intCast(w);
    height = @intCast(h);
    gl.Viewport(0, 0, @intCast(w), @intCast(h));
    _ = window;
}
