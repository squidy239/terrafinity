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
    buffer: ?vk.Buffer,
    buffer_offset: vk.DeviceSize,
    used: vk.DeviceSize,

    free_regions: std.ArrayList(Region),
    free_list_allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,

    pub fn init(free_list_allocator: std.mem.Allocator, gpu_allocator: std.mem.Allocator, capacity_bytes: vk.DeviceSize) !FaceDataAllocator {
        const slice = try gpu_allocator.alignedAlloc(u8, buf_align, capacity_bytes);

        return FaceDataAllocator{
            .buffer_slice = slice,
            .buffer = null,
            .buffer_offset = 0,
            .used = 0,
            .free_regions = std.ArrayList(Region).initCapacity(free_list_allocator, 0) catch unreachable,
            .free_list_allocator = free_list_allocator,
        };
    }

    pub fn deinit(self: *FaceDataAllocator, gpu_allocator: std.mem.Allocator) void {
        self.free_regions.deinit(self.free_list_allocator);
        gpu_allocator.free(self.buffer_slice);
    }

    pub fn resolve(self: *FaceDataAllocator, buffer: vk.Buffer, buffer_offset: vk.DeviceSize) void {
        std.debug.assert(buffer != .null_handle);
        self.buffer = buffer;
        self.buffer_offset = buffer_offset;
    }

    pub fn allocRegion(self: *FaceDataAllocator, io: std.Io, length: vk.DeviceSize) ?AllocResult {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.buffer == null) return null;

        if (self.findFreeRegion(length)) |offset| {
            return .{
                .offset = offset,
                .buffer = self.buffer.?,
                .buffer_offset = self.buffer_offset,
            };
        }

        const new_used, const overflow = @addWithOverflow(self.used, length);
        if (overflow == 0 and new_used <= self.buffer_slice.len) {
            const offset = self.used;
            self.used = new_used;
            return .{
                .offset = offset,
                .buffer = self.buffer.?,
                .buffer_offset = self.buffer_offset,
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

        const new_capacity = self.buffer_slice.len * 2;
        log.info("growing from {d} MB to {d} MB", .{
            self.buffer_slice.len / (1024 * 1024),
            new_capacity / (1024 * 1024),
        });

        const new_slice = try gpu_allocator.alignedAlloc(u8, buf_align, new_capacity);

        const old_info: GrowInfo = .{
            .old_slice = self.buffer_slice,
            .old_buffer = self.buffer.?,
            .old_buffer_offset = self.buffer_offset,
            .old_used = self.used,
        };

        self.buffer_slice = new_slice;
        self.free_regions.clearRetainingCapacity();

        log.info("grew to {d} MB", .{self.buffer_slice.len / (1024 * 1024)});

        return old_info;
    }
};
