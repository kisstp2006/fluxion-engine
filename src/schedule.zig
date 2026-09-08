// SPDX-License-Identifier: BSD-3-Clause

//! When each of a game's systems runs.
//!
//! ```zig
//! try app.addSystem(.fixed, movePaddles);
//! try app.addSystem(.update, spinCoins);
//! try app.addSystem(.ui, scoreboard);
//! ```
//!
//! A system is a plain function that takes the `App`. Not a closure - Zig has
//! none - and not a struct with a virtual `process` on it, which is what a
//! scene graph would need and an ECS does not: the state a system works on
//! lives in the world it is handed, so the function needs nothing of its own
//! and a function pointer is the whole of it.
//!
//! **The stages are the frame, in order**, and there are seven:
//!
//! | Stage | When, and what belongs there |
//! | --- | --- |
//! | `startup` | Once, before the first frame. Spawn the world. |
//! | `input` | After the events are in. Turn keys into intent. |
//! | `fixed` | Zero or more times, at a constant delta. Physics. |
//! | `update` | Once, at whatever the frame took. Everything else. |
//! | `late` | After `update`, before anything is drawn. Cameras follow here. |
//! | `ui` | Inside the interface's own frame. Declares the interface. |
//! | `shutdown` | Once, after the last frame. |
//!
//! **`late` exists for one reason**: a camera that follows a player must run
//! after the player has moved, and putting both in `update` makes that an
//! accident of registration order. A camera in `late` is a frame behind
//! nothing and stutters for nobody.
//!
//! **`ui` is not a stage that happens to draw.** It runs between the layout
//! engine's `begin` and `end`, so the calls a system makes to `app.ui` build
//! that frame's tree. Declaring interface anywhere else does nothing at all,
//! which is the one surprise in the list and the reason it has its own name.
//!
//! **Within a stage, systems run in the order they were added**, on one
//! thread. That is not where the parallelism is: it is inside a system, in
//! `Query.each`, where the rows of an archetype are cut into chunks that do
//! not overlap. Running two whole systems at once would need to know which
//! components each touches, which needs a different way of declaring them
//! than a function pointer - and that is the next thing this file grows, not
//! something it pretends to have.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const App = @import("App.zig");

/// What a system is: a function that gets the whole application.
///
/// The alternative is Bevy's, where a system declares the queries and
/// resources it wants in its signature and the scheduler works out what may
/// run beside what. That is worth having and it is not free: it needs every
/// piece of state to be reachable by type, which means a resource registry
/// that this engine only half has. Until the scheduler can use that
/// information, asking for it would be ceremony - so a system takes the
/// `App`, and the day the dependency graph arrives is the day this type
/// changes and every game's systems change with it. Written down here so that
/// is a known cost rather than a surprise.
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

    /// How many stages there are, for the array of lists below.
    pub const count = @typeInfo(Stage).@"enum".fields.len;
};

/// One registered system, and what to call it in a message.
pub const Entry = struct {
    name: []const u8,
    run: System,
};

/// What went wrong, and where. See `Schedule.failed`.
pub const Failure = struct {
    stage: Stage,
    name: []const u8,
    err: anyerror,
};

pub const Schedule = struct {
    /// One list per stage, indexed by `@intFromEnum`. An array rather than a
    /// map because the set of stages is fixed and known at compile time, and
    /// the frame walks all of them every time.
    stages: [Stage.count]std.ArrayList(Entry) = @splat(.empty),

    /// Which system failed, and in which stage. Set by `run` and not cleared.
    ///
    /// A Zig error is a value with no room in it for a name, so a caller that
    /// catches one from `run` knows *what* went wrong and not *where*. This
    /// is where. Recording it rather than logging it is deliberate: a library
    /// that writes to the log takes a decision that belongs to the program -
    /// and a test that deliberately fails a system should not have to print
    /// an error to prove it worked.
    failed: ?Failure = null,

    pub const empty: Schedule = .{};

    pub fn deinit(self: *Schedule, gpa: Allocator) void {
        for (&self.stages) |*list| list.deinit(gpa);
        self.* = undefined;
    }

    /// Add a system to the end of a stage.
    pub fn add(self: *Schedule, gpa: Allocator, stage: Stage, system: System) Allocator.Error!void {
        return self.addNamed(gpa, stage, "system", system);
    }

    /// The same, with a name that turns up in a profile or a panic message.
    ///
    /// Zig cannot recover a function's own name from a pointer to it, so the
    /// name has to be handed over. It is borrowed, not copied: a string
    /// literal is the expected argument and it outlives everything.
    pub fn addNamed(
        self: *Schedule,
        gpa: Allocator,
        stage: Stage,
        name: []const u8,
        system: System,
    ) Allocator.Error!void {
        try self.stages[@intFromEnum(stage)].append(gpa, .{ .name = name, .run = system });
    }

    /// Run every system of one stage, in order, and stop at the first that
    /// fails.
    ///
    /// Stopping rather than carrying on is the right default for a stage: the
    /// systems after a failed one usually read what it was supposed to have
    /// written, and running them produces a second, more confusing failure.
    pub fn run(self: *Schedule, stage: Stage, app: *App) anyerror!void {
        for (self.stages[@intFromEnum(stage)].items) |entry| {
            entry.run(app) catch |err| {
                self.failed = .{ .stage = stage, .name = entry.name, .err = err };
                return err;
            };
        }
    }

    /// How many systems are in a stage.
    pub fn countIn(self: *const Schedule, stage: Stage) usize {
        return self.stages[@intFromEnum(stage)].items.len;
    }

    /// Whether any stage has anything in it, which is how `App` decides
    /// whether a game was ever configured.
    pub fn isEmpty(self: *const Schedule) bool {
        for (self.stages) |list| {
            if (list.items.len != 0) return false;
        }
        return true;
    }
};

test "systems run in the order they were added" {
    // A file-scoped counter rather than a closure, because the systems are
    // plain functions and have nothing to capture.
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

    try schedule.add(testing.allocator, .update, order.first);
    try schedule.add(testing.allocator, .update, order.second);
    try schedule.add(testing.allocator, .update, order.third);

    // No `App` is touched by any of them, so a pointer to none is safe here
    // and nowhere else.
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

    try schedule.addNamed(testing.allocator, .update, "guaranteed to fail", counted.fails);
    try schedule.add(testing.allocator, .update, counted.after);

    try testing.expectError(error.Deliberate, schedule.run(.update, undefined));
    try testing.expectEqual(@as(usize, 1), counted.ran);

    // And the schedule remembers which one, which an error value cannot say.
    try testing.expectEqualStrings("guaranteed to fail", schedule.failed.?.name);
    try testing.expectEqual(Stage.update, schedule.failed.?.stage);
}

test "a stage nobody registered anything in runs nothing" {
    var schedule: Schedule = .empty;
    defer schedule.deinit(testing.allocator);

    try testing.expect(schedule.isEmpty());
    try schedule.run(.fixed, undefined);
}
