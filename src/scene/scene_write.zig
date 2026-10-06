// SPDX-License-Identifier: BSD-3-Clause

//! A world written down as a scene: every entity, its UUID, name, parent and
//! groups, and each registered component, a field at its default left out.
//! See `scene.zig` for the format.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const json = @import("fluxion_json");
const rhi = @import("fluxion_rhi");
const Uuid = @import("fluxion_id").Uuid;

const App = @import("../App.zig");
const AssetKind = @import("../assets/asset_kind.zig").AssetKind;
const Project = @import("../project/Project.zig");
const attr = @import("../reflect/attr.zig");
const signals = @import("../core/signals.zig");
const component_texts = @import("component_texts.zig");
const registry = @import("registry.zig");
const scene = @import("scene.zig");

const Entity = ecs.Entity;
const copyValue = registry.copyValue;
const version = scene.version;
const SaveOptions = scene.SaveOptions;

/// How a texture a scene points at is sampled, when it is not the way
/// `Assets.loadTexture` samples by default.
const TextureOptions = struct {
    filter: rhi.Filter = .nearest,
    wrap: rhi.Wrap = .clamp_to_edge,
};

/// Write a scene with nothing in it to `path`: see `App.createScene`. Never
/// over a file already there - `error.PathAlreadyExists`.
pub fn create(app: *App, path: []const u8, options: SaveOptions) !void {
    const io = app.io orelse return error.NoIo;
    const bytes = try writeEmpty(app.gpa, options);
    defer app.gpa.free(bytes);
    const file = try app.project.osPath(app.gpa, path);
    defer app.gpa.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = bytes, .flags = .{ .exclusive = true } });
}

/// Write `app`'s world to a file, named as `Project` names one. See
/// `App.saveScene`. A file of the project's that is loaded and has no UUID
/// is given one first, in a `.uid` file beside it, so the scene can name it
/// by that.
pub fn save(app: *App, io: std.Io, path: []const u8, options: SaveOptions) !void {
    try app.assets.ensureUids();
    try app.tile_sets.ensureUids(&app.project);
    try app.themes.ensureUids(&app.project);
    if (app.scripts) |scripts| try scripts.ensureUids();
    const file = try app.project.osPath(app.gpa, path);
    defer app.gpa.free(file);
    return json.save(io, file, Document{ .app = app, .root = options.root }, writeOptions(options));
}

/// Write `app`'s world into fresh memory. A file with no UUID yet is named
/// by its path alone: only `save` makes UUIDs for files. The caller frees it.
pub fn write(app: *App, gpa: Allocator, options: SaveOptions) json.StringifyError![]u8 {
    return json.stringify(gpa, Document{ .app = app, .root = options.root }, writeOptions(options));
}

/// A scene with nothing in it, into fresh memory: what a new level starts as,
/// written before anything is put in it. The caller frees it. See
/// `App.createScene`, which writes one to a file.
pub fn writeEmpty(gpa: Allocator, options: SaveOptions) json.StringifyError![]u8 {
    return json.stringify(gpa, Empty{}, writeOptions(options));
}

pub fn writeOptions(options: SaveOptions) json.WriteOptions {
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
    root: ?Entity = null,

    pub fn toJson(self: Document, w: *json.Writer) json.Writer.Error!void {
        const gpa = self.app.gpa;
        var saving: Saving = .{ .app = self.app, .root = self.root };
        defer saving.deinit(gpa);
        try saving.placeAll();

        try w.beginObject();
        try w.field("fluxion_scene", @as(u32, version));
        try w.key("entities");
        try w.beginArray();
        for (saving.order.items) |e| try saving.writeEntity(w, e);
        try w.endArray();
        try saving.writeConnections(w);
        try saving.writeFiles(w);
        try w.endObject();
    }
};

/// An entity's components as a scene writes them, every field of each, in
/// compact JSON: what `App.keepInstance` keeps an instance's root as its
/// scene made it by. Nothing else is given a UUID for it. The caller frees
/// it.
pub fn entityTemplate(app: *App, gpa: Allocator, entity: Entity) json.StringifyError![]u8 {
    return json.stringify(gpa, Template{ .app = app, .entity = entity }, .{ .indent = 0, .non_finite = .literal });
}

const Template = struct {
    app: *App,
    entity: Entity,

    pub fn toJson(self: Template, w: *json.Writer) json.Writer.Error!void {
        var saving: Saving = .{ .app = self.app, .every_field = true };
        defer saving.deinit(self.app.gpa);
        try saving.writeEntity(w, self.entity);
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
        var saving: Saving = .{ .app = self.app, .every_field = self.every_field };
        defer saving.deinit(self.app.gpa);
        try saving.placeAll();
        try saving.writeEntity(w, self.entity);
    }
};

pub const Saving = struct {
    app: *App,
    every_field: bool = false,
    /// See `SaveOptions.root`.
    root: ?Entity = null,
    /// What is written: its parent is named only when it is written too.
    written: std.AutoHashMapUnmanaged(Entity, void) = .empty,
    /// The entity being written, for a component whose value is kept beside
    /// it: a map's tiles.
    entity: Entity = .none,
    /// A shader's numbers written beside a value, when they are not an
    /// entity's: a material file's. See `writeValueTextWith`.
    params: ?[]const @import("../render/shaders.zig").Param = null,
    /// Every entity, in the order a scene lists them.
    order: std.ArrayList(Entity) = .empty,
    /// Every file written, under the name it was written by, for `assets`.
    files: std.StringArrayHashMapUnmanaged(TextureOptions) = .empty,

    fn deinit(saving: *Saving, gpa: Allocator) void {
        saving.order.deinit(gpa);
        saving.files.deinit(gpa);
        saving.written.deinit(gpa);
    }

    /// Every entity in the world, in the order a parent's children are in -
    /// the order `App.setSiblingIndex` and the scenes read put them in, and
    /// then the order their slots were handed out, which for a world built
    /// and never thinned is the order it was built in - and each given a
    /// UUID, if it had none, for what names it to be written by. So the list
    /// is the order, and a scene needs nothing more to keep it.
    fn placeAll(saving: *Saving) Allocator.Error!void {
        const gpa = saving.app.gpa;
        for (saving.app.world.archetypeSlice()) |*archetype| {
            for (archetype.entities.items) |e| {
                // Not a thing in the scene: a map'saving chunk, which its map
                // writes, and reading that makes again.
                if (saving.app.scene_components.keepsOut(&saving.app.world, e)) continue;
                if (saving.root) |root| if (!e.eql(root) and !saving.app.isDescendantOf(e, root)) continue;
                try saving.order.append(gpa, e);
            }
        }
        std.mem.sort(Entity, saving.order.items, @as(*const App, saving.app), App.siblingBefore);
        for (saving.order.items) |e| try saving.written.put(gpa, e, {});
        // What an instance holds is its scene's: the instance is written, and
        // its insides are made again from the scene when it is read.
        var hidden: std.AutoHashMapUnmanaged(Entity, void) = .empty;
        defer hidden.deinit(gpa);
        for (saving.app.instances.by_root.keys(), saving.app.instances.by_root.values()) |root, held| {
            if (!saving.written.contains(root)) continue;
            for (held.members) |member| try hidden.put(gpa, member, {});
        }
        if (hidden.count() > 0) {
            var kept: usize = 0;
            for (saving.order.items) |e| {
                if (hidden.contains(e)) {
                    _ = saving.written.remove(e);
                    continue;
                }
                saving.order.items[kept] = e;
                kept += 1;
            }
            saving.order.shrinkRetainingCapacity(kept);
        }
        for (saving.order.items) |e| _ = saving.app.ensureUuid(e) catch |err| switch (err) {
            error.NoSuchEntity => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    fn writeEntity(saving: *Saving, w: *json.Writer, e: Entity) json.Writer.Error!void {
        const app = saving.app;
        saving.entity = e;
        try w.beginObject();
        if (app.uuidOf(e)) |uuid| {
            const text = uuid.toString();
            try w.field("uuid", @as([]const u8, &text));
        }
        // What it hangs from, by the UUID it was written with: before the
        // name, which is its own among its parent'saving children. A branch'saving
        // root hangs from nothing written.
        const parent = app.parentOf(e);
        const named_parent = if (saving.root) |root| !e.eql(root) else true;
        if (!parent.isNone() and named_parent) if (app.uuidOf(parent)) |uuid| {
            const text = uuid.toString();
            try w.field("parent", @as([]const u8, &text));
        };
        if (app.nameOf(e)) |name| try w.field("name", name);
        var held: [32][]const u8 = undefined;
        const groups = app.groupsOf(e, &held);
        if (groups.len > 0) {
            try w.key("groups");
            try w.beginArray();
            for (groups) |group| try w.writeString(group);
            try w.endArray();
        }
        // What its script'saving `@export`saving are given.
        if (app.exports.of(e)) |values| try w.field("exports", values);
        // An instance: the scene it is one of, and what differs from it.
        if (!saving.every_field) if (app.instances.by_root.getPtr(e)) |instance| {
            try w.field("instance", app.sceneSource(instance.scene) orelse "");
            try saving.writeOverrides(w, e, instance.template);
            return w.endObject();
        };
        for (app.scene_components.entries.items) |entry| {
            const id = entry.findIdIn(&app.world) orelse continue;
            const cell = app.world.cellOf(e, id) orelse continue;
            try w.key(entry.name);
            try entry.write(saving, w, cell);
        }
        try saving.writeUnknown(w, e);
        try w.endObject();
    }

    /// What an instance's root has that its scene did not give it: the
    /// fields that differ, the components it was given, and in `removed`
    /// those it lost - `template` being the root as the scene made it.
    fn writeOverrides(saving: *Saving, w: *json.Writer, e: Entity, template: []const u8) json.Writer.Error!void {
        const app = saving.app;
        var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const was = membersOf(arena, template) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.WriteFailed,
        };

        var removed: std.ArrayList([]const u8) = .empty;
        for (app.scene_components.entries.items) |entry| {
            const before = memberNamed(was, entry.name);
            const id = entry.findIdIn(&app.world) orelse {
                if (before != null) try removed.append(arena, entry.name);
                continue;
            };
            const cell = app.world.cellOf(e, id) orelse {
                if (before != null) try removed.append(arena, entry.name);
                continue;
            };
            const had = before orelse {
                // Given one its scene does not: written whole.
                try w.key(entry.name);
                try entry.write(saving, w, cell);
                continue;
            };
            // Every field of it as it is now, beside every field it was
            // made with: what differs is written.
            var now_text: std.Io.Writer.Allocating = .init(arena);
            var now_writer: json.Writer = .init(&now_text.writer, .{ .non_finite = .literal });
            const every = saving.every_field;
            saving.every_field = true;
            entry.write(saving, &now_writer, cell) catch |err| {
                saving.every_field = every;
                return err;
            };
            saving.every_field = every;
            const now = membersOf(arena, now_text.written()) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.WriteFailed,
            };
            const then = membersOf(arena, had) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.WriteFailed,
            };
            var any = false;
            for (now) |field| {
                // A map'saving tiles are its scene'saving.
                if (std.mem.eql(u8, field.name, "cells")) continue;
                if (memberNamed(then, field.name)) |old| if (std.mem.eql(u8, old, field.value)) continue;
                if (!any) {
                    try w.key(entry.name);
                    try w.beginObject();
                    any = true;
                }
                try w.key(field.name);
                try writeRaw(app.gpa, w, field.value);
            }
            if (any) try w.endObject();
        }
        if (removed.items.len > 0) {
            try w.key("removed");
            try w.beginArray();
            for (removed.items) |name| try w.writeString(name);
            try w.endArray();
        }
    }

    /// The components the entity was read with that nothing here knows, as
    /// they were read. One of a name the entity has a registered component
    /// of now is left out: that component is what it holds.
    fn writeUnknown(saving: *Saving, w: *json.Writer, e: Entity) json.Writer.Error!void {
        const app = saving.app;
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
    /// build or not - and nothing at all when there are none.
    fn writeConnections(saving: *Saving, w: *json.Writer) json.Writer.Error!void {
        var any = false;
        for (saving.order.items) |source| {
            const list = saving.app.signals.from.getPtr(source) orelse continue;
            for (list.items) |c| {
                if (!c.options.flags.persist or c.callable != .named) continue;
                const from = saving.app.uuidOf(source) orelse continue;
                const to = saving.app.uuidOf(c.callable.named.target) orelse continue;
                if (!any) {
                    try w.key("connections");
                    try w.beginArray();
                    any = true;
                }
                try w.beginObject();
                const from_text = from.toString();
                try w.field("from", @as([]const u8, &from_text));
                try w.field("signal", saving.app.signalWritten(c));
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
                    for (c.options.binds) |b| try saving.writeBind(w, b);
                    try w.endArray();
                }
                try w.endObject();
            }
        }
        if (any) try w.endArray();
    }

    /// A bind: the plain JSON value it is, or an object saying which of the
    /// others it is.
    fn writeBind(saving: *Saving, w: *json.Writer, b: signals.Bind) json.Writer.Error!void {
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
                try writeValue(saving, w, Entity, &e);
                try w.endObject();
            },
        }
    }

    /// `assets`: each file the scene named that there is something to say
    /// of - its UUID, how a texture is sampled when that is not the default
    /// - and nothing at all when there is nothing to say of any.
    fn writeFiles(saving: *Saving, w: *json.Writer) json.Writer.Error!void {
        var any = false;
        for (saving.files.keys(), saving.files.values()) |name, sampled| {
            const uid = saving.app.project.knownUid(name);
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
                try writeValue(saving, w, rhi.Filter, &sampled.filter);
            }
            if (sampled.wrap != .clamp_to_edge) {
                try w.key("wrap");
                try writeValue(saving, w, rhi.Wrap, &sampled.wrap);
            }
            try w.endObject();
        }
        if (any) try w.endObject();
    }
};

/// One member of a JSON object, its value as compact JSON.
const Member = struct {
    name: []const u8,
    value: []const u8,
};

/// The members of the JSON object in `text`, each value written compactly,
/// so two written by different writers compare as text.
fn membersOf(arena: Allocator, text: []const u8) ![]Member {
    var reader: json.Reader = .init(arena, text, .{ .syntax = .json5 });
    defer reader.deinit();
    var out: std.ArrayList(Member) = .empty;
    const opening = (try reader.next()) orelse return error.SyntaxError;
    if (opening != .object_begin) return error.SyntaxError;
    while (true) {
        const token = (try reader.next()) orelse return error.SyntaxError;
        const name = switch (token) {
            .key => |held| try arena.dupe(u8, held),
            .object_end => break,
            else => return error.SyntaxError,
        };
        var value: std.Io.Writer.Allocating = .init(arena);
        var w: json.Writer = .init(&value.writer, .{ .non_finite = .literal });
        try copyValue(&reader, &w);
        try out.append(arena, .{ .name = name, .value = value.written() });
    }
    return out.items;
}

fn memberNamed(members: []const Member, name: []const u8) ?[]const u8 {
    for (members) |member| {
        if (std.mem.eql(u8, member.name, name)) return member.value;
    }
    return null;
}

/// JSON already written, written again into `w`.
fn writeRaw(gpa: Allocator, w: *json.Writer, text: []const u8) json.Writer.Error!void {
    var reader: json.Reader = .init(gpa, text, .{ .syntax = .json5 });
    defer reader.deinit();
    copyValue(&reader, w) catch |err| return switch (err) {
        error.OutOfMemory, error.WriteFailed, error.TooDeep, error.NonFiniteNumber => |held| held,
        // Written by this file a moment ago, and it reads.
        error.SyntaxError => unreachable,
    };
}

/// One value of `T` - a component's fields - as JSON text of its own, the
/// caller's: what `scene_read.readValueText` reads. A file it names is
/// written by its path.
pub fn writeValueText(app: *App, gpa: Allocator, comptime T: type, value: *const T) json.StringifyError![]u8 {
    return writeValueTextWith(app, gpa, T, value, null);
}

/// The same, with a shader's numbers written beside the value under
/// `params`: a material file's.
pub fn writeValueTextWith(app: *App, gpa: Allocator, comptime T: type, value: *const T, params: ?[]const @import("../render/shaders.zig").Param) json.StringifyError![]u8 {
    return json.stringify(gpa, ValueText(T){ .app = app, .value = value, .params = params }, writeOptions(.{}));
}

fn ValueText(comptime T: type) type {
    return struct {
        app: *App,
        value: *const T,
        params: ?[]const @import("../render/shaders.zig").Param = null,

        pub fn toJson(self: @This(), w: *json.Writer) json.Writer.Error!void {
            var saving: Saving = .{ .app = self.app, .params = self.params orelse &.{} };
            defer saving.deinit(self.app.gpa);
            try writeComponent(&saving, w, T, self.value);
        }
    };
}

/// A component: an object of the fields that do not hold their defaults.
pub fn writeComponent(saving: *Saving, w: *json.Writer, comptime T: type, value: *const T) json.Writer.Error!void {
    if (@typeInfo(T) != .@"struct") return writeValue(saving, w, T, value);
    try w.beginObject();
    // Its words, which it keeps beside it: see `component_texts.zig`.
    inline for (comptime component_texts.declared(T)) |text| {
        const said = saving.app.textOf(saving.entity, T, text.name);
        if (said.len > 0 or saving.every_field) try w.field(text.name, said);
    }
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const held = &@field(value.*, field.name);
        const skip = (comptime isUnsaved(T, field.name)) or
            (if (field.defaultValue()) |default| !saving.every_field and std.meta.eql(held.*, default) else false);
        if (!skip) {
            try w.key(field.name);
            try writeValue(saving, w, field.type, held);
        }
    }
    // What it keeps beside it.
    inline for (comptime scene.besideOf(T)) |beside| try beside.write(saving, w);
    try w.endObject();
}

/// Whether `T` keeps its field `name` out of every scene: `attr.Unsaved`.
fn isUnsaved(comptime T: type, comptime name: []const u8) bool {
    if (!@hasDecl(T, "reflect_fields") or !@hasField(@TypeOf(T.reflect_fields), name)) return false;
    for (@field(T.reflect_fields, name)) |entry| {
        if (@TypeOf(entry) == attr.Unsaved) return true;
    }
    return false;
}

/// A value inside a component, whole: a nested struct with all its fields,
/// so a colour reads as the four numbers it is.
fn writeValue(saving: *Saving, w: *json.Writer, comptime T: type, value: *const T) json.Writer.Error!void {
    if (T == Entity) {
        const uuid = if (value.isNone()) null else saving.app.uuidOf(value.*);
        const held = uuid orelse return w.writeNull();
        const text = held.toString();
        return w.writeString(&text);
    }
    // A file is written as its path, and the path kept for `assets`.
    if (comptime AssetKind.of(T)) |kind| {
        const source = saving.app.assetSource(value.*) orelse return w.writeNull();
        const kept = try saving.files.getOrPut(saving.app.gpa, source);
        if (!kept.found_existing) kept.value_ptr.* = .{};
        switch (kind) {
            // How a texture is sampled is the file'saving, and goes in `assets`.
            .texture => {
                const texture = saving.app.assets.get(value.*).?;
                kept.value_ptr.* = .{ .filter = texture.filter, .wrap = texture.wrap };
            },
            // The first font of a file is the file. Another font of a
            // collection is an object that says which, so one scene can
            // hold two of a file.
            .font => {
                const member = saving.app.assets.fontMember(value.*);
                if (member != 0) {
                    try w.beginObject();
                    try w.field("file", source);
                    try w.key("member");
                    try w.writeInt(member);
                    return w.endObject();
                }
            },
            else => {},
        }
        return w.writeString(source);
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
                try writeValue(saving, w, field.type, &@field(value.*, field.name));
            }
            try w.endObject();
        },
        .array => |info| {
            // A name kept in the component - a `Script`'saving struct, a player'saving
            // bus - is the text before its first zero.
            if (info.child == u8) {
                const end = std.mem.indexOfScalar(u8, value, 0) orelse value.len;
                return w.writeString(value[0..end]);
            }
            try w.beginArray();
            for (value) |*item| try writeValue(saving, w, info.child, item);
            try w.endArray();
        },
        .vector => |info| {
            try w.beginArray();
            const items: [info.len]info.child = value.*;
            for (&items) |*item| try writeValue(saving, w, info.child, item);
            try w.endArray();
        },
        .optional => |info| if (value.*) |*inner| {
            try writeValue(saving, w, info.child, inner);
        } else try w.writeNull(),
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("fluxion-engine: a scene cannot tell which field of the untagged union " ++ @typeName(T) ++ " is set");
            switch (value.*) {
                inline else => |*payload, tag| {
                    if (@TypeOf(payload.*) == void) return w.writeString(@tagName(tag));
                    try w.beginObject();
                    try w.key(@tagName(tag));
                    try writeValue(saving, w, @TypeOf(payload.*), payload);
                    try w.endObject();
                },
            }
        },
        else => @compileError("fluxion-engine: a scene cannot hold a " ++ @typeName(T)),
    }
}
