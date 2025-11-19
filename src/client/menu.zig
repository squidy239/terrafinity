const switchMenu = @import("root").SwitchMenu;

const glfw = @import("zglfw");
const gui = @import("gui");
const std = @import("std");
pub const fpsoptions = gui.Element.CreationOptions{
    .elementBackground = .{ .solid = .{ 1, 1, 1, 0.7 } },
    .textOptions = .{
        .text = "",
        .scale = .{ .relative = 5 },
        .startPosition = .{
            .x = .{ .xPercent = 0 },
            .y = .{ .yPercent = 100 },
        },
    },
    .position = .{ .x = .{ .xPercent = 20 }, .y = .{ .yPercent = 85 } },
    .size = .{
        .width = .{ .xPercent = 40 },
        .height = .{ .yPercent = 30 },
    },
    .cornerPixelRadii = .{ .{}, .{}, .{ .pixels = 25 }, .{} },
};

pub const mainMenu = gui.Element.CreationOptions{ .elementBackground = .{ .solid = .{ 0.3, 0.5, 1, 0.7 } }, .position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 50 } }, .size = .{
    .width = .{ .xPercent = 100 },
    .height = .{ .yPercent = 100 },
}, .children = &[_]gui.Element.CreationOptions{
    .{
        .position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 75 } },
        .size = .{
            .width = .{ .xPercent = 50 },
            .height = .{ .pixels = 50 },
        },
        .onHover = openRenderer,
        .textOptions = .{
            .text = "singleplayer",
            .scale = .{ .absolute = 50 },
            .startPosition = .{
                .x = .{ .xPercent = 15 },
                .y = .{ .yPercent = 100 },
            },
        },
    },
    .{
        .position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 25 } },
        .size = .{
            .width = .{ .xPercent = 50 },
            .height = .{ .pixels = 50 },
        },
        .onHover = openOptionsMenu,
        .textOptions = .{
            .text = "options",
            .scale = .{ .absolute = 50 },
            .startPosition = .{
                .x = .{ .xPercent = 15 },
                .y = .{ .yPercent = 100 },
            },
        },
    },
} };

fn openOptionsMenu(element: *gui.Element, mousePos: [2]f64, window: *glfw.Window, toggle: bool) void {
    _ = mousePos;
    _ = element;
    if (toggle and window.getMouseButton(.left) == .press) {
        switchMenu(.optionsMenu) catch |err| std.debug.panic("err: {any}", .{err});
    }
}

fn openRenderer(element: *gui.Element, mousePos: [2]f64, window: *glfw.Window, toggle: bool) void {
    _ = mousePos;
    _ = element;
    if (toggle and window.getMouseButton(.left) == .press) {
        switchMenu(.worldRender) catch |err| std.debug.panic("err: {any}", .{err});
    }
}

fn openMainMenu(element: *gui.Element, mousePos: [2]f64, window: *glfw.Window, toggle: bool) void {
    _ = mousePos;
    _ = element;
    if (toggle and window.getMouseButton(.left) == .press) {
        switchMenu(.mainMenu) catch |err| std.debug.panic("err: {any}", .{err});
    }
}

pub const optionsMenu = gui.Element.CreationOptions{ .elementBackground = .{ .solid = .{ 0.0, 0.0, 0.2, 0.3 } }, .position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 50 } }, .size = .{
    .width = .{ .xPercent = 100 },
    .height = .{ .yPercent = 100 },
}, .children = &[_]gui.Element.CreationOptions{ gui.Widgets.Slider(.{
    .centerPos = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 80 } },
    .size = .{
        .width = .{ .xPercent = 90 },
        .height = .{ .yPercent = 5 },
    },
    .scrollerSize = .{
        .width = .{ .xPercent = 5 },
        .height = .{ .yPercent = 90 },
    },
    .scrollerStartPos = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 50 } },
}, null, .x), gui.Widgets.Slider(.{
    .centerPos = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 50 } },
    .size = .{
        .width = .{ .xPercent = 90 },
        .height = .{ .yPercent = 5 },
    },
    .scrollerSize = .{
        .width = .{ .xPercent = 5 },
        .height = .{ .yPercent = 90 },
    },
    .scrollerStartPos = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 50 } },
}, null, .x), gui.Widgets.Slider(.{
    .centerPos = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 20 } },
    .size = .{
        .width = .{ .xPercent = 90 },
        .height = .{ .yPercent = 5 },
    },
    .scrollerSize = .{
        .width = .{ .xPercent = 5 },
        .height = .{ .yPercent = 90 },
    },
    .scrollerStartPos = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 50 } },
}, null, .x), gui.Element.CreationOptions{
    .position = .{ .x = .{ .xPercent = 100, .pixels = -50 }, .y = .{ .yPercent = 100, .pixels = -50 } },
    .size = .{
        .width = .{ .pixels = 50 },
        .height = .{ .pixels = 50 },
    },
    .elementBackground = .{ .solid = .{ 1.0, 0.0, 0.0, 1.0 } },
    .onHover = openMainMenu,
    .textOptions = .{
        .text = "X",
        .scale = .{ .absolute = 25 },
        .startPosition = .{
            .x = .{ .xPercent = 50 },
            .y = .{ .yPercent = 50 },
        },
    },
} } };

const ToggleSettings = @import("UserInput.zig").ToggleSettings;

pub const textEscMenu = gui.Element.CreationOptions{
    .elementBackground = .{ .solid = .{ 0.8, 0.8, 0.8, 0.95 } },
    .position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 50 } },
    .size = .{
        .width = .{ .xPercent = 75 },
        .height = .{ .yPercent = 75 },
    },
    .cornerPixelRadii = @splat(.{ .pixels = 25 }),
    .children = &.{
        .{ //TODO move menu out of this and redo user input handeling
            .elementBackground = .{ .solid = .{ 0.8, 0.3, 0.3, 1 } },
            .position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 60 } },
            .size = .{
                .width = .{ .xPercent = 60 },
                .height = .{ .yPercent = 10 },
            },
            .textOptions = .{
                .text = "Quit",
                .scale = .{ .relative = 4 },
                .startPosition = .{
                    .x = .{ .xPercent = 45 },
                    .y = .{ .yPercent = 100 },
                },
            },
            .onHover = onHoverEsc,
            .cornerPixelRadii = @splat(.{ .pixels = 15 }),
        },
        .{ //TODO move menu out of this and redo user input handeling
            .elementBackground = .{ .solid = .{ 0.3, 0.8, 0.3, 1 } },
            .position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 80 } },
            .size = .{
                .width = .{ .xPercent = 60 },
                .height = .{ .yPercent = 10 },
            },
            .textOptions = .{
                .text = "Back to Game",
                .scale = .{ .relative = 4 },
                .startPosition = .{
                    .x = .{ .xPercent = 35 },
                    .y = .{ .yPercent = 100 },
                },
            },
            .onHover = onHoverC,
            .cornerPixelRadii = @splat(.{ .pixels = 15 }),
        },
        gui.Widgets.Slider(.{ //TODO move menu out of this and redo user input handeling
            .size = .{ .height = .{ .yPercent = 100 }, .width = .{ .pixels = 50 } },
            .centerPos = .{ .x = .{ .xPercent = 100, .pixels = -50 }, .y = .{ .yPercent = 50 } },
        }, null, .y),
    },
};

fn onHoverEsc(element: *gui.Element, mouse_pos: [2]f64, window: *glfw.Window, toggle: bool) void {
    _ = mouse_pos;
    if (toggle) {
        element.options.size.height.pixels += 5;
        element.options.size.width.pixels += 5;
        element.options.elementBackground.solid += @Vector(4, f32){ 0.1, 0.1, 0.1, 0.0 };
        if (window.getMouseButton(glfw.MouseButton.left) == .press) {
            window.setShouldClose(true);
        }
        element.update();
    } else {
        element.options.size.height.pixels -= 5;
        element.options.size.width.pixels -= 5;
        element.options.elementBackground.solid -= @Vector(4, f32){ 0.1, 0.1, 0.1, 0.0 };
        element.update();
    }
}

fn onHoverC(element: *gui.Element, mouse_pos: [2]f64, window: *glfw.Window, toggle: bool) void {
    _ = mouse_pos;
    const ts: *ToggleSettings = @ptrCast(element.onHoverArgs.?);
    if (toggle) {
        element.options.size.width.pixels += 5;
        element.options.size.height.pixels += 5;

        element.options.elementBackground.solid += @Vector(4, f32){ 0.1, 0.1, 0.1, 0.0 };
        if (window.getMouseButton(glfw.MouseButton.left) == .press and ts.CursorEscaped) {
            ts.CursorEscaped = false;
            _ = glfw.Window.setInputMode(window, glfw.InputMode.cursor, glfw.InputMode.ValueType(glfw.InputMode.cursor).disabled) catch std.debug.panic("err cant set input mode\n", .{});
        }
        element.update();
    } else {
        element.options.size.width.pixels -= 5;
        element.options.size.height.pixels -= 5;

        element.options.elementBackground.solid -= @Vector(4, f32){ 0.1, 0.1, 0.1, 0.0 };
        element.update();
    }
}
