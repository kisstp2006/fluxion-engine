// SPDX-License-Identifier: BSD-3-Clause

//! Controllers: each slot's buttons and axes as they stood at the top of
//! the frame, with the same levels and edges as a key, and one controller -
//! or every one at once - to ask questions of, its dead zones taken out.

const std = @import("std");

const math = @import("fluxion_math");
const platform = @import("fluxion_platform");

const Input = @import("input.zig");

const Vec2 = math.Vec2;
const max_pads = Input.max_pads;

/// The fifteen buttons a mapped controller has, one bit each.
pub const PadButtons = std.StaticBitSet(platform.GamepadButton.count);

/// One controller slot, as it stood at the top of this frame. Built by
/// `readPads`, with the same levels and edges as a key.
pub const PadState = struct {
    connected: bool = false,
    down: PadButtons = .initEmpty(),
    pressed: PadButtons = .initEmpty(),
    released: PadButtons = .initEmpty(),
    fixed_pressed: PadButtons = .initEmpty(),
    fixed_released: PadButtons = .initEmpty(),
    /// With no dead zone: a stick from -1 to 1 on each axis, up negative, and
    /// a trigger from 0 to 1.
    axes: [platform.GamepadAxis.count]f32 = @splat(0),
};

/// Which of a controller's two sticks.
pub const Side = enum { left, right };

/// One controller, or every controller at once, to ask questions of. A view
/// rather than a copy, so in a `.fixed` system it answers from the fixed
/// step's edges like everything else here.
pub const Pad = struct {
    input: *const Input,
    /// Which slot, or null for every connected one.
    slot: ?usize,

    /// The slots this view reads: one, or all of them.
    fn states(self: Pad) []const PadState {
        const slot = self.slot orelse return &self.input.pads;
        if (slot >= max_pads) return &.{};
        return self.input.pads[slot .. slot + 1];
    }

    /// Is something plugged into this slot - or, for `anyPad`, into any?
    pub fn connected(self: Pad) bool {
        for (self.states()) |state| {
            if (state.connected) return true;
        }
        return false;
    }

    /// Is this button held down now?
    pub fn down(self: Pad, button: platform.GamepadButton) bool {
        const i = @intFromEnum(button);
        for (self.states()) |state| {
            if (state.down.isSet(i)) return true;
        }
        return false;
    }

    /// Did it go down this frame - or, in a `.fixed` system, since the last
    /// fixed step?
    pub fn justPressed(self: Pad, button: platform.GamepadButton) bool {
        const i = @intFromEnum(button);
        for (self.states()) |*state| {
            const edges = if (self.input.clock == .fixed) &state.fixed_pressed else &state.pressed;
            if (edges.isSet(i)) return true;
        }
        return false;
    }

    /// Did it come up this frame - or since the last fixed step?
    pub fn justReleased(self: Pad, button: platform.GamepadButton) bool {
        const i = @intFromEnum(button);
        for (self.states()) |*state| {
            const edges = if (self.input.clock == .fixed) &state.fixed_released else &state.released;
            if (edges.isSet(i)) return true;
        }
        return false;
    }

    /// A stick with its dead zone taken out: zero until it leans past
    /// `Input.stick_deadzone`, then rising to a length of one. Up is negative.
    /// The dead zone is round, so a diagonal does not snap to an axis, and
    /// the length stops at one, so a corner is no faster. For `anyPad`, the
    /// stick leaning furthest, so two resting sticks do not add up to a drift.
    pub fn stick(self: Pad, side: Side) Vec2 {
        const axes: [2]platform.GamepadAxis = switch (side) {
            .left => .{ .left_x, .left_y },
            .right => .{ .right_x, .right_y },
        };
        var furthest: Vec2 = .zero;
        for (self.states()) |state| {
            if (!state.connected) continue;
            const leaning = roundDeadzone(
                state.axes[@intFromEnum(axes[0])],
                state.axes[@intFromEnum(axes[1])],
                self.input.stick_deadzone,
            );
            if (leaning.lenSq() > furthest.lenSq()) furthest = leaning;
        }
        return furthest;
    }

    /// One axis, with its dead zone taken out. A stick's axis agrees with
    /// `stick`; a trigger reads from zero to one.
    pub fn axis(self: Pad, which: platform.GamepadAxis) f32 {
        return switch (which) {
            .left_x => self.stick(.left).x,
            .left_y => self.stick(.left).y,
            .right_x => self.stick(.right).x,
            .right_y => self.stick(.right).y,
            .left_trigger, .right_trigger => self.trigger(which),
        };
    }

    fn trigger(self: Pad, which: platform.GamepadAxis) f32 {
        const dead = std.math.clamp(self.input.trigger_deadzone, 0, 0.99);
        var most: f32 = 0;
        for (self.states()) |state| {
            if (!state.connected) continue;
            const raw = state.axes[@intFromEnum(which)];
            if (raw <= dead) continue;
            most = @max(most, @min((raw - dead) / (1 - dead), 1));
        }
        return most;
    }
};

/// A stick position with a round dead zone taken out, rescaled so the edge of
/// the zone is zero and full tilt is one - so there is no jump at the edge.
fn roundDeadzone(x: f32, y: f32, deadzone: f32) Vec2 {
    const dead = std.math.clamp(deadzone, 0, 0.99);
    const length = @sqrt(x * x + y * y);
    if (length <= dead) return .zero;
    const rescaled = (@min(length, 1) - dead) / (1 - dead);
    return .init(x / length * rescaled, y / length * rescaled);
}

/// Everything that moves one axis - two keys, a second two, a controller's
/// stick and two of its buttons - as plain data. Read with `Input.axisOf`.
///
/// ```zig
/// const Paddle = extern struct { move: AxisBinding, speed: f32 = 300 };
///
/// .move = AxisBinding.keys(.w, .s).withPadY(0),         // spawn
/// speed.y = app.input.axisOf(paddle.move) * paddle.speed; // drive
/// ```
///
/// Plain numbers, so it can live in a component and in a save: `platform.Key`
/// is a non-exhaustive enum, which neither fluxion-data nor fluxion-ecs will
/// take. The builders take the enums.
pub const AxisBinding = extern struct {
    /// The keys that push towards -1 and towards 1, in two pairs - WASD and
    /// the arrows. `no_key` for none.
    negative: [2]i32 = @splat(no_key),
    positive: [2]i32 = @splat(no_key),

    /// Which controller slot, or `any_pad` for whichever is being used.
    pad: u8 = any_pad,
    /// Which of its axes, as `GamepadAxis`'s number, or `no_pad_input`.
    pad_axis: u8 = no_pad_input,
    /// Which of its buttons push towards -1 and towards 1 - the d-pad,
    /// usually - as `GamepadButton`'s numbers, or `no_pad_input`.
    pad_negative: u8 = no_pad_input,
    pad_positive: u8 = no_pad_input,

    /// No key: `Key.unknown`'s number, which is never down.
    pub const no_key: i32 = @intFromEnum(platform.Key.unknown);
    /// Every connected controller at once. See `Input.anyPad`.
    pub const any_pad: u8 = 0xFF;
    /// No axis or button. Past the end of both lists, so an out-of-range
    /// number read from a file means the same.
    pub const no_pad_input: u8 = 0xFF;

    /// Two keys: the first pushes towards -1, the second towards 1.
    pub fn keys(negative: platform.Key, positive: platform.Key) AxisBinding {
        return .{
            .negative = .{ @intFromEnum(negative), no_key },
            .positive = .{ @intFromEnum(positive), no_key },
        };
    }

    /// A second pair of keys on the same axis.
    pub fn orKeys(self: AxisBinding, negative: platform.Key, positive: platform.Key) AxisBinding {
        var out = self;
        out.negative[1] = @intFromEnum(negative);
        out.positive[1] = @intFromEnum(positive);
        return out;
    }

    /// The left stick's horizontal axis and the d-pad's left and right, on
    /// controller `slot` or on `any_pad`.
    pub fn withPadX(self: AxisBinding, slot: u8) AxisBinding {
        return self.withPad(slot, .left_x, .dpad_left, .dpad_right);
    }

    /// The left stick's vertical axis and the d-pad's up and down. Up is -1,
    /// as with the world's `y`.
    pub fn withPadY(self: AxisBinding, slot: u8) AxisBinding {
        return self.withPad(slot, .left_y, .dpad_up, .dpad_down);
    }

    fn withPad(
        self: AxisBinding,
        slot: u8,
        axis: platform.GamepadAxis,
        negative: platform.GamepadButton,
        positive: platform.GamepadButton,
    ) AxisBinding {
        var out = self;
        out.pad = slot;
        out.pad_axis = @intFromEnum(axis);
        out.pad_negative = @intFromEnum(negative);
        out.pad_positive = @intFromEnum(positive);
        return out;
    }
};
