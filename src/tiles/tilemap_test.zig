// SPDX-License-Identifier: BSD-3-Clause

//! Tile maps through a whole app, headless: chunks, solid tiles and their bodies,
//! used cells, tile data and shapes.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const ecs = @import("fluxion_ecs");
const geometry = @import("../math/geometry.zig");
const tilemap = @import("tilemap.zig");
const tileset = @import("tileset.zig");

/// A tile set of one untextured source: its first tile solid, its second a
/// picture and nothing more.
const solid_tiles =
    \\{
    \\  "fluxion_tileset": 1,
    \\  "tile_size": [16, 16],
    \\  "sources": [{ "id": 0, "tiles": [{ "at": [0, 0], "collision": "full" }] }]
    \\}
;

test "tile maps create signed chunks and cull them before their tiles" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1, .width = 320, .height = 240 });
    defer app.destroy();
    const set = try app.addTileSet("tiles.tileset", solid_tiles);
    const map = try app.world.spawnWith(.{ components.Transform2D{}, tilemap.TileMap{ .tile_set = set } });
    const near = (try app.setTile(map, -1, -1, .at(0, 0, 0))).?;
    _ = try app.setTile(map, 0, 0, .at(0, 0, 0));
    const far = (try app.setTile(map, 1024, 1024, .at(0, 0, 0))).?;
    try app.run();

    try testing.expectEqual(@as(i32, -1), app.world.get(near, tilemap.TileChunk).?.x);
    try testing.expectEqual(@as(i32, -1), app.world.get(near, tilemap.TileChunk).?.y);
    try testing.expectEqual(@as(i32, 64), app.world.get(far, tilemap.TileChunk).?.x);
    try testing.expectEqual(@as(u32, 2), app.sprites.tile_chunks_drawn);
    try testing.expectEqual(@as(u32, 1), app.sprites.tile_chunks_culled);
    try testing.expectEqual(@as(u32, 2), app.sprites.drawn);

    // The index finds a chunk, and an emptied one goes away with its key.
    try testing.expect(app.tileChunkAt(map, -1, -1).?.eql(near));
    try testing.expect(app.tileAt(map, -1, -1).has(tilemap.Cell.present));
    try testing.expect(try app.setTile(map, -1, -1, .empty) == null);
    try testing.expect(app.tileChunkAt(map, -1, -1) == null);
    try testing.expect(app.tileAt(map, -1, -1).isEmpty());
    try testing.expect(!app.world.isAlive(near));
}

test "a map's chunks go when the map does" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();
    const set = try app.addTileSet("tiles.tileset", solid_tiles);
    const map = try app.world.spawnWith(.{ components.Transform2D{}, tilemap.TileMap{ .tile_set = set } });
    const chunk = (try app.setTile(map, 2, 2, .at(0, 0, 0))).?;

    app.world.despawn(map);
    try app.run();
    try testing.expect(!app.world.isAlive(chunk));
    try testing.expectEqual(@as(usize, 0), app.tile_chunks.by_key.count());
}

test "the tile set says which tiles are solid, and they become one body" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1, .width = 64, .height = 64 });
    defer app.destroy();
    const set = try app.addTileSet("tiles.tileset", solid_tiles);
    const map = try app.world.spawnWith(.{ components.Transform2D{}, tilemap.TileMap{ .tile_set = set } });
    _ = try app.setTile(map, 0, 0, .at(0, 0, 0));
    _ = try app.setTile(map, 1, 0, .at(0, 0, 0));
    // A tile the set says nothing of is a picture and no more.
    _ = try app.setTile(map, 2, 0, .at(0, 3, 0));
    try app.run();

    try testing.expectEqual(@as(usize, 1), app.physics.bodyCount());
    try testing.expectEqual(@as(usize, 1), app.physics.shapeCount());
    const hit = app.castRay(.init(8, -8), .init(8, 24), 0xFFFF_FFFF, false) orelse return error.TestExpectedEqual;
    try testing.expect(hit.shape.eql(map));

    _ = try app.setTile(map, 0, 0, .empty);
    _ = try app.setTile(map, 1, 0, .empty);
    try app.bodies.sync(app);
    try testing.expectEqual(@as(usize, 0), app.physics.shapeCount());
}

test "a map's used cells are the smallest rectangle round what is painted, across chunks" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const map = try app.world.spawnWith(.{ components.Transform2D{}, tilemap.TileMap{} });
    try testing.expect(app.usedCells(map) == null);

    _ = try app.setTile(map, 3, 2, .at(0, 0, 0));
    _ = try app.setTile(map, -20, 40, .at(0, 0, 0));
    const used = app.usedCells(map).?;
    try testing.expectEqual(geometry.Vec2i.init(-20, 2), used.position);
    try testing.expectEqual(geometry.Vec2i.init(3, 40), used.last());

    // Another map's cells are its own.
    const other = try app.world.spawnWith(.{ components.Transform2D{}, tilemap.TileMap{} });
    _ = try app.setTile(other, 100, 100, .at(0, 0, 0));
    try testing.expectEqual(geometry.Vec2i.init(3, 40), app.usedCells(map).?.last());
}

test "a tile's data is asked for by its cell, or by a point of the world over it" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const set = try app.addTileSet("data.tileset",
        \\{ "fluxion_tileset": 1, "tile_size": [16, 16], "data_layers": [{ "name": "damage", "type": "int" }],
        \\  "sources": [{ "id": 0, "tiles": [{ "at": [1, 0], "data": { "damage": 3 } }] }] }
    );
    const map = try app.world.spawnWith(.{ components.Transform2D{ .x = 100 }, tilemap.TileMap{ .tile_set = set } });
    _ = try app.setTile(map, 2, 1, .at(0, 1, 0));
    _ = try app.setTile(map, 3, 1, .at(0, 0, 0));

    try testing.expectEqual(tileset.Value{ .int = 3 }, app.tileData(map, 2, 1, "damage").?);
    try testing.expectEqual(tileset.Value{ .int = 0 }, app.tileData(map, 3, 1, "damage").?);
    try testing.expect(app.tileData(map, 4, 1, "damage") == null);
    try testing.expect(app.tileData(map, 2, 1, "speed") == null);

    // The map starts 100 to the right: cell (2, 1) is from 132 to 148 across.
    try testing.expectEqual(geometry.Vec2i.init(2, 1), app.cellAt(map, .init(140, 20)).?);
    try testing.expectEqual(geometry.Vec2i.init(-1, -1), app.cellAt(map, .init(99, -1)).?);
    try testing.expectEqual(tileset.Value{ .int = 3 }, app.tileDataAt(map, .init(140, 20), "damage").?);
    const nothing = try app.world.spawnWith(.{components.Transform2D{}});
    try testing.expect(app.cellAt(nothing, .init(0, 0)) == null);
}

test "a tile's own shape is a polygon, turned the way its cell is" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const set = try app.addTileSet("slope.tileset",
        \\{
        \\  "fluxion_tileset": 1,
        \\  "tile_size": [16, 16],
        \\  "sources": [{ "id": 0, "tiles": [
        \\    { "at": [0, 0], "collision": "polygon", "polygon": [[0, 16], [16, 16], [16, 0]] }
        \\  ] }]
        \\}
    );
    const map = try app.world.spawnWith(.{ components.Transform2D{}, tilemap.TileMap{ .tile_set = set } });
    _ = try app.setTile(map, 0, 0, .at(0, 0, 0));
    try app.syncBodies();
    try testing.expectEqual(@as(usize, 1), app.physics.shapeCount());

    // The ramp rises to the right: at its left edge only the last two
    // pixels are solid, at its right edge all but the first two.
    try testing.expect(app.castRay(.init(2, 0), .init(2, 10), 0xFFFF_FFFF, false) == null);
    try testing.expect(app.castRay(.init(14, 0), .init(14, 10), 0xFFFF_FFFF, false) != null);

    // Flipped, it rises to the left instead.
    _ = try app.setTile(map, 0, 0, tilemap.Cell.at(0, 0, 0).with(tilemap.Cell.flip_h, true));
    try app.syncBodies();
    try testing.expect(app.castRay(.init(2, 0), .init(2, 10), 0xFFFF_FFFF, false) != null);
    try testing.expect(app.castRay(.init(14, 0), .init(14, 10), 0xFFFF_FFFF, false) == null);
}

test "a rigid body detects a tile floor below its collider" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const set = try app.addTileSet("tiles.tileset", solid_tiles);
    const map = try app.world.spawnWith(.{
        components.Transform2D{},
        tilemap.TileMap{ .tile_set = set, .collision_layer = 1, .collision_mask = 2 },
    });
    _ = try app.setTile(map, 0, 0, .at(0, 0, 0));
    const player = try app.world.spawnWith(.{
        components.Transform2D.at(8, -5),
        components.RigidBody2D{},
        components.Collider2D{ .extents = .init(4, 4), .collision_layer = 2, .collision_mask = 1 },
    });
    try app.syncBodies();
    try testing.expect(app.isOnFloor(player, 5));

    app.world.get(player, components.Transform2D).?.y = -20;
    try app.syncBodies();
    try testing.expect(!app.isOnFloor(player, 5));
}

/// What pushes a crate along in a fixed step, as a game's script does: its
/// speed set, whatever it was.
const Pusher = struct {
    var crate: ecs.Entity = .none;
    var speed: f32 = 0;

    fn push(app: *App) !void {
        const body = app.world.get(crate, components.RigidBody2D) orelse return;
        body.linear_velocity.x = speed;
    }
};

test "a crate stands on a tile floor at rest and pushed along it, as far as over its edge" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 60.0 };
    const set = try app.addTileSet("tiles.tileset", solid_tiles);
    const map = try app.world.spawnWith(.{ components.Transform2D{}, tilemap.TileMap{ .tile_set = set } });
    for (0..10) |x| _ = try app.setTile(map, @intCast(x), 0, .at(0, 0, 0));
    // Sized from its sprite, as a crate put in a scene is.
    const crate = try app.world.spawnWith(.{
        components.Transform2D.at(40, -30),
        components.Sprite{ .width = 28, .height = 28 },
        components.RigidBody2D{},
        components.Collider2D{},
    });
    Pusher.crate = crate;
    Pusher.speed = 0;
    try app.addSystem(.fixed, "push", Pusher.push);
    try app.startup();

    // At rest it has sunk into the floor by the physics' slop - which a ray
    // from its bottom would start inside of - and stands.
    for (0..60) |_| _ = try app.step();
    try testing.expect(app.world.get(crate, components.Transform2D).?.y + 14 > 0);
    try testing.expect(app.isOnFloor(crate, 6));

    // Pushed along, it stands every step, and still with its middle past the
    // end of the floor.
    Pusher.speed = 120;
    while (app.world.get(crate, components.Transform2D).?.x < 165) {
        _ = try app.step();
        try testing.expect(app.isOnFloor(crate, 6));
    }

    // Off the end, it falls, and stands on nothing.
    for (0..30) |_| _ = try app.step();
    try testing.expect(!app.isOnFloor(crate, 6));
}
