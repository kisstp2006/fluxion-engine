// SPDX-License-Identifier: BSD-3-Clause

//! A file of settings a game keeps for itself - the player's volume, the
//! last slot saved - as sections of keys:
//!
//! ```zig
//! var config = try fx.ConfigFile.load(app, "user://settings.cfg");
//! defer config.deinit();
//! const volume = config.getFloat("audio", "music", 0.8);
//! try config.set("display", "fullscreen", true);
//! try config.save(app, "user://settings.cfg");
//! ```
//!
//! The file is a JSON object of objects, `{ "audio": { "music": 0.8 } }`, to
//! read and to edit by hand. Nothing is declared first: a key is whatever it
//! was last set to, and what a file holds that the game does not ask for -
//! written by a newer build, or by hand - is kept and saved back. A game
//! whose settings have a shape of their own reads them into a struct with
//! `settings_file` instead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const json = @import("fluxion_json");

const App = @import("App.zig");

pub const ConfigFile = struct {
    doc: json.Document,

    pub const Error = error{
        /// The file is JSON, and not an object of sections.
        NotAConfig,
    };

    /// One with nothing in it.
    pub fn init(gpa: Allocator) Allocator.Error!ConfigFile {
        var doc: json.Document = try .init(gpa);
        errdefer doc.deinit();
        doc.root = try doc.object();
        return .{ .doc = doc };
    }

    pub fn deinit(self: *ConfigFile) void {
        self.doc.deinit();
        self.* = undefined;
    }

    /// One read from text: JSON, comments and all.
    pub fn parse(gpa: Allocator, text: []const u8, diagnostics: ?*json.Diagnostics) !ConfigFile {
        var doc = try json.parse(gpa, text, .{ .syntax = .json5, .diagnostics = diagnostics });
        errdefer doc.deinit();
        if (doc.root.asObject() == null) return error.NotAConfig;
        return .{ .doc = doc };
    }

    /// The file at `path` - `user://`, `res://` or the system's - or one
    /// with nothing in it where there is no file yet: the first run.
    pub fn load(app: *App, path: []const u8) !ConfigFile {
        const text = app.readText(app.gpa, path) catch |err| switch (err) {
            error.FileNotFound => return init(app.gpa),
            else => return err,
        };
        defer app.gpa.free(text);
        return parse(app.gpa, text, null);
    }

    /// Write it to `path`, and the folders it is in with it.
    pub fn save(self: *const ConfigFile, app: *App, path: []const u8) !void {
        const text = try self.write(app.gpa);
        defer app.gpa.free(text);
        try app.writeText(path, text);
    }

    /// Its text, as `save` writes it. The caller frees it.
    pub fn write(self: *const ConfigFile, gpa: Allocator) json.StringifyError![]u8 {
        return json.stringify(gpa, self.doc.root, .{ .indent = 2 });
    }

    /// What `key` of `section` holds: `.null` for one it does not.
    pub fn get(self: *const ConfigFile, section: []const u8, key: []const u8) json.Value {
        const held = self.doc.root.get(section);
        if (held.asObject() == null) return .null;
        return held.get(key);
    }

    pub fn has(self: *const ConfigFile, section: []const u8, key: []const u8) bool {
        return self.get(section, key) != .null;
    }

    /// A number, whether it was written whole or not; `default` for none.
    pub fn getFloat(self: *const ConfigFile, section: []const u8, key: []const u8, default: f64) f64 {
        return self.get(section, key).asFloat(f64) orelse default;
    }

    pub fn getInt(self: *const ConfigFile, section: []const u8, key: []const u8, default: i64) i64 {
        return self.get(section, key).asInt(i64) orelse default;
    }

    pub fn getBool(self: *const ConfigFile, section: []const u8, key: []const u8, default: bool) bool {
        return self.get(section, key).asBool() orelse default;
    }

    /// Text, good until the file is changed or let go of.
    pub fn getString(self: *const ConfigFile, section: []const u8, key: []const u8, default: []const u8) []const u8 {
        return self.get(section, key).asString() orelse default;
    }

    /// Set `key` of `section`, making the section when it is new: a bool, a
    /// number, text, or anything fluxion-json writes.
    pub fn set(self: *ConfigFile, section: []const u8, key: []const u8, value: anytype) !void {
        if (self.doc.root.get(section).asObject() == null) try self.doc.root.put(section, try self.doc.object());
        try self.doc.root.get(section).put(key, value);
    }

    /// Take a key out. Says whether it was there.
    pub fn erase(self: *ConfigFile, section: []const u8, key: []const u8) bool {
        const held = self.doc.root.get(section);
        if (held.asObject() == null) return false;
        return held.remove(key);
    }

    /// Take a whole section out.
    pub fn eraseSection(self: *ConfigFile, section: []const u8) bool {
        return self.doc.root.remove(section);
    }

    pub fn sections(self: *const ConfigFile) []const []const u8 {
        return self.doc.root.keys();
    }

    /// The keys of a section, none for one it has not got.
    pub fn keys(self: *const ConfigFile, section: []const u8) []const []const u8 {
        const held = self.doc.root.get(section);
        if (held.asObject() == null) return &.{};
        return held.keys();
    }
};

test "a key is set in a section, read back as what it is, and kept with what the file had" {
    var config = try ConfigFile.parse(testing.allocator,
        \\{
        \\  // Written by hand, and by a newer build.
        \\  "audio": { "music": 1, "voices": 0.5 },
        \\  "future": { "hdr": true }
        \\}
    , null);
    defer config.deinit();
    try testing.expectEqual(@as(f64, 1), config.getFloat("audio", "music", 0));
    try testing.expectEqual(@as(f64, 0.5), config.getFloat("audio", "voices", 0));
    try testing.expectEqual(@as(f64, 0.8), config.getFloat("audio", "effects", 0.8));
    try testing.expect(!config.has("display", "fullscreen"));

    try config.set("display", "fullscreen", true);
    try config.set("player", "name", "Mike");
    try config.set("audio", "music", 0.25);
    try testing.expect(config.getBool("display", "fullscreen", false));
    try testing.expectEqualStrings("Mike", config.getString("player", "name", ""));
    try testing.expect(config.erase("audio", "voices"));
    try testing.expect(!config.erase("audio", "voices"));

    const text = try config.write(testing.allocator);
    defer testing.allocator.free(text);
    var again = try ConfigFile.parse(testing.allocator, text, null);
    defer again.deinit();
    try testing.expectEqual(@as(f64, 0.25), again.getFloat("audio", "music", 0));
    try testing.expect(again.getBool("future", "hdr", false));
    try testing.expectEqual(@as(usize, 4), again.sections().len);
    try testing.expectEqual(@as(usize, 1), again.keys("audio").len);

    try testing.expectError(error.NotAConfig, ConfigFile.parse(testing.allocator, "[1, 2]", null));
}
