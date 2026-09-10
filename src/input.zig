// SPDX-License-Identifier: BSD-3-Clause

//! What the keyboard and the mouse did, as a thing to ask rather than a thing
//! to be told.
//!
//! ```zig
//! fn steer(app: *App) !void {
//!     const x = app.input.axis(.a, .d);          // -1, 0 or 1
//!     if (app.input.justPressed(.space)) jump();
//!     if (app.input.buttonDown(.left)) shoot(app.input.pointer.x, app.input.pointer.y);
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

const std = @import("std");
const testing = std.testing;

const platform = @import("fluxion_platform");

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

/// How much typing one frame can hold. A fast typist manages about twenty
/// characters a second, so this is more than a frame will ever see.
pub const typed_capacity = 32;

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

/// Two keys as one number: -1, 0 or 1.
///
/// ```zig
/// const dx = input.axis(.a, .d);
/// const dy = input.axis(.w, .s);
/// ```
///
/// Both down is zero rather than whichever was pressed last. That is a real
/// choice and the less annoying one: the alternative needs the order the keys
/// arrived in, which means state, and a player resting a thumb on both keys
/// expects to stop.
pub fn axis(self: *const Input, negative: platform.Key, positive: platform.Key) f32 {
    const n: f32 = if (self.isDown(negative)) 1 else 0;
    const p: f32 = if (self.isDown(positive)) 1 else 0;
    return p - n;
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
            self.pointer.x = @floatCast(b.x);
            self.pointer.y = @floatCast(b.y);
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
        // Focus lost with keys held would otherwise leave them held for ever:
        // the release arrives at whatever window took the focus, and this one
        // never hears about it. Alt+Tab away while walking, and walk into the
        // wall for the rest of the session.
        .focus => |s| if (!s.value) self.releaseEverything(),
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
    try testing.expectEqual(@as(f32, -1), input.axis(.a, .d));

    input.apply(keyEvent(.d, .press));
    try testing.expectEqual(@as(f32, 0), input.axis(.a, .d));
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
