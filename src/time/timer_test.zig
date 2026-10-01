// SPDX-License-Identifier: BSD-3-Clause

//! Timers through a whole app, headless.

const std = @import("std");
const testing = std.testing;

const timer = @import("timer.zig");
const App = @import("../App.zig");
const Timer = timer.Timer;
const ecs = @import("fluxion_ecs");

/// What the handlers heard.
const Heard = struct {
    var timeouts: usize = 0;

    fn timeout(_: *App, _: struct {}) !void {
        timeouts += 1;
    }
};

/// A quarter of a second a frame, and a fixed step each.
/// An app of quarter-second frames, with nothing heard yet.
fn quartered() !*App {
    Heard.timeouts = 0;
    return @import("../test_helpers.zig").quarterSecondApp();
}

fn frames(app: *App, n: usize) !void {
    for (0..n) |_| _ = try app.step();
}

test "a timer that starts by itself says timeout when it runs out, and again when it repeats" {
    const app = try quartered();
    defer app.destroy();
    const bell = try app.world.spawnWith(.{Timer{ .autostart = true }});
    try app.signal(bell, Timer, .timeout).connectFn(Heard.timeout, .{});

    try frames(app, 3);
    try testing.expectEqual(@as(usize, 0), Heard.timeouts);
    try testing.expectApproxEqAbs(@as(f32, 0.25), app.world.get(bell, Timer).?.time_left, 1e-5);
    try frames(app, 1);
    try testing.expectEqual(@as(usize, 1), Heard.timeouts);
    // Starting over, not stopped.
    try testing.expect(!app.world.get(bell, Timer).?.isStopped());
    try frames(app, 4);
    try testing.expectEqual(@as(usize, 2), Heard.timeouts);
}

test "a one-shot timer stops at its timeout, and start and stop do what they say" {
    const app = try quartered();
    defer app.destroy();
    const fuse = try app.world.spawnWith(.{Timer{ .one_shot = true }});
    try app.signal(fuse, Timer, .timeout).connectFn(Heard.timeout, .{});

    // Not started: nothing counts.
    try frames(app, 8);
    try testing.expectEqual(@as(usize, 0), Heard.timeouts);
    try testing.expect(app.world.get(fuse, Timer).?.isStopped());

    app.world.get(fuse, Timer).?.start(0.5);
    try testing.expectEqual(@as(f32, 0.5), app.world.get(fuse, Timer).?.wait_time);
    try frames(app, 2);
    try testing.expectEqual(@as(usize, 1), Heard.timeouts);
    try testing.expect(app.world.get(fuse, Timer).?.isStopped());
    try frames(app, 4);
    try testing.expectEqual(@as(usize, 1), Heard.timeouts);

    // Stopped before it runs out: no timeout.
    app.world.get(fuse, Timer).?.start(-1);
    try frames(app, 1);
    app.world.get(fuse, Timer).?.stop();
    try frames(app, 4);
    try testing.expectEqual(@as(usize, 1), Heard.timeouts);
}

test "a paused timer keeps its time, and one counted by fixed steps waits for them" {
    const app = try quartered();
    defer app.destroy();
    // Nine tenths: no count of quarters comes back round to it.
    const held = try app.world.spawnWith(.{Timer{ .wait_time = 0.9, .autostart = true, .paused = true }});
    const stepped = try app.world.spawnWith(.{Timer{ .autostart = true, .one_shot = true, .clock = .fixed }});
    try app.signal(stepped, Timer, .timeout).connectFn(Heard.timeout, .{});
    // A second of fixed steps: not a frame sooner.
    try frames(app, 3);
    try testing.expectEqual(@as(usize, 0), Heard.timeouts);
    try frames(app, 5);
    try testing.expectEqual(@as(f32, 0.9), app.world.get(held, Timer).?.time_left);

    // No time, no steps: a stopped clock counts nothing.
    app.time.scale = 0;
    try testing.expectEqual(@as(usize, 1), Heard.timeouts);
    const later = try app.world.spawnWith(.{Timer{ .autostart = true }});
    try frames(app, 8);
    try testing.expect(!app.world.get(later, Timer).?.counted);
    try testing.expect(app.world.get(later, Timer).?.isStopped());
}

test "a paused game's timers wait, but for one whose entity runs while it is paused" {
    const app = try quartered();
    defer app.destroy();
    const Processing = @import("../scene/inherited.zig").Processing;
    const game = try app.world.spawnWith(.{Timer{ .wait_time = 0.5, .autostart = true }});
    const menu = try app.world.spawnWith(.{ Processing{ .mode = .when_paused }, Timer{ .wait_time = 0.5, .autostart = true } });
    try frames(app, 1);
    try testing.expectEqual(@as(f32, 0.25), app.world.get(game, Timer).?.time_left);
    // Not counted, nor started, before its first pause.
    try testing.expect(!app.world.get(menu, Timer).?.counted);

    app.setPaused(true);
    try frames(app, 1);
    try testing.expectEqual(@as(f32, 0.25), app.world.get(game, Timer).?.time_left);
    try testing.expectEqual(@as(f32, 0.25), app.world.get(menu, Timer).?.time_left);

    app.setPaused(false);
    try frames(app, 1);
    try testing.expectEqual(@as(f32, 0.5), app.world.get(game, Timer).?.time_left);
    try testing.expectEqual(@as(f32, 0.25), app.world.get(menu, Timer).?.time_left);
}

test "a repeating timer keeps what a frame ran past, and keeps its rhythm" {
    const app = try quartered();
    defer app.destroy();
    // Three eighths of a second, counted a quarter at a time: eight
    // timeouts in three seconds, not the six a timer starting over from the
    // top each time would say.
    const tick = try app.world.spawnWith(.{Timer{ .wait_time = 0.375, .autostart = true }});
    try app.signal(tick, Timer, .timeout).connectFn(Heard.timeout, .{});
    try frames(app, 12);
    try testing.expectEqual(@as(usize, 8), Heard.timeouts);
}

test "a timer from createTimer says timeout once and goes" {
    const app = try quartered();
    defer app.destroy();
    const fuse = try app.createTimer(0.5);
    try app.signal(fuse, Timer, .timeout).connectFn(Heard.timeout, .{});
    try frames(app, 2);
    try testing.expectEqual(@as(usize, 1), Heard.timeouts);
    try frames(app, 1);
    try testing.expect(!app.world.isAlive(fuse));
    try testing.expectEqual(@as(usize, 1), Heard.timeouts);
}

test "a timer saved while it counts reads back where it was, and does not start over" {
    const app = try quartered();
    defer app.destroy();
    _ = try app.world.spawnWith(.{Timer{ .wait_time = 2, .autostart = true }});
    try frames(app, 3);
    const saved = try @import("../scene/scene.zig").write(app, testing.allocator, .{});
    defer testing.allocator.free(saved);

    const copy = try quartered();
    defer copy.destroy();
    _ = try @import("../scene/scene.zig").read(copy, saved, .{});
    var it = try ecs.Query(.{Timer}).over(&copy.world);
    const read = it.next().?.slice(Timer)[0];
    try testing.expectApproxEqAbs(@as(f32, 1.25), read.time_left, 1e-5);
    try testing.expect(read.counted);
}
