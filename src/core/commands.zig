// SPDX-License-Identifier: BSD-3-Clause

//! Changes to the world that wait for the system asking for them to return:
//! what can be asked for in the middle of a query without pulling the rows
//! out from under it.
//!
//! ```zig
//! var it = try fx.Query(.{Bullet}).over(&app.world);
//! while (it.next()) |chunk| {
//!     for (chunk.entities, chunk.slice(Bullet)) |e, bullet| {
//!         if (bullet.spent) try app.commands.despawn(e);
//!     }
//! }
//! ```
//!
//! A despawn, an `add` or a `remove` moves rows between tables, so one done
//! while a query holds slices of those tables skips entities or visits them
//! twice. A command is kept instead, and the engine does them all, in the
//! order they were asked for, when the system returns.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");

const Entity = ecs.Entity;
const World = ecs.World;

const Commands = @This();

gpa: Allocator,
world: *World,
queue: std.ArrayList(Command) = .empty,
/// The component values the queued `add`s carry, one after another.
values: std.ArrayList(u8) = .empty,
/// Held while a command is written down: a parallel `Query.each` may ask
/// from every worker at once.
busy: std.atomic.Value(bool) = .init(false),

const Command = struct {
    entity: Entity,
    run: *const fn (world: *World, e: Entity, value: []const u8) World.Error!void,
    /// Where its value is in `values`, for an `add`.
    at: usize = 0,
    len: usize = 0,
};

pub fn init(gpa: Allocator, world: *World) Commands {
    return .{ .gpa = gpa, .world = world };
}

pub fn deinit(self: *Commands) void {
    self.queue.deinit(self.gpa);
    self.values.deinit(self.gpa);
    self.* = undefined;
}

/// A new entity, alive now with nothing on it, which gets `values` when the
/// system returns. The handle works at once: name it, hang things from it,
/// keep it in a component. Only from the system's own thread - not from
/// inside a parallel `Query.each` - because making the handle is a change to
/// the world, if the smallest one.
pub fn spawn(self: *Commands, values: anytype) (World.Error || Allocator.Error)!Entity {
    const fields = @typeInfo(@TypeOf(values)).@"struct".fields;
    comptime {
        for (fields, 0..) |a, i| {
            for (fields[i + 1 ..]) |b| {
                if (a.type == b.type) @compileError("fluxion-engine: " ++ @typeName(a.type) ++ " twice in one spawn");
            }
        }
    }
    // Into the empty set, which no query walks: this moves no row that
    // anything is iterating.
    const e = try self.world.spawn();
    errdefer self.world.despawn(e);
    inline for (fields) |field| try self.add(e, @field(values, field.name));
    return e;
}

/// Put `value` on `e` when the system returns, over one it already has.
pub fn add(self: *Commands, e: Entity, value: anytype) Allocator.Error!void {
    const T = @TypeOf(value);
    ecs.component.check(T);
    self.lock();
    defer self.unlock();
    const at = self.values.items.len;
    try self.values.appendSlice(self.gpa, std.mem.asBytes(&value));
    errdefer self.values.shrinkRetainingCapacity(at);
    try self.queue.append(self.gpa, .{ .entity = e, .run = Apply(T).add, .at = at, .len = @sizeOf(T) });
}

/// Take a `T` off `e` when the system returns.
pub fn remove(self: *Commands, e: Entity, comptime T: type) Allocator.Error!void {
    ecs.component.check(T);
    self.lock();
    defer self.unlock();
    try self.queue.append(self.gpa, .{ .entity = e, .run = Apply(T).remove });
}

/// Take `e` out of the world when the system returns. What hangs from it goes
/// at the end of the frame, as with `World.despawn`.
pub fn despawn(self: *Commands, e: Entity) Allocator.Error!void {
    self.lock();
    defer self.unlock();
    try self.queue.append(self.gpa, .{ .entity = e, .run = despawnNow });
}

/// Do everything asked for, in order, now. The engine calls this after every
/// system; a system calls it for what it needs at once - a body for what it
/// just spawned, to join it to another - and never from inside a query.
///
/// A command for an entity that has died since is passed over: two bullets
/// despawning the enemy both hit is not a mistake.
pub fn apply(self: *Commands) World.Error!void {
    if (self.queue.items.len == 0) return;
    defer self.clear();
    for (self.queue.items) |command| {
        try command.run(self.world, command.entity, self.values.items[command.at..][0..command.len]);
    }
}

/// Forget everything asked for: what `App.clearWorld` needs, because the
/// entities it names are gone and their handles will be handed out again.
pub fn clear(self: *Commands) void {
    self.queue.clearRetainingCapacity();
    self.values.clearRetainingCapacity();
}

/// How many commands are waiting.
pub fn count(self: *const Commands) usize {
    return self.queue.items.len;
}

fn lock(self: *Commands) void {
    while (self.busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlock(self: *Commands) void {
    self.busy.store(false, .release);
}

fn Apply(comptime T: type) type {
    return struct {
        fn add(world: *World, e: Entity, bytes: []const u8) World.Error!void {
            var value: T = undefined;
            @memcpy(std.mem.asBytes(&value), bytes);
            world.add(e, value) catch |err| switch (err) {
                error.NoSuchEntity => {},
                else => |other| return other,
            };
        }

        fn remove(world: *World, e: Entity, _: []const u8) World.Error!void {
            try world.remove(e, T);
        }
    };
}

fn despawnNow(world: *World, e: Entity, _: []const u8) World.Error!void {
    world.despawn(e);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const Mark = extern struct { value: u32 = 0 };
const Tag = extern struct { hot: bool = true };

test "a despawn asked for inside a query waits for the query to finish" {
    var world: World = .init(testing.allocator);
    defer world.deinit();
    var commands: Commands = .init(testing.allocator, &world);
    defer commands.deinit();

    for (0..10) |i| _ = try world.spawnWith(.{Mark{ .value = @intCast(i) }});

    var visited: usize = 0;
    var it = try ecs.Query(.{Mark}).over(&world);
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(Mark)) |e, mark| {
            visited += 1;
            if (mark.value % 2 == 0) try commands.despawn(e);
        }
    }
    try testing.expectEqual(@as(usize, 10), visited);
    try testing.expectEqual(@as(usize, 10), world.count());

    try commands.apply();
    try testing.expectEqual(@as(usize, 5), world.count());
    try testing.expectEqual(@as(usize, 0), commands.count());
}

test "a spawned entity is alive at once, and has its components when the commands run" {
    var world: World = .init(testing.allocator);
    defer world.deinit();
    var commands: Commands = .init(testing.allocator, &world);
    defer commands.deinit();

    const e = try commands.spawn(.{ Mark{ .value = 7 }, Tag{} });
    try testing.expect(world.isAlive(e));
    try testing.expect(world.get(e, Mark) == null);

    try commands.apply();
    try testing.expectEqual(@as(u32, 7), world.get(e, Mark).?.value);
    try testing.expect(world.has(e, Tag));
}

test "commands run in the order they were asked for" {
    var world: World = .init(testing.allocator);
    defer world.deinit();
    var commands: Commands = .init(testing.allocator, &world);
    defer commands.deinit();

    const e = try world.spawnWith(.{Mark{ .value = 1 }});
    try commands.add(e, Tag{});
    try commands.remove(e, Mark);
    try commands.add(e, Mark{ .value = 3 });
    try commands.apply();
    try testing.expectEqual(@as(u32, 3), world.get(e, Mark).?.value);
    try testing.expect(world.has(e, Tag));

    const brief = try commands.spawn(.{Mark{}});
    try commands.despawn(brief);
    try commands.apply();
    try testing.expect(!world.isAlive(brief));
}

test "a command for an entity that died meanwhile is passed over" {
    var world: World = .init(testing.allocator);
    defer world.deinit();
    var commands: Commands = .init(testing.allocator, &world);
    defer commands.deinit();

    const e = try world.spawnWith(.{Mark{}});
    try commands.add(e, Tag{});
    try commands.remove(e, Mark);
    try commands.despawn(e);
    try commands.despawn(e);
    world.despawn(e);
    try commands.apply();
    try testing.expectEqual(@as(usize, 0), world.count());
}

test "commands asked for from every worker of a parallel query are all run" {
    var world: World = .init(testing.allocator);
    defer world.deinit();
    var commands: Commands = .init(testing.allocator, &world);
    defer commands.deinit();
    var jobs: ecs.Jobs = try .init(testing.allocator, .{ .io = testing.io, .workers = .{ .count = 4 } });
    defer jobs.deinit();

    for (0..5000) |i| _ = try world.spawnWith(.{Mark{ .value = @intCast(i) }});
    try ecs.Query(.{Mark}).each(&world, &jobs, &commands, struct {
        fn run(c: *Commands, chunk: ecs.Query(.{Mark}).Chunk) void {
            for (chunk.entities) |e| c.despawn(e) catch unreachable;
        }
    }.run, .{ .grain = 64 });

    try testing.expectEqual(@as(usize, 5000), commands.count());
    try commands.apply();
    try testing.expectEqual(@as(usize, 0), world.count());
}
