const builtin = @import("builtin");
const std = @import("std");

extern "kernel32" fn SetThreadPriority(hThread: std.posix.pid_t, nPriority: i32) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
extern "c" fn pthread_self() u64;
extern "c" fn pthread_setschedparam(thread: u64, policy: c_int, param: *sched_param) c_int;
extern "c" fn pthread_getschedparam(thread: u64, policy: *c_int, param: *sched_param) c_int;
extern "c" fn pthread_setschedprio(thread: u64, prio: c_int) c_int;

pub const timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

pub const sched_param = extern struct {
    pub const __ss = extern struct {
        __ss_low_priority: i32,
        __ss_max_repl: i32,
        __ss_repl_period: timespec,
        __ss_init_budget: timespec,
    };

    pub const __Ss_Un = extern union {
        reserved: [8]i32,
        ss: __ss,
    };

    sched_priority: i32,
    sched_curpriority: i32,
    __ss_un: __Ss_Un,
};

pub fn setThreadPriority(priority: Priority) bool {
    return switch (builtin.os.tag) {
        .windows => (SetThreadPriority(std.os.windows.GetCurrentThread(), @intFromEnum(priority)) != 0),
        .linux => {
            if (priority == Priority.THREAD_PRIORITY_REALTIME or priority == Priority.THREAD_PRIORITY_IDLE) {
                var param: sched_param = undefined;
                var policy: SchedPolicy = if (priority == Priority.THREAD_PRIORITY_REALTIME) .SCHED_FIFO else .SCHED_IDLE;
                const self = pthread_self();
                const getsucc = pthread_getschedparam(self, @ptrCast(&policy), &param);
                if (getsucc != 0) {
                    std.log.err("Failed to get thread data: {d}", .{getsucc});
                    return false;
                }
                const setsucc = pthread_setschedparam(self, @intFromEnum(policy), &param);
                if (setsucc != 0) {
                    std.log.err("Failed to set thread data: {d}", .{setsucc});
                    return false;
                }
                return true;
            } else return false;
        },
        else => false,
    };
}

const Priority = enum(i32) {
    THREAD_PRIORITY_REALTIME = 15,
    THREAD_PRIORITY_HIGHEST = 2,
    THREAD_PRIORITY_ABOVE_NORMAL = 1,
    THREAD_PRIORITY_NORMAL = 0,
    THREAD_PRIORITY_BELOW_NORMAL = -1,
    THREAD_PRIORITY_LOWEST = -2,
    THREAD_PRIORITY_IDLE = -15,
};

const SchedPolicy = enum(c_int) {
    SCHED_OTHER = 0,
    SCHED_FIFO = 1,
    SCHED_RR = 2,
    SCHED_BATCH = 3,
    SCHED_IDLE = 5,
    SCHED_DEADLINE = 6,
};
