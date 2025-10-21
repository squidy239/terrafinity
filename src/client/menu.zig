const gui = @import("gui");

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
