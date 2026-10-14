// SPDX-License-Identifier: BSD-3-Clause

//! The light from everywhere: a room baked, a probe volume and a reflection
//! probe in it.
//!
//! ```bash
//! zig build example-light -- --root /tmp/light
//! FLUXION_VOLUME=realtime zig build example-light -- --root /tmp/light --frames 240 --capture light.png
//! FLUXION_QUALITY=high zig build example-light -- --root /tmp/light
//! ```
//!
//! A closed room - a red wall, a green one, a door out to the dark - lit by
//! a lamp under its ceiling, its light baked by a `LightmapGI` at startup
//! into the project at `--root` (`room.lightmap`). A white ball stands in
//! it, lit by the room's `ProbeVolume3D`: as baked, or - `FLUXION_VOLUME`
//! `realtime` - lit again every frame as the lamp is now, the lamp turning
//! from warm to blue and back, so the ball and the walls' light from
//! everywhere follow it. `off` leaves the volume out. A chrome ball shows
//! the room's `ReflectionProbe3D`, captured again as the lamp turns where
//! the volume is realtime. `FLUXION_QUALITY` - `low`, `medium`, `high` -
//! sets both probes' quality: the reflection probe's picture's side
//! (`App.setReflectionProbeSize`) and the rays of the volume's probes.

const std = @import("std");
const fx = @import("fluxion_engine");

const App = fx.App;
const Transform3D = fx.Transform3D;
const Color = fx.Color;

const Mode = enum { off, baked, realtime };

/// The lamp, whose colour a realtime volume follows.
const Lamp = extern struct { turn: f32 = 0 };

const Quality = fx.ProbeVolume3D.Quality;

fn quality() Quality {
    const said = std.c.getenv("FLUXION_QUALITY") orelse return .medium;
    return std.meta.stringToEnum(Quality, std.mem.span(said)) orelse .medium;
}

fn mode() Mode {
    const said = std.c.getenv("FLUXION_VOLUME") orelse return .baked;
    return std.meta.stringToEnum(Mode, std.mem.span(said)) orelse .baked;
}

fn wall(app: *App, at: [3]f32, size: [3]f32, look: fx.MaterialHandle) !void {
    const made = try app.world.spawnWith(.{
        Transform3D.at(at[0], at[1], at[2]),
        fx.MeshInstance3D{},
        fx.PrimitiveMesh3D{ .shape = .box, .size = .init(size[0], size[1], size[2]) },
        fx.Material3D{ .material = look },
    });
    // A lightmap finds its meshes by their UUIDs.
    _ = try app.ensureUuid(made);
}

fn spawn(app: *App) !void {
    const white = try app.addMaterial("white", .{ .albedo_color = .hex(0xD8D8D8) });
    const red = try app.addMaterial("red", .{ .albedo_color = .hex(0xC02818) });
    const green = try app.addMaterial("green", .{ .albedo_color = .hex(0x28A830) });
    // Floor, ceiling, back; the red left, the green right; the front with a door.
    try wall(app, .{ 0, -2, 0 }, .{ 8, 0.2, 8 }, white);
    try wall(app, .{ 0, 2, 0 }, .{ 8, 0.2, 8 }, white);
    try wall(app, .{ 0, 0, -4 }, .{ 8, 4, 0.2 }, white);
    try wall(app, .{ -4, 0, 0 }, .{ 0.2, 4, 8 }, red);
    try wall(app, .{ 4, 0, 0 }, .{ 0.2, 4, 8 }, green);
    try wall(app, .{ -2.5, 0, 4 }, .{ 3, 4, 0.2 }, white);
    try wall(app, .{ 2.5, 0, 4 }, .{ 3, 4, 0.2 }, white);
    try wall(app, .{ 0, 1.4, 4 }, .{ 2, 1.2, 0.2 }, white);

    const lamp = try app.world.spawnWith(.{ Transform3D.at(0, 1.5, -1), fx.PointLight3D{ .range = 12, .energy = 3, .color = .hex(0xFFD8A0), .bake = .indirect, .shadow = true }, Lamp{} });
    _ = try app.ensureUuid(lamp);

    _ = try app.world.spawnWith(.{
        Transform3D.at(-1, -1.2, -0.5),
        fx.MeshInstance3D{ .gi_mode = .dynamic },
        fx.PrimitiveMesh3D{ .shape = .sphere, .radius = 0.7 },
        fx.Material3D{ .material = try app.addMaterial("ball", .{ .albedo_color = .hex(0xF0F0F0) }) },
    });
    _ = try app.world.spawnWith(.{
        Transform3D.at(1.4, -1.3, 0.3),
        fx.MeshInstance3D{ .gi_mode = .dynamic },
        fx.PrimitiveMesh3D{ .shape = .sphere, .radius = 0.6 },
        fx.Material3D{ .material = try app.addMaterial("chrome", .{ .albedo_color = .hex(0xF2F2F2), .metallic = 1, .roughness = 0.08 }) },
    });
    const chosen = mode();
    app.setReflectionProbeSize(switch (quality()) {
        .low => .x64,
        .medium => .x128,
        .high => .x256,
    });
    // Captured once; realtime - a face a frame - where the lamp turns.
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0, 0), fx.ReflectionProbe3D{ .extents = .init(3.9, 1.9, 3.9), .blend_distance = 0.3, .update = if (chosen == .realtime) .realtime else .once } });

    if (chosen != .off) {
        const volume = try app.world.spawnWith(.{ Transform3D.at(0, 0, 0), fx.ProbeVolume3D{ .extents = .init(3.8, 1.8, 3.8), .spacing = 0.9, .quality = quality(), .mode = if (chosen == .realtime) .realtime else .baked } });
        _ = try app.ensureUuid(volume);
    }

    var eye: Transform3D = .at(0, 0.4, 3.4);
    eye.lookAt(.init(0, -0.4, 0), .unit_y);
    _ = try app.world.spawnWith(.{ eye, fx.Camera3D{ .fov = std.math.degreesToRadians(60.0), .current = true } });

    // The room's light, baked now: the probe volume's with it.
    const gi = try app.world.spawnWith(.{fx.LightmapGI{ .texels_per_unit = 4, .quality = .medium, .bounces = 3 }});
    const bake = try app.bakeLightmap(gi, "res://room.lightmap");
    _ = try bake.finish(app);
}

/// A realtime volume's lamp turns from warm to blue and back.
fn turnLamp(app: *App) !void {
    if (mode() != .realtime) return;
    var it = try fx.ecs.Query(.{ fx.PointLight3D, Lamp }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(fx.PointLight3D), chunk.slice(Lamp)) |*light, *lamp| {
            lamp.turn += app.time.delta * 0.8;
            const t = 0.5 + 0.5 * @sin(lamp.turn);
            light.color = .{ .r = 1.0 - 0.7 * t, .g = 0.85 - 0.3 * t, .b = 0.6 + 0.4 * t, .a = 1 };
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &stdout.interface;

    const flags = try App.parseFlags(App.Flags, try init.minimal.args.toSlice(init.arena.allocator()));
    if (flags.root == null) {
        try out.print("the room's light is baked into a project: --root <folder>\n", .{});
        try out.flush();
        return;
    }
    const app = App.create(gpa, flags.apply(.{
        .title = "Light - Fluxion Engine",
        .width = 960,
        .height = 540,
        .clear_color = .hex(0x050607),
        .io = init.io,
        .quit_key = .escape,
    })) catch |err| switch (err) {
        error.NoDisplay => {
            try out.print("no display, so nothing to show\n", .{});
            try out.flush();
            return;
        },
        else => return err,
    };
    defer app.destroy();
    try out.print("{f}, probe volume {t}, {t} quality\n", .{ app.device.info(), mode(), quality() });
    try out.flush();

    try app.registerComponents(.{Lamp});
    try app.addSystem(.startup, "spawn", spawn);
    try app.addSystem(.update, "turn lamp", turnLamp);
    app.run() catch |err| {
        if (app.schedule.failed) |failure| try out.print("{f}\n", .{failure});
        try out.flush();
        return err;
    };
    if (flags.capture) |path| {
        try app.saveCapture(path);
        try out.print("wrote {s}\n", .{path});
    }
    try out.flush();
}
