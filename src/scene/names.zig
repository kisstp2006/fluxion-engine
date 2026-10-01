// SPDX-License-Identifier: BSD-3-Clause

//! What entities are called: `App.setName`, `App.find` and a path of names.
//!
//! A name is the entity's own, kept beside the world rather than in a
//! component, so naming does not move the entity to another archetype.
//! Siblings - the children of one parent, or the roots - have names of their
//! own, so a path of names leads to one thing; two entities in different
//! places may share one, as two copies of a scene do.
//!
//! Every name's text is one allocation, the key in `by_name`, which
//! `of_entity` points into and which is freed when nothing has the name any
//! more. `of_entity` is an array map, so that `forgetDead` can walk it by
//! index while removing from it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const hierarchy = @import("hierarchy.zig");
const App = @import("../App.zig");

const Entity = ecs.Entity;

/// What `Names.set` can refuse.
pub const NameError = error{
    /// A sibling is called that: another living entity with the same
    /// parent, or another root. A path of names picks out one thing.
    NameTaken,
    /// The entity has been despawned, or never was.
    NoSuchEntity,
} || Allocator.Error;

pub const Names = struct {
    /// Every named entity's name.
    of_entity: std.AutoArrayHashMapUnmanaged(Entity, []const u8) = .empty,
    /// Every name's entities, in the order they were given it: `find`'s
    /// answer is the first living one.
    by_name: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Entity)) = .empty,

    pub fn deinit(self: *Names, gpa: Allocator) void {
        self.of_entity.deinit(gpa);
        self.freeAll(gpa);
        self.by_name.deinit(gpa);
    }

    /// Every name gone, as a world thrown away takes them.
    pub fn clear(self: *Names, app: *App) void {
        self.of_entity.clearRetainingCapacity();
        self.freeAll(app.gpa);
    }

    /// Give back every name's text and list, and empty `by_name`.
    fn freeAll(self: *Names, gpa: Allocator) void {
        var it = self.by_name.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            entry.value_ptr.deinit(gpa);
        }
        self.by_name.clearRetainingCapacity();
    }

    /// Call an entity `name`, unless a sibling is called that. Calling it
    /// again renames; the text is copied.
    pub fn set(self: *Names, gpa: Allocator, world: *const ecs.World, entity: Entity, name: []const u8) NameError!void {
        if (!world.isAlive(entity)) return error.NoSuchEntity;
        if (self.of(world, entity)) |own| if (std.mem.eql(u8, own, name)) return;
        if (self.siblingNamed(world, hierarchy.parentOf(world, entity), name, entity) != null) return error.NameTaken;
        try self.give(gpa, entity, name);
    }

    /// `set`, where a sibling that has the name already gives this one the
    /// first free one after it - "Rock 2" - rather than refusing.
    pub fn setFree(self: *Names, gpa: Allocator, world: *const ecs.World, entity: Entity, wanted: []const u8) NameError!void {
        if (!world.isAlive(entity)) return error.NoSuchEntity;
        var buffer: [256]u8 = undefined;
        const name = self.freeName(world, hierarchy.parentOf(world, entity), wanted, entity, &buffer);
        if (self.of(world, entity)) |own| if (std.mem.eql(u8, own, name)) return;
        try self.give(gpa, entity, name);
    }

    /// `wanted`, or it with the first number after it that no child of
    /// `parent` but `except` is called: "Sprite", "Sprite 2", "Sprite 3".
    /// Written into `buffer` when a number is added; a name too long for it
    /// is cut.
    pub fn freeName(self: *const Names, world: *const ecs.World, parent: Entity, wanted: []const u8, except: Entity, buffer: []u8) []const u8 {
        if (self.siblingNamed(world, parent, wanted, except) == null) return wanted;
        const base = wanted[0..@min(wanted.len, buffer.len -| 8)];
        var number: usize = 2;
        while (number < 100_000) : (number += 1) {
            const tried = std.fmt.bufPrint(buffer, "{s} {d}", .{ base, number }) catch break;
            if (self.siblingNamed(world, parent, tried, except) == null) return tried;
        }
        return wanted;
    }

    /// A living child of `parent` but `except` called `name`, if there is one.
    fn siblingNamed(self: *const Names, world: *const ecs.World, parent: Entity, name: []const u8, except: Entity) ?Entity {
        const holders = self.by_name.getPtr(name) orelse return null;
        for (holders.items) |holder| {
            if (holder.eql(except) or !world.isAlive(holder)) continue;
            if (hierarchy.parentOf(world, holder).eql(parent)) return holder;
        }
        return null;
    }

    /// Give an entity a name, whoever else has it: the checks are the
    /// caller's.
    fn give(self: *Names, gpa: Allocator, entity: Entity, name: []const u8) Allocator.Error!void {
        // Everything that can fail comes before anything changes, so a failed
        // rename keeps the old name.
        try self.of_entity.ensureUnusedCapacity(gpa, 1);
        try self.by_name.ensureUnusedCapacity(gpa, 1);
        const known = self.by_name.getPtr(name);
        const copy = if (known == null) try gpa.dupe(u8, name) else null;
        errdefer if (copy) |text| gpa.free(text);
        var fresh: std.ArrayListUnmanaged(Entity) = .empty;
        errdefer fresh.deinit(gpa);
        if (known) |holders| try holders.ensureUnusedCapacity(gpa, 1) else try fresh.ensureTotalCapacity(gpa, 1);

        // Nothing below here can fail.
        self.forget(gpa, entity);
        const slot = self.by_name.getOrPutAssumeCapacity(copy orelse name);
        if (!slot.found_existing) slot.value_ptr.* = fresh;
        slot.value_ptr.appendAssumeCapacity(entity);
        self.of_entity.putAssumeCapacity(entity, slot.key_ptr.*);
    }

    /// What an entity is called, or null when it has no name or is not
    /// alive. The text lasts until the entity is renamed or despawned.
    pub fn of(self: *const Names, world: *const ecs.World, entity: Entity) ?[]const u8 {
        if (!world.isAlive(entity)) return null;
        return self.of_entity.get(entity);
    }

    /// A living entity called `name` - the first given it of those that
    /// are - or null.
    pub fn find(self: *const Names, world: *const ecs.World, name: []const u8) ?Entity {
        const holders = self.by_name.getPtr(name) orelse return null;
        for (holders.items) |holder| {
            if (world.isAlive(holder)) return holder;
        }
        return null;
    }

    /// Take one entity's name off it, if it has one, and free the text once
    /// nothing has it.
    fn forget(self: *Names, gpa: Allocator, entity: Entity) void {
        const named = self.of_entity.fetchSwapRemove(entity) orelse return;
        const slot = self.by_name.getEntry(named.value) orelse return;
        const holders = slot.value_ptr;
        for (holders.items, 0..) |holder, at| {
            if (!holder.eql(entity)) continue;
            _ = holders.orderedRemove(at);
            break;
        }
        if (holders.items.len > 0) return;
        const key = slot.key_ptr.*;
        holders.deinit(gpa);
        self.by_name.removeByPtr(slot.key_ptr);
        gpa.free(key);
    }

    /// Give back the names of everything that has died.
    pub fn forgetDead(self: *Names, app: *App) void {
        // Backwards, so the entry a swap-remove moves into the gap has
        // already been looked at.
        var at = self.of_entity.count();
        while (at > 0) {
            at -= 1;
            const entity = self.of_entity.keys()[at];
            if (!app.world.isAlive(entity)) self.forget(app.gpa, entity);
        }
    }
};
