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
