// SPDX-License-Identifier: BSD-3-Clause

//! What the engine can draw into `app.debug` by itself: the shapes the
//! physics sees, where bodies are heading, which way things face and what
//! they hang from, where sprites reach, what the camera shows, and how long
//! the frame took. Each is off until asked for - by a game, or by an editor's
//! View menu, which finds them all by walking this struct's fields:
//!
//! ```zig
//! app.debug_views.colliders = true;
//!
//! inline for (std.meta.fields(fx.DebugViews)) |view| {
//!     if (menu.checkbox(view.name, @field(app.debug_views, view.name))) |on| @field(app.debug_views, view.name) = on;
//! }
//! ```
//!
//! Everything is drawn where the renderer draws it: a body's shapes go with
//! its entity's transform between fixed steps, not with the step's pose, so
//! an outline stays on its sprite on a fast screen.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const physics = @import("fluxion_physics");
const physics3d = @import("fluxion_physics3d");
const debugdraw = @import("fluxion_debugdraw");

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const hierarchy = @import("../scene/hierarchy.zig");

const Vec2 = math.Vec2;
const Color = debugdraw.Color;
const Entity = ecs.Entity;
const Transform2D = components.Transform2D;

const DebugViews = @This();

/// Every collider's shape, in its body's colour: green static, blue
/// kinematic, orange moving, grey asleep, and cyan for a sensor - the 3D
/// ones' too, in the 3D world.
colliders: bool = false,
/// Each moving body's centre of mass, with an arrow as long as a tenth of a
/// second of its travel.
bodies: bool = false,
/// Each transform's axes - `x` red, `y` green - and a line to what it hangs
/// from.
transforms: bool = false,
/// Each visible sprite's outline.
sprites: bool = false,
/// What the camera shows, and the area a camera fits.
cameras: bool = false,
/// The frame's rate and length and what is in the world, in pixels at the
/// top left.
stats: bool = false,

/// For a tool that has the descriptor and not the type: every field is a view,
/// and every view is a `bool`.
pub const reflect_name = "DebugViews";

/// How long the arrows and axes are, in world units.
const reach = 16;
/// A second of travel, drawn this long.
const arrow_seconds = 0.1;

pub fn any(self: DebugViews) bool {
    inline for (std.meta.fields(DebugViews)) |field| {
        if (@field(self, field.name)) return true;
    }
    return false;
}

/// Draw the views that are on into `app.debug`, for this frame.
pub fn draw(self: DebugViews, app: *App) !void {
    if (self.colliders) {
        drawColliders(app);
        drawColliders3D(app, app.debug_3d, .{});
        drawRayCasts3D(app, app.debug_3d);
    }
    if (self.bodies) drawBodies(app);
    if (self.transforms) try drawTransforms(app);
    if (self.sprites) try drawSprites(app);
    if (self.cameras) try drawCameras(app);
    if (self.stats) drawStats(app);
}

fn drawColliders(app: *App) void {
    var shapes = app.physics.shapeIterator();
    while (shapes.next()) |entry| {
        const shape = entry.value;
        const body = app.physics.bodyConst(shape.body) orelse continue;
        const pose = poseOf(app, shape.body, body);
        const colour = colourOf(body, shape.def.sensor);
        switch (shape.def.geometry) {
            .polygon => |*polygon| {
                var corners: [physics.Polygon.max_vertices]Vec2 = undefined;
                for (polygon.vertexSlice(), 0..) |corner, i| corners[i] = pose.apply(corner);
                app.debug.polygon2d(corners[0..polygon.count], colour);
            },
            .circle => |circle| {
                const centre = pose.apply(circle.center);
                app.debug.circle2d(centre, circle.radius, colour);
                // A spoke, so a rolling ball is seen to roll.
                app.debug.line2d(centre, centre.add(pose.turn(.init(circle.radius, 0))), colour);
            },
            .capsule => |capsule| {
                // Its two ends, and its two sides between them.
                const a = pose.apply(capsule.center1);
                const b = pose.apply(capsule.center2);
                app.debug.circle2d(a, capsule.radius, colour);
                app.debug.circle2d(b, capsule.radius, colour);
                const along = b.sub(a);
                const len = along.len();
                if (len > 0) {
                    const side = Vec2.init(-along.y, along.x).scale(capsule.radius / len);
                    app.debug.line2d(a.add(side), b.add(side), colour);
                    app.debug.line2d(a.sub(side), b.sub(side), colour);
                }
            },
        }
    }
}

/// What `drawColliders3D` leaves out.
pub const Colliders3D = struct {
    /// A mesh collider's triangles: a level's are many lines, which an
    /// editor draws for the one picked.
    meshes: bool = true,
};

/// Every 3D collider's shape with `pen`, where the physics holds it: what
/// the colliders view draws, and an editor draws in its 3D view.
pub fn drawColliders3D(app: *App, pen: debugdraw.Pen, options: Colliders3D) void {
    var shapes = app.physics3d.shapes.iterator();
    while (shapes.next()) |entry| {
        if (!options.meshes and entry.value.def.geometry == .mesh) continue;
        drawShape3D(app, pen, entry.value);
    }
}

/// One 3D collider's shape with `pen` - the one on `entity`, if it has one
/// the physics holds.
pub fn drawCollider3D(app: *App, pen: debugdraw.Pen, entity: ecs.Entity) void {
    const id = app.bodies3d.shapeOfEntity(entity) orelse return;
    const shape = app.physics3d.shape(id) orelse return;
    drawShape3D(app, pen, shape);
}

/// Each `RayCast3D` that is on, as a line: yellow to where it ends, or red
/// to what it hit at the last fixed step.
pub fn drawRayCasts3D(app: *App, pen: debugdraw.Pen) void {
    var it = ecs.Query(.{ components.Transform3D, components.RayCast3D }).over(&app.world) catch return;
    while (it.next()) |chunk| {
        for (chunk.slice(components.RayCast3D), chunk.entities) |ray, e| {
            if (!ray.enabled) continue;
            const from = hierarchy.globalPosition3D(&app.world, e) orelse continue;
            if (ray.colliding) {
                pen.line(from, ray.point, .red);
                pen.point(ray.point, 6, .red);
            } else {
                const to = hierarchy.toGlobal3D(&app.world, e, ray.target) orelse continue;
                pen.line(from, to, .yellow);
            }
        }
    }
}

fn drawShape3D(app: *App, pen: debugdraw.Pen, shape: *const physics3d.World.ShapeEntry) void {
    const body = app.physics3d.bodyConst(shape.body) orelse return;
    const xf = app.physics3d.shapeTransform(shape);
    const colour: Color = if (shape.def.sensor) .cyan else switch (body.type) {
        .static => .green,
        .kinematic => .blue,
        .dynamic => if (body.awake) .orange else .gray,
    };
    switch (shape.def.geometry) {
        .sphere => |ball| pen.sphere(xf.position, ball.radius, colour),
        .box => |box| pen.orientedBox(xf.position, box.half, xf.rotation, colour),
        .capsule => |c| {
            const axis = xf.turn(.init(0, c.half_height, 0));
            pen.capsule(xf.position.sub(axis), xf.position.add(axis), c.radius, colour);
        },
        .cylinder => |c| {
            const axis = xf.turn(.init(0, c.half_height, 0));
            pen.cylinder(xf.position.sub(axis), xf.position.add(axis), c.radius, colour);
        },
        .hull => |hull| for (hull.edges) |edge| pen.line(xf.apply(hull.vertices[edge[0]]), xf.apply(hull.vertices[edge[1]]), colour),
        .mesh => |mesh| for (mesh.triangles) |t| {
            const a = xf.apply(mesh.vertices[t[0]]);
            const b = xf.apply(mesh.vertices[t[1]]);
            const c = xf.apply(mesh.vertices[t[2]]);
            pen.line(a, b, colour);
            pen.line(b, c, colour);
            pen.line(c, a, colour);
        },
    }
}

fn drawBodies(app: *App) void {
    var bodies = app.physics.bodyIterator();
    while (bodies.next()) |entry| {
        const body = entry.value;
        if (body.type == .static) continue;
        const centre = poseOf(app, entry.handle, body).apply(body.local_center);
        const colour: Color = if (body.isAwake()) .yellow else .gray;
        app.debug.cross2d(centre, reach / 2, colour);
        const travel = body.linear_velocity.scale(arrow_seconds);
        if (travel.lenSq() > 1) app.debug.arrow2d(centre, centre.add(travel), colour);
    }
}

fn drawTransforms(app: *App) !void {
    var it = try ecs.Query(.{Transform2D}).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.entities) |e| {
            const placed = app.drawnTransform(e) orelse continue;
            const at: Vec2 = .init(placed.x, placed.y);
            app.debug.axes2d(at, placed.rotation, reach);
            const above = app.parentOf(e);
            if (above.isNone()) continue;
            const parent = app.drawnTransform(above) orelse continue;
            app.debug.line2d(at, .init(parent.x, parent.y), .gray);
        }
    }
}

fn drawSprites(app: *App) !void {
    var it = try ecs.Query(.{ Transform2D, components.Sprite }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(components.Sprite)) |e, sprite| {
            if (!sprite.visible) continue;
            const corners = app.spriteCorners(e) orelse continue;
            app.debug.polygon2d(&corners, .magenta);
        }
    }
}

fn drawCameras(app: *App) !void {
    const view = app.currentView();
    app.debug.polygon2d(&.{
        view.toWorld(.init(0, 0)),
        view.toWorld(.init(view.width, 0)),
        view.toWorld(.init(view.width, view.height)),
        view.toWorld(.init(0, view.height)),
    }, .white);

    var it = try ecs.Query(.{ Transform2D, components.Camera2D }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(components.Camera2D)) |e, camera| {
            if (!camera.active or camera.fit_width <= 0 or camera.fit_height <= 0) continue;
            const placed = app.drawnTransform(e) orelse continue;
            const pose: Pose = .of(placed.x, placed.y, camera.rotation + placed.rotation);
            const w = camera.fit_width / 2;
            const h = camera.fit_height / 2;
            app.debug.polygon2d(&.{
                pose.apply(.init(-w, -h)),
                pose.apply(.init(w, -h)),
                pose.apply(.init(w, h)),
                pose.apply(.init(-w, h)),
            }, .cyan);
        }
    }
}

fn drawStats(app: *App) void {
    const pen = app.debug.screen().with(.{ .text_scale = 2 });
    const line = 22;
    pen.print2d(.init(12, 12), "{d:.0} fps  {d:.2} ms", .{ app.time.fps(), app.time.unscaled_delta * 1000 }, .white);
    pen.print2d(.init(12, 12 + line), "{d} entities  {d} bodies, {d} awake", .{
        app.world.count(),
        app.physics.bodyCount(),
        app.physics.awakeCount(),
    }, .white);
    pen.print2d(.init(12, 12 + 2 * line), "{d} sprites in {d} draws", .{ app.sprites.drawn, app.sprites.draw_calls }, .white);
}

/// Where a body is drawn: its entity's transform, between fixed steps as the
/// sprites are, for a body the engine made; the step's own pose for one a
/// game made itself.
fn poseOf(app: *App, handle: physics.BodyId, body: *const physics.Body) Pose {
    const owner: Entity = .fromInt(body.user_data);
    if (!owner.isNone()) {
        if (app.bodies.idOf(owner)) |made| {
            if (made.eql(handle)) {
                if (app.drawnTransform(owner)) |placed| return .of(placed.x, placed.y, placed.rotation);
            }
        }
    }
    return .of(body.transform.p.x, body.transform.p.y, body.angle);
}

fn colourOf(body: *const physics.Body, sensor: bool) Color {
    if (sensor) return .cyan;
    return switch (body.type) {
        .static => .green,
        .kinematic => .blue,
        .dynamic => if (body.isAwake()) .orange else .gray,
    };
}

const Pose = struct {
    x: f32,
    y: f32,
    c: f32,
    s: f32,

    fn of(x: f32, y: f32, radians: f32) Pose {
        return .{ .x = x, .y = y, .c = @cos(radians), .s = @sin(radians) };
    }

    fn turn(self: Pose, p: Vec2) Vec2 {
        return .init(p.x * self.c - p.y * self.s, p.x * self.s + p.y * self.c);
    }

    fn apply(self: Pose, p: Vec2) Vec2 {
        const turned = self.turn(p);
        return .init(self.x + turned.x, self.y + turned.y);
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn headless() !*App {
    return App.create(testing.allocator, .{ .headless = true, .frame_time = 1.0 / 60.0 });
}

fn linesDrawn(app: *App) u32 {
    return app.debug_frame.count(.world).lines;
}

test "the engine draws nothing of its own until a view is asked for" {
    const app = try headless();
    defer app.destroy();
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 100), components.Sprite.solid(.white, 400, 20), components.Collider2D{} });
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 0), components.Camera2D.fitting(320, 180) });

    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), linesDrawn(app));
    try testing.expectEqual(@as(u32, 0), app.debug_frame.count(.screen).triangles);
}

test "the collider view outlines each collider in its body's colour" {
    const app = try headless();
    defer app.destroy();
    app.debug_views.colliders = true;
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 100), components.Collider2D.rectangle(200, 10) });
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 0), components.RigidBody2D{}, components.Collider2D.circle(5) });

    _ = try app.step();
    // A box is four lines, a circle thirty-two and its spoke.
    try testing.expectEqual(@as(u32, 4 + 32 + 1), linesDrawn(app));
    const lines = app.debug_frame.lines.items;
    try testing.expect(std.meta.eql(lines[0].start_color, Color.green));
    try testing.expect(std.meta.eql(lines[lines.len - 1].start_color, Color.orange));
}

test "a collider is drawn where its sprite is between fixed steps" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frame_time = 0.5 / 60.0 });
    defer app.destroy();
    app.debug_views.colliders = true;
    const puck = try app.world.spawnWith(.{
        Transform2D.at(0, 0).interpolated(),
        components.RigidBody2D{ .gravity_scale = 0, .linear_velocity = .init(600, 0) },
        components.Collider2D.rectangle(5, 5),
    });

    // Two frames a step: the second of each pair is halfway between steps.
    for (0..3) |_| _ = try app.step();
    const drawn = app.drawnTransform(puck).?;
    const step = app.bodyOf(puck).?.position();
    try testing.expect(@abs(drawn.x - step.x) > 1);
    const left = app.debug_frame.lines.items[0].start;
    try testing.expectApproxEqAbs(drawn.x - 5, left[0], 0.01);
}

test "the body view marks moving bodies and where they are heading" {
    const app = try headless();
    defer app.destroy();
    app.debug_views.bodies = true;
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 100), components.Collider2D.rectangle(200, 10) });
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 0), components.RigidBody2D{}, components.Collider2D.circle(5) });

    for (0..10) |_| _ = try app.step();
    // A cross, and an arrow of three lines; the floor is not a moving body.
    try testing.expectEqual(@as(u32, 2 + 3), linesDrawn(app));
}

test "the transform view draws each entity's axes and a line to its parent" {
    const app = try headless();
    defer app.destroy();
    app.debug_views.transforms = true;
    const tank = try app.world.spawnWith(.{Transform2D.at(10, 10)});
    _ = try app.world.spawnWith(.{ Transform2D.at(20, 0), components.Parent.of(tank) });

    _ = try app.step();
    try testing.expectEqual(@as(u32, 2 + 2 + 1), linesDrawn(app));
}

test "the sprite and camera views outline what is visible and what is shown" {
    const app = try headless();
    defer app.destroy();
    app.debug_views.sprites = true;
    app.debug_views.cameras = true;
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 0), components.Sprite.solid(.white, 30, 10) });
    var hidden = components.Sprite.solid(.white, 30, 10);
    hidden.visible = false;
    _ = try app.world.spawnWith(.{ Transform2D.at(50, 0), hidden });
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 0), components.Camera2D.fitting(320, 180) });

    _ = try app.step();
    // One sprite, the view, and the area the camera fits.
    try testing.expectEqual(@as(u32, 4 + 4 + 4), linesDrawn(app));
}

test "the stats view writes in screen pixels" {
    const app = try headless();
    defer app.destroy();
    app.debug_views.stats = true;
    _ = try app.step();
    try testing.expect(app.debug_frame.count(.screen).triangles > 0);
    try testing.expectEqual(@as(u32, 0), linesDrawn(app));
}

test "an editor's menu finds every view by walking the struct" {
    var views: DebugViews = .{};
    try testing.expect(!views.any());
    inline for (std.meta.fields(DebugViews)) |field| @field(views, field.name) = true;
    try testing.expect(views.any());
    try testing.expect(views.colliders and views.stats);
}
