const std = @import("std");
const root = @import("root");
const Game = @import("Game.zig").Game;
const World = @import("root").World;

const ChunkSize = @import("Chunk").Chunk.ChunkSize;
const EntityTypes = @import("EntityTypes");
const gl = @import("gl");
const glfw = @import("zglfw");
const gui = @import("gui");
const zm = @import("zm");
const ztracy = @import("ztracy");
const Renderer = @import("Renderer.zig").Renderer;
var game: *Game = undefined;
var worldEditor: World.WorldEditor = undefined;
var worldEditorLock: std.Thread.Mutex = .{};
var last_mouse_pos: [2]f64 = [2]f64{ 0, 0 };
var isinit = false;
const Menu = @import("menu.zig");
var menu: gui.Element = undefined;
var lastmicrotime: i64 = 0;
var lastfullscreentoggle: i64 = 0;
var lastbreak: i64 = 0;

var benchmarkStartTime: i64 = 0;
pub fn init(g: *Game) !void { //TODO move menu out of this and redo user input handeling
    game = g;
    worldEditor = .{
        .tempallocator = game.allocator,
        .world = &game.world,
    };
    lastmicrotime = std.time.microTimestamp();

    //menu is temporay test code
    menu = try gui.Element.create(std.heap.c_allocator, Menu.textEscMenu);
    menu.children.?[0].onHoverArgs = &ts;
    menu.children.?[1].onHoverArgs = &ts;
    std.debug.print("mo: {any}\n", .{menu.onHoverArgs});
    const viewport_pixels: @Vector(2, f32) = @splat(0);
    const viewport_millimeters: @Vector(2, f32) = @splat(0);
    menu.init(viewport_pixels, viewport_millimeters);
    @as(*gui.Widgets.SlideData, @ptrCast(@alignCast(menu.children.?[2].customData.?))).onSlide = OnSlide;
    isinit = true;
}

pub fn deinit() void {
    worldEditorLock.lock();
    _ = worldEditor.flush() catch |err| std.debug.panic("failed to deinit WorldEditor: {any}\n", .{err});
    worldEditorLock.unlock();

    menu.deinit();
    isinit = false;
}

fn OnSlide(slider: *gui.Element, slideData: *const gui.Widgets.SlideData, window: *glfw.Window) void {
    _ = slider;
    _ = window;
    var genDistf: @Vector(2, f32) = @Vector(2, f32){ 100, 100 };
    genDistf *= @splat(slideData.sliderPos);
    const genDist: @Vector(2, u32) = @intFromFloat(genDistf);
    game.GenerateDistance[0].store(genDist[0], .monotonic);
    game.GenerateDistance[1].store(genDist[1], .monotonic);
    game.GenerateDistance[2].store(genDist[0], .monotonic);
    game.LoadDistance[0].store(genDist[1] + 2, .monotonic);
    game.LoadDistance[1].store(genDist[0] + 2, .monotonic);
    game.LoadDistance[2].store(genDist[1] + 2, .monotonic);
    game.MeshDistance[0].store(genDist[0] + 2, .monotonic);
    game.MeshDistance[1].store(genDist[1] + 2, .monotonic);
    game.MeshDistance[2].store(genDist[0] + 2, .monotonic);
    std.debug.print("genDist: {d}\n", .{genDist});
}

pub const ToggleSettings = struct {
    Fullscreen: bool,
    Sprinting: bool,
    SuperSpeed: bool,
    CursorEscaped: bool,
    Benchmark: bool,
};
var ts = ToggleSettings{
    .Fullscreen = false,
    .Sprinting = false,
    .SuperSpeed = false,
    .CursorEscaped = true,
    .Benchmark = false,
};
var slideamount: f32 = 0.5;
var childrenBuffer: [1]gui.Element.CreationOptions = undefined;

pub fn menuDraw(viewport_pixels: @Vector(2, f32), viewport_millimeters: @Vector(2, f32), window: *glfw.Window) void {
    if (ts.CursorEscaped) menu.Draw(viewport_pixels, viewport_millimeters, window);
}
pub fn processInput(window: *glfw.Window) !void {
    std.debug.assert(isinit);
    const timestamp = std.time.microTimestamp();
    const dt = timestamp - lastmicrotime;
    lastmicrotime = timestamp;
    var posAdjustment: @Vector(3, f64) = @splat(0);
    const player = @as(*EntityTypes.Player, @ptrCast(@alignCast(game.player.ptr)));
    defer {
        player.lock.lock();
        player.pos += posAdjustment;
        player.lock.unlock();
    }
    var cameraSpeed: @Vector(3, f64) = @Vector(3, f64){ 0.002, 0.002, 0.002 } * @as(@Vector(3, f64), @splat(@as(f64, @floatFromInt(dt)) * 0.01)); // adjust accordingly
    if (ts.Sprinting) {
        cameraSpeed *= @splat(8);
    }
    if (ts.SuperSpeed) {
        cameraSpeed *= @splat(32);
    }
    if (window.getKey(glfw.Key.w) == .press)
        posAdjustment += cameraSpeed * game.renderer.cameraFront;
    if (window.getKey(glfw.Key.s) == .press)
        posAdjustment -= cameraSpeed * game.renderer.cameraFront;
    if (window.getKey(glfw.Key.a) == .press) {
        const cross = zm.vec.cross(game.renderer.cameraFront, Renderer.cameraUp);
        if (@reduce(.Or, cross != @Vector(3, f64){ 0, 0, 0 }))
            posAdjustment -= zm.vec.normalize(cross) * cameraSpeed;
    }
    if (window.getKey(glfw.Key.d) == .press) {
        const cross = zm.vec.cross(game.renderer.cameraFront, Renderer.cameraUp);
        if (@reduce(.Or, cross != @Vector(3, f64){ 0, 0, 0 }))
            posAdjustment += zm.vec.normalize(cross) * cameraSpeed;
    }
    if (window.getKey(glfw.Key.F11) == .press and std.time.milliTimestamp() - lastfullscreentoggle > 500) {
        if (ts.Fullscreen) {
            window.setMonitor(null, 0, 0, 800, 600, 0); //TODO make it choose the correct moniter and have the right size
            ts.Fullscreen = false;
            lastfullscreentoggle = std.time.milliTimestamp();
        } else {
            const mon = glfw.getPrimaryMonitor().?;
            const dim = try mon.getPhysicalSize();
            window.setMonitor(mon, 0, 0, dim[0], dim[1], 0);
            ts.Fullscreen = true;
            lastfullscreentoggle = std.time.milliTimestamp();
        }
    }
    if (window.getKey(glfw.Key.escape) == .press or window.getKey(glfw.Key.left_super) == .press) {
        if (!ts.CursorEscaped) {
            ts.CursorEscaped = true;
            _ = try glfw.Window.setInputMode(window, glfw.InputMode.cursor, .normal);
        }
    }
    if (window.getKey(glfw.Key.left_control) == .press) {
        ts.Sprinting = true;
    } else ts.Sprinting = false;
    if (window.getKey(glfw.Key.left_shift) == .press) {
        ts.SuperSpeed = true;
    } else ts.SuperSpeed = false;
    if (window.getKey(glfw.Key.r) == .press)
        try game.chunkManager.AddChunkToRender(@divFloor(@as(@Vector(3, i32), @intFromFloat(game.player.getPos().?)), @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize }), true, true);

    if (window.getKey(glfw.Key.b) == .press) {
        if (std.time.microTimestamp() - lastbreak > 100 * std.time.us_per_ms) {
            try game.chunkManager.pool.spawn(placeSamplerSphereTask, .{game.player.getPos().?}, .High);
            lastbreak = std.time.microTimestamp();
        }
    }

    if (window.getKey(glfw.Key.f) == .press) {
        const cone = World.WorldEditor.Cone(f64).init(game.player.getPos().?, game.renderer.cameraFront, 1000, 100, 50);
        worldEditorLock.lock();
        try worldEditor.PlaceSamplerShape(.Stone, cone);
        _ = worldEditor.flush() catch |err| std.debug.panic("failed to clear WorldEditor: {any}\n", .{err});
        worldEditorLock.unlock();

        // _ = try game.world.SpawnEntity(null, EntityTypes.Explosive{.pos = game.player.GetPos().?, .velocity = game.renderer.cameraFront * @Vector(3, f64){100,100,100}, .timestamp = std.time.microTimestamp(), .explosionRadius = 32, .exploded = false,});
    }

    if (window.getKey(glfw.Key.g) == .press) {
        try game.chunkManager.pool.spawn(genFractalTask, .{}, .High);
    }

    if (window.getKey(glfw.Key.i) == .press) {
        const playerPos = game.player.getPos().?;
        const chpos: @Vector(3, i32) = @intFromFloat(@round(playerPos / @as(@Vector(3, f64), @splat(ChunkSize))));
        std.debug.print("inspected: {any}, data: {any}", .{ chpos, game.chunkManager.world.Chunks.get(chpos) });
        std.debug.print("cameraFront: {any}, cameraUp: {any}\n", .{ game.renderer.cameraFront, Renderer.cameraUp });
        worldEditorLock.lock();
        defer worldEditorLock.unlock();
        std.debug.print("block: {any}\n", .{worldEditor.GetBlock(@intFromFloat(playerPos))});
        worldEditor.ClearReader();
    }
    if (window.getKey(glfw.Key.p) == .press) {
        ts.Benchmark = true;
        benchmarkStartTime = std.time.microTimestamp();
    }
    if (ts.Benchmark) {
        player.lock.lock();
        var t: f64 = @floatFromInt(std.time.microTimestamp() - benchmarkStartTime);
        const speedUpFactor = 0.000000000005; //the bigger this number is the faster the acceleration
        t *= ((t * speedUpFactor));
        const playerptr: *EntityTypes.Player = @ptrCast(@alignCast(game.player.ptr));
        playerptr.pos = std.math.lerp(playerptr.pos, game.chunkManager.world.Config.SpawnCenterPos + @Vector(3, f64){ t, @floatFromInt(100 + try game.chunkManager.world.GetTerrainHeightAtCoords(@Vector(2, i64){ @intFromFloat(game.chunkManager.world.Config.SpawnCenterPos[0] + t), @intFromFloat(game.chunkManager.world.Config.SpawnCenterPos[2]) })), 0.0 }, @Vector(3, f64){ 1, 0.2, 1 });
        const pos = playerptr.pos;
        player.lock.unlock();
        const chpos: @Vector(3, i32) = @intFromFloat(@round(pos / @as(@Vector(3, f64), @splat(ChunkSize))));
        if (game.chunkManager.world.Chunks.get(chpos) == null) {
            std.debug.print("benchmark finished, reached: {d}, chunk: {d}\n", .{ (t), chpos });
            std.debug.print("ended on: {any}, data: {any}", .{ (chpos), game.chunkManager.world.Chunks.get(chpos) });
            ts.Benchmark = false;
        }
    }
    if (window.getKey(glfw.Key.end) == .press) {
        ts.Benchmark = false;
    }
}

fn placeSamplerSphereTask(pos: @Vector(3, f64)) void {
    const noise = World.DefaultGenerator.Noise.Noise(f32){
        .noise_type = .perlin,
        .frequency = 0.1,
    };
    worldEditorLock.lock();
    World.TexturedSphere.NoiseSphere(&worldEditor, pos, 128, 1.0, noise, .Air) catch |err| std.debug.panic("err: {any}\n", .{err});
    std.debug.print("placeing\n", .{});
    _ = worldEditor.flush() catch |err| std.debug.panic("failed to clear WorldEditor: {any}\n", .{err});
    worldEditorLock.unlock();
}

fn genFractalTask() void {
    comptime var csteps: [20]World.Tree.Step = undefined;
    comptime for (&csteps, 0..) |*step, r| {
        step.* = switch (r) {
            0 => World.Tree.Step{
                .lengthPercent = 1.0,
                .radiusPercent = 1.0,
                .branchCountMax = 32,
                .branchCountMin = 32,
                .branchRange = @Vector(3, f32){ 2, 2, 2 },
                .block = .Stone,
                .branchRandomness = 0.0,
            },
            1...21 => World.Tree.Step{
                .lengthPercent = 0.75,
                .radiusPercent = 0.5,
                .branchRange = @Vector(3, f32){ 0.3, 0.3, 0.3 },
                .block = .Stone,
                .branchCountMax = 3,
                .branchCountMin = 3,
                .branchRandomness = 0.0,
                .endBlock = .Snow,
            },
            else => unreachable,
        };
    };
    const steps = csteps;
    var random = std.Random.DefaultPrng.init(0);
    const tree = World.Tree{
        .pos = @intFromFloat(game.player.getPos().?),
        .baseRadius = 5,
        .rand = random.random(),
        .trunkHeight = 64,
        .maxRecursionDepth = 10,
        .leafSize = 0,
        .steps = &steps,
    };
    worldEditorLock.lock();
    defer worldEditorLock.unlock();
    _ = tree.place(&worldEditor) catch |err| std.debug.panic("failed to place tree: {any}\n", .{err});
    _ = worldEditor.flush() catch |err| std.debug.panic("failed to flush WorldEditor: {any}\n", .{err});
}

pub export fn MouseCallback(window: *glfw.Window, xpos: f64, ypos: f64) void {
    _ = window;
    std.debug.assert(isinit);
    if (ts.CursorEscaped) return;
    const xoffset: f64 = (xpos - last_mouse_pos[0]) * game.renderer.mouseSensitivity;
    const yoffset: f64 = (ypos - last_mouse_pos[1]) * game.renderer.mouseSensitivity;
    last_mouse_pos[0] = xpos;
    last_mouse_pos[1] = ypos;
    const player: *EntityTypes.Player = @ptrCast(@alignCast(game.player.ptr));
    player.lock.lock();
    var newHeadRotationAxis = player.headRotationAxis;
    var newBodyRotationAxis = player.bodyRotationAxis;
    newHeadRotationAxis -= @Vector(2, f32){ @floatCast(yoffset), @floatCast(xoffset) };
    newHeadRotationAxis[0] = @max(-89.99999, newHeadRotationAxis[0]);
    newHeadRotationAxis[0] = @min(89.99999, newHeadRotationAxis[0]);

    if (getDiff(@Vector(3, f32){ newHeadRotationAxis[0], newHeadRotationAxis[1], 0 }, newBodyRotationAxis) > 20) newBodyRotationAxis = @Vector(3, f32){ newHeadRotationAxis[0], newHeadRotationAxis[1], 0 }; //adjust degrees, currently at 20

    player.headRotationAxis = newHeadRotationAxis;
    player.bodyRotationAxis = newBodyRotationAxis;
    player.lock.unlock();

    var cameraFront: @Vector(3, f64) = undefined;
    cameraFront[0] = @floatCast(@sin(std.math.degreesToRadians(newHeadRotationAxis[1])) * @cos(std.math.degreesToRadians(newHeadRotationAxis[0])));
    cameraFront[1] = @floatCast(@sin(std.math.degreesToRadians(newHeadRotationAxis[0])));
    cameraFront[2] = @floatCast(@cos(std.math.degreesToRadians(newHeadRotationAxis[1])) * @cos(std.math.degreesToRadians(newHeadRotationAxis[0])));
    game.renderer.cameraFront = zm.vec.normalize(cameraFront);
}

fn getDiff(a: @Vector(3, f32), b: @Vector(3, f32)) f32 {
    var diff: f32 = 0;
    inline for (0..3) |i| {
        diff += @abs(a[i] - b[i]);
    }
    return diff;
}

pub fn GetViewportPixels(window: *glfw.Window) @Vector(2, f32) {
    return @Vector(2, f32){ (@as(f32, @floatFromInt(root.width)) * window.getContentScale()[0]), (@as(f32, @floatFromInt(root.height)) * window.getContentScale()[1]) };
}
