const std = @import("std");

const zm = @import("zm");

pub const Frustum = struct {
    frus: [6]@Vector(4, f64),

    pub const Box = struct {
        min: @Vector(3, f64),
        max: @Vector(3, f64),
    };

    pub fn extractFrustumPlanes(mat: @Vector(16, f64)) Frustum {
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

        var planes: [6]@Vector(4, f64) = undefined;

        planes[0] = @Vector(4, f64){ m30 + m00, m31 + m01, m32 + m02, m33 + m03 }; // Left
        planes[1] = @Vector(4, f64){ m30 - m00, m31 - m01, m32 - m02, m33 - m03 }; // Right
        planes[2] = @Vector(4, f64){ m30 + m10, m31 + m11, m32 + m12, m33 + m13 }; // Bottom
        planes[3] = @Vector(4, f64){ m30 - m10, m31 - m11, m32 - m12, m33 - m13 }; // Top
        planes[4] = @Vector(4, f64){ m30 + m20, m31 + m21, m32 + m22, m33 + m23 }; // Near
        planes[5] = @Vector(4, f64){ m30 - m20, m31 - m21, m32 - m22, m33 - m23 }; // Far

        // Normalize planes
        for (0..6) |i| {
            const n = @Vector(3, f64){ planes[i][0], planes[i][1], planes[i][2] };
            const len = @sqrt(zm.vec.dot(n, n));
            planes[i] /= @splat(len);
        }

        return Frustum{ .frus = planes };
    }

    pub fn boxInFrustum(self: *const @This(), box: Box) bool {
        // Check box against each of the 6 frustum planes
        inline for (0..6) |i| {
            var out: u32 = 0;
            const plane = self.frus[i];

            // Test all 8 corners of the box against this plane
            // Corner 1: min.x, min.y, min.z
            out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.min[0], box.min[1], box.min[2], 1.0 }) < 0.0);
            // Corner 2: max.x, min.y, min.z
            out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.max[0], box.min[1], box.min[2], 1.0 }) < 0.0);
            // Corner 3: min.x, max.y, min.z
            out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.min[0], box.max[1], box.min[2], 1.0 }) < 0.0);
            // Corner 4: max.x, max.y, min.z
            out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.max[0], box.max[1], box.min[2], 1.0 }) < 0.0);
            // Corner 5: min.x, min.y, max.z
            out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.min[0], box.min[1], box.max[2], 1.0 }) < 0.0);
            // Corner 6: max.x, min.y, max.z
            out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.max[0], box.min[1], box.max[2], 1.0 }) < 0.0);
            // Corner 7: min.x, max.y, max.z
            out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.min[0], box.max[1], box.max[2], 1.0 }) < 0.0);
            // Corner 8: max.x, max.y, max.z
            out += @intFromBool(zm.vec.dot(plane, @Vector(4, f64){ box.max[0], box.max[1], box.max[2], 1.0 }) < 0.0);

            // If all 8 corners are outside this plane, the box is completely outside the frustum
            if (out == 8) return false;
        }

        return true;
    }

    pub fn sphereInFrustum(self: *const @This(), center: @Vector(3, f64), radius: f64) bool {
        for (self.frus) |plane| {
            const dist = plane[0] * center[0] + plane[1] * center[1] + plane[2] * center[2] + plane[3];
            if (dist < -radius) return false;
        }
        return true;
    }
};
