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
uniforms: UniformLocations,
cameraFront: @Vector(3, f32),
load_queue: ConcurrentQueue(toRenderData, 32, true),
renderlist: ConcurrentHashMap(ChunkPos, MeshBufferIDs, std.hash_map.AutoContext(ChunkPos), 80, 32),
interface: Renderer,
viewport_pixels: @Vector(2, u32),

const toRenderData = struct {
    vbo: c_uint,
    Pos: ChunkPos,
    face_count: usize,
};
pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
    self.* = @This(){
        .allocator = allocator,
        .facebuffer = undefined,
        .indecies = undefined,
        .shaderprogram = undefined,
        .load_queue = .init(allocator),
        .entityshaderprogram = undefined,
        .cameraFront = undefined,
        .renderlist = .init(allocator),
        .blockAtlasTextureId = undefined,
        .uniforms = undefined,
        .viewport_pixels = .{ 0, 0 },
        .interface = .{
            .userdata = @ptrCast(self),
            .vtable = &.{
                .addChunk = addChunk,
                .removeChunk = removeChunk,
                .drawChunks = drawChunksFn,
                .containsChunk = containsChunk,
                .clear = clear,
                .setViewport = setViewport,
            },
        },
    };
    try self.CompileShaders();
    self.LoadFacebuffer();
    self.uniforms = UniformLocations.GetLocations(self.shaderprogram, self.entityshaderprogram);
    self.blockAtlasTextureId = try Textures.loadTextureArray(try std.fs.cwd().openDir("packs/default/Blocks/", .{ .iterate = true }), allocator);
}

pub fn deinit(self: *@This()) void {
    while (self.load_queue.popFirst()) |vbo| {
        gl.DeleteBuffers(1, @ptrCast(&vbo));
    }
    self.load_queue.deinit(true);

    var it = self.renderlist.iterator();
    while (it.next()) |entry| {
        const mesh = entry.value_ptr;
        mesh.free();
    }

    it.deinit();
    self.renderlist.deinit();

    gl.DeleteTextures(1, @ptrCast(&self.blockAtlasTextureId));
    gl.DeleteBuffers(1, @ptrCast(&self.indecies));
    gl.DeleteBuffers(1, @ptrCast(&self.facebuffer));
    gl.DeleteProgram(self.shaderprogram);
    gl.DeleteProgram(self.entityshaderprogram);
    std.log.info("renderer deinit", .{});
}

pub fn Draw(self: *@This(), game: *@import("../../Game.zig"), viewport_pixels: @Vector(2, f32)) ![2]u64 {
    const playerPos = self.player.physics.getPos();
    //draw chunks
    const blueSky = @Vector(4, f32){ 0, 0.4, 0.8, 1.0 };
    const greySky = @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 };
    const skyColor = std.math.lerp(blueSky, greySky, @as(@Vector(4, f32), @splat(@as(f32, @floatCast(@min(1.0, @max(0, playerPos[1] / 4096)))))));
    const c = ztracy.ZoneNC(@src(), "Clear", 32213);
    gl.ClearColor(skyColor[0], skyColor[1], skyColor[2], skyColor[3]);
    gl.Clear(gl.COLOR_BUFFER_BIT);
    gl.Clear(gl.DEPTH_BUFFER_BIT);
    c.End();
    if (!std.meta.eql(last_viewport, viewport_pixels)) gl.Viewport(0, 0, @intFromFloat(viewport_pixels[0]), @intFromFloat(viewport_pixels[1]));
    last_viewport = viewport_pixels;
    const dc = ztracy.ZoneNC(@src(), "DrawChunks", 24342);
    const drawn = self.DrawChunks(playerPos, skyColor, viewport_pixels);
    dc.End();
    const drawEntities = ztracy.ZoneNC(@src(), "drawEntities", 24342);
    try self.DrawEntities(game, playerPos, viewport_pixels);
    drawEntities.End();
    const um = ztracy.ZoneNC(@src(), "unloadMeshes", 54333);
    self.unloadMeshes(playerPos, game);
    um.End();
    {
        const glSync = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0) orelse null;
        defer if (glSync) |sync| gl.DeleteSync(sync);
        //  _ = try loadMeshes(self, glSync, 10 * std.time.us_per_ms, 40 * std.time.us_per_ms);
    }
    return drawn;
}

threadlocal var context: ?sdl.video.gl.Context = null;

pub const MeshWriter = struct {
    vbo: ?c_uint,
    pos: usize,
    interface: std.Io.Writer,

    pub fn init(buffer: []u8) MeshWriter {
        return .{
            .interface = initInterface(buffer),
            .vbo = null,
            .pos = 0,
        };
    }

    pub fn initInterface(buffer: []u8) std.Io.Writer {
        return .{
            .vtable = &.{
                .drain = drain,
                .sendFile = std.Io.Writer.unimplementedSendFile,
            },
            .buffer = buffer,
        };
    }
    const main = @import("../../main.zig");

    pub fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
        const d = ztracy.ZoneNC(@src(), "drain", 32213);
        defer d.End();
        _ = splat;
        _ = data;
        const buffered = io_w.buffered();
        if (buffered.len == 0) return 0;
        gl.makeProcTableCurrent(&main.proc_table);
        if (context == null) {
            context = main.contexts[std.crypto.random.intRangeAtMost(usize, 0, 511)]; //terrable solution
            context.?.makeCurrent(main.window) catch return error.WriteFailed;
        }
        context.?.makeCurrent(main.window) catch return error.WriteFailed;
        const mesh_writer: *MeshWriter = @alignCast(@fieldParentPtr("interface", io_w));
        var new_vbo: c_uint = undefined;
        gl.GenBuffers(1, @ptrCast(&new_vbo));
        glError() catch return error.WriteFailed;
        if (mesh_writer.vbo) |vbo| {
            gl.DeleteBuffers(1, @ptrCast(&vbo));
            @panic("TODO copy data");
        }
        gl.BindBuffer(gl.ARRAY_BUFFER, new_vbo);
        gl.BufferStorage(gl.ARRAY_BUFFER, @intCast(buffered.len), buffered.ptr, 0x0);
        gl.Finish();
        glError() catch {
            gl.DeleteBuffers(1, @ptrCast(&new_vbo));
            mesh_writer.vbo = null;
            return error.WriteFailed;
        };

        mesh_writer.vbo = new_vbo;
        mesh_writer.pos += buffered.len;
        _ = io_w.consumeAll();
        return buffered.len;
    }
};

fn glError() !void {
    if (true) return;
    switch (gl.GetError()) {
        gl.NO_ERROR => return,
        gl.INVALID_ENUM => return error.InvalidEnum,
        gl.INVALID_VALUE => return error.InvalidValue,
        gl.INVALID_OPERATION => return error.InvalidOperation,
        gl.INVALID_FRAMEBUFFER_OPERATION => return error.InvalidFramebufferOperation,
        gl.OUT_OF_MEMORY => return error.OutOfMemory,
        else => unreachable,
    }
}

fn frameLoadBuffers(self: *@This()) !void {
    const flb = ztracy.ZoneNC(@src(), "frameLoadBuffers", 32213);
    defer flb.End();
    while (self.load_queue.popFirst()) |vbo| {
        try self.loadBuffer(vbo.Pos, vbo.vbo, vbo.face_count, false);
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

fn containsChunk(userdata: *anyopaque, Pos: ChunkPos) bool {
    const self: *@This() = @ptrCast(@alignCast(userdata));
    return self.renderlist.contains(Pos);
}

pub fn LoadVbo(renderer: *@This(), Pos: ChunkPos, vbo: c_uint, face_count: usize, CreationTime: ?i64) MeshBufferIDs {
    var tempb: [2]c_uint = undefined;
    gl.GenBuffers(2, @ptrCast(&tempb));
    var NewMeshIDs: MeshBufferIDs = .{
        .vao = null,
        .vbo = vbo,
        .count = @intCast(face_count),
        .drawCommand = tempb[1],
        .UBO = tempb[0],
        .pos = Pos.position,
        .time = 0,
        .scale = @floatCast(ChunkPos.toScale(Pos.level)),
    };

    gl.BindBuffer(gl.UNIFORM_BUFFER, NewMeshIDs.UBO);
    const UniformBuffer = UBO{
        .chunkPos = Pos.position,
        .scale = @floatCast(ChunkPos.toScale(Pos.level)),
        .creationTime = @floatFromInt(CreationTime orelse std.time.milliTimestamp()),
        ._0 = undefined,
    };
    gl.BufferStorage(gl.UNIFORM_BUFFER, @sizeOf(UBO), @ptrCast(&UniformBuffer), 0x0);

    var a: c_uint = undefined;
    gl.GenVertexArrays(1, @ptrCast(&a));
    gl.BindVertexArray(a);
    NewMeshIDs.vao = a;
    NewMeshIDs.count = @intCast(face_count);
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, renderer.indecies);
    gl.BindBuffer(gl.ARRAY_BUFFER, renderer.facebuffer);
    gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(f32), 0);
    gl.EnableVertexAttribArray(0);
    gl.BindBuffer(gl.ARRAY_BUFFER, vbo);
    gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(u32), 0);
    gl.EnableVertexAttribArray(1);
    gl.VertexAttribDivisor(1, 1);
    gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, NewMeshIDs.drawCommand.?);
    const IndirectCommand: DrawElementsIndirectCommand = .{
        .count = 6,
        .baseInstance = 0,
        .baseVertex = 0,
        .firstIndex = 0,
        .instanceCount = @intCast(NewMeshIDs.count),
    };
    gl.BufferStorage(gl.DRAW_INDIRECT_BUFFER, @sizeOf(DrawElementsIndirectCommand), &IndirectCommand, 0x0);
    NewMeshIDs.time = CreationTime orelse std.time.milliTimestamp();
    return NewMeshIDs;
}

pub fn loadBuffer(self: *@This(), Pos: ChunkPos, vbo: c_uint, face_count: usize, animation: bool) !void {
    const ex = self.renderlist.get(Pos);
    var oldtime: ?i64 = null;
    if (ex) |m| {
        oldtime = m.time;
    }
    if (!animation) {
        oldtime = 0;
    }
    const mesh_buffer_ids = LoadVbo(self, Pos, vbo, face_count, oldtime);
    {
        const oldChunk = try self.renderlist.fetchPut(Pos, mesh_buffer_ids);
        if (oldChunk) |old_mesh| {
            old_mesh.free();
        }
    }
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
    var drawnchunks: u64 = 0;
    var torenderchunks: u64 = 0;
    const millitimestamp = std.time.milliTimestamp();
    gl.Uniform1d(self.uniforms.timelocation, @floatFromInt(millitimestamp));
    gl.Uniform3d(self.uniforms.playerposlocation, playerPos[0], playerPos[1], playerPos[2]);
    const frustrum = Frustum.extractFrustumPlanes(projview);
    //if (i == 1) gl.Disable(gl.CULL_FACE);
    //defer gl.Enable(gl.CULL_FACE);
    var list_it = self.renderlist.iterator();
    defer list_it.deinit();
    while (list_it.next()) |item| {
        torenderchunks += 1;
        const buffer_ids = item.value_ptr;
        const Pos = item.key_ptr.*;
        //std.debug.print("rendering: {any}\n", .{buffer_ids});
        const chunkSizeVec: @Vector(3, f32) = @splat(@floatCast(ChunkSize * buffer_ids.scale));
        const relativeChunkPos: @Vector(3, f32) = @floatCast((@as(@Vector(3, f32), @floatFromInt(Pos.position)) * chunkSizeVec) - playerPos);
        const cull = frustrum.boxInFrustum(.{ .max = relativeChunkPos + chunkSizeVec, .min = relativeChunkPos });
        if (!cull) continue;
        drawnchunks += 1;
        gl.BindVertexArray(buffer_ids.vao orelse continue);
        gl.BindBufferBase(gl.UNIFORM_BUFFER, 0, buffer_ids.UBO);
        gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, buffer_ids.drawCommand.?);
        gl.DrawElementsIndirect(gl.TRIANGLES, gl.UNSIGNED_INT, 0);
        try glError();
    }
}

fn drawChunksFn(userdata: *anyopaque, viewpos: @Vector(3, f64)) error{DrawFailed}!void {
    const self: *@This() = @ptrCast(@alignCast(userdata));
    (self.drawChunks(viewpos, .{ 32, 32, 32, 255 }, self.viewport_pixels)) catch return error.DrawFailed;
    //const glSync = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0) orelse null;
    //defer if (glSync) |sync| gl.DeleteSync(sync);
    self.frameLoadBuffers() catch return error.DrawFailed;
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
