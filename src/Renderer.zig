const std = @import("std");
const Mesh = @import("Mesh.zig");
const ChunkPos = @import("world/World.zig").ChunkPos;

pub const OpenGl = @import("Renderer/opengl/OpenGl.zig");

vtable: *const VTable,
userdata: *anyopaque,
last_viewport: ?[2]u32 = null,

pub const VTable = struct {
    removeChunk: *const fn (*anyopaque, std.Io, ChunkPos) void,
    addChunk: *const fn (*anyopaque, std.Io, ChunkPos, []const u8) error{ OutOfMemory, OutOfVideoMemory }!void,
    drawChunks: *const fn (*anyopaque, io: std.Io, @Vector(3, f64)) error{DrawFailed}!void,
    containsChunk: *const fn (*anyopaque, std.Io, ChunkPos) bool,
    clear: *const fn (*anyopaque, @Vector(3, f64)) error{DrawFailed}!void,
    setViewport: *const fn (*anyopaque, @Vector(2, u32)) error{ViewportSetFailed}!void,
    updateCameraDirection: *const fn (*anyopaque, @Vector(3, f32)) void,
    ensureContext: *const fn (*anyopaque) anyerror!void,
    getCameraFront: *const fn (*anyopaque) @Vector(3, f32),
    forEachChunk: *const fn (*anyopaque, std.Io, *anyopaque, *const fn (*anyopaque, ChunkPos) void) void,
};

///adds a chunk mesh to the renderer, this function may be called on any thread
pub fn addChunk(self: *@This(), io: std.Io, Pos: ChunkPos, mesh: []const u8) !void {
    return self.vtable.addChunk(self.userdata, io, Pos, mesh);
}

///removes a chunk mesh from the renderer and frees all associated resources, this function may be called on any thread
pub fn removeChunk(self: *@This(), io: std.Io, Pos: ChunkPos) void {
    if (!self.vtable.containsChunk(self.userdata, io, Pos)) return;
    return self.vtable.removeChunk(self.userdata, io, Pos);
}

///draws all loaded chunk meshes to the screen, this function should only be called on the main thread
pub fn drawChunks(self: *@This(), io: std.Io, viewpos: @Vector(3, f64)) error{DrawFailed}!void {
    return self.vtable.drawChunks(self.userdata, io, viewpos);
}

///checks if a chunk mesh is loaded, this function may be called on any thread
pub fn containsChunk(self: *@This(), io: std.Io, Pos: ChunkPos) bool {
    return self.vtable.containsChunk(self.userdata, io, Pos);
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

pub fn updateCameraDirection(self: *@This(), viewDir: @Vector(3, f32)) void {
    return self.vtable.updateCameraDirection(self.userdata, viewDir);
}

pub fn ensureContext(self: *@This()) !void {
    return self.vtable.ensureContext(self.userdata);
}

pub fn getCameraFront(self: *@This()) @Vector(3, f32) {
    return self.vtable.getCameraFront(self.userdata);
}

pub fn forEachChunk(self: *@This(), io: std.Io, userdata: *anyopaque, callback: *const fn (*anyopaque, ChunkPos) void) void {
    return self.vtable.forEachChunk(self.userdata, io, userdata, callback);
}