/// Unit vector along `v`. Returns `v` unchanged when its length is near zero.
pub inline fn vecNormalize(v: @Vector(3, f64)) @Vector(3, f64) {
    const len = vecLength(v);
    return if (len > 0.00001) v / @as(@Vector(3, f64), @splat(len)) else v;
}
/// Length of `v`.
pub inline fn vecLength(v: @Vector(3, f64)) f64 {
    return @sqrt(@reduce(.Add, v * v));
}
/// Dot product of two vectors with one shared element type.
pub inline fn dot(a: anytype, b: @TypeOf(a)) @typeInfo(@TypeOf(a)).vector.child {
    return @reduce(.Add, a * b);
}
