const std = @import("std");

const vk = @import("vulkan");
const zigimg = @import("zigimg");

const VulkanRenderer = @import("VulkanRenderer.zig");
const Block = @import("../../main.zig").Block;

pub const TextureArrayManager = struct {
    renderer: *VulkanRenderer,
    gamma_correction: bool,
    texture_image: vk.Image,
    texture_memory: vk.DeviceMemory,
    texture_view: vk.ImageView,
    sampler: vk.Sampler,

    pub fn init(renderer: *VulkanRenderer, gamma_correction: bool) TextureArrayManager {
        return .{
            .renderer = renderer,
            .gamma_correction = gamma_correction,
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

        const indexer = std.enums.EnumIndexer(Block);

        var entry_names: std.ArrayList([]const u8) = .empty;
        defer {
            for (entry_names.items) |n| allocator.free(n);
            entry_names.deinit(allocator);
        }

        var max_layer_index: usize = 0;

        {
            var dir_it = std.Io.Dir.iterate(textures_path);
            while (try dir_it.next(io)) |entry| {
                if (entry.kind != .file or std.mem.indexOf(u8, entry.name, keyword) == null) continue;

                const dot = std.mem.indexOfScalar(u8, entry.name, '.') orelse entry.name.len;
                const block_name = entry.name[0..dot];
                const block_type = std.meta.stringToEnum(Block, block_name) orelse {
                    std.log.warn("Skipping non-block texture: {s}\n", .{entry.name});
                    continue;
                };
                if (!block_type.isVisible()) {
                    std.log.warn("Skipping non-block texture: {s}\n", .{entry.name});
                    continue;
                }

                max_layer_index = @max(max_layer_index, indexer.indexOf(block_type));

                try entry_names.append(allocator, try allocator.dupe(u8, entry.name));
            }
        }

        if (entry_names.items.len == 0) return error.NoTexturesFound;

        const layer_count = max_layer_index + 1;

        // Open and read just the first texture to determine resolution
        var first_w: usize = 0;
        var first_h: usize = 0;
        {
            const first_name = entry_names.items[0];
            const texture_file = try textures_path.openFile(io, first_name, .{});
            defer texture_file.close(io);
            var loaded_img = try zigimg.Image.fromFile(allocator, io, texture_file, &read_buffer);
            defer loaded_img.deinit(allocator);
            first_w = loaded_img.width;
            first_h = loaded_img.height;
        }

        if (first_w != first_h) return error.TexturesNotSquare;

        std.log.info("texture resolution: {d}x{d}, count: {d}\n", .{ first_w, first_h, entry_names.items.len });
        std.log.info("loading {d} texture layers sequentially...\n", .{layer_count});

        try self.createVulkanTextureArray(io, allocator, textures_path, entry_names.items, first_w, first_h, layer_count);
    }

    fn createVulkanTextureArray(
        self: *TextureArrayManager,
        io: std.Io,
        allocator: std.mem.Allocator,
        textures_path: std.Io.Dir,
        entry_names: [][]const u8,
        width: usize,
        height: usize,
        layer_count: usize,
    ) !void {
        const image_count: u32 = @intCast(layer_count);
        const image_size: vk.DeviceSize = @intCast(width * height * 4);

        const total_staging_size = image_size * image_count;
        const mapped_slice = try self.renderer.cpu_to_gpu_gpa.allocator().alloc(u8, total_staging_size);
        defer self.renderer.cpu_to_gpu_gpa.allocator().free(mapped_slice);

        const info = self.renderer.backing_allocator.getBufferAndOffset(.cpu_to_gpu, mapped_slice.ptr);
        const staging_buffer = info.buffer;
        const staging_offset = info.offset;

        const indexer = std.enums.EnumIndexer(Block);
        var loaded_layers = try allocator.alloc(bool, layer_count);
        defer allocator.free(loaded_layers);
        @memset(loaded_layers, false);

        var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;

        for (entry_names) |name| {
            const dot = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
            const block_name = name[0..dot];
            const block_type = std.meta.stringToEnum(Block, block_name) orelse continue;
            const layer = indexer.indexOf(block_type);

            const texture_file = try textures_path.openFile(io, name, .{});
            defer texture_file.close(io);

            var loaded_img = try zigimg.Image.fromFile(allocator, io, texture_file, &read_buffer);
            defer loaded_img.deinit(allocator);

            try loaded_img.convert(allocator, .rgba32);

            if (loaded_img.width != width or loaded_img.height != height) {
                return error.InconsistentTextureResolution;
            }

            const layer_offset = @as(vk.DeviceSize, @intCast(layer)) * image_size;
            const rgba_data = loaded_img.rawBytes();
            @memcpy(mapped_slice[layer_offset .. layer_offset + rgba_data.len], rgba_data);
            loaded_layers[layer] = true;
        }

        for (0..layer_count) |layer| {
            if (!loaded_layers[layer]) {
                const layer_offset = @as(vk.DeviceSize, @intCast(layer)) * image_size;
                for (0..height) |y| {
                    for (0..width) |x| {
                        const is_magenta = ((x / 8) + (y / 8)) % 2 == 0;
                        const idx = layer_offset + (y * width + x) * 4;
                        mapped_slice[idx + 0] = if (is_magenta) 255 else 0;
                        mapped_slice[idx + 1] = 0;
                        mapped_slice[idx + 2] = if (is_magenta) 255 else 0;
                        mapped_slice[idx + 3] = 255;
                    }
                }
            }
        }

        const max_dim = @max(width, height);
        const num_mip_levels: u16 = @intCast(std.math.log2(max_dim) + 1);

        const image_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .extent = .{ .width = @intCast(width), .height = @intCast(height), .depth = 1 },
            .mip_levels = num_mip_levels,
            .array_layers = @intCast(image_count),
            .format = if (self.gamma_correction) .r8g8b8a8_srgb else .r8g8b8a8_unorm,
            .tiling = .optimal,
            .initial_layout = .undefined,
            .usage = .{ .transfer_src_bit = true, .transfer_dst_bit = true, .sampled_bit = true },
            .sharing_mode = .exclusive,
            .samples = .{ .@"1_bit" = true },
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        };

        var mem_reqs2: vk.MemoryRequirements2 = .{
            .memory_requirements = undefined,
        };
        self.renderer.dev.getDeviceImageMemoryRequirements(&.{
            .p_create_info = &image_info,
            .plane_aspect = .{},
        }, &mem_reqs2);
        const mem_reqs = mem_reqs2.memory_requirements;

        const alloc_info = vk.MemoryAllocateInfo{
            .allocation_size = mem_reqs.size,
            .memory_type_index = try self.renderer.findMemoryType(mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
        };
        const memory = try self.renderer.dev.allocateMemory(&alloc_info, null);
        errdefer self.renderer.dev.freeMemory(memory, null);

        const texture_image = try self.renderer.dev.createImage(&image_info, null);
        errdefer self.renderer.dev.destroyImage(texture_image, null);

        try self.renderer.dev.bindImageMemory(texture_image, memory, 0);

        var cmd = try self.renderer.beginSingleTimeCommands();
        errdefer if (cmd != .null_handle)
            self.renderer.dev.freeCommandBuffers(self.renderer.upload_command_pool, &.{cmd});

        try self.transitionImageLayout(cmd, texture_image, .undefined, .transfer_dst_optimal, 0, 1, 0, image_count);

        var copy_regions = try allocator.alloc(vk.BufferImageCopy, image_count);
        defer allocator.free(copy_regions);

        const w: u32 = @intCast(width);
        const h: u32 = @intCast(height);
        for (0..image_count) |layer_idx| {
            copy_regions[layer_idx] = .{
                .buffer_offset = staging_offset + (@as(vk.DeviceSize, @intCast(layer_idx)) * image_size),
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = 0,
                    .base_array_layer = @intCast(layer_idx),
                    .layer_count = 1,
                },
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .image_extent = .{ .width = w, .height = h, .depth = 1 },
            };
        }

        self.renderer.dev.cmdCopyBufferToImage(cmd, staging_buffer, texture_image, .transfer_dst_optimal, copy_regions);

        try self.transitionImageLayout(cmd, texture_image, .transfer_dst_optimal, .transfer_src_optimal, 0, 1, 0, image_count);

        if (num_mip_levels > 1) {
            var mip_level: u32 = 1;
            while (mip_level < num_mip_levels) : (mip_level += 1) {
                const prev_mip = mip_level - 1;
                const src_w = @max(1, width >> @as(u6, @intCast(prev_mip)));
                const src_h = @max(1, height >> @as(u6, @intCast(prev_mip)));
                const dst_w = @max(1, width >> @as(u6, @intCast(mip_level)));
                const dst_h = @max(1, height >> @as(u6, @intCast(mip_level)));

                try self.transitionImageLayout(cmd, texture_image, .undefined, .transfer_dst_optimal, mip_level, 1, 0, image_count);

                const blit_region = vk.ImageBlit{
                    .src_subresource = .{
                        .aspect_mask = .{ .color_bit = true },
                        .mip_level = prev_mip,
                        .base_array_layer = 0,
                        .layer_count = image_count,
                    },
                    .src_offsets = .{
                        .{ .x = 0, .y = 0, .z = 0 },
                        .{ .x = @intCast(src_w), .y = @intCast(src_h), .z = 1 },
                    },
                    .dst_subresource = .{
                        .aspect_mask = .{ .color_bit = true },
                        .mip_level = mip_level,
                        .base_array_layer = 0,
                        .layer_count = image_count,
                    },
                    .dst_offsets = .{
                        .{ .x = 0, .y = 0, .z = 0 },
                        .{ .x = @intCast(dst_w), .y = @intCast(dst_h), .z = 1 },
                    },
                };

                self.renderer.dev.cmdBlitImage(
                    cmd,
                    texture_image,
                    .transfer_src_optimal,
                    texture_image,
                    .transfer_dst_optimal,
                    &.{blit_region},
                    .linear,
                );

                try self.transitionImageLayout(cmd, texture_image, .transfer_src_optimal, .shader_read_only_optimal, prev_mip, 1, 0, image_count);

                try self.transitionImageLayout(cmd, texture_image, .transfer_dst_optimal, .transfer_src_optimal, mip_level, 1, 0, image_count);
            }
        }

        try self.transitionImageLayout(cmd, texture_image, .transfer_src_optimal, .shader_read_only_optimal, if (num_mip_levels > 1) num_mip_levels - 1 else 0, 1, 0, image_count);

        try self.renderer.endSingleTimeCommands(io, cmd);
        cmd = .null_handle;

        const view_info = vk.ImageViewCreateInfo{
            .flags = .{},
            .image = texture_image,
            .view_type = .@"2d_array",
            .format = if (self.gamma_correction) .r8g8b8a8_srgb else .r8g8b8a8_unorm,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = num_mip_levels,
                .base_array_layer = 0,
                .layer_count = image_count,
            },
        };

        const texture_view = try self.renderer.dev.createImageView(&view_info, null);
        errdefer self.renderer.dev.destroyImageView(texture_view, null);

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
            .max_lod = num_mip_levels - 1,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = .false,
        };

        const sampler = try self.renderer.dev.createSampler(&sampler_info, null);
        errdefer self.renderer.dev.destroySampler(sampler, null);

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
        var barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{},
            .src_access_mask = .{},
            .dst_stage_mask = .{},
            .dst_access_mask = .{},
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
        };

        if (old_layout == .undefined and new_layout == .transfer_dst_optimal) {
            barrier.dst_access_mask = .{ .transfer_write_bit = true };
            barrier.dst_stage_mask = .{ .all_transfer_bit = true };
        } else if (old_layout == .transfer_dst_optimal and new_layout == .transfer_src_optimal) {
            barrier.src_access_mask = .{ .transfer_write_bit = true };
            barrier.dst_access_mask = .{ .transfer_read_bit = true };
            barrier.src_stage_mask = .{ .all_transfer_bit = true };
            barrier.dst_stage_mask = .{ .all_transfer_bit = true };
        } else if (old_layout == .transfer_src_optimal and new_layout == .shader_read_only_optimal) {
            barrier.src_access_mask = .{ .transfer_read_bit = true, .transfer_write_bit = true };
            barrier.dst_access_mask = .{ .shader_read_bit = true };
            barrier.src_stage_mask = .{ .all_transfer_bit = true };
            barrier.dst_stage_mask = .{ .fragment_shader_bit = true };
        } else if (old_layout == .undefined and new_layout == .transfer_src_optimal) {
            barrier.dst_access_mask = .{ .transfer_read_bit = true };
            barrier.dst_stage_mask = .{ .all_transfer_bit = true };
        } else if (old_layout == .shader_read_only_optimal and new_layout == .transfer_src_optimal) {
            barrier.src_access_mask = .{ .shader_read_bit = true };
            barrier.dst_access_mask = .{ .transfer_read_bit = true };
            barrier.src_stage_mask = .{ .fragment_shader_bit = true };
            barrier.dst_stage_mask = .{ .all_transfer_bit = true };
        } else if (old_layout == .transfer_dst_optimal and new_layout == .shader_read_only_optimal) {
            barrier.src_access_mask = .{ .transfer_write_bit = true };
            barrier.dst_access_mask = .{ .shader_read_bit = true };
            barrier.src_stage_mask = .{ .all_transfer_bit = true };
            barrier.dst_stage_mask = .{ .fragment_shader_bit = true };
        } else if (old_layout == .transfer_src_optimal and new_layout == .transfer_dst_optimal) {
            barrier.src_access_mask = .{ .transfer_read_bit = true };
            barrier.dst_access_mask = .{ .transfer_write_bit = true };
            barrier.src_stage_mask = .{ .all_transfer_bit = true };
            barrier.dst_stage_mask = .{ .all_transfer_bit = true };
        } else {
            @panic("Unsupported layout transition");
        }

        self.renderer.dev.cmdPipelineBarrier2(cmd, &.{
            .dependency_flags = .{},
            .memory_barrier_count = 0,
            .p_memory_barriers = null,
            .buffer_memory_barrier_count = 0,
            .p_buffer_memory_barriers = null,
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = (&barrier)[0..1],
        });
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
    const manager = TextureArrayManager.init(undefined, true);
    try std.testing.expectEqual(@as(vk.Image, .null_handle), manager.texture_image);
    try std.testing.expectEqual(@as(vk.DeviceMemory, .null_handle), manager.texture_memory);
    try std.testing.expectEqual(@as(vk.ImageView, .null_handle), manager.texture_view);
    try std.testing.expectEqual(@as(vk.Sampler, .null_handle), manager.sampler);
}
