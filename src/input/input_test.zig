// SPDX-License-Identifier: BSD-3-Clause

//! Input through a whole app, headless: keys and pads against fixed steps, dropped
//! files, the project's actions and dialog answers.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const Input = @import("input.zig");
const Project = @import("../project/Project.zig");
const dialog = @import("../platform/dialog.zig");
const platform = @import("fluxion_platform");
const helpers = @import("../test_helpers.zig");
const Files = helpers.Files;
const pressOf = helpers.pressOf;

test "a key held, and an axis of two keys" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    app.input.apply(pressOf(.a));
    try testing.expect(app.keyDown(.a));
    try testing.expectEqual(@as(f32, -1), app.keyAxis(.a, .d));
    app.input.apply(pressOf(.d));
    try testing.expectEqual(@as(f32, 0), app.keyAxis(.a, .d));
    try testing.expect(!app.keyDown(.w));
}

/// One press of space on a chosen frame, and a count of the fixed steps
/// that heard it.
const Jumps = struct {
    var heard: u32 = 0;
    var press_on: u64 = 1;

    fn press(app: *App) anyerror!void {
        if (app.time.frame == press_on) app.input.apply(pressOf(.space));
    }

    fn jump(app: *App) anyerror!void {
        if (app.input.justPressed(.space)) heard += 1;
    }

    /// Start the world again on the fourth frame. See the pause test.
    fn wake(app: *App) anyerror!void {
        if (app.time.frame == 4) app.time.scale = 1;
    }
};

test "a press is heard by one fixed step when frames are shorter than steps" {
    Jumps.heard = 0;
    Jumps.press_on = 1;

    // A frame is half a step long, so the frame the press lands on runs no
    // step. Powers of two keep the accumulator exact.
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 8,
        .fixed_delta = 1.0 / 64.0,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 128.0 };

    try app.addSystem(.input, "press", Jumps.press);
    try app.addSystem(.fixed, "jump", Jumps.jump);
    try app.run();

    try testing.expectEqual(@as(u32, 1), Jumps.heard);
}

test "a press is heard by one fixed step when a frame runs two" {
    Jumps.heard = 0;
    Jumps.press_on = 1;

    // A frame is two steps long, so both run inside the frame of the press.
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 4,
        .fixed_delta = 1.0 / 64.0,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 32.0 };

    try app.addSystem(.input, "press", Jumps.press);
    try app.addSystem(.fixed, "jump", Jumps.jump);
    try app.run();

    try testing.expectEqual(@as(u32, 1), Jumps.heard);
}

test "a press made while the world is paused does not reach the step after it" {
    Jumps.heard = 0;
    Jumps.press_on = 2;

    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 8,
        .fixed_delta = 1.0 / 64.0,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 32.0 };
    app.time.scale = 0;

    // Pressed on the second frame, paused until the fourth: no step should
    // hear it.
    try app.addSystem(.input, "press", Jumps.press);
    try app.addSystem(.input, "wake", Jumps.wake);
    try app.addSystem(.fixed, "jump", Jumps.jump);
    try app.run();

    try testing.expectEqual(@as(u32, 0), Jumps.heard);
}

/// A controller in slot zero with A held from the first frame on, handed over
/// every frame as `Window.pump` would.
const Controller = struct {
    var heard: u32 = 0;
    var slots: [Input.max_pads]platform.Gamepad = @splat(.{});

    fn poll(app: *App) anyerror!void {
        if (app.time.frame == 1) {
            slots[0].connected = true;
            slots[0].state.buttons[@intFromEnum(platform.GamepadButton.a)] = true;
        }
        app.input.readPads(&slots);
    }

    fn jump(app: *App) anyerror!void {
        if (app.input.anyPad().justPressed(.a)) heard += 1;
    }
};

test "a controller press is heard by one fixed step, as a key is" {
    Controller.heard = 0;
    Controller.slots = @splat(.{});

    // Frames half a step long, as in the key test: the frame the button goes
    // down on runs no step.
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 8,
        .fixed_delta = 1.0 / 64.0,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 128.0 };

    try app.addSystem(.input, "poll", Controller.poll);
    try app.addSystem(.fixed, "jump", Controller.jump);
    try app.run();

    // Once, though the button is held for all eight frames.
    try testing.expectEqual(@as(u32, 1), Controller.heard);
}

test "a headless dialog is never answered by itself, and a test's answer comes in the next frame" {
    const Seen = struct {
        var answers: usize = 0;
        var last: dialog.Id = .none;
        var paths: usize = 0;

        fn look(a: *App) anyerror!void {
            for (a.input.dialogAnswers()) |answer| {
                answers += 1;
                last = answer.id;
                paths += answer.paths.len;
            }
        }
    };
    Seen.answers = 0;
    Seen.paths = 0;
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "look", Seen.look);

    const folder = try app.openFolderDialog(.{ .title = "Where the project goes" });
    const file = try app.openFileDialog(.{ .multiple = true, .filters = &.{.{ .name = "Scenes", .extensions = &.{ "json", "scene" } }} });
    try testing.expect(folder != .none and file != .none and folder != file);

    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Seen.answers);

    app.input.answerDialog(.{ .id = folder, .paths = &.{"C:/games/meadow"} });
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Seen.answers);
    try testing.expectEqual(folder, Seen.last);
    try testing.expectEqual(@as(usize, 1), Seen.paths);

    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Seen.answers);
    try testing.expect(app.input.dialogAnswer(folder) == null);

    // A cancel is an answer, with no paths.
    app.input.answerDialog(.{ .id = file, .paths = &.{} });
    _ = try app.step();
    try testing.expectEqual(@as(usize, 2), Seen.answers);
    try testing.expectEqual(@as(usize, 0), app.input.dialogAnswer(file).?.len);

    // The ids go round after four billion, past `.none`.
    app.next_dialog = std.math.maxInt(u32);
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), @intFromEnum(try app.openFileDialog(.{})));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(try app.openFileDialog(.{})));
}

test "a frame that fails still lets its dialog answers go" {
    // The platform's paths are good until its next pump. An answer that a
    // failed frame kept would be read in the next one from memory already
    // given back - by an editor, which goes on after a system's error.
    const Once = struct {
        var failed = false;

        fn fail(_: *App) anyerror!void {
            if (failed) return;
            failed = true;
            return error.Broken;
        }
    };
    Once.failed = false;
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "fails once", Once.fail);

    const id = try app.openFileDialog(.{});
    app.input.answerDialog(.{ .id = id, .paths = &.{"C:/games/meadow/hero.png"} });
    try testing.expectError(error.Broken, app.step());

    _ = try app.step();
    try testing.expect(app.input.dialogAnswer(id) == null);
}

test "files dropped on the window reach that frame's systems, and only that frame's" {
    const Seen = struct {
        var drops: usize = 0;
        var last: []const u8 = "";

        fn look(app: *App) anyerror!void {
            for (app.input.dropped()) |drop| {
                drops += 1;
                last = drop.paths[drop.paths.len - 1];
            }
        }
    };
    Seen.drops = 0;
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "look", Seen.look);
    try app.startup();

    app.input.dropFiles(.{ .paths = &.{ "C:/Art/hero.png", "C:/Art/tree.png" }, .x = 10, .y = 20 });
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Seen.drops);
    try testing.expectEqualStrings("C:/Art/tree.png", Seen.last);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Seen.drops);
}

test "a project's actions are the game's, over the built-in ones, and the player's changes are kept apart" {
    var files: Files = try .init();
    defer files.tmp.cleanup();
    try files.tmp.dir.writeFile(testing.io, .{ .sub_path = Project.file_name, .data =
        \\{ "fluxion_project": 2, "application": { "name": "Keys" },
        \\  "input": { "actions": [
        \\    { "name": "jump", "bindings": [ { "type": "key", "key": "space" }, { "type": "pad_button", "button": "a" } ] },
        \\    { "name": "ui_accept", "bindings": [ { "type": "key", "key": "j" } ] } ] } }
    });
    const saves = try std.fs.path.join(testing.allocator, &.{ try files.at(), "saves" });
    defer testing.allocator.free(saves);

    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = try files.at(), .user_root = saves });
    defer app.destroy();
    try testing.expectEqual(@as(usize, 2), app.input.actions.get("jump").?.bindings.len);
    try testing.expect(app.input.actions.get("ui_accept").?.bindings[0].eql(.keyOf(.j)));

    app.input.apply(.{ .key = .{ .window = .none, .key = .space, .scancode = @enumFromInt(0), .action = .press, .mods = .{} } });
    _ = try app.step();
    try testing.expect(app.actionDown("jump"));
    try testing.expect(app.actionJustPressed("jump"));
    try testing.expectEqualStrings("Space", app.describeAction("jump"));
    _ = try app.step();
    try testing.expect(app.actionDown("jump"));
    try testing.expect(!app.actionJustPressed("jump"));

    // The player moves jump to W, and that is kept in a file of its own.
    try testing.expect(!try app.loadInputMap("user://input.json"));
    try testing.expect(app.input.actions.unbindAll("jump"));
    try app.input.actions.bind(testing.allocator, "jump", .keyOf(.w));
    try app.saveInputMap("user://input.json");

    const again = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = try files.at(), .user_root = saves });
    defer again.destroy();
    try testing.expect(again.input.actions.get("jump").?.bindings[0].eql(.keyOf(.space)));
    try testing.expect(try again.loadInputMap("user://input.json"));
    try testing.expectEqual(@as(usize, 1), again.input.actions.get("jump").?.bindings.len);
    try testing.expect(again.input.actions.get("jump").?.bindings[0].eql(.keyOf(.w)));

    // A program whose keys are its own has the built-in actions alone.
    const editor = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = try files.at(), .project_input = false });
    defer editor.destroy();
    try testing.expect(editor.input.actions.get("jump") == null);
    try testing.expect(editor.input.actions.get("ui_accept").?.bindings[0].eql(.keyOf(.enter)));
}
