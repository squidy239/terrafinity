const std = @import("std");
const gl = @import("gl");
const zm = @import("zm");
const zstbi = @import("zstbi");
const w = @import("glfw.zig");
var procs: gl.ProcTable = undefined;
var gpa = (std.heap.GeneralPurposeAllocator(.{}){});
const allocator = gpa.allocator();

pub fn main() !void {
    _ = try w.CreateWindow();
}
