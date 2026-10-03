// SPDX-License-Identifier: BSD-3-Clause

//! Where a thing is in 3D, which way it faces and how big it is.
//!
//! Like `Transform2D`, the numbers are local - in the space of the entity it
//! hangs from - and `App.worldTransform3D` gives the world's. A parent with
//! no `Transform3D` places nothing: a 3D entity under a 2D one is a root of
//! its own world.
//!
//! The axes are right-handed, `+y` up, and a thing faces its own `-z`: a
//! camera looks down `-z`, and a model made that way faces where its
//! transform says. Rotations are quaternions - a script reads and writes one
//! as `quat`, or as `rotation_degrees`, pitch, yaw and roll in degrees.

const std = @import("std");
const testing = std.testing;

const math = @import("fluxion_math");
const attr = @import("../reflect/attr.zig");

const Vec3 = math.Vec3;
const Quat = math.Quat;

/// A rotation as a component keeps it: the four numbers of a `math.Quat`,
/// laid out as a component's fields must be. A script has one as a `quat`.
pub const Rotation = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,

    pub const identity: Rotation = .{};
    pub const reflect_name = "Rotation";

    pub fn of(q: Quat) Rotation {
        return .{ .x = q.x, .y = q.y, .z = q.z, .w = q.w };
    }

    pub fn quat(self: Rotation) Quat {
        return .init(self.x, self.y, self.z, self.w);
    }
};

pub const Transform3D = extern struct {
    position: Vec3 = .zero,
    rotation: Rotation = .identity,
    scale: Vec3 = .one,

    /// Whether this turns with its parent. Its offset turns either way.
    inherit_rotation: bool = true,

    /// Whether the parent's scale multiplies this one's.
    inherit_scale: bool = true,

    /// Draw this between its last two fixed steps, for anything moved in
    /// `.fixed`. See `Transform2D.interpolate`.
    interpolate: bool = false,

    /// How many links of a chain are followed before giving up.
    pub const max_depth: u8 = 16;

    pub const reflect_name = "Transform3D";
    pub const reflect_fields = .{
        .rotation = .{attr.Doc{ .text = "Pitch, yaw and roll, in degrees" }},
    };
    pub const reflect_methods = .{
        .translate = .{attr.Params{ .names = &.{"offset"} }},
        .translateLocal = .{attr.Params{ .names = &.{"offset"} }},
        .rotateX = .{attr.Params{ .names = &.{"radians"} }},
        .rotateY = .{attr.Params{ .names = &.{"radians"} }},
        .rotateZ = .{attr.Params{ .names = &.{"radians"} }},
        .rotateAbout = .{attr.Params{ .names = &.{ "axis", "radians" } }},
        .rotateLocal = .{attr.Params{ .names = &.{ "axis", "radians" } }},
        .lookAt = .{ attr.Params{ .names = &.{ "target", "up" } }, attr.defaults(.{Vec3.unit_y}) },
        .forward = .{},
        .back = .{},
        .right = .{},
        .up = .{},
    };

    /// Where an interpolating transform was before the last fixed step.
    pub const Snapshot = struct {
        position: Vec3,
        rotation: Quat,
        scale: Vec3,

        pub fn of(transform: Transform3D) Snapshot {
            return .{ .position = transform.position, .rotation = transform.rotation.quat(), .scale = transform.scale };
        }

        /// Somewhere between here and `now`, at `t` from zero to one: the
        /// rotation along the shortest arc.
        pub fn blend(self: Snapshot, now: Transform3D, t: f32) Transform3D {
            var out = now;
            out.position = .lerp(self.position, now.position, t);
            out.rotation = .of(Quat.slerp(self.rotation, now.rotation.quat(), t));
            out.scale = .lerp(self.scale, now.scale, t);
            return out;
        }
    };

    /// A transform at a point, unrotated and unscaled.
    pub fn at(x: f32, y: f32, z: f32) Transform3D {
        return .{ .position = .init(x, y, z) };
    }

    /// The same transform, drawn between fixed steps.
    pub fn interpolated(self: Transform3D) Transform3D {
        var out = self;
        out.interpolate = true;
        return out;
    }

    /// The position, rotation and scale as the maths library has them.
    pub fn pose(self: Transform3D) math.Transform {
        return .init(self.position, self.rotation.quat(), self.scale);
    }

    /// The matrix that takes this transform's own space into its parent's.
    pub fn matrix(self: Transform3D) math.Mat4 {
        return self.pose().toMat4();
    }

    /// Move by `offset`, in the space this transform is in.
    pub fn translate(self: *Transform3D, offset: Vec3) void {
        self.position = self.position.add(offset);
    }

    /// Move by `offset` along its own axes: `translateLocal(vec3(0, 0, -1))`
    /// is a step forward, whichever way it faces. Its scale is not applied.
    pub fn translateLocal(self: *Transform3D, offset: Vec3) void {
        self.position = self.position.add(self.rotation.quat().rotate(offset));
    }

    /// Turn about the axes of the space it is in: `rotateY` turns it left
    /// or right whichever way it was tipped.
    pub fn rotateX(self: *Transform3D, radians: f32) void {
        self.rotateAbout(.unit_x, radians);
    }

    pub fn rotateY(self: *Transform3D, radians: f32) void {
        self.rotateAbout(.unit_y, radians);
    }

    pub fn rotateZ(self: *Transform3D, radians: f32) void {
        self.rotateAbout(.unit_z, radians);
    }

    /// Turn about `axis`, in the space it is in.
    pub fn rotateAbout(self: *Transform3D, axis: Vec3, radians: f32) void {
        self.rotation = .of(Quat.fromAxisAngle(axis, radians).mul(self.rotation.quat()).norm());
    }

    /// Turn about one of its own axes: `rotateLocal(vec3(1, 0, 0), a)`
    /// tips its nose up and down, whichever way it faces.
    pub fn rotateLocal(self: *Transform3D, axis: Vec3, radians: f32) void {
        self.rotation = .of(self.rotation.quat().mul(Quat.fromAxisAngle(axis, radians)).norm());
    }

    /// Turn to face `target`, a point in the space it is in, with `up` as
    /// near its own `+y` as it can be. A target where it stands leaves it
    /// as it was.
    pub fn lookAt(self: *Transform3D, target: Vec3, up_hint: Vec3) void {
        self.rotation = .of(self.pose().facing(target, up_hint).rotation);
    }

    /// Its own `-z`, the way it faces, in the space it is in.
    pub fn forward(self: Transform3D) Vec3 {
        return self.rotation.quat().rotate(.init(0, 0, -1));
    }

    /// Its own `+z`.
    pub fn back(self: Transform3D) Vec3 {
        return self.rotation.quat().rotate(.unit_z);
    }

    /// Its own `+x`.
    pub fn right(self: Transform3D) Vec3 {
        return self.rotation.quat().rotate(.unit_x);
    }

    /// Its own `+y`.
    pub fn up(self: Transform3D) Vec3 {
        return self.rotation.quat().rotate(.unit_y);
    }

    /// Pitch, yaw and roll, in degrees: what a person reads and types.
    pub fn rotationDegrees(self: Transform3D) Vec3 {
        const e = self.rotation.quat().toEuler();
        return .init(math.degrees(e.pitch), math.degrees(e.yaw), math.degrees(e.roll));
    }

    pub fn setRotationDegrees(self: *Transform3D, degrees: Vec3) void {
        self.rotation = .of(Quat.fromEuler(math.radians(degrees.x), math.radians(degrees.y), math.radians(degrees.z)));
    }

    /// A point in this transform's own space, in its parent's.
    pub fn apply(self: Transform3D, point: Vec3) Vec3 {
        return self.pose().apply(point);
    }

    /// `apply` undone. A scale of zero is left out rather than divided by.
    pub fn unapply(self: Transform3D, point: Vec3) Vec3 {
        return self.pose().applyInverse(point);
    }

    /// Where `local` ends up, given where its parent ended up. Exact for a
    /// parent of uniform scale; under a stretched one, the nearest
    /// transform to the sheared truth, as every scene graph keeps it.
    pub fn compose(parent: Transform3D, local: Transform3D) Transform3D {
        return .{
            .position = parent.apply(local.position),
            .rotation = if (local.inherit_rotation) .of(parent.rotation.quat().mul(local.rotation.quat())) else local.rotation,
            .scale = if (local.inherit_scale) parent.scale.mul(local.scale) else local.scale,
            .interpolate = local.interpolate,
        };
    }
};

test "a child is turned and moved through its parent" {
    const parent: Transform3D = .{ .position = .init(10, 0, 0), .rotation = .of(Quat.fromAxisAngle(.unit_y, std.math.pi / 2.0)) };
    const child: Transform3D = .at(0, 0, -2);
    const placed: Transform3D = .compose(parent, child);
    // A quarter turn about +y takes -z to -x.
    try testing.expectApproxEqAbs(@as(f32, 8), placed.position.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), placed.position.z, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -1), placed.forward().x, 1e-5);
}

test "degrees go in and come back out" {
    var t: Transform3D = .{};
    t.setRotationDegrees(.init(20, -60, 10));
    const back_out = t.rotationDegrees();
    try testing.expectApproxEqAbs(@as(f32, 20), back_out.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -60), back_out.y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 10), back_out.z, 1e-3);
}

test "a transform looks at a point with -z" {
    var t: Transform3D = .at(0, 0, 0);
    t.lookAt(.init(5, 0, 0), .unit_y);
    try testing.expectApproxEqAbs(@as(f32, 1), t.forward().x, 1e-5);
    t.translateLocal(.init(0, 0, -2));
    try testing.expectApproxEqAbs(@as(f32, 2), t.position.x, 1e-5);
}
