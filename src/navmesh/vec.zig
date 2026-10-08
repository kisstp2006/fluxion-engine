// SPDX-License-Identifier: BSD-3-Clause

//! Three floats, and the few things done with them here.

const std = @import("std");

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

/// Twice the signed area of the triangle on the ground, x and z: its sign
/// says which way round `a, b, c` go.
pub inline fn area2d(a: Vec3, b: Vec3, c: Vec3) f32 {
    const abx = b[0] - a[0];
    const abz = b[2] - a[2];
    const acx = c[0] - a[0];
    const acz = c[2] - a[2];
    return acx * abz - abx * acz;
}

/// A place, a turn and a size: three rows of four, the last column the
/// move. What puts a mesh baked in its region's own space into the world.
pub const Affine = struct {
    rows: [3][4]f32 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 } },

    pub const identity: Affine = .{};

    pub fn apply(self: Affine, p: Vec3) Vec3 {
        var out: Vec3 = undefined;
        inline for (0..3) |r| out[r] = self.rows[r][0] * p[0] + self.rows[r][1] * p[1] + self.rows[r][2] * p[2] + self.rows[r][3];
        return out;
    }

    /// Of a column-major 4x4 matrix, as a renderer keeps one.
    pub fn ofColumns(m: [16]f32) Affine {
        return .{ .rows = .{
            .{ m[0], m[4], m[8], m[12] },
            .{ m[1], m[5], m[9], m[13] },
            .{ m[2], m[6], m[10], m[14] },
        } };
    }

    pub fn isIdentity(self: Affine) bool {
        return std.meta.eql(self.rows, identity.rows);
    }
};
