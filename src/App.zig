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

const Assets = @import("assets.zig");
const Bodies = @import("bodies.zig");
const Clipboard = @import("clipboard.zig");
const Commands = @import("commands.zig");
const Interface = @import("interface.zig");
const Input = @import("input.zig");
const Time = @import("time.zig");
const Window = @import("window.zig");
const schedule_mod = @import("schedule.zig");
const hierarchy = @import("hierarchy.zig");
const scene = @import("scene.zig");
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
    sprite.Error || ecs.Jobs.Error || debugdraw_rhi.Error;

/// Which drawing API to open.
pub const Backend = enum {
    /// OpenGL, on every platform for now.
    auto,
    gl,
    d3d11,
    /// Accepts everything, draws nothing. What `.headless` uses.
    none,

    fn resolve(self: Backend) Backend {
        return switch (self) {
            .auto => .gl,
            else => self,
        };
    }
};

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
    title: []const u8 = "fluxion",
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

    /// Every frame counts as exactly this many seconds, whatever the clock
    /// says, so every run is the same. `Flags.apply` sets it for `--capture`.
    frame_time: ?f32 = null,

    /// A key that ends the game, handled after the `.input` stage. Null leaves
    /// every key to the game.
    quit_key: ?platform.Key = null,

    /// A key that toggles borderless fullscreen, handled the same way. F11
    /// rather than Alt+Enter, which DXGI answers on its own on `d3d11`.
    fullscreen_key: ?platform.Key = null,

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

assets: Assets,
sprites: sprite.Renderer,

/// Lines, shapes and text drawn over everything, for one frame unless its
/// style says for how many seconds. Inside `.fixed` they last until the next
/// step instead, so a step's shapes are there in the frames between steps.
debug: debugdraw.Pen,
debug_frame: debugdraw.Canvas,
debug_steps: debugdraw.Canvas,
debug_renderer: debugdraw_rhi.Renderer,

/// What `.ui` systems declare the interface into.
ui: ui_lib.Ui,
/// How the interface is fed and drawn: its font, scale and safe area.
interface: Interface = .{},

/// The system's clipboard, or the program's own without a window. See
/// `setClipboardText`.
clipboard: Clipboard = .{},

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

/// What a scene can hold, and what each component is called in one: the
/// engine's own from the start, and a game's once `registerComponents` has
/// been told about them.
scene_components: scene.Registry = .{},

input: Input = .{},
schedule: Schedule = .empty,

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
        .assets = undefined,
        .sprites = undefined,
        .debug = undefined,
        .debug_frame = .init(gpa),
        .debug_steps = .init(gpa),
        .debug_renderer = undefined,
        .ui = .init(gpa),
        .interface = .{},
        .clipboard = .{},
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
        .scene_components = .{},
        .input = .{},
        .schedule = .{ .io = options.io, .commands = &self.commands },
        .background = options.background,
        .world_on_screen = true,
        .width = options.width,
        .height = options.height,
        .resized = false,
        .quit_key = options.quit_key,
        .fullscreen_key = options.fullscreen_key,
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

    errdefer self.scene_components.deinit(gpa);
    inline for (.{
        components.Transform2D,
        components.Sprite,
        components.Text2D,
        components.Animation,
        components.Camera2D,
        components.RigidBody2D,
        components.Collider2D,
    }) |T| {
        self.scene_components.add(gpa, T, comptime scene.nameOf(T)) catch |err| switch (err) {
            error.ComponentNameTaken => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    const backend = if (options.headless) .none else options.backend.resolve();

    // The window comes first, and has to know whether to make an OpenGL
    // context: no platform lets a window change its mind about that.
    if (!options.headless) {
        // Opened in place: its handle points at the context beside it.
        self.window = @as(Window, undefined);
        self.window.?.open(gpa, .{
            .title = options.title,
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

    self.device = try .init(gpa, .{
        .backend = switch (backend) {
            .gl => .gl,
            .d3d11 => .d3d11,
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

    self.assets = try .init(gpa, &self.device, options.io);
    errdefer self.assets.deinit();

    self.sprites = try .init(gpa, &self.device);
    errdefer self.sprites.deinit(gpa);

    self.debug_renderer = try .init(gpa, &self.device, .{});
    errdefer self.debug_renderer.deinit();
    self.debug = self.debug_frame.pen();

    return self;
}

pub fn destroy(self: *App) void {
    const gpa = self.gpa;

    self.schedule.deinit(gpa);
    self.snapshots.deinit(gpa);
    self.orphans.deinit(gpa);
    for (self.names.values()) |name| gpa.free(name);
    self.names.deinit(gpa);
    self.by_name.deinit(gpa);
    self.scene_components.deinit(gpa);
    self.bodies.deinit(gpa);
    self.physics.deinit();
    self.debug_renderer.deinit();
    self.debug_steps.deinit();
    self.debug_frame.deinit();
    self.interface.deinit();
    self.clipboard.deinit(gpa);
    self.ui.deinit();
    self.sprites.deinit(gpa);
    self.assets.deinit();
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
    return self.schedule.add(self.gpa, stage, name, system);
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

/// Run the `.startup` stage, once. Doing it twice does nothing.
pub fn startup(self: *App) anyerror!void {
    if (self.started) return;
    self.started = true;
    try self.schedule.run(.startup, self);
}

/// One frame. Says whether there should be another. Public for a game that
/// drives its own loop.
pub fn step(self: *App) anyerror!bool {
    if (!self.running) return false;

    // The old edges go first, then this frame's events. The resize flag is an
    // edge too.
    self.input.beginFrame();
    self.schedule.beginFrame();
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

    self.time.tick();
    self.debug_frame.advance(self.time.delta);
    if (self.hasInterface()) try self.feedInterface();

    // What was asked for outside any system - between frames, by a tool -
    // is done before the first system of this one.
    try self.commands.apply();

    // Bodies are synced before each fixed step. A paused frame - and the
    // first, which has no time to step - is synced here instead, so the
    // queries find what was spawned.
    self.bodies.beginFrame();
    if (self.time.delta == 0) try self.bodies.sync(self);

    try self.schedule.run(.input, self);
    self.shortcuts();

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

        while (self.time.takeFixedStep()) |_| {
            self.debug_steps.advance(self.time.fixed_delta);
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

    // The engine's own passes, after the game's `.late` systems and before
    // drawing: whatever hung from something despawned goes with it, and then
    // the names of everything that died are given back.
    try self.despawnOrphans();
    self.forgetDeadNames();
    try self.animate();

    if (self.hasInterface()) try self.layOutInterface();

    const minimized = self.windowState() == .minimized;
    if (!minimized) try self.render();

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
}

fn hasInterface(self: *const App) bool {
    return self.schedule.systemsIn(.ui).len != 0;
}

/// Before the `.input` stage, so a game system can ask `app.ui.wantsPointer()`
/// about this frame.
fn feedInterface(self: *App) !void {
    if (self.interfaceFace()) |face| self.ui.setMeasurer(Interface.measurer(face));
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
    if (self.window) |*window| self.interface.applyCursor(&self.ui, window);
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
/// are told apart. Registering one twice does nothing.
pub fn registerComponents(self: *App, comptime types: anytype) scene.Registry.Error!void {
    inline for (types) |T| try self.scene_components.add(self.gpa, T, comptime scene.nameOf(T));
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

/// Everything out of the world at once - every entity and every name - and
/// an empty world in its place: a level loaded over another is this and then
/// `loadScene`. Not from inside a query, which is walking the world it
/// throws away.
pub fn clearWorld(self: *App) void {
    self.bodies.clear(self);
    self.commands.clear();
    self.world.deinit();
    self.world = .init(self.gpa);
    self.snapshots.clearRetainingCapacity();
    self.orphans.clearRetainingCapacity();
    for (self.names.values()) |name| self.gpa.free(name);
    self.names.clearRetainingCapacity();
    self.by_name.clearRetainingCapacity();
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
        try self.sprites.draw(self.gpa, &self.world, &self.assets, &self.snapshots, into, view, self.background, self.time.alpha());
    } else try self.clearTarget(into);

    // 3. The interface, on top, loading what the 2D layer left.
    try self.interface.draw(self.gpa, &self.device, self.interfaceFace(), into, width, height);

    // 4. `debug`, over all of it: the world through the 2D camera, and the
    //    screen in pixels.
    if (self.world_on_screen) try self.drawDebug(into, view);
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
    try self.sprites.draw(self.gpa, &self.world, &self.assets, &self.snapshots, .{ .texture = into }, view, self.background, self.time.alpha());
    try self.drawDebug(.{ .texture = into }, view);
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
/// asks for. `error.NoIo` without `Options.io`.
pub fn saveCapture(self: *App, path: []const u8) !void {
    const io = self.io orelse return error.NoIo;

    const pixels = try self.capture(self.gpa, self.width, self.height);
    defer self.gpa.free(pixels);

    try image.png.writeFile(self.gpa, io, path, .{
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
    const state = struct {
        var frames: u32 = 0;
    };
    state.frames += 1;
    if (state.frames >= 3) app.quit();
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
