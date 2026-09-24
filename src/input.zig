// SPDX-License-Identifier: BSD-3-Clause

//! What the keyboard, the mouse and the controllers did, as a thing to ask.
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
//! Events are folded in as they arrive, and systems read the result. `down`
//! is a level; `pressed` and `released` are edges, kept separately so that a
//! key that goes down and up inside one frame still counts. `beginFrame`
//! clears the edges at the top of the next frame.
//!
//! A `.fixed` step runs zero or more times a frame, so it answers from a
//! second set of edges, cleared only after a step has run: one press is one
//! jump, whatever the frame rate. See `clock`. `pointer.dx`, `wheel` and
//! `typed` have no second set, so read them outside `.fixed`.
//!
//! The platform polls the controllers once a frame, and `readPads` turns the
//! difference into the same edges a key has.
//!
//! Files let go over the window and the answers to file dialogs are input
//! too, each there for one frame: see `dropped` and `dialogAnswers`.
//!
//! A game asks for its actions rather than its keys - `actionDown("jump")`
//! - and a project says which keys, buttons and sticks they are: see
//! `actions` and `updateActions`.

const std = @import("std");
const testing = std.testing;

const platform = @import("fluxion_platform");
const math = @import("fluxion_math");

const actions_mod = @import("actions.zig");
const dialog = @import("dialog.zig");
const pointer_mod = @import("pointer.zig");

pub const Action = actions_mod.Action;
pub const Actions = actions_mod.Actions;
pub const Binding = actions_mod.Binding;
pub const Device = actions_mod.Device;

const Vec2 = math.Vec2;

const Input = @This();

/// One past the largest `Key`, `menu` at 348. The keys are at GLFW's
/// numbers, so the range is sparse; a bit set still beats a hash lookup.
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

/// The same keys by what the layout calls them: `KeyEvent.virtual`. What an
/// action bound to a key that is not `physical` reads.
virtual_down: Keys = .initEmpty(),
virtual_pressed: Keys = .initEmpty(),

/// The game's actions, and where each one stands this frame. Freed with
/// `deinit`; `App` fills it from the project.
actions: Actions = .{},

/// What the player last pressed something on: the keyboard and the mouse,
/// or a controller. What `describeAction` names an action by.
last_device: Device = .keyboard,

/// Mouse buttons, the same three ways.
button_down: Buttons = .initEmpty(),
button_pressed: Buttons = .initEmpty(),
button_released: Buttons = .initEmpty(),

/// The edges again, counted since the last fixed step: what the questions
/// below answer from while `clock` is `.fixed`.
fixed_pressed: Keys = .initEmpty(),
fixed_released: Keys = .initEmpty(),
fixed_button_pressed: Buttons = .initEmpty(),
fixed_button_released: Buttons = .initEmpty(),

/// Which edges `justPressed` and the rest answer from. A mode rather than a
/// second set of functions, so a `.fixed` system calling `justPressed` is
/// simply right. `App` sets it around the fixed stage; nothing else should.
clock: Clock = .frame,

/// Where the pointer is, in pixels from the top left of the content area,
/// and how far it moved this frame.
pointer: Pointer = .{},

/// How far the wheel turned this frame. Positive `y` is away from the user.
wheel: Wheel = .{},

/// What was held down when the last event arrived. Shift, control, alt.
mods: platform.Mods = .{},

/// Buttons whose press this frame was the second of a double click, by
/// the system's own rule. See `doubleClicked`.
button_double: Buttons = .initEmpty(),

/// How far the pointer has moved since the velocity was last worked out,
/// and how long that has taken; and how long it has been still.
pointer_moved: math.Vec2 = .zero,
pointer_elapsed: f32 = 0,
pointer_still: f32 = 0,

/// Everything typed this frame, in order: the codepoints meant, and the keys
/// that may mean an edit.
typed: [typed_capacity]Typed = undefined,
typed_len: usize = 0,

/// Every key that went down, came up or repeated this frame, in order: what
/// a script's `input` is handed. One given between frames is the next
/// frame's, as a pointer event is.
key_events: [typed_capacity]platform.event.KeyEvent = undefined,
key_events_len: usize = 0,
key_events_seen: usize = 0,

/// Everything the pointer did this frame, in order: what picking hands
/// to whatever is under it, and what a game reads for itself. See
/// `pointerEvents`.
pointer_events: [pointer_event_capacity]pointer_mod.InputEvent = undefined,
pointer_events_len: usize = 0,
/// How many of them this frame's systems have seen, so one given between
/// frames - by a test, for the hand that is not there - is the next
/// frame's rather than nobody's.
pointer_events_seen: usize = 0,
/// Whether this frame's pointer has been taken by something already.
/// See `setAsHandled`.
handled: bool = false,

/// Every controller slot, as it stood at the top of this frame. Asked
/// through `pad` and `anyPad`, which apply the dead zones and the clock.
pads: [max_pads]PadState = @splat(.{}),

/// How far a stick has to lean before it counts, as a fraction of full tilt.
/// A worn stick does not come back to exactly the middle.
stick_deadzone: f32 = 0.2,

/// The same for a trigger, which rests more reliably.
trigger_deadzone: f32 = 0.1,

/// Whether the window has the keyboard. For a game that pauses when nobody
/// is looking at it.
focused: bool = true,

/// The dialogs answered this frame, and ones answered since the last frame
/// ended: see `dialogAnswers`. The first `answers_seen` were there for a
/// whole frame, and go at the top of the next.
answers: [answer_capacity]dialog.Answer = undefined,
answers_len: usize = 0,
answers_seen: usize = 0,

/// Files let go over the window this frame, kept as the dialogs' answers
/// are: see `dropped`.
drops: [drop_capacity]Dropped = undefined,
drops_len: usize = 0,
drops_seen: usize = 0,

/// Whether the program is in the background, from `.suspended` to
/// `.resumed`: an Android app switched away from, a page that was hidden.
/// A desktop program never is. See `justSuspended`.
suspended: bool = false,

/// Whether the window has nothing to draw on, from `.surface_lost` to
/// `.surface_created`: an Android app's, while it is in the background.
surface_lost: bool = false,

/// The lifecycle's edges this frame, and ones told since the last frame
/// ended, kept as the dialogs' answers are.
happened: std.EnumSet(Happening) = .initEmpty(),
happened_seen: std.EnumSet(Happening) = .initEmpty(),

/// What the system says of the program as a whole, rather than of a key.
pub const Happening = enum { suspended, resumed, low_memory };

/// How much typing one frame can hold: far more than a fast typist manages.
pub const typed_capacity = 32;

/// The least time the pointer's velocity is worked out over, so a frame
/// with no motion in it does not read as a stop.
const velocity_window = 0.1;
/// How long the pointer stands still before its velocity is nought.
const velocity_forgets = 3.0;

/// The most pointer events one frame keeps; the rest are dropped.
pub const pointer_event_capacity = 32;

/// How many drops one frame can hold. A person lets go of one armful at a
/// time; this is room for a test's several.
pub const drop_capacity = 4;

/// Files let go over the window: dragged there from the system's file
/// manager.
pub const Dropped = struct {
    /// The operating system's paths, lent until the frame ends. A page is
    /// never shown a path, so in a browser they are the files' names, and
    /// fluxion-platform's `web.droppedFile` has the bytes.
    paths: []const []const u8,
    /// Where they were let go, in the pixels `pointer` is in: where to put
    /// them. Where the platform does not say, where the pointer last was.
    x: f32,
    y: f32,
};

/// How many dialog answers one frame can hold. One dialog is open at a time,
/// so a frame has one at most, and a test that answers for several is still
/// well inside this.
pub const answer_capacity = 8;

/// How many controllers can be told apart: fluxion-platform's slots.
pub const max_pads = platform.gamepad.max_devices;

/// The fifteen buttons a mapped controller has, one bit each.
const PadButtons = std.StaticBitSet(platform.GamepadButton.count);

/// How far a stick or a trigger goes before the player counts as using the
/// controller: a resting stick's drift does not.
const device_threshold = 0.5;

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
    /// How fast it is moving, in pixels a second, worked out over at
    /// least the last tenth of a second. Nought once it has been still
    /// for three seconds. Set by `Input.trackPointer`.
    velocity: math.Vec2 = .zero,
    /// Whether the pointer is over the window at all.
    inside: bool = true,

    /// Whether the cursor is locked; see `App.setCursor`. While it is, `x`
    /// and `y` hold where the pointer was - the platform reports nought,
    /// nought - and only `dx` and `dy` move. Set by `App`.
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

/// A key's bit, or null for none: `Key.unknown` is -1, and a negative index
/// into a bit set is a crash.
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
/// ```
///
/// Its sources are added up and the sum held to that range, so all of them
/// at once is no faster. Both ends held is a standstill. A stick is read with
/// its dead zone taken out.
pub fn axisOf(self: *const Input, binding: AxisBinding) f32 {
    var sum = self.anyKeyOf(binding.positive) - self.anyKeyOf(binding.negative);

    const controller = if (binding.pad == AxisBinding.any_pad) self.anyPad() else self.pad(binding.pad);
    // A number out of range - `no_pad_input`, or a save from a build with
    // more buttons - is no input rather than an enum that does not exist.
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

/// One if any of these keys is down: two keys for the same end of an axis
/// count once.
fn anyKeyOf(self: *const Input, keys: [2]i32) f32 {
    for (keys) |raw| {
        if (self.isDown(@enumFromInt(raw))) return 1;
    }
    return 0;
}

// -------------------------------------------------------------------------
// Actions
// -------------------------------------------------------------------------

/// Whether the action is down: any of its inputs is, or `pressAction` holds
/// it. False for an action there is none of.
pub fn actionDown(self: *const Input, name: []const u8) bool {
    const entry = self.actions.findConst(name) orelse return false;
    return entry.state.down;
}

/// Whether it went down this frame - or, in a `.fixed` system, since the
/// last fixed step. Pressing a second key while the first is held is no new
/// press.
pub fn actionJustPressed(self: *const Input, name: []const u8) bool {
    const entry = self.actions.findConst(name) orelse return false;
    return if (self.clock == .fixed) entry.state.fixed_pressed else entry.state.pressed;
}

/// Whether it came up this frame - or since the last fixed step.
pub fn actionJustReleased(self: *const Input, name: []const u8) bool {
    const entry = self.actions.findConst(name) orelse return false;
    return if (self.clock == .fixed) entry.state.fixed_released else entry.state.released;
}

/// How far down it is, from nought to one: one for a key, and for a stick
/// or a trigger how far past its dead zone it is.
pub fn actionStrength(self: *const Input, name: []const u8) f32 {
    const entry = self.actions.findConst(name) orelse return 0;
    return entry.state.strength;
}

/// Two actions as one axis, from -1 to 1: `actionAxis("move_left",
/// "move_right")`.
pub fn actionAxis(self: *const Input, negative: []const u8, positive: []const u8) f32 {
    return self.actionStrength(positive) - self.actionStrength(negative);
}

/// Four actions as a direction, no longer than one, up negative as the
/// world's `y` is: what a character walks by.
pub fn actionVector(self: *const Input, left: []const u8, right: []const u8, up: []const u8, down_name: []const u8) Vec2 {
    const toward: Vec2 = .init(self.actionAxis(left, right), self.actionAxis(up, down_name));
    const length = toward.len();
    return if (length > 1) toward.scale(1 / length) else toward;
}

/// Hold an action down from code, at `strength` from nought to one - what a
/// button on a touch screen does - until `releaseAction`. It goes down at
/// once, with its edge, if nothing held it; and it is down while either
/// holds it, the code or an input. `error.NoSuchAction` for one there is none
/// of.
pub fn pressAction(self: *Input, name: []const u8, strength: f32) error{NoSuchAction}!void {
    const entry = self.actions.find(name) orelse return error.NoSuchAction;
    entry.state.forced = if (std.math.isNan(strength)) 1 else std.math.clamp(strength, 0.001, 1);
    self.evaluate(entry);
}

/// Let go of what `pressAction` held. It comes up at once, with its edge,
/// unless an input still holds it.
pub fn releaseAction(self: *Input, name: []const u8) error{NoSuchAction}!void {
    const entry = self.actions.find(name) orelse return error.NoSuchAction;
    entry.state.forced = 0;
    self.evaluate(entry);
}

/// What the player presses for an action, in words, in `buffer`: `Space`,
/// `Pad A` - its first input on what the player last used, the keyboard or
/// a controller, or else its first. Empty for an action with none, or none
/// of that name. For "Press E to open".
pub fn describeAction(self: *const Input, buffer: []u8, name: []const u8) []const u8 {
    const entry = self.actions.findConst(name) orelse return "";
    const bindings = entry.bindings.items;
    if (bindings.len == 0) return "";
    var chosen = bindings[0];
    for (bindings) |binding| {
        if (binding.device() == self.last_device) {
            chosen = binding;
            break;
        }
    }
    return std.fmt.bufPrint(buffer, "{f}", .{chosen}) catch buffer[0..0];
}

/// Work out where every action stands from this frame's keys, buttons and
/// controllers, and give it its edges. Called by `App` once a frame, after
/// the events and before the first system; a test that feeds events calls
/// it itself.
pub fn updateActions(self: *Input) void {
    for (self.actions.entries.items) |*entry| self.evaluate(entry);
}

/// One action, against what its inputs say now. Edges only ever add to
/// what the frame and the fixed step have heard: `beginFrame` and
/// `endFixedStep` clear them.
fn evaluate(self: *Input, entry: *Actions.Entry) void {
    var strength: f32 = 0;
    var off_keys: f32 = 0;
    var tapped = false;
    for (entry.bindings.items) |binding| {
        const reading = self.read(binding, entry.deadzone);
        strength = @max(strength, reading.strength);
        if (binding.device() != .keyboard or binding == .mouse_button) off_keys = @max(off_keys, reading.strength);
        tapped = tapped or reading.tapped;
    }
    const state = &entry.state;
    strength = @max(strength, state.forced);
    off_keys = @max(off_keys, state.forced);

    const was = state.down;
    const down = strength > 0;
    const pressed = !was and (down or tapped);
    // A tap inside one frame is its release as well.
    const released = (was and !down) or (!was and !down and tapped);
    state.down = down;
    state.strength = strength;
    state.strength_off_keys = off_keys;
    state.pressed = state.pressed or pressed;
    state.released = state.released or released;
    state.fixed_pressed = state.fixed_pressed or pressed;
    state.fixed_released = state.fixed_released or released;
}

const Reading = struct { strength: f32 = 0, tapped: bool = false };

/// What one input says now: how far down it is, and whether it went down
/// this frame.
fn read(self: *const Input, binding: Binding, deadzone: f32) Reading {
    switch (binding) {
        .key => |held| {
            const i = indexOf(held.key) orelse return .{};
            const level = if (held.physical) &self.down else &self.virtual_down;
            const edges = if (held.physical) &self.pressed else &self.virtual_pressed;
            return .{ .strength = if (level.isSet(i)) 1 else 0, .tapped = edges.isSet(i) };
        },
        .mouse_button => |held| {
            const i = @intFromEnum(held.button);
            if (i >= button_span) return .{};
            return .{ .strength = if (self.button_down.isSet(i)) 1 else 0, .tapped = self.button_pressed.isSet(i) };
        },
        .pad_button => |held| {
            const i = @intFromEnum(held.button);
            var reading: Reading = .{};
            for (self.padStates(held.pad)) |state| {
                if (state.down.isSet(i)) reading.strength = 1;
                if (state.pressed.isSet(i)) reading.tapped = true;
            }
            return reading;
        },
        .pad_axis => |held| {
            const sign: f32 = if (held.direction == .negative) -1 else 1;
            var furthest: f32 = 0;
            for (self.padStates(held.pad)) |state| {
                if (!state.connected) continue;
                furthest = @max(furthest, state.axes[@intFromEnum(held.axis)] * sign);
            }
            if (furthest <= deadzone) return .{};
            return .{ .strength = @min((furthest - deadzone) / (1 - deadzone), 1) };
        },
    }
}

/// One controller's slot, or every slot for null.
fn padStates(self: *const Input, pad_slot: ?u8) []const PadState {
    const slot = pad_slot orelse return &self.pads;
    if (slot >= max_pads) return &.{};
    return self.pads[slot .. slot + 1];
}

/// Whether anything at all is held down.
pub fn anyKeyDown(self: *const Input) bool {
    return self.down.count() != 0;
}

/// Whether that button's press this frame was the second of a double
/// click, by the system's rule: Windows' own setting, or four hundred
/// milliseconds within a few pixels. A third press starts again, and a
/// `.fixed` system reads the frame's, not the step's.
pub fn doubleClicked(self: *const Input, button: platform.MouseButton) bool {
    const i = @intFromEnum(button);
    return i < button_span and self.button_double.isSet(i);
}

/// Work out the pointer's velocity from the frame's motion. Called by
/// `App` once a frame, after the events are in.
pub fn trackPointer(self: *Input, delta: f32) void {
    const moved: math.Vec2 = .init(self.pointer.dx, self.pointer.dy);
    self.pointer_moved = self.pointer_moved.add(moved);
    self.pointer_elapsed += delta;
    if (moved.x != 0 or moved.y != 0) self.pointer_still = 0 else self.pointer_still += delta;
    if (self.pointer_elapsed >= velocity_window) {
        self.pointer.velocity = self.pointer_moved.scale(1 / self.pointer_elapsed);
        self.pointer_moved = .zero;
        self.pointer_elapsed = 0;
    }
    if (self.pointer_still >= velocity_forgets) self.pointer.velocity = .zero;
}

/// What the pointer did this frame, oldest first: presses, releases,
/// wheel notches as wheel buttons, and one motion for the frame's
/// moving. Picking hands each to whatever is under it.
pub fn pointerEvents(self: *const Input) []const pointer_mod.InputEvent {
    return self.pointer_events[0..self.pointer_events_len];
}

/// Which buttons are held now, as a mask. The wheel is in an event's own
/// mask, never here.
pub fn buttonMask(self: *const Input) pointer_mod.ButtonMask {
    var mask: pointer_mod.ButtonMask = .none;
    for (0..button_span) |i| {
        if (!self.button_down.isSet(i)) continue;
        if (pointer_mod.PointerButton.of(@enumFromInt(@as(u8, @intCast(i))))) |which| mask = mask.with(which, true);
    }
    return mask;
}

/// Take this frame's pointer: picking stops there, and a system that
/// asks `isHandled` leaves it alone. What an `.input` system calls to
/// keep a click from the world behind it.
pub fn setAsHandled(self: *Input) void {
    self.handled = true;
}

/// Whether something has taken this frame's pointer already.
pub fn isHandled(self: *const Input) bool {
    return self.handled;
}

/// What was typed this frame, oldest first.
/// Every key event of this frame, releases and repeats too, oldest first.
pub fn keyEvents(self: *const Input) []const platform.event.KeyEvent {
    return self.key_events[0..self.key_events_len];
}

pub fn typedThisFrame(self: *const Input) []const Typed {
    return self.typed[0..self.typed_len];
}

/// The file and folder dialogs answered this frame, each with the id
/// `App.openFileDialog` or `openFolderDialog` gave. Every system of the frame
/// sees them; the next frame does not, and the paths are lent until then.
pub fn dialogAnswers(self: *const Input) []const dialog.Answer {
    return self.answers[0..self.answers_len];
}

/// The paths one dialog came back with this frame - none when it was
/// cancelled - or null when it has not come back this frame.
pub fn dialogAnswer(self: *const Input, id: dialog.Id) ?[]const []const u8 {
    for (self.dialogAnswers()) |answer| {
        if (answer.id == id) return answer.paths;
    }
    return null;
}

/// The files let go over the window this frame, in the order they were:
/// every system of the frame sees them, and the next frame does not.
///
/// ```zig
/// for (app.input.dropped()) |drop| for (drop.paths) |path| try bringIn(path, drop.x, drop.y);
/// ```
pub fn dropped(self: *const Input) []const Dropped {
    return self.drops[0..self.drops_len];
}

/// Files let go over the window, for this frame's systems: what `apply`
/// does with the platform's drops, and what a test calls. Given between
/// frames, it is the next frame's. Past `drop_capacity` in one frame, it is
/// dropped.
pub fn dropFiles(self: *Input, drop: Dropped) void {
    if (self.drops_len == self.drops.len) return;
    self.drops[self.drops_len] = drop;
    self.drops_len += 1;
}

/// Whether the program went into the background this frame: a system's
/// last chance to save, because the frames after it run no systems until it
/// comes back - and Android may end a program in the background without
/// another word.
pub fn justSuspended(self: *const Input) bool {
    return self.happened.contains(.suspended);
}

/// Whether the program came back from the background this frame. The clock
/// starts again with it, so the time away is not a frame.
pub fn justResumed(self: *const Input) bool {
    return self.happened.contains(.resumed);
}

/// Whether the system asked for memory back this frame: a game lets go of
/// what it can load again. Android's, and never a desktop's.
pub fn lowMemory(self: *const Input) bool {
    return self.happened.contains(.low_memory);
}

/// One controller, by its platform slot. A controller keeps its slot while it
/// stays plugged in, so slots work as player numbers. An empty slot says no
/// and zero to everything.
pub fn pad(self: *const Input, slot: usize) Pad {
    return .{ .input = self, .slot = slot };
}

/// Every connected controller as one: a button is down if it is down on any
/// of them, and a stick reads whichever is leaning furthest. For a game with
/// one player.
pub fn anyPad(self: *const Input) Pad {
    return .{ .input = self, .slot = null };
}

// -------------------------------------------------------------------------
// Being told
// -------------------------------------------------------------------------

/// Forget the frame's edges and movement, before the new frame's events are
/// read. The fixed step's edges stay: a frame that runs no step passes them
/// on. See `endFixedStep`.
pub fn beginFrame(self: *Input) void {
    self.pressed = .initEmpty();
    self.released = .initEmpty();
    self.virtual_pressed = .initEmpty();
    for (self.actions.entries.items) |*entry| {
        entry.state.pressed = false;
        entry.state.released = false;
    }
    self.button_pressed = .initEmpty();
    self.button_released = .initEmpty();
    self.button_double = .initEmpty();
    for (&self.pads) |*state| {
        state.pressed = .initEmpty();
        state.released = .initEmpty();
    }
    self.pointer.dx = 0;
    self.pointer.dy = 0;
    self.wheel = .{};
    self.typed_len = 0;
    self.handled = false;

    // The pointer events a whole frame has had go; one given between
    // frames stays for this one, as a dialog's answer does.
    const keys_unseen = self.key_events_len - self.key_events_seen;
    std.mem.copyForwards(platform.event.KeyEvent, self.key_events[0..keys_unseen], self.key_events[self.key_events_seen..self.key_events_len]);
    self.key_events_len = keys_unseen;
    self.key_events_seen = 0;

    const unseen = self.pointer_events_len - self.pointer_events_seen;
    std.mem.copyForwards(pointer_mod.InputEvent, self.pointer_events[0..unseen], self.pointer_events[self.pointer_events_seen..self.pointer_events_len]);
    self.pointer_events_len = unseen;
    self.pointer_events_seen = 0;

    // The answers a whole frame has had go; one given between frames - by a
    // test, for the person who is not there - stays for this one.
    const kept = self.answers_len - self.answers_seen;
    std.mem.copyForwards(dialog.Answer, self.answers[0..kept], self.answers[self.answers_seen..self.answers_len]);
    self.answers_len = kept;
    self.answers_seen = 0;

    // The drops, the same way.
    const still = self.drops_len - self.drops_seen;
    std.mem.copyForwards(Dropped, self.drops[0..still], self.drops[self.drops_seen..self.drops_len]);
    self.drops_len = still;
    self.drops_seen = 0;

    // And the lifecycle's edges.
    self.happened = self.happened.differenceWith(self.happened_seen);
    self.happened_seen = .initEmpty();
}

/// Mark what this frame's systems have seen, for `beginFrame` to let go.
/// Called by `App` at the end of every frame, one whose system failed too.
pub fn endFrame(self: *Input) void {
    self.answers_seen = self.answers_len;
    self.drops_seen = self.drops_len;
    self.pointer_events_seen = self.pointer_events_len;
    self.key_events_seen = self.key_events_len;
    self.happened_seen = self.happened;
}

/// A dialog's answer, for this frame's systems: what `apply` does with the
/// platform's, and what a test calls to answer a headless dialog. Given
/// between frames, it is the next frame's. Past `answer_capacity` in one
/// frame, it is dropped.
pub fn answerDialog(self: *Input, answer: dialog.Answer) void {
    if (self.answers_len == self.answers.len) return;
    self.answers[self.answers_len] = answer;
    self.answers_len += 1;
}

/// Forget the edges a fixed step has just seen. Called by `App` after every
/// fixed step, and on a frame that gave the fixed stage no time at all.
pub fn endFixedStep(self: *Input) void {
    self.fixed_pressed = .initEmpty();
    self.fixed_released = .initEmpty();
    for (self.actions.entries.items) |*entry| {
        entry.state.fixed_pressed = false;
        entry.state.fixed_released = false;
    }
    self.fixed_button_pressed = .initEmpty();
    self.fixed_button_released = .initEmpty();
    for (&self.pads) |*state| {
        state.fixed_pressed = .initEmpty();
        state.fixed_released = .initEmpty();
    }
}

/// Take this frame's controllers from the platform, and work out what changed
/// since the last frame's. Called by `Window.pump`. An unplugged controller
/// lets go of everything it was holding.
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
        if (pressed.count() != 0) self.last_device = .pad;
        for (axes, 0..) |value, i| {
            if (@abs(value) > device_threshold and @abs(state.axes[i]) <= device_threshold) self.last_device = .pad;
        }
        state.pressed.setUnion(pressed);
        state.released.setUnion(released);
        state.fixed_pressed.setUnion(pressed);
        state.fixed_released.setUnion(released);

        state.down = down;
        state.axes = axes;
        state.connected = device != null;
    }
}

/// Fold one platform event in. Events that are not input are ignored, so a
/// caller may hand over everything the queue produced. A dialog's answer is
/// input too: see `dialogAnswers`.
pub fn apply(self: *Input, ev: platform.Event) void {
    if (comptime dialog.available) {
        switch (ev) {
            .file_dialog => |answered| return self.answerDialog(.{
                .id = @enumFromInt(@intFromEnum(answered.id)),
                .paths = answered.paths,
            }),
            else => {},
        }
    }
    switch (ev) {
        .key => |k| {
            self.mods = k.mods;
            if (indexOf(k.key)) |i| {
                // A `repeat` sets no edge - it is a press to a menu, not to a
                // jump button - and reaches text input through `typed`.
                switch (k.action) {
                    .press => {
                        self.down.set(i);
                        self.pressed.set(i);
                        self.fixed_pressed.set(i);
                        self.last_device = .keyboard;
                    },
                    .release => {
                        self.down.unset(i);
                        self.released.set(i);
                        self.fixed_released.set(i);
                    },
                    .repeat => {},
                }
            }
            if (indexOf(k.virtual)) |i| switch (k.action) {
                .press => {
                    self.virtual_down.set(i);
                    self.virtual_pressed.set(i);
                },
                .release => self.virtual_down.unset(i),
                .repeat => {},
            };
            if (k.action.down()) self.pushTyped(.{ .key = k });
            if (self.key_events_len < self.key_events.len) {
                self.key_events[self.key_events_len] = k;
                self.key_events_len += 1;
            }
        },
        .char => |c| {
            self.mods = c.mods;
            self.pushTyped(.{ .character = c.codepoint });
        },
        .mouse_button => |b| {
            self.mods = b.mods;
            // A locked pointer has no position to report.
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
                    if (b.double_click) self.button_double.set(i);
                    self.last_device = .keyboard;
                },
                .release => {
                    self.button_down.unset(i);
                    self.button_released.set(i);
                    self.fixed_button_released.set(i);
                },
                .repeat => {},
            }
            if (b.action != .repeat) {
                if (pointer_mod.PointerButton.of(b.button)) |which| self.pushPointer(.{ .mouse_button = .{
                    .button = which,
                    .pressed = b.action == .press,
                    .double_click = b.double_click,
                    .position = .init(self.pointer.x, self.pointer.y),
                    .button_mask = self.buttonMask(),
                    .mods = b.mods,
                } });
            }
        },
        .cursor => |m| {
            if (self.pointer.locked) {
                // Movement only, and only while the window has the keyboard:
                // in the background, the hand on the mouse is using another
                // program.
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
            self.pushMotion(.init(@floatCast(m.dx), @floatCast(m.dy)));
        },
        .cursor_enter => |s| self.pointer.inside = s.value,
        .scroll => |w| {
            self.wheel.x += @floatCast(w.x);
            self.wheel.y += @floatCast(w.y);
            // A notch is reported as a press and a release of a wheel
            // button.
            if (w.y != 0) self.pushWheel(if (w.y > 0) .wheel_up else .wheel_down, @floatCast(@abs(w.y)), w.mods);
            if (w.x != 0) self.pushWheel(if (w.x > 0) .wheel_right else .wheel_left, @floatCast(@abs(w.x)), w.mods);
        },
        .focus => |s| {
            self.focused = s.value;
            // Keys held as the focus goes would stay held for ever: their
            // release goes to whichever window took the focus.
            if (!s.value) self.releaseEverything();
        },
        .drop => |d| {
            // Where it was let go, once the platform says; the pointer's last
            // place until then, which is where a drag over the window was.
            const point = comptime @hasField(platform.event.DropEvent, "x");
            self.dropFiles(.{
                .paths = d.paths,
                .x = if (point) @floatCast(d.x) else self.pointer.x,
                .y = if (point) @floatCast(d.y) else self.pointer.y,
            });
        },
        .suspended => {
            self.suspended = true;
            self.happened.insert(.suspended);
        },
        .resumed => {
            self.suspended = false;
            self.happened.insert(.resumed);
        },
        .low_memory => self.happened.insert(.low_memory),
        .surface_lost => self.surface_lost = true,
        .surface_created => self.surface_lost = false,
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
    self.virtual_down = .initEmpty();
    self.button_down = .initEmpty();
}

/// One pointer event, dropped rather than grown, as the typed ones are.
fn pushPointer(self: *Input, event: pointer_mod.InputEvent) void {
    if (self.pointer_events_len == self.pointer_events.len) return;
    self.pointer_events[self.pointer_events_len] = event;
    self.pointer_events_len += 1;
}

/// Motion, added to the last event when that is motion too: a frame's
/// moving is one event.
fn pushMotion(self: *Input, by: math.Vec2) void {
    const at: math.Vec2 = .init(self.pointer.x, self.pointer.y);
    if (self.pointer_events_len != 0) {
        const last = &self.pointer_events[self.pointer_events_len - 1];
        if (last.* == .mouse_motion) {
            last.mouse_motion.position = at;
            last.mouse_motion.relative = last.mouse_motion.relative.add(by);
            last.mouse_motion.button_mask = self.buttonMask();
            last.mouse_motion.mods = self.mods;
            return;
        }
    }
    self.pushPointer(.{ .mouse_motion = .{
        .position = at,
        .relative = by,
        .button_mask = self.buttonMask(),
        .mods = self.mods,
    } });
}

/// A wheel notch: the press that has the wheel's bit, and the release
/// that has not.
fn pushWheel(self: *Input, which: pointer_mod.PointerButton, notches: f32, mods: platform.Mods) void {
    const at: math.Vec2 = .init(self.pointer.x, self.pointer.y);
    const held = self.buttonMask();
    self.pushPointer(.{ .mouse_button = .{
        .button = which,
        .pressed = true,
        .factor = notches,
        .position = at,
        .button_mask = held.with(which, true),
        .mods = mods,
    } });
    self.pushPointer(.{ .mouse_button = .{
        .button = which,
        .pressed = false,
        .factor = notches,
        .position = at,
        .button_mask = held,
        .mods = mods,
    } });
}

fn pushTyped(self: *Input, item: Typed) void {
    // Dropped rather than grown, so nothing allocates inside the event loop.
    if (self.typed_len == self.typed.len) return;
    self.typed[self.typed_len] = item;
    self.typed_len += 1;
}

/// Give back what the actions hold.
pub fn deinit(self: *Input, gpa: std.mem.Allocator) void {
    self.actions.deinit(gpa);
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
