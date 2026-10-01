// SPDX-License-Identifier: BSD-3-Clause

//! Game states through a whole app, headless: the systems in a state and its
//! hooks.

const std = @import("std");
const testing = std.testing;

const States = @import("states.zig");
const keyOf = States.keyOf;

const App = @import("../App.zig");
const components = @import("../scene/components.zig");

const Mode = enum { menu, playing, paused };
const Weather = enum(u8) { clear = 3, rain = 7 };

fn headless() !*App {
    return App.create(testing.allocator, .{ .headless = true, .frame_time = 1.0 / 60.0 });
}

/// What the systems in these tests did, in order.
const Log = struct {
    var said: [16][]const u8 = undefined;
    var seen: [16]Mode = undefined;
    var len: usize = 0;
    var count: usize = 0;
    var open = false;

    fn reset() void {
        len = 0;
        count = 0;
        open = false;
    }

    fn say(app: *App, what: []const u8) void {
        said[len] = what;
        seen[len] = app.state(Mode);
        len += 1;
    }

    fn tick(_: *App) anyerror!void {
        count += 1;
    }

    fn enterMenu(app: *App) anyerror!void {
        say(app, "enter menu");
    }

    fn leaveMenu(app: *App) anyerror!void {
        say(app, "leave menu");
    }

    fn enterPlaying(app: *App) anyerror!void {
        say(app, "enter playing");
    }

    fn enterPaused(app: *App) anyerror!void {
        say(app, "enter paused");
    }

    fn pauseAtOnce(app: *App) anyerror!void {
        try app.setState(Mode.paused);
    }

    fn isOpen(_: *App) bool {
        return open;
    }

    fn failing(_: *App) anyerror!void {
        return error.Deliberate;
    }
};

test "a system in a state runs only while the state has that value" {
    Log.reset();
    const app = try headless();
    defer app.destroy();
    try app.addSystemIn(.update, Mode.playing, "move", Log.tick);
    try app.startup();

    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Log.count);

    try app.setState(Mode.playing);
    try testing.expectEqual(Mode.menu, app.state(Mode));
    _ = try app.step();
    try testing.expectEqual(Mode.playing, app.state(Mode));
    try testing.expectEqual(@as(usize, 1), Log.count);
}

test "leaving runs before entering, each seeing its own value, and the first value is entered after startup" {
    Log.reset();
    const app = try headless();
    defer app.destroy();
    try app.onEnter(Mode.menu, "enter menu", Log.enterMenu);
    try app.onExit(Mode.menu, "leave menu", Log.leaveMenu);
    try app.onEnter(Mode.playing, "enter playing", Log.enterPlaying);

    try app.startup();
    try app.setState(Mode.playing);
    _ = try app.step();

    try testing.expectEqual(@as(usize, 3), Log.len);
    try testing.expectEqualStrings("enter menu", Log.said[0]);
    try testing.expectEqualStrings("leave menu", Log.said[1]);
    try testing.expectEqual(Mode.menu, Log.seen[1]);
    try testing.expectEqualStrings("enter playing", Log.said[2]);
    try testing.expectEqual(Mode.playing, Log.seen[2]);
}

test "a state can start elsewhere, the last asked for wins, and the value it has changes nothing" {
    Log.reset();
    const app = try headless();
    defer app.destroy();
    try app.addState(Mode.playing);
    try app.onEnter(Mode.playing, "enter playing", Log.enterPlaying);
    try app.onEnter(Mode.paused, "enter paused", Log.enterPaused);
    try app.startup();
    try testing.expectEqual(@as(usize, 1), Log.len);

    try app.setState(Mode.playing);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Log.len);

    try app.setState(Mode.menu);
    try app.setState(Mode.paused);
    _ = try app.step();
    try testing.expectEqual(Mode.paused, app.state(Mode));
    try testing.expectEqualStrings("enter paused", Log.said[Log.len - 1]);
    try testing.expectEqual(@as(usize, 2), Log.len);
}

test "a change asked for while entering waits for the frame after" {
    Log.reset();
    const app = try headless();
    defer app.destroy();
    try app.onEnter(Mode.playing, "pause at once", Log.pauseAtOnce);
    try app.startup();

    try app.setState(Mode.playing);
    _ = try app.step();
    try testing.expectEqual(Mode.playing, app.state(Mode));
    _ = try app.step();
    try testing.expectEqual(Mode.paused, app.state(Mode));
}

test "a condition of the game's own decides whether a system runs" {
    Log.reset();
    const app = try headless();
    defer app.destroy();
    try app.addSystemIf(.update, Log.isOpen, "while open", Log.tick);

    _ = try app.step();
    Log.open = true;
    _ = try app.step();
    _ = try app.step();
    try testing.expectEqual(@as(usize, 2), Log.count);
}

test "a system that fails on a change of state says so" {
    const app = try headless();
    defer app.destroy();
    try app.onEnter(Mode.menu, "build the menu", Log.failing);
    try testing.expectError(error.Deliberate, app.startup());
    try testing.expectEqual(@as(?@import("schedule.zig").Stage, null), app.schedule.failed.?.stage);

    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "the 'build the menu' system, run on a change of state, failed: Deliberate",
        try std.fmt.bufPrint(&buffer, "{f}", .{app.schedule.failed.?}),
    );
}

/// A game, as an editor sees it: systems it did not write.
const Game = struct {
    var fixed_steps: usize = 0;
    var playing_frames: usize = 0;

    fn addSystems(app: *App) anyerror!void {
        try app.addSystem(.fixed, "count steps", countStep);
        try app.addSystemIn(.update, Mode.playing, "count playing", countPlaying);
    }

    fn countStep(_: *App) anyerror!void {
        fixed_steps += 1;
    }

    fn countPlaying(_: *App) anyerror!void {
        playing_frames += 1;
    }
};

test "systems added under a state run only in it, on top of their own conditions" {
    const Play = enum { editing, playing };
    Game.fixed_steps = 0;
    Game.playing_frames = 0;
    const app = try headless();
    defer app.destroy();
    try app.addSystemsIn(Play.playing, Game.addSystems);
    try app.addSystem(.update, "the editor's own", Log.tick);
    try app.addState(Mode.playing);

    Log.reset();
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Game.fixed_steps);
    try testing.expectEqual(@as(usize, 3), Log.count);

    try app.setState(Play.playing);
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 3), Game.fixed_steps);
    try testing.expectEqual(@as(usize, 3), Game.playing_frames);

    try app.setState(Mode.paused);
    for (0..2) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 5), Game.fixed_steps);
    try testing.expectEqual(@as(usize, 3), Game.playing_frames);
}

test "a hook added under a state runs only in it" {
    const Play = enum { editing, playing };
    const register = struct {
        fn addHooks(app: *App) anyerror!void {
            try app.onEnter(Mode.paused, "enter paused", Log.enterPaused);
        }
    }.addHooks;
    Log.reset();
    const app = try headless();
    defer app.destroy();
    try app.addSystemsIn(Play.playing, register);
    try app.startup();

    try app.setState(Mode.paused);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Log.len);

    try app.setState(Play.playing);
    try app.setState(Mode.menu);
    _ = try app.step();
    try app.setState(Mode.paused);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Log.len);
}

test "an editor's Edit, Play, Pause and Step, out of states and the clock" {
    const Play = enum { editing, playing, paused };
    Game.fixed_steps = 0;
    const app = try headless();
    defer app.destroy();
    try app.addSystemsIn(Play.playing, Game.addSystems);
    const crate = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.RigidBody2D{}, components.Collider2D.rectangle(5, 5) });
    const height = struct {
        fn of(a: *App, e: @import("fluxion_ecs").Entity) f32 {
            return a.world.get(e, components.Transform2D).?.y;
        }
    }.of;

    // Editing: the game's systems are out, and the world holds still.
    app.time.scale = 0;
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Game.fixed_steps);
    try testing.expectEqual(@as(f32, 0), height(app, crate));
    try testing.expect(app.bodyOf(crate) != null);

    // Play.
    try app.setState(Play.playing);
    app.time.scale = 1;
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 3), Game.fixed_steps);
    const fallen = height(app, crate);
    try testing.expect(fallen > 0);

    // Pause: nothing moves, and the game hears nothing.
    try app.setState(Play.paused);
    app.time.scale = 0;
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 3), Game.fixed_steps);
    try testing.expectEqual(fallen, height(app, crate));

    // Step: one frame of the game and one step of the world, then paused.
    try app.setState(Play.playing);
    app.time.stepOnce();
    _ = try app.step();
    try app.setState(Play.paused);
    try testing.expectEqual(@as(usize, 4), Game.fixed_steps);
    const stepped = height(app, crate);
    try testing.expect(stepped > fallen);

    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 4), Game.fixed_steps);
    try testing.expectEqual(stepped, height(app, crate));
}

test "a state is read and changed by the names of its type and its value" {
    const app = try headless();
    defer app.destroy();
    try app.addState(Weather.rain);
    try app.startup();
    try testing.expectEqualStrings("rain", app.stateNamed("Weather").?);
    try testing.expect(app.stateNamed("Mode") == null);

    try app.setStateNamed("Weather", "clear");
    try testing.expectEqual(Weather.rain, app.state(Weather));
    _ = try app.step();
    try testing.expectEqual(Weather.clear, app.state(Weather));
    try testing.expectEqualStrings("clear", app.stateNamed("Weather").?);

    try testing.expectError(error.NoSuchValue, app.setStateNamed("Weather", "snow"));
    try testing.expectError(error.NoSuchState, app.setStateNamed("Mood", "calm"));

    // The same, as a console calls it.
    var state_name: []const u8 = "Weather";
    var value_name: []const u8 = "rain";
    try app.callNamed("setStateNamed", &.{ .of(&state_name), .of(&value_name) }, null);
    _ = try app.step();
    try testing.expectEqual(Weather.rain, app.state(Weather));
}

test "a state starts at its first value, and each type is its own" {
    var states: States = .{};
    defer states.deinit(testing.allocator);

    try testing.expectEqual(Mode.menu, states.get(Mode));
    try testing.expectEqual(Weather.clear, states.get(Weather));
    try testing.expect(keyOf(Mode) != keyOf(Weather));
    try testing.expectEqual(keyOf(Mode), keyOf(Mode));

    try states.set(testing.allocator, Weather.rain);
    try testing.expectEqual(Weather.clear, states.get(Weather));
    try testing.expectEqual(@as(?u32, 7), (try states.slotFor(testing.allocator, Weather)).pending);
    try testing.expect(states.is(.of(Weather.clear)));
    try testing.expect(!states.is(.of(Weather.rain)));
}
