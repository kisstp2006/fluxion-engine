// SPDX-License-Identifier: BSD-3-Clause

//! A world written down, and read back: as JSON to read and to diff, or as
//! CBOR, the same scene in fewer bytes. Reading tells the two apart itself.
//!
//! ```zig
//! try app.registerComponents(.{ Wander, Player });
//! try app.saveScene("levels/meadow.json", .{});
//! try app.saveScene("levels/meadow.scene", .{ .format = .cbor });
//! const loaded = try app.loadScene("levels/meadow.scene", .{});
//! ```
//!
//! ```json
//! {
//!   "fluxion_scene": 1,
//!   "entities": [
//!     {
//!       "name": "player",
//!       "Transform2D": { "x": 320.0, "y": 180.0 },
//!       "Sprite": { "texture": "art/hero.png", "width": 48.0, "height": 48.0 }
//!     },
//!     {
//!       "Transform2D": { "y": -6.0, "parent": 0 },
//!       "Sprite": { "texture": "art/turret.png" }
//!     }
//!   ]
//! }
//! ```
//!
//! **An entity is an object of its components**, each under its type's name.
//! A component's field that holds its default is left out, so a scene says
//! what is particular about each thing - and a field added to a component
//! later reads as its default from every scene written before it.
//!
//! **What a handle points at is written, not the handle.** An `Entity` is its
//! place in the list, and a texture or a font is the file it was read from -
//! from the scene file's own directory, so the two can move together and a
//! scene opens from any working directory. Reading mints new entities, points
//! every reference at the new ones, and loads the files - or finds them
//! already loaded. A texture made from pixels in memory has no file, and is
//! written as `null`.
//!
//! **A scene holds the components it has been told about.** The engine's are
//! registered from the start, and a game adds its own with
//! `App.registerComponents`. A component in a file that nothing registered
//! is passed over and counted in `Loaded.skipped`, so a scene from a newer
//! build still opens.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const json = @import("fluxion_json");
const rhi = @import("fluxion_rhi");

const App = @import("App.zig");
const Assets = @import("assets.zig");
const components = @import("components.zig");

const Entity = ecs.Entity;
const World = ecs.World;
const ComponentId = ecs.component.Id;
const TextureHandle = Assets.TextureHandle;
const FontHandle = Assets.FontHandle;
const Text2D = components.Text2D;

/// The version this writes, and the newest it reads.
pub const version = 1;

pub const SaveOptions = struct {
    format: json.Format = .json,
    /// Spaces per level of JSON. CBOR has no layout.
    indent: u8 = 2,
};

pub const LoadOptions = struct {
    /// Where reading went wrong and why: a line and a column, or a byte of
    /// CBOR, and the path to the value, such as `/entities/3/Sprite/texture`.
    diagnostics: ?*json.Diagnostics = null,
    /// The directory the scene's texture and font paths are relative to.
    /// `load` gives the scene file's own; null reads them from the working
    /// directory, as they are.
    directory: ?[]const u8 = null,
};

/// Where a scene file's paths are relative to: its own directory, and the
/// working directory that one is relative to in turn.
const Base = struct {
    cwd: []const u8,
    directory: []const u8,
};

/// What a load did.
pub const Loaded = struct {
    /// How many entities it spawned.
    entities: usize = 0,
    /// Components the file has that nothing here is registered as, passed
    /// over.
    skipped: usize = 0,
};

/// What scenes can hold, and what each component is called in one.
pub const Registry = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Error = error{
        /// Another type is registered under that name. Declare
        /// `pub const scene_name` on one of them.
        ComponentNameTaken,
    } || Allocator.Error;

    pub const Entry = struct {
        name: []const u8,
        key: ecs.component.Key,
        idIn: *const fn (world: *World) World.Error!ComponentId,
        findIdIn: *const fn (world: *const World) ?ComponentId,
        write: *const fn (s: *Saving, w: *json.Writer, cell: *const anyopaque) json.Writer.Error!void,
        read: *const fn (l: *Loading, cell: *anyopaque) anyerror!void,

        fn of(comptime T: type, name: []const u8) Entry {
            const Shim = struct {
                fn idIn(world: *World) World.Error!ComponentId {
                    return world.idOf(T);
                }
                fn findIdIn(world: *const World) ?ComponentId {
                    return world.findId(T);
                }
                fn write(s: *Saving, w: *json.Writer, cell: *const anyopaque) json.Writer.Error!void {
                    return writeComponent(s, w, T, @ptrCast(@alignCast(cell)));
                }
                fn read(l: *Loading, cell: *anyopaque) anyerror!void {
                    return readComponent(l, T, @ptrCast(@alignCast(cell)));
                }
            };
            return .{
                .name = name,
                .key = ecs.component.keyOf(T),
                .idIn = Shim.idIn,
                .findIdIn = Shim.findIdIn,
                .write = Shim.write,
                .read = Shim.read,
            };
        }
    };

    pub fn deinit(self: *Registry, gpa: Allocator) void {
        self.entries.deinit(gpa);
    }

    /// Let scenes hold `T`s, under `name`, which must outlive the registry.
    /// A type registered again is left as it was.
    pub fn add(self: *Registry, gpa: Allocator, comptime T: type, name: []const u8) Error!void {
        const key = ecs.component.keyOf(T);
        for (self.entries.items) |entry| {
            if (entry.key == key) return;
            if (std.mem.eql(u8, entry.name, name)) return error.ComponentNameTaken;
        }
        try self.entries.append(gpa, .of(T, name));
    }

    pub fn find(self: *const Registry, name: []const u8) ?*const Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

/// What `T` is called in a scene: its `scene_name` if it declares one, and
/// otherwise its type name without the path in front - `Wander`, not
/// `creatures.Wander`.
pub fn nameOf(comptime T: type) []const u8 {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => if (@hasDecl(T, "scene_name")) return T.scene_name,
        else => {},
    }
    const full = @typeName(T);
    const end = std.mem.indexOfScalar(u8, full, '(') orelse full.len;
    const start = if (std.mem.lastIndexOfScalar(u8, full[0..end], '.')) |dot| dot + 1 else 0;
    return full[start..];
}

/// How a texture a scene points at is sampled, when it is not the way
/// `Assets.loadTexture` samples by default.
const TextureOptions = struct {
    filter: rhi.Filter = .nearest,
    wrap: rhi.Wrap = .clamp_to_edge,
};

// -------------------------------------------------------------------------
// Writing
// -------------------------------------------------------------------------

/// Write `app`'s world to a file. See `App.saveScene`. Texture and font
/// paths are written from the file's own directory, so the scene and what
/// it points at can move together.
pub fn save(app: *App, io: std.Io, path: []const u8, options: SaveOptions) !void {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPath(io, &cwd_buffer);
    const base: Base = .{ .cwd = cwd_buffer[0..cwd_len], .directory = std.fs.path.dirname(path) orelse "." };
    return json.save(io, path, Document{ .app = app, .base = base }, writeOptions(options));
}

/// Write `app`'s world into fresh memory, with texture and font paths as
/// they were loaded. The caller frees it.
pub fn write(app: *App, gpa: Allocator, options: SaveOptions) json.StringifyError![]u8 {
    return json.stringify(gpa, Document{ .app = app }, writeOptions(options));
}

fn writeOptions(options: SaveOptions) json.WriteOptions {
    // NaN and the infinities as themselves: JSON5 in text, floats in CBOR.
    return .{ .format = options.format, .indent = options.indent, .non_finite = .literal };
}

/// The world as fluxion-json writes it.
const Document = struct {
    app: *App,
    base: ?Base = null,

    pub fn toJson(self: Document, w: *json.Writer) json.Writer.Error!void {
        const gpa = self.app.gpa;
        var s: Saving = .{ .app = self.app, .base = self.base, .paths = .init(gpa) };
        defer s.deinit(gpa);
        try s.placeAll();

        try w.beginObject();
        try w.field("fluxion_scene", @as(u32, version));
        try w.key("entities");
        try w.beginArray();
        for (s.order.items) |e| try s.writeEntity(w, e);
        try w.endArray();
        try s.writeTextureOptions(w);
        try w.endObject();
    }
};

/// One entity as a scene writes it - its name and its registered components
/// - for `json.stringify` or `json.Document.from`: what an editor's inspector
/// shows. An entity it names is written as its place in the world's list.
pub const EntityJson = struct {
    app: *App,
    entity: Entity,
    /// Every field, and not only those that differ from their defaults.
    every_field: bool = false,

    pub fn toJson(self: EntityJson, w: *json.Writer) json.Writer.Error!void {
        var s: Saving = .{ .app = self.app, .every_field = self.every_field, .paths = .init(self.app.gpa) };
        defer s.deinit(self.app.gpa);
        try s.placeAll();
        try s.writeEntity(w, self.entity);
    }
};

const Saving = struct {
    app: *App,
    every_field: bool = false,
    /// Null writes a path as it was loaded.
    base: ?Base = null,
    /// Paths as the scene spells them.
    paths: std.heap.ArenaAllocator,
    /// Every entity, in the order a scene lists them.
    order: std.ArrayList(Entity) = .empty,
    /// Each entity's place in the list, by `Entity.toInt`.
    places: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// Every texture written, for the table of how the unusual ones are
    /// sampled.
    textures: std.AutoArrayHashMapUnmanaged(TextureHandle, void) = .empty,

    fn deinit(s: *Saving, gpa: Allocator) void {
        s.order.deinit(gpa);
        s.places.deinit(gpa);
        s.textures.deinit(gpa);
        s.paths.deinit();
    }

    /// A texture or a font's file, as the scene names it: from the scene's
    /// directory, with forward slashes, so a scene saved on Windows reads
    /// anywhere. An absolute path - a system font - stays as it is.
    fn pathOf(s: *Saving, source: []const u8) Allocator.Error![]const u8 {
        const base = s.base orelse return source;
        if (std.fs.path.isAbsolute(source)) return source;
        const from_scene = try std.fs.path.relative(s.paths.allocator(), base.cwd, null, base.directory, source);
        std.mem.replaceScalar(u8, from_scene, '\\', '/');
        return from_scene;
    }

    /// Every entity in the world, in the order their slots were handed out -
    /// for a world built and never thinned, the order it was built in - and
    /// each one's place in that order.
    fn placeAll(s: *Saving) Allocator.Error!void {
        const gpa = s.app.gpa;
        for (s.app.world.archetypeSlice()) |*archetype| try s.order.appendSlice(gpa, archetype.entities.items);
        std.mem.sort(Entity, s.order.items, {}, earlier);
        try s.places.ensureTotalCapacity(gpa, @intCast(s.order.items.len));
        for (s.order.items, 0..) |e, place| s.places.putAssumeCapacity(e.toInt(), @intCast(place));
    }

    fn earlier(_: void, a: Entity, b: Entity) bool {
        return a.index < b.index;
    }

    fn writeEntity(s: *Saving, w: *json.Writer, e: Entity) json.Writer.Error!void {
        const app = s.app;
        try w.beginObject();
        if (app.nameOf(e)) |name| try w.field("name", name);
        for (app.scene_components.entries.items) |entry| {
            const id = entry.findIdIn(&app.world) orelse continue;
            const cell = app.world.cellOf(e, id) orelse continue;
            try w.key(entry.name);
            try entry.write(s, w, cell);
        }
        try w.endObject();
    }

    fn writeTextureOptions(s: *Saving, w: *json.Writer) json.Writer.Error!void {
        var any = false;
        for (s.textures.keys()) |handle| {
            const texture = s.app.assets.get(handle) orelse continue;
            const options: TextureOptions = .{ .filter = texture.filter, .wrap = texture.wrap };
            if (std.meta.eql(options, TextureOptions{})) continue;
            if (!any) {
                try w.key("textures");
                try w.beginObject();
                any = true;
            }
            try w.key(try s.pathOf(texture.source));
            try writeComponent(s, w, TextureOptions, &options);
        }
        if (any) try w.endObject();
    }
};

/// A component: an object of the fields that do not hold their defaults.
fn writeComponent(s: *Saving, w: *json.Writer, comptime T: type, value: *const T) json.Writer.Error!void {
    if (@typeInfo(T) != .@"struct") return writeValue(s, w, T, value);
    try w.beginObject();
    if (T == Text2D and (value.len > 0 or s.every_field)) try w.field("text", value.slice());
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const held = &@field(value.*, field.name);
        const skip = (T == Text2D and comptime isTextBuffer(field.name)) or
            (if (field.defaultValue()) |default| !s.every_field and std.meta.eql(held.*, default) else false);
        if (!skip) {
            try w.key(field.name);
            try writeValue(s, w, field.type, held);
        }
    }
    try w.endObject();
}

/// A value inside a component, whole: a nested struct with all its fields,
/// so a colour reads as the four numbers it is.
fn writeValue(s: *Saving, w: *json.Writer, comptime T: type, value: *const T) json.Writer.Error!void {
    if (T == Entity) {
        const place = if (value.isNone()) null else s.places.get(value.toInt());
        return if (place) |p| w.writeInt(p) else w.writeNull();
    }
    if (T == TextureHandle) {
        const source = s.app.assets.textureSource(value.*) orelse return w.writeNull();
        try s.textures.put(s.app.gpa, value.*, {});
        return w.writeString(try s.pathOf(source));
    }
    if (T == FontHandle) {
        const source = s.app.assets.fontSource(value.*) orelse return w.writeNull();
        return w.writeString(try s.pathOf(source));
    }
    switch (@typeInfo(T)) {
        .bool => try w.writeBool(value.*),
        .int => try w.writeInt(value.*),
        .float => try w.writeFloat(value.*),
        .@"enum" => if (std.enums.tagName(T, value.*)) |name| {
            try w.writeString(name);
        } else try w.writeInt(@intFromEnum(value.*)),
        .@"struct" => |info| {
            try w.beginObject();
            inline for (info.fields) |field| {
                try w.key(field.name);
                try writeValue(s, w, field.type, &@field(value.*, field.name));
            }
            try w.endObject();
        },
        .array => |info| {
            try w.beginArray();
            for (value) |*item| try writeValue(s, w, info.child, item);
            try w.endArray();
        },
        .vector => |info| {
            try w.beginArray();
            const items: [info.len]info.child = value.*;
            for (&items) |*item| try writeValue(s, w, info.child, item);
            try w.endArray();
        },
        .optional => |info| if (value.*) |*inner| {
            try writeValue(s, w, info.child, inner);
        } else try w.writeNull(),
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("fluxion-engine: a scene cannot tell which field of the untagged union " ++ @typeName(T) ++ " is set");
            switch (value.*) {
                inline else => |*payload, tag| {
                    if (@TypeOf(payload.*) == void) return w.writeString(@tagName(tag));
                    try w.beginObject();
                    try w.key(@tagName(tag));
                    try writeValue(s, w, @TypeOf(payload.*), payload);
                    try w.endObject();
                },
            }
        },
        else => @compileError("fluxion-engine: a scene cannot hold a " ++ @typeName(T)),
    }
}

/// The buffer and the length a `Text2D` keeps its words in, written as one
/// string called `text` instead.
fn isTextBuffer(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "bytes") or std.mem.eql(u8, name, "len");
}

// -------------------------------------------------------------------------
// Reading
// -------------------------------------------------------------------------
//
// Two passes over the tokens, and no tree. The first learns which components
// each entity has and spawns it with all of them, so that the second can
// write every value straight into its cell - and an entity named anywhere in
// the list already exists when a value names it. Numbers stay the digits the
// file has until a field asks for them as its own type, so a `u64` comes
// back to the last digit, which a tree's `i64` could not promise.

/// Read the scene at `path` into `app`'s world. See `App.loadScene`.
pub fn load(app: *App, io: std.Io, path: []const u8, options: LoadOptions) anyerror!Loaded {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.setFile(path);
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, app.gpa, .unlimited) catch |err| {
        if (options.diagnostics) |d| d.setMessage("cannot read the file: {t}", .{err});
        return err;
    };
    defer app.gpa.free(bytes);
    var from_file = options;
    from_file.directory = std.fs.path.dirname(path) orelse ".";
    return read(app, bytes, from_file);
}

/// Read a scene from memory into `app`'s world. If anything in it is wrong,
/// nothing of it stays.
pub fn read(app: *App, bytes: []const u8, options: LoadOptions) anyerror!Loaded {
    const gpa = app.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var spawned: std.ArrayList(Entity) = .empty;
    defer spawned.deinit(gpa);
    errdefer for (spawned.items) |e| app.world.despawn(e);

    var textures: std.StringHashMapUnmanaged(TextureOptions) = .empty;
    var skipped: usize = 0;
    {
        var reader: json.Reader = .init(gpa, bytes, readerOptions(options));
        defer reader.deinit();
        var l: Loading = .{ .app = app, .reader = &reader, .arena = arena.allocator(), .diagnostics = options.diagnostics };
        skipped = try l.shape(&spawned, &textures);
    }
    {
        var reader: json.Reader = .init(gpa, bytes, readerOptions(options));
        defer reader.deinit();
        var l: Loading = .{
            .app = app,
            .reader = &reader,
            .arena = arena.allocator(),
            .diagnostics = options.diagnostics,
            .entities = spawned.items,
            .texture_options = &textures,
            .directory = options.directory,
        };
        try l.fill();
    }
    return .{ .entities = spawned.items.len, .skipped = skipped };
}

fn readerOptions(options: LoadOptions) json.Reader.Options {
    // JSON5 for NaN and the infinities, which the writer spells out; comments
    // come with it, for a scene edited by hand.
    return .{ .syntax = .json5, .diagnostics = options.diagnostics };
}

const Token = json.Reader.Token;

const Loading = struct {
    app: *App,
    reader: *json.Reader,
    /// For what outlives a token: the paths in the texture table.
    arena: Allocator,
    diagnostics: ?*json.Diagnostics,
    /// Every entity in the file, at its place in the list.
    entities: []const Entity = &.{},
    texture_options: ?*const std.StringHashMapUnmanaged(TextureOptions) = null,
    /// What the scene's paths are relative to. See `LoadOptions.directory`.
    directory: ?[]const u8 = null,
    /// Textures found or loaded already, by the path the file gives.
    textures: std.StringHashMapUnmanaged(TextureHandle) = .empty,
    fonts: std.StringHashMapUnmanaged(FontHandle) = .empty,
    path: Path = .{},

    /// The first pass: an entity for every object in `entities`, with every
    /// registered component it has, and the texture table. How many
    /// components nothing is registered as.
    fn shape(l: *Loading, spawned: *std.ArrayList(Entity), textures: *std.StringHashMapUnmanaged(TextureOptions)) anyerror!usize {
        const app = l.app;
        var skipped: usize = 0;
        var versioned = false;
        var listed = false;

        try l.open(.object_begin, "a scene, which is an object");
        while (try l.key()) |name| {
            if (std.mem.eql(u8, name, "fluxion_scene")) {
                const token = try l.next();
                const number = switch (token) {
                    .number => |n| n.asInt(u32),
                    else => null,
                } orelse return l.fail(error.NotAScene, "\"fluxion_scene\" is the version of the scene, and this is {f}", .{found(token)});
                if (number > version) return l.fail(error.UnsupportedVersion, "this scene is version {d}, and this engine reads up to version {d}", .{ number, version });
                versioned = true;
            } else if (std.mem.eql(u8, name, "entities")) {
                if (listed) return l.fail(error.NotAScene, "a scene has one list of entities, and this is a second", .{});
                listed = true;
                try l.open(.array_begin, "the list of entities");
                while (try l.reader.peek() != .array_end) {
                    const mark = l.path.push("entities/{d}", .{spawned.items.len});
                    try l.open(.object_begin, "an entity, which is an object of its components");
                    var ids: [ecs.component.max_components]ComponentId = undefined;
                    var count: usize = 0;
                    while (try l.key()) |member| {
                        if (!std.mem.eql(u8, member, "name")) {
                            if (app.scene_components.find(member)) |entry| {
                                if (count == ids.len) return error.TooManyComponents;
                                ids[count] = try entry.idIn(&app.world);
                                count += 1;
                            } else skipped += 1;
                        }
                        try l.reader.skipValue();
                    }
                    try spawned.ensureUnusedCapacity(app.gpa, 1);
                    spawned.appendAssumeCapacity(try app.world.spawnRaw(distinct(ids[0..count])));
                    l.path.pop(mark);
                }
                _ = try l.next();
            } else if (std.mem.eql(u8, name, "textures")) {
                try l.open(.object_begin, "the table of how textures are sampled, which is an object");
                while (try l.key()) |path| {
                    const owned = try l.arena.dupe(u8, path);
                    const mark = l.path.push("textures/{s}", .{owned});
                    var options: TextureOptions = undefined;
                    try readComponent(l, TextureOptions, &options);
                    try textures.put(l.arena, owned, options);
                    l.path.pop(mark);
                }
            } else try l.reader.skipValue();
        }
        if (!versioned) return l.fail(error.NotAScene, "this is not a scene: it has no \"fluxion_scene\" version", .{});
        return skipped;
    }

    /// The second pass: every name and every component value.
    fn fill(l: *Loading) anyerror!void {
        const app = l.app;
        _ = try l.next();
        while (try l.key()) |name| {
            if (!std.mem.eql(u8, name, "entities")) {
                try l.reader.skipValue();
                continue;
            }
            _ = try l.next();
            for (l.entities, 0..) |e, place| {
                const entity_mark = l.path.push("entities/{d}", .{place});
                _ = try l.next();
                while (try l.key()) |member| {
                    if (std.mem.eql(u8, member, "name")) {
                        const token = try l.next();
                        const text = switch (token) {
                            .string => |text| text,
                            else => return l.wrong("an entity's name", token),
                        };
                        app.setName(e, text) catch |err| return switch (err) {
                            error.NameTaken => l.fail(err, "\"{s}\" is the name of an entity already in the world", .{text}),
                            else => err,
                        };
                        continue;
                    }
                    const entry = app.scene_components.find(member) orelse {
                        try l.reader.skipValue();
                        continue;
                    };
                    const mark = l.path.push("{s}", .{entry.name});
                    const cell = app.world.cellOf(e, entry.findIdIn(&app.world).?).?;
                    try entry.read(l, cell);
                    l.path.pop(mark);
                }
                l.path.pop(entity_mark);
            }
            return;
        }
    }

    fn next(l: *Loading) anyerror!Token {
        return (try l.reader.next()) orelse l.fail(error.SyntaxError, "the scene ends too soon", .{});
    }

    /// The next member's name, or null at the end of the object.
    fn key(l: *Loading) anyerror!?[]const u8 {
        return switch (try l.next()) {
            .key => |name| name,
            else => null,
        };
    }

    fn open(l: *Loading, comptime kind: std.meta.Tag(Token), comptime what: []const u8) anyerror!void {
        const token = try l.next();
        if (token != kind) return l.wrong(what, token);
    }

    fn wrong(l: *Loading, comptime expected: []const u8, token: Token) anyerror {
        return l.fail(error.WrongType, "expected " ++ expected ++ ", found {f}", .{found(token)});
    }

    /// Say what is wrong with the last token, and where in the scene it is.
    fn fail(l: *Loading, err: anyerror, comptime fmt: []const u8, args: anytype) anyerror {
        l.reader.report(fmt, args);
        if (l.diagnostics) |d| d.setPath(l.path.slice());
        return err;
    }

    /// Where a path in the scene is from the working directory: joined to
    /// the scene's directory, with forward slashes.
    fn located(l: *Loading, path: []const u8) Allocator.Error![]const u8 {
        const directory = l.directory orelse return path;
        if (std.fs.path.isAbsolute(path)) return path;
        const joined = try std.fs.path.resolve(l.arena, &.{ directory, path });
        std.mem.replaceScalar(u8, joined, '\\', '/');
        return joined;
    }

    fn texture(l: *Loading, path: []const u8) anyerror!TextureHandle {
        if (l.textures.get(path)) |known| return known;
        const where = try l.located(path);
        const assets = &l.app.assets;
        const handle = assets.findTexture(where) orelse blk: {
            const options = if (l.texture_options) |table| table.get(path) orelse TextureOptions{} else TextureOptions{};
            break :blk assets.loadTexture(where, .{ .filter = options.filter, .wrap = options.wrap }) catch |err|
                return l.fail(err, "cannot read the texture \"{s}\": {t}", .{ where, err });
        };
        try l.textures.put(l.arena, try l.arena.dupe(u8, path), handle);
        return handle;
    }

    fn font(l: *Loading, path: []const u8) anyerror!FontHandle {
        if (l.fonts.get(path)) |known| return known;
        const where = try l.located(path);
        const assets = &l.app.assets;
        const handle = assets.findFont(where) orelse assets.loadFont(where, .{}) catch |err|
            return l.fail(err, "cannot read the font \"{s}\": {t}", .{ where, err });
        try l.fonts.put(l.arena, try l.arena.dupe(u8, path), handle);
        return handle;
    }
};

/// `ids` sorted, and each once: an archetype's signature.
fn distinct(ids: []ComponentId) []const ComponentId {
    std.mem.sort(ComponentId, ids, {}, ecs.component.Signature.lessThan);
    var kept: usize = 0;
    for (ids) |id| {
        if (kept > 0 and ids[kept - 1] == id) continue;
        ids[kept] = id;
        kept += 1;
    }
    return ids[0..kept];
}

/// A component, from an object whose missing fields take their defaults.
fn readComponent(l: *Loading, comptime T: type, out: *T) anyerror!void {
    if (@typeInfo(T) != .@"struct") return readValue(l, T, out);
    try l.open(.object_begin, "an object of the component's fields");
    const fields = @typeInfo(T).@"struct".fields;
    var seen: std.StaticBitSet(fields.len) = .initEmpty();
    if (T == Text2D) {
        out.bytes = @splat(0);
        out.len = 0;
    }
    while (try l.key()) |name| {
        if (T == Text2D and std.mem.eql(u8, name, "text")) {
            try readText(l, out);
            continue;
        }
        var matched = false;
        inline for (fields, 0..) |field, i| {
            const hidden = T == Text2D and comptime isTextBuffer(field.name);
            if (!hidden and !matched and std.mem.eql(u8, name, field.name)) {
                matched = true;
                seen.set(i);
                const mark = l.path.push("{s}", .{field.name});
                try readValue(l, field.type, &@field(out.*, field.name));
                l.path.pop(mark);
            }
        }
        // A field the component no longer has: the scene is older than it.
        if (!matched) try l.reader.skipValue();
    }
    try defaultTheRest(l, T, out, seen);
}

fn defaultTheRest(l: *Loading, comptime T: type, out: *T, seen: anytype) anyerror!void {
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        const hidden = T == Text2D and comptime isTextBuffer(field.name);
        if (!hidden and !seen.isSet(i)) {
            @field(out.*, field.name) = field.defaultValue() orelse
                return l.fail(error.MissingField, "{s} has no {s}, and it has no default to take", .{ nameOf(T), field.name });
        }
    }
}

fn readText(l: *Loading, out: *Text2D) anyerror!void {
    const token = try l.next();
    const text = switch (token) {
        .string => |text| text,
        else => return l.wrong("the words of the text", token),
    };
    if (text.len > Text2D.capacity) return l.fail(error.OutOfRange, "this text is {d} bytes, and a Text2D holds {d}", .{ text.len, Text2D.capacity });
    out.set(text);
}

/// A value inside a component. A nested struct may leave fields out too.
fn readValue(l: *Loading, comptime T: type, out: *T) anyerror!void {
    if (T == Entity) {
        const token = try l.next();
        out.* = switch (token) {
            .null => .none,
            .number => |n| blk: {
                const place = n.asInt(usize) orelse return l.fail(error.WrongType, "an entity is written as its place in the list, and {s} is not one", .{n.text});
                if (place >= l.entities.len) return l.fail(error.NoSuchEntity, "there is no entity {d} in this scene, which has {d}", .{ place, l.entities.len });
                break :blk l.entities[place];
            },
            else => return l.wrong("an entity's place in the list, or null", token),
        };
        return;
    }
    if (T == TextureHandle or T == FontHandle) {
        const token = try l.next();
        out.* = switch (token) {
            .null => .none,
            .string => |path| if (T == TextureHandle) try l.texture(path) else try l.font(path),
            else => return l.wrong("the file it was read from, or null", token),
        };
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => return readComponent(l, T, out),
        .optional => |info| {
            if (try l.reader.peek() == .null) {
                _ = try l.next();
                out.* = null;
                return;
            }
            var inner: info.child = undefined;
            try readValue(l, info.child, &inner);
            out.* = inner;
        },
        .array => |info| try readItems(l, info.child, info.len, out),
        .vector => |info| {
            var items: [info.len]info.child = undefined;
            try readItems(l, info.child, info.len, &items);
            out.* = items;
        },
        .@"union" => |info| {
            const token = try l.next();
            switch (token) {
                .string => |arm| inline for (info.fields) |field| {
                    if (field.type == void and std.mem.eql(u8, arm, field.name)) {
                        out.* = @unionInit(T, field.name, {});
                        return;
                    }
                },
                .object_begin => if (try l.key()) |arm| inline for (info.fields) |field| {
                    if (std.mem.eql(u8, arm, field.name)) {
                        var payload: field.type = undefined;
                        if (field.type == void) try l.reader.skipValue() else try readValue(l, field.type, &payload);
                        out.* = @unionInit(T, field.name, payload);
                        if (try l.key() != null) return l.fail(error.WrongType, "a union is one member, naming the field that is set, and this has more", .{});
                        return;
                    }
                },
                else => {},
            }
            return l.wrong("the name of one of " ++ @typeName(T) ++ "'s fields", token);
        },
        else => {
            const token = try l.next();
            out.* = switch (@typeInfo(T)) {
                .bool => switch (token) {
                    .bool => |b| b,
                    else => return l.wrong("true or false", token),
                },
                .int => switch (token) {
                    .number => |n| n.asInt(T) orelse return if (n.isInteger())
                        l.fail(error.OutOfRange, "{s} does not fit in a {s}, which holds {d} to {d}", .{ n.text, @typeName(T), std.math.minInt(T), std.math.maxInt(T) })
                    else
                        l.fail(error.WrongType, "expected a whole number, found {s}", .{n.text}),
                    else => return l.wrong("a whole number", token),
                },
                .float => switch (token) {
                    .number => |n| n.asFloat(T),
                    else => return l.wrong("a number", token),
                },
                .@"enum" => |info| switch (token) {
                    .string => |name| std.meta.stringToEnum(T, name) orelse
                        return l.fail(error.WrongType, "\"{s}\" is not one of the names of {s}", .{ name, @typeName(T) }),
                    .number => |n| if (n.asInt(info.tag_type)) |raw| std.enums.fromInt(T, raw) orelse
                        return l.fail(error.WrongType, "{s} is not one of the values of {s}", .{ n.text, @typeName(T) }) else return l.wrong("one of the names of " ++ @typeName(T), token),
                    else => return l.wrong("one of the names of " ++ @typeName(T), token),
                },
                else => @compileError("fluxion-engine: a scene cannot hold a " ++ @typeName(T)),
            };
        },
    }
}

fn readItems(l: *Loading, comptime Item: type, comptime len: usize, out: *[len]Item) anyerror!void {
    try l.open(.array_begin, std.fmt.comptimePrint("a list of {d}", .{len}));
    for (out, 0..) |*item, i| {
        if (try l.reader.peek() == .array_end) return l.fail(error.LengthMismatch, "expected {d} items, found {d}", .{ len, i });
        const mark = l.path.push("{d}", .{i});
        try readValue(l, Item, item);
        l.path.pop(mark);
    }
    if (try l.next() != .array_end) return l.fail(error.LengthMismatch, "expected {d} items, found more", .{len});
}

/// What a token is, for a message: `the string "wide"`, `an object`.
fn found(token: Token) Found {
    return .{ .token = token };
}

const Found = struct {
    token: Token,

    pub fn format(f: Found, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (f.token) {
            .string => |text| try w.print("the string \"{s}\"", .{text}),
            .number => |n| try w.print("the number {s}", .{n.text}),
            .bool => |b| try w.print("{}", .{b}),
            .null => try w.writeAll("null"),
            .object_begin => try w.writeAll("an object"),
            .array_begin => try w.writeAll("a list"),
            .key => |name| try w.print("the key \"{s}\"", .{name}),
            .object_end, .array_end => try w.writeAll("the end of it"),
        }
    }
};

/// Where the reading is, as a JSON Pointer, for the diagnostics. Cut short
/// rather than failing if it outgrows the buffer.
const Path = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    fn push(p: *Path, comptime fmt: []const u8, args: anytype) usize {
        const mark = p.len;
        const written = std.fmt.bufPrint(p.buf[p.len..], "/" ++ fmt, args) catch "";
        p.len += written.len;
        return mark;
    }

    fn pop(p: *Path, mark: usize) void {
        p.len = mark;
    }

    fn slice(p: *const Path) []const u8 {
        return p.buf[0..p.len];
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const image = @import("fluxion_image");

const Transform2D = components.Transform2D;
const Sprite = components.Sprite;
const Camera2D = components.Camera2D;
const Animation = components.Animation;

/// A game's own component, holding the kinds of thing a component can.
const Wander = extern struct {
    dx: f32,
    dy: f32 = 0,
    mood: Mood = .calm,
    /// Who it is following, if anyone.
    leader: Entity = .none,
    seed: u64 = 0,
    steps: [3]u8 = .{ 1, 2, 3 },

    const Mood = enum(u8) { calm, curious, cross };
};

fn headless() !*App {
    return App.create(testing.allocator, .{ .headless = true, .io = testing.io });
}

test "a scene reads as what it holds, and leaves out what is the default" {
    const app = try headless();
    defer app.destroy();
    try app.registerComponents(.{Wander});

    const camera = try app.world.spawnWith(.{ Transform2D.at(320, 180), Camera2D{} });
    try app.setName(camera, "camera");
    var label: Text2D = .of("Hi");
    label.size = 13;
    _ = try app.world.spawnWith(.{ Transform2D.childOf(camera, 0, -6), label });
    _ = try app.world.spawnWith(.{Wander{ .dx = 1, .mood = .cross, .leader = camera }});

    const text = try write(app, testing.allocator, .{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\{
        \\  "fluxion_scene": 1,
        \\  "entities": [
        \\    {
        \\      "name": "camera",
        \\      "Transform2D": { "x": 320.0, "y": 180.0 },
        \\      "Camera2D": {}
        \\    },
        \\    {
        \\      "Transform2D": { "y": -6.0, "parent": 0 },
        \\      "Text2D": { "text": "Hi", "size": 13.0 }
        \\    },
        \\    { "Wander": { "dx": 1.0, "mood": "cross", "leader": 0 } }
        \\  ]
        \\}
    , text);
}

test "one entity is written as a scene writes it, or with every field for an inspector" {
    const app = try headless();
    defer app.destroy();
    const camera = try app.world.spawnWith(.{ Transform2D.at(4, 8), Camera2D{} });
    try app.setName(camera, "camera");
    const child = try app.world.spawnWith(.{Transform2D.childOf(camera, 0, 2)});

    const brief = try json.stringify(testing.allocator, EntityJson{ .app = app, .entity = child }, .{});
    defer testing.allocator.free(brief);
    try testing.expectEqualStrings("{\"Transform2D\":{\"y\":2.0,\"parent\":0}}", brief);

    const doc = try json.Document.init(testing.allocator);
    defer doc.deinit();
    const whole = try doc.from(EntityJson{ .app = app, .entity = camera, .every_field = true });
    try testing.expectEqualStrings("camera", whole.get("name").asString().?);
    try testing.expectEqual(@as(?f32, 1), whole.get("Transform2D").get("scale_x").asFloat(f32));
    try testing.expectEqual(@as(?bool, true), whole.get("Camera2D").get("active").asBool());
}

test "a scene comes back as it went, from JSON and from CBOR" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var png_buf: [160]u8 = undefined;
    const png = try std.fmt.bufPrint(&png_buf, "{s}/hero.png", .{dir});
    try image.png.writeFile(testing.allocator, testing.io, png, .{
        .width = 2,
        .height = 2,
        .pixels = &(.{255} ** 16),
        .row_pitch = 8,
    }, .{ .keep_alpha = true });

    const source = try headless();
    defer source.destroy();
    try source.registerComponents(.{Wander});
    const hero = try source.assets.loadTexture(png, .{ .filter = .linear });
    const typeface = source.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 64 }) catch FontHandle.none;

    const body = try source.world.spawnWith(.{
        Transform2D.at(10, 20).interpolated(),
        Sprite{ .texture = hero, .tint = .rgba(0.5, 0.25, 1, 0.75), .region = .cell(3, 4, 2), .blend = .additive },
        Animation.strip(4, 8),
    });
    try source.setName(body, "hero");
    _ = try source.world.spawnWith(.{ Transform2D.childOf(body, -7, -4), Sprite.solid(.white, 9, 9) });
    var label: Text2D = .of("Zoë ✓");
    label.font = typeface;
    _ = try source.world.spawnWith(.{ Transform2D{ .parent = body, .inherit_rotation = false }, label });
    _ = try source.world.spawnWith(.{Wander{
        .dx = 0.1,
        .dy = std.math.inf(f32),
        .leader = body,
        .seed = std.math.maxInt(u64),
        .steps = .{ 7, 8, 9 },
        .mood = .curious,
    }});

    const expected = try write(source, testing.allocator, .{});
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.indexOf(u8, expected, "\"filter\": \"linear\"") != null);

    for ([_]json.Format{ .json, .cbor }) |format| {
        var path_buf: [160]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/level.{t}", .{ dir, format });
        try source.saveScene(path, .{ .format = format });

        const copy = try headless();
        defer copy.destroy();
        try copy.registerComponents(.{Wander});
        const loaded = try copy.loadScene(path, .{});
        try testing.expectEqual(@as(usize, 4), loaded.entities);
        try testing.expectEqual(@as(usize, 0), loaded.skipped);

        const again = try write(copy, testing.allocator, .{});
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(expected, again);

        const leader = copy.find("hero").?;
        const wander = copy.single(Wander).?;
        try testing.expect(wander.leader.eql(leader));
        try testing.expectEqual(@as(u64, std.math.maxInt(u64)), wander.seed);
        const sheet = copy.world.get(leader, Sprite).?.texture;
        try testing.expectEqual(rhi.Filter.linear, copy.assets.get(sheet).?.filter);
    }
}

test "a texture's path is written from the scene file's directory, and found from there" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "art");
    var buffers: [3][160]u8 = undefined;
    const png = try std.fmt.bufPrint(&buffers[0], ".zig-cache/tmp/{s}/art/hero.png", .{tmp.sub_path});
    const scene_path = try std.fmt.bufPrint(&buffers[1], ".zig-cache/tmp/{s}/levels/meadow.json", .{tmp.sub_path});
    try image.png.writeFile(testing.allocator, testing.io, png, .{ .width = 1, .height = 1, .pixels = &.{ 255, 255, 255, 255 }, .row_pitch = 4 }, .{});

    const source = try headless();
    defer source.destroy();
    const hero = try source.assets.loadTexture(png, .{});
    _ = try source.world.spawnWith(.{ Transform2D.at(1, 2), Sprite.of(hero) });
    try source.saveScene(scene_path, .{});

    const saved = try std.Io.Dir.cwd().readFileAlloc(testing.io, scene_path, testing.allocator, .unlimited);
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "\"texture\": \"../art/hero.png\"") != null);

    const copy = try headless();
    defer copy.destroy();
    _ = try copy.loadScene(scene_path, .{});
    const sheet = copy.single(Sprite).?.texture;
    const beside = try std.fmt.bufPrint(&buffers[2], ".zig-cache/tmp/{s}/art/hero.png", .{tmp.sub_path});
    try testing.expectEqualStrings(beside, copy.assets.textureSource(sheet).?);
}

test "what a scene has that nothing here knows is passed over, and what it lacks is the default" {
    const app = try headless();
    defer app.destroy();
    const loaded = try read(app,
        \\{ "fluxion_scene": 1, "entities": [
        \\  { "Transform2D": { "x": 5, "wobble": 3 }, "Mystery": { "a": [1, 2] } },
        \\  { "name": "empty" }
        \\], "future": true }
    , .{});
    try testing.expectEqual(@as(usize, 2), loaded.entities);
    try testing.expectEqual(@as(usize, 1), loaded.skipped);

    const place = app.single(Transform2D).?;
    try testing.expectEqual(@as(f32, 5), place.x);
    try testing.expectEqual(@as(f32, 1), place.scale_x);
    try testing.expect(place.parent.isNone());
    try testing.expect(app.find("empty") != null);
}

test "a mistake in a scene says where it is, and leaves the world as it was" {
    const app = try headless();
    defer app.destroy();
    _ = try app.world.spawnWith(.{Transform2D.at(1, 1)});

    const text =
        \\{ "fluxion_scene": 1, "entities": [
        \\  { "name": "first", "Transform2D": { "x": 5 } },
        \\  { "Transform2D": { "parent": 7 } }
        \\] }
    ;
    var diagnostics: json.Diagnostics = .{};
    try testing.expectError(error.NoSuchEntity, read(app, text, .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("there is no entity 7 in this scene, which has 2", diagnostics.message());
    try testing.expectEqualStrings("/entities/1/Transform2D/parent", diagnostics.path());
    try testing.expectEqual(@as(u32, 3), diagnostics.line);
    try testing.expectEqual(@as(u32, 32), diagnostics.column);
    try testing.expectEqual(@as(usize, 1), app.world.count());
    try testing.expect(app.find("first") == null);

    // The same mistake in CBOR is at a byte.
    const binary = try json.reformat(testing.allocator, text, .{}, .{ .format = .cbor });
    defer testing.allocator.free(binary);
    try testing.expectError(error.NoSuchEntity, read(app, binary, .{ .diagnostics = &diagnostics }));
    try testing.expect(diagnostics.binary);
    try testing.expectEqualStrings("/entities/1/Transform2D/parent", diagnostics.path());

    try testing.expectError(error.WrongType, read(app,
        \\{ "fluxion_scene": 1, "entities": [{ "Sprite": { "width": "wide" } }] }
    , .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("expected a number, found the string \"wide\"", diagnostics.message());
    try testing.expectEqualStrings("/entities/0/Sprite/width", diagnostics.path());
    try testing.expectEqual(@as(usize, 1), app.world.count());
}

test "a file that is not a scene, or a newer one, is refused" {
    const app = try headless();
    defer app.destroy();
    var diagnostics: json.Diagnostics = .{};

    try testing.expectError(error.NotAScene, read(app, "{ \"entities\": [] }", .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("this is not a scene: it has no \"fluxion_scene\" version", diagnostics.message());

    try testing.expectError(error.UnsupportedVersion, read(app, "{ \"fluxion_scene\": 2, \"entities\": [] }", .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("this scene is version 2, and this engine reads up to version 1", diagnostics.message());

    try testing.expectError(error.WrongType, read(app, "[1, 2]", .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("expected a scene, which is an object, found a list", diagnostics.message());
}

/// Two components called the same, in two places.
const Twins = struct {
    const First = struct {
        const Marker = extern struct { v: u8 = 0 };
    };
    const Second = struct {
        const Marker = extern struct { w: u8 = 0 };
    };
    const Renamed = extern struct {
        w: u8 = 0,
        pub const scene_name = "OtherMarker";
    };
};

test "two components of one name need a scene_name to tell them apart" {
    const app = try headless();
    defer app.destroy();
    try app.registerComponents(.{Twins.First.Marker});
    try app.registerComponents(.{Twins.First.Marker});
    try testing.expectError(error.ComponentNameTaken, app.registerComponents(.{Twins.Second.Marker}));
    try app.registerComponents(.{Twins.Renamed});
    try testing.expect(app.scene_components.find("Marker") != null);
    try testing.expect(app.scene_components.find("OtherMarker") != null);
}
