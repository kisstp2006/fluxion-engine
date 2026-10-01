// SPDX-License-Identifier: BSD-3-Clause

//! What a project says a game opens with, opened: its boot splash while it
//! reads, its autoloads - each named after its file and kept when the scene
//! changes - and then its main scene.

const std = @import("std");

const ecs = @import("fluxion_ecs");

const App = @import("../App.zig");
const Project = @import("Project.zig");
const components = @import("../scene/components.zig");
const layers = @import("../render/layers.zig");
const Script = @import("../script/script.zig").Script;

const log = std.log.scoped(.fluxion_engine);

/// Open what the project says a game opens with: its boot splash while it
/// reads, its autoloads - each named after its file and kept when the scene
/// changes - and then its main scene. What `Options.open_project` does at
/// `startup`.
pub fn open(app: *App) !void {
    const settings = app.project.settings orelse return;
    const application = settings.application;
    if (application.boot_splash.show) showBootSplash(app, application.boot_splash);
    try openAutoloads(app);
    if (application.main_scene.len > 0) try app.openScene(try app.loadScene(application.main_scene));
}

/// The project's `application.autoload` list, made: each scene or script an
/// entity named after its file, which a scene change leaves. What
/// `openProject` does before the main scene, for a tool that opens another.
pub fn openAutoloads(app: *App) !void {
    const settings = app.project.settings orelse return;
    for (settings.application.autoload) |path| {
        autoload(app, path) catch |err| {
            log.err("the autoload {s} did not open: {t}", .{ path, err });
            return err;
        };
    }
}

/// One autoload: a script on an entity of its own, or a scene's instance,
/// named after its file.
fn autoload(app: *App, path: []const u8) !void {
    const name = std.fs.path.stem(path);
    const made = if (std.ascii.endsWithIgnoreCase(path, ".flux")) blk: {
        const file = try app.loadScript(path);
        break :blk try app.world.spawnWith(.{Script.of(file)});
    } else try app.instantiate(try app.loadScene(path), .none);
    try app.setFreeName(made, name);
}

/// A frame of the project's boot splash: its colour, and its picture in the
/// middle of the window. Nothing without a window.
fn showBootSplash(app: *App, splash: Project.Application.BootSplash) void {
    if (app.window == null) return;
    const kept = app.clear_color;
    defer app.clear_color = kept;
    app.clear_color = splash.color;
    var shown: ?ecs.Entity = null;
    if (splash.image.len > 0) {
        if (app.assets.loadTexture(splash.image, .{ .filter = .linear })) |picture| {
            const middle = app.screenToWorld(@as(f32, @floatFromInt(app.game_area.width)) / 2, @as(f32, @floatFromInt(app.game_area.height)) / 2);
            shown = app.world.spawnWith(.{ components.Transform2D.at(middle.x, middle.y), components.Sprite.of(picture) }) catch null;
        } else |err| log.warn("the boot splash's picture {s} did not read: {t}", .{ splash.image, err });
    }
    defer if (shown) |e| app.world.despawn(e);
    layers.render(app) catch |err| log.warn("the boot splash was not drawn: {t}", .{err});
}
