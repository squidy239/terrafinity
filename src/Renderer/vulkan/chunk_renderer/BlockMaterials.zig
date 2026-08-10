const std = @import("std");
const vk = @import("vulkan");

const DeviceProxy = vk.DeviceProxy;

const VulkanContext = @import("../../../VulkanContext.zig").VulkanContext;
const utils = @import("../../../libs/utils.zig");
const World = @import("../../../world/World.zig");
const core = @import("../core.zig");
const gpu = @import("../gpu.zig");
const textures = @import("textures.zig");

const BlockMaterial = extern struct {
    volume_color: [3]f32 align(4) = .{ 1.0, 1.0, 1.0 },
    density: f32 = 0.0,
    fresnel_power: f32 = 5.0,
    min_opacity: f32 = 0.15,
};

const BlockMaterialsZon = blk: {
    const vis_count = World.Block.visible_count;
    const names = textures.visible_block_names;
    const types: [vis_count]type = .{BlockMaterial} ** vis_count;
    const default_mat: BlockMaterial = .{};
    var attrs: [vis_count]std.builtin.Type.StructField.Attributes = undefined;
    for (&attrs) |*a| a.* = .{ .default_value_ptr = @as(?*const anyopaque, @ptrCast(&default_mat)) };
    break :blk @Struct(.auto, null, &names, &types, &attrs);
};

pub const MaterialGpu = extern struct {
    density: f32,
    fresnel_power: f32,
    min_opacity: f32,
    // align(16) matches GLSL std430 vec3 alignment (16-byte boundary).
    // Without it, volume_color would sit at offset 12, but GLSL expects
    // it at offset 16, causing every block's material data to read garbage.
    volume_color: [3]f32 align(16),
};

/// Default material values (matching BlockMaterial's field defaults) used to fill a new
/// material buffer before the pack's materials.zon overrides individual blocks.
const default_material_gpu: MaterialGpu = .{ .density = 0.0, .fresnel_power = 5.0, .min_opacity = 0.15, .volume_color = .{ 1.0, 1.0, 1.0 } };

comptime {
    if (@sizeOf(MaterialGpu) != 32) @compileError("MaterialGpu size mismatch with GLSL std430 layout (expected 32, got " ++ std.fmt.comptimePrint("{}", .{@sizeOf(MaterialGpu)}) ++ ")");
}

/// GPU-side block material constants loaded from the selected resource pack,
/// exposed to the transparent fragment shader as a storage buffer descriptor.
pub const BlockMaterials = struct {
    dev: DeviceProxy,
    vk_ctx: *VulkanContext,
    memory: *gpu.GpuMemory,

    mapped: []MaterialGpu = &.{},
    descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    descriptor_pool: vk.DescriptorPool = .null_handle,
    descriptor_set: vk.DescriptorSet = .null_handle,

    pub fn load(self: *BlockMaterials, io: std.Io, allocator: std.mem.Allocator, selected_pack: []const u8) !void {
        const pack = try textures.openPackBlocksDir(io, allocator, selected_pack);
        defer allocator.free(pack.path);
        defer pack.dir.close(io);

        if (pack.is_default) {
            const default_materials_zon = @import("materials").default;
            if (pack.dir.openFile(io, "materials.zon", .{})) |f| {
                f.close(io);
            } else |err| switch (err) {
                error.FileNotFound => try pack.dir.writeFile(io, .{ .data = default_materials_zon, .sub_path = "materials.zon" }),
                else => |e| return e,
            }
        }

        const indexer = std.enums.EnumIndexer(World.Block);
        const count = indexer.count;
        const slice = try self.memory.cpuToGpu().alloc(MaterialGpu, count);
        errdefer self.memory.cpuToGpu().free(slice);
        @memset(slice, default_material_gpu);

        var zon_file: ?std.Io.File = null;
        if (pack.dir.openFile(io, "materials.zon", .{})) |f| {
            zon_file = f;
        } else |err| switch (err) {
            error.FileNotFound => std.log.warn("No materials.zon found in pack, using defaults for all blocks", .{}),
            else => |e| return e,
        }
        defer if (zon_file) |f| f.close(io);

        if (zon_file) |f| {
            var temp_arena = std.heap.ArenaAllocator.init(allocator);
            defer temp_arena.deinit();
            const parsed = try utils.loadZon(BlockMaterialsZon, io, f, temp_arena.allocator(), allocator);

            inline for (std.meta.fields(World.Block)) |fld| {
                if (!@field(World.Block, fld.name).isVisible()) continue;
                const mat = &@field(parsed, fld.name);
                const idx = indexer.indexOf(@field(World.Block, fld.name));
                slice[idx] = .{
                    .density = mat.density,
                    .fresnel_power = mat.fresnel_power,
                    .min_opacity = mat.min_opacity,
                    .volume_color = mat.volume_color,
                };
            }
        }

        self.mapped = slice;
        errdefer self.mapped = &.{};
        try self.createDescriptorResources();
    }

    pub fn deinit(self: *BlockMaterials) void {
        core.destroyIfValid(self.dev, &self.descriptor_pool, &self.vk_ctx.vkalloc);
        if (self.mapped.len > 0) self.memory.cpuToGpu().free(self.mapped);
        core.destroyIfValid(self.dev, &self.descriptor_set_layout, &self.vk_ctx.vkalloc);
    }

    fn createDescriptorResources(self: *BlockMaterials) !void {
        if (self.descriptor_set_layout == .null_handle) {
            const binding = vk.DescriptorSetLayoutBinding{
                .binding = 0,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .fragment_bit = true },
                .p_immutable_samplers = null,
            };
            self.descriptor_set_layout = try core.createDescriptorSetLayout(self.dev, &self.vk_ctx.vkalloc, .{}, (&binding)[0..1]);
        }

        if (self.descriptor_pool == .null_handle) {
            const pool_size = vk.DescriptorPoolSize{ .type = .storage_buffer, .descriptor_count = 1 };
            self.descriptor_pool = try self.dev.createDescriptorPool(&.{ .flags = .{}, .max_sets = 1, .pool_size_count = 1, .p_pool_sizes = (&pool_size)[0..1].ptr }, &self.vk_ctx.vkalloc);
        }

        if (self.descriptor_set == .null_handle) {
            try self.dev.allocateDescriptorSets(&.{
                .descriptor_pool = self.descriptor_pool,
                .descriptor_set_count = 1,
                .p_set_layouts = (&self.descriptor_set_layout)[0..1],
            }, (&self.descriptor_set)[0..1]);
        }

        const info = self.memory.backing_allocator.getBufferAndOffset(.cpu_to_gpu, self.mapped.ptr);
        const buf_info: vk.DescriptorBufferInfo = .{
            .buffer = info.buffer,
            .offset = info.offset,
            .range = self.mapped.len * @sizeOf(MaterialGpu),
        };
        self.dev.updateDescriptorSets((&core.bufferWriteDescriptorSet(self.descriptor_set, 0, .storage_buffer, &buf_info))[0..1], null);
    }
};
