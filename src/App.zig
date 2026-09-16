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
const Uuid = @import("fluxion_id").Uuid;

const Assets = @import("assets.zig");
const attr = @import("attr.zig");
const Areas = @import("areas.zig");
const Bodies = @import("bodies.zig");
const Picking = @import("picking.zig");
const pointer = @import("pointer.zig");
const Clipboard = @import("clipboard.zig");
const Commands = @import("commands.zig");
const DebugViews = @import("debug_views.zig");
const dialog = @import("dialog.zig");
const Project = @import("Project.zig");
const States = @import("states.zig");
const Interface = @import("interface.zig");
const Input = @import("input.zig");
const Time = @import("time.zig");
const Window = @import("window.zig");
const schedule_mod = @import("schedule.zig");
const hierarchy = @import("hierarchy.zig");
const scene = @import("scene.zig");
const signals_mod = @import("signals.zig");
const events_mod = @import("events.zig");
const sprite = @import("render/sprite.zig");
const View = @import("render/view.zig").View;

const Color = @import("color.zig").Color;
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
    Project.ReadError || BackendError;

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
    /// WebGL 2, in a browser.
    webgl,
    /// Accepts everything, draws nothing. What `.headless` uses.
    none,
};

pub const BackendError = error{
    /// The project's renderer has no backend built on this system: `modern`,
    /// for now, which is Direct3D 12 and Vulkan.
    RendererNotBuilt,
};

/// The backend to open: `wanted` as it is, unless it is `auto`, which is
/// the best of `renderer`'s backends on `os`. A renderer with none is an
/// error rather than a quiet fall back to another, which would hide what the
/// game really looks like.
pub fn chooseBackend(wanted: Backend, renderer: Project.Renderer, os: std.Target.Os.Tag) BackendError!Backend {
    if (wanted != .auto) return wanted;
    const choices = renderer.backends(os);
    if (choices.len == 0) return error.RendererNotBuilt;
    return choices[0];
}

/// How the window fills the screen. See `Window.Fullscreen`.
pub const Fullscreen = Window.Fullscreen;

/// Where the pointer may go, and whether it shows. See `Window.Cursor`.
pub const Cursor = Window.Cursor;

/// One of the system's own pointer shapes.
pub const CursorShape = platform.CursorShape;

/// Whether the window is at its own size, maximised, or minimised.
pub const WindowState = Window.State;

/// How small and how large the player may drag the window.
pub const WindowSizeLimits = Window.SizeLimits;

pub const Options = struct {
    /// What the title bar says. Null is the project's name, from its project
    /// file, or "fluxion" with none.
    title: ?[]const u8 = null,
    width: u32 = 1280,
    height: u32 = 720,
    backend: Backend = .auto,
    vsync: bool = true,

    /// Whether the player may drag the window's edges. `setWindowSize` works
    /// either way.
    resizable: bool = true,

    /// Open maximised. Only a resizable window can be.
    maximized: bool = false,

    /// Open filling the screen. `width` and `height` are still the size of
    /// the window it goes back to.
    fullscreen: Fullscreen = .windowed,

    /// What files are read with and the clock is read from. Null means no
    /// files and a fixed step, as in a test.
    io: ?std.Io = null,

    /// The project's root directory, which `res://` paths are from - or its
    /// `project.fluxion`, which names the same directory. Null is the working
    /// directory. See `Project`.
    root: ?[]const u8 = null,

    /// Where the project file went wrong, when it did: `create` fails then,
    /// and says it in the log as well.
    project_diagnostics: ?*json.Diagnostics = null,

    /// Every frame counts as exactly this many seconds, whatever the clock
    /// says, so every run is the same. `Flags.apply` sets it for `--capture`.
    frame_time: ?f32 = null,

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

    /// What the frame is cleared to.
    background: Color = .hex(0x0E1013),

    /// One fixed step, in seconds.
    fixed_delta: f32 = 1.0 / 60.0,

    /// Stop after this many frames. A headless app has no window to close, so
    /// it needs this or a system that calls `quit`.
    frames: ?u32 = null,

    /// Worker threads for parallel queries. Null is one fewer than the cores.
    workers: ?u32 = null,

    /// A hundred units to the metre, for a world measured in pixels: gravity
    /// pulls at 981 units a second squared.
    physics: physics_lib.Settings = .{ .units_per_metre = 100 },
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
        if (self.frames) |frames| out.frames = frames;
        if (self.root) |root| out.root = root;
        if (self.capture != null) {
            out.frames = out.frames orelse capture_frames;
            out.frame_time = out.fixed_delta;
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

/// Null when headless.
window: ?Window = null,
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
/// Which body is which entity's. See `bodies.zig`.
bodies: Bodies = .{},
/// What is inside each `Area2D`, and the signals that say so. See
/// `areas.zig`.
areas: Areas = .{},
/// What the pointer is over, and what it did there. See `picking.zig`.
picking: Picking = .{},

/// Whether the pointer picks what it is over at all: Godot's
/// `physics/common/enable_object_picking`. An editor turns it off while it
/// edits a scene rather than plays it.
physics_object_picking: bool = true,
/// Whether what is picked comes in the order it is drawn, the topmost
/// first. Godot works the other way by default, and its order is the
/// broadphase's.
physics_object_picking_sort: bool = true,
/// Whether only the first of several under the pointer hears the event,
/// as Godot 4.3 can.
physics_object_picking_first_only: bool = false,

/// Where the game's files are - `res://` - and the UUIDs of the ones that
/// have them. See `Project`.
project: Project,

assets: Assets,
sprites: sprite.Renderer,

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

/// Every named entity's name, and every name's entity. Each name is one
/// allocation, shared by the two maps and freed once. An array map, so that
/// `forgetDeadNames` can walk it by index while removing from it.
names: std.AutoArrayHashMapUnmanaged(ecs.Entity, []const u8) = .empty,
by_name: std.StringHashMapUnmanaged(ecs.Entity) = .empty,

/// Every entity given a UUID, and every UUID's entity: kept beside the world
/// as names are, and written into a scene with it. An array map, for the same
/// reason as `names`.
uuids: std.AutoArrayHashMapUnmanaged(ecs.Entity, Uuid) = .empty,
by_uuid: std.AutoHashMapUnmanaged(Uuid, ecs.Entity) = .empty,
/// What `newUuid` draws from: seeded by the operating system, or with no
/// `Io` by a constant, so a test makes the same ones every run.
uuid_source: std.Random.DefaultCsprng,

/// What a scene can hold, and what each component is called in one: the
/// engine's own from the start, and a game's once `registerComponents` has
/// been told about them.
scene_components: scene.Registry = .{},

/// Every signal's connections, the calls waiting for their sync point, and
/// `dispatch`, the switch that makes none. See `signal`.
signals: signals_mod.Signals,

/// Every type of event sent, by type. See `send` and `events`.
event_channels: std.AutoArrayHashMapUnmanaged(usize, EventChannel) = .empty,

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

vsync_on: bool = true,

/// Cleared by `quit`, and by the frame counter running out.
running: bool = true,
frames_left: ?u32,
started: bool = false,

/// Open everything, in the order the pieces depend on each other.
pub fn create(gpa: Allocator, options: Options) Error!*App {
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
        .physics = .init(gpa, options.physics),
        .bodies = .{},
        .project = undefined,
        .assets = undefined,
        .sprites = undefined,
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
        .interface = .{},
        .clipboard = .{},
        .next_dialog = 1,
        .trash = null,
        // A fixed frame time wins over the clock, and the clock over nothing.
        .time = .init(if (options.frame_time) |seconds|
            .{ .fixed = seconds }
        else if (options.io) |io|
            .{ .clock = io }
        else
            .{ .fixed = options.fixed_delta }),
        .snapshots = .empty,
        .orphans = .empty,
        .names = .empty,
        .by_name = .empty,
        .uuids = .empty,
        .by_uuid = .empty,
        .uuid_source = undefined,
        .scene_components = .{},
        .signals = .init(gpa),
        .event_channels = .empty,
        .types = .init(gpa),
        .input = .{},
        .schedule = .{ .io = options.io, .commands = &self.commands, .signals = &self.signals },
        .states = .{},
        .gate = null,
        .background = options.background,
        .world_on_screen = true,
        .width = options.width,
        .height = options.height,
        .resized = false,
        .quit_key = options.quit_key,
        .fullscreen_key = options.fullscreen_key,
        .debug_key = options.debug_key,
        .vsync_on = options.vsync,
        .running = true,
        .frames_left = options.frames,
        .started = false,
    };
    errdefer self.world.deinit();
    errdefer self.commands.deinit();
    errdefer self.ui.deinit();
    errdefer self.physics.deinit();
    self.time.fixed_delta = options.fixed_delta;

    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = @splat(0x5E);
    if (options.io) |io| io.random(&seed);
    self.uuid_source = .init(seed);
    self.project = try .init(gpa, options.io, options.root);
    errdefer self.project.deinit();
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

    errdefer self.scene_components.deinit(gpa);
    errdefer self.types.deinit();
    self.registerComponents(.{
        components.Transform2D,
        components.Sprite,
        components.Text2D,
        components.Animation,
        components.Camera2D,
        components.RigidBody2D,
        components.Collider2D,
        components.Area2D,
    }) catch |err| switch (err) {
        error.ComponentNameTaken => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    self.types.addAll(.{ DebugViews, Color, components.Region, Assets.TextureHandle, Assets.FontHandle }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    // Headless opens no renderer, so the project's is not asked about.
    const renderer: Project.Renderer = if (self.project.settings) |held| held.renderer else .compatibility;
    const backend: Backend = if (options.headless) .none else chooseBackend(options.backend, renderer, builtin.os.tag) catch |err| {
        log.err("the {t} renderer ({s}) is not built yet: set \"renderer\" to \"compatibility\" in {s}, or give --backend", .{ renderer, renderer.apis(), Project.file_name });
        return err;
    };
    if (!options.headless and options.backend != .auto and std.mem.indexOfScalar(Backend, renderer.backends(builtin.os.tag), backend) == null) {
        log.info("drawing with {t}, which is not one of the {t} renderer's here", .{ backend, renderer });
    }

    // The window comes first, and has to know whether to make an OpenGL
    // context: no platform lets a window change its mind about that.
    if (!options.headless) {
        // Opened in place: its handle points at the context beside it.
        self.window = @as(Window, undefined);
        self.window.?.open(gpa, .{
            .title = titleOf(options, self.project.settings),
            .width = options.width,
            .height = options.height,
            .resizable = options.resizable,
            .maximized = options.maximized,
            .gl = backend == .gl,
            .vsync = options.vsync,
        }) catch |err| {
            self.window = null;
            if (Window.isAbsent(err)) return Error.NoDisplay;
            return err;
        };
        self.clipboard.system = &self.window.?.ctx;
    }
    errdefer if (self.window) |*w| w.close();

    // Before anything is sized from the window, so the swapchain is made at
    // its final size. Not fatal: a game that cannot fill the screen still
    // runs in a window.
    if (self.window) |*w| {
        if (options.fullscreen != .windowed) {
            w.setFullscreen(options.fullscreen) catch |err| {
                log.warn("could not open fullscreen: {t}", .{err});
            };
        }
    }

    const width = if (self.window) |*w| w.width else options.width;
    const height = if (self.window) |*w| w.height else options.height;
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
            .webgl => .webgl,
            .none => .none,
            .auto => .auto,
        },
        // Only OpenGL wants the context; Direct3D takes the window handle at
        // surface time instead.
        .gl = if (backend == .gl and self.window != null) self.window.?.hooks() else null,
    });
    errdefer self.device.deinit();

    if (self.window) |*w| {
        self.surface = try self.device.createSurface(.{
            .native_window = w.nativeHandle(),
            .width = width,
            .height = height,
            // Told to the swapchain as well as the window: Direct3D keeps it
            // on the swapchain, OpenGL on the context.
            .vsync = options.vsync,
        });
    } else {
        // No window, so the frame goes into a texture, through every draw
        // call the real path makes.
        self.offscreen = try self.device.createTexture(.{
            .width = width,
            .height = height,
            .usage = .{ .sampled = true, .render_target = true },
            .label = "headless target",
        });
    }
    errdefer if (self.surface) |s| self.device.destroySurface(s);

    self.jobs = try .init(gpa, .{
        .io = options.io,
        .workers = if (options.workers) |count| .{ .count = count } else .auto,
    });
    errdefer self.jobs.deinit();

    self.assets = try .init(gpa, &self.device, options.io, &self.project);
    errdefer self.assets.deinit();

    self.sprites = try .init(gpa, &self.device);
    errdefer self.sprites.deinit(gpa);

    self.debug_renderer = try .init(gpa, &self.device, .{});
    errdefer self.debug_renderer.deinit();
    self.debug = self.debug_frame.pen();
    self.debug_under = self.debug_under_frame.pen();

    return self;
}

/// What the title bar says: the game's own title, or else its project's
/// name, or else "fluxion".
fn titleOf(options: Options, settings: ?Project.Settings) []const u8 {
    if (options.title) |title| return title;
    if (settings) |held| {
        if (held.name.len > 0) return held.name;
    }
    return "fluxion";
}

pub fn destroy(self: *App) void {
    const gpa = self.gpa;

    self.schedule.deinit(gpa);
    self.states.deinit(gpa);
    self.snapshots.deinit(gpa);
    self.orphans.deinit(gpa);
    for (self.names.values()) |name| gpa.free(name);
    self.names.deinit(gpa);
    self.by_name.deinit(gpa);
    self.uuids.deinit(gpa);
    self.by_uuid.deinit(gpa);
    self.scene_components.deinit(gpa);
    self.signals.deinit();
    for (self.event_channels.values()) |channel| channel.deinit(channel.events, gpa);
    self.event_channels.deinit(gpa);
    self.types.deinit();
    self.bodies.deinit(gpa);
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
    self.ui.deinit();
    self.sprites.deinit(gpa);
    self.assets.deinit();
    self.project.deinit();
    self.jobs.deinit();
    self.commands.deinit();
    self.world.deinit();

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
    self.schedule.beginFrame();
    // Last frame's events go, and this frame's become last frame's.
    for (self.event_channels.values()) |channel| channel.update(channel.events);
    self.resized = false;

    if (self.window) |*window| {
        if (!window.pump(&self.input)) {
            self.running = false;
            return false;
        }
        if (window.resized) {
            window.resized = false;
            try self.adoptSize(window.width, window.height);
        }
    }
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
    self.debug_frame.advance(self.time.delta);
    self.debug_under_frame.advance(self.time.delta);
    if (self.hasInterface()) try self.feedInterface();

    // What was asked for outside any system - between frames, by a tool -
    // is done before the first system of this one, and then the states
    // change that the last frame asked to.
    try self.commands.apply();
    try self.changeStates();

    // Bodies are synced before each fixed step. A paused frame - and the
    // first, which has no time to step - is synced here instead, so the
    // queries find what was spawned.
    self.bodies.beginFrame();
    if (self.time.delta == 0) try self.bodies.sync(self);

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
            self.debug_steps.advance(self.time.fixed_delta);
            self.debug_under_steps.advance(self.time.fixed_delta);
            // Where everything was before this step, to draw between steps.
            try self.snapshotPrevious();
            try self.schedule.run(.fixed, self);
            try self.stepPhysics();
            // Seen, so gone: the next step hears only what comes after.
            self.input.endFixedStep();
        }
    }
    // A paused frame gives the fixed stage no time, and so no edges: a key
    // pressed on a pause menu must not reach the first step after it.
    if (self.time.delta == 0) self.input.endFixedStep();

    try self.schedule.run(.update, self);
    try self.schedule.run(.late, self);
    // Deferred signal calls, Godot's idle time: after `.late`, before the
    // engine's own passes, so what they despawn is gone by the draw.
    try self.signals.flushDeferred(self);

    // The engine's own passes, after the game's `.late` systems and before
    // drawing: whatever hung from something despawned goes with it, and then
    // the names of everything that died are given back.
    try self.despawnOrphans();
    self.forgetDeadNames();
    self.forgetDeadUuids();
    self.signals.forgetDead(&self.world);
    try self.animate();
    if (self.debug_visible and self.debug_views.any()) try self.debug_views.draw(self);

    if (self.hasInterface()) try self.layOutInterface();

    // Nothing to draw on while Android has taken the surface away.
    const minimized = self.windowState() == .minimized;
    if (!minimized and !self.input.surface_lost) try self.render();

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
    try self.signals.drain(self);
}

fn waitForNextFrame(self: *App, minimized: bool) !void {
    const target_fps: f32 = if (minimized) fps_while_minimized else self.time.max_fps orelse return;
    try self.time.sleepUntilNextFrame(target_fps);
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
    if (self.interfaceFace()) |face| self.ui.setMeasurer(Interface.measurer(face));
    // Asked of the system when the wheel turned, so a changed setting is
    // taken at once - and only then, since on Linux asking reads a file.
    if (self.input.wheel.x != 0 or self.input.wheel.y != 0) {
        if (self.window) |*window| self.interface.scroll_lines = window.scrollLines();
    }
    try self.interface.feed(self.gpa, &self.ui, &self.input, &self.clipboard, self.time.unscaled_delta);
}

fn layOutInterface(self: *App) !void {
    self.interface.commands = &.{};
    self.ui.begin(self.interface.surface(@floatFromInt(self.width), @floatFromInt(self.height)));
    {
        // One root for every `.ui` system: fluxion-ui makes the first element
        // the root, so a second system's would land beside it. `.grow`,
        // because fluxion-ui gives a `.fit` root its content's height.
        self.ui.open(.{ .width = .grow, .height = .grow });
        defer self.ui.close();
        try self.schedule.run(.ui, self);
    }
    self.interface.commands = try self.ui.end();
    if (self.window) |*window| {
        self.interface.applyCursor(&self.ui, window);
        self.interface.applyTextInput(&self.ui, window);
    }
}

/// The interface's scale for this frame: the game's `zoom` times the
/// display's, which it follows unless told not to - and 1 with no window.
fn fitInterface(self: *App) void {
    const display: f32 = if (self.window) |*window|
        (if (self.interface.follow_display) window.content_scale else 1)
    else
        1;
    self.interface.display_scale = display;
    self.interface.scale = self.interface.zoom * display;
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

fn interfaceFace(self: *App) ?*const typeface.Font {
    const font = self.assets.fontOf(self.interface.font) orelse return null;
    return &font.face;
}

/// Take a new size from the window: the numbers, the flag, and the swapchain.
fn adoptSize(self: *App, width: u32, height: u32) !void {
    self.width = width;
    self.height = height;
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

/// Step every `Animation` and write the cell it landed on into its `Sprite`.
/// On the frame's delta: an animation is seen, not simulated.
fn animate(self: *App) !void {
    const delta = self.time.delta;

    var it = try ecs.Query(.{ components.Sprite, components.Animation }).over(&self.world);
    while (it.next()) |chunk| {
        for (chunk.slice(components.Sprite), chunk.slice(components.Animation)) |*drawn, *animation| {
            drawn.region = animation.advance(delta);
        }
    }
}

/// Despawn everything whose parent has died, and what hangs from that in
/// turn; see `Transform2D.parent`. Once a frame, because a game despawns
/// through `world.despawn` and nothing here sees it. It goes round until a
/// pass finds nothing, so a turret's barrel goes one pass after the turret.
fn despawnOrphans(self: *App) !void {
    while (true) {
        self.orphans.clearRetainingCapacity();

        var it = try ecs.Query(.{components.Transform2D}).over(&self.world);
        while (it.next()) |chunk| {
            for (chunk.slice(components.Transform2D), chunk.entities) |place, entity| {
                if (place.parent.isNone() or self.world.isAlive(place.parent)) continue;
                try self.orphans.append(self.gpa, entity);
            }
        }

        // Found first and despawned after: a despawn moves rows, and the
        // slices above point at rows.
        if (self.orphans.items.len == 0) return;
        for (self.orphans.items) |orphan| self.world.despawn(orphan);
    }
}

/// Where an entity really is, with every parent above it applied: Godot's
/// `global_position`. Null when it has no transform, or when something it
/// hangs from was despawned this frame. The result has no parent, so writing
/// it over the entity's own transform lets go while keeping it in place.
pub fn worldTransform(self: *App, entity: ecs.Entity) ?components.Transform2D {
    return hierarchy.resolveEntity(&self.world, &self.snapshots, entity, self.time.alpha());
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
    /// Another living entity is called that. A name picks out one thing.
    NameTaken,
    /// The entity has been despawned, or never was.
    NoSuchEntity,
} || Allocator.Error;

/// Call an entity something, so that `find` can come back to it.
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
/// The name is the entity's own, as a Unity GameObject's is, not a
/// component: naming does not move the entity to another archetype. One
/// living entity to a name - another is `error.NameTaken` - because `find`
/// hands back one. A despawned entity's name is free at once, and calling
/// this again renames. The text is copied. `ecs.save` does not write names.
pub fn setName(self: *App, entity: ecs.Entity, name: []const u8) NameError!void {
    if (!self.world.isAlive(entity)) return error.NoSuchEntity;

    var stale: ?ecs.Entity = null;
    if (self.by_name.get(name)) |holder| {
        if (holder.eql(entity)) return;
        if (self.world.isAlive(holder)) return error.NameTaken;
        // Despawned and not yet forgotten: the name is free.
        stale = holder;
    }

    // Everything that can fail comes before anything changes, so a failed
    // rename keeps the old name. The copy comes first of all, because `name`
    // may point into a name that is about to be freed.
    const copy = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(copy);
    try self.names.ensureUnusedCapacity(self.gpa, 1);
    try self.by_name.ensureUnusedCapacity(self.gpa, 1);

    if (stale) |holder| self.forgetName(holder);
    const slot = self.names.getOrPutAssumeCapacity(entity);
    if (slot.found_existing) {
        _ = self.by_name.remove(slot.value_ptr.*);
        self.gpa.free(slot.value_ptr.*);
    }
    slot.value_ptr.* = copy;
    self.by_name.putAssumeCapacityNoClobber(copy, entity);
}

/// What an entity is called, or null when it has no name or is not alive.
/// The text lasts until the entity is renamed or despawned.
pub fn nameOf(self: *const App, entity: ecs.Entity) ?[]const u8 {
    if (!self.world.isAlive(entity)) return null;
    return self.names.get(entity);
}

/// The living entity called `name`, or null. Cheap enough to ask every
/// frame. See `setName`.
///
/// ```zig
/// const player = app.find("player") orelse return;
/// ```
pub fn find(self: *const App, name: []const u8) ?ecs.Entity {
    const entity = self.by_name.get(name) orelse return null;
    return if (self.world.isAlive(entity)) entity else null;
}

/// Take one entity's name off it, if it has one, and free the text.
fn forgetName(self: *App, entity: ecs.Entity) void {
    const named = self.names.fetchSwapRemove(entity) orelse return;
    _ = self.by_name.remove(named.value);
    self.gpa.free(named.value);
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

/// Read a scene into the world, beside whatever is in it already, and say
/// what came of it. See `scene`.
///
/// ```zig
/// var diagnostics: fx.json.Diagnostics = .{};
/// _ = app.loadScene("levels/meadow.json", .{ .diagnostics = &diagnostics }) catch |err| {
///     std.log.err("{f}", .{diagnostics});
///     return err;
/// };
/// ```
pub fn loadScene(self: *App, path: []const u8, options: scene.LoadOptions) !scene.Loaded {
    const io = self.io orelse return error.NoIo;
    return scene.load(self, io, path, options);
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
    const io = self.io orelse return error.NoIo;
    const file = try self.project.osPath(self.gpa, path);
    defer self.gpa.free(file);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file, self.gpa, .unlimited);
    defer self.gpa.free(bytes);
    return scene.readInfo(self.gpa, bytes, diagnostics);
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
    for (self.names.values()) |name| self.gpa.free(name);
    self.names.clearRetainingCapacity();
    self.by_name.clearRetainingCapacity();
    self.uuids.clearRetainingCapacity();
    self.by_uuid.clearRetainingCapacity();
    self.signals.clear();
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

/// Take the component called `name` off an entity. One it has not got does
/// nothing. Not from inside a query either.
pub fn removeComponentNamed(self: *App, entity: ecs.Entity, name: []const u8) ComponentError!void {
    const entry = self.scene_components.find(name) orelse return error.NoSuchComponent;
    try entry.removeFrom(&self.world, entity);
}

fn valueOf(self: *App, entity: ecs.Entity, entry: *const scene.Registry.Entry) ?reflect.Value {
    const id = entry.findIdIn(&self.world) orelse return null;
    const cell = self.world.cellOf(entity, id) orelse return null;
    return .init(entry.type, cell);
}

/// `App` as fluxion-reflect sees it: no insides, and the calls a console, a
/// script or an editor's command palette may make by name - see `callNamed`.
/// A call is listed when it takes and gives plain values: the ones taking a
/// type or a function, or holding an allocator, are for Zig to call. Only a
/// program that asks for this descriptor has them compiled in; see `types`.
pub const reflect_name = "App";
pub const reflect_opaque = true;
pub const reflect_methods = .{
    .quit,
    .setName,
    .nameOf,
    .find,
    .clearWorld,
    .addComponentNamed,
    .removeComponentNamed,
    .stateNamed,
    .setStateNamed,
    .saveScene,
    .loadScene,
    .worldTransform,
    .screenToWorld,
    .worldToScreen,
    .pointerInWorld,
    .overlapPoint,
    .setFullscreen,
    .fullscreen,
    .toggleFullscreen,
    .setWindowTitle,
    .setWindowSize,
    .setWindowPosition,
    .windowPosition,
    .setWindowState,
    .windowState,
    .setVsync,
    .vsync,
    .setCursor,
    .cursor,
    .setCursorShape,
    .setClipboardText,
    .clipboardText,
    .hasClipboardText,
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
    var held: [64]u8 align(16) = undefined;
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
// Godot's signals, on components, and the typed events the engine's own
// are made from. See `signals.zig` and `events.zig`.

pub const Signal = signals_mod.Signal;

/// The signal `name` that `C` declares, of `entity`: Godot's
/// `entity.name`, checked as it is compiled.
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
    return found orelse error.NoSuchSignal;
}

/// `signalNamed`, emitted with values: what a console or a script emits.
pub fn emitNamed(self: *App, entity: ecs.Entity, name: []const u8, values: []const reflect.Value) signals_mod.Error!void {
    return (try self.signalNamed(entity, name)).emitValues(values);
}

/// Whether one of `entity`'s components declares a signal by that name.
/// Godot's `has_signal`.
pub fn hasSignal(self: *App, entity: ecs.Entity, name: []const u8) bool {
    _ = self.signalNamed(entity, name) catch |err| return err == error.AmbiguousSignal;
    return true;
}

/// Every signal `entity` has, component by component in the order they
/// were registered, as many as `found` holds. Godot's `get_signal_list`.
pub fn signalsOf(self: *App, entity: ecs.Entity, found: []signals_mod.Info) []signals_mod.Info {
    var count: usize = 0;
    var held: [64]ComponentValue = undefined;
    for (self.componentsOf(entity, &held)) |component| {
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
/// reads back. A disconnect and a connect again puts one last, as Godot's
/// Edit Connection does. Godot's `get_signal_connection_list`, over all.
pub fn connectionsFrom(self: *App, source: ecs.Entity, found: []signals_mod.Connection) []signals_mod.Connection {
    const listed = self.signals.connectionsFrom(source, found);
    for (listed) |*c| c.signal = self.signalWritten(c.*);
    return listed;
}

/// Every connection to a method of `receiver`. Godot's
/// `get_incoming_connections`.
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

/// Whether `entity`'s emits do nothing. Godot's `set_block_signals`.
pub fn setBlockSignals(self: *App, entity: ecs.Entity, on: bool) Allocator.Error!void {
    if (on) try self.signals.blocked.put(self.gpa, entity, {}) else _ = self.signals.blocked.remove(entity);
}

pub fn isBlockingSignals(self: *const App, entity: ecs.Entity) bool {
    return self.signals.blocked.contains(entity);
}

/// Let a signal's connection call `f` by `name`, when no component of the
/// target has a method by it: `fn (app: *App, self: fx.Entity, ...) !void`,
/// `self` the entity connected to - Godot's implicit one - and after it what
/// the connection hands on. The values are converted to the parameters as
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
/// else one given to `addMethod`.
pub fn callMethodOn(self: *App, receiver: ecs.Entity, name: []const u8, args: []const reflect.Value) anyerror!void {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    const component: ?[]const u8 = if (dot) |at| name[0..at] else null;
    const method = if (dot) |at| name[at + 1 ..] else name;

    var owner: ?reflect.Value = null;
    var held: [64]ComponentValue = undefined;
    for (self.componentsOf(receiver, &held)) |found| {
        if (component) |wanted| {
            if (!std.mem.eql(u8, found.name, wanted)) continue;
        }
        if (found.value.type.method(method) == null) continue;
        if (owner != null) return error.AmbiguousMethod;
        owner = found.value;
    }
    if (owner) |value| return callValue(value, method, args, null);
    if (component == null) {
        if (self.signals.methods.get(name)) |m| return m.call(self, receiver, args);
    }
    return error.NoSuchMethod;
}

/// Whether a connection naming `name` would find a method on `receiver`:
/// one of its components', or one given to `addMethod`.
pub fn hasMethod(self: *App, receiver: ecs.Entity, name: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    const method = if (dot) |at| name[at + 1 ..] else name;
    var held: [64]ComponentValue = undefined;
    for (self.componentsOf(receiver, &held)) |found| {
        if (dot) |at| {
            if (!std.mem.eql(u8, found.name, name[0..at])) continue;
        }
        if (found.value.type.method(method) != null) return true;
    }
    return dot == null and self.signals.methods.contains(name);
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

/// Where the pointer is in the world.
pub fn pointerInWorld(self: *App) math.Vec2 {
    return self.screenToWorld(self.input.pointer.x, self.input.pointer.y);
}

/// Where an entity's sprite is drawn, as its four corners in the world, round
/// from the texture's top left - turned, scaled and carried by its parents
/// as the renderer does it. Null for an entity with no sprite, or none that
/// can be placed. What a click on a sprite is tested against.
pub fn spriteCorners(self: *App, entity: ecs.Entity) ?[4]math.Vec2 {
    const drawn = (self.world.get(entity, components.Sprite) orelse return null).*;
    const placed = self.worldTransform(entity) orelse return null;
    const texture = self.assets.get(drawn.texture) orelse self.assets.get(self.assets.white) orelse return null;
    return sprite.cornersOf(drawn, placed, texture);
}

/// Where an entity's label is drawn, as its four corners in the world, round
/// from the top left of its first line - turned, scaled and carried by its
/// parents as the renderer does it. The box its lines are laid out in, not
/// the ink. Null for an entity with no `Text2D`, one with nothing to draw,
/// or one that cannot be placed.
pub fn textCorners(self: *App, entity: ecs.Entity) ?[4]math.Vec2 {
    const label = (self.world.get(entity, components.Text2D) orelse return null).*;
    const placed = self.worldTransform(entity) orelse return null;
    const face = self.assets.fontOf(label.font) orelse return null;
    return sprite.labelCornersOf(label, placed, face);
}

/// Whichever of the two an entity is drawn as: its sprite's corners, else
/// its label's. What an editor outlines, frames and tests a click against
/// without asking which it is.
pub fn drawnCorners(self: *App, entity: ecs.Entity) ?[4]math.Vec2 {
    return self.spriteCorners(entity) orelse self.textCorners(entity);
}

/// What the camera sees, at the size of the window.
fn currentView(self: *App) View {
    return .of(&self.world, &self.snapshots, @floatFromInt(self.width), @floatFromInt(self.height));
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
pub fn castRay(self: *App, from: math.Vec2, to: math.Vec2, filter: physics_lib.Filter) ?Bodies.RayHit {
    return self.bodies.castRay(self, from, to, filter);
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

/// Whose collision object a collider is a shape of: Godot's
/// `CollisionObject2D` of a shape, and what an area's signals name. The
/// collider's own entity when that has an `Area2D` or a `RigidBody2D`, else
/// the nearest one above it that has, else its own entity, which is its own
/// static body. Null for an entity that is neither.
pub fn collisionObjectOf(self: *App, collider: ecs.Entity) ?ecs.Entity {
    return Bodies.objectOf(&self.world, collider);
}

/// The bodies inside `area` now, as many as `found` holds: Godot's
/// `get_overlapping_bodies`. Empty, with a word in the log, for an area that
/// is not monitoring.
pub fn overlappingBodies(self: *App, area: ecs.Entity, found: []ecs.Entity) []ecs.Entity {
    return self.areas.overlapping(self, area, false, found);
}

/// The other areas inside `area` now: Godot's `get_overlapping_areas`.
pub fn overlappingAreas(self: *App, area: ecs.Entity, found: []ecs.Entity) []ecs.Entity {
    return self.areas.overlapping(self, area, true, found);
}

/// Whether anything at all is inside `area`: Godot's `has_overlapping_bodies`.
pub fn hasOverlappingBodies(self: *App, area: ecs.Entity) bool {
    return self.areas.any(self, area, false);
}

/// Whether another area is inside it: Godot's `has_overlapping_areas`.
pub fn hasOverlappingAreas(self: *App, area: ecs.Entity) bool {
    return self.areas.any(self, area, true);
}

/// Whether that body is inside it: Godot's `overlaps_body`.
pub fn overlapsBody(self: *App, area: ecs.Entity, body: ecs.Entity) bool {
    return self.areas.overlaps(self, area, body);
}

/// Whether that area is inside it: Godot's `overlaps_area`.
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

/// Fill the screen, or go back to being a window, on the monitor the window
/// is on. `.borderless` is what a game should use; see `Fullscreen`. The new
/// size arrives at the top of the next frame. Nothing without a window.
pub fn setFullscreen(self: *App, wanted: Fullscreen) Window.Error!void {
    if (self.window) |*window| try window.setFullscreen(wanted);
}

/// How the window fills the screen now. `.windowed` when there is no window.
pub fn fullscreen(self: *const App) Fullscreen {
    if (self.window) |*window| return window.fullscreen();
    return .windowed;
}

/// Borderless if it is a window, a window if it is not.
pub fn toggleFullscreen(self: *App) Window.Error!void {
    try self.setFullscreen(switch (self.fullscreen()) {
        .windowed => .borderless,
        else => .windowed,
    });
}

/// What the title bar says. Nothing without a window.
pub fn setWindowTitle(self: *App, title: []const u8) Window.Error!void {
    if (self.window) |*window| try window.setTitle(title);
}

/// Make the window's content area this size, in pixels. A fullscreen,
/// maximised or minimised window becomes an ordinary one first. The new size
/// arrives at the top of the next frame. Nothing without a window.
pub fn setWindowSize(self: *App, width: u32, height: u32) Window.Error!void {
    if (self.window) |*window| try window.setSize(width, height);
}

/// Put the top left of the window's content area at this point of the
/// desktop. Nothing without a window.
pub fn setWindowPosition(self: *App, x: i32, y: i32) Window.Error!void {
    if (self.window) |*window| try window.setPosition(x, y);
}

/// Where the top left of the window's content area is on the desktop, or
/// null when there is no window. Always nought, nought on Wayland.
pub fn windowPosition(self: *const App) ?[2]i32 {
    if (self.window) |*window| return window.position();
    return null;
}

/// How small and how large the player may drag the window. A window already
/// outside the limits is brought inside them at once. Nothing without a
/// window.
pub fn setWindowSizeLimits(self: *App, limits: WindowSizeLimits) Window.Error!void {
    if (self.window) |*window| try window.setSizeLimits(limits);
}

/// Maximise the window, minimise it, or put it back. Nothing without a
/// window.
pub fn setWindowState(self: *App, wanted: WindowState) Window.Error!void {
    if (self.window) |*window| try window.setState(wanted);
}

/// Whether the window is at its own size, maximised, or minimised. `.normal`
/// when there is no window.
pub fn windowState(self: *const App) WindowState {
    if (self.window) |*window| return window.state();
    return .normal;
}

pub fn setVsync(self: *App, on: bool) (rhi.Error || Window.Error)!void {
    self.vsync_on = on;
    if (self.surface) |surface| try self.device.setVsync(surface, on);
    if (self.window) |*window| try window.setVsync(on);
}

pub fn vsync(self: *const App) bool {
    return self.vsync_on;
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

/// Use one of the system's own pointer shapes over the window. Nothing
/// without a window.
pub fn setCursorShape(self: *App, shape: CursorShape) Window.Error!void {
    if (self.window) |*window| try window.setCursorShape(shape);
}

/// A picture of the game's own for the pointer, with the point in it that
/// does the pointing; null puts the shape back. Godot's
/// `Input.set_custom_mouse_cursor`. Nothing without a window.
///
/// ```zig
/// const sword = app.assets.get(cursor_texture).?;
/// try app.setCursorImage(.{ .pixels = pixels, .width = 32, .height = 32, .hot_x = 4, .hot_y = 2 });
/// ```
///
/// A browser quietly keeps its own arrow past a size of its own - 128 by
/// 128 in Chrome and Firefox - so a cursor a page will see should be small.
pub fn setCursorImage(self: *App, picture: ?platform.CursorImage) Window.Error!void {
    if (self.window) |*window| try window.setCursorImage(picture);
}

/// The window's own picture, in the title bar, the task switcher and the
/// dock: several sizes at once, and the system takes the one it wants. An
/// empty list puts the system's own back. Nothing without a window, and
/// `error.Unavailable` on Wayland, where a window's picture comes from its
/// desktop file, and on Android.
pub fn setWindowIcon(self: *App, images: []const platform.IconImage) Window.Error!void {
    if (self.window) |*window| try window.setIcon(images);
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

/// Put the pointer there, in framebuffer pixels: Godot's `warp_mouse`. The
/// system takes a moment to say it moved, so `input.pointer` is set here as
/// well. Nothing without a window, save moving what a test reads.
pub fn warpPointer(self: *App, x: f32, y: f32) void {
    if (self.window) |*window| {
        window.setCursorPos(x, y) catch |err| {
            log.warn("could not put the pointer at {d},{d}: {t}", .{ x, y, err });
            return;
        };
    }
    self.input.pointer.x = x;
    self.input.pointer.y = y;
}

/// Where the pointer is in an entity's own space: Godot's
/// `get_local_mouse_position`. Null for an entity that is not there, or
/// whose chain of parents is broken.
///
/// ```zig
/// const at = app.pointerIn(dial) orelse return;
/// dial_angle = std.math.atan2(at.y, at.x);
/// ```
pub fn pointerIn(self: *App, entity: ecs.Entity) ?math.Vec2 {
    return self.pointIn(entity, self.pointerInWorld());
}

/// The same for any point in the world.
pub fn pointIn(self: *App, entity: ecs.Entity, point: math.Vec2) ?math.Vec2 {
    const place = self.worldTransform(entity) orelse return null;
    const local = place.unapply(point.x, point.y);
    return .init(local.x, local.y);
}

/// A pointer event as an entity sees it: the same event, with its place in
/// that entity's own space rather than the window's. Godot's
/// `make_input_local`.
pub fn localEvent(self: *App, entity: ecs.Entity, event: pointer.InputEvent) pointer.InputEvent {
    const at = self.screenToWorld(event.position().x, event.position().y);
    const local = self.pointIn(entity, at) orelse return event;
    var made = event;
    switch (made) {
        inline else => |*held| held.position = local,
    }
    return made;
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
        for (chunk.slice(components.Transform2D), chunk.entities) |now, entity| {
            if (!now.interpolate) continue;
            try self.snapshots.put(self.gpa, entity, .of(now));
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
fn drawLayers(self: *App, into: rhi.RenderTarget, width: f32, height: f32) !void {
    // 1. The 3D layer, with a depth test, clearing the frame. Not written
    //    yet; when it is, the 2D pass below stops clearing.

    // 2. The 2D layer: sprites and text, sorted back to front, blended, no
    //    depth - or, with the world off the screen, only the clearing.
    const view: View = .of(&self.world, &self.snapshots, width, height);
    if (self.world_on_screen) {
        const clear = try self.drawDebugUnder(into, view);
        try self.sprites.draw(self.gpa, &self.world, &self.assets, &self.snapshots, into, view, clear, self.time.alpha());
    } else try self.clearTarget(into);

    // 3. The interface, on top, loading what the 2D layer left - with its
    //    glyphs drawn again when a font was read again since.
    if (self.interface.font_reloads != self.assets.font_reloads) {
        self.interface.forgetRenderer();
        self.interface.font_reloads = self.assets.font_reloads;
    }
    try self.interface.draw(self.gpa, &self.device, self.interfaceFace(), into, width, height);

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
    const clear = try self.drawDebugUnder(.{ .texture = into }, view);
    try self.sprites.draw(self.gpa, &self.world, &self.assets, &self.snapshots, .{ .texture = into }, view, clear, self.time.alpha());
    if (self.debug_visible) try self.drawDebug(.{ .texture = into }, view);
}

/// Whether a texture `drawWorld` drew into comes out upside down when drawn
/// as a picture: true on OpenGL, whose framebuffers count rows from the
/// bottom.
pub fn drawnUpsideDown(self: *const App) bool {
    return switch (self.device.backendTag()) {
        .gl, .webgl => true,
        .d3d11, .none => false,
    };
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

/// Read the frame that was last drawn, as `width * height * 4` bytes the
/// caller owns. Headless only: a swapchain image cannot be read back on every
/// backend.
pub fn readFrame(self: *App, gpa: Allocator) ![]u8 {
    const texture = self.offscreen orelse return error.NotHeadless;
    return self.device.readTexture(texture, gpa);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const components = @import("components.zig");
const Region = components.Region;

fn spawnOne(app: *App) anyerror!void {
    _ = try app.world.spawnWith(.{
        components.Transform2D.at(64, 64),
        components.Sprite.solid(.hex(0xFF0000), 32, 32),
    });
}

fn countFrames(app: *App) anyerror!void {
    const counted = struct {
        var frames: u32 = 0;
    };
    counted.frames += 1;
    if (counted.frames >= 3) app.quit();
}

test "a headless app runs its stages and draws" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .width = 64,
        .height = 64,
        // Without this, or a system that calls `quit`, `run` never ends.
        .frames = 1,
    });
    defer app.destroy();

    try app.addSystem(.startup, "spawn one", spawnOne);
    try app.run();

    try testing.expectEqual(@as(usize, 1), app.world.count());
    // One sprite, one texture, one draw call.
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
    try testing.expectEqual(@as(u32, 1), app.sprites.draw_calls);
}

test "a sprite nowhere near the camera is not drawn" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 1,
        .width = 320,
        .height = 240,
    });
    defer app.destroy();

    // With no camera, the view is the window.
    _ = try app.world.spawnWith(.{
        components.Transform2D.at(160, 120),
        components.Sprite.solid(.white, 16, 16),
    });
    _ = try app.world.spawnWith(.{
        components.Transform2D.at(9000, 9000),
        components.Sprite.solid(.white, 16, 16),
    });

    try app.run();

    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
    try testing.expectEqual(@as(u32, 1), app.sprites.culled);
}

test "the world is drawn into a texture through a view of its own" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240 });
    defer app.destroy();
    _ = try app.world.spawnWith(.{
        components.Transform2D.at(1000, 1000),
        components.Sprite.solid(.white, 16, 16),
    });
    const panel = try app.device.createTexture(.{
        .width = 64,
        .height = 64,
        .usage = .{ .sampled = true, .render_target = true },
    });
    defer app.device.destroyTexture(panel);

    // The window's view is nowhere near it; this one is right over it.
    var view: View = .screen(64, 64);
    view.x = 1000;
    view.y = 1000;
    try app.drawWorld(panel, view);
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);

    view.x = 0;
    try app.drawWorld(panel, view);
    try testing.expectEqual(@as(u32, 0), app.sprites.drawn);
    try testing.expectEqual(@as(u32, 1), app.sprites.culled);
    try testing.expect(!app.drawnUpsideDown());
}

test "with the world off the screen, a frame draws none of it" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1, .width = 320, .height = 240 });
    defer app.destroy();
    app.world_on_screen = false;
    _ = try app.world.spawnWith(.{
        components.Transform2D.at(160, 120),
        components.Sprite.solid(.white, 16, 16),
    });

    try app.run();
    try testing.expectEqual(@as(u32, 0), app.sprites.drawn);
    try testing.expectEqual(@as(u32, 0), app.sprites.draw_calls);
}

test "clearing the world leaves nothing in it, and frees every name" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const door = try app.world.spawnWith(.{components.Transform2D.at(1, 2)});
    try app.setName(door, "door");
    _ = try app.world.spawnWith(.{components.Transform2D.childOf(door, 0, 1)});

    app.clearWorld();
    try testing.expectEqual(@as(usize, 0), app.world.count());
    try testing.expect(app.find("door") == null);

    // A fresh world hands out the same handles again, and none of them may
    // come with an old name.
    const again = try app.world.spawnWith(.{components.Transform2D.at(3, 4)});
    try testing.expect(again.eql(door));
    try testing.expect(app.nameOf(again) == null);
    try app.setName(again, "door");
    try testing.expect(app.find("door").?.eql(again));
}

test "a sprite half off the edge is still drawn" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 1,
        .width = 320,
        .height = 240,
    });
    defer app.destroy();

    _ = try app.world.spawnWith(.{
        components.Transform2D.at(-4, 120),
        components.Sprite.solid(.white, 40, 40),
    });

    try app.run();

    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
    try testing.expectEqual(@as(u32, 0), app.sprites.culled);
}

test "a label with no font loaded draws nothing and does not fall over" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    _ = try app.world.spawnWith(.{
        components.Transform2D.at(10, 10),
        components.Text2D.of("nobody can read this"),
    });

    try app.run();
    try testing.expectEqual(@as(u32, 0), app.sprites.drawn);
}

test "a label becomes one quad per letter" {
    // A real font off this machine; skipped where there is none, as on a
    // build server.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 1,
        .width = 320,
        .height = 240,
        .io = threaded.io(),
    });
    defer app.destroy();

    _ = app.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 256 }) catch
        return error.SkipZigTest;

    _ = try app.world.spawnWith(.{
        components.Transform2D.at(20, 20),
        components.Text2D.of("Hi!"),
    });

    try app.run();

    // Three letters, three quads, and three glyphs in the atlas.
    try testing.expectEqual(@as(u32, 3), app.sprites.drawn);
    const face = app.assets.fontOf(.none).?;
    try testing.expectEqual(@as(usize, 3), face.atlas.count());

    // The second frame rasterises none of them again.
    app.running = true;
    app.frames_left = 1;
    _ = try app.step();
    try testing.expectEqual(@as(usize, 3), face.atlas.count());
}

test "the frame count ends the loop" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 5 });
    defer app.destroy();

    try app.run();
    try testing.expectEqual(@as(u64, 5), app.time.frame);
}

test "quitting from a system ends the loop" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    try app.addSystem(.update, "count frames", countFrames);
    try app.run();

    try testing.expect(!app.running);
    try testing.expectEqual(@as(u64, 3), app.time.frame);
}

test "a child is where its parent put it, and its own numbers stay local" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    const tank = try app.world.spawnWith(.{
        components.Transform2D.at(100, 50),
        components.Sprite.solid(.white, 20, 20),
    });
    const turret = try app.world.spawnWith(.{
        components.Transform2D.childOf(tank, 0, -12),
        components.Sprite.solid(.white, 8, 8),
    });

    try app.run();

    const placed = app.worldTransform(turret).?;
    try testing.expectApproxEqAbs(@as(f32, 100), placed.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 38), placed.y, 0.0001);

    // The component still holds its own local numbers.
    const local = app.world.get(turret, components.Transform2D).?;
    try testing.expectEqual(@as(f32, 0), local.x);
    try testing.expectEqual(@as(f32, -12), local.y);
}

test "a grandchild is composed through the whole chain" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    const root = try app.world.spawnWith(.{components.Transform2D.at(10, 0)});
    const middle = try app.world.spawnWith(.{components.Transform2D.childOf(root, 5, 0)});
    const leaf = try app.world.spawnWith(.{components.Transform2D.childOf(middle, 2, 0)});

    try app.run();
    try testing.expectApproxEqAbs(@as(f32, 17), app.worldTransform(leaf).?.x, 0.0001);
}

test "what hangs from something that died goes with it" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    const tank = try app.world.spawnWith(.{
        components.Transform2D.at(100, 50),
        components.Sprite.solid(.white, 20, 20),
    });
    const turret = try app.world.spawnWith(.{
        components.Transform2D.childOf(tank, 0, -12),
        components.Sprite.solid(.white, 8, 8),
    });
    const barrel = try app.world.spawnWith(.{
        components.Transform2D.childOf(turret, 10, 0),
        components.Sprite.solid(.white, 12, 2),
    });
    const bystander = try app.world.spawnWith(.{
        components.Transform2D.at(20, 20),
        components.Sprite.solid(.white, 4, 4),
    });

    app.world.despawn(tank);
    // Until the end of the frame, the chain is broken and says so.
    try testing.expect(app.worldTransform(turret) == null);

    try app.run();

    // The turret went because the tank did, and the barrel one pass later.
    try testing.expect(!app.world.isAlive(turret));
    try testing.expect(!app.world.isAlive(barrel));
    try testing.expect(app.world.isAlive(bystander));

    // And only the bystander was drawn.
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
}

test "a parent with no transform places nothing and still owns what hangs from it" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    // An entity with no components at all.
    const spell = try app.world.spawn();
    const spark = try app.world.spawnWith(.{
        components.Transform2D.childOf(spell, 40, 30),
        components.Sprite.solid(.white, 4, 4),
    });

    try app.run();

    // Its numbers are the world's, as if it had no parent...
    const placed = app.worldTransform(spark).?;
    try testing.expectEqual(@as(f32, 40), placed.x);
    try testing.expectEqual(@as(f32, 30), placed.y);
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);

    // ... and it still goes when its parent does.
    app.world.despawn(spell);
    app.running = true;
    app.frames_left = 1;
    _ = try app.step();
    try testing.expect(!app.world.isAlive(spark));
}

test "an animation moves the sprite's region on" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 6,
        // Six frames of a tenth of a second, at ten cells a second: once
        // round a four-cell strip, and two more.
        .fixed_delta = 0.1,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.1 };

    const walker = try app.world.spawnWith(.{
        components.Transform2D{},
        components.Sprite.solid(.white, 8, 8),
        components.Animation.strip(4, 10),
    });

    try app.run();

    const showing = app.world.get(walker, components.Sprite).?.region;
    try testing.expectApproxEqAbs(Region.cell(2, 4, 1).u0, showing.u0, 0.0001);
}

test "a fixed step runs as many times as the frame is worth" {
    const counter = struct {
        var steps: u32 = 0;
        fn count(_: *App) anyerror!void {
            steps += 1;
        }
    };
    counter.steps = 0;

    // Frames of a fiftieth of a second, steps of a hundredth: two a frame.
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 10,
        .fixed_delta = 0.01,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.02 };

    try app.addSystem(.fixed, "count", counter.count);
    try app.run();

    try testing.expectEqual(@as(u32, 20), counter.steps);
}

fn spawnInterpolated(app: *App) anyerror!void {
    var moving: components.Transform2D = .at(0, 0);
    moving.interpolate = true;
    _ = try app.world.spawnWith(.{
        moving,
        components.Sprite.solid(.hex(0xFF0000), 8, 8),
    });
}

fn slideRight(app: *App) anyerror!void {
    var it = try ecs.Query(.{components.Transform2D}).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(components.Transform2D)) |*t| t.x += 10;
    }
}

test "a previous transform is taken before each fixed step" {
    // A frame is worth one and a half steps: one runs, and half a step is
    // left to blend by.
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 1,
        .fixed_delta = 0.01,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.015 };

    try app.addSystem(.startup, "spawn interpolated", spawnInterpolated);
    try app.addSystem(.fixed, "slide right", slideRight);
    try app.run();

    var it = try ecs.Query(.{components.Transform2D}).over(&app.world);
    const chunk = it.next().?;
    const entity = chunk.entities[0];
    const now = chunk.slice(components.Transform2D)[0];

    // Where it is, where it was, and halfway between: what is drawn.
    try testing.expectEqual(@as(f32, 10), now.x);
    try testing.expectEqual(@as(f32, 0), app.snapshots.get(entity).?.x);
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.time.alpha(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), app.worldTransform(entity).?.x, 0.01);
}

test "a transform that never asked is not remembered at all" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 2,
        .fixed_delta = 0.01,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.05 };

    _ = try app.world.spawnWith(.{components.Transform2D.at(0, 0)});
    try app.run();

    try testing.expectEqual(@as(usize, 0), app.snapshots.count());
}

/// A key going down, as the platform would deliver it.
fn pressOf(key: platform.Key) platform.Event {
    return .{ .key = .{
        .window = .none,
        .key = key,
        .scancode = @enumFromInt(0),
        .action = .press,
        .mods = .{},
    } };
}

/// One press of space on a chosen frame, and a count of the fixed steps
/// that heard it.
const Jumps = struct {
    var heard: u32 = 0;
    var press_on: u64 = 1;

    fn press(app: *App) anyerror!void {
        if (app.time.frame == press_on) app.input.apply(pressOf(.space));
    }

    fn jump(app: *App) anyerror!void {
        if (app.input.justPressed(.space)) heard += 1;
    }

    /// Start the world again on the fourth frame. See the pause test.
    fn wake(app: *App) anyerror!void {
        if (app.time.frame == 4) app.time.scale = 1;
    }
};

test "a press is heard by one fixed step when frames are shorter than steps" {
    Jumps.heard = 0;
    Jumps.press_on = 1;

    // A frame is half a step long, so the frame the press lands on runs no
    // step. Powers of two keep the accumulator exact.
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 8,
        .fixed_delta = 1.0 / 64.0,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 128.0 };

    try app.addSystem(.input, "press", Jumps.press);
    try app.addSystem(.fixed, "jump", Jumps.jump);
    try app.run();

    try testing.expectEqual(@as(u32, 1), Jumps.heard);
}

test "a press is heard by one fixed step when a frame runs two" {
    Jumps.heard = 0;
    Jumps.press_on = 1;

    // A frame is two steps long, so both run inside the frame of the press.
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 4,
        .fixed_delta = 1.0 / 64.0,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 32.0 };

    try app.addSystem(.input, "press", Jumps.press);
    try app.addSystem(.fixed, "jump", Jumps.jump);
    try app.run();

    try testing.expectEqual(@as(u32, 1), Jumps.heard);
}

test "a press made while the world is paused does not reach the step after it" {
    Jumps.heard = 0;
    Jumps.press_on = 2;

    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 8,
        .fixed_delta = 1.0 / 64.0,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 32.0 };
    app.time.scale = 0;

    // Pressed on the second frame, paused until the fourth: no step should
    // hear it.
    try app.addSystem(.input, "press", Jumps.press);
    try app.addSystem(.input, "wake", Jumps.wake);
    try app.addSystem(.fixed, "jump", Jumps.jump);
    try app.run();

    try testing.expectEqual(@as(u32, 0), Jumps.heard);
}

test "with no camera, the screen and the world are the same numbers" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240 });
    defer app.destroy();

    const at = app.screenToWorld(12, 34);
    try testing.expectApproxEqAbs(@as(f32, 12), at.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 34), at.y, 0.001);

    const back = app.worldToScreen(12, 34);
    try testing.expectApproxEqAbs(@as(f32, 12), back.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 34), back.y, 0.001);
}

test "the pointer is found in the world through the camera" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240 });
    defer app.destroy();

    // Looking at (100, 50), with everything twice the size.
    _ = try app.world.spawnWith(.{
        components.Transform2D.at(100, 50),
        components.Camera2D.atZoom(2),
    });

    // The middle of the screen is where the camera is looking...
    app.input.pointer = .{ .x = 160, .y = 120 };
    const middle = app.pointerInWorld();
    try testing.expectApproxEqAbs(@as(f32, 100), middle.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 50), middle.y, 0.001);

    // ... and the top left is half a screen away at zoom two: 80 by 60 units.
    const corner = app.screenToWorld(0, 0);
    try testing.expectApproxEqAbs(@as(f32, 20), corner.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -10), corner.y, 0.001);

    // And back again, to the pixel it came from.
    const again = app.worldToScreen(corner.x, corner.y);
    try testing.expectApproxEqAbs(@as(f32, 0), again.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), again.y, 0.001);
}

test "a headless app has no screen to fill, and says so without failing" {
    const app = try App.create(testing.allocator, .{ .headless = true, .fullscreen = .borderless });
    defer app.destroy();

    try testing.expect(app.fullscreen() == .windowed);
    try app.setFullscreen(.borderless);
    try app.toggleFullscreen();
    try testing.expect(app.fullscreen() == .windowed);
}

/// A controller in slot zero with A held from the first frame on, handed over
/// every frame as `Window.pump` would.
const Controller = struct {
    var heard: u32 = 0;
    var slots: [Input.max_pads]platform.Gamepad = @splat(.{});

    fn poll(app: *App) anyerror!void {
        if (app.time.frame == 1) {
            slots[0].connected = true;
            slots[0].state.buttons[@intFromEnum(platform.GamepadButton.a)] = true;
        }
        app.input.readPads(&slots);
    }

    fn jump(app: *App) anyerror!void {
        if (app.input.anyPad().justPressed(.a)) heard += 1;
    }
};

test "a controller press is heard by one fixed step, as a key is" {
    Controller.heard = 0;
    Controller.slots = @splat(.{});

    // Frames half a step long, as in the key test: the frame the button goes
    // down on runs no step.
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 8,
        .fixed_delta = 1.0 / 64.0,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 128.0 };

    try app.addSystem(.input, "poll", Controller.poll);
    try app.addSystem(.fixed, "jump", Controller.jump);
    try app.run();

    // Once, though the button is held for all eight frames.
    try testing.expectEqual(@as(u32, 1), Controller.heard);
}

test "a headless app has no pointer to hold, and says so without failing" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    try app.setCursor(.locked);
    try testing.expect(app.cursor() == .normal);
    try testing.expect(!app.input.pointer.locked);
    try app.setCursorShape(.pointing_hand);
    try testing.expectEqual(@as(usize, 0), try app.addGamepadMappings("not a mapping"));
}

test "a headless app has no window to move or resize, and says so without failing" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .width = 320,
        .height = 240,
        .resizable = false,
        .maximized = true,
    });
    defer app.destroy();

    try app.setWindowTitle("nobody reads this");
    try app.setWindowSize(800, 600);
    try app.setWindowPosition(10, 20);
    try app.setWindowSizeLimits(.{ .min_width = 640, .min_height = 480 });
    try app.setWindowState(.maximized);

    try testing.expect(app.windowPosition() == null);
    try testing.expect(app.windowState() == .normal);
    // The target is the size it was made at, and nothing was resized.
    try testing.expectEqual(@as(u32, 320), app.width);
    try testing.expectEqual(@as(u32, 240), app.height);
    try testing.expect(!app.resized);
}

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

test "the engine's flags are read by name, and a game's own sit beside them" {
    const engine = try parseFlags(Flags, &.{ "game", "--backend", "d3d11", "--frames", "300", "--capture", "shot.png" });
    try testing.expectEqual(Backend.d3d11, engine.backend.?);
    try testing.expectEqual(@as(u32, 300), engine.frames.?);
    try testing.expectEqualStrings("shot.png", engine.capture.?);
    try testing.expect(engine.width == null);

    // The engine's flags inside a game's own: both read, and `write_atlas`
    // is `--write-atlas`.
    const Mine = struct { app: Flags = .{}, write_atlas: ?[]const u8 = null };
    const mine = try parseFlags(Mine, &.{ "game", "--write-atlas", "atlas.png", "--width", "640" });
    try testing.expectEqualStrings("atlas.png", mine.write_atlas.?);
    try testing.expectEqual(@as(u32, 640), mine.app.width.?);
}

test "a flag that is wrong stops the program rather than being passed over" {
    try testing.expectError(error.UnknownFlag, parseFlags(Flags, &.{ "game", "--frame", "10" }));
    try testing.expectError(error.MissingValue, parseFlags(Flags, &.{ "game", "--frames" }));
    try testing.expectError(error.InvalidValue, parseFlags(Flags, &.{ "game", "--frames", "ten" }));
    try testing.expectError(error.InvalidValue, parseFlags(Flags, &.{ "game", "--backend", "metal" }));
}

test "flags override what they say and leave the rest, and a capture is reproducible" {
    const base: Options = .{ .width = 960, .height = 540, .frames = null };

    const sized = (Flags{ .width = 1280 }).apply(base);
    try testing.expectEqual(@as(u32, 1280), sized.width);
    try testing.expectEqual(@as(u32, 540), sized.height);
    try testing.expect(sized.frame_time == null);

    // A capture: a frame count to stop at, and a clock that is not the
    // machine's.
    const captured = (Flags{ .capture = "shot.png" }).apply(base);
    try testing.expectEqual(@as(u32, Flags.capture_frames), captured.frames.?);
    try testing.expectEqual(captured.fixed_delta, captured.frame_time.?);

    // With a count of its own, that count.
    const counted = (Flags{ .capture = "shot.png", .frames = 7 }).apply(base);
    try testing.expectEqual(@as(u32, 7), counted.frames.?);
}

test "a fixed frame time wins over the clock" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 3,
        .io = testing.io,
        .frame_time = 0.25,
    });
    defer app.destroy();

    try app.run();
    try testing.expectApproxEqAbs(@as(f64, 0.75), app.time.elapsed, 0.0001);
}

const Tally = extern struct { points: u32 = 0 };

test "single finds the one entity with a component, or none" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    // Never seen, so nothing - and asking registered nothing.
    try testing.expect(app.single(Tally) == null);
    const before = app.world.componentCount();
    try testing.expect(app.single(Tally) == null);
    try testing.expectEqual(before, app.world.componentCount());

    // Beside other components, in an archetype of its own.
    _ = try app.world.spawnWith(.{ components.Transform2D{}, Tally{ .points = 4 } });
    app.single(Tally).?.points += 1;
    try testing.expectEqual(@as(u32, 5), app.single(Tally).?.points);
}

test "a name finds its entity, and the entity its name" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    const camera = try app.world.spawnWith(.{components.Transform2D{}});
    const player = try app.world.spawnWith(.{components.Transform2D{}});
    const shapes = app.world.archetypeSlice().len;
    try app.setName(camera, "camera");
    try app.setName(player, "player");

    try testing.expect(app.find("camera").?.eql(camera));
    try testing.expect(app.find("player").?.eql(player));
    try testing.expectEqualStrings("camera", app.nameOf(camera).?);
    try testing.expect(app.find("door") == null);

    // A name is not a component: no new archetype.
    try testing.expectEqual(shapes, app.world.archetypeSlice().len);

    const rock = try app.world.spawn();
    try testing.expect(app.nameOf(rock) == null);
}

test "a name belongs to one living entity at a time" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    const first = try app.world.spawn();
    const second = try app.world.spawn();
    try app.setName(first, "door");

    try testing.expectError(error.NameTaken, app.setName(second, "door"));
    // Its own name again is not a clash.
    try app.setName(first, "door");

    // Despawned: the name is free at once, before the end of the frame.
    app.world.despawn(first);
    try testing.expect(app.find("door") == null);
    try testing.expect(app.nameOf(first) == null);
    try app.setName(second, "door");
    try testing.expect(app.find("door").?.eql(second));

    try testing.expectError(error.NoSuchEntity, app.setName(first, "ghost"));
}

test "renaming frees the old name, and the text is copied" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    const thing = try app.world.spawn();
    var buffer: [16]u8 = undefined;
    try app.setName(thing, try std.fmt.bufPrint(&buffer, "player {d}", .{2}));
    @memset(&buffer, 'x');
    try testing.expect(app.find("player 2").?.eql(thing));

    try app.setName(thing, "hero");
    try testing.expect(app.find("player 2") == null);
    try testing.expectEqualStrings("hero", app.nameOf(thing).?);

    // And the old name is anybody's.
    const other = try app.world.spawn();
    try app.setName(other, "player 2");
    try testing.expect(app.find("player 2").?.eql(other));
}

test "a rename that runs out of memory keeps the old name" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const app = try App.create(failing.allocator(), .{ .headless = true });
    defer app.destroy();

    const thing = try app.world.spawn();
    try app.setName(thing, "name 0");

    // Renamed while the tables fill, so each has to grow at some point, with
    // every allocation of each rename failing in turn: the old name has to
    // survive every failure.
    var old_text: [16]u8 = undefined;
    var new_text: [16]u8 = undefined;
    for (1..24) |round| {
        const old = try std.fmt.bufPrint(&old_text, "name {d}", .{round - 1});
        const new = try std.fmt.bufPrint(&new_text, "name {d}", .{round});

        var fail_after: usize = 0;
        while (true) : (fail_after += 1) {
            failing.fail_index = failing.alloc_index + fail_after;
            app.setName(thing, new) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                try testing.expectEqualStrings(old, app.nameOf(thing).?);
                try testing.expect(app.find(old).?.eql(thing));
                try testing.expect(app.find(new) == null);
                continue;
            };
            break;
        }
        failing.fail_index = std.math.maxInt(usize);
        try testing.expect(app.find(new).?.eql(thing));

        const filler = try app.world.spawn();
        try app.setName(filler, try std.fmt.bufPrint(&new_text, "filler {d}", .{round}));
    }
}

test "the names of the dead are given back at the end of the frame" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    const ship = try app.world.spawnWith(.{components.Transform2D.at(10, 10)});
    const flame = try app.world.spawnWith(.{components.Transform2D.childOf(ship, 0, 8)});
    const buoy = try app.world.spawn();
    try app.setName(ship, "ship");
    try app.setName(flame, "flame");
    try app.setName(buoy, "buoy");

    app.world.despawn(ship);
    try app.run();

    // The flame went with the ship, and both names with them.
    try testing.expect(app.find("flame") == null);
    try testing.expect(app.find("buoy").?.eql(buoy));
    try testing.expectEqual(@as(usize, 1), app.names.count());
    try testing.expectEqual(@as(u32, 1), app.by_name.count());
}

/// Escape pressed on the third frame, the way the platform would deliver it.
fn escapeOnThird(app: *App) anyerror!void {
    if (app.time.frame == 3) app.input.apply(pressOf(.escape));
}

test "a quit key ends the game after the frame it was pressed in" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 100, .quit_key = .escape });
    defer app.destroy();

    try app.addSystem(.input, "escape on third", escapeOnThird);
    try app.run();
    try testing.expectEqual(@as(u64, 3), app.time.frame);
}

test "a shortcut nobody asked for is not one" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 5 });
    defer app.destroy();

    try app.addSystem(.input, "escape on third", escapeOnThird);
    try app.run();
    try testing.expectEqual(@as(u64, 5), app.time.frame);
}

/// What `time.delta` said in each stage, the last time each ran.
const Deltas = struct {
    var fixed: f32 = 0;
    var update: f32 = 0;

    fn inFixed(app: *App) anyerror!void {
        fixed = app.time.delta;
    }

    fn inUpdate(app: *App) anyerror!void {
        update = app.time.delta;
    }
};

test "time.delta is the step in the fixed stage and the frame everywhere else" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 2,
        .fixed_delta = 1.0 / 64.0,
        .frame_time = 1.0 / 32.0,
    });
    defer app.destroy();

    try app.addSystem(.fixed, "in fixed", Deltas.inFixed);
    try app.addSystem(.update, "in update", Deltas.inUpdate);
    try app.run();

    try testing.expectEqual(@as(f32, 1.0 / 64.0), Deltas.fixed);
    try testing.expectEqual(@as(f32, 1.0 / 32.0), Deltas.update);
    // And put back afterwards.
    try testing.expectEqual(@as(f32, 1.0 / 32.0), app.time.delta);
}

test "a capture is saved as a PNG the size of the target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const app = try App.create(testing.allocator, .{
        .headless = true,
        .width = 32,
        .height = 16,
        .frames = 1,
        .io = testing.io,
    });
    defer app.destroy();
    try app.run();

    var buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/shot.png", .{tmp.sub_path});
    try app.saveCapture(path);

    var decoded = try image.png.readFile(testing.allocator, testing.io, path, .{});
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 32), decoded.width);
    try testing.expectEqual(@as(u32, 16), decoded.height);
}

test "a capture with nothing to write files with says so" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();
    try app.run();
    try testing.expectError(error.NoIo, app.saveCapture("nowhere.png"));
}

test "vsync is remembered, even with no display to wait for" {
    const app = try App.create(testing.allocator, .{ .headless = true, .vsync = true });
    defer app.destroy();

    try testing.expect(app.vsync());
    try app.setVsync(false);
    try testing.expect(!app.vsync());
}

test "additive sprites get a draw of their own, and share it with each other" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    for ([_]components.Sprite.Blend{ .additive, .alpha, .additive }, 0..) |blend, i| {
        var glow = components.Sprite.solid(.white, 8, 8);
        glow.blend = blend;
        _ = try app.world.spawnWith(.{ components.Transform2D.at(@floatFromInt(10 + i * 10), 10), glow });
    }
    try app.run();

    try testing.expectEqual(@as(u32, 3), app.sprites.drawn);
    try testing.expectEqual(@as(u32, 2), app.sprites.draw_calls);
}

test "a repeating texture tiles across a region past its edge" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    const tile = try app.assets.textureFromPixels(2, 2, &(.{255} ** 16), .{ .wrap = .repeat });
    _ = try app.world.spawnWith(.{
        components.Transform2D.at(32, 32),
        components.Sprite{ .texture = tile, .region = .repeated(4, 2) },
    });
    try app.run();

    const drawn = app.sprites.items.items[0];
    try testing.expect(std.meta.eql(app.assets.samplers.get(.nearest).get(.repeat), drawn.sampler));
    try testing.expectEqual(@as(f32, 8), drawn.instance.placement[2]);
    try testing.expectEqual(@as(f32, 4), drawn.instance.placement[3]);
}

const Panel = struct {
    fn declare(app: *App) anyerror!void {
        app.ui.empty(.{ .id = "panel", .width = .fixed(100), .height = .fixed(50), .background_color = .white });
    }

    fn another(app: *App) anyerror!void {
        app.ui.empty(.{ .id = "other", .width = .fixed(60), .height = .fixed(50), .background_color = .white });
    }

    fn tall(app: *App) anyerror!void {
        app.ui.empty(.{ .id = "tall", .width = .fixed(10), .height = .grow });
    }

    fn label(app: *App) anyerror!void {
        app.ui.open(.{});
        defer app.ui.close();
        app.ui.text("Hi", .{ .font_size = 16 });
    }
};

test "every .ui system declares into one root the size of the window" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240, .frames = 2 });
    defer app.destroy();
    try app.addSystem(.ui, "panel", Panel.declare);
    try app.addSystem(.ui, "another", Panel.another);
    try app.addSystem(.ui, "tall", Panel.tall);
    try app.run();

    try testing.expectEqual(@as(f32, 100), app.ui.boxOf("panel").?.width);
    try testing.expectEqual(@as(f32, 100), app.ui.boxOf("other").?.x);
    try testing.expectEqual(@as(f32, 240), app.ui.boxOf("tall").?.height);
    try testing.expectEqual(@as(usize, 2), app.interface.commands.len);
}

test "the interface is drawn over the 2D layer, in the default font" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1, .io = testing.io });
    defer app.destroy();
    _ = app.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 256 }) catch return error.SkipZigTest;
    _ = try app.world.spawnWith(.{ components.Transform2D.at(10, 10), components.Sprite.solid(.white, 8, 8) });
    try app.addSystem(.ui, "label", Panel.label);
    try app.run();

    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
    try testing.expectEqual(&app.assets.fontOf(.none).?.face, app.interface.face.?);
    try testing.expectEqual(@as(usize, 2), app.interface.renderer.?.instances.items.len);
}

test "a font read again is drawn again in the interface, not from the old one's glyphs" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    const font = app.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 256 }) catch return error.SkipZigTest;
    try app.addSystem(.ui, "label", Panel.label);
    try app.startup();

    _ = try app.step();
    const first = app.interface.renderer.?.atlas_texture;
    _ = try app.step();
    try testing.expect(std.meta.eql(first, app.interface.renderer.?.atlas_texture));

    // The face keeps its address, and the renderer is made again anyway.
    try testing.expect(try app.assets.reloadFont(font));
    _ = try app.step();
    try testing.expect(!std.meta.eql(first, app.interface.renderer.?.atlas_texture));
    try testing.expectEqual(&app.assets.fontOf(.none).?.face, app.interface.face.?);
}

const Clicks = struct {
    var released: u32 = 0;
    var wanted = false;

    fn button(app: *App) anyerror!void {
        app.ui.open(.{ .id = "ok", .width = .fixed(40), .height = .fixed(20), .background_color = .white });
        defer app.ui.close();
        if (app.ui.justReleased()) released += 1;
    }

    fn game(app: *App) anyerror!void {
        wanted = app.ui.wantsPointer();
    }
};

fn leftButton(down: bool, x: f64, y: f64) platform.Event {
    return .{ .mouse_button = .{
        .window = .none,
        .button = .left,
        .action = if (down) .press else .release,
        .mods = .{},
        .x = x,
        .y = y,
    } };
}

test "a click presses what the interface drew under it, and the game is told" {
    Clicks.released = 0;
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 200, .height = 100 });
    defer app.destroy();
    try app.addSystem(.ui, "button", Clicks.button);
    try app.addSystem(.update, "game", Clicks.game);
    try app.startup();

    _ = try app.step();
    app.input.apply(leftButton(true, 20, 10));
    _ = try app.step();
    try testing.expect(Clicks.wanted);

    app.input.apply(leftButton(false, 20, 10));
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), Clicks.released);
}

const Nap = struct {
    fn run(_: *App) anyerror!void {
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
};

test "each system's time over the last frame is kept under its name" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 2, .io = testing.io });
    defer app.destroy();
    try app.addSystem(.update, "nap", Nap.run);
    try app.run();

    const nap = app.schedule.systemsIn(.update)[0];
    try testing.expectEqualStrings("nap", nap.name);
    try testing.expect(nap.time_last_frame.nanoseconds >= std.time.ns_per_ms / 2);
}

test "a frame cap slows the loop down to it" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 6, .io = testing.io });
    defer app.destroy();
    app.time.max_fps = 100;

    try app.run();
    try testing.expect(app.time.elapsed >= 0.03);
}

const Scribble = struct {
    var every_frame: bool = true;

    fn line(app: *App) anyerror!void {
        if (every_frame) app.debug.line2d(.init(0, 0), .init(10, 10), .red);
    }

    fn circle(app: *App) anyerror!void {
        app.debug.with(.{ .segments = 16 }).circle2d(.init(20, 20), 5, .green);
    }

    fn lasting(app: *App) anyerror!void {
        if (app.time.frame == 1) app.debug.with(.{ .seconds = 0.05 }).cross2d(.init(5, 5), 4, .white);
    }
};

test "a debug shape is drawn in the frame it was drawn in, and not in the next" {
    Scribble.every_frame = true;
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "line", Scribble.line);

    try app.startup();
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.debug_renderer.stats.lines);

    Scribble.every_frame = false;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.debug_renderer.stats.lines);
}

test "a debug shape drawn in a fixed step is there in every frame until the next step" {
    const app = try App.create(testing.allocator, .{ .headless = true, .fixed_delta = 1.0 / 64.0 });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 256.0 };
    try app.addSystem(.fixed, "circle", Scribble.circle);

    try app.startup();
    for (1..13) |frame| {
        _ = try app.step();
        try testing.expectEqual(@as(u32, if (frame < 4) 0 else 16), app.debug_renderer.stats.lines);
    }

    app.time.source = .{ .fixed = 1.0 / 32.0 };
    _ = try app.step();
    try testing.expectEqual(@as(u32, 16), app.debug_renderer.stats.lines);
}

test "a lasting debug shape stays for its seconds of game time" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 64.0 };
    try app.addSystem(.update, "lasting", Scribble.lasting);

    try app.startup();
    var frames_with_it: u32 = 0;
    for (0..10) |_| {
        _ = try app.step();
        if (app.debug_renderer.stats.lines > 0) frames_with_it += 1;
    }
    try testing.expectEqual(@as(u32, 4), frames_with_it);
}

test "with debug hidden nothing of it is drawn, a game's own shapes nor the engine's views" {
    Scribble.every_frame = true;
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "line", Scribble.line);
    app.debug_views.transforms = true;
    _ = try app.world.spawnWith(.{components.Transform2D.at(1, 1)});
    app.debug_visible = false;

    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.debug_renderer.stats.lines);
    try testing.expectEqual(@as(u32, 1), app.debug_frame.count(.world).lines);

    app.debug_visible = true;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1 + 2), app.debug_renderer.stats.lines);
}

/// F3 pressed on the second frame.
fn debugKeyOnSecond(app: *App) anyerror!void {
    if (app.time.frame == 2) app.input.apply(pressOf(.f3));
}

test "the debug key shows and hides what debug draws" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 3, .debug_key = .f3 });
    defer app.destroy();
    try app.addSystem(.input, "f3 on second", debugKeyOnSecond);
    try app.run();
    try testing.expect(!app.debug_visible);
}

test "what a system asks of the commands is done before the next system runs" {
    const Seen = struct {
        var by_itself: usize = 99;
        var by_the_next: usize = 99;

        fn spawnTwo(a: *App) anyerror!void {
            _ = try a.commands.spawn(.{components.Transform2D.at(1, 2)});
            _ = try a.commands.spawn(.{components.Transform2D.at(3, 4)});
            by_itself = try ecs.Query(.{components.Transform2D}).count(&a.world);
        }

        fn count(a: *App) anyerror!void {
            by_the_next = try ecs.Query(.{components.Transform2D}).count(&a.world);
        }
    };

    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();
    try app.addSystem(.update, "spawn", Seen.spawnTwo);
    try app.addSystem(.update, "count", Seen.count);
    try app.run();
    try testing.expectEqual(@as(usize, 0), Seen.by_itself);
    try testing.expectEqual(@as(usize, 2), Seen.by_the_next);
}

test "a system that fails leaves nothing of what it asked the commands for" {
    const Failing = struct {
        fn run(a: *App) anyerror!void {
            _ = try a.commands.spawn(.{components.Transform2D.at(1, 2)});
            return error.Deliberate;
        }
    };
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();
    try app.addSystem(.update, "fail", Failing.run);
    try testing.expectError(error.Deliberate, app.run());
    try testing.expectEqual(@as(usize, 0), app.commands.count());
    try testing.expectEqual(@as(usize, 0), try ecs.Query(.{components.Transform2D}).count(&app.world));
}

test "commands asked for between frames are done at the top of the next" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const e = try app.commands.spawn(.{components.Transform2D.at(5, 6)});
    try testing.expect(app.world.get(e, components.Transform2D) == null);
    _ = try app.step();
    try testing.expectEqual(@as(f32, 5), app.world.get(e, components.Transform2D).?.x);

    try app.commands.despawn(e);
    app.clearWorld();
    try testing.expectEqual(@as(usize, 0), app.commands.count());
}

test "with no window the clipboard is the program's own, and the game and the interface share it" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try testing.expect(app.clipboard.system == null);
    try testing.expect(!app.hasClipboardText());

    try app.setClipboardText("level 3");
    try testing.expect(app.hasClipboardText());
    try testing.expectEqualStrings("level 3", try app.clipboardText());
    try testing.expectError(error.Unavailable, app.setClipboardText("\xc3"));
}

test "every engine component is described under the name a scene gives it" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    try testing.expectEqual(@as(usize, 8), app.scene_components.entries.items.len);
    for (app.scene_components.entries.items) |entry| {
        try testing.expectEqualStrings(entry.name, entry.type.name.slice());
        try testing.expect(app.types.find(entry.name).? == entry.type);
    }

    const drawn = app.types.find("Sprite").?;
    try testing.expectEqual(@as(f64, 1), drawn.field("pivot_x").?.attribute(reflect.attr.Range).?.max);
    try testing.expect(drawn.field("tint").?.type == app.types.find("Color").?);
    try testing.expect(app.types.find("Text2D").?.field("bytes").?.attribute(reflect.attr.Hidden) != null);
    try testing.expect(app.types.find("DebugViews").?.field("colliders") != null);

    // Described, and left out until asked for: see `types`.
    try testing.expect(reflect.typeOf(App).method("setWindowTitle") != null);
    try testing.expect(app.types.find("App") == null);
    _ = try app.types.add(App);
    try testing.expect(app.types.find("App").? == reflect.typeOf(App));
}

test "a component is found by its name, and read and written where it is" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const thing = try app.world.spawnWith(.{ components.Transform2D.at(1, 2), components.Sprite.solid(.white, 4, 4) });

    const place = app.componentOf(thing, "Transform2D").?;
    try (try place.field("x")).setFloat(320);
    try (try place.path("scale_y")).setFloat(2);
    try testing.expectEqual(@as(f32, 320), app.world.get(thing, components.Transform2D).?.x);
    try testing.expectEqual(@as(f32, 2), app.world.get(thing, components.Transform2D).?.scale_y);

    // A method of the component's own, called through the value.
    var by: f32 = 5;
    try place.call("translate", &.{ .of(&by), .of(&by) }, null);
    try testing.expectEqual(@as(f32, 325), app.world.get(thing, components.Transform2D).?.x);

    try testing.expect(app.componentOf(thing, "Camera2D") == null);
    try testing.expect(app.componentOf(thing, "Mystery") == null);
    app.world.despawn(thing);
    try testing.expect(app.componentOf(thing, "Transform2D") == null);
}

test "a label's words are a property, written and read through its methods, not its buffer" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const label = try app.world.spawnWith(.{ components.Transform2D{}, components.Text2D.of("Score") });

    // As an inspector that has never heard of `Text2D` finds them.
    const words = app.componentOf(label, "Text2D").?;
    const property = words.type.attribute(attr.Property).?;
    try testing.expectEqualStrings("text", property.name);
    var over: []const u8 = "Game over";
    try words.call(property.set, &.{.of(&over)}, null);
    var shown: []const u8 = "";
    try words.call(property.get, &.{}, .of(&shown));
    try testing.expectEqualStrings("Game over", shown);
    try testing.expectEqualStrings("Game over", app.world.get(label, components.Text2D).?.slice());
    try testing.expect(words.type.method(property.set).?.attribute(attr.Multiline) != null);
}

/// A game's component with a field that declares no default.
const Heading = extern struct {
    angle: f32,
    speed: f32 = 3,
};

test "an entity's components are listed in the order they were registered" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.registerComponents(.{Tally});
    const thing = try app.world.spawnWith(.{ Tally{ .points = 3 }, components.Sprite{}, components.Transform2D{} });

    var found: [8]ComponentValue = undefined;
    const listed = app.componentsOf(thing, &found);
    try testing.expectEqual(@as(usize, 3), listed.len);
    try testing.expectEqualStrings("Transform2D", listed[0].name);
    try testing.expectEqualStrings("Sprite", listed[1].name);
    try testing.expectEqualStrings("Tally", listed[2].name);
    try testing.expectEqual(@as(?u32, 3), (try listed[2].value.field("points")).get(u32));
    try testing.expect(app.types.find(@typeName(Tally)) == listed[2].value.type);

    // As many as there is room for.
    try testing.expectEqual(@as(usize, 1), app.componentsOf(thing, found[0..1]).len);
}

test "a component is added by its name holding its defaults, and taken off by it" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.registerComponents(.{Heading});
    const thing = try app.world.spawnWith(.{components.Transform2D{}});

    const collider = try app.addComponentNamed(thing, "Collider2D");
    try testing.expectEqual(@as(?f32, 0.6), (try collider.field("friction")).get(f32));
    try (try collider.field("friction")).setFloat(0.25);

    // One it has is handed back as it is, not started again.
    const again = try app.addComponentNamed(thing, "Collider2D");
    try testing.expectEqual(@as(?f32, 0.25), (try again.field("friction")).get(f32));
    try testing.expectEqual(@as(f32, 0.25), app.world.get(thing, components.Collider2D).?.friction);

    // A field with no default of its own starts at zero.
    _ = try app.addComponentNamed(thing, "Heading");
    try testing.expectEqual(Heading{ .angle = 0, .speed = 3 }, app.world.get(thing, Heading).?.*);

    try app.removeComponentNamed(thing, "Collider2D");
    try testing.expect(!app.world.has(thing, components.Collider2D));
    try app.removeComponentNamed(thing, "Collider2D");
    try testing.expect(app.world.has(thing, Heading));

    try testing.expectError(error.NoSuchComponent, app.addComponentNamed(thing, "Mystery"));
    try testing.expectError(error.NoSuchComponent, app.removeComponentNamed(thing, "Mystery"));
    app.world.despawn(thing);
    try testing.expectError(error.NoSuchEntity, app.addComponentNamed(thing, "Sprite"));
}

test "the engine's calls are made by name, and what they return comes back, errors too" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    const door = try app.world.spawn();
    const other = try app.world.spawn();

    var name: []const u8 = "door";
    try app.callNamed("setName", &.{ .of(&door), .of(&name) }, null);
    var answer: ?ecs.Entity = null;
    try app.callNamed("find", &.{.of(&name)}, .of(&answer));
    try testing.expect(answer.?.eql(door));

    // An error is returned, not dropped.
    try testing.expectError(error.NameTaken, app.callNamed("setName", &.{ .of(&other), .of(&name) }, null));
    var path: []const u8 = "no/such/scene.json";
    var options: scene.LoadOptions = .{};
    try testing.expectError(error.FileNotFound, app.callNamed("loadScene", &.{ .of(&path), .of(&options) }, null));

    // And a value that comes with the chance of one.
    var copied: []const u8 = "level 3";
    try app.callNamed("setClipboardText", &.{.of(&copied)}, null);
    var pasted: []const u8 = "";
    try app.callNamed("clipboardText", &.{}, .of(&pasted));
    try testing.expectEqualStrings("level 3", pasted);

    try testing.expectError(error.NoSuchMethod, app.callNamed("launchMissiles", &.{}, null));
    try testing.expectError(error.ArgumentCount, app.callNamed("quit", &.{.of(&name)}, null));
    try app.callNamed("quit", &.{}, null);
    try testing.expect(!app.running);
}

test "a UUID belongs to one living entity at a time, and is free again when it dies" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const door = try app.world.spawn();
    const gate = try app.world.spawn();
    const uuid = app.newUuid();
    try testing.expectEqual(@as(u4, 4), uuid.version());
    try testing.expect(!uuid.eql(app.newUuid()));

    try app.setUuid(door, uuid);
    try testing.expect(app.findUuid(uuid).?.eql(door));
    try testing.expect(app.uuidOf(door).?.eql(uuid));
    try testing.expectError(error.UuidTaken, app.setUuid(gate, uuid));
    try app.setUuid(door, uuid);
    try testing.expectError(error.NilUuid, app.setUuid(gate, .nil));

    // Another for the door, and the first is anybody's.
    const other = app.newUuid();
    try app.setUuid(door, other);
    try testing.expect(app.findUuid(uuid) == null);
    try app.setUuid(gate, uuid);
    try testing.expect(app.findUuid(uuid).?.eql(gate));

    // Despawned: free at once, before the end of the frame.
    app.world.despawn(gate);
    try testing.expect(app.findUuid(uuid) == null);
    try testing.expect(app.uuidOf(gate) == null);
    try app.setUuid(door, uuid);
    try testing.expectError(error.NoSuchEntity, app.setUuid(gate, other));
    try testing.expectError(error.NoSuchEntity, app.ensureUuid(gate));
}

test "an entity given a UUID keeps it, and the dead ones are forgotten at the end of the frame" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const thing = try app.world.spawn();
    const given = try app.ensureUuid(thing);
    try testing.expect(given.eql(try app.ensureUuid(thing)));

    app.world.despawn(thing);
    try testing.expectEqual(@as(usize, 1), app.uuids.count());
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.uuids.count());
    try testing.expectEqual(@as(usize, 0), app.by_uuid.count());

    _ = try app.ensureUuid(try app.world.spawn());
    app.clearWorld();
    try testing.expectEqual(@as(usize, 0), app.uuids.count());
}

test "the project's root is an option and a flag, and one that is not there stops the start" {
    const flags = try App.parseFlags(App.Flags, &.{ "game", "--root", "games/pong" });
    try testing.expectEqualStrings("games/pong", flags.apply(.{}).root.?);
    try testing.expectError(error.FileNotFound, App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = "no/such/project" }));
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

    try Project.writeSettings(testing.allocator, testing.io, root, .{ .name = "Meadow", .tags = &.{"2d"} });
    // By the folder, or by the file itself, as a file association gives it.
    const file = try std.fmt.bufPrint(&buffers[1], "{s}/" ++ Project.file_name, .{root});
    for ([_][]const u8{ root, file }) |given| {
        const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = given });
        defer app.destroy();
        const settings = app.project.settings.?;
        try testing.expectEqualStrings("Meadow", settings.name);
        try testing.expectEqualStrings("2d", settings.tags[0]);
        try testing.expect(std.mem.endsWith(u8, app.project.root, &tmp.sub_path));
        try testing.expectEqualStrings("Meadow", titleOf(.{}, settings));
        try testing.expectEqualStrings("Pong", titleOf(.{ .title = "Pong" }, settings));
    }
}

test "a project file that is wrong stops the start, and says what and where" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = Project.file_name, .data = "{ \"fluxion_project\": 9, \"name\": \"Later\" }" });

    var diagnostics: json.Diagnostics = .{};
    try testing.expectError(error.UnsupportedVersion, App.create(testing.allocator, .{
        .headless = true,
        .io = testing.io,
        .root = root,
        .project_diagnostics = &diagnostics,
    }));
    try testing.expectEqualStrings("this project file is version 9; this engine reads version 1", diagnostics.message());
    try testing.expectEqual(@as(u32, 1), diagnostics.line);
}

test "auto opens the best of the project's renderer, and a backend asked for wins" {
    try testing.expectEqual(Backend.d3d11, try chooseBackend(.auto, .compatibility, .windows));
    try testing.expectEqual(Backend.gl, try chooseBackend(.auto, .compatibility, .linux));
    try testing.expectEqual(Backend.gl, try chooseBackend(.auto, .compatibility, .macos));
    try testing.expectEqual(Backend.webgl, try chooseBackend(.auto, .compatibility, .emscripten));
    try testing.expectEqual(Backend.gl, try chooseBackend(.gl, .compatibility, .windows));

    // Not built: refused, not drawn with something else - unless asked for.
    try testing.expectError(error.RendererNotBuilt, chooseBackend(.auto, .modern, .windows));
    try testing.expectEqual(Backend.d3d11, try chooseBackend(.d3d11, .modern, .windows));

    const flags = try App.parseFlags(App.Flags, &.{ "game", "--backend", "gl" });
    try testing.expectEqual(Backend.gl, flags.apply(.{}).backend);
}

test "a headless dialog is never answered by itself, and a test's answer comes in the next frame" {
    const Seen = struct {
        var answers: usize = 0;
        var last: dialog.Id = .none;
        var paths: usize = 0;

        fn look(a: *App) anyerror!void {
            for (a.input.dialogAnswers()) |answer| {
                answers += 1;
                last = answer.id;
                paths += answer.paths.len;
            }
        }
    };
    Seen.answers = 0;
    Seen.paths = 0;
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "look", Seen.look);

    const folder = try app.openFolderDialog(.{ .title = "Where the project goes" });
    const file = try app.openFileDialog(.{ .multiple = true, .filters = &.{.{ .name = "Scenes", .extensions = &.{ "json", "scene" } }} });
    try testing.expect(folder != .none and file != .none and folder != file);

    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Seen.answers);

    app.input.answerDialog(.{ .id = folder, .paths = &.{"C:/games/meadow"} });
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Seen.answers);
    try testing.expectEqual(folder, Seen.last);
    try testing.expectEqual(@as(usize, 1), Seen.paths);

    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Seen.answers);
    try testing.expect(app.input.dialogAnswer(folder) == null);

    // A cancel is an answer, with no paths.
    app.input.answerDialog(.{ .id = file, .paths = &.{} });
    _ = try app.step();
    try testing.expectEqual(@as(usize, 2), Seen.answers);
    try testing.expectEqual(@as(usize, 0), app.input.dialogAnswer(file).?.len);

    // The ids go round after four billion, past `.none`.
    app.next_dialog = std.math.maxInt(u32);
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), @intFromEnum(try app.openFileDialog(.{})));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(try app.openFileDialog(.{})));
}

test "a frame that fails still lets its dialog answers go" {
    // The platform's paths are good until its next pump. An answer that a
    // failed frame kept would be read in the next one from memory already
    // given back - by an editor, which goes on after a system's error.
    const Once = struct {
        var failed = false;

        fn fail(_: *App) anyerror!void {
            if (failed) return;
            failed = true;
            return error.Broken;
        }
    };
    Once.failed = false;
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "fails once", Once.fail);

    const id = try app.openFileDialog(.{});
    app.input.answerDialog(.{ .id = id, .paths = &.{"C:/games/meadow/hero.png"} });
    try testing.expectError(error.Broken, app.step());

    _ = try app.step();
    try testing.expect(app.input.dialogAnswer(id) == null);
}

test "files dropped on the window reach that frame's systems, and only that frame's" {
    const Seen = struct {
        var drops: usize = 0;
        var last: []const u8 = "";

        fn look(app: *App) anyerror!void {
            for (app.input.dropped()) |drop| {
                drops += 1;
                last = drop.paths[drop.paths.len - 1];
            }
        }
    };
    Seen.drops = 0;
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "look", Seen.look);
    try app.startup();

    app.input.dropFiles(.{ .paths = &.{ "C:/Art/hero.png", "C:/Art/tree.png" }, .x = 10, .y = 20 });
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Seen.drops);
    try testing.expectEqualStrings("C:/Art/tree.png", Seen.last);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Seen.drops);
}

/// A project of a test's own, with a PNG in it: see `scene.zig`'s `Game`.
const Files = struct {
    tmp: testing.TmpDir,
    buffer: [128]u8 = undefined,
    root: []const u8 = "",

    fn init() !Files {
        var files: Files = .{ .tmp = testing.tmpDir(.{}) };
        try files.tmp.dir.createDirPath(testing.io, "art");
        return files;
    }

    /// The root, from the working directory. Made where the struct has come
    /// to rest, since it points into `buffer`.
    fn at(files: *Files) ![]const u8 {
        files.root = try std.fmt.bufPrint(&files.buffer, ".zig-cache/tmp/{s}", .{files.tmp.sub_path});
        return files.root;
    }

    fn picture(files: *Files, path: []const u8) !void {
        var buffer: [192]u8 = undefined;
        const file = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ try files.at(), path });
        try image.png.writeFile(testing.allocator, testing.io, file, .{ .width = 1, .height = 1, .pixels = &.{ 255, 255, 255, 255 }, .row_pitch = 4 }, .{});
    }

    fn app(files: *Files) !*App {
        return App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = try files.at() });
    }
};

test "a file moved takes what was read from it along, and the scene saved next names the new place" {
    var files: Files = try .init();
    defer files.tmp.cleanup();
    try files.picture("art/hero.png");
    const app = try files.app();
    defer app.destroy();

    const hero = try app.assets.loadTexture("res://art/hero.png", .{});
    _ = try app.world.spawnWith(.{ components.Transform2D.at(1, 2), components.Sprite.of(hero) });
    try app.saveScene("res://meadow.json", .{});
    const uid = app.project.knownUid("res://art/hero.png").?;

    try app.moveFile("res://art/hero.png", "res://art/ada.png");
    try testing.expectEqualStrings("res://art/ada.png", app.assets.textureSource(hero).?);
    try testing.expect(app.assets.findTexture("res://art/ada.png").?.eql(hero));

    // A folder, and what was read from inside it.
    try app.moveFile("res://art", "res://pictures");
    try testing.expectEqualStrings("res://pictures/ada.png", app.assets.textureSource(hero).?);
    try testing.expectEqualStrings("res://pictures/ada.png", (try app.project.pathOf(uid)).?);

    // Another run finds it by its UUID from the scene saved before the moves,
    // and the scene saved now names where it is.
    const other = try files.app();
    defer other.destroy();
    const loaded = try other.loadScene("res://meadow.json", .{});
    try testing.expectEqual(@as(usize, 1), loaded.moved);
    try app.saveScene("res://meadow.json", .{});
    var said = (try app.sceneInfo("res://meadow.json", null)).?;
    defer said.deinit(testing.allocator);
    try testing.expectEqualStrings("res://pictures/ada.png", said.files[0].path);
    try testing.expect(said.files[0].uid.?.eql(uid));
}

test "a file thrown away goes to the trash with its UUID, which names nothing after it" {
    var files: Files = try .init();
    defer files.tmp.cleanup();
    try files.picture("art/hero.png");
    const app = try files.app();
    defer app.destroy();
    if (comptime !@hasDecl(platform, "trash")) {
        try testing.expectError(error.Unsupported, app.moveToTrash("res://art/hero.png"));
        return;
    }
    // A trash of the test's own: the person's is not the test's to fill.
    var trash_buffer: [160]u8 = undefined;
    app.trash = try std.fmt.bufPrint(&trash_buffer, "{s}/Trash", .{try files.at()});
    const uid = try app.project.ensureUid("res://art/hero.png");

    try app.moveToTrash("res://art/hero.png");
    const dir = files.tmp.dir;
    try testing.expectError(error.FileNotFound, dir.access(testing.io, "art/hero.png", .{}));
    try testing.expectError(error.FileNotFound, dir.access(testing.io, "art/hero.png.uid", .{}));
    try dir.access(testing.io, "Trash/files/hero.png", .{});
    try dir.access(testing.io, "Trash/files/hero.png.uid", .{});
    try dir.access(testing.io, "Trash/info/hero.png.trashinfo", .{});
    try testing.expect(app.project.knownUid("res://art/hero.png") == null);
    try testing.expect(app.project.by_uid.get(uid) == null);

    // Another of the same name, beside the first; a folder, whole.
    try files.picture("art/hero.png");
    try app.moveToTrash("res://art/hero.png");
    try dir.access(testing.io, "Trash/files/hero.png.2", .{});
    try app.moveToTrash("res://art");
    try dir.access(testing.io, "Trash/files/art", .{});
    try testing.expectError(error.FileNotFound, app.moveToTrash("res://art"));
}

test "a new scene is written empty, never over another, and says what it is without being loaded" {
    var files: Files = try .init();
    defer files.tmp.cleanup();
    const app = try files.app();
    defer app.destroy();

    try app.createScene("res://levels.json", .{});
    try testing.expectError(error.PathAlreadyExists, app.createScene("res://levels.json", .{ .format = .cbor }));
    var said = (try app.sceneInfo("res://levels.json", null)).?;
    defer said.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, scene.version), said.version);
    try testing.expectEqual(@as(usize, 0), said.entities);
    try testing.expectEqual(@as(usize, 0), (try app.loadScene("res://levels.json", .{})).entities);

    try files.tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.json", .data = "{ \"hello\": 1 }" });
    try testing.expect(try app.sceneInfo("res://notes.json", null) == null);
}

test "a program in the background runs no systems until it is back, but for the frame it left in" {
    const Count = struct {
        var runs: usize = 0;
        var left: usize = 0;
        var back: usize = 0;

        fn look(a: *App) anyerror!void {
            runs += 1;
            if (a.input.justSuspended()) left += 1;
            if (a.input.justResumed()) back += 1;
        }
    };
    Count.runs = 0;
    Count.left = 0;
    Count.back = 0;
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "look", Count.look);

    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Count.runs);

    // Told between frames, as the next pump would tell it.
    app.input.apply(.suspended);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 2), Count.runs);
    try testing.expectEqual(@as(usize, 1), Count.left);

    for (0..3) |_| try testing.expect(try app.step());
    try testing.expectEqual(@as(usize, 2), Count.runs);

    app.input.apply(.resumed);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 3), Count.runs);
    try testing.expectEqual(@as(usize, 1), Count.back);
}

test "the time a program spent in the background is not a frame" {
    // The clock, not a fixed frame, so time away can be measured.
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    _ = try app.step();

    app.input.apply(.suspended);
    _ = try app.step();
    _ = try app.step();

    // Away for ever, as far as the clock can tell, and back.
    app.time.last = .zero;
    app.input.apply(.resumed);
    _ = try app.step();
    try testing.expectEqual(@as(f32, 0), app.time.unscaled_delta);
}

test "memory running low is told to the systems of one frame" {
    const Seen = struct {
        var low: usize = 0;

        fn look(a: *App) anyerror!void {
            if (a.input.lowMemory()) low += 1;
        }
    };
    Seen.low = 0;
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "look", Seen.look);

    app.input.apply(.low_memory);
    _ = try app.step();
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Seen.low);
}

test "the interface is laid out at the game's zoom times the display's scale" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    _ = try app.step();
    // No window, so no display to follow.
    try testing.expectEqual(@as(f32, 1), app.interface.display_scale);
    try testing.expectEqual(@as(f32, 1), app.interface.scale);

    app.interface.zoom = 1.25;
    _ = try app.step();
    try testing.expectEqual(@as(f32, 1.25), app.interface.scale);
}

test "a label's corners are the box its lines are laid out in" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    _ = app.assets.loadSystemFont(.{ .atlas = 256 }) catch return error.SkipZigTest;

    const one = try app.world.spawnWith(.{
        components.Transform2D.at(100, 50),
        components.Text2D.of("Hello"),
    });
    const corners = app.textCorners(one).?;
    // The transform is the top left of the first line, and the box goes
    // right and down from it.
    try testing.expectApproxEqAbs(@as(f32, 100), corners[0].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 50), corners[0].y, 0.001);
    try testing.expect(corners[2].x > corners[0].x);
    try testing.expect(corners[2].y > corners[0].y);
    const width = corners[2].x - corners[0].x;
    const height = corners[2].y - corners[0].y;

    // A second line is another line's height, and no wider for the same
    // words.
    const two = try app.world.spawnWith(.{
        components.Transform2D.at(100, 50),
        components.Text2D.of("Hello\nHello"),
    });
    const taller = app.textCorners(two).?;
    try testing.expectApproxEqAbs(width, taller[2].x - taller[0].x, 0.001);
    try testing.expectApproxEqAbs(height * 2, taller[2].y - taller[0].y, 0.01);

    // Centred, the same box sits astride the transform.
    const middle = try app.world.spawnWith(.{
        components.Transform2D.at(100, 50),
        components.Text2D{ .alignment = .center },
    });
    app.world.get(middle, components.Text2D).?.set("Hello");
    const centred = app.textCorners(middle).?;
    try testing.expectApproxEqAbs(100 - width / 2, centred[0].x, 0.001);
    try testing.expectApproxEqAbs(100 + width / 2, centred[2].x, 0.001);

    // Nothing to draw, nothing to outline: no words, and bytes that are
    // not words either, which the renderer passes over as well.
    const empty = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.Text2D{} });
    try testing.expect(app.textCorners(empty) == null);
    app.world.get(empty, components.Text2D).?.set(&.{ 0xff, 0xfe });
    try testing.expect(app.textCorners(empty) == null);
    try testing.expect(app.textCorners(.none) == null);
}

test "an entity is outlined by whichever of the two it is drawn as" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    _ = app.assets.loadSystemFont(.{ .atlas = 256 }) catch return error.SkipZigTest;

    const drawn = try app.world.spawnWith(.{
        components.Transform2D.at(0, 0),
        components.Sprite.solid(.white, 20, 10),
    });
    const written = try app.world.spawnWith(.{
        components.Transform2D.at(0, 0),
        components.Text2D.of("Hello"),
    });
    const neither = try app.world.spawnWith(.{components.Transform2D.at(0, 0)});

    const box = app.drawnCorners(drawn).?;
    try testing.expectApproxEqAbs(@as(f32, 20), box[2].x - box[0].x, 0.001);
    try testing.expect(app.drawnCorners(written) != null);
    try testing.expect(app.spriteCorners(written) == null);
    try testing.expect(app.drawnCorners(neither) == null);
}

const Beneath = struct {
    fn grid(app: *App) anyerror!void {
        app.debug_under.line2d(.init(-50, 0), .init(50, 0), .white);
        app.debug_under.line2d(.init(0, -50), .init(0, 50), .white);
    }

    fn stepped(app: *App) anyerror!void {
        app.debug_under.line2d(.init(0, 0), .init(1, 1), .white);
    }
};

test "what is drawn under the world is drawn in a pass of its own, before the sprites" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "grid", Beneath.grid);
    try app.addSystem(.update, "line", Scribble.line);
    _ = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.Sprite.solid(.white, 8, 8) });

    _ = try app.step();
    // Two under, one over, each counted where it was drawn.
    try testing.expectEqual(@as(u32, 2), app.debug_under_stats.lines);
    try testing.expectEqual(@as(u32, 1), app.debug_renderer.stats.lines);
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);

    // Hidden with the rest of `debug`.
    app.debug_visible = false;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.debug_under_stats.lines);
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
}

test "nothing under the world makes no pass of its own" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    _ = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.Sprite.solid(.white, 8, 8) });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.debug_under_stats.lines);
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
}

test "under the world as over it, a fixed step's shapes last until the next step" {
    const app = try App.create(testing.allocator, .{ .headless = true, .fixed_delta = 1.0 / 64.0 });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 256.0 };
    try app.addSystem(.fixed, "stepped", Beneath.stepped);

    // A step every fourth frame: its line is there from the first step on,
    // in the frames between the steps as well.
    try app.startup();
    for (1..13) |frame| {
        _ = try app.step();
        try testing.expectEqual(@as(u32, if (frame < 4) 0 else 1), app.debug_under_stats.lines);
    }
    try testing.expect(app.debug_under.canvas == &app.debug_under_frame);
}
