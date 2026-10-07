// SPDX-License-Identifier: BSD-3-Clause

//! Three floats, and the few things done with them here.

pub const Vec3 = @Vector(3, f32);

pub inline fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

pub inline fn length(a: Vec3) f32 {
    return @sqrt(dot(a, a));
}

pub inline fn normalize(a: Vec3) Vec3 {
    const l = length(a);
    return if (l > 0) a / @as(Vec3, @splat(l)) else a;
}

pub inline fn scale(a: Vec3, s: f32) Vec3 {
    return a * @as(Vec3, @splat(s));
}

pub inline fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
    return a + (b - a) * @as(Vec3, @splat(t));
}

/// The distance on the ground, ignoring height.
pub inline fn distance2d(a: Vec3, b: Vec3) f32 {
    const x = a[0] - b[0];
    const z = a[2] - b[2];
    return @sqrt(x * x + z * z);
}

/// Twice the signed area of the triangle on the ground: positive when
/// `a, b, c` turn counter-clockwise seen from above, with x to the right
/// and z towards the viewer... as the polygons here are wound.
pub inline fn area2d(a: Vec3, b: Vec3, c: Vec3) f32 {
    const abx = b[0] - a[0];
    const abz = b[2] - a[2];
    const acx = c[0] - a[0];
    const acz = c[2] - a[2];
    return acx * abz - abx * acz;
}
