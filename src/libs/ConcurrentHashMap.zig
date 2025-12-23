const std = @import("std");
const Chunk = @import("Chunk").Chunk;

pub fn ConcurrentHashMap(comptime K: type, comptime V: type, comptime Context: type, comptime maxloadpercentage: u64, comptime bucketamount: u32) type {
    return struct {
        ctx: Context,
        buckets: [bucketamount]Bucket(K, V, Context, maxloadpercentage),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn get(self: *Self, key: K) ?V {
            //const hashget = ztracy.ZoneNC(@src(), "hashget", 0x9692d);
            //defer hashget.End();
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].get(key);
        }

        pub fn contains(self: *Self, key: K) bool {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].contains(key);
        }

        ///returns null if item wasent present, else returns [newvalue, oldvalue], adds a ref to oldvalue
        pub fn putNoOverrideaddRef(self: *Self, key: K, value: V) !?V {
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return try self.buckets[bucket_index].putNoOverride(key, value);
        }

        pub fn getandaddref(self: *Self, key: K) ?V {
            //const hashget = ztracy.ZoneNC(@src(), "hashget", 0x9692d);
            //defer hashget.End();
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].getandaddref(key);
        }

        pub fn fetchremove(self: *Self, key: K) ?V {
            //const hashget = ztracy.ZoneNC(@src(), "hashget", 0x9692d);
            //defer hashget.End();
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].fetchremove(key);
        }

        pub fn getandaddrefnolock(self: *Self, key: K) ?V {
            //const hashget = ztracy.ZoneNC(@src(), "hashget", 0x9692d);
            //defer hashget.End();
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].getandaddrefnolock(key);
        }

        pub fn getPtr(self: *Self, key: K) ?*V {
            //const hashgetptr = ztracy.ZoneNC(@src(), "hashgetptr", 0x9692d);
            //defer hashgetptr.End();
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].getPtr(key);
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            //const hashput = ztracy.ZoneNC(@src(), "hashput", 0x9692d);
            //defer hashput.End();
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            try self.buckets[bucket_index].put(key, value);
        }

        pub fn increment(self: *Self, key: K, amount: i32) !void {
            //const hashput = ztracy.ZoneNC(@src(), "hashput", 0x9692d);
            //defer hashput.End();
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            try self.buckets[bucket_index].increment(key, amount);
        }

        pub fn fetchPut(self: *Self, key: K, value: V) !?V {
            //const hashput = ztracy.ZoneNC(@src(), "hashput", 0x9692d);
            //defer hashput.End();
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return try self.buckets[bucket_index].fetchPut(key, value);
        }

        pub fn remove(self: *Self, key: K) bool {
            //const hashput = ztracy.ZoneNC(@src(), "hashput", 0x9692d);
            //defer hashput.End();
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].remove(key);
        }

        pub fn removemanuallock(self: *Self, key: K) bool {
            //const hashput = ztracy.ZoneNC(@src(), "hashput", 0x9692d);
            //defer hashput.End();
            const hash_code = self.ctx.hash(key);
            const bucket_index = @mod(hash_code, bucketamount);
            return self.buckets[bucket_index].removemanuallock(key);
        }

        pub fn count(self: *Self) usize {
            //const hashput = ztracy.ZoneNC(@src(), "count", 0x9692d);
            //defer hashput.End();
            var totalcount: usize = 0;
            for (&self.buckets) |*bucket| {
                bucket.lock.lockShared();
                defer bucket.lock.unlockShared();
                totalcount += bucket.hash_map.count();
            }
            return totalcount;
        }

        pub fn init(allocator: std.mem.Allocator) Self {
            var bkts: [bucketamount]Bucket(K, V, Context, maxloadpercentage) = undefined;
            for (0..bucketamount) |i| {
                bkts[i] = Bucket(K, V, Context, maxloadpercentage).init(allocator);
            }
            return .{
                .allocator = allocator,
                .ctx = Context{},
                .buckets = bkts,
            };
        }

        pub fn deinit(self: *Self) void {
            for (&self.buckets) |*b| {
                b.deinit();
            }
        }
    };
}

fn Bucket(comptime K: type, comptime V: type, comptime Context: type, comptime maxloadpercentage: u64) type {
    return struct {
        lock: std.Thread.RwLock,
        hash_map: std.HashMap(K, V, Context, maxloadpercentage),

        const Self = @This();

        pub fn get(self: *Self, key: K) ?V {
            //const bktlock = ztracy.ZoneNC(@src(), "bktlock", 0x2665f2d);
            self.lock.lockShared();
            //bktlock.End();
            defer self.lock.unlockShared();
            return self.hash_map.get(key);
        }
        pub fn fetchremove(self: *Self, key: K) ?V {
            //const bktlock = ztracy.ZoneNC(@src(), "bktlock", 0x2665f2d);
            self.lock.lock();
            //bktlock.End();
            defer self.lock.unlock();
            const r = self.hash_map.get(key);
            _ = self.hash_map.remove(key);
            return r;
        }

        pub fn contains(self: *Self, key: K) bool {
            //const bktlock = ztracy.ZoneNC(@src(), "bktlock", 0x2665f2d);
            self.lock.lockShared();
            //bktlock.End();
            defer self.lock.unlockShared();
            return self.hash_map.contains(key);
        }

        pub fn fetchPut(self: *Self, key: K, value: V) !?V {
            //const bktlock = ztracy.ZoneNC(@src(), "bktlock", 0x2665f2d);
            self.lock.lock();
            //bktlock.End();
            defer self.lock.unlock();
            const res = try self.hash_map.fetchPut(key, value) orelse return null;
            return res.value;
        }

        pub fn putNoOverride(self: *Self, key: K, value: V) !?V {
            //const bktlock = ztracy.ZoneNC(@src(), "bktlock", 0x2665f2d);
            self.lock.lock();
            //bktlock.End();
            defer self.lock.unlock();

            const res = self.hash_map.get(key);
            if (res) |r| {
                _ = r.ref_count.fetchAdd(1, .seq_cst);
                return r;
            }
            try self.hash_map.put(key, value);
            return null;
        }

        pub fn getandaddref(self: *Self, key: K) ?V {
            //const bktlock = ztracy.ZoneNC(@src(), "bktlock", 0x2665f2d);
            self.lock.lockShared();
            //bktlock.End();
            defer self.lock.unlockShared();
            const r = self.hash_map.get(key);
            if (r != null) {
                _ = r.?.ref_count.fetchAdd(1, .seq_cst);
            } else return null;
            return r;
        }

        pub fn getandaddrefnolock(self: *Self, key: K) ?V {
            const r = self.hash_map.get(key);
            if (r != null) {
                r.?.add_ref();
            } else return null;
            return r;
        }

        pub fn getPtr(self: *Self, key: K) ?*V {
            //const bktlock = ztracy.ZoneNC(@src(), "bktlock", 0x2665f2d);
            self.lock.lockShared();
            //bktlock.End();
            defer self.lock.unlockShared();
            return self.hash_map.getPtr(key);
        }

        pub fn iteratorManualLock(self: *Self) std.HashMap(K, V, Context, maxloadpercentage).Iterator {
            return self.hash_map.iterator();
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            //const bktlock = ztracy.ZoneNC(@src(), "bktlock", 0x2665f2d);
            self.lock.lock();
            //bktlock.End();
            defer self.lock.unlock();
            try self.hash_map.put(key, value);
        }

        pub fn increment(self: *Self, key: K, amount: i32) !void {
            self.lock.lock();
            defer self.lock.unlock();
            const k: i32 = self.hash_map.get(key) orelse 0;
            try self.hash_map.put(key, k + amount);
        }

        pub fn remove(self: *Self, key: K) bool {
            //const bktlock = ztracy.ZoneNC(@src(), "bktlock", 0x2665f2d);
            self.lock.lock();
            //bktlock.End();
            defer self.lock.unlock();
            return self.hash_map.remove(key);
        }

        pub fn removemanuallock(self: *Self, key: K) bool {
            return self.hash_map.remove(key);
        }

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .lock = .{},
                .hash_map = std.HashMap(K, V, Context, maxloadpercentage).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.hash_map.deinit();
        }
    };
}

test "basic get and put" {
    const allocator = std.testing.allocator;
    var hm = ConcurrentHashMap(i32, i32, std.hash_map.AutoContext(i32), 80, 4).init(allocator);
    defer hm.deinit();

    try hm.put(1, 32);
    try hm.put(345, 775);

    try std.testing.expectEqual(@as(?i32, 32), hm.get(1));
    try std.testing.expect(hm.get(345) == 775);
    try std.testing.expect(hm.get(45645) == null);
}

test "remove" {
    const allocator = std.testing.allocator;
    var hm = ConcurrentHashMap(i32, i32, std.hash_map.AutoContext(i32), 80, 4).init(allocator);
    defer hm.deinit();

    try hm.put(100, 320);
    try hm.put(345, 775);
    for (0..100) |i| {
        try hm.put(@intCast(i), @intCast(i + 1));
    }
    for (0..50) |i| {
        _ = hm.remove(@intCast(i));
    }
    try std.testing.expectEqual(@as(?i32, 320), hm.get(100));
    try std.testing.expect(hm.get(345) == 775);
    try std.testing.expect(hm.get(75) == 76);
    try std.testing.expect(hm.get(45645) == null);
}
