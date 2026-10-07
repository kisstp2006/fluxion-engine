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
//! A scene is a world and a node is an entity, with
//! [Fluxion ECS](https://github.com/kisstp2006/fluxion-ecs) in the middle.
//! Three layers - 3D, 2D, interface - are drawn back to front into one
//! target; the 2D layer and the interface are written, the 3D one is not. This
//! is the one package in the stack that may open a window.

const std = @import("std");

pub const App = @import("App.zig");
/// The engine's version: what a plugin's manifest is checked against.
pub const version = @import("engine_options").version;
/// Plugins: folders under `res://addons/` with a manifest. See
/// `project/plugins.zig`.
pub const plugins = @import("project/plugins.zig");
pub const Window = @import("platform/window.zig");
pub const Input = @import("input/input.zig");
pub const Time = @import("time/frame_time.zig");
pub const Assets = @import("assets/assets.zig");
pub const Interface = @import("ui/interface.zig");
pub const ToolWindow = @import("ui/tool_window.zig");
pub const WorldPlacement = @import("ui/interface.zig").WorldPlacement;
pub const Clipboard = @import("platform/clipboard.zig");

/// Spawns, despawns, adds and removes that wait for the system asking for
/// them to return: `app.commands`.
pub const Commands = @import("core/commands.zig");

/// What the engine draws into `app.debug` by itself - colliders, bodies,
/// transforms, sprites, cameras, stats - each off until asked for:
/// `app.debug_views`.
pub const DebugViews = @import("render/debug_views.zig");

/// A game's own states, each an enum with one value at a time: `app.state`,
/// `app.setState`, `app.addSystemIn`, `app.onEnter`.
pub const States = @import("core/states.zig");

/// Signals, on components: `pub const signals` on one, and `app.signal`,
/// `connect`, `emit`. The table is `app.signals`.
pub const signals = @import("core/signals.zig");

/// A signal of one entity. See `App.signal`.
pub const Signal = signals.Signal;

/// What a signal calls: a method by name, or a Zig function.
pub const Callable = signals.Callable;

/// How a connection is heard and kept: deferred, persist, one shot.
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
pub const events = @import("core/event_channels.zig");

/// The events of one type, last frame's and this frame's.
pub const Events = events.Events;

/// A place in the events of one type, reading each once.
pub const EventReader = events.Reader;

/// Flux scripts on entities: `app.useScripts`, `app.loadScript`, and a
/// `Script` on the entity.
pub const script = @import("script/script.zig");

/// A script on an entity: a `.flux` file, and which struct in it.
pub const Script = script.Script;

/// A `.flux` file loaded into the app's VM.
pub const ScriptHandle = script.ScriptHandle;

/// The scripting language itself, for what a game or a tool does beyond a
/// `Script`: calling into a script by name, or checking one in an editor
/// with `flux.service` and `app.scriptSetup()`.
pub const flux = script.flux;

/// Where a game's files are: `res://` paths from the project's root, files
/// known by the UUID in the `.uid` file beside them, and the player's own
/// under `user://`: `app.project`. `app.readText`, `app.writeText` and the
/// rest take any of them.
pub const Project = @import("project/Project.zig");
/// Settings a game keeps for itself, in sections of keys that need no
/// declaring: the player's volume, in `user://settings.cfg`.
pub const ConfigFile = @import("files/config_file.zig").ConfigFile;
/// A picture in memory, a pixel at a time: see `images`.
pub const Image = @import("assets/images.zig").Image;
/// A file of settings in sections, read and written from the struct that
/// describes it: what `project.fluxion` is, and what an editor keeps its own
/// settings with.
pub const settings_file = @import("project/settings_file.zig");

/// File and folder dialogs, the system's own: `app.openFileDialog`,
/// `app.openFolderDialog`, and the answer in `app.input.dialogAnswer`.
pub const dialog = @import("platform/dialog.zig");

/// A 128-bit name for a thing, unique everywhere: what an entity is known by
/// in a scene - `app.uuidOf`, `app.findUuid` - and a project's file by in its
/// `.uid` file.
pub const Uuid = @import("fluxion_id").Uuid;

pub const assets = @import("assets/assets.zig");
pub const components = @import("scene/components.zig");
pub const control = @import("ui/control.zig");
pub const color = @import("math/color.zig");
pub const schedule = @import("core/schedule.zig");

/// Where a thing really is, once its parent has had its say.
pub const hierarchy = @import("scene/hierarchy.zig");

/// A world written down and read back, as JSON or as CBOR: `App.saveScene`
/// and `App.loadScene`.
pub const scene = @import("scene/scene.zig");

/// Which body is which entity's: `RigidBody2D` and `Collider2D` kept in step
/// with `App.physics`.
pub const Bodies = @import("physics/bodies.zig");

pub const render = struct {
    pub const sprite = @import("render/sprite.zig");
    /// What the camera sees, and where the pointer is in the world.
    pub const view = @import("render/view.zig");
    /// A `.shader` file's fragment stage, with the engine's part after it.
    pub const material = @import("render/material.zig");
    /// The frame, drawn where it can be read.
    pub const screen = @import("render/screen.zig");
    /// The light buffer the world is lit by.
    pub const lighting = @import("render/lighting.zig");
    /// What draws the 3D world.
    pub const renderer3d = @import("render/renderer3d.zig");
    /// A `.shader3d` file: a mesh's surface, which the engine lights.
    pub const shader3d = @import("render/shader3d.zig");
    /// The 3D layer's light turned into a picture: glow, tone, smoothing.
    pub const post3d = @import("render/post3d.zig");
    /// Where every 3D shadow is drawn: the atlas, its tiles and views.
    pub const shadows3d = @import("render/shadows3d.zig");
    /// What a 3D camera sees, and where a pixel is in the 3D world.
    pub const view3d = @import("render/view3d.zig");
    /// Skeletons, their bones and poses.
    pub const skeleton = @import("render/skeleton.zig");
};

/// Every glyph the game has drawn, in one texture.
pub const text = struct {
    pub const Atlas = @import("render/GlyphAtlas.zig");
};

/// Where a thing is, how big, and which way round.
pub const Transform2D = components.Transform2D;
pub const Transform3D = components.Transform3D;
pub const Rotation = components.Rotation;
pub const Parent = components.Parent;

/// A picture drawn at a transform.
pub const Sprite = components.Sprite;

/// Which part of a texture a sprite shows.
pub const Region = components.Region;

/// Words drawn at a transform.
pub const Text2D = components.Text2D;

/// What a `Text2D` is drawn in.
pub const FontHandle = assets.FontHandle;

/// What the 2D pass looks through.
pub const Camera2D = components.Camera2D;

/// Meshes: what a `MeshInstance3D` draws, and the shapes made from numbers.
pub const mesh = @import("render/mesh.zig");
pub const Mesh = mesh.Mesh;
pub const MeshHandle = mesh.MeshHandle;
/// `.mat3d` files: a `Material3DData` kept as a file with its shader's
/// numbers, and a model's materials.
pub const materials = @import("render/materials.zig");
pub const MaterialHandle = materials.MaterialHandle;
/// `.lightmap` files: what a `LightmapGI` bakes. See `render/lightmaps.zig`,
/// and `render/lightmap_uv.zig` for the UVs it is laid out by.
pub const lightmaps = @import("render/lightmaps.zig");
pub const LightmapHandle = lightmaps.LightmapHandle;
/// A bake on its way: see `App.bakeLightmap`.
pub const LightmapBake = @import("render/lightmap_bake.zig").LightmapBake;
pub const lightmap_uv = @import("render/lightmap_uv.zig");
/// Models as scenes: glTF read by the engine, FBX and Blender files by way
/// of an editor. See `assets/models.zig` and `assets/gltf.zig`.
pub const models = @import("assets/models.zig");
pub const gltf = @import("assets/gltf.zig");
/// Files read on the loading threads: see `App.loadInBackground`.
pub const background_load = @import("assets/background_load.zig");
/// The 3D layer's components: see `render/render3d_components.zig`.
pub const MeshInstance3D = components.MeshInstance3D;
pub const PrimitiveMesh3D = components.PrimitiveMesh3D;
pub const Material3D = components.Material3D;
pub const Material3DData = components.Material3DData;
pub const Camera3D = components.Camera3D;
pub const DirectionalLight3D = components.DirectionalLight3D;
pub const PointLight3D = components.PointLight3D;
pub const SpotLight3D = components.SpotLight3D;
pub const Environment = components.Environment;
pub const LightmapGI = components.LightmapGI;
/// Skeletons and the meshes they bend: see `render/skeleton.zig`.
pub const Skeleton3D = components.Skeleton3D;
pub const BoneAttachment3D = components.BoneAttachment3D;
pub const skeleton = render.skeleton;
/// What a 3D camera sees: what `App.drawWorld3D` draws the world through.
pub const View3D = render.view3d.View3D;

/// Something that falls, is pushed and bounces.
pub const RigidBody2D = components.RigidBody2D;

/// The shape a body collides with, or a static body of its own.
pub const Collider2D = components.Collider2D;

/// A place that tells what is in it and pushes nothing: a trigger, a
/// pickup, a hurtbox.
pub const Area2D = components.Area2D;
pub const RayCast2D = components.RayCast2D;
pub const Drawing2D = @import("render/drawing.zig").Drawing2D;
pub const drawing = @import("render/drawing.zig");

/// Sparks, smoke, rain: many small pictures an entity lets go of.
pub const Particles2D = particles.Particles2D;
pub const particles = @import("render/particles.zig");

/// Light in the 2D world, and the shadows it casts: see `lights.zig`.
pub const lights = @import("render/lights.zig");
pub const PointLight2D = lights.PointLight2D;
pub const DirectionalLight2D = lights.DirectionalLight2D;
pub const AmbientLight2D = lights.AmbientLight2D;
pub const LightOccluder2D = lights.LightOccluder2D;

/// A grid of tiles from a `TileSet`. Its cells live in `TileChunk`s the
/// map owns; `App.setTile` paints one.
pub const TileMap = @import("tiles/tilemap.zig").TileMap;
pub const TileChunk = @import("tiles/tilemap.zig").TileChunk;
/// One tile of a map: which tile of which source, and how it is turned.
pub const Cell = @import("tiles/tilemap.zig").Cell;
pub const tile_chunk_side = @import("tiles/tilemap.zig").chunk_side;

pub const tileset = @import("tiles/tileset.zig");
/// What a map's cells name their tiles in: a `.tileset` file.
pub const TileSet = tileset.TileSet;
pub const TileSetHandle = tileset.TileSetHandle;

pub const theme = @import("ui/theme.zig");
/// What a `Control` is drawn from: a `.theme` file.
pub const Theme = theme.Theme;
pub const ThemeHandle = theme.ThemeHandle;

pub const Control = control.Control;
pub const CanvasLayer = control.CanvasLayer;
pub const Viewport = control.Viewport;
pub const BoxContainer = control.BoxContainer;
pub const MarginContainer = control.MarginContainer;
pub const CenterContainer = control.CenterContainer;
pub const ScrollContainer = control.ScrollContainer;
pub const PanelContainer = control.PanelContainer;
pub const Label = control.Label;
pub const Button = control.Button;
pub const CheckBox = control.CheckBox;
pub const ThemeOverride = control.ThemeOverride;
pub const LineEdit = control.LineEdit;
pub const Slider = control.Slider;
pub const ProgressBar = control.ProgressBar;
pub const ColorRect = control.ColorRect;
pub const Focus = control.Focus;
pub const MouseCursor = control.MouseCursor;
pub const RichText = control.RichText;
pub const Popup = control.Popup;
pub const StyleBox = control.StyleBox;
pub const TabContainer = control.TabContainer;
pub const TextureRect = control.TextureRect;
pub const NinePatchRect = control.NinePatchRect;

/// One thing the player did, of its own kind: what a script's `input` is
/// handed, and a pointer's `input_event` signal. See `input_event.zig`.
pub const input_event = @import("input/input_event.zig");
pub const InputEvent = input_event.InputEvent;
pub const KeyEvent = input_event.KeyEvent;
pub const MouseButtonEvent = input_event.MouseButtonEvent;
pub const MouseMotionEvent = input_event.MouseMotionEvent;
pub const WheelEvent = input_event.WheelEvent;
pub const TouchEvent = input_event.TouchEvent;
pub const TouchMotionEvent = input_event.TouchMotionEvent;
pub const TapEvent = input_event.TapEvent;
pub const LongPressEvent = input_event.LongPressEvent;
pub const SwipeEvent = input_event.SwipeEvent;
pub const PinchEvent = input_event.PinchEvent;
pub const PanEvent = input_event.PanEvent;
pub const RotateEvent = input_event.RotateEvent;
pub const PadButtonEvent = input_event.PadButtonEvent;

/// One finger on a touch screen, as a frame has it: `app.input.touches()`.
pub const Touch = @import("input/input.zig").Touch;
/// What two fingers did this frame: `app.twoFingers()`.
pub const TwoFingers = @import("input/input.zig").TwoFingers;
/// A control fingers press, as many at once as there are fingers. See
/// `touch_button.zig`.
pub const TouchButton = @import("ui/touch_button.zig").TouchButton;

/// Which mouse buttons are held: `app.input.buttonMask()`.
pub const ButtonMask = input_event.ButtonMask;

/// A picture of the game's own for the pointer: `App.setCustomCursorPixels`.
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
/// Bodies the game moves: see `App.moveAndSlide`.
pub const character = @import("physics/character.zig");
pub const CharacterBody2D = components.CharacterBody2D;
pub const Collision = character.Collision;

/// What a camera sees, as a point, a zoom, a turn and a size: what
/// `App.drawWorld` draws the world through.
pub const View = render.view.View;

/// How the window is on the screen: windowed, minimised, maximised,
/// fullscreen or exclusively so.
pub const WindowMode = Window.Mode;
/// How frames are shown against the display's refresh.
pub const VsyncMode = Window.VsyncMode;
/// Where the window opens.
pub const InitialPosition = App.InitialPosition;

/// Where the pointer may go, and whether it shows.
pub const Cursor = Window.Cursor;

/// One of the system's own pointer shapes.
pub const CursorShape = platform.CursorShape;

/// How small and how large the player may drag the window.
pub const WindowSizeLimits = Window.SizeLimits;

/// A controller button, named by position: `.a` is the bottom face button on
/// every pad.
pub const GamepadButton = platform.GamepadButton;

/// A stick's axis or a trigger on a controller.
pub const GamepadAxis = platform.GamepadAxis;

/// The keys, stick and d-pad that move one axis, as component data.
pub const AxisBinding = Input.AxisBinding;

/// A game's actions - `jump`, `ui_accept` - and the keys, buttons and
/// sticks that set them off: named in the project, asked for with
/// `app.input.actionDown`, and rebound as the game runs. See `actions.zig`.
pub const actions = @import("input/actions.zig");
pub const Action = actions.Action;
pub const Binding = actions.Binding;

/// A component that counts down and says `timeout`. See `timer.zig`.
pub const Timer = @import("time/timer.zig").Timer;
/// Sound: clips, the players that play them, and the project's buses. See
/// `audio.zig`.
pub const audio = @import("audio/audio.zig");
/// A property of an entity named by text - `Appearance.modulate.a` - which
/// tweens and animations move. See `property.zig`.
pub const property = @import("reflect/property.zig");
pub const Property = property.Property;
pub const Tween = @import("animation/tween.zig").Tween;
/// Animation libraries - `.anim` - and the players that play them. See
/// `animation.zig`.
pub const animation = @import("animation/animation.zig");
pub const AnimationPlayer = animation.AnimationPlayer;
pub const AnimationLibraryHandle = animation.AnimationLibraryHandle;
/// Animations of pictures - `.frames` - and the sprites that play them. See
/// `sprite_frames.zig`.
pub const sprite_frames = @import("animation/sprite_frames.zig");
pub const AnimatedSprite2D = sprite_frames.AnimatedSprite2D;
pub const SpriteFrames = sprite_frames.SpriteFrames;
pub const SpriteFramesHandle = sprite_frames.SpriteFramesHandle;
pub const AudioPlayer = audio.AudioPlayer;
pub const AudioSpatial2D = audio.AudioSpatial2D;
pub const AudioListener2D = audio.AudioListener2D;
pub const AudioClipHandle = audio.AudioClipHandle;
pub const scenes = @import("assets/scene_table.zig");
pub const SceneHandle = scenes.SceneHandle;
pub const data = @import("assets/data_files.zig");
/// Dates and times: a moment, a span, and a calendar's fields in a time zone,
/// written as the person's culture writes them. See `datetime.zig`.
pub const datetime = @import("time/datetime.zig");
pub const Instant = datetime.Instant;
pub const Duration = datetime.Duration;
pub const DateTime = datetime.DateTime;
pub const Zone = datetime.Zone;
/// A game's own clocks: a date and time at a rate of its own. See
/// `game_clocks.zig` and `App.newClock`.
pub const clocks = @import("time/game_clocks.zig");
pub const ClockHandle = clocks.ClockHandle;
pub const DataHandle = data.DataHandle;
pub const background = @import("assets/background_load.zig");
pub const inherited = @import("scene/inherited.zig");
pub const Processing = inherited.Processing;
pub const Appearance = inherited.Appearance;

/// A point or a direction in the plane.
pub const Vec2 = math.Vec2;

/// A colour, four floats from zero to one.
pub const Color = color.Color;

/// Whole-number points, and boxes of either kind.
pub const geometry = @import("math/geometry.zig");
pub const Vec2i = geometry.Vec2i;
pub const Rect2 = geometry.Rect2;
pub const Rect2i = geometry.Rect2i;

/// The kinds of file a game is made of, and the handle each is held by.
pub const AssetKind = @import("assets/asset_kind.zig").AssetKind;

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

/// Packs: the files of a shipped game in one, sealed and signed if it asks,
/// which `App.Options.pack` reads `res://` out of.
pub const vfs = @import("fluxion_vfs");

/// Where a shipped game's program finds its pack, and keeps the pack's key:
/// what the runtime reads and the export writes.
pub const shipped = @import("files/pack_locator.zig");

/// Web requests: the client `App.webSend` asks through, for a tool of its
/// own. See `net/web.zig`.
pub const net = @import("fluxion_net");

/// Rigid bodies in the plane: what `App.physics` is, for joints, gravity and
/// anything else a body can do.
pub const physics = @import("fluxion_physics");

/// Types read and written at run time: what `App.componentOf` hands out, what
/// `App.types` holds, and what `App.callNamed` calls through.
pub const reflect = @import("fluxion_reflect");

/// What a component's field means, for an inspector to show it by: a range,
/// an angle, a unit, layers, several lines, a value behind a getter and a
/// setter. `reflect.attr`'s five and five more, in one namespace.
pub const attr = @import("reflect/attr.zig");
/// The words components keep beside them: see `App.textOf`.
pub const texts = @import("scene/component_texts.zig");
/// Shaders from `.shader` files, and what a `Material` gives one: see
/// `App.loadShader`.
pub const shaders = @import("render/shaders.zig");
pub const Material = shaders.Material;
/// The picture each `RenderView` draws: see `App.viewTexture`.
pub const views = @import("render/view_textures.zig");
pub const RenderView = components.RenderView;
pub const ViewTexture = components.ViewTexture;
/// A game made at one size, shown in a window of any: see `App.frame`.
pub const stretch = @import("render/stretch.zig");
pub const ShaderHandle = shaders.ShaderHandle;

/// A physical key, by its position on a US layout.
pub const Key = platform.Key;

/// A mouse button.
pub const MouseButton = platform.MouseButton;

/// One entity: eight bytes with a generation in them.
pub const Entity = ecs.Entity;

/// Everything with a set of components, in slices.
pub const Query = ecs.Query;

// Every test the engine has: its test files, which run whole apps headless,
// and every source file, for the tests of its own each keeps beside its code.
test {
    _ = @import("animation/animation_test.zig");
    _ = @import("animation/sprite_frames_test.zig");
    _ = @import("animation/tween_test.zig");
    _ = @import("app_test.zig");
    _ = @import("assets/images_test.zig");
    _ = @import("audio/audio_test.zig");
    _ = @import("core/signals_test.zig");
    _ = @import("core/states_test.zig");
    _ = @import("files/files_test.zig");
    _ = @import("files/pack_test.zig");
    _ = @import("input/input_test.zig");
    _ = @import("net/web_test.zig");
    _ = @import("project/plugins_test.zig");
    _ = @import("physics/areas_test.zig");
    _ = @import("physics/bodies_test.zig");
    _ = @import("physics/character_test.zig");
    _ = @import("physics/picking_test.zig");
    _ = @import("platform/window_test.zig");
    _ = @import("reflect/reflect_test.zig");
    _ = @import("render/camera_test.zig");
    _ = @import("render/label_layout_test.zig");
    _ = @import("render/particles_test.zig");
    _ = @import("render/render_test.zig");
    _ = @import("render/render3d_test.zig");
    _ = @import("render/mesh.zig");
    _ = @import("render/lightmap_uv.zig");
    _ = @import("render/lightmaps.zig");
    _ = @import("render/skeleton.zig");
    _ = @import("render/lightmap_test.zig");
    _ = @import("render/view3d.zig");
    _ = @import("render/renderer3d.zig");
    _ = @import("render/shader3d.zig");
    _ = @import("render/post3d.zig");
    _ = @import("render/materials.zig");
    _ = @import("assets/gltf.zig");
    _ = @import("assets/models.zig");
    _ = @import("assets/models_test.zig");
    _ = @import("scene/hierarchy_test.zig");
    _ = @import("scene/inherited_test.zig");
    _ = @import("scene/instance_test.zig");
    _ = @import("scene/names_test.zig");
    _ = @import("scene/scene_test.zig");
    _ = @import("script/script_test.zig");
    _ = @import("tiles/tilemap_test.zig");
    _ = @import("time/frame_time_test.zig");
    _ = @import("time/timer_test.zig");
    _ = @import("ui/control_test.zig");
    _ = @import("ui/ui_test.zig");

    _ = @import("App.zig");
    _ = @import("animation/animation.zig");
    _ = @import("assets/asset_kind.zig");
    _ = @import("assets/assets.zig");
    _ = @import("assets/data_files.zig");
    _ = @import("assets/file_table.zig");
    _ = @import("assets/images.zig");
    _ = @import("audio/audio.zig");
    _ = @import("core/commands.zig");
    _ = @import("core/event_channels.zig");
    _ = @import("core/schedule.zig");
    _ = @import("core/signals.zig");
    _ = @import("files/config_file.zig");
    _ = @import("files/pack_locator.zig");
    _ = @import("files/sealed.zig");
    _ = @import("input/actions.zig");
    _ = @import("input/input_event.zig");
    _ = @import("math/color.zig");
    _ = @import("math/geometry.zig");
    _ = @import("platform/clipboard.zig");
    _ = @import("project/Project.zig");
    _ = @import("project/settings.zig");
    _ = @import("project/plugins.zig");
    _ = @import("project/settings_file.zig");
    _ = @import("reflect/fixed_text.zig");
    _ = @import("reflect/property.zig");
    _ = @import("render/GlyphAtlas.zig");
    _ = @import("render/debug_views.zig");
    _ = @import("render/drawing.zig");
    _ = @import("render/lighting.zig");
    _ = @import("render/lights.zig");
    _ = @import("render/material.zig");
    _ = @import("render/render_components.zig");
    _ = @import("render/screen.zig");
    _ = @import("render/shader_edit.zig");
    _ = @import("render/shaders.zig");
    _ = @import("render/sprite.zig");
    _ = @import("render/stretch.zig");
    _ = @import("render/view.zig");
    _ = @import("scene/component_texts.zig");
    _ = @import("scene/components.zig");
    _ = @import("scene/hierarchy.zig");
    _ = @import("scene/inherited.zig");
    _ = @import("script/script.zig");
    _ = @import("script/script_exports.zig");
    _ = @import("tiles/tilemap.zig");
    _ = @import("tiles/tileset.zig");
    _ = @import("time/datetime.zig");
    _ = @import("time/frame_time.zig");
    _ = @import("time/game_clocks.zig");
    _ = @import("ui/interface.zig");
    _ = @import("ui/theme.zig");
    _ = @import("ui/touch_button.zig");
}

test "every name this file exports is one that exists" {
    // Zig checks a declaration only when something uses it, so a re-export of
    // a renamed name would compile here and fail in the first game to use it.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(render);
    std.testing.refAllDecls(text);
}
