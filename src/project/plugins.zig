// SPDX-License-Identifier: BSD-3-Clause

//! Plugins: each a folder under `res://addons/` with a `plugin.fluxion`
//! manifest that says what it is and what it adds - singletons the game
//! opens with, a section of the project's settings, presets, an editor
//! part - and which other plugins it needs. The project file's
//! `plugins.enabled` names the ones turned on, by their folders.
//!
//! What a manifest says is added and taken away with the plugin: turned
//! off, its singletons are not opened and its files are not shipped.
//!
//! ```json
//! {
//!   "fluxion_plugin": 1,
//!   "name": "Game Jolt API",
//!   "version": "1.0.0",
//!   "engine": "0.4",
//!   "editor": "editor.flux",
//!   "autoload": [{ "name": "GameJolt", "path": "game_jolt.flux" }],
//!   "settings": { "section": "game_jolt", "label": "Game Jolt", "script": "settings.flux" },
//!   "requires": [{ "plugin": "http_tools", "version": "1.2" }],
//!   "leave_out": ["example/*"]
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("fluxion_json");

const App = @import("../App.zig");
const project_start = @import("project_start.zig");
const engine_version = @import("engine_options").version;

const log = std.log.scoped(.fluxion_engine);

/// Where plugins are: a folder each.
pub const folder = "res://addons";
/// Each plugin's manifest, in its folder.
pub const manifest_name = "plugin.fluxion";
/// Where a plugin's settings keep what they mark `@secret` - a private key
/// - out of the project file: a file of the project's that version
/// control leaves out, and an export puts in the game's pack.
/// `{ "<section>": { "<field>": value } }`.
pub const secrets_path = "res://.fluxion/secrets.json";
/// What a manifest says it is, at its top, and the version this engine
/// reads.
pub const header = "fluxion_plugin";
pub const version = 1;

/// What a plugin's `plugin.fluxion` says. Paths in it are inside the
/// plugin's folder.
pub const Manifest = struct {
    /// Always written, whatever else is left out.
    comptime fluxion_plugin: u32 = version,
    name: []const u8 = "",
    description: []const u8 = "",
    author: []const u8 = "",
    version: []const u8 = "",
    /// A picture of it, for the editor's list.
    icon: []const u8 = "",
    homepage: []const u8 = "",
    license: []const u8 = "",
    /// The engine it was made for: one older than that refuses it.
    engine: []const u8 = "",
    /// The script that runs in the editor, if it has a part there.
    editor: []const u8 = "",
    /// What the game opens with, before the project's own autoloads.
    autoload: []const Autoload = &.{},
    /// A section of the project's settings that is the plugin's.
    settings: ?Settings = null,
    /// Scenes the editor's Add menu offers, under a group.
    presets: []const Preset = &.{},
    /// What a game made with it does not ship: an example, its tests.
    /// `*` stands for any run of characters, `/` too.
    leave_out: []const []const u8 = &.{},
    /// The plugins it cannot do without, each started before it.
    requires: []const Dependency = &.{},
    /// The plugins it uses when they are there, started before it then.
    optional: []const Dependency = &.{},

    pub const Autoload = struct {
        /// What the singleton is called in the game: `app.find("GameJolt")`.
        name: []const u8,
        /// A script or a scene, inside the plugin's folder.
        path: []const u8,
    };

    pub const Settings = struct {
        /// Its key in the project file: `"game_jolt": { ... }`.
        section: []const u8,
        /// What the Project Settings call its page.
        label: []const u8 = "",
        /// The script whose struct its fields are: their `@export`s.
        script: []const u8,
        /// The struct, when it is not the one named after the file.
        @"struct": []const u8 = "",
    };

    pub const Preset = struct {
        name: []const u8,
        group: []const u8 = "",
        icon: []const u8 = "",
        scene: []const u8,
    };

    pub const Dependency = struct {
        /// The other plugin's folder.
        plugin: []const u8,
        /// The least version of it that will do; empty for any.
        version: []const u8 = "",
    };
};

/// One plugin found.
pub const Plugin = struct {
    /// Its folder under `res://addons/`: what the project's list names it
    /// by.
    id: []const u8,
    /// `res://addons/<id>`.
    root: []const u8,
    manifest: Manifest,
    /// Why its manifest did not read; then `manifest` is empty.
    problem: ?[]const u8 = null,

    /// A path of its manifest's, inside its folder: `res://addons/<id>/<relative>`.
    pub fn path(p: *const Plugin, gpa: Allocator, relative: []const u8) Allocator.Error![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ p.root, std.mem.trimStart(u8, relative, "/") });
    }

    /// What it is called: its manifest's name, or its folder's.
    pub fn label(p: *const Plugin) []const u8 {
        return if (p.manifest.name.len > 0) p.manifest.name else p.id;
    }
};

/// The plugins a project has, read from its `res://addons/`.
pub const Found = struct {
    arena: std.heap.ArenaAllocator,
    plugins: []Plugin = &.{},

    pub fn deinit(f: *Found) void {
        f.arena.deinit();
        f.* = undefined;
    }

    pub fn named(f: *const Found, id: []const u8) ?*const Plugin {
        for (f.plugins) |*p| if (std.mem.eql(u8, p.id, id)) return p;
        return null;
    }
};

/// Every folder under `res://addons/` with a manifest, in the order of
/// their names. One whose manifest does not read is there, with its
/// problem. A folder inside a plugin's is the plugin's own, never a plugin
/// of its own.
pub fn discover(app: *App, gpa: Allocator) Allocator.Error!Found {
    var found: Found = .{ .arena = .init(gpa) };
    errdefer found.deinit();
    const a = found.arena.allocator();
    const listing = app.listDir(gpa, folder) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return found,
    };
    defer listing.deinit(gpa);
    var list: std.ArrayList(Plugin) = .empty;
    for (listing.names) |name| {
        if (!std.mem.endsWith(u8, name, "/")) continue;
        const id = try a.dupe(u8, name[0 .. name.len - 1]);
        const root = try std.fmt.allocPrint(a, "{s}/{s}", .{ folder, id });
        const manifest_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, manifest_name });
        const text = app.readText(a, manifest_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A folder with no manifest is no plugin.
            else => continue,
        };
        var plugin: Plugin = .{ .id = id, .root = root, .manifest = .{} };
        if (read(a, text)) |manifest| {
            plugin.manifest = manifest;
        } else |err| plugin.problem = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotAManifest => "its plugin.fluxion does not say \"fluxion_plugin\"",
            error.NewerVersion => "its plugin.fluxion is of a newer engine's",
            else => "its plugin.fluxion is not JSON a manifest reads from",
        };
        try list.append(a, plugin);
    }
    found.plugins = list.items;
    return found;
}

pub const ReadError = error{ NotAManifest, NewerVersion } || json.Error;

/// What a manifest's text says.
pub fn read(a: Allocator, text: []const u8) ReadError!Manifest {
    const doc = try json.parse(a, text, .{});
    const root = doc.root;
    if (root.asObject() == null or !root.has(header)) return error.NotAManifest;
    if ((root.get(header).asInt(i64) orelse return error.NotAManifest) > version) return error.NewerVersion;
    const parsed = try root.parseAs(Manifest, a, .{ .unknown_fields = .ignore });
    return parsed.value;
}

/// A manifest as its file's text: what it says besides the defaults.
pub fn write(gpa: Allocator, manifest: Manifest) json.StringifyError![]u8 {
    return json.stringify(gpa, manifest, .{ .indent = 2, .skip_nulls = true, .skip_defaults = true });
}

/// Why a plugin turned on does not start.
pub const Refusal = struct {
    id: []const u8,
    why: Why,
    /// The plugin it needs, or the version it asks for.
    other: []const u8 = "",

    pub const Why = enum {
        /// Its manifest did not read.
        unreadable,
        /// It was made for a newer engine: `other` is the version.
        newer_engine,
        /// A plugin it requires is not there, or not turned on: `other`.
        needs,
        /// A plugin it requires is older than it needs: `other`.
        needs_newer,
        /// It requires, through others, itself.
        circle,
    };
};

/// The plugins turned on that start, each after those it requires or uses,
/// and those that cannot, with why.
pub const Start = struct {
    order: []const *const Plugin,
    refused: []const Refusal,

    pub fn refusalOf(s: *const Start, id: []const u8) ?Refusal {
        for (s.refused) |r| if (std.mem.eql(u8, r.id, id)) return r;
        return null;
    }
};

/// What starts of the plugins `enabled` names, in what order. In `a`.
pub fn startOrder(found: *const Found, enabled: []const []const u8, a: Allocator) Allocator.Error!Start {
    var refused: std.ArrayList(Refusal) = .empty;
    var order: std.ArrayList(*const Plugin) = .empty;
    // A plugin the list names and the folder has not is no plugin at all.
    var on: std.ArrayList(*const Plugin) = .empty;
    for (enabled) |id| if (found.named(id)) |p| try on.append(a, p);

    for (on.items) |p| {
        if (p.problem != null) {
            try refused.append(a, .{ .id = p.id, .why = .unreadable });
        } else if (p.manifest.engine.len > 0 and newer(p.manifest.engine, engine_version)) {
            try refused.append(a, .{ .id = p.id, .why = .newer_engine, .other = p.manifest.engine });
        }
    }
    try refuseTheirNeeds(a, on.items, &refused);
    // Each after what it requires or uses: depth first, a circle refused,
    // and so what requires one of the circle.
    var state: std.StringHashMapUnmanaged(enum { visiting, done }) = .empty;
    for (on.items) |p| try visit(a, p, true, on.items, &refused, &order, &state);
    try refuseTheirNeeds(a, on.items, &refused);
    var kept: usize = 0;
    for (order.items) |p| {
        if (isRefused(refused.items, p.id)) continue;
        order.items[kept] = p;
        kept += 1;
    }
    return .{ .order = order.items[0..kept], .refused = refused.items };
}

/// Those whose requirement is missing, too old or refused are refused too,
/// until none is.
fn refuseTheirNeeds(a: Allocator, on: []const *const Plugin, refused: *std.ArrayList(Refusal)) Allocator.Error!void {
    var changed = true;
    while (changed) {
        changed = false;
        for (on) |p| {
            if (isRefused(refused.items, p.id)) continue;
            for (p.manifest.requires) |need| {
                const other = enabledNamed(on, need.plugin);
                const why: ?Refusal.Why = if (other == null or isRefused(refused.items, need.plugin))
                    .needs
                else if (need.version.len > 0 and newer(need.version, other.?.manifest.version))
                    .needs_newer
                else
                    null;
                if (why) |w| {
                    try refused.append(a, .{ .id = p.id, .why = w, .other = need.plugin });
                    changed = true;
                    break;
                }
            }
        }
    }
}

/// `p` after what it requires or uses. Come round to again through what
/// requires it, it is refused: it would need to start before itself. Two
/// that only use each other start one after the other.
fn visit(
    a: Allocator,
    p: *const Plugin,
    required: bool,
    on: []const *const Plugin,
    refused: *std.ArrayList(Refusal),
    order: *std.ArrayList(*const Plugin),
    state: anytype,
) Allocator.Error!void {
    if (isRefused(refused.items, p.id)) return;
    if (state.get(p.id)) |s| {
        if (s == .visiting and required) try refused.append(a, .{ .id = p.id, .why = .circle });
        return;
    }
    try state.put(a, p.id, .visiting);
    for (p.manifest.requires) |need| if (enabledNamed(on, need.plugin)) |other| try visit(a, other, true, on, refused, order, state);
    for (p.manifest.optional) |use| if (enabledNamed(on, use.plugin)) |other| try visit(a, other, false, on, refused, order, state);
    try state.put(a, p.id, .done);
    if (!isRefused(refused.items, p.id)) try order.append(a, p);
}

fn isRefused(refused: []const Refusal, id: []const u8) bool {
    for (refused) |r| if (std.mem.eql(u8, r.id, id)) return true;
    return false;
}

fn enabledNamed(on: []const *const Plugin, id: []const u8) ?*const Plugin {
    for (on) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}

/// Whether version `a` is newer than `b`: "1.10" than "1.9", "0.5" than
/// "0.4.2". Parts that are not numbers count as nought.
pub fn newer(a: []const u8, b: []const u8) bool {
    var left = std.mem.splitScalar(u8, a, '.');
    var right = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const x = left.next();
        const y = right.next();
        if (x == null and y == null) return false;
        const xn = if (x) |text| std.fmt.parseInt(u64, text, 10) catch 0 else 0;
        const yn = if (y) |text| std.fmt.parseInt(u64, text, 10) catch 0 else 0;
        if (xn != yn) return xn > yn;
    }
}

/// Whether a game made from the project ships `path`: not when it is a
/// plugin's that is turned off, nor its editor part, its templates or what
/// its `leave_out` names.
pub fn ships(found: *const Found, enabled: []const []const u8, path: []const u8) bool {
    const prefix = folder ++ "/";
    if (!std.mem.startsWith(u8, path, prefix)) return true;
    const rest = path[prefix.len..];
    const cut = std.mem.indexOfScalar(u8, rest, '/') orelse return true;
    const id = rest[0..cut];
    const inside = rest[cut + 1 ..];
    const plugin = found.named(id) orelse return true;
    for (enabled) |on| {
        if (std.mem.eql(u8, on, id)) break;
    } else return false;
    const m = plugin.manifest;
    if (m.editor.len > 0 and std.mem.eql(u8, inside, std.mem.trimStart(u8, m.editor, "/"))) return false;
    if (std.mem.startsWith(u8, inside, "templates/")) return false;
    for (m.leave_out) |pattern| if (matches(pattern, inside)) return false;
    return true;
}

/// `*` stands for any run of characters, `/` too; the rest is itself.
pub fn matches(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;
    if (pattern[0] == '*') {
        var i: usize = 0;
        while (i <= text.len) : (i += 1) if (matches(pattern[1..], text[i..])) return true;
        return false;
    }
    return text.len > 0 and pattern[0] == text[0] and matches(pattern[1..], text[1..]);
}

/// The singletons of the plugins that start, made: each an entity named as
/// its manifest says, which a scene change leaves. Before the project's own
/// autoloads, so those find them. A plugin that cannot start is said in the
/// log.
pub fn openAutoloads(app: *App) !void {
    const settings = app.project.settings orelse return;
    if (settings.plugins.enabled.len == 0) return;
    var found = try discover(app, app.gpa);
    defer found.deinit();
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const start = try startOrder(&found, settings.plugins.enabled, a);
    for (start.refused) |r| log.warn("the plugin {s} does not start: {t} {s}", .{ r.id, r.why, r.other });
    for (start.order) |p| for (p.manifest.autoload) |entry| {
        const path = try p.path(a, entry.path);
        project_start.autoload(app, path, entry.name) catch |err| {
            log.err("the plugin {s}'s autoload {s} did not open: {t}", .{ p.id, path, err });
            return err;
        };
    };
}

const testing = std.testing;

test "versions are compared by their numbers" {
    try testing.expect(newer("1.10", "1.9"));
    try testing.expect(newer("0.5", "0.4.2"));
    try testing.expect(!newer("0.4", "0.4.0"));
    try testing.expect(!newer("1.0", "1.0.1"));
}

test "a leave_out pattern: `*` for any run" {
    try testing.expect(matches("example/*", "example/scene.json"));
    try testing.expect(matches("example/*", "example/art/a.png"));
    try testing.expect(matches("*.md", "README.md"));
    try testing.expect(!matches("example/*", "examples.flux"));
}

test "plugins start after those they require; one that needs a missing or older one, or itself, does not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plugins = [_]Plugin{
        .{ .id = "toasts", .root = "res://addons/toasts", .manifest = .{ .requires = &.{.{ .plugin = "gamejolt", .version = "1.0" }} } },
        .{ .id = "gamejolt", .root = "res://addons/gamejolt", .manifest = .{ .version = "1.2.0" } },
        .{ .id = "picky", .root = "res://addons/picky", .manifest = .{ .requires = &.{.{ .plugin = "gamejolt", .version = "2.0" }} } },
        .{ .id = "lonely", .root = "res://addons/lonely", .manifest = .{ .requires = &.{.{ .plugin = "nowhere" }} } },
        .{ .id = "a", .root = "res://addons/a", .manifest = .{ .optional = &.{.{ .plugin = "b" }} } },
        .{ .id = "b", .root = "res://addons/b", .manifest = .{ .optional = &.{.{ .plugin = "a" }} } },
        .{ .id = "future", .root = "res://addons/future", .manifest = .{ .engine = "99.0" } },
        .{ .id = "after_future", .root = "res://addons/after_future", .manifest = .{ .requires = &.{.{ .plugin = "future" }} } },
        .{ .id = "x", .root = "res://addons/x", .manifest = .{ .requires = &.{.{ .plugin = "y" }} } },
        .{ .id = "y", .root = "res://addons/y", .manifest = .{ .requires = &.{.{ .plugin = "x" }} } },
    };
    const found: Found = .{ .arena = .init(testing.allocator), .plugins = &plugins };
    const start = try startOrder(&found, &.{ "toasts", "gamejolt", "picky", "lonely", "a", "b", "future", "after_future", "x", "y", "missing" }, a);

    var ids: std.ArrayList([]const u8) = .empty;
    for (start.order) |p| try ids.append(a, p.id);
    try testing.expectEqual(@as(usize, 4), ids.items.len);
    try testing.expectEqualStrings("gamejolt", ids.items[0]);
    try testing.expectEqualStrings("toasts", ids.items[1]);
    try testing.expectEqual(Refusal.Why.needs_newer, start.refusalOf("picky").?.why);
    try testing.expectEqual(Refusal.Why.needs, start.refusalOf("lonely").?.why);
    try testing.expectEqual(Refusal.Why.newer_engine, start.refusalOf("future").?.why);
    try testing.expectEqual(Refusal.Why.needs, start.refusalOf("after_future").?.why);
    // Two that use each other: both start, one after the other. Two that
    // require each other: neither.
    try testing.expect(start.refusalOf("a") == null and start.refusalOf("b") == null);
    try testing.expect(start.refusalOf("x") != null and start.refusalOf("y") != null);

    // Shipped: an enabled plugin's files, not its editor part, templates or
    // what it leaves out; nothing of a plugin turned off.
    plugins[1].manifest.editor = "editor.flux";
    plugins[1].manifest.leave_out = &.{"example/*"};
    try testing.expect(ships(&found, &.{"gamejolt"}, "res://addons/gamejolt/game_jolt.flux"));
    try testing.expect(!ships(&found, &.{"gamejolt"}, "res://addons/gamejolt/editor.flux"));
    try testing.expect(!ships(&found, &.{"gamejolt"}, "res://addons/gamejolt/templates/x.template"));
    try testing.expect(!ships(&found, &.{"gamejolt"}, "res://addons/gamejolt/example/demo.json"));
    try testing.expect(!ships(&found, &.{}, "res://addons/gamejolt/game_jolt.flux"));
    try testing.expect(ships(&found, &.{}, "res://scenes/main.json"));
}

test "a manifest written says its header and what is not a default, and reads back the same" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const manifest: Manifest = .{
        .name = "Game Jolt API",
        .version = "1.0.0",
        .editor = "editor.flux",
        .autoload = &.{.{ .name = "GameJolt", .path = "game_jolt.flux" }},
        .settings = .{ .section = "game_jolt", .script = "settings.flux" },
    };
    const text = try write(a, manifest);
    try testing.expect(std.mem.indexOf(u8, text, "\"fluxion_plugin\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"icon\"") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\"requires\"") == null);
    const back = try read(a, text);
    try testing.expectEqualStrings("Game Jolt API", back.name);
    try testing.expectEqualStrings("game_jolt.flux", back.autoload[0].path);
    try testing.expectEqualStrings("game_jolt", back.settings.?.section);
    try testing.expectEqualStrings("", back.icon);
}
