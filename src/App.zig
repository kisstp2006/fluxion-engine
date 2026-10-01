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
const image = @import("fluxion_image");
const debugdraw = @import("fluxion_debugdraw");
const debugdraw_rhi = @import("fluxion_debugdraw_rhi");
const ui_lib = @import("fluxion_ui");
const typeface = @import("fluxion_font");
const physics_lib = @import("fluxion_physics");
const json = @import("fluxion_json");
const reflect = @import("fluxion_reflect");
const vfs = @import("fluxion_vfs");
const Uuid = @import("fluxion_id").Uuid;

const Assets = @import("assets/assets.zig");
const attr = @import("reflect/attr.zig");
const Areas = @import("physics/areas.zig");
const Bodies = @import("physics/bodies.zig");
const Picking = @import("physics/picking.zig");
const InputEvent = @import("input/input_event.zig").InputEvent;
const Clipboard = @import("platform/clipboard.zig");
const Commands = @import("core/commands.zig");
const control = @import("ui/control.zig");
const DebugViews = @import("render/debug_views.zig");
const dialog = @import("platform/dialog.zig");
const Project = @import("project/Project.zig");
const States = @import("core/states.zig");
const Interface = @import("ui/interface.zig");
const Input = @import("input/input.zig");
const Time = @import("time/frame_time.zig");
const Window = @import("platform/window.zig");
const ToolWindow = @import("ui/tool_window.zig");
const world_ui = @import("ui/world_ui.zig");
const schedule_mod = @import("core/schedule.zig");
const components = @import("scene/components.zig");
const hierarchy = @import("scene/hierarchy.zig");
const inherited_mod = @import("scene/inherited.zig");
const drawing_mod = @import("render/drawing.zig");
const particles_mod = @import("render/particles.zig");
const lights_mod = @import("render/lights.zig");
const timer = @import("time/timer.zig");
const touch_mod = @import("ui/touch_button.zig");
const tilemap = @import("tiles/tilemap.zig");
const geometry = @import("math/geometry.zig");
const AssetKind = @import("assets/asset_kind.zig").AssetKind;
const theme = @import("ui/theme.zig");
const tileset = @import("tiles/tileset.zig");
const scene = @import("scene/scene.zig");
const scenes_mod = @import("assets/scene_table.zig");
const data_mod = @import("assets/data_files.zig");
const audio_mod = @import("audio/audio.zig");
const property_mod = @import("reflect/property.zig");
const tween_mod = @import("animation/tween.zig");
const texts_mod = @import("scene/component_texts.zig");
const animation_mod = @import("animation/animation.zig");
const sprite_frames_mod = @import("animation/sprite_frames.zig");
const exports_mod = @import("script/script_exports.zig");
const background_mod = @import("assets/background_load.zig");
const signals_mod = @import("core/signals.zig");
const events_mod = @import("core/event_channels.zig");
const script_mod = @import("script/script.zig");
const datetime = @import("time/datetime.zig");
const clocks_mod = @import("time/game_clocks.zig");
const sprite = @import("render/sprite.zig");
const View = @import("render/view.zig").View;
const Screen = @import("render/screen.zig").Screen;
const shaders_mod = @import("render/shaders.zig");
const views_mod = @import("render/view_textures.zig");
const character = @import("physics/character.zig");
const stretch_mod = @import("render/stretch.zig");

const Color = @import("math/color.zig").Color;
const ConfigFile = @import("files/config_file.zig").ConfigFile;
const sealed = @import("files/sealed.zig");
const Image = @import("assets/images.zig").Image;
const Schedule = schedule_mod.Schedule;
const Stage = schedule_mod.Stage;
const System = schedule_mod.System;

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

/// Which drawing API to open.
pub const Backend = enum {
    /// The best of the project's renderer on this system - see
    /// `Project.Renderer.backends` - and with no project file the
    /// compatibility renderer's: Direct3D 11 on Windows, OpenGL on Linux,
    /// macOS and Android, WebGL in a browser.
    auto,
    /// OpenGL 3.3.
    gl,
    /// Direct3D 11. Windows only.
    d3d11,
    /// Direct3D 12. Windows only. Experimental: see `experimental`.
    d3d12,
    /// Vulkan: Windows, Linux and Android, where a driver has it.
    /// Experimental: see `experimental`.
    vulkan,
    /// WebGL 2, in a browser.
    webgl,
    /// Accepts everything, draws nothing. What `.headless` uses.
    none,

    /// Whether it is still being finished: it draws everything the engine
    /// does, the picture the others do, and is slower than they are and
    /// less proven - which the log says when one opens.
    pub fn experimental(self: Backend) bool {
        return self == .d3d12 or self == .vulkan;
    }
};

pub const BackendError = error{
    /// The project's renderer has no backend on this system: `modern` in a
    /// browser, or on macOS.
    RendererNotBuilt,
};

/// The backend to open: `wanted` as it is, unless it is `auto`, which is
/// the best of `renderer`'s backends on `os`. A renderer with none is an
/// error rather than a quiet fall back to another, which would hide what the
/// game really looks like.
/// The backends a game is drawn with, the first to try first: the one asked
/// for alone, never another, or the project's renderer's - see
/// `Rendering.backendsFor`. Empty where its renderer has none here.
pub fn backendsToTry(wanted: Backend, rendering: Project.Rendering, os: std.Target.Os.Tag, buffer: *[Project.Rendering.max_backends]Backend) []const Backend {
    if (wanted != .auto) {
        buffer[0] = wanted;
        return buffer[0..1];
    }
    return rendering.backendsFor(os, buffer);
}

/// How the window is on the screen: windowed, minimised, maximised,
/// fullscreen or exclusively so. See `Window.Mode`.
pub const WindowMode = Window.Mode;

/// How frames are shown against the display's refresh. See
/// `Window.VsyncMode`.
pub const VsyncMode = Window.VsyncMode;

/// A display's resolution, bits and refresh: what `exclusive_fullscreen`
/// switches it to. See `setVideoMode`.
pub const VideoMode = platform.VideoMode;

/// Where the window opens.
pub const InitialPosition = enum {
    /// In the middle of the screen the system calls its primary.
    center_of_primary_screen,
    /// In the middle of the screen `screen` names, counting from nought.
    center_of_screen,
    /// At `position`, the top left of its content, on the desktop.
    absolute,
};

/// Where the pointer may go, and whether it shows. See `Window.Cursor`.
pub const Cursor = Window.Cursor;

/// One of the system's own pointer shapes.
pub const CursorShape = platform.CursorShape;

/// How small and how large the player may drag the window.
pub const WindowSizeLimits = Window.SizeLimits;

pub const Options = struct {
    /// What the title bar says. Null is the project's name, from its project
    /// file, or "fluxion" with none.
    title: ?[]const u8 = null,
    /// The window's size. Null is what the project file's `display` says -
    /// 1280 by 720 with none. So are the four below: a game says them in code
    /// only to overrule its project.
    width: ?u32 = null,
    height: ?u32 = null,
    backend: Backend = .auto,
    /// How frames are shown against the refresh. Null is the project file's
    /// `display.vsync_mode`: enabled, with none.
    vsync_mode: ?VsyncMode = null,
    /// The most frames a second, slept down to. Null is what the project
    /// file's `application.max_fps` says - no limit, with nought or none.
    max_fps: ?f32 = null,
    /// Open what the project says a game opens with, at `startup`: see
    /// `openProject`. A game made in code leaves it off and spawns its own.
    open_project: bool = false,

    /// Whether the player may drag the window's edges. `setWindowSize` works
    /// either way.
    resizable: ?bool = null,

    /// How the window opens: a window, minimised, maximised, or filling the
    /// screen. `width` and `height` are still the size of the window it
    /// goes back to. Null is the project file's `display.mode`.
    window_mode: ?WindowMode = null,

    /// With no frame or title bar of the system's. Null is the project
    /// file's `display.borderless`.
    borderless: ?bool = null,

    /// Kept over every window that is not kept so itself. Null is the
    /// project file's `display.always_on_top`.
    always_on_top: ?bool = null,

    /// Where the window opens, the screen for `center_of_screen` and the
    /// point for `absolute`. Null is the project file's `display`.
    initial_position: ?InitialPosition = null,
    screen: ?u16 = null,
    position: ?geometry.Vec2i = null,

    /// Keep the screen from blanking, and the machine from sleeping, while
    /// the game runs. Null is the project file's `display.keep_screen_on`.
    keep_screen_on: ?bool = null,

    /// How the frame fits the window. Null is the project file's
    /// `display.stretch_mode` and `stretch_aspect`, over its `width` and
    /// `height`: an editor, whose window is its own and not the game's, says
    /// `.{}` - the window itself. See `stretch.zig`.
    stretch: ?stretch_mod.Stretch = null,

    /// The least the window may be dragged to. Null is the project file's
    /// `display.min_width` and `min_height`; an editor says its own.
    min_size: ?[2]u32 = null,

    /// Put the project file's `application.icon` on the window. An editor,
    /// whose window is its own and not the game's, leaves it off.
    project_icon: bool = true,
    /// Take the project file's `display.mouse_cursor` for the pointer. An
    /// editor, drawing its own interface, leaves it off.
    project_cursor: bool = true,

    /// Take the project file's actions, over the built-in ones. An editor,
    /// whose keys are its own and not the game's, leaves it off, and moves
    /// round its interface with the built-in ones alone.
    project_input: bool = true,

    /// What files are read with and the clock is read from. Null means no
    /// files and a fixed step, as in a test.
    io: ?std.Io = null,

    /// Where the game's chance starts - `randomFloat` and the rest - so a
    /// run can be played again the same. Null draws it from the operating
    /// system, or with no `io` is a constant.
    random_seed: ?u64 = null,

    /// The project's root directory, which `res://` paths are from - or its
    /// `project.fluxion`, which names the same directory. Null is the working
    /// directory. See `Project`.
    root: ?[]const u8 = null,

    /// Where `user://` is: the player's saves and settings. Null is a folder
    /// named after the game in the one the system keeps for programs' data.
    /// A test gives its own; so may a game kept on a stick, with its saves
    /// beside it. See `Project.userRoot`.
    user_root: ?[]const u8 = null,

    /// The pack a shipped game is: `res://`, `uid://` and the project file
    /// are read out of it instead of `root`. The App owns it from `create`
    /// on, whether `create` succeeds or not. See `Project.usePack`.
    pack: ?vfs.Pack = null,

    /// Where the project file went wrong, when it did: `create` fails then,
    /// and says it in the log as well.
    project_diagnostics: ?*json.Diagnostics = null,

    /// Every frame counts as exactly this many seconds, whatever the clock
    /// says, so every run is the same.
    frame_time: ?f32 = null,

    /// Every frame counts as exactly one fixed step, whatever the clock says
    /// and however long the project makes the step. `Flags.apply` sets it for
    /// `--capture`.
    fixed_frame_time: bool = false,

    /// A key that ends the game, handled after the `.input` stage. Null leaves
    /// every key to the game.
    quit_key: ?platform.Key = null,

    /// A key that toggles borderless fullscreen, handled the same way. F11
    /// rather than Alt+Enter, which DXGI answers on its own on `d3d11`.
    fullscreen_key: ?platform.Key = null,

    /// A key that shows and hides everything `debug` draws, handled the same
    /// way: F3, say. See `App.debug_visible`.
    debug_key: ?platform.Key = null,

    /// No window, no display, no GPU: the `none` backend, drawing into a
    /// texture.
    headless: bool = false,

    /// The window's close button - and Alt+F4 - only ask: `close_pressed`
    /// says so, and the program ends the run with `quit` if it agrees. For a
    /// program with unsaved work to ask about; a game closes at once.
    ask_before_closing: bool = false,

    /// What the frame is cleared to. Null is the project file's
    /// `rendering.clear_color`.
    background: ?Color = null,

    /// One fixed step, in seconds. Null is a step of the project file's
    /// `physics_2d.ticks_per_second` - sixty a second, with none.
    fixed_delta: ?f32 = null,

    /// Stop after this many frames. A headless app has no window to close, so
    /// it needs this or a system that calls `quit`.
    frames: ?u32 = null,

    /// Worker threads for parallel queries. Null is one fewer than the cores.
    workers: ?u32 = null,

    /// Where the game's sound goes: the machine's sound device, or - as
    /// headless always does - mixed each frame and heard nowhere. See
    /// `audio.zig`.
    audio: audio_mod.Output = .auto,

    /// A hundred units to the metre, for a world measured in pixels: what
    /// the physics' tolerances are scaled by. The engine keeps its own
    /// rules whatever the rest says: gravity is `physics_2d`'s, two
    /// colliders touch when either one's mask has the other's layer, and a
    /// pair's friction is the smaller and its bounce the sum.
    physics: physics_lib.Settings = .{ .units_per_metre = 100 },

    /// How the 2D world moves - gravity, and what a body's damping of minus
    /// one means - for a game with no project file: the defaults, a gravity
    /// of 98 where a unit is a pixel. A project file's `physics_2d` is
    /// taken instead.
    physics_2d: Project.Physics2D = .{},
};

/// The command-line flags the engine understands, read with `parseFlags` and
/// laid over a game's `Options` with `apply`. A flag that was not given
/// leaves the game's choice alone.
///
/// ```bash
/// game --backend d3d11 --width 1280 --height 720
/// game --frames 300 --capture shot.png
/// ```
pub const Flags = struct {
    /// `--backend gl` or `--backend d3d11`.
    backend: ?Backend = null,
    /// `--width 1280`, `--height 720`: the window's size.
    width: ?u32 = null,
    height: ?u32 = null,
    /// `--window-mode maximized`: how it opens. See `WindowMode`.
    window_mode: ?WindowMode = null,
    /// `--screen 1`: in the middle of that screen, counting from nought.
    screen: ?u16 = null,
    /// `--position-x 100 --position-y 80`: there, its content's top left
    /// on the desktop. One of the two alone is nought for the other.
    position_x: ?i32 = null,
    position_y: ?i32 = null,
    /// `--frames 300`: stop after this many.
    frames: ?u32 = null,
    /// `--capture shot.png`: where `saveCapture` puts the last frame. See
    /// `apply`.
    capture: ?[]const u8 = null,
    /// `--root ../my-game`: the project's root, which `res://` paths are
    /// from.
    root: ?[]const u8 = null,

    /// How long a capture runs when `--frames` does not say: two seconds.
    pub const capture_frames = 120;

    /// These flags over `options`. A capture also stops after `--frames` -
    /// or `capture_frames` - and counts every frame as one fixed step, so the
    /// same flags draw the same picture on every machine.
    pub fn apply(self: Flags, options: Options) Options {
        var out = options;
        if (self.backend) |backend| out.backend = backend;
        if (self.width) |width| out.width = width;
        if (self.height) |height| out.height = height;
        if (self.window_mode) |mode| out.window_mode = mode;
        if (self.screen) |screen| {
            out.initial_position = .center_of_screen;
            out.screen = screen;
        }
        if (self.position_x != null or self.position_y != null) {
            out.initial_position = .absolute;
            out.position = .init(self.position_x orelse 0, self.position_y orelse 0);
        }
        if (self.frames) |frames| out.frames = frames;
        if (self.root) |root| out.root = root;
        if (self.capture != null) {
            out.frames = out.frames orelse capture_frames;
            out.fixed_frame_time = true;
        }
        return out;
    }
};

pub const FlagError = error{
    /// A flag no field answers to - usually a typo, so it stops the program.
    UnknownFlag,
    /// A flag at the end of the line with nothing after it.
    MissingValue,
    /// A value its field cannot hold: letters for a number, or a name the
    /// enum does not have.
    InvalidValue,
};

/// Read `--name value` flags into a struct of optional fields: a field
/// `write_atlas` is the flag `--write-atlas`.
///
/// ```zig
/// const flags = try App.parseFlags(App.Flags, arguments);
///
/// // A game with flags of its own puts the engine's beside them:
/// const Mine = struct { app: App.Flags = .{}, write_atlas: ?[]const u8 = null };
/// const mine = try App.parseFlags(Mine, arguments);
/// ```
///
/// The struct is read at compile time with `@typeInfo`: its field names are
/// the flags, its field types say how to read the values - text, a whole
/// number, an enum - and a field that is a struct has its fields read as
/// flags too. The first argument is the program's own name and is skipped.
pub fn parseFlags(comptime T: type, arguments: []const []const u8) FlagError!T {
    var flags: T = .{};
    var at: usize = 1;
    while (at < arguments.len) : (at += 2) {
        if (at + 1 == arguments.len) return error.MissingValue;
        if (!try setFlag(T, &flags, arguments[at], arguments[at + 1])) return error.UnknownFlag;
    }
    return flags;
}

/// Set the field of `T` - or of a struct inside it - that `name` names.
/// False when no field answers to it.
fn setFlag(comptime T: type, into: *T, name: []const u8, value: []const u8) FlagError!bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        switch (@typeInfo(field.type)) {
            .@"struct" => if (try setFlag(field.type, &@field(into, field.name), name, value)) return true,
            .optional => |optional| if (std.mem.eql(u8, name, comptime flagName(field.name))) {
                @field(into, field.name) = try flagValue(optional.child, value);
                return true;
            },
            else => @compileError("fluxion-engine: the flag field '" ++ field.name ++
                "' has to be optional - a flag that was not given is null - or a struct of flags"),
        }
    }
    return false;
}

/// `write_atlas` as `--write-atlas`, worked out once, at compile time.
fn flagName(comptime field: []const u8) []const u8 {
    comptime {
        var name: [field.len + 2]u8 = undefined;
        name[0] = '-';
        name[1] = '-';
        for (field, 0..) |c, i| name[i + 2] = if (c == '_') '-' else c;
        const done = name;
        return &done;
    }
}

/// One flag's value, read as whatever its field holds.
fn flagValue(comptime V: type, text: []const u8) FlagError!V {
    if (V == []const u8) return text;
    return switch (@typeInfo(V)) {
        .int => std.fmt.parseInt(V, text, 10) catch error.InvalidValue,
        .@"enum" => std.meta.stringToEnum(V, text) orelse error.InvalidValue,
        else => @compileError("fluxion-engine: a flag holds text, a whole number or an enum, not " ++ @typeName(V)),
    };
}

gpa: Allocator,
io: ?std.Io,
/// How hard `writeSecret`'s password is made to guess. See `sealed.Cost`.
secret_cost: sealed.Cost = .default,
/// How many textures `newTexture` has named.
image_textures: u32 = 0,

/// Null when headless.
window: ?Window = null,
/// The program's other windows, each with an interface of its own: see
/// `openToolWindow`.
tool_windows: std.ArrayList(*ToolWindow) = .empty,
/// The actions the touch buttons held last frame. See `touch_button.zig`.
touch_actions: std.ArrayList(touch_mod.ActionName) = .empty,
device: rhi.Device,
/// What the frame is drawn into: a swapchain image, or a texture when there
/// is no window.
surface: ?rhi.Surface = null,
offscreen: ?rhi.Texture = null,

/// Everything in the game.
world: ecs.World,
/// Spawns, despawns, adds and removes that wait for the system asking for
/// them to return, so a query can ask. See `commands.zig`.
commands: Commands,
/// What a parallel query runs on. See `ecs.Query.each`.
jobs: ecs.Jobs,

/// Rigid bodies, stepped after each `.fixed` stage. The engine makes one for
/// every `RigidBody2D`; gravity, joints and the rest are here.
physics: physics_lib.World,
/// How the 2D world moves: the project file's `physics_2d`, or
/// `Options.physics_2d` with none. Its gravity is put into `physics` as the
/// app starts; a body reads its damping from here when it is synced.
physics_2d: Project.Physics2D,
/// Which body is which entity's. See `bodies.zig`.
bodies: Bodies = .{},

/// Every `.tileset` file read, and the handles a `TileMap` points at one
/// with. See `loadTileSet`.
tile_sets: tileset.TileSets = .{},
/// Every `.theme` file read, and the handles a `Control` points at one with.
/// See `loadTheme`.
themes: theme.Themes = .{},
/// Every scene read as a file to make things of: see `loadScene`.
scenes: scenes_mod.Scenes = .{},
/// Every data file read: see `loadData`.
data_files: data_mod.DataFiles = .{},
/// The sound device, the clips read, the project's buses and what the
/// players play: see `audio.zig` and `loadAudio`.
audio: audio_mod.Audio,
/// Each tween's steps: see `tween.zig` and `tween`.
tweens: tween_mod.Tweens = .{},
/// The pictures the game gave the pointer's shapes: see `setCustomCursor`.
custom_cursors: [@typeInfo(CursorShape).@"enum".fields.len]?CustomCursor = @splat(null),
/// What the pointer is where nothing asks for another shape.
default_cursor_shape: CursorShape = .arrow,
/// The shape the last frame's interface asked for, and what the window was
/// last told, with the pictures as they were then.
cursor_wanted: CursorShape = .arrow,
cursor_shown: ?struct { shape: CursorShape, generation: u32 } = null,
cursor_generation: u32 = 0,
/// The game's own clocks: see `game_clocks.zig` and `newClock`.
clocks: clocks_mod.Clocks = .{},
/// The culture dates and times are written in, once asked for: see
/// `culture`.
culture_held: ?*datetime.Culture = null,
/// The locale `setLocale` chose, over the project's.
locale_chosen: ?[]u8 = null,
/// The words components keep beside them: see `component_texts.zig` and `textOf`.
texts: texts_mod.Texts = .{},
/// Every `.shader` file read, compiled for the 2D layer: see `shaders.zig`
/// and `loadShader`.
shaders: shaders_mod.Shaders = .{},
/// The numbers each `Material` gives its shader: see `setShaderParam`.
shader_params: shaders_mod.Params = .{},
/// The picture each `RenderView` draws: see `view_textures.zig` and `viewTexture`.
views: views_mod.Views = .{},
/// How the frame fits the window, and the size the game was made at. See
/// `stretch.zig`.
stretch: stretch_mod.Stretch = .{},
/// What this frame is laid out and drawn at, and where on the window it is
/// shown: the window itself unless the project stretches its game.
frame: stretch_mod.Frame = .window(1, 1),
/// Every `.anim` file read: see `animation.zig` and `loadAnimations`.
animation_libraries: animation_mod.Libraries = .{},
/// What each `AnimationPlayer`'s tracks are bound to.
animation_players: animation_mod.Players = .{},
/// Every `.frames` file read: see `sprite_frames.zig` and `loadSpriteFrames`.
sprite_frames: sprite_frames_mod.AllFrames = .{},
/// The theme the project file names for every control, and the path it was
/// read by: see `projectTheme`.
project_theme: ProjectTheme = .{},
/// Which entity holds each chunk of each map, so painting a tile finds its
/// chunk without walking every chunk in the world. Kept beside the world,
/// as the names are: a chunk holds no handle of its own.
tile_chunks: std.AutoHashMapUnmanaged(ChunkKey, ecs.Entity) = .empty,
/// What is inside each `Area2D`, and the signals that say so. See
/// `areas.zig`.
areas: Areas = .{},
/// What the pointer is over, and what it did there. See `picking.zig`.
picking: Picking = .{},

/// Whether the pointer picks what it is over at all. An editor turns it off
/// while it edits a scene rather than plays it.
physics_object_picking: bool = true,
/// Whether what is picked comes in the order it is drawn, the topmost
/// first. Off, the order is the broadphase's.
physics_object_picking_sort: bool = true,
/// Whether only the first of several under the pointer hears the event.
physics_object_picking_first_only: bool = false,

/// Where the game's files are - `res://` - and the UUIDs of the ones that
/// have them. See `Project`.
project: Project,

assets: Assets,
sprites: sprite.Renderer,
/// Where a frame something reads is drawn, and copied for what reads it.
/// See `render/screen.zig`.
screen: Screen,

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
/// See `debug_views.zig`.
debug_views: DebugViews = .{},

/// What `.ui` systems declare the interface into.
ui: ui_lib.Ui,
control_nodes: control.Nodes = .{},
/// How the interface is fed and drawn: its font, scale and safe area.
interface: Interface = .{},

/// The system's clipboard, or the program's own without a window. See
/// `setClipboardText`.
clipboard: Clipboard = .{},

/// The id the next headless dialog gets. See `openFileDialog`.
next_dialog: u32 = 1,

/// Where `moveToTrash` puts things instead of the system's trash, when set:
/// a folder, in the freedesktop.org layout a file manager restores from. For
/// a test, which must not fill a person's own trash. Borrowed.
trash: ?[]const u8 = null,

time: Time,

/// Where each interpolating transform was before the last fixed step: the
/// engine's own bookkeeping, beside the world. See `Transform2D.interpolate`.
snapshots: hierarchy.Snapshots = .empty,

/// What `despawnOrphans` found. Kept for its capacity.
orphans: std.ArrayList(ecs.Entity) = .empty,

/// Every named entity's name, and every name's entities, in the order they
/// were given it: `find`'s answer is the first living one. Each name's text
/// is one allocation, the key in `by_name`, which `names` points into and
/// which is freed when nothing has the name any more. An array map, so that
/// `forgetDeadNames` can walk it by index while removing from it.
names: std.AutoArrayHashMapUnmanaged(ecs.Entity, []const u8) = .empty,
by_name: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(ecs.Entity)) = .empty,

/// Every entity given a UUID, and every UUID's entity: kept beside the world
/// as names are, and written into a scene with it. An array map, for the same
/// reason as `names`.
uuids: std.AutoArrayHashMapUnmanaged(ecs.Entity, Uuid) = .empty,
by_uuid: std.AutoHashMapUnmanaged(Uuid, ecs.Entity) = .empty,
/// Each entity's place among its parent's children, for the ones given one
/// by `setSiblingIndex` or a scene's list: kept beside the world as names
/// are. See `childrenOf`.
sibling_ranks: std.AutoArrayHashMapUnmanaged(ecs.Entity, u64) = .empty,
/// The next place given out.
next_rank: u64 = 0,
/// Each parent's children in their order, and the roots: see `childrenOf`.
tree: Tree = .{},
/// The groups entities are in, by name, each with its members in the order
/// they joined. See `addToGroup`.
groups: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(ecs.Entity)) = .empty,
/// Whether the game is paused. See `setPaused`.
paused: bool = false,
/// What each entity inherits - `Processing` and `Appearance` - worked out
/// as it is asked for. See `inherited.zig`.
inherited: inherited_mod.Inherited = .{},
/// Every instance of a scene in the world, by its root: what it is an
/// instance of, and what it made. See `instantiate`.
instances: std.AutoArrayHashMapUnmanaged(ecs.Entity, Instance) = .empty,
/// The scene the game is playing, and its roots: what `changeScene` takes
/// away. See `openScene`.
scene_now: scenes_mod.SceneHandle = .none,
/// What `connectedPads` hands out.
connected_pads: [Input.max_pads]u8 = undefined,
/// What each character's last `moveAndSlide` met, in order.
slide_collisions: std.AutoArrayHashMapUnmanaged(ecs.Entity, std.ArrayList(character.Collision)) = .empty,
/// What the overlap questions hand out.
overlaps_found: std.ArrayList(ecs.Entity) = .empty,
/// What `animationNames` hands out.
names_found: std.ArrayList([]const u8) = .empty,
/// What each `Drawing2D` has drawn: see `drawing.zig`.
drawings: drawing_mod.Drawings = .{},
/// Each `Particles2D`'s particles: see `particles.zig`.
particles: particles_mod.Particles = .{},
scene_roots: std.ArrayListUnmanaged(ecs.Entity) = .empty,
/// The scene `changeScene` asked for, opened at the end of the frame.
scene_next: ?scenes_mod.SceneHandle = null,
/// Scenes reading in the background: see `loadInBackground`.
loads: std.ArrayListUnmanaged(*background_mod.Load) = .empty,
/// What `newUuid` draws from: seeded by the operating system, or with no
/// `Io` by a constant, so a test makes the same ones every run.
uuid_source: std.Random.DefaultCsprng,
/// What the game's chance is drawn from: `randomFloat` and the rest.
random_source: std.Random.DefaultPrng,

/// What a scene can hold, and what each component is called in one: the
/// engine's own from the start, and a game's once `registerComponents` has
/// been told about them.
scene_components: scene.Registry = .{},
/// The components scenes held that nothing here is registered as, each kept
/// with its entity and written back with it. See `unknownComponentsOf`.
unknown_components: scene.Unknown = .{},
/// What each entity's script's `@export`s are given in place of their
/// defaults. See `script_exports.zig`.
exports: exports_mod.Exports = .{},

/// Every signal's connections, the calls waiting for their sync point, and
/// `dispatch`, the switch that makes none. See `signal`.
signals: signals_mod.Signals,

/// Every type of event sent, by type. See `send` and `events`.
event_channels: std.AutoArrayHashMapUnmanaged(usize, EventChannel) = .empty,

/// Flux scripts: the VM, the files, and every entity's instance, once
/// `useScripts` has made them. See `script`.
scripts: ?*script_mod.Scripts = null,

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

input: Input = .{},
/// `describeAction`'s words, for the call that asked.
described: [64]u8 = undefined,
schedule: Schedule = .empty,

/// The game's own states: menu, playing, paused. See `states.zig`.
states: States = .{},
/// What `addSystemsIn` is adding under, while it runs.
gate: ?schedule_mod.Condition = null,

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

/// The engine's own shortcuts, from `Options`. Null is off.
quit_key: ?platform.Key = null,
fullscreen_key: ?platform.Key = null,
debug_key: ?platform.Key = null,

/// How frames are shown against the refresh, as last asked: kept for a
/// headless app too, which has no display to wait for.
vsync_mode_now: VsyncMode = .enabled,

/// The frame the window's close button was last pressed in: see
/// `closeRequested`.
close_frame: ?u64 = null,

/// Cleared by `quit`, and by the frame counter running out.
running: bool = true,

/// From `Options`: whether the close button only sets `close_pressed`.
/// Whether `startup` opens the project: see `Options.open_project`.
open_project: bool = false,
ask_before_closing: bool = false,

/// Set when the window's close button was pressed and `ask_before_closing`
/// kept that from ending the run, until the program has answered it and sets
/// it back.
close_pressed: bool = false,
frames_left: ?u32,
started: bool = false,

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
        .physics = .init(gpa, withEngineRules(options.physics)),
        .physics_2d = options.physics_2d,
        .bodies = .{},
        .tile_sets = .{},
        .themes = .{},
        .tile_chunks = .empty,
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
        .control_nodes = .{},
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
        .orphans = .empty,
        .names = .empty,
        .by_name = .empty,
        .uuids = .empty,
        .by_uuid = .empty,
        .uuid_source = undefined,
        .random_source = undefined,
        .scene_components = .{},
        .audio = undefined,
        .signals = .init(gpa),
        .event_channels = .empty,
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

    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = @splat(0x5E);
    if (options.io) |io| io.random(&seed);
    self.uuid_source = .init(seed);
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
    self.audio = audio_mod.Audio.init(gpa, options.audio, options.headless, if (self.project.settings) |held| held.audio.buses else &.{}) catch |err| return switch (err) {
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
    self.fitFrame();
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
    self.registerComponents(.{
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
        drawing_mod.Drawing2D,
        particles_mod.Particles2D,
        lights_mod.PointLight2D,
        lights_mod.DirectionalLight2D,
        lights_mod.AmbientLight2D,
        lights_mod.LightOccluder2D,
        timer.Timer,
        audio_mod.AudioPlayer,
        audio_mod.AudioSpatial2D,
        audio_mod.AudioListener2D,
        tween_mod.Tween,
        animation_mod.AnimationPlayer,
        sprite_frames_mod.AnimatedSprite2D,
        shaders_mod.Material,
        inherited_mod.Processing,
        inherited_mod.Appearance,
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
        touch_mod.TouchButton,
    }) catch |err| switch (err) {
        error.ComponentNameTaken => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    self.types.addAll(.{ DebugViews, Color, components.Region, Assets.TextureHandle, Assets.FontHandle, tileset.TileSetHandle, theme.ThemeHandle, audio_mod.AudioClipHandle, animation_mod.AnimationLibraryHandle, sprite_frames_mod.SpriteFramesHandle, sprite_frames_mod.LoopMode, shaders_mod.ShaderHandle, character.Collision, geometry.Vec2i, geometry.Rect2, geometry.Rect2i }) catch |err| switch (err) {
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
        self.openDisplay(gpa, options, resolved, backend) catch |err| {
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
    if (options.project_icon) self.useProjectIcon();
    if (options.project_cursor) self.useProjectCursor();

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

/// The window, the device and what is drawn into, for one backend: the
/// window kept from a backend tried before where it does for this one, and
/// made again where it does not - no platform lets a window change its mind
/// about an OpenGL context. What this attempt made is undone where it fails.
fn openDisplay(self: *App, gpa: Allocator, options: Options, resolved: Resolved, backend: Backend) !void {
    const wants_gl = backend == .gl;
    if (self.window) |*w| if (w.has_gl_context != wants_gl) {
        w.close();
        self.window = null;
    };
    if (!options.headless and self.window == null) {
        // Opened in place: its handle points at the context beside it.
        self.window = @as(Window, undefined);
        self.window.?.open(gpa, .{
            .title = titleOf(options, self.project.settings),
            .width = resolved.width,
            .height = resolved.height,
            .resizable = resolved.resizable,
            .decorated = !resolved.borderless,
            // Shown once it is in its place, so it is never seen elsewhere.
            .visible = false,
            .gl = wants_gl,
            .present_mode = resolved.vsync_mode.present(),
        }) catch |err| {
            self.window = null;
            if (Window.isAbsent(err)) {
                log.info("no window could be opened: {t}", .{err});
                return Error.NoDisplay;
            }
            return err;
        };
        self.clipboard.system = &self.window.?.ctx;
        if (resolved.min_size[0] > 0 or resolved.min_size[1] > 0) {
            self.window.?.setSizeLimits(.{ .min_width = resolved.min_size[0], .min_height = resolved.min_size[1] }) catch |err|
                log.warn("the window's least size could not be set: {t}", .{err});
        }
        // Before anything is sized from the window, so the swapchain is made
        // at its final size. None of it fatal: a game that cannot be put
        // where it asks still runs, and says why.
        placeWindow(&self.window.?, resolved);
    }

    const width = if (self.window) |*w| w.width else resolved.width;
    const height = if (self.window) |*w| w.height else resolved.height;
    self.width = width;
    self.height = height;
    // The surface is about to be made at this size, so the first frame has
    // nothing to resize; and the input starts out agreeing with the window
    // about the keyboard.
    if (self.window) |*w| {
        w.resized = false;
        self.input.focused = w.focused;
    }
    self.fitInterface();

    self.device = try .init(gpa, .{
        .backend = switch (backend) {
            .gl => .gl,
            .d3d11 => .d3d11,
            .d3d12 => .d3d12,
            .vulkan => .vulkan,
            .webgl => .webgl,
            .none => .none,
            .auto => .auto,
        },
        // Only OpenGL wants the context; Direct3D takes the window handle at
        // surface time instead.
        .gl = if (wants_gl and self.window != null) self.window.?.hooks() else null,
    });
    errdefer self.device.deinit();

    if (self.window) |*w| {
        // The window as it is, whichever backend draws into it: its handle,
        // and its hooks for a backend that makes its surface from it.
        self.surface = try self.device.createSurface(.{
            .native_window = w.nativeHandle(),
            .window = w.surfaceHooks(),
            .width = width,
            .height = height,
            // Told to the swapchain as well as the window: Direct3D keeps it
            // on the swapchain, OpenGL on the context.
            .present_mode = resolved.vsync_mode.present(),
        });
    } else {
        // No window, so the frame goes into a texture, through every draw
        // call the real path makes.
        self.offscreen = try self.device.createTexture(.{
            .width = width,
            .height = height,
            .usage = .{ .sampled = true, .render_target = true },
            .clear_color = resolved.background.array(),
            .label = "headless target",
        });
    }
    if (backend.experimental()) log.warn("drawing with {t} ({s}), which is experimental", .{ backend, self.device.info().renderer });
}

/// Put a window opened hidden where and how `resolved` says - its screen or
/// its point, its frame, its stacking, its mode - and show it. Whatever the
/// system will not do is said, and the rest done.
fn placeWindow(w: *Window, resolved: Resolved) void {
    const screens = w.screens();
    switch (resolved.initial_position) {
        .center_of_primary_screen => if (w.primaryScreen()) |primary| w.centerOn(primary) catch |err| log.info("the window could not be centred: {t}", .{err}),
        .center_of_screen => {
            const index: usize = if (resolved.screen < screens.len) resolved.screen else w.primaryScreen() orelse 0;
            if (resolved.screen >= screens.len) log.warn("there is no screen {d}: the window opens on the primary one", .{resolved.screen});
            w.centerOn(index) catch |err| log.info("the window could not be centred: {t}", .{err});
        },
        .absolute => w.setPosition(resolved.position.x, resolved.position.y) catch |err| log.info("the window could not be put at its position: {t}", .{err}),
    }
    if (resolved.always_on_top) w.setTopmost(true) catch |err| log.warn("the window cannot be kept on top here: {t}", .{err});
    // In its mode before it shows, so it never shows as a window first; a
    // system that takes no mode for a window not shown yet is asked again.
    const wanted = resolved.window_mode;
    if (wanted != .windowed) w.setMode(wanted) catch {};
    w.show();
    if (wanted != .windowed and w.mode() != wanted) w.setMode(wanted) catch |err| log.warn("the window could not open {t}: {t}", .{ wanted, err });
    w.setKeepAwake(resolved.keep_screen_on) catch |err| switch (err) {
        // A phone, a page and Wayland keep their screens as they will.
        error.Unavailable => {},
        else => log.warn("the screen could not be kept on: {t}", .{err}),
    };
}

/// What the title bar says: the game's own title, or else its project's
/// name, or else "fluxion".
fn titleOf(options: Options, settings: ?Project.Settings) []const u8 {
    if (options.title) |title| return title;
    if (settings) |held| {
        if (held.application.name.len > 0) return held.application.name;
    }
    return "fluxion";
}

/// What the window, the frame and the clock are made with: the game's
/// `Options` where they say, the project file's `display`, `rendering` and
/// `physics_2d` where they do not, and the engine's own under both - which
/// are the sections' defaults, so a project that says nothing and a folder
/// with no project file open the same.
const Resolved = struct {
    width: u32,
    height: u32,
    stretch: stretch_mod.Stretch,
    min_size: [2]u32,
    vsync_mode: VsyncMode,
    resizable: bool,
    window_mode: WindowMode,
    borderless: bool,
    always_on_top: bool,
    initial_position: InitialPosition,
    screen: u16,
    position: geometry.Vec2i,
    keep_screen_on: bool,
    background: Color,
    fixed_delta: f32,
    max_fixed_steps: u32,
    max_fps: ?f32,
    interface_zoom: f32,

    const default_fixed_delta: f32 = 1.0 / @as(f32, @floatFromInt((Project.Physics2D{}).ticks_per_second));

    fn of(options: Options, settings: ?*const Project.Settings, physics_2d: Project.Physics2D) Resolved {
        const display: Project.Display = if (settings) |held| held.display else .{};
        const rendering: Project.Rendering = if (settings) |held| held.rendering else .{};
        const application: Project.Application = if (settings) |held| held.application else .{};
        const gui: Project.Gui = if (settings) |held| held.gui else .{};
        return .{
            // The window's own size where the project gives one, and the
            // size the game is made at where it does not.
            .width = options.width orelse if (display.window_width > 0) display.window_width else display.width,
            .height = options.height orelse if (display.window_height > 0) display.window_height else display.height,
            // Made at the project's size, whatever size the window opens.
            .stretch = options.stretch orelse .{
                .mode = display.stretch_mode,
                .aspect = display.stretch_aspect,
                .width = display.width,
                .height = display.height,
                .scale = display.stretch_scale,
                .scale_mode = display.stretch_scale_mode,
            },
            .min_size = options.min_size orelse .{ display.min_width, display.min_height },
            .vsync_mode = options.vsync_mode orelse display.vsync_mode,
            .resizable = options.resizable orelse display.resizable,
            .window_mode = options.window_mode orelse display.mode,
            .borderless = options.borderless orelse display.borderless,
            .always_on_top = options.always_on_top orelse display.always_on_top,
            .initial_position = options.initial_position orelse display.initial_position,
            .screen = options.screen orelse display.screen,
            .position = options.position orelse display.position,
            .keep_screen_on = options.keep_screen_on orelse display.keep_screen_on,
            .background = options.background orelse rendering.clear_color,
            .fixed_delta = options.fixed_delta orelse 1.0 / @as(f32, @floatFromInt(@max(physics_2d.ticks_per_second, 1))),
            .max_fixed_steps = @max(physics_2d.max_steps_per_frame, 1),
            .max_fps = options.max_fps orelse if (application.max_fps > 0) @floatFromInt(application.max_fps) else null,
            .interface_zoom = if (gui.scale > 0) gui.scale else 1,
        };
    }
};

pub fn destroy(self: *App) void {
    const gpa = self.gpa;

    // First, while everything a script's handle points at is still there.
    if (self.scripts) |scripts| scripts.calls.destroy(scripts);
    self.input.deinit(gpa);
    self.schedule.deinit(gpa);
    self.states.deinit(gpa);
    self.snapshots.deinit(gpa);
    self.orphans.deinit(gpa);
    self.names.deinit(gpa);
    self.freeNames();
    self.by_name.deinit(gpa);
    self.tree.deinit(gpa);
    self.freeGroups();
    self.groups.deinit(gpa);
    for (self.slide_collisions.values()) |*met| met.deinit(gpa);
    self.slide_collisions.deinit(gpa);
    self.overlaps_found.deinit(gpa);
    self.names_found.deinit(gpa);
    self.drawings.deinit(gpa);
    self.particles.deinit(gpa);
    self.inherited.deinit(gpa);
    self.freeInstances();
    self.instances.deinit(gpa);
    self.scene_roots.deinit(gpa);
    // Each is taken out of the list as it goes.
    while (self.loads.items.len > 0) self.dropLoad(self.loads.items[self.loads.items.len - 1]);
    self.loads.deinit(gpa);
    self.scenes.deinit(gpa);
    self.data_files.deinit(gpa);
    self.audio.deinit();
    self.tweens.deinit(gpa);
    for (self.custom_cursors) |held| if (held) |custom| gpa.free(custom.pixels);
    self.clocks.deinit(gpa);
    if (self.culture_held) |held| held.close();
    if (self.locale_chosen) |chosen| gpa.free(chosen);
    self.texts.deinit(gpa);
    self.shader_params.deinit(gpa);
    self.animation_players.deinit(gpa);
    self.animation_libraries.deinit(gpa);
    self.sprite_frames.deinit(gpa);
    self.uuids.deinit(gpa);
    self.by_uuid.deinit(gpa);
    self.sibling_ranks.deinit(gpa);
    self.scene_components.deinit(gpa);
    self.unknown_components.deinit(gpa);
    self.exports.deinit(gpa);
    self.signals.deinit();
    for (self.event_channels.values()) |channel| channel.deinit(channel.events, gpa);
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
    self.control_nodes.deinit(gpa);
    self.ui.deinit();
    self.sprites.deinit(gpa);
    self.screen.deinit();
    self.shaders.deinit(gpa, &self.device);
    self.views.deinit(gpa, &self.assets);
    self.assets.deinit();
    self.project.deinit();
    self.jobs.deinit();
    self.commands.deinit();
    self.world.deinit();

    while (self.tool_windows.pop()) |tool| self.dropToolWindow(tool);
    self.tool_windows.deinit(gpa);
    self.touch_actions.deinit(gpa);
    if (self.offscreen) |t| self.device.destroyTexture(t);
    if (self.surface) |s| self.device.destroySurface(s);
    self.device.deinit();
    if (self.window) |*w| w.close();

    gpa.destroy(self);
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
// Pause
// -------------------------------------------------------------------------

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

/// How an entity shows, everything above it counted: whether it is drawn,
/// the colour its own is multiplied by, and what its layer is raised by.
/// See `Appearance`.
pub fn resolvedAppearance(self: *App, entity: ecs.Entity) inherited_mod.Resolved {
    return self.inherited.of(self.gpa, &self.world, entity);
}

/// Show an entity and what hangs from it, or hide them: its `Appearance`,
/// given one when it has none. What shows, everything above counted, is
/// `isVisibleInTree`.
pub fn setVisible(self: *App, entity: ecs.Entity, visible: bool) (ecs.World.Error || error{NoSuchEntity})!void {
    if (self.world.get(entity, inherited_mod.Appearance)) |held| {
        held.visible = visible;
    } else try self.world.add(entity, inherited_mod.Appearance{ .visible = visible });
    self.inherited.forget();
}

/// Whether an entity shows: neither it nor anything above it hidden by its
/// `Appearance`.
pub fn isVisibleInTree(self: *App, entity: ecs.Entity) bool {
    return self.world.isAlive(entity) and self.resolvedAppearance(entity).visible;
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

fn addHook(self: *App, on: schedule_mod.Hook.On, value: anytype, comptime name: []const u8, system: System) Allocator.Error!void {
    _ = try self.states.slotFor(self.gpa, @TypeOf(value));
    try self.schedule.addHook(self.gpa, .{
        .on = on,
        .state = .of(value),
        .entry = .{ .name = name, .run = system, .gate = self.gate },
    });
}

/// Do the changes `setState` asked for. At the top of each frame.
fn changeStates(self: *App) anyerror!void {
    // By index: a hook may name a new state, and the list may move.
    var at: usize = 0;
    while (at < self.states.slots.items.len) : (at += 1) {
        const slot = self.states.slots.items[at];
        const next = slot.pending orelse continue;
        self.states.slots.items[at].pending = null;
        if (next == slot.current) continue;
        try self.schedule.runHooks(.exit, .{ .key = slot.key, .value = slot.current }, self);
        self.states.slots.items[at].current = next;
        try self.schedule.runHooks(.enter, .{ .key = slot.key, .value = next }, self);
    }
}

/// Enter every state at its first value, or the one `.startup` asked for.
fn enterFirstStates(self: *App) anyerror!void {
    var at: usize = 0;
    while (at < self.states.slots.items.len) : (at += 1) {
        const slot = &self.states.slots.items[at];
        if (slot.pending) |chosen| slot.current = chosen;
        slot.pending = null;
        const entered: States.Value = .{ .key = slot.key, .value = slot.current };
        try self.schedule.runHooks(.enter, entered, self);
    }
}

// -------------------------------------------------------------------------
// The loop
// -------------------------------------------------------------------------

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
    try self.enterFirstStates();
}

/// One frame. Says whether there should be another. Public for a game that
/// drives its own loop.
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
    for (self.event_channels.values()) |channel| channel.update(channel.events);
    self.resized = false;

    if (self.window) |*window| {
        if (!window.pump(&self.input, .{ .context = self, .event = routeToTool })) {
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
            try self.adoptSize(window.width, window.height);
        }
    }
    for (self.tool_windows.items) |tool| {
        if (!tool.resized) continue;
        tool.resized = false;
        if (tool.surface) |surface| try self.device.resizeSurface(surface, tool.width, tool.height);
    }
    // The touch buttons the fingers press, and the actions they hold; then
    // every action from this frame's keys, buttons, sticks and those, for
    // the interface and the first system alike.
    try touch_mod.update(self);
    self.input.updateActions();
    for (self.tool_windows.items) |tool| tool.input.updateActions();
    self.fitFrame();
    self.fitInterface();

    // In the background - an Android app switched away from, a page hidden -
    // a frame runs nothing and draws nothing, save the one the news came in,
    // for its systems to save what they must. Coming back starts the clock
    // again, so the time away is not a frame.
    if (self.input.suspended and !self.input.justSuspended()) {
        try self.waitForNextFrame(true);
        return self.running;
    }
    if (self.input.justResumed()) self.time.restart();

    self.time.tick();
    // What the fingers made - taps, swipes, two fingers' pinch - for the
    // scripts to hear with the rest of the frame's input.
    self.input.trackFingers(self.time.unscaled_delta);
    self.inherited.forget();
    // A game that wrote `paused` itself is taken at its word from here on.
    self.schedule.paused = self.paused;
    self.debug_frame.advance(self.time.delta);
    self.debug_under_frame.advance(self.time.delta);
    if (self.hasInterface()) try self.feedInterface();

    // What was asked for outside any system - between frames, by a tool -
    // is done before the first system of this one, and then the states
    // change that the last frame asked to.
    try self.commands.apply();
    try self.changeStates();

    // Bodies are synced before each fixed step. A frame with no time - and
    // the first, which has no time to step - is synced here instead, so the
    // queries find what was spawned, and so is a paused game's, whose steps
    // move no body.
    self.bodies.beginFrame();
    if (self.time.delta == 0 or self.paused) try self.bodies.sync(self);

    // The scripts hear the frame's input first: each `input`, and what
    // none took to each `unhandled_input`.
    if (self.scripts) |scripts| try scripts.calls.pass(scripts, .input);
    try self.schedule.run(.input, self);
    self.shortcuts();
    // The pointer's speed, from everything this frame has said of it,
    // including what an `.input` system put in.
    self.input.trackPointer(self.time.unscaled_delta);
    // After the game's own input systems, which may take the pointer with
    // `input.setAsHandled`, and before the first step.
    try self.picking.update(self);

    // A backlog too big to work through is dropped. See
    // `Time.max_fixed_steps`.
    self.time.dropBacklog();
    {
        // Inside `.fixed`, the edges are counted since the last step and
        // `time.delta` is the step. Both are put back with `defer`, so a step
        // that fails leaves nothing wrong for the stages after it.
        self.input.clock = .fixed;
        defer self.input.clock = .frame;
        const frame_delta = self.time.delta;
        self.time.delta = self.time.fixed_delta;
        defer self.time.delta = frame_delta;
        self.debug.canvas = &self.debug_steps;
        defer self.debug.canvas = &self.debug_frame;
        self.debug_under.canvas = &self.debug_under_steps;
        defer self.debug_under.canvas = &self.debug_under_frame;

        while (self.time.takeFixedStep()) |_| {
            self.inherited.forget();
            self.debug_steps.advance(self.time.fixed_delta);
            self.debug_under_steps.advance(self.time.fixed_delta);
            // Where everything was before this step, to draw between steps.
            try self.snapshotPrevious();
            try timer.count(self, .fixed, self.time.fixed_delta);
            try self.signals.drain(self);
            if (self.scripts) |scripts| {
                try scripts.calls.pass(scripts, .{ .fixed = self.time.fixed_delta });
                try self.signals.drain(self);
            }
            try self.schedule.run(.fixed, self);
            // Nothing moves a paused game's bodies: there is one physics.
            if (!self.paused) try self.stepPhysics();
            // Seen, so gone: the next step hears only what comes after.
            self.input.endFixedStep();
        }
    }
    // A paused frame gives the fixed stage no time, and so no edges: a key
    // pressed on a pause menu must not reach the first step after it.
    if (self.time.delta == 0) self.input.endFixedStep();

    self.inherited.forget();
    self.clocks.step(self.time.delta, self, clockRuns);
    try timer.count(self, .update, self.time.delta);
    try tween_mod.update(self, self.time.delta);
    try animation_mod.update(self, self.time.delta);
    try sprite_frames_mod.update(self, self.time.delta);
    try self.signals.drain(self);
    if (self.scripts) |scripts| {
        try scripts.calls.pass(scripts, .{ .update = self.time.delta });
        try self.signals.drain(self);
    }
    try self.schedule.run(.update, self);
    try self.schedule.run(.late, self);
    // Deferred signal calls: after `.late`, before the engine's own
    // passes, so what they despawn is gone by the draw.
    try self.signals.flushDeferred(self);

    // The scene `changeScene` asked for, before the engine's passes: what
    // hung from the old one goes with it this frame.
    if (self.scene_next) |next| {
        self.scene_next = null;
        self.openScene(next) catch |err| log.err("the scene {s} did not open: {t}", .{ self.sceneSource(next) orelse "?", err });
    }
    // A load with no thread of its own is worked a piece a frame.
    if (!background_mod.threaded) for (self.loads.items) |load| {
        _ = load.work();
    };

    // The engine's own passes, after the game's `.late` systems and before
    // drawing: whatever hung from something despawned goes with it, and then
    // the names of everything that died are given back.
    try self.despawnOrphans();
    // Every player's sound as its component says, and every emitter's
    // particles moved on, after everything that could say otherwise: and
    // each `finished` heard before the frame is drawn.
    try self.audio.update(self);
    try particles_mod.update(self, self.time.delta, .game);
    try self.signals.drain(self);
    // The scripts of the dead, and of what lost its `Script`, hear `exit`
    // in the frame it happened.
    if (self.scripts) |scripts| {
        try scripts.calls.pass(scripts, .end_of_frame);
        try self.signals.drain(self);
    }
    self.forgetDeadNames();
    self.forgetDeadUuids();
    self.forgetDeadPlaces();
    self.forgetDeadGroupMembers();
    self.forgetDeadSlides();
    self.forgetDeadInstances();
    self.unknown_components.forgetDead(self.gpa, &self.world);
    self.exports.forgetDead(&self.world);
    self.tweens.forgetDead(self);
    self.drawings.forgetDead(self.gpa, &self.world);
    self.particles.forgetDead(self.gpa, &self.world);
    self.texts.forgetDead(self.gpa, &self.world);
    self.shader_params.forgetDead(self.gpa, &self.world);
    self.views.forgetDead(self.gpa, &self.world, &self.assets, components.RenderView);
    self.animation_players.forgetDead(self.gpa, &self.world);
    self.signals.forgetDead(&self.world);
    // Every animated sprite's frame in its Sprite, and every smoothed
    // camera a step nearer, after all that could change them.
    try sprite_frames_mod.show(self);
    try self.followCameras();
    if (self.debug_visible and self.debug_views.any()) try self.debug_views.draw(self);

    // What the systems changed of how things show is seen by the drawing.
    self.inherited.forget();
    if (self.hasInterface()) try self.layOutInterface();
    for (self.tool_windows.items) |tool| try self.layOutTool(tool);

    // Nothing to draw on while Android has taken the surface away.
    const minimized = self.windowMode() == .minimized;
    if (!minimized and !self.input.surface_lost) try self.render();
    for (self.tool_windows.items) |tool| try self.renderTool(tool);

    if (self.frames_left) |left| {
        if (left <= 1) {
            self.running = false;
        } else {
            self.frames_left = left - 1;
        }
    }

    if (self.running) try self.waitForNextFrame(minimized);
    return self.running;
}

/// After the game's `.fixed` systems, so what they wrote into the components
/// is in this step.
fn stepPhysics(self: *App) !void {
    try self.bodies.sync(self);
    try self.physics.step(self.time.fixed_delta, &self.jobs);
    try self.bodies.afterStep(self);
    // What the step found each area holding, said and heard before the
    // systems of the next step run.
    try self.areas.update(self);
    try self.updateRayCasts();
    try self.signals.drain(self);
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

/// The engine's own keys, after the game's `.input` systems.
fn shortcuts(self: *App) void {
    if (self.quit_key) |key| {
        if (self.input.justPressed(key)) self.quit();
    }
    if (self.fullscreen_key) |key| {
        if (self.input.justPressed(key)) self.toggleFullscreen() catch |err| {
            log.warn("could not change fullscreen: {t}", .{err});
        };
    }
    if (self.debug_key) |key| {
        if (self.input.justPressed(key)) self.debug_visible = !self.debug_visible;
    }
}

/// Whether the interface is laid out at all: a game with a `.ui` system.
pub fn hasInterface(self: *const App) bool {
    return self.schedule.systemsIn(.ui).len != 0;
}

/// Before the `.input` stage, so a game system can ask `app.ui.wantsPointer()`
/// about this frame.
fn feedInterface(self: *App) !void {
    if (self.interfaceFaces().len != 0) self.ui.setMeasurer(Interface.measurer(&self.interface.faces));
    // Asked of the system when the wheel turned, so a changed setting is
    // taken at once - and only then, since on Linux asking reads a file.
    if (self.input.wheel.x != 0 or self.input.wheel.y != 0) {
        if (self.window) |*window| self.interface.scroll_lines = window.scrollLines();
    }
    try self.interface.feed(self.gpa, &self.ui, &self.input, &self.clipboard, self.time.unscaled_delta);
}

// -------------------------------------------------------------------------
// Tool windows
// -------------------------------------------------------------------------

/// Another window, beside the main one, with an interface of its own that
/// `ToolWindow.draw` lays out each frame: see `ToolWindow`. It draws with the
/// main window's device and in the interface's fonts. Headless, it is drawn
/// into a texture of its size.
pub fn openToolWindow(self: *App, desc: ToolWindow.Desc) !*ToolWindow {
    try self.tool_windows.ensureUnusedCapacity(self.gpa, 1);
    const tool = try self.gpa.create(ToolWindow);
    errdefer self.gpa.destroy(tool);
    tool.* = .{ .handle = null, .ui = .init(self.gpa), .width = desc.width, .height = desc.height };
    errdefer tool.deinit(self.gpa);
    try tool.input.actions.reset(self.gpa, &.{});

    if (self.window) |*window| {
        const handle = try window.openBeside(.{
            .title = desc.title,
            .width = desc.width,
            .height = desc.height,
            .resizable = desc.resizable,
        });
        errdefer handle.destroy();
        tool.handle = handle;
        const size = handle.framebufferSize();
        tool.width = @max(size[0], 1);
        tool.height = @max(size[1], 1);
        tool.content_scale = handle.contentScale()[0];
        tool.focused = handle.isFocused();
        // Two windows waiting for the display each frame would wait twice.
        tool.surface = try self.device.createSurface(.{
            .native_window = handle.native(),
            .window = tool.surfaceHooks(window.has_gl_context),
            .width = tool.width,
            .height = tool.height,
            .present_mode = .disabled,
        });
    } else {
        tool.offscreen = try self.device.createTexture(.{
            .width = tool.width,
            .height = tool.height,
            .usage = .{ .sampled = true, .render_target = true },
            .clear_color = tool.background,
            .label = "tool window",
        });
    }
    tool.fit(&self.interface);
    self.tool_windows.appendAssumeCapacity(tool);
    return tool;
}

/// Close a tool window, and let go of all it had.
pub fn closeToolWindow(self: *App, tool: *ToolWindow) void {
    for (self.tool_windows.items, 0..) |held, i| if (held == tool) {
        _ = self.tool_windows.orderedRemove(i);
        break;
    };
    self.dropToolWindow(tool);
}

fn dropToolWindow(self: *App, tool: *ToolWindow) void {
    if (tool.surface) |surface| self.device.destroySurface(surface);
    if (tool.offscreen) |texture| self.device.destroyTexture(texture);
    tool.deinit(self.gpa);
    if (tool.handle) |handle| handle.destroy();
    self.gpa.destroy(tool);
}

/// An event about a window other than the main one: a tool window's.
fn routeToTool(context: *anyopaque, ev: platform.Event) void {
    const self: *App = @ptrCast(@alignCast(context));
    const about = ev.window();
    for (self.tool_windows.items) |tool| {
        const handle = tool.handle orelse continue;
        if (handle.id == about) return tool.take(ev);
    }
}

/// Its input into its interface, then its interface laid out by its `draw`,
/// in the main interface's fonts; its pointer's shape and text input told.
fn layOutTool(self: *App, tool: *ToolWindow) !void {
    tool.fit(&self.interface);
    if (self.interfaceFaces().len != 0) tool.ui.setMeasurer(Interface.measurer(&self.interface.faces));
    try tool.interface.feed(self.gpa, &tool.ui, &tool.input, &self.clipboard, self.time.unscaled_delta);

    tool.interface.commands = &.{};
    tool.ui.begin(tool.interface.surface(@floatFromInt(tool.width), @floatFromInt(tool.height)));
    {
        tool.ui.open(.{ .width = .grow, .height = .grow });
        defer tool.ui.close();
        if (tool.draw) |draw| try draw.run(draw.context, tool);
    }
    tool.interface.commands = try tool.ui.end();
    const handle = tool.handle orelse return;
    tool.showCursor(switch (tool.ui.cursor()) {
        inline else => |named| @field(CursorShape, @tagName(named)),
    });
    tool.interface.applyTextInput(&tool.ui, handle);
}

/// Its background, its interface over it, and shown.
fn renderTool(self: *App, tool: *ToolWindow) !void {
    if (tool.width == 0 or tool.height == 0) return;
    if (tool.handle) |handle| if (handle.isIconified()) return;
    const into = tool.target();
    const cmd = self.device.begin();
    try cmd.beginPass(.{ .color = .{ .target = into, .clear_color = tool.background } });
    try cmd.endPass();
    try self.device.submit();
    try tool.interface.draw(self.gpa, &self.device, self.interfaceFaces(), into, @floatFromInt(tool.width), @floatFromInt(tool.height));
    if (tool.surface) |surface| try self.device.present(surface);
}

fn layOutInterface(self: *App) !void {
    self.interface.commands = &.{};
    self.ui.begin(self.interface.surface(@floatFromInt(self.frame.width), @floatFromInt(self.frame.height)));
    {
        // One root for every `.ui` system: fluxion-ui makes the first element
        // the root, so a second system's would land beside it. `.grow`,
        // because fluxion-ui gives a `.fit` root its content's height.
        self.ui.open(.{ .width = .grow, .height = .grow });
        defer self.ui.close();
        try self.schedule.run(.ui, self);
    }
    self.interface.commands = try self.ui.end();
    self.cursor_wanted = self.wantedCursor();
    if (self.window) |*window| {
        self.applyCursor(window);
        self.interface.applyTextInput(&self.ui, window.handle);
    }
}

/// This frame's size and place on the window, as the stretch says, and the
/// pointer's pixels turned into its. See `stretch.zig`.
fn fitFrame(self: *App) void {
    self.frame = self.stretch.frameOf(self.width, self.height);
    self.input.frame_origin = .init(self.frame.shown.x, self.frame.shown.y);
    self.input.frame_ratio = self.frame.ratio();
    // A density-independent pixel, in the frame's: the window's pixels in
    // one, and the frame's in each of those.
    const display: f32 = if (self.window) |*window| window.content_scale else 1;
    self.input.dp = display * self.input.frame_ratio;
}

/// The interface's scale for this frame: the game's `zoom` times the
/// display's, which it follows unless told not to - and 1 with no window.
/// A stretched game's is its frame's scale instead, which already counts
/// the window's pixels.
fn fitInterface(self: *App) void {
    const display: f32 = if (self.window) |*window|
        (if (self.interface.follow_display) window.content_scale else 1)
    else
        1;
    self.interface.display_scale = display;
    const outer: f32 = if (self.stretch.mode == .disabled) display else self.frame.scale;
    self.interface.scale = self.interface.zoom * outer;
    if (self.interface.follow_safe_area) {
        const edges = self.safeArea();
        self.interface.safe_area = .{
            .left = cut(edges.left),
            .top = cut(edges.top),
            .right = cut(edges.right),
            .bottom = cut(edges.bottom),
        };
    }
}

/// A screen edge as the interface holds it: sixteen bits, which is wider
/// than any screen there is.
fn cut(edge: u32) u16 {
    return @intCast(@min(edge, std.math.maxInt(u16)));
}

/// The interface's faces, filled into `interface.faces` from its fonts: its
/// `font` first, then each `addFont` gave it. A font that has been let go of
/// takes the first face's place, so the indices after it stay where they
/// are. None at all when `font` has no face, which lays the interface out
/// and draws no text.
fn interfaceFaces(self: *App) []const *const typeface.Font {
    const faces = &self.interface.faces;
    faces.len = 0;
    const first = &(self.assets.fontOf(self.interface.font) orelse return faces.slice()).face;
    faces.items[0] = first;
    const others = self.interface.other_fonts[0..self.interface.other_font_count];
    for (others, faces.items[1..][0..others.len]) |handle, *face| {
        face.* = if (self.assets.fontOf(handle)) |font| &font.face else first;
    }
    faces.len = @intCast(1 + others.len);
    return faces.slice();
}

/// Take a new size from the window: the numbers, the flag, and the swapchain.
fn adoptSize(self: *App, width: u32, height: u32) !void {
    self.width = width;
    self.height = height;
    self.fitFrame();
    self.resized = true;
    if (self.surface) |surface| try self.device.resizeSurface(surface, width, height);
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

/// Despawn everything whose parent has died, and what hangs from that in
/// turn; see `Parent`. Once a frame, because a game despawns through
/// `world.despawn` and nothing here sees it. It goes round until a pass
/// finds nothing, so a turret's barrel goes one pass after the turret.
fn despawnOrphans(self: *App) !void {
    while (true) {
        self.orphans.clearRetainingCapacity();

        var it = try ecs.Query(.{components.Parent}).over(&self.world);
        while (it.next()) |chunk| {
            for (chunk.slice(components.Parent), chunk.entities) |held, entity| {
                if (held.entity.isNone() or self.world.isAlive(held.entity)) continue;
                try self.orphans.append(self.gpa, entity);
            }
        }

        // A chunk is its map's rather than its child, and goes the same way:
        // a map despawned takes its tiles with it.
        var chunks = try ecs.Query(.{tilemap.TileChunk}).over(&self.world);
        while (chunks.next()) |chunk| {
            for (chunk.slice(tilemap.TileChunk), chunk.entities) |tiles, entity| {
                if (self.world.has(tiles.map, tilemap.TileMap)) continue;
                try self.orphans.append(self.gpa, entity);
                _ = self.tile_chunks.remove(.{ .map = tiles.map, .x = tiles.x, .y = tiles.y });
            }
        }

        // Found first and despawned after: a despawn moves rows, and the
        // slices above point at rows.
        if (self.orphans.items.len == 0) return;
        for (self.orphans.items) |orphan| self.world.despawn(orphan);
    }
}

// -------------------------------------------------------------------------
// Where things are, through the parent chain
// -------------------------------------------------------------------------

/// Resolving against no snapshots is resolving where things are, not where
/// they are drawn.
const still: hierarchy.Snapshots = .empty;

/// Where an entity really is, with every parent above it applied. Null
/// when it has no transform, or when something it hangs from was despawned
/// this frame. The result has no parent, so writing
/// it over the entity's own transform lets go while keeping it in place.
///
/// Where it is, not where it is drawn: an entity that `interpolate`s is drawn
/// between its last two fixed steps, which `drawnTransform` says.
pub fn worldTransform(self: *App, entity: ecs.Entity) ?components.Transform2D {
    return hierarchy.resolveEntity(&self.world, &still, entity, 1);
}

/// Where an entity is drawn this frame: `worldTransform`, with every link
/// that `interpolate`s blended between its last two fixed steps as the
/// renderer blends it. For drawing beside a sprite, not for the game's sums.
pub fn drawnTransform(self: *App, entity: ecs.Entity) ?components.Transform2D {
    return hierarchy.resolveEntity(&self.world, &self.snapshots, entity, self.time.alpha());
}

/// What a call that writes where an entity is can fail with.
pub const PlaceError = error{
    /// It has no `Transform2D` to write.
    NoTransform,
    /// Something above it cannot be placed: a parent despawned this frame,
    /// or a chain deeper than `Transform2D.max_depth`.
    Unplaced,
};

/// Put an entity where `placed` says in the world, and keep its parent: its
/// own transform becomes the one that, under its parents, lands there. Its
/// parent, its inherit switches and its `interpolate` stay its own;
/// `placed`'s are not read.
pub fn setWorldTransform(self: *App, entity: ecs.Entity, placed: components.Transform2D) PlaceError!void {
    const above = try self.parentPlace(entity);
    const own = self.world.get(entity, components.Transform2D) orelse return error.NoTransform;
    const at = above.unapply(placed.x, placed.y);
    own.x = at.x;
    own.y = at.y;
    own.rotation = if (own.inherit_rotation) placed.rotation - above.rotation else placed.rotation;
    own.scale_x = if (own.inherit_scale) placed.scale_x / nonZero(above.scale_x) else placed.scale_x;
    own.scale_y = if (own.inherit_scale) placed.scale_y / nonZero(above.scale_y) else placed.scale_y;
}

/// Where an entity's parent is in the world: nothing at all for none, or
/// for a living parent with no transform of its own, which places nothing.
fn parentPlace(self: *App, entity: ecs.Entity) PlaceError!components.Transform2D {
    const above = self.parentOf(entity);
    if (above.isNone()) return .{};
    if (self.world.get(above, components.Transform2D) == null and self.world.isAlive(above)) return .{};
    return self.worldTransform(above) orelse error.Unplaced;
}

/// A scale of zero is left out rather than divided by, as `unapply` does.
fn nonZero(scale: f32) f32 {
    return if (scale != 0) scale else 1;
}

/// The world transform of an entity to write, or why there is none.
fn placeOf(self: *App, entity: ecs.Entity) PlaceError!components.Transform2D {
    if (!self.world.has(entity, components.Transform2D)) return error.NoTransform;
    return self.worldTransform(entity) orelse error.Unplaced;
}

/// Where an entity is in the world.
pub fn globalPosition(self: *App, entity: ecs.Entity) ?math.Vec2 {
    const placed = self.worldTransform(entity) orelse return null;
    return .init(placed.x, placed.y);
}

pub fn setGlobalPosition(self: *App, entity: ecs.Entity, position: math.Vec2) PlaceError!void {
    var placed = try self.placeOf(entity);
    placed.x = position.x;
    placed.y = position.y;
    try self.setWorldTransform(entity, placed);
}

/// Which way an entity faces in the world, in radians.
pub fn globalRotation(self: *App, entity: ecs.Entity) ?f32 {
    const placed = self.worldTransform(entity) orelse return null;
    return placed.rotation;
}

pub fn setGlobalRotation(self: *App, entity: ecs.Entity, radians: f32) PlaceError!void {
    var placed = try self.placeOf(entity);
    placed.rotation = radians;
    try self.setWorldTransform(entity, placed);
}

/// How big an entity is in the world.
pub fn globalScale(self: *App, entity: ecs.Entity) ?math.Vec2 {
    const placed = self.worldTransform(entity) orelse return null;
    return .init(placed.scale_x, placed.scale_y);
}

pub fn setGlobalScale(self: *App, entity: ecs.Entity, scale: math.Vec2) PlaceError!void {
    var placed = try self.placeOf(entity);
    placed.scale_x = scale.x;
    placed.scale_y = scale.y;
    try self.setWorldTransform(entity, placed);
}

/// Move an entity by `offset` in the world, whatever its parents have done
/// to its axes.
pub fn globalTranslate(self: *App, entity: ecs.Entity, offset: math.Vec2) PlaceError!void {
    const placed = try self.placeOf(entity);
    try self.setGlobalPosition(entity, .init(placed.x + offset.x, placed.y + offset.y));
}

/// A point in the world, in an entity's own space.
pub fn toLocal(self: *App, entity: ecs.Entity, global_point: math.Vec2) ?math.Vec2 {
    const placed = self.worldTransform(entity) orelse return null;
    const local = placed.unapply(global_point.x, global_point.y);
    return .init(local.x, local.y);
}

/// A point in an entity's own space, in the world.
pub fn toGlobal(self: *App, entity: ecs.Entity, local_point: math.Vec2) ?math.Vec2 {
    const placed = self.worldTransform(entity) orelse return null;
    const global = placed.apply(local_point.x, local_point.y);
    return .init(global.x, global.y);
}

/// How far an entity would turn to face a point with its `+x`, in radians,
/// measured in its own space and scale.
pub fn getAngleTo(self: *App, entity: ecs.Entity, point: math.Vec2) ?f32 {
    const local = self.toLocal(entity, point) orelse return null;
    const own = self.world.get(entity, components.Transform2D).?;
    return std.math.atan2(local.y * own.scale_y, local.x * own.scale_x);
}

/// Turn an entity so that its `+x` faces a point in the world.
pub fn lookAt(self: *App, entity: ecs.Entity, point: math.Vec2) PlaceError!void {
    const angle = self.getAngleTo(entity, point) orelse return if (self.world.has(entity, components.Transform2D)) error.Unplaced else error.NoTransform;
    self.world.get(entity, components.Transform2D).?.rotation += angle;
}

/// Where an entity is in the space of `ancestor`, something it hangs from.
/// Nothing moved for the entity itself, and null for an entity `ancestor`
/// is not above.
pub fn getRelativeTransformToParent(self: *App, entity: ecs.Entity, ancestor: ecs.Entity) ?components.Transform2D {
    var chain: [components.Transform2D.max_depth]components.Transform2D = undefined;
    var depth: usize = 0;
    var at = entity;
    while (!at.eql(ancestor)) {
        if (depth == chain.len) return null;
        const own = self.world.get(at, components.Transform2D) orelse return null;
        const above = self.parentOf(at);
        if (above.isNone()) return null;
        chain[depth] = own.*;
        depth += 1;
        at = above;
    }
    var placed: components.Transform2D = .{};
    while (depth > 0) {
        depth -= 1;
        placed = components.Transform2D.compose(placed, chain[depth]);
    }
    return placed;
}

/// Move an entity along its own `+x`, in its parent's space. By `delta`
/// units, or with `scaled` by `delta` of its own scaled lengths.
pub fn moveLocalX(self: *App, entity: ecs.Entity, delta: f32, scaled: bool) PlaceError!void {
    const own = self.world.get(entity, components.Transform2D) orelse return error.NoTransform;
    moveAlong(own, .init(@cos(own.rotation) * own.scale_x, @sin(own.rotation) * own.scale_x), delta, scaled);
}

/// The same along its own `+y`.
pub fn moveLocalY(self: *App, entity: ecs.Entity, delta: f32, scaled: bool) PlaceError!void {
    const own = self.world.get(entity, components.Transform2D) orelse return error.NoTransform;
    moveAlong(own, .init(-@sin(own.rotation) * own.scale_y, @cos(own.rotation) * own.scale_y), delta, scaled);
}

fn moveAlong(own: *components.Transform2D, axis: math.Vec2, delta: f32, scaled: bool) void {
    const along = if (scaled) axis else axis.norm();
    own.x += along.x * delta;
    own.y += along.y * delta;
}

/// Turn an entity by `radians` more.
pub fn rotate(self: *App, entity: ecs.Entity, radians: f32) PlaceError!void {
    const own = self.world.get(entity, components.Transform2D) orelse return error.NoTransform;
    own.rotation += radians;
}

/// Multiply an entity's scale by `ratio`.
pub fn applyScale(self: *App, entity: ecs.Entity, ratio: math.Vec2) PlaceError!void {
    const own = self.world.get(entity, components.Transform2D) orelse return error.NoTransform;
    own.scale_x *= ratio.x;
    own.scale_y *= ratio.y;
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

// -------------------------------------------------------------------------
// Names
// -------------------------------------------------------------------------

/// What `setName` can refuse.
pub const NameError = error{
    /// A sibling is called that: another living entity with the same
    /// parent, or another root. A path of names picks out one thing.
    NameTaken,
    /// The entity has been despawned, or never was.
    NoSuchEntity,
} || Allocator.Error;

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
    if (!self.world.isAlive(entity)) return error.NoSuchEntity;
    if (self.nameOf(entity)) |own| if (std.mem.eql(u8, own, name)) return;
    if (self.siblingNamed(self.parentOf(entity), name, entity) != null) return error.NameTaken;
    try self.giveName(entity, name);
}

/// `setName`, where a sibling that has the name already gives this one the
/// first free one after it - "Rock 2" - rather than refusing: what a scene
/// read into a family does, and `setParent`.
pub fn setFreeName(self: *App, entity: ecs.Entity, wanted: []const u8) NameError!void {
    if (!self.world.isAlive(entity)) return error.NoSuchEntity;
    var buffer: [256]u8 = undefined;
    const name = self.freeName(self.parentOf(entity), wanted, entity, &buffer);
    if (self.nameOf(entity)) |own| if (std.mem.eql(u8, own, name)) return;
    try self.giveName(entity, name);
}

/// `wanted`, or it with the first number after it that no child of
/// `parent` but `except` is called: "Sprite", "Sprite 2", "Sprite 3". Written
/// into `buffer` when a number is added; a name too long for it is cut.
pub fn freeName(self: *const App, parent: ecs.Entity, wanted: []const u8, except: ecs.Entity, buffer: []u8) []const u8 {
    if (self.siblingNamed(parent, wanted, except) == null) return wanted;
    const base = wanted[0..@min(wanted.len, buffer.len -| 8)];
    var number: usize = 2;
    while (number < 100_000) : (number += 1) {
        const tried = std.fmt.bufPrint(buffer, "{s} {d}", .{ base, number }) catch break;
        if (self.siblingNamed(parent, tried, except) == null) return tried;
    }
    return wanted;
}

/// A living child of `parent` but `except` called `name`, if there is one.
fn siblingNamed(self: *const App, parent: ecs.Entity, name: []const u8, except: ecs.Entity) ?ecs.Entity {
    const holders = self.by_name.getPtr(name) orelse return null;
    for (holders.items) |holder| {
        if (holder.eql(except) or !self.world.isAlive(holder)) continue;
        if (self.parentOf(holder).eql(parent)) return holder;
    }
    return null;
}

/// Give an entity a name, whoever else has it: the checks are the caller's.
fn giveName(self: *App, entity: ecs.Entity, name: []const u8) Allocator.Error!void {
    // Everything that can fail comes before anything changes, so a failed
    // rename keeps the old name.
    try self.names.ensureUnusedCapacity(self.gpa, 1);
    try self.by_name.ensureUnusedCapacity(self.gpa, 1);
    const known = self.by_name.getPtr(name);
    const copy = if (known == null) try self.gpa.dupe(u8, name) else null;
    errdefer if (copy) |text| self.gpa.free(text);
    var fresh: std.ArrayListUnmanaged(ecs.Entity) = .empty;
    errdefer fresh.deinit(self.gpa);
    if (known) |holders| try holders.ensureUnusedCapacity(self.gpa, 1) else try fresh.ensureTotalCapacity(self.gpa, 1);

    // Nothing below here can fail.
    self.forgetName(entity);
    const slot = self.by_name.getOrPutAssumeCapacity(copy orelse name);
    if (!slot.found_existing) slot.value_ptr.* = fresh;
    slot.value_ptr.appendAssumeCapacity(entity);
    self.names.putAssumeCapacity(entity, slot.key_ptr.*);
}

/// What an entity is called, or null when it has no name or is not alive.
/// The text lasts until the entity is renamed or despawned.
pub fn nameOf(self: *const App, entity: ecs.Entity) ?[]const u8 {
    if (!self.world.isAlive(entity)) return null;
    return self.names.get(entity);
}

/// A living entity called `name` - the first given it of those that are -
/// or null. Cheap enough to ask every frame. Where two in different places
/// share a name, `findPath` and `findIn` say which. See `setName`.
///
/// ```zig
/// const player = app.find("player") orelse return;
/// ```
pub fn find(self: *const App, name: []const u8) ?ecs.Entity {
    const holders = self.by_name.getPtr(name) orelse return null;
    for (holders.items) |holder| {
        if (self.world.isAlive(holder)) return holder;
    }
    return null;
}

/// Take one entity's name off it, if it has one, and free the text once
/// nothing has it.
fn forgetName(self: *App, entity: ecs.Entity) void {
    const named = self.names.fetchSwapRemove(entity) orelse return;
    const slot = self.by_name.getEntry(named.value) orelse return;
    const holders = slot.value_ptr;
    for (holders.items, 0..) |holder, at| {
        if (!holder.eql(entity)) continue;
        _ = holders.orderedRemove(at);
        break;
    }
    if (holders.items.len > 0) return;
    const key = slot.key_ptr.*;
    holders.deinit(self.gpa);
    self.by_name.removeByPtr(slot.key_ptr);
    self.gpa.free(key);
}

/// Give back every name's text and list, and empty `by_name`.
fn freeNames(self: *App) void {
    var it = self.by_name.iterator();
    while (it.next()) |entry| {
        self.gpa.free(entry.key_ptr.*);
        entry.value_ptr.deinit(self.gpa);
    }
    self.by_name.clearRetainingCapacity();
}

// -------------------------------------------------------------------------
// UUIDs
// -------------------------------------------------------------------------

/// What `setUuid` can refuse.
pub const UuidError = error{
    /// Another living entity has it. A UUID picks out one thing.
    UuidTaken,
    /// All zeroes: what a UUID nobody set looks like, and so not one.
    NilUuid,
    /// The entity has been despawned, or never was.
    NoSuchEntity,
} || Allocator.Error;

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

/// A new random UUID - version 4 - for an entity, or for anything else a
/// game wants named once and for good.
pub fn newUuid(self: *App) Uuid {
    return .random(self.uuid_source.random());
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
    if (!self.world.isAlive(entity)) return error.NoSuchEntity;
    if (uuid.isNil()) return error.NilUuid;

    var stale: ?ecs.Entity = null;
    if (self.by_uuid.get(uuid)) |holder| {
        if (holder.eql(entity)) return;
        if (self.world.isAlive(holder)) return error.UuidTaken;
        stale = holder;
    }
    // Everything that can fail first, so a refused change changes nothing.
    try self.uuids.ensureUnusedCapacity(self.gpa, 1);
    try self.by_uuid.ensureUnusedCapacity(self.gpa, 1);

    if (stale) |holder| self.forgetUuid(holder);
    const slot = self.uuids.getOrPutAssumeCapacity(entity);
    if (slot.found_existing) _ = self.by_uuid.remove(slot.value_ptr.*);
    slot.value_ptr.* = uuid;
    self.by_uuid.putAssumeCapacityNoClobber(uuid, entity);
}

/// An entity's UUID, or null when it has none or is not alive.
pub fn uuidOf(self: *const App, entity: ecs.Entity) ?Uuid {
    if (!self.world.isAlive(entity)) return null;
    return self.uuids.get(entity);
}

/// An entity's UUID, made for it now if it has none.
pub fn ensureUuid(self: *App, entity: ecs.Entity) (error{NoSuchEntity} || Allocator.Error)!Uuid {
    if (self.uuidOf(entity)) |held| return held;
    while (true) {
        const fresh = self.newUuid();
        self.setUuid(entity, fresh) catch |err| switch (err) {
            // A hundred and twenty-two random bits, drawn twice alike.
            error.UuidTaken => continue,
            error.NilUuid => unreachable,
            error.NoSuchEntity, error.OutOfMemory => |e| return e,
        };
        return fresh;
    }
}

/// The living entity with this UUID, or null.
pub fn findUuid(self: *const App, uuid: Uuid) ?ecs.Entity {
    const entity = self.by_uuid.get(uuid) orelse return null;
    return if (self.world.isAlive(entity)) entity else null;
}

fn forgetUuid(self: *App, entity: ecs.Entity) void {
    const held = self.uuids.fetchSwapRemove(entity) orelse return;
    _ = self.by_uuid.remove(held.value);
}

/// Give back the UUIDs of everything that has died, as `forgetDeadNames`
/// does the names.
fn forgetDeadUuids(self: *App) void {
    var at = self.uuids.count();
    while (at > 0) {
        at -= 1;
        const entity = self.uuids.keys()[at];
        if (!self.world.isAlive(entity)) self.forgetUuid(entity);
    }
}

// -------------------------------------------------------------------------
// The order of a parent's children
// -------------------------------------------------------------------------

/// Ranks given out start below this, so every entity with a place comes
/// before every one that has never been given one.
const unplaced: u64 = 1 << 48;

/// Where an entity comes among its siblings, as a number to sort by: the
/// order `setSiblingIndex` and a scene's list gave it, and after all of
/// those, the order the handles were given out in.
fn siblingRank(self: *const App, entity: ecs.Entity) u64 {
    return self.sibling_ranks.get(entity) orelse unplaced + entity.index;
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
    return self.siblingRank(a) < self.siblingRank(b);
}

/// The parent an entity hangs from, `.none` for a root: see `Parent`.
pub fn parentOf(self: *const App, entity: ecs.Entity) ecs.Entity {
    return hierarchy.parentOf(&self.world, entity);
}

/// What `setParent` can refuse.
pub const ParentError = error{
    /// The entity has been despawned, or never was - or the parent has.
    NoSuchEntity,
    /// The parent is the entity itself, or something that hangs from it: a
    /// loop, which nothing could be placed by.
    Loop,
} || PlaceError || NameError || ecs.World.Error;

/// Hang `entity` from `parent`, or from nothing for a root, last among its
/// new siblings. With `keep_global` it stays where it is in the world, its
/// own transform written to land there under the new parent; without, its
/// numbers stay as they are and it moves with the new parent's space. A
/// sibling with its name already gives it the first free one after it.
pub fn setParent(self: *App, entity: ecs.Entity, parent: ecs.Entity, keep_global: bool) ParentError!void {
    if (!self.world.isAlive(entity)) return error.NoSuchEntity;
    if (!parent.isNone()) {
        if (!self.world.isAlive(parent)) return error.NoSuchEntity;
        if (parent.eql(entity) or self.hangsFrom(parent, entity)) return error.Loop;
    }
    if (self.parentOf(entity).eql(parent)) return;
    const was = if (keep_global and self.world.has(entity, components.Transform2D))
        self.worldTransform(entity) orelse return error.Unplaced
    else
        null;
    if (parent.isNone()) {
        try self.world.remove(entity, components.Parent);
    } else {
        self.world.add(entity, components.Parent.of(parent)) catch |err| return switch (err) {
            error.NoSuchEntity => error.NoSuchEntity,
            else => |other| other,
        };
    }
    try self.setSiblingIndex(entity, std.math.maxInt(u32));
    if (self.nameOf(entity)) |name| {
        var copy: [256]u8 = undefined;
        const held = copy[0..@min(name.len, copy.len)];
        @memcpy(held, name[0..held.len]);
        try self.setFreeName(entity, held);
    }
    if (was) |placed| try self.setWorldTransform(entity, placed);
}

/// Whether `entity` hangs from `ancestor`, however far down.
pub fn hangsFrom(self: *const App, entity: ecs.Entity, ancestor: ecs.Entity) bool {
    var at = self.parentOf(entity);
    var depth: usize = 0;
    while (!at.isNone() and depth < 256) : (depth += 1) {
        if (at.eql(ancestor)) return true;
        at = self.parentOf(at);
    }
    return false;
}

/// Each parent's children in their order, and the roots, as one list of
/// families: built from the `Parent` components when the world has changed
/// shape since, or a place or a parent was given.
pub const Tree = struct {
    families: std.AutoHashMapUnmanaged(ecs.Entity, Family) = .empty,
    order: std.ArrayListUnmanaged(ecs.Entity) = .empty,
    /// The world's `structure` when it was built; null when something has
    /// changed that the world does not count.
    built: ?u64 = null,

    pub const Family = struct { start: u32, count: u32 };

    fn deinit(self: *Tree, gpa: Allocator) void {
        self.families.deinit(gpa);
        self.order.deinit(gpa);
    }

    /// Build it again when next asked.
    pub fn forget(self: *Tree) void {
        self.built = null;
    }
};

/// A parent's children in their order, `.none` for the roots: a slice of
/// the tree, good until the world next changes shape.
pub fn children(self: *App, parent: ecs.Entity) []const ecs.Entity {
    self.buildTree() catch return &.{};
    const family = self.tree.families.get(parent) orelse return &.{};
    return self.tree.order.items[family.start..][0..family.count];
}

fn buildTree(self: *App) Allocator.Error!void {
    if (self.tree.built == self.world.structure) return;
    const gpa = self.gpa;
    const Member = struct { parent: ecs.Entity, rank: u64, entity: ecs.Entity };
    var members: std.ArrayListUnmanaged(Member) = .empty;
    defer members.deinit(gpa);
    try members.ensureTotalCapacity(gpa, self.world.count());
    for (self.world.archetypeSlice()) |*archetype| {
        for (archetype.entities.items) |entity| {
            members.appendAssumeCapacity(.{ .parent = self.parentOf(entity), .rank = self.siblingRank(entity), .entity = entity });
        }
    }
    std.mem.sort(Member, members.items, {}, struct {
        fn before(_: void, a: Member, b: Member) bool {
            const pa = a.parent.toInt();
            const pb = b.parent.toInt();
            if (pa != pb) return pa < pb;
            return a.rank < b.rank;
        }
    }.before);
    self.tree.families.clearRetainingCapacity();
    self.tree.order.clearRetainingCapacity();
    try self.tree.order.ensureTotalCapacity(gpa, members.items.len);
    for (members.items, 0..) |member, at| {
        self.tree.order.appendAssumeCapacity(member.entity);
        const family = try self.tree.families.getOrPut(gpa, member.parent);
        if (!family.found_existing) family.value_ptr.* = .{ .start = @intCast(at), .count = 0 };
        family.value_ptr.count += 1;
    }
    self.tree.built = self.world.structure;
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

/// The child of `parent` called `name`, the roots for `.none`.
pub fn childNamed(self: *App, parent: ecs.Entity, name: []const u8) ?ecs.Entity {
    for (self.children(parent)) |child| {
        const own = self.names.get(child) orelse continue;
        if (std.mem.eql(u8, own, name)) return child;
    }
    return null;
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
    var at = if (path.len > 0 and path[0] == '/') ecs.Entity.none else from;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (at.isNone()) return null;
            at = self.parentOf(at);
            continue;
        }
        at = self.childNamed(at, part) orelse return null;
    }
    return if (at.isNone()) null else at;
}

/// The first entity called `name` that hangs from `root`, however far down,
/// in the tree's order; the whole world for `.none`. What a scene's own
/// "unique" names are found by, from its root.
pub fn findIn(self: *App, root: ecs.Entity, name: []const u8) ?ecs.Entity {
    for (self.children(root)) |child| {
        if (self.names.get(child)) |own| if (std.mem.eql(u8, own, name)) return child;
    }
    for (self.children(root)) |child| {
        if (self.findIn(child, name)) |found| return found;
    }
    return null;
}

// -------------------------------------------------------------------------
// Tiles
// -------------------------------------------------------------------------

/// Which chunk of which map: what `tile_chunks` finds an entity by.
pub const ChunkKey = struct {
    map: ecs.Entity,
    x: i32,
    y: i32,
};

pub const SetTileError = error{ NotATileMap, OutOfMemory };

/// Put `cell` at `x`, `y` of `map`, counted in tiles from the map's origin
/// and negative above it and to its left. The chunk it lands in is made when
/// there is none.
///
/// Gives back the chunk holding the cell, or null when an empty cell was put
/// where there was no chunk - or emptied the last tile of one, which takes
/// the chunk away with it.
pub fn setTile(self: *App, map: ecs.Entity, x: i32, y: i32, cell: tilemap.Cell) SetTileError!?ecs.Entity {
    if (!self.world.has(map, tilemap.TileMap)) return error.NotATileMap;
    const chunk_x = @divFloor(x, tilemap.chunk_side);
    const chunk_y = @divFloor(y, tilemap.chunk_side);
    const local_x: u8 = @intCast(@mod(x, tilemap.chunk_side));
    const local_y: u8 = @intCast(@mod(y, tilemap.chunk_side));

    const entity = self.tileChunkAt(map, chunk_x, chunk_y) orelse {
        // Nothing there to empty.
        if (cell.isEmpty()) return null;
        const made = try self.makeTileChunk(map, chunk_x, chunk_y);
        _ = self.world.get(made, tilemap.TileChunk).?.set(local_x, local_y, cell);
        return made;
    };

    const chunk = self.world.get(entity, tilemap.TileChunk).?;
    _ = chunk.set(local_x, local_y, cell);
    if (cell.isEmpty() and chunk.isEmpty()) {
        _ = self.tile_chunks.remove(.{ .map = map, .x = chunk_x, .y = chunk_y });
        self.world.despawn(entity);
        return null;
    }
    return entity;
}

/// What is at `x`, `y` of `map`: `Cell.empty` where nothing was painted.
pub fn tileAt(self: *App, map: ecs.Entity, x: i32, y: i32) tilemap.Cell {
    const chunk_x = @divFloor(x, tilemap.chunk_side);
    const chunk_y = @divFloor(y, tilemap.chunk_side);
    const entity = self.tileChunkAt(map, chunk_x, chunk_y) orelse return .empty;
    const chunk = self.world.get(entity, tilemap.TileChunk).?;
    return chunk.get(@intCast(@mod(x, tilemap.chunk_side)), @intCast(@mod(y, tilemap.chunk_side))).?;
}

/// The entity holding a map's chunk at `x`, `y`, in chunks. Found through
/// the index rather than by walking every chunk in the world.
pub fn tileChunkAt(self: *App, map: ecs.Entity, x: i32, y: i32) ?ecs.Entity {
    const key: ChunkKey = .{ .map = map, .x = x, .y = y };
    const entity = self.tile_chunks.get(key) orelse return null;
    // A chunk despawned elsewhere leaves its key behind; the first look
    // after that gives it back.
    const chunk = self.world.get(entity, tilemap.TileChunk) orelse {
        _ = self.tile_chunks.remove(key);
        return null;
    };
    if (!chunk.map.eql(map) or chunk.x != x or chunk.y != y) {
        _ = self.tile_chunks.remove(key);
        return null;
    }
    return entity;
}

/// A chunk of a map, made and put in the index. Its cells start empty.
pub fn makeTileChunk(self: *App, map: ecs.Entity, x: i32, y: i32) SetTileError!ecs.Entity {
    if (!self.world.has(map, tilemap.TileMap)) return error.NotATileMap;
    try self.tile_chunks.ensureUnusedCapacity(self.gpa, 1);
    const entity = self.world.spawnWith(.{tilemap.TileChunk{ .map = map, .x = x, .y = y }}) catch return error.OutOfMemory;
    self.tile_chunks.putAssumeCapacity(.{ .map = map, .x = x, .y = y }, entity);
    return entity;
}

/// How big one tile of a map is, in its own pixels: what its tile set says,
/// or the default for a map without one.
pub fn tileSizeOf(self: *App, map: ecs.Entity) [2]f32 {
    const held = self.world.getConst(map, tilemap.TileMap) orelse return .{ tileset.default_tile_size, tileset.default_tile_size };
    const set = self.tile_sets.get(held.tile_set) orelse return .{ tileset.default_tile_size, tileset.default_tile_size };
    return .{ @floatFromInt(set.tile_width), @floatFromInt(set.tile_height) };
}

/// Which cell of `map` a point of the world is in, counted in tiles from the
/// map's origin as `setTile` counts them. Null for an entity with no
/// `TileMap`.
pub fn cellAt(self: *App, map: ecs.Entity, point: math.Vec2) ?geometry.Vec2i {
    if (!self.world.has(map, tilemap.TileMap)) return null;
    const placed = self.worldTransform(map) orelse return null;
    const local = placed.unapply(point.x, point.y);
    const tile = self.tileSizeOf(map);
    return .init(
        std.math.lossyCast(i32, @floor(local.x / tile[0])),
        std.math.lossyCast(i32, @floor(local.y / tile[1])),
    );
}

/// The cells of `map` something is painted in: the smallest rectangle that
/// holds them all. Null for a map with nothing painted.
pub fn usedCells(self: *App, map: ecs.Entity) ?geometry.Rect2i {
    var out: ?geometry.Rect2i = null;
    var it = self.tile_chunks.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!key.map.eql(map)) continue;
        // One despawned elsewhere is not the map's any more.
        const chunk = self.world.getConst(entry.value_ptr.*, tilemap.TileChunk) orelse continue;
        if (!chunk.map.eql(map) or chunk.x != key.x or chunk.y != key.y) continue;
        for (chunk.cells, 0..) |cell, at| {
            if (cell.isEmpty()) continue;
            const x = key.x * tilemap.chunk_side + @as(i32, @intCast(at % tilemap.chunk_side));
            const y = key.y * tilemap.chunk_side + @as(i32, @intCast(at / tilemap.chunk_side));
            const place: geometry.Vec2i = .init(x, y);
            out = if (out) |held| held.expandTo(place) else .fromCells(place, place);
        }
    }
    return out;
}

/// What the tile at `x`, `y` of `map` says under its tile set's data layer
/// called `layer`: nought, or false, where it says nothing, and null where
/// nothing is painted or the set has no layer of that name. A script has the
/// number, or the truth, itself.
pub fn tileData(self: *App, map: ecs.Entity, x: i32, y: i32, layer: []const u8) ?tileset.Value {
    const held = self.world.getConst(map, tilemap.TileMap) orelse return null;
    const set = self.tile_sets.get(held.tile_set) orelse return null;
    return set.dataOf(self.tileAt(map, x, y), layer);
}

/// The same for the tile under a point of the world: the one something
/// stands on, say.
pub fn tileDataAt(self: *App, map: ecs.Entity, point: math.Vec2, layer: []const u8) ?tileset.Value {
    const cell = self.cellAt(map, point) orelse return null;
    return self.tileData(map, cell.x, cell.y, layer);
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
    return self.tile_sets.find(path);
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

/// The theme the project file names for its whole interface - `gui.theme` -
/// which every control is drawn with under the one it names itself; `.none`
/// for the engine's own look. Read the first time it is asked for, and again
/// when the project file names another.
pub fn projectTheme(self: *App) theme.ThemeHandle {
    const named = if (self.project.settings) |settings| settings.gui.theme else "";
    const held = &self.project_theme;
    if (std.mem.eql(u8, held.path(), named)) return held.handle;
    held.remember(named);
    held.handle = .none;
    if (named.len == 0) return .none;
    // Kept even when it does not read, so that it is said once and not a
    // frame.
    held.handle = self.loadTheme(named) catch |err| blk: {
        log.warn("the project's theme {s} did not read: {t}", .{ named, err });
        break :blk .none;
    };
    return held.handle;
}

pub const ProjectTheme = struct {
    handle: theme.ThemeHandle = .none,
    bytes: [512]u8 = undefined,
    len: usize = 0,

    fn path(self: *const ProjectTheme) []const u8 {
        return self.bytes[0..self.len];
    }

    fn remember(self: *ProjectTheme, named: []const u8) void {
        self.len = @min(named.len, self.bytes.len);
        @memcpy(self.bytes[0..self.len], named[0..self.len]);
    }
};

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
    return self.themes.find(path);
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

/// A parent's children in their order, as many as `found` holds, the first
/// ones kept when there are more; `.none` for the roots. See `children` for
/// the slice itself.
pub fn childrenOf(self: *App, parent: ecs.Entity, found: []ecs.Entity) []ecs.Entity {
    const family = self.children(parent);
    const count = @min(family.len, found.len);
    @memcpy(found[0..count], family[0..count]);
    return found[0..count];
}

/// Where an entity is among its parent's children, from nought. Null for
/// one that is not alive.
pub fn siblingIndex(self: *App, entity: ecs.Entity) ?u32 {
    if (!self.world.isAlive(entity)) return null;
    for (self.children(self.parentOf(entity)), 0..) |sibling, at| {
        if (sibling.eql(entity)) return @intCast(at);
    }
    return null;
}

/// Put an entity at `index` among its parent's children, the ones from
/// there on moving along one. An index past the end is the end. Kept beside
/// the world, and written into a scene as the order its list is in, so it
/// comes back as it was.
pub fn setSiblingIndex(self: *App, entity: ecs.Entity, index: u32) (error{NoSuchEntity} || Allocator.Error)!void {
    if (!self.world.isAlive(entity)) return error.NoSuchEntity;
    const parent = self.parentOf(entity);

    // Numbered afresh, the whole family, so none of it is left half placed.
    var family: std.ArrayList(ecs.Entity) = .empty;
    defer family.deinit(self.gpa);
    for (self.children(parent)) |other| {
        if (!other.eql(entity)) try family.append(self.gpa, other);
    }
    try family.insert(self.gpa, @min(index, family.items.len), entity);
    try self.placeInOrder(family.items);
}

/// Give entities places in the order given, after every place given out
/// before: what a scene's list does to the entities it made.
pub fn placeInOrder(self: *App, entities: []const ecs.Entity) Allocator.Error!void {
    try self.sibling_ranks.ensureUnusedCapacity(self.gpa, entities.len);
    for (entities) |entity| {
        self.sibling_ranks.putAssumeCapacity(entity, self.next_rank);
        self.next_rank += 1;
    }
    self.tree.forget();
}

/// Give every living entity that has no place one, in the order of its
/// handle - which is the order it is in now - so that what is placed next
/// comes after it rather than before. A world nobody reorders never pays
/// for this.
pub fn placeTheRest(self: *App) Allocator.Error!void {
    var rest: std.ArrayList(ecs.Entity) = .empty;
    defer rest.deinit(self.gpa);
    for (self.world.archetypeSlice()) |*archetype| {
        for (archetype.entities.items) |entity| {
            if (!self.sibling_ranks.contains(entity)) try rest.append(self.gpa, entity);
        }
    }
    if (rest.items.len == 0) return;
    std.mem.sort(ecs.Entity, rest.items, @as(*const App, self), siblingBefore);
    try self.placeInOrder(rest.items);
}

/// Forget the places of everything that has died, as `forgetDeadNames`
/// does the names.
fn forgetDeadPlaces(self: *App) void {
    var at = self.sibling_ranks.count();
    while (at > 0) {
        at -= 1;
        const entity = self.sibling_ranks.keys()[at];
        if (!self.world.isAlive(entity)) self.sibling_ranks.swapRemoveAt(at);
    }
}

// -------------------------------------------------------------------------
// Groups
// -------------------------------------------------------------------------
//
// A group is a name entities are put under - "enemies", "pickups" - to be
// found and called together, wherever they are in the tree. Kept beside the
// world, as names are, and written into a scene with each entity.

/// Put an entity in a group, made the first time it is named. Once is
/// enough: being put in again changes nothing.
pub fn addToGroup(self: *App, entity: ecs.Entity, group: []const u8) (error{NoSuchEntity} || Allocator.Error)!void {
    if (!self.world.isAlive(entity)) return error.NoSuchEntity;
    if (self.isInGroup(entity, group)) return;
    const known = self.groups.getPtr(group);
    const members = known orelse blk: {
        const copy = try self.gpa.dupe(u8, group);
        errdefer self.gpa.free(copy);
        try self.groups.put(self.gpa, copy, .empty);
        break :blk self.groups.getPtr(copy).?;
    };
    try members.append(self.gpa, entity);
}

/// Take an entity out of a group. The group stays, empty.
pub fn removeFromGroup(self: *App, entity: ecs.Entity, group: []const u8) void {
    const members = self.groups.getPtr(group) orelse return;
    for (members.items, 0..) |member, at| {
        if (!member.eql(entity)) continue;
        _ = members.orderedRemove(at);
        return;
    }
}

pub fn isInGroup(self: *const App, entity: ecs.Entity, group: []const u8) bool {
    const members = self.groups.getPtr(group) orelse return false;
    for (members.items) |member| {
        if (member.eql(entity)) return true;
    }
    return false;
}

/// A group's living members, in the order they joined: a slice good until a
/// member joins or leaves. What a script goes through: `for
/// (app.groupMembers("enemies")) |enemy|`, `app.groupMembers("player").first()`.
pub fn groupMembers(self: *App, group: []const u8) []const ecs.Entity {
    const members = self.groups.getPtr(group) orelse return &.{};
    // One despawned since the frame began goes now rather than at its end.
    var at = members.items.len;
    while (at > 0) {
        at -= 1;
        if (!self.world.isAlive(members.items[at])) _ = members.orderedRemove(at);
    }
    return members.items;
}

/// The groups an entity is in, as many as `found` holds.
pub fn groupsOf(self: *const App, entity: ecs.Entity, found: [][]const u8) [][]const u8 {
    var count: usize = 0;
    for (self.groups.keys(), self.groups.values()) |name, members| {
        if (count == found.len) break;
        for (members.items) |member| {
            if (!member.eql(entity)) continue;
            found[count] = name;
            count += 1;
            break;
        }
    }
    return found[0..count];
}

/// Call a method on every living member of a group, in the order they
/// joined - a component's, the script's, or one `addMethod` added: see
/// `callMethodOn`. A member that has no such method is passed over. The
/// members are copied first, so a call may add to the group or take from it.
pub fn callGroup(self: *App, group: []const u8, method: []const u8) anyerror!void {
    const members = try self.gpa.dupe(ecs.Entity, self.groupMembers(group));
    defer self.gpa.free(members);
    for (members) |member| {
        if (!self.world.isAlive(member)) continue;
        self.callMethodOn(member, method, &.{}) catch |err| switch (err) {
            error.NoSuchMethod => continue,
            else => return err,
        };
    }
}

/// Take the dead out of every group, at the end of the frame.
fn forgetDeadGroupMembers(self: *App) void {
    for (self.groups.values()) |*members| {
        var at = members.items.len;
        while (at > 0) {
            at -= 1;
            if (!self.world.isAlive(members.items[at])) _ = members.orderedRemove(at);
        }
    }
}

fn freeGroups(self: *App) void {
    for (self.groups.keys(), self.groups.values()) |name, *members| {
        self.gpa.free(name);
        members.deinit(self.gpa);
    }
}

// -------------------------------------------------------------------------
// Scenes
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
/// it by that name, and an `attr.Property` it declares is checked.
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

/// Read a scene's file to make things of, or find the one read from there
/// already. Nothing is made of it yet: see `instantiate` and `changeScene`,
/// and `scenes`.
///
/// A file `loadInBackground` is reading is taken from that load - waited
/// for, if it is not done - rather than read again.
pub fn loadScene(self: *App, path: []const u8) !scenes_mod.SceneHandle {
    try self.finishLoad(path);
    return self.scenes.load(self, path);
}

/// A scene from memory rather than a file: a test's, or one a game wrote
/// with `scene.write`. `name` is what it is found and written by.
pub fn addScene(self: *App, name: []const u8, bytes: []const u8) !scenes_mod.SceneHandle {
    return self.scenes.add(self.gpa, name, bytes);
}

/// The scene read from `path` already, if one was, however the path is
/// spelt: `res://`, from the root, or the system's.
pub fn findScene(self: *App, path: []const u8) ?scenes_mod.SceneHandle {
    if (self.scenes.find(path)) |known| return known;
    const named = self.project.canonical(self.gpa, path) catch return null;
    defer self.gpa.free(named);
    return self.scenes.find(named);
}

/// The path a scene was read from: what an instance is written as.
pub fn sceneSource(self: *App, handle: scenes_mod.SceneHandle) ?[]const u8 {
    return self.scenes.sourceOf(handle);
}

/// Read a scene's file again, for an editor that has just saved it: what is
/// made of it next is what was saved. What was made of it already stays.
pub fn reloadScene(self: *App, handle: scenes_mod.SceneHandle) !bool {
    return self.scenes.reload(self, handle);
}

pub fn unloadScene(self: *App, handle: scenes_mod.SceneHandle) void {
    self.scenes.unload(self.gpa, handle);
}

/// A tween: an entity of its own, hanging from `owner` - `.none` for the
/// top of the tree - whose steps move properties over time, and which goes
/// once it is done. See `tween.zig`.
pub fn tween(self: *App, owner: ecs.Entity) !ecs.Entity {
    const made = try self.spawn(owner);
    errdefer self.world.despawn(made);
    try self.world.add(made, tween_mod.Tween{});
    return made;
}

/// A step of `tween_entity`: the property `path` of `moved` - see
/// `property.zig` - moved from what it holds when the step starts to `to`,
/// over `seconds`.
pub fn tweenProperty(self: *App, tween_entity: ecs.Entity, moved: ecs.Entity, path: []const u8, to: property_mod.Value, seconds: f32) !void {
    if (!self.world.has(tween_entity, tween_mod.Tween)) return error.NotATween;
    const compiled = try property_mod.Property.compile(self, path);
    if (to.as(compiled.kind) == null) return error.WrongKindOfValue;
    const plan = try self.tweens.planOf(self.gpa, tween_entity);
    try plan.steps.append(self.gpa, .{
        .target = moved,
        .property = compiled,
        .to = to,
        .seconds = @max(seconds, 0),
        .ease = plan.ease,
        .with_before = plan.parallel and plan.steps.items.len > 0,
    });
}

/// A step that waits `seconds`.
pub fn tweenInterval(self: *App, tween_entity: ecs.Entity, seconds: f32) !void {
    if (!self.world.has(tween_entity, tween_mod.Tween)) return error.NotATween;
    const plan = try self.tweens.planOf(self.gpa, tween_entity);
    try plan.steps.append(self.gpa, .{ .seconds = @max(seconds, 0), .with_before = plan.parallel and plan.steps.items.len > 0 });
}

/// The steps added after this start together with the one before them,
/// rather than after it.
pub fn tweenParallel(self: *App, tween_entity: ecs.Entity, together: bool) !void {
    if (!self.world.has(tween_entity, tween_mod.Tween)) return error.NotATween;
    (try self.tweens.planOf(self.gpa, tween_entity)).parallel = together;
}

/// The curve the steps added after this move by: `.linear`, `.quad_out`,
/// `.back_in`, `.elastic_out`, ...
pub fn tweenEase(self: *App, tween_entity: ecs.Entity, ease: math.ease.Kind) !void {
    if (!self.world.has(tween_entity, tween_mod.Tween)) return error.NotATween;
    (try self.tweens.planOf(self.gpa, tween_entity)).ease = ease;
}

/// A step that calls a script's function when it is reached: a sound when
/// a panel is in, a door shut at the end. `t.tweenCallback(self.shut)`.
pub fn tweenCallback(self: *App, tween_entity: ecs.Entity, function: script_mod.flux.Value) !void {
    try self.addCallStep(tween_entity, function, .{ .seconds = 0 });
}

/// A step that calls a script's function with each value from `from` to
/// `to` over `seconds`, along the curve: a score counted up, a colour a
/// shader is given.
pub fn tweenMethod(self: *App, tween_entity: ecs.Entity, function: script_mod.flux.Value, from: property_mod.Value, to: property_mod.Value, seconds: f32) !void {
    try self.addCallStep(tween_entity, function, .{ .seconds = @max(seconds, 0), .start_at = from, .to = to, .along = true });
}

fn addCallStep(self: *App, tween_entity: ecs.Entity, function: script_mod.flux.Value, given: tween_mod.Step) !void {
    if (!self.world.has(tween_entity, tween_mod.Tween)) return error.NotATween;
    const scripts = self.scripts orelse return error.NoScripts;
    try scripts.calls.hold(scripts, function);
    errdefer scripts.calls.release(scripts, function);
    const plan = try self.tweens.planOf(self.gpa, tween_entity);
    var made = given;
    made.call = function;
    made.ease = plan.ease;
    made.with_before = plan.parallel and plan.steps.items.len > 0;
    try plan.steps.append(self.gpa, made);
}

/// The step added last starts from `from`, rather than from what its
/// property holds when it starts: a fade in from nothing.
pub fn tweenFrom(self: *App, tween_entity: ecs.Entity, from: property_mod.Value) !void {
    (try self.lastTweenStep(tween_entity)).start_at = from;
}

/// The step added last moves by its value from where it starts, rather than
/// to it: forty to the right of wherever it is.
pub fn tweenRelative(self: *App, tween_entity: ecs.Entity) !void {
    (try self.lastTweenStep(tween_entity)).relative = true;
}

/// The step added last waits `seconds` before it starts.
pub fn tweenDelay(self: *App, tween_entity: ecs.Entity, seconds: f32) !void {
    (try self.lastTweenStep(tween_entity)).delay = @max(seconds, 0);
}

fn lastTweenStep(self: *App, tween_entity: ecs.Entity) error{ NotATween, NoStep }!*tween_mod.Step {
    if (!self.world.has(tween_entity, tween_mod.Tween)) return error.NotATween;
    const plan = self.tweens.by.getPtr(tween_entity) orelse return error.NoStep;
    if (plan.steps.items.len == 0) return error.NoStep;
    return &plan.steps.items[plan.steps.items.len - 1];
}

/// The animations an `AnimationPlayer`'s library holds, in its order: a list
/// good until the next such question.
pub fn animationNames(self: *App, player: ecs.Entity) Allocator.Error![]const []const u8 {
    self.names_found.clearRetainingCapacity();
    const held = self.world.get(player, animation_mod.AnimationPlayer) orelse return self.names_found.items;
    const library = self.animation_libraries.get(held.library) orelse return self.names_found.items;
    for (library.animations.items) |*animation| try self.names_found.append(self.gpa, animation.name);
    return self.names_found.items;
}

/// Whether an `AnimationPlayer`'s library has an animation of that name.
pub fn hasAnimation(self: *App, player: ecs.Entity, name: []const u8) bool {
    return self.playerAnimation(player, name) != null;
}

/// How many seconds an animation of an `AnimationPlayer` lasts; nought for
/// one it has not.
pub fn animationLength(self: *App, player: ecs.Entity, name: []const u8) f32 {
    const animation = self.playerAnimation(player, name) orelse return 0;
    return animation.length;
}

fn playerAnimation(self: *App, player: ecs.Entity, name: []const u8) ?*const animation_mod.Animation {
    const held = self.world.get(player, animation_mod.AnimationPlayer) orelse return null;
    const library = self.animation_libraries.get(held.library) orelse return null;
    return library.find(name);
}

// -------------------------------------------------------------------------
// Drawing
// -------------------------------------------------------------------------
//
// Shapes a game draws in an entity's own space, kept until it draws again:
// see `drawing.zig`. Each call adds to the entity's picture, giving it a
// `Drawing2D` when it has none.

/// What can go wrong drawing: the entity is gone, or there is no room.
pub const DrawError = ecs.World.Error || error{NoSuchEntity};

fn pictureFor(self: *App, entity: ecs.Entity) DrawError!*drawing_mod.Picture {
    if (!self.world.isAlive(entity)) return error.NoSuchEntity;
    if (!self.world.has(entity, drawing_mod.Drawing2D)) try self.world.add(entity, drawing_mod.Drawing2D{});
    return self.drawings.pictureOf(self.gpa, entity);
}

/// A straight line `width` wide.
pub fn drawLine(self: *App, entity: ecs.Entity, from: math.Vec2, to: math.Vec2, color: Color, width: f32) DrawError!void {
    const picture = try self.pictureFor(entity);
    picture.cover(from, width);
    picture.cover(to, width);
    try picture.add(self.gpa, .{ .line = .{ .from = from, .to = to, .color = color, .width = width } });
}

/// A box from `position`, `size` big: filled, or its edges `width` wide.
pub fn drawRect(self: *App, entity: ecs.Entity, position: math.Vec2, size: math.Vec2, color: Color, filled: bool, width: f32) DrawError!void {
    const picture = try self.pictureFor(entity);
    picture.cover(position, width);
    picture.cover(position.add(size), width);
    try picture.add(self.gpa, .{ .rect = .{ .at = position, .size = size, .color = color, .filled = filled, .width = width } });
}

/// A circle: filled, or its edge `width` wide.
pub fn drawCircle(self: *App, entity: ecs.Entity, center: math.Vec2, radius: f32, color: Color, filled: bool, width: f32) DrawError!void {
    const picture = try self.pictureFor(entity);
    picture.cover(center, radius + width);
    try picture.add(self.gpa, .{ .circle = .{ .center = center, .radius = radius, .color = color, .filled = filled, .width = width } });
}

/// Part of a circle's edge, from `start_angle` round to `end_angle`, in
/// radians clockwise on screen from the right.
pub fn drawArc(self: *App, entity: ecs.Entity, center: math.Vec2, radius: f32, start_angle: f32, end_angle: f32, color: Color, width: f32) DrawError!void {
    const picture = try self.pictureFor(entity);
    picture.cover(center, radius + width);
    try picture.add(self.gpa, .{ .arc = .{ .center = center, .radius = radius, .start = start_angle, .end = end_angle, .color = color, .width = width } });
}

/// Lines joining the points in turn: a path, a graph.
pub fn drawPolyline(self: *App, entity: ecs.Entity, points: []const math.Vec2, color: Color, width: f32) DrawError!void {
    if (points.len < 2) return;
    const picture = try self.pictureFor(entity);
    const first = try picture.keepPoints(self.gpa, points, width);
    try picture.add(self.gpa, .{ .polyline = .{ .first = first, .count = @intCast(points.len), .color = color, .width = width } });
}

/// The shape the points go round, filled: any shape whose sides do not
/// cross, either way round.
pub fn drawPolygon(self: *App, entity: ecs.Entity, points: []const math.Vec2, color: Color) DrawError!void {
    const picture = try self.pictureFor(entity);
    try picture.addPolygon(self.gpa, points, color);
}

/// A picture from `position`, `size` big - its own size for nought - its
/// colours multiplied by `modulate`.
pub fn drawTexture(self: *App, entity: ecs.Entity, texture: Assets.TextureHandle, position: math.Vec2, size: math.Vec2, modulate: Color) DrawError!void {
    const picture = try self.pictureFor(entity);
    const shown: math.Vec2 = if (size.x == 0 and size.y == 0) if (self.assets.get(texture)) |held| .init(@floatFromInt(held.width), @floatFromInt(held.height)) else size else size;
    picture.cover(position, 0);
    picture.cover(position.add(shown), 0);
    try picture.add(self.gpa, .{ .texture = .{ .texture = texture, .at = position, .size = size, .color = modulate } });
}

/// Words, their first line's top left at `position`, `size` pixels high in
/// `font` - the first one loaded for none.
pub fn drawText(self: *App, entity: ecs.Entity, text: []const u8, position: math.Vec2, color: Color, size: f32, font: Assets.FontHandle) DrawError!void {
    const picture = try self.pictureFor(entity);
    const first = try picture.keepWords(self.gpa, text);
    var lines: f32 = 1;
    var widest: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    var count: f32 = 0;
    while (it.next()) |line| : (count += 1) widest = @max(widest, line.len);
    lines = @max(count, 1);
    picture.cover(position, 0);
    picture.cover(position.add(.init(@as(f32, @floatFromInt(widest)) * size, lines * size * 1.5)), 0);
    try picture.add(self.gpa, .{ .text = .{ .first = first, .len = @intCast(text.len), .at = position, .color = color, .size = size, .font = font } });
}

/// Everything an entity has drawn taken away.
pub fn clearDrawing(self: *App, entity: ecs.Entity) void {
    const picture = self.drawings.get(entity) orelse return;
    picture.clear();
}

/// Ask an entity's script to draw it again - its `draw(self)`, on an
/// emptied picture - at the end of this frame.
pub fn queueRedraw(self: *App, entity: ecs.Entity) DrawError!void {
    if (!self.world.isAlive(entity)) return error.NoSuchEntity;
    (try self.drawings.pictureOf(self.gpa, entity)).wanted = true;
}

// -------------------------------------------------------------------------
// Particles
// -------------------------------------------------------------------------

/// Start an emitter's cycle again from its beginning, every particle gone,
/// and emitting: a one-shot's burst again. See `particles.zig`.
pub fn restartParticles(self: *App, emitter: ecs.Entity) particles_mod.Error!void {
    try particles_mod.restart(self, emitter);
}

/// `count` particles let go of at once, over and above an emitter's cycle:
/// the sparks of a hit.
pub fn emitParticles(self: *App, emitter: ecs.Entity, count: u32) particles_mod.Error!void {
    try particles_mod.burst(self, emitter, count);
}

/// How many of an emitter's particles are alive now.
pub fn particleCount(self: *App, emitter: ecs.Entity) u32 {
    const held = self.particles.get(emitter) orelse return 0;
    return @intCast(held.aliveCount());
}

/// Read a `.anim` file - an animation library - or find the one read from
/// there already. What an `AnimationPlayer` plays; see `animation.zig`.
pub fn loadAnimations(self: *App, path: []const u8) !animation_mod.AnimationLibraryHandle {
    return self.animation_libraries.load(self, path);
}

/// An animation library from text rather than a file: a test's, or a
/// tool's. A name given before gets the new text.
pub fn addAnimations(self: *App, name: []const u8, text: []const u8) !animation_mod.AnimationLibraryHandle {
    return self.animation_libraries.add(self.gpa, name, text);
}

pub fn findAnimations(self: *App, path: []const u8) ?animation_mod.AnimationLibraryHandle {
    if (self.animation_libraries.find(path)) |known| return known;
    const named = self.project.canonical(self.gpa, path) catch return null;
    defer self.gpa.free(named);
    return self.animation_libraries.find(named);
}

/// Read a `.anim` file again, for an editor that has just saved it.
pub fn reloadAnimations(self: *App, handle: animation_mod.AnimationLibraryHandle) !bool {
    return self.animation_libraries.reload(self, handle);
}

/// Read a `.frames` file - animations of pictures - or find the one read
/// from there already. What an `AnimatedSprite2D` plays; see
/// `sprite_frames.zig`.
pub fn loadSpriteFrames(self: *App, path: []const u8) !sprite_frames_mod.SpriteFramesHandle {
    return self.sprite_frames.load(self, path);
}

/// New sprite frames, of no file until `saveSpriteFrames` writes them: one
/// animation, `"default"`, at 5 frames a second.
pub fn newSpriteFrames(self: *App) !sprite_frames_mod.SpriteFramesHandle {
    return self.sprite_frames.addNew(self);
}

/// `frames` written to `path`. New ones become that file's; a file's are
/// written there as a copy.
pub fn saveSpriteFrames(self: *App, frames: sprite_frames_mod.SpriteFramesHandle, path: []const u8) !void {
    return self.sprite_frames.saveAs(self, frames, path);
}

/// Sprite frames from text rather than a file. A name given before gets the
/// new text.
pub fn addSpriteFrames(self: *App, name: []const u8, text: []const u8) !sprite_frames_mod.SpriteFramesHandle {
    return self.sprite_frames.add(self, name, text);
}

/// Sprite frames made in code: `clips` over a `columns` by `rows` grid of
/// `texture`, found by `name`.
pub fn addGridFrames(self: *App, name: []const u8, texture: Assets.TextureHandle, columns: u16, rows: u16, clips: []const sprite_frames_mod.GridClip) !sprite_frames_mod.SpriteFramesHandle {
    return self.sprite_frames.addGrid(self, name, texture, columns, rows, clips);
}

pub fn findSpriteFrames(self: *App, path: []const u8) ?sprite_frames_mod.SpriteFramesHandle {
    if (self.sprite_frames.find(path)) |known| return known;
    const named = self.project.canonical(self.gpa, path) catch return null;
    defer self.gpa.free(named);
    return self.sprite_frames.find(named);
}

pub fn reloadSpriteFrames(self: *App, handle: sprite_frames_mod.SpriteFramesHandle) !bool {
    return self.sprite_frames.reload(self, handle);
}

/// Read a `.shader` file, or find the one read from there already: what a
/// `Material` draws with. One that does not compile says why in the log and
/// draws as none. See `shaders.zig`.
pub fn loadShader(self: *App, path: []const u8) !shaders_mod.ShaderHandle {
    return self.shaders.load(self, path);
}

/// A shader from text rather than a file: a test's, or a tool's. A name
/// given before gets the new text.
pub fn addShader(self: *App, name: []const u8, text: []const u8) !shaders_mod.ShaderHandle {
    return self.shaders.add(self, name, text);
}

pub fn findShader(self: *App, path: []const u8) ?shaders_mod.ShaderHandle {
    if (self.shaders.find(path)) |known| return known;
    const named = self.project.canonical(self.gpa, path) catch return null;
    defer self.gpa.free(named);
    return self.shaders.find(named);
}

/// Text an editor has open for a shader and has not saved, as it is typed:
/// what names it draws with it from the next frame, or - while it does not
/// compile - with what last did. `reloadShader` goes back to the file.
pub fn previewShader(self: *App, handle: shaders_mod.ShaderHandle, text: []const u8) !void {
    return self.shaders.preview(self, handle, text);
}

/// Read a shader's file again, for an editor that has just saved it: what
/// names it draws with the new one from the next frame.
pub fn reloadShader(self: *App, handle: shaders_mod.ShaderHandle) !bool {
    return self.shaders.reload(self, handle);
}

/// A shader as it was read: its text, what it compiled to, and why it did
/// not when it did not.
pub fn shaderOf(self: *App, handle: shaders_mod.ShaderHandle) ?*const shaders_mod.Shader {
    return self.shaders.get(handle);
}

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
pub fn shaderParamField(self: *App, entity: ecs.Entity, name: []const u8) ?shaders_mod.material.Field {
    const held = self.world.get(entity, shaders_mod.Material) orelse return null;
    const drawn = self.shaders.get(held.shader) orelse return null;
    for (drawn.params()) |field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

/// What `entity`'s material gives its shader's field `name` - its own, or
/// else the file's - as the floats `shaders.pack` puts in the buffer, into
/// `out`. Null for a field its shader does not have.
pub fn shaderParamOrDefault(self: *App, entity: ecs.Entity, name: []const u8, out: *[16]f32) ?[]const f32 {
    const held = self.world.get(entity, shaders_mod.Material) orelse return null;
    const drawn = self.shaders.get(held.shader) orelse return null;
    for (drawn.params()) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        const count = shaders_mod.componentsOf(field.ty);
        out.* = @splat(0);
        if (field.default) |first| @memcpy(out[0..@min(first.len, count)], first[0..@min(first.len, count)]);
        if (self.shader_params.get(entity, name)) |own| @memcpy(out[0..@min(own.len, count)], own[0..@min(own.len, count)]);
        return out[0..count];
    }
    return null;
}

/// Whether a frame has something in it that reads what is drawn under it:
/// then it is drawn where it can be read. See `render/screen.zig`.
fn readsScreen(self: *App) bool {
    var it = ecs.Query(.{shaders_mod.Material}).over(&self.world) catch return false;
    while (it.next()) |chunk| {
        for (chunk.slice(shaders_mod.Material)) |held| {
            const compiled = self.shaders.compiledOf(held.shader) orelse continue;
            if (compiled.readsScreen()) return true;
        }
    }
    return false;
}

/// Draw what each active `RenderView` sees into its picture: before the
/// screen, so what shows one shows this frame's. See `view_textures.zig`.
fn drawViews(self: *App) !void {
    var it = try ecs.Query(.{ components.Transform2D, components.Camera2D, components.RenderView }).over(&self.world);
    while (it.next()) |chunk| {
        const places = chunk.slice(components.Transform2D);
        const cameras = chunk.slice(components.Camera2D);
        const views = chunk.slice(components.RenderView);
        for (places, cameras, views, chunk.entities) |local, camera, view, entity| {
            if (!view.active) continue;
            const placed = hierarchy.resolve(&self.world, &self.snapshots, entity, local, self.time.alpha()) orelse continue;
            const picture = try self.viewPicture(entity, view);
            const gpu = (self.assets.get(picture) orelse continue).gpu;
            self.sprites.drawing = entity;
            defer self.sprites.drawing = .none;
            const through: View = .through(camera, placed, @floatFromInt(@max(view.width, 1)), @floatFromInt(@max(view.height, 1)));
            try self.sprites.draw(self.gpa, &self.world, &self.assets, &self.tile_sets, &self.snapshots, &self.inherited, .{ .texture = gpu }, through, view.clear_color, self.time.alpha());
        }
    }
}

/// A render view's picture, at the size it says now.
fn viewPicture(self: *App, entity: ecs.Entity, view: components.RenderView) !Assets.TextureHandle {
    const filter: rhi.Filter = if (view.filter == .linear) .linear else .nearest;
    if (self.views.textureOf(entity)) |held| {
        try self.assets.resizeRenderTexture(held, view.width, view.height, filter, view.clear_color.array());
        return held;
    }
    const made = try self.assets.addRenderTexture(view.width, view.height, filter, view.clear_color.array(), self.drawnUpsideDown(), "render view");
    errdefer self.assets.unload(made);
    try self.views.textures.put(self.gpa, entity, made);
    return made;
}

/// The picture a `RenderView` draws, as a texture: to put on a sprite, a
/// texture rect, or anything else a texture goes, from code. Made now if it
/// has not drawn one yet; `error.NotAView` for an entity with no view.
pub fn viewTexture(self: *App, view: ecs.Entity) !Assets.TextureHandle {
    const held = self.world.get(view, components.RenderView) orelse return error.NotAView;
    return self.viewPicture(view, held.*);
}

/// Draw a control's box the interface left for its material: see
/// `control.Nodes.drawCustom`.
fn drawControlBox(context: ?*anyopaque, command: ui_lib.RenderCommand, scissor: ?rhi.Rect, into: rhi.RenderTarget, size: ui_lib.Dimensions) anyerror!void {
    const self: *App = @ptrCast(@alignCast(context.?));
    try self.control_nodes.drawCustom(self, command, scissor, into, size);
}

/// Read a sound's file - `.wav`, `.ogg` or `.mp3` - or find the one read
/// from there already. What an `AudioPlayer` plays; see `audio.zig`.
pub fn loadAudio(self: *App, path: []const u8) !audio_mod.AudioClipHandle {
    try self.finishLoad(path);
    return self.audio.load(self, path);
}

/// A sound from memory rather than a file: a test's, or a tool's. Its
/// format is what its bytes say, or else its name's ending.
pub fn addAudio(self: *App, name: []const u8, bytes: []const u8) !audio_mod.AudioClipHandle {
    return self.audio.add(name, bytes);
}

/// The sound read from `path` already, if one was, however the path is
/// spelt.
pub fn findAudio(self: *App, path: []const u8) ?audio_mod.AudioClipHandle {
    if (self.audio.find(path)) |known| return known;
    const named = self.project.canonical(self.gpa, path) catch return null;
    defer self.gpa.free(named);
    return self.audio.find(named);
}

pub fn audioSource(self: *App, handle: audio_mod.AudioClipHandle) ?[]const u8 {
    return self.audio.sourceOf(handle);
}

/// Let a sound go, and every player playing it stop.
pub fn unloadAudio(self: *App, handle: audio_mod.AudioClipHandle) void {
    self.audio.unload(handle);
}

/// How long a sound is, in seconds: from Flux, `app.audioLength("res://door.ogg")`.
pub fn audioLength(self: *App, clip: audio_mod.AudioClipHandle) f32 {
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
    return self.audio.busVolumeDb(name) orelse audio_mod.silent_db;
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
    return audio_mod.linearToDb(linear);
}

pub fn dbToLinear(self: *const App, db: f32) f32 {
    _ = self;
    return audio_mod.dbToLinear(db);
}

/// Read a `.data` file, or find the one read from there already: see
/// `data`. What it says is read when its struct is made, by `readData`.
pub fn loadData(self: *App, path: []const u8) !data_mod.DataHandle {
    return self.data_files.load(self, path);
}

/// A data file from memory rather than a file: a test's, or one a tool
/// wrote with `data.write`. `name` is what it is found and written by.
pub fn addData(self: *App, name: []const u8, bytes: []const u8) !data_mod.DataHandle {
    return self.data_files.add(self.gpa, name, bytes);
}

/// The data file read from `path` already, if one was, however the path is
/// spelt.
pub fn findData(self: *App, path: []const u8) ?data_mod.DataHandle {
    if (self.data_files.find(path)) |known| return known;
    const named = self.project.canonical(self.gpa, path) catch return null;
    defer self.gpa.free(named);
    return self.data_files.find(named);
}

pub fn dataSource(self: *App, handle: data_mod.DataHandle) ?[]const u8 {
    return self.data_files.sourceOf(handle);
}

/// Read a data file again, for an editor that has just saved it: what
/// `readData` makes next is what was saved.
pub fn reloadData(self: *App, handle: data_mod.DataHandle) !bool {
    return self.data_files.reload(self, handle);
}

pub fn unloadData(self: *App, handle: data_mod.DataHandle) void {
    self.data_files.unload(self.gpa, handle);
}

/// A data file's struct, made anew and given the file's values - from Flux,
/// `app.readData("res://dialogue/intro.data")`. A value the struct cannot
/// hold is said and passed over, as a scene's `"exports"` are.
pub fn readData(self: *App, handle: data_mod.DataHandle) !script_mod.flux.Value {
    const scripts = self.scripts orelse return error.NoScripts;
    const held = self.data_files.get(handle) orelse return error.NoSuchData;
    const contents = try data_mod.read(self.gpa, held.bytes);
    defer contents.deinit();
    return scripts.calls.readData(scripts, &contents, held.source);
}

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
pub fn instantiate(self: *App, scene_handle: scenes_mod.SceneHandle, parent: ecs.Entity) !ecs.Entity {
    const held = self.scenes.get(scene_handle) orelse return error.NoSuchScene;
    if (!parent.isNone() and !self.world.isAlive(parent)) return error.NoSuchEntity;
    var made: std.ArrayList(ecs.Entity) = .empty;
    defer made.deinit(self.gpa);
    errdefer for (made.items) |e| if (self.world.isAlive(e)) self.world.despawn(e);
    const within: scene.Nesting = .{ .scene = scene_handle };
    const loaded = try scene.read(self, held.bytes, .{
        .parent = parent,
        .instance = self.newUuid(),
        .spawned = &made,
        .within = &within,
    });
    try self.keepInstance(loaded.root, scene_handle, made.items);
    return loaded.root;
}

/// One instance of a scene: see `instantiate`.
pub const Instance = struct {
    scene: scenes_mod.SceneHandle,
    /// What it made, its root not among them, the insides of the instances
    /// in it among them.
    members: []ecs.Entity,
    /// Its root as the scene made it, every field of every component, for
    /// a scene written with the instance in it to write what differs.
    template: []u8,
};

/// Remember `root` as an instance of `scene_handle`, which made `made`.
pub fn keepInstance(self: *App, root: ecs.Entity, scene_handle: scenes_mod.SceneHandle, made: []const ecs.Entity) !void {
    const gpa = self.gpa;
    var members: std.ArrayList(ecs.Entity) = .empty;
    errdefer members.deinit(gpa);
    try members.ensureTotalCapacity(gpa, made.len);
    for (made) |e| {
        if (!e.eql(root)) members.appendAssumeCapacity(e);
    }
    const template = try scene.entityTemplate(self, gpa, root);
    errdefer gpa.free(template);
    try self.instances.ensureUnusedCapacity(gpa, 1);
    const owned = try members.toOwnedSlice(gpa);
    self.instances.putAssumeCapacity(root, .{ .scene = scene_handle, .members = owned, .template = template });
}

/// What `root` is an instance of, when it is the root of one.
pub fn instanceOf(self: *const App, root: ecs.Entity) ?*const Instance {
    return self.instances.getPtr(root);
}

/// The root of the instance an entity is inside of, if it is inside one -
/// the outermost, where instances are inside instances. Not for a root
/// itself unless it is inside another.
pub fn instanceHolding(self: *const App, entity: ecs.Entity) ?ecs.Entity {
    var found: ?ecs.Entity = null;
    for (self.instances.keys(), self.instances.values()) |root, held| {
        if (!self.world.isAlive(root)) continue;
        for (held.members) |member| {
            if (!member.eql(entity)) continue;
            // The outermost holds the most.
            if (found) |other| {
                if (self.instances.getPtr(other).?.members.len >= held.members.len) break;
            }
            found = root;
            break;
        }
    }
    return found;
}

/// An instance made the scene's own: its insides are written as themselves
/// from now on, and a change to the scene file reaches it no more.
pub fn makeLocal(self: *App, root: ecs.Entity) void {
    const held = self.instances.fetchSwapRemove(root) orelse return;
    self.gpa.free(held.value.members);
    self.gpa.free(held.value.template);
}

fn freeInstances(self: *App) void {
    for (self.instances.values()) |held| {
        self.gpa.free(held.members);
        self.gpa.free(held.template);
    }
}

/// Forget the instances whose root has died, at the end of the frame.
fn forgetDeadInstances(self: *App) void {
    var at = self.instances.count();
    while (at > 0) {
        at -= 1;
        const root = self.instances.keys()[at];
        if (self.world.isAlive(root)) continue;
        const held = self.instances.values()[at];
        self.gpa.free(held.members);
        self.gpa.free(held.template);
        self.instances.swapRemoveAt(at);
    }
}

/// Despawn an entity and everything that hangs from it, now rather than at
/// the end of the frame.
pub fn despawnTree(self: *App, entity: ecs.Entity) Allocator.Error!void {
    if (!self.world.isAlive(entity)) return;
    var doomed: std.ArrayList(ecs.Entity) = .empty;
    defer doomed.deinit(self.gpa);
    try doomed.append(self.gpa, entity);
    var at: usize = 0;
    while (at < doomed.items.len) : (at += 1) {
        try doomed.appendSlice(self.gpa, self.children(doomed.items[at]));
    }
    for (doomed.items) |e| {
        if (self.world.isAlive(e)) self.world.despawn(e);
    }
}

/// Play another scene from the end of this frame: the one playing goes,
/// with everything that hangs from it, and this is read in its place.
/// What does not belong to the scene - an autoload, what the game spawned
/// at the top of the tree itself - stays. See `openScene`.
///
/// ```zig
/// app.changeScene(try app.loadScene("res://levels/two.json"));
/// ```
pub fn changeScene(self: *App, scene_handle: scenes_mod.SceneHandle) void {
    self.scene_next = scene_handle;
}

/// `changeScene`, now: before the first frame, or from a tool.
pub fn openScene(self: *App, scene_handle: scenes_mod.SceneHandle) !void {
    const held = self.scenes.get(scene_handle) orelse return error.NoSuchScene;
    // Gone first, so the next is read with its own UUIDs even when it is
    // the same scene again.
    for (self.scene_roots.items) |root| try self.despawnTree(root);
    self.scene_roots.clearRetainingCapacity();
    self.scene_now = .none;
    var made: std.ArrayList(ecs.Entity) = .empty;
    defer made.deinit(self.gpa);
    _ = try scene.read(self, held.bytes, .{ .spawned = &made });
    for (made.items) |e| {
        if (self.parentOf(e).isNone() and !self.world.has(e, tilemap.TileChunk)) try self.scene_roots.append(self.gpa, e);
    }
    self.scene_now = scene_handle;
}

/// The scene the game is playing: what `openScene` or `changeScene` opened
/// last. `.none` before one has.
pub fn currentScene(self: *const App) scenes_mod.SceneHandle {
    return self.scene_now;
}

/// The scene the game is playing, from its start again, at the end of the
/// frame: a level restarted. Nothing before a scene is open.
pub fn reloadCurrentScene(self: *App) void {
    if (!self.scene_now.isNone()) self.changeScene(self.scene_now);
}

/// The first entity at the top of the scene the game is playing - the one
/// root of a scene that has one - or `.none` before a scene is open.
pub fn currentSceneRoot(self: *const App) ecs.Entity {
    for (self.scene_roots.items) |root| if (self.world.isAlive(root)) return root;
    return .none;
}

/// Open what the project says a game opens with: its boot splash while it
/// reads, its autoloads - each named after its file and kept when the scene
/// changes - and then its main scene. What `Options.open_project` does at
/// `startup`.
pub fn openProject(self: *App) !void {
    const settings = self.project.settings orelse return;
    const application = settings.application;
    if (application.boot_splash.show) self.showBootSplash(application.boot_splash);
    try self.openAutoloads();
    if (application.main_scene.len > 0) try self.openScene(try self.loadScene(application.main_scene));
}

/// The project's `application.autoload` list, made: each scene or script an
/// entity named after its file, which a scene change leaves. What
/// `openProject` does before the main scene, for a tool that opens another.
pub fn openAutoloads(self: *App) !void {
    const settings = self.project.settings orelse return;
    for (settings.application.autoload) |path| {
        self.autoload(path) catch |err| {
            log.err("the autoload {s} did not open: {t}", .{ path, err });
            return err;
        };
    }
}

/// One autoload: a script on an entity of its own, or a scene's instance,
/// named after its file.
fn autoload(self: *App, path: []const u8) !void {
    const name = std.fs.path.stem(path);
    const made = if (std.ascii.endsWithIgnoreCase(path, ".flux")) blk: {
        const file = try self.loadScript(path);
        break :blk try self.world.spawnWith(.{script_mod.Script.of(file)});
    } else try self.instantiate(try self.loadScene(path), .none);
    try self.setFreeName(made, name);
}

/// A frame of the project's boot splash: its colour, and its picture in the
/// middle of the window. Nothing without a window.
fn showBootSplash(self: *App, splash: Project.Application.BootSplash) void {
    if (self.window == null) return;
    const kept = self.background;
    defer self.background = kept;
    self.background = splash.color;
    var shown: ?ecs.Entity = null;
    if (splash.image.len > 0) {
        if (self.assets.loadTexture(splash.image, .{ .filter = .linear })) |picture| {
            const middle = self.screenToWorld(@as(f32, @floatFromInt(self.frame.width)) / 2, @as(f32, @floatFromInt(self.frame.height)) / 2);
            shown = self.world.spawnWith(.{ components.Transform2D.at(middle.x, middle.y), components.Sprite.of(picture) }) catch null;
        } else |err| log.warn("the boot splash's picture {s} did not read: {t}", .{ splash.image, err });
    }
    defer if (shown) |e| self.world.despawn(e);
    self.render() catch |err| log.warn("the boot splash was not drawn: {t}", .{err});
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
    if (self.io == null) return error.NoIo;
    // Memory any thread can ask for, since the load's thread does.
    const gpa = std.heap.smp_allocator;
    const source = try self.project.canonical(gpa, path);
    errdefer gpa.free(source);
    const kind = loadedKind(source) orelse return error.NotAnAsset;
    if (self.isRead(kind, source) or self.loadOf(source) != null) {
        gpa.free(source);
        return;
    }
    // A pack's file is read out of the pack, by its own name.
    const file = if (self.project.pack != null and Project.isProjectPath(source))
        try gpa.dupe(u8, source)
    else
        try self.project.osPath(gpa, source);
    errdefer gpa.free(file);
    const load = try gpa.create(background_mod.Load);
    errdefer gpa.destroy(load);
    load.* = .{ .gpa = gpa, .kind = kind, .source = source, .file = file, .files = self.project.files() };
    try self.loads.append(self.gpa, load);
    if (background_mod.threaded) {
        load.thread = std.Thread.spawn(.{}, background_mod.Load.run, .{load}) catch null;
        // No thread to be had: a piece a frame, as on a page.
        if (load.thread == null) load.run();
    }
}

/// How far the file at `path` has got, from nought to one: one once it is
/// read, in the background or not, and nought while nothing is reading it.
pub fn loadProgress(self: *App, path: []const u8) f32 {
    const named = self.project.canonical(self.gpa, path) catch return 0;
    defer self.gpa.free(named);
    if (loadedKind(named)) |kind| if (self.isRead(kind, named)) return 1;
    const load = self.loadOf(named) orelse return 0;
    // One only once it can be taken without a wait.
    return if (load.done()) 1 else @min(load.progress(), 0.99);
}

/// Where a file is in `loadInBackground`: `done` once it is read - in the
/// background or not - `failed` for a load that did not read, which says
/// why when it is taken, and `none` when nothing is reading it.
pub const LoadStatus = enum { none, loading, done, failed };

pub fn loadStatus(self: *App, path: []const u8) LoadStatus {
    const named = self.project.canonical(self.gpa, path) catch return .none;
    defer self.gpa.free(named);
    if (loadedKind(named)) |kind| if (self.isRead(kind, named)) return .done;
    const load = self.loadOf(named) orelse return .none;
    if (!load.done()) return .loading;
    return if (load.failure != null) .failed else .done;
}

/// Wait for the background load of `path`, if there is one, and make what
/// it read what it is: the next load of the file finds it. What went wrong
/// is its error. Nothing when nothing is reading it.
pub fn finishLoad(self: *App, path: []const u8) !void {
    if (self.loads.items.len == 0) return;
    const named = try self.project.canonical(self.gpa, path);
    defer self.gpa.free(named);
    if (self.loadOf(named)) |load| try self.takeLoad(load);
}

/// What a file is to `loadInBackground`: what its ending says, and a scene
/// for a `.json`, which is the one a game loads.
fn loadedKind(path: []const u8) ?AssetKind {
    if (AssetKind.ofPath(path)) |kind| return kind;
    return if (std.ascii.endsWithIgnoreCase(path, ".json")) .scene else null;
}

/// Whether the file at `path`, of `kind`, is read into its table.
fn isRead(self: *App, kind: AssetKind, path: []const u8) bool {
    return switch (kind) {
        inline else => |k| self.findAsset(k.Handle(), path) != null,
    };
}

/// The background load of the file at `source`, as `Project.canonical`
/// spells it.
fn loadOf(self: *App, source: []const u8) ?*background_mod.Load {
    for (self.loads.items) |load| if (std.mem.eql(u8, load.source, source)) return load;
    return null;
}

/// What a background load read, once it is done - waited for, if it is not
/// - made what it is: the pictures textures, the sounds clips, the scene a
/// scene. The engine's other files are read again by their own loads, which
/// is quick. The load is let go of either way. A file that did not read is
/// its error.
fn takeLoad(self: *App, load: *background_mod.Load) !void {
    defer self.dropLoad(load);
    load.join();
    while (load.work()) {}
    if (load.failure) |err| return err;
    for (load.decoded.items) |picture| {
        if (self.assets.findTexture(picture.source) != null) continue;
        _ = self.assets.adoptTexture(picture.source, picture.width, picture.height, picture.pixels, .{}) catch |err|
            log.warn("the picture {s} did not reach the GPU: {t}", .{ picture.source, err });
    }
    for (load.heard.items) |sound| {
        if (self.audio.find(sound.source) != null) continue;
        _ = self.audio.adopt(self, sound.source, sound.bytes) catch |err|
            log.warn("the sound {s} was not taken: {t}", .{ sound.source, err });
    }
    switch (load.kind) {
        .scene => if (self.scenes.find(load.source) == null) {
            _ = try self.scenes.add(self.gpa, load.source, load.bytes);
        },
        .audio => if (self.audio.find(load.source) == null) {
            _ = try self.audio.adopt(self, load.source, load.bytes);
        },
        .font => if (self.assets.findFont(load.source) == null) {
            _ = try self.assets.adoptFont(load.source, load.bytes, .{});
        },
        else => {},
    }
}

/// A load let go of, whether it was taken or not.
fn dropLoad(self: *App, load: *background_mod.Load) void {
    for (self.loads.items, 0..) |held, at| {
        if (held != load) continue;
        _ = self.loads.swapRemove(at);
        break;
    }
    load.deinit();
    load.gpa.destroy(load);
}

/// Write a scene with nothing in it to `path`: a new level, for an editor to
/// open and fill. Never over a file already there - that is
/// `error.PathAlreadyExists` - and the folder it goes in has to be there.
pub fn createScene(self: *App, path: []const u8, options: scene.SaveOptions) !void {
    const io = self.io orelse return error.NoIo;
    const bytes = try scene.writeEmpty(self.gpa, options);
    defer self.gpa.free(bytes);
    const file = try self.project.osPath(self.gpa, path);
    defer self.gpa.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = bytes, .flags = .{ .exclusive = true } });
}

/// What the scene at `path` says of itself - its version, its format, how
/// many entities and which files - read without loading it. Null for a file
/// that is not a scene. Free it with `Info.deinit`. See `scene.readInfo`.
pub fn sceneInfo(self: *App, path: []const u8, diagnostics: ?*json.Diagnostics) !?scene.Info {
    const bytes = try self.project.readFileAlloc(self.gpa, path, .unlimited);
    defer self.gpa.free(bytes);
    return scene.readInfo(self.gpa, bytes, diagnostics);
}

/// The most a file is read as text: `readText`.
pub const text_limit = 64 << 20;

/// The text of the file at `path` - `res://`, `user://`, `uid://` or the
/// system's own - in `gpa`'s memory, for the caller to free.
/// `error.FileNotFound` where there is none.
pub fn readText(self: *App, gpa: Allocator, path: []const u8) ![]u8 {
    return self.project.readFileAlloc(gpa, path, .limited(text_limit));
}

/// Write `text` to the file at `path`, over what it held, making the
/// folders on the way. The new text is written beside the old and then put
/// in its place, so a game that stops halfway through a save leaves the
/// last one whole.
pub fn writeText(self: *App, path: []const u8, text: []const u8) !void {
    const io = self.io orelse return error.NoIo;
    const file = try self.project.osPath(self.gpa, path);
    defer self.gpa.free(file);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, file, .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, text);
    try atomic.replace(io);
}

/// Whether there is a file or a folder at `path`.
pub fn fileExists(self: *App, path: []const u8) bool {
    if (self.project.packInfo(path) != null) return true;
    const io = self.io orelse return false;
    const file = self.project.osPath(self.gpa, path) catch return false;
    defer self.gpa.free(file);
    std.Io.Dir.cwd().access(io, file, .{}) catch return false;
    return true;
}

/// Make the folder at `path`, and the ones it is in. One there already is
/// fine.
pub fn makeDir(self: *App, path: []const u8) !void {
    const io = self.io orelse return error.NoIo;
    const file = try self.project.osPath(self.gpa, path);
    defer self.gpa.free(file);
    try std.Io.Dir.cwd().createDirPath(io, file);
}

/// Take out the file at `path`, or the folder, when it is empty.
pub fn removeFile(self: *App, path: []const u8) !void {
    const io = self.io orelse return error.NoIo;
    const file = try self.project.osPath(self.gpa, path);
    defer self.gpa.free(file);
    std.Io.Dir.cwd().deleteFile(io, file) catch |err| switch (err) {
        error.IsDir => try std.Io.Dir.cwd().deleteDir(io, file),
        else => return err,
    };
}

/// What a folder holds, by name, in order. See `listDir`.
pub const Listing = struct {
    /// A folder's name ends with `/`: `slots/`.
    names: [][]u8,

    pub fn deinit(self: Listing, gpa: Allocator) void {
        for (self.names) |name| gpa.free(name);
        gpa.free(self.names);
    }
};

/// The names in the folder at `path`, sorted, a folder's ending with `/`.
/// `error.FileNotFound` where there is none.
pub fn listDir(self: *App, gpa: Allocator, path: []const u8) !Listing {
    if (self.project.pack != null and Project.isProjectPath(path)) {
        return .{ .names = (try self.project.packListing(gpa, path)) orelse return error.FileNotFound };
    }
    const io = self.io orelse return error.NoIo;
    const file = try self.project.osPath(self.gpa, path);
    defer self.gpa.free(file);
    var dir = try std.Io.Dir.cwd().openDir(io, file, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try names.ensureUnusedCapacity(gpa, 1);
        const folder = entry.kind == .directory;
        const name = try gpa.alloc(u8, entry.name.len + @intFromBool(folder));
        @memcpy(name[0..entry.name.len], entry.name);
        if (folder) name[entry.name.len] = '/';
        names.appendAssumeCapacity(name);
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return .{ .names = try names.toOwnedSlice(gpa) };
}

/// Add `text` to the end of the file at `path`, making it - and the folders
/// it is in - when there is none: a log, a line at a time.
pub fn appendText(self: *App, path: []const u8, text: []const u8) !void {
    const io = self.io orelse return error.NoIo;
    const file = try self.project.osPath(self.gpa, path);
    defer self.gpa.free(file);
    if (std.fs.path.dirname(file)) |folder| try std.Io.Dir.cwd().createDirPath(io, folder);
    var handle = try std.Io.Dir.cwd().createFile(io, file, .{ .truncate = false, .read = true });
    defer handle.close(io);
    const end = (try handle.stat(io)).size;
    var buffer: [4096]u8 = undefined;
    var out = handle.writer(io, &buffer);
    try out.seekTo(end);
    try out.interface.writeAll(text);
    try out.interface.flush();
}

/// What is known of a file without reading it. See `fileInfo`.
pub const FileInfo = struct {
    /// Bytes; nought for a folder.
    size: u64,
    /// When it was last written.
    modified: datetime.Instant,
    folder: bool,
};

/// The size of the file at `path`, when it was last written, and whether it
/// is a folder. `error.FileNotFound` where there is none.
pub fn fileInfo(self: *App, path: []const u8) !FileInfo {
    if (self.project.pack != null and Project.isProjectPath(path)) {
        const info = self.project.packInfo(path) orelse return error.FileNotFound;
        // A pack keeps no times: it was all made at once.
        return .{ .size = info.size, .modified = .{ .us = 0 }, .folder = info.folder };
    }
    const io = self.io orelse return error.NoIo;
    const file = try self.project.osPath(self.gpa, path);
    defer self.gpa.free(file);
    const stat = try std.Io.Dir.cwd().statFile(io, file, .{});
    const folder = stat.kind == .directory;
    return .{
        .size = if (folder) 0 else stat.size,
        .modified = .{ .us = @intCast(@divFloor(stat.mtime.nanoseconds, 1000)) },
        .folder = folder,
    };
}

/// Whether there is a folder at `path`.
pub fn isDir(self: *App, path: []const u8) bool {
    const info = self.fileInfo(path) catch return false;
    return info.folder;
}

/// The SHA-256 of the file at `path`: the same file, the same 32 bytes -
/// whether a download finished whole, or a save is the one the game wrote.
pub fn fileSha256(self: *App, path: []const u8) ![32]u8 {
    if (self.project.pack != null and Project.isProjectPath(path)) {
        const bytes = try self.project.readFileAlloc(self.gpa, path, .unlimited);
        defer self.gpa.free(bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return digest;
    }
    const io = self.io orelse return error.NoIo;
    const file = try self.project.osPath(self.gpa, path);
    defer self.gpa.free(file);
    var handle = try std.Io.Dir.cwd().openFile(io, file, .{});
    defer handle.close(io);
    var in = handle.reader(io, &.{});
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const got = in.interface.readSliceShort(&chunk) catch return in.err orelse error.ReadFailed;
        if (got == 0) break;
        hash.update(chunk[0..got]);
    }
    return hash.finalResult();
}

/// `text` written to `path` as gzip, which any tool opens: a big save in a
/// tenth of the room. `readCompressed` reads it.
pub fn writeCompressed(self: *App, path: []const u8, text: []const u8) !void {
    const bytes = try sealed.compress(self.gpa, text);
    defer self.gpa.free(bytes);
    try self.writeText(path, bytes);
}

/// The text of a file `writeCompressed` wrote. `error.NotCompressed` for a
/// file that is not gzip.
pub fn readCompressed(self: *App, gpa: Allocator, path: []const u8) ![]u8 {
    const bytes = try self.readText(self.gpa, path);
    defer self.gpa.free(bytes);
    return sealed.decompress(gpa, bytes, text_limit);
}

/// `text` written to `path` compressed and sealed with `password`: nobody
/// reads it, and a file changed by hand is refused rather than taken. See
/// `sealed`. `secret_cost` is how hard the password is made to guess.
pub fn writeSecret(self: *App, path: []const u8, text: []const u8, password: []const u8) !void {
    const io = self.io orelse return error.NoIo;
    const bytes = try sealed.seal(self.gpa, io, text, password, self.secret_cost);
    defer self.gpa.free(bytes);
    try self.writeText(path, bytes);
}

/// The text of a file `writeSecret` wrote with `password`.
/// `error.CannotOpen` for another password or a file changed since;
/// `error.NotSealed` for a file that was never sealed.
pub fn readSecret(self: *App, gpa: Allocator, path: []const u8, password: []const u8) ![]u8 {
    const io = self.io orelse return error.NoIo;
    const bytes = try self.readText(self.gpa, path);
    defer self.gpa.free(bytes);
    return sealed.open(gpa, io, bytes, password, text_limit);
}

/// Open a web or mail address in the player's browser or mail program: a
/// game's page, its store, an address to write to. Only `http://`,
/// `https://` and `mailto:` - anything else is `error.NotAllowed`, so a
/// script cannot start a program with it.
pub fn openUrl(self: *App, url: []const u8) !void {
    const io = self.io orelse return error.NoIo;
    inline for (.{ "http://", "https://", "mailto:" }) |allowed| {
        if (std.ascii.startsWithIgnoreCase(url, allowed)) return platform.shell.openUrl(self.gpa, io, url);
    }
    return error.NotAllowed;
}

/// Open the file at `path` in the program the player opens its kind with,
/// or a folder in the file manager. `error.Unsupported` where there is none
/// to ask: a page, a phone.
pub fn openPath(self: *App, path: []const u8) !void {
    const io = self.io orelse return error.NoIo;
    const file = try self.project.osPath(self.gpa, path);
    defer self.gpa.free(file);
    try platform.shell.openPath(self.gpa, io, file);
}

/// Show the file at `path` picked out in the file manager's window of its
/// folder: a Saves folder button's `showInFolder("user://saves/slot1.json")`.
pub fn showInFolder(self: *App, path: []const u8) !void {
    const io = self.io orelse return error.NoIo;
    const file = try self.project.osPath(self.gpa, path);
    defer self.gpa.free(file);
    try platform.shell.showInFolder(self.gpa, io, file);
}

/// Write a data file of a script's struct: the values of its `@export`
/// fields, as `readData` gives them back - the struct as a save. From Flux,
/// `app.writeData(save, "user://saves/one.data")`. A data file read from
/// there already is read again, so the next `readData` gives what was
/// written. A field whose value a file cannot say - an entity, a function -
/// is passed over with a warning.
pub fn writeData(self: *App, value: script_mod.flux.Value, path: []const u8) !void {
    const scripts = self.scripts orelse return error.NoScripts;
    const text = try scripts.calls.writeData(scripts, value);
    defer self.gpa.free(text);
    try self.writeText(path, text);
    if (self.findData(path)) |known| _ = try self.reloadData(known);
}

/// Everything out of the world at once - every entity, name and UUID - and
/// an empty world in its place: a level loaded over another is this and then
/// `loadScene`. Not from inside a query, which is walking the world it
/// throws away.
pub fn clearWorld(self: *App) void {
    self.bodies.clear(self);
    self.areas.clear();
    self.picking.clear();
    self.commands.clear();
    self.world.deinit();
    self.world = .init(self.gpa);
    self.snapshots.clearRetainingCapacity();
    self.orphans.clearRetainingCapacity();
    self.tile_chunks.clearRetainingCapacity();
    self.names.clearRetainingCapacity();
    self.freeNames();
    self.tree.forget();
    self.freeGroups();
    self.groups.clearRetainingCapacity();
    self.uuids.clearRetainingCapacity();
    self.by_uuid.clearRetainingCapacity();
    self.sibling_ranks.clearRetainingCapacity();
    self.unknown_components.clear(self.gpa);
    self.exports.clear();
    self.freeInstances();
    self.instances.clearRetainingCapacity();
    self.scene_roots.clearRetainingCapacity();
    self.scene_now = .none;
    self.signals.clear();
    self.audio.clear();
    self.tweens.clear(self);
    self.drawings.clearAll(self.gpa);
    self.particles.clearAll(self.gpa);
    self.texts.clear(self.gpa);
    self.shader_params.clear(self.gpa);
    self.views.clear(&self.assets);
    self.animation_players.clear(self.gpa);
    // Last, in the new world: each script's `exit` finds its entity gone.
    if (self.scripts) |scripts| scripts.calls.clear(scripts);
}

/// Give back the names of everything that has died. Once a frame, after
/// `despawnOrphans`, for the same reason.
fn forgetDeadNames(self: *App) void {
    // Backwards, so the entry a swap-remove moves into the gap has already
    // been looked at.
    var at = self.names.count();
    while (at > 0) {
        at -= 1;
        const entity = self.names.keys()[at];
        if (!self.world.isAlive(entity)) self.forgetName(entity);
    }
}

// -------------------------------------------------------------------------
// Scripts
// -------------------------------------------------------------------------

/// Run Flux scripts. This makes the VM, with `app` and `self.entity` in it,
/// and lets scenes hold a `Script`. Call it once; a second call does
/// nothing. See `script`.
///
/// ```zig
/// try app.useScripts(.{ .budget = 1_000_000 });
/// const door = try app.loadScript("res://scripts/door.flux");
/// _ = try app.world.spawnWith(.{ fx.Transform2D.at(0, 0), fx.Script.of(door) });
/// ```
pub fn useScripts(self: *App, options: script_mod.Options) !void {
    if (self.scripts != null) return;
    try self.registerComponents(.{script_mod.Script});
    self.types.addAll(.{script_mod.ScriptHandle}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    self.scripts = try script_mod.Scripts.create(self, options);
}

/// Read a `.flux` file and compile it, or find the script already read from
/// it, named as `Project` names a file. A file that reads and does not
/// compile still gets a handle, and its reasons are in the log. A `Script`
/// holding it makes nothing until a reload compiles.
pub fn loadScript(self: *App, path: []const u8) !script_mod.ScriptHandle {
    const scripts = self.scripts orelse return error.ScriptsNotUsed;
    return scripts.load(path);
}

/// A script compiled from text rather than a file: a test's, or a tool's.
/// `name` is what the log and a scene call it. A name given before gets the
/// new text, as `setScriptText` gives it.
pub fn addScript(self: *App, name: []const u8, text: []const u8) !script_mod.ScriptHandle {
    const scripts = self.scripts orelse return error.ScriptsNotUsed;
    return scripts.add(name, text);
}

/// Read a script's file again and put the new code in while the game runs:
/// every instance keeps its fields and goes on with the new code. Says
/// whether there was a file to read. Text that does not compile leaves the
/// old code running, and the reasons are in the log. Not from inside a
/// script, which is `error.Busy`.
pub fn reloadScript(self: *App, handle: script_mod.ScriptHandle) !bool {
    const scripts = self.scripts orelse return false;
    return scripts.reload(handle);
}

/// New code for a script from text, not its file: an editor's unsaved
/// changes, run before they are saved. See `reloadScript`.
pub fn setScriptText(self: *App, handle: script_mod.ScriptHandle, text: []const u8) !void {
    const scripts = self.scripts orelse return error.ScriptsNotUsed;
    return scripts.setText(handle, text);
}

/// A script's compiled code, for a shipped game to load in place of its
/// text: see `Scripts.saveCompiled`. Needs `useScripts` with `run` off.
pub fn compiledScript(self: *App, handle: script_mod.ScriptHandle, gpa: Allocator, options: script_mod.flux.image.SaveOptions) ![]u8 {
    const scripts = self.scripts orelse return error.ScriptsNotUsed;
    return scripts.saveCompiled(handle, gpa, options);
}

/// The script read from `path`, if one was, spelt any way `Project` spells
/// it.
pub fn findScript(self: *App, path: []const u8) ?script_mod.ScriptHandle {
    const scripts = self.scripts orelse return null;
    const named = self.project.canonical(self.gpa, path) catch return scripts.find(path);
    defer self.gpa.free(named);
    return scripts.find(named);
}

/// Where a script was read from, or the name it was given; null for a
/// handle that has expired.
pub fn scriptSource(self: *App, handle: script_mod.ScriptHandle) ?[]const u8 {
    const scripts = self.scripts orelse return null;
    return scripts.sourceOf(handle);
}

/// The fields the struct of `entity`'s script marks `@export`, made or not,
/// as many as `found` holds: what an editor shows under the `Script`. None
/// for an entity with no script, or one whose script does not compile.
pub fn exportedFields(self: *App, entity: ecs.Entity, found: []script_mod.flux.FieldInfo) []script_mod.flux.FieldInfo {
    const scripts = self.scripts orelse return found[0..0];
    return scripts.calls.exportedFields(scripts, entity, found);
}

/// The same for the struct `struct_name` of `script` - empty for the one
/// named after its file: what an editor shows of a data file.
pub fn structFields(self: *App, script: script_mod.ScriptHandle, struct_name: []const u8, found: []script_mod.flux.FieldInfo) []script_mod.flux.FieldInfo {
    const scripts = self.scripts orelse return found[0..0];
    return scripts.calls.structFields(scripts, script, struct_name, found);
}

/// What an editor's language service needs to check and complete a game's
/// scripts as the game compiles them: `app` and `self.entity`. Hand it to
/// `flux.service`, with a loader for the files being edited. It needs no
/// `useScripts`.
pub fn scriptSetup(self: *App) script_mod.flux.service.Options {
    return script_mod.serviceOptions(self);
}

// -------------------------------------------------------------------------
// Files
// -------------------------------------------------------------------------
//
// What an editor does to a project's files, done so that nothing the engine
// holds is left pointing at the old place.

/// Whether `moveToTrash` has a trash to move things to on this system: the
/// Recycle Bin on Windows, the freedesktop.org trash on a Linux desktop -
/// with a fluxion-platform that has trash at all. The Linux one takes only
/// what is on the home folder's drive: anything else is `error.OtherDrive`.
/// A folder in `App.trash` stands in for either, on any system.
pub const trash_available = if (@hasDecl(platform, "trash")) platform.trash.available else false;

/// Move or rename a file or a folder, with its `.uid` file, and everything
/// read from it with it: a texture loaded from it stays loaded, kept by
/// where it is now, so the scene saved next names the new place - and every
/// scene that names it by its UUID finds it there. Never over something
/// already at `to`: that is `error.PathAlreadyExists`. See
/// `Project.moveFile`.
pub fn moveFile(self: *App, from: []const u8, to: []const u8) !void {
    const old = try self.project.canonical(self.gpa, from);
    defer self.gpa.free(old);
    const new = try self.project.canonical(self.gpa, to);
    defer self.gpa.free(new);
    try self.project.moveFile(old, new);
    try self.assets.renamed(old, new);
    try self.tile_sets.renamed(self.gpa, old, new);
    try self.scenes.renamed(self.gpa, old, new);
    try self.data_files.renamed(self.gpa, old, new);
    try self.audio.renamed(old, new);
    try self.animation_libraries.renamed(self.gpa, old, new);
    try self.sprite_frames.renamed(self.gpa, old, new);
    try self.shaders.renamed(self.gpa, old, new);
    try self.themes.renamed(self.gpa, old, new);
    if (self.scripts) |scripts| try scripts.renamed(old, new);
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
    if (comptime @hasDecl(platform, "trash")) {
        const io = self.io orelse return error.NoIo;
        const named = try self.project.canonical(self.gpa, path);
        defer self.gpa.free(named);
        const file = try self.project.osPath(self.gpa, named);
        defer self.gpa.free(file);
        const kept = try std.mem.concat(self.gpa, u8, &.{ file, Project.uid_extension });
        defer self.gpa.free(kept);

        try self.throwAway(io, file);
        // Its UUID after it, so a restore brings back both. The file has gone
        // either way, so a `.uid` file left behind is said, not undone.
        if (std.Io.Dir.cwd().access(io, kept, .{})) |_| {
            self.throwAway(io, kept) catch |err| log.warn("{s} is in the trash and its {s} file is not: {t}", .{ named, Project.uid_extension, err });
        } else |_| {}
        try self.project.forgetFile(named);
        return;
    }
    return error.Unsupported;
}

/// One file or folder, absolute, to `trash` when it is set and to the
/// system's otherwise.
fn throwAway(self: *App, io: std.Io, file: []const u8) !void {
    const bin = platform.trash;
    const folder = self.trash orelse return bin.move(self.gpa, io, file);
    // The time in UTC: a folder of one's own is for tests and tools, which
    // want it the same on every machine more than in the local hour.
    const seconds: u64 = @intCast(@max(0, std.Io.Timestamp.now(io, .real).toSeconds()));
    const at: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const date = at.getEpochDay().calculateYearDay();
    const day = date.calculateMonthDay();
    const time = at.getDaySeconds();
    return bin.freedesktop.move(self.gpa, io, file, folder, .{
        .year = date.year,
        .month = day.month.numeric(),
        .day = @as(u8, day.day_index) + 1,
        .hour = time.getHoursIntoDay(),
        .minute = time.getMinutesIntoHour(),
        .second = time.getSecondsIntoMinute(),
    });
}

// -------------------------------------------------------------------------
// Reflection
// -------------------------------------------------------------------------
//
// For code that was not compiled against the game: an editor's inspector
// walks a component's fields, a console calls the engine by name. Both go
// through fluxion-reflect's descriptors, and a component is found by the
// name a scene gives it.

/// One of an entity's components, as `componentsOf` lists them.
pub const ComponentValue = struct {
    /// What a scene calls it.
    name: []const u8,
    value: reflect.Value,
};

pub const ComponentError = error{
    /// No component is registered under that name. See `registerComponents`.
    NoSuchComponent,
    /// The entity has been despawned, or never was.
    NoSuchEntity,
} || ecs.World.Error;

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
    const entry = self.scene_components.find(name) orelse return null;
    return self.valueOf(entity, entry);
}

/// The component of type `t` on an entity, found as `componentOf` finds one
/// by name. A script's handle on a component looks itself up with this each
/// time the script uses it.
pub fn componentOfType(self: *App, entity: ecs.Entity, t: *const reflect.Type) ?reflect.Value {
    const entry = self.scene_components.findType(t) orelse return null;
    return self.valueOf(entity, entry);
}

/// Every registered component an entity has, in the order they were
/// registered - the engine's first - as many as `found` holds.
pub fn componentsOf(self: *App, entity: ecs.Entity, found: []ComponentValue) []ComponentValue {
    var count: usize = 0;
    for (self.scene_components.entries.items) |*entry| {
        if (count == found.len) break;
        const value = self.valueOf(entity, entry) orelse continue;
        found[count] = .{ .name = entry.name, .value = value };
        count += 1;
    }
    return found[0..count];
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

/// Put the component called `name` on an entity, holding its defaults, and
/// hand it back to fill in: an inspector's Add Component. One the entity has
/// already is handed back as it is. Not from inside a query, since it moves
/// the entity; `commands` is for that.
pub fn addComponentNamed(self: *App, entity: ecs.Entity, name: []const u8) ComponentError!reflect.Value {
    const entry = self.scene_components.find(name) orelse return error.NoSuchComponent;
    if (self.valueOf(entity, entry)) |held| return held;
    try entry.addTo(&self.world, entity);
    return self.valueOf(entity, entry).?;
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

fn valueOf(self: *App, entity: ecs.Entity, entry: *const scene.Registry.Entry) ?reflect.Value {
    const id = entry.findIdIn(&self.world) orelse return null;
    const cell = self.world.cellOf(entity, id) orelse return null;
    return .init(entry.type, cell);
}

// -------------------------------------------------------------------------
// Dates, times and the player's culture
// -------------------------------------------------------------------------

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
    if (self.culture_held) |held| return held;
    const tag = self.locale_chosen orelse if (self.project.settings) |settings| settings.internationalization.locale else "";
    const made = try datetime.Culture.open(self.gpa, tag);
    self.culture_held = made;
    return made;
}

/// Write dates and times as `tag` does from now on - `de-DE`, `ja-JP` - or,
/// for an empty one, as the player does.
pub fn setLocale(self: *App, tag: []const u8) Allocator.Error!void {
    const copy = try self.gpa.dupe(u8, tag);
    if (self.locale_chosen) |old| self.gpa.free(old);
    self.locale_chosen = copy;
    if (self.culture_held) |held| held.close();
    self.culture_held = null;
}

/// The tag of the culture the game writes in: `hu-HU`.
pub fn locale(self: *App) Allocator.Error![]const u8 {
    return (try self.culture()).tag;
}

/// A clock of the game's own, running at `options.rate` from
/// `options.start`. See `game_clocks.zig`.
pub fn newClock(self: *App, options: clocks_mod.Options) Allocator.Error!clocks_mod.ClockHandle {
    return self.clocks.add(self.gpa, options);
}

pub fn removeClock(self: *App, clock: clocks_mod.ClockHandle) void {
    self.clocks.remove(clock);
}

/// What the clock shows; null for one taken away.
pub fn clockTime(self: *App, clock: clocks_mod.ClockHandle) ?datetime.DateTime {
    const held = self.clocks.get(clock) orelse return null;
    return held.time();
}

/// Set the clock to show `time`'s fields, whatever its zone.
pub fn setClockTime(self: *App, clock: clocks_mod.ClockHandle, time: datetime.DateTime) void {
    const held = self.clocks.get(clock) orelse return;
    held.reading = time.wallMicroseconds();
    held.leftover = 0;
}

pub fn clockRate(self: *App, clock: clocks_mod.ClockHandle) f64 {
    const held = self.clocks.get(clock) orelse return 0;
    return held.rate;
}

/// Seconds of the clock a real second: 60 is a minute a second.
pub fn setClockRate(self: *App, clock: clocks_mod.ClockHandle, rate: f64) void {
    const held = self.clocks.get(clock) orelse return;
    held.rate = @max(rate, 0);
}

pub fn pauseClock(self: *App, clock: clocks_mod.ClockHandle) void {
    const held = self.clocks.get(clock) orelse return;
    held.paused = true;
}

pub fn resumeClock(self: *App, clock: clocks_mod.ClockHandle) void {
    const held = self.clocks.get(clock) orelse return;
    held.paused = false;
}

pub fn isClockPaused(self: *App, clock: clocks_mod.ClockHandle) bool {
    const held = self.clocks.get(clock) orelse return true;
    return held.paused;
}

/// The minutes, hours and days that turned over on the clock in the last
/// frame.
pub fn clockPassed(self: *App, clock: clocks_mod.ClockHandle) clocks_mod.Passed {
    const held = self.clocks.get(clock) orelse return .{};
    return held.passed;
}

/// Whether a clock runs this frame: as its owner does, or, with none, while
/// the game is not paused.
fn clockRuns(self: *App, owner: ?ecs.Entity) clocks_mod.Clocks.Runs {
    const entity = owner orelse return if (self.paused) .still else .runs;
    if (!self.world.isAlive(entity)) return .gone;
    return if (self.isProcessing(entity)) .runs else .still;
}

/// `App` as fluxion-reflect sees it: no insides, and the calls a console, a
/// script or an editor's command palette may make by name - see `callNamed`.
/// A call is listed when it takes and gives plain values: the ones taking a
/// type or a function, or holding an allocator, are for Zig to call. Only a
/// program that asks for this descriptor has them compiled in; see `types`.
pub const reflect_name = "App";
pub const reflect_opaque = true;
pub const reflect_methods = .{
    .quit = .{},
    .setName = .{attr.Params{ .names = &.{ "entity", "name" } }},
    .setFreeName = .{attr.Params{ .names = &.{ "entity", "name" } }},
    .nameOf = .{ attr.Params{ .names = &.{"entity"} }, script_mod.flux.Alias{ .name = "name" } },
    .find = .{attr.Params{ .names = &.{"name"} }},
    .setParent = .{attr.Params{ .names = &.{ "entity", "parent", "keep_global" } }},
    .parentOf = .{ attr.Params{ .names = &.{"entity"} }, script_mod.flux.Alias{ .name = "parent" } },
    .hangsFrom = .{attr.Params{ .names = &.{ "entity", "ancestor" } }},
    .childCount = .{attr.Params{ .names = &.{"parent"} }},
    .childAt = .{attr.Params{ .names = &.{ "parent", "index" } }},
    .children = .{attr.Params{ .names = &.{"parent"} }},
    .siblingIndex = .{attr.Params{ .names = &.{"entity"} }},
    .setSiblingIndex = .{attr.Params{ .names = &.{ "entity", "index" } }},
    .childNamed = .{attr.Params{ .names = &.{ "parent", "name" } }},
    .findPath = .{attr.Params{ .names = &.{ "from", "path" } }},
    .findIn = .{attr.Params{ .names = &.{ "root", "name" } }},
    .addToGroup = .{attr.Params{ .names = &.{ "entity", "group" } }},
    .removeFromGroup = .{attr.Params{ .names = &.{ "entity", "group" } }},
    .isInGroup = .{attr.Params{ .names = &.{ "entity", "group" } }},
    .groupMembers = .{attr.Params{ .names = &.{"group"} }},
    .callGroup = .{attr.Params{ .names = &.{ "group", "method" } }},
    .setPaused = .{attr.Params{ .names = &.{"paused"} }},
    .isPaused = .{},
    .isProcessing = .{attr.Params{ .names = &.{"entity"} }},
    .setVisible = .{attr.Params{ .names = &.{ "entity", "visible" } }},
    .isVisibleInTree = .{attr.Params{ .names = &.{"entity"} }},
    .clearWorld = .{},
    .stateNamed = .{attr.Params{ .names = &.{"state"} }},
    .setStateNamed = .{attr.Params{ .names = &.{ "state", "value" } }},
    .saveScene = .{ attr.Params{ .names = &.{ "path", "options" } }, script_mod.flux.GivesErrors{} },
    .readScene = .{ attr.Params{ .names = &.{ "path", "options" } }, script_mod.flux.GivesErrors{} },
    .loadInBackground = .{ attr.Params{ .names = &.{"path"} }, script_mod.flux.GivesErrors{} },
    .loadProgress = .{attr.Params{ .names = &.{"path"} }},
    .loadStatus = .{attr.Params{ .names = &.{"path"} }},
    .finishLoad = .{ attr.Params{ .names = &.{"path"} }, script_mod.flux.GivesErrors{} },
    .currentScene = .{},
    .currentSceneRoot = .{},
    .createTimer = .{attr.Params{ .names = &.{"seconds"} }},
    .randomFloat = .{},
    .randomRange = .{attr.Params{ .names = &.{ "low", "high" } }},
    .randomInt = .{attr.Params{ .names = &.{ "low", "high" } }},
    .randomChance = .{attr.Params{ .names = &.{"chance"} }},
    .randomIndex = .{attr.Params{ .names = &.{"count"} }},
    .seedRandom = .{attr.Params{ .names = &.{"seed"} }},
    .randomize = .{},
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
    .setInputAsHandled = .{},
    .bindAction = .{attr.Params{ .names = &.{ "name", "event" } }},
    .clearAction = .{attr.Params{ .names = &.{"name"} }},
    .spawn = .{ attr.Params{ .names = &.{"parent"} }, script_mod.flux.Alias{ .name = "spawnChild" } },
    .instantiate = .{attr.Params{ .names = &.{ "scene", "parent" } }},
    .changeScene = .{attr.Params{ .names = &.{"scene"} }},
    .reloadCurrentScene = .{},
    .readData = .{ attr.Params{ .names = &.{"path"} }, script_mod.flux.GivesErrors{} },
    .newSpriteFrames = .{},
    .loadSpriteFrames = .{ attr.Params{ .names = &.{"path"} }, script_mod.flux.GivesErrors{} },
    .saveSpriteFrames = .{ attr.Params{ .names = &.{ "frames", "path" } }, script_mod.flux.GivesErrors{} },
    .tween = .{attr.Params{ .names = &.{"owner"} }},
    .tweenProperty = .{attr.Params{ .names = &.{ "tween", "target", "property", "to", "seconds" } }},
    .tweenInterval = .{attr.Params{ .names = &.{ "tween", "seconds" } }},
    .tweenParallel = .{attr.Params{ .names = &.{ "tween", "together" } }},
    .tweenEase = .{attr.Params{ .names = &.{ "tween", "ease" } }},
    .animationNames = .{attr.Params{ .names = &.{"player"} }},
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
    .restartParticles = .{attr.Params{ .names = &.{"emitter"} }},
    .emitParticles = .{attr.Params{ .names = &.{ "emitter", "count" } }},
    .particleCount = .{attr.Params{ .names = &.{"emitter"} }},
    .hasAnimation = .{attr.Params{ .names = &.{ "player", "name" } }},
    .animationLength = .{attr.Params{ .names = &.{ "player", "name" } }},
    .tweenCallback = .{attr.Params{ .names = &.{ "tween", "function" } }},
    .tweenMethod = .{attr.Params{ .names = &.{ "tween", "function", "from", "to", "seconds" } }},
    .tweenFrom = .{attr.Params{ .names = &.{ "tween", "from" } }},
    .tweenRelative = .{attr.Params{ .names = &.{"tween"} }},
    .tweenDelay = .{attr.Params{ .names = &.{ "tween", "seconds" } }},
    .grabFocus = .{attr.Params{ .names = &.{"entity"} }},
    .hasFocus = .{attr.Params{ .names = &.{"entity"} }},
    .releaseFocus = .{},
    .controlRect = .{attr.Params{ .names = &.{"entity"} }},
    .setAnchorsPreset = .{attr.Params{ .names = &.{ "entity", "preset" } }},
    .audioLength = .{attr.Params{ .names = &.{"clip"} }},
    .setBusVolumeDb = .{attr.Params{ .names = &.{ "name", "db" } }},
    .busVolumeDb = .{attr.Params{ .names = &.{"name"} }},
    .setBusMute = .{attr.Params{ .names = &.{ "name", "mute" } }},
    .isBusMuted = .{attr.Params{ .names = &.{"name"} }},
    .linearToDb = .{attr.Params{ .names = &.{"linear"} }},
    .dbToLinear = .{attr.Params{ .names = &.{"db"} }},
    .nextFrame = .{script_mod.flux.Returns{ .builtin = .signal }},
    .callDeferred = .{attr.Params{ .names = &.{"function"} }},
    .keyDown = .{attr.Params{ .names = &.{"key"} }},
    .keyAxis = .{attr.Params{ .names = &.{ "negative", "positive" } }},
    .keyJustPressed = .{attr.Params{ .names = &.{"key"} }},
    .keyJustReleased = .{attr.Params{ .names = &.{"key"} }},
    .mouseButtonDown = .{attr.Params{ .names = &.{"button"} }},
    .mouseButtonJustPressed = .{attr.Params{ .names = &.{"button"} }},
    .mouseButtonJustReleased = .{attr.Params{ .names = &.{"button"} }},
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
    .connectedPads = .{},
    .padConnected = .{ attr.Params{ .names = &.{"pad"} }, attr.defaults(.{@as(?u8, null)}) },
    .padButtonDown = .{ attr.Params{ .names = &.{ "button", "pad" } }, attr.defaults(.{@as(?u8, null)}) },
    .padButtonJustPressed = .{ attr.Params{ .names = &.{ "button", "pad" } }, attr.defaults(.{@as(?u8, null)}) },
    .padButtonJustReleased = .{ attr.Params{ .names = &.{ "button", "pad" } }, attr.defaults(.{@as(?u8, null)}) },
    .padAxis = .{ attr.Params{ .names = &.{ "axis", "pad" } }, attr.defaults(.{@as(?u8, null)}) },
    .padStick = .{ attr.Params{ .names = &.{ "side", "pad" } }, attr.defaults(.{@as(?u8, null)}) },
    .actionDown = .{attr.Params{ .names = &.{"name"} }},
    .actionJustPressed = .{attr.Params{ .names = &.{"name"} }},
    .actionJustReleased = .{attr.Params{ .names = &.{"name"} }},
    .actionStrength = .{attr.Params{ .names = &.{"name"} }},
    .actionAxis = .{attr.Params{ .names = &.{ "negative", "positive" } }},
    .actionVector = .{attr.Params{ .names = &.{ "left", "right", "up", "down" } }},
    .pressAction = .{attr.Params{ .names = &.{ "name", "strength" } }},
    .releaseAction = .{attr.Params{ .names = &.{"name"} }},
    .describeAction = .{attr.Params{ .names = &.{"name"} }},
    .saveInputMap = .{ attr.Params{ .names = &.{"path"} }, script_mod.flux.GivesErrors{} },
    .loadInputMap = .{ attr.Params{ .names = &.{"path"} }, script_mod.flux.GivesErrors{} },
    .isOnFloor = .{attr.Params{ .names = &.{ "entity", "distance" } }},
    .moveAndSlide = .{attr.Params{ .names = &.{"entity"} }},
    .moveAndCollide = .{attr.Params{ .names = &.{ "entity", "motion" } }},
    .slideCollisionCount = .{attr.Params{ .names = &.{"entity"} }},
    .slideCollision = .{attr.Params{ .names = &.{ "entity", "index" } }},
    .lastSlideCollision = .{attr.Params{ .names = &.{"entity"} }},
    .castRay = .{ attr.Params{ .names = &.{ "from", "to", "mask", "hit_areas" } }, attr.defaults(.{ @as(u32, 0xFFFF_FFFF), false }) },
    .forceRaycastUpdate = .{attr.Params{ .names = &.{"entity"} }},
    .applyImpulse = .{ attr.Params{ .names = &.{ "body", "impulse", "offset" } }, attr.defaults(.{math.Vec2.zero}) },
    .applyForce = .{ attr.Params{ .names = &.{ "body", "force", "offset" } }, attr.defaults(.{math.Vec2.zero}) },
    .applyTorque = .{attr.Params{ .names = &.{ "body", "torque" } }},
    .applyTorqueImpulse = .{attr.Params{ .names = &.{ "body", "impulse" } }},
    .overlappingBodies = .{attr.Params{ .names = &.{"area"} }},
    .overlappingAreas = .{attr.Params{ .names = &.{"area"} }},
    .hasOverlappingBodies = .{attr.Params{ .names = &.{"area"} }},
    .hasOverlappingAreas = .{attr.Params{ .names = &.{"area"} }},
    .overlapsBody = .{attr.Params{ .names = &.{ "area", "body" } }},
    .overlapsArea = .{attr.Params{ .names = &.{ "area", "other" } }},
    .cellAt = .{attr.Params{ .names = &.{ "map", "point" } }},
    .tileData = .{attr.Params{ .names = &.{ "map", "x", "y", "layer" } }},
    .tileDataAt = .{attr.Params{ .names = &.{ "map", "point", "layer" } }},
    .screenToWorld = .{attr.Params{ .names = &.{ "x", "y" } }},
    .worldToScreen = .{attr.Params{ .names = &.{ "x", "y" } }},
    .pointerInWorld = .{},
    .pointerOnScreen = .{},
    .screenCenter = .{attr.Params{ .names = &.{"camera"} }},
    .resetSmoothing = .{attr.Params{ .names = &.{"camera"} }},
    .warpPointer = .{attr.Params{ .names = &.{ "x", "y" } }},
    .screenSize = .{},
    .overlapPoint = .{attr.Params{ .names = &.{"point"} }},
    .addCollisionExceptionWith = .{attr.Params{ .names = &.{ "entity", "other" } }},
    .removeCollisionExceptionWith = .{attr.Params{ .names = &.{ "entity", "other" } }},
    .setWindowMode = .{ attr.Params{ .names = &.{"mode"} }, script_mod.flux.GivesErrors{} },
    .windowMode = .{},
    .toggleFullscreen = .{script_mod.flux.GivesErrors{}},
    .setVideoMode = .{ attr.Params{ .names = &.{"mode"} }, script_mod.flux.GivesErrors{} },
    .setWindowBorderless = .{ attr.Params{ .names = &.{"borderless"} }, script_mod.flux.GivesErrors{} },
    .windowBorderless = .{},
    .setWindowResizable = .{ attr.Params{ .names = &.{"resizable"} }, script_mod.flux.GivesErrors{} },
    .windowResizable = .{},
    .setWindowAlwaysOnTop = .{ attr.Params{ .names = &.{"on_top"} }, script_mod.flux.GivesErrors{} },
    .windowAlwaysOnTop = .{},
    .setKeepScreenOn = .{ attr.Params{ .names = &.{"on"} }, script_mod.flux.GivesErrors{} },
    .keepScreenOn = .{},
    .screenCount = .{},
    .windowScreen = .{},
    .primaryScreen = .{},
    .setWindowScreen = .{ attr.Params{ .names = &.{"screen"} }, script_mod.flux.GivesErrors{} },
    .centerWindow = .{script_mod.flux.GivesErrors{}},
    .screenRect = .{attr.Params{ .names = &.{"screen"} }},
    .screenUsableRect = .{attr.Params{ .names = &.{"screen"} }},
    .screenScale = .{attr.Params{ .names = &.{"screen"} }},
    .screenRefreshRate = .{attr.Params{ .names = &.{"screen"} }},
    .videoModeCount = .{attr.Params{ .names = &.{"screen"} }},
    .videoMode = .{attr.Params{ .names = &.{ "screen", "index" } }},
    .closeRequested = .{},
    .gameVersion = .{},
    .osName = .{},
    .isDebugBuild = .{},
    .setWindowTitle = .{ attr.Params{ .names = &.{"title"} }, script_mod.flux.GivesErrors{} },
    .setWindowSize = .{ attr.Params{ .names = &.{ "width", "height" } }, script_mod.flux.GivesErrors{} },
    .windowSize = .{},
    .setWindowPosition = .{ attr.Params{ .names = &.{ "x", "y" } }, script_mod.flux.GivesErrors{} },
    .windowPosition = .{},
    .setVsyncMode = .{ attr.Params{ .names = &.{"mode"} }, script_mod.flux.GivesErrors{} },
    .vsyncMode = .{},
    .setStretchMode = .{attr.Params{ .names = &.{"mode"} }},
    .stretchMode = .{},
    .setStretchAspect = .{attr.Params{ .names = &.{"aspect"} }},
    .stretchAspect = .{},
    .setStretchScale = .{attr.Params{ .names = &.{"scale"} }},
    .stretchScale = .{},
    .setStretchScaleMode = .{attr.Params{ .names = &.{"mode"} }},
    .stretchScaleMode = .{},
    .setMaxPhysicsStepsPerFrame = .{attr.Params{ .names = &.{"steps"} }},
    .maxPhysicsStepsPerFrame = .{},
    .setPhysicsTicksPerSecond = .{attr.Params{ .names = &.{"ticks"} }},
    .physicsTicksPerSecond = .{},
    .rendererInUse = .{},
    .backendInUse = .{},
    .setMaxFps = .{attr.Params{ .names = &.{"fps"} }},
    .maxFps = .{},
    .setBackgroundFps = .{attr.Params{ .names = &.{"fps"} }},
    .backgroundFps = .{},
    .inForeground = .{},
    .fps = .{},
    .frameCount = .{},
    .elapsed = .{},
    .setTimeScale = .{attr.Params{ .names = &.{"scale"} }},
    .timeScale = .{},
    .setInterfaceZoom = .{attr.Params{ .names = &.{"zoom"} }},
    .interfaceZoom = .{},
    .setCursor = .{ attr.Params{ .names = &.{"mode"} }, script_mod.flux.GivesErrors{} },
    .cursor = .{},
    .setCustomCursor = .{ attr.Params{ .names = &.{ "image", "shape", "hotspot" } }, attr.defaults(.{ CursorShape.arrow, math.Vec2.init(0, 0) }), script_mod.flux.GivesErrors{} },
    .setDefaultCursorShape = .{attr.Params{ .names = &.{"shape"} }},
    .defaultCursorShape = .{},
    .currentCursorShape = .{},
    .setClipboardText = .{ attr.Params{ .names = &.{"text"} }, script_mod.flux.GivesErrors{} },
    .clipboardText = .{script_mod.flux.GivesErrors{}},
    .hasClipboardText = .{},
    .openUrl = .{ attr.Params{ .names = &.{"url"} }, script_mod.flux.GivesErrors{} },
};

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
    return callValue(.of(self), name, args, result);
}

/// Call a method of `receiver`'s type by name, its error coming back as one.
fn callValue(receiver: reflect.Value, name: []const u8, args: []const reflect.Value, result: ?reflect.Value) anyerror!void {
    const method = receiver.type.method(name) orelse return error.NoSuchMethod;
    const returns = method.type.info.function.return_type;
    if (returns.kind != .error_union) return receiver.call(name, args, result);

    // Taken whole - error or value - so that an error comes back as one,
    // rather than going into `result` or nowhere.
    var held: [128]u8 align(16) = undefined;
    if (returns.size > held.len or returns.alignment > 16) return error.Unsupported;
    const returned: reflect.Value = .init(returns, &held);
    try receiver.call(name, args, returned);
    const code = returns.info.error_union.ops.code(&held);
    if (code != 0) return @errorFromInt(@as(std.meta.Int(.unsigned, @bitSizeOf(anyerror)), @intCast(code)));
    if (result) |into| try into.convertFrom(returned.unwrap().?);
}

// -------------------------------------------------------------------------
// Signals and events
// -------------------------------------------------------------------------
//
// Signals, on components, and the typed events the engine's own are made
// from. See `signals.zig` and `event_channels.zig`.

pub const Signal = signals_mod.Signal;

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
pub fn emit(self: *App, entity: ecs.Entity, comptime C: type, comptime name: @EnumLiteral(), args: @field(C.signals, @tagName(name))) signals_mod.Error!void {
    return self.signal(entity, C, name).emit(args);
}

/// A signal of `entity` by the name one of its components declares it
/// under - `hit`, or `Health.hit` when two of them declare `hit` - for what
/// was not compiled against the game: an editor, a console, a scene.
pub fn signalNamed(self: *App, entity: ecs.Entity, name: []const u8) signals_mod.Error!Signal {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        if (std.mem.eql(u8, name[0..dot], script_mod.component_name)) {
            return self.scriptSignal(entity, name[dot + 1 ..]) orelse error.NoSuchSignal;
        }
        const entry = self.scene_components.find(name[0..dot]) orelse return error.NoSuchSignal;
        if (self.valueOf(entity, entry) == null) return error.NoSuchSignal;
        for (entry.signals) |decl| {
            if (std.mem.eql(u8, decl.name, name[dot + 1 ..])) return .{ .app = self, .source = entity, .component = entry.name, .name = decl.name };
        }
        return error.NoSuchSignal;
    }
    var found: ?Signal = null;
    var held: [64]ComponentValue = undefined;
    for (self.componentsOf(entity, &held)) |component| {
        const entry = self.scene_components.find(component.name) orelse continue;
        for (entry.signals) |decl| {
            if (!std.mem.eql(u8, decl.name, name)) continue;
            if (found != null) return error.AmbiguousSignal;
            found = .{ .app = self, .source = entity, .component = entry.name, .name = decl.name };
        }
    }
    if (self.scriptSignal(entity, name)) |declared| {
        if (found != null) return error.AmbiguousSignal;
        found = declared;
    }
    return found orelse error.NoSuchSignal;
}

/// The signal `name` the entity's script declares, if it has a script that
/// does.
fn scriptSignal(self: *App, entity: ecs.Entity, name: []const u8) ?Signal {
    const scripts = self.scripts orelse return null;
    var found: [64]signals_mod.Info = undefined;
    for (scripts.calls.signals(scripts, entity, &found)) |info| {
        if (std.mem.eql(u8, info.name, name)) return .{ .app = self, .source = entity, .component = script_mod.component_name, .name = info.name };
    }
    return null;
}

/// `signalNamed`, emitted with values: what a console or a script emits.
pub fn emitNamed(self: *App, entity: ecs.Entity, name: []const u8, values: []const reflect.Value) signals_mod.Error!void {
    return (try self.signalNamed(entity, name)).emitValues(values);
}

/// Whether one of `entity`'s components declares a signal by that name.
pub fn hasSignal(self: *App, entity: ecs.Entity, name: []const u8) bool {
    _ = self.signalNamed(entity, name) catch |err| return err == error.AmbiguousSignal;
    return true;
}

/// Every signal `entity` has, component by component in the order they
/// were registered - its script's where `Script` is - as many as `found`
/// holds.
pub fn signalsOf(self: *App, entity: ecs.Entity, found: []signals_mod.Info) []signals_mod.Info {
    var count: usize = 0;
    var held: [64]ComponentValue = undefined;
    for (self.componentsOf(entity, &held)) |component| {
        if (std.mem.eql(u8, component.name, script_mod.component_name)) {
            if (self.scripts) |scripts| count += scripts.calls.signals(scripts, entity, found[count..]).len;
            continue;
        }
        const entry = self.scene_components.find(component.name) orelse continue;
        for (entry.signals) |decl| {
            if (count == found.len) return found[0..count];
            found[count] = .{ .component = entry.name, .name = decl.name, .args = decl.args };
            count += 1;
        }
    }
    return found[0..count];
}

/// The signals the component a scene calls `name` declares, whether any
/// entity has it or not: what an editor lists before one is added.
pub fn signalsOfComponent(self: *App, name: []const u8, found: []signals_mod.Info) []signals_mod.Info {
    const entry = self.scene_components.find(name) orelse return found[0..0];
    const count = @min(found.len, entry.signals.len);
    for (entry.signals[0..count], found[0..count]) |decl, *into| {
        into.* = .{ .component = entry.name, .name = decl.name, .args = decl.args };
    }
    return found[0..count];
}

/// Connect to a signal of `source` by name, whether this build knows it or
/// not: one no component declares is kept, saved and listed as written,
/// and never heard - how a scene or an editor holds a game's connections
/// without the game's components. A bare name two components declare is
/// `error.AmbiguousSignal`: name one.
pub fn connectNamed(self: *App, source: ecs.Entity, name: []const u8, callable: signals_mod.Callable, options: signals_mod.Options) signals_mod.Error!void {
    const known = self.signalNamed(source, name) catch |err| switch (err) {
        error.NoSuchSignal => return self.signals.connect(source, .{ .name = name }, callable, options),
        else => return err,
    };
    return known.connect(callable, options);
}

/// Take away a connection `connectNamed` could have made, by the name a
/// listing gives it.
pub fn disconnectNamed(self: *App, source: ecs.Entity, name: []const u8, callable: signals_mod.Callable) void {
    if (self.signalNamed(source, name)) |known| {
        if (self.signals.disconnect(source, known.key(), callable)) return;
    } else |_| {}
    // Kept as written: one this build did not know when it was made.
    _ = self.signals.disconnect(source, .{ .name = name }, callable);
}

/// Every connection of `source`'s signals, known or not, in the order they
/// were made: the order they are heard in, and the order a scene keeps and
/// reads back. A disconnect and a connect again puts one last.
pub fn connectionsFrom(self: *App, source: ecs.Entity, found: []signals_mod.Connection) []signals_mod.Connection {
    const listed = self.signals.connectionsFrom(source, found);
    for (listed) |*c| c.signal = self.signalWritten(c.*);
    return listed;
}

/// Every connection to a method of `receiver`.
pub fn connectionsTo(self: *App, receiver: ecs.Entity, found: []signals_mod.Connection) []signals_mod.Connection {
    const listed = self.signals.connectionsTo(receiver, found);
    for (listed) |*c| c.signal = self.signalWritten(c.*);
    return listed;
}

/// How many connections `source`'s signals have, known or not, with no
/// list to fill: what a hierarchy's signal icon asks.
pub fn connectionCount(self: *const App, source: ecs.Entity) usize {
    const list = self.signals.from.getPtr(source) orelse return 0;
    return list.items.len;
}

/// Whether `entity`'s emits do nothing.
pub fn setBlockSignals(self: *App, entity: ecs.Entity, on: bool) Allocator.Error!void {
    if (on) try self.signals.blocked.put(self.gpa, entity, {}) else _ = self.signals.blocked.remove(entity);
}

pub fn isBlockingSignals(self: *const App, entity: ecs.Entity) bool {
    return self.signals.blocked.contains(entity);
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
    const entry = try self.signals.methods.getOrPut(self.gpa, name);
    if (!entry.found_existing) {
        entry.key_ptr.* = self.gpa.dupe(u8, name) catch |err| {
            self.signals.methods.removeByPtr(entry.key_ptr);
            return err;
        };
    }
    entry.value_ptr.* = signals_mod.registered(f);
}

/// Every method a connection to `receiver` can name, with what each takes:
/// its components' `reflect_methods`, then what the game gave `addMethod`
/// by name, as many as `found` holds. What an editor's method picker lists,
/// and filters by a signal's arguments. `Entity.none` lists the game's own
/// alone.
pub fn methodsOf(self: *App, receiver: ecs.Entity, found: []signals_mod.MethodInfo) []signals_mod.MethodInfo {
    var count: usize = 0;
    var held: [64]ComponentValue = undefined;
    for (self.componentsOf(receiver, &held)) |component| {
        if (std.mem.eql(u8, component.name, script_mod.component_name)) {
            if (self.scripts) |scripts| count += scripts.calls.methods(scripts, receiver, found[count..]).len;
            continue;
        }
        for (component.value.type.methods.slice()) |*m| {
            if (count == found.len) return found[0..count];
            // The first is the component itself.
            const params = m.type.info.function.params.slice();
            found[count] = .{ .component = component.name, .name = m.name.slice(), .params = params[@min(1, params.len)..] };
            count += 1;
        }
    }
    const own = count;
    var it = self.signals.methods.iterator();
    while (it.next()) |entry| {
        if (count == found.len) break;
        found[count] = .{ .component = "", .name = entry.key_ptr.*, .params = entry.value_ptr.params };
        count += 1;
    }
    std.mem.sort(signals_mod.MethodInfo, found[own..count], {}, struct {
        fn less(_: void, a: signals_mod.MethodInfo, b: signals_mod.MethodInfo) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    return found[0..count];
}

/// Call the method a connection names, on `receiver`: a method one of its
/// components lists in `reflect_methods` - `Text2D.set` names the one -
/// or its script declares - `Script.hit` - else one given to `addMethod`.
pub fn callMethodOn(self: *App, receiver: ecs.Entity, name: []const u8, args: []const reflect.Value) anyerror!void {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    const component: ?[]const u8 = if (dot) |at| name[0..at] else null;
    const method = if (dot) |at| name[at + 1 ..] else name;

    var owner: ?reflect.Value = null;
    var scripted = false;
    var held: [64]ComponentValue = undefined;
    for (self.componentsOf(receiver, &held)) |found| {
        if (component) |wanted| {
            if (!std.mem.eql(u8, found.name, wanted)) continue;
        }
        const has = if (std.mem.eql(u8, found.name, script_mod.component_name))
            self.scriptHasMethod(receiver, method)
        else
            found.value.type.method(method) != null;
        if (!has) continue;
        if (owner != null or scripted) return error.AmbiguousMethod;
        if (std.mem.eql(u8, found.name, script_mod.component_name)) scripted = true else owner = found.value;
    }
    if (owner) |value| return callValue(value, method, args, null);
    if (scripted) {
        const scripts = self.scripts.?;
        return scripts.calls.callMethod(scripts, receiver, method, args);
    }
    if (component == null) {
        if (self.signals.methods.get(name)) |m| return m.call(self, receiver, args);
    }
    return error.NoSuchMethod;
}

/// Whether a connection naming `name` would find a method on `receiver`:
/// one of its components', its script's, or one given to `addMethod`.
pub fn hasMethod(self: *App, receiver: ecs.Entity, name: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    const method = if (dot) |at| name[at + 1 ..] else name;
    var held: [64]ComponentValue = undefined;
    for (self.componentsOf(receiver, &held)) |found| {
        if (dot) |at| {
            if (!std.mem.eql(u8, found.name, name[0..at])) continue;
        }
        if (std.mem.eql(u8, found.name, script_mod.component_name)) {
            if (self.scriptHasMethod(receiver, method)) return true;
            continue;
        }
        if (found.value.type.method(method) != null) return true;
    }
    return dot == null and self.signals.methods.contains(name);
}

fn scriptHasMethod(self: *App, entity: ecs.Entity, name: []const u8) bool {
    const scripts = self.scripts orelse return false;
    return scripts.calls.hasMethod(scripts, entity, name);
}

/// A connection's signal as the listings give it and a scene writes it: the
/// bare name, unless another of the source's components declares the same
/// name or the source has not got the one that declares it; and one this
/// build did not know when it was made, as it was written.
pub fn signalWritten(self: *App, c: signals_mod.Connection) []const u8 {
    if (!c.known) return c.signal;
    const dot = std.mem.lastIndexOfScalar(u8, c.signal, '.') orelse return c.signal;
    const component = c.signal[0..dot];
    const name = c.signal[dot + 1 ..];
    if (self.componentOf(c.source, component) == null) return c.signal;
    var held: [64]ComponentValue = undefined;
    for (self.componentsOf(c.source, &held)) |found| {
        if (std.mem.eql(u8, found.name, component)) continue;
        if (std.mem.eql(u8, found.name, script_mod.component_name)) {
            if (self.scriptSignal(c.source, name) != null) return c.signal;
            continue;
        }
        const entry = self.scene_components.find(found.name) orelse continue;
        for (entry.signals) |decl| {
            if (std.mem.eql(u8, decl.name, name)) return c.signal;
        }
    }
    return name;
}

/// Send an event: every reader of its type sees it once, this frame or the
/// next. Safe anywhere, a query's loop included. See `events`.
///
/// ```zig
/// try app.send(Damage{ .to = player, .amount = 5 });
/// ```
pub fn send(self: *App, event: anytype) Allocator.Error!void {
    const channel = try self.channelOf(@TypeOf(event));
    try channel.send(self.gpa, event);
}

/// The events of one type, this frame's and last frame's, for a reader to
/// read. None when nothing ever sent one.
pub fn events(self: *App, comptime T: type) *const events_mod.Events(T) {
    const found = self.event_channels.get(typeKey(T)) orelse return &events_mod.Events(T).empty;
    return @ptrCast(@alignCast(found.events));
}

fn channelOf(self: *App, comptime T: type) Allocator.Error!*events_mod.Events(T) {
    const entry = try self.event_channels.getOrPut(self.gpa, typeKey(T));
    if (entry.found_existing) return @ptrCast(@alignCast(entry.value_ptr.events));
    const made = self.gpa.create(events_mod.Events(T)) catch |err| {
        self.event_channels.swapRemoveAt(entry.index);
        return err;
    };
    made.* = .{};
    entry.value_ptr.* = .of(T, made);
    return made;
}

/// One type's events, with what the frame and the end do to them.
const EventChannel = struct {
    events: *anyopaque,
    update: *const fn (events: *anyopaque) void,
    deinit: *const fn (events: *anyopaque, gpa: Allocator) void,

    fn of(comptime T: type, made: *events_mod.Events(T)) EventChannel {
        const Shim = struct {
            fn update(p: *anyopaque) void {
                const held: *events_mod.Events(T) = @ptrCast(@alignCast(p));
                held.update();
            }
            fn deinit(p: *anyopaque, gpa: Allocator) void {
                const held: *events_mod.Events(T) = @ptrCast(@alignCast(p));
                held.deinit(gpa);
                gpa.destroy(held);
            }
        };
        return .{ .events = made, .update = Shim.update, .deinit = Shim.deinit };
    }
};

/// A number for each type, the same for as long as the program runs: the
/// address of a variable only that type's instance of this has.
fn typeKey(comptime T: type) usize {
    return @intFromPtr(&struct {
        var marker: ?*const T = null;
    }.marker);
}

// -------------------------------------------------------------------------
// The screen and the world
// -------------------------------------------------------------------------

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

/// Open a regular Fluxion UI element over a point in the 2D world. Call it
/// from a `.ui` system and close it like `ui.open`.
pub fn openWorldUi(
    self: *App,
    point: math.Vec2,
    declaration: ui_lib.Declaration,
    placement: world_ui.Placement,
) void {
    const screen = self.worldToScreen(point.x, point.y);
    const scale = if (self.interface.scale > 0) self.interface.scale else 1;
    var placed = declaration;
    placed.floating = .{
        .attach = .root,
        .anchor = .{
            .element_x = placement.anchor_x,
            .element_y = placement.anchor_y,
        },
        .offset = .{
            .x = screen.x / scale + placement.offset.x,
            .y = screen.y / scale + placement.offset.y,
        },
        .z_index = placement.z_index,
        .clip = placement.clip,
    };
    self.ui.open(placed);
}

/// Draw the scene's `Control` trees every frame. Calling it again does
/// nothing, so a reusable game module may safely ask for it too.
pub fn useControlNodes(self: *App) !void {
    try self.control_nodes.enable(self);
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

/// A new entity, with nothing on it, hanging from `parent` - or a root, for
/// none. What a script makes things with: `self.entity.spawnChild()`, or
/// `app.spawn(null)` for a root, then `add(Sprite)`.
pub fn spawn(self: *App, parent: ecs.Entity) !ecs.Entity {
    const made = try self.world.spawn();
    errdefer self.world.despawn(made);
    if (!parent.isNone()) try self.setParent(made, parent, false);
    return made;
}

/// Take the event a script's `input` or `unhandled_input` is handling: the
/// scripts after it do not hear it, nor does any `unhandled_input`.
pub fn setInputAsHandled(self: *App) void {
    if (self.scripts) |scripts| scripts.input_handled = true;
    // And from an object's `input_event`, the objects under it do not hear
    // it either.
    self.picking.taken = true;
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

/// What a script awaits for the next frame: `await app.nextFrame()`. Null
/// in a game with no scripts.
pub fn nextFrame(self: *App) script_mod.flux.Value {
    const scripts = self.scripts orelse return .null;
    return scripts.calls.nextFrame(scripts);
}

/// Call a script's function at the end of this frame, after its systems and
/// signals: `app.callDeferred(self.respawn)`.
pub fn callDeferred(self: *App, callable: script_mod.flux.Value) !void {
    const scripts = self.scripts orelse return error.NoScripts;
    return scripts.calls.callDeferred(scripts, callable);
}

/// Whether a key is held: `app.keyDown(.w)`.
pub fn keyDown(self: *const App, key: platform.Key) bool {
    return self.input.isDown(key);
}

/// -1, 0 or 1 from two keys: `app.keyAxis(.a, .d)`.
pub fn keyAxis(self: *const App, negative: platform.Key, positive: platform.Key) f32 {
    var value: f32 = 0;
    if (self.keyDown(negative)) value -= 1;
    if (self.keyDown(positive)) value += 1;
    return value;
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
    return self.input.two_fingers;
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

/// One controller slot, or every connected controller for null.
fn padOf(self: *const App, pad: ?u8) Input.Pad {
    return if (pad) |slot| self.input.pad(slot) else self.input.anyPad();
}

/// The controller slots something is plugged into, from nought: for a game
/// with a player to each.
pub fn connectedPads(self: *App) []const u8 {
    var count: usize = 0;
    for (self.input.pads, 0..) |held, slot| {
        if (!held.connected) continue;
        self.connected_pads[count] = @intCast(slot);
        count += 1;
    }
    return self.connected_pads[0..count];
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

/// Move a `CharacterBody2D` by its velocity for this step - `time.delta` -
/// stopping at what it meets and sliding along it, and say what it stands
/// on and is against in its fields after. Whether anything stopped it. See
/// `character.zig`.
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
    const met = self.slide_collisions.get(entity) orelse return 0;
    return @intCast(met.items.len);
}

/// The one it met `index`th, in order; null past the end. What a character
/// pushes a crate by: `app.slideCollision(player, 0).?.collider`.
pub fn slideCollision(self: *const App, entity: ecs.Entity, index: u32) ?character.Collision {
    const met = self.slide_collisions.get(entity) orelse return null;
    return if (index < met.items.len) met.items[index] else null;
}

/// The last it met, or null for none.
pub fn lastSlideCollision(self: *const App, entity: ecs.Entity) ?character.Collision {
    const met = self.slide_collisions.get(entity) orelse return null;
    return met.getLastOrNull();
}

/// Forget the slides of the dead, at the end of the frame.
fn forgetDeadSlides(self: *App) void {
    var at = self.slide_collisions.count();
    while (at > 0) {
        at -= 1;
        if (self.world.isAlive(self.slide_collisions.keys()[at])) continue;
        self.slide_collisions.values()[at].deinit(self.gpa);
        self.slide_collisions.swapRemoveAt(at);
    }
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
    // A character knows: its last move said.
    if (self.world.get(entity, components.CharacterBody2D)) |held| return held.on_floor;
    const collider = self.world.get(entity, components.Collider2D) orelse return false;
    const box = self.bodies.boundsOf(self, entity) orelse return false;
    const settings = self.physics.settings;
    const sunk = 4 * settings.linear_slop * settings.units_per_metre;
    const inside = @min(sunk, (box.max.y - box.min.y) / 2);
    const own = self.bodies.idOf(entity);
    const filter: physics_lib.Filter = .{ .category = collider.collision_layer, .mask = collider.collision_mask };
    for ([_]f32{ 0.5, 0.1, 0.9 }) |along| {
        const x = box.min.x + (box.max.x - box.min.x) * along;
        const hit = self.bodies.castRay(self, .init(x, box.max.y - inside), .init(x, box.max.y + @max(distance, 0)), .{ .filter = filter }) orelse continue;
        // Another collider of the same body is not a floor.
        if (hit.shape.eql(entity) or std.meta.eql(self.bodies.idOf(hit.shape), own)) continue;
        if (hit.normal.y < -0.5) return true;
    }
    return false;
}

/// Where an entity's sprite is drawn, as its four corners in the world, round
/// from the texture's top left - turned, scaled and carried by its parents
/// as the renderer does it. Null for an entity with no sprite, or none that
/// can be placed. What a click on a sprite is tested against.
pub fn spriteCorners(self: *App, entity: ecs.Entity) ?[4]math.Vec2 {
    const drawn = (self.world.get(entity, components.Sprite) orelse return null).*;
    const placed = self.drawnTransform(entity) orelse return null;
    const shown = self.views.shown(&self.world, entity, drawn.texture);
    const texture = self.assets.get(shown) orelse self.assets.get(self.assets.white) orelse return null;
    return sprite.cornersOf(drawn, placed, texture);
}

/// Where an entity's label is drawn, as its four corners in the world, round
/// from the top left of its first line - turned, scaled and carried by its
/// parents as the renderer does it. The box its lines are laid out in, not
/// the ink. Null for an entity with no `Text2D`, one with nothing to draw,
/// or one that cannot be placed.
pub fn textCorners(self: *App, entity: ecs.Entity) ?[4]math.Vec2 {
    const label = (self.world.get(entity, components.Text2D) orelse return null).*;
    const placed = self.drawnTransform(entity) orelse return null;
    const face = self.assets.fontOf(label.font) orelse return null;
    return sprite.labelCornersOf(label, self.textOf(entity, components.Text2D, "text"), placed, face);
}

// -------------------------------------------------------------------------
// Texts
// -------------------------------------------------------------------------

/// What `C`'s text `property` says on `entity`: empty for nothing, or for an
/// entity without it. A component keeps its words beside it, as long as
/// they are - see `component_texts.zig`. The text lasts until it is set again.
///
/// ```zig
/// const said = app.textOf(label, fx.Label, "text");
/// ```
pub fn textOf(self: *const App, entity: ecs.Entity, comptime C: type, comptime property: []const u8) []const u8 {
    return self.texts.get(entity, comptime texts_mod.keyFor(C, property));
}

/// Say `text` in `C`'s text `property` on `entity`. `C` has to keep a text of
/// that name - the build says so - and the entity has to be alive.
///
/// ```zig
/// try app.setText(title, fx.Label, "text", "Paused");
/// ```
pub fn setText(self: *App, entity: ecs.Entity, comptime C: type, comptime property: []const u8, text: []const u8) !void {
    if (!self.world.isAlive(entity)) return error.NoSuchEntity;
    try self.texts.set(self.gpa, entity, comptime texts_mod.keyFor(C, property), text);
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

/// Give the keyboard's and a pad's focus to a control: a menu's first
/// button as it opens. From Flux too.
pub fn grabFocus(self: *App, entity: ecs.Entity) void {
    var buffer: [48]u8 = undefined;
    self.ui.setFocus(control.focusIdOf(self, &buffer, entity));
}

/// Whether a control has the focus.
pub fn hasFocus(self: *App, entity: ecs.Entity) bool {
    var buffer: [48]u8 = undefined;
    return self.ui.isFocused(control.focusIdOf(self, &buffer, entity));
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
    var id: [48]u8 = undefined;
    const box = self.ui.boxOf(control.idOf(&id, entity)) orelse return null;
    const scale = if (self.interface.scale > 0) self.interface.scale else 1;
    return .init(box.x / scale, box.y / scale, box.width / scale, box.height / scale);
}

/// Anchor a control where `preset` says: see `Control.setAnchorsPreset`.
pub fn setAnchorsPreset(self: *App, entity: ecs.Entity, preset: control.Control.AnchorsPreset) !void {
    const held = self.world.get(entity, control.Control) orelse return error.NoSuchComponent;
    held.setAnchorsPreset(preset);
}

/// `textOf` by names, for what knows a component only by the name a scene
/// gives it: an editor, a script.
pub fn textNamed(self: *const App, entity: ecs.Entity, component: []const u8, property: []const u8) []const u8 {
    return self.texts.get(entity, texts_mod.keyOf(component, property));
}

/// `setText` by names. The component has to be registered and keep a text
/// of that name.
pub fn setTextNamed(self: *App, entity: ecs.Entity, component: []const u8, property: []const u8, text: []const u8) !void {
    if (!self.world.isAlive(entity)) return error.NoSuchEntity;
    const entry = self.scene_components.find(component) orelse return error.NoSuchComponent;
    if (textAttributeOf(entry.type, property) == null) return error.NoSuchText;
    try self.texts.set(self.gpa, entity, texts_mod.keyOf(component, property), text);
}

/// The text `property` a component's type keeps beside it, if it keeps one.
pub fn textAttributeOf(owner: *const reflect.Type, property: []const u8) ?*const attr.Text {
    for (owner.attributes.slice()) |*attribute| {
        const text = attribute.as(attr.Text) orelse continue;
        if (std.mem.eql(u8, text.name, property)) return text;
    }
    return null;
}

/// The box a map's painted tiles fill, in the map's own pixels: left, top,
/// right and bottom. Null for an entity with no `TileMap`, or one with no
/// tiles in it.
pub fn tileMapBounds(self: *App, entity: ecs.Entity) ?[4]f32 {
    if (!self.world.has(entity, tilemap.TileMap)) return null;
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    var it = ecs.Query(.{tilemap.TileChunk}).over(&self.world) catch return null;
    while (it.next()) |chunk| for (chunk.slice(tilemap.TileChunk)) |tiles| {
        if (!tiles.map.eql(entity)) continue;
        for (tiles.cells, 0..) |cell, index| {
            if (cell.isEmpty()) continue;
            const x = tiles.x * tilemap.chunk_side + @as(i32, @intCast(index % tilemap.chunk_side));
            const y = tiles.y * tilemap.chunk_side + @as(i32, @intCast(index / tilemap.chunk_side));
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x + 1);
            max_y = @max(max_y, y + 1);
        }
    };
    if (min_x > max_x) return null;
    const tile = self.tileSizeOf(entity);
    return .{
        @as(f32, @floatFromInt(min_x)) * tile[0],
        @as(f32, @floatFromInt(min_y)) * tile[1],
        @as(f32, @floatFromInt(max_x)) * tile[0],
        @as(f32, @floatFromInt(max_y)) * tile[1],
    };
}

pub fn tileMapCorners(self: *App, entity: ecs.Entity) ?[4]math.Vec2 {
    const bounds = self.tileMapBounds(entity) orelse return null;
    const placed = self.drawnTransform(entity) orelse return null;
    const top_left = placed.apply(bounds[0], bounds[1]);
    const top_right = placed.apply(bounds[2], bounds[1]);
    const bottom_right = placed.apply(bounds[2], bounds[3]);
    const bottom_left = placed.apply(bounds[0], bounds[3]);
    return .{
        .init(top_left.x, top_left.y),
        .init(top_right.x, top_right.y),
        .init(bottom_right.x, bottom_right.y),
        .init(bottom_left.x, bottom_left.y),
    };
}

/// Whichever of the two an entity is drawn as: its sprite's corners, else
/// its label's. What an editor outlines, frames and tests a click against
/// without asking which it is.
pub fn drawnCorners(self: *App, entity: ecs.Entity) ?[4]math.Vec2 {
    return self.spriteCorners(entity) orelse self.textCorners(entity) orelse self.tileMapCorners(entity);
}

/// What the camera sees, at the frame's size and scale: the view the world
/// is drawn through and the pointer is found in.
pub fn currentView(self: *App) View {
    return self.viewAt(self.frame, @floatFromInt(self.frame.width), @floatFromInt(self.frame.height));
}

/// What the camera sees in a frame this size, as the stretch scales it:
/// worked out at the size the game is made at - where a world with no
/// camera has its origin at the top left, and a camera's fit is measured -
/// and drawn at the frame's pixels.
fn viewAt(self: *App, frame: stretch_mod.Frame, width: f32, height: f32) View {
    const scale = if (frame.scale > 0) frame.scale else 1;
    var view: View = .of(&self.world, &self.snapshots, width / scale, height / scale);
    view.width = width;
    view.height = height;
    return view.zoomed(scale);
}

// -------------------------------------------------------------------------
// Physics
// -------------------------------------------------------------------------

/// The body an entity is, or is part of, to push: its `RigidBody2D`'s, or
/// the one its `Collider2D` belongs to. Bodies are made at the top of each
/// frame and before each fixed step, so this is null until then - see
/// `syncBodies`. The pointer lasts until the next body is made.
///
/// ```zig
/// if (app.bodyOf(player)) |body| body.applyImpulse(.init(0, -300 * body.mass), body.center);
/// ```
pub fn bodyOf(self: *App, entity: ecs.Entity) ?*physics_lib.Body {
    return self.physics.body(self.bodies.idOf(entity) orelse return null);
}

/// The handle of the same body, for `physics.createJoint`.
pub fn bodyIdOf(self: *const App, entity: ecs.Entity) ?physics_lib.BodyId {
    return self.bodies.idOf(entity);
}

/// Make, change and take away bodies to match the components now, not at
/// the next frame or step: for joining two things just spawned.
pub fn syncBodies(self: *App) !void {
    try self.bodies.sync(self);
}

/// The first collider on the line from `from` to `to` whose filter agrees
/// with `filter`; `.{}` agrees with everything.
pub fn castRay(self: *App, from: math.Vec2, to: math.Vec2, mask: u32, hit_areas: bool) ?Bodies.RayHit {
    return self.bodies.castRay(self, from, to, .{ .filter = .{ .category = 0xFFFF_FFFF, .mask = mask }, .sensors = hit_areas });
}

/// Every `RayCast2D` asked what it hits, after each physics step.
fn updateRayCasts(self: *App) !void {
    var it = try ecs.Query(.{components.RayCast2D}).over(&self.world);
    while (it.next()) |chunk| {
        for (chunk.slice(components.RayCast2D), chunk.entities) |*ray, entity| self.castRayOf(entity, ray);
    }
}

/// Ask a `RayCast2D` now rather than at the next physics step: after
/// moving it, or turning it on.
pub fn forceRaycastUpdate(self: *App, entity: ecs.Entity) void {
    const ray = self.world.get(entity, components.RayCast2D) orelse return;
    self.castRayOf(entity, ray);
}

fn castRayOf(self: *App, entity: ecs.Entity, ray: *components.RayCast2D) void {
    ray.colliding = false;
    ray.collider = .none;
    ray.shape = .none;
    if (!ray.enabled) return;
    const from = self.globalPosition(entity) orelse return;
    const to = self.toGlobal(entity, ray.target) orelse return;
    // The body it is on: its own, or the nearest one above it.
    var own: ?physics_lib.BodyId = null;
    if (ray.exclude_parent) {
        var at = entity;
        while (!at.isNone()) : (at = self.parentOf(at)) {
            own = self.bodies.idOf(at) orelse continue;
            break;
        }
    }
    const hit = self.bodies.castRay(self, from, to, .{
        .filter = .{ .category = 0xFFFF_FFFF, .mask = ray.collision_mask },
        .sensors = ray.hit_areas,
        .ignore = own,
    }) orelse return;
    ray.colliding = true;
    ray.collider = hit.collider;
    ray.shape = hit.shape;
    ray.point = hit.point;
    ray.normal = hit.normal;
}

/// A `RigidBody2D`'s body in the physics, made now if the physics has not
/// seen it yet.
fn rigidBodyOf(self: *App, entity: ecs.Entity) error{ NotABody, OutOfMemory }!*physics_lib.Body {
    if (!self.world.has(entity, components.RigidBody2D)) return error.NotABody;
    const id = self.bodies.idOf(entity) orelse blk: {
        self.syncBodies() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NotABody,
        };
        break :blk self.bodies.idOf(entity) orelse return error.NotABody;
    };
    const held = self.physics.body(id) orelse return error.NotABody;
    held.wake();
    return held;
}

/// A kick: the body's velocity changed at once by `impulse` over its mass -
/// a jump, a bullet, an explosion. At `offset` from its middle, in the
/// world's directions, it turns too. Only a dynamic body moves.
pub fn applyImpulse(self: *App, body: ecs.Entity, impulse: math.Vec2, offset: math.Vec2) error{ NotABody, OutOfMemory }!void {
    const held = try self.rigidBodyOf(body);
    held.applyImpulse(impulse, held.position().add(offset));
}

/// A push for the next physics step, at `offset` from the body's middle: a
/// thruster, wind. Given again every step it keeps pushing - from `fixed`.
pub fn applyForce(self: *App, body: ecs.Entity, force: math.Vec2, offset: math.Vec2) error{ NotABody, OutOfMemory }!void {
    const held = try self.rigidBodyOf(body);
    held.applyForceAt(force, held.position().add(offset));
}

/// A turning push for the next physics step, clockwise on screen.
pub fn applyTorque(self: *App, body: ecs.Entity, torque: f32) error{ NotABody, OutOfMemory }!void {
    const held = try self.rigidBodyOf(body);
    held.applyTorque(torque);
}

/// A turning kick: the spin changed at once.
pub fn applyTorqueImpulse(self: *App, body: ecs.Entity, impulse: f32) error{ NotABody, OutOfMemory }!void {
    const held = try self.rigidBodyOf(body);
    held.applyAngularImpulse(impulse);
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

/// The physics' settings as the engine keeps them, whatever a game passed:
/// two colliders touch when either one's mask has the other's layer, a
/// pair's friction is the smaller of the two, and its bounce the two added.
fn withEngineRules(settings: physics_lib.Settings) physics_lib.Settings {
    var kept = settings;
    kept.filter_rule = .either;
    kept.friction_mix = .minimum;
    kept.restitution_mix = .sum_clamped;
    return kept;
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
    return self.overlapsOf(area, false);
}

/// The other areas inside `area` now, good until the next such question.
pub fn overlappingAreas(self: *App, area: ecs.Entity) Allocator.Error![]const ecs.Entity {
    return self.overlapsOf(area, true);
}

fn overlapsOf(self: *App, area: ecs.Entity, areas: bool) Allocator.Error![]const ecs.Entity {
    try self.overlaps_found.ensureTotalCapacity(self.gpa, self.areas.objects.count());
    const found = self.areas.overlapping(self, area, areas, self.overlaps_found.allocatedSlice());
    self.overlaps_found.items.len = found.len;
    return self.overlaps_found.items;
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

/// The same for contacts that ended - including because one of the two was
/// despawned, so the entity named may be dead.
pub fn contactsEnded(self: *const App) []const Bodies.Contact {
    return self.bodies.ended(self.input.clock == .fixed);
}

// -------------------------------------------------------------------------
// The window
// -------------------------------------------------------------------------

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
    try self.setWindowMode(switch (self.windowMode()) {
        .fullscreen, .exclusive_fullscreen => .windowed,
        else => .fullscreen,
    });
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
    const window = if (self.window) |*held| held else return;
    const mode = window.mode();
    const filling = mode == .fullscreen or mode == .exclusive_fullscreen;
    if (filling) try window.setMode(.windowed);
    try window.centerOn(screen);
    if (filling) try window.setMode(mode);
}

/// Put the window in the middle of the screen it is on. Nothing without a
/// window.
pub fn centerWindow(self: *App) Window.Error!void {
    const window = if (self.window) |*held| held else return;
    try window.centerOn(window.screen() orelse window.primaryScreen() orelse return error.Unavailable);
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

/// True in the frame the window's close button - or Alt+F4 - was pressed,
/// where the project's `application.quit_on_close` is off: the game asks
/// whether to go, and goes with `quit`.
pub fn closeRequested(self: *const App) bool {
    return self.close_frame == self.time.frame;
}

/// What the project file's `application.version` says: "1.2.0", for a menu
/// to show. Empty with none.
pub fn gameVersion(self: *const App) []const u8 {
    const held = self.project.settings orelse return "";
    return held.application.version;
}

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
    try self.adoptSize(width, height);
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
/// another: see `stretch.zig`. From the next frame.
pub fn setStretchMode(self: *App, mode: stretch_mod.Mode) void {
    self.stretch.mode = mode;
    self.refitStretch();
}

pub fn stretchMode(self: *const App) stretch_mod.Mode {
    return self.stretch.mode;
}

/// What a window of another shape shows: bars, or more of the game.
pub fn setStretchAspect(self: *App, aspect: stretch_mod.Aspect) void {
    self.stretch.aspect = aspect;
    self.refitStretch();
}

pub fn stretchAspect(self: *const App) stretch_mod.Aspect {
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
pub fn setStretchScaleMode(self: *App, mode: stretch_mod.ScaleMode) void {
    self.stretch.scale_mode = mode;
    self.refitStretch();
}

pub fn stretchScaleMode(self: *const App) stretch_mod.ScaleMode {
    return self.stretch.scale_mode;
}

/// A stretch changed: the frame again, and the picture it is drawn into.
fn refitStretch(self: *App) void {
    self.fitFrame();
    self.resized = true;
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

/// The family of graphics APIs the game is drawn with: the project's.
pub fn rendererInUse(self: *const App) Project.Renderer {
    const held = self.project.settings orelse return .compatibility;
    return held.rendering.renderer;
}

/// The graphics API the game is drawn with, which the renderer chose - or
/// fell back to. `.none` with no window.
pub fn backendInUse(self: *App) Backend {
    return switch (self.device.backendTag()) {
        .gl => .gl,
        .d3d11 => .d3d11,
        .d3d12 => .d3d12,
        .vulkan => .vulkan,
        .webgl => .webgl,
        .none, .other => .none,
    };
}

/// Hold the frames to at most `fps` a second, nought for no cap: a
/// settings menu's frame limit. `time.max_fps` from Zig.
pub fn setMaxFps(self: *App, limit: f32) void {
    self.time.max_fps = if (limit > 0) limit else null;
}

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
    if (texture.isNone()) return self.setCustomCursorPixels(null, shape);
    const source = self.assets.textureSource(texture) orelse return error.NoFile;
    return self.setCustomCursorFile(source, shape, hotspot);
}

/// The same from a picture's file - `res://`, `user://` or the system's -
/// read without making a texture of it.
pub fn setCustomCursorFile(self: *App, path: []const u8, shape: CursorShape, hotspot: math.Vec2) !void {
    const bytes = try self.project.readFileAlloc(self.gpa, path, .limited(text_limit));
    defer self.gpa.free(bytes);
    var decoded = try image.decode(self.gpa, bytes);
    defer decoded.deinit(self.gpa);
    const hot_x: u32 = @intFromFloat(std.math.clamp(@round(hotspot.x), 0, @as(f32, @floatFromInt(decoded.width -| 1))));
    const hot_y: u32 = @intFromFloat(std.math.clamp(@round(hotspot.y), 0, @as(f32, @floatFromInt(decoded.height -| 1))));
    try self.setCustomCursorPixels(.{ .pixels = decoded.pixels, .width = decoded.width, .height = decoded.height, .hot_x = hot_x, .hot_y = hot_y }, shape);
}

/// The same from pixels in memory - straight RGBA, row by row from the top
/// - which are copied; null gives the shape back to the system.
pub fn setCustomCursorPixels(self: *App, picture: ?platform.CursorImage, shape: CursorShape) !void {
    const slot = &self.custom_cursors[@intFromEnum(shape)];
    const given = picture orelse {
        if (slot.*) |held| self.gpa.free(held.pixels);
        slot.* = null;
        self.cursor_generation +%= 1;
        return;
    };
    if (given.width > platform.CursorImage.max_side or given.height > platform.CursorImage.max_side) return error.CursorTooLarge;
    if (!given.valid()) return error.InvalidCursor;
    const pixels = try self.gpa.dupe(u8, given.pixels);
    if (slot.*) |held| self.gpa.free(held.pixels);
    slot.* = .{ .pixels = pixels, .width = given.width, .height = given.height, .hot_x = given.hot_x, .hot_y = given.hot_y };
    self.cursor_generation +%= 1;
}

/// The shape the pointer takes where nothing under it asks for another -
/// over the game's world, over a control that leaves it to the game: the
/// arrow, unless this says otherwise.
pub fn setDefaultCursorShape(self: *App, shape: CursorShape) void {
    self.default_cursor_shape = shape;
}

pub fn defaultCursorShape(self: *const App) CursorShape {
    return self.default_cursor_shape;
}

/// The shape the pointer took in the last frame: what the control under it
/// asked for, or the default.
pub fn currentCursorShape(self: *const App) CursorShape {
    return self.cursor_wanted;
}

/// The shape the interface asks for, the arrow being the game's default.
fn wantedCursor(self: *App) CursorShape {
    const asked: CursorShape = switch (self.ui.cursor()) {
        inline else => |named| @field(CursorShape, @tagName(named)),
    };
    return if (asked == .arrow) self.default_cursor_shape else asked;
}

/// The window shows the wanted shape: the game's picture for it where it
/// gave one, and the system's otherwise - told only of a change.
fn applyCursor(self: *App, window: *Window) void {
    const shape = self.cursor_wanted;
    if (self.cursor_shown) |shown| {
        if (shown.shape == shape and shown.generation == self.cursor_generation) return;
    }
    self.cursor_shown = .{ .shape = shape, .generation = self.cursor_generation };
    if (self.custom_cursors[@intFromEnum(shape)]) |custom| {
        window.setCursorImage(.{ .pixels = custom.pixels, .width = custom.width, .height = custom.height, .hot_x = custom.hot_x, .hot_y = custom.hot_y }) catch |err| {
            log.warn("the pointer's picture was not taken: {t}", .{err});
        };
        return;
    }
    window.setCursorImage(null) catch {};
    window.setCursorShape(shape) catch {};
}

/// The project file's `display.mouse_cursor` for the arrow. A picture that
/// does not read is said, and the system's arrow stays.
fn useProjectCursor(self: *App) void {
    const settings = self.project.settings orelse return;
    const path = settings.display.mouse_cursor;
    if (path.len == 0) return;
    self.setCustomCursorFile(path, .arrow, settings.display.mouse_cursor_hotspot) catch |err| {
        log.warn("the project's pointer {s} was not taken: {t}", .{ path, err });
    };
}

/// A picture the game gave one of the pointer's shapes.
const CustomCursor = struct { pixels: []u8, width: u32, height: u32, hot_x: u32, hot_y: u32 };

/// The window's own picture, in the title bar, the task switcher and the
/// dock: several sizes at once, each at most `platform.IconImage.max_side`
/// pixels across, and the system takes the one it wants. An empty list puts
/// the system's own back: the program's icon, when it has one. Nothing
/// without a window, and `error.Unavailable` on Wayland, where a window's
/// picture comes from its desktop file, on Android, and for an image too
/// large.
pub fn setWindowIcon(self: *App, images: []const platform.IconImage) Window.Error!void {
    if (self.window) |*window| try window.setIcon(images);
}

/// The sizes a window's picture is made in: what the systems draw one at,
/// in a title bar and a task switcher, at display scales from 100% to 300%,
/// smallest first.
const window_icon_sides = [_]u32{ 16, 20, 24, 28, 32, 40, 48, 56, 64, 96, 128, 256 };

/// The project file's `application.icon` on the window, when it names one:
/// what the game shows in the taskbar. The picture can be any size; the
/// window gets it at each of `window_icon_sides`. A program with an icon of
/// its own - a Windows export - keeps that one, which its export made for
/// it. A picture that does not read is said, and the window keeps the
/// system's.
fn useProjectIcon(self: *App) void {
    const settings = self.project.settings orelse return;
    const path = settings.application.icon;
    const window = if (self.window) |*one| one else return;
    if (path.len == 0 or window.programIcon()) return;
    const bytes = self.project.readFileAlloc(self.gpa, path, .limited(text_limit)) catch |err| {
        return log.warn("the project's icon {s} did not read: {t}", .{ path, err });
    };
    defer self.gpa.free(bytes);
    var art = Image.decode(self.gpa, bytes) catch |err| {
        return log.warn("the project's icon {s} did not read: {t}", .{ path, err });
    };
    defer art.deinit(self.gpa);

    // The largest from the picture, and the rest from that one, so a picture
    // of any size is gone over once.
    var made: [window_icon_sides.len]Image = undefined;
    var sizes: [window_icon_sides.len]platform.IconImage = undefined;
    var count: usize = 0;
    defer for (made[0..count]) |*one| one.deinit(self.gpa);
    var left: usize = window_icon_sides.len;
    while (left > 0) {
        left -= 1;
        const side = window_icon_sides[left];
        made[count] = (if (count == 0) art.icon(self.gpa, side, side) else made[0].resized(self.gpa, side, side, true)) catch |err| {
            return log.warn("the project's icon {s} was not put on the window: {t}", .{ path, err });
        };
        sizes[count] = .{ .pixels = made[count].pixels, .width = side, .height = side };
        count += 1;
    }
    self.setWindowIcon(&sizes) catch |err| {
        log.warn("the project's icon {s} was not put on the window: {t}", .{ path, err });
    };
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

/// Teach the platform controllers it does not know, from text in SDL's
/// `gamecontrollerdb.txt` format, and say how many lines it took. Most
/// controllers never need it. Nothing without a window.
pub fn addGamepadMappings(self: *App, text: []const u8) Window.Error!usize {
    const window = if (self.window) |*w| w else return 0;
    return window.ctx.updateGamepadMappings(text);
}

// -------------------------------------------------------------------------
// The clipboard
// -------------------------------------------------------------------------

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

/// Remember where every interpolating transform is, before a step moves it.
/// Refilled rather than added to, so the dead drop out; the capacity stays.
fn snapshotPrevious(self: *App) !void {
    self.snapshots.clearRetainingCapacity();

    var it = try ecs.Query(.{components.Transform2D}).over(&self.world);
    while (it.next()) |chunk| {
        for (chunk.slice(components.Transform2D), chunk.entities) |current, entity| {
            if (!current.interpolate) continue;
            try self.snapshots.put(self.gpa, entity, .of(current));
        }
    }
}

/// What this frame is drawn into.
pub fn target(self: *App) rhi.RenderTarget {
    if (self.surface) |surface| return .{ .surface = surface };
    return .{ .texture = self.offscreen.? };
}

/// Draw the layers, back to front, into one target.
fn render(self: *App) !void {
    try self.drawLayers(self.target(), @floatFromInt(self.width), @floatFromInt(self.height));
    if (self.surface) |surface| try self.device.present(surface);
}

/// Every layer, in order, into whatever it is given. Separate from `render`,
/// so that `capture` can draw the same frame somewhere else.
///
/// A frame with a material in it that reads what is drawn under it is drawn
/// into a texture of its own - a surface cannot be read - and put on `into`
/// after. See `render/screen.zig`.
fn drawLayers(self: *App, into: rhi.RenderTarget, width: f32, height: f32) !void {
    self.sprites.time = @floatCast(self.interface.seconds);
    self.screen.copies = 0;
    try self.drawViews();
    // The frame for a target this size: the window's, or a capture's.
    const frame = self.stretch.frameOf(@intFromFloat(width), @intFromFloat(height));
    const frame_width: f32 = @floatFromInt(frame.width);
    const frame_height: f32 = @floatFromInt(frame.height);
    if (!frame.apart and !self.readsScreen()) return self.drawLayersInto(into, frame, frame_width, frame_height);
    const picture = try self.screen.frameOf(frame.width, frame.height, self.background);
    try self.drawLayersInto(.{ .texture = picture }, frame, frame_width, frame_height);
    // A picture scaled to the window is sampled as the project's textures
    // are; a canvas is one pixel to one.
    const filter: rhi.Filter = if (self.stretch.mode == .picture) self.assets.default_filter else .nearest;
    const shown = frame.shown;
    try self.screen.present(picture, into, .{ .x = shown.x, .y = shown.y, .width = shown.width, .height = shown.height }, self.assets.samplerFor(filter, .clamp_to_edge), .black);
}

fn drawLayersInto(self: *App, into: rhi.RenderTarget, frame: stretch_mod.Frame, width: f32, height: f32) !void {
    // 1. The 3D layer, with a depth test, clearing the frame. Not written
    //    yet; when it is, the 2D pass below stops clearing.

    // 2. The 2D layer: sprites and text, sorted back to front, blended, no
    //    depth - or, with the world off the screen, only the clearing.
    const view = self.viewAt(frame, width, height);
    if (self.world_on_screen) {
        const clear = try self.drawDebugUnder(into, view);
        try self.sprites.draw(self.gpa, &self.world, &self.assets, &self.tile_sets, &self.snapshots, &self.inherited, into, view, clear, self.time.alpha());
    } else try self.clearTarget(into);

    // 3. The interface, on top, loading what the 2D layer left - with its
    //    glyphs drawn again when a font was read again since.
    if (self.interface.font_reloads != self.assets.font_reloads) {
        self.interface.forgetGlyphs();
        self.interface.font_reloads = self.assets.font_reloads;
    }
    try self.interface.draw(self.gpa, &self.device, self.interfaceFaces(), into, width, height);

    // 4. `debug`, over all of it: the world through the 2D camera, and the
    //    screen in pixels.
    if (self.world_on_screen and self.debug_visible) try self.drawDebug(into, view);
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
    try self.drawWorldWithoutDebug(into, view);
    try self.drawDebugOverlay(into, view);
}

/// `drawWorld` without the `debug` lines over it, for an editor that draws
/// its interface preview over the world first and its marks last, with
/// `drawDebugOverlay`: a material there that reads the screen reads the
/// game's picture, not a selection's outline or a camera's frame.
pub fn drawWorldWithoutDebug(self: *App, into: rhi.Texture, view: View) !void {
    self.sprites.time = @floatCast(self.interface.seconds);
    try self.drawViews();
    const clear = try self.drawDebugUnder(.{ .texture = into }, view);
    try self.sprites.draw(self.gpa, &self.world, &self.assets, &self.tile_sets, &self.snapshots, &self.inherited, .{ .texture = into }, view, clear, self.time.alpha());
}

/// The size the game is made at: the project's `display.width` and
/// `height`, what its interface is laid out in at its first size - or the
/// window's, with no project.
pub fn gameSize(self: *const App) [2]f32 {
    if (self.project.settings) |settings| return .{ @floatFromInt(settings.display.width), @floatFromInt(settings.display.height) };
    return .{ @floatFromInt(self.width), @floatFromInt(self.height) };
}

/// The camera the screen looks through: the active one with the highest
/// priority that draws no picture of its own, or null for none.
pub fn currentCamera(self: *App) ?ecs.Entity {
    const seen = View.lookedThrough(&self.world, &self.snapshots) orelse return null;
    return seen.entity;
}

/// What a camera shows of the world: through it at the game's size - or,
/// for one that draws a picture of its own, at the picture's.
pub fn cameraView(self: *App, entity: ecs.Entity) ?View {
    const camera = self.world.get(entity, components.Camera2D) orelse return null;
    const placed = self.drawnTransform(entity) orelse return null;
    const size = if (self.world.get(entity, components.RenderView)) |own| [2]f32{ @floatFromInt(own.width), @floatFromInt(own.height) } else self.gameSize();
    return .through(camera.*, placed, size[0], size[1]);
}

/// A smoothed camera's frame toward where it is: `Camera2D.smoothing`. With
/// no time going by - an editor's frame - it is where it is.
fn followCameras(self: *App) !void {
    var it = try ecs.Query(.{components.Camera2D}).over(&self.world);
    while (it.next()) |chunk| {
        for (chunk.slice(components.Camera2D), chunk.entities) |*camera, entity| {
            const placed = self.drawnTransform(entity) orelse continue;
            const aim = camera.target(placed);
            const delta = self.time.delta;
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
pub fn screenCenter(self: *App, camera: ecs.Entity) ?math.Vec2 {
    const view = self.cameraView(camera) orelse return null;
    return .init(view.x, view.y);
}

/// Put a smoothed camera where it is at once: after a teleport, a new
/// level.
pub fn resetSmoothing(self: *App, camera: ecs.Entity) void {
    const held = self.world.get(camera, components.Camera2D) orelse return;
    held.following = false;
}

/// The corners of what a camera shows, in the world, clockwise from the
/// screen's top left: a frame an editor draws round it.
pub fn cameraCorners(self: *App, entity: ecs.Entity) ?[4]math.Vec2 {
    const view = self.cameraView(entity) orelse return null;
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

pub fn screenInWorld(self: *App) ScreenPlace {
    const camera = self.currentCamera() orelse return .{ .top_left = .init(0, 0), .units_per_pixel = 1 };
    const view = self.cameraView(camera).?;
    const size = self.gameSize();
    return .{
        .top_left = .init(view.x - size[0] / (2 * view.zoom_x), view.y - size[1] / (2 * view.zoom_y)),
        .units_per_pixel = 1 / view.zoom_x,
    };
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
    try self.control_nodes.preview(self, into, view, view.width, view.height, self.interface.faces, editing);
}

/// Draw this frame's world-space debug lines over an editor preview: after
/// `drawWorldWithoutDebug` and `drawControlPreview`.
pub fn drawDebugOverlay(self: *App, into: rhi.Texture, view: View) !void {
    if (self.debug_visible) try self.drawDebug(.{ .texture = into }, view);
}

/// A Control's box in the last editor preview, in preview pixels.
pub fn controlPreviewBox(self: *App, entity: ecs.Entity) ?ui_lib.BoundingBox {
    return self.control_nodes.previewBox(entity);
}

/// Whether a texture `drawWorld` drew into comes out upside down when drawn
/// as a picture: what the device says of what it draws - true on OpenGL,
/// whose framebuffers count rows from the bottom.
pub fn drawnUpsideDown(self: *const App) bool {
    return self.device.caps().features.render_target_origin_bottom_left;
}

/// Clear `into` to the background and draw `debug_under` on it, for the
/// sprites to go over: the colour the sprites should clear to, which is
/// none once this has cleared. With nothing under the world - the usual
/// case - no pass is made, and the sprites clear as they always did.
fn drawDebugUnder(self: *App, into: rhi.RenderTarget, view: View) !?Color {
    self.debug_under_stats = .{};
    if (!self.debug_visible) return self.background;
    if (self.debug_under_frame.isEmpty() and self.debug_under_steps.isEmpty()) return self.background;
    try self.debug_renderer.draw(&.{ &self.debug_under_steps, &self.debug_under_frame }, .{
        .color = into,
        .clear = self.background.array(),
    }, .{
        .view_projection = view.matrix(self.device.clip()),
        .width = view.width,
        .height = view.height,
    });
    self.debug_under_stats = self.debug_renderer.stats;
    return null;
}

fn drawDebug(self: *App, into: rhi.RenderTarget, view: View) !void {
    try self.debug_renderer.draw(&.{ &self.debug_steps, &self.debug_frame }, .{ .color = into }, .{
        .view_projection = view.matrix(self.device.clip()),
        .width = view.width,
        .height = view.height,
    });
}

/// Start a frame from the background, for a frame that draws no world.
fn clearTarget(self: *App, into: rhi.RenderTarget) !void {
    const list = self.device.begin();
    try list.beginPass(.{ .color = .{ .target = into, .clear_color = self.background.array() } });
    try list.endPass();
    try self.device.submit();
}

/// Draw one frame into a texture of its own and hand back the pixels: four
/// bytes each, top row first, owned by the caller. The same passes as a
/// frame on screen, so a capture shows what a player sees.
pub fn capture(self: *App, gpa: Allocator, width: u32, height: u32) ![]u8 {
    const texture = try self.device.createTexture(.{
        .width = width,
        .height = height,
        .usage = .{ .sampled = true, .render_target = true },
        .clear_color = self.background.array(),
        .label = "capture",
    });
    defer self.device.destroyTexture(texture);

    try self.drawLayers(.{ .texture = texture }, @floatFromInt(width), @floatFromInt(height));
    return self.device.readTexture(texture, gpa);
}

/// Draw one frame at the target's size into a PNG file: what `--capture`
/// asks for. `res://` is taken, as everywhere. `error.NoIo` without
/// `Options.io`.
pub fn saveCapture(self: *App, path: []const u8) !void {
    const io = self.io orelse return error.NoIo;
    const file = try self.project.osPath(self.gpa, path);
    defer self.gpa.free(file);

    const pixels = try self.capture(self.gpa, self.width, self.height);
    defer self.gpa.free(pixels);

    try image.png.writeFile(self.gpa, io, file, .{
        .width = self.width,
        .height = self.height,
        .pixels = pixels,
        .row_pitch = self.width * 4,
    }, .{});
}

// -------------------------------------------------------------------------
// Images
// -------------------------------------------------------------------------

/// A picture's file - a PNG or a JPEG, `res://`, `user://` or the system's -
/// as an image to read and change, in `gpa`'s memory. See `images`.
pub fn readImage(self: *App, gpa: Allocator, path: []const u8) !Image {
    const bytes = try self.project.readFileAlloc(self.gpa, path, .limited(text_limit));
    defer self.gpa.free(bytes);
    const decoded = try image.decode(gpa, bytes);
    return .{ .width = decoded.width, .height = decoded.height, .pixels = decoded.pixels };
}

pub const SaveImageOptions = struct {
    /// A JPEG's, from 1 to 100.
    quality: u8 = 90,
};

/// Write an image to `path`: a JPEG for a `.jpg` or a `.jpeg`, a PNG for a
/// `.png`, and `error.UnknownImageFormat` for any other ending. Written
/// beside the old and put in its place, as `writeText` does.
pub fn saveImage(self: *App, picture: Image, path: []const u8, options: SaveImageOptions) !void {
    const ending = std.fs.path.extension(path);
    const bytes = if (std.ascii.eqlIgnoreCase(ending, ".png"))
        try picture.encodePng(self.gpa)
    else if (std.ascii.eqlIgnoreCase(ending, ".jpg") or std.ascii.eqlIgnoreCase(ending, ".jpeg"))
        try picture.encodeJpg(self.gpa, options.quality)
    else
        return error.UnknownImageFormat;
    defer self.gpa.free(bytes);
    try self.writeText(path, bytes);
}

/// The frame drawn again into an image the window's size: a save's
/// thumbnail, a photo mode's picture.
pub fn captureImage(self: *App, gpa: Allocator) !Image {
    const pixels = try self.capture(gpa, self.width, self.height);
    return .{ .width = self.width, .height = self.height, .pixels = pixels };
}

/// What a texture holds, read back from the GPU: a render view's picture, a
/// texture made from an image and changed since.
pub fn textureImage(self: *App, gpa: Allocator, texture: Assets.TextureHandle) !Image {
    const held = self.assets.get(texture) orelse return error.NoSuchTexture;
    const pixels = try self.device.readTexture(held.gpu, gpa);
    const out: Image = .{ .width = held.width, .height = held.height, .pixels = pixels };
    if (held.upside_down) out.flipY();
    return out;
}

/// An image made a texture to draw, found by the name it is given -
/// `image://1`, `image://2`... - which is what a script hands a sprite. See
/// `updateTexture`.
pub fn newTexture(self: *App, picture: Image, options: Assets.LoadOptions) !Assets.TextureHandle {
    self.image_textures +%= 1;
    var name: [32]u8 = undefined;
    const source = try std.fmt.bufPrint(&name, "image://{d}", .{self.image_textures});
    return self.assets.adoptTexture(source, picture.width, picture.height, picture.pixels, options);
}

/// Give a texture an image's pixels: in place for the same size, made anew
/// for another, the handle the same either way.
pub fn updateTexture(self: *App, texture: Assets.TextureHandle, picture: Image) !void {
    try self.assets.setTexturePixels(texture, picture.width, picture.height, picture.pixels);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------


test "resized is true for the one frame the size changed in, and no other" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240 });
    defer app.destroy();

    try app.startup();
    _ = try app.step();
    try testing.expect(!app.resized);

    // What `step` does when the window reports a new size, done by hand.
    try app.adoptSize(400, 300);
    try testing.expect(app.resized);
    try testing.expectEqual(@as(u32, 400), app.width);
    try testing.expectEqual(@as(u32, 300), app.height);

    // The next frame is at the new size, and the news is old.
    _ = try app.step();
    try testing.expect(!app.resized);
    try testing.expectEqual(@as(u32, 400), app.width);
}

test "an interface font let go of draws in the first, and the indices after it keep their fonts" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    const words = app.assets.loadSystemFont(.{ .atlas = 64 }) catch return error.SkipZigTest;
    const mono = app.assets.loadSystemFont(.{ .atlas = 64, .mono = true }) catch return error.SkipZigTest;
    app.interface.font = words;
    // A handle to nothing, as one to a font since let go of is.
    const gone: Assets.FontHandle = .{ .index = 99, .generation = 7 };
    try testing.expectEqual(@as(u16, 1), try app.interface.addFont(gone));
    try testing.expectEqual(@as(u16, 2), try app.interface.addFont(mono));

    const faces = app.interfaceFaces();
    try testing.expectEqual(@as(usize, 3), faces.len);
    try testing.expectEqual(faces[0], faces[1]);
    try testing.expectEqual(&app.assets.fontOf(mono).?.face, faces[2]);
    // An index past the end is measured in the first, as it is drawn.
    try testing.expectEqual(faces[0], app.interface.faces.faceFor(3));
    try testing.expectEqual(faces[0], app.interface.faces.faceFor(9));

    // As many as the table holds, and not one more.
    for (3..Interface.max_fonts) |n| {
        const filler: Assets.FontHandle = .{ .index = @intCast(100 + n), .generation = 1 };
        try testing.expectEqual(@as(u16, @intCast(n)), try app.interface.addFont(filler));
    }
    try testing.expectError(error.TooManyFonts, app.interface.addFont(.{ .index = 500, .generation = 1 }));
}

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

test "a project's file is read as it starts, and a root with none starts as before" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffers: [2][160]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffers[0], ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const bare = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root });
    try testing.expect(bare.project.settings == null);
    try testing.expectEqualStrings("fluxion", titleOf(.{}, bare.project.settings));
    bare.destroy();

    try Project.writeSettings(testing.allocator, testing.io, root, .{
        .application = .{ .name = "Meadow", .tags = &.{"2d"} },
        .physics_2d = .{ .default_gravity = 981, .default_linear_damp = 0.25 },
    });
    // By the folder, or by the file itself, as a file association gives it.
    const file = try std.fmt.bufPrint(&buffers[1], "{s}/" ++ Project.file_name, .{root});
    for ([_][]const u8{ root, file }) |given| {
        const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = given });
        defer app.destroy();
        const settings = app.project.settings.?;
        try testing.expectEqualStrings("Meadow", settings.application.name);
        try testing.expectEqualStrings("2d", settings.application.tags[0]);
        try testing.expect(std.mem.endsWith(u8, app.project.root, &tmp.sub_path));
        try testing.expectEqualStrings("Meadow", titleOf(.{}, settings));
        try testing.expectEqualStrings("Pong", titleOf(.{ .title = "Pong" }, settings));
        // Its physics over the game's, which it would have had with none.
        try testing.expectEqual(@as(f32, 981), app.physics.gravity.y);
        try testing.expectEqual(@as(f32, 0.25), app.physics_2d.default_linear_damp);
    }
}

test "the window, the frame and the clock are the game's, then the project's, then the engine's" {
    const said: Project.Settings = .{
        .application = .{ .name = "Wide", .max_fps = 30 },
        .display = .{ .width = 1600, .height = 900, .vsync_mode = .disabled, .mode = .fullscreen, .borderless = true, .initial_position = .absolute, .position = .init(40, 30), .keep_screen_on = false, .stretch_scale = 2, .stretch_scale_mode = .integer },
        .rendering = .{ .clear_color = .hex(0x102030) },
        .physics_2d = .{ .ticks_per_second = 120, .max_steps_per_frame = 3 },
        .gui = .{ .scale = 1.5 },
    };
    const project: Resolved = .of(.{}, &said, said.physics_2d);
    try testing.expectEqual(@as(u32, 1600), project.width);
    try testing.expectEqual(@as(u32, 900), project.height);
    try testing.expectEqual(VsyncMode.disabled, project.vsync_mode);
    try testing.expectEqual(WindowMode.fullscreen, project.window_mode);
    try testing.expect(project.borderless and !project.always_on_top and !project.keep_screen_on);
    try testing.expectEqual(InitialPosition.absolute, project.initial_position);
    try testing.expectEqual(geometry.Vec2i.init(40, 30), project.position);
    try testing.expectEqual(@as(f32, 2), project.stretch.scale);
    try testing.expectEqual(stretch_mod.ScaleMode.integer, project.stretch.scale_mode);
    try testing.expectEqual(@as(u32, 3), project.max_fixed_steps);
    try testing.expectEqual(@as(f32, 1.5), project.interface_zoom);
    try testing.expectEqual(Color.hex(0x102030), project.background);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 120.0), project.fixed_delta, 1e-6);
    try testing.expectEqual(@as(?f32, 30), project.max_fps);

    // What the game says in code overrules its project, and only that.
    const game: Resolved = .of(.{ .width = 800, .window_mode = .windowed, .fixed_delta = 0.5 }, &said, said.physics_2d);
    try testing.expectEqual(@as(u32, 800), game.width);
    try testing.expectEqual(@as(u32, 900), game.height);
    try testing.expectEqual(WindowMode.windowed, game.window_mode);
    try testing.expectEqual(@as(f32, 0.5), game.fixed_delta);

    // With no project file, the sections' own defaults.
    const bare: Resolved = .of(.{}, null, .{});
    try testing.expectEqual(@as(u32, 1280), bare.width);
    try testing.expectEqual(@as(u32, 720), bare.height);
    try testing.expect(bare.resizable and !bare.borderless and bare.keep_screen_on);
    try testing.expectEqual(VsyncMode.enabled, bare.vsync_mode);
    try testing.expectEqual(WindowMode.windowed, bare.window_mode);
    try testing.expectEqual(InitialPosition.center_of_primary_screen, bare.initial_position);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 60.0), bare.fixed_delta, 1e-6);
    try testing.expect(bare.max_fps == null);

    // And a game opened in a project's folder takes them.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try Project.writeSettings(testing.allocator, testing.io, root, said);
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root });
    defer app.destroy();
    try testing.expectEqual(@as(u32, 1600), app.width);
    try testing.expectEqual(Color.hex(0x102030), app.background);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 120.0), app.time.fixed_delta, 1e-6);
}
