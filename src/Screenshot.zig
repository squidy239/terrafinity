const std = @import("std");
const vk = @import("vulkan");

/// Selectable screenshot resolutions. Native uses current swapchain size.
pub const Resolution = enum {
    native,
    @"720p",
    @"1080p",
    @"1440p",
    @"4k",
    @"8k",

    pub fn label(self: @This()) []const u8 {
        return switch (self) {
            .native => "Native (Window)",
            .@"720p" => "1280 x 720 (HD)",
            .@"1080p" => "1920 x 1080 (Full HD)",
            .@"1440p" => "2560 x 1440 (QHD)",
            .@"4k" => "3840 x 2160 (4K UHD)",
            .@"8k" => "7680 x 4320 (8K UHD)",
        };
    }

    pub fn targetExtent(self: @This(), native: vk.Extent2D) vk.Extent2D {
        return switch (self) {
            .native => native,
            .@"720p" => .{ .width = 1280, .height = 720 },
            .@"1080p" => .{ .width = 1920, .height = 1080 },
            .@"1440p" => .{ .width = 2560, .height = 1440 },
            .@"4k" => .{ .width = 3840, .height = 2160 },
            .@"8k" => .{ .width = 7680, .height = 4320 },
        };
    }
};
