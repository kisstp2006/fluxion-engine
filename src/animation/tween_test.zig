// SPDX-License-Identifier: BSD-3-Clause

//! Tweens through a whole app, headless.

const std = @import("std");
const testing = std.testing;

const tween = @import("tween.zig");
const App = @import("../App.zig");
const Tween = tween.Tween;

const components = @import("../scene/components.zig");

/// A quarter of a second a frame.
const quarterSecondApp = @import("../test_helpers.zig").quarterSecondApp;

const Heard = struct {
    var finished: usize = 0;

    fn done(_: *App, _: struct {}) !void {
        finished += 1;
    }
};

test "a tween moves its steps one after another, says finished, and goes" {
    const app = try quarterSecondApp();
    defer app.destroy();
    Heard.finished = 0;
    const box = try app.world.spawnWith(.{components.Transform2D.at(0, 0)});
    const moving = try app.tween(.none);
    try app.tweenProperty(moving, box, "Transform2D.x", .{ .number = 100 }, 1);
    try app.tweenInterval(moving, 0.5);
    try app.tweenProperty(moving, box, "Transform2D.y", .{ .number = -40 }, 0.5);
    try app.signal(moving, Tween, .finished).connectFn(Heard.done, .{});

    _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 25), app.world.get(box, components.Transform2D).?.x, 0.001);
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(f32, 100), app.world.get(box, components.Transform2D).?.x);
    try testing.expectEqual(@as(f32, 0), app.world.get(box, components.Transform2D).?.y);
    // Waited, then the second half of the way.
    for (0..3) |_| _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, -20), app.world.get(box, components.Transform2D).?.y, 0.001);
    _ = try app.step();
    try testing.expectEqual(@as(f32, -40), app.world.get(box, components.Transform2D).?.y);
    try testing.expectEqual(@as(usize, 1), Heard.finished);
    _ = try app.step();
    try testing.expect(!app.world.isAlive(moving));
}

test "steps started together, along a curve, from where each was when it started" {
    const app = try quarterSecondApp();
    defer app.destroy();
    const panel = try app.world.spawnWith(.{ components.Transform2D.at(-200, 10), @import("../scene/inherited.zig").Appearance{} });
    const slide = try app.tween(panel);
    try app.tweenParallel(slide, true);
    try app.tweenEase(slide, .quad_out);
    try app.tweenProperty(slide, panel, "Appearance.modulate.a", .{ .number = 0 }, 0.5);
    try app.tweenProperty(slide, panel, "Transform2D.x,y", .{ .vec2 = .{ 0, 0 } }, 1);
    try testing.expectError(error.NotATween, app.tweenEase(panel, .quad_in));

    _ = try app.step();
    // A quarter of the way along quad_out is seven sixteenths of the move.
    const halfway = app.world.get(panel, @import("../scene/inherited.zig").Appearance).?.modulate.a;
    try testing.expectApproxEqAbs(@as(f32, 0.25), halfway, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -200 + 200 * 0.4375), app.world.get(panel, components.Transform2D).?.x, 0.01);
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(f32, 0), app.world.get(panel, @import("../scene/inherited.zig").Appearance).?.modulate.a);
    try testing.expectEqual(@as(f32, 0), app.world.get(panel, components.Transform2D).?.x);

    // One that hangs from its entity goes with it.
    const again = try app.tween(panel);
    try app.tweenProperty(again, panel, "Transform2D.x", .{ .number = 50 }, 1);
    app.world.despawn(panel);
    for (0..2) |_| _ = try app.step();
    try testing.expect(!app.world.isAlive(again));
}

test "a tween loops, waits while its entity is paused, and a wrong property says so" {
    const app = try quarterSecondApp();
    defer app.destroy();
    const box = try app.world.spawnWith(.{components.Transform2D.at(0, 0)});
    const beat = try app.tween(.none);
    app.world.get(beat, Tween).?.loops = 0;
    try app.tweenProperty(beat, box, "Transform2D.rotation", .{ .number = 1 }, 0.5);
    try testing.expectError(error.NoSuchField, app.tweenProperty(beat, box, "Transform2D.spin", .{ .number = 1 }, 1));
    try testing.expectError(error.NoSuchComponent, app.tweenProperty(beat, box, "Wobble.x", .{ .number = 1 }, 1));

    _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.world.get(box, components.Transform2D).?.rotation, 0.001);
    for (0..3) |_| _ = try app.step();
    // Round again from where the step found it: already at the end.
    try testing.expectEqual(@as(u32, 2), app.world.get(beat, Tween).?.passes);
    app.setPaused(true);
    const held = app.world.get(beat, Tween).?.elapsed;
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(held, app.world.get(beat, Tween).?.elapsed);
    try testing.expect(app.world.isAlive(beat));
}
