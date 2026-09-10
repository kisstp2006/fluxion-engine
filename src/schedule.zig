// SPDX-License-Identifier: BSD-3-Clause

//! When each of a game's systems runs.
//!
//! ```zig
//! try app.addSystem(.fixed, "move paddles", movePaddles);
//! try app.addSystem(.late, "follow player", followPlayer);
//! ```
//!
//! A system is a plain function that takes the `App`; its state lives in the
//! world. The stages are the frame, in order:
//!
//! | Stage | When, and what belongs there |
//! | --- | --- |
//! | `startup` | Once, before the first frame. Spawn the world. |
//! | `input` | After the events are in. Turn keys into intent. |
//! | `fixed` | Zero or more times, at a constant delta. Physics. |
//! | `update` | Once, at whatever the frame took. Everything else. |
//! | `late` | After `update`, before anything is drawn. Cameras follow here. |
//! | `ui` | Inside the interface's own frame. Not run yet. |
//! | `shutdown` | Once, after the last frame. |
//!
//! Until the interface is wired up, `App.addSystem` refuses `ui` at compile
//! time. Within a stage, systems run in the order they were added, on one
//! thread - the parallelism is inside a system, in `Query.each`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const App = @import("App.zig");

/// What a system is: a function that gets the whole application. Declaring
/// queries in the signature, as Bevy does, waits for a scheduler that could
/// use them.
pub const System = *const fn (app: *App) anyerror!void;

/// Which part of the frame a system runs in. See the table above.
pub const Stage = enum {
    startup,
    input,
    fixed,
    update,
    late,
    ui,
    shutdown,

    pub const count = @typeInfo(Stage).@"enum".fields.len;
};

/// One registered system, and what to call it in a message.
pub const Entry = struct {
    name: []const u8,
    run: System,
    time_this_frame: std.Io.Duration = .zero,
    time_last_frame: std.Io.Duration = .zero,
};

/// What went wrong, and where. See `Schedule.failed`.
pub const Failure = struct {
    stage: Stage,
    name: []const u8,
    err: anyerror,

    /// Prints `the 'move ball' system in stage .fixed failed: OutOfMemory`
    /// with `{f}`.
    pub fn format(self: Failure, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("the '{s}' system in stage .{t} failed: {t}", .{ self.name, self.stage, self.err });
    }
};

pub const Schedule = struct {
    /// One list per stage, indexed by `@intFromEnum`.
    stages: [Stage.count]std.ArrayList(Entry) = @splat(.empty),

    /// Which system failed, and in which stage - an error value has no room
    /// for a name. Set by `run`, never cleared, and not logged: that is the
    /// program's decision.
    failed: ?Failure = null,

    io: ?std.Io = null,

    pub const empty: Schedule = .{};

    pub fn deinit(self: *Schedule, gpa: Allocator) void {
        for (&self.stages) |*list| list.deinit(gpa);
        self.* = undefined;
    }

    /// Add a system to the end of a stage. The name is borrowed, not copied;
    /// see `App.addSystem`, which is what a game calls.
    pub fn add(
        self: *Schedule,
        gpa: Allocator,
        stage: Stage,
        name: []const u8,
        system: System,
    ) Allocator.Error!void {
        try self.stages[@intFromEnum(stage)].append(gpa, .{ .name = name, .run = system });
    }

    /// Run one stage's systems in order, and stop at the first that fails:
    /// the ones after it usually read what it should have written.
    pub fn run(self: *Schedule, stage: Stage, app: *App) anyerror!void {
        for (self.stages[@intFromEnum(stage)].items) |*entry| {
            const started = if (self.io) |io| std.Io.Timestamp.now(io, .awake) else null;
            entry.run(app) catch |err| {
                self.failed = .{ .stage = stage, .name = entry.name, .err = err };
                return err;
            };
            if (started) |then| entry.time_this_frame.nanoseconds += then.durationTo(.now(self.io.?, .awake)).nanoseconds;
        }
    }

    pub fn beginFrame(self: *Schedule) void {
        for (&self.stages) |*list| {
            for (list.items) |*entry| {
                entry.time_last_frame = entry.time_this_frame;
                entry.time_this_frame = .zero;
            }
        }
    }

    pub fn systemsIn(self: *const Schedule, stage: Stage) []const Entry {
        return self.stages[@intFromEnum(stage)].items;
    }

    pub fn format(self: Schedule, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (std.enums.values(Stage)) |stage| {
            for (self.systemsIn(stage)) |entry| {
                try w.print("{s:<9} {s:<24} {f}\n", .{ @tagName(stage), entry.name, entry.time_last_frame });
            }
        }
    }

    /// Whether any stage has anything in it.
    pub fn isEmpty(self: *const Schedule) bool {
        for (self.stages) |list| {
            if (list.items.len != 0) return false;
        }
        return true;
    }
};

test "systems run in the order they were added" {
    const order = struct {
        var seen: [3]u8 = @splat(0);
        var at: usize = 0;

        fn first(_: *App) anyerror!void {
            seen[at] = 1;
            at += 1;
        }
        fn second(_: *App) anyerror!void {
            seen[at] = 2;
            at += 1;
        }
        fn third(_: *App) anyerror!void {
            seen[at] = 3;
            at += 1;
        }
    };
    order.at = 0;

    var schedule: Schedule = .empty;
    defer schedule.deinit(testing.allocator);

    try schedule.add(testing.allocator, .update, "first", order.first);
    try schedule.add(testing.allocator, .update, "second", order.second);
    try schedule.add(testing.allocator, .update, "third", order.third);

    // None of them touches the `App`, so `undefined` is safe here.
    try schedule.run(.update, undefined);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &order.seen);
}

test "a failing system stops the stage" {
    const counted = struct {
        var ran: usize = 0;

        fn fails(_: *App) anyerror!void {
            ran += 1;
            return error.Deliberate;
        }
        fn after(_: *App) anyerror!void {
            ran += 1;
        }
    };
    counted.ran = 0;

    var schedule: Schedule = .empty;
    defer schedule.deinit(testing.allocator);

    try schedule.add(testing.allocator, .update, "guaranteed to fail", counted.fails);
    try schedule.add(testing.allocator, .update, "after", counted.after);

    try testing.expectError(error.Deliberate, schedule.run(.update, undefined));
    try testing.expectEqual(@as(usize, 1), counted.ran);

    try testing.expectEqualStrings("guaranteed to fail", schedule.failed.?.name);
    try testing.expectEqual(Stage.update, schedule.failed.?.stage);

    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "the 'guaranteed to fail' system in stage .update failed: Deliberate",
        try std.fmt.bufPrint(&buffer, "{f}", .{schedule.failed.?}),
    );
}

test "every system is timed, and a frame's steps add up" {
    const busy = struct {
        fn run(_: *App) anyerror!void {
            const start: std.Io.Timestamp = .now(std.testing.io, .awake);
            while (start.durationTo(.now(std.testing.io, .awake)).nanoseconds < 2 * std.time.ns_per_ms) {}
        }
    };

    var schedule: Schedule = .{ .io = std.testing.io };
    defer schedule.deinit(testing.allocator);
    try schedule.add(testing.allocator, .fixed, "busy", busy.run);

    try schedule.run(.fixed, undefined);
    try schedule.run(.fixed, undefined);
    schedule.beginFrame();

    const timed = schedule.systemsIn(.fixed)[0];
    try testing.expect(timed.time_last_frame.nanoseconds >= 4 * std.time.ns_per_ms);
    try testing.expectEqual(0, timed.time_this_frame.nanoseconds);
}

test "the schedule prints every system's time over the last frame" {
    const idle = struct {
        fn run(_: *App) anyerror!void {}
    };

    var schedule: Schedule = .empty;
    defer schedule.deinit(testing.allocator);
    try schedule.add(testing.allocator, .fixed, "move ball", idle.run);
    try schedule.add(testing.allocator, .update, "show score", idle.run);
    schedule.stages[@intFromEnum(Stage.fixed)].items[0].time_last_frame = .fromNanoseconds(1_500_000);

    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "fixed" ++ " " ** 5 ++ "move ball" ++ " " ** 16 ++ "1.5ms\n" ++
            "update" ++ " " ** 4 ++ "show score" ++ " " ** 15 ++ "0ns\n",
        try std.fmt.bufPrint(&buffer, "{f}", .{schedule}),
    );
}

test "a stage nobody registered anything in runs nothing" {
    var schedule: Schedule = .empty;
    defer schedule.deinit(testing.allocator);

    try testing.expect(schedule.isEmpty());
    try schedule.run(.fixed, undefined);
}
