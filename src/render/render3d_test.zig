// SPDX-License-Identifier: BSD-3-Clause

//! The 3D layer through a whole app, headless: what a camera sees drawn,
//! what it does not left out, meshes of one kind drawn together, a render
//! view's own camera, meshes made in code and by their numbers, and the
//! components through a scene.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const Appearance = @import("../scene/inherited.zig").Appearance;
const mesh = @import("mesh.zig");
const scene = @import("../scene/scene.zig");

const Transform3D = components.Transform3D;
const MeshInstance3D = components.MeshInstance3D;
const PrimitiveMesh3D = components.PrimitiveMesh3D;
const Material3D = components.Material3D;
const Camera3D = components.Camera3D;
const DirectionalLight3D = components.DirectionalLight3D;
const RenderView = components.RenderView;

fn headless() !*App {
    return App.create(testing.allocator, .{ .headless = true, .width = 64, .height = 64, .io = testing.io });
}

/// A camera at `z` five, looking at the origin.
fn looking(app: *App) !@import("fluxion_ecs").Entity {
    var eye: Transform3D = .at(0, 0, 5);
    eye.lookAt(.zero, .unit_y);
    return app.world.spawnWith(.{ eye, Camera3D{} });
}

fn boxAt(app: *App, x: f32, y: f32, z: f32) !@import("fluxion_ecs").Entity {
    return app.world.spawnWith(.{ Transform3D.at(x, y, z), MeshInstance3D{}, PrimitiveMesh3D{} });
}

test "the boxes a camera sees are drawn together, and one behind it is left out" {
    const app = try headless();
    defer app.destroy();
    // Nothing 3D, no camera: the 3D layer draws nothing.
    _ = try boxAt(app, 0, 0, 0);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.renderer3d.drawn);

    const camera = try looking(app);
    _ = try boxAt(app, 1, 0, 0);
    _ = try boxAt(app, -1, 0, 0);
    _ = try boxAt(app, 0, 0, 20);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 3), app.renderer3d.drawn);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.culled);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.draw_calls);

    // Another shape, both sides drawn, and see-through: a draw each.
    const ball = try app.world.spawnWith(.{ Transform3D.at(0, 1, 0), MeshInstance3D{}, PrimitiveMesh3D{ .shape = .sphere } });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, -1, 0), MeshInstance3D{}, PrimitiveMesh3D{}, Material3D{ .cull = .disabled } });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0, 1), MeshInstance3D{}, PrimitiveMesh3D{}, Material3D{ .transparency = .alpha, .albedo_color = .{ .r = 1, .g = 1, .b = 1, .a = 0.5 } } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 6), app.renderer3d.drawn);
    try testing.expectEqual(@as(u32, 4), app.renderer3d.draw_calls);

    // Hidden, or on a layer the camera does not see: not drawn.
    try app.world.add(ball, Appearance{ .visible = false });
    app.world.get(camera, Camera3D).?.cull_mask = 0b1;
    app.world.get(try boxAt(app, 0, 0, 0), MeshInstance3D).?.layers = 0b10;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 5), app.renderer3d.drawn);
}

test "a mesh made in code is drawn by its handle, and nothing once it is let go" {
    const app = try headless();
    defer app.destroy();
    _ = try looking(app);
    const made = try app.addMesh("crate", try mesh.box(testing.allocator, .init(1, 1, 1)));
    try testing.expectEqual(made, app.findMesh("crate").?);
    try testing.expectEqual(@as(usize, 12), app.meshOf(made).?.triangleCount());
    _ = try app.world.spawnWith(.{ Transform3D{}, MeshInstance3D{ .mesh = made } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.renderer3d.drawn);

    app.unloadMesh(made);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.renderer3d.drawn);
}

test "a render view beside a 3D camera draws the 3D world into its picture" {
    const app = try headless();
    defer app.destroy();
    var eye: Transform3D = .at(0, 0, 5);
    eye.lookAt(.zero, .unit_y);
    const monitor = try app.world.spawnWith(.{ eye, Camera3D{}, RenderView{ .width = 32, .height = 24 } });
    _ = try boxAt(app, 0, 0, 0);
    _ = try app.step();
    // The screen has no camera of its own: the view's is not the screen's.
    try testing.expect(app.currentCamera3D() == null);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.drawn);
    try testing.expect(app.views.textureOf(monitor) != null);
}

test "a camera's ray and a point on the screen go through the game's pixels" {
    const app = try headless();
    defer app.destroy();
    const camera = try looking(app);
    _ = try app.step();
    try testing.expect(app.currentCamera3D().?.eql(camera));
    const middle: @import("fluxion_math").Vec2 = .init(32, 32);
    try testing.expect(app.projectRayNormal(camera, middle).?.approxEql(.init(0, 0, -1)));
    const seen = app.unprojectPosition(camera, .zero).?;
    try testing.expectApproxEqAbs(@as(f32, 32), seen.x, 1e-3);
    try testing.expect(app.isPositionBehind(camera, .init(0, 0, 9)));
    try testing.expect(app.projectPosition(camera, middle, 5).?.approxEql(.zero));
}

test "the 3D components keep what they hold through a scene round trip" {
    const source = try headless();
    defer source.destroy();
    var eye: Transform3D = .at(0, 2, 5);
    eye.lookAt(.zero, .unit_y);
    const camera = try source.world.spawnWith(.{ eye, Camera3D{ .fov = 1, .projection = .orthogonal, .current = true, .cull_mask = 0b101 } });
    try source.setName(camera, "eye");
    const pill = try source.world.spawnWith(.{
        Transform3D.at(1, 0, 0),
        MeshInstance3D{ .layers = 0b100, .cast_shadow = false },
        PrimitiveMesh3D{ .shape = .capsule, .radius = 0.25, .height = 1.5, .segments = 12 },
        Material3D{ .albedo_color = .hex(0x336699), .cull = .front, .transparency = .alpha, .unshaded = true, .uv_scale = .init(2, 3) },
    });
    try source.setName(pill, "pill");
    const sun = try source.world.spawnWith(.{ Transform3D{}, DirectionalLight3D{ .energy = 2 } });
    try source.setName(sun, "sun");

    const text = try scene.write(source, testing.allocator, .{});
    defer testing.allocator.free(text);
    const copy = try headless();
    defer copy.destroy();
    _ = try scene.read(copy, text, .{});

    const seen = copy.world.get(copy.find("eye").?, Camera3D).?;
    try testing.expectEqual(source.world.get(camera, Camera3D).?.*, seen.*);
    const back = copy.find("pill").?;
    try testing.expectEqual(source.world.get(pill, MeshInstance3D).?.*, copy.world.get(back, MeshInstance3D).?.*);
    try testing.expectEqual(source.world.get(pill, PrimitiveMesh3D).?.*, copy.world.get(back, PrimitiveMesh3D).?.*);
    try testing.expectEqual(source.world.get(pill, Material3D).?.*, copy.world.get(back, Material3D).?.*);
    try testing.expectEqual(@as(f32, 2), copy.world.get(copy.find("sun").?, DirectionalLight3D).?.energy);
}
