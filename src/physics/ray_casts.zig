// SPDX-License-Identifier: BSD-3-Clause

//! Rays cast into the physics: each `RayCast2D`'s, after every step and
//! when asked, and the ones that find whether an entity stands on a floor.

const std = @import("std");

const ecs = @import("fluxion_ecs");
const physics = @import("fluxion_physics");

const App = @import("../App.zig");
const components = @import("../scene/components.zig");

const Entity = ecs.Entity;
const RayCast2D = components.RayCast2D;
const CharacterBody2D = components.CharacterBody2D;
const Collider2D = components.Collider2D;

/// Every `RayCast2D` asked what it hits: after each physics step.
pub fn updateAll(app: *App) !void {
    var it = try ecs.Query(.{RayCast2D}).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(RayCast2D), chunk.entities) |*ray, entity| cast(app, entity, ray);
    }
}

/// Ask one `RayCast2D` now rather than at the next physics step.
pub fn update(app: *App, entity: Entity) void {
    const ray = app.world.get(entity, RayCast2D) orelse return;
    cast(app, entity, ray);
}

fn cast(app: *App, entity: Entity, ray: *RayCast2D) void {
    ray.colliding = false;
    ray.collider = .none;
    ray.shape = .none;
    if (!ray.enabled) return;
    const from = app.globalPosition(entity) orelse return;
    const to = app.toGlobal(entity, ray.target) orelse return;
    // The body it is on: its own, or the nearest one above it.
    var own: ?physics.BodyId = null;
    if (ray.exclude_parent) {
        var at = entity;
        while (!at.isNone()) : (at = app.parentOf(at)) {
            own = app.bodies.idOf(at) orelse continue;
            break;
        }
    }
    const hit = app.bodies.castRay(app, from, to, .{
        .filter = .{ .category = 0xFFFF_FFFF, .mask = ray.collision_mask },
        .sensors = ray.hit_areas,
        .ignore = own,
    }) orelse return;
    ray.colliding = true;
    ray.collider = hit.collider;
    ray.shape = hit.shape;
    ray.point = hit.point;
    ray.normal = hit.normal;
}

/// Whether an entity stands on a floor: something facing up under the bottom
/// of its collider, no further below it than `distance`. A floor under the
/// middle of the bottom, or under either end of it, counts, so a body half
/// over an edge still stands; the bottom is the collider's as the physics
/// holds it, so a turned body stands on whatever corner is lowest.
///
/// The rays start a little inside the body: one resting on a floor has sunk
/// the physics' slop into it, and a ray that starts inside the floor finds
/// nothing of it.
pub fn isOnFloor(app: *App, entity: Entity, distance: f32) bool {
    // A character knows: its last move said.
    if (app.world.get(entity, CharacterBody2D)) |held| return held.on_floor;
    const collider = app.world.get(entity, Collider2D) orelse return false;
    const box = app.bodies.boundsOf(app, entity) orelse return false;
    const settings = app.physics.settings;
    const sunk = 4 * settings.linear_slop * settings.units_per_metre;
    const inside = @min(sunk, (box.max.y - box.min.y) / 2);
    const own = app.bodies.idOf(entity);
    const filter: physics.Filter = .{ .category = collider.collision_layer, .mask = collider.collision_mask };
    for ([_]f32{ 0.5, 0.1, 0.9 }) |along| {
        const x = box.min.x + (box.max.x - box.min.x) * along;
        const hit = app.bodies.castRay(app, .init(x, box.max.y - inside), .init(x, box.max.y + @max(distance, 0)), .{ .filter = filter }) orelse continue;
        // Another collider of the same body is not a floor.
        if (hit.shape.eql(entity) or std.meta.eql(app.bodies.idOf(hit.shape), own)) continue;
        if (hit.normal.y < -0.5) return true;
    }
    return false;
}
