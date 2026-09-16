// SPDX-License-Identifier: BSD-3-Clause

//! Picking through a whole app: what the pointer is over, what hears a
//! click, in which order, and who can stop it.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const platform = @import("fluxion_platform");

const App = @import("App.zig");
const components = @import("components.zig");
const pointer = @import("pointer.zig");

const Entity = ecs.Entity;
const Vec2 = math.Vec2;
const Area2D = components.Area2D;
const Camera2D = components.Camera2D;
const Collider2D = components.Collider2D;
const RigidBody2D = components.RigidBody2D;
const Sprite = components.Sprite;
const Transform2D = components.Transform2D;

/// What the handlers heard, in order.
const Heard = struct {
    var events: [32]Event = undefined;
    var len: usize = 0;
    /// Whether the next `_pick` handler takes the pointer.
    var stops = false;

    const Kind = enum { picked, entered, exited, shape_entered, shape_exited };
    const Event = struct {
        kind: Kind,
        object: Entity,
        shape: Entity = .none,
        what: ?pointer.InputEvent = null,
    };

    fn reset() void {
        len = 0;
        stops = false;
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

    fn nth(kind: Kind, which: usize) ?Event {
        var seen: usize = 0;
        for (events[0..len]) |event| {
            if (event.kind != kind) continue;
            if (seen == which) return event;
            seen += 1;
        }
        return null;
    }

    fn picked(app: *App, self: Entity, event: pointer.InputEvent, shape: Entity) !void {
        note(.{ .kind = .picked, .object = self, .shape = shape, .what = event });
        if (stops) app.input.setAsHandled();
    }
    fn entered(_: *App, self: Entity) !void {
        note(.{ .kind = .entered, .object = self });
    }
    fn exited(_: *App, self: Entity) !void {
        note(.{ .kind = .exited, .object = self });
    }
    fn shapeEntered(_: *App, self: Entity, shape: Entity) !void {
        note(.{ .kind = .shape_entered, .object = self, .shape = shape });
    }
    fn shapeExited(_: *App, self: Entity, shape: Entity) !void {
        note(.{ .kind = .shape_exited, .object = self, .shape = shape });
    }
};

fn headless() !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 400, .height = 200, .frame_time = 1.0 / 60.0 });
    errdefer app.destroy();
    try app.addMethod("_pick", Heard.picked);
    try app.addMethod("_in", Heard.entered);
    try app.addMethod("_out", Heard.exited);
    try app.addMethod("_shape_in", Heard.shapeEntered);
    try app.addMethod("_shape_out", Heard.shapeExited);
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 0), Camera2D{} });
    Heard.reset();
    return app;
}

/// Every picking signal of an object into the log, whichever kind it is.
fn watch(app: *App, object: Entity) !void {
    if (app.world.has(object, Area2D) and !app.world.has(object, RigidBody2D)) {
        try app.signal(object, Area2D, .input_event).connect(.method(object, "_pick"), .{});
        try app.signal(object, Area2D, .mouse_entered).connect(.method(object, "_in"), .{});
        try app.signal(object, Area2D, .mouse_exited).connect(.method(object, "_out"), .{});
        try app.signal(object, Area2D, .mouse_shape_entered).connect(.method(object, "_shape_in"), .{});
        try app.signal(object, Area2D, .mouse_shape_exited).connect(.method(object, "_shape_out"), .{});
    } else {
        try app.signal(object, RigidBody2D, .input_event).connect(.method(object, "_pick"), .{});
        try app.signal(object, RigidBody2D, .mouse_entered).connect(.method(object, "_in"), .{});
        try app.signal(object, RigidBody2D, .mouse_exited).connect(.method(object, "_out"), .{});
        try app.signal(object, RigidBody2D, .mouse_shape_entered).connect(.method(object, "_shape_in"), .{});
        try app.signal(object, RigidBody2D, .mouse_shape_exited).connect(.method(object, "_shape_out"), .{});
    }
}

/// A press or a release of the left button, at a point in the world.
fn click(app: *App, at: Vec2, down: bool) void {
    const on_screen = app.worldToScreen(at.x, at.y);
    app.input.apply(.{ .mouse_button = .{
        .window = .none,
        .button = .left,
        .action = if (down) .press else .release,
        .mods = .{},
        .x = on_screen.x,
        .y = on_screen.y,
    } });
}

/// The pointer moved to a point in the world.
fn move(app: *App, at: Vec2) void {
    const on_screen = app.worldToScreen(at.x, at.y);
    app.input.apply(.{ .cursor = .{
        .window = .none,
        .x = on_screen.x,
        .y = on_screen.y,
        .dx = 0,
        .dy = 0,
    } });
}

test "a click is heard by what is under it, with where it was and which collider" {
    const app = try headless();
    defer app.destroy();
    const button = try app.world.spawnWith(.{ Transform2D.at(50, 20), Area2D{}, Collider2D.box(40, 40) });
    try watch(app, button);

    click(app, .init(50, 20), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.count(.entered));
    try testing.expectEqual(@as(usize, 1), Heard.count(.shape_entered));
    try testing.expectEqual(@as(usize, 1), Heard.count(.picked));
    const first = Heard.nth(.picked, 0).?;
    try testing.expect(first.object.eql(button));
    try testing.expect(first.shape.eql(button));
    try testing.expect(first.what.?.isPressed(.left));
    try testing.expect(first.what.?.buttonMask().has(.left));
    // The event's place is the window's pixels, and the world's through it.
    const in_world = app.screenToWorld(first.what.?.position().x, first.what.?.position().y);
    try testing.expectApproxEqAbs(@as(f32, 50), in_world.x, 0.001);

    // The release is heard too, and nothing is entered again.
    click(app, .init(50, 20), false);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 2), Heard.count(.picked));
    try testing.expect(Heard.nth(.picked, 1).?.what.?.isReleased(.left));
    try testing.expectEqual(@as(usize, 1), Heard.count(.entered));

    // Away from it: it is left, shape and all.
    move(app, .init(-150, 0));
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.count(.exited));
    try testing.expectEqual(@as(usize, 1), Heard.count(.shape_exited));
}

test "a click through a camera that is moved, zoomed and turned lands where it looks" {
    const app = try headless();
    defer app.destroy();
    // The camera of `headless` is the only one; move, turn and zoom it.
    var it = try ecs.Query(.{ Transform2D, Camera2D }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(Transform2D), chunk.slice(Camera2D)) |*place, *view| {
            place.x = 120;
            place.y = -40;
            place.rotation = std.math.pi / 6.0;
            view.zoom = 2;
        }
    }
    const target = try app.world.spawnWith(.{ Transform2D.at(140, -30), Area2D{}, Collider2D.box(20, 20) });
    try watch(app, target);

    click(app, .init(140, -30), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.count(.picked));
    try testing.expect(Heard.nth(.picked, 0).?.object.eql(target));

    // A point outside the shape, through the same camera, hits nothing.
    click(app, .init(180, -30), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.count(.picked));
    try testing.expectEqual(@as(usize, 1), Heard.count(.exited));
}

test "what is drawn over the other is picked first, and first_only stops after it" {
    const app = try headless();
    defer app.destroy();
    const under = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite{ .layer = 1 }, Area2D{}, Collider2D.box(60, 60) });
    const over = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite{ .layer = 3 }, Area2D{}, Collider2D.box(60, 60) });
    try watch(app, under);
    try watch(app, over);

    click(app, .init(0, 0), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 2), Heard.count(.picked));
    try testing.expect(Heard.nth(.picked, 0).?.object.eql(over));
    try testing.expect(Heard.nth(.picked, 1).?.object.eql(under));

    // Only the first, and both are still hovered.
    Heard.reset();
    app.physics_object_picking_first_only = true;
    click(app, .init(0, 0), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.count(.picked));
    try testing.expect(Heard.nth(.picked, 0).?.object.eql(over));
    try testing.expect(app.picking.over.contains(under));
}

test "a handler that takes the pointer stops the one under it hearing" {
    const app = try headless();
    defer app.destroy();
    const under = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite{ .layer = 1 }, Area2D{}, Collider2D.box(60, 60) });
    const over = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite{ .layer = 3 }, Area2D{}, Collider2D.box(60, 60) });
    try watch(app, under);
    try watch(app, over);

    Heard.stops = true;
    click(app, .init(0, 0), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.count(.picked));
    try testing.expect(Heard.nth(.picked, 0).?.object.eql(over));
    try testing.expect(app.input.isHandled());

    // Handled is this frame's: the next one is heard again.
    Heard.stops = false;
    Heard.reset();
    click(app, .init(0, 0), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 2), Heard.count(.picked));
}

test "an entity moved under a pointer that has not moved is entered" {
    const app = try headless();
    defer app.destroy();
    const walker = try app.world.spawnWith(.{ Transform2D.at(150, 0), Area2D{}, Collider2D.box(30, 30) });
    try watch(app, walker);

    move(app, .init(0, 0));
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Heard.count(.entered));

    // The pointer stands still, and the thing comes to it.
    app.world.get(walker, Transform2D).?.x = 0;
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.count(.entered));
    try testing.expectEqual(@as(usize, 0), Heard.count(.picked));

    app.world.get(walker, Transform2D).?.x = 150;
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.count(.exited));
}

test "what has died under the pointer says nothing, and is forgotten" {
    const app = try headless();
    defer app.destroy();
    const ghost = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, Collider2D.box(30, 30) });
    try watch(app, ghost);

    move(app, .init(0, 0));
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.count(.entered));

    app.world.despawn(ghost);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Heard.count(.exited));
    try testing.expect(!app.picking.over.contains(ghost));
}

test "a body is picked only when it says so, and a lone collider never is" {
    const app = try headless();
    defer app.destroy();
    const crate = try app.world.spawnWith(.{
        Transform2D.at(0, 0),
        RigidBody2D{ .type = .static },
        Collider2D.box(40, 40),
    });
    const wall = try app.world.spawnWith(.{ Transform2D.at(100, 0), Collider2D.box(40, 40) });
    try watch(app, crate);
    try watch(app, wall);

    click(app, .init(0, 0), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Heard.count(.picked));

    app.world.get(crate, RigidBody2D).?.input_pickable = true;
    click(app, .init(0, 0), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.count(.picked));
    try testing.expect(Heard.nth(.picked, 0).?.object.eql(crate));

    // A collider that is its own static body is not a collision object to
    // pick, whatever is clicked on it.
    click(app, .init(100, 0), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.count(.picked));
}

test "a hidden object, one on no layer, and picking turned off are all passed over" {
    const app = try headless();
    defer app.destroy();
    var quiet = Collider2D.box(40, 40);
    quiet.category = 0;
    const nowhere = try app.world.spawnWith(.{ Transform2D.at(100, 0), Area2D{}, quiet });
    const hidden = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite{ .visible = false }, Area2D{}, Collider2D.box(40, 40) });
    const plain = try app.world.spawnWith(.{ Transform2D.at(-100, 0), Area2D{}, Collider2D.box(40, 40) });
    try watch(app, nowhere);
    try watch(app, hidden);
    try watch(app, plain);

    click(app, .init(100, 0), true);
    click(app, .init(0, 0), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Heard.count(.picked));

    click(app, .init(-100, 0), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.count(.picked));

    // The switch an editor turns off: nothing is picked, and what was
    // hovered is left.
    Heard.reset();
    app.physics_object_picking = false;
    click(app, .init(-100, 0), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Heard.count(.picked));
    try testing.expectEqual(@as(usize, 1), Heard.count(.exited));
}

const Taker = struct {
    fn take(app: *App) anyerror!void {
        app.input.setAsHandled();
    }
};

test "an input system that takes the pointer leaves picking nothing" {
    const app = try headless();
    defer app.destroy();
    const thing = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, Collider2D.box(40, 40) });
    try watch(app, thing);
    try app.addSystem(.input, "take", Taker.take);

    click(app, .init(0, 0), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Heard.count(.picked));
    try testing.expectEqual(@as(usize, 0), Heard.count(.entered));
}

test "a wheel notch is a press and a release of a wheel button, and motion is one event" {
    const app = try headless();
    defer app.destroy();
    const thing = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, Collider2D.box(40, 40) });
    try watch(app, thing);

    move(app, .init(0, 0));
    move(app, .init(4, 0));
    app.input.apply(.{ .scroll = .{ .window = .none, .x = 0, .y = 2, .mods = .{} } });
    _ = try app.step();

    // One motion, then the wheel's press and release.
    try testing.expectEqual(@as(usize, 3), Heard.count(.picked));
    try testing.expect(Heard.nth(.picked, 0).?.what.? == .mouse_motion);
    const press = Heard.nth(.picked, 1).?.what.?;
    try testing.expect(press.isPressed(.wheel_up));
    try testing.expectEqual(@as(f32, 2), press.mouse_button.factor);
    try testing.expect(press.buttonMask().has(.wheel_up));
    const release = Heard.nth(.picked, 2).?.what.?;
    try testing.expect(release.isReleased(.wheel_up));
    try testing.expect(!release.buttonMask().has(.wheel_up));
}

test "a click beside a turned shape, near it but not in it, hits nothing" {
    const app = try headless();
    defer app.destroy();
    // A square turned an eighth of a turn: a diamond, whose corner region
    // the pointer can be in without being in the shape.
    var diamond = Collider2D.box(40, 40);
    diamond.rotation = std.math.pi / 4.0;
    const gem = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, diamond });
    try watch(app, gem);

    click(app, .init(19, 19), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Heard.count(.picked));
    try testing.expectEqual(@as(usize, 0), Heard.count(.entered));

    click(app, .init(0, 19), true);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.count(.picked));
}
