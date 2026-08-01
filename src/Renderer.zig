const std = @import("std");
const vk = @import("vulkan");

const Chunk = @import("world/Chunk.zig");
pub const Vulkan = @import("Renderer/vulkan/VulkanRenderer.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const ChunkPos = @import("world/World.zig").ChunkPos;

pub const cameraUp = @Vector(3, f64){ 0, 1, 0 };

/// Shared camera math: converts view direction (pitch in [0], yaw in [1]) to a unit front vector.
pub fn cameraFrontFromViewDirection(view_dir: @Vector(3, f32)) @Vector(3, f32) {
    return @Vector(3, f32){
        @sin(std.math.degreesToRadians(view_dir[1])) * @cos(std.math.degreesToRadians(view_dir[0])),
        @sin(std.math.degreesToRadians(view_dir[0])),
        @cos(std.math.degreesToRadians(view_dir[1])) * @cos(std.math.degreesToRadians(view_dir[0])),
    };
}

pub const Implementation = opaque {};
vtable: *const VTable,
userdata: *Implementation,

pub const DrawTarget = struct {
    width: u32,
    height: u32,
};

pub const FrameDrawContext = struct {
    frame_index: u32,
    cmd_buffer: vk.CommandBuffer,
    output_image: vk.Image,
    output_view: vk.ImageView,
    swapchain_image_layout: *vk.ImageLayout,
};

pub const VTable = struct {
    /// Adds or replaces a chunk mesh, meshing the given chunk encoding against the provided neighbor faces.
    /// May be called from any thread. The encoding and neighbor faces must remain valid for the duration of the call.
    addChunk: *const fn (*Implementation, std.Io, ChunkPos, Chunk.Encoding, *const [6]Chunk.Encoding.Face) (std.Io.Cancelable || error{AddChunkFailed})!void,
    /// Removes the chunk mesh for the given position.
    /// May be called from any thread.
    removeChunk: *const fn (*Implementation, std.Io, ChunkPos) (std.Io.Cancelable || error{RemoveChunkFailed})!void,
    draw: *const fn (*Implementation, io: std.Io, target: DrawTarget, frame_ctx: FrameDrawContext, @Vector(3, f64)) (std.Io.Cancelable || error{DrawFailed})!void,
    recreateSwapchain: *const fn (*Implementation, io: std.Io) anyerror!void,
    updateCameraDirection: *const fn (*Implementation, @Vector(3, f32)) void,
    forEachMesh: *const fn (*Implementation, std.Io, *anyopaque, *const fn (*anyopaque, ChunkPos) error{Failed}!void) (std.Io.Cancelable || error{Failed})!void,
};

/// Adds a chunk mesh to the renderer, this function may be called on any thread.
/// The chunk encoding and neighbor faces must remain valid for the duration of the call.
pub fn addChunk(self: *@This(), io: std.Io, chunk_pos: ChunkPos, encoding: Chunk.Encoding, neighbor_faces: *const [6]Chunk.Encoding.Face) (std.Io.Cancelable || error{AddChunkFailed})!void {
    return self.vtable.addChunk(self.userdata, io, chunk_pos, encoding, neighbor_faces);
}

/// Removes the chunk mesh for the given position, this function may be called on any thread.
pub fn removeChunk(self: *@This(), io: std.Io, chunk_pos: ChunkPos) (std.Io.Cancelable || error{RemoveChunkFailed})!void {
    return self.vtable.removeChunk(self.userdata, io, chunk_pos);
}

///draws all loaded chunk meshes to the screen, this function should only be called on the main thread
pub fn draw(self: *@This(), io: std.Io, target: DrawTarget, frame_ctx: FrameDrawContext, viewpos: @Vector(3, f64)) (std.Io.Cancelable || error{DrawFailed})!void {
    return self.vtable.draw(self.userdata, io, target, frame_ctx, viewpos);
}

/// Notifies the renderer that the swapchain has been resized/changed and resources must be recreated.
pub fn recreateSwapchain(self: *@This(), io: std.Io) !void {
    return self.vtable.recreateSwapchain(self.userdata, io);
}

pub fn updateCameraDirection(self: *@This(), view_dir: @Vector(3, f32)) void {
    return self.vtable.updateCameraDirection(self.userdata, view_dir);
}

pub fn forEachMesh(self: *@This(), io: std.Io, userdata: *anyopaque, callback: *const fn (*anyopaque, ChunkPos) error{Failed}!void) (std.Io.Cancelable || error{Failed})!void {
    return self.vtable.forEachMesh(self.userdata, io, userdata, callback);
}

pub const RenderOptions = struct {
    fov: f32 = 90.0,
    day_length_sec: f32 = 60 * 5,
    gamma_correction: bool = false,
    present_mode: VulkanContext.PresentMode = .mailbox,
    selected_pack: []const u8 = "default",
    inside_transparent: bool = false,
};
