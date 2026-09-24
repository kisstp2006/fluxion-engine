// SPDX-License-Identifier: BSD-3-Clause

//! A game's actions: `jump`, `move_left`, `pause` - each a name, and the
//! keys, mouse buttons and controller inputs that set it off.
//!
//! ```zig
//! if (app.input.actionJustPressed("jump")) jump();
//! const walk = app.input.actionVector("move_left", "move_right", "move_up", "move_down");
//! try app.input.actions.bind(gpa, "jump", .keyOf(.j));  // rebound as the game runs
//! ```
//!
//! A project names its actions in its project file, and the player's
//! changes can be kept in a file of their own:
//!
//! ```json
//! "input": { "actions": [
//!   { "name": "jump", "bindings": [ { "type": "key", "key": "space" }, { "type": "pad_button", "button": "a" } ] },
//!   { "name": "move_left", "deadzone": 0.2, "bindings": [ { "type": "key", "key": "a" }, { "type": "pad_axis", "axis": "left_x", "direction": "negative" } ] }
//! ] }
//! ```
//!
//! **Six actions are always there**, for moving round an interface:
//! `ui_accept`, `ui_cancel`, `ui_left`, `ui_right`, `ui_up` and `ui_down`
//! (see `builtin`). A project's action of the same name takes the place of
//! one, so a game can move them to other keys; the project file holds only
//! what differs.
//!
//! **An action is down while any of its inputs is.** Letting go of one of
//! two keys held does not let go of it, and pressing the second is no new
//! press: its edges come from the action going down and coming up. A key
//! pressed and let go inside one frame is a press and a release all the same.
//! What the edges and the state are, and when, is `Input`'s: see
//! `Input.updateActions`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const json = @import("fluxion_json");
const platform = @import("fluxion_platform");

/// One input that sets an action off.
pub const Binding = union(enum) {
    key: Key,
    mouse_button: MouseButton,
    pad_button: PadButton,
    pad_axis: PadAxis,

    /// `{ "type": "key", "key": "space" }` in a file.
    pub const json_tag = "type";

    pub const Key = struct {
        key: platform.Key,
        /// The key at this place on a US layout, whatever the player's layout
        /// is - what WASD wants. False is the key the player's layout puts
        /// this letter on, wherever that is: a key named by what it says.
        physical: bool = true,
    };

    pub const MouseButton = struct {
        button: platform.MouseButton,
    };

    pub const PadButton = struct {
        button: platform.GamepadButton,
        /// Which controller slot, from nought; null for any of them.
        pad: ?u8 = null,
    };

    pub const PadAxis = struct {
        axis: platform.GamepadAxis,
        /// Which way it is pushed: left and up are negative on a stick. A
        /// trigger only goes one way, the positive.
        direction: Direction = .positive,
        pad: ?u8 = null,
    };

    pub const Direction = enum { negative, positive };

    pub fn keyOf(key: platform.Key) Binding {
        return .{ .key = .{ .key = key } };
    }

    pub fn mouseButtonOf(button: platform.MouseButton) Binding {
        return .{ .mouse_button = .{ .button = button } };
    }

    pub fn padButtonOf(button: platform.GamepadButton) Binding {
        return .{ .pad_button = .{ .button = button } };
    }

    pub fn padAxisOf(axis: platform.GamepadAxis, direction: Direction) Binding {
        return .{ .pad_axis = .{ .axis = axis, .direction = direction } };
    }

    pub fn eql(a: Binding, b: Binding) bool {
        return std.meta.eql(a, b);
    }

    /// Which hand is on it: the keyboard and the mouse, or a controller.
    pub fn device(self: Binding) Device {
        return switch (self) {
            .key, .mouse_button => .keyboard,
            .pad_button, .pad_axis => .pad,
        };
    }

    /// What a player reads it as: `Space`, `Left Mouse`, `Pad A`, `Left
    /// Stick Left`, and which controller when it is one's alone.
    pub fn format(self: Binding, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .key => |held| try writeKey(w, held.key),
            .mouse_button => |held| switch (held.button) {
                .left => try w.writeAll("Left Mouse"),
                .right => try w.writeAll("Right Mouse"),
                .middle => try w.writeAll("Middle Mouse"),
                else => try w.print("Mouse {d}", .{@intFromEnum(held.button) + 1}),
            },
            .pad_button => |held| {
                try w.writeAll(padButtonName(held.button));
                try writePad(w, held.pad);
            },
            .pad_axis => |held| {
                try w.writeAll(padAxisName(held.axis, held.direction));
                try writePad(w, held.pad);
            },
        }
    }
};

/// Which hand an input is under. See `Input.last_device`.
pub const Device = enum { keyboard, pad };

/// An action as a project file and `Actions` hold it.
pub const Action = struct {
    name: []const u8,
    /// How far a stick or a trigger has to go before it counts, from nought
    /// to one. Keys and buttons are down or not.
    deadzone: f32 = default_deadzone,
    bindings: []const Binding = &.{},

    pub const default_deadzone = 0.5;
};

/// The actions every game has, for moving round an interface with the
/// keyboard or a controller. A project's own action of the same name takes
/// the place of one.
pub const builtin = [_]Action{
    .{ .name = "ui_accept", .bindings = &.{ .keyOf(.enter), .keyOf(.kp_enter), .keyOf(.space), .padButtonOf(.a) } },
    .{ .name = "ui_cancel", .bindings = &.{ .keyOf(.escape), .padButtonOf(.b) } },
    .{ .name = "ui_left", .bindings = &.{ .keyOf(.left), .padButtonOf(.dpad_left), .padAxisOf(.left_x, .negative) } },
    .{ .name = "ui_right", .bindings = &.{ .keyOf(.right), .padButtonOf(.dpad_right), .padAxisOf(.left_x, .positive) } },
    .{ .name = "ui_up", .bindings = &.{ .keyOf(.up), .padButtonOf(.dpad_up), .padAxisOf(.left_y, .negative) } },
    .{ .name = "ui_down", .bindings = &.{ .keyOf(.down), .padButtonOf(.dpad_down), .padAxisOf(.left_y, .positive) } },
};

/// The built-in action called `name`, as the engine has it.
pub fn builtinNamed(name: []const u8) ?Action {
    for (builtin) |action| {
        if (std.mem.eql(u8, action.name, name)) return action;
    }
    return null;
}

/// Where an action is this frame. Worked out by `Input.updateActions`.
pub const State = struct {
    down: bool = false,
    /// From nought to one: one for a key, how far past the dead zone for a
    /// stick.
    strength: f32 = 0,
    /// The same without what the keyboard gives: what an interface moves by
    /// while its keys are for typing.
    strength_off_keys: f32 = 0,
    pressed: bool = false,
    released: bool = false,
    /// The edges again, since the last fixed step.
    fixed_pressed: bool = false,
    fixed_released: bool = false,
    /// What `Input.pressAction` holds it at, or nought.
    forced: f32 = 0,
};

/// The actions a running game has: the built-in ones, the project's, and
/// what the game changed of them since. `Input.actions`.
pub const Actions = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        name: []u8,
        deadzone: f32,
        bindings: std.ArrayList(Binding) = .empty,
        state: State = .{},

        fn deinit(self: *Entry, gpa: Allocator) void {
            gpa.free(self.name);
            self.bindings.deinit(gpa);
        }

        /// It as an `Action`, lent until it changes.
        pub fn action(self: *const Entry) Action {
            return .{ .name = self.name, .deadzone = self.deadzone, .bindings = self.bindings.items };
        }
    };

    pub const Error = error{
        /// An action of that name is there already.
        ActionExists,
        NoSuchAction,
        /// An action needs a name.
        EmptyName,
    } || Allocator.Error;

    pub fn deinit(self: *Actions, gpa: Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(gpa);
        self.entries.deinit(gpa);
        self.* = .{};
    }

    /// Every action there is, in order: the built-in ones, then the
    /// project's own.
    pub fn list(self: *const Actions) []const Entry {
        return self.entries.items;
    }

    pub fn find(self: *Actions, name: []const u8) ?*Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    pub fn findConst(self: *const Actions, name: []const u8) ?*const Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    /// The action called `name`, lent until it changes.
    pub fn get(self: *const Actions, name: []const u8) ?Action {
        const entry = self.findConst(name) orelse return null;
        return entry.action();
    }

    /// The built-in actions, and a project's over them: what a game starts
    /// with. Everything held before goes, its state with it.
    pub fn reset(self: *Actions, gpa: Allocator, project: []const Action) Allocator.Error!void {
        self.deinit(gpa);
        errdefer self.deinit(gpa);
        for (builtin) |action| try self.set(gpa, action);
        for (project) |action| {
            if (action.name.len == 0) continue;
            try self.set(gpa, action);
        }
    }

    /// A new action. `error.ActionExists` for a name there already.
    pub fn add(self: *Actions, gpa: Allocator, action: Action) Error!void {
        if (action.name.len == 0) return error.EmptyName;
        if (self.findConst(action.name) != null) return error.ActionExists;
        try self.set(gpa, action);
    }

    /// An action, new or in the place of the one of that name: its dead
    /// zone and its inputs, and where it stands as it was.
    pub fn set(self: *Actions, gpa: Allocator, action: Action) Allocator.Error!void {
        if (self.find(action.name)) |entry| {
            entry.deadzone = clampDeadzone(action.deadzone);
            entry.bindings.clearRetainingCapacity();
            try appendUnique(gpa, &entry.bindings, action.bindings);
            return;
        }
        var entry: Entry = .{ .name = try gpa.dupe(u8, action.name), .deadzone = clampDeadzone(action.deadzone) };
        errdefer entry.deinit(gpa);
        try appendUnique(gpa, &entry.bindings, action.bindings);
        try self.entries.append(gpa, entry);
    }

    /// Take an action out. Says whether it was there.
    pub fn remove(self: *Actions, gpa: Allocator, name: []const u8) bool {
        for (self.entries.items, 0..) |*entry, at| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            entry.deinit(gpa);
            _ = self.entries.orderedRemove(at);
            return true;
        }
        return false;
    }

    pub fn rename(self: *Actions, gpa: Allocator, old: []const u8, new: []const u8) Error!void {
        if (new.len == 0) return error.EmptyName;
        const entry = self.find(old) orelse return error.NoSuchAction;
        if (std.mem.eql(u8, old, new)) return;
        if (self.findConst(new) != null) return error.ActionExists;
        const owned = try gpa.dupe(u8, new);
        gpa.free(entry.name);
        entry.name = owned;
    }

    /// One more input for an action. One it has already is not added twice.
    pub fn bind(self: *Actions, gpa: Allocator, name: []const u8, binding: Binding) Error!void {
        const entry = self.find(name) orelse return error.NoSuchAction;
        try appendUnique(gpa, &entry.bindings, &.{binding});
    }

    /// Take an input off an action. Says whether it had it.
    pub fn unbind(self: *Actions, name: []const u8, binding: Binding) bool {
        const entry = self.find(name) orelse return false;
        for (entry.bindings.items, 0..) |held, at| {
            if (!held.eql(binding)) continue;
            _ = entry.bindings.orderedRemove(at);
            return true;
        }
        return false;
    }

    /// Take every input off an action, to give it new ones.
    pub fn unbindAll(self: *Actions, name: []const u8) bool {
        const entry = self.find(name) orelse return false;
        entry.bindings.clearRetainingCapacity();
        return true;
    }

    pub fn setDeadzone(self: *Actions, name: []const u8, deadzone: f32) bool {
        const entry = self.find(name) orelse return false;
        entry.deadzone = clampDeadzone(deadzone);
        return true;
    }

    /// The version `write` puts at the top of a file, and `read` takes.
    pub const file_version = 1;

    /// Every action as a file of its own - `{ "fluxion_input_map": 1,
    /// "actions": [...] }` - to keep what the player changed. The caller
    /// frees it.
    pub fn write(self: *const Actions, gpa: Allocator) json.StringifyError![]u8 {
        const held = try gpa.alloc(Action, self.entries.items.len);
        defer gpa.free(held);
        for (self.entries.items, held) |*entry, *action| action.* = entry.action();
        return json.stringify(gpa, File{ .actions = held }, .{ .indent = 2, .skip_defaults = true });
    }

    /// Take what a file `write` wrote says of each action this game has:
    /// its dead zone and its inputs. An action the game no longer has is
    /// passed over, so a save from before an update still reads. Says how
    /// many were taken.
    pub fn read(self: *Actions, gpa: Allocator, text: []const u8, diagnostics: ?*json.Diagnostics) !usize {
        const parsed = try json.parseAs(File, gpa, text, .{ .syntax = .json5, .unknown_fields = .ignore, .diagnostics = diagnostics });
        defer parsed.deinit();
        if (parsed.value.fluxion_input_map != file_version) {
            if (diagnostics) |d| d.setMessage("this input map is version {d}, and this build reads version {d}", .{ parsed.value.fluxion_input_map, file_version });
            return error.UnsupportedVersion;
        }
        var taken: usize = 0;
        for (parsed.value.actions) |action| {
            if (self.findConst(action.name) == null) continue;
            try self.set(gpa, action);
            taken += 1;
        }
        return taken;
    }

    const File = struct {
        fluxion_input_map: u32 = file_version,
        actions: []const Action = &.{},
    };
};

fn clampDeadzone(value: f32) f32 {
    if (std.math.isNan(value)) return Action.default_deadzone;
    return std.math.clamp(value, 0, 0.99);
}

fn appendUnique(gpa: Allocator, into: *std.ArrayList(Binding), bindings: []const Binding) Allocator.Error!void {
    outer: for (bindings) |binding| {
        for (into.items) |held| if (held.eql(binding)) continue :outer;
        try into.append(gpa, binding);
    }
}

/// A key's name in words: `Space`, `Left Shift`, `Keypad 7`, `F5`.
fn writeKey(w: *std.Io.Writer, key: platform.Key) std.Io.Writer.Error!void {
    if (!key.named() or key == .unknown) return w.print("Key {d}", .{@intFromEnum(key)});
    var name = @tagName(key);
    if (std.mem.startsWith(u8, name, "kp_")) {
        try w.writeAll("Keypad ");
        name = name[3..];
    }
    var first = true;
    var words = std.mem.tokenizeScalar(u8, name, '_');
    while (words.next()) |word| {
        if (!first) try w.writeByte(' ');
        first = false;
        try w.writeByte(std.ascii.toUpper(word[0]));
        try w.writeAll(word[1..]);
    }
}

fn padButtonName(button: platform.GamepadButton) []const u8 {
    return switch (button) {
        .a => "Pad A",
        .b => "Pad B",
        .x => "Pad X",
        .y => "Pad Y",
        .left_bumper => "Pad LB",
        .right_bumper => "Pad RB",
        .back => "Pad Back",
        .start => "Pad Start",
        .guide => "Pad Guide",
        .left_thumb => "Pad LS",
        .right_thumb => "Pad RS",
        .dpad_up => "Pad Up",
        .dpad_right => "Pad Right",
        .dpad_down => "Pad Down",
        .dpad_left => "Pad Left",
    };
}

fn padAxisName(axis: platform.GamepadAxis, direction: Binding.Direction) []const u8 {
    const negative = direction == .negative;
    return switch (axis) {
        .left_x => if (negative) "Left Stick Left" else "Left Stick Right",
        .left_y => if (negative) "Left Stick Up" else "Left Stick Down",
        .right_x => if (negative) "Right Stick Left" else "Right Stick Right",
        .right_y => if (negative) "Right Stick Up" else "Right Stick Down",
        .left_trigger => "Left Trigger",
        .right_trigger => "Right Trigger",
    };
}

fn writePad(w: *std.Io.Writer, pad: ?u8) std.Io.Writer.Error!void {
    if (pad) |slot| try w.print(" (pad {d})", .{@as(u32, slot) + 1});
}

test "an input reads as a player would say it" {
    var buffer: [64]u8 = undefined;
    const cases = [_]struct { Binding, []const u8 }{
        .{ .keyOf(.space), "Space" },
        .{ .keyOf(.left_shift), "Left Shift" },
        .{ .keyOf(.kp_7), "Keypad 7" },
        .{ .keyOf(.e), "E" },
        .{ .mouseButtonOf(.right), "Right Mouse" },
        .{ .mouseButtonOf(.button_4), "Mouse 4" },
        .{ .padButtonOf(.a), "Pad A" },
        .{ .{ .pad_button = .{ .button = .start, .pad = 1 } }, "Pad Start (pad 2)" },
        .{ .padAxisOf(.left_x, .negative), "Left Stick Left" },
        .{ .padAxisOf(.right_trigger, .positive), "Right Trigger" },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(case[1], try std.fmt.bufPrint(&buffer, "{f}", .{case[0]}));
    }
}

test "the built-in actions are there first, and a project's action takes the place of one" {
    var actions: Actions = .{};
    defer actions.deinit(testing.allocator);
    try actions.reset(testing.allocator, &.{
        .{ .name = "ui_accept", .bindings = &.{.keyOf(.j)} },
        .{ .name = "jump", .deadzone = 2, .bindings = &.{ .keyOf(.space), .keyOf(.space), .padButtonOf(.a) } },
    });
    try testing.expectEqual(builtin.len + 1, actions.list().len);
    try testing.expectEqualStrings("ui_accept", actions.list()[0].name);
    try testing.expectEqual(@as(usize, 1), actions.get("ui_accept").?.bindings.len);
    const jump = actions.get("jump").?;
    // Twice the same input is one, and a dead zone is less than the whole.
    try testing.expectEqual(@as(usize, 2), jump.bindings.len);
    try testing.expectEqual(@as(f32, 0.99), jump.deadzone);

    try testing.expectError(error.ActionExists, actions.add(testing.allocator, .{ .name = "jump" }));
    try testing.expectError(error.EmptyName, actions.add(testing.allocator, .{ .name = "" }));
    try actions.rename(testing.allocator, "jump", "leap");
    try testing.expectError(error.ActionExists, actions.rename(testing.allocator, "leap", "ui_cancel"));
    try actions.bind(testing.allocator, "leap", .keyOf(.w));
    try testing.expect(actions.unbind("leap", .keyOf(.space)));
    try testing.expect(!actions.unbind("leap", .keyOf(.space)));
    try testing.expectError(error.NoSuchAction, actions.bind(testing.allocator, "jump", .keyOf(.w)));
    try testing.expect(actions.remove(testing.allocator, "leap"));
    try testing.expect(actions.get("leap") == null);
}

test "a player's input map is written, and read back over the game's own" {
    var actions: Actions = .{};
    defer actions.deinit(testing.allocator);
    try actions.reset(testing.allocator, &.{.{ .name = "jump", .bindings = &.{.keyOf(.space)} }});
    try testing.expect(actions.unbindAll("jump"));
    try actions.bind(testing.allocator, "jump", .{ .key = .{ .key = .z, .physical = false } });
    try actions.bind(testing.allocator, "jump", .{ .pad_axis = .{ .axis = .right_trigger, .pad = 0 } });
    const text = try actions.write(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"type\": \"key\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"physical\": false") != null);

    var other: Actions = .{};
    defer other.deinit(testing.allocator);
    try other.reset(testing.allocator, &.{.{ .name = "jump", .bindings = &.{.keyOf(.space)} }});
    _ = other.remove(testing.allocator, "ui_down");
    // Every action there is, save the one this game does not have.
    try testing.expectEqual(builtin.len, try other.read(testing.allocator, text, null));
    const jump = other.get("jump").?;
    try testing.expectEqual(@as(usize, 2), jump.bindings.len);
    try testing.expect(jump.bindings[0].eql(.{ .key = .{ .key = .z, .physical = false } }));
    try testing.expectEqual(@as(?u8, 0), jump.bindings[1].pad_axis.pad);
    try testing.expect(other.get("ui_down") == null);

    try testing.expectError(error.UnsupportedVersion, other.read(testing.allocator, "{ \"fluxion_input_map\": 7 }", null));
}
