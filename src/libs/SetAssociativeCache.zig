// This file is a slightly modified version of the Tigerbeetle SetAssociativeCache
// https://github.com/tigerbeetle/tigerbeetle/blob/main/src/lsm/set_associative_cache.zig

const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;

/// The comptime shape of a `SetAssociativeCacheType`.
pub const Layout = struct {
    ways: u64 = 16,
    tag_bits: u64 = 8,
    clock_bits: u64 = 2,
    cache_line_size: u64 = 64,
    /// Set this to a non-null value to override the alignment of the stored values.
    value_alignment: ?u29 = null,
};

const Metrics = struct {
    hits: std.atomic.Value(u64) = .init(0),
    misses: std.atomic.Value(u64) = .init(0),
    value_count: std.atomic.Value(u64) = .init(0),
};

/// A cache where the hash of each Key selects a set of `layout.ways` consecutive slots.
/// Only the slots of that set can hold the Value.
pub fn SetAssociativeCacheType(
    comptime Key: type,
    comptime Value: type,
    comptime key_from_value: fn (*const Value) callconv(.@"inline") Key,
    comptime hash: fn (Key) callconv(.@"inline") u64,
    comptime layout: Layout,
) type {
    assert(math.isPowerOfTwo(@sizeOf(Key)));

    switch (layout.ways) {
        // An 8-way set-associative cache has the clock hand as a u3, which would introduce padding.
        2, 4, 16 => {},
        else => @compileError("ways must be 2, 4 or 16 for optimal CLOCK hand size."),
    }
    switch (layout.tag_bits) {
        8, 16 => {},
        else => @compileError("tag_bits must be 8 or 16."),
    }
    switch (layout.clock_bits) {
        1, 2, 4 => {},
        else => @compileError("clock_bits must be 1, 2 or 4."),
    }

    if (layout.value_alignment) |alignment| {
        assert(alignment >= @alignOf(Value));
        assert(@sizeOf(Value) % alignment == 0);
    }
    const value_alignment = layout.value_alignment orelse @alignOf(Value);

    assert(math.isPowerOfTwo(layout.cache_line_size));

    assert(@sizeOf(Key) <= @sizeOf(Value));
    assert(@sizeOf(Key) < layout.cache_line_size);
    assert(layout.cache_line_size % @sizeOf(Key) == 0);

    const clock_hand_bits = math.log2_int(u64, layout.ways);
    assert(math.isPowerOfTwo(clock_hand_bits));
    assert((1 << clock_hand_bits) == layout.ways);

    const tags_per_line = @divExact(layout.cache_line_size * 8, layout.ways * layout.tag_bits);
    assert(tags_per_line > 0);

    const clocks_per_line = @divExact(layout.cache_line_size * 8, layout.ways * layout.clock_bits);
    assert(clocks_per_line > 0);

    const clock_hands_per_line = @divExact(layout.cache_line_size * 8, clock_hand_bits);
    assert(clock_hands_per_line > 0);

    return struct {
        const SetAssociativeCache = @This();

        const Tag = @Int(.unsigned, layout.tag_bits);
        const Count = @Int(.unsigned, layout.clock_bits);
        const Clock = @Int(.unsigned, clock_hand_bits);

        /// The set size: `value_count_max` in `init` must be a positive multiple of it,
        /// so it is also the smallest valid `value_count_max`.
        pub const value_count_min: u64 = layout.ways;

        metrics: *Metrics,

        /// A short, partial hash of a Key, corresponding to a Value.
        /// Because the tag is small, collisions are possible:
        /// `tag(v₁) = tag(v₂)` does not imply `v₁ = v₂`.
        /// However, most of the time, where the tag differs, a full key comparison can be avoided.
        /// Since tags are 16-32x smaller than keys, they can also be kept hot in cache.
        tags: []Tag,

        /// When the corresponding Count is zero, the Value is absent.
        values: []align(value_alignment) Value,

        /// Each value has a Count of its recent reads.
        /// `get` increments it, a cache write that misses the value's set decrements it,
        /// and the cache evicts the value when it reaches zero.
        counts: PackedUnsignedIntegerArrayType(Count),

        /// Each set has a Clock hand that cycles through the ways (slots) of the set.
        /// A cache write starts its search for a free or evictable way at the hand and wraps around.
        /// This is "CLOCK Nth-Chance": each way has more than one count bit, so it gets more
        /// than one chance before eviction. See "RRIParoo" in "Kangaroo: Caching Billions of
        /// Tiny Objects on Flash", and https://en.wikipedia.org/wiki/Page_replacement_algorithm.
        clocks: PackedUnsignedIntegerArrayType(Clock),

        /// Allocates an empty cache with `value_count_max` slots.
        pub fn init(allocator: mem.Allocator, value_count_max: u64) !SetAssociativeCache {
            assert(value_count_max >= value_count_min);
            assert(value_count_max % layout.ways == 0);

            const sets = @divExact(value_count_max, layout.ways);

            const counts_size = @divCeil(value_count_max * layout.clock_bits, 8);

            // Clock hands never span cache lines by construction. Rounding clocks
            // up to a byte keeps the contract: `value_count_max` needs only a multiple of `ways`.
            const clocks_size = @divCeil(sets * clock_hand_bits, 8);

            const tags = try allocator.alloc(Tag, value_count_max);
            errdefer allocator.free(tags);

            const values = try allocator.alignedAlloc(
                Value,
                std.mem.Alignment.fromByteUnits(value_alignment),
                value_count_max,
            );
            errdefer allocator.free(values);

            const counts = try allocator.alloc(u64, @divCeil(counts_size, @sizeOf(u64)));
            errdefer allocator.free(counts);

            const clocks = try allocator.alloc(u64, @divCeil(clocks_size, @sizeOf(u64)));
            errdefer allocator.free(clocks);

            // A separate allocation lets `get` take `*const SetAssociativeCache`.
            const metrics = try allocator.create(Metrics);
            errdefer allocator.destroy(metrics);

            var self = SetAssociativeCache{
                .tags = tags,
                .values = values,
                .counts = .{ .words = counts },
                .clocks = .{ .words = clocks },
                .metrics = metrics,
            };

            self.reset();

            return self;
        }

        /// Frees the memory of the cache.
        pub fn deinit(self: *SetAssociativeCache, allocator: mem.Allocator) void {
            allocator.free(self.tags);
            allocator.free(self.values);
            allocator.free(self.counts.words);
            allocator.free(self.clocks.words);
            allocator.destroy(self.metrics);
        }

        /// Removes all values and clears the metrics.
        pub fn reset(self: *SetAssociativeCache) void {
            @memset(self.tags, 0);
            @memset(self.counts.words, 0);
            @memset(self.clocks.words, 0);
            self.metrics.* = .{};
        }

        /// Visits each value that the cache holds.
        pub const Iterator = struct {
            cache: *const SetAssociativeCache,
            index: usize = 0,

            /// Returns a pointer to the next active Value in the cache, or null if iteration is complete.
            pub fn next(it: *Iterator) ?*align(value_alignment) Value {
                while (it.index < it.cache.values.len) {
                    const current_index = it.index;
                    it.index += 1;

                    if (it.cache.counts.get(current_index) > 0) {
                        return @alignCast(&it.cache.values[current_index]);
                    }
                }
                return null;
            }
        };

        /// Returns an iterator over all currently active items in the cache.
        pub fn iterator(self: *const SetAssociativeCache) Iterator {
            return .{ .cache = self };
        }

        /// Returns the value for `key`, or null when the cache does not hold it.
        /// It gives the value one more read.
        pub fn get(self: *const SetAssociativeCache, key: Key) ?*align(value_alignment) Value {
            const set = self.associate(key);
            const way = self.search(set, key) orelse {
                _ = self.metrics.misses.fetchAdd(1, .acq_rel);
                return null;
            };
            _ = self.metrics.hits.fetchAdd(1, .acq_rel);
            self.counts.set(set.offset + way, self.counts.get(set.offset + way) +| 1);
            return @alignCast(&set.values[way]);
        }

        /// Removes `key` and returns its value, or null when the cache does not hold it.
        pub fn remove(self: *SetAssociativeCache, key: Key) ?Value {
            const set = self.associate(key);
            const way = self.search(set, key) orelse return null;

            const removed: Value = set.values[way];
            self.counts.set(set.offset + way, 0);
            set.values[way] = undefined;
            _ = self.metrics.value_count.fetchSub(1, .acq_rel);

            return removed;
        }

        /// If the key is present in the set, returns the way. Otherwise returns null.
        inline fn search(self: *const SetAssociativeCache, set: Set, key: Key) ?u16 {
            const ways: u16 = searchTags(set.tags, set.tag);
            if (ways == 0) return null;

            // Iterate over all ways to help the OOO execution.
            for (0..layout.ways) |way| {
                if ((ways >> @as(u4, @intCast(way)) & 1) == 1 and
                    self.counts.get(set.offset + way) > 0)
                {
                    if (std.meta.eql(key_from_value(&set.values[way]), key)) {
                        return @intCast(way);
                    }
                }
            }
            return null;
        }

        /// Where each set bit represents the index of a way that has the same tag.
        const Ways = @Int(.unsigned, layout.ways);

        inline fn searchTags(tags: *const [layout.ways]Tag, tag: Tag) Ways {
            const x: @Vector(layout.ways, Tag) = tags.*;
            const y: @Vector(layout.ways, Tag) = @splat(tag);

            const result: @Vector(layout.ways, bool) = x == y;
            return @bitCast(result);
        }
        const Victim = struct { way: Clock, occupied: bool };

        /// Returns a copy of the counts of the set at `offset`.
        fn setCounts(self: *const SetAssociativeCache, offset: u64) [layout.ways]Count {
            var counts: [layout.ways]Count = undefined;
            for (&counts, 0..) |*count, i| count.* = self.counts.get(offset + i);
            return counts;
        }

        /// Runs one CLOCK pass over `counts` from `hand`, decrementing counts until
        /// a free slot appears. Returns the victim way and whether it holds a value.
        fn clockVictim(counts: *[layout.ways]Count, hand: Clock) Victim {
            comptime assert(math.maxInt(Clock) == layout.ways - 1);
            comptime assert(@as(Clock, math.maxInt(Clock)) +% 1 == 0);

            // Worst case: every slot holds the max count, so the loop clears
            // all counts to 1, then frees one slot on the next pass.
            const clock_iterations_max = layout.ways * (math.maxInt(Count) - 1);

            var way = hand;
            for (0..clock_iterations_max + 1) |_| {
                const count = &counts[way];
                if (count.* == 0) return .{ .way = way, .occupied = false };
                count.* -= 1;
                if (count.* == 0) return .{ .way = way, .occupied = true };
                way +%= 1;
            }
            unreachable;
        }

        /// Runs the CLOCK pass on the set's real counts and stores the decremented counts.
        fn findVictim(self: *SetAssociativeCache, set: Set, clock_index: u64) Victim {
            var counts = self.setCounts(set.offset);
            const victim = clockVictim(&counts, self.clocks.get(clock_index));
            for (counts, 0..) |count, i| self.counts.set(set.offset + i, count);
            return victim;
        }

        /// The result of `upsert`.
        pub const Upserted = struct { evicted: ?Value };

        /// Inserts or replaces a value and evicts an older value when the set is full.
        /// Returns the evicted or replaced value.
        pub fn upsert(self: *SetAssociativeCache, value: *const Value) Upserted {
            const slot = self.claimSlot(key_from_value(value));
            const evicted: ?Value = if (slot.occupied) slot.value.* else null;
            slot.value.* = value.*;
            return .{ .evicted = evicted };
        }

        /// Like `upsert`, but returns the slot for `key` and does not copy a value in.
        /// Thus the caller can write a large value outside the lock. The caller must write
        /// the key before the next lookup, because the slot keeps its old contents.
        pub fn claim(self: *SetAssociativeCache, key: Key) *align(value_alignment) Value {
            return self.claimSlot(key).value;
        }

        /// Returns the slot for `key`, which is the slot of `key` or a CLOCK victim, and
        /// whether that slot holds a value.
        fn claimSlot(self: *SetAssociativeCache, key: Key) struct {
            value: *align(value_alignment) Value,
            occupied: bool,
        } {
            const set = self.associate(key);
            if (self.search(set, key)) |way| {
                self.counts.set(set.offset + way, 1);
                return .{ .value = @alignCast(&set.values[way]), .occupied = true };
            }

            const clock_index = @divExact(set.offset, layout.ways);
            const victim = self.findVictim(set, clock_index);
            set.tags[victim.way] = set.tag;
            self.counts.set(set.offset + victim.way, 1);
            self.clocks.set(clock_index, victim.way +% 1);
            if (!victim.occupied) _ = self.metrics.value_count.fetchAdd(1, .acq_rel);
            return .{ .value = @alignCast(&set.values[victim.way]), .occupied = victim.occupied };
        }

        /// Returns the value that `upsert` with this key replaces or evicts.
        /// Returns null when `upsert` uses an empty slot.
        pub fn peekVictim(self: *const SetAssociativeCache, key: Key) ?*align(value_alignment) Value {
            const set = self.associate(key);
            if (self.search(set, key)) |way| return @alignCast(&set.values[way]);

            // A peek cannot change counts, so the CLOCK pass runs on a copy of this set.
            var counts = self.setCounts(set.offset);
            const victim = clockVictim(&counts, self.clocks.get(@divExact(set.offset, layout.ways)));
            return if (victim.occupied) @alignCast(&set.values[victim.way]) else null;
        }

        /// Skips the current eviction candidate in the set of `key`.
        /// It runs the CLOCK algorithm to find the candidate, sets its count to 1,
        /// and moves the clock hand past it.
        pub fn skipVictim(self: *SetAssociativeCache, key: Key) void {
            const set = self.associate(key);

            // An existing key updates in place, so no victim exists.
            if (self.search(set, key) != null) return;

            const clock_index = @divExact(set.offset, layout.ways);
            const way = self.findVictim(set, clock_index).way;
            self.counts.set(set.offset + way, 1);
            self.clocks.set(clock_index, way +% 1);
        }

        const Set = struct {
            tag: Tag,
            offset: u64,
            tags: *[layout.ways]Tag,
            values: *[layout.ways]Value,
        };

        inline fn associate(self: *const SetAssociativeCache, key: Key) Set {
            const entropy = hash(key);

            const tag: Tag = @truncate(entropy);
            const index = fastrange(entropy, self.tags.len / layout.ways);
            const offset = index * layout.ways;

            return .{
                .tag = tag,
                .offset = offset,
                .tags = self.tags[offset..][0..layout.ways],
                .values = self.values[offset..][0..layout.ways],
            };
        }
    };
}

inline fn testKeyFromValue(value: *const u64) u64 {
    return value.*;
}

fn expectEviction(comptime hash: fn (u64) callconv(.@"inline") u64) !void {
    const testing = std.testing;
    const expect = testing.expect;
    const expectEqual = testing.expectEqual;
    const layout: Layout = .{};
    const Sac = SetAssociativeCacheType(u64, u64, testKeyFromValue, hash, layout);

    const checks = struct {
        fn expectEmpty(sac: *const Sac) !void {
            for (sac.tags) |tag| try expectEqual(@as(Sac.Tag, 0), tag);
            for (sac.counts.words) |word| try expectEqual(@as(u64, 0), word);
            for (sac.clocks.words) |word| try expectEqual(@as(u64, 0), word);
            try expectEqual(@as(u64, 0), sac.metrics.value_count.raw);
        }

        // Inserts one more key into the full first set, which evicts key 0.
        fn expectFirstKeyEvicted(sac: *Sac, sets: u64) !void {
            const key = layout.ways * sets;
            _ = sac.upsert(&key);
            try expect(sac.counts.get(0) == 1);
            try expectEqual(key, sac.get(key).?.*);
            try expect(sac.counts.get(0) == 2);

            try expectEqual(@as(?*u64, null), sac.get(0));
            for (1..layout.ways) |way| try expect(sac.counts.get(way) == 1);
            try expectEqual(@as(u64, layout.ways), sac.metrics.value_count.raw);
        }
    };

    var sac = try Sac.init(testing.allocator, Sac.value_count_min);
    defer sac.deinit(testing.allocator);
    const sets = sac.tags.len / layout.ways;

    try checks.expectEmpty(&sac);
    for (0..layout.ways) |way| {
        try expectEqual(way, sac.clocks.get(0));

        const key = way * sets;
        _ = sac.upsert(&key);
        try expect(sac.counts.get(way) == 1);
        try expectEqual(key, sac.get(key).?.*);
        try expect(sac.counts.get(way) == 2);
    }
    try expect(sac.clocks.get(0) == 0);
    try expectEqual(@as(u64, layout.ways), sac.metrics.value_count.raw);
    try checks.expectFirstKeyEvicted(&sac, sets);

    {
        const key = 5 * sets;
        try expectEqual(key, sac.get(key).?.*);
        try expect(sac.counts.get(5) == 2);

        _ = sac.remove(key);
        try expectEqual(@as(?*u64, null), sac.get(key));
        try expect(sac.counts.get(5) == 0);
        try expectEqual(@as(u64, layout.ways - 1), sac.metrics.value_count.raw);
    }

    sac.reset();

    try checks.expectEmpty(&sac);
    for (0..layout.ways) |way| {
        try expectEqual(way, sac.clocks.get(0));

        const key = way * sets;
        _ = sac.upsert(&key);
        try expect(sac.counts.get(way) == 1);
        for (2..math.maxInt(Sac.Count) + 1) |count| {
            try expectEqual(key, sac.get(key).?.*);
            try expect(sac.counts.get(way) == count);
        }
        try expectEqual(key, sac.get(key).?.*);
        try expect(sac.counts.get(way) == math.maxInt(Sac.Count));
    }
    try expect(sac.clocks.get(0) == 0);
    try expectEqual(@as(u64, layout.ways), sac.metrics.value_count.raw);
    try checks.expectFirstKeyEvicted(&sac, sets);
}

test "SetAssociativeCache: eviction" {
    try expectEviction(struct {
        inline fn hash(key: u64) u64 {
            return key;
        }
    }.hash);
}

test "SetAssociativeCache: hash collision" {
    // Every key hashes to 0, so all tags and sets collide.
    try expectEviction(struct {
        inline fn hash(_: u64) u64 {
            return 0;
        }
    }.hash);
}

/// A little simpler than PackedIntArray in the std lib, restricted to little endian 64-bit words,
/// and using words exactly without padding.
fn PackedUnsignedIntegerArrayType(comptime UInt: type) type {
    const Word = u64;

    assert(builtin.target.cpu.arch.endian() == .little);
    assert(@typeInfo(UInt).int.signedness == .unsigned);
    assert(@typeInfo(UInt).int.bits < @bitSizeOf(u8));
    assert(math.isPowerOfTwo(@typeInfo(UInt).int.bits));

    const word_bits = @bitSizeOf(Word);
    const uint_bits = @bitSizeOf(UInt);
    const uints_per_word = @divExact(word_bits, uint_bits);

    // An index bounded by the number of unsigned integers that fit exactly into a word.
    const WordIndex = @Int(.unsigned, math.log2_int(u64, uints_per_word));
    assert(math.maxInt(WordIndex) == uints_per_word - 1);

    // An index bounded by the number of bits (not unsigned integers) that fit exactly into a word.
    const BitsIndex = math.Log2Int(Word);
    assert(math.maxInt(BitsIndex) == word_bits - 1);
    assert(math.maxInt(BitsIndex) == uint_bits * (math.maxInt(WordIndex) + 1) - 1);

    return struct {
        const PackedUnsignedIntegerArray = @This();

        words: []Word,

        /// Returns the unsigned integer at `index`.
        pub inline fn get(self: PackedUnsignedIntegerArray, index: u64) UInt {
            // This truncate is safe since we want to mask the right-shifted word by exactly a UInt:
            return @as(UInt, @truncate(self.word(index).* >> bitsIndex(index)));
        }

        /// Sets the unsigned integer at `index` to `value`.
        pub inline fn set(self: PackedUnsignedIntegerArray, index: u64, value: UInt) void {
            const w = self.word(index);
            w.* &= ~mask(index);
            w.* |= @as(Word, value) << bitsIndex(index);
        }

        inline fn mask(index: u64) Word {
            return @as(Word, math.maxInt(UInt)) << bitsIndex(index);
        }

        inline fn word(self: PackedUnsignedIntegerArray, index: u64) *Word {
            return &self.words[@divFloor(index, uints_per_word)];
        }

        inline fn bitsIndex(index: u64) BitsIndex {
            // If uint_bits=2, then it's normal for the maximum return value value to be 62, even
            // where BitsIndex allows up to 63 (inclusive) for a 64-bit word. This is because 62 is
            // the bit index of the highest 2-bit UInt (e.g. bit index + bit length == 64).
            comptime assert(uint_bits * (math.maxInt(WordIndex) + 1) == math.maxInt(BitsIndex) + 1);

            return @as(BitsIndex, uint_bits) * @as(WordIndex, @truncate(index));
        }
    };
}

test "PackedUnsignedIntegerArray: unit" {
    const expectEqual = std.testing.expectEqual;

    var words = [8]u64{ 0, 0b10110010, 0, 0, 0, 0, 0, 0 };

    var p: PackedUnsignedIntegerArrayType(u2) = .{
        .words = &words,
    };

    try expectEqual(@as(u2, 0b10), p.get(32 + 0));
    try expectEqual(@as(u2, 0b00), p.get(32 + 1));
    try expectEqual(@as(u2, 0b11), p.get(32 + 2));
    try expectEqual(@as(u2, 0b10), p.get(32 + 3));

    p.set(0, 0b01);
    try expectEqual(@as(u64, 0b00000001), words[0]);
    try expectEqual(@as(u2, 0b01), p.get(0));
    p.set(1, 0b10);
    try expectEqual(@as(u64, 0b00001001), words[0]);
    try expectEqual(@as(u2, 0b10), p.get(1));
    p.set(2, 0b11);
    try expectEqual(@as(u64, 0b00111001), words[0]);
    try expectEqual(@as(u2, 0b11), p.get(2));
    p.set(3, 0b11);
    try expectEqual(@as(u64, 0b11111001), words[0]);
    try expectEqual(@as(u2, 0b11), p.get(3));
    p.set(3, 0b01);
    try expectEqual(@as(u64, 0b01111001), words[0]);
    try expectEqual(@as(u2, 0b01), p.get(3));
    p.set(3, 0b00);
    try expectEqual(@as(u64, 0b00111001), words[0]);
    try expectEqual(@as(u2, 0b00), p.get(3));

    p.set(4, 0b11);
    try expectEqual(
        @as(u64, 0b0000000000000000000000000000000000000000000000000000001100111001),
        words[0],
    );
    p.set(31, 0b11);
    try expectEqual(
        @as(u64, 0b1100000000000000000000000000000000000000000000000000001100111001),
        words[0],
    );
}

/// Maps `word` uniformly onto `[0, p)` with a multiply instead of a modulo.
inline fn fastrange(word: u64, p: u64) u64 {
    return @truncate(@as(u128, word) * p >> 64);
}

test {
    std.testing.refAllDecls(@This());
}
