// SPDX-License-Identifier: BSD-3-Clause

//! Characters, headless: falling onto a floor and standing on it, walking
//! into a wall and stopping, standing on a slope and walking down it, seen
//! from above, pushed out of what they are in, a one-way platform jumped up
//! through, and a script that walks one.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("App.zig");
const components = @import("components.zig");
const script = @import("script.zig");

const Entity = ecs.Entity;
const Vec2 = math.Vec2;
const Transform2D = components.Transform2D;
const Collider2D = components.Collider2D;
const CharacterBody2D = components.CharacterBody2D;

const dt: f32 = 1.0 / 60.0;

/// A floor whose top is at y = 90, from x = -500 to 500, and a wall whose
/// left face is at x = 190 standing on it.
fn level() !struct { app: *App, floor: Entity, wall: Entity } {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 64, .height = 64 });
    errdefer app.destroy();
    const floor = try app.world.spawnWith(.{ Transform2D.at(0, 100), Collider2D.rectangle(500, 10) });
    const wall = try app.world.spawnWith(.{ Transform2D.at(200, 40), Collider2D.rectangle(10, 50) });
    try app.syncBodies();
    app.time.delta = dt;
    return .{ .app = app, .floor = floor, .wall = wall };
}

/// A capsule forty tall and ten round, at `x, y`.
fn person(app: *App, x: f32, y: f32, body: CharacterBody2D) !Entity {
    return app.world.spawnWith(.{ Transform2D.at(x, y), Collider2D.capsule(10, 40), body });
}

fn fall(app: *App, e: Entity, steps: usize) !void {
    for (0..steps) |_| {
        app.world.get(e, CharacterBody2D).?.velocity.y += 900 * dt;
        _ = try app.moveAndSlide(e);
    }
}

test "a character falls onto the floor and stands on it, walks, and stops at a wall" {
    const it = try level();
    const app = it.app;
    defer app.destroy();
    const player = try person(app, 0, 0, .{});

    try fall(app, player, 90);
    const standing = app.world.get(player, CharacterBody2D).?.*;
    try testing.expect(standing.on_floor);
    try testing.expect(standing.floor_normal.approxEql(.init(0, -1)));
    try testing.expectEqual(@as(f32, 0), standing.velocity.y);
    // Its bottom, twenty below its middle, a margin clear of y = 90.
    try testing.expectApproxEqAbs(@as(f32, 69.5), app.world.get(player, Transform2D).?.y, 0.3);
    try testing.expect(app.isOnFloor(player, 1));

    // Walking right along the floor to the wall, and stopped there.
    for (0..120) |_| {
        const body = app.world.get(player, CharacterBody2D).?;
        body.velocity.x = 200;
        body.velocity.y += 900 * dt;
        _ = try app.moveAndSlide(player);
    }
    const stopped = app.world.get(player, CharacterBody2D).?.*;
    try testing.expect(stopped.on_wall);
    try testing.expect(stopped.on_floor);
    try testing.expect(stopped.wall_normal.approxEql(.init(-1, 0)));
    try testing.expectEqual(@as(f32, 0), stopped.velocity.x);
    try testing.expectApproxEqAbs(@as(f32, 179.5), app.world.get(player, Transform2D).?.x, 0.3);
    try testing.expectApproxEqAbs(@as(f32, 69.5), app.world.get(player, Transform2D).?.y, 0.3);
}

test "on a slope a character stands still, and walking down it keeps to it" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 64, .height = 64 });
    defer app.destroy();
    // A long plank turned twenty degrees: its right end lower, y being down.
    var slope = Collider2D.rectangle(400, 10);
    slope.rotation = 20 * std.math.pi / 180.0;
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 100), slope });
    try app.syncBodies();
    app.time.delta = dt;
    const player = try person(app, 0, 40, .{});
    try fall(app, player, 90);
    const rested = app.world.get(player, Transform2D).?.*;
    try testing.expect(app.world.get(player, CharacterBody2D).?.on_floor);
    try fall(app, player, 60);
    // Still where it stood.
    try testing.expectApproxEqAbs(rested.x, app.world.get(player, Transform2D).?.x, 0.2);

    // Walking down it, it is on the floor every step, not falling off it.
    for (0..40) |_| {
        const body = app.world.get(player, CharacterBody2D).?;
        body.velocity.x = 150;
        body.velocity.y += 900 * dt;
        _ = try app.moveAndSlide(player);
        try testing.expect(app.world.get(player, CharacterBody2D).?.on_floor);
    }
    try testing.expect(app.world.get(player, Transform2D).?.x > rested.x + 80);
}

test "seen from above, everything is a wall, and a body slides along one" {
    const it = try level();
    const app = it.app;
    defer app.destroy();
    const mouse = try person(app, 150, 40, .{ .motion_mode = .floating });
    // Into the wall at a slant: stopped across, and going on along it -
    // still beside it after a third of a second.
    for (0..20) |_| {
        app.world.get(mouse, CharacterBody2D).?.velocity = .init(200, -100);
        _ = try app.moveAndSlide(mouse);
    }
    const state = app.world.get(mouse, CharacterBody2D).?.*;
    try testing.expect(state.on_wall and !state.on_floor);
    try testing.expectApproxEqAbs(@as(f32, 179.5), app.world.get(mouse, Transform2D).?.x, 0.3);
    try testing.expect(app.world.get(mouse, Transform2D).?.y < 20);
}

test "moveAndCollide says what stopped it, and a body pushed into the floor is put back out" {
    const it = try level();
    const app = it.app;
    defer app.destroy();
    const player = try person(app, 100, 40, .{});
    const hit = (try app.moveAndCollide(player, .init(100, 0))).?;
    try testing.expect(hit.collider.eql(it.wall));
    try testing.expect(hit.normal.approxEql(.init(-1, 0)));
    try testing.expectApproxEqAbs(@as(f32, 79.5), hit.travel.x, 0.3);
    try testing.expectApproxEqAbs(@as(f32, 20.5), hit.remainder.x, 0.3);
    try testing.expect((try app.moveAndCollide(player, .init(-50, 0))) == null);

    // Sunk ten into the floor, it comes out of it before it moves.
    app.world.get(player, Transform2D).?.y = 80;
    try app.syncBodies();
    _ = try app.moveAndSlide(player);
    try testing.expectApproxEqAbs(@as(f32, 69.5), app.world.get(player, Transform2D).?.y, 0.3);

    try testing.expectError(error.NotACharacter, app.moveAndSlide(it.wall));
}

test "a character jumps up through a one-way platform and stands on it" {
    const it = try level();
    const app = it.app;
    defer app.destroy();
    var platform = Collider2D.rectangle(60, 4);
    platform.one_way_collision = true;
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 20), platform });
    try app.syncBodies();
    const player = try person(app, 0, 69.5, .{});
    try fall(app, player, 5);
    try testing.expect(app.world.get(player, CharacterBody2D).?.on_floor);

    // Up through it, and down onto it.
    app.world.get(player, CharacterBody2D).?.velocity.y = -600;
    try fall(app, player, 90);
    try testing.expect(app.world.get(player, CharacterBody2D).?.on_floor);
    // On the platform's top, at y = 16: twenty and a margin above it.
    try testing.expectApproxEqAbs(@as(f32, -4.5), app.world.get(player, Transform2D).?.y, 0.3);
}

test "a script walks a character" {
    const it = try level();
    const app = it.app;
    defer app.destroy();
    try app.useScripts(.{});
    const handle = try app.addScript("walker.flux",
        \\var stood = false;
        \\struct Walker {
        \\    fn fixed(self, dt: float) {
        \\        const body = self.entity.get(CharacterBody2D);
        \\        body.velocity = vec2(120.0, body.velocity.y + 900.0 * dt);
        \\        app.moveAndSlide(self.entity);
        \\        if (body.on_floor) stood = true;
        \\    }
        \\}
    );
    const walker = try person(app, 0, 0, .{});
    try app.world.add(walker, script.Script.of(handle));
    app.time.source = .{ .fixed = dt };
    for (0..60) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
    const scripts = app.scripts.?;
    try testing.expect(scripts.vm.get(scripts.moduleOf(handle).?, "stood").?.asBool());
    try testing.expect(app.world.get(walker, Transform2D).?.x > 50);
}
