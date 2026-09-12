// SPDX-License-Identifier: BSD-3-Clause

//! The physics world kept in step with the entities. Each `RigidBody2D` is a
//! body and each `Collider2D` a shape, made, changed and taken away as the
//! components are, and after every step the bodies' places and speeds go
//! back into the components. The handles live here, beside the world, as the
//! names do: no component holds one.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const physics = @import("fluxion_physics");

const App = @import("App.zig");
const components = @import("components.zig");
const hierarchy = @import("hierarchy.zig");
const sprite = @import("render/sprite.zig");

const Entity = ecs.Entity;
const Vec2 = math.Vec2;
const Transform2D = components.Transform2D;
const RigidBody2D = components.RigidBody2D;
const Collider2D = components.Collider2D;
const Sprite = components.Sprite;
const BodyId = physics.BodyId;
const ShapeId = physics.ShapeId;

const Bodies = @This();
const log = std.log.scoped(.fluxion_engine);

/// Two colliders that began or stopped touching.
pub const Contact = struct {
    a: Entity,
    b: Entity,
    /// One of them is a sensor: seen, not pushed.
    sensor: bool,

    /// The one that is not `entity`, when `entity` is either.
    pub fn other(self: Contact, entity: Entity) ?Entity {
        if (self.a.eql(entity)) return self.b;
        if (self.b.eql(entity)) return self.a;
        return null;
    }
};

/// What a ray hit first.
pub const RayHit = struct {
    /// `.none` for a shape the engine did not make.
    entity: Entity,
    point: Vec2,
    /// Out of the surface it hit.
    normal: Vec2,
    /// How far along, from zero at the start to one at the end.
    fraction: f32,
};

/// By entity index.
bodies: std.ArrayList(BodyLink) = .empty,
/// By entity index.
shapes: std.ArrayList(ShapeLink) = .empty,
/// By entity index, the sync that last saw each link: zero for no link.
/// Apart from the links, so the sweep reads four bytes an entity.
body_seen: std.ArrayList(u32) = .empty,
shape_seen: std.ArrayList(u32) = .empty,
/// The entities whose bodies move, as of the last sync: what a step writes
/// back.
moving: std.ArrayList(u32) = .empty,
/// Shapes taken away since the last step, whose contacts that step ends.
departed: std.ArrayList(Departed) = .empty,
began_step: std.ArrayList(Contact) = .empty,
ended_step: std.ArrayList(Contact) = .empty,
began_frame: std.ArrayList(Contact) = .empty,
ended_frame: std.ArrayList(Contact) = .empty,
/// Counts syncs, skipping zero.
mark: u32 = 0,

const BodyLink = struct {
    entity: Entity = .none,
    body: BodyId = .none,
    /// As last synced either way. Null for a collider's own static body.
    rigid: ?RigidBody2D = null,
    /// As last synced either way.
    transform: Transform2D = .{},
    /// Where the body was last put, in the world.
    placed: Pose = .{},
};

const ShapeLink = struct {
    entity: Entity = .none,
    /// None when the collider has no size to make a shape of.
    shape: ShapeId = .none,
    body: BodyId = .none,
    made_from: Inputs = undefined,
};

/// Everything a shape is made from: when any of it changes, the shape is
/// made again.
const Inputs = struct {
    collider: Collider2D,
    /// The collider's entity in its body's frame.
    place: Pose,
    /// The sprite's size and middle, for a collider that takes its size from
    /// it; zeroes otherwise.
    sprite: [4]f32,
};

const Pose = struct {
    x: f32 = 0,
    y: f32 = 0,
    rotation: f32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,

    fn of(t: Transform2D) Pose {
        return .{ .x = t.x, .y = t.y, .rotation = t.rotation, .scale_x = t.scale_x, .scale_y = t.scale_y };
    }
};

const Departed = struct { shape: ShapeId, entity: Entity };

/// Resolving against no snapshots is resolving where things are, not where
/// they are drawn.
const still: hierarchy.Snapshots = .empty;

/// Smaller than this, a shape has no area the solver can divide by.
const least_size = 1e-3;

pub fn deinit(self: *Bodies, gpa: Allocator) void {
    self.bodies.deinit(gpa);
    self.shapes.deinit(gpa);
    self.body_seen.deinit(gpa);
    self.shape_seen.deinit(gpa);
    self.moving.deinit(gpa);
    self.departed.deinit(gpa);
    self.began_step.deinit(gpa);
    self.ended_step.deinit(gpa);
    self.began_frame.deinit(gpa);
    self.ended_frame.deinit(gpa);
    self.* = undefined;
}

// -------------------------------------------------------------------------
// Keeping step
// -------------------------------------------------------------------------

/// Make, change and take away bodies and shapes to match the components.
pub fn sync(self: *Bodies, app: *App) !void {
    const gpa = app.gpa;
    const span = app.world.entities.slots.items.len;
    try grow(BodyLink, gpa, &self.bodies, span, .{});
    try grow(ShapeLink, gpa, &self.shapes, span, .{});
    try grow(u32, gpa, &self.body_seen, span, 0);
    try grow(u32, gpa, &self.shape_seen, span, 0);
    self.mark +%= 1;
    if (self.mark == 0) self.mark = 1;
    self.moving.clearRetainingCapacity();
    try self.syncRigid(app);
    try self.syncColliders(app);
    try self.sweep(app);
}

fn grow(comptime T: type, gpa: Allocator, list: *std.ArrayList(T), len: usize, empty: T) Allocator.Error!void {
    if (list.items.len < len) try list.appendNTimes(gpa, empty, len - list.items.len);
}

fn syncRigid(self: *Bodies, app: *App) !void {
    var it = try ecs.Query(.{ Transform2D, RigidBody2D }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(Transform2D), chunk.slice(RigidBody2D)) |e, place, rigid| {
            const link = &self.bodies.items[e.index];
            if (link.entity.eql(e) and link.rigid != null and link.rigid.?.type == rigid.type) {
                update(app, link, place, rigid);
            } else {
                const at = placed(app, e, place) orelse continue;
                try self.make(app, link, e, place, at, rigid);
            }
            self.body_seen.items[e.index] = self.mark;
            if (rigid.type != .static) try self.moving.append(app.gpa, e.index);
        }
    }
}

fn update(app: *App, link: *BodyLink, place: Transform2D, rigid: RigidBody2D) void {
    const body = app.physics.body(link.body) orelse return;
    const was = link.rigid.?;
    if (moved(link.transform, place) or (rigid.type == .static and !place.parent.isNone())) {
        if (placed(app, link.entity, place)) |at| {
            if (!std.meta.eql(at, link.placed)) body.setTransform(.init(at.x, at.y), at.rotation);
            link.placed = at;
        }
        link.transform = place;
    }
    if (!std.meta.eql(rigid.velocity, was.velocity) or rigid.angular_velocity != was.angular_velocity) {
        body.linear_velocity = rigid.velocity;
        body.angular_velocity = rigid.angular_velocity;
        body.wake();
    }
    body.linear_damping = rigid.linear_damping;
    body.angular_damping = rigid.angular_damping;
    body.bullet = rigid.bullet;
    if (rigid.gravity_scale != was.gravity_scale) {
        body.gravity_scale = rigid.gravity_scale;
        body.wake();
    }
    if (rigid.can_sleep != was.can_sleep) {
        body.allow_sleep = rigid.can_sleep;
        body.wake();
    }
    if (rigid.fixed_rotation != was.fixed_rotation) {
        body.fixed_rotation = rigid.fixed_rotation;
        app.physics.updateMass(link.body);
    }
    link.rigid = rigid;
}

fn make(self: *Bodies, app: *App, link: *BodyLink, e: Entity, place: Transform2D, at: Pose, rigid: ?RigidBody2D) !void {
    if (!link.entity.isNone()) try self.destroy(app, link.body);
    const r = rigid orelse RigidBody2D{ .type = .static };
    const body = try app.physics.createBody(.{
        .type = r.type,
        .position = .init(at.x, at.y),
        .angle = at.rotation,
        .linear_velocity = r.velocity,
        .angular_velocity = r.angular_velocity,
        .linear_damping = r.linear_damping,
        .angular_damping = r.angular_damping,
        .gravity_scale = r.gravity_scale,
        .fixed_rotation = r.fixed_rotation,
        .allow_sleep = r.can_sleep,
        .bullet = r.bullet,
        .user_data = e.toInt(),
    });
    link.* = .{ .entity = e, .body = body, .rigid = rigid, .transform = place, .placed = at };
}

fn destroy(self: *Bodies, app: *App, id: BodyId) !void {
    const body = app.physics.body(id) orelse return;
    var at = body.first_shape;
    while (app.physics.shape(at)) |entry| : (at = entry.next) {
        try self.departed.append(app.gpa, .{ .shape = at, .entity = .fromInt(entry.def.user_data) });
    }
    app.physics.destroyBody(id);
}

fn syncColliders(self: *Bodies, app: *App) !void {
    var it = try ecs.Query(.{ Transform2D, Collider2D }).over(&app.world);
    while (it.next()) |chunk| {
        // One archetype: every row has a body of its own, or none does.
        const rigid = app.world.has(chunk.entities[0], RigidBody2D);
        for (chunk.entities, chunk.slice(Transform2D), chunk.slice(Collider2D)) |e, place, collider| {
            const owner = if (rigid or place.parent.isNone()) e else ownerOf(&app.world, e, place) orelse continue;
            if (!rigid and owner.eql(e)) try self.syncStatic(app, e, place);

            const body_link = &self.bodies.items[owner.index];
            if (!body_link.entity.eql(owner) or self.body_seen.items[owner.index] != self.mark) continue;
            const inputs = inputsOf(app, e, place, collider, owner) orelse continue;

            const link = &self.shapes.items[e.index];
            if (!link.entity.eql(e) or !link.body.eql(body_link.body) or !std.meta.eql(link.made_from, inputs)) {
                try self.reshape(app, link, e, body_link.body, inputs);
            }
            self.shape_seen.items[e.index] = self.mark;
        }
    }
}

/// A collider with no body to be part of is a static body of its own, which
/// goes wherever its transform does.
fn syncStatic(self: *Bodies, app: *App, e: Entity, place: Transform2D) !void {
    const link = &self.bodies.items[e.index];
    if (link.entity.eql(e) and link.rigid == null) {
        if (moved(link.transform, place) or !place.parent.isNone()) {
            const at = placed(app, e, place) orelse return;
            if (!std.meta.eql(at, link.placed)) {
                if (app.physics.body(link.body)) |body| body.setTransform(.init(at.x, at.y), at.rotation);
                link.placed = at;
            }
            link.transform = place;
        }
    } else {
        const at = placed(app, e, place) orelse return;
        try self.make(app, link, e, place, at, null);
    }
    self.body_seen.items[e.index] = self.mark;
}

/// Whose body a collider is part of: its own entity's when that has a
/// `RigidBody2D`, else the nearest one above it that has, else its own. Null
/// when the chain above it is broken.
fn ownerOf(world: *ecs.World, e: Entity, place: Transform2D) ?Entity {
    if (world.has(e, RigidBody2D)) return e;
    var above = place.parent;
    var depth: usize = 0;
    while (!above.isNone()) : (depth += 1) {
        if (depth == Transform2D.max_depth) return null;
        const up = world.get(above, Transform2D) orelse return if (world.isAlive(above)) e else null;
        if (world.has(above, RigidBody2D)) return above;
        above = up.parent;
    }
    return e;
}

fn inputsOf(app: *App, e: Entity, place: Transform2D, collider: Collider2D, owner: Entity) ?Inputs {
    const scale = if (owner.eql(e) and place.parent.isNone())
        .{ place.scale_x, place.scale_y }
    else
        worldScale(app, owner) orelse return null;
    var frame: Transform2D = .{ .scale_x = scale[0], .scale_y = scale[1] };
    if (!owner.eql(e)) {
        // The links between the body's entity and the collider's, composed
        // from the body down: the same numbers every time the body moves, so
        // a moving body does not make its shapes again.
        var chain: [Transform2D.max_depth]Transform2D = undefined;
        var depth: usize = 0;
        var link = place;
        while (true) {
            if (depth == chain.len) return null;
            chain[depth] = link;
            depth += 1;
            if (link.parent.eql(owner)) break;
            link = (app.world.get(link.parent, Transform2D) orelse return null).*;
        }
        while (depth > 0) {
            depth -= 1;
            frame = Transform2D.compose(frame, chain[depth]);
        }
    }
    return .{ .collider = collider, .place = .of(frame), .sprite = spriteOf(app, e, collider) };
}

fn worldScale(app: *App, e: Entity) ?[2]f32 {
    const place = app.world.get(e, Transform2D) orelse return null;
    if (place.parent.isNone()) return .{ place.scale_x, place.scale_y };
    const world = hierarchy.resolve(&app.world, &still, e, place.*, 1) orelse return null;
    return .{ world.scale_x, world.scale_y };
}

fn spriteOf(app: *App, e: Entity, collider: Collider2D) [4]f32 {
    const wanted = switch (collider.shape) {
        .box => collider.width == 0 or collider.height == 0,
        .circle => collider.radius == 0,
    };
    if (!wanted) return @splat(0);
    const drawn = app.world.get(e, Sprite) orelse return @splat(0);
    const texture = app.assets.get(drawn.texture) orelse app.assets.get(app.assets.white) orelse return @splat(0);
    const size = sprite.spriteSize(drawn.*, texture);
    return .{ size.width, size.height, (0.5 - drawn.pivot_x) * size.width, (0.5 - drawn.pivot_y) * size.height };
}

fn reshape(self: *Bodies, app: *App, link: *ShapeLink, e: Entity, body: BodyId, inputs: Inputs) !void {
    if (!link.entity.isNone()) try self.take(app, link.shape, link.entity);
    link.* = .{ .entity = e, .body = body, .made_from = inputs };
    const def = shapeOf(inputs, e) orelse {
        log.warn("the collider on {f} has no size, and no sprite to take one from", .{e});
        return;
    };
    link.shape = try app.physics.addShape(body, def);
}

fn shapeOf(inputs: Inputs, e: Entity) ?physics.Shape {
    const c = inputs.collider;
    const place = inputs.place;
    var offset: [2]f32 = .{ c.offset_x, c.offset_y };
    const geometry: physics.shape.Geometry = switch (c.shape) {
        .box => blk: {
            if (c.width == 0 or c.height == 0) {
                offset[0] += inputs.sprite[2];
                offset[1] += inputs.sprite[3];
            }
            const half_width = @abs((if (c.width != 0) c.width else inputs.sprite[0]) * place.scale_x) / 2;
            const half_height = @abs((if (c.height != 0) c.height else inputs.sprite[1]) * place.scale_y) / 2;
            if (!(half_width > least_size and half_height > least_size)) return null;
            break :blk .{ .polygon = .offsetBox(half_width, half_height, centreOf(place, offset), place.rotation + c.rotation) };
        },
        .circle => blk: {
            if (c.radius == 0) {
                offset[0] += inputs.sprite[2];
                offset[1] += inputs.sprite[3];
            }
            const radius = @abs(if (c.radius != 0) c.radius else inputs.sprite[0] / 2) *
                @max(@abs(place.scale_x), @abs(place.scale_y));
            if (!(radius > least_size)) return null;
            break :blk .{ .circle = .{ .center = centreOf(place, offset), .radius = radius } };
        },
    };
    return .{
        .geometry = geometry,
        .material = .{ .friction = c.friction, .restitution = c.restitution, .density = c.density },
        .filter = .{ .category = c.category, .mask = c.mask, .group = c.group },
        .sensor = c.sensor,
        .user_data = e.toInt(),
    };
}

fn centreOf(place: Pose, offset: [2]f32) Vec2 {
    const frame: Transform2D = .{
        .x = place.x,
        .y = place.y,
        .rotation = place.rotation,
        .scale_x = place.scale_x,
        .scale_y = place.scale_y,
    };
    const at = frame.apply(offset[0], offset[1]);
    return .init(at.x, at.y);
}

fn take(self: *Bodies, app: *App, shape: ShapeId, e: Entity) !void {
    if (app.physics.shape(shape) == null) return;
    try self.departed.append(app.gpa, .{ .shape = shape, .entity = e });
    app.physics.removeShape(shape);
}

fn sweep(self: *Bodies, app: *App) !void {
    for (self.shape_seen.items, self.shapes.items) |*seen, *link| {
        if (seen.* == 0 or seen.* == self.mark) continue;
        try self.take(app, link.shape, link.entity);
        link.* = .{};
        seen.* = 0;
    }
    for (self.body_seen.items, self.bodies.items) |*seen, *link| {
        if (seen.* == 0 or seen.* == self.mark) continue;
        try self.destroy(app, link.body);
        link.* = .{};
        seen.* = 0;
    }
}

fn moved(was: Transform2D, now: Transform2D) bool {
    return was.x != now.x or was.y != now.y or was.rotation != now.rotation or
        was.scale_x != now.scale_x or was.scale_y != now.scale_y or !was.parent.eql(now.parent) or
        was.inherit_rotation != now.inherit_rotation or was.inherit_scale != now.inherit_scale;
}

fn placed(app: *App, e: Entity, place: Transform2D) ?Pose {
    return .of(hierarchy.resolve(&app.world, &still, e, place, 1) orelse return null);
}

/// Write each moving body's place and speed into its components, and hear
/// what began and stopped touching.
pub fn afterStep(self: *Bodies, app: *App) !void {
    for (self.moving.items) |index| {
        const link = &self.bodies.items[index];
        const body = app.physics.bodyConst(link.body) orelse continue;
        const place = app.world.get(link.entity, Transform2D) orelse continue;
        const local = localPose(app, place.*, body) orelse continue;
        place.x = local.x;
        place.y = local.y;
        place.rotation = local.rotation;
        link.transform = place.*;
        link.placed.x = body.position().x;
        link.placed.y = body.position().y;
        link.placed.rotation = body.angle;
        if (app.world.get(link.entity, RigidBody2D)) |written| {
            written.velocity = body.linear_velocity;
            written.angular_velocity = body.angular_velocity;
            link.rigid = written.*;
        }
    }
    try self.hear(app);
}

/// A body's place in its entity's parent's space.
fn localPose(app: *App, place: Transform2D, body: *const physics.Body) ?Pose {
    const at = body.position();
    const parent_local = app.world.get(place.parent, Transform2D) orelse {
        if (!place.parent.isNone() and !app.world.isAlive(place.parent)) return null;
        return .{ .x = at.x, .y = at.y, .rotation = body.angle };
    };
    const parent = hierarchy.resolve(&app.world, &still, place.parent, parent_local.*, 1) orelse return null;
    const local = parent.unapply(at.x, at.y);
    return .{
        .x = local.x,
        .y = local.y,
        .rotation = if (place.inherit_rotation) body.angle - parent.rotation else body.angle,
    };
}

fn hear(self: *Bodies, app: *App) !void {
    self.began_step.clearRetainingCapacity();
    self.ended_step.clearRetainingCapacity();
    try self.collect(app, app.physics.beginEvents(), &self.began_step);
    try self.collect(app, app.physics.endEvents(), &self.ended_step);
    try self.began_frame.appendSlice(app.gpa, self.began_step.items);
    try self.ended_frame.appendSlice(app.gpa, self.ended_step.items);
    self.departed.clearRetainingCapacity();
}

fn collect(self: *Bodies, app: *App, events: []const physics.ContactEvent, into: *std.ArrayList(Contact)) !void {
    for (events) |event| {
        const a = self.entityOf(app, event.shape_a) orelse continue;
        const b = self.entityOf(app, event.shape_b) orelse continue;
        try into.append(app.gpa, .{ .a = a, .b = b, .sensor = event.sensor });
    }
}

/// Forget this frame's contacts. Called at the top of each frame.
pub fn beginFrame(self: *Bodies) void {
    self.began_frame.clearRetainingCapacity();
    self.ended_frame.clearRetainingCapacity();
}

/// Every body the engine made, gone. What `App.clearWorld` needs, because a
/// fresh world hands out the old entities' handles again.
pub fn clear(self: *Bodies, app: *App) void {
    for (self.bodies.items) |link| {
        if (!link.entity.isNone()) app.physics.destroyBody(link.body);
    }
    self.bodies.clearRetainingCapacity();
    self.shapes.clearRetainingCapacity();
    self.body_seen.clearRetainingCapacity();
    self.shape_seen.clearRetainingCapacity();
    self.moving.clearRetainingCapacity();
    self.departed.clearRetainingCapacity();
    self.began_step.clearRetainingCapacity();
    self.ended_step.clearRetainingCapacity();
    self.beginFrame();
}

// -------------------------------------------------------------------------
// Asking
// -------------------------------------------------------------------------

/// The body an entity is, or is part of.
pub fn idOf(self: *const Bodies, e: Entity) ?BodyId {
    if (e.index < self.bodies.items.len and self.bodies.items[e.index].entity.eql(e)) {
        return self.bodies.items[e.index].body;
    }
    if (e.index < self.shapes.items.len and self.shapes.items[e.index].entity.eql(e)) {
        return self.shapes.items[e.index].body;
    }
    return null;
}

/// The collider a shape is, or null for one the engine did not make.
pub fn entityOf(self: *const Bodies, app: *App, shape: ShapeId) ?Entity {
    if (app.physics.shape(shape)) |entry| {
        const e: Entity = .fromInt(entry.def.user_data);
        if (e.index >= self.shapes.items.len) return null;
        const link = self.shapes.items[e.index];
        return if (link.entity.eql(e) and link.shape.eql(shape)) e else null;
    }
    for (self.departed.items) |gone| {
        if (gone.shape.eql(shape)) return gone.entity;
    }
    return null;
}

/// This frame's contacts, or with `fixed` the last step's.
pub fn began(self: *const Bodies, fixed: bool) []const Contact {
    return if (fixed) self.began_step.items else self.began_frame.items;
}

pub fn ended(self: *const Bodies, fixed: bool) []const Contact {
    return if (fixed) self.ended_step.items else self.ended_frame.items;
}

pub fn castRay(self: *const Bodies, app: *App, from: Vec2, to: Vec2, filter: physics.Filter) ?RayHit {
    const hit = app.physics.castRay(from, to.sub(from), filter) orelse return null;
    return .{
        .entity = self.entityOf(app, hit.shape) orelse .none,
        .point = hit.point,
        .normal = hit.normal,
        .fraction = hit.fraction,
    };
}

pub fn overlapPoint(self: *const Bodies, app: *App, point: Vec2) ?Entity {
    return self.entityOf(app, app.physics.overlapPoint(point) orelse return null);
}

pub fn overlapBox(self: *const Bodies, app: *App, min: Vec2, max: Vec2, found: []Entity) []Entity {
    const Gather = struct {
        bodies: *const Bodies,
        app: *App,
        found: []Entity,
        len: usize = 0,

        fn visit(g: *@This(), shape: ShapeId) bool {
            const e = g.bodies.entityOf(g.app, shape) orelse return true;
            g.found[g.len] = e;
            g.len += 1;
            return g.len < g.found.len;
        }
    };
    if (found.len == 0) return found;
    var gather: Gather = .{ .bodies = self, .app = app, .found = found };
    app.physics.overlapAabb(.{ .min = min.min(max), .max = min.max(max) }, &gather, Gather.visit);
    return found[0..gather.len];
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const scene = @import("scene.zig");

fn headless(frame_time: f32) !*App {
    return App.create(testing.allocator, .{ .headless = true, .frame_time = frame_time });
}

fn frames(app: *App, count: usize) !void {
    for (0..count) |_| _ = try app.step();
}

test "a crate falls onto a floor and comes to rest on it" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const floor = try app.world.spawnWith(.{ Transform2D.at(0, 100), Collider2D.box(400, 20) });
    const crate = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{}, Collider2D.box(20, 20) });

    try frames(app, 120);
    try testing.expectApproxEqAbs(@as(f32, 80), app.world.get(crate, Transform2D).?.y, 1);
    try testing.expectApproxEqAbs(@as(f32, 0), app.world.get(crate, RigidBody2D).?.velocity.y, 1);
    try testing.expectEqual(physics.BodyType.static, app.bodyOf(floor).?.type);
    try testing.expectEqual(@as(usize, 2), app.physics.bodyCount());
}

test "a body falling says how fast, in its component" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const stone = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{}, Collider2D.circle(4) });

    try frames(app, 30);
    // Half a second of 981 units a second squared.
    try testing.expectApproxEqAbs(@as(f32, 490), app.world.get(stone, RigidBody2D).?.velocity.y, 20);
}

test "writing the transform moves the body, and writing the velocity sets it going" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const puck = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{ .gravity_scale = 0 }, Collider2D.circle(5) });
    try frames(app, 1);

    app.world.get(puck, Transform2D).?.x = 50;
    try frames(app, 1);
    try testing.expectApproxEqAbs(@as(f32, 50), app.bodyOf(puck).?.position().x, 0.001);

    app.world.get(puck, RigidBody2D).?.velocity = .init(60, 0);
    try frames(app, 1);
    try testing.expectApproxEqAbs(@as(f32, 51), app.world.get(puck, Transform2D).?.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 60), app.world.get(puck, RigidBody2D).?.velocity.x, 0.001);
}

test "a contact is heard once a frame however many steps ran, and once a step in .fixed" {
    const Heard = struct {
        var in_frames: usize = 0;
        var in_steps: usize = 0;

        fn update(a: *App) anyerror!void {
            in_frames += a.contactsBegun().len;
        }

        fn fixed(a: *App) anyerror!void {
            in_steps += a.contactsBegun().len;
        }
    };
    Heard.in_frames = 0;
    Heard.in_steps = 0;

    // Four steps a frame.
    const app = try headless(4.0 / 60.0);
    defer app.destroy();
    try app.addSystem(.update, "count frames", Heard.update);
    try app.addSystem(.fixed, "count steps", Heard.fixed);
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 100), Collider2D.box(400, 20) });
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 70), RigidBody2D{}, Collider2D.box(20, 20) });

    try frames(app, 10);
    try testing.expectEqual(@as(usize, 1), Heard.in_frames);
    try testing.expectEqual(@as(usize, 1), Heard.in_steps);
}

test "a despawned entity takes its body with it, and its contacts end naming it" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const floor = try app.world.spawnWith(.{ Transform2D.at(0, 100), Collider2D.box(400, 20) });
    const crate = try app.world.spawnWith(.{ Transform2D.at(0, 79), RigidBody2D{}, Collider2D.box(20, 20) });
    try frames(app, 5);
    try testing.expectEqual(@as(usize, 2), app.physics.bodyCount());

    app.world.despawn(crate);
    try frames(app, 1);
    try testing.expectEqual(@as(usize, 1), app.physics.bodyCount());
    const ended_now = app.contactsEnded();
    try testing.expectEqual(@as(usize, 1), ended_now.len);
    try testing.expect(ended_now[0].other(floor).?.eql(crate));
}

test "a sensor is heard and pushes nothing" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    var zone = Collider2D.box(100, 100);
    zone.sensor = true;
    const pit = try app.world.spawnWith(.{ Transform2D.at(0, 200), zone });
    const stone = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{}, Collider2D.circle(4) });

    var heard = false;
    for (0..60) |_| {
        _ = try app.step();
        for (app.contactsBegun()) |contact| {
            if (contact.sensor and contact.other(pit) != null) heard = true;
        }
    }
    try testing.expect(heard);
    // It fell straight through.
    try testing.expect(app.world.get(stone, Transform2D).?.y > 300);
}

test "a ray finds what it hits first, and a point what is under it" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const near = try app.world.spawnWith(.{ Transform2D.at(50, 0), Collider2D.box(10, 10) });
    const far = try app.world.spawnWith(.{ Transform2D.at(100, 0), Collider2D.box(10, 10) });
    try app.syncBodies();

    const hit = app.castRay(.init(0, 0), .init(200, 0), .{}).?;
    try testing.expect(hit.entity.eql(near));
    try testing.expectApproxEqAbs(@as(f32, 45), hit.point.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -1), hit.normal.x, 0.001);

    try testing.expect(app.overlapPoint(.init(102, 3)).?.eql(far));
    try testing.expect(app.overlapPoint(.init(75, 0)) == null);

    var found: [4]Entity = undefined;
    try testing.expectEqual(@as(usize, 2), app.overlapBox(.init(40, -10), .init(110, 10), &found).len);
    try testing.expectEqual(@as(usize, 1), app.overlapBox(.init(40, -10), .init(110, 10), found[0..1]).len);
}

test "a collider hanging from a body is part of that body" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const hull = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{ .gravity_scale = 0 }, Collider2D.box(10, 10) });
    const arm = try app.world.spawnWith(.{ Transform2D.childOf(hull, 20, 0), Collider2D.box(10, 10) });
    try app.syncBodies();

    try testing.expectEqual(@as(usize, 1), app.physics.bodyCount());
    try testing.expectEqual(@as(usize, 2), app.physics.shapeCount());
    try testing.expect(app.bodyIdOf(arm).?.eql(app.bodyIdOf(hull).?));
    try testing.expect(app.overlapPoint(.init(22, 0)).?.eql(arm));

    // Turned a quarter, the arm is below the hull, and still part of it.
    app.world.get(hull, Transform2D).?.rotation = std.math.pi / 2.0;
    try app.syncBodies();
    try testing.expect(app.overlapPoint(.init(0, 22)).?.eql(arm));
    try testing.expectEqual(@as(usize, 2), app.physics.shapeCount());
}

test "a collider with no size takes its sprite's, centred on the sprite" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const centred = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite.solid(.white, 30, 10), Collider2D{} });
    var corner = Sprite.solid(.white, 30, 10);
    corner.pivot_x = 0;
    corner.pivot_y = 0;
    const cornered = try app.world.spawnWith(.{ Transform2D.at(100, 0), corner, Collider2D{} });
    try app.syncBodies();

    try testing.expect(app.overlapPoint(.init(14, 4)).?.eql(centred));
    try testing.expect(app.overlapPoint(.init(16, 0)) == null);
    try testing.expect(app.overlapPoint(.init(125, 8)).?.eql(cornered));
    try testing.expect(app.overlapPoint(.init(95, 5)) == null);
}

test "a transform's scale scales its collider" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const big = try app.world.spawnWith(.{ Transform2D.at(0, 0).scaled(2), Collider2D.box(10, 10) });
    try app.syncBodies();
    try testing.expect(app.overlapPoint(.init(9, 0)).?.eql(big));

    app.world.get(big, Transform2D).?.scale_x = 1;
    try app.syncBodies();
    try testing.expect(app.overlapPoint(.init(9, 0)) == null);
}

test "changing a body's type makes it anew" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const crate = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{}, Collider2D.box(10, 10) });
    try frames(app, 1);
    const was = app.bodyIdOf(crate).?;

    app.world.get(crate, RigidBody2D).?.type = .static;
    try frames(app, 1);
    try testing.expect(!app.bodyIdOf(crate).?.eql(was));
    try testing.expectEqual(physics.BodyType.static, app.bodyOf(crate).?.type);
    try testing.expectEqual(@as(usize, 1), app.physics.bodyCount());
    try testing.expectEqual(@as(usize, 1), app.physics.shapeCount());
}

test "a moving parent does not carry a body, whose place is written in the parent's space" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const cart = try app.world.spawnWith(.{Transform2D.at(100, 0)});
    const rider = try app.world.spawnWith(.{ Transform2D.childOf(cart, 10, 0), RigidBody2D{ .gravity_scale = 0 }, Collider2D.circle(2) });
    try frames(app, 1);
    try testing.expectApproxEqAbs(@as(f32, 110), app.bodyOf(rider).?.position().x, 0.001);

    app.world.get(cart, Transform2D).?.x = 200;
    try frames(app, 1);
    try testing.expectApproxEqAbs(@as(f32, 110), app.bodyOf(rider).?.position().x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -90), app.world.get(rider, Transform2D).?.x, 0.001);
}

test "a static collider goes where its transform does, and is found there after the next step" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    const door = try app.world.spawnWith(.{ Transform2D.at(0, 0), Collider2D.box(10, 10) });
    try frames(app, 1);
    app.world.get(door, Transform2D).?.x = 40;
    try frames(app, 1);
    try testing.expectApproxEqAbs(@as(f32, 40), app.bodyOf(door).?.position().x, 0.001);
    try testing.expect(app.overlapPoint(.init(0, 0)) == null);
    try testing.expect(app.overlapPoint(.init(40, 0)).?.eql(door));
}

test "a scene keeps bodies and colliders, and loading one makes them" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 100), Collider2D.box(400, 20) });
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{ .bullet = true }, Collider2D.circle(5) });
    const text = try scene.write(app, testing.allocator, .{});
    defer testing.allocator.free(text);

    const copy = try headless(1.0 / 60.0);
    defer copy.destroy();
    _ = try scene.read(copy, text, .{});
    try copy.syncBodies();
    try testing.expectEqual(@as(usize, 2), copy.physics.bodyCount());
    try testing.expectEqual(@as(usize, 2), copy.physics.shapeCount());
}

test "clearing the world takes every body with it" {
    const app = try headless(1.0 / 60.0);
    defer app.destroy();
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 100), Collider2D.box(400, 20) });
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 0), RigidBody2D{}, Collider2D.circle(5) });
    try frames(app, 1);

    app.clearWorld();
    try frames(app, 1);
    try testing.expectEqual(@as(usize, 0), app.physics.bodyCount());
}
