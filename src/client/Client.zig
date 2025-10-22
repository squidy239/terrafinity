const std = @import("std");
const builtin = @import("builtin");

pub const Block = @import("Block").Blocks;
pub const Cache = @import("Cache").Cache;
pub const Chunk = @import("Chunk").Chunk;
pub const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Entity = @import("Entity").Entity;
const EntityTypes = @import("EntityTypes");
const gl = @import("gl");
pub const ConcurrentQueue = @import("ConcurrentQueue");
const glfw = @import("zglfw");
pub const SetThreadPriority = @import("ThreadPriority").setThreadPriority;
pub const ThreadPool = @import("ThreadPool");
const UpdateEntitiesThread = @import("Entity").TickEntitiesThread;
pub const World = @import("World").World;
pub const zm = @import("zm");
pub const ztracy = @import("ztracy");
pub const Loader = @import("Loader.zig");
pub const Renderer = @import("Renderer.zig").Renderer;
pub const menu = @import("menu.zig");
const UserInput = @import("UserInput.zig");
const ChunkSize = Chunk.ChunkSize;
pub const gui = @import("gui");
var lastx: f64 = undefined;
var lasty: f64 = undefined;
var cameraFront = @Vector(3, f64){ 0, 1, 0 };
var cameraUp = @Vector(3, f64){ 0, 1, 0 };
var pitch: f64 = 1;
var yaw: f64 = 1;
var height: u32 = 800;
var width: u32 = 600;

var running = std.atomic.Value(bool).init(true);

pub fn main() !void {
    var proc: gl.ProcTable = undefined;
    var main_debug_allocator = std.heap.DebugAllocator(.{ .backing_allocator_zeroes = false }).init;
    var secondary_debug_allocator = std.heap.DebugAllocator(.{ .backing_allocator_zeroes = false }).init;
    defer if (main_debug_allocator.deinit() == .leak or secondary_debug_allocator.deinit() == .leak) {
        std.debug.panic("mem leaked", .{});
    } else {
        std.debug.print("no leaks\n", .{});
    };
    const prioritySet = SetThreadPriority(.THREAD_PRIORITY_REALTIME);
    if (prioritySet) std.debug.print("Render thread priority set\n", .{}) else std.debug.print("Could not set render thread priority\n", .{});
    const smp_allocator = std.heap.smp_allocator;
    const allocator = if (builtin.mode == .ReleaseFast) smp_allocator else main_debug_allocator.allocator();
    const secondary_allocator = if (builtin.mode == .ReleaseFast) smp_allocator else secondary_debug_allocator.allocator();
    const cpu_count = try std.Thread.getCpuCount();
    var pool: ThreadPool = undefined;
    try pool.init(.{ .n_jobs = cpu_count - 1, .allocator = secondary_allocator });
    var rand = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    const seed = 0;
    std.log.info("using seed {d}\n", .{seed});
    var MainWorld = World{
        .allocator = allocator,
        .threadPool = &pool,
        .TerrainHeightCache = try Cache([2]i32, [ChunkSize][ChunkSize]i32, 8192).init(secondary_allocator),
        .Entitys = ConcurrentHashMap(u128, *Entity, std.hash_map.AutoContext(u128), 80, 32).init(secondary_allocator),
        .Chunks = ConcurrentHashMap([3]i32, *Chunk, std.hash_map.AutoContext([3]i32), 80, 32).init(secondary_allocator),
        .SpawnRange = 0,
        .SpawnCenterPos = [3]i32{ 5333, 0, -5333 }, //5333, -5333 is the mountain
        .Rand = rand.random(),
        .GenParams = .{
            .terrainmin = -1024,
            .terrainmax = 5192,
            .seed = seed,
            .SeaLevel = 0,
            .terrainblockRandomness = 0.125,
            .TerrainNoise = .{
                .seed = @bitCast(std.hash.Murmur2_32.hashUint64(seed)),
                .fractal_type = .ridged,
                .octaves = 12,
                .noise_type = .perlin,
                .frequency = 0.003,
            },
            .terrainNoiseBalance = 0.5, //0 is TerrainNoise, 1 is LargeTerrainNoise
            .LargeTerrainNoise = .{
                .seed = @bitCast(std.hash.Murmur2_32.hashUint64(seed)),
                .fractal_type = .ping_pong,
                .octaves = 1,
                .noise_type = .value_cubic,
                .frequency = 0.005,
            },
            .CaveNoise = .{
                .seed = @bitCast(std.hash.Murmur2_32.hashUint64(seed)),
                .fractal_type = .ping_pong,
                .octaves = 8,
                .lacunarity = 2,
                .ping_pong_strength = 2.0,
                .gain = 0.5,
                .noise_type = .perlin,
                .frequency = 0.03,
            },
            .CaveExpansionMax = 4000,
            .CaveExpansionStart = undefined, //TODO
            .Cavesess = -0.7,
        },
    };
    const tempPlayer: EntityTypes.Player = .{
        .player_UUID = 0, //UUID 0 resurved for client
        .player_name = .fromString("squid"),
        .gameMode = .Spectator,
        .OnGround = false,
        .pos = MainWorld.GetPlayerSpawnPos() + @Vector(3, f64){ 0, 0, 0 },
        .bodyRotationAxis = @Vector(3, f16){ 0, 0, 0 },
        .headRotationAxis = @Vector(2, f16){ 0, 0 },
        .armSwings = [2]f16{ 0, 0 }, //right,left
        .hitboxmin = @Vector(3, f64){ -1, 0.8, -1 },
        .hitboxmax = @Vector(3, f64){ 1, 0.2, 1 },
        .Velocity = @splat(0),
    };
    const playerEntity = try tempPlayer.MakeEntity(allocator);

    for (0..0) |_| {
        const tempCube: EntityTypes.Cube = .{
            .velocity = @splat(0),
            .bodyRotationAxis = @splat(0),
            .pos = tempPlayer.pos,
            .timestamp = std.time.microTimestamp(),
        };
        _ = try MainWorld.SpawnEntity(rand.random().int(u128), tempCube);
    }
    const player = @as(*EntityTypes.Player, @ptrCast(@alignCast(playerEntity.ptr)));
    _ = playerEntity.ref_count.fetchAdd(1, .seq_cst);
    try MainWorld.Entitys.put(World.PlayerIDtoEntityId(player.player_UUID), playerEntity);
    _ = playerEntity.ref_count.fetchAdd(1, .seq_cst);
    const window = try InitWindowAndProcs(&proc);
    var renderer = Renderer.Init(&pool, &MainWorld, &proc, &running, player, &playerEntity.lock, allocator) catch |err| {
        std.debug.panic("Failed to initialize renderer: {}\n", .{err});
        return err;
    };
    renderer.window = window;
    try EntityTypes.LoadMeshes(allocator);
    const unloaderThread = try std.Thread.spawn(.{}, Loader.ChunkUnloaderThread, .{ &MainWorld, &renderer.LoadDistance, &player.pos, &playerEntity.lock, 5 * std.time.ns_per_ms, &running });
    const loaderThread = try std.Thread.spawn(.{}, Loader.ChunkLoaderThread, .{ &renderer, 40 * std.time.ns_per_ms, &player.pos, &playerEntity.lock, &running });
    const updateEntitiesThread = try std.Thread.spawn(.{}, UpdateEntitiesThread, .{ &MainWorld, 5 * std.time.ns_per_ms, &running });

    defer {
        std.debug.print("started closing\n", .{});
        running.store(false, .monotonic);
        UserInput.deinit();
        updateEntitiesThread.join();
        std.debug.print("entity update thread stopped\n", .{});
        loaderThread.join();
        unloaderThread.join();
        std.debug.print("loader and unloader threads stopped\n", .{});
        pool.deinit();
        std.debug.print("pool deinit\n", .{});
        EntityTypes.FreeMeshes();
        renderer.deinit();
        glfw.terminate();
        _ = playerEntity.ref_count.fetchSub(1, .seq_cst);
        std.debug.print("renderer deinit\n", .{});
        _ = playerEntity.ref_count.fetchSub(1, .seq_cst);
        MainWorld.Deinit() catch |err| std.debug.panic("error: {any}", .{err});
        std.debug.print("World Closed\n", .{});
        renderer.window.destroy();
        glfw.pollEvents(); //must be called to close the window
    }

    try UserInput.init(&renderer);
    _ = renderer.window.setCursorPosCallback(UserInput.MouseCallback);
    _ = renderer.window.setSizeCallback(UserInput.glfwSizeCallback);
    var st = std.time.nanoTimestamp();
    gui.init(secondary_allocator);
    defer gui.deinit();

    var f3t: bool = true;
    var f3noholdt: bool = true;

    var fpsBox = try gui.Element.create(allocator, menu.fpsoptions);
    const viewport_pixels: @Vector(2, f32) = @floatFromInt(@as(@Vector(2, u32), renderer.GetScreenDimensions()));
    const viewport_millimeters: @Vector(2, f32) = @floatFromInt(@as(@Vector(2, i32), try glfw.getPrimaryMonitor().?.getPhysicalSize()));
    fpsBox.init(viewport_pixels, viewport_millimeters);
    defer fpsBox.deinit();
    var lastFps: ?f128 = null;
    while (!renderer.window.shouldClose()) {
        const Frame = ztracy.ZoneNC(@src(), "Frame", 0xFFFFFFFF);
        defer Frame.End();
        const frameStart = std.time.nanoTimestamp();
        const waitforlock = ztracy.ZoneNC(@src(), "waitforlock", 2222111);
        playerEntity.lock.lockShared();
        const playerPos = player.pos;
        playerEntity.lock.unlockShared();
        waitforlock.End();
        //draw chunks
        const blueSky = @Vector(4, f32){ 0, 0.4, 0.8, 1.0 };
        const greySky = @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 };
        const skyColor = std.math.lerp(blueSky, greySky, @as(@Vector(4, f32), @splat(@as(f32, @floatCast(@min(1.0, @max(0, playerPos[1] / 4096)))))));
        const clear = ztracy.ZoneNC(@src(), "Clear", 32213);
        gl.ClearColor(skyColor[0], skyColor[1], skyColor[2], skyColor[3]);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.Clear(gl.DEPTH_BUFFER_BIT);
        clear.End();
        gl.UseProgram(renderer.shaderprogram);

        const drawChunks = ztracy.ZoneNC(@src(), "DrawChunks", 24342);
        const drawn = renderer.DrawChunks(playerPos, skyColor);
        drawChunks.End();
        const drawEntities = ztracy.ZoneNC(@src(), "drawEntities", 24342);
        renderer.DrawEntities(playerPos);
        drawEntities.End();
        const viewport_pixels_loop: @Vector(2, f32) = @floatFromInt(@as(@Vector(2, u32), renderer.GetScreenDimensions()));
        const viewport_millimeters_loop: @Vector(2, f32) = @floatFromInt(@as(@Vector(2, i32), try glfw.getPrimaryMonitor().?.getPhysicalSize()));
        if (f3t) fpsBox.Draw(viewport_pixels_loop, viewport_millimeters_loop, renderer.window);
        UserInput.menuDraw(viewport_pixels_loop, viewport_millimeters_loop);
        const drawText = ztracy.ZoneNC(@src(), "DrawLargeText", 24342);
        drawText.End();
        //unload meshes
        const meshDistance = [3]u32{ renderer.MeshDistance[0].load(.seq_cst), renderer.MeshDistance[1].load(.seq_cst), renderer.MeshDistance[2].load(.seq_cst) };
        const floatPlayerChunkPos = playerPos / @as(@Vector(3, f64), @splat(ChunkSize));
        const playerChunkPos = @as(@Vector(3, i32), @intFromFloat(floatPlayerChunkPos));
        const unloadMeshes = ztracy.ZoneNC(@src(), "unloadMeshes", 54333);
        renderer.UnloadMeshes(meshDistance, playerChunkPos);
        unloadMeshes.End();
        const printpos = @round(playerPos * @Vector(3, f64){ 100, 100, 100 }) / @Vector(3, f64){ 100, 100, 100 };
        st = std.time.nanoTimestamp();

        {
            const glSync = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0) orelse {
                return error.FailedToCreateGLSync;
            };
            defer gl.DeleteSync(glSync);
            _ = try renderer.LoadMeshes(glSync, 1 * std.time.us_per_ms, 20 * std.time.us_per_ms);
        }
        const swap = ztracy.ZoneNC(@src(), "swap", 456564);
        renderer.window.swapBuffers();
        swap.End();
        const poll = ztracy.ZoneNC(@src(), "poll", 456564);
        glfw.pollEvents();
        poll.End();
        const prossesinput = ztracy.ZoneNC(@src(), "prossesinput", 456765);
        try UserInput.processInput();
        if (glfw.getKey(renderer.window, glfw.Key.F3) == .press) {
            if (f3noholdt) f3t = !f3t;
            f3noholdt = false;
        } else f3noholdt = true; //TODO use this toggle type for fullscreen and other toggle settings
        prossesinput.End();
        var fps = (std.time.ns_per_s / @as(f128, @floatFromInt(std.time.nanoTimestamp() - frameStart)));
        if (lastFps != null) fps = std.math.lerp(fps, lastFps.?, 0.90);
        lastFps = fps;
        const printText = try std.fmt.allocPrint(secondary_allocator, "pos: {d}, {d}, {d}\nFPS: {d}\n{d}/{d} chunks drawn\ntotal chunks loaded: {d}\n", .{ printpos[0], printpos[1], printpos[2], @round(fps), drawn[0], drawn[1], MainWorld.Chunks.count() });
        defer secondary_allocator.free(printText);
        try fpsBox.options.text.?.SetText(printText);
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

fn OnHover(element: *gui.Element, mouse_pos: [2]f64, window: *glfw.Window, toggle: bool) void {
    _ = mouse_pos;
    if (!element.options.Visible) return;
    if (toggle) {
        if (window.getMouseButton(glfw.MouseButton.left) == .press) {
            //  element.options.size.widthPixels = 1;
            element.options.size.heightPixels += 16;
            element.options.position.yPixels += 8;
            element.update(element.screen_dimensions);
        }
    }
}

fn DeflateElement(element: *gui.Element, window: *glfw.Window) void {
    if (!element.options.Visible) return;
    const time = std.time.timestamp();
    const eid = (element.options.position.xPercent * 10 * 0.5);
    if (@rem(time, 5) == @as(i64, @intFromFloat((eid))) and window.getKey(glfw.Key.m) == .press) {
        element.options.size.heightPixels += 2;
        element.options.position.yPixels += 1;
        element.update(element.screen_dimensions);
    }
    const wp = element.options.size.widthPixels;
    const hp = element.options.size.heightPixels;
    const yp = element.options.position.yPixels;
    element.options.size.widthPixels = std.math.lerp(element.options.size.widthPixels, -10, 0.01);
    element.options.size.heightPixels = std.math.lerp(element.options.size.heightPixels, -10, 0.001);
    element.options.position.yPixels = std.math.lerp(element.options.position.yPixels, 0, 0.001);
    if (wp != element.options.size.widthPixels or hp != element.options.size.heightPixels or yp != element.options.position.yPixels) element.update(element.screen_dimensions);
}

fn InitWindowAndProcs(proc_table: *gl.ProcTable) !*glfw.Window {
    //try glfw.initHint(.platform, glfw.Platform.x11); //renderdoc wont work with wayland
    try glfw.init();
    std.debug.print("using: {s}\n", .{@tagName(glfw.getPlatform())});
    const gl_versions = [_][2]c_int{ [2]c_int{ 4, 6 }, [2]c_int{ 4, 5 }, [2]c_int{ 4, 4 }, [2]c_int{ 4, 3 }, [2]c_int{ 4, 2 }, [2]c_int{ 4, 1 }, [2]c_int{ 4, 0 }, [2]c_int{ 3, 3 } };
    var window: ?*glfw.Window = null;
    for (gl_versions) |version| {
        std.log.info("trying OpenGL version {d}.{d}\n", .{ version[0], version[1] });
        glfw.windowHint(.context_version_major, version[0]);
        glfw.windowHint(.context_version_minor, version[1]);
        glfw.windowHint(.opengl_forward_compat, true);
        glfw.windowHint(.client_api, .opengl_api);
        glfw.windowHint(.doublebuffer, true);
        glfw.windowHint(.samples, 8);
        window = glfw.Window.create(800, 600, "voxelgame", null) catch continue;
        glfw.makeContextCurrent(window);
        if (proc_table.init(glfw.getProcAddress)) {
            std.log.info("using OpenGL version {d}.{d}\n", .{ version[0], version[1] });
            break;
        } else {
            window.?.destroy();
        }
    }
    if (window == null) return error.FailedToCreateWindow;
    gl.makeProcTableCurrent(proc_table);
    const xz = window.?.getContentScale();
    gl.Enable(gl.MULTISAMPLE);
    gl.Viewport(0, 0, @intFromFloat(800 * xz[0]), @intFromFloat(600 * xz[1]));
    glfw.swapInterval(0);
    gl.Enable(gl.DEPTH_TEST);
    gl.Enable(gl.CULL_FACE);
    gl.CullFace(gl.BACK);
    gl.FrontFace(gl.CW);
    gl.DepthFunc(gl.LESS);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    return window.?;
}
