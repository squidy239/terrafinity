//modified from the std thread pool, added prioritys nad switched from fila to fifo
const std = @import("std");
const builtin = @import("builtin");
const Pool = @This();
const WaitGroup = std.Thread.WaitGroup;
const ztracy = @import("root").ztracy;
const ConcurrentQueue = @import("ConcurrentQueue");
const ThreadPriority = @import("ThreadPriority");
mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
run_queue: [7]ConcurrentQueue.ConcurrentQueue(*Runnable, 32, false) = undefined,
is_running: std.atomic.Value(bool) = .init(true),
allocator: std.mem.Allocator,
threads: if (builtin.single_threaded) [0]std.Thread else []std.Thread,
isempty: std.Thread.Condition = .{},
isemptymutex: std.Thread.Mutex = .{},

const Runnable = struct {
    runFn: RunProto,
    node: std.DoublyLinkedList.Node = .{},
};

pub const Priority = enum(u4) {
    ExtremelyHigh = 0,
    VeryHigh = 1,
    High = 2,
    Medium = 3,
    Low = 4,
    VeryLow = 5,
    ExtremelyLow = 6,
};

const RunProto = *const fn (*Runnable) void;

pub const Options = struct {
    allocator: std.mem.Allocator,
    n_jobs: ?usize = null,
    stack_size: usize = std.Thread.SpawnConfig.default_stack_size,
};
///the allocator must be thread-safe
pub fn init(pool: *Pool, options: Options) !void {
    const allocator = options.allocator;

    pool.* = .{
        .allocator = allocator,
        .threads = if (builtin.single_threaded) .{} else &.{},
        .run_queue = undefined,
    };

    for (&pool.run_queue) |*q| {
        q.* = try ConcurrentQueue.ConcurrentQueue(*Runnable, 32, false).init(allocator);
    }
    if (builtin.single_threaded) {
        return;
    }

    const thread_count = options.n_jobs orelse @max(1, std.Thread.getCpuCount() catch 1);

    // kill and join any threads we spawned and free memory on error.
    pool.threads = try allocator.alloc(std.Thread, thread_count);
    var spawned: usize = 0;
    errdefer pool.join(spawned);

    for (pool.threads) |*thread| {
        thread.* = try std.Thread.spawn(.{
            .stack_size = options.stack_size,
            .allocator = allocator,
        }, worker, .{pool});
        spawned += 1;
    }
}

pub fn deinit(pool: *Pool) void {
    pool.join(pool.threads.len); // kill and join all threads.
    for (&pool.run_queue) |*q| {
        for (&q.fragments, 0..) |*fragment, i| { //strict ordering is disabled so it has to be manually emptied
            q.fragmentLocks[i].lock();
            defer q.fragmentLocks[i].unlock();
            while (fragment.popFirst()) |runnable| { //make sure all tasks are completed
                const datanode: *@TypeOf(pool.run_queue[i]).Node = @fieldParentPtr("node", runnable);
                datanode.data.runFn(datanode.data);
                q.allocators[i].destroy(datanode);
            }
        }
        q.deinit(true);
    }
    pool.* = undefined;
}

fn join(pool: *Pool, spawned: usize) void {
    if (builtin.single_threaded) {
        return;
    }

    {
        // ensure future worker threads exit the dequeue loop
        pool.is_running.store(false, .monotonic);
    }

    // wake up any sleeping threads (this can be done outside the mutex)
    // then wait for all the threads we know are spawned to complete.

    pool.isempty.broadcast();

    for (pool.threads[0..spawned]) |thread| {
        thread.join();
    }

    pool.allocator.free(pool.threads);
}

pub fn spawn(pool: *Pool, comptime func: anytype, args: anytype, priority: Priority) !void {
    if (builtin.single_threaded) {
        @call(.auto, func, args);
        return;
    }

    const Args = @TypeOf(args);
    const Closure = struct {
        arguments: Args,
        pool: *Pool,
        runnable: Runnable = .{ .runFn = runFn },

        fn runFn(runnable: *Runnable) void {
            const closure: *@This() = @alignCast(@fieldParentPtr("runnable", runnable));
            @call(.auto, func, closure.arguments);
            const d = ztracy.ZoneNC(@src(), "threadpooldestroy", 423342423);
            closure.pool.allocator.destroy(closure);
            d.End();
        }
    };

    const closure = try pool.allocator.create(Closure);
    closure.* = .{
        .arguments = args,
        .pool = pool,
    };

    _ = try pool.run_queue[@intFromEnum(priority)].append(&closure.runnable);
    pool.isempty.signal();
}

fn worker(pool: *Pool) void {
    while (true) {
        var run: ?*Runnable = null;

        for (&pool.run_queue) |*queue| {
            if (queue.popFirst()) |node| {
                run = node;
                break;
            }
        }

        if (run) |runnable| {
            runnable.runFn(runnable);
            const y = ztracy.ZoneNC(@src(), "threadYield", 423342423);
            std.Thread.yield() catch {};
            y.End();
        } else if (pool.is_running.load(.monotonic)) {
            pool.isemptymutex.lock();
            if (pool.is_running.load(.monotonic)) {
                pool.isempty.wait(&pool.isemptymutex);
            }
            pool.isemptymutex.unlock();
        }
        if (run == null and !pool.is_running.load(.monotonic)) {
            break;
        } else run = null;
    }
}

pub fn getIdCount(pool: *Pool) usize {
    return @intCast(1 + pool.threads.len);
}

test spawn {
    const TestFn = struct {
        fn checkRun(completed: *bool) void {
            completed.* = true;
        }
    };

    var completed: bool = false;

    {
        var pool: Pool = undefined;
        try pool.init(.{
            .allocator = std.testing.allocator,
        });
        defer pool.deinit();
        try pool.spawn(TestFn.checkRun, .{&completed});
    }

    try std.testing.expectEqual(true, completed);
}
