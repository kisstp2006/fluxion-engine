// SPDX-License-Identifier: BSD-3-Clause

//! The picture each `RenderView` draws: a texture made for it the first
//! time it draws, the size it says, and let go of with it.
//!
//! ```zig
//! const arcade = try app.world.spawnWith(.{
//!     fx.Transform2D.at(5000, 0),
//!     fx.Camera2D{ .cull_mask = 0b10 },
//!     fx.RenderView{ .width = 256, .height = 224 },
//! });
//! _ = try app.world.spawnWith(.{ fx.Control{}, fx.TextureRect{}, fx.ViewTexture{ .view = arcade }, fx.Parent.of(cabinet) });
//! ```
//!
//! Each view is drawn every frame it is `active`, before the screen, through
//! its own camera: what its `cull_mask` sees, which a branch put on a render
//! layer of its own with `Appearance.render_layers` can keep off the screen.
//! A `ViewTexture` on a `Sprite` or a `TextureRect` shows it, as does its
//! handle - `App.viewTexture` - put anywhere a texture goes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");

const rhi = @import("fluxion_rhi");

const App = @import("../App.zig");
const Assets = @import("../assets/assets.zig");
const components = @import("../scene/components.zig");
const hierarchy = @import("../scene/hierarchy.zig");
const View = @import("view.zig").View;
const View3D = @import("view3d.zig").View3D;
const Camera3D = @import("render3d_components.zig").Camera3D;
const Transform3D = @import("../scene/transform3d.zig").Transform3D;

const Entity = ecs.Entity;
const Transform2D = components.Transform2D;
const Camera2D = components.Camera2D;
const RenderView = components.RenderView;
const ViewTexture = components.ViewTexture;

pub const Views = struct {
    textures: std.AutoHashMapUnmanaged(Entity, Assets.TextureHandle) = .empty,

    /// The pictures themselves go with the assets that hold them.
    pub fn deinit(self: *Views, gpa: Allocator) void {
        self.textures.deinit(gpa);
    }

    /// The picture `view` draws, once it has drawn one.
    pub fn textureOf(self: *const Views, view: Entity) ?Assets.TextureHandle {
        return self.textures.get(view);
    }

    /// The texture `entity` shows: the picture of the view its
    /// `ViewTexture` names, once that has one, or else its own.
    pub fn shown(self: *const Views, world: *ecs.World, entity: Entity, own: Assets.TextureHandle) Assets.TextureHandle {
        const held = world.get(entity, ViewTexture) orelse return own;
        return self.textureOf(held.view) orelse own;
    }

    /// Let go of the pictures of views that are gone, or are views no more.
    pub fn forgetDead(self: *Views, app: *App) void {
        var dead: std.ArrayList(Entity) = .empty;
        defer dead.deinit(app.gpa);
        var it = self.textures.keyIterator();
        while (it.next()) |view| {
            if (!app.world.isAlive(view.*) or !app.world.has(view.*, RenderView)) dead.append(app.gpa, view.*) catch break;
        }
        for (dead.items) |view| {
            const gone = self.textures.fetchRemove(view) orelse continue;
            app.assets.unload(gone.value);
        }
    }

    pub fn clear(self: *Views, app: *App) void {
        var it = self.textures.valueIterator();
        while (it.next()) |texture| app.assets.unload(texture.*);
        self.textures.clearRetainingCapacity();
    }
};

/// Draw what each active `RenderView` sees into its picture: before the
/// screen, so what shows one shows this frame's. See `view_textures.zig`.
/// One beside a `Camera3D` sees the 3D world through it.
pub fn drawAll(app: *App) !void {
    var it3d = try ecs.Query(.{ Transform3D, Camera3D, RenderView }).over(&app.world);
    while (it3d.next()) |chunk| {
        const places = chunk.slice(Transform3D);
        const cameras = chunk.slice(Camera3D);
        const views = chunk.slice(RenderView);
        for (places, cameras, views, chunk.entities) |local, camera, view, entity| {
            if (!view.active) continue;
            const placed = hierarchy.resolve3D(&app.world, &app.snapshots3d, entity, local, app.time.alpha()) orelse continue;
            const picture = try pictureOf(app, entity, view);
            const gpu = (app.assets.get(picture) orelse continue).gpu;
            const width = @max(view.width, 1);
            const height = @max(view.height, 1);
            var through: View3D = .of(camera, placed, @floatFromInt(width), @floatFromInt(height));
            through.render_view = entity;
            try app.renderer3d.draw(app, .{ .texture = gpu }, width, height, through, view.clear_color, .{});
        }
    }

    var it = try ecs.Query(.{ Transform2D, Camera2D, RenderView }).over(&app.world);
    while (it.next()) |chunk| {
        const places = chunk.slice(Transform2D);
        const cameras = chunk.slice(Camera2D);
        const views = chunk.slice(RenderView);
        for (places, cameras, views, chunk.entities) |local, camera, view, entity| {
            if (!view.active) continue;
            const placed = hierarchy.resolve(&app.world, &app.snapshots, entity, local, app.time.alpha()) orelse continue;
            const picture = try pictureOf(app, entity, view);
            const gpu = (app.assets.get(picture) orelse continue).gpu;
            var through: View = .through(camera, placed, @floatFromInt(@max(view.width, 1)), @floatFromInt(@max(view.height, 1)));
            through.render_view = entity;
            try app.sprites.draw(app.gpa, &app.world, &app.assets, &app.tile_sets, &app.snapshots, &app.inherited, .{ .texture = gpu }, through, view.clear_color, app.time.alpha());
        }
    }
}

/// A render view's picture, at the size it says now.
pub fn pictureOf(app: *App, entity: Entity, view: RenderView) !Assets.TextureHandle {
    const filter: rhi.Filter = if (view.filter == .linear) .linear else .nearest;
    if (app.views.textureOf(entity)) |held| {
        try app.assets.resizeRenderTexture(held, view.width, view.height, filter, view.clear_color.array());
        return held;
    }
    const made = try app.assets.addRenderTexture(view.width, view.height, filter, view.clear_color.array(), app.drawnUpsideDown(), "render view");
    errdefer app.assets.unload(made);
    try app.views.textures.put(app.gpa, entity, made);
    return made;
}

/// The picture a `RenderView` draws, as a texture: to put on a sprite, a
/// texture rect, or anything else a texture goes, from code. Made now if it
/// has not drawn one yet; `error.NotAView` for an entity with no view.
pub fn textureOfView(app: *App, view: Entity) !Assets.TextureHandle {
    const held = app.world.get(view, RenderView) orelse return error.NotAView;
    return pictureOf(app, view, held.*);
}
