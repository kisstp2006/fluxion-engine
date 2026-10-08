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
//! with `clock = .fixed` once a fixed step before the `.fixed` systems - the
//! length a game's simulation depends on is the same on every machine that
//! way. What it says is heard when the count is done, before the stage's
//! systems run.
//!
//! **A timer counts while its entity runs**: a paused game's timers wait,
//! but for those under something whose `Processing` runs while it is paused
//! - a pause menu's. And a frame that gives no time counts nothing and
//! starts nothing: an editor, which never gives its world time, never starts
//! a timer in the scene it edits.

const std = @import("std");

const ecs = @import("fluxion_ecs");

const App = @import("../App.zig");
const attr = @import("../reflect/attr.zig");

const Entity = ecs.Entity;

pub const Timer = extern struct {
    /// Seconds from starting to `timeout`, and between two when it repeats.
    wait_time: f32 = 1,
    /// Whether it stops at its first `timeout`. Off, it starts over.
    one_shot: bool = false,
    /// Whether it starts by itself the first time the game counts it.
    autostart: bool = false,
    /// While on, it keeps its time and says nothing.
    paused: bool = false,
    clock: Clock = .update,
    /// Seconds to the next `timeout`, and zero while it is stopped.
    time_left: f32 = 0,
    /// Whether the engine has counted it yet, and so looked at `autostart`:
    /// a timer read back from a scene saved while it ran goes on from where
    /// it was rather than starting over.
    counted: bool = false,
    /// For `App.createTimer`'s: the entity goes once the timer stops.
    free_when_stopped: bool = false,

    /// When it counts.
    pub const Clock = enum(u8) {
        /// Each fixed step, before the `.fixed` systems.
        fixed,
        /// Each frame, before the `.update` systems.
        update,
    };

    pub const signals = .{
        // The time ran out: once for a one-shot timer, every `wait_time`
        // seconds for one that goes round.
        .timeout = struct {},
    };

    pub const reflect_name = "Timer";
    pub const reflect_fields = .{
        .wait_time = .{ attr.Unit{ .text = "s" }, attr.Range{ .min = 0.001, .max = 4096 } },
        .one_shot = .{attr.Doc{ .text = "Stops at its first timeout" }},
        .autostart = .{attr.Doc{ .text = "Starts by itself when the game first counts it" }},
        .paused = .{attr.Doc{ .text = "Keeps its time and says nothing" }},
        .clock = .{attr.Doc{ .text = "Counted each fixed step, or each frame" }},
        .time_left = .{ attr.ReadOnly{}, attr.Unit{ .text = "s" } },
        .counted = .{attr.Hidden{}},
        .free_when_stopped = .{attr.Hidden{}},
    };
    pub const reflect_methods = .{ .start = .{attr.Params{ .names = &.{"seconds"} }}, .stop = .{}, .isStopped = .{} };

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

/// Count every timer on `clock` by the time that passed - the frame's, or
/// in a fixed step the step's - and say each `timeout` that came: a pass of
/// `app/frame_steps.zig`.
pub fn count(app: *App, clock: Timer.Clock) !void {
    const delta = app.time.delta;
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
            if (timer.clock != clock) continue;
            // Not counted, not even started, while its entity waits.
            if (!app.timeMovesFor(e)) continue;
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
