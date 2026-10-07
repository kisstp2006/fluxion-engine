// SPDX-License-Identifier: BSD-3-Clause

//! One frame, in order: the engine's own passes and the game's stages
//! between them, as lists `App.step` runs. Read top to bottom, they are
//! what a frame does.
//!
//! A pass is a function of the app. **After every pass the signals it said
//! are heard**, so what a timer's `timeout`, a button's `pressed` or a
//! particle emitter's `finished` sets off happens before the next pass, and
//! nothing waits for a later one to be heard. A stage's systems are heard
//! after each system the same way: see `core/schedule.zig`.
//!
//! What a pass moves by is `app.time.delta`: the frame's, or inside the
//! fixed steps, the step's.

const std = @import("std");

const App = @import("../App.zig");
const Interface = @import("../ui/interface.zig");
const Stage = @import("../core/schedule.zig").Stage;
const States = @import("../core/states.zig");
const animation = @import("../animation/animation.zig");
const skeleton = @import("../render/skeleton.zig");
const cameras = @import("../render/cameras.zig");
const current_scene = @import("../scene/current_scene.zig");
const display = @import("display.zig");
const game_clocks = @import("../time/game_clocks.zig");
const hierarchy = @import("../scene/hierarchy.zig");
const layers = @import("../render/layers.zig");
const particles = @import("../render/particles.zig");
const ray_casts = @import("../physics/ray_casts.zig");
const ray_casts3d = @import("../physics3d/ray_casts3d.zig");
const sprite_frames = @import("../animation/sprite_frames.zig");
const tile_chunks = @import("../tiles/tile_chunks.zig");
const timer = @import("../time/timer.zig");
const touch_button = @import("../ui/touch_button.zig");
const tree = @import("../scene/tree.zig");
const tween = @import("../animation/tween.zig");
const web = @import("../net/web.zig");

const log = std.log.scoped(.fluxion_engine);

/// One thing a frame does.
pub const Step = union(enum) {
    /// The engine's own work, after which the signals are heard.
    pass: *const fn (app: *App) anyerror!void,
    /// The game's systems of a stage.
    stage: Stage,
    /// As many fixed steps as the time that passed makes room for, each one
    /// of these steps; with `app.time.delta` the step's and the input's
    /// edges counted since the last.
    fixed_steps: []const Step,
};

/// What every frame does with the window's news, even one that runs
/// nothing else because the program is in the background.
pub const news = [_]Step{
    // The web's answers, whoever asked: nothing on its way is lost while
    // the program is away.
    .{ .pass = web.collect },
    .{ .pass = touch_button.update },
    .{ .pass = actions },
    .{ .pass = fitGameArea },
};

/// The rest of a frame, unless the program is in the background.
pub const order = [_]Step{
    .{ .pass = tick },
    .{ .pass = fingers },
    .{ .pass = freshFrame },
    .{ .pass = feedInterface },
    .{ .pass = commands },
    .{ .pass = States.changeAsked },
    .{ .pass = bodiesBeforeTheSteps },

    // The frame's input: each script's `input` and `unhandled_input`, then
    // the game's systems, then the engine's keys and what the pointer is
    // over - after the game's own input systems, which may take the
    // pointer with `input.setAsHandled`.
    .{ .pass = scriptsHearInput },
    .{ .stage = .input },
    .{ .pass = engineKeys },
    .{ .pass = pointerSpeed },
    .{ .pass = picking },

    .{ .fixed_steps = &fixed_step },

    // What moves with the frame's time, before the game's `.update`
    // systems: a timer's `timeout` or a tween's `finished` is heard by
    // what runs after.
    .{ .pass = freshInherited },
    .{ .pass = gameClocks },
    .{ .pass = frameTimers },
    .{ .pass = tween.update },
    .{ .pass = animation.update },
    .{ .pass = skeleton.update },
    .{ .pass = sprite_frames.update },
    .{ .pass = scriptsUpdate },
    .{ .stage = .update },
    .{ .stage = .late },
    // Deferred signal calls: after `.late`, before the engine's own
    // passes, so what they despawn is gone by the draw.
    .{ .pass = deferredSignals },

    // The engine's own passes, after the game's: the scene `changeScene`
    // asked for, a load with no thread of its own worked a piece, whatever
    // hung from something despawned gone with it, every player's sound as
    // its component says and every emitter's particles moved on - and
    // then what the dead left let go of.
    .{ .pass = current_scene.openAsked },
    .{ .pass = backgroundLoads },
    .{ .pass = tree.despawnOrphans },
    .{ .pass = tile_chunks.despawnOrphans },
    .{ .pass = sound },
    .{ .pass = emitters },
    .{ .pass = scriptsEndOfFrame },
    .{ .pass = forgetTheDead },

    // Every animated sprite's frame in its Sprite, and every smoothed
    // camera a step nearer, after all that could change them; then what
    // the frame shows, laid out and drawn.
    .{ .pass = sprite_frames.show },
    .{ .pass = cameras.follow },
    .{ .pass = debugViews },
    .{ .pass = freshInherited },
    .{ .pass = layOut },
    .{ .pass = skeleton.update },
    .{ .pass = skeleton.drawBones },
    .{ .pass = textureMips },
    .{ .pass = draw },
};

/// One fixed step.
pub const fixed_step = [_]Step{
    .{ .pass = freshStep },
    .{ .pass = fixedTimers },
    .{ .pass = scriptsFixed },
    .{ .stage = .fixed },
    .{ .pass = navigationAvoidance },
    .{ .pass = physics },
    .{ .pass = fixedEdgesHeard },
};

/// Run `steps`, in order.
pub fn run(app: *App, steps: []const Step) anyerror!void {
    for (steps) |step| switch (step) {
        .pass => |pass| {
            try pass(app);
            try app.signals.drain(app);
        },
        .stage => |stage| try app.schedule.run(stage, app),
        .fixed_steps => |inner| try fixedSteps(app, inner),
    };
}

fn fixedSteps(app: *App, steps: []const Step) anyerror!void {
    // A backlog too big to work through is dropped. See
    // `Time.max_fixed_steps`.
    app.time.dropBacklog();
    {
        // Inside, the edges are counted since the last step and
        // `time.delta` is the step. Both are put back with `defer`, so a
        // step that fails leaves nothing wrong for what comes after.
        app.input.clock = .fixed;
        defer app.input.clock = .frame;
        const frame_delta = app.time.delta;
        app.time.delta = app.time.fixed_delta;
        defer app.time.delta = frame_delta;
        app.debug.canvas = &app.debug_steps;
        defer app.debug.canvas = &app.debug_frame;
        app.debug_under.canvas = &app.debug_under_steps;
        defer app.debug_under.canvas = &app.debug_under_frame;

        while (app.time.takeFixedStep()) |_| try run(app, steps);
    }
    // A paused frame gives the fixed stage no time, and so no edges: a key
    // pressed on a pause menu must not reach the first step after it.
    if (app.time.delta == 0) app.input.endFixedStep();
}
/// Every action from this frame's keys, buttons, sticks and touch buttons,
/// for the interface and the first system alike.
fn actions(app: *App) anyerror!void {
    app.input.updateActions();
    for (app.tool_windows.items) |tool| tool.input.updateActions();
}

/// The area the game is drawn in, and the interface's scale, fitted to the
/// window as it is now.
fn fitGameArea(app: *App) anyerror!void {
    display.fitGameArea(app);
    display.fitInterface(app);
}

// The frame's start.

/// The clock moved on. Coming back from the background starts it again, so
/// the time away is not a frame.
fn tick(app: *App) anyerror!void {
    if (app.input.justResumed()) app.time.restart();
    app.time.tick();
}

/// What the fingers made - taps, swipes, two fingers' pinch - for the
/// scripts to hear with the rest of the frame's input.
fn fingers(app: *App) anyerror!void {
    app.input.trackFingers(app.time.unscaled_delta);
}

/// What is inherited worked out afresh, the schedule told of the pause - a
/// game that wrote `paused` itself is taken at its word - and the frame's
/// debug shapes aged.
fn freshFrame(app: *App) anyerror!void {
    app.inherited.forget();
    app.schedule.paused = app.paused;
    app.debug_frame.advance(app.time.delta);
    app.debug_3d_frame.advance(app.time.delta);
    app.debug_under_frame.advance(app.time.delta);
}

/// The interface's input, before the `.input` stage, so a game system can
/// ask `app.ui.wantsPointer()` about this frame. Only for a game that has
/// an interface.
fn feedInterface(app: *App) anyerror!void {
    if (!app.hasInterface()) return;
    if (!app.interface.fillFaces(&app.assets).isEmpty()) app.ui.setMeasurer(Interface.measurer(&app.interface.faces));
    // Asked of the system when the wheel turned, so a changed setting is
    // taken at once - and only then, since on Linux asking reads a file.
    if (app.input.wheel.x != 0 or app.input.wheel.y != 0) {
        if (app.window) |*window| app.interface.scroll_lines = window.scrollLines();
    }
    try app.interface.feed(app.gpa, &app.ui, &app.input, &app.clipboard, app.time.unscaled_delta);
}

/// What was asked for outside any system - between frames, by a tool - done
/// before the first system of this one.
fn commands(app: *App) anyerror!void {
    try app.commands.apply();
}

/// Bodies are synced before each fixed step. A frame with no time - and the
/// first, which has no time to step - is synced here instead, so the
/// queries find what was spawned, and so is a paused game's, whose steps
/// move no body.
fn bodiesBeforeTheSteps(app: *App) anyerror!void {
    app.bodies.beginFrame();
    app.bodies3d.beginFrame();
    if (app.time.delta == 0 or app.paused) {
        try app.bodies.sync(app);
        try app.bodies3d.sync(app);
    }
}

// The input.

fn scriptsHearInput(app: *App) anyerror!void {
    if (app.scripts) |scripts| try scripts.calls.pass(scripts, .input);
}

/// The engine's own keys: quitting, the fullscreen key, the debug views.
fn engineKeys(app: *App) anyerror!void {
    if (app.quit_key) |key| {
        if (app.input.justPressed(key)) app.quit();
    }
    if (app.fullscreen_key) |key| {
        if (app.input.justPressed(key)) app.toggleFullscreen() catch |err| {
            log.warn("could not change fullscreen: {t}", .{err});
        };
    }
    if (app.debug_key) |key| {
        if (app.input.justPressed(key)) app.debug_visible = !app.debug_visible;
    }
}

/// The pointer's speed, from everything this frame has said of it,
/// including what an `.input` system put in.
fn pointerSpeed(app: *App) anyerror!void {
    app.input.trackPointer(app.time.unscaled_delta);
}

/// What the pointer is over in the world, pressed and let go of: before the
/// first step.
fn picking(app: *App) anyerror!void {
    try app.picking.update(app);
    try app.picking3d.update(app);
}

// A fixed step.

/// What is inherited worked out afresh, the step's debug shapes aged, and
/// where everything was before this step kept, to draw between steps.
fn freshStep(app: *App) anyerror!void {
    app.inherited.forget();
    app.debug_steps.advance(app.time.fixed_delta);
    app.debug_under_steps.advance(app.time.fixed_delta);
    try hierarchy.snapshot(app.gpa, &app.world, &app.snapshots);
    try hierarchy.snapshot3D(app.gpa, &app.world, &app.snapshots3d);
}

fn fixedTimers(app: *App) anyerror!void {
    try timer.count(app, .fixed);
}

fn scriptsFixed(app: *App) anyerror!void {
    if (app.scripts) |scripts| try scripts.calls.pass(scripts, .{ .fixed = app.time.delta });
}

/// After the game's `.fixed` systems, so what they wrote into the components
/// is in this step. Nothing moves a paused game's bodies: there is one
/// physics. What the step found each area holding, and what each ray met,
/// is said before the systems of the next step run.
fn physics(app: *App) anyerror!void {
    if (app.paused) return;
    try app.bodies.sync(app);
    try app.physics.step(app.time.delta, &app.jobs);
    try app.bodies.afterStep(app);
    try app.areas.update(app);
    try ray_casts.updateAll(app);
    try app.bodies3d.sync(app);
    try app.physics3d.step(app.time.delta);
    try app.bodies3d.afterStep(app);
    try app.areas3d.update(app);
    try ray_casts3d.updateAll(app);
}

/// What the agents said they want this step, each given the velocity that
/// keeps it out of the others' way - heard before the physics step, so a
/// character moved by it moves in this step.
fn navigationAvoidance(app: *App) anyerror!void {
    if (app.paused) return;
    try app.navigation.avoid(app, app.time.delta);
}

/// Seen, so gone: the next step hears only what comes after.
fn fixedEdgesHeard(app: *App) anyerror!void {
    app.input.endFixedStep();
}

// What moves with the frame.

/// What is inherited worked out afresh: what the systems changed of it is
/// seen by what comes after.
fn freshInherited(app: *App) anyerror!void {
    app.inherited.forget();
}

fn gameClocks(app: *App) anyerror!void {
    app.clocks.step(app.time.delta, app, game_clocks.runsIn);
}

fn frameTimers(app: *App) anyerror!void {
    try timer.count(app, .update);
}

fn scriptsUpdate(app: *App) anyerror!void {
    if (app.scripts) |scripts| try scripts.calls.pass(scripts, .{ .update = app.time.delta });
}

fn deferredSignals(app: *App) anyerror!void {
    try app.signals.flushDeferred(app);
}

// The engine's own passes.

fn backgroundLoads(app: *App) anyerror!void {
    app.loads.work();
}

fn sound(app: *App) anyerror!void {
    try app.audio.update(app);
}

fn emitters(app: *App) anyerror!void {
    try particles.update(app, app.time.delta, .game);
}

/// The scripts of the dead, and of what lost its `Script`, hear `exit` in
/// the frame it happened.
fn scriptsEndOfFrame(app: *App) anyerror!void {
    if (app.scripts) |scripts| try scripts.calls.pass(scripts, .end_of_frame);
}

fn forgetTheDead(app: *App) anyerror!void {
    app.forgetTheDead();
}

/// The chains of levels the last frame's 3D surfaces asked their pictures
/// for, made between frames. See `Assets.wantMips`.
fn textureMips(app: *App) anyerror!void {
    app.assets.makeWantedMips();
}

fn debugViews(app: *App) anyerror!void {
    if (app.debug_visible and app.debug_views.any()) try app.debug_views.draw(app);
}

// What the frame shows.

/// The interface laid out - every `.ui` system under one root - and the
/// tool windows'.
fn layOut(app: *App) anyerror!void {
    if (app.hasInterface()) {
        app.interface.commands = &.{};
        app.ui.begin(app.interface.surface(@floatFromInt(app.game_area.width), @floatFromInt(app.game_area.height)));
        {
            // One root for every `.ui` system: fluxion-ui makes the first
            // element the root, so a second system's would land beside it.
            // `.grow`, because fluxion-ui gives a `.fit` root its content's
            // height.
            app.ui.open(.{ .width = .grow, .height = .grow });
            defer app.ui.close();
            try app.schedule.run(.ui, app);
        }
        app.interface.commands = try app.ui.end();
        app.cursors.want(app.ui.cursor());
        if (app.window) |*window| {
            app.cursors.apply(window);
            app.interface.applyTextInput(&app.ui, window.handle);
        }
    }
    for (app.tool_windows.items) |tool| try tool.layOut(app);
}

/// The frame drawn, and the tool windows'. Nothing to draw on while the
/// window is minimized, or while Android has taken the surface away.
fn draw(app: *App) anyerror!void {
    if (app.windowMode() != .minimized and !app.input.surface_lost) try layers.render(app);
    for (app.tool_windows.items) |tool| try tool.render(app);
    app.meshes.tick(app.gpa, &app.device);
    app.renderer3d.tick(app.gpa);
}
