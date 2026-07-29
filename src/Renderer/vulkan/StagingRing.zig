const std = @import("std");
const vk = @import("vulkan");

pub const StagingRing = struct {
    const transfer_alignment: vk.DeviceSize = 256;

    allocator: std.mem.Allocator,

    mapping: []align(transfer_alignment) u8,
    buffer: ?vk.Buffer,

    head: vk.DeviceSize,
    entries: std.ArrayList(struct { ptr: [*]const u8, timeline_value: ?u64 }),
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, cpu_to_gpu_allocator: std.mem.Allocator, capacity_bytes: vk.DeviceSize) !StagingRing {
        const mapping = try cpu_to_gpu_allocator.alignedAlloc(u8, .fromByteUnits(transfer_alignment), capacity_bytes);
        errdefer cpu_to_gpu_allocator.free(mapping);

        return .{
            .allocator = allocator,
            .mapping = mapping,
            .buffer = null,
            .head = 0,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *StagingRing, cpu_to_gpu_allocator: std.mem.Allocator) void {
        cpu_to_gpu_allocator.free(self.mapping);
        self.entries.deinit(self.allocator);
    }

    pub fn resolve(self: *StagingRing, buffer: vk.Buffer) void {
        std.debug.assert(buffer != .null_handle);
        self.buffer = buffer;
    }

    pub fn alloc(self: *StagingRing, io: std.Io, size: vk.DeviceSize) ?[]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.buffer == null) return null;

        const aligned = std.mem.alignForward(vk.DeviceSize, size, transfer_alignment);
        if (aligned > self.mapping.len) return null;

        if (self.head + aligned > self.mapping.len) {
            if (self.entries.items.len > 0) return null;
            self.head = 0;
        }

        const slice = self.mapping[self.head..][0..@intCast(size)];
        self.entries.append(self.allocator, .{ .ptr = slice.ptr, .timeline_value = null }) catch return null;
        self.head += aligned;

        return slice;
    }

    pub fn bind(self: *StagingRing, io: std.Io, slice: []const u8, timeline_value: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        for (self.entries.items) |*e| {
            if (e.ptr == slice.ptr) {
                e.timeline_value = timeline_value;
                return;
            }
        }
    }

    pub fn retire(self: *StagingRing, io: std.Io, current_transfer_val: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (self.entries.items.len > 0) {
            const e = self.entries.items[0];
            const tv = e.timeline_value orelse break;
            if (current_transfer_val < tv) break;
            _ = self.entries.orderedRemove(0);
        }

        if (self.entries.items.len == 0) self.head = 0;
    }

    pub fn cancel(self: *StagingRing, io: std.Io, slice: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        for (self.entries.items, 0..) |e, i| {
            if (e.ptr == slice.ptr) {
                std.debug.assert(e.timeline_value == null);
                _ = self.entries.swapRemove(i);
                if (self.entries.items.len == 0) self.head = 0;
                return;
            }
        }
    }
};
