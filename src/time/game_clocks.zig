// SPDX-License-Identifier: BSD-3-Clause

//! A game's own clocks: a date and time that runs at a rate of its own - a
//! night from midnight to six in six minutes, a farm's days - with no entity
//! needed for one.
//!
//! ```zig
//! const night = try app.newClock(.{ .start = fx.DateTime.at(.utc, 2026, 1, 1, 0, 0, 0), .rate = 60 });
//! app.clockTime(night)              // a DateTime: a minute of it every real second
//! app.clockPassed(night).hours      // how many hours turned over in the last frame
//! app.setClockRate(night, 120);
//! app.pauseClock(night);
//! ```
//!
//! **A clock keeps the time it is given, without a zone**: no summer time
//! moves it, and `clockTime` gives it in UTC, whose fields are the clock's.
//!
//! It runs on the frame's time - so `time.scale` slows it - and stands while
//! the game is paused. Given an `owner`, it runs as the entity does (see
//! `Processing`) and goes with it. An editor's frames have no time, so no
//! clock runs there.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const datetime = @import("datetime.zig");

const DateTime = datetime.DateTime;
const Entity = ecs.Entity;

const us_per_minute: i64 = 60 * 1_000_000;
const us_per_hour: i64 = 60 * us_per_minute;
const us_per_day: i64 = 24 * us_per_hour;

/// One clock, and whether it is still the one it was.
pub const ClockHandle = extern struct {
    index: u32 = 0,
    generation: u32 = 0,

    pub const none: ClockHandle = .{};

    pub fn isNone(self: ClockHandle) bool {
        return self.generation == 0;
    }

    pub fn eql(self: ClockHandle, other: ClockHandle) bool {
        return self.index == other.index and self.generation == other.generation;
    }
};

pub const Options = struct {
    /// Where it starts: its fields, whatever its zone.
    start: DateTime = .{},
    /// Seconds of it a real second: 60 is a minute a second. Nought stands.
    rate: f64 = 1,
    paused: bool = false,
    /// Runs as this entity does, and goes with it.
    owner: ?Entity = null,
};

/// What turned over in a clock's last step: minutes, hours and days, each
/// counted, whether the step was a second or a week.
pub const Passed = struct {
    minutes: u64 = 0,
    hours: u64 = 0,
    days: u64 = 0,
};

pub const Clock = struct {
    /// Microseconds since 1970 on its face.
    reading: i64,
    rate: f64,
    paused: bool,
    owner: ?Entity,
    /// A part of a microsecond not yet shown.
    leftover: f64 = 0,
    passed: Passed = .{},

    pub fn time(self: *const Clock) DateTime {
        return DateTime.fromWallMicroseconds(self.reading);
    }
};

const Slot = struct {
    generation: u32,
    clock: ?Clock,
};

pub const Clocks = struct {
    slots: std.ArrayList(Slot) = .empty,

    pub fn deinit(self: *Clocks, gpa: Allocator) void {
        self.slots.deinit(gpa);
    }

    pub fn add(self: *Clocks, gpa: Allocator, options: Options) Allocator.Error!ClockHandle {
        const clock: Clock = .{
            .reading = options.start.wallMicroseconds(),
            .rate = options.rate,
            .paused = options.paused,
            .owner = options.owner,
        };
        for (self.slots.items, 0..) |*slot, i| {
            if (slot.clock != null) continue;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.clock = clock;
            return .{ .index = @intCast(i), .generation = slot.generation };
        }
        try self.slots.append(gpa, .{ .generation = 1, .clock = clock });
        return .{ .index = @intCast(self.slots.items.len - 1), .generation = 1 };
    }

    pub fn remove(self: *Clocks, handle: ClockHandle) void {
        const slot = self.slotOf(handle) orelse return;
        slot.clock = null;
    }

    pub fn get(self: *Clocks, handle: ClockHandle) ?*Clock {
        const slot = self.slotOf(handle) orelse return null;
        return if (slot.clock) |*clock| clock else null;
    }

    fn slotOf(self: *Clocks, handle: ClockHandle) ?*Slot {
        if (handle.isNone() or handle.index >= self.slots.items.len) return null;
        const slot = &self.slots.items[handle.index];
        return if (slot.generation == handle.generation and slot.clock != null) slot else null;
    }

    /// Every clock on by `delta` seconds of the frame, as `runs` says of
    /// each; one whose owner is gone goes too. What turned over is in each
    /// clock's `passed` until the next step.
    pub fn step(self: *Clocks, delta: f32, context: anytype, comptime runs: fn (@TypeOf(context), ?Entity) Runs) void {
        for (self.slots.items) |*slot| {
            const clock = &(slot.clock orelse continue);
            clock.passed = .{};
            const how = runs(context, clock.owner);
            if (how == .gone) {
                slot.clock = null;
                continue;
            }
            if (how == .still or clock.paused or delta <= 0 or clock.rate <= 0) continue;
            const exact = @as(f64, delta) * clock.rate * 1_000_000 + clock.leftover;
            const whole = @floor(exact);
            clock.leftover = exact - whole;
            const before = clock.reading;
            clock.reading +|= @intFromFloat(@min(whole, @as(f64, @floatFromInt(std.math.maxInt(i64) / 2))));
            clock.passed = .{
                .minutes = turned(before, clock.reading, us_per_minute),
                .hours = turned(before, clock.reading, us_per_hour),
                .days = turned(before, clock.reading, us_per_day),
            };
        }
    }

    /// Whether an owner's clock runs this frame.
    pub const Runs = enum { runs, still, gone };
};

fn turned(before: i64, after: i64, size: i64) u64 {
    return @intCast(@max(0, @divFloor(after, size) - @divFloor(before, size)));
}

test "a clock runs at its rate, counts what turns over, and stands when paused or told" {
    var clocks: Clocks = .{};
    defer clocks.deinit(testing.allocator);
    const Always = struct {
        fn runs(_: void, _: ?Entity) Clocks.Runs {
            return .runs;
        }
    };
    const night = try clocks.add(testing.allocator, .{ .start = DateTime.at(.utc, 2026, 1, 1, 23, 59, 30), .rate = 60 });
    // Two real seconds are two minutes: over midnight, into a new day.
    clocks.step(2, {}, Always.runs);
    const clock = clocks.get(night).?;
    try testing.expectEqual(@as(u8, 0), clock.time().hour);
    try testing.expectEqual(@as(u8, 1), clock.time().minute);
    try testing.expectEqual(@as(u8, 2), clock.time().day);
    try testing.expectEqual(Passed{ .minutes = 2, .hours = 1, .days = 1 }, clock.passed);
    // A tenth of a second at a rate of 1 is kept until it adds up.
    clock.rate = 1;
    for (0..10) |_| clocks.step(0.1, {}, Always.runs);
    try testing.expectEqual(@as(u8, 31), clock.time().second);
    clock.paused = true;
    clocks.step(5, {}, Always.runs);
    try testing.expectEqual(@as(u8, 31), clock.time().second);
    try testing.expectEqual(Passed{}, clock.passed);

    // Taken away, its handle finds nothing, and the slot's next clock is another.
    clocks.remove(night);
    try testing.expect(clocks.get(night) == null);
    const next = try clocks.add(testing.allocator, .{});
    try testing.expect(!next.eql(night));
    try testing.expect(clocks.get(night) == null);
}
