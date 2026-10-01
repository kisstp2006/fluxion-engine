// SPDX-License-Identifier: BSD-3-Clause

//! Frame time and fixed steps through a whole app, headless.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const ecs = @import("fluxion_ecs");

test "a fixed step runs as many times as the frame is worth" {
    const counter = struct {
        var steps: u32 = 0;
        fn count(_: *App) anyerror!void {
            steps += 1;
        }
    };
    counter.steps = 0;

    // Frames of a fiftieth of a second, steps of a hundredth: two a frame.
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 10,
        .fixed_delta = 0.01,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.02 };

    try app.addSystem(.fixed, "count", counter.count);
    try app.run();

    try testing.expectEqual(@as(u32, 20), counter.steps);
}

fn spawnInterpolated(app: *App) anyerror!void {
    var moving: components.Transform2D = .at(0, 0);
    moving.interpolate = true;
    _ = try app.world.spawnWith(.{
        moving,
        components.Sprite.solid(.hex(0xFF0000), 8, 8),
    });
}

fn slideRight(app: *App) anyerror!void {
    var it = try ecs.Query(.{components.Transform2D}).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(components.Transform2D)) |*t| t.x += 10;
    }
}

test "a previous transform is taken before each fixed step" {
    // A frame is worth one and a half steps: one runs, and half a step is
    // left to blend by.
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 1,
        .fixed_delta = 0.01,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.015 };

    try app.addSystem(.startup, "spawn interpolated", spawnInterpolated);
    try app.addSystem(.fixed, "slide right", slideRight);
    try app.run();

    var it = try ecs.Query(.{components.Transform2D}).over(&app.world);
    const chunk = it.next().?;
    const entity = chunk.entities[0];
    const current = chunk.slice(components.Transform2D)[0];

    // Where it is, where it was, and halfway between: what is drawn. The
    // game's sums see where it is.
    try testing.expectEqual(@as(f32, 10), current.x);
    try testing.expectEqual(@as(f32, 0), app.snapshots.get(entity).?.x);
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.time.alpha(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), app.drawnTransform(entity).?.x, 0.01);
    try testing.expectEqual(@as(f32, 10), app.worldTransform(entity).?.x);
    // Its sprite's corners are where it is drawn: eight wide, round x = 5.
    const corners = app.spriteCorners(entity).?;
    try testing.expectApproxEqAbs(@as(f32, 1), corners[0].x, 0.01);
}

test "a transform that never asked is not remembered at all" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 2,
        .fixed_delta = 0.01,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.05 };

    _ = try app.world.spawnWith(.{components.Transform2D.at(0, 0)});
    try app.run();

    try testing.expectEqual(@as(usize, 0), app.snapshots.count());
}

test "a fixed frame time wins over the clock" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 3,
        .io = testing.io,
        .frame_time = 0.25,
    });
    defer app.destroy();

    try app.run();
    try testing.expectApproxEqAbs(@as(f64, 0.75), app.time.elapsed, 0.0001);
}

/// What `time.delta` said in each stage, the last time each ran.
const Deltas = struct {
    var fixed: f32 = 0;
    var update: f32 = 0;

    fn inFixed(app: *App) anyerror!void {
        fixed = app.time.delta;
    }

    fn inUpdate(app: *App) anyerror!void {
        update = app.time.delta;
    }
};

test "time.delta is the step in the fixed stage and the frame everywhere else" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 2,
        .fixed_delta = 1.0 / 64.0,
        .frame_time = 1.0 / 32.0,
    });
    defer app.destroy();

    try app.addSystem(.fixed, "in fixed", Deltas.inFixed);
    try app.addSystem(.update, "in update", Deltas.inUpdate);
    try app.run();

    try testing.expectEqual(@as(f32, 1.0 / 64.0), Deltas.fixed);
    try testing.expectEqual(@as(f32, 1.0 / 32.0), Deltas.update);
    // And put back afterwards.
    try testing.expectEqual(@as(f32, 1.0 / 32.0), app.time.delta);
}
