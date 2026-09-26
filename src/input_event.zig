// SPDX-License-Identifier: BSD-3-Clause

//! One thing the player did, as one value of its own kind: a key, a mouse
//! button, the pointer moving, the wheel turning, a controller's button.
//! What a script's `input(self, event)` and `unhandled_input` are handed -
//! asked which with `is`:
//!
//! ```
//! fn input(self, event: InputEvent) {
//!     if (event.isActionPressed("jump")) self.jump();
//!     if (event is MouseButtonEvent and event.pressed) print(event.button, event.position);
//! }
//! ```
//!
//! The pointer's own - a button, motion, the wheel - are also what picking
//! hands to whatever is under it as `input_event`. This frame's are
//! `app.input.pointerEvents()`, in the order they happened.

const std = @import("std");
const testing = std.testing;

const math = @import("fluxion_math");
const platform = @import("fluxion_platform");
const flux = @import("fluxion_script");

const actions = @import("actions.zig");
const attr = @import("attr.zig");

const Vec2 = math.Vec2;

/// Which mouse buttons are held, one bit each, in `platform.MouseButton`'s
/// order.
pub const ButtonMask = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    button_4: bool = false,
    button_5: bool = false,
    button_6: bool = false,
    button_7: bool = false,
    button_8: bool = false,

    pub const reflect_name = "ButtonMask";

    pub const none: ButtonMask = .{};

    pub fn has(self: ButtonMask, button: platform.MouseButton) bool {
        const i = button.index() orelse return false;
        return (@as(u8, @bitCast(self)) >> @as(u3, @intCast(i))) & 1 != 0;
    }

    pub fn with(self: ButtonMask, button: platform.MouseButton, down: bool) ButtonMask {
        const i = button.index() orelse return self;
        const bit = @as(u8, 1) << @as(u3, @intCast(i));
        const bits = @as(u8, @bitCast(self));
        return @bitCast(if (down) bits | bit else bits & ~bit);
    }

    pub fn any(self: ButtonMask) bool {
        return @as(u8, @bitCast(self)) != 0;
    }
};

/// A key going down, coming up, or held long enough to repeat.
pub const KeyEvent = struct {
    /// The key where it sits on a US keyboard, whatever the player's layout
    /// calls it: a game's WASD.
    key: platform.Key = .unknown,
    /// The key the player's layout names it: what "press E" means.
    virtual_key: platform.Key = .unknown,
    pressed: bool = false,
    /// Held long enough that the system repeats it. Down, as the first was.
    echo: bool = false,
    mods: platform.Mods = .{},

    pub const reflect_name = "KeyEvent";
};

/// A mouse button pressed or let go.
pub const MouseButtonEvent = struct {
    button: platform.MouseButton = .left,
    pressed: bool = false,
    /// The second press of a double click, by the system's own rule.
    double_click: bool = false,
    /// Where the pointer is, in the frame's pixels, as `app.pointerOnScreen()`
    /// says; `app.screenToWorld` takes it into the world.
    position: Vec2 = .zero,
    /// What is held after it.
    buttons: ButtonMask = .none,
    mods: platform.Mods = .{},

    pub const reflect_name = "MouseButtonEvent";
};

/// The pointer moved: one a frame, with the frame's moving added up.
pub const MouseMotionEvent = struct {
    /// In the frame's pixels.
    position: Vec2 = .zero,
    /// How far it moved to get there.
    relative: Vec2 = .zero,
    buttons: ButtonMask = .none,
    mods: platform.Mods = .{},

    pub const reflect_name = "MouseMotionEvent";
};

/// The wheel turned.
pub const WheelEvent = struct {
    /// How many notches, up and right positive.
    delta: Vec2 = .zero,
    /// Where the pointer is, in the frame's pixels.
    position: Vec2 = .zero,
    buttons: ButtonMask = .none,
    mods: platform.Mods = .{},

    pub const reflect_name = "WheelEvent";
};

/// A controller's button pressed or let go.
pub const PadButtonEvent = struct {
    button: platform.GamepadButton = .a,
    /// Which controller: its slot, from 0.
    pad: u8 = 0,
    pressed: bool = false,

    pub const reflect_name = "PadButtonEvent";
};

/// One thing the player did. See the top of the file.
pub const InputEvent = union(enum) {
    key: KeyEvent,
    mouse_button: MouseButtonEvent,
    mouse_motion: MouseMotionEvent,
    wheel: WheelEvent,
    pad_button: PadButtonEvent,

    pub const reflect_name = "InputEvent";
    pub const reflect_methods = .{
        .isAction = .{attr.Params{ .names = &.{ "vm", "action" } }},
        .isActionPressed = .{attr.Params{ .names = &.{ "vm", "action" } }},
        .isActionReleased = .{attr.Params{ .names = &.{ "vm", "action" } }},
        .describe = .{attr.Params{ .names = &.{"vm"} }},
        .isPressed = .{attr.Params{ .names = &.{"button"} }},
        .isReleased = .{attr.Params{ .names = &.{"button"} }},
    };

    /// Whether it is one of the action's inputs.
    pub fn isAction(self: *const InputEvent, vm: *flux.Vm, action: []const u8) bool {
        return self.sets(&script.appOf(vm).input.actions, action);
    }

    /// Whether it is one of the action's inputs going down - not a repeat.
    pub fn isActionPressed(self: *const InputEvent, vm: *flux.Vm, action: []const u8) bool {
        return self.isDown() and !self.isEcho() and self.isAction(vm, action);
    }

    /// Whether it is one of the action's inputs coming up.
    pub fn isActionReleased(self: *const InputEvent, vm: *flux.Vm, action: []const u8) bool {
        return self.binding() != null and !self.isDown() and self.isAction(vm, action);
    }

    /// What the player pressed, in words: `Space`, `Left Mouse`, `Pad A`.
    /// Empty for motion and the wheel.
    pub fn describe(self: *const InputEvent, vm: *flux.Vm) []const u8 {
        const bound = self.binding() orelse return "";
        return script.describe(vm, bound);
    }

    /// Whether it is the mouse button `button` being pressed: what a
    /// handler of the pointer asks first.
    ///
    /// ```zig
    /// if (event.isPressed(.left)) open(app, self);
    /// ```
    pub fn isPressed(self: *const InputEvent, button: platform.MouseButton) bool {
        return switch (self.*) {
            .mouse_button => |b| b.pressed and b.button == button,
            else => false,
        };
    }

    pub fn isReleased(self: *const InputEvent, button: platform.MouseButton) bool {
        return switch (self.*) {
            .mouse_button => |b| !b.pressed and b.button == button,
            else => false,
        };
    }

    /// Where the pointer is, for the pointer's events; null for a key's and
    /// a controller's.
    pub fn position(self: InputEvent) ?Vec2 {
        return switch (self) {
            .mouse_button => |b| b.position,
            .mouse_motion => |m| m.position,
            .wheel => |w| w.position,
            .key, .pad_button => null,
        };
    }

    /// The same event with the pointer somewhere else: an entity's own space.
    pub fn at(self: InputEvent, place: Vec2) InputEvent {
        var moved = self;
        switch (moved) {
            .mouse_button => |*b| b.position = place,
            .mouse_motion => |*m| m.position = place,
            .wheel => |*w| w.position = place,
            .key, .pad_button => {},
        }
        return moved;
    }

    pub fn buttons(self: InputEvent) ButtonMask {
        return switch (self) {
            .mouse_button => |b| b.buttons,
            .mouse_motion => |m| m.buttons,
            .wheel => |w| w.buttons,
            .key, .pad_button => .none,
        };
    }

    pub fn mods(self: InputEvent) platform.Mods {
        return switch (self) {
            .key => |k| k.mods,
            .mouse_button => |b| b.mods,
            .mouse_motion => |m| m.mods,
            .wheel => |w| w.mods,
            .pad_button => .{},
        };
    }

    /// The input it is, as an action binds it: what `app.bindAction` gives
    /// the action. Null for motion and the wheel.
    pub fn binding(self: InputEvent) ?actions.Binding {
        return switch (self) {
            .key => |k| .keyOf(k.key),
            .mouse_button => |b| .mouseButtonOf(b.button),
            .pad_button => |p| .padButtonOf(p.button),
            .mouse_motion, .wheel => null,
        };
    }

    fn isDown(self: *const InputEvent) bool {
        return switch (self.*) {
            .key => |k| k.pressed,
            .mouse_button => |b| b.pressed,
            .pad_button => |p| p.pressed,
            .mouse_motion, .wheel => false,
        };
    }

    fn isEcho(self: *const InputEvent) bool {
        return self.* == .key and self.key.echo;
    }

    /// Whether it is one of `action`'s inputs in `map`.
    pub fn sets(self: *const InputEvent, map: *const actions.Actions, action: []const u8) bool {
        const entry = map.findConst(action) orelse return false;
        for (entry.bindings.items) |bound| {
            if (self.is(bound)) return true;
        }
        return false;
    }

    fn is(self: *const InputEvent, bound: actions.Binding) bool {
        return switch (bound) {
            .key => |held| self.* == .key and (if (held.physical) held.key == self.key.key else held.key == self.key.virtual_key),
            .mouse_button => |held| self.* == .mouse_button and held.button == self.mouse_button.button,
            .pad_button => |held| self.* == .pad_button and held.button == self.pad_button.button and (held.pad == null or held.pad.? == self.pad_button.pad),
            .pad_axis => false,
        };
    }
};

const script = @import("script.zig");

test "a mask holds the button it was given, and lets it go" {
    var mask: ButtonMask = .none;
    try testing.expect(!mask.any());
    mask = mask.with(.left, true).with(.button_4, true);
    try testing.expect(mask.has(.left));
    try testing.expect(mask.has(.button_4));
    try testing.expect(!mask.has(.right));
    try testing.expect(mask.left and mask.button_4);
    mask = mask.with(.left, false);
    try testing.expect(!mask.has(.left));
    try testing.expect(mask.any());
}

test "an event says what it is, whichever kind it is" {
    const moved: InputEvent = .{ .mouse_motion = .{ .position = .init(4, 5), .relative = .init(1, 0) } };
    try testing.expectEqual(@as(f32, 4), moved.position().?.x);
    try testing.expect(!moved.isPressed(.left));

    const clicked: InputEvent = .{ .mouse_button = .{
        .button = .left,
        .pressed = true,
        .position = .init(4, 5),
        .buttons = ButtonMask.none.with(.left, true),
    } };
    try testing.expect(clicked.isPressed(.left));
    try testing.expect(!clicked.isReleased(.left));
    try testing.expect(clicked.buttons().has(.left));
    try testing.expectEqual(@as(f32, 9), clicked.at(.init(9, 9)).position().?.x);

    const key: InputEvent = .{ .key = .{ .key = .space, .pressed = true } };
    try testing.expect(key.position() == null);
    try testing.expect(key.binding().?.eql(.keyOf(.space)));
    try testing.expect((InputEvent{ .wheel = .{ .delta = .init(0, 1) } }).binding() == null);
}
