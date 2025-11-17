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
var menu: gui.Element = undefined;
var lastmicrotime: i64 = 0;
var lastfullscreentoggle: i64 = 0;
var benchmarkStartTime: i64 = 0;
pub fn init(g: *Game) !void { //TODO move menu out of this and redo user input handeling
    game = g;
    worldEditor = .{
        .tempallocator = game.allocator,
        .world = &game.world,
    };
    lastmicrotime = std.time.microTimestamp();
    const textEscMenu = gui.Element.CreationOptions{
        .elementBackground = .{ .solid = .{ 0.8, 0.8, 0.8, 0.95 } },
        .position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 50 } },
        .size = .{
            .width = .{ .xPercent = 75 },
            .height = .{ .yPercent = 75 },
        },
        .cornerPixelRadii = @splat(.{ .pixels = 25 }),
        .children = &.{
            .{ //TODO move menu out of this and redo user input handeling
                .elementBackground = .{ .solid = .{ 0.8, 0.3, 0.3, 1 } },
                .position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 60 } },
                .size = .{
                    .width = .{ .xPercent = 60 },
                    .height = .{ .yPercent = 10 },
                },
                .textOptions = .{
                    .text = "Quit",
                    .scale = .{ .relative = 4 },
                    .startPosition = .{
                        .x = .{ .xPercent = 45 },
                        .y = .{ .yPercent = 100 },
                    },
                },
                .onHover = onHoverEsc,
                .cornerPixelRadii = @splat(.{ .pixels = 15 }),
            },
            .{ //TODO move menu out of this and redo user input handeling
                .elementBackground = .{ .solid = .{ 0.3, 0.8, 0.3, 1 } },
                .position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 80 } },
                .size = .{
                    .width = .{ .xPercent = 60 },
                    .height = .{ .yPercent = 10 },
                },
                .textOptions = .{
                    .text = "Back to Game",
                    .scale = .{ .relative = 4 },
                    .startPosition = .{
                        .x = .{ .xPercent = 35 },
                        .y = .{ .yPercent = 100 },
                    },
                },
                .onHover = onHoverC,
                .cornerPixelRadii = @splat(.{ .pixels = 15 }),
            },
            gui.Widgets.Slider(.{ //TODO move menu out of this and redo user input handeling
                .size = .{ .height = .{ .yPercent = 100 }, .width = .{ .pixels = 50 } },
                .centerPos = .{ .x = .{ .xPercent = 100, .pixels = -50 }, .y = .{ .yPercent = 50 } },
            }, &childrenBuffer, .y),
        },
    };
    //menu is temporay test code
    menu = try gui.Element.create(std.heap.c_allocator, textEscMenu);
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

fn onHoverEsc(element: *gui.Element, mouse_pos: [2]f64, window: *glfw.Window, toggle: bool) void {
    _ = mouse_pos;
    if (toggle) {
        element.options.size.height.pixels += 5;
        element.options.size.width.pixels += 5;
        element.options.elementBackground.solid += @Vector(4, f32){ 0.1, 0.1, 0.1, 0.0 };
        if (window.getMouseButton(glfw.MouseButton.left) == .press) {
            window.setShouldClose(true);
        }
        element.update();
    } else {
        element.options.size.height.pixels -= 5;
        element.options.size.width.pixels -= 5;
        element.options.elementBackground.solid -= @Vector(4, f32){ 0.1, 0.1, 0.1, 0.0 };
        element.update();
    }
}

fn onHoverC(element: *gui.Element, mouse_pos: [2]f64, window: *glfw.Window, toggle: bool) void {
    _ = mouse_pos;
    if (toggle) {
        element.options.size.width.pixels += 5;
        element.options.size.height.pixels += 5;

        element.options.elementBackground.solid += @Vector(4, f32){ 0.1, 0.1, 0.1, 0.0 };
        if (window.getMouseButton(glfw.MouseButton.left) == .press and ts.CursorEscaped) {
            ts.CursorEscaped = false;
            _ = glfw.Window.setInputMode(window, glfw.InputMode.cursor, glfw.InputMode.ValueType(glfw.InputMode.cursor).disabled) catch std.debug.panic("err cant set input mode\n", .{});
        }
        element.update();
    } else {
        element.options.size.width.pixels -= 5;
        element.options.size.height.pixels -= 5;

        element.options.elementBackground.solid -= @Vector(4, f32){ 0.1, 0.1, 0.1, 0.0 };
        element.update();
    }
}

const ToggleSettings = struct {
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
    defer {
        game.player.lock.lock();
        std.debug.assert(@reduce(.Or, posAdjustment == posAdjustment)); //posAdjustment is not NaN
        @as(*EntityTypes.Player, @ptrCast(@alignCast(game.player.ptr))).pos += posAdjustment;
        game.player.lock.unlock();
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
        try game.chunkManager.AddChunkToRender(@divFloor(@as(@Vector(3, i32), @intFromFloat(game.player.GetPos().?)), @Vector(3, i32){ ChunkSize, ChunkSize, ChunkSize }), true);

    if (window.getKey(glfw.Key.b) == .press) {
        //const cone = World.WorldEditor.Cone(f64).init(game.player.GetPos().?, game.renderer.cameraFront, 1000, 100, 50);
        //worldEditorLock.lock();
        //try worldEditor.PlaceSamplerShape(.Stone, cone);
        //_ = worldEditor.flush() catch |err| std.debug.panic("failed to clear WorldEditor: {any}\n", .{err});
        //worldEditorLock.unlock();
        //
        const noise = World.DefaultGenerator.Noise.Noise(f32){
            .noise_type = .perlin,
            .frequency = 0.1,
        };
        worldEditorLock.lock();
        try World.TexturedSphere.NoiseSphere(&worldEditor, game.player.GetPos().?, 128, 1.0, noise, .Air);
        std.debug.print("placeing\n", .{});
        _ = worldEditor.flush() catch |err| std.debug.panic("failed to clear WorldEditor: {any}\n", .{err});
        worldEditorLock.unlock();
    }

    if (window.getKey(glfw.Key.f) == .press) {
        const cone = World.WorldEditor.Cone(f64).init(game.player.GetPos().?, game.renderer.cameraFront, 1000, 100, 50);
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
        const playerPos = game.player.GetPos().?;
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
        game.player.lock.lock();
        var t: f64 = @floatFromInt(std.time.microTimestamp() - benchmarkStartTime);
        const speedUpFactor = 0.000000000005; //the bigger this number is the faster the acceleration
        t *= ((t * speedUpFactor));
        const playerptr: *EntityTypes.Player = @ptrCast(@alignCast(game.player.ptr));
        playerptr.pos = std.math.lerp(playerptr.pos, game.chunkManager.world.Config.SpawnCenterPos + @Vector(3, f64){ t, @floatFromInt(100 + try game.chunkManager.world.GetTerrainHeightAtCoords(@Vector(2, i64){ @intFromFloat(game.chunkManager.world.Config.SpawnCenterPos[0] + t), @intFromFloat(game.chunkManager.world.Config.SpawnCenterPos[2]) })), 0.0 }, @Vector(3, f64){ 1, 0.2, 1 });
        const pos = playerptr.pos;
        game.player.lock.unlock();
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
        .pos = @intFromFloat(game.player.GetPos().?),
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
    game.player.lock.lock();
    const player: *EntityTypes.Player = @ptrCast(@alignCast(game.player.ptr));
    var newHeadRotationAxis = player.headRotationAxis;
    var newBodyRotationAxis = player.bodyRotationAxis;
    newHeadRotationAxis -= @Vector(2, f32){ @floatCast(yoffset), @floatCast(xoffset) };
    newHeadRotationAxis[0] = @max(-89.99999, newHeadRotationAxis[0]);
    newHeadRotationAxis[0] = @min(89.99999, newHeadRotationAxis[0]);

    if (getDiff(@Vector(3, f32){ newHeadRotationAxis[0], newHeadRotationAxis[1], 0 }, newBodyRotationAxis) > 20) newBodyRotationAxis = @Vector(3, f32){ newHeadRotationAxis[0], newHeadRotationAxis[1], 0 }; //adjust degrees, currently at 20

    player.headRotationAxis = newHeadRotationAxis;
    player.bodyRotationAxis = newBodyRotationAxis;
    game.player.lock.unlock();

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
