// SPDX-License-Identifier: BSD-3-Clause

//! Dates and times: a moment (`Instant`), a span (`Duration`), and a
//! calendar's fields in a time zone (`DateTime`) - counted in the proleptic
//! Gregorian calendar, and written as a culture writes them.
//!
//! ```zig
//! const now = app.now();                                   // an Instant
//! const here = now.in(.local);                             // a DateTime, 19:42 in Budapest
//! here.writeStyle(culture, .long, .short, &buf)            // "2026. szeptember 25. 19:42"
//! here.write(culture, "EEEE, MMMM d.", &buf)               // "péntek, szeptember 25."
//! here.addDays(1).startOfDay()                             // tomorrow, at midnight
//! fx.datetime.relative(culture, earlier, now, .local, .wide, &buf)  // "5 perccel ezelőtt"
//! ```
//!
//! **A moment and a calendar's fields are two things.** An `Instant` is one
//! point in time, the same everywhere; a `DateTime` is what a clock and a
//! calendar show for it in one time zone. Adding a day to a `DateTime` keeps
//! the hour on the clock (`addDays`) - over a change to summer time that is
//! 23 or 25 hours; adding 24 hours (`plus`) is exact. The names say which.
//!
//! **A culture writes, it does not count.** The counting is always the
//! Gregorian calendar; the names, the order, twelve hours or twenty-four and
//! the first day of a week come from a `platform.culture.Culture` - the
//! system's own data, see `App.culture`.
//!
//! **Patterns are CLDR's letters**, the ones every locale's data is written
//! in: `y` year, `M` month (`MMMM` its name), `d` day, `E` weekday, `H` and
//! `h` hour, `m` minute, `s` second, `S` its fraction, `a` before or after
//! noon, `z`, `Z`, `X` and `O` the zone, and `'quoted words'`. See `write`.
//!
//! **Scripts have the same**, through `time`: `time.now().format("HH:mm")`,
//! `time.date(2026, 9, 25).addDays(1).formatStyle("long")`, in the game's
//! culture - see `App.culture`.

const std = @import("std");
const testing = std.testing;

const culture_mod = @import("fluxion_platform").culture;
const flux = @import("fluxion_script");
const attr = @import("attr.zig");
const script_mod = @import("script.zig");

const file = @This();

pub const Culture = culture_mod.Culture;
pub const Width = culture_mod.Width;
pub const Style = culture_mod.Style;
pub const Unit = culture_mod.Unit;

const us_per_second: i64 = 1_000_000;
const us_per_minute: i64 = 60 * us_per_second;
const us_per_hour: i64 = 60 * us_per_minute;
const us_per_day: i64 = 24 * us_per_hour;

pub const Weekday = enum(u3) { monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday };

pub const Month = enum(u4) { january = 1, february, march, april, may, june, july, august, september, october, november, december };

// -------------------------------------------------------------------------
// A span of time
// -------------------------------------------------------------------------

/// A span of time, in microseconds; negative is backwards.
pub const Duration = extern struct {
    us: i64 = 0,

    pub const reflect_name = "Duration";
    pub const reflect_fields = .{ .us = .{attr.ReadOnly{}} };
    pub const reflect_methods = .{
        .totalSeconds = .{},
        .totalMinutes = .{},
        .totalHours = .{},
        .totalDays = .{},
        .plus = .{attr.Params{ .names = &.{"other"} }},
        .minus = .{attr.Params{ .names = &.{"other"} }},
        .times = .{attr.Params{ .names = &.{"factor"} }},
        .negated = .{},
        .format = .{ attr.Params{ .names = &.{ "vm", "style" } }, attr.defaults(.{"clock"}) },
    };

    pub fn ofSeconds(seconds: f64) Duration {
        return .{ .us = @intFromFloat(@round(seconds * @as(f64, us_per_second))) };
    }
    pub fn ofMinutes(minutes: f64) Duration {
        return ofSeconds(minutes * 60);
    }
    pub fn ofHours(hours: f64) Duration {
        return ofSeconds(hours * 3600);
    }
    pub fn ofDays(days: f64) Duration {
        return ofSeconds(days * 86400);
    }

    pub fn totalSeconds(self: Duration) f64 {
        return @as(f64, @floatFromInt(self.us)) / us_per_second;
    }
    pub fn totalMinutes(self: Duration) f64 {
        return self.totalSeconds() / 60;
    }
    pub fn totalHours(self: Duration) f64 {
        return self.totalSeconds() / 3600;
    }
    pub fn totalDays(self: Duration) f64 {
        return self.totalSeconds() / 86400;
    }

    pub fn plus(self: Duration, other: Duration) Duration {
        return .{ .us = self.us +| other.us };
    }
    pub fn minus(self: Duration, other: Duration) Duration {
        return .{ .us = self.us -| other.us };
    }
    pub fn times(self: Duration, factor: f64) Duration {
        return .{ .us = @intFromFloat(@round(@as(f64, @floatFromInt(self.us)) * factor)) };
    }
    pub fn negated(self: Duration) Duration {
        return .{ .us = 0 -| self.us };
    }

    /// Days, hours, minutes, seconds and the microseconds left, of the
    /// span's size.
    pub fn parts(self: Duration) Parts {
        var left: u64 = @abs(self.us);
        const days = left / @as(u64, us_per_day);
        left %= @as(u64, us_per_day);
        const hours = left / @as(u64, us_per_hour);
        left %= @as(u64, us_per_hour);
        const minutes = left / @as(u64, us_per_minute);
        left %= @as(u64, us_per_minute);
        return .{
            .negative = self.us < 0,
            .days = days,
            .hours = @intCast(hours),
            .minutes = @intCast(minutes),
            .seconds = @intCast(left / @as(u64, us_per_second)),
            .microseconds = @intCast(left % @as(u64, us_per_second)),
        };
    }

    pub const Parts = struct {
        negative: bool,
        days: u64,
        hours: u8,
        minutes: u8,
        seconds: u8,
        microseconds: u32,
    };

    pub const FormatStyle = enum {
        /// `1:05:03`, or `5:03` under an hour: a clock's.
        clock,
        /// `1 óra, 5 perc`, `1 hour, 5 minutes`.
        wide,
        /// `1 ó, 5 p`, `1 hr, 5 min`.
        abbreviated,
        /// `1ó 5p`, `1h 5m`.
        narrow,
    };

    /// For scripts: `span.format("wide")` - `clock`, `wide`, `abbreviated`
    /// or `narrow`, in the game's culture.
    pub fn format(self: Duration, vm: *flux.Vm, style: []const u8) anyerror![]const u8 {
        const scripts = scriptsOf(vm);
        const how = std.meta.stringToEnum(FormatStyle, style) orelse return error.UnknownStyle;
        return self.write(try scripts.app.culture(), how, &scripts.said);
    }

    /// The span in words the culture writes, or as a clock does.
    pub fn write(self: Duration, culture: *Culture, style: FormatStyle, buf: []u8) []const u8 {
        const p = self.parts();
        if (style == .clock) {
            const hours = p.days * 24 + p.hours;
            const sign: []const u8 = if (p.negative) "-" else "";
            return (if (hours > 0)
                std.fmt.bufPrint(buf, "{s}{d}:{d:0>2}:{d:0>2}", .{ sign, hours, p.minutes, p.seconds })
            else
                std.fmt.bufPrint(buf, "{s}{d}:{d:0>2}", .{ sign, p.minutes, p.seconds })) catch "";
        }
        const width: Width = switch (style) {
            .wide => .wide,
            .abbreviated => .abbreviated,
            else => .narrow,
        };
        var words: [4][48]u8 = undefined;
        var items: [4][]const u8 = undefined;
        var n: usize = 0;
        const amounts = [_]struct { u64, Unit }{ .{ p.days, .day }, .{ p.hours, .hour }, .{ p.minutes, .minute }, .{ p.seconds, .second } };
        for (amounts) |pair| {
            if (pair[0] == 0) continue;
            items[n] = culture.amount(&words[n], @floatFromInt(pair[0]), pair[1], width);
            n += 1;
        }
        if (n == 0) {
            items[0] = culture.amount(&words[0], 0, .second, width);
            n = 1;
        }
        const listed = culture.list(buf[@min(buf.len, 1)..], items[0..n], width);
        if (!p.negative) {
            std.mem.copyForwards(u8, buf[0..listed.len], listed);
            return buf[0..listed.len];
        }
        if (buf.len == 0) return buf;
        buf[0] = '-';
        return buf[0 .. listed.len + 1];
    }
};

// -------------------------------------------------------------------------
// A moment
// -------------------------------------------------------------------------

/// One moment, the same everywhere: microseconds since 1970-01-01 00:00 UTC,
/// some 292 000 years either way.
pub const Instant = extern struct {
    us: i64 = 0,

    pub fn fromUnix(seconds: f64) Instant {
        return .{ .us = @intFromFloat(@round(seconds * @as(f64, us_per_second))) };
    }

    pub fn fromUnixMilliseconds(ms: i64) Instant {
        return .{ .us = ms *| 1000 };
    }

    pub fn unix(self: Instant) f64 {
        return @as(f64, @floatFromInt(self.us)) / us_per_second;
    }

    pub fn unixMilliseconds(self: Instant) i64 {
        return @divFloor(self.us, 1000);
    }

    pub fn plus(self: Instant, d: Duration) Instant {
        return .{ .us = self.us +| d.us };
    }

    /// How long after `earlier` this is.
    pub fn since(self: Instant, earlier: Instant) Duration {
        return .{ .us = self.us -| earlier.us };
    }

    /// What a clock and a calendar show at this moment in `zone`.
    pub fn in(self: Instant, zone: Zone) DateTime {
        const offset = zone.offsetAt(self);
        return DateTime.fromWall(self.us + @as(i64, offset) * us_per_minute, zone, offset);
    }
};

/// Which time zone a `DateTime`'s fields are in.
pub const Zone = extern struct {
    kind: Kind = .utc,
    /// East of UTC, for a fixed zone.
    minutes: i16 = 0,

    pub const Kind = enum(u8) {
        utc,
        /// The system's, summer time and all: see `platform.culture.utcOffset`.
        local,
        /// A fixed offset from UTC: `+02:00`.
        fixed,
    };

    pub const utc: Zone = .{};
    pub const local: Zone = .{ .kind = .local };

    pub fn fixed(minutes: i16) Zone {
        return .{ .kind = .fixed, .minutes = minutes };
    }

    /// Minutes east of UTC at `at`.
    pub fn offsetAt(self: Zone, at: Instant) i16 {
        return switch (self.kind) {
            .utc => 0,
            .fixed => self.minutes,
            .local => @intCast(@divTrunc(culture_mod.utcOffset(at.unixMilliseconds()), 60)),
        };
    }

    /// The offset a wall clock reading `wall` has here. A time a change to
    /// summer time skips is taken as the time after the gap; one a change
    /// back shows twice, as the second.
    fn offsetForWall(self: Zone, wall: i64) i16 {
        if (self.kind != .local) return self.offsetAt(.{});
        const guess = self.offsetAt(.{ .us = wall });
        const first = self.offsetAt(.{ .us = wall - @as(i64, guess) * us_per_minute });
        if (first == guess) return guess;
        const second = self.offsetAt(.{ .us = wall - @as(i64, first) * us_per_minute });
        if (second == first) return first;
        return @min(first, second);
    }
};

// -------------------------------------------------------------------------
// The calendar
// -------------------------------------------------------------------------

/// Days since 1970-01-01 of a date: Howard Hinnant's `days_from_civil`.
pub fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, month) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: i64, month: u8, day: u8 };

/// The date `days` after 1970-01-01: `civil_from_days`.
pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0), .month = month, .day = day };
}

pub fn isLeap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub fn monthLength(year: i64, month: u8) u8 {
    return switch (month) {
        2 => if (isLeap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Monday 1 to Sunday 7 of a day counted from 1970-01-01, a Thursday.
fn weekdayOfDays(days: i64) u3 {
    return @intCast(@mod(days + 3, 7) + 1);
}

// -------------------------------------------------------------------------
// A calendar's fields
// -------------------------------------------------------------------------

/// What a clock and a calendar show in one time zone: its fields, and the
/// offset from UTC they were read at.
pub const DateTime = extern struct {
    year: i32 = 1970,
    microsecond: u32 = 0,
    /// Minutes east of UTC these fields are at.
    offset: i16 = 0,
    month: u8 = 1,
    day: u8 = 1,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    zone: Zone = .{},

    pub const reflect_name = "DateTime";
    pub const reflect_fields = .{
        .year = .{attr.ReadOnly{}},
        .microsecond = .{attr.ReadOnly{}},
        .offset = .{attr.ReadOnly{}},
        .month = .{attr.ReadOnly{}},
        .day = .{attr.ReadOnly{}},
        .hour = .{attr.ReadOnly{}},
        .minute = .{attr.ReadOnly{}},
        .second = .{attr.ReadOnly{}},
        .zone = .{attr.ReadOnly{}},
    };
    pub const reflect_methods = .{
        .format = .{attr.Params{ .names = &.{ "vm", "pattern" } }},
        .formatStyle = .{ attr.Params{ .names = &.{ "vm", "date", "time" } }, attr.defaults(.{ "medium", "short" }) },
        .formatSkeleton = .{attr.Params{ .names = &.{ "vm", "skeleton" } }},
        .iso = .{attr.Params{ .names = &.{"vm"} }},
        .relative = .{attr.Params{ .names = &.{"vm"} }},
        .weekday = .{},
        .weekdayName = .{ attr.Params{ .names = &.{ "vm", "width" } }, attr.defaults(.{"wide"}) },
        .monthName = .{ attr.Params{ .names = &.{ "vm", "width" } }, attr.defaults(.{"wide"}) },
        .dayOfYear = .{},
        .isoWeek = .{},
        .daysInMonth = .{},
        .isLeapYear = .{},
        .addDays = .{attr.Params{ .names = &.{"days"} }},
        .addMonths = .{attr.Params{ .names = &.{"months"} }},
        .addYears = .{attr.Params{ .names = &.{"years"} }},
        .addHours = .{attr.Params{ .names = &.{"hours"} }},
        .addMinutes = .{attr.Params{ .names = &.{"minutes"} }},
        .addSeconds = .{attr.Params{ .names = &.{"seconds"} }},
        .plus = .{attr.Params{ .names = &.{"span"} }},
        .since = .{attr.Params{ .names = &.{"earlier"} }},
        .compare = .{attr.Params{ .names = &.{"other"} }},
        .startOfDay = .{},
        .startOfWeek = .{attr.Params{ .names = &.{"vm"} }},
        .startOfMonth = .{},
        .startOfYear = .{},
        .toUtc = .{},
        .toLocal = .{},
        .toOffset = .{attr.Params{ .names = &.{"minutes"} }},
        .unix = .{},
    };

    /// The date and time given in `zone`. What does not fit carries over:
    /// month 13 is January of the next year, day 0 the last of the month
    /// before, minute 90 an hour and a half.
    pub fn at(zone: Zone, year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64) DateTime {
        const months = year * 12 + (month - 1);
        const y = @divFloor(months, 12);
        const m: u8 = @intCast(@mod(months, 12) + 1);
        const day_count = daysFromCivil(y, m, 1) + (day - 1);
        return atWall(zone, day_count * us_per_day + hour * us_per_hour + minute * us_per_minute + second * us_per_second);
    }

    /// The fields a wall clock reading `reading` shows in `zone`.
    fn atWall(zone: Zone, reading: i64) DateTime {
        const offset = zone.offsetForWall(reading);
        const moment: Instant = .{ .us = reading - @as(i64, offset) * us_per_minute };
        return moment.in(zone);
    }

    fn fromWall(reading: i64, zone: Zone, offset: i16) DateTime {
        const day_count = @divFloor(reading, us_per_day);
        var left = reading - day_count * us_per_day;
        const date = civilFromDays(day_count);
        const hour: u8 = @intCast(@divFloor(left, us_per_hour));
        left -= @as(i64, hour) * us_per_hour;
        const minute: u8 = @intCast(@divFloor(left, us_per_minute));
        left -= @as(i64, minute) * us_per_minute;
        const second: u8 = @intCast(@divFloor(left, us_per_second));
        return .{
            .year = @intCast(std.math.clamp(date.year, std.math.minInt(i32), std.math.maxInt(i32))),
            .month = date.month,
            .day = date.day,
            .hour = hour,
            .minute = minute,
            .second = second,
            .microsecond = @intCast(left - @as(i64, second) * us_per_second),
            .offset = offset,
            .zone = zone,
        };
    }

    /// Microseconds since 1970 on its face, whatever its zone.
    pub fn wallMicroseconds(self: DateTime) i64 {
        return self.wall();
    }

    /// What a face reading `reading` - microseconds since 1970 - shows, in
    /// UTC, whose fields are the face's.
    pub fn fromWallMicroseconds(reading: i64) DateTime {
        return fromWall(reading, .utc, 0);
    }

    /// Microseconds since 1970 on the wall clock.
    fn wall(self: DateTime) i64 {
        return self.days() * us_per_day + @as(i64, self.hour) * us_per_hour + @as(i64, self.minute) * us_per_minute +
            @as(i64, self.second) * us_per_second + self.microsecond;
    }

    fn days(self: DateTime) i64 {
        return daysFromCivil(self.year, self.month, self.day);
    }

    pub fn toInstant(self: DateTime) Instant {
        return .{ .us = self.wall() - @as(i64, self.offset) * us_per_minute };
    }

    /// The same moment in another zone.
    pub fn toZone(self: DateTime, zone: Zone) DateTime {
        return self.toInstant().in(zone);
    }

    pub fn weekday(self: DateTime) Weekday {
        return @enumFromInt(weekdayOfDays(self.days()));
    }

    /// 1 for the first of January.
    pub fn dayOfYear(self: DateTime) u16 {
        return @intCast(self.days() - daysFromCivil(self.year, 1, 1) + 1);
    }

    pub fn daysInMonth(self: DateTime) u8 {
        return monthLength(self.year, self.month);
    }

    pub fn isLeapYear(self: DateTime) bool {
        return isLeap(self.year);
    }

    /// ISO 8601's week: weeks from Monday, the first the one with the
    /// year's first Thursday. The first days of January can be in the last
    /// week of the year before: see `isoWeekYear`.
    pub fn isoWeek(self: DateTime) u8 {
        return weekOf(self.days(), 1, 4).week;
    }

    pub fn isoWeekYear(self: DateTime) i64 {
        return weekOf(self.days(), 1, 4).year;
    }

    /// A day later, at the same time on the clock - over a change to summer
    /// time that is not 24 hours.
    pub fn addDays(self: DateTime, n: i64) DateTime {
        return atWall(self.zone, self.wall() + n * us_per_day);
    }

    /// Months later, the day kept where the month has it: the 31st of
    /// January and a month is the last of February.
    pub fn addMonths(self: DateTime, n: i64) DateTime {
        const months = @as(i64, self.year) * 12 + (self.month - 1) + n;
        const y = @divFloor(months, 12);
        const m: u8 = @intCast(@mod(months, 12) + 1);
        const d = @min(self.day, monthLength(y, m));
        const time_of_day = self.wall() - self.days() * us_per_day;
        return atWall(self.zone, daysFromCivil(y, m, d) * us_per_day + time_of_day);
    }

    pub fn addYears(self: DateTime, n: i64) DateTime {
        return self.addMonths(n * 12);
    }

    /// Exactly this much later: 24 hours are 24 hours, whatever the clock
    /// shows after them.
    pub fn plus(self: DateTime, d: Duration) DateTime {
        return self.toInstant().plus(d).in(self.zone);
    }

    pub fn addHours(self: DateTime, n: f64) DateTime {
        return self.plus(.ofHours(n));
    }
    pub fn addMinutes(self: DateTime, n: f64) DateTime {
        return self.plus(.ofMinutes(n));
    }
    pub fn addSeconds(self: DateTime, n: f64) DateTime {
        return self.plus(.ofSeconds(n));
    }

    /// How long after `earlier` this is.
    pub fn since(self: DateTime, earlier: DateTime) Duration {
        return self.toInstant().since(earlier.toInstant());
    }

    /// Before, the same moment, or after: -1, 0 or 1.
    pub fn compare(self: DateTime, other: DateTime) i32 {
        const a = self.toInstant().us;
        const b = other.toInstant().us;
        return if (a < b) -1 else if (a > b) 1 else 0;
    }

    pub fn startOfDay(self: DateTime) DateTime {
        return atWall(self.zone, self.days() * us_per_day);
    }

    /// The start of its week, which starts on `first` - 1 for Monday to 7
    /// for Sunday: a culture's `first_weekday`.
    pub fn startOfWeekFrom(self: DateTime, first: u3) DateTime {
        const back = @mod(@as(i64, @intFromEnum(self.weekday())) - first, 7);
        return atWall(self.zone, (self.days() - back) * us_per_day);
    }

    pub fn startOfMonth(self: DateTime) DateTime {
        return atWall(self.zone, daysFromCivil(self.year, self.month, 1) * us_per_day);
    }

    pub fn startOfYear(self: DateTime) DateTime {
        return atWall(self.zone, daysFromCivil(self.year, 1, 1) * us_per_day);
    }

    // ---------------------------------------------------------------------
    // ISO 8601
    // ---------------------------------------------------------------------

    /// `2026-09-25T19:42:05+02:00`: RFC 3339, with `Z` for UTC and the
    /// fraction of a second when there is one - milliseconds where they are
    /// enough.
    pub fn writeIso(self: DateTime, buf: []u8) []const u8 {
        var out: Out = .{ .buf = buf };
        if (self.year < 0 or self.year > 9999) {
            out.put(if (self.year < 0) "-" else "+");
            out.number(@abs(self.year), 6);
        } else out.number(@intCast(self.year), 4);
        out.put("-");
        out.number(self.month, 2);
        out.put("-");
        out.number(self.day, 2);
        out.put("T");
        out.number(self.hour, 2);
        out.put(":");
        out.number(self.minute, 2);
        out.put(":");
        out.number(self.second, 2);
        if (self.microsecond != 0) {
            out.put(".");
            if (self.microsecond % 1000 == 0) out.number(self.microsecond / 1000, 3) else out.number(self.microsecond, 6);
        }
        if (self.zone.kind == .utc) out.put("Z") else out.offset(self.offset, true, false);
        return out.written();
    }

    pub const ParseError = error{InvalidDateTime};

    /// A date and time as ISO 8601 writes it: `2026-09-25`,
    /// `2026-09-25T19:42`, `2026-09-25 19:42:05.25+02:00`, `...Z`. One with
    /// an offset is in that fixed zone, `Z` in UTC, and one without in
    /// `zone`.
    pub fn parseIso(text: []const u8, zone: Zone) ParseError!DateTime {
        var p: Reader = .{ .text = std.mem.trim(u8, text, " \t\r\n") };
        const negative = p.take('-');
        if (!negative) _ = p.take('+');
        const year_digits = p.at;
        const year = p.digits(4, 6) orelse return error.InvalidDateTime;
        if (p.at - year_digits > 4 and !negative and year < 10000) return error.InvalidDateTime;
        if (!p.take('-')) return error.InvalidDateTime;
        const month = p.digits(2, 2) orelse return error.InvalidDateTime;
        if (!p.take('-')) return error.InvalidDateTime;
        const day = p.digits(2, 2) orelse return error.InvalidDateTime;
        const y: i64 = if (negative) -year else year;
        if (month < 1 or month > 12 or day < 1 or day > monthLength(y, @intCast(month))) return error.InvalidDateTime;
        var hour: i64 = 0;
        var minute: i64 = 0;
        var second: i64 = 0;
        var micro: i64 = 0;
        if (p.take('T') or p.take('t') or p.take(' ')) {
            hour = p.digits(2, 2) orelse return error.InvalidDateTime;
            if (!p.take(':')) return error.InvalidDateTime;
            minute = p.digits(2, 2) orelse return error.InvalidDateTime;
            if (p.take(':')) {
                second = p.digits(2, 2) orelse return error.InvalidDateTime;
                if (p.take('.') or p.take(',')) {
                    const start = p.at;
                    const fraction = p.digits(1, 9) orelse return error.InvalidDateTime;
                    var scale = p.at - start;
                    micro = fraction;
                    while (scale < 6) : (scale += 1) micro *= 10;
                    while (scale > 6) : (scale -= 1) micro = @divFloor(micro, 10);
                }
            }
            // A leap second is the last of its minute here.
            if (hour > 23 or minute > 59 or second > 60) return error.InvalidDateTime;
            second = @min(second, 59);
        }
        const reading = daysFromCivil(y, @intCast(month), @intCast(day)) * us_per_day + hour * us_per_hour + minute * us_per_minute + second * us_per_second + micro;
        if (p.done()) return atWall(zone, reading);
        if (p.take('Z') or p.take('z')) {
            if (!p.done()) return error.InvalidDateTime;
            return (Instant{ .us = reading }).in(.utc);
        }
        const east = p.take('+');
        if (!east and !p.take('-')) return error.InvalidDateTime;
        const hours = p.digits(2, 2) orelse return error.InvalidDateTime;
        _ = p.take(':');
        const minutes = p.digits(2, 2) orelse 0;
        if (!p.done() or hours > 23 or minutes > 59) return error.InvalidDateTime;
        const offset: i16 = @intCast((hours * 60 + minutes) * @as(i64, if (east) 1 else -1));
        return (Instant{ .us = reading - @as(i64, offset) * us_per_minute }).in(.fixed(offset));
    }

    // ---------------------------------------------------------------------
    // As a culture writes it
    // ---------------------------------------------------------------------

    /// In one of the culture's own styles; null leaves the date or the time
    /// out.
    pub fn writeStyle(self: DateTime, culture: *Culture, date: ?Style, time: ?Style, buf: []u8) []const u8 {
        const pattern = if (date) |d|
            (if (time) |t| culture.dateTimePattern(d, t) else culture.datePattern(d))
        else if (time) |t| culture.timePattern(t) else return buf[0..0];
        return self.write(culture, pattern, buf);
    }

    /// With the culture's best pattern for a skeleton - the fields wanted,
    /// in any order: `MMMMd` is `szeptember 25.`, `September 25`; `yMMM`,
    /// `jm` (the culture's own hour and minutes).
    pub fn writeSkeleton(self: DateTime, culture: *Culture, skeleton: []const u8, buf: []u8) []const u8 {
        var pattern: [96]u8 = undefined;
        const best = culture.bestPattern(&pattern, skeleton);
        return self.write(culture, best, buf);
    }

    /// With a CLDR pattern, the culture's names in it. The letters, a run of
    /// each saying how much:
    ///
    /// | | |
    /// | --- | --- |
    /// | `G` | era: `AD`, `Anno Domini` (4) |
    /// | `y`, `u`, `Y` | year: `y` 2026, `yy` 26; `u` counts years before 1 as 0, -1; `Y` the year of `w`'s week |
    /// | `Q`, `q` | quarter: 3, `Q3` (3), `3rd quarter` (4) |
    /// | `M`, `L` | month: 9, 09, `Sep`, `September`, `S`; `L` alone, not in a date |
    /// | `w`, `W` | week of the year, as the culture counts them; of the month |
    /// | `d`, `D`, `F` | day of the month, of the year; which of its weekday in the month |
    /// | `E`, `e`, `c` | weekday: `Fri`, `Friday` (4), `F` (5); `e` and `c` as a number from the culture's first day |
    /// | `a`, `b`, `B` | before or after noon: `AM`, `du.` |
    /// | `h`, `H`, `K`, `k` | hour: 1-12, 0-23, 0-11, 1-24 |
    /// | `m`, `s`, `S` | minute; second; its fraction, as many digits as `S`s |
    /// | `z`, `v` | the zone's name: `CEST`, `Central European Summer Time` (4) |
    /// | `O` | `GMT+2`, `GMT+02:00` (4) |
    /// | `Z` | `+0200`, `GMT+02:00` (4), `+02:00` (5) |
    /// | `X`, `x` | ISO: `+02`, `+0200`, `+02:00` (3); `X` writes `Z` for UTC |
    /// | `V` | the zone's id: `Europe/Budapest` |
    /// | `'...'` | words as they are; `''` is a quote |
    pub fn write(self: DateTime, culture: *Culture, pattern: []const u8, buf: []u8) []const u8 {
        var out: Out = .{ .buf = buf };
        var i: usize = 0;
        while (i < pattern.len) {
            const c = pattern[i];
            if (c == '\'') {
                i += 1;
                if (i < pattern.len and pattern[i] == '\'') {
                    out.put("'");
                    i += 1;
                    continue;
                }
                while (i < pattern.len) {
                    if (pattern[i] == '\'') {
                        if (i + 1 < pattern.len and pattern[i + 1] == '\'') {
                            out.put("'");
                            i += 2;
                            continue;
                        }
                        i += 1;
                        break;
                    }
                    out.put(pattern[i .. i + 1]);
                    i += 1;
                }
                continue;
            }
            if (!std.ascii.isAlphabetic(c)) {
                out.put(pattern[i .. i + 1]);
                i += 1;
                continue;
            }
            var n: usize = 1;
            while (i + n < pattern.len and pattern[i + n] == c) n += 1;
            self.field(culture, &out, c, n);
            i += n;
        }
        return out.written();
    }

    fn field(self: DateTime, culture: *Culture, out: *Out, letter: u8, n: usize) void {
        const width: Width = if (n == 4) .wide else if (n == 5) .narrow else .abbreviated;
        switch (letter) {
            'G' => out.put(culture.eras[if (n == 4) 0 else 1][if (self.year > 0) 1 else 0]),
            'y' => {
                const era_year: u64 = if (self.year > 0) @intCast(self.year) else @intCast(1 - @as(i64, self.year));
                if (n == 2) out.number(era_year % 100, 2) else out.number(era_year, n);
            },
            'u' => {
                if (self.year < 0) out.put("-");
                out.number(@abs(self.year), n);
            },
            'Y' => {
                const week = weekOf(self.days(), culture.first_weekday, culture.minimal_days);
                const y: u64 = @abs(week.year);
                if (n == 2) out.number(y % 100, 2) else out.number(y, n);
            },
            'Q', 'q' => {
                const quarter = (self.month - 1) / 3;
                if (n <= 2) out.number(quarter + 1, n) else out.put(culture.quarters[if (n == 4) 0 else 1][quarter]);
            },
            'M', 'L' => {
                const context: culture_mod.Context = if (letter == 'M') .format else .standalone;
                if (n <= 2) out.number(self.month, n) else out.put(culture.monthName(@intCast(self.month), width, context));
            },
            'w' => out.number(weekOf(self.days(), culture.first_weekday, culture.minimal_days).week, n),
            'W' => {
                const first = daysFromCivil(self.year, self.month, 1);
                const lead = @mod(@as(i64, weekdayOfDays(first)) - culture.first_weekday, 7);
                out.number(@intCast(@divFloor(self.day - 1 + lead, 7) + 1), n);
            },
            'd' => out.number(self.day, n),
            'D' => out.number(self.dayOfYear(), n),
            'F' => out.number((self.day - 1) / 7 + 1, n),
            'E' => out.put(culture.weekdayName(@intFromEnum(self.weekday()), if (n == 4) .wide else if (n == 5) .narrow else .abbreviated, .format)),
            'e', 'c' => {
                const day = @intFromEnum(self.weekday());
                if (n <= 2) {
                    out.number(@intCast(@mod(@as(i64, day) - culture.first_weekday, 7) + 1), n);
                } else out.put(culture.weekdayName(day, width, if (letter == 'e') .format else .standalone));
            },
            'a', 'b', 'B' => out.put(culture.day_periods[if (self.hour < 12) 0 else 1]),
            'h' => out.number(if (self.hour % 12 == 0) 12 else self.hour % 12, n),
            'H' => out.number(self.hour, n),
            'K' => out.number(self.hour % 12, n),
            'k' => out.number(if (self.hour == 0) 24 else self.hour, n),
            'm' => out.number(self.minute, n),
            's' => out.number(self.second, n),
            'S' => {
                var digits: [9]u8 = undefined;
                _ = std.fmt.bufPrint(&digits, "{d:0>6}000", .{self.microsecond}) catch {};
                out.put(digits[0..@min(n, 9)]);
            },
            'A' => out.number(@intCast(@divFloor(self.wall() - self.days() * us_per_day, 1000)), n),
            'z', 'v' => self.zoneName(culture, out, n >= 4),
            'O' => out.gmt(self.offset, n >= 4),
            'Z' => switch (n) {
                1, 2, 3 => out.offset(self.offset, false, false),
                4 => out.gmt(self.offset, true),
                else => if (self.offset == 0) out.put("Z") else out.offset(self.offset, true, false),
            },
            'X', 'x' => {
                if (letter == 'X' and self.offset == 0) return out.put("Z");
                switch (n) {
                    1 => out.offset(self.offset, false, true),
                    2, 4 => out.offset(self.offset, false, false),
                    else => out.offset(self.offset, true, false),
                }
            },
            'V' => switch (self.zone.kind) {
                .utc => out.put("UTC"),
                .local => {
                    var name: [64]u8 = undefined;
                    const found = culture_mod.timeZoneName(&name);
                    if (found.len > 0) out.put(found) else out.gmt(self.offset, true);
                },
                .fixed => out.gmt(self.offset, true),
            },
            else => {
                var run: [8]u8 = undefined;
                const shown = @min(n, run.len);
                @memset(run[0..shown], letter);
                out.put(run[0..shown]);
            },
        }
    }

    fn zoneName(self: DateTime, culture: *Culture, out: *Out, long: bool) void {
        switch (self.zone.kind) {
            .utc => out.put(if (long) "Coordinated Universal Time" else "UTC"),
            .fixed => out.gmt(self.offset, long),
            .local => {
                var name: [96]u8 = undefined;
                const found = culture.zoneName(&name, self.toInstant().unixMilliseconds(), long);
                if (found.len > 0) out.put(found) else out.gmt(self.offset, long);
            },
        }
    }

    /// How long ago or from `now` this is, in the words of the culture:
    /// `5 perccel ezelőtt`, `tegnap`, `in 3 hours`. See `relative`.
    pub fn writeRelative(self: DateTime, culture: *Culture, now: DateTime, width: Width, buf: []u8) []const u8 {
        return file.relative(culture, self.toInstant(), now.toInstant(), now.zone, width, buf);
    }

    // ---------------------------------------------------------------------
    // For scripts, in the game's culture
    // ---------------------------------------------------------------------

    /// With a CLDR pattern: `format("yyyy. MMMM d.")`. See `write`.
    pub fn format(self: DateTime, vm: *flux.Vm, pattern: []const u8) anyerror![]const u8 {
        const scripts = scriptsOf(vm);
        return self.write(try scripts.app.culture(), pattern, &scripts.said);
    }

    /// In the culture's styles - `full`, `long`, `medium`, `short` or
    /// `none` - for the date and the time.
    pub fn formatStyle(self: DateTime, vm: *flux.Vm, date: []const u8, time: []const u8) anyerror![]const u8 {
        const scripts = scriptsOf(vm);
        return self.writeStyle(try scripts.app.culture(), try styleNamed(date), try styleNamed(time), &scripts.said);
    }

    /// With the culture's pattern for the fields a skeleton names: `MMMMd`.
    pub fn formatSkeleton(self: DateTime, vm: *flux.Vm, skeleton: []const u8) anyerror![]const u8 {
        const scripts = scriptsOf(vm);
        return self.writeSkeleton(try scripts.app.culture(), skeleton, &scripts.said);
    }

    /// `2026-09-25T19:42:05+02:00`.
    pub fn iso(self: DateTime, vm: *flux.Vm) []const u8 {
        return self.writeIso(&scriptsOf(vm).said);
    }

    /// How long ago or from now: `5 perccel ezelőtt`, `tomorrow`.
    pub fn relative(self: DateTime, vm: *flux.Vm) anyerror![]const u8 {
        const scripts = scriptsOf(vm);
        const now = scripts.app.now().in(self.zone);
        return self.writeRelative(try scripts.app.culture(), now, .wide, &scripts.said);
    }

    /// Its weekday's name: `wide`, `abbreviated` or `narrow`.
    pub fn weekdayName(self: DateTime, vm: *flux.Vm, width: []const u8) anyerror![]const u8 {
        const culture = try scriptsOf(vm).app.culture();
        return culture.weekdayName(@intFromEnum(self.weekday()), try widthNamed(width), .standalone);
    }

    /// Its month's name, as it stands on its own: `szeptember`, `wrzesień`.
    pub fn monthName(self: DateTime, vm: *flux.Vm, width: []const u8) anyerror![]const u8 {
        const culture = try scriptsOf(vm).app.culture();
        return culture.monthName(@intCast(self.month), try widthNamed(width), .standalone);
    }

    /// The start of its week, on the culture's first day of one.
    pub fn startOfWeek(self: DateTime, vm: *flux.Vm) anyerror!DateTime {
        const culture = try scriptsOf(vm).app.culture();
        return self.startOfWeekFrom(culture.first_weekday);
    }

    pub fn toUtc(self: DateTime) DateTime {
        return self.toZone(.utc);
    }

    pub fn toLocal(self: DateTime) DateTime {
        return self.toZone(.local);
    }

    /// At a fixed offset, minutes east of UTC.
    pub fn toOffset(self: DateTime, minutes: i64) DateTime {
        return self.toZone(.fixed(@intCast(std.math.clamp(minutes, -24 * 60, 24 * 60))));
    }

    /// Seconds since 1970-01-01 00:00 UTC.
    pub fn unix(self: DateTime) f64 {
        return self.toInstant().unix();
    }
};

/// The week `days` falls in, weeks starting on `first` (1 Monday to 7
/// Sunday) and the first week of a year being the first with at least
/// `minimal` of its days in it - ISO's is Monday and 4.
fn weekOf(days: i64, first: u3, minimal: u3) struct { year: i64, week: u8 } {
    const year = civilFromDays(days).year;
    var candidate = year + 1;
    while (candidate >= year - 1) : (candidate -= 1) {
        const start = firstWeekStart(candidate, first, minimal);
        if (days >= start) return .{ .year = candidate, .week = @intCast(@divFloor(days - start, 7) + 1) };
    }
    return .{ .year = year, .week = 1 };
}

fn firstWeekStart(year: i64, first: u3, minimal: u3) i64 {
    const jan1 = daysFromCivil(year, 1, 1);
    const lead = @mod(@as(i64, weekdayOfDays(jan1)) - first, 7);
    const start = jan1 - lead;
    return if (7 - lead >= minimal) start else start + 7;
}

// -------------------------------------------------------------------------
// How long ago
// -------------------------------------------------------------------------

/// How long before or after `now` `then` is, in the culture's words:
/// seconds under 45 of them, minutes under 45, hours within the day - or
/// within six, over midnight - then days by the calendar in `zone` (`tegnap`,
/// `yesterday`), weeks under four, months under twelve, and years.
pub fn relative(culture: *Culture, then: Instant, now: Instant, zone: Zone, width: Width, buf: []u8) []const u8 {
    const apart = then.since(now).totalSeconds();
    const size = @abs(apart);
    if (size < 45) return culture.relative(buf, @round(apart), .second, width, false);
    if (size < 45 * 60) return culture.relative(buf, @round(apart / 60), .minute, width, false);
    const a = then.in(zone);
    const b = now.in(zone);
    const day_apart = a.days() - b.days();
    if (size < 22 * 3600 and (day_apart == 0 or size < 6 * 3600)) return culture.relative(buf, @round(apart / 3600), .hour, width, false);
    if (@abs(day_apart) < 7) return culture.relative(buf, @floatFromInt(day_apart), .day, width, false);
    if (@abs(day_apart) < 28) return culture.relative(buf, @floatFromInt(@divTrunc(day_apart, 7)), .week, width, false);
    const month_apart = (@as(i64, a.year) * 12 + a.month) - (@as(i64, b.year) * 12 + b.month);
    if (@abs(month_apart) < 12) return culture.relative(buf, @floatFromInt(if (month_apart == 0) std.math.sign(day_apart) else month_apart), .month, width, false);
    return culture.relative(buf, @floatFromInt(@divTrunc(month_apart, 12)), .year, width, false);
}

fn scriptsOf(vm: *flux.Vm) *script_mod.Scripts {
    return @ptrCast(@alignCast(vm.host.?));
}

fn styleNamed(name: []const u8) error{UnknownStyle}!?Style {
    if (std.mem.eql(u8, name, "none") or name.len == 0) return null;
    return std.meta.stringToEnum(Style, name) orelse error.UnknownStyle;
}

fn widthNamed(name: []const u8) error{UnknownWidth}!Width {
    return std.meta.stringToEnum(Width, name) orelse error.UnknownWidth;
}

// -------------------------------------------------------------------------
// Writing
// -------------------------------------------------------------------------

/// A buffer written into from the front, what does not fit left out.
const Out = struct {
    buf: []u8,
    len: usize = 0,

    fn put(self: *Out, text: []const u8) void {
        const n = @min(text.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], text[0..n]);
        self.len += n;
    }

    /// At least `digits` of them, noughts in front.
    fn number(self: *Out, value: u64, digits: usize) void {
        var text: [24]u8 = undefined;
        const plain = std.fmt.bufPrint(&text, "{d}", .{value}) catch return;
        var pad = digits -| plain.len;
        while (pad > 0) : (pad -= 1) self.put("0");
        self.put(plain);
    }

    /// `+02:00` or `+0200`; `short` leaves out nought minutes: `+02`.
    fn offset(self: *Out, minutes: i16, colon: bool, short: bool) void {
        self.put(if (minutes < 0) "-" else "+");
        const size: u64 = @abs(minutes);
        self.number(size / 60, 2);
        if (short and size % 60 == 0) return;
        if (colon) self.put(":");
        self.number(size % 60, 2);
    }

    /// `GMT+2`, `GMT+5:45`; long, `GMT+02:00`; `GMT` for nought.
    fn gmt(self: *Out, minutes: i16, long: bool) void {
        self.put("GMT");
        if (minutes == 0) return;
        if (long) return self.offset(minutes, true, false);
        self.put(if (minutes < 0) "-" else "+");
        const size: u64 = @abs(minutes);
        self.number(size / 60, 1);
        if (size % 60 != 0) {
            self.put(":");
            self.number(size % 60, 2);
        }
    }

    fn written(self: *const Out) []const u8 {
        return self.buf[0..self.len];
    }
};

const Reader = struct {
    text: []const u8,
    at: usize = 0,

    fn take(self: *Reader, c: u8) bool {
        if (self.at < self.text.len and self.text[self.at] == c) {
            self.at += 1;
            return true;
        }
        return false;
    }

    fn digits(self: *Reader, least: usize, most: usize) ?i64 {
        var value: i64 = 0;
        var n: usize = 0;
        while (n < most and self.at < self.text.len and std.ascii.isDigit(self.text[self.at])) : (n += 1) {
            value = value * 10 + (self.text[self.at] - '0');
            self.at += 1;
        }
        return if (n >= least) value else null;
    }

    fn done(self: *const Reader) bool {
        return self.at == self.text.len;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a date and its day number go back and forth over ten thousand years" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 11016), daysFromCivil(2000, 2, 29));
    var days: i64 = -3_700_000;
    while (days < 3_700_000) : (days += 997) {
        const date = civilFromDays(days);
        try testing.expectEqual(days, daysFromCivil(date.year, date.month, date.day));
    }
    try testing.expectEqual(Weekday.thursday, (DateTime{}).weekday());
    try testing.expectEqual(Weekday.tuesday, DateTime.at(.utc, 2000, 2, 29, 0, 0, 0).weekday());
    try testing.expect(isLeap(2000) and !isLeap(1900) and isLeap(2024));
}

test "what does not fit carries over, a month is kept to its days, and a week starts where it is told" {
    const d = DateTime.at(.utc, 2026, 13, 32, 25, 61, 0);
    try testing.expectEqual(@as(i32, 2027), d.year);
    try testing.expectEqual(@as(u8, 2), d.month);
    try testing.expectEqual(@as(u8, 2), d.day);
    try testing.expectEqual(@as(u8, 2), d.hour);
    try testing.expectEqual(@as(u8, 1), d.minute);

    const jan31 = DateTime.at(.utc, 2024, 1, 31, 10, 0, 0);
    try testing.expectEqual(@as(u8, 29), jan31.addMonths(1).day);
    try testing.expectEqual(@as(u8, 28), jan31.addYears(1).addMonths(1).day);
    try testing.expectEqual(@as(u8, 10), jan31.addMonths(1).hour);

    const friday = DateTime.at(.utc, 2026, 9, 25, 19, 42, 5);
    try testing.expectEqual(@as(u8, 21), friday.startOfWeekFrom(1).day);
    try testing.expectEqual(@as(u8, 20), friday.startOfWeekFrom(7).day);
    try testing.expectEqual(@as(u8, 0), friday.startOfDay().hour);
    try testing.expectEqual(@as(u16, 268), friday.dayOfYear());
}

test "ISO weeks at the edges of the year" {
    try testing.expectEqual(@as(u8, 53), DateTime.at(.utc, 2020, 12, 31, 0, 0, 0).isoWeek());
    try testing.expectEqual(@as(u8, 53), DateTime.at(.utc, 2021, 1, 3, 0, 0, 0).isoWeek());
    try testing.expectEqual(@as(i64, 2020), DateTime.at(.utc, 2021, 1, 3, 0, 0, 0).isoWeekYear());
    try testing.expectEqual(@as(u8, 1), DateTime.at(.utc, 2021, 1, 4, 0, 0, 0).isoWeek());
    try testing.expectEqual(@as(u8, 1), DateTime.at(.utc, 2024, 12, 30, 0, 0, 0).isoWeek());
    try testing.expectEqual(@as(i64, 2025), DateTime.at(.utc, 2024, 12, 30, 0, 0, 0).isoWeekYear());
}

test "ISO 8601 written and read back, with offsets, fractions and UTC" {
    var buf: [64]u8 = undefined;
    const d = DateTime.at(.fixed(120), 2026, 9, 25, 19, 42, 5);
    try testing.expectEqualStrings("2026-09-25T19:42:05+02:00", d.writeIso(&buf));
    try testing.expectEqualStrings("2026-09-25T17:42:05Z", d.toZone(.utc).writeIso(&buf));
    const read = try DateTime.parseIso("2026-09-25T19:42:05.25+02:00", .utc);
    try testing.expectEqual(@as(i16, 120), read.offset);
    try testing.expectEqual(@as(u32, 250_000), read.microsecond);
    try testing.expectEqualStrings("2026-09-25T19:42:05.250+02:00", read.writeIso(&buf));
    const z = try DateTime.parseIso("2026-09-25 17:42Z", .local);
    try testing.expectEqual(Zone.Kind.utc, z.zone.kind);
    try testing.expectEqual(d.toInstant().us - 5 * us_per_second, z.toInstant().us);
    const plain = try DateTime.parseIso("2026-09-25", .fixed(-300));
    try testing.expectEqual(@as(i16, -300), plain.offset);
    try testing.expectEqualStrings("2026-09-25T00:00:00-05:00", plain.writeIso(&buf));
    for ([_][]const u8{ "2026-02-30", "2026-9-25", "2026-09-25T24:00", "2026-09-25T10:00+2", "yesterday", "2026-09-25T10:00:00Zed" }) |bad| {
        try testing.expectError(error.InvalidDateTime, DateTime.parseIso(bad, .utc));
    }
}

test "a day on the clock and 24 hours are the same where the zone does not change" {
    const d = DateTime.at(.fixed(60), 2026, 3, 28, 12, 0, 0);
    try testing.expectEqual(d.addDays(1).toInstant().us, d.plus(.ofDays(1)).toInstant().us);
    try testing.expectEqual(@as(f64, 24), d.addDays(1).since(d).totalHours());
    try testing.expectEqual(@as(i32, -1), d.compare(d.addSeconds(1)));
}

test "the system's zone gives each moment the offset it had then" {
    // Wherever the machine is, a moment and its fields in the local zone
    // agree, and a wall time read back is the same wall time.
    const moment = Instant.fromUnix(1790358125);
    const here = moment.in(.local);
    try testing.expectEqual(moment.us, here.toInstant().us);
    const again = DateTime.at(.local, here.year, here.month, here.day, here.hour, here.minute, here.second);
    try testing.expectEqual(here.hour, again.hour);
    try testing.expectEqual(moment.us, again.toInstant().us);
}

test "patterns in the culture's words: English, whatever the system" {
    const english = try Culture.openEnglish(testing.allocator);
    defer english.close();
    var buf: [128]u8 = undefined;
    const d = DateTime.at(.fixed(120), 2026, 9, 25, 19, 42, 5).plus(.ofSeconds(0.25));
    try testing.expectEqualStrings("Friday, September 25, 2026", d.writeStyle(english, .full, null, &buf));
    try testing.expectEqualStrings("9/25/26, 7:42 PM", d.writeStyle(english, .short, .short, &buf));
    try testing.expectEqualStrings("September 25, 2026 at 7:42:05 PM", d.writeStyle(english, .long, .medium, &buf));
    try testing.expectEqualStrings("2026-09-25 19:42:05.250 +0200", d.write(english, "yyyy-MM-dd HH:mm:ss.SSS Z", &buf));
    try testing.expectEqualStrings("Q3 Sep Fri 'x' 268 GMT+2 +02:00", d.write(english, "QQQ LLL EEE '''x''' D O XXX", &buf));
    try testing.expectEqualStrings("12 AM, 24", DateTime.at(.utc, 2026, 1, 1, 0, 0, 0).write(english, "h a, k", &buf));
    try testing.expectEqualStrings("0001 BC 0000", DateTime.at(.utc, 0, 6, 1, 0, 0, 0).write(english, "yyyy G uuuu", &buf));
}

test "how long ago, by the clock and by the calendar" {
    const english = try Culture.openEnglish(testing.allocator);
    defer english.close();
    var buf: [64]u8 = undefined;
    const now = DateTime.at(.utc, 2026, 9, 25, 19, 42, 0);
    const Case = struct { DateTime, []const u8 };
    for ([_]Case{
        .{ now.addSeconds(-10), "10 seconds ago" },
        .{ now, "now" },
        .{ now.addMinutes(-5), "5 minutes ago" },
        .{ now.addHours(3), "in 3 hours" },
        .{ now.addDays(-1), "yesterday" },
        .{ now.addDays(2), "in 2 days" },
        .{ now.addDays(-14), "2 weeks ago" },
        .{ now.addMonths(-3), "3 months ago" },
        .{ now.addYears(2), "in 2 years" },
    }) |case| {
        try testing.expectEqualStrings(case[1], case[0].writeRelative(english, now, .wide, &buf));
    }
}

test "a span as a clock and in words" {
    const english = try Culture.openEnglish(testing.allocator);
    defer english.close();
    var buf: [64]u8 = undefined;
    const d = Duration.ofSeconds(3903);
    try testing.expectEqualStrings("1:05:03", d.write(english, .clock, &buf));
    try testing.expectEqualStrings("5:03", Duration.ofSeconds(303).write(english, .clock, &buf));
    try testing.expectEqualStrings("-5:03", Duration.ofSeconds(-303).write(english, .clock, &buf));
    try testing.expectEqualStrings("1 hour, 5 minutes, 3 seconds", d.write(english, .wide, &buf));
    try testing.expectEqualStrings("0 seconds", (Duration{}).write(english, .wide, &buf));
    try testing.expectEqual(@as(f64, 65.05), d.totalMinutes());
}

test "the system's culture writes in its own words" {
    if (!culture_mod.available) return error.SkipZigTest;
    const hu = try Culture.open(testing.allocator, "hu-HU");
    defer hu.close();
    if (hu.source != .system) return error.SkipZigTest;
    var buf: [128]u8 = undefined;
    const d = DateTime.at(.utc, 2026, 9, 25, 19, 42, 5);
    try testing.expectEqualStrings("2026. szeptember 25. 19:42", d.writeStyle(hu, .long, .short, &buf));
    try testing.expectEqualStrings("péntek, szeptember 25.", d.write(hu, "EEEE, MMMM d.", &buf));
    try testing.expectEqualStrings("szeptember 25.", d.writeSkeleton(hu, "MMMMd", &buf));
    try testing.expectEqualStrings("tegnap", d.addDays(-1).writeRelative(hu, d, .wide, &buf));
    try testing.expectEqualStrings("5 perccel ezelőtt", d.addMinutes(-5).writeRelative(hu, d, .wide, &buf));
}
