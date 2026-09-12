// SPDX-License-Identifier: BSD-3-Clause

//! Rigid bodies: a floor, a ramp, a pile of crates, a ball on a rod, and a
//! basket that counts what falls into it.
//!
//! ```bash
//! zig build example-crates
//! zig build example-crates -- --frames 240 --capture crates.png
//! zig build example-crates -- --views on
//! ```
//!
//! Left click drops a crate where the pointer is, right click a ball. Space
//! throws everything up. F3 shows what the physics sees, F11 fills the
//! screen, Escape leaves.
//!
//! **Nothing here makes a body.** Every entity says what it is - a
//! `RigidBody2D` to fall, a `Collider2D` for its shape - and the engine makes
//! the bodies in `app.physics` and writes where they went back into their
//! transforms. The walls and the ramp have a collider and no body, which makes
//! each a static body of its own; the colliders have no size, which makes
//! each the size of its sprite.
//!
//! **Writing is moving.** Space writes a velocity into every crate's
//! `RigidBody2D` from a `.fixed` system, and that step flings them.
//!
//! **What touched comes back as entities.** The basket is a sensor, which
//! pushes nothing and is still heard: `app.contactsBegun()` and
//! `contactsEnded()` say what came in and what left, each once, and the
//! count over it is the difference.
//!
//! **The rest is `app.physics`.** The ball swinging on the left hangs from a
//! pin by a distance joint, made from the two bodies' handles once
//! `app.syncBodies()` has made them. The red line is `app.castRay`, stopped
//! at whatever crosses it first.
//!
//! **F3 turns on three of the engine's debug views** - every collider in its
//! body's colour, where the moving bodies are heading, and the frame's
//! numbers - by writing `app.debug_views`, as an editor's View menu would.

const std = @import("std");
const fx = @import("fluxion_engine");

const App = fx.App;
const Transform2D = fx.Transform2D;
const Sprite = fx.Sprite;
const RigidBody2D = fx.RigidBody2D;
const Collider2D = fx.Collider2D;
const Text2D = fx.Text2D;
const Color = fx.Color;
const Vec2 = fx.Vec2;

const field_width: f32 = 960;
const field_height: f32 = 540;
const crate_size: f32 = 36;
const ball_size: f32 = 26;
const laser_y: f32 = 460;

const theme = struct {
    const background: Color = .hex(0x11151C);
    const wall: Color = .hex(0x2B3442);
    const crate: Color = .oklch(0.74, 0.12, 65);
    const ball: Color = .oklch(0.76, 0.12, 235);
    const basket: Color = .hexa(0x7FD1AE30);
    const text: Color = .hex(0xC9D3DF);
};

/// What the basket has in it. One entity has this.
const Basket = extern struct { inside: u32 = 0 };

/// The picture every ball is drawn with, made once at startup.
const Art = extern struct { disc: fx.TextureHandle = .none };

fn spawn(app: *App) !void {
    _ = try app.world.spawnWith(.{
        Transform2D.at(field_width / 2, field_height / 2),
        fx.Camera2D.fitting(field_width, field_height),
    });
    _ = try app.world.spawnWith(.{Art{ .disc = try disc(app) }});

    try wall(app, field_width / 2, field_height - 10, field_width, 20, 0);
    try wall(app, 10, field_height / 2, 20, field_height, 0);
    try wall(app, field_width - 10, field_height / 2, 20, field_height, 0);
    try wall(app, 330, 380, 300, 16, 0.3);

    var sensor: Collider2D = .{};
    sensor.sensor = true;
    const basket = try app.world.spawnWith(.{
        Transform2D.at(820, 460),
        Sprite.solid(theme.basket, 200, 140),
        sensor,
        Basket{},
    });
    try app.setName(basket, "basket");

    for (0..5) |row| {
        for (0..5 - row) |column| {
            const x = 520 + (@as(f32, @floatFromInt(column)) + @as(f32, @floatFromInt(row)) / 2) * (crate_size + 2);
            const y = field_height - 20 - crate_size / 2 - @as(f32, @floatFromInt(row)) * crate_size;
            _ = try crate(app, x, y);
        }
    }

    _ = try crate(app, 240, 250);
    _ = try ball(app, 790, 200);
    _ = try ball(app, 850, 120);

    const pin = try app.world.spawnWith(.{ Transform2D.at(200, 90), Sprite.solid(theme.wall, 10, 10), Collider2D{} });
    const bob = try ball(app, 340, 90);
    try app.syncBodies();
    _ = try app.physics.createJoint(.{ .distance = .{
        .body_a = app.bodyIdOf(pin).?,
        .body_b = app.bodyIdOf(bob).?,
        .anchor_a = .init(200, 90),
        .anchor_b = .init(340, 90),
    } });

    const font = app.assets.loadFont(fx.Assets.systemFontPath(), .{}) catch |err| blk: {
        std.log.warn("no font ({t}); the count will not draw", .{err});
        break :blk fx.FontHandle.none;
    };
    var label: Text2D = .of("");
    label.font = font;
    label.size = 18;
    label.color = theme.text;
    label.alignment = .right;
    // The top left is where the stats view writes.
    const counter = try app.world.spawnWith(.{ Transform2D.at(field_width - 34, 30), label });
    try app.setName(counter, "count");
}

fn wall(app: *App, x: f32, y: f32, width: f32, height: f32, rotation: f32) !void {
    _ = try app.world.spawnWith(.{
        Transform2D{ .x = x, .y = y, .rotation = rotation },
        Sprite.solid(theme.wall, width, height),
        Collider2D{},
    });
}

fn crate(app: *App, x: f32, y: f32) !fx.Entity {
    return app.world.spawnWith(.{
        Transform2D.at(x, y).interpolated(),
        Sprite.solid(theme.crate, crate_size, crate_size),
        RigidBody2D{},
        Collider2D{ .friction = 0.7 },
    });
}

fn ball(app: *App, x: f32, y: f32) !fx.Entity {
    const art = app.single(Art) orelse return error.NoArt;
    return app.world.spawnWith(.{
        Transform2D.at(x, y).interpolated(),
        Sprite{ .texture = art.disc, .tint = theme.ball, .width = ball_size, .height = ball_size },
        RigidBody2D{},
        Collider2D{ .shape = .circle, .restitution = 0.5 },
    });
}

/// A white disc with a soft edge, for tinting.
fn disc(app: *App) !fx.TextureHandle {
    const size = 64;
    var pixels: [size * size * 4]u8 = undefined;
    for (0..size) |y| {
        for (0..size) |x| {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - size / 2.0;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - size / 2.0;
            const cover = std.math.clamp(size / 2.0 - @sqrt(dx * dx + dy * dy), 0, 1);
            const at = (y * size + x) * 4;
            pixels[at..][0..4].* = .{ 255, 255, 255, @intFromFloat(cover * 255) };
        }
    }
    return app.assets.textureFromPixels(size, size, &pixels, .{ .filter = .linear, .label = "disc" });
}

fn drop(app: *App) !void {
    const at = app.pointerInWorld();
    if (app.input.buttonJustPressed(.left)) _ = try crate(app, at.x, at.y);
    if (app.input.buttonJustPressed(.right)) _ = try ball(app, at.x, at.y);
}

fn throw(app: *App) !void {
    if (!app.input.justPressed(.space)) return;
    var it = try fx.Query(.{RigidBody2D}).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(RigidBody2D)) |*body| {
            if (body.type == .dynamic) body.velocity.y -= 650;
        }
    }
}

fn count(app: *App) !void {
    const basket = app.find("basket") orelse return;
    const held = app.world.get(basket, Basket) orelse return;
    for (app.contactsBegun()) |contact| {
        if (contact.other(basket) != null) held.inside += 1;
    }
    for (app.contactsEnded()) |contact| {
        if (contact.other(basket) != null) held.inside -|= 1;
    }

    const counter = app.find("count") orelse return;
    const label = app.world.get(counter, Text2D) orelse return;
    label.print("{d} in the basket, {d} bodies, {d} awake", .{
        held.inside,
        app.physics.bodyCount(),
        app.physics.awakeCount(),
    });
}

fn laser(app: *App) !void {
    const from: Vec2 = .init(24, laser_y);
    const to: Vec2 = .init(field_width - 24, laser_y);
    if (app.castRay(from, to, .{})) |hit| {
        app.debug.with(.{ .width = 2 }).line2d(from, hit.point, .red);
        app.debug.cross2d(hit.point, 8, .yellow);
    } else {
        app.debug.with(.{ .width = 2 }).line2d(from, to, .red);
    }
}

fn toggleViews(app: *App) !void {
    if (app.input.justPressed(.f3)) showViews(app, !app.debug_views.colliders);
}

fn showViews(app: *App, on: bool) void {
    app.debug_views.colliders = on;
    app.debug_views.bodies = on;
    app.debug_views.stats = on;
}

const Flags = struct {
    app: App.Flags = .{},
    /// `--views on`: start with F3's views showing.
    views: ?enum { on, off } = null,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &stdout.interface;

    const flags = try App.parseFlags(Flags, try init.minimal.args.toSlice(init.arena.allocator()));
    const app = App.create(gpa, flags.app.apply(.{
        .title = "Crates - Fluxion Engine",
        .width = 960,
        .height = 540,
        .background = theme.background,
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
    try out.print("Left click drops a crate, right click a ball, space throws them up. F3 shows what the physics sees, F11 fills the screen, Escape leaves.\n", .{});
    try out.flush();

    if (flags.views == .on) showViews(app, true);
    try app.registerComponents(.{ Basket, Art });
    try app.addSystem(.startup, "spawn", spawn);
    try app.addSystem(.input, "views", toggleViews);
    try app.addSystem(.fixed, "throw", throw);
    try app.addSystem(.update, "drop", drop);
    try app.addSystem(.update, "count", count);
    try app.addSystem(.update, "laser", laser);

    app.run() catch |err| {
        if (app.schedule.failed) |failure| try out.print("{f}\n", .{failure});
        try out.flush();
        return err;
    };

    try out.print("{d} frames, {d} bodies, {d} awake\n", .{ app.time.frame, app.physics.bodyCount(), app.physics.awakeCount() });
    try out.print("time per system on the last frame:\n{f}", .{app.schedule});

    if (flags.app.capture) |path| {
        try app.saveCapture(path);
        try out.print("wrote {s}\n", .{path});
    }
    try out.flush();
}
