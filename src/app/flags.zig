// SPDX-License-Identifier: BSD-3-Clause

//! The command line: `--name value` flags read into a struct of optional
//! fields, and the engine's own laid over a game's `Options`.

const std = @import("std");

const Options = @import("options.zig").Options;
const Backend = @import("options.zig").Backend;
const WindowMode = @import("../platform/window.zig").Mode;
const VsyncMode = @import("../platform/window.zig").VsyncMode;

/// The command-line flags the engine understands, read with `parseFlags` and
/// laid over a game's `Options` with `apply`. A flag that was not given
/// leaves the game's choice alone.
///
/// ```bash
/// game --backend d3d11 --width 1280 --height 720
/// game --frames 300 --capture shot.png
/// game --stats vulkan.json --vsync disabled --frames 600
/// ```
pub const Flags = struct {
    /// `--backend gl` or `--backend d3d11`.
    backend: ?Backend = null,
    /// `--width 1280`, `--height 720`: the window's size.
    width: ?u32 = null,
    height: ?u32 = null,
    /// `--window-mode maximized`: how it opens. See `WindowMode`.
    window_mode: ?WindowMode = null,
    /// `--screen 1`: in the middle of that screen, counting from nought.
    screen: ?u16 = null,
    /// `--position-x 100 --position-y 80`: there, its content's top left
    /// on the desktop. One of the two alone is nought for the other.
    position_x: ?i32 = null,
    position_y: ?i32 = null,
    /// `--frames 300`: stop after this many.
    frames: ?u32 = null,
    /// `--capture shot.png`: where `saveCapture` puts the last frame. See
    /// `apply`.
    capture: ?[]const u8 = null,
    /// `--stats report.json`: what each frame cost, written there at the
    /// end. See `app/frame_stats.zig`.
    stats: ?[]const u8 = null,
    /// `--vsync disabled`: whether frames wait for the refresh - the
    /// project's choice overruled, to measure a frame's work.
    vsync: ?VsyncMode = null,
    /// `--root ../my-game`: the project's root, which `res://` paths are
    /// from.
    root: ?[]const u8 = null,

    /// How long a capture runs when `--frames` does not say: two seconds.
    pub const capture_frames = 120;

    /// These flags over `options`. A capture also stops after `--frames` -
    /// or `capture_frames` - and counts every frame as one fixed step, so the
    /// same flags draw the same picture on every machine.
    pub fn apply(self: Flags, options: Options) Options {
        var out = options;
        if (self.backend) |backend| out.backend = backend;
        if (self.width) |width| out.width = width;
        if (self.height) |height| out.height = height;
        if (self.window_mode) |mode| out.window_mode = mode;
        if (self.screen) |screen| {
            out.initial_position = .center_of_screen;
            out.screen = screen;
        }
        if (self.position_x != null or self.position_y != null) {
            out.initial_position = .absolute;
            out.position = .init(self.position_x orelse 0, self.position_y orelse 0);
        }
        if (self.frames) |frames| out.frames = frames;
        if (self.root) |root| out.root = root;
        if (self.stats) |path| out.stats = path;
        if (self.vsync) |mode| out.vsync_mode = mode;
        if (self.capture != null) {
            out.frames = out.frames orelse capture_frames;
            out.fixed_frame_time = true;
        }
        return out;
    }
};

pub const FlagError = error{
    /// A flag no field answers to - usually a typo, so it stops the program.
    UnknownFlag,
    /// A flag at the end of the line with nothing after it.
    MissingValue,
    /// A value its field cannot hold: letters for a number, or a name the
    /// enum does not have.
    InvalidValue,
};

/// Read `--name value` flags into a struct of optional fields: a field
/// `write_atlas` is the flag `--write-atlas`.
///
/// ```zig
/// const flags = try App.parseFlags(App.Flags, arguments);
///
/// // A game with flags of its own puts the engine's beside them:
/// const Mine = struct { app: App.Flags = .{}, write_atlas: ?[]const u8 = null };
/// const mine = try App.parseFlags(Mine, arguments);
/// ```
///
/// The struct is read at compile time with `@typeInfo`: its field names are
/// the flags, its field types say how to read the values - text, a whole
/// number, an enum - and a field that is a struct has its fields read as
/// flags too. The first argument is the program's own name and is skipped.
pub fn parse(comptime T: type, arguments: []const []const u8) FlagError!T {
    var flags: T = .{};
    var at: usize = 1;
    while (at < arguments.len) : (at += 2) {
        if (at + 1 == arguments.len) return error.MissingValue;
        if (!try setFlag(T, &flags, arguments[at], arguments[at + 1])) return error.UnknownFlag;
    }
    return flags;
}

/// `parse`, passing over what `T` has no field for: a launcher's own flags,
/// and the game's, which it reads with `App.commandArgument`. A flag of
/// `T`'s with a wrong value still fails. `--name=value` is read as well as
/// `--name value`.
pub fn parseKnown(comptime T: type, arguments: []const []const u8) FlagError!T {
    var flags: T = .{};
    var at: usize = 1;
    while (at < arguments.len) {
        const argument = arguments[at];
        if (!std.mem.startsWith(u8, argument, "--")) {
            at += 1;
            continue;
        }
        if (std.mem.indexOfScalar(u8, argument, '=')) |cut| {
            _ = try setFlag(T, &flags, argument[0..cut], argument[cut + 1 ..]);
            at += 1;
            continue;
        }
        const has_value = at + 1 < arguments.len and !std.mem.startsWith(u8, arguments[at + 1], "--");
        if (!has_value) {
            at += 1;
            continue;
        }
        _ = try setFlag(T, &flags, argument, arguments[at + 1]);
        at += 2;
    }
    return flags;
}

/// Set the field of `T` - or of a struct inside it - that `name` names.
/// False when no field answers to it.
fn setFlag(comptime T: type, into: *T, name: []const u8, value: []const u8) FlagError!bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        switch (@typeInfo(field.type)) {
            .@"struct" => if (try setFlag(field.type, &@field(into, field.name), name, value)) return true,
            .optional => |optional| if (std.mem.eql(u8, name, comptime flagName(field.name))) {
                @field(into, field.name) = try flagValue(optional.child, value);
                return true;
            },
            else => @compileError("fluxion-engine: the flag field '" ++ field.name ++
                "' has to be optional - a flag that was not given is null - or a struct of flags"),
        }
    }
    return false;
}

/// `write_atlas` as `--write-atlas`, worked out once, at compile time.
fn flagName(comptime field: []const u8) []const u8 {
    comptime {
        var name: [field.len + 2]u8 = undefined;
        name[0] = '-';
        name[1] = '-';
        for (field, 0..) |c, i| name[i + 2] = if (c == '_') '-' else c;
        const done = name;
        return &done;
    }
}

/// One flag's value, read as whatever its field holds.
fn flagValue(comptime V: type, text: []const u8) FlagError!V {
    if (V == []const u8) return text;
    return switch (@typeInfo(V)) {
        .int => std.fmt.parseInt(V, text, 10) catch error.InvalidValue,
        .@"enum" => std.meta.stringToEnum(V, text) orelse error.InvalidValue,
        else => @compileError("fluxion-engine: a flag holds text, a whole number or an enum, not " ++ @typeName(V)),
    };
}
