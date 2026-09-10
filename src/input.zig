// SPDX-License-Identifier: BSD-3-Clause

//! What the keyboard, the mouse and the controllers did, as a thing to ask
//! rather than a thing to be told.
//!
//! ```zig
//! fn steer(app: *App) !void {
//!     const x = app.input.axisOf(.keys(.a, .d)); // -1, 0 or 1
//!     if (app.input.justPressed(.space)) jump();
//!     if (app.input.buttonDown(.left)) shoot(app.input.pointer.x, app.input.pointer.y);
//!
//!     const pad = app.input.anyPad();
//!     const walk = pad.stick(.left);             // dead zone already out
//!     if (pad.justPressed(.a)) jump();
//! }
//! ```
//!
//! [Fluxion Platform](https://github.com/kisstp2006/fluxion-platform) delivers
//! events - key down, key up, one at a time, in order. A game asks questions -
//! is the key down *now*, did it go down *this frame*. This is the thing in
//! between: every event of a frame is folded in as it arrives, and what is
//! left when the loop reaches the systems is a snapshot they can all read
//! without caring who asked first.
//!
//! **Three sets, not one.** `down` is a level and `pressed` and `released`
//! are edges, and a game needs all three: a held key steers, a pressed key
//! jumps, and a released key throws what was being charged. Deriving the
//! edges from last frame's levels would be the same information; keeping them
//! separately is what makes a key that went down *and* up inside one frame
//! still count, which on a slow frame or a fast finger really happens.
//!
//! **The edges are cleared at the top of the next frame**, not at the bottom
//! of this one, so a system that runs late in the frame sees the same edges
//! as one that ran early. `beginFrame` is what does it, and `App` calls it
//! before any event of the new frame is read.
//!
//! **A fixed step counts its own edges.** The `.fixed` stage runs as many
//! times as the frame was worth, which on a fast screen is usually none - at
//! a hundred and forty-four hertz, five frames in twelve run a step - so an
//! edge that lasted one frame was missed by more than half the jumps read
//! there, and seen twice on a slow frame that ran two steps. So every edge
//! also goes into a second set that is cleared only after a fixed step has
//! run, and while `App` runs that stage, `justPressed` and the rest answer
//! from it: one press, one jump, whatever the frame rate. See `clock`. What
//! is counted per frame and has no second set - `pointer.dx` and `dy`,
//! `wheel`, `typed` - belongs in the stages that run once a frame.
//!
//! **A controller is read, not heard.** A stick is a position rather than a
//! thing that happened, so the platform polls every controller once a frame
//! and `readPads` compares what it found with what it found last time: that
//! difference is a controller's "pressed this frame", and it goes into both
//! sets of edges exactly as a key's does. `pad(slot)` asks one controller and
//! `anyPad()` asks all of them at once, which is what a game with one player
//! wants - whichever controller they picked up, it works.
//!
//! **What moves an axis is data.** Two keys, a second two, a stick and two
//! controller buttons, all held in one `AxisBinding` a component can carry and
//! a save can keep, and read with `axisOf` - the one place where sources are
//! added together. Everything else here reads one source: a key, a button, a
//! stick.

const std = @import("std");
const testing = std.testing;

const platform = @import("fluxion_platform");
const math = @import("fluxion_math");

const Vec2 = math.Vec2;

const Input = @This();

/// One past the largest `Key`, which is `menu` at 348. The keys are at GLFW's
/// own numbers, so the range is sparse - a few hundred bits, most of them
/// never set. Forty-four bytes of waste per set, against a hash lookup on
/// every key press: the array wins and is not close.
pub const key_span = 349;

/// The buttons a `MouseButton` can be, which is eight.
pub const button_span = platform.keys.MouseButton.max + 1;

const Keys = std.StaticBitSet(key_span);
const Buttons = std.StaticBitSet(button_span);

/// Keys held down right now.
down: Keys = .initEmpty(),
/// Keys that went down during this frame.
pressed: Keys = .initEmpty(),
/// Keys that came up during this frame.
released: Keys = .initEmpty(),

/// Mouse buttons, the same three ways.
button_down: Buttons = .initEmpty(),
button_pressed: Buttons = .initEmpty(),
button_released: Buttons = .initEmpty(),

/// The four sets of edges again, counted since the last fixed step rather
/// than since the top of the frame. What the questions below answer from
/// while `clock` is `.fixed`.
fixed_pressed: Keys = .initEmpty(),
fixed_released: Keys = .initEmpty(),
fixed_button_pressed: Buttons = .initEmpty(),
fixed_button_released: Buttons = .initEmpty(),

/// Which edges `justPressed` and the rest answer from.
///
/// A mode rather than a second set of functions, because the bug it fixes is
/// a game calling `justPressed` from a `.fixed` system - and a function the
/// game had to remember to call instead would leave that line exactly as
/// wrong as it was. `App` sets this around the fixed stage and puts it back
/// afterwards; nothing else should touch it.
clock: Clock = .frame,

/// Where the pointer is, in pixels from the top left of the content area,
/// and how far it moved this frame.
pointer: Pointer = .{},

/// How far the wheel turned this frame. Positive `y` is away from the user,
/// which is what every platform reports and the opposite of what a scrolling
/// list wants - so the interface layer negates it, once, where it is used.
wheel: Wheel = .{},

/// What was held down when the last event arrived. Shift, control, alt.
mods: platform.Mods = .{},

/// Everything typed this frame, in the order it was typed.
///
/// Two kinds, because a text field needs both: a `character` is a codepoint
/// the user meant, and a `key` is a key that may mean an edit - backspace,
/// left arrow, control and A. Which key means which edit is a decision, and
/// `editAction` makes it in one place rather than in every game.
typed: [typed_capacity]Typed = undefined,
typed_len: usize = 0,

/// Every controller slot, as it stood at the top of this frame. Asked
/// through `pad` and `anyPad`, which is where the dead zones and the clock
/// are applied.
pads: [max_pads]PadState = @splat(.{}),

/// How far a stick has to lean before it counts, as a fraction of full tilt.
///
/// A stick that has been used for a year does not come back to exactly the
/// middle, and a camera steered by the raw number drifts for ever. A fifth is
/// enough for a worn stick and little enough that a gentle push still moves
/// something; a settings screen can hand it to the player.
stick_deadzone: f32 = 0.2,

/// The same for a trigger, which rests more reliably and wants less.
trigger_deadzone: f32 = 0.1,

/// Whether the window has the keyboard, from the platform's focus events.
/// For a game that pauses when nobody is looking at it.
focused: bool = true,

/// How much typing one frame can hold. A fast typist manages about twenty
/// characters a second, so this is more than a frame will ever see.
pub const typed_capacity = 32;

/// How many controllers can be told apart: `fluxion-platform`'s slots.
pub const max_pads = platform.gamepad.max_devices;

/// The fifteen buttons a mapped controller has, one bit each.
const PadButtons = std.StaticBitSet(platform.GamepadButton.count);

/// One controller slot, as it stood at the top of this frame.
///
/// Built by `readPads` from what the platform polled. The same levels and
/// edges as a key, and the same second set of edges for the fixed step.
pub const PadState = struct {
    connected: bool = false,
    down: PadButtons = .initEmpty(),
    pressed: PadButtons = .initEmpty(),
    released: PadButtons = .initEmpty(),
    fixed_pressed: PadButtons = .initEmpty(),
    fixed_released: PadButtons = .initEmpty(),
    /// As the platform reports them, with no dead zone: a stick from -1 to
    /// 1 on each axis with up negative - the same way round as the world -
    /// and a trigger from 0 to 1.
    axes: [platform.GamepadAxis.count]f32 = @splat(0),
};

/// Which of a controller's two sticks.
pub const Side = enum { left, right };

/// One controller, or every controller at once, to ask questions of.
///
/// A view rather than a copy: it holds the `Input` it came from and reads it
/// when asked, so a `Pad` in a `.fixed` system answers from the fixed step's
/// edges like everything else here. See `clock`.
pub const Pad = struct {
    input: *const Input,
    /// Which slot, or null for every connected one. See `anyPad`.
    slot: ?usize,

    /// The slots this view reads: one, or all of them.
    fn states(self: Pad) []const PadState {
        const slot = self.slot orelse return &self.input.pads;
        if (slot >= max_pads) return &.{};
        return self.input.pads[slot .. slot + 1];
    }

    /// Is something plugged into this slot? For `anyPad`, into any slot?
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

    /// A stick, with its dead zone taken out: nothing at all until it leans
    /// past `Input.stick_deadzone`, then rising from zero to a length of one
    /// at full tilt. Up is negative, like the world's `y`.
    ///
    /// **Round, not square.** The dead zone is on how far the stick is from
    /// the middle rather than on each axis separately, because a square one
    /// snaps a nearly diagonal push onto the nearest axis, and the player
    /// feels the stick catch on straight lines. And never longer than one,
    /// because some sticks report more than full tilt on both axes at once in
    /// the corners, which would make a diagonal faster than a straight line.
    ///
    /// For `anyPad`, whichever stick is leaning furthest - so two controllers
    /// resting slightly off centre do not add up to a drift.
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

    /// One axis, with its dead zone taken out. A stick's axis is that
    /// component of `stick`, so the two always agree; a trigger rests at zero
    /// and reads up to one.
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

/// A stick position with a round dead zone taken out of it: zero inside,
/// then rescaled so the edge of the dead zone is zero and full tilt is one.
/// Rescaled rather than cut, so the first movement past the edge is a small
/// one and not a jump to a fifth of full speed.
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
/// **Data, so it can live in a component and in a saved game** - which is
/// what makes a player's remapped controls a thing that is saved rather than
/// a config file to parse. Every field is a number for that reason:
/// `platform.Key` has an open `_` for keys the list does not name, and an enum
/// like that cannot be written down, so `fluxion-data` refuses it and
/// `fluxion-ecs` refuses it in a component. The builders below take the
/// enums, and nothing else has to see the numbers; a settings screen that
/// rebinds a key writes the field.
pub const AxisBinding = extern struct {
    /// The keys that push towards -1 and towards 1: a pair, and a second
    /// pair for the same axis - WASD and the arrows. `no_key` for none.
    negative: [2]i32 = @splat(no_key),
    positive: [2]i32 = @splat(no_key),

    /// Which controller slot, or `any_pad` for whichever is being used.
    pad: u8 = any_pad,
    /// Which of its axes, as `GamepadAxis`'s number, or `no_pad_input`.
    pad_axis: u8 = no_pad_input,
    /// Which of its buttons push towards -1 and towards 1, as
    /// `GamepadButton`'s numbers - the d-pad, usually - or `no_pad_input`.
    pad_negative: u8 = no_pad_input,
    pad_positive: u8 = no_pad_input,

    /// No key: `Key.unknown`'s number, which is never down.
    pub const no_key: i32 = @intFromEnum(platform.Key.unknown);
    /// Every connected controller at once. See `Input.anyPad`.
    pub const any_pad: u8 = 0xFF;
    /// No axis or button on the controller. Past the end of both lists, so
    /// an out-of-range number read from a file means the same thing.
    pub const no_pad_input: u8 = 0xFF;

    /// Two keys: the first pushes towards -1, the second towards 1.
    pub fn keys(negative: platform.Key, positive: platform.Key) AxisBinding {
        return .{
            .negative = .{ @intFromEnum(negative), no_key },
            .positive = .{ @intFromEnum(positive), no_key },
        };
    }

    /// The same, with a second pair on the same axis: WASD and the arrows.
    pub fn orKeys(self: AxisBinding, negative: platform.Key, positive: platform.Key) AxisBinding {
        var out = self;
        out.negative[1] = @intFromEnum(negative);
        out.positive[1] = @intFromEnum(positive);
        return out;
    }

    /// The same, with the left stick's horizontal axis and the d-pad's left
    /// and right, on controller `slot` or on `any_pad`.
    pub fn withPadX(self: AxisBinding, slot: u8) AxisBinding {
        return self.withPad(slot, .left_x, .dpad_left, .dpad_right);
    }

    /// The same, with the left stick's vertical axis and the d-pad's up and
    /// down. Up is -1, the same way round as the world's `y`.
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

/// Which edges the questions answer from. See `clock`.
pub const Clock = enum {
    /// Since the top of this frame. What every stage but `.fixed` sees.
    frame,
    /// Since the last fixed step ran. What `.fixed` sees.
    fixed,
};

pub const Pointer = struct {
    x: f32 = 0,
    y: f32 = 0,
    dx: f32 = 0,
    dy: f32 = 0,
    /// Whether the pointer is over the window at all. A game that hides the
    /// crosshair when the mouse leaves wants this.
    inside: bool = true,

    /// Whether the cursor is locked. See `App.setCursor`.
    ///
    /// While it is, `x` and `y` hold still where the pointer was when it was
    /// locked, and only `dx` and `dy` move. A locked pointer has been taken
    /// out of the picture and the platform reports it at nought, nought;
    /// passing that on would throw a crosshair into the corner, and where it
    /// last was is the more useful thing to go on saying - it is also where
    /// the pointer comes back when it is let go. Set by `App`, and nothing
    /// else should touch it.
    locked: bool = false,
};

pub const Wheel = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Typed = union(enum) {
    character: u21,
    key: platform.event.KeyEvent,
};

// -------------------------------------------------------------------------
// Asking
// -------------------------------------------------------------------------

/// Turn a key into an index, or say it has none.
///
/// `Key` is an `enum(i32)` at GLFW's numbers with `unknown` at -1, so this is
/// not `@intFromEnum` on its own: a negative index into a bit set is a crash
/// in a debug build and something worse in a release one.
inline fn indexOf(key: platform.Key) ?usize {
    const raw = @intFromEnum(key);
    if (raw < 0 or raw >= key_span) return null;
    return @intCast(raw);
}

/// Is this key down now?
pub fn isDown(self: *const Input, key: platform.Key) bool {
    return if (indexOf(key)) |i| self.down.isSet(i) else false;
}

/// Did it go down this frame - or, in a `.fixed` system, since the last
/// fixed step? See `clock`.
pub fn justPressed(self: *const Input, key: platform.Key) bool {
    const edges = if (self.clock == .fixed) &self.fixed_pressed else &self.pressed;
    return if (indexOf(key)) |i| edges.isSet(i) else false;
}

/// Did it come up this frame - or since the last fixed step?
pub fn justReleased(self: *const Input, key: platform.Key) bool {
    const edges = if (self.clock == .fixed) &self.fixed_released else &self.released;
    return if (indexOf(key)) |i| edges.isSet(i) else false;
}

pub fn buttonDown(self: *const Input, button: platform.MouseButton) bool {
    const i = @intFromEnum(button);
    return i < button_span and self.button_down.isSet(i);
}

pub fn buttonJustPressed(self: *const Input, button: platform.MouseButton) bool {
    const edges = if (self.clock == .fixed) &self.fixed_button_pressed else &self.button_pressed;
    const i = @intFromEnum(button);
    return i < button_span and edges.isSet(i);
}

pub fn buttonJustReleased(self: *const Input, button: platform.MouseButton) bool {
    const edges = if (self.clock == .fixed) &self.fixed_button_released else &self.button_released;
    const i = @intFromEnum(button);
    return i < button_span and edges.isSet(i);
}

/// How far a binding says its axis is pushed, from -1 to 1.
///
/// ```zig
/// const dx = input.axisOf(.keys(.a, .d));
/// const dy = input.axisOf(AxisBinding.keys(.w, .s).orKeys(.up, .down));
/// ```
///
/// Every source the binding names is added up and the sum held to that
/// range, so any of them works and all of them at once is no faster. The
/// keys at one end count once however many of them are down, and both ends
/// held is a standstill rather than whichever was pressed last: the
/// alternative needs the order the keys arrived in, which means state, and a
/// player resting a thumb on both expects to stop. A stick is read with its
/// dead zone taken out. See `AxisBinding`.
pub fn axisOf(self: *const Input, binding: AxisBinding) f32 {
    var sum = self.anyKeyOf(binding.positive) - self.anyKeyOf(binding.negative);

    const controller = if (binding.pad == AxisBinding.any_pad) self.anyPad() else self.pad(binding.pad);
    // Checked against the ends of both lists, so a number out of range - a
    // saved binding from a build that had more buttons, or `no_pad_input` -
    // is no input rather than an enum that does not exist.
    if (binding.pad_axis < platform.GamepadAxis.count) {
        sum += controller.axis(@enumFromInt(binding.pad_axis));
    }
    if (binding.pad_positive < platform.GamepadButton.count and controller.down(@enumFromInt(binding.pad_positive))) {
        sum += 1;
    }
    if (binding.pad_negative < platform.GamepadButton.count and controller.down(@enumFromInt(binding.pad_negative))) {
        sum -= 1;
    }
    return std.math.clamp(sum, -1, 1);
}

/// One if any of these keys is down, and zero if none is: two keys held for
/// the same end of an axis count once.
fn anyKeyOf(self: *const Input, keys: [2]i32) f32 {
    for (keys) |raw| {
        if (self.isDown(@enumFromInt(raw))) return 1;
    }
    return 0;
}

/// Whether anything at all is held down, for an attract screen that ends when
/// the player touches something.
pub fn anyKeyDown(self: *const Input) bool {
    return self.down.count() != 0;
}

/// What was typed this frame, oldest first.
pub fn typedThisFrame(self: *const Input) []const Typed {
    return self.typed[0..self.typed_len];
}

/// One controller, by the slot the platform put it in.
///
/// ```zig
/// const player_two = app.input.pad(1);
/// if (player_two.justPressed(.start)) join(2);
/// ```
///
/// A slot is the controller's for as long as it stays plugged in, which is
/// what makes slots usable as player numbers; on Windows they are XInput's
/// own four, the quarter of the ring an Xbox controller lights up. An empty
/// slot answers no and zero to everything, so a game can ask after player two
/// before player two has arrived.
pub fn pad(self: *const Input, slot: usize) Pad {
    return .{ .input = self, .slot = slot };
}

/// Every connected controller as one: a button is down if it is down on any
/// of them, and a stick reads whichever one is leaning furthest. For a game
/// with one player, who should be able to pick up whichever controller is
/// nearest.
pub fn anyPad(self: *const Input) Pad {
    return .{ .input = self, .slot = null };
}

// -------------------------------------------------------------------------
// Being told
// -------------------------------------------------------------------------

/// Forget the edges and the per-frame movement. Called once, before any of
/// the new frame's events are read.
///
/// Not the fixed step's edges: a frame that runs no step has to pass them on
/// to the next one that does. See `endFixedStep`.
pub fn beginFrame(self: *Input) void {
    self.pressed = .initEmpty();
    self.released = .initEmpty();
    self.button_pressed = .initEmpty();
    self.button_released = .initEmpty();
    for (&self.pads) |*state| {
        state.pressed = .initEmpty();
        state.released = .initEmpty();
    }
    self.pointer.dx = 0;
    self.pointer.dy = 0;
    self.wheel = .{};
    self.typed_len = 0;
}

/// Forget the edges a fixed step has just seen, so the next step sees only
/// what happens after this one. Called by `App` after every fixed step, and
/// on a frame that gave the fixed stage no time at all.
pub fn endFixedStep(self: *Input) void {
    self.fixed_pressed = .initEmpty();
    self.fixed_released = .initEmpty();
    self.fixed_button_pressed = .initEmpty();
    self.fixed_button_released = .initEmpty();
    for (&self.pads) |*state| {
        state.fixed_pressed = .initEmpty();
        state.fixed_released = .initEmpty();
    }
}

/// Take this frame's controllers from the platform, and work out what
/// changed since the last frame's.
///
/// Called by `Window.pump`, after the platform has polled. What went down is
/// what is down now and was not before, so a press that begins and ends
/// between two polls is never seen - at sixty polls a second that is a tap
/// shorter than a sixtieth of a second, which a thumb seldom manages.
///
/// A controller that is unplugged lets go of everything it was holding, for
/// the same reason losing focus does: a button held when it went would
/// otherwise stay held for the rest of the session.
pub fn readPads(self: *Input, devices: []const platform.Gamepad) void {
    for (&self.pads, 0..) |*state, slot| {
        const device: ?*const platform.Gamepad =
            if (slot < devices.len and devices[slot].connected) &devices[slot] else null;

        var down: PadButtons = .initEmpty();
        var axes: [platform.GamepadAxis.count]f32 = @splat(0);
        if (device) |found| {
            for (found.state.buttons, 0..) |held, i| {
                if (held) down.set(i);
            }
            axes = found.state.axes;
        }

        const pressed = down.differenceWith(state.down);
        const released = state.down.differenceWith(down);
        state.pressed.setUnion(pressed);
        state.released.setUnion(released);
        state.fixed_pressed.setUnion(pressed);
        state.fixed_released.setUnion(released);

        state.down = down;
        state.axes = axes;
        state.connected = device != null;
    }
}

/// Fold one platform event in. Events that are not about the user are
/// ignored, so a caller may hand over everything the queue produced.
pub fn apply(self: *Input, ev: platform.Event) void {
    switch (ev) {
        .key => |k| {
            self.mods = k.mods;
            if (indexOf(k.key)) |i| {
                // A `repeat` is the platform's auto-repeat, and it is a press
                // to a menu and nothing at all to a jump button. It sets
                // neither edge here and reaches the text layer through
                // `typed`, which is where repeat is actually wanted.
                switch (k.action) {
                    .press => {
                        self.down.set(i);
                        self.pressed.set(i);
                        self.fixed_pressed.set(i);
                    },
                    .release => {
                        self.down.unset(i);
                        self.released.set(i);
                        self.fixed_released.set(i);
                    },
                    .repeat => {},
                }
            }
            if (k.action.down()) self.pushTyped(.{ .key = k });
        },
        .char => |c| {
            self.mods = c.mods;
            self.pushTyped(.{ .character = c.codepoint });
        },
        .mouse_button => |b| {
            self.mods = b.mods;
            // A locked pointer has no position to report. See
            // `Pointer.locked`.
            if (!self.pointer.locked) {
                self.pointer.x = @floatCast(b.x);
                self.pointer.y = @floatCast(b.y);
            }
            const i = @intFromEnum(b.button);
            if (i >= button_span) return;
            switch (b.action) {
                .press => {
                    self.button_down.set(i);
                    self.button_pressed.set(i);
                    self.fixed_button_pressed.set(i);
                },
                .release => {
                    self.button_down.unset(i);
                    self.button_released.set(i);
                    self.fixed_button_released.set(i);
                },
                .repeat => {},
            }
        },
        .cursor => |m| {
            if (self.pointer.locked) {
                // Movement only, and only while the window has the keyboard.
                // A locked pointer is let go while the window is in the
                // background - see `Window.refocus` - and a hand moving over
                // it then belongs to somebody using another program, not to
                // the camera this movement would turn.
                if (self.focused) {
                    self.pointer.dx += @floatCast(m.dx);
                    self.pointer.dy += @floatCast(m.dy);
                }
                return;
            }
            self.pointer.x = @floatCast(m.x);
            self.pointer.y = @floatCast(m.y);
            self.pointer.dx += @floatCast(m.dx);
            self.pointer.dy += @floatCast(m.dy);
        },
        .cursor_enter => |s| self.pointer.inside = s.value,
        .scroll => |w| {
            self.wheel.x += @floatCast(w.x);
            self.wheel.y += @floatCast(w.y);
        },
        .focus => |s| {
            self.focused = s.value;
            // Focus lost with keys held would otherwise leave them held for
            // ever: the release arrives at whatever window took the focus,
            // and this one never hears about it. Alt+Tab away while walking,
            // and walk into the wall for the rest of the session.
            if (!s.value) self.releaseEverything();
        },
        else => {},
    }
}

/// Let go of everything, as if every key and button came up at once.
pub fn releaseEverything(self: *Input) void {
    var keys = self.down.iterator(.{});
    while (keys.next()) |i| {
        self.released.set(i);
        self.fixed_released.set(i);
    }
    var buttons = self.button_down.iterator(.{});
    while (buttons.next()) |i| {
        self.button_released.set(i);
        self.fixed_button_released.set(i);
    }
    self.down = .initEmpty();
    self.button_down = .initEmpty();
}

fn pushTyped(self: *Input, item: Typed) void {
    // Dropping the newest rather than growing: a frame that typed more than
    // this had something wrong with it, and a buffer that grows is a buffer
    // that allocates in the middle of an event loop.
    if (self.typed_len == self.typed.len) return;
    self.typed[self.typed_len] = item;
    self.typed_len += 1;
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

/// Every slot empty, as the platform would hand them over with nothing
/// plugged in - to be filled in by a test.
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

    // And a slot with nothing in it says no to everything.
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

    // Pushed all the way right.
    lean(&slots[0], .left_x, 1);
    lean(&slots[0], .left_y, 0);
    input.readPads(&slots);
    try testing.expectApproxEqAbs(@as(f32, 1), input.pad(0).stick(.left).x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), input.pad(0).axis(.left_x), 0.0001);

    // A corner that reports more than full tilt on both axes is no faster
    // than a straight push.
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
    // Resting slightly off, on a third controller nobody is using.
    lean(&slots[5], .left_x, 0.15);
    input.readPads(&slots);

    const any = input.anyPad();
    try testing.expect(any.connected());
    try testing.expect(any.down(.a));
    try testing.expect(any.justPressed(.a));
    // The stick being pushed, not the sum of it and the one resting.
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

    // The stick halfway down: a little over half, once its dead zone is out.
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

test "a locked pointer holds still, and only its movement counts" {
    var input: Input = .{};
    input.apply(cursorEvent(120, 80, 0, 0));

    input.pointer.locked = true;
    input.beginFrame();
    // What the platform sends while the cursor is locked: no position, and
    // movement that keeps coming however far the hand goes.
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
