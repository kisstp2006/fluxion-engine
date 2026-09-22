// SPDX-License-Identifier: BSD-3-Clause

const ecs = @import("fluxion_ecs");

const Assets = @import("assets.zig");
const Color = @import("color.zig").Color;
const attr = @import("attr.zig");

pub const Entity = ecs.Entity;
pub const chunk_side = 16;
pub const tiles_per_chunk = chunk_side * chunk_side;

pub const TileMap = extern struct {
    texture: Assets.TextureHandle = .none,
    tile_width: u16 = 16,
    tile_height: u16 = 16,
    columns: u16 = 1,
    rows: u16 = 1,
    tint: Color = .white,
    layer: i16 = 0,
    order: f32 = 0,
    visible: bool = true,
    collision_layer: u32 = 1,
    collision_mask: u32 = 1,
    friction: f32 = 0.5,
    bounce: f32 = 0,

    pub const reflect_name = "TileMap";
    pub const reflect_fields = .{
        .tile_width = .{ attr.Range{ .min = 1, .max = 4096 }, attr.Unit{ .text = "px" } },
        .tile_height = .{ attr.Range{ .min = 1, .max = 4096 }, attr.Unit{ .text = "px" } },
        .columns = .{attr.Range{ .min = 1, .max = 4096 }},
        .rows = .{attr.Range{ .min = 1, .max = 4096 }},
        .collision_layer = .{attr.Layers{ .names = .physics_2d }},
        .collision_mask = .{attr.Layers{ .names = .physics_2d }},
        .friction = .{attr.Range{ .min = 0, .max = 1 }},
        .bounce = .{attr.Range{ .min = 0, .max = 1 }},
    };
};

pub const Tile = extern struct {
    atlas: u16 = 0,
    solid: bool = false,
    flip_x: bool = false,
    flip_y: bool = false,

    pub fn of(atlas_index: u16) Tile {
        return .{ .atlas = atlas_index +| 1 };
    }

    pub fn isEmpty(self: Tile) bool {
        return self.atlas == 0;
    }

    pub fn atlasIndex(self: Tile) u16 {
        return self.atlas -| 1;
    }
};

pub const TileChunk = extern struct {
    map: Entity = .none,
    x: i32 = 0,
    y: i32 = 0,
    revision: u32 = 1,
    tiles: [tiles_per_chunk]Tile = .{Tile{}} ** tiles_per_chunk,

    pub const reflect_name = "TileChunk";

    pub fn get(self: *const TileChunk, x: u8, y: u8) ?Tile {
        if (x >= chunk_side or y >= chunk_side) return null;
        return self.tiles[@as(usize, y) * chunk_side + x];
    }

    pub fn set(self: *TileChunk, x: u8, y: u8, tile: Tile) bool {
        if (x >= chunk_side or y >= chunk_side) return false;
        const at = @as(usize, y) * chunk_side + x;
        if (self.tiles[at].atlas == tile.atlas and self.tiles[at].solid == tile.solid and self.tiles[at].flip_x == tile.flip_x and self.tiles[at].flip_y == tile.flip_y) return false;
        self.tiles[at] = tile;
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
        return true;
    }

    pub fn clear(self: *TileChunk) void {
        self.tiles = .{Tile{}} ** tiles_per_chunk;
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }
};

test "a tile chunk changes through one revisioned data path" {
    const testing = @import("std").testing;
    var chunk: TileChunk = .{};
    const before = chunk.revision;
    try testing.expect(chunk.set(2, 3, .{ .atlas = 5, .solid = true }));
    try testing.expectEqual(@as(u16, 5), chunk.get(2, 3).?.atlas);
    try testing.expect(chunk.get(2, 3).?.solid);
    try testing.expect(chunk.revision != before);
    try testing.expect(!chunk.set(2, 3, .{ .atlas = 5, .solid = true }));
    try testing.expect(chunk.get(chunk_side, 0) == null);
}
