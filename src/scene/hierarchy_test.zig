// SPDX-License-Identifier: BSD-3-Clause

//! The tree through a whole app, headless: where children are, moving them in the
//! world, what goes with a parent, and the order of children.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const components = @import("components.zig");
const control = @import("../ui/control.zig");
const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const scene = @import("scene.zig");
const timer = @import("../time/timer.zig");
const helpers = @import("../test_helpers.zig");
const Tally = helpers.Tally;

test "a child is where its parent put it, and its own numbers stay local" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    const tank = try app.world.spawnWith(.{
        components.Transform2D.at(100, 50),
        components.Sprite.solid(.white, 20, 20),
    });
    const turret = try app.world.spawnWith(.{
        components.Transform2D.at(0, -12),     components.Parent.of(tank),
        components.Sprite.solid(.white, 8, 8),
    });

    try app.run();

    const placed = app.worldTransform(turret).?;
    try testing.expectApproxEqAbs(@as(f32, 100), placed.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 38), placed.y, 0.0001);

    // The component still holds its own local numbers.
    const local = app.world.get(turret, components.Transform2D).?;
    try testing.expectEqual(@as(f32, 0), local.x);
    try testing.expectEqual(@as(f32, -12), local.y);
}

test "a grandchild is composed through the whole chain" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    const root = try app.world.spawnWith(.{components.Transform2D.at(10, 0)});
    const middle = try app.world.spawnWith(.{ components.Transform2D.at(5, 0), components.Parent.of(root) });
    const leaf = try app.world.spawnWith(.{ components.Transform2D.at(2, 0), components.Parent.of(middle) });

    try app.run();
    try testing.expectApproxEqAbs(@as(f32, 17), app.worldTransform(leaf).?.x, 0.0001);
}

test "an entity put somewhere in the world lands there under its parents, and keeps them" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    // A parent turned a quarter, twice the size.
    const tank = try app.world.spawnWith(.{components.Transform2D{ .x = 100, .y = 50, .rotation = std.math.pi / 2.0, .scale_x = 2, .scale_y = 2 }});
    const turret = try app.world.spawnWith(.{ components.Transform2D.at(10, 0), components.Parent.of(tank) });

    // Ten along the tank's +x, which the quarter turn points down the
    // screen, at twice the length.
    const at = app.globalPosition(turret).?;
    try testing.expectApproxEqAbs(@as(f32, 100), at.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 70), at.y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), app.globalRotation(turret).?, 1e-5);
    try testing.expectEqual(@as(f32, 2), app.globalScale(turret).?.x);

    try app.setGlobalPosition(turret, .init(0, 0));
    try app.setGlobalRotation(turret, 0);
    try app.setGlobalScale(turret, .init(1, 3));
    const placed = app.worldTransform(turret).?;
    try testing.expectApproxEqAbs(@as(f32, 0), placed.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), placed.y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), placed.rotation, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 3), placed.scale_y, 1e-5);
    // Its own numbers are still the tank's space.
    const own = app.world.get(turret, components.Transform2D).?;
    try testing.expect(app.parentOf(turret).eql(tank));
    try testing.expectApproxEqAbs(@as(f32, -std.math.pi / 2.0), own.rotation, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), own.scale_x, 1e-5);

    // By an amount in the world, whichever way the tank's axes point.
    try app.globalTranslate(turret, .init(5, -3));
    try testing.expectApproxEqAbs(@as(f32, 5), app.globalPosition(turret).?.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -3), app.globalPosition(turret).?.y, 1e-3);

    // And the whole of it at once.
    try app.setWorldTransform(turret, .{ .x = -7, .y = 9, .rotation = 1, .scale_x = 4, .scale_y = 4 });
    const again = app.worldTransform(turret).?;
    try testing.expectApproxEqAbs(@as(f32, -7), again.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 9), again.y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1), again.rotation, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 4), again.scale_x, 1e-5);
}

test "what does not inherit its parent's turn or scale is put in the world by its own numbers" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const post = try app.world.spawnWith(.{components.Transform2D{ .x = 10, .rotation = 1, .scale_x = 4, .scale_y = 4 }});
    const plate = try app.world.spawnWith(.{ components.Transform2D{ .inherit_rotation = false, .inherit_scale = false }, components.Parent.of(post) });
    try app.setGlobalRotation(plate, 0.25);
    try app.setGlobalScale(plate, .init(2, 2));
    const own = app.world.get(plate, components.Transform2D).?;
    try testing.expectApproxEqAbs(@as(f32, 0.25), own.rotation, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 2), own.scale_x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.25), app.globalRotation(plate).?, 1e-5);
}

test "a point goes into an entity's space and back, and an entity turns to face one" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const arm = try app.world.spawnWith(.{components.Transform2D{ .x = 30, .y = -20, .rotation = 0.5, .scale_x = 2, .scale_y = 0.5 }});
    const hand = try app.world.spawnWith(.{ components.Transform2D{ .x = 4, .y = 6, .rotation = -0.25 }, components.Parent.of(arm) });
    const point: math.Vec2 = .init(-12, 40);
    const back = app.toGlobal(hand, app.toLocal(hand, point).?).?;
    try testing.expectApproxEqAbs(point.x, back.x, 1e-3);
    try testing.expectApproxEqAbs(point.y, back.y, 1e-3);

    // A parent as big one way as the other, so facing is exact.
    const body = try app.world.spawnWith(.{components.Transform2D{ .x = 5, .y = 5, .rotation = 2, .scale_x = 3, .scale_y = 3 }});
    // Its own scale not the same both ways: facing still is, in its own
    // space.
    const eye = try app.world.spawnWith(.{ components.Transform2D{ .x = 1, .y = -2, .rotation = 0.7, .scale_x = 2, .scale_y = 0.5 }, components.Parent.of(body) });
    try app.lookAt(eye, point);
    try testing.expectApproxEqAbs(@as(f32, 0), app.getAngleTo(eye, point).?, 1e-4);
    const from = app.globalPosition(eye).?;
    const ahead = app.toGlobal(eye, .init(1, 0)).?;
    const facing = ahead.sub(from).norm();
    const wanted = point.sub(from).norm();
    try testing.expectApproxEqAbs(@as(f32, 1), facing.dot(wanted), 1e-4);
}

test "an entity moves along its own axes, turns and grows by its own numbers" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    // A quarter turn: its +x points down the screen and its +y to the left.
    const ship = try app.world.spawnWith(.{components.Transform2D{ .x = 1, .y = 2, .rotation = std.math.pi / 2.0, .scale_x = 2, .scale_y = 3 }});
    const own = app.world.get(ship, components.Transform2D).?;
    try app.moveLocalX(ship, 5, false);
    try testing.expectApproxEqAbs(@as(f32, 7), own.y, 1e-4);
    try app.moveLocalX(ship, 5, true);
    try testing.expectApproxEqAbs(@as(f32, 17), own.y, 1e-4);
    try app.moveLocalY(ship, 1, true);
    try testing.expectApproxEqAbs(@as(f32, -2), own.x, 1e-4);
    try app.moveLocalY(ship, 1, false);
    try testing.expectApproxEqAbs(@as(f32, -3), own.x, 1e-4);

    try app.rotate(ship, 0.5);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0 + 0.5), own.rotation, 1e-5);
    try app.applyScale(ship, .init(0.5, 2));
    try testing.expectEqual(@as(f32, 1), own.scale_x);
    try testing.expectEqual(@as(f32, 6), own.scale_y);
}

test "where an entity is in the space of something above it" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const root = try app.world.spawnWith(.{components.Transform2D.at(100, 0)});
    const middle = try app.world.spawnWith(.{ components.Transform2D{ .x = 10, .rotation = std.math.pi / 2.0 }, components.Parent.of(root) });
    const leaf = try app.world.spawnWith(.{ components.Transform2D.at(5, 0), components.Parent.of(middle) });

    const within = app.getRelativeTransformToParent(leaf, root).?;
    try testing.expectApproxEqAbs(@as(f32, 10), within.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5), within.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), within.rotation, 1e-5);
    try testing.expectEqual(@as(f32, 0), app.getRelativeTransformToParent(leaf, leaf).?.x);
    try testing.expect(app.getRelativeTransformToParent(root, leaf) == null);
}

test "writing where an entity is says why it cannot: no transform, or a parent that is gone" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const bare = try app.world.spawnWith(.{components.Camera2D{}});
    try testing.expectError(error.NoTransform, app.setGlobalPosition(bare, .init(1, 1)));
    try testing.expectError(error.NoTransform, app.rotate(bare, 1));
    try testing.expectError(error.NoTransform, app.lookAt(bare, .init(1, 1)));
    try testing.expect(app.globalPosition(bare) == null);

    const parent = try app.world.spawnWith(.{components.Transform2D.at(0, 0)});
    const orphan = try app.world.spawnWith(.{ components.Transform2D.at(1, 1), components.Parent.of(parent) });
    app.world.despawn(parent);
    try testing.expectError(error.Unplaced, app.setGlobalPosition(orphan, .init(0, 0)));
    try testing.expectError(error.Unplaced, app.lookAt(orphan, .init(5, 5)));

    // A living parent with no transform of its own places nothing.
    const holder = try app.world.spawnWith(.{components.Camera2D{}});
    const held = try app.world.spawnWith(.{ components.Transform2D.at(3, 4), components.Parent.of(holder) });
    try app.setGlobalPosition(held, .init(7, 8));
    try testing.expectEqual(@as(f32, 7), app.world.get(held, components.Transform2D).?.x);
    try testing.expectEqual(@as(f32, 8), app.world.get(held, components.Transform2D).?.y);
}

test "what hangs from something that died goes with it" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    const tank = try app.world.spawnWith(.{
        components.Transform2D.at(100, 50),
        components.Sprite.solid(.white, 20, 20),
    });
    const turret = try app.world.spawnWith(.{
        components.Transform2D.at(0, -12),     components.Parent.of(tank),
        components.Sprite.solid(.white, 8, 8),
    });
    const barrel = try app.world.spawnWith(.{
        components.Transform2D.at(10, 0),       components.Parent.of(turret),
        components.Sprite.solid(.white, 12, 2),
    });
    const bystander = try app.world.spawnWith(.{
        components.Transform2D.at(20, 20),
        components.Sprite.solid(.white, 4, 4),
    });

    app.world.despawn(tank);
    // Until the end of the frame, the chain is broken and says so.
    try testing.expect(app.worldTransform(turret) == null);

    try app.run();

    // The turret went because the tank did, and the barrel one pass later.
    try testing.expect(!app.world.isAlive(turret));
    try testing.expect(!app.world.isAlive(barrel));
    try testing.expect(app.world.isAlive(bystander));

    // And only the bystander was drawn.
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
}

test "a parent with no transform places nothing and still owns what hangs from it" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    // An entity with no components at all.
    const spell = try app.world.spawn();
    const spark = try app.world.spawnWith(.{
        components.Transform2D.at(40, 30),     components.Parent.of(spell),
        components.Sprite.solid(.white, 4, 4),
    });

    try app.run();

    // Its numbers are the world's, as if it had no parent...
    const placed = app.worldTransform(spark).?;
    try testing.expectEqual(@as(f32, 40), placed.x);
    try testing.expectEqual(@as(f32, 30), placed.y);
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);

    // ... and it still goes when its parent does.
    app.world.despawn(spell);
    app.running = true;
    app.frames_left = 1;
    _ = try app.step();
    try testing.expect(!app.world.isAlive(spark));
}

test "single finds the one entity with a component, or none" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    // Never seen, so nothing - and asking registered nothing.
    try testing.expect(app.single(Tally) == null);
    const before = app.world.componentCount();
    try testing.expect(app.single(Tally) == null);
    try testing.expectEqual(before, app.world.componentCount());

    // Beside other components, in an archetype of its own.
    _ = try app.world.spawnWith(.{ components.Transform2D{}, Tally{ .points = 4 } });
    app.single(Tally).?.points += 1;
    try testing.expectEqual(@as(u32, 5), app.single(Tally).?.points);
}

test "anything hangs in the one tree, and goes with what it hangs from" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    const panel = try app.world.spawnWith(.{control.Control{}});
    const button = try app.world.spawnWith(.{ control.Control{}, components.Parent.of(panel), control.Button{} });
    try app.setText(button, control.Button, "text", "OK");
    const clock = try app.world.spawnWith(.{ timer.Timer{}, components.Parent.of(button) });
    try testing.expect(app.hangsFrom(clock, panel));
    try testing.expect(!app.hangsFrom(panel, clock));

    // A loop is refused, and changes nothing.
    try testing.expectError(error.Loop, app.setParent(panel, clock, false));
    try testing.expectError(error.Loop, app.setParent(panel, panel, false));
    try testing.expect(app.parentOf(panel).isNone());

    app.world.despawn(panel);
    _ = try app.step();
    try testing.expect(!app.world.isAlive(button));
    try testing.expect(!app.world.isAlive(clock));
}

test "an entity hung elsewhere stays where it is in the world, or keeps its own numbers" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    const ship = try app.world.spawnWith(.{components.Transform2D.at(10, 10)});
    const rock = try app.world.spawnWith(.{components.Transform2D.at(15, 10)});

    try app.setParent(rock, ship, true);
    try testing.expectEqual(@as(f32, 5), app.world.get(rock, components.Transform2D).?.x);
    try testing.expectEqual(@as(f32, 15), app.worldTransform(rock).?.x);

    try app.setParent(rock, .none, true);
    try testing.expectEqual(@as(f32, 15), app.world.get(rock, components.Transform2D).?.x);
    try testing.expect(!app.world.has(rock, components.Parent));

    try app.setParent(rock, ship, false);
    try testing.expectEqual(@as(f32, 15), app.world.get(rock, components.Transform2D).?.x);
    try testing.expectEqual(@as(f32, 25), app.worldTransform(rock).?.x);

    const gone = try app.world.spawn();
    app.world.despawn(gone);
    try testing.expectError(error.NoSuchEntity, app.setParent(rock, gone, false));
}

test "a parent's children keep the order they are put in, and a new one comes last" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const parent = try app.world.spawnWith(.{components.Transform2D.at(0, 0)});
    const a = try app.world.spawnWith(.{ components.Transform2D.at(1, 0), components.Parent.of(parent) });
    const b = try app.world.spawnWith(.{ components.Transform2D.at(2, 0), components.Parent.of(parent) });
    const c = try app.world.spawnWith(.{ components.Transform2D.at(3, 0), components.Parent.of(parent) });
    var found: [8]ecs.Entity = undefined;

    // Never placed: the order the handles were given out in.
    try testing.expectEqualSlices(ecs.Entity, &.{ a, b, c }, app.childrenOf(parent, &found));
    try testing.expectEqual(@as(?u32, 2), app.siblingIndex(c));

    try app.setSiblingIndex(c, 0);
    try testing.expectEqualSlices(ecs.Entity, &.{ c, a, b }, app.childrenOf(parent, &found));
    try testing.expectEqual(@as(?u32, 0), app.siblingIndex(c));
    try testing.expectEqual(@as(?u32, 2), app.siblingIndex(b));

    // Past the end is the end.
    try app.setSiblingIndex(a, 99);
    try testing.expectEqualSlices(ecs.Entity, &.{ c, b, a }, app.childrenOf(parent, &found));

    // A child made afterwards comes after the ones placed.
    const d = try app.world.spawnWith(.{ components.Transform2D.at(4, 0), components.Parent.of(parent) });
    try testing.expectEqualSlices(ecs.Entity, &.{ c, b, a, d }, app.childrenOf(parent, &found));

    // The roots are a family of their own, untouched.
    try testing.expectEqualSlices(ecs.Entity, &.{parent}, app.childrenOf(.none, &found));

    // Fewer places than children: the first ones, still in order.
    var two: [2]ecs.Entity = undefined;
    try testing.expectEqualSlices(ecs.Entity, &.{ c, b }, app.childrenOf(parent, &two));

    // The dead give their places back.
    app.world.despawn(b);
    _ = try app.step();
    try testing.expect(!app.sibling_ranks.contains(b));
    try testing.expect(app.siblingIndex(b) == null);
    try testing.expectError(error.NoSuchEntity, app.setSiblingIndex(b, 0));
    try testing.expectEqualSlices(ecs.Entity, &.{ c, a, d }, app.childrenOf(parent, &found));
}

test "the order of a parent's children goes through a scene and back" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const parent = try app.world.spawnWith(.{components.Transform2D.at(0, 0)});
    const first = try app.world.spawnWith(.{ components.Transform2D.at(1, 0), components.Parent.of(parent) });
    const second = try app.world.spawnWith(.{ components.Transform2D.at(2, 0), components.Parent.of(parent) });
    const third = try app.world.spawnWith(.{ components.Transform2D.at(3, 0), components.Parent.of(parent) });
    try app.setName(first, "first");
    try app.setName(second, "second");
    try app.setName(third, "third");
    try app.setSiblingIndex(third, 0);
    try app.setSiblingIndex(first, 2);

    const bytes = try scene.write(app, testing.allocator, .{});
    defer testing.allocator.free(bytes);

    const copy = try App.create(testing.allocator, .{ .headless = true });
    defer copy.destroy();
    // Handles given back out of order, so the scene's entities are not
    // made in the order of their handles and only the list can say it.
    var scratch: [4]ecs.Entity = undefined;
    for (&scratch) |*made| made.* = try copy.world.spawnWith(.{components.Transform2D{}});
    for (scratch) |made| copy.world.despawn(made);
    // Something already there, which keeps its place before the scene's.
    const before = try copy.world.spawnWith(.{components.Transform2D.at(9, 9)});
    _ = try scene.read(copy, bytes, .{});

    var found: [8]ecs.Entity = undefined;
    const copied_parent = copy.findUuid(app.uuidOf(parent).?).?;
    const family = copy.childrenOf(copied_parent, &found);
    try testing.expectEqual(@as(usize, 3), family.len);
    try testing.expectEqualStrings("third", copy.nameOf(family[0]).?);
    try testing.expectEqualStrings("second", copy.nameOf(family[1]).?);
    try testing.expectEqualStrings("first", copy.nameOf(family[2]).?);
    const roots = copy.childrenOf(.none, &found);
    try testing.expect(roots[0].eql(before));

    // Written again without `before`, it is the same scene.
    copy.world.despawn(before);
    const again = try scene.write(copy, testing.allocator, .{});
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(bytes, again);
}
