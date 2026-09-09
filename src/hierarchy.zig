// SPDX-License-Identifier: BSD-3-Clause

//! Where a thing really is, once its parent has had its say.
//!
//! A `Transform2D` is **local**: its numbers are in its parent's space, and
//! in the world's only when it has no parent. That is Unity's `Transform`
//! and Godot's `Node2D` - `position` against `global_position` - and it is
//! what people expect, because moving a turret by one is moving it one along
//! the tank rather than one along the world.
//!
//! Something has to turn the one into the other, and this is it.
//!
//! **Nothing is cached.** The world transform of a parented entity is worked
//! out where it is wanted, by walking up to a root and composing back down.
//! The alternative - a second, derived component holding the world value -
//! is what Bevy does, and in an archetype world it means every entity with a
//! transform is moved into a different table to make room for it, and every
//! system that spawns one pays for the move. Walking costs one lookup per
//! link, and only for entities that have a parent at all: a flat scene pays
//! a single comparison against `.none`.
//!
//! **Interpolation happens before composing**, so a child of a body moved in
//! the `.fixed` stage slides as smoothly as the body does. Both are blended
//! in their own space and then put together, which is the only order that
//! does not make a rotating parent drag its children round in steps.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const components = @import("components.zig");

const Transform2D = components.Transform2D;
const Entity = ecs.Entity;

/// Where a transform was before the last fixed step.
///
/// Kept by the `App` in a table beside the world rather than in a component,
/// because it is the engine's own bookkeeping and not something a game
/// declares. See `Transform2D.interpolate`.
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

    /// Somewhere between here and `now`, at `t` from zero to one.
    ///
    /// The rotation is blended as a plain number, so a thing that turns more
    /// than half a circle in one step is drawn going the long way round.
    /// Nothing moving at sixty steps a second turns that fast.
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

/// Every entity that asked to be drawn between steps, and where it was.
pub const Snapshots = std.AutoHashMapUnmanaged(Entity, Snapshot);

/// One transform, blended against its snapshot if it asked for that.
pub fn stepped(snapshots: *const Snapshots, entity: Entity, local: Transform2D, alpha: f32) Transform2D {
    if (!local.interpolate) return local;
    const previous = snapshots.get(entity) orelse return local;
    return previous.blend(local, alpha);
}

/// Where an entity's transform ends up once every parent above it has been
/// applied.
///
/// Null when a link in the chain leads nowhere - a parent that has died, or
/// one with no transform - which leaves the caller to decide. The renderer
/// draws such a thing at its local position, which is where it was before
/// whatever it was attached to went away.
pub fn resolve(
    world: *ecs.World,
    snapshots: *const Snapshots,
    entity: Entity,
    local: Transform2D,
    alpha: f32,
) ?Transform2D {
    if (local.parent.isNone()) return stepped(snapshots, entity, local, alpha);

    // The chain from this entity up to a root, nearest first. A fixed array
    // rather than a list, because `max_depth` is the point at which a chain
    // is a mistake and this must not allocate inside a frame.
    var chain: [Transform2D.max_depth]Transform2D = undefined;
    var depth: usize = 0;

    var current_entity = entity;
    var current = stepped(snapshots, entity, local, alpha);

    while (depth < chain.len) {
        chain[depth] = current;
        depth += 1;

        const above = current.parent;
        if (above.isNone()) {
            // A root: its own transform is already the world one, and the
            // chain is composed back down from it.
            var placed = chain[depth - 1];
            while (depth > 1) {
                depth -= 1;
                placed = Transform2D.compose(placed, chain[depth - 1]);
            }
            return placed;
        }

        const parent_local = world.get(above, Transform2D) orelse return null;
        current_entity = above;
        current = stepped(snapshots, current_entity, parent_local.*, alpha);
    }

    // Deeper than anyone means to nest, which in practice means a cycle.
    return null;
}

/// The same, for an entity whose transform the caller has not already got.
pub fn resolveEntity(
    world: *ecs.World,
    snapshots: *const Snapshots,
    entity: Entity,
    alpha: f32,
) ?Transform2D {
    const local = world.get(entity, Transform2D) orelse return null;
    return resolve(world, snapshots, entity, local.*, alpha);
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
    const held = try world.spawnWith(.{Transform2D.childOf(body, 10, 0)});

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
    const middle = try world.spawnWith(.{Transform2D.childOf(root, 5, 0)});
    const leaf = try world.spawnWith(.{Transform2D.childOf(middle, 2, 0)});

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
    const held = try world.spawnWith(.{Transform2D.childOf(carrier, 4, 0)});

    world.despawn(carrier);
    try testing.expect(resolveEntity(&world, &snapshots, held, 1) == null);
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
