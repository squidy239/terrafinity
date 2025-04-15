const std = @import("std");
pub var EntityId: u32 = 0;

pub const EntityType = union(enum) {
    Player: *Player,
};

pub const Entity = struct {
    entity: EntityType,
    lock: std.Thread.RwLock,
    ref_count: std.atomic.Value(u32), //must count being in a hashmap as a refrence

    pub fn free(self: *@This(), allocator: std.mem.Allocator, max_tries: ?u32) !void {
        self.lock.lock();
        var tries: u32 = 0;
        while (self.ref_count.load(.seq_cst) != 1) {
            std.atomic.spinLoopHint();
            tries += 1;
            if (max_tries != null and tries > max_tries.?) return error.MaxTries;
        }
        allocator.destroy(unionPayloadPtr(EntityType, &self.entity).?);
    }
    fn unionPayloadPtr(comptime T: type, union_ptr: anytype) ?*T {
        const U = @typeInfo(@TypeOf(union_ptr)).pointer.child;
        inline for (@typeInfo(U).@"union".fields, 0..) |field, i| {
            if (field.type != T)
                continue;
            if (@intFromEnum(union_ptr.*) == i)
                return &@field(union_ptr, field.name);
        }
        return null;
    }
    pub fn add_ref(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .release);
    }

    pub fn release(self: *@This()) void {
        _ = self.ref_count.fetchSub(1, .release);
    }
};

pub const GameMode = enum(u8) {
    Survival = 0,
    Creative = 1,
    Spectator = 3,
};

pub const Player = struct {
    player_UUID: u128,
    player_name_len: u8,
    player_name: [64]u8,
    gameMode: GameMode,
    OnGround: bool,
    pos: @Vector(3, f64),
    bodyRotationAxis: @Vector(3, f64),
    headRotationAxis: @Vector(3, f64),
    eyepitch: f32,
    rightArmSwing: f32,
    leftArmSwing: f32,
    hitboxmin: @Vector(3, f64),
    hitboxmax: @Vector(3, f64),
    Movement: @Vector(3, f64),
    velocity: @Vector(3, f32),
    GenDistance: [3]u32,
    ip: ?std.posix.sockaddr,
};
