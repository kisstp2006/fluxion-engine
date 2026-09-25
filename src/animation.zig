// SPDX-License-Identifier: BSD-3-Clause

//! Animations: named sets of tracks kept in a `.anim` file - an animation
//! library - which an `AnimationPlayer` plays on its entity and the ones
//! under it.
//!
//! ```json
//! { "fluxion_animation": 1,
//!   "animations": [
//!     { "name": "open", "length": 0.3,
//!       "tracks": [
//!         { "target": "Panel", "property": "Appearance.modulate.a",
//!           "keys": [ { "time": 0, "value": 0 }, { "time": 0.3, "value": 1, "ease": "quad_out" } ] },
//!         { "target": "Panel", "property": "Control.offset_left,offset_top",
//!           "keys": [ { "time": 0, "value": [-400, 0] }, { "time": 0.3, "value": [0, 0] } ] } ] } ] }
//! ```
//!
//! ```zig
//! const menu = try app.loadAnimations("res://ui/menu.anim");
//! const ui = try app.world.spawnWith(.{ fx.AnimationPlayer{ .library = menu } });
//! app.world.get(ui, fx.AnimationPlayer).?.play("open");
//! ```
//!
//! **An animation** has a length in seconds and loops or not - round again,
//! or back and forth. **A track** moves one property - see `property.zig` -
//! of one entity: the player's own with an empty `target`, or one under it by
//! name or by path, `Panel/Title`. It goes from key to key, each key saying
//! the curve it is got to by, or with `"update": "discrete"` jumps to each
//! key's value as it comes. A key's value is a number, `[x, y]`, a colour as
//! `[r, g, b, a]` or `"#rrggbbaa"`, or true or false.
//!
//! **The player** is data, as an `AudioPlayer` is: `play`, `stop`, `seek`
//! and `queue` ask the engine's pass, once a frame before the `.update`
//! systems while its entity runs, and `current`, `playing` and `position`
//! say what it found. `animation_started` and `animation_finished` say so
//! with the animation's name. A frame with no time moves nothing: an editor
//! poses a scene with `pose` instead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const id = @import("fluxion_id");
const json = @import("fluxion_json");
const math = @import("fluxion_math");

const App = @import("App.zig");
const Project = @import("Project.zig");
const attr = @import("attr.zig");
const file_table = @import("file_table.zig");
const property_mod = @import("property.zig");
const Color = @import("color.zig").Color;

const Entity = ecs.Entity;
const Property = property_mod.Property;
const Value = property_mod.Value;
const log = std.log.scoped(.fluxion_engine);

/// An animation library read: see `Libraries`.
pub const AnimationLibraryHandle = file_table.Handle("AnimationLibraryHandle");

pub const extension = ".anim";
pub const header = "fluxion_animation";
pub const version = 1;

pub const Loop = enum { none, repeat, ping_pong };
pub const Update = enum { continuous, discrete };

/// Two keys closer together than this are at one time.
pub const same_time = 0.0005;

pub const Key = struct {
    time: f32,
    value: Value,
    /// How the track gets to this key from the one before it.
    ease: math.ease.Kind = .linear,
};

pub const Track = struct {
    /// The entity it moves, from the player's: empty for its own, a name, or
    /// a path, `Panel/Title`.
    target: []u8,
    property: []u8,
    update: Update = .continuous,
    /// In the order of their times.
    keys: std.ArrayList(Key) = .empty,

    /// What the track says at `time`: the first key's value before it, the
    /// last's after it, and between two, the way to the later one - or with
    /// `discrete`, the earlier one's. Null with no keys.
    pub fn sample(self: *const Track, time: f32) ?Value {
        const keys = self.keys.items;
        if (keys.len == 0) return null;
        if (time <= keys[0].time) return keys[0].value;
        for (keys[1..], 1..) |key, at| {
            if (time >= key.time) continue;
            const before = keys[at - 1];
            if (self.update == .discrete) return before.value;
            const span = key.time - before.time;
            const t: f32 = if (span > 0) (time - before.time) / span else 1;
            return before.value.lerp(key.value, key.ease.apply(t));
        }
        return keys[keys.len - 1].value;
    }

    /// Put `key` in its place among the others, or in place of the one
    /// already at its time, which keeps its time. Where it went.
    pub fn setKey(self: *Track, gpa: Allocator, key: Key) Allocator.Error!usize {
        for (self.keys.items, 0..) |*held, at| {
            if (@abs(held.time - key.time) < same_time) {
                held.* = .{ .time = held.time, .value = key.value, .ease = key.ease };
                return at;
            }
            if (held.time > key.time) {
                try self.keys.insert(gpa, at, key);
                return at;
            }
        }
        try self.keys.append(gpa, key);
        return self.keys.items.len - 1;
    }

    /// The key at `time`, if there is one.
    pub fn keyAt(self: *const Track, time: f32) ?usize {
        for (self.keys.items, 0..) |held, at| {
            if (@abs(held.time - time) < same_time) return at;
        }
        return null;
    }

    /// Keep the keys in the order of their times: after a key has moved.
    pub fn sortKeys(self: *Track) void {
        std.mem.sort(Key, self.keys.items, {}, struct {
            fn earlier(_: void, a: Key, b: Key) bool {
                return a.time < b.time;
            }
        }.earlier);
    }

    fn deinit(self: *Track, gpa: Allocator) void {
        gpa.free(self.target);
        gpa.free(self.property);
        self.keys.deinit(gpa);
    }
};

pub const Animation = struct {
    name: []u8,
    /// Seconds.
    length: f32 = 1,
    loop: Loop = .none,
    tracks: std.ArrayList(Track) = .empty,

    fn deinit(self: *Animation, gpa: Allocator) void {
        gpa.free(self.name);
        for (self.tracks.items) |*track| track.deinit(gpa);
        self.tracks.deinit(gpa);
    }

    /// The track of `target`'s `property`, if there is one.
    pub fn trackOf(self: *Animation, target: []const u8, property: []const u8) ?*Track {
        for (self.tracks.items) |*track| {
            if (std.mem.eql(u8, track.target, target) and std.mem.eql(u8, track.property, property)) return track;
        }
        return null;
    }

    /// The track of `target`'s `property`, made with no keys if there is
    /// none yet.
    pub fn ensureTrack(self: *Animation, gpa: Allocator, target: []const u8, property: []const u8) Allocator.Error!*Track {
        if (self.trackOf(target, property)) |found| return found;
        var made: Track = .{ .target = try gpa.dupe(u8, target), .property = &.{} };
        errdefer made.deinit(gpa);
        made.property = try gpa.dupe(u8, property);
        try self.tracks.append(gpa, made);
        return &self.tracks.items[self.tracks.items.len - 1];
    }

    pub fn removeTrack(self: *Animation, gpa: Allocator, at: usize) void {
        var gone = self.tracks.orderedRemove(at);
        gone.deinit(gpa);
    }
};

/// A `.anim` file, as read.
pub const Library = struct {
    source: []u8,
    on_disc: bool,
    animations: std.ArrayList(Animation) = .empty,
    /// Moved on by every change, so a player playing it binds its tracks
    /// again.
    revision: u32 = 0,

    pub fn find(self: *const Library, name: []const u8) ?*const Animation {
        for (self.animations.items) |*held| {
            if (std.mem.eql(u8, held.name, name)) return held;
        }
        return null;
    }

    /// A change is done: players bind the tracks again.
    pub fn touched(self: *Library) void {
        self.revision +%= 1;
    }

    /// Its place among the animations.
    pub fn indexOf(self: *const Library, name: []const u8) ?usize {
        for (self.animations.items, 0..) |held, at| {
            if (std.mem.eql(u8, held.name, name)) return at;
        }
        return null;
    }

    /// A new animation with no tracks, after the others. The caller gives it
    /// a name none of them has.
    pub fn addAnimation(self: *Library, gpa: Allocator, name: []const u8) Allocator.Error!*Animation {
        const made: Animation = .{ .name = try gpa.dupe(u8, name) };
        self.animations.append(gpa, made) catch |err| {
            gpa.free(made.name);
            return err;
        };
        return &self.animations.items[self.animations.items.len - 1];
    }

    pub fn removeAnimation(self: *Library, gpa: Allocator, at: usize) void {
        var gone = self.animations.orderedRemove(at);
        gone.deinit(gpa);
    }

    pub fn renameAnimation(self: *Library, gpa: Allocator, at: usize, name: []const u8) Allocator.Error!void {
        const held = &self.animations.items[at];
        const copy = try gpa.dupe(u8, name);
        gpa.free(held.name);
        held.name = copy;
    }

    fn deinitContent(self: *Library, gpa: Allocator) void {
        for (self.animations.items) |*held| held.deinit(gpa);
        self.animations.deinit(gpa);
    }
};

const Table = id.handle.Table(Library);

fn toId(handle: AnimationLibraryHandle) Table.Handle {
    return @bitCast(handle);
}

fn fromId(handle: Table.Handle) AnimationLibraryHandle {
    return @bitCast(handle);
}

// -------------------------------------------------------------------------
// Reading and writing
// -------------------------------------------------------------------------

pub const ReadError = error{ NotAnimations, NewerVersion, Malformed } || json.Error;

/// The animations `text` says, into `into`. What makes no sense in it is
/// said in the log and left out.
pub fn read(gpa: Allocator, into: *Library, text: []const u8) ReadError!void {
    var doc = try json.parse(gpa, text, .{});
    defer doc.deinit();
    const root = doc.root;
    if (root.asObject() == null or !root.has(header)) return error.NotAnimations;
    if ((root.get(header).asInt(i64) orelse return error.Malformed) > version) return error.NewerVersion;
    for (root.get("animations").items()) |given| {
        const name = given.get("name").asString() orelse continue;
        var made: Animation = .{ .name = try gpa.dupe(u8, name) };
        errdefer made.deinit(gpa);
        made.length = @floatCast(@max(given.get("length").asFloat(f64) orelse 1, 0));
        if (given.get("loop").asString()) |text_loop| made.loop = std.meta.stringToEnum(Loop, text_loop) orelse .none;
        for (given.get("tracks").items()) |track_json| {
            const prop = track_json.get("property").asString() orelse continue;
            var track: Track = .{
                .target = try gpa.dupe(u8, track_json.get("target").asString() orelse ""),
                .property = try gpa.dupe(u8, prop),
            };
            errdefer track.deinit(gpa);
            if (track_json.get("update").asString()) |text_update| track.update = std.meta.stringToEnum(Update, text_update) orelse .continuous;
            for (track_json.get("keys").items()) |key_json| {
                const value = valueOf(key_json.get("value")) orelse {
                    log.warn("{s}: a key of {s}'s {s} has no value that moves", .{ into.source, made.name, prop });
                    continue;
                };
                var key: Key = .{ .time = @floatCast(key_json.get("time").asFloat(f64) orelse 0), .value = value };
                if (key_json.get("ease").asString()) |text_ease| key.ease = std.meta.stringToEnum(math.ease.Kind, text_ease) orelse .linear;
                try track.keys.append(gpa, key);
            }
            track.sortKeys();
            try made.tracks.append(gpa, track);
        }
        try into.animations.append(gpa, made);
    }
}

/// A key's value as a file writes it. A string is a colour when it reads
/// as one, `"#ff8800"`, and a name otherwise.
pub fn valueOf(given: json.Value) ?Value {
    switch (given) {
        .int => |n| return .{ .number = @floatFromInt(n) },
        .float => |f| return .{ .number = f },
        .bool => |b| return .{ .flag = b },
        .string => |text| {
            const c = Color.parse(text) orelse return .nameOf(text);
            return .{ .color = .{ c.r, c.g, c.b, c.a } };
        },
        .array => {
            const items = given.items();
            var numbers: [4]f32 = undefined;
            if (items.len != 2 and items.len != 4) return null;
            for (items, 0..) |item, at| numbers[at] = @floatCast(item.asFloat(f64) orelse return null);
            if (items.len == 2) return .{ .vec2 = .{ numbers[0], numbers[1] } };
            return .{ .color = numbers };
        },
        else => return null,
    }
}

fn writeValue(w: *json.Writer, value: Value) json.Writer.Error!void {
    switch (value) {
        .number => |n| try w.write(n),
        .flag => |on| try w.write(on),
        .vec2 => |xy| try w.write(xy),
        .color => |rgba| try w.write(rgba),
        .name => try w.write(value.text()),
    }
}

const write_options: json.WriteOptions = .{ .indent = 2 };

/// A library as its file, for `json.save` and `json.stringify`.
const Document = struct {
    library: *const Library,

    pub fn toJson(self: Document, w: *json.Writer) json.Writer.Error!void {
        try w.beginObject();
        try w.field(header, @as(u32, version));
        try w.key("animations");
        try w.beginArray();
        for (self.library.animations.items) |*held| {
            try w.beginObject();
            try w.field("name", held.name);
            try w.field("length", held.length);
            if (held.loop != .none) try w.field("loop", @tagName(held.loop));
            try w.key("tracks");
            try w.beginArray();
            for (held.tracks.items) |*track| {
                try w.beginObject();
                try w.field("target", track.target);
                try w.field("property", track.property);
                if (track.update != .continuous) try w.field("update", @tagName(track.update));
                try w.key("keys");
                try w.beginArray();
                for (track.keys.items) |key| {
                    try w.beginObject();
                    try w.field("time", key.time);
                    try w.key("value");
                    try writeValue(w, key.value);
                    if (key.ease != .linear) try w.field("ease", @tagName(key.ease));
                    try w.endObject();
                }
                try w.endArray();
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

/// Every animation library read, and the handles they are found by.
pub const Libraries = struct {
    table: Table = .empty,

    pub fn deinit(self: *Libraries, gpa: Allocator) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            entry.value.deinitContent(gpa);
            gpa.free(entry.value.source);
        }
        self.table.deinit(gpa);
    }

    /// Read a `.anim` file, or find the one read from there already. One
    /// that reads and makes no sense is kept empty, and why is said.
    pub fn load(self: *Libraries, app: *App, path: []const u8) !AnimationLibraryHandle {
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
        return self.keep(app.gpa, source, text, true);
    }

    /// A library from text rather than a file: a test's, or a tool's. A
    /// name given before gets the new text.
    pub fn add(self: *Libraries, gpa: Allocator, name: []const u8, text: []const u8) !AnimationLibraryHandle {
        if (self.find(name)) |known| {
            try self.setText(gpa, known, text);
            return known;
        }
        return self.keep(gpa, name, text, false);
    }

    fn keep(self: *Libraries, gpa: Allocator, source: []const u8, text: []const u8, on_disc: bool) !AnimationLibraryHandle {
        const name = try gpa.dupe(u8, source);
        errdefer gpa.free(name);
        var made: Library = .{ .source = name, .on_disc = on_disc };
        read(gpa, &made, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => log.warn("{s} does not read as animations: {t}", .{ source, err }),
        };
        errdefer made.deinitContent(gpa);
        return fromId(try self.table.add(gpa, made));
    }

    /// New text for a library: an editor's, as it undoes. Text that does not
    /// read leaves what it said before.
    pub fn setText(self: *Libraries, gpa: Allocator, handle: AnimationLibraryHandle, text: []const u8) !void {
        const held = self.table.get(toId(handle)) orelse return error.NoSuchAnimations;
        var fresh: Library = .{ .source = held.source, .on_disc = held.on_disc, .revision = held.revision +% 1 };
        read(gpa, &fresh, text) catch |err| {
            fresh.deinitContent(gpa);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => log.warn("{s} does not read as animations: {t}", .{ held.source, err }),
            };
        };
        held.deinitContent(gpa);
        held.* = fresh;
    }

    /// Read a library's file again. Says whether there was a file to read.
    pub fn reload(self: *Libraries, app: *App, handle: AnimationLibraryHandle) !bool {
        const held = self.table.get(toId(handle)) orelse return false;
        if (!held.on_disc) return false;
        const io = app.io orelse return error.NoIo;
        const file = try app.project.osPath(app.gpa, held.source);
        defer app.gpa.free(file);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, file, app.gpa, .limited(file_table.file_limit));
        defer app.gpa.free(text);
        try self.setText(app.gpa, handle, text);
        return true;
    }

    pub fn find(self: *Libraries, source: []const u8) ?AnimationLibraryHandle {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value.source, source)) return fromId(entry.handle);
        }
        return null;
    }

    pub fn get(self: *Libraries, handle: AnimationLibraryHandle) ?*const Library {
        return self.table.get(toId(handle));
    }

    /// A library to change, for an editor, which calls `Library.touched`
    /// when it is done.
    pub fn edit(self: *Libraries, handle: AnimationLibraryHandle) ?*Library {
        return self.table.get(toId(handle));
    }

    /// The library as its file would be, into fresh memory: what an editor
    /// saves and keeps to undo by. The caller frees it.
    pub fn textOf(self: *Libraries, gpa: Allocator, handle: AnimationLibraryHandle) ![]u8 {
        const held = self.table.get(toId(handle)) orelse return error.NoSuchAnimations;
        return json.stringify(gpa, Document{ .library = held }, write_options);
    }

    /// Write a library back to its file, and give it a UUID if it has none.
    pub fn save(self: *Libraries, app: *App, handle: AnimationLibraryHandle) !void {
        const io = app.io orelse return error.NoIo;
        const held = self.table.get(toId(handle)) orelse return error.NoSuchAnimations;
        if (!held.on_disc) return error.NotAFile;
        const file = try app.project.osPath(app.gpa, held.source);
        defer app.gpa.free(file);
        try json.save(io, file, Document{ .library = held }, write_options);
        if (Project.isProjectPath(held.source)) _ = try app.project.ensureUid(held.source);
    }

    pub fn sourceOf(self: *Libraries, handle: AnimationLibraryHandle) ?[]const u8 {
        const held = self.table.get(toId(handle)) orelse return null;
        return held.source;
    }

    pub fn renamed(self: *Libraries, gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!void {
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
// The player
// -------------------------------------------------------------------------

/// How long an animation's name may be, in a player.
pub const name_len = 32;

fn nameIn(buffer: *const [name_len]u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return buffer[0..end];
}

fn setName(buffer: *[name_len]u8, name: []const u8) void {
    buffer.* = @splat(0);
    const kept = @min(name.len, name_len);
    @memcpy(buffer[0..kept], name[0..kept]);
}

/// Plays the animations of a library on its entity and the ones under it.
/// See the top of this file.
pub const AnimationPlayer = extern struct {
    library: AnimationLibraryHandle = .none,
    /// The animation it starts with the first time the game runs its entity;
    /// empty for none.
    autoplay: [name_len]u8 = @splat(0),
    /// Faster above 1, slower below.
    speed: f32 = 1,
    /// Held where it is while on.
    paused: bool = false,
    /// The animation it plays, or played last.
    current: [name_len]u8 = @splat(0),
    playing: bool = false,
    /// Seconds into `current`.
    position: f32 = 0,
    /// What `play`, `stop`, `seek` and `queue` asked the engine's pass for.
    request: Request = .none,
    wanted: [name_len]u8 = @splat(0),
    from: f32 = 0,
    /// Played after `current` finishes: `queue`.
    next: [name_len]u8 = @splat(0),
    /// Whether the pass has looked at it yet, and so at `autoplay`.
    started: bool = false,

    pub const Request = enum(u8) { none, play, stop, seek };

    pub const signals = .{
        .animation_started = struct { name: []const u8 },
        .animation_finished = struct { name: []const u8 },
    };

    pub const reflect_name = "AnimationPlayer";
    pub const reflect_fields = .{
        .autoplay = .{attr.Doc{ .text = "Starts by itself when the game first runs its entity; empty for none" }},
        .speed = .{attr.Doc{ .text = "Faster above 1, slower below" }},
        .paused = .{attr.Doc{ .text = "Held where it is" }},
        .current = .{attr.ReadOnly{}},
        .playing = .{attr.ReadOnly{}},
        .position = .{ attr.ReadOnly{}, attr.Unit{ .text = "s" } },
        .request = .{attr.Hidden{}},
        .wanted = .{attr.Hidden{}},
        .from = .{attr.Hidden{}},
        .next = .{attr.Hidden{}},
        .started = .{attr.Hidden{}},
    };
    pub const reflect_methods = .{ .play, .stop, .seek, .queue, .currentName };

    /// Play `name` from its start, at the next pass.
    pub fn play(self: *AnimationPlayer, name: []const u8) void {
        self.request = .play;
        setName(&self.wanted, name);
        self.from = 0;
        self.playing = true;
    }

    /// Stop, back at the start, saying nothing.
    pub fn stop(self: *AnimationPlayer) void {
        self.request = .stop;
        self.playing = false;
    }

    /// To `to` seconds into what it plays, posed there at the next pass
    /// whether it plays or not.
    pub fn seek(self: *AnimationPlayer, to: f32) void {
        if (self.request == .play) {
            self.from = @max(to, 0);
            return;
        }
        self.request = .seek;
        self.from = @max(to, 0);
    }

    /// Play `name` once what it plays has finished - at once when it plays
    /// nothing.
    pub fn queue(self: *AnimationPlayer, name: []const u8) void {
        if (!self.playing and self.request != .play) return self.play(name);
        setName(&self.next, name);
    }

    pub fn currentName(self: *const AnimationPlayer) []const u8 {
        return nameIn(&self.current);
    }

    pub fn autoplayName(self: *const AnimationPlayer) []const u8 {
        return nameIn(&self.autoplay);
    }

    pub fn setAutoplay(self: *AnimationPlayer, name: []const u8) void {
        setName(&self.autoplay, name);
    }
};

/// A track bound to the entity and the property it moves.
const Bound = struct {
    track: usize,
    entity: Entity,
    property: Property,
};

/// What each player's tracks are bound to, for the library's revision and
/// the animation it plays: `app.animation_players`.
pub const Players = struct {
    by: std.AutoArrayHashMapUnmanaged(Entity, Binding) = .empty,
    /// Signals to say after the pass.
    said: std.ArrayList(Said) = .empty,

    const Said = struct { entity: Entity, started: bool, name: [name_len]u8 };

    pub const Binding = struct {
        library: AnimationLibraryHandle = .none,
        revision: u32 = 0,
        name: [name_len]u8 = @splat(0),
        tracks: std.ArrayList(Bound) = .empty,
    };

    pub fn deinit(self: *Players, gpa: Allocator) void {
        for (self.by.values()) |*binding| binding.tracks.deinit(gpa);
        self.by.deinit(gpa);
        self.said.deinit(gpa);
    }

    pub fn clear(self: *Players, gpa: Allocator) void {
        for (self.by.values()) |*binding| binding.tracks.deinit(gpa);
        self.by.clearRetainingCapacity();
    }

    pub fn forgetDead(self: *Players, gpa: Allocator, world: *const ecs.World) void {
        var at = self.by.count();
        while (at > 0) {
            at -= 1;
            if (world.isAlive(self.by.keys()[at])) continue;
            self.by.values()[at].tracks.deinit(gpa);
            self.by.swapRemoveAt(at);
        }
    }
};

/// Move every player on by `delta` seconds, and pose what each plays. What
/// `App.step` calls.
pub fn update(app: *App, delta: f32) !void {
    const players = &app.animation_players;
    players.said.clearRetainingCapacity();
    const flowing = delta > 0;

    var it = ecs.Query(.{AnimationPlayer}).over(&app.world) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyComponents => return,
    };
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(AnimationPlayer)) |e, *player| try advance(app, e, player, delta, flowing);
    }
    for (players.said.items) |said| {
        const name = nameIn(&said.name);
        if (said.started) {
            try app.emit(said.entity, AnimationPlayer, .animation_started, .{ .name = name });
        } else try app.emit(said.entity, AnimationPlayer, .animation_finished, .{ .name = name });
    }
}

fn advance(app: *App, e: Entity, player: *AnimationPlayer, delta: f32, flowing: bool) !void {
    const players = &app.animation_players;
    switch (player.request) {
        .none => {},
        .stop => {
            player.request = .none;
            player.playing = false;
            player.position = 0;
            player.next = @splat(0);
        },
        // Nothing starts in a frame with no time.
        .play => if (flowing) {
            player.request = .none;
            try start(app, e, player, nameIn(&player.wanted), player.from);
        },
        .seek => {
            player.request = .none;
            player.position = player.from;
            try poseOf(app, e, player);
        },
    }
    if (!player.started and flowing) {
        player.started = true;
        const name = nameIn(&player.autoplay);
        if (name.len > 0 and !player.playing) try start(app, e, player, name, 0);
    }
    if (!player.playing or player.paused or !flowing or !app.isProcessing(e)) return;

    const library = app.animation_libraries.get(player.library) orelse return;
    const animation = library.find(player.currentName()) orelse {
        player.playing = false;
        return;
    };
    player.position += delta * player.speed;
    const length = animation.length;
    var ended = false;
    switch (animation.loop) {
        .none => if (player.position >= length or player.position < 0) {
            player.position = std.math.clamp(player.position, 0, length);
            ended = true;
        },
        .repeat => player.position = if (length > 0) @mod(player.position, length) else 0,
        .ping_pong => player.position = if (length > 0) @mod(player.position, length * 2) else 0,
    }
    try poseOf(app, e, player);
    if (!ended) return;
    player.playing = false;
    try players.said.append(app.gpa, .{ .entity = e, .started = false, .name = player.current });
    const next = nameIn(&player.next);
    if (next.len > 0) {
        var name: [name_len]u8 = player.next;
        player.next = @splat(0);
        try start(app, e, player, nameIn(&name), 0);
    }
}

fn start(app: *App, e: Entity, player: *AnimationPlayer, name: []const u8, from: f32) !void {
    const library = app.animation_libraries.get(player.library) orelse {
        player.playing = false;
        return;
    };
    if (library.find(name) == null) {
        log.warn("{f} has no animation called {s} to play", .{ e, name });
        player.playing = false;
        return;
    }
    setName(&player.current, name);
    player.position = from;
    player.playing = true;
    try app.animation_players.said.append(app.gpa, .{ .entity = e, .started = true, .name = player.current });
    try poseOf(app, e, player);
}

/// The player's entities as its animation says they are where it is.
fn poseOf(app: *App, e: Entity, player: *const AnimationPlayer) !void {
    const library = app.animation_libraries.get(player.library) orelse return;
    const animation = library.find(player.currentName()) orelse return;
    const binding = try bindingOf(app, e, player, library, animation);
    const time = timeIn(animation, player.position);
    for (binding.tracks.items) |bound| {
        const value = animation.tracks.items[bound.track].sample(time) orelse continue;
        _ = bound.property.write(app, bound.entity, value);
    }
}

/// Where in the animation `position` is: back and forth for one that goes
/// back and forth.
fn timeIn(animation: *const Animation, position: f32) f32 {
    if (animation.loop == .ping_pong and position > animation.length) return animation.length * 2 - position;
    return position;
}

/// The player's tracks bound to what they move, again after a change to the
/// library or to what it plays, or when an entity bound is gone.
fn bindingOf(app: *App, e: Entity, player: *const AnimationPlayer, library: *const Library, animation: *const Animation) !*Players.Binding {
    const entry = try app.animation_players.by.getOrPut(app.gpa, e);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    const binding = entry.value_ptr;
    var fresh = !binding.library.eql(player.library) or binding.revision != library.revision or !std.mem.eql(u8, &binding.name, &player.current);
    if (!fresh) for (binding.tracks.items) |bound| {
        if (!app.world.isAlive(bound.entity)) fresh = true;
    };
    if (!fresh) return binding;
    binding.library = player.library;
    binding.revision = library.revision;
    binding.name = player.current;
    binding.tracks.clearRetainingCapacity();
    try bindTracks(app, e, animation, &binding.tracks);
    return binding;
}

fn bindTracks(app: *App, root: Entity, animation: *const Animation, into: *std.ArrayList(Bound)) !void {
    for (animation.tracks.items, 0..) |*track, at| {
        const target = targetOf(app, root, track.target) orelse continue;
        const compiled = Property.compile(app, track.property) catch continue;
        try into.append(app.gpa, .{ .track = at, .entity = target, .property = compiled });
    }
}

/// The entity a track's `target` names from `root`.
pub fn targetOf(app: *App, root: Entity, target: []const u8) ?Entity {
    if (target.len == 0 or std.mem.eql(u8, target, ".")) return root;
    return app.findPath(root, target);
}

/// The `target` a track of `root`'s player names `entity` by: empty for
/// `root` itself, and otherwise the names down from it, `Panel/Title`. Null
/// for an entity not under `root`, or under one with no name.
pub fn targetPath(app: *App, root: Entity, entity: Entity, buffer: []u8) ?[]const u8 {
    if (entity.eql(root)) return "";
    var names: [32][]const u8 = undefined;
    var count: usize = 0;
    var at = entity;
    while (!at.eql(root)) : (at = app.parentOf(at)) {
        if (at.isNone() or count == names.len) return null;
        names[count] = app.nameOf(at) orelse return null;
        count += 1;
    }
    var w: std.Io.Writer = .fixed(buffer);
    var i = count;
    while (i > 0) {
        i -= 1;
        w.writeAll(names[i]) catch return null;
        if (i > 0) w.writeByte('/') catch return null;
    }
    return w.buffered();
}

/// Pose `root` and what is under it as `animation` says they are `time`
/// seconds in, with no player: what an editor shows as it scrubs through
/// one. What a track cannot move is passed over.
pub fn pose(app: *App, root: Entity, animation: *const Animation, time: f32) !void {
    var bound: std.ArrayList(Bound) = .empty;
    defer bound.deinit(app.gpa);
    try bindTracks(app, root, animation, &bound);
    for (bound.items) |held| {
        const value = animation.tracks.items[held.track].sample(time) orelse continue;
        _ = held.property.write(app, held.entity, value);
    }
}

test "a track goes between its keys by each key's curve, or jumps to them" {
    var track: Track = .{ .target = &.{}, .property = &.{} };
    defer track.keys.deinit(testing.allocator);
    try track.keys.appendSlice(testing.allocator, &.{
        .{ .time = 0, .value = .{ .number = 0 } },
        .{ .time = 1, .value = .{ .number = 10 } },
        .{ .time = 2, .value = .{ .number = 20 }, .ease = .quad_in },
    });
    try testing.expectEqual(@as(f64, 0), track.sample(-1).?.number);
    try testing.expectEqual(@as(f64, 5), track.sample(0.5).?.number);
    try testing.expectEqual(@as(f64, 12.5), track.sample(1.5).?.number);
    try testing.expectEqual(@as(f64, 20), track.sample(9).?.number);
    track.update = .discrete;
    try testing.expectEqual(@as(f64, 10), track.sample(1.9).?.number);
}

test "a library is read back as it was written" {
    const text =
        \\{ "fluxion_animation": 1, "animations": [
        \\  { "name": "open", "length": 0.5, "loop": "ping_pong", "tracks": [
        \\    { "target": "Panel", "property": "Appearance.modulate", "update": "discrete",
        \\      "keys": [ { "time": 0.5, "value": "#ff000080" }, { "time": 0, "value": [0, 1, 0, 1], "ease": "back_out" } ] },
        \\    { "target": "", "property": "Transform2D.x,y", "keys": [ { "time": 0, "value": [1, 2] }, { "time": 0.2, "value": true }, { "time": 0.3 } ] } ] } ] }
    ;
    var library: Library = .{ .source = @constCast("test.anim"), .on_disc = false };
    defer library.deinitContent(testing.allocator);
    try read(testing.allocator, &library, text);
    const open = library.find("open").?;
    try testing.expectEqual(Loop.ping_pong, open.loop);
    // Put in the order of their times.
    try testing.expectEqual(@as(f32, 0), open.tracks.items[0].keys.items[0].time);
    try testing.expectEqual(math.ease.Kind.back_out, open.tracks.items[0].keys.items[0].ease);
    try testing.expectApproxEqAbs(@as(f32, 0.5), open.tracks.items[0].keys.items[1].value.color[3], 0.01);
    // A key with no value is left out.
    try testing.expectEqual(@as(usize, 2), open.tracks.items[1].keys.items.len);

    const written = try json.stringify(testing.allocator, Document{ .library = &library }, write_options);
    defer testing.allocator.free(written);
    var back: Library = .{ .source = @constCast("back.anim"), .on_disc = false };
    defer back.deinitContent(testing.allocator);
    try read(testing.allocator, &back, written);
    const again = back.find("open").?;
    try testing.expectEqual(Update.discrete, again.tracks.items[0].update);
    try testing.expectEqual(@as(f32, 0.5), again.length);
    try testing.expectEqual(@as(f32, 2), again.tracks.items[1].keys.items[0].value.vec2[1]);
    try testing.expectError(error.NotAnimations, read(testing.allocator, &back, "{ \"fluxion_scene\": 3 }"));
}
