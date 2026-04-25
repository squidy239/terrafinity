const std = @import("std");
const wio = @import("wio").wio;

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

const Keys = wio.Button;

pub const Key = struct {
    key: Keys,
};

pub const Map = struct {
    lock: std.Io.RwLock = .init,
    map: std.AutoHashMap(Key, Action),

    pub fn init(allocator: std.mem.Allocator) Map {
        return .{
            .map = std.AutoHashMap(Key, Action).init(allocator),
        };
    }

    pub fn setActionKey(self: *Map, io: std.Io, key: Key, action: Action) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        try self.map.put(key, action);
    }

    pub fn getAction(self: *Map, io: std.Io, key: Key) ?Action {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        return self.map.get(key);
    }
};
