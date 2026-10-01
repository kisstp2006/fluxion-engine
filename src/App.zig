// SPDX-License-Identifier: BSD-3-Clause

//! The engine: a window, a device, a world, and the loop between them.
//!
//! ```zig
//! pub fn main(init: std.process.Init) !void {
//!     const app = try App.create(init.gpa, .{ .title = "game", .io = init.io });
//!     defer app.destroy();
//!
//!     try app.addSystem(.startup, "spawn world", spawnWorld);
//!     try app.addSystem(.fixed, "move paddles", movePaddles);
//!     try app.run();
//! }
//! ```
//!
//! Created on the heap, because the device, the renderer and the platform
//! window hold pointers into this struct, and what is pointed at must not
//! move. The stages of the frame are in `schedule`. With `.headless` it runs
//! with no window and no GPU, which is how every test here runs.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const rhi = @import("fluxion_rhi");
const math = @import("fluxion_math");
const platform = @import("fluxion_platform");
const debugdraw = @import("fluxion_debugdraw");
const debugdraw_rhi = @import("fluxion_debugdraw_rhi");
const fluxion_ui = @import("fluxion_ui");
const fluxion_physics = @import("fluxion_physics");
const json = @import("fluxion_json");
const reflect = @import("fluxion_reflect");
const Uuid = @import("fluxion_id").Uuid;

// What an app is made with, and the parts of it that are its own.
const display = @import("app/display.zig");
const frame_steps = @import("app/frame_steps.zig");

// core
const Commands = @import("core/commands.zig");
const States = @import("core/states.zig");
const Schedule = @import("core/schedule.zig").Schedule;
const Stage = @import("core/schedule.zig").Stage;
const System = @import("core/schedule.zig").System;
const Condition = @import("core/schedule.zig").Condition;
const Hook = @import("core/schedule.zig").Hook;
const Signals = @import("core/signals.zig").Signals;
const SignalError = @import("core/signals.zig").Error;
const SignalInfo = @import("core/signals.zig").Info;
const Connection = @import("core/signals.zig").Connection;
const ConnectOptions = @import("core/signals.zig").Options;
const Callable = @import("core/signals.zig").Callable;
const MethodInfo = @import("core/signals.zig").MethodInfo;
const signals_by_name = @import("core/signals_by_name.zig");
const typed_events = @import("core/event_channels.zig");

// reflect
const attr = @import("reflect/attr.zig");
const calls = @import("reflect/calls.zig");
const PropertyValue = @import("reflect/property.zig").Value;

// scene
const components = @import("scene/components.zig");
const hierarchy = @import("scene/hierarchy.zig");
const scene = @import("scene/scene.zig");
const registry = @import("scene/registry.zig");
const Names = @import("scene/names.zig").Names;
const Uuids = @import("scene/uuids.zig").Uuids;
const scene_tree = @import("scene/tree.zig");
const scene_groups = @import("scene/groups.zig");
const Groups = scene_groups.Groups;
const scene_instances = @import("scene/instances.zig");
const playing = @import("scene/current_scene.zig");
const component_texts = @import("scene/component_texts.zig");
const Appearance = @import("scene/inherited.zig").Appearance;
const Processing = @import("scene/inherited.zig").Processing;
const Inherited = @import("scene/inherited.zig").Inherited;
const ResolvedAppearance = @import("scene/inherited.zig").Resolved;

// time
const Time = @import("time/frame_time.zig");
const timer = @import("time/timer.zig");
const game_clocks = @import("time/game_clocks.zig");
const datetime = @import("time/datetime.zig");

// input
const Input = @import("input/input.zig");
const InputEvent = @import("input/input_event.zig").InputEvent;

// physics
const Bodies = @import("physics/bodies.zig");
const Areas = @import("physics/areas.zig");
const Picking = @import("physics/picking.zig");
const character = @import("physics/character.zig");
const ray_casts = @import("physics/ray_casts.zig");
const forces = @import("physics/forces.zig");

// audio
const sound = @import("audio/audio.zig");

// animation
const tweening = @import("animation/tween.zig");
const animation = @import("animation/animation.zig");
const sprite_animation = @import("animation/sprite_frames.zig");

// render
const sprite = @import("render/sprite.zig");
const layers = @import("render/layers.zig");
const cameras = @import("render/cameras.zig");
const drawn_corners = @import("render/drawn_corners.zig");
const drawing = @import("render/drawing.zig");
const particle_emitters = @import("render/particles.zig");
const lights = @import("render/lights.zig");
const shading = @import("render/shaders.zig");
const view_textures = @import("render/view_textures.zig");
const stretching = @import("render/stretch.zig");
const DebugViews = @import("render/debug_views.zig");
const View = @import("render/view.zig").View;
const Screen = @import("render/screen.zig").Screen;

// tiles
const tilemap = @import("tiles/tilemap.zig");
const tileset = @import("tiles/tileset.zig");
const tiles = @import("tiles/tile_chunks.zig");

// ui
const control = @import("ui/control.zig");
const ControlTree = @import("ui/control_tree.zig").ControlTree;
const controlFocusId = @import("ui/control_tree.zig").focusIdOf;
const controlRectOf = @import("ui/control_tree.zig").rectOf;
const Interface = @import("ui/interface.zig");
const theme = @import("ui/theme.zig");
const ToolWindow = @import("ui/tool_window.zig");
const touch_buttons = @import("ui/touch_button.zig");

// script
const script = @import("script/script.zig");
const flux = script.flux;
const Exports = @import("script/script_exports.zig").Exports;

// assets
const Assets = @import("assets/assets.zig");
const AssetKind = @import("assets/asset_kind.zig").AssetKind;
const SceneHandle = @import("assets/scene_table.zig").SceneHandle;
const Scenes = @import("assets/scene_table.zig").Scenes;
const data_file = @import("assets/data_files.zig");
const background_load = @import("assets/background_load.zig");
const images = @import("assets/images.zig");
const Image = images.Image;

// project
const Project = @import("project/Project.zig");
const project_start = @import("project/project_start.zig");

// files
const sealed = @import("files/sealed.zig");
const game_files = @import("files/game_files.zig");
const project_files = @import("files/project_files.zig");

// platform
const Window = @import("platform/window.zig");
const Clipboard = @import("platform/clipboard.zig");
const dialog = @import("platform/dialog.zig");
const pointer = @import("platform/cursors.zig");
const window_icon = @import("platform/window_icon.zig");

// math
const geometry = @import("math/geometry.zig");
const Color = @import("math/color.zig").Color;

const App = @This();
const log = std.log.scoped(.fluxion_engine);

const fps_while_minimized = 10;

pub const Error = error{
    /// A window was wanted and this machine has no display. See
    /// `Window.isAbsent`.
    NoDisplay,
} || Allocator.Error || rhi.Error || Window.Error || Assets.Error ||
    sprite.Error || ecs.Jobs.Error || debugdraw_rhi.Error || Project.InitError ||
    Project.ReadError || Project.PackError || BackendError;

/// What an `App` is made with: see `app/options.zig`.
pub const Options = @import("app/options.zig").Options;
pub const Backend = @import("app/options.zig").Backend;
pub const BackendError = @import("app/options.zig").BackendError;
pub const backendsToTry = @import("app/options.zig").backendsToTry;
pub const InitialPosition = @import("app/options.zig").InitialPosition;
const Resolved = @import("app/options.zig").Resolved;

/// The command line: see `app/flags.zig`.
pub const Flags = @import("app/flags.zig").Flags;
pub const FlagError = @import("app/flags.zig").FlagError;
pub const parseFlags = @import("app/flags.zig").parse;

// The app itself.
gpa: Allocator,
io: ?std.Io,
/// Cleared by `quit`, and by the frame counter running out.
running: bool = true,
/// Whether `startup` has run.
started: bool = false,
/// The frames left before the run ends: `Options.frames`, counted down.
/// Null runs until something else stops it.
frames_left: ?u32,

// The world, its systems, and what they say to each other: `core/`.
/// Everything in the game.
world: ecs.World,
/// Spawns, despawns, adds and removes that wait for the system asking for
/// them to return, so a query can ask. See `core/commands.zig`.
commands: Commands,
/// What a parallel query runs on. See `ecs.Query.each`.
jobs: ecs.Jobs,
/// The systems, stage by stage, and the hooks states run: see
/// `core/schedule.zig`.
schedule: Schedule = .empty,
/// The game's own states: menu, playing, paused. See `core/states.zig`.
states: States = .{},
/// What `addSystemsIn` is adding under, while it runs.
gate: ?Condition = null,
/// Every signal's connections, the calls waiting for their sync point, and
/// `dispatch`, the switch that makes none. See `signal`.
signals: Signals,
/// Every type of event sent, by type. See `send` and `events`.
event_channels: typed_events.Channels = .{},
/// Every type described at run time, by name: the components, the values in
/// them, and `DebugViews`. A game's components join when they are
/// registered, and its own functions with `types.addFunction`, for a console
/// to find. See `componentOf`.
///
/// `App` is not in it until something adds it - `app.types.add(App)` - since
/// its descriptor lists calls, and listing a call compiles it, and what it
/// reaches, into the program: the scene reader and writer among them, 60 KB
/// and more of a small game that never asked for them.
types: reflect.Registry,

// What is kept of each entity beside the world: `scene/`.
/// What a scene can hold, and what each component is called in one: the
/// engine's own from the start, and a game's once `registerComponents` has
/// been told about them.
scene_components: scene.Registry = .{},
/// The components scenes held that nothing here is registered as, each kept
/// with its entity and written back with it. See `unknownComponentsOf`.
unknown_components: scene.Unknown = .{},
/// What every named entity is called. See `scene/names.zig`.
names: Names = .{},
/// Every entity's UUID, and what new ones are drawn from. See
/// `scene/uuids.zig`.
uuids: Uuids,
/// Each parent's children in their order, and the roots. See
/// `scene/tree.zig`.
tree: scene_tree.Tree = .{},
/// The groups entities are in. See `scene/groups.zig`.
groups: Groups = .{},
/// Whether the game is paused. See `setPaused`.
paused: bool = false,
/// What each entity inherits - `Processing` and `Appearance` - worked out
/// as it is asked for. See `scene/inherited.zig`.
inherited: Inherited = .{},
/// Where each interpolating transform was before the last fixed step: the
/// engine's own bookkeeping, beside the world. See `Transform2D.interpolate`.
snapshots: hierarchy.Snapshots = .empty,
/// Every instance of a scene in the world, by its root. See
/// `scene/instances.zig`.
instances: scene_instances.Instances = .{},
/// The scene the game is playing. See `scene/current_scene.zig`.
current_scene: playing.CurrentScene = .{},
/// The words components keep beside them: see `scene/component_texts.zig` and `textOf`.
texts: component_texts.Texts = .{},

// Time: `time/`.
/// This frame's time, and the fixed step's: see `time/frame_time.zig`.
time: Time,
/// The game's own clocks: see `time/game_clocks.zig` and `newClock`.
clocks: game_clocks.Clocks = .{},
/// The culture dates and times are written in, once asked for: see
/// `culture`.
culture_choice: datetime.CultureChoice = .{},

// Input: `input/`.
/// What the keys, the pointer, the fingers and the controllers did this
/// frame, and the project's actions: see `input/input.zig`.
input: Input = .{},
/// `describeAction`'s words, for the call that asked.
described: [64]u8 = undefined,
/// What `connectedPads` hands out.
connected_pads: [Input.max_pads]u8 = undefined,

// Physics: `physics/`.
/// Rigid bodies, stepped after each `.fixed` stage. The engine makes one for
/// every `RigidBody2D`; gravity, joints and the rest are here.
physics: fluxion_physics.World,
/// How the 2D world moves: the project file's `physics_2d`, or
/// `Options.physics_2d` with none. Its gravity is put into `physics` as the
/// app starts; a body reads its damping from here when it is synced.
physics_2d: Project.Physics2D,
/// Which body is which entity's. See `physics/bodies.zig`.
bodies: Bodies = .{},
/// What is inside each `Area2D`, and the signals that say so. See
/// `physics/areas.zig`.
areas: Areas = .{},
/// What the pointer is over, and what it did there. See `physics/picking.zig`.
picking: Picking = .{},
/// Whether the pointer picks what it is over at all. An editor turns it off
/// while it edits a scene rather than plays it.
physics_object_picking: bool = true,
/// Whether what is picked comes in the order it is drawn, the topmost
/// first. Off, the order is the broadphase's.
physics_object_picking_sort: bool = true,
/// Whether only the first of several under the pointer hears the event.
physics_object_picking_first_only: bool = false,
/// What each character's last `moveAndSlide` met. See `physics/character.zig`.
slide_collisions: character.Slides = .{},

// Sound: `audio/`.
/// The sound device, the clips read, the project's buses and what the
/// players play: see `audio/audio.zig` and `loadAudio`.
audio: sound.Audio,

// Animation: `animation/`.
/// Each tween's steps: see `animation/tween.zig` and `tween`.
tweens: tweening.Tweens = .{},
/// Every `.anim` file read: see `animation/animation.zig` and `loadAnimations`.
animation_libraries: animation.Libraries = .{},
/// What each `AnimationPlayer`'s tracks are bound to.
animation_players: animation.Players = .{},
/// Every `.frames` file read: see `animation/sprite_frames.zig` and `loadSpriteFrames`.
sprite_frames: sprite_animation.AllFrames = .{},

// Drawing: `render/`.
/// What everything is drawn with: the drawing API the backend opened.
device: rhi.Device,
/// What the frame is drawn into: a swapchain image, or a texture when there
/// is no window.
surface: ?rhi.Surface = null,
offscreen: ?rhi.Texture = null,
/// What draws the 2D world - sprites, text, tiles, lights and the rest:
/// see `render/sprite.zig`.
sprites: sprite.Renderer,
/// Where a frame something reads is drawn, and copied for what reads it.
/// See `render/screen.zig`.
screen: Screen,
/// Every `.shader` file read, compiled for the 2D layer: see `render/shaders.zig`
/// and `loadShader`.
shaders: shading.Shaders = .{},
/// The numbers each `Material` gives its shader: see `setShaderParam`.
shader_params: shading.Params = .{},
/// The picture each `RenderView` draws: see `render/view_textures.zig` and `viewTexture`.
views: view_textures.Views = .{},
/// What each `Drawing2D` has drawn: see `render/drawing.zig`.
drawings: drawing.Drawings = .{},
/// Each `Particles2D`'s particles: see `render/particles.zig`.
particles: particle_emitters.Particles = .{},
/// What the frame is cleared to.
background: Color,
/// Whether the frame draws the world under the interface. An editor turns it
/// off and shows the world in a panel of its own, through `drawWorld`; the
/// frame is then the background and the interface.
world_on_screen: bool = true,
/// The size of the target, in pixels. Kept here, because a headless app has
/// no window to ask.
width: u32,
height: u32,
/// True for the one frame in which `width` and `height` changed. Set before
/// any system runs, so every stage of that frame sees it.
resized: bool = false,
/// How the frame fits the window, and the size the game was made at. See
/// `render/stretch.zig`.
stretch: stretching.Stretch = .{},
/// What this frame is laid out and drawn at, and where on the window it is
/// shown: the window itself unless the project stretches its game.
frame: stretching.Frame = .window(1, 1),
/// How frames are shown against the refresh, as last asked: kept for a
/// headless app too, which has no display to wait for.
vsync_mode_now: VsyncMode = .enabled,
/// Lines, shapes and text drawn over everything, for one frame unless its
/// style says for how many seconds. Inside `.fixed` they last until the next
/// step instead, so a step's shapes are there in the frames between steps.
debug: debugdraw.Pen,
debug_frame: debugdraw.Canvas,
debug_steps: debugdraw.Canvas,
debug_renderer: debugdraw_rhi.Renderer,
/// The same as `debug`, drawn under the world rather than over it: after
/// the frame is cleared to `background` and before the sprites, so the
/// world is drawn over what it holds. An editor's grid, a level's guide
/// lines. Inside `.fixed` it lasts until the next step, as `debug` does.
debug_under: debugdraw.Pen,
debug_under_frame: debugdraw.Canvas,
debug_under_steps: debugdraw.Canvas,
/// What the last frame drew of `debug_under`; `debug_renderer.stats` is
/// what it drew over the world.
debug_under_stats: debugdraw_rhi.Stats = .{},
/// Whether anything `debug` holds is drawn - a game's own shapes and the
/// views below. `Options.debug_key` flips it.
debug_visible: bool = true,
/// What the engine draws into `debug` by itself, each off until asked for.
/// See `render/debug_views.zig`.
debug_views: DebugViews = .{},

// Tiles: `tiles/`.
/// Every `.tileset` file read, and the handles a `TileMap` points at one
/// with. See `loadTileSet`.
tile_sets: tileset.TileSets = .{},
/// Which entity holds each chunk of each map. See `tiles/tile_chunks.zig`.
tile_chunks: tiles.TileChunks = .{},

// The interface: `ui/`.
/// What `.ui` systems declare the interface into.
ui: fluxion_ui.Ui,
/// The scene's `Control` trees, laid out into `ui`: see `ui/control_tree.zig`.
control_tree: ControlTree = .{},
/// How the interface is fed and drawn: its font, scale and safe area.
interface: Interface = .{},
/// Every `.theme` file read, and the handles a `Control` points at one with.
/// See `loadTheme`.
themes: theme.Themes = .{},
/// The program's other windows, each with an interface of its own: see
/// `openToolWindow`.
tool_windows: std.ArrayList(*ToolWindow) = .empty,
/// The actions the touch buttons held last frame. See `ui/touch_button.zig`.
touch_actions: std.ArrayList(touch_buttons.ActionName) = .empty,

// Scripts: `script/`.
/// Flux scripts: the VM, the files, and every entity's instance, once
/// `useScripts` has made them. See `script`.
scripts: ?*script.Scripts = null,
/// What each entity's script's `@export`s are given in place of their
/// defaults. See `script/script_exports.zig`.
exports: Exports = .{},

// Files of every kind: `assets/`.
/// Every texture and font read, and their copies on the GPU: see
/// `assets/assets.zig`.
assets: Assets,
/// Every scene read as a file to make things of: see `loadScene`.
scenes: Scenes = .{},
/// Every data file read: see `loadData`.
data_files: data_file.DataFiles = .{},
/// Files reading in the background: see `loadInBackground`.
loads: background_load.Loads = .{},

// The project: `project/`.
/// Where the game's files are - `res://` - and the UUIDs of the ones that
/// have them. See `Project`.
project: Project,
/// Whether `startup` opens what the project says a game opens with: see
/// `Options.open_project`.
open_project: bool = false,

// A game's files: `files/`.
/// How hard `writeSecret`'s password is made to guess. See `sealed.Cost`.
secret_cost: sealed.Cost = .default,
/// Where `moveToTrash` puts things instead of the system's trash, when set:
/// a folder, in the freedesktop.org layout a file manager restores from. For
/// a test, which must not fill a person's own trash. Borrowed.
trash: ?[]const u8 = null,

// The window and the system: `platform/`.
/// The game's window: null when headless.
window: ?Window = null,
/// The system's clipboard, or the program's own without a window. See
/// `setClipboardText`.
clipboard: Clipboard = .{},
/// The pointer's pictures and shape. See `platform/cursors.zig`.
cursors: pointer.Cursors = .{},
/// The id the next headless dialog gets. See `openFileDialog`.
next_dialog: u32 = 1,
/// The engine's own shortcuts, from `Options`. Null is off.
quit_key: ?platform.Key = null,
fullscreen_key: ?platform.Key = null,
debug_key: ?platform.Key = null,
/// The frame the window's close button was last pressed in: see
/// `closeRequested`.
close_frame: ?u64 = null,
/// Whether the window's close button only asks, with `close_pressed`: see
/// `Options.ask_before_closing`.
ask_before_closing: bool = false,
/// Set when the window's close button was pressed and `ask_before_closing`
/// kept that from ending the run, until the program has answered it and sets
/// it back.
close_pressed: bool = false,

// Chance: `math/`.
/// What the game's chance is drawn from: `randomFloat` and the rest.
random_source: std.Random.DefaultPrng,

// -------------------------------------------------------------------------
// Making and ending an app
// -------------------------------------------------------------------------

/// The tables kept beside the world by entity, by field. Each lets go of
/// everything when the world goes - `clear(app)` - and one that keeps what a
/// despawn leaves forgets the dead once a frame - `forgetDead(app)`: see
/// `clearWorld` and `forgetTheDead`. A table of an entity's is listed here,
/// or a world cleared hands its old entries to the new world's entities.
const entity_tables = .{
    .names,            .uuids,       .tree,               .groups,
    .slide_collisions, .instances,   .unknown_components, .exports,
    .tweens,           .drawings,    .particles,          .texts,
    .shader_params,    .views,       .animation_players,  .signals,
    .current_scene,    .tile_chunks, .bodies,             .areas,
    .picking,          .audio,       .control_tree,
};

/// The engine's own components: what every scene can hold from the start.
pub const engine_components = .{
    components.Transform2D,
    components.Sprite,
    components.Text2D,
    components.Camera2D,
    components.RenderView,
    components.ViewTexture,
    components.RigidBody2D,
    components.CharacterBody2D,
    components.Collider2D,
    components.Area2D,
    components.RayCast2D,
    drawing.Drawing2D,
    particle_emitters.Particles2D,
    lights.PointLight2D,
    lights.DirectionalLight2D,
    lights.AmbientLight2D,
    lights.LightOccluder2D,
    timer.Timer,
    sound.AudioPlayer,
    sound.AudioSpatial2D,
    sound.AudioListener2D,
    tweening.Tween,
    animation.AnimationPlayer,
    sprite_animation.AnimatedSprite2D,
    shading.Material,
    Processing,
    Appearance,
    tilemap.TileMap,
    tilemap.TileChunk,
    control.Control,
    control.CanvasLayer,
    control.Viewport,
    control.BoxContainer,
    control.MarginContainer,
    control.CenterContainer,
    control.ScrollContainer,
    control.PanelContainer,
    control.ThemeOverride,
    control.Label,
    control.Button,
    control.CheckBox,
    control.LineEdit,
    control.Slider,
    control.ProgressBar,
    control.Focus,
    control.MouseCursor,
    control.ColorRect,
    control.RichText,
    control.Popup,
    control.TabContainer,
    control.TextureRect,
    control.NinePatchRect,
    touch_buttons.TouchButton,
};

/// The engine's own values that are not components, described for what
/// finds a type by name: a console, an editor. See `types`.
const described_types = .{
    DebugViews,
    Color,
    components.Region,
    Assets.TextureHandle,
    Assets.FontHandle,
    tileset.TileSetHandle,
    theme.ThemeHandle,
    sound.AudioClipHandle,
    animation.AnimationLibraryHandle,
    sprite_animation.SpriteFramesHandle,
    sprite_animation.LoopMode,
    shading.ShaderHandle,
    character.Collision,
    geometry.Vec2i,
    geometry.Rect2,
    geometry.Rect2i,
};

/// Open everything, in the order the pieces depend on each other.
pub fn create(gpa: Allocator, options: Options) Error!*App {
    // The pack is the App's from here: it is let go of on the way out of a
    // failure, until the project has it.
    var pack = options.pack;
    errdefer if (pack) |*held| if (options.io) |io| held.deinit(io);

    const self = try gpa.create(App);
    errdefer gpa.destroy(self);

    // Every field at once, defaults included: `create` hands back
    // uninitialised memory, and a default only applies to a struct literal.
    // This way the compiler notices a missing field.
    self.* = .{
        .gpa = gpa,
        .io = options.io,
        .window = null,
        .device = undefined,
        .surface = null,
        .offscreen = null,
        .world = .init(gpa),
        .commands = .init(gpa, &self.world),
        .jobs = undefined,
        .physics = .init(gpa, Bodies.withEngineRules(options.physics)),
        .physics_2d = options.physics_2d,
        .bodies = .{},
        .tile_sets = .{},
        .themes = .{},
        .tile_chunks = .{},
        .project = undefined,
        .assets = undefined,
        .sprites = undefined,
        .screen = undefined,
        .debug = undefined,
        .debug_frame = .init(gpa),
        .debug_steps = .init(gpa),
        .debug_under = undefined,
        .debug_under_frame = .init(gpa),
        .debug_under_steps = .init(gpa),
        .debug_renderer = undefined,
        .debug_visible = true,
        .debug_views = .{},
        .ui = .init(gpa),
        .control_tree = .{},
        .interface = .{},
        .clipboard = .{},
        .next_dialog = 1,
        .trash = null,
        // A fixed frame time wins over the clock, and the clock over nothing.
        // The fixed step is known once the project file is read; the source
        // is set again then.
        .time = .init(if (options.frame_time) |seconds|
            .{ .fixed = seconds }
        else if (options.io) |io|
            .{ .clock = io }
        else
            .{ .fixed = options.fixed_delta orelse Resolved.default_fixed_delta }),
        .snapshots = .empty,
        .names = .{},
        .uuids = .init(options.io),
        .random_source = undefined,
        .scene_components = .{},
        .audio = undefined,
        .signals = .init(gpa),
        .event_channels = .{},
        .types = .init(gpa),
        .input = .{},
        .schedule = .{ .io = options.io, .commands = &self.commands, .signals = &self.signals },
        .states = .{},
        .gate = null,
        .background = options.background orelse Project.Rendering.default_clear_color,
        .world_on_screen = true,
        .width = options.width orelse 0,
        .height = options.height orelse 0,
        .resized = false,
        .quit_key = options.quit_key,
        .ask_before_closing = options.ask_before_closing,
        .open_project = options.open_project,
        .fullscreen_key = options.fullscreen_key,
        .debug_key = options.debug_key,
        .vsync_mode_now = options.vsync_mode orelse .enabled,
        .running = true,
        .close_pressed = false,
        .frames_left = options.frames,
        .started = false,
    };
    errdefer self.world.deinit();
    errdefer self.commands.deinit();
    errdefer self.ui.deinit();
    errdefer self.physics.deinit();

    self.random_source = .init(options.random_seed orelse self.drawnSeed());
    self.project = try .init(gpa, options.io, options.root);
    errdefer self.project.deinit();
    if (options.user_root) |held| self.project.user_root = try gpa.dupe(u8, held);
    if (options.title) |held| self.project.fallback_name = try gpa.dupe(u8, held);
    if (pack) |held| {
        pack = null;
        try self.project.usePack(held);
    }
    // Before the backend is chosen: the project's renderer chooses it, and
    // the window has to know whether it is OpenGL's. A project file that is
    // wrong stops the start, and says why - where the caller asked for it,
    // or else in the log - rather than being drawn some way the project did
    // not ask for.
    {
        var own: json.Diagnostics = .{};
        self.project.loadSettings(options.project_diagnostics orelse &own) catch |err| {
            if (options.project_diagnostics == null and err != error.OutOfMemory) log.err("{f}", .{own});
            return err;
        };
    }
    // The project's actions over the built-in ones.
    const project_actions: []const Input.Action = if (!options.project_input) &.{} else if (self.project.settings) |held| held.input.actions else &.{};
    try self.input.actions.reset(gpa, project_actions);
    if (options.project_input) if (self.project.settings) |held| {
        self.input.mouse_from_touch = held.touch.mouse_from_touch;
        self.input.touch_from_mouse = held.touch.touch_from_mouse;
        self.input.pinch_from_ctrl_wheel = held.touch.pinch_from_ctrl_wheel;
    };
    errdefer self.input.deinit(gpa);
    // The sound device, and the project's buses on it.
    self.audio = sound.Audio.init(gpa, options.audio, options.headless, if (self.project.settings) |held| held.audio.buses else &.{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Nothing but a mixer that did not make itself: no sound at all.
        else => error.Failed,
    };
    errdefer self.audio.deinit();
    // The project's physics, or the game's with no project file.
    if (self.project.settings) |held| self.physics_2d = held.physics_2d;
    self.physics.gravity = self.physics_2d.gravity();

    // The window, the frame and the clock: what the game says, over what
    // the project says, over the engine's own.
    const resolved: Resolved = .of(options, if (self.project.settings) |*held| held else null, self.physics_2d);
    self.background = resolved.background;
    self.width = resolved.width;
    self.height = resolved.height;
    self.stretch = resolved.stretch;
    display.fitFrame(self);
    self.vsync_mode_now = resolved.vsync_mode;
    self.time.fixed_delta = resolved.fixed_delta;
    self.time.max_fixed_steps = resolved.max_fixed_steps;
    self.interface.zoom = resolved.interface_zoom;
    if (self.project.settings) |held| {
        if (!held.application.quit_on_close) self.ask_before_closing = true;
    }
    self.time.max_fps = resolved.max_fps;
    if (options.frame_time == null and (options.fixed_frame_time or options.io == null)) {
        self.time.source = .{ .fixed = resolved.fixed_delta };
    }

    errdefer self.scene_components.deinit(gpa);
    errdefer self.types.deinit();
    self.registerComponents(engine_components) catch |err| switch (err) {
        error.ComponentNameTaken => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    self.types.addAll(described_types) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    // Headless opens no renderer, so the project's is not asked about. The
    // backends are tried in turn, the next where one will not open here.
    const rendering: Project.Rendering = if (self.project.settings) |held| held.rendering else .{};
    var buffer: [Project.Rendering.max_backends]Backend = undefined;
    const candidates = if (options.headless) blk: {
        buffer[0] = .none;
        break :blk buffer[0..1];
    } else backendsToTry(options.backend, rendering, builtin.os.tag, &buffer);
    if (candidates.len == 0) {
        log.err("the {t} renderer ({s}) has no backend here: set \"renderer\" to \"compatibility\" in {s}, or give --backend", .{ rendering.renderer, rendering.renderer.apis(), Project.file_name });
        return error.RendererNotBuilt;
    }
    errdefer if (self.window) |*w| w.close();
    for (candidates, 0..) |backend, attempt| {
        display.open(self, gpa, options, resolved, backend) catch |err| {
            if (err == Error.NoDisplay or attempt + 1 == candidates.len) return err;
            log.warn("{t} did not open here ({t}): trying {t}", .{ backend, err, candidates[attempt + 1] });
            continue;
        };
        if (!options.headless and options.backend == .auto and std.mem.indexOfScalar(Backend, rendering.renderer.backends(builtin.os.tag), backend) == null) {
            log.warn("the {t} renderer did not open here: drawing with {t}, of the compatibility renderer", .{ rendering.renderer, backend });
        }
        break;
    }
    errdefer self.device.deinit();
    errdefer if (self.surface) |s| self.device.destroySurface(s);

    self.jobs = try .init(gpa, .{
        .io = options.io,
        .workers = if (options.workers) |count| .{ .count = count } else .auto,
    });
    errdefer self.jobs.deinit();

    self.assets = try .init(gpa, &self.device, options.io, &self.project);
    errdefer self.assets.deinit();
    if (self.project.settings) |held| self.assets.default_filter = switch (held.rendering.default_texture_filter) {
        .nearest => .nearest,
        .linear => .linear,
    };
    if (options.project_icon) window_icon.useProjectIcon(self);
    if (options.project_cursor) pointer.useProjectCursor(self);

    self.sprites = try .init(gpa, &self.device);
    errdefer self.sprites.deinit(gpa);
    self.screen = try .init(gpa, &self.device);
    errdefer self.screen.deinit();
    self.sprites.texts = &self.texts;
    self.sprites.shaders = &self.shaders;
    self.sprites.params = &self.shader_params;
    self.sprites.screen = &self.screen;
    self.sprites.views = &self.views;
    self.sprites.drawings = &self.drawings;
    self.sprites.particles = &self.particles;
    self.interface.custom = .{ .context = self, .draw = drawControlBox };

    self.debug_renderer = try .init(gpa, &self.device, .{});
    errdefer self.debug_renderer.deinit();
    self.debug = self.debug_frame.pen();
    self.debug_under = self.debug_under_frame.pen();

    return self;
}

pub fn destroy(self: *App) void {
    const gpa = self.gpa;

    // First, while everything a script's handle points at is still there.
    if (self.scripts) |scripts| scripts.calls.destroy(scripts);
    self.input.deinit(gpa);
    self.schedule.deinit(gpa);
    self.states.deinit(gpa);
    self.snapshots.deinit(gpa);
    self.names.deinit(gpa);
    self.tree.deinit(gpa);
    self.groups.deinit(gpa);
    self.slide_collisions.deinit(gpa);
    self.drawings.deinit(gpa);
    self.particles.deinit(gpa);
    self.inherited.deinit(gpa);
    self.instances.deinit(gpa);
    self.current_scene.deinit(gpa);
    self.loads.deinit(gpa);
    self.scenes.deinit(gpa);
    self.data_files.deinit(gpa);
    self.audio.deinit();
    self.tweens.deinit(gpa);
    self.cursors.deinit(gpa);
    self.clocks.deinit(gpa);
    self.culture_choice.deinit(gpa);
    self.texts.deinit(gpa);
    self.shader_params.deinit(gpa);
    self.animation_players.deinit(gpa);
    self.animation_libraries.deinit(gpa);
    self.sprite_frames.deinit(gpa);
    self.uuids.deinit(gpa);
    self.scene_components.deinit(gpa);
    self.unknown_components.deinit(gpa);
    self.exports.deinit(gpa);
    self.signals.deinit();
    self.event_channels.deinit(gpa);
    self.types.deinit();
    self.bodies.deinit(gpa);
    self.tile_sets.deinit(gpa);
    self.themes.deinit(gpa);
    self.tile_chunks.deinit(gpa);
    self.areas.deinit(gpa);
    self.picking.deinit(gpa);
    self.physics.deinit();
    self.debug_renderer.deinit();
    self.debug_steps.deinit();
    self.debug_frame.deinit();
    self.debug_under_steps.deinit();
    self.debug_under_frame.deinit();
    self.interface.deinit();
    self.clipboard.deinit(gpa);
    self.control_tree.deinit(gpa);
    self.ui.deinit();
    self.sprites.deinit(gpa);
    self.screen.deinit();
    self.shaders.deinit(gpa, &self.device);
    self.views.deinit(gpa);
    self.assets.deinit();
    self.project.deinit();
    self.jobs.deinit();
    self.commands.deinit();
    self.world.deinit();

    while (self.tool_windows.pop()) |tool| tool.destroy(self);
    self.tool_windows.deinit(gpa);
    self.touch_actions.deinit(gpa);
    if (self.offscreen) |t| self.device.destroyTexture(t);
    if (self.surface) |s| self.device.destroySurface(s);
    self.device.deinit();
    if (self.window) |*w| w.close();

    gpa.destroy(self);
}

// -------------------------------------------------------------------------
// The loop
// -------------------------------------------------------------------------
//
// Each frame: the window's news, the scripts and the systems in their
// stages, the fixed steps, the engine's own passes, and the drawing. `step`
// is one frame, and `run` every frame until something stops it.

/// Run until something asks to stop: the window closes, `quit` is called, or
/// the frame count runs out.
pub fn run(self: *App) anyerror!void {
    try self.startup();
    while (try self.step()) {}
    try self.stop();
}

/// Run the `.startup` stage, once, and enter each state's first value.
/// Doing it twice does nothing.
pub fn startup(self: *App) anyerror!void {
    if (self.started) return;
    self.started = true;
    if (self.open_project) try self.openProject();
    try self.schedule.run(.startup, self);
    try States.enterFirst(self);
}

/// One frame - the lists of `app/frame_steps.zig` - and whether there should be
/// another. Public for a game that drives its own loop.
pub fn step(self: *App) anyerror!bool {
    if (!self.running) return false;

    // The old edges go first, then this frame's events. The resize flag is an
    // edge too.
    self.input.beginFrame();
    // Every system has had this frame's dialog answers and drops when it
    // ends - or had its chance, when one of them failed - and they go at the
    // next `beginFrame`, before the pump that frees the platform's paths in
    // them.
    // A `defer`, so a loop that goes on after an error never reads a path
    // that is gone.
    defer self.input.endFrame();
    for (self.tool_windows.items) |tool| tool.input.beginFrame();
    defer for (self.tool_windows.items) |tool| tool.input.endFrame();
    self.schedule.beginFrame();
    // Last frame's events go, and this frame's become last frame's.
    self.event_channels.update();
    self.resized = false;

    if (!try self.readWindows()) return false;
    try frame_steps.run(self, &frame_steps.news);

    // In the background - an Android app switched away from, a page hidden -
    // a frame runs nothing and draws nothing, save the one the news came in,
    // for its systems to save what they must.
    if (self.input.suspended and !self.input.justSuspended()) {
        try self.waitForNextFrame(true);
        return self.running;
    }
    try frame_steps.run(self, &frame_steps.order);

    if (self.frames_left) |left| {
        if (left <= 1) {
            self.running = false;
        } else {
            self.frames_left = left - 1;
        }
    }

    if (self.running) try self.waitForNextFrame(self.windowMode() == .minimized);
    return self.running;
}

/// The windows' news: their events into the input, a close asked for, a new
/// size. False when the window is gone and the loop should end.
fn readWindows(self: *App) !bool {
    if (self.window) |*window| {
        if (!window.pump(&self.input, .{ .context = self, .event = ToolWindow.route })) {
            self.running = false;
            return false;
        }
        if (window.close_pressed) {
            window.close_pressed = false;
            if (!self.ask_before_closing) {
                self.running = false;
                return false;
            }
            self.close_pressed = true;
            self.close_frame = self.time.frame;
        }
        if (window.resized) {
            window.resized = false;
            try display.adoptSize(self, window.width, window.height);
        }
    }
    for (self.tool_windows.items) |tool| {
        if (!tool.resized) continue;
        tool.resized = false;
        if (tool.surface) |surface| try self.device.resizeSurface(surface, tool.width, tool.height);
    }
    return true;
}

fn waitForNextFrame(self: *App, minimized: bool) !void {
    const target_fps: f32 = if (minimized) fps_while_minimized else self.frameCap() orelse return;
    try self.time.sleepUntilNextFrame(target_fps);
}

/// The frames a second this frame is held to: `max_fps`, and
/// `background_fps` too while no window of the program has the keyboard.
fn frameCap(self: *const App) ?f32 {
    const cap = self.time.max_fps;
    const behind = self.time.background_fps orelse return cap;
    if (self.inForeground()) return cap;
    return if (cap) |held| @min(held, behind) else behind;
}

/// Whether one of the program's windows - its own, or a tool window - has
/// the keyboard. Without a window, always.
pub fn inForeground(self: *const App) bool {
    if (self.input.focused) return true;
    for (self.tool_windows.items) |tool| {
        if (tool.focused) return true;
    }
    return false;
}

/// Whether the interface is laid out at all: a game with a `.ui` system.
pub fn hasInterface(self: *const App) bool {
    return self.schedule.systemsIn(.ui).len != 0;
}

/// Run the `.shutdown` stage. Called by `run`; call it yourself if you drive
/// `step` and want the stage to happen.
pub fn stop(self: *App) anyerror!void {
    try self.schedule.run(.shutdown, self);
}

/// End the loop after this frame.
pub fn quit(self: *App) void {
    self.running = false;
    if (self.window) |*w| w.requestClose();
}

// -------------------------------------------------------------------------
// Systems
// -------------------------------------------------------------------------

/// Add a system to a stage, under a name. See `schedule`.
///
/// ```zig
/// try app.addSystem(.fixed, "move ball", moveBall);
/// ```
///
/// The name is what a failure is reported by - see `Schedule.failed` - since
/// Zig cannot recover a function's name from a pointer. It is `comptime` so
/// that it outlives the schedule, which keeps it uncopied.
pub fn addSystem(self: *App, stage: Stage, comptime name: []const u8, system: System) Allocator.Error!void {
    return self.schedule.addEntry(self.gpa, stage, .{ .name = name, .run = system, .gate = self.gate });
}

/// `addSystem`, for a system that runs whether the game is paused or not:
/// the key that pauses and unpauses it. The rest stop while it is paused.
/// See `setPaused`.
///
/// ```zig
/// try app.addSystemAlways(.input, "pause key", togglePause);
/// ```
pub fn addSystemAlways(self: *App, stage: Stage, comptime name: []const u8, system: System) Allocator.Error!void {
    return self.schedule.addEntry(self.gpa, stage, .{ .name = name, .run = system, .gate = self.gate, .pause = .always });
}

/// `addSystem`, for a system that runs only while the game is paused: a
/// pause menu's. See `setPaused`.
pub fn addSystemWhenPaused(self: *App, stage: Stage, comptime name: []const u8, system: System) Allocator.Error!void {
    return self.schedule.addEntry(self.gpa, stage, .{ .name = name, .run = system, .gate = self.gate, .pause = .when_paused });
}

/// Add a system that runs only while `value`'s state has that value.
///
/// ```zig
/// const Mode = enum { menu, playing, paused };
/// try app.addSystemIn(.update, Mode.playing, "move", move);
/// ```
pub fn addSystemIn(self: *App, stage: Stage, value: anytype, comptime name: []const u8, system: System) Allocator.Error!void {
    _ = try self.states.slotFor(self.gpa, @TypeOf(value));
    return self.schedule.addEntry(self.gpa, stage, .{
        .name = name,
        .run = system,
        .condition = .{ .state = .of(value) },
        .gate = self.gate,
    });
}

/// Add a system that runs only while `condition` says so, asked each time
/// its stage comes round.
pub fn addSystemIf(
    self: *App,
    stage: Stage,
    condition: *const fn (app: *App) bool,
    comptime name: []const u8,
    system: System,
) Allocator.Error!void {
    return self.schedule.addEntry(self.gpa, stage, .{
        .name = name,
        .run = system,
        .condition = .{ .custom = condition },
        .gate = self.gate,
    });
}

/// Every system `register` adds - to stages and to states - runs only while
/// `value`'s state has that value. For code that does not know it is being
/// gated: an editor adds a game's systems so, and they run in Play and not
/// while it is editing.
///
/// ```zig
/// const Play = enum { editing, playing, paused };
/// try app.addSystemsIn(Play.playing, game.addSystems);
/// ```
pub fn addSystemsIn(self: *App, value: anytype, register: *const fn (app: *App) anyerror!void) anyerror!void {
    _ = try self.states.slotFor(self.gpa, @TypeOf(value));
    const outer = self.gate;
    defer self.gate = outer;
    self.gate = .{ .state = .of(value) };
    try register(self);
}

// -------------------------------------------------------------------------
// States
// -------------------------------------------------------------------------

/// Start a state at `initial` rather than at its first value. Before `run`;
/// after it, this is `setState`.
pub fn addState(self: *App, initial: anytype) Allocator.Error!void {
    if (self.started) return self.setState(initial);
    const slot = try self.states.slotFor(self.gpa, @TypeOf(initial));
    slot.current = @intFromEnum(initial);
}

/// A state's value now. One nothing has named yet is at its first value.
pub fn state(self: *const App, comptime T: type) T {
    return self.states.get(T);
}

/// Change a state at the top of the next frame: the systems for leaving the
/// old value run, then those for entering this one. The last asked for in a
/// frame wins, and asking for the value it has does nothing.
pub fn setState(self: *App, value: anytype) Allocator.Error!void {
    try self.states.set(self.gpa, value);
}

/// What `setStateNamed` can refuse.
pub const StateError = error{
    /// Nothing has named a state type of that name. See `States.Slot.name`.
    NoSuchState,
    /// The state type has no value of that name.
    NoSuchValue,
};

/// The name of the value a state has now, the state given by its type's name
/// - `Mode`, not `game.Mode`. For a console or an editor's state panel,
/// which were not compiled against the game's enums. Null for a state nothing
/// has named.
pub fn stateNamed(self: *const App, state_name: []const u8) ?[]const u8 {
    const at = self.states.named(state_name) orelse return null;
    return self.states.slots.items[at].currentName();
}

/// `setState`, by names: `app.setStateNamed("Mode", "paused")`.
pub fn setStateNamed(self: *App, state_name: []const u8, value_name: []const u8) StateError!void {
    const at = self.states.named(state_name) orelse return error.NoSuchState;
    const slot = &self.states.slots.items[at];
    const member = slot.type.member(value_name) orelse return error.NoSuchValue;
    slot.pending = @intCast(member.value);
}

/// Run `system` whenever `value`'s state takes that value - and after
/// `.startup`, for the value a state starts at.
pub fn onEnter(self: *App, value: anytype, comptime name: []const u8, system: System) Allocator.Error!void {
    try self.addHook(.enter, value, name, system);
}

/// Run `system` whenever `value`'s state leaves that value.
pub fn onExit(self: *App, value: anytype, comptime name: []const u8, system: System) Allocator.Error!void {
    try self.addHook(.exit, value, name, system);
}

fn addHook(self: *App, on: Hook.On, value: anytype, comptime name: []const u8, system: System) Allocator.Error!void {
    _ = try self.states.slotFor(self.gpa, @TypeOf(value));
    try self.schedule.addHook(self.gpa, .{
        .on = on,
        .state = .of(value),
        .entry = .{ .name = name, .run = system, .gate = self.gate },
    });
}

// -------------------------------------------------------------------------
// Signals and events
// -------------------------------------------------------------------------
//
// Signals, on components, and the typed events the engine's own are made
// from: see `core/signals.zig`, `core/signals_by_name.zig` and
// `core/event_channels.zig`.

pub const Signal = @import("core/signals.zig").Signal;

/// The signal `name` that `C` declares, of `entity`, checked as it is
/// compiled.
///
/// ```zig
/// try app.signal(player, Health, .hit).connect(.method(hud, "_on_player_hit"), .{});
/// ```
pub fn signal(self: *App, entity: ecs.Entity, comptime C: type, comptime name: @EnumLiteral()) Signal {
    comptime {
        if (!@hasDecl(C, "signals") or !@hasField(@TypeOf(C.signals), @tagName(name)))
            @compileError("fluxion-engine: " ++ @typeName(C) ++ " declares no signal ." ++ @tagName(name));
    }
    return .{ .app = self, .source = entity, .component = comptime scene.nameOf(C), .name = @tagName(name) };
}

/// Emit `name` of `entity`, its arguments checked against what `C` declares
/// as it is compiled. See `Signal.emit`.
pub fn emit(self: *App, entity: ecs.Entity, comptime C: type, comptime name: @EnumLiteral(), args: @field(C.signals, @tagName(name))) SignalError!void {
    return self.signal(entity, C, name).emit(args);
}

/// A signal of `entity` by the name one of its components declares it
/// under - `hit`, or `Health.hit` when two of them declare `hit` - for what
/// was not compiled against the game: an editor, a console, a scene.
pub fn signalNamed(self: *App, entity: ecs.Entity, name: []const u8) SignalError!Signal {
    return signals_by_name.signalNamed(self, entity, name);
}

/// `signalNamed`, emitted with values: what a console or a script emits.
pub fn emitNamed(self: *App, entity: ecs.Entity, name: []const u8, values: []const reflect.Value) SignalError!void {
    return signals_by_name.emitNamed(self, entity, name, values);
}

/// Whether one of `entity`'s components declares a signal by that name.
pub fn hasSignal(self: *App, entity: ecs.Entity, name: []const u8) bool {
    return signals_by_name.hasSignal(self, entity, name);
}

/// Every signal `entity` has, component by component in the order they
/// were registered - its script's where `Script` is - as many as `found`
/// holds.
pub fn signalsOf(self: *App, entity: ecs.Entity, found: []SignalInfo) []SignalInfo {
    return signals_by_name.signalsOf(self, entity, found);
}

/// The signals the component a scene calls `name` declares, whether any
/// entity has it or not: what an editor lists before one is added.
pub fn signalsOfComponent(self: *App, name: []const u8, found: []SignalInfo) []SignalInfo {
    return signals_by_name.signalsOfComponent(self, name, found);
}

/// Connect to a signal of `source` by name, whether this build knows it or
/// not: one no component declares is kept, saved and listed as written,
/// and never heard - how a scene or an editor holds a game's connections
/// without the game's components. A bare name two components declare is
/// `error.AmbiguousSignal`: name one.
pub fn connectNamed(self: *App, source: ecs.Entity, name: []const u8, callable: Callable, options: ConnectOptions) SignalError!void {
    return signals_by_name.connectNamed(self, source, name, callable, options);
}

/// Take away a connection `connectNamed` could have made, by the name a
/// listing gives it.
pub fn disconnectNamed(self: *App, source: ecs.Entity, name: []const u8, callable: Callable) void {
    return signals_by_name.disconnectNamed(self, source, name, callable);
}

/// Every connection of `source`'s signals, known or not, in the order they
/// were made: the order they are heard in, and the order a scene keeps and
/// reads back. A disconnect and a connect again puts one last.
pub fn connectionsFrom(self: *App, source: ecs.Entity, found: []Connection) []Connection {
    return signals_by_name.connectionsFrom(self, source, found);
}

/// Every connection to a method of `receiver`.
pub fn connectionsTo(self: *App, receiver: ecs.Entity, found: []Connection) []Connection {
    return signals_by_name.connectionsTo(self, receiver, found);
}

/// How many connections `source`'s signals have, known or not, with no
/// list to fill: what a hierarchy's signal icon asks.
pub fn connectionCount(self: *const App, source: ecs.Entity) usize {
    return self.signals.connectionCount(source);
}

/// Whether `entity`'s emits do nothing.
pub fn setBlockSignals(self: *App, entity: ecs.Entity, on: bool) Allocator.Error!void {
    return self.signals.setBlocked(entity, on);
}

pub fn isBlockingSignals(self: *const App, entity: ecs.Entity) bool {
    return self.signals.isBlocked(entity);
}

/// Let a signal's connection call `f` by `name`, when no component of the
/// target has a method by it: `fn (app: *App, self: fx.Entity, ...) !void`,
/// `self` the entity connected to, and after it what the connection hands
/// on. The values are converted to the parameters as
/// it is called, and a call with the wrong number is that call's error.
///
/// ```zig
/// try app.addMethod("_on_player_hit", onPlayerHit);
/// fn onPlayerHit(app: *fx.App, self: fx.Entity, damage: f32, by: fx.Entity) !void { ... }
/// ```
pub fn addMethod(self: *App, name: []const u8, comptime f: anytype) Allocator.Error!void {
    return self.signals.addMethod(name, f);
}

/// Every method a connection to `receiver` can name, with what each takes:
/// its components' `reflect_methods`, then what the game gave `addMethod`
/// by name, as many as `found` holds. What an editor's method picker lists,
/// and filters by a signal's arguments. `Entity.none` lists the game's own
/// alone.
pub fn methodsOf(self: *App, receiver: ecs.Entity, found: []MethodInfo) []MethodInfo {
    return signals_by_name.methodsOf(self, receiver, found);
}

/// Call the method a connection names, on `receiver`: a method one of its
/// components lists in `reflect_methods` - `Text2D.set` names the one -
/// or its script declares - `Script.hit` - else one given to `addMethod`.
pub fn callMethodOn(self: *App, receiver: ecs.Entity, name: []const u8, args: []const reflect.Value) anyerror!void {
    return signals_by_name.callMethodOn(self, receiver, name, args);
}

/// Whether a connection naming `name` would find a method on `receiver`:
/// one of its components', its script's, or one given to `addMethod`.
pub fn hasMethod(self: *App, receiver: ecs.Entity, name: []const u8) bool {
    return signals_by_name.hasMethod(self, receiver, name);
}

/// A connection's signal as the listings give it and a scene writes it: the
/// bare name, unless another of the source's components declares the same
/// name or the source has not got the one that declares it; and one this
/// build did not know when it was made, as it was written.
pub fn signalWritten(self: *App, c: Connection) []const u8 {
    return signals_by_name.signalWritten(self, c);
}

/// Send an event: every reader of its type sees it once, this frame or the
/// next. Safe anywhere, a query's loop included. See `events`.
///
/// ```zig
/// try app.send(Damage{ .to = player, .amount = 5 });
/// ```
pub fn send(self: *App, event: anytype) Allocator.Error!void {
    return self.event_channels.send(self.gpa, event);
}

/// The events of one type, this frame's and last frame's, for a reader to
/// read. None when nothing ever sent one.
pub fn events(self: *App, comptime T: type) *const typed_events.Events(T) {
    return self.event_channels.events(T);
}

// -------------------------------------------------------------------------
// Components and calls by name
// -------------------------------------------------------------------------
//
// For code that was not compiled against the game: an editor's inspector
// walks a component's fields, a console calls the engine by name. Both go
// through fluxion-reflect's descriptors, and a component is found by the
// name a scene gives it: see `scene/registry.zig`.

/// One of an entity's components, as `componentsOf` lists them.
pub const ComponentValue = registry.ComponentValue;

pub const ComponentError = registry.ComponentError;

/// The component called `name` on an entity, as a value whose type is known
/// only at run time: read and written in place, field by field. Null when
/// nothing is registered under that name, or the entity has none of it.
///
/// ```zig
/// const place = app.componentOf(player, "Transform2D") orelse return;
/// try (try place.field("x")).setFloat(320);
/// for (place.type.fields()) |field| inspect(field.name.slice(), try place.field(field.name.slice()));
/// ```
///
/// It points into the world, so it lasts as a `World.get` pointer does: until
/// rows next move.
pub fn componentOf(self: *App, entity: ecs.Entity, name: []const u8) ?reflect.Value {
    return self.scene_components.componentOf(&self.world, entity, name);
}

/// The component of type `t` on an entity, found as `componentOf` finds one
/// by name. A script's handle on a component looks itself up with this each
/// time the script uses it.
pub fn componentOfType(self: *App, entity: ecs.Entity, t: *const reflect.Type) ?reflect.Value {
    return self.scene_components.componentOfType(&self.world, entity, t);
}

/// Every registered component an entity has, in the order they were
/// registered - the engine's first - as many as `found` holds.
pub fn componentsOf(self: *App, entity: ecs.Entity, found: []ComponentValue) []ComponentValue {
    return self.scene_components.componentsOf(&self.world, entity, found);
}

/// Put the component called `name` on an entity, holding its defaults, and
/// hand it back to fill in: an inspector's Add Component. One the entity has
/// already is handed back as it is. Not from inside a query, since it moves
/// the entity; `commands` is for that.
pub fn addComponentNamed(self: *App, entity: ecs.Entity, name: []const u8) ComponentError!reflect.Value {
    return self.scene_components.addNamed(&self.world, entity, name);
}

/// Take the component called `name` off an entity: a registered one, which
/// does nothing when the entity has none, or one it was read with that
/// nothing here is registered as. Not from inside a query either.
pub fn removeComponentNamed(self: *App, entity: ecs.Entity, name: []const u8) ComponentError!void {
    const entry = self.scene_components.find(name) orelse {
        if (!self.world.isAlive(entity)) return error.NoSuchEntity;
        if (!self.unknown_components.remove(self.gpa, entity, name)) return error.NoSuchComponent;
        return;
    };
    try entry.removeFrom(&self.world, entity);
}

/// The components an entity was read from a scene with that nothing here is
/// registered as - a game's own, in an editor that has not got them - each
/// its name and its value as compact JSON, in the order the scene had them.
/// Saving a scene writes them back as they were, and `removeComponentNamed`
/// takes one off.
pub fn unknownComponentsOf(self: *const App, entity: ecs.Entity) []const scene.Unknown.Component {
    if (!self.world.isAlive(entity)) return &.{};
    return self.unknown_components.of(entity);
}

/// Call one of the calls `reflect_methods` lists, by name, with values for
/// its arguments - what a console does with a line it has read. An error the
/// call returns is returned from here; otherwise what it gives back is
/// written into `result`, when there is one, converted as numbers are.
///
/// ```zig
/// var title: []const u8 = "Level 2";
/// try app.callNamed("setWindowTitle", &.{.of(&title)}, null);
///
/// var hero: ?fx.Entity = null;
/// try app.callNamed("find", &.{.of(&name)}, .of(&hero));
/// ```
///
/// `reflect.typeOf(App).methods` lists them, with each one's parameters.
pub fn callNamed(self: *App, name: []const u8, args: []const reflect.Value, result: ?reflect.Value) anyerror!void {
    return calls.call(.of(self), name, args, result);
}

// -------------------------------------------------------------------------
// Entities
// -------------------------------------------------------------------------

/// Let scenes hold these components as well as the engine's own.
///
/// ```zig
/// try app.registerComponents(.{ Wander, Player });
/// ```
///
/// Each is written under its own name - `Wander`, not `creatures.Wander` -
/// or under its `pub const scene_name`, which is how two types of one name
/// are told apart, or its `reflect_name`. Registering one twice does
/// nothing. Each is described in `types` as well, so `componentOf` can find
/// it by that name, and the attributes it declares are checked: see
/// `attr.check`.
pub fn registerComponents(self: *App, comptime list: anytype) scene.Registry.Error!void {
    @setEvalBranchQuota(10_000);
    inline for (list) |T| {
        comptime attr.check(T);
        // Described first: a description nothing uses is harmless, and a
        // component a scene holds and nothing can describe is not.
        //
        // The registry takes two descriptors of one name, kind and size for
        // one type described twice - by another binary, say - so two types
        // given one `reflect_name` would pass it. In one program a type has
        // one descriptor, and another under the name is another type.
        const described = reflect.typeOf(T);
        if (self.types.find(described.name.slice())) |held| {
            if (held != described) return error.ComponentNameTaken;
        }
        self.types.addType(described) catch |err| return switch (err) {
            error.NameTaken => error.ComponentNameTaken,
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable,
        };
        try self.scene_components.add(self.gpa, T, comptime scene.nameOf(T));
    }
}

/// A new entity, with nothing on it, hanging from `parent` - or a root, for
/// none. What a script makes things with: `self.entity.spawnChild()`, or
/// `app.spawn(null)` for a root, then `add(Sprite)`.
pub fn spawn(self: *App, parent: ecs.Entity) !ecs.Entity {
    const made = try self.world.spawn();
    errdefer self.world.despawn(made);
    if (!parent.isNone()) try self.setParent(made, parent, false);
    return made;
}

/// A timer that runs once, `seconds` from now, on an entity of its own that
/// goes after its `timeout`: one to connect to and forget.
///
/// ```zig
/// const fuse = try app.createTimer(1.5);
/// try app.signal(fuse, fx.Timer, .timeout).connectFn(explode, .{});
/// ```
pub fn createTimer(self: *App, seconds: f32) ecs.World.Error!ecs.Entity {
    return self.world.spawnWith(.{timer.Timer{ .wait_time = seconds, .one_shot = true, .autostart = true, .free_when_stopped = true }});
}

/// The one entity's `T`: a score, a game's state - the component there is
/// exactly one of. Null when there is none.
///
/// ```zig
/// const score = app.single(Score) orelse return;
/// score.left += 1;
/// ```
///
/// A second entity with a `T` stops a debug build here rather than quietly
/// picking one. The pointer lasts until rows next move, as with `World.get`.
/// Asking about a component the world has never seen registers nothing.
pub fn single(self: *App, comptime T: type) ?*T {
    const id = self.world.findId(T) orelse return null;
    var found: ?ecs.Entity = null;
    for (self.world.archetypeSlice()) |*archetype| {
        if (archetype.len() == 0 or !archetype.signature().contains(id)) continue;
        std.debug.assert(found == null and archetype.len() == 1);
        found = archetype.entities.items[0];
    }
    return self.world.get(found orelse return null, T);
}

/// Everything out of the world at once - every entity, name and UUID - and
/// an empty world in its place: a level loaded over another is this and then
/// `loadScene`. Not from inside a query, which is walking the world it
/// throws away.
pub fn clearWorld(self: *App) void {
    inline for (entity_tables) |field| @field(self, @tagName(field)).clear(self);
    self.commands.clear();
    self.world.deinit();
    self.world = .init(self.gpa);
    self.snapshots.clearRetainingCapacity();
    // Last, in the new world: each script's `exit` finds its entity gone.
    if (self.scripts) |scripts| scripts.calls.clear(scripts);
}

/// What every table beside the world kept of the entities that died, let
/// go of: once a frame, after the last despawn the engine makes.
pub fn forgetTheDead(self: *App) void {
    inline for (entity_tables) |field| {
        const table = &@field(self, @tagName(field));
        if (@hasDecl(@TypeOf(table.*), "forgetDead")) table.forgetDead(self);
    }
}

// -------------------------------------------------------------------------
// The tree
// -------------------------------------------------------------------------
//
// Each parent's children in their order, and the roots: see `scene/tree.zig`.

/// The parent an entity hangs from, `.none` for a root: see `Parent`.
pub fn parentOf(self: *const App, entity: ecs.Entity) ecs.Entity {
    return hierarchy.parentOf(&self.world, entity);
}

/// What `setParent` can refuse.
pub const ParentError = scene_tree.ParentError;

/// Hang `entity` from `parent`, or from nothing for a root, last among its
/// new siblings. With `keep_global` it stays where it is in the world, its
/// own transform written to land there under the new parent; without, its
/// numbers stay as they are and it moves with the new parent's space. A
/// sibling with its name already gives it the first free one after it.
pub fn setParent(self: *App, entity: ecs.Entity, parent: ecs.Entity, keep_global: bool) ParentError!void {
    return scene_tree.setParent(self, entity, parent, keep_global);
}

/// Whether `entity` hangs from `ancestor`, however far down.
pub fn hangsFrom(self: *const App, entity: ecs.Entity, ancestor: ecs.Entity) bool {
    return hierarchy.hangsFrom(&self.world, entity, ancestor);
}

/// Whether `a` comes before `b` among their parent's children: what to sort
/// siblings by. Siblings are the entities with the same `Parent`, and the
/// roots - no parent - are one family of their own. An editor that groups
/// the world by parent itself sorts each group with this, rather than asking
/// `childrenOf` of every entity.
///
/// ```zig
/// std.mem.sort(fx.Entity, group, @as(*const fx.App, app), fx.App.siblingBefore);
/// ```
pub fn siblingBefore(self: *const App, a: ecs.Entity, b: ecs.Entity) bool {
    return self.tree.before(a, b);
}

/// A parent's children in their order, `.none` for the roots: a slice of
/// the tree, good until the world next changes shape.
pub fn children(self: *App, parent: ecs.Entity) []const ecs.Entity {
    return self.tree.children(self.gpa, &self.world, parent);
}

/// How many children a parent has; the roots for `.none`.
pub fn childCount(self: *App, parent: ecs.Entity) i64 {
    return @intCast(self.children(parent).len);
}

/// A parent's child at `index` in their order, or null past the end.
pub fn childAt(self: *App, parent: ecs.Entity, index: i64) ?ecs.Entity {
    const family = self.children(parent);
    if (index < 0 or index >= family.len) return null;
    return family[@intCast(index)];
}

/// A parent's children in their order, as many as `found` holds, the first
/// ones kept when there are more; `.none` for the roots. See `children` for
/// the slice itself.
pub fn childrenOf(self: *App, parent: ecs.Entity, found: []ecs.Entity) []ecs.Entity {
    const family = self.children(parent);
    const count = @min(family.len, found.len);
    @memcpy(found[0..count], family[0..count]);
    return found[0..count];
}

/// The child of `parent` called `name`, the roots for `.none`.
pub fn childNamed(self: *App, parent: ecs.Entity, name: []const u8) ?ecs.Entity {
    return scene_tree.childNamed(self, parent, name);
}

/// Where a path of names leads from `from`: "Arm/Hand" is `from`'s child
/// called Arm and that one's child called Hand. `..` is a step up to the
/// parent, `.` stays, and a path that starts with `/` starts from the roots
/// rather than from `from`. Null where a step finds nothing.
///
/// ```zig
/// const hand = app.findPath(player, "Arm/Hand") orelse return;
/// const door = app.findPath(button, "../../Door") orelse return;
/// ```
pub fn findPath(self: *App, from: ecs.Entity, path: []const u8) ?ecs.Entity {
    return scene_tree.findPath(self, from, path);
}

/// The first entity called `name` that hangs from `root`, however far down,
/// in the tree's order; the whole world for `.none`. What a scene's own
/// "unique" names are found by, from its root.
pub fn findIn(self: *App, root: ecs.Entity, name: []const u8) ?ecs.Entity {
    return scene_tree.findIn(self, root, name);
}

/// Where an entity is among its parent's children, from nought. Null for
/// one that is not alive.
pub fn siblingIndex(self: *App, entity: ecs.Entity) ?u32 {
    return self.tree.indexOf(self.gpa, &self.world, entity);
}

/// Put an entity at `index` among its parent's children, the ones from
/// there on moving along one. An index past the end is the end. Kept beside
/// the world, and written into a scene as the order its list is in, so it
/// comes back as it was.
pub fn setSiblingIndex(self: *App, entity: ecs.Entity, index: u32) (error{NoSuchEntity} || Allocator.Error)!void {
    return self.tree.setIndex(self.gpa, &self.world, entity, index);
}

/// Give entities places in the order given, after every place given out
/// before: what a scene's list does to the entities it made.
pub fn placeInOrder(self: *App, entities: []const ecs.Entity) Allocator.Error!void {
    return self.tree.placeInOrder(self.gpa, entities);
}

/// Give every living entity that has no place one, in the order of its
/// handle - which is the order it is in now - so that what is placed next
/// comes after it rather than before. A world nobody reorders never pays
/// for this.
pub fn placeTheRest(self: *App) Allocator.Error!void {
    return self.tree.placeTheRest(self.gpa, &self.world);
}

/// Despawn an entity and everything that hangs from it, now rather than at
/// the end of the frame.
pub fn despawnTree(self: *App, entity: ecs.Entity) Allocator.Error!void {
    return scene_tree.despawnBranch(self, entity);
}

// -------------------------------------------------------------------------
// Where things are, through the parent chain
// -------------------------------------------------------------------------
//
// See `scene/hierarchy.zig`.

/// What a call that writes where an entity is can fail with.
pub const PlaceError = hierarchy.PlaceError;

/// Where an entity really is, with every parent above it applied. Null
/// when it has no transform, or when something it hangs from was despawned
/// this frame. The result has no parent, so writing
/// it over the entity's own transform lets go while keeping it in place.
///
/// Where it is, not where it is drawn: an entity that `interpolate`s is drawn
/// between its last two fixed steps, which `drawnTransform` says.
pub fn worldTransform(self: *App, entity: ecs.Entity) ?components.Transform2D {
    return hierarchy.worldTransform(&self.world, entity);
}

/// Where an entity is drawn this frame: `worldTransform`, with every link
/// that `interpolate`s blended between its last two fixed steps as the
/// renderer blends it. For drawing beside a sprite, not for the game's sums.
pub fn drawnTransform(self: *App, entity: ecs.Entity) ?components.Transform2D {
    return hierarchy.resolveEntity(&self.world, &self.snapshots, entity, self.time.alpha());
}

/// Put an entity where `placed` says in the world, and keep its parent: its
/// own transform becomes the one that, under its parents, lands there. Its
/// parent, its inherit switches and its `interpolate` stay its own;
/// `placed`'s are not read.
pub fn setWorldTransform(self: *App, entity: ecs.Entity, placed: components.Transform2D) PlaceError!void {
    return hierarchy.setWorldTransform(&self.world, entity, placed);
}

/// Where an entity is in the world.
pub fn globalPosition(self: *App, entity: ecs.Entity) ?math.Vec2 {
    return hierarchy.globalPosition(&self.world, entity);
}

pub fn setGlobalPosition(self: *App, entity: ecs.Entity, position: math.Vec2) PlaceError!void {
    return hierarchy.setGlobalPosition(&self.world, entity, position);
}

/// Which way an entity faces in the world, in radians.
pub fn globalRotation(self: *App, entity: ecs.Entity) ?f32 {
    return hierarchy.globalRotation(&self.world, entity);
}

pub fn setGlobalRotation(self: *App, entity: ecs.Entity, radians: f32) PlaceError!void {
    return hierarchy.setGlobalRotation(&self.world, entity, radians);
}

/// How big an entity is in the world.
pub fn globalScale(self: *App, entity: ecs.Entity) ?math.Vec2 {
    return hierarchy.globalScale(&self.world, entity);
}

pub fn setGlobalScale(self: *App, entity: ecs.Entity, scale: math.Vec2) PlaceError!void {
    return hierarchy.setGlobalScale(&self.world, entity, scale);
}

/// Move an entity by `offset` in the world, whatever its parents have done
/// to its axes.
pub fn globalTranslate(self: *App, entity: ecs.Entity, offset: math.Vec2) PlaceError!void {
    return hierarchy.globalTranslate(&self.world, entity, offset);
}

/// A point in the world, in an entity's own space.
pub fn toLocal(self: *App, entity: ecs.Entity, global_point: math.Vec2) ?math.Vec2 {
    return hierarchy.toLocal(&self.world, entity, global_point);
}

/// A point in an entity's own space, in the world.
pub fn toGlobal(self: *App, entity: ecs.Entity, local_point: math.Vec2) ?math.Vec2 {
    return hierarchy.toGlobal(&self.world, entity, local_point);
}

/// How far an entity would turn to face a point with its `+x`, in radians,
/// measured in its own space and scale.
pub fn getAngleTo(self: *App, entity: ecs.Entity, point: math.Vec2) ?f32 {
    return hierarchy.getAngleTo(&self.world, entity, point);
}

/// Turn an entity so that its `+x` faces a point in the world.
pub fn lookAt(self: *App, entity: ecs.Entity, point: math.Vec2) PlaceError!void {
    return hierarchy.lookAt(&self.world, entity, point);
}

/// Where an entity is in the space of `ancestor`, something it hangs from.
/// Nothing moved for the entity itself, and null for an entity `ancestor`
/// is not above.
pub fn getRelativeTransformToParent(self: *App, entity: ecs.Entity, ancestor: ecs.Entity) ?components.Transform2D {
    return hierarchy.getRelativeTransformToParent(&self.world, entity, ancestor);
}

/// Move an entity along its own `+x`, in its parent's space. By `delta`
/// units, or with `scaled` by `delta` of its own scaled lengths.
pub fn moveLocalX(self: *App, entity: ecs.Entity, delta: f32, scaled: bool) PlaceError!void {
    return hierarchy.moveLocalX(&self.world, entity, delta, scaled);
}

/// The same along its own `+y`.
pub fn moveLocalY(self: *App, entity: ecs.Entity, delta: f32, scaled: bool) PlaceError!void {
    return hierarchy.moveLocalY(&self.world, entity, delta, scaled);
}

/// Turn an entity by `radians` more.
pub fn rotate(self: *App, entity: ecs.Entity, radians: f32) PlaceError!void {
    return hierarchy.rotate(&self.world, entity, radians);
}

/// Multiply an entity's scale by `ratio`.
pub fn applyScale(self: *App, entity: ecs.Entity, ratio: math.Vec2) PlaceError!void {
    return hierarchy.applyScale(&self.world, entity, ratio);
}

// -------------------------------------------------------------------------
// Names and UUIDs
// -------------------------------------------------------------------------
//
// See `scene/names.zig` and `scene/uuids.zig`.

/// What `setName` can refuse.
pub const NameError = @import("scene/names.zig").NameError;

/// Call an entity something, so that `find` and a path of names can come
/// back to it.
///
/// ```zig
/// fn spawn(app: *App) !void {
///     const camera = try app.world.spawnWith(.{ Transform2D.at(0, 0), Camera2D{} });
///     try app.setName(camera, "camera");
/// }
///
/// fn pan(app: *App) !void {
///     const camera = app.find("camera") orelse return;
///     ...
/// }
/// ```
///
/// The name is the entity's own, not a component: naming does not move the
/// entity to another archetype. Siblings - the children of one parent, or
/// the roots - have names of their own, another's is `error.NameTaken`, so a
/// path of names leads to one thing; two entities in different places may
/// share one, as two copies of a scene do. A despawned entity's name is free
/// at once, and calling this again renames. The text is copied.
pub fn setName(self: *App, entity: ecs.Entity, name: []const u8) NameError!void {
    return self.names.set(self.gpa, &self.world, entity, name);
}

/// `setName`, where a sibling that has the name already gives this one the
/// first free one after it - "Rock 2" - rather than refusing: what a scene
/// read into a family does, and `setParent`.
pub fn setFreeName(self: *App, entity: ecs.Entity, wanted: []const u8) NameError!void {
    return self.names.setFree(self.gpa, &self.world, entity, wanted);
}

/// `wanted`, or it with the first number after it that no child of
/// `parent` but `except` is called: "Sprite", "Sprite 2", "Sprite 3". Written
/// into `buffer` when a number is added; a name too long for it is cut.
pub fn freeName(self: *const App, parent: ecs.Entity, wanted: []const u8, except: ecs.Entity, buffer: []u8) []const u8 {
    return self.names.freeName(&self.world, parent, wanted, except, buffer);
}

/// What an entity is called, or null when it has no name or is not alive.
/// The text lasts until the entity is renamed or despawned.
pub fn nameOf(self: *const App, entity: ecs.Entity) ?[]const u8 {
    return self.names.of(&self.world, entity);
}

/// A living entity called `name` - the first given it of those that are -
/// or null. Cheap enough to ask every frame. Where two in different places
/// share a name, `findPath` and `findIn` say which. See `setName`.
///
/// ```zig
/// const player = app.find("player") orelse return;
/// ```
pub fn find(self: *const App, name: []const u8) ?ecs.Entity {
    return self.names.find(&self.world, name);
}

/// What `setUuid` can refuse.
pub const UuidError = @import("scene/uuids.zig").UuidError;

/// A new random UUID - version 4 - for an entity, or for anything else a
/// game wants named once and for good.
pub fn newUuid(self: *App) Uuid {
    return self.uuids.new();
}

/// Give an entity this UUID: what it is known by from one save and load to
/// the next, when its handle is new each time. An editor's undo gives an
/// entity it brings back the UUID it had.
///
/// ```zig
/// const door = app.findUuid(door_uuid) orelse return;
/// ```
///
/// Like a name it is the entity's own, not a component, and one living
/// entity has a UUID at a time - another is `error.UuidTaken`. A despawned
/// entity's is free at once. A scene gives every entity it writes one, and
/// every entity it reads the one it had.
pub fn setUuid(self: *App, entity: ecs.Entity, uuid: Uuid) UuidError!void {
    return self.uuids.set(self.gpa, &self.world, entity, uuid);
}

/// An entity's UUID, or null when it has none or is not alive.
pub fn uuidOf(self: *const App, entity: ecs.Entity) ?Uuid {
    return self.uuids.of(&self.world, entity);
}

/// An entity's UUID, made for it now if it has none.
pub fn ensureUuid(self: *App, entity: ecs.Entity) (error{NoSuchEntity} || Allocator.Error)!Uuid {
    return self.uuids.ensure(self.gpa, &self.world, entity);
}

/// The living entity with this UUID, or null.
pub fn findUuid(self: *const App, uuid: Uuid) ?ecs.Entity {
    return self.uuids.find(&self.world, uuid);
}

// -------------------------------------------------------------------------
// Groups
// -------------------------------------------------------------------------
//
// A group is a name entities are put under - "enemies", "pickups" - to be
// found and called together, wherever they are in the tree: see
// `scene/groups.zig`.

/// Put an entity in a group, made the first time it is named. Once is
/// enough: being put in again changes nothing.
pub fn addToGroup(self: *App, entity: ecs.Entity, group: []const u8) (error{NoSuchEntity} || Allocator.Error)!void {
    return self.groups.add(self.gpa, &self.world, entity, group);
}

/// Take an entity out of a group. The group stays, empty.
pub fn removeFromGroup(self: *App, entity: ecs.Entity, group: []const u8) void {
    return self.groups.remove(entity, group);
}

pub fn isInGroup(self: *const App, entity: ecs.Entity, group: []const u8) bool {
    return self.groups.has(entity, group);
}

/// A group's living members, in the order they joined: a slice good until a
/// member joins or leaves. What a script goes through: `for
/// (app.groupMembers("enemies")) |enemy|`, `app.groupMembers("player").first()`.
pub fn groupMembers(self: *App, group: []const u8) []const ecs.Entity {
    return self.groups.members(&self.world, group);
}

/// The groups an entity is in, as many as `found` holds.
pub fn groupsOf(self: *const App, entity: ecs.Entity, found: [][]const u8) [][]const u8 {
    return self.groups.of(entity, found);
}

/// Call a method on every living member of a group, in the order they
/// joined - a component's, the script's, or one `addMethod` added: see
/// `callMethodOn`. A member that has no such method is passed over. The
/// members are copied first, so a call may add to the group or take from it.
pub fn callGroup(self: *App, group: []const u8, method: []const u8) anyerror!void {
    return scene_groups.callAll(self, group, method);
}

// -------------------------------------------------------------------------
// Pause and appearance
// -------------------------------------------------------------------------
//
// What an entity inherits from above it: see `scene/inherited.zig`.

/// Pause the game, or let it go on.
///
/// ```zig
/// app.setPaused(true);
/// try app.world.add(pause_menu, fx.Processing{ .mode = .when_paused });
/// try app.addSystemAlways(.input, "pause key", togglePause);
/// ```
///
/// While it is paused only what asked to run does: an entity whose
/// `Processing` says `.when_paused` or `.always` - and what hangs from it -
/// and the systems added with `addSystemWhenPaused` or `addSystemAlways`.
/// The rest wait where they are: their timers, their scripts' `fixed` and
/// `update`, their tasks, their animation, their controls and the pointer
/// over them, and the game's other systems. The physics stops for
/// everything. Time goes on, unlike with `time.scale` at nought, so a pause
/// menu can fade in.
pub fn setPaused(self: *App, paused: bool) void {
    self.paused = paused;
    self.schedule.paused = paused;
}

pub fn isPaused(self: *const App) bool {
    return self.paused;
}

/// Whether an entity runs now: its `Processing`, or the nearest one above
/// it, against the pause.
pub fn isProcessing(self: *App, entity: ecs.Entity) bool {
    return self.inherited.of(self.gpa, &self.world, entity).processing.runs(self.paused);
}

/// Whether `entity`'s own time moves on now: time passes - the frame's, or
/// in a fixed step the step's - and nothing above it holds it. What a timer,
/// a tween, an animation and a particle emitter ask before they move.
pub fn timeMovesFor(self: *App, entity: ecs.Entity) bool {
    return self.time.delta > 0 and self.isProcessing(entity);
}

/// How an entity shows, everything above it counted: whether it is drawn,
/// the colour its own is multiplied by, and what its layer is raised by.
/// See `Appearance`.
pub fn resolvedAppearance(self: *App, entity: ecs.Entity) ResolvedAppearance {
    return self.inherited.of(self.gpa, &self.world, entity);
}

/// Show an entity and what hangs from it, or hide them: its `Appearance`,
/// given one when it has none. What shows, everything above counted, is
/// `isVisibleInTree`.
pub fn setVisible(self: *App, entity: ecs.Entity, visible: bool) (ecs.World.Error || error{NoSuchEntity})!void {
    if (self.world.get(entity, Appearance)) |held| {
        held.visible = visible;
    } else try self.world.add(entity, Appearance{ .visible = visible });
    self.inherited.forget();
}

/// Whether an entity shows: neither it nor anything above it hidden by its
/// `Appearance`.
pub fn isVisibleInTree(self: *App, entity: ecs.Entity) bool {
    return self.world.isAlive(entity) and self.resolvedAppearance(entity).visible;
}

// -------------------------------------------------------------------------
// Texts
// -------------------------------------------------------------------------
//
// The words components keep beside them: see `scene/component_texts.zig`.

/// What `C`'s text `property` says on `entity`: empty for nothing, or for an
/// entity without it. A component keeps its words beside it, as long as
/// they are - see `scene/component_texts.zig`. The text lasts until it is set again.
///
/// ```zig
/// const said = app.textOf(label, fx.Label, "text");
/// ```
pub fn textOf(self: *const App, entity: ecs.Entity, comptime C: type, comptime property: []const u8) []const u8 {
    return self.texts.get(entity, comptime component_texts.keyFor(C, property));
}

/// Say `text` in `C`'s text `property` on `entity`. `C` has to keep a text of
/// that name - the build says so - and the entity has to be alive.
///
/// ```zig
/// try app.setText(title, fx.Label, "text", "Paused");
/// ```
pub fn setText(self: *App, entity: ecs.Entity, comptime C: type, comptime property: []const u8, text: []const u8) !void {
    if (!self.world.isAlive(entity)) return error.NoSuchEntity;
    try self.texts.set(self.gpa, entity, comptime component_texts.keyFor(C, property), text);
}

/// `setText` with the words formatted: a score, a time.
///
/// ```zig
/// try app.printText(score, fx.Text2D, "text", "{d} points", .{points});
/// ```
pub fn printText(self: *App, entity: ecs.Entity, comptime C: type, comptime property: []const u8, comptime format: []const u8, args: anytype) !void {
    const made = try std.fmt.allocPrint(self.gpa, format, args);
    defer self.gpa.free(made);
    try self.setText(entity, C, property, made);
}

/// `textOf` by names, for what knows a component only by the name a scene
/// gives it: an editor, a script.
pub fn textNamed(self: *const App, entity: ecs.Entity, component: []const u8, property: []const u8) []const u8 {
    return self.texts.get(entity, component_texts.keyOf(component, property));
}

/// `setText` by names. The component has to be registered and keep a text
/// of that name.
pub fn setTextNamed(self: *App, entity: ecs.Entity, component: []const u8, property: []const u8, text: []const u8) !void {
    return component_texts.setNamed(self, entity, component, property, text);
}

// -------------------------------------------------------------------------
// Scenes
// -------------------------------------------------------------------------
//
// A world written down and read back, and scenes made into things and played: see `scene/scene.zig`.

/// Write the world to a file: every entity, its name, and every registered
/// component on it. JSON unless `.format = .cbor`. See `scene`.
pub fn saveScene(self: *App, path: []const u8, options: scene.SaveOptions) !void {
    const io = self.io orelse return error.NoIo;
    return scene.save(self, io, path, options);
}

/// Read the file at `path` into the world, beside whatever is in it
/// already, and say what came of it: what an editor opens a scene with. A
/// game makes things of a scene with `instantiate`, and plays one with
/// `changeScene`. See `scene`.
///
/// ```zig
/// var diagnostics: fx.json.Diagnostics = .{};
/// _ = app.readScene("levels/meadow.json", .{ .diagnostics = &diagnostics }) catch |err| {
///     std.log.err("{f}", .{diagnostics});
///     return err;
/// };
/// ```
pub fn readScene(self: *App, path: []const u8, options: scene.LoadOptions) !scene.Loaded {
    return scene.load(self, path, options);
}

/// Write a scene with nothing in it to `path`: a new level, for an editor to
/// open and fill. Never over a file already there - that is
/// `error.PathAlreadyExists` - and the folder it goes in has to be there.
pub fn createScene(self: *App, path: []const u8, options: scene.SaveOptions) !void {
    return scene.create(self, path, options);
}

/// What the scene at `path` says of itself - its version, its format, how
/// many entities and which files - read without loading it. Null for a file
/// that is not a scene. Free it with `Info.deinit`. See `scene.readInfo`.
pub fn sceneInfo(self: *App, path: []const u8, diagnostics: ?*json.Diagnostics) !?scene.Info {
    return scene.infoOfFile(self, path, diagnostics);
}

/// One instance of a scene: see `instantiate`.
pub const Instance = scene_instances.Instance;

/// A scene made as a thing in the world: its one root, hanging from
/// `parent` - `.none` for the top of the tree - with everything else of the
/// scene under it. What a spawner makes a bat of, or a level a door of.
///
/// ```zig
/// const bat = try app.loadScene("res://enemies/bat.json");
/// const one = try app.instantiate(bat, cave);
/// ```
///
/// Each instance's entities are given UUIDs of their own, made from the
/// instance's and the scene's, so two are never confused and a scene that
/// names one inside an instance finds it again every time it is read. A
/// scene saved with an instance in it writes the instance - the file it is
/// of, and what its root has that the file does not give it - so an edit of
/// the file reaches every instance of it. A scene of more than one root is
/// `error.NotOneRoot`: save its roots under one first.
pub fn instantiate(self: *App, scene_handle: SceneHandle, parent: ecs.Entity) !ecs.Entity {
    return scene_instances.instantiate(self, scene_handle, parent);
}

/// Remember `root` as an instance of `scene_handle`, which made `made`.
pub fn keepInstance(self: *App, root: ecs.Entity, scene_handle: SceneHandle, made: []const ecs.Entity) !void {
    return scene_instances.keep(self, root, scene_handle, made);
}

/// What `root` is an instance of, when it is the root of one.
pub fn instanceOf(self: *const App, root: ecs.Entity) ?*const Instance {
    return self.instances.of(root);
}

/// The root of the instance an entity is inside of, if it is inside one -
/// the outermost, where instances are inside instances. Not for a root
/// itself unless it is inside another.
pub fn instanceHolding(self: *const App, entity: ecs.Entity) ?ecs.Entity {
    return self.instances.holding(&self.world, entity);
}

/// An instance made the scene's own: its insides are written as themselves
/// from now on, and a change to the scene file reaches it no more.
pub fn makeLocal(self: *App, root: ecs.Entity) void {
    return self.instances.makeLocal(self.gpa, root);
}

/// Play another scene from the end of this frame: the one playing goes,
/// with everything that hangs from it, and this is read in its place.
/// What does not belong to the scene - an autoload, what the game spawned
/// at the top of the tree itself - stays. See `openScene`.
///
/// ```zig
/// app.changeScene(try app.loadScene("res://levels/two.json"));
/// ```
pub fn changeScene(self: *App, scene_handle: SceneHandle) void {
    self.current_scene.next = scene_handle;
}

/// `changeScene`, now: before the first frame, or from a tool.
pub fn openScene(self: *App, scene_handle: SceneHandle) !void {
    return playing.open(self, scene_handle);
}

/// The scene the game is playing: what `openScene` or `changeScene` opened
/// last. `.none` before one has.
pub fn currentScene(self: *const App) SceneHandle {
    return self.current_scene.handle;
}

/// The scene the game is playing, from its start again, at the end of the
/// frame: a level restarted. Nothing before a scene is open.
pub fn reloadCurrentScene(self: *App) void {
    if (!self.current_scene.handle.isNone()) self.changeScene(self.current_scene.handle);
}

/// The first entity at the top of the scene the game is playing - the one
/// root of a scene that has one - or `.none` before a scene is open.
pub fn currentSceneRoot(self: *const App) ecs.Entity {
    return self.current_scene.root(&self.world);
}

// -------------------------------------------------------------------------
// Frame time
// -------------------------------------------------------------------------
//
// See `time/frame_time.zig`.

/// Frames a second over the last whole second; nought until one has gone
/// by.
pub fn fps(self: *const App) f32 {
    return self.time.frames_per_second;
}

/// How many frames have gone by since the game started.
pub fn frameCount(self: *const App) u64 {
    return self.time.frame;
}

/// Seconds of game time since the first frame: slowed by `timeScale`, and
/// stopped with it at nought.
pub fn elapsed(self: *const App) f64 {
    return self.time.elapsed;
}

/// How fast game time goes: 1 as it is, 0.5 slow motion, 0 stopped. Every
/// frame's and fixed step's time is multiplied by it; `update`'s `delta`
/// too. A pause is `setPaused`, which stops only what may be paused.
pub fn setTimeScale(self: *App, scale: f32) void {
    self.time.scale = @max(scale, 0);
}

pub fn timeScale(self: *const App) f32 {
    return self.time.scale;
}

/// Hold the frames to at most `fps` a second, nought for no cap: a
/// settings menu's frame limit. `time.max_fps` from Zig.
pub fn setMaxFps(self: *App, limit: f32) void {
    self.time.max_fps = if (limit > 0) limit else null;
}

/// The cap on frames a second, nought for none.
pub fn maxFps(self: *const App) f32 {
    return self.time.max_fps orelse 0;
}

/// Hold the frames to at most `fps` a second while no window of the program
/// has the keyboard, nought for no other cap than `setMaxFps`'s: less work,
/// and less power, for a game nobody is looking at. `time.background_fps`
/// from Zig.
pub fn setBackgroundFps(self: *App, limit: f32) void {
    self.time.background_fps = if (limit > 0) limit else null;
}

/// The cap on frames a second in the background, nought for none.
pub fn backgroundFps(self: *const App) f32 {
    return self.time.background_fps orelse 0;
}

/// The most fixed steps one frame takes to catch up after a slow one.
pub fn setMaxPhysicsStepsPerFrame(self: *App, steps: u32) void {
    self.time.max_fixed_steps = @max(steps, 1);
}

pub fn maxPhysicsStepsPerFrame(self: *const App) u32 {
    return self.time.max_fixed_steps;
}

/// How many fixed steps a second the physics and the fixed systems take.
pub fn setPhysicsTicksPerSecond(self: *App, ticks: u32) void {
    self.time.fixed_delta = 1.0 / @as(f32, @floatFromInt(@max(ticks, 1)));
    if (self.time.source == .fixed) self.time.source = .{ .fixed = self.time.fixed_delta };
}

pub fn physicsTicksPerSecond(self: *const App) u32 {
    return @intFromFloat(@round(1.0 / self.time.fixed_delta));
}

// -------------------------------------------------------------------------
// Clocks, dates and the player's culture
// -------------------------------------------------------------------------
//
// See `time/game_clocks.zig` and `time/datetime.zig`.

/// This moment, on the system's clock. The start of 1970 in an app with no
/// clock, which is what a test has.
pub fn now(self: *const App) datetime.Instant {
    const io = self.io orelse return .{};
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    return .{ .us = @intCast(@divFloor(ns, 1000)) };
}

/// This moment on the system's calendar and clock, in its time zone.
pub fn localNow(self: *const App) datetime.DateTime {
    return self.now().in(.local);
}

/// The culture the game writes dates, times and spans of time in: the one
/// `setLocale` chose, else the project's `internationalization.locale`, else
/// the player's own - with the choices they made in the system's settings.
/// Its names and patterns are the system's: see `platform.culture`.
pub fn culture(self: *App) Allocator.Error!*datetime.Culture {
    const project_tag = if (self.project.settings) |settings| settings.internationalization.locale else "";
    return self.culture_choice.culture(self.gpa, project_tag);
}

/// Write dates and times as `tag` does from now on - `de-DE`, `ja-JP` - or,
/// for an empty one, as the player does.
pub fn setLocale(self: *App, tag: []const u8) Allocator.Error!void {
    return self.culture_choice.choose(self.gpa, tag);
}

/// The tag of the culture the game writes in: `hu-HU`.
pub fn locale(self: *App) Allocator.Error![]const u8 {
    return (try self.culture()).tag;
}

/// A clock of the game's own, running at `options.rate` from
/// `options.start`. See `time/game_clocks.zig`.
pub fn newClock(self: *App, options: game_clocks.Options) Allocator.Error!game_clocks.ClockHandle {
    return self.clocks.add(self.gpa, options);
}

pub fn removeClock(self: *App, clock: game_clocks.ClockHandle) void {
    self.clocks.remove(clock);
}

/// What the clock shows; null for one taken away.
pub fn clockTime(self: *App, clock: game_clocks.ClockHandle) ?datetime.DateTime {
    const held = self.clocks.get(clock) orelse return null;
    return held.time();
}

/// Set the clock to show `time`'s fields, whatever its zone.
pub fn setClockTime(self: *App, clock: game_clocks.ClockHandle, time: datetime.DateTime) void {
    const held = self.clocks.get(clock) orelse return;
    held.setTime(time);
}

pub fn clockRate(self: *App, clock: game_clocks.ClockHandle) f64 {
    const held = self.clocks.get(clock) orelse return 0;
    return held.rate;
}

/// Seconds of the clock a real second: 60 is a minute a second.
pub fn setClockRate(self: *App, clock: game_clocks.ClockHandle, rate: f64) void {
    const held = self.clocks.get(clock) orelse return;
    held.rate = @max(rate, 0);
}

pub fn pauseClock(self: *App, clock: game_clocks.ClockHandle) void {
    const held = self.clocks.get(clock) orelse return;
    held.paused = true;
}

pub fn resumeClock(self: *App, clock: game_clocks.ClockHandle) void {
    const held = self.clocks.get(clock) orelse return;
    held.paused = false;
}

pub fn isClockPaused(self: *App, clock: game_clocks.ClockHandle) bool {
    const held = self.clocks.get(clock) orelse return true;
    return held.paused;
}

/// The minutes, hours and days that turned over on the clock in the last
/// frame.
pub fn clockPassed(self: *App, clock: game_clocks.ClockHandle) game_clocks.Passed {
    const held = self.clocks.get(clock) orelse return .{};
    return held.passed;
}

// -------------------------------------------------------------------------
// Keys and the pointer
// -------------------------------------------------------------------------
//
// See `input/input.zig`.

/// Whether a key is held: `app.keyDown(.w)`.
pub fn keyDown(self: *const App, key: platform.Key) bool {
    return self.input.isDown(key);
}

/// -1, 0 or 1 from two keys: `app.keyAxis(.a, .d)`.
pub fn keyAxis(self: *const App, negative: platform.Key, positive: platform.Key) f32 {
    return self.input.keyAxis(negative, positive);
}

/// Whether a key went down this frame - in a `fixed` hook, since the last
/// fixed step.
pub fn keyJustPressed(self: *const App, key: platform.Key) bool {
    return self.input.justPressed(key);
}

/// Whether a key came up this frame, or since the last fixed step.
pub fn keyJustReleased(self: *const App, key: platform.Key) bool {
    return self.input.justReleased(key);
}

/// Whether a mouse button is held: `app.mouseButtonDown(.left)`.
pub fn mouseButtonDown(self: *const App, button: platform.MouseButton) bool {
    return self.input.buttonDown(button);
}

/// Whether a mouse button went down this frame, or since the last fixed
/// step.
pub fn mouseButtonJustPressed(self: *const App, button: platform.MouseButton) bool {
    return self.input.buttonJustPressed(button);
}

/// Whether a mouse button came up this frame, or since the last fixed step.
pub fn mouseButtonJustReleased(self: *const App, button: platform.MouseButton) bool {
    return self.input.buttonJustReleased(button);
}

/// Where the pointer is in the world.
pub fn pointerInWorld(self: *App) math.Vec2 {
    return self.screenToWorld(self.input.pointer.x, self.input.pointer.y);
}

/// Where the pointer is on the screen: in the frame's pixels from its top
/// left, `y` down - what an input event's `position` says, and what
/// `screenToWorld` takes. Where it was last, once it has left the window.
pub fn pointerOnScreen(self: *const App) math.Vec2 {
    return .init(self.input.pointer.x, self.input.pointer.y);
}

/// Where the pointer is in an entity's own space. Null for an entity that
/// is not there, or whose chain of parents is broken.
///
/// ```zig
/// const at = app.pointerIn(dial) orelse return;
/// dial_angle = std.math.atan2(at.y, at.x);
/// ```
pub fn pointerIn(self: *App, entity: ecs.Entity) ?math.Vec2 {
    return self.toLocal(entity, self.pointerInWorld());
}

/// A pointer event as an entity sees it: the same event, with its place in
/// that entity's own space rather than the window's. A key's and a
/// controller's are as they are.
pub fn localEvent(self: *App, entity: ecs.Entity, event: InputEvent) InputEvent {
    const place = event.position() orelse return event;
    const at = self.screenToWorld(place.x, place.y);
    const local = self.toLocal(entity, at) orelse return event;
    return event.at(local);
}

/// Put the pointer there, in the pixels `pointerOnScreen` gives: the
/// frame's, which a stretched game's window shows bigger or beside bars.
/// The system takes a moment to say it moved, so `input.pointer` is set here
/// as well. Nothing without a window, save moving what a test reads.
pub fn warpPointer(self: *App, x: f32, y: f32) void {
    if (self.window) |*window| {
        const ratio = if (self.input.frame_ratio > 0) self.input.frame_ratio else 1;
        window.setCursorPos(x / ratio + self.input.frame_origin.x, y / ratio + self.input.frame_origin.y) catch |err| {
            log.warn("could not put the pointer at {d},{d}: {t}", .{ x, y, err });
            return;
        };
    }
    self.input.pointer.x = x;
    self.input.pointer.y = y;
}

/// Take the event a script's `input` or `unhandled_input` is handling: the
/// scripts after it do not hear it, nor does any `unhandled_input`.
pub fn setInputAsHandled(self: *App) void {
    if (self.scripts) |scripts| scripts.input_handled = true;
    // And from an object's `input_event`, the objects under it do not hear
    // it either.
    self.picking.taken = true;
}

// -------------------------------------------------------------------------
// Fingers
// -------------------------------------------------------------------------

/// How many fingers this frame has: every one down, and every one lifted
/// this frame. See `Input.touches`.
pub fn touchCount(self: *const App) usize {
    return self.input.touches().len;
}

/// This frame's `index`th finger, in the order they touched; null past the
/// last.
///
/// ```
/// for (0..app.touchCount()) |i| {
///     const finger = app.touchAt(i).?;
///     if (finger.pressed) spark(app.screenToWorld(finger.position.x, finger.position.y));
/// }
/// ```
pub fn touchAt(self: *const App, index: usize) ?Input.Touch {
    const all = self.input.touches();
    return if (index < all.len) all[index] else null;
}

/// A finger of this frame by its number; null for none.
pub fn touchOf(self: *const App, finger: u32) ?Input.Touch {
    return self.input.touchOf(finger);
}

/// How many fingers are down now.
pub fn fingersDown(self: *const App) usize {
    return self.input.fingersDown();
}

/// What two fingers did this frame: how much they spread, how far they
/// moved together and how much they turned - a camera zoomed, dragged and
/// turned by two fingers. `active` is false with fewer down.
///
/// ```
/// const two = app.twoFingers();
/// if (two.active) {
///     camera.zoom *= two.factor;
///     place.x -= two.relative.x / camera.zoom;
/// }
/// ```
pub fn twoFingers(self: *const App) Input.TwoFingers {
    return self.input.gestures.two_fingers;
}

/// Whether this is a touch screen: Android, or a screen a finger has
/// touched. What a game asks before it shows its touch buttons.
pub fn hasTouchscreen(self: *const App) bool {
    return self.input.touchscreen;
}

/// Whether the first finger is the mouse as well: the project's
/// `touch.mouse_from_touch`. Off, a finger moves no pointer and presses no
/// button, and the interface is for the mouse alone.
pub fn setMouseFromTouch(self: *App, on: bool) void {
    self.input.mouse_from_touch = on;
}

pub fn mouseFromTouch(self: *const App) bool {
    return self.input.mouse_from_touch;
}

/// Whether the left mouse button is a finger as well: the project's
/// `touch.touch_from_mouse`, to try a game made for a touch screen with a
/// mouse.
pub fn setTouchFromMouse(self: *App, on: bool) void {
    self.input.touch_from_mouse = on;
}

pub fn touchFromMouse(self: *const App) bool {
    return self.input.touch_from_mouse;
}

/// Whether a wheel turned with Ctrl is a `PinchEvent` as well, at the
/// pointer: the project's `touch.pinch_from_ctrl_wheel`. A laptop
/// touchpad's pinch is that on Windows and in a browser.
pub fn setPinchFromCtrlWheel(self: *App, on: bool) void {
    self.input.pinch_from_ctrl_wheel = on;
}

pub fn pinchFromCtrlWheel(self: *const App) bool {
    return self.input.pinch_from_ctrl_wheel;
}

// -------------------------------------------------------------------------
// Controllers
// -------------------------------------------------------------------------

/// One controller slot, or every connected controller for null.
fn padOf(self: *const App, pad: ?u8) Input.Pad {
    return self.input.padOrAny(pad);
}

/// The controller slots something is plugged into, from nought: for a game
/// with a player to each.
pub fn connectedPads(self: *App) []const u8 {
    return self.input.connectedPads(&self.connected_pads);
}

/// Whether a controller is plugged into the slot, or any for null.
pub fn padConnected(self: *const App, pad: ?u8) bool {
    return self.padOf(pad).connected();
}

/// Whether a controller's button is held: `app.padButtonDown(.a)` on any
/// controller, `app.padButtonDown(.a, 1)` on the second.
pub fn padButtonDown(self: *const App, button: platform.GamepadButton, pad: ?u8) bool {
    return self.padOf(pad).down(button);
}

/// Whether it went down this frame, or since the last fixed step.
pub fn padButtonJustPressed(self: *const App, button: platform.GamepadButton, pad: ?u8) bool {
    return self.padOf(pad).justPressed(button);
}

/// Whether it came up this frame, or since the last fixed step.
pub fn padButtonJustReleased(self: *const App, button: platform.GamepadButton, pad: ?u8) bool {
    return self.padOf(pad).justReleased(button);
}

/// One axis of a controller, its dead zone taken out: a stick's from -1 to
/// 1, up negative, a trigger's from 0 to 1.
pub fn padAxis(self: *const App, axis: platform.GamepadAxis, pad: ?u8) f32 {
    return self.padOf(pad).axis(axis);
}

/// A stick, its dead zone taken out and no longer than one; up negative.
pub fn padStick(self: *const App, side: Input.Side, pad: ?u8) math.Vec2 {
    return self.padOf(pad).stick(side);
}

/// Teach the platform controllers it does not know, from text in SDL's
/// `gamecontrollerdb.txt` format, and say how many lines it took. Most
/// controllers never need it. Nothing without a window.
pub fn addGamepadMappings(self: *App, text: []const u8) Window.Error!usize {
    const window = if (self.window) |*w| w else return 0;
    return window.ctx.updateGamepadMappings(text);
}

// -------------------------------------------------------------------------
// Actions
// -------------------------------------------------------------------------
//
// See `input/actions.zig`.

/// `input.actionDown`, for a script: whether the action is down.
pub fn actionDown(self: *const App, name: []const u8) bool {
    return self.input.actionDown(name);
}

/// `input.actionJustPressed`: whether it went down this frame, or since the
/// last fixed step inside `fixed`.
pub fn actionJustPressed(self: *const App, name: []const u8) bool {
    return self.input.actionJustPressed(name);
}

pub fn actionJustReleased(self: *const App, name: []const u8) bool {
    return self.input.actionJustReleased(name);
}

/// How far down the action is, from nought to one.
pub fn actionStrength(self: *const App, name: []const u8) f32 {
    return self.input.actionStrength(name);
}

/// Two actions as one axis, from -1 to 1.
pub fn actionAxis(self: *const App, negative: []const u8, positive: []const u8) f32 {
    return self.input.actionAxis(negative, positive);
}

/// Four actions as a direction no longer than one, up negative.
pub fn actionVector(self: *const App, left: []const u8, right: []const u8, up: []const u8, down: []const u8) math.Vec2 {
    return self.input.actionVector(left, right, up, down);
}

/// Hold an action down from code, at `strength` from nought to one, until
/// `releaseAction`: a button on a touch screen.
pub fn pressAction(self: *App, name: []const u8, strength: f32) error{NoSuchAction}!void {
    return self.input.pressAction(name, strength);
}

pub fn releaseAction(self: *App, name: []const u8) error{NoSuchAction}!void {
    return self.input.releaseAction(name);
}

/// What the player presses for an action, in words - `Space`, `Pad A` - on
/// what they last used. See `Input.describeAction`.
pub fn describeAction(self: *App, name: []const u8) []const u8 {
    return self.input.describeAction(&self.described, name);
}

/// One more input for an action: the key, mouse button or controller
/// button an event is - what a settings menu rebinds with, from the
/// `input` that caught the player's next press. Kept with `saveInputMap`.
pub fn bindAction(self: *App, name: []const u8, event: InputEvent) !void {
    const binding = event.binding() orelse return error.NotAnInput;
    try self.input.actions.bind(self.gpa, name, binding);
}

/// Take every input off an action, to give it new ones with `bindAction`.
/// Says whether there is one of that name.
pub fn clearAction(self: *App, name: []const u8) bool {
    return self.input.actions.unbindAll(name);
}

/// Keep what the player changed of the actions in a file of its own - as
/// `user://input.json` - to read back with `loadInputMap`. Written whole or
/// not at all.
pub fn saveInputMap(self: *App, path: []const u8) !void {
    const text = try self.input.actions.write(self.gpa);
    defer self.gpa.free(text);
    try self.writeText(path, text);
}

/// Take what a file `saveInputMap` wrote says of the game's actions. False
/// when there is no file yet - the first run - and the actions stay as the
/// project has them. An action the game no longer has is passed over.
pub fn loadInputMap(self: *App, path: []const u8) !bool {
    const text = self.readText(self.gpa, path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer self.gpa.free(text);
    var diagnostics: json.Diagnostics = .{};
    _ = self.input.actions.read(self.gpa, text, &diagnostics) catch |err| {
        if (err != error.OutOfMemory) log.warn("{s}: {f}", .{ path, diagnostics });
        return err;
    };
    return true;
}

// -------------------------------------------------------------------------
// Physics
// -------------------------------------------------------------------------
//
// Bodies, rays, pushes and what areas hold: see `physics/`.

/// The body an entity is, or is part of, to push: its `RigidBody2D`'s, or
/// the one its `Collider2D` belongs to. Bodies are made at the top of each
/// frame and before each fixed step, so this is null until then - see
/// `syncBodies`. The pointer lasts until the next body is made.
///
/// ```zig
/// if (app.bodyOf(player)) |body| body.applyImpulse(.init(0, -300 * body.mass), body.center);
/// ```
pub fn bodyOf(self: *App, entity: ecs.Entity) ?*fluxion_physics.Body {
    return self.physics.body(self.bodies.idOf(entity) orelse return null);
}

/// The handle of the same body, for `physics.createJoint`.
pub fn bodyIdOf(self: *const App, entity: ecs.Entity) ?fluxion_physics.BodyId {
    return self.bodies.idOf(entity);
}

/// Make, change and take away bodies to match the components now, not at
/// the next frame or step: for joining two things just spawned.
pub fn syncBodies(self: *App) !void {
    try self.bodies.sync(self);
}

/// A kick: the body's velocity changed at once by `impulse` over its mass -
/// a jump, a bullet, an explosion. At `offset` from its middle, in the
/// world's directions, it turns too. Only a dynamic body moves.
pub fn applyImpulse(self: *App, body: ecs.Entity, impulse: math.Vec2, offset: math.Vec2) error{ NotABody, OutOfMemory }!void {
    return forces.applyImpulse(self, body, impulse, offset);
}

/// A push for the next physics step, at `offset` from the body's middle: a
/// thruster, wind. Given again every step it keeps pushing - from `fixed`.
pub fn applyForce(self: *App, body: ecs.Entity, force: math.Vec2, offset: math.Vec2) error{ NotABody, OutOfMemory }!void {
    return forces.applyForce(self, body, force, offset);
}

/// A turning push for the next physics step, clockwise on screen.
pub fn applyTorque(self: *App, body: ecs.Entity, torque: f32) error{ NotABody, OutOfMemory }!void {
    return forces.applyTorque(self, body, torque);
}

/// A turning kick: the spin changed at once.
pub fn applyTorqueImpulse(self: *App, body: ecs.Entity, impulse: f32) error{ NotABody, OutOfMemory }!void {
    return forces.applyTorqueImpulse(self, body, impulse);
}

/// The first collider on the line from `from` to `to` whose filter agrees
/// with `filter`; `.{}` agrees with everything.
pub fn castRay(self: *App, from: math.Vec2, to: math.Vec2, mask: u32, hit_areas: bool) ?Bodies.RayHit {
    return self.bodies.castRay(self, from, to, .{ .filter = .{ .category = 0xFFFF_FFFF, .mask = mask }, .sensors = hit_areas });
}

/// Ask a `RayCast2D` now rather than at the next physics step: after
/// moving it, or turning it on.
pub fn forceRaycastUpdate(self: *App, entity: ecs.Entity) void {
    return ray_casts.update(self, entity);
}

/// Whether an entity stands on a floor: something facing up under the bottom
/// of its collider, no further below it than `distance`. A floor under the
/// middle of the bottom, or under either end of it, counts, so a body half
/// over an edge still stands; the bottom is the collider's as the physics
/// holds it, so a turned body stands on whatever corner is lowest.
///
/// The rays start a little inside the body: one resting on a floor has sunk
/// the physics' slop into it, and a ray that starts inside the floor finds
/// nothing of it.
pub fn isOnFloor(self: *App, entity: ecs.Entity, distance: f32) bool {
    return ray_casts.isOnFloor(self, entity, distance);
}

/// A collider under a point.
pub fn overlapPoint(self: *App, point: math.Vec2) ?ecs.Entity {
    return self.bodies.overlapPoint(self, point);
}

/// The colliders whose bounding boxes overlap the box between two corners,
/// as many as `found` holds.
pub fn overlapBox(self: *App, min: math.Vec2, max: math.Vec2, found: []ecs.Entity) []ecs.Entity {
    return self.bodies.overlapBox(self, min, max, found);
}

/// The contacts that began in this frame's steps, each once however many
/// steps ran - or, in a `.fixed` system, in the step before this one.
///
/// ```zig
/// for (app.contactsBegun()) |contact| {
///     if (contact.other(player)) |thing| if (app.world.has(thing, Coin)) collect(app, thing);
/// }
/// ```
pub fn contactsBegun(self: *const App) []const Bodies.Contact {
    return self.bodies.began(self.input.clock == .fixed);
}

/// The same for contacts that ended - including because one of the two was
/// despawned, so the entity named may be dead.
pub fn contactsEnded(self: *const App) []const Bodies.Contact {
    return self.bodies.ended(self.input.clock == .fixed);
}

/// Keep two bodies from touching whatever their layers say. Each is a
/// `RigidBody2D` or a collider that is a static body of its own. Counted, so two calls take two
/// removals, and gone with either entity.
pub fn addCollisionExceptionWith(self: *App, a: ecs.Entity, b: ecs.Entity) Bodies.ExceptionError!void {
    return self.bodies.addException(self, a, b);
}

/// Take one `addCollisionExceptionWith` back.
pub fn removeCollisionExceptionWith(self: *App, a: ecs.Entity, b: ecs.Entity) void {
    self.bodies.removeException(self, a, b);
}

/// The bodies `body` is kept from touching, as many as `found` holds.
pub fn collisionExceptionsOf(self: *App, body: ecs.Entity, found: []ecs.Entity) []ecs.Entity {
    return self.bodies.exceptionsOf(body, found);
}

/// Whose collision object a collider is a shape of: the body or area that
/// owns it, and what an area's signals name. The collider's own entity when
/// that has an `Area2D` or a `RigidBody2D`, else the nearest one above it
/// that has, else its own entity, which is its own static body. Null for an
/// entity that is neither.
pub fn collisionObjectOf(self: *App, collider: ecs.Entity) ?ecs.Entity {
    return Bodies.objectOf(&self.world, collider);
}

/// The bodies inside `area` now: a list good until the next such question.
/// Empty, with a word in the log, for an area that is not monitoring.
pub fn overlappingBodies(self: *App, area: ecs.Entity) Allocator.Error![]const ecs.Entity {
    return self.areas.overlappingList(self, area, false);
}

/// The other areas inside `area` now, good until the next such question.
pub fn overlappingAreas(self: *App, area: ecs.Entity) Allocator.Error![]const ecs.Entity {
    return self.areas.overlappingList(self, area, true);
}

/// Whether any body at all is inside `area`.
pub fn hasOverlappingBodies(self: *App, area: ecs.Entity) bool {
    return self.areas.any(self, area, false);
}

/// Whether another area is inside it.
pub fn hasOverlappingAreas(self: *App, area: ecs.Entity) bool {
    return self.areas.any(self, area, true);
}

/// Whether that body is inside it.
pub fn overlapsBody(self: *App, area: ecs.Entity, body: ecs.Entity) bool {
    return self.areas.overlaps(self, area, body);
}

/// Whether that area is inside it.
pub fn overlapsArea(self: *App, area: ecs.Entity, other: ecs.Entity) bool {
    return self.areas.overlaps(self, area, other);
}

// -------------------------------------------------------------------------
// Characters
// -------------------------------------------------------------------------
//
// See `physics/character.zig`.

/// Move a `CharacterBody2D` by its velocity for this step - `time.delta` -
/// stopping at what it meets and sliding along it, and say what it stands
/// on and is against in its fields after. Whether anything stopped it. See
/// `physics/character.zig`.
pub fn moveAndSlide(self: *App, entity: ecs.Entity) character.Error!bool {
    return character.moveAndSlide(self, entity);
}

/// Move a `CharacterBody2D` once, by `motion`, stopping `safe_margin` short
/// of the first thing in the way: what that was, or null for nothing.
pub fn moveAndCollide(self: *App, entity: ecs.Entity, motion: math.Vec2) character.Error!?character.Collision {
    return character.moveAndCollide(self, entity, motion);
}

/// How many things a character's last `moveAndSlide` met: a wall, then the
/// floor it slid down onto.
pub fn slideCollisionCount(self: *const App, entity: ecs.Entity) u32 {
    return @intCast(self.slide_collisions.of(entity).len);
}

/// The one it met `index`th, in order; null past the end. What a character
/// pushes a crate by: `app.slideCollision(player, 0).?.collider`.
pub fn slideCollision(self: *const App, entity: ecs.Entity, index: u32) ?character.Collision {
    const met = self.slide_collisions.of(entity);
    return if (index < met.len) met[index] else null;
}

/// The last it met, or null for none.
pub fn lastSlideCollision(self: *const App, entity: ecs.Entity) ?character.Collision {
    const met = self.slide_collisions.of(entity);
    return if (met.len > 0) met[met.len - 1] else null;
}

// -------------------------------------------------------------------------
// Sound
// -------------------------------------------------------------------------
//
// See `audio/audio.zig`.

/// How long a sound is, in seconds: from Flux, `app.audioLength("res://door.ogg")`.
pub fn audioLength(self: *App, clip: sound.AudioClipHandle) f32 {
    const held = self.audio.get(clip) orelse return 0;
    return @floatCast(held.info.seconds());
}

/// Turn the bus called `name` up or down, in decibels. False for a bus the
/// project has not.
pub fn setBusVolumeDb(self: *App, name: []const u8, db: f32) bool {
    return self.audio.setBusVolumeDb(name, db);
}

/// A bus's volume in decibels; `audio.silent_db` for one there is not.
pub fn busVolumeDb(self: *App, name: []const u8) f32 {
    return self.audio.busVolumeDb(name) orelse sound.silent_db;
}

pub fn setBusMute(self: *App, name: []const u8, mute: bool) bool {
    return self.audio.setBusMute(name, mute);
}

pub fn isBusMuted(self: *App, name: []const u8) bool {
    return self.audio.isBusMuted(name);
}

/// A slider's 0 to 1 as decibels, and back: `app.setBusVolumeDb("Music",
/// app.linearToDb(slider.value))`.
pub fn linearToDb(self: *const App, linear: f32) f32 {
    _ = self;
    return sound.linearToDb(linear);
}

pub fn dbToLinear(self: *const App, db: f32) f32 {
    _ = self;
    return sound.dbToLinear(db);
}

// -------------------------------------------------------------------------
// Tweens and animations
// -------------------------------------------------------------------------
//
// See `animation/tween.zig` and `animation/animation.zig`.

/// A tween: an entity of its own, hanging from `owner` - `.none` for the
/// top of the tree - whose steps move properties over time, and which goes
/// once it is done. See `animation/tween.zig`.
pub fn tween(self: *App, owner: ecs.Entity) !ecs.Entity {
    return tweening.make(self, owner);
}

/// A step of `tween_entity`: the property `path` of `moved` - see
/// `reflect/property.zig` - moved from what it holds when the step starts to `to`,
/// over `seconds`.
pub fn tweenProperty(self: *App, tween_entity: ecs.Entity, moved: ecs.Entity, path: []const u8, to: PropertyValue, seconds: f32) !void {
    return tweening.addProperty(self, tween_entity, moved, path, to, seconds);
}

/// A step that waits `seconds`.
pub fn tweenInterval(self: *App, tween_entity: ecs.Entity, seconds: f32) !void {
    return tweening.addInterval(self, tween_entity, seconds);
}

/// The steps added after this start together with the one before them,
/// rather than after it.
pub fn tweenParallel(self: *App, tween_entity: ecs.Entity, together: bool) !void {
    return tweening.setParallel(self, tween_entity, together);
}

/// The curve the steps added after this move by: `.linear`, `.quad_out`,
/// `.back_in`, `.elastic_out`, ...
pub fn tweenEase(self: *App, tween_entity: ecs.Entity, ease: math.ease.Kind) !void {
    return tweening.setEase(self, tween_entity, ease);
}

/// A step that calls a script's function when it is reached: a sound when
/// a panel is in, a door shut at the end. `t.tweenCallback(self.shut)`.
pub fn tweenCallback(self: *App, tween_entity: ecs.Entity, function: flux.Value) !void {
    return tweening.addCallback(self, tween_entity, function);
}

/// A step that calls a script's function with each value from `from` to
/// `to` over `seconds`, along the curve: a score counted up, a colour a
/// shader is given.
pub fn tweenMethod(self: *App, tween_entity: ecs.Entity, function: flux.Value, from: PropertyValue, to: PropertyValue, seconds: f32) !void {
    return tweening.addMethod(self, tween_entity, function, from, to, seconds);
}

/// The step added last starts from `from`, rather than from what its
/// property holds when it starts: a fade in from nothing.
pub fn tweenFrom(self: *App, tween_entity: ecs.Entity, from: PropertyValue) !void {
    return tweening.startFrom(self, tween_entity, from);
}

/// The step added last moves by its value from where it starts, rather than
/// to it: forty to the right of wherever it is.
pub fn tweenRelative(self: *App, tween_entity: ecs.Entity) !void {
    return tweening.makeRelative(self, tween_entity);
}

/// The step added last waits `seconds` before it starts.
pub fn tweenDelay(self: *App, tween_entity: ecs.Entity, seconds: f32) !void {
    return tweening.setDelay(self, tween_entity, seconds);
}

/// The animations an `AnimationPlayer`'s library holds, in its order: a list
/// good until the next such question.
pub fn animationNames(self: *App, player: ecs.Entity) Allocator.Error![]const []const u8 {
    return self.animation_libraries.namesOf(self.gpa, &self.world, player);
}

/// Whether an `AnimationPlayer`'s library has an animation of that name.
pub fn hasAnimation(self: *App, player: ecs.Entity, name: []const u8) bool {
    return self.animation_libraries.ofPlayer(&self.world, player, name) != null;
}

/// How many seconds an animation of an `AnimationPlayer` lasts; nought for
/// one it has not.
pub fn animationLength(self: *App, player: ecs.Entity, name: []const u8) f32 {
    return if (self.animation_libraries.ofPlayer(&self.world, player, name)) |found| found.length else 0;
}

// -------------------------------------------------------------------------
// Drawing
// -------------------------------------------------------------------------
//
// Shapes a game draws in an entity's own space, kept until it draws again:
// see `render/drawing.zig`. Each call adds to the entity's picture, giving
// it a `Drawing2D` when it has none.

/// What can go wrong drawing: the entity is gone, or there is no room.
pub const DrawError = drawing.DrawError;

/// A straight line `width` wide.
pub fn drawLine(self: *App, entity: ecs.Entity, from: math.Vec2, to: math.Vec2, color: Color, width: f32) DrawError!void {
    return drawing.drawLine(self, entity, from, to, color, width);
}

/// A box from `position`, `size` big: filled, or its edges `width` wide.
pub fn drawRect(self: *App, entity: ecs.Entity, position: math.Vec2, size: math.Vec2, color: Color, filled: bool, width: f32) DrawError!void {
    return drawing.drawRect(self, entity, position, size, color, filled, width);
}

/// A circle: filled, or its edge `width` wide.
pub fn drawCircle(self: *App, entity: ecs.Entity, center: math.Vec2, radius: f32, color: Color, filled: bool, width: f32) DrawError!void {
    return drawing.drawCircle(self, entity, center, radius, color, filled, width);
}

/// Part of a circle's edge, from `start_angle` round to `end_angle`, in
/// radians clockwise on screen from the right.
pub fn drawArc(self: *App, entity: ecs.Entity, center: math.Vec2, radius: f32, start_angle: f32, end_angle: f32, color: Color, width: f32) DrawError!void {
    return drawing.drawArc(self, entity, center, radius, start_angle, end_angle, color, width);
}

/// Lines joining the points in turn: a path, a graph.
pub fn drawPolyline(self: *App, entity: ecs.Entity, points: []const math.Vec2, color: Color, width: f32) DrawError!void {
    return drawing.drawPolyline(self, entity, points, color, width);
}

/// The shape the points go round, filled: any shape whose sides do not
/// cross, either way round.
pub fn drawPolygon(self: *App, entity: ecs.Entity, points: []const math.Vec2, color: Color) DrawError!void {
    return drawing.drawPolygon(self, entity, points, color);
}

/// A picture from `position`, `size` big - its own size for nought - its
/// colours multiplied by `modulate`.
pub fn drawTexture(self: *App, entity: ecs.Entity, texture: Assets.TextureHandle, position: math.Vec2, size: math.Vec2, modulate: Color) DrawError!void {
    return drawing.drawTexture(self, entity, texture, position, size, modulate);
}

/// Words, their first line's top left at `position`, `size` pixels high in
/// `font` - the first one loaded for none.
pub fn drawText(self: *App, entity: ecs.Entity, text: []const u8, position: math.Vec2, color: Color, size: f32, font: Assets.FontHandle) DrawError!void {
    return drawing.drawText(self, entity, text, position, color, size, font);
}

/// Everything an entity has drawn taken away.
pub fn clearDrawing(self: *App, entity: ecs.Entity) void {
    return drawing.clearDrawing(self, entity);
}

/// Ask an entity's script to draw it again - its `draw(self)`, on an
/// emptied picture - at the end of this frame.
pub fn queueRedraw(self: *App, entity: ecs.Entity) DrawError!void {
    return drawing.queueRedraw(self, entity);
}

// -------------------------------------------------------------------------
// Particles
// -------------------------------------------------------------------------
//
// See `render/particles.zig`.

/// Start an emitter's cycle again from its beginning, every particle gone,
/// and emitting: a one-shot's burst again. See `render/particles.zig`.
pub fn restartParticles(self: *App, emitter: ecs.Entity) particle_emitters.Error!void {
    try particle_emitters.restart(self, emitter);
}

/// `count` particles let go of at once, over and above an emitter's cycle:
/// the sparks of a hit.
pub fn emitParticles(self: *App, emitter: ecs.Entity, count: u32) particle_emitters.Error!void {
    try particle_emitters.burst(self, emitter, count);
}

/// How many of an emitter's particles are alive now.
pub fn particleCount(self: *App, emitter: ecs.Entity) u32 {
    const held = self.particles.get(emitter) orelse return 0;
    return @intCast(held.aliveCount());
}

// -------------------------------------------------------------------------
// Materials
// -------------------------------------------------------------------------
//
// The numbers each `Material` gives its shader: see `render/shaders.zig`.

/// Give `entity`'s material a number for its shader's field `name`: one
/// float, or one per component of a vector, a matrix's column by column.
/// None gives it back what the file says.
pub fn setShaderParam(self: *App, entity: ecs.Entity, name: []const u8, numbers: []const f32) !void {
    if (!self.world.isAlive(entity)) return error.NoSuchEntity;
    try self.shader_params.set(self.gpa, entity, name, numbers);
}

/// What `entity`'s material gives its shader's field `name`, or null when it
/// gives what the file says.
pub fn shaderParam(self: *App, entity: ecs.Entity, name: []const u8) ?[]const f32 {
    return self.shader_params.get(entity, name);
}

/// The field `name` of `entity`'s material's shader, or null for none: one
/// its shader has not, or a shader that did not compile.
pub fn shaderParamField(self: *App, entity: ecs.Entity, name: []const u8) ?shading.material.Field {
    return shading.paramField(self, entity, name);
}

/// What `entity`'s material gives its shader's field `name` - its own, or
/// else the file's - as the floats `shaders.pack` puts in the buffer, into
/// `out`. Null for a field its shader does not have.
pub fn shaderParamOrDefault(self: *App, entity: ecs.Entity, name: []const u8, out: *[16]f32) ?[]const f32 {
    return shading.paramOrDefault(self, entity, name, out);
}

// -------------------------------------------------------------------------
// Cameras and the screen
// -------------------------------------------------------------------------
//
// See `render/cameras.zig`.

/// What the camera sees, at the frame's size and scale: the view the world
/// is drawn through and the pointer is found in.
pub fn currentView(self: *App) View {
    return cameras.currentView(self);
}

/// The camera the screen looks through: the active one with the highest
/// priority that draws no picture of its own, or null for none.
pub fn currentCamera(self: *App) ?ecs.Entity {
    return cameras.currentCamera(self);
}

/// What a camera shows of the world: through it at the game's size - or,
/// for one that draws a picture of its own, at the picture's.
pub fn cameraView(self: *App, entity: ecs.Entity) ?View {
    return cameras.viewOf(self, entity);
}

/// The corners of what a camera shows, in the world, clockwise from the
/// screen's top left: a frame an editor draws round it.
pub fn cameraCorners(self: *App, entity: ecs.Entity) ?[4]math.Vec2 {
    return cameras.cornersOf(self, entity);
}

/// Where the middle of what a camera shows is in the world: after its
/// offset, its smoothing and its limits.
pub fn screenCenter(self: *App, camera: ecs.Entity) ?math.Vec2 {
    return cameras.screenCenter(self, camera);
}

/// Put a smoothed camera where it is at once: after a teleport, a new
/// level.
pub fn resetSmoothing(self: *App, camera: ecs.Entity) void {
    return cameras.resetSmoothing(self, camera);
}

/// Where a point on the screen is in the world, through the camera.
///
/// ```zig
/// const aim = app.screenToWorld(app.input.pointer.x, app.input.pointer.y);
/// ```
///
/// The screen is in framebuffer pixels from the top left, `y` down. The
/// camera is read as it is now - before `.late`, the one the player clicked
/// through. See `render.view`.
pub fn screenToWorld(self: *App, x: f32, y: f32) math.Vec2 {
    return self.currentView().toWorld(.init(x, y));
}

/// Where a point in the world lands on the screen, in framebuffer pixels. Not
/// clamped: a point off the screen comes back outside the window.
pub fn worldToScreen(self: *App, x: f32, y: f32) math.Vec2 {
    return self.currentView().toScreen(.init(x, y));
}

/// How big the screen is in those pixels: the frame the camera shows and
/// the interface is laid out in. With the project's stretch it is the size
/// the game is made at, grown to the window's shape; without one, the
/// window's. What a pointer's place is measured against:
///
/// ```flux
/// const across = app.pointerOnScreen().x / app.screenSize().x; // 0 at the left, 1 at the right
/// ```
pub fn screenSize(self: *const App) math.Vec2 {
    return .init(@floatFromInt(self.frame.width), @floatFromInt(self.frame.height));
}

/// The size the game is made at: the project's `display.width` and
/// `height`, what its interface is laid out in at its first size - or the
/// window's, with no project.
pub fn gameSize(self: *const App) [2]f32 {
    if (self.project.settings) |settings| return .{ @floatFromInt(settings.display.width), @floatFromInt(settings.display.height) };
    return .{ @floatFromInt(self.width), @floatFromInt(self.height) };
}

/// Where the game's screen is in the world, for an editor: the top left of
/// what the current camera shows at the game's size, and how many of the
/// world's units a pixel of the screen is - with no camera, the world's
/// origin and one. The camera's turn is left out: the interface is not
/// turned with it.
pub const ScreenPlace = cameras.ScreenPlace;

pub fn screenInWorld(self: *App) ScreenPlace {
    return cameras.screenInWorld(self);
}

/// The picture a `RenderView` draws, as a texture: to put on a sprite, a
/// texture rect, or anything else a texture goes, from code. Made now if it
/// has not drawn one yet; `error.NotAView` for an entity with no view.
pub fn viewTexture(self: *App, view: ecs.Entity) !Assets.TextureHandle {
    return view_textures.textureOfView(self, view);
}

// -------------------------------------------------------------------------
// Where things are drawn
// -------------------------------------------------------------------------
//
// See `render/drawn_corners.zig`.

/// Where an entity's sprite is drawn, as its four corners in the world, round
/// from the texture's top left - turned, scaled and carried by its parents
/// as the renderer does it. Null for an entity with no sprite, or none that
/// can be placed. What a click on a sprite is tested against.
pub fn spriteCorners(self: *App, entity: ecs.Entity) ?[4]math.Vec2 {
    return drawn_corners.ofSprite(self, entity);
}

/// Where an entity's label is drawn, as its four corners in the world, round
/// from the top left of its first line - turned, scaled and carried by its
/// parents as the renderer does it. The box its lines are laid out in, not
/// the ink. Null for an entity with no `Text2D`, one with nothing to draw,
/// or one that cannot be placed.
pub fn textCorners(self: *App, entity: ecs.Entity) ?[4]math.Vec2 {
    return drawn_corners.ofText(self, entity);
}

/// Where a map's painted tiles are drawn, as the four corners of the box
/// they fill, in the world, clockwise from its top left. Null for an entity
/// with no `TileMap`, one with nothing painted, or one that cannot be
/// placed.
pub fn tileMapCorners(self: *App, entity: ecs.Entity) ?[4]math.Vec2 {
    return drawn_corners.ofTileMap(self, entity);
}

/// Whichever an entity is drawn as: its sprite's corners, else its label's,
/// else its map's. What an editor outlines, frames and tests a click
/// against without asking which it is.
pub fn drawnCorners(self: *App, entity: ecs.Entity) ?[4]math.Vec2 {
    return drawn_corners.of(self, entity);
}

// -------------------------------------------------------------------------
// The frame
// -------------------------------------------------------------------------
//
// Drawn layer by layer, and fitted to the window: see `render/layers.zig` and `render/stretch.zig`.

/// What this frame is drawn into.
pub fn target(self: *App) rhi.RenderTarget {
    return layers.target(self);
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
/// try app.drawWorld(minimap, view);
/// ```
///
/// On OpenGL a texture drawn into is read bottom row first, so shown in the
/// interface it wants its `source` turned over; see `drawnUpsideDown`.
pub fn drawWorld(self: *App, into: rhi.Texture, view: View) !void {
    return layers.drawWorld(self, into, view);
}

/// `drawWorld` without the `debug` lines over it, for an editor that draws
/// its interface preview over the world first and its marks last, with
/// `drawDebugOverlay`: a material there that reads the screen reads the
/// game's picture, not a selection's outline or a camera's frame.
pub fn drawWorldWithoutDebug(self: *App, into: rhi.Texture, view: View) !void {
    return layers.drawWorldWithoutDebug(self, into, view);
}

/// Draw this frame's world-space debug lines over an editor preview: after
/// `drawWorldWithoutDebug` and `drawControlPreview`.
pub fn drawDebugOverlay(self: *App, into: rhi.Texture, view: View) !void {
    return layers.drawDebugOverlay(self, into, view);
}

/// Whether a texture `drawWorld` drew into comes out upside down when drawn
/// as a picture: what the device says of what it draws - true on OpenGL,
/// whose framebuffers count rows from the bottom.
pub fn drawnUpsideDown(self: *const App) bool {
    return layers.drawnUpsideDown(self);
}

/// Draw one frame into a texture of its own and hand back the pixels: four
/// bytes each, top row first, owned by the caller. The same passes as a
/// frame on screen, so a capture shows what a player sees.
pub fn capture(self: *App, gpa: Allocator, width: u32, height: u32) ![]u8 {
    return layers.capture(self, gpa, width, height);
}

/// Draw one frame at the target's size into a PNG file: what `--capture`
/// asks for. `res://` is taken, as everywhere. `error.NoIo` without
/// `Options.io`.
pub fn saveCapture(self: *App, path: []const u8) !void {
    return layers.saveCapture(self, path);
}

/// How frames are shown against the display's refresh, from the next one:
/// see `VsyncMode`. One a backend has not is shown `enabled`.
pub fn setVsyncMode(self: *App, mode: VsyncMode) (rhi.Error || Window.Error)!void {
    self.vsync_mode_now = mode;
    if (self.surface) |surface| try self.device.setPresentMode(surface, mode.present());
    if (self.window) |*window| window.setPresentMode(mode.present()) catch {
        // A driver without late swaps: the nearest it has.
        if (mode == .adaptive) try window.setPresentMode(.enabled) else return error.Unavailable;
    };
}

/// How frames are shown against the refresh, as last asked.
pub fn vsyncMode(self: *const App) VsyncMode {
    return self.vsync_mode_now;
}

/// How the game, made at the project's size, is shown in a window of
/// another: see `render/stretch.zig`. From the next frame.
pub fn setStretchMode(self: *App, mode: stretching.Mode) void {
    self.stretch.mode = mode;
    self.refitStretch();
}

pub fn stretchMode(self: *const App) stretching.Mode {
    return self.stretch.mode;
}

/// What a window of another shape shows: bars, or more of the game.
pub fn setStretchAspect(self: *App, aspect: stretching.Aspect) void {
    self.stretch.aspect = aspect;
    self.refitStretch();
}

pub fn stretchAspect(self: *const App) stretching.Aspect {
    return self.stretch.aspect;
}

/// How big the game is drawn on top of its stretch: two shows half as much,
/// twice the size.
pub fn setStretchScale(self: *App, scale: f32) void {
    self.stretch.scale = @max(scale, 0.01);
    self.refitStretch();
}

pub fn stretchScale(self: *const App) f32 {
    return self.stretch.scale;
}

/// Any scale, or only whole ones: every pixel of pixel art the same size.
pub fn setStretchScaleMode(self: *App, mode: stretching.ScaleMode) void {
    self.stretch.scale_mode = mode;
    self.refitStretch();
}

pub fn stretchScaleMode(self: *const App) stretching.ScaleMode {
    return self.stretch.scale_mode;
}

/// A stretch changed: the frame again, and the picture it is drawn into.
fn refitStretch(self: *App) void {
    display.fitFrame(self);
    self.resized = true;
}

/// The family of graphics APIs the game is drawn with: the project's.
pub fn rendererInUse(self: *const App) Project.Renderer {
    const held = self.project.settings orelse return .compatibility;
    return held.rendering.renderer;
}

/// The graphics API the game is drawn with, which the renderer chose - or
/// fell back to. `.none` with no window.
pub fn backendInUse(self: *App) Backend {
    return Backend.of(self.device.backendTag());
}

// -------------------------------------------------------------------------
// Tiles
// -------------------------------------------------------------------------
//
// See `tiles/tile_chunks.zig`.

pub const SetTileError = tiles.SetTileError;

/// Put `cell` at `x`, `y` of `map`, counted in tiles from the map's origin
/// and negative above it and to its left. The chunk it lands in is made when
/// there is none.
///
/// Gives back the chunk holding the cell, or null when an empty cell was put
/// where there was no chunk - or emptied the last tile of one, which takes
/// the chunk away with it.
pub fn setTile(self: *App, map: ecs.Entity, x: i32, y: i32, cell: tilemap.Cell) SetTileError!?ecs.Entity {
    return tiles.setTile(self, map, x, y, cell);
}

/// What is at `x`, `y` of `map`: `Cell.empty` where nothing was painted.
pub fn tileAt(self: *App, map: ecs.Entity, x: i32, y: i32) tilemap.Cell {
    return tiles.tileAt(self, map, x, y);
}

/// The entity holding a map's chunk at `x`, `y`, in chunks. Found through
/// the index rather than by walking every chunk in the world.
pub fn tileChunkAt(self: *App, map: ecs.Entity, x: i32, y: i32) ?ecs.Entity {
    return self.tile_chunks.at(&self.world, map, x, y);
}

/// A chunk of a map, made and put in the index. Its cells start empty.
pub fn makeTileChunk(self: *App, map: ecs.Entity, x: i32, y: i32) SetTileError!ecs.Entity {
    return self.tile_chunks.make(self.gpa, &self.world, map, x, y);
}

/// How big one tile of a map is, in its own pixels: what its tile set says,
/// or the default for a map without one.
pub fn tileSizeOf(self: *App, map: ecs.Entity) [2]f32 {
    return tiles.tileSizeOf(self, map);
}

/// Which cell of `map` a point of the world is in, counted in tiles from the
/// map's origin as `setTile` counts them. Null for an entity with no
/// `TileMap`.
pub fn cellAt(self: *App, map: ecs.Entity, point: math.Vec2) ?geometry.Vec2i {
    return tiles.cellAt(self, map, point);
}

/// The cells of `map` something is painted in: the smallest rectangle that
/// holds them all. Null for a map with nothing painted.
pub fn usedCells(self: *App, map: ecs.Entity) ?geometry.Rect2i {
    return tiles.usedCells(self, map);
}

/// What the tile at `x`, `y` of `map` says under its tile set's data layer
/// called `layer`: nought, or false, where it says nothing, and null where
/// nothing is painted or the set has no layer of that name. A script has the
/// number, or the truth, itself.
pub fn tileData(self: *App, map: ecs.Entity, x: i32, y: i32, layer: []const u8) ?tileset.Value {
    return tiles.tileData(self, map, x, y, layer);
}

/// The same for the tile under a point of the world: the one something
/// stands on, say.
pub fn tileDataAt(self: *App, map: ecs.Entity, point: math.Vec2, layer: []const u8) ?tileset.Value {
    return tiles.tileDataAt(self, map, point, layer);
}

/// The box a map's painted tiles fill, in the map's own pixels: left, top,
/// right and bottom. Null for an entity with no `TileMap`, or one with no
/// tiles in it.
pub fn tileMapBounds(self: *App, entity: ecs.Entity) ?[4]f32 {
    return tiles.bounds(self, entity);
}

// -------------------------------------------------------------------------
// The interface
// -------------------------------------------------------------------------
//
// See `ui/interface.zig` and `ui/control.zig`.

/// Draw the scene's `Control` trees every frame. Calling it again does
/// nothing, so a reusable game module may safely ask for it too.
pub fn useControlNodes(self: *App) !void {
    try self.control_tree.enable(self);
}

/// Open a regular Fluxion UI element over a point in the 2D world. Call it
/// from a `.ui` system and close it like `ui.open`.
pub fn openWorldUi(
    self: *App,
    point: math.Vec2,
    declaration: fluxion_ui.Declaration,
    placement: Interface.WorldPlacement,
) void {
    const screen = self.worldToScreen(point.x, point.y);
    self.interface.openAt(&self.ui, screen, declaration, placement);
}

/// Give the keyboard's and a pad's focus to a control: a menu's first
/// button as it opens. From Flux too.
pub fn grabFocus(self: *App, entity: ecs.Entity) void {
    var buffer: [48]u8 = undefined;
    self.ui.setFocus(controlFocusId(self, &buffer, entity));
}

/// Whether a control has the focus.
pub fn hasFocus(self: *App, entity: ecs.Entity) bool {
    var buffer: [48]u8 = undefined;
    return self.ui.isFocused(controlFocusId(self, &buffer, entity));
}

/// Take the focus from whatever has it.
pub fn releaseFocus(self: *App) void {
    self.ui.clearFocus();
}

/// Where a control was laid out when the interface was last drawn, in the
/// units its anchors and offsets are in: its `size` is what a panel slides
/// in by, from a script as `app.controlRect(panel).size.x`. Null for one not
/// laid out - not a control, hidden, or not drawn yet.
pub fn controlRect(self: *App, entity: ecs.Entity) ?geometry.Rect2 {
    return controlRectOf(self, entity);
}

/// Anchor a control where `preset` says: see `Control.setAnchorsPreset`.
pub fn setAnchorsPreset(self: *App, entity: ecs.Entity, preset: control.Control.AnchorsPreset) !void {
    const held = self.world.get(entity, control.Control) orelse return error.NoSuchComponent;
    held.setAnchorsPreset(preset);
}

/// Lay the interface out this many times larger, over what the display and
/// the stretch ask for: a settings menu's interface size. One is as it is.
/// `interface.zoom` from Zig.
pub fn setInterfaceZoom(self: *App, zoom: f32) void {
    self.interface.zoom = if (zoom > 0) zoom else 1;
}

/// How much larger the game lays its interface out: see `setInterfaceZoom`.
pub fn interfaceZoom(self: *const App) f32 {
    return self.interface.zoom;
}

/// Draw the registered Control trees over an editor's scene texture, using
/// the same declarations and renderer as the running game: laid out at
/// `gameSize` on the screen where `screenInWorld` puts it - over what the
/// current camera shows, or at the world's origin with none - and as big as
/// `view` shows the world. A tree with no `CanvasLayer` or `Viewport` of its
/// own is shown over the screen too. A popup that is shut is drawn open while
/// it, or something in it, is one of `editing`: what the editor has picked,
/// to lay it out.
pub fn drawControlPreview(self: *App, into: rhi.Texture, view: View, editing: []const ecs.Entity) !void {
    try self.control_tree.preview(self, into, view, view.width, view.height, self.interface.faces, editing);
}

/// A Control's box in the last editor preview, in preview pixels.
pub fn controlPreviewBox(self: *App, entity: ecs.Entity) ?fluxion_ui.BoundingBox {
    return self.control_tree.previewBox(entity);
}

/// Draw a control's box the interface left for its material: see
/// `ControlTree.drawCustom`.
fn drawControlBox(context: ?*anyopaque, command: fluxion_ui.RenderCommand, scissor: ?rhi.Rect, into: rhi.RenderTarget, size: fluxion_ui.Dimensions) anyerror!void {
    const self: *App = @ptrCast(@alignCast(context.?));
    try self.control_tree.drawCustom(self, command, scissor, into, size);
}

/// The theme the project file names for its whole interface - `gui.theme` -
/// which every control is drawn with under the one it names itself; `.none`
/// for the engine's own look. Read the first time it is asked for, and again
/// when the project file names another.
pub fn projectTheme(self: *App) theme.ThemeHandle {
    return self.themes.ofProject(self);
}

/// Another window, beside the main one, with an interface of its own that
/// `ToolWindow.draw` lays out each frame: see `ToolWindow`. It draws with the
/// main window's device and in the interface's fonts. Headless, it is drawn
/// into a texture of its size.
pub fn openToolWindow(self: *App, desc: ToolWindow.Desc) !*ToolWindow {
    return ToolWindow.open(self, desc);
}

/// Close a tool window, and let go of all it had.
pub fn closeToolWindow(self: *App, tool: *ToolWindow) void {
    tool.close(self);
}

// -------------------------------------------------------------------------
// Scripts
// -------------------------------------------------------------------------
//
// See `script/script.zig`.

/// Run Flux scripts. This makes the VM, with `app` and `self.entity` in it,
/// and lets scenes hold a `Script`. Call it once; a second call does
/// nothing. See `script`.
///
/// ```zig
/// try app.useScripts(.{ .budget = 1_000_000 });
/// const door = try app.loadScript("res://scripts/door.flux");
/// _ = try app.world.spawnWith(.{ fx.Transform2D.at(0, 0), fx.Script.of(door) });
/// ```
pub fn useScripts(self: *App, options: script.Options) !void {
    if (self.scripts != null) return;
    try self.registerComponents(.{script.Script});
    self.types.addAll(.{script.ScriptHandle}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    self.scripts = try script.Scripts.create(self, options);
}

/// Read a `.flux` file and compile it, or find the script already read from
/// it, named as `Project` names a file. A file that reads and does not
/// compile still gets a handle, and its reasons are in the log. A `Script`
/// holding it makes nothing until a reload compiles.
pub fn loadScript(self: *App, path: []const u8) !script.ScriptHandle {
    const scripts = self.scripts orelse return error.ScriptsNotUsed;
    return scripts.load(path);
}

/// A script compiled from text rather than a file: a test's, or a tool's.
/// `name` is what the log and a scene call it. A name given before gets the
/// new text, as `setScriptText` gives it.
pub fn addScript(self: *App, name: []const u8, text: []const u8) !script.ScriptHandle {
    const scripts = self.scripts orelse return error.ScriptsNotUsed;
    return scripts.add(name, text);
}

/// Read a script's file again and put the new code in while the game runs:
/// every instance keeps its fields and goes on with the new code. Says
/// whether there was a file to read. Text that does not compile leaves the
/// old code running, and the reasons are in the log. Not from inside a
/// script, which is `error.Busy`.
pub fn reloadScript(self: *App, handle: script.ScriptHandle) !bool {
    const scripts = self.scripts orelse return false;
    return scripts.reload(handle);
}

/// New code for a script from text, not its file: an editor's unsaved
/// changes, run before they are saved. See `reloadScript`.
pub fn setScriptText(self: *App, handle: script.ScriptHandle, text: []const u8) !void {
    const scripts = self.scripts orelse return error.ScriptsNotUsed;
    return scripts.setText(handle, text);
}

/// A script's compiled code, for a shipped game to load in place of its
/// text: see `Scripts.saveCompiled`. Needs `useScripts` with `run` off.
pub fn compiledScript(self: *App, handle: script.ScriptHandle, gpa: Allocator, options: flux.image.SaveOptions) ![]u8 {
    const scripts = self.scripts orelse return error.ScriptsNotUsed;
    return scripts.saveCompiled(handle, gpa, options);
}

/// The script read from `path`, if one was, spelt any way `Project` spells
/// it.
pub fn findScript(self: *App, path: []const u8) ?script.ScriptHandle {
    const scripts = self.scripts orelse return null;
    return self.findSpelt(scripts, path);
}

/// Where a script was read from, or the name it was given; null for a
/// handle that has expired.
pub fn scriptSource(self: *App, handle: script.ScriptHandle) ?[]const u8 {
    const scripts = self.scripts orelse return null;
    return scripts.sourceOf(handle);
}

/// The fields the struct of `entity`'s script marks `@export`, made or not,
/// as many as `found` holds: what an editor shows under the `Script`. None
/// for an entity with no script, or one whose script does not compile.
pub fn exportedFields(self: *App, entity: ecs.Entity, found: []flux.FieldInfo) []flux.FieldInfo {
    const scripts = self.scripts orelse return found[0..0];
    return scripts.calls.exportedFields(scripts, entity, found);
}

/// The same for the struct `struct_name` of the script `file` - empty for
/// the one named after its file: what an editor shows of a data file.
pub fn structFields(self: *App, file: script.ScriptHandle, struct_name: []const u8, found: []flux.FieldInfo) []flux.FieldInfo {
    const scripts = self.scripts orelse return found[0..0];
    return scripts.calls.structFields(scripts, file, struct_name, found);
}

/// What an editor's language service needs to check and complete a game's
/// scripts as the game compiles them: `app` and `self.entity`. Hand it to
/// `flux.service`, with a loader for the files being edited. It needs no
/// `useScripts`.
pub fn scriptSetup(self: *App) flux.service.Options {
    return script.serviceOptions(self);
}

/// What a script awaits for the next frame: `await app.nextFrame()`. Null
/// in a game with no scripts.
pub fn nextFrame(self: *App) flux.Value {
    const scripts = self.scripts orelse return .null;
    return scripts.calls.nextFrame(scripts);
}

/// Call a script's function at the end of this frame, after its systems and
/// signals: `app.callDeferred(self.respawn)`.
pub fn callDeferred(self: *App, callable: flux.Value) !void {
    const scripts = self.scripts orelse return error.NoScripts;
    return scripts.calls.callDeferred(scripts, callable);
}

/// A data file's struct, made anew and given the file's values - from Flux,
/// `app.readData("res://dialogue/intro.data")`. A value the struct cannot
/// hold is said and passed over, as a scene's `"exports"` are.
pub fn readData(self: *App, handle: data_file.DataHandle) !flux.Value {
    const scripts = self.scripts orelse return error.NoScripts;
    const held = self.data_files.get(handle) orelse return error.NoSuchData;
    const contents = try data_file.read(self.gpa, held.bytes);
    defer contents.deinit();
    return scripts.calls.readData(scripts, &contents, held.source);
}

/// Write a data file of a script's struct: the values of its `@export`
/// fields, as `readData` gives them back - the struct as a save. From Flux,
/// `app.writeData(save, "user://saves/one.data")`. A data file read from
/// there already is read again, so the next `readData` gives what was
/// written. A field whose value a file cannot say - an entity, a function -
/// is passed over with a warning.
pub fn writeData(self: *App, value: flux.Value, path: []const u8) !void {
    const scripts = self.scripts orelse return error.NoScripts;
    const text = try scripts.calls.writeData(scripts, value);
    defer self.gpa.free(text);
    try self.writeText(path, text);
    if (self.findData(path)) |known| _ = try self.reloadData(known);
}

// -------------------------------------------------------------------------
// Files of every kind
// -------------------------------------------------------------------------
//
// One call each for what every kind of file has - where a handle's file is,
// and the handle of a file - whatever the kind: what a scene writes and
// reads handles by, and what an editor's file fields go through. See
// `AssetKind`.

/// The file a handle was read from, whatever kind of file it holds: its
/// `res://` path. Null for `.none`, for an expired handle, and for one made
/// in memory.
pub fn assetSource(self: *App, handle: anytype) ?[]const u8 {
    const H = @TypeOf(handle);
    const kind = comptime AssetKind.of(H) orelse @compileError(@typeName(H) ++ " holds no file");
    return switch (kind) {
        .texture => self.assets.textureSource(handle),
        .font => self.assets.fontSource(handle),
        .script => self.scriptSource(handle),
        .tileset => self.tileSetSource(handle),
        .theme => self.themeSource(handle),
        .scene => self.sceneSource(handle),
        .data => self.dataSource(handle),
        .audio => self.audioSource(handle),
        .animation => self.animation_libraries.sourceOf(handle),
        .frames => self.sprite_frames.sourceOf(handle),
        .shader => self.shaders.sourceOf(handle),
    };
}

/// The handle of the file at `path`, read now if nothing has read it yet: a
/// texture sampled as textures are by default, the first font of a file.
pub fn loadAsset(self: *App, comptime H: type, path: []const u8) !H {
    const kind = comptime AssetKind.of(H) orelse @compileError(@typeName(H) ++ " holds no file");
    try self.finishLoad(path);
    return switch (kind) {
        .texture => self.assets.findTexture(path) orelse try self.assets.loadTexture(path, .{}),
        .font => self.assets.findFont(path) orelse try self.assets.loadFont(path, .{}),
        .script => self.loadScript(path),
        .tileset => self.loadTileSet(path),
        .theme => self.loadTheme(path),
        .scene => self.loadScene(path),
        .data => self.loadData(path),
        .audio => self.loadAudio(path),
        .animation => self.loadAnimations(path),
        .frames => self.loadSpriteFrames(path),
        .shader => self.loadShader(path),
    };
}

/// The handle of the file at `path`, if something has read it.
pub fn findAsset(self: *App, comptime H: type, path: []const u8) ?H {
    const kind = comptime AssetKind.of(H) orelse @compileError(@typeName(H) ++ " holds no file");
    return switch (kind) {
        .texture => self.assets.findTexture(path),
        .font => self.assets.findFont(path),
        .script => self.findScript(path),
        .tileset => self.findTileSet(path),
        .theme => self.findTheme(path),
        .scene => self.findScene(path),
        .data => self.findData(path),
        .audio => self.findAudio(path),
        .animation => self.findAnimations(path),
        .frames => self.findSpriteFrames(path),
        .shader => self.findShader(path),
    };
}

/// What `table.find` finds at `path`, spelt as it is given or as
/// `Project.canonical` spells it: `res://`, from the root, or the system's.
fn findSpelt(self: *App, table: anytype, path: []const u8) @TypeOf(table.find(path)) {
    if (table.find(path)) |known| return known;
    const named = self.project.canonical(self.gpa, path) catch return null;
    defer self.gpa.free(named);
    return table.find(named);
}

/// Read a file beside the game - any the engine reads: a scene, a picture, a
/// sound, a font, a tile set… - on a thread of its own, or on a page a piece
/// a frame. A picture is decoded there, and a scene brings the pictures and
/// sounds it names with it. `loadProgress` and `loadStatus` say how far it
/// has got, and the next load of the file - `loadScene`, `loadAsset`, a
/// script giving a sprite the path - takes it once it is done, without a
/// pause; `finishLoad` waits for it. A file on its way already, or read
/// already, is left as it is. See `background`.
///
/// ```zig
/// try app.loadInBackground("res://levels/two.json");
/// try app.loadInBackground("res://music/night.ogg");
/// // each frame:
/// bar.value = app.loadProgress("res://levels/two.json") * 100;
/// if (bar.value >= 100) app.changeScene(try app.loadScene("res://levels/two.json"));
/// ```
///
/// `error.NotAnAsset` for a file the engine does not read by its ending.
pub fn loadInBackground(self: *App, path: []const u8) !void {
    return background_load.start(self, path);
}

/// How far the file at `path` has got, from nought to one: one once it is
/// read, in the background or not, and nought while nothing is reading it.
pub fn loadProgress(self: *App, path: []const u8) f32 {
    return background_load.progress(self, path);
}

/// Where a file is in `loadInBackground`: `done` once it is read - in the
/// background or not - `failed` for a load that did not read, which says
/// why when it is taken, and `none` when nothing is reading it.
pub const LoadStatus = background_load.LoadStatus;

pub fn loadStatus(self: *App, path: []const u8) LoadStatus {
    return background_load.status(self, path);
}

/// Wait for the background load of `path`, if there is one, and make what
/// it read what it is: the next load of the file finds it. What went wrong
/// is its error. Nothing when nothing is reading it.
pub fn finishLoad(self: *App, path: []const u8) !void {
    return background_load.finish(self, path);
}

// -------------------------------------------------------------------------
// Each kind of file
// -------------------------------------------------------------------------
//
// Read a file, make one from text, find it, read it again, let it go.

/// Read a `.tileset` file, or find the one read from there already. See
/// `tileset.TileSets`.
pub fn loadTileSet(self: *App, path: []const u8) !tileset.TileSetHandle {
    return self.tile_sets.load(self, path);
}

/// A tile set from text rather than a file: a test's, or a tool's.
pub fn addTileSet(self: *App, name: []const u8, text: []const u8) !tileset.TileSetHandle {
    return self.tile_sets.add(self, name, text);
}

pub fn findTileSet(self: *App, path: []const u8) ?tileset.TileSetHandle {
    return self.findSpelt(&self.tile_sets, path);
}

/// Read a tile set's file again, for an editor that has just saved it.
/// Whatever was built from it is built again.
pub fn reloadTileSet(self: *App, handle: tileset.TileSetHandle) !bool {
    return self.tile_sets.reload(self, handle);
}

pub fn tileSetOf(self: *App, handle: tileset.TileSetHandle) ?*const tileset.TileSet {
    return self.tile_sets.get(handle);
}

/// The path a tile set was read from: what a scene writes in a handle's
/// place, and what an editor shows.
pub fn tileSetSource(self: *App, handle: tileset.TileSetHandle) ?[]const u8 {
    return self.tile_sets.sourceOf(handle);
}

/// Read a `.theme` file, or find the one read from there already. See
/// `theme.Themes`.
pub fn loadTheme(self: *App, path: []const u8) !theme.ThemeHandle {
    return self.themes.load(self, path);
}

/// A theme from text rather than a file: a test's, or a tool's.
pub fn addTheme(self: *App, name: []const u8, text: []const u8) !theme.ThemeHandle {
    return self.themes.add(self, name, text);
}

pub fn findTheme(self: *App, path: []const u8) ?theme.ThemeHandle {
    return self.findSpelt(&self.themes, path);
}

/// Read a theme's file again, for an editor that has just saved it.
pub fn reloadTheme(self: *App, handle: theme.ThemeHandle) !bool {
    return self.themes.reload(self, handle);
}

pub fn themeOf(self: *App, handle: theme.ThemeHandle) ?*const theme.Theme {
    return self.themes.get(handle);
}

/// The path a theme was read from: what a scene writes in a handle's place,
/// and what an editor shows.
pub fn themeSource(self: *App, handle: theme.ThemeHandle) ?[]const u8 {
    return self.themes.sourceOf(handle);
}

/// Read a scene's file to make things of, or find the one read from there
/// already. Nothing is made of it yet: see `instantiate` and `changeScene`,
/// and `scenes`.
///
/// A file `loadInBackground` is reading is taken from that load - waited
/// for, if it is not done - rather than read again.
pub fn loadScene(self: *App, path: []const u8) !SceneHandle {
    try self.finishLoad(path);
    return self.scenes.load(self, path);
}

/// A scene from memory rather than a file: a test's, or one a game wrote
/// with `scene.write`. `name` is what it is found and written by.
pub fn addScene(self: *App, name: []const u8, bytes: []const u8) !SceneHandle {
    return self.scenes.add(self.gpa, name, bytes);
}

/// The scene read from `path` already, if one was, however the path is
/// spelt: `res://`, from the root, or the system's.
pub fn findScene(self: *App, path: []const u8) ?SceneHandle {
    return self.findSpelt(&self.scenes, path);
}

/// The path a scene was read from: what an instance is written as.
pub fn sceneSource(self: *App, handle: SceneHandle) ?[]const u8 {
    return self.scenes.sourceOf(handle);
}

/// Read a scene's file again, for an editor that has just saved it: what is
/// made of it next is what was saved. What was made of it already stays.
pub fn reloadScene(self: *App, handle: SceneHandle) !bool {
    return self.scenes.reload(self, handle);
}

pub fn unloadScene(self: *App, handle: SceneHandle) void {
    self.scenes.unload(self.gpa, handle);
}

/// Read a `.anim` file - an animation library - or find the one read from
/// there already. What an `AnimationPlayer` plays; see `animation/animation.zig`.
pub fn loadAnimations(self: *App, path: []const u8) !animation.AnimationLibraryHandle {
    return self.animation_libraries.load(self, path);
}

/// An animation library from text rather than a file: a test's, or a
/// tool's. A name given before gets the new text.
pub fn addAnimations(self: *App, name: []const u8, text: []const u8) !animation.AnimationLibraryHandle {
    return self.animation_libraries.add(self.gpa, name, text);
}

pub fn findAnimations(self: *App, path: []const u8) ?animation.AnimationLibraryHandle {
    return self.findSpelt(&self.animation_libraries, path);
}

/// Read a `.anim` file again, for an editor that has just saved it.
pub fn reloadAnimations(self: *App, handle: animation.AnimationLibraryHandle) !bool {
    return self.animation_libraries.reload(self, handle);
}

/// Read a `.frames` file - animations of pictures - or find the one read
/// from there already. What an `AnimatedSprite2D` plays; see
/// `animation/sprite_frames.zig`.
pub fn loadSpriteFrames(self: *App, path: []const u8) !sprite_animation.SpriteFramesHandle {
    return self.sprite_frames.load(self, path);
}

/// New sprite frames, of no file until `saveSpriteFrames` writes them: one
/// animation, `"default"`, at 5 frames a second.
pub fn newSpriteFrames(self: *App) !sprite_animation.SpriteFramesHandle {
    return self.sprite_frames.addNew(self);
}

/// `frames` written to `path`. New ones become that file's; a file's are
/// written there as a copy.
pub fn saveSpriteFrames(self: *App, frames: sprite_animation.SpriteFramesHandle, path: []const u8) !void {
    return self.sprite_frames.saveAs(self, frames, path);
}

/// Sprite frames from text rather than a file. A name given before gets the
/// new text.
pub fn addSpriteFrames(self: *App, name: []const u8, text: []const u8) !sprite_animation.SpriteFramesHandle {
    return self.sprite_frames.add(self, name, text);
}

/// Sprite frames made in code: `clips` over a `columns` by `rows` grid of
/// `texture`, found by `name`.
pub fn addGridFrames(self: *App, name: []const u8, texture: Assets.TextureHandle, columns: u16, rows: u16, clips: []const sprite_animation.GridClip) !sprite_animation.SpriteFramesHandle {
    return self.sprite_frames.addGrid(self, name, texture, columns, rows, clips);
}

pub fn findSpriteFrames(self: *App, path: []const u8) ?sprite_animation.SpriteFramesHandle {
    return self.findSpelt(&self.sprite_frames, path);
}

pub fn reloadSpriteFrames(self: *App, handle: sprite_animation.SpriteFramesHandle) !bool {
    return self.sprite_frames.reload(self, handle);
}

/// Read a `.shader` file, or find the one read from there already: what a
/// `Material` draws with. One that does not compile says why in the log and
/// draws as none. See `render/shaders.zig`.
pub fn loadShader(self: *App, path: []const u8) !shading.ShaderHandle {
    return self.shaders.load(self, path);
}

/// A shader from text rather than a file: a test's, or a tool's. A name
/// given before gets the new text.
pub fn addShader(self: *App, name: []const u8, text: []const u8) !shading.ShaderHandle {
    return self.shaders.add(self, name, text);
}

pub fn findShader(self: *App, path: []const u8) ?shading.ShaderHandle {
    return self.findSpelt(&self.shaders, path);
}

/// Text an editor has open for a shader and has not saved, as it is typed:
/// what names it draws with it from the next frame, or - while it does not
/// compile - with what last did. `reloadShader` goes back to the file.
pub fn previewShader(self: *App, handle: shading.ShaderHandle, text: []const u8) !void {
    return self.shaders.preview(self, handle, text);
}

/// Read a shader's file again, for an editor that has just saved it: what
/// names it draws with the new one from the next frame.
pub fn reloadShader(self: *App, handle: shading.ShaderHandle) !bool {
    return self.shaders.reload(self, handle);
}

/// A shader as it was read: its text, what it compiled to, and why it did
/// not when it did not.
pub fn shaderOf(self: *App, handle: shading.ShaderHandle) ?*const shading.Shader {
    return self.shaders.get(handle);
}

/// Read a sound's file - `.wav`, `.ogg` or `.mp3` - or find the one read
/// from there already. What an `AudioPlayer` plays; see `audio/audio.zig`.
pub fn loadAudio(self: *App, path: []const u8) !sound.AudioClipHandle {
    try self.finishLoad(path);
    return self.audio.load(self, path);
}

/// A sound from memory rather than a file: a test's, or a tool's. Its
/// format is what its bytes say, or else its name's ending.
pub fn addAudio(self: *App, name: []const u8, bytes: []const u8) !sound.AudioClipHandle {
    return self.audio.add(name, bytes);
}

/// The sound read from `path` already, if one was, however the path is
/// spelt.
pub fn findAudio(self: *App, path: []const u8) ?sound.AudioClipHandle {
    return self.findSpelt(&self.audio, path);
}

pub fn audioSource(self: *App, handle: sound.AudioClipHandle) ?[]const u8 {
    return self.audio.sourceOf(handle);
}

/// Let a sound go, and every player playing it stop.
pub fn unloadAudio(self: *App, handle: sound.AudioClipHandle) void {
    self.audio.unload(handle);
}

/// Read a `.data` file, or find the one read from there already: see
/// `data`. What it says is read when its struct is made, by `readData`.
pub fn loadData(self: *App, path: []const u8) !data_file.DataHandle {
    return self.data_files.load(self, path);
}

/// A data file from memory rather than a file: a test's, or one a tool
/// wrote with `data.write`. `name` is what it is found and written by.
pub fn addData(self: *App, name: []const u8, bytes: []const u8) !data_file.DataHandle {
    return self.data_files.add(self.gpa, name, bytes);
}

/// The data file read from `path` already, if one was, however the path is
/// spelt.
pub fn findData(self: *App, path: []const u8) ?data_file.DataHandle {
    return self.findSpelt(&self.data_files, path);
}

pub fn dataSource(self: *App, handle: data_file.DataHandle) ?[]const u8 {
    return self.data_files.sourceOf(handle);
}

/// Read a data file again, for an editor that has just saved it: what
/// `readData` makes next is what was saved.
pub fn reloadData(self: *App, handle: data_file.DataHandle) !bool {
    return self.data_files.reload(self, handle);
}

pub fn unloadData(self: *App, handle: data_file.DataHandle) void {
    self.data_files.unload(self.gpa, handle);
}

// -------------------------------------------------------------------------
// Images
// -------------------------------------------------------------------------
//
// See `assets/images.zig`.

/// A picture's file - a PNG or a JPEG, `res://`, `user://` or the system's -
/// as an image to read and change, in `gpa`'s memory. See `images`.
pub fn readImage(self: *App, gpa: Allocator, path: []const u8) !Image {
    return images.read(self, gpa, path);
}

pub const SaveImageOptions = images.SaveOptions;

/// Write an image to `path`: a JPEG for a `.jpg` or a `.jpeg`, a PNG for a
/// `.png`, and `error.UnknownImageFormat` for any other ending. Written
/// beside the old and put in its place, as `writeText` does.
pub fn saveImage(self: *App, picture: Image, path: []const u8, options: SaveImageOptions) !void {
    return images.save(self, picture, path, options);
}

/// The frame drawn again into an image the window's size: a save's
/// thumbnail, a photo mode's picture.
pub fn captureImage(self: *App, gpa: Allocator) !Image {
    return images.capture(self, gpa);
}

/// What a texture holds, read back from the GPU: a render view's picture, a
/// texture made from an image and changed since.
pub fn textureImage(self: *App, gpa: Allocator, texture: Assets.TextureHandle) !Image {
    return images.ofTexture(self, gpa, texture);
}

/// An image made a texture to draw, found by the name it is given -
/// `image://1`, `image://2`... - which is what a script hands a sprite. See
/// `updateTexture`.
pub fn newTexture(self: *App, picture: Image, options: Assets.LoadOptions) !Assets.TextureHandle {
    return images.toTexture(self, picture, options);
}

/// Give a texture an image's pixels: in place for the same size, made anew
/// for another, the handle the same either way.
pub fn updateTexture(self: *App, texture: Assets.TextureHandle, picture: Image) !void {
    return images.updateTexture(self, texture, picture);
}

// -------------------------------------------------------------------------
// The project
// -------------------------------------------------------------------------
//
// See `project/project_start.zig`.

/// Open what the project says a game opens with: its boot splash while it
/// reads, its autoloads - each named after its file and kept when the scene
/// changes - and then its main scene. What `Options.open_project` does at
/// `startup`.
pub fn openProject(self: *App) !void {
    return project_start.open(self);
}

/// The project's `application.autoload` list, made: each scene or script an
/// entity named after its file, which a scene change leaves. What
/// `openProject` does before the main scene, for a tool that opens another.
pub fn openAutoloads(self: *App) !void {
    return project_start.openAutoloads(self);
}

/// What the project file's `application.version` says: "1.2.0", for a menu
/// to show. Empty with none.
pub fn gameVersion(self: *const App) []const u8 {
    const held = self.project.settings orelse return "";
    return held.application.version;
}

// -------------------------------------------------------------------------
// A game's files
// -------------------------------------------------------------------------
//
// See `files/game_files.zig`.

/// The most a file is read as text: `readText`.
pub const text_limit = game_files.text_limit;

/// The text of the file at `path` - `res://`, `user://`, `uid://` or the
/// system's own - in `gpa`'s memory, for the caller to free.
/// `error.FileNotFound` where there is none.
pub fn readText(self: *App, gpa: Allocator, path: []const u8) ![]u8 {
    return game_files.readText(&self.project, gpa, path);
}

/// Write `text` to the file at `path`, over what it held, making the
/// folders on the way. The new text is written beside the old and then put
/// in its place, so a game that stops halfway through a save leaves the
/// last one whole.
pub fn writeText(self: *App, path: []const u8, text: []const u8) !void {
    return game_files.writeText(&self.project, path, text);
}

/// Add `text` to the end of the file at `path`, making it - and the folders
/// it is in - when there is none: a log, a line at a time.
pub fn appendText(self: *App, path: []const u8, text: []const u8) !void {
    return game_files.appendText(&self.project, path, text);
}

/// Whether there is a file or a folder at `path`.
pub fn fileExists(self: *App, path: []const u8) bool {
    return game_files.fileExists(&self.project, path);
}

/// Make the folder at `path`, and the ones it is in. One there already is
/// fine.
pub fn makeDir(self: *App, path: []const u8) !void {
    return game_files.makeDir(&self.project, path);
}

/// Take out the file at `path`, or the folder, when it is empty.
pub fn removeFile(self: *App, path: []const u8) !void {
    return game_files.removeFile(&self.project, path);
}

/// What a folder holds, by name, in order. See `listDir`.
pub const Listing = game_files.Listing;

/// The names in the folder at `path`, sorted, a folder's ending with `/`.
/// `error.FileNotFound` where there is none.
pub fn listDir(self: *App, gpa: Allocator, path: []const u8) !Listing {
    return game_files.listDir(&self.project, gpa, path);
}

/// What is known of a file without reading it. See `fileInfo`.
pub const FileInfo = game_files.FileInfo;

/// The size of the file at `path`, when it was last written, and whether it
/// is a folder. `error.FileNotFound` where there is none.
pub fn fileInfo(self: *App, path: []const u8) !FileInfo {
    return game_files.fileInfo(&self.project, path);
}

/// Whether there is a folder at `path`.
pub fn isDir(self: *App, path: []const u8) bool {
    return game_files.isDir(&self.project, path);
}

/// The SHA-256 of the file at `path`: the same file, the same 32 bytes -
/// whether a download finished whole, or a save is the one the game wrote.
pub fn fileSha256(self: *App, path: []const u8) ![32]u8 {
    return game_files.fileSha256(&self.project, path);
}

/// `text` written to `path` as gzip, which any tool opens: a big save in a
/// tenth of the room. `readCompressed` reads it.
pub fn writeCompressed(self: *App, path: []const u8, text: []const u8) !void {
    return game_files.writeCompressed(&self.project, path, text);
}

/// The text of a file `writeCompressed` wrote. `error.NotCompressed` for a
/// file that is not gzip.
pub fn readCompressed(self: *App, gpa: Allocator, path: []const u8) ![]u8 {
    return game_files.readCompressed(&self.project, gpa, path);
}

/// `text` written to `path` compressed and sealed with `password`: nobody
/// reads it, and a file changed by hand is refused rather than taken. See
/// `sealed`. `secret_cost` is how hard the password is made to guess.
pub fn writeSecret(self: *App, path: []const u8, text: []const u8, password: []const u8) !void {
    return game_files.writeSecret(&self.project, path, text, password, self.secret_cost);
}

/// The text of a file `writeSecret` wrote with `password`.
/// `error.CannotOpen` for another password or a file changed since;
/// `error.NotSealed` for a file that was never sealed.
pub fn readSecret(self: *App, gpa: Allocator, path: []const u8, password: []const u8) ![]u8 {
    return game_files.readSecret(&self.project, gpa, path, password);
}

/// Open a web or mail address in the player's browser or mail program: a
/// game's page, its store, an address to write to. Only `http://`,
/// `https://` and `mailto:` - anything else is `error.NotAllowed`, so a
/// script cannot start a program with it.
pub fn openUrl(self: *App, url: []const u8) !void {
    return game_files.openUrl(&self.project, url);
}

/// Open the file at `path` in the program the player opens its kind with,
/// or a folder in the file manager. `error.Unsupported` where there is none
/// to ask: a page, a phone.
pub fn openPath(self: *App, path: []const u8) !void {
    return game_files.openPath(&self.project, path);
}

/// Show the file at `path` picked out in the file manager's window of its
/// folder: a Saves folder button's `showInFolder("user://saves/slot1.json")`.
pub fn showInFolder(self: *App, path: []const u8) !void {
    return game_files.showInFolder(&self.project, path);
}

// -------------------------------------------------------------------------
// A project's files, for an editor
// -------------------------------------------------------------------------
//
// What an editor does to a project's files, done so that nothing the engine
// holds is left pointing at the old place: see `files/project_files.zig`.

/// Whether `moveToTrash` has a trash to move things to on this system: the
/// Recycle Bin on Windows, the freedesktop.org trash on a Linux desktop -
/// with a fluxion-platform that has trash at all. The Linux one takes only
/// what is on the home folder's drive: anything else is `error.OtherDrive`.
/// A folder in `App.trash` stands in for either, on any system.
pub const trash_available = project_files.trash_available;

/// Move or rename a file or a folder, with its `.uid` file, and everything
/// read from it with it: a texture loaded from it stays loaded, kept by
/// where it is now, so the scene saved next names the new place - and every
/// scene that names it by its UUID finds it there. Never over something
/// already at `to`: that is `error.PathAlreadyExists`. See
/// `Project.moveFile`.
pub fn moveFile(self: *App, from: []const u8, to: []const u8) !void {
    return project_files.moveFile(self, from, to);
}

/// Copy a file, or a folder and everything in it, never over something
/// already at `to`. A copy of a file with a UUID is given a new one. See
/// `Project.copyFile`.
pub fn copyFile(self: *App, from: []const u8, to: []const u8) !void {
    return self.project.copyFile(from, to);
}

/// Move a file or a folder to the system's trash, where a person can take it
/// back from - with its `.uid` file, so what comes back has its UUID. What
/// the project knew of its UUIDs is forgotten; what was loaded from it stays
/// loaded. `error.Unsupported` where there is no trash: see
/// `trash_available`.
pub fn moveToTrash(self: *App, path: []const u8) !void {
    return project_files.moveToTrash(self, path);
}

// -------------------------------------------------------------------------
// The window
// -------------------------------------------------------------------------
//
// See `platform/window.zig`.

/// How the window is on the screen: windowed, minimised, maximised,
/// fullscreen or exclusively so. See `Window.Mode`.
pub const WindowMode = Window.Mode;

/// How frames are shown against the display's refresh. See
/// `Window.VsyncMode`.
pub const VsyncMode = Window.VsyncMode;

/// A display's resolution, bits and refresh: what `exclusive_fullscreen`
/// switches it to. See `setVideoMode`.
pub const VideoMode = platform.VideoMode;

/// How small and how large the player may drag the window.
pub const WindowSizeLimits = Window.SizeLimits;

/// Put the window in a mode: a window, minimised, maximised, filling the
/// screen it is on, or filling it exclusively. See `WindowMode`. The new
/// size arrives at the top of the next frame. Nothing without a window.
pub fn setWindowMode(self: *App, mode: WindowMode) Window.Error!void {
    if (self.window) |*window| try window.setMode(mode);
}

/// Which of the five the window is in now. `.windowed` when there is none.
pub fn windowMode(self: *const App) WindowMode {
    if (self.window) |*window| return window.mode();
    return .windowed;
}

/// Filling the screen if it is a window, a window if it fills the screen.
pub fn toggleFullscreen(self: *App) Window.Error!void {
    if (self.window) |*window| try window.toggleFullscreen();
}

/// The display mode `exclusive_fullscreen` switches the window's screen to:
/// one of its `videoMode`s, a lower resolution for a slow machine. Taken at
/// once where the window is in that mode already. Nothing without a window.
pub fn setVideoMode(self: *App, mode: VideoMode) Window.Error!void {
    if (self.window) |*window| try window.setVideoMode(mode);
}

/// Give the window the system's frame and title bar, or take them away - a
/// borderless window. `error.Unavailable` where the system decides: a
/// phone, a page, Wayland. Nothing without a window.
pub fn setWindowBorderless(self: *App, borderless: bool) Window.Error!void {
    if (self.window) |*window| try window.setDecorated(!borderless);
}

/// Whether the window has no frame of the system's. False with none.
pub fn windowBorderless(self: *const App) bool {
    if (self.window) |*window| return !window.decorated();
    return false;
}

/// Let the player drag the window's edges, or not. `setWindowSize` works
/// either way. Nothing without a window.
pub fn setWindowResizable(self: *App, resizable: bool) Window.Error!void {
    if (self.window) |*window| try window.setResizable(resizable);
}

/// Whether the player may drag the window's edges. False with no window.
pub fn windowResizable(self: *const App) bool {
    if (self.window) |*window| return window.resizable();
    return false;
}

/// Keep the window over every window that is not kept so itself.
/// `error.Unavailable` on Wayland, a phone and a page. Nothing without a
/// window.
pub fn setWindowAlwaysOnTop(self: *App, on_top: bool) Window.Error!void {
    if (self.window) |*window| try window.setTopmost(on_top);
}

/// Whether the window is kept on top. False with none.
pub fn windowAlwaysOnTop(self: *const App) bool {
    if (self.window) |*window| return window.topmost();
    return false;
}

/// Keep the screen from blanking, and the machine from sleeping, while the
/// game runs, or let them again: a game played with a pad. See
/// `display.keep_screen_on`. `error.Unavailable` on a phone, a page and
/// Wayland. Nothing without a window.
pub fn setKeepScreenOn(self: *App, on: bool) Window.Error!void {
    if (self.window) |*window| try window.setKeepAwake(on);
}

/// Whether the game keeps the screen on. False with no window.
pub fn keepScreenOn(self: *const App) bool {
    if (self.window) |*window| return window.keepAwake();
    return false;
}

/// What the title bar says. Nothing without a window.
pub fn setWindowTitle(self: *App, title: []const u8) Window.Error!void {
    if (self.window) |*window| try window.setTitle(title);
}

/// Make the window's content area this size, in pixels. A fullscreen,
/// maximised or minimised window becomes an ordinary one first. The new size
/// arrives at the top of the next frame. Without a window, what the app draws
/// into is that size at once - a test of a layout at a size asks this.
pub fn setWindowSize(self: *App, width: u32, height: u32) (Window.Error || rhi.Error)!void {
    if (self.window) |*window| return window.setSize(width, height);
    // With no window, what there is to draw into is that size at once.
    try display.adoptSize(self, width, height);
}

/// How big the window's content area is, in pixels: what `setWindowSize`
/// asked for once it has arrived. The size the app was made at when there is
/// no window.
pub fn windowSize(self: *const App) geometry.Vec2i {
    return .init(@intCast(self.width), @intCast(self.height));
}

/// Put the top left of the window's content area at this point of the
/// desktop. Nothing without a window.
pub fn setWindowPosition(self: *App, x: i32, y: i32) Window.Error!void {
    if (self.window) |*window| try window.setPosition(x, y);
}

/// Where the top left of the window's content area is on the desktop, or
/// null when there is no window. Always nought, nought on Wayland.
pub fn windowPosition(self: *const App) ?geometry.Vec2i {
    const window = if (self.window) |*held| held else return null;
    const at = window.position();
    return .init(at[0], at[1]);
}

/// How small and how large the player may drag the window. A window already
/// outside the limits is brought inside them at once. Nothing without a
/// window.
pub fn setWindowSizeLimits(self: *App, limits: WindowSizeLimits) Window.Error!void {
    if (self.window) |*window| try window.setSizeLimits(limits);
}

/// The window's own picture, in the title bar, the task switcher and the
/// dock: several sizes at once, each at most `platform.IconImage.max_side`
/// pixels across, and the system takes the one it wants. An empty list puts
/// the system's own back: the program's icon, when it has one. Nothing
/// without a window, and `error.Unavailable` on Wayland, where a window's
/// picture comes from its desktop file, on Android, and for an image too
/// large.
pub fn setWindowIcon(self: *App, sizes: []const platform.IconImage) Window.Error!void {
    if (self.window) |*window| try window.setIcon(sizes);
}

/// How far in from each edge of the framebuffer the part of the window that
/// nothing covers starts: a phone's notch and its gesture bar, a page's
/// safe area. Nought on every desktop, and without a window.
///
/// `app.safeArea().within(app.width, app.height)` is what is left, which is
/// where the interface puts its root - see `Interface.follow_safe_area`.
/// A page gets them only with `viewport-fit=cover` in its viewport meta tag.
pub fn safeArea(self: *const App) platform.Insets {
    if (self.window) |*window| return window.safeArea();
    return .{};
}

/// True in the frame the window's close button - or Alt+F4 - was pressed,
/// where the project's `application.quit_on_close` is off: the game asks
/// whether to go, and goes with `quit`.
pub fn closeRequested(self: *const App) bool {
    return self.close_frame == self.time.frame;
}

// -------------------------------------------------------------------------
// Screens
// -------------------------------------------------------------------------

/// How many screens are attached. Nought with no window.
pub fn screenCount(self: *App) u32 {
    if (self.window) |*window| return @intCast(window.screens().len);
    return 0;
}

/// Which screen the window is on, counting from nought, or null where the
/// system does not say.
pub fn windowScreen(self: *const App) ?u32 {
    if (self.window) |*window| if (window.screen()) |index| return @intCast(index);
    return null;
}

/// Which screen the system calls its primary - the first where it calls
/// none so - or null with none at all.
pub fn primaryScreen(self: *App) ?u32 {
    if (self.window) |*window| if (window.primaryScreen()) |index| return @intCast(index);
    return null;
}

/// Put the window on a screen: in the middle of it as a window, or filling
/// it where it fills the one it is on. `error.Unavailable` for a screen
/// there is not, and on Wayland. Nothing without a window.
pub fn setWindowScreen(self: *App, screen: u32) Window.Error!void {
    if (self.window) |*window| try window.moveToScreen(screen);
}

/// Put the window in the middle of the screen it is on. Nothing without a
/// window.
pub fn centerWindow(self: *App) Window.Error!void {
    if (self.window) |*window| try window.center();
}

/// A screen's place on the desktop and its size, in pixels. Null for a
/// screen there is not.
pub fn screenRect(self: *App, screen: u32) ?geometry.Rect2i {
    const at = self.screenAt(screen) orelse return null;
    return rectOf(at.bounds);
}

/// The part of a screen no taskbar or panel covers. Null for a screen there
/// is not.
pub fn screenUsableRect(self: *App, screen: u32) ?geometry.Rect2i {
    const at = self.screenAt(screen) orelse return null;
    return rectOf(at.work_area);
}

/// A screen's pixels per logical unit: 1 on an ordinary display, 1.5 or 2
/// on a HiDPI one. One for a screen there is not.
pub fn screenScale(self: *App, screen: u32) f32 {
    const at = self.screenAt(screen) orelse return 1;
    return at.scale_x;
}

/// How many times a second a screen refreshes, as its mode says; nought
/// where it does not.
pub fn screenRefreshRate(self: *App, screen: u32) f32 {
    const at = self.screenAt(screen) orelse return 0;
    return @floatFromInt(at.current.refresh_hz);
}

/// How many video modes a screen can be switched to. See `videoMode`.
pub fn videoModeCount(self: *App, screen: u32) u32 {
    const at = self.screenAt(screen) orelse return 0;
    return @intCast(at.modes.len);
}

/// One of a screen's video modes - its resolution, bits and refresh - for a
/// menu of resolutions to pass to `setVideoMode`. Null past the last.
pub fn videoMode(self: *App, screen: u32, index: u32) ?VideoMode {
    const at = self.screenAt(screen) orelse return null;
    if (index >= at.modes.len) return null;
    return at.modes[index];
}

fn screenAt(self: *App, screen: u32) ?*const platform.Monitor {
    const window = if (self.window) |*held| held else return null;
    const list = window.screens();
    if (screen >= list.len) return null;
    return &list[screen];
}

fn rectOf(rect: platform.monitor.Rect) geometry.Rect2i {
    return .init(rect.x, rect.y, @intCast(rect.width), @intCast(rect.height));
}

// -------------------------------------------------------------------------
// The pointer's look
// -------------------------------------------------------------------------
//
// See `platform/cursors.zig`.

/// Where the pointer may go, and whether it shows. See `Window.Cursor`.
pub const Cursor = Window.Cursor;

/// One of the system's own pointer shapes.
pub const CursorShape = platform.CursorShape;

/// Lock the pointer, confine it to the window, hide it, or give it back. See
/// `Cursor`.
///
/// ```zig
/// try app.setCursor(.locked);     // a first-person camera, or a drag
/// const turn = app.input.pointer.dx;
/// ```
///
/// A held pointer is let go when the window loses the keyboard, and taken
/// back when it returns. Nothing without a window.
pub fn setCursor(self: *App, wanted: Cursor) Window.Error!void {
    const window = if (self.window) |*w| w else return;
    try window.setCursor(wanted);
    self.input.pointer.locked = wanted == .locked;
}

/// What the pointer was last asked to do. `.normal` when there is no window.
pub fn cursor(self: *const App) Cursor {
    if (self.window) |*window| return window.cursor();
    return .normal;
}

/// A picture of the game's own for one of the pointer's shapes - `.arrow`
/// is the pointer everywhere, `.pointing_hand` the one over a button, `.ibeam`
/// over text - with `hotspot` the pixel in it that points; `.none` gives the
/// shape back to the system. The picture is read from the texture's file,
/// 256 pixels a side at most.
///
/// ```zig
/// try app.setCustomCursor(try app.assets.loadTexture("res://ui/sword.png", .{}), .arrow, .init(2, 2));
/// try app.setCustomCursor(try app.assets.loadTexture("res://ui/hand.png", .{}), .pointing_hand, .init(8, 1));
/// ```
///
/// A browser quietly keeps its own arrow past a size of its own - 128 by
/// 128 in Chrome and Firefox - so a cursor a page will see should be small.
pub fn setCustomCursor(self: *App, texture: Assets.TextureHandle, shape: CursorShape, hotspot: math.Vec2) !void {
    return pointer.setCustom(self, texture, shape, hotspot);
}

/// The same from a picture's file - `res://`, `user://` or the system's -
/// read without making a texture of it.
pub fn setCustomCursorFile(self: *App, path: []const u8, shape: CursorShape, hotspot: math.Vec2) !void {
    return pointer.setCustomFile(self, path, shape, hotspot);
}

/// The same from pixels in memory - straight RGBA, row by row from the top
/// - which are copied; null gives the shape back to the system.
pub fn setCustomCursorPixels(self: *App, picture: ?platform.CursorImage, shape: CursorShape) !void {
    return self.cursors.setPixels(self.gpa, picture, shape);
}

/// The shape the pointer takes where nothing under it asks for another -
/// over the game's world, over a control that leaves it to the game: the
/// arrow, unless this says otherwise.
pub fn setDefaultCursorShape(self: *App, shape: CursorShape) void {
    self.cursors.default_shape = shape;
}

pub fn defaultCursorShape(self: *const App) CursorShape {
    return self.cursors.default_shape;
}

/// The shape the pointer took in the last frame: what the control under it
/// asked for, or the default.
pub fn currentCursorShape(self: *const App) CursorShape {
    return self.cursors.wanted;
}

// -------------------------------------------------------------------------
// Dialogs and the clipboard
// -------------------------------------------------------------------------

/// Open the system's file dialog over the window, and say which one it is:
/// its answer is `input.dialogAnswer(id)` in the frame it comes back in. See
/// `dialog`.
///
/// ```zig
/// opening = try app.openFileDialog(.{ .filters = &.{.{ .name = "Scenes", .extensions = &.{ "json", "scene" } }} });
/// ```
///
/// `error.Unavailable` while another is open, and where the platform has no
/// dialogs. Headless, it is never answered by itself: a test answers it with
/// `input.answerDialog`.
pub fn openFileDialog(self: *App, options: dialog.FileOptions) dialog.Error!dialog.Id {
    if (self.window) |*window| return window.openFileDialog(options);
    return self.headlessDialog();
}

/// Open the system's folder dialog over the window. See `openFileDialog`.
pub fn openFolderDialog(self: *App, options: dialog.FolderOptions) dialog.Error!dialog.Id {
    if (self.window) |*window| return window.openFolderDialog(options);
    return self.headlessDialog();
}

fn headlessDialog(self: *App) dialog.Id {
    defer self.next_dialog +%= 1;
    if (self.next_dialog == 0) self.next_dialog = 1;
    return @enumFromInt(self.next_dialog);
}

/// Put text on the system clipboard, for every other program to paste - or,
/// with no window, on the program's own. Copied.
///
/// ```zig
/// try app.setClipboardText(seed);
/// ```
///
/// `error.Unavailable` for text that is not UTF-8, and for a system that will
/// not take it: Wayland takes the clipboard only from the window with the
/// keyboard.
pub fn setClipboardText(self: *App, text: []const u8) Clipboard.Error!void {
    return self.clipboard.set(self.gpa, text);
}

/// The text on the clipboard, empty when it holds none: UTF-8 with `\n`
/// between lines, whatever put it there. Lent until the next read - the
/// interface's paste is one - so keep a copy. Read it when it is wanted, not
/// every frame: on X11 and Wayland a read waits on the program that owns it.
pub fn clipboardText(self: *App) Clipboard.Error![]const u8 {
    return self.clipboard.read();
}

/// Whether the clipboard holds text, asked without reading it: for a Paste
/// entry that greys out.
pub fn hasClipboardText(self: *App) bool {
    return self.clipboard.has();
}

// -------------------------------------------------------------------------
// The system
// -------------------------------------------------------------------------

/// The system a game runs on.
pub const Os = enum { windows, macos, linux, android, ios, web, other };

/// Which system this is: for a touch layout on a phone, a quit button left
/// out on the web.
pub fn osName(_: *const App) Os {
    return switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .macos,
        .linux => if (builtin.abi.isAndroid()) .android else .linux,
        .ios => .ios,
        .emscripten, .wasi => .web,
        else => if (builtin.cpu.arch.isWasm()) .web else .other,
    };
}

/// Whether the game was built for finding mistakes rather than for players:
/// slower, with checks.
pub fn isDebugBuild(_: *const App) bool {
    return builtin.mode == .Debug;
}

// -------------------------------------------------------------------------
// Chance
// -------------------------------------------------------------------------
//
// The game's own source of chance, apart from the one UUIDs are drawn from:
// seeded by the operating system when the app is made, or by
// `Options.random_seed` or `seedRandom`, so a run seeded the same way draws
// the same numbers. Not for secrets.

/// A number from nought up to, but not including, one.
pub fn randomFloat(self: *App) f32 {
    return self.random_source.random().float(f32);
}

/// A number from `low` up to `high`.
pub fn randomRange(self: *App, low: f32, high: f32) f32 {
    return low + (high - low) * self.randomFloat();
}

/// A whole number from `low` to `high`, either of them possible, whichever
/// way round they are given.
pub fn randomInt(self: *App, low: i64, high: i64) i64 {
    return self.random_source.random().intRangeAtMost(i64, @min(low, high), @max(low, high));
}

/// True that part of the time: `randomChance(0.25)` one time in four.
pub fn randomChance(self: *App, chance: f32) bool {
    return self.randomFloat() < chance;
}

/// A place in a list of `count` things, to pick one of them by. Nought for
/// a list of none.
pub fn randomIndex(self: *App, count: i64) i64 {
    if (count <= 0) return 0;
    return self.random_source.random().intRangeLessThan(i64, 0, count);
}

/// Start the numbers again from `seed`: the same seed, the same numbers.
pub fn seedRandom(self: *App, seed: i64) void {
    self.random_source = .init(@bitCast(seed));
}

/// Start the numbers again from a seed of the operating system's.
pub fn randomize(self: *App) void {
    self.random_source = .init(self.drawnSeed());
}

fn drawnSeed(self: *const App) u64 {
    var seed: u64 = 0x5EED_F1A5_0000_0001;
    if (self.io) |io| io.random(std.mem.asBytes(&seed));
    return seed;
}

// -------------------------------------------------------------------------
// What scripts and consoles may call
// -------------------------------------------------------------------------

/// `App` as fluxion-reflect sees it: no insides, and the calls a console, a
/// script or an editor's command palette may make by name - see `callNamed`.
/// A call is listed when it takes and gives plain values: the ones taking a
/// type or a function, or holding an allocator, are for Zig to call. Only a
/// program that asks for this descriptor has them compiled in; see `types`.
pub const reflect_name = "App";

pub const reflect_opaque = true;

pub const reflect_methods = .{
    // The loop
    .inForeground = .{},
    .quit = .{},
    // States
    .stateNamed = .{attr.Params{ .names = &.{"state"} }},
    .setStateNamed = .{attr.Params{ .names = &.{ "state", "value" } }},
    // Entities
    .spawn = .{ attr.Params{ .names = &.{"parent"} }, flux.Alias{ .name = "spawnChild" } },
    .createTimer = .{attr.Params{ .names = &.{"seconds"} }},
    .clearWorld = .{},
    // The tree
    .parentOf = .{ attr.Params{ .names = &.{"entity"} }, flux.Alias{ .name = "parent" } },
    .setParent = .{attr.Params{ .names = &.{ "entity", "parent", "keep_global" } }},
    .hangsFrom = .{attr.Params{ .names = &.{ "entity", "ancestor" } }},
    .children = .{attr.Params{ .names = &.{"parent"} }},
    .childCount = .{attr.Params{ .names = &.{"parent"} }},
    .childAt = .{attr.Params{ .names = &.{ "parent", "index" } }},
    .childNamed = .{attr.Params{ .names = &.{ "parent", "name" } }},
    .findPath = .{attr.Params{ .names = &.{ "from", "path" } }},
    .findIn = .{attr.Params{ .names = &.{ "root", "name" } }},
    .siblingIndex = .{attr.Params{ .names = &.{"entity"} }},
    .setSiblingIndex = .{attr.Params{ .names = &.{ "entity", "index" } }},
    // Where things are, through the parent chain
    .worldTransform = .{attr.Params{ .names = &.{"entity"} }},
    .setWorldTransform = .{attr.Params{ .names = &.{ "entity", "transform" } }},
    .globalPosition = .{attr.Params{ .names = &.{"entity"} }},
    .setGlobalPosition = .{attr.Params{ .names = &.{ "entity", "position" } }},
    .globalRotation = .{attr.Params{ .names = &.{"entity"} }},
    .setGlobalRotation = .{attr.Params{ .names = &.{ "entity", "radians" } }},
    .globalScale = .{attr.Params{ .names = &.{"entity"} }},
    .setGlobalScale = .{attr.Params{ .names = &.{ "entity", "scale" } }},
    .globalTranslate = .{attr.Params{ .names = &.{ "entity", "offset" } }},
    .toLocal = .{attr.Params{ .names = &.{ "entity", "point" } }},
    .toGlobal = .{attr.Params{ .names = &.{ "entity", "point" } }},
    .getAngleTo = .{attr.Params{ .names = &.{ "entity", "point" } }},
    .lookAt = .{attr.Params{ .names = &.{ "entity", "point" } }},
    .getRelativeTransformToParent = .{attr.Params{ .names = &.{ "entity", "ancestor" } }},
    .moveLocalX = .{attr.Params{ .names = &.{ "entity", "delta", "scaled" } }},
    .moveLocalY = .{attr.Params{ .names = &.{ "entity", "delta", "scaled" } }},
    .rotate = .{attr.Params{ .names = &.{ "entity", "radians" } }},
    .applyScale = .{attr.Params{ .names = &.{ "entity", "ratio" } }},
    // Names and UUIDs
    .setName = .{attr.Params{ .names = &.{ "entity", "name" } }},
    .setFreeName = .{attr.Params{ .names = &.{ "entity", "name" } }},
    .nameOf = .{ attr.Params{ .names = &.{"entity"} }, flux.Alias{ .name = "name" } },
    .find = .{attr.Params{ .names = &.{"name"} }},
    // Groups
    .addToGroup = .{attr.Params{ .names = &.{ "entity", "group" } }},
    .removeFromGroup = .{attr.Params{ .names = &.{ "entity", "group" } }},
    .isInGroup = .{attr.Params{ .names = &.{ "entity", "group" } }},
    .groupMembers = .{attr.Params{ .names = &.{"group"} }},
    .callGroup = .{attr.Params{ .names = &.{ "group", "method" } }},
    // Pause and appearance
    .setPaused = .{attr.Params{ .names = &.{"paused"} }},
    .isPaused = .{},
    .isProcessing = .{attr.Params{ .names = &.{"entity"} }},
    .setVisible = .{attr.Params{ .names = &.{ "entity", "visible" } }},
    .isVisibleInTree = .{attr.Params{ .names = &.{"entity"} }},
    // Scenes
    .saveScene = .{ attr.Params{ .names = &.{ "path", "options" } }, flux.GivesErrors{} },
    .readScene = .{ attr.Params{ .names = &.{ "path", "options" } }, flux.GivesErrors{} },
    .instantiate = .{attr.Params{ .names = &.{ "scene", "parent" } }},
    .changeScene = .{attr.Params{ .names = &.{"scene"} }},
    .currentScene = .{},
    .reloadCurrentScene = .{},
    .currentSceneRoot = .{},
    // Frame time
    .fps = .{},
    .frameCount = .{},
    .elapsed = .{},
    .setTimeScale = .{attr.Params{ .names = &.{"scale"} }},
    .timeScale = .{},
    .setMaxFps = .{attr.Params{ .names = &.{"fps"} }},
    .maxFps = .{},
    .setBackgroundFps = .{attr.Params{ .names = &.{"fps"} }},
    .backgroundFps = .{},
    .setMaxPhysicsStepsPerFrame = .{attr.Params{ .names = &.{"steps"} }},
    .maxPhysicsStepsPerFrame = .{},
    .setPhysicsTicksPerSecond = .{attr.Params{ .names = &.{"ticks"} }},
    .physicsTicksPerSecond = .{},
    // Keys and the pointer
    .keyDown = .{attr.Params{ .names = &.{"key"} }},
    .keyAxis = .{attr.Params{ .names = &.{ "negative", "positive" } }},
    .keyJustPressed = .{attr.Params{ .names = &.{"key"} }},
    .keyJustReleased = .{attr.Params{ .names = &.{"key"} }},
    .mouseButtonDown = .{attr.Params{ .names = &.{"button"} }},
    .mouseButtonJustPressed = .{attr.Params{ .names = &.{"button"} }},
    .mouseButtonJustReleased = .{attr.Params{ .names = &.{"button"} }},
    .pointerInWorld = .{},
    .pointerOnScreen = .{},
    .warpPointer = .{attr.Params{ .names = &.{ "x", "y" } }},
    .setInputAsHandled = .{},
    // Fingers
    .touchCount = .{},
    .touchAt = .{attr.Params{ .names = &.{"index"} }},
    .touchOf = .{attr.Params{ .names = &.{"finger"} }},
    .fingersDown = .{},
    .twoFingers = .{},
    .hasTouchscreen = .{},
    .setMouseFromTouch = .{attr.Params{ .names = &.{"on"} }},
    .mouseFromTouch = .{},
    .setTouchFromMouse = .{attr.Params{ .names = &.{"on"} }},
    .touchFromMouse = .{},
    .setPinchFromCtrlWheel = .{attr.Params{ .names = &.{"on"} }},
    .pinchFromCtrlWheel = .{},
    // Controllers
    .connectedPads = .{},
    .padConnected = .{ attr.Params{ .names = &.{"pad"} }, attr.defaults(.{@as(?u8, null)}) },
    .padButtonDown = .{ attr.Params{ .names = &.{ "button", "pad" } }, attr.defaults(.{@as(?u8, null)}) },
    .padButtonJustPressed = .{ attr.Params{ .names = &.{ "button", "pad" } }, attr.defaults(.{@as(?u8, null)}) },
    .padButtonJustReleased = .{ attr.Params{ .names = &.{ "button", "pad" } }, attr.defaults(.{@as(?u8, null)}) },
    .padAxis = .{ attr.Params{ .names = &.{ "axis", "pad" } }, attr.defaults(.{@as(?u8, null)}) },
    .padStick = .{ attr.Params{ .names = &.{ "side", "pad" } }, attr.defaults(.{@as(?u8, null)}) },
    // Actions
    .actionDown = .{attr.Params{ .names = &.{"name"} }},
    .actionJustPressed = .{attr.Params{ .names = &.{"name"} }},
    .actionJustReleased = .{attr.Params{ .names = &.{"name"} }},
    .actionStrength = .{attr.Params{ .names = &.{"name"} }},
    .actionAxis = .{attr.Params{ .names = &.{ "negative", "positive" } }},
    .actionVector = .{attr.Params{ .names = &.{ "left", "right", "up", "down" } }},
    .pressAction = .{attr.Params{ .names = &.{ "name", "strength" } }},
    .releaseAction = .{attr.Params{ .names = &.{"name"} }},
    .describeAction = .{attr.Params{ .names = &.{"name"} }},
    .bindAction = .{attr.Params{ .names = &.{ "name", "event" } }},
    .clearAction = .{attr.Params{ .names = &.{"name"} }},
    .saveInputMap = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
    .loadInputMap = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
    // Physics
    .applyImpulse = .{ attr.Params{ .names = &.{ "body", "impulse", "offset" } }, attr.defaults(.{math.Vec2.zero}) },
    .applyForce = .{ attr.Params{ .names = &.{ "body", "force", "offset" } }, attr.defaults(.{math.Vec2.zero}) },
    .applyTorque = .{attr.Params{ .names = &.{ "body", "torque" } }},
    .applyTorqueImpulse = .{attr.Params{ .names = &.{ "body", "impulse" } }},
    .castRay = .{ attr.Params{ .names = &.{ "from", "to", "mask", "hit_areas" } }, attr.defaults(.{ @as(u32, 0xFFFF_FFFF), false }) },
    .forceRaycastUpdate = .{attr.Params{ .names = &.{"entity"} }},
    .isOnFloor = .{attr.Params{ .names = &.{ "entity", "distance" } }},
    .overlapPoint = .{attr.Params{ .names = &.{"point"} }},
    .addCollisionExceptionWith = .{attr.Params{ .names = &.{ "entity", "other" } }},
    .removeCollisionExceptionWith = .{attr.Params{ .names = &.{ "entity", "other" } }},
    .overlappingBodies = .{attr.Params{ .names = &.{"area"} }},
    .overlappingAreas = .{attr.Params{ .names = &.{"area"} }},
    .hasOverlappingBodies = .{attr.Params{ .names = &.{"area"} }},
    .hasOverlappingAreas = .{attr.Params{ .names = &.{"area"} }},
    .overlapsBody = .{attr.Params{ .names = &.{ "area", "body" } }},
    .overlapsArea = .{attr.Params{ .names = &.{ "area", "other" } }},
    // Characters
    .moveAndSlide = .{attr.Params{ .names = &.{"entity"} }},
    .moveAndCollide = .{attr.Params{ .names = &.{ "entity", "motion" } }},
    .slideCollisionCount = .{attr.Params{ .names = &.{"entity"} }},
    .slideCollision = .{attr.Params{ .names = &.{ "entity", "index" } }},
    .lastSlideCollision = .{attr.Params{ .names = &.{"entity"} }},
    // Sound
    .audioLength = .{attr.Params{ .names = &.{"clip"} }},
    .setBusVolumeDb = .{attr.Params{ .names = &.{ "name", "db" } }},
    .busVolumeDb = .{attr.Params{ .names = &.{"name"} }},
    .setBusMute = .{attr.Params{ .names = &.{ "name", "mute" } }},
    .isBusMuted = .{attr.Params{ .names = &.{"name"} }},
    .linearToDb = .{attr.Params{ .names = &.{"linear"} }},
    .dbToLinear = .{attr.Params{ .names = &.{"db"} }},
    // Tweens and animations
    .tween = .{attr.Params{ .names = &.{"owner"} }},
    .tweenProperty = .{attr.Params{ .names = &.{ "tween", "target", "property", "to", "seconds" } }},
    .tweenInterval = .{attr.Params{ .names = &.{ "tween", "seconds" } }},
    .tweenParallel = .{attr.Params{ .names = &.{ "tween", "together" } }},
    .tweenEase = .{attr.Params{ .names = &.{ "tween", "ease" } }},
    .tweenCallback = .{attr.Params{ .names = &.{ "tween", "function" } }},
    .tweenMethod = .{attr.Params{ .names = &.{ "tween", "function", "from", "to", "seconds" } }},
    .tweenFrom = .{attr.Params{ .names = &.{ "tween", "from" } }},
    .tweenRelative = .{attr.Params{ .names = &.{"tween"} }},
    .tweenDelay = .{attr.Params{ .names = &.{ "tween", "seconds" } }},
    .animationNames = .{attr.Params{ .names = &.{"player"} }},
    .hasAnimation = .{attr.Params{ .names = &.{ "player", "name" } }},
    .animationLength = .{attr.Params{ .names = &.{ "player", "name" } }},
    // Drawing
    .drawLine = .{ attr.Params{ .names = &.{ "entity", "from", "to", "color", "width" } }, attr.defaults(.{@as(f32, 1)}) },
    .drawRect = .{ attr.Params{ .names = &.{ "entity", "position", "size", "color", "filled", "width" } }, attr.defaults(.{ true, @as(f32, 1) }) },
    .drawCircle = .{ attr.Params{ .names = &.{ "entity", "center", "radius", "color", "filled", "width" } }, attr.defaults(.{ true, @as(f32, 1) }) },
    .drawArc = .{ attr.Params{ .names = &.{ "entity", "center", "radius", "start_angle", "end_angle", "color", "width" } }, attr.defaults(.{@as(f32, 1)}) },
    .drawPolyline = .{ attr.Params{ .names = &.{ "entity", "points", "color", "width" } }, attr.defaults(.{@as(f32, 1)}) },
    .drawPolygon = .{attr.Params{ .names = &.{ "entity", "points", "color" } }},
    .drawTexture = .{ attr.Params{ .names = &.{ "entity", "texture", "position", "size", "modulate" } }, attr.defaults(.{ math.Vec2.zero, Color.white }) },
    .drawText = .{ attr.Params{ .names = &.{ "entity", "text", "position", "color", "size", "font" } }, attr.defaults(.{ Color.white, @as(f32, 16), Assets.FontHandle.none }) },
    .clearDrawing = .{attr.Params{ .names = &.{"entity"} }},
    .queueRedraw = .{attr.Params{ .names = &.{"entity"} }},
    // Particles
    .restartParticles = .{attr.Params{ .names = &.{"emitter"} }},
    .emitParticles = .{attr.Params{ .names = &.{ "emitter", "count" } }},
    .particleCount = .{attr.Params{ .names = &.{"emitter"} }},
    // Cameras and the screen
    .screenCenter = .{attr.Params{ .names = &.{"camera"} }},
    .resetSmoothing = .{attr.Params{ .names = &.{"camera"} }},
    .screenToWorld = .{attr.Params{ .names = &.{ "x", "y" } }},
    .worldToScreen = .{attr.Params{ .names = &.{ "x", "y" } }},
    .screenSize = .{},
    // The frame
    .setVsyncMode = .{ attr.Params{ .names = &.{"mode"} }, flux.GivesErrors{} },
    .vsyncMode = .{},
    .setStretchMode = .{attr.Params{ .names = &.{"mode"} }},
    .stretchMode = .{},
    .setStretchAspect = .{attr.Params{ .names = &.{"aspect"} }},
    .stretchAspect = .{},
    .setStretchScale = .{attr.Params{ .names = &.{"scale"} }},
    .stretchScale = .{},
    .setStretchScaleMode = .{attr.Params{ .names = &.{"mode"} }},
    .stretchScaleMode = .{},
    .rendererInUse = .{},
    .backendInUse = .{},
    // Tiles
    .cellAt = .{attr.Params{ .names = &.{ "map", "point" } }},
    .tileData = .{attr.Params{ .names = &.{ "map", "x", "y", "layer" } }},
    .tileDataAt = .{attr.Params{ .names = &.{ "map", "point", "layer" } }},
    // The interface
    .grabFocus = .{attr.Params{ .names = &.{"entity"} }},
    .hasFocus = .{attr.Params{ .names = &.{"entity"} }},
    .releaseFocus = .{},
    .controlRect = .{attr.Params{ .names = &.{"entity"} }},
    .setAnchorsPreset = .{attr.Params{ .names = &.{ "entity", "preset" } }},
    .setInterfaceZoom = .{attr.Params{ .names = &.{"zoom"} }},
    .interfaceZoom = .{},
    // Scripts
    .nextFrame = .{flux.Returns{ .builtin = .signal }},
    .callDeferred = .{attr.Params{ .names = &.{"function"} }},
    .readData = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
    // Files of every kind
    .loadInBackground = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
    .loadProgress = .{attr.Params{ .names = &.{"path"} }},
    .loadStatus = .{attr.Params{ .names = &.{"path"} }},
    .finishLoad = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
    // Each kind of file
    .loadSpriteFrames = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
    .newSpriteFrames = .{},
    .saveSpriteFrames = .{ attr.Params{ .names = &.{ "frames", "path" } }, flux.GivesErrors{} },
    // The project
    .gameVersion = .{},
    // A game's files
    .openUrl = .{ attr.Params{ .names = &.{"url"} }, flux.GivesErrors{} },
    // The window
    .setWindowMode = .{ attr.Params{ .names = &.{"mode"} }, flux.GivesErrors{} },
    .windowMode = .{},
    .toggleFullscreen = .{flux.GivesErrors{}},
    .setVideoMode = .{ attr.Params{ .names = &.{"mode"} }, flux.GivesErrors{} },
    .setWindowBorderless = .{ attr.Params{ .names = &.{"borderless"} }, flux.GivesErrors{} },
    .windowBorderless = .{},
    .setWindowResizable = .{ attr.Params{ .names = &.{"resizable"} }, flux.GivesErrors{} },
    .windowResizable = .{},
    .setWindowAlwaysOnTop = .{ attr.Params{ .names = &.{"on_top"} }, flux.GivesErrors{} },
    .windowAlwaysOnTop = .{},
    .setKeepScreenOn = .{ attr.Params{ .names = &.{"on"} }, flux.GivesErrors{} },
    .keepScreenOn = .{},
    .setWindowTitle = .{ attr.Params{ .names = &.{"title"} }, flux.GivesErrors{} },
    .setWindowSize = .{ attr.Params{ .names = &.{ "width", "height" } }, flux.GivesErrors{} },
    .windowSize = .{},
    .setWindowPosition = .{ attr.Params{ .names = &.{ "x", "y" } }, flux.GivesErrors{} },
    .windowPosition = .{},
    .closeRequested = .{},
    // Screens
    .screenCount = .{},
    .windowScreen = .{},
    .primaryScreen = .{},
    .setWindowScreen = .{ attr.Params{ .names = &.{"screen"} }, flux.GivesErrors{} },
    .centerWindow = .{flux.GivesErrors{}},
    .screenRect = .{attr.Params{ .names = &.{"screen"} }},
    .screenUsableRect = .{attr.Params{ .names = &.{"screen"} }},
    .screenScale = .{attr.Params{ .names = &.{"screen"} }},
    .screenRefreshRate = .{attr.Params{ .names = &.{"screen"} }},
    .videoModeCount = .{attr.Params{ .names = &.{"screen"} }},
    .videoMode = .{attr.Params{ .names = &.{ "screen", "index" } }},
    // The pointer's look
    .setCursor = .{ attr.Params{ .names = &.{"mode"} }, flux.GivesErrors{} },
    .cursor = .{},
    .setCustomCursor = .{ attr.Params{ .names = &.{ "image", "shape", "hotspot" } }, attr.defaults(.{ CursorShape.arrow, math.Vec2.init(0, 0) }), flux.GivesErrors{} },
    .setDefaultCursorShape = .{attr.Params{ .names = &.{"shape"} }},
    .defaultCursorShape = .{},
    .currentCursorShape = .{},
    // Dialogs and the clipboard
    .setClipboardText = .{ attr.Params{ .names = &.{"text"} }, flux.GivesErrors{} },
    .clipboardText = .{flux.GivesErrors{}},
    .hasClipboardText = .{},
    // The system
    .osName = .{},
    .isDebugBuild = .{},
    // Chance
    .randomFloat = .{},
    .randomRange = .{attr.Params{ .names = &.{ "low", "high" } }},
    .randomInt = .{attr.Params{ .names = &.{ "low", "high" } }},
    .randomChance = .{attr.Params{ .names = &.{"chance"} }},
    .randomIndex = .{attr.Params{ .names = &.{"count"} }},
    .seedRandom = .{attr.Params{ .names = &.{"seed"} }},
    .randomize = .{},
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a program in the background is held to its background cap" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 6, .io = testing.io });
    defer app.destroy();
    app.setMaxFps(1000);
    app.setBackgroundFps(100);
    try testing.expectEqual(@as(?f32, 1000), app.frameCap());

    app.input.focused = false;
    try testing.expect(!app.inForeground());
    try testing.expectEqual(@as(?f32, 100), app.frameCap());
    try app.run();
    try testing.expect(app.time.elapsed >= 0.03);

    app.setBackgroundFps(0);
    try testing.expectEqual(@as(?f32, 1000), app.frameCap());
}
