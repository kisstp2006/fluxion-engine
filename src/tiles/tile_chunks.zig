// SPDX-License-Identifier: BSD-3-Clause

//! Which entity holds each chunk of each map, so painting a tile finds its
//! chunk without walking every chunk in the world, and the tile calls that
//! go through it: `App.setTile`, `App.tileAt`, `App.usedCells` and the rest.
//!
//! Kept beside the world, as the names are: a chunk holds no handle of its
//! own. A chunk is only ever made by `TileChunks.make`, so the index knows
//! every one; one despawned elsewhere leaves its key behind, which the first
//! look after that gives back. The index keeps the order the chunks were
//! made in, which is the order a scene writes them in.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("../App.zig");
const tilemap = @import("tilemap.zig");
const tileset = @import("tileset.zig");
const geometry = @import("../math/geometry.zig");

const Entity = ecs.Entity;
const TileMap = tilemap.TileMap;
const TileChunk = tilemap.TileChunk;
const Cell = tilemap.Cell;
const chunk_side = tilemap.chunk_side;

/// Which chunk of which map: what the index finds an entity by.
pub const ChunkKey = struct {
    map: Entity,
    x: i32,
    y: i32,
};

pub const SetTileError = error{ NotATileMap, OutOfMemory };

pub const TileChunks = struct {
    by_key: std.AutoArrayHashMapUnmanaged(ChunkKey, Entity) = .empty,

    pub fn deinit(self: *TileChunks, gpa: Allocator) void {
        self.by_key.deinit(gpa);
    }

    /// Every chunk forgotten, as a world thrown away takes them.
    pub fn clear(self: *TileChunks) void {
        self.by_key.clearRetainingCapacity();
    }

    /// The entity holding a map's chunk at `x`, `y`, in chunks.
    pub fn at(self: *TileChunks, world: *ecs.World, map: Entity, x: i32, y: i32) ?Entity {
        const key: ChunkKey = .{ .map = map, .x = x, .y = y };
        const entity = self.by_key.get(key) orelse return null;
        const chunk = world.get(entity, TileChunk) orelse {
            self.remove(key);
            return null;
        };
        if (!chunk.map.eql(map) or chunk.x != x or chunk.y != y) {
            self.remove(key);
            return null;
        }
        return entity;
    }

    /// A chunk of a map, made and put in the index. Its cells start empty.
    pub fn make(self: *TileChunks, gpa: Allocator, world: *ecs.World, map: Entity, x: i32, y: i32) SetTileError!Entity {
        if (!world.has(map, TileMap)) return error.NotATileMap;
        try self.by_key.ensureUnusedCapacity(gpa, 1);
        const entity = world.spawnWith(.{TileChunk{ .map = map, .x = x, .y = y }}) catch return error.OutOfMemory;
        self.by_key.putAssumeCapacity(.{ .map = map, .x = x, .y = y }, entity);
        return entity;
    }

    /// Forget a chunk, keeping the others in their order.
    pub fn remove(self: *TileChunks, key: ChunkKey) void {
        _ = self.by_key.orderedRemove(key);
    }
};

/// Put `cell` at `x`, `y` of `map`, counted in tiles from the map's origin:
/// see `App.setTile`.
pub fn setTile(app: *App, map: Entity, x: i32, y: i32, cell: Cell) SetTileError!?Entity {
    if (!app.world.has(map, TileMap)) return error.NotATileMap;
    const chunk_x = @divFloor(x, chunk_side);
    const chunk_y = @divFloor(y, chunk_side);
    const local_x: u8 = @intCast(@mod(x, chunk_side));
    const local_y: u8 = @intCast(@mod(y, chunk_side));

    const entity = app.tile_chunks.at(&app.world, map, chunk_x, chunk_y) orelse {
        // Nothing there to empty.
        if (cell.isEmpty()) return null;
        const made = try app.tile_chunks.make(app.gpa, &app.world, map, chunk_x, chunk_y);
        _ = app.world.get(made, TileChunk).?.set(local_x, local_y, cell);
        return made;
    };

    const chunk = app.world.get(entity, TileChunk).?;
    _ = chunk.set(local_x, local_y, cell);
    if (cell.isEmpty() and chunk.isEmpty()) {
        app.tile_chunks.remove(.{ .map = map, .x = chunk_x, .y = chunk_y });
        app.world.despawn(entity);
        return null;
    }
    return entity;
}

/// What is at `x`, `y` of `map`: `Cell.empty` where nothing was painted.
pub fn tileAt(app: *App, map: Entity, x: i32, y: i32) Cell {
    const entity = app.tile_chunks.at(&app.world, map, @divFloor(x, chunk_side), @divFloor(y, chunk_side)) orelse return .empty;
    const chunk = app.world.get(entity, TileChunk).?;
    return chunk.get(@intCast(@mod(x, chunk_side)), @intCast(@mod(y, chunk_side))).?;
}

/// How big one tile of a map is, in its own pixels: what its tile set says,
/// or the default for a map without one.
pub fn tileSizeOf(app: *App, map: Entity) [2]f32 {
    const default: [2]f32 = .{ tileset.default_tile_size, tileset.default_tile_size };
    const held = app.world.getConst(map, TileMap) orelse return default;
    const set = app.tile_sets.get(held.tile_set) orelse return default;
    return .{ @floatFromInt(set.tile_width), @floatFromInt(set.tile_height) };
}

/// Which cell of `map` a point of the world is in, counted as `setTile`
/// counts them. Null for an entity with no `TileMap`.
pub fn cellAt(app: *App, map: Entity, point: math.Vec2) ?geometry.Vec2i {
    if (!app.world.has(map, TileMap)) return null;
    const placed = app.worldTransform(map) orelse return null;
    const local = placed.unapply(point.x, point.y);
    const tile = tileSizeOf(app, map);
    return .init(
        std.math.lossyCast(i32, @floor(local.x / tile[0])),
        std.math.lossyCast(i32, @floor(local.y / tile[1])),
    );
}

/// The cells of `map` something is painted in: the smallest rectangle that
/// holds them all. Null for a map with nothing painted.
pub fn usedCells(app: *App, map: Entity) ?geometry.Rect2i {
    var out: ?geometry.Rect2i = null;
    var it = app.tile_chunks.by_key.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!key.map.eql(map)) continue;
        // One despawned elsewhere is not the map's any more.
        const chunk = app.world.getConst(entry.value_ptr.*, TileChunk) orelse continue;
        if (!chunk.map.eql(map) or chunk.x != key.x or chunk.y != key.y) continue;
        for (chunk.cells, 0..) |cell, at| {
            if (cell.isEmpty()) continue;
            const x = key.x * chunk_side + @as(i32, @intCast(at % chunk_side));
            const y = key.y * chunk_side + @as(i32, @intCast(at / chunk_side));
            const place: geometry.Vec2i = .init(x, y);
            out = if (out) |held| held.expandTo(place) else .fromCells(place, place);
        }
    }
    return out;
}

/// The box a map's painted tiles fill, in the map's own pixels: left, top,
/// right and bottom. Null for an entity with no `TileMap`, or one with no
/// tiles in it.
pub fn bounds(app: *App, map: Entity) ?[4]f32 {
    if (!app.world.has(map, TileMap)) return null;
    const used = usedCells(app, map) orelse return null;
    const tile = tileSizeOf(app, map);
    const end = used.end();
    return .{
        @as(f32, @floatFromInt(used.position.x)) * tile[0],
        @as(f32, @floatFromInt(used.position.y)) * tile[1],
        @as(f32, @floatFromInt(end.x)) * tile[0],
        @as(f32, @floatFromInt(end.y)) * tile[1],
    };
}

/// What the tile at `x`, `y` of `map` says under its tile set's data layer
/// called `layer`: see `App.tileData`.
pub fn tileData(app: *App, map: Entity, x: i32, y: i32, layer: []const u8) ?tileset.Value {
    const held = app.world.getConst(map, TileMap) orelse return null;
    const set = app.tile_sets.get(held.tile_set) orelse return null;
    return set.dataOf(tileAt(app, map, x, y), layer);
}

/// The same for the tile under a point of the world.
pub fn tileDataAt(app: *App, map: Entity, point: math.Vec2, layer: []const u8) ?tileset.Value {
    const cell = cellAt(app, map, point) orelse return null;
    return tileData(app, map, cell.x, cell.y, layer);
}
