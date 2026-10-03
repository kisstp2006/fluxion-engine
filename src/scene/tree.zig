// SPDX-License-Identifier: BSD-3-Clause

//! The tree: each parent's children in their order, the roots as one family
//! of their own, and what goes through it - a path of names, a new parent,
//! a branch despawned.
//!
//! Siblings are the entities with the same `Parent`. Each entity's place
//! among them is a rank, kept beside the world for the ones given one by
//! `setIndex` or a scene's list; every other comes after those, in the order
//! its handle was given out, so a world nobody reorders pays nothing. The
//! families are built again when they are next asked for after the world
//! has changed shape, or a place was given.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");

const App = @import("../App.zig");
const components = @import("components.zig");
const hierarchy = @import("hierarchy.zig");
const NameError = @import("names.zig").NameError;

const Entity = ecs.Entity;

/// Despawn everything whose parent has died, and what hangs from that in
/// turn: see `Parent`. Once a frame, a pass of `app/frame_steps.zig`, because a
/// game despawns through `world.despawn` and nothing here sees it. It goes
/// round until a pass finds nothing, so a turret's barrel goes one pass
/// after the turret.
pub fn despawnOrphans(app: *App) !void {
    var orphans: std.ArrayList(Entity) = .empty;
    defer orphans.deinit(app.gpa);
    while (true) {
        orphans.clearRetainingCapacity();
        var it = try ecs.Query(.{components.Parent}).over(&app.world);
        while (it.next()) |chunk| {
            for (chunk.slice(components.Parent), chunk.entities) |held, entity| {
                if (held.entity.isNone() or app.world.isAlive(held.entity)) continue;
                try orphans.append(app.gpa, entity);
            }
        }
        // Found first and despawned after: a despawn moves rows, and the
        // slices above point at rows.
        if (orphans.items.len == 0) return;
        for (orphans.items) |orphan| app.world.despawn(orphan);
    }
}

pub const Tree = struct {
    /// Each placed entity's rank among its siblings.
    ranks: std.AutoArrayHashMapUnmanaged(Entity, u64) = .empty,
    /// The next rank given out.
    next_rank: u64 = 0,
    /// Each parent's children, a run of `order`: `.none` for the roots.
    families: std.AutoHashMapUnmanaged(Entity, Family) = .empty,
    order: std.ArrayListUnmanaged(Entity) = .empty,
    /// The world's `structure` when the families were built; null when
    /// something has changed that the world does not count.
    built: ?u64 = null,

    pub const Family = struct { start: u32, count: u32 };

    /// Ranks given out start below this, so every entity with a place comes
    /// before every one that has never been given one.
    const unplaced: u64 = 1 << 48;

    pub fn deinit(self: *Tree, gpa: Allocator) void {
        self.ranks.deinit(gpa);
        self.families.deinit(gpa);
        self.order.deinit(gpa);
    }

    /// Every place forgotten, as a world thrown away takes them.
    pub fn clear(self: *Tree, _: *App) void {
        self.ranks.clearRetainingCapacity();
        self.forget();
    }

    /// Build the families again when next asked.
    pub fn forget(self: *Tree) void {
        self.built = null;
    }

    /// Where an entity comes among its siblings, as a number to sort by.
    fn rank(self: *const Tree, entity: Entity) u64 {
        return self.ranks.get(entity) orelse unplaced + entity.index;
    }

    /// Whether `a` comes before `b` among their parent's children.
    pub fn before(self: *const Tree, a: Entity, b: Entity) bool {
        return self.rank(a) < self.rank(b);
    }

    /// A parent's children in their order, `.none` for the roots: a slice
    /// good until the world next changes shape. None when there is no
    /// memory to build the families in.
    pub fn children(self: *Tree, gpa: Allocator, world: *ecs.World, parent: Entity) []const Entity {
        self.build(gpa, world) catch return &.{};
        const family = self.families.get(parent) orelse return &.{};
        return self.order.items[family.start..][0..family.count];
    }

    fn build(self: *Tree, gpa: Allocator, world: *ecs.World) Allocator.Error!void {
        if (self.built == world.structure) return;
        const Member = struct { parent: Entity, rank: u64, entity: Entity };
        var members: std.ArrayListUnmanaged(Member) = .empty;
        defer members.deinit(gpa);
        try members.ensureTotalCapacity(gpa, world.count());
        for (world.archetypeSlice()) |*archetype| {
            for (archetype.entities.items) |entity| {
                members.appendAssumeCapacity(.{ .parent = hierarchy.parentOf(world, entity), .rank = self.rank(entity), .entity = entity });
            }
        }
        std.mem.sort(Member, members.items, {}, struct {
            fn before(_: void, a: Member, b: Member) bool {
                const pa = a.parent.toInt();
                const pb = b.parent.toInt();
                if (pa != pb) return pa < pb;
                return a.rank < b.rank;
            }
        }.before);
        self.families.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
        try self.order.ensureTotalCapacity(gpa, members.items.len);
        for (members.items, 0..) |member, at| {
            self.order.appendAssumeCapacity(member.entity);
            const family = try self.families.getOrPut(gpa, member.parent);
            if (!family.found_existing) family.value_ptr.* = .{ .start = @intCast(at), .count = 0 };
            family.value_ptr.count += 1;
        }
        self.built = world.structure;
    }

    /// Where an entity is among its parent's children, from nought. Null
    /// for one that is not alive.
    pub fn indexOf(self: *Tree, gpa: Allocator, world: *ecs.World, entity: Entity) ?u32 {
        if (!world.isAlive(entity)) return null;
        for (self.children(gpa, world, hierarchy.parentOf(world, entity)), 0..) |sibling, at| {
            if (sibling.eql(entity)) return @intCast(at);
        }
        return null;
    }

    /// Put an entity at `index` among its parent's children, the ones from
    /// there on moving along one. An index past the end is the end.
    pub fn setIndex(self: *Tree, gpa: Allocator, world: *ecs.World, entity: Entity, index: u32) (error{NoSuchEntity} || Allocator.Error)!void {
        if (!world.isAlive(entity)) return error.NoSuchEntity;
        const parent = hierarchy.parentOf(world, entity);

        // Numbered afresh, the whole family, so none of it is left half placed.
        var family: std.ArrayList(Entity) = .empty;
        defer family.deinit(gpa);
        for (self.children(gpa, world, parent)) |other| {
            if (!other.eql(entity)) try family.append(gpa, other);
        }
        try family.insert(gpa, @min(index, family.items.len), entity);
        try self.placeInOrder(gpa, family.items);
    }

    /// Give entities places in the order given, after every place given out
    /// before.
    pub fn placeInOrder(self: *Tree, gpa: Allocator, entities: []const Entity) Allocator.Error!void {
        try self.ranks.ensureUnusedCapacity(gpa, entities.len);
        for (entities) |entity| {
            self.ranks.putAssumeCapacity(entity, self.next_rank);
            self.next_rank += 1;
        }
        self.forget();
    }

    /// Give every living entity that has no place one, in the order it is
    /// in now, so that what is placed next comes after it rather than before.
    pub fn placeTheRest(self: *Tree, gpa: Allocator, world: *ecs.World) Allocator.Error!void {
        var rest: std.ArrayList(Entity) = .empty;
        defer rest.deinit(gpa);
        for (world.archetypeSlice()) |*archetype| {
            for (archetype.entities.items) |entity| {
                if (!self.ranks.contains(entity)) try rest.append(gpa, entity);
            }
        }
        if (rest.items.len == 0) return;
        std.mem.sort(Entity, rest.items, @as(*const Tree, self), before);
        try self.placeInOrder(gpa, rest.items);
    }

    /// Forget the places of everything that has died.
    pub fn forgetDead(self: *Tree, app: *App) void {
        var at = self.ranks.count();
        while (at > 0) {
            at -= 1;
            const entity = self.ranks.keys()[at];
            if (!app.world.isAlive(entity)) self.ranks.swapRemoveAt(at);
        }
    }
};

/// The child of `parent` called `name`, the roots for `.none`.
pub fn childNamed(app: *App, parent: Entity, name: []const u8) ?Entity {
    for (app.children(parent)) |child| {
        const own = app.names.of_entity.get(child) orelse continue;
        if (std.mem.eql(u8, own, name)) return child;
    }
    return null;
}

/// Where a path of names leads from `from`: see `App.findPath`.
pub fn findPath(app: *App, from: Entity, path: []const u8) ?Entity {
    var at = if (path.len > 0 and path[0] == '/') Entity.none else from;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (at.isNone()) return null;
            at = hierarchy.parentOf(&app.world, at);
            continue;
        }
        at = childNamed(app, at, part) orelse return null;
    }
    return if (at.isNone()) null else at;
}

/// The first entity called `name` that hangs from `root`, however far down,
/// in the tree's order: the children before their children.
pub fn findIn(app: *App, root: Entity, name: []const u8) ?Entity {
    for (app.children(root)) |child| {
        if (app.names.of_entity.get(child)) |own| if (std.mem.eql(u8, own, name)) return child;
    }
    for (app.children(root)) |child| {
        if (findIn(app, child, name)) |found| return found;
    }
    return null;
}

/// What `setParent` can refuse.
pub const ParentError = error{
    /// The entity has been despawned, or never was - or the parent has.
    NoSuchEntity,
    /// The parent is the entity itself, or something that hangs from it: a
    /// loop, which nothing could be placed by.
    Loop,
} || hierarchy.PlaceError || NameError || ecs.World.Error;

/// Hang `entity` from `parent`, or from nothing for a root, last among its
/// new siblings: see `App.setParent`.
pub fn setParent(app: *App, entity: Entity, parent: Entity, keep_global: bool) ParentError!void {
    const world = &app.world;
    if (!world.isAlive(entity)) return error.NoSuchEntity;
    if (!parent.isNone()) {
        if (!world.isAlive(parent)) return error.NoSuchEntity;
        if (parent.eql(entity) or hierarchy.isDescendantOf(world, parent, entity)) return error.Loop;
    }
    if (hierarchy.parentOf(world, entity).eql(parent)) return;
    const was = if (keep_global and world.has(entity, components.Transform2D))
        hierarchy.worldTransform(world, entity) orelse return error.Unplaced
    else
        null;
    const was3d = if (keep_global and world.has(entity, components.Transform3D))
        hierarchy.worldTransform3D(world, entity) orelse return error.Unplaced
    else
        null;
    if (parent.isNone()) {
        try world.remove(entity, components.Parent);
    } else {
        world.add(entity, components.Parent.of(parent)) catch |err| return switch (err) {
            error.NoSuchEntity => error.NoSuchEntity,
            else => |other| other,
        };
    }
    try app.tree.setIndex(app.gpa, world, entity, std.math.maxInt(u32));
    if (app.names.of(world, entity)) |name| {
        var copy: [256]u8 = undefined;
        const held = copy[0..@min(name.len, copy.len)];
        @memcpy(held, name[0..held.len]);
        try app.names.setFree(app.gpa, world, entity, held);
    }
    if (was) |placed| try hierarchy.setWorldTransform(world, entity, placed);
    if (was3d) |placed| try hierarchy.setWorldTransform3D(world, entity, placed);
}

/// Despawn an entity and everything that hangs from it, now rather than at
/// the end of the frame.
pub fn despawnBranch(app: *App, entity: Entity) Allocator.Error!void {
    if (!app.world.isAlive(entity)) return;
    var doomed: std.ArrayList(Entity) = .empty;
    defer doomed.deinit(app.gpa);
    try doomed.append(app.gpa, entity);
    var at: usize = 0;
    while (at < doomed.items.len) : (at += 1) {
        try doomed.appendSlice(app.gpa, app.children(doomed.items[at]));
    }
    for (doomed.items) |e| {
        if (app.world.isAlive(e)) app.world.despawn(e);
    }
}
