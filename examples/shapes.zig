// SPDX-License-Identifier: BSD-3-Clause

//! The 3D layer: a floor and the five shapes made from numbers, turning,
//! lit by the sun, seen through a camera that goes round them - with a
//! see-through pane in front, and words in 2D over it all.
//!
//! ```bash
//! zig build example-shapes
//! zig build example-shapes -- --frames 120 --capture shapes.png
//! zig build example-shapes -- --backend vulkan
//! ```
//!
//! Left click says which shape is under the pointer. Escape leaves, F11
//! fills the screen.
//!
//! **A shape is three components.** `MeshInstance3D` draws a mesh where the
//! entity's `Transform3D` is, the `PrimitiveMesh3D` beside it says which
//! mesh - a box, a sphere, a plane, a cylinder or a capsule of its numbers,
//! made once and shared by every shape with the same - and `Material3D`
//! says its colour, whether it is lit, and which sides are drawn.
//!
//! **The camera is a `Camera3D`** on an entity like any other: turning it is
//! writing its transform. What a click is on is the ray from the camera
//! through the pointer - `app.projectRayOrigin` and `projectRayNormal` - met
//! against each shape's box.
//!
//! **The 2D world and the interface go over the 3D one.** The words are a
//! `Text2D`, drawn through no camera at all, after the 3D layer.

const std = @import("std");
const fx = @import("fluxion_engine");

const App = fx.App;
const Transform3D = fx.Transform3D;
const Color = fx.Color;
const Vec3 = fx.math.Vec3;

const theme = struct {
    const background: Color = .hex(0x1B2330);
    const floor: Color = .hex(0x56606E);
    const text: Color = .hex(0xE6EDF5);
};

/// A shape that turns about its own `y`.
const Spin = extern struct { speed: f32 = 1 };

/// The words saying what was clicked: how many clicks they have answered.
const Caption = extern struct { clicks: u32 = 0 };

fn spawn(app: *App) !void {
    _ = try app.world.spawnWith(.{
        Transform3D{ .position = .init(0, -0.5, 0) },
        fx.MeshInstance3D{},
        fx.PrimitiveMesh3D{ .shape = .plane, .size = .init(12, 1, 12) },
        fx.Material3D{ .albedo_color = theme.floor, .uv_scale = .init(6, 6) },
    });
    const shapes = [_]struct { shape: fx.PrimitiveMesh3D.Shape, x: f32, color: Color }{
        .{ .shape = .box, .x = -4, .color = .oklch(0.72, 0.14, 25) },
        .{ .shape = .sphere, .x = -2, .color = .oklch(0.78, 0.13, 85) },
        .{ .shape = .cylinder, .x = 0, .color = .oklch(0.74, 0.13, 150) },
        .{ .shape = .capsule, .x = 2, .color = .oklch(0.72, 0.12, 235) },
        .{ .shape = .box, .x = 4, .color = .oklch(0.70, 0.14, 310) },
    };
    for (shapes, 0..) |made, i| {
        var shape: fx.PrimitiveMesh3D = .of(made.shape);
        shape.height = 1.4;
        shape.radius = 0.6;
        shape.size = .init(1.1, 1.1, 1.1);
        _ = try app.world.spawnWith(.{
            Transform3D{ .position = .init(made.x, 0.3, 0) },
            fx.MeshInstance3D{},
            shape,
            fx.Material3D{ .albedo_color = made.color, .unshaded = i == 4 },
            Spin{ .speed = 0.4 + 0.2 * @as(f32, @floatFromInt(i)) },
        });
    }
    // A see-through pane in front, both its sides drawn.
    var pane: Transform3D = .{ .position = .init(0, 0.4, 2.2) };
    pane.rotateX(std.math.pi / 2.0);
    _ = try app.world.spawnWith(.{
        pane,
        fx.MeshInstance3D{},
        fx.PrimitiveMesh3D{ .shape = .plane, .size = .init(3, 1, 1.6) },
        fx.Material3D{ .albedo_color = .hexa(0x9FD3FF60), .transparency = .alpha, .cull = .disabled },
    });

    var sun: Transform3D = .{};
    sun.lookAt(.init(-0.4, -1, -0.6), .unit_y);
    _ = try app.world.spawnWith(.{ sun, fx.DirectionalLight3D{ .energy = 0.9 } });

    var eye: Transform3D = .at(0, 3.5, 9);
    eye.lookAt(.zero, .unit_y);
    _ = try app.world.spawnWith(.{ eye, fx.Camera3D{ .fov = std.math.degreesToRadians(55.0), .current = true } });

    const font = app.assets.loadSystemFont(.{}) catch |err| blk: {
        std.log.warn("no font ({t}); the words will not draw", .{err});
        break :blk fx.FontHandle.none;
    };
    const caption = try app.world.spawnWith(.{ fx.Transform2D.at(16, 16), fx.Text2D{ .font = font, .color = theme.text, .size = 20 }, Caption{} });
    try app.setText(caption, fx.Text2D, "text", "Five shapes, one camera, the sun");
}

fn spin(app: *App) !void {
    var it = try fx.ecs.Query(.{ Transform3D, Spin }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(Transform3D), chunk.slice(Spin)) |*place, turn| place.rotateY(turn.speed * app.time.delta);
    }
}

/// The camera goes slowly round the middle.
fn orbit(app: *App) !void {
    const camera = app.currentCamera3D() orelse return;
    const place = app.world.get(camera, Transform3D) orelse return;
    const angle: f32 = @floatCast(app.time.elapsed * 0.15);
    place.position = .init(9 * @sin(angle), 3.5, 9 * @cos(angle));
    place.lookAt(.zero, .unit_y);
}

/// What a click is on: the nearest shape whose box the ray meets.
fn pick(app: *App) !void {
    if (!app.input.buttonJustPressed(.left)) return;
    const camera = app.currentCamera3D() orelse return;
    const pointer: fx.Vec2 = .init(app.input.pointer.x, app.input.pointer.y);
    const ray: fx.math.Ray = .init(app.projectRayOrigin(camera, pointer).?, app.projectRayNormal(camera, pointer).?);
    var nearest: ?fx.PrimitiveMesh3D.Shape = null;
    var best = std.math.inf(f32);
    var it = try fx.ecs.Query(.{ Transform3D, fx.PrimitiveMesh3D, Spin }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(Transform3D), chunk.slice(fx.PrimitiveMesh3D)) |place, shape| {
            const box: fx.math.Aabb = .fromCenterExtents(place.position, .splat(0.7));
            const t = ray.intersectAabb(box) orelse continue;
            if (t < best) {
                best = t;
                nearest = shape.shape;
            }
        }
    }
    var words: [64]u8 = undefined;
    const said = if (nearest) |shape| try std.fmt.bufPrint(&words, "That is a {t}", .{shape}) else "Nothing there";
    var captions = try fx.ecs.Query(.{Caption}).over(&app.world);
    while (captions.next()) |chunk| for (chunk.entities) |entity| try app.setText(entity, fx.Text2D, "text", said);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &stdout.interface;

    const flags = try App.parseFlags(App.Flags, try init.minimal.args.toSlice(init.arena.allocator()));
    const app = App.create(gpa, flags.apply(.{
        .title = "Shapes - Fluxion Engine",
        .width = 960,
        .height = 540,
        .clear_color = theme.background,
        .io = init.io,
        .quit_key = .escape,
        .fullscreen_key = .f11,
    })) catch |err| switch (err) {
        error.NoDisplay => {
            try out.print("no display, so nothing to show\n", .{});
            try out.flush();
            return;
        },
        else => return err,
    };
    defer app.destroy();

    try out.print("{f}\n", .{app.device.info()});
    try out.print("Left click says which shape is under the pointer. F11 fills the screen, Escape leaves.\n", .{});
    try out.flush();

    try app.registerComponents(.{ Spin, Caption });
    try app.addSystem(.startup, "spawn", spawn);
    try app.addSystem(.update, "spin", spin);
    try app.addSystem(.update, "orbit", orbit);
    try app.addSystem(.update, "pick", pick);

    app.run() catch |err| {
        if (app.schedule.failed) |failure| try out.print("{f}\n", .{failure});
        try out.flush();
        return err;
    };

    try out.print("{d} frames, {d} meshes drawn in {d} draws\n", .{ app.time.frame, app.renderer3d.drawn, app.renderer3d.draw_calls });
    if (flags.capture) |path| {
        try app.saveCapture(path);
        try out.print("wrote {s}\n", .{path});
    }
    try out.flush();
}
