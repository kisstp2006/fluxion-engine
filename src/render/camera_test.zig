// SPDX-License-Identifier: BSD-3-Clause

//! Cameras, headless: the screen and the world through one, its limits and smoothing,
//! and the frame it shows.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const math = @import("fluxion_math");

test "with no camera, the screen and the world are the same numbers" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240 });
    defer app.destroy();

    const at = app.screenToWorld(12, 34);
    try testing.expectApproxEqAbs(@as(f32, 12), at.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 34), at.y, 0.001);

    const back = app.worldToScreen(12, 34);
    try testing.expectApproxEqAbs(@as(f32, 12), back.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 34), back.y, 0.001);
}

test "the pointer is found in the world through the camera" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240 });
    defer app.destroy();

    // Looking at (100, 50), with everything twice the size.
    _ = try app.world.spawnWith(.{
        components.Transform2D.at(100, 50),
        components.Camera2D.atZoom(2),
    });

    // The middle of the screen is where the camera is looking...
    app.input.pointer = .{ .x = 160, .y = 120 };
    const middle = app.pointerInWorld();
    try testing.expectApproxEqAbs(@as(f32, 100), middle.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 50), middle.y, 0.001);

    // ... and the top left is half a screen away at zoom two: 80 by 60 units.
    const corner = app.screenToWorld(0, 0);
    try testing.expectApproxEqAbs(@as(f32, 20), corner.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -10), corner.y, 0.001);

    // And back again, to the pixel it came from.
    const again = app.worldToScreen(corner.x, corner.y);
    try testing.expectApproxEqAbs(@as(f32, 0), again.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), again.y, 0.001);
}

test "the pointer's place on the screen is measured against the screen's size, the game area's" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240 });
    defer app.destroy();
    _ = try app.step();
    try testing.expectEqual(math.Vec2.init(320, 240), app.screenSize());
    app.input.apply(.{ .cursor = .{ .window = .none, .x = 240, .y = 60, .dx = 0, .dy = 0 } });
    _ = try app.step();
    try testing.expectEqual(math.Vec2.init(240, 60), app.pointerOnScreen());
    const across = app.pointerOnScreen().x / app.screenSize().x;
    try testing.expectEqual(@as(f32, 0.75), across);
}

test "a camera looks past its offset, stops at its limits, and catches up when smoothed" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 200, .height = 100 });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.1 };
    const camera = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.Camera2D{
        .offset = .init(10, 0),
        .limit_left = 0,
        .limit_right = 1000,
    } });
    _ = try app.step();
    // A screen two hundred wide shows a hundred either side: at the left
    // edge its middle is kept a hundred in.
    try testing.expectEqual(math.Vec2.init(100, 0), app.screenCenter(camera).?);
    try testing.expectApproxEqAbs(@as(f32, 0), app.cameraCorners(camera).?[0].x, 0.001);

    // Away from the edges, it looks past its place by its offset.
    app.world.get(camera, components.Transform2D).?.x = 500;
    _ = try app.step();
    try testing.expectEqual(math.Vec2.init(510, 0), app.screenCenter(camera).?);

    // Smoothed, it is part of the way there after a frame, and nearly there
    // after many.
    app.world.get(camera, components.Camera2D).?.smoothing = true;
    app.world.get(camera, components.Transform2D).?.x = 700;
    _ = try app.step();
    const partway = app.screenCenter(camera).?.x;
    try testing.expect(partway > 510 and partway < 710);
    for (0..40) |_| _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 710), app.screenCenter(camera).?.x, 0.1);

    // Reset, it is there at once.
    app.world.get(camera, components.Transform2D).?.x = 300;
    app.resetSmoothing(camera);
    _ = try app.step();
    try testing.expectEqual(math.Vec2.init(310, 0), app.screenCenter(camera).?);

    // A level narrower than the screen is shown in the middle.
    app.world.get(camera, components.Camera2D).?.limit_right = 50;
    try testing.expectEqual(math.Vec2.init(25, 0), app.screenCenter(camera).?);
}

test "a camera's frame is what it shows at the game's size, and an editor's screen is over what the current one shows" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 1280, .height = 720 });
    defer app.destroy();
    // With no camera, the screen's top left is the world's origin.
    try testing.expectEqual(math.Vec2.init(0, 0), app.screenInWorld().top_left);
    try testing.expectEqual(@as(f32, 1), app.screenInWorld().units_per_pixel);

    const camera = try app.world.spawnWith(.{ components.Transform2D.at(100, 50), components.Camera2D{ .zoom = 2 } });
    try testing.expect(app.currentCamera().?.eql(camera));
    const corners = app.cameraCorners(camera).?;
    try testing.expectApproxEqAbs(@as(f32, -220), corners[0].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -130), corners[0].y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 420), corners[2].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 230), corners[2].y, 0.001);
    const screen = app.screenInWorld();
    try testing.expectApproxEqAbs(@as(f32, -220), screen.top_left.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -130), screen.top_left.y, 0.001);
    try testing.expectEqual(@as(f32, 0.5), screen.units_per_pixel);

    // One that draws a picture of its own is framed at the picture's size,
    // and the screen does not look through it.
    const picture = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.Camera2D{}, components.RenderView{ .width = 320, .height = 180 } });
    try testing.expectApproxEqAbs(@as(f32, 160), app.cameraCorners(picture).?[2].x, 0.001);
    try testing.expect(app.currentCamera().?.eql(camera));
}
