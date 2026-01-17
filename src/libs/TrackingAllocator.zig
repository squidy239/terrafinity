const std = @import("std");
const Allocator = std.mem.Allocator;

///an allocator that tracks used memory. it may not be fully sequencialy consistent with multithreading due to unordered atomics, but is thread safe
//returns OOM if the memory limit is reached
const TrackingAllocator = @This();
memory_limit: std.atomic.Value(usize),
used_memory: std.atomic.Value(usize),
backing_allocator: std.mem.Allocator,

fn alloc(selfptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *TrackingAllocator = @ptrCast(@alignCast(selfptr));
    if (self.used_memory.load(.unordered) + len > self.memory_limit.load(.unordered)) return null;
    const mem = self.backing_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
    _ = self.used_memory.fetchAdd(len, .monotonic);
    return mem;
}

fn free(selfptr: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *TrackingAllocator = @ptrCast(@alignCast(selfptr));
    self.backing_allocator.rawFree(mem, alignment, ret_addr);
    _ = self.used_memory.fetchSub(mem.len, .monotonic);
}

fn resize(selfptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
    const self: *TrackingAllocator = @ptrCast(@alignCast(selfptr));
    if (new_len > memory.len) if (self.used_memory.load(.unordered) + new_len > self.memory_limit.load(.unordered)) return false;
    const resized = self.backing_allocator.rawResize(memory, alignment, new_len, ra);
    if (resized) {
        if (new_len > memory.len) {
            _ = self.used_memory.fetchAdd(new_len - memory.len, .monotonic);
        } else {
            _ = self.used_memory.fetchSub(memory.len - new_len, .monotonic);
        }
    }
    return resized;
}

fn remap(selfptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    const self: *TrackingAllocator = @ptrCast(@alignCast(selfptr));
    if (new_len > memory.len) if (self.used_memory.load(.unordered) + new_len > self.memory_limit.load(.unordered)) return null;
    const resized = self.backing_allocator.rawRemap(memory, alignment, new_len, ra) orelse return null;
    if (new_len > memory.len) {
        _ = self.used_memory.fetchAdd(new_len - memory.len, .monotonic);
    } else {
        _ = self.used_memory.fetchSub(memory.len - new_len, .monotonic);
    }

    return resized;
}

pub fn init(allocator: Allocator, limit: usize) TrackingAllocator {
    return TrackingAllocator{
        .backing_allocator = allocator,
        .memory_limit = std.atomic.Value(usize).init(limit),
        .used_memory = std.atomic.Value(usize).init(0),
    };
}

pub fn deinit(self: *TrackingAllocator) void {
    self.backing_allocator.deinit();
}

pub fn getUsedMemory(self: *TrackingAllocator) usize {
    return self.used_memory.load(.unordered);
}

pub fn getMemoryLimit(self: *TrackingAllocator) usize {
    return self.memory_limit.load(.unordered);
}

pub fn setMemoryLimit(self: *TrackingAllocator, limit: usize) void {
    self.memory_limit.store(limit, .unordered);
}

pub fn get_allocator(self: *TrackingAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}
