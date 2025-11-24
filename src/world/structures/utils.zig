pub inline fn vecNormalize(v: @Vector(3, f64)) @Vector(3, f64) {
    const len = vecLength(v);
    return if (len > 0.00001) v / @as(@Vector(3, f64), @splat(len)) else v;
}
pub inline fn vecLength(v: @Vector(3, f64)) f64 {
    return @sqrt(@reduce(.Add, v * v));
}

pub inline fn vecCross(a: @Vector(3, f64), b: @Vector(3, f64)) @Vector(3, f64) {
    return @Vector(3, f64){
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

pub inline fn dot(a: anytype, b: @TypeOf(a)) @typeInfo(@TypeOf(a)).vector.child {
    return @reduce(.Add, a * b);
}