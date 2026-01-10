const std = @import("std");
const sdl = @import("sdl3");

pub const Action = enum {
    forward,
    backward,
    left,
    right,
    jump,
    escape_menu,
};

pub const ActionSet = std.enums.EnumSet(Action);
pub const Singlepress = std.enums.EnumSet(Action);

const Keys = sdl.keycode.Keycode;
const Modifier = sdl.keycode.KeyModifier;

pub const Key = struct {
    key: Keys,
    modifier: Modifier = .{},
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
