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
        self.sampler = try core.createSampler(self.dev, &self.vk_ctx.vkalloc, .{});
        errdefer self.dev.destroySampler(self.sampler, &self.vk_ctx.vkalloc);
        return self;
    }

    pub fn deinit(self: *OitCompositor) void {
        self.destroyTransientResources();
        core.destroyIfValid(self.dev, &self.sampler, &self.vk_ctx.vkalloc);
    }

    fn destroyTransientResources(self: *OitCompositor) void {
        core.destroyIfValid(self.dev, &self.composition_pipeline, &self.vk_ctx.vkalloc);
        core.destroyIfValid(self.dev, &self.composition_layout, &self.vk_ctx.vkalloc);
        core.destroyIfValid(self.dev, &self.descriptor_set_layout, &self.vk_ctx.vkalloc);
        core.destroyFrameDescriptorResources(self.dev, self.allocator, &self.vk_ctx.vkalloc, &self.descriptor_pool, &self.descriptor_sets_per_frame);
        core.destroyRenderTarget(self.dev, &self.accum, &self.vk_ctx.vkalloc);
        core.destroyRenderTarget(self.dev, &self.reveal, &self.vk_ctx.vkalloc);
        core.destroyRenderTarget(self.dev, &self.volume_weight, &self.vk_ctx.vkalloc);
    }

    /// Recreates everything except the sampler: composition pipeline/layout, descriptor
    /// resources, and the three OIT targets. Called on init and on swapchain recreation.
    pub fn recreate(self: *OitCompositor, extent: vk.Extent2D, color_view: vk.ImageView) !void {
        self.destroyTransientResources();

        const oit_usage: vk.ImageUsageFlags = .{ .color_attachment_bit = true, .sampled_bit = true };
        const oit_aspect: vk.ImageAspectFlags = .{ .color_bit = true };
        const oit_targets: [3]*RenderTarget = .{ &self.accum, &self.reveal, &self.volume_weight };
        const oit_formats: [3]vk.Format = .{ .r16g16b16a16_sfloat, .r16g16b16a16_sfloat, .r16_sfloat };
        errdefer self.destroyTransientResources();
        for (oit_targets, oit_formats) |target, format| {
            target.* = try core.createImageWithMemory(self.dev, self.vk_ctx.mem_props, &self.vk_ctx.vkalloc, extent, format, oit_usage, oit_aspect);
        }

        if (self.descriptor_set_layout == .null_handle) {
            const bindings: [4]vk.DescriptorSetLayoutBinding = .{
                .{ .binding = 0, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
                .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
                .{ .binding = 2, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
                .{ .binding = 3, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
            };
            self.descriptor_set_layout = try core.createDescriptorSetLayout(self.dev, &self.vk_ctx.vkalloc, .{}, &bindings);
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

            self.composition_pipeline = try core.buildGraphicsPipeline(self.dev, &self.vk_ctx.vkalloc, self.vk_ctx.pipeline_creation_feedback, vert_module, frag_module, &.{self.vk_ctx.swapchain_format}, .undefined, null, &.{core.opaqueBlendAttachment()}, self.composition_layout, core.emptyVertexInput());
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
            for (&writes, &image_infos, 0..) |*write, *info, binding| write.* = core.imageWriteDescriptorSet(desc_set, @intCast(binding), info);
            self.dev.updateDescriptorSets(&writes, null);
        }
    }

    /// Inputs for one fullscreen composition into the swapchain image.
    pub const CompositionContext = struct {
        cmd_buffer: vk.CommandBuffer,
        extent: vk.Extent2D,
        output_image: vk.Image,
        output_view: vk.ImageView,
        frame_idx: u32,
        /// Scatter term from the transparent pass is skipped when the camera sits
        /// inside a transparent volume.
        scatter_enabled: u32,
        swapchain_old_layout: vk.ImageLayout,
        /// Written with the final present layout when non-null.
        swapchain_layout_ptr: ?*vk.ImageLayout,
    };

    pub fn recordCompositionPass(self: *OitCompositor, ctx: CompositionContext, color_image: vk.Image) void {
        const zone = tracy.Zone.begin(.{ .src = @src(), .name = "recordCompositionPass" });
        defer zone.end();
        const gpu_zone = self.vk_ctx.gpu_profiler.beginZone(ctx.cmd_buffer, ctx.frame_idx, .{ .src = @src(), .name = "oit_composition" });
        defer gpu_zone.end();
        const color_aspect: vk.ImageAspectFlags = .{ .color_bit = true };

        var pre_comp_barriers: [5]vk.ImageMemoryBarrier2 = undefined;
        const read_images: [4]vk.Image = .{ color_image, self.accum.image, self.reveal.image, self.volume_weight.image };
        for (pre_comp_barriers[0..4], read_images) |*barrier, image| {
            barrier.* = core.makeImageBarrier2(image, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .fragment_shader_bit = true }, .{ .shader_read_bit = true }, color_aspect);
        }
        const src_stage, const src_access = switch (ctx.swapchain_old_layout) {
            .undefined => .{ @as(vk.PipelineStageFlags2, .{ .top_of_pipe_bit = true }), @as(vk.AccessFlags2, .{}) },
            .present_src_khr => .{ @as(vk.PipelineStageFlags2, .{ .color_attachment_output_bit = true }), @as(vk.AccessFlags2, .{}) },
            else => .{ @as(vk.PipelineStageFlags2, .{ .all_commands_bit = true }), @as(vk.AccessFlags2, .{ .memory_write_bit = true }) },
        };
        pre_comp_barriers[4] = core.makeImageBarrier2(
            ctx.output_image,
            ctx.swapchain_old_layout,
            .color_attachment_optimal,
            src_stage,
            src_access,
            .{ .color_attachment_output_bit = true },
            .{ .color_attachment_write_bit = true, .color_attachment_read_bit = true },
            color_aspect,
        );
        core.pipelineBarrier(ctx.cmd_buffer, self.dev, vk.ImageMemoryBarrier2, &pre_comp_barriers);

        const swapchain_attachment = core.renderingAttachmentColor(ctx.output_view, .dont_care, .{ 0.0, 0.0, 0.0, 0.0 });
        self.dev.cmdBeginRendering(ctx.cmd_buffer, &core.renderingInfo(ctx.extent, &.{swapchain_attachment}, null));

        self.dev.cmdBindPipeline(ctx.cmd_buffer, .graphics, self.composition_pipeline);
        core.setViewportAndScissor(self.dev, ctx.cmd_buffer, ctx.extent);

        self.dev.cmdPushConstants(ctx.cmd_buffer, self.composition_layout, .{ .fragment_bit = true }, 0, @sizeOf(u32), &ctx.scatter_enabled);

        const oit_desc_set: vk.DescriptorSet = self.descriptor_sets_per_frame[ctx.frame_idx];
        self.dev.cmdBindDescriptorSets(ctx.cmd_buffer, .graphics, self.composition_layout, 0, (&oit_desc_set)[0..1], null);
        self.dev.cmdDraw(ctx.cmd_buffer, core.fullscreen_triangle_vertices, 1, 0, 0);

        self.dev.cmdEndRendering(ctx.cmd_buffer);
        core.pipelineBarrier(ctx.cmd_buffer, self.dev, vk.ImageMemoryBarrier2, (&core.makeImageBarrier2(ctx.output_image, .color_attachment_optimal, .present_src_khr, .{ .color_attachment_output_bit = true }, .{ .color_attachment_write_bit = true }, .{ .color_attachment_output_bit = true }, .{}, color_aspect))[0..1]);

        if (ctx.swapchain_layout_ptr) |ptr| ptr.* = .present_src_khr;
    }
};
