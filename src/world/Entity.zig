const std = @import("std");
const Renderer = @import("root").Renderer;
const World = @import("root").World;
const ztracy = @import("root").ztracy;

const EntityTypes = @import("EntityTypes");

threadlocal var UnloadingEntities: [128]u128 = undefined;
threadlocal var UnloadingEntitiesPos: usize = 0;

pub const EntityType = enum(u16) {
    Player = 0,
    Cube = 1,
    Explosive = 2,
};
//TODO rewrite how entities work after async is added
pub const Entity = struct {
    type: EntityType,
    ptr: *anyopaque,
    lock: std.Thread.RwLock = .{},
    ref_count: std.atomic.Value(u32),
    functions: struct {
        updateFn: ?*const fn (ptr: *anyopaque, world: *World, uuid: u128) void = null,
        freeFn: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void = null,
        getPosFn: ?*const fn (ptr: *anyopaque) @Vector(3, f64) = null,
        drawFn: ?*const fn (ptr: *anyopaque, playerPos: @Vector(3, f64), renderer: *Renderer.Renderer) void = null,
    },

    pub fn update(self: *@This(), world: *World, uuid: u128) void {
        if (self.functions.updateFn) |updateFn| {
            self.lock.lock();
            defer self.lock.unlock();
            return updateFn(self.ptr, world, uuid);
        }
    }

    pub fn draw(self: *@This(), playerPos: @Vector(3, f64), r: *Renderer.Renderer) !void {
        if (self.functions.drawFn) |drawFn| {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            return drawFn(self.ptr, playerPos, r);
        }
    }
    pub fn GetPos(self: *@This()) ?@Vector(3, f64) {
        if (self.functions.getPosFn) |getPosFn| {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            return getPosFn(self.ptr);
        }
        return null;
    }
    ///frees any resources allocated by the entity
    pub fn freeFn(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.functions.freeFn) |freefn| {
            return freefn(self.ptr, allocator);
        }
    }

    pub fn WaitForRefAmount(self: *@This(), amount: u32, comptime maxMicroTime: ?u64) bool {
        if (self.ref_count.load(.seq_cst) == amount) return true;
        const st = std.time.microTimestamp();
        while (self.ref_count.load(.seq_cst) != amount) {
            if (maxMicroTime != null and (std.time.microTimestamp() - st) > maxMicroTime.?) return false;
            std.Thread.yield() catch |err| std.debug.print("yield err:{any}\n", .{err});
        }
        return true;
    }

    ///waits for 1 ref then destroys held entity
    pub fn free(self: *@This(), allocator: std.mem.Allocator) void {
        _ = self.WaitForRefAmount(1, null);
        self.freeFn(allocator);
        switch (self.type) {
            EntityType.Cube => allocator.destroy(@as(*EntityTypes.Cube, @ptrCast(@alignCast(self.ptr)))),
            EntityType.Player => allocator.destroy(@as(*EntityTypes.Player, @ptrCast(@alignCast(self.ptr)))),
            EntityType.Explosive => allocator.destroy(@as(*EntityTypes.Explosive, @ptrCast(@alignCast(self.ptr)))),
        }
    }

    ///waits for 1 ref then destroys held entity and self
    pub fn fullfree(self: *@This(), allocator: std.mem.Allocator) void {
        self.free(allocator);
        allocator.destroy(self);
    }

    pub fn add_ref(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    pub fn release(self: *@This()) void {
        _ = self.ref_count.fetchSub(1, .seq_cst);
    }

    pub fn addAndLockShared(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
        self.lock.lockShared();
    }

    pub fn addAndlock(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
        self.lock.lock();
    }

    pub fn addAndlockSharednoBlock(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
        self.lock.tryLockShared();
    }

    pub fn addAndlocknoBlock(self: *@This()) void {
        self.lock.tryLock();
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    pub fn releaseAndUnlock(self: *@This()) void {
        self.lock.unlock();
        _ = self.ref_count.fetchSub(1, .seq_cst);
    }

    pub fn releaseAndUnlockShared(self: *@This()) void {
        self.lock.unlockShared();
        _ = self.ref_count.fetchSub(1, .seq_cst);
    }
};

pub fn TickEntitiesBucketTask(world: *World, running: *std.atomic.Value(bool), complete: *bool, bucket: usize) void {
    if (!running.load(.monotonic)) return;
    defer complete.* = true;
    const TickEntitiesTask = ztracy.ZoneNC(@src(), "TickEntitiesTask", 324);
    defer TickEntitiesTask.End();
    world.Entitys.buckets[bucket].lock.lockShared();
    defer world.Entitys.buckets[bucket].lock.unlockShared();
    var it = world.Entitys.buckets[bucket].hash_map.iterator();
    while (it.next()) |c| {
        c.value_ptr.*.update(world, c.key_ptr.*);
    }
}

pub fn TickEntitiesThread(world: *World, interval_ns: u64, running: *std.atomic.Value(bool)) void {
    while (running.load(.monotonic)) {
        const AddEntitiesToTick = ztracy.ZoneNC(@src(), "AddEntitiesToTick", 45354345);
        const st = std.time.nanoTimestamp();
        defer std.Thread.sleep(interval_ns -| @as(u64, @intCast(std.time.nanoTimestamp() - st)));
        const enbktamount = world.Entitys.buckets.len;
        var tasksComplete: [enbktamount]bool = @splat(false);
        for (0..enbktamount) |bucket| {
            world.threadPool.spawn(TickEntitiesBucketTask, .{ world, running, &tasksComplete[bucket], bucket }, .High) catch std.debug.panic("error adding task to pool", .{});
        }
        AddEntitiesToTick.End();
        const WaitingForTasksToComplete = ztracy.ZoneNC(@src(), "WaitingForTasksToComplete", 2344326);
        while (!@reduce(.And, @as(@Vector(enbktamount, bool), tasksComplete)) and running.load(.monotonic)) { //checks if all tasks finished before spawning new ones, check if running because the tasks exit if its not
            std.Thread.yield() catch std.debug.print("cany yeild", .{});
        }
        WaitingForTasksToComplete.End();
    }
}

pub fn DespawnEntities(world: *World, centers: []const @Vector(3, f64), coordrange: @Vector(3, f64)) void {
    const enbktamount = world.Entitys.buckets.len;
    outer: for (0..enbktamount) |b| {
        world.Entitys.buckets[b].lock.lockShared();
        var it = world.Entitys.buckets[b].hash_map.iterator();
        defer world.Entitys.buckets[b].lock.unlockShared();
        while (it.next()) |c| {
            if (UnloadingEntitiesPos >= UnloadingEntities.len) break :outer;
            const pos = c.value_ptr.GetPos();
            var outOfAllRanges = false;
            for (centers) |center| outOfAllRanges = outOfAllRanges or outOfSquareRange(pos, coordrange + center);
            if (outOfAllRanges) {
                UnloadingEntities[UnloadingEntitiesPos] = c.key_ptr.*;
                UnloadingEntitiesPos += 1;
            }
        }
    }

    for (UnloadingEntities[0..UnloadingEntitiesPos]) |uuid| {
        world.UnloadEntity(uuid);
    }
    UnloadingEntitiesPos = 0;
}

fn outOfSquareRange(Pos: @Vector(3, f64), range: @Vector(3, f64)) bool {
    return @reduce(.Or, @as(@Vector(3, f64), @intCast(@abs(Pos))) > range);
}
