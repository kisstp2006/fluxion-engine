// SPDX-License-Identifier: BSD-3-Clause

//! What the pointer did, as one event: an `InputEventMouseButton` or an
//! `InputEventMouseMotion`. This frame's are `app.input.pointerEvents()`, in
//! the order they happened, and picking hands each one to whatever is under
//! it as `input_event`.

const std = @import("std");
const testing = std.testing;

const math = @import("fluxion_math");
const platform = @import("fluxion_platform");

const Vec2 = math.Vec2;

/// A button of the pointer, the wheel's four directions among them. The
/// mouse's own buttons keep the numbers `fx.MouseButton` gives them; the
/// wheel's come after.
pub const PointerButton = enum(u8) {
    left = 0,
    right = 1,
    middle = 2,
    wheel_up = 3,
    wheel_down = 4,
    wheel_left = 5,
    wheel_right = 6,
    button_4 = 7,
    button_5 = 8,
    button_6 = 9,
    button_7 = 10,
    button_8 = 11,

    pub const reflect_name = "PointerButton";

    /// The same button as the system reports it, or null for one past the
    /// eight this knows.
    pub fn of(button: platform.MouseButton) ?PointerButton {
        return switch (@intFromEnum(button)) {
            0 => .left,
            1 => .right,
            2 => .middle,
            3 => .button_4,
            4 => .button_5,
            5 => .button_6,
            6 => .button_7,
            7 => .button_8,
            else => null,
        };
    }

    pub fn isWheel(self: PointerButton) bool {
        return switch (self) {
            .wheel_up, .wheel_down, .wheel_left, .wheel_right => true,
            else => false,
        };
    }
};

/// Which buttons are held, one bit each. A wheel's bit is set only in the
/// press that turns it.
pub const ButtonMask = packed struct(u16) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    wheel_up: bool = false,
    wheel_down: bool = false,
    wheel_left: bool = false,
    wheel_right: bool = false,
    button_4: bool = false,
    button_5: bool = false,
    button_6: bool = false,
    button_7: bool = false,
    button_8: bool = false,
    _: u4 = 0,

    pub const reflect_name = "ButtonMask";

    pub const none: ButtonMask = .{};

    pub fn has(self: ButtonMask, button: PointerButton) bool {
        return (@as(u16, @bitCast(self)) >> @as(u4, @intCast(@intFromEnum(button)))) & 1 != 0;
    }

    pub fn with(self: ButtonMask, button: PointerButton, down: bool) ButtonMask {
        const bit = @as(u16, 1) << @as(u4, @intCast(@intFromEnum(button)));
        const bits = @as(u16, @bitCast(self));
        return @bitCast(if (down) bits | bit else bits & ~bit);
    }

    pub fn any(self: ButtonMask) bool {
        return @as(u16, @bitCast(self)) != 0;
    }
};

/// A button pressed or let go, or a wheel notch, which is reported as a
/// press and a release of a wheel button.
pub const InputEventMouseButton = struct {
    button: PointerButton,
    pressed: bool,
    /// The second press of a double click, by the system's own rule.
    double_click: bool = false,
    /// How many notches a wheel event turned; one for a button.
    factor: f32 = 1,
    /// In the window's pixels, as `input.pointer` is. `App.screenToWorld`
    /// takes it into the world.
    position: Vec2,
    /// What is held after this event.
    button_mask: ButtonMask = .none,
    mods: platform.Mods = .{},

    pub const reflect_name = "InputEventMouseButton";
};

/// The pointer moved. One event a frame, with all of the frame's motion
/// added up.
pub const InputEventMouseMotion = struct {
    /// In the window's pixels.
    position: Vec2,
    /// How far it moved to get here.
    relative: Vec2 = .zero,
    button_mask: ButtonMask = .none,
    mods: platform.Mods = .{},

    pub const reflect_name = "InputEventMouseMotion";
};

/// One thing the pointer did. What an `input_event` signal is handed.
pub const InputEvent = union(enum) {
    mouse_button: InputEventMouseButton,
    mouse_motion: InputEventMouseMotion,

    pub const reflect_name = "InputEvent";

    /// Where it happened, in the window's pixels.
    pub fn position(self: InputEvent) Vec2 {
        return switch (self) {
            inline else => |held| held.position,
        };
    }

    pub fn buttonMask(self: InputEvent) ButtonMask {
        return switch (self) {
            inline else => |held| held.button_mask,
        };
    }

    pub fn mods(self: InputEvent) platform.Mods {
        return switch (self) {
            inline else => |held| held.mods,
        };
    }

    /// Whether it is that button being pressed: what a handler asks first.
    ///
    /// ```zig
    /// if (event.isPressed(.left)) open(app, self);
    /// ```
    pub fn isPressed(self: InputEvent, button: PointerButton) bool {
        return switch (self) {
            .mouse_button => |b| b.pressed and b.button == button,
            .mouse_motion => false,
        };
    }

    pub fn isReleased(self: InputEvent, button: PointerButton) bool {
        return switch (self) {
            .mouse_button => |b| !b.pressed and b.button == button,
            .mouse_motion => false,
        };
    }
};

test "a mask holds the button it was given, and lets it go" {
    var mask: ButtonMask = .none;
    try testing.expect(!mask.any());
    mask = mask.with(.left, true).with(.wheel_up, true);
    try testing.expect(mask.has(.left));
    try testing.expect(mask.has(.wheel_up));
    try testing.expect(!mask.has(.right));
    try testing.expect(mask.left and mask.wheel_up);
    mask = mask.with(.left, false);
    try testing.expect(!mask.has(.left));
    try testing.expect(mask.any());
}

test "the system's buttons keep their numbers, and the wheel comes after" {
    try testing.expectEqual(PointerButton.left, PointerButton.of(.left).?);
    try testing.expectEqual(PointerButton.button_4, PointerButton.of(.button_4).?);
    try testing.expect(PointerButton.of(@enumFromInt(9)) == null);
    try testing.expect(PointerButton.wheel_down.isWheel());
    try testing.expect(!PointerButton.middle.isWheel());
}

test "an event says what it is, whichever kind it is" {
    const moved: InputEvent = .{ .mouse_motion = .{ .position = .init(4, 5), .relative = .init(1, 0) } };
    try testing.expectEqual(@as(f32, 4), moved.position().x);
    try testing.expect(!moved.isPressed(.left));

    const clicked: InputEvent = .{ .mouse_button = .{
        .button = .left,
        .pressed = true,
        .position = .init(4, 5),
        .button_mask = ButtonMask.none.with(.left, true),
    } };
    try testing.expect(clicked.isPressed(.left));
    try testing.expect(!clicked.isReleased(.left));
    try testing.expect(clicked.buttonMask().has(.left));
}
