// SPDX-License-Identifier: BSD-3-Clause

//! Where a thing really is, once its parent has had its say.
//!
//! A `Transform2D` - or a `Transform3D` - is local: in its `Parent`'s space.
//! The two are walked the same way, each through parents of its own kind.
//! Nothing is cached - a
//! parented entity's world transform is worked out where it is wanted, by
//! walking up to a root - so there is no second component to move every
//! transform into another archetype. Each link is interpolated in its own
//! space before composing, so the children of a body stepped in `.fixed`
//! slide as smoothly as it does.
//!
//! A chain with a dead link cannot be placed: this says null, and `App`
//! despawns what hung from it at the end of the frame.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const components = @import("components.zig");

const Allocator = std.mem.Allocator;
const Transform2D = components.Transform2D;
const Transform3D = @import("transform3d.zig").Transform3D;
const Parent = components.Parent;
const Entity = ecs.Entity;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Quat = math.Quat;

/// What an entity hangs from, `.none` for a root.
pub fn parentOf(world: *const ecs.World, entity: Entity) Entity {
    const held = world.getConst(entity, Parent) orelse return .none;
    return held.entity;
}

/// Where a transform was before the last fixed step. Kept by `App` beside the
/// world; see `Transform2D.interpolate`.
pub const Snapshot = struct {
    x: f32,
    y: f32,
    rotation: f32,
    scale_x: f32,
    scale_y: f32,

    pub fn of(transform: Transform2D) Snapshot {
        return .{
            .x = transform.x,
            .y = transform.y,
            .rotation = transform.rotation,
            .scale_x = transform.scale_x,
            .scale_y = transform.scale_y,
        };
    }

    /// Somewhere between here and `now`, at `t` from zero to one. Rotation is
    /// blended as a plain number, so more than half a turn in one step goes
    /// the long way round.
    pub fn blend(self: Snapshot, now: Transform2D, t: f32) Transform2D {
        var out = now;
        out.x = std.math.lerp(self.x, now.x, t);
        out.y = std.math.lerp(self.y, now.y, t);
        out.rotation = std.math.lerp(self.rotation, now.rotation, t);
        out.scale_x = std.math.lerp(self.scale_x, now.scale_x, t);
        out.scale_y = std.math.lerp(self.scale_y, now.scale_y, t);
        return out;
    }
};

/// Where a transform of type `T` was before the last fixed step.
pub fn SnapshotOf(comptime T: type) type {
    return if (T == Transform2D) Snapshot else T.Snapshot;
}

/// Every entity with a transform of type `T` that asked to be drawn
/// between steps, and where it was.
pub fn SnapshotsOf(comptime T: type) type {
    return std.AutoHashMapUnmanaged(Entity, SnapshotOf(T));
}

pub const Snapshots = SnapshotsOf(Transform2D);
pub const Snapshots3D = SnapshotsOf(Transform3D);

/// One transform, blended against its snapshot if it asked for that.
pub fn stepped(snapshots: *const Snapshots, entity: Entity, local: Transform2D, alpha: f32) Transform2D {
    return steppedAs(Transform2D, snapshots, entity, local, alpha);
}

pub fn steppedAs(comptime T: type, snapshots: *const SnapshotsOf(T), entity: Entity, local: T, alpha: f32) T {
    if (!local.interpolate) return local;
    const previous = snapshots.get(entity) orelse return local;
    return previous.blend(local, alpha);
}

/// Where an entity's transform ends up once every parent above it has been
/// applied: in world space. `local` is the entity's own transform, which the
/// caller may hold a copy of.
///
/// The chain ends at a root, or at a living parent with no `Transform2D`.
/// Null when a link has died, or when the chain is deeper than
/// `Transform2D.max_depth` - in practice, a cycle.
pub fn resolve(
    world: *ecs.World,
    snapshots: *const Snapshots,
    entity: Entity,
    local: Transform2D,
    alpha: f32,
) ?Transform2D {
    return resolveAs(Transform2D, world, snapshots, entity, local, alpha);
}

/// `resolve` for a transform of either kind: the chain goes up through
/// parents with a transform of the same kind.
pub fn resolveAs(
    comptime T: type,
    world: *ecs.World,
    snapshots: *const SnapshotsOf(T),
    entity: Entity,
    local: T,
    alpha: f32,
) ?T {
    var above = parentOf(world, entity);
    if (above.isNone()) return steppedAs(T, snapshots, entity, local, alpha);

    // Nearest first. A fixed array, so nothing allocates inside a frame.
    var chain: [T.max_depth]T = undefined;
    chain[0] = steppedAs(T, snapshots, entity, local, alpha);
    var depth: usize = 1;

    while (!above.isNone()) {
        const parent_local = world.get(above, T) orelse {
            // Dead: the chain is broken. See `tree.despawnOrphans`.
            if (!world.isAlive(above)) return null;
            // Alive with no transform: the chain stops here.
            break;
        };

        if (depth == chain.len) return null;
        chain[depth] = steppedAs(T, snapshots, above, parent_local.*, alpha);
        depth += 1;
        above = parentOf(world, above);
    }

    // Composed back down from the root, whose numbers are already the world's.
    var placed = chain[depth - 1];
    var at = depth - 1;
    while (at > 0) {
        at -= 1;
        placed = T.compose(placed, chain[at]);
    }
    return placed;
}

/// `resolve`, for an entity whose transform the caller has not got.
pub fn resolveEntity(
    world: *ecs.World,
    snapshots: *const Snapshots,
    entity: Entity,
    alpha: f32,
) ?Transform2D {
    const local = world.get(entity, Transform2D) orelse return null;
    return resolve(world, snapshots, entity, local.*, alpha);
}

/// Resolving against no snapshots is resolving where things are, not where
/// they are drawn.
const still: Snapshots = .empty;

/// Where an entity really is, with every parent above it applied. Null
/// when it has no transform, or when something it hangs from was despawned
/// this frame. The result has no parent, so writing
/// it over the entity's own transform lets go while keeping it in place.
///
/// Where it is, not where it is drawn: an entity that `interpolate`s is drawn
/// between its last two fixed steps, which `drawnTransform` says.
pub fn worldTransform(world: *ecs.World, entity: Entity) ?Transform2D {
    return resolveEntity(world, &still, entity, 1);
}

/// What a call that writes where an entity is can fail with.
pub const PlaceError = error{
    /// It has no `Transform2D` to write.
    NoTransform,
    /// Something above it cannot be placed: a parent despawned this frame,
    /// or a chain deeper than `Transform2D.max_depth`.
    Unplaced,
};

/// Put an entity where `placed` says in the world, and keep its parent: its
/// own transform becomes the one that, under its parents, lands there. Its
/// parent, its inherit switches and its `interpolate` stay its own;
/// `placed`'s are not read.
pub fn setWorldTransform(world: *ecs.World, entity: Entity, placed: Transform2D) PlaceError!void {
    const above = try parentPlace(world, entity);
    const own = world.get(entity, Transform2D) orelse return error.NoTransform;
    const at = above.unapply(placed.x, placed.y);
    own.x = at.x;
    own.y = at.y;
    own.rotation = if (own.inherit_rotation) placed.rotation - above.rotation else placed.rotation;
    own.scale_x = if (own.inherit_scale) placed.scale_x / nonZero(above.scale_x) else placed.scale_x;
    own.scale_y = if (own.inherit_scale) placed.scale_y / nonZero(above.scale_y) else placed.scale_y;
}

/// Where an entity's parent is in the world: nothing at all for none, or
/// for a living parent with no transform of its own, which places nothing.
fn parentPlace(world: *ecs.World, entity: Entity) PlaceError!Transform2D {
    const above = parentOf(world, entity);
    if (above.isNone()) return .{};
    if (world.get(above, Transform2D) == null and world.isAlive(above)) return .{};
    return worldTransform(world, above) orelse error.Unplaced;
}

/// A scale of zero is left out rather than divided by, as `unapply` does.
fn nonZero(scale: f32) f32 {
    return if (scale != 0) scale else 1;
}

/// The world transform of an entity to write, or why there is none.
fn placeOf(world: *ecs.World, entity: Entity) PlaceError!Transform2D {
    if (!world.has(entity, Transform2D)) return error.NoTransform;
    return worldTransform(world, entity) orelse error.Unplaced;
}

/// Where an entity is in the world.
pub fn globalPosition(world: *ecs.World, entity: Entity) ?Vec2 {
    const placed = worldTransform(world, entity) orelse return null;
    return .init(placed.x, placed.y);
}

pub fn setGlobalPosition(world: *ecs.World, entity: Entity, position: Vec2) PlaceError!void {
    var placed = try placeOf(world, entity);
    placed.x = position.x;
    placed.y = position.y;
    try setWorldTransform(world, entity, placed);
}

/// Which way an entity faces in the world, in radians.
pub fn globalRotation(world: *ecs.World, entity: Entity) ?f32 {
    const placed = worldTransform(world, entity) orelse return null;
    return placed.rotation;
}

pub fn setGlobalRotation(world: *ecs.World, entity: Entity, radians: f32) PlaceError!void {
    var placed = try placeOf(world, entity);
    placed.rotation = radians;
    try setWorldTransform(world, entity, placed);
}

/// How big an entity is in the world.
pub fn globalScale(world: *ecs.World, entity: Entity) ?Vec2 {
    const placed = worldTransform(world, entity) orelse return null;
    return .init(placed.scale_x, placed.scale_y);
}

pub fn setGlobalScale(world: *ecs.World, entity: Entity, scale: Vec2) PlaceError!void {
    var placed = try placeOf(world, entity);
    placed.scale_x = scale.x;
    placed.scale_y = scale.y;
    try setWorldTransform(world, entity, placed);
}

/// Move an entity by `offset` in the world, whatever its parents have done
/// to its axes.
pub fn globalTranslate(world: *ecs.World, entity: Entity, offset: Vec2) PlaceError!void {
    const placed = try placeOf(world, entity);
    try setGlobalPosition(world, entity, .init(placed.x + offset.x, placed.y + offset.y));
}

/// A point in the world, in an entity's own space.
pub fn toLocal(world: *ecs.World, entity: Entity, global_point: Vec2) ?Vec2 {
    const placed = worldTransform(world, entity) orelse return null;
    const local = placed.unapply(global_point.x, global_point.y);
    return .init(local.x, local.y);
}

/// A point in an entity's own space, in the world.
pub fn toGlobal(world: *ecs.World, entity: Entity, local_point: Vec2) ?Vec2 {
    const placed = worldTransform(world, entity) orelse return null;
    const global = placed.apply(local_point.x, local_point.y);
    return .init(global.x, global.y);
}

/// How far an entity would turn to face a point with its `+x`, in radians,
/// measured in its own space and scale.
pub fn getAngleTo(world: *ecs.World, entity: Entity, point: Vec2) ?f32 {
    const local = toLocal(world, entity, point) orelse return null;
    const own = world.get(entity, Transform2D).?;
    return std.math.atan2(local.y * own.scale_y, local.x * own.scale_x);
}

/// Turn an entity so that its `+x` faces a point in the world.
pub fn lookAt(world: *ecs.World, entity: Entity, point: Vec2) PlaceError!void {
    const angle = getAngleTo(world, entity, point) orelse return if (world.has(entity, Transform2D)) error.Unplaced else error.NoTransform;
    world.get(entity, Transform2D).?.rotation += angle;
}

/// Where an entity is in the space of `ancestor`, something it hangs from.
/// Nothing moved for the entity itself, and null for an entity `ancestor`
/// is not above.
pub fn getTransformRelativeTo(world: *ecs.World, entity: Entity, ancestor: Entity) ?Transform2D {
    var chain: [Transform2D.max_depth]Transform2D = undefined;
    var depth: usize = 0;
    var at = entity;
    while (!at.eql(ancestor)) {
        if (depth == chain.len) return null;
        const own = world.get(at, Transform2D) orelse return null;
        const above = parentOf(world, at);
        if (above.isNone()) return null;
        chain[depth] = own.*;
        depth += 1;
        at = above;
    }
    var placed: Transform2D = .{};
    while (depth > 0) {
        depth -= 1;
        placed = Transform2D.compose(placed, chain[depth]);
    }
    return placed;
}

/// Move an entity along its own `+x`, in its parent's space. By `delta`
/// units, or with `scaled` by `delta` of its own scaled lengths.
pub fn moveLocalX(world: *ecs.World, entity: Entity, delta: f32, scaled: bool) PlaceError!void {
    const own = world.get(entity, Transform2D) orelse return error.NoTransform;
    moveAlong(own, .init(@cos(own.rotation) * own.scale_x, @sin(own.rotation) * own.scale_x), delta, scaled);
}

/// The same along its own `+y`.
pub fn moveLocalY(world: *ecs.World, entity: Entity, delta: f32, scaled: bool) PlaceError!void {
    const own = world.get(entity, Transform2D) orelse return error.NoTransform;
    moveAlong(own, .init(-@sin(own.rotation) * own.scale_y, @cos(own.rotation) * own.scale_y), delta, scaled);
}

fn moveAlong(own: *Transform2D, axis: Vec2, delta: f32, scaled: bool) void {
    const along = if (scaled) axis else axis.norm();
    own.x += along.x * delta;
    own.y += along.y * delta;
}

/// Turn an entity by `radians` more.
pub fn rotate(world: *ecs.World, entity: Entity, radians: f32) PlaceError!void {
    const own = world.get(entity, Transform2D) orelse return error.NoTransform;
    own.rotation += radians;
}

/// Multiply an entity's scale by `ratio`.
pub fn applyScale(world: *ecs.World, entity: Entity, ratio: Vec2) PlaceError!void {
    const own = world.get(entity, Transform2D) orelse return error.NoTransform;
    own.scale_x *= ratio.x;
    own.scale_y *= ratio.y;
}

/// Whether `entity` hangs from `ancestor`, however far down.
pub fn isDescendantOf(world: *const ecs.World, entity: Entity, ancestor: Entity) bool {
    var at = parentOf(world, entity);
    var depth: usize = 0;
    while (!at.isNone() and depth < 256) : (depth += 1) {
        if (at.eql(ancestor)) return true;
        at = parentOf(world, at);
    }
    return false;
}

/// Remember where every interpolating transform is, before a step moves it.
/// Refilled rather than added to, so the dead drop out; the capacity stays.
pub fn snapshot(gpa: Allocator, world: *ecs.World, snapshots: *Snapshots) !void {
    snapshots.clearRetainingCapacity();

    var it = try ecs.Query(.{Transform2D}).over(world);
    while (it.next()) |chunk| {
        for (chunk.slice(Transform2D), chunk.entities) |current, entity| {
            if (!current.interpolate) continue;
            try snapshots.put(gpa, entity, .of(current));
        }
    }
}

// -------------------------------------------------------------------------
// In 3D
// -------------------------------------------------------------------------

/// `resolve`, for a `Transform3D`.
pub fn resolve3D(
    world: *ecs.World,
    snapshots: *const Snapshots3D,
    entity: Entity,
    local: Transform3D,
    alpha: f32,
) ?Transform3D {
    return resolveAs(Transform3D, world, snapshots, entity, local, alpha);
}

/// `resolve3D`, for an entity whose transform the caller has not got.
pub fn resolveEntity3D(world: *ecs.World, snapshots: *const Snapshots3D, entity: Entity, alpha: f32) ?Transform3D {
    const local = world.get(entity, Transform3D) orelse return null;
    return resolve3D(world, snapshots, entity, local.*, alpha);
}

const still3d: Snapshots3D = .empty;

/// Where an entity really is in 3D, with every parent above it applied:
/// `worldTransform`, for a `Transform3D`.
pub fn worldTransform3D(world: *ecs.World, entity: Entity) ?Transform3D {
    return resolveEntity3D(world, &still3d, entity, 1);
}

/// Put an entity where `placed` says in the 3D world, and keep its parent:
/// `setWorldTransform`, for a `Transform3D`.
pub fn setWorldTransform3D(world: *ecs.World, entity: Entity, placed: Transform3D) PlaceError!void {
    const above = try parentPlace3D(world, entity);
    const own = world.get(entity, Transform3D) orelse return error.NoTransform;
    own.position = above.unapply(placed.position);
    own.rotation = if (own.inherit_rotation) .of(above.rotation.quat().conj().mul(placed.rotation.quat()).norm()) else placed.rotation;
    own.scale = if (own.inherit_scale) .init(
        placed.scale.x / nonZero(above.scale.x),
        placed.scale.y / nonZero(above.scale.y),
        placed.scale.z / nonZero(above.scale.z),
    ) else placed.scale;
}

fn parentPlace3D(world: *ecs.World, entity: Entity) PlaceError!Transform3D {
    const above = parentOf(world, entity);
    if (above.isNone()) return .{};
    if (world.get(above, Transform3D) == null and world.isAlive(above)) return .{};
    return worldTransform3D(world, above) orelse error.Unplaced;
}

fn placeOf3D(world: *ecs.World, entity: Entity) PlaceError!Transform3D {
    if (!world.has(entity, Transform3D)) return error.NoTransform;
    return worldTransform3D(world, entity) orelse error.Unplaced;
}

/// Where an entity is in the 3D world.
pub fn globalPosition3D(world: *ecs.World, entity: Entity) ?Vec3 {
    const placed = worldTransform3D(world, entity) orelse return null;
    return placed.position;
}

pub fn setGlobalPosition3D(world: *ecs.World, entity: Entity, position: Vec3) PlaceError!void {
    var placed = try placeOf3D(world, entity);
    placed.position = position;
    try setWorldTransform3D(world, entity, placed);
}

/// Which way an entity faces in the 3D world.
pub fn globalRotation3D(world: *ecs.World, entity: Entity) ?Quat {
    const placed = worldTransform3D(world, entity) orelse return null;
    return placed.rotation.quat();
}

pub fn setGlobalRotation3D(world: *ecs.World, entity: Entity, rotation: Quat) PlaceError!void {
    var placed = try placeOf3D(world, entity);
    placed.rotation = .of(rotation);
    try setWorldTransform3D(world, entity, placed);
}

/// How big an entity is in the 3D world.
pub fn globalScale3D(world: *ecs.World, entity: Entity) ?Vec3 {
    const placed = worldTransform3D(world, entity) orelse return null;
    return placed.scale;
}

pub fn setGlobalScale3D(world: *ecs.World, entity: Entity, scale: Vec3) PlaceError!void {
    var placed = try placeOf3D(world, entity);
    placed.scale = scale;
    try setWorldTransform3D(world, entity, placed);
}

/// Move an entity by `offset` in the 3D world.
pub fn globalTranslate3D(world: *ecs.World, entity: Entity, offset: Vec3) PlaceError!void {
    const placed = try placeOf3D(world, entity);
    try setGlobalPosition3D(world, entity, placed.position.add(offset));
}

/// A point in the 3D world, in an entity's own space.
pub fn toLocal3D(world: *ecs.World, entity: Entity, global_point: Vec3) ?Vec3 {
    const placed = worldTransform3D(world, entity) orelse return null;
    return placed.unapply(global_point);
}

/// A point in an entity's own space, in the 3D world.
pub fn toGlobal3D(world: *ecs.World, entity: Entity, local_point: Vec3) ?Vec3 {
    const placed = worldTransform3D(world, entity) orelse return null;
    return placed.apply(local_point);
}

/// Which way one of an entity's own directions points in the 3D world,
/// scaled to a length of one: its `-z` is where it faces.
pub fn globalDirection3D(world: *ecs.World, entity: Entity, local_direction: Vec3) ?Vec3 {
    const placed = worldTransform3D(world, entity) orelse return null;
    return placed.rotation.quat().rotate(local_direction).tryNorm() orelse local_direction;
}

/// Turn an entity so that its `-z` faces a point in the 3D world, with its
/// `+y` as near `up` as it can be.
pub fn lookAt3D(world: *ecs.World, entity: Entity, target: Vec3, up: Vec3) PlaceError!void {
    var placed = try placeOf3D(world, entity);
    placed.lookAt(target, up);
    try setWorldTransform3D(world, entity, placed);
}

/// Remember where every interpolating 3D transform is, before a step moves
/// it: `snapshot`, in 3D.
pub fn snapshot3D(gpa: Allocator, world: *ecs.World, snapshots: *Snapshots3D) !void {
    snapshots.clearRetainingCapacity();
    var it = try ecs.Query(.{Transform3D}).over(world);
    while (it.next()) |chunk| {
        for (chunk.slice(Transform3D), chunk.entities) |current, entity| {
            if (!current.interpolate) continue;
            try snapshots.put(gpa, entity, .of(current));
        }
    }
}

test "an unparented transform is already the world one" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var snapshots: Snapshots = .empty;
    defer snapshots.deinit(testing.allocator);

    const lonely = try world.spawnWith(.{Transform2D.at(10, 20)});
    const placed = resolveEntity(&world, &snapshots, lonely, 1).?;

    try testing.expectEqual(@as(f32, 10), placed.x);
    try testing.expectEqual(@as(f32, 20), placed.y);
}

test "a child is composed through its parent" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var snapshots: Snapshots = .empty;
    defer snapshots.deinit(testing.allocator);

    const body = try world.spawnWith(.{Transform2D{
        .x = 100,
        .y = 100,
        .rotation = std.math.pi / 2.0,
    }});
    const held = try world.spawnWith(.{ Transform2D.at(10, 0), Parent.of(body) });

    // A quarter turn takes the offset from +x to +y.
    const placed = resolveEntity(&world, &snapshots, held, 1).?;
    try testing.expectApproxEqAbs(@as(f32, 100), placed.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 110), placed.y, 0.0001);
}

test "a chain of three composes in one pass" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var snapshots: Snapshots = .empty;
    defer snapshots.deinit(testing.allocator);

    const root = try world.spawnWith(.{Transform2D.at(10, 0)});
    const middle = try world.spawnWith(.{ Transform2D.at(5, 0), Parent.of(root) });
    const leaf = try world.spawnWith(.{ Transform2D.at(2, 0), Parent.of(middle) });

    try testing.expectApproxEqAbs(
        @as(f32, 17),
        resolveEntity(&world, &snapshots, leaf, 1).?.x,
        0.0001,
    );
}

test "a parent that died leaves the chain unresolvable" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var snapshots: Snapshots = .empty;
    defer snapshots.deinit(testing.allocator);

    const carrier = try world.spawnWith(.{Transform2D.at(60, 60)});
    const held = try world.spawnWith(.{ Transform2D.at(4, 0), Parent.of(carrier) });

    world.despawn(carrier);
    try testing.expect(resolveEntity(&world, &snapshots, held, 1) == null);
}

test "a parent with no transform is the end of the chain, not a break in it" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var snapshots: Snapshots = .empty;
    defer snapshots.deinit(testing.allocator);

    const owner = try world.spawn();
    const arm = try world.spawnWith(.{ Transform2D.at(100, 0), Parent.of(owner) });
    const hand = try world.spawnWith(.{ Transform2D.at(5, 0), Parent.of(arm) });

    const placed = resolveEntity(&world, &snapshots, hand, 1).?;
    try testing.expectApproxEqAbs(@as(f32, 105), placed.x, 0.0001);
}

test "a chain that loops back on itself cannot be placed" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var snapshots: Snapshots = .empty;
    defer snapshots.deinit(testing.allocator);

    const a = try world.spawnWith(.{Transform2D.at(1, 0)});
    const b = try world.spawnWith(.{ Transform2D.at(1, 0), Parent.of(a) });
    try world.add(a, Parent.of(b));

    try testing.expect(resolveEntity(&world, &snapshots, a, 1) == null);
}

test "an entity is drawn between its last two steps" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var snapshots: Snapshots = .empty;
    defer snapshots.deinit(testing.allocator);

    var moving: Transform2D = .at(10, 0);
    moving.interpolate = true;
    const runner = try world.spawnWith(.{moving});

    try snapshots.put(testing.allocator, runner, .of(.at(0, 0)));

    const halfway = resolveEntity(&world, &snapshots, runner, 0.5).?;
    try testing.expectApproxEqAbs(@as(f32, 5), halfway.x, 0.0001);
}

test "a transform that did not ask is not interpolated" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var snapshots: Snapshots = .empty;
    defer snapshots.deinit(testing.allocator);

    const runner = try world.spawnWith(.{Transform2D.at(10, 0)});
    try snapshots.put(testing.allocator, runner, .of(.at(0, 0)));

    try testing.expectEqual(
        @as(f32, 10),
        resolveEntity(&world, &snapshots, runner, 0.5).?.x,
    );
}

test "a 3D child is placed through its 3D parent, and placed back where asked" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();

    var turned: Transform3D = .at(10, 0, 0);
    turned.rotation = .of(Quat.fromAxisAngle(.unit_y, std.math.pi / 2.0));
    const parent = try world.spawnWith(.{turned});
    const child = try world.spawnWith(.{ Transform3D.at(0, 0, -2), Parent.of(parent) });

    // A quarter turn about +y takes the child's -z offset to -x.
    const at = globalPosition3D(&world, child).?;
    try testing.expectApproxEqAbs(@as(f32, 8), at.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), at.z, 1e-5);

    try setGlobalPosition3D(&world, child, .init(10, 5, 0));
    const now = globalPosition3D(&world, child).?;
    try testing.expectApproxEqAbs(@as(f32, 10), now.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 5), now.y, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), now.z, 1e-5);

    // Facing a point in the world, whatever the parent's turn.
    try lookAt3D(&world, child, .init(10, 5, -10), .unit_y);
    const facing = globalDirection3D(&world, child, .init(0, 0, -1)).?;
    try testing.expectApproxEqAbs(@as(f32, -1), facing.z, 1e-4);
}

test "a 3D transform under a 2D one, or under none, is its own root" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    const flat = try world.spawnWith(.{Transform2D.at(100, 100)});
    const solid = try world.spawnWith(.{ Transform3D.at(1, 2, 3), Parent.of(flat) });
    const at = globalPosition3D(&world, solid).?;
    try testing.expectEqual(@as(f32, 1), at.x);
    try testing.expectEqual(@as(f32, 3), at.z);
}

test "a 3D entity is drawn between its last two steps" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var snapshots: Snapshots3D = .empty;
    defer snapshots.deinit(testing.allocator);

    const runner = try world.spawnWith(.{Transform3D.at(0, 0, 0).interpolated()});
    try snapshot3D(testing.allocator, &world, &snapshots);
    world.get(runner, Transform3D).?.position = .init(0, 0, 10);
    try testing.expectApproxEqAbs(@as(f32, 5), resolveEntity3D(&world, &snapshots, runner, 0.5).?.position.z, 1e-5);
}
