const std = @import("std");
const ConcurrentQueue = @import("ConcurrentQueue").ConcurrentQueue;
const World = @import("../../world/World.zig");
const ChunkSize = World.ChunkSize;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Entity = World.Entity;
const Mesh = @import("../../Mesh.zig");
const ChunkPos = World.ChunkPos;
const EntityTypes = World.EntityTypes;
const gl = @import("gl");
const zm = @import("zm");
const ztracy = @import("ztracy");
const keepLoaded = @import("../../Loader.zig").keepLoaded;

const Frustum = @import("Frustum.zig").Frustum;
const Textures = @import("textures.zig");
const Renderer = @import("../../Renderer.zig");
pub const cameraUp = @Vector(3, f64){ 0, 1, 0 };

allocator: std.mem.Allocator,
facebuffer: c_uint,
indecies: c_uint,
entityshaderprogram: c_uint,
shaderprogram: c_uint,
blockAtlasTextureId: c_uint,
uniforms: UniformLocations,
cameraFront: @Vector(3, f32),
load_queue: ConcurrentQueue(Mesh, 32, true),
renderlist: ConcurrentHashMap(ChunkPos, MeshBufferIDs, std.hash_map.AutoContext(ChunkPos), 80, 32),
interface: Renderer,
viewport_pixels: @Vector(2, u32),

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
                .unloadChunks = unloadChunks,
            },
        },
    };
    try self.CompileShaders();
    self.LoadFacebuffer();
    self.uniforms = UniformLocations.GetLocations(self.shaderprogram, self.entityshaderprogram);
    self.blockAtlasTextureId = try Textures.loadTextureArray(try std.fs.cwd().openDir("packs/default/Blocks/", .{ .iterate = true }), allocator);
}

pub fn deinit(self: *@This()) void {
    while (self.load_queue.popFirst()) |mesh| {
        mesh.free(self.allocator);
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
        _ = try loadMeshes(self, glSync, 10 * std.time.us_per_ms, 40 * std.time.us_per_ms);
    }
    return drawn;
}

pub fn addChunk(userdata: *anyopaque, mesh: Mesh) error{ OutOfMemory, OutOfVideoMemory }!void {
    const self: *@This() = @ptrCast(@alignCast(userdata));
    _ = try self.load_queue.append(mesh);
}

fn loadMeshes(self: *@This(), glSync: ?*gl.sync, min_us: u32, max_us: u32) !u64 {
    const lm = ztracy.ZoneNC(@src(), "LoadMeshes", 156567756);
    defer lm.End();
    const st = std.time.microTimestamp();
    var amount: u64 = 0;
    while (true) {
        var syncStatus: c_int = undefined;
        if (glSync) |sync| gl.GetSynciv(sync, gl.SYNC_STATUS, @sizeOf(c_int), null, @ptrCast(&syncStatus)) else syncStatus = gl.UNSIGNALED;
        if (std.time.microTimestamp() - st > max_us or (syncStatus == gl.SIGNALED and std.time.microTimestamp() - st > min_us)) break;
        const mesh = self.load_queue.popFirst() orelse break;
        defer mesh.free(self.allocator);
        //defer _ = game.chunkManager.LoadingChunks.remove(mesh.Pos); i will probubly forget to readd this
        const isempty = mesh.faces == null and mesh.TransperentFaces == null;
        if (isempty) {
            self.remove(mesh.Pos);
            continue;
        }
        const ex = self.renderlist.get(mesh.Pos);
        defer amount += 1;
        var oldtime: ?i64 = null;
        if (ex) |m| {
            oldtime = m.time;
        }
        if (!mesh.animation) {
            oldtime = 0;
        }
        const mesh_buffer_ids = LoadMesh(self, mesh, oldtime);
        {
            const oldChunk = try self.renderlist.fetchPut(mesh.Pos, mesh_buffer_ids);
            if (oldChunk) |old_mesh| {
                old_mesh.free();
            }
        }
    }
    return amount;
}

fn remove(self: *@This(), Pos: ChunkPos) void {
    const ids = self.renderlist.fetchremove(Pos) orelse return;
    ids.free();
}

fn removeChunk(userdata: *anyopaque, Pos: ChunkPos) void {
    const emptyMesh: Mesh = .{ .Pos = Pos, .TransperentFaces = null, .faces = null, .scale = undefined, .animation = undefined };
    addChunk(userdata, emptyMesh) catch std.log.err("removemesh failed", .{});
}

fn containsChunk(userdata: *anyopaque, Pos: ChunkPos) bool {
    const self: *@This() = @ptrCast(@alignCast(userdata));
    return self.renderlist.contains(Pos);
}

fn unloadChunks(userdata: *anyopaque, playerPos: @Vector(3, f64), mesh_distance: @Vector(2, u32), min_level: i32, max_level: i32, inner_radius: @Vector(2, u32)) void {
    const unload = ztracy.ZoneNC(@src(), "UnloadMeshes", 75645);
    defer unload.End();
    const self: *@This() = @ptrCast(@alignCast(userdata));
    var buffer: [256]ChunkPos = undefined;
    var tounload: std.ArrayList(ChunkPos) = .initBuffer(&buffer);
    {
        const loop = ztracy.ZoneNC(@src(), "loopMeshes", 6788676);
        defer loop.End();
        var list_it = self.renderlist.iterator();
        defer list_it.deinit();
        while (list_it.next()) |entry| {
            const Pos: ChunkPos = entry.key_ptr.*;
            const innerRadius: @Vector(2, u32) = if (Pos.level > min_level) inner_radius else @splat(0);
            const keep = keepLoaded(min_level, max_level, playerPos, Pos, innerRadius, mesh_distance);
            if (keep) continue;
            tounload.appendBounded(Pos) catch break;
        }
    }

    const free = ztracy.ZoneNC(@src(), "freeMeshes", 8799877);
    defer free.End();
    for (tounload.items) |Pos| {
        self.remove(Pos);
    }
}

fn LoadMesh(renderer: *@This(), mesh: Mesh, CreationTime: ?i64) MeshBufferIDs {
    var NewMeshIDs: MeshBufferIDs = .{
        .vao = [2]?c_uint{ null, null },
        .vbo = [2]?c_uint{ null, null },
        .count = [2]u32{ 0, 0 },
        .drawCommand = [2]?c_uint{ null, null },
        .UBO = undefined,
        .pos = mesh.Pos.position,
        .time = 0,
        .scale = @floatCast(ChunkPos.toScale(mesh.Pos.level)),
    };

    gl.GenBuffers(1, @ptrCast(&NewMeshIDs.UBO));
    gl.BindBuffer(gl.UNIFORM_BUFFER, NewMeshIDs.UBO);
    const UniformBuffer = UBO{
        .chunkPos = mesh.Pos.position,
        .scale = @floatCast(ChunkPos.toScale(mesh.Pos.level)),
        .creationTime = @floatFromInt(CreationTime orelse std.time.milliTimestamp()),
        ._0 = undefined,
    };
    gl.BufferData(gl.UNIFORM_BUFFER, @sizeOf(UBO), @ptrCast(&UniformBuffer), gl.STATIC_DRAW);

    inline for (0..2) |i| {
        const faces = if (i == 0) mesh.faces else mesh.TransperentFaces;
        if (faces) |f| {
            var a: c_uint = undefined;
            var b: c_uint = undefined;
            gl.GenVertexArrays(1, @ptrCast(&a));
            gl.BindVertexArray(a);
            gl.GenBuffers(1, @ptrCast(&b));
            gl.BindBuffer(gl.ARRAY_BUFFER, b);
            NewMeshIDs.vao[i] = a;
            NewMeshIDs.vbo[i] = b;
            const bytes = std.mem.sliceAsBytes(f);
            gl.BufferData(gl.ARRAY_BUFFER, @intCast(@sizeOf(Mesh.Face) * f.len), bytes.ptr, gl.STATIC_DRAW);
            NewMeshIDs.count[i] = @intCast(f.len);
            gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, renderer.indecies);
            gl.BindBuffer(gl.ARRAY_BUFFER, renderer.facebuffer);
            gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(f32), 0);
            gl.EnableVertexAttribArray(0);
            gl.BindBuffer(gl.ARRAY_BUFFER, b);
            gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(u32), 0);
            gl.EnableVertexAttribArray(1);
            gl.VertexAttribDivisor(1, 1);
            var indirectBuff: c_uint = undefined;
            gl.GenBuffers(1, @ptrCast(&indirectBuff));
            gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, indirectBuff);
            const IndirectCommand: DrawElementsIndirectCommand = .{
                .count = 6,
                .baseInstance = 0,
                .baseVertex = 0,
                .firstIndex = 0,
                .instanceCount = @intCast(NewMeshIDs.count[i]),
            };
            gl.BufferData(gl.DRAW_INDIRECT_BUFFER, @sizeOf(DrawElementsIndirectCommand), &IndirectCommand, gl.STATIC_DRAW);
            NewMeshIDs.drawCommand[i] = indirectBuff;
        }
    }
    NewMeshIDs.time = CreationTime orelse std.time.milliTimestamp();

    gl.BindBuffer(gl.ARRAY_BUFFER, 0);
    gl.BindVertexArray(0);
    return NewMeshIDs;
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
    inline for (0..2) |i| {
        if (i == 1) gl.Disable(gl.CULL_FACE);
        defer gl.Enable(gl.CULL_FACE);
        var list_it = self.renderlist.iterator();
        defer list_it.deinit();
        while (list_it.next()) |item| {
            torenderchunks += 1;
            const buffer_ids = item.value_ptr;
            const Pos = item.key_ptr.*;

            const chunkSizeVec: @Vector(3, f32) = @splat(@floatCast(ChunkSize * buffer_ids.scale));
            const relativeChunkPos: @Vector(3, f32) = @floatCast((@as(@Vector(3, f32), @floatFromInt(Pos.position)) * chunkSizeVec) - playerPos);
            const cull = frustrum.boxInFrustum(.{ .max = relativeChunkPos + chunkSizeVec, .min = relativeChunkPos });
            if (!cull) continue;
            drawnchunks += 1;
            gl.BindVertexArray(buffer_ids.vao[i] orelse continue);
            gl.BindBufferBase(gl.UNIFORM_BUFFER, 0, buffer_ids.UBO);
            gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, buffer_ids.drawCommand[i].?);
            gl.DrawElementsIndirect(gl.TRIANGLES, gl.UNSIGNED_INT, 0);
        }
    }
}

fn drawChunksFn(userdata: *anyopaque, viewpos: @Vector(3, f64)) error{DrawFailed}!void {
    const self: *@This() = @ptrCast(@alignCast(userdata));
    (self.drawChunks(viewpos, .{ 32, 32, 32, 255 }, self.viewport_pixels)) catch return error.DrawFailed;
    const glSync = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0) orelse null;
    defer if (glSync) |sync| gl.DeleteSync(sync);
    _ = loadMeshes(self, glSync, 10 * std.time.us_per_ms, 40 * std.time.us_per_ms) catch return error.DrawFailed;
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
    vbo: [2]?c_uint,
    vao: [2]?c_uint,
    drawCommand: [2]?c_uint,
    UBO: c_uint,
    pos: [3]i32,
    count: [2]u32,
    scale: f32,

    pub fn free(self: *const @This()) void {
        inline for (0..2) |i| {
            if (self.vbo[i]) |vbo| gl.DeleteBuffers(1, @ptrCast(@constCast(&vbo)));
            if (self.vao[i]) |vao| gl.DeleteVertexArrays(1, @ptrCast(@constCast(&vao)));
            if (self.drawCommand[i]) |drawCommand| gl.DeleteBuffers(1, @ptrCast(@constCast(&drawCommand)));
        }
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
