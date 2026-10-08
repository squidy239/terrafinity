const std = @import("std");

pub fn ConcurrentHashMap(comptime K: type, comptime V: type, comptime Context: type, comptime bucket_amount: u32) type {
    return struct {
        const Map = @This();
        pub const Bkt = Bucket(K, V, Context);
        buckets: [bucket_amount]Bkt,

        const Self = @This();

        pub fn get(self: *Self, io: std.Io, key: K) ?V {
            return self.getBucket(key).get(io, key);
        }

        pub fn getBucket(self: *Self, key: K) *Bkt {
            const hash_code = (Context{}).hash(key);
            return &self.buckets[@mod(hash_code, bucket_amount)];
        }

        pub fn fetchRemove(self: *Self, io: std.Io, key: K) ?V {
            return self.getBucket(key).fetchRemove(io, key);
        }

        pub fn put(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !void {
            try self.getBucket(key).put(io, allocator, key, value);
        }

        pub fn fetchPut(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !?V {
            return self.getBucket(key).fetchPut(io, allocator, key, value);
        }

        pub fn count(self: *Self, io: std.Io) usize {
            var total_count: usize = 0;
            for (&self.buckets) |*bucket| {
                bucket.lock.lockSharedUncancelable(io);
                defer bucket.lock.unlockShared(io);
                total_count += bucket.hash_map.count();
            }
            return total_count;
        }

        pub const init = blk: {
            var bkts: [bucket_amount]Bucket(K, V, Context) = undefined;
            for (&bkts) |*bkt| {
                bkt.* = Bucket(K, V, Context).init();
            }
            break :blk @This(){ .buckets = bkts };
        };

        pub fn deinit(self: *Self, io: std.Io, allocator: std.mem.Allocator) void {
            for (&self.buckets) |*b| {
                b.deinit(io, allocator);
            }
        }

        pub const Iterator = struct {
            map: *Map,
            bkt_index: usize = 0,
            bkt_iter: ?Bkt.Map.Iterator = null,

            pub fn next(it: *Iterator, io: std.Io) !?Bkt.Map.Entry {
                while (true) {
                    if (it.bkt_iter) |*iter| {
                        if (iter.next()) |entry| {
                            return entry;
                        }

                        it.map.buckets[it.bkt_index].lock.unlockShared(io);
                        it.bkt_iter = null;
                        it.bkt_index += 1;
                        continue;
                    }

                    if (it.bkt_index >= it.map.buckets.len)
                        return null;

                    const bucket = &it.map.buckets[it.bkt_index];
                    try bucket.lock.lockShared(io);
                    it.bkt_iter = bucket.hash_map.iterator();
                }
            }

            pub fn deinit(it: *Iterator, io: std.Io) void {
                if (it.bkt_iter != null) it.map.buckets[it.bkt_index].lock.unlockShared(io);
                it.* = undefined;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{
                .map = self,
            };
        }
    };
}

fn Bucket(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        const Map = std.HashMapUnmanaged(K, V, Context, 80);

        hash_map: Map,
        lock: std.Io.RwLock,

        pub fn init() Self {
            return .{
                .hash_map = .empty,
                .lock = .init,
            };
        }

        pub fn get(self: *Self, io: std.Io, key: K) ?V {
            self.lock.lockSharedUncancelable(io);
            defer self.lock.unlockShared(io);
            return self.hash_map.get(key);
        }

        pub fn fetchRemove(self: *Self, io: std.Io, key: K) ?V {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            const kv = self.hash_map.fetchRemove(key) orelse return null;
            return kv.value;
        }

        pub fn fetchPut(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !?V {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            const kv = try self.hash_map.fetchPut(allocator, key, value);
            return if (kv) |kv_val| kv_val.value else null;
        }

        pub fn put(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !void {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            try self.hash_map.put(allocator, key, value);
        }

        pub fn deinit(self: *Self, io: std.Io, allocator: std.mem.Allocator) void {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            self.hash_map.deinit(allocator);
        }
    };
}

test "ConcurrentHashMap basic" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var map = ConcurrentHashMap(i32, i32, std.hash_map.AutoContext(i32), 4).init;
    defer map.deinit(io, allocator);

    try map.put(io, allocator, 1, 10);
    try map.put(io, allocator, 2, 20);

    try std.testing.expectEqual(@as(?i32, 10), map.get(io, 1));
    try std.testing.expectEqual(@as(?i32, 20), map.get(io, 2));
    try std.testing.expectEqual(@as(?i32, null), map.get(io, 3));

    try std.testing.expectEqual(@as(?i32, 10), map.fetchRemove(io, 1));
    try std.testing.expectEqual(@as(?i32, null), map.get(io, 1));
}

test "ConcurrentHashMap allocation failure" {
    const io = std.testing.io;
    const test_fn = struct {
        fn run(allocator: std.mem.Allocator, _io: std.Io) !void {
            var map = ConcurrentHashMap(i32, i32, std.hash_map.AutoContext(i32), 4).init;
            defer map.deinit(_io, allocator);
            try map.put(_io, allocator, 1, 10);
            try map.put(_io, allocator, 2, 20);
            _ = map.get(_io, 1);
            _ = map.fetchRemove(_io, 2);
        }
    }.run;

    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_fn, .{io});
}
