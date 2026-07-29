const std = @import("std");
const vk = @import("vulkan");

const Mesher = @import("Mesher.zig");
pub const Vulkan = @import("Renderer/vulkan/VulkanRenderer.zig");
const VulkanContext = @import("VulkanContext.zig").VulkanContext;
const ChunkPos = @import("world/World.zig").ChunkPos;

pub const cameraUp = @Vector(3, f64){ 0, 1, 0 };

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
    /// This may not return any error other than canceled if both `opaque_mesh` and `transparent_mesh` have a length of 0.
    addMesh: *const fn (*Implementation, std.Io, ChunkPos, []Mesher.Face, []Mesher.Face) (std.Io.Cancelable || error{AddMeshFailed})!void,
    draw: *const fn (*Implementation, io: std.Io, target: DrawTarget, frame_ctx: FrameDrawContext, @Vector(3, f64)) (std.Io.Cancelable || error{DrawFailed})!void,
    recreateSwapchain: *const fn (*Implementation, io: std.Io) void,
    updateCameraDirection: *const fn (*Implementation, @Vector(3, f32)) void,
    forEachMesh: *const fn (*Implementation, std.Io, *anyopaque, *const fn (*anyopaque, ChunkPos) error{Failed}!void) (std.Io.Cancelable || error{Failed})!void,
};

///adds a chunk mesh to the renderer, this function may be called on any thread
///After this call opaque mesh and transparent mesh are in an undefined state and may not be read
pub fn addMesh(self: *@This(), io: std.Io, chunk_pos: ChunkPos, opaque_mesh: []Mesher.Face, transparent_mesh: []Mesher.Face) (std.Io.Cancelable || error{AddMeshFailed})!void {
    return self.vtable.addMesh(self.userdata, io, chunk_pos, opaque_mesh, transparent_mesh);
}

///draws all loaded chunk meshes to the screen, this function should only be called on the main thread
pub fn draw(self: *@This(), io: std.Io, target: DrawTarget, frame_ctx: FrameDrawContext, viewpos: @Vector(3, f64)) (std.Io.Cancelable || error{DrawFailed})!void {
    return self.vtable.draw(self.userdata, io, target, frame_ctx, viewpos);
}

/// Notifies the renderer that the swapchain has been resized/changed and resources must be recreated.
pub fn recreateSwapchain(self: *@This(), io: std.Io) void {
    self.vtable.recreateSwapchain(self.userdata, io);
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
