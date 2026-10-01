// SPDX-License-Identifier: BSD-3-Clause

//! What entities are known by from one save and load to the next:
//! `App.setUuid`, `App.findUuid`.
//!
//! Like a name a UUID is the entity's own, kept beside the world, and one
//! living entity has a UUID at a time. A despawned entity's is free at once.
//! A scene gives every entity it writes one, and every entity it reads the
//! one it had. `of_entity` is an array map, so `forgetDead` can walk it by
//! index while removing from it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const Uuid = @import("fluxion_id").Uuid;
const App = @import("../App.zig");

const Entity = ecs.Entity;

/// What `Uuids.set` can refuse.
pub const UuidError = error{
    /// Another living entity has it. A UUID picks out one thing.
    UuidTaken,
    /// All zeroes: what a UUID nobody set looks like, and so not one.
    NilUuid,
    /// The entity has been despawned, or never was.
    NoSuchEntity,
} || Allocator.Error;

pub const Uuids = struct {
    of_entity: std.AutoArrayHashMapUnmanaged(Entity, Uuid) = .empty,
    by_uuid: std.AutoHashMapUnmanaged(Uuid, Entity) = .empty,
    /// What `new` draws from: seeded by the operating system, or with no
    /// `Io` by a constant, so a test makes the same ones every run.
    source: std.Random.DefaultCsprng,

    pub fn init(io: ?std.Io) Uuids {
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = @splat(0x5E);
        if (io) |held| held.random(&seed);
        return .{ .source = .init(seed) };
    }

    pub fn deinit(self: *Uuids, gpa: Allocator) void {
        self.of_entity.deinit(gpa);
        self.by_uuid.deinit(gpa);
    }

    /// Every UUID gone, as a world thrown away takes them.
    pub fn clear(self: *Uuids, _: *App) void {
        self.of_entity.clearRetainingCapacity();
        self.by_uuid.clearRetainingCapacity();
    }

    /// A new random UUID - version 4.
    pub fn new(self: *Uuids) Uuid {
        return .random(self.source.random());
    }

    /// Give an entity this UUID, unless another living one has it.
    pub fn set(self: *Uuids, gpa: Allocator, world: *const ecs.World, entity: Entity, uuid: Uuid) UuidError!void {
        if (!world.isAlive(entity)) return error.NoSuchEntity;
        if (uuid.isNil()) return error.NilUuid;

        var stale: ?Entity = null;
        if (self.by_uuid.get(uuid)) |holder| {
            if (holder.eql(entity)) return;
            if (world.isAlive(holder)) return error.UuidTaken;
            stale = holder;
        }
        // Everything that can fail first, so a refused change changes nothing.
        try self.of_entity.ensureUnusedCapacity(gpa, 1);
        try self.by_uuid.ensureUnusedCapacity(gpa, 1);

        if (stale) |holder| self.forget(holder);
        const slot = self.of_entity.getOrPutAssumeCapacity(entity);
        if (slot.found_existing) _ = self.by_uuid.remove(slot.value_ptr.*);
        slot.value_ptr.* = uuid;
        self.by_uuid.putAssumeCapacityNoClobber(uuid, entity);
    }

    /// An entity's UUID, or null when it has none or is not alive.
    pub fn of(self: *const Uuids, world: *const ecs.World, entity: Entity) ?Uuid {
        if (!world.isAlive(entity)) return null;
        return self.of_entity.get(entity);
    }

    /// An entity's UUID, made for it now if it has none.
    pub fn ensure(self: *Uuids, gpa: Allocator, world: *const ecs.World, entity: Entity) (error{NoSuchEntity} || Allocator.Error)!Uuid {
        if (self.of(world, entity)) |held| return held;
        while (true) {
            const fresh = self.new();
            self.set(gpa, world, entity, fresh) catch |err| switch (err) {
                // A hundred and twenty-two random bits, drawn twice alike.
                error.UuidTaken => continue,
                error.NilUuid => unreachable,
                error.NoSuchEntity, error.OutOfMemory => |e| return e,
            };
            return fresh;
        }
    }

    /// The living entity with this UUID, or null.
    pub fn find(self: *const Uuids, world: *const ecs.World, uuid: Uuid) ?Entity {
        const entity = self.by_uuid.get(uuid) orelse return null;
        return if (world.isAlive(entity)) entity else null;
    }

    fn forget(self: *Uuids, entity: Entity) void {
        const held = self.of_entity.fetchSwapRemove(entity) orelse return;
        _ = self.by_uuid.remove(held.value);
    }

    /// Give back the UUIDs of everything that has died.
    pub fn forgetDead(self: *Uuids, app: *App) void {
        var at = self.of_entity.count();
        while (at > 0) {
            at -= 1;
            const entity = self.of_entity.keys()[at];
            if (!app.world.isAlive(entity)) self.forget(entity);
        }
    }
};
