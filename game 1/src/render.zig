const glfw = @import("glfw");
const gl = @import("gl");
const zm = @import("zm");
const std = @import("std");
const zstbi = @import("zstbi");
const glfw_log = std.log.scoped(.glfw);
const gl_log = std.log.scoped(.gl);
const vsync = false;
const world = @import("world.zig");
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//-----------------------------------------------------------------------
var width: f32 = 1920;
var height: f32 = 1080;
pub var VAO:c_uint = undefined;
pub var VBO:c_uint = undefined;
var pitch: f64 = 0;
var yaw: f64 = 0;
const allocator = gpa.allocator();
var lastX: f64 = 0;
var lastY: f64 = 0;
var shaderprogram: c_uint = undefined;
var texture = [_]c_uint{undefined};
//-------------------------------------------------------------------------
pub const vertices = [_]f32{ -0.5, -0.5, -0.5, 0.0, 0.0, 0.5, -0.5, -0.5, 1.0, 0.0, 0.5, 0.5, -0.5, 1.0, 1.0, 0.5, 0.5, -0.5, 1.0, 1.0, -0.5, 0.5, -0.5, 0.0, 1.0, -0.5, -0.5, -0.5, 0.0, 0.0, -0.5, -0.5, 0.5, 0.0, 0.0, 0.5, -0.5, 0.5, 1.0, 0.0, 0.5, 0.5, 0.5, 1.0, 1.0, 0.5, 0.5, 0.5, 1.0, 1.0, -0.5, 0.5, 0.5, 0.0, 1.0, -0.5, -0.5, 0.5, 0.0, 0.0, -0.5, 0.5, 0.5, 1.0, 0.0, -0.5, 0.5, -0.5, 1.0, 1.0, -0.5, -0.5, -0.5, 0.0, 1.0, -0.5, -0.5, -0.5, 0.0, 1.0, -0.5, -0.5, 0.5, 0.0, 0.0, -0.5, 0.5, 0.5, 1.0, 0.0, 0.5, 0.5, 0.5, 1.0, 0.0, 0.5, 0.5, -0.5, 1.0, 1.0, 0.5, -0.5, -0.5, 0.0, 1.0, 0.5, -0.5, -0.5, 0.0, 1.0, 0.5, -0.5, 0.5, 0.0, 0.0, 0.5, 0.5, 0.5, 1.0, 0.0, -0.5, -0.5, -0.5, 0.0, 1.0, 0.5, -0.5, -0.5, 1.0, 1.0, 0.5, -0.5, 0.5, 1.0, 0.0, 0.5, -0.5, 0.5, 1.0, 0.0, -0.5, -0.5, 0.5, 0.0, 0.0, -0.5, -0.5, -0.5, 0.0, 1.0, -0.5, 0.5, -0.5, 0.0, 1.0, 0.5, 0.5, -0.5, 1.0, 1.0, 0.5, 0.5, 0.5, 1.0, 0.0, 0.5, 0.5, 0.5, 1.0, 0.0, -0.5, 0.5, 0.5, 0.0, 0.0, -0.5, 0.5, -0.5, 0.0, 1.0 };

const indecies = [_]i32{ // note that we start from 0!
    0, 1, 3, // first triangle
    1, 2, 3, // second triangle
};

const texcoords = [_]f32{ 0.0, 0.0, 1.0, 0, 0.5, 1.0, 1.0, 0.4 };

fn eql(o: []f32, t: []f32) void {
    std.debug.print("lens o:{}, t:{}", .{ o.len, t.len });
    var i: u32 = 0;
    while (i < o.len) {
        if (o[i] != t[i]) std.debug.print("{}               {} != {}\n\n", .{ i, o[i], t[i] });
        i += 1;
    }
}
pub fn RenderChunkFrame(chunkpos: [3]i32, vbo: c_uint, vao: c_uint, vlen: c_uint, cameraPos: zm.Vec3f, cameraUp: zm.Vec3f, cameraFront: zm.Vec3f) !void {
    //gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(f32) * @as(isize,@intCast(ver.len)), @ptrCast(&ver), gl.DYNAMIC_DRAW);
    if (vlen == 0) return;
    //std.debug.print("\\{}/\n", .{vao});
    gl.BindVertexArray(vao);
    
    gl.BindBuffer(gl.ARRAY_BUFFER, vbo);
    const proj = zm.Mat4f.perspective(zm.toRadians(90.0), width / height, 0.1, 10000.0);
    const projectionlocation = gl.GetUniformLocation(shaderprogram, "projection");
    gl.UniformMatrix4fv(projectionlocation, 1, gl.TRUE, @ptrCast(&(proj)));
    const view = zm.Mat4f.lookAt(cameraPos, cameraPos + cameraFront, cameraUp);
    const viewlocation = gl.GetUniformLocation(shaderprogram, "view");
    gl.UniformMatrix4fv(viewlocation, 1, gl.TRUE, @ptrCast(&(view)));
    const mo = zm.Mat4f.translation(@floatFromInt(32 * chunkpos[0]), @floatFromInt(32 * chunkpos[1]), @floatFromInt(32 * chunkpos[2]));
    const modellocation = gl.GetUniformLocation(shaderprogram, "model");
    gl.UniformMatrix4fv(modellocation, 1, gl.TRUE, @ptrCast(&(mo)));
    
    gl.DrawArrays(gl.TRIANGLES, 0, @intCast(vlen));
    //gl.DrawArrays(gl.TRIANGLES, 0, @as(c_int,@intCast(ver.len)));
    //gl.DrawElements(gl.TRIANGLES, @as(c_int,@intCast(36)), gl.UNSIGNED_INT,0);
                            if (gl.GetError() != @as(c_uint,gl.NO_ERROR)) std.debug.panic("{any}", .{(gl.GetError())});

    gl.BindVertexArray(0);

}

pub fn InitRenderer() !void {
    gl.GenVertexArrays(1, @ptrCast(&VAO));
    gl.BindVertexArray(VAO);

    gl.GenBuffers(1, @ptrCast(&VBO));
    gl.BindBuffer(gl.ARRAY_BUFFER, VBO);
    gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(f32) * vertices.len, &vertices, gl.STATIC_DRAW);
            gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 5 * @sizeOf(f32), 0);
                            gl.EnableVertexAttribArray(0);
                            gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 5 * @sizeOf(f32), 3 * @sizeOf(f32));
                            gl.EnableVertexAttribArray(1);
    zstbi.init(allocator);
    defer zstbi.deinit();
    zstbi.setFlipVerticallyOnLoad(true);
    var textureimg = try zstbi.Image.loadFromFile("./src/texture_packs/default/test_block.jpg", 0);
    defer textureimg.deinit();

    gl.GenTextures(1, &texture);
    gl.TexParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
    gl.BindTextures(gl.TEXTURE_2D, 1, &texture);
                    const b = gl.GetError();


    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGB, @intCast(textureimg.width), @intCast(textureimg.height), 0, gl.RGB, gl.UNSIGNED_BYTE, @ptrCast(textureimg.data));
                            if (b != gl.NO_ERROR) std.debug.print("{}", .{b});
    gl.GenerateMipmap(gl.TEXTURE_2D);


    const vertexshader = gl.CreateShader(gl.VERTEX_SHADER);
    gl.ShaderSource(vertexshader, 1, @ptrCast(&@embedFile("./vertexshader.vs")), null);
    gl.CompileShader(vertexshader);

    const fragshader = gl.CreateShader(gl.FRAGMENT_SHADER);
    gl.ShaderSource(fragshader, 1, @ptrCast(&@embedFile("./fragshader.fs")), null);
    gl.CompileShader(fragshader);
    
    shaderprogram = gl.CreateProgram();
    gl.TextureParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT); // set texture wrapping to GL_REPEAT (default wrapping method)
    gl.TextureParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
    // set texture1 filtering parameters
    gl.TextureParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.TextureParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.BindTextures(gl.TEXTURE_2D, 1, @ptrCast(&texture));
    gl.AttachShader(shaderprogram, vertexshader);
    gl.AttachShader(shaderprogram, fragshader);
    gl.LinkProgram(shaderprogram);
    gl.PolygonMode(gl.FRONT_AND_BACK, gl.TRIANGLES);
    gl.Enable(gl.DEPTH_TEST);
    gl.UseProgram(shaderprogram);
}
