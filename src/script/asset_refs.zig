// SPDX-License-Identifier: BSD-3-Clause

//! A file the engine reads, as a script holds it: a value of the file's
//! kind - `Texture`, `Scene`, `SpriteFrames` and the rest - that a script
//! hands wherever the engine wants one, and that says where it was read
//! from.

const std = @import("std");
const Allocator = std.mem.Allocator;

const flux = @import("fluxion_script");
const math = @import("fluxion_math");
const AssetKind = @import("../assets/asset_kind.zig").AssetKind;
const attr = @import("../reflect/attr.zig");
const sprite_frames = @import("../animation/sprite_frames.zig");
const Assets = @import("../assets/assets.zig");
const geometry = @import("../math/geometry.zig");
const log = std.log.scoped(.fluxion_engine);

const Scripts = @import("script.zig").Scripts;

/// A set of sprite frames as a script holds it: what `sprite.sprite_frames`,
/// `app.newSpriteFrames()` and `app.loadSpriteFrames(path)` give. The calls
/// are `SpriteFrames`'s, by the same names, a texture given by its path:
///
/// ```
/// let frames = app.newSpriteFrames();
/// frames.addAnimation("walk");
/// frames.setAnimationSpeed("walk", 8);
/// frames.addFrameRegion("walk", "res://art/hero.png", 0, 0, 32, 32);
/// print(frames.getAnimationNames(), frames.resource_path);
/// ```
///
/// `resource_path` is the file it is, empty for new frames not saved yet. One
/// set of frames is one value: two sprites playing it hand back the same.
/// A call that cannot be done - an animation it has not, a name it has - says
/// why in the log and gives an error.
pub const FramesRef = struct {
    scripts: *Scripts,
    handle: sprite_frames.SpriteFramesHandle,

    pub const reflect_name = "SpriteFrames";
    pub const reflect_opaque = true;
    pub const reflect_methods = .{
        .addAnimation = .{attr.Params{ .names = &.{"name"} }},
        .addFrame = .{ attr.Params{ .names = &.{ "name", "texture", "duration", "at_position" } }, attr.defaults(.{ 1.0, -1 }) },
        .addFrameRegion = .{ attr.Params{ .names = &.{ "name", "texture", "x", "y", "width", "height", "duration", "at_position" } }, attr.defaults(.{ 1.0, -1 }) },
        .clear = .{attr.Params{ .names = &.{"name"} }},
        .clearAll = .{},
        .duplicateAnimation = .{attr.Params{ .names = &.{ "from", "to" } }},
        .getAnimationLoopMode = .{attr.Params{ .names = &.{"name"} }},
        .setAnimationLoopMode = .{attr.Params{ .names = &.{ "name", "mode" } }},
        .getAnimationNames = .{ attr.Params{ .names = &.{"vm"} }, flux.Returns.of([]const []const u8) },
        .getAnimationSpeed = .{attr.Params{ .names = &.{"name"} }},
        .setAnimationSpeed = .{attr.Params{ .names = &.{ "name", "fps" } }},
        .getFrameCount = .{attr.Params{ .names = &.{"name"} }},
        .getFrameDuration = .{attr.Params{ .names = &.{ "name", "index" } }},
        .getFrameTexture = .{attr.Params{ .names = &.{ "name", "index" } }},
        .getFrameRegion = .{attr.Params{ .names = &.{ "name", "index" } }},
        .hasAnimation = .{attr.Params{ .names = &.{"name"} }},
        .removeAnimation = .{attr.Params{ .names = &.{"name"} }},
        .removeFrame = .{attr.Params{ .names = &.{ "name", "index" } }},
        .renameAnimation = .{attr.Params{ .names = &.{ "name", "new_name" } }},
        .setFrame = .{ attr.Params{ .names = &.{ "name", "index", "texture", "duration" } }, attr.defaults(.{1.0}) },
        .setFrameRegion = .{ attr.Params{ .names = &.{ "name", "index", "texture", "x", "y", "width", "height", "duration" } }, attr.defaults(.{1.0}) },
    };

    const Failed = sprite_frames.Error || error{NoSuchFrames};

    fn held(self: *FramesRef) error{NoSuchFrames}!*sprite_frames.SpriteFrames {
        return self.scripts.app.sprite_frames.edit(self.handle) orelse error.NoSuchFrames;
    }

    fn gpa(self: *FramesRef) Allocator {
        return self.scripts.app.gpa;
    }

    /// `err`, said in the log as the call that met it.
    fn refused(self: *FramesRef, comptime call: []const u8, name: []const u8, err: Failed) Failed {
        const source = self.scripts.app.sprite_frames.sourceOf(self.handle) orelse "sprite frames";
        log.warn("{s}: {s}(\"{s}\"): {t}", .{ source, call, name, err });
        return err;
    }

    pub fn addAnimation(self: *FramesRef, name: []const u8) Failed!void {
        (try self.held()).addAnimation(self.gpa(), name) catch |err| return self.refused("addAnimation", name, err);
    }

    pub fn addFrame(self: *FramesRef, name: []const u8, texture: Assets.TextureHandle, duration: f32, at_position: i32) Failed!void {
        (try self.held()).addFrame(self.gpa(), name, texture, duration, at_position) catch |err| return self.refused("addFrame", name, err);
    }

    pub fn addFrameRegion(self: *FramesRef, name: []const u8, texture: Assets.TextureHandle, x: f32, y: f32, width: f32, height: f32, duration: f32, at_position: i32) Failed!void {
        (try self.held()).addFrameRegion(self.gpa(), name, texture, .init(x, y, width, height), duration, at_position) catch |err| return self.refused("addFrameRegion", name, err);
    }

    pub fn clear(self: *FramesRef, name: []const u8) Failed!void {
        (try self.held()).clear(name) catch |err| return self.refused("clear", name, err);
    }

    pub fn clearAll(self: *FramesRef) Failed!void {
        try (try self.held()).clearAll(self.gpa());
    }

    pub fn duplicateAnimation(self: *FramesRef, from: []const u8, to: []const u8) Failed!void {
        (try self.held()).duplicateAnimation(self.gpa(), from, to) catch |err| return self.refused("duplicateAnimation", from, err);
    }

    pub fn getAnimationLoopMode(self: *FramesRef, name: []const u8) Failed!sprite_frames.LoopMode {
        return (try self.held()).getAnimationLoopMode(name);
    }

    pub fn setAnimationLoopMode(self: *FramesRef, name: []const u8, mode: sprite_frames.LoopMode) Failed!void {
        (try self.held()).setAnimationLoopMode(name, mode) catch |err| return self.refused("setAnimationLoopMode", name, err);
    }

    /// Their names, in the order of the alphabet.
    pub fn getAnimationNames(self: *FramesRef, vm: *flux.Vm) anyerror!flux.Value {
        const names = try (try self.held()).getAnimationNames(self.gpa());
        defer self.gpa().free(names);
        return flux.bind.toValue(vm, names);
    }

    pub fn getAnimationSpeed(self: *FramesRef, name: []const u8) Failed!f32 {
        return (try self.held()).getAnimationSpeed(name);
    }

    pub fn setAnimationSpeed(self: *FramesRef, name: []const u8, fps: f32) Failed!void {
        (try self.held()).setAnimationSpeed(name, fps) catch |err| return self.refused("setAnimationSpeed", name, err);
    }

    pub fn getFrameCount(self: *FramesRef, name: []const u8) Failed!i32 {
        return (try self.held()).getFrameCount(name);
    }

    pub fn getFrameDuration(self: *FramesRef, name: []const u8, index: i32) Failed!f32 {
        return (try self.held()).getFrameDuration(name, index);
    }

    pub fn getFrameTexture(self: *FramesRef, name: []const u8, index: i32) Failed!Assets.TextureHandle {
        return (try self.held()).getFrameTexture(name, index);
    }

    pub fn getFrameRegion(self: *FramesRef, name: []const u8, index: i32) Failed!geometry.Rect2 {
        return (try self.held()).getFrameRegion(name, index);
    }

    pub fn hasAnimation(self: *FramesRef, name: []const u8) Failed!bool {
        return (try self.held()).hasAnimation(name);
    }

    pub fn removeAnimation(self: *FramesRef, name: []const u8) Failed!void {
        (try self.held()).removeAnimation(self.gpa(), name) catch |err| return self.refused("removeAnimation", name, err);
    }

    pub fn removeFrame(self: *FramesRef, name: []const u8, index: i32) Failed!void {
        (try self.held()).removeFrame(name, index) catch |err| return self.refused("removeFrame", name, err);
    }

    pub fn renameAnimation(self: *FramesRef, name: []const u8, new_name: []const u8) Failed!void {
        (try self.held()).renameAnimation(self.gpa(), name, new_name) catch |err| return self.refused("renameAnimation", name, err);
    }

    pub fn setFrame(self: *FramesRef, name: []const u8, index: i32, texture: Assets.TextureHandle, duration: f32) Failed!void {
        (try self.held()).setFrame(name, index, texture, duration) catch |err| return self.refused("setFrame", name, err);
    }

    pub fn setFrameRegion(self: *FramesRef, name: []const u8, index: i32, texture: Assets.TextureHandle, x: f32, y: f32, width: f32, height: f32, duration: f32) Failed!void {
        (try self.held()).setFrameRegion(name, index, texture, .init(x, y, width, height), duration) catch |err| return self.refused("setFrameRegion", name, err);
    }

    /// The file it is: empty for frames not saved yet.
    pub fn resourcePath(self: *const FramesRef) []const u8 {
        const frames = self.scripts.app.sprite_frames.get(self.handle) orelse return "";
        return if (frames.on_disc) frames.source else "";
    }
};

/// A file of the game's as the scripts see it - a `Texture`, a `Scene`, an
/// `AudioClip` - given by its path where one is wanted: `var icon: Texture =
/// "res://icon.png"`, `sprite.texture = icon`, `app.instantiate(enemy,
/// self.entity)`. Its `resource_path` is the file. One file is one value;
/// sprite frames are `FramesRef`, with calls of their own.
pub fn AssetRef(comptime kind: AssetKind) type {
    return struct {
        scripts: *Scripts,
        handle: kind.Handle(),

        const Self = @This();

        pub const reflect_name = assetTypeName(kind);
        pub const reflect_opaque = true;
        pub const reflect_methods = switch (kind) {
            .texture => .{ .width = .{}, .height = .{}, .size = .{} },
            .audio => .{ .length = .{} },
            else => .{},
        };

        /// How many pixels across: nought once it is unloaded.
        pub fn width(self: *const Self) i32 {
            const held = self.scripts.app.assets.get(self.handle) orelse return 0;
            return @intCast(held.width);
        }

        /// How many pixels down: nought once it is unloaded.
        pub fn height(self: *const Self) i32 {
            const held = self.scripts.app.assets.get(self.handle) orelse return 0;
            return @intCast(held.height);
        }

        /// Its width and height, in pixels.
        pub fn size(self: *const Self) math.Vec2 {
            return .init(@floatFromInt(self.width()), @floatFromInt(self.height()));
        }

        /// How long it plays, in seconds.
        pub fn length(self: *const Self) f32 {
            return self.scripts.app.audioLength(self.handle);
        }

        /// The file it is.
        pub fn resourcePath(self: *const Self) []const u8 {
            return self.scripts.app.assetSource(self.handle) orelse "";
        }
    };
}

/// What each kind of file is called in a script.
fn assetTypeName(comptime kind: AssetKind) [:0]const u8 {
    return switch (kind) {
        .texture => "Texture",
        .font => "Font",
        .scene => "Scene",
        .script => "ScriptFile",
        .tileset => "TileSet",
        .theme => "Theme",
        .data => "DataFile",
        .audio => "AudioClip",
        .animation => "AnimationLibrary",
        .frames => "SpriteFrames",
        .shader => "Shader",
        .mesh => "Mesh",
    };
}

/// The value a file of `kind` is to the scripts.
pub fn RefOf(comptime kind: AssetKind) type {
    return if (kind == .frames) FramesRef else AssetRef(kind);
}

/// The file a script's value is, and of what kind: null for one that is
/// none.
pub fn assetOf(value: flux.Value) ?struct { kind: AssetKind, path: []const u8 } {
    if (value.tag != .handle) return null;
    const h = value.as(flux.object.Handle);
    if (h.live != null) return null;
    inline for (AssetKind.handled) |kind| {
        if (h.value.asConst(RefOf(kind))) |ref| return .{ .kind = kind, .path = ref.resourcePath() };
    }
    return null;
}

/// Which file a value stands for, by its kind and handle.
pub const AssetKey = struct { kind: AssetKind, index: u32, generation: u32 };
