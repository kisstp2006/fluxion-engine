// SPDX-License-Identifier: BSD-3-Clause

//! What the 2D camera sees, and where a point in the world lands on the
//! screen.
//!
//! ```zig
//! const view: View = .of(&world, &snapshots, 1280, 720);
//! const under_pointer = view.toWorld(.init(pointer.x, pointer.y));
//! ```
//!
//! **One description of the camera, used three ways.** The renderer builds
//! the matrix the shader is given from it, throws away whatever falls outside
//! the box it covers, and `App.screenToWorld` runs it backwards to find what
//! is under the pointer. The first two used to be separate pieces of
//! arithmetic over the same two components, each finding the camera for
//! itself, twice a frame; a third copy for the mouse would have been the one
//! to drift, and a pointer a few pixels out at the edge of a zoomed, turned
//! view is a bug nobody finds by looking. A test here holds `toScreen`
//! against the matrix, so the two cannot disagree without it failing.
//!
//! **Screen coordinates are framebuffer pixels**, from the top left with `y`
//! down: the units of `App.width`, of `Input.pointer`, and of a world with no
//! camera in it. The pointer arrives in those units on every backend
//! `fluxion-platform` has today. A backend that one day reports it in
//! logical units on a HiDPI display will have to scale it there, not here -
//! this file cannot tell the two apart.
//!
//! **With no camera, the view is the window**: the origin at the top left
//! corner and one world unit to the pixel, which is the interface's
//! coordinate system too. That is written as a view like any other - centred
//! on the middle of the window, at zoom one - rather than as a special case
//! in each of the three uses.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const components = @import("../components.zig");
const hierarchy = @import("../hierarchy.zig");

const Transform2D = components.Transform2D;
const Camera2D = components.Camera2D;
const Vec2 = math.Vec2;

/// Everything that can be looked through.
const Cameras = ecs.Query(.{ Transform2D, Camera2D });

pub const View = struct {
    /// The point in the world at the middle of the screen.
    x: f32,
    y: f32,

    /// Pixels per world unit. Two draws everything at twice the size, and so
    /// shows half as much. Never zero or less: see `positive`.
    ///
    /// One per axis, because the camera's transform may be scaled unevenly,
    /// and a single number could only honour one of the two.
    zoom_x: f32 = 1,
    zoom_y: f32 = 1,

    /// Radians, the camera's own. The world turns the other way, which is
    /// what a camera turning means.
    rotation: f32 = 0,

    /// What it is drawn into, in pixels.
    width: f32,
    height: f32,

    /// A world with no camera in it: the origin at the top left, one unit to
    /// the pixel.
    pub fn screen(width: f32, height: f32) View {
        return .{ .x = width / 2, .y = height / 2, .width = width, .height = height };
    }

    /// The view through the best camera in the world - the active one with
    /// the highest `priority` - or `screen` when there is none.
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
                // Ties go to whichever was found first, which is not an order
                // to depend on - see `Camera2D.priority`.
                if (best_priority) |priority| {
                    if (camera.priority <= priority) continue;
                }

                // A camera may be parented too - to the player it follows, or
                // to a rig that shakes - so where it looks from is resolved
                // the way everything else is, at the latest step. One that
                // cannot be placed is not looked through.
                const placed = hierarchy.resolve(world, snapshots, entity, local, 1) orelse continue;

                best_priority = camera.priority;
                best = .{
                    .x = placed.x,
                    .y = placed.y,
                    // The camera's own transform may be scaled - a camera
                    // parented to something that grows - and that multiplies
                    // the zoom rather than fighting it, on each axis.
                    .zoom_x = positive(camera.zoom * placed.scale_x),
                    .zoom_y = positive(camera.zoom * placed.scale_y),
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
        // Into the camera's frame - slid so the camera is at the origin, and
        // turned the other way to it - then out to pixels about the middle of
        // the screen, zoomed. The same three steps as `matrix`, without the
        // trip through clip space and back.
        const dx = point.x - self.x;
        const dy = point.y - self.y;
        const c = @cos(self.rotation);
        const s = @sin(self.rotation);
        return .init(
            self.width / 2 + (dx * c + dy * s) * self.zoom_x,
            self.height / 2 + (dy * c - dx * s) * self.zoom_y,
        );
    }

    /// What is under a point on the screen. `toScreen`, undone one step at a
    /// time in the opposite order.
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

    /// The part of the world this view can show, as a box that does not
    /// turn.
    ///
    /// A turned camera makes it larger than what is really visible - the box
    /// round a turned rectangle - which is the right way to be wrong for what
    /// it is used for: a sprite wrongly kept is a few bytes in a buffer, and a
    /// sprite wrongly dropped is a hole in the picture.
    pub fn bounds(self: View) Bounds {
        var half_width = self.width / (2 * self.zoom_x);
        var half_height = self.height / (2 * self.zoom_y);

        if (self.rotation != 0) {
            // The box round the turned box: each half-extent picks up a share
            // of the other, by how far the rotation leans it over.
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
        // A zoom of two means everything twice the size, which means the
        // camera sees half as much - so the extents are divided by it and not
        // multiplied. Getting this the wrong way round is the traditional
        // mistake, and it looks right until somebody zooms.
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

        // The world moves opposite to the camera, in both senses: it slides
        // by minus the camera's position and turns by minus its rotation.
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
    ///
    /// The radius is the caller's, and it should be generous: see the
    /// renderer's `spriteRadius`.
    pub fn admits(self: Bounds, x: f32, y: f32, radius: f32) bool {
        return x + radius >= self.left and
            x - radius <= self.right and
            y + radius >= self.top and
            y - radius <= self.bottom;
    }
};

/// A zoom that can be divided by and still draws the right way round. Zero
/// would divide the view by nothing, and less than zero would turn it inside
/// out; both are taken as one, which is at least a picture.
fn positive(zoom: f32) f32 {
    return if (zoom > 0) zoom else 1;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// Views worth being right about: none, moved, zoomed unevenly, turned by an
/// awkward amount, and all of it at once.
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
    // The whole point of this file: the pointer and the picture go through
    // the same camera. For each view and each point, the matrix the renderer
    // uploads takes the point to clip space, the viewport takes that to a
    // pixel - and that pixel has to be the one `toScreen` said.
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

    // Half a screen is 160 pixels across and 120 down, which at twice the
    // size is 80 units and 60.
    try expectNear(.init(20, -10), view.toWorld(.init(0, 0)));
}

test "a turned camera turns the world the other way" {
    // A quarter turn: positive rotation takes +x towards +y, clockwise on a
    // screen whose y points down. What was straight below the camera in the
    // world is now straight to the right of the middle of the screen.
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
