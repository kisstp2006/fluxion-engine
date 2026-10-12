// SPDX-License-Identifier: BSD-3-Clause

//! Ragdolls: a skeleton's bones as bodies. Each `PhysicalBone3D` is a body
//! that is one bone; once a frame, after the animations, they and their
//! bones are put in step - whichever way `simulate` says.
//!
//! **Following** (`simulate` off): the body is kinematic and is put where
//! its bone is in the world, so a shot finds the arm where it is drawn; how
//! fast the bone moved and turned is kept, `carried_velocity` and
//! `carried_spin`.
//!
//! **Simulated** (`simulate` on): the body is dynamic - made where the bone
//! was, moving as it was - and the bone is put where the body is, its
//! parent's place taken out, the bones nearer the root first. A bone with
//! no body keeps its place from its parent: the fingers on a falling hand.
//! The body is read as it is drawn, between two steps where its transform
//! is interpolated, so the skeleton moves as smoothly as anything else.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const hierarchy = @import("../scene/hierarchy.zig");

const Entity = ecs.Entity;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Transform3D = components.Transform3D;
const RigidBody3D = components.RigidBody3D;
const PhysicalBone3D = components.PhysicalBone3D;
const Skeleton3D = components.Skeleton3D;

/// The fastest a bone's motion is carried into its body, in metres a
/// second: a skeleton put somewhere else in one frame does not throw it.
const most_carried = 20;

/// Every physical bone and its bone put in step.
pub fn update(app: *App) !void {
    var driven: std.ArrayList(Driven) = .empty;
    defer driven.deinit(app.gpa);
    const dt = app.time.delta;
    var it = try ecs.Query(.{ PhysicalBone3D, Transform3D, RigidBody3D }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(PhysicalBone3D), chunk.slice(RigidBody3D)) |e, *part, *rigid| {
            const owner = skeletonOf(app, e, part) orelse continue;
            const pose = app.poses.of(app, owner) orelse continue;
            const bone = app.skeletons.get(pose.skeleton).?.find(part.boneName()) orelse continue;
            if (part.simulate) {
                if (rigid.type != .dynamic) {
                    rigid.type = .dynamic;
                    rigid.linear_velocity = part.carried_velocity;
                    rigid.angular_velocity = part.carried_spin;
                }
                try driven.append(app.gpa, .{ .skeleton = owner, .bone = bone, .body = e });
            } else {
                if (rigid.type != .kinematic) rigid.type = .kinematic;
                rigid.linear_velocity = .zero;
                rigid.angular_velocity = .zero;
                follow(app, e, part, owner, bone, dt);
            }
        }
    }
    try drive(app, driven.items);
}

const Driven = struct { skeleton: Entity, bone: u16, body: Entity };

/// The skeleton `part` is a bone of: its own, or the nearest under its
/// parent, its parent's parent and so up - kept, and looked for again only
/// once it is gone.
fn skeletonOf(app: *App, e: Entity, part: *PhysicalBone3D) ?Entity {
    if (!part.skeleton.isNone()) return part.skeleton;
    if (app.world.isAlive(part.found_skeleton) and app.world.has(part.found_skeleton, Skeleton3D)) return part.found_skeleton;
    var above = app.parentOf(e);
    while (!above.isNone()) : (above = app.parentOf(above)) {
        if (skeletonUnder(app, above)) |found| {
            part.found_skeleton = found;
            return found;
        }
    }
    return null;
}

fn skeletonUnder(app: *App, root: Entity) ?Entity {
    if (app.world.has(root, Skeleton3D)) return root;
    for (app.children(root)) |child| {
        if (skeletonUnder(app, child)) |found| return found;
    }
    return null;
}

/// The body put where its bone is in the world, and how fast the bone went
/// to get there kept.
fn follow(app: *App, e: Entity, part: *PhysicalBone3D, owner: Entity, bone: u16, dt: f32) void {
    const globals = app.poses.globalsOf(app, owner) orelse return;
    const placed = hierarchy.worldTransform3D(&app.world, owner) orelse return;
    const at = math.Transform.fromMat4(placed.matrix().mul(globals[bone]));
    const was = hierarchy.worldTransform3D(&app.world, e) orelse return;
    if (dt > 0) {
        part.carried_velocity = at.translation.sub(was.position).scale(1 / dt);
        const speed = part.carried_velocity.len();
        if (speed > most_carried) part.carried_velocity = part.carried_velocity.scale(most_carried / speed);
        part.carried_spin = spinBetween(was.rotation.quat(), at.rotation, dt);
    }
    hierarchy.setWorldTransform3D(&app.world, e, .{ .position = at.translation, .rotation = .of(at.rotation.norm()), .scale = was.scale }) catch {};
}

/// How fast, in radians a second about each axis, `from` turned to `to` in
/// `dt`.
pub fn spinBetween(from: math.Quat, to: math.Quat, dt: f32) Vec3 {
    var turn = to.mul(from.inverse()).norm();
    if (turn.w < 0) turn = .{ .x = -turn.x, .y = -turn.y, .z = -turn.z, .w = -turn.w };
    const half = @sqrt(turn.x * turn.x + turn.y * turn.y + turn.z * turn.z);
    if (half < 1e-6) return .zero;
    const angle = 2 * std.math.atan2(half, turn.w);
    return Vec3.init(turn.x, turn.y, turn.z).scale(angle / half / dt);
}

/// Each simulated bone put where its body is, the bones nearer the root
/// first, so a bone's parent is where it will be when the bone is placed
/// from it.
fn drive(app: *App, driven: []const Driven) !void {
    const alpha = app.time.alpha();
    for (driven, 0..) |first, at| {
        // Each skeleton once, from its first bone in the list.
        const seen = for (driven[0..at]) |before| {
            if (before.skeleton.eql(first.skeleton)) break true;
        } else false;
        if (seen) continue;
        const pose = app.poses.of(app, first.skeleton) orelse continue;
        const skeleton = app.skeletons.get(pose.skeleton).?;
        const placed = hierarchy.resolveEntity3D(&app.world, &app.snapshots3d, first.skeleton, alpha) orelse continue;
        const back = placed.matrix().inverseAffine() orelse continue;
        for (skeleton.order) |bone| {
            const body = for (driven[at..]) |d| {
                if (d.skeleton.eql(first.skeleton) and d.bone == bone) break d.body;
            } else continue;
            const now = hierarchy.resolveEntity3D(&app.world, &app.snapshots3d, body, alpha) orelse continue;
            const in_skeleton = back.mul((math.Transform{ .translation = now.position, .rotation = now.rotation.quat() }).toMat4());
            const globals = app.poses.globalsOf(app, first.skeleton) orelse break;
            const local = if (skeleton.bones[bone].parent) |parent| (globals[parent].inverseAffine() orelse continue).mul(in_skeleton) else in_skeleton;
            const put = math.Transform.fromMat4(local);
            pose.locals[bone].translation = put.translation;
            pose.locals[bone].rotation = put.rotation.norm();
            pose.moved();
        }
    }
}

test "a spin from one turn to another, a second apart, is the turn's axis times its angle" {
    const from = math.Quat.fromAxisAngle(.unit_y, 0.2);
    const to = math.Quat.fromAxisAngle(.unit_y, 0.7).mul(math.Quat.identity);
    const spin = spinBetween(from, to, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 1), spin.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), spin.x, 1e-4);
    try testing.expect(spinBetween(from, from, 0.1).eql(.zero));
}
