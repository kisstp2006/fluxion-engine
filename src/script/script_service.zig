// SPDX-License-Identifier: BSD-3-Clause

//! What an editor's language service is told of the engine, to check and
//! complete a game's scripts as the game compiles them: the same types and
//! hooks as `install` gives the VM, the files a script may import, and the
//! names a call's string can be - an action, an entity, a group, a file of
//! the project's, an animation.

const std = @import("std");
const Allocator = std.mem.Allocator;

const flux = @import("fluxion_script");
const ecs = @import("fluxion_ecs");
const App = @import("../App.zig");
const actions = @import("../input/actions.zig");
const AssetKind = @import("../assets/asset_kind.zig").AssetKind;
const Project = @import("../project/Project.zig");
const FileAccess = @import("file_access.zig").FileAccess;
const ImagesAccess = @import("image_access.zig").ImagesAccess;

const Script = @import("script.zig").Script;
const install = @import("script_host.zig").install;

/// For `App.scriptSetup`. An analysis only compiles, so `app` is a name
/// with nothing behind it there. Inside the quotes of a call that names an
/// action, the project's actions are offered.
pub fn serviceOptions(app: *App) flux.service.Options {
    return .{
        .setup = .{ .context = app, .run = installForAnalysis },
        .loader = .{ .context = app, .load = loadImport },
        .io = app.io,
        .strings = .{ .context = app, .values = stringValues },
        .imports = .{ .context = app, .list = importableScripts },
    };
}

/// For `App.hostScriptSetup`: the same, for a host's own scripts that are
/// no entity's, whose methods the engine does not call.
pub fn hostServiceOptions(app: *App) flux.service.Options {
    return .{
        .setup = .{ .context = app, .run = installHostForAnalysis },
        .loader = .{ .context = app, .load = loadImport },
        .io = app.io,
        .strings = .{ .context = app, .values = stringValues },
        .imports = .{ .context = app, .list = importableScripts },
    };
}

/// The project's scripts, for an editor's `@import("` and the names they
/// declare: every `.flux` file under `res://` but in hidden folders and
/// what a build leaves, `zig-out` and `zig-pkg`. None without a project.
fn importableScripts(context: ?*anyopaque, arena: Allocator) Allocator.Error![]const []const u8 {
    const app: *App = @ptrCast(@alignCast(context.?));
    if (app.project.settings == null) return &.{};
    var found: std.ArrayList([]const u8) = .empty;
    try filesUnder(app, arena, Project.scheme, &.{.script}, &found, 0);
    return found.items;
}

/// The project's files of `kinds` under `folder`, by their `res://` paths:
/// of any kind the engine reads, with none named. Not what is in hidden
/// folders, nor what a build leaves, `zig-out` and `zig-pkg`.
fn filesUnder(app: *App, arena: Allocator, folder: []const u8, kinds: []const AssetKind, found: *std.ArrayList([]const u8), depth: u8) Allocator.Error!void {
    if (depth > 16 or found.items.len >= 4096) return;
    const listing = app.listDir(app.gpa, folder) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer listing.deinit(app.gpa);
    for (listing.names) |name| {
        if (name[0] == '.') continue;
        if (std.mem.endsWith(u8, name, "/")) {
            if (std.mem.eql(u8, name, "zig-out/") or std.mem.eql(u8, name, "zig-pkg/")) continue;
            try filesUnder(app, arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ folder, name }), kinds, found, depth + 1);
        } else if (isOfKinds(name, kinds)) {
            if (found.items.len >= 4096) return;
            try found.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ folder, name }));
        }
    }
}

/// Whether the file called `name` is of one of `kinds`, by its ending: a
/// scene's may be `.json`, which `AssetKind.ofPath` leaves to what the file
/// says inside.
fn isOfKinds(name: []const u8, kinds: []const AssetKind) bool {
    const ending = std.fs.path.extension(name);
    const among: []const AssetKind = if (kinds.len == 0) std.enums.values(AssetKind) else kinds;
    for (among) |kind| for (kind.extensions()) |known| {
        if (std.ascii.eqlIgnoreCase(ending, known)) return true;
    };
    return false;
}

/// A script's `@import("save.flux")`: the file beside the one importing it,
/// or at a `res://` path, read from the project. The same file is the same
/// module name however it is spelt - and however the importing file is: an
/// editor outside the engine names it by where it is on the disk.
pub fn loadImport(context: ?*anyopaque, gpa: Allocator, from: []const u8, path: []const u8) anyerror!flux.Vm.Loader.Loaded {
    const app: *App = @ptrCast(@alignCast(context.?));
    const importing = try app.project.canonical(gpa, from);
    defer gpa.free(importing);
    const wanted = if (std.mem.indexOf(u8, path, "://") != null)
        try gpa.dupe(u8, path)
    else if (std.mem.lastIndexOfScalar(u8, importing, '/')) |cut|
        // "res://Scripts/menu.flux" and "save.flux" are "res://Scripts/save.flux".
        try std.mem.concat(gpa, u8, &.{ importing[0 .. cut + 1], path })
    else
        try gpa.dupe(u8, path);
    defer gpa.free(wanted);
    const name = try app.project.canonical(gpa, wanted);
    errdefer gpa.free(name);
    const source = try app.project.readFileAlloc(gpa, name, .limited(16 << 20));
    return .{ .name = name, .source = source };
}

/// What the text a call takes names.
const Naming = union(enum) {
    /// One of the input map's actions.
    action,
    /// An entity, by its name: `find`'s.
    entity,
    /// An entity, by the names on the way to it from the roots.
    entity_path,
    group,
    /// One of the audio buses.
    bus,
    /// One of `DebugViews`' switches.
    debug_view,
    /// An animation of a player's libraries.
    animation,
    /// A file of the project's, of these kinds - of any, with none.
    file: []const AssetKind,
};

/// A parameter of one of `App`'s calls, and what its text names.
const Named = struct { call: []const u8, param: []const u8, what: Naming };

/// `App`'s calls whose text names something the engine knows of. Each is
/// offered inside the quotes of `app.call(...)`, and of `entity.call(...)`
/// where the call's first parameter is the entity - `player.addToGroup("`.
/// A call or a parameter that is not there does not compile.
const named = [_]Named{
    .{ .call = "actionDown", .param = "name", .what = .action },
    .{ .call = "actionJustPressed", .param = "name", .what = .action },
    .{ .call = "actionJustReleased", .param = "name", .what = .action },
    .{ .call = "actionStrength", .param = "name", .what = .action },
    .{ .call = "actionAxis", .param = "negative", .what = .action },
    .{ .call = "actionAxis", .param = "positive", .what = .action },
    .{ .call = "actionVector", .param = "left", .what = .action },
    .{ .call = "actionVector", .param = "right", .what = .action },
    .{ .call = "actionVector", .param = "up", .what = .action },
    .{ .call = "actionVector", .param = "down", .what = .action },
    .{ .call = "pressAction", .param = "name", .what = .action },
    .{ .call = "releaseAction", .param = "name", .what = .action },
    .{ .call = "describeAction", .param = "name", .what = .action },
    .{ .call = "bindAction", .param = "name", .what = .action },
    .{ .call = "clearAction", .param = "name", .what = .action },

    .{ .call = "find", .param = "name", .what = .entity },
    .{ .call = "findIn", .param = "name", .what = .entity },
    .{ .call = "childNamed", .param = "name", .what = .entity },
    .{ .call = "findPath", .param = "path", .what = .entity_path },

    .{ .call = "addToGroup", .param = "group", .what = .group },
    .{ .call = "removeFromGroup", .param = "group", .what = .group },
    .{ .call = "isInGroup", .param = "group", .what = .group },
    .{ .call = "groupMembers", .param = "group", .what = .group },
    .{ .call = "callGroup", .param = "group", .what = .group },

    .{ .call = "setBusVolumeDb", .param = "name", .what = .bus },
    .{ .call = "busVolumeDb", .param = "name", .what = .bus },
    .{ .call = "setBusMute", .param = "name", .what = .bus },
    .{ .call = "isBusMuted", .param = "name", .what = .bus },

    .{ .call = "setDebugView", .param = "name", .what = .debug_view },
    .{ .call = "isDebugViewOn", .param = "name", .what = .debug_view },

    .{ .call = "hasAnimation", .param = "name", .what = .animation },
    .{ .call = "animationLength", .param = "name", .what = .animation },

    .{ .call = "saveScene", .param = "path", .what = .{ .file = &.{.scene} } },
    .{ .call = "readScene", .param = "path", .what = .{ .file = &.{.scene} } },
    .{ .call = "loadInBackground", .param = "path", .what = .{ .file = &.{} } },
    .{ .call = "loadProgress", .param = "path", .what = .{ .file = &.{} } },
    .{ .call = "loadStatus", .param = "path", .what = .{ .file = &.{} } },
    .{ .call = "finishLoad", .param = "path", .what = .{ .file = &.{} } },
    .{ .call = "loadSpriteFrames", .param = "path", .what = .{ .file = &.{.frames} } },
    .{ .call = "saveSpriteFrames", .param = "path", .what = .{ .file = &.{.frames} } },
    .{ .call = "readData", .param = "path", .what = .{ .file = &.{.data} } },
    .{ .call = "bakeNavigationMesh", .param = "path", .what = .{ .file = &.{.navmesh} } },
    .{ .call = "materialNumber", .param = "path", .what = .{ .file = &.{.material} } },
    .{ .call = "setMaterialNumber", .param = "path", .what = .{ .file = &.{.material} } },
    .{ .call = "setMaterialColor", .param = "path", .what = .{ .file = &.{.material} } },
};

/// Where a call's parameters are, as a script counts its arguments: `vm`,
/// which the engine hands over itself, is not one of them.
fn Places(comptime T: type) type {
    return struct {
        /// The names of `call`'s parameters a script gives, or null for no
        /// call of `T`'s.
        fn of(comptime call: []const u8) ?[]const []const u8 {
            comptime {
                if (!@hasField(@TypeOf(T.reflect_methods), call)) return null;
                var names: []const []const u8 = &.{};
                for (@field(T.reflect_methods, call)) |held| {
                    if (@TypeOf(held) != @import("../reflect/attr.zig").Params) continue;
                    for (held.names) |name| {
                        if (!std.mem.eql(u8, name, "vm")) names = names ++ .{name};
                    }
                }
                return names;
            }
        }
    };
}

/// Whether `call` of `App`'s is one a script makes on an entity: its first
/// parameter is the entity, which is then no argument.
fn onEntity(comptime call: []const u8) bool {
    const params = @typeInfo(@TypeOf(@field(App, call))).@"fn".params;
    return params.len > 1 and params[1].type == ecs.Entity;
}

/// One of `named`, with where its parameter is among a call's arguments.
const Place = struct { call: []const u8, arg: u32, on_entity: bool, what: Naming };

const places = made: {
    var out: [named.len]Place = undefined;
    for (named, &out) |each, *place| {
        const names = Places(App).of(each.call) orelse @compileError("App has no call " ++ each.call);
        const at = for (names, 0..) |name, i| {
            if (std.mem.eql(u8, name, each.param)) break i;
        } else @compileError(each.call ++ " has no parameter " ++ each.param);
        place.* = .{ .call = each.call, .arg = at, .on_entity = onEntity(each.call), .what = each.what };
    }
    break :made out;
};

/// `App`'s calls that take a path a completion has nothing to offer for: a
/// file of the player's own, under `user://`.
const left_out = [_][]const u8{ "saveInputMap", "loadInputMap" };

comptime {
    // A call added with a path or a group is named here, or left out by
    // name: no text the engine knows the names for goes without them.
    @setEvalBranchQuota(1_000_000);
    for (@typeInfo(@TypeOf(App.reflect_methods)).@"struct".fields) |method| {
        const names = Places(App).of(method.name).?;
        params: for (names) |name| {
            if (!std.mem.eql(u8, name, "path") and !std.mem.eql(u8, name, "group")) continue;
            for (named) |each| {
                if (std.mem.eql(u8, each.call, method.name) and std.mem.eql(u8, each.param, name)) continue :params;
            }
            for (left_out) |call| {
                if (std.mem.eql(u8, call, method.name)) continue :params;
            }
            @compileError("app." ++ method.name ++ " takes a " ++ name ++ " that script_service.zig's `named` does not list");
        }
    }
}

/// What the text `argument` is in names, or null for one the engine has no
/// names for. A call on `app` is `App`'s; on `files` or `images`, a path
/// is a file's; on anything else it is taken for an entity's, since what a
/// call is on is not known to a completion.
fn namingOf(argument: flux.service.StringArgument) ?Naming {
    const receiver = argument.receiver orelse return null;
    if (std.mem.eql(u8, receiver, "files")) return if (isPath(FileAccess, argument)) .{ .file = &.{} } else null;
    if (std.mem.eql(u8, receiver, "images")) return if (isPath(ImagesAccess, argument)) .{ .file = &.{.texture} } else null;
    const on_app = std.mem.eql(u8, receiver, "app");
    for (places) |place| {
        if (!std.mem.eql(u8, place.call, argument.callee)) continue;
        if (on_app) {
            if (place.arg == argument.arg) return place.what;
        } else if (place.on_entity and place.arg == argument.arg + 1) return place.what;
    }
    return null;
}

/// Whether the argument is one of `T`'s calls' paths: a parameter called
/// `path`, `from` or `to`.
fn isPath(comptime T: type, argument: flux.service.StringArgument) bool {
    inline for (@typeInfo(@TypeOf(T.reflect_methods)).@"struct".fields) |method| {
        if (std.mem.eql(u8, method.name, argument.callee)) {
            const names = comptime Places(T).of(method.name).?;
            if (argument.arg >= names.len) return false;
            inline for (.{ "path", "from", "to" }) |path| {
                if (std.mem.eql(u8, names[argument.arg], path)) return true;
            }
            return false;
        }
    }
    return false;
}

/// What the string a call takes may say: the names of what the engine
/// knows of, for the calls that take one - an action's, with the inputs
/// that set it off; an entity's, with where it is; a file's, with its kind.
fn stringValues(context: ?*anyopaque, arena: Allocator, argument: flux.service.StringArgument) Allocator.Error![]const flux.service.StringValue {
    const app: *App = @ptrCast(@alignCast(context.?));
    return switch (namingOf(argument) orelse return spriteAnimationNames(app, arena, argument)) {
        .action => actionNames(app, arena),
        .entity => entityNames(app, arena, false),
        .entity_path => entityNames(app, arena, true),
        .group => groupNames(app, arena),
        .bus => busNames(app, arena),
        .debug_view => debugViewNames(arena),
        .animation => playerAnimationNames(app, arena),
        .file => |kinds| fileNames(app, arena, kinds),
    };
}

/// The project file's actions, over the built-in ones: an editor runs with
/// the built-in ones alone, and a game with both.
fn actionNames(app: *App, arena: Allocator) Allocator.Error![]const flux.service.StringValue {
    var list: std.ArrayList(flux.service.StringValue) = .empty;
    const project: []const actions.Action = if (app.project.settings) |held| held.input.actions else &.{};
    for (actions.builtin) |builtin| {
        const chosen = for (project) |action| {
            if (std.mem.eql(u8, action.name, builtin.name)) break action;
        } else builtin;
        try list.append(arena, try actionValue(arena, chosen, "A built-in action, for moving round the interface."));
    }
    for (project) |action| {
        if (actions.builtinNamed(action.name) != null) continue;
        try list.append(arena, try actionValue(arena, action, null));
    }
    for (app.input.actions.list()) |*entry| {
        if (!said(list.items, entry.name)) try list.append(arena, try actionValue(arena, entry.action(), null));
    }
    return list.items;
}

fn said(values: []const flux.service.StringValue, label: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value.label, label)) return true;
    }
    return false;
}

/// The names of the world's entities - in an editor, the scene open - each
/// once, with the way to the first of them from the roots; or, `as_path`,
/// each entity by that way, as `findPath` takes one from the roots.
fn entityNames(app: *App, arena: Allocator, as_path: bool) Allocator.Error![]const flux.service.StringValue {
    var list: std.ArrayList(flux.service.StringValue) = .empty;
    var it = app.names.of_entity.iterator();
    while (it.next()) |entry| {
        if (list.items.len >= 4096) break;
        const entity = entry.key_ptr.*;
        if (!app.world.isAlive(entity)) continue;
        const name = entry.value_ptr.*;
        if (!as_path and said(list.items, name)) continue;
        const path = try wayTo(app, arena, entity);
        try list.append(arena, if (as_path) .{ .label = path } else .{ .label = try arena.dupe(u8, name), .detail = path });
    }
    return list.items;
}

/// The names from the roots to `entity`, `/` before each: `/Level/Door`. One
/// on the way with no name is `?`, which no path finds.
fn wayTo(app: *App, arena: Allocator, entity: ecs.Entity) Allocator.Error![]const u8 {
    var steps: [32][]const u8 = undefined;
    var count: usize = 0;
    var at = entity;
    while (!at.isNone() and count < steps.len) : (at = app.parentOf(at)) {
        steps[count] = app.nameOf(at) orelse "?";
        count += 1;
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    while (count > 0) : (count -= 1) out.writer.print("/{s}", .{steps[count - 1]}) catch return error.OutOfMemory;
    return out.written();
}

/// The groups the world's entities are in, each with how many.
fn groupNames(app: *App, arena: Allocator) Allocator.Error![]const flux.service.StringValue {
    var list: std.ArrayList(flux.service.StringValue) = .empty;
    for (app.groups.by_name.keys(), app.groups.by_name.values()) |name, members| {
        try list.append(arena, .{
            .label = try arena.dupe(u8, name),
            .detail = try std.fmt.allocPrint(arena, "{d} in it", .{members.items.len}),
        });
    }
    return list.items;
}

/// The buses sound is mixed on: the ones made, `Master` first, and the
/// project's, which an editor has not made.
fn busNames(app: *App, arena: Allocator) Allocator.Error![]const flux.service.StringValue {
    var list: std.ArrayList(flux.service.StringValue) = .empty;
    for (app.audio.buses.items) |bus| try list.append(arena, .{ .label = try arena.dupe(u8, bus.name) });
    const project: []const @import("../audio/audio.zig").Bus = if (app.project.settings) |held| held.audio.buses else &.{};
    for (project) |bus| {
        if (!said(list.items, bus.name)) try list.append(arena, .{ .label = bus.name, .detail = try std.fmt.allocPrint(arena, "into {s}", .{bus.send}) });
    }
    return list.items;
}

/// The switches of `DebugViews`, which `setDebugView` turns by name.
fn debugViewNames(arena: Allocator) Allocator.Error![]const flux.service.StringValue {
    const fields = std.meta.fields(@import("../render/debug_views.zig"));
    const list = try arena.alloc(flux.service.StringValue, fields.len);
    inline for (fields, list) |field, *value| value.* = .{ .label = field.name };
    return list;
}

/// The project's files of `kinds`, each by its `res://` path with the kind
/// it is - found by any part of its name, as the list is narrowed by what
/// is typed. A path being typed from `res://` on is the editor's to
/// complete, a folder at a time.
fn fileNames(app: *App, arena: Allocator, kinds: []const AssetKind) Allocator.Error![]const flux.service.StringValue {
    if (app.project.settings == null) return &.{};
    var found: std.ArrayList([]const u8) = .empty;
    try filesUnder(app, arena, Project.scheme, kinds, &found, 0);
    const list = try arena.alloc(flux.service.StringValue, found.items.len);
    for (found.items, list) |path, *value| value.* = .{
        .label = path,
        .detail = if (AssetKind.ofPath(path)) |kind| kind.label() else "",
    };
    return list;
}

/// The first string of a sprite's `play` and `playBackwards` and a player's
/// `play` and `queue`: the name of an animation of the sprite frames and
/// the animation libraries read, each with the file it is in. What the call
/// is on is not known to a completion, so both kinds are offered.
fn spriteAnimationNames(app: *App, arena: Allocator, argument: flux.service.StringArgument) Allocator.Error![]const flux.service.StringValue {
    if (argument.receiver == null or argument.arg != 0) return &.{};
    const callee = argument.callee;
    const of_sprites = std.mem.eql(u8, callee, "play") or std.mem.eql(u8, callee, "playBackwards");
    const of_players = std.mem.eql(u8, callee, "play") or std.mem.eql(u8, callee, "queue");
    var list: std.ArrayList(flux.service.StringValue) = .empty;
    if (of_sprites) {
        var it = app.sprite_frames.table.iterator();
        while (it.next()) |entry| for (entry.value.animations.items) |clip| {
            try list.append(arena, .{ .label = clip.name, .detail = entry.value.source });
        };
    }
    if (of_players) try list.appendSlice(arena, try playerAnimationNames(app, arena));
    return list.items;
}

/// The animations of the animation libraries read, each with its file.
fn playerAnimationNames(app: *App, arena: Allocator) Allocator.Error![]const flux.service.StringValue {
    var list: std.ArrayList(flux.service.StringValue) = .empty;
    var it = app.animation_libraries.table.iterator();
    while (it.next()) |entry| for (entry.value.animations.items) |held| {
        try list.append(arena, .{ .label = held.name, .detail = entry.value.source });
    };
    return list.items;
}

/// An action as a completion: its name, and its inputs as what it is.
fn actionValue(arena: Allocator, action: actions.Action, doc: ?[]const u8) Allocator.Error!flux.service.StringValue {
    var inputs: std.Io.Writer.Allocating = .init(arena);
    for (action.bindings, 0..) |binding, i| {
        if (i > 0) inputs.writer.writeAll(", ") catch return error.OutOfMemory;
        inputs.writer.print("{f}", .{binding}) catch return error.OutOfMemory;
    }
    return .{ .label = action.name, .detail = if (action.bindings.len == 0) "no input yet" else inputs.written(), .doc = doc };
}

/// What the game's VM is given, with nothing behind `app` and `files`: see
/// `install`.
fn installForAnalysis(context: ?*anyopaque, vm: *flux.Vm) anyerror!void {
    try install(vm, @ptrCast(@alignCast(context.?)), null, .world);
}

fn installHostForAnalysis(context: ?*anyopaque, vm: *flux.Vm) anyerror!void {
    try install(vm, @ptrCast(@alignCast(context.?)), null, .host);
}

/// The struct a `Script` names: the one it names, or else the one named
/// after its file, as the file is spelt or in CamelCase.
pub fn classFor(vm: *flux.Vm, module: *flux.object.Module, script: *const Script, source: []const u8, spelled: *[64]u8) ?flux.Value {
    return classAsked(vm, module, script.structName(), source, spelled);
}

/// The struct called `asked`, or with nothing asked, the one named after the
/// file.
pub fn classAsked(vm: *flux.Vm, module: *flux.object.Module, asked: []const u8, source: []const u8, spelled: *[64]u8) ?flux.Value {
    if (asked.len != 0) return classNamed(vm, module, asked);
    if (classNamed(vm, module, std.fs.path.stem(source))) |found| return found;
    return classNamed(vm, module, expected(source, spelled));
}

fn classNamed(vm: *flux.Vm, module: *flux.object.Module, name: []const u8) ?flux.Value {
    const found = vm.get(module, name) orelse return null;
    return if (found.tag == .class) found else null;
}

/// The struct named after a file, in CamelCase: `BigDoor` for
/// `big_door.flux`. Cut at `into`'s length.
pub fn expected(source: []const u8, into: *[64]u8) []const u8 {
    var len: usize = 0;
    var upper = true;
    for (std.fs.path.stem(source)) |c| {
        if (c == '_' or c == '-' or c == ' ') {
            upper = true;
            continue;
        }
        if (len == into.len) break;
        into[len] = if (upper) std.ascii.toUpper(c) else c;
        len += 1;
        upper = false;
    }
    return into[0..len];
}
