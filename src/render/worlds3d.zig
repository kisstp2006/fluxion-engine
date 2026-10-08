// SPDX-License-Identifier: BSD-3-Clause

//! Which 3D world an entity is in: the nearest `World3D` above it - itself
//! too - that is enabled, or the main world for none. A draw sees one world:
//! the one its camera is in. What draws the 3D layer asks a `Filter` made
//! for the draw, which finds out once whether there is any world but the
//! main one, and when there is not, asks nothing more.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");

const App = @import("../App.zig");
const World3D = @import("render3d_components.zig").World3D;
const View3D = @import("view3d.zig").View3D;

const Entity = ecs.Entity;

/// The `World3D` `entity` is in, or `.none` for the main world.
pub fn worldOf(app: *App, entity: Entity) Entity {
    var at = entity;
    var depth: usize = 0;
    while (!at.isNone() and depth < 1024) : (depth += 1) {
        if (app.world.getConst(at, World3D)) |held| if (held.enabled) return at;
        at = app.parentOf(at);
    }
    return .none;
}

/// Whether any `World3D` is enabled.
pub fn anyWorld(app: *App) bool {
    var it = ecs.Query(.{World3D}).over(&app.world) catch return false;
    while (it.next()) |chunk| {
        for (chunk.slice(World3D)) |held| if (held.enabled) return true;
    }
    return false;
}

/// What one draw sees.
pub const Filter = struct {
    /// Whether to ask at all: false where there is one world, or the draw
    /// sees them all.
    asks: bool,
    world: Entity,

    pub fn of(app: *App, view: View3D) Filter {
        if (view.every_world) return .{ .asks = false, .world = .none };
        return .{ .asks = anyWorld(app), .world = view.world };
    }

    /// Whether `entity` is in the world the draw sees.
    pub fn admits(self: Filter, app: *App, entity: Entity) bool {
        if (!self.asks) return true;
        return worldOf(app, entity).eql(self.world);
    }
};

test "an entity is in the world of the nearest enabled World3D above it, or the main one" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const Parent = @import("../scene/components.zig").Parent;
    const outside = try app.world.spawn();
    const arcade = try app.world.spawnWith(.{World3D{}});
    const cabinet = try app.world.spawnWith(.{Parent.of(arcade)});
    const ball = try app.world.spawnWith(.{Parent.of(cabinet)});
    try testing.expect(worldOf(app, outside).isNone());
    try testing.expect(worldOf(app, arcade).eql(arcade));
    try testing.expect(worldOf(app, ball).eql(arcade));
    try testing.expect(anyWorld(app));

    const seen: Filter = .of(app, .{ .world = arcade });
    try testing.expect(seen.admits(app, ball));
    try testing.expect(!seen.admits(app, outside));
    const main: Filter = .of(app, .{});
    try testing.expect(main.admits(app, outside));
    try testing.expect(!main.admits(app, ball));
    try testing.expect((Filter.of(app, .{ .every_world = true })).admits(app, ball));

    app.world.get(arcade, World3D).?.enabled = false;
    try testing.expect(worldOf(app, ball).isNone());
    try testing.expect(!anyWorld(app));
}
