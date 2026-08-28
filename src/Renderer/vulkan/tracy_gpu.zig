const std = @import("std");
const tracy = @import("tracy");
const vk = @import("vulkan");

const DeviceProxy = vk.DeviceProxy;

const max_frames_in_flight: u32 = 2;
const queries_per_frame: u32 = 2048;
const bootstrap_query: u32 = 0;
const query_pool_count: u32 = bootstrap_query + max_frames_in_flight * queries_per_frame;

const timestamp_stage: vk.PipelineStageFlags2 = .{ .all_commands_bit = true };

const FrameState = struct {
    query_count: u32 = 0,
    submitted: bool = false,
};

/// Records Vulkan timestamp queries and forwards their completed values to Tracy.
///
/// Each in-flight frame owns a fixed query range. The range is reset only after the
/// graphics timeline has made that frame reusable, so recording never reuses queries
/// still referenced by the GPU.
pub const GpuProfiler = struct {
    dev: DeviceProxy = undefined,
    query_pool: vk.QueryPool = .null_handle,
    vkalloc: *const vk.AllocationCallbacks = undefined,
    queue: tracy.GpuQueue = undefined,
    frames: [max_frames_in_flight]FrameState = .{ .{}, .{} },
    enabled: bool = false,

    pub fn init(
        dev: DeviceProxy,
        queue: vk.Queue,
        command_pool: vk.CommandPool,
        vkalloc: *const vk.AllocationCallbacks,
        timestamp_period: f32,
    ) !GpuProfiler {
        var self: GpuProfiler = .{
            .dev = dev,
            .vkalloc = vkalloc,
        };
        if (!tracy.enabled) return self;

        if (timestamp_period <= 0.0) return error.TracyGpuTimestampsUnavailable;

        self.query_pool = try dev.createQueryPool(&.{
            .query_type = .timestamp,
            .query_count = query_pool_count,
        }, vkalloc);
        errdefer dev.destroyQueryPool(self.query_pool, vkalloc);

        const initial_gpu_time = try bootstrapTimestamp(dev, queue, command_pool, self.query_pool, vkalloc);
        self.queue = tracy.GpuQueue.init(.{
            .gpu_time = initial_gpu_time,
            .period = timestamp_period,
            .context = 0,
            .type = .vulkan,
            .name = "Vulkan graphics",
        });
        self.enabled = true;
        return self;
    }

    pub fn deinit(self: *GpuProfiler) void {
        if (self.query_pool != .null_handle) {
            self.dev.destroyQueryPool(self.query_pool, self.vkalloc);
            self.query_pool = .null_handle;
        }
    }

    /// Resolves the previous use of a frame slot and makes its query range available
    /// for the command buffer that will be recorded into that slot.
    pub fn prepareFrame(self: *GpuProfiler, frame_index: u32) void {
        if (!self.enabled) return;
        std.debug.assert(frame_index < max_frames_in_flight);

        const state = &self.frames[frame_index];
        if (state.submitted and state.query_count > 0) self.resolveFrame(frame_index, state.query_count);

        state.* = .{};
    }

    /// Records the reset for a frame slot after its command buffer has begun. Host query
    /// reset is not enabled by the device, so every reused range is reset on the GPU.
    pub fn resetFrame(self: *GpuProfiler, cmd_buffer: vk.CommandBuffer, frame_index: u32) void {
        if (!self.enabled) return;
        std.debug.assert(frame_index < max_frames_in_flight);
        self.dev.cmdResetQueryPool(cmd_buffer, self.query_pool, queryOffset(frame_index), queries_per_frame);
    }

    /// Commits the query records for a frame only after its graphics submission succeeds.
    pub fn markSubmitted(self: *GpuProfiler, frame_index: u32) void {
        if (!self.enabled) return;
        std.debug.assert(frame_index < max_frames_in_flight);
        self.frames[frame_index].submitted = self.frames[frame_index].query_count > 0;
    }

    pub fn beginZone(
        self: *GpuProfiler,
        cmd_buffer: vk.CommandBuffer,
        frame_index: u32,
        comptime location_options: tracy.SourceLocation.InitOptions,
    ) Zone {
        if (!self.enabled) return .{};
        std.debug.assert(frame_index < max_frames_in_flight);

        const state = &self.frames[frame_index];
        std.debug.assert(state.query_count + 2 <= queries_per_frame);
        const query_id = queryOffset(frame_index) + state.query_count;
        state.query_count += 2;

        const location = tracy.SourceLocation.init(location_options);
        self.dev.cmdWriteTimestamp2(cmd_buffer, timestamp_stage, self.query_pool, query_id);
        self.queue.beginZone(.{ .loc = location, .query_id = @intCast(query_id) });

        return .{
            .profiler = self,
            .cmd_buffer = cmd_buffer,
            .query_id = query_id + 1,
            .active = true,
        };
    }

    fn endZone(self: *GpuProfiler, cmd_buffer: vk.CommandBuffer, query_id: u32) void {
        self.dev.cmdWriteTimestamp2(cmd_buffer, timestamp_stage, self.query_pool, query_id);
        self.queue.endZone(@intCast(query_id));
    }

    fn resolveFrame(self: *GpuProfiler, frame_index: u32, query_count: u32) void {
        const offset = queryOffset(frame_index);
        var timestamps: [queries_per_frame]u64 = undefined;
        const result = self.dev.getQueryPoolResults(
            self.query_pool,
            offset,
            query_count,
            @sizeOf(u64) * query_count,
            &timestamps,
            @sizeOf(u64),
            .{ .@"64_bit" = true },
        ) catch |err| {
            std.log.warn("Tracy GPU timestamp read failed: {s}", .{@errorName(err)});
            return;
        };
        if (result != .success) {
            std.log.warn("Tracy GPU timestamp results were not ready: {s}", .{@tagName(result)});
            return;
        }

        for (timestamps[0..query_count], 0..) |timestamp, i| {
            self.queue.emitTime(.{
                .query_id = @intCast(offset + i),
                .gpu_time = timestamp,
            });
        }
    }

    fn queryOffset(frame_index: u32) u32 {
        return bootstrap_query + frame_index * queries_per_frame;
    }

    fn bootstrapTimestamp(
        dev: DeviceProxy,
        queue: vk.Queue,
        command_pool: vk.CommandPool,
        query_pool: vk.QueryPool,
        vkalloc: *const vk.AllocationCallbacks,
    ) !u64 {
        var command_buffer: vk.CommandBuffer = undefined;
        try dev.allocateCommandBuffers(&.{
            .level = .primary,
            .command_pool = command_pool,
            .command_buffer_count = 1,
        }, (&command_buffer)[0..1]);
        defer dev.freeCommandBuffers(command_pool, (&command_buffer)[0..1]);

        try dev.beginCommandBuffer(command_buffer, &.{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        });
        dev.cmdResetQueryPool(command_buffer, query_pool, 0, query_pool_count);
        dev.cmdWriteTimestamp2(command_buffer, .{ .top_of_pipe_bit = true }, query_pool, bootstrap_query);
        try dev.endCommandBuffer(command_buffer);

        const fence = try dev.createFence(&.{}, vkalloc);
        defer dev.destroyFence(fence, vkalloc);

        const submit_info: vk.SubmitInfo2 = .{
            .flags = .{},
            .wait_semaphore_info_count = 0,
            .p_wait_semaphore_infos = null,
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = (&vk.CommandBufferSubmitInfo{
                .command_buffer = command_buffer,
                .device_mask = 0,
            })[0..1],
            .signal_semaphore_info_count = 0,
            .p_signal_semaphore_infos = null,
        };
        try dev.queueSubmit2(queue, (&submit_info)[0..1], fence);
        _ = try dev.waitForFences((&fence)[0..1], .true, std.math.maxInt(u64));

        var timestamp: u64 = undefined;
        const result = try dev.getQueryPoolResults(
            query_pool,
            bootstrap_query,
            1,
            @sizeOf(u64),
            &timestamp,
            @sizeOf(u64),
            .{ .@"64_bit" = true, .wait_bit = true },
        );
        if (result != .success) return error.TracyGpuTimestampUnavailable;
        return timestamp;
    }

    pub const Zone = struct {
        profiler: ?*GpuProfiler = null,
        cmd_buffer: vk.CommandBuffer = .null_handle,
        query_id: u32 = 0,
        active: bool = false,

        pub fn end(self: @This()) void {
            if (!self.active) return;
            self.profiler.?.endZone(self.cmd_buffer, self.query_id);
        }
    };
};
