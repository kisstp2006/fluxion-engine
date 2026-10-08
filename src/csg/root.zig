// SPDX-License-Identifier: BSD-3-Clause

//! Solids joined, cut and met: constructive solid geometry. A box, a
//! cylinder, a ball or a closed mesh is a `Solid` - the polygons round it -
//! and one solid joined with another, cut by it or met with it is another
//! solid, by binary space partitioning (`Solid.combine`). What it comes to
//! is triangles, each knowing whose polygon it was.
//!
//! It is given plain numbers and gives back plain numbers: the engine makes
//! the solids from a `CSGShape3D` and those under it, and a mesh of what
//! they come to (`render/csg_shapes.zig`). Like the lightmap baker it is
//! built for speed in a release, and needs nothing but the standard
//! library.

pub const Solid = @import("Solid.zig");
pub const Vec3 = Solid.Vec3;
pub const Affine = Solid.Affine;
pub const Vertex = Solid.Vertex;
pub const Plane = Solid.Plane;
pub const Polygon = Solid.Polygon;
pub const Operation = Solid.Operation;
pub const Triangles = Solid.Triangles;
pub const epsilon = Solid.epsilon;

pub const box = Solid.box;
pub const cylinder = Solid.cylinder;
pub const sphere = Solid.sphere;
pub const mesh = Solid.mesh;

pub const planarUv = Solid.planarUv;
pub const Indexed = Solid.Indexed;

test {
    _ = Solid;
}

test "a face's picture runs to the right seen from outside, and is upright on the sides" {
    const std = @import("std");
    // Seen from in front of each side, its right and its up.
    const sides = [_]struct { facing: [3]f32, right: [3]f32 }{
        .{ .facing = .{ 0, 0, 1 }, .right = .{ 1, 0, 0 } },
        .{ .facing = .{ 0, 0, -1 }, .right = .{ -1, 0, 0 } },
        .{ .facing = .{ 1, 0, 0 }, .right = .{ 0, 0, -1 } },
        .{ .facing = .{ -1, 0, 0 }, .right = .{ 0, 0, 1 } },
    };
    for (sides) |side| {
        const at = planarUv(.{ 0, 0, 0 }, side.facing);
        const right = planarUv(side.right, side.facing);
        const up = planarUv(.{ 0, 1, 0 }, side.facing);
        try std.testing.expect(right[0] > at[0]);
        // A picture's `v` runs down it.
        try std.testing.expect(up[1] < at[1]);
    }
}
