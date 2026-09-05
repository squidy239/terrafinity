const std = @import("std");
const wio = @import("wio");

pub const Action = enum {
    forward,
    backward,
    left,
    right,
    up,
    down,
    escape_menu,
    hotbar_key_0,
    hotbar_key_1,
    hotbar_key_2,
    hotbar_key_3,
    hotbar_key_4,
    hotbar_key_5,
    hotbar_key_6,
    hotbar_key_7,
    hotbar_key_8,
    hotbar_key_9,
    hotbar_scroll_up,
    hotbar_scroll_down,
    use_item_primary,
    use_item_secondary,
    use_item_tertiary,
    use_item_quaternary,
    spawn_explosive,
    fullscreen,
    screenshot,
    debug_menu,
};

pub const ActionSet = std.enums.EnumSet(Action);
pub const Singlepress = std.enums.EnumSet(Action);

const Keys = wio.Button;

pub const Key = struct {
    key: Keys,
};

// Single-threaded: written once during init, read on the loop thread only.
// Do not share across threads without adding synchronization.
pub const Map = struct {
    map: std.AutoHashMap(Key, Action),

    pub fn init(allocator: std.mem.Allocator) Map {
        return .{
            .map = .init(allocator),
        };
    }

    pub fn setActionKey(self: *Map, key: Key, action: Action) !void {
        try self.map.put(key, action);
    }

    pub fn getAction(self: *Map, key: Key) ?Action {
        return self.map.get(key);
    }
};
