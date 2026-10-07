// SPDX-License-Identifier: BSD-3-Clause

//! Pushes on a `RigidBody3D` from code: a kick at once, or a push for the
//! next physics step, and either of them turning. Only a dynamic body moves.

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const physics3d = @import("fluxion_physics3d");

const App = @import("../App.zig");
const RigidBody3D = @import("../scene/components.zig").RigidBody3D;

const Entity = ecs.Entity;
const Vec3 = math.Vec3;

pub const Error = error{ NotABody, OutOfMemory };

/// A `RigidBody3D`'s body in the physics, made now if the physics has not
/// seen it yet, and woken to move.
fn awakeBody(app: *App, entity: Entity) Error!*physics3d.Body {
    if (!app.world.has(entity, RigidBody3D)) return error.NotABody;
    const id = app.bodies3d.idOf(entity) orelse blk: {
        app.bodies3d.sync(app) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NotABody,
        };
        break :blk app.bodies3d.idOf(entity) orelse return error.NotABody;
    };
    const held = app.physics3d.body(id) orelse return error.NotABody;
    held.wake();
    return held;
}

/// A kick: the velocity changed at once by `impulse` over the mass. At
/// `offset` from its centre of mass, in the world's directions, it turns
/// too.
pub fn applyImpulse(app: *App, body: Entity, impulse: Vec3, offset: Vec3) Error!void {
    const held = try awakeBody(app, body);
    held.applyImpulse(impulse, held.center.add(offset));
}

/// A push for the next physics step, at `offset` from its centre of mass.
pub fn applyForce(app: *App, body: Entity, force: Vec3, offset: Vec3) Error!void {
    const held = try awakeBody(app, body);
    held.applyForce(force, held.center.add(offset));
}

/// A turning push for the next physics step, about the axis it points
/// along, as hard as it is long.
pub fn applyTorque(app: *App, body: Entity, torque: Vec3) Error!void {
    const held = try awakeBody(app, body);
    held.applyTorque(torque);
}

/// A turning kick: the spin changed at once.
pub fn applyTorqueImpulse(app: *App, body: Entity, impulse: Vec3) Error!void {
    const held = try awakeBody(app, body);
    held.applyAngularImpulse(impulse);
}
