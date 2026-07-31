const std = @import("std");

const vk = @import("vulkan");
const zignal = @import("zignal");

const VulkanRenderer = @import("VulkanRenderer.zig");
const Block = @import("../../world/Block.zig").Block;

const visible_block_count = Block.visible_count;

const visible_block_names: [visible_block_count][]const u8 = blk: {
    var names: [visible_block_count][]const u8 = undefined;
    var i: usize = 0;
    for (std.meta.fields(Block)) |field| {
        if (!@field(Block, field.name).isVisible()) continue;
        names[i] = field.name;
        i += 1;
    }
    break :blk names;
};

const Texture = struct {
    image: vk.Image = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    view: vk.ImageView = .null_handle,
    num_mip_levels: u16 = 0,
};

const StageAccess = struct {
    stage: vk.PipelineStageFlags2,
    access: vk.AccessFlags2,
};

const Transition = struct {
    src: StageAccess,
    dst: StageAccess,
};

fn transitionFor(old: vk.ImageLayout, new: vk.ImageLayout) Transition {
    switch (old) {
        .undefined => switch (new) {
            .transfer_dst_optimal => return .{ .src = .{ .stage = .{}, .access = .{} }, .dst = .{ .stage = .{ .all_transfer_bit = true }, .access = .{ .transfer_write_bit = true } } },
            .transfer_src_optimal => return .{ .src = .{ .stage = .{}, .access = .{} }, .dst = .{ .stage = .{ .all_transfer_bit = true }, .access = .{ .transfer_read_bit = true } } },
            else => unreachable,
        },
        .transfer_dst_optimal => switch (new) {
            .transfer_src_optimal => return .{ .src = .{ .stage = .{ .all_transfer_bit = true }, .access = .{ .transfer_write_bit = true } }, .dst = .{ .stage = .{ .all_transfer_bit = true }, .access = .{ .transfer_read_bit = true } } },
            .shader_read_only_optimal => return .{ .src = .{ .stage = .{ .all_transfer_bit = true }, .access = .{ .transfer_write_bit = true } }, .dst = .{ .stage = .{ .fragment_shader_bit = true }, .access = .{ .shader_read_bit = true } } },
            else => unreachable,
        },
        .transfer_src_optimal => switch (new) {
            .shader_read_only_optimal => return .{ .src = .{ .stage = .{ .all_transfer_bit = true }, .access = .{ .transfer_read_bit = true } }, .dst = .{ .stage = .{ .fragment_shader_bit = true }, .access = .{ .shader_read_bit = true } } },
            else => unreachable,
        },
        else => unreachable,
    }
}

pub const TextureManager = struct {
    renderer: *VulkanRenderer,
    gamma_correction: bool,
    sampler: vk.Sampler = .null_handle,
    textures: std.enums.EnumArray(Block, Texture) = .initFill(.{}),
    default_texture: Texture = .{},
    descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    descriptor_pool: vk.DescriptorPool = .null_handle,
    descriptor_set: vk.DescriptorSet = .null_handle,

    pub fn init(renderer: *VulkanRenderer, gamma_correction: bool) TextureManager {
        return .{ .renderer = renderer, .gamma_correction = gamma_correction };
    }

    pub fn loadTextures(self: *TextureManager, io: std.Io, allocator: std.mem.Allocator, selected_pack: []const u8) !void {
        const pack_path = try std.fmt.allocPrint(allocator, "packs/{s}/blocks/", .{selected_pack});
        defer allocator.free(pack_path);

        const is_default = std.mem.eql(u8, selected_pack, "default");

        var pack_dir = if (is_default)
            try std.Io.Dir.cwd().createDirPathOpen(io, pack_path, .{ .open_options = .{ .iterate = true } })
        else
            try std.Io.Dir.cwd().openDir(io, pack_path, .{ .iterate = true });
        defer pack_dir.close(io);

        if (is_default) {
            const default_textures = @import("textures").default;
            for (visible_block_names, default_textures) |name, data| {
                const filename = try std.fmt.allocPrint(allocator, "{s}.png", .{name});
                defer allocator.free(filename);

                if (pack_dir.openFile(io, filename, .{})) |f| {
                    f.close(io);
                } else |err| {
                    switch (err) {
                        error.FileNotFound => try pack_dir.writeFile(io, .{ .data = data, .sub_path = filename }),
                        else => |e| return e,
                    }
                }
            }
        }

        try self.loadTextureDirectory(io, pack_dir, allocator, ".png");
    }

    pub fn loadTextureDirectory(
        self: *TextureManager,
        io: std.Io,
        dir: std.Io.Dir,
        allocator: std.mem.Allocator,
        keyword: []const u8,
    ) !void {
        self.createSampler();
        errdefer if (self.sampler != .null_handle) {
            self.renderer.dev.destroySampler(self.sampler, null);
            self.sampler = .null_handle;
        };

        errdefer {
            for (&self.textures.values) |*tex| self.destroyTexture(tex);
            self.destroyTexture(&self.default_texture);
        }

        var entry_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (entry_names.items) |n| allocator.free(n);
            entry_names.deinit(allocator);
        }
        var entry_blocks: std.ArrayListUnmanaged(Block) = .empty;
        defer entry_blocks.deinit(allocator);

        {
            var dir_it = std.Io.Dir.iterate(dir);
            while (try dir_it.next(io)) |entry| {
                if (entry.kind != .file or std.mem.indexOf(u8, entry.name, keyword) == null) continue;
                const dot = std.mem.indexOfScalar(u8, entry.name, '.') orelse entry.name.len;
                const block_type = std.meta.stringToEnum(Block, entry.name[0..dot]) orelse continue;
                if (!block_type.isVisible()) continue;

                try entry_names.append(allocator, try allocator.dupe(u8, entry.name));
                try entry_blocks.append(allocator, block_type);
            }
        }

        if (entry_names.items.len == 0) return error.NoTexturesFound;

        const format: vk.Format = if (self.gamma_correction) .r8g8b8a8_srgb else .r8g8b8a8_unorm;

        var cmd = try self.renderer.beginSingleTimeCommands();
        errdefer if (cmd != .null_handle)
            self.renderer.dev.freeCommandBuffers(self.renderer.upload_command_pool, (&cmd)[0..1]);

        var staging_slices: std.ArrayListUnmanaged([]u8) = .empty;
        try staging_slices.ensureTotalCapacity(allocator, entry_names.items.len + 1);
        defer {
            for (staging_slices.items) |s| self.renderer.cpu_to_gpu_gpa.allocator().free(s);
            staging_slices.deinit(allocator);
        }

        // 1x1 magenta fallback for blocks without a pack texture, batched into the same upload pass.
        {
            const default_pixels: [4]u8 = .{ 255, 0, 255, 255 };
            const staging = try self.uploadSingleTexture(cmd, &self.default_texture, 1, 1, &default_pixels, format);
            staging_slices.appendAssumeCapacity(staging);
        }

        for (entry_names.items, entry_blocks.items) |name, block_type| {
            const texture_file = try dir.openFile(io, name, .{});
            defer texture_file.close(io);

            const stat = try texture_file.stat(io);
            const content = try allocator.alloc(u8, stat.size);
            defer allocator.free(content);
            if (try texture_file.readPositionalAll(io, content, 0) != content.len) return error.EndOfStream;

            var loaded_img = try zignal.Image(zignal.Rgba(u8)).loadFromBytes(allocator, content);
            defer loaded_img.deinit(allocator);

            const w: u32 = @intCast(loaded_img.cols);
            const h: u32 = @intCast(loaded_img.rows);

            const staging = try self.uploadSingleTexture(cmd, self.textures.getPtr(block_type), w, h, loaded_img.asBytes(), format);
            staging_slices.appendAssumeCapacity(staging);
        }

        const end_err = self.renderer.endSingleTimeCommands(io, cmd);
        cmd = .null_handle;
        try end_err;

        self.default_texture.view = try self.createTextureView(&self.default_texture, format);
        for (entry_blocks.items) |block_type| {
            const tex = self.textures.getPtr(block_type);
            tex.view = try self.createTextureView(tex, format);
        }

        try self.createDescriptorResources();
        std.log.info("Loaded {d} bindless textures", .{entry_names.items.len});
    }

    fn createSampler(self: *TextureManager) void {
        const anisotropy = self.renderer.vk_ctx.sampler_anisotropy;
        self.sampler = self.renderer.dev.createSampler(&.{
            .mag_filter = .nearest,
            .min_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .mip_lod_bias = 0.0,
            .anisotropy_enable = if (anisotropy) .true else .false,
            .max_anisotropy = 16.0,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0.0,
            .max_lod = vk.LOD_CLAMP_NONE,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = .false,
        }, null) catch |err| @panic(@errorName(err));
    }

    fn createTextureView(self: *TextureManager, tex: *Texture, format: vk.Format) !vk.ImageView {
        return self.renderer.dev.createImageView(&.{
            .image = tex.image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = tex.num_mip_levels, .base_array_layer = 0, .layer_count = 1 },
        }, null);
    }

    fn createDescriptorResources(self: *TextureManager) !void {
        const num_textures = std.enums.EnumIndexer(Block).count;
        const binding_flags = vk.DescriptorBindingFlags{ .update_after_bind_bit = true, .partially_bound_bit = true };
        const flags_info = vk.DescriptorSetLayoutBindingFlagsCreateInfo{ .binding_count = 1, .p_binding_flags = (&binding_flags)[0..1] };

        self.descriptor_set_layout = try self.renderer.dev.createDescriptorSetLayout(&.{
            .flags = .{ .update_after_bind_pool_bit = true },
            .p_next = &flags_info,
            .binding_count = 1,
            .p_bindings = &.{.{
                .binding = 0,
                .descriptor_type = .combined_image_sampler,
                .descriptor_count = @intCast(num_textures),
                .stage_flags = .{ .fragment_bit = true },
                .p_immutable_samplers = null,
            }},
        }, null);
        errdefer {
            self.renderer.dev.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
            self.descriptor_set_layout = .null_handle;
        }

        self.descriptor_pool = try self.renderer.dev.createDescriptorPool(&.{
            .flags = .{ .update_after_bind_bit = true },
            .max_sets = 1,
            .pool_size_count = 1,
            .p_pool_sizes = &.{.{ .type = .combined_image_sampler, .descriptor_count = @intCast(num_textures) }},
        }, null);
        errdefer {
            self.renderer.dev.destroyDescriptorPool(self.descriptor_pool, null);
            self.descriptor_pool = .null_handle;
        }

        try self.renderer.dev.allocateDescriptorSets(&.{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = (&self.descriptor_set_layout)[0..1],
        }, (&self.descriptor_set)[0..1]);

        var image_infos: [num_textures]vk.DescriptorImageInfo = undefined;
        var tex_it = self.textures.iterator();
        for (&image_infos) |*info| {
            const entry = tex_it.next().?;
            const tex = if (entry.value.view != .null_handle) entry.value else &self.default_texture;
            info.* = .{ .sampler = self.sampler, .image_view = tex.view, .image_layout = .shader_read_only_optimal };
        }

        self.renderer.dev.updateDescriptorSets(&.{vk.WriteDescriptorSet{
            .dst_set = self.descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = @intCast(num_textures),
            .descriptor_type = .combined_image_sampler,
            .p_image_info = &image_infos,
            .p_buffer_info = &VulkanRenderer.null_buffer_info,
            .p_texel_buffer_view = &VulkanRenderer.null_buffer_view,
        }}, null);
    }

    fn destroyTexture(self: *TextureManager, tex: *Texture) void {
        if (tex.view != .null_handle) {
            self.renderer.dev.destroyImageView(tex.view, null);
            tex.view = .null_handle;
        }
        if (tex.image != .null_handle) {
            self.renderer.dev.destroyImage(tex.image, null);
            tex.image = .null_handle;
        }
        if (tex.memory != .null_handle) {
            self.renderer.dev.freeMemory(tex.memory, null);
            tex.memory = .null_handle;
        }
    }

    fn uploadSingleTexture(
        self: *TextureManager,
        cmd: vk.CommandBuffer,
        tex: *Texture,
        width: u32,
        height: u32,
        rgba_data: []const u8,
        format: vk.Format,
    ) ![]u8 {
        const image_size: vk.DeviceSize = @intCast(width * height * 4);
        const num_mip_levels: u16 = @intCast(std.math.log2(@max(width, height)) + 1);
        const image_info = vk.ImageCreateInfo{
            .image_type = .@"2d",
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mip_levels = num_mip_levels,
            .array_layers = 1,
            .format = format,
            .tiling = .optimal,
            .initial_layout = .undefined,
            .usage = .{ .transfer_src_bit = true, .transfer_dst_bit = true, .sampled_bit = true },
            .sharing_mode = .exclusive,
            .samples = .{ .@"1_bit" = true },
        };

        var mem_reqs2: vk.MemoryRequirements2 = .{ .memory_requirements = undefined };
        self.renderer.dev.getDeviceImageMemoryRequirements(&.{ .p_create_info = &image_info, .plane_aspect = .{} }, &mem_reqs2);

        const memory = try self.renderer.dev.allocateMemory(&.{
            .allocation_size = mem_reqs2.memory_requirements.size,
            .memory_type_index = try self.renderer.findMemoryType(mem_reqs2.memory_requirements.memory_type_bits, .{ .device_local_bit = true }),
        }, null);
        errdefer self.renderer.dev.freeMemory(memory, null);

        const image = try self.renderer.dev.createImage(&image_info, null);
        errdefer self.renderer.dev.destroyImage(image, null);

        try self.renderer.dev.bindImageMemory(image, memory, 0);

        const staging = try self.renderer.cpu_to_gpu_gpa.allocator().alloc(u8, image_size);
        @memcpy(staging, rgba_data);

        const staging_info = self.renderer.backing_allocator.getBufferAndOffset(.cpu_to_gpu, staging.ptr);

        self.imageBarrier(cmd, image, .undefined, .transfer_dst_optimal, 0, 1);

        self.renderer.dev.cmdCopyBufferToImage(cmd, staging_info.buffer, image, .transfer_dst_optimal, &.{vk.BufferImageCopy{
            .buffer_offset = staging_info.offset,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = width, .height = height, .depth = 1 },
        }});

        self.generateMipmaps(cmd, image, width, height, num_mip_levels);

        tex.image = image;
        tex.memory = memory;
        tex.num_mip_levels = num_mip_levels;

        return staging;
    }

    fn generateMipmaps(
        self: *TextureManager,
        cmd: vk.CommandBuffer,
        image: vk.Image,
        width: u32,
        height: u32,
        num_mip_levels: u16,
    ) void {
        if (num_mip_levels == 1) {
            self.imageBarrier(cmd, image, .transfer_dst_optimal, .shader_read_only_optimal, 0, 1);
            return;
        }

        var mip: u32 = 1;
        while (mip < num_mip_levels) : (mip += 1) {
            const sw = @max(1, width >> @intCast(mip - 1));
            const sh = @max(1, height >> @intCast(mip - 1));
            const dw = @max(1, width >> @intCast(mip));
            const dh = @max(1, height >> @intCast(mip));

            // Each mip is downscaled from the previous one: make mip (mip-1) readable as the
            // blit source, then target mip `mip` as the destination.
            self.imageBarrier(cmd, image, .transfer_dst_optimal, .transfer_src_optimal, mip - 1, 1);
            self.imageBarrier(cmd, image, .undefined, .transfer_dst_optimal, mip, 1);

            self.renderer.dev.cmdBlitImage(cmd, image, .transfer_src_optimal, image, .transfer_dst_optimal, &.{
                vk.ImageBlit{
                    .src_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = mip - 1, .base_array_layer = 0, .layer_count = 1 },
                    .src_offsets = .{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = @intCast(sw), .y = @intCast(sh), .z = 1 } },
                    .dst_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = mip, .base_array_layer = 0, .layer_count = 1 },
                    .dst_offsets = .{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = @intCast(dw), .y = @intCast(dh), .z = 1 } },
                },
            }, .linear);

            self.imageBarrier(cmd, image, .transfer_src_optimal, .shader_read_only_optimal, mip - 1, 1);
        }

        self.imageBarrier(cmd, image, .transfer_dst_optimal, .shader_read_only_optimal, num_mip_levels - 1, 1);
    }

    fn imageBarrier(
        self: *TextureManager,
        cmd: vk.CommandBuffer,
        image: vk.Image,
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
        base_mip: u32,
        mip_count: u32,
    ) void {
        const t = transitionFor(old_layout, new_layout);
        self.renderer.dev.cmdPipelineBarrier2(cmd, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = (&vk.ImageMemoryBarrier2{
                .src_stage_mask = t.src.stage,
                .src_access_mask = t.src.access,
                .dst_stage_mask = t.dst.stage,
                .dst_access_mask = t.dst.access,
                .old_layout = old_layout,
                .new_layout = new_layout,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = image,
                .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = base_mip, .level_count = mip_count, .base_array_layer = 0, .layer_count = 1 },
            })[0..1],
        });
    }

    pub fn deinit(self: *TextureManager) void {
        for (&self.textures.values) |*tex| self.destroyTexture(tex);
        self.destroyTexture(&self.default_texture);
        if (self.descriptor_pool != .null_handle) self.renderer.dev.destroyDescriptorPool(self.descriptor_pool, null);
        if (self.descriptor_set_layout != .null_handle) self.renderer.dev.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
        if (self.sampler != .null_handle) self.renderer.dev.destroySampler(self.sampler, null);
    }
};

test "TextureManager.init — null handles and zeroed state" {
    const manager = TextureManager.init(undefined, true);
    try std.testing.expectEqual(@as(vk.Sampler, .null_handle), manager.sampler);
    try std.testing.expectEqual(@as(vk.DescriptorSetLayout, .null_handle), manager.descriptor_set_layout);
    try std.testing.expectEqual(@as(vk.DescriptorPool, .null_handle), manager.descriptor_pool);
    try std.testing.expectEqual(@as(vk.DescriptorSet, .null_handle), manager.descriptor_set);
}
