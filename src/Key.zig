const std = @import("std");
const sdl = @import("sdl3");

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
};

pub const ActionSet = std.enums.EnumSet(Action);
pub const Singlepress = std.enums.EnumSet(Action);

const Keys = sdl.keycode.Keycode;
const Modifier = sdl.keycode.KeyModifier;

pub const Key = struct {
    key: Keys,
    modifier: ?Modifier = null,
};

pub const Map = struct {
    lock: std.Thread.RwLock = .{},
    map: std.AutoHashMap(Key, Action),

    pub fn init(allocator: std.mem.Allocator) Map {
        return .{
            .map = std.AutoHashMap(Key, Action).init(allocator),
            .lock = .{},
        };
    }

    pub fn setActionKey(self: *Map, key: Key, action: Action) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.map.put(key, action);
    }

    pub fn getAction(self: *Map, key: Key) ?Action {
        self.lock.lock();
        defer self.lock.unlock();
        return self.map.get(key);
    }
};
