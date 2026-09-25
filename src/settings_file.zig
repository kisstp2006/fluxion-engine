// SPDX-License-Identifier: BSD-3-Clause

//! A file of settings in sections - `project.fluxion`, and an editor's own -
//! read and written from the struct that describes it:
//!
//! ```zig
//! const Settings = struct {
//!     window: Window = .{},
//!     audio: Audio = .{},
//!     kept: settings_file.Kept = .{},
//!     pub const json_ignore = .{.kept};
//! };
//! var settings = try settings_file.parse(Settings, .{ .header = "my_settings", .version = 1 }, gpa, text, "settings.json", &diagnostics);
//! ```
//!
//! **Every field of the struct but `kept` is a section**, itself a struct
//! whose fields are the settings: what the file calls it, and what an editor
//! lists it as. A new setting is a new field, with its default and its
//! `fluxion_reflect` attributes - `attr.Doc`, `attr.Range`, and the four for
//! settings: `attr.ProjectFile`, `attr.Required`, `attr.Advanced`,
//! `attr.Restart` - and nothing else: no reader, no writer, no panel.
//!
//! **A file says only what differs.** A setting left at its default is not
//! written, and a section all of whose settings are is not either, so a file
//! is a short list of what was changed, and a default
//! changed in a later build reaches every project that did not say otherwise.
//!
//! **What this build does not know is kept.** A key of the file that names
//! no section - a newer build's, a game's own - is written back as it was
//! read; a game reads its own with `section`. A key inside a section this
//! build has no setting for is passed over with a warning.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const json = @import("fluxion_json");

const attr = @import("attr.zig");
const Project = @import("Project.zig");

const log = std.log.scoped(.fluxion_engine);

/// What a file of settings keeps besides its sections: the memory its text
/// lives in, and the keys no section of this build read, to be written back
/// as they were. Not a section: a struct names it `kept` and leaves it out
/// of its JSON with `json_ignore`.
pub const Kept = struct {
    /// Owns the text of the sections, for settings read from a file; null
    /// for ones written in code, whose text is the caller's.
    arena: ?*std.heap.ArenaAllocator = null,
    /// An object of the file's other keys, or null when it had none.
    rest: ?json.Document = null,

    pub fn deinit(self: *Kept) void {
        if (self.rest) |doc| doc.deinit();
        if (self.arena) |arena| {
            const gpa = arena.child_allocator;
            arena.deinit();
            gpa.destroy(arena);
        }
        self.* = .{};
    }

    /// Memory for text given to a setting, living as long as the settings:
    /// what an editor types a new value into. Made on first use.
    pub fn allocator(self: *Kept, gpa: Allocator) Allocator.Error!Allocator {
        if (self.arena == null) {
            const arena = try gpa.create(std.heap.ArenaAllocator);
            arena.* = .init(gpa);
            self.arena = arena;
        }
        return self.arena.?.allocator();
    }
};

/// What a kind of settings file is called at its top, and which version of
/// it this build reads and writes: `"fluxion_project": 2`.
pub const Header = struct {
    /// The key whose number is the version.
    header: []const u8,
    version: u32,
    /// What a message calls the file: "project file".
    what: []const u8 = "settings file",
};

pub const ReadError = error{
    /// Not this kind of file: not an object, or no version under its header.
    NotSettings,
    /// A version other than the one this build reads.
    UnsupportedVersion,
    /// A setting that has to say something, and says nothing.
    MissingField,
} || json.Error;

pub const WriteError = error{
    /// A setting that is a project's file names one that is not the
    /// project's, which the file could not be read back with.
    WrongType,
    /// A setting that has to say something, and says nothing.
    MissingField,
} || json.SaveError;

/// Whether `name`, a field of a settings struct, is one of its sections.
pub fn isSection(comptime name: []const u8) bool {
    return !std.mem.eql(u8, name, "kept");
}

/// The sections of `T`, in the order its fields are declared: what a file
/// is written in and an editor lists.
pub fn sections(comptime T: type) []const std.builtin.Type.StructField {
    comptime {
        var out: []const std.builtin.Type.StructField = &.{};
        for (@typeInfo(T).@"struct".fields) |f| {
            if (isSection(f.name)) out = out ++ .{f};
        }
        return out;
    }
}

/// An attribute of type `A` on the field `name` of `Section`, from its
/// `reflect_fields`, or null.
pub fn attribute(comptime Section: type, comptime name: []const u8, comptime A: type) ?A {
    comptime {
        if (!@hasDecl(Section, "reflect_fields")) return null;
        const table = Section.reflect_fields;
        if (!@hasField(@TypeOf(table), name)) return null;
        for (@field(table, name)) |each| {
            if (@TypeOf(each) == A) return each;
        }
        return null;
    }
}

// -------------------------------------------------------------------------
// Reading
// -------------------------------------------------------------------------

/// Settings from a file's text. What is wrong, and where, goes into
/// `diagnostics`; `file` is what a warning calls the file. JSON5, so a file
/// edited by hand may say why in a comment.
pub fn parse(comptime T: type, comptime kind: Header, gpa: Allocator, text: []const u8, file: []const u8, diagnostics: ?*json.Diagnostics) ReadError!T {
    // The whole text as a tree first: its version, the keys inside a
    // section that no setting reads, and the keys that name no section.
    var doc = try json.parse(gpa, text, .{ .syntax = .json5, .diagnostics = diagnostics });
    var keep_doc = false;
    defer if (!keep_doc) doc.deinit();
    const root = doc.root.asObject() orelse return fail(diagnostics, error.NotSettings, "this is not a " ++ kind.what ++ ": it is not an object", .{});
    const said = root.get(kind.header);
    if (said == .null) return fail(diagnostics, error.NotSettings, "this is not a " ++ kind.what ++ ": it has no \"" ++ kind.header ++ "\" version", .{});
    const number = said.asInt(u32) orelse return fail(diagnostics, error.NotSettings, "\"" ++ kind.header ++ "\" is the version of the " ++ kind.what ++ ", and this is {f}", .{said});
    if (number != kind.version) {
        return fail(diagnostics, error.UnsupportedVersion, "this " ++ kind.what ++ " is version {d}, written for {s} Fluxion; this one reads version {d}", .{
            number,
            if (number < kind.version) "an older" else "a newer",
            kind.version,
        });
    }

    // The sections, read into their types: a value of the wrong kind is an
    // error with its line and column.
    const parsed = try json.parseAs(T, gpa, text, .{ .syntax = .json5, .unknown_fields = .ignore, .diagnostics = diagnostics });
    var out = parsed.value;
    out.kept = .{ .arena = parsed.arena };
    errdefer out.kept.deinit();

    inline for (comptime sections(T)) |f| {
        if (root.get(f.name).asObject()) |object| {
            for (object.keys()) |key| {
                if (!hasField(f.type, key)) log.warn("{s}: \"{s}.{s}\" is no setting this build knows, and is passed over", .{ file, f.name, key });
            }
        }
    }
    try check(T, &out, diagnostics);

    // What names no section is kept, to be written back.
    _ = root.remove(kind.header);
    inline for (comptime sections(T)) |f| _ = root.remove(f.name);
    if (root.len() > 0) {
        out.kept.rest = doc;
        keep_doc = true;
    }
    return out;
}

fn hasField(comptime Section: type, name: []const u8) bool {
    inline for (@typeInfo(Section).@"struct".fields) |g| {
        if (std.mem.eql(u8, g.name, name)) return true;
    }
    return false;
}

/// Every setting that is a project's file names one of the project's, and
/// every one that has to say something does.
fn check(comptime T: type, settings: *const T, diagnostics: ?*json.Diagnostics) ReadError!void {
    inline for (comptime sections(T)) |f| {
        const section = @field(settings.*, f.name);
        inline for (@typeInfo(f.type).@"struct".fields) |g| {
            const value = @field(section, g.name);
            if (comptime attribute(f.type, g.name, attr.Required) != null) {
                if (isEmpty(value)) return fail(diagnostics, error.MissingField, "\"" ++ f.name ++ "." ++ g.name ++ "\" has to say something, and says nothing", .{});
            }
            if (comptime attribute(f.type, g.name, attr.ProjectFile) != null) {
                if (value.len > 0 and !Project.isValidProjectPath(value)) {
                    return fail(diagnostics, error.WrongType, "\"" ++ f.name ++ "." ++ g.name ++ "\" is a res:// or uid:// path, or empty, and this is \"{s}\"", .{value});
                }
            }
        }
    }
}

fn isEmpty(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .pointer => value.len == 0,
        else => false,
    };
}

fn fail(diagnostics: ?*json.Diagnostics, err: anytype, comptime fmt: []const u8, args: anytype) @TypeOf(err) {
    if (diagnostics) |d| d.setMessage(fmt, args);
    return err;
}

/// A section the game keeps in the file itself - one no struct of the
/// engine's names, as `"my_game": { ... }` - read into `S`. Null when the
/// file has none. Its text lives in `into`.
pub fn readSection(comptime S: type, kept: *const Kept, name: []const u8, into: Allocator) json.Error!?S {
    const doc = kept.rest orelse return null;
    const value = doc.root.get(name);
    if (value == .null) return null;
    const parsed = try value.parseAs(S, into, .{ .unknown_fields = .ignore });
    return parsed.value;
}

// -------------------------------------------------------------------------
// Writing
// -------------------------------------------------------------------------

/// Write `settings` to `path`, in place of the file there: written beside
/// it and moved over it, so a crash halfway leaves the old one whole.
/// Folders on the way are made.
pub fn save(comptime T: type, comptime kind: Header, io: std.Io, path: []const u8, settings: *const T) WriteError!void {
    try checkWrite(T, settings);
    try json.save(io, path, File(T, kind){ .settings = settings }, .{ .indent = 2, .skip_defaults = true });
}

/// The file as text: what `save` writes.
pub fn stringify(comptime T: type, comptime kind: Header, gpa: Allocator, settings: *const T) (WriteError || Allocator.Error)![]u8 {
    try checkWrite(T, settings);
    return json.stringify(gpa, File(T, kind){ .settings = settings }, .{ .indent = 2, .skip_defaults = true });
}

fn checkWrite(comptime T: type, settings: *const T) WriteError!void {
    check(T, settings, null) catch |err| return switch (err) {
        error.MissingField => error.MissingField,
        else => error.WrongType,
    };
}

fn File(comptime T: type, comptime kind: Header) type {
    return struct {
        settings: *const T,

        pub fn toJson(self: @This(), w: *json.Writer) json.Writer.Error!void {
            try w.beginObject();
            try w.field(kind.header, @as(u32, kind.version));
            inline for (comptime sections(T)) |f| {
                const value = @field(self.settings.*, f.name);
                if (!deepEql(value, f.defaultValue().?)) try w.field(f.name, value);
            }
            if (self.settings.kept.rest) |doc| {
                if (doc.root.asObject()) |object| {
                    for (object.keys(), object.values()) |key, value| try w.field(key, value);
                }
            }
            try w.endObject();
        }
    };
}

/// Whether two values say the same: text by its bytes, a slice by what it
/// holds.
pub fn deepEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.fields) |f| {
                if (!deepEql(@field(a, f.name), @field(b, f.name))) return false;
            }
            return true;
        },
        .array => {
            for (a, b) |x, y| if (!deepEql(x, y)) return false;
            return true;
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (a.len != b.len) return false;
                for (a, b) |x, y| if (!deepEql(x, y)) return false;
                return true;
            },
            else => return a == b,
        },
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return deepEql(a.?, b.?);
        },
        else => return std.meta.eql(a, b),
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const Sample = struct {
    window: Window = .{},
    words: Words = .{},
    kept: Kept = .{},

    pub const json_ignore = .{.kept};

    const Window = struct {
        width: u32 = 640,
        vsync: bool = true,
    };

    const Words = struct {
        name: []const u8 = "",
        scene: []const u8 = "",
        tags: []const []const u8 = &.{},

        pub const reflect_fields = .{
            .name = .{attr.Required{}},
            .scene = .{attr.ProjectFile{ .kind = .scene }},
        };
    };
};

const sample: Header = .{ .header = "sample", .version = 3 };

test "a settings file says only what differs from the defaults, and keeps what it does not know" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    var settings = try parse(Sample, sample, testing.allocator,
        \\// A hand wrote this.
        \\{ "sample": 3, "words": { "name": "Meadow", "colour": "red" }, "my_game": { "lives": 3 } }
    , "sample.json", null);
    defer settings.kept.deinit();
    try testing.expectEqualStrings("Meadow", settings.words.name);
    try testing.expectEqual(@as(u32, 640), settings.window.width);

    settings.window.vsync = false;
    const text = try stringify(Sample, sample, testing.allocator, &settings);
    defer testing.allocator.free(text);
    // The header first, then only what was changed, then the rest as it was.
    try testing.expect(std.mem.startsWith(u8, text, "{\n  \"sample\": 3,"));
    try testing.expect(std.mem.indexOf(u8, text, "\"width\"") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\"vsync\": false") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"my_game\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"colour\"") == null);

    // A game's own section, read into its own type.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Game = struct { lives: u8 = 1 };
    try testing.expectEqual(@as(u8, 3), (try readSection(Game, &settings.kept, "my_game", arena.allocator())).?.lives);
    try testing.expect(try readSection(Game, &settings.kept, "other", arena.allocator()) == null);
}

test "a settings file that is wrong says what, and where" {
    var diagnostics: json.Diagnostics = .{};
    const cases = [_]struct { text: []const u8, err: ReadError, message: []const u8 }{
        .{ .text = "[1]", .err = error.NotSettings, .message = "this is not a settings file: it is not an object" },
        .{ .text = "{ \"words\": { \"name\": \"A\" } }", .err = error.NotSettings, .message = "this is not a settings file: it has no \"sample\" version" },
        .{ .text = "{ \"sample\": 2, \"words\": { \"name\": \"A\" } }", .err = error.UnsupportedVersion, .message = "this settings file is version 2, written for an older Fluxion; this one reads version 3" },
        .{ .text = "{ \"sample\": 3 }", .err = error.MissingField, .message = "\"words.name\" has to say something, and says nothing" },
        .{ .text = "{ \"sample\": 3, \"words\": { \"name\": \"A\", \"scene\": \"C:/a.json\" } }", .err = error.WrongType, .message = "\"words.scene\" is a res:// or uid:// path, or empty, and this is \"C:/a.json\"" },
    };
    for (cases) |case| {
        try testing.expectError(case.err, parse(Sample, sample, testing.allocator, case.text, "sample.json", &diagnostics));
        try testing.expectEqualStrings(case.message, diagnostics.message());
    }
    // A value of the wrong kind, at its line and column.
    try testing.expectError(error.WrongType, parse(Sample, sample, testing.allocator, "{ \"sample\": 3,\n  \"window\": { \"width\": \"wide\" } }", "sample.json", &diagnostics));
    try testing.expectEqual(@as(u32, 2), diagnostics.line);
}

test "a setting that is a project's file, or has to say something, is not written wrong" {
    var settings: Sample = .{ .words = .{ .name = "A", .scene = "levels/one.json" } };
    try testing.expectError(error.WrongType, stringify(Sample, sample, testing.allocator, &settings));
    settings.words = .{};
    try testing.expectError(error.MissingField, stringify(Sample, sample, testing.allocator, &settings));
}
