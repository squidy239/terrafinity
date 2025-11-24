const utils = @import("utils.zig");
   
pub fn Cone(comptime T: type) type {
            return struct {
                position: @Vector(3, T), // top center of cone
                axis: @Vector(3, T), // normalized axis (direction from top → base)
                length: T,
                radiusTop: T,
                radiusBase: T,
                boundingBox: @Vector(6, T),
                pub fn init(pos: @Vector(3, T), axisVec: @Vector(3, T), coneLength: T, baseR: T, topR: T) @This() {
                    // normalize axis
                    const normAxis = axisVec / @as(@Vector(3, T), @splat(@sqrt(utils.dot(axisVec, axisVec))));
                    var cone: @This() = .{
                        .position = pos,
                        .axis = normAxis,
                        .length = coneLength,
                        .radiusTop = topR,
                        .radiusBase = baseR,
                        .boundingBox = undefined,
                    };
                    cone.updateBoundingBox();
                    return cone;
                }

                pub fn isPointInside(self: *const @This(), P: @Vector(3, T)) bool {
                    const v = P - self.position;
                    const t = utils.dot(v, self.axis);

                    if (t < 0 or t > self.length) return false;

                    const len2 = utils.dot(v, v);
                    const perp2 = len2 - t * t;

                    const r = self.radiusBase + (self.radiusTop - self.radiusBase) * (t / self.length);
                    return perp2 < r * r;
                }

                pub fn updateBoundingBox(self: *@This()) void {
                    const top = self.position;
                    const base = self.position + self.axis * @as(@Vector(3, T), @splat(self.length));
                    const rMax = @max(self.radiusTop, self.radiusBase);

                    const minX = @floor(@min(top[0], base[0]) - rMax);
                    const maxX = @ceil(@max(top[0], base[0]) + rMax);

                    const minY = @floor(@min(top[1], base[1]) - rMax);
                    const maxY = @ceil(@max(top[1], base[1]) + rMax);

                    const minZ = @floor(@min(top[2], base[2]) - rMax);
                    const maxZ = @ceil(@max(top[2], base[2]) + rMax);
                    self.boundingBox = @Vector(6, T){ minX, maxX, minY, maxY, minZ, maxZ };
                }
            };
        }

        pub fn Sphere(comptime T: type) type {
            return struct {
                position: @Vector(3, T),
                radius: T,
                boundingBox: @Vector(6, T),
                pub fn init(pos: @Vector(3, T), radius: T) @This() {
                    var sphere: @This() = .{
                        .position = pos,
                        .radius = radius,
                        .boundingBox = undefined,
                    };
                    sphere.updateBoundingBox();
                    return sphere;
                }

                pub fn isPointInside(self: *const @This(), P: @Vector(3, T)) bool {
                    const diff = P - self.position;
                    const dist2 = utils.dot(diff, diff);
                    return dist2 <= self.radius * self.radius;
                }

                pub fn updateBoundingBox(self: *@This()) void {
                    const r = self.radius;

                    const minX = @floor(@min(self.position[0] - r, self.position[0] + r));
                    const maxX = @ceil(@max(self.position[0] - r, self.position[0] + r));

                    const minY = @floor(@min(self.position[1] - r, self.position[1] + r));
                    const maxY = @ceil(@max(self.position[1] - r, self.position[1] + r));

                    const minZ = @floor(@min(self.position[2] - r, self.position[2] + r));
                    const maxZ = @ceil(@max(self.position[2] - r, self.position[2] + r));
                    self.boundingBox = @Vector(6, T){ minX, maxX, minY, maxY, minZ, maxZ };
                }
            };
        }