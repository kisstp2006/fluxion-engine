// SPDX-License-Identifier: BSD-3-Clause

//! Groups: names entities are put under - "enemies", "pickups" - to be found
//! and called together, wherever they are in the tree. Kept beside the
//! world, as names are, and written into a scene with each entity. A group is
//! made the first time it is named, and stays once it is empty.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");

const App = @import("../App.zig");

const Entity = ecs.Entity;

pub const Groups = struct {
    /// Each group's members, in the order they joined. Each name is owned.
    by_name: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(Entity)) = .empty,

    pub fn deinit(self: *Groups, gpa: Allocator) void {
        self.freeAll(gpa);
        self.by_name.deinit(gpa);
    }

    /// Every group gone, as a world thrown away takes them.
    pub fn clear(self: *Groups, gpa: Allocator) void {
        self.freeAll(gpa);
        self.by_name.clearRetainingCapacity();
    }

    fn freeAll(self: *Groups, gpa: Allocator) void {
        for (self.by_name.keys(), self.by_name.values()) |name, *list| {
            gpa.free(name);
            list.deinit(gpa);
        }
    }

    /// Put an entity in a group. Once is enough: being put in again changes
    /// nothing.
    pub fn add(self: *Groups, gpa: Allocator, world: *const ecs.World, entity: Entity, group: []const u8) (error{NoSuchEntity} || Allocator.Error)!void {
        if (!world.isAlive(entity)) return error.NoSuchEntity;
        if (self.has(entity, group)) return;
        const list = self.by_name.getPtr(group) orelse blk: {
            const copy = try gpa.dupe(u8, group);
            errdefer gpa.free(copy);
            try self.by_name.put(gpa, copy, .empty);
            break :blk self.by_name.getPtr(copy).?;
        };
        try list.append(gpa, entity);
    }

    /// Take an entity out of a group.
    pub fn remove(self: *Groups, entity: Entity, group: []const u8) void {
        const list = self.by_name.getPtr(group) orelse return;
        for (list.items, 0..) |member, at| {
            if (!member.eql(entity)) continue;
            _ = list.orderedRemove(at);
            return;
        }
    }

    pub fn has(self: *const Groups, entity: Entity, group: []const u8) bool {
        const list = self.by_name.getPtr(group) orelse return false;
        for (list.items) |member| {
            if (member.eql(entity)) return true;
        }
        return false;
    }

    /// A group's living members, in the order they joined: a slice good
    /// until a member joins or leaves. One despawned since the frame began
    /// is taken out now rather than at its end.
    pub fn members(self: *Groups, world: *const ecs.World, group: []const u8) []const Entity {
        const held = self.by_name.getPtr(group) orelse return &.{};
        dropDead(held, world);
        return held.items;
    }

    /// The groups an entity is in, as many as `found` holds.
    pub fn of(self: *const Groups, entity: Entity, found: [][]const u8) [][]const u8 {
        var count: usize = 0;
        for (self.by_name.keys(), self.by_name.values()) |name, held| {
            if (count == found.len) break;
            for (held.items) |member| {
                if (!member.eql(entity)) continue;
                found[count] = name;
                count += 1;
                break;
            }
        }
        return found[0..count];
    }

    /// Take the dead out of every group.
    pub fn forgetDead(self: *Groups, world: *const ecs.World) void {
        for (self.by_name.values()) |*held| dropDead(held, world);
    }

    fn dropDead(held: *std.ArrayListUnmanaged(Entity), world: *const ecs.World) void {
        var at = held.items.len;
        while (at > 0) {
            at -= 1;
            if (!world.isAlive(held.items[at])) _ = held.orderedRemove(at);
        }
    }
};

/// Call a method on every living member of a group, in the order they
/// joined: see `App.callGroup`. The members are copied first, so a call may
/// add to the group or take from it.
pub fn callAll(app: *App, group: []const u8, method: []const u8) anyerror!void {
    const members = try app.gpa.dupe(Entity, app.groups.members(&app.world, group));
    defer app.gpa.free(members);
    for (members) |member| {
        if (!app.world.isAlive(member)) continue;
        app.callMethodOn(member, method, &.{}) catch |err| switch (err) {
            error.NoSuchMethod => continue,
            else => return err,
        };
    }
}
