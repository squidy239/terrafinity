const std = @import("std");
const Renderer = @import("../main.zig").Renderer;
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
const EntityMeshBufferIDs = struct {
    vbo: c_uint,
    vao: c_uint,
    ebo: c_uint,
};

var EntityMeshes: [@typeInfo(Entity.Type).@"enum".fields.len]?EntityMeshBufferIDs = @splat(null);
var EntityMeshesLen: [@typeInfo(Entity.Type).@"enum".fields.len]c_int = undefined;

pub fn LoadMeshes(allocator: std.mem.Allocator) !void {
    var cwd = std.fs.cwd(); //cd into packs
    var packs = try cwd.makeOpenPath("packs", .{});
    defer packs.close();
    var packdir = try packs.makeOpenPath(pack, .{});
    defer packdir.close();
    var entities = try packdir.makeOpenPath("Entities", .{});
    defer entities.close();
    for (&EntityMeshes, 0..) |*mesh, i| {
        const entity: Entity.Type = @enumFromInt(i);
        std.debug.print("reading: {s}\n", .{@tagName(entity)});
        const fileContents = entities.readFileAlloc(allocator, @tagName(entity), 1_000_000_000) catch {
            std.log.err("failed to read: {s}\n", .{@tagName(entity)});
            continue;
        };
        defer allocator.free(fileContents);
        var parsedObj = try obj.parseObj(allocator, fileContents); //TODO somehow fetch files if they are missing
        defer parsedObj.deinit(allocator);
        mesh.* = try GlLoadEntity(parsedObj, &EntityMeshesLen[i], allocator);
    }
    std.debug.print("done reading\n", .{});
}

pub fn GlLoadEntity(entity: obj.ObjData, EntityMeshLen: *c_int, allocator: std.mem.Allocator) !?EntityMeshBufferIDs {
    if (entity.meshes.len == 0) return null;
    // std.debug.assert(entity.meshes.len == 1);
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
    //  std.debug.print("e:{any}\n", .{entity.meshes[0].indices.len});
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
    inventory_buffer: [256]?Item.Item = @splat(null),
    ///main inventory and hotbar
    main_inventory: Item.Inventory,
    ///pitch, yaw, roll, in degrees
    viewDirection: @Vector(3, f32),
    viewDirectionLock: std.Thread.RwLock = .{},
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

    pub fn unload(entity: *Entity, world: *World, uuid: u128, allocator: std.mem.Allocator, save: bool) error{SavingFailed}!void {
        _ = save;
        _ = uuid;
        _ = world;
        const self: *@This() = @ptrCast(@alignCast(entity.ptr));
        allocator.destroy(self);
        allocator.destroy(entity);
    }

    pub fn getPos(ptr: *anyopaque) @Vector(3, f64) {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.physics.getPos();
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

    pub fn getViewDirection(self: *@This()) @Vector(3, f32) {
        self.viewDirectionLock.lockShared();
        defer self.viewDirectionLock.unlockShared();
        return self.viewDirection;
    }

    pub fn update(entity: *Entity, world: *World, uuid: u128, allocator: std.mem.Allocator) error{ TimedOut, Unrecoverable }!bool {
        _ = uuid;
        const self: *@This() = @ptrCast(@alignCast(entity.ptr));
        self.physics.update(world, allocator) catch return error.Unrecoverable;
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

pub const Cube = struct {
    lock: std.Thread.RwLock = .{},
    pos: @Vector(3, f64),
    velocity: @Vector(3, f64),
    timestamp: i64,

    pub fn update(entity: *Entity, world: *World, uuid: u128, allocator: std.mem.Allocator) error{ TimedOut, Unrecoverable }!void {
        const u = ztracy.ZoneNC(@src(), "updateCube", 345433);
        defer u.End();
        const self: *@This() = @ptrCast(@alignCast(entity.ptr));
        const timestamp = self.timestamp;
        self.timestamp = std.time.microTimestamp();
        const l = ztracy.ZoneNC(@src(), "lock", 6553);
        self.lock.lock();
        l.End();
        const dt: @Vector(3, f64) = @splat(@as(f64, @floatFromInt(self.timestamp - timestamp)) * 0.000001);
        //self.velocity[world.random.intRangeAtMost(usize, 0, 2)] += 100 * (world.random.float(f64) - 0.5) * dt[0];
        self.pos += self.velocity * dt;
        self.lock.unlock();
        var worldReader = World.Reader{ .world = world };
        const g = ztracy.ZoneNC(@src(), "getblock", 56565);
        if ((worldReader.getBlockUncached(@intFromFloat(self.pos), World.standard_level) catch unreachable) != .air) {
            g.End();
            var worldEditor = World.Editor{
                .world = world,
                .tempallocator = allocator,
            };
            const sphere = World.Editor.TexturedSphere.TexturedSphere(f64, texture, void).init(self.pos, 32, {}, 0.6);
            //const sphere = World.WorldEditor.Sphere(f64).init(self.pos, 128);
            worldEditor.placeSamplerShape(.air, sphere, World.standard_level) catch |err| std.debug.panic("failed to WorldEditor: {any}\n", .{err});
            _ = worldEditor.flush() catch |err| std.debug.panic("failed to clear WorldEditor: {any}\n", .{err});
            //_ = uuid;
            _ = entity.ref_count.fetchSub(1, .seq_cst);
            world.unloadEntity(uuid);
            return;
        } else g.End();
        _ = entity.ref_count.fetchSub(1, .seq_cst);
    }

    pub fn unload(entity: *Entity, world: *World, uuid: u128, allocator: std.mem.Allocator, save: bool) error{SavingFailed}!void {
        _ = save;
        _ = uuid;
        _ = world;
        const self: *@This() = @ptrCast(@alignCast(entity.ptr));
        allocator.destroy(self);
        allocator.destroy(entity);
    }

    pub fn getPos(ptr: *anyopaque) @Vector(3, f64) {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.pos;
    }

    pub fn getInterface(self: *const @This()) Entity.interface {
        _ = self;
        return .{
            .getPos = getPos,
            .unload = unload,
            .update = update,
            .draw = draw,
        };
    }

    pub fn draw(ptr: *anyopaque, world: *World, uuid: u128, allocator: std.mem.Allocator, playerPos: @Vector(3, f64), renderer: *Renderer) error{Unrecoverable}!void {
        _ = world;
        _ = uuid;
        _ = allocator;
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.lock.lockShared();
        const relativePos: @Vector(3, f32) = @floatCast(self.pos - playerPos);
        self.lock.unlockShared();
        gl.Uniform3f(renderer.uniforms.relativeEntityposlocation, relativePos[0], relativePos[1], relativePos[2]);
        gl.BindVertexArray(EntityMeshes[@intFromEnum(Entity.Type.Cube)].?.vao);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, EntityMeshes[@intFromEnum(Entity.Type.Cube)].?.ebo);
        gl.DrawElements(gl.TRIANGLES, EntityMeshesLen[@intFromEnum(Entity.Type.Cube)], gl.UNSIGNED_INT, 0);
    }
};
fn texture(u: f64, v: f64, args: anytype) f64 {
    const noise = World.DefaultGenerator.Noise.Noise(f32){
        .noise_type = .simplex,
        .frequency = 4,
    };
    _ = args;
    const sampled = noise.genNoise2DRange(@floatCast(u), @floatCast(v), f32, 0, 1);
    return @floatCast(std.math.lerp(sampled, @as(f32, 1.0), @as(f32, 0.75)));
}
