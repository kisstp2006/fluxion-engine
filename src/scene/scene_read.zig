// SPDX-License-Identifier: BSD-3-Clause

//! A scene read into the world: new entities with the UUIDs the file gives
//! them, every reference pointed at the right one, and the instances in it
//! made. A mistake is an error with where it is, and leaves the world as it
//! was. See `scene.zig` for the format.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const json = @import("fluxion_json");
const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");
const Uuid = @import("fluxion_id").Uuid;

const App = @import("../App.zig");
const Assets = @import("../assets/assets.zig");
const AssetKind = @import("../assets/asset_kind.zig").AssetKind;
const Project = @import("../project/Project.zig");
const signals = @import("../core/signals.zig");
const Color = @import("../math/color.zig").Color;
const components = @import("components.zig");
const component_texts = @import("component_texts.zig");
const registry = @import("registry.zig");
const scene = @import("scene.zig");

const Entity = ecs.Entity;
const ComponentId = ecs.component.Id;
const FontHandle = Assets.FontHandle;
const nameOf = registry.nameOf;
const copyValue = registry.copyValue;
const version = scene.version;
const LoadOptions = scene.LoadOptions;
const Nesting = scene.Nesting;
const Loaded = scene.Loaded;

/// What `assets` says of one file: its UUID, and how a texture is sampled
/// when that is not the way `Assets.loadTexture` samples by default.
const FileInfo = struct {
    uid: ?Uuid = null,
    filter: rhi.Filter = .nearest,
    wrap: rhi.Wrap = .clamp_to_edge,
};

/// Read the scene at `path` - `res://`, `uid://` or the operating system's -
/// into `app`'s world. See `App.loadScene`.
pub fn load(app: *App, path: []const u8, options: LoadOptions) anyerror!Loaded {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.setFile(path);
    }
    const bytes = app.project.readFileAlloc(app.gpa, path, .unlimited) catch |err| {
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

    // Every entity made, the instances' insides too: the caller's list, or
    // this read's own. On a mistake what this read added goes again.
    var own: std.ArrayList(Entity) = .empty;
    defer own.deinit(gpa);
    const made = options.spawned orelse &own;
    const first = made.items.len;
    errdefer for (made.items[first..]) |e| if (app.world.isAlive(e)) app.world.despawn(e);

    // One a place in the file's list: an instance's is its root, once made.
    var entities: std.ArrayList(Entity) = .empty;
    defer entities.deinit(gpa);

    // What is in the world already keeps its place before the scene's.
    try app.placeTheRest();

    var told: Told = .{};
    {
        var reader: json.Reader = .init(gpa, bytes, readerOptions(options));
        defer reader.deinit();
        var l: Loading = .{ .app = app, .reader = &reader, .arena = arena.allocator(), .diagnostics = options.diagnostics, .parent = options.parent };
        try l.shape(&entities, made, &told);
    }
    if (options.instance != null and told.roots != 1) {
        return failWhole(options, error.NotOneRoot, "a scene made as an instance has one root, which the rest of it hangs from, and this has {d}", .{told.roots});
    }

    // Each entity the UUID the file gives it - an instance's made of its
    // own and the file's - unless an entity already in the world has that
    // one, when it is given a new one, and the file's stays the scene's own
    // name for it.
    var loaded: Loaded = .{ .roots = @intCast(told.roots) };
    for (entities.items, 0..) |e, place| {
        if (told.nested.contains(place)) continue;
        const uuid = uuidAt(options, &told, place) orelse continue;
        if (app.findUuid(uuid) != null) {
            _ = try app.ensureUuid(e);
            loaded.reassigned += 1;
        } else app.setUuid(e, uuid) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UuidTaken, error.NilUuid, error.NoSuchEntity => unreachable,
        };
    }

    // Each instance in it made from its own scene, with the UUID the file
    // gives it: its insides are named after that, so they are found by the
    // same UUIDs every time the file is read.
    var it = told.nested.iterator();
    while (it.next()) |entry| {
        const place = entry.key_ptr.*;
        const path = entry.value_ptr.*;
        const handle = app.loadScene(path) catch |err|
            return failWhole(options, err, "cannot read the scene \"{s}\" an entity is an instance of: {t}", .{ path, err });
        if (Nesting.holds(options.within, handle)) {
            return failWhole(options, error.SceneHoldsItself, "\"{s}\" is an instance of itself, and would never end", .{path});
        }
        var uuid = uuidAt(options, &told, place) orelse app.newUuid();
        if (app.findUuid(uuid) != null) {
            uuid = app.newUuid();
            loaded.reassigned += 1;
        }
        const nesting: Nesting = .{ .scene = handle, .outer = options.within };
        const before = made.items.len;
        // Its mistakes are said as its own file's.
        var outer_file: [240]u8 = undefined;
        var outer_len: usize = 0;
        if (options.diagnostics) |d| {
            outer_len = @min(d.file().len, outer_file.len);
            @memcpy(outer_file[0..outer_len], d.file()[0..outer_len]);
            d.setFile(app.sceneSource(handle) orelse path);
        }
        const inner = try read(app, app.scenes.get(handle).?.bytes, .{
            .diagnostics = options.diagnostics,
            .instance = uuid,
            .spawned = made,
            .within = &nesting,
        });
        if (options.diagnostics) |d| d.setFile(outer_file[0..outer_len]);
        entities.items[place] = inner.root;
        // What it is as its scene makes it, before this file says what is
        // particular about this one.
        try app.keepInstance(inner.root, handle, made.items[before..]);
    }

    var later: std.ArrayList(Later) = .empty;
    defer later.deinit(gpa);
    {
        var reader: json.Reader = .init(gpa, bytes, readerOptions(options));
        defer reader.deinit();
        var l: Loading = .{
            .app = app,
            .reader = &reader,
            .arena = arena.allocator(),
            .diagnostics = options.diagnostics,
            .entities = entities.items,
            .told = &told,
            .later = &later,
            .parent = options.parent,
            .instance = options.instance,
        };
        try l.fill();
        // The list is the order of every parent's children.
        try app.placeInOrder(entities.items);
        loaded.moved = @intCast(l.moved);
        loaded.components_unknown = @intCast(l.components_unknown);
        loaded.connections_unknown = @intCast(l.connections_unknown);
        loaded.connections_skipped = @intCast(l.connections_skipped);
    }

    // Last of all, what had to wait for the values to be written: see
    // `Loading.whenRead`.
    for (later.items) |job| try job.run(app, job.value, made);
    if (told.roots == 1) loaded.root = entities.items[told.root_place.?];
    loaded.entities = @intCast(made.items.len - first);
    return loaded;
}

/// The UUID the entity at `place` is given: the file's, or for an instance
/// the instance's own for its root and one made of it and the file's for
/// the rest. Null for one the file gives none.
fn uuidAt(options: LoadOptions, told: *const Told, place: usize) ?Uuid {
    const instance = options.instance orelse return told.uuids.items[place];
    if (told.root_place == place) return instance;
    const given = told.uuids.items[place] orelse return null;
    return Uuid.fromName(instance, &given.bytes);
}

/// Say what is wrong with the scene as a whole, rather than at a token.
fn failWhole(options: LoadOptions, err: anyerror, comptime fmt: []const u8, args: anytype) anyerror {
    if (options.diagnostics) |d| d.setMessage(fmt, args);
    return err;
}

/// What the first pass learns for the second. Kept in the arena.
const Told = struct {
    /// Each entity's UUID in the file, at its place in the list.
    uuids: std.ArrayList(?Uuid) = .empty,
    /// The places that are instances of another scene, with its path.
    nested: std.AutoArrayHashMapUnmanaged(usize, []const u8) = .empty,
    /// Whether the entity at a place names a parent.
    parented: std.ArrayList(bool) = .empty,
    /// How many name none, and where the first of them is.
    roots: usize = 0,
    root_place: ?usize = null,
    /// Each UUID's place in the list: what a reference inside the scene
    /// finds, whatever UUID the entity was given in the end.
    places: std.AutoHashMapUnmanaged(Uuid, usize) = .empty,
    /// `assets`, by path.
    files: std.StringHashMapUnmanaged(FileInfo) = .empty,
};

pub fn readerOptions(options: LoadOptions) json.Reader.Options {
    // JSON5 for NaN and the infinities, which the writer spells out; comments
    // come with it, for a scene edited by hand.
    return .{ .syntax = .json5, .diagnostics = options.diagnostics };
}

pub const Token = json.Reader.Token;

/// Work left until the whole scene is read, with its own copy of what it
/// needs: see `Loading.whenRead`.
pub const Later = struct {
    run: *const fn (app: *App, value: *const anyopaque, made: *std.ArrayList(Entity)) anyerror!void,
    value: *const anyopaque,
};

pub const Loading = struct {
    app: *App,
    reader: *json.Reader,
    /// For what outlives a token: the paths in the tables, what `Told` holds.
    arena: Allocator,
    diagnostics: ?*json.Diagnostics,
    /// Every entity in the file, at its place in the list.
    entities: []const Entity = &.{},
    /// What the first pass learnt. Null during it.
    told: ?*const Told = null,
    /// Files found or loaded already, by their kind and the path the file
    /// gives, as the eight bytes every handle is.
    handles: std.StringHashMapUnmanaged(u64) = .empty,
    /// Fonts the same, by the path and which font of the file.
    fonts: std.StringHashMapUnmanaged(FontHandle) = .empty,
    /// The entity being filled in, for a value kept beside its component:
    /// a map's tiles.
    entity: Entity = .none,
    /// What has to wait until the whole scene is read: see `whenRead`.
    later: ?*std.ArrayList(Later) = null,
    /// What the scene's roots hang from: see `LoadOptions.parent`.
    parent: Entity = .none,
    /// The instance being read, when it is one: see `LoadOptions.instance`.
    instance: ?Uuid = null,
    /// Whether the entity being read is an instance, whose components are
    /// its scene's and whose fields here say only what differs: a field
    /// left out keeps what the scene gave it.
    overriding: bool = false,
    /// Files found by their UUIDs somewhere other than the scene says.
    moved: usize = 0,
    /// See `Loaded`.
    components_unknown: usize = 0,
    connections_unknown: usize = 0,
    connections_skipped: usize = 0,
    path: Path = .{},

    /// Run `job` with a copy of `value` once the whole scene is read: what
    /// makes an entity - a map's chunk - since making one now would move the
    /// rows the values are being written into. What it makes goes in
    /// `made`, with the rest of what the scene made.
    pub fn whenRead(l: *Loading, value: anytype, comptime job: fn (app: *App, value: *const @TypeOf(value), made: *std.ArrayList(Entity)) anyerror!void) !void {
        const list = l.later orelse return;
        const T = @TypeOf(value);
        const kept = try l.arena.create(T);
        kept.* = value;
        const Run = struct {
            fn run(app: *App, held: *const anyopaque, made: *std.ArrayList(Entity)) anyerror!void {
                return job(app, @ptrCast(@alignCast(held)), made);
            }
        };
        try list.append(l.app.gpa, .{ .run = Run.run, .value = kept });
    }

    /// The first pass: an entity for every object in `entities`, with every
    /// registered component it has, each entity's UUID, and the tables of
    /// files.
    fn shape(l: *Loading, entities: *std.ArrayList(Entity), made: *std.ArrayList(Entity), told: *Told) anyerror!void {
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
                    const place = entities.items.len;
                    const mark = l.path.push("entities/{d}", .{place});
                    try l.open(.object_begin, "an entity, which is an object of its components");
                    var ids: [ecs.component.max_components]ComponentId = undefined;
                    var count: usize = 0;
                    var own: ?Uuid = null;
                    var parented = false;
                    var instance: ?[]const u8 = null;
                    while (try l.key()) |member| {
                        if (std.mem.eql(u8, member, "uuid")) {
                            const inner = l.path.push("uuid", .{});
                            const uuid = try l.readUuid();
                            if (told.places.contains(uuid)) return l.fail(error.DuplicateUuid, "another entity in this scene has this UUID already", .{});
                            try told.places.put(l.arena, uuid, place);
                            own = uuid;
                            l.path.pop(inner);
                            continue;
                        }
                        if (std.mem.eql(u8, member, "instance")) {
                            const inner = l.path.push("instance", .{});
                            const token = try l.next();
                            instance = switch (token) {
                                .string => |text| try l.arena.dupe(u8, text),
                                else => return l.wrong("the scene it is an instance of, which is a path", token),
                            };
                            l.path.pop(inner);
                            continue;
                        }
                        if (std.mem.eql(u8, member, "parent")) {
                            parented = true;
                        } else if (!std.mem.eql(u8, member, "name") and !std.mem.eql(u8, member, "groups") and !std.mem.eql(u8, member, "removed") and !std.mem.eql(u8, member, "exports")) {
                            if (app.scene_components.find(member)) |entry| {
                                if (count == ids.len) return error.TooManyComponents;
                                ids[count] = try entry.idIn(&app.world);
                                count += 1;
                            }
                        }
                        try l.reader.skipValue();
                    }
                    if (!parented) {
                        if (told.root_place == null) told.root_place = place;
                        told.roots += 1;
                    }
                    try told.uuids.append(l.arena, own);
                    try told.parented.append(l.arena, parented);
                    try entities.ensureUnusedCapacity(app.gpa, 1);
                    if (instance) |path| {
                        // Made from its own scene once the list is read.
                        try told.nested.put(l.arena, place, path);
                        entities.appendAssumeCapacity(.none);
                    } else {
                        if (parented or !l.parent.isNone()) {
                            if (count == ids.len) return error.TooManyComponents;
                            ids[count] = try app.world.idOf(components.Parent);
                            count += 1;
                        }
                        try made.ensureUnusedCapacity(app.gpa, 1);
                        const e = try app.world.spawnRaw(distinct(ids[0..count]));
                        made.appendAssumeCapacity(e);
                        entities.appendAssumeCapacity(e);
                    }
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
                l.overriding = l.told.?.nested.contains(place);
                defer l.overriding = false;
                // Given once the whole entity is read, when its parent is,
                // since a name is its own among its parent's children.
                var given: ?[]const u8 = null;
                _ = try l.next();
                while (try l.key()) |member| {
                    if (std.mem.eql(u8, member, "uuid") or std.mem.eql(u8, member, "instance")) {
                        try l.reader.skipValue();
                        continue;
                    }
                    if (std.mem.eql(u8, member, "removed")) {
                        const mark = l.path.push("removed", .{});
                        try l.open(.array_begin, "the components its scene gives it that it has not, which is a list of names");
                        while (true) {
                            const token = try l.next();
                            switch (token) {
                                .array_end => break,
                                .string => |component| app.removeComponentNamed(e, component) catch {},
                                else => return l.wrong("the name of a component", token),
                            }
                        }
                        l.path.pop(mark);
                        continue;
                    }
                    if (std.mem.eql(u8, member, "name")) {
                        const token = try l.next();
                        given = switch (token) {
                            .string => |text| try l.arena.dupe(u8, text),
                            else => return l.wrong("an entity's name", token),
                        };
                        continue;
                    }
                    if (std.mem.eql(u8, member, "parent")) {
                        const mark = l.path.push("parent", .{});
                        var parent: Entity = .none;
                        try readValue(l, Entity, &parent);
                        try hang(app, e, parent);
                        l.path.pop(mark);
                        continue;
                    }
                    if (std.mem.eql(u8, member, "exports")) {
                        const mark = l.path.push("exports", .{});
                        try l.readExports(e);
                        l.path.pop(mark);
                        continue;
                    }
                    if (std.mem.eql(u8, member, "groups")) {
                        const mark = l.path.push("groups", .{});
                        try l.open(.array_begin, "the groups an entity is in, which is a list of names");
                        while (true) {
                            const token = try l.next();
                            switch (token) {
                                .array_end => break,
                                .string => |group| try app.addToGroup(e, group),
                                else => return l.wrong("the name of a group", token),
                            }
                        }
                        l.path.pop(mark);
                        continue;
                    }
                    const entry = app.scene_components.find(member) orelse {
                        try l.keepUnknown(e, member);
                        continue;
                    };
                    const mark = l.path.push("{s}", .{entry.name});
                    // An instance given a component its scene does not.
                    if (l.overriding and app.componentOf(e, entry.name) == null) _ = try app.addComponentNamed(e, entry.name);
                    const cell = app.world.cellOf(e, entry.findIdIn(&app.world).?).?;
                    try entry.read(l, cell);
                    l.path.pop(mark);
                }
                // A root of the scene hangs from what it was read under.
                if (!l.told.?.parented.items[place] and !l.parent.isNone()) try hang(app, e, l.parent);
                // Another of its family with the name already - the same
                // scene read twice beside itself - gives this one the first
                // free one after it.
                if (given) |text| try app.setFreeName(e, text);
                l.path.pop(entity_mark);
            }
            // Past the list's end, for what comes after it: the connections.
            try l.open(.array_end, "the end of the entities");
        }
    }

    /// A component nothing here is registered as, kept with its entity as
    /// the scene has it. See `Unknown`.
    /// `exports`: what the entity's script's fields are given, an object of
    /// them. See `script_exports.zig`.
    fn readExports(l: *Loading, e: Entity) anyerror!void {
        const gpa = l.app.gpa;
        var text: std.Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        var w: json.Writer = .init(&text.writer, .{ .non_finite = .literal });
        try copyValue(l.reader, &w);
        var doc = try json.parse(gpa, text.written(), .{ .syntax = .json5 });
        defer doc.deinit();
        if (doc.root.asObject() == null) return l.fail(error.WrongType, "what a script's fields are given is an object, by field", .{});
        try l.app.exports.setAll(gpa, e, doc.root);
    }

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
        return l.entityNamed(uuid);
    }

    /// The entity a UUID in the file names: one of the scene's own by the
    /// file's name for it, else one inside an instance the scene holds -
    /// named, as the file names it, after the instance - else one the world
    /// had already.
    fn entityNamed(l: *Loading, uuid: Uuid) ?Entity {
        if (l.told.?.places.get(uuid)) |place| return l.entities[place];
        if (l.instance) |instance| {
            if (l.app.findUuid(Uuid.fromName(instance, &uuid.bytes))) |inside| return inside;
        }
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

    /// The next token, which the scene has to have.
    pub fn next(l: *Loading) anyerror!Token {
        return (try l.reader.next()) orelse l.fail(error.SyntaxError, "the scene ends too soon", .{});
    }

    /// The next member's name, or null at the end of the object.
    pub fn key(l: *Loading) anyerror!?[]const u8 {
        return switch (try l.next()) {
            .key => |name| name,
            else => null,
        };
    }

    /// The next token, which has to be a `kind`: `what` it is, said when it
    /// is not.
    pub fn open(l: *Loading, comptime kind: std.meta.Tag(Token), comptime what: []const u8) anyerror!void {
        const token = try l.next();
        if (token != kind) return l.wrong(what, token);
    }

    /// Say the last token is not what was `expected`.
    pub fn wrong(l: *Loading, comptime expected: []const u8, token: Token) anyerror {
        return l.fail(error.WrongType, "expected " ++ expected ++ ", found {f}", .{found(token)});
    }

    /// Say what is wrong with the last token, and where in the scene it is.
    pub fn fail(l: *Loading, err: anyerror, comptime fmt: []const u8, args: anytype) anyerror {
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

    /// A file the scene names, read once however many things name it. A
    /// texture is sampled as `assets` says. A script that does not compile,
    /// a tile set or a theme that does not read, is still loaded, and the
    /// scene opens with it: what uses it makes nothing, draws white squares
    /// or draws with no theme, until a reload reads it.
    fn asset(l: *Loading, comptime H: type, path: []const u8) anyerror!H {
        const kind = comptime AssetKind.of(H).?;
        const seen = try std.fmt.allocPrint(l.arena, "{t}\x00{s}", .{ kind, path });
        if (l.handles.get(seen)) |known| return @bitCast(known);
        const where, const info = try l.file(path);
        // A picture read in the background is taken; what went wrong there
        // is found again below.
        if (kind == .texture) l.app.finishLoad(where) catch {};
        const handle: H = switch (kind) {
            .texture => l.app.assets.findTexture(where) orelse l.app.assets.loadTexture(where, .{ .filter = info.filter, .wrap = info.wrap }) catch |err|
                return l.fail(err, "cannot read the texture \"{s}\": {t}", .{ where, err }),
            else => l.app.loadAsset(H, where) catch |err|
                return l.fail(err, "cannot read the {s} \"{s}\": {t}", .{ kind.label(), where, err }),
        };
        try l.handles.put(l.arena, seen, @bitCast(handle));
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
/// Give an entity its parent, whether it was made with room for one or not:
/// an instance's root was made by its own scene, as a root.
fn hang(app: *App, e: Entity, parent: Entity) !void {
    if (app.world.get(e, components.Parent)) |held| {
        held.* = .of(parent);
    } else try app.world.add(e, components.Parent.of(parent));
}

pub fn readComponent(l: *Loading, comptime T: type, out: *T) anyerror!void {
    if (@typeInfo(T) != .@"struct") return readValue(l, T, out);
    try l.open(.object_begin, "an object of the component's fields");
    const fields = @typeInfo(T).@"struct".fields;
    var seen: std.StaticBitSet(fields.len) = .initEmpty();
    // An instance's field left out keeps what its scene gave it.
    if (!l.overriding) {
        // Words left out are none.
        inline for (comptime component_texts.declared(T)) |text| {
            if (!l.entity.isNone()) try l.app.setText(l.entity, T, text.name, "");
        }
        // What it keeps beside it, left out, is none.
        inline for (comptime scene.besideOf(T)) |beside| {
            if (beside.forget) |forget| if (!l.entity.isNone()) forget(l.app, l.entity);
        }
    }
    while (try l.key()) |name| {
        var said = false;
        inline for (comptime component_texts.declared(T)) |text| {
            if (!said and std.mem.eql(u8, name, text.name)) {
                said = true;
                try readText(l, T, text.name);
            }
        }
        inline for (comptime scene.besideOf(T)) |beside| {
            if (!said and std.mem.eql(u8, name, beside.key)) {
                said = true;
                const mark = l.path.push("{s}", .{beside.key});
                try beside.read(l);
                l.path.pop(mark);
            }
        }
        if (said) continue;
        var matched = false;
        inline for (fields, 0..) |field, i| {
            if (!matched and std.mem.eql(u8, name, field.name)) {
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
    if (!l.overriding) try defaultTheRest(l, T, out, seen);
}

fn defaultTheRest(l: *Loading, comptime T: type, out: *T, seen: anytype) anyerror!void {
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        if (!seen.isSet(i)) {
            @field(out.*, field.name) = field.defaultValue() orelse
                return l.fail(error.MissingField, "{s} has no {s}, and it has no default to take", .{ nameOf(T), field.name });
        }
    }
}

/// A name kept in a component, written as the text it is.
fn readName(l: *Loading, out: []u8) anyerror!void {
    const token = try l.next();
    const text = switch (token) {
        .string => |text| text,
        else => return l.wrong("a name, as text", token),
    };
    if (text.len > out.len) return l.fail(error.OutOfRange, "the name is {d} bytes, and {d} are kept", .{ text.len, out.len });
    @memset(out, 0);
    @memcpy(out[0..text.len], text);
}

/// One of a component's words, kept beside it for the entity being read.
fn readText(l: *Loading, comptime T: type, comptime property: []const u8) anyerror!void {
    const token = try l.next();
    const text = switch (token) {
        .string => |text| text,
        else => return l.wrong("words, as text", token),
    };
    if (!l.entity.isNone()) try l.app.setText(l.entity, T, property, text);
}

/// A value inside a component. A nested struct may leave fields out too.
fn readValue(l: *Loading, comptime T: type, out: *T) anyerror!void {
    if (T == Entity) {
        const token = try l.next();
        out.* = switch (token) {
            .null => .none,
            .string => |text| blk: {
                const uuid = Uuid.parse(text) catch return l.fail(error.WrongType, "an entity is named by its UUID, and \"{s}\" is not one", .{text});
                break :blk l.entityNamed(uuid) orelse
                    return l.fail(error.NoSuchEntity, "no entity in this scene or in the world has the UUID {s}", .{text});
            },
            else => return l.wrong("an entity's UUID, or null", token),
        };
        return;
    }
    if (comptime AssetKind.of(T)) |kind| {
        const token = try l.next();
        out.* = switch (token) {
            .null => .none,
            .string => |path| if (kind == .font) try l.font(path, 0) else try l.asset(T, path),
            .object_begin => if (kind == .font) try l.fontObject() else return l.wrong("the file it was read from, or null", token),
            else => return l.wrong(if (kind == .font) "the file it was read from, its file and member, or null" else "the file it was read from, or null", token),
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
        .array => |info| if (info.child == u8) try readName(l, out) else try readItems(l, info.child, info.len, out),
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

    pub fn push(p: *Path, comptime fmt: []const u8, args: anytype) usize {
        const mark = p.len;
        const written = std.fmt.bufPrint(p.buf[p.len..], "/" ++ fmt, args) catch "";
        p.len += written.len;
        return mark;
    }

    pub fn pop(p: *Path, mark: usize) void {
        p.len = mark;
    }

    fn slice(p: *const Path) []const u8 {
        return p.buf[0..p.len];
    }
};
