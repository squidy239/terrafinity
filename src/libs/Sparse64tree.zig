const std = @import("std");

const Node = struct {
    Children: [64]?*Node,
    Data: ?u32,
    fn NewChild(parent: *Node, pos: [3]u6, Data: ?u32, allocator: std.mem.Allocator) !*Node {
        const in: u6 = 0x000000 | pos[0] | pos[1] << 2 | pos[2] << 4;
        if (parent.Children[in] != null) {
            parent.Children[in].?.CleanupSelf(allocator);
        }
        var ptr = try allocator.create(Node);
        ptr.Children = comptime [_]?*Node{null} ** 64;
        ptr.Data = Data;
        parent.Children[in] = ptr;
        return ptr;
    }
    fn CleanupSelf(parent: *Node, allocator: std.mem.Allocator) void {
        for (parent.Children) |n| {
            if (n != null) n.?.CleanupSelf(allocator);
        }
        allocator.destroy(parent);
    }
    fn InitEmpty(allocator: std.mem.Allocator) !*Node {
        var ptr = try allocator.create(Node);
        ptr.Children = comptime [_]?*Node{null} ** 64;
        ptr.Data = null;
        return ptr;
    }
    fn IndexToPos(in: u6) [3]u6 {
        return @as(@Vector(3, u6), @Vector(3, u2){
            @truncate(in), // Extract first 2 bits
            @truncate(in >> 2), // Extract next 2 bits (shifted 2 positions)
            @truncate(in >> 4), // Extract last 2 bits (shifted 4 positions)
        });
    }

    fn PosToIndex(pos: [3]u6) u6 {
        return ((0x000000 | pos[0]) | pos[1] << 2) | pos[2] << 4;
    }
};

test "tree" {
    var Tree = try Node.InitEmpty(std.testing.allocator);
    var n = try Tree.NewChild([3]u6{ 2, 3, 0 }, 21, std.testing.allocator);
    _ = try n.NewChild([3]u6{ 2, 2, 1 }, 32, std.testing.allocator);
    std.debug.print("\n{any}\n", .{Tree.Children[Node.PosToIndex([3]u6{ 2, 3, 0 })].?.Children[Node.PosToIndex([3]u6{ 2, 2, 1 })].?.Data});
    std.debug.print("\n{any}\n", .{Tree});
    Tree.CleanupSelf(std.testing.allocator);
}
