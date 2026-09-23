// SPDX-License-Identifier: BSD-3-Clause

//! The kinds of file a game is made of, in one list: what each is called,
//! which files are of it, and the handle a component holds one by.
//!
//! ```zig
//! const kind = AssetKind.ofPath("res://ui/game.theme").?; // .theme
//! const Handle = AssetKind.Handle(.texture);               // TextureHandle
//! const source = app.assetSource(sprite.texture);          // "res://art/hero.png"
//! ```
//!
//! A scene writes a handle as the file it was read from and reads it back
//! by the same list, a project setting names a file of a kind with
//! `attr.ProjectFile`, and an editor draws a field for every handle in it -
//! so a new kind is an entry here, its handle's three calls in
//! `App.assetSource`, `App.loadAsset` and `App.findAsset`, and nothing else.

const std = @import("std");
const testing = std.testing;

const Assets = @import("assets.zig");
const script = @import("script.zig");
const theme = @import("theme.zig");
const tileset = @import("tileset.zig");

pub const AssetKind = enum {
    texture,
    font,
    scene,
    script,
    tileset,
    theme,

    /// What a person calls one.
    pub fn label(self: AssetKind) []const u8 {
        return switch (self) {
            .texture => "texture",
            .font => "font",
            .scene => "scene",
            .script => "script",
            .tileset => "tile set",
            .theme => "theme",
        };
    }

    /// What one is, for a field that asks for one.
    pub fn about(self: AssetKind) []const u8 {
        return switch (self) {
            .texture => "A PNG",
            .font => "A TrueType font",
            .scene => "A scene",
            .script => "A Flux script",
            .tileset => "A tile set",
            .theme => "A theme",
        };
    }

    /// A path one might have.
    pub fn example(self: AssetKind) []const u8 {
        return switch (self) {
            .texture => "res://art/hero.png",
            .font => "res://fonts/body.ttf",
            .scene => "res://levels/main.json",
            .script => "res://scripts/door.flux",
            .tileset => "res://tiles/terrain.tileset",
            .theme => "res://ui/game.theme",
        };
    }

    /// The endings of its files, the usual one first.
    pub fn extensions(self: AssetKind) []const []const u8 {
        return switch (self) {
            .texture => &.{".png"},
            .font => &.{ ".ttf", ".otf", ".ttc" },
            .scene => &.{ ".json", ".scene", ".cbor" },
            .script => &.{".flux"},
            .tileset => &.{".tileset"},
            .theme => &.{".theme"},
        };
    }

    /// The kind a file's ending says it is, or null for none of them. A
    /// `.json` is a scene only when it says so inside, which its name cannot
    /// tell: it is left for the caller to look into.
    pub fn ofPath(path: []const u8) ?AssetKind {
        const ending = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ending, ".json")) return null;
        for (std.enums.values(AssetKind)) |kind| {
            for (kind.extensions()) |known| {
                if (std.ascii.eqlIgnoreCase(ending, known)) return kind;
            }
        }
        return null;
    }

    /// The handle a component holds one by. A scene is not held by a handle
    /// yet.
    pub fn Handle(comptime self: AssetKind) type {
        return switch (self) {
            .texture => Assets.TextureHandle,
            .font => Assets.FontHandle,
            .script => script.ScriptHandle,
            .tileset => tileset.TileSetHandle,
            .theme => theme.ThemeHandle,
            .scene => @compileError("a scene is not held by a handle"),
        };
    }

    /// The kind a handle type holds, or null for a type that is not one.
    pub fn of(comptime T: type) ?AssetKind {
        inline for (handled) |kind| {
            if (T == kind.Handle()) return kind;
        }
        return null;
    }

    /// Every kind a component can hold a file of: the ones with a handle.
    pub const handled = [_]AssetKind{ .texture, .font, .script, .tileset, .theme };
};

test "a file's kind is its ending's, whatever its case, and a scene's JSON is not said by its name" {
    try testing.expectEqual(AssetKind.texture, AssetKind.ofPath("res://art/Hero.PNG").?);
    try testing.expectEqual(AssetKind.tileset, AssetKind.ofPath("res://tiles/terrain" ++ tileset.extension).?);
    try testing.expectEqual(AssetKind.theme, AssetKind.ofPath("game" ++ theme.extension).?);
    try testing.expectEqual(AssetKind.scene, AssetKind.ofPath("res://levels/one.cbor").?);
    try testing.expect(AssetKind.ofPath("res://levels/one.json") == null);
    try testing.expect(AssetKind.ofPath("notes.md") == null);
}

test "each handle names its kind, and each kind its handle" {
    inline for (AssetKind.handled) |kind| {
        try testing.expectEqual(kind, AssetKind.of(kind.Handle()).?);
    }
    try testing.expect(AssetKind.of(u32) == null);
}
