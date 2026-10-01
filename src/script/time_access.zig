// SPDX-License-Identifier: BSD-3-Clause

//! What a script reaches as `time`: this moment, dates and spans of time
//! written in the game's culture, and clocks of the game's own.

const platform = @import("fluxion_platform");
const flux = @import("fluxion_script");
const App = @import("../App.zig");
const attr = @import("../reflect/attr.zig");
const datetime = @import("../time/datetime.zig");
const clocks_mod = @import("../time/game_clocks.zig");

const Scripts = @import("script.zig").Scripts;

/// What a script reaches as `time`: this moment, dates made and read,
/// spans of time, the culture they are written in, and clocks of the game's
/// own. Dates are `DateTime` values and spans `Duration` ones, with their
/// calls:
///
/// ```
/// let now = time.now();
/// print(now.formatStyle("long", "short"));          // 2026. szeptember 25. 19:42
/// print(now.addDays(1).format("EEEE"));              // szombat
/// let saved = time.parse("2026-09-25T18:00:00+02:00");
/// print(saved.relative());                           // 1 órával ezelőtt
/// let night = time.clock(time.date(2026, 1, 1), 60);
/// night.hour_passed.connect(fn(hours) { print(night.time().format("h a")); });
/// ```
pub const TimeAccess = struct {
    app: *App,

    pub const reflect_name = "Time";
    pub const reflect_opaque = true;
    pub const reflect_methods = .{
        .now = .{},
        .utcNow = .{},
        .unix = .{},
        .fromUnix = .{attr.Params{ .names = &.{"seconds"} }},
        .date = .{ attr.Params{ .names = &.{ "year", "month", "day", "hour", "minute", "second" } }, attr.defaults(.{ 0, 0, 0 }) },
        .utcDate = .{ attr.Params{ .names = &.{ "year", "month", "day", "hour", "minute", "second" } }, attr.defaults(.{ 0, 0, 0 }) },
        .parse = .{ attr.Params{ .names = &.{"text"} }, flux.GivesErrors{} },
        .seconds = .{attr.Params{ .names = &.{"n"} }},
        .minutes = .{attr.Params{ .names = &.{"n"} }},
        .hours = .{attr.Params{ .names = &.{"n"} }},
        .days = .{attr.Params{ .names = &.{"n"} }},
        .locale = .{},
        .setLocale = .{ attr.Params{ .names = &.{"tag"} }, flux.GivesErrors{} },
        .systemLocale = .{attr.Params{ .names = &.{"vm"} }},
        .zoneName = .{attr.Params{ .names = &.{"vm"} }},
        .clock = .{ attr.Params{ .names = &.{ "vm", "start", "rate" } }, attr.defaults(.{1.0}), flux.Returns.of(ClockRef) },
    };

    /// This moment, on the player's calendar and clock.
    pub fn now(self: *TimeAccess) datetime.DateTime {
        return self.app.localNow();
    }

    pub fn utcNow(self: *TimeAccess) datetime.DateTime {
        return self.app.now().in(.utc);
    }

    /// Seconds since 1970-01-01 00:00 UTC.
    pub fn unix(self: *TimeAccess) f64 {
        return self.app.now().unix();
    }

    /// The moment `seconds` after 1970 began, on the player's clock.
    pub fn fromUnix(_: *TimeAccess, since_1970: f64) datetime.DateTime {
        return datetime.Instant.fromUnix(since_1970).in(.local);
    }

    /// A date and time on the player's clock. What does not fit carries
    /// over: day 32 of January is the first of February.
    pub fn date(_: *TimeAccess, year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64) datetime.DateTime {
        return datetime.DateTime.at(.local, year, month, day, hour, minute, second);
    }

    pub fn utcDate(_: *TimeAccess, year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64) datetime.DateTime {
        return datetime.DateTime.at(.utc, year, month, day, hour, minute, second);
    }

    /// ISO 8601: `2026-09-25`, `2026-09-25 19:42`, `...T19:42:05+02:00`.
    /// One without an offset is on the player's clock.
    pub fn parse(_: *TimeAccess, text: []const u8) anyerror!datetime.DateTime {
        return datetime.DateTime.parseIso(text, .local);
    }

    pub fn seconds(_: *TimeAccess, n: f64) datetime.Duration {
        return .ofSeconds(n);
    }
    pub fn minutes(_: *TimeAccess, n: f64) datetime.Duration {
        return .ofMinutes(n);
    }
    pub fn hours(_: *TimeAccess, n: f64) datetime.Duration {
        return .ofHours(n);
    }
    pub fn days(_: *TimeAccess, n: f64) datetime.Duration {
        return .ofDays(n);
    }

    /// The tag of the culture dates are written in: `hu-HU`.
    pub fn locale(self: *TimeAccess) anyerror![]const u8 {
        return self.app.locale();
    }

    /// Write in `tag`'s way from now on - `de-DE` - or, for `""`, the
    /// player's.
    pub fn setLocale(self: *TimeAccess, tag: []const u8) anyerror!void {
        try self.app.setLocale(tag);
    }

    /// The player's own locale, whatever the game writes in.
    pub fn systemLocale(_: *TimeAccess, vm: *flux.Vm) []const u8 {
        const scripts: *Scripts = @ptrCast(@alignCast(vm.host.?));
        const held: *[platform.culture.max_tag]u8 = scripts.said[0..platform.culture.max_tag];
        return platform.culture.userLocale(held);
    }

    /// The player's time zone: `Europe/Budapest`, where the system names it.
    pub fn zoneName(_: *TimeAccess, vm: *flux.Vm) []const u8 {
        const scripts: *Scripts = @ptrCast(@alignCast(vm.host.?));
        return platform.culture.timeZoneName(&scripts.said);
    }

    /// A clock of the game's own, showing `start`'s fields and running
    /// `rate` seconds a real second. See `ClockRef`.
    pub fn clock(self: *TimeAccess, vm: *flux.Vm, start: datetime.DateTime, rate: f64) anyerror!flux.Value {
        const scripts: *Scripts = @ptrCast(@alignCast(vm.host.?));
        const handle = try self.app.newClock(.{ .start = start, .rate = rate });
        return clockValue(scripts, handle);
    }
};

/// A clock of the game's own as a script holds it: what `time.clock(start,
/// rate)` gives. `time()` is what it shows, `setTime`, `setRate`, `pause`,
/// `unpause` and `remove` change it, and its signals say what turned over -
/// each once a frame with how many:
///
/// ```
/// let night = time.clock(time.date(2026, 1, 1), 60);
/// night.hour_passed.connect(fn(hours) { if (night.time().hour == 6) win(); });
/// await night.day_passed;
/// ```
///
/// It stands while the game is paused. A call on one taken away says so.
pub const ClockRef = struct {
    scripts: *Scripts,
    handle: clocks_mod.ClockHandle,

    pub const signal_names = [3][]const u8{ "minute_passed", "hour_passed", "day_passed" };

    pub const reflect_name = "Clock";
    pub const reflect_opaque = true;
    pub const reflect_methods = .{
        .time = .{},
        .setTime = .{attr.Params{ .names = &.{"time"} }},
        .rate = .{},
        .setRate = .{attr.Params{ .names = &.{"rate"} }},
        .pause = .{},
        .unpause = .{},
        .isPaused = .{},
        .remove = .{},
    };

    /// What it shows.
    pub fn time(self: *ClockRef) anyerror!datetime.DateTime {
        return self.scripts.app.clockTime(self.handle) orelse error.NoSuchClock;
    }

    /// Show `to`'s fields from now on.
    pub fn setTime(self: *ClockRef, to: datetime.DateTime) anyerror!void {
        if (self.scripts.app.clockTime(self.handle) == null) return error.NoSuchClock;
        self.scripts.app.setClockTime(self.handle, to);
    }

    /// Seconds of it a real second.
    pub fn rate(self: *ClockRef) f64 {
        return self.scripts.app.clockRate(self.handle);
    }

    pub fn setRate(self: *ClockRef, to: f64) anyerror!void {
        if (self.scripts.app.clockTime(self.handle) == null) return error.NoSuchClock;
        self.scripts.app.setClockRate(self.handle, to);
    }

    pub fn pause(self: *ClockRef) void {
        self.scripts.app.pauseClock(self.handle);
    }

    pub fn unpause(self: *ClockRef) void {
        self.scripts.app.resumeClock(self.handle);
    }

    pub fn isPaused(self: *ClockRef) bool {
        return self.scripts.app.isClockPaused(self.handle);
    }

    pub fn remove(self: *ClockRef) void {
        self.scripts.app.removeClock(self.handle);
    }
};

pub fn clockKey(handle: clocks_mod.ClockHandle) u64 {
    return @bitCast(handle);
}

/// The value a clock is to the scripts: one clock, one value.
fn clockValue(scripts: *Scripts, handle: clocks_mod.ClockHandle) flux.Vm.Error!flux.Value {
    const key = clockKey(handle);
    if (scripts.clock_values.get(key)) |known| return known;
    const vm = scripts.vm;
    try scripts.clock_values.ensureUnusedCapacity(scripts.app.gpa, 1);
    const ref = try vm.gpa.create(ClockRef);
    ref.* = .{ .scripts = scripts, .handle = handle };
    const made = vm.adoptHandle(ref) catch |err| {
        vm.gpa.destroy(ref);
        return err;
    };
    try vm.hold(made);
    scripts.clock_values.putAssumeCapacityNoClobber(key, made);
    return made;
}
