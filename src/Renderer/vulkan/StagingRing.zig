const std = @import("std");
const vk = @import("vulkan");

const Slot = struct {
    offset: vk.DeviceSize,
    timeline_value: u64,
};

pub const StagingRing = struct {
    allocator: std.mem.Allocator,

    mapping: []u8,
    buffer: vk.Buffer,
    buffer_offset: vk.DeviceSize,
    capacity: vk.DeviceSize,

    head: vk.DeviceSize,
    entries: std.ArrayList(Slot),
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, cpu_to_gpu_allocator: std.mem.Allocator, max_face_bytes: vk.DeviceSize) !StagingRing {
        const capacity = max_face_bytes * 64;
        const mapping = try cpu_to_gpu_allocator.alignedAlloc(u8, .fromByteUnits(256), capacity);
        errdefer cpu_to_gpu_allocator.free(mapping);

        return StagingRing{
            .allocator = allocator,
            .mapping = mapping,
            .buffer = .null_handle,
            .buffer_offset = 0,
            .capacity = capacity,
            .head = 0,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *StagingRing, cpu_to_gpu_allocator: std.mem.Allocator) void {
        cpu_to_gpu_allocator.free(self.mapping);
        self.entries.deinit(self.allocator);
    }

    pub fn resolve(self: *StagingRing, buffer: vk.Buffer, buffer_offset: vk.DeviceSize) void {
        self.buffer = buffer;
        self.buffer_offset = buffer_offset;
    }

    pub fn alloc(self: *StagingRing, io: std.Io, size: vk.DeviceSize) ?[]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const alignment: vk.DeviceSize = 256;
        const aligned = (size + alignment - 1) / alignment * alignment;

        if (aligned > self.capacity)
            return null;

        if (self.head + aligned > self.capacity) {
            if (self.entries.items.len > 0)
                return null;
            self.head = 0;
        }

        const offset = self.head;
        self.entries.append(self.allocator, .{ .offset = offset, .timeline_value = std.math.maxInt(u64) }) catch return null;
        self.head += aligned;

        return self.mapping[offset..][0..@intCast(size)];
    }

    fn findSlot(self: *StagingRing, slice: []const u8) ?usize {
        const off = @intFromPtr(slice.ptr) - @intFromPtr(self.mapping.ptr);
        for (self.entries.items, 0..) |e, i| {
            if (e.offset == off) return i;
        }
        return null;
    }

    pub fn bind(self: *StagingRing, io: std.Io, slice: []const u8, timeline_value: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.findSlot(slice)) |i| {
            self.entries.items[i].timeline_value = timeline_value;
        }
    }

    pub fn retire(self: *StagingRing, io: std.Io, current_transfer_val: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (self.entries.items.len > 0) {
            const e = self.entries.items[0];
            if (e.timeline_value != 0 and current_transfer_val < e.timeline_value) break;
            _ = self.entries.swapRemove(0);
        }

        if (self.entries.items.len == 0)
            self.head = 0;
    }

    pub fn cancel(self: *StagingRing, io: std.Io, slice: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.findSlot(slice)) |i| {
            _ = self.entries.swapRemove(i);
        }
    }
};
