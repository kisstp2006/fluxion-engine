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

const Assets = @import("assets.zig");
const ViewTexture = @import("components.zig").ViewTexture;

const Entity = ecs.Entity;

pub const Views = struct {
    textures: std.AutoHashMapUnmanaged(Entity, Assets.TextureHandle) = .empty,

    pub fn deinit(self: *Views, gpa: Allocator, assets: *Assets) void {
        self.clear(assets);
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
    pub fn forgetDead(self: *Views, gpa: Allocator, world: *const ecs.World, assets: *Assets, comptime RenderView: type) void {
        var dead: std.ArrayList(Entity) = .empty;
        defer dead.deinit(gpa);
        var it = self.textures.keyIterator();
        while (it.next()) |view| {
            if (!world.isAlive(view.*) or !world.has(view.*, RenderView)) dead.append(gpa, view.*) catch break;
        }
        for (dead.items) |view| {
            const gone = self.textures.fetchRemove(view) orelse continue;
            assets.unload(gone.value);
        }
    }

    pub fn clear(self: *Views, assets: *Assets) void {
        var it = self.textures.valueIterator();
        while (it.next()) |texture| assets.unload(texture.*);
        self.textures.clearRetainingCapacity();
    }
};
