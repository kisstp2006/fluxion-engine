// SPDX-License-Identifier: BSD-3-Clause

//! `project.fluxion`: how a project is called, opened, drawn and moved, at
//! the root of its folder, as Godot keeps its `project.godot`.
//!
//! ```json
//! {
//!   "fluxion_project": 2,
//!   "application": { "name": "Meadow", "icon": "res://icon.png", "main_scene": "res://levels/meadow.json", "tags": ["2d"] },
//!   "display": { "width": 1600, "height": 900, "mode": "maximized" },
//!   "physics_2d": { "default_gravity": 420 },
//!   "layer_names": { "physics_2d": ["world", "player"] },
//!   "gui": { "theme": "res://ui/game.theme" }
//! }
//! ```
//!
//! **Settings are data.** Each section is a struct below, each setting a
//! field of it with its default and its description; `settings_file.zig`
//! reads and writes any such struct, and an editor draws its Project
//! Settings from the same fields. A file says only what differs from the
//! defaults, and keeps the keys this build has no section for.
//!
//! **A game and an editor read the same file.** A project manager lists its
//! projects by reading theirs, with no `App` and no GPU - `Project.readSettings`
//! - and a game finds its own as it starts: `App.create` reads the one at its
//! root, and what it says of the window, the clear colour and the fixed step
//! is what the game opens with, unless the game's own `App.Options` say
//! otherwise. A folder with no project file is still somewhere to read files
//! from.
//!
//! **What is wrong is said, not guessed round.** A version other than this
//! one, a renderer with no name here, a path that is not the project's, a
//! project with no name: each is an error with where it is.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const json = @import("fluxion_json");
const math = @import("fluxion_math");

const App = @import("../App.zig");
const attr = @import("../attr.zig");
const Color = @import("../color.zig").Color;
const settings_file = @import("../settings_file.zig");

/// What the file is called, at the root of a project's folder.
pub const file_name = "project.fluxion";

/// The version this writes, and the only one it reads.
pub const version = 2;

/// The top of the file: `"fluxion_project": 2`.
pub const header: settings_file.Header = .{ .header = "fluxion_project", .version = version, .what = "project file" };

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

/// What the project is and what it opens: Godot's `application/config` and
/// `application/run`.
pub const Application = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    icon: []const u8 = "",
    main_scene: []const u8 = "",
    tags: []const []const u8 = &.{},

    pub const reflect_fields = .{
        .name = .{ attr.Required{}, attr.Doc{ .text = "What the project is called: the game window's title, and what the project list shows." } },
        .description = .{ attr.Multiline{}, attr.Doc{ .text = "A line or two about the project, for the project list." } },
        .icon = .{ attr.ProjectFile{ .kind = .texture }, attr.Doc{ .text = "The project's picture: the game window's icon, and the project list's." } },
        .main_scene = .{ attr.ProjectFile{ .kind = .scene }, attr.Doc{ .text = "The scene the game opens with, and what Play runs." } },
        .tags = .{attr.Doc{ .text = "Words to find the project by in the project list." }},
    };
};

/// The game's window: Godot's `display/window`. A game's own `App.Options`
/// say otherwise when they say anything.
pub const Display = struct {
    width: u32 = 1280,
    height: u32 = 720,
    resizable: bool = true,
    mode: Mode = .windowed,
    vsync: bool = true,

    pub const Mode = enum {
        /// A window of `width` by `height`.
        windowed,
        /// The window, as large as the screen lets it be.
        maximized,
        /// The whole monitor, at the resolution it already has.
        fullscreen,
    };

    pub const reflect_fields = .{
        .width = .{ attr.Range{ .min = 1, .max = 16384, .step = 1 }, attr.Unit{ .text = "px" }, attr.Restart{}, attr.Doc{ .text = "How wide the game's window opens." } },
        .height = .{ attr.Range{ .min = 1, .max = 16384, .step = 1 }, attr.Unit{ .text = "px" }, attr.Restart{}, attr.Doc{ .text = "How tall the game's window opens." } },
        .resizable = .{ attr.Restart{}, attr.Doc{ .text = "Whether the player may drag the window's edges." } },
        .mode = .{ attr.Restart{}, attr.Doc{ .text = "Whether the game opens in a window, maximised, or filling the screen." } },
        .vsync = .{ attr.Restart{}, attr.Doc{ .text = "Wait for the screen between frames, so a frame is never shown half drawn." } },
    };
};

/// How the project is drawn: Godot's `rendering`.
pub const Rendering = struct {
    renderer: Renderer = .compatibility,
    clear_color: Color = default_clear_color,

    pub const default_clear_color: Color = .hex(0x0E1013);

    pub const reflect_fields = .{
        .renderer = .{ attr.Restart{}, attr.Doc{ .text = "The family of graphics APIs the game is drawn with." } },
        .clear_color = .{ attr.Advanced{}, attr.Restart{}, attr.Doc{ .text = "What every frame is cleared to, under the world." } },
    };
};

/// How a 2D world moves when nothing else says so: Godot 3's `physics/2d`
/// settings and their names, and `physics/common`'s ticks. A game with no
/// project file takes `App.Options.physics_2d`.
pub const Physics2D = struct {
    default_gravity: f32 = 98,
    default_gravity_vector: math.Vec2 = .init(0, 1),
    default_linear_damp: f32 = 0.1,
    default_angular_damp: f32 = 1,
    ticks_per_second: u16 = 60,

    pub const reflect_fields = .{
        .default_gravity = .{ attr.Range{ .min = 0, .max = 10000 }, attr.Unit{ .text = "px/s²" }, attr.Doc{ .text = "How hard everything falls. 98 is Godot 3's, where a unit is a pixel; a world of a hundred units to the metre that wants Earth's says 981." } },
        .default_gravity_vector = .{attr.Doc{ .text = "Which way things fall: down the screen." }},
        .default_linear_damp = .{ attr.Range{ .min = 0, .max = 100 }, attr.Doc{ .text = "How much of its speed a body loses a second, when its own linear damp is minus one." } },
        .default_angular_damp = .{ attr.Range{ .min = 0, .max = 100 }, attr.Doc{ .text = "How much of its spin a body loses a second, when its own angular damp is minus one." } },
        .ticks_per_second = .{ attr.Range{ .min = 1, .max = 1000, .step = 1 }, attr.Advanced{}, attr.Restart{}, attr.Doc{ .text = "How many fixed steps a second the physics and the fixed systems take." } },
    };

    /// The gravity as the physics takes it: the vector, scaled.
    pub fn gravity(self: Physics2D) math.Vec2 {
        return self.default_gravity_vector.scale(self.default_gravity);
    }
};

/// What the project calls its layers: Godot's `layer_names`.
pub const LayerNames = struct {
    /// The 2D physics layers, first to last, `""` for one with no name - at
    /// most 32: what an editor shows beside a layer's toggle.
    physics_2d: []const []const u8 = &.{},

    pub const max = 32;

    pub const reflect_fields = .{
        .physics_2d = .{ attr.Label{ .text = "2D Physics" }, attr.Doc{ .text = "A name for each 2D physics layer, shown beside its toggle." } },
    };

    /// The name of the 2D physics layer numbered from 0, or `""`.
    pub fn physics2d(self: LayerNames, layer: usize) []const u8 {
        return if (layer < self.physics_2d.len) self.physics_2d[layer] else "";
    }
};

/// How the project's interface looks when nothing nearer says: Godot's
/// `gui/theme`.
pub const Gui = struct {
    theme: []const u8 = "",

    pub const reflect_fields = .{
        .theme = .{ attr.ProjectFile{ .kind = .theme }, attr.Doc{ .text = "The .theme every control is drawn with, under the one it names itself." } },
    };
};

/// What a project file says: a section a field.
pub const Settings = struct {
    application: Application = .{},
    display: Display = .{},
    rendering: Rendering = .{},
    physics_2d: Physics2D = .{},
    layer_names: LayerNames = .{},
    gui: Gui = .{},
    /// The memory the text above is kept in, and the file's keys this build
    /// has no section for.
    kept: settings_file.Kept = .{},

    pub const json_ignore = .{.kept};

    /// Give back what reading them took. Nothing, for settings written in
    /// code.
    pub fn deinit(self: *Settings) void {
        self.kept.deinit();
        self.* = undefined;
    }

    /// A section the game keeps in the project file itself, read into `S`:
    /// `"my_game": { ... }` beside the engine's. Null when there is none.
    pub fn section(self: *const Settings, comptime S: type, name: []const u8, into: Allocator) json.Error!?S {
        return settings_file.readSection(S, &self.kept, name, into);
    }
};

pub const ReadError = settings_file.ReadError || std.Io.Dir.ReadFileAllocError;

pub const WriteError = settings_file.WriteError || Allocator.Error;

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
pub fn parse(gpa: Allocator, bytes: []const u8, name: []const u8, diagnostics: ?*json.Diagnostics) settings_file.ReadError!Settings {
    // Reading starts the diagnostics afresh; which file it is, is said again.
    var file_buffer: [240]u8 = undefined;
    const file: []const u8 = if (diagnostics) |d| blk: {
        const len = @min(d.file().len, file_buffer.len);
        @memcpy(file_buffer[0..len], d.file()[0..len]);
        break :blk file_buffer[0..len];
    } else "";
    var settings = settings_file.parse(Settings, header, gpa, bytes, name, diagnostics) catch |err| {
        if (diagnostics) |d| d.setFile(file);
        return err;
    };
    errdefer settings.deinit();
    if (diagnostics) |d| d.setFile(file);
    if (settings.layer_names.physics_2d.len > LayerNames.max) {
        if (diagnostics) |d| d.setMessage("there are 32 physics layers, and \"layer_names.physics_2d\" names more", .{});
        return error.WrongType;
    }
    return settings;
}

// -------------------------------------------------------------------------
// Writing
// -------------------------------------------------------------------------

/// Write `settings` as the project file in the folder `dir`, in place of the
/// one there: written beside it and then moved over it, so a crash halfway
/// leaves the old file whole. Folders on the way are made. Only what differs
/// from the defaults is written.
pub fn write(gpa: Allocator, io: std.Io, dir: []const u8, settings: Settings) WriteError!void {
    const path = try std.fs.path.join(gpa, &.{ dir, file_name });
    defer gpa.free(path);
    try settings_file.save(Settings, header, io, path, &settings);
}

/// The project file's text, as `write` writes it.
pub fn text(gpa: Allocator, settings: *const Settings) WriteError![]u8 {
    return settings_file.stringify(Settings, header, gpa, settings);
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

    fn put(self: *Folder, content: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = file_name, .data = content });
    }
};

test "a project file is written and read back as it was, saying only what differs" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    const tags = [_][]const u8{ "2d", "jam" };
    const layers = [_][]const u8{ "world", "", "", "wolves" };
    try write(testing.allocator, testing.io, try folder.at(""), .{
        .application = .{
            .name = "Meadow",
            .description = "Sheep, and a wolf",
            .icon = "res://icon.png",
            .main_scene = "res://levels/meadow.json",
            .tags = &tags,
        },
        .display = .{ .width = 1600, .mode = .maximized },
        .physics_2d = .{
            .default_gravity = 981,
            .default_gravity_vector = .init(0.6, 0.8),
            .default_linear_damp = 0,
            .default_angular_damp = 0.5,
        },
        .layer_names = .{ .physics_2d = &layers },
        .gui = .{ .theme = "res://ui/game.theme" },
    });

    var settings = try read(testing.allocator, testing.io, try folder.at(""), null);
    defer settings.deinit();
    const application = settings.application;
    try testing.expectEqualStrings("Meadow", application.name);
    try testing.expectEqualStrings("Sheep, and a wolf", application.description);
    try testing.expectEqualStrings("res://icon.png", application.icon);
    try testing.expectEqualStrings("res://levels/meadow.json", application.main_scene);
    try testing.expectEqual(@as(usize, 2), application.tags.len);
    try testing.expectEqualStrings("jam", application.tags[1]);
    try testing.expectEqual(@as(u32, 1600), settings.display.width);
    try testing.expectEqual(@as(u32, 720), settings.display.height);
    try testing.expectEqual(Display.Mode.maximized, settings.display.mode);
    try testing.expectEqual(Renderer.compatibility, settings.rendering.renderer);
    const physics = settings.physics_2d;
    try testing.expectEqual(@as(f32, 981), physics.default_gravity);
    try testing.expectEqual(@as(f32, 0.8), physics.default_gravity_vector.y);
    try testing.expectEqual(@as(f32, 0), physics.default_linear_damp);
    try testing.expectEqual(@as(f32, 0.5), physics.default_angular_damp);
    try testing.expectApproxEqAbs(@as(f32, 784.8), physics.gravity().y, 0.01);
    try testing.expectEqualStrings("wolves", settings.layer_names.physics2d(3));
    try testing.expectEqualStrings("", settings.layer_names.physics2d(2));
    try testing.expectEqualStrings("", settings.layer_names.physics2d(31));
    try testing.expectEqualStrings("res://ui/game.theme", settings.gui.theme);

    // What was left at its default is not written: no height, no renderer.
    var kept: [2048]u8 = undefined;
    const written = try folder.tmp.dir.readFile(testing.io, file_name, &kept);
    try testing.expect(std.mem.startsWith(u8, written, "{\n  \"fluxion_project\": 2,\n  \"application\": {"));
    try testing.expect(std.mem.indexOf(u8, written, "\"height\"") == null);
    try testing.expect(std.mem.indexOf(u8, written, "\"rendering\"") == null);

    // A theme that is not the project's is not written.
    try testing.expectError(error.WrongType, write(testing.allocator, testing.io, try folder.at(""), .{ .application = .{ .name = "Out" }, .gui = .{ .theme = "C:/elsewhere.theme" } }));
}

test "what a project file leaves out takes its default, and a key it does not know is kept" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    try folder.put(
        \\// Written by hand.
        \\{ "fluxion_project": 2, "application": { "name": "Bare", "colour": "green" }, "my_game": { "lives": 3 } }
    );
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    var settings = try read(testing.allocator, testing.io, try folder.at(""), null);
    defer settings.deinit();
    try testing.expectEqualStrings("Bare", settings.application.name);
    try testing.expectEqualStrings("", settings.application.icon);
    try testing.expectEqual(Renderer.compatibility, settings.rendering.renderer);
    try testing.expectEqual(@as(usize, 0), settings.application.tags.len);
    // Godot 3's physics, which a new Godot project has.
    try testing.expectEqual(@as(f32, 98), settings.physics_2d.default_gravity);
    try testing.expectEqual(@as(f32, 1), settings.physics_2d.default_gravity_vector.y);
    try testing.expectEqual(@as(u16, 60), settings.physics_2d.ticks_per_second);

    // The game's own section, read by the game; and written back.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Game = struct { lives: u8 = 1 };
    try testing.expectEqual(@as(u8, 3), (try settings.section(Game, "my_game", arena.allocator())).?.lives);
    try write(testing.allocator, testing.io, try folder.at(""), settings);
    var kept: [1024]u8 = undefined;
    const written = try folder.tmp.dir.readFile(testing.io, file_name, &kept);
    try testing.expect(std.mem.indexOf(u8, written, "\"my_game\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"colour\"") == null);
}

test "a project file that is wrong says what and where, and one that is not there says so" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    var diagnostics: json.Diagnostics = .{};

    try testing.expectError(error.FileNotFound, read(testing.allocator, testing.io, try folder.at(""), &diagnostics));

    const cases = [_]struct { text: []const u8, err: ReadError, message: []const u8 }{
        .{
            .text = "{ \"fluxion_project\": 1, \"name\": \"Old\" }",
            .err = error.UnsupportedVersion,
            .message = "this project file is version 1, written for an older Fluxion; this one reads version 2",
        },
        .{
            .text = "{ \"fluxion_project\": 2, \"application\": { \"name\": \"Lost\", \"icon\": \"C:/art/icon.png\" } }",
            .err = error.WrongType,
            .message = "\"application.icon\" is a res:// or uid:// path, or empty, and this is \"C:/art/icon.png\"",
        },
        .{
            .text = "{ \"fluxion_project\": 2, \"rendering\": { \"renderer\": \"modern\" } }",
            .err = error.MissingField,
            .message = "\"application.name\" has to say something, and says nothing",
        },
        .{
            .text = "{ \"application\": { \"name\": \"Meadow\" } }",
            .err = error.NotSettings,
            .message = "this is not a project file: it has no \"fluxion_project\" version",
        },
        .{
            .text = "{ \"fluxion_project\": 2, \"application\": { \"name\": \"Many\" }, \"layer_names\": { \"physics_2d\": [" ++
                ("\"\", " ** 32) ++ "\"thirty-third\"] } }",
            .err = error.WrongType,
            .message = "there are 32 physics layers, and \"layer_names.physics_2d\" names more",
        },
    };
    for (cases) |case| {
        try folder.put(case.text);
        try testing.expectError(case.err, read(testing.allocator, testing.io, try folder.at(""), &diagnostics));
        try testing.expectEqualStrings(case.message, diagnostics.message());
        try testing.expect(std.mem.endsWith(u8, diagnostics.file(), file_name));
    }

    // The line of what is wrong.
    try folder.put("{\n  \"fluxion_project\": 2,\n  \"application\": { \"name\": \"Shiny\" },\n  \"rendering\": { \"renderer\": \"raytraced\" }\n}");
    try testing.expectError(error.UnknownTag, read(testing.allocator, testing.io, try folder.at(""), &diagnostics));
    try testing.expectEqual(@as(u32, 4), diagnostics.line);
}

test "a project is made in a folder that was not there, and not over one that is" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    const dir = try folder.at("/games/meadow");
    try create(testing.allocator, testing.io, dir, .{ .application = .{ .name = "Meadow" }, .rendering = .{ .renderer = .modern } });

    var settings = try read(testing.allocator, testing.io, dir, null);
    defer settings.deinit();
    try testing.expectEqual(Renderer.modern, settings.rendering.renderer);

    try testing.expectError(error.ProjectExists, create(testing.allocator, testing.io, dir, .{ .application = .{ .name = "Other" } }));
    var again = try read(testing.allocator, testing.io, dir, null);
    defer again.deinit();
    try testing.expectEqualStrings("Meadow", again.application.name);

    try testing.expectError(error.WrongType, write(testing.allocator, testing.io, dir, .{ .application = .{ .name = "Lost", .icon = "icon.png" } }));
}

test "a renderer's backends, best first, on each system" {
    try testing.expectEqualSlices(App.Backend, &.{ .d3d11, .gl }, Renderer.compatibility.backends(.windows));
    try testing.expectEqualSlices(App.Backend, &.{.gl}, Renderer.compatibility.backends(.linux));
    try testing.expectEqualSlices(App.Backend, &.{.gl}, Renderer.compatibility.backends(.macos));
    try testing.expectEqualSlices(App.Backend, &.{.webgl}, Renderer.compatibility.backends(.emscripten));
    try testing.expectEqual(@as(usize, 0), Renderer.modern.backends(.windows).len);
}
