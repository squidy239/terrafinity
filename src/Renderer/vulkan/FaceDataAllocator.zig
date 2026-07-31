const std = @import("std");
const vk = @import("vulkan");

const log = std.log.scoped(.face_data_allocator);

const buf_align: std.mem.Alignment = .fromByteUnits(256);

const Region = struct {
    offset: vk.DeviceSize,
    length: vk.DeviceSize,
};

pub const GrowInfo = struct {
    old_slice: []align(buf_align.toByteUnits()) u8,
    old_buffer: vk.Buffer,
    old_buffer_offset: vk.DeviceSize,
    old_used: vk.DeviceSize,
};

pub const FaceDataAllocator = struct {
    pub const AllocResult = struct {
        offset: vk.DeviceSize,
        buffer: vk.Buffer,
        buffer_offset: vk.DeviceSize,
    };

    buffer_slice: []align(buf_align.toByteUnits()) u8,
    // Atomic so the render thread can size barriers without taking the allocator mutex.
    buffer: std.atomic.Value(vk.Buffer) = .init(.null_handle),
    buffer_offset: std.atomic.Value(vk.DeviceSize) = .init(0),
    used: std.atomic.Value(vk.DeviceSize) = .init(0),

    free_regions: std.ArrayList(Region),
    free_list_allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,

    pub fn init(free_list_allocator: std.mem.Allocator, gpu_allocator: std.mem.Allocator, capacity_bytes: vk.DeviceSize) !FaceDataAllocator {
        const slice = try gpu_allocator.alignedAlloc(u8, buf_align, capacity_bytes);

        return FaceDataAllocator{
            .buffer_slice = slice,
            .free_regions = .empty,
            .free_list_allocator = free_list_allocator,
        };
    }

    pub fn deinit(self: *FaceDataAllocator, gpu_allocator: std.mem.Allocator) void {
        self.free_regions.deinit(self.free_list_allocator);
        gpu_allocator.free(self.buffer_slice);
    }

    pub fn resolve(self: *FaceDataAllocator, buffer: vk.Buffer, buffer_offset: vk.DeviceSize) void {
        std.debug.assert(buffer != .null_handle);
        self.buffer.store(buffer, .release);
        self.buffer_offset.store(buffer_offset, .release);
    }

    pub fn allocRegion(self: *FaceDataAllocator, io: std.Io, length: vk.DeviceSize) ?AllocResult {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.buffer.load(.monotonic) == .null_handle) return null;

        if (self.findFreeRegion(length)) |offset| {
            return .{
                .offset = offset,
                .buffer = self.buffer.load(.monotonic),
                .buffer_offset = self.buffer_offset.load(.monotonic),
            };
        }

        const current_used = self.used.load(.monotonic);
        const new_used, const overflow = @addWithOverflow(current_used, length);
        if (overflow == 0 and new_used <= self.buffer_slice.len) {
            const offset = current_used;
            self.used.store(new_used, .monotonic);
            return .{
                .offset = offset,
                .buffer = self.buffer.load(.monotonic),
                .buffer_offset = self.buffer_offset.load(.monotonic),
            };
        }

        return null;
    }

    fn findFreeRegion(self: *FaceDataAllocator, length: vk.DeviceSize) ?vk.DeviceSize {
        for (self.free_regions.items, 0..) |region, i| {
            if (region.length < length) continue;

            const result = region.offset;
            if (region.length == length) {
                _ = self.free_regions.orderedRemove(i);
            } else {
                self.free_regions.items[i] = .{
                    .offset = region.offset + length,
                    .length = region.length - length,
                };
            }
            return result;
        }
        return null;
    }

    pub fn freeRegion(self: *FaceDataAllocator, io: std.Io, offset: vk.DeviceSize, length: vk.DeviceSize) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const insertion_index = for (self.free_regions.items, 0..) |region, i| {
            if (offset < region.offset + region.length and region.offset < offset + length) {
                std.debug.panic("FaceDataAllocator.freeRegion: overlapping free of [{d}, {d})", .{ offset, offset + length });
            }
            if (region.offset > offset) break i;
        } else self.free_regions.items.len;

        self.free_regions.insert(self.free_list_allocator, insertion_index, .{ .offset = offset, .length = length }) catch @panic("FaceDataAllocator.freeRegion: insert OOM");

        var i = insertion_index;
        while (i > 0) {
            if (self.free_regions.items[i - 1].offset + self.free_regions.items[i - 1].length == self.free_regions.items[i].offset) {
                self.free_regions.items[i - 1].length += self.free_regions.items[i].length;
                _ = self.free_regions.orderedRemove(i);
                i -= 1;
            } else break;
        }

        while (i + 1 < self.free_regions.items.len) {
            if (self.free_regions.items[i].offset + self.free_regions.items[i].length == self.free_regions.items[i + 1].offset) {
                self.free_regions.items[i].length += self.free_regions.items[i + 1].length;
                _ = self.free_regions.orderedRemove(i + 1);
            } else break;
        }
    }

    pub fn grow(self: *FaceDataAllocator, io: std.Io, gpu_allocator: std.mem.Allocator) !GrowInfo {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const new_capacity = std.math.mul(vk.DeviceSize, @as(vk.DeviceSize, @intCast(self.buffer_slice.len)), 2) catch return error.OutOfMemory;
        log.info("growing from {d} MB to {d} MB", .{
            self.buffer_slice.len / (1024 * 1024),
            new_capacity / (1024 * 1024),
        });

        const new_slice = try gpu_allocator.alignedAlloc(u8, buf_align, new_capacity);

        const old_info: GrowInfo = .{
            .old_slice = self.buffer_slice,
            .old_buffer = self.buffer.load(.monotonic),
            .old_buffer_offset = self.buffer_offset.load(.monotonic),
            .old_used = self.used.load(.monotonic),
        };

        self.buffer_slice = new_slice;
        // Freed regions stay reusable: the caller copies [0, used) into the new buffer,
        // so their offsets remain valid. buffer is nulled until resolve() pairs it
        // with the new handle — allocRegion returns null in the interim.
        self.buffer.store(.null_handle, .release);
        self.buffer_offset.store(0, .release);

        log.info("grew to {d} MB", .{self.buffer_slice.len / (1024 * 1024)});

        return old_info;
    }
};

fn faceDataAllocInitDeinit(alloc: std.mem.Allocator) !void {
    var allocator = try FaceDataAllocator.init(alloc, alloc, 1024 * 1024);
    allocator.deinit(alloc);
}

test "FaceDataAllocator checkAllAllocationFailures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, faceDataAllocInitDeinit, .{});
}
