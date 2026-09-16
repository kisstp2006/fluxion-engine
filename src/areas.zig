// SPDX-License-Identifier: BSD-3-Clause

//! What is inside each `Area2D`: the shape pairs the physics found, the
//! signals that say one began or ended, and the questions a game asks
//! instead of listening. Godot's Area2D monitoring, with its shape indices
//! replaced by the colliders' entities.
//!
//! Every sensor pair an area is in is kept here, beside the world as the
//! bodies' handles are, whether it is reported or not: what an area says is
//! worked out again after each step, so a mask changed, an area that stops
//! and starts monitoring, or one that becomes monitorable says what it
//! should from then on.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");

const App = @import("App.zig");
const Bodies = @import("bodies.zig");
const components = @import("components.zig");

const Entity = ecs.Entity;
const Area2D = components.Area2D;
const Collider2D = components.Collider2D;

const Areas = @This();
const log = std.log.scoped(.fluxion_engine);

/// One area's collider, and the collider of what is in it.
const ShapePair = struct { local: Entity, other: Entity };

/// What a shape pair is between, kept so that an end can be told even when
/// the other side has died since, and told as the same kind it began as.
const Between = struct {
    area: Entity,
    object: Entity,
    /// Whether the object is an area of its own: which pair of signals it is.
    is_area: bool,
    /// Whether the area has been told of it: it is monitoring, either mask
    /// takes the other's layer, and an area in it is monitorable.
    reported: bool = false,
    /// How many of the physics' shape pairs between the two colliders
    /// overlap: one, except for the step in which a collider is made anew,
    /// whose new shape begins as its old one ends.
    touching: u32 = 0,
};

/// One area and one thing in it, however many of their shapes touch.
const ObjectPair = struct { area: Entity, object: Entity };

const Count = struct { shapes: u32, is_area: bool };

/// Every sensor shape pair an area is in, reported or not.
pairs: std.AutoArrayHashMapUnmanaged(ShapePair, Between) = .empty,
/// How many reported shape pairs each object pair has: entered at the first,
/// exited after the last. The questions are answered from this.
objects: std.AutoArrayHashMapUnmanaged(ObjectPair, Count) = .empty,
/// Areas already told that a question with `monitoring` off is empty.
warned: std.AutoHashMapUnmanaged(Entity, void) = .empty,

pub fn deinit(self: *Areas, gpa: Allocator) void {
    self.pairs.deinit(gpa);
    self.objects.deinit(gpa);
    self.warned.deinit(gpa);
    self.* = undefined;
}

/// Everything forgotten, with nothing said: a world cleared.
pub fn clear(self: *Areas) void {
    self.pairs.clearRetainingCapacity();
    self.objects.clearRetainingCapacity();
    self.warned.clearRetainingCapacity();
}

// -------------------------------------------------------------------------
// Keeping step
// -------------------------------------------------------------------------

/// What the last step's sensor pairs mean for each area, said in signals.
/// Called after the step, so the systems after it hear them.
pub fn update(self: *Areas, app: *App) !void {
    for (app.bodies.began(true)) |touch| {
        if (!touch.sensor) continue;
        try self.found(app, touch.a, touch.b);
        try self.found(app, touch.b, touch.a);
    }
    // What began is told before what ended is let go, so a body crossing
    // from one shape of an area to another in one step never leaves it.
    try self.tell(app);
    for (app.bodies.ended(true)) |touch| {
        if (!touch.sensor) continue;
        try self.lost(app, touch.a, touch.b);
        try self.lost(app, touch.b, touch.a);
    }
}

/// A pair the physics has made, kept whether it is reported or not.
fn found(self: *Areas, app: *App, local: Entity, other: Entity) !void {
    const area = Bodies.objectOf(&app.world, local) orelse return;
    if (!Bodies.isArea(&app.world, area)) return;
    const object = Bodies.objectOf(&app.world, other) orelse return;
    // Another of its own shapes, paired through a parent.
    if (object.eql(area)) return;

    const pair = try self.pairs.getOrPut(app.gpa, .{ .local = local, .other = other });
    if (!pair.found_existing) pair.value_ptr.* = .{ .area = area, .object = object, .is_area = Bodies.isArea(&app.world, object) };
    pair.value_ptr.touching += 1;
}

/// A pair the physics has let go of - they parted, or a shape went with its
/// entity - with the exits it was owed. A collider made anew let go of its
/// old shape as its new one began, and the pair stays.
fn lost(self: *Areas, app: *App, local: Entity, other: Entity) !void {
    const key: ShapePair = .{ .local = local, .other = other };
    const pair = self.pairs.getPtr(key) orelse return;
    pair.touching -|= 1;
    if (pair.touching > 0) return;
    const gone = self.pairs.fetchSwapRemove(key).?;
    if (gone.value.reported) try self.parted(app, gone.value, local, other);
}

/// Whether the shape `mine` is told about the shape `theirs`: Godot 3's
/// rule, the one its physics touches by, where either side's mask having
/// the other's layer is enough.
fn told(mine: Collider2D, theirs: Collider2D) bool {
    return (mine.collision_mask & theirs.collision_layer) != 0 or (theirs.collision_mask & mine.collision_layer) != 0;
}

/// Whether an area is to be told of one pair as things stand now.
fn reportable(app: *App, pair: ShapePair, between: *Between) bool {
    const looking = app.world.get(between.area, Area2D) orelse return false;
    if (!looking.monitoring) return false;
    if (app.world.isAlive(between.object)) between.is_area = Bodies.isArea(&app.world, between.object);
    if (between.is_area) {
        const seen = app.world.get(between.object, Area2D) orelse return false;
        if (!seen.monitorable) return false;
    }
    const mine = app.world.get(pair.local, Collider2D) orelse return false;
    const theirs = app.world.get(pair.other, Collider2D) orelse return false;
    return told(mine.*, theirs.*);
}

/// Every pair looked at again, and the signals of the ones that changed.
fn tell(self: *Areas, app: *App) !void {
    var at: usize = 0;
    while (at < self.pairs.count()) : (at += 1) {
        const pair = self.pairs.keys()[at];
        const between = &self.pairs.values()[at];
        const should = reportable(app, pair, between);
        if (should == between.reported) continue;
        between.reported = should;
        // A copy: the signals may despawn, and the values may move.
        const held = between.*;
        if (should) try self.joined(app, held, pair.local, pair.other) else try self.parted(app, held, pair.local, pair.other);
    }
}

/// What one shape pair's beginning says, and the object pair's when it was
/// the first of them.
fn joined(self: *Areas, app: *App, between: Between, local: Entity, other: Entity) !void {
    const held = try self.objects.getOrPut(app.gpa, .{ .area = between.area, .object = between.object });
    if (!held.found_existing) held.value_ptr.* = .{ .shapes = 0, .is_area = between.is_area };
    held.value_ptr.shapes += 1;
    const first = held.value_ptr.shapes == 1;

    // The object first and then the shape, as Godot says them.
    if (between.is_area) {
        if (first) try app.emit(between.area, Area2D, .area_entered, .{ .area = between.object });
        try app.emit(between.area, Area2D, .area_shape_entered, .{ .area = between.object, .area_shape = other, .local_shape = local });
    } else {
        if (first) try app.emit(between.area, Area2D, .body_entered, .{ .body = between.object });
        try app.emit(between.area, Area2D, .body_shape_entered, .{ .body = between.object, .body_shape = other, .local_shape = local });
    }
}

/// What one shape pair's end says, and the object pair's when it was the
/// last of them.
fn parted(self: *Areas, app: *App, between: Between, local: Entity, other: Entity) !void {
    const key: ObjectPair = .{ .area = between.area, .object = between.object };
    var last = true;
    if (self.objects.getPtr(key)) |held| {
        held.shapes -= 1;
        last = held.shapes == 0;
    }
    if (last) _ = self.objects.swapRemove(key);

    // The shape first and then the object, as Godot says them.
    if (between.is_area) {
        try app.emit(between.area, Area2D, .area_shape_exited, .{ .area = between.object, .area_shape = other, .local_shape = local });
        if (last) try app.emit(between.area, Area2D, .area_exited, .{ .area = between.object });
    } else {
        try app.emit(between.area, Area2D, .body_shape_exited, .{ .body = between.object, .body_shape = other, .local_shape = local });
        if (last) try app.emit(between.area, Area2D, .body_exited, .{ .body = between.object });
    }
}

// -------------------------------------------------------------------------
// Asking
// -------------------------------------------------------------------------

/// What is in `area` now: the bodies with `areas` false, the other areas
/// with it true, as many as `found` holds.
pub fn overlapping(self: *Areas, app: *App, area: Entity, areas: bool, into: []Entity) []Entity {
    if (!self.watching(app, area)) return into[0..0];
    var count: usize = 0;
    for (self.objects.keys(), self.objects.values()) |key, held| {
        if (count == into.len) break;
        if (!key.area.eql(area) or held.is_area != areas) continue;
        into[count] = key.object;
        count += 1;
    }
    return into[0..count];
}

pub fn any(self: *Areas, app: *App, area: Entity, areas: bool) bool {
    var one: [1]Entity = undefined;
    return self.overlapping(app, area, areas, &one).len != 0;
}

pub fn overlaps(self: *Areas, app: *App, area: Entity, object: Entity) bool {
    if (!self.watching(app, area)) return false;
    return self.objects.contains(.{ .area = area, .object = object });
}

/// Whether an area answers questions at all, with a word about one that does
/// not - once for each, where Godot says it every time.
fn watching(self: *Areas, app: *App, area: Entity) bool {
    const held = app.world.get(area, Area2D) orelse return false;
    if (held.monitoring) return true;
    const known = self.warned.fetchPut(app.gpa, area, {}) catch null;
    if (known == null) {
        log.warn("{f} is asked what is in it while its Area2D is not monitoring: nothing is", .{area});
    }
    return false;
}
