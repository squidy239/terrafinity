const std = @import("std");

const Mesher = @import("Mesher.zig");
pub const OpenGl = @import("Renderer/opengl/OpenGl.zig");
pub const Vulkan = @import("Renderer/vulkan/Vulkan.zig");
const ChunkPos = @import("world/World.zig").ChunkPos;

pub const Implementation = opaque {};
vtable: *const VTable,
userdata: *Implementation,
last_viewport: ?@Vector(2, u32) = null,

pub const VTable = struct {
    /// This may not return any error other than canceled if both `opaque_mesh` and `transparent_mesh` have a length of 0.
    addChunk: *const fn (*Implementation, std.Io, ChunkPos, []Mesher.Face, []Mesher.Face) (std.Io.Cancelable || error{AddChunkFailed})!void,
    draw: *const fn (*Implementation, io: std.Io, @Vector(3, f64)) (std.Io.Cancelable || error{DrawFailed})!void,
    setViewport: *const fn (*Implementation, @Vector(2, u32)) error{ViewportSetFailed}!void,
    updateCameraDirection: *const fn (*Implementation, @Vector(3, f32)) void,
    forEachChunk: *const fn (*Implementation, std.Io, *anyopaque, *const fn (*anyopaque, ChunkPos) void) std.Io.Cancelable!void,
};

///adds a chunk mesh to the renderer, this function may be called on any thread
///After this call opaque mesh and transparent mesh are in an undefined state and may not be read
pub fn addChunk(self: *@This(), io: std.Io, chunk_pos: ChunkPos, opaque_mesh: []Mesher.Face, transparent_mesh: []Mesher.Face) (std.Io.Cancelable || error{AddChunkFailed})!void {
    return self.vtable.addChunk(self.userdata, io, chunk_pos, opaque_mesh, transparent_mesh);
}

///removes a chunk mesh from the renderer and frees all associated resources, this function may be called on any thread
pub fn removeChunk(self: *@This(), io: std.Io, chunk_pos: ChunkPos) void {
    const cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(cancel_protection);
    return addChunk(self, io, chunk_pos, &.{}, &.{}) catch @panic("addChunk may not return an error here since its under cancel protection");
}

///draws all loaded chunk meshes to the screen, this function should only be called on the main thread
pub fn draw(self: *@This(), io: std.Io, viewpos: @Vector(3, f64)) (std.Io.Cancelable || error{DrawFailed})!void {
    return self.vtable.draw(self.userdata, io, viewpos);
}

///sets the viewport dimensions in pixels, this function should only be called on the main thread
pub fn setViewport(self: *@This(), viewport_pixels: @Vector(2, u32)) !void {
    if (!std.meta.eql(self.last_viewport, viewport_pixels)) {
        try self.vtable.setViewport(self.userdata, viewport_pixels);
        self.last_viewport = viewport_pixels;
    }
}

pub fn updateCameraDirection(self: *@This(), viewDir: @Vector(3, f32)) void {
    return self.vtable.updateCameraDirection(self.userdata, viewDir);
}

pub fn forEachChunk(self: *@This(), io: std.Io, userdata: *anyopaque, callback: *const fn (*anyopaque, ChunkPos) void) !void {
    return self.vtable.forEachChunk(self.userdata, io, userdata, callback);
}

pub const RenderOptions = struct {
    fov: f32 = 90.0,
    day_length_sec: f32 = 60 * 5,
    gamma_correction: bool = false,
};
