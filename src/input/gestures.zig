// SPDX-License-Identifier: BSD-3-Clause

//! What the fingers make from frame to frame: a tap, a double tap, a long
//! press and a swipe of one finger alone, two fingers' pinch, pan and turn,
//! and the pinch a wheel turned with Ctrl makes. Each is put with the
//! pointer's events for the scripts to hear, and two fingers' are kept to
//! ask for as well.
//!
//! The lengths are in density-independent pixels, so a gesture is the same
//! size under a finger on any screen, and the times are on the fingers' own
//! clock, which the game's pause and time scale do not touch: a gesture is
//! the player's hand, not the game's clock.

const std = @import("std");

const math = @import("fluxion_math");

const Input = @import("input.zig");
const events = @import("input_event.zig");

const Vec2 = math.Vec2;
const Touch = Input.Touch;
const velocity_window = Input.velocity_window;

/// What two fingers did this frame - the first two down that no touch
/// button holds: how much they spread, how far they moved together, how
/// much they turned. The same as this frame's `PinchEvent`, `PanEvent` and
/// `RotateEvent`, to ask for rather than to hear.
pub const TwoFingers = struct {
    /// Whether two fingers are down.
    active: bool = false,
    /// Halfway between them, in the game area's pixels.
    center: Vec2 = .zero,
    /// How much farther apart they are than last frame.
    factor: f32 = 1,
    /// How far their middle moved this frame.
    relative: Vec2 = .zero,
    /// Radians they turned this frame, clockwise on the screen positive.
    rotation: f32 = 0,
    /// How much farther apart they are than when the second touched.
    scale: f32 = 1,
    /// Radians they turned since the second touched.
    angle: f32 = 0,

    pub const reflect_name = "TwoFingers";
};

/// How far, in density-independent pixels, a finger may drift and still
/// tap or press long.
pub const tap_slop_dp = 10;

/// Seconds a finger is held still before it is a long press.
pub const long_press_seconds = 0.5;

/// How soon after a tap was lifted a touch makes it a double tap, in
/// seconds, and how near, in density-independent pixels.
pub const double_tap_seconds = 0.3;

pub const double_tap_slop_dp = 100;

/// How far a swipe goes, and how fast the finger is going when it is
/// lifted, in density-independent pixels and those a second.
pub const swipe_distance_dp = 30;

pub const swipe_speed_dp = 300;

/// How much larger a notch of the wheel turned with Ctrl makes a pinch,
/// and how long a pause ends one.
pub const wheel_pinch_per_notch = 1.1;

pub const wheel_pinch_pause = 0.3;

/// One finger down, as the gestures follow it.
const Track = struct {
    finger: u32,
    start: Vec2,
    down_at: f64,
    /// It went past `tap_slop_dp`.
    wandered: bool = false,
    /// No other finger touched while it was down, and no touch button held
    /// it: only such a finger taps, presses long and swipes.
    alone: bool = true,
    long_pressed: bool = false,
    /// Where it was, frame by frame, the last few: for its speed.
    samples: [8]Sample = undefined,
    sample_count: usize = 0,
    next: usize = 0,

    const Sample = struct { at: Vec2, time: f64 };

    fn sample(self: *Track, at: Vec2, time: f64) void {
        self.samples[self.next] = .{ .at = at, .time = time };
        self.next = (self.next + 1) % self.samples.len;
        self.sample_count = @min(self.sample_count + 1, self.samples.len);
    }

    /// How fast it went over at least the last tenth of a second it has,
    /// in the game area's pixels a second.
    fn velocity(self: *const Track) Vec2 {
        if (self.sample_count < 2) return .zero;
        const newest = self.samples[(self.next + self.samples.len - 1) % self.samples.len];
        var oldest = newest;
        for (1..self.sample_count) |back| {
            oldest = self.samples[(self.next + self.samples.len - 1 - back) % self.samples.len];
            if (newest.time - oldest.time >= velocity_window) break;
        }
        const took = newest.time - oldest.time;
        if (took <= 0) return .zero;
        return newest.at.sub(oldest.at).scale(@floatCast(1 / took));
    }
};

const Pair = struct {
    first: u32,
    second: u32,
    center: Vec2,
    distance: f32,
    angle: f32,
    start_distance: f32,
    turned: f32 = 0,
};

const LastTap = struct { position: Vec2, time: f64, count: u32 };

/// The gestures' state, kept by `Input` from frame to frame.
pub const Gestures = struct {
    /// Seconds on the fingers' own clock: what `follow` has counted.
    time: f64 = 0,
    /// Each finger down, for the gestures it may make.
    tracks: [Input.max_fingers]Track = undefined,
    track_count: usize = 0,
    /// The two fingers whose pinch, pan and turn the last frame worked out.
    pair: ?Pair = null,
    /// The last tap, for the next to make a double tap.
    last_tap: ?LastTap = null,
    /// What two fingers did this frame.
    two_fingers: TwoFingers = .{},
    /// The pinch the wheel is making: how far it has gone, and when it last
    /// turned, on the fingers' clock.
    wheel_pinch: struct { scale: f32 = 1, time: f64 = -std.math.inf(f64) } = .{},

    /// What the fingers made this frame, put with the pointer's events: see
    /// `Input.trackFingers`.
    pub fn follow(self: *Gestures, input: *Input, delta: f32) void {
        self.time += delta;
        const now = self.time;
        for (input.fingers[0..input.finger_count]) |finger| {
            if (finger.pressed) self.startTrack(finger, now);
            const track = self.trackOf(finger.finger) orelse continue;
            track.sample(finger.position, now);
            if (finger.position.dist(track.start) > tap_slop_dp * input.dp) track.wandered = true;
            if (finger.on_button) track.alone = false;
            if (finger.released) {
                if (!finger.canceled and track.alone) self.lifted(input, track.*, finger, now);
                self.dropTrack(finger.finger);
                continue;
            }
            if (track.alone and !track.wandered and !track.long_pressed and now - track.down_at >= long_press_seconds) {
                track.long_pressed = true;
                input.pushPointer(.{ .long_press = .{ .finger = finger.finger, .position = finger.position } });
            }
        }
        self.trackPair(input);
    }

    fn startTrack(self: *Gestures, finger: Touch, now: f64) void {
        if (self.trackOf(finger.finger) != null or self.track_count == self.tracks.len) return;
        // A finger touching while others are down makes them all two fingers'.
        const alone = self.track_count == 0;
        for (self.tracks[0..self.track_count]) |*other| other.alone = false;
        self.tracks[self.track_count] = .{ .finger = finger.finger, .start = finger.position, .down_at = now, .alone = alone };
        self.track_count += 1;
    }

    fn trackOf(self: *Gestures, finger: u32) ?*Track {
        for (self.tracks[0..self.track_count]) |*track| {
            if (track.finger == finger) return track;
        }
        return null;
    }

    fn dropTrack(self: *Gestures, finger: u32) void {
        for (self.tracks[0..self.track_count], 0..) |track, i| {
            if (track.finger != finger) continue;
            self.tracks[i] = self.tracks[self.track_count - 1];
            self.track_count -= 1;
            return;
        }
    }

    /// A finger alone lifted: a tap where it touched, or a swipe far from it.
    fn lifted(self: *Gestures, input: *Input, track: Track, finger: Touch, now: f64) void {
        if (track.long_pressed) return;
        if (!track.wandered) {
            var count: u32 = 1;
            if (self.last_tap) |last| {
                if (track.down_at - last.time <= double_tap_seconds and track.start.dist(last.position) <= double_tap_slop_dp * input.dp) count = last.count + 1;
            }
            self.last_tap = .{ .position = finger.position, .time = now, .count = count };
            input.pushPointer(.{ .tap = .{ .finger = finger.finger, .position = finger.position, .count = count } });
            return;
        }
        const velocity = track.velocity();
        if (finger.position.dist(track.start) < swipe_distance_dp * input.dp or velocity.len() < swipe_speed_dp * input.dp) return;
        const direction: events.SwipeEvent.Direction = if (@abs(velocity.x) >= @abs(velocity.y))
            (if (velocity.x < 0) .left else .right)
        else
            (if (velocity.y < 0) .up else .down);
        input.pushPointer(.{ .swipe = .{ .finger = finger.finger, .start = track.start, .position = finger.position, .velocity = velocity, .direction = direction } });
    }

    /// The first two fingers down that no touch button holds: how much they
    /// spread, moved and turned since last frame. A new pair starts from where
    /// it is, and says nothing on its first frame.
    fn trackPair(self: *Gestures, input: *Input) void {
        self.two_fingers = .{};
        var found: [2]Touch = undefined;
        var count: usize = 0;
        for (input.fingers[0..input.finger_count]) |finger| {
            if (!finger.down() or finger.on_button) continue;
            found[count] = finger;
            count += 1;
            if (count == 2) break;
        }
        if (count < 2) {
            self.pair = null;
            return;
        }
        const center = found[0].position.add(found[1].position).scale(0.5);
        const span = found[1].position.sub(found[0].position);
        const distance = @max(span.len(), 0.001);
        const angle = std.math.atan2(span.y, span.x);
        self.two_fingers.active = true;
        self.two_fingers.center = center;

        const held = if (self.pair) |*kept| (if (kept.first == found[0].finger and kept.second == found[1].finger) kept else null) else null;
        const pair = held orelse {
            self.pair = .{ .first = found[0].finger, .second = found[1].finger, .center = center, .distance = distance, .angle = angle, .start_distance = distance };
            return;
        };
        const factor = distance / pair.distance;
        const rotation = wrapAngle(angle - pair.angle);
        const relative = center.sub(pair.center);
        pair.turned += rotation;
        pair.center = center;
        pair.distance = distance;
        pair.angle = angle;
        self.two_fingers.factor = factor;
        self.two_fingers.relative = relative;
        self.two_fingers.rotation = rotation;
        self.two_fingers.scale = distance / pair.start_distance;
        self.two_fingers.angle = pair.turned;

        if (factor != 1) input.pushPointer(.{ .pinch = .{ .center = center, .factor = factor, .scale = self.two_fingers.scale } });
        if (relative.x != 0 or relative.y != 0) input.pushPointer(.{ .pan = .{ .center = center, .relative = relative } });
        if (rotation != 0) input.pushPointer(.{ .rotate = .{ .center = center, .angle = rotation, .total = pair.turned } });
    }

    /// A wheel turned with Ctrl, as a pinch at the pointer: a notch up is a
    /// tenth larger, a notch down a tenth smaller. One pinch goes on until the
    /// wheel rests `wheel_pinch_pause`.
    pub fn wheelPinch(self: *Gestures, input: *Input, notches: f32) void {
        const factor = std.math.pow(f32, wheel_pinch_per_notch, notches);
        if (self.time - self.wheel_pinch.time > wheel_pinch_pause) self.wheel_pinch.scale = 1;
        self.wheel_pinch.scale *= factor;
        self.wheel_pinch.time = self.time;
        input.pushPointer(.{ .pinch = .{ .center = .init(input.pointer.x, input.pointer.y), .factor = factor, .scale = self.wheel_pinch.scale } });
    }
};

/// An angle between minus and plus half a turn.
fn wrapAngle(angle: f32) f32 {
    var wrapped = angle;
    while (wrapped > std.math.pi) wrapped -= 2 * std.math.pi;
    while (wrapped < -std.math.pi) wrapped += 2 * std.math.pi;
    return wrapped;
}
