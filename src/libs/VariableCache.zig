const std = @import("std");
const zballoc = @import("zballoc.zig");

//a work in progress LRU cache with no allocations after initialization
pub fn TypeErasedCache(K: type) type {
    return struct {
        const Cache = @This();
        const keyhashfn = std.hash_map.getAutoHashFn(K, void);

        const Segment = struct {
            keyhash: u64,
            node: std.DoublyLinkedList.Node,
        };

        const MapData = struct {
            slice: []u8,
            nodeptr: *std.DoublyLinkedList.Node,
        };

        zballoc: zballoc,
        allocator: std.mem.Allocator,
        list: std.DoublyLinkedList,
        list_buffer: std.heap.MemoryPoolExtra(Segment, .{ .growable = false }),
        map: std.HashMapUnmanaged(u64, MapData, std.hash_map.AutoContext(u64), 80), //TODO no context because the u64 is a hash
        buffer_len: usize,
        max_items: usize,
        current_items: usize,

        pub fn sizeOfZballocData(alloc_count: usize) usize {
            const node_count = alloc_count + 1;
            var size: usize = 0;
            size += @sizeOf(zballoc.Node.Index) * node_count;
            size += @sizeOf(zballoc.Node) * node_count;
            size += ((node_count + 1) + (@bitSizeOf(usize) - 1)) / @bitSizeOf(usize); //this is from dynamic bitset resize
            return size;
        }
        pub fn init(self: *@This(), allocator: std.mem.Allocator, buffer: []u8, max_items: usize) !void {
            self.* = .{
                .zballoc = try .init(allocator, buffer, @intCast(max_items)),
                .list = .{},
                .list_buffer = try .initPreheated(allocator, max_items),
                .allocator = undefined,
                .buffer_len = buffer.len,
                .map = .empty,
                .current_items = 0,
                .max_items = max_items,
            };
            try self.map.ensureTotalCapacity(allocator, @intCast(max_items));
            self.allocator = self.zballoc.allocator();
        }

        ///cache must be empty before calling this
        pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
            std.debug.assert(self.map.count() == 0);
            std.debug.assert(self.current_items == 0);
            self.map.deinit(allocator);
            self.list_buffer.deinit();
            std.debug.assert(self.zballoc.totalFreeSpace() == self.buffer_len);
            self.zballoc.deinit(allocator);
            self.* = undefined;
        }

        pub fn use(self: *Cache, key: K) void {
            const keyhash = keyhashfn({}, key);
            const mapdata = self.map.get(keyhash) orelse return;
            self.list.remove(mapdata.nodeptr);
            self.list.append(mapdata.nodeptr);
        }

        pub fn put(self: *Cache, key: K, data: []const u8) void {
            std.debug.assert(data.len < self.buffer_len);
            const keyhash = keyhashfn({}, key);
            var mem: []u8 = undefined;
            while (true) {
                mem = self.allocator.alloc(u8, data.len) catch continue;
                break;
            }
            @memcpy(mem, data);

            while (self.current_items == self.max_items) {}

            const segment = self.list_buffer.create() catch unreachable;
            segment.* = .{ .keyhash = keyhash, .node = .{} };
            self.list.append(&segment.node);
            self.map.putAssumeCapacityNoClobber(keyhash, .{ .nodeptr = &segment.node, .slice = mem });

            self.current_items += 1;
        }

        ///removes the oldest entry from the queue and returns it if it exists, freeSlice must be called on the returned slice.
        pub fn evict(self: *Cache) ?[]u8 {
            while (true) {
                const node = self.list.pop() orelse return null;
                const segment: *Segment = @fieldParentPtr("node", node);
                const entry = self.map.fetchRemove(segment.keyhash) orelse {
                    std.log.debug("key not in map, trying next...", .{}); //TODO remove this after testing
                    continue;
                };
                self.list_buffer.destroy(segment);
                self.current_items -= 1;
                return entry.value.slice;
            }
        }

        pub fn freeSlice(self: *Cache, slice: []u8) void {
            self.allocator.free(slice);
        }

        pub fn get(self: *Cache, key: K) ?[]u8 {
            const keyhash = keyhashfn({}, key);
            const mapdata = self.map.get(keyhash) orelse return null;
            self.list.remove(mapdata.nodeptr);
            self.list.append(mapdata.nodeptr);
            return mapdata.slice;
        }
    };
}

test "simple single threaded" {
    var buffer: [65536]u8 = undefined;

    var cache: TypeErasedCache(u64) = undefined;
    try cache.init(std.testing.allocator, &buffer, 2048);
    defer cache.deinit(std.testing.allocator);
    for (0..100) |i| {
        cache.put(i, "hello");
        try std.testing.expectEqualStrings("hello", (cache.get(i)) orelse return error.Failed);
        const evicted = cache.evict() orelse return error.Failed;
        try std.testing.expectEqualStrings("hello", evicted);
        cache.freeSlice(evicted);
    }
    for (0..1024) |i| {
        cache.put(i, std.mem.asBytes(&i));
    }
    for (0..1024) |i| {
        const g = std.mem.bytesToValue(usize, (cache.get(i) orelse return error.Failed));
        try std.testing.expectEqual(i, g);
        const evicted = cache.evict() orelse return error.Failed;
        try std.testing.expectEqual(i, std.mem.bytesToValue(usize, evicted));
        cache.freeSlice(evicted);
    }
    try std.testing.expectEqual(cache.get(4345), null);
    try std.testing.expectEqual(cache.get(2), null);
    try std.testing.expectEqual(cache.evict(), null);
}
