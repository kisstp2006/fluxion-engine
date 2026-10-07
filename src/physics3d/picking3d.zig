// SPDX-License-Identifier: BSD-3-Clause

//! Physics object picking in 3D: what the pointer is over, seen through the
//! current `Camera3D`, and what it did there - as `physics/picking.zig`
//! does it in 2D. Once a frame every pointer event goes to the collision
//! object under it as `input_event`; what the pointer is over now says
//! `mouse_entered` and `mouse_exited`; a mouse button down on one says
//! `pressed`, up again `released`, and up over it still `clicked`. An
//! `Area3D` keeps `hovered` and `held` besides.
//!
//! **The nearest thing along the pointer's ray is what it is over**: an
//! `Area3D` or a `RigidBody3D` with `input_pickable`, through a collider on
//! a layer and visible. A solid thing in front of it - a wall before a
//! lever - hides it; an area in front that is not picked is passed through.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const physics3d = @import("fluxion_physics3d");

const App = @import("../App.zig");
const Bodies3D = @import("bodies3d.zig");
const components = @import("../scene/components.zig");
const input_event = @import("../input/input_event.zig");
const InputEvent = input_event.InputEvent;
const ButtonMask = input_event.ButtonMask;
const MouseButton = @import("fluxion_platform").MouseButton;

const Entity = ecs.Entity;
const Vec2 = math.Vec2;
const Area3D = components.Area3D;
const Collider3D = components.Collider3D;
const RigidBody3D = components.RigidBody3D;
const Camera3D = components.Camera3D;

const Picking3D = @This();

/// What the pointer is over, as of the last pass.
over: Entity = .none,
/// What a pass found.
hit: Entity = .none,
hit_shape: Entity = .none,
/// The objects mouse buttons went down on and are not up yet.
holding: std.AutoArrayHashMapUnmanaged(Entity, ButtonMask) = .empty,

pub fn deinit(self: *Picking3D, gpa: Allocator) void {
    self.holding.deinit(gpa);
    self.* = undefined;
}

pub fn clear(self: *Picking3D, _: *App) void {
    self.over = .none;
    self.hit = .none;
    self.hit_shape = .none;
    self.holding.clearRetainingCapacity();
}

/// The frame's pass, after the 2D one.
pub fn update(self: *Picking3D, app: *App) !void {
    const events = app.input.pointerEvents();
    if (!app.physics_object_picking or !picks(app)) {
        for (events) |event| if (releaseOf(event)) |button| try self.letGo(app, button, false);
        return self.leave(app);
    }
    // The bodies where the transforms say, so a click lands on what is drawn.
    try app.bodies3d.sync(app);
    var pointed = false;
    for (events) |event| {
        if (!event.fromPointer()) continue;
        pointed = true;
        if (app.input.isHandled()) {
            if (releaseOf(event)) |button| try self.letGo(app, button, false);
            continue;
        }
        self.gather(app, event.position().?);
        try self.deliver(app, event);
    }
    if (!pointed) {
        self.gather(app, app.pointerOnScreen());
        try self.deliver(app, null);
    }
}

fn picks(app: *App) bool {
    if (app.input.isHandled()) return false;
    if (app.cursor() == .locked) return false;
    if (!app.input.pointer.inside) return false;
    if (app.hasInterface() and app.ui.wantsPointer()) return false;
    return true;
}

/// The nearest pickable thing under `screen_point`, unless something solid
/// is nearer.
fn gather(self: *Picking3D, app: *App, screen_point: Vec2) void {
    self.hit = .none;
    self.hit_shape = .none;
    const camera = app.currentCamera3D() orelse return;
    const origin = app.projectRayOrigin(camera, screen_point) orelse return;
    const direction = app.projectRayNormal(camera, screen_point) orelse return;
    const reach = if (app.world.get(camera, Camera3D)) |held| held.far else 1000;
    var found: [32]physics3d.RayHit = undefined;
    for (app.physics3d.castRayAll(origin, direction.scale(reach), .{ .sensors = true }, &found)) |hit| {
        const shape = app.bodies3d.entityOf(app, hit.shape) orelse continue;
        const collider = app.world.get(shape, Collider3D) orelse continue;
        const object = Bodies3D.objectOf(&app.world, shape) orelse continue;
        const sensor = collider.sensor or Bodies3D.isArea(&app.world, object);
        const visible = app.resolvedAppearance(object).visible;
        if (collider.collision_layer != 0 and visible and pickable(app, object) and app.isProcessing(object)) {
            self.hit = object;
            self.hit_shape = shape;
            return;
        }
        // Something solid in front hides what is behind it.
        if (!sensor and visible) return;
    }
}

fn pickable(app: *App, object: Entity) bool {
    if (app.world.get(object, Area3D)) |area| {
        if (!app.world.has(object, RigidBody3D)) return area.input_pickable;
    }
    if (app.world.get(object, RigidBody3D)) |body| return body.input_pickable;
    return false;
}

fn deliver(self: *Picking3D, app: *App, event: ?InputEvent) !void {
    if (!self.hit.eql(self.over)) {
        const was = self.over;
        self.over = self.hit;
        if (!was.isNone() and app.world.isAlive(was)) {
            setHovered(app, was, false);
            try say(app, was, .mouse_exited, .{});
        }
        if (!self.hit.isNone()) {
            setHovered(app, self.hit, true);
            try say(app, self.hit, .mouse_entered, .{});
        }
    }
    if (event) |what| {
        if (!self.hit.isNone()) {
            try say(app, self.hit, .input_event, .{ .event = what, .shape = self.hit_shape });
            if (pressOf(what)) |button| {
                try self.hold(app, self.hit, button);
                try say(app, self.hit, .pressed, .{ .button = button });
            }
        }
        if (releaseOf(what)) |button| try self.letGo(app, button, true);
    }
    try app.signals.drain(app);
}

fn hold(self: *Picking3D, app: *App, object: Entity, button: MouseButton) !void {
    const entry = try self.holding.getOrPut(app.gpa, object);
    if (!entry.found_existing) entry.value_ptr.* = .none;
    entry.value_ptr.* = entry.value_ptr.with(button, true);
    setHeld(app, object, true);
}

fn letGo(self: *Picking3D, app: *App, button: MouseButton, over_them: bool) !void {
    var at: usize = 0;
    while (at < self.holding.count()) {
        const object = self.holding.keys()[at];
        const held = &self.holding.values()[at];
        if (!held.has(button)) {
            at += 1;
            continue;
        }
        held.* = held.with(button, false);
        const still = held.any();
        if (!still) self.holding.swapRemoveAt(at) else at += 1;
        if (!app.world.isAlive(object)) continue;
        if (!still) setHeld(app, object, false);
        try say(app, object, .released, .{ .button = button });
        if (over_them and self.hit.eql(object)) try say(app, object, .clicked, .{ .button = button });
    }
}

fn leave(self: *Picking3D, app: *App) !void {
    if (self.over.isNone()) return;
    const was = self.over;
    self.over = .none;
    if (!app.world.isAlive(was)) return;
    setHovered(app, was, false);
    try say(app, was, .mouse_exited, .{});
    try app.signals.drain(app);
}

fn pressOf(event: InputEvent) ?MouseButton {
    return switch (event) {
        .mouse_button => |held| if (held.pressed) held.button else null,
        else => null,
    };
}

fn releaseOf(event: InputEvent) ?MouseButton {
    return switch (event) {
        .mouse_button => |held| if (!held.pressed) held.button else null,
        else => null,
    };
}

fn setHovered(app: *App, object: Entity, on: bool) void {
    if (app.world.get(object, Area3D)) |area| area.hovered = on;
}

fn setHeld(app: *App, object: Entity, on: bool) void {
    if (app.world.get(object, Area3D)) |area| area.held = on;
}

fn say(app: *App, object: Entity, comptime name: @EnumLiteral(), args: anytype) !void {
    if (Bodies3D.isArea(&app.world, object)) {
        try app.signal(object, Area3D, name).emit(args);
    } else {
        try app.signal(object, RigidBody3D, name).emit(args);
    }
}
