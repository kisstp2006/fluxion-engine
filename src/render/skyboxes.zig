// SPDX-License-Identifier: BSD-3-Clause

//! A 3D skybox: the land round a level, made small - the city past its walls,
//! the hills, the far towers - drawn behind it as if it were as large as it
//! stands for. Counter-Strike's maps have one.
//!
//! A `SkyBox3D` beside a `World3D` makes what is under that world the
//! skybox. Before each frame's world, it is drawn through a camera of its
//! own: turned as the game's camera is, at `origin` - in the skybox's own
//! space - moved by where the game's camera is over `scale`. So the skybox
//! moves past a little as the player walks, as far land does, and turns
//! as they turn. Then the world is drawn over it, its depth its own: the
//! skybox is behind all of it, however near its model is.
//!
//! The skybox's world is lit by its own lights and `Environment`, and its
//! fog is its own: what is behind its land, its sky. The world's background
//! is not drawn under a skybox.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("../App.zig");
const hierarchy = @import("../scene/hierarchy.zig");
const Transform3D = @import("../scene/transform3d.zig").Transform3D;
const components3d = @import("render3d_components.zig");
const SkyBox3D = components3d.SkyBox3D;
const World3D = components3d.World3D;
const View3D = @import("view3d.zig").View3D;

/// The view the skybox is drawn through for a frame seen through `seen`;
/// null with no skybox, or one hidden or turned off.
pub fn viewFor(app: *App, seen: View3D) ?View3D {
    if (seen.every_world or !seen.world.isNone()) return null;
    var it = ecs.Query(.{ SkyBox3D, World3D }).over(&app.world) catch return null;
    while (it.next()) |chunk| {
        for (chunk.slice(SkyBox3D), chunk.slice(World3D), chunk.entities) |sky, world, entity| {
            if (!world.enabled or !(sky.scale > 0)) continue;
            if (!app.inherited.of(app.gpa, &app.world, entity).visible) continue;
            const placed = hierarchy.worldTransform3D(&app.world, entity) orelse continue;
            return through(sky, placed, seen, entity);
        }
    }
    return null;
}

/// `seen` from inside a skybox placed at `placed`.
pub fn through(sky: SkyBox3D, placed: Transform3D, seen: View3D, entity: ecs.Entity) View3D {
    var out = seen;
    out.position = placed.apply(sky.origin.add(seen.position.scale(1 / sky.scale)));
    out.rotation = placed.rotation.quat().mul(seen.rotation).norm();
    out.near = @max(sky.near, 0.0001);
    out.far = @max(sky.far, out.near * 2);
    out.world = entity;
    return out;
}

test "the skybox's camera stands at its origin, moved by the game's camera over its scale, and turns as it does" {
    var seen: View3D = .{ .position = .init(32, 16, -160), .near = 0.03, .far = 400 };
    seen.rotation = .fromAxisAngle(.unit_y, 0.5);
    const sky: SkyBox3D = .{ .scale = 16, .origin = .init(-1, 2, 3), .near = 0.5, .far = 900 };
    const placed: Transform3D = .at(0, -500, 0);
    const out = through(sky, placed, seen, .none);
    try testing.expectApproxEqAbs(@as(f32, -1 + 2), out.position.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -500 + 2 + 1), out.position.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3 - 10), out.position.z, 1e-4);
    try testing.expectApproxEqAbs(seen.rotation.w, out.rotation.w, 1e-5);
    try testing.expectEqual(@as(f32, 900), out.far);
}

test "only a frame through the main world's camera has the skybox behind it" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const sky = try app.world.spawnWith(.{ Transform3D{}, World3D{}, SkyBox3D{} });
    try testing.expect(viewFor(app, .{}) != null);
    try testing.expect(viewFor(app, .{}).?.world.eql(sky));
    try testing.expect(viewFor(app, .{ .every_world = true }) == null);
    app.world.get(sky, World3D).?.enabled = false;
    try testing.expect(viewFor(app, .{}) == null);
}
