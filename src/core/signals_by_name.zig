// SPDX-License-Identifier: BSD-3-Clause

//! Signals and methods found by name, for what was not compiled against the
//! game: an editor, a console, a scene. A signal is the one a component of
//! the entity declares - or its script - and a bare name two of them
//! declare is ambiguous; a method is a component's `reflect_methods`, the
//! script's, or one given to `App.addMethod`.

const std = @import("std");

const ecs = @import("fluxion_ecs");
const reflect = @import("fluxion_reflect");

const App = @import("../App.zig");
const calls = @import("../reflect/calls.zig");
const registry = @import("../scene/registry.zig");
const signals = @import("signals.zig");
const script_component = @import("../script/script.zig").component_name;

const Entity = ecs.Entity;
const Signal = signals.Signal;
const Error = signals.Error;
const Info = signals.Info;
const Callable = signals.Callable;
const Options = signals.Options;
const Connection = signals.Connection;
const MethodInfo = signals.MethodInfo;

/// A signal of `entity` by the name one of its components declares it
/// under - `hit`, or `Health.hit` when two of them declare `hit` - for what
/// was not compiled against the game: an editor, a console, a scene.
pub fn signalNamed(app: *App, entity: Entity, name: []const u8) Error!Signal {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        if (std.mem.eql(u8, name[0..dot], script_component)) {
            return scriptSignal(app, entity, name[dot + 1 ..]) orelse error.NoSuchSignal;
        }
        const entry = app.scene_components.find(name[0..dot]) orelse return error.NoSuchSignal;
        if (entry.valueOn(&app.world, entity) == null) return error.NoSuchSignal;
        for (entry.signals) |decl| {
            if (std.mem.eql(u8, decl.name, name[dot + 1 ..])) return .{ .app = app, .source = entity, .component = entry.name, .name = decl.name };
        }
        return error.NoSuchSignal;
    }
    var found: ?Signal = null;
    var held: [64]registry.ComponentValue = undefined;
    for (app.componentsOf(entity, &held)) |component| {
        const entry = app.scene_components.find(component.name) orelse continue;
        for (entry.signals) |decl| {
            if (!std.mem.eql(u8, decl.name, name)) continue;
            if (found != null) return error.AmbiguousSignal;
            found = .{ .app = app, .source = entity, .component = entry.name, .name = decl.name };
        }
    }
    if (scriptSignal(app, entity, name)) |declared| {
        if (found != null) return error.AmbiguousSignal;
        found = declared;
    }
    return found orelse error.NoSuchSignal;
}

/// The signal `name` the entity's script declares, if it has a script that
/// does.
fn scriptSignal(app: *App, entity: Entity, name: []const u8) ?Signal {
    const scripts = app.scripts orelse return null;
    var found: [64]Info = undefined;
    for (scripts.calls.signals(scripts, entity, &found)) |info| {
        if (std.mem.eql(u8, info.name, name)) return .{ .app = app, .source = entity, .component = script_component, .name = info.name };
    }
    return null;
}

/// `signalNamed`, emitted with values: what a console or a script emits.
pub fn emitNamed(app: *App, entity: Entity, name: []const u8, values: []const reflect.Value) Error!void {
    return (try signalNamed(app, entity, name)).emitValues(values);
}

/// Whether one of `entity`'s components declares a signal by that name.
pub fn hasSignal(app: *App, entity: Entity, name: []const u8) bool {
    _ = signalNamed(app, entity, name) catch |err| return err == error.AmbiguousSignal;
    return true;
}

/// Every signal `entity` has, component by component in the order they
/// were registered - its script's where `Script` is - as many as `found`
/// holds.
pub fn signalsOf(app: *App, entity: Entity, found: []Info) []Info {
    var count: usize = 0;
    var held: [64]registry.ComponentValue = undefined;
    for (app.componentsOf(entity, &held)) |component| {
        if (std.mem.eql(u8, component.name, script_component)) {
            if (app.scripts) |scripts| count += scripts.calls.signals(scripts, entity, found[count..]).len;
            continue;
        }
        const entry = app.scene_components.find(component.name) orelse continue;
        for (entry.signals) |decl| {
            if (count == found.len) return found[0..count];
            found[count] = .{ .component = entry.name, .name = decl.name, .args = decl.args };
            count += 1;
        }
    }
    return found[0..count];
}

/// The signals the component a scene calls `name` declares, whether any
/// entity has it or not: what an editor lists before one is added.
pub fn signalsOfComponent(app: *App, name: []const u8, found: []Info) []Info {
    const entry = app.scene_components.find(name) orelse return found[0..0];
    const count = @min(found.len, entry.signals.len);
    for (entry.signals[0..count], found[0..count]) |decl, *into| {
        into.* = .{ .component = entry.name, .name = decl.name, .args = decl.args };
    }
    return found[0..count];
}

/// Connect to a signal of `source` by name, whether this build knows it or
/// not: one no component declares is kept, saved and listed as written,
/// and never heard - how a scene or an editor holds a game's connections
/// without the game's components. A bare name two components declare is
/// `error.AmbiguousSignal`: name one.
pub fn connectNamed(app: *App, source: Entity, name: []const u8, callable: Callable, options: Options) Error!void {
    const known = signalNamed(app, source, name) catch |err| switch (err) {
        error.NoSuchSignal => return app.signals.connect(source, .{ .name = name }, callable, options),
        else => return err,
    };
    return known.connect(callable, options);
}

/// Take away a connection `connectNamed` could have made, by the name a
/// listing gives it.
pub fn disconnectNamed(app: *App, source: Entity, name: []const u8, callable: Callable) void {
    if (signalNamed(app, source, name)) |known| {
        if (app.signals.disconnect(source, known.key(), callable)) return;
    } else |_| {}
    // Kept as written: one this build did not know when it was made.
    _ = app.signals.disconnect(source, .{ .name = name }, callable);
}

/// Every connection of `source`'s signals, known or not, in the order they
/// were made: the order they are heard in, and the order a scene keeps and
/// reads back. A disconnect and a connect again puts one last.
pub fn connectionsFrom(app: *App, source: Entity, found: []Connection) []Connection {
    const listed = app.signals.connectionsFrom(source, found);
    for (listed) |*c| c.signal = signalWritten(app, c.*);
    return listed;
}

/// Every connection to a method of `receiver`.
pub fn connectionsTo(app: *App, receiver: Entity, found: []Connection) []Connection {
    const listed = app.signals.connectionsTo(receiver, found);
    for (listed) |*c| c.signal = signalWritten(app, c.*);
    return listed;
}

/// Every method a connection to `receiver` can name, with what each takes:
/// its components' `reflect_methods`, then what the game gave `addMethod`
/// by name, as many as `found` holds. What an editor's method picker lists,
/// and filters by a signal's arguments. `Entity.none` lists the game's own
/// alone.
pub fn methodsOf(app: *App, receiver: Entity, found: []MethodInfo) []MethodInfo {
    var count: usize = 0;
    var held: [64]registry.ComponentValue = undefined;
    for (app.componentsOf(receiver, &held)) |component| {
        if (std.mem.eql(u8, component.name, script_component)) {
            if (app.scripts) |scripts| count += scripts.calls.methods(scripts, receiver, found[count..]).len;
            continue;
        }
        for (component.value.type.methods.slice()) |*m| {
            if (count == found.len) return found[0..count];
            // The first is the component itself.
            const params = m.type.info.function.params.slice();
            found[count] = .{ .component = component.name, .name = m.name.slice(), .params = params[@min(1, params.len)..] };
            count += 1;
        }
    }
    const own = count;
    var it = app.signals.methods.iterator();
    while (it.next()) |entry| {
        if (count == found.len) break;
        found[count] = .{ .component = "", .name = entry.key_ptr.*, .params = entry.value_ptr.params };
        count += 1;
    }
    std.mem.sort(MethodInfo, found[own..count], {}, struct {
        fn less(_: void, a: MethodInfo, b: MethodInfo) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    return found[0..count];
}

/// Call the method a connection names, on `receiver`: a method one of its
/// components lists in `reflect_methods` - `Text2D.set` names the one -
/// or its script declares - `Script.hit` - else one given to `addMethod`.
pub fn callMethodOn(app: *App, receiver: Entity, name: []const u8, args: []const reflect.Value) anyerror!void {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    const component: ?[]const u8 = if (dot) |at| name[0..at] else null;
    const method = if (dot) |at| name[at + 1 ..] else name;

    var owner: ?reflect.Value = null;
    var scripted = false;
    var held: [64]registry.ComponentValue = undefined;
    for (app.componentsOf(receiver, &held)) |found| {
        if (component) |wanted| {
            if (!std.mem.eql(u8, found.name, wanted)) continue;
        }
        const has = if (std.mem.eql(u8, found.name, script_component))
            scriptHasMethod(app, receiver, method)
        else
            found.value.type.method(method) != null;
        if (!has) continue;
        if (owner != null or scripted) return error.AmbiguousMethod;
        if (std.mem.eql(u8, found.name, script_component)) scripted = true else owner = found.value;
    }
    if (owner) |value| return calls.call(value, method, args, null);
    if (scripted) {
        const scripts = app.scripts.?;
        return scripts.calls.callMethod(scripts, receiver, method, args);
    }
    if (component == null) {
        if (app.signals.methods.get(name)) |m| return m.call(app, receiver, args);
    }
    return error.NoSuchMethod;
}

/// Whether a connection naming `name` would find a method on `receiver`:
/// one of its components', its script's, or one given to `addMethod`.
pub fn hasMethod(app: *App, receiver: Entity, name: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    const method = if (dot) |at| name[at + 1 ..] else name;
    var held: [64]registry.ComponentValue = undefined;
    for (app.componentsOf(receiver, &held)) |found| {
        if (dot) |at| {
            if (!std.mem.eql(u8, found.name, name[0..at])) continue;
        }
        if (std.mem.eql(u8, found.name, script_component)) {
            if (scriptHasMethod(app, receiver, method)) return true;
            continue;
        }
        if (found.value.type.method(method) != null) return true;
    }
    return dot == null and app.signals.methods.contains(name);
}

fn scriptHasMethod(app: *App, entity: Entity, name: []const u8) bool {
    const scripts = app.scripts orelse return false;
    return scripts.calls.hasMethod(scripts, entity, name);
}

/// A connection's signal as the listings give it and a scene writes it: the
/// bare name, unless another of the source's components declares the same
/// name or the source has not got the one that declares it; and one this
/// build did not know when it was made, as it was written.
pub fn signalWritten(app: *App, c: Connection) []const u8 {
    if (!c.known) return c.signal;
    const dot = std.mem.lastIndexOfScalar(u8, c.signal, '.') orelse return c.signal;
    const component = c.signal[0..dot];
    const name = c.signal[dot + 1 ..];
    if (app.componentOf(c.source, component) == null) return c.signal;
    var held: [64]registry.ComponentValue = undefined;
    for (app.componentsOf(c.source, &held)) |found| {
        if (std.mem.eql(u8, found.name, component)) continue;
        if (std.mem.eql(u8, found.name, script_component)) {
            if (scriptSignal(app, c.source, name) != null) return c.signal;
            continue;
        }
        const entry = app.scene_components.find(found.name) orelse continue;
        for (entry.signals) |decl| {
            if (std.mem.eql(u8, decl.name, name)) return c.signal;
        }
    }
    return name;
}
