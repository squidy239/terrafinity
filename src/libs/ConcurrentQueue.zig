const std = @import("std");
//const ztracy = @import("ztracy");

pub fn ConcurrentQueue(comptime DataType: type, comptime fragments: usize, comptime strictFIFO: bool) type {
    return struct {
        setfragmentindex: std.atomic.Value(u64),
        getfragmentindex: std.atomic.Value(u64),
        getfragmentindexlock: std.Thread.RwLock,
        allocators: [fragments]std.mem.Allocator,
        fragments: [fragments]std.DoublyLinkedList,
        fragmentLocks: [fragments]std.Thread.Mutex,
        pub fn init(allocator: std.mem.Allocator) @This() {
            var queue = @This(){
                .setfragmentindex = std.atomic.Value(u64).init(0),
                .getfragmentindex = std.atomic.Value(u64).init(0),
                .getfragmentindexlock = .{},
                .fragments = @splat(.{}),
                .allocators = undefined,
                .fragmentLocks = @splat(.{}),
            };
            queue.allocators = @splat(allocator);
            return queue;
        }

        pub fn deinit(self: *@This(), assertEmpty: bool) void {
            for (&self.fragments, 0..) |*fragment, i| {
                while (fragment.popFirst()) |node| {
                    if (assertEmpty) {
                        unreachable;
                    }
                    const datanode: *Node = @fieldParentPtr("node", node);
                    self.allocators[i].destroy(datanode);
                }
            }
        }

        pub fn append(self: *@This(), data: DataType) !removable {
            // const a = ztracy.ZoneNC(@src(), "ConcurrentQueueAppend", 34343);
            // defer a.End();
            const index = @rem(self.setfragmentindex.fetchAdd(1, .seq_cst), fragments);
            self.fragmentLocks[index].lock();
            defer self.fragmentLocks[index].unlock();
            const nodePtr = try self.allocators[index].create(Node);
            nodePtr.* = Node{
                .data = data,
                .node = .{},
            };
            self.fragments[index].append(&nodePtr.node);
            return removable{ .index = index, .node = &nodePtr.node };
        }

        pub const removable = struct {
            index: usize,
            node: *std.DoublyLinkedList.Node,
        };

        pub fn popFirst(self: *@This()) ?DataType {
            //    const pop = ztracy.ZoneNC(@src(), "ConcurrentQueuePopFirst", 23325);
            //   defer pop.End();
            var index: usize = undefined;
            //  const fil = ztracy.ZoneNC(@src(), "ConcurrentQueueFragmentIndexLock", 2332);
            if (strictFIFO) self.getfragmentindexlock.lock();

            //  fil.End();
            index = @rem(self.getfragmentindex.fetchAdd(1, .seq_cst), fragments);
            //   const fl = ztracy.ZoneNC(@src(), "ConcurrentQueueFragmentLock", 67567567);
            self.fragmentLocks[index].lock();
            //    fl.End();
            defer self.fragmentLocks[index].unlock();
            if (self.fragments[index].popFirst()) |node| {
                if (strictFIFO) self.getfragmentindexlock.unlock();
                const datanode: *Node = @fieldParentPtr("node", node);
                const data: DataType = datanode.data;
                self.allocators[index].destroy(datanode);
                return data;
            } else {
                _ = self.getfragmentindex.fetchSub(1, .seq_cst);
                if (strictFIFO) self.getfragmentindexlock.unlock();
            }
            return null;
        }

        pub const Node = struct {
            data: DataType,
            node: std.DoublyLinkedList.Node,
        };
    };
}

test "queue" {
    var queue = try ConcurrentQueue(u32, 32, 1_000_000, true).init((std.testing.allocator));
    defer queue.deinit(true);
    _ = try queue.append(12);
    _ = try queue.append(43);
    try std.testing.expectEqual(@as(u32, 12), queue.popFirst());
    try std.testing.expectEqual(@as(u32, 43), queue.popFirst());
    try std.testing.expectEqual(null, queue.popFirst());
    try std.testing.expectEqual(null, queue.popFirst());

    for (0..100) |i| {
        _ = try queue.append(@intCast(i));
    }

    std.Thread.sleep(50 * std.time.ns_per_ms);
    for (0..100) |i| {
        const p = queue.popFirst();
        try std.testing.expectEqual(@as(u32, @intCast(i)), p);
        std.debug.print("p: {any}\n", .{p});
    }
    try std.testing.expectEqual(null, queue.popFirst());
    std.debug.print("singlethreaded pass\n", .{});
}

test "multithreaded_non_strict_queue" {
    var queue = try ConcurrentQueue(u32, 32, 1_000_000, false).init((std.testing.allocator));
    defer queue.deinit(true);
    _ = try queue.append(12);
    _ = try queue.append(43);
    try std.testing.expectEqual(@as(u32, 12), queue.popFirst());
    try std.testing.expectEqual(@as(u32, 43), queue.popFirst());
    try std.testing.expectEqual(null, queue.popFirst());
    try std.testing.expectEqual(null, queue.popFirst());

    for (0..100) |i| {
        _ = try queue.append(@intCast(i));
    }

    std.Thread.sleep(50 * std.time.ns_per_ms);
    var threads: [100]std.Thread = undefined;
    var imut: std.Thread.Mutex = .{};
    var i: u32 = 0;
    for (0..100) |j| {
        threads[j] = try std.Thread.spawn(.{}, qget, .{ *@TypeOf(queue), &queue, &i, &imut });
    }
    for (0..100) |j| {
        threads[j].join();
    }
    std.debug.print("multithreaded pass\n", .{});
}

test "multithreadedqueuestrict" {
    var queue = try ConcurrentQueue(u32, 32, 1_000_000, true).init((std.testing.allocator));
    defer queue.deinit(true);
    _ = try queue.append(12);
    _ = try queue.append(43);
    try std.testing.expectEqual(@as(u32, 12), queue.popFirst());
    try std.testing.expectEqual(@as(u32, 43), queue.popFirst());
    try std.testing.expectEqual(null, queue.popFirst());
    try std.testing.expectEqual(null, queue.popFirst());

    for (0..100) |i| {
        _ = try queue.append(@intCast(i));
    }

    std.Thread.sleep(50 * std.time.ns_per_ms);
    var threads: [100]std.Thread = undefined;
    var imut: std.Thread.Mutex = .{};
    var i: u32 = 0;
    for (0..100) |j| {
        threads[j] = try std.Thread.spawn(.{}, qget, .{ *@TypeOf(queue), &queue, &i, &imut });
    }
    for (0..100) |j| {
        threads[j].join();
    }
    std.debug.print("multithreaded strict pass\n", .{});
}
fn qget(T: type, q: T, i: *u32, imut: *std.Thread.Mutex) void {
    imut.lock();
    defer imut.unlock();
    std.debug.print("i: {any}, p: {any}\n", .{ i.*, q.popFirst() });
    i.* += 1;
}

test "deinit" {
    var queue = try ConcurrentQueue(u32, 8, 1_000_000, true).init((std.testing.allocator));
    defer queue.deinit(false);
    _ = try queue.append(12);
    _ = try queue.append(43);
}
