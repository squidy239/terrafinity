const std = @import("std");
const Entity = @import("Entity").Entity;

pub const GameMode = enum(u8) {
    Survival = 0,
    Creative = 1,
    Spectator = 3,
};

pub const Name = struct {
    data: [64]u8,
    len: u8,

    pub fn fromString(str: anytype) @This() {
        var name = @This(){
            .data = [_]u8{0} ** 64,
            .len = str.len,
        };
        @memcpy(name.data[0..str.len], str);
        return name;
    }

    pub fn toString(self: @This()) []const u8 {
        return self.data[0..self.len];
    }
};
pub const Player = struct {
    player_UUID: u128,
    player_name: Name,
    gameMode: GameMode,
    OnGround: bool,
    pos: @Vector(3, f64),
    bodyRotationAxis: @Vector(3, f16),
    headRotationAxis: @Vector(2, f16),
    armSwings: [2]f16, //right,left
    hitboxmin: @Vector(3, f64),
    hitboxmax: @Vector(3, f64),
    Velocity: @Vector(3, f64),
    ip: ?std.posix.sockaddr,

    pub fn update(self: *@This()) !void {
        _ = self;
    }

    pub fn getPos(selfptr: *anyopaque) @Vector(3, f64) {
        const self: *@This() = @ptrCast(@alignCast(selfptr));
        return self.pos;
    }
    ///inits ref_count to 1
    pub fn MakeEntity(self: @This(), allocator: std.mem.Allocator) !*Entity {
        var mem = try allocator.create(@This());
        mem.* = self;
        _ = &mem;

        const en = Entity{
            .type = .Player,
            .ptr = mem,
            .lock = .{},
            .ref_count = .init(1),
            .functions = .{
                .getPosFn = @This().getPos,
            },
        };

        var entity = try allocator.create(Entity);
        entity.* = en;
        _ = &entity;
        return entity;
    }
};

pub const Cube = struct {
    pos: @Vector(3, f64),
    timestamp: i64,
    bodyRotationAxis: @Vector(3, f64),

    pub fn update(self: *@This()) !void {
        const timestamp = self.timestamp;
        self.timestamp = std.time.microTimestamp();
        self.pos += @Vector(3, f64){ @floatFromInt(timestamp), @floatFromInt(timestamp), @floatFromInt(timestamp) };
    }

    pub fn getPos(selfptr: *anyopaque) @Vector(3, f64) {
        const self: *@This() = @ptrCast(@alignCast(selfptr));
        return self.pos;
    }
    ///inits ref_count to 1
    pub fn MakeEntity(self: @This(), allocator: std.mem.Allocator) !*Entity {
        var mem = try allocator.create(@This());
        mem.* = self;
        _ = &mem;

        const en = Entity{
            .type = .Cube,
            .ptr = mem,
            .lock = .{},
            .ref_count = .init(1),
            .functions = .{
                .getPosFn = @This().getPos,
            },
        };

        var entity = try allocator.create(Entity);
        entity.* = en;
        _ = &entity;
        return entity;
    }
};

pub const OtherCube = struct {
    pos: @Vector(3, f32),
    timestamp: i64,
    bodyRotationAxis: @Vector(3, f64),

    pub fn update(self: *@This()) !void {
        const timestamp = self.timestamp;
        self.timestamp = std.time.microTimestamp();
        self.pos += @Vector(3, f64){ @floatFromInt(timestamp), @floatFromInt(timestamp), @floatFromInt(timestamp) };
    }

    pub fn getPos(self: anytype, args: anytype) @Vector(3, f32) {
        _ = args;
        return @floatCast(self.pos);
    }

    pub fn getTimestamp(self: *@This(), args: anytype) i64 {
        _ = args;
        return self.timestamp;
    }
};
