const std = @import("std");
const Renderer = @import("root").Renderer;
const World = @import("root").World;
const zm = @import("root").zm;
const Block = @import("root").Block;
const Entity = @import("Entity").Entity;
const EntityType = @import("Entity").Entity.Type;
const gl = @import("gl");
const obj = @import("obj");

const pack = "default";
const EntityMeshBufferIDs = struct {
    vbo: c_uint,
    vao: c_uint,
    ebo: c_uint,
};

var EntityMeshes: [@typeInfo(EntityType).@"enum".fields.len]?EntityMeshBufferIDs = @splat(null);
var EntityMeshesLen: [@typeInfo(EntityType).@"enum".fields.len]c_int = undefined;

pub fn LoadMeshes(allocator: std.mem.Allocator) !void {
    var cwd = std.fs.cwd(); //cd into packs
    var packs = try cwd.makeOpenPath("packs", .{});
    defer packs.close();
    var packdir = try packs.makeOpenPath(pack, .{});
    defer packdir.close();
    var entities = try packdir.makeOpenPath("Entities", .{});
    defer entities.close();
    for (&EntityMeshes, 0..) |*mesh, i| {
        const entity: EntityType = @enumFromInt(i);
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
    lock: std.Thread.RwLock,
    player_name: Name,
    gameMode: GameMode,
    OnGround: bool,
    pos: @Vector(3, f64),
    bodyRotationAxis: @Vector(3, f32),
    headRotationAxis: @Vector(2, f32),
    armSwings: [2]f16, //right,left
    hitboxmin: @Vector(3, f64),
    hitboxmax: @Vector(3, f64),
    Velocity: @Vector(3, f64),

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

    pub fn update(self: *@This()) !void {
        _ = self;
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
        };
    }
};

pub const Cube = struct {
    lock: std.Thread.RwLock,
    pos: @Vector(3, f64),
    velocity: @Vector(3, f64),
    timestamp: i64,
    bodyRotationAxis: @Vector(3, f64),

    pub fn update(entity: *Entity, world: *World, uuid: u128, allocator: std.mem.Allocator) error{ TimedOut, Unrecoverable }!void {
        _ = uuid;
        _ = allocator;
        const self: *@This() = @ptrCast(@alignCast(entity.ptr));
        self.lock.lock();
        const timestamp = self.timestamp;
        self.timestamp = std.time.microTimestamp();
        const dt: @Vector(3, f64) = @splat(@as(f64, @floatFromInt(self.timestamp - timestamp)) * 0.000001);
        self.velocity[world.random.intRangeAtMost(usize, 0, 2)] += 100 * (world.random.float(f64) - 0.5) * dt[0];
        self.pos += self.velocity * dt;
        self.lock.unlock();
        var worldEditor = World.WorldEditor{
            .editBuffer = .{},
            .lastChunkCache = null,
            .lastChunkReadCache = null,
            .world = world,
            .tempallocator = world.allocator,
        };
        worldEditor.ClearReader();

        if (world.random.float(f32) > 0.99 and false) {
            worldEditor.ClearReader();

            //const sphere = World.TexturedSphere.TexturedSphere(f64, texture, void).init(self.pos, 32, {}, 0.6);
           // _ = uuid;
            //worldEditor.PlaceSamplerShape(.Air, sphere) catch |err| std.debug.panic("failed to WorldEditor: {any}\n", .{err});
            //_ = worldEditor.flush() catch |err| std.debug.panic("failed to clear WorldEditor: {any}\n", .{err});
            
            if(world.random.float(f32) > 0.0){
                _ = world.SpawnEntity(null, Cube{
                    .lock = .{},
                    .pos = self.pos,
                    .velocity = @splat(0),
                    .timestamp = std.time.microTimestamp(),
                    .bodyRotationAxis = @splat(0),
                }) catch return error.Unrecoverable;
            }
        }
        
        
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

    pub fn draw(ptr: *anyopaque, world: *World, uuid: u128, allocator: std.mem.Allocator, playerPos: @Vector(3, f64), renderer: *Renderer.Renderer) error{Unrecoverable}!void {
        _ = world;
        _ = uuid;
        _ = allocator;
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const relativePos: @Vector(3, f32) = @floatCast(self.pos - playerPos);
        gl.Uniform3f(renderer.uniforms.relativeEntityposlocation, relativePos[0], relativePos[1], relativePos[2]);
        gl.BindVertexArray(EntityMeshes[@intFromEnum(EntityType.Cube)].?.vao);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, EntityMeshes[@intFromEnum(EntityType.Cube)].?.ebo);
        gl.DrawElements(gl.TRIANGLES, EntityMeshesLen[@intFromEnum(EntityType.Cube)], gl.UNSIGNED_INT, 0);
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
pub const Explosive = struct {
    pos: @Vector(3, f64),
    velocity: @Vector(3, f64),
    timestamp: i64,
    explosionRadius: f64,
    exploded: bool,

    pub fn update(selfptr: *anyopaque, world: *World, uuid: u128) void {
        const self: *@This() = @ptrCast(@alignCast(selfptr));
        const timestamp = self.timestamp;
        self.timestamp = std.time.microTimestamp();
        const dt: @Vector(3, f64) = @splat(@as(f64, @floatFromInt(self.timestamp - timestamp)) * 0.000001);
        self.pos += self.velocity * dt;
        var worldEditor = World.WorldEditor{
            .editBuffer = .{},
            .lastChunkCache = null,
            .lastChunkReadCache = null,
            .world = world,
            .tempallocator = world.allocator,
        };
        defer worldEditor.ClearReader();
        if (Block.Properties.visible.get(worldEditor.GetBlock(@intFromFloat(self.pos)) catch |err| std.debug.panic("err: {any}\n", .{err}))) {
            worldEditor.ClearReader();

            const sphere = World.Structures.TexturedSphere(f64, texture, void).init(self.pos, self.explosionRadius);
            _ = uuid;
            worldEditor.PlaceSamplerShape(.Air, sphere) catch |err| std.debug.panic("failed to WorldEditor: {any}\n", .{err});
            _ = worldEditor.flush() catch |err| std.debug.panic("failed to clear WorldEditor: {any}\n", .{err});
        }
    }

    pub fn getPos(selfptr: *anyopaque) @Vector(3, f64) {
        const self: *@This() = @ptrCast(@alignCast(selfptr));
        return self.pos;
    }

    pub fn draw(selfptr: *anyopaque, playerPos: @Vector(3, f64), renderer: *Renderer.Renderer) void {
        const self: *@This() = @ptrCast(@alignCast(selfptr));
        // std.debug.print("d\n", .{});
        //     const timestamp = self.timestamp;
        //self.timestamp = std.time.microTimestamp();
        //const dt = self.timestamp - timestamp;
        //   self.update(playerPos);
        const relativePos: @Vector(3, f32) = @floatCast(self.pos - playerPos);
        //const md = @Vector(3, u32){ renderer.MeshDistance[0].load(.seq_cst), renderer.MeshDistance[1].load(.seq_cst), renderer.MeshDistance[2].load(.seq_cst) };
        // if (@reduce(.Or, @abs(diff / @Vector(3, f64){ 32, 32, 32 }) > @as(@Vector(3, f64), (@floatFromInt(md))))) {
        //   return;
        //   }
        //      const rotation = zm.Mat4f.rotation(@Vector(3, f32){ 0, 1, 0 }, @floatFromInt(30));
        gl.Uniform3f(renderer.uniforms.relativeEntityposlocation, relativePos[0], relativePos[1], relativePos[2]);
        //     gl.UniformMatrix4fv(renderer.uniforms.EntityRotationlocation, 1, gl.TRUE, @ptrCast(&(rotation.data)));
        gl.BindVertexArray(EntityMeshes[@intFromEnum(EntityType.Cube)].?.vao);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, EntityMeshes[@intFromEnum(EntityType.Cube)].?.ebo);
        gl.DrawElements(gl.TRIANGLES, EntityMeshesLen[@intFromEnum(EntityType.Cube)], gl.UNSIGNED_INT, 0);
        // gl.DrawArrays(gl.TRIANGLES, 0, EntityMeshesLen[@intFromEnum(EntityType.Cube)]);
        // gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0);
    }
    ///inits ref_count to 1
    pub fn MakeEntity(self: @This(), allocator: std.mem.Allocator) !*Entity {
        var mem = try allocator.create(@This());
        mem.* = self;
        _ = &mem;

        const en = Entity{
            .type = .Explosive,
            .ptr = mem,
            .lock = .{},
            .ref_count = .init(1),
            .functions = .{
                .getPosFn = @This().getPos,
                .updateFn = @This().update,
                .drawFn = @This().draw,
            },
        };

        var entity = try allocator.create(Entity);
        entity.* = en;
        _ = &entity;
        return entity;
    }
};
