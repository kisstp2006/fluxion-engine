// SPDX-License-Identifier: BSD-3-Clause

//! `project.fluxion`: what a project is called and how it is drawn, at the
//! root of its folder, as Godot keeps its `project.godot`.
//!
//! ```json
//! {
//!   "fluxion_project": 1,
//!   "name": "Meadow",
//!   "description": "",
//!   "icon": "res://icon.png",
//!   "renderer": "compatibility",
//!   "main_scene": "",
//!   "tags": ["2d"]
//! }
//! ```
//!
//! **A game and an editor read the same file.** A project manager lists its
//! projects by reading theirs, with no `App` and no GPU - `Project.readSettings`
//! - and a game finds its own as it starts: `App.create` reads the one at its
//! root, and the renderer it names chooses what `Backend.auto` opens. A folder
//! with no project file is still somewhere to read files from, and is drawn
//! with the compatibility renderer.
//!
//! **What is wrong is said, not guessed round.** A version other than this
//! one, a renderer with no name here, a path that is not the project's, is an
//! error with its line and column. A key this engine does not know is passed
//! over with a warning, so a file a hand or a newer build added to still opens.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const json = @import("fluxion_json");
const Uuid = @import("fluxion_id").Uuid;

const App = @import("../App.zig");
const Project = @import("../Project.zig");
const scene = @import("../scene.zig");

const log = std.log.scoped(.fluxion_engine);

/// What the file is called, at the root of a project's folder.
pub const file_name = "project.fluxion";

/// The version this writes, and the only one it reads.
pub const version = 1;

/// Which family of graphics APIs a project is drawn with.
pub const Renderer = enum {
    /// Direct3D 11 and OpenGL 3.3, and WebGL 2 in a browser: what there is.
    compatibility,
    /// Direct3D 12 and Vulkan. Not built yet: a project that asks for it
    /// opens no window, rather than being drawn with something else.
    modern,

    /// The graphics APIs it means, in words, for a person choosing one.
    pub fn apis(self: Renderer) []const u8 {
        return switch (self) {
            .compatibility => "Direct3D 11 and OpenGL",
            .modern => "Direct3D 12 and Vulkan",
        };
    }

    /// Its backends on an operating system, best first: the first is what
    /// `Backend.auto` opens, and the others are what the same game can be
    /// checked on. Nothing for a renderer that is not built.
    pub fn backends(self: Renderer, os: std.Target.Os.Tag) []const App.Backend {
        return switch (self) {
            .compatibility => switch (os) {
                .windows => &.{ .d3d11, .gl },
                .freestanding, .emscripten, .wasi => &.{.webgl},
                else => &.{.gl},
            },
            .modern => &.{},
        };
    }
};

/// What a project file says.
pub const Settings = struct {
    name: []const u8,
    description: []const u8 = "",
    /// `res://` or `uid://`, or empty.
    icon: []const u8 = "",
    renderer: Renderer = .compatibility,
    /// What a game opens first: `res://` or `uid://`, or empty. Kept for a
    /// project manager to show; nothing opens it by itself yet.
    main_scene: []const u8 = "",
    tags: []const []const u8 = &.{},
    /// What the text above is kept in, for settings read from a file; null
    /// for ones written in code, whose text is the caller's.
    arena: ?*std.heap.ArenaAllocator = null,

    /// Give back what reading them took. Nothing, for settings written in
    /// code.
    pub fn deinit(self: *Settings) void {
        if (self.arena) |arena| {
            const gpa = arena.child_allocator;
            arena.deinit();
            gpa.destroy(arena);
        }
        self.* = undefined;
    }
};

pub const ReadError = error{
    /// Not a project file: not an object, or no `fluxion_project` version.
    NotAProject,
    /// A version other than the one this engine reads.
    UnsupportedVersion,
    /// A value of the wrong kind: a renderer with no name here, a path that
    /// is not the project's, a number where text goes.
    WrongType,
    /// No `name`, which every project has.
    MissingField,
} || json.Reader.Error || std.Io.Dir.ReadFileAllocError;

pub const WriteError = error{
    /// An `icon` or a `main_scene` that is not the project's path, which
    /// the file could not be read back with.
    WrongType,
} || Allocator.Error || json.SaveError;

pub const CreateError = error{
    /// The folder has a project file already.
    ProjectExists,
} || WriteError || std.Io.Dir.AccessError;

// -------------------------------------------------------------------------
// Reading
// -------------------------------------------------------------------------

/// The project file in the folder `dir` - `error.FileNotFound` when it has
/// none. What went wrong, and where, goes into `diagnostics`, under the
/// file's path: `games/meadow/project.fluxion:3:14: ...`.
pub fn read(gpa: Allocator, io: std.Io, dir: []const u8, diagnostics: ?*json.Diagnostics) ReadError!Settings {
    const path = try std.fs.path.join(gpa, &.{ dir, file_name });
    defer gpa.free(path);
    if (diagnostics) |d| {
        d.* = .{};
        d.setFile(path);
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        if (diagnostics) |d| d.setMessage("cannot read the file: {t}", .{err});
        return err;
    };
    defer gpa.free(bytes);
    return parse(gpa, bytes, path, diagnostics);
}

/// Settings from a project file's text; `name` is what a warning calls the
/// file. JSON5, so a file edited by hand may say why in a comment.
pub fn parse(gpa: Allocator, bytes: []const u8, name: []const u8, diagnostics: ?*json.Diagnostics) ReadError!Settings {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    var reader: json.Reader = .init(gpa, bytes, .{ .syntax = .json5, .diagnostics = diagnostics });
    defer reader.deinit();
    var reading: Reading = .{ .reader = &reader, .arena = arena.allocator(), .file = name };
    var settings = try reading.settings();
    settings.arena = arena;
    return settings;
}

/// The names of the renderers, for a message: `compatibility and modern`.
const renderer_names = blk: {
    const names = std.meta.fieldNames(Renderer);
    var text: []const u8 = "";
    for (names, 0..) |each, i| {
        text = text ++ (if (i == 0) "" else if (i + 1 == names.len) " and " else ", ") ++ each;
    }
    break :blk text;
};

const Token = json.Reader.Token;

const Reading = struct {
    reader: *json.Reader,
    arena: Allocator,
    file: []const u8,

    fn settings(r: *Reading) ReadError!Settings {
        var out: Settings = .{ .name = "" };
        var versioned = false;
        var named = false;
        try r.open(.object_begin, "a project, which is an object");
        while (try r.key()) |name| {
            if (std.mem.eql(u8, name, "fluxion_project")) {
                const token = try r.next();
                const number = switch (token) {
                    .number => |n| n.asInt(u32),
                    else => null,
                } orelse return r.fail(error.NotAProject, "\"fluxion_project\" is the version of the project file, and this is {f}", .{scene.found(token)});
                if (number != version) return r.fail(error.UnsupportedVersion, "this project file is version {d}; this engine reads version {d}", .{ number, version });
                versioned = true;
            } else if (std.mem.eql(u8, name, "name")) {
                out.name = try r.text("the project's name");
                named = true;
            } else if (std.mem.eql(u8, name, "description")) {
                out.description = try r.text("a description");
            } else if (std.mem.eql(u8, name, "icon")) {
                out.icon = try r.path("icon");
            } else if (std.mem.eql(u8, name, "main_scene")) {
                out.main_scene = try r.path("main_scene");
            } else if (std.mem.eql(u8, name, "renderer")) {
                out.renderer = try r.renderer();
            } else if (std.mem.eql(u8, name, "tags")) {
                out.tags = try r.tags();
            } else {
                log.warn("{s}: \"{s}\" is no project setting this engine knows, and is passed over", .{ r.file, name });
                try r.reader.skipValue();
            }
        }
        if (!versioned) return r.fail(error.NotAProject, "this is not a project file: it has no \"fluxion_project\" version", .{});
        if (!named) return r.fail(error.MissingField, "a project has a \"name\", and this one has none", .{});
        return out;
    }

    fn text(r: *Reading, comptime what: []const u8) ReadError![]const u8 {
        const token = try r.next();
        return switch (token) {
            .string => |words| try r.arena.dupe(u8, words),
            else => r.wrong(what ++ ", which is text", token),
        };
    }

    fn path(r: *Reading, comptime field: []const u8) ReadError![]const u8 {
        const given = try r.text("\"" ++ field ++ "\", a path");
        if (given.len == 0 or Project.isValidProjectPath(given)) return given;
        return r.fail(error.WrongType, "\"" ++ field ++ "\" is a res:// or uid:// path, or empty, and this is \"{s}\"", .{given});
    }

    fn renderer(r: *Reading) ReadError!Renderer {
        const token = try r.next();
        const word = switch (token) {
            .string => |word| word,
            else => return r.wrong("a renderer, which is text", token),
        };
        return std.meta.stringToEnum(Renderer, word) orelse
            r.fail(error.WrongType, "\"{s}\" is not a renderer: the renderers are " ++ renderer_names, .{word});
    }

    fn tags(r: *Reading) ReadError![]const []const u8 {
        try r.open(.array_begin, "the tags, which are a list");
        var list: std.ArrayList([]const u8) = .empty;
        while (try r.reader.peek() != .array_end) try list.append(r.arena, try r.text("a tag"));
        _ = try r.next();
        return list.items;
    }

    fn next(r: *Reading) ReadError!Token {
        return (try r.reader.next()) orelse r.fail(error.SyntaxError, "the project file ends too soon", .{});
    }

    /// The next member's name, or null at the end of the object.
    fn key(r: *Reading) ReadError!?[]const u8 {
        return switch (try r.next()) {
            .key => |name| name,
            else => null,
        };
    }

    fn open(r: *Reading, comptime kind: std.meta.Tag(Token), comptime what: []const u8) ReadError!void {
        const token = try r.next();
        if (token != kind) return r.wrong(what, token);
    }

    fn wrong(r: *Reading, comptime expected: []const u8, token: Token) ReadError {
        return r.fail(error.WrongType, "expected " ++ expected ++ ", found {f}", .{scene.found(token)});
    }

    /// Say what is wrong with the last token, and where it is.
    fn fail(r: *Reading, err: ReadError, comptime fmt: []const u8, args: anytype) ReadError {
        r.reader.report(fmt, args);
        return err;
    }
};

// -------------------------------------------------------------------------
// Writing
// -------------------------------------------------------------------------

/// Write `settings` as the project file in the folder `dir`, in place of the
/// one there: written beside it and then moved over it, so a crash halfway
/// leaves the old file whole. Folders on the way are made.
pub fn write(gpa: Allocator, io: std.Io, dir: []const u8, settings: Settings) WriteError!void {
    for ([_][]const u8{ settings.icon, settings.main_scene }) |given| {
        if (given.len > 0 and !Project.isValidProjectPath(given)) return error.WrongType;
    }
    const path = try std.fs.path.join(gpa, &.{ dir, file_name });
    defer gpa.free(path);
    try json.save(io, path, File{ .settings = settings }, .{ .indent = 2 });
}

/// Make a new project: its folder, with every folder above it that is
/// missing, and its project file. `error.ProjectExists` when the folder has
/// one already, which is left as it was.
pub fn create(gpa: Allocator, io: std.Io, dir: []const u8, settings: Settings) CreateError!void {
    const path = try std.fs.path.join(gpa, &.{ dir, file_name });
    defer gpa.free(path);
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
        return error.ProjectExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    // `write` makes the folders on the way, as fluxion-json's `save` does.
    try write(gpa, io, dir, settings);
}

/// The file as fluxion-json writes it: every key, in the order a person
/// would read them.
const File = struct {
    settings: Settings,

    pub fn toJson(self: File, w: *json.Writer) json.Writer.Error!void {
        const s = self.settings;
        try w.beginObject();
        try w.field("fluxion_project", @as(u32, version));
        try w.field("name", s.name);
        try w.field("description", s.description);
        try w.field("icon", s.icon);
        try w.field("renderer", @as([]const u8, @tagName(s.renderer)));
        try w.field("main_scene", s.main_scene);
        try w.key("tags");
        try w.beginArray();
        for (s.tags) |tag| try w.writeString(tag);
        try w.endArray();
        try w.endObject();
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// A folder of a test's own, and its path from the working directory.
const Folder = struct {
    tmp: testing.TmpDir,
    buffer: [160]u8 = undefined,

    fn init() Folder {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn at(self: *Folder, inside: []const u8) ![]const u8 {
        return std.fmt.bufPrint(&self.buffer, ".zig-cache/tmp/{s}{s}", .{ self.tmp.sub_path, inside });
    }

    fn put(self: *Folder, text: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = file_name, .data = text });
    }
};

test "a project file is written and read back as it was" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    const tags = [_][]const u8{ "2d", "jam" };
    try write(testing.allocator, testing.io, try folder.at(""), .{
        .name = "Meadow",
        .description = "Sheep, and a wolf",
        .icon = "res://icon.png",
        .main_scene = "res://levels/meadow.json",
        .tags = &tags,
    });

    var settings = try read(testing.allocator, testing.io, try folder.at(""), null);
    defer settings.deinit();
    try testing.expectEqualStrings("Meadow", settings.name);
    try testing.expectEqualStrings("Sheep, and a wolf", settings.description);
    try testing.expectEqualStrings("res://icon.png", settings.icon);
    try testing.expectEqual(Renderer.compatibility, settings.renderer);
    try testing.expectEqualStrings("res://levels/meadow.json", settings.main_scene);
    try testing.expectEqual(@as(usize, 2), settings.tags.len);
    try testing.expectEqualStrings("jam", settings.tags[1]);

    var kept: [512]u8 = undefined;
    const text = try folder.tmp.dir.readFile(testing.io, file_name, &kept);
    try testing.expect(std.mem.startsWith(u8, text, "{\n  \"fluxion_project\": 1,\n  \"name\": \"Meadow\","));
}

test "what a project file leaves out takes its default, and a key it does not know is passed over" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    try folder.put(
        \\// Written by hand.
        \\{ "fluxion_project": 1, "window": { "vsync": false, "size": [640, 360] }, "name": "Bare" }
    );
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    var settings = try read(testing.allocator, testing.io, try folder.at(""), null);
    defer settings.deinit();
    try testing.expectEqualStrings("Bare", settings.name);
    try testing.expectEqualStrings("", settings.icon);
    try testing.expectEqual(Renderer.compatibility, settings.renderer);
    try testing.expectEqual(@as(usize, 0), settings.tags.len);
}

test "a project file that is wrong says what and where, and one that is not there says so" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    var diagnostics: json.Diagnostics = .{};

    try testing.expectError(error.FileNotFound, read(testing.allocator, testing.io, try folder.at(""), &diagnostics));

    const cases = [_]struct { text: []const u8, err: ReadError, message: []const u8 }{
        .{
            .text = "{ \"fluxion_project\": 2, \"name\": \"Later\" }",
            .err = error.UnsupportedVersion,
            .message = "this project file is version 2; this engine reads version 1",
        },
        .{
            .text = "{ \"fluxion_project\": 1, \"name\": \"Shiny\", \"renderer\": \"raytraced\" }",
            .err = error.WrongType,
            .message = "\"raytraced\" is not a renderer: the renderers are compatibility and modern",
        },
        .{
            .text = "{ \"fluxion_project\": 1, \"name\": \"Lost\", \"icon\": \"C:/art/icon.png\" }",
            .err = error.WrongType,
            .message = "\"icon\" is a res:// or uid:// path, or empty, and this is \"C:/art/icon.png\"",
        },
        .{
            .text = "{ \"fluxion_project\": 1, \"renderer\": \"modern\" }",
            .err = error.MissingField,
            .message = "a project has a \"name\", and this one has none",
        },
        .{
            .text = "{ \"name\": \"Meadow\" }",
            .err = error.NotAProject,
            .message = "this is not a project file: it has no \"fluxion_project\" version",
        },
        .{
            .text = "{ \"fluxion_project\": 1, \"name\": 7 }",
            .err = error.WrongType,
            .message = "expected the project's name, which is text, found the number 7",
        },
    };
    for (cases) |case| {
        try folder.put(case.text);
        try testing.expectError(case.err, read(testing.allocator, testing.io, try folder.at(""), &diagnostics));
        try testing.expectEqualStrings(case.message, diagnostics.message());
        try testing.expect(std.mem.endsWith(u8, diagnostics.file(), file_name));
    }

    // The line and column of what is wrong.
    try folder.put("{\n  \"fluxion_project\": 1,\n  \"name\": \"Shiny\",\n  \"renderer\": \"raytraced\"\n}");
    try testing.expectError(error.WrongType, read(testing.allocator, testing.io, try folder.at(""), &diagnostics));
    try testing.expectEqual(@as(u32, 4), diagnostics.line);
    try testing.expectEqual(@as(u32, 15), diagnostics.column);
}

test "a project is made in a folder that was not there, and not over one that is" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    const dir = try folder.at("/games/meadow");
    try create(testing.allocator, testing.io, dir, .{ .name = "Meadow", .renderer = .modern });

    var settings = try read(testing.allocator, testing.io, dir, null);
    defer settings.deinit();
    try testing.expectEqual(Renderer.modern, settings.renderer);

    try testing.expectError(error.ProjectExists, create(testing.allocator, testing.io, dir, .{ .name = "Other" }));
    var again = try read(testing.allocator, testing.io, dir, null);
    defer again.deinit();
    try testing.expectEqualStrings("Meadow", again.name);

    try testing.expectError(error.WrongType, write(testing.allocator, testing.io, dir, .{ .name = "Lost", .icon = "icon.png" }));
}

test "a renderer's backends, best first, on each system" {
    try testing.expectEqualSlices(App.Backend, &.{ .d3d11, .gl }, Renderer.compatibility.backends(.windows));
    try testing.expectEqualSlices(App.Backend, &.{.gl}, Renderer.compatibility.backends(.linux));
    try testing.expectEqualSlices(App.Backend, &.{.gl}, Renderer.compatibility.backends(.macos));
    try testing.expectEqualSlices(App.Backend, &.{.webgl}, Renderer.compatibility.backends(.emscripten));
    try testing.expectEqual(@as(usize, 0), Renderer.modern.backends(.windows).len);
}
