// SPDX-License-Identifier: BSD-3-Clause

//! Fluxion Engine - a window, a world, and the loop between them.
//!
//!   `App`         the frame: what it owns, and the order it does things in
//!   `schedule`    when a game's systems run
//!   `components`  what the renderer knows how to read
//!   `assets`      what the GPU is holding, and the handles that name it
//!   `Input`       what the keyboard and the mouse did
//!   `Time`        how long the last frame took, and the fixed step
//!   `color`       a colour, and the three ways to write one down
//!   `Window`      the window and the event queue
//!   `render`      the layers, and what draws each
//!
//! ```zig
//! const fx = @import("fluxion_engine");
//!
//! pub fn main(init: std.process.Init) !void {
//!     const app = try fx.App.create(init.gpa, .{ .title = "game", .io = init.io });
//!     defer app.destroy();
//!
//!     try app.addSystem(.startup, spawn);
//!     try app.addSystem(.fixed, move);
//!     try app.run();
//! }
//!
//! fn spawn(app: *fx.App) !void {
//!     _ = try app.world.spawnWith(.{
//!         fx.Transform2D.at(320, 180),
//!         fx.Sprite.solid(.hex(0x3AA0FF), 48, 48),
//!     });
//! }
//! ```
//!
//! **A scene is a world, and a node is an entity.** The shape is Godot's -
//! open a window, put things in a scene, give them behaviour, draw - and the
//! thing in the middle is an ECS rather than a tree of objects with virtual
//! methods on them. What that buys is in
//! [Fluxion ECS](https://github.com/kisstp2006/fluxion-ecs): everything of
//! one shape sits in one table, so a system is a loop over slices with no
//! branch in it asking what this one is.
//!
//! **Three layers, drawn back to front into one target.** 3D first with a
//! depth test, then 2D blended with none, then the interface on top of both.
//! Each is its own render pass into the same surface: the first clears, the
//! rest load what the one before left. Today the 2D pass is the only one
//! written - see `docs/in-game-ui.md` for what the interface layer is waiting
//! on, and the note in `App.render` for where the 3D one goes.
//!
//! **The engine is what may open a window.** Every library under this one is
//! forbidden from it - `fluxion-ui` lays out and does not draw, `fluxion-rhi`
//! draws and does not open windows, `fluxion-ecs` does neither and runs in a
//! browser because of it. This package is where all of that is finally
//! allowed to touch a machine, which is also why it is the only one whose
//! dependencies are not lazy.

const std = @import("std");

pub const App = @import("App.zig");
pub const Window = @import("window.zig");
pub const Input = @import("input.zig");
pub const Time = @import("time.zig");
pub const Assets = @import("assets.zig");

pub const assets = @import("assets.zig");
pub const components = @import("components.zig");
pub const color = @import("color.zig");
pub const schedule = @import("schedule.zig");

pub const render = struct {
    pub const sprite = @import("render/sprite.zig");
};

/// Where a thing is, how big, and which way round. See `components`.
pub const Transform2D = components.Transform2D;

/// A picture drawn at a transform. See `components`.
pub const Sprite = components.Sprite;

/// Which part of a texture a sprite shows. See `components`.
pub const Region = components.Region;

/// What the 2D pass looks through. See `components`.
pub const Camera2D = components.Camera2D;

/// Where a thing was before the last fixed step, so it can be drawn smoothly
/// between steps. See `components`.
pub const Previous2D = components.Previous2D;

/// A colour, four floats from zero to one. See `color`.
pub const Color = color.Color;

/// What a `Sprite` points at. See `assets`.
pub const TextureHandle = assets.TextureHandle;

/// Which part of the frame a system runs in. See `schedule`.
pub const Stage = schedule.Stage;

/// What a system is. See `schedule`.
pub const System = schedule.System;

/// The world, and everything in it, re-exported so a game need not name the
/// package to spawn something.
pub const ecs = @import("fluxion_ecs");

/// Everything a program says to a device, for a game that wants to draw
/// something the engine has no component for yet.
pub const rhi = @import("fluxion_rhi");

/// Windows, input and the event loop. `Key` lives here.
pub const platform = @import("fluxion_platform");

/// Projections, matrices and vectors.
pub const math = @import("fluxion_math");

/// A PNG, read and written. What a texture comes from, and where a capture
/// goes.
pub const image = @import("fluxion_image");

/// A physical key, at its position on a US layout. What `Input` is asked
/// about, re-exported so `.space` and `.escape` work without an import.
pub const Key = platform.Key;

/// A mouse button.
pub const MouseButton = platform.MouseButton;

/// One entity: eight bytes with a generation in them.
pub const Entity = ecs.Entity;

/// Everything with a set of components, in slices. See `ecs.Query`.
pub const Query = ecs.Query;

test {
    _ = App;
    _ = Window;
    _ = Input;
    _ = Time;
    _ = assets;
    _ = components;
    _ = color;
    _ = schedule;
    _ = render.sprite;
}
