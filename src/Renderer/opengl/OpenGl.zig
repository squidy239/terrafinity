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

pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
    try glError();
    self.* = @This(){
        .allocator = allocator,
        .facebuffer = undefined,
        .indecies = undefined,
        .shaderprogram = undefined,
        .render_buffer = .{ .allocator = allocator },
        .entityshaderprogram = undefined,
        .cameraFront = undefined,
        .vao = undefined,
        .blockAtlasTextureId = try Textures.loadTextureArray(try std.fs.cwd().openDir("packs/default/Blocks/", .{ .iterate = true }), allocator),
        .uniforms = undefined,
        .viewport_pixels = .{ 0, 0 },
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
    try glError();

    try self.CompileShaders();

    self.uniforms = UniformLocations.GetLocations(self.shaderprogram, self.entityshaderprogram);
    
    self.LoadFacebuffer();

    gl.GenVertexArrays(1, @ptrCast(&self.vao));
    gl.BindVertexArray(self.vao);

    gl.BindBuffer(gl.ARRAY_BUFFER, self.facebuffer);
    gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(f32), 0);
    gl.EnableVertexAttribArray(0);
 

    gl.BindVertexArray(0);
    try glError();

    try glError();
}

pub fn deinit(self: *@This()) void {
    gl.Finish();
    //TODO deinit renderbuffer

    gl.DeleteTextures(1, @ptrCast(&self.blockAtlasTextureId));
    gl.DeleteBuffers(1, @ptrCast(&self.indecies));
    gl.DeleteBuffers(1, @ptrCast(&self.facebuffer));
    gl.DeleteProgram(self.shaderprogram);
    gl.DeleteProgram(self.entityshaderprogram);
    std.log.info("renderer deinit", .{});
}

threadlocal var context: ?sdl.video.gl.Context = null;

const main = @import("../../main.zig");

fn ensureContext() !void {
    if (context == null) {
        context = main.contexts[main.context_index.fetchAdd(1, .seq_cst)];
        try context.?.makeCurrent(main.window);
        gl.makeProcTableCurrent(&main.proc_table);
    }
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
    //const frustrum = Frustum.extractFrustumPlanes(projview);
    //if (i == 1) gl.Disable(gl.CULL_FACE);
    //defer gl.Enable(gl.CULL_FACE);
    glError() catch return error.DrawFailed;
    const count = self.render_buffer.rebuildCommands(@sizeOf(Mesh.Face)) catch return error.DrawFailed;
    self.render_buffer.buff_lock.lockShared();
    defer self.render_buffer.buff_lock.unlockShared();
    gl.BindVertexArray(self.vao);
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.indecies);
    gl.BindBuffer(gl.ARRAY_BUFFER, self.render_buffer.buffer.buffer orelse return);

    gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(u32), 0);
    gl.EnableVertexAttribArray(1);
    gl.VertexAttribDivisor(1, 1);
    
    gl.BindBuffer(gl.ARRAY_BUFFER, self.facebuffer);
    glError() catch return error.DrawFailed;
    //gl.BindBufferBase(gl.UNIFORM_BUFFER, 0, buffer_ids.UBO);
    gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.render_buffer.indirect_buffer.?);
    glError() catch return error.DrawFailed;
    std.log.debug("drawing {d} chunks\n", .{count});
    gl.MultiDrawElementsIndirect(gl.TRIANGLES, gl.UNSIGNED_INT, 0, @intCast(count), 0);

    glError() catch return error.DrawFailed;
}

fn drawChunksFn(userdata: *anyopaque, viewpos: @Vector(3, f64)) error{DrawFailed}!void {
    const self: *@This() = @ptrCast(@alignCast(userdata));
    (self.drawChunks(viewpos, .{ 32, 32, 32, 255 }, self.viewport_pixels)) catch return error.DrawFailed;
}

fn clear(userdata: *anyopaque, viewpos: @Vector(3, f64)) error{DrawFailed}!void {
    _ = userdata;
    const blueSky = @Vector(4, f32){ 0, 0.4, 0.8, 1.0 };
    const greySky = @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 };
    const skyColor = std.math.lerp(blueSky, greySky, @as(@Vector(4, f32), @splat(@as(f32, @floatCast(@min(1.0, @max(0, viewpos[1] / 4096)))))));
    const c = ztracy.ZoneNC(@src(), "Clear", 32213);
    gl.ClearColor(skyColor[0], skyColor[1], skyColor[2], skyColor[3]);
    gl.Clear(gl.COLOR_BUFFER_BIT);
    gl.Clear(gl.DEPTH_BUFFER_BIT);
    c.End();
}

fn setViewport(userdata: *anyopaque, viewport_pixels: @Vector(2, u32)) void {
    const self: *@This() = @ptrCast(@alignCast(userdata));
    gl.Viewport(0, 0, @intCast(viewport_pixels[0]), @intCast(viewport_pixels[1]));
    self.viewport_pixels = viewport_pixels;
}

//TODO update entity rendering
fn DrawEntities(self: *@This(), game: *@import("../../Game.zig"), playerPos: @Vector(3, f64), viewport_pixels: @Vector(2, f32)) !void {
    gl.FrontFace(gl.CCW);
    gl.UseProgram(self.entityshaderprogram);
    const projview = @as(@Vector(16, f32), @floatCast(zm.Mat4.perspective(std.math.degreesToRadians(90.0), viewport_pixels[0] / viewport_pixels[1], 0.1, @floatFromInt(2000 * 32)).multiply(zm.Mat4.lookAt(@Vector(3, f32){ 0, 0, 0 }, @Vector(3, f32){ 0, 0, 0 } + self.cameraFront, @This().cameraUp)).data));
    gl.UniformMatrix4fv(self.uniforms.entityprojviewlocation, 1, gl.TRUE, @ptrCast(&(projview)));
    var it = game.world.Entitys.iterator();
    defer it.deinit();
    while (it.next()) |c| {
        try c.value_ptr.*.draw(playerPos, c.key_ptr.*, &game.world, self);
    }
}

const MeshBufferIDs = struct {
    time: i64,
    vbo: ?c_uint,
    vao: ?c_uint,
    drawCommand: ?c_uint,
    UBO: c_uint,
    pos: [3]i32,
    count: u32,
    scale: f32,

    pub fn free(self: *const @This()) void {
        if (self.vbo) |vbo| gl.DeleteBuffers(1, @ptrCast(@constCast(&vbo)));
        if (self.vao) |vao| gl.DeleteVertexArrays(1, @ptrCast(@constCast(&vao)));
        if (self.drawCommand) |drawCommand| gl.DeleteBuffers(1, @ptrCast(@constCast(&drawCommand)));
        gl.DeleteBuffers(1, @ptrCast(&self.UBO));
    }
};

const DrawElementsIndirectCommand = packed struct {
    count: c_uint,
    instanceCount: c_uint,
    firstIndex: c_uint,
    baseVertex: c_uint,
    baseInstance: c_uint,
};

const UBO = packed struct {
    scale: f32,
    _0: u32,
    creationTime: f64,
    chunkPos: @Vector(3, i32),
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
    pub fn expand(self: *GpuBuffer, new_size: usize) !void {
        std.debug.assert(new_size != 0);
        if (self.buffer != null and new_size <= self.len) return;
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
    }

    pub fn writeSegment(self: *GpuBuffer, offset: usize, data: []const u8) !void {
        try self.expand(offset + data.len);
        gl.NamedBufferSubData(self.buffer.?, @intCast(offset), @intCast(data.len), data.ptr);
        gl.Flush();
        try glError();
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
        list_lock: std.Thread.Mutex = .{},

        map: std.AutoArrayHashMapUnmanaged(K, *Space) = .empty,
        map_lock: std.Thread.Mutex = .{},

        buffer_changed: std.atomic.Value(bool) = .init(false),
        indirect_buffer: ?c_uint = null,

        const Space = struct {
            node: std.DoublyLinkedList.Node,
            free: bool,
            start: usize,
            length: usize,
        };

        pub fn put(self: *@This(), key: K, value: []const u8) !void {
            try ensureContext();
            const space = try self.add(value.len);
            {
                self.buff_lock.lockShared();
                defer self.buff_lock.unlockShared();
                try self.buffer.writeSegment(space.start, value);
            }
            gl.Flush();
            self.map_lock.lock();
            defer self.map_lock.unlock();
            self.buffer_changed.store(true, .seq_cst);
            const existing = try self.map.fetchPut(self.allocator, key, space);
            if(existing != null)std.log.err("TODO remove mesh", .{});
        }

        fn add(self: *@This(), length: usize) !*Space {
            self.list_lock.lock();
            defer self.list_lock.unlock();
            var node = self.linked_list.first orelse &(try self.expand(self.buffer.len + length)).node;
            while (true) {
                node = node.next orelse &(try self.expand(self.buffer.len + length)).node;
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

        fn expand(self: *@This(), new_size: usize) !*Space {
            std.log.debug("expanding to {d} bytes", .{new_size});
            self.buff_lock.lock();
            defer self.buff_lock.unlock();
            const old_size = self.buffer.len;
            std.debug.assert(new_size > old_size);
            try self.buffer.expand(new_size);
            const size_diff = new_size - old_size;
            const add_one: bool = self.linked_list.last == null or !@as(*Space, @fieldParentPtr("node", self.linked_list.last.?)).free;
            if (!add_one) {
                const last: *Space = @fieldParentPtr("node", self.linked_list.last.?);
                std.debug.assert(last.free);
                last.length += size_diff;
                return last;
            } else {
                const space_ptr = try self.allocator.create(Space);
                space_ptr.* = Space{
                    .node = undefined,
                    .free = true,
                    .start = old_size,
                    .length = size_diff,
                };
                self.linked_list.append(&space_ptr.node);
                return space_ptr;
            }
        }

        fn rebuildCommands(self: *@This(), element_size: usize) !usize {
            //if (!self.buffer_changed.swap(false, .seq_cst)) return;
            const rc = ztracy.ZoneNC(@src(), "rebuildCommands", 32213);
            defer rc.End();
            var dcount: u64 = 0;
            if (self.indirect_buffer == null) {
                var ib: c_uint = undefined;
                gl.GenBuffers(1, @ptrCast(&ib));
                try glError();
                self.indirect_buffer = ib;
            }
            
            self.map_lock.lock();
            const ac = ztracy.ZoneNC(@src(), "allocCommands", 32213);
            var commands = std.ArrayList(DrawElementsIndirectCommand).initCapacity(self.allocator, self.map.count()) catch |err| {
                self.map_lock.unlock();
                return err;
            };
            ac.End();
            const loop = ztracy.ZoneNC(@src(), "loop", 32213);
            var it = self.map.iterator();
            while (it.next()) |entry| {
                const space = entry.value_ptr.*;
                dcount += space.length;
                commands.appendAssumeCapacity(DrawElementsIndirectCommand{
                    .count = 6,
                    .firstIndex = 0,
                    .baseInstance = @intCast(@divExact(space.start, element_size)),
                    .baseVertex = 0,
                    .instanceCount = @intCast(@divExact(space.length, element_size)),
                });
            }
            loop.End();
            self.map_lock.unlock();
            std.log.debug("drawing {d} faces", .{dcount});
            const amount = commands.items.len;
            const bd  = ztracy.ZoneNC(@src(), "BufferData", 32213);
            defer bd.End();
            gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buffer.?);
            gl.BufferData(gl.DRAW_INDIRECT_BUFFER, @intCast(amount * @sizeOf(DrawElementsIndirectCommand)), commands.items.ptr, gl.DYNAMIC_DRAW);
            commands.deinit(self.allocator);
            return amount;
        }
        
    };
}
