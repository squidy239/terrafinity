//! Allocates from the given buffer first, falling back to `fallback_allocator`.

const std = @import("std");
const heap = std.heap;
const testing = std.testing;

const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const BufferFirstAllocator = @This();

fallback_allocator: Allocator,
fixed_buffer_allocator: FixedBufferAllocator,

pub fn init(buffer: []u8, fallback_allocator: Allocator) BufferFirstAllocator {
    return .{
        .fallback_allocator = fallback_allocator,
        .fixed_buffer_allocator = .init(buffer),
    };
}

pub fn allocator(self: *BufferFirstAllocator) Allocator {
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

fn alloc(
    ctx: *anyopaque,
    len: usize,
    alignment: Alignment,
    ra: usize,
) ?[*]u8 {
    const self: *BufferFirstAllocator = @ptrCast(@alignCast(ctx));
    return FixedBufferAllocator.alloc(&self.fixed_buffer_allocator, len, alignment, ra) orelse
        return self.fallback_allocator.rawAlloc(len, alignment, ra);
}

fn resize(
    ctx: *anyopaque,
    buf: []u8,
    alignment: Alignment,
    new_len: usize,
    ra: usize,
) bool {
    const self: *BufferFirstAllocator = @ptrCast(@alignCast(ctx));
    if (self.fixed_buffer_allocator.ownsPtr(buf.ptr)) {
        return FixedBufferAllocator.resize(&self.fixed_buffer_allocator, buf, alignment, new_len, ra);
    } else {
        return self.fallback_allocator.rawResize(buf, alignment, new_len, ra);
    }
}

fn remap(
    context: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u8 {
    const self: *BufferFirstAllocator = @ptrCast(@alignCast(context));
    if (self.fixed_buffer_allocator.ownsPtr(memory.ptr)) {
        return FixedBufferAllocator.remap(&self.fixed_buffer_allocator, memory, alignment, new_len, return_address);
    } else {
        return self.fallback_allocator.rawRemap(memory, alignment, new_len, return_address);
    }
}

fn free(
    ctx: *anyopaque,
    buf: []u8,
    alignment: Alignment,
    ra: usize,
) void {
    const self: *BufferFirstAllocator = @ptrCast(@alignCast(ctx));
    if (self.fixed_buffer_allocator.ownsPtr(buf.ptr)) {
        return FixedBufferAllocator.free(&self.fixed_buffer_allocator, buf, alignment, ra);
    } else {
        return self.fallback_allocator.rawFree(buf, alignment, ra);
    }
}

test "BufferFirstAllocator" {
    // Buffer-first path below, standard allocator checks after.
    {
        var buffer: [10]u8 = undefined;
        var bfa_state: BufferFirstAllocator = .init(&buffer, std.testing.allocator);
        const bfa = bfa_state.allocator();

        const txt0 = "hellowrld";
        const buf0 = try bfa.create(@TypeOf(txt0.*));
        buf0.* = txt0.*;
        try testing.expect(bfa_state.fixed_buffer_allocator.ownsPtr(buf0.ptr));

        const txt1 = "test!";
        const buf1 = try bfa.create(@TypeOf(txt1.*));
        buf1.* = txt1.*;
        try testing.expect(!bfa_state.fixed_buffer_allocator.ownsPtr(buf1.ptr));

        try testing.expectEqualStrings(txt0, buf0);
        bfa.destroy(buf0);

        const txt2 = "qwertyqwerty";
        const buf2 = try bfa.create(@TypeOf(txt2.*));
        buf2.* = txt2.*;
        try testing.expect(!bfa_state.fixed_buffer_allocator.ownsPtr(buf2.ptr));

        const txt3 = "dvorak";
        const buf3 = try bfa.create(@TypeOf(txt3.*));
        buf3.* = txt3.*;
        try testing.expect(bfa_state.fixed_buffer_allocator.ownsPtr(buf3.ptr));

        const txt4 = "moretext";
        const buf4 = try bfa.create(@TypeOf(txt4.*));
        buf4.* = txt4.*;
        try testing.expect(!bfa_state.fixed_buffer_allocator.ownsPtr(buf4.ptr));

        try testing.expectEqualStrings(txt1, buf1);
        bfa.destroy(buf1);
        try testing.expectEqualStrings(txt2, buf2);
        bfa.destroy(buf2);
        try testing.expectEqualStrings(txt3, buf3);
        bfa.destroy(buf3);
        try testing.expectEqualStrings(txt4, buf4);
        bfa.destroy(buf4);

        try testing.expectEqual(0, bfa_state.fixed_buffer_allocator.end_index);
    }

    {
        var buf: [4096]u8 = undefined;
        {
            var bfa: BufferFirstAllocator = .init(&buf, std.testing.allocator);
            try heap.testAllocator(bfa.allocator());
        }
        {
            var bfa: BufferFirstAllocator = .init(&buf, std.testing.allocator);
            try heap.testAllocatorAligned(bfa.allocator());
        }
        {
            var bfa: BufferFirstAllocator = .init(&buf, std.testing.allocator);
            try heap.testAllocatorLargeAlignment(bfa.allocator());
        }
        {
            var bfa: BufferFirstAllocator = .init(&buf, std.testing.allocator);
            try heap.testAllocatorAlignedShrink(bfa.allocator());
        }
    }
}
