// SPDX-License-Identifier: BSD-3-Clause

//! A `Timer`: a component that counts down, and says `timeout` when it runs
//! out.
//!
//! ```zig
//! const door = try app.world.spawnWith(.{ fx.Transform2D.at(0, 0), fx.Timer{ .wait_time = 2, .one_shot = true, .autostart = true } });
//! try app.signal(door, fx.Timer, .timeout).connect(.method(door, "_on_timer_timeout"), .{});
//!
//! app.world.get(door, fx.Timer).?.start(5);   // five seconds, from now
//! const fuse = try app.createTimer(1.5);      // one to connect to and forget
//! ```
//!
//! **Counted by the engine**, once a frame before the `.update` systems, or
//! with `process_mode = .physics` once a fixed step before the `.fixed`
//! systems - the length a game's simulation depends on is the same on every
//! machine that way. What it says is heard when the count is done, before
//! the stage's systems run.
//!
//! **A frame that gives no time counts nothing**, and starts nothing: a
//! paused game's timers wait, and an editor, which never gives its world
//! time, never starts a timer in the scene it edits.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");

const App = @import("App.zig");
const attr = @import("attr.zig");

const Entity = ecs.Entity;
const log = std.log.scoped(.fluxion_engine);

pub const Timer = extern struct {
    /// Seconds from starting to `timeout`, and between two when it repeats.
    wait_time: f32 = 1,
    /// Whether it stops at its first `timeout`. Off, it starts over.
    one_shot: bool = false,
    /// Whether it starts by itself the first time the game counts it.
    autostart: bool = false,
    /// While on, it keeps its time and says nothing.
    paused: bool = false,
    process_mode: ProcessMode = .idle,
    /// Seconds to the next `timeout`, and zero while it is stopped.
    time_left: f32 = 0,
    /// Whether the engine has counted it yet, and so looked at `autostart`:
    /// a timer read back from a scene saved while it ran goes on from where
    /// it was rather than starting over.
    counted: bool = false,
    /// For `App.createTimer`'s: the entity goes once the timer stops.
    free_when_stopped: bool = false,

    /// When it counts.
    pub const ProcessMode = enum(u8) {
        /// Each fixed step, before the `.fixed` systems.
        physics,
        /// Each frame, before the `.update` systems.
        idle,
    };

    pub const signals = .{ .timeout = struct {} };

    pub const reflect_name = "Timer";
    pub const reflect_fields = .{
        .wait_time = .{ attr.Unit{ .text = "s" }, attr.Range{ .min = 0.001, .max = 4096 } },
        .one_shot = .{attr.Doc{ .text = "Stops at its first timeout" }},
        .autostart = .{attr.Doc{ .text = "Starts by itself when the game first counts it" }},
        .paused = .{attr.Doc{ .text = "Keeps its time and says nothing" }},
        .process_mode = .{attr.Doc{ .text = "Counted each frame, or each fixed step" }},
        .time_left = .{ attr.ReadOnly{}, attr.Unit{ .text = "s" } },
        .counted = .{attr.Hidden{}},
        .free_when_stopped = .{attr.Hidden{}},
    };
    pub const reflect_methods = .{ .start, .stop, .isStopped };

    /// Start counting from the top: from `seconds`, which becomes
    /// `wait_time`, or with nought or less from `wait_time` as it is.
    pub fn start(self: *Timer, seconds: f32) void {
        if (seconds > 0) self.wait_time = seconds;
        self.time_left = @max(self.wait_time, 0);
    }

    /// Stop, with no `timeout`. `time_left` is zero.
    pub fn stop(self: *Timer) void {
        self.time_left = 0;
    }

    pub fn isStopped(self: Timer) bool {
        return self.time_left <= 0;
    }
};

/// Count every timer of `mode` by `delta`, and say each `timeout` that came.
/// What `App.step` calls.
pub fn count(app: *App, mode: Timer.ProcessMode, delta: f32) !void {
    if (delta <= 0) return;
    var gone: std.ArrayList(Entity) = .empty;
    defer gone.deinit(app.gpa);
    var fired: std.ArrayList(Entity) = .empty;
    defer fired.deinit(app.gpa);

    var it = ecs.Query(.{Timer}).over(&app.world) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Nothing has a `Timer` then.
        error.TooManyComponents => return,
    };
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(Timer)) |e, *timer| {
            if (timer.process_mode != mode) continue;
            if (!timer.counted) {
                timer.counted = true;
                if (timer.autostart) timer.start(-1);
            }
            if (timer.paused or timer.isStopped()) {
                if (timer.free_when_stopped and timer.isStopped()) try gone.append(app.gpa, e);
                continue;
            }
            timer.time_left -= delta;
            if (timer.time_left > 0) continue;
            if (timer.one_shot) {
                timer.time_left = 0;
            } else {
                // Starting over keeps what the frame ran past, so a timer
                // that repeats keeps its rhythm.
                timer.time_left = @max(timer.time_left + timer.wait_time, 0);
            }
            try fired.append(app.gpa, e);
        }
    }
    // Said after the walk: a handler heard at the drain may change the world.
    for (fired.items) |e| try app.emit(e, Timer, .timeout, .{});
    for (gone.items) |e| app.world.despawn(e);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// What the handlers heard.
const Heard = struct {
    var timeouts: usize = 0;

    fn timeout(_: *App, _: struct {}) !void {
        timeouts += 1;
    }
};

/// A quarter of a second a frame, and a fixed step each.
fn quartered() !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .fixed_delta = 0.25 });
    app.time.source = .{ .fixed = 0.25 };
    Heard.timeouts = 0;
    return app;
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
    const stepped = try app.world.spawnWith(.{Timer{ .autostart = true, .one_shot = true, .process_mode = .physics }});
    try app.signal(stepped, Timer, .timeout).connectFn(Heard.timeout, .{});
    // A second of fixed steps: not a frame sooner.
    try frames(app, 3);
    try testing.expectEqual(@as(usize, 0), Heard.timeouts);
    try frames(app, 5);
    try testing.expectEqual(@as(f32, 0.9), app.world.get(held, Timer).?.time_left);

    // No time, no steps: a paused game counts nothing.
    app.time.scale = 0;
    try testing.expectEqual(@as(usize, 1), Heard.timeouts);
    const later = try app.world.spawnWith(.{Timer{ .autostart = true }});
    try frames(app, 8);
    try testing.expect(!app.world.get(later, Timer).?.counted);
    try testing.expect(app.world.get(later, Timer).?.isStopped());
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
    const saved = try @import("scene.zig").write(app, testing.allocator, .{});
    defer testing.allocator.free(saved);

    const copy = try quartered();
    defer copy.destroy();
    _ = try @import("scene.zig").read(copy, saved, .{});
    var it = try ecs.Query(.{Timer}).over(&copy.world);
    const read = it.next().?.slice(Timer)[0];
    try testing.expectApproxEqAbs(@as(f32, 1.25), read.time_left, 1e-5);
    try testing.expect(read.counted);
}
