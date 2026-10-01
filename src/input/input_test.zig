// SPDX-License-Identifier: BSD-3-Clause

//! Input, alone and through a whole app, headless: keys, the pointer and
//! pads against frames and fixed steps, fingers and their gestures, dropped
//! files, the project's actions and dialog answers.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const platform = @import("fluxion_platform");

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");
const dialog = @import("../platform/dialog.zig");
const helpers = @import("../test_helpers.zig");
const Input = @import("input.zig");
const events = @import("input_event.zig");

const Action = Input.Action;
const AxisBinding = Input.AxisBinding;
const Device = Input.Device;
const Files = helpers.Files;
const answer_capacity = Input.answer_capacity;
const drop_capacity = Input.drop_capacity;
const max_pads = Input.max_pads;
const mouse_as_finger = Input.mouse_as_finger;
const pressOf = helpers.pressOf;
const touchOf = helpers.touchOf;

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

fn keyEvent(key: platform.Key, action: platform.Action) platform.Event {
    return .{ .key = .{
        .window = .none,
        .key = key,
        .scancode = @enumFromInt(0),
        .action = action,
        .mods = .{},
    } };
}

test "an edge lasts exactly one frame" {
    var input: Input = .{};
    input.beginFrame();
    input.apply(keyEvent(.space, .press));

    try testing.expect(input.isDown(.space));
    try testing.expect(input.justPressed(.space));

    input.beginFrame();
    try testing.expect(input.isDown(.space));
    try testing.expect(!input.justPressed(.space));
}

test "down and up inside one frame still counts as both" {
    var input: Input = .{};
    input.beginFrame();
    input.apply(keyEvent(.e, .press));
    input.apply(keyEvent(.e, .release));

    try testing.expect(!input.isDown(.e));
    try testing.expect(input.justPressed(.e));
    try testing.expect(input.justReleased(.e));
}

test "both directions held is a standstill" {
    var input: Input = .{};
    input.apply(keyEvent(.a, .press));
    try testing.expectEqual(@as(f32, -1), input.axisOf(.keys(.a, .d)));

    input.apply(keyEvent(.d, .press));
    try testing.expectEqual(@as(f32, 0), input.axisOf(.keys(.a, .d)));
}

test "two keys for one end of an axis count once" {
    var input: Input = .{};
    const walk = AxisBinding.keys(.a, .d).orKeys(.left, .right);

    input.apply(keyEvent(.left, .press));
    try testing.expectEqual(@as(f32, -1), input.axisOf(walk));

    // A and the left arrow together are still -1, not -2.
    input.apply(keyEvent(.a, .press));
    try testing.expectEqual(@as(f32, -1), input.axisOf(walk));
}

test "losing focus lets go of everything" {
    var input: Input = .{};
    input.apply(keyEvent(.w, .press));
    input.beginFrame();
    input.apply(.{ .focus = .{ .window = .none, .value = false } });

    try testing.expect(!input.isDown(.w));
    try testing.expect(input.justReleased(.w));
}

test "a press waits for a fixed step, and only one step hears it" {
    var input: Input = .{};
    input.beginFrame();
    input.apply(keyEvent(.space, .press));

    // A frame that ran no fixed step ends, and the next one begins: the
    // frame's edge is gone...
    input.beginFrame();
    try testing.expect(!input.justPressed(.space));

    // ... but the step that finally runs still hears it,
    input.clock = .fixed;
    try testing.expect(input.justPressed(.space));
    input.endFixedStep();

    // and the step after that does not.
    try testing.expect(!input.justPressed(.space));
    try testing.expect(input.isDown(.space));
}

test "letting go on losing focus reaches the fixed step too" {
    var input: Input = .{};
    input.apply(.{ .mouse_button = .{
        .window = .none,
        .button = .left,
        .action = .press,
        .mods = .{},
        .x = 0,
        .y = 0,
    } });
    input.endFixedStep();
    input.apply(.{ .focus = .{ .window = .none, .value = false } });

    input.clock = .fixed;
    try testing.expect(input.buttonJustReleased(.left));
    try testing.expect(!input.buttonDown(.left));
}

test "an unknown key is not an index" {
    var input: Input = .{};
    input.apply(keyEvent(.unknown, .press));
    try testing.expect(!input.isDown(.unknown));
}

/// Every slot empty, as with nothing plugged in.
fn emptySlots() [max_pads]platform.Gamepad {
    return @splat(.{});
}

fn hold(device: *platform.Gamepad, button: platform.GamepadButton, held: bool) void {
    device.connected = true;
    device.state.buttons[@intFromEnum(button)] = held;
}

fn lean(device: *platform.Gamepad, which: platform.GamepadAxis, value: f32) void {
    device.connected = true;
    device.state.axes[@intFromEnum(which)] = value;
}

test "a controller press is this frame's buttons against the last" {
    var input: Input = .{};
    var slots = emptySlots();

    hold(&slots[0], .a, true);
    input.beginFrame();
    input.readPads(&slots);
    try testing.expect(input.pad(0).connected());
    try testing.expect(input.pad(0).down(.a));
    try testing.expect(input.pad(0).justPressed(.a));

    // Still held a frame later: down, and no longer an edge.
    input.beginFrame();
    input.readPads(&slots);
    try testing.expect(input.pad(0).down(.a));
    try testing.expect(!input.pad(0).justPressed(.a));

    hold(&slots[0], .a, false);
    input.beginFrame();
    input.readPads(&slots);
    try testing.expect(input.pad(0).justReleased(.a));
    try testing.expect(!input.pad(0).down(.a));

    // An empty slot says no to everything.
    try testing.expect(!input.pad(3).connected());
    try testing.expect(!input.pad(99).down(.a));
}

test "a controller unplugged lets go of everything it held" {
    var input: Input = .{};
    var slots = emptySlots();

    hold(&slots[2], .right_bumper, true);
    input.readPads(&slots);

    slots[2] = .{};
    input.beginFrame();
    input.readPads(&slots);

    try testing.expect(!input.pad(2).connected());
    try testing.expect(!input.pad(2).down(.right_bumper));
    try testing.expect(input.pad(2).justReleased(.right_bumper));
}

test "a stick at rest inside its dead zone is still, and full tilt is one" {
    var input: Input = .{};
    var slots = emptySlots();

    // A worn stick, resting a little off centre.
    lean(&slots[0], .left_x, 0.12);
    lean(&slots[0], .left_y, -0.08);
    input.readPads(&slots);
    try testing.expectEqual(@as(f32, 0), input.pad(0).stick(.left).len());

    lean(&slots[0], .left_x, 1);
    lean(&slots[0], .left_y, 0);
    input.readPads(&slots);
    try testing.expectApproxEqAbs(@as(f32, 1), input.pad(0).stick(.left).x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), input.pad(0).axis(.left_x), 0.0001);

    // A corner reporting more than full tilt on both axes is no faster.
    lean(&slots[0], .left_x, 1);
    lean(&slots[0], .left_y, 1);
    input.readPads(&slots);
    try testing.expectApproxEqAbs(@as(f32, 1), input.pad(0).stick(.left).len(), 0.0001);

    // Just past the edge of the dead zone is a small number, not a jump.
    lean(&slots[0], .left_x, 0.21);
    lean(&slots[0], .left_y, 0);
    input.readPads(&slots);
    try testing.expect(input.pad(0).stick(.left).x < 0.05);
}

test "a trigger rests at zero and reads up to one" {
    var input: Input = .{};
    var slots = emptySlots();

    lean(&slots[0], .right_trigger, 0.05);
    input.readPads(&slots);
    try testing.expectEqual(@as(f32, 0), input.pad(0).axis(.right_trigger));

    lean(&slots[0], .right_trigger, 1);
    input.readPads(&slots);
    try testing.expectApproxEqAbs(@as(f32, 1), input.pad(0).axis(.right_trigger), 0.0001);
}

test "any pad is every pad at once" {
    var input: Input = .{};
    var slots = emptySlots();

    hold(&slots[0], .a, true);
    lean(&slots[3], .left_x, -0.9);
    // Resting slightly off, on a controller nobody is using.
    lean(&slots[5], .left_x, 0.15);
    input.readPads(&slots);

    const any = input.anyPad();
    try testing.expect(any.connected());
    try testing.expect(any.down(.a));
    try testing.expect(any.justPressed(.a));
    // The stick being pushed, not the sum of it and the resting one.
    try testing.expect(any.stick(.left).x < -0.8);
    try testing.expect(!input.pad(3).down(.a));
}

test "a controller press reaches exactly one fixed step" {
    var input: Input = .{};
    var slots = emptySlots();

    hold(&slots[0], .a, true);
    input.beginFrame();
    input.readPads(&slots);

    // A frame that ran no fixed step, and the next one, still held: no new
    // edge for the frame...
    input.beginFrame();
    input.readPads(&slots);
    try testing.expect(!input.pad(0).justPressed(.a));

    // ... and the press still waiting for the step that finally runs.
    input.clock = .fixed;
    try testing.expect(input.anyPad().justPressed(.a));
    input.endFixedStep();
    try testing.expect(!input.anyPad().justPressed(.a));
}

test "the d-pad makes an axis the way two keys do" {
    var input: Input = .{};
    var slots = emptySlots();
    const climb = (AxisBinding{}).withPadY(0);

    hold(&slots[0], .dpad_up, true);
    input.readPads(&slots);
    try testing.expectEqual(@as(f32, -1), input.axisOf(climb));

    hold(&slots[0], .dpad_down, true);
    input.readPads(&slots);
    try testing.expectEqual(@as(f32, 0), input.axisOf(climb));
}

test "a binding adds its keys, its stick and its d-pad, and holds the sum to one" {
    var input: Input = .{};
    var slots = emptySlots();
    const bat = AxisBinding.keys(.w, .s).withPadY(1);

    // 0.6 down, less the dead zone of 0.2, rescaled: exactly half.
    lean(&slots[1], .left_y, 0.6);
    input.readPads(&slots);
    try testing.expectApproxEqAbs(@as(f32, 0.5), input.axisOf(bat), 0.0001);

    // And S as well: one, not one and a half.
    input.apply(keyEvent(.s, .press));
    try testing.expectEqual(@as(f32, 1), input.axisOf(bat));

    // The binding is for slot one: the same stick on slot zero moves nothing.
    var other = emptySlots();
    lean(&other[0], .left_y, 0.6);
    input.apply(keyEvent(.s, .release));
    input.readPads(&other);
    try testing.expectEqual(@as(f32, 0), input.axisOf(bat));
}

test "a binding with a number out of range is no input, not a crash" {
    var input: Input = .{};
    var slots = emptySlots();
    hold(&slots[0], .a, true);
    input.readPads(&slots);

    // What a save written by a build with more buttons might hold.
    var strange = (AxisBinding{}).withPadY(0);
    strange.pad_axis = 200;
    strange.pad_positive = 99;
    try testing.expectEqual(@as(f32, 0), input.axisOf(strange));
}

fn cursorEvent(x: f64, y: f64, dx: f64, dy: f64) platform.Event {
    return .{ .cursor = .{ .window = .none, .x = x, .y = y, .dx = dx, .dy = dy } };
}

test "every finger is a touch of its own, from the frame it touches to the frame it is lifted" {
    var input: Input = .{};
    input.frame_origin = .init(100, 0);
    input.frame_ratio = 0.5;

    input.apply(touchOf(4, .down, 300, 200));
    input.apply(touchOf(9, .down, 500, 100));
    try testing.expect(input.touchscreen);
    try testing.expectEqual(@as(usize, 2), input.fingersDown());
    const first = input.touchOf(4).?;
    try testing.expect(first.pressed and first.mouse);
    try testing.expectEqual(@as(f32, 100), first.position.x);
    try testing.expect(!input.touchOf(9).?.mouse);

    // Moves in one frame are one event a finger, added up.
    input.apply(touchOf(4, .move, 310, 200));
    input.apply(touchOf(9, .move, 520, 100));
    input.apply(touchOf(4, .move, 320, 210));
    const heard = input.pointerEvents();
    try testing.expectEqual(@as(usize, 4), heard.len);
    try testing.expectEqual(@as(f32, 10), heard[2].touch_motion.relative.x);
    try testing.expectEqual(@as(f32, 5), heard[2].touch_motion.relative.y);
    try testing.expectEqual(@as(?u32, 9), heard[3].finger());
    try testing.expectEqual(@as(f32, 10), input.touchOf(4).?.relative.x);

    // Lifted: there this frame, with `released`, and gone the next.
    input.endFrame();
    input.beginFrame();
    try testing.expect(!input.touchOf(4).?.pressed);
    input.apply(touchOf(4, .up, 320, 210));
    input.apply(touchOf(9, .cancel, 520, 100));
    try testing.expect(input.touchOf(4).?.released);
    try testing.expect(input.touchOf(9).?.canceled);
    try testing.expectEqual(@as(usize, 0), input.fingersDown());
    try testing.expect(input.pointerEvents()[1].touch.canceled);
    input.endFrame();
    input.beginFrame();
    try testing.expectEqual(@as(usize, 0), input.touches().len);

    // A finger touched and lifted inside one frame is still seen.
    input.apply(touchOf(1, .down, 0, 0));
    input.apply(touchOf(1, .up, 0, 0));
    try testing.expect(input.touchOf(1).?.pressed and input.touchOf(1).?.released);
}

test "the first finger's mouse is not heard when a project says so, and the mouse is a finger when it says that" {
    var input: Input = .{};
    input.mouse_from_touch = false;
    input.apply(.{ .cursor = .{ .window = .none, .x = 50, .y = 60, .dx = 0, .dy = 0, .from_touch = true } });
    input.apply(.{ .mouse_button = .{ .window = .none, .button = .left, .action = .press, .mods = .{}, .x = 50, .y = 60, .from_touch = true } });
    try testing.expect(!input.buttonDown(.left));
    try testing.expectEqual(@as(f32, 0), input.pointer.x);

    input.touch_from_mouse = true;
    input.apply(cursorEvent(10, 20, 0, 0));
    input.apply(.{ .mouse_button = .{ .window = .none, .button = .left, .action = .press, .mods = .{}, .x = 10, .y = 20 } });
    try testing.expect(input.touchOf(mouse_as_finger).?.pressed);
    input.apply(cursorEvent(15, 20, 5, 0));
    try testing.expectEqual(@as(f32, 5), input.touchOf(mouse_as_finger).?.relative.x);
    input.apply(.{ .mouse_button = .{ .window = .none, .button = .left, .action = .release, .mods = .{}, .x = 15, .y = 20 } });
    try testing.expect(input.touchOf(mouse_as_finger).?.released);
    // A mouse is no touch screen.
    try testing.expect(input.touchscreen == builtin.abi.isAndroid());
}

/// A frame of the fingers: their events, then the gestures, a sixtieth of a
/// second on.
fn frameOf(input: *Input, happened: []const platform.Event) void {
    input.endFrame();
    input.beginFrame();
    for (happened) |event| input.apply(event);
    input.trackFingers(1.0 / 60.0);
}

fn gesturesOf(input: *const Input) []const events.InputEvent {
    var start: usize = 0;
    for (input.pointerEvents(), 0..) |event, i| {
        if (event == .touch or event == .touch_motion) start = i + 1;
    }
    return input.pointerEvents()[start..];
}

test "a finger lifted soon and near is a tap, and another soon after is a double tap" {
    var input: Input = .{};
    frameOf(&input, &.{touchOf(1, .down, 100, 100)});
    frameOf(&input, &.{touchOf(1, .move, 104, 102)});
    frameOf(&input, &.{touchOf(1, .up, 104, 102)});
    try testing.expectEqual(@as(u32, 1), gesturesOf(&input)[0].tap.count);

    frameOf(&input, &.{});
    frameOf(&input, &.{touchOf(2, .down, 110, 100)});
    frameOf(&input, &.{touchOf(2, .up, 110, 100)});
    try testing.expectEqual(@as(u32, 2), gesturesOf(&input)[0].tap.count);

    // Too late for a third: a tap of its own.
    for (0..30) |_| frameOf(&input, &.{});
    frameOf(&input, &.{touchOf(3, .down, 110, 100)});
    frameOf(&input, &.{touchOf(3, .up, 110, 100)});
    try testing.expectEqual(@as(u32, 1), gesturesOf(&input)[0].tap.count);
}

test "a finger held still is a long press, once, and then no tap" {
    var input: Input = .{};
    frameOf(&input, &.{touchOf(1, .down, 100, 100)});
    var pressed: usize = 0;
    for (0..40) |_| {
        frameOf(&input, &.{});
        for (gesturesOf(&input)) |event| {
            if (event == .long_press) pressed += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), pressed);
    frameOf(&input, &.{touchOf(1, .up, 100, 100)});
    try testing.expectEqual(@as(usize, 0), gesturesOf(&input).len);
}

test "a finger flicked and lifted while going fast is a swipe, and a slow drag is none" {
    var input: Input = .{};
    frameOf(&input, &.{touchOf(1, .down, 100, 300)});
    for (1..6) |i| frameOf(&input, &.{touchOf(1, .move, 100, 300 - @as(f64, @floatFromInt(i)) * 20)});
    frameOf(&input, &.{touchOf(1, .up, 100, 180)});
    const swiped = gesturesOf(&input)[0].swipe;
    try testing.expectEqual(events.SwipeEvent.Direction.up, swiped.direction);
    try testing.expectEqual(@as(f32, 300), swiped.start.y);
    try testing.expect(swiped.velocity.y < -1000);

    frameOf(&input, &.{touchOf(2, .down, 100, 300)});
    for (1..60) |i| frameOf(&input, &.{touchOf(2, .move, 100 + @as(f64, @floatFromInt(i)), 300)});
    frameOf(&input, &.{touchOf(2, .up, 160, 300)});
    try testing.expectEqual(@as(usize, 0), gesturesOf(&input).len);
}

test "two fingers pinch, pan and turn, and make no tap" {
    var input: Input = .{};
    frameOf(&input, &.{ touchOf(1, .down, 100, 100), touchOf(2, .down, 200, 100) });
    try testing.expect(input.gestures.two_fingers.active);
    try testing.expectEqual(@as(f32, 1), input.gestures.two_fingers.factor);

    // Twice as far apart, about the same middle.
    frameOf(&input, &.{ touchOf(1, .move, 50, 100), touchOf(2, .move, 250, 100) });
    try testing.expectApproxEqAbs(@as(f32, 2), input.gestures.two_fingers.factor, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2), gesturesOf(&input)[0].pinch.factor, 0.0001);

    // Moved together, then a quarter turn about the middle.
    frameOf(&input, &.{ touchOf(1, .move, 60, 120), touchOf(2, .move, 260, 120) });
    try testing.expectEqual(@as(f32, 20), input.gestures.two_fingers.relative.y);
    try testing.expectEqual(@as(f32, 20), gesturesOf(&input)[0].pan.relative.y);
    frameOf(&input, &.{ touchOf(1, .move, 160, 20), touchOf(2, .move, 160, 220) });
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), input.gestures.two_fingers.rotation, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), input.gestures.two_fingers.angle, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2), input.gestures.two_fingers.scale, 0.0001);

    // Lifted: no tap, no swipe, and no two fingers.
    frameOf(&input, &.{ touchOf(1, .up, 160, 20), touchOf(2, .up, 160, 220) });
    try testing.expectEqual(@as(usize, 0), gesturesOf(&input).len);
    try testing.expect(!input.gestures.two_fingers.active);
}

test "a wheel turned with Ctrl is a pinch at the pointer, as a touchpad's pinch is sent" {
    var input: Input = .{};
    input.apply(cursorEvent(40, 50, 0, 0));
    const ctrl: platform.Mods = .{ .control = true };
    input.apply(.{ .scroll = .{ .window = .none, .x = 0, .y = 2, .mods = ctrl } });
    var heard = input.pointerEvents();
    // The wheel's own event, and the pinch after it.
    try testing.expect(heard[heard.len - 2] == .wheel);
    var pinch = heard[heard.len - 1].pinch;
    try testing.expectApproxEqAbs(@as(f32, 1.21), pinch.factor, 0.0001);
    try testing.expectEqual(@as(f32, 40), pinch.center.x);
    input.apply(.{ .scroll = .{ .window = .none, .x = 0, .y = -1, .mods = ctrl } });
    heard = input.pointerEvents();
    pinch = heard[heard.len - 1].pinch;
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 1.1), pinch.factor, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.1), pinch.scale, 0.0001);

    // A pause starts another.
    input.trackFingers(0.5);
    input.apply(.{ .scroll = .{ .window = .none, .x = 0, .y = 1, .mods = ctrl } });
    heard = input.pointerEvents();
    try testing.expectApproxEqAbs(@as(f32, 1.1), heard[heard.len - 1].pinch.scale, 0.0001);

    // Without Ctrl, or with the project saying not, the wheel alone.
    input.apply(.{ .scroll = .{ .window = .none, .x = 0, .y = 1, .mods = .{} } });
    heard = input.pointerEvents();
    try testing.expect(heard[heard.len - 1] == .wheel);
    input.pinch_from_ctrl_wheel = false;
    input.apply(.{ .scroll = .{ .window = .none, .x = 0, .y = 1, .mods = ctrl } });
    heard = input.pointerEvents();
    try testing.expect(heard[heard.len - 1] == .wheel);
}

test "the window losing the keyboard lifts every finger" {
    var input: Input = .{};
    input.apply(touchOf(2, .down, 0, 0));
    input.apply(.{ .focus = .{ .window = .none, .value = false } });
    try testing.expect(input.touchOf(2).?.canceled);
    try testing.expectEqual(@as(usize, 0), input.fingersDown());
}

test "a locked pointer holds still, and only its movement counts" {
    var input: Input = .{};
    input.apply(cursorEvent(120, 80, 0, 0));

    input.pointer.locked = true;
    input.beginFrame();
    // What the platform sends while locked: no position, only movement.
    input.apply(cursorEvent(0, 0, 7, -3));
    input.apply(cursorEvent(0, 0, 5, 1));

    try testing.expectEqual(@as(f32, 120), input.pointer.x);
    try testing.expectEqual(@as(f32, 80), input.pointer.y);
    try testing.expectEqual(@as(f32, 12), input.pointer.dx);
    try testing.expectEqual(@as(f32, -2), input.pointer.dy);

    // A click while locked does not move it either.
    input.apply(.{ .mouse_button = .{
        .window = .none,
        .button = .left,
        .action = .press,
        .mods = .{},
        .x = 0,
        .y = 0,
    } });
    try testing.expectEqual(@as(f32, 120), input.pointer.x);
    try testing.expect(input.buttonDown(.left));
}

test "a locked pointer does not turn anything while the window is in the background" {
    var input: Input = .{};
    input.pointer.locked = true;
    input.apply(.{ .focus = .{ .window = .none, .value = false } });
    try testing.expect(!input.focused);

    input.beginFrame();
    input.apply(cursorEvent(0, 0, 40, 40));
    try testing.expectEqual(@as(f32, 0), input.pointer.dx);

    input.apply(.{ .focus = .{ .window = .none, .value = true } });
    input.apply(cursorEvent(0, 0, 3, 0));
    try testing.expectEqual(@as(f32, 3), input.pointer.dx);
}

test "a dialog's answer is there for the frame it came in, and one given between frames for the next" {
    var input: Input = .{};
    const early: dialog.Id = @enumFromInt(1);
    const late: dialog.Id = @enumFromInt(2);

    // Arrived with the frame's events: this frame's.
    input.beginFrame();
    input.answerDialog(.{ .id = early, .paths = &.{"C:/games/meadow"} });
    try testing.expectEqualStrings("C:/games/meadow", input.dialogAnswer(early).?[0]);
    input.endFrame();

    // Given after the frame ended: kept through the next frame's start.
    input.answerDialog(.{ .id = late, .paths = &.{} });
    input.beginFrame();
    try testing.expect(input.dialogAnswer(early) == null);
    try testing.expectEqual(@as(usize, 0), input.dialogAnswer(late).?.len);
    input.endFrame();
    input.beginFrame();
    try testing.expectEqual(@as(usize, 0), input.dialogAnswers().len);
}

test "a frame's dialog answers past what it holds are dropped, never written past the end" {
    var input: Input = .{};
    input.beginFrame();
    for (0..answer_capacity + 3) |n| input.answerDialog(.{ .id = @enumFromInt(n + 1), .paths = &.{} });
    try testing.expectEqual(@as(usize, answer_capacity), input.dialogAnswers().len);
    try testing.expect(input.dialogAnswer(@enumFromInt(answer_capacity)) != null);
    try testing.expect(input.dialogAnswer(@enumFromInt(answer_capacity + 1)) == null);
}

test "the platform's answer to a dialog is folded in with the rest of the events" {
    if (comptime dialog.available) {
        var input: Input = .{};
        input.beginFrame();
        input.apply(.{ .file_dialog = .{ .window = .none, .id = @enumFromInt(7), .paths = &.{"/art/hero.png"} } });
        try testing.expectEqualStrings("/art/hero.png", input.dialogAnswer(@enumFromInt(7)).?[0]);
    } else return error.SkipZigTest;
}

test "a drop is there for the frame it came in, and one given between frames for the next" {
    var input: Input = .{};

    // Arrived with the frame's events: this frame's.
    input.beginFrame();
    input.dropFiles(.{ .paths = &.{ "C:/Art/hero.png", "C:/Art/tree.png" }, .x = 40, .y = 60 });
    try testing.expectEqual(@as(usize, 1), input.dropped().len);
    try testing.expectEqualStrings("C:/Art/tree.png", input.dropped()[0].paths[1]);
    try testing.expectEqual(@as(f32, 60), input.dropped()[0].y);
    input.endFrame();

    // Given after the frame ended: kept through the next frame's start, and
    // only the next.
    input.dropFiles(.{ .paths = &.{"C:/Levels/meadow.json"}, .x = 0, .y = 0 });
    input.beginFrame();
    try testing.expectEqual(@as(usize, 1), input.dropped().len);
    try testing.expectEqualStrings("C:/Levels/meadow.json", input.dropped()[0].paths[0]);
    input.endFrame();
    input.beginFrame();
    try testing.expectEqual(@as(usize, 0), input.dropped().len);
}

test "a frame's drops past what it holds are dropped, never written past the end" {
    var input: Input = .{};
    input.beginFrame();
    for (0..drop_capacity + 2) |n| input.dropFiles(.{ .paths = &.{}, .x = @floatFromInt(n), .y = 0 });
    try testing.expectEqual(@as(usize, drop_capacity), input.dropped().len);
    try testing.expectEqual(@as(f32, drop_capacity - 1), input.dropped()[drop_capacity - 1].x);
}

test "the platform's drop is folded in with the rest of the events, at the place it was let go" {
    var input: Input = .{};
    input.beginFrame();
    input.apply(.{ .cursor = .{ .window = .none, .x = 7, .y = 9, .dx = 0, .dy = 0 } });

    var drop: platform.event.DropEvent = .{ .window = .none, .paths = &.{"/art/hero.png"} };
    const point = comptime @hasField(platform.event.DropEvent, "x");
    if (point) {
        drop.x = 120;
        drop.y = 45.5;
    }
    input.apply(.{ .drop = drop });

    const got = input.dropped();
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("/art/hero.png", got[0].paths[0]);
    // A platform that says where is taken at its word; one that does not
    // gets the pointer's last place.
    try testing.expectEqual(@as(f32, if (point) 120 else 7), got[0].x);
    try testing.expectEqual(@as(f32, if (point) 45.5 else 9), got[0].y);
}

test "going into the background is an edge for its frame and a level until the program is back" {
    var input: Input = .{};

    // Told in the frame: that frame's.
    input.beginFrame();
    input.apply(.suspended);
    try testing.expect(input.justSuspended() and input.suspended);
    input.endFrame();

    input.beginFrame();
    try testing.expect(!input.justSuspended() and input.suspended);
    input.endFrame();

    // Told between frames - by a test - it is the next frame's.
    input.apply(.resumed);
    input.apply(.low_memory);
    input.beginFrame();
    try testing.expect(input.justResumed() and input.lowMemory() and !input.suspended);
    input.endFrame();
    input.beginFrame();
    try testing.expect(!input.justResumed() and !input.lowMemory());
}

test "a window without a surface is one until it has a surface again" {
    var input: Input = .{};
    try testing.expect(!input.surface_lost);
    input.apply(.{ .surface_lost = .none });
    try testing.expect(input.surface_lost);
    input.apply(.{ .surface_created = .{ .window = .none, .width = 1080, .height = 2400 } });
    try testing.expect(!input.surface_lost);
}

fn virtualKeyEvent(key: platform.Key, virtual: platform.Key, action: platform.Action) platform.Event {
    var event = keyEvent(key, action);
    event.key.virtual = virtual;
    return event;
}

/// An input with actions, and a frame begun: what the action tests start
/// from.
fn withActions(project: []const Action) !Input {
    var input: Input = .{};
    try input.actions.reset(testing.allocator, project);
    input.beginFrame();
    return input;
}

test "an action is down while any of its inputs is, and its edges are the action's own" {
    var input = try withActions(&.{.{ .name = "jump", .bindings = &.{ .keyOf(.space), .keyOf(.w) } }});
    defer input.deinit(testing.allocator);

    input.apply(keyEvent(.space, .press));
    input.updateActions();
    try testing.expect(input.actionDown("jump"));
    try testing.expect(input.actionJustPressed("jump"));
    try testing.expectEqual(@as(f32, 1), input.actionStrength("jump"));

    // The second key is no new press, and letting go of the first no release.
    input.beginFrame();
    input.apply(keyEvent(.w, .press));
    input.updateActions();
    try testing.expect(!input.actionJustPressed("jump"));
    input.beginFrame();
    input.apply(keyEvent(.space, .release));
    input.updateActions();
    try testing.expect(input.actionDown("jump"));
    try testing.expect(!input.actionJustReleased("jump"));

    input.beginFrame();
    input.apply(keyEvent(.w, .release));
    input.updateActions();
    try testing.expect(!input.actionDown("jump"));
    try testing.expect(input.actionJustReleased("jump"));

    // A tap inside one frame is a press and a release.
    input.beginFrame();
    input.apply(keyEvent(.space, .press));
    input.apply(keyEvent(.space, .release));
    input.updateActions();
    try testing.expect(!input.actionDown("jump"));
    try testing.expect(input.actionJustPressed("jump"));
    try testing.expect(input.actionJustReleased("jump"));

    // An action there is none of is never down.
    try testing.expect(!input.actionDown("fly"));
}

test "an action's press waits for a fixed step, and only one step hears it" {
    var input = try withActions(&.{.{ .name = "jump", .bindings = &.{.keyOf(.space)} }});
    defer input.deinit(testing.allocator);
    input.apply(keyEvent(.space, .press));
    input.updateActions();

    input.beginFrame();
    input.updateActions();
    try testing.expect(!input.actionJustPressed("jump"));
    input.clock = .fixed;
    try testing.expect(input.actionJustPressed("jump"));
    input.endFixedStep();
    try testing.expect(!input.actionJustPressed("jump"));
}

test "a key bound by its letter follows the layout, and one by its place does not" {
    var input = try withActions(&.{
        .{ .name = "undo", .bindings = &.{.{ .key = .{ .key = .z, .physical = false } }} },
        .{ .name = "left", .bindings = &.{.keyOf(.a)} },
    });
    defer input.deinit(testing.allocator);
    // On a German layout Z is where Y is on a US one; A is where A is.
    input.apply(virtualKeyEvent(.y, .z, .press));
    input.apply(virtualKeyEvent(.q, .a, .press));
    input.updateActions();
    try testing.expect(input.actionDown("undo"));
    try testing.expect(!input.actionDown("left"));
}

test "a stick past an action's dead zone reads from nought to one, and four actions make a direction" {
    var input = try withActions(&.{
        .{ .name = "left", .deadzone = 0.2, .bindings = &.{ .padAxisOf(.left_x, .negative), .keyOf(.a) } },
        .{ .name = "right", .deadzone = 0.2, .bindings = &.{ .padAxisOf(.left_x, .positive), .keyOf(.d) } },
        .{ .name = "up", .bindings = &.{.keyOf(.w)} },
        .{ .name = "down", .bindings = &.{.keyOf(.s)} },
    });
    defer input.deinit(testing.allocator);
    var slots = emptySlots();

    lean(&slots[0], .left_x, 0.1);
    input.readPads(&slots);
    input.updateActions();
    try testing.expect(!input.actionDown("right"));

    lean(&slots[0], .left_x, 0.6);
    input.beginFrame();
    input.readPads(&slots);
    input.updateActions();
    try testing.expect(input.actionJustPressed("right"));
    try testing.expectApproxEqAbs(@as(f32, 0.5), input.actionStrength("right"), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), input.actionAxis("left", "right"), 0.0001);
    try testing.expectEqual(Device.pad, input.last_device);

    // A key and the stick at once are no faster than one of them.
    lean(&slots[0], .left_x, 0);
    input.beginFrame();
    input.readPads(&slots);
    input.apply(keyEvent(.d, .press));
    input.apply(keyEvent(.s, .press));
    input.updateActions();
    const toward = input.actionVector("left", "right", "up", "down");
    try testing.expectApproxEqAbs(@as(f32, 1), toward.len(), 0.0001);
    try testing.expect(toward.x > 0 and toward.y > 0);
    try testing.expectEqual(Device.keyboard, input.last_device);
}

test "a controller's button counts on the pad it is bound to, or on any" {
    var input = try withActions(&.{
        .{ .name = "any", .bindings = &.{.padButtonOf(.a)} },
        .{ .name = "second", .bindings = &.{.{ .pad_button = .{ .button = .a, .pad = 1 } }} },
    });
    defer input.deinit(testing.allocator);
    var slots = emptySlots();
    hold(&slots[0], .a, true);
    input.readPads(&slots);
    input.updateActions();
    try testing.expect(input.actionDown("any"));
    try testing.expect(!input.actionDown("second"));
}

test "code holds an action down until it lets go, with the edges an input gives" {
    var input = try withActions(&.{.{ .name = "fire", .bindings = &.{.keyOf(.f)} }});
    defer input.deinit(testing.allocator);
    try input.pressAction("fire", 0.5);
    try testing.expect(input.actionDown("fire"));
    try testing.expect(input.actionJustPressed("fire"));
    try testing.expectEqual(@as(f32, 0.5), input.actionStrength("fire"));

    // Held by the key as well, the code letting go does not let go of it.
    input.beginFrame();
    input.apply(keyEvent(.f, .press));
    input.updateActions();
    try input.releaseAction("fire");
    try testing.expect(input.actionDown("fire"));
    try testing.expect(!input.actionJustReleased("fire"));
    try testing.expectError(error.NoSuchAction, input.pressAction("fly", 1));
}

test "an action is named by its input on what the player last used" {
    var input = try withActions(&.{.{ .name = "open", .bindings = &.{ .padButtonOf(.x), .keyOf(.e) } }});
    defer input.deinit(testing.allocator);
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("E", input.describeAction(&buffer, "open"));
    var slots = emptySlots();
    hold(&slots[0], .x, true);
    input.readPads(&slots);
    try testing.expectEqualStrings("Pad X", input.describeAction(&buffer, "open"));
    try testing.expectEqualStrings("", input.describeAction(&buffer, "fly"));
    try testing.expectEqualStrings("Pad A", input.describeAction(&buffer, "ui_accept"));
}
