const glfw = @import("glfw");
const std = @import("std");
const gl = @import("gl");
pub var width = 800;
pub var height = 800;

pub fn CreateWindow() !glfw.Window {
    const window = glfw.Window.create(width, height, "voxelgame", null, null, .{
        .context_version_major = 4,
        .context_version_minor = 6,
        .opengl_profile = .opengl_core_profile,
        .opengl_forward_compat = true,
        .samples = 4,
    }) orelse {
        std.debug.panic("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        return error.CreateWindowFailed;
    };
    defer window.destroy();
    glfw.makeContextCurrent(window);
    glfw.Window.setFramebufferSizeCallback(window, glfwSizeCallback);
}

fn glfwSizeCallback(window: glfw.Window, w: u32, h: u32) void {
    width = w;
    height = h;
    gl.Viewport(0, 0, @intCast(w), @intCast(h));
    _ = window;
}
