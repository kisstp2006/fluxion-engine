// SPDX-License-Identifier: BSD-3-Clause

//! What the keyboard, the mouse, the fingers on a touch screen and the
//! controllers did, as a thing to ask.
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
//!
//! Every finger on a touch screen is a `Touch` of its own, for the frame it
//! touches to the frame it is lifted: see `touches`. The first finger is the
//! mouse as well, unless `mouse_from_touch` says not. What the fingers make -
//! a tap, a long press, a swipe; two fingers' pinch, pan and turn - is worked
//! out once a frame: see `trackFingers`.

const std = @import("std");
const builtin = @import("builtin");

const math = @import("fluxion_math");
const platform = @import("fluxion_platform");

const attr = @import("../reflect/attr.zig");
const dialog = @import("../platform/dialog.zig");
const events = @import("input_event.zig");

const Gestures = @import("gestures.zig").Gestures;
const PadButtons = @import("pads.zig").PadButtons;

// What the files of this module give, under the module's name.
pub const Action = @import("actions.zig").Action;
pub const Actions = @import("actions.zig").Actions;
pub const Binding = @import("actions.zig").Binding;
pub const Device = @import("actions.zig").Device;
pub const AxisBinding = @import("pads.zig").AxisBinding;
pub const Pad = @import("pads.zig").Pad;
pub const PadState = @import("pads.zig").PadState;
pub const Side = @import("pads.zig").Side;
/// What two fingers did this frame: see `gestures.zig`.
pub const TwoFingers = @import("gestures.zig").TwoFingers;

pub const Vec2 = math.Vec2;

pub const Input = @This();

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

/// Where on the window the game area is shown, and how many of its pixels one of
/// the window's is: what turns every pointer position and movement this
/// reads from the window's pixels into the game area's. The identity until a
/// project stretches its game to the window; see `stretch.zig`.
area_origin: math.Vec2 = .zero,
area_ratio: f32 = 1,

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
pointer_events: [pointer_event_capacity]events.InputEvent = undefined,
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

/// This frame's fingers, in the order they touched: those down, and those
/// lifted this frame. See `touches`.
fingers: [max_fingers]Touch = undefined,
finger_count: usize = 0,
/// Whether the first finger's mouse is heard: the pointer it moves and the
/// left button it holds. A project's `touch.mouse_from_touch`.
mouse_from_touch: bool = true,
/// Whether the left mouse button is a finger as well - `mouse_as_finger` -
/// to try a game made for a touch screen with a mouse. A project's
/// `touch.touch_from_mouse`.
touch_from_mouse: bool = false,
/// Whether this is a touch screen: Android, or a screen a finger touched.
touchscreen: bool = builtin.abi.isAndroid(),
/// How many of the game area's pixels a density-independent pixel is - a 160th
/// of an inch - so that a gesture is the same size under a finger on any
/// screen. Set by `App`.
dp: f32 = 1,
/// What the fingers make from frame to frame: see `gestures.zig`.
gestures: Gestures = .{},
/// Whether a wheel turned with Ctrl is a pinch as well: what a precision
/// touchpad's pinch is on Windows and in a browser. A project's
/// `touch.pinch_from_ctrl_wheel`.
pinch_from_ctrl_wheel: bool = true,

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
pub const velocity_window = 0.1;
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

/// How far a stick or a trigger goes before the player counts as using the
/// controller: a resting stick's drift does not.
const device_threshold = 0.5;

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

/// The most fingers followed at once.
pub const max_fingers = 16;

/// The finger the left mouse button is, when `touch_from_mouse` says it is
/// one.
pub const mouse_as_finger: u32 = std.math.maxInt(u32);

/// One finger on a touch screen, as this frame has it.
pub const Touch = struct {
    /// Which finger: the same number from the frame it touches to the frame
    /// it is lifted. Another may have the number afterwards.
    finger: u32 = 0,
    /// Where it is, in the game area's pixels, as the pointer's.
    position: Vec2 = .zero,
    /// Where it touched.
    start: Vec2 = .zero,
    /// How far it moved this frame.
    relative: Vec2 = .zero,
    /// How hard it presses, from nought to one.
    pressure: f32 = 1,
    /// It touched this frame.
    pressed: bool = false,
    /// It was lifted this frame, its last here.
    released: bool = false,
    /// Lifted by the system rather than the player: whatever it was doing
    /// should not happen.
    canceled: bool = false,
    /// The mouse as well: the first finger. See `mouse_from_touch`.
    mouse: bool = false,
    /// A `TouchButton` holds it this frame.
    on_button: bool = false,
    /// A frame has seen it as it is: what that frame said of it - its edges,
    /// its moving - goes at the next frame's top.
    seen: bool = false,

    pub const reflect_name = "Touch";
    pub const reflect_fields = .{ .seen = .{attr.Hidden{}} };

    /// This frame's news of it gone, once a frame has seen it: what it
    /// says from here is new.
    fn fresh(self: *Touch) void {
        if (!self.seen) return;
        self.pressed = false;
        self.relative = .zero;
        self.on_button = false;
        self.seen = false;
    }

    /// Down now: touched and not lifted.
    pub fn down(self: Touch) bool {
        return !self.released;
    }
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

/// This frame's fingers, in the order they touched: every one down, and
/// every one lifted this frame, with `released` set.
pub fn touches(self: *const Input) []const Touch {
    return self.fingers[0..self.finger_count];
}

/// A finger of this frame by its number, or null.
pub fn touchOf(self: *const Input, finger: u32) ?Touch {
    for (self.touches()) |held| {
        if (held.finger == finger) return held;
    }
    return null;
}

/// How many fingers are down now.
pub fn fingersDown(self: *const Input) usize {
    var count: usize = 0;
    for (self.touches()) |held| {
        if (held.down()) count += 1;
    }
    return count;
}

/// -1, 0 or 1 from two keys held.
pub fn keyAxis(self: *const Input, negative: platform.Key, positive: platform.Key) f32 {
    var value: f32 = 0;
    if (self.isDown(negative)) value -= 1;
    if (self.isDown(positive)) value += 1;
    return value;
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

/// Work out what the fingers made this frame - a tap, a long press, a swipe,
/// two fingers' pinch, pan and turn - and put it with the pointer's events
/// for the scripts to hear. Called by `App` once a frame, after the touch
/// buttons, with the frame's time unscaled: a gesture is the player's hand,
/// not the game's clock.
pub fn trackFingers(self: *Input, delta: f32) void {
    self.gestures.follow(self, delta);
}

/// What the pointer did this frame, oldest first: presses, releases, the
/// wheel's turns, and one motion for the frame's moving. Picking hands
/// each to whatever is under it.
pub fn pointerEvents(self: *const Input) []const events.InputEvent {
    return self.pointer_events[0..self.pointer_events_len];
}

/// Which buttons are held now, as a mask.
pub fn buttonMask(self: *const Input) events.ButtonMask {
    var mask: events.ButtonMask = .none;
    for (0..@min(button_span, platform.MouseButton.max + 1)) |i| {
        if (self.button_down.isSet(i)) mask = mask.with(@enumFromInt(@as(u8, @intCast(i))), true);
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

/// The controller slots something is plugged into, from nought, written
/// into `into`.
pub fn connectedPads(self: *const Input, into: *[max_pads]u8) []const u8 {
    var count: usize = 0;
    for (self.pads, 0..) |held, slot| {
        if (!held.connected) continue;
        into[count] = @intCast(slot);
        count += 1;
    }
    return into[0..count];
}

/// One controller slot, or every connected controller for null.
pub fn padOrAny(self: *const Input, slot: ?u8) Pad {
    return if (slot) |held| self.pad(held) else self.anyPad();
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

    // The fingers last frame saw lifted are gone, and the rest start the
    // frame still; one given between frames is this frame's news.
    var still_down: usize = 0;
    for (self.fingers[0..self.finger_count]) |held| {
        if (held.released and held.seen) continue;
        self.fingers[still_down] = held;
        self.fingers[still_down].fresh();
        still_down += 1;
    }
    self.finger_count = still_down;

    // The pointer events a whole frame has had go; one given between
    // frames stays for this one, as a dialog's answer does.
    const keys_unseen = self.key_events_len - self.key_events_seen;
    std.mem.copyForwards(platform.event.KeyEvent, self.key_events[0..keys_unseen], self.key_events[self.key_events_seen..self.key_events_len]);
    self.key_events_len = keys_unseen;
    self.key_events_seen = 0;

    const unseen = self.pointer_events_len - self.pointer_events_seen;
    std.mem.copyForwards(events.InputEvent, self.pointer_events[0..unseen], self.pointer_events[self.pointer_events_seen..self.pointer_events_len]);
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
    for (self.fingers[0..self.finger_count]) |*held| held.seen = true;
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
/// A point across the window, in the game area's pixels.
fn frameX(self: *const Input, x: f64) f32 {
    return (@as(f32, @floatCast(x)) - self.area_origin.x) * self.area_ratio;
}

fn frameY(self: *const Input, y: f64) f32 {
    return (@as(f32, @floatCast(y)) - self.area_origin.y) * self.area_ratio;
}

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
            if (b.from_touch and !self.mouse_from_touch) return;
            self.mods = b.mods;
            // A locked pointer has no position to report.
            if (!self.pointer.locked) {
                self.pointer.x = self.frameX(b.x);
                self.pointer.y = self.frameY(b.y);
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
            if (b.action != .repeat and b.button.index() != null) self.pushPointer(.{ .mouse_button = .{
                .button = b.button,
                .pressed = b.action == .press,
                .double_click = b.double_click,
                .position = .init(self.pointer.x, self.pointer.y),
                .buttons = self.buttonMask(),
                .mods = b.mods,
            } });
            if (self.touch_from_mouse and !b.from_touch and b.button == .left and b.action != .repeat and !self.pointer.locked) {
                self.touched(mouse_as_finger, .init(self.pointer.x, self.pointer.y), if (b.action == .press) .down else .up, 1);
            }
        },
        .cursor => |m| {
            if (m.from_touch and !self.mouse_from_touch) return;
            if (self.pointer.locked) {
                // Movement only, and only while the window has the keyboard:
                // in the background, the hand on the mouse is using another
                // program.
                if (self.focused) {
                    self.pointer.dx += @as(f32, @floatCast(m.dx)) * self.area_ratio;
                    self.pointer.dy += @as(f32, @floatCast(m.dy)) * self.area_ratio;
                }
                return;
            }
            self.pointer.x = self.frameX(m.x);
            self.pointer.y = self.frameY(m.y);
            const moved: math.Vec2 = .init(@as(f32, @floatCast(m.dx)) * self.area_ratio, @as(f32, @floatCast(m.dy)) * self.area_ratio);
            self.pointer.dx += moved.x;
            self.pointer.dy += moved.y;
            self.pushMotion(moved);
            if (self.touch_from_mouse and !m.from_touch and self.buttonDown(.left)) {
                self.touched(mouse_as_finger, .init(self.pointer.x, self.pointer.y), .move, 1);
            }
        },
        .touch => |t| {
            self.touchscreen = true;
            self.touched(t.finger, .init(self.frameX(t.x), self.frameY(t.y)), t.phase, t.pressure);
        },
        .cursor_enter => |s| self.pointer.inside = s.value,
        .scroll => |w| {
            self.mods = w.mods;
            self.wheel.x += @floatCast(w.x);
            self.wheel.y += @floatCast(w.y);
            if (w.x != 0 or w.y != 0) self.pushPointer(.{ .wheel = .{
                .delta = .init(@floatCast(w.x), @floatCast(w.y)),
                .position = .init(self.pointer.x, self.pointer.y),
                .buttons = self.buttonMask(),
                .mods = w.mods,
            } });
            if (w.mods.control and w.y != 0 and self.pinch_from_ctrl_wheel) self.gestures.wheelPinch(self, @floatCast(w.y));
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
                .x = if (point) self.frameX(d.x) else self.pointer.x,
                .y = if (point) self.frameY(d.y) else self.pointer.y,
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

/// A finger touched, moved or was lifted, at `at` in the game area's pixels.
fn touched(self: *Input, finger: u32, at: Vec2, phase: platform.event.TouchPhase, pressure: f32) void {
    switch (phase) {
        .down => {
            if (self.liveFinger(finger) != null or self.finger_count == self.fingers.len) return;
            // The platform's rule for the finger that is the mouse: the one
            // that touches when no other is down.
            const mouse = finger != mouse_as_finger and self.fingersDown() == 0;
            self.fingers[self.finger_count] = .{ .finger = finger, .position = at, .start = at, .pressure = pressure, .pressed = true, .mouse = mouse };
            self.finger_count += 1;
            self.pushPointer(.{ .touch = .{ .finger = finger, .pressed = true, .position = at, .pressure = pressure } });
        },
        .move => {
            const held = self.liveFinger(finger) orelse return;
            held.fresh();
            const by = at.sub(held.position);
            held.position = at;
            held.relative = held.relative.add(by);
            held.pressure = pressure;
            self.pushTouchMotion(finger, at, by, pressure);
        },
        .up, .cancel => {
            const held = self.liveFinger(finger) orelse return;
            held.fresh();
            held.position = at;
            held.released = true;
            held.canceled = phase == .cancel;
            self.pushPointer(.{ .touch = .{ .finger = finger, .canceled = held.canceled, .position = at, .pressure = pressure } });
        },
    }
}

/// A finger down now, by its number.
fn liveFinger(self: *Input, finger: u32) ?*Touch {
    for (self.fingers[0..self.finger_count]) |*held| {
        if (held.finger == finger and held.down()) return held;
    }
    return null;
}

/// A finger's motion, added to its last motion this frame when nothing of
/// that finger came since: a frame's moving is one event a finger.
fn pushTouchMotion(self: *Input, finger: u32, at: Vec2, by: Vec2, pressure: f32) void {
    var i = self.pointer_events_len;
    while (i > self.pointer_events_seen) {
        i -= 1;
        const earlier = &self.pointer_events[i];
        if (earlier.finger() != finger) continue;
        if (earlier.* != .touch_motion) break;
        earlier.touch_motion.position = at;
        earlier.touch_motion.relative = earlier.touch_motion.relative.add(by);
        earlier.touch_motion.pressure = pressure;
        return;
    }
    self.pushPointer(.{ .touch_motion = .{ .finger = finger, .position = at, .relative = by, .pressure = pressure } });
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
    for (self.fingers[0..self.finger_count]) |*held| {
        if (!held.down()) continue;
        held.released = true;
        held.canceled = true;
    }
}

/// One pointer event, dropped rather than grown, as the typed ones are.
pub fn pushPointer(self: *Input, event: events.InputEvent) void {
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
            last.mouse_motion.buttons = self.buttonMask();
            last.mouse_motion.mods = self.mods;
            return;
        }
    }
    self.pushPointer(.{ .mouse_motion = .{
        .position = at,
        .relative = by,
        .buttons = self.buttonMask(),
        .mods = self.mods,
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
