// SPDX-License-Identifier: BSD-3-Clause

//! The interface's controls, headless: anchors, the focus, popups, rich text
//! shown letter by letter, tooltips, and words a script writes.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");

const App = @import("../App.zig");
const control = @import("control.zig");
const components = @import("../scene/components.zig");
const script = @import("../script/script.zig");
const Assets = @import("../assets/assets.zig");
const Color = @import("../math/color.zig").Color;
const ToolWindow = @import("tool_window.zig");
const Interface = @import("interface.zig");
const Appearance = @import("../scene/inherited.zig").Appearance;
const Processing = @import("../scene/inherited.zig").Processing;
const platform = @import("fluxion_platform");
const typeface = @import("fluxion_font");
const helpers = @import("../test_helpers.zig");
const Paused = helpers.Paused;

const Entity = ecs.Entity;
const Parent = components.Parent;
const Control = control.Control;
const CanvasLayer = control.CanvasLayer;
const BoxContainer = control.BoxContainer;
const Button = control.Button;

/// An app with the controls drawn, a quarter of a second a frame, and a
/// canvas over the whole window.
fn withCanvas() !struct { app: *App, root: Entity } {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 400, .height = 200, .io = testing.io, .fixed_delta = 0.25 });
    errdefer app.destroy();
    app.time.source = .{ .fixed = 0.25 };
    try app.useControlNodes();
    const root = try app.world.spawnWith(.{ Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } }, CanvasLayer{} });
    return .{ .app = app, .root = root };
}

fn boxOf(app: *App, entity: Entity) ?@import("fluxion_ui").BoundingBox {
    var id: [48]u8 = undefined;
    return app.ui.boxOf(control.idOf(&id, entity));
}

fn fixed(width: f32, height: f32) Control {
    return .{ .width = .{ .mode = .fixed, .value = width }, .height = .{ .mode = .fixed, .value = height } };
}

fn pointAt(app: *App, x: f32, y: f32) void {
    app.input.apply(.{ .cursor = .{ .window = .none, .x = x, .y = y, .dx = 0, .dy = 0 } });
}

fn press(app: *App, x: f32, y: f32, down: bool) void {
    app.input.apply(.{ .mouse_button = .{ .window = .none, .button = .left, .action = if (down) .press else .release, .mods = .{}, .x = x, .y = y } });
}

fn touch(app: *App, finger: u32, phase: @import("fluxion_platform").event.TouchPhase, x: f32, y: f32) void {
    app.input.apply(.{ .touch = .{ .window = .none, .finger = finger, .phase = phase, .x = x, .y = y } });
}

const TouchButton = @import("touch_button.zig").TouchButton;

const Pressed = struct {
    var presses: u32 = 0;
    var releases: u32 = 0;

    fn pressed(_: *App, _: struct {}) !void {
        presses += 1;
    }

    fn released(_: *App, _: struct {}) !void {
        releases += 1;
    }
};

test "two touch buttons are held at once by two fingers, and hold their actions while they are" {
    const it = try withCanvas();
    const app = it.app;
    defer app.destroy();
    try app.input.actions.add(testing.allocator, .{ .name = "jump" });
    try app.input.actions.add(testing.allocator, .{ .name = "fire" });

    var left = fixed(80, 80);
    left.setAnchorsPreset(.bottom_left);
    var right = fixed(80, 80);
    right.setAnchorsPreset(.bottom_right);
    var jumping: TouchButton = .{};
    jumping.setAction("jump");
    var firing: TouchButton = .{};
    firing.setAction("fire");
    const jump = try app.world.spawnWith(.{ left, jumping, Parent.of(it.root) });
    const fire = try app.world.spawnWith(.{ right, firing, Parent.of(it.root) });
    Pressed.presses = 0;
    Pressed.releases = 0;
    try app.signal(jump, TouchButton, .pressed).connectFn(Pressed.pressed, .{});
    try app.signal(jump, TouchButton, .released).connectFn(Pressed.released, .{});
    for (0..2) |_| _ = try app.step();

    // A finger on each, touching inside: both held, both actions down.
    touch(app, 3, .down, 20, 180);
    touch(app, 5, .down, 380, 150);
    _ = try app.step();
    try testing.expect(app.world.get(jump, TouchButton).?.down);
    try testing.expect(app.world.get(fire, TouchButton).?.down);
    try testing.expect(app.input.actionDown("jump") and app.input.actionJustPressed("jump"));
    try testing.expect(app.input.actionDown("fire"));
    try testing.expectEqual(@as(u32, 1), Pressed.presses);
    try testing.expect(app.input.touchOf(3).?.on_button);

    // One lifted: its button and its action let go, the other held.
    touch(app, 3, .up, 20, 180);
    _ = try app.step();
    try testing.expect(!app.world.get(jump, TouchButton).?.down);
    try testing.expect(!app.input.actionDown("jump"));
    try testing.expect(app.input.actionDown("fire"));
    try testing.expectEqual(@as(u32, 1), Pressed.releases);

    // A button gone lets go of its action.
    app.world.despawn(fire);
    _ = try app.step();
    try testing.expect(!app.input.actionDown("fire"));

    // A finger touching outside presses nothing.
    touch(app, 7, .down, 200, 20);
    _ = try app.step();
    try testing.expect(!app.world.get(jump, TouchButton).?.down);
}

test "a touch button for a touch screen is drawn where one has been touched, and a mouse can be a finger" {
    const it = try withCanvas();
    const app = it.app;
    defer app.destroy();
    app.input.touchscreen = false;
    const button = try app.world.spawnWith(.{ fixed(60, 60), TouchButton{ .visibility = .touchscreen_only }, Parent.of(it.root) });
    for (0..2) |_| _ = try app.step();
    try testing.expect(boxOf(app, button) == null);

    // The left button, as a finger, does not make this a touch screen.
    app.setTouchFromMouse(true);
    press(app, 10, 10, true);
    _ = try app.step();
    try testing.expect(!app.hasTouchscreen());
    press(app, 10, 10, false);

    // A finger does, and the button is drawn and pressed from then on.
    touch(app, 1, .down, 150, 150);
    touch(app, 1, .up, 150, 150);
    for (0..2) |_| _ = try app.step();
    try testing.expect(app.hasTouchscreen());
    try testing.expect(boxOf(app, button) != null);
    press(app, 10, 10, true);
    _ = try app.step();
    try testing.expect(app.world.get(button, TouchButton).?.down);
}

test "a control held between two points stretches with its parent, and one pinned to a point grows from it" {
    const it = try withCanvas();
    const app = it.app;
    defer app.destroy();

    var between: Control = .{ .position = .anchored };
    between.anchor_left = 0.25;
    between.anchor_right = 0.75;
    between.anchor_top = 0.5;
    between.anchor_bottom = 1;
    between.offset_left = 10;
    between.offset_right = -10;
    between.offset_bottom = -20;
    const stretched = try app.world.spawnWith(.{ between, Parent.of(it.root) });

    var middle = fixed(40, 20);
    middle.setAnchorsPreset(.center);
    const pinned = try app.world.spawnWith(.{ middle, Parent.of(it.root) });
    const corner = try app.world.spawnWith(.{ fixed(30, 10), Parent.of(it.root) });
    try app.setAnchorsPreset(corner, .bottom_right);
    for (0..2) |_| _ = try app.step();

    // A quarter of the way in and ten more, half of it wide and twenty less.
    const wide = boxOf(app, stretched).?;
    try testing.expectEqual(@as(f32, 110), wide.x);
    try testing.expectEqual(@as(f32, 180), wide.width);
    try testing.expectEqual(@as(f32, 100), wide.y);
    try testing.expectEqual(@as(f32, 80), wide.height);
    // Its middle on the parent's.
    const small = boxOf(app, pinned).?;
    try testing.expectEqual(@as(f32, 180), small.x);
    try testing.expectEqual(@as(f32, 90), small.y);
    // Grown up and to the left from the corner.
    const low = boxOf(app, corner).?;
    try testing.expectEqual(@as(f32, 370), low.x);
    try testing.expectEqual(@as(f32, 190), low.y);
    try testing.expectEqual(Control.AnchorsPreset.bottom_right, app.world.get(corner, Control).?.anchorsPreset().?);
}

test "the focus goes where a control's Focus says, a press-only one is passed over, and grabFocus gives the keyboard" {
    const it = try withCanvas();
    const app = it.app;
    defer app.destroy();
    try app.world.add(it.root, BoxContainer{ .direction = .vertical });
    const first = try app.world.spawnWith(.{ fixed(100, 30), Parent.of(it.root), Button{} });
    const clicked = try app.world.spawnWith(.{ fixed(100, 30), Parent.of(it.root), Button{}, control.Focus{ .mode = .click } });
    const last = try app.world.spawnWith(.{ fixed(100, 30), Parent.of(it.root), Button{} });
    try app.world.add(last, control.Focus{ .next = first });
    try app.world.add(first, control.Focus{ .next = last, .previous = last });
    for (0..2) |_| _ = try app.step();

    app.grabFocus(first);
    try testing.expect(app.hasFocus(first));
    _ = app.ui.navigate(.next);
    try testing.expect(app.hasFocus(last));
    _ = app.ui.navigate(.next);
    try testing.expect(app.hasFocus(first));
    _ = app.ui.navigate(.down);
    try testing.expect(app.hasFocus(last));
    // Only a press, or the game, gives it to the one that asked for that.
    app.grabFocus(clicked);
    try testing.expect(app.hasFocus(clicked));
    app.releaseFocus();
    try testing.expect(!app.hasFocus(clicked));
}

const Heard = struct {
    var closed: usize = 0;
    var pressed: usize = 0;
    var revealed: usize = 0;

    fn reset() void {
        closed = 0;
        pressed = 0;
        revealed = 0;
    }

    fn close(_: *App, _: struct {}) !void {
        closed += 1;
    }

    fn press(_: *App, _: struct {}) !void {
        pressed += 1;
    }

    fn reveal(_: *App, _: struct {}) !void {
        revealed += 1;
    }
};

test "an open popup is over everything in the middle, what is under it takes no press, and a press outside closes it" {
    const it = try withCanvas();
    const app = it.app;
    defer app.destroy();
    Heard.reset();
    var under = fixed(400, 200);
    under.position = .anchored;
    const button = try app.world.spawnWith(.{ under, Parent.of(it.root), Button{} });
    try app.signal(button, Button, .pressed).connectFn(Heard.press, .{});
    const box = try app.world.spawnWith(.{ fixed(100, 50), Parent.of(it.root), control.Popup{ .open = true } });
    try app.signal(box, control.Popup, .closed).connectFn(Heard.close, .{});
    for (0..2) |_| _ = try app.step();
    const shown = boxOf(app, box).?;
    try testing.expectEqual(@as(f32, 150), shown.x);
    try testing.expectEqual(@as(f32, 75), shown.y);

    // A press on the veil, over the button: the button hears nothing, and
    // the popup shuts and says so.
    pointAt(app, 10, 10);
    press(app, 10, 10, true);
    _ = try app.step();
    press(app, 10, 10, false);
    _ = try app.step();
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Heard.pressed);
    try testing.expect(!app.world.get(box, control.Popup).?.open);
    try testing.expectEqual(@as(usize, 1), Heard.closed);

    // Shut, it is not drawn, and the button takes presses again.
    press(app, 10, 10, true);
    _ = try app.step();
    press(app, 10, 10, false);
    _ = try app.step();
    try testing.expect(boxOf(app, box) == null);
    try testing.expectEqual(@as(usize, 1), Heard.pressed);
}

/// A press and a release at a point of the window, a frame each, after a
/// frame that lays out what changed: the pointer finds what the last frame
/// drew.
fn click(app: *App, x: f32, y: f32) !void {
    _ = try app.step();
    pointAt(app, x, y);
    press(app, x, y, true);
    _ = try app.step();
    press(app, x, y, false);
    _ = try app.step();
}

/// What a control and a button said, in the order they said it.
const Said = struct {
    var words: [16][]const u8 = undefined;
    var count: usize = 0;

    fn reset() void {
        count = 0;
    }

    fn note(word: []const u8) void {
        if (count < words.len) words[count] = word;
        count += 1;
    }

    fn entered(_: *App, _: struct {}) !void {
        note("entered");
    }
    fn exited(_: *App, _: struct {}) !void {
        note("exited");
    }
    fn focused(_: *App, _: struct {}) !void {
        note("focused");
    }
    fn unfocused(_: *App, _: struct {}) !void {
        note("unfocused");
    }
    fn down(_: *App, _: struct {}) !void {
        note("down");
    }
    fn up(_: *App, _: struct {}) !void {
        note("up");
    }
};

test "a control says when the pointer comes and goes and when it takes and loses the keys, and a button when it goes down and up" {
    const it = try withCanvas();
    const app = it.app;
    defer app.destroy();
    Said.reset();
    var place = fixed(100, 50);
    place.position = .anchored;
    const button = try app.world.spawnWith(.{ place, Parent.of(it.root), Button{} });
    try app.signal(button, Control, .mouse_entered).connectFn(Said.entered, .{});
    try app.signal(button, Control, .mouse_exited).connectFn(Said.exited, .{});
    try app.signal(button, Control, .focus_entered).connectFn(Said.focused, .{});
    try app.signal(button, Control, .focus_exited).connectFn(Said.unfocused, .{});
    try app.signal(button, Button, .button_down).connectFn(Said.down, .{});
    try app.signal(button, Button, .button_up).connectFn(Said.up, .{});
    pointAt(app, 300, 150);
    for (0..2) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Said.count);

    pointAt(app, 10, 10);
    for (0..2) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Said.count);
    try testing.expectEqualStrings("entered", Said.words[0]);

    press(app, 10, 10, true);
    _ = try app.step();
    press(app, 10, 10, false);
    _ = try app.step();
    pointAt(app, 300, 150);
    for (0..2) |_| _ = try app.step();
    // The press gave it the keys; let go of, and taken again.
    app.releaseFocus();
    for (0..2) |_| _ = try app.step();
    app.grabFocus(button);
    for (0..2) |_| _ = try app.step();
    // Gone, it says nothing more.
    app.world.despawn(button);
    for (0..2) |_| _ = try app.step();

    const said = Said.words[0..@min(Said.count, Said.words.len)];
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (said) |word| try joined.print(testing.allocator, "{s} ", .{word});
    try testing.expectEqualStrings("entered focused down up exited unfocused focused ", joined.items);
}

test "a layer over another lets the pointer through to what is under it, and so does a veil that ignores it" {
    const it = try withCanvas();
    const app = it.app;
    defer app.destroy();
    Heard.reset();
    var under = fixed(400, 200);
    under.position = .anchored;
    const button = try app.world.spawnWith(.{ under, Parent.of(it.root), Button{} });
    try app.signal(button, Button, .pressed).connectFn(Heard.press, .{});
    // A layer over the whole window, and a veil over the whole of it: what a
    // fade to black is, clear while nothing loads.
    const upper = try app.world.spawnWith(.{ Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } }, CanvasLayer{ .layer = 10 } });
    var covering = fixed(400, 200);
    covering.position = .anchored;
    covering.mouse_filter = .ignore;
    const veil = try app.world.spawnWith(.{ covering, Parent.of(upper), control.ColorRect{} });
    for (0..2) |_| _ = try app.step();

    try click(app, 10, 10);
    try testing.expectEqual(@as(usize, 1), Heard.pressed);

    // A veil that answers the pointer keeps it from the button.
    app.world.get(veil, Control).?.mouse_filter = .pass;
    try click(app, 10, 10);
    try testing.expectEqual(@as(usize, 1), Heard.pressed);

    // And so does a layer that stops it.
    app.world.get(veil, Control).?.mouse_filter = .ignore;
    app.world.get(upper, Control).?.mouse_filter = .stop;
    try click(app, 10, 10);
    try testing.expectEqual(@as(usize, 1), Heard.pressed);

    app.world.get(upper, Control).?.mouse_filter = .pass;
    try click(app, 10, 10);
    try testing.expectEqual(@as(usize, 2), Heard.pressed);
}

test "rich text shows its letters one after another, and says when the last shows" {
    const it = try withCanvas();
    const app = it.app;
    defer app.destroy();
    Heard.reset();
    const words = try app.world.spawnWith(.{ fixed(300, 40), Parent.of(it.root), control.RichText{ .reveal_speed = 4 } });
    try app.setText(words, control.RichText, "text", "{b|Hi} {color=red|there}");
    try app.signal(words, control.RichText, .revealed).connectFn(Heard.reveal, .{});
    _ = try app.step();
    try testing.expectEqual(@as(i32, -1), app.world.get(words, control.RichText).?.visible_characters);

    app.world.get(words, control.RichText).?.reveal();
    for (0..3) |_| _ = try app.step();
    // A letter a frame, the tags not counted.
    try testing.expectEqual(@as(i32, 3), app.world.get(words, control.RichText).?.visible_characters);
    for (0..6) |_| _ = try app.step();
    try testing.expectEqual(@as(i32, -1), app.world.get(words, control.RichText).?.visible_characters);
    try testing.expectEqual(@as(usize, 1), Heard.revealed);
}

test "a tooltip shows by the pointer once it has rested on its control long enough" {
    const it = try withCanvas();
    const app = it.app;
    defer app.destroy();
    const button = try app.world.spawnWith(.{ fixed(100, 30), Parent.of(it.root), Button{} });
    try app.setText(button, Control, "tooltip_text", "Saves the game");
    _ = try app.step();
    pointAt(app, 20, 10);
    _ = try app.step();
    try testing.expect(app.ui.boxOf("control-tooltip") == null);
    for (0..3) |_| _ = try app.step();
    const tip = app.ui.boxOf("control-tooltip").?;
    try testing.expect(tip.x > 20 and tip.y > 10);
    pointAt(app, 300, 150);
    for (0..2) |_| _ = try app.step();
    try testing.expect(app.ui.boxOf("control-tooltip") == null);
}

test "a script reads and writes a label's words, and a control's box as one value" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.useScripts(.{});
    const handle = try app.addScript("title.flux",
        \\struct Title {
        \\    fn ready(self) {
        \\        const label = self.entity.get(Label);
        \\        label.text = "Paused: " + label.text;
        \\        const look = self.entity.get(ThemeOverride);
        \\        var box = look.styleBox();
        \\        box.corner_radius = 9.0;
        \\        look.setStyleBox(box);
        \\    }
        \\}
    );
    const title = try app.world.spawnWith(.{ Control{}, control.Label{}, control.ThemeOverride{} });
    try app.setText(title, control.Label, "text", "Game");
    try app.world.add(title, script.Script.of(handle));
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
    try testing.expectEqualStrings("Paused: Game", app.textOf(title, control.Label, "text"));
    const look = app.world.get(title, control.ThemeOverride).?;
    try testing.expect(look.override_corners and look.override_background);
    try testing.expectEqual(@as(f32, 9), look.corner_radius);
}

test "a control's modulate colours it and everything in it, and its alpha fades them" {
    const it = try withCanvas();
    const app = it.app;
    defer app.destroy();
    const panel = try app.world.spawnWith(.{ fixed(100, 50), Parent.of(it.root), control.ColorRect{}, Appearance{ .modulate = .rgba(1, 0.5, 0.5, 0.5) } });
    _ = try app.world.spawnWith(.{ fixed(20, 20), Parent.of(panel), control.ColorRect{ .color = .rgba(0.5, 1, 1, 1) } });
    _ = try app.step();

    var outer = false;
    var inner = false;
    for (app.interface.commands) |command| switch (command.config) {
        .rectangle => |rect| {
            const c = rect.color;
            if (command.bounding_box.width == 100) {
                try testing.expectEqual(@import("fluxion_ui").Color.rgba(1, 0.5, 0.5, 0.5), c);
                outer = true;
            } else if (command.bounding_box.width == 20) {
                // Its own colour seen through the panel's.
                try testing.expectEqual(@import("fluxion_ui").Color.rgba(0.5, 0.5, 0.5, 0.5), c);
                inner = true;
            }
        },
        else => {},
    };
    try testing.expect(outer and inner);
}

test "a label's words sit where its alignment says, and a button's in its middle" {
    const it = try withCanvas();
    const app = it.app;
    defer app.destroy();
    _ = app.assets.loadFont(@import("../assets/assets.zig").systemFontPath(), .{ .atlas = 256 }) catch return error.SkipZigTest;
    const title = try app.world.spawnWith(.{ fixed(300, 100), Parent.of(it.root), control.Label{ .horizontal_alignment = .center, .vertical_alignment = .bottom } });
    try app.setText(title, control.Label, "text", "Middle");
    const right = try app.world.spawnWith(.{ fixed(300, 40), Parent.of(it.root), control.Label{ .horizontal_alignment = .right, .vertical_alignment = .center } });
    try app.setText(right, control.Label, "text", "Right");
    const go = try app.world.spawnWith(.{ fixed(300, 60), Parent.of(it.root), Button{} });
    try app.setText(go, Button, "text", "Go");
    _ = try app.step();

    const title_box = boxOf(app, title).?;
    const right_box = boxOf(app, right).?;
    const go_box = boxOf(app, go).?;
    var seen: usize = 0;
    for (app.interface.commands) |command| switch (command.config) {
        .text => |run| {
            const box = command.bounding_box;
            const middle_x = box.x + box.width / 2;
            const middle_y = box.y + box.height / 2;
            if (std.mem.eql(u8, run.text, "Middle")) {
                try testing.expectApproxEqAbs(title_box.x + title_box.width / 2, middle_x, 1);
                try testing.expectApproxEqAbs(title_box.y + title_box.height, box.y + box.height, 1);
                seen += 1;
            } else if (std.mem.eql(u8, run.text, "Right")) {
                try testing.expectApproxEqAbs(right_box.x + right_box.width, box.x + box.width, 1);
                try testing.expectApproxEqAbs(right_box.y + right_box.height / 2, middle_y, 1);
                seen += 1;
            } else if (std.mem.eql(u8, run.text, "Go")) {
                try testing.expectApproxEqAbs(go_box.x + go_box.width / 2, middle_x, 1);
                try testing.expectApproxEqAbs(go_box.y + go_box.height / 2, middle_y, 1);
                seen += 1;
            }
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 3), seen);
}

test "a control's own font is the one its words are drawn in" {
    const it = try withCanvas();
    const app = it.app;
    defer app.destroy();
    _ = app.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 256 }) catch return error.SkipZigTest;
    const other = try app.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 256, .label = "other" });
    const plain = try app.world.spawnWith(.{ Control{}, Parent.of(it.root), control.Label{} });
    try app.setText(plain, control.Label, "text", "Plain");
    const own = try app.world.spawnWith(.{ Control{}, Parent.of(it.root), control.Label{}, control.ThemeOverride{ .override_font = true, .font = other } });
    try app.setText(own, control.Label, "text", "Own");
    _ = try app.step();

    var fonts: [2]u16 = .{ 99, 99 };
    for (app.interface.commands) |command| switch (command.config) {
        .text => |run| {
            if (std.mem.eql(u8, run.text, "Plain")) fonts[0] = run.font;
            if (std.mem.eql(u8, run.text, "Own")) fonts[1] = run.font;
        },
        else => {},
    };
    try testing.expectEqual(@as(u16, 0), fonts[0]);
    try testing.expect(fonts[1] != 0 and fonts[1] != 99);
}

test "a script sets the window's fill, the frame cap and the interface's size, and loads in the background" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    try app.useScripts(.{});
    const handle = try app.addScript("settings.flux",
        \\const modes: [WindowMode] = [.windowed, .exclusive_fullscreen];
        \\var windowed = false;
        \\var mailbox = false;
        \\struct Settings {
        \\    fn ready(self) {
        \\        app.setWindowMode(modes[1]) catch {};
        \\        windowed = app.windowMode() == modes[0]; // with no window, a window
        \\        app.setVsyncMode(.mailbox) catch {};
        \\        mailbox = app.vsyncMode() == .mailbox;
        \\        app.setStretchAspect(.keep_height);
        \\        app.setStretchScaleMode(.integer);
        \\        app.setWindowBorderless(true) catch {};
        \\        app.setMaxFps(30.0);
        \\        app.setInterfaceZoom(1.5);
        \\        print(app.maxFps(), app.interfaceZoom(), app.loadProgress("res://nowhere.json"), app.currentScene());
        \\    }
        \\}
    );
    _ = try app.world.spawnWith(.{script.Script.of(handle)});
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
    try testing.expect(app.scripts.?.vm.get(app.scripts.?.moduleOf(handle).?, "windowed").?.asBool());
    try testing.expect(app.scripts.?.vm.get(app.scripts.?.moduleOf(handle).?, "mailbox").?.asBool());
    try testing.expect(app.stretchAspect() == .keep_height and app.stretchScaleMode() == .integer);
    try testing.expectEqual(@as(?f32, 30), app.time.max_fps);
    try testing.expectEqual(@as(f32, 1.5), app.interface.zoom);
    app.setMaxFps(0);
    try testing.expect(app.time.max_fps == null);
}

test "a focused slider keeps the focus along its way, and the arrows and a pad step it" {
    const it = try withCanvas();
    const app = it.app;
    defer app.destroy();
    const column = try app.world.spawnWith(.{ fixed(300, 200), Parent.of(it.root), BoxContainer{ .separation = 10 } });
    const slider = try app.world.spawnWith(.{ fixed(200, 20), Parent.of(column), control.Slider{ .min = 0, .max = 10, .value = 5, .step = 1 } });
    const below = try app.world.spawnWith(.{ fixed(200, 30), Parent.of(column), Button{} });
    _ = try app.step();
    app.grabFocus(slider);
    _ = try app.step();

    try app.pressAction("ui_right", 1);
    _ = try app.step();
    try testing.expectEqual(@as(f32, 6), app.world.get(slider, control.Slider).?.value);
    try testing.expect(app.hasFocus(slider));
    try app.releaseAction("ui_right");
    _ = try app.step();
    try app.pressAction("ui_left", 1);
    _ = try app.step();
    try app.releaseAction("ui_left");
    _ = try app.step();
    try testing.expectEqual(@as(f32, 5), app.world.get(slider, control.Slider).?.value);

    // Across its way, the focus goes on as ever.
    try app.pressAction("ui_down", 1);
    _ = try app.step();
    try app.releaseAction("ui_down");
    _ = try app.step();
    try testing.expect(app.hasFocus(below));
    try testing.expectEqual(@as(f32, 5), app.world.get(slider, control.Slider).?.value);
}

const Panel = struct {
    fn declare(app: *App) anyerror!void {
        app.ui.empty(.{ .id = "panel", .width = .fixed(100), .height = .fixed(50), .background_color = .white });
    }

    fn another(app: *App) anyerror!void {
        app.ui.empty(.{ .id = "other", .width = .fixed(60), .height = .fixed(50), .background_color = .white });
    }

    fn tall(app: *App) anyerror!void {
        app.ui.empty(.{ .id = "tall", .width = .fixed(10), .height = .grow });
    }

    fn label(app: *App) anyerror!void {
        app.ui.open(.{});
        defer app.ui.close();
        app.ui.text("Hi", .{ .font_size = 16 });
    }
};

const WorldPanel = struct {
    var released: u32 = 0;

    fn declare(app: *App) anyerror!void {
        app.openWorldUi(.init(40, 50), .{
            .id = "world panel",
            .width = .fixed(20),
            .height = .fixed(10),
            .background_color = .white,
        }, .{ .offset = .{ .x = 3, .y = -4 } });
        defer app.ui.close();
        if (app.ui.justReleased()) released += 1;
    }
};

test "world UI uses the regular interface scale and follows a world point" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240, .frames = 2 });
    defer app.destroy();
    app.interface.zoom = 2;
    try app.addSystem(.ui, "world panel", WorldPanel.declare);
    try app.run();

    const box = app.ui.boxOf("world panel").?;
    try testing.expectApproxEqAbs(@as(f32, 26), box.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 22), box.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40), box.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), box.height, 0.001);
}

test "world UI receives input through the regular interface" {
    WorldPanel.released = 0;
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240 });
    defer app.destroy();
    try app.addSystem(.ui, "world panel", WorldPanel.declare);
    try app.startup();

    _ = try app.step();
    app.input.apply(leftButton(true, 40, 40));
    _ = try app.step();
    app.input.apply(leftButton(false, 40, 40));
    _ = try app.step();

    try testing.expectEqual(@as(u32, 1), WorldPanel.released);
}

const Tool = struct {
    var released: u32 = 0;

    fn draw(_: *anyopaque, tool: *ToolWindow) anyerror!void {
        tool.ui.open(.{ .id = "tool-button", .width = .fixed(100), .height = .fixed(50) });
        if (tool.ui.justReleased()) released += 1;
        tool.ui.close();
        tool.ui.open(.{ .id = "tool-label" });
        tool.ui.text("Code", .{ .font_size = 20 });
        tool.ui.close();
    }
};

test "a tool window lays out an interface of its own from input of its own, in the interface's fonts" {
    Tool.released = 0;
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240, .io = testing.io });
    defer app.destroy();
    _ = app.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 256 }) catch return error.SkipZigTest;
    try app.startup();
    const tool = try app.openToolWindow(.{ .width = 200, .height = 120 });
    tool.draw = .{ .context = app, .run = Tool.draw };
    _ = try app.step();
    try testing.expectEqual(@as(f32, 100), tool.ui.boxOf("tool-button").?.width);
    try testing.expect(tool.ui.boxOf("tool-label").?.width > 0);
    try testing.expect(app.ui.boxOf("tool-button") == null);
    // Drawn, its words in the main interface's face.
    try testing.expect(tool.interface.renderer.?.instances.items.len >= 2);

    // A press on the main window's input is not the tool window's; one on
    // its own is.
    app.input.apply(leftButton(true, 40, 20));
    _ = try app.step();
    app.input.apply(leftButton(false, 40, 20));
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), Tool.released);
    tool.input.apply(leftButton(true, 40, 20));
    _ = try app.step();
    tool.input.apply(leftButton(false, 40, 20));
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), Tool.released);

    // Its close button is the program's to answer.
    tool.take(.{ .close = .none });
    _ = try app.step();
    try testing.expect(tool.close_pressed);
    app.closeToolWindow(tool);
    try testing.expectEqual(@as(usize, 0), app.tool_windows.items.len);
    _ = try app.step();
}

test "every .ui system declares into one root the size of the window" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240, .frames = 2 });
    defer app.destroy();
    try app.addSystem(.ui, "panel", Panel.declare);
    try app.addSystem(.ui, "another", Panel.another);
    try app.addSystem(.ui, "tall", Panel.tall);
    try app.run();

    try testing.expectEqual(@as(f32, 100), app.ui.boxOf("panel").?.width);
    try testing.expectEqual(@as(f32, 100), app.ui.boxOf("other").?.x);
    try testing.expectEqual(@as(f32, 240), app.ui.boxOf("tall").?.height);
    try testing.expectEqual(@as(usize, 2), app.interface.commands.len);
}

test "the interface is drawn over the 2D layer, in the default font" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1, .io = testing.io });
    defer app.destroy();
    _ = app.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 256 }) catch return error.SkipZigTest;
    _ = try app.world.spawnWith(.{ components.Transform2D.at(10, 10), components.Sprite.solid(.white, 8, 8) });
    try app.addSystem(.ui, "label", Panel.label);
    try app.run();

    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
    try testing.expectEqualSlices(*const typeface.Font, &.{&app.assets.fontOf(.none).?.face}, app.interface.faces.slice());
    try testing.expectEqual(@as(usize, 2), app.interface.renderer.?.instances.items.len);
}

const Code = struct {
    var index: u16 = 0;

    fn label(app: *App) anyerror!void {
        box(app, "words narrow", "iiii", 0);
        box(app, "words wide", "WWWW", 0);
        box(app, "code narrow", "iiii", index);
        box(app, "code wide", "WWWW", index);
    }

    /// A box as wide as its text.
    fn box(app: *App, id: []const u8, letters: []const u8, font: u16) void {
        app.ui.open(.{ .id = id });
        defer app.ui.close();
        app.ui.text(letters, .{ .font_size = 20, .font = font });
    }
};

test "a second font for the interface is measured and drawn by the index it was given" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1, .io = testing.io });
    defer app.destroy();
    const words = app.assets.loadSystemFont(.{ .atlas = 256 }) catch return error.SkipZigTest;
    const mono = app.assets.loadSystemFont(.{ .atlas = 256, .mono = true }) catch return error.SkipZigTest;
    app.interface.font = words;
    Code.index = try app.interface.addFont(mono);
    try testing.expectEqual(@as(u16, 1), Code.index);
    // Asked again, the same index; the interface's own font is 0.
    try testing.expectEqual(@as(u16, 1), try app.interface.addFont(mono));
    try testing.expectEqual(@as(u16, 0), try app.interface.addFont(words));
    try app.addSystem(.ui, "label", Code.label);
    try app.run();

    // Measured in its own face: every letter as wide as every other in the
    // code font, and not in the interface's.
    const width = struct {
        fn of(a: *App, id: []const u8) f32 {
            return a.ui.boxOf(id).?.width;
        }
    }.of;
    // Measured at all: with no measurer every width is nothing, and nothing
    // is as wide as nothing.
    try testing.expect(width(app, "code narrow") > 0);
    try testing.expectApproxEqAbs(width(app, "code narrow"), width(app, "code wide"), 0.5);
    try testing.expect(width(app, "words narrow") < width(app, "words wide"));
    // And drawn from the same table, in the same order.
    const table = [_]*const typeface.Font{ &app.assets.fontOf(words).?.face, &app.assets.fontOf(mono).?.face };
    try testing.expectEqualSlices(*const typeface.Font, &table, app.interface.faces.slice());
    try testing.expectEqualSlices(*const typeface.Font, &table, app.interface.renderer.?.faces.items);
    try testing.expectEqual(@as(usize, 16), app.interface.renderer.?.instances.items.len);
}

const Emoji = struct {
    fn label(app: *App) anyerror!void {
        Code.box(app, "plain", "aa", 0);
        Code.box(app, "smiling", "a😀", 0);
    }
};

test "an emoji in the interface is measured and drawn from the emoji font, in colour" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1, .io = testing.io });
    defer app.destroy();
    _ = app.assets.loadSystemFont(.{ .atlas = 256 }) catch return error.SkipZigTest;
    try app.assets.loadEmojiFonts();
    if (app.assets.fallback_count == 0) return error.SkipZigTest;
    try app.addSystem(.ui, "label", Emoji.label);
    try app.run();

    // The emoji takes room - its own font's advance, not an empty box's.
    const plain = app.ui.boxOf("plain").?.width;
    const smiling = app.ui.boxOf("smiling").?.width;
    try testing.expect(smiling > plain);

    // The fallback is last in the table, and the renderer falls back on it.
    const emoji_face = &app.assets.fontOf(app.assets.fallback_fonts[0]).?.face;
    const faces = app.interface.faces.slice();
    try testing.expectEqual(@as(*const typeface.Font, emoji_face), faces[faces.len - 1]);
    const renderer = &app.interface.renderer.?;
    try testing.expectEqualSlices(u16, &.{@intCast(faces.len - 1)}, renderer.fallbacks.items);
    var colored: usize = 0;
    for (renderer.instances.items) |instance| {
        if (instance.textured == @TypeOf(instance).Kind.color_glyph) colored += 1;
    }
    try testing.expectEqual(@as(usize, 1), colored);
}

test "a font read again is drawn again in the interface, not from the old one's glyphs" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    const font = app.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 256 }) catch return error.SkipZigTest;
    try app.addSystem(.ui, "label", Panel.label);
    try app.startup();

    _ = try app.step();
    const renderer = &app.interface.renderer.?;
    const texture = renderer.atlas_texture;
    const packed_to = .{ renderer.atlas.pen_y, renderer.atlas.pen_x };
    // Drawn again from the glyphs it has: nothing new is packed.
    _ = try app.step();
    try testing.expectEqual(packed_to, .{ renderer.atlas.pen_y, renderer.atlas.pen_x });

    // The face keeps its address, so its glyphs are forgotten by name and
    // packed again, into room of their own - in the same renderer and
    // texture.
    try testing.expect(try app.assets.reloadFont(font));
    _ = try app.step();
    try testing.expect(std.meta.eql(texture, app.interface.renderer.?.atlas_texture));
    const current = .{ renderer.atlas.pen_y, renderer.atlas.pen_x };
    try testing.expect(current[0] > packed_to[0] or (current[0] == packed_to[0] and current[1] > packed_to[1]));
    try testing.expectEqualSlices(*const typeface.Font, &.{&app.assets.fontOf(.none).?.face}, app.interface.faces.slice());
}

const Clicks = struct {
    var released: u32 = 0;
    var wanted = false;

    fn button(app: *App) anyerror!void {
        app.ui.open(.{ .id = "ok", .width = .fixed(40), .height = .fixed(20), .background_color = .white });
        defer app.ui.close();
        if (app.ui.justReleased()) released += 1;
    }

    fn game(app: *App) anyerror!void {
        wanted = app.ui.wantsPointer();
    }
};

fn leftButton(down: bool, x: f64, y: f64) platform.Event {
    return .{ .mouse_button = .{
        .window = .none,
        .button = .left,
        .action = if (down) .press else .release,
        .mods = .{},
        .x = x,
        .y = y,
    } };
}

test "a click presses what the interface drew under it, and the game is told" {
    Clicks.released = 0;
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 200, .height = 100 });
    defer app.destroy();
    try app.addSystem(.ui, "button", Clicks.button);
    try app.addSystem(.update, "game", Clicks.game);
    try app.startup();

    _ = try app.step();
    app.input.apply(leftButton(true, 20, 10));
    _ = try app.step();
    try testing.expect(Clicks.wanted);

    app.input.apply(leftButton(false, 20, 10));
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), Clicks.released);
}

test "a button answers while it runs: not while the game is paused, unless it asked to" {
    Paused.reset();
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 200, .height = 100 });
    defer app.destroy();
    try app.useControlNodes();
    const root = try app.world.spawnWith(.{ control.Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } }, control.CanvasLayer{} });
    const button = try app.world.spawnWith(.{
        control.Control{ .width = .{ .mode = .fixed, .value = 100 }, .height = .{ .mode = .fixed, .value = 40 } },
        components.Parent.of(root),
        control.Button{},
    });
    try app.setText(button, control.Button, "text", "Go");
    try app.signal(button, control.Button, .pressed).connectFn(Paused.press, .{});
    try app.startup();
    _ = try app.step();

    const Click = struct {
        fn at(a: *App) !void {
            a.input.apply(leftButton(true, 20, 10));
            _ = try a.step();
            a.input.apply(leftButton(false, 20, 10));
            _ = try a.step();
        }
    };
    try Click.at(app);
    try testing.expectEqual(@as(u32, 1), Paused.pressed);

    app.setPaused(true);
    try Click.at(app);
    try testing.expectEqual(@as(u32, 1), Paused.pressed);

    // A pause menu's button: it answers while the game is paused.
    try app.world.add(button, Processing{ .mode = .when_paused });
    try Click.at(app);
    try testing.expectEqual(@as(u32, 2), Paused.pressed);
}

test "a control fades as its Appearance and everything above it says, and grows as its scale does" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 200, .height = 100 });
    defer app.destroy();
    try app.useControlNodes();
    const holder = try app.world.spawnWith(.{Appearance{ .modulate = Color.white.withAlpha(0.5) }});
    const root = try app.world.spawnWith(.{ control.Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } }, control.CanvasLayer{}, components.Parent.of(holder) });
    const panel = try app.world.spawnWith(.{
        control.Control{ .width = .{ .mode = .fixed, .value = 40 }, .height = .{ .mode = .fixed, .value = 40 }, .scale = 2 },
        components.Parent.of(root),
        control.PanelContainer{},
        Appearance{ .modulate = Color.white.withAlpha(0.5) },
    });
    _ = try app.world.spawnWith(.{
        control.Control{ .width = .{ .mode = .fixed, .value = 10 }, .height = .{ .mode = .fixed, .value = 10 } },
        components.Parent.of(root),
        control.PanelContainer{},
        Appearance{ .visible = false },
    });
    _ = try app.step();

    var id: [48]u8 = undefined;
    const box = app.ui.boxOf(control.idOf(&id, panel)).?;
    var found = false;
    for (app.interface.commands) |command| {
        if (!std.meta.eql(command.bounding_box, box)) continue;
        const colour = switch (command.config) {
            .rectangle => |fill| fill.color,
            .image => |picture| picture.tint,
            else => continue,
        };
        // A quarter: its own half, and the half of what its tree hangs from.
        try testing.expect(colour.a <= 0.25 + 1e-4);
        try testing.expect(!command.transform.isIdentity());
        found = true;
    }
    try testing.expect(found);
    // The hidden one is not in the tree at all.
    var rectangles: usize = 0;
    for (app.interface.commands) |command| {
        if (command.config == .rectangle or command.config == .image) rectangles += 1;
    }
    try testing.expect(rectangles <= 2);
}

test "the interface is laid out at the game's zoom times the display's scale" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    _ = try app.step();
    // No window, so no display to follow.
    try testing.expectEqual(@as(f32, 1), app.interface.display_scale);
    try testing.expectEqual(@as(f32, 1), app.interface.scale);

    app.interface.zoom = 1.25;
    _ = try app.step();
    try testing.expectEqual(@as(f32, 1.25), app.interface.scale);
}

test "an interface font let go of draws in the first, and the indices after it keep their fonts" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    const words = app.assets.loadSystemFont(.{ .atlas = 64 }) catch return error.SkipZigTest;
    const mono = app.assets.loadSystemFont(.{ .atlas = 64, .mono = true }) catch return error.SkipZigTest;
    app.interface.font = words;
    // A handle to nothing, as one to a font since let go of is.
    const gone: Assets.FontHandle = .{ .index = 99, .generation = 7 };
    try testing.expectEqual(@as(u16, 1), try app.interface.addFont(gone));
    try testing.expectEqual(@as(u16, 2), try app.interface.addFont(mono));

    const faces = app.interface.fillFaces(&app.assets).slice();
    try testing.expectEqual(@as(usize, 3), faces.len);
    try testing.expectEqual(faces[0], faces[1]);
    try testing.expectEqual(&app.assets.fontOf(mono).?.face, faces[2]);
    // An index past the end is measured in the first, as it is drawn.
    try testing.expectEqual(faces[0], app.interface.faces.faceFor(3));
    try testing.expectEqual(faces[0], app.interface.faces.faceFor(9));

    // As many as the table holds, and not one more.
    for (3..Interface.max_fonts) |n| {
        const filler: Assets.FontHandle = .{ .index = @intCast(100 + n), .generation = 1 };
        try testing.expectEqual(@as(u16, @intCast(n)), try app.interface.addFont(filler));
    }
    try testing.expectError(error.TooManyFonts, app.interface.addFont(.{ .index = 500, .generation = 1 }));
}
