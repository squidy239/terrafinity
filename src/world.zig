const std = @import("std");
const Entitys = @import("./entitys.zig");
pub const h = "hello3";
pub const vertices =[_]f32{
    -0.5, -0.5, -0.5,  0.0, 0.0,
     0.5, -0.5, -0.5,  1.0, 0.0,
     0.5,  0.5, -0.5,  1.0, 1.0,
     0.5,  0.5, -0.5,  1.0, 1.0,
    -0.5,  0.5, -0.5,  0.0, 1.0,
    -0.5, -0.5, -0.5,  0.0, 0.0,

    -0.5, -0.5,  0.5,  0.0, 0.0,
     0.5, -0.5,  0.5,  1.0, 0.0,
     0.5,  0.5,  0.5,  1.0, 1.0,
     0.5,  0.5,  0.5,  1.0, 1.0,
    -0.5,  0.5,  0.5,  0.0, 1.0,
    -0.5, -0.5,  0.5,  0.0, 0.0,

    -0.5,  0.5,  0.5,  1.0, 0.0,
    -0.5,  0.5, -0.5,  1.0, 1.0,
    -0.5, -0.5, -0.5,  0.0, 1.0,
    -0.5, -0.5, -0.5,  0.0, 1.0,
    -0.5, -0.5,  0.5,  0.0, 0.0,
    -0.5,  0.5,  0.5,  1.0, 0.0,

     0.5,  0.5,  0.5,  1.0, 0.0,
     0.5,  0.5, -0.5,  1.0, 1.0,
     0.5, -0.5, -0.5,  0.0, 1.0,
     0.5, -0.5, -0.5,  0.0, 1.0,
     0.5, -0.5,  0.5,  0.0, 0.0,
     0.5,  0.5,  0.5,  1.0, 0.0,

    -0.5, -0.5, -0.5,  0.0, 1.0,
     0.5, -0.5, -0.5,  1.0, 1.0,
     0.5, -0.5,  0.5,  1.0, 0.0,
     0.5, -0.5,  0.5,  1.0, 0.0,
    -0.5, -0.5,  0.5,  0.0, 0.0,
    -0.5, -0.5, -0.5,  0.0, 1.0,

    -0.5,  0.5, -0.5,  0.0, 1.0,
     0.5,  0.5, -0.5,  1.0, 1.0,
     0.5,  0.5,  0.5,  1.0, 0.0,
     0.5,  0.5,  0.5,  1.0, 0.0,
    -0.5,  0.5,  0.5,  0.0, 0.0,
    -0.5,  0.5, -0.5,  0.0, 1.0
};

var GeneralPurposeAllocator  = std.heap.GeneralPurposeAllocator(.{}){};




pub const Chunk = struct {
    blocks: [32][32][32]u32,
    pos:@Vector(3, i32),
    vertices:?std.ArrayList(f32),

    pub fn initctoblock(block:Materials,pos:@Vector(3, i32)) !Chunk{
        //const allocator = GeneralPurposeAllocator.allocator();
        var chunk = Chunk{
        .blocks=[_][32][32]u32{ [_][32]u32{[_]u32{@intFromEnum(block)} ** 32} ** 32} ** 32,
        .pos = pos,
        .vertices = null,
        };
        chunk.vertices = try CalculateVertices(&chunk,GeneralPurposeAllocator.allocator());
        return chunk;
    }

};

pub fn translatedface(x:f32,y:f32,z:f32,face:u8) [30]f32{
    var v:[30]f32 = undefined;
    @memcpy(&v, vertices[(face*30)..(face*30)+30]);
    for(0..v.len)|i|{
        if(i % 5 == 0){v[i] += x;}
        if(i % 5 == 1){v[i] += y;}
        if(i % 5 == 2){v[i] += z;}

    }
    return v;
}

 pub fn CalculateVertices(chunk:*Chunk,allocator:std.mem.Allocator) !std.ArrayList(f32){
        var verts = std.ArrayList(f32).init(allocator);
        //_ = try verts.addManyAsArray(vertices.len);
        const blocks = chunk.blocks;
        for (0..32) |x|{
            for (0..32) |y| {
                for (0..32) |z| {
                    if (blocks[x][y][z] != @intFromEnum(Materials.Air)){
                        if (x != 31 and blocks[x+1][y][z] == @intFromEnum(Materials.Air) or x == 31){
                          _ = try verts.appendSlice(&translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z),2));
                        }
                        if (x != 0 and blocks[x-1][y][z] == @intFromEnum(Materials.Air)  or x == 0){
                          _ = try verts.appendSlice(&translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z),3));
                        }
                        if (y != 31 and blocks[x][y+1][z] == @intFromEnum(Materials.Air) or y == 31){
                          _ = try verts.appendSlice(&translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z),4));
                        }
                        if (y != 0 and blocks[x][y-1][z] == @intFromEnum(Materials.Air)  or y == 0){
                          _ = try verts.appendSlice(&translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z),5));
                        }
                        if (z != 31 and blocks[x][y][z+1] == @intFromEnum(Materials.Air) or z == 31){
                          _ = try verts.appendSlice(&translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z),1));
                        }
                        if (z != 0 and blocks[x][y][z-1] == @intFromEnum(Materials.Air)  or z == 0){
                          _ = try verts.appendSlice(&translatedface(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z),0));
                        }
                    }
                }
            }
        }
        return verts;

    }

pub const World = struct {
    Chunks:std.AutoHashMap(@Vector(3, i32),Chunk),
};

pub const Materials = enum(u32){
    Air = 0,
    Dirt = 1,
    Grass = 2,
    Stone = 3,
    TestBlock = 888,
};