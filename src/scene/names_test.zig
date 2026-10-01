// SPDX-License-Identifier: BSD-3-Clause

//! Names, UUIDs and groups through a whole app, headless.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const components = @import("components.zig");
const ecs = @import("fluxion_ecs");

test "clearing the world leaves nothing in it, and frees every name" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const door = try app.world.spawnWith(.{components.Transform2D.at(1, 2)});
    try app.setName(door, "door");
    _ = try app.world.spawnWith(.{ components.Transform2D.at(0, 1), components.Parent.of(door) });

    app.clearWorld();
    try testing.expectEqual(@as(usize, 0), app.world.count());
    try testing.expect(app.find("door") == null);

    // A fresh world hands out the same handles again, and none of them may
    // come with an old name.
    const again = try app.world.spawnWith(.{components.Transform2D.at(3, 4)});
    try testing.expect(again.eql(door));
    try testing.expect(app.nameOf(again) == null);
    try app.setName(again, "door");
    try testing.expect(app.find("door").?.eql(again));
}

test "a name finds its entity, and the entity its name" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    const camera = try app.world.spawnWith(.{components.Transform2D{}});
    const player = try app.world.spawnWith(.{components.Transform2D{}});
    const shapes = app.world.archetypeSlice().len;
    try app.setName(camera, "camera");
    try app.setName(player, "player");

    try testing.expect(app.find("camera").?.eql(camera));
    try testing.expect(app.find("player").?.eql(player));
    try testing.expectEqualStrings("camera", app.nameOf(camera).?);
    try testing.expect(app.find("door") == null);

    // A name is not a component: no new archetype.
    try testing.expectEqual(shapes, app.world.archetypeSlice().len);

    const rock = try app.world.spawn();
    try testing.expect(app.nameOf(rock) == null);
}

test "a name belongs to one living entity at a time" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    const first = try app.world.spawn();
    const second = try app.world.spawn();
    try app.setName(first, "door");

    try testing.expectError(error.NameTaken, app.setName(second, "door"));
    // Its own name again is not a clash.
    try app.setName(first, "door");

    // Despawned: the name is free at once, before the end of the frame.
    app.world.despawn(first);
    try testing.expect(app.find("door") == null);
    try testing.expect(app.nameOf(first) == null);
    try app.setName(second, "door");
    try testing.expect(app.find("door").?.eql(second));

    try testing.expectError(error.NoSuchEntity, app.setName(first, "ghost"));
}

test "renaming frees the old name, and the text is copied" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    const thing = try app.world.spawn();
    var buffer: [16]u8 = undefined;
    try app.setName(thing, try std.fmt.bufPrint(&buffer, "player {d}", .{2}));
    @memset(&buffer, 'x');
    try testing.expect(app.find("player 2").?.eql(thing));

    try app.setName(thing, "hero");
    try testing.expect(app.find("player 2") == null);
    try testing.expectEqualStrings("hero", app.nameOf(thing).?);

    // And the old name is anybody's.
    const other = try app.world.spawn();
    try app.setName(other, "player 2");
    try testing.expect(app.find("player 2").?.eql(other));
}

test "a rename that runs out of memory keeps the old name" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const app = try App.create(failing.allocator(), .{ .headless = true });
    defer app.destroy();

    const thing = try app.world.spawn();
    try app.setName(thing, "name 0");

    // Renamed while the tables fill, so each has to grow at some point, with
    // every allocation of each rename failing in turn: the old name has to
    // survive every failure.
    var old_text: [16]u8 = undefined;
    var new_text: [16]u8 = undefined;
    for (1..24) |round| {
        const old = try std.fmt.bufPrint(&old_text, "name {d}", .{round - 1});
        const new = try std.fmt.bufPrint(&new_text, "name {d}", .{round});

        var fail_after: usize = 0;
        while (true) : (fail_after += 1) {
            failing.fail_index = failing.alloc_index + fail_after;
            app.setName(thing, new) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                try testing.expectEqualStrings(old, app.nameOf(thing).?);
                try testing.expect(app.find(old).?.eql(thing));
                try testing.expect(app.find(new) == null);
                continue;
            };
            break;
        }
        failing.fail_index = std.math.maxInt(usize);
        try testing.expect(app.find(new).?.eql(thing));

        const filler = try app.world.spawn();
        try app.setName(filler, try std.fmt.bufPrint(&new_text, "filler {d}", .{round}));
    }
}

test "the names of the dead are given back at the end of the frame" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    const ship = try app.world.spawnWith(.{components.Transform2D.at(10, 10)});
    const flame = try app.world.spawnWith(.{ components.Transform2D.at(0, 8), components.Parent.of(ship) });
    const buoy = try app.world.spawn();
    try app.setName(ship, "ship");
    try app.setName(flame, "flame");
    try app.setName(buoy, "buoy");

    app.world.despawn(ship);
    try app.run();

    // The flame went with the ship, and both names with them.
    try testing.expect(app.find("flame") == null);
    try testing.expect(app.find("buoy").?.eql(buoy));
    try testing.expectEqual(@as(usize, 1), app.names.of_entity.count());
    try testing.expectEqual(@as(u32, 1), app.names.by_name.count());
}

test "a name is its siblings' own: two parents may each have a child of it, and a clash takes the next free one" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    const left = try app.world.spawn();
    const right = try app.world.spawn();
    try app.setName(left, "left");
    try app.setName(right, "right");
    const first = try app.world.spawnWith(.{components.Parent.of(left)});
    const second = try app.world.spawnWith(.{components.Parent.of(right)});
    const third = try app.world.spawnWith(.{components.Parent.of(left)});
    try app.setName(first, "hand");
    try app.setName(second, "hand");
    try testing.expectError(error.NameTaken, app.setName(third, "hand"));
    try app.setFreeName(third, "hand");
    try testing.expectEqualStrings("hand 2", app.nameOf(third).?);

    // `find` answers with the first given it; a path says which.
    try testing.expect(app.find("hand").?.eql(first));
    try testing.expect(app.findPath(right, "hand").?.eql(second));
    try testing.expect(app.findPath(second, "../../left/hand 2").?.eql(third));
    try testing.expect(app.findPath(second, "/left/./hand").?.eql(first));
    try testing.expect(app.findPath(left, "nobody") == null);
    try testing.expect(app.findPath(left, "../..") == null);
    try testing.expect(app.findIn(.none, "hand 2").?.eql(third));
    try testing.expect(app.findIn(right, "hand").?.eql(second));
    try testing.expect(app.findIn(right, "hand 2") == null);

    // Moved in among others of its name, it takes the next free one, and
    // comes last.
    try app.setParent(second, left, false);
    try testing.expectEqualStrings("hand 3", app.nameOf(second).?);
    try testing.expectEqual(@as(i64, 3), app.childCount(left));
    try testing.expect(app.childAt(left, 0).?.eql(first));
    try testing.expect(app.childAt(left, 2).?.eql(second));
    try testing.expect(app.childAt(left, 3) == null);
    try testing.expectEqual(@as(i64, 0), app.childCount(right));
}

fn nudge(app: *App, self: ecs.Entity) !void {
    app.world.get(self, components.Transform2D).?.x += 1;
}

test "a group is found and called wherever its members are, and lets the dead go" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addMethod("nudge", nudge);

    const bat = try app.world.spawnWith(.{components.Transform2D{}});
    const ghost = try app.world.spawnWith(.{ components.Transform2D{}, components.Parent.of(bat) });
    const lamp = try app.world.spawnWith(.{components.Transform2D{}});
    try app.addToGroup(bat, "enemies");
    try app.addToGroup(ghost, "enemies");
    try app.addToGroup(ghost, "enemies");
    try app.addToGroup(ghost, "loud");

    try testing.expectEqual(@as(usize, 2), app.groupMembers("enemies").len);
    try testing.expect(app.groupMembers("enemies")[1].eql(ghost));
    try testing.expect(!app.isInGroup(lamp, "enemies"));
    try testing.expectEqual(@as(usize, 0), app.groupMembers("nobody").len);
    var held: [4][]const u8 = undefined;
    const groups = app.groupsOf(ghost, &held);
    try testing.expectEqual(@as(usize, 2), groups.len);
    try testing.expectEqualStrings("enemies", groups[0]);
    try testing.expectEqualStrings("loud", groups[1]);

    try app.callGroup("enemies", "nudge");
    // A member with no such method is passed over.
    try app.callGroup("enemies", "no such thing");
    try testing.expectEqual(@as(f32, 1), app.world.get(bat, components.Transform2D).?.x);
    try testing.expectEqual(@as(f32, 1), app.world.get(ghost, components.Transform2D).?.x);
    try testing.expectEqual(@as(f32, 0), app.world.get(lamp, components.Transform2D).?.x);

    app.removeFromGroup(bat, "enemies");
    try testing.expectEqual(@as(usize, 1), app.groupMembers("enemies").len);

    // The dead are no members at once, and are let go of at the end of the
    // frame.
    app.world.despawn(ghost);
    try testing.expectEqual(@as(usize, 0), app.groupMembers("enemies").len);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.groupMembers("loud").len);
    try testing.expectError(error.NoSuchEntity, app.addToGroup(ghost, "enemies"));
}

test "a UUID belongs to one living entity at a time, and is free again when it dies" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const door = try app.world.spawn();
    const gate = try app.world.spawn();
    const uuid = app.newUuid();
    try testing.expectEqual(@as(u4, 4), uuid.version());
    try testing.expect(!uuid.eql(app.newUuid()));

    try app.setUuid(door, uuid);
    try testing.expect(app.findUuid(uuid).?.eql(door));
    try testing.expect(app.uuidOf(door).?.eql(uuid));
    try testing.expectError(error.UuidTaken, app.setUuid(gate, uuid));
    try app.setUuid(door, uuid);
    try testing.expectError(error.NilUuid, app.setUuid(gate, .nil));

    // Another for the door, and the first is anybody's.
    const other = app.newUuid();
    try app.setUuid(door, other);
    try testing.expect(app.findUuid(uuid) == null);
    try app.setUuid(gate, uuid);
    try testing.expect(app.findUuid(uuid).?.eql(gate));

    // Despawned: free at once, before the end of the frame.
    app.world.despawn(gate);
    try testing.expect(app.findUuid(uuid) == null);
    try testing.expect(app.uuidOf(gate) == null);
    try app.setUuid(door, uuid);
    try testing.expectError(error.NoSuchEntity, app.setUuid(gate, other));
    try testing.expectError(error.NoSuchEntity, app.ensureUuid(gate));
}

test "an entity given a UUID keeps it, and the dead ones are forgotten at the end of the frame" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const thing = try app.world.spawn();
    const given = try app.ensureUuid(thing);
    try testing.expect(given.eql(try app.ensureUuid(thing)));

    app.world.despawn(thing);
    try testing.expectEqual(@as(usize, 1), app.uuids.of_entity.count());
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.uuids.of_entity.count());
    try testing.expectEqual(@as(usize, 0), app.uuids.by_uuid.count());

    _ = try app.ensureUuid(try app.world.spawn());
    app.clearWorld();
    try testing.expectEqual(@as(usize, 0), app.uuids.of_entity.count());
}
