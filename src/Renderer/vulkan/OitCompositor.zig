const std = @import("std");
const tracy = @import("tracy");
const vk = @import("vulkan");

const DeviceProxy = vk.DeviceProxy;

const VulkanContext = @import("../../VulkanContext.zig").VulkanContext;
const core = @import("core.zig");

const composite_vert_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("comp_vert_spv")));
const composite_frag_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, @embedFile("comp_frag_spv")));

const RenderTarget = core.RenderTarget;

/// Weighted-blended order-independent transparency (accumulate / reveal / volume weight)
/// render targets plus the fullscreen composition pass that blends them with the opaque
/// color target and writes to the swapchain. Reusable by any renderer needing transparency.
pub const OitCompositor = struct {
    allocator: std.mem.Allocator,
    dev: DeviceProxy,
    vk_ctx: *VulkanContext,

    accum: RenderTarget = .{},
    reveal: RenderTarget = .{},
    volume_weight: RenderTarget = .{},
    sampler: vk.Sampler = .null_handle,
    composition_pipeline: vk.Pipeline = .null_handle,
    composition_layout: vk.PipelineLayout = .null_handle,
    descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    descriptor_sets_per_frame: []vk.DescriptorSet = &.{},
    descriptor_pool: vk.DescriptorPool = .null_handle,

    pub fn init(allocator: std.mem.Allocator, vk_ctx: *VulkanContext) !OitCompositor {
        var self: OitCompositor = .{
            .allocator = allocator,
            .dev = vk_ctx.dev,
            .vk_ctx = vk_ctx,
        };
        self.allocator = allocator;
        self.dev = vk_ctx.dev;
        self.vk_ctx = vk_ctx;
        self.sampler = try self.dev.createSampler(&.{
            .flags = .{},
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mip_lod_bias = 0,
            .anisotropy_enable = .false,
            .max_anisotropy = 1.0,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0,
            .max_lod = 0,
            .border_color = .float_opaque_black,
            .unnormalized_coordinates = .false,
        }, &self.vk_ctx.vkalloc);
        errdefer self.dev.destroySampler(self.sampler, &self.vk_ctx.vkalloc);
        return self;
    }

    pub fn deinit(self: *OitCompositor) void {
        core.destroyRenderTarget(self.dev, &self.accum, &self.vk_ctx.vkalloc);
        core.destroyRenderTarget(self.dev, &self.reveal, &self.vk_ctx.vkalloc);
        core.destroyRenderTarget(self.dev, &self.volume_weight, &self.vk_ctx.vkalloc);

        if (self.descriptor_pool != .null_handle) {
            self.dev.destroyDescriptorPool(self.descriptor_pool, &self.vk_ctx.vkalloc);
            self.descriptor_pool = .null_handle;
        }
        if (self.descriptor_sets_per_frame.len > 0) {
            self.allocator.free(self.descriptor_sets_per_frame);
            self.descriptor_sets_per_frame = &.{};
        }

        core.destroyIfValid(self.dev, &self.composition_pipeline, &self.vk_ctx.vkalloc);
        core.destroyIfValid(self.dev, &self.composition_layout, &self.vk_ctx.vkalloc);
        core.destroyIfValid(self.dev, &self.descriptor_set_layout, &self.vk_ctx.vkalloc);
        core.destroyIfValid(self.dev, &self.sampler, &self.vk_ctx.vkalloc);
    }

    /// Recreates everything except the sampler: composition pipeline/layout, descriptor
    /// resources, and the three OIT targets. Called on init and on swapchain recreation.
    pub fn recreate(self: *OitCompositor, extent: vk.Extent2D, color_view: vk.ImageView) !void {
        core.destroyIfValid(self.dev, &self.composition_pipeline, &self.vk_ctx.vkalloc);
        core.destroyIfValid(self.dev, &self.composition_layout, &self.vk_ctx.vkalloc);
        core.destroyIfValid(self.dev, &self.descriptor_set_layout, &self.vk_ctx.vkalloc);
        if (self.descriptor_pool != .null_handle) {
            self.dev.destroyDescriptorPool(self.descriptor_pool, &self.vk_ctx.vkalloc);
            self.descriptor_pool = .null_handle;
        }
        if (self.descriptor_sets_per_frame.len > 0) {
            self.allocator.free(self.descriptor_sets_per_frame);
            self.descriptor_sets_per_frame = &.{};
        }
        core.destroyRenderTarget(self.dev, &self.accum, &self.vk_ctx.vkalloc);
        core.destroyRenderTarget(self.dev, &self.reveal, &self.vk_ctx.vkalloc);
        core.destroyRenderTarget(self.dev, &self.volume_weight, &self.vk_ctx.vkalloc);

        const oit_usage: vk.ImageUsageFlags = .{ .color_attachment_bit = true, .sampled_bit = true };
        const oit_aspect: vk.ImageAspectFlags = .{ .color_bit = true };
        self.accum = try core.createImageWithMemory(self.dev, self.vk_ctx.mem_props, &self.vk_ctx.vkalloc, extent, .r16g16b16a16_sfloat, oit_usage, oit_aspect);
        errdefer core.destroyRenderTarget(self.dev, &self.accum, &self.vk_ctx.vkalloc);
        self.reveal = try core.createImageWithMemory(self.dev, self.vk_ctx.mem_props, &self.vk_ctx.vkalloc, extent, .r16g16b16a16_sfloat, oit_usage, oit_aspect);
        errdefer core.destroyRenderTarget(self.dev, &self.reveal, &self.vk_ctx.vkalloc);
        self.volume_weight = try core.createImageWithMemory(self.dev, self.vk_ctx.mem_props, &self.vk_ctx.vkalloc, extent, .r16_sfloat, oit_usage, oit_aspect);
        errdefer core.destroyRenderTarget(self.dev, &self.volume_weight, &self.vk_ctx.vkalloc);

        if (self.descriptor_set_layout == .null_handle) {
            const bindings: [4]vk.DescriptorSetLayoutBinding = .{
                .{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
                .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
                .{ .binding = 2, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
                .{ .binding = 3, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
            };
            self.descriptor_set_layout = try self.dev.createDescriptorSetLayout(&.{ .flags = .{}, .binding_count = bindings.len, .p_bindings = bindings[0..] }, &self.vk_ctx.vkalloc);
        }

        if (self.composition_layout == .null_handle) {
            const pc_range: vk.PushConstantRange = .{ .stage_flags = .{ .fragment_bit = true }, .offset = 0, .size = @sizeOf(u32) };
            self.composition_layout = try self.dev.createPipelineLayout(&.{
                .flags = .{},
                .set_layout_count = 1,
                .p_set_layouts = (&self.descriptor_set_layout)[0..1],
                .push_constant_range_count = 1,
                .p_push_constant_ranges = (&pc_range)[0..1],
            }, &self.vk_ctx.vkalloc);
        }

        if (self.composition_pipeline == .null_handle) {
            const vert_module = try core.createShaderModule(self.dev, &self.vk_ctx.vkalloc, composite_vert_spv);
            defer self.dev.destroyShaderModule(vert_module, &self.vk_ctx.vkalloc);
            const frag_module = try core.createShaderModule(self.dev, &self.vk_ctx.vkalloc, composite_frag_spv);
            defer self.dev.destroyShaderModule(frag_module, &self.vk_ctx.vkalloc);

            const blend: vk.PipelineColorBlendAttachmentState = .{
                .blend_enable = .false,
                .src_color_blend_factor = .one,
                .dst_color_blend_factor = .zero,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .zero,
                .alpha_blend_op = .add,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            };
            const no_vertex_input: vk.PipelineVertexInputStateCreateInfo = .{
                .flags = .{},
                .vertex_binding_description_count = 0,
                .p_vertex_binding_descriptions = null,
                .vertex_attribute_description_count = 0,
                .p_vertex_attribute_descriptions = null,
            };
            self.composition_pipeline = try core.buildGraphicsPipeline(self.dev, &self.vk_ctx.vkalloc, self.vk_ctx.pipeline_creation_feedback, vert_module, frag_module, &.{self.vk_ctx.swapchain_format}, .undefined, null, &.{blend}, self.composition_layout, no_vertex_input);
        }

        if (self.descriptor_pool == .null_handle) {
            const pool_size: vk.DescriptorPoolSize = .{ .type = .combined_image_sampler, .descriptor_count = @intCast(VulkanContext.max_frames_in_flight * 4) };
            try core.createFrameDescriptorPool(self.dev, self.allocator, &self.vk_ctx.vkalloc, &self.descriptor_pool, self.descriptor_set_layout, &self.descriptor_sets_per_frame, (&pool_size)[0..1]);
        }

        self.updateOitDescriptorSets(color_view);
    }

    pub fn updateOitDescriptorSets(self: *OitCompositor, color_view: vk.ImageView) void {
        const image_infos: [4]vk.DescriptorImageInfo = .{
            .{ .sampler = self.sampler, .image_view = color_view, .image_layout = .shader_read_only_optimal },
            .{ .sampler = self.sampler, .image_view = self.accum.view, .image_layout = .shader_read_only_optimal },
            .{ .sampler = self.sampler, .image_view = self.reveal.view, .image_layout = .shader_read_only_optimal },
            .{ .sampler = self.sampler, .image_view = self.volume_weight.view, .image_layout = .shader_read_only_optimal },
        };
        for (self.descriptor_sets_per_frame) |desc_set| {
            var writes: [4]vk.WriteDescriptorSet = undefined;
            inline for (0..4) |i| writes[i] = core.imageWriteDescriptorSet(desc_set, @intCast(i), &image_infos[i]);
            self.dev.updateDescriptorSets(&writes, null);
        }
    }

    pub fn recordCompositionPass(
        self: *OitCompositor,
        cmd_buffer: vk.CommandBuffer,
        extent: vk.Extent2D,
        output_image: vk.Image,
        output_view: vk.ImageView,
        current_frame: u32,
        scatter_enabled: u32,
        swapchain_old_layout: vk.ImageLayout,
        swapchain_layout_ptr: ?*vk.ImageLayout,
        color_image: vk.Image,
    ) void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordCompositionPass" });
        defer zone.end();
        const color_aspect: vk.ImageAspectFlags = .{ .color_bit = true };

        const pre_comp_barriers: [5]vk.ImageMemoryBarrier2 = .{
            core.makeImageBarrier2(color_image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true }, color_aspect),
            core.makeImageBarrier2(self.accum.image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true }, color_aspect),
            core.makeImageBarrier2(self.reveal.image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true }, color_aspect),
            core.makeImageBarrier2(self.volume_weight.image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true }, color_aspect),
            core.makeImageBarrier2(
                output_image,
                swapchain_old_layout,
                .color_attachment_optimal,
                switch (swapchain_old_layout) {
                    .undefined => .{ .top_of_pipe_bit = true },
                    .present_src_khr => .{ .color_attachment_output_bit = true },
                    else => .{ .all_commands_bit = true },
                },
                switch (swapchain_old_layout) {
                    .undefined => .{},
                    .present_src_khr => .{},
                    else => .{ .memory_write_bit = true },
                },
                .{ .color_attachment_output_bit = true },
                .{ .color_attachment_write_bit = true, .color_attachment_read_bit = true },
                color_aspect,
            ),
        };
        core.pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, &pre_comp_barriers);

        const swapchain_attachment = core.renderingAttachmentColor(output_view, .dont_care, .{ 0.0, 0.0, 0.0, 0.0 });
        self.dev.cmdBeginRendering(cmd_buffer, &core.renderingInfo(extent, &.{swapchain_attachment}, null));

        self.dev.cmdBindPipeline(cmd_buffer, .graphics, self.composition_pipeline);
        core.setViewportAndScissor(self.dev, cmd_buffer, extent);

        self.dev.cmdPushConstants(cmd_buffer, self.composition_layout, .{ .fragment_bit = true }, 0, @sizeOf(u32), &scatter_enabled);

        const oit_desc_set: vk.DescriptorSet = self.descriptor_sets_per_frame[current_frame];
        self.dev.cmdBindDescriptorSets(cmd_buffer, .graphics, self.composition_layout, 0, (&oit_desc_set)[0..1], null);
        self.dev.cmdDraw(cmd_buffer, 3, 1, 0, 0);

        self.dev.cmdEndRendering(cmd_buffer);
        core.pipelineBarrier(cmd_buffer, self.dev, vk.ImageMemoryBarrier2, (&core.makeImageBarrier2(output_image, .color_attachment_optimal, .present_src_khr, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true }, .{}, color_aspect))[0..1]);

        if (swapchain_layout_ptr) |ptr| ptr.* = .present_src_khr;
    }
};
