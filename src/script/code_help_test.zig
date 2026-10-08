// SPDX-License-Identifier: BSD-3-Clause

//! What an editor's code help shows a script of the engine's, checked
//! whole: every call of `app`'s, every component's fields, methods and
//! signals, every kind of input event, offered after their `.` with their
//! types and what they are - so a call added without a doc, a signal hidden
//! behind a field of its name, or a value a script sees as `any` is found
//! here rather than by someone typing.

const std = @import("std");
const testing = std.testing;
const flux = @import("fluxion_script");
const reflect = @import("fluxion_reflect");

const App = @import("../App.zig");
const attr = @import("../reflect/attr.zig");
const InputEvent = @import("../input/input_event.zig").InputEvent;

const Item = flux.service.Item;

/// What is offered where the `$` is in `source`.
fn offered(arena: std.mem.Allocator, app: *App, source: []const u8) ![]const Item {
    const where = std.mem.indexOfScalar(u8, source, '$').?;
    const text = try std.mem.concat(arena, u8, &.{ source[0..where], source[where + 1 ..] });
    const found = try flux.service.complete(testing.allocator, arena, "help.flux", text, @intCast(where), app.scriptSetup());
    return found.items;
}

fn named(items: []const Item, label: []const u8) ?Item {
    for (items) |item| if (std.mem.eql(u8, item.label, label)) return item;
    return null;
}

/// The item `label` of `items`, said of: there, and with a doc.
fn said(items: []const Item, label: []const u8, where: []const u8) !Item {
    const item = named(items, label) orelse {
        std.debug.print("`{s}` is not offered after `{s}`\n", .{ label, where });
        return error.NotOffered;
    };
    if (item.doc == null) {
        std.debug.print("`{s}` after `{s}` says nothing of what it is\n", .{ label, where });
        return error.Undocumented;
    }
    return item;
}

fn hidden(field: *const reflect.Field) bool {
    return field.attribute(attr.Hidden) != null or std.mem.startsWith(u8, field.name.slice(), "_");
}

test "every call of app's is offered after `app.`, with its signature and what it does" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = try offered(arena, app, "fn f() { app.$ }");
    inline for (@typeInfo(@TypeOf(App.reflect_methods)).@"struct".fields) |method| {
        const item = try said(items, method.name, "app.");
        try testing.expect(std.mem.startsWith(u8, item.detail, "fn App." ++ method.name ++ "("));
    }
    for ([_][]const u8{ "focus_changed", "quitting" }) |signal| {
        try testing.expect(std.mem.startsWith(u8, (try said(items, signal, "app.")).detail, "signal App."));
    }
}

test "every component's members are offered after `get(C).`: its fields typed and said what they are, its signals with what they say, none hidden behind another of its name" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var undocumented: usize = 0;
    for (app.scene_components.entries.items) |*entry| {
        const name = entry.name;
        const where = try std.fmt.allocPrint(arena, "get({s}).", .{name});
        const items = try offered(arena, app, try std.fmt.allocPrint(arena, "struct H {{ fn ready(self) {{ self.entity.get({s}).$ }} }}", .{name}));
        for (entry.signals) |decl| {
            // A field or a method of the name is what a script would reach.
            if (entry.type.field(decl.name) != null or entry.type.method(decl.name) != null) {
                std.debug.print("{s}.{s} is a signal and a field or a method too\n", .{ name, decl.name });
                return error.SignalHidden;
            }
            const item = try said(items, decl.name, where);
            try testing.expectEqual(flux.service.Kind.signal, item.kind);
            const head = try std.fmt.allocPrint(arena, "signal {s}.{s}(", .{ name, decl.name });
            try testing.expect(std.mem.startsWith(u8, item.detail, head));
        }
        if (entry.type.kind != .@"struct") continue;
        for (entry.type.fields()) |*field| {
            if (hidden(field)) continue;
            const item = named(items, field.name.slice()) orelse {
                std.debug.print("{s}.{s} is not offered\n", .{ name, field.name.slice() });
                return error.NotOffered;
            };
            if (std.mem.endsWith(u8, item.detail, ": any")) {
                std.debug.print("{s} is untyped\n", .{item.detail});
                return error.Untyped;
            }
            if (item.doc == null) {
                std.debug.print("`{s}` says nothing of what it is\n", .{item.detail});
                undocumented += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), undocumented);
}

test "every kind of input event is told apart with `is`, and offers its fields and the event's calls, each said what it is" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    inline for (@typeInfo(InputEvent).@"union".fields) |arm| {
        const kind = arm.type.reflect_name;
        const where = "if (event is " ++ kind ++ ") event.";
        const items = try offered(arena, app, "struct H { fn input(self, event: InputEvent) { if (event is " ++ kind ++ ") event.$ } }");
        inline for (@typeInfo(arm.type).@"struct".fields) |field| _ = try said(items, field.name, where);
        inline for (@typeInfo(@TypeOf(InputEvent.reflect_methods)).@"struct".fields) |method| _ = try said(items, method.name, where);
        // The name is offered where a kind is asked for.
        _ = named(try offered(arena, app, "struct H { fn input(self, event: InputEvent) { if (event is $) {} } }"), kind) orelse return error.NotOffered;
    }
    // Before `is`, what every event has.
    const any = try offered(arena, app, "struct H { fn input(self, event: InputEvent) { event.$ } }");
    for ([_][]const u8{ "isActionPressed", "isActionReleased", "isAction", "isPressed", "isKeyPressed", "describe" }) |call| _ = try said(any, call, "event.");
}

test "a lambda connected to a signal is given what the signal says, typed: offered after its `.`" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "struct H { fn ready(self) { self.entity.get(Area3D).body_entered.connect(fn(body) { body.$ }); } }", "globalPosition3D" },
        .{ "struct H { fn ready(self) { self.entity.get(Area2D).input_event.connect(fn(event, shape) { event.$ }); } }", "isActionPressed" },
        .{ "struct H { fn ready(self) { self.entity.get(RigidBody3D).clicked.connect(fn(button) { const b = button == MouseButton.$ }); } }", "left" },
        .{ "struct H { fn ready(self) { self.entity.get(NavigationAgent3D).link_reached.connect(fn(start, end) { end.$ }); } }", "y" },
        .{ "struct H { fn ready(self) { self.entity.get(AnimationPlayer).animation_finished.once(fn(name) { name.$ }); } }", "len" },
    }) |case| {
        _ = named(try offered(arena, app, case[0]), case[1]) orelse {
            std.debug.print("{s} is not offered in `{s}`\n", .{ case[1], case[0] });
            return error.NotOffered;
        };
    }
    // And checked as what it is.
    const source =
        \\fn f() {
        \\    time.clock(time.now(), 60.0).hour_passed.connect(fn(hours) { const _h: string = hours; });
        \\    app.focus_changed.connect(fn(front) { const _f: bool = front; });
        \\}
    ;
    const a = try flux.service.Analysis.init(testing.allocator, "help.flux", source, app.scriptSetup());
    defer a.deinit();
    try testing.expectEqual(@as(usize, 1), a.diagnostics.items.items.len);
    try testing.expectEqualStrings("the variable must be string, not int", a.diagnostics.items.items[0].message);
}

test "what the engine's calls give back is typed, and offers its fields, each said what it is" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Case = struct { []const u8, []const []const u8 };
    for ([_]Case{
        .{ "fn f() { const h = app.castRay3D(vec3(0, 0, 0), vec3(0, 0, 1)).?.$ }", &.{ "collider", "shape", "point", "normal", "fraction" } },
        .{ "fn f() { const h = app.castRay(vec2(0, 0), vec2(0, 1)).?.$ }", &.{ "collider", "shape", "point", "normal", "fraction" } },
        .{ "fn f() { for (app.contactsBegun3D()) |c| { c.$ } }", &.{ "a", "b", "sensor", "other" } },
        .{ "fn f() { for (app.contactsEnded()) |c| { c.$ } }", &.{ "a", "b", "sensor", "other" } },
        .{ "struct H { fn ready(self) { const c = app.moveAndCollide3D(self.entity, vec3(0, 0, 0)).?.$ } }", &.{ "collider", "shape", "point", "normal", "travel", "remainder" } },
        .{ "struct H { fn ready(self) { const c = app.lastSlideCollision(self.entity).?.$ } }", &.{ "collider", "shape", "point", "normal", "travel", "remainder" } },
        .{ "fn f() { const t = app.touchAt(0).?.$ }", &.{ "finger", "position", "pressed" } },
        .{ "fn f() { const t = app.twoFingers().$ }", &.{ "center", "scale", "angle" } },
    }) |case| {
        const items = try offered(arena, app, case[0]);
        for (case[1]) |field| _ = try said(items, field, case[0]);
    }
    // A vector and a list as the language's own.
    _ = named(try offered(arena, app, "struct H { fn ready(self) { const p = app.nextPathPosition(self.entity).$ } }"), "x") orelse return error.NotOffered;
    _ = named(try offered(arena, app, "fn f() { for (app.navigationPath(vec3(0, 0, 0), vec3(1, 0, 0))) |p| { p.$ } }"), "z") orelse return error.NotOffered;
    _ = named(try offered(arena, app, "struct H { fn ready(self) { const r = app.globalRotation3D(self.entity).?.$ } }"), "slerp") orelse return error.NotOffered;
}

test "a value of one kind only is checked as one where the engine takes it, though the engine takes any value there" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    const source =
        \\fn f() {
        \\    const picture = images.new(4, 4);
        \\    picture.blit(images.new(2, 2), 0, 0);
        \\    print(images.toTexture(picture) catch null);
        \\    picture.blit(3, 0, 0);
        \\    print(images.toTexture("map.png") catch null);
        \\    web.cancel(web.get("https://example.com"));
        \\    web.cancel(1);
        \\}
    ;
    const a = try flux.service.Analysis.init(testing.allocator, "help.flux", source, app.scriptSetup());
    defer a.deinit();
    var messages: std.ArrayList([]const u8) = .empty;
    defer messages.deinit(testing.allocator);
    for (a.diagnostics.items.items) |d| try messages.append(testing.allocator, d.message);
    try testing.expectEqual(@as(usize, 3), messages.items.len);
    try testing.expectEqualStrings("the argument must be Image, not int", messages.items[0]);
    try testing.expectEqualStrings("the argument must be Image, not string", messages.items[1]);
    try testing.expectEqualStrings("the argument must be task, not int", messages.items[2]);
}
