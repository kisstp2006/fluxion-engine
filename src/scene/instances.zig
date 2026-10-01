// SPDX-License-Identifier: BSD-3-Clause

//! Scenes made as things in the world: `App.instantiate`, and the instances
//! the world holds, each by its root.
//!
//! Each instance's entities are given UUIDs of their own, made from the
//! instance's and the scene's, so two are never confused and a scene that
//! names one inside an instance finds it again every time it is read. A
//! scene saved with an instance in it writes the instance - the file it is
//! of, and what its root has that the file does not give it - so an edit of
//! the file reaches every instance of it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");

const App = @import("../App.zig");
const scene = @import("scene.zig");
const SceneHandle = @import("../assets/scene_table.zig").SceneHandle;

const Entity = ecs.Entity;

/// One instance of a scene.
pub const Instance = struct {
    scene: SceneHandle,
    /// What it made, its root not among them, the insides of the instances
    /// in it among them.
    members: []Entity,
    /// Its root as the scene made it, every field of every component, for
    /// a scene written with the instance in it to write what differs.
    template: []u8,

    fn deinit(self: Instance, gpa: Allocator) void {
        gpa.free(self.members);
        gpa.free(self.template);
    }
};

pub const Instances = struct {
    by_root: std.AutoArrayHashMapUnmanaged(Entity, Instance) = .empty,

    pub fn deinit(self: *Instances, gpa: Allocator) void {
        for (self.by_root.values()) |held| held.deinit(gpa);
        self.by_root.deinit(gpa);
    }

    /// Every instance forgotten, as a world thrown away takes them.
    pub fn clear(self: *Instances, gpa: Allocator) void {
        for (self.by_root.values()) |held| held.deinit(gpa);
        self.by_root.clearRetainingCapacity();
    }

    /// What `root` is an instance of, when it is the root of one.
    pub fn of(self: *const Instances, root: Entity) ?*const Instance {
        return self.by_root.getPtr(root);
    }

    /// The root of the instance an entity is inside of, if it is inside one
    /// - the outermost, where instances are inside instances. Not for a root
    /// itself unless it is inside another.
    pub fn holding(self: *const Instances, world: *const ecs.World, entity: Entity) ?Entity {
        var found: ?Entity = null;
        for (self.by_root.keys(), self.by_root.values()) |root, held| {
            if (!world.isAlive(root)) continue;
            for (held.members) |member| {
                if (!member.eql(entity)) continue;
                // The outermost holds the most.
                if (found) |other| {
                    if (self.by_root.getPtr(other).?.members.len >= held.members.len) break;
                }
                found = root;
                break;
            }
        }
        return found;
    }

    /// An instance made the scene's own: its insides are written as
    /// themselves from now on, and a change to the scene file reaches it no
    /// more.
    pub fn makeLocal(self: *Instances, gpa: Allocator, root: Entity) void {
        const held = self.by_root.fetchSwapRemove(root) orelse return;
        held.value.deinit(gpa);
    }

    /// Forget the instances whose root has died.
    pub fn forgetDead(self: *Instances, gpa: Allocator, world: *const ecs.World) void {
        var at = self.by_root.count();
        while (at > 0) {
            at -= 1;
            if (world.isAlive(self.by_root.keys()[at])) continue;
            self.by_root.values()[at].deinit(gpa);
            self.by_root.swapRemoveAt(at);
        }
    }
};

/// A scene made as a thing in the world: its one root, hanging from
/// `parent`, with everything else of the scene under it. See
/// `App.instantiate`.
pub fn instantiate(app: *App, scene_handle: SceneHandle, parent: Entity) !Entity {
    const held = app.scenes.get(scene_handle) orelse return error.NoSuchScene;
    if (!parent.isNone() and !app.world.isAlive(parent)) return error.NoSuchEntity;
    var made: std.ArrayList(Entity) = .empty;
    defer made.deinit(app.gpa);
    errdefer for (made.items) |e| if (app.world.isAlive(e)) app.world.despawn(e);
    const within: scene.Nesting = .{ .scene = scene_handle };
    const loaded = try scene.read(app, held.bytes, .{
        .parent = parent,
        .instance = app.newUuid(),
        .spawned = &made,
        .within = &within,
    });
    try keep(app, loaded.root, scene_handle, made.items);
    return loaded.root;
}

/// Remember `root` as an instance of `scene_handle`, which made `made`.
pub fn keep(app: *App, root: Entity, scene_handle: SceneHandle, made: []const Entity) !void {
    const gpa = app.gpa;
    var members: std.ArrayList(Entity) = .empty;
    errdefer members.deinit(gpa);
    try members.ensureTotalCapacity(gpa, made.len);
    for (made) |e| {
        if (!e.eql(root)) members.appendAssumeCapacity(e);
    }
    const template = try scene.entityTemplate(app, gpa, root);
    errdefer gpa.free(template);
    try app.instances.by_root.ensureUnusedCapacity(gpa, 1);
    const owned = try members.toOwnedSlice(gpa);
    app.instances.by_root.putAssumeCapacity(root, .{ .scene = scene_handle, .members = owned, .template = template });
}
