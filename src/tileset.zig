// SPDX-License-Identifier: BSD-3-Clause

//! The tiles a `TileMap` is painted with, as a file describes them: Godot's
//! TileSet resource.
//!
//! ```json
//! {
//!   "fluxion_tileset": 1,
//!   "tile_size": [16, 16],
//!   "sources": [{
//!     "id": 0, "texture": "res://art/terrain.png", "margin": [0, 0], "separation": [0, 0],
//!     "tiles": [
//!       { "at": [0, 0], "collision": "full" },
//!       { "at": [2, 0], "collision": "polygon", "polygon": [[0, 16], [16, 0], [16, 16]] }
//!     ]
//!   }]
//! }
//! ```
//!
//! A source is one sheet cut into a grid of tiles. Every cell of the grid is a
//! tile a map can hold; `tiles` lists only those with something more to say,
//! such as a shape the physics stops at. A source without a texture is one
//! tile of the white texel, which a map's tint colours: blocking out a level
//! before its art exists.
//!
//! Kept beside the world, as scripts are, and pointed at by a handle: a
//! component holds no memory. A file that does not read still gets a handle,
//! and says why in the log, so a scene naming it still opens.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const id = @import("fluxion_id");
const json = @import("fluxion_json");
const math = @import("fluxion_math");

const App = @import("App.zig");
const Assets = @import("assets.zig");
const Project = @import("Project.zig");
const Region = @import("components.zig").Region;
const Cell = @import("tilemap.zig").Cell;

const log = std.log.scoped(.fluxion_engine);

/// What a tile set's file ends in.
pub const extension = ".tileset";

/// The version this reads.
pub const version = 1;

/// A tile's size, in pixels, where there is no tile set to say.
pub const default_tile_size = 16;

/// The most corners a tile's shape may have: as many as the physics' polygons.
pub const max_points = 8;

/// The largest tile set file read.
const file_limit = 4 << 20;

/// A `.tileset` file, the way a `TextureHandle` is a picture.
pub const TileSetHandle = extern struct {
    index: u32 = 0,
    generation: u32 = 0,

    pub const none: TileSetHandle = .{};

    /// A tool shows `App.tileSetSource` instead, as for a texture.
    pub const reflect_name = "TileSetHandle";

    pub fn isNone(self: TileSetHandle) bool {
        return self.generation == 0;
    }

    pub fn eql(a: TileSetHandle, b: TileSetHandle) bool {
        return a.index == b.index and a.generation == b.generation;
    }

    fn toId(self: TileSetHandle) Table.Handle {
        return @bitCast(self);
    }

    fn fromId(handle: Table.Handle) TileSetHandle {
        return @bitCast(handle);
    }
};

const Table = id.handle.Table(TileSet);

/// What the physics stops at in a tile.
pub const Collision = enum {
    /// Nothing: the tile is only a picture.
    none,
    /// The whole tile. Neighbours of this kind are merged into one box.
    full,
    /// The corners `Tile.points` give: a slope, a half-height ledge.
    polygon,
};

/// What one tile of a source is, beyond its picture.
pub const Tile = struct {
    collision: Collision = .none,
    /// Corners in the tile's own pixels, from its top left, as the sheet has
    /// it: before a cell flips or turns it. Used when `collision` is
    /// `.polygon`.
    points: [max_points]math.Vec2 = @splat(.zero),
    point_count: u8 = 0,

    pub fn polygon(self: *const Tile) []const math.Vec2 {
        return self.points[0..self.point_count];
    }

    /// Whether nothing is said of this tile beyond its picture, so that a
    /// source need not keep it and a file need not name it.
    pub fn isPlain(self: *const Tile) bool {
        return self.collision == .none;
    }

    /// The corners a shape is drawn round, keeping at most `max_points` of
    /// them. Fewer than three is no shape at all.
    pub fn setPolygon(self: *Tile, points: []const math.Vec2) void {
        self.point_count = @intCast(@min(points.len, max_points));
        for (points[0..self.point_count], 0..) |point, i| self.points[i] = point;
        if (self.point_count < 3) {
            self.point_count = 0;
            self.collision = .none;
        } else {
            self.collision = .polygon;
        }
    }
};

/// One sheet, cut into a grid of tiles.
pub const Source = struct {
    /// What a cell calls it by: `Cell.source`.
    id: u8,
    /// `.none` for a source of one untextured tile.
    texture: Assets.TextureHandle = .none,
    /// Pixels to pass over at the sheet's left and top before the first tile.
    margin_x: u16 = 0,
    margin_y: u16 = 0,
    /// Pixels between one tile and the next.
    separation_x: u16 = 0,
    separation_y: u16 = 0,
    /// The tiles something is said of, by `key`.
    tiles: std.AutoHashMapUnmanaged(u16, Tile) = .empty,

    fn key(x: u8, y: u8) u16 {
        return @as(u16, y) << 8 | x;
    }

    /// Say something of the tile at `x`, `y`; a tile with nothing to say is
    /// forgotten, so that a set holds only what it means.
    pub fn setTileAt(self: *Source, gpa: Allocator, x: u8, y: u8, tile: Tile) Allocator.Error!void {
        if (tile.isPlain()) {
            _ = self.tiles.remove(key(x, y));
            return;
        }
        try self.tiles.put(gpa, key(x, y), tile);
    }

    /// What the tile at column `x` and row `y` is. One nothing is said of has
    /// no shape.
    pub fn tileAt(self: *const Source, x: u8, y: u8) Tile {
        return self.tiles.get(key(x, y)) orelse .{};
    }

    /// How many tiles across and down the sheet holds: one of each without a
    /// texture, or with one that has not loaded.
    pub fn grid(self: *const Source, assets: *Assets, tile_width: u16, tile_height: u16) struct { columns: u16, rows: u16 } {
        const size = assets.sizeOf(self.texture) orelse return .{ .columns = 1, .rows = 1 };
        return .{
            .columns = count(size.width, self.margin_x, tile_width, self.separation_x),
            .rows = count(size.height, self.margin_y, tile_height, self.separation_y),
        };
    }

    fn count(extent: f32, margin: u16, tile: u16, separation: u16) u16 {
        const room = extent - @as(f32, @floatFromInt(margin)) + @as(f32, @floatFromInt(separation));
        const step: f32 = @floatFromInt(@max(@as(u32, tile) + separation, 1));
        return @intFromFloat(std.math.clamp(@floor(room / step), 1, 256));
    }

    fn deinit(self: *Source, gpa: Allocator) void {
        self.tiles.deinit(gpa);
    }
};

/// What to draw a cell with: a texture and the part of it.
pub const Picture = struct {
    texture: Assets.TextureHandle,
    region: Region,
};

/// A tile set, as read from its file.
pub const TileSet = struct {
    /// The path it was read from, as `Project.canonical` spells it, or the
    /// name it was given.
    source: []const u8,
    /// Whether there is a file to read again, or only text it was given.
    on_disc: bool,
    tile_width: u16 = default_tile_size,
    tile_height: u16 = default_tile_size,
    sources: std.ArrayList(Source) = .empty,
    /// Stepped whenever what it says changes, so what was built from it -
    /// a map's physics - knows to build again.
    revision: u32 = 1,

    pub fn sourceById(self: *const TileSet, source_id: u8) ?*const Source {
        for (self.sources.items) |*held| {
            if (held.id == source_id) return held;
        }
        return null;
    }

    /// The same, to change: for the tile set editor.
    pub fn sourceMut(self: *TileSet, source_id: u8) ?*Source {
        for (self.sources.items) |*held| {
            if (held.id == source_id) return held;
        }
        return null;
    }

    /// Say that what the set holds has changed, so that what was built from
    /// it - a map's physics - is built again.
    pub fn touched(self: *TileSet) void {
        self.revision +%= 1;
    }

    /// Add a sheet, numbered with the lowest number no source has, and answer
    /// that number. A set holds at most 256 sources: a cell names one in a
    /// byte.
    pub fn addSource(self: *TileSet, gpa: Allocator, texture: Assets.TextureHandle) !u8 {
        var number: u16 = 0;
        while (number < 256) : (number += 1) {
            if (self.sourceById(@intCast(number)) == null) break;
        } else return error.TooManySources;
        try self.sources.append(gpa, .{ .id = @intCast(number), .texture = texture });
        return @intCast(number);
    }

    /// Take a sheet out. Cells that named it draw the white texel until they
    /// are painted again, as they do for a source a file never had.
    pub fn removeSource(self: *TileSet, gpa: Allocator, source_id: u8) void {
        for (self.sources.items, 0..) |*held, at| {
            if (held.id != source_id) continue;
            held.deinit(gpa);
            _ = self.sources.orderedRemove(at);
            return;
        }
    }

    /// What the tile a cell holds is. An empty cell, or one naming a source
    /// the set has not got, is a tile with no shape.
    pub fn tileOf(self: *const TileSet, cell: Cell) Tile {
        if (cell.isEmpty()) return .{};
        const held = self.sourceById(cell.source) orelse return .{};
        return held.tileAt(cell.x, cell.y);
    }

    /// The part of which texture a cell shows, before it flips or turns. A
    /// source the set has not got, or one with no texture, shows the white
    /// texel.
    pub fn pictureOf(self: *const TileSet, assets: *Assets, cell: Cell) Picture {
        const white: Picture = .{ .texture = assets.white, .region = .full };
        const held = self.sourceById(cell.source) orelse return white;
        const size = assets.sizeOf(held.texture) orelse return white;
        const tile_width: f32 = @floatFromInt(self.tile_width);
        const tile_height: f32 = @floatFromInt(self.tile_height);
        const x = @as(f32, @floatFromInt(held.margin_x)) + @as(f32, @floatFromInt(cell.x)) * (tile_width + @as(f32, @floatFromInt(held.separation_x)));
        const y = @as(f32, @floatFromInt(held.margin_y)) + @as(f32, @floatFromInt(cell.y)) * (tile_height + @as(f32, @floatFromInt(held.separation_y)));
        return .{ .texture = held.texture, .region = .fromPixels(x, y, tile_width, tile_height, size.width, size.height) };
    }

    fn deinitContent(self: *TileSet, gpa: Allocator) void {
        for (self.sources.items) |*held| held.deinit(gpa);
        self.sources.deinit(gpa);
    }
};

/// Every tile set read, and the handles they are found by.
pub const TileSets = struct {
    table: Table = .empty,

    pub fn deinit(self: *TileSets, gpa: Allocator) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            entry.value.deinitContent(gpa);
            gpa.free(entry.value.source);
        }
        self.table.deinit(gpa);
    }

    /// Read a `.tileset` file, or find the one read from there already. A
    /// file that reads and does not make sense is kept, empty, and why is
    /// said in the log.
    pub fn load(self: *TileSets, app: *App, path: []const u8) !TileSetHandle {
        const io = app.io orelse return error.NoIo;
        const source = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(source);
        if (self.find(source)) |known| return known;

        const file = try app.project.osPath(app.gpa, source);
        defer app.gpa.free(file);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, file, app.gpa, .limited(file_limit));
        defer app.gpa.free(text);
        if (Project.isProjectPath(source)) {
            _ = app.project.uidOf(source) catch |err|
                log.warn("the {s} file beside {s} does not read: {t}", .{ Project.uid_extension, source, err });
        }
        return self.keep(app, source, text, true);
    }

    /// A tile set from text, not a file: a test's, or a tool's. `name` is
    /// what the log and a scene call it. A name given before gets the new
    /// text.
    pub fn add(self: *TileSets, app: *App, name: []const u8, text: []const u8) !TileSetHandle {
        if (self.find(name)) |known| {
            try self.setText(app, known, text);
            return known;
        }
        return self.keep(app, name, text, false);
    }

    fn keep(self: *TileSets, app: *App, source: []const u8, text: []const u8, on_disc: bool) !TileSetHandle {
        const gpa = app.gpa;
        const name = try gpa.dupe(u8, source);
        errdefer gpa.free(name);
        var made: TileSet = .{ .source = name, .on_disc = on_disc };
        read(app, &made, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Said already; kept empty, so what names it still opens.
            else => {},
        };
        errdefer made.deinitContent(gpa);
        return .fromId(try self.table.add(gpa, made));
    }

    /// New text for a tile set: an editor's, before it saves. Text that does
    /// not make sense leaves what the set said before, and says why.
    pub fn setText(self: *TileSets, app: *App, handle: TileSetHandle, text: []const u8) !void {
        const held = self.table.get(handle.toId()) orelse return error.NoSuchTileSet;
        var fresh: TileSet = .{ .source = held.source, .on_disc = held.on_disc, .revision = held.revision +% 1 };
        read(app, &fresh, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        held.deinitContent(app.gpa);
        held.* = fresh;
    }

    /// Read a set's file again. Says whether there was a file to read.
    pub fn reload(self: *TileSets, app: *App, handle: TileSetHandle) !bool {
        const held = self.table.get(handle.toId()) orelse return false;
        if (!held.on_disc) return false;
        const io = app.io orelse return error.NoIo;
        const file = try app.project.osPath(app.gpa, held.source);
        defer app.gpa.free(file);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, file, app.gpa, .limited(file_limit));
        defer app.gpa.free(text);
        try self.setText(app, handle, text);
        return true;
    }

    /// The handle of a set read already, by the path or name it was read by.
    pub fn find(self: *TileSets, source: []const u8) ?TileSetHandle {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value.source, source)) return .fromId(entry.handle);
        }
        return null;
    }

    pub fn get(self: *TileSets, handle: TileSetHandle) ?*const TileSet {
        return self.table.get(handle.toId());
    }

    /// A set to change, for a tool: the tile set editor. Whoever changes one
    /// calls `TileSet.touched` when it is done.
    pub fn edit(self: *TileSets, handle: TileSetHandle) ?*TileSet {
        return self.table.get(handle.toId());
    }

    /// The set as its file would be, into fresh memory: what an editor saves,
    /// and what it keeps to undo by. The caller frees it.
    pub fn textOf(self: *TileSets, app: *App, gpa: Allocator, handle: TileSetHandle) ![]u8 {
        const held = self.table.get(handle.toId()) orelse return error.NoSuchTileSet;
        return json.stringify(gpa, Document{ .set = held, .assets = &app.assets }, write_options);
    }

    /// Write a set back to the file it was read from, and give it a UUID if
    /// it has none, as saving a scene does.
    pub fn save(self: *TileSets, app: *App, handle: TileSetHandle) !void {
        const io = app.io orelse return error.NoIo;
        const held = self.table.get(handle.toId()) orelse return error.NoSuchTileSet;
        if (!held.on_disc) return error.NotAFile;
        const file = try app.project.osPath(app.gpa, held.source);
        defer app.gpa.free(file);
        try json.save(io, file, Document{ .set = held, .assets = &app.assets }, write_options);
        if (Project.isProjectPath(held.source)) _ = try app.project.ensureUid(held.source);
    }

    pub fn sourceOf(self: *TileSets, handle: TileSetHandle) ?[]const u8 {
        const held = self.table.get(handle.toId()) orelse return null;
        return held.source;
    }

    /// Give each set of the project's that has no UUID one, in a `.uid` file
    /// beside it, as `Assets.ensureUids` does for textures.
    pub fn ensureUids(self: *TileSets, project: *Project) !void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (entry.value.on_disc and Project.isProjectPath(entry.value.source)) _ = try project.ensureUid(entry.value.source);
        }
    }

    /// The file or folder at `old` is now at `new`: a set read from under it
    /// is found at its new place.
    pub fn renamed(self: *TileSets, gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (!entry.value.on_disc) continue;
            const rest = Project.under(entry.value.source, old) orelse continue;
            const moved = try std.mem.concat(gpa, u8, &.{ new, rest });
            gpa.free(entry.value.source);
            entry.value.source = moved;
        }
    }
};

// -------------------------------------------------------------------------
// Writing
// -------------------------------------------------------------------------

/// Two spaces and a newline, as the rest of the project's files are written.
const write_options: json.WriteOptions = .{ .indent = 2 };

/// A tile set as its file, for `json.save` and `json.stringify`. Only what
/// differs from the default is written, as a scene is written.
const Document = struct {
    set: *const TileSet,
    assets: *Assets,

    pub fn toJson(self: Document, w: *json.Writer) json.Writer.Error!void {
        try w.beginObject();
        try w.field("fluxion_tileset", @as(u32, version));
        try w.field("tile_size", [2]u16{ self.set.tile_width, self.set.tile_height });
        try w.key("sources");
        try w.beginArray();
        for (self.set.sources.items) |*source| try self.writeSource(w, source);
        try w.endArray();
        try w.endObject();
    }

    fn writeSource(self: Document, w: *json.Writer, source: *const Source) json.Writer.Error!void {
        try w.beginObject();
        try w.field("id", source.id);
        if (self.assets.get(source.texture)) |texture| try w.field("texture", texture.source);
        if (source.margin_x != 0 or source.margin_y != 0) try w.field("margin", [2]u16{ source.margin_x, source.margin_y });
        if (source.separation_x != 0 or source.separation_y != 0) try w.field("separation", [2]u16{ source.separation_x, source.separation_y });
        try w.key("tiles");
        try w.beginArray();
        // Over every place a tile may be, in reading order, rather than over
        // the map that holds them: a map has no order of its own, and a file
        // that changes when nothing did is a file that fights its history.
        var y: u16 = 0;
        while (y < 256) : (y += 1) {
            var x: u16 = 0;
            while (x < 256) : (x += 1) {
                const tile = source.tiles.get(Source.key(@intCast(x), @intCast(y))) orelse continue;
                try writeTile(w, @intCast(x), @intCast(y), tile);
            }
        }
        try w.endArray();
        try w.endObject();
    }

    fn writeTile(w: *json.Writer, x: u8, y: u8, tile: Tile) json.Writer.Error!void {
        try w.beginObject();
        try w.field("at", [2]u8{ x, y });
        try w.field("collision", tile.collision);
        if (tile.collision == .polygon) {
            try w.key("polygon");
            try w.beginArray();
            for (tile.points[0..tile.point_count]) |point| try w.write([2]f32{ point.x, point.y });
            try w.endArray();
        }
        try w.endObject();
    }
};

// -------------------------------------------------------------------------
// Reading
// -------------------------------------------------------------------------

/// The file as `fluxion_json` reads it.
const FileShape = struct {
    fluxion_tileset: u32,
    tile_size: [2]u16 = .{ default_tile_size, default_tile_size },
    sources: []const SourceShape = &.{},
};

const SourceShape = struct {
    id: u8 = 0,
    texture: ?[]const u8 = null,
    margin: [2]u16 = .{ 0, 0 },
    separation: [2]u16 = .{ 0, 0 },
    tiles: []const TileShape = &.{},
};

const TileShape = struct {
    at: [2]u8,
    collision: Collision = .none,
    polygon: []const [2]f32 = &.{},
};

/// Fill `into`, which has no content yet, from a file's text. What does not
/// make sense is said in the log, and leaves it empty.
fn read(app: *App, into: *TileSet, text: []const u8) !void {
    const gpa = app.gpa;
    var diagnostics: json.Diagnostics = .{};
    diagnostics.setFile(into.source);
    const parsed = json.parseAs(FileShape, gpa, text, .{
        .syntax = .json5,
        .unknown_fields = .fail,
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.warn("{f}", .{diagnostics});
            return err;
        },
    };
    defer parsed.deinit();
    const shape = parsed.value;
    if (shape.fluxion_tileset != version) {
        log.warn("{s} is tile set version {d}, and this engine reads version {d}", .{ into.source, shape.fluxion_tileset, version });
        return error.UnsupportedVersion;
    }

    errdefer into.deinitContent(gpa);
    into.tile_width = @max(shape.tile_size[0], 1);
    into.tile_height = @max(shape.tile_size[1], 1);
    for (shape.sources) |given| {
        if (into.sourceById(given.id) != null) {
            log.warn("{s} has two sources numbered {d}; the second is passed over", .{ into.source, given.id });
            continue;
        }
        var made: Source = .{
            .id = given.id,
            .margin_x = given.margin[0],
            .margin_y = given.margin[1],
            .separation_x = given.separation[0],
            .separation_y = given.separation[1],
        };
        errdefer made.deinit(gpa);
        if (given.texture) |path| made.texture = app.assets.findTexture(path) orelse app.assets.loadTexture(path, .{}) catch |err| blk: {
            log.warn("{s}: the texture {s} does not read: {t}", .{ into.source, path, err });
            break :blk .none;
        };
        for (given.tiles) |tile| {
            var kept: Tile = .{ .collision = tile.collision };
            if (tile.collision == .polygon) {
                if (tile.polygon.len < 3 or tile.polygon.len > max_points) {
                    log.warn("{s}: the shape of tile ({d}, {d}) has {d} corners, and one has 3 to {d}; it has none", .{ into.source, tile.at[0], tile.at[1], tile.polygon.len, max_points });
                    kept.collision = .none;
                } else {
                    for (tile.polygon, 0..) |point, i| kept.points[i] = .init(point[0], point[1]);
                    kept.point_count = @intCast(tile.polygon.len);
                }
            }
            try made.tiles.put(gpa, Source.key(tile.at[0], tile.at[1]), kept);
        }
        try into.sources.append(gpa, made);
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const slope =
    \\{
    \\  "fluxion_tileset": 1,
    \\  "tile_size": [16, 16],
    \\  "sources": [{
    \\    "id": 0,
    \\    "tiles": [
    \\      { "at": [0, 0], "collision": "full" },
    \\      { "at": [1, 0], "collision": "polygon", "polygon": [[0, 16], [16, 0], [16, 16]] },
    \\    ]
    \\  }]
    \\}
;

test "a tile set says each tile's shape, and nothing of the rest" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const set = try app.tile_sets.add(app, "slope.tileset", slope);
    const read_back = app.tile_sets.get(set).?;

    try testing.expectEqual(@as(u16, 16), read_back.tile_width);
    try testing.expectEqual(Collision.full, read_back.tileOf(.at(0, 0, 0)).collision);
    const ramp = read_back.tileOf(.at(0, 1, 0));
    try testing.expectEqual(Collision.polygon, ramp.collision);
    try testing.expectEqual(@as(usize, 3), ramp.polygon().len);
    try testing.expectEqual(Collision.none, read_back.tileOf(.at(0, 5, 5)).collision);
    try testing.expectEqual(Collision.none, read_back.tileOf(.at(9, 0, 0)).collision);
    try testing.expectEqual(Collision.none, read_back.tileOf(.empty).collision);
    // No texture: one tile of the white texel.
    const picture = read_back.pictureOf(&app.assets, .at(0, 0, 0));
    try testing.expect(picture.texture.eql(app.assets.white));
}

test "a tile set that does not read is kept empty, and new text that does not read leaves the old" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    const broken = try app.tile_sets.add(app, "broken.tileset", "{ \"fluxion_tileset\": 1, \"tile_sise\": [8, 8] }");
    try testing.expectEqual(@as(usize, 0), app.tile_sets.get(broken).?.sources.items.len);

    const set = try app.tile_sets.add(app, "slope.tileset", slope);
    const before = app.tile_sets.get(set).?.revision;
    try app.tile_sets.setText(app, set, "{ not a tile set");
    try testing.expectEqual(before, app.tile_sets.get(set).?.revision);
    try testing.expectEqual(Collision.full, app.tile_sets.get(set).?.tileOf(.at(0, 0, 0)).collision);

    try app.tile_sets.setText(app, set, "{ \"fluxion_tileset\": 1, \"tile_size\": [32, 32] }");
    try testing.expect(app.tile_sets.get(set).?.revision != before);
    try testing.expectEqual(@as(u16, 32), app.tile_sets.get(set).?.tile_width);
}

test "a set written back reads as the set it was, with what an editor changed" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const handle = try app.tile_sets.add(app, "slope.tileset", slope);

    // What the editor does: another sheet, a tile given a shape, and the
    // first tile's shape taken away again.
    const set = app.tile_sets.edit(handle).?;
    const second = try set.addSource(app.gpa, .none);
    try testing.expectEqual(@as(u8, 1), second);
    const source = set.sourceMut(0).?;
    try source.setTileAt(app.gpa, 0, 0, .{});
    var ledge: Tile = .{};
    ledge.setPolygon(&.{ .init(0, 8), .init(16, 8), .init(16, 16), .init(0, 16) });
    try source.setTileAt(app.gpa, 2, 1, ledge);
    set.touched();

    const text = try app.tile_sets.textOf(app, testing.allocator, handle);
    defer testing.allocator.free(text);
    const again = app.tile_sets.get(try app.tile_sets.add(app, "again.tileset", text)).?;

    try testing.expectEqual(@as(usize, 2), again.sources.items.len);
    try testing.expectEqual(@as(u16, 16), again.tile_width);
    // The tile nothing is said of any more is gone; the slope is as it was.
    try testing.expectEqual(Collision.none, again.tileOf(.at(0, 0, 0)).collision);
    try testing.expectEqual(@as(usize, 3), again.tileOf(.at(0, 1, 0)).polygon().len);
    const kept = again.tileOf(.at(0, 2, 1));
    try testing.expectEqual(Collision.polygon, kept.collision);
    try testing.expectEqual(@as(usize, 4), kept.polygon().len);
    try testing.expectEqual(@as(f32, 8), kept.polygon()[0].y);

    // Written twice, the same file both times.
    const twice = try app.tile_sets.textOf(app, testing.allocator, handle);
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings(text, twice);
}

test "a shape of fewer than three corners is no shape" {
    var tile: Tile = .{ .collision = .full };
    tile.setPolygon(&.{ .init(0, 0), .init(8, 8) });
    try testing.expectEqual(Collision.none, tile.collision);
    try testing.expectEqual(@as(usize, 0), tile.polygon().len);
    try testing.expect(tile.isPlain());
}

test "a sheet is cut past its margin, with the separation between tiles" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const sheet = try app.assets.textureFromPixels(36, 20, &(.{255} ** (36 * 20 * 4)), .{});
    var set: TileSet = .{ .source = "sheet", .on_disc = false, .tile_width = 8, .tile_height = 8 };
    defer set.deinitContent(testing.allocator);
    try set.sources.append(testing.allocator, .{ .id = 3, .texture = sheet, .margin_x = 2, .margin_y = 2, .separation_x = 1, .separation_y = 1 });

    const grid = set.sources.items[0].grid(&app.assets, 8, 8);
    try testing.expectEqual(@as(u16, 3), grid.columns);
    try testing.expectEqual(@as(u16, 2), grid.rows);

    const picture = set.pictureOf(&app.assets, .at(3, 1, 1));
    try testing.expectApproxEqAbs(@as(f32, 11.0 / 36.0), picture.region.u0, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 11.0 / 20.0), picture.region.v0, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 19.0 / 36.0), picture.region.u1, 1e-6);
}
