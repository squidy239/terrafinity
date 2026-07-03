const std = @import("std");

const vk = @import("vulkan");
const zigimg = @import("zigimg");

const VulkanRenderer = @import("Vulkan.zig");

pub const TextureArrayManager = struct {
    renderer: *VulkanRenderer,
    texture_image: vk.Image,
    texture_memory: vk.DeviceMemory,
    texture_view: vk.ImageView,
    sampler: vk.Sampler,

    pub fn init(renderer: *VulkanRenderer) TextureArrayManager {
        return TextureArrayManager{
            .renderer = renderer,
            .texture_image = .null_handle,
            .texture_memory = .null_handle,
            .texture_view = .null_handle,
            .sampler = .null_handle,
        };
    }

    pub fn loadTextureDirectory(
        self: *TextureArrayManager,
        io: std.Io,
        textures_path: std.Io.Dir,
        allocator: std.mem.Allocator,
        keyword: []const u8,
    ) !void {
        var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;

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

        var texture_images = try allocator.alloc(zigimg.Image, texture_count);

        dir_it = std.Io.Dir.iterate(textures_path);
        var texture_idx: usize = 0;

        errdefer {
            for (texture_images[0..texture_idx]) |*img| img.deinit(allocator);
            allocator.free(texture_images);
        }

        while (try dir_it.next(io)) |entry| {
            if (entry.kind == .file and std.mem.indexOf(u8, entry.name, keyword) != null) {
                const texture_file = try textures_path.openFile(io, entry.name, .{});
                defer texture_file.close(io);

                const loaded_img = try zigimg.Image.fromFile(allocator, io, texture_file, &read_buffer);

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

        try self.createVulkanTextureArray(io, allocator, texture_images, res[0], res[1]);

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
        _ = io;
        _ = allocator;

        const image_count = images.len;
        const image_size = @as(vk.DeviceSize, @intCast(width)) * @as(vk.DeviceSize, @intCast(height)) * 4;

        var staging_buffer: vk.Buffer = .null_handle;
        var staging_memory: vk.DeviceMemory = .null_handle;

        const total_staging_size = image_size * @as(vk.DeviceSize, @intCast(image_count));
        try self.renderer.createBuffer(total_staging_size, .{ .transfer_src_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, &staging_buffer, &staging_memory);
        defer {
            if (staging_buffer != .null_handle) self.renderer.dev.destroyBuffer(staging_buffer, null);
            if (staging_memory != .null_handle) self.renderer.dev.freeMemory(staging_memory, null);
        }

        const data = try self.renderer.dev.mapMemory(staging_memory, 0, total_staging_size, .{});
        const mapped_slice = @as([*]u8, @ptrCast(data))[0..total_staging_size];

        var offset: vk.DeviceSize = 0;
        for (images) |img| {
            const rgba_data = img.rawBytes();
            @memcpy(mapped_slice[offset .. offset + rgba_data.len], rgba_data);
            offset += @as(vk.DeviceSize, @intCast(rgba_data.len));
        }

        self.renderer.dev.unmapMemory(staging_memory);

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

        const texture_image = try self.renderer.dev.createImage(&image_info, null);

        const mem_reqs = self.renderer.dev.getImageMemoryRequirements(texture_image);
        const alloc_info = vk.MemoryAllocateInfo{
            .allocation_size = mem_reqs.size,
            .memory_type_index = self.renderer.findMemoryType(mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
        };
        const memory = try self.renderer.dev.allocateMemory(&alloc_info, null);
        try self.renderer.dev.bindImageMemory(texture_image, memory, 0);

        const cmd = try self.renderer.beginSingleTimeCommands();

        for (0..image_count) |layer_idx| {
            const layer_offset = @as(vk.DeviceSize, @intCast(layer_idx)) * image_size;

            try self.transitionImageLayout(cmd, texture_image, .undefined, .transfer_dst_optimal, 0, 1, @intCast(layer_idx), 1);

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

            self.renderer.dev.cmdCopyBufferToImage(cmd, staging_buffer, texture_image, .transfer_dst_optimal, 1, @ptrCast(&region));
        }

        try self.transitionImageLayout(cmd, texture_image, .transfer_dst_optimal, .shader_read_only_optimal, 0, num_mip_levels, 0, @intCast(image_count));

        try self.renderer.endSingleTimeCommands(cmd);

        if (num_mip_levels > 1) {
            try self.generateMipmaps(texture_image, @intCast(width), @intCast(height), @intCast(image_count));
        }

        const view_info = vk.ImageViewCreateInfo{
            .flags = .{},
            .image = texture_image,
            .view_type = .@"2d_array",
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

        const texture_view = try self.renderer.dev.createImageView(&view_info, null);

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

        const sampler = try self.renderer.dev.createSampler(&sampler_info, null);

        const image_info_descriptor = vk.DescriptorImageInfo{
            .image_layout = .shader_read_only_optimal,
            .image_view = texture_view,
            .sampler = sampler,
        };

        const descriptor_write = vk.WriteDescriptorSet{
            .dst_set = self.renderer.global_descriptor_set,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&image_info_descriptor),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        self.renderer.dev.updateDescriptorSets(self.renderer.dev_handle, 1, @ptrCast(&descriptor_write), 0, undefined);

        self.texture_image = texture_image;
        self.texture_memory = memory;
        self.texture_view = texture_view;
        self.sampler = sampler;

        std.log.info("Created Vulkan texture array with {d} layers, {d} mip levels\n", .{ image_count, num_mip_levels });
    }

    fn transitionImageLayout(
        self: *TextureArrayManager,
        cmd: vk.CommandBuffer,
        image: vk.Image,
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
        base_mip_level: u32,
        mip_level_count: u32,
        base_array_layer: u32,
        array_layer_count: u32,
    ) !void {
        var barrier = vk.ImageMemoryBarrier{
            .flags = .{},
            .old_layout = old_layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = base_mip_level,
                .level_count = mip_level_count,
                .base_array_layer = base_array_layer,
                .layer_count = array_layer_count,
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
        } else if (old_layout == .shader_read_only_optimal and new_layout == .transfer_src_optimal) {
            barrier.src_access_mask = .{ .shader_read_bit = true };
            barrier.dst_access_mask = .{ .transfer_read_bit = true };
            source_stage = .{ .fragment_shader_bit = true };
            dest_stage = .{ .transfer_bit = true };
        } else if (old_layout == .transfer_src_optimal and new_layout == .shader_read_only_optimal) {
            barrier.src_access_mask = .{ .transfer_read_bit = true };
            barrier.dst_access_mask = .{ .shader_read_bit = true };
            source_stage = .{ .transfer_bit = true };
            dest_stage = .{ .fragment_shader_bit = true };
        } else if (old_layout == .undefined and new_layout == .transfer_src_optimal) {
            barrier.src_access_mask = .{};
            barrier.dst_access_mask = .{ .transfer_read_bit = true };
            source_stage = .{ .top_of_pipe_bit = true };
            dest_stage = .{ .transfer_bit = true };
        } else {
            @panic("Unsupported layout transition");
        }

        self.renderer.dev.cmdPipelineBarrier(cmd, source_stage, dest_stage, .{}, 0, undefined, 0, undefined, 1, @ptrCast(&barrier));
    }

    fn generateMipmaps(self: *TextureArrayManager, image: vk.Image, width: u32, height: u32, image_count: u32) !void {
        const cmd = try self.renderer.beginSingleTimeCommands();

        const max_dim: u32 = @max(width, height);
        const num_mip_levels: u32 = std.math.max(1, @as(u32, @intFromFloat(@log2(@as(f64, @floatFromInt(max_dim)))))) + 1;

        var src_layout: vk.ImageLayout = .shader_read_only_optimal;
        var dst_layout: vk.ImageLayout = .transfer_dst_optimal;

        var mip_level: u32 = 1;
        while (mip_level < num_mip_levels) : (mip_level += 1) {
            const prev_mip_level = mip_level - 1;

            const prev_width = @max(1, width >> prev_mip_level);
            const prev_height = @max(1, height >> prev_mip_level);
            const curr_width = @max(1, width >> mip_level);
            const curr_height = @max(1, height >> mip_level);

            try self.transitionImageLayout(cmd, image, src_layout, .transfer_src_optimal, prev_mip_level, 1, 0, image_count);

            try self.transitionImageLayout(cmd, image, dst_layout, .transfer_dst_optimal, mip_level, 1, 0, image_count);

            const blit_region = vk.ImageBlit{
                .src_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = prev_mip_level,
                    .base_array_layer = 0,
                    .layer_count = image_count,
                },
                .src_offsets = .{
                    .{ .x = 0, .y = 0, .z = 0 },
                    .{ .x = @as(i32, @intCast(prev_width)), .y = @as(i32, @intCast(prev_height)), .z = 1 },
                },
                .dst_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = mip_level,
                    .base_array_layer = 0,
                    .layer_count = image_count,
                },
                .dst_offsets = .{
                    .{ .x = 0, .y = 0, .z = 0 },
                    .{ .x = @as(i32, @intCast(curr_width)), .y = @as(i32, @intCast(curr_height)), .z = 1 },
                },
            };

            self.renderer.dev.cmdBlitImage(
                cmd,
                image,
                .transfer_src_optimal,
                image,
                .transfer_dst_optimal,
                1,
                @ptrCast(&blit_region),
                .linear,
            );

            try self.transitionImageLayout(cmd, image, .transfer_src_optimal, .shader_read_only_optimal, prev_mip_level, 1, 0, image_count);

            src_layout = .shader_read_only_optimal;
            dst_layout = .transfer_dst_optimal;
        }

        try self.transitionImageLayout(cmd, image, .transfer_dst_optimal, .shader_read_only_optimal, num_mip_levels - 1, 1, 0, image_count);

        try self.renderer.endSingleTimeCommands(cmd);
    }

    pub fn destroyTextureArray(self: *TextureArrayManager) void {
        if (self.sampler != .null_handle) {
            self.renderer.dev.destroySampler(self.sampler, null);
            self.sampler = .null_handle;
        }
        if (self.texture_view != .null_handle) {
            self.renderer.dev.destroyImageView(self.texture_view, null);
            self.texture_view = .null_handle;
        }
        if (self.texture_image != .null_handle) {
            self.renderer.dev.destroyImage(self.texture_image, null);
            self.texture_image = .null_handle;
        }
        if (self.texture_memory != .null_handle) {
            self.renderer.dev.freeMemory(self.texture_memory, null);
            self.texture_memory = .null_handle;
        }
    }
};

fn getResolution(io: std.Io, allocator: std.mem.Allocator, textures_path: std.Io.Dir, filename: []const u8, read_buffer: *[zigimg.io.DEFAULT_BUFFER_SIZE]u8) ![2]usize {
    const texture = try textures_path.openFile(io, filename, .{});
    defer texture.close(io);

    var img = try zigimg.Image.fromFile(allocator, io, texture, read_buffer);
    defer img.deinit(allocator);

    return [2]usize{ img.width, img.height };
}
