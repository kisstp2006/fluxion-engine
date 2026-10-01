// SPDX-License-Identifier: BSD-3-Clause

//! A game's own states - menu, playing, paused, game over - each an enum
//! holding one value at a time, and each changed between frames.
//!
//! ```zig
//! const Mode = enum { menu, playing, paused };
//!
//! try app.addState(Mode.menu);
//! try app.addSystemIn(.update, Mode.playing, "move", move);
//! try app.onEnter(Mode.paused, "pause menu", showPauseMenu);
//! try app.setState(Mode.paused);
//! ```
//!
//! **A change waits for the top of the next frame.** Every system of this
//! frame sees the same value, whichever of them asked; then the systems for
//! leaving the old value run, the value changes, and the ones for entering
//! the new one run, before the frame's first stage. A change asked for while
//! entering waits for the frame after, so two states cannot chase each other
//! round in one frame.
//!
//! **Any number of state types**, each its own: a `Mode` and a `Weather`
//! change apart, and a system can ask about both.

const std = @import("std");
const Allocator = std.mem.Allocator;

const reflect = @import("fluxion_reflect");

const App = @import("../App.zig");

const States = @This();

slots: std.ArrayList(Slot) = .empty,

/// One state type's value.
pub const Slot = struct {
    key: usize,
    /// What a debugger, an editor and `App.setStateNamed` call the type: its
    /// `reflect_name`, or its name without the path in front - `Mode`, not
    /// `game.Mode`.
    name: []const u8,
    /// The type, whose members name the values.
    type: *const reflect.Type,
    current: u32,
    /// What `set` asked for, done at the top of the next frame.
    pending: ?u32 = null,

    /// The name of the value it has now.
    pub fn currentName(self: Slot) []const u8 {
        return self.type.memberOf(self.current).?.name.slice();
    }
};

/// One value of one state type, as a condition or a hook keeps it.
pub const Value = struct {
    key: usize,
    value: u32,

    pub fn of(value: anytype) Value {
        return .{ .key = keyOf(@TypeOf(value)), .value = @intFromEnum(value) };
    }

    pub fn eql(a: Value, b: Value) bool {
        return a.key == b.key and a.value == b.value;
    }
};

/// A number that is `T`'s own: the address of a variable only `T` has.
pub fn keyOf(comptime T: type) usize {
    comptime check(T);
    return @intFromPtr(&Key(T).unique);
}

fn Key(comptime T: type) type {
    return struct {
        const of = T;
        var unique: u8 = 0;
    };
}

fn check(comptime T: type) void {
    const info = switch (@typeInfo(T)) {
        .@"enum" => |info| info,
        else => @compileError("fluxion-engine: a state is an enum, and " ++ @typeName(T) ++ " is not one"),
    };
    if (!info.is_exhaustive) @compileError("fluxion-engine: a state is an exhaustive enum, and " ++ @typeName(T) ++ " is not");
    if (info.fields.len == 0) @compileError("fluxion-engine: a state needs a value to be in, and " ++ @typeName(T) ++ " has none");
    if (@bitSizeOf(info.tag_type) > 32) @compileError("fluxion-engine: " ++ @typeName(T) ++ "'s values do not fit in 32 bits");
}

/// The value a state starts in unless told otherwise: its first.
fn firstOf(comptime T: type) T {
    return @field(T, @typeInfo(T).@"enum".fields[0].name);
}

pub fn deinit(self: *States, gpa: Allocator) void {
    self.slots.deinit(gpa);
    self.* = undefined;
}

fn find(self: *const States, key: usize) ?usize {
    for (self.slots.items, 0..) |slot, i| {
        if (slot.key == key) return i;
    }
    return null;
}

/// `T`'s slot, made at `T`'s first value the first time `T` is named.
pub fn slotFor(self: *States, gpa: Allocator, comptime T: type) Allocator.Error!*Slot {
    const key = keyOf(T);
    if (self.find(key)) |i| return &self.slots.items[i];
    try self.slots.append(gpa, .{
        .key = key,
        .name = comptime nameOf(T),
        .type = reflect.typeOf(T),
        .current = @intFromEnum(firstOf(T)),
    });
    return &self.slots.items[self.slots.items.len - 1];
}

/// Where in `slots` the state type called `name` is, if anything has named
/// it.
pub fn named(self: *const States, name: []const u8) ?usize {
    for (self.slots.items, 0..) |slot, i| {
        if (std.mem.eql(u8, slot.name, name)) return i;
    }
    return null;
}

/// As a scene names a component, less the `scene_name`.
fn nameOf(comptime T: type) []const u8 {
    if (@hasDecl(T, "reflect_name")) return T.reflect_name;
    const full = @typeName(T);
    const end = std.mem.indexOfScalar(u8, full, '(') orelse full.len;
    const start = if (std.mem.lastIndexOfScalar(u8, full[0..end], '.')) |dot| dot + 1 else 0;
    return full[start..];
}

/// `T`'s value now, or its first for a state nothing has named yet.
pub fn get(self: *const States, comptime T: type) T {
    const i = self.find(keyOf(T)) orelse return firstOf(T);
    return @enumFromInt(self.slots.items[i].current);
}

/// Change `value`'s state to it at the top of the next frame. The last asked
/// for wins.
pub fn set(self: *States, gpa: Allocator, value: anytype) Allocator.Error!void {
    const slot = try self.slotFor(gpa, @TypeOf(value));
    slot.pending = @intFromEnum(value);
}

/// Whether a state has this value now.
pub fn is(self: *const States, wanted: Value) bool {
    const i = self.find(wanted.key) orelse return false;
    return self.slots.items[i].current == wanted.value;
}

/// Do the changes `App.setState` asked for: a pass of `app/frame_steps.zig`, at
/// the top of each frame.
pub fn changeAsked(app: *App) anyerror!void {
    // By index: a hook may name a new state, and the list may move.
    var at: usize = 0;
    while (at < app.states.slots.items.len) : (at += 1) {
        const slot = app.states.slots.items[at];
        const next = slot.pending orelse continue;
        app.states.slots.items[at].pending = null;
        if (next == slot.current) continue;
        try app.schedule.runHooks(.exit, .{ .key = slot.key, .value = slot.current }, app);
        app.states.slots.items[at].current = next;
        try app.schedule.runHooks(.enter, .{ .key = slot.key, .value = next }, app);
    }
}

/// Enter every state at its first value, or the one `.startup` asked for.
pub fn enterFirst(app: *App) anyerror!void {
    var at: usize = 0;
    while (at < app.states.slots.items.len) : (at += 1) {
        const slot = &app.states.slots.items[at];
        if (slot.pending) |chosen| slot.current = chosen;
        slot.pending = null;
        const entered: Value = .{ .key = slot.key, .value = slot.current };
        try app.schedule.runHooks(.enter, entered, app);
    }
}
