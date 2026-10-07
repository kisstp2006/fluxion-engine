// SPDX-License-Identifier: BSD-3-Clause

//! Rays cast into the 3D physics: each `RayCast3D`'s, after every step and
//! when asked.

const std = @import("std");

const ecs = @import("fluxion_ecs");
const physics3d = @import("fluxion_physics3d");

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const hierarchy = @import("../scene/hierarchy.zig");

const Entity = ecs.Entity;
const RayCast3D = components.RayCast3D;

/// Every `RayCast3D` asked what it hits: after each physics step.
pub fn updateAll(app: *App) !void {
    var it = try ecs.Query(.{RayCast3D}).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(RayCast3D), chunk.entities) |*ray, entity| cast(app, entity, ray);
    }
}

/// Ask one `RayCast3D` now rather than at the next physics step.
pub fn update(app: *App, entity: Entity) void {
    const ray = app.world.get(entity, RayCast3D) orelse return;
    cast(app, entity, ray);
}

fn cast(app: *App, entity: Entity, ray: *RayCast3D) void {
    ray.colliding = false;
    ray.collider = .none;
    ray.shape = .none;
    if (!ray.enabled) return;
    const from = hierarchy.globalPosition3D(&app.world, entity) orelse return;
    const to = hierarchy.toGlobal3D(&app.world, entity, ray.target) orelse return;
    // The body it is on: its own, or the nearest one above it.
    var own: physics3d.BodyId = .none;
    if (ray.exclude_parent) {
        var at = entity;
        while (!at.isNone()) : (at = app.parentOf(at)) {
            own = app.bodies3d.idOf(at) orelse continue;
            break;
        }
    }
    const hit = app.bodies3d.castRay(app, from, to, .{ .mask = ray.collision_mask, .sensors = ray.hit_areas, .ignore = own }) orelse return;
    ray.colliding = true;
    ray.collider = hit.collider;
    ray.shape = hit.shape;
    ray.point = hit.point;
    ray.normal = hit.normal;
}
