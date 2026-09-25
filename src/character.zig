// SPDX-License-Identifier: BSD-3-Clause

//! Bodies the game moves: `CharacterBody2D`. A player, a guard walking a
//! corridor, a mouse in a maze - moved where the game says, stopping at
//! what it meets and sliding along it, and never pushed about.
//!
//! ```zig
//! fn walk(app: *fx.App) !void {           // a `.fixed` system
//!     const body = app.world.get(player, fx.CharacterBody2D).?;
//!     body.velocity.x = app.input.actionAxis("move_left", "move_right") * 180;
//!     body.velocity.y += 900 * app.time.delta;
//!     if (body.on_floor and app.input.actionJustPressed("jump")) body.velocity.y = -420;
//!     _ = try app.moveAndSlide(player);
//! }
//! ```
//!
//! **Its shapes are its colliders**, on it and hanging from it, as a rigid
//! body's are; the physics holds it as a kinematic body that goes where its
//! transform goes, so what it walks into it pushes, and nothing pushes it.
//!
//! **`moveAndSlide` moves it by its velocity for the step** - `time.delta`,
//! a fixed step inside `.fixed` - in as many as `max_slides` pieces: each
//! goes until something is `safe_margin` away, and what is left slides
//! along what it met. What went into a wall is taken off the velocity, so a
//! body that walks into one stops walking into it. Seen from the side
//! (`motion_mode = .grounded`), what it met is a floor when it faces
//! `up_direction` within `floor_max_angle`, a ceiling when it faces the
//! other way as nearly, and a wall otherwise; `on_floor`, `on_wall`,
//! `on_ceiling` and their normals say so after. Standing on a slope it
//! stays put (`floor_stop_on_slope`), and walking off the top of one or down
//! a step no higher than `floor_snap_length` it keeps to the floor rather
//! than leaving it. Seen from above (`.floating`), everything is a wall.
//!
//! **`moveAndCollide` moves it once**, by a motion given, and says what
//! stopped it: what it hit, where, the way out of it, how far it went and
//! what was left. What it does with that is the game's.
//!
//! Before it moves, a body that something has pushed into - a door that
//! closed on it, a platform that rose into it - is put back out,
//! `safe_margin` clear. The casts are fluxion-physics' `castShape`: see
//! there for how a shape it starts touching stops it only when it moves
//! into it, and how a one-way platform holds it only from above.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const physics = @import("fluxion_physics");

const App = @import("App.zig");
const components = @import("components.zig");

const Entity = ecs.Entity;
const Vec2 = math.Vec2;
const CharacterBody2D = components.CharacterBody2D;

/// What stopped a move.
pub const Collision = struct {
    /// The collision object it hit: a body, or a collider's own static body.
    /// See `App.collisionObjectOf`.
    collider: Entity = .none,
    /// The collider it hit.
    shape: Entity = .none,
    /// Where the two touch, in the world.
    point: Vec2 = .zero,
    /// Out of what it hit, towards the body.
    normal: Vec2 = .zero,
    /// How far it went before it stopped.
    travel: Vec2 = .zero,
    /// What was left of the motion.
    remainder: Vec2 = .zero,

    pub const reflect_name = "Collision";
};

pub const Error = error{
    /// The entity has no `CharacterBody2D`.
    NotACharacter,
    /// It has no body in the physics: no `Transform2D`, or a chain above it
    /// that cannot be placed.
    NoBody,
} || App.PlaceError || std.mem.Allocator.Error;

/// The most shapes pushed out of at once, and asked about each move.
const max_overlaps = 16;

/// How many times a body is pushed out of what it is in before it moves.
const max_recoveries = 4;

/// Move `e` by `motion`, stopping `safe_margin` short of the first thing
/// in the way. What stopped it, or null for nothing.
pub fn moveAndCollide(app: *App, e: Entity, motion: Vec2) Error!?Collision {
    const body = try bodyOf(app, e);
    const margin = app.world.get(e, CharacterBody2D).?.safe_margin;
    try recover(app, e, body, margin);
    return step(app, e, body, motion, margin);
}

/// Move `e` by its velocity for this step, sliding along what it meets, and
/// say what it stands on. Whether anything stopped it.
pub fn moveAndSlide(app: *App, e: Entity) Error!bool {
    const body = try bodyOf(app, e);
    const state = app.world.get(e, CharacterBody2D).?.*;
    try recover(app, e, body, state.safe_margin);

    var out = state;
    out.on_floor = false;
    out.on_wall = false;
    out.on_ceiling = false;
    out.floor_normal = .zero;
    out.wall_normal = .zero;
    const up = upOf(state);
    var motion = state.velocity.scale(app.time.delta);
    var collided = false;

    var slides: u32 = 0;
    while (slides < @max(state.max_slides, 1)) : (slides += 1) {
        if (motion.lenSq() == 0) break;
        const hit = try step(app, e, body, motion, state.safe_margin) orelse break;
        collided = true;
        var rest = hit.remainder;
        switch (kindOf(state, up, hit.normal)) {
            .floor => {
                out.on_floor = true;
                out.floor_normal = hit.normal;
                // Landing takes what fell; standing still on a slope, what
                // is left of the step is only what goes across it.
                if (out.velocity.dot(up) < 0) out.velocity = out.velocity.sub(up.scale(out.velocity.dot(up)));
                if (state.floor_stop_on_slope) rest = rest.sub(up.scale(rest.dot(up)));
            },
            .ceiling => {
                out.on_ceiling = true;
                if (out.velocity.dot(hit.normal) < 0) out.velocity = out.velocity.sub(hit.normal.scale(out.velocity.dot(hit.normal)));
            },
            .wall => {
                out.on_wall = true;
                out.wall_normal = hit.normal;
                if (out.velocity.dot(hit.normal) < 0) out.velocity = out.velocity.sub(hit.normal.scale(out.velocity.dot(hit.normal)));
            },
        }
        // What is left slides along what it met.
        motion = rest.sub(hit.normal.scale(@min(rest.dot(hit.normal), 0)));
    }

    // Walked off the top of a slope, or down a step: kept to the floor
    // below, when it was on one and is not going up.
    if (state.motion_mode == .grounded and state.on_floor and !out.on_floor and state.floor_snap_length > 0 and out.velocity.dot(up) <= 0) {
        if (try cast(app, body, up.scale(-state.floor_snap_length), state.safe_margin)) |below| {
            if (kindOf(state, up, below.normal) == .floor) {
                try moveBy(app, e, body, up.scale(-state.floor_snap_length * below.fraction));
                out.on_floor = true;
                out.floor_normal = below.normal;
            }
        }
    }
    // Standing on a floor it did not move into this step: resting on it.
    if (state.motion_mode == .grounded and !out.on_floor and out.velocity.dot(up) <= 0) {
        if (try cast(app, body, up.scale(-state.safe_margin), state.safe_margin)) |below| {
            if (below.fraction == 0 and kindOf(state, up, below.normal) == .floor) {
                out.on_floor = true;
                out.floor_normal = below.normal;
            }
        }
    }

    app.world.get(e, CharacterBody2D).?.* = out;
    return collided;
}

const Kind = enum { floor, wall, ceiling };

fn kindOf(state: CharacterBody2D, up: Vec2, normal: Vec2) Kind {
    if (state.motion_mode == .floating) return .wall;
    const steep = @cos(state.floor_max_angle) - 0.01;
    if (normal.dot(up) >= steep) return .floor;
    if (normal.dot(up.neg()) >= steep) return .ceiling;
    return .wall;
}

fn upOf(state: CharacterBody2D) Vec2 {
    const len = state.up_direction.len();
    return if (len > 0) state.up_direction.scale(1 / len) else .init(0, -1);
}

/// The body of a character, made now if the physics has not seen it yet.
fn bodyOf(app: *App, e: Entity) Error!physics.BodyId {
    if (!app.world.has(e, CharacterBody2D)) return error.NotACharacter;
    if (app.bodies.idOf(e)) |held| return held;
    app.syncBodies() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NoBody,
    };
    return app.bodies.idOf(e) orelse error.NoBody;
}

/// One piece of a move: as far as `motion` goes before something is
/// `margin` away, and what that was.
fn step(app: *App, e: Entity, body: physics.BodyId, motion: Vec2, margin: f32) Error!?Collision {
    const hit = try cast(app, body, motion, margin) orelse {
        try moveBy(app, e, body, motion);
        return null;
    };
    const travel = motion.scale(hit.fraction);
    try moveBy(app, e, body, travel);
    const shape = app.bodies.entityOf(app, hit.shape) orelse Entity.none;
    return .{
        .collider = if (shape.isNone()) .none else app.collisionObjectOf(shape) orelse shape,
        .shape = shape,
        .point = hit.point,
        .normal = hit.normal,
        .travel = travel,
        .remainder = motion.sub(travel),
    };
}

/// The nearest thing any of the body's shapes meets along `motion`.
fn cast(app: *App, body: physics.BodyId, motion: Vec2, margin: f32) Error!?physics.ShapeHit {
    const held = app.physics.bodyConst(body) orelse return null;
    const xf = held.transform;
    var best: ?physics.ShapeHit = null;
    var at = held.first_shape;
    while (app.physics.shape(at)) |entry| : (at = entry.next) {
        if (entry.def.sensor) continue;
        const hit = app.physics.castShape(&entry.def.geometry, xf, motion, .{ .filter = entry.def.filter, .ignore = body, .margin = margin }) orelse continue;
        if (best == null or hit.fraction < best.?.fraction) best = hit;
    }
    return best;
}

/// Push the body out of whatever it is further into than `margin`: the
/// deepest first, a few times over.
fn recover(app: *App, e: Entity, body: physics.BodyId, margin: f32) Error!void {
    const tolerance = 0.25 * app.physics.settings.linear_slop * app.physics.settings.units_per_metre;
    for (0..max_recoveries) |_| {
        const held = app.physics.bodyConst(body) orelse return;
        const xf = held.transform;
        var deepest: ?physics.Overlap = null;
        var found: [max_overlaps]physics.Overlap = undefined;
        var at = held.first_shape;
        while (app.physics.shape(at)) |entry| : (at = entry.next) {
            if (entry.def.sensor) continue;
            for (app.physics.overlapShape(&entry.def.geometry, xf, .{ .filter = entry.def.filter, .ignore = body, .margin = margin }, &found)) |overlap| {
                if (deepest == null or overlap.depth > deepest.?.depth) deepest = overlap;
            }
        }
        const out = deepest orelse return;
        if (out.depth <= tolerance) return;
        try moveBy(app, e, body, out.normal.scale(out.depth));
    }
}

/// Move the body and its entity by `delta`, in the world, at once: the
/// next cast of this step starts from where it is now.
fn moveBy(app: *App, e: Entity, body: physics.BodyId, delta: Vec2) Error!void {
    if (delta.x == 0 and delta.y == 0) return;
    const held = app.physics.body(body) orelse return;
    const now = held.position().add(delta);
    held.setTransform(now, held.angle);
    try app.setGlobalPosition(e, now);
    app.bodies.movedTo(app, e, now, held.angle);
}
