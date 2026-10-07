// SPDX-License-Identifier: BSD-3-Clause

//! What an `App` is made with: the backend it draws with, the window it
//! opens, the frame and the clock - what a game says in `Options`, over what
//! its project file says, over the engine's own.

const std = @import("std");

const platform = @import("fluxion_platform");
const rhi = @import("fluxion_rhi");
const json = @import("fluxion_json");
const vfs = @import("fluxion_vfs");

const Project = @import("../project/Project.zig");
const Window = @import("../platform/window.zig");
const geometry = @import("../math/geometry.zig");
const Color = @import("../math/color.zig").Color;

const WindowMode = Window.Mode;
const VsyncMode = Window.VsyncMode;
const Stretch = @import("../render/stretch.zig").Stretch;
const AudioOutput = @import("../audio/audio.zig").Output;
const PhysicsSettings = @import("fluxion_physics").Settings;

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

    /// The backend of a device that is open.
    pub fn of(tag: rhi.Backend) Backend {
        return switch (tag) {
            .gl => .gl,
            .d3d11 => .d3d11,
            .d3d12 => .d3d12,
            .vulkan => .vulkan,
            .webgl => .webgl,
            .none, .other => .none,
        };
    }
};

pub const BackendError = error{
    /// The project's renderer has no backend on this system: `modern` in a
    /// browser, or on macOS.
    RendererNotBuilt,
};

/// The backends a game is drawn with, the first to try first: `wanted`
/// alone, never another, unless it is `auto`, which is the project's
/// renderer's - see `Rendering.backendsFor`. Empty where its renderer has
/// none here, which `App.create` refuses rather than quietly drawing with
/// another renderer and hiding what the game really looks like.
pub fn backendsToTry(wanted: Backend, rendering: Project.Rendering, os: std.Target.Os.Tag, buffer: *[Project.Rendering.max_backends]Backend) []const Backend {
    if (wanted != .auto) {
        buffer[0] = wanted;
        return buffer[0..1];
    }
    return rendering.backendsFor(os, buffer);
}

/// Where the window opens.
pub const InitialPosition = enum {
    /// In the middle of the screen the system calls its primary.
    center_of_primary_screen,
    /// In the middle of the screen `screen` names, counting from nought.
    center_of_screen,
    /// At `position`, the top left of its content, on the desktop.
    absolute,
};

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
    stretch: ?Stretch = null,

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

    /// Where `program://` is: the folder of the files beside the program -
    /// what a launcher left there for the game. Null is the running
    /// program's own folder. A test gives its own. See `Project.programRoot`.
    program_root: ?[]const u8 = null,

    /// The program's command line, its own name first: what
    /// `commandArgument` reads. Borrowed, for as long as the app lives.
    arguments: []const []const u8 = &.{},
    /// What the address of the page the game runs in gives, as `name=value`:
    /// what `pageParameter` reads. A browser's runtime hands it over; there
    /// is none anywhere else. Borrowed, for as long as the app lives.
    page: []const []const u8 = &.{},

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
    clear_color: ?Color = null,

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
    audio: AudioOutput = .auto,

    /// A hundred units to the metre, for a world measured in pixels: what
    /// the physics' tolerances are scaled by. The engine keeps its own
    /// rules whatever the rest says: gravity is `physics_2d`'s, two
    /// colliders touch when either one's mask has the other's layer, and a
    /// pair's friction is the smaller and its bounce the sum.
    physics: PhysicsSettings = .{ .units_per_metre = 100 },

    /// How the 2D world moves - gravity, and what a body's damping of minus
    /// one means - for a game with no project file: the defaults, a gravity
    /// of 98 where a unit is a pixel. A project file's `physics_2d` is
    /// taken instead.
    physics_2d: Project.Physics2D = .{},

    /// The 3D physics' tolerances and solver, in metres. The engine keeps
    /// the same rules as in 2D whatever this says, and gravity is
    /// `physics_3d`'s.
    physics3d: @import("fluxion_physics3d").Settings = .{},

    /// How the 3D world moves - gravity, and what a body's damping of minus
    /// one means - for a game with no project file.
    physics_3d: Project.Physics3D = .{},
};

/// What the window, the frame and the clock are made with: the game's
/// `Options` where they say, the project file's `display`, `rendering` and
/// `physics_2d` where they do not, and the engine's own under both - which
/// are the sections' defaults, so a project that says nothing and a folder
/// with no project file open the same.
pub const Resolved = struct {
    width: u32,
    height: u32,
    stretch: Stretch,
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
    clear_color: Color,
    fixed_delta: f32,
    max_fixed_steps: u32,
    max_fps: ?f32,
    interface_zoom: f32,

    pub const default_fixed_delta: f32 = 1.0 / @as(f32, @floatFromInt((Project.Physics2D{}).ticks_per_second));

    pub fn of(options: Options, settings: ?*const Project.Settings, physics_2d: Project.Physics2D) Resolved {
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
            .clear_color = options.clear_color orelse rendering.clear_color,
            .fixed_delta = options.fixed_delta orelse 1.0 / @as(f32, @floatFromInt(@max(physics_2d.ticks_per_second, 1))),
            .max_fixed_steps = @max(physics_2d.max_steps_per_frame, 1),
            .max_fps = options.max_fps orelse if (application.max_fps > 0) @floatFromInt(application.max_fps) else null,
            .interface_zoom = if (gui.scale > 0) gui.scale else 1,
        };
    }
};
