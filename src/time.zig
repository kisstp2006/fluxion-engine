// SPDX-License-Identifier: BSD-3-Clause

//! How long the last frame took, and the fixed step.
//!
//! Inside `.fixed`, `delta` is one fixed step; everywhere else it is the
//! frame's length. Anything that integrates belongs in `.fixed`, so that it
//! gives the same answer on every machine.
//!
//! The clock comes from `std.Io`, passed down from `main`. An `App` without
//! one steps by a fixed amount instead, which is what a test wants.

const std = @import("std");

const Time = @This();

/// Where a frame's length comes from.
pub const Source = union(enum) {
    /// The monotonic clock. What a game uses.
    clock: std.Io,
    /// Every frame is this many seconds long. What tests and `--capture` use.
    fixed: f32,
};

source: Source,

/// When the last frame was, if there is a clock.
last: std.Io.Timestamp = .zero,

/// The seconds the running stage covers: one fixed step inside `.fixed`, the
/// last frame everywhere else - scaled by `scale`, clamped by `max_delta`.
delta: f32 = 0,

/// `delta` before `scale`. What a pause menu animates on.
unscaled_delta: f32 = 0,

/// Seconds since the first frame, scaled. `f64`, because an `f32` can no
/// longer tell a sixtieth of a second apart after about a day.
elapsed: f64 = 0,

/// How many frames have been through the loop.
frame: u64 = 0,

/// 0.5 is slow motion, 0 is paused. Scales the fixed steps too.
scale: f32 = 1,

/// How long one `.fixed` step is.
fixed_delta: f32 = 1.0 / 60.0,

/// The longest a frame may claim to have been, so a stall slows the world
/// for a moment instead of moving everything through the walls.
max_delta: f32 = 0.25,

/// Time not yet spent on a whole fixed step.
accumulator: f32 = 0,

/// The most fixed steps one frame may run. Past it the backlog is dropped, so
/// a slow machine runs slow instead of never catching up.
max_fixed_steps: u32 = 8,

/// A countdown that lives in a component: a serve after a pause, a cooldown.
///
/// ```zig
/// const Ball = extern struct { wait: Timer = .seconds(1.2) };
///
/// if (ball.wait.tick(app.time.delta)) serve();   // true once, as it runs out
/// ```
///
/// Tick it in `.fixed` when the simulation depends on it.
pub const Timer = extern struct {
    /// Seconds until it goes off. Zero or less when it is not counting.
    left: f32 = 0,

    /// One that goes off after this many seconds.
    pub fn seconds(duration: f32) Timer {
        return .{ .left = duration };
    }

    /// Count down by `delta`, and say whether it went off in this call. True
    /// in exactly one call.
    pub fn tick(self: *Timer, delta: f32) bool {
        if (self.left <= 0) return false;
        self.left -= delta;
        return self.left <= 0;
    }

    /// Whether it is still counting.
    pub fn running(self: Timer) bool {
        return self.left > 0;
    }

    /// Make it go off at the next `tick`. Not the same as setting `left` to
    /// zero: at zero it is not counting, and the next `tick` says false.
    pub fn finish(self: *Timer) void {
        if (self.left > 0) self.left = std.math.floatMin(f32);
    }
};

pub fn init(source: Source) Time {
    return .{ .source = source };
}

/// Read the clock and work out this frame's length. Called once a frame, by
/// `App.step`.
pub fn tick(self: *Time) void {
    const raw = switch (self.source) {
        .fixed => |seconds| seconds,
        .clock => |io| blk: {
            const now: std.Io.Timestamp = .now(io, .awake);
            defer self.last = now;
            // The first frame has nothing to measure from, and counting the
            // start-up would move everything before anything is on screen.
            if (self.frame == 0) break :blk 0;
            const ns = self.last.durationTo(now).nanoseconds;
            break :blk @as(f32, @floatFromInt(@as(i64, @intCast(ns)))) / std.time.ns_per_s;
        },
    };

    self.unscaled_delta = @min(raw, self.max_delta);
    self.delta = self.unscaled_delta * self.scale;
    self.elapsed += self.delta;
    self.frame += 1;
    self.accumulator += self.delta;
}

/// Take one whole fixed step out of the accumulator, or null if there is not
/// one.
pub fn takeFixedStep(self: *Time) ?f32 {
    if (self.accumulator < self.fixed_delta) return null;
    self.accumulator -= self.fixed_delta;
    return self.fixed_delta;
}

/// Throw away a backlog too big to work through. See `max_fixed_steps`.
pub fn dropBacklog(self: *Time) void {
    const most = self.fixed_delta * @as(f32, @floatFromInt(self.max_fixed_steps));
    if (self.accumulator > most) self.accumulator = most;
}

/// Where the frame sits between two fixed steps, from zero to one: what
/// interpolated transforms are blended by.
pub fn alpha(self: Time) f32 {
    return std.math.clamp(self.accumulator / self.fixed_delta, 0, 1);
}

/// Frames per second, from the last frame alone. Not smoothed, so a single
/// slow frame shows.
pub fn fps(self: Time) f32 {
    if (self.unscaled_delta <= 0) return 0;
    return 1 / self.unscaled_delta;
}

test "a fixed source makes every frame the same length" {
    var time: Time = .init(.{ .fixed = 1.0 / 60.0 });
    for (0..60) |_| time.tick();

    try std.testing.expectEqual(@as(u64, 60), time.frame);
    try std.testing.expectApproxEqAbs(@as(f64, 1), time.elapsed, 0.0001);
}

test "the accumulator hands out whole steps and keeps the remainder" {
    var time: Time = .init(.{ .fixed = 0.025 });
    time.fixed_delta = 0.01;
    time.tick();

    var steps: u32 = 0;
    while (time.takeFixedStep()) |_| steps += 1;

    try std.testing.expectEqual(@as(u32, 2), steps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.005), time.accumulator, 0.0001);
}

test "a stalled frame is clamped rather than teleporting everything" {
    var time: Time = .init(.{ .fixed = 3 });
    time.tick();
    try std.testing.expectEqual(time.max_delta, time.delta);
}

test "scale slows the simulation and leaves the unscaled delta alone" {
    var time: Time = .init(.{ .fixed = 0.1 });
    time.scale = 0.5;
    time.tick();

    try std.testing.expectApproxEqAbs(@as(f32, 0.05), time.delta, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), time.unscaled_delta, 0.0001);
}

test "a timer goes off once, in the tick it runs out in" {
    var timer: Timer = .seconds(0.25);
    try std.testing.expect(timer.running());

    try std.testing.expect(!timer.tick(0.1));
    try std.testing.expect(!timer.tick(0.1));
    try std.testing.expect(timer.tick(0.1));
    try std.testing.expect(!timer.running());
    try std.testing.expect(!timer.tick(0.1));
}

test "finishing a timer makes the next tick go off, not skip it" {
    var timer: Timer = .seconds(10);
    timer.finish();
    try std.testing.expect(timer.running());
    try std.testing.expect(timer.tick(0.001));

    var idle: Timer = .{};
    idle.finish();
    try std.testing.expect(!idle.tick(0.001));
}
