// SPDX-License-Identifier: BSD-3-Clause

//! A frame drawn, layer by layer: the render views' pictures first, then
//! the 3D world, the 2D world over it, the interface over that and `debug`
//! over everything - into the window, a capture, or an editor's view of the
//! world.
//!
//! A frame with a material in it that reads what is drawn under it is drawn
//! into a texture of its own - a surface cannot be read - and put on the
//! window after: see `render/screen.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const rhi = @import("fluxion_rhi");
const image = @import("fluxion_image");

const App = @import("../App.zig");
const cameras = @import("cameras.zig");
const view3d = @import("view3d.zig");
const View3D = view3d.View3D;
const Lighting = @import("renderer3d.zig").Lighting;
const view_textures = @import("view_textures.zig");
const Material = @import("shaders.zig").Material;
const GameArea = @import("stretch.zig").GameArea;
const View = @import("view.zig").View;
const Color = @import("../math/color.zig").Color;

/// What this frame is drawn into.
pub fn target(app: *App) rhi.RenderTarget {
    if (app.surface) |surface| return .{ .surface = surface };
    return .{ .texture = app.offscreen.? };
}

/// Draw the layers, back to front, into one target.
pub fn render(app: *App) !void {
    try drawLayers(app, target(app), @floatFromInt(app.width), @floatFromInt(app.height));
    if (app.surface) |surface| try app.device.present(surface);
}

/// Every layer, in order, into whatever it is given. Separate from `render`,
/// so that `capture` can draw the same frame somewhere else.
///
/// A frame with a material in it that reads what is drawn under it is drawn
/// into a texture of its own - a surface cannot be read - and put on `into`
/// after. See `render/screen.zig`.
fn drawLayers(app: *App, into: rhi.RenderTarget, width: f32, height: f32) !void {
    app.sprites.time = @floatCast(app.interface.seconds);
    app.screen_texture.copies = 0;
    try view_textures.drawAll(app);
    // The game area for a target this size: the window's, or a capture's.
    const area = app.stretch.areaOf(@intFromFloat(width), @intFromFloat(height));
    const area_width: f32 = @floatFromInt(area.width);
    const area_height: f32 = @floatFromInt(area.height);
    if (!area.apart and !readsScreen(app)) return drawLayersInto(app, into, area, area_width, area_height);
    const picture = try app.screen_texture.frameOf(area.width, area.height, app.clear_color);
    try drawLayersInto(app, .{ .texture = picture }, area, area_width, area_height);
    // A picture scaled to the window is sampled as the project's textures
    // are; a canvas is one pixel to one.
    const filter: rhi.Filter = if (app.stretch.mode == .picture) app.assets.default_filter else .nearest;
    const shown = area.shown;
    try app.screen_texture.present(picture, into, .{ .x = shown.x, .y = shown.y, .width = shown.width, .height = shown.height }, app.assets.samplerFor(filter, .clamp_to_edge), .black);
}

fn drawLayersInto(app: *App, into: rhi.RenderTarget, area: GameArea, width: f32, height: f32) !void {
    // 1. The 3D layer, through the current 3D camera when there is one,
    //    with a depth test, clearing the frame: the 2D layer goes over it.
    var clear: ?Color = app.clear_color;
    if (app.world_on_screen) if (view3d.currentCamera(app)) |camera| if (view3d.viewOf(app, camera, width, height)) |seen| {
        try draw3D(app, into, area.width, area.height, seen, clear, .{});
        clear = null;
    };

    // 2. The 2D layer: sprites and text, sorted back to front, blended, no
    //    depth - or, with the world off the screen, only the clearing.
    const view = cameras.viewAt(app, area, width, height);
    if (app.world_on_screen) {
        const under = try drawDebugUnder(app, into, view, clear);
        try app.sprites.draw(app.gpa, &app.world, &app.assets, &app.tile_sets, &app.snapshots, &app.inherited, into, view, under, app.time.alpha());
    } else try clearTarget(app, into);

    // 3. The interface, on top, loading what the 2D layer left - with its
    //    glyphs drawn again when a font was read again since.
    if (app.interface.font_reloads != app.assets.font_reloads) {
        app.interface.forgetGlyphs();
        app.interface.font_reloads = app.assets.font_reloads;
    }
    try app.interface.draw(app.gpa, &app.device, app.interface.fillFaces(&app.assets), into, width, height);

    // 4. `debug`, over all of it: the world through the 2D camera, and the
    //    screen in pixels.
    if (app.world_on_screen and app.debug_visible) try drawDebug(app, into, view);
}

/// Whether a frame has something in it that reads what is drawn under it:
/// then it is drawn where it can be read. See `render/screen.zig`.
fn readsScreen(app: *App) bool {
    var it = ecs.Query(.{Material}).over(&app.world) catch return false;
    while (it.next()) |chunk| {
        for (chunk.slice(Material)) |held| {
            const compiled = app.shaders.compiledOf(held.shader) orelse continue;
            if (compiled.readsScreen()) return true;
        }
    }
    return false;
}

/// Draw the world - its sprites, its text and `debug` - through `view` into
/// `into`, a texture made with `.render_target = true` at the view's size,
/// cleared to the background first. An editor's scene view is this, and so
/// is a minimap; with `world_on_screen` off, it is the only place the world
/// is drawn.
///
/// ```zig
/// var view: fx.View = .screen(640, 360);
/// view.x = player.x;
/// view.zoom_x = 2;
/// view.zoom_y = 2;
/// try drawWorld(app, minimap, view);
/// ```
///
/// On OpenGL a texture drawn into is read bottom row first, so shown in the
/// interface it wants its `source` turned over; see `drawnUpsideDown`.
pub fn drawWorld(app: *App, into: rhi.Texture, view: View) !void {
    try drawWorldWithoutDebug(app, into, view);
    try drawDebugOverlay(app, into, view);
}

/// `drawWorld` without the `debug` lines over it, for an editor that draws
/// its interface preview over the world first and its marks last, with
/// `drawDebugOverlay`: a material there that reads the screen reads the
/// game's picture, not a selection's outline or a camera's frame.
pub fn drawWorldWithoutDebug(app: *App, into: rhi.Texture, view: View) !void {
    app.sprites.time = @floatCast(app.interface.seconds);
    try view_textures.drawAll(app);
    const clear = try drawDebugUnder(app, .{ .texture = into }, view, app.clear_color);
    try app.sprites.draw(app.gpa, &app.world, &app.assets, &app.tile_sets, &app.snapshots, &app.inherited, .{ .texture = into }, view, clear, app.time.alpha());
}

/// Draw the 3D world through `view` into `into` - a texture made with
/// `.render_target = true` at the view's size - cleared to the background
/// first, with `debug_3d` over it: an editor's view of a 3D scene, through
/// a camera of its own. The 2D world is not drawn.
pub fn drawWorld3D(app: *App, into: rhi.Texture, view: View3D, lighting: Lighting) !void {
    try draw3D(app, .{ .texture = into }, @intFromFloat(@max(view.width, 1)), @intFromFloat(@max(view.height, 1)), view, app.clear_color, lighting);
}

/// The 3D world into a target `width` by `height`, and `debug_3d` over it,
/// hidden behind what is in front of it.
fn draw3D(app: *App, into: rhi.RenderTarget, width: u32, height: u32, view: View3D, clear: ?Color, lighting: Lighting) !void {
    try app.renderer3d.draw(app, into, width, height, view, clear, lighting);
    if (!app.debug_visible or app.debug_3d_frame.isEmpty()) return;
    const renderer = if (app.debug_renderer_3d) |*held| held else return;
    const depth = app.renderer3d.last_depth orelse return;
    try renderer.draw(&.{&app.debug_3d_frame}, .{ .color = into, .depth = depth }, .{
        .view_projection = view.matrix(app.device.clip()),
        .width = view.width,
        .height = view.height,
    });
}

/// Draw this frame's world-space debug lines over an editor preview: after
/// `drawWorldWithoutDebug` and `drawControlPreview`.
pub fn drawDebugOverlay(app: *App, into: rhi.Texture, view: View) !void {
    if (app.debug_visible) try drawDebug(app, .{ .texture = into }, view);
}

/// Whether a texture `drawWorld` drew into comes out upside down when drawn
/// as a picture: what the device says of what it draws - true on OpenGL,
/// whose framebuffers count rows from the bottom.
pub fn drawnUpsideDown(app: *const App) bool {
    return app.device.caps().features.render_target_origin_bottom_left;
}

/// Clear `into` to `clear` - the background, or nothing over a 3D layer
/// - and draw `debug_under` on it, for the sprites to go over: the colour
/// the sprites should clear to, which is none once this has cleared. With
/// nothing under the world - the usual case - no pass is made, and the
/// sprites clear as they always did.
fn drawDebugUnder(app: *App, into: rhi.RenderTarget, view: View, clear: ?Color) !?Color {
    app.debug_under_stats = .{};
    if (!app.debug_visible) return clear;
    if (app.debug_under_frame.isEmpty() and app.debug_under_steps.isEmpty()) return clear;
    try app.debug_renderer.draw(&.{ &app.debug_under_steps, &app.debug_under_frame }, .{
        .color = into,
        .clear = if (clear) |color| color.array() else null,
    }, .{
        .view_projection = view.matrix(app.device.clip()),
        .width = view.width,
        .height = view.height,
    });
    app.debug_under_stats = app.debug_renderer.stats;
    return null;
}

fn drawDebug(app: *App, into: rhi.RenderTarget, view: View) !void {
    try app.debug_renderer.draw(&.{ &app.debug_steps, &app.debug_frame }, .{ .color = into }, .{
        .view_projection = view.matrix(app.device.clip()),
        .width = view.width,
        .height = view.height,
    });
}

/// Start a frame from the background, for a frame that draws no world.
fn clearTarget(app: *App, into: rhi.RenderTarget) !void {
    const list = app.device.begin();
    try list.beginPass(.{ .color = .{ .target = into, .clear_color = app.clear_color.array() } });
    try list.endPass();
    try app.device.submit();
}

/// Draw one frame into a texture of its own and hand back the pixels: four
/// bytes each, top row first, owned by the caller. The same passes as a
/// frame on screen, so a capture shows what a player sees.
pub fn capture(app: *App, gpa: Allocator, width: u32, height: u32) ![]u8 {
    const texture = try app.device.createTexture(.{
        .width = width,
        .height = height,
        .usage = .{ .sampled = true, .render_target = true },
        .clear_color = app.clear_color.array(),
        .label = "capture",
    });
    defer app.device.destroyTexture(texture);

    try drawLayers(app, .{ .texture = texture }, @floatFromInt(width), @floatFromInt(height));
    return app.device.readTexture(texture, gpa);
}

/// Draw one frame at the target's size into a PNG file: what `--capture`
/// asks for. `res://` is taken, as everywhere. `error.NoIo` without
/// `Options.io`.
pub fn saveCapture(app: *App, path: []const u8) !void {
    const io = app.io orelse return error.NoIo;
    const file = try app.project.osPath(app.gpa, path);
    defer app.gpa.free(file);

    const pixels = try capture(app, app.gpa, app.width, app.height);
    defer app.gpa.free(pixels);

    try image.png.writeFile(app.gpa, io, file, .{
        .width = app.width,
        .height = app.height,
        .pixels = pixels,
        .row_pitch = app.width * 4,
    }, .{});
}
