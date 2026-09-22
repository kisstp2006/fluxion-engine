// SPDX-License-Identifier: BSD-3-Clause

//! A world written down, and read back: as JSON to read and to diff, or as
//! CBOR, the same scene in fewer bytes. Reading tells the two apart itself.
//!
//! ```zig
//! try app.registerComponents(.{ Wander, Player });
//! try app.saveScene("res://levels/meadow.json", .{});
//! try app.saveScene("res://levels/meadow.scene", .{ .format = .cbor });
//! const loaded = try app.loadScene("res://levels/meadow.scene", .{});
//! ```
//!
//! ```json
//! {
//!   "fluxion_scene": 2,
//!   "entities": [
//!     {
//!       "uuid": "0b8e3c1a-5f2d-4c6e-9a7b-1d2e3f4a5b6c",
//!       "name": "player",
//!       "Transform2D": { "x": 320.0, "y": 180.0 },
//!       "Sprite": { "texture": "res://art/hero.png", "width": 48.0, "height": 48.0 }
//!     },
//!     {
//!       "uuid": "5c2d7e9f-0a1b-4c3d-8e5f-6a7b8c9d0e1f",
//!       "Transform2D": { "y": -6.0, "parent": "0b8e3c1a-5f2d-4c6e-9a7b-1d2e3f4a5b6c" },
//!       "Sprite": { "texture": "res://art/turret.png" }
//!     }
//!   ],
//!   "assets": {
//!     "res://art/hero.png": { "uid": "uid://2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34", "filter": "linear" },
//!     "res://art/turret.png": { "uid": "uid://9d1e4b7a-3c2f-4e8d-a1b6-0f5c7e2d9a83" }
//!   }
//! }
//! ```
//!
//! **An entity is an object of its components**, each under its type's name,
//! beside its UUID and its name. A component's field that holds its default
//! is left out, so a scene says what is particular about each thing - and a
//! field added to a component later reads as its default from every scene
//! written before it.
//!
//! **What a handle points at is written, not the handle.** An `Entity` is the
//! UUID of the one it names, which every entity written is given - so a scene
//! diffs cleanly when one is added at the top, and an editor's undo can bring
//! one back as what it was. A texture or a font is its file, by the path
//! `Project` names it by - `res://` inside the project, which opens from any
//! working directory - and in `assets`, by the UUID in the `.uid` file beside
//! it, which saving a scene makes where there is none. Reading goes by the
//! UUID first, so a file moved with its `.uid` file is found where it went,
//! and by the path when nothing holds that UUID. A texture made from pixels in
//! memory has no file, and is written as `null`.
//!
//! **Reading mints new entities**, gives each the UUID the file has for it -
//! or, when an entity in the world has that one already, as when a scene is
//! loaded twice, a new one - and points every reference at the right one: in
//! the scene first, then in the world, so a scene can name an entity another
//! scene brought.
//!
//! **A scene holds the components it has been told about.** The engine's are
//! registered from the start, and a game adds its own with
//! `App.registerComponents`. A component in a file that nothing here is
//! registered as is kept with its entity as the file has it, and written
//! back so when the scene is saved: a scene from a newer build still opens,
//! and an editor without a game's own components saves the game's scenes
//! whole. See `Unknown`. A scene of another version is refused, and the
//! refusal says which version it is.
//!
//! **A scene that is wrong is an error, never a crash**: what the file holds
//! is checked as it is read, and a mistake is returned with where it is,
//! leaving the world as it was - an editor shows it and goes on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const json = @import("fluxion_json");
const reflect = @import("fluxion_reflect");
const rhi = @import("fluxion_rhi");

const App = @import("App.zig");
const signals = @import("signals.zig");
const Assets = @import("assets.zig");
const Project = @import("Project.zig");
const components = @import("components.zig");

const Entity = ecs.Entity;
const World = ecs.World;
const ComponentId = ecs.component.Id;
const TextureHandle = Assets.TextureHandle;
const FontHandle = Assets.FontHandle;
const Text2D = components.Text2D;
const Label = @import("control.zig").Label;
const LineEdit = @import("control.zig").LineEdit;
const ScriptHandle = @import("script.zig").ScriptHandle;
const Script = @import("script.zig").Script;
const tilemap = @import("tilemap.zig");
const TileMap = tilemap.TileMap;
const TileChunk = tilemap.TileChunk;
const TileSetHandle = @import("tileset.zig").TileSetHandle;
const Uuid = @import("fluxion_id").Uuid;
const math = @import("fluxion_math");
const Color = @import("color.zig").Color;

/// The version this writes, and the only one it reads.
pub const version = 2;

pub const SaveOptions = struct {
    format: json.Format = .json,
    /// Spaces per level of JSON. CBOR has no layout.
    indent: u8 = 2,
};

pub const LoadOptions = struct {
    /// Where reading went wrong and why: a line and a column, or a byte of
    /// CBOR, and the path to the value, such as `/entities/3/Sprite/texture`.
    diagnostics: ?*json.Diagnostics = null,
};

/// What a load did.
pub const Loaded = struct {
    /// How many entities it spawned.
    entities: usize = 0,
    /// Components the file has that nothing here is registered as: kept
    /// with their entities, saved back as they were, and never run. An
    /// editor without the game's components meets these. See `Unknown`.
    components_unknown: usize = 0,
    /// Entities given a new UUID, because one in the world had the one the
    /// file gave them: the same scene loaded twice, say. References inside
    /// the scene still find them.
    reassigned: usize = 0,
    /// Files found by their UUID at another path than the scene names: moved
    /// or renamed with their `.uid` files. Saving the scene again writes
    /// where they are now.
    moved: usize = 0,
    /// Connections made to a signal no component of this build declares, or
    /// to a method the target has not got: kept, saved back as they were,
    /// and never heard. An editor without the game's components meets these.
    connections_unknown: usize = 0,
    /// Connections passed over because one of their two ends is in neither
    /// the scene nor the world.
    connections_skipped: usize = 0,
};

/// What `assets` says of one file: its UUID, and how a texture is sampled
/// when that is not the way `Assets.loadTexture` samples by default.
const FileInfo = struct {
    uid: ?Uuid = null,
    filter: rhi.Filter = .nearest,
    wrap: rhi.Wrap = .clamp_to_edge,
};

/// What scenes can hold, and what each component is called in one.
pub const Registry = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Error = error{
        /// Another type is registered under that name. Declare
        /// `pub const scene_name` on one of them - or, when it is their
        /// `reflect_name`s that are the same, change one.
        ComponentNameTaken,
    } || Allocator.Error;

    pub const Entry = struct {
        name: []const u8,
        key: ecs.component.Key,
        /// What the component is made of, for a value of it whose type is
        /// known only at run time. See `App.componentOf`.
        type: *const reflect.Type,
        /// What it can say: its `pub const signals`. See `App.signal`.
        signals: []const signals.Decl,
        idIn: *const fn (world: *World) World.Error!ComponentId,
        findIdIn: *const fn (world: *const World) ?ComponentId,
        /// Put one holding its defaults on an entity, or overwrite the one
        /// it has with them.
        addTo: *const fn (world: *World, entity: Entity) (World.Error || error{NoSuchEntity})!void,
        removeFrom: *const fn (world: *World, entity: Entity) World.Error!void,
        write: *const fn (s: *Saving, w: *json.Writer, cell: *const anyopaque) json.Writer.Error!void,
        read: *const fn (l: *Loading, cell: *anyopaque) anyerror!void,

        fn of(comptime T: type, name: []const u8) Entry {
            const Shim = struct {
                /// Its declared defaults, and zero where it declares none: a
                /// component added by hand has to start from something.
                const initial: T = reflect.initialValue(T) orelse std.mem.zeroes(T);

                fn idIn(world: *World) World.Error!ComponentId {
                    return world.idOf(T);
                }
                fn findIdIn(world: *const World) ?ComponentId {
                    return world.findId(T);
                }
                fn addTo(world: *World, entity: Entity) (World.Error || error{NoSuchEntity})!void {
                    return world.add(entity, initial);
                }
                fn removeFrom(world: *World, entity: Entity) World.Error!void {
                    return world.remove(entity, T);
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
                .type = reflect.typeOf(T),
                .signals = signals.declsOf(T),
                .idIn = Shim.idIn,
                .findIdIn = Shim.findIdIn,
                .addTo = Shim.addTo,
                .removeFrom = Shim.removeFrom,
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

/// Components scenes held that nothing here is registered as, each kept with
/// its entity as the scene had it and written back with it when a scene is
/// saved. A value is kept as compact JSON, which holds a number to its last
/// digit whether the scene was JSON or CBOR. A string is kept as a string:
/// a UUID in one naming an entity is not pointed anywhere new, as a
/// registered component's `Entity` is when a scene is loaded twice.
pub const Unknown = struct {
    /// Each entity's, in the order its scene had them. An array map, so that
    /// `forgetDead` can walk it by index while removing from it.
    by_entity: std.AutoArrayHashMapUnmanaged(Entity, std.ArrayList(Component)) = .empty,

    pub const Component = struct {
        name: []const u8,
        /// Its value, as compact JSON.
        value: []const u8,
    };

    pub fn deinit(self: *Unknown, gpa: Allocator) void {
        for (self.by_entity.values()) |*list| freeAll(gpa, list);
        self.by_entity.deinit(gpa);
    }

    /// Every one forgotten: the world was cleared.
    pub fn clear(self: *Unknown, gpa: Allocator) void {
        for (self.by_entity.values()) |*list| freeAll(gpa, list);
        self.by_entity.clearRetainingCapacity();
    }

    /// An entity's, in the order its scene had them.
    pub fn of(self: *const Unknown, entity: Entity) []const Component {
        const list = self.by_entity.getPtr(entity) orelse return &.{};
        return list.items;
    }

    /// Keep one for `entity`. It takes `name` and `value`, which `gpa`
    /// made, once it has returned.
    fn keep(self: *Unknown, gpa: Allocator, entity: Entity, name: []const u8, value: []const u8) Allocator.Error!void {
        const slot = try self.by_entity.getOrPut(gpa, entity);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(gpa, .{ .name = name, .value = value });
    }

    /// Forget the one called `name` of an entity's. Whether there was one.
    pub fn remove(self: *Unknown, gpa: Allocator, entity: Entity, name: []const u8) bool {
        const list = self.by_entity.getPtr(entity) orelse return false;
        for (list.items, 0..) |kept, at| {
            if (!std.mem.eql(u8, kept.name, name)) continue;
            gpa.free(kept.name);
            gpa.free(kept.value);
            _ = list.orderedRemove(at);
            return true;
        }
        return false;
    }

    /// Forget those of every entity that has died. Once a frame, as the
    /// names are.
    pub fn forgetDead(self: *Unknown, gpa: Allocator, world: *const World) void {
        // Backwards, so the entry a swap-remove moves into the gap has
        // already been looked at.
        var at = self.by_entity.count();
        while (at > 0) {
            at -= 1;
            if (world.isAlive(self.by_entity.keys()[at])) continue;
            freeAll(gpa, &self.by_entity.values()[at]);
            self.by_entity.swapRemoveAt(at);
        }
    }

    fn freeAll(gpa: Allocator, list: *std.ArrayList(Component)) void {
        for (list.items) |kept| {
            gpa.free(kept.name);
            gpa.free(kept.value);
        }
        list.deinit(gpa);
    }
};

/// One whole value from `r` into `w`, token by token: a number as the digits
/// it was read as, a string as its text.
fn copyValue(r: *json.Reader, w: *json.Writer) (json.Reader.Error || json.Writer.Error)!void {
    var depth: usize = 0;
    while (true) {
        switch ((try r.next()) orelse return error.SyntaxError) {
            .object_begin => {
                try w.beginObject();
                depth += 1;
            },
            .array_begin => {
                try w.beginArray();
                depth += 1;
            },
            .object_end => {
                try w.endObject();
                depth -= 1;
            },
            .array_end => {
                try w.endArray();
                depth -= 1;
            },
            .key => |name| try w.key(name),
            .string => |text| try w.writeString(text),
            .number => |number| try w.writeNumber(number),
            .bool => |value| try w.writeBool(value),
            .null => try w.writeNull(),
        }
        if (depth == 0) return;
    }
}

/// What `T` is called in a scene, and by `App.componentOf`: its `scene_name`
/// if it declares one, then its `reflect_name`, and otherwise its type name
/// without the path in front - `Wander`, not `creatures.Wander`.
pub fn nameOf(comptime T: type) []const u8 {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => {
            if (@hasDecl(T, "scene_name")) return T.scene_name;
            if (@hasDecl(T, "reflect_name")) return T.reflect_name;
        },
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

/// Write `app`'s world to a file, named as `Project` names one. See
/// `App.saveScene`. A file of the project's that is loaded and has no UUID
/// is given one first, in a `.uid` file beside it, so the scene can name it
/// by that.
pub fn save(app: *App, io: std.Io, path: []const u8, options: SaveOptions) !void {
    try app.assets.ensureUids();
    try app.tile_sets.ensureUids(&app.project);
    if (app.scripts) |scripts| try scripts.ensureUids();
    const file = try app.project.osPath(app.gpa, path);
    defer app.gpa.free(file);
    return json.save(io, file, Document{ .app = app }, writeOptions(options));
}

/// Write `app`'s world into fresh memory. A file with no UUID yet is named
/// by its path alone: only `save` makes UUIDs for files. The caller frees it.
pub fn write(app: *App, gpa: Allocator, options: SaveOptions) json.StringifyError![]u8 {
    return json.stringify(gpa, Document{ .app = app }, writeOptions(options));
}

/// A scene with nothing in it, into fresh memory: what a new level starts as,
/// written before anything is put in it. The caller frees it. See
/// `App.createScene`, which writes one to a file.
pub fn writeEmpty(gpa: Allocator, options: SaveOptions) json.StringifyError![]u8 {
    return json.stringify(gpa, Empty{}, writeOptions(options));
}

fn writeOptions(options: SaveOptions) json.WriteOptions {
    // NaN and the infinities as themselves: JSON5 in text, floats in CBOR.
    return .{ .format = options.format, .indent = options.indent, .non_finite = .literal };
}

/// A scene of no entities, as `Document` writes one: the version, and an
/// empty list rather than none, so it reads as a scene by hand too.
const Empty = struct {
    pub fn toJson(_: Empty, w: *json.Writer) json.Writer.Error!void {
        try w.beginObject();
        try w.field("fluxion_scene", @as(u32, version));
        try w.key("entities");
        try w.beginArray();
        try w.endArray();
        try w.endObject();
    }
};

/// The world as fluxion-json writes it.
const Document = struct {
    app: *App,

    pub fn toJson(self: Document, w: *json.Writer) json.Writer.Error!void {
        const gpa = self.app.gpa;
        var s: Saving = .{ .app = self.app };
        defer s.deinit(gpa);
        try s.placeAll();

        try w.beginObject();
        try w.field("fluxion_scene", @as(u32, version));
        try w.key("entities");
        try w.beginArray();
        for (s.order.items) |e| try s.writeEntity(w, e);
        try w.endArray();
        try s.writeConnections(w);
        try s.writeFiles(w);
        try w.endObject();
    }
};

/// One entity as a scene writes it - its UUID, its name, its registered
/// components and those it was read with that nothing here knows - for
/// `json.stringify` or `json.Document.from`: what an editor's inspector
/// shows. An entity it names is written as its UUID.
pub const EntityJson = struct {
    app: *App,
    entity: Entity,
    /// Every field, and not only those that differ from their defaults.
    every_field: bool = false,

    pub fn toJson(self: EntityJson, w: *json.Writer) json.Writer.Error!void {
        var s: Saving = .{ .app = self.app, .every_field = self.every_field };
        defer s.deinit(self.app.gpa);
        try s.placeAll();
        try s.writeEntity(w, self.entity);
    }
};

const Saving = struct {
    app: *App,
    every_field: bool = false,
    /// The entity being written, for a component whose value is kept beside
    /// it: a map's tiles.
    entity: Entity = .none,
    /// Every entity, in the order a scene lists them.
    order: std.ArrayList(Entity) = .empty,
    /// Every file written, under the name it was written by, for `assets`.
    files: std.StringArrayHashMapUnmanaged(TextureOptions) = .empty,

    fn deinit(s: *Saving, gpa: Allocator) void {
        s.order.deinit(gpa);
        s.files.deinit(gpa);
    }

    /// Every entity in the world, in the order a parent's children are in -
    /// the order `App.setSiblingIndex` and the scenes read put them in, and
    /// then the order their slots were handed out, which for a world built
    /// and never thinned is the order it was built in - and each given a
    /// UUID, if it had none, for what names it to be written by. So the list
    /// is the order, and a scene needs nothing more to keep it.
    fn placeAll(s: *Saving) Allocator.Error!void {
        const gpa = s.app.gpa;
        for (s.app.world.archetypeSlice()) |*archetype| {
            for (archetype.entities.items) |e| {
                // A chunk is not a thing in the scene: its map writes its
                // tiles, and reading them makes the chunks again.
                if (s.app.world.has(e, TileChunk)) continue;
                try s.order.append(gpa, e);
            }
        }
        std.mem.sort(Entity, s.order.items, @as(*const App, s.app), App.siblingBefore);
        for (s.order.items) |e| _ = s.app.ensureUuid(e) catch |err| switch (err) {
            error.NoSuchEntity => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    fn writeEntity(s: *Saving, w: *json.Writer, e: Entity) json.Writer.Error!void {
        const app = s.app;
        s.entity = e;
        try w.beginObject();
        if (app.uuidOf(e)) |uuid| {
            const text = uuid.toString();
            try w.field("uuid", @as([]const u8, &text));
        }
        if (app.nameOf(e)) |name| try w.field("name", name);
        for (app.scene_components.entries.items) |entry| {
            const id = entry.findIdIn(&app.world) orelse continue;
            const cell = app.world.cellOf(e, id) orelse continue;
            try w.key(entry.name);
            try entry.write(s, w, cell);
        }
        try s.writeUnknown(w, e);
        try w.endObject();
    }

    /// The components the entity was read with that nothing here knows, as
    /// they were read. One of a name the entity has a registered component
    /// of now is left out: that component is what it holds.
    fn writeUnknown(s: *Saving, w: *json.Writer, e: Entity) json.Writer.Error!void {
        const app = s.app;
        for (app.unknown_components.of(e)) |kept| {
            if (app.componentOf(e, kept.name) != null) continue;
            try w.key(kept.name);
            var reader: json.Reader = .init(app.gpa, kept.value, .{ .syntax = .json5 });
            defer reader.deinit();
            copyValue(&reader, w) catch |err| return switch (err) {
                error.OutOfMemory, error.WriteFailed, error.TooDeep, error.NonFiniteNumber => |held| held,
                // `Loading.keepUnknown` wrote it, and it reads.
                error.SyntaxError => unreachable,
            };
        }
    }

    /// `connections`: every one made with `persist` from an entity written,
    /// to one written, in the order each entity's are heard - known to this
    /// build or not - and nothing at all when there are none. Godot's
    /// `[connection]` lines.
    fn writeConnections(s: *Saving, w: *json.Writer) json.Writer.Error!void {
        var any = false;
        for (s.order.items) |source| {
            const list = s.app.signals.from.getPtr(source) orelse continue;
            for (list.items) |c| {
                if (!c.options.flags.persist or c.callable != .named) continue;
                const from = s.app.uuidOf(source) orelse continue;
                const to = s.app.uuidOf(c.callable.named.target) orelse continue;
                if (!any) {
                    try w.key("connections");
                    try w.beginArray();
                    any = true;
                }
                try w.beginObject();
                const from_text = from.toString();
                try w.field("from", @as([]const u8, &from_text));
                try w.field("signal", s.app.signalWritten(c));
                const to_text = to.toString();
                try w.field("to", @as([]const u8, &to_text));
                try w.field("method", c.callable.named.name);
                // Every flag but `persist`, which every one written has.
                var flags = c.options.flags;
                flags.persist = false;
                if (@as(u8, @bitCast(flags)) != 0) {
                    try w.key("flags");
                    try w.beginArray();
                    inline for (.{ "deferred", "one_shot", "reference_counted", "append_source" }) |name| {
                        if (@field(flags, name)) try w.writeString(name);
                    }
                    try w.endArray();
                }
                if (c.options.unbinds != 0) try w.field("unbinds", c.options.unbinds);
                if (c.options.binds.len != 0) {
                    try w.key("binds");
                    try w.beginArray();
                    for (c.options.binds) |b| try s.writeBind(w, b);
                    try w.endArray();
                }
                try w.endObject();
            }
        }
        if (any) try w.endArray();
    }

    /// A bind: the plain JSON value it is, or an object saying which of the
    /// others it is.
    fn writeBind(s: *Saving, w: *json.Writer, b: signals.Bind) json.Writer.Error!void {
        switch (b) {
            .bool => |v| try w.writeBool(v),
            .int => |v| try w.writeInt(v),
            .float => |v| try w.writeFloat(v),
            .string => |v| try w.writeString(v),
            .vec2 => |v| {
                try w.beginObject();
                try w.key("vec2");
                try w.beginArray();
                try w.writeFloat(v.x);
                try w.writeFloat(v.y);
                try w.endArray();
                try w.endObject();
            },
            .color => |v| {
                try w.beginObject();
                try w.key("color");
                try w.beginArray();
                inline for (.{ v.r, v.g, v.b, v.a }) |part| try w.writeFloat(part);
                try w.endArray();
                try w.endObject();
            },
            .entity => |e| {
                try w.beginObject();
                try w.key("entity");
                try writeValue(s, w, Entity, &e);
                try w.endObject();
            },
        }
    }

    /// `assets`: each file the scene named that there is something to say
    /// of - its UUID, how a texture is sampled when that is not the default
    /// - and nothing at all when there is nothing to say of any.
    fn writeFiles(s: *Saving, w: *json.Writer) json.Writer.Error!void {
        var any = false;
        for (s.files.keys(), s.files.values()) |name, sampled| {
            const uid = s.app.project.knownUid(name);
            if (uid == null and std.meta.eql(sampled, TextureOptions{})) continue;
            if (!any) {
                try w.key("assets");
                try w.beginObject();
                any = true;
            }
            try w.key(name);
            try w.beginObject();
            if (uid) |held| {
                var text: [Project.uid_scheme.len + Uuid.string_len]u8 = undefined;
                try w.field("uid", std.fmt.bufPrint(&text, Project.uid_scheme ++ "{f}", .{held}) catch unreachable);
            }
            if (sampled.filter != .nearest) {
                try w.key("filter");
                try writeValue(s, w, rhi.Filter, &sampled.filter);
            }
            if (sampled.wrap != .clamp_to_edge) {
                try w.key("wrap");
                try writeValue(s, w, rhi.Wrap, &sampled.wrap);
            }
            try w.endObject();
        }
        if (any) try w.endObject();
    }
};

/// How many bytes a chunk's cells are, and the text they become.
const chunk_bytes = tilemap.tiles_per_chunk * @sizeOf(tilemap.Cell);
const chunk_text_len = std.base64.standard.Encoder.calcSize(chunk_bytes);

/// A map's tiles: one line of text a chunk, under the chunk's place.
///
/// Godot 3 writes a TileMap's cells as one flat list for the same reasons.
/// A chunk at a time rather than one long line so that a change to a corner
/// of a level is a change to one line of the file, and base64 rather than
/// numbers because a chunk is a kilobyte of them and nobody reads a
/// thousand numbers.
fn writeCells(s: *Saving, w: *json.Writer) json.Writer.Error!void {
    const app = s.app;
    var any = false;
    // In the order the chunks were made, which for a level painted left to
    // right is the order it was painted: a scene saved again keeps its
    // lines where they were.
    var it = app.tile_chunks.iterator();
    while (it.next()) |entry| {
        if (!entry.key_ptr.map.eql(s.entity)) continue;
        const chunk = app.world.getConst(entry.value_ptr.*, TileChunk) orelse continue;
        if (chunk.isEmpty()) continue;
        if (!any) {
            try w.key("cells");
            try w.beginObject();
            any = true;
        }
        var name: [32]u8 = undefined;
        var text: [chunk_text_len]u8 = undefined;
        try w.key(std.fmt.bufPrint(&name, "{d},{d}", .{ chunk.x, chunk.y }) catch unreachable);
        try w.writeString(std.base64.standard.Encoder.encode(&text, std.mem.asBytes(&chunk.cells)));
    }
    if (any) try w.endObject();
}

/// A component: an object of the fields that do not hold their defaults.
fn writeComponent(s: *Saving, w: *json.Writer, comptime T: type, value: *const T) json.Writer.Error!void {
    if (@typeInfo(T) != .@"struct") return writeValue(s, w, T, value);
    try w.beginObject();
    if (comptime isBufferedText(T)) if (value.len > 0 or s.every_field) try w.field("text", value.slice());
    if (T == LineEdit and (value.placeholder_len > 0 or s.every_field)) try w.field("placeholder_text", value.placeholderSlice());
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const held = &@field(value.*, field.name);
        const skip = (comptime isBufferedText(T) and isTextBuffer(field.name)) or (T == LineEdit and isPlaceholderBuffer(field.name)) or
            (if (field.defaultValue()) |default| !s.every_field and std.meta.eql(held.*, default) else false);
        if (!skip) {
            try w.key(field.name);
            if (comptime T == Script and std.mem.eql(u8, field.name, "struct_name")) {
                try w.writeString(value.structName());
            } else try writeValue(s, w, field.type, held);
        }
    }
    if (T == TileMap) try writeCells(s, w);
    try w.endObject();
}

/// A value inside a component, whole: a nested struct with all its fields,
/// so a colour reads as the four numbers it is.
fn writeValue(s: *Saving, w: *json.Writer, comptime T: type, value: *const T) json.Writer.Error!void {
    if (T == Entity) {
        const uuid = if (value.isNone()) null else s.app.uuidOf(value.*);
        const held = uuid orelse return w.writeNull();
        const text = held.toString();
        return w.writeString(&text);
    }
    if (T == TextureHandle) {
        const texture = s.app.assets.get(value.*) orelse return w.writeNull();
        if (texture.source.len == 0) return w.writeNull();
        try s.files.put(s.app.gpa, texture.source, .{ .filter = texture.filter, .wrap = texture.wrap });
        return w.writeString(texture.source);
    }
    if (T == ScriptHandle) {
        const source = s.app.scriptSource(value.*) orelse return w.writeNull();
        const kept = try s.files.getOrPut(s.app.gpa, source);
        if (!kept.found_existing) kept.value_ptr.* = .{};
        return w.writeString(source);
    }
    if (T == TileSetHandle) {
        const source = s.app.tileSetSource(value.*) orelse return w.writeNull();
        const kept = try s.files.getOrPut(s.app.gpa, source);
        if (!kept.found_existing) kept.value_ptr.* = .{};
        return w.writeString(source);
    }
    if (T == FontHandle) {
        const source = s.app.assets.fontSource(value.*) orelse return w.writeNull();
        const kept = try s.files.getOrPut(s.app.gpa, source);
        if (!kept.found_existing) kept.value_ptr.* = .{};
        // The first font of a file is the file. Another font of a collection
        // is an object that says which, so one scene can hold two of a file.
        const member = s.app.assets.fontMember(value.*);
        if (member == 0) return w.writeString(source);
        try w.beginObject();
        try w.field("file", source);
        try w.key("member");
        try w.writeInt(member);
        return w.endObject();
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

/// Read the scene at `path` - `res://`, `uid://` or the operating system's -
/// into `app`'s world. See `App.loadScene`.
pub fn load(app: *App, io: std.Io, path: []const u8, options: LoadOptions) anyerror!Loaded {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.setFile(path);
    }
    const file = app.project.osPath(app.gpa, path) catch |err| {
        if (options.diagnostics) |d| d.setMessage("cannot find the file: {t}", .{err});
        return err;
    };
    defer app.gpa.free(file);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, file, app.gpa, .unlimited) catch |err| {
        if (options.diagnostics) |d| d.setMessage("cannot read the file: {t}", .{err});
        return err;
    };
    defer app.gpa.free(bytes);
    return read(app, bytes, options);
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

    // What is in the world already keeps its place before the scene's.
    try app.placeTheRest();

    var told: Told = .{};
    {
        var reader: json.Reader = .init(gpa, bytes, readerOptions(options));
        defer reader.deinit();
        var l: Loading = .{ .app = app, .reader = &reader, .arena = arena.allocator(), .diagnostics = options.diagnostics };
        try l.shape(&spawned, &told);
    }

    // Each entity the UUID the file gives it - unless an entity already in
    // the world has that one, when it is given a new one, and the file's
    // stays the scene's own name for it.
    var loaded: Loaded = .{ .entities = spawned.items.len };
    for (spawned.items, told.uuids.items) |e, given| {
        const uuid = given orelse continue;
        if (app.findUuid(uuid) != null) {
            _ = try app.ensureUuid(e);
            loaded.reassigned += 1;
        } else app.setUuid(e, uuid) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UuidTaken, error.NilUuid, error.NoSuchEntity => unreachable,
        };
    }

    var chunks: std.ArrayList(PendingChunk) = .empty;
    defer chunks.deinit(gpa);
    {
        var reader: json.Reader = .init(gpa, bytes, readerOptions(options));
        defer reader.deinit();
        var l: Loading = .{
            .app = app,
            .reader = &reader,
            .arena = arena.allocator(),
            .diagnostics = options.diagnostics,
            .entities = spawned.items,
            .told = &told,
            .chunks = &chunks,
        };
        try l.fill();
        // The list is the order of every parent's children.
        try app.placeInOrder(spawned.items);
        loaded.moved = l.moved;
        loaded.components_unknown = l.components_unknown;
        loaded.connections_unknown = l.connections_unknown;
        loaded.connections_skipped = l.connections_skipped;
    }

    // Last of all: a chunk is an entity, and making one while the values
    // above were being written would have moved the rows they went into.
    var made: std.ArrayList(Entity) = .empty;
    defer made.deinit(gpa);
    errdefer for (made.items) |e| app.world.despawn(e);
    for (chunks.items) |pending| {
        const entity = try app.makeTileChunk(pending.map, pending.x, pending.y);
        try made.append(gpa, entity);
        const chunk = app.world.get(entity, TileChunk).?;
        chunk.cells = pending.cells;
    }
    return loaded;
}

/// What a scene says of itself, read without loading it: see `readInfo`.
pub const Info = struct {
    /// The version the file says it is. Only `version` loads; another is told
    /// rather than refused, so a tool can say which it is.
    version: u32,
    format: json.Format,
    /// How many entities it lists.
    entities: usize = 0,
    /// The files its `assets` table lists, in the file's order: for a scene
    /// `save` wrote, every file of the project's that it names.
    files: []File = &.{},

    pub const File = struct {
        /// As the scene gives it: `res://` for a file of the project's.
        path: []const u8,
        /// The UUID the scene knows it by, which finds it where it moved.
        uid: ?Uuid = null,
    };

    pub fn deinit(self: *Info, gpa: Allocator) void {
        for (self.files) |named| gpa.free(named.path);
        gpa.free(self.files);
        self.* = undefined;
    }
};

/// What starts every CBOR scene: the self-described tag, which is also how
/// the reader tells the two formats apart.
const cbor_start = "\xD9\xD9\xF7";

/// What the scene in `bytes` says of itself - its version, its format, how
/// many entities and which files - with no world to load it into: what an
/// editor shows of a scene it has not opened. Null when the bytes are not a
/// scene, which is anything that has not said `fluxion_scene` before it
/// stops making sense. A scene damaged after that is an error, and where
/// is in `diagnostics`. Free it with `Info.deinit`.
pub fn readInfo(gpa: Allocator, bytes: []const u8, diagnostics: ?*json.Diagnostics) !?Info {
    var reader: json.Reader = .init(gpa, bytes, .{ .syntax = .json5, .diagnostics = diagnostics });
    defer reader.deinit();

    var glance: Glance = .{
        .gpa = gpa,
        .reader = &reader,
        .said = .{ .version = 0, .format = if (std.mem.startsWith(u8, bytes, cbor_start)) .cbor else .json },
    };
    defer glance.deinit();
    glance.scene() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError, error.TooDeep => if (glance.versioned) return err else return null,
    };
    if (!glance.versioned) return null;

    var said = glance.said;
    said.files = try glance.files.toOwnedSlice(gpa);
    return said;
}

/// `readInfo`'s one pass: the members it wants, and the rest passed over.
/// Nothing a scene holds is checked but its shape where `readInfo` looks, so a
/// scene of another version is told as far as it can be.
const Glance = struct {
    gpa: Allocator,
    reader: *json.Reader,
    said: Info,
    /// Whether the scene has said its version: from then on, it is one.
    versioned: bool = false,
    files: std.ArrayList(Info.File) = .empty,

    fn deinit(g: *Glance) void {
        for (g.files.items) |named| g.gpa.free(named.path);
        g.files.deinit(g.gpa);
    }

    fn scene(g: *Glance) json.Reader.Error!void {
        if (try g.next() != .object_begin) return;
        while (try g.key()) |name| {
            // Told apart before the next token, which the name does not
            // outlive.
            const member = std.meta.stringToEnum(enum { fluxion_scene, entities, assets }, name) orelse {
                try g.reader.skipValue();
                continue;
            };
            switch (member) {
                .fluxion_scene => {
                    const number = switch (try g.next()) {
                        .number => |n| n.asInt(u32),
                        else => null,
                    } orelse return;
                    g.said.version = number;
                    g.versioned = true;
                },
                .entities => {
                    if (try g.peek() != .array_begin) {
                        try g.reader.skipValue();
                        continue;
                    }
                    _ = try g.next();
                    while (try g.peek() != .array_end) {
                        try g.reader.skipValue();
                        g.said.entities += 1;
                    }
                    _ = try g.next();
                },
                .assets => {
                    if (try g.peek() != .object_begin) {
                        try g.reader.skipValue();
                        continue;
                    }
                    _ = try g.next();
                    while (try g.key()) |path| {
                        try g.files.ensureUnusedCapacity(g.gpa, 1);
                        g.files.appendAssumeCapacity(.{ .path = try g.gpa.dupe(u8, path) });
                        g.files.items[g.files.items.len - 1].uid = try g.uid();
                    }
                },
            }
        }
    }

    /// The UUID in what `assets` says of one file, when it says one that
    /// reads.
    fn uid(g: *Glance) json.Reader.Error!?Uuid {
        if (try g.peek() != .object_begin) {
            try g.reader.skipValue();
            return null;
        }
        _ = try g.next();
        var found_uid: ?Uuid = null;
        while (try g.key()) |field| {
            if (!std.mem.eql(u8, field, "uid") or try g.peek() != .string) {
                try g.reader.skipValue();
                continue;
            }
            const text = (try g.next()).string;
            const body = if (std.mem.startsWith(u8, text, Project.uid_scheme)) text[Project.uid_scheme.len..] else text;
            found_uid = Uuid.parse(body) catch null;
        }
        return found_uid;
    }

    /// The next token. The input ending where a value should be is a
    /// mistake, never the end of a loop.
    fn next(g: *Glance) json.Reader.Error!Token {
        return (try g.reader.next()) orelse g.endsTooSoon();
    }

    fn peek(g: *Glance) json.Reader.Error!json.Reader.Kind {
        return (try g.reader.peek()) orelse g.endsTooSoon();
    }

    fn endsTooSoon(g: *Glance) json.Reader.Error {
        g.reader.report("the scene ends too soon", .{});
        return error.SyntaxError;
    }

    /// The next member's name, or null at the end of the object.
    fn key(g: *Glance) json.Reader.Error!?[]const u8 {
        return switch (try g.next()) {
            .key => |name| name,
            else => null,
        };
    }
};

/// What the first pass learns for the second. Kept in the arena.
const Told = struct {
    /// Each entity's UUID in the file, at its place in the list.
    uuids: std.ArrayList(?Uuid) = .empty,
    /// Each UUID's place in the list: what a reference inside the scene
    /// finds, whatever UUID the entity was given in the end.
    places: std.AutoHashMapUnmanaged(Uuid, usize) = .empty,
    /// `assets`, by path.
    files: std.StringHashMapUnmanaged(FileInfo) = .empty,
};

fn readerOptions(options: LoadOptions) json.Reader.Options {
    // JSON5 for NaN and the infinities, which the writer spells out; comments
    // come with it, for a scene edited by hand.
    return .{ .syntax = .json5, .diagnostics = options.diagnostics };
}

const Token = json.Reader.Token;

const Loading = struct {
    app: *App,
    reader: *json.Reader,
    /// For what outlives a token: the paths in the tables, what `Told` holds.
    arena: Allocator,
    diagnostics: ?*json.Diagnostics,
    /// Every entity in the file, at its place in the list.
    entities: []const Entity = &.{},
    /// What the first pass learnt. Null during it.
    told: ?*const Told = null,
    /// Textures found or loaded already, by the path the file gives.
    textures: std.StringHashMapUnmanaged(TextureHandle) = .empty,
    fonts: std.StringHashMapUnmanaged(FontHandle) = .empty,
    scripts: std.StringHashMapUnmanaged(ScriptHandle) = .empty,
    tile_sets: std.StringHashMapUnmanaged(TileSetHandle) = .empty,
    /// The entity being filled in, for a value kept beside its component:
    /// a map's tiles.
    entity: Entity = .none,
    /// The chunks the maps' cells make, kept until the whole scene is read:
    /// making an entity now would move the rows the values are being
    /// written into.
    chunks: ?*std.ArrayList(PendingChunk) = null,
    /// Files found by their UUIDs somewhere other than the scene says.
    moved: usize = 0,
    /// See `Loaded`.
    components_unknown: usize = 0,
    connections_unknown: usize = 0,
    connections_skipped: usize = 0,
    path: Path = .{},

    /// The first pass: an entity for every object in `entities`, with every
    /// registered component it has, each entity's UUID, and the tables of
    /// files.
    fn shape(l: *Loading, spawned: *std.ArrayList(Entity), told: *Told) anyerror!void {
        const app = l.app;
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
                if (number < version) return l.fail(error.UnsupportedVersion, "this scene is version {d}, an older one this engine no longer reads: it reads version {d}", .{ number, version });
                if (number > version) return l.fail(error.UnsupportedVersion, "this scene is version {d}, newer than this engine, which reads version {d}", .{ number, version });
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
                    var own: ?Uuid = null;
                    while (try l.key()) |member| {
                        if (std.mem.eql(u8, member, "uuid")) {
                            const inner = l.path.push("uuid", .{});
                            const uuid = try l.readUuid();
                            if (told.places.contains(uuid)) return l.fail(error.DuplicateUuid, "another entity in this scene has this UUID already", .{});
                            try told.places.put(l.arena, uuid, spawned.items.len);
                            own = uuid;
                            l.path.pop(inner);
                            continue;
                        }
                        if (!std.mem.eql(u8, member, "name")) {
                            if (app.scene_components.find(member)) |entry| {
                                if (count == ids.len) return error.TooManyComponents;
                                ids[count] = try entry.idIn(&app.world);
                                count += 1;
                            }
                        }
                        try l.reader.skipValue();
                    }
                    try spawned.ensureUnusedCapacity(app.gpa, 1);
                    try told.uuids.append(l.arena, own);
                    spawned.appendAssumeCapacity(try app.world.spawnRaw(distinct(ids[0..count])));
                    l.path.pop(mark);
                }
                _ = try l.next();
            } else if (std.mem.eql(u8, name, "assets")) {
                try l.open(.object_begin, "the table of the files the scene names, which is an object");
                while (try l.key()) |path| {
                    const owned = try l.arena.dupe(u8, path);
                    const mark = l.path.push("assets/{s}", .{owned});
                    try told.files.put(l.arena, owned, try l.fileInfo());
                    l.path.pop(mark);
                }
            } else try l.reader.skipValue();
        }
        if (!versioned) return l.fail(error.NotAScene, "this is not a scene: it has no \"fluxion_scene\" version", .{});
    }

    /// A UUID, written as a string: an entity's own, or one naming another.
    fn readUuid(l: *Loading) anyerror!Uuid {
        const token = try l.next();
        const text = switch (token) {
            .string => |text| text,
            else => return l.wrong("a UUID, which is a string", token),
        };
        const uuid = Uuid.parse(text) catch return l.fail(error.WrongType, "\"{s}\" is not a UUID", .{text});
        if (uuid.isNil()) return l.fail(error.WrongType, "the nil UUID names nothing", .{});
        return uuid;
    }

    /// One file in `assets`: its UUID, and how a texture is sampled.
    fn fileInfo(l: *Loading) anyerror!FileInfo {
        var info: FileInfo = .{};
        try l.open(.object_begin, "what the scene knows of a file, which is an object");
        while (try l.key()) |field| {
            if (std.mem.eql(u8, field, "uid")) {
                const mark = l.path.push("uid", .{});
                const token = try l.next();
                const text = switch (token) {
                    .string => |text| text,
                    else => return l.wrong("a uid:// path", token),
                };
                const body = if (std.mem.startsWith(u8, text, Project.uid_scheme)) text[Project.uid_scheme.len..] else text;
                info.uid = Uuid.parse(body) catch return l.fail(error.WrongType, "\"{s}\" is not a uid:// path", .{text});
                l.path.pop(mark);
            } else if (std.mem.eql(u8, field, "filter")) {
                const mark = l.path.push("filter", .{});
                try readValue(l, rhi.Filter, &info.filter);
                l.path.pop(mark);
            } else if (std.mem.eql(u8, field, "wrap")) {
                const mark = l.path.push("wrap", .{});
                try readValue(l, rhi.Wrap, &info.wrap);
                l.path.pop(mark);
            } else try l.reader.skipValue();
        }
        return info;
    }

    /// The second pass: every name and every component value.
    fn fill(l: *Loading) anyerror!void {
        const app = l.app;
        _ = try l.next();
        while (try l.key()) |name| {
            if (std.mem.eql(u8, name, "connections")) {
                const mark = l.path.push("connections", .{});
                try l.connections();
                l.path.pop(mark);
                continue;
            }
            if (!std.mem.eql(u8, name, "entities")) {
                try l.reader.skipValue();
                continue;
            }
            _ = try l.next();
            for (l.entities, 0..) |e, place| {
                const entity_mark = l.path.push("entities/{d}", .{place});
                l.entity = e;
                _ = try l.next();
                while (try l.key()) |member| {
                    if (std.mem.eql(u8, member, "uuid")) {
                        try l.reader.skipValue();
                        continue;
                    }
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
                        try l.keepUnknown(e, member);
                        continue;
                    };
                    const mark = l.path.push("{s}", .{entry.name});
                    const cell = app.world.cellOf(e, entry.findIdIn(&app.world).?).?;
                    try entry.read(l, cell);
                    l.path.pop(mark);
                }
                l.path.pop(entity_mark);
            }
            // Past the list's end, for what comes after it: the connections.
            try l.open(.array_end, "the end of the entities");
        }
    }

    /// A component nothing here is registered as, kept with its entity as
    /// the scene has it. See `Unknown`.
    fn keepUnknown(l: *Loading, e: Entity, name: []const u8) anyerror!void {
        const gpa = l.app.gpa;
        // The reader's, until its next token.
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        var text: std.Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        var w: json.Writer = .init(&text.writer, .{ .non_finite = .literal });
        try copyValue(l.reader, &w);
        const value = try text.toOwnedSlice();
        errdefer gpa.free(value);
        try l.app.unknown_components.keep(gpa, e, owned, value);
        l.components_unknown += 1;
    }

    /// `connections`: each made again, with `persist`, whether this build
    /// knows its signal and its method or not - an editor that has not got
    /// the game's components saves them back as they were. One whose `from`
    /// or `to` is in neither the scene nor the world is passed over.
    fn connections(l: *Loading) anyerror!void {
        try l.open(.array_begin, "the connections, which are a list");
        var place: usize = 0;
        while (true) : (place += 1) {
            const token = try l.next();
            if (token == .array_end) return;
            if (token != .object_begin) return l.wrong("a connection, which is an object", token);
            const mark = l.path.push("{d}", .{place});
            defer l.path.pop(mark);

            var from: ?Entity = null;
            var to: ?Entity = null;
            var signal: ?[]const u8 = null;
            var method: ?[]const u8 = null;
            var options: signals.Options = .{ .flags = .{ .persist = true } };
            var binds: std.ArrayList(signals.Bind) = .empty;
            while (try l.key()) |field| {
                if (std.mem.eql(u8, field, "from") or std.mem.eql(u8, field, "to")) {
                    const end = try l.connectionEnd();
                    if (field[0] == 'f') from = end else to = end;
                } else if (std.mem.eql(u8, field, "signal") or std.mem.eql(u8, field, "method")) {
                    const text = switch (try l.next()) {
                        .string => |text| try l.arena.dupe(u8, text),
                        else => |other| return l.wrong("a name", other),
                    };
                    if (field[0] == 's') signal = text else method = text;
                } else if (std.mem.eql(u8, field, "flags")) {
                    try l.open(.array_begin, "the flags, which are a list");
                    while (true) {
                        const flag = switch (try l.next()) {
                            .array_end => break,
                            .string => |text| text,
                            else => |other| return l.wrong("a flag's name", other),
                        };
                        // A flag, not a `break`: control flow that leaves an
                        // `inline for` under a run-time test is refused.
                        var matched = false;
                        inline for (.{ "deferred", "persist", "one_shot", "reference_counted", "append_source" }) |known| {
                            if (!matched and std.mem.eql(u8, flag, known)) {
                                @field(options.flags, known) = true;
                                matched = true;
                            }
                        }
                        if (!matched) return l.fail(error.WrongType, "\"{s}\" is not a flag: the flags are deferred, persist, one_shot, reference_counted and append_source", .{flag});
                    }
                } else if (std.mem.eql(u8, field, "unbinds")) {
                    try readValue(l, u8, &options.unbinds);
                } else if (std.mem.eql(u8, field, "binds")) {
                    try l.open(.array_begin, "the binds, which are a list");
                    while (try l.bind()) |b| try binds.append(l.arena, b);
                } else try l.reader.skipValue();
            }
            const named = signal orelse return l.fail(error.WrongType, "a connection names its \"signal\"", .{});
            const called = method orelse return l.fail(error.WrongType, "a connection names its \"method\"", .{});
            if (from == null or to == null) {
                l.connections_skipped += 1;
                continue;
            }
            options.binds = binds.items;
            const callable: signals.Callable = .method(to.?, called);
            // A signal nothing declares, or a bare name two components
            // declare now, is kept as written and never heard.
            const heard: ?signals.Signal = l.app.signalNamed(from.?, named) catch null;
            const made = if (heard) |s| s.connect(callable, options) else l.app.signals.connect(from.?, .{ .name = named }, callable, options);
            made catch |err| switch (err) {
                // The same scene's connection read twice keeps the one.
                error.AlreadyConnected => {},
                else => return err,
            };
            if (heard == null or !l.app.hasMethod(to.?, called)) l.connections_unknown += 1;
        }
    }

    /// A connection's `from` or `to`: the entity with that UUID, in the
    /// scene first and then the world, or null when neither has it.
    fn connectionEnd(l: *Loading) anyerror!?Entity {
        const text = switch (try l.next()) {
            .string => |text| text,
            else => |other| return l.wrong("an entity's UUID", other),
        };
        const uuid = Uuid.parse(text) catch return l.fail(error.WrongType, "an entity is named by its UUID, and \"{s}\" is not one", .{text});
        if (l.told.?.places.get(uuid)) |place| return l.entities[place];
        return l.app.findUuid(uuid);
    }

    /// One of a connection's binds, or null at the list's end: a bool, a
    /// number, text, or `{ "vec2": [x, y] }`, `{ "color": [r, g, b, a] }`,
    /// `{ "entity": uuid }`.
    fn bind(l: *Loading) anyerror!?signals.Bind {
        return switch (try l.next()) {
            .array_end => null,
            .bool => |b| .{ .bool = b },
            .number => |n| if (n.isInteger())
                .{ .int = n.asInt(i64) orelse return l.fail(error.WrongType, "{s} is too big for a bind", .{n.text}) }
            else
                .{ .float = n.asFloat(f64) },
            .string => |text| .{ .string = try l.arena.dupe(u8, text) },
            .object_begin => blk: {
                const kind = (try l.key()) orelse return l.fail(error.WrongType, "a bind's object names what it is", .{});
                const made: signals.Bind = if (std.mem.eql(u8, kind, "vec2")) vec: {
                    var v: math.Vec2 = undefined;
                    try l.numbers(&.{ &v.x, &v.y });
                    break :vec .{ .vec2 = v };
                } else if (std.mem.eql(u8, kind, "color")) colour: {
                    var c: Color = undefined;
                    try l.numbers(&.{ &c.r, &c.g, &c.b, &c.a });
                    break :colour .{ .color = c };
                } else if (std.mem.eql(u8, kind, "entity")) entity: {
                    var e: Entity = .none;
                    try readValue(l, Entity, &e);
                    break :entity .{ .entity = e };
                } else return l.fail(error.WrongType, "\"{s}\" is not a bind: they are vec2, color and entity, besides bools, numbers and text", .{kind});
                try l.open(.object_end, "the end of the bind");
                break :blk made;
            },
            else => |other| l.wrong("a bind", other),
        };
    }

    /// A list of exactly these numbers.
    fn numbers(l: *Loading, into: []const *f32) anyerror!void {
        try l.open(.array_begin, "a list of numbers");
        for (into) |out| try readValue(l, f32, out);
        try l.open(.array_end, "the end of the list");
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

    /// Where a file the scene names is now, and what `assets` says of it:
    /// by its UUID first - counted in `moved` when that is somewhere else -
    /// and by its path when no `.uid` file holds the UUID.
    fn file(l: *Loading, path: []const u8) anyerror!struct { []const u8, FileInfo } {
        const told = l.told.?;
        const info = told.files.get(path) orelse return .{ path, .{} };
        const uid = info.uid orelse return .{ path, info };
        const now = (try l.app.project.pathOf(uid)) orelse return .{ path, info };
        if (std.mem.eql(u8, now, path)) return .{ path, info };
        l.moved += 1;
        return .{ try l.arena.dupe(u8, now), info };
    }

    fn texture(l: *Loading, path: []const u8) anyerror!TextureHandle {
        if (l.textures.get(path)) |known| return known;
        const where, const info = try l.file(path);
        const assets = &l.app.assets;
        const handle = assets.findTexture(where) orelse assets.loadTexture(where, .{ .filter = info.filter, .wrap = info.wrap }) catch |err|
            return l.fail(err, "cannot read the texture \"{s}\": {t}", .{ where, err });
        try l.textures.put(l.arena, try l.arena.dupe(u8, path), handle);
        return handle;
    }

    /// A script the scene names. One that does not compile is still loaded,
    /// and the scene opens with it: its `Script` makes nothing until a
    /// reload compiles.
    fn script(l: *Loading, path: []const u8) anyerror!ScriptHandle {
        if (l.scripts.get(path)) |known| return known;
        const where, _ = try l.file(path);
        const handle = l.app.loadScript(where) catch |err|
            return l.fail(err, "cannot read the script \"{s}\": {t}", .{ where, err });
        try l.scripts.put(l.arena, try l.arena.dupe(u8, path), handle);
        return handle;
    }

    /// A tile set the scene names. One that does not read is still loaded,
    /// and the scene opens with it: its maps draw white squares until it
    /// does.
    fn tileSet(l: *Loading, path: []const u8) anyerror!TileSetHandle {
        if (l.tile_sets.get(path)) |known| return known;
        const where, _ = try l.file(path);
        const handle = l.app.loadTileSet(where) catch |err|
            return l.fail(err, "cannot read the tile set \"{s}\": {t}", .{ where, err });
        try l.tile_sets.put(l.arena, try l.arena.dupe(u8, path), handle);
        return handle;
    }

    fn font(l: *Loading, path: []const u8, member: u32) anyerror!FontHandle {
        // Kept by the file and the member: two fonts of one collection are
        // two fonts.
        const name = if (member == 0) path else try std.fmt.allocPrint(l.arena, "{s}\x00{d}", .{ path, member });
        if (l.fonts.get(name)) |known| return known;
        const where, _ = try l.file(path);
        const assets = &l.app.assets;
        const handle = assets.findFontMember(where, member) orelse assets.loadFont(where, .{ .member = member }) catch |err| {
            if (member == 0) return l.fail(err, "cannot read the font \"{s}\": {t}", .{ where, err });
            return l.fail(err, "cannot read font {d} of the collection \"{s}\": {t}", .{ member, where, err });
        };
        try l.fonts.put(l.arena, try l.arena.dupe(u8, name), handle);
        return handle;
    }

    /// A font written as an object: its file, and which font of the file it
    /// is. The object itself has begun.
    fn fontObject(l: *Loading) anyerror!FontHandle {
        var path: ?[]const u8 = null;
        var member: u32 = 0;
        while (try l.key()) |field| {
            if (std.mem.eql(u8, field, "file")) {
                const mark = l.path.push("file", .{});
                const token = try l.next();
                path = switch (token) {
                    .string => |text| try l.arena.dupe(u8, text),
                    else => return l.wrong("the file it was read from", token),
                };
                l.path.pop(mark);
            } else if (std.mem.eql(u8, field, "member")) {
                const mark = l.path.push("member", .{});
                try readValue(l, u32, &member);
                l.path.pop(mark);
            } else try l.reader.skipValue();
        }
        const named = path orelse return l.fail(error.WrongType, "a font written as an object names its \"file\"", .{});
        return l.font(named, member);
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
    if (comptime isBufferedText(T)) {
        out.bytes = @splat(0);
        out.len = 0;
    }
    if (T == LineEdit) {
        out.placeholder = @splat(0);
        out.placeholder_len = 0;
    }
    while (try l.key()) |name| {
        if (comptime isBufferedText(T)) if (std.mem.eql(u8, name, "text")) {
            try readText(l, out);
            continue;
        };
        if (T == TileMap and std.mem.eql(u8, name, "cells")) {
            const mark = l.path.push("cells", .{});
            try readCells(l);
            l.path.pop(mark);
            continue;
        }
        if (T == LineEdit and std.mem.eql(u8, name, "placeholder_text")) {
            try readPlaceholder(l, out);
            continue;
        }
        var matched = false;
        inline for (fields, 0..) |field, i| {
            const hidden = (comptime isBufferedText(T) and isTextBuffer(field.name)) or (T == LineEdit and isPlaceholderBuffer(field.name));
            if (!hidden and !matched and std.mem.eql(u8, name, field.name)) {
                matched = true;
                seen.set(i);
                const mark = l.path.push("{s}", .{field.name});
                if (comptime T == Script and std.mem.eql(u8, field.name, "struct_name")) {
                    try readStructName(l, out);
                } else try readValue(l, field.type, &@field(out.*, field.name));
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
        const hidden = (comptime isBufferedText(T) and isTextBuffer(field.name)) or (T == LineEdit and isPlaceholderBuffer(field.name));
        if (!hidden and !seen.isSet(i)) {
            @field(out.*, field.name) = field.defaultValue() orelse
                return l.fail(error.MissingField, "{s} has no {s}, and it has no default to take", .{ nameOf(T), field.name });
        }
    }
}

/// A `Script`'s struct name, written as the text it is.
fn readStructName(l: *Loading, out: *Script) anyerror!void {
    const token = try l.next();
    const text = switch (token) {
        .string => |text| text,
        else => return l.wrong("the name of a struct in the script", token),
    };
    if (text.len > out.struct_name.len) return l.fail(error.OutOfRange, "a struct name is {d} bytes, and a Script holds {d}", .{ text.len, out.struct_name.len });
    out.struct_name = @splat(0);
    @memcpy(out.struct_name[0..text.len], text);
}

fn readText(l: *Loading, out: anytype) anyerror!void {
    const T = @TypeOf(out.*);
    const token = try l.next();
    const text = switch (token) {
        .string => |text| text,
        else => return l.wrong("the words of the text", token),
    };
    if (text.len > T.capacity) return l.fail(error.OutOfRange, "this text is {d} bytes, and a {s} holds {d}", .{ text.len, nameOf(T), T.capacity });
    out.set(text);
}

fn readPlaceholder(l: *Loading, out: *LineEdit) anyerror!void {
    const token = try l.next();
    const text = switch (token) {
        .string => |text| text,
        else => return l.wrong("the placeholder text", token),
    };
    if (text.len > LineEdit.capacity) return l.fail(error.OutOfRange, "this placeholder is {d} bytes, and a LineEdit holds {d}", .{ text.len, LineEdit.capacity });
    out.setPlaceholder(text);
}

fn isBufferedText(comptime T: type) bool {
    return T == Text2D or T == Label or T == LineEdit;
}

/// One chunk of a map's tiles, read and waiting for the scene to be over.
const PendingChunk = struct {
    map: Entity,
    x: i32,
    y: i32,
    cells: [tilemap.tiles_per_chunk]tilemap.Cell,
};

/// A map's `cells`: a line of base64 under each chunk's place, as
/// `writeCells` put them. The chunks themselves are made once every value in
/// the scene has been written, by `read`.
fn readCells(l: *Loading) anyerror!void {
    try l.open(.object_begin, "the map's tiles, which is an object of its chunks");
    while (try l.key()) |name| {
        const mark = l.path.push("{s}", .{name});
        const comma = std.mem.indexOfScalar(u8, name, ',') orelse
            return l.fail(error.WrongType, "\"{s}\" is not a chunk's place, which is written \"x,y\"", .{name});
        const x = std.fmt.parseInt(i32, name[0..comma], 10) catch
            return l.fail(error.WrongType, "\"{s}\" is not a chunk's place, which is written \"x,y\"", .{name});
        const y = std.fmt.parseInt(i32, name[comma + 1 ..], 10) catch
            return l.fail(error.WrongType, "\"{s}\" is not a chunk's place, which is written \"x,y\"", .{name});

        const token = try l.next();
        const text = switch (token) {
            .string => |held| held,
            else => return l.wrong("a chunk's tiles, which is a line of base64", token),
        };
        var pending: PendingChunk = .{ .map = l.entity, .x = x, .y = y, .cells = undefined };
        const room = std.mem.asBytes(&pending.cells);
        const size = std.base64.standard.Decoder.calcSizeForSlice(text) catch
            return l.fail(error.WrongType, "a chunk's tiles are base64, and this is not", .{});
        if (size != room.len) return l.fail(error.OutOfRange, "a chunk is {d} bytes of tiles, and this is {d}", .{ room.len, size });
        std.base64.standard.Decoder.decode(room, text) catch
            return l.fail(error.WrongType, "a chunk's tiles are base64, and this is not", .{});

        if (l.chunks) |waiting| try waiting.append(l.app.gpa, pending);
        l.path.pop(mark);
    }
}

fn isPlaceholderBuffer(name: []const u8) bool {
    return std.mem.eql(u8, name, "placeholder") or std.mem.eql(u8, name, "placeholder_len");
}

/// A value inside a component. A nested struct may leave fields out too.
fn readValue(l: *Loading, comptime T: type, out: *T) anyerror!void {
    if (T == Entity) {
        const token = try l.next();
        out.* = switch (token) {
            .null => .none,
            .string => |text| blk: {
                const uuid = Uuid.parse(text) catch return l.fail(error.WrongType, "an entity is named by its UUID, and \"{s}\" is not one", .{text});
                if (l.told.?.places.get(uuid)) |place| break :blk l.entities[place];
                break :blk l.app.findUuid(uuid) orelse
                    return l.fail(error.NoSuchEntity, "no entity in this scene or in the world has the UUID {s}", .{text});
            },
            else => return l.wrong("an entity's UUID, or null", token),
        };
        return;
    }
    if (T == TextureHandle) {
        const token = try l.next();
        out.* = switch (token) {
            .null => .none,
            .string => |path| try l.texture(path),
            else => return l.wrong("the file it was read from, or null", token),
        };
        return;
    }
    if (T == ScriptHandle) {
        const token = try l.next();
        out.* = switch (token) {
            .null => .none,
            .string => |path| try l.script(path),
            else => return l.wrong("the file it was read from, or null", token),
        };
        return;
    }
    if (T == TileSetHandle) {
        const token = try l.next();
        out.* = switch (token) {
            .null => .none,
            .string => |path| try l.tileSet(path),
            else => return l.wrong("the file it was read from, or null", token),
        };
        return;
    }
    if (T == FontHandle) {
        const token = try l.next();
        out.* = switch (token) {
            .null => .none,
            .string => |path| try l.font(path, 0),
            .object_begin => try l.fontObject(),
            else => return l.wrong("the file it was read from, its file and member, or null", token),
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

/// What a token is, for a message: `the string "wide"`, `an object`. The
/// project file's reader says it the same way.
pub fn found(token: Token) Found {
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

/// UUIDs a test gives, so that what is written can be read off the page.
const fixed_uuids = [_]Uuid{
    .parseComptime("00000000-0000-4000-8000-000000000001"),
    .parseComptime("00000000-0000-4000-8000-000000000002"),
    .parseComptime("00000000-0000-4000-8000-000000000003"),
};

test "a scene reads as what it holds, and leaves out what is the default" {
    const app = try headless();
    defer app.destroy();
    try app.registerComponents(.{Wander});

    const camera = try app.world.spawnWith(.{ Transform2D.at(320, 180), Camera2D{} });
    try app.setName(camera, "camera");
    var label: Text2D = .of("Hi");
    label.size = 13;
    const words = try app.world.spawnWith(.{ Transform2D.childOf(camera, 0, -6), label });
    const wanderer = try app.world.spawnWith(.{Wander{ .dx = 1, .mood = .cross, .leader = camera }});
    for ([_]Entity{ camera, words, wanderer }, fixed_uuids) |e, uuid| try app.setUuid(e, uuid);

    const text = try write(app, testing.allocator, .{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\{
        \\  "fluxion_scene": 2,
        \\  "entities": [
        \\    {
        \\      "uuid": "00000000-0000-4000-8000-000000000001",
        \\      "name": "camera",
        \\      "Transform2D": { "x": 320.0, "y": 180.0 },
        \\      "Camera2D": {}
        \\    },
        \\    {
        \\      "uuid": "00000000-0000-4000-8000-000000000002",
        \\      "Transform2D": {
        \\        "y": -6.0,
        \\        "parent": "00000000-0000-4000-8000-000000000001"
        \\      },
        \\      "Text2D": { "text": "Hi", "size": 13.0 }
        \\    },
        \\    {
        \\      "uuid": "00000000-0000-4000-8000-000000000003",
        \\      "Wander": {
        \\        "dx": 1.0,
        \\        "mood": "cross",
        \\        "leader": "00000000-0000-4000-8000-000000000001"
        \\      }
        \\    }
        \\  ]
        \\}
    , text);
}

test "a UI label keeps its buffered text through a scene round trip" {
    const source = try headless();
    defer source.destroy();
    var words = Label.of("Hello UI");
    words.outline_width = 2;
    try source.setName(try source.world.spawnWith(.{words}), "words");
    var field = LineEdit.of("Player");
    field.setPlaceholder("Name");
    try source.setName(try source.world.spawnWith(.{field}), "field");

    const text = try write(source, testing.allocator, .{});
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"text\": \"Hello UI\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"placeholder_text\": \"Name\"") != null);

    const copy = try headless();
    defer copy.destroy();
    _ = try read(copy, text, .{});
    const label = copy.world.get(copy.find("words").?, Label).?;
    try testing.expectEqualStrings("Hello UI", label.slice());
    try testing.expectEqual(@as(u16, 2), label.outline_width);
    const line = copy.world.get(copy.find("field").?, LineEdit).?;
    try testing.expectEqualStrings("Player", line.slice());
    try testing.expectEqualStrings("Name", line.placeholderSlice());
}

test "a map writes its tiles with itself, and its chunks are not in the scene" {
    const source = try headless();
    defer source.destroy();
    const map = try source.world.spawnWith(.{ Transform2D{}, TileMap{} });
    try source.setName(map, "level");
    _ = try source.setTile(map, -2, 18, tilemap.Cell.at(1, 7, 3).with(tilemap.Cell.flip_h, true));
    _ = try source.setTile(map, 0, 0, .at(0, 1, 1));

    const text = try write(source, testing.allocator, .{});
    defer testing.allocator.free(text);
    // Two chunks of tiles, and no entity of their own for either.
    try testing.expect(std.mem.indexOf(u8, text, "\"cells\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"TileChunk\"") == null);
    // A kilobyte of tiles is a line, not a thousand numbers.
    try testing.expect(text.len < 4000);

    const copy = try headless();
    defer copy.destroy();
    _ = try read(copy, text, .{});

    const loaded = copy.find("level").?;
    const cell = copy.tileAt(loaded, -2, 18);
    try testing.expectEqual(@as(u8, 1), cell.source);
    try testing.expectEqual(@as(u8, 7), cell.x);
    try testing.expectEqual(@as(u8, 3), cell.y);
    try testing.expect(cell.has(tilemap.Cell.flip_h));
    try testing.expect(copy.tileChunkAt(loaded, -1, 1) != null);
    try testing.expectEqual(@as(u8, 1), copy.tileAt(loaded, 0, 0).x);
    try testing.expect(copy.tileAt(loaded, 5, 5).isEmpty());
}

test "a map keeps the tile set it was saved with" {
    const source = try headless();
    defer source.destroy();
    const set = try source.addTileSet("res://terrain.tileset", "{ \"fluxion_tileset\": 1 }");
    const map = try source.world.spawnWith(.{ Transform2D{}, TileMap{ .tile_set = set } });
    try source.setName(map, "level");

    const text = try write(source, testing.allocator, .{});
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "res://terrain.tileset") != null);
}

test "every entity written is given a UUID, and keeps it" {
    const app = try headless();
    defer app.destroy();
    const camera = try app.world.spawnWith(.{Transform2D{}});
    try testing.expect(app.uuidOf(camera) == null);

    const first = try write(app, testing.allocator, .{});
    defer testing.allocator.free(first);
    const given = app.uuidOf(camera).?;
    try testing.expectEqual(@as(u4, 4), given.version());

    const second = try write(app, testing.allocator, .{});
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
}

test "one entity is written as a scene writes it, or with every field for an inspector" {
    const app = try headless();
    defer app.destroy();
    const camera = try app.world.spawnWith(.{ Transform2D.at(4, 8), Camera2D{} });
    try app.setName(camera, "camera");
    const child = try app.world.spawnWith(.{Transform2D.childOf(camera, 0, 2)});
    try app.setUuid(camera, fixed_uuids[0]);
    try app.setUuid(child, fixed_uuids[1]);

    const brief = try json.stringify(testing.allocator, EntityJson{ .app = app, .entity = child }, .{});
    defer testing.allocator.free(brief);
    try testing.expectEqualStrings(
        "{\"uuid\":\"00000000-0000-4000-8000-000000000002\",\"Transform2D\":{\"y\":2.0,\"parent\":\"00000000-0000-4000-8000-000000000001\"}}",
        brief,
    );

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

    // Saved once first, which gives the texture its `.uid` file, so what is
    // written below names it by that as a copy will.
    var first_buf: [160]u8 = undefined;
    try source.saveScene(try std.fmt.bufPrint(&first_buf, "{s}/first.json", .{dir}), .{});
    const expected = try write(source, testing.allocator, .{});
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.indexOf(u8, expected, "\"filter\": \"linear\"") != null);
    try testing.expect(std.mem.indexOf(u8, expected, "\"uid\": \"uid://") != null);

    for ([_]json.Format{ .json, .cbor }) |format| {
        var path_buf: [160]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/level.{t}", .{ dir, format });
        try source.saveScene(path, .{ .format = format });

        const copy = try headless();
        defer copy.destroy();
        try copy.registerComponents(.{Wander});
        const loaded = try copy.loadScene(path, .{});
        try testing.expectEqual(@as(usize, 4), loaded.entities);
        try testing.expectEqual(@as(usize, 0), loaded.components_unknown);

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

/// A project of a test's own: a directory, a PNG in it, and its path.
const Game = struct {
    tmp: testing.TmpDir,
    buffer: [128]u8 = undefined,
    root: []const u8 = "",

    fn init() !Game {
        var game: Game = .{ .tmp = testing.tmpDir(.{}) };
        try game.tmp.dir.createDirPath(testing.io, "art");
        return game;
    }

    fn at(game: *Game) ![]const u8 {
        game.root = try std.fmt.bufPrint(&game.buffer, ".zig-cache/tmp/{s}", .{game.tmp.sub_path});
        return game.root;
    }

    fn picture(game: *Game, path: []const u8) !void {
        var buffer: [192]u8 = undefined;
        const file = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ game.root, path });
        try image.png.writeFile(testing.allocator, testing.io, file, .{ .width = 1, .height = 1, .pixels = &.{ 255, 255, 255, 255 }, .row_pitch = 4 }, .{});
    }

    fn app(game: *Game) !*App {
        return App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = game.root });
    }
};

test "a project's file is written by its res:// path and its UUID, and found by the UUID when it moves" {
    var game: Game = try .init();
    defer game.tmp.cleanup();
    _ = try game.at();
    try game.picture("art/hero.png");

    const source = try game.app();
    defer source.destroy();
    // By the operating system's path: kept by the project's all the same.
    var buffer: [192]u8 = undefined;
    const hero = try source.assets.loadTexture(try std.fmt.bufPrint(&buffer, "{s}/art/hero.png", .{game.root}), .{});
    _ = try source.world.spawnWith(.{ Transform2D.at(1, 2), Sprite.of(hero) });
    try source.saveScene("res://levels/meadow.json", .{});
    const uid = source.project.knownUid("res://art/hero.png").?;

    var saved_buffer: [2048]u8 = undefined;
    const saved = try game.tmp.dir.readFile(testing.io, "levels/meadow.json", &saved_buffer);
    try testing.expect(std.mem.indexOf(u8, saved, "\"texture\": \"res://art/hero.png\"") != null);
    var line: [64]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, saved, try std.fmt.bufPrint(&line, "\"uid\": \"uid://{f}\"", .{uid})) != null);

    // Moved and renamed, with its `.uid` file.
    try game.tmp.dir.createDirPath(testing.io, "art/people");
    try game.tmp.dir.rename("art/hero.png", game.tmp.dir, "art/people/ada.png", testing.io);
    try game.tmp.dir.rename("art/hero.png.uid", game.tmp.dir, "art/people/ada.png.uid", testing.io);

    const copy = try game.app();
    defer copy.destroy();
    const loaded = try copy.loadScene("res://levels/meadow.json", .{});
    try testing.expectEqual(@as(usize, 1), loaded.moved);
    const sheet = copy.single(Sprite).?.texture;
    try testing.expectEqualStrings("res://art/people/ada.png", copy.assets.textureSource(sheet).?);
}

test "a version 1 scene is refused, and says so, rather than read another way" {
    const app = try headless();
    defer app.destroy();
    var diagnostics: json.Diagnostics = .{};
    try testing.expectError(error.UnsupportedVersion, read(app,
        \\{ "fluxion_scene": 1, "entities": [
        \\  { "name": "tank" },
        \\  { "Transform2D": { "parent": 0 } }
        \\] }
    , .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("this scene is version 1, an older one this engine no longer reads: it reads version 2", diagnostics.message());
    try testing.expectEqual(@as(usize, 0), app.world.count());

    // Nor is an entity named by its place in the list any more.
    try testing.expectError(error.WrongType, read(app,
        \\{ "fluxion_scene": 2, "entities": [{ "name": "tank" }, { "Transform2D": { "parent": 0 } }] }
    , .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("expected an entity's UUID, or null, found the number 0", diagnostics.message());
    try testing.expectEqual(@as(usize, 0), app.world.count());
}

test "a scene loaded twice gives the second copy UUIDs of its own, and its references stay inside it" {
    const app = try headless();
    defer app.destroy();
    const text =
        \\{ "fluxion_scene": 2, "entities": [
        \\  { "uuid": "11111111-1111-4111-8111-111111111111", "name": "tank", "Transform2D": { "x": 1 } },
        \\  { "uuid": "22222222-2222-4222-8222-222222222222", "Transform2D": { "parent": "11111111-1111-4111-8111-111111111111" } }
        \\] }
    ;
    const tank_uuid: Uuid = .parseComptime("11111111-1111-4111-8111-111111111111");
    try testing.expectEqual(@as(usize, 0), (try read(app, text, .{})).reassigned);
    const tank = app.findUuid(tank_uuid).?;
    try testing.expect(tank.eql(app.find("tank").?));

    app.clearWorld();
    try testing.expect(app.findUuid(tank_uuid) == null);
    try testing.expectEqual(@as(usize, 0), (try read(app, text, .{})).reassigned);
    const again = app.findUuid(tank_uuid).?;

    // The same scene beside it: new UUIDs, and a child of its own tank.
    var copy = text.*;
    std.mem.replaceScalar(u8, &copy, 'k', 'q');
    try testing.expectEqual(@as(usize, 2), (try read(app, &copy, .{})).reassigned);
    try testing.expect(app.findUuid(tank_uuid).?.eql(again));
    const second_tank = app.find("tanq").?;
    try testing.expect(!app.uuidOf(second_tank).?.eql(tank_uuid));

    var parents: [2]Entity = undefined;
    var count: usize = 0;
    var it = try ecs.Query(.{Transform2D}).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(Transform2D)) |place| {
            if (place.parent.isNone()) continue;
            parents[count] = place.parent;
            count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(parents[0].eql(again) != parents[1].eql(again));
    try testing.expect(parents[0].eql(second_tank) or parents[1].eql(second_tank));
}

test "an entity another scene brought is found by its UUID" {
    const app = try headless();
    defer app.destroy();
    const door = try app.world.spawnWith(.{Transform2D.at(3, 4)});
    try app.setUuid(door, fixed_uuids[2]);
    _ = try read(app,
        \\{ "fluxion_scene": 2, "entities": [
        \\  { "name": "handle", "Transform2D": { "parent": "00000000-0000-4000-8000-000000000003" } }
        \\] }
    , .{});
    try testing.expect(app.world.get(app.find("handle").?, Transform2D).?.parent.eql(door));
}

test "a UUID given twice, or naming nothing, is a mistake that says where it is" {
    const app = try headless();
    defer app.destroy();
    var diagnostics: json.Diagnostics = .{};

    try testing.expectError(error.DuplicateUuid, read(app,
        \\{ "fluxion_scene": 2, "entities": [
        \\  { "uuid": "11111111-1111-4111-8111-111111111111" },
        \\  { "uuid": "11111111-1111-4111-8111-111111111111" }
        \\] }
    , .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("another entity in this scene has this UUID already", diagnostics.message());
    try testing.expectEqualStrings("/entities/1/uuid", diagnostics.path());

    try testing.expectError(error.NoSuchEntity, read(app,
        \\{ "fluxion_scene": 2, "entities": [
        \\  { "Transform2D": { "parent": "44444444-4444-4444-8444-444444444444" } }
        \\] }
    , .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("no entity in this scene or in the world has the UUID 44444444-4444-4444-8444-444444444444", diagnostics.message());
    try testing.expectEqualStrings("/entities/0/Transform2D/parent", diagnostics.path());

    try testing.expectError(error.WrongType, read(app,
        \\{ "fluxion_scene": 2, "entities": [{ "uuid": "tank" }] }
    , .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("\"tank\" is not a UUID", diagnostics.message());
    try testing.expectEqual(@as(usize, 0), app.world.count());
}

test "a component nothing here knows is kept, a field or a member nothing knows is passed over, and what a scene lacks is the default" {
    const app = try headless();
    defer app.destroy();
    const loaded = try read(app,
        \\{ "fluxion_scene": 2, "entities": [
        \\  { "name": "odd", "Transform2D": { "x": 5, "wobble": 3 }, "Mystery": { "a": [1, 2] } },
        \\  { "name": "empty" }
        \\], "future": true }
    , .{});
    try testing.expectEqual(@as(usize, 2), loaded.entities);
    try testing.expectEqual(@as(usize, 1), loaded.components_unknown);
    const kept = app.unknownComponentsOf(app.find("odd").?);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("Mystery", kept[0].name);
    try testing.expectEqualStrings("{\"a\":[1,2]}", kept[0].value);
    try testing.expectEqual(@as(usize, 0), app.unknownComponentsOf(app.find("empty").?).len);

    const place = app.single(Transform2D).?;
    try testing.expectEqual(@as(f32, 5), place.x);
    try testing.expectEqual(@as(f32, 1), place.scale_x);
    try testing.expect(place.parent.isNone());
    try testing.expect(app.find("empty") != null);
}

/// A game's component that an editor meets only later, if at all.
const Later = extern struct {
    n: i32 = 0,

    pub const scene_name = "Later";
};

test "a component nothing here knows is written back as it was read, from JSON and from CBOR" {
    const app = try headless();
    defer app.destroy();
    const loaded = try read(app,
        \\{ "fluxion_scene": 2, "entities": [
        \\  { "name": "odd", "Mystery": { "big": 18446744073709551615, "half": -0.5, "odd": NaN,
        \\      "text": "a \"quoted\"\nline ✓", "list": [true, false, null, { "deep": [[]] }] },
        \\    "Transform2D": { "x": 5 }, "Later": 7 },
        \\  { "name": "plain", "Transform2D": {} }
        \\] }
    , .{});
    try testing.expectEqual(@as(usize, 2), loaded.components_unknown);
    const odd = app.find("odd").?;
    const mystery = "{\"big\":18446744073709551615,\"half\":-0.5,\"odd\":NaN,\"text\":\"a \\\"quoted\\\"\\nline ✓\",\"list\":[true,false,null,{\"deep\":[[]]}]}";
    const kept = app.unknownComponentsOf(odd);
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expectEqualStrings("Mystery", kept[0].name);
    try testing.expectEqualStrings(mystery, kept[0].value);
    try testing.expectEqualStrings("Later", kept[1].name);
    try testing.expectEqualStrings("7", kept[1].value);

    // Written after the registered ones, in the order read.
    const text = try write(app, testing.allocator, .{ .indent = 0 });
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"Transform2D\":{\"x\":5.0},\"Mystery\":" ++ mystery ++ ",\"Later\":7}") != null);
    const one = try json.stringify(testing.allocator, EntityJson{ .app = app, .entity = odd }, .{});
    defer testing.allocator.free(one);
    try testing.expect(std.mem.indexOf(u8, one, "\"Later\":7") != null);

    // Through CBOR and back, every digit and every character stays.
    const bytes = try write(app, testing.allocator, .{ .format = .cbor });
    defer testing.allocator.free(bytes);
    const again = try headless();
    defer again.destroy();
    _ = try read(again, bytes, .{});
    const round = again.unknownComponentsOf(again.find("odd").?);
    try testing.expectEqual(@as(usize, 2), round.len);
    try testing.expectEqualStrings(mystery, round[0].value);
    try testing.expectEqualStrings("7", round[1].value);
    const text_again = try write(again, testing.allocator, .{ .indent = 0 });
    defer testing.allocator.free(text_again);
    try testing.expectEqualStrings(text, text_again);

    // Once the game's component is here and on the entity, it is what the
    // entity holds, and what is written.
    try app.registerComponents(.{Later});
    _ = try app.addComponentNamed(odd, "Later");
    const known = try write(app, testing.allocator, .{ .indent = 0 });
    defer testing.allocator.free(known);
    try testing.expect(std.mem.indexOf(u8, known, "\"Later\":{}") != null);
    try testing.expect(std.mem.indexOf(u8, known, "\"Later\":7") == null);

    // Taken off by name, and forgotten with the entity or the world.
    try app.removeComponentNamed(odd, "Mystery");
    try testing.expectEqual(@as(usize, 1), app.unknownComponentsOf(odd).len);
    try testing.expectError(error.NoSuchComponent, app.removeComponentNamed(odd, "Mystery"));
    const plain = again.find("plain").?;
    try testing.expectError(error.NoSuchComponent, again.removeComponentNamed(plain, "Mystery"));
    app.world.despawn(odd);
    try testing.expectEqual(@as(usize, 0), app.unknownComponentsOf(odd).len);
    try testing.expectError(error.NoSuchEntity, app.removeComponentNamed(odd, "Later2"));
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.unknown_components.by_entity.count());
    _ = try again.step();
    try testing.expectEqual(@as(usize, 1), again.unknown_components.by_entity.count());
    again.clearWorld();
    try testing.expectEqual(@as(usize, 0), again.unknown_components.by_entity.count());
}

test "a mistake in a scene says where it is, and leaves the world as it was" {
    const app = try headless();
    defer app.destroy();
    _ = try app.world.spawnWith(.{Transform2D.at(1, 1)});

    const text =
        \\{ "fluxion_scene": 2, "entities": [
        \\  { "name": "first", "Transform2D": { "x": 5 } },
        \\  { "Transform2D": { "parent": "77777777-7777-4777-8777-777777777777" } }
        \\] }
    ;
    var diagnostics: json.Diagnostics = .{};
    try testing.expectError(error.NoSuchEntity, read(app, text, .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("no entity in this scene or in the world has the UUID 77777777-7777-4777-8777-777777777777", diagnostics.message());
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
        \\{ "fluxion_scene": 2, "entities": [{ "Sprite": { "width": "wide" } }] }
    , .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("expected a number, found the string \"wide\"", diagnostics.message());
    try testing.expectEqualStrings("/entities/0/Sprite/width", diagnostics.path());
    try testing.expectEqual(@as(usize, 1), app.world.count());
}

test "numbers no hand would give load, and the frames after them do not crash" {
    // The colliders that get no shape are said so in warnings, which are the
    // point and need not fill the test's output.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    const app = try headless();
    defer app.destroy();
    _ = app.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 64 }) catch {};
    const loaded = try read(app,
        \\{ "fluxion_scene": 2, "entities": [
        \\  { "Transform2D": { "x": NaN, "y": Infinity, "scale_x": 0 }, "Sprite": { "width": NaN },
        \\    "Animation": { "columns": 0, "rows": 0, "length": 4, "fps": 1e39, "time": NaN } },
        \\  { "Transform2D": {}, "Sprite": {}, "Animation": { "columns": 0, "rows": 0, "length": 0, "fps": 1e39 } },
        \\  { "Transform2D": { "x": 1 }, "Camera2D": { "zoom": 0, "fit_width": NaN, "fit_height": Infinity } },
        \\  { "Transform2D": { "rotation": NaN }, "RigidBody2D": { "velocity": { "x": NaN, "y": 1 } },
        \\    "Collider2D": { "shape": "circle", "radius": -1 } },
        \\  { "Transform2D": {}, "RigidBody2D": { "gravity_scale": NaN },
        \\    "Collider2D": { "width": 10, "height": 10, "rotation": NaN } },
        \\  { "Transform2D": {}, "RigidBody2D": {}, "Collider2D": { "shape": "circle", "radius": -1, "offset_x": Infinity } },
        \\  { "Transform2D": { "x": Infinity }, "Collider2D": { "width": 4, "height": 4 } },
        \\  { "Transform2D": { "x": 5 }, "Text2D": { "text": "Hi", "size": 1e30, "line_spacing": NaN } },
        \\  { "Transform2D": { "x": 5 }, "Text2D": { "text": "Hi", "size": NaN } },
        \\  { "Transform2D": { "y": 50 },
        \\    "RigidBody2D": { "velocity": { "x": NaN, "y": Infinity }, "angular_velocity": NaN, "linear_damping": NaN, "gravity_scale": Infinity },
        \\    "Collider2D": { "width": 4, "height": 4, "density": NaN, "friction": NaN, "restitution": NaN } },
        \\  { "Transform2D": { "y": 51 }, "RigidBody2D": { "type": "static" }, "Collider2D": { "width": 40, "height": 4, "density": -1 } }
        \\] }
    , .{});
    try testing.expectEqual(@as(usize, 11), loaded.entities);

    // Words that are not UTF-8 never reach a label: a lone surrogate written
    // as an escape is read as U+FFFD, and a byte no UTF-8 has is a mistake.
    _ = try read(app,
        \\{ "fluxion_scene": 2, "entities": [{ "name": "surrogate", "Transform2D": {}, "Text2D": { "text": "a\uD800b" } }] }
    , .{});
    try testing.expectEqualStrings("a\u{FFFD}b", app.world.get(app.find("surrogate").?, Text2D).?.slice());
    try testing.expectError(error.SyntaxError, read(app, "{ \"fluxion_scene\": 2, \"entities\": [{ \"Text2D\": { \"text\": \"a\xffb\" } }] }", .{}));

    // And a label's bytes written by hand, past UTF-8 and past its buffer,
    // are neither drawn nor saved as they are.
    var broken: Text2D = .of("ok");
    broken.bytes[0] = 0xFF;
    _ = try app.world.spawnWith(.{ Transform2D{}, broken });
    var overlong: Text2D = .of("ok");
    overlong.len = 200;
    _ = try app.world.spawnWith(.{ Transform2D{}, overlong });
    const saved = try write(app, testing.allocator, .{});
    testing.allocator.free(saved);

    // Edited, and paused: bodies are made at the top of every frame.
    app.time.scale = 0;
    for (0..3) |_| _ = try app.step();
    // Played.
    app.time.scale = 1;
    for (0..5) |_| _ = try app.step();
}

test "a file that is not a scene, or a newer one, is refused" {
    const app = try headless();
    defer app.destroy();
    var diagnostics: json.Diagnostics = .{};

    try testing.expectError(error.NotAScene, read(app, "{ \"entities\": [] }", .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("this is not a scene: it has no \"fluxion_scene\" version", diagnostics.message());

    try testing.expectError(error.UnsupportedVersion, read(app, "{ \"fluxion_scene\": 3, \"entities\": [] }", .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("this scene is version 3, newer than this engine, which reads version 2", diagnostics.message());

    try testing.expectError(error.WrongType, read(app, "[1, 2]", .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("expected a scene, which is an object, found a list", diagnostics.message());
}

test "a scene says what it is and which files it names, without being loaded" {
    const text =
        \\{
        \\  // By hand, with what nothing here knows beside what it does.
        \\  "fluxion_scene": 2,
        \\  "made_by": { "tool": "an editor", "entities": [1, 2, 3] },
        \\  "entities": [
        \\    { "uuid": "00000000-0000-4000-8000-000000000001", "Sprite": { "texture": "res://art/hero.png" } },
        \\    { "Sprite": { "texture": "res://art/tree.png" } }
        \\  ],
        \\  "assets": {
        \\    "res://art/hero.png": { "uid": "uid://2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34", "filter": "linear" },
        \\    "res://art/tree.png": { "wrap": "repeat" },
        \\    "res://art/odd.png": { "uid": "not a uuid" }
        \\  }
        \\}
    ;
    var said = (try readInfo(testing.allocator, text, null)).?;
    defer said.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), said.version);
    try testing.expectEqual(json.Format.json, said.format);
    try testing.expectEqual(@as(usize, 2), said.entities);
    try testing.expectEqual(@as(usize, 3), said.files.len);
    try testing.expectEqualStrings("res://art/hero.png", said.files[0].path);
    try testing.expect(said.files[0].uid.?.eql(.parseComptime("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34")));
    try testing.expectEqualStrings("res://art/tree.png", said.files[1].path);
    try testing.expect(said.files[1].uid == null);
    try testing.expect(said.files[2].uid == null);
}

test "a scene in CBOR, or of another version, is told as it is" {
    const app = try headless();
    defer app.destroy();
    for (0..3) |_| _ = try app.world.spawnWith(.{Transform2D.at(1, 2)});
    const bytes = try write(app, testing.allocator, .{ .format = .cbor });
    defer testing.allocator.free(bytes);

    var binary = (try readInfo(testing.allocator, bytes, null)).?;
    defer binary.deinit(testing.allocator);
    try testing.expectEqual(json.Format.cbor, binary.format);
    try testing.expectEqual(@as(usize, 3), binary.entities);
    try testing.expectEqual(@as(u32, version), binary.version);

    // Refused by `read`, and told here, so a tool can say which it is.
    var old = (try readInfo(testing.allocator, "{ \"fluxion_scene\": 1, \"entities\": [{}, {}] }", null)).?;
    defer old.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), old.version);
    try testing.expectEqual(@as(usize, 2), old.entities);
}

test "what is not a scene is null, and a scene damaged past its version is a mistake that says where" {
    const gpa = testing.allocator;
    try testing.expect(try readInfo(gpa, "", null) == null);
    try testing.expect(try readInfo(gpa, "not JSON at all", null) == null);
    try testing.expect(try readInfo(gpa, "[1, 2]", null) == null);
    try testing.expect(try readInfo(gpa, "{ \"entities\": [] }", null) == null);
    try testing.expect(try readInfo(gpa, "{ \"fluxion_scene\": \"two\" }", null) == null);
    // Broken before it said it was a scene: as far as can be told, it is not.
    try testing.expect(try readInfo(gpa, "{ \"entities\": [ { , ], \"fluxion_scene\": 2 }", null) == null);

    var diagnostics: json.Diagnostics = .{};
    try testing.expectError(error.SyntaxError, readInfo(gpa, "{ \"fluxion_scene\": 2, \"entities\": [{}, ", &diagnostics));
    try testing.expectError(error.SyntaxError, readInfo(gpa, "{ \"fluxion_scene\": 2, \"assets\": { \"res://a.png\": { \"uid\": ", null));
    try testing.expect(diagnostics.message().len > 0);
}

test "an empty scene is a scene, with nothing in it, in either format" {
    const app = try headless();
    defer app.destroy();
    for ([_]json.Format{ .json, .cbor }) |format| {
        const bytes = try writeEmpty(testing.allocator, .{ .format = format });
        defer testing.allocator.free(bytes);

        var said = (try readInfo(testing.allocator, bytes, null)).?;
        defer said.deinit(testing.allocator);
        try testing.expectEqual(format, said.format);
        try testing.expectEqual(@as(usize, 0), said.entities);

        const loaded = try read(app, bytes, .{});
        try testing.expectEqual(@as(usize, 0), loaded.entities);
        // An empty list rather than none, for a person reading it.
        if (format == .json) try testing.expect(std.mem.indexOf(u8, bytes, "\"entities\": []") != null);
    }
    try testing.expectEqual(@as(usize, 0), app.world.count());
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
    const Described = extern struct {
        w: u8 = 0,
        pub const reflect_name = "DescribedMarker";
    };
    const Both = extern struct {
        w: u8 = 0,
        pub const reflect_name = "DescribedMarker";
        pub const scene_name = "WrittenMarker";
    };
};

test "a component's scene name is its scene_name, then its reflect_name, then its own" {
    try testing.expectEqualStrings("Marker", nameOf(Twins.First.Marker));
    try testing.expectEqualStrings("OtherMarker", nameOf(Twins.Renamed));
    try testing.expectEqualStrings("DescribedMarker", nameOf(Twins.Described));
    try testing.expectEqualStrings("WrittenMarker", nameOf(Twins.Both));
}

test "two components of one name need a scene_name to tell them apart" {
    const app = try headless();
    defer app.destroy();
    try app.registerComponents(.{Twins.First.Marker});
    try app.registerComponents(.{Twins.First.Marker});
    try testing.expectError(error.ComponentNameTaken, app.registerComponents(.{Twins.Second.Marker}));
    try app.registerComponents(.{Twins.Renamed});
    try testing.expect(app.scene_components.find("Marker") != null);
    try testing.expect(app.scene_components.find("OtherMarker") != null);

    // Two scene names and one reflect_name: the descriptions would clash, and
    // the second is refused before a scene can hold it.
    try app.registerComponents(.{Twins.Described});
    try testing.expectError(error.ComponentNameTaken, app.registerComponents(.{Twins.Both}));
    try testing.expect(app.scene_components.find("WrittenMarker") == null);
}

/// A TrueType collection the system has, by its path, or null. See
/// `Assets`' tests.
fn systemCollection() ?[]const u8 {
    const candidates = [_][]const u8{
        "C:/Windows/Fonts/YuGothM.ttc",
        "C:/Windows/Fonts/cambria.ttc",
        "C:/Windows/Fonts/msgothic.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
    };
    for (candidates) |path| {
        std.Io.Dir.cwd().access(testing.io, path, .{}) catch continue;
        return path;
    }
    return null;
}

test "a font of a collection is written as its file and member, and read back as that font" {
    const path = systemCollection() orelse return error.SkipZigTest;
    const source = try headless();
    defer source.destroy();
    const first = try source.assets.loadFont(path, .{ .atlas = 64 });
    const second = try source.assets.loadFont(path, .{ .atlas = 64, .member = 1 });

    var upright: Text2D = .of("a");
    upright.font = first;
    var other: Text2D = .of("b");
    other.font = second;
    try source.setName(try source.world.spawnWith(.{ Transform2D{}, upright }), "first");
    try source.setName(try source.world.spawnWith(.{ Transform2D{}, other }), "second");

    const text = try write(source, testing.allocator, .{});
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"member\": 1") != null);

    const copy = try headless();
    defer copy.destroy();
    _ = try read(copy, text, .{});
    const a = copy.world.get(copy.find("first").?, Text2D).?.font;
    const b = copy.world.get(copy.find("second").?, Text2D).?.font;
    try testing.expectEqual(@as(u32, 0), copy.assets.fontMember(a));
    try testing.expectEqual(@as(u32, 1), copy.assets.fontMember(b));
    try testing.expect(!std.meta.eql(a, b));

    // Written again, it is what was read.
    const again = try write(copy, testing.allocator, .{});
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(text, again);

    // An object with no file is a mistake that says so, not a crash.
    try testing.expectError(error.WrongType, read(copy,
        \\{ "fluxion_scene": 2, "entities": [{ "Transform2D": {}, "Text2D": { "font": { "member": 1 } } }] }
    , .{}));
}
