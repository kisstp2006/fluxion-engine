// SPDX-License-Identifier: BSD-3-Clause

//! Cameras: what the screen looks through, what each one shows of the
//! world, and a smoothed one's frame drawing toward where it is.

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const Frame = @import("stretch.zig").Frame;
const View = @import("view.zig").View;

/// What the camera sees, at the frame's size and scale: the view the world
/// is drawn through and the pointer is found in.
pub fn currentView(app: *App) View {
    return viewAt(app, app.frame, @floatFromInt(app.frame.width), @floatFromInt(app.frame.height));
}

/// What the camera sees in a frame this size, as the stretch scales it:
/// worked out at the size the game is made at - where a world with no
/// camera has its origin at the top left, and a camera's fit is measured -
/// and drawn at the frame's pixels.
pub fn viewAt(app: *App, frame: Frame, width: f32, height: f32) View {
    const scale = if (frame.scale > 0) frame.scale else 1;
    var view: View = .of(&app.world, &app.snapshots, width / scale, height / scale);
    view.width = width;
    view.height = height;
    return view.zoomed(scale);
}

/// The camera the screen looks through: the active one with the highest
/// priority that draws no picture of its own, or null for none.
pub fn currentCamera(app: *App) ?ecs.Entity {
    const seen = View.lookedThrough(&app.world, &app.snapshots) orelse return null;
    return seen.entity;
}

/// What a camera shows of the world: through it at the game's size - or,
/// for one that draws a picture of its own, at the picture's.
pub fn viewOf(app: *App, entity: ecs.Entity) ?View {
    const camera = app.world.get(entity, components.Camera2D) orelse return null;
    const placed = app.drawnTransform(entity) orelse return null;
    const size = if (app.world.get(entity, components.RenderView)) |own| [2]f32{ @floatFromInt(own.width), @floatFromInt(own.height) } else app.gameSize();
    return .through(camera.*, placed, size[0], size[1]);
}

/// A smoothed camera's frame toward where it is: `Camera2D.smoothing`. With
/// no time going by - an editor's frame - it is where it is.
pub fn follow(app: *App) !void {
    var it = try ecs.Query(.{components.Camera2D}).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(components.Camera2D), chunk.entities) |*camera, entity| {
            const placed = app.drawnTransform(entity) orelse continue;
            const aim = camera.target(placed);
            const delta = app.time.delta;
            if (!camera.smoothing or !camera.following or delta <= 0) {
                camera.shown = aim;
            } else {
                const closed = 1 - @exp(-camera.smoothing_speed * delta);
                camera.shown = camera.shown.add(aim.sub(camera.shown).scale(closed));
            }
            camera.following = true;
        }
    }
}

/// Where the middle of what a camera shows is in the world: after its
/// offset, its smoothing and its limits.
pub fn screenCenter(app: *App, camera: ecs.Entity) ?math.Vec2 {
    const view = viewOf(app, camera) orelse return null;
    return .init(view.x, view.y);
}

/// Put a smoothed camera where it is at once: after a teleport, a new
/// level.
pub fn resetSmoothing(app: *App, camera: ecs.Entity) void {
    const held = app.world.get(camera, components.Camera2D) orelse return;
    held.following = false;
}

/// The corners of what a camera shows, in the world, clockwise from the
/// screen's top left: a frame an editor draws round it.
pub fn cornersOf(app: *App, entity: ecs.Entity) ?[4]math.Vec2 {
    const view = viewOf(app, entity) orelse return null;
    return .{
        view.toWorld(.init(0, 0)),
        view.toWorld(.init(view.width, 0)),
        view.toWorld(.init(view.width, view.height)),
        view.toWorld(.init(0, view.height)),
    };
}

/// Where the game's screen is in the world, for an editor: the top left of
/// what the current camera shows at the game's size, and how many of the
/// world's units a pixel of the screen is - with no camera, the world's
/// origin and one. The camera's turn is left out: the interface is not
/// turned with it.
pub const ScreenPlace = struct { top_left: math.Vec2, units_per_pixel: f32 };

pub fn screenInWorld(app: *App) ScreenPlace {
    const camera = currentCamera(app) orelse return .{ .top_left = .init(0, 0), .units_per_pixel = 1 };
    const view = viewOf(app, camera).?;
    const size = app.gameSize();
    return .{
        .top_left = .init(view.x - size[0] / (2 * view.zoom_x), view.y - size[1] / (2 * view.zoom_y)),
        .units_per_pixel = 1 / view.zoom_x,
    };
}
