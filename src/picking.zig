// SPDX-License-Identifier: BSD-3-Clause

//! Physics object picking: what the pointer is over, and what it
//! did there. Once a frame, after the `.input` stage and before the first
//! fixed step, every pointer event of the frame goes to the collision
//! objects under it as `input_event`, and what the pointer is over now says
//! `mouse_entered` and `mouse_exited`.
//!
//! What can be picked is an `Area2D` or a `RigidBody2D` with
//! `input_pickable`, through a collider that holds the point, is on a layer
//! - a `collision_layer` of nought is never picked - and whose
//! object, if it is drawn at all, is visible.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const physics = @import("fluxion_physics");

const App = @import("App.zig");
const Bodies = @import("bodies.zig");
const components = @import("components.zig");
const pointer = @import("pointer.zig");

const Entity = ecs.Entity;
const Vec2 = math.Vec2;
const Area2D = components.Area2D;
const Collider2D = components.Collider2D;
const RigidBody2D = components.RigidBody2D;
const Sprite = components.Sprite;

const Picking = @This();

/// One pickable collider under the point, with what it is sorted by.
const Hit = struct {
    object: Entity,
    shape: Entity,
    /// The object's own sprite, or nothing drawn: zero.
    layer: i16,
    order: f32,
    /// Later in the world, as a scene reads it, comes first among equals.
    index: u32,
};

/// The objects the pointer is over, as of the last pass.
over: std.AutoArrayHashMapUnmanaged(Entity, void) = .empty,
/// The colliders it is over, each with the object it belongs to.
over_shapes: std.AutoArrayHashMapUnmanaged(Entity, Entity) = .empty,
/// What one pass found, sorted; kept to be used again rather than grown
/// every frame.
hits: std.ArrayList(Hit) = .empty,
/// What that pass is over, filled as the hits are walked.
found: std.AutoArrayHashMapUnmanaged(Entity, void) = .empty,
found_shapes: std.AutoArrayHashMapUnmanaged(Entity, Entity) = .empty,

pub fn deinit(self: *Picking, gpa: Allocator) void {
    self.over.deinit(gpa);
    self.over_shapes.deinit(gpa);
    self.hits.deinit(gpa);
    self.found.deinit(gpa);
    self.found_shapes.deinit(gpa);
    self.* = undefined;
}

/// Over nothing, with nothing said: a world cleared.
pub fn clear(self: *Picking) void {
    self.over.clearRetainingCapacity();
    self.over_shapes.clearRetainingCapacity();
    self.hits.clearRetainingCapacity();
    self.found.clearRetainingCapacity();
    self.found_shapes.clearRetainingCapacity();
}

/// The frame's pass. Called by `App.step` after the `.input` stage.
pub fn update(self: *Picking, app: *App) !void {
    if (!app.physics_object_picking or !picks(app)) return self.leaveAll(app);

    // The bodies where the transforms say, so a click lands on what is
    // drawn rather than on where it was at the last step.
    try app.syncBodies();

    self.found.clearRetainingCapacity();
    self.found_shapes.clearRetainingCapacity();
    const events = app.input.pointerEvents();
    for (events) |event| {
        try self.gather(app, app.screenToWorld(event.position().x, event.position().y));
        try self.deliver(app, event);
        if (app.input.isHandled()) break;
    }
    if (events.len == 0) {
        // No event: what it is over is still worked out, so a thing that
        // moves under a pointer standing still is entered.
        try self.gather(app, app.pointerInWorld());
        try self.deliver(app, null);
    }
    try self.leaveRest(app);
}

/// Whether picking happens at all this frame.
fn picks(app: *App) bool {
    if (app.input.isHandled()) return false;
    // A locked pointer has no place to pick with.
    if (app.cursor() == .locked) return false;
    if (!app.input.pointer.inside) return false;
    // The interface has it: a control under the pointer keeps it from the
    // world.
    if (app.hasInterface() and app.ui.wantsPointer()) return false;
    return true;
}

/// Every pickable collider that holds the point, first one first.
fn gather(self: *Picking, app: *App, point: Vec2) !void {
    self.hits.clearRetainingCapacity();
    const Probe = struct {
        picking: *Picking,
        app: *App,
        point: Vec2,
        failed: ?Allocator.Error = null,

        fn visit(p: *@This(), id: physics.ShapeId) bool {
            p.picking.take(p.app, id, p.point) catch |err| {
                p.failed = err;
                return false;
            };
            return true;
        }
    };
    var probe: Probe = .{ .picking = self, .app = app, .point = point };
    app.physics.overlapAabb(.{ .min = point, .max = point }, &probe, Probe.visit);
    if (probe.failed) |err| return err;

    if (app.physics_object_picking_sort) std.mem.sort(Hit, self.hits.items, {}, above);
}

/// Whether `a` is picked before `b`: what is drawn over the other, and of
/// two drawn alike the later one in the world.
fn above(_: void, a: Hit, b: Hit) bool {
    if (a.layer != b.layer) return a.layer > b.layer;
    if (a.order != b.order) return a.order > b.order;
    return a.index > b.index;
}

/// One shape the point may be in, kept if it is pickable.
fn take(self: *Picking, app: *App, id: physics.ShapeId, point: Vec2) !void {
    const entry = app.physics.shape(id) orelse return;
    if (!holds(app, entry, point)) return;
    const shape = app.bodies.entityOf(app, id) orelse return;
    const collider = app.world.get(shape, Collider2D) orelse return;
    // Only a shape on a layer is picked; there is no picking mask.
    if (collider.collision_layer == 0) return;
    const object = Bodies.objectOf(&app.world, shape) orelse return;
    if (!pickable(app, object)) return;
    // What waits while the game is paused hears nothing of the pointer.
    if (!app.isProcessing(object)) return;

    const drawn = app.world.get(object, Sprite);
    if (drawn) |sprite| {
        if (!sprite.visible) return;
    }
    try self.hits.append(app.gpa, .{
        .object = object,
        .shape = shape,
        .layer = if (drawn) |sprite| sprite.layer else 0,
        .order = if (drawn) |sprite| sprite.order else 0,
        .index = object.index,
    });
}

/// Whether the shape itself holds the point, not only its box.
fn holds(app: *App, entry: *const physics.World.ShapeEntry, point: Vec2) bool {
    const local = app.physics.shapeTransform(entry).unapply(point);
    return entry.def.geometry.containsLocal(local);
}

/// Whether an object takes the pointer at all: its `input_pickable`, true
/// on an area and false on a body. A lone collider, which is its own
/// static body, is never picked.
fn pickable(app: *App, object: Entity) bool {
    if (app.world.get(object, Area2D)) |area| {
        if (!app.world.has(object, RigidBody2D)) return area.input_pickable;
    }
    if (app.world.get(object, RigidBody2D)) |body| return body.input_pickable;
    return false;
}

/// The hits of one pass: what is newly over, then the event itself to each,
/// until a handler takes it.
fn deliver(self: *Picking, app: *App, event: ?pointer.InputEvent) !void {
    var first = true;
    for (self.hits.items) |hit| {
        if (!self.found.contains(hit.object)) {
            try self.found.put(app.gpa, hit.object, {});
            if (!self.over.contains(hit.object)) {
                try self.over.put(app.gpa, hit.object, {});
                try say(app, hit.object, .mouse_entered, .{});
            }
        }
        if (!self.found_shapes.contains(hit.shape)) {
            try self.found_shapes.put(app.gpa, hit.shape, hit.object);
            if (!self.over_shapes.contains(hit.shape)) {
                try self.over_shapes.put(app.gpa, hit.shape, hit.object);
                try say(app, hit.object, .mouse_shape_entered, .{ .shape = hit.shape });
            }
        }
        if (event) |what| {
            if (!first and app.physics_object_picking_first_only) continue;
            try say(app, hit.object, .input_event, .{ .event = what, .shape = hit.shape });
            // Heard at once, so a handler that takes the pointer stops the
            // rest of them hearing it.
            try app.signals.drain(app);
            if (app.input.isHandled()) return;
        }
        first = false;
    }
    try app.signals.drain(app);
}

/// What the pointer has left since the last pass: the objects first, then
/// the shapes.
fn leaveRest(self: *Picking, app: *App) !void {
    var at: usize = 0;
    while (at < self.over.count()) {
        const object = self.over.keys()[at];
        if (self.found.contains(object)) {
            at += 1;
            continue;
        }
        self.over.swapRemoveAt(at);
        // A thing that has died says nothing.
        if (app.world.isAlive(object)) try say(app, object, .mouse_exited, .{});
    }
    at = 0;
    while (at < self.over_shapes.count()) {
        const shape = self.over_shapes.keys()[at];
        const object = self.over_shapes.values()[at];
        if (self.found_shapes.contains(shape)) {
            at += 1;
            continue;
        }
        self.over_shapes.swapRemoveAt(at);
        if (app.world.isAlive(object)) try say(app, object, .mouse_shape_exited, .{ .shape = shape });
    }
    try app.signals.drain(app);
}

/// Everything left, for a frame that picks nothing at all.
fn leaveAll(self: *Picking, app: *App) !void {
    if (self.over.count() == 0 and self.over_shapes.count() == 0) return;
    self.found.clearRetainingCapacity();
    self.found_shapes.clearRetainingCapacity();
    try self.leaveRest(app);
}

/// The signal an object says, whichever kind of object it is.
fn say(app: *App, object: Entity, comptime name: @EnumLiteral(), args: anytype) !void {
    if (Bodies.isArea(&app.world, object)) {
        try app.signal(object, Area2D, name).emit(args);
    } else {
        try app.signal(object, RigidBody2D, name).emit(args);
    }
}
