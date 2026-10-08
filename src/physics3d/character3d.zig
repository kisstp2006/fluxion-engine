// SPDX-License-Identifier: BSD-3-Clause

//! Bodies the game moves in 3D: `CharacterBody3D`. A player walking a
//! level, a guard on a round - moved where the game says, stopping at what
//! it meets and sliding along it, and never pushed about.
//!
//! ```zig
//! fn walk(app: *fx.App) !void {           // a `.fixed` system
//!     const body = app.world.get(player, fx.CharacterBody3D).?;
//!     const wish = app.input.actionVector("left", "right", "forward", "back");
//!     body.velocity.x = wish.x * 4;
//!     body.velocity.z = wish.y * 4;
//!     body.velocity.y -= 9.8 * app.time.delta;
//!     if (body.on_floor and app.input.actionJustPressed("jump")) body.velocity.y = 5;
//!     _ = try app.moveAndSlide(player);
//! }
//! ```
//!
//! What `character.zig` says of a 2D character holds here, a dimension up:
//! its shapes are its `Collider3D`s - a capsule, most often - held as a
//! kinematic body that goes where its transform goes; `moveAndSlide` moves
//! it by its velocity for the step in as many as `max_slides` pieces, each
//! stopping `safe_margin` short of what it meets and sliding along it; what
//! it met is a floor, a wall or a ceiling by how it faces `up_direction`;
//! it stays put standing on a slope and keeps to the floor walking off the
//! top of one or down a step. Before it moves, a body something has pushed
//! into is put back out.

const std = @import("std");

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const physics3d = @import("fluxion_physics3d");

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const hierarchy = @import("../scene/hierarchy.zig");

const Entity = ecs.Entity;
const Vec3 = math.Vec3;
const CharacterBody3D = components.CharacterBody3D;

/// What stopped a move.
pub const Collision = struct {
    /// The collision object it hit: a body, or a collider's own static body.
    collider: Entity = .none,
    /// The collider it hit.
    shape: Entity = .none,
    /// Where the two touch, in the world.
    point: Vec3 = .zero,
    /// Out of what it hit, towards the body.
    normal: Vec3 = .zero,
    /// How far it went before it stopped, in metres along the motion it was
    /// given: `motion.normalized() * travel` is the move it made.
    travel: f32 = 0,
    /// How far it had still to go, in metres along the motion.
    remainder: f32 = 0,

    pub const reflect_name = "Collision3D";
};

/// One piece of a move as the slide works it: what it met, and the motion
/// gone and left.
const Hit = struct {
    collision: Collision,
    travel: Vec3,
    remainder: Vec3,
};

/// What each character's last `moveAndSlide` met, in order.
pub const Slides = struct {
    by_entity: std.AutoArrayHashMapUnmanaged(Entity, std.ArrayList(Collision)) = .empty,

    pub fn deinit(self: *Slides, gpa: std.mem.Allocator) void {
        for (self.by_entity.values()) |*met| met.deinit(gpa);
        self.by_entity.deinit(gpa);
    }

    fn restart(self: *Slides, gpa: std.mem.Allocator, e: Entity) !*std.ArrayList(Collision) {
        const met = try self.by_entity.getOrPut(gpa, e);
        if (!met.found_existing) met.value_ptr.* = .empty;
        met.value_ptr.clearRetainingCapacity();
        return met.value_ptr;
    }

    pub fn of(self: *const Slides, e: Entity) []const Collision {
        const met = self.by_entity.getPtr(e) orelse return &.{};
        return met.items;
    }

    pub fn clear(self: *Slides, app: *App) void {
        for (self.by_entity.values()) |*met| met.deinit(app.gpa);
        self.by_entity.clearRetainingCapacity();
    }

    pub fn forgetDead(self: *Slides, app: *App) void {
        var at = self.by_entity.count();
        while (at > 0) {
            at -= 1;
            if (app.world.isAlive(self.by_entity.keys()[at])) continue;
            self.by_entity.values()[at].deinit(app.gpa);
            self.by_entity.swapRemoveAt(at);
        }
    }
};

pub const Error = error{
    /// The entity has no `CharacterBody3D`.
    NotACharacter,
    /// It has no body in the physics: no `Transform3D`, or a chain above it
    /// that cannot be placed.
    NoBody,
} || App.PlaceError || std.mem.Allocator.Error;

const max_overlaps = 16;
const max_recoveries = 4;

/// Move `e` by `motion`, stopping `safe_margin` short of the first thing in
/// the way. What stopped it, or null for nothing.
pub fn moveAndCollide(app: *App, e: Entity, motion: Vec3) Error!?Collision {
    const body = try bodyOf(app, e);
    const margin = app.world.get(e, CharacterBody3D).?.safe_margin;
    try recover(app, e, body, margin);
    const hit = try step(app, e, body, motion, margin) orelse return null;
    return hit.collision;
}

/// Move `e` by its velocity for this step, sliding along what it meets, and
/// say what it stands on. Whether anything stopped it.
pub fn moveAndSlide(app: *App, e: Entity) Error!bool {
    const body = try bodyOf(app, e);
    const state = app.world.get(e, CharacterBody3D).?.*;
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
    const met = try app.slide_collisions3d.restart(app.gpa, e);

    var slides: u32 = 0;
    while (slides < @max(state.max_slides, 1)) : (slides += 1) {
        if (motion.lenSq() < 1e-14) break;
        const hit = try step(app, e, body, motion, state.safe_margin) orelse break;
        collided = true;
        try met.append(app.gpa, hit.collision);
        var rest = hit.remainder;
        const normal = hit.collision.normal;
        switch (kindOf(state, up, normal)) {
            .floor => {
                out.on_floor = true;
                out.floor_normal = normal;
                if (out.velocity.dot(up) < 0) out.velocity = out.velocity.sub(up.scale(out.velocity.dot(up)));
                if (state.floor_stop_on_slope) rest = rest.sub(up.scale(rest.dot(up)));
            },
            .ceiling => {
                out.on_ceiling = true;
                if (out.velocity.dot(normal) < 0) out.velocity = out.velocity.sub(normal.scale(out.velocity.dot(normal)));
            },
            .wall => {
                // A kerb, a stair: walked up onto from the floor.
                if (state.motion_mode == .grounded and state.on_floor and state.max_step_height > 0) {
                    if (try stepUp(app, e, body, rest, up, state)) |left| {
                        out.on_floor = true;
                        motion = left;
                        continue;
                    }
                }
                out.on_wall = true;
                out.wall_normal = normal;
                // A wall stops what goes into it - but not the fall along it.
                const flat = flatten(normal, up, state.motion_mode);
                if (out.velocity.dot(flat) < 0) out.velocity = out.velocity.sub(flat.scale(out.velocity.dot(flat)));
            },
        }
        // What is left slides along what it met.
        motion = rest.sub(normal.scale(@min(rest.dot(normal), 0)));
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
        if (try cast(app, body, up.scale(-2 * state.safe_margin), state.safe_margin)) |below| {
            if (kindOf(state, up, below.normal) == .floor) {
                out.on_floor = true;
                out.floor_normal = below.normal;
            }
        }
    }

    app.world.get(e, CharacterBody3D).?.* = out;
    return collided;
}

/// Up by the step height, on by `motion` along the ground, and down onto a
/// floor: what is left of `motion` when that worked. Undone when there is
/// no room above, the edge is higher than the step, or there is no floor
/// past it.
fn stepUp(app: *App, e: Entity, body: physics3d.BodyId, motion: Vec3, up: Vec3, state: CharacterBody3D) Error!?Vec3 {
    const forward = motion.sub(up.scale(motion.dot(up)));
    if (forward.lenSq() < 1e-10) return null;
    const margin = state.safe_margin;
    const lift = up.scale(state.max_step_height);
    const raised = if (try cast(app, body, lift, margin)) |hit| lift.scale(hit.fraction) else lift;
    if (raised.len() < state.max_step_height * 0.25) return null;
    try moveBy(app, e, body, raised);
    const ahead = try cast(app, body, forward, margin);
    const went = if (ahead) |hit| forward.scale(hit.fraction) else forward;
    if (went.len() < 1e-4) {
        try moveBy(app, e, body, raised.neg());
        return null;
    }
    try moveBy(app, e, body, went);
    const drop = raised.neg().sub(up.scale(margin * 2));
    const below = try cast(app, body, drop, margin);
    if (below == null or kindOf(state, up, below.?.normal) != .floor) {
        try moveBy(app, e, body, went.add(raised).neg());
        return null;
    }
    try moveBy(app, e, body, drop.scale(below.?.fraction));
    return forward.sub(went);
}

/// A wall's normal with its up part taken out, so stopping at a wall that
/// leans does not stop a fall.
fn flatten(normal: Vec3, up: Vec3, mode: CharacterBody3D.MotionMode) Vec3 {
    if (mode == .floating) return normal;
    const flat = normal.sub(up.scale(normal.dot(up)));
    return flat.tryNorm() orelse normal;
}

const Kind = enum { floor, wall, ceiling };

fn kindOf(state: CharacterBody3D, up: Vec3, normal: Vec3) Kind {
    if (state.motion_mode == .floating) return .wall;
    const steep = @cos(state.floor_max_angle) - 0.01;
    if (normal.dot(up) >= steep) return .floor;
    if (normal.dot(up.neg()) >= steep) return .ceiling;
    return .wall;
}

fn upOf(state: CharacterBody3D) Vec3 {
    return state.up_direction.tryNorm() orelse Vec3.init(0, 1, 0);
}

fn bodyOf(app: *App, e: Entity) Error!physics3d.BodyId {
    if (!app.world.has(e, CharacterBody3D)) return error.NotACharacter;
    if (app.bodies3d.idOf(e)) |held| return held;
    app.bodies3d.sync(app) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NoBody,
    };
    return app.bodies3d.idOf(e) orelse error.NoBody;
}

fn step(app: *App, e: Entity, body: physics3d.BodyId, motion: Vec3, margin: f32) Error!?Hit {
    const hit = try cast(app, body, motion, margin) orelse {
        try moveBy(app, e, body, motion);
        return null;
    };
    const travel = motion.scale(hit.fraction);
    try moveBy(app, e, body, travel);
    const shape = app.bodies3d.entityOf(app, hit.shape) orelse Entity.none;
    const remainder = motion.sub(travel);
    return .{
        .collision = .{
            .collider = if (shape.isNone()) .none else app.collisionObjectOf(shape) orelse shape,
            .shape = shape,
            .point = hit.point,
            .normal = hit.normal,
            .travel = travel.len(),
            .remainder = remainder.len(),
        },
        .travel = travel,
        .remainder = remainder,
    };
}

/// The nearest thing any of the body's shapes meets along `motion`.
fn cast(app: *App, body: physics3d.BodyId, motion: Vec3, margin: f32) Error!?physics3d.ShapeHit {
    const held = app.physics3d.bodyConst(body) orelse return null;
    const xf = held.transform;
    var best: ?physics3d.ShapeHit = null;
    var at = held.first_shape;
    while (app.physics3d.shape(at)) |entry| : (at = entry.next) {
        if (entry.def.sensor) continue;
        const hit = app.physics3d.castShape(entry.def.geometry, xf.mul(entry.def.offset), motion, .{ .mask = entry.def.filter.mask, .ignore = body, .margin = margin }) orelse continue;
        // One it started against stops it only when it moves into it.
        if (hit.initially_overlapping) continue;
        if (best == null or hit.fraction < best.?.fraction) best = hit;
    }
    return best;
}

/// Push the body out of whatever it is nearer than `margin`: the deepest
/// first, a few times over.
fn recover(app: *App, e: Entity, body: physics3d.BodyId, margin: f32) Error!void {
    const tolerance = 0.25 * app.physics3d.settings.linear_slop;
    for (0..max_recoveries) |_| {
        const held = app.physics3d.bodyConst(body) orelse return;
        const xf = held.transform;
        var deepest: ?physics3d.Penetration = null;
        var found: [max_overlaps]physics3d.Penetration = undefined;
        var at = held.first_shape;
        while (app.physics3d.shape(at)) |entry| : (at = entry.next) {
            if (entry.def.sensor) continue;
            for (app.physics3d.penetrations(entry.def.geometry, xf.mul(entry.def.offset), .{ .mask = entry.def.filter.mask, .ignore = body, .margin = margin }, &found)) |p| {
                if (deepest == null or p.depth > deepest.?.depth) deepest = p;
            }
        }
        const out = deepest orelse return;
        if (out.depth <= tolerance + margin * 0.5) return;
        try moveBy(app, e, body, out.normal.scale(out.depth - margin * 0.5));
    }
}

/// Move the body and its entity by `delta`, in the world, at once.
fn moveBy(app: *App, e: Entity, body: physics3d.BodyId, delta: Vec3) Error!void {
    if (delta.lenSq() == 0) return;
    const held = app.physics3d.body(body) orelse return;
    const now = held.position().add(delta);
    const turn = held.rotation();
    app.physics3d.setTransform(body, now, turn);
    try hierarchy.setGlobalPosition3D(&app.world, e, now);
    app.bodies3d.movedTo(app, e, now, turn);
}
