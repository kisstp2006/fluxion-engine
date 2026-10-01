// SPDX-License-Identifier: BSD-3-Clause

//! The physics world kept in step with the entities. Each `RigidBody2D` is a
//! body and each `Collider2D` a shape, made, changed and taken away as the
//! components are, and after every step the bodies' places and speeds go
//! back into the components. The handles live here, beside the world, as the
//! names do: no component holds one.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const physics = @import("fluxion_physics");

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const hierarchy = @import("../scene/hierarchy.zig");
const sprite = @import("../render/sprite.zig");
const tilemap = @import("../tiles/tilemap.zig");
const tileset = @import("../tiles/tileset.zig");

const Entity = ecs.Entity;
const Vec2 = math.Vec2;
const Transform2D = components.Transform2D;
const RigidBody2D = components.RigidBody2D;
const Collider2D = components.Collider2D;
const Area2D = components.Area2D;
const CharacterBody2D = components.CharacterBody2D;
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
    /// The collision object it hit: a body, an area, or a collider's own
    /// static body. See `App.collisionObjectOf`.
    collider: Entity,
    /// The collider it hit; `.none` for a shape the engine did not make.
    shape: Entity,
    point: Vec2,
    /// Out of the surface it hit.
    normal: Vec2,
    /// How far along, from zero at the start to one at the end.
    fraction: f32,

    pub const reflect_name = "RayHit";
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
/// Entities told already that they cannot be a body and an area at once.
refused: std.AutoHashMapUnmanaged(Entity, void) = .empty,
/// Pairs of bodies kept from touching, with how many times each was asked:
/// the collision exceptions, by entity, so they outlast a body made anew.
/// The physics is told of each pair once, while both bodies are there.
exceptions: std.AutoArrayHashMapUnmanaged(EntityPair, u32) = .empty,
tile_bodies: std.AutoHashMapUnmanaged(Entity, TileBody) = .empty,

/// Two entities, the lower first, so either order names the pair.
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
    rigid: ?RigidBody2D = null,
    /// As last synced either way.
    transform: Transform2D = .{},
    /// What it hung from when it was last synced.
    parent: Entity = .none,
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

const TileBody = struct {
    body: BodyId,
    map: Entity,
    revision: u32,
    settings: TileSettings,
    placed: Pose,
    seen: u32,
};

const TileSettings = struct {
    tile_set: tileset.TileSetHandle,
    tile_set_revision: u32,
    collision_layer: u32,
    collision_mask: u32,
    friction: f32,
    bounce: f32,
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

/// The physics' settings as the engine keeps them, whatever a game passed:
/// two colliders touch when either one's mask has the other's layer, a
/// pair's friction is the smaller of the two, and its bounce the two added.
pub fn withEngineRules(settings: physics.Settings) physics.Settings {
    var kept = settings;
    kept.filter_rule = .either;
    kept.friction_mix = .minimum;
    kept.restitution_mix = .sum_clamped;
    return kept;
}

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
    self.refused.deinit(gpa);
    self.exceptions.deinit(gpa);
    self.tile_bodies.deinit(gpa);
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
    try self.syncCharacters(app);
    try self.syncAreas(app);
    try self.syncColliders(app);
    try self.syncTiles(app);
    try self.sweep(app);
}

fn syncTiles(self: *Bodies, app: *App) !void {
    var it = try ecs.Query(.{tilemap.TileChunk}).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(tilemap.TileChunk)) |entity, tiles| {
            const map = app.world.get(tiles.map, tilemap.TileMap) orelse continue;
            const local = app.world.get(tiles.map, Transform2D) orelse continue;
            const world = hierarchy.resolve(&app.world, &still, tiles.map, local.*, 1) orelse continue;
            const at = Pose.of(world);
            const set = app.tile_sets.get(map.tile_set);
            const settings: TileSettings = .{
                .tile_set = map.tile_set,
                // The set's own revision: a shape edited in an editor
                // reaches the physics as a saved file would.
                .tile_set_revision = if (set) |held| held.revision else 0,
                .collision_layer = map.collision_layer,
                .collision_mask = map.collision_mask,
                .friction = map.friction,
                .bounce = map.bounce,
            };
            if (self.tile_bodies.getPtr(entity)) |held| {
                if (held.map.eql(tiles.map) and held.revision == tiles.revision and std.meta.eql(held.settings, settings) and std.meta.eql(held.placed, at)) {
                    held.seen = self.mark;
                    continue;
                }
                try self.destroy(app, held.body);
            }
            const body = try app.physics.createBody(.{
                .type = .static,
                .position = .init(at.x, at.y),
                .angle = at.rotation,
                .user_data = tiles.map.toInt(),
            });
            errdefer app.physics.destroyBody(body);
            try addTileShapes(app, body, tiles, map.*, set, at);
            try self.tile_bodies.put(app.gpa, entity, .{
                .body = body,
                .map = tiles.map,
                .revision = tiles.revision,
                .settings = settings,
                .placed = at,
                .seen = self.mark,
            });
        }
    }

    var stale: std.ArrayList(Entity) = .empty;
    defer stale.deinit(app.gpa);
    var links = self.tile_bodies.iterator();
    while (links.next()) |entry| if (entry.value_ptr.seen != self.mark) try stale.append(app.gpa, entry.key_ptr.*);
    for (stale.items) |entity| {
        const held = self.tile_bodies.get(entity) orelse continue;
        try self.destroy(app, held.body);
        _ = self.tile_bodies.remove(entity);
    }
}

/// One chunk's shapes on its body: the tiles their tile set calls `full`,
/// merged into as few boxes as they make, and one polygon for each tile with
/// a shape of its own.
///
/// A map with no tile set stops nothing: what is solid is the set's to say.
fn addTileShapes(app: *App, body: BodyId, chunk: tilemap.TileChunk, map: tilemap.TileMap, set: ?*const tileset.TileSet, placed_map: Pose) !void {
    const held = set orelse return;
    const tile_width: f32 = @floatFromInt(@max(held.tile_width, 1));
    const tile_height: f32 = @floatFromInt(@max(held.tile_height, 1));
    const material: physics.Material = .{ .friction = map.friction, .restitution = map.bounce, .density = 1 };
    const filter: physics.Filter = .{ .category = map.collision_layer, .mask = map.collision_mask };

    var solids: tilemap.Solids = .{ .chunk = &chunk, .set = held };
    while (solids.next()) |solid| switch (solid) {
        .polygon => |shaped| try addTilePolygon(app, body, chunk, shaped.cell, shaped.tile, shaped.x, shaped.y, tile_width, tile_height, placed_map, material, filter),
        .box => |box| {
            const local_x = (@as(f32, @floatFromInt(chunk.x * tilemap.chunk_side)) + @as(f32, @floatFromInt(box.x)) + @as(f32, @floatFromInt(box.width)) / 2) * tile_width * placed_map.scale_x;
            const local_y = (@as(f32, @floatFromInt(chunk.y * tilemap.chunk_side)) + @as(f32, @floatFromInt(box.y)) + @as(f32, @floatFromInt(box.height)) / 2) * tile_height * placed_map.scale_y;
            const half_width = @as(f32, @floatFromInt(box.width)) * tile_width * @abs(placed_map.scale_x) / 2;
            const half_height = @as(f32, @floatFromInt(box.height)) * tile_height * @abs(placed_map.scale_y) / 2;
            _ = try app.physics.addShape(body, .{
                .geometry = .{ .polygon = .offsetBox(half_width, half_height, .init(local_x, local_y), 0) },
                .material = material,
                .filter = filter,
                .user_data = chunk.map.toInt(),
            });
        },
    };
}

/// One tile's own shape, put where the cell turns it: `tilemap.place` says
/// where a corner of the picture lands, and a corner of the shape lands
/// there too.
fn addTilePolygon(
    app: *App,
    body: BodyId,
    chunk: tilemap.TileChunk,
    cell: tilemap.Cell,
    tile: tileset.Tile,
    x: usize,
    y: usize,
    tile_width: f32,
    tile_height: f32,
    placed_map: Pose,
    material: physics.Material,
    filter: physics.Filter,
) !void {
    const corner_x = (@as(f32, @floatFromInt(chunk.x * tilemap.chunk_side)) + @as(f32, @floatFromInt(x))) * tile_width;
    const corner_y = (@as(f32, @floatFromInt(chunk.y * tilemap.chunk_side)) + @as(f32, @floatFromInt(y))) * tile_height;

    var points: [tileset.max_points]Vec2 = undefined;
    const given = tile.polygon();
    for (given, 0..) |point, i| {
        const at = tilemap.place(cell, point.x / tile_width, point.y / tile_height);
        points[i] = .init(
            (corner_x + at[0] * tile_width) * placed_map.scale_x,
            (corner_y + at[1] * tile_height) * placed_map.scale_y,
        );
    }
    const polygon = physics.Polygon.fromPoints(points[0..given.len]) catch |err| {
        log.warn("a tile's shape is not a polygon the physics can hold: {t}", .{err});
        return;
    };
    _ = try app.physics.addShape(body, .{
        .geometry = .{ .polygon = polygon },
        .material = material,
        .filter = filter,
        .user_data = chunk.map.toInt(),
    });
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

fn update(app: *App, link: *BodyLink, place: Transform2D, rigid: RigidBody2D, follows_parent: bool) void {
    const body = app.physics.body(link.body) orelse return;
    const was = link.rigid.?;
    const parent = hierarchy.parentOf(&app.world, link.entity);
    if (moved(link.transform, place) or !link.parent.eql(parent) or ((rigid.type == .static or follows_parent) and !parent.isNone())) {
        if (placed(app, link.entity, place)) |at| {
            if (!std.meta.eql(at, link.placed)) body.setTransform(.init(at.x, at.y), at.rotation);
            link.placed = at;
        }
        link.transform = place;
        link.parent = parent;
    }
    if (!std.meta.eql(rigid.linear_velocity, was.linear_velocity) or rigid.angular_velocity != was.angular_velocity) {
        body.linear_velocity = rigid.linear_velocity;
        body.angular_velocity = rigid.angular_velocity;
        body.wake();
    }
    body.linear_damping = linearDamp(app, rigid);
    body.angular_damping = angularDamp(app, rigid);
    body.bullet = rigid.continuous_cd != .disabled;
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

/// A body's damping: its own, or with minus one the project's.
fn linearDamp(app: *const App, rigid: RigidBody2D) f32 {
    return if (rigid.linear_damp >= 0) rigid.linear_damp else app.physics_2d.default_linear_damp;
}

fn angularDamp(app: *const App, rigid: RigidBody2D) f32 {
    return if (rigid.angular_damp >= 0) rigid.angular_damp else app.physics_2d.default_angular_damp;
}

fn make(self: *Bodies, app: *App, link: *BodyLink, e: Entity, place: Transform2D, at: Pose, rigid: ?RigidBody2D) !void {
    if (!link.entity.isNone()) try self.destroy(app, link.body);
    const r = rigid orelse RigidBody2D{ .type = .static };
    const body = try app.physics.createBody(.{
        .type = r.type,
        .position = .init(at.x, at.y),
        .angle = at.rotation,
        .linear_velocity = r.linear_velocity,
        .angular_velocity = r.angular_velocity,
        .linear_damping = linearDamp(app, r),
        .angular_damping = angularDamp(app, r),
        .gravity_scale = r.gravity_scale,
        .fixed_rotation = r.fixed_rotation,
        .allow_sleep = r.can_sleep,
        .bullet = r.continuous_cd != .disabled,
        .user_data = e.toInt(),
    });
    link.* = .{ .entity = e, .body = body, .rigid = rigid, .transform = place, .parent = hierarchy.parentOf(&app.world, e), .placed = at };
    // A body made anew has lost its exceptions with the old one.
    for (self.exceptions.keys()) |pair| {
        if (!pair.has(e)) continue;
        const other = if (pair.a.eql(e)) pair.b else pair.a;
        if (self.bodyOfObject(other)) |theirs| try app.physics.addCollisionException(body, theirs);
    }
}

/// The body an object has now: a body, or a collider's own static one.
fn bodyOfObject(self: *const Bodies, e: Entity) ?BodyId {
    if (e.index >= self.bodies.items.len) return null;
    const link = self.bodies.items[e.index];
    return if (link.entity.eql(e)) link.body else null;
}

// -------------------------------------------------------------------------
// Collision exceptions
// -------------------------------------------------------------------------

pub const ExceptionError = error{
    /// Neither a `RigidBody2D` nor a collider that is its own static body:
    /// an area, a collider that is part of a body, or nothing physical.
    NotABody,
    /// The same body twice.
    SameBody,
} || Allocator.Error;

/// Keep two bodies from touching, whatever their layers and masks say.
/// Counted, so two calls take two removals. It lasts until then or until
/// either entity is gone, a body made anew included.
pub fn addException(self: *Bodies, app: *App, a: Entity, b: Entity) ExceptionError!void {
    if (!isBody(&app.world, a) or !isBody(&app.world, b)) return error.NotABody;
    if (a.eql(b)) return error.SameBody;
    const held = try self.exceptions.getOrPut(app.gpa, .of(a, b));
    if (held.found_existing) {
        held.value_ptr.* += 1;
        return;
    }
    held.value_ptr.* = 1;
    const ours = self.bodyOfObject(a) orelse return;
    const theirs = self.bodyOfObject(b) orelse return;
    app.physics.addCollisionException(ours, theirs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Both are there: `bodyOfObject` found them.
        error.NoSuchBody, error.SameBody => unreachable,
    };
}

/// Take one `addException` back. Nothing, for a pair that has none.
pub fn removeException(self: *Bodies, app: *App, a: Entity, b: Entity) void {
    const key: EntityPair = .of(a, b);
    const count = self.exceptions.getPtr(key) orelse return;
    count.* -= 1;
    if (count.* > 0) return;
    _ = self.exceptions.orderedRemove(key);
    const ours = self.bodyOfObject(a) orelse return;
    const theirs = self.bodyOfObject(b) orelse return;
    app.physics.removeCollisionException(ours, theirs);
}

/// The bodies `e` is kept from touching, as many as `found` holds, in the
/// order they were asked for.
pub fn exceptionsOf(self: *const Bodies, e: Entity, found: []Entity) []Entity {
    var count: usize = 0;
    for (self.exceptions.keys()) |pair| {
        if (count == found.len) break;
        if (!pair.has(e)) continue;
        found[count] = if (pair.a.eql(e)) pair.b else pair.a;
        count += 1;
    }
    return found[0..count];
}

/// Whether an entity is a body a collision exception can name: a
/// `RigidBody2D`, or a collider that is a static body of its own.
fn isBody(world: *ecs.World, e: Entity) bool {
    if (world.has(e, RigidBody2D) or world.has(e, CharacterBody2D)) return true;
    if (world.has(e, Area2D)) return false;
    if (!world.has(e, Transform2D)) return false;
    if (!world.has(e, Collider2D)) return false;
    const owner = ownerOf(world, e) orelse return false;
    return owner.eql(e);
}

fn destroy(self: *Bodies, app: *App, id: BodyId) !void {
    const body = app.physics.body(id) orelse return;
    var at = body.first_shape;
    while (app.physics.shape(at)) |entry| : (at = entry.next) {
        try self.departed.append(app.gpa, .{ .shape = at, .entity = .fromInt(entry.def.user_data) });
    }
    app.physics.destroyBody(id);
}

/// A `CharacterBody2D` is a kinematic body that goes where its transform
/// goes: `character.zig` moves both at once. Not written back after a step,
/// which moves it nowhere.
fn syncCharacters(self: *Bodies, app: *App) !void {
    var it = try ecs.Query(.{ Transform2D, CharacterBody2D }).over(&app.world);
    while (it.next()) |chunk| {
        if (app.world.has(chunk.entities[0], RigidBody2D)) {
            for (chunk.entities) |e| if (try self.refused.fetchPut(app.gpa, e, {}) == null) {
                log.warn("{f} has a CharacterBody2D and a RigidBody2D; it is a rigid body, and the character does nothing", .{e});
            };
            continue;
        }
        for (chunk.entities, chunk.slice(Transform2D)) |e, place| {
            const character: RigidBody2D = .{ .type = .kinematic };
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

/// A character's body and its entity were moved together, to `position`
/// in the world: what the next sync would otherwise take for a move.
pub fn movedTo(self: *Bodies, app: *App, e: Entity, position: Vec2, rotation: f32) void {
    if (e.index >= self.bodies.items.len) return;
    const link = &self.bodies.items[e.index];
    if (!link.entity.eql(e)) return;
    link.placed.x = position.x;
    link.placed.y = position.y;
    link.placed.rotation = rotation;
    if (app.world.get(e, Transform2D)) |place| link.transform = place.*;
    link.parent = hierarchy.parentOf(&app.world, e);
}

/// An `Area2D` is a kinematic body that goes where its transform goes. An
/// entity with a `RigidBody2D` as well is a body, and its area is passed
/// over: a place that tells what is in it is not also a thing that falls.
fn syncAreas(self: *Bodies, app: *App) !void {
    var it = try ecs.Query(.{ Transform2D, Area2D }).over(&app.world);
    while (it.next()) |chunk| {
        const also_a_body = app.world.has(chunk.entities[0], RigidBody2D);
        for (chunk.entities, chunk.slice(Transform2D)) |e, place| {
            if (also_a_body) {
                if (try self.refused.fetchPut(app.gpa, e, {}) == null) {
                    log.warn("{f} has an Area2D and a RigidBody2D; it is a body, and the area does nothing", .{e});
                }
                continue;
            }
            const area: RigidBody2D = .{ .type = .kinematic };
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

fn syncColliders(self: *Bodies, app: *App) !void {
    var it = try ecs.Query(.{ Transform2D, Collider2D }).over(&app.world);
    while (it.next()) |chunk| {
        // One archetype: every row has a body of its own, or none does.
        const own_body = owns(&app.world, chunk.entities[0]);
        for (chunk.entities, chunk.slice(Transform2D), chunk.slice(Collider2D)) |e, place, collider| {
            const owner = if (own_body or hierarchy.parentOf(&app.world, e).isNone()) e else ownerOf(&app.world, e) orelse continue;
            if (!own_body and owner.eql(e)) try self.syncStatic(app, e, place);
            // Not there while disabled: its shape goes with the sweep.
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
fn syncStatic(self: *Bodies, app: *App, e: Entity, place: Transform2D) !void {
    const link = &self.bodies.items[e.index];
    if (link.entity.eql(e) and link.rigid == null) {
        const parent = hierarchy.parentOf(&app.world, e);
        if (moved(link.transform, place) or !parent.isNone() or !link.parent.eql(parent)) {
            const at = placed(app, e, place) orelse return;
            if (!std.meta.eql(at, link.placed)) {
                if (app.physics.body(link.body)) |body| body.setTransform(.init(at.x, at.y), at.rotation);
                link.placed = at;
            }
            link.transform = place;
            link.parent = parent;
        }
    } else {
        const at = placed(app, e, place) orelse return;
        try self.make(app, link, e, place, at, null);
    }
    self.body_seen.items[e.index] = self.mark;
}

/// Whether an entity is an area: one that is a body as well is a body, and
/// its area does nothing. See `syncAreas`.
pub fn isArea(world: *ecs.World, e: Entity) bool {
    return world.has(e, Area2D) and !world.has(e, RigidBody2D);
}

/// Whether an entity is a collision object of its own: a body, a
/// character, or an area.
fn owns(world: *ecs.World, e: Entity) bool {
    return world.has(e, RigidBody2D) or world.has(e, CharacterBody2D) or world.has(e, Area2D);
}

/// Which collision object a collider belongs to: the body or area that owns
/// a shape. Its own entity when that is a body or an area, else the
/// nearest one above it that is, else its own entity, which is its own
/// static body. Null when it is neither a collider nor an object itself, or
/// when the chain above it is broken.
pub fn objectOf(world: *ecs.World, e: Entity) ?Entity {
    if (!world.has(e, Transform2D)) return null;
    if (!world.has(e, Collider2D)) return if (owns(world, e)) e else null;
    return ownerOf(world, e);
}

/// Whose body a collider is part of: its own entity when that is a body or
/// an area, else the nearest one above it that is, else its own. Null when
/// the chain above it is broken.
fn ownerOf(world: *ecs.World, e: Entity) ?Entity {
    if (owns(world, e)) return e;
    var above = hierarchy.parentOf(world, e);
    var depth: usize = 0;
    while (!above.isNone()) : (depth += 1) {
        if (depth == Transform2D.max_depth) return null;
        if (!world.has(above, Transform2D)) return if (world.isAlive(above)) e else null;
        if (owns(world, above)) return above;
        above = hierarchy.parentOf(world, above);
    }
    return e;
}

fn inputsOf(app: *App, e: Entity, place: Transform2D, collider: Collider2D, owner: Entity) ?Inputs {
    const scale = if (owner.eql(e) and hierarchy.parentOf(&app.world, e).isNone())
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
        var at = e;
        var link = place;
        while (true) {
            if (depth == chain.len) return null;
            chain[depth] = link;
            depth += 1;
            const above = hierarchy.parentOf(&app.world, at);
            if (above.eql(owner)) break;
            link = (app.world.get(above, Transform2D) orelse return null).*;
            at = above;
        }
        while (depth > 0) {
            depth -= 1;
            frame = Transform2D.compose(frame, chain[depth]);
        }
    }
    // Every shape of an area is a sensor, whatever its collider says.
    var shaped = collider;
    if (isArea(&app.world, owner)) shaped.sensor = true;
    return .{ .collider = shaped, .place = .of(frame), .sprite = spriteOf(app, e, shaped) };
}

fn worldScale(app: *App, e: Entity) ?[2]f32 {
    const place = app.world.get(e, Transform2D) orelse return null;
    if (hierarchy.parentOf(&app.world, e).isNone()) return .{ place.scale_x, place.scale_y };
    const world = hierarchy.resolve(&app.world, &still, e, place.*, 1) orelse return null;
    return .{ world.scale_x, world.scale_y };
}

fn spriteOf(app: *App, e: Entity, collider: Collider2D) [4]f32 {
    const wanted = switch (collider.shape) {
        .rectangle => collider.extents.x == 0 or collider.extents.y == 0,
        .circle => collider.radius == 0,
        .capsule => collider.radius == 0 or collider.extents.y == 0,
    };
    if (!wanted) return @splat(0);
    const drawn = app.world.get(e, Sprite) orelse return @splat(0);
    const texture = app.assets.get(drawn.texture) orelse app.assets.get(app.assets.white) orelse return @splat(0);
    return sprite.spriteBox(drawn.*, texture);
}

fn reshape(self: *Bodies, app: *App, link: *ShapeLink, e: Entity, body: BodyId, inputs: Inputs) !void {
    if (!link.entity.isNone()) try self.take(app, link.shape, link.entity);
    link.* = .{ .entity = e, .body = body, .made_from = inputs };
    const def = shapeOf(inputs, e) orelse {
        log.warn("the collider on {f} makes no shape: it has no size and no sprite to take one from, or a number in it is not finite", .{e});
        return;
    };
    link.shape = try app.physics.addShape(body, def);
}

fn shapeOf(inputs: Inputs, e: Entity) ?physics.Shape {
    const c = inputs.collider;
    const place = inputs.place;
    var offset: [2]f32 = .{ c.offset.x, c.offset.y };
    const geometry: physics.shape.Geometry = switch (c.shape) {
        .rectangle => blk: {
            if (c.extents.x == 0 or c.extents.y == 0) {
                offset[0] += inputs.sprite[2];
                offset[1] += inputs.sprite[3];
            }
            const half_width = @abs(if (c.extents.x != 0) c.extents.x * place.scale_x else inputs.sprite[0] * place.scale_x / 2);
            const half_height = @abs(if (c.extents.y != 0) c.extents.y * place.scale_y else inputs.sprite[1] * place.scale_y / 2);
            const centre = centreOf(place, offset);
            const turn = place.rotation + c.rotation;
            if (!(half_width > least_size and half_height > least_size)) return null;
            if (!finite(&.{ half_width, half_height, centre.x, centre.y, turn })) return null;
            break :blk .{ .polygon = .offsetBox(half_width, half_height, centre, turn) };
        },
        .circle => blk: {
            if (c.radius == 0) {
                offset[0] += inputs.sprite[2];
                offset[1] += inputs.sprite[3];
            }
            const radius = @abs(if (c.radius != 0) c.radius else inputs.sprite[0] / 2) *
                @max(@abs(place.scale_x), @abs(place.scale_y));
            const centre = centreOf(place, offset);
            if (!(radius > least_size) or !finite(&.{ radius, centre.x, centre.y })) return null;
            break :blk .{ .circle = .{ .center = centre, .radius = radius } };
        },
        .capsule => blk: {
            if (c.radius == 0 or c.extents.y == 0) {
                offset[0] += inputs.sprite[2];
                offset[1] += inputs.sprite[3];
            }
            const radius = @abs(if (c.radius != 0) c.radius else inputs.sprite[0] / 2) * @abs(place.scale_x);
            const half_height = @abs(if (c.extents.y != 0) c.extents.y else inputs.sprite[1] / 2) * @abs(place.scale_y);
            const centre = centreOf(place, offset);
            const turn = place.rotation + c.rotation;
            if (!(radius > least_size) or !finite(&.{ radius, half_height, centre.x, centre.y, turn })) return null;
            // From the middle to each end's centre, along the entity's `y`.
            const reach = half_height - radius;
            // No longer than it is round: a circle.
            if (!(reach > least_size)) break :blk .{ .circle = .{ .center = centre, .radius = radius } };
            const along: Vec2 = .init(-@sin(turn) * reach, @cos(turn) * reach);
            break :blk .{ .capsule = .{ .center1 = centre.sub(along), .center2 = centre.add(along), .radius = radius } };
        },
    };
    return .{
        .geometry = geometry,
        .material = .{ .friction = c.friction, .restitution = c.bounce, .density = c.density },
        .filter = .{ .category = c.collision_layer, .mask = c.collision_mask },
        .sensor = c.sensor,
        // The entity's `+y`, down the screen, turned and flipped into the
        // body's frame: the way something is held going.
        .one_way = if (c.one_way_collision) .{ .direction = downOf(place, c.rotation) } else null,
        .user_data = e.toInt(),
    };
}

/// Where a collider's own `+y` points in its body's frame.
fn downOf(place: Pose, rotation: f32) Vec2 {
    const turn = place.rotation + rotation;
    const flip: f32 = if (place.scale_y < 0) -1 else 1;
    return .init(-@sin(turn) * flip, @cos(turn) * flip);
}

/// Whether every one of these is a number, and not an infinity. A shape made
/// of a NaN - a scene edited by hand, a component written wrong - has no area
/// the physics can divide by, and it stops there; it gets no shape instead.
fn finite(values: []const f32) bool {
    for (values) |value| {
        if (!std.math.isFinite(value)) return false;
    }
    return true;
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
    // An exception naming an entity that is gone goes too: its body, and
    // what the physics held of it, went with it.
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
        was.scale_x != now.scale_x or was.scale_y != now.scale_y or
        was.inherit_rotation != now.inherit_rotation or was.inherit_scale != now.inherit_scale;
}

/// Where a body goes, or null when it cannot be placed - its chain is broken,
/// or a number on the way is not finite, and a body there would be NaN from
/// its first step.
fn placed(app: *App, e: Entity, place: Transform2D) ?Pose {
    const at: Pose = .of(hierarchy.resolve(&app.world, &still, e, place, 1) orelse return null);
    return if (finite(&.{ at.x, at.y, at.rotation, at.scale_x, at.scale_y })) at else null;
}

/// Write each moving body's place and speed into its components, and hear
/// what began and stopped touching.
pub fn afterStep(self: *Bodies, app: *App) !void {
    for (self.moving.items) |index| {
        const link = &self.bodies.items[index];
        const body = app.physics.bodyConst(link.body) orelse continue;
        const place = app.world.get(link.entity, Transform2D) orelse continue;
        const local = localPose(app, link.entity, place.*, body) orelse continue;
        place.x = local.x;
        place.y = local.y;
        place.rotation = local.rotation;
        link.transform = place.*;
        link.placed.x = body.position().x;
        link.placed.y = body.position().y;
        link.placed.rotation = body.angle;
        if (app.world.get(link.entity, RigidBody2D)) |written| {
            written.linear_velocity = body.linear_velocity;
            written.angular_velocity = body.angular_velocity;
            link.rigid = written.*;
        }
    }
    try self.hear(app);
}

/// A body's place in its entity's parent's space.
fn localPose(app: *App, e: Entity, place: Transform2D, body: *const physics.Body) ?Pose {
    const at = body.position();
    const above = hierarchy.parentOf(&app.world, e);
    const parent_local = app.world.get(above, Transform2D) orelse {
        if (!above.isNone() and !app.world.isAlive(above)) return null;
        return .{ .x = at.x, .y = at.y, .rotation = body.angle };
    };
    const parent = hierarchy.resolve(&app.world, &still, above, parent_local.*, 1) orelse return null;
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
    // A chunk's body is kept by its entity, and a fresh world hands those
    // entities out again: left here, an old body would be taken for the new
    // world's.
    var tiles = self.tile_bodies.valueIterator();
    while (tiles.next()) |held| app.physics.destroyBody(held.body);
    self.tile_bodies.clearRetainingCapacity();
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

/// The box round an entity's collider in the world, as the physics holds
/// it: turned, scaled, and sized from a sprite as the shape was made. Null
/// for an entity with no shape.
pub fn boundsOf(self: *const Bodies, app: *App, e: Entity) ?physics.Aabb {
    if (e.index >= self.shapes.items.len) return null;
    const link = self.shapes.items[e.index];
    if (!link.entity.eql(e)) return null;
    const entry = app.physics.shape(link.shape) orelse return null;
    return entry.def.geometry.aabb(app.physics.shapeTransform(entry));
}

/// The collider a shape is, or null for one the engine did not make.
pub fn entityOf(self: *const Bodies, app: *App, shape: ShapeId) ?Entity {
    if (app.physics.shape(shape)) |entry| {
        const e: Entity = .fromInt(entry.def.user_data);
        if (app.world.has(e, tilemap.TileMap)) return e;
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

pub fn castRay(self: *const Bodies, app: *App, from: Vec2, to: Vec2, options: physics.RayOptions) ?RayHit {
    const hit = app.physics.castRay(from, to.sub(from), options) orelse return null;
    const shape = self.entityOf(app, hit.shape) orelse Entity.none;
    return .{
        .collider = if (shape.isNone()) .none else objectOf(&app.world, shape) orelse shape,
        .shape = shape,
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
