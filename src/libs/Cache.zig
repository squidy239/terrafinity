const std = @import("std");
const SetAssociativeCache = @import("SetAssociativeCache.zig");

/// A set-associative cache split into `fragments` shards, each with its own lock.
/// The hash of a key selects the shard.
pub fn Cache(
    comptime Key: type,
    comptime Value: type,
    comptime key_from_value: fn (*const Value) callconv(.@"inline") Key,
    comptime hash: fn (Key) callconv(.@"inline") u64,
    comptime layout: SetAssociativeCache.Layout,
    comptime fragments: comptime_int,
) type {
    return struct {
        const Self = @This();
        pub const Shard = SetAssociativeCache.SetAssociativeCacheType(Key, Value, key_from_value, hash, layout);
        pub const value_count_min = Shard.value_count_min * fragments;
        shards: [fragments]Shard,
        shard_locks: [fragments]std.Io.Mutex,

        pub fn init(allocator: std.mem.Allocator, value_count_max: u64) !Self {
            var self: Self = .{
                .shards = undefined,
                .shard_locks = @splat(.init),
            };
            var initialized_count: usize = 0;
            errdefer for (self.shards[0..initialized_count]) |*shard| shard.deinit(allocator);
            for (&self.shards) |*shard| {
                shard.* = try .init(allocator, value_count_max / fragments);
                initialized_count += 1;
            }
            return self;
        }

        /// Frees the memory of all shards.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (&self.shards) |*shard| shard.deinit(allocator);
        }

        /// Returns a copy of the value for `key`, or null when the cache does not hold it.
        pub fn get(self: *Self, io: std.Io, key: Key) ?Value {
            const shard, const lock = self.getShardAndLock(key);
            lock.lockUncancelable(io);
            defer lock.unlock(io);
            return if (shard.get(key)) |v| v.* else null;
        }

        /// Removes `key` and returns its value, or null when the cache does not hold it.
        pub fn remove(self: *Self, io: std.Io, key: Key) ?Value {
            const shard, const lock = self.getShardAndLock(key);
            lock.lockUncancelable(io);
            defer lock.unlock(io);
            return shard.remove(key);
        }

        /// Returns the shard that holds `key` and the lock that guards that shard.
        pub fn getShardAndLock(self: *Self, key: Key) struct { *Shard, *std.Io.Mutex } {
            const shard_index = hash(key) % fragments;
            return .{ &self.shards[shard_index], &self.shard_locks[shard_index] };
        }

        /// Returns the number of values in all shards.
        pub fn count(self: *const Self) u64 {
            return self.sumMetric("value_count");
        }

        /// Returns the number of `get` calls on all shards that found their key.
        pub fn hits(self: *const Self) u64 {
            return self.sumMetric("hits");
        }

        /// Returns the number of `get` calls on all shards that did not find their key.
        pub fn misses(self: *const Self) u64 {
            return self.sumMetric("misses");
        }

        fn sumMetric(self: *const Self, comptime name: []const u8) u64 {
            var total: u64 = 0;
            for (&self.shards) |*shard| total += @field(shard.metrics, name).load(.acquire);
            return total;
        }

        /// Inserts or replaces the value and returns the value that it evicts.
        pub fn upsert(self: *Self, io: std.Io, value: *const Value) Shard.Upserted {
            const shard, const lock = self.getShardAndLock(key_from_value(value));
            lock.lockUncancelable(io);
            defer lock.unlock(io);
            return shard.upsert(value);
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
