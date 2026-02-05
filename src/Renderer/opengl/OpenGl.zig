const std = @import("std");

const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const ConcurrentQueue = @import("ConcurrentQueue").ConcurrentQueue;
const gl = @import("gl");
const sdl = @import("sdl3");
const zm = @import("zm");
const ztracy = @import("ztracy");

const keepLoaded = @import("../../Loader.zig").keepLoaded;
const Mesh = @import("../../Mesh.zig");
const Renderer = @import("../../Renderer.zig");
const World = @import("../../world/World.zig");
const ChunkSize = World.ChunkSize;
const Entity = World.Entity;
const ChunkPos = World.ChunkPos;
const EntityTypes = World.EntityTypes;
const Frustum = @import("Frustum.zig").Frustum;
const Textures = @import("textures.zig");
const builtin = @import("builtin");

pub const cameraUp = @Vector(3, f64){ 0, 1, 0 };
const OpenGlRenderer = @This();
allocator: std.mem.Allocator,
facebuffer: c_uint,
indecies: c_uint,
entityshaderprogram: c_uint,
shaderprogram: c_uint,
blockAtlasTextureId: c_uint,
vao: c_uint,
uniforms: UniformLocations,
cameraFront: @Vector(3, f32),
render_buffer: MultiRenderBuffer(ChunkPos),
interface: Renderer,
viewport_pixels: @Vector(2, u32),
window: sdl.video.Window,
gen_context_lock: std.Thread.Mutex = .{},
contexts: std.ArrayList(sdl.video.gl.Context),
context_index: std.atomic.Value(usize) = .init(0),
proc_table: gl.ProcTable,
draw_context: sdl.video.gl.Context,

pub fn init(self: *@This(), allocator: std.mem.Allocator, window: sdl.video.Window) !void {
    const cpu_count = try std.Thread.getCpuCount();
    self.* = @This(){
        .allocator = allocator,
        .facebuffer = undefined,
        .indecies = undefined,
        .shaderprogram = undefined,
        .proc_table = undefined,
        .render_buffer = .{ .allocator = allocator },
        .entityshaderprogram = undefined,
        .cameraFront = undefined,
        .vao = undefined,
        .window = window,
        .draw_context = try sdl.video.gl.Context.init(window),
        .blockAtlasTextureId = undefined,
        .uniforms = undefined,
        .viewport_pixels = .{ 0, 0 },
        .contexts = try .initCapacity(allocator, cpu_count),
        .interface = .{
            .userdata = @ptrCast(self),
            .vtable = &.{
                .addChunk = addChunk,
                .removeChunk = removeChunk,
                .drawChunks = drawChunksFn,
                .containsChunk = undefined,
                .clear = clear,
                .setViewport = setViewport,
            },
        },
    };
    if (!gl.ProcTable.init(&self.proc_table, sdl.c.SDL_GL_GetProcAddress)) return error.InitFailed;
    gl.makeProcTableCurrent(&self.proc_table);

    self.blockAtlasTextureId = try Textures.loadTextureArray(try std.fs.cwd().openDir("packs/default/Blocks/", .{ .iterate = true }), allocator);

    for (0..cpu_count) |_| {
        try self.contexts.append(allocator, try sdl.video.gl.Context.init(window));
    }
    try self.draw_context.makeCurrent(self.window);

    try self.CompileShaders();

    self.uniforms = UniformLocations.GetLocations(self.shaderprogram, self.entityshaderprogram);

    self.LoadFacebuffer();

    gl.GenVertexArrays(1, @ptrCast(&self.vao));
    gl.BindVertexArray(self.vao);
    try glError();

    gl.BindBuffer(gl.ARRAY_BUFFER, self.facebuffer);
    gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(f32), 0);
    gl.EnableVertexAttribArray(0);
    gl.BindVertexArray(0);

    try glError();

    gl.Viewport(0, 0, @intFromFloat(@as(f32, @floatFromInt(800))), @intFromFloat(@as(f32, @floatFromInt(600))));

    gl.Enable(gl.MULTISAMPLE);
    gl.Enable(gl.DEPTH_TEST);
    gl.Enable(gl.CULL_FACE);
    gl.CullFace(gl.BACK);
    gl.FrontFace(gl.CW);
    gl.DepthFunc(gl.LESS);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    try glError();
}

pub fn deinit(self: *@This()) void {
    self.draw_context.makeCurrent(self.window) catch unreachable;
    gl.Finish();
    self.render_buffer.deinit();
    self.context_index.store(0, .seq_cst);
    for (0..self.contexts.items.len) |i| {
        self.contexts.items[i].deinit() catch unreachable;
    }
    self.contexts.deinit(self.allocator);
    gl.DeleteTextures(1, @ptrCast(&self.blockAtlasTextureId));
    gl.DeleteBuffers(1, @ptrCast(&self.indecies));
    gl.DeleteBuffers(1, @ptrCast(&self.facebuffer));

    gl.DeleteProgram(self.shaderprogram);
    gl.DeleteProgram(self.entityshaderprogram);
    std.log.info("renderer deinit", .{});
}

threadlocal var thread_index: ?usize = null;

pub fn ensureContext(self: *@This()) !void {
    if (thread_index == null) {
        thread_index = self.context_index.fetchAdd(1, .seq_cst);
    }
    try self.contexts.items[thread_index.?].makeCurrent(self.window);
    gl.makeProcTableCurrent(&self.proc_table);
}

fn glError() !void {
    switch (gl.GetError()) {
        gl.NO_ERROR => return,
        gl.INVALID_ENUM => unreachable,
        gl.INVALID_VALUE => unreachable,
        gl.INVALID_OPERATION => unreachable,
        gl.INVALID_FRAMEBUFFER_OPERATION => unreachable,
        gl.OUT_OF_MEMORY => return error.OutOfMemory,
        else => unreachable,
    }
}

pub fn addChunk(userdata: *anyopaque, mesh: Mesh) error{ OutOfMemory, OutOfVideoMemory }!void {
    if (true) unreachable;
    const self: *@This() = @ptrCast(@alignCast(userdata));
    _ = try self.load_queue.append(mesh);
}

pub fn remove(self: *@This(), Pos: ChunkPos) void {
    const ids = self.renderlist.fetchremove(Pos) orelse return;
    ids.free();
}

fn removeChunk(userdata: *anyopaque, Pos: ChunkPos) void {
    _ = userdata;
    _ = Pos;
    unreachable;
    //const emptyMesh: Mesh = .{ .Pos = Pos, .TransperentFaces = null, .faces = null, .scale = undefined, .animation = undefined };
    //addChunk(userdata, emptyMesh) catch std.log.err("removemesh failed", .{});
}

pub fn updateCameraDirection(self: *@This(), viewDir: @Vector(3, f32)) void {
    self.cameraFront[0] = @sin(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    self.cameraFront[1] = @sin(std.math.degreesToRadians(viewDir[0]));
    self.cameraFront[2] = @cos(std.math.degreesToRadians(viewDir[1])) * @cos(std.math.degreesToRadians(viewDir[0]));
    _ = zm.vec.normalize(self.cameraFront);
}

fn CompileShaders(self: *@This()) !void {
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
    try glError();
}

fn LoadFacebuffer(self: *@This()) void {
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
var last_viewport: [2]f32 = undefined;

fn drawChunks(self: *@This(), playerPos: @Vector(3, f64), skyColor: @Vector(4, f32), viewport_pixels: @Vector(2, u32)) error{DrawFailed}!void {
    const c = ztracy.ZoneNC(@src(), "drawChunks", 32213);
    defer c.End();
    self.draw_context.makeCurrent(self.window) catch return error.DrawFailed;
    gl.makeProcTableCurrent(&self.proc_table);
    gl.FrontFace(gl.CW);
    gl.UseProgram(self.shaderprogram);
    gl.BindTexture(gl.TEXTURE_2D_ARRAY, self.blockAtlasTextureId);
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.indecies);
    const sunrot = zm.Mat4f.rotation(@Vector(3, f32){ 1.0, 0.0, 0.0 }, std.math.degreesToRadians(180));
    const projdist = 10000000;

    const view = zm.Mat4.lookAt(@Vector(3, f32){ 0, 0, 0 }, self.cameraFront, @This().cameraUp);
    const projection = zm.Mat4.perspective(std.math.degreesToRadians(90.0), @as(f32, @floatFromInt(viewport_pixels[0])) / @as(f32, @floatFromInt(viewport_pixels[1])), 0.1, @floatFromInt(projdist));
    const projview = @as(@Vector(16, f32), @floatCast(projection.multiply(view).data));
    gl.Uniform4f(self.uniforms.skyColor, skyColor[0], skyColor[1], skyColor[2], skyColor[3]);
    gl.Uniform1f(self.uniforms.fogDensity, 0);
    gl.UniformMatrix4fv(self.uniforms.sunlocation, 1, gl.TRUE, @ptrCast(&(sunrot)));
    gl.UniformMatrix4fv(self.uniforms.projviewlocation, 1, gl.TRUE, @ptrCast(&(projview)));
    //var drawnchunks: u64 = 0;
    //var torenderchunks: u64 = 0;
    const millitimestamp = std.time.milliTimestamp();
    gl.Uniform1d(self.uniforms.timelocation, @floatFromInt(millitimestamp));
    gl.Uniform3d(self.uniforms.playerposlocation, playerPos[0], playerPos[1], playerPos[2]);
    const frustrum = Frustum.extractFrustumPlanes(projview);
    gl.Enable(gl.CULL_FACE);
    glError() catch return error.DrawFailed;
    const lb = ztracy.ZoneN(@src(), "lock buffer");

    const draw_info = self.render_buffer.rebuild(
        @sizeOf(Mesh.Face),
        cullChunkFn,
        .{ .frustrum = frustrum, .playerPos = playerPos },
        ChunkDrawData,
        getChunkData,
        .{ .playerpos = playerPos },
    ) catch return error.DrawFailed;
    self.render_buffer.buff_lock.lockShared();
    lb.End();
    defer self.render_buffer.buff_lock.unlockShared();

    if (draw_info.drawn == 0) return;
    gl.BindVertexArray(self.vao);
    glError() catch return error.DrawFailed;
    gl.BindBuffer(gl.ARRAY_BUFFER, self.render_buffer.buffer.buffer orelse return);
    glError() catch return error.DrawFailed;
    gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(u32), 0);
    gl.EnableVertexAttribArray(1);
    gl.VertexAttribDivisor(1, 1);
    glError() catch return error.DrawFailed;

    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.indecies);
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, self.render_buffer.ssbo.?);

    glError() catch return error.DrawFailed;
    gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.render_buffer.indirect_buffer.?);
    glError() catch return error.DrawFailed;
    gl.MultiDrawElementsIndirect(gl.TRIANGLES, gl.UNSIGNED_INT, 0, @intCast(draw_info.drawn), 0);
    glError() catch return error.DrawFailed;
    std.log.info("drawing {d}/{d} chunks and {d} faces  ", .{ draw_info.drawn, draw_info.total, draw_info.faces });
}

fn getChunkData(userdata: anytype, chunkpos: ChunkPos) ChunkDrawData {
    const playerpos: @Vector(3, f64) = userdata.playerpos;
    const ratio: @Vector(3, f64) = @splat(@floatCast(ChunkPos.levelToBlockRatioFloat(chunkpos.level)));
    const chunk_blockpos = @as(@Vector(3, f64), @floatFromInt(chunkpos.position)) * ratio;
    const relative_blockpos = chunk_blockpos - playerpos;
    return ChunkDrawData{
        .absolute_position = @as(@Vector(3, f32), @floatCast(chunk_blockpos)),
        .relative_position = @as(@Vector(3, f32), @floatCast(relative_blockpos)),
        .scale = ChunkPos.toScale(chunkpos.level),
    };
}

fn cullChunkFn(userdata: anytype, chunkpos: ChunkPos) bool {
    return cullChunk(&userdata.frustrum, chunkpos, userdata.playerPos);
}

fn cullChunk(frustrum: *const Frustum, chunkpos: ChunkPos, playerPos: @Vector(3, f64)) bool {
    const scale = ChunkPos.toScale(chunkpos.level);
    const chunkSizeVec: @Vector(3, f32) = @splat(@floatCast(ChunkSize * scale));
    const relativeChunkPos: @Vector(3, f32) = @floatCast((@as(@Vector(3, f32), @floatFromInt(chunkpos.position)) * chunkSizeVec) - playerPos);
    return !frustrum.boxInFrustum(.{ .max = relativeChunkPos + chunkSizeVec, .min = relativeChunkPos });
}

fn drawChunksFn(userdata: *anyopaque, viewpos: @Vector(3, f64)) error{DrawFailed}!void {
    const self: *@This() = @ptrCast(@alignCast(userdata));
    (self.drawChunks(viewpos, .{ 32, 32, 32, 255 }, self.viewport_pixels)) catch return error.DrawFailed;
}

fn clear(userdata: *anyopaque, viewpos: @Vector(3, f64)) error{DrawFailed}!void {
    const self: *@This() = @ptrCast(@alignCast(userdata));
    self.draw_context.makeCurrent(self.window) catch return error.DrawFailed;
    const blueSky = @Vector(4, f32){ 0, 0.4, 0.8, 1.0 };
    const greySky = @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 };
    const skyColor = std.math.lerp(blueSky, greySky, @as(@Vector(4, f32), @splat(@as(f32, @floatCast(@min(1.0, @max(0, viewpos[1] / 4096)))))));
    const c = ztracy.ZoneNC(@src(), "Clear", 32213);
    gl.ClearColor(skyColor[0], skyColor[1], skyColor[2], skyColor[3]);
    gl.Clear(gl.COLOR_BUFFER_BIT);
    gl.Clear(gl.DEPTH_BUFFER_BIT);
    c.End();
}

fn setViewport(userdata: *anyopaque, viewport_pixels: @Vector(2, u32)) error{ViewportSetFailed}!void {
    const self: *@This() = @ptrCast(@alignCast(userdata));
    self.draw_context.makeCurrent(self.window) catch return error.ViewportSetFailed;
    gl.Viewport(0, 0, @intCast(viewport_pixels[0]), @intCast(viewport_pixels[1]));
    glError() catch return error.ViewportSetFailed;
    self.viewport_pixels = viewport_pixels;
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
        };
    }
};

const GpuBuffer = struct {
    len: usize = 0,
    buffer: ?c_uint = null,

    pub const WriteFuture = struct {
        sync: ?*gl.sync,

        pub fn create() !WriteFuture {
            const sync = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0) orelse return error.FailedToCreateSync;
            try glError();
            return .{ .sync = sync };
        }

        pub fn isComplete(sync: *anyopaque) bool {
            const result = gl.ClientWaitSync(sync, 0, 0); // timeout=0, non-blocking
            return result == gl.ALREADY_SIGNALED or result == gl.CONDITION_SATISFIED;
        }

        pub fn wait(self: *@This(), timeout_ns: u64) !void {
            const result = gl.ClientWaitSync(self.sync orelse return, gl.SYNC_FLUSH_COMMANDS_BIT, timeout_ns);
            switch (result) {
                gl.ALREADY_SIGNALED, gl.CONDITION_SATISFIED => self.sync = null,
                gl.TIMEOUT_EXPIRED => return error.Timeout,
                gl.WAIT_FAILED => return error.WaitFailed,
                else => unreachable,
            }
        }

        pub fn cleanup(self: *@This()) void {
            gl.DeleteSync(self.sync orelse return);
            self.sync = null;
        }
    };

    pub fn expand(self: *GpuBuffer, new_size: usize) !void {
        std.debug.assert(new_size != 0);
        if (self.buffer != null and new_size <= self.len) return;
        std.log.debug("Expanding buffer to {d}", .{new_size});
        var new_buffer: c_uint = undefined;
        gl.CreateBuffers(1, @ptrCast(&new_buffer));
        try glError();
        gl.NamedBufferStorage(new_buffer, @intCast(new_size), null, gl.DYNAMIC_STORAGE_BIT);
        glError() catch |err| {
            gl.DeleteBuffers(1, @ptrCast(&new_buffer));
            return err;
        };
        if (self.buffer) |oldbuffer| {
            gl.CopyNamedBufferSubData(oldbuffer, new_buffer, 0, 0, @intCast(self.len));
            glError() catch |err| {
                gl.DeleteBuffers(1, @ptrCast(&new_buffer));
                return err;
            };
            self.buffer = new_buffer;
            self.len = new_size;
            gl.DeleteBuffers(1, @ptrCast(&oldbuffer));
        } else {
            self.buffer = new_buffer;
            self.len = new_size;
        }
        gl.Finish();
    }

    pub fn writeSegment(self: *GpuBuffer, offset: usize, data: []const u8) !WriteFuture {
        try self.expand(offset + data.len);
        gl.NamedBufferSubData(self.buffer.?, @intCast(offset), @intCast(data.len), data.ptr);
        try glError();
        return WriteFuture.create();
    }

    pub fn free(self: *GpuBuffer) void {
        if (self.buffer) |buffer| {
            gl.DeleteBuffers(1, @ptrCast(&buffer));
        }
        self.buffer = null;
        self.len = 0;
    }
};

fn MultiRenderBuffer(comptime K: type) type {
    return struct {
        allocator: std.mem.Allocator,

        ///exclusive lock is for resizing, shared lock is for reading/writing
        buff_lock: std.Thread.RwLock = .{},
        buffer: GpuBuffer = .{},

        linked_list: std.DoublyLinkedList = .{},

        map: std.AutoArrayHashMapUnmanaged(K, *Space) = .empty,
        lock: std.Thread.Mutex = .{},

        indirect_buffer: ?c_uint = null,
        ssbo: ?c_uint = null,

        write_futures: std.ArrayList(GpuBuffer.WriteFuture) = .{},

        const Space = struct {
            node: std.DoublyLinkedList.Node,
            free: bool,
            start: usize,
            length: usize,
        };

        pub fn put(self: *@This(), key: K, value: []const u8) !void {
            const z = ztracy.Zone(@src());
            defer z.End();
            self.lock.lock();
            const space = try self.add(value.len);
            {
                self.buff_lock.lockShared();
                defer self.buff_lock.unlockShared();
                try self.write_futures.append(self.allocator, try self.buffer.writeSegment(space.start, value));
            }
            std.debug.assert(space.length == value.len);
            const existing = self.map.fetchPut(self.allocator, key, space) catch |err| {
                self.lock.unlock();
                return err;
            };
            self.lock.unlock();
            if (existing) |e| self.removeSpace(e.value);
        }

        fn add(self: *@This(), length: usize) !*Space {
            const z = ztracy.Zone(@src());
            defer z.End();
            var node = self.linked_list.first orelse &(try self.append(length)).node;
            while (true) {
                node = node.next orelse &(try self.append(length)).node;
                const space: *Space = @fieldParentPtr("node", node);
                if (space.free and space.length >= length) {
                    space.free = false;
                    const extra_space = space.length - length;
                    if (extra_space > 0) {
                        const space_ptr = try self.allocator.create(Space);
                        space_ptr.* = Space{
                            .node = undefined,
                            .free = true,
                            .start = space.start + length,
                            .length = extra_space,
                        };
                        self.linked_list.insertAfter(node, &space_ptr.node);
                        space.length -= extra_space;
                    }
                    std.debug.assert(space.length == length);
                    return space;
                }
            }
        }

        fn append(self: *@This(), minsize: usize) !*Space {
            const z = ztracy.Zone(@src());
            defer z.End();
            self.buff_lock.lock();
            const old_size = self.buffer.len;
            std.debug.assert(minsize > 0);
            const newsize = @max(old_size + minsize, old_size * 2);
            std.debug.assert(newsize > old_size);
            while (self.write_futures.items.len > 0) {
                var wf = self.write_futures.swapRemove(0);
                try wf.wait(std.math.maxInt(u64));
            }
            self.buffer.expand(newsize) catch |err| {
                self.buff_lock.unlock();
                return err;
            };
            self.buff_lock.unlock();
            const space_ptr = try self.allocator.create(Space);
            space_ptr.* = Space{
                .node = undefined,
                .free = true,
                .start = old_size,
                .length = newsize - old_size,
            };
            self.linked_list.append(&space_ptr.node);
            return space_ptr;
        }

        pub fn remove(self: *@This(), key: K) void {
            self.lock.lock();
            const entry = self.map.fetchSwapRemove(key) orelse {
                self.lock.unlock();
                return;
            };
            self.lock.unlock();
            const space = entry.value;
            self.removeSpace(space);
        }

        pub fn removeSpace(self: *@This(), space: *Space) void {
            self.lock.lock();
            space.free = true;
            const behind = space.node.prev;
            const ahead = space.node.next;
            if (ahead) |node| {
                const aspace: *Space = @fieldParentPtr("node", node);
                if (aspace.free) {
                    std.debug.assert(space.start + space.length == aspace.start);
                    space.length += aspace.length;
                    self.linked_list.remove(&aspace.node);
                    self.allocator.destroy(aspace);
                }
            }
            if (behind) |node| {
                const bspace: *Space = @fieldParentPtr("node", node);
                if (bspace.free) {
                    std.debug.assert(bspace.start + bspace.length == space.start);
                    space.length += bspace.length;
                    space.start = bspace.start;
                    self.linked_list.remove(&bspace.node);
                    self.allocator.destroy(bspace);
                }
            }
            self.lock.unlock();
        }

        pub fn rebuild(
            self: *@This(),
            element_size: usize,
            culler: ?fn (userdata: anytype, key: K) bool,
            cull_userdata: anytype,
            ItemData: type,
            get_itemdata: fn (userdata: anytype, key: K) ItemData,
            item_userdata: anytype,
        ) !struct { faces: u64, drawn: u64, total: u64 } {
            const z = ztracy.Zone(@src());
            defer z.End();

            if (builtin.mode == .Debug) self.verify();
            var face_count: u64 = 0;
            if (self.indirect_buffer == null) {
                var ib: c_uint = undefined;
                gl.CreateBuffers(1, @ptrCast(&ib));
                try glError();
                self.indirect_buffer = ib;
            }
            if (self.ssbo == null) {
                var sb: c_uint = undefined;
                gl.CreateBuffers(1, @ptrCast(&sb));
                try glError();
                self.ssbo = sb;
            }

            const a = ztracy.ZoneN(@src(), "alloc");
            var item_data: std.ArrayList(ItemData) = try .initCapacity(self.allocator, 1_000);
            defer item_data.deinit(self.allocator);
            var commands: std.ArrayList(DrawElementsIndirectCommand) = try .initCapacity(self.allocator, 1_000);
            defer commands.deinit(self.allocator);
            a.End();
            //TODO persistently map buffer
            var total: u64 = 0;
            {
                const l = ztracy.ZoneN(@src(), "lock");
                self.lock.lock();
                l.End();
                defer self.lock.unlock();

                total = self.map.count();

                if (total == 0) return .{ .drawn = 0, .total = 0, .faces = 0 };
                const ac = ztracy.ZoneN(@src(), "mapCommands");
                try glError();
                ac.End();

                const loop = ztracy.ZoneNC(@src(), "loop", 32213);
                var it = self.map.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    if (culler) |cullFn| {
                        if (cullFn(cull_userdata, key)) continue;
                    }
                    const space = entry.value_ptr.*;
                    std.debug.assert(!space.free);
                    const faces = @divExact(space.length, element_size);
                    face_count += faces;
                    const command: DrawElementsIndirectCommand = .{
                        .count = 6,
                        .firstIndex = 0,
                        .baseInstance = @intCast(@divExact(space.start, element_size)),
                        .baseVertex = 0,
                        .instanceCount = @intCast(@divExact(space.length, element_size)),
                    };
                    try commands.append(self.allocator, command);
                    try item_data.append(self.allocator, get_itemdata(item_userdata, key));
                }
                loop.End();
            }
            gl.NamedBufferData(self.indirect_buffer.?, @intCast(commands.items.len * @sizeOf(DrawElementsIndirectCommand)), @ptrCast(commands.items), gl.DYNAMIC_DRAW);
            gl.NamedBufferData(self.ssbo.?, @intCast(item_data.items.len * @sizeOf(ItemData)), @ptrCast(item_data.items), gl.DYNAMIC_DRAW);
            gl.Flush();
            return .{ .faces = face_count, .drawn = commands.items.len, .total = total };
        }

        pub fn verify(self: *@This()) void {
            const v = ztracy.ZoneN(@src(), "verify");
            defer v.End();
            self.lock.lock();
            defer self.lock.unlock();
            var node = self.linked_list.first;
            var lastpos: usize = 0;
            var count: usize = 0;
            while (node) |n| {
                const space: *Space = @fieldParentPtr("node", n);
                std.debug.assert(space.length > 0);
                std.debug.assert(space.start == lastpos);
                lastpos += space.length;
                std.debug.assert(lastpos <= self.buffer.len);
                node = n.next;
                count += 1;
            }
            std.log.debug("{d} nodes", .{count});
        }

        pub fn deinit(self: *@This()) void {
            std.debug.assert(self.lock.tryLock());
            self.buffer.free();

            var node = self.linked_list.first;
            while (node) |n| {
                const space: *Space = @fieldParentPtr("node", n);
                node = n.next;
                self.allocator.destroy(space);
            }
            self.map.deinit(self.allocator);

            if (self.ssbo) |ssbo| {
                gl.DeleteBuffers(1, @ptrCast(&ssbo));
            }
            if (self.indirect_buffer) |indirect_buffer| {
                gl.DeleteBuffers(1, @ptrCast(&indirect_buffer));
            }
            if (self.buffer.buffer) |buffer| {
                gl.DeleteBuffers(1, @ptrCast(&buffer));
            }
        }
    };
}
