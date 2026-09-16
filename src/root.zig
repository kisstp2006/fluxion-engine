// SPDX-License-Identifier: BSD-3-Clause

//! Fluxion Engine - a window, a world, and the loop between them.
//!
//! ```zig
//! const fx = @import("fluxion_engine");
//!
//! pub fn main(init: std.process.Init) !void {
//!     const app = try fx.App.create(init.gpa, .{ .title = "game", .io = init.io });
//!     defer app.destroy();
//!
//!     try app.addSystem(.startup, "spawn", spawn);
//!     try app.addSystem(.fixed, "move", move);
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
//! A scene is a world and a node is an entity: Godot's shape, with
//! [Fluxion ECS](https://github.com/kisstp2006/fluxion-ecs) in the middle.
//! Three layers - 3D, 2D, interface - are drawn back to front into one
//! target; the 2D layer and the interface are written, the 3D one is not. This
//! is the one package in the stack that may open a window.

const std = @import("std");

pub const App = @import("App.zig");
pub const Window = @import("window.zig");
pub const Input = @import("input.zig");
pub const Time = @import("time.zig");
pub const Assets = @import("assets.zig");
pub const Interface = @import("interface.zig");
pub const Clipboard = @import("clipboard.zig");

/// Spawns, despawns, adds and removes that wait for the system asking for
/// them to return: `app.commands`.
pub const Commands = @import("commands.zig");

/// What the engine draws into `app.debug` by itself - colliders, bodies,
/// transforms, sprites, cameras, stats - each off until asked for:
/// `app.debug_views`.
pub const DebugViews = @import("debug_views.zig");

/// A game's own states, each an enum with one value at a time: `app.state`,
/// `app.setState`, `app.addSystemIn`, `app.onEnter`.
pub const States = @import("states.zig");

/// Godot's signals, on components: `pub const signals` on one, and
/// `app.signal`, `connect`, `emit`. The table is `app.signals`.
pub const signals = @import("signals.zig");

/// A signal of one entity: Godot 4's `Signal`. See `App.signal`.
pub const Signal = signals.Signal;

/// What a signal calls: a method by name, or a Zig function. Godot's
/// `Callable`.
pub const Callable = signals.Callable;

/// Godot's `ConnectFlags`.
pub const ConnectFlags = signals.Flags;

/// How a connection is made: flags, unbinds, binds.
pub const ConnectOptions = signals.Options;

/// A value a connection hands its method after the signal's own.
pub const Bind = signals.Bind;

/// A connection, as `app.connectionsFrom` lists them.
pub const Connection = signals.Connection;

/// A signal an entity has, as `app.signalsOf` lists them.
pub const SignalInfo = signals.Info;

/// A method a connection can name, as `app.methodsOf` lists them.
pub const MethodInfo = signals.MethodInfo;

/// Typed events: what one system tells any others that care, by type rather
/// than by who. `app.send` and `app.events`.
pub const events = @import("events.zig");

/// The events of one type, last frame's and this frame's.
pub const Events = events.Events;

/// A place in the events of one type, reading each once.
pub const EventReader = events.Reader;

/// Flux scripts on entities, the way Godot puts a script on a node:
/// `app.useScripts`, `app.loadScript`, and a `Script` on the entity.
pub const script = @import("script.zig");

/// A script on an entity: a `.flux` file, and which struct in it.
pub const Script = script.Script;

/// A `.flux` file loaded into the app's VM.
pub const ScriptHandle = script.ScriptHandle;

/// The scripting language itself, for what a game or a tool does beyond a
/// `Script`: calling into a script by name, or checking one in an editor
/// with `flux.service` and `app.scriptSetup()`.
pub const flux = script.flux;

/// Where a game's files are: `res://` paths from the project's root, and
/// files known by the UUID in the `.uid` file beside them: `app.project`.
pub const Project = @import("Project.zig");

/// File and folder dialogs, the system's own: `app.openFileDialog`,
/// `app.openFolderDialog`, and the answer in `app.input.dialogAnswer`.
pub const dialog = @import("dialog.zig");

/// A 128-bit name for a thing, unique everywhere: what an entity is known by
/// in a scene - `app.uuidOf`, `app.findUuid` - and a project's file by in its
/// `.uid` file.
pub const Uuid = @import("fluxion_id").Uuid;

pub const assets = @import("assets.zig");
pub const components = @import("components.zig");
pub const color = @import("color.zig");
pub const schedule = @import("schedule.zig");

/// Where a thing really is, once its parent has had its say.
pub const hierarchy = @import("hierarchy.zig");

/// A world written down and read back, as JSON or as CBOR: `App.saveScene`
/// and `App.loadScene`.
pub const scene = @import("scene.zig");

/// Which body is which entity's: `RigidBody2D` and `Collider2D` kept in step
/// with `App.physics`.
pub const Bodies = @import("bodies.zig");

pub const render = struct {
    pub const sprite = @import("render/sprite.zig");
    /// What the camera sees, and where the pointer is in the world.
    pub const view = @import("render/view.zig");
};

/// Every glyph the game has drawn, in one texture.
pub const text = struct {
    pub const Atlas = @import("text/Atlas.zig");
};

/// Where a thing is, how big, and which way round.
pub const Transform2D = components.Transform2D;

/// A picture drawn at a transform.
pub const Sprite = components.Sprite;

/// Which part of a texture a sprite shows.
pub const Region = components.Region;

/// Words drawn at a transform.
pub const Text2D = components.Text2D;

/// What a `Text2D` is drawn in.
pub const FontHandle = assets.FontHandle;

/// A sprite that walks through the cells of its own texture.
pub const Animation = components.Animation;

/// What the 2D pass looks through.
pub const Camera2D = components.Camera2D;

/// Something that falls, is pushed and bounces.
pub const RigidBody2D = components.RigidBody2D;

/// The shape a body collides with, or a static body of its own.
pub const Collider2D = components.Collider2D;

/// A place that tells what is in it and pushes nothing: a trigger, a
/// pickup, a hurtbox. Godot's Area2D.
pub const Area2D = components.Area2D;

/// What the pointer did, as an `input_event` signal is handed it.
pub const pointer = @import("pointer.zig");

/// One thing the pointer did: `fx.pointer.InputEvent`.
pub const InputEvent = pointer.InputEvent;

/// A button of the pointer, the wheel among them. Godot's `MouseButton`.
pub const PointerButton = pointer.PointerButton;

/// Which pointer buttons are held: `app.input.buttonMask()`.
pub const ButtonMask = pointer.ButtonMask;

/// A picture of the game's own for the pointer: `App.setCursorImage`.
pub const CursorImage = platform.CursorImage;

/// One size of a window's own picture: `App.setWindowIcon`.
pub const IconImage = platform.IconImage;

/// How far in from each edge of the framebuffer the usable part starts:
/// `App.safeArea`.
pub const Insets = platform.Insets;

/// Two colliders that began or stopped touching: `App.contactsBegun`.
pub const Contact = Bodies.Contact;

/// What `App.castRay` hit.
pub const RayHit = Bodies.RayHit;

/// What a camera sees, as a point, a zoom, a turn and a size: what
/// `App.drawWorld` draws the world through.
pub const View = render.view.View;

/// How the window fills the screen.
pub const Fullscreen = Window.Fullscreen;

/// Where the pointer may go, and whether it shows.
pub const Cursor = Window.Cursor;

/// One of the system's own pointer shapes.
pub const CursorShape = platform.CursorShape;

/// Whether the window is at its own size, maximised, or minimised.
pub const WindowState = Window.State;

/// How small and how large the player may drag the window.
pub const WindowSizeLimits = Window.SizeLimits;

/// A controller button, named by position: `.a` is the bottom face button on
/// every pad.
pub const GamepadButton = platform.GamepadButton;

/// A stick's axis or a trigger on a controller.
pub const GamepadAxis = platform.GamepadAxis;

/// The keys, stick and d-pad that move one axis, as component data.
pub const AxisBinding = Input.AxisBinding;

/// Godot's Timer: a component that counts down and says `timeout`. See
/// `timer.zig`.
pub const Timer = @import("timer.zig").Timer;

/// A point or a direction in the plane.
pub const Vec2 = math.Vec2;

/// A colour, four floats from zero to one.
pub const Color = color.Color;

/// What a `Sprite` points at.
pub const TextureHandle = assets.TextureHandle;

/// Which part of the frame a system runs in.
pub const Stage = schedule.Stage;

/// What a system is.
pub const System = schedule.System;

/// The world and everything in it, so a game need not name the package.
pub const ecs = @import("fluxion_ecs");

/// The graphics device, for drawing what the engine has no component for.
pub const rhi = @import("fluxion_rhi");

/// Windows, input and the event loop.
pub const platform = @import("fluxion_platform");

/// Projections, matrices and vectors.
pub const math = @import("fluxion_math");

/// PNG reading and writing.
pub const image = @import("fluxion_image");

/// Lines, shapes and text for seeing what a game is doing: what `App.debug`
/// draws with.
pub const debugdraw = @import("fluxion_debugdraw");

/// The layout a `.ui` system declares with; `app.ui` is one.
pub const ui = @import("fluxion_ui");

/// JSON and CBOR, read and written: what a scene is kept in, and what a
/// game's own settings and saves can be.
pub const json = @import("fluxion_json");

/// Rigid bodies in the plane: what `App.physics` is, for joints, gravity and
/// anything else a body can do.
pub const physics = @import("fluxion_physics");

/// Types read and written at run time: what `App.componentOf` hands out, what
/// `App.types` holds, and what `App.callNamed` calls through.
pub const reflect = @import("fluxion_reflect");

/// What a component's field means, for an inspector to show it by: a range,
/// an angle, a unit, layers, several lines, a value behind a getter and a
/// setter. `reflect.attr`'s five and five more, in one namespace.
pub const attr = @import("attr.zig");

/// A physical key, by its position on a US layout.
pub const Key = platform.Key;

/// A mouse button.
pub const MouseButton = platform.MouseButton;

/// One entity: eight bytes with a generation in them.
pub const Entity = ecs.Entity;

/// Everything with a set of components, in slices.
pub const Query = ecs.Query;

test {
    _ = App;
    _ = Window;
    _ = Input;
    _ = Time;
    _ = Interface;
    _ = Clipboard;
    _ = Commands;
    _ = DebugViews;
    _ = States;
    _ = signals;
    _ = @import("areas.zig");
    _ = @import("picking.zig");
    _ = @import("pointer.zig");
    _ = events;
    _ = @import("signals_test.zig");
    _ = @import("areas_test.zig");
    _ = @import("picking_test.zig");
    _ = @import("timer.zig");
    _ = @import("script.zig");
    _ = @import("script_test.zig");
    _ = Project;
    _ = dialog;
    _ = attr;
    _ = assets;
    _ = components;
    _ = color;
    _ = schedule;
    _ = hierarchy;
    _ = scene;
    _ = Bodies;
    _ = render.sprite;
    _ = render.view;
    _ = text.Atlas;
}

test "every name this file exports is one that exists" {
    // Zig checks a declaration only when something uses it, so a re-export of
    // a renamed name would compile here and fail in the first game to use it.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(render);
    std.testing.refAllDecls(text);
}
