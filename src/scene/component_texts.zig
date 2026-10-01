// SPDX-License-Identifier: BSD-3-Clause

//! Words a component keeps beside it rather than in it: a label's, a
//! button's, a field's and its placeholder, a tooltip - as long as they need
//! to be, which a component cannot hold, being plain data of one size.
//!
//! A component says which of its words are kept here with an `attr.Text` on
//! its type:
//!
//! ```zig
//! pub const reflect_attributes = .{fx.attr.Text{ .name = "text", .multiline = true }};
//! ```
//!
//! and they are the app's, under the entity and the name: `app.textOf(e,
//! fx.Label, "text")` and `app.setText(e, fx.Label, "text", "Hello")` from
//! Zig, `label.text` from a script, a field of the component's in a scene
//! and in an editor's inspector. They go with the entity, at the end of the
//! frame it dies in.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const reflect = @import("fluxion_reflect");

const App = @import("../App.zig");
const attr = @import("../reflect/attr.zig");

const Entity = ecs.Entity;

pub const Key = struct {
    entity: Entity,
    /// The component's name and the text's, hashed: see `keyOf`.
    name: u64,
};

/// The key of one of a component's texts, from the name a scene gives the
/// component and the text's own.
pub fn keyOf(component: []const u8, property: []const u8) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(component);
    hash.update(".");
    hash.update(property);
    return hash.final();
}

/// Every text `T` keeps here, as its `attr.Text`s say.
pub fn declared(comptime T: type) []const attr.Text {
    comptime {
        if (!@hasDecl(T, "reflect_attributes")) return &.{};
        var found: []const attr.Text = &.{};
        for (T.reflect_attributes) |attribute| {
            if (@TypeOf(attribute) == attr.Text) found = found ++ .{attribute};
        }
        return found;
    }
}

/// The text `property` a component's type keeps beside it, if it keeps one.
pub fn attributeOf(owner: *const reflect.Type, property: []const u8) ?*const attr.Text {
    for (owner.attributes.slice()) |*attribute| {
        const text = attribute.as(attr.Text) orelse continue;
        if (std.mem.eql(u8, text.name, property)) return text;
    }
    return null;
}

/// Say `text` in a component's text by the names a scene gives them: see
/// `App.setTextNamed`. The component has to be registered and keep a text
/// of that name.
pub fn setNamed(app: *App, entity: Entity, component: []const u8, property: []const u8, text: []const u8) !void {
    if (!app.world.isAlive(entity)) return error.NoSuchEntity;
    const entry = app.scene_components.find(component) orelse return error.NoSuchComponent;
    if (attributeOf(entry.type, property) == null) return error.NoSuchText;
    try app.texts.set(app.gpa, entity, keyOf(component, property), text);
}

/// The key of `T`'s text `property`, and a build that stops if `T` keeps no
/// text of that name.
pub fn keyFor(comptime T: type, comptime property: []const u8) u64 {
    comptime {
        for (declared(T)) |text| {
            if (std.mem.eql(u8, text.name, property)) return keyOf(T.reflect_name, property);
        }
        @compileError("fluxion-engine: " ++ @typeName(T) ++ " keeps no text called " ++ property);
    }
}

pub const Texts = struct {
    by_key: std.AutoHashMapUnmanaged(Key, []u8) = .empty,

    pub fn deinit(self: *Texts, gpa: Allocator) void {
        var it = self.by_key.valueIterator();
        while (it.next()) |text| gpa.free(text.*);
        self.by_key.deinit(gpa);
    }

    /// What it says: empty for nothing.
    pub fn get(self: *const Texts, entity: Entity, name: u64) []const u8 {
        return self.by_key.get(.{ .entity = entity, .name = name }) orelse "";
    }

    /// Say `text`, in memory of its own. Empty is nothing kept.
    pub fn set(self: *Texts, gpa: Allocator, entity: Entity, name: u64, text: []const u8) Allocator.Error!void {
        const key: Key = .{ .entity = entity, .name = name };
        if (text.len == 0) {
            if (self.by_key.fetchRemove(key)) |gone| gpa.free(gone.value);
            return;
        }
        if (self.by_key.getPtr(key)) |held| if (std.mem.eql(u8, held.*, text)) return;
        const copy = try gpa.dupe(u8, text);
        errdefer gpa.free(copy);
        const slot = try self.by_key.getOrPut(gpa, key);
        if (slot.found_existing) gpa.free(slot.value_ptr.*);
        slot.value_ptr.* = copy;
    }

    /// Let go of what the dead said. Once a frame.
    pub fn forgetDead(self: *Texts, app: *App) void {
        var dead: std.ArrayList(Key) = .empty;
        defer dead.deinit(app.gpa);
        var it = self.by_key.keyIterator();
        while (it.next()) |key| {
            if (app.world.isAlive(key.entity)) continue;
            dead.append(app.gpa, key.*) catch break;
        }
        for (dead.items) |key| {
            if (self.by_key.fetchRemove(key)) |gone| app.gpa.free(gone.value);
        }
    }

    pub fn clear(self: *Texts, app: *App) void {
        var it = self.by_key.valueIterator();
        while (it.next()) |text| app.gpa.free(text.*);
        self.by_key.clearRetainingCapacity();
    }
};

test "a text is kept under its entity and name, in memory of its own, and nothing is none" {
    var texts: Texts = .{};
    defer texts.deinit(testing.allocator);
    const e: Entity = .{ .index = 3, .generation = 1 };
    const name = keyOf("Label", "text");
    var typed = "Hello".*;
    try texts.set(testing.allocator, e, name, &typed);
    typed[0] = 'J';
    try testing.expectEqualStrings("Hello", texts.get(e, name));
    try testing.expectEqualStrings("", texts.get(e, keyOf("Button", "text")));
    // The same slot, another life: nothing said.
    try testing.expectEqualStrings("", texts.get(.{ .index = 3, .generation = 2 }, name));
    try texts.set(testing.allocator, e, name, "");
    try testing.expectEqual(@as(usize, 0), texts.by_key.count());
}
