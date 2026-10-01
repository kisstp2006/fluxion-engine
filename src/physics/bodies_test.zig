// SPDX-License-Identifier: BSD-3-Clause

//! Bodies through a whole app, headless: falling, resting, colliding, one-way
//! colliders, exceptions, and what the components say reaching the physics.

const std = @import("std");
const testing = std.testing;

const Bodies = @import("bodies.zig");
const App = @import("../App.zig");
const earth = @import("../test_helpers.zig").earth;
const Area2D = components.Area2D;
const Collider2D = components.Collider2D;
const Entity = ecs.Entity;
const RigidBody2D = components.RigidBody2D;
const Sprite = components.Sprite;
const Transform2D = components.Transform2D;
const components = @import("../scene/components.zig");
const physics = @import("fluxion_physics");
const ecs = @import("fluxion_ecs");

const scene = @import("../scene/scene.zig");

/// Earth's pull at a hundred units to the metre, with nothing slowing a
/// body down: what these tests' numbers were worked out for. The defaults
/// have tests of their own.
fn headless(frame_time: f32) !*App {
    return App.create(testing.allocator, .{ .headless = true, .frame_time = frame_time, .physics_2d = earth });
}

fn frames(app: *App, count: usize) !void {
    for (0..count) |_| _ = try app.step();
}

test "a crate falls onto a floor and comes to rest on it" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const floor = try app.world.spawnWith(.{ Transform2D.at(0, 100), Collider2D.rectangle(200, 10) });
    const crate = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{}, Collider2D.rectangle(10, 10) });

    try frames(app, 120);
    try testing.expectApproxEqAbs(@as(f32, 80), app.world.get(crate, Transform2D).?.y, 1);
    try testing.expectApproxEqAbs(@as(f32, 0), app.world.get(crate, RigidBody2D).?.linear_velocity.y, 1);
    try testing.expectEqual(physics.BodyType.static, app.bodyOf(floor).?.type);
    try testing.expectEqual(@as(usize, 2), app.physics.bodyCount());
}

test "a body falling says how fast, in its component" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const stone = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{}, Collider2D.circle(4) });

    try frames(app, 30);
    // Half a second of 981 units a second squared.
    try testing.expectApproxEqAbs(@as(f32, 490), app.world.get(stone, RigidBody2D).?.linear_velocity.y, 20);
}

test "writing the transform moves the body, and writing the velocity sets it going" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const puck = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{ .gravity_scale = 0 }, Collider2D.circle(5) });
    try frames(app, 1);

    app.world.get(puck, Transform2D).?.x = 50;
    try frames(app, 1);
    try testing.expectApproxEqAbs(@as(f32, 50), app.bodyOf(puck).?.position().x, 0.001);

    app.world.get(puck, RigidBody2D).?.linear_velocity = .init(60, 0);
    try frames(app, 1);
    try testing.expectApproxEqAbs(@as(f32, 51), app.world.get(puck, Transform2D).?.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 60), app.world.get(puck, RigidBody2D).?.linear_velocity.x, 0.001);
}

test "a contact is heard once a frame however many steps ran, and once a step in .fixed" {
    const Heard = struct {
        var in_frames: usize = 0;
        var in_steps: usize = 0;

        fn update(a: *App) anyerror!void {
            in_frames += a.contactsBegun().len;
        }

        fn fixed(a: *App) anyerror!void {
            in_steps += a.contactsBegun().len;
        }
    };
    Heard.in_frames = 0;
    Heard.in_steps = 0;

    // Four steps a frame.
    const app = try headless(4.0 / 60.0);
    defer app.destroy();
    try app.addSystem(.update, "count frames", Heard.update);
    try app.addSystem(.fixed, "count steps", Heard.fixed);
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 100), Collider2D.rectangle(200, 10) });
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 70), RigidBody2D{}, Collider2D.rectangle(10, 10) });

    try frames(app, 10);
    try testing.expectEqual(@as(usize, 1), Heard.in_frames);
    try testing.expectEqual(@as(usize, 1), Heard.in_steps);
}

test "a despawned entity takes its body with it, and its contacts end naming it" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const floor = try app.world.spawnWith(.{ Transform2D.at(0, 100), Collider2D.rectangle(200, 10) });
    const crate = try app.world.spawnWith(.{ Transform2D.at(0, 79), RigidBody2D{}, Collider2D.rectangle(10, 10) });
    try frames(app, 5);
    try testing.expectEqual(@as(usize, 2), app.physics.bodyCount());

    app.world.despawn(crate);
    try frames(app, 1);
    try testing.expectEqual(@as(usize, 1), app.physics.bodyCount());
    const ended_now = app.contactsEnded();
    try testing.expectEqual(@as(usize, 1), ended_now.len);
    try testing.expect(ended_now[0].other(floor).?.eql(crate));
}

test "a sensor is heard and pushes nothing" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    var zone = Collider2D.rectangle(50, 50);
    zone.sensor = true;
    const pit = try app.world.spawnWith(.{ Transform2D.at(0, 200), zone });
    const stone = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{}, Collider2D.circle(4) });

    var heard = false;
    for (0..60) |_| {
        _ = try app.step();
        for (app.contactsBegun()) |contact| {
            if (contact.sensor and contact.other(pit) != null) heard = true;
        }
    }
    try testing.expect(heard);
    // It fell straight through.
    try testing.expect(app.world.get(stone, Transform2D).?.y > 300);
}

test "a ray finds what it hits first, and a point what is under it" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const near = try app.world.spawnWith(.{ Transform2D.at(50, 0), Collider2D.rectangle(5, 5) });
    const far = try app.world.spawnWith(.{ Transform2D.at(100, 0), Collider2D.rectangle(5, 5) });
    try app.syncBodies();

    const hit = app.castRay(.init(0, 0), .init(200, 0), 0xFFFF_FFFF, false).?;
    try testing.expect(hit.shape.eql(near) and hit.collider.eql(near));
    try testing.expectApproxEqAbs(@as(f32, 45), hit.point.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -1), hit.normal.x, 0.001);

    try testing.expect(app.overlapPoint(.init(102, 3)).?.eql(far));
    try testing.expect(app.overlapPoint(.init(75, 0)) == null);

    var found: [4]Entity = undefined;
    try testing.expectEqual(@as(usize, 2), app.overlapBox(.init(40, -10), .init(110, 10), &found).len);
    try testing.expectEqual(@as(usize, 1), app.overlapBox(.init(40, -10), .init(110, 10), found[0..1]).len);
}

test "an area follows a moving parent" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();

    const carrier = try app.world.spawnWith(.{Transform2D.at(20, 0)});
    const button = try app.world.spawnWith(.{
        Transform2D.at(5, 0),
        components.Parent.of(carrier),
        Area2D{},
        Collider2D.rectangle(4, 4),
    });
    try app.syncBodies();
    try testing.expect(app.overlapPoint(.init(25, 0)).?.eql(button));

    app.world.get(carrier, Transform2D).?.x = 100;
    try app.syncBodies();
    try testing.expect(app.overlapPoint(.init(25, 0)) == null);
    try testing.expect(app.overlapPoint(.init(105, 0)).?.eql(button));
}

test "a collider hanging from a body is part of that body" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const hull = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{ .gravity_scale = 0 }, Collider2D.rectangle(5, 5) });
    const arm = try app.world.spawnWith(.{ Transform2D.at(20, 0), components.Parent.of(hull), Collider2D.rectangle(5, 5) });
    try app.syncBodies();

    try testing.expectEqual(@as(usize, 1), app.physics.bodyCount());
    try testing.expectEqual(@as(usize, 2), app.physics.shapeCount());
    try testing.expect(app.bodyIdOf(arm).?.eql(app.bodyIdOf(hull).?));
    try testing.expect(app.overlapPoint(.init(22, 0)).?.eql(arm));

    // Turned a quarter, the arm is below the hull, and still part of it.
    app.world.get(hull, Transform2D).?.rotation = std.math.pi / 2.0;
    try app.syncBodies();
    try testing.expect(app.overlapPoint(.init(0, 22)).?.eql(arm));
    try testing.expectEqual(@as(usize, 2), app.physics.shapeCount());
}

test "a collider with no size takes its sprite's, centred on the sprite" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const centred = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite.solid(.white, 30, 10), Collider2D{} });
    var corner = Sprite.solid(.white, 30, 10);
    corner.pivot_x = 0;
    corner.pivot_y = 0;
    const cornered = try app.world.spawnWith(.{ Transform2D.at(100, 0), corner, Collider2D{} });
    try app.syncBodies();

    try testing.expect(app.overlapPoint(.init(14, 4)).?.eql(centred));
    try testing.expect(app.overlapPoint(.init(16, 0)) == null);
    try testing.expect(app.overlapPoint(.init(125, 8)).?.eql(cornered));
    try testing.expect(app.overlapPoint(.init(95, 5)) == null);
}

test "a transform's scale scales its collider" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const big = try app.world.spawnWith(.{ Transform2D.at(0, 0).scaled(2), Collider2D.rectangle(5, 5) });
    try app.syncBodies();
    try testing.expect(app.overlapPoint(.init(9, 0)).?.eql(big));

    app.world.get(big, Transform2D).?.scale_x = 1;
    try app.syncBodies();
    try testing.expect(app.overlapPoint(.init(9, 0)) == null);
}

test "changing a body's type makes it anew" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const crate = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{}, Collider2D.rectangle(5, 5) });
    try frames(app, 1);
    const was = app.bodyIdOf(crate).?;

    app.world.get(crate, RigidBody2D).?.type = .static;
    try frames(app, 1);
    try testing.expect(!app.bodyIdOf(crate).?.eql(was));
    try testing.expectEqual(physics.BodyType.static, app.bodyOf(crate).?.type);
    try testing.expectEqual(@as(usize, 1), app.physics.bodyCount());
    try testing.expectEqual(@as(usize, 1), app.physics.shapeCount());
}

test "a moving parent does not carry a body, whose place is written in the parent's space" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const cart = try app.world.spawnWith(.{Transform2D.at(100, 0)});
    const rider = try app.world.spawnWith(.{ Transform2D.at(10, 0), components.Parent.of(cart), RigidBody2D{ .gravity_scale = 0 }, Collider2D.circle(2) });
    try frames(app, 1);
    try testing.expectApproxEqAbs(@as(f32, 110), app.bodyOf(rider).?.position().x, 0.001);

    app.world.get(cart, Transform2D).?.x = 200;
    try frames(app, 1);
    try testing.expectApproxEqAbs(@as(f32, 110), app.bodyOf(rider).?.position().x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -90), app.world.get(rider, Transform2D).?.x, 0.001);
}

test "a static collider goes where its transform does, and is found there after the next step" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const door = try app.world.spawnWith(.{ Transform2D.at(0, 0), Collider2D.rectangle(5, 5) });
    try frames(app, 1);
    app.world.get(door, Transform2D).?.x = 40;
    try frames(app, 1);
    try testing.expectApproxEqAbs(@as(f32, 40), app.bodyOf(door).?.position().x, 0.001);
    try testing.expect(app.overlapPoint(.init(0, 0)) == null);
    try testing.expect(app.overlapPoint(.init(40, 0)).?.eql(door));
}

test "a scene keeps bodies and colliders, and loading one makes them" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 100), Collider2D.rectangle(200, 10) });
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{ .continuous_cd = .cast_ray }, Collider2D.circle(5) });
    const text = try scene.write(app, testing.allocator, .{});
    defer testing.allocator.free(text);

    const copy = try headless(1.0 / 60.0);
    defer copy.destroy();
    _ = try scene.read(copy, text, .{});
    try copy.syncBodies();
    try testing.expectEqual(@as(usize, 2), copy.physics.bodyCount());
    try testing.expectEqual(@as(usize, 2), copy.physics.shapeCount());
}

test "clearing the world takes every body with it" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 100), Collider2D.rectangle(200, 10) });
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{}, Collider2D.circle(5) });
    try frames(app, 1);

    app.clearWorld();
    try frames(app, 1);
    try testing.expectEqual(@as(usize, 0), app.physics.bodyCount());
}

test "a body's damping of minus one is the project's, and its own is its own" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const drifting = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{}, Collider2D.circle(4) });
    const braked = try app.world.spawnWith(.{ Transform2D.at(50, 0), RigidBody2D{ .linear_damp = 3, .angular_damp = 0 }, Collider2D.circle(4) });
    try app.syncBodies();
    // The defaults, with no project file to say otherwise.
    try testing.expectEqual(@as(f32, 0.1), app.bodyOf(drifting).?.linear_damping);
    try testing.expectEqual(@as(f32, 1), app.bodyOf(drifting).?.angular_damping);
    try testing.expectEqual(@as(f32, 3), app.bodyOf(braked).?.linear_damping);
    try testing.expectEqual(@as(f32, 0), app.bodyOf(braked).?.angular_damping);

    app.world.get(braked, RigidBody2D).?.linear_damp = -1;
    try app.syncBodies();
    try testing.expectEqual(@as(f32, 0.1), app.bodyOf(braked).?.linear_damping);
}

test "gravity is the project's, and the rules for touching are the engine's whatever a game passes" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try testing.expectEqual(@as(f32, 98), app.physics.gravity.y);
    try testing.expectEqual(@as(f32, 0), app.physics.gravity.x);

    const sideways = try App.create(testing.allocator, .{
        .headless = true,
        .physics = .{ .units_per_metre = 100, .filter_rule = .both, .friction_mix = .geometric_mean },
        .physics_2d = .{ .default_gravity = 30, .default_gravity_vector = .init(1, 0) },
    });
    defer sideways.destroy();
    try testing.expectEqual(@as(f32, 30), sideways.physics.gravity.x);
    try testing.expectEqual(physics.FilterRule.either, sideways.physics.settings.filter_rule);
    try testing.expectEqual(physics.Mix.minimum, sideways.physics.settings.friction_mix);
    try testing.expectEqual(physics.Mix.sum_clamped, sideways.physics.settings.restitution_mix);
}

test "two colliders touch when either one's mask has the other's layer" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    var floor = Collider2D.rectangle(200, 10);
    floor.collision_mask = 1 << 1;
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 100), floor });
    // On layer two, looking for nothing: the floor looks for it.
    var looked_for = Collider2D.rectangle(10, 10);
    looked_for.collision_layer = 1 << 1;
    looked_for.collision_mask = 0;
    const crate = try app.world.spawnWith(.{ Transform2D.at(-50, 0), RigidBody2D{}, looked_for });
    // On layer three, looking for nothing: nobody's.
    var unseen = looked_for;
    unseen.collision_layer = 1 << 2;
    const ghost = try app.world.spawnWith(.{ Transform2D.at(50, 0), RigidBody2D{}, unseen });
    try frames(app, 120);
    try testing.expectApproxEqAbs(@as(f32, 80), app.world.get(crate, Transform2D).?.y, 1);
    try testing.expect(app.world.get(ghost, Transform2D).?.y > 300);
}

test "a disabled collider is not there until it is turned back on" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    var trapdoor = Collider2D.rectangle(200, 10);
    trapdoor.disabled = true;
    const floor = try app.world.spawnWith(.{ Transform2D.at(0, 100), trapdoor });
    const early = try app.world.spawnWith(.{ Transform2D.at(-50, 0), RigidBody2D{}, Collider2D.rectangle(10, 10) });
    try frames(app, 60);
    try testing.expect(app.world.get(early, Transform2D).?.y > 300);
    // The crate's shape and none of the floor's.
    try testing.expectEqual(@as(usize, 1), app.physics.shapeCount());

    app.world.get(floor, Collider2D).?.disabled = false;
    const late = try app.world.spawnWith(.{ Transform2D.at(50, 0), RigidBody2D{}, Collider2D.rectangle(10, 10) });
    try frames(app, 120);
    try testing.expectApproxEqAbs(@as(f32, 80), app.world.get(late, Transform2D).?.y, 1);

    // And off again, what stands on it falls.
    app.world.get(floor, Collider2D).?.disabled = true;
    try frames(app, 60);
    try testing.expect(app.world.get(late, Transform2D).?.y > 300);
}

test "a one-way collider holds a crate that lands on it and lets one up through it from below" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    var ledge = Collider2D.rectangle(200, 10);
    ledge.one_way_collision = true;
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 100), ledge });
    const lands = try app.world.spawnWith(.{ Transform2D.at(-50, 0), RigidBody2D{}, Collider2D.rectangle(10, 10) });
    // Under the ledge, thrown up well past it.
    const jumps = try app.world.spawnWith(.{ Transform2D.at(50, 160), RigidBody2D{ .linear_velocity = .init(0, -700) }, Collider2D.rectangle(10, 10) });
    var cleared = false;
    for (0..180) |_| {
        _ = try app.step();
        if (app.world.get(jumps, Transform2D).?.y < 0) cleared = true;
    }
    try testing.expect(cleared);
    try testing.expectApproxEqAbs(@as(f32, 80), app.world.get(lands, Transform2D).?.y, 1);
    try testing.expectApproxEqAbs(@as(f32, 80), app.world.get(jumps, Transform2D).?.y, 1);
}

test "a one-way collider turned over holds from below instead, and so does one turned by its own rotation" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    var ledge = Collider2D.rectangle(100, 10);
    ledge.one_way_collision = true;
    // Its entity half round: its own +y points up the screen.
    _ = try app.world.spawnWith(.{ Transform2D{ .x = -150, .y = 100, .rotation = std.math.pi }, ledge });
    // The collider half round on an entity that is not.
    var turned = ledge;
    turned.rotation = std.math.pi;
    _ = try app.world.spawnWith(.{ Transform2D.at(150, 100), turned });
    // Flipped upside down by its scale.
    _ = try app.world.spawnWith(.{ Transform2D{ .x = 450, .y = 100, .scale_y = -1 }, ledge });
    const first = try app.world.spawnWith(.{ Transform2D.at(-150, 0), RigidBody2D{}, Collider2D.rectangle(10, 10) });
    const second = try app.world.spawnWith(.{ Transform2D.at(150, 0), RigidBody2D{}, Collider2D.rectangle(10, 10) });
    const third = try app.world.spawnWith(.{ Transform2D.at(450, 0), RigidBody2D{}, Collider2D.rectangle(10, 10) });
    try frames(app, 60);
    try testing.expect(app.world.get(first, Transform2D).?.y > 300);
    try testing.expect(app.world.get(second, Transform2D).?.y > 300);
    try testing.expect(app.world.get(third, Transform2D).?.y > 300);
}

test "a collision exception keeps two bodies apart, outlasts a body made anew, and goes with an entity" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const floor = try app.world.spawnWith(.{ Transform2D.at(0, 100), Collider2D.rectangle(200, 10) });
    const crate = try app.world.spawnWith(.{ Transform2D.at(-50, 0), RigidBody2D{ .type = .kinematic }, Collider2D.rectangle(10, 10) });
    const other = try app.world.spawnWith(.{ Transform2D.at(50, 0), RigidBody2D{}, Collider2D.rectangle(10, 10) });
    // Told before any body is made, twice: the physics hears of it once the
    // bodies are there.
    try app.addCollisionExceptionWith(crate, floor);
    try app.addCollisionExceptionWith(floor, crate);
    try testing.expectError(error.SameBody, app.addCollisionExceptionWith(crate, crate));
    const area = try app.world.spawnWith(.{ Transform2D.at(0, -300), components.Area2D{}, Collider2D.rectangle(5, 5) });
    try testing.expectError(error.NotABody, app.addCollisionExceptionWith(crate, area));
    try frames(app, 1);
    try testing.expect(app.physics.hasCollisionException(app.bodyIdOf(crate).?, app.bodyIdOf(floor).?));

    var found: [4]Entity = undefined;
    try testing.expectEqual(@as(usize, 1), app.collisionExceptionsOf(floor, &found).len);
    try testing.expect(found[0].eql(crate));

    // Made anew as a dynamic body, it still falls through the floor, and
    // the other lands on it.
    app.world.get(crate, RigidBody2D).?.type = .dynamic;
    try frames(app, 120);
    try testing.expect(app.world.get(crate, Transform2D).?.y > 300);
    try testing.expectApproxEqAbs(@as(f32, 80), app.world.get(other, Transform2D).?.y, 1);

    // Taken back once of twice, it stays; twice, it is gone, from the
    // physics too.
    app.removeCollisionExceptionWith(crate, floor);
    try testing.expectEqual(@as(usize, 1), app.collisionExceptionsOf(crate, &found).len);
    app.removeCollisionExceptionWith(floor, crate);
    try testing.expectEqual(@as(usize, 0), app.collisionExceptionsOf(crate, &found).len);
    try testing.expect(!app.physics.hasCollisionException(app.bodyIdOf(crate).?, app.bodyIdOf(floor).?));

    // One naming an entity that is gone goes with it.
    try app.addCollisionExceptionWith(other, floor);
    app.world.despawn(other);
    try frames(app, 1);
    try testing.expectEqual(@as(usize, 0), app.collisionExceptionsOf(floor, &found).len);
}

test "what a collider and its body say reaches the shape and the body the physics has" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    var said = Collider2D.circle(4);
    said.friction = 0.25;
    said.bounce = 0.75;
    said.density = 3;
    said.collision_layer = 1 << 31;
    said.collision_mask = 1 << 30;
    const ball = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{ .continuous_cd = .cast_shape }, said });
    const plain = try app.world.spawnWith(.{ Transform2D.at(50, 0), RigidBody2D{}, Collider2D.circle(4) });
    try app.syncBodies();

    const body = app.bodyOf(ball).?;
    try testing.expect(body.bullet);
    try testing.expect(!app.bodyOf(plain).?.bullet);
    const shape = app.physics.shape(body.first_shape).?.def;
    try testing.expectEqual(@as(f32, 0.25), shape.material.friction);
    try testing.expectEqual(@as(f32, 0.75), shape.material.restitution);
    try testing.expectEqual(@as(f32, 3), shape.material.density);
    try testing.expectEqual(@as(u32, 1 << 31), shape.filter.category);
    try testing.expectEqual(@as(u32, 1 << 30), shape.filter.mask);
    try testing.expect(shape.one_way == null);
}
