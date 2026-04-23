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

        pub const Iterator = struct {
            map: *Map,
            bkt_index: usize = 0,
            bkt_iter: ?Bkt.Map.Iterator = null,
            paused: bool = false,

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
                if (it.bkt_index < it.map.buckets.len) {
                    it.map.buckets[it.bkt_index].lock.unlockShared(io);
                }
                it.paused = true;
            }

            pub fn unpause(it: *Iterator, io: std.Io) !void {
                if (it.bkt_index < it.map.buckets.len) {
                    try it.map.buckets[it.bkt_index].lock.lockShared(io);
                }
                it.paused = false;
            }

            pub fn deinit(it: *Iterator, io: std.Io) void {
                if (it.bkt_iter != null) {
                    if (!it.paused) it.map.buckets[it.bkt_index].lock.unlockShared(io);
                }
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

fn Bucket(comptime K: type, comptime V: type, comptime Context: type, comptime maxloadpercentage: u64) type {
    _ = maxloadpercentage;
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

        pub fn contains(self: *Self, io: std.Io, key: K) bool {
            self.lock.lockSharedUncancelable(io);
            defer self.lock.unlockShared(io);
            return self.hash_map.contains(key);
        }

        pub fn fetchRemove(self: *Self, io: std.Io, key: K) ?V {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            const kv = self.hash_map.fetchRemove(key) orelse return null;
            return kv.value;
        }

        pub fn getAndAddRef(self: *Self, io: std.Io, key: K) ?V {
            self.lock.lockSharedUncancelable(io);
            defer self.lock.unlockShared(io);
            const val = self.hash_map.get(key) orelse return null;
            _ = val.ref_count.fetchAdd(1, .seq_cst);
            return val;
        }

        pub fn getAndAddRefNoLock(self: *Self, key: K) ?V {
            const val = self.hash_map.get(key) orelse return null;
            _ = val.ref_count.fetchAdd(1, .seq_cst);
            return val;
        }

        pub fn getPtr(self: *Self, io: std.Io, key: K) ?*V {
            self.lock.lockSharedUncancelable(io);
            defer self.lock.unlockShared(io);
            return self.hash_map.getPtr(key);
        }

        pub fn fetchPut(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !?V {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            const kv = try self.hash_map.fetchPut(allocator, key, value);
            return if (kv) |kv_val| kv_val.value else null;
        }

        pub fn putNoOverrideAddRef(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !?V {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            if (self.hash_map.get(key)) |val| {
                _ = val.ref_count.fetchAdd(1, .seq_cst);
                return val;
            }
            try self.hash_map.put(allocator, key, value);
            return null;
        }

        pub fn getOrPut(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !Map.Entry {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            return try self.hash_map.getOrPut(allocator, key, value);
        }

        pub fn put(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, value: V) !void {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            try self.hash_map.put(allocator, key, value);
        }

        pub fn increment(self: *Self, io: std.Io, allocator: std.mem.Allocator, key: K, amount: i32) !void {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            const gop = try self.hash_map.getOrPut(allocator, key, 0);
            gop.value_ptr.* += amount;
        }

        pub fn remove(self: *Self, io: std.Io, key: K) bool {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            return self.hash_map.remove(key);
        }

        pub fn removeManualLock(self: *Self, key: K) bool {
            return self.hash_map.remove(key);
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
    var map = ConcurrentHashMap(i32, i32, std.hash_map.AutoContext(i32), 80, 4).init();
    defer map.deinit(io, allocator);

    try map.put(io, allocator, 1, 10);
    try map.put(io, allocator, 2, 20);

    try std.testing.expectEqual(@as(?i32, 10), map.get(io, 1));
    try std.testing.expectEqual(@as(?i32, 20), map.get(io, 2));
    try std.testing.expectEqual(@as(?i32, null), map.get(io, 3));

    try std.testing.expect(map.remove(io, 1));
    try std.testing.expectEqual(@as(?i32, null), map.get(io, 1));
}

test "ConcurrentHashMap allocation failure" {
    const io = std.testing.io;
    const test_fn = struct {
        fn run(allocator: std.mem.Allocator, _io: std.Io) !void {
            var map = ConcurrentHashMap(i32, i32, std.hash_map.AutoContext(i32), 80, 4).init();
            defer map.deinit(_io, allocator);
            try map.put(_io, allocator, 1, 10);
            try map.put(_io, allocator, 2, 20);
            _ = map.get(_io, 1);
            _ = map.remove(_io, 2);
        }
    }.run;

    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_fn, .{io});
}
