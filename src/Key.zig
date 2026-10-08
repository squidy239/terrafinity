const std = @import("std");
const wio = @import("wio");

pub const Action = enum {
    forward,
    backward,
    left,
    right,
    up,
    down,
    sprint,
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
    hotbar_left,
    hotbar_right,
    hotbar_up,
    hotbar_down,
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

/// Actions that fire once per press instead of while held.
pub const single_press: ActionSet = .initMany(&.{
    .escape_menu,  .fullscreen,   .spawn_explosive, .screenshot,   .debug_menu,
    .hotbar_left,  .hotbar_right, .hotbar_up,       .hotbar_down,  .hotbar_key_0,
    .hotbar_key_1, .hotbar_key_2, .hotbar_key_3,    .hotbar_key_4, .hotbar_key_5,
    .hotbar_key_6, .hotbar_key_7, .hotbar_key_8,    .hotbar_key_9,
});

/// The action each button triggers. Read only on the loop thread; rebinding is a `put`.
pub const Map = std.enums.EnumMap(wio.Button, Action);
