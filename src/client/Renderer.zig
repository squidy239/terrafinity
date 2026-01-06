const std = @import("std");
const builtin = @import("builtin");
const ConcurrentQueue = @import("root").ConcurrentQueue.ConcurrentQueue;
const root = @import("root");
const ChunkManager = root.ChunkManager;
const Loader = root.Loader;
const ThreadPool = @import("root").ThreadPool;
const Game = @import("../Game.zig").Game;
const Block = @import("Block").Blocks;
const ChunkSize = @import("../App.zig").ChunkSize;
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Entity = @import("root").Entity;
const EntityTypes = @import("EntityTypes");
const gl = @import("gl");
const glfw = @import("zglfw");
const Player = @import("EntityTypes").Player;
const UpdateEntitiesThread = @import("Entity").TickEntitiesThread;
const zm = @import("zm");
const ztracy = @import("ztracy");

const Frustum = @import("Frustum.zig").Frustum;
const Textures = @import("textures.zig");

pub const Renderer = struct {
    pub const cameraUp = @Vector(3, f64){ 0, 1, 0 };
    allocator: std.mem.Allocator,
    facebuffer: c_uint,
    player: *Entity,
    cameraFront: @Vector(3, f64),
    mouseSensitivity: f64,
    indecies: c_uint,
    entityshaderprogram: c_uint,
    shaderprogram: c_uint,
    blockAtlasTextureId: c_uint,
    uniforms: UniformLocations,

    pub fn init(allocator: std.mem.Allocator, player: *Entity) !@This() {
        _ = player.ref_count.fetchAdd(1, .seq_cst);
        var renderer = @This(){
            .allocator = allocator,
            .mouseSensitivity = 0.2,
            .cameraFront = @Vector(3, f64){ 0.0001, -0.4, 0.001 },
            .facebuffer = undefined,
            .indecies = undefined,
            .shaderprogram = undefined,
            .entityshaderprogram = undefined,
            .blockAtlasTextureId = undefined,
            .uniforms = undefined,
            .player = player,
        };

        try renderer.CompileShaders();
        renderer.LoadFacebuffer();
        renderer.uniforms = UniformLocations.GetLocations(renderer.shaderprogram, renderer.entityshaderprogram);
        renderer.blockAtlasTextureId = try Textures.loadTextureArray(try std.fs.cwd().openDir("packs/default/Blocks/", .{ .iterate = true }), allocator);
        return renderer;
    }

    pub fn deinit(self: *@This()) void {
        _ = self.player.ref_count.fetchSub(1, .seq_cst);
        gl.DeleteTextures(1, @ptrCast(&self.blockAtlasTextureId));
        gl.DeleteBuffers(1, @ptrCast(&self.indecies));
        gl.DeleteBuffers(1, @ptrCast(&self.facebuffer));
        gl.DeleteProgram(self.shaderprogram);
        gl.DeleteProgram(self.entityshaderprogram);
        std.log.info("renderer deinit", .{});
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
    pub fn Draw(self: *@This(), game: *Game, viewport_pixels: @Vector(2, f32)) ![2]u64 {
        const playerPos = self.player.getPos().?;
        //draw chunks
        const blueSky = @Vector(4, f32){ 0, 0.4, 0.8, 1.0 };
        const greySky = @Vector(4, f32){ 0.5, 0.5, 0.5, 1.0 };
        const skyColor = std.math.lerp(blueSky, greySky, @as(@Vector(4, f32), @splat(@as(f32, @floatCast(@min(1.0, @max(0, playerPos[1] / 4096)))))));
        const clear = ztracy.ZoneNC(@src(), "Clear", 32213);
        gl.ClearColor(skyColor[0], skyColor[1], skyColor[2], skyColor[3]);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.Clear(gl.DEPTH_BUFFER_BIT);
        clear.End();

        const drawChunks = ztracy.ZoneNC(@src(), "DrawChunks", 24342);
        const drawn = self.DrawChunks(game, playerPos, skyColor, viewport_pixels);
        drawChunks.End();
        const drawEntities = ztracy.ZoneNC(@src(), "drawEntities", 24342);
        try self.DrawEntities(game, playerPos, viewport_pixels);
        drawEntities.End();
        const gen_distance = game.getGenDistance();
        const unloadMeshes = ztracy.ZoneNC(@src(), "unloadMeshes", 54333);
        Loader.UnloadMeshes(game, gen_distance, playerPos);
        unloadMeshes.End();
        {
            const glSync = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0) orelse null;
            defer if (glSync) |sync| gl.DeleteSync(sync);
            _ = try Loader.LoadMeshes(self, game, glSync, 10 * std.time.us_per_ms, 40 * std.time.us_per_ms);
        }
        return drawn;
    }
    fn DrawChunks(self: *@This(), game: *Game, playerPos: @Vector(3, f64), skyColor: @Vector(4, f32), viewport_pixels: @Vector(2, f32)) [2]u64 {
        gl.FrontFace(gl.CW);
        gl.UseProgram(self.shaderprogram);
        gl.BindTexture(gl.TEXTURE_2D_ARRAY, self.blockAtlasTextureId);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.indecies);
        const sunrot = zm.Mat4f.rotation(@Vector(3, f32){ 1.0, 0.0, 0.0 }, std.math.degreesToRadians(180));
        const projdist = 10000000;
        const view = zm.Mat4.lookAt(@Vector(3, f32){ 0, 0, 0 }, self.cameraFront, Renderer.cameraUp);
        const projection = zm.Mat4.perspective(std.math.degreesToRadians(90.0), viewport_pixels[0] / viewport_pixels[1], 0.1, @floatFromInt(projdist));
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
            var list_it = game.chunkManager.ChunkRenderList.iterator();
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
        return [2]u64{ drawnchunks, torenderchunks };
    }

    pub fn DrawEntities(self: *@This(), game: *Game, playerPos: @Vector(3, f64), viewport_pixels: @Vector(2, f32)) !void {
        gl.FrontFace(gl.CCW);
        gl.UseProgram(self.entityshaderprogram);
        const projview = @as(@Vector(16, f32), @floatCast(zm.Mat4.perspective(std.math.degreesToRadians(90.0), viewport_pixels[0] / viewport_pixels[1], 0.1, @floatFromInt(2000 * 32)).multiply(zm.Mat4.lookAt(@Vector(3, f32){ 0, 0, 0 }, @Vector(3, f32){ 0, 0, 0 } + self.cameraFront, Renderer.cameraUp)).data));
        gl.UniformMatrix4fv(self.uniforms.entityprojviewlocation, 1, gl.TRUE, @ptrCast(&(projview)));
        var it = game.chunkManager.world.Entitys.iterator();
        defer it.deinit();
        while (it.next()) |c| {
            try c.value_ptr.*.draw(playerPos, c.key_ptr.*, &game.world, self);
        }
    }
};

pub const MeshBufferIDs = struct {
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

pub const DrawElementsIndirectCommand = packed struct {
    count: c_uint,
    instanceCount: c_uint,
    firstIndex: c_uint,
    baseVertex: c_uint,
    baseInstance: c_uint,
};

pub const UBO = packed struct {
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
