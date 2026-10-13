const std = @import("std");
const wio = @import("wio");

const utils = @import("libs/utils.zig");

/// Up to two buttons that trigger one action.
pub const Binding = struct {
    primary: ?wio.Button = null,
    alternate: ?wio.Button = null,

    pub const Which = enum { primary, alternate };

    /// Returns a pointer to the button in slot `which`, so the settings editor can change it.
    pub fn slot(binding: *Binding, which: Which) *?wio.Button {
        return switch (which) {
            .primary => &binding.primary,
            .alternate => &binding.alternate,
        };
    }

    pub fn buttons(binding: Binding) [2]?wio.Button {
        return .{ binding.primary, binding.alternate };
    }

    fn isAnyIn(binding: Binding, set: ButtonSet) bool {
        for (binding.buttons()) |maybe_button| {
            if (maybe_button) |button| if (set.contains(button)) return true;
        }
        return false;
    }
};

/// The buttons of every action, saved as Keymap.zon. Field order is the order the settings editor lists them.
/// Every field keeps a declaration default, so a file saved before an action existed parses with it bound.
pub const Keymap = struct {
    forward: Binding = .{ .primary = .w },
    backward: Binding = .{ .primary = .s },
    left: Binding = .{ .primary = .a },
    right: Binding = .{ .primary = .d },
    up: Binding = .{ .primary = .space },
    down: Binding = .{ .primary = .left_shift },
    sprint: Binding = .{ .primary = .left_control },
    use_item_primary: Binding = .{ .primary = .mouse_left },
    use_item_secondary: Binding = .{ .primary = .mouse_right },
    use_item_tertiary: Binding = .{ .primary = .f },
    spawn_explosive: Binding = .{ .primary = .t },
    hotbar_slot_1: Binding = .{ .primary = .@"1" },
    hotbar_slot_2: Binding = .{ .primary = .@"2" },
    hotbar_slot_3: Binding = .{ .primary = .@"3" },
    hotbar_slot_4: Binding = .{ .primary = .@"4" },
    hotbar_slot_5: Binding = .{ .primary = .@"5" },
    hotbar_slot_6: Binding = .{ .primary = .@"6" },
    hotbar_slot_7: Binding = .{ .primary = .@"7" },
    hotbar_slot_8: Binding = .{ .primary = .@"8" },
    hotbar_slot_9: Binding = .{ .primary = .@"9" },
    hotbar_slot_10: Binding = .{ .primary = .@"0" },
    hotbar_left: Binding = .{ .primary = .left },
    hotbar_right: Binding = .{ .primary = .right },
    hotbar_up: Binding = .{ .primary = .up },
    hotbar_down: Binding = .{ .primary = .down },
    inventory: Binding = .{ .primary = .e },
    escape_menu: Binding = .{ .primary = .escape, .alternate = .left_gui },
    fullscreen: Binding = .{ .primary = .f11 },
    screenshot: Binding = .{ .primary = .f2 },
    debug_menu: Binding = .{ .primary = .f3 },

    /// Reads the keymap at `path`, writing the defaults there first when the file does not exist yet.
    /// A file that fails to parse is an error, so a typo is never overwritten.
    pub fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Keymap {
        const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .lock = .shared }) catch |err| switch (err) {
            error.FileNotFound => {
                const keymap: Keymap = .{};
                try keymap.save(io, path);
                return keymap;
            },
            else => return err,
        };
        defer file.close(io);
        // A keymap holds no pointers, so parsing allocates nothing that outlives the call.
        return utils.loadZon(Keymap, io, file, gpa, gpa);
    }

    /// Writes the keymap to `path`.
    pub fn save(keymap: *const Keymap, io: std.Io, path: []const u8) !void {
        try utils.saveZon(io, std.Io.Dir.cwd(), path, keymap.*);
    }

    /// Returns the binding of `action`.
    pub fn get(keymap: Keymap, action: Action) Binding {
        return switch (action) {
            inline else => |tag| @field(keymap, @tagName(tag)),
        };
    }

    /// Returns a pointer to the binding of `action`, so the settings editor can change it.
    pub fn binding(keymap: *Keymap, action: Action) *Binding {
        return switch (action) {
            inline else => |tag| &@field(keymap, @tagName(tag)),
        };
    }
};

/// One action for each `Keymap` field, in field order.
pub const Action = std.meta.FieldEnum(Keymap);

pub const ActionSet = std.enums.EnumSet(Action);
pub const ButtonSet = std.enums.EnumSet(wio.Button);

/// One of the two slots of an action, as the settings editor addresses it.
pub const Slot = struct { action: Action, which: Binding.Which };

/// Actions that fire once per press instead of while held.
const single_press: ActionSet = .initMany(&.{
    .escape_menu,   .fullscreen,    .spawn_explosive, .screenshot,     .debug_menu,
    .hotbar_left,   .hotbar_right,  .hotbar_up,       .hotbar_down,    .hotbar_slot_1,
    .hotbar_slot_2, .hotbar_slot_3, .hotbar_slot_4,   .hotbar_slot_5,  .hotbar_slot_6,
    .hotbar_slot_7, .hotbar_slot_8, .hotbar_slot_9,   .hotbar_slot_10, .inventory,
});

/// The number of `hotbar_slot_*` actions.
pub const hotbar_slot_count = 10;

/// The action that selects hotbar column `column`, counting from zero.
pub fn hotbarSlot(column: usize) Action {
    return @fromBackingInt(@intCast(@backingInt(Action.hotbar_slot_1) + column));
}

comptime {
    for (0..hotbar_slot_count) |column| {
        std.debug.assert(hotbarSlot(column) == @field(Action, std.fmt.comptimePrint("hotbar_slot_{d}", .{column + 1})));
    }
}

/// Physical button state. The loop thread folds it into actions once per frame.
pub const Buttons = struct {
    held: ButtonSet = .empty,
    /// Buttons pressed since the last `takeActions`, so a press released within one event batch still counts.
    pressed: ButtonSet = .empty,

    pub fn press(self: *Buttons, button: wio.Button) void {
        self.held.insert(button);
        self.pressed.insert(button);
    }

    pub fn release(self: *Buttons, button: wio.Button) void {
        self.held.remove(button);
    }

    /// Forgets held buttons when the window loses focus, because their releases go to another window.
    pub fn releaseAll(self: *Buttons) void {
        self.held = .empty;
    }

    /// Returns this frame's actions and clears the press set for the next frame.
    /// While `text_focused`, typing triggers no bindings and only Escape still reaches the menu.
    pub fn takeActions(self: *Buttons, keymap: *const Keymap, text_focused: bool) ActionSet {
        defer self.pressed = .empty;
        var actions: ActionSet = .empty;
        // Escape always opens the menu, so no keymap can lock the player out of the settings.
        if (self.pressed.contains(.escape)) actions.insert(.escape_menu);
        if (text_focused) return actions;
        const down = self.held.unionWith(self.pressed);
        for (std.enums.values(Action)) |action| {
            const active = if (single_press.contains(action)) self.pressed else down;
            if (keymap.get(action).isAnyIn(active)) actions.insert(action);
        }
        return actions;
    }
};

test "a held action stays active while another of its buttons is down" {
    var keymap: Keymap = .{};
    keymap.forward.alternate = .up;
    var buttons: Buttons = .{};
    buttons.press(.w);
    buttons.press(.up);
    buttons.release(.w);
    _ = buttons.takeActions(&keymap, false);
    try std.testing.expect(buttons.takeActions(&keymap, false).contains(.forward));
    buttons.releaseAll();
    try std.testing.expect(!buttons.takeActions(&keymap, false).contains(.forward));
}

test "a press released within one batch counts for one frame" {
    const keymap: Keymap = .{};
    var buttons: Buttons = .{};
    buttons.press(.space);
    buttons.release(.space);
    buttons.press(.e);
    buttons.release(.e);
    const first = buttons.takeActions(&keymap, false);
    try std.testing.expect(first.contains(.up) and first.contains(.inventory));
    try std.testing.expectEqual(ActionSet.empty, buttons.takeActions(&keymap, false));
}

test "escape reaches the menu when unbound or while typing" {
    var keymap: Keymap = .{};
    keymap.escape_menu = .{};
    var buttons: Buttons = .{};
    buttons.press(.escape);
    buttons.press(.w);
    const actions = buttons.takeActions(&keymap, true);
    try std.testing.expect(actions.contains(.escape_menu) and !actions.contains(.forward));
}

fn parseKeymapForTest(arena: std.mem.Allocator, source: [:0]const u8) !Keymap {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(Keymap, .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    });
}

test "Keymap zon keeps defaults for missing fields and ignores removed actions" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(arena);
    try std.zon.stringify.serialize(Keymap{}, .{}, &out.writer);
    try std.testing.expectEqual(Keymap{}, try parseKeymapForTest(arena, try out.toOwnedSliceSentinel(0)));

    const parsed = try parseKeymapForTest(arena, ".{ .forward = .{ .primary = .up }, .backward = .{}, .hotbar_scroll_up = .{} }");
    try std.testing.expectEqual(Binding{ .primary = .up }, parsed.forward);
    try std.testing.expectEqual(Binding{}, parsed.backward);
    try std.testing.expectEqual((Keymap{}).left, parsed.left);
}

test {
    std.testing.refAllDecls(@This());
}
