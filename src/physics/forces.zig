// SPDX-License-Identifier: BSD-3-Clause

//! Pushes on a `RigidBody2D` from code: a kick at once, or a push for the
//! next physics step, and either of them turning. Only a dynamic body moves.

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const physics = @import("fluxion_physics");

const App = @import("../App.zig");
const RigidBody2D = @import("../scene/components.zig").RigidBody2D;

const Entity = ecs.Entity;
const Vec2 = math.Vec2;

/// A `RigidBody2D`'s body in the physics, made now if the physics has not
/// seen it yet, and woken to move.
fn awakeBody(app: *App, entity: Entity) error{ NotABody, OutOfMemory }!*physics.Body {
    if (!app.world.has(entity, RigidBody2D)) return error.NotABody;
    const id = app.bodies.idOf(entity) orelse blk: {
        app.syncBodies() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NotABody,
        };
        break :blk app.bodies.idOf(entity) orelse return error.NotABody;
    };
    const held = app.physics.body(id) orelse return error.NotABody;
    held.wake();
    return held;
}

/// A kick: the body's velocity changed at once by `impulse` over its mass -
/// a jump, a bullet, an explosion. At `offset` from its middle, in the
/// world's directions, it turns too. Only a dynamic body moves.
pub fn applyImpulse(app: *App, body: Entity, impulse: Vec2, offset: Vec2) error{ NotABody, OutOfMemory }!void {
    const held = try awakeBody(app, body);
    held.applyImpulse(impulse, held.position().add(offset));
}

/// A push for the next physics step, at `offset` from the body's middle: a
/// thruster, wind. Given again every step it keeps pushing - from `fixed`.
pub fn applyForce(app: *App, body: Entity, force: Vec2, offset: Vec2) error{ NotABody, OutOfMemory }!void {
    const held = try awakeBody(app, body);
    held.applyForceAt(force, held.position().add(offset));
}

/// A turning push for the next physics step, clockwise on screen.
pub fn applyTorque(app: *App, body: Entity, torque: f32) error{ NotABody, OutOfMemory }!void {
    const held = try awakeBody(app, body);
    held.applyTorque(torque);
}

/// A turning kick: the spin changed at once.
pub fn applyTorqueImpulse(app: *App, body: Entity, impulse: f32) error{ NotABody, OutOfMemory }!void {
    const held = try awakeBody(app, body);
    held.applyAngularImpulse(impulse);
}
