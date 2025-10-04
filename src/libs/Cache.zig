const std = @import("std");

//TODO make concurrent version with no allocations beyond the initialisation
pub fn Cache(comptime K: type, comptime V: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Node = struct {
            key: K,
            value: V,
            prev: ?*Node,
            next: ?*Node,
        };

        allocator: std.mem.Allocator,
        map: std.AutoHashMap(K, *Node),
        head: ?*Node = null, // Most recently used
        tail: ?*Node = null, // Least recently used
        mutex: std.Thread.Mutex = .{},

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .allocator = allocator,
                .map = std.AutoHashMap(K, *Node).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.iterator();
            while (it.next()) |entry| {
                self.allocator.destroy(entry.value_ptr.*);
            }
            self.map.deinit();
        }

        pub fn get(self: *Self, key: K) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();

            const node_ptr = self.map.get(key) orelse return null;

            // Move to front (most recently used)
            self.moveToFront(node_ptr);

            return node_ptr.value;
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // If key exists, update value and move to front
            if (self.map.get(key)) |node_ptr| {
                node_ptr.value = value;
                self.moveToFront(node_ptr);
                return;
            }

            // Create new node
            const node = try self.allocator.create(Node);
            node.* = .{
                .key = key,
                .value = value,
                .prev = null,
                .next = self.head,
            };

            // Add to map
            try self.map.put(key, node);

            // If we have a head, update its prev pointer
            if (self.head) |head| {
                head.prev = node;
            }

            // Update head
            self.head = node;

            // If this is the first node, it's also the tail
            if (self.tail == null) {
                self.tail = node;
            }

            // If we're over capacity, remove tail (LRU element)
            if (self.map.count() > capacity) {
                self.removeTail();
            }
        }

        pub fn remove(self: *Self, key: K) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            const node_ptr = self.map.get(key) orelse return false;

            // Remove from linked list
            if (node_ptr.prev) |prev| {
                prev.next = node_ptr.next;
            } else {
                // This was the head
                self.head = node_ptr.next;
            }

            if (node_ptr.next) |next| {
                next.prev = node_ptr.prev;
            } else {
                // This was the tail
                self.tail = node_ptr.prev;
            }

            // Remove from map and free memory
            _ = self.map.remove(key);
            self.allocator.destroy(node_ptr);

            return true;
        }

        fn moveToFront(self: *Self, node: *Node) void {
            // If node is already at the front, return
            if (node.prev == null) return;

            // Remove node from its current position
            node.prev.?.next = node.next;

            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                // This was the tail
                self.tail = node.prev;
            }

            // Move to front
            node.prev = null;
            node.next = self.head;
            self.head.?.prev = node;
            self.head = node;
        }

        fn removeTail(self: *Self) void {
            const tail = self.tail orelse return;

            // Update tail pointer
            self.tail = tail.prev;

            // If there's a new tail, update its next pointer
            if (self.tail) |new_tail| {
                new_tail.next = null;
            } else {
                // List is now empty
                self.head = null;
            }

            // Remove from map and free memory
            _ = self.map.remove(tail.key);
            self.allocator.destroy(tail);
        }
    };
}

test "LRUCache" {
    var cache = try Cache(u32, u32, 2).init(std.testing.allocator);
    defer cache.deinit();

    try cache.put(1, 10);
    try cache.put(2, 20);

    try std.testing.expectEqual(@as(?u32, 10), cache.get(1));

    // This will evict key 2 because 1 was recently accessed
    try cache.put(3, 30);

    try std.testing.expectEqual(@as(?u32, null), cache.get(2));
    try std.testing.expectEqual(@as(?u32, 10), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 30), cache.get(3));
}
