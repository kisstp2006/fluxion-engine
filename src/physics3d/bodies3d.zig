// SPDX-License-Identifier: BSD-3-Clause

//! The 3D physics world kept in step with the entities. Each `RigidBody3D`,
//! `CharacterBody3D` and `Area3D` is a body and each `Collider3D` a shape,
//! made, changed and taken away as the components are; after every step the
//! bodies' places, turns and speeds go back into the components. The
//! handles live here, beside the world: no component holds one.
//!
//! **A collider made from a mesh** - `convex` or `mesh` - is made from the
//! mesh's corners as its entity is scaled, once for each mesh and scale,
//! and kept while a collider uses it: a hundred crates with one hull share
//! it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const physics3d = @import("fluxion_physics3d");

const App = @import("../App.zig");
const attr = @import("../reflect/attr.zig");
const components = @import("../scene/components.zig");
const hierarchy = @import("../scene/hierarchy.zig");
const mesh_table = @import("../render/mesh.zig");

const Entity = ecs.Entity;
const Vec3 = math.Vec3;
const Quat = math.Quat;
const Transform3D = components.Transform3D;
const RigidBody3D = components.RigidBody3D;
const Collider3D = components.Collider3D;
const Area3D = components.Area3D;
const CharacterBody3D = components.CharacterBody3D;
const MeshInstance3D = components.MeshInstance3D;
const BodyId = physics3d.BodyId;
const ShapeId = physics3d.ShapeId;

const Bodies3D = @This();
const log = std.log.scoped(.fluxion_engine);

/// Two colliders that began or stopped touching.
pub const Contact = struct {
    /// One of the two that touch: a body, or a collider's own static body.
    /// `other(self.entity)` is whichever is not this one.
    a: Entity,
    /// The other.
    b: Entity,
    /// One of them is a sensor: seen, not pushed.
    sensor: bool,

    /// The one that is not `entity`, when `entity` is either.
    pub fn other(self: Contact, entity: Entity) ?Entity {
        if (self.a.eql(entity)) return self.b;
        if (self.b.eql(entity)) return self.a;
        return null;
    }

    pub const reflect_name = "Contact3D";
    pub const reflect_methods = .{
        .other = .{attr.Params{ .names = &.{"entity"} }},
    };
};

/// What a ray hit first.
pub const RayHit = struct {
    /// The collision object it hit: a body, an area, or a collider's own
    /// static body.
    collider: Entity,
    /// The collider it hit.
    shape: Entity,
    /// Where it hit, in the world.
    point: Vec3,
    /// Out of the surface it hit.
    normal: Vec3,
    /// How far along, from nought at the start to one at the end.
    fraction: f32,

    pub const reflect_name = "RayHit3D";
};

bodies: std.ArrayList(BodyLink) = .empty,
shapes: std.ArrayList(ShapeLink) = .empty,
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
mark: u32 = 0,
refused: std.AutoHashMapUnmanaged(Entity, void) = .empty,
exceptions: std.AutoArrayHashMapUnmanaged(EntityPair, u32) = .empty,
/// Hulls and meshes made from the engine's meshes, by what they were made
/// from, with how many shapes use each.
hulls: std.AutoHashMapUnmanaged(MeshKey, Made(physics3d.Hull)) = .empty,
meshes: std.AutoHashMapUnmanaged(MeshKey, Made(physics3d.Mesh)) = .empty,

/// Two entities, the lower first.
pub const EntityPair = struct {
    a: Entity,
    b: Entity,

    pub fn of(x: Entity, y: Entity) EntityPair {
        return if (x.toInt() < y.toInt()) .{ .a = x, .b = y } else .{ .a = y, .b = x };
    }

    fn has(self: EntityPair, e: Entity) bool {
        return self.a.eql(e) or self.b.eql(e);
    }
};

const BodyLink = struct {
    entity: Entity = .none,
    body: BodyId = .none,
    /// As last synced either way. Null for a collider's own static body.
    rigid: ?RigidBody3D = null,
    /// As last synced either way.
    transform: Transform3D = .{},
    parent: Entity = .none,
    /// Where the body was last put, in the world.
    placed: Placed = .{},
};

const ShapeLink = struct {
    entity: Entity = .none,
    shape: ShapeId = .none,
    body: BodyId = .none,
    made_from: Inputs = undefined,
    /// The hull or mesh it holds a count on.
    key: ?MeshKey = null,
};

/// Where an entity is in the world, and how big.
const Placed = struct {
    position: Vec3 = .zero,
    rotation: Quat = .identity,
    scale: Vec3 = .one,
};

/// Everything a shape is made from: when any of it changes, the shape is
/// made again.
const Inputs = struct {
    collider: Collider3D,
    /// The collider's entity in its body's frame, scale and all.
    place: Transform3D,
    /// The mesh a `convex` or `mesh` collider is made from.
    mesh: usize,
    /// Which making of it: see `mesh.Kept.stamp`.
    stamp: u64,
};

/// What a hull or a mesh was made from: the mesh, which making of it, and
/// how it was scaled.
const MeshKey = struct {
    mesh: usize,
    stamp: u64,
    scale: [3]u32,
};

fn Made(comptime T: type) type {
    return struct { held: *T, users: u32 };
}

const Departed = struct { shape: ShapeId, entity: Entity };

const still: hierarchy.Snapshots3D = .empty;

/// Smaller than this, a shape has no size the solver can divide by.
const least_size = 1e-4;

/// The physics' settings as the engine keeps them, whatever a game passed:
/// the same rules as in 2D.
pub fn withEngineRules(settings: physics3d.Settings) physics3d.Settings {
    var kept = settings;
    kept.filter_rule = .either;
    kept.friction_mix = .minimum;
    kept.restitution_mix = .sum_clamped;
    return kept;
}

pub fn deinit(self: *Bodies3D, gpa: Allocator) void {
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
    self.refused.deinit(gpa);
    self.exceptions.deinit(gpa);
    var hulls = self.hulls.valueIterator();
    while (hulls.next()) |made| {
        made.held.deinit(gpa);
        gpa.destroy(made.held);
    }
    self.hulls.deinit(gpa);
    var meshes = self.meshes.valueIterator();
    while (meshes.next()) |made| {
        made.held.deinit(gpa);
        gpa.destroy(made.held);
    }
    self.meshes.deinit(gpa);
    self.* = undefined;
}

// -------------------------------------------------------------------------
// Keeping step
// -------------------------------------------------------------------------

/// Make, change and take away bodies and shapes to match the components.
pub fn sync(self: *Bodies3D, app: *App) !void {
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
    try self.syncCharacters(app);
    try self.syncAreas(app);
    try self.syncColliders(app);
    try self.sweep(app);
}

fn grow(comptime T: type, gpa: Allocator, list: *std.ArrayList(T), len: usize, empty: T) Allocator.Error!void {
    if (list.items.len < len) try list.appendNTimes(gpa, empty, len - list.items.len);
}

fn syncRigid(self: *Bodies3D, app: *App) !void {
    var it = try ecs.Query(.{ Transform3D, RigidBody3D }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(Transform3D), chunk.slice(RigidBody3D)) |e, place, rigid| {
            const link = &self.bodies.items[e.index];
            if (link.entity.eql(e) and link.rigid != null and link.rigid.?.type == rigid.type) {
                update(app, link, place, rigid, false);
            } else {
                const at = placed(app, e, place) orelse continue;
                try self.make(app, link, e, place, at, rigid);
            }
            self.body_seen.items[e.index] = self.mark;
            if (rigid.type != .static) try self.moving.append(app.gpa, e.index);
        }
    }
}

fn update(app: *App, link: *BodyLink, place: Transform3D, rigid: RigidBody3D, follows_parent: bool) void {
    if (app.physics3d.body(link.body) == null) return;
    const was = link.rigid.?;
    const parent = hierarchy.parentOf(&app.world, link.entity);
    if (moved(link.transform, place) or !link.parent.eql(parent) or ((rigid.type == .static or follows_parent) and !parent.isNone())) {
        if (placed(app, link.entity, place)) |at| {
            if (!at.position.eql(link.placed.position) or !std.meta.eql(at.rotation, link.placed.rotation)) {
                app.physics3d.setTransform(link.body, at.position, at.rotation);
            }
            link.placed = at;
        }
        link.transform = place;
        link.parent = parent;
    }
    const b = app.physics3d.body(link.body) orelse return;
    if (!rigid.linear_velocity.eql(was.linear_velocity) or !rigid.angular_velocity.eql(was.angular_velocity)) {
        b.linear_velocity = rigid.linear_velocity;
        b.angular_velocity = if (rigid.lock_rotation) .zero else rigid.angular_velocity;
        b.wake();
    }
    b.linear_damping = linearDamp(app, rigid);
    b.angular_damping = angularDamp(app, rigid);
    if (rigid.gravity_scale != was.gravity_scale) {
        b.gravity_scale = rigid.gravity_scale;
        b.wake();
    }
    if (rigid.can_sleep != was.can_sleep) {
        b.allow_sleep = rigid.can_sleep;
        b.wake();
    }
    if (rigid.lock_rotation != was.lock_rotation) {
        b.lock_rotation = rigid.lock_rotation;
        app.physics3d.updateMass(link.body);
    }
    link.rigid = rigid;
}

fn linearDamp(app: *const App, rigid: RigidBody3D) f32 {
    return if (rigid.linear_damp >= 0) rigid.linear_damp else app.physics_3d.default_linear_damp;
}

fn angularDamp(app: *const App, rigid: RigidBody3D) f32 {
    return if (rigid.angular_damp >= 0) rigid.angular_damp else app.physics_3d.default_angular_damp;
}

fn make(self: *Bodies3D, app: *App, link: *BodyLink, e: Entity, place: Transform3D, at: Placed, rigid: ?RigidBody3D) !void {
    if (!link.entity.isNone()) try self.destroy(app, link.body);
    const r = rigid orelse RigidBody3D{ .type = .static };
    const body = try app.physics3d.createBody(.{
        .type = r.type,
        .position = at.position,
        .rotation = at.rotation,
        .linear_velocity = r.linear_velocity,
        .angular_velocity = r.angular_velocity,
        .linear_damping = linearDamp(app, r),
        .angular_damping = angularDamp(app, r),
        .gravity_scale = r.gravity_scale,
        .lock_rotation = r.lock_rotation,
        .allow_sleep = r.can_sleep,
        .user_data = e.toInt(),
    });
    link.* = .{ .entity = e, .body = body, .rigid = rigid, .transform = place, .parent = hierarchy.parentOf(&app.world, e), .placed = at };
    for (self.exceptions.keys()) |pair| {
        if (!pair.has(e)) continue;
        const other = if (pair.a.eql(e)) pair.b else pair.a;
        if (self.bodyOfObject(other)) |theirs| try app.physics3d.addCollisionException(body, theirs);
    }
}

fn bodyOfObject(self: *const Bodies3D, e: Entity) ?BodyId {
    if (e.index >= self.bodies.items.len) return null;
    const link = self.bodies.items[e.index];
    return if (link.entity.eql(e)) link.body else null;
}

fn destroy(self: *Bodies3D, app: *App, id: BodyId) !void {
    const body = app.physics3d.body(id) orelse return;
    var at = body.first_shape;
    while (app.physics3d.shape(at)) |entry| : (at = entry.next) {
        try self.departed.append(app.gpa, .{ .shape = at, .entity = .fromInt(entry.def.user_data) });
        const e: Entity = .fromInt(entry.def.user_data);
        if (e.index < self.shapes.items.len and self.shapes.items[e.index].shape.eql(at)) self.release(app, &self.shapes.items[e.index]);
    }
    app.physics3d.destroyBody(id);
}

/// A `CharacterBody3D` is a kinematic body that goes where its transform
/// goes: `character3d.zig` moves both at once.
fn syncCharacters(self: *Bodies3D, app: *App) !void {
    var it = try ecs.Query(.{ Transform3D, CharacterBody3D }).over(&app.world);
    while (it.next()) |chunk| {
        if (app.world.has(chunk.entities[0], RigidBody3D)) {
            for (chunk.entities) |e| if (try self.refused.fetchPut(app.gpa, e, {}) == null) {
                log.warn("{f} has a CharacterBody3D and a RigidBody3D; it is a rigid body, and the character does nothing", .{e});
            };
            continue;
        }
        for (chunk.entities, chunk.slice(Transform3D)) |e, place| {
            const character: RigidBody3D = .{ .type = .kinematic };
            const link = &self.bodies.items[e.index];
            if (link.entity.eql(e) and link.rigid != null and link.rigid.?.type == .kinematic) {
                update(app, link, place, character, false);
            } else {
                const at = placed(app, e, place) orelse continue;
                try self.make(app, link, e, place, at, character);
            }
            self.body_seen.items[e.index] = self.mark;
        }
    }
}

/// A character's body and its entity were moved together, to `position`:
/// what the next sync would otherwise take for a move.
pub fn movedTo(self: *Bodies3D, app: *App, e: Entity, position: Vec3, rotation: Quat) void {
    if (e.index >= self.bodies.items.len) return;
    const link = &self.bodies.items[e.index];
    if (!link.entity.eql(e)) return;
    link.placed.position = position;
    link.placed.rotation = rotation;
    if (app.world.get(e, Transform3D)) |place| link.transform = place.*;
    link.parent = hierarchy.parentOf(&app.world, e);
}

/// An `Area3D` is a kinematic body that goes where its transform goes. One
/// with a `RigidBody3D` as well is a body, and its area is passed over.
fn syncAreas(self: *Bodies3D, app: *App) !void {
    var it = try ecs.Query(.{ Transform3D, Area3D }).over(&app.world);
    while (it.next()) |chunk| {
        const also_a_body = app.world.has(chunk.entities[0], RigidBody3D);
        for (chunk.entities, chunk.slice(Transform3D)) |e, place| {
            if (also_a_body) {
                if (try self.refused.fetchPut(app.gpa, e, {}) == null) {
                    log.warn("{f} has an Area3D and a RigidBody3D; it is a body, and the area does nothing", .{e});
                }
                continue;
            }
            const area: RigidBody3D = .{ .type = .kinematic };
            const link = &self.bodies.items[e.index];
            if (link.entity.eql(e) and link.rigid != null and link.rigid.?.type == .kinematic) {
                update(app, link, place, area, true);
            } else {
                const at = placed(app, e, place) orelse continue;
                try self.make(app, link, e, place, at, area);
            }
            self.body_seen.items[e.index] = self.mark;
            try self.moving.append(app.gpa, e.index);
        }
    }
}

fn syncColliders(self: *Bodies3D, app: *App) !void {
    var it = try ecs.Query(.{ Transform3D, Collider3D }).over(&app.world);
    while (it.next()) |chunk| {
        const own_body = owns(&app.world, chunk.entities[0]);
        for (chunk.entities, chunk.slice(Transform3D), chunk.slice(Collider3D)) |e, place, collider| {
            const owner = if (own_body or hierarchy.parentOf(&app.world, e).isNone()) e else ownerOf(&app.world, e) orelse continue;
            if (!own_body and owner.eql(e)) try self.syncStatic(app, e, place);
            if (collider.disabled) continue;

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
fn syncStatic(self: *Bodies3D, app: *App, e: Entity, place: Transform3D) !void {
    const link = &self.bodies.items[e.index];
    if (link.entity.eql(e) and link.rigid == null) {
        const parent = hierarchy.parentOf(&app.world, e);
        if (moved(link.transform, place) or !parent.isNone() or !link.parent.eql(parent)) {
            const at = placed(app, e, place) orelse return;
            if (!at.position.eql(link.placed.position) or !std.meta.eql(at.rotation, link.placed.rotation)) {
                app.physics3d.setTransform(link.body, at.position, at.rotation);
            }
            link.placed = at;
            link.transform = place;
            link.parent = parent;
        }
    } else {
        const at = placed(app, e, place) orelse return;
        try self.make(app, link, e, place, at, null);
    }
    self.body_seen.items[e.index] = self.mark;
}

/// Whether an entity is an area: one that is a body as well is a body.
pub fn isArea(world: *ecs.World, e: Entity) bool {
    return world.has(e, Area3D) and !world.has(e, RigidBody3D);
}

/// Whether an entity is a collision object of its own.
fn owns(world: *ecs.World, e: Entity) bool {
    return world.has(e, RigidBody3D) or world.has(e, CharacterBody3D) or world.has(e, Area3D);
}

/// Which collision object a collider belongs to: the body or area that
/// owns its shape - its own entity, or the nearest above it that is one -
/// else its own entity, a static body of its own.
pub fn objectOf(world: *ecs.World, e: Entity) ?Entity {
    if (!world.has(e, Transform3D)) return null;
    if (!world.has(e, Collider3D)) return if (owns(world, e)) e else null;
    return ownerOf(world, e);
}

fn ownerOf(world: *ecs.World, e: Entity) ?Entity {
    if (owns(world, e)) return e;
    var above = hierarchy.parentOf(world, e);
    var depth: usize = 0;
    while (!above.isNone()) : (depth += 1) {
        if (depth == Transform3D.max_depth) return null;
        if (!world.has(above, Transform3D)) return if (world.isAlive(above)) e else null;
        if (owns(world, above)) return above;
        above = hierarchy.parentOf(world, above);
    }
    return e;
}

fn inputsOf(app: *App, e: Entity, place: Transform3D, collider: Collider3D, owner: Entity) ?Inputs {
    const body_scale = (placed(app, owner, (app.world.get(owner, Transform3D) orelse return null).*) orelse return null).scale;
    var frame: Transform3D = .{ .scale = body_scale };
    if (!owner.eql(e)) {
        // The links between the body's entity and the collider's, composed
        // from the body down: the same numbers every time the body moves.
        var chain: [Transform3D.max_depth]Transform3D = undefined;
        var depth: usize = 0;
        var at = e;
        var link = place;
        while (true) {
            if (depth == chain.len) return null;
            chain[depth] = link;
            depth += 1;
            const above = hierarchy.parentOf(&app.world, at);
            if (above.eql(owner)) break;
            link = (app.world.get(above, Transform3D) orelse return null).*;
            at = above;
        }
        while (depth > 0) {
            depth -= 1;
            frame = .compose(frame, chain[depth]);
        }
    }
    var shaped = collider;
    if (isArea(&app.world, owner)) shaped.sensor = true;
    const made = meshOf(app, e, collider);
    return .{ .collider = shaped, .place = frame, .mesh = if (made) |kept| @intFromPtr(&kept.mesh) else 0, .stamp = if (made) |kept| kept.stamp else 0 };
}

/// The mesh a `convex` or `mesh` collider is made from: its own, or what
/// the `MeshInstance3D` beside it draws.
fn meshOf(app: *App, e: Entity, collider: Collider3D) ?*mesh_table.Kept {
    if (collider.shape != .convex and collider.shape != .mesh) return null;
    if (!collider.mesh.isNone()) return app.meshes.keptOf(collider.mesh);
    const instance = app.world.get(e, MeshInstance3D) orelse return null;
    return app.meshDrawnBy(e, instance.*) catch null;
}

fn reshape(self: *Bodies3D, app: *App, link: *ShapeLink, e: Entity, body: BodyId, inputs: Inputs) !void {
    if (!link.entity.isNone()) try self.take(app, link);
    link.* = .{ .entity = e, .body = body, .made_from = inputs };
    const def = try self.shapeOf(app, link, inputs, e) orelse return;
    link.shape = app.physics3d.addShape(body, def) catch |err| switch (err) {
        error.MeshOnMovingBody => {
            log.warn("the mesh collider on {f} is on a body that moves: a mesh has no inside, so only what never moves can be one - use convex", .{e});
            self.release(app, link);
            return;
        },
        else => |other| return other,
    };
}

fn shapeOf(self: *Bodies3D, app: *App, link: *ShapeLink, inputs: Inputs, e: Entity) !?physics3d.Shape {
    const c = inputs.collider;
    const place = inputs.place;
    const s = place.scale.abs();
    const across = @max(s.x, s.z);
    const made: ?physics3d.Geometry = switch (c.shape) {
        .box => blk: {
            const half = c.extents.mul(s).abs();
            if (!(half.x > least_size and half.y > least_size and half.z > least_size)) break :blk null;
            break :blk .{ .box = .{ .half = half } };
        },
        .sphere => blk: {
            const radius = @abs(c.radius) * @max(across, s.y);
            if (!(radius > least_size)) break :blk null;
            break :blk .{ .sphere = .{ .radius = radius } };
        },
        .capsule => blk: {
            const radius = @abs(c.radius) * across;
            const half_height = @abs(c.height) * s.y / 2 - radius;
            if (!(radius > least_size)) break :blk null;
            if (!(half_height > least_size)) break :blk .{ .sphere = .{ .radius = radius } };
            break :blk .{ .capsule = .{ .half_height = half_height, .radius = radius } };
        },
        .cylinder => blk: {
            const radius = @abs(c.radius) * across;
            const half_height = @abs(c.height) * s.y / 2;
            if (!(radius > least_size and half_height > least_size)) break :blk null;
            break :blk .{ .cylinder = .{ .half_height = half_height, .radius = radius } };
        },
        .convex => blk: {
            const key = keyOf(inputs) orelse break :blk null;
            const hull = try self.hullOf(app, key, place.scale) orelse break :blk null;
            link.key = key;
            break :blk .{ .hull = hull };
        },
        .mesh => blk: {
            const key = keyOf(inputs) orelse break :blk null;
            const mesh = try self.meshFor(app, key, place.scale) orelse break :blk null;
            link.key = key;
            break :blk .{ .mesh = mesh };
        },
    };
    const geometry = made orelse {
        log.warn("the collider on {f} makes no shape: it has no size, no mesh to be made from, or a number in it is not finite", .{e});
        return null;
    };
    // The collider's offset turned and scaled with its entity, from where
    // the entity is on the body.
    const position = place.position.add(place.rotation.quat().rotate(c.offset.mul(place.scale)));
    if (!finite(position) or !place.rotation.quat().isFinite()) return null;
    return .{
        .geometry = geometry,
        .offset = .{ .position = position, .rotation = place.rotation.quat().mul(c.rotation.quat()).norm() },
        .material = .{ .friction = c.friction, .restitution = c.bounce, .density = c.density },
        .filter = .{ .layer = c.collision_layer, .mask = c.collision_mask },
        .sensor = c.sensor,
        .user_data = e.toInt(),
    };
}

fn keyOf(inputs: Inputs) ?MeshKey {
    if (inputs.mesh == 0) return null;
    const s = inputs.place.scale;
    return .{ .mesh = inputs.mesh, .stamp = inputs.stamp, .scale = .{ @bitCast(s.x), @bitCast(s.y), @bitCast(s.z) } };
}

/// The corners of the mesh at `address`, scaled.
fn cornersOf(gpa: Allocator, address: usize, scale: Vec3) !?[]Vec3 {
    const m: *const mesh_table.Mesh = @ptrFromInt(address);
    if (m.vertices.len == 0) return null;
    const out = try gpa.alloc(Vec3, m.vertices.len);
    for (m.vertices, out) |v, *p| p.* = Vec3.fromArray(v.position).mul(scale);
    return out;
}

fn hullOf(self: *Bodies3D, app: *App, key: MeshKey, scale: Vec3) !?*const physics3d.Hull {
    if (self.hulls.getPtr(key)) |made| {
        made.users += 1;
        return made.held;
    }
    const corners = try cornersOf(app.gpa, key.mesh, scale) orelse return null;
    defer app.gpa.free(corners);
    const held = try app.gpa.create(physics3d.Hull);
    errdefer app.gpa.destroy(held);
    held.* = physics3d.Hull.init(app.gpa, corners) catch |err| switch (err) {
        error.FlatHull => {
            log.warn("a convex collider's mesh is flat: no solid round it", .{});
            app.gpa.destroy(held);
            return null;
        },
        else => |other| return other,
    };
    try self.hulls.put(app.gpa, key, .{ .held = held, .users = 1 });
    return held;
}

fn meshFor(self: *Bodies3D, app: *App, key: MeshKey, scale: Vec3) !?*const physics3d.Mesh {
    if (self.meshes.getPtr(key)) |made| {
        made.users += 1;
        return made.held;
    }
    const corners = try cornersOf(app.gpa, key.mesh, scale) orelse return null;
    defer app.gpa.free(corners);
    const m: *const mesh_table.Mesh = @ptrFromInt(key.mesh);
    const held = try app.gpa.create(physics3d.Mesh);
    errdefer app.gpa.destroy(held);
    held.* = physics3d.Mesh.init(app.gpa, corners, m.indices) catch |err| switch (err) {
        error.BadMesh => {
            app.gpa.destroy(held);
            return null;
        },
        else => |other| return other,
    };
    try self.meshes.put(app.gpa, key, .{ .held = held, .users = 1 });
    return held;
}

/// A shape's count on its hull or mesh given back, and the hull or mesh
/// let go of with the last.
fn release(self: *Bodies3D, app: *App, link: *ShapeLink) void {
    const key = link.key orelse return;
    link.key = null;
    const convex = link.made_from.collider.shape == .convex;
    if (convex) {
        const made = self.hulls.getPtr(key) orelse return;
        made.users -= 1;
        if (made.users > 0) return;
        made.held.deinit(app.gpa);
        app.gpa.destroy(made.held);
        _ = self.hulls.remove(key);
    } else {
        const made = self.meshes.getPtr(key) orelse return;
        made.users -= 1;
        if (made.users > 0) return;
        made.held.deinit(app.gpa);
        app.gpa.destroy(made.held);
        _ = self.meshes.remove(key);
    }
}

fn finite(v: Vec3) bool {
    return std.math.isFinite(v.x) and std.math.isFinite(v.y) and std.math.isFinite(v.z);
}

fn take(self: *Bodies3D, app: *App, link: *ShapeLink) !void {
    if (app.physics3d.shape(link.shape) != null) {
        try self.departed.append(app.gpa, .{ .shape = link.shape, .entity = link.entity });
        app.physics3d.removeShape(link.shape);
    }
    self.release(app, link);
}

fn sweep(self: *Bodies3D, app: *App) !void {
    var at: usize = 0;
    while (at < self.exceptions.count()) {
        const pair = self.exceptions.keys()[at];
        if (app.world.isAlive(pair.a) and app.world.isAlive(pair.b)) {
            at += 1;
        } else {
            self.exceptions.orderedRemoveAt(at);
        }
    }
    for (self.shape_seen.items, self.shapes.items) |*seen, *link| {
        if (seen.* == 0 or seen.* == self.mark) continue;
        try self.take(app, link);
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

fn moved(was: Transform3D, now: Transform3D) bool {
    return !was.position.eql(now.position) or !std.meta.eql(was.rotation, now.rotation) or !was.scale.eql(now.scale) or
        was.inherit_rotation != now.inherit_rotation or was.inherit_scale != now.inherit_scale;
}

/// Where a body goes, or null when it cannot be placed.
fn placed(app: *App, e: Entity, place: Transform3D) ?Placed {
    const world = hierarchy.resolve3D(&app.world, &still, e, place, 1) orelse return null;
    const at: Placed = .{ .position = world.position, .rotation = world.rotation.quat().norm(), .scale = world.scale };
    return if (finite(at.position) and finite(at.scale) and at.rotation.isFinite()) at else null;
}

/// Write each moving body's place, turn and speeds into its components, and
/// hear what began and stopped touching.
pub fn afterStep(self: *Bodies3D, app: *App) !void {
    for (self.moving.items) |index| {
        const link = &self.bodies.items[index];
        const body = app.physics3d.bodyConst(link.body) orelse continue;
        const place = app.world.get(link.entity, Transform3D) orelse continue;
        if (!localPlace(app, link.entity, place, body)) continue;
        link.transform = place.*;
        link.placed.position = body.position();
        link.placed.rotation = body.rotation();
        if (app.world.get(link.entity, RigidBody3D)) |written| {
            written.linear_velocity = body.linear_velocity;
            written.angular_velocity = body.angular_velocity;
            link.rigid = written.*;
        }
    }
    try self.hear(app);
}

/// A body's place and turn into its entity's transform, in its parent's
/// space. False when there is no parent's place to be in.
fn localPlace(app: *App, e: Entity, place: *Transform3D, body: *const physics3d.Body) bool {
    const above = hierarchy.parentOf(&app.world, e);
    const at = body.position();
    const turn = body.rotation();
    const parent_local = app.world.get(above, Transform3D) orelse {
        if (!above.isNone() and !app.world.isAlive(above)) return false;
        place.position = at;
        place.rotation = .of(turn);
        return true;
    };
    const parent = hierarchy.resolve3D(&app.world, &still, above, parent_local.*, 1) orelse return false;
    place.position = parent.unapply(at);
    place.rotation = if (place.inherit_rotation) .of(parent.rotation.quat().conj().mul(turn).norm()) else .of(turn);
    return true;
}

fn hear(self: *Bodies3D, app: *App) !void {
    self.began_step.clearRetainingCapacity();
    self.ended_step.clearRetainingCapacity();
    try self.collect(app, app.physics3d.beginEvents(), &self.began_step);
    try self.collect(app, app.physics3d.endEvents(), &self.ended_step);
    try self.began_frame.appendSlice(app.gpa, self.began_step.items);
    try self.ended_frame.appendSlice(app.gpa, self.ended_step.items);
    self.departed.clearRetainingCapacity();
}

fn collect(self: *Bodies3D, app: *App, events: []const physics3d.ContactEvent, into: *std.ArrayList(Contact)) !void {
    for (events) |event| {
        const a = self.entityOf(app, event.shape_a) orelse continue;
        const b = self.entityOf(app, event.shape_b) orelse continue;
        try into.append(app.gpa, .{ .a = a, .b = b, .sensor = event.sensor });
    }
}

pub fn beginFrame(self: *Bodies3D) void {
    self.began_frame.clearRetainingCapacity();
    self.ended_frame.clearRetainingCapacity();
}

/// Every body the engine made, gone: a world cleared.
pub fn clear(self: *Bodies3D, app: *App) void {
    for (self.bodies.items) |link| {
        if (!link.entity.isNone()) app.physics3d.destroyBody(link.body);
    }
    for (self.shapes.items) |*link| self.release(app, link);
    self.bodies.clearRetainingCapacity();
    self.shapes.clearRetainingCapacity();
    self.body_seen.clearRetainingCapacity();
    self.shape_seen.clearRetainingCapacity();
    self.moving.clearRetainingCapacity();
    self.departed.clearRetainingCapacity();
    self.began_step.clearRetainingCapacity();
    self.ended_step.clearRetainingCapacity();
    self.exceptions.clearRetainingCapacity();
    self.beginFrame();
}

// -------------------------------------------------------------------------
// Collision exceptions
// -------------------------------------------------------------------------

pub const ExceptionError = error{ NotABody, OutOfMemory };

pub fn addException(self: *Bodies3D, app: *App, a: Entity, b: Entity) ExceptionError!void {
    if (!owns(&app.world, a) and !app.world.has(a, Collider3D)) return error.NotABody;
    if (!owns(&app.world, b) and !app.world.has(b, Collider3D)) return error.NotABody;
    const entry = try self.exceptions.getOrPut(app.gpa, .of(a, b));
    if (entry.found_existing) {
        entry.value_ptr.* += 1;
        return;
    }
    entry.value_ptr.* = 1;
    if (self.bodyOfObject(a)) |x| if (self.bodyOfObject(b)) |y| try app.physics3d.addCollisionException(x, y);
}

pub fn removeException(self: *Bodies3D, app: *App, a: Entity, b: Entity) void {
    const count = self.exceptions.getPtr(.of(a, b)) orelse return;
    count.* -= 1;
    if (count.* > 0) return;
    _ = self.exceptions.orderedRemove(.of(a, b));
    if (self.bodyOfObject(a)) |x| if (self.bodyOfObject(b)) |y| app.physics3d.removeCollisionException(x, y);
}

// -------------------------------------------------------------------------
// Asking
// -------------------------------------------------------------------------

/// The body an entity is, or is part of.
pub fn idOf(self: *const Bodies3D, e: Entity) ?BodyId {
    if (e.index < self.bodies.items.len and self.bodies.items[e.index].entity.eql(e)) return self.bodies.items[e.index].body;
    if (e.index < self.shapes.items.len and self.shapes.items[e.index].entity.eql(e)) return self.shapes.items[e.index].body;
    return null;
}

/// The collider a shape is, or null for one the engine did not make.
pub fn entityOf(self: *const Bodies3D, app: *App, shape: ShapeId) ?Entity {
    if (app.physics3d.shape(shape)) |entry| {
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

/// The collider an entity has as a shape now.
pub fn shapeOfEntity(self: *const Bodies3D, e: Entity) ?ShapeId {
    if (e.index >= self.shapes.items.len) return null;
    const link = self.shapes.items[e.index];
    return if (link.entity.eql(e) and !link.shape.isNone()) link.shape else null;
}

pub fn began(self: *const Bodies3D, fixed: bool) []const Contact {
    return if (fixed) self.began_step.items else self.began_frame.items;
}

pub fn ended(self: *const Bodies3D, fixed: bool) []const Contact {
    return if (fixed) self.ended_step.items else self.ended_frame.items;
}

pub fn castRay(self: *const Bodies3D, app: *App, from: Vec3, to: Vec3, filter: physics3d.QueryFilter) ?RayHit {
    const hit = app.physics3d.castRay(from, to.sub(from), filter) orelse return null;
    const shape = self.entityOf(app, hit.shape) orelse Entity.none;
    return .{
        .collider = if (shape.isNone()) .none else objectOf(&app.world, shape) orelse shape,
        .shape = shape,
        .point = hit.point,
        .normal = hit.normal,
        .fraction = hit.fraction,
    };
}
