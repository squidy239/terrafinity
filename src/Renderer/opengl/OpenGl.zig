const std = @import("std");
const builtin = @import("builtin");

const ConcurrentHashMap = @import("../../libs/ConcurrentHashMap.zig").ConcurrentHashMap;
const gl = @import("gl");
const tracy = @import("tracy");
const wio = @import("wio");
const zm = @import("zm");

const setCallback = @import("../../main.zig").setCallback;
const Mesher = @import("../../Mesher.zig");
const Renderer = @import("../../Renderer.zig");
const World = @import("../../world/World.zig");
const ChunkSize = World.ChunkSize;
const ChunkPos = World.ChunkPos;
const Frustum = @import("Frustum.zig").Frustum;
const Textures = @import("textures.zig");

pub const cameraUp = @Vector(3, f64){ 0, 1, 0 };
const OpenGlRenderer = @This();

const RenderBufferKey = union(enum) {
    @"opaque": ChunkPos,
    transparent: ChunkPos,

    pub fn toPos(self: RenderBufferKey) ChunkPos {
        return switch (self) {
            .@"opaque" => |pos| pos,
            .transparent => |pos| pos,
        };
    }
};

allocator: std.mem.Allocator,
facebuffer: c_uint,
indecies: c_uint,
entityshaderprogram: c_uint,
shaderprogram: c_uint,
blockAtlasTextureId: c_uint,
vao: c_uint,
uniforms: UniformLocations,
cameraFront: @Vector(3, f32),
render_buffer: MultiRenderBuffer(RenderBufferKey),
interface: Renderer,
viewport_pixels: @Vector(2, u32),
window: *wio.Window,
gen_context_lock: std.Io.Mutex = .init,
contexts: std.ArrayList(wio.GlContext),
context_index: std.atomic.Value(usize) = .init(0),
proc_table: *const gl.ProcTable,
draw_context: wio.GlContext,
gl_options: wio.GlOptions,

fbo: c_uint,
color_texture: c_uint,
depth_texture: c_uint,

render_options: *RenderOptions,
render_options_lock: *std.Io.RwLock,

pub const RenderOptions = struct {
    draw_over: bool = false,
    fov: f32 = 90.0,
    day_length_sec: f32 = 60 * 5,
};

pub fn init(self: *@This(), io: std.Io, allocator: std.mem.Allocator, window: *wio.Window, gl_options: wio.GlOptions, share_context: *wio.GlContext, proc_table: *const gl.ProcTable, render_options: *RenderOptions, render_options_lock: *std.Io.RwLock) !void {
    const cpu_count = try std.Thread.getCpuCount();
    defer window.glMakeContextCurrent(share_context.*);
    self.* = @This(){
        .render_options = render_options,
        .render_options_lock = render_options_lock,
        .allocator = allocator,
        .gl_options = gl_options,
        .facebuffer = undefined,
        .indecies = undefined,
        .shaderprogram = undefined,
        .proc_table = proc_table,
        .render_buffer = .{ .allocator = allocator },
        .entityshaderprogram = undefined,
        .cameraFront = undefined,
        .vao = undefined,
        .window = window,
        .draw_context = try window.glCreateContext(.{ .options = gl_options, .share = share_context.* }),
        .blockAtlasTextureId = undefined,
        .uniforms = undefined,
        .viewport_pixels = .{ 0, 0 },
        .contexts = try .initCapacity(allocator, cpu_count),
        .fbo = undefined,
        .color_texture = undefined,
        .depth_texture = undefined,
        .interface = .{
            .userdata = @ptrCast(self),
            .vtable = &.{
                .addChunk = vtableAddChunk,
                .removeChunk = vtableRemoveChunk,
                .drawChunks = vtableDrawChunks,
                .clear = vtableClear,
                .setViewport = vtableSetViewport,
                .updateCameraDirection = vtableUpdateCameraDirection,
                .getCameraFront = vtableGetCameraFront,
                .forEachChunk = vtableForEachChunk,
            },
        },
    };
    self.window.glMakeContextCurrent(self.draw_context);
    gl.makeProcTableCurrent(self.proc_table);
    setCallback();

    //preallocate vram to prevent costly buffer resizes
    try self.render_buffer.buffer.ensureCapacity(io, 1024_000_000);
    try self.render_buffer.ssbo.ensureCapacity(io, 32_000_000);
    try self.render_buffer.indirect_buffer.ensureCapacity(io, 32_000_000);

    {
        //TODO better system for this
        const dir = try std.Io.Dir.cwd().createDirPathOpen(io, "packs/default/Blocks/", .{ .open_options = .{ .iterate = true } });
        defer dir.close(io);
        try dir.writeFile(io, .{ .data = @embedFile("Blocks/grass.png"), .sub_path = "grass.png" });
        try dir.writeFile(io, .{ .data = @embedFile("Blocks/dirt.png"), .sub_path = "dirt.png" });
        try dir.writeFile(io, .{ .data = @embedFile("Blocks/snow.png"), .sub_path = "snow.png" });
        try dir.writeFile(io, .{ .data = @embedFile("Blocks/stone.png"), .sub_path = "stone.png" });
        try dir.writeFile(io, .{ .data = @embedFile("Blocks/water.png"), .sub_path = "water.png" });
        try dir.writeFile(io, .{ .data = @embedFile("Blocks/wood.png"), .sub_path = "wood.png" });
        try dir.writeFile(io, .{ .data = @embedFile("Blocks/leaves.png"), .sub_path = "leaves.png" });

        self.blockAtlasTextureId = try Textures.loadTextureArray(io, dir, allocator);
    }

    //+1 for main thread, TODO threadlocal
    for (0..cpu_count + 1) |i| {
        try self.contexts.append(allocator, try window.glCreateContext(.{ .options = gl_options, .share = self.draw_context }));
        self.window.glMakeContextCurrent(self.contexts.items[i]);
        setCallback();
    }

    self.window.glMakeContextCurrent(self.draw_context);
    try self.compileShaders();
    self.uniforms = UniformLocations.GetLocations(self.shaderprogram, self.entityshaderprogram);
    gl.GenVertexArrays(1, @ptrCast(&self.vao));
    gl.BindVertexArray(self.vao);
    try self.loadFacebuffer();

    gl.BindBuffer(gl.ARRAY_BUFFER, self.facebuffer);
    gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(f32), 0);
    gl.EnableVertexAttribArray(0);
    gl.BindVertexArray(0);

    self.viewport_pixels = .{ 800, 600 };
    gl.Viewport(0, 0, 800, 600);
    self.setupFbo(800, 600);

    gl.Enable(gl.MULTISAMPLE);
    gl.Enable(gl.DEPTH_TEST);
    gl.Enable(gl.CULL_FACE);
    gl.CullFace(gl.BACK);
    gl.FrontFace(gl.CW);
    gl.DepthFunc(gl.GREATER);
    gl.ClipControl(gl.LOWER_LEFT, gl.ZERO_TO_ONE);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
}

pub fn deinit(self: *@This(), io: std.Io) void {
    gl.Finish();
    self.window.glMakeContextCurrent(self.draw_context);
    self.render_buffer.deinit(io, self.allocator);
    gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
    gl.DeleteTextures(1, @ptrCast(&self.blockAtlasTextureId));
    gl.DeleteBuffers(1, @ptrCast(&self.indecies));
    gl.DeleteBuffers(1, @ptrCast(&self.facebuffer));

    gl.DeleteFramebuffers(1, @ptrCast(&self.fbo));
    gl.DeleteTextures(1, @ptrCast(&self.color_texture));
    gl.DeleteTextures(1, @ptrCast(&self.depth_texture));

    gl.DeleteProgram(self.shaderprogram);
    gl.DeleteProgram(self.entityshaderprogram);

    self.context_index.store(0, .seq_cst);
    self.gen_context_lock.lockUncancelable(io);
    for (0..self.contexts.items.len) |i| {
        self.contexts.items[i].destroy();
    }
    self.gen_context_lock.unlock(io);
    self.contexts.deinit(self.allocator);
    self.draw_context.destroy();
    std.log.info("renderer deinit", .{});
}

fn setupFbo(self: *OpenGlRenderer, width: u32, height: u32) void {
    gl.CreateFramebuffers(1, @ptrCast(&self.fbo));
    const samples = @max(1, self.gl_options.samples);

    gl.CreateTextures(gl.TEXTURE_2D_MULTISAMPLE, 1, @ptrCast(&self.color_texture));
    gl.TextureStorage2DMultisample(self.color_texture, @intCast(samples), gl.RGBA8, @intCast(width), @intCast(height), gl.TRUE);

    gl.CreateTextures(gl.TEXTURE_2D_MULTISAMPLE, 1, @ptrCast(&self.depth_texture));
    gl.TextureStorage2DMultisample(self.depth_texture, @intCast(samples), gl.DEPTH_COMPONENT32F, @intCast(width), @intCast(height), gl.TRUE);

    gl.NamedFramebufferTexture(self.fbo, gl.COLOR_ATTACHMENT0, self.color_texture, 0);
    gl.NamedFramebufferTexture(self.fbo, gl.DEPTH_ATTACHMENT, self.depth_texture, 0);

    const status = gl.CheckNamedFramebufferStatus(self.fbo, gl.FRAMEBUFFER);
    if (status != gl.FRAMEBUFFER_COMPLETE) {
        std.log.err("Framebuffer incomplete: {X}", .{status});
    }
}

pub fn updateCameraDirection(self: *@This(), viewDir: @Vector(3, f32)) void {
    self.cameraFront[0] = @sin(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    self.cameraFront[1] = @sin(std.math.degreesToRadians(viewDir[0]));
    self.cameraFront[2] = @cos(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    self.cameraFront = zm.Vec3f.norm(.{ .data = self.cameraFront }).data;
}

fn vtableUpdateCameraDirection(userdata: *anyopaque, viewDir: @Vector(3, f32)) void {
    const self: *OpenGlRenderer = @ptrCast(@alignCast(userdata));
    return self.updateCameraDirection(viewDir);
}

fn vtableGetCameraFront(userdata: *anyopaque) @Vector(3, f32) {
    const self: *OpenGlRenderer = @ptrCast(@alignCast(userdata));
    return self.cameraFront;
}

fn vtableAddChunk(userdata: *anyopaque, io: std.Io, chunk_pos: ChunkPos, opaque_mesh: []const Mesher.Face, transparent_mesh: []const Mesher.Face) error{ OutOfMemory, OutOfVideoMemory, Unexpected }!void {
    const self: *OpenGlRenderer = @ptrCast(@alignCast(userdata));
    self.ensureContext() catch return error.Unexpected;

    if (opaque_mesh.len > 0) {
        self.render_buffer.put(io, .{ .@"opaque" = chunk_pos }, std.mem.sliceAsBytes(opaque_mesh)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OutOfVideoMemory,
        };
    } else self.render_buffer.remove(io, .{ .@"opaque" = chunk_pos });

    if (transparent_mesh.len > 0) {
        self.render_buffer.put(io, .{ .transparent = chunk_pos }, std.mem.sliceAsBytes(transparent_mesh)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OutOfVideoMemory,
        };
    } else self.render_buffer.remove(io, .{ .transparent = chunk_pos });
}

pub fn remove(self: *@This(), io: std.Io, chunk_pos: ChunkPos) void {
    self.render_buffer.remove(io, .{ .@"opaque" = chunk_pos });
    self.render_buffer.remove(io, .{ .transparent = chunk_pos });
}

fn vtableRemoveChunk(userdata: *anyopaque, io: std.Io, chunk_pos: ChunkPos) void {
    const self: *OpenGlRenderer = @ptrCast(@alignCast(userdata));
    return self.remove(io, chunk_pos);
}

threadlocal var thread_index: ?usize = null;

fn ensureContext(self: *@This()) !void {
    if (thread_index == null) {
        thread_index = self.context_index.fetchAdd(1, .seq_cst);
    }
    self.window.glMakeContextCurrent(self.contexts.items[thread_index.?]);
    gl.makeProcTableCurrent(self.proc_table);
}

fn vtableDrawChunks(userdata: *anyopaque, io: std.Io, viewpos: @Vector(3, f64)) error{DrawFailed}!void {
    const self: *OpenGlRenderer = @ptrCast(@alignCast(userdata));
    gl.makeProcTableCurrent(self.proc_table);
    self.window.glMakeContextCurrent(self.draw_context);
    gl.BindFramebuffer(gl.FRAMEBUFFER, self.fbo);
    (self.drawChunks(io, viewpos, .{ 32, 32, 32, 255 }, self.viewport_pixels)) catch return error.DrawFailed;

    gl.BlitNamedFramebuffer(
        self.fbo,
        0,
        0,
        0,
        @intCast(self.viewport_pixels[0]),
        @intCast(self.viewport_pixels[1]),
        0,
        0,
        @intCast(self.viewport_pixels[0]),
        @intCast(self.viewport_pixels[1]),
        gl.COLOR_BUFFER_BIT,
        gl.NEAREST,
    );
    gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
}

fn vtableClear(userdata: *anyopaque, viewpos: @Vector(3, f64)) error{DrawFailed}!void {
    const self: *OpenGlRenderer = @ptrCast(@alignCast(userdata));
    gl.makeProcTableCurrent(self.proc_table);
    self.window.glMakeContextCurrent(self.draw_context);
    gl.BindFramebuffer(gl.FRAMEBUFFER, self.fbo);
    const blueSky = @Vector(4, f32){ 0, 0.4, 0.8, 1.0 };
    const greySky = @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 };
    const skyColor = std.math.lerp(blueSky, greySky, @as(@Vector(4, f32), @splat(@as(f32, @floatCast(@min(1.0, @max(0, viewpos[1] / 4096)))))));
    var c = tracy.Zone.begin(.{ .src = @src(), .name = "Clear" });
    defer c.end();
    gl.ClearColor(skyColor[0], skyColor[1], skyColor[2], skyColor[3]);
    gl.Clear(gl.COLOR_BUFFER_BIT);
    gl.ClearDepth(0.0);
    gl.Clear(gl.DEPTH_BUFFER_BIT);
}

fn vtableSetViewport(userdata: *anyopaque, viewport_pixels: @Vector(2, u32)) error{ViewportSetFailed}!void {
    const self: *OpenGlRenderer = @ptrCast(@alignCast(userdata));
    gl.makeProcTableCurrent(self.proc_table);
    self.window.glMakeContextCurrent(self.draw_context);
    gl.Viewport(0, 0, @intCast(viewport_pixels[0]), @intCast(viewport_pixels[1]));
    self.setupFbo(viewport_pixels[0], viewport_pixels[1]);
    self.viewport_pixels = viewport_pixels;
}

fn vtableForEachChunk(userdata: *anyopaque, io: std.Io, callback_userdata: *anyopaque, callback: *const fn (*anyopaque, ChunkPos) void) std.Io.Cancelable!void {
    const self: *OpenGlRenderer = @ptrCast(@alignCast(userdata));
    var it = self.render_buffer.map.iterator();
    defer it.deinit(io);
    while (try it.next(io)) |entry| {
        const chunk_pos = entry.key_ptr.*.toPos();
        it.pause(io);
        callback(callback_userdata, chunk_pos);
        try it.unpause(io);
    }
}

fn compileShaders(self: *@This()) !void {
    const vertexshader = gl.CreateShader(gl.VERTEX_SHADER);
    gl.ShaderSource(vertexshader, 1, @ptrCast(&@embedFile("./vertexshader.vert")), null);
    gl.CompileShader(vertexshader);

    const fragshader = gl.CreateShader(gl.FRAGMENT_SHADER);
    gl.ShaderSource(fragshader, 1, @ptrCast(&@embedFile("./fragshader.frag")), null);
    gl.CompileShader(fragshader);

    const shaderprogram = gl.CreateProgram();
    gl.AttachShader(shaderprogram, vertexshader);
    gl.AttachShader(shaderprogram, fragshader);
    gl.LinkProgram(shaderprogram);
    var linkstatus: c_int = undefined;
    gl.GetProgramiv(shaderprogram, gl.LINK_STATUS, @ptrCast(&linkstatus));
    if (linkstatus == gl.FALSE) {
        var vsbuffer: [1000]u8 = undefined;
        var fsbuffer: [1000]u8 = undefined;
        var plog: [1000]u8 = undefined;
        gl.GetShaderInfoLog(vertexshader, 1000, null, &vsbuffer);
        gl.GetShaderInfoLog(fragshader, 1000, null, &fsbuffer);
        gl.GetProgramInfoLog(shaderprogram, 1000, null, &plog);
        std.debug.panic("{s}\n\n{s}\n\n{s}", .{ vsbuffer, fsbuffer, plog });
        return error.ShaderCompilationFailed;
    }
    gl.DeleteShader(vertexshader);
    gl.DeleteShader(fragshader);
    self.shaderprogram = shaderprogram;

    const entityvertexshader = gl.CreateShader(gl.VERTEX_SHADER);
    gl.ShaderSource(entityvertexshader, 1, @ptrCast(&@embedFile("./EntityVertexShader.vert")), null);
    gl.CompileShader(entityvertexshader);

    const entityfragshader = gl.CreateShader(gl.FRAGMENT_SHADER);
    gl.ShaderSource(entityfragshader, 1, @ptrCast(&@embedFile("./EntityFragmentShader.frag")), null);
    gl.CompileShader(entityfragshader);

    const entityshaderprogram = gl.CreateProgram();
    gl.AttachShader(entityshaderprogram, entityvertexshader);
    gl.AttachShader(entityshaderprogram, entityfragshader);
    gl.LinkProgram(entityshaderprogram);
    var elinkstatus: c_int = undefined;
    gl.GetProgramiv(entityshaderprogram, gl.LINK_STATUS, @ptrCast(&elinkstatus));
    if (elinkstatus == gl.FALSE) {
        var vsbuffer: [1000]u8 = undefined;
        var fsbuffer: [1000]u8 = undefined;
        var plog: [1000]u8 = undefined;
        gl.GetShaderInfoLog(entityvertexshader, 1000, null, &vsbuffer);
        gl.GetShaderInfoLog(entityfragshader, 1000, null, &fsbuffer);
        gl.GetProgramInfoLog(entityshaderprogram, 1000, null, &plog);
        std.debug.panic("{s}\n\n{s}\n\n{s}", .{ vsbuffer, fsbuffer, plog });
        return error.ShaderCompilationFailed;
    }
    gl.DeleteShader(entityvertexshader);
    gl.DeleteShader(entityfragshader);
    self.entityshaderprogram = entityshaderprogram;
}

fn loadFacebuffer(self: *@This()) !void {
    const vertices = [_]f32{
        -0.5, -0.5, 0.0, // bottom left corner
        -0.5, 0.5, 0.0, // top left corner
        0.5, 0.5,  0.0, // top right corner
        0.5, -0.5, 0.0,
    }; // bottom right corner

    const indices = [_]u32{
        0, 1, 2, // first triangle (bottom left - top left - top right)
        0, 2, 3,
    };

    gl.GenBuffers(1, @ptrCast(&self.indecies));
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.indecies);

    gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @sizeOf(u32) * indices.len, &indices, gl.STATIC_DRAW);

    gl.GenBuffers(1, @ptrCast(&self.facebuffer));
    gl.BindBuffer(gl.ARRAY_BUFFER, self.facebuffer);

    gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(f32) * vertices.len, &vertices, gl.STATIC_DRAW);
    gl.VertexAttribPointer(0, 3, gl.FLOAT, 0, 3 * @sizeOf(f32), 0);
    gl.EnableVertexAttribArray(0);
}

fn drawChunks(self: *@This(), io: std.Io, playerPos: @Vector(3, f64), skyColor: @Vector(4, f32), viewport_pixels: @Vector(2, u32)) error{DrawFailed}!void {
    const c = tracy.Zone.begin(.{ .src = @src() });
    defer c.end();
    self.render_options_lock.lockSharedUncancelable(io);
    const draw_over = self.render_options.draw_over;
    const fov = std.math.degreesToRadians(self.render_options.fov);
    const day_length_sec = self.render_options.day_length_sec;
    self.render_options_lock.unlockShared(io);

    gl.makeProcTableCurrent(self.proc_table);
    gl.FrontFace(gl.CW);
    gl.UseProgram(self.shaderprogram);
    gl.BindTexture(gl.TEXTURE_2D_ARRAY, self.blockAtlasTextureId);
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.indecies);
    const sun_angle = @rem(@as(f128, @floatFromInt(std.Io.Timestamp.now(io, .real).nanoseconds)) / ((@as(f128, @max(0.001, day_length_sec)) * std.time.ns_per_s) / 360), 360.0);
    const sunrot = zm.Mat4f.rotationRH(.{ .data = @Vector(3, f32){ 1.0, 0.0, 0.0 } }, @floatCast(std.math.degreesToRadians(sun_angle)));

    const view = zm.Mat4f.lookAtRH(.{ .data = @Vector(3, f32){ 0, 0, 0 } }, .{ .data = self.cameraFront }, .{ .data = @This().cameraUp });
    const aspect = @as(f32, @floatFromInt(viewport_pixels[0])) / @as(f32, @floatFromInt(viewport_pixels[1]));
    const reverse_z_matrix = makeInfReversedZProjRH(fov, aspect, 0.01).transpose();
    const projection = reverse_z_matrix;
    const projview = @as(@Vector(16, f32), @bitCast(projection.multiply(view).data));
    gl.Uniform4f(self.uniforms.skyColor, skyColor[0], skyColor[1], skyColor[2], skyColor[3]);
    gl.Uniform1f(self.uniforms.fogDensity, 0);
    gl.UniformMatrix4fv(self.uniforms.sunlocation, 1, gl.TRUE, @ptrCast(&(sunrot)));
    gl.UniformMatrix4fv(self.uniforms.projviewlocation, 1, gl.TRUE, @ptrCast(&(projview)));
    const millitimestamp = std.Io.Timestamp.now(io, .real).toMilliseconds();
    gl.Uniform1d(self.uniforms.timelocation, @floatFromInt(millitimestamp));
    gl.Uniform3d(self.uniforms.playerposlocation, playerPos[0], playerPos[1], playerPos[2]);
    gl.Uniform1i(self.uniforms.draw_over, if (draw_over) gl.TRUE else gl.FALSE);
    const frustrum = Frustum.extractFrustumPlanes(projview);

    try drawChunksReal(self, io, playerPos, frustrum, false);
    try drawChunksReal(self, io, playerPos, frustrum, true);
}

fn drawChunksReal(self: *@This(), io: std.Io, playerPos: @Vector(3, f64), frustrum: Frustum, is_transparent: bool) !void {
    const opaque_draw_info = self.render_buffer.rebuild(
        io,
        @sizeOf(Mesher.Face),
        cullChunkPredicate,
        .{ .frustrum = frustrum, .playerPos = playerPos, .is_transparent = is_transparent },
        ChunkDrawData,
        getChunkData,
        .{ .playerpos = playerPos },
    ) catch return error.DrawFailed;

    if (opaque_draw_info.drawn == 0) return;
    self.render_buffer.buffer.resize_lock.lockSharedUncancelable(io);
    defer self.render_buffer.buffer.resize_lock.unlockShared(io);
    self.render_buffer.ssbo.resize_lock.lockSharedUncancelable(io);
    defer self.render_buffer.ssbo.resize_lock.unlockShared(io);
    self.render_buffer.indirect_buffer.resize_lock.lockSharedUncancelable(io);
    defer self.render_buffer.indirect_buffer.resize_lock.unlockShared(io);
    gl.Finish();
    gl.BindVertexArray(self.vao);
    gl.BindBuffer(gl.ARRAY_BUFFER, self.render_buffer.buffer.buffer orelse return);
    gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(u32), 0);
    gl.EnableVertexAttribArray(1);
    gl.VertexAttribDivisor(1, 1);
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.indecies);
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, self.render_buffer.ssbo.buffer.?);

    gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.render_buffer.indirect_buffer.buffer.?);
    gl.MultiDrawElementsIndirect(gl.TRIANGLES, gl.UNSIGNED_INT, 0, @intCast(opaque_draw_info.drawn), 0);
    const ff = tracy.Zone.begin(.{ .src = @src() });
    defer ff.end();
    gl.Finish(); //TODO better syncronization
}

fn getChunkData(userdata: anytype, key: RenderBufferKey) ChunkDrawData {
    const chunkpos = key.toPos();

    const playerpos: @Vector(3, f64) = userdata.playerpos;
    const ratio: @Vector(3, f64) = @splat(@floatCast(ChunkPos.levelToBlockRatioFloat(chunkpos.level)));
    const chunk_blockpos = @as(@Vector(3, f64), chunkpos.position) * ratio;
    const relative_blockpos = chunk_blockpos - playerpos;
    return ChunkDrawData{
        .absolute_position = @as(@Vector(3, f32), @floatCast(chunk_blockpos)),
        .relative_position = @as(@Vector(3, f32), @floatCast(relative_blockpos)),
        .scale = ChunkPos.toScale(chunkpos.level),
    };
}

fn cullChunkPredicate(userdata: anytype, chunkpos: RenderBufferKey) bool {
    const is_transparent = chunkpos == .transparent;
    if (userdata.is_transparent != is_transparent) return true;
    return cullChunk(&userdata.frustrum, chunkpos.toPos(), userdata.playerPos);
}

fn cullChunk(frustrum: *const Frustum, chunkpos: ChunkPos, playerPos: @Vector(3, f64)) bool {
    const scale = ChunkPos.toScale(chunkpos.level);
    const chunkSizeVec: @Vector(3, f32) = @splat(ChunkSize * scale);
    const relativeChunkPos: @Vector(3, f32) = @floatCast((@as(@Vector(3, f32), @floatFromInt(chunkpos.position)) * chunkSizeVec) - playerPos);
    return !frustrum.boxInFrustum(.{ .max = relativeChunkPos + chunkSizeVec, .min = relativeChunkPos });
}

fn makeInfReversedZProjRH(fovY_radians: f32, aspectWbyH: f32, zNear: f32) zm.Mat4f {
    const f: f32 = 1.0 / @tan(fovY_radians / 2.0);
    return .{
        .data = .{
            .{
                f / aspectWbyH,
                0.0,
                0.0,
                0.0,
            },
            .{
                0.0,
                f,
                0.0,
                0.0,
            },
            .{
                0.0,
                0.0,
                0.0,
                -1.0,
            },
            .{
                0.0,
                0.0,
                zNear,
                0.0,
            },
        },
    };
}

const DrawElementsIndirectCommand = extern struct {
    count: c_uint,
    instanceCount: c_uint,
    firstIndex: c_uint,
    baseVertex: c_uint,
    baseInstance: c_uint,
};

const ChunkDrawData = extern struct {
    absolute_position: [3]f32 align(4 * @sizeOf(f32)),
    relative_position: [3]f32 align(4 * @sizeOf(f32)),
    scale: f32,
};

const UniformLocations = struct {
    projviewlocation: c_int,
    entityprojviewlocation: c_int,
    relativechunkposlocation: c_int,
    relativeEntityposlocation: c_int,
    EntityRotationlocation: c_int,
    sunlocation: c_int,
    playerposlocation: c_int,
    fogDensity: c_int,
    skyColor: c_int,
    timelocation: c_int,
    draw_over: c_int,

    pub fn GetLocations(shaderprogram: c_uint, entityshaderprogram: c_uint) @This() {
        return @This(){
            .projviewlocation = gl.GetUniformLocation(shaderprogram, "projview"),
            .entityprojviewlocation = gl.GetUniformLocation(entityshaderprogram, "ProjView"),
            .relativechunkposlocation = gl.GetUniformLocation(shaderprogram, "relativechunkpos"),
            .relativeEntityposlocation = gl.GetUniformLocation(entityshaderprogram, "RelativePos"),
            .EntityRotationlocation = gl.GetUniformLocation(entityshaderprogram, "Rotation"),
            .playerposlocation = gl.GetUniformLocation(shaderprogram, "playerPos"),
            .sunlocation = gl.GetUniformLocation(shaderprogram, "sunrot"),
            .skyColor = gl.GetUniformLocation(shaderprogram, "skyColor"),
            .fogDensity = gl.GetUniformLocation(shaderprogram, "fogDensity"),
            .timelocation = gl.GetUniformLocation(shaderprogram, "time"),
            .draw_over = gl.GetUniformLocation(shaderprogram, "draw_over"),
        };
    }
};

const GpuBuffer = struct {
    buffer: ?c_uint = null,
    mapping: ?[]u8 = null,
    growth_factor: u32 = 2,
    ///shared is for starting writes and reading variables, exclusive is for resizing
    resize_lock: std.Io.RwLock = .init,

    pub fn ensureCapacity(self: *GpuBuffer, io: std.Io, length: usize) !void {
        {
            try self.resize_lock.lockShared(io);
            defer self.resize_lock.unlockShared(io);
            if (self.mapping != null and length <= self.mapping.?.len) return;
        }

        try self.resize_lock.lock(io);
        defer self.resize_lock.unlock(io);
        if (self.mapping != null and length <= self.mapping.?.len) return;
        const scaled_size: usize = if (self.mapping != null) self.mapping.?.len * self.growth_factor else 0;
        const new_size = @max(scaled_size, length);
        std.log.debug("Expanding buffer to {d}", .{new_size});
        const e = tracy.Zone.begin(.{ .src = @src() });
        defer e.end();
        var new_buffer: c_uint = undefined;
        gl.CreateBuffers(1, @ptrCast(&new_buffer));
        errdefer gl.DeleteBuffers(1, @ptrCast(&new_buffer));
        gl.NamedBufferStorage(new_buffer, @intCast(new_size), null, gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.CLIENT_STORAGE_BIT);
        errdefer _ = gl.UnmapNamedBuffer(new_buffer);
        if (self.buffer) |oldbuffer| {
            gl.Finish();
            const data_len = if (self.mapping != null) self.mapping.?.len else 0;
            if (self.mapping != null) _ = gl.UnmapNamedBuffer(oldbuffer);
            self.mapping = null;
            gl.CopyNamedBufferSubData(oldbuffer, new_buffer, 0, 0, @intCast(data_len));
            gl.DeleteBuffers(1, @ptrCast(&oldbuffer));
        }
        var new_mapping: []u8 = undefined;
        new_mapping.len = new_size;
        new_mapping.ptr = @ptrCast(gl.MapNamedBufferRange(new_buffer, 0, @intCast(new_size), gl.MAP_WRITE_BIT | gl.MAP_FLUSH_EXPLICIT_BIT | gl.MAP_PERSISTENT_BIT) orelse return error.OutOfMemory);
        self.buffer = new_buffer;
        self.mapping = new_mapping;
        gl.Finish();
    }

    pub fn writeSegment(self: *GpuBuffer, io: std.Io, offset: usize, data: []const u8) !void {
        const e = tracy.Zone.begin(.{ .src = @src() });
        defer e.end();
        std.debug.assert(data.len > 0);
        try self.ensureCapacity(io, offset + data.len);
        try self.resize_lock.lockShared(io);
        defer self.resize_lock.unlockShared(io);
        std.debug.assert(self.mapping.?.len >= data.len);
        @memcpy(self.mapping.?[offset .. offset + data.len], data);
        gl.FlushMappedNamedBufferRange(self.buffer.?, @intCast(offset), @intCast(data.len));
        gl.Flush();
    }

    pub fn writeSegmentNoFlush(self: *GpuBuffer, io: std.Io, offset: usize, data: []const u8) !void {
        std.debug.assert(data.len > 0);
        try self.ensureCapacity(io, offset + data.len);
        try self.resize_lock.lockShared(io);
        std.debug.assert(self.mapping.?.len >= data.len);
        defer self.resize_lock.unlockShared(io);
        @memcpy(self.mapping.?[offset .. offset + data.len], data);
    }

    pub fn flushRange(self: *GpuBuffer, io: std.Io, offset: usize, length: usize) !void {
        try self.resize_lock.lockShared(io);
        defer self.resize_lock.unlockShared(io);
        gl.FlushMappedNamedBufferRange(self.buffer.?, @intCast(offset), @intCast(length));
        gl.Flush();
    }

    pub fn free(self: *GpuBuffer, io: std.Io) void {
        self.resize_lock.lockUncancelable(io);
        defer self.resize_lock.unlock(io);
        if (self.buffer) |buffer| {
            _ = gl.UnmapNamedBuffer(buffer);
            gl.DeleteBuffers(1, @ptrCast(&buffer));
        }
        self.buffer = null;
        self.mapping = null;
    }
};

fn MultiRenderBuffer(comptime K: type) type {
    return struct {
        pub const Map = ConcurrentHashMap(K, *Space, std.hash_map.AutoContext(K), 80, 32);
        allocator: std.mem.Allocator,

        ssbo: GpuBuffer = .{},
        indirect_buffer: GpuBuffer = .{},

        buffer: GpuBuffer = .{},
        used_capacity: usize = 0,

        linked_list: std.DoublyLinkedList = .{},

        free_list: std.DoublyLinkedList = .{},

        map: Map = .init,
        lock: std.Io.Mutex = .init,

        const Space = struct {
            node: std.DoublyLinkedList.Node,
            freelist_node: ?std.DoublyLinkedList.Node,
            start: usize,
            length: usize,
        };

        pub fn put(self: *@This(), io: std.Io, key: K, value: []const u8) !void {
            const z = tracy.Zone.begin(.{ .src = @src() });
            defer z.end();
            {
                const l = tracy.Zone.begin(.{ .src = @src(), .name = "lock" });
                self.lock.lockUncancelable(io);
                defer self.lock.unlock(io);
                l.end();
                const space = try self.add(value.len);
                std.debug.assert(space.freelist_node == null);
                std.debug.assert(space.length == value.len);
                const existing = try self.map.fetchPut(io, self.allocator, key, space);
                if (existing) |e| self.removeSpace(e);
                try self.buffer.writeSegment(io, space.start, value);
            }
        }

        fn add(self: *@This(), length: usize) !*Space {
            const z = tracy.Zone.begin(.{ .src = @src() });
            defer z.end();
            var space: *Space = undefined;
            var next = self.free_list.first;
            while (true) {
                space = if (next != null) @fieldParentPtr("freelist_node", @as(*?std.DoublyLinkedList.Node, @ptrCast(next))) else try self.append(length);
                if (next) |n| next = n.next;
                if (space.length >= length) {
                    const extra_space = space.length - length;
                    if (extra_space > 0) {
                        const space_ptr = try self.allocator.create(Space);
                        space_ptr.* = Space{
                            .node = undefined,
                            .freelist_node = .{},
                            .start = space.start + length,
                            .length = extra_space,
                        };
                        self.free_list.append(&space_ptr.freelist_node.?);
                        self.linked_list.insertAfter(&space.node, &space_ptr.node);
                        space.length -= extra_space;
                    }
                    self.free_list.remove(&space.freelist_node.?);
                    space.freelist_node = null;
                    std.debug.assert(space.length == length);
                    return space;
                }
            }
        }

        fn append(self: *@This(), size: usize) !*Space {
            const z = tracy.Zone.begin(.{ .src = @src() });
            defer z.end();
            std.debug.assert(size > 0);

            const space_ptr = try self.allocator.create(Space);
            space_ptr.* = Space{
                .node = undefined,
                .freelist_node = .{},
                .start = self.used_capacity,
                .length = size,
            };
            self.free_list.append(&space_ptr.freelist_node.?);
            self.linked_list.append(&space_ptr.node);
            self.used_capacity += size;
            std.debug.assert(space_ptr.length == size);
            return space_ptr;
        }

        pub fn remove(self: *@This(), io: std.Io, key: K) void {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            const space = self.map.fetchRemove(io, key) orelse {
                return;
            };
            self.removeSpace(space);
        }

        pub fn removeSpace(self: *@This(), space: *Space) void {
            const rs = tracy.Zone.begin(.{ .src = @src() });
            defer rs.end();
            space.freelist_node = .{};
            const behind = space.node.prev;
            const ahead = space.node.next;
            if (ahead) |node| {
                const aspace: *Space = @fieldParentPtr("node", node);
                if (aspace.freelist_node != null) {
                    std.debug.assert(space.start + space.length == aspace.start);
                    space.length += aspace.length;
                    self.linked_list.remove(&aspace.node);
                    self.free_list.remove(&aspace.freelist_node.?);
                    self.allocator.destroy(aspace);
                }
            }
            if (behind) |node| {
                const bspace: *Space = @fieldParentPtr("node", node);
                if (bspace.freelist_node != null) {
                    std.debug.assert(bspace.start + bspace.length == space.start);
                    space.length += bspace.length;
                    space.start = bspace.start;
                    self.linked_list.remove(&bspace.node);
                    self.free_list.remove(&bspace.freelist_node.?);
                    self.allocator.destroy(bspace);
                }
            }
            self.free_list.append(&space.freelist_node.?);
        }

        pub fn rebuild(
            self: *@This(),
            io: std.Io,
            element_size: usize,
            culler: ?fn (userdata: anytype, key: K) bool,
            cull_userdata: anytype,
            ItemData: type,
            get_itemdata: fn (userdata: anytype, key: K) ItemData,
            item_userdata: anytype,
        ) !struct { faces: u64, drawn: u64, total: u64 } {
            const z = tracy.Zone.begin(.{ .src = @src() });
            defer z.end();

            var face_count: u64 = 0;
            var drawn: usize = 0;
            const total = self.map.count(io);
            if (total == 0) return .{ .drawn = 0, .total = 0, .faces = 0 };
            {
                const loop = tracy.Zone.begin(.{ .src = @src() });
                defer loop.end();
                try self.lock.lock(io);
                defer self.lock.unlock(io);
                var it = self.map.iterator();
                defer it.deinit(io);
                while (try it.next(io)) |entry| {
                    const start = entry.value_ptr.*.start;
                    const length = entry.value_ptr.*.length;
                    const free = entry.value_ptr.*.freelist_node != null;

                    std.debug.assert(length > 0);
                    std.debug.assert(!free);
                    const key = entry.key_ptr.*;
                    if (culler) |cullFn| {
                        const cu = tracy.Zone.begin(.{ .src = @src(), .name = "cull" });
                        defer cu.end();
                        if (cullFn(cull_userdata, key)) continue;
                    }
                    const faces = @divExact(length, element_size);
                    face_count += faces;
                    const command: DrawElementsIndirectCommand = .{
                        .count = 6,
                        .firstIndex = 0,
                        .baseInstance = @intCast(@divExact(start, element_size)),
                        .baseVertex = 0,
                        .instanceCount = @intCast(@divExact(length, element_size)),
                    };
                    const itemdata = get_itemdata(item_userdata, key);
                    const wr = tracy.Zone.begin(.{ .src = @src() });
                    defer wr.end();
                    try self.indirect_buffer.writeSegmentNoFlush(io, drawn * @sizeOf(DrawElementsIndirectCommand), std.mem.asBytes(&command));
                    try self.ssbo.writeSegmentNoFlush(io, drawn * @sizeOf(ItemData), std.mem.asBytes(&itemdata));
                    drawn += 1;
                }
            }
            if (drawn > 0) {
                gl.MemoryBarrier(gl.SHADER_STORAGE_BARRIER_BIT | gl.COMMAND_BARRIER_BIT | gl.CLIENT_MAPPED_BUFFER_BARRIER_BIT);
                gl.Flush();
            }
            return .{ .faces = face_count, .drawn = drawn, .total = total }; //total may not be totaly accurate
        }

        pub fn deinit(self: *@This(), io: std.Io, allocator: std.mem.Allocator) void {
            std.debug.assert(self.lock.tryLock());
            self.buffer.free(io);

            var node = self.linked_list.first;
            while (node) |n| {
                const space: *Space = @fieldParentPtr("node", n);
                node = n.next;
                self.allocator.destroy(space);
            }
            self.map.deinit(io, allocator);

            self.ssbo.free(io);
            self.indirect_buffer.free(io);
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
