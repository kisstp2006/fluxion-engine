// SPDX-License-Identifier: BSD-3-Clause

//! A `TouchButton`: a control that fingers press, as many at once as there
//! are fingers - a touch screen's stick, jump and fire, held together.
//!
//! ```zig
//! const jump = try app.world.spawnWith(.{ fx.Control{ .width = 96, .height = 96 }, fx.TextureRect{ .texture = art }, fx.TouchButton{} });
//! fx.TouchButton.setAction(app.world.get(jump, fx.TouchButton).?, "jump");
//! try app.signal(jump, fx.TouchButton, .pressed).connectFn(onJump, .{});
//! ```
//!
//! **Its box is its control's**, as the interface laid it out: a control on
//! the screen, drawn by whatever is beside it - a picture, a colour. The
//! interface itself answers one pointer, the first finger's; a touch button
//! answers every finger, and is pressed while any holds it.
//!
//! **Each frame, before the systems**: a finger that touches inside presses
//! it, and it stays pressed until that finger is lifted - or, with
//! `passby_press`, until the finger slides off, and any finger sliding on
//! presses it. It says `pressed` and `released`, and holds its `action` down
//! while it is pressed, as `app.pressAction` would: a game made for keys and
//! a controller plays by touch with no code of its own.
//!
//! A button hidden, paused or not laid out is let go. One shown only on a
//! touch screen - `visibility = .touchscreen_only` - is not drawn where there
//! is none (`app.hasTouchscreen()`), but for an editor.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");

const App = @import("../App.zig");
const attr = @import("../reflect/attr.zig");
const control = @import("control.zig");
const Input = @import("../input/input.zig");
const fixed_text = @import("../reflect/fixed_text.zig");

const Entity = ecs.Entity;
const log = std.log.scoped(.fluxion_engine);

pub const TouchButton = extern struct {
    /// The action it holds down while pressed, as `app.pressAction` would;
    /// none when empty.
    action: [32]u8 = @splat(0),
    /// Pressed by any finger that slides onto it, and let go when that
    /// finger slides off; without, only a finger that touches it presses it,
    /// until that finger is lifted.
    passby_press: bool = false,
    visibility: Visibility = .always,
    /// Whether a finger holds it now.
    down: bool = false,
    /// The finger that does.
    finger: u32 = 0,

    pub const Visibility = enum(u8) {
        /// Shown everywhere.
        always,
        /// Shown only where there is a touch screen.
        touchscreen_only,
    };

    pub const signals = .{ .pressed = struct {}, .released = struct {} };

    pub const reflect_name = "TouchButton";
    pub const reflect_fields = .{
        .action = .{ attr.InputAction{}, attr.Doc{ .text = "The action it holds down while a finger presses it" } },
        .passby_press = .{attr.Doc{ .text = "Pressed by a finger sliding onto it, and let go when it slides off" }},
        .visibility = .{attr.Doc{ .text = "Shown always, or only where there is a touch screen" }},
        .down = .{ attr.ReadOnly{}, attr.Unsaved{} },
        .finger = .{ attr.Hidden{}, attr.Unsaved{} },
    };
    pub const reflect_methods = .{ .setAction = .{attr.Params{ .names = &.{"name"} }}, .actionName = .{} };

    /// Hold `name` down while pressed; empty for none. A name longer than
    /// the button keeps is cut short.
    pub fn setAction(self: *TouchButton, name: []const u8) void {
        fixed_text.set(&self.action, name);
    }

    /// The action it holds, or empty.
    pub fn actionName(self: *const TouchButton) []const u8 {
        return fixed_text.get(&self.action);
    }

    /// Whether it is drawn, and so pressed: on a touch screen, or always.
    pub fn shown(self: TouchButton, touchscreen: bool) bool {
        return self.visibility == .always or touchscreen;
    }

    /// Whether its control is left out of the interface: where it is not
    /// shown. What the control tree asks of what is beside a control.
    pub fn hidesControl(self: *const TouchButton, app: *App) bool {
        return !self.shown(app.input.touchscreen);
    }
};

/// Press and let go of every touch button by this frame's fingers, say so,
/// and hold their actions. Called by `App.step` after the events, before the
/// frame's actions are worked out.
pub fn update(app: *App) !void {
    var it = try ecs.Query(.{TouchButton}).over(&app.world);
    var changed: std.ArrayList(Change) = .empty;
    defer changed.deinit(app.gpa);
    while (it.next()) |chunk| {
        for (chunk.slice(TouchButton), chunk.entities) |*button, entity| {
            const was = button.down;
            const box = boxOf(app, entity, button.*);
            press(&app.input, button, box);
            if (button.down) markOnButton(&app.input, button.finger);
            if (button.down != was) try changed.append(app.gpa, .{ .entity = entity, .down = button.down });
        }
    }
    for (changed.items) |change| {
        if (change.down) {
            try app.signal(change.entity, TouchButton, .pressed).emit(.{});
        } else {
            try app.signal(change.entity, TouchButton, .released).emit(.{});
        }
    }
    try holdActions(app);
}

const Change = struct { entity: Entity, down: bool };

/// An action's name as a button keeps it.
pub const ActionName = [32]u8;

/// The box a button answers in, in the frame's pixels as the fingers are;
/// null for one that does not answer now.
fn boxOf(app: *App, entity: Entity, button: TouchButton) ?Box {
    if (!button.shown(app.input.touchscreen)) return null;
    if (!app.isProcessing(entity) or !app.resolvedAppearance(entity).visible) return null;
    var id: [48]u8 = undefined;
    const laid = app.ui.boxOf(control.idOf(&id, entity)) orelse return null;
    return .{ .x = laid.x, .y = laid.y, .width = laid.width, .height = laid.height };
}

const Box = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    fn holds(self: Box, at: @import("fluxion_math").Vec2) bool {
        return at.x >= self.x and at.y >= self.y and at.x < self.x + self.width and at.y < self.y + self.height;
    }
};

/// Where one button stands after this frame's fingers.
fn press(input: *const Input, button: *TouchButton, box: ?Box) void {
    const inside = box orelse {
        button.down = false;
        return;
    };
    if (button.down) {
        const held = input.touchOf(button.finger);
        const kept = if (held) |finger| finger.down() and (!button.passby_press or inside.holds(finger.position)) else false;
        if (kept) return;
        button.down = false;
    }
    for (input.touches()) |finger| {
        if (!finger.down()) continue;
        if (!finger.pressed and !button.passby_press) continue;
        if (!inside.holds(finger.position)) continue;
        button.down = true;
        button.finger = finger.finger;
        return;
    }
}

fn markOnButton(input: *Input, finger: u32) void {
    for (input.fingers[0..input.finger_count]) |*held| {
        if (held.finger == finger and held.down()) held.on_button = true;
    }
}

/// Hold down the actions of the buttons pressed now, and let go of those no
/// button presses any more - two buttons of one action hold it while either
/// is pressed, and a button gone lets go of its own. `App.touch_actions` is
/// what the buttons held last frame.
fn holdActions(app: *App) !void {
    var now: std.ArrayList(ActionName) = .empty;
    errdefer now.deinit(app.gpa);
    var it = try ecs.Query(.{TouchButton}).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(TouchButton)) |*button| {
            if (!button.down or button.actionName().len == 0) continue;
            if (!holds(now.items, button.action)) try now.append(app.gpa, button.action);
        }
    }
    for (now.items) |action| {
        if (holds(app.touch_actions.items, action)) continue;
        const name = fixed_text.get(&action);
        app.input.pressAction(name, 1) catch log.warn("a touch button holds the action \"{s}\", which the project has not", .{name});
    }
    for (app.touch_actions.items) |action| {
        if (holds(now.items, action)) continue;
        app.input.releaseAction(fixed_text.get(&action)) catch {};
    }
    app.touch_actions.deinit(app.gpa);
    app.touch_actions = now;
}

fn holds(list: []const ActionName, action: ActionName) bool {
    for (list) |held| {
        if (std.mem.eql(u8, &held, &action)) return true;
    }
    return false;
}

test "a finger touching inside presses a button until it is lifted; with passby, while it is on it" {
    var input: Input = .{};
    const box: Box = .{ .x = 10, .y = 10, .width = 50, .height = 50 };
    var button: TouchButton = .{};

    // A finger already down that slides on does not press a plain button.
    input.apply(touchOf(1, .down, 100, 100));
    input.endFrame();
    input.beginFrame();
    input.apply(touchOf(1, .move, 20, 20));
    press(&input, &button, box);
    try testing.expect(!button.down);

    // One that touches inside does, and holds it off the button too.
    input.apply(touchOf(2, .down, 30, 30));
    press(&input, &button, box);
    try testing.expect(button.down);
    try testing.expectEqual(@as(u32, 2), button.finger);
    input.endFrame();
    input.beginFrame();
    input.apply(touchOf(2, .move, 200, 200));
    press(&input, &button, box);
    try testing.expect(button.down);
    input.apply(touchOf(2, .up, 200, 200));
    press(&input, &button, box);
    try testing.expect(!button.down);

    // With passby, the finger already down presses it, and sliding off lets go.
    button.passby_press = true;
    press(&input, &button, box);
    try testing.expect(button.down);
    try testing.expectEqual(@as(u32, 1), button.finger);
    input.apply(touchOf(1, .move, 300, 20));
    press(&input, &button, box);
    try testing.expect(!button.down);

    // Not laid out, or hidden: let go.
    input.apply(touchOf(1, .move, 20, 20));
    press(&input, &button, box);
    try testing.expect(button.down);
    press(&input, &button, null);
    try testing.expect(!button.down);
}

const touchOf = @import("../test_helpers.zig").touchOf;
