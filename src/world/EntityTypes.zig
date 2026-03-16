const std = @import("std");
const World = @import("World.zig");
const zm = @import("zm");
const Block = @import("Block.zig").Block;
const Entity = @import("Entity.zig");
const gl = @import("gl");
const obj = @import("obj");
const ztracy = @import("ztracy");
const Physics = @import("Physics.zig");
const Item = @import("Item.zig");
const pack = "default";
const AtomicVector = @import("../libs/utils.zig").AtomicVector;

const EntityMeshBufferIDs = struct {
    vbo: c_uint,
    vao: c_uint,
    ebo: c_uint,
};

var EntityMeshes: [@typeInfo(Entity.Type).@"enum".fields.len]?EntityMeshBufferIDs = @splat(null);
var EntityMeshesLen: [@typeInfo(Entity.Type).@"enum".fields.len]c_int = undefined;

pub fn LoadMeshes(allocator: std.mem.Allocator, io: std.Io) !void {
    var cwd = std.Io.Dir.cwd();
    var packs = try cwd.createDirPathOpen(io, "packs", .{});
    defer packs.close();
    var packdir = try packs.createDirPathOpen(io, pack, .{});
    defer packdir.close();
    var entities = try packdir.createDirPathOpen(io, "Entities", .{});
    defer entities.close();
    for (&EntityMeshes, 0..) |*mesh, i| {
        const entity: Entity.Type = @enumFromInt(i);
        std.debug.print("reading: {s}\n", .{@tagName(entity)});
        const fileContents = entities.readFileAlloc(allocator, @tagName(entity), 1_000_000_000) catch {
            std.log.err("failed to read: {s}\n", .{@tagName(entity)});
            continue;
        };
        defer allocator.free(fileContents);
        var parsedObj = try obj.parseObj(allocator, fileContents);
        defer parsedObj.deinit(allocator);
        mesh.* = try GlLoadEntity(parsedObj, &EntityMeshesLen[i], allocator);
    }
    std.debug.print("done reading\n", .{});
}

pub fn GlLoadEntity(entity: obj.ObjData, EntityMeshLen: *c_int, allocator: std.mem.Allocator) !?EntityMeshBufferIDs {
    if (entity.meshes.len == 0) return null;
    var bufferids: EntityMeshBufferIDs = undefined;
    gl.GenBuffers(1, @ptrCast(&bufferids.vbo));
    gl.BindBuffer(gl.ARRAY_BUFFER, bufferids.vbo);
    gl.BufferData(gl.ARRAY_BUFFER, @intCast(@sizeOf(f32) * entity.vertices.len), @ptrCast(entity.vertices), gl.STATIC_DRAW);
    gl.GenVertexArrays(1, @ptrCast(&bufferids.vao));
    gl.BindVertexArray(bufferids.vao);
    gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(f32), 0);
    gl.GenBuffers(1, @ptrCast(&bufferids.ebo));
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, bufferids.ebo);
    gl.EnableVertexAttribArray(0);
    var indices = try allocator.alloc(u32, 4_000_000);
    defer allocator.free(indices);
    var pos: usize = 0;
    for (entity.meshes) |mesh| {
        for (mesh.indices) |index| {
            indices[pos] = index.vertex.?;
            pos += 1;
        }
    }
    EntityMeshLen.* = @intCast(pos);
    gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(@sizeOf(u32) * pos), @ptrCast(indices[0..pos]), gl.STATIC_DRAW);
    return bufferids;
}

pub fn FreeMeshes() void {
    for (EntityMeshes) |m| {
        if (m) |mesh| {
            gl.DeleteBuffers(1, @ptrCast(@constCast(&mesh.vbo)));
            gl.DeleteBuffers(1, @ptrCast(@constCast(&mesh.ebo)));
            gl.DeleteVertexArrays(1, @ptrCast(@constCast(&mesh.vao)));
        }
    }
}

pub const Player = struct {
    pub const Type = Entity.Type.Player;
    player_name: Name,
    gameMode: std.atomic.Value(GameMode),
    fly_speed: std.atomic.Value(f32),
    fly_speed_linear: std.atomic.Value(f32),
    inventory_buffer: [10 * 16]?Item.Item = @splat(null),
    /// Main inventory and hotbar.
    main_inventory: Item.Inventory,
    /// Pitch, yaw, roll, in degrees.
    viewDirection: AtomicVector(3, f32),

    physics: Physics.getInterface(struct {
        gravity: Physics.Gravity,
        resistance: Physics.Resistance,
        mover: Physics.Mover,
    }),

    pub const Name = struct {
        data: [64]u8,
        len: u8,

        pub fn fromString(str: anytype) @This() {
            var name = @This(){
                .data = [_]u8{0} ** 64,
                .len = str.len,
            };
            std.debug.assert(str.len < name.data.len);
            @memcpy(name.data[0..str.len], str);
            return name;
        }

        pub fn toString(self: @This()) []const u8 {
            return self.data[0..self.len];
        }
    };

    pub const GameMode = enum(u8) {
        Survival = 0,
        Creative = 1,
        Spectator = 3,
    };

    pub fn unload(entity: *Entity, io: std.Io, world: *World, uuid: u128, allocator: std.mem.Allocator, save: bool) error{SavingFailed}!void {
        _ = save;
        _ = uuid;
        _ = world;
        _ = io;
        const self: *@This() = @ptrCast(@alignCast(entity.ptr));
        allocator.destroy(self);
        allocator.destroy(entity);
    }

    pub fn getPos(ptr: *anyopaque) @Vector(3, f64) {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.physics.pos.load(.seq_cst);
    }

    pub fn switchGameMode(self: *@This(), gameMode: GameMode) void {
        self.gameMode.store(gameMode, .seq_cst);
        switch (gameMode) {
            .Spectator => {
                self.physics.elements.mover.enabled = true;
                self.physics.elements.mover.zeroVelocity = true;
                self.physics.elements.mover.collisions = false;
                self.physics.elements.gravity.enabled = false;
                self.physics.elements.resistance.enabled = false;
            },
            .Survival => {
                self.physics.elements.mover.enabled = true;
                self.physics.elements.mover.zeroVelocity = false;
                self.physics.elements.mover.collisions = true;
                self.physics.elements.gravity.enabled = true;
                self.physics.elements.resistance.enabled = true;
            },
            .Creative => {
                self.physics.elements.mover.enabled = true;
                self.physics.elements.mover.zeroVelocity = false;
                self.physics.elements.mover.collisions = true;
                self.physics.elements.gravity.enabled = false;
                self.physics.elements.resistance.enabled = true;
            },
        }
    }

    pub fn update(entity: *Entity, io: std.Io, world: *World, uuid: u128, allocator: std.mem.Allocator) error{ Canceled, Unrecoverable }!bool {
        _ = uuid;
        const self: *@This() = @ptrCast(@alignCast(entity.ptr));
        self.physics.update(world, io, allocator) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.Unrecoverable,
        };
        return false;
    }

    pub fn getInterface(self: *const @This()) Entity.interface {
        _ = self;
        return .{
            .getPos = getPos,
            .unload = unload,
            .update = update,
        };
    }
};

pub const Explosive = struct {
    pub const Type: Entity.Type = .Explosive;
    pos: AtomicVector(3, f64),
    dir: AtomicVector(3, f64),
    timestamp: std.atomic.Value(i128),
    lock: std.Io.RwLock = .init,

    pub fn update(entity: *Entity, io: std.Io, world: *World, uuid: u128, allocator: std.mem.Allocator) error{ Canceled, Unrecoverable, OutOfMemory }!bool {
        const u = ztracy.ZoneNC(@src(), "updateCube", 345433);
        defer u.End();
        const self: *@This() = @ptrCast(@alignCast(entity.ptr));
        const l = ztracy.ZoneNC(@src(), "lock", 6553);
        self.lock.lockUncancelable(io);
        l.End();
        defer self.lock.unlock(io);

        const now_ns = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        const prev_ns = self.timestamp.load(.seq_cst);
        self.timestamp.store(now_ns, .seq_cst);
        const dt = @as(f64, @floatFromInt(now_ns - prev_ns)) * 1e-9;

        var dir = self.dir.load(.seq_cst);
        var pos = self.pos.load(.seq_cst);

        //dir[0] += (std.crypto.random.float(f64) - 0.5) * dt;
        //dir[1] += (std.crypto.random.float(f64) - 0.5) * dt;
        //dir[2] += (std.crypto.random.float(f64) - 0.5) * dt;
        if (!std.meta.eql(dir, @Vector(3, f64){ 0, 0, 0 })) dir = zm.vec.normalize(dir);
        dir *= @splat(10 * dt);
        pos += dir;

        self.dir.store(dir, .seq_cst);
        self.pos.store(pos, .seq_cst);

        var worldReader = World.Reader{ .world = world };
        const g = ztracy.ZoneNC(@src(), "getblock", 56565);
        if (true or (worldReader.getBlockUncached(@intFromFloat(pos), World.standard_level) catch unreachable) != .air) {
            g.End();
            var worldEditor = World.Editor{
                .world = world,
                .tempallocator = allocator,
            };
            const sphere = World.Editor.Geometry.Sphere(f32).init(@floatCast(pos), 8);
            worldEditor.placeSamplerShape(.grass, sphere, World.standard_level) catch |err| std.debug.panic("failed to WorldEditor: {any}\n", .{err});
            worldEditor.flush(io, allocator) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Unrecoverable,
            };
            return false;
        } else g.End();
        _ = uuid;
        return false;
    }

    pub fn unload(entity: *Entity, io: std.Io, world: *World, uuid: u128, allocator: std.mem.Allocator, save: bool) error{SavingFailed}!void {
        _ = save;
        _ = uuid;
        _ = world;
        _ = io;
        const self: *@This() = @ptrCast(@alignCast(entity.ptr));
        allocator.destroy(self);
        allocator.destroy(entity);
    }

    pub fn getPos(ptr: *anyopaque) @Vector(3, f64) {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.pos.load(.seq_cst);
    }

    pub fn getInterface(self: *const @This()) Entity.interface {
        _ = self;
        return .{
            .getPos = getPos,
            .unload = unload,
            .update = update,
            .draw = null,
        };
    }
};

fn texture(u: f64, v: f64, args: anytype) f64 {
    const noise = World.DefaultGenerator.Noise.Noise(f32){
        .noise_type = .simplex,
        .frequency = 0.5,
    };
    _ = args;
    const sampled = noise.genNoise2DRange(@floatCast(u), @floatCast(v), f32, 0, 1);
    return @floatCast(std.math.lerp(sampled, @as(f32, 1.0), @as(f32, 0.75)));
}
