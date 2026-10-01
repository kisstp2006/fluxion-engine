// SPDX-License-Identifier: BSD-3-Clause

//! The scene the game is playing: what `App.openScene` opened, its roots,
//! and the one `App.changeScene` asked for, opened at the end of the frame.
//!
//! What does not belong to the scene - an autoload, what the game spawned at
//! the top of the tree itself - stays when it changes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");

const App = @import("../App.zig");
const scene = @import("scene.zig");
const hierarchy = @import("hierarchy.zig");
const SceneHandle = @import("../assets/scene_table.zig").SceneHandle;

const Entity = ecs.Entity;
const log = std.log.scoped(.fluxion_engine);

pub const CurrentScene = struct {
    /// The scene opened last; `.none` before one has.
    handle: SceneHandle = .none,
    /// Its roots: what the next scene takes away.
    roots: std.ArrayListUnmanaged(Entity) = .empty,
    /// The scene asked for, to open at the end of the frame.
    next: ?SceneHandle = null,

    pub fn deinit(self: *CurrentScene, gpa: Allocator) void {
        self.roots.deinit(gpa);
    }

    /// No scene playing, as a world thrown away leaves none.
    pub fn clear(self: *CurrentScene, _: *App) void {
        self.roots.clearRetainingCapacity();
        self.handle = .none;
    }

    /// The first living entity at the top of the scene - the one root of a
    /// scene that has one - or `.none` before a scene is open.
    pub fn root(self: *const CurrentScene, world: *const ecs.World) Entity {
        for (self.roots.items) |held| if (world.isAlive(held)) return held;
        return .none;
    }
};

/// Play `scene_handle` now: the roots of the one playing go, with
/// everything that hangs from them, and it is read in their place.
pub fn open(app: *App, scene_handle: SceneHandle) !void {
    const held = app.scenes.get(scene_handle) orelse return error.NoSuchScene;
    const playing = &app.current_scene;
    // Gone first, so the next is read with its own UUIDs even when it is
    // the same scene again.
    for (playing.roots.items) |root| try app.despawnTree(root);
    playing.roots.clearRetainingCapacity();
    playing.handle = .none;
    var made: std.ArrayList(Entity) = .empty;
    defer made.deinit(app.gpa);
    _ = try scene.read(app, held.bytes, .{ .spawned = &made });
    for (made.items) |e| {
        if (hierarchy.parentOf(&app.world, e).isNone() and !app.scene_components.keepsOut(&app.world, e)) try playing.roots.append(app.gpa, e);
    }
    playing.handle = scene_handle;
}

/// The scene `App.changeScene` asked for, opened: at the end of the frame,
/// before the engine's own passes, so what hung from the old one goes with
/// it this frame. One that does not open is said, and the old one is gone.
pub fn openAsked(app: *App) !void {
    const next = app.current_scene.next orelse return;
    app.current_scene.next = null;
    open(app, next) catch |err| log.err("the scene {s} did not open: {t}", .{ app.sceneSource(next) orelse "?", err });
}
