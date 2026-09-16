// SPDX-License-Identifier: BSD-3-Clause

//! Areas through a whole app: who is told what is in them, when, and what
//! the questions say between the signals.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");

const App = @import("App.zig");
const components = @import("components.zig");

const Entity = ecs.Entity;
const Area2D = components.Area2D;
const Collider2D = components.Collider2D;
const RigidBody2D = components.RigidBody2D;
const Transform2D = components.Transform2D;
const scene = @import("scene.zig");

/// What the handlers heard, in order.
const Seen = struct {
    var events: [64]Event = undefined;
    var len: usize = 0;

    const Kind = enum { body_in, body_out, body_shape_in, body_shape_out, area_in, area_out, area_shape_in, area_shape_out };
    const Event = struct {
        kind: Kind,
        area: Entity,
        object: Entity,
        other_shape: Entity = .none,
        local_shape: Entity = .none,
    };

    fn reset() void {
        len = 0;
    }

    fn note(event: Event) void {
        if (len == events.len) return;
        events[len] = event;
        len += 1;
    }

    fn count(kind: Kind) usize {
        var found: usize = 0;
        for (events[0..len]) |event| {
            if (event.kind == kind) found += 1;
        }
        return found;
    }

    fn first(kind: Kind) ?Event {
        for (events[0..len]) |event| {
            if (event.kind == kind) return event;
        }
        return null;
    }

    fn bodyIn(_: *App, self: Entity, body: Entity) !void {
        note(.{ .kind = .body_in, .area = self, .object = body });
    }
    fn bodyOut(_: *App, self: Entity, body: Entity) !void {
        note(.{ .kind = .body_out, .area = self, .object = body });
    }
    fn bodyShapeIn(_: *App, self: Entity, body: Entity, body_shape: Entity, local_shape: Entity) !void {
        note(.{ .kind = .body_shape_in, .area = self, .object = body, .other_shape = body_shape, .local_shape = local_shape });
    }
    fn bodyShapeOut(_: *App, self: Entity, body: Entity, body_shape: Entity, local_shape: Entity) !void {
        note(.{ .kind = .body_shape_out, .area = self, .object = body, .other_shape = body_shape, .local_shape = local_shape });
    }
    fn areaIn(_: *App, self: Entity, area: Entity) !void {
        note(.{ .kind = .area_in, .area = self, .object = area });
    }
    fn areaOut(_: *App, self: Entity, area: Entity) !void {
        note(.{ .kind = .area_out, .area = self, .object = area });
    }
    fn areaShapeIn(_: *App, self: Entity, area: Entity, area_shape: Entity, local_shape: Entity) !void {
        note(.{ .kind = .area_shape_in, .area = self, .object = area, .other_shape = area_shape, .local_shape = local_shape });
    }
    fn areaShapeOut(_: *App, self: Entity, area: Entity, area_shape: Entity, local_shape: Entity) !void {
        note(.{ .kind = .area_shape_out, .area = self, .object = area, .other_shape = area_shape, .local_shape = local_shape });
    }
};

fn headless() !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .frame_time = 1.0 / 60.0, .physics_2d = @import("bodies.zig").earth });
    errdefer app.destroy();
    try app.addMethod("_body_in", Seen.bodyIn);
    try app.addMethod("_body_out", Seen.bodyOut);
    try app.addMethod("_body_shape_in", Seen.bodyShapeIn);
    try app.addMethod("_body_shape_out", Seen.bodyShapeOut);
    try app.addMethod("_area_in", Seen.areaIn);
    try app.addMethod("_area_out", Seen.areaOut);
    try app.addMethod("_area_shape_in", Seen.areaShapeIn);
    try app.addMethod("_area_shape_out", Seen.areaShapeOut);
    Seen.reset();
    return app;
}

/// Every signal of an area, into the log, with the area as the target so
/// that each event says whose it was.
fn watch(app: *App, area: Entity) !void {
    try app.signal(area, Area2D, .body_entered).connect(.method(area, "_body_in"), .{});
    try app.signal(area, Area2D, .body_exited).connect(.method(area, "_body_out"), .{});
    try app.signal(area, Area2D, .body_shape_entered).connect(.method(area, "_body_shape_in"), .{});
    try app.signal(area, Area2D, .body_shape_exited).connect(.method(area, "_body_shape_out"), .{});
    try app.signal(area, Area2D, .area_entered).connect(.method(area, "_area_in"), .{});
    try app.signal(area, Area2D, .area_exited).connect(.method(area, "_area_out"), .{});
    try app.signal(area, Area2D, .area_shape_entered).connect(.method(area, "_area_shape_in"), .{});
    try app.signal(area, Area2D, .area_shape_exited).connect(.method(area, "_area_shape_out"), .{});
}

fn frames(app: *App, count: usize) !void {
    for (0..count) |_| _ = try app.step();
}

test "a body falling through an area is told entering and leaving, once each" {
    const app = try headless();
    defer app.destroy();
    const gate = try app.world.spawnWith(.{ Transform2D.at(0, 100), Area2D{}, Collider2D.rectangle(50, 20) });
    const stone = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{}, Collider2D.circle(4) });
    try watch(app, gate);

    try frames(app, 90);
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_in));
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_out));
    try testing.expect(Seen.first(.body_in).?.object.eql(stone));
    try testing.expect(Seen.first(.body_in).?.area.eql(gate));

    // The shape signals name the colliders, which are these entities.
    const shape_in = Seen.first(.body_shape_in).?;
    try testing.expect(shape_in.other_shape.eql(stone));
    try testing.expect(shape_in.local_shape.eql(gate));
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_shape_out));

    // It fell through: nothing pushed it.
    try testing.expect(app.world.get(stone, Transform2D).?.y > 200);
    try testing.expect(!app.hasOverlappingBodies(gate));
}

test "a kinematic body is in a still area while it is there, and the questions say so" {
    const app = try headless();
    defer app.destroy();
    const trigger = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, Collider2D.rectangle(30, 30) });
    const player = try app.world.spawnWith(.{
        Transform2D.at(-100, 0),
        RigidBody2D{ .type = .kinematic },
        Collider2D.rectangle(10, 10),
    });
    try watch(app, trigger);

    // Walked in from the left, held there, then out to the right.
    var found: [4]Entity = undefined;
    for (0..10) |_| {
        app.world.get(player, Transform2D).?.x += 10;
        _ = try app.step();
    }
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_in));
    try testing.expectEqual(@as(usize, 0), Seen.count(.body_out));
    try testing.expect(app.overlapsBody(trigger, player));
    try testing.expectEqual(@as(usize, 1), app.overlappingBodies(trigger, &found).len);
    try testing.expect(found[0].eql(player));
    try testing.expect(app.hasOverlappingBodies(trigger));
    try testing.expect(!app.hasOverlappingAreas(trigger));

    // Standing still inside it says nothing more.
    try frames(app, 10);
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_in));
    try testing.expectEqual(@as(usize, 0), Seen.count(.body_out));

    for (0..12) |_| {
        app.world.get(player, Transform2D).?.x += 10;
        _ = try app.step();
    }
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_out));
    try testing.expect(!app.overlapsBody(trigger, player));
    try testing.expectEqual(@as(usize, 0), app.overlappingBodies(trigger, &found).len);
}

test "a hitbox and the hurtbox that asks for it hear each other: Godot 3's layers go both ways" {
    const app = try headless();
    defer app.destroy();
    const hitboxes: u32 = 1 << 2;

    // The hitbox says what it is and asks for nothing.
    var swing = Collider2D.rectangle(15, 15);
    swing.collision_layer = hitboxes;
    swing.collision_mask = 0;
    const sword = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, swing });

    // The hurtbox is on no layer and asks for hitboxes.
    var skin = Collider2D.rectangle(15, 15);
    skin.collision_layer = 0;
    skin.collision_mask = hitboxes;
    const monster = try app.world.spawnWith(.{ Transform2D.at(200, 0), Area2D{}, skin });

    // A third on no layer that asks for nothing: nobody's.
    var nothing = Collider2D.rectangle(15, 15);
    nothing.collision_layer = 0;
    nothing.collision_mask = 0;
    const ghost = try app.world.spawnWith(.{ Transform2D.at(-200, 0), Area2D{}, nothing });

    try watch(app, sword);
    try watch(app, monster);
    try watch(app, ghost);
    app.world.get(sword, Transform2D).?.x = 195;
    try frames(app, 2);

    // One mask asking is enough, for both of them.
    try testing.expectEqual(@as(usize, 2), Seen.count(.area_in));
    try testing.expect(app.overlapsArea(monster, sword));
    try testing.expect(app.overlapsArea(sword, monster));

    // And out again, and over the ghost, which neither hears.
    app.world.get(sword, Transform2D).?.x = -195;
    try frames(app, 2);
    try testing.expectEqual(@as(usize, 2), Seen.count(.area_out));
    try testing.expect(!app.overlapsArea(sword, ghost));
    try testing.expect(!app.overlapsArea(ghost, sword));
}

test "an area that stops monitoring leaves what was in it, and answers nothing" {
    const app = try headless();
    defer app.destroy();
    const zone = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, Collider2D.rectangle(30, 30) });
    const thing = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{ .type = .kinematic }, Collider2D.rectangle(5, 5) });
    try watch(app, zone);

    try frames(app, 2);
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_in));

    app.world.get(zone, Area2D).?.monitoring = false;
    // Asked before the next step, it is empty already, where Godot errors.
    var early: [4]Entity = undefined;
    try testing.expectEqual(@as(usize, 0), app.overlappingBodies(zone, &early).len);
    try testing.expect(!app.overlapsBody(zone, thing));
    try frames(app, 1);
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_out));
    try testing.expect(Seen.first(.body_out).?.object.eql(thing));
    var found: [4]Entity = undefined;
    try testing.expectEqual(@as(usize, 0), app.overlappingBodies(zone, &found).len);
    try testing.expect(!app.overlapsBody(zone, thing));

    // Watching again finds it where it is.
    app.world.get(zone, Area2D).?.monitoring = true;
    try frames(app, 2);
    try testing.expectEqual(@as(usize, 2), Seen.count(.body_in));
    try testing.expect(app.overlapsBody(zone, thing));
}

test "what an area held is left with an exit when it is despawned" {
    const app = try headless();
    defer app.destroy();
    const pit = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, Collider2D.rectangle(30, 30) });
    const coin = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{ .type = .kinematic }, Collider2D.rectangle(5, 5) });
    try watch(app, pit);

    try frames(app, 2);
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_in));

    app.world.despawn(coin);
    try frames(app, 2);
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_out));
    // Named, though it has died since.
    try testing.expect(Seen.first(.body_out).?.object.eql(coin));
    try testing.expect(!app.hasOverlappingBodies(pit));
}

test "an area carries the colliders hanging from it, and every one of them is a sensor" {
    const app = try headless();
    defer app.destroy();
    const room = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{} });
    const left = try app.world.spawnWith(.{ Transform2D.childOf(room, -40, 0), Collider2D.rectangle(10, 10) });
    _ = try app.world.spawnWith(.{ Transform2D.childOf(room, 40, 0), Collider2D.rectangle(10, 10) });
    const walker = try app.world.spawnWith(.{ Transform2D.at(-40, 0), RigidBody2D{ .type = .kinematic }, Collider2D.rectangle(5, 5) });
    try watch(app, room);

    try testing.expect(app.collisionObjectOf(left).?.eql(room));
    try testing.expect(app.collisionObjectOf(walker).?.eql(walker));

    try frames(app, 2);
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_in));
    try testing.expect(Seen.first(.body_shape_in).?.local_shape.eql(left));

    // Across to the other shape: one shape pair ends as the other begins,
    // and the body never left the room.
    app.world.get(walker, Transform2D).?.x = 40;
    try frames(app, 2);
    try testing.expectEqual(@as(usize, 2), Seen.count(.body_shape_in));
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_shape_out));
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_in));
    try testing.expectEqual(@as(usize, 0), Seen.count(.body_out));
    try testing.expect(app.overlapsBody(room, walker));
    // A sensor pushes nothing: it walked through a shape rather than into it.
    try testing.expectApproxEqAbs(@as(f32, 40), app.world.get(walker, Transform2D).?.x, 0.001);
    try testing.expect(Seen.first(.body_shape_out).?.local_shape.eql(left));
}

test "an entity that is a body and an area is a body, and its area does nothing" {
    const app = try headless();
    defer app.destroy();
    const both = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, RigidBody2D{}, Collider2D.rectangle(10, 10) });
    const floor = try app.world.spawnWith(.{ Transform2D.at(0, 100), Collider2D.rectangle(200, 10) });
    try watch(app, both);

    try frames(app, 90);
    // It fell and landed, which a sensor would not have done.
    try testing.expectApproxEqAbs(@as(f32, 80), app.world.get(both, Transform2D).?.y, 1);
    try testing.expectEqual(@as(usize, 0), Seen.len);
    try testing.expect(app.collisionObjectOf(both).?.eql(both));
    _ = floor;
}

test "an area that is not monitorable is seen by bodies' contacts and not by areas" {
    const app = try headless();
    defer app.destroy();
    const ghost = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{ .monitorable = false }, Collider2D.rectangle(20, 20) });
    const eye = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, Collider2D.rectangle(20, 20) });
    const walker = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{ .type = .kinematic }, Collider2D.rectangle(5, 5) });
    try watch(app, eye);
    try watch(app, ghost);

    try frames(app, 2);
    // Both hear the body in them. The ghost monitors, so it hears the eye;
    // the eye cannot see the ghost, which is not monitorable.
    try testing.expectEqual(@as(usize, 2), Seen.count(.body_in));
    try testing.expectEqual(@as(usize, 1), Seen.count(.area_in));
    try testing.expect(Seen.first(.area_in).?.area.eql(ghost));
    try testing.expect(app.overlapsBody(eye, walker));
    try testing.expect(app.overlapsArea(ghost, eye));
    try testing.expect(!app.overlapsArea(eye, ghost));

    // Made monitorable while they are in one another: told from then on.
    app.world.get(ghost, Area2D).?.monitorable = true;
    try frames(app, 1);
    try testing.expectEqual(@as(usize, 2), Seen.count(.area_in));
    try testing.expect(app.overlapsArea(eye, ghost));
}

test "an area hears a body that asks for it, though the area asks for nothing" {
    const app = try headless();
    defer app.destroy();
    var listening = Collider2D.rectangle(20, 20);
    listening.collision_mask = 0;
    const ear = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, listening });

    var quiet = Collider2D.rectangle(5, 5);
    quiet.collision_layer = 0;
    const mouse = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{ .type = .kinematic }, quiet });
    try watch(app, ear);

    // The mouse is on no layer, and its mask has the ear's.
    try frames(app, 2);
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_in));
    try testing.expect(app.overlapsBody(ear, mouse));
}

test "an area moved over a still body finds it, and lets go as it moves on" {
    const app = try headless();
    defer app.destroy();
    const sweep = try app.world.spawnWith(.{ Transform2D.at(-100, 0), Area2D{}, Collider2D.rectangle(10, 10) });
    const post = try app.world.spawnWith(.{ Transform2D.at(0, 0), Collider2D.rectangle(10, 10) });
    try watch(app, sweep);

    for (0..12) |_| {
        app.world.get(sweep, Transform2D).?.x += 10;
        _ = try app.step();
    }
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_in));
    try testing.expect(Seen.first(.body_in).?.object.eql(post));

    for (0..12) |_| {
        app.world.get(sweep, Transform2D).?.x += 10;
        _ = try app.step();
    }
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_out));
    try testing.expect(!app.hasOverlappingBodies(sweep));
}

test "an area goes through a scene with its connections, and tells what is in it again" {
    const first = try headless();
    defer first.destroy();
    const gate = try first.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{ .monitorable = false }, Collider2D.rectangle(30, 30) });
    const walker = try first.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{ .type = .kinematic }, Collider2D.rectangle(5, 5) });
    try first.signal(gate, Area2D, .body_entered).connect(.method(gate, "_body_in"), .{ .flags = .{ .persist = true } });

    const bytes = try scene.write(first, testing.allocator, .{});
    defer testing.allocator.free(bytes);

    const again = try headless();
    defer again.destroy();
    const loaded = try scene.read(again, bytes, .{});
    try testing.expectEqual(@as(usize, 0), loaded.connections_skipped);
    try testing.expectEqual(@as(usize, 0), loaded.connections_unknown);

    const there = again.findUuid(first.uuidOf(gate).?).?;
    try testing.expect(!again.world.get(there, Area2D).?.monitorable);
    try testing.expectEqual(@as(usize, 1), again.connectionCount(there));

    Seen.reset();
    try frames(again, 2);
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_in));
    try testing.expect(Seen.first(.body_in).?.area.eql(there));
    try testing.expect(again.overlapsBody(there, again.findUuid(first.uuidOf(walker).?).?));
}

test "a body stays in an area while its collider is made anew, and leaves when no layer joins them" {
    const app = try headless();
    defer app.destroy();
    const trigger = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, Collider2D.rectangle(30, 30) });
    const player = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{ .type = .kinematic }, Collider2D.rectangle(10, 10) });
    try watch(app, trigger);
    try frames(app, 2);
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_in));

    // A new friction makes its shape anew where it was: nothing to say.
    app.world.get(player, Collider2D).?.friction = 0.5;
    try frames(app, 2);
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_in));
    try testing.expectEqual(@as(usize, 0), Seen.count(.body_out));
    try testing.expect(app.overlapsBody(trigger, player));

    // On no layer and looking for none: it leaves.
    app.world.get(player, Collider2D).?.collision_layer = 0;
    app.world.get(player, Collider2D).?.collision_mask = 0;
    try frames(app, 2);
    try testing.expectEqual(@as(usize, 1), Seen.count(.body_out));
    try testing.expect(!app.overlapsBody(trigger, player));
}
