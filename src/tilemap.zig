// SPDX-License-Identifier: BSD-3-Clause

//! A grid of tiles from a tile set: the `TileMap` component.
//!
//! ```zig
//! const terrain = try app.loadTileSet("res://art/terrain.tileset");
//! const level = try app.world.spawnWith(.{ fx.Transform2D{}, fx.TileMap{ .tile_set = terrain } });
//! _ = try app.setTile(level, 3, 7, .at(0, 1, 0));
//! ```
//!
//! The cells live in `TileChunk` entities of sixteen by sixteen, because a
//! component may hold no list that grows: a chunk is culled as one, its solid
//! tiles become one static body, and a level larger than the screen is a
//! handful of draws. Chunks are the map's own - they are not in the tree, a
//! scene writes them as part of their map, and they go when it does.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");

const Color = @import("color.zig").Color;
const Region = @import("components.zig").Region;
const attr = @import("attr.zig");
const tileset = @import("tileset.zig");

pub const Entity = ecs.Entity;
pub const TileSetHandle = tileset.TileSetHandle;

/// How many tiles a chunk holds on a side.
pub const chunk_side = 16;
pub const tiles_per_chunk = chunk_side * chunk_side;

/// A grid of tiles drawn from one tile set. The tiles themselves are in its
/// `TileChunk`s; `App.setTile` and `App.tileAt` reach one by its coordinates.
pub const TileMap = extern struct {
    /// What the cells name their tiles in. Without one a map draws its cells
    /// as white squares its tint colours, and stops nothing.
    tile_set: TileSetHandle = .none,
    tint: Color = .white,
    /// Drawn with the sprites of this layer.
    layer: i16 = 0,
    /// Sorted by this inside the layer, as a `Sprite` is.
    order: f32 = 0,
    visible: bool = true,
    /// The layers its solid tiles are on, and those they stop. A map's own,
    /// kept on the TileMap rather than on each tile.
    collision_layer: u32 = 1,
    collision_mask: u32 = 1,
    friction: f32 = 0.5,
    bounce: f32 = 0,
    /// Whether its solid tiles - the shapes its tile set gives them - cast
    /// the shadows of the lights that have them.
    light_occlusion: bool = false,

    pub const reflect_name = "TileMap";
    pub const reflect_fields = .{
        .tile_set = .{attr.Doc{ .text = "The .tileset file its tiles come from" }},
        .collision_layer = .{attr.Layers{ .names = .physics_2d }},
        .collision_mask = .{attr.Layers{ .names = .physics_2d }},
        .friction = .{attr.Range{ .min = 0, .max = 1 }},
        .bounce = .{attr.Range{ .min = 0, .max = 1 }},
        .light_occlusion = .{attr.Doc{ .text = "Its solid tiles cast the shadows of lights" }},
    };
};

/// One tile of a map: which tile of which source, and how it is turned.
///
/// Four bytes, and the atlas coordinates rather than an index, so a tile
/// added to the sheet leaves every painted cell where it was.
pub const Cell = extern struct {
    /// Which source of the tile set. See `tileset.Source.id`.
    source: u8 = 0,
    /// Which column and row of that source's grid.
    x: u8 = 0,
    y: u8 = 0,
    flags: u8 = 0,

    /// Set on a cell that holds a tile at all: a zeroed cell is empty.
    pub const present: u8 = 1 << 0;
    pub const flip_h: u8 = 1 << 1;
    pub const flip_v: u8 = 1 << 2;
    /// Mirrored along its top-left to bottom-right diagonal, which with the
    /// flips is every quarter turn: the diagonal flip.
    pub const transpose: u8 = 1 << 3;

    pub const reflect_name = "Cell";

    pub const empty: Cell = .{};

    /// The tile at `x`, `y` of `source`, the way round the sheet has it.
    pub fn at(source: u8, x: u8, y: u8) Cell {
        return .{ .source = source, .x = x, .y = y, .flags = present };
    }

    pub fn isEmpty(self: Cell) bool {
        return self.flags & present == 0;
    }

    pub fn has(self: Cell, flag: u8) bool {
        return self.flags & flag != 0;
    }

    /// The same cell with one of the flags on or off.
    pub fn with(self: Cell, flag: u8, on: bool) Cell {
        var out = self;
        out.flags = if (on) self.flags | flag else self.flags & ~flag;
        return out;
    }

    pub fn eql(a: Cell, b: Cell) bool {
        return a.source == b.source and a.x == b.x and a.y == b.y and a.flags == b.flags;
    }
};

/// Sixteen by sixteen cells of one map. Not a node in the tree: `map` is
/// which map owns it, and the scene writes the cells with that map.
pub const TileChunk = extern struct {
    map: Entity = .none,
    /// Which chunk of the map, in chunks from its origin. Negative to the
    /// left of it and above it.
    x: i32 = 0,
    y: i32 = 0,
    /// Stepped whenever a cell changes, so the physics knows to build the
    /// chunk's body again. Never zero.
    revision: u32 = 1,
    cells: [tiles_per_chunk]Cell = @splat(.{}),

    pub const reflect_name = "TileChunk";
    pub const reflect_fields = .{
        .map = .{attr.Doc{ .text = "The TileMap these tiles belong to" }},
        .revision = .{attr.ReadOnly{}},
        .cells = .{attr.Hidden{}},
    };

    pub fn get(self: *const TileChunk, x: u8, y: u8) ?Cell {
        if (x >= chunk_side or y >= chunk_side) return null;
        return self.cells[@as(usize, y) * chunk_side + x];
    }

    /// Put a cell in, and say whether that changed anything.
    pub fn set(self: *TileChunk, x: u8, y: u8, cell: Cell) bool {
        if (x >= chunk_side or y >= chunk_side) return false;
        const at = @as(usize, y) * chunk_side + x;
        if (self.cells[at].eql(cell)) return false;
        self.cells[at] = cell;
        self.step();
        return true;
    }

    pub fn clear(self: *TileChunk) void {
        self.cells = @splat(.{});
        self.step();
    }

    /// Whether every cell of it is empty: one nothing draws, saves or stops
    /// at.
    pub fn isEmpty(self: *const TileChunk) bool {
        for (&self.cells) |cell| {
            if (!cell.isEmpty()) return false;
        }
        return true;
    }

    fn step(self: *TileChunk) void {
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }
};

// -------------------------------------------------------------------------
// Which way round a cell is
// -------------------------------------------------------------------------

/// Where a point of a tile's picture lands in the cell it is painted into,
/// both in fractions from the top left.
///
/// **The transpose comes first, and the flips after it**, in the cell's own
/// frame - the rule that makes "turn it a quarter" the same three flags
/// wherever the tile came from. Everything that has to agree on which way
/// round a cell is goes through here: the renderer places its corners this
/// way, and the physics places the corners of a tile's shape.
pub fn place(cell: Cell, u: f32, v: f32) [2]f32 {
    var x = u;
    var y = v;
    if (cell.has(Cell.transpose)) std.mem.swap(f32, &x, &y);
    if (cell.has(Cell.flip_h)) x = 1 - x;
    if (cell.has(Cell.flip_v)) y = 1 - y;
    return .{ x, y };
}

/// How the renderer draws one cell: the part of the texture, and whether the
/// quad is turned a quarter to the left.
///
/// A quarter turn is the one thing a flipped region cannot do on its own,
/// because the shader reads a corner's `u` from the quad's own `x`. So a
/// transposed cell is drawn turned, and the flips fold into the region
/// around that turn.
pub const Drawn = struct {
    region: Region,
    /// Whether the quad is turned a quarter anticlockwise about its middle,
    /// which also swaps how wide and how tall it is drawn.
    turned: bool,
};

pub fn drawn(cell: Cell, picture: Region) Drawn {
    var region = picture;
    if (!cell.has(Cell.transpose)) {
        if (cell.has(Cell.flip_h)) region = region.flippedX();
        if (cell.has(Cell.flip_v)) region = region.flippedY();
        return .{ .region = region, .turned = false };
    }
    // Turned, the quad's x reads the picture's v and its y reads the
    // picture's u backwards: the flips are the other way round, and the one
    // that undoes the turn's mirror is `flip_v`.
    if (cell.has(Cell.flip_h)) region = region.flippedY();
    if (!cell.has(Cell.flip_v)) region = region.flippedX();
    return .{ .region = region, .turned = true };
}

/// What a chunk's solid tiles make, one at a time: the tiles their set calls
/// `full` merged into as few boxes as they make, and each tile with a shape
/// of its own. What the physics builds a chunk's body from, and what a map's
/// shadows are cast by.
pub const Solids = struct {
    chunk: *const TileChunk,
    set: *const tileset.TileSet,
    used: [tiles_per_chunk]bool = @splat(false),
    at: usize = 0,

    /// In the chunk's cells, from its top left.
    pub const Solid = union(enum) {
        /// `width` cells across and `height` down from `x`, `y`.
        box: struct { x: usize, y: usize, width: usize, height: usize },
        /// The tile at `x`, `y`, whose `polygon` is turned as `cell` says:
        /// see `place`.
        polygon: struct { x: usize, y: usize, cell: Cell, tile: tileset.Tile },
    };

    pub fn next(self: *Solids) ?Solid {
        while (self.at < tiles_per_chunk) {
            const start = self.at;
            self.at += 1;
            if (self.used[start]) continue;
            const x = start % chunk_side;
            const y = start / chunk_side;
            const tile = self.set.tileOf(self.chunk.cells[start]);
            switch (tile.collision) {
                .none => continue,
                .polygon => {
                    self.used[start] = true;
                    return .{ .polygon = .{ .x = x, .y = y, .cell = self.chunk.cells[start], .tile = tile } };
                },
                .full => {},
            }

            // A run to the right, then as many rows below it as are full all
            // the way across.
            var width: usize = 1;
            while (x + width < chunk_side and self.fullAt(start + width)) : (width += 1) {}
            var height: usize = 1;
            rows: while (y + height < chunk_side) : (height += 1) {
                for (0..width) |across| if (!self.fullAt((y + height) * chunk_side + x + across)) break :rows;
            }
            for (0..height) |down| {
                for (0..width) |across| self.used[(y + down) * chunk_side + x + across] = true;
            }
            return .{ .box = .{ .x = x, .y = y, .width = width, .height = height } };
        }
        return null;
    }

    fn fullAt(self: *const Solids, index: usize) bool {
        return !self.used[index] and self.set.tileOf(self.chunk.cells[index]).collision == .full;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a chunk changes through one revisioned path, and says when it is empty" {
    var chunk: TileChunk = .{};
    const before = chunk.revision;
    try testing.expect(chunk.isEmpty());
    try testing.expect(chunk.set(2, 3, .at(1, 4, 5)));
    try testing.expectEqual(@as(u8, 4), chunk.get(2, 3).?.x);
    try testing.expect(chunk.revision != before);
    try testing.expect(!chunk.isEmpty());
    // The same cell again changes nothing.
    try testing.expect(!chunk.set(2, 3, .at(1, 4, 5)));
    try testing.expect(chunk.get(chunk_side, 0) == null);

    try testing.expect(chunk.set(2, 3, .empty));
    try testing.expect(chunk.isEmpty());
}

test "a flag is set and taken off without touching the tile" {
    const cell: Cell = .at(2, 3, 4);
    const flipped = cell.with(Cell.flip_h, true);
    try testing.expect(flipped.has(Cell.flip_h));
    try testing.expectEqual(@as(u8, 3), flipped.x);
    try testing.expect(!flipped.with(Cell.flip_h, false).has(Cell.flip_h));
    try testing.expect(!Cell.empty.has(Cell.present));
}

test "the corners the renderer draws are the ones `place` names" {
    // What the vertex shader does with what `drawn` gives it, in fractions
    // of one cell: every corner of the quad, and the picture it samples
    // there. The two have to agree, or a slope's shape and its picture point
    // different ways.
    const whole: Region = .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 };
    for ([_]u8{ 0, Cell.flip_h, Cell.flip_v, Cell.transpose }) |a| {
        for ([_]u8{ 0, Cell.flip_h, Cell.flip_v, Cell.transpose }) |b| {
            const cell: Cell = .{ .flags = Cell.present | a | b };
            const how = drawn(cell, whole);
            for ([_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |corner| {
                // `uv = mix(uv_rect.xy, uv_rect.zw, corner)`.
                const u = how.region.u0 + (how.region.u1 - how.region.u0) * corner[0];
                const v = how.region.v0 + (how.region.v1 - how.region.v0) * corner[1];
                // A turned quad's corner, about its middle: (x, y) becomes
                // (y, 1 - x).
                const at: [2]f32 = if (how.turned) .{ corner[1], 1 - corner[0] } else corner;
                const wanted = place(cell, u, v);
                try testing.expectApproxEqAbs(at[0], wanted[0], 1e-6);
                try testing.expectApproxEqAbs(at[1], wanted[1], 1e-6);
            }
        }
    }
}

test "a chunk's solid tiles are as few boxes as they make, and the shaped ones one each" {
    const App = @import("App.zig");
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const set = app.tile_sets.get(try app.tile_sets.add(app, "solid.tileset",
        \\{
        \\  "fluxion_tileset": 1,
        \\  "tile_size": [16, 16],
        \\  "sources": [{ "id": 0, "tiles": [
        \\    { "at": [0, 0], "collision": "full" },
        \\    { "at": [1, 0], "collision": "polygon", "polygon": [[0, 16], [16, 0], [16, 16]] }
        \\  ] }]
        \\}
    )).?;

    // A 3 by 2 block, a lone full tile and a slope; the picture-only tile
    // makes nothing.
    var chunk: TileChunk = .{};
    for (0..3) |x| for (0..2) |y| {
        _ = chunk.set(@intCast(x), @intCast(y), .at(0, 0, 0));
    };
    _ = chunk.set(5, 0, .at(0, 0, 0));
    _ = chunk.set(7, 7, .at(0, 1, 0));
    _ = chunk.set(9, 9, .at(0, 2, 0));

    var solids: Solids = .{ .chunk = &chunk, .set = set };
    const block = solids.next().?.box;
    try testing.expectEqual(@as(usize, 3), block.width);
    try testing.expectEqual(@as(usize, 2), block.height);
    const lone = solids.next().?.box;
    try testing.expectEqual(@as(usize, 5), lone.x);
    try testing.expectEqual(@as(usize, 1), lone.width * lone.height);
    const ramp = solids.next().?.polygon;
    try testing.expectEqual(@as(usize, 7), ramp.x);
    try testing.expectEqual(@as(usize, 3), ramp.tile.polygon().len);
    try testing.expect(solids.next() == null);
}

test "a quarter turn is the transpose and one flip" {
    // What the editor's rotate button will do: turning a tile to the right
    // takes its top left corner to its top right.
    const right: Cell = .{ .flags = Cell.present | Cell.transpose | Cell.flip_h };
    const corner = place(right, 0, 0);
    try testing.expectApproxEqAbs(@as(f32, 1), corner[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), corner[1], 1e-6);

    const left: Cell = .{ .flags = Cell.present | Cell.transpose | Cell.flip_v };
    const other = place(left, 0, 0);
    try testing.expectApproxEqAbs(@as(f32, 0), other[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), other[1], 1e-6);
}
