const std = @import("std");
const Mesh = @import("Mesh.zig");
const ChunkPos = @import("world/World.zig").ChunkPos;

pub const OpenGl = @import("Renderer/opengl/OpenGl.zig");

vtable: *const VTable,
userdata: *anyopaque,
last_viewport: ?[2]u32 = null,

pub const VTable = struct {
    removeChunk: *const fn (*anyopaque, ChunkPos) void,
    addChunk: *const fn (*anyopaque, Mesh) error{ OutOfMemory, OutOfVideoMemory }!void,
    drawChunks: *const fn (*anyopaque, io: std.Io, @Vector(3, f64)) error{DrawFailed}!void,
    containsChunk: *const fn (*anyopaque, ChunkPos) bool,
    clear: *const fn (*anyopaque, @Vector(3, f64)) error{DrawFailed}!void,
    setViewport: *const fn (*anyopaque, @Vector(2, u32)) error{ViewportSetFailed}!void,
};

///adds a chunk mesh to the renderer, this function may be called on any thread
pub fn addChunk(self: *@This(), mesh: Mesh) !void {
    return self.vtable.addChunk(self.userdata, mesh);
}

///removes a chunk mesh from the renderer and frees all associated resources, this function may be called on any thread
pub fn removeChunk(self: *@This(), Pos: ChunkPos) void {
    if (!self.vtable.containsChunk(self.userdata, Pos)) return;
    return self.vtable.removeChunk(self.userdata, Pos);
}

///draws all loaded chunk meshes to the screen, this function should only be called on the main thread
pub fn drawChunks(self: *@This(), io: std.Io, viewpos: @Vector(3, f64)) error{DrawFailed}!void {
    return self.vtable.drawChunks(self.userdata, io, viewpos);
}

///checks if a chunk mesh is loaded, this function may be called on any thread
pub fn containsChunk(self: *@This(), Pos: ChunkPos) bool {
    return self.vtable.containsChunk(self.userdata, Pos);
}

///clears the screen and draws any skyboxes, this function should only be called on the main thread
pub fn clear(self: *@This(), viewpos: @Vector(3, f64)) error{DrawFailed}!void {
    return self.vtable.clear(self.userdata, viewpos);
}

///sets the viewport dimensions in pixels, this function should only be called on the main thread
pub fn setViewport(self: *@This(), viewport_pixels: @Vector(2, u32)) !void {
    if (self.last_viewport) |lvp| if (std.meta.eql(lvp, viewport_pixels)) return;
    try self.vtable.setViewport(self.userdata, viewport_pixels);
    self.last_viewport = viewport_pixels;
}
