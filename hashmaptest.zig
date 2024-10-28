const std = @import("std");
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const  allocator = gpa.allocator();
pub fn main() !void {
    var intkeys = std.AutoHashMap([3]i32, u5096).init(allocator);
    for(0..100000)|i|{_ = try intkeys.put([3]i32{@as(i32,@intCast(i)),2,@as(i32,@intCast(i))+1}, @intCast(@bitReverse(i)));}
    var a:?u5096 = undefined;
    var t = try std.time.Timer.start();
    for(0..1_000_000)|_|{a = intkeys.get([3]i32{1,3,1});}
    std.debug.print("{d} ns\n", .{t.read()});
    std.debug.print("a:{?}", .{a}); 
}
