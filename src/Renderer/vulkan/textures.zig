const std = @import("std");

const vk = @import("vulkan");
const zigimg = @import("zigimg");

const VulkanRenderer = @import("Vulkan.zig");

pub const TextureArrayManager = struct {
    renderer: *VulkanRenderer,

    pub fn init(renderer: *VulkanRenderer) TextureArrayManager {
        return TextureArrayManager{
            .renderer = renderer,
        };
    }

    /// Loads textures from a directory using zigimg and creates a Vulkan texture array
    pub fn loadTextureDirectory(
        self: *TextureArrayManager,
        io: std.Io,
        textures_path: std.Io.Dir,
        allocator: std.mem.Allocator,
        keyword: []const u8,
    ) !void {
        var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;

        // First pass: count and validate resolutions
        var dir_it = std.Io.Dir.iterate(textures_path);
        var first_resolution: ?[2]usize = null;
        var texture_count: usize = 0;

        while (try dir_it.next(io)) |entry| {
            if (entry.kind == .file and std.mem.indexOf(u8, entry.name, keyword) != null) {
                const img_res = try getResolution(io, allocator, textures_path, entry.name, &read_buffer);
                if (first_resolution == null) {
                    first_resolution = img_res;
                } else {
                    if (first_resolution.?[0] != img_res[0] or first_resolution.?[1] != img_res[1]) {
                        return error.InconsistentTextureResolution;
                    }
                }
                texture_count += 1;
            }
        }

        if (first_resolution == null) return error.NoTexturesFound;

        const res = first_resolution.?;
        std.log.info("texture resolution: {any}, count: {d}\n", .{ res, texture_count });

        // Second pass: load all textures into an array
        var texture_images = try allocator.alloc(zigimg.Image, texture_count);
        errdefer for (texture_images) |*img| img.deinit(allocator);

        dir_it = std.Io.Dir.iterate(textures_path);
        var texture_idx: usize = 0;

        while (try dir_it.next(io)) |entry| {
            if (entry.kind == .file and std.mem.indexOf(u8, entry.name, keyword) != null) {
                const loaded_img = try zigimg.Image.fromFile(allocator, io, try textures_path.openFile(io, entry.name, .{}), &read_buffer);
                errdefer loaded_img.deinit(allocator);

                try loaded_img.convert(allocator, .rgba32);
                if (loaded_img.width != res[0] or loaded_img.height != res[1]) {
                    loaded_img.deinit(allocator);
                    return error.InvalidTextureResolution;
                }

                texture_images[texture_idx] = loaded_img;
                texture_idx += 1;
            }
        }

        std.log.info("loaded {d} textures\n", .{texture_images.len});

        // Create Vulkan texture array
        try self.createVulkanTextureArray(io, allocator, texture_images, res[0], res[1]);

        // Deinit images after they've been uploaded to GPU
        for (texture_images) |*img| img.deinit(allocator);
        allocator.free(texture_images);
    }

    fn createVulkanTextureArray(
        self: *TextureArrayManager,
        io: std.Io,
        allocator: std.mem.Allocator,
        images: []zigimg.Image,
        width: usize,
        height: usize,
    ) !void {
        _ = io; // Mark as used
        _ = allocator; // Mark as used

        const image_count = images.len;
        const image_size = @as(vk.DeviceSize, @intCast(width)) * @as(vk.DeviceSize, @intCast(height)) * 4; // RGBA

        // Create staging buffer for all textures
        var staging_buffer: vk.Buffer = .null_handle;
        var staging_memory: vk.DeviceMemory = .null_handle;

        const total_staging_size = image_size * @as(vk.DeviceSize, @intCast(image_count));
        try self.renderer.createBuffer(
            total_staging_size,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
            &staging_buffer,
            &staging_memory
        );
        defer {
            if (staging_buffer != .null_handle) self.renderer.dev.destroyBuffer(self.renderer.dev_handle, staging_buffer, null);
            if (staging_memory != .null_handle) self.renderer.dev.freeMemory(self.renderer.dev_handle, staging_memory, null);
        }

        // Map and copy all texture data to staging buffer
        const data = try self.renderer.dev.mapMemory(self.renderer.dev_handle, staging_memory, 0, total_staging_size, .{});
        const mapped_slice = @as([*]u8, @ptrCast(data))[0..total_staging_size];

        var offset: vk.DeviceSize = 0;
        for (images) |img| {
            const rgba_data = img.rawBytes();
            @memcpy(mapped_slice[offset .. offset + rgba_data.len], rgba_data);
            offset += @as(vk.DeviceSize, @intCast(rgba_data.len));
        }

        self.renderer.dev.unmapMemory(self.renderer.dev_handle, staging_memory);

        // Create vk.Image for texture array (with mipmaps)
        const max_dim = @max(width, height);
        const max_dim_f: f64 = @floatFromInt(max_dim);
        const num_mip_levels: u32 = @intCast(std.math.max(1, @as(u32, @intFromFloat(@log2(max_dim_f))) + 1));

        const image_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .extent = .{ .width = @intCast(width), .height = @intCast(height), .depth = 1 },
            .mip_levels = num_mip_levels,
            .array_layers = @intCast(image_count),
            .format = .r8g8b8a8_srgb,
            .tiling = .optimal,
            .initial_layout = .undefined,
            .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
            .sharing_mode = .exclusive,
            .samples = .{ .@"1_bit" = true },
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        };

        const texture_image = try self.renderer.dev.createImage(self.renderer.dev_handle, &image_info, null);

        // Allocate image memory
        const mem_reqs = self.renderer.dev.getImageMemoryRequirements(self.renderer.dev_handle, texture_image);
        const alloc_info = vk.MemoryAllocateInfo{
            .allocation_size = mem_reqs.size,
            .memory_type_index = self.renderer.findMemoryType(mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
        };
        const memory = try self.renderer.dev.allocateMemory(self.renderer.dev_handle, &alloc_info, null);
        try self.renderer.dev.bindImageMemory(self.renderer.dev_handle, texture_image, memory, 0);

        // Transition layout and copy data for each layer
        for (0..image_count) |layer_idx| {
            const layer_offset = @as(vk.DeviceSize, @intCast(layer_idx)) * image_size;

            // Transition to transfer_dst_optimal for this layer
            try self.transitionImageLayoutForLayer(texture_image, .undefined, .transfer_dst_optimal, @intCast(layer_idx));

            // Copy data for this layer
            const region = vk.BufferImageCopy{
                .buffer_offset = layer_offset,
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = 0,
                    .base_array_layer = @intCast(layer_idx),
                    .layer_count = 1,
                },
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .image_extent = .{ .width = @intCast(width), .height = @intCast(height), .depth = 1 },
            };

            const cmd = try self.renderer.beginSingleTimeCommands();
            defer self.renderer.endSingleTimeCommands(cmd) catch {};

            self.renderer.dev.cmdCopyBufferToImage(cmd, staging_buffer, texture_image, .transfer_dst_optimal, 1, @ptrCast(&region));
        }

        // Transition to shader_read_only_optimal and generate mipmaps for all layers
        try self.transitionImageLayoutForLayer(texture_image, .transfer_dst_optimal, .shader_read_only_optimal, 0);

        // Generate mipmaps if the image has more than 1 mip level
        if (num_mip_levels > 1) {
            try self.generateMipmaps(texture_image, @intCast(width), @intCast(height));
        }

        // Create image view for texture array
        const view_info = vk.ImageViewCreateInfo{
            .flags = .{},
            .image = texture_image,
            .view_type = .@"2d",
            .format = .r8g8b8a8_srgb,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = num_mip_levels,
                .base_array_layer = 0,
                .layer_count = @intCast(image_count),
            },
        };

        const texture_view = try self.renderer.dev.createImageView(self.renderer.dev_handle, &view_info, null);

        // Create sampler for the texture array (linear filtering with mipmaps)
        const sampler_info = vk.SamplerCreateInfo{
            .flags = .{},
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .mip_lod_bias = 0.0,
            .anisotropy_enable = vk.FALSE,
            .max_anisotropy = 1.0,
            .compare_enable = vk.FALSE,
            .compare_op = .always,
            .min_lod = 0.0,
            .max_lod = @floatFromInt(num_mip_levels - 1),
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = vk.FALSE,
        };

        const sampler = try self.renderer.dev.createSampler(self.renderer.dev_handle, &sampler_info, null);

        // Update global descriptor set with the texture array (binding 1)
        const image_info_descriptor = vk.DescriptorImageInfo{
            .image_layout = .shader_read_only_optimal,
            .image_view = texture_view,
            .sampler = sampler,
        };

        const descriptor_write = vk.WriteDescriptorSet{
            .dst_set = self.renderer.global_descriptor_set,
            .dst_binding = 1, // Matches layout(binding = 1) in frag shader (texture_array)
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&image_info_descriptor),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        self.renderer.dev.updateDescriptorSets(self.renderer.dev_handle, 1, @ptrCast(&descriptor_write), 0, undefined);

        std.log.info("Created Vulkan texture array with {d} layers, {d} mip levels\n", .{ image_count, num_mip_levels });
    }

    fn transitionImageLayoutForLayer(
        self: *TextureArrayManager,
        image: vk.Image,
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
        layer_idx: u32,
    ) !void {
        const cmd = try self.renderer.beginSingleTimeCommands();
        defer self.renderer.endSingleTimeCommands(cmd) catch {};

        var barrier = vk.ImageMemoryBarrier{
            .flags = .{},
            .old_layout = old_layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = layer_idx,
                .layer_count = 1,
            },
            .src_access_mask = .{},
            .dst_access_mask = .{},
        };

        var source_stage: vk.PipelineStageFlags = .{};
        var dest_stage: vk.PipelineStageFlags = .{};

        if (old_layout == .undefined and new_layout == .transfer_dst_optimal) {
            barrier.src_access_mask = .{};
            barrier.dst_access_mask = .{ .transfer_write_bit = true };
            source_stage = .{ .top_of_pipe_bit = true };
            dest_stage = .{ .transfer_bit = true };
        } else if (old_layout == .transfer_dst_optimal and new_layout == .shader_read_only_optimal) {
            barrier.src_access_mask = .{ .transfer_write_bit = true };
            barrier.dst_access_mask = .{ .shader_read_bit = true };
            source_stage = .{ .transfer_bit = true };
            dest_stage = .{ .fragment_shader_bit = true };
        } else {
            @panic("Unsupported layout transition");
        }

        self.renderer.dev.cmdPipelineBarrier(cmd, source_stage, dest_stage, .{}, 0, undefined, 0, undefined, 1, @ptrCast(&barrier));
    }

    fn generateMipmaps(self: *TextureArrayManager, image: vk.Image, width: u32, height: u32) !void {
        _ = width; // autofix
        _ = height; // autofix
        const cmd = try self.renderer.beginSingleTimeCommands();
        defer self.renderer.endSingleTimeCommands(cmd) catch {};

        // VK_REMAINING_MIP_LEVELS and VK_REMAINING_ARRAY_LAYERS are ~0u in Vulkan
        const remaining_mip_levels: u32 = ~@as(u32, 0);
        const remaining_array_layers: u32 = ~@as(u32, 0);

        var barrier = vk.ImageMemoryBarrier{
            .flags = .{},
            .old_layout = .shader_read_only_optimal,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = remaining_mip_levels,
                .base_array_layer = 0,
                .layer_count = remaining_array_layers,
            },
            .src_access_mask = .{ .shader_read_bit = true },
            .dst_access_mask = .{ .transfer_write_bit = true },
        };

        self.renderer.dev.cmdPipelineBarrier(
            cmd,
            .{ .fragment_shader_bit = true },
            .{ .transfer_bit = true },
            .{},
            1, @ptrCast(&barrier),
            0, undefined,
            0, undefined,
        );

        // Transition back to shader_read_only_optimal
        barrier.old_layout = .transfer_dst_optimal;
        barrier.new_layout = .shader_read_only_optimal;
        barrier.src_access_mask = .{ .transfer_write_bit = true };
        barrier.dst_access_mask = .{ .shader_read_bit = true };

        self.renderer.dev.cmdPipelineBarrier(
            cmd,
            .{ .transfer_bit = true },
            .{ .fragment_shader_bit = true },
            .{},
            1, @ptrCast(&barrier),
            0, undefined,
            0, undefined,
        );
    }

    pub fn destroyTextureArray(self: *TextureArrayManager) void {
        _ = self; // autofix
        // Texture array is managed by the renderer's descriptor set cleanup
    }
};

fn getResolution(io: std.Io, allocator: std.mem.Allocator, textures_path: std.Io.Dir, filename: []const u8, read_buffer: *[zigimg.io.DEFAULT_BUFFER_SIZE]u8) ![2]usize {
    const texture = try textures_path.openFile(io, filename, .{});
    defer texture.close(io);

    var img = try zigimg.Image.fromFile(allocator, io, texture, read_buffer);
    defer img.deinit(allocator);

    return [2]usize{ img.width, img.height };
}
