const std = @import("std");

const zm = @import("zm");

pub const Frustum = struct {
    planes: [6]@Vector(4, f32),

    pub fn extractFrustumPlanes(mat: @Vector(16, f32)) Frustum {
        // zm row-major
        const m00 = mat[0];
        const m01 = mat[1];
        const m02 = mat[2];
        const m03 = mat[3];
        const m10 = mat[4];
        const m11 = mat[5];
        const m12 = mat[6];
        const m13 = mat[7];
        const m20 = mat[8];
        const m21 = mat[9];
        const m22 = mat[10];
        const m23 = mat[11];
        const m30 = mat[12];
        const m31 = mat[13];
        const m32 = mat[14];
        const m33 = mat[15];

        var planes: [6]@Vector(4, f32) = undefined;

        planes[0] = @Vector(4, f32){ m30 + m00, m31 + m01, m32 + m02, m33 + m03 }; // Left
        planes[1] = @Vector(4, f32){ m30 - m00, m31 - m01, m32 - m02, m33 - m03 }; // Right
        planes[2] = @Vector(4, f32){ m30 + m10, m31 + m11, m32 + m12, m33 + m13 }; // Bottom
        planes[3] = @Vector(4, f32){ m30 - m10, m31 - m11, m32 - m12, m33 - m13 }; // Top
        planes[4] = @Vector(4, f32){ m30 + m20, m31 + m21, m32 + m22, m33 + m23 }; // Near
        planes[5] = @Vector(4, f32){ m30 - m20, m31 - m21, m32 - m22, m33 - m23 }; // Far

        // Normalize planes
        for (&planes) |*p| {
            const n = @Vector(3, f32){ p[0], p[1], p[2] };
            const len = @sqrt(zm.Vec3f.dot(.{ .data = n }, .{ .data = n }));
            p.* /= @splat(len);
        }

        return Frustum{ .planes = planes };
    }

    pub fn boxInFrustum(self: *const @This(), b_min: @Vector(3, f32), b_max: @Vector(3, f32)) bool {
        for (self.planes) |plane| {
            const plane_normal = @Vector(3, f32){ plane[0], plane[1], plane[2] };
            const p_vertex = @select(f32, plane_normal > @Vector(3, f32){ 0, 0, 0 }, b_max, b_min);
            if (zm.Vec3f.dot(.{ .data = plane_normal }, .{ .data = p_vertex }) + plane[3] < 0.0) return false;
        }
        return true;
    }
};
