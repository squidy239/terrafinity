const std = @import("std");
const Renderer = @import("root").Renderer;
const World = @import("root").World;
const zm = @import("root").zm;

const Entity = @import("Entity").Entity;
const EntityType = @import("Entity").EntityType;
const gl = @import("gl");
const obj = @import("obj");

pub const GameMode = enum(u8) {
    Survival = 0,
    Creative = 1,
    Spectator = 3,
};
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
pub const Player = struct { //TODO atomic instead of lock
    player_UUID: u128,
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
    velocity: @Vector(3, f64),
    timestamp: i64,
    bodyRotationAxis: @Vector(3, f64),

    pub fn update(selfptr: *anyopaque, world: *World) void {
        const self: *@This() = @ptrCast(@alignCast(selfptr));
        const timestamp = self.timestamp;
        self.timestamp = std.time.microTimestamp();
        const dt: @Vector(3, f64) = @splat(@as(f64, @floatFromInt(self.timestamp - timestamp)) * 0.000001);
        self.velocity[world.Rand.intRangeAtMost(usize, 0, 2)] += 100 * (world.Rand.float(f64) - 0.5) * dt[0];
        // const player = world.Entitys.getandaddref(0).?;
        //defer player.release();
        //  const diff = player.GetPos().? - self.pos;
        // _ = diff;
        //if (world.Rand.int(u16) == 255) std.debug.print("v:{d}\n", .{self.velocity});
        //self.velocity += (diff / @as(@Vector(3, f64), @splat(32))) * dt;
        self.pos += self.velocity * dt;
        // self.velocity *= @splat(1 - @max(0.01, dt[0] * 0.000000000001));
        // self.pos[0] += 1 * (@as(f64, @floatFromInt(dt)) * 0.0001);
    }

    pub fn getPos(selfptr: *anyopaque) @Vector(3, f64) {
        const self: *@This() = @ptrCast(@alignCast(selfptr));
        return self.pos;
    }

    pub fn draw(selfptr: *anyopaque, playerPos: @Vector(3, f64), renderer: *Renderer) void {
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
            .type = .Cube,
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
