const std = @import("std");

pub const Frustum = struct {
    planes: [6]@Vector(4, f32),

    pub fn extractFrustumPlanes(mat: @Vector(16, f32)) Frustum {
        // zm is row-major, so row i occupies mat[i * 4 ..][0..4].
        const row_x: @Vector(4, f32) = .{ mat[0], mat[1], mat[2], mat[3] };
        const row_y: @Vector(4, f32) = .{ mat[4], mat[5], mat[6], mat[7] };
        const row_z: @Vector(4, f32) = .{ mat[8], mat[9], mat[10], mat[11] };
        const row_w: @Vector(4, f32) = .{ mat[12], mat[13], mat[14], mat[15] };

        var planes: [6]@Vector(4, f32) = .{
            row_w + row_x, // Left
            row_w - row_x, // Right
            row_w + row_y, // Bottom
            row_w - row_y, // Top
            row_w + row_z, // Near
            row_w - row_z, // Far
        };

        for (&planes) |*plane| {
            const normal = @Vector(3, f32){ plane[0], plane[1], plane[2] };
            plane.* /= @splat(@sqrt(@reduce(.Add, normal * normal)));
        }

        return .{ .planes = planes };
    }

    pub fn boxInFrustum(self: *const Frustum, b_min: @Vector(3, f32), b_max: @Vector(3, f32)) bool {
        for (self.planes) |plane| {
            const normal = @Vector(3, f32){ plane[0], plane[1], plane[2] };
            const p_vertex = @select(f32, normal > @as(@Vector(3, f32), @splat(0)), b_max, b_min);
            if (@reduce(.Add, normal * p_vertex) + plane[3] < 0.0) return false;
        }
        return true;
    }
};

test "identity view projection clips to the unit cube" {
    const identity: @Vector(16, f32) = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const frustum = Frustum.extractFrustumPlanes(identity);

    for (frustum.planes) |plane| {
        const normal = @Vector(3, f32){ plane[0], plane[1], plane[2] };
        try std.testing.expectApproxEqAbs(1.0, @sqrt(@reduce(.Add, normal * normal)), 1e-6);
    }

    try std.testing.expect(frustum.boxInFrustum(.{ -0.5, -0.5, -0.5 }, .{ 0.5, 0.5, 0.5 }));
    try std.testing.expect(frustum.boxInFrustum(.{ 0.5, 0.5, 0.5 }, .{ 5.0, 5.0, 5.0 }));
    try std.testing.expect(!frustum.boxInFrustum(.{ 2.0, 2.0, 2.0 }, .{ 3.0, 3.0, 3.0 }));
}
