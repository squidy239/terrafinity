const std = @import("std");
const Chunk = @import("Chunk");
const zm = @import("zm");
const World = @import("World").World;
const Mesher = @import("Mesher.zig");
const gl = @import("gl");
const glfw = @import("zglfw");
const ztracy = @import("ztracy");
const ConcurrentHashMap = @import("ConcurrentHashMap").ConcurrentHashMap;
const Block = @import("Block").Blocks;
const ChunkSize = 32;

const UniformLocations = struct {
    projviewlocation: c_int,
    relativechunkposlocation: c_int,
    chunkposlocation: c_int,
    tlocation: c_int,
    sunlocation: c_int,
    scalelocation: c_int,
    timelocation: c_int,

    pub fn GetLocations(shaderprogram: c_uint) @This() {
        return @This(){
            .projviewlocation = gl.GetUniformLocation(shaderprogram, "projview"),
            .relativechunkposlocation = gl.GetUniformLocation(shaderprogram, "relativechunkpos"),
            .chunkposlocation = gl.GetUniformLocation(shaderprogram, "chunkpos"),
            .tlocation = gl.GetUniformLocation(shaderprogram, "chunktime"),
            .sunlocation = gl.GetUniformLocation(shaderprogram, "sunrot"),
            .scalelocation = gl.GetUniformLocation(shaderprogram, "scale"),
            .timelocation = gl.GetUniformLocation(shaderprogram, "time"),
        };
    }
};
pub const ProjectionParams = struct {
    eyePos: @Vector(3, f64),
    cameraFront: @Vector(3, f64),
    cameraUp: @Vector(3, f64),
};

pub const Renderer = struct {
    pub const cameraUp = @Vector(3, f64){ 0, 1, 0 };
    allocator: std.mem.Allocator,
    pool: *std.Thread.Pool,
    world: *World,
    facebuffer: c_uint,
    eyePos: @Vector(3, f64), //x,y,z
    rotationAxis: @Vector(3, f64), //pitch, yaw,roll
    cameraFront: @Vector(3, f64),
    mouseSensitivity: f64,
    indecies: c_uint,
    shaderprogram: c_uint,
    uniforms: UniformLocations,
    MeshesToLoad: std.ArrayList(Mesher.Mesh),
    LoadingChunks: ConcurrentHashMap([3]i32, bool, std.hash_map.AutoContext([3]i32), 80, 32),
    MeshesToLoadLock: std.Thread.RwLock,
    ChunkRenderList: std.AutoArrayHashMap([3]i32, MeshBufferIDs),
    ChunkRenderListLock: std.Thread.RwLock,
    MeshDistance: [3]std.atomic.Value(u32),
    GenerateDistance: [3]std.atomic.Value(u32),
    LoadDistance: [3]std.atomic.Value(u32),
    window: *glfw.Window,
    proc_table: *gl.ProcTable,
    screen_dimensions: [2]u32,

    ///must be called on main thread
    pub fn Init(pool: *std.Thread.Pool, world: *World, proc_table_location: *gl.ProcTable, eyepos: @Vector(3, f64), allocator: std.mem.Allocator) !@This() {
        var renderer = @This(){
            .allocator = allocator,
            .pool = pool,
            .world = world,
            .mouseSensitivity = 0.2,
            .rotationAxis = @Vector(3, f64){ 0, 0, 0 },
            .cameraFront = @Vector(3, f64){ 0, 1, 0 },
            .facebuffer = undefined,
            .indecies = undefined,
            .shaderprogram = undefined,
            .MeshesToLoad = std.ArrayList(Mesher.Mesh).init(allocator),
            .MeshesToLoadLock = .{},
            .uniforms = undefined,
            .eyePos = eyepos,
            .LoadingChunks = ConcurrentHashMap([3]i32, bool, std.hash_map.AutoContext([3]i32), 80, 32).init(allocator),
            .ChunkRenderList = std.AutoArrayHashMap([3]i32, MeshBufferIDs).init(allocator),
            .ChunkRenderListLock = .{},
            .GenerateDistance = [3]std.atomic.Value(u32){ std.atomic.Value(u32).init(20), std.atomic.Value(u32).init(20), std.atomic.Value(u32).init(20) },
            .LoadDistance = [3]std.atomic.Value(u32){ std.atomic.Value(u32).init(20), std.atomic.Value(u32).init(20), std.atomic.Value(u32).init(20) },
            .MeshDistance = [3]std.atomic.Value(u32){ std.atomic.Value(u32).init(20), std.atomic.Value(u32).init(20), std.atomic.Value(u32).init(20) },
            .window = undefined,
            .proc_table = proc_table_location,
            .screen_dimensions = [2]u32{ 800, 600 },
        };

        try renderer.InitWindowAndProcs();
        try renderer.CompileShaders();
        renderer.LoadFacebuffer();
        renderer.uniforms = UniformLocations.GetLocations(renderer.shaderprogram);
        return renderer;
    }
    ///threadpool should be deinitualised before calling, dosent destroy window
    pub fn deinit(self: *@This()) void {
        gl.DeleteBuffers(1, @ptrCast(&self.indecies));
        gl.DeleteBuffers(1, @ptrCast(&self.facebuffer));
        gl.DeleteProgram(self.shaderprogram);
        self.ChunkRenderListLock.lock();
        var it = self.ChunkRenderList.iterator();
        while (it.next()) |mesh| {
            inline for (0..1) |i| {
                if (mesh.value_ptr.vbo[i]) |vbo| gl.DeleteBuffers(1, @constCast(@ptrCast(&vbo)));
                if (mesh.value_ptr.vao[i]) |vao| gl.DeleteVertexArrays(1, @constCast(@ptrCast(&vao)));
            }
        }
        glfw.terminate();
        self.ChunkRenderList.deinit();
        self.LoadingChunks.deinit();
        self.MeshesToLoadLock.lock();
        for (self.MeshesToLoad.items) |mesh| {
            FreeMesh(mesh, self.allocator);
        }
        self.MeshesToLoad.deinit();
        std.debug.print("stopped renderer\n", .{});
    }
    fn InitWindowAndProcs(self: *@This()) !void {
        try glfw.init();
        const gl_versions = [_][2]c_int{ [2]c_int{ 4, 6 }, [2]c_int{ 4, 5 }, [2]c_int{ 4, 4 }, [2]c_int{ 4, 3 }, [2]c_int{ 4, 2 }, [2]c_int{ 4, 1 }, [2]c_int{ 4, 0 }, [2]c_int{ 3, 3 } };
        for (gl_versions) |version| {
            std.log.info("trying OpenGL version {d}.{d}\n", .{ version[0], version[1] });
            glfw.windowHint(.context_version_major, version[0]);
            glfw.windowHint(.context_version_minor, version[1]);
            glfw.windowHint(.opengl_forward_compat, true);
            glfw.windowHint(.client_api, .opengl_api);
            glfw.windowHint(.doublebuffer, true);
            glfw.windowHint(.samples, 4);

            self.window = try glfw.Window.create(800, 600, "voxelgame", null);

            glfw.makeContextCurrent(self.window);
            if (self.proc_table.init(glfw.getProcAddress)) {
                std.log.info("using OpenGL version {d}.{d}\n", .{ version[0], version[1] });
                break;
            } else {
                self.window.destroy();
            }
        }
        gl.makeProcTableCurrent(self.proc_table);
        const xz = self.window.getContentScale();
        gl.Viewport(0, 0, @intFromFloat(800 * xz[0]), @intFromFloat(600 * xz[1]));
        glfw.swapInterval(1);
        gl.Enable(gl.DEPTH_TEST);
        gl.Enable(gl.CULL_FACE);
        gl.CullFace(gl.BACK);
        gl.FrontFace(gl.CW);
        gl.DepthFunc(gl.LESS);
        gl.Enable(gl.BLEND);
        gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
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
        gl.GetProgramiv(shaderprogram, gl.LINK_STATUS, &linkstatus);
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
        gl.UseProgram(shaderprogram);
        gl.DeleteShader(vertexshader);
        gl.DeleteShader(fragshader);
        self.shaderprogram = shaderprogram;
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

    pub fn DrawChunks(self: *@This()) void {
        self.ChunkRenderListLock.lockShared();
        defer self.ChunkRenderListLock.unlockShared();
        gl.ClearColor(0, 0.3, 0.5, 1.0);

        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.Clear(gl.DEPTH_BUFFER_BIT);

        const projview = @as(@Vector(16, f32), @floatCast(zm.Mat4.perspective(std.math.degreesToRadians(90.0), @as(f32, @floatFromInt(self.screen_dimensions[0])) / @as(f32, @floatFromInt(self.screen_dimensions[1])), 0.1, @floatFromInt(200 * 32)).multiply(zm.Mat4.lookAt(@Vector(3, f32){ 0, 0, 0 }, @Vector(3, f32){ 0, 0, 0 } + self.cameraFront, Renderer.cameraUp)).data));
        gl.UniformMatrix4fv(self.uniforms.projviewlocation, 1, gl.TRUE, @ptrCast(&(projview)));
        const sunrot = zm.Mat4.rotation(@Vector(3, f32){ 1.0, 0.0, 0.0 }, std.math.degreesToRadians(@as(f32, @floatFromInt(@mod(@divFloor(std.time.milliTimestamp(), 100), 360)))));
        gl.UniformMatrix4fv(self.uniforms.sunlocation, 1, gl.TRUE, @ptrCast(&(sunrot)));

        //std.debug.print("{d}\n", .{MainWorld.ChunkMeshes.items.len});
        var it = self.ChunkRenderList.iterator();
        var drawnchunks: u64 = 0;
        const millitimestamp = std.time.milliTimestamp();
        gl.Uniform1d(self.uniforms.timelocation, @floatFromInt(millitimestamp)); //bool

        inline for (0..2) |i| {
            //if (i == 1) gl.Disable(gl.CULL_FACE);
            //defer gl.Enable(gl.CULL_FACE);
            while (it.next()) |item| {
                const buffer_ids = item.value_ptr;
                const Pos = item.key_ptr.*;
                gl.BindVertexArray(buffer_ids.vao[i] orelse continue);
                drawnchunks += 1;
                var tr = millitimestamp - buffer_ids.time;
                if (tr > 1000) {
                    @branchHint(.likely);
                    tr = 1000;
                }
                gl.Uniform1f(self.uniforms.scalelocation, buffer_ids.scale);
                gl.Uniform1i(self.uniforms.tlocation, @intCast(tr));
                gl.Uniform3i(self.uniforms.chunkposlocation, Pos[0], Pos[1], Pos[2]);
                //player height
                gl.Uniform3f(self.uniforms.relativechunkposlocation, @floatCast((@as(f64, @floatFromInt(Pos[0])) * buffer_ids.scale * ChunkSize) - self.eyePos[0]), @floatCast((@as(f64, @floatFromInt(Pos[1])) * buffer_ids.scale * ChunkSize) - self.eyePos[1]), @floatCast((@as(f64, @floatFromInt(Pos[2])) * buffer_ids.scale * ChunkSize) - self.eyePos[2]));
                //TODO frustrum cullling and LODs
                gl.DrawElementsInstanced(gl.TRIANGLES, 6, gl.UNSIGNED_INT, null, @intCast(buffer_ids.count[i]));
            }
        }
    }
    ///Adds a chunk to the render list replacing it if it already exists, generates it or its neighbors if it dosent exist
    pub fn AddChunkToRender(self: *@This(), Pos: [3]i32) !void {
        const GenMeshAndAdd = ztracy.ZoneNC(@src(), "GenMeshAndAdd", 324342342);
        defer GenMeshAndAdd.End();
        const chunk = try self.world.LoadChunk(Pos);
        chunk.lock.lockShared(); //ref is added in loadchunk
        defer chunk.releaseAndUnlockShared();

        const neighbor_faces = [6][ChunkSize][ChunkSize]Block{
            (try self.world.LoadChunk(Pos + @Vector(3, i32){ 1, 0, 0 })).extractFace(.xMinus, true),
            (try self.world.LoadChunk(Pos + @Vector(3, i32){ -1, 0, 0 })).extractFace(.xPlus, true),
            (try self.world.LoadChunk(Pos + @Vector(3, i32){ 0, 1, 0 })).extractFace(.yMinus, true),
            (try self.world.LoadChunk(Pos + @Vector(3, i32){ 0, -1, 0 })).extractFace(.yPlus, true),
            (try self.world.LoadChunk(Pos + @Vector(3, i32){ 0, 0, 1 })).extractFace(.zMinus, true),
            (try self.world.LoadChunk(Pos + @Vector(3, i32){ 0, 0, -1 })).extractFace(.zPlus, true),
        };

        const exbl = ztracy.ZoneNC(@src(), "extractBlocks", 3222);
        var blocks: *[ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        var Tempcube: [ChunkSize][ChunkSize][ChunkSize]Block = undefined;
        switch (chunk.blocks) {
            .blocks => blocks = chunk.blocks.blocks,
            .oneBlock => {
                var dd: [ChunkSize][ChunkSize]Block = undefined;
                @memset(&dd, @splat(chunk.blocks.oneBlock));
                Tempcube = @splat((dd));
                blocks = &Tempcube;
            },
        }
        exbl.End();
        const mesh = try Mesher.Mesh.MeshFromChunks(Pos, (blocks), neighbor_faces, self.allocator);
        if (mesh) |m| {
            self.MeshesToLoadLock.lock();
            defer self.MeshesToLoadLock.unlock();
            try self.MeshesToLoad.append(m);
        }
    }

    ///Adds a chunk to the render list, generates it or its neighbors if it dosent exist
    pub inline fn AddChunkToRenderNoError(self: *@This(), Pos: [3]i32) void {
        self.AddChunkToRender(Pos) catch |err| std.log.err("addchunktorenderError:{any}", .{err});
    }

    ///must be called on main thread
    pub fn LoadMeshes(self: *@This(), max_to_load: u32) !void {
        if (!self.MeshesToLoadLock.tryLock()) return; //dont block the main thread
        defer self.MeshesToLoadLock.unlock();
        const MeshesToLoadLen: usize = self.MeshesToLoad.items.len;
        for (0..MeshesToLoadLen) |amount_unloaded| {
            if (amount_unloaded >= max_to_load) break;
            const mesh = self.MeshesToLoad.swapRemove(0);
            defer FreeMesh(mesh, self.allocator);
            const mesh_buffer_ids = self.LoadMesh(mesh);
            {
                self.ChunkRenderListLock.lock();
                defer self.ChunkRenderListLock.unlock();
                const oldChunk = try self.ChunkRenderList.fetchPut(mesh.Pos, mesh_buffer_ids);
                if (oldChunk) |old_mesh| {
                    std.debug.print("remeshed chunk at pos:{d}\n", .{mesh.Pos});
                    inline for (0..1) |i| {
                        if (old_mesh.value.vbo[i]) |vbo| gl.DeleteBuffers(1, @constCast(@ptrCast(&vbo)));
                        if (old_mesh.value.vao[i]) |vao| gl.DeleteVertexArrays(1, @constCast(@ptrCast(&vao)));
                    }
                }
            }
            _ = self.LoadingChunks.remove(mesh.Pos);
        }
    }

    pub fn FreeMesh(mesh: Mesher.Mesh, allocator: std.mem.Allocator) void {
        if (mesh.faces) |faces| allocator.free(faces);
        if (mesh.TransperentFaces) |tfaces| allocator.free(tfaces);
    }

    ///caller must free mesh, must be called from main thread
    fn LoadMesh(self: *@This(), mesh: Mesher.Mesh) MeshBufferIDs {
        var NewMeshIDs: MeshBufferIDs = .{
            .vao = [2]?c_uint{ null, null },
            .vbo = [2]?c_uint{ null, null },
            .count = [2]u32{ 0, 0 },
            .scale = 1,
            .pos = mesh.Pos,
            .time = 0,
        };
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
                gl.BufferData(gl.ARRAY_BUFFER, @intCast(@sizeOf(Mesher.Face) * f.len), bytes.ptr, gl.STATIC_DRAW);
                NewMeshIDs.count[i] = @intCast(f.len);
                gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.indecies);
                gl.BindBuffer(gl.ARRAY_BUFFER, self.facebuffer);
                gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(f32), 0);
                gl.EnableVertexAttribArray(0);
                gl.BindBuffer(gl.ARRAY_BUFFER, b);
                gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(u32), 0);
                gl.EnableVertexAttribArray(1);
                gl.VertexAttribDivisor(1, 1);
            }
        }

        gl.BindBuffer(gl.ARRAY_BUFFER, 0);
        gl.BindVertexArray(0);
        NewMeshIDs.time = std.time.milliTimestamp();
        return NewMeshIDs;
    }

    pub const MeshBufferIDs = struct {
        time: i64,
        vbo: [2]?c_uint,
        vao: [2]?c_uint,
        pos: [3]i32,
        count: [2]u32,
        scale: f32,
    };
};
