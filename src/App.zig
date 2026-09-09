// SPDX-License-Identifier: BSD-3-Clause

//! The engine: a window, a device, a world, and the loop that turns one into
//! the other sixty times a second.
//!
//! ```zig
//! pub fn main(init: std.process.Init) !void {
//!     const app = try App.create(init.gpa, .{ .title = "game", .io = init.io });
//!     defer app.destroy();
//!
//!     try app.addSystem(.startup, spawnWorld);
//!     try app.addSystem(.fixed, movePaddles);
//!     try app.run();
//! }
//! ```
//!
//! **It is created on the heap, and that is not an accident.** The device
//! holds a pointer to the window's OpenGL hooks, the renderer holds a pointer
//! to the device, and the platform's window handle holds a pointer to its
//! context - all three of which are fields of this struct. A value that
//! something points at cannot be one that moves, and Zig moves a value on
//! every return and every assignment. `create` puts it at an address that
//! stays put; there is no `init` that hands one back by value, because that
//! function could not be written correctly.
//!
//! **The frame is fixed, and the stages are how a game gets into it.** See
//! `schedule` for the seven of them and what belongs in each. Nothing here is
//! virtual and nothing is registered by name: a stage is an array of function
//! pointers, and running one is a loop over it.
//!
//! **The layers are drawn back to front into one target.** Today that is the
//! 3D pass, which does not exist yet, and then the 2D pass. The interface
//! layer belongs on top of those and is not wired up, because the renderer
//! that would draw it always clears its pass and so can only be the first
//! thing in a target. Each layer is its own render pass into the same
//! surface: the first clears, the rest load what the one before it left.
//! Adding the third is one call in `render`.
//!
//! **A transform is local, and nothing caches the world one.** An entity's
//! parent is a field of its `Transform2D`, the way Unity puts it on
//! `Transform` and Godot puts it in the tree - and where a child really ends
//! up is worked out where it is needed rather than written into a second
//! component every frame. See `hierarchy`.
//!
//! **It runs without a window at all.** `.headless` opens the `none` backend,
//! which accepts every call and draws none of them, and steps a clock that
//! does not need a machine to read. Every test in this package runs that way,
//! and so does a build server.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const rhi = @import("fluxion_rhi");

const Assets = @import("assets.zig");
const Input = @import("input.zig");
const Time = @import("time.zig");
const Window = @import("window.zig");
const schedule_mod = @import("schedule.zig");
const hierarchy = @import("hierarchy.zig");
const sprite = @import("render/sprite.zig");

const Color = @import("color.zig").Color;
const Schedule = schedule_mod.Schedule;
const Stage = schedule_mod.Stage;
const System = schedule_mod.System;

const App = @This();
const log = std.log.scoped(.fluxion_engine);

pub const Error = error{
    /// A window was wanted and this machine has no display. Not the same as
    /// a broken program: see `Window.isAbsent`.
    NoDisplay,
} || Allocator.Error || rhi.Error || Window.Error || Assets.Error ||
    sprite.Error || ecs.Jobs.Error;

/// Which drawing API to open.
pub const Backend = enum {
    /// OpenGL, which is the best-travelled path through this stack. Chosen
    /// for `.auto` on every platform - Direct3D is one flag away, and being
    /// able to run the same game on both is what the RHI is for.
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

pub const Options = struct {
    title: []const u8 = "fluxion",
    width: u32 = 1280,
    height: u32 = 720,
    backend: Backend = .auto,
    vsync: bool = true,

    /// What files are read with, and what the clock is read from. Null means
    /// no files and a fixed step - which is what a test wants and what a
    /// browser build will want.
    io: ?std.Io = null,

    /// No window, no display, no GPU. The `none` backend, a texture to draw
    /// into instead of a surface, and a clock that advances by `fixed_delta`
    /// whether or not any time passed.
    headless: bool = false,

    /// What the frame is cleared to before anything is drawn.
    background: Color = .hex(0x0E1013),

    /// One fixed step, in seconds. Sixty a second.
    fixed_delta: f32 = 1.0 / 60.0,

    /// Stop after this many frames. What `--frames 120` is for, and what
    /// makes a run reproducible.
    ///
    /// Worth setting for a headless app: with no window to close, `run` ends
    /// only when a system calls `quit` or this counter runs out.
    frames: ?u32 = null,

    /// Worker threads for parallel queries. Null leaves it to the scheduler,
    /// which takes one fewer than the machine has cores.
    workers: ?u32 = null,
};

gpa: Allocator,
io: ?std.Io,

/// Null when headless.
window: ?Window = null,
device: rhi.Device,
/// What the frame is drawn into: a swapchain image, or a texture when there
/// is no window.
surface: ?rhi.Surface = null,
offscreen: ?rhi.Texture = null,

/// Everything in the game. A game's own components go in here beside the
/// engine's.
world: ecs.World,
/// What a parallel query runs on. See `ecs.Query.each`.
jobs: ecs.Jobs,

assets: Assets,
sprites: sprite.Renderer,

time: Time,

/// Where each interpolating transform was before the last fixed step.
///
/// Beside the world rather than in it, because it is the engine's own
/// bookkeeping: a game asks for smooth drawing by setting one flag on a
/// transform and never sees this. Only entities that asked are in here, so a
/// scene of static things costs nothing at all. See
/// `Transform2D.interpolate`.
snapshots: hierarchy.Snapshots = .empty,

input: Input = .{},
schedule: Schedule = .empty,

background: Color,

/// The size of the target, in pixels. Kept here rather than asked of the
/// window every time, because a headless app has no window to ask.
width: u32,
height: u32,

/// Cleared by `quit`, and by the frame counter running out.
running: bool = true,
frames_left: ?u32,
started: bool = false,

/// Open everything, in the order the pieces depend on each other.
pub fn create(gpa: Allocator, options: Options) Error!*App {
    const self = try gpa.create(App);
    errdefer gpa.destroy(self);

    // Every field, including the ones with a default beside them.
    //
    // `create` hands back uninitialised memory, and a field's default applies
    // to a *struct literal* rather than to whatever an allocator returned - so
    // filling the fields one at a time silently leaves the rest as whatever
    // was in that memory before. What that looked like here was
    // "beginPass: the surface is not alive" from a headless app that had no
    // surface and a `?Surface` full of rubbish, which is a long way from the
    // line that caused it. Assigning the whole struct once makes the compiler
    // the thing that notices a missing field.
    self.* = .{
        .gpa = gpa,
        .io = options.io,
        .window = null,
        .device = undefined,
        .surface = null,
        .offscreen = null,
        .world = .init(gpa),
        .jobs = undefined,
        .assets = undefined,
        .sprites = undefined,
        .time = .init(if (options.io) |io| .{ .clock = io } else .{ .fixed = options.fixed_delta }),
        .snapshots = .empty,
        .input = .{},
        .schedule = .empty,
        .background = options.background,
        .width = options.width,
        .height = options.height,
        .running = true,
        .frames_left = options.frames,
        .started = false,
    };
    errdefer self.world.deinit();
    self.time.fixed_delta = options.fixed_delta;

    const backend = if (options.headless) .none else options.backend.resolve();

    // The window has to come first and has to know whether it is being asked
    // for an OpenGL context, because no platform lets a window change its
    // mind about that afterwards. Which is why the backend is chosen before
    // anything is opened rather than negotiated after.
    if (!options.headless) {
        // Opened at its final address rather than returned into it: the
        // window's own handle points at the context beside it. See `window`.
        self.window = @as(Window, undefined);
        self.window.?.open(gpa, .{
            .title = options.title,
            .width = options.width,
            .height = options.height,
            .gl = backend == .gl,
            .vsync = options.vsync,
        }) catch |err| {
            self.window = null;
            if (Window.isAbsent(err)) return Error.NoDisplay;
            return err;
        };
    }
    errdefer if (self.window) |*w| w.close();

    const width = if (self.window) |*w| w.width else options.width;
    const height = if (self.window) |*w| w.height else options.height;
    self.width = width;
    self.height = height;

    self.device = try .init(gpa, .{
        .backend = switch (backend) {
            .gl => .gl,
            .d3d11 => .d3d11,
            .none => .none,
            .auto => .auto,
        },
        // Only OpenGL wants the context. Direct3D makes its own device and
        // takes the window handle at surface time instead, which is why this
        // is the one place the two backends look different from up here.
        .gl = if (backend == .gl and self.window != null) self.window.?.hooks() else null,
    });
    errdefer self.device.deinit();

    if (self.window) |*w| {
        self.surface = try self.device.createSurface(.{
            .native_window = w.nativeHandle(),
            .width = width,
            .height = height,
        });
    } else {
        // No window, so the frame goes into a texture. Not a stub: every
        // draw call the real path makes is made here too, which is what
        // makes a test on a machine with no display worth running.
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

    return self;
}

pub fn destroy(self: *App) void {
    const gpa = self.gpa;

    self.schedule.deinit(gpa);
    self.snapshots.deinit(gpa);
    self.sprites.deinit(gpa);
    self.assets.deinit();
    self.jobs.deinit();
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

/// Add a system to a stage. See `schedule`.
pub fn addSystem(self: *App, stage: Stage, system: System) Allocator.Error!void {
    return self.schedule.add(self.gpa, stage, system);
}

/// The same, with a name for a profile or a failure message.
pub fn addNamedSystem(
    self: *App,
    stage: Stage,
    name: []const u8,
    system: System,
) Allocator.Error!void {
    return self.schedule.addNamed(self.gpa, stage, name, system);
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

/// One frame. Says whether there should be another.
///
/// Public because a game with its own idea of a loop - a test stepping
/// frames, an editor drawing into a panel - should not have to give up the
/// rest of the engine to have it.
pub fn step(self: *App) anyerror!bool {
    if (!self.running) return false;

    // Edges first, then this frame's events on top of them. Doing it the
    // other way round would throw away the input the pump just gathered.
    self.input.beginFrame();

    if (self.window) |*window| {
        if (!window.pump(&self.input)) {
            self.running = false;
            return false;
        }
        if (window.resized) {
            window.resized = false;
            self.width = window.width;
            self.height = window.height;
            if (self.surface) |surface| {
                try self.device.resizeSurface(surface, self.width, self.height);
            }
        }
    }

    self.time.tick();

    try self.schedule.run(.input, self);

    // A backlog too big to work through is dropped rather than chased, which
    // makes a stalled frame show up as the world running slow for a moment
    // instead of as the loop never finishing. See `Time.max_fixed_steps`.
    self.time.dropBacklog();
    while (self.time.takeFixedStep()) |_| {
        // Where everything was before this step, for drawing the frame
        // somewhere between this step and the last. See `Previous2D`.
        try self.snapshotPrevious();
        try self.schedule.run(.fixed, self);
    }

    try self.schedule.run(.update, self);
    try self.schedule.run(.late, self);

    // The engine's own pass over the world, after everything a game does and
    // before anything is drawn. Here rather than registered as a system in
    // `.late` on purpose: a system added at `create` would run *before* a
    // game's own late systems.
    //
    // Parented transforms are not resolved here, or anywhere: the renderer
    // works out where a child ended up when it draws it, and
    // `worldTransform` answers the same question for a game that asks. See
    // `hierarchy`.
    try self.animate();

    try self.render();

    if (self.frames_left) |left| {
        if (left <= 1) {
            self.running = false;
        } else {
            self.frames_left = left - 1;
        }
    }

    return self.running;
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
///
/// On the frame's own delta rather than the fixed step, because an animation
/// is something a viewer sees and not something the simulation depends on -
/// so it runs once a frame however many times physics did.
fn animate(self: *App) !void {
    const delta = self.time.delta;

    var it = try ecs.Query(.{ components.Sprite, components.Animation }).over(&self.world);
    while (it.next()) |chunk| {
        for (chunk.slice(components.Sprite), chunk.slice(components.Animation)) |*drawn, *animation| {
            drawn.region = animation.advance(delta);
        }
    }
}

/// Where an entity really is, with every parent above it applied.
///
/// Godot's `global_position` and Unity's `transform.position`, and it costs
/// what those cost: a walk up the chain rather than a field read. Null when
/// the entity has no transform, or when something it hangs from has died.
///
/// A transform with no parent is its own answer, so this is a comparison and
/// a copy for almost everything in a scene.
pub fn worldTransform(self: *App, entity: ecs.Entity) ?components.Transform2D {
    return hierarchy.resolveEntity(&self.world, &self.snapshots, entity, self.time.alpha());
}

/// Remember where every interpolating transform is, before a step moves it.
///
/// Cleared and refilled rather than added to, so an entity that died does not
/// sit in the table for the rest of the session. The capacity is kept, so
/// after the first step this allocates nothing.
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

/// Every layer, in order, into whatever it is given.
///
/// Separate from `render` so that `capture` can send the same frame somewhere
/// else. A layer that only worked when it was drawn into a window would be a
/// layer nothing could check.
fn drawLayers(self: *App, into: rhi.RenderTarget, width: f32, height: f32) !void {
    // 1. The 3D layer, with a depth test, clearing the frame. Not written
    //    yet. When it is, this is where it goes and the 2D pass below stops
    //    clearing - which is the whole of what the second layer costs.

    // 2. The 2D layer: sprites, sorted back to front, blended, no depth.
    try self.sprites.draw(
        self.gpa,
        &self.world,
        &self.assets,
        &self.snapshots,
        into,
        width,
        height,
        self.background,
        self.time.alpha(),
    );

    // 3. The interface layer, over everything, in screen coordinates. Not
    //    here yet: it would have to load this pass rather than clear, and
    //    the renderer that draws it has no way to be asked for that.
}

/// Draw one frame into a texture of its own and hand back the pixels.
///
/// Four bytes a pixel, top row first, and the caller owns them. Nothing about
/// the layers changes: the same passes run against a texture instead of a
/// swapchain image, which is what makes a capture worth comparing against
/// what a player sees.
///
/// This is how a machine with no eyes checks the picture - a screenshot in a
/// script, a test that counts coloured pixels, a build server comparing two
/// backends. The alternative is reading back a swapchain image, which not
/// every backend can do.
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

/// Read the frame that was last drawn, as `width * height * 4` bytes.
///
/// Only when headless, because only then is the target a texture: a
/// swapchain image cannot be read back on every backend, and a function that
/// worked in a test and not in a game would be worse than one that says so.
/// The caller owns what comes back.
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
        // Without this - or a system that calls `quit` - `run` is an
        // infinite loop, because a headless app has no window to close.
        .frames = 1,
    });
    defer app.destroy();

    try app.addSystem(.startup, spawnOne);
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

    // With no camera in the world the view is the window: the origin at the
    // top left, one unit to the pixel.
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
    // A real font off this machine, and a real glyph atlas. Skipped rather
    // than failed where there is no font to read: a build server has none,
    // and everything else in this file has to keep running there.
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

    // Three letters, three quads, and three glyphs in the atlas that was
    // empty a moment ago.
    try testing.expectEqual(@as(u32, 3), app.sprites.drawn);
    const face = app.assets.fontOf(.none).?;
    try testing.expectEqual(@as(usize, 3), face.atlas.count());

    // And the second frame draws the same letters without rasterising any of
    // them again, which is the whole point of an atlas.
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

    try app.addSystem(.update, countFrames);
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

    // And the component itself still says what was written into it, which is
    // the difference between this and a pass that resolves in place.
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

test "a child of something that died has no world position" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    const carrier = try app.world.spawnWith(.{components.Transform2D.at(60, 60)});
    const held = try app.world.spawnWith(.{components.Transform2D.childOf(carrier, 4, 0)});

    app.world.despawn(carrier);
    try app.run();

    try testing.expect(app.worldTransform(held) == null);
}

test "an animation moves the sprite's region on" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 6,
        // Every frame a tenth of a second, so six frames is six cells at
        // ten a second: back to the start of a four-cell strip, plus two.
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

    // Every frame is a fiftieth of a second, and a fixed step is a hundredth,
    // so each frame is worth two of them.
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 10,
        .fixed_delta = 0.01,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.02 };

    try app.addSystem(.fixed, counter.count);
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
    // A frame is worth one and a half fixed steps: one step runs, and half
    // a step is left over for the renderer to blend by.
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 1,
        .fixed_delta = 0.01,
    });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.015 };

    try app.addSystem(.startup, spawnInterpolated);
    try app.addSystem(.fixed, slideRight);
    try app.run();

    var it = try ecs.Query(.{components.Transform2D}).over(&app.world);
    const chunk = it.next().?;
    const entity = chunk.entities[0];
    const now = chunk.slice(components.Transform2D)[0];

    // Where it is, where it was, and halfway between - which is what the
    // renderer draws, and what a game asking for a world position gets.
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

    // Nothing in the table, so a scene of static things pays nothing for a
    // feature it does not use.
    try testing.expectEqual(@as(usize, 0), app.snapshots.count());
}
