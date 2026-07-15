const std = @import("std");
const vk = @import("vulkan");

const log = std.log.scoped(.face_data_allocator);

const Region = struct {
    offset: vk.DeviceSize,
    length: vk.DeviceSize,
};

pub const GrowInfo = struct {
    old_slice: []u8,
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

    buffer_slice: []u8,
    buffer: vk.Buffer,
    buffer_offset: vk.DeviceSize,
    capacity: vk.DeviceSize,
    used: vk.DeviceSize,

    free_regions: std.ArrayList(Region),
    meta_allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,

    const init_align: std.mem.Alignment = .fromByteUnits(256);

    pub fn init(meta_allocator: std.mem.Allocator, gpu_allocator: std.mem.Allocator) !FaceDataAllocator {
        const initial_capacity: vk.DeviceSize = 64 * 1024 * 1024;
        const slice = try gpu_allocator.alignedAlloc(u8, init_align, initial_capacity);
        errdefer gpu_allocator.free(slice);

        return FaceDataAllocator{
            .buffer_slice = slice,
            .buffer = .null_handle,
            .buffer_offset = 0,
            .capacity = initial_capacity,
            .used = 0,
            .free_regions = std.ArrayList(Region).initCapacity(meta_allocator, 0) catch unreachable,
            .meta_allocator = meta_allocator,
        };
    }

    pub fn deinit(self: *FaceDataAllocator, gpu_allocator: std.mem.Allocator) void {
        self.free_regions.deinit(self.meta_allocator);
        gpu_allocator.free(self.buffer_slice);
    }

    pub fn resolve(self: *FaceDataAllocator, buffer: vk.Buffer, buffer_offset: vk.DeviceSize) void {
        self.buffer = buffer;
        self.buffer_offset = buffer_offset;
    }

    pub fn allocRegion(self: *FaceDataAllocator, io: std.Io, length: vk.DeviceSize) ?AllocResult {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const offset = if (self.used + length <= self.capacity)
            self.tryAllocRegion(length)
        else
            self.tryFindFreeRegion(length);

        return if (offset) |off| AllocResult{
            .offset = off,
            .buffer = self.buffer,
            .buffer_offset = self.buffer_offset,
        } else null;
    }

    fn tryFindFreeRegion(self: *FaceDataAllocator, length: vk.DeviceSize) ?vk.DeviceSize {
        for (self.free_regions.items, 0..) |region, i| {
            if (region.length < length) continue;

            const result = region.offset;
            if (region.length == length) {
                _ = self.free_regions.swapRemove(i);
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

    fn tryAllocRegion(self: *FaceDataAllocator, length: vk.DeviceSize) ?vk.DeviceSize {
        if (self.tryFindFreeRegion(length)) |offset| return offset;

        const offset = self.used;
        self.used += length;
        return offset;
    }

    pub fn freeRegion(self: *FaceDataAllocator, io: std.Io, offset: vk.DeviceSize, length: vk.DeviceSize) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const insertion_index = for (self.free_regions.items, 0..) |region, i| {
            if (region.offset > offset) break i;
        } else self.free_regions.items.len;

        self.free_regions.insert(self.meta_allocator, insertion_index, .{ .offset = offset, .length = length }) catch |err| {
            log.err("freeRegion: insert failed: {any}", .{err});
            return;
        };

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

    pub fn grow(self: *FaceDataAllocator, gpu_allocator: std.mem.Allocator) !GrowInfo {
        const new_capacity = self.capacity * 2;
        log.info("growing from {d} MB to {d} MB", .{
            self.capacity / (1024 * 1024),
            new_capacity / (1024 * 1024),
        });

        const new_slice = try gpu_allocator.alignedAlloc(u8, init_align, new_capacity);
        errdefer gpu_allocator.free(new_slice);

        const old_info: GrowInfo = .{
            .old_slice = self.buffer_slice,
            .old_buffer = self.buffer,
            .old_buffer_offset = self.buffer_offset,
            .old_used = self.used,
        };

        self.buffer_slice = new_slice;
        self.capacity = new_capacity;

        log.info("grew to {d} MB", .{self.capacity / (1024 * 1024)});

        return old_info;
    }
};
