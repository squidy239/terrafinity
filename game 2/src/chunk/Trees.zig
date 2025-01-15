const std  = @import("std");
const Block = @import("Blocks.zig").Blocks;
const branch = struct {
    children:?std.ArrayList(branch),
    ray:@Vector(8, f32),//start:x,y,z,width,end:width,x,y,z         all positions are offsets from end of last branch
};

const TreeType = enum (u16){
    Oak = 0,
};

const TreeBlocks  = enum ([4]Block){
    Oak = [4]Block{.OakRoots,.OakRootCluster,.OakLog,.OakLeaves},
};

const Tree = struct {
    allocator:std.mem.Allocator,
    branches:std.ArrayList(branch),
    creationtimeMS:i64,
    treetype:TreeType,
    posinchunk:[3]u5,
    chunkpos:[3]i32,

    fn DrawTree(treeblocks:TreeBlocks)!void{
        _ = treeblocks;
    }

    fn GenerateTree(allocator:std.mem.Allocator,treetype:TreeType, chunkpos:[3]i32,posinchunk:[3]u5,recursion:usize,firstbranchamount:usize)!Tree{
        var tree = Tree{
            .treetype = treetype,
            .allocator = allocator,
            .creationtimeMS = std.time.milliTimestamp(),
            .chunkpos = chunkpos,
            .posinchunk = posinchunk,
            .branches = try std.ArrayList(branch).initCapacity(allocator, 1), // 1 is trunk
        };
        for(0..firstbranchamount)|i|{
            const br = branch{
                .ray = @Vector(8, f32){0.0,0.0,0.0,1.0,0.8,1.0,1.0,@floatFromInt(i)},
                .children = null,
            };
            _ = try tree.branches.append(br);
            
        
        }



        return tree;
    }
};
pub fn main() void {
    std.debug.print("{}", .{@sizeOf(std.ArrayList(branch))});
}

test "TreeGen"{
    const tree = try Tree.GenerateTree(std.testing.allocator, TreeType.Oak, [3]i32{0,0,0}, [3]u5{0,0,0}, 4, 3);
   // defer tree.deinit();
    std.debug.print("\n\n{any}\n\n\n\n\n\n\n", .{tree});
}
    
