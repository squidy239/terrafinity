const std = @import("std");
const Chunk = @import("Chunk").Chunk;

pub fn ConcurrentHashMap(comptime K: type, comptime V: type, comptime Context: type, comptime maxloadpercentage: u64, comptime bucketamount: u32) type {
    return struct {
        const Map = @This();
        const Bkt = Bucket(K, V, Context, maxloadpercentage);
        ctx: Context,
        buckets: [bucketamount]Bkt,

        const Self = @This();

        pub fn get(self: *Self, io: std.Io, key: K) ?V {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].get(io, key);
        }

        pub fn contains(self: *Self, io: std.Io, key: K) bool {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].contains(io, key);
        }

        /// Returns null if item wasn't present, else returns old value and adds a ref to it.
        pub fn putNoOverrideAddRef(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !?V {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return try self.buckets[bucket_index].putNoOverrideAddRef(io, allocator, key, value);
        }

        pub fn getOrPut(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !Map.Bkt.Map.Entry {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return try self.buckets[bucket_index].getOrPut(io, allocator, key, value);
        }

        pub fn getAndAddRef(self: *Self, io: std.Io, key: K) ?V {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].getAndAddRef(io, key);
        }

        pub fn fetchRemove(self: *Self, io: std.Io, key: K) ?V {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].fetchRemove(io, key);
        }

        pub fn getAndAddRefNoLock(self: *Self, key: K) ?V {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].getAndAddRefNoLock(key);
        }

        pub fn getPtr(self: *Self, io: std.Io, key: K) ?*V {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].getPtr(io, key);
        }

        pub fn put(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !void {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            try self.buckets[bucket_index].put(io, allocator, key, value);
        }

        pub fn increment(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, amount: i32) !void {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            try self.buckets[bucket_index].increment(io, allocator, key, amount);
        }

        pub fn fetchPut(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !?V {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return try self.buckets[bucket_index].fetchPut(io, allocator, key, value);
        }

        pub fn remove(self: *Self, io: std.Io, key: K) bool {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].remove(io, key);
        }

        pub fn removeManualLock(self: *Self, key: K) bool {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].removeManualLock(key);
        }

        pub fn count(self: *Self, io: std.Io) usize {
            var totalcount: usize = 0;
            for (&self.buckets) |*bucket| {
                bucket.lock.lockSharedUncancelable(io);
                defer bucket.lock.unlockShared(io);
                totalcount += bucket.hash_map.count();
            }
            return totalcount;
        }

        pub fn init() Self {
            var bkts: [bucketamount]Bucket(K, V, Context, maxloadpercentage) = undefined;
            for (0..bucketamount) |i| {
                bkts[i] = Bucket(K, V, Context, maxloadpercentage).init();
            }
            return .{
                .ctx = Context{},
                .buckets = bkts,
            };
        }

        pub fn deinit(self: *Self, io: std.Io, allocator: std.mem.Allocator) void {
            for (&self.buckets) |*b| {
                b.deinit(io, allocator);
            }
        }

        const Iterator = struct {
            map: *Map,
            bkt_index: usize = 0,
            bkt_iter: ?Bkt.Map.Iterator = null,

            pub fn next(it: *Iterator, io: std.Io) ?Bkt.Map.Entry {
                while (true) {
                    // If we have an active bucket iterator, use it
                    if (it.bkt_iter) |*iter| {
                        if (iter.next()) |entry| {
                            return entry;
                        }

                        // Bucket exhausted
                        it.map.buckets[it.bkt_index].lock.unlockShared(io);
                        it.bkt_iter = null;
                        it.bkt_index += 1;
                        continue;
                    }

                    // Move to next bucket
                    if (it.bkt_index >= it.map.buckets.len)
                        return null;

                    const bucket = &it.map.buckets[it.bkt_index];
                    bucket.lock.lockSharedUncancelable(io);
                    it.bkt_iter = bucket.hash_map.iterator();
                }
            }

            /// Pauses the iterator. Iteration may not be complete or ordered if the map
            /// is modified while paused. Must be followed by unpause.
            pub fn pause(it: *Iterator, io: std.Io) void {
                if (it.bkt_index >= it.map.buckets.len) return;
                it.map.buckets[it.bkt_index].lock.unlockShared(io);
            }

            pub fn unpause(it: *Iterator, io: std.Io) void {
                if (it.bkt_index >= it.map.buckets.len) return;
                it.map.buckets[it.bkt_index].lock.lockSharedUncancelable(io);
            }

            /// Unlocks the current bucket. Only needs to be called if the iterator doesn't finish.
            pub fn deinit(it: *Iterator, io: std.Io) void {
                if (it.bkt_iter != null) {
                    it.map.buckets[it.bkt_index].lock.unlockShared(io);
                    it.bkt_iter = null;
                }
            }
        };

        pub fn iterator(self: *@This()) Iterator {
            return Iterator{ .map = self };
        }
    };
}

fn Bucket(comptime K: type, comptime V: type, comptime Context: type, comptime maxloadpercentage: u64) type {
    return struct {
        pub const Map = std.HashMapUnmanaged(K, V, Context, maxloadpercentage);
        lock: std.Io.RwLock,
        hash_map: Map,

        const Self = @This();

        pub fn get(self: *Self, io: std.Io, key: K) ?V {
            self.lock.lockSharedUncancelable(io);
            defer self.lock.unlockShared(io);
            return self.hash_map.get(key);
        }

        pub fn fetchRemove(self: *Self, io: std.Io, key: K) ?V {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            const r = self.hash_map.get(key);
            _ = self.hash_map.remove(key);
            return r;
        }

        pub fn contains(self: *Self, io: std.Io, key: K) bool {
            self.lock.lockSharedUncancelable(io);
            defer self.lock.unlockShared(io);
            return self.hash_map.contains(key);
        }

        pub fn fetchPut(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !?V {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            const res = try self.hash_map.fetchPut(allocator, key, value) orelse return null;
            return res.value;
        }

        pub fn putNoOverrideAddRef(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !?V {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            const res = self.hash_map.get(key);
            if (res) |r| {
                _ = r.ref_count.fetchAdd(1, .seq_cst);
                return r;
            }
            try self.hash_map.put(allocator, key, value);
            return null;
        }

        pub fn getOrPut(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !Map.Entry {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            return try self.hash_map.getOrPutValue(allocator, key, value);
        }

        pub fn getAndAddRef(self: *Self, io: std.Io, key: K) ?V {
            self.lock.lockSharedUncancelable(io);
            defer self.lock.unlockShared(io);
            const r = self.hash_map.get(key);
            if (r != null) {
                _ = r.?.ref_count.fetchAdd(1, .seq_cst);
            } else return null;
            return r;
        }

        pub fn getAndAddRefNoLock(self: *Self, key: K) ?V {
            const r = self.hash_map.get(key);
            if (r != null) {
                r.?.add_ref();
            } else return null;
            return r;
        }

        pub fn getPtr(self: *Self, io: std.Io, key: K) ?*V {
            self.lock.lockSharedUncancelable(io);
            defer self.lock.unlockShared(io);
            return self.hash_map.getPtr(key);
        }

        pub fn iteratorManualLock(self: *Self) Map.Iterator {
            return self.hash_map.iterator();
        }

        pub fn put(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !void {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            try self.hash_map.put(allocator, key, value);
        }

        pub fn increment(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, amount: i32) !void {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            const k: i32 = self.hash_map.get(key) orelse 0;
            try self.hash_map.put(allocator, key, k + amount);
        }

        pub fn remove(self: *Self, io: std.Io, key: K) bool {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            return self.hash_map.remove(key);
        }

        pub fn removeManualLock(self: *Self, key: K) bool {
            return self.hash_map.remove(key);
        }

        pub fn init() Self {
            return .{
                .lock = .init,
                .hash_map = .empty,
            };
        }

        pub fn deinit(self: *Self, io: std.Io, allocator: std.mem.Allocator) void {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            self.hash_map.deinit(allocator);
        }
    };
}

test "basic get and put" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var hm = ConcurrentHashMap(i32, i32, std.hash_map.AutoContext(i32), 80, 4).init();
    defer hm.deinit(io, allocator);

    try hm.put(io, allocator, 1, 32);
    try hm.put(io, allocator, 345, 775);

    try std.testing.expectEqual(@as(?i32, 32), hm.get(io, 1));
    try std.testing.expect(hm.get(io, 345) == 775);
    try std.testing.expect(hm.get(io, 45645) == null);
}

test "remove" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var hm = ConcurrentHashMap(i32, i32, std.hash_map.AutoContext(i32), 80, 4).init();
    defer hm.deinit(io, allocator);

    try hm.put(io, allocator, 100, 320);
    try hm.put(io, allocator, 345, 775);
    for (0..100) |i| {
        try hm.put(io, allocator, @intCast(i), @intCast(i + 1));
    }
    for (0..50) |i| {
        _ = hm.remove(io, @intCast(i));
    }
    try std.testing.expectEqual(@as(?i32, 320), hm.get(io, 100));
    try std.testing.expect(hm.get(io, 345) == 775);
    try std.testing.expect(hm.get(io, 75) == 76);
    try std.testing.expect(hm.get(io, 45645) == null);
}
