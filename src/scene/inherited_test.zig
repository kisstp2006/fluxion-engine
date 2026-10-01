// SPDX-License-Identifier: BSD-3-Clause

//! Pause and appearance as they pass down the tree, through a whole app, headless.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const Color = @import("../math/color.zig").Color;
const components = @import("components.zig");
const Appearance = @import("inherited.zig").Appearance;
const Processing = @import("inherited.zig").Processing;
const AnimatedSprite2D = @import("../animation/sprite_frames.zig").AnimatedSprite2D;
const helpers = @import("../test_helpers.zig");
const Paused = helpers.Paused;

test "a paused game runs only the systems that asked to, and moves no body" {
    Paused.reset();
    const app = try App.create(testing.allocator, .{ .headless = true, .fixed_delta = 0.25 });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.25 };
    try app.addSystem(.update, "game", Paused.countGame);
    try app.addSystemWhenPaused(.update, "menu", Paused.countMenu);
    try app.addSystemAlways(.input, "key", Paused.countKey);
    const ball = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.RigidBody2D{}, components.Collider2D.circle(4) });

    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(u32, 3), Paused.game);
    try testing.expectEqual(@as(u32, 0), Paused.menu);
    try testing.expectEqual(@as(u32, 3), Paused.key);
    const fallen = app.world.get(ball, components.Transform2D).?.y;
    try testing.expect(fallen > 0);

    app.setPaused(true);
    for (0..2) |_| _ = try app.step();
    try testing.expectEqual(@as(u32, 3), Paused.game);
    try testing.expectEqual(@as(u32, 2), Paused.menu);
    try testing.expectEqual(@as(u32, 5), Paused.key);
    try testing.expectEqual(fallen, app.world.get(ball, components.Transform2D).?.y);
    // Time goes on: it is not a clock stopped at nought.
    try testing.expect(app.time.delta > 0);

    app.setPaused(false);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 4), Paused.game);
    try testing.expect(app.world.get(ball, components.Transform2D).?.y > fallen);
}

test "an animation waits while its entity does not run" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.25 };
    const frames = try app.addGridFrames("strip", .none, 4, 1, &.{.{ .name = "walk", .cells = &.{ 0, 1, 2, 3 }, .speed = 4 }});
    const strip: AnimatedSprite2D = .autoplaying(frames, "walk");
    const walker = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.Sprite.solid(.white, 4, 4), strip });
    const menu = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.Sprite.solid(.white, 4, 4), strip, Processing{ .mode = .always } });

    app.setPaused(true);
    for (0..2) |_| _ = try app.step();
    try testing.expectEqual(@as(f32, 0), app.world.get(walker, AnimatedSprite2D).?.frame_progress);
    try testing.expectEqual(@as(i32, 0), app.world.get(walker, AnimatedSprite2D).?.frame);
    try testing.expectEqual(@as(i32, 1), app.world.get(menu, AnimatedSprite2D).?.frame);
}

test "an Appearance hides, fades and raises what hangs from it" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const faded = try app.world.spawnWith(.{
        components.Transform2D.at(0, 0),
        components.Sprite.solid(.white, 10, 10),
        Appearance{ .modulate = Color.white.withAlpha(0.5), .z = 3 },
    });
    _ = try app.world.spawnWith(.{ components.Transform2D.at(2, 0), components.Parent.of(faded), components.Sprite.solid(.white, 4, 4) });
    const hidden = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), Appearance{ .visible = false } });
    _ = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.Parent.of(hidden), components.Sprite.solid(.white, 4, 4) });
    const plain = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.Sprite.solid(.white, 4, 4) });
    _ = try app.step();

    try testing.expectEqual(@as(u32, 3), app.sprites.drawn);
    var halves: usize = 0;
    for (app.sprites.items.items) |item| {
        if (item.instance.tint[3] == 0.5) halves += 1;
    }
    try testing.expectEqual(@as(usize, 2), halves);
    try testing.expectEqual(@as(i16, 3), app.resolvedAppearance(app.childAt(faded, 0).?).layer(0));
    try testing.expectEqual(@as(i16, 0), app.resolvedAppearance(plain).layer(0));
}
