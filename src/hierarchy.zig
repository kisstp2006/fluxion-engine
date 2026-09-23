// SPDX-License-Identifier: BSD-3-Clause

//! Where a thing really is, once its parent has had its say.
//!
//! A `Transform2D` is local: in its parent's space. Nothing is cached - a
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
const components = @import("components.zig");

const Transform2D = components.Transform2D;
const Entity = ecs.Entity;

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

/// Every entity that asked to be drawn between steps, and where it was.
pub const Snapshots = std.AutoHashMapUnmanaged(Entity, Snapshot);

/// One transform, blended against its snapshot if it asked for that.
pub fn stepped(snapshots: *const Snapshots, entity: Entity, local: Transform2D, alpha: f32) Transform2D {
    if (!local.interpolate) return local;
    const previous = snapshots.get(entity) orelse return local;
    return previous.blend(local, alpha);
}

/// Where an entity's transform ends up once every parent above it has been
/// applied. The result has no parent: it is in world space.
///
/// The chain ends at `.none`, or at a living parent with no `Transform2D`.
/// Null when a link has died, or when the chain is deeper than
/// `Transform2D.max_depth` - in practice, a cycle.
pub fn resolve(
    world: *ecs.World,
    snapshots: *const Snapshots,
    entity: Entity,
    local: Transform2D,
    alpha: f32,
) ?Transform2D {
    if (local.parent.isNone()) return stepped(snapshots, entity, local, alpha);

    // Nearest first. A fixed array, so nothing allocates inside a frame.
    var chain: [Transform2D.max_depth]Transform2D = undefined;
    chain[0] = stepped(snapshots, entity, local, alpha);
    var depth: usize = 1;

    while (true) {
        const above = chain[depth - 1].parent;
        if (above.isNone()) break;

        const parent_local = world.get(above, Transform2D) orelse {
            // Dead: the chain is broken. See `App.despawnOrphans`.
            if (!world.isAlive(above)) return null;
            // Alive with no transform: the chain stops here.
            break;
        };

        if (depth == chain.len) return null;
        chain[depth] = stepped(snapshots, above, parent_local.*, alpha);
        depth += 1;
    }

    // Composed back down from the root, whose numbers are already the world's.
    var placed = chain[depth - 1];
    placed.parent = .none;
    var at = depth - 1;
    while (at > 0) {
        at -= 1;
        placed = Transform2D.compose(placed, chain[at]);
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

test "a parent with no transform is the end of the chain, not a break in it" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var snapshots: Snapshots = .empty;
    defer snapshots.deinit(testing.allocator);

    const owner = try world.spawn();
    const arm = try world.spawnWith(.{Transform2D.childOf(owner, 100, 0)});
    const hand = try world.spawnWith(.{Transform2D.childOf(arm, 5, 0)});

    const placed = resolveEntity(&world, &snapshots, hand, 1).?;
    try testing.expectApproxEqAbs(@as(f32, 105), placed.x, 0.0001);
    try testing.expect(placed.parent.isNone());
}

test "a chain that loops back on itself cannot be placed" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var snapshots: Snapshots = .empty;
    defer snapshots.deinit(testing.allocator);

    const a = try world.spawnWith(.{Transform2D.at(1, 0)});
    const b = try world.spawnWith(.{Transform2D.childOf(a, 1, 0)});
    world.get(a, Transform2D).?.parent = b;

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
