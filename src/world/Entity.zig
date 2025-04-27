const std = @import("std");
const EntityTypes = @import("EntityTypes.zig");

const EntityType = enum {
    Player,
    Cube,
    OtherCube,
};
pub const Entity = struct {
    type: EntityType,
    ptr: *anyopaque,
    lock: std.Thread.RwLock = .{},
    ref_count: std.atomic.Value(u32),
    functions: struct {
        updateFn: ?*const fn (ptr: *anyopaque) void = null,
        freeFn: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void = null,
        getPosFn: ?*const fn (ptr: *anyopaque) @Vector(3, f64) = null,
    },

    pub fn update(self: *@This()) !void {
        if (self.functions.updateFn) |updateFn| {
            return updateFn(self.ptr);
        }
    }

    pub fn GetPos(self: *@This()) ?@Vector(3, f64) {
        if (self.functions.getPosFn) |getPosFn| {
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

    pub fn WaitForRefAmount(self: *@This(), comptime amount: u32, comptime maxMicroTime: ?u64) bool {
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
            EntityType.OtherCube => allocator.destroy(@as(*EntityTypes.OtherCube, @ptrCast(@alignCast(self.ptr)))),
        }
    }

    ///waits for 1 ref then destroys held entity and self
    pub fn fullfree(self: *@This(), allocator: std.mem.Allocator) void {
        self.free(allocator);
        allocator.destroy(self);
    }
};

pub fn main() !void {
    var db = std.heap.DebugAllocator(.{}){};
    defer if (db.deinit() == .ok) {} else std.debug.panic("leak", .{});
    const allocator = db.allocator();

    const cube = EntityTypes.Cube{
        .bodyRotationAxis = @splat(0),
        .pos = @splat(0),
        .timestamp = std.time.microTimestamp(),
    };
    const entity = try cube.MakeEntity(allocator);
    defer entity.fullfree(allocator);

    // Set the timestamp at runtime
    //  defer en.fullfree(allocator);
    var hm = std.AutoHashMap(i32, *Entity).init(allocator);
    defer hm.deinit();
    try hm.put(0, entity);
    const a = hm.get(0).?;
    std.debug.print("ct:{any}\n", .{a.GetPos()});
    std.debug.print("size: {d}\n", .{@sizeOf(Entity)});
}
