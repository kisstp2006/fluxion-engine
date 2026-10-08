// SPDX-License-Identifier: BSD-3-Clause

//! Components and calls by name through a whole app, headless.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const ComponentValue = App.ComponentValue;
const attr = @import("attr.zig");
const components = @import("../scene/components.zig");
const ecs = @import("fluxion_ecs");
const reflect = @import("fluxion_reflect");
const scene = @import("../scene/scene.zig");
const helpers = @import("../test_helpers.zig");
const Tally = helpers.Tally;

test "every engine component is described under the name a scene gives it" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    try testing.expectEqual(@as(usize, 82), app.scene_components.entries.items.len);
    for (app.scene_components.entries.items) |entry| {
        try testing.expectEqualStrings(entry.name, entry.type.name.slice());
        try testing.expect(app.types.find(entry.name).? == entry.type);
    }

    const drawn = app.types.find("Sprite").?;
    try testing.expectEqual(@as(f64, 1), drawn.field("pivot_x").?.attribute(reflect.attr.Range).?.max);
    try testing.expect(drawn.field("tint").?.type == app.types.find("Color").?);
    try testing.expect(app.types.find("Text2D").?.attribute(attr.Text) != null);
    try testing.expect(app.types.find("DebugViews").?.field("colliders") != null);
    // A 3D transform keeps its turn as a `Rotation`, four numbers.
    try testing.expect(app.types.find("Transform3D").?.field("rotation").?.type.field("w") != null);

    // Described, and left out until asked for: see `types`.
    try testing.expect(reflect.typeOf(App).method("setWindowTitle") != null);
    try testing.expect(app.types.find("App") == null);
    _ = try app.types.add(App);
    try testing.expect(app.types.find("App").? == reflect.typeOf(App));
}

test "a component is found by its name, and read and written where it is" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const thing = try app.world.spawnWith(.{ components.Transform2D.at(1, 2), components.Sprite.solid(.white, 4, 4) });

    const place = app.componentOf(thing, "Transform2D").?;
    try (try place.field("x")).setFloat(320);
    try (try place.path("scale_y")).setFloat(2);
    try testing.expectEqual(@as(f32, 320), app.world.get(thing, components.Transform2D).?.x);
    try testing.expectEqual(@as(f32, 2), app.world.get(thing, components.Transform2D).?.scale_y);

    // A method of the component's own, called through the value.
    var by: f32 = 5;
    try place.call("translate", &.{ .of(&by), .of(&by) }, null);
    try testing.expectEqual(@as(f32, 325), app.world.get(thing, components.Transform2D).?.x);

    try testing.expect(app.componentOf(thing, "Camera2D") == null);
    try testing.expect(app.componentOf(thing, "Mystery") == null);
    app.world.despawn(thing);
    try testing.expect(app.componentOf(thing, "Transform2D") == null);
}

test "a label's words are a text it keeps beside it, found and written by names" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const label = try app.world.spawnWith(.{ components.Transform2D{}, components.Text2D{} });
    try app.setText(label, components.Text2D, "text", "Score");

    // As an inspector that has never heard of `Text2D` finds them.
    const words = app.componentOf(label, "Text2D").?;
    const text = words.type.attribute(attr.Text).?;
    try testing.expectEqualStrings("text", text.name);
    try testing.expect(text.multiline);
    try app.setTextNamed(label, "Text2D", text.name, "Game over");
    try testing.expectEqualStrings("Game over", app.textNamed(label, "Text2D", "text"));
    try testing.expectEqualStrings("Game over", app.textOf(label, components.Text2D, "text"));
}

/// A game's component with a field that declares no default.
const Heading = extern struct {
    angle: f32,
    speed: f32 = 3,
};

test "an entity's components are listed in the order they were registered" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.registerComponents(.{Tally});
    const thing = try app.world.spawnWith(.{ Tally{ .points = 3 }, components.Sprite{}, components.Transform2D{} });

    var found: [8]ComponentValue = undefined;
    const listed = app.componentsOf(thing, &found);
    try testing.expectEqual(@as(usize, 3), listed.len);
    try testing.expectEqualStrings("Transform2D", listed[0].name);
    try testing.expectEqualStrings("Sprite", listed[1].name);
    try testing.expectEqualStrings("Tally", listed[2].name);
    try testing.expectEqual(@as(?u32, 3), (try listed[2].value.field("points")).get(u32));
    try testing.expect(app.types.find(@typeName(Tally)) == listed[2].value.type);

    // As many as there is room for.
    try testing.expectEqual(@as(usize, 1), app.componentsOf(thing, found[0..1]).len);
}

test "a component is added by its name holding its defaults, and taken off by it" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.registerComponents(.{Heading});
    const thing = try app.world.spawnWith(.{components.Transform2D{}});

    const collider = try app.addComponentNamed(thing, "Collider2D");
    try testing.expectEqual(@as(?f32, 1), (try collider.field("friction")).get(f32));
    try (try collider.field("friction")).setFloat(0.25);

    // One it has is handed back as it is, not started again.
    const again = try app.addComponentNamed(thing, "Collider2D");
    try testing.expectEqual(@as(?f32, 0.25), (try again.field("friction")).get(f32));
    try testing.expectEqual(@as(f32, 0.25), app.world.get(thing, components.Collider2D).?.friction);

    // A field with no default of its own starts at zero.
    _ = try app.addComponentNamed(thing, "Heading");
    try testing.expectEqual(Heading{ .angle = 0, .speed = 3 }, app.world.get(thing, Heading).?.*);

    try app.removeComponentNamed(thing, "Collider2D");
    try testing.expect(!app.world.has(thing, components.Collider2D));
    try app.removeComponentNamed(thing, "Collider2D");
    try testing.expect(app.world.has(thing, Heading));

    try testing.expectError(error.NoSuchComponent, app.addComponentNamed(thing, "Mystery"));
    try testing.expectError(error.NoSuchComponent, app.removeComponentNamed(thing, "Mystery"));
    app.world.despawn(thing);
    try testing.expectError(error.NoSuchEntity, app.addComponentNamed(thing, "Sprite"));
}

test "the engine's calls are made by name, and what they return comes back, errors too" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    const door = try app.world.spawn();
    const other = try app.world.spawn();

    var name: []const u8 = "door";
    try app.callNamed("setName", &.{ .of(&door), .of(&name) }, null);
    var answer: ?ecs.Entity = null;
    try app.callNamed("find", &.{.of(&name)}, .of(&answer));
    try testing.expect(answer.?.eql(door));

    // An error is returned, not dropped.
    try testing.expectError(error.NameTaken, app.callNamed("setName", &.{ .of(&other), .of(&name) }, null));
    var path: []const u8 = "no/such/scene.json";
    var options: scene.LoadOptions = .{};
    try testing.expectError(error.FileNotFound, app.callNamed("readScene", &.{ .of(&path), .of(&options) }, null));

    // And a value that comes with the chance of one.
    var copied: []const u8 = "level 3";
    try app.callNamed("setClipboardText", &.{.of(&copied)}, null);
    var pasted: []const u8 = "";
    try app.callNamed("clipboardText", &.{}, .of(&pasted));
    try testing.expectEqualStrings("level 3", pasted);

    try testing.expectError(error.NoSuchMethod, app.callNamed("launchMissiles", &.{}, null));
    try testing.expectError(error.ArgumentCount, app.callNamed("quit", &.{.of(&name)}, null));
    try app.callNamed("quit", &.{}, null);
    try testing.expect(!app.running);
}
