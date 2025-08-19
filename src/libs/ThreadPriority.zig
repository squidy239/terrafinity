const builtin = @import("builtin");
const std = @import("std");
pub const HANDLE = *anyopaque;

extern "kernel32" fn SetThreadPriority(hThread: HANDLE, nPriority: i32) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;

pub fn setThreadPriority(priority: Priority) bool {
    return switch (builtin.os.tag) {
        .windows => (SetThreadPriority(std.os.windows.GetCurrentThread(), @intFromEnum(priority)) != 0),
        .linux => false, //TODO
        else => false,
    };
}

const Priority = enum(i32) {
    THREAD_PRIORITY_TIME_CRITICAL = 15,
    THREAD_PRIORITY_HIGHEST = 2,
    THREAD_PRIORITY_ABOVE_NORMAL = 1,
    THREAD_PRIORITY_NORMAL = 0,
    THREAD_PRIORITY_BELOW_NORMAL = -1,
    THREAD_PRIORITY_LOWEST = -2,
    THREAD_PRIORITY_IDLE = -15,
};
