// SPDX-License-Identifier: BSD-3-Clause

//! Sprite frames: named animations of pictures - each a texture, or a piece
//! of one - kept in a `.frames` file, and the `AnimatedSprite2D` that plays
//! one of them in the `Sprite` beside it.
//!
//! ```json
//! { "fluxion_frames": 2, "animations": [
//!     { "name": "walk", "speed": 8, "frames": [
//!         { "texture": "res://art/hero.png", "region": [0, 0, 32, 32] },
//!         { "texture": "res://art/hero.png", "region": [32, 0, 32, 32], "duration": 2 } ] },
//!     { "name": "hit", "speed": 12, "loop": "none", "frames": [ { "texture": "res://art/spark.png" } ] } ] }
//! ```
//!
//! **An animation** has a name, a `speed` in frames a second - 5 unless it
//! says -, a `loop` - `"linear"`, round again from the first frame, unless it
//! says `"pingpong"`, back and forth, or `"none"`, once - and its frames, in
//! order. **A frame** is a texture, or the `region` of one in texels -
//! `[x, y, width, height]`, the whole texture without one -, shown for
//! `duration` of the animation's frames, one unless it says. A frame with no
//! texture shows nothing. A new set of frames has one animation, `"default"`.
//!
//! **Changed in code** through `SpriteFrames`'s calls - `addAnimation`,
//! `addFrame`, `setAnimationSpeed`, `renameAnimation`... - which a script calls
//! by the same names on what `sprite.sprite_frames` is:
//!
//! ```
//! let frames = app.newSpriteFrames();
//! frames.addAnimation("blink");
//! frames.addFrameRegion("blink", "res://art/eye.png", 0, 0, 16, 16);
//! sprite.sprite_frames = frames;
//! sprite.play("blink");
//! ```
//!
//! One set of frames is shared by every sprite that plays it: a change to it
//! shows on all of them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const id = @import("fluxion_id");
const json = @import("fluxion_json");
const math = @import("fluxion_math");

const App = @import("App.zig");
const Assets = @import("assets.zig");
const Project = @import("Project.zig");
const attr = @import("attr.zig");
const components = @import("components.zig");
const file_table = @import("file_table.zig");
const geometry = @import("geometry.zig");

const Entity = ecs.Entity;
const Rect2 = geometry.Rect2;
const Region = components.Region;
const Sprite = components.Sprite;
const TextureHandle = Assets.TextureHandle;
const log = std.log.scoped(.fluxion_engine);

pub const SpriteFramesHandle = file_table.Handle("SpriteFramesHandle");

pub const extension = ".frames";
pub const header = "fluxion_frames";
pub const version = 2;

/// The animation a new set of frames has.
pub const default_name = "default";
/// Frames a second, unless an animation says.
pub const default_speed = 5;

/// What an animation does at its last frame.
pub const LoopMode = enum(u8) {
    /// Stops there, and says `animation_finished`.
    none,
    /// Goes round again from its first frame.
    linear,
    /// Turns round and goes back, and at its first frame turns again.
    pingpong,

    pub const reflect_name = "LoopMode";
};

pub const Frame = struct {
    /// None shows nothing.
    texture: TextureHandle = .none,
    /// The part of the texture shown, in texels: all of it with no size.
    region: Rect2 = .{},
    /// How long it shows, in frames of the animation's speed.
    duration: f32 = 1,

    /// How long it shows, if it says something that is one.
    pub fn length(self: Frame) f32 {
        return if (self.duration > 0 and std.math.isFinite(self.duration)) self.duration else 1;
    }

    /// The part of its texture it shows, as a sprite's region, and its size
    /// in texels: nothing for a frame with no texture, or with one that is
    /// gone.
    pub fn shown(self: Frame, assets: *Assets) ?Shown {
        if (self.texture.isNone()) return null;
        const size = assets.sizeOf(self.texture) orelse return null;
        if (self.region.size.x <= 0 or self.region.size.y <= 0) return .{ .region = .full, .width = size.width, .height = size.height };
        const r = self.region;
        return .{
            .region = .fromPixels(r.position.x, r.position.y, r.size.x, r.size.y, @max(size.width, 1), @max(size.height, 1)),
            .width = r.size.x,
            .height = r.size.y,
        };
    }

    pub const Shown = struct { region: Region, width: f32, height: f32 };
};

/// One animation of a set: see the top of this file.
pub const Clip = struct {
    name: []u8,
    /// Frames a second.
    speed: f32 = default_speed,
    loop: LoopMode = .linear,
    frames: std.ArrayList(Frame) = .empty,

    fn deinit(self: *Clip, gpa: Allocator) void {
        gpa.free(self.name);
        self.frames.deinit(gpa);
    }
};

pub const Error = error{
    /// It has no animation of that name.
    NoSuchAnimation,
    /// It has one of that name already.
    AnimationExists,
    /// The animation has no frame there.
    NoSuchFrame,
} || Allocator.Error;

/// A set of sprite frames: a `.frames` file read, or one made in code.
pub const SpriteFrames = struct {
    source: []u8,
    on_disc: bool,
    /// In the order they were added: what an animated sprite given these
    /// frames falls back to is the first.
    animations: std.ArrayList(Clip) = .empty,
    /// Moved on by every change, for what keeps something worked out of it.
    revision: u32 = 0,

    /// The animation called `name`.
    pub fn find(self: *const SpriteFrames, name: []const u8) ?*const Clip {
        const at = self.indexOf(name) orelse return null;
        return &self.animations.items[at];
    }

    pub fn indexOf(self: *const SpriteFrames, name: []const u8) ?usize {
        for (self.animations.items, 0..) |clip, at| {
            if (std.mem.eql(u8, clip.name, name)) return at;
        }
        return null;
    }

    pub fn touched(self: *SpriteFrames) void {
        self.revision +%= 1;
    }

    fn clipOf(self: *SpriteFrames, name: []const u8) Error!*Clip {
        const at = self.indexOf(name) orelse return error.NoSuchAnimation;
        return &self.animations.items[at];
    }

    fn frameOf(self: *const SpriteFrames, name: []const u8, index: i32) ?Frame {
        const clip = self.find(name) orelse return null;
        if (index < 0 or index >= clip.frames.items.len) return null;
        return clip.frames.items[@intCast(index)];
    }

    /// A new animation, with no frames, at 5 frames a second and looping.
    pub fn addAnimation(self: *SpriteFrames, gpa: Allocator, name: []const u8) Error!void {
        if (self.indexOf(name) != null) return error.AnimationExists;
        const made: Clip = .{ .name = try gpa.dupe(u8, name) };
        self.animations.append(gpa, made) catch |err| {
            gpa.free(made.name);
            return err;
        };
        self.touched();
    }

    /// `texture` as a frame of `name`, shown for `duration` frames: at
    /// `at_position`, or after the others when that is not a frame's place.
    pub fn addFrame(self: *SpriteFrames, gpa: Allocator, name: []const u8, texture: TextureHandle, duration: f32, at_position: i32) Error!void {
        return self.addFrameRegion(gpa, name, texture, .{}, duration, at_position);
    }

    /// `addFrame` with a part of the texture, in texels.
    pub fn addFrameRegion(self: *SpriteFrames, gpa: Allocator, name: []const u8, texture: TextureHandle, region: Rect2, duration: f32, at_position: i32) Error!void {
        const clip = try self.clipOf(name);
        const frame: Frame = .{ .texture = texture, .region = region, .duration = duration };
        if (at_position >= 0 and at_position < clip.frames.items.len) {
            try clip.frames.insert(gpa, @intCast(at_position), frame);
        } else try clip.frames.append(gpa, frame);
        self.touched();
    }

    /// `name`'s frames, all of them gone.
    pub fn clear(self: *SpriteFrames, name: []const u8) Error!void {
        const clip = try self.clipOf(name);
        clip.frames.clearRetainingCapacity();
        self.touched();
    }

    /// Every animation gone, and a `"default"` in their place.
    pub fn clearAll(self: *SpriteFrames, gpa: Allocator) Error!void {
        for (self.animations.items) |*clip| clip.deinit(gpa);
        self.animations.clearRetainingCapacity();
        try self.addAnimation(gpa, default_name);
    }

    /// A copy of `from` called `to`, which none of them is called.
    pub fn duplicateAnimation(self: *SpriteFrames, gpa: Allocator, from: []const u8, to: []const u8) Error!void {
        const at = self.indexOf(from) orelse return error.NoSuchAnimation;
        if (self.indexOf(to) != null) return error.AnimationExists;
        var made: Clip = .{ .name = try gpa.dupe(u8, to) };
        errdefer made.deinit(gpa);
        const original = &self.animations.items[at];
        made.speed = original.speed;
        made.loop = original.loop;
        try made.frames.appendSlice(gpa, original.frames.items);
        try self.animations.append(gpa, made);
        self.touched();
    }

    pub fn getAnimationLoopMode(self: *const SpriteFrames, name: []const u8) LoopMode {
        const clip = self.find(name) orelse return .none;
        return clip.loop;
    }

    pub fn setAnimationLoopMode(self: *SpriteFrames, name: []const u8, mode: LoopMode) Error!void {
        const clip = try self.clipOf(name);
        clip.loop = mode;
        self.touched();
    }

    /// Their names, in the order of the alphabet, borrowed from them: the
    /// list is the caller's to free.
    pub fn getAnimationNames(self: *const SpriteFrames, gpa: Allocator) Allocator.Error![][]const u8 {
        const out = try gpa.alloc([]const u8, self.animations.items.len);
        for (self.animations.items, out) |clip, *name| name.* = clip.name;
        std.mem.sortUnstable([]const u8, out, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        return out;
    }

    /// Frames a second; nought for an animation it has not.
    pub fn getAnimationSpeed(self: *const SpriteFrames, name: []const u8) f32 {
        const clip = self.find(name) orelse return 0;
        return clip.speed;
    }

    pub fn setAnimationSpeed(self: *SpriteFrames, name: []const u8, fps: f32) Error!void {
        const clip = try self.clipOf(name);
        clip.speed = if (std.math.isFinite(fps)) @max(fps, 0) else 0;
        self.touched();
    }

    /// Nought for an animation it has not.
    pub fn getFrameCount(self: *const SpriteFrames, name: []const u8) i32 {
        const clip = self.find(name) orelse return 0;
        return @intCast(clip.frames.items.len);
    }

    pub fn getFrameDuration(self: *const SpriteFrames, name: []const u8, index: i32) f32 {
        const frame = self.frameOf(name, index) orelse return 1;
        return frame.duration;
    }

    pub fn getFrameTexture(self: *const SpriteFrames, name: []const u8, index: i32) TextureHandle {
        const frame = self.frameOf(name, index) orelse return .none;
        return frame.texture;
    }

    /// The part of its texture a frame shows, in texels: no size for all of
    /// it.
    pub fn getFrameRegion(self: *const SpriteFrames, name: []const u8, index: i32) Rect2 {
        const frame = self.frameOf(name, index) orelse return .{};
        return frame.region;
    }

    pub fn hasAnimation(self: *const SpriteFrames, name: []const u8) bool {
        return self.indexOf(name) != null;
    }

    pub fn removeAnimation(self: *SpriteFrames, gpa: Allocator, name: []const u8) Error!void {
        const at = self.indexOf(name) orelse return error.NoSuchAnimation;
        var gone = self.animations.orderedRemove(at);
        gone.deinit(gpa);
        self.touched();
    }

    pub fn removeFrame(self: *SpriteFrames, name: []const u8, index: i32) Error!void {
        const clip = try self.clipOf(name);
        if (index < 0 or index >= clip.frames.items.len) return error.NoSuchFrame;
        _ = clip.frames.orderedRemove(@intCast(index));
        self.touched();
    }

    /// `name` called `new_name`, which none of the others is called.
    pub fn renameAnimation(self: *SpriteFrames, gpa: Allocator, name: []const u8, new_name: []const u8) Error!void {
        const clip = try self.clipOf(name);
        if (std.mem.eql(u8, name, new_name)) return;
        if (self.indexOf(new_name) != null) return error.AnimationExists;
        const copy = try gpa.dupe(u8, new_name);
        gpa.free(clip.name);
        clip.name = copy;
        self.touched();
    }

    /// The frame at `index` of `name` made `texture`, all of it, shown for
    /// `duration`.
    pub fn setFrame(self: *SpriteFrames, name: []const u8, index: i32, texture: TextureHandle, duration: f32) Error!void {
        return self.setFrameRegion(name, index, texture, .{}, duration);
    }

    /// `setFrame` with a part of the texture, in texels.
    pub fn setFrameRegion(self: *SpriteFrames, name: []const u8, index: i32, texture: TextureHandle, region: Rect2, duration: f32) Error!void {
        const clip = try self.clipOf(name);
        if (index < 0 or index >= clip.frames.items.len) return error.NoSuchFrame;
        clip.frames.items[@intCast(index)] = .{ .texture = texture, .region = region, .duration = duration };
        self.touched();
    }

    fn deinitContent(self: *SpriteFrames, gpa: Allocator) void {
        for (self.animations.items) |*clip| clip.deinit(gpa);
        self.animations.deinit(gpa);
    }
};

const Table = id.handle.Table(SpriteFrames);

fn toId(handle: SpriteFramesHandle) Table.Handle {
    return @bitCast(handle);
}

fn fromId(handle: Table.Handle) SpriteFramesHandle {
    return @bitCast(handle);
}

// -------------------------------------------------------------------------
// Reading and writing
// -------------------------------------------------------------------------

pub const ReadError = error{ NotFrames, NewerVersion, Malformed } || json.Error;

/// What `text` says, into `into`; its textures read through `app`. What
/// makes no sense is said in the log and left out.
pub fn read(app: *App, into: *SpriteFrames, text: []const u8) ReadError!void {
    const gpa = app.gpa;
    var doc = try json.parse(gpa, text, .{});
    defer doc.deinit();
    const root = doc.root;
    if (root.asObject() == null or !root.has(header)) return error.NotFrames;
    if ((root.get(header).asInt(i64) orelse return error.Malformed) > version) return error.NewerVersion;
    for (root.get("animations").items()) |given| {
        const name = given.get("name").asString() orelse continue;
        if (into.indexOf(name) != null) {
            log.warn("{s}: a second animation called {s} is left out", .{ into.source, name });
            continue;
        }
        var clip: Clip = .{ .name = try gpa.dupe(u8, name) };
        errdefer clip.deinit(gpa);
        clip.speed = @floatCast(given.get("speed").asFloat(f64) orelse default_speed);
        if (given.get("loop").asString()) |loop| {
            clip.loop = std.meta.stringToEnum(LoopMode, loop) orelse blk: {
                log.warn("{s}: {s} loops as {s}, which is none of none, linear and pingpong", .{ into.source, name, loop });
                break :blk .linear;
            };
        }
        for (given.get("frames").items()) |frame_json| {
            var frame: Frame = .{};
            if (frame_json.get("texture").asString()) |path| frame.texture = textureAt(app, into.source, path);
            const region = frame_json.get("region");
            if (region.len() == 4) frame.region = .init(
                @floatCast(region.get(0).asFloat(f64) orelse 0),
                @floatCast(region.get(1).asFloat(f64) orelse 0),
                @floatCast(region.get(2).asFloat(f64) orelse 0),
                @floatCast(region.get(3).asFloat(f64) orelse 0),
            );
            frame.duration = @floatCast(frame_json.get("duration").asFloat(f64) orelse 1);
            try clip.frames.append(gpa, frame);
        }
        try into.animations.append(gpa, clip);
    }
}

fn textureAt(app: *App, source: []const u8, path: []const u8) TextureHandle {
    return app.loadAsset(TextureHandle, path) catch |err| {
        log.warn("{s}: the texture {s} did not read: {t}", .{ source, path, err });
        return .none;
    };
}

const write_options: json.WriteOptions = .{ .indent = 2 };

/// Sprite frames as their file.
const Document = struct {
    frames: *const SpriteFrames,
    assets: *Assets,

    pub fn toJson(self: Document, w: *json.Writer) json.Writer.Error!void {
        try w.beginObject();
        try w.field(header, @as(u32, version));
        try w.key("animations");
        try w.beginArray();
        for (self.frames.animations.items) |*clip| {
            try w.beginObject();
            try w.field("name", clip.name);
            try w.field("speed", clip.speed);
            if (clip.loop != .linear) try w.field("loop", @tagName(clip.loop));
            try w.key("frames");
            try w.beginArray();
            for (clip.frames.items) |frame| {
                try w.beginObject();
                if (self.assets.textureSource(frame.texture)) |path| try w.field("texture", path);
                const r = frame.region;
                if (r.size.x > 0 and r.size.y > 0) try w.field("region", [4]f32{ r.position.x, r.position.y, r.size.x, r.size.y });
                if (frame.duration != 1) try w.field("duration", frame.duration);
                try w.endObject();
            }
            try w.endArray();
            try w.endObject();
        }
        try w.endArray();
        try w.endObject();
    }
};

// -------------------------------------------------------------------------
// The table
// -------------------------------------------------------------------------

/// An animation of the cells of a grid over a sheet, for `AllFrames.addGrid`:
/// the cells counted across and then down.
pub const GridClip = struct {
    name: []const u8,
    cells: []const u32,
    speed: f32 = default_speed,
    loop: LoopMode = .linear,
};

/// Every set of sprite frames, read or made, and the handles they are found by.
pub const AllFrames = struct {
    table: Table = .empty,
    /// How many `addNew` has made, for their names.
    made: u32 = 0,

    pub fn deinit(self: *AllFrames, gpa: Allocator) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            entry.value.deinitContent(gpa);
            gpa.free(entry.value.source);
        }
        self.table.deinit(gpa);
    }

    pub fn load(self: *AllFrames, app: *App, path: []const u8) !SpriteFramesHandle {
        if (self.find(path)) |known| return known;
        const io = app.io orelse return error.NoIo;
        const source = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(source);
        if (self.find(source)) |known| return known;
        const file = try app.project.osPath(app.gpa, source);
        defer app.gpa.free(file);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, file, app.gpa, .limited(file_table.file_limit));
        defer app.gpa.free(text);
        if (Project.isProjectPath(source)) {
            _ = app.project.uidOf(source) catch |err|
                log.warn("the {s} file beside {s} does not read: {t}", .{ Project.uid_extension, source, err });
        }
        return self.keep(app, source, text, true);
    }

    pub fn add(self: *AllFrames, app: *App, name: []const u8, text: []const u8) !SpriteFramesHandle {
        if (self.find(name)) |known| {
            try self.setText(app, known, text);
            return known;
        }
        return self.keep(app, name, text, false);
    }

    /// A new set of frames, of no file until it is saved as one: one
    /// animation, `"default"`.
    pub fn addNew(self: *AllFrames, app: *App) !SpriteFramesHandle {
        const gpa = app.gpa;
        self.made += 1;
        const source = try std.fmt.allocPrint(gpa, "(new sprite frames {d})", .{self.made});
        errdefer gpa.free(source);
        var made: SpriteFrames = .{ .source = source, .on_disc = false };
        errdefer made.deinitContent(gpa);
        try made.addAnimation(gpa, default_name);
        return fromId(try self.table.add(gpa, made));
    }

    /// Sprite frames made in code: `clips` of the cells of a `columns` by
    /// `rows` grid over `texture`, found by `name`.
    pub fn addGrid(self: *AllFrames, app: *App, name: []const u8, texture: TextureHandle, columns: u16, rows: u16, clips: []const GridClip) !SpriteFramesHandle {
        const gpa = app.gpa;
        const source = try gpa.dupe(u8, name);
        errdefer gpa.free(source);
        var made: SpriteFrames = .{ .source = source, .on_disc = false };
        errdefer made.deinitContent(gpa);
        const size = app.assets.sizeOf(texture);
        for (clips) |given| {
            try made.addAnimation(gpa, given.name);
            const clip = &made.animations.items[made.animations.items.len - 1];
            clip.speed = given.speed;
            clip.loop = given.loop;
            for (given.cells) |cell| {
                const region: Rect2 = if (size) |s| cellRegion(cell, columns, rows, s.width, s.height) else .{};
                try clip.frames.append(gpa, .{ .texture = texture, .region = region });
            }
        }
        return fromId(try self.table.add(gpa, made));
    }

    fn keep(self: *AllFrames, app: *App, source: []const u8, text: []const u8, on_disc: bool) !SpriteFramesHandle {
        const gpa = app.gpa;
        const name = try gpa.dupe(u8, source);
        errdefer gpa.free(name);
        var made: SpriteFrames = .{ .source = name, .on_disc = on_disc };
        read(app, &made, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => log.warn("{s} does not read as sprite frames: {t}", .{ source, err }),
        };
        errdefer made.deinitContent(gpa);
        return fromId(try self.table.add(gpa, made));
    }

    pub fn setText(self: *AllFrames, app: *App, handle: SpriteFramesHandle, text: []const u8) !void {
        const held = self.table.get(toId(handle)) orelse return error.NoSuchFrames;
        var fresh: SpriteFrames = .{ .source = held.source, .on_disc = held.on_disc, .revision = held.revision +% 1 };
        read(app, &fresh, text) catch |err| {
            fresh.deinitContent(app.gpa);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => log.warn("{s} does not read as sprite frames: {t}", .{ held.source, err }),
            };
        };
        held.deinitContent(app.gpa);
        held.* = fresh;
    }

    pub fn reload(self: *AllFrames, app: *App, handle: SpriteFramesHandle) !bool {
        const held = self.table.get(toId(handle)) orelse return false;
        if (!held.on_disc) return false;
        const io = app.io orelse return error.NoIo;
        const file = try app.project.osPath(app.gpa, held.source);
        defer app.gpa.free(file);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, file, app.gpa, .limited(file_table.file_limit));
        defer app.gpa.free(text);
        try self.setText(app, handle, text);
        return true;
    }

    pub fn find(self: *AllFrames, source: []const u8) ?SpriteFramesHandle {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value.source, source)) return fromId(entry.handle);
        }
        return null;
    }

    pub fn get(self: *AllFrames, handle: SpriteFramesHandle) ?*const SpriteFrames {
        return self.table.get(toId(handle));
    }

    pub fn edit(self: *AllFrames, handle: SpriteFramesHandle) ?*SpriteFrames {
        return self.table.get(toId(handle));
    }

    pub fn textOf(self: *AllFrames, app: *App, gpa: Allocator, handle: SpriteFramesHandle) ![]u8 {
        const held = self.table.get(toId(handle)) orelse return error.NoSuchFrames;
        return json.stringify(gpa, Document{ .frames = held, .assets = &app.assets }, write_options);
    }

    pub fn save(self: *AllFrames, app: *App, handle: SpriteFramesHandle) !void {
        const held = self.table.get(toId(handle)) orelse return error.NoSuchFrames;
        if (!held.on_disc) return error.NotAFile;
        return self.saveAs(app, handle, held.source);
    }

    /// Written to `path`. Frames of no file yet become that file's; a file's
    /// are written there as a copy, and stay their own.
    pub fn saveAs(self: *AllFrames, app: *App, handle: SpriteFramesHandle, path: []const u8) !void {
        const io = app.io orelse return error.NoIo;
        const held = self.table.get(toId(handle)) orelse return error.NoSuchFrames;
        const source = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(source);
        if (!held.on_disc) if (self.find(source)) |other| if (!other.eql(handle)) return error.PathTaken;
        const file = try app.project.osPath(app.gpa, source);
        defer app.gpa.free(file);
        try json.save(io, file, Document{ .frames = held, .assets = &app.assets }, write_options);
        if (!held.on_disc) {
            const kept = try app.gpa.dupe(u8, source);
            app.gpa.free(held.source);
            held.source = kept;
            held.on_disc = true;
        }
        if (Project.isProjectPath(source)) _ = try app.project.ensureUid(source);
    }

    pub fn sourceOf(self: *AllFrames, handle: SpriteFramesHandle) ?[]const u8 {
        const held = self.table.get(toId(handle)) orelse return null;
        return held.source;
    }

    pub fn renamed(self: *AllFrames, gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (!entry.value.on_disc) continue;
            const rest = Project.under(entry.value.source, old) orelse continue;
            const moved = try std.mem.concat(gpa, u8, &.{ new, rest });
            gpa.free(entry.value.source);
            entry.value.source = moved;
        }
    }
};

/// The cell `index` of a `columns` by `rows` grid over a sheet of `width`
/// by `height` texels, counted across and then down.
pub fn cellRegion(index: u32, columns: u16, rows: u16, width: f32, height: f32) Rect2 {
    const across: u32 = @max(columns, 1);
    const down: u32 = @max(rows, 1);
    const w = width / @as(f32, @floatFromInt(across));
    const h = height / @as(f32, @floatFromInt(down));
    const x: f32 = @floatFromInt(index % across);
    const y: f32 = @floatFromInt((index / across) % down);
    return .init(x * w, y * h, w, h);
}

// -------------------------------------------------------------------------
// The component
// -------------------------------------------------------------------------

/// The longest animation name a sprite holds: as long as a track's key
/// holds, so a name keyed on the timeline is the whole name.
pub const name_len = @import("property.zig").Value.name_len;

fn nameIn(buffer: *const [name_len]u8) []const u8 {
    return std.mem.sliceTo(buffer, 0);
}

fn setName(buffer: *[name_len]u8, name: []const u8) void {
    buffer.* = @splat(0);
    const kept = @min(name.len, name_len);
    @memcpy(buffer[0..kept], name[0..kept]);
}

fn named(comptime name: []const u8) [name_len]u8 {
    var out: [name_len]u8 = @splat(0);
    @memcpy(out[0..name.len], name);
    return out;
}

/// Plays an animation of its `sprite_frames` in the `Sprite` beside it,
/// writing four of the Sprite's fields every frame: its texture, the region
/// of it shown - mirrored by `flip_h` and `flip_v` -, its size, which is the
/// frame's in texels, and its pivot, which `centered` and `offset` say. Its
/// tint, layer, order and blend stay the Sprite's.
///
/// ```zig
/// const hero = try app.loadSpriteFrames("res://art/hero.frames");
/// const e = try app.world.spawnWith(.{ fx.Transform2D.at(0, 0), fx.Sprite{}, fx.AnimatedSprite2D.autoplaying(hero, "walk") });
/// app.world.get(e, fx.AnimatedSprite2D).?.play("run", 1, false);
/// ```
///
/// **Playing.** `play(name, custom_speed, from_end)` plays an animation - with
/// no name the one it has, on from where it was paused - at `speed_scale`
/// times `custom_speed` its own speed, backwards below nought, and from its
/// end with `from_end`. `playBackwards(name)` is `play(name, -1, true)`.
/// `pause()` holds it where it is; `stop()` puts it back on its first frame
/// as well. A script leaves the last arguments out: `sprite.play("run")`.
///
/// **Going round.** A frame shows until `frame_progress` has gone from 0 to 1
/// - from 1 to 0 backwards - and every new frame says `frame_changed`. Past
/// the last frame an animation that loops goes back to the first and says
/// `animation_looped`, one that goes back and forth turns round and says the
/// same, and one that does neither stays on its last frame, paused, and says
/// `animation_finished`. Backwards, the first frame is the last.
///
/// **A write to a field has more to it.** Another `animation` starts from its
/// first frame - its last when it plays backwards - and says
/// `animation_changed`; another `frame` shows from its beginning and says
/// `frame_changed`; other `sprite_frames` stop it, change an animation they
/// have not to their first and say `sprite_frames_changed`. A script's write
/// goes through `setAnimation`, `setFrame` and `setSpriteFrames` at once; any
/// other - an inspector's, a track's, a system's - is seen by the engine's
/// next pass and made the same. The signals are said at that pass.
///
/// **Autoplay**: the animation it starts by itself the first time the game
/// runs its entity. Not in an editor, where no time goes by.
///
/// **Stepped by the engine** after the animation players and before the
/// systems' `.update`, while its entity runs, and put in its Sprite once more
/// before drawing.
pub const AnimatedSprite2D = extern struct {
    sprite_frames: SpriteFramesHandle = .none,
    animation: [name_len]u8 = named(default_name),
    /// Started by itself when the game first runs its entity; empty for none.
    autoplay: [name_len]u8 = @splat(0),
    /// Its middle on the transform, rather than its top left corner.
    centered: bool = true,
    /// Moves the picture from where `centered` puts it, in texels.
    offset: math.Vec2 = .zero,
    flip_h: bool = false,
    flip_v: bool = false,
    /// The frame it shows, counted from nought.
    frame: i32 = 0,
    /// How far through `frame` it is, from 0 to 1.
    frame_progress: f32 = 0,
    /// Faster above 1, slower below, backwards below nought.
    speed_scale: f32 = 1,

    // What it does while the game runs, worked out again after a scene is
    // read: never saved.
    playing: bool = false,
    /// `play`'s own speed, turned round by a ping-pong.
    custom_speed: f32 = 1,
    /// The frames `animation` has, as the engine's pass last counted them:
    /// what `frame` is kept under. Negative when not known - after another
    /// animation, until the pass counts them.
    frame_count: i32 = -1,
    /// The next pass puts it on its animation's last frame: started from its
    /// end before its frames were counted.
    to_end: bool = false,
    /// The next pass fits a name to its sprite frames: after other frames,
    /// and after another name.
    check_frames: bool = false,
    check_name: bool = false,
    /// Whether the pass has looked at `autoplay`.
    started: bool = false,
    /// Whether the pass has seen it, and so what it saw is below: what a
    /// write to the fields since is told by.
    seen: bool = false,
    seen_frames: SpriteFramesHandle = .none,
    seen_animation: [name_len]u8 = @splat(0),
    seen_frame: i32 = 0,
    /// Signals the setters raised, said at the next pass.
    told_animation: bool = false,
    told_frame: bool = false,
    told_frames: bool = false,

    pub const signals = .{
        .animation_changed = struct {},
        .animation_finished = struct {},
        .animation_looped = struct {},
        .frame_changed = struct {},
        .sprite_frames_changed = struct {},
    };

    pub const reflect_name = "AnimatedSprite2D";
    pub const reflect_fields = .{
        .sprite_frames = .{ attr.Setter{ .method = "setSpriteFrames" }, attr.Doc{ .text = "The animations it plays: a .frames file" } },
        .animation = .{ attr.Setter{ .method = "setAnimation" }, attr.Doc{ .text = "The animation it plays, from its first frame when changed" } },
        .autoplay = .{attr.Doc{ .text = "Starts by itself when the game first runs its entity; empty for none" }},
        .centered = .{attr.Doc{ .text = "Its middle on the transform, rather than its top left corner" }},
        .offset = .{ attr.Unit{ .text = "px" }, attr.Doc{ .text = "Moves the picture from where Centered puts it" } },
        .frame = .{ attr.Setter{ .method = "setFrame" }, attr.Doc{ .text = "The frame it shows, counted from nought" } },
        .frame_progress = .{ attr.Range{ .min = 0, .max = 1 }, attr.Doc{ .text = "How far through the frame it is" } },
        .speed_scale = .{attr.Doc{ .text = "Faster above 1, slower below, backwards below nought" }},
        .playing = .{ attr.Hidden{}, attr.Unsaved{} },
        .custom_speed = .{ attr.Hidden{}, attr.Unsaved{} },
        .frame_count = .{ attr.Hidden{}, attr.Unsaved{} },
        .to_end = .{ attr.Hidden{}, attr.Unsaved{} },
        .check_frames = .{ attr.Hidden{}, attr.Unsaved{} },
        .check_name = .{ attr.Hidden{}, attr.Unsaved{} },
        .started = .{ attr.Hidden{}, attr.Unsaved{} },
        .seen = .{ attr.Hidden{}, attr.Unsaved{} },
        .seen_frames = .{ attr.Hidden{}, attr.Unsaved{} },
        .seen_animation = .{ attr.Hidden{}, attr.Unsaved{} },
        .seen_frame = .{ attr.Hidden{}, attr.Unsaved{} },
        .told_animation = .{ attr.Hidden{}, attr.Unsaved{} },
        .told_frame = .{ attr.Hidden{}, attr.Unsaved{} },
        .told_frames = .{ attr.Hidden{}, attr.Unsaved{} },
    };
    pub const reflect_methods = .{
        .play = .{ attr.Params{ .names = &.{ "name", "custom_speed", "from_end" } }, attr.defaults(.{ "", 1.0, false }), attr.Doc{ .text = "Plays an animation - with no name the one it has - at custom_speed times its speed, from its end with from_end" } },
        .playBackwards = .{ attr.Params{ .names = &.{"name"} }, attr.defaults(.{""}), attr.Doc{ .text = "Plays an animation backwards from its end: play(name, -1, true)" } },
        .pause = .{attr.Doc{ .text = "Holds it where it is" }},
        .stop = .{attr.Doc{ .text = "Holds it on its first frame" }},
        .isPlaying = .{},
        .getPlayingSpeed = .{attr.Doc{ .text = "speed_scale times play's custom speed while it plays, nought while it does not" }},
        .setFrameAndProgress = .{ attr.Params{ .names = &.{ "frame", "progress" } }, attr.Doc{ .text = "Shows frame, progress of the way through it" } },
        .setAnimation = .{attr.Params{ .names = &.{"name"} }},
        .setFrame = .{attr.Params{ .names = &.{"frame"} }},
        .setSpriteFrames = .{attr.Params{ .names = &.{"frames"} }},
    };

    /// One that plays `name` of `frames` once the game runs it.
    pub fn autoplaying(frames: SpriteFramesHandle, name: []const u8) AnimatedSprite2D {
        var made: AnimatedSprite2D = .{ .sprite_frames = frames };
        setName(&made.animation, name);
        setName(&made.autoplay, name);
        return made;
    }

    pub fn animationName(self: *const AnimatedSprite2D) []const u8 {
        return nameIn(&self.animation);
    }

    pub fn autoplayName(self: *const AnimatedSprite2D) []const u8 {
        return nameIn(&self.autoplay);
    }

    pub fn setAutoplay(self: *AnimatedSprite2D, name: []const u8) void {
        setName(&self.autoplay, name);
    }

    pub fn play(self: *AnimatedSprite2D, name: []const u8, custom_speed: f32, from_end: bool) void {
        if (self.sprite_frames.isNone()) return;
        const wanted = if (name.len == 0) self.animationName() else name;
        self.playing = true;
        self.custom_speed = custom_speed;
        if (!std.mem.eql(u8, wanted, self.animationName())) {
            self.changeAnimation(wanted);
            if (from_end) {
                self.toEnd();
            } else self.setFrameAndProgress(0, 0);
            return;
        }
        const backwards = std.math.signbit(self.speed_scale * self.custom_speed);
        if (from_end and backwards and self.frame == 0 and self.frame_progress <= 0) {
            self.toEnd();
        } else if (!from_end and !backwards and self.frame_count >= 0 and self.frame == @max(self.frame_count - 1, 0) and self.frame_progress >= 1) {
            self.setFrameAndProgress(0, 0);
        }
    }

    pub fn playBackwards(self: *AnimatedSprite2D, name: []const u8) void {
        self.play(name, -1, true);
    }

    pub fn pause(self: *AnimatedSprite2D) void {
        self.playing = false;
    }

    pub fn stop(self: *AnimatedSprite2D) void {
        self.playing = false;
        self.custom_speed = 1;
        self.setFrameAndProgress(0, 0);
    }

    pub fn isPlaying(self: *const AnimatedSprite2D) bool {
        return self.playing;
    }

    pub fn getPlayingSpeed(self: *const AnimatedSprite2D) f32 {
        if (!self.playing) return 0;
        return self.speed_scale * self.custom_speed;
    }

    /// Shows `frame`, `progress` of the way through it. Kept to its
    /// animation's frames; nothing without sprite frames.
    pub fn setFrameAndProgress(self: *AnimatedSprite2D, frame: i32, progress: f32) void {
        if (self.sprite_frames.isNone()) return;
        const was = self.frame;
        self.frame = if (frame < 0) 0 else if (self.frame_count >= 0) @min(frame, @max(self.frame_count - 1, 0)) else frame;
        self.frame_progress = progress;
        self.seen_frame = self.frame;
        if (self.frame != was) self.told_frame = true;
    }

    /// What a write to `frame` does: `setFrameAndProgress`, from the
    /// frame's beginning - its end when it plays backwards.
    pub fn setFrame(self: *AnimatedSprite2D, frame: i32) void {
        self.setFrameAndProgress(frame, if (std.math.signbit(self.getPlayingSpeed())) 1 else 0);
    }

    /// What a write to `animation` does: see the comment on the type.
    pub fn setAnimation(self: *AnimatedSprite2D, name: []const u8) void {
        if (std.mem.eql(u8, name, self.animationName())) return;
        self.changeAnimation(name);
        if (std.math.signbit(self.getPlayingSpeed())) {
            self.toEnd();
        } else self.setFrameAndProgress(0, 0);
    }

    /// What a write to `sprite_frames` does: see the comment on the type.
    pub fn setSpriteFrames(self: *AnimatedSprite2D, frames: SpriteFramesHandle) void {
        if (frames.eql(self.sprite_frames)) return;
        self.stop();
        self.sprite_frames = frames;
        self.seen_frames = frames;
        self.frame_count = -1;
        self.check_frames = true;
        self.told_frames = true;
    }

    fn changeAnimation(self: *AnimatedSprite2D, name: []const u8) void {
        setName(&self.animation, name);
        self.seen_animation = self.animation;
        self.frame_count = -1;
        self.check_name = true;
        self.told_animation = true;
    }

    /// On the last frame, at its end: now when its frames are counted, or
    /// at the next pass.
    fn toEnd(self: *AnimatedSprite2D) void {
        if (self.frame_count >= 0) return self.setFrameAndProgress(@max(self.frame_count - 1, 0), 1);
        self.to_end = true;
        self.setFrameAndProgress(self.frame, 1);
    }
};

// -------------------------------------------------------------------------
// The engine's passes
// -------------------------------------------------------------------------

const Signal = std.meta.FieldEnum(@TypeOf(AnimatedSprite2D.signals));

/// The signals of a pass, said after it: a signal's call may change the
/// world the pass walks.
const Said = struct {
    list: std.ArrayList(struct { entity: Entity, signal: Signal }) = .empty,

    fn add(self: *Said, gpa: Allocator, e: Entity, signal: Signal) Allocator.Error!void {
        try self.list.append(gpa, .{ .entity = e, .signal = signal });
    }

    fn deinit(self: *Said, gpa: Allocator) void {
        self.list.deinit(gpa);
    }

    fn emit(self: *const Said, app: *App) !void {
        for (self.list.items) |said| {
            const e = said.entity;
            switch (said.signal) {
                .animation_changed => try app.emit(e, AnimatedSprite2D, .animation_changed, .{}),
                .animation_finished => try app.emit(e, AnimatedSprite2D, .animation_finished, .{}),
                .animation_looped => try app.emit(e, AnimatedSprite2D, .animation_looped, .{}),
                .frame_changed => try app.emit(e, AnimatedSprite2D, .frame_changed, .{}),
                .sprite_frames_changed => try app.emit(e, AnimatedSprite2D, .sprite_frames_changed, .{}),
            }
        }
    }
};

/// Every animated sprite moved on by `delta` seconds, after what was written
/// to it is made what its setters make it, and its autoplay started the
/// first time time goes by. What `App.step` calls after the animation
/// players.
pub fn update(app: *App, delta: f32) !void {
    var said: Said = .{};
    defer said.deinit(app.gpa);
    const flowing = delta > 0;
    var it = ecs.Query(.{AnimatedSprite2D}).over(&app.world) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyComponents => return,
    };
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(AnimatedSprite2D)) |e, *sprite| {
            try notice(app, e, sprite, &said);
            if (!sprite.started and flowing) {
                sprite.started = true;
                const frames = app.sprite_frames.get(sprite.sprite_frames);
                const name = sprite.autoplayName();
                if (name.len > 0) if (frames) |held| if (held.hasAnimation(name)) {
                    // Its own copy: `play` writes the name it is given.
                    const autoplay = sprite.autoplay;
                    sprite.play(nameIn(&autoplay), 1, false);
                    try notice(app, e, sprite, &said);
                };
            }
            if (flowing and sprite.playing and app.isProcessing(e)) try advance(app, e, sprite, delta, &said);
        }
    }
    try said.emit(app);
}

/// Every animated sprite's frame put in the `Sprite` beside it, after what
/// was written to it since `update` is made what its setters make it. What
/// `App.step` calls before drawing, in an editor too.
pub fn show(app: *App) !void {
    var said: Said = .{};
    defer said.deinit(app.gpa);
    var it = ecs.Query(.{AnimatedSprite2D}).over(&app.world) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyComponents => return,
    };
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(AnimatedSprite2D)) |e, *sprite| {
            try notice(app, e, sprite, &said);
            if (app.world.get(e, Sprite)) |drawn| drawInto(app, sprite, drawn);
        }
    }
    try said.emit(app);
}

/// `sprite` moved on by `delta` seconds whether or not the game's time goes
/// by, its frames counted and nothing said: an editor playing it - in the
/// scene, or a copy of its own that is in no world - with the time of the
/// editor's frames.
pub fn preview(app: *App, sprite: *AnimatedSprite2D, delta: f32) !void {
    var said: Said = .{};
    defer said.deinit(app.gpa);
    fit(app, .none, sprite);
    if (sprite.playing and delta > 0) try advance(app, .none, sprite, delta, &said);
}

/// What was written to `sprite` since the last pass, made what its setters
/// would have made it, and what the setters left to the pass done: the name
/// fitted to the frames, the frames counted, the frame kept to them.
fn notice(app: *App, e: Entity, sprite: *AnimatedSprite2D, said: *Said) !void {
    if (!sprite.seen) {
        // As it was spawned or read: its name fitted to its frames, and
        // nothing said.
        sprite.seen = true;
        if (app.sprite_frames.get(sprite.sprite_frames)) |frames| {
            if (!frames.hasAnimation(sprite.animationName()) and frames.animations.items.len > 0) setName(&sprite.animation, frames.animations.items[0].name);
        }
        sprite.seen_frames = sprite.sprite_frames;
        sprite.seen_animation = sprite.animation;
        sprite.seen_frame = sprite.frame;
    } else {
        // Each put back as it was seen, and then written through its setter,
        // in the order a person would: the frames, the name, the frame.
        const frames = sprite.sprite_frames;
        const name = sprite.animation;
        const frame = sprite.frame;
        const new_frames = !frames.eql(sprite.seen_frames);
        const new_name = !std.mem.eql(u8, &name, &sprite.seen_animation);
        const new_frame = frame != sprite.seen_frame;
        sprite.sprite_frames = sprite.seen_frames;
        sprite.animation = sprite.seen_animation;
        sprite.frame = sprite.seen_frame;
        if (new_frames) sprite.setSpriteFrames(frames);
        if (new_name) sprite.setAnimation(nameIn(&name));
        if (new_frame) sprite.setFrame(frame);
    }
    fit(app, e, sprite);
    if (sprite.told_animation) try said.add(app.gpa, e, .animation_changed);
    if (sprite.told_frame) try said.add(app.gpa, e, .frame_changed);
    if (sprite.told_frames) try said.add(app.gpa, e, .sprite_frames_changed);
    sprite.told_animation = false;
    sprite.told_frame = false;
    sprite.told_frames = false;
}

/// The name fitted to the frames after a change to either, the frames
/// counted, and the frame kept to them.
fn fit(app: *App, e: Entity, sprite: *AnimatedSprite2D) void {
    const frames = app.sprite_frames.get(sprite.sprite_frames);
    if (sprite.check_frames) {
        sprite.check_frames = false;
        if (frames) |held| {
            // A name given after the frames is checked as a name is, below.
            if (!sprite.check_name and !held.hasAnimation(sprite.animationName())) {
                sprite.setAnimation(if (held.animations.items.len > 0) held.animations.items[0].name else "");
            }
            if (!held.hasAnimation(sprite.autoplayName())) sprite.autoplay = @splat(0);
        }
    }
    if (sprite.check_name) {
        sprite.check_name = false;
        const name = sprite.animationName();
        if (frames) |held| if (name.len > 0 and !held.hasAnimation(name)) {
            log.warn("{f}: {s} has no animation called {s}", .{ e, held.source, name });
            sprite.animation = @splat(0);
            sprite.seen_animation = sprite.animation;
        };
        const count = if (frames) |held| held.getFrameCount(sprite.animationName()) else 0;
        if (sprite.animationName().len == 0 or count == 0) sprite.stop();
    }
    const clip = if (frames) |held| held.find(sprite.animationName()) else null;
    const count: i32 = if (clip) |held| @intCast(held.frames.items.len) else -1;
    sprite.frame_count = count;
    if (count < 0) {
        sprite.to_end = false;
        return;
    }
    if (sprite.to_end) {
        sprite.to_end = false;
        sprite.setFrameAndProgress(count - 1, 1);
    }
    // Fewer frames than it was on: a change to the file.
    if (sprite.frame > @max(count - 1, 0)) sprite.setFrameAndProgress(count - 1, sprite.frame_progress);
    if (count == 0) sprite.playing = false;
}

/// `delta` seconds on, frame by frame: see the comment on the type.
fn advance(app: *App, e: Entity, sprite: *AnimatedSprite2D, delta: f32, said: *Said) !void {
    const frames = app.sprite_frames.get(sprite.sprite_frames) orelse return;
    const clip = frames.find(sprite.animationName()) orelse return;
    const count: i32 = @intCast(clip.frames.items.len);
    if (count == 0) return;
    const last = count - 1;
    defer sprite.seen_frame = sprite.frame;
    var remaining: f64 = delta;
    // However fast it goes, no more than a round of its frames a pass.
    var steps: i32 = 0;
    while (remaining > 0) : (steps += 1) {
        if (steps > count) return;
        const shown = clip.frames.items[@intCast(std.math.clamp(sprite.frame, 0, last))];
        const speed = @as(f64, clip.speed) * sprite.speed_scale * sprite.custom_speed / shown.length();
        if (speed == 0 or !std.math.isFinite(speed)) return;
        const pace = @abs(speed);
        if (!std.math.signbit(speed)) {
            if (sprite.frame_progress >= 1) {
                if (sprite.frame >= last) switch (clip.loop) {
                    .linear => {
                        sprite.frame = 0;
                        try said.add(app.gpa, e, .animation_looped);
                    },
                    .pingpong => {
                        // Turned round, to go back from the frame before.
                        sprite.custom_speed = -sprite.custom_speed;
                        sprite.frame_progress = 0;
                        try said.add(app.gpa, e, .animation_looped);
                        continue;
                    },
                    .none => {
                        sprite.frame = last;
                        sprite.pause();
                        try said.add(app.gpa, e, .animation_finished);
                        return;
                    },
                } else sprite.frame += 1;
                sprite.frame_progress = 0;
                try said.add(app.gpa, e, .frame_changed);
            }
            const taken = @min((1 - @as(f64, sprite.frame_progress)) / pace, remaining);
            sprite.frame_progress = @floatCast(sprite.frame_progress + taken * pace);
            remaining -= taken;
        } else {
            if (sprite.frame_progress <= 0) {
                if (sprite.frame <= 0) switch (clip.loop) {
                    .linear => {
                        sprite.frame = last;
                        try said.add(app.gpa, e, .animation_looped);
                    },
                    .pingpong => {
                        sprite.custom_speed = -sprite.custom_speed;
                        sprite.frame_progress = 1;
                        try said.add(app.gpa, e, .animation_looped);
                        continue;
                    },
                    .none => {
                        sprite.frame = 0;
                        sprite.pause();
                        try said.add(app.gpa, e, .animation_finished);
                        return;
                    },
                } else sprite.frame -= 1;
                sprite.frame_progress = 1;
                try said.add(app.gpa, e, .frame_changed);
            }
            const taken = @min(@as(f64, sprite.frame_progress) / pace, remaining);
            sprite.frame_progress = @floatCast(sprite.frame_progress - taken * pace);
            remaining -= taken;
        }
    }
}

/// The fields of the `Sprite` beside an `AnimatedSprite2D` that it writes
/// every frame, and not the Sprite's to say: an editor shows them as the
/// animated sprite's.
pub const driven_sprite_fields = [_][]const u8{ "texture", "region", "width", "height", "pivot_x", "pivot_y" };

/// The frame `sprite` is on, in `drawn`: nothing drawn when there is none.
pub fn drawInto(app: *App, sprite: *const AnimatedSprite2D, drawn: *Sprite) void {
    const frame = frameShown(app, sprite) orelse return hide(drawn);
    const shown = frame.shown(&app.assets) orelse return hide(drawn);
    drawn.texture = frame.texture;
    var region = shown.region;
    if (sprite.flip_h) region = region.flippedX();
    if (sprite.flip_v) region = region.flippedY();
    drawn.region = region;
    drawn.width = shown.width;
    drawn.height = shown.height;
    const middle: f32 = if (sprite.centered) 0.5 else 0;
    drawn.pivot_x = if (shown.width > 0) middle - sprite.offset.x / shown.width else middle;
    drawn.pivot_y = if (shown.height > 0) middle - sprite.offset.y / shown.height else middle;
}

/// A sprite of no size: no texture alone would be a white texel.
fn hide(drawn: *Sprite) void {
    drawn.texture = .none;
    drawn.region = .{ .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0 };
    drawn.width = 0;
    drawn.height = 0;
}

/// The frame it shows, if its frames have its animation and that the frame.
pub fn frameShown(app: *App, sprite: *const AnimatedSprite2D) ?Frame {
    const frames = app.sprite_frames.get(sprite.sprite_frames) orelse return null;
    const clip = frames.find(sprite.animationName()) orelse return null;
    if (sprite.frame < 0 or sprite.frame >= clip.frames.items.len) return null;
    return clip.frames.items[@intCast(sprite.frame)];
}
