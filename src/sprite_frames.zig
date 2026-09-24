// SPDX-License-Identifier: BSD-3-Clause

//! Sprite frames: named animations of pictures - cells of a sheet, or
//! pieces of textures - kept in a `.frames` file, which an `AnimatedSprite`
//! shows one after another in its entity's `Sprite`.
//!
//! ```json
//! { "fluxion_frames": 1, "texture": "res://art/hero.png", "grid": [4, 2],
//!   "animations": [
//!     { "name": "walk", "fps": 8, "frames": [0, 1, 2, 3] },
//!     { "name": "hit", "fps": 12, "loop": false,
//!       "frames": [4, { "cell": 5, "duration": 2 }, { "region": [0, 0.5, 0.25, 1], "texture": "res://art/spark.png" }] } ] }
//! ```
//!
//! ```zig
//! const hero = try app.loadSpriteFrames("res://art/hero.frames");
//! _ = try app.world.spawnWith(.{ fx.Transform2D.at(0, 0), fx.Sprite{ .width = 32, .height = 32 }, fx.AnimatedSprite.of(hero, "walk") });
//! ```
//!
//! **A frame** is a cell of the file's `grid` over its `texture`, counted
//! across and then down, or a `region` of it or of a texture of its own, and
//! shows for `duration` frames of the animation's `fps` - one by default.
//! An animation loops unless it says `"loop": false`, and then stops on its
//! last frame and says `animation_finished`.
//!
//! **Stepped by the engine** once a frame before drawing, while the
//! entity runs; `play(name)` and `stop()` ask for another animation or none.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const id = @import("fluxion_id");
const json = @import("fluxion_json");

const App = @import("App.zig");
const Assets = @import("assets.zig");
const Project = @import("Project.zig");
const attr = @import("attr.zig");
const components = @import("components.zig");
const file_table = @import("file_table.zig");

const Entity = ecs.Entity;
const Region = components.Region;
const TextureHandle = Assets.TextureHandle;
const log = std.log.scoped(.fluxion_engine);

pub const SpriteFramesHandle = file_table.Handle("SpriteFramesHandle");

pub const extension = ".frames";
pub const header = "fluxion_frames";
pub const version = 1;

pub const Frame = struct {
    texture: TextureHandle = .none,
    region: Region = .{},
    /// The cell of the grid it is, when it is one: what it is written as.
    cell: ?u32 = null,
    /// How long it shows, in frames of the animation's rate.
    duration: f32 = 1,
};

pub const Clip = struct {
    name: []u8,
    /// Frames a second.
    fps: f32 = 12,
    loop: bool = true,
    frames: std.ArrayList(Frame) = .empty,

    /// How long it takes to play through, in seconds.
    pub fn seconds(self: *const Clip) f32 {
        if (!(self.fps > 0)) return 0;
        var total: f32 = 0;
        for (self.frames.items) |frame| total += @max(frame.duration, 0);
        return total / self.fps;
    }

    /// Which frame shows `time` seconds in, counted from the start.
    pub fn frameAt(self: *const Clip, time: f32) usize {
        if (self.frames.items.len == 0 or !(self.fps > 0)) return 0;
        var reached: f32 = 0;
        for (self.frames.items, 0..) |frame, at| {
            reached += @max(frame.duration, 0) / self.fps;
            if (time < reached) return at;
        }
        return self.frames.items.len - 1;
    }

    fn deinit(self: *Clip, gpa: Allocator) void {
        gpa.free(self.name);
        self.frames.deinit(gpa);
    }
};

/// A `.frames` file, as read.
pub const SpriteFrames = struct {
    source: []u8,
    on_disc: bool,
    /// The texture a frame with none of its own is from, and the grid its
    /// cells are counted on.
    texture: TextureHandle = .none,
    columns: u16 = 1,
    rows: u16 = 1,
    animations: std.ArrayList(Clip) = .empty,
    revision: u32 = 0,

    /// The animation called `name`, or with an empty name the first.
    pub fn find(self: *const SpriteFrames, name: []const u8) ?*const Clip {
        if (name.len == 0) return if (self.animations.items.len > 0) &self.animations.items[0] else null;
        for (self.animations.items) |*clip| {
            if (std.mem.eql(u8, clip.name, name)) return clip;
        }
        return null;
    }

    /// The cell `index` of the grid, as a frame.
    pub fn cellFrame(self: *const SpriteFrames, index: u32) Frame {
        return .{ .texture = self.texture, .region = .cell(index, @max(self.columns, 1), @max(self.rows, 1)), .cell = index };
    }

    pub fn touched(self: *SpriteFrames) void {
        self.revision +%= 1;
    }

    pub fn indexOf(self: *const SpriteFrames, name: []const u8) ?usize {
        for (self.animations.items, 0..) |clip, at| {
            if (std.mem.eql(u8, clip.name, name)) return at;
        }
        return null;
    }

    /// A new animation with no frames, after the others. The caller gives it
    /// a name none of them has.
    pub fn addClip(self: *SpriteFrames, gpa: Allocator, name: []const u8) Allocator.Error!*Clip {
        const made: Clip = .{ .name = try gpa.dupe(u8, name) };
        self.animations.append(gpa, made) catch |err| {
            gpa.free(made.name);
            return err;
        };
        return &self.animations.items[self.animations.items.len - 1];
    }

    pub fn removeClip(self: *SpriteFrames, gpa: Allocator, at: usize) void {
        var gone = self.animations.orderedRemove(at);
        gone.deinit(gpa);
    }

    pub fn renameClip(self: *SpriteFrames, gpa: Allocator, at: usize, name: []const u8) Allocator.Error!void {
        const held = &self.animations.items[at];
        const copy = try gpa.dupe(u8, name);
        gpa.free(held.name);
        held.name = copy;
    }

    /// Another sheet: the frames of the old one are of the new one.
    pub fn setTexture(self: *SpriteFrames, texture: TextureHandle) void {
        for (self.animations.items) |*clip| for (clip.frames.items) |*frame| {
            if (frame.texture.eql(self.texture)) frame.texture = texture;
        };
        self.texture = texture;
    }

    /// Another grid over the sheet: every frame that is a cell of it is cut
    /// again where its cell now is.
    pub fn setGrid(self: *SpriteFrames, columns: u16, rows: u16) void {
        self.columns = @max(columns, 1);
        self.rows = @max(rows, 1);
        for (self.animations.items) |*clip| for (clip.frames.items) |*frame| {
            const cell = frame.cell orelse continue;
            if (!frame.texture.eql(self.texture)) continue;
            frame.region = .cell(cell, self.columns, self.rows);
        };
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
    if (root.get("texture").asString()) |path| into.texture = textureAt(app, into.source, path);
    const grid = root.get("grid");
    into.columns = @intCast(std.math.clamp(grid.get(0).asInt(i64) orelse 1, 1, 4096));
    into.rows = @intCast(std.math.clamp(grid.get(1).asInt(i64) orelse 1, 1, 4096));
    for (root.get("animations").items()) |given| {
        const name = given.get("name").asString() orelse continue;
        var clip: Clip = .{ .name = try gpa.dupe(u8, name) };
        errdefer clip.deinit(gpa);
        clip.fps = @floatCast(given.get("fps").asFloat(f64) orelse 12);
        clip.loop = given.get("loop").asBool() orelse true;
        for (given.get("frames").items()) |frame_json| {
            if (frame_json.asInt(i64)) |cell| {
                try clip.frames.append(gpa, into.cellFrame(@intCast(@max(cell, 0))));
                continue;
            }
            if (frame_json.asObject() == null) continue;
            var frame: Frame = if (frame_json.get("cell").asInt(i64)) |cell| into.cellFrame(@intCast(@max(cell, 0))) else .{ .texture = into.texture };
            const region = frame_json.get("region");
            if (region.len() == 4) {
                frame.region = .{
                    .u0 = @floatCast(region.get(0).asFloat(f64) orelse 0),
                    .v0 = @floatCast(region.get(1).asFloat(f64) orelse 0),
                    .u1 = @floatCast(region.get(2).asFloat(f64) orelse 1),
                    .v1 = @floatCast(region.get(3).asFloat(f64) orelse 1),
                };
                frame.cell = null;
            }
            if (frame_json.get("texture").asString()) |path| {
                frame.texture = textureAt(app, into.source, path);
                frame.cell = null;
            }
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
        const held = self.frames;
        try w.beginObject();
        try w.field(header, @as(u32, version));
        if (self.assets.textureSource(held.texture)) |path| try w.field("texture", path);
        if (held.columns != 1 or held.rows != 1) try w.field("grid", [2]u16{ held.columns, held.rows });
        try w.key("animations");
        try w.beginArray();
        for (held.animations.items) |*clip| {
            try w.beginObject();
            try w.field("name", clip.name);
            try w.field("fps", clip.fps);
            if (!clip.loop) try w.field("loop", false);
            try w.key("frames");
            try w.beginArray();
            for (clip.frames.items) |frame| {
                const own_texture = !frame.texture.eql(held.texture);
                if (frame.cell) |cell| if (!own_texture and frame.duration == 1) {
                    try w.write(cell);
                    continue;
                };
                try w.beginObject();
                if (frame.cell) |cell| {
                    try w.field("cell", cell);
                } else try w.field("region", [4]f32{ frame.region.u0, frame.region.v0, frame.region.u1, frame.region.v1 });
                if (own_texture) if (self.assets.textureSource(frame.texture)) |path| try w.field("texture", path);
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

/// A grid animation made in code: `AllFrames.addGrid`.
pub const GridClip = struct {
    name: []const u8,
    cells: []const u32,
    fps: f32 = 12,
    loop: bool = true,
};

/// Every `.frames` file read, and the handles they are found by.
pub const AllFrames = struct {
    table: Table = .empty,

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

    /// Sprite frames made in code: `clips` over a `columns` by `rows` grid of
    /// `texture`, found by `name`.
    pub fn addGrid(self: *AllFrames, app: *App, name: []const u8, texture: TextureHandle, columns: u16, rows: u16, clips: []const GridClip) !SpriteFramesHandle {
        const gpa = app.gpa;
        const source = try gpa.dupe(u8, name);
        errdefer gpa.free(source);
        var made: SpriteFrames = .{ .source = source, .on_disc = false, .texture = texture, .columns = @max(columns, 1), .rows = @max(rows, 1) };
        errdefer made.deinitContent(gpa);
        for (clips) |given| {
            var clip: Clip = .{ .name = try gpa.dupe(u8, given.name), .fps = given.fps, .loop = given.loop };
            errdefer clip.deinit(gpa);
            for (given.cells) |cell| try clip.frames.append(gpa, made.cellFrame(cell));
            try made.animations.append(gpa, clip);
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
        const io = app.io orelse return error.NoIo;
        const held = self.table.get(toId(handle)) orelse return error.NoSuchFrames;
        if (!held.on_disc) return error.NotAFile;
        const file = try app.project.osPath(app.gpa, held.source);
        defer app.gpa.free(file);
        try json.save(io, file, Document{ .frames = held, .assets = &app.assets }, write_options);
        if (Project.isProjectPath(held.source)) _ = try app.project.ensureUid(held.source);
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

// -------------------------------------------------------------------------
// The component
// -------------------------------------------------------------------------

pub const name_len = 32;

/// Shows the frames of an animation one after another in its entity's
/// `Sprite`. See the top of this file.
pub const AnimatedSprite = extern struct {
    frames: SpriteFramesHandle = .none,
    /// Which animation: empty for the first.
    animation: [name_len]u8 = @splat(0),
    playing: bool = true,
    /// Faster above 1, slower below.
    speed: f32 = 1,
    /// Seconds into the animation.
    time: f32 = 0,
    /// The frame showing.
    frame: u16 = 0,

    pub const signals = .{ .animation_finished = struct {} };

    pub const reflect_name = "AnimatedSprite";
    pub const reflect_fields = .{
        .animation = .{attr.Doc{ .text = "Which animation; empty for the first" }},
        .speed = .{attr.Doc{ .text = "Faster above 1, slower below" }},
        .time = .{ attr.Unit{ .text = "s" }, attr.Doc{ .text = "Into the animation" } },
        .frame = .{attr.ReadOnly{}},
    };
    pub const reflect_methods = .{ .play, .stop, .animationName };

    pub fn of(frames: SpriteFramesHandle, name: []const u8) AnimatedSprite {
        var made: AnimatedSprite = .{ .frames = frames };
        made.setAnimation(name);
        return made;
    }

    /// Show `name` from its first frame.
    pub fn play(self: *AnimatedSprite, name: []const u8) void {
        self.setAnimation(name);
        self.time = 0;
        self.playing = true;
    }

    /// Hold the frame showing.
    pub fn stop(self: *AnimatedSprite) void {
        self.playing = false;
    }

    pub fn animationName(self: *const AnimatedSprite) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.animation, 0) orelse self.animation.len;
        return self.animation[0..end];
    }

    fn setAnimation(self: *AnimatedSprite, name: []const u8) void {
        self.animation = @splat(0);
        const kept = @min(name.len, name_len);
        @memcpy(self.animation[0..kept], name[0..kept]);
    }
};

/// Every animated sprite moved on by `delta` seconds and its frame put in
/// its sprite. What `App.step` calls.
pub fn animate(app: *App, delta: f32) !void {
    var ended: std.ArrayList(Entity) = .empty;
    defer ended.deinit(app.gpa);
    var it = ecs.Query(.{ components.Sprite, AnimatedSprite }).over(&app.world) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyComponents => return,
    };
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(components.Sprite), chunk.slice(AnimatedSprite)) |e, *drawn, *animated| {
            const frames = app.sprite_frames.get(animated.frames) orelse continue;
            const clip = frames.find(animated.animationName()) orelse continue;
            // One that does not run now keeps its frame.
            if (animated.playing and app.isProcessing(e)) {
                animated.time += delta * animated.speed;
                const length = clip.seconds();
                if (!std.math.isFinite(animated.time) or !(length > 0)) {
                    animated.time = 0;
                } else if (clip.loop) {
                    animated.time = @mod(animated.time, length);
                } else if (animated.time >= length) {
                    animated.time = length;
                    animated.playing = false;
                    try ended.append(app.gpa, e);
                }
            }
            if (clip.frames.items.len == 0) continue;
            const at = clip.frameAt(animated.time);
            animated.frame = @intCast(@min(at, std.math.maxInt(u16)));
            const shown = clip.frames.items[at];
            if (!shown.texture.isNone()) drawn.texture = shown.texture;
            drawn.region = shown.region;
        }
    }
    for (ended.items) |e| try app.emit(e, AnimatedSprite, .animation_finished, .{});
}

test "a clip's frame is found by its time, each frame as long as it says" {
    var clip: Clip = .{ .name = @constCast("walk"), .fps = 10 };
    defer clip.frames.deinit(testing.allocator);
    try clip.frames.appendSlice(testing.allocator, &.{ .{}, .{ .duration = 2 }, .{} });
    try testing.expectApproxEqAbs(@as(f32, 0.4), clip.seconds(), 1e-6);
    try testing.expectEqual(@as(usize, 0), clip.frameAt(0.05));
    try testing.expectEqual(@as(usize, 1), clip.frameAt(0.25));
    try testing.expectEqual(@as(usize, 2), clip.frameAt(0.35));
    try testing.expectEqual(@as(usize, 2), clip.frameAt(9));
}
