// SPDX-License-Identifier: BSD-3-Clause

//! What an editor's language service is told of the engine, to check and
//! complete a game's scripts as the game compiles them: the same types and
//! hooks as `install` gives the VM, the files a script may import, and the
//! names a call's string can be - an action, an animation.

const std = @import("std");
const Allocator = std.mem.Allocator;

const flux = @import("fluxion_script");
const App = @import("../App.zig");
const actions = @import("../input/actions.zig");
const Project = @import("../project/Project.zig");

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

/// The project's scripts, for an editor's `@import("` and the names they
/// declare: every `.flux` file under `res://` but in hidden folders and
/// what a build leaves, `zig-out` and `zig-pkg`. None without a project.
fn importableScripts(context: ?*anyopaque, arena: Allocator) Allocator.Error![]const []const u8 {
    const app: *App = @ptrCast(@alignCast(context.?));
    if (app.project.settings == null) return &.{};
    var found: std.ArrayList([]const u8) = .empty;
    try scriptsUnder(app, arena, Project.scheme, &found, 0);
    return found.items;
}

fn scriptsUnder(app: *App, arena: Allocator, folder: []const u8, found: *std.ArrayList([]const u8), depth: u8) Allocator.Error!void {
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
            try scriptsUnder(app, arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ folder, name }), found, depth + 1);
        } else if (std.mem.endsWith(u8, name, ".flux")) {
            try found.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ folder, name }));
        }
    }
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

/// `app`'s calls whose strings name an action, and whether every one of
/// their arguments does or only the first.
const action_calls = [_]struct { []const u8, bool }{
    .{ "actionDown", false },
    .{ "actionJustPressed", false },
    .{ "actionJustReleased", false },
    .{ "actionStrength", false },
    .{ "actionAxis", true },
    .{ "actionVector", true },
    .{ "pressAction", false },
    .{ "releaseAction", false },
    .{ "describeAction", false },
};

/// What the string a call of `app`'s takes may say: an action's name, for
/// the calls that take one - each with the inputs that set it off.
fn stringValues(context: ?*anyopaque, arena: Allocator, argument: flux.service.StringArgument) Allocator.Error![]const flux.service.StringValue {
    const app: *App = @ptrCast(@alignCast(context.?));
    const receiver = argument.receiver orelse return &.{};
    if (!std.mem.eql(u8, receiver, "app")) return animationNames(app, arena, argument);
    const every = for (action_calls) |each| {
        if (std.mem.eql(u8, each[0], argument.callee)) break each[1];
    } else return &.{};
    if (!every and argument.arg != 0) return &.{};

    // The project file's actions, over the built-in ones: an editor runs
    // with the built-in ones alone, and a game with both.
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
        const known = for (list.items) |value| {
            if (std.mem.eql(u8, value.label, entry.name)) break true;
        } else false;
        if (!known) try list.append(arena, try actionValue(arena, entry.action(), null));
    }
    return list.items;
}

/// The first string of a sprite's `play` and `playBackwards` and a player's
/// `play` and `queue`: the name of an animation of the sprite frames and
/// the animation libraries read, each with the file it is in. What the call
/// is on is not known to a completion, so both kinds are offered.
fn animationNames(app: *App, arena: Allocator, argument: flux.service.StringArgument) Allocator.Error![]const flux.service.StringValue {
    if (argument.arg != 0) return &.{};
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
    if (of_players) {
        var it = app.animation_libraries.table.iterator();
        while (it.next()) |entry| for (entry.value.animations.items) |held| {
            try list.append(arena, .{ .label = held.name, .detail = entry.value.source });
        };
    }
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
    try install(vm, @ptrCast(@alignCast(context.?)), null);
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
