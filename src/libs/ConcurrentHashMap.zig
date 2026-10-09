const std = @import("std");

/// A hash map split into `bucket_amount` buckets, each guarded by its own read-write lock.
pub fn ConcurrentHashMap(comptime K: type, comptime V: type, comptime Context: type, comptime bucket_amount: u32) type {
    return struct {
        const Self = @This();
        /// One lock-guarded part of the map.
        pub const Bucket = BucketType(K, V, Context);

        buckets: [bucket_amount]Bucket,

        /// An empty map.
        pub const init: Self = .{ .buckets = @splat(.init) };

        /// Returns a copy of the value for `key`, or null when the map does not hold it.
        pub fn get(self: *Self, io: std.Io, key: K) ?V {
            return self.getBucket(key).get(io, key);
        }

        /// Returns the bucket that holds `key`. The caller locks it for compound operations.
        pub fn getBucket(self: *Self, key: K) *Bucket {
            const hash_code = (Context{}).hash(key);
            return &self.buckets[hash_code % bucket_amount];
        }

        /// Removes `key` and returns its value, or null when the map does not hold it.
        pub fn fetchRemove(self: *Self, io: std.Io, key: K) ?V {
            return self.getBucket(key).fetchRemove(io, key);
        }

        /// Inserts or replaces the value for `key`.
        pub fn put(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !void {
            try self.getBucket(key).put(io, allocator, key, value);
        }

        /// Inserts or replaces the value for `key` and returns the replaced value.
        pub fn fetchPut(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !?V {
            return self.getBucket(key).fetchPut(io, allocator, key, value);
        }

        /// Returns the number of entries in all buckets.
        pub fn count(self: *Self, io: std.Io) usize {
            var total_count: usize = 0;
            for (&self.buckets) |*bucket| {
                bucket.lock.lockSharedUncancelable(io);
                defer bucket.lock.unlockShared(io);
                total_count += bucket.hash_map.count();
            }
            return total_count;
        }

        /// Frees the memory of all buckets.
        pub fn deinit(self: *Self, io: std.Io, allocator: std.mem.Allocator) void {
            for (&self.buckets) |*bucket| bucket.deinit(io, allocator);
        }

        /// Visits each entry. It holds the shared lock of the current bucket until `deinit`.
        pub const Iterator = struct {
            map: *Self,
            bucket_index: usize = 0,
            bucket_iterator: ?Bucket.HashMap.Iterator = null,

            /// Returns the next entry, or null after the last bucket.
            pub fn next(it: *Iterator, io: std.Io) !?Bucket.HashMap.Entry {
                while (true) {
                    if (it.bucket_iterator) |*bucket_iterator| {
                        if (bucket_iterator.next()) |entry| return entry;

                        it.map.buckets[it.bucket_index].lock.unlockShared(io);
                        it.bucket_iterator = null;
                        it.bucket_index += 1;
                        continue;
                    }

                    if (it.bucket_index >= it.map.buckets.len) return null;

                    const bucket = &it.map.buckets[it.bucket_index];
                    try bucket.lock.lockShared(io);
                    it.bucket_iterator = bucket.hash_map.iterator();
                }
            }

            /// Releases the lock of the current bucket.
            pub fn deinit(it: *Iterator, io: std.Io) void {
                if (it.bucket_iterator != null) it.map.buckets[it.bucket_index].lock.unlockShared(io);
                it.* = undefined;
            }
        };

        /// Returns an iterator that starts at the first bucket.
        pub fn iterator(self: *Self) Iterator {
            return .{ .map = self };
        }
    };
}

fn BucketType(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        const HashMap = std.HashMapUnmanaged(K, V, Context, 80);

        hash_map: HashMap,
        lock: std.Io.RwLock,

        const init: Self = .{ .hash_map = .empty, .lock = .init };

        /// Returns a copy of the value for `key` under the shared lock.
        pub fn get(self: *Self, io: std.Io, key: K) ?V {
            self.lock.lockSharedUncancelable(io);
            defer self.lock.unlockShared(io);
            return self.hash_map.get(key);
        }

        /// Removes `key` and returns its value under the exclusive lock.
        pub fn fetchRemove(self: *Self, io: std.Io, key: K) ?V {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            const kv = self.hash_map.fetchRemove(key) orelse return null;
            return kv.value;
        }

        /// Inserts or replaces the value for `key` and returns the replaced value.
        pub fn fetchPut(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !?V {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            return if (try self.hash_map.fetchPut(allocator, key, value)) |kv| kv.value else null;
        }

        /// Inserts or replaces the value for `key` under the exclusive lock.
        pub fn put(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !void {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            try self.hash_map.put(allocator, key, value);
        }

        /// Frees the memory of the bucket.
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
        fn run(allocator: std.mem.Allocator, test_io: std.Io) !void {
            var map = ConcurrentHashMap(i32, i32, std.hash_map.AutoContext(i32), 4).init;
            defer map.deinit(test_io, allocator);
            try map.put(test_io, allocator, 1, 10);
            try map.put(test_io, allocator, 2, 20);
            _ = map.get(test_io, 1);
            _ = map.fetchRemove(test_io, 2);
        }
    }.run;

    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_fn, .{io});
}

test {
    std.testing.refAllDecls(@This());
}
