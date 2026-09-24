// SPDX-License-Identifier: BSD-3-Clause

//! What an entity's script's `@export`s are given in place of their
//! defaults: by the field's name, as JSON, kept beside the world as its
//! names are - `app.exports`. A scene writes them on the entity,
//!
//! ```json
//! { "name": "guard", "Script": { "source": "res://guard.flux" },
//!   "exports": { "hp": 20, "mood": "angry", "path": [[0, 0], [16, 0]] } }
//! ```
//!
//! and the scripts set them on the instance the moment it is made, before
//! its `ready`: a number, a bool or text as itself, a vector as its numbers,
//! a colour as `"#rrggbbaa"`, an enum's member by its name, an entity by its
//! UUID, a list as a list. A field the struct no longer has, or one written
//! as something it does not hold, is said and passed over.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const json = @import("fluxion_json");

const Entity = ecs.Entity;

pub const Exports = struct {
    by: std.AutoArrayHashMapUnmanaged(Entity, json.Document) = .empty,

    pub fn deinit(self: *Exports, gpa: Allocator) void {
        self.clear();
        self.by.deinit(gpa);
    }

    /// Every entity's gone: the world was cleared.
    pub fn clear(self: *Exports) void {
        for (self.by.values()) |doc| doc.deinit();
        self.by.clearRetainingCapacity();
    }

    /// The values an entity's fields are given, an object by field; null
    /// for one with none.
    pub fn of(self: *const Exports, entity: Entity) ?json.Value {
        const doc = self.by.get(entity) orelse return null;
        return doc.root;
    }

    /// The value `name` is given, or null for one at its default.
    pub fn get(self: *const Exports, entity: Entity, name: []const u8) ?json.Value {
        const values = self.of(entity) orelse return null;
        const value = values.get(name);
        return if (values.has(name)) value else null;
    }

    /// Give `name` a value of its own, copied.
    pub fn set(self: *Exports, gpa: Allocator, entity: Entity, name: []const u8, value: json.Value) json.EditError!void {
        const doc = try self.documentOf(gpa, entity);
        try doc.root.put(name, try doc.clone(value));
    }

    /// `name` back to its default. Says whether it had a value of its own.
    pub fn remove(self: *Exports, entity: Entity, name: []const u8) bool {
        const doc = self.by.getPtr(entity) orelse return false;
        const had = doc.root.remove(name);
        if (doc.root.len() == 0) self.forget(entity);
        return had;
    }

    /// Every value an entity's fields are given, in place of what it had:
    /// the object a scene wrote.
    pub fn setAll(self: *Exports, gpa: Allocator, entity: Entity, values: json.Value) json.EditError!void {
        if (values.asObject() == null) return error.NotAnObject;
        self.forget(entity);
        if (values.len() == 0) return;
        const doc = try self.documentOf(gpa, entity);
        doc.root = try doc.clone(values);
    }

    /// What `from`'s fields are given, given to `to` as well: a copy of an
    /// entity.
    pub fn copy(self: *Exports, gpa: Allocator, from: Entity, to: Entity) json.EditError!void {
        const values = self.of(from) orelse return self.forget(to);
        try self.setAll(gpa, to, values);
    }

    pub fn forget(self: *Exports, entity: Entity) void {
        const removed = self.by.fetchSwapRemove(entity) orelse return;
        removed.value.deinit();
    }

    /// Let go of what the dead had. Once a frame, with the names.
    pub fn forgetDead(self: *Exports, world: *const ecs.World) void {
        var at = self.by.count();
        while (at > 0) {
            at -= 1;
            if (world.isAlive(self.by.keys()[at])) continue;
            self.by.values()[at].deinit();
            self.by.swapRemoveAt(at);
        }
    }

    fn documentOf(self: *Exports, gpa: Allocator, entity: Entity) Allocator.Error!*json.Document {
        const entry = try self.by.getOrPut(gpa, entity);
        if (!entry.found_existing) {
            entry.value_ptr.* = json.Document.init(gpa) catch |err| {
                self.by.swapRemoveAt(entry.index);
                return err;
            };
            entry.value_ptr.root = entry.value_ptr.object() catch |err| {
                entry.value_ptr.deinit();
                self.by.swapRemoveAt(entry.index);
                return err;
            };
        }
        return entry.value_ptr;
    }
};

test "an entity's values are set, read, taken back to their defaults, copied and let go of" {
    var exports: Exports = .{};
    defer exports.deinit(testing.allocator);
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    const guard = try world.spawn();
    const other = try world.spawn();

    var doc = try json.parse(testing.allocator, "{ \"hp\": 20, \"path\": [[0, 0], [16, 0]] }", .{});
    defer doc.deinit();
    try exports.setAll(testing.allocator, guard, doc.root);
    try testing.expectEqual(@as(i64, 20), exports.get(guard, "hp").?.asInt(i64).?);
    try testing.expect(exports.get(guard, "mood") == null);
    try exports.set(testing.allocator, guard, "hp", .{ .int = 30 });
    try testing.expectEqual(@as(i64, 30), exports.get(guard, "hp").?.asInt(i64).?);

    try exports.copy(testing.allocator, guard, other);
    try testing.expect(exports.remove(guard, "hp"));
    try testing.expect(exports.remove(guard, "path"));
    try testing.expect(exports.of(guard) == null);
    try testing.expectEqual(@as(usize, 2), exports.of(other).?.len());

    world.despawn(other);
    exports.forgetDead(&world);
    try testing.expect(exports.of(other) == null);
}
