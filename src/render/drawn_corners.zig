// SPDX-License-Identifier: BSD-3-Clause

//! Where things are drawn, as four corners in the world - turned, scaled and
//! carried by their parents as the renderer does it: what a click is tested
//! against, and what an editor outlines and frames.

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const sprite = @import("sprite.zig");

const Entity = ecs.Entity;
const Vec2 = math.Vec2;

/// Where an entity's sprite is drawn, as its four corners in the world, round
/// from the texture's top left - turned, scaled and carried by its parents
/// as the renderer does it. Null for an entity with no sprite, or none that
/// can be placed. What a click on a sprite is tested against.
pub fn ofSprite(app: *App, entity: Entity) ?[4]Vec2 {
    const drawn = (app.world.get(entity, components.Sprite) orelse return null).*;
    const placed = app.drawnTransform(entity) orelse return null;
    const shown = app.views.shown(&app.world, entity, drawn.texture);
    const texture = app.assets.get(shown) orelse app.assets.get(app.assets.white) orelse return null;
    return sprite.cornersOf(drawn, placed, texture);
}

/// Where an entity's label is drawn, as its four corners in the world, round
/// from the top left of its first line - turned, scaled and carried by its
/// parents as the renderer does it. The box its lines are laid out in, not
/// the ink. Null for an entity with no `Text2D`, one with nothing to draw,
/// or one that cannot be placed.
pub fn ofText(app: *App, entity: Entity) ?[4]Vec2 {
    const label = (app.world.get(entity, components.Text2D) orelse return null).*;
    const placed = app.drawnTransform(entity) orelse return null;
    return sprite.labelCornersOf(app.gpa, &app.assets, label, app.textOf(entity, components.Text2D, "text"), placed);
}

/// Where a map's painted tiles are drawn, as the four corners of the box
/// they fill, in the world, clockwise from its top left. Null for an entity
/// with no `TileMap`, one with nothing painted, or one that cannot be
/// placed.
pub fn ofTileMap(app: *App, entity: Entity) ?[4]Vec2 {
    const bounds = app.tileMapBounds(entity) orelse return null;
    const placed = app.drawnTransform(entity) orelse return null;
    const top_left = placed.apply(bounds[0], bounds[1]);
    const top_right = placed.apply(bounds[2], bounds[1]);
    const bottom_right = placed.apply(bounds[2], bounds[3]);
    const bottom_left = placed.apply(bounds[0], bounds[3]);
    return .{
        .init(top_left.x, top_left.y),
        .init(top_right.x, top_right.y),
        .init(bottom_right.x, bottom_right.y),
        .init(bottom_left.x, bottom_left.y),
    };
}

/// Whichever an entity is drawn as: its sprite's corners, else its label's,
/// else its map's. What an editor outlines, frames and tests a click
/// against without asking which it is.
pub fn of(app: *App, entity: Entity) ?[4]Vec2 {
    return ofSprite(app, entity) orelse ofText(app, entity) orelse ofTileMap(app, entity);
}
