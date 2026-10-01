// SPDX-License-Identifier: BSD-3-Clause

//! What more than one test file uses: a key press as the platform sends it, a
//! component to count with, systems that count while paused, and a project of a
//! test's own.

const std = @import("std");
const testing = std.testing;

const App = @import("App.zig");
const image = @import("fluxion_image");
const platform = @import("fluxion_platform");

/// A key going down, as the platform would deliver it.
pub fn pressOf(key: platform.Key) platform.Event {
    return .{ .key = .{
        .window = .none,
        .key = key,
        .scancode = @enumFromInt(0),
        .action = .press,
        .mods = .{},
    } };
}

/// The physics of a world with the earth's pull and nothing to slow it: what
/// the body tests fall in.
pub const earth: @import("project/Project.zig").Physics2D = .{ .default_gravity = 981, .default_linear_damp = 0, .default_angular_damp = 0 };

/// An app whose every frame is a quarter of a second, headless: what the tests
/// of things that take time - timers, tweens, animations, sounds - step through.
pub fn quarterSecondApp() !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .fixed_delta = 0.25 });
    app.time.source = .{ .fixed = 0.25 };
    return app;
}

pub const Tally = extern struct { points: u32 = 0 };

pub const Paused = struct {
    pub var game: u32 = 0;
    pub var menu: u32 = 0;
    pub var key: u32 = 0;
    pub var pressed: u32 = 0;

    pub fn reset() void {
        game = 0;
        menu = 0;
        key = 0;
        pressed = 0;
    }
    pub fn countGame(_: *App) anyerror!void {
        game += 1;
    }
    pub fn countMenu(_: *App) anyerror!void {
        menu += 1;
    }
    pub fn countKey(_: *App) anyerror!void {
        key += 1;
    }
    pub fn press(_: *App, _: struct {}) !void {
        pressed += 1;
    }
};

/// A project of a test's own, with a PNG in it: see `scene.zig`'s `Game`.
pub const Files = struct {
    tmp: testing.TmpDir,
    buffer: [128]u8 = undefined,
    root: []const u8 = "",

    pub fn init() !Files {
        var files: Files = .{ .tmp = testing.tmpDir(.{}) };
        try files.tmp.dir.createDirPath(testing.io, "art");
        return files;
    }

    /// The root, from the working directory. Made where the struct has come
    /// to rest, since it points into `buffer`.
    pub fn at(files: *Files) ![]const u8 {
        files.root = try std.fmt.bufPrint(&files.buffer, ".zig-cache/tmp/{s}", .{files.tmp.sub_path});
        return files.root;
    }

    pub fn picture(files: *Files, path: []const u8) !void {
        var buffer: [192]u8 = undefined;
        const file = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ try files.at(), path });
        try image.png.writeFile(testing.allocator, testing.io, file, .{ .width = 1, .height = 1, .pixels = &.{ 255, 255, 255, 255 }, .row_pitch = 4 }, .{});
    }

    pub fn app(files: *Files) !*App {
        return App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = try files.at() });
    }
};
