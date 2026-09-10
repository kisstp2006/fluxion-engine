// SPDX-License-Identifier: BSD-3-Clause

//! How long the last frame took, and how the fixed step is paid for.
//!
//! ```zig
//! fn move(app: *App) !void {
//!     const dt = app.time.delta;          // seconds, already scaled
//!     ...
//! }
//! ```
//!
//! **Two clocks, one name.** Outside the `.fixed` stage, `delta` is however
//! long the last frame actually took, and a system that uses it moves
//! smoothly whatever the frame rate. The `.fixed` stage runs as many times per
//! frame as it takes to catch up - none on a fast frame, twice on a slow one -
//! and each of those steps is `fixed_delta` long, so while it runs, `delta`
//! *is* `fixed_delta`. A system reads `delta` in whichever stage it is in and
//! gets the time that stage covers; the bug this prevents is a `.fixed` system
//! reading the frame's length, which moves things at a speed that depends on
//! the screen. Physics and anything that integrates belongs in `.fixed`,
//! because a simulation stepped by a number that changes is a simulation that
//! gives a different answer on a different machine.
//!
//! **The clock comes from outside.** Zig 0.16 took `std.time.Timer` away and
//! put the monotonic clock behind `std.Io`, which is the interface a program
//! passes down from `main` rather than reaches for. That turns out to be
//! exactly what a game engine wants anyway: an `App` with no `Io` steps by a
//! fixed amount instead, so a test runs sixty frames in no time at all and
//! gets the same numbers every run. See `Source`.

const std = @import("std");

const Time = @This();

/// Where a frame's length comes from.
pub const Source = union(enum) {
    /// The machine's monotonic clock. What a game uses.
    clock: std.Io,
    /// Every frame is this many seconds, however long it really took. What a
    /// test uses, and what `App.Options.frame_time` sets - which `--capture`
    /// does, to record the same footage twice.
    fixed: f32,
};

source: Source,

/// When the last frame was, if there is a clock. Meaningless otherwise.
last: std.Io.Timestamp = .zero,

/// The seconds the running stage covers: inside `.fixed`, one fixed step;
/// everywhere else, the last frame, scaled by `scale` and clamped by
/// `max_delta`. The number nearly every system wants, in every stage.
delta: f32 = 0,

/// The same, before `scale` was applied. What a pause menu animates on while
/// the world it covers is frozen.
unscaled_delta: f32 = 0,

/// Seconds since the first frame, scaled. `f64` because an `f32` stops being
/// able to represent a sixtieth of a second after about a day of running, and
/// a long-lived server would quietly stop advancing.
elapsed: f64 = 0,

/// How many frames have been through the loop.
frame: u64 = 0,

/// Slow motion at 0.5, pause at 0. Multiplies `delta` and the fixed steps
/// alike, so the whole simulation slows and not half of it.
scale: f32 = 1,

/// How long one `.fixed` step is: the setting, sixty a second. A system does
/// not read this to move by it - inside `.fixed`, `delta` already is it.
fixed_delta: f32 = 1.0 / 60.0,

/// The longest a frame is allowed to claim to have been.
///
/// Without this, a frame that stalled - a breakpoint, a window drag, a
/// texture upload - hands the next one a delta of several seconds, and every
/// moving thing teleports through the wall it should have hit. Clamping means
/// a stall shows up as the world running slow for a moment, which is the
/// failure everybody prefers.
max_delta: f32 = 0.25,

/// Unspent time, waiting for a whole fixed step to be made of it.
accumulator: f32 = 0,

/// How many fixed steps one frame may run before giving up on catching up.
///
/// The bound that stops the spiral of death: if each fixed step takes longer
/// than a fixed step is worth, an unbounded loop never finishes. Dropping the
/// backlog makes the simulation run slow instead of stopping, and a slow
/// simulation is one a player can still play.
max_fixed_steps: u32 = 8,

/// A countdown that lives in a component: a serve after a pause, a cooldown,
/// a power-up running out.
///
/// ```zig
/// const Ball = extern struct { wait: Timer = .seconds(1.2) };
///
/// if (ball.wait.tick(app.time.delta)) serve();   // true once, as it runs out
/// ```
///
/// **A value, not a callback.** A component may not hold a function, and a
/// countdown the game ticks itself runs in whichever stage the game ticks it
/// in - `.fixed` for anything the simulation depends on, so the pause is the
/// same length on every machine. The whole of it is one number, which is
/// also what makes it save and load with the world.
pub const Timer = extern struct {
    /// Seconds until it goes off. Zero or less when it is not counting.
    left: f32 = 0,

    /// One that goes off after this many seconds.
    pub fn seconds(duration: f32) Timer {
        return .{ .left = duration };
    }

    /// Count down by `delta`, and say whether it went off in this call.
    ///
    /// True in exactly one call - the one it ran out in - and false before
    /// and after, so the thing it was waiting for happens once.
    pub fn tick(self: *Timer, delta: f32) bool {
        if (self.left <= 0) return false;
        self.left -= delta;
        return self.left <= 0;
    }

    /// Whether it is still counting.
    pub fn running(self: Timer) bool {
        return self.left > 0;
    }

    /// Make it go off at the next `tick`, however long it had left: what
    /// "press space to serve now" is. Doing nothing to one that is not
    /// counting, because there is nothing to cut short.
    ///
    /// Not the same as setting `left` to zero, and the difference is the bug
    /// this exists to prevent: at zero a timer is not counting, so the next
    /// `tick` says false and whatever it was waiting for never happens.
    pub fn finish(self: *Timer) void {
        if (self.left > 0) self.left = std.math.floatMin(f32);
    }
};

pub fn init(source: Source) Time {
    return .{ .source = source };
}

/// Read the clock, and work out what the frame it starts is worth.
///
/// Called once at the top of a frame, by `App.step`, and by nothing else.
pub fn tick(self: *Time) void {
    const raw = switch (self.source) {
        .fixed => |seconds| seconds,
        .clock => |io| blk: {
            const now: std.Io.Timestamp = .now(io, .awake);
            defer self.last = now;
            // The first frame has nothing to measure from, and would
            // otherwise be however long the program took to start up - which
            // on a cold start is most of a second of movement before anything
            // is on screen.
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

/// Take one whole fixed step out of the accumulator, or say there is not one.
///
/// ```zig
/// while (app.time.takeFixedStep()) |_| try schedule.run(.fixed, app);
/// ```
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

/// Where between two fixed steps the current frame sits, from zero to one.
///
/// What a renderer interpolates positions with when it wants a body stepped
/// at sixty hertz to be drawn smoothly at a hundred and forty-four. Nothing
/// here uses it yet; it is the number that will be needed the moment
/// something does.
pub fn alpha(self: Time) f32 {
    return std.math.clamp(self.accumulator / self.fixed_delta, 0, 1);
}

/// Frames per second, averaged over nothing at all - one frame's worth.
///
/// Jittery on purpose. A smoothed figure hides exactly the single slow frame
/// that is worth knowing about, so smoothing is left to whoever displays it.
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
    // Gone off, and not again.
    try std.testing.expect(!timer.running());
    try std.testing.expect(!timer.tick(0.1));
}

test "finishing a timer makes the next tick go off, not skip it" {
    var timer: Timer = .seconds(10);
    timer.finish();
    try std.testing.expect(timer.running());
    try std.testing.expect(timer.tick(0.001));

    // One that was not counting has nothing to cut short.
    var idle: Timer = .{};
    idle.finish();
    try std.testing.expect(!idle.tick(0.001));
}
