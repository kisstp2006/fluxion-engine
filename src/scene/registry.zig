// SPDX-License-Identifier: BSD-3-Clause

//! What scenes can hold - every component registered, each under the name a
//! scene gives it - and the components a scene held that nothing here is
//! registered as, kept with their entities to be written back.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const json = @import("fluxion_json");
const reflect = @import("fluxion_reflect");

const signals = @import("../core/signals.zig");
const scene_read = @import("scene_read.zig");
const scene_write = @import("scene_write.zig");

const Entity = ecs.Entity;
const World = ecs.World;
const ComponentId = ecs.component.Id;
const Saving = scene_write.Saving;
const writeComponent = scene_write.writeComponent;
const Loading = scene_read.Loading;
const readComponent = scene_read.readComponent;

/// One of an entity's components, as `Registry.componentsOf` lists them.
pub const ComponentValue = struct {
    /// What a scene calls it.
    name: []const u8,
    value: reflect.Value,
};

pub const ComponentError = error{
    /// No component is registered under that name. See
    /// `App.registerComponents`.
    NoSuchComponent,
    /// The entity has been despawned, or never was.
    NoSuchEntity,
} || World.Error;

/// What scenes can hold, and what each component is called in one.
pub const Registry = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Where in `entries` each type is, by its reflected id: a script finds
    /// a component by its type at every use.
    by_type: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    pub const Error = error{
        /// Another type is registered under that name. Declare
        /// `pub const scene_name` on one of them - or, when it is their
        /// `reflect_name`s that are the same, change one.
        ComponentNameTaken,
    } || Allocator.Error;

    pub const Entry = struct {
        name: []const u8,
        key: ecs.component.Key,
        /// What the component is made of, for a value of it whose type is
        /// known only at run time. See `App.componentOf`.
        type: *const reflect.Type,
        /// What it can say: its `pub const signals`. See `App.signal`.
        signals: []const signals.Decl,
        idIn: *const fn (world: *World) World.Error!ComponentId,
        findIdIn: *const fn (world: *const World) ?ComponentId,
        /// Put one holding its defaults on an entity, or overwrite the one
        /// it has with them.
        addTo: *const fn (world: *World, entity: Entity) (World.Error || error{NoSuchEntity})!void,
        removeFrom: *const fn (world: *World, entity: Entity) World.Error!void,
        write: *const fn (s: *Saving, w: *json.Writer, cell: *const anyopaque) json.Writer.Error!void,
        read: *const fn (l: *Loading, cell: *anyopaque) anyerror!void,

        fn of(comptime T: type, name: []const u8) Entry {
            const Shim = struct {
                /// Its declared defaults, and zero where it declares none: a
                /// component added by hand has to start from something.
                const initial: T = reflect.initialValue(T) orelse std.mem.zeroes(T);

                fn idIn(world: *World) World.Error!ComponentId {
                    return world.idOf(T);
                }
                fn findIdIn(world: *const World) ?ComponentId {
                    return world.findId(T);
                }
                fn addTo(world: *World, entity: Entity) (World.Error || error{NoSuchEntity})!void {
                    return world.add(entity, initial);
                }
                fn removeFrom(world: *World, entity: Entity) World.Error!void {
                    return world.remove(entity, T);
                }
                fn write(s: *Saving, w: *json.Writer, cell: *const anyopaque) json.Writer.Error!void {
                    return writeComponent(s, w, T, @ptrCast(@alignCast(cell)));
                }
                fn read(l: *Loading, cell: *anyopaque) anyerror!void {
                    return readComponent(l, T, @ptrCast(@alignCast(cell)));
                }
            };
            return .{
                .name = name,
                .key = ecs.component.keyOf(T),
                .type = reflect.typeOf(T),
                .signals = signals.declsOf(T),
                .idIn = Shim.idIn,
                .findIdIn = Shim.findIdIn,
                .addTo = Shim.addTo,
                .removeFrom = Shim.removeFrom,
                .write = Shim.write,
                .read = Shim.read,
            };
        }

        /// The component this stands for on `entity`, as a value whose type
        /// is known only at run time: read and written in place. Null when
        /// the entity has none.
        pub fn valueOn(self: *const Entry, world: *World, entity: Entity) ?reflect.Value {
            const id = self.findIdIn(world) orelse return null;
            const cell = world.cellOf(entity, id) orelse return null;
            return .init(self.type, cell);
        }
    };

    pub fn deinit(self: *Registry, gpa: Allocator) void {
        self.entries.deinit(gpa);
        self.by_type.deinit(gpa);
    }

    /// Let scenes hold `T`s, under `name`, which must outlive the registry.
    /// A type registered again is left as it was.
    pub fn add(self: *Registry, gpa: Allocator, comptime T: type, name: []const u8) Error!void {
        const key = ecs.component.keyOf(T);
        for (self.entries.items) |entry| {
            if (entry.key == key) return;
            if (std.mem.eql(u8, entry.name, name)) return error.ComponentNameTaken;
        }
        const entry: Entry = .of(T, name);
        try self.by_type.put(gpa, entry.type.id, @intCast(self.entries.items.len));
        errdefer _ = self.by_type.remove(entry.type.id);
        try self.entries.append(gpa, entry);
    }

    pub fn find(self: *const Registry, name: []const u8) ?*const Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    /// The one registered for the type `t`.
    pub fn findType(self: *const Registry, t: *const reflect.Type) ?*const Entry {
        const at = self.by_type.get(t.id) orelse return null;
        const entry = &self.entries.items[at];
        return if (entry.type.same(t)) entry else null;
    }

    /// The component called `name` on an entity: see `App.componentOf`.
    pub fn componentOf(self: *const Registry, world: *World, entity: Entity, name: []const u8) ?reflect.Value {
        const entry = self.find(name) orelse return null;
        return entry.valueOn(world, entity);
    }

    /// The component of type `t` on an entity.
    pub fn componentOfType(self: *const Registry, world: *World, entity: Entity, t: *const reflect.Type) ?reflect.Value {
        const entry = self.findType(t) orelse return null;
        return entry.valueOn(world, entity);
    }

    /// Every registered component an entity has, in the order they were
    /// registered, as many as `found` holds.
    pub fn componentsOf(self: *const Registry, world: *World, entity: Entity, found: []ComponentValue) []ComponentValue {
        var count: usize = 0;
        for (self.entries.items) |*entry| {
            if (count == found.len) break;
            const value = entry.valueOn(world, entity) orelse continue;
            found[count] = .{ .name = entry.name, .value = value };
            count += 1;
        }
        return found[0..count];
    }

    /// Put the component called `name` on an entity, holding its defaults,
    /// and hand it back; one it has already is handed back as it is.
    pub fn addNamed(self: *const Registry, world: *World, entity: Entity, name: []const u8) ComponentError!reflect.Value {
        const entry = self.find(name) orelse return error.NoSuchComponent;
        if (entry.valueOn(world, entity)) |held| return held;
        try entry.addTo(world, entity);
        return entry.valueOn(world, entity).?;
    }
};

/// Components scenes held that nothing here is registered as, each kept with
/// its entity as the scene had it and written back with it when a scene is
/// saved. A value is kept as compact JSON, which holds a number to its last
/// digit whether the scene was JSON or CBOR. A string is kept as a string:
/// a UUID in one naming an entity is not pointed anywhere new, as a
/// registered component's `Entity` is when a scene is loaded twice.
pub const Unknown = struct {
    /// Each entity's, in the order its scene had them. An array map, so that
    /// `forgetDead` can walk it by index while removing from it.
    by_entity: std.AutoArrayHashMapUnmanaged(Entity, std.ArrayList(Component)) = .empty,

    pub const Component = struct {
        name: []const u8,
        /// Its value, as compact JSON.
        value: []const u8,
    };

    pub fn deinit(self: *Unknown, gpa: Allocator) void {
        for (self.by_entity.values()) |*list| freeAll(gpa, list);
        self.by_entity.deinit(gpa);
    }

    /// Every one forgotten: the world was cleared.
    pub fn clear(self: *Unknown, gpa: Allocator) void {
        for (self.by_entity.values()) |*list| freeAll(gpa, list);
        self.by_entity.clearRetainingCapacity();
    }

    /// An entity's, in the order its scene had them.
    pub fn of(self: *const Unknown, entity: Entity) []const Component {
        const list = self.by_entity.getPtr(entity) orelse return &.{};
        return list.items;
    }

    /// Keep one for `entity`. It takes `name` and `value`, which `gpa`
    /// made, once it has returned.
    pub fn keep(self: *Unknown, gpa: Allocator, entity: Entity, name: []const u8, value: []const u8) Allocator.Error!void {
        const slot = try self.by_entity.getOrPut(gpa, entity);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(gpa, .{ .name = name, .value = value });
    }

    /// Forget the one called `name` of an entity's. Whether there was one.
    pub fn remove(self: *Unknown, gpa: Allocator, entity: Entity, name: []const u8) bool {
        const list = self.by_entity.getPtr(entity) orelse return false;
        for (list.items, 0..) |kept, at| {
            if (!std.mem.eql(u8, kept.name, name)) continue;
            gpa.free(kept.name);
            gpa.free(kept.value);
            _ = list.orderedRemove(at);
            return true;
        }
        return false;
    }

    /// Forget those of every entity that has died. Once a frame, as the
    /// names are.
    pub fn forgetDead(self: *Unknown, gpa: Allocator, world: *const World) void {
        // Backwards, so the entry a swap-remove moves into the gap has
        // already been looked at.
        var at = self.by_entity.count();
        while (at > 0) {
            at -= 1;
            if (world.isAlive(self.by_entity.keys()[at])) continue;
            freeAll(gpa, &self.by_entity.values()[at]);
            self.by_entity.swapRemoveAt(at);
        }
    }

    fn freeAll(gpa: Allocator, list: *std.ArrayList(Component)) void {
        for (list.items) |kept| {
            gpa.free(kept.name);
            gpa.free(kept.value);
        }
        list.deinit(gpa);
    }
};

/// One whole value from `r` into `w`, token by token: a number as the digits
/// it was read as, a string as its text.
pub fn copyValue(r: *json.Reader, w: *json.Writer) (json.Reader.Error || json.Writer.Error)!void {
    var depth: usize = 0;
    while (true) {
        switch ((try r.next()) orelse return error.SyntaxError) {
            .object_begin => {
                try w.beginObject();
                depth += 1;
            },
            .array_begin => {
                try w.beginArray();
                depth += 1;
            },
            .object_end => {
                try w.endObject();
                depth -= 1;
            },
            .array_end => {
                try w.endArray();
                depth -= 1;
            },
            .key => |name| try w.key(name),
            .string => |text| try w.writeString(text),
            .number => |number| try w.writeNumber(number),
            .bool => |value| try w.writeBool(value),
            .null => try w.writeNull(),
        }
        if (depth == 0) return;
    }
}

/// What `T` is called in a scene, and by `App.componentOf`: its `scene_name`
/// if it declares one, then its `reflect_name`, and otherwise its type name
/// without the path in front - `Wander`, not `creatures.Wander`.
pub fn nameOf(comptime T: type) []const u8 {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => {
            if (@hasDecl(T, "scene_name")) return T.scene_name;
            if (@hasDecl(T, "reflect_name")) return T.reflect_name;
        },
        else => {},
    }
    const full = @typeName(T);
    const end = std.mem.indexOfScalar(u8, full, '(') orelse full.len;
    const start = if (std.mem.lastIndexOfScalar(u8, full[0..end], '.')) |dot| dot + 1 else 0;
    return full[start..];
}
