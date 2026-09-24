// SPDX-License-Identifier: BSD-3-Clause

//! The interface's controls, headless: anchors, the focus, popups, rich text
//! shown letter by letter, tooltips, and words a script writes.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");

const App = @import("App.zig");
const control = @import("control.zig");
const components = @import("components.zig");
const script = @import("script.zig");

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
        \\        const label = self.entity.get("Label");
        \\        label.text = "Paused: " + label.text;
        \\        const look = self.entity.get("ThemeOverride");
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
