// SPDX-License-Identifier: BSD-3-Clause

//! What an entity takes from what it hangs from: whether it runs while the
//! game is paused, and how it shows.
//!
//! ```zig
//! try app.world.add(pause_menu, fx.Processing{ .mode = .when_paused });
//! try app.world.add(ghost, fx.Appearance{ .modulate = fx.Color.white.withAlpha(0.5) });
//! app.setPaused(true);
//! ```
//!
//! **Both are optional.** An entity without one is whatever its parent
//! is, and a root without one is the default: runs while the game runs,
//! shows as it is. So a paused game stops everything but what asked not to
//! stop, and a panel fading out takes everything in it along.
//!
//! **Worked out once a frame, where it is asked.** `Inherited.of` walks up
//! to the nearest entity already worked out and keeps what it found, by the
//! entity's slot, until the engine starts the next part of the frame - the
//! fixed steps, the update, the drawing - so a system that changes one sees
//! it from the next part on.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");

const attr = @import("attr.zig");
const Color = @import("color.zig").Color;
const hierarchy = @import("hierarchy.zig");

const Entity = ecs.Entity;

/// Whether an entity runs while the game is paused - its script's `fixed`
/// and `update`, its timers, its animation, its tasks, its controls and the
/// pointer over it. See `App.setPaused`.
pub const Processing = extern struct {
    mode: Mode = .inherit,

    pub const Mode = enum(u8) {
        /// As the entity it hangs from does; a root runs while the game runs.
        inherit,
        /// While the game runs, and not while it is paused.
        pausable,
        /// Only while the game is paused: a pause menu.
        when_paused,
        /// Paused or not.
        always,
        /// Never.
        disabled,

        /// Whether it runs, with the game paused or not.
        pub fn runs(self: Mode, paused: bool) bool {
            return switch (self) {
                .inherit, .pausable => !paused,
                .when_paused => paused,
                .always => true,
                .disabled => false,
            };
        }
    };

    pub const reflect_name = "Processing";
    pub const reflect_fields = .{
        .mode = .{attr.Doc{ .text = "Whether it runs while the game is paused: as its parent does, not then, only then, always, or never" }},
    };
};

/// How an entity shows, and so everything that hangs from it: whether at
/// all, in what colour, and how far up. Its own picture's colour - a
/// sprite's `tint`, a label's `color` - is multiplied by `modulate` and by
/// every one above it.
pub const Appearance = extern struct {
    /// Hidden, it hides everything under it too.
    visible: bool = true,
    /// Multiplied into its drawing and into everything under it.
    modulate: Color = .white,
    /// Added to the layer it and what hangs from it are drawn on.
    z: i16 = 0,
    /// Whether `z` is added to the one it inherits, or stands on its own.
    z_relative: bool = true,

    pub const reflect_name = "Appearance";
    pub const reflect_fields = .{
        .visible = .{attr.Doc{ .text = "Whether it and everything under it is drawn" }},
        .modulate = .{attr.Doc{ .text = "Multiplied into its colours and everything under it" }},
        .z = .{attr.Doc{ .text = "Added to the layer it and everything under it is drawn on" }},
        .z_relative = .{attr.Doc{ .text = "Whether z is added to the one it inherits" }},
    };
};

/// What an entity comes to, with everything above it counted.
pub const Resolved = struct {
    /// Never `.inherit`.
    processing: Processing.Mode = .pausable,
    visible: bool = true,
    modulate: Color = .white,
    z: i32 = 0,

    /// The layer something on `layer` is drawn on under this.
    pub fn layer(self: Resolved, own: i16) i16 {
        const sum = @as(i32, own) + self.z;
        return @intCast(std.math.clamp(sum, std.math.minInt(i16), std.math.maxInt(i16)));
    }

    /// A colour of its own, under this.
    pub fn tint(self: Resolved, own: Color) Color {
        return times(own, self.modulate);
    }
};

fn times(a: Color, b: Color) Color {
    return .{ .r = a.r * b.r, .g = a.g * b.g, .b = a.b * b.b, .a = a.a * b.a };
}

/// The deepest a chain of parents is followed: past it, a cycle.
const max_depth = 256;

/// What each entity came to, kept by its slot until `forget`.
pub const Inherited = struct {
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    /// Which working-out a slot belongs to; one that says another is stale.
    stamp: u32 = 1,

    const Slot = struct {
        stamp: u32 = 0,
        entity: Entity = .none,
        resolved: Resolved = .{},
    };

    pub fn deinit(self: *Inherited, gpa: Allocator) void {
        self.slots.deinit(gpa);
        self.* = .{};
    }

    /// Work everything out again when next asked.
    pub fn forget(self: *Inherited) void {
        self.stamp +%= 1;
        if (self.stamp != 0) return;
        // Round the clock: a slot from long ago must not pass for this one.
        for (self.slots.items) |*slot| slot.stamp = 0;
        self.stamp = 1;
    }

    /// What `entity` comes to. One that is not alive, or `.none`, is a root
    /// with nothing: the defaults.
    pub fn of(self: *Inherited, gpa: Allocator, world: *const ecs.World, entity: Entity) Resolved {
        return self.walk(gpa, world, entity, 0);
    }

    fn walk(self: *Inherited, gpa: Allocator, world: *const ecs.World, entity: Entity, depth: usize) Resolved {
        if (entity.isNone() or !world.isAlive(entity)) return .{};
        if (entity.index < self.slots.items.len) {
            const slot = self.slots.items[entity.index];
            if (slot.stamp == self.stamp and slot.entity.eql(entity)) return slot.resolved;
        }
        const parent = hierarchy.parentOf(world, entity);
        const above: Resolved = if (depth >= max_depth or parent.eql(entity)) .{} else self.walk(gpa, world, parent, depth + 1);
        const out = ownOver(world, entity, above);
        self.keep(gpa, entity, out);
        return out;
    }

    /// Kept for the rest of this working-out; not kept, and so worked out
    /// again, when there is no memory for it.
    fn keep(self: *Inherited, gpa: Allocator, entity: Entity, resolved: Resolved) void {
        if (entity.index >= self.slots.items.len) {
            self.slots.appendNTimes(gpa, .{}, entity.index + 1 - self.slots.items.len) catch return;
        }
        self.slots.items[entity.index] = .{ .stamp = self.stamp, .entity = entity, .resolved = resolved };
    }
};

/// An entity's own, over what it inherits.
fn ownOver(world: *const ecs.World, entity: Entity, above: Resolved) Resolved {
    var out = above;
    if (world.getConst(entity, Processing)) |processing| {
        if (processing.mode != .inherit) out.processing = processing.mode;
    }
    if (world.getConst(entity, Appearance)) |appearance| {
        out.visible = above.visible and appearance.visible;
        out.modulate = times(above.modulate, appearance.modulate);
        out.z = if (appearance.z_relative) above.z + appearance.z else appearance.z;
    }
    return out;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const Parent = @import("components.zig").Parent;

test "an entity is what it hangs from is, but for what it says itself" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var inherited: Inherited = .{};
    defer inherited.deinit(testing.allocator);

    const menu = try world.spawnWith(.{ Processing{ .mode = .when_paused }, Appearance{ .modulate = .{ .r = 1, .g = 0.5, .b = 1, .a = 0.5 }, .z = 3 } });
    const button = try world.spawnWith(.{Parent.of(menu)});
    const icon = try world.spawnWith(.{ Parent.of(button), Appearance{ .modulate = .{ .r = 1, .g = 1, .b = 1, .a = 0.5 }, .z = 2 } });
    const stuck = try world.spawnWith(.{ Parent.of(menu), Processing{ .mode = .disabled }, Appearance{ .visible = false, .z = -1, .z_relative = false } });
    const hidden_child = try world.spawnWith(.{Parent.of(stuck)});
    const lone = try world.spawn();

    const gpa = testing.allocator;
    try testing.expectEqual(Processing.Mode.pausable, inherited.of(gpa, &world, lone).processing);
    try testing.expectEqual(Processing.Mode.when_paused, inherited.of(gpa, &world, button).processing);
    try testing.expectEqual(Processing.Mode.disabled, inherited.of(gpa, &world, hidden_child).processing);

    const drawn = inherited.of(gpa, &world, icon);
    try testing.expectEqual(@as(f32, 0.25), drawn.modulate.a);
    try testing.expectEqual(@as(f32, 0.5), drawn.modulate.g);
    try testing.expectEqual(@as(i32, 5), drawn.z);
    try testing.expect(drawn.visible);
    try testing.expectEqual(@as(i16, 15), drawn.layer(10));

    const gone = inherited.of(gpa, &world, hidden_child);
    try testing.expect(!gone.visible);
    try testing.expectEqual(@as(i32, -1), gone.z);

    // Kept until forgotten: a change is seen from the next working-out on.
    world.get(menu, Processing).?.mode = .always;
    try testing.expectEqual(Processing.Mode.when_paused, inherited.of(gpa, &world, button).processing);
    inherited.forget();
    try testing.expectEqual(Processing.Mode.always, inherited.of(gpa, &world, button).processing);

    // A slot given to another entity is that one's, not the dead one's.
    world.despawn(button);
    const other = try world.spawn();
    try testing.expectEqual(Processing.Mode.pausable, inherited.of(gpa, &world, other).processing);
}

test "a loop of parents ends in the defaults, not in a crash" {
    var world: ecs.World = .init(testing.allocator);
    defer world.deinit();
    var inherited: Inherited = .{};
    defer inherited.deinit(testing.allocator);

    const a = try world.spawnWith(.{Appearance{ .z = 1 }});
    const b = try world.spawnWith(.{ Parent.of(a), Appearance{ .z = 1 } });
    try world.add(a, Parent.of(b));
    const resolved = inherited.of(testing.allocator, &world, a);
    try testing.expect(resolved.z > 0);
}

test "a mode runs as the game's pause says" {
    try testing.expect(Processing.Mode.pausable.runs(false));
    try testing.expect(!Processing.Mode.pausable.runs(true));
    try testing.expect(!Processing.Mode.when_paused.runs(false));
    try testing.expect(Processing.Mode.when_paused.runs(true));
    try testing.expect(Processing.Mode.always.runs(true));
    try testing.expect(!Processing.Mode.disabled.runs(false));
}
