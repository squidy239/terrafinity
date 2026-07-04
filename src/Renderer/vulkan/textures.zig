const std = @import("std");

const vk = @import("vulkan");
const zigimg = @import("zigimg");

const VulkanRenderer = @import("Vulkan.zig");
const Block = @import("../../main.zig").Block;

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

        // --- Pass 1: validate resolution consistency, count visible Block textures ---
        var dir_it = std.Io.Dir.iterate(textures_path);
        var first_resolution: ?[2]usize = null;
        var texture_count: usize = 0;

        while (try dir_it.next(io)) |entry| {
            if (entry.kind == .file and std.mem.indexOf(u8, entry.name, keyword) != null) {
                // Map filename → Block; skip unknown files (same as OpenGL)
                const block_name = entry.name[0 .. std.mem.indexOfScalar(u8, entry.name, '.') orelse entry.name.len];
                const block_type = std.meta.stringToEnum(Block, block_name);
                if (block_type == null or !block_type.?.isVisible()) {
                    std.log.warn("Skipping non-block texture: {s}\n", .{entry.name});
                    continue;
                }

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

        // Validate square (same as OpenGL)
        if (res[0] != res[1]) return error.TexturesNotSquare;

        std.log.info("texture resolution: {any}, count: {d}\n", .{ res, texture_count });

        // --- Pass 2: load each file and place at the right enum-indexer layer ---
        // Use the same indexer strategy as OpenGL: layer = EnumIndexer position
        const indexer = std.enums.EnumIndexer(Block);

        // Max layer index we'll need (max declaration position among loaded textures)
        var max_layer_index: usize = 0;

        // First pass to find max_layer_index
        dir_it = std.Io.Dir.iterate(textures_path);
        while (try dir_it.next(io)) |entry| {
            if (entry.kind == .file and std.mem.indexOf(u8, entry.name, keyword) != null) {
                const block_name = entry.name[0 .. std.mem.indexOfScalar(u8, entry.name, '.') orelse entry.name.len];
                const block_type = std.meta.stringToEnum(Block, block_name) orelse continue;
                if (!block_type.isVisible()) continue;
                const layer = indexer.indexOf(block_type);
                if (layer > max_layer_index) max_layer_index = layer;
            }
        }

        // Number of layers = max_layer_index + 1 so we cover all declared Block positions
        const layer_count = max_layer_index + 1;

        // Temporarily store texture images indexed by layer (missing textures get null)
        var layer_images = try allocator.alloc(?zigimg.Image, layer_count);
        defer {
            for (layer_images) |*maybe_img| {
                if (maybe_img.*) |*img| img.deinit(allocator);
            }
            allocator.free(layer_images);
        }
        @memset(layer_images, null);

        dir_it = std.Io.Dir.iterate(textures_path);
        var loaded_count: usize = 0;

        while (try dir_it.next(io)) |entry| {
            if (entry.kind == .file and std.mem.indexOf(u8, entry.name, keyword) != null) {
                const block_name = entry.name[0 .. std.mem.indexOfScalar(u8, entry.name, '.') orelse entry.name.len];
                const block_type = std.meta.stringToEnum(Block, block_name) orelse continue;
                if (!block_type.isVisible()) continue;

                const layer = indexer.indexOf(block_type);

                const texture_file = try textures_path.openFile(io, entry.name, .{});
                defer texture_file.close(io);

                var loaded_img = try zigimg.Image.fromFile(allocator, io, texture_file, &read_buffer);
                try loaded_img.convert(allocator, .rgba32);
                if (loaded_img.width != res[0] or loaded_img.height != res[1]) {
                    loaded_img.deinit(allocator);
                    return error.InvalidTextureResolution;
                }

                std.log.debug("loaded texture {s} -> layer {d}\n", .{ entry.name, layer });

                // Free any previous image at this layer (shouldn't happen)
                if (layer_images[layer]) |*old_img| old_img.deinit(allocator);
                layer_images[layer] = loaded_img;
                loaded_count += 1;
            }
        }

        std.log.info("loaded {d}/{d} texture layers\n", .{ loaded_count, layer_count });

        try self.createVulkanTextureArray(io, allocator, layer_images, res[0], res[1]);
    }

    fn createVulkanTextureArray(
        self: *TextureArrayManager,
        io: std.Io,
        allocator: std.mem.Allocator,
        layer_images: []?zigimg.Image,
        width: usize,
        height: usize,
    ) !void {
        const image_count = @as(u32, @intCast(layer_images.len));
        const image_size = @as(vk.DeviceSize, @intCast(width)) * @as(vk.DeviceSize, @intCast(height)) * 4;

        // --- Generate missing-texture fallback (16×16 magenta/black checkerboard) ---
        const fallback_w: usize = 16;
        const fallback_h: usize = 16;
        var fallback_pixels: [fallback_w * fallback_h * 4]u8 = undefined;
        for (0..fallback_h) |y| {
            for (0..fallback_w) |x| {
                const is_magenta = (x / 8 + y / 8) % 2 == 0;
                const i = (y * fallback_w + x) * 4;
                if (is_magenta) {
                    fallback_pixels[i + 0] = 255;
                    fallback_pixels[i + 1] = 0;
                    fallback_pixels[i + 2] = 255;
                    fallback_pixels[i + 3] = 255;
                } else {
                    fallback_pixels[i + 0] = 0;
                    fallback_pixels[i + 1] = 0;
                    fallback_pixels[i + 2] = 0;
                    fallback_pixels[i + 3] = 255;
                }
            }
        }

        // --- Staging buffer for all layer data ---
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

        for (layer_images, 0..) |maybe_img, i| {
            const rgba_data = if (maybe_img) |img|
                img.rawBytes()
            else
                @as([]const u8, fallback_pixels[0..@min(fallback_w * fallback_h * 4, @as(usize, @intCast(image_size)))]);

            const layer_offset = @as(vk.DeviceSize, @intCast(i)) * image_size;
            @memcpy(mapped_slice[layer_offset .. layer_offset + rgba_data.len], rgba_data);
        }

        self.renderer.dev.unmapMemory(staging_memory);

        // --- Calculate mip levels ---
        const max_dim = @max(width, height);
        const num_mip_levels: u32 = @max(1, @as(u32, @intFromFloat(@log2(@as(f64, @floatFromInt(max_dim))))) + 1);

        // --- Create the texture array image ---
        const image_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .extent = .{ .width = @intCast(width), .height = @intCast(height), .depth = 1 },
            .mip_levels = num_mip_levels,
            .array_layers = @intCast(image_count),
            .format = .r8g8b8a8_srgb,
            .tiling = .optimal,
            .initial_layout = .undefined,
            .usage = .{ .transfer_src_bit = true, .transfer_dst_bit = true, .sampled_bit = true },
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

        // --- Single command buffer for copy + mip generation ---
        const cmd = try self.renderer.beginSingleTimeCommands(io);

        // 1. Transition ALL layers mip 0: undefined → transfer_dst_optimal
        try self.transitionImageLayout(cmd, texture_image, .undefined, .transfer_dst_optimal, 0, 1, 0, image_count);

        // 2. Copy each layer from staging buffer → image mip 0 (one batch of regions)
        var copy_regions = try allocator.alloc(vk.BufferImageCopy, image_count);
        defer allocator.free(copy_regions);

        for (0..image_count) |layer_idx| {
            copy_regions[layer_idx] = vk.BufferImageCopy{
                .buffer_offset = @as(vk.DeviceSize, @intCast(layer_idx)) * image_size,
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = 0,
                    .base_array_layer = @as(u32, @intCast(layer_idx)),
                    .layer_count = 1,
                },
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .image_extent = .{ .width = @intCast(width), .height = @intCast(height), .depth = 1 },
            };
        }

        self.renderer.dev.cmdCopyBufferToImage(cmd, staging_buffer, texture_image, .transfer_dst_optimal, copy_regions);

        // 3. Transition mip 0: transfer_dst_optimal → transfer_src_optimal (ready for blit source)
        try self.transitionImageLayout(cmd, texture_image, .transfer_dst_optimal, .transfer_src_optimal, 0, 1, 0, image_count);

        // 4. Generate mip chain via blit
        if (num_mip_levels > 1) {
            // For each destination mip level, blit from the previous level
            var mip_level: u32 = 1;
            while (mip_level < num_mip_levels) : (mip_level += 1) {
                const prev_mip = mip_level - 1;
                const src_w = @max(@as(u32, 1), @as(u32, @truncate(width >> @as(u6, @truncate(prev_mip)))));
                const src_h = @max(@as(u32, 1), @as(u32, @truncate(height >> @as(u6, @truncate(prev_mip)))));
                const dst_w = @max(@as(u32, 1), @as(u32, @truncate(width >> @as(u6, @truncate(mip_level)))));
                const dst_h = @max(@as(u32, 1), @as(u32, @truncate(height >> @as(u6, @truncate(mip_level)))));

                // Transition dest mip level: undefined → transfer_dst_optimal
                try self.transitionImageLayout(cmd, texture_image, .undefined, .transfer_dst_optimal, mip_level, 1, 0, image_count);

                // Blit from prev mip (transfer_src_optimal) → current mip (transfer_dst_optimal)
                const blit_region = vk.ImageBlit{
                    .src_subresource = .{
                        .aspect_mask = .{ .color_bit = true },
                        .mip_level = prev_mip,
                        .base_array_layer = 0,
                        .layer_count = image_count,
                    },
                    .src_offsets = .{
                        .{ .x = 0, .y = 0, .z = 0 },
                        .{ .x = @as(i32, @intCast(src_w)), .y = @as(i32, @intCast(src_h)), .z = 1 },
                    },
                    .dst_subresource = .{
                        .aspect_mask = .{ .color_bit = true },
                        .mip_level = mip_level,
                        .base_array_layer = 0,
                        .layer_count = image_count,
                    },
                    .dst_offsets = .{
                        .{ .x = 0, .y = 0, .z = 0 },
                        .{ .x = @as(i32, @intCast(dst_w)), .y = @as(i32, @intCast(dst_h)), .z = 1 },
                    },
                };

                self.renderer.dev.cmdBlitImage(
                    cmd,
                    texture_image,
                    .transfer_src_optimal,
                    texture_image,
                    .transfer_dst_optimal,
                    &[_]vk.ImageBlit{blit_region},
                    .linear,
                );

                // Transition prev mip to shader_read_only (done with it)
                try self.transitionImageLayout(cmd, texture_image, .transfer_src_optimal, .shader_read_only_optimal, prev_mip, 1, 0, image_count);

                // Transition current mip to transfer_src_optimal for next iteration (or final read)
                try self.transitionImageLayout(cmd, texture_image, .transfer_dst_optimal, .transfer_src_optimal, mip_level, 1, 0, image_count);
            }

            // Transition last mip level: transfer_src_optimal → shader_read_only_optimal
            try self.transitionImageLayout(cmd, texture_image, .transfer_src_optimal, .shader_read_only_optimal, num_mip_levels - 1, 1, 0, image_count);
        } else {
            // No mipmaps: transition mip 0: transfer_src_optimal → shader_read_only_optimal
            try self.transitionImageLayout(cmd, texture_image, .transfer_src_optimal, .shader_read_only_optimal, 0, 1, 0, image_count);
        }

        try self.renderer.endSingleTimeCommands(io, cmd);

        // --- Create image view (2D array) ---
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

        // --- Create sampler (matches OpenGL: LINEAR_MIPMAP_LINEAR min, NEAREST mag) ---
        const sampler_info = vk.SamplerCreateInfo{
            .flags = .{},
            .mag_filter = .nearest,
            .min_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .mip_lod_bias = 0.0,
            .anisotropy_enable = .false,
            .max_anisotropy = 1.0,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0.0,
            .max_lod = @floatFromInt(num_mip_levels - 1),
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = .false,
        };

        const sampler = try self.renderer.dev.createSampler(&sampler_info, null);

        // --- Update per-frame descriptor sets (binding 1 = combined_image_sampler) ---
        const descriptor_image_info = vk.DescriptorImageInfo{
            .image_layout = .shader_read_only_optimal,
            .image_view = texture_view,
            .sampler = sampler,
        };

        for (self.renderer.descriptor_sets_per_frame) |desc_set| {
            const descriptor_write = vk.WriteDescriptorSet{
                .dst_set = desc_set,
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .combined_image_sampler,
                .p_image_info = @ptrCast(&descriptor_image_info),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };

            self.renderer.dev.updateDescriptorSets(&[_]vk.WriteDescriptorSet{descriptor_write}, null);
        }

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
        } else if (old_layout == .transfer_dst_optimal and new_layout == .transfer_src_optimal) {
            barrier.src_access_mask = .{ .transfer_write_bit = true };
            barrier.dst_access_mask = .{ .transfer_read_bit = true };
            source_stage = .{ .transfer_bit = true };
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
        } else if (old_layout == .shader_read_only_optimal and new_layout == .transfer_src_optimal) {
            barrier.src_access_mask = .{ .shader_read_bit = true };
            barrier.dst_access_mask = .{ .transfer_read_bit = true };
            source_stage = .{ .fragment_shader_bit = true };
            dest_stage = .{ .transfer_bit = true };
        } else if (old_layout == .transfer_dst_optimal and new_layout == .shader_read_only_optimal) {
            barrier.src_access_mask = .{ .transfer_write_bit = true };
            barrier.dst_access_mask = .{ .shader_read_bit = true };
            source_stage = .{ .transfer_bit = true };
            dest_stage = .{ .fragment_shader_bit = true };
        } else if (old_layout == .transfer_src_optimal and new_layout == .transfer_dst_optimal) {
            barrier.src_access_mask = .{ .transfer_read_bit = true };
            barrier.dst_access_mask = .{ .transfer_write_bit = true };
            source_stage = .{ .transfer_bit = true };
            dest_stage = .{ .transfer_bit = true };
        } else {
            @panic("Unsupported layout transition");
        }

        self.renderer.dev.cmdPipelineBarrier(cmd, source_stage, dest_stage, .{}, null, null, @ptrCast(&[_]vk.ImageMemoryBarrier{barrier}));
    }

    /// Rebind the texture array to all per-frame descriptor sets (needed after swapchain
    /// recreation, which destroys and recreates the descriptor pool).
    pub fn rebindDescriptorSets(self: *TextureArrayManager) void {
        if (self.texture_view == .null_handle or self.sampler == .null_handle) return;
        const descriptor_image_info = vk.DescriptorImageInfo{
            .image_layout = .shader_read_only_optimal,
            .image_view = self.texture_view,
            .sampler = self.sampler,
        };
        for (self.renderer.descriptor_sets_per_frame) |desc_set| {
            const descriptor_write = vk.WriteDescriptorSet{
                .dst_set = desc_set,
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .combined_image_sampler,
                .p_image_info = @ptrCast(&descriptor_image_info),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };
            self.renderer.dev.updateDescriptorSets(&[_]vk.WriteDescriptorSet{descriptor_write}, null);
        }
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

test "TextureArrayManager.init — null handles and zeroed state" {
    // init() should return a manager with null_handle for all Vulkan resources
    const manager = TextureArrayManager.init(undefined);
    try std.testing.expectEqual(@as(vk.Image, .null_handle), manager.texture_image);
    try std.testing.expectEqual(@as(vk.DeviceMemory, .null_handle), manager.texture_memory);
    try std.testing.expectEqual(@as(vk.ImageView, .null_handle), manager.texture_view);
    try std.testing.expectEqual(@as(vk.Sampler, .null_handle), manager.sampler);
}

fn getResolution(io: std.Io, allocator: std.mem.Allocator, textures_path: std.Io.Dir, filename: []const u8, read_buffer: *[zigimg.io.DEFAULT_BUFFER_SIZE]u8) ![2]usize {
    const texture = try textures_path.openFile(io, filename, .{});
    defer texture.close(io);

    var img = try zigimg.Image.fromFile(allocator, io, texture, read_buffer);
    defer img.deinit(allocator);

    return [2]usize{ img.width, img.height };
}
