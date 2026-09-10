// SPDX-License-Identifier: BSD-3-Clause

//! What the 2D camera sees, and where a point in the world lands on the
//! screen.
//!
//! ```zig
//! const view: View = .of(&world, &snapshots, 1280, 720);
//! const under_pointer = view.toWorld(.init(pointer.x, pointer.y));
//! ```
//!
//! One description of the camera, used three ways: the renderer's matrix,
//! culling, and `App.screenToWorld`. A test holds `toScreen` against the
//! matrix, so the two cannot drift apart. Screen coordinates are framebuffer
//! pixels from the top left, `y` down. With no camera the view is the window:
//! the origin at the top left, one unit to the pixel.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const components = @import("../components.zig");
const hierarchy = @import("../hierarchy.zig");

const Transform2D = components.Transform2D;
const Camera2D = components.Camera2D;
const Vec2 = math.Vec2;

const Cameras = ecs.Query(.{ Transform2D, Camera2D });

pub const View = struct {
    /// The point in the world at the middle of the screen.
    x: f32,
    y: f32,

    /// Pixels per world unit, per axis because the camera's transform may be
    /// scaled unevenly. Never zero or less; see `positive`.
    zoom_x: f32 = 1,
    zoom_y: f32 = 1,

    /// Radians, the camera's own. The world turns the other way.
    rotation: f32 = 0,

    /// What it is drawn into, in pixels.
    width: f32,
    height: f32,

    /// A world with no camera: the origin at the top left, one unit to the
    /// pixel.
    pub fn screen(width: f32, height: f32) View {
        return .{ .x = width / 2, .y = height / 2, .width = width, .height = height };
    }

    /// The view through the active camera with the highest `priority`, or
    /// `screen` when there is none.
    pub fn of(
        world: *ecs.World,
        snapshots: *const hierarchy.Snapshots,
        width: f32,
        height: f32,
    ) View {
        var best: View = .screen(width, height);
        var best_priority: ?i16 = null;

        var it = Cameras.over(world) catch return best;
        while (it.next()) |chunk| {
            const places = chunk.slice(Transform2D);
            const cameras = chunk.slice(Camera2D);
            for (places, cameras, chunk.entities) |local, camera, entity| {
                if (!camera.active) continue;
                // Ties go to the first found; see `Camera2D.priority`.
                if (best_priority) |priority| {
                    if (camera.priority <= priority) continue;
                }

                // A camera may be parented, so it is resolved like anything
                // else. One that cannot be placed is not looked through.
                const placed = hierarchy.resolve(world, snapshots, entity, local, 1) orelse continue;

                best_priority = camera.priority;
                const scale = pixelsPerUnit(camera, width, height);
                best = .{
                    .x = placed.x,
                    .y = placed.y,
                    // The camera's own scale multiplies the zoom.
                    .zoom_x = positive(scale * placed.scale_x),
                    .zoom_y = positive(scale * placed.scale_y),
                    .rotation = camera.rotation + placed.rotation,
                    .width = width,
                    .height = height,
                };
            }
        }
        return best;
    }

    /// Where a point in the world is drawn, in pixels from the top left.
    pub fn toScreen(self: View, point: Vec2) Vec2 {
        // Into the camera's frame, then out to pixels about the middle of the
        // screen: `matrix` without the trip through clip space.
        const dx = point.x - self.x;
        const dy = point.y - self.y;
        const c = @cos(self.rotation);
        const s = @sin(self.rotation);
        return .init(
            self.width / 2 + (dx * c + dy * s) * self.zoom_x,
            self.height / 2 + (dy * c - dx * s) * self.zoom_y,
        );
    }

    /// What is under a point on the screen: `toScreen` undone.
    pub fn toWorld(self: View, point: Vec2) Vec2 {
        const across = (point.x - self.width / 2) / self.zoom_x;
        const down = (point.y - self.height / 2) / self.zoom_y;
        const c = @cos(self.rotation);
        const s = @sin(self.rotation);
        return .init(
            self.x + across * c - down * s,
            self.y + across * s + down * c,
        );
    }

    /// The part of the world this view shows, as a box that does not turn. A
    /// turned camera makes it larger than what is visible, which only keeps a
    /// few extra sprites.
    pub fn bounds(self: View) Bounds {
        var half_width = self.width / (2 * self.zoom_x);
        var half_height = self.height / (2 * self.zoom_y);

        if (self.rotation != 0) {
            const c = @abs(@cos(self.rotation));
            const s = @abs(@sin(self.rotation));
            const turned_width = half_width * c + half_height * s;
            const turned_height = half_width * s + half_height * c;
            half_width = turned_width;
            half_height = turned_height;
        }

        return .{
            .left = self.x - half_width,
            .top = self.y - half_height,
            .right = self.x + half_width,
            .bottom = self.y + half_height,
        };
    }

    /// What the shader is given: the world to clip space, in one matrix.
    pub fn matrix(self: View, clip: math.Clip) math.Mat4 {
        // Zoom divides the extents: twice the size shows half as much.
        const half_width = self.width / (2 * self.zoom_x);
        const half_height = self.height / (2 * self.zoom_y);

        const projection = math.orthographic(.{
            .left = -half_width,
            .right = half_width,
            // `y` down, like the screen: the bottom edge is the positive one.
            .bottom = half_height,
            .top = -half_height,
            .near = -1,
            .far = 1,
            .clip = clip,
        });

        // The world slides and turns opposite to the camera.
        const turn: math.Mat4 = .fromAxisAngle(.init(0, 0, 1), -self.rotation);
        const slide: math.Mat4 = .fromTranslation(.init(-self.x, -self.y, 0));
        return projection.mul(turn.mul(slide));
    }
};

/// A box in the world that does not turn.
pub const Bounds = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,

    /// Whether anything within `radius` of this point could be inside.
    pub fn admits(self: Bounds, x: f32, y: f32, radius: f32) bool {
        return x + radius >= self.left and
            x - radius <= self.right and
            y + radius >= self.top and
            y - radius <= self.bottom;
    }
};

/// A zoom that can be divided by: zero or less is taken as one.
fn positive(zoom: f32) f32 {
    return if (zoom > 0) zoom else 1;
}

/// Pixels per world unit before the camera's own scale: `zoom`, times the
/// smaller of the two ratios that fit the camera's area into the target, so
/// all of the area shows. See `Camera2D.fit_width`.
fn pixelsPerUnit(camera: Camera2D, width: f32, height: f32) f32 {
    if (camera.fit_width <= 0 or camera.fit_height <= 0) return camera.zoom;
    return camera.zoom * @min(width / camera.fit_width, height / camera.fit_height);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// None, moved, zoomed unevenly, turned awkwardly, and all of it at once.
const awkward = [_]View{
    .screen(320, 240),
    .{ .x = 100, .y = -40, .width = 320, .height = 240 },
    .{ .x = 0, .y = 0, .zoom_x = 2, .zoom_y = 0.5, .width = 640, .height = 360 },
    .{ .x = 10, .y = 20, .rotation = 0.7, .width = 800, .height = 600 },
    .{ .x = -333, .y = 71, .zoom_x = 3, .zoom_y = 3, .rotation = -2.4, .width = 1920, .height = 1080 },
};

const points = [_]Vec2{
    .init(0, 0),
    .init(160, 120),
    .init(-50, 900),
    .init(1234.5, -87.25),
};

fn expectNear(expected: Vec2, actual: Vec2) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, 0.01);
    try testing.expectApproxEqAbs(expected.y, actual.y, 0.01);
}

test "with no camera, a pixel is a world unit from the top left" {
    const view: View = .screen(320, 240);
    try expectNear(.init(12, 34), view.toScreen(.init(12, 34)));
    try expectNear(.init(12, 34), view.toWorld(.init(12, 34)));

    const box = view.bounds();
    try testing.expectEqual(@as(f32, 0), box.left);
    try testing.expectEqual(@as(f32, 0), box.top);
    try testing.expectEqual(@as(f32, 320), box.right);
    try testing.expectEqual(@as(f32, 240), box.bottom);
}

test "toWorld undoes toScreen, whatever the camera is doing" {
    for (awkward) |view| {
        for (points) |point| {
            try expectNear(point, view.toWorld(view.toScreen(point)));
            try expectNear(point, view.toScreen(view.toWorld(point)));
        }
    }
}

test "toScreen lands where the shader draws" {
    // The matrix and the viewport must take each point to the pixel that
    // `toScreen` says.
    for ([_]math.Clip{ .gl, .d3d }) |clip| {
        for (awkward) |view| {
            const m = view.matrix(clip);
            for (points) |point| {
                const ndc = m.project(.init(point.x, point.y, 0)).?;
                const pixel: Vec2 = .init(
                    (ndc.x + 1) / 2 * view.width,
                    (1 - ndc.y) / 2 * view.height,
                );
                try expectNear(pixel, view.toScreen(point));
            }
        }
    }
}

test "the middle of the screen is where the camera is, and zoom shows less" {
    const view: View = .{ .x = 100, .y = 50, .zoom_x = 2, .zoom_y = 2, .width = 320, .height = 240 };
    try expectNear(.init(160, 120), view.toScreen(.init(100, 50)));

    // Half a screen, 160 by 120 pixels, is 80 by 60 units at zoom two.
    try expectNear(.init(20, -10), view.toWorld(.init(0, 0)));
}

test "a turned camera turns the world the other way" {
    // A quarter turn: what was straight below the camera is now straight to
    // the right of the middle of the screen.
    const view: View = .{ .x = 0, .y = 0, .rotation = std.math.pi / 2.0, .width = 320, .height = 240 };
    try expectNear(.init(170, 120), view.toScreen(.init(0, 10)));
}

test "every corner of the screen is inside the box" {
    for (awkward) |view| {
        const box = view.bounds();
        const corners = [_]Vec2{
            .init(0, 0),
            .init(view.width, 0),
            .init(0, view.height),
            .init(view.width, view.height),
        };
        for (corners) |corner| {
            const at = view.toWorld(corner);
            try testing.expect(box.admits(at.x, at.y, 0.01));
        }
    }
}

test "the best active camera is the one looked through" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var snapshots: hierarchy.Snapshots = .empty;
    defer snapshots.deinit(testing.allocator);

    _ = try world.spawnWith(.{ Transform2D.at(1, 1), Camera2D{ .priority = 0 } });
    _ = try world.spawnWith(.{ Transform2D.at(2, 2), Camera2D{ .priority = 5 } });
    // The highest of all, and switched off.
    _ = try world.spawnWith(.{ Transform2D.at(3, 3), Camera2D{ .priority = 9, .active = false } });

    const view: View = .of(&world, &snapshots, 320, 240);
    try testing.expectEqual(@as(f32, 2), view.x);
    try testing.expectEqual(@as(f32, 2), view.y);
}

test "a fitted camera shows the whole area in any window, and zoom multiplies it" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var snapshots: hierarchy.Snapshots = .empty;
    defer snapshots.deinit(testing.allocator);

    const camera = try world.spawnWith(.{ Transform2D.at(320, 180), Camera2D.fitting(640, 360) });

    // Exactly the design size: one unit, one pixel.
    try testing.expectApproxEqAbs(@as(f32, 1), View.of(&world, &snapshots, 640, 360).zoom_x, 0.0001);

    // Twice as wide and only as tall: the height decides, and the spare
    // width shows more world at the sides.
    const wide: View = .of(&world, &snapshots, 1280, 360);
    try testing.expectApproxEqAbs(@as(f32, 1), wide.zoom_x, 0.0001);
    const box = wide.bounds();
    try testing.expect(box.top <= 0 and box.bottom >= 360);
    try testing.expect(box.left < 0 and box.right > 640);

    // Twice the size both ways: twice the scale.
    try testing.expectApproxEqAbs(@as(f32, 2), View.of(&world, &snapshots, 1280, 720).zoom_x, 0.0001);

    // And zoom on top of the fit: 2 shows half the area.
    world.get(camera, Camera2D).?.zoom = 2;
    try testing.expectApproxEqAbs(@as(f32, 2), View.of(&world, &snapshots, 640, 360).zoom_x, 0.0001);
}

test "a zoom of nothing is taken as one rather than divided by" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var snapshots: hierarchy.Snapshots = .empty;
    defer snapshots.deinit(testing.allocator);

    _ = try world.spawnWith(.{ Transform2D.at(0, 0), Camera2D{ .zoom = 0 } });

    const view: View = .of(&world, &snapshots, 320, 240);
    try testing.expectEqual(@as(f32, 1), view.zoom_x);
    try testing.expect(std.math.isFinite(view.toWorld(.init(10, 10)).x));
}
