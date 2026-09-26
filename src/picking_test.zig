// SPDX-License-Identifier: BSD-3-Clause

//! Picking through a whole app: what the pointer is over, what hears a
//! click, in which order, and who can stop it - and what the pointer
//! itself says of where it is and how fast it is moving.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const platform = @import("fluxion_platform");

const App = @import("App.zig");
const components = @import("components.zig");
const InputEvent = @import("input_event.zig").InputEvent;

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
        what: ?InputEvent = null,
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

    fn picked(app: *App, self: Entity, event: InputEvent, shape: Entity) !void {
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
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 400, .height = 200, .frame_time = 1.0 / 60.0, .physics_2d = @import("bodies.zig").earth });
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
    const button = try app.world.spawnWith(.{ Transform2D.at(50, 20), Area2D{}, Collider2D.rectangle(20, 20) });
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
    try testing.expect(first.what.?.buttons().has(.left));
    // The event's place is the window's pixels, and the world's through it.
    const in_world = app.screenToWorld(first.what.?.position().?.x, first.what.?.position().?.y);
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
    const target = try app.world.spawnWith(.{ Transform2D.at(140, -30), Area2D{}, Collider2D.rectangle(10, 10) });
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
    const under = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite{ .layer = 1 }, Area2D{}, Collider2D.rectangle(30, 30) });
    const over = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite{ .layer = 3 }, Area2D{}, Collider2D.rectangle(30, 30) });
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
    const under = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite{ .layer = 1 }, Area2D{}, Collider2D.rectangle(30, 30) });
    const over = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite{ .layer = 3 }, Area2D{}, Collider2D.rectangle(30, 30) });
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
    const walker = try app.world.spawnWith(.{ Transform2D.at(150, 0), Area2D{}, Collider2D.rectangle(15, 15) });
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
    const ghost = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, Collider2D.rectangle(15, 15) });
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
        Collider2D.rectangle(20, 20),
    });
    const wall = try app.world.spawnWith(.{ Transform2D.at(100, 0), Collider2D.rectangle(20, 20) });
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
    var quiet = Collider2D.rectangle(20, 20);
    quiet.collision_layer = 0;
    const nowhere = try app.world.spawnWith(.{ Transform2D.at(100, 0), Area2D{}, quiet });
    const hidden = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite{ .visible = false }, Area2D{}, Collider2D.rectangle(20, 20) });
    const plain = try app.world.spawnWith(.{ Transform2D.at(-100, 0), Area2D{}, Collider2D.rectangle(20, 20) });
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
    const thing = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, Collider2D.rectangle(20, 20) });
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
    const thing = try app.world.spawnWith(.{ Transform2D.at(0, 0), Area2D{}, Collider2D.rectangle(20, 20) });
    try watch(app, thing);

    move(app, .init(0, 0));
    move(app, .init(4, 0));
    app.input.apply(.{ .scroll = .{ .window = .none, .x = 0, .y = 2, .mods = .{} } });
    _ = try app.step();

    // One motion, then the wheel's turn.
    try testing.expectEqual(@as(usize, 2), Heard.count(.picked));
    try testing.expect(Heard.nth(.picked, 0).?.what.? == .mouse_motion);
    const turned = Heard.nth(.picked, 1).?.what.?;
    try testing.expect(turned == .wheel);
    try testing.expectEqual(@as(f32, 2), turned.wheel.delta.y);
    try testing.expect(!turned.buttons().any());
}

test "a click beside a turned shape, near it but not in it, hits nothing" {
    const app = try headless();
    defer app.destroy();
    // A square turned an eighth of a turn: a diamond, whose corner region
    // the pointer can be in without being in the shape.
    var diamond = Collider2D.rectangle(20, 20);
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

/// Input given from inside an `.input` system, which is where the pump puts
/// it: an edge given between frames is gone by the time the systems run.
const Feed = struct {
    var moving: f32 = 0;
    var press = false;
    var double = false;

    fn run(app: *App) anyerror!void {
        if (moving != 0) app.input.apply(.{ .cursor = .{
            .window = .none,
            .x = 0,
            .y = 0,
            .dx = moving,
            .dy = 0,
        } });
        if (press) {
            app.input.apply(.{ .mouse_button = .{
                .window = .none,
                .button = .left,
                .action = .press,
                .mods = .{},
                .x = 10,
                .y = 10,
                .double_click = double,
            } });
            press = false;
        }
    }
};

test "the pointer says how fast it is moving, and forgets once it stands still" {
    const app = try headless();
    defer app.destroy();
    Feed.moving = 10;
    Feed.press = false;
    try app.addSystem(.input, "feed", Feed.run);

    // Ten pixels a frame at sixty frames a second, for more than the tenth
    // of a second the velocity is worked out over.
    for (0..8) |_| _ = try app.step();
    try testing.expect(app.input.pointer.velocity.x > 400);
    try testing.expectEqual(@as(f32, 0), app.input.pointer.velocity.y);

    // Still for three seconds: nothing is moving any more.
    Feed.moving = 0;
    for (0..200) |_| _ = try app.step();
    try testing.expectEqual(@as(f32, 0), app.input.pointer.velocity.x);
}

test "a double click is the one the system counted" {
    const app = try headless();
    defer app.destroy();
    Feed.moving = 0;
    Feed.press = true;
    Feed.double = false;
    try app.addSystem(.input, "feed", Feed.run);

    _ = try app.step();
    try testing.expect(app.input.buttonJustPressed(.left));
    try testing.expect(!app.input.doubleClicked(.left));

    Feed.press = true;
    Feed.double = true;
    _ = try app.step();
    try testing.expect(app.input.doubleClicked(.left));
    try testing.expect(app.input.pointerEvents()[0].mouse_button.double_click);

    // This frame's, as every edge is.
    Feed.double = false;
    _ = try app.step();
    try testing.expect(!app.input.doubleClicked(.left));
}

test "the pointer is put where a warp says, and read in an entity's own space" {
    const app = try headless();
    defer app.destroy();
    const dial = try app.world.spawnWith(.{Transform2D{
        .x = 40,
        .y = 10,
        .rotation = std.math.pi / 2.0,
        .scale_x = 2,
        .scale_y = 2,
    }});

    // Without a window there is no system to move, and the pointer is still
    // where the game put it, for the game and for a test.
    const middle = app.worldToScreen(40, 10);
    app.warpPointer(middle.x, middle.y);
    try testing.expectEqual(middle.x, app.input.pointer.x);

    const at_middle = app.pointerIn(dial).?;
    try testing.expectApproxEqAbs(@as(f32, 0), at_middle.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), at_middle.y, 0.001);

    // A quarter turn takes the dial's +x to the world's +y, and the scale
    // halves what a step in the world is worth in its own space.
    const along = app.toLocal(dial, .init(40, 30)).?;
    try testing.expectApproxEqAbs(@as(f32, 10), along.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), along.y, 0.001);
    try testing.expect(app.pointerIn(.none) == null);
}

test "an event handed to an entity is the same event in its own space" {
    const app = try headless();
    defer app.destroy();
    const knob = try app.world.spawnWith(.{Transform2D.at(60, 0)});
    const on_screen = app.worldToScreen(70, 0);
    const event: InputEvent = .{ .mouse_button = .{
        .button = .left,
        .pressed = true,
        .position = .init(on_screen.x, on_screen.y),
    } };

    const local = app.localEvent(knob, event);
    try testing.expect(local.isPressed(.left));
    try testing.expectApproxEqAbs(@as(f32, 10), local.position().?.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), local.position().?.y, 0.001);

    // An entity that is not there leaves the event as it was.
    const same = app.localEvent(.none, event);
    try testing.expectEqual(event.position().?.x, same.position().?.x);
}

test "the interface keeps inside the safe area, or inside whatever the game says" {
    const app = try headless();
    defer app.destroy();
    _ = try app.step();
    // No window, so no notch: the whole of it is the interface's.
    try testing.expect(app.safeArea().isEmpty());
    try testing.expect(std.meta.eql(app.interface.safe_area, .{}));

    // A game that draws into the notch itself says so, and keeps its own.
    app.interface.follow_safe_area = false;
    app.interface.safe_area = .{ .top = 40 };
    _ = try app.step();
    try testing.expectEqual(@as(u16, 40), app.interface.safe_area.top);
    try testing.expectEqual(@as(f32, 40), app.interface.surface(200, 100).safe_area.top);

    app.interface.follow_safe_area = true;
    _ = try app.step();
    try testing.expectEqual(@as(u16, 0), app.interface.safe_area.top);
}
