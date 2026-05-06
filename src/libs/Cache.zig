const std = @import("std");
const mem = std.mem;
const SetAssociativeCache = @import("SetAssosiativeCache.zig");

/// Each Key is associated with a set of n consecutive ways (or slots) that may contain the Value.
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
        const Shard = SetAssociativeCache.SetAssociativeCacheType(Key, Value, key_from_value, hash, layout);
        shards: [fragments]Shard,
        shard_locks: [fragments]std.Io.RwLock,

        pub fn init(allocator: mem.Allocator, value_count_max: u64, options: Shard.Options) !Self {
            var self: Self = .{
                .shards = undefined,
                .shard_locks = @splat(.init),
            };
            for (&self.shards) |*shard| {
                shard.* = try .init(allocator, value_count_max / fragments, options);
            }
            return self;
        }

        pub fn deinit(self: *Self, allocator: mem.Allocator) void {
            for (&self.shards) |*shard| {
                shard.*.deinit(allocator);
            }
        }

        pub fn reset(self: *Self, io: std.Io) void {
            for (&self.shards, &self.shard_locks) |*shard, *lock| {
                lock.lockUncancelable(io);
                defer lock.unlock();
                shard.*.reset();
            }
        }

        pub fn get(self: *Self, io: std.Io, key: Key) ?*Value {
            const shard, const lock = self.getShardAndLock(key);
            lock.lockSharedUncancelable(io);
            defer lock.unlockShared(io);
            return shard.get(key);
        }

        pub fn remove(self: *Self, key: Key) ?Value {
            const shard, const lock = self.getShardAndLock(key);
            lock.lockUncancelable();
            defer lock.unlock();
            return shard.remove(key);
        }

        pub fn getShardAndLock(self: *Self, key: Key) struct {*Shard, *std.Io.RwLock } {
            const shard_index = hash(key) % fragments;
            const shard = &self.shards[shard_index];
            const lock = &self.shard_locks[shard_index];
            return .{ shard, lock };
        }

        pub fn upsert(self: *Self, io: std.Io, value: *const Value) struct {
            index: usize,
            updated: SetAssociativeCache.UpdateOrInsert,
            evicted: ?Value,
        } {
            const shard, const lock = self.getShardAndLock(key_from_value(value));
            lock.lockUncancelable(io);
            defer lock.unlock(io);
            const result = shard.upsert(value);
            return .{
                .index = result.index,
                .updated = result.updated,
                .evicted = result.evicted,
            };
        }
    };
}
