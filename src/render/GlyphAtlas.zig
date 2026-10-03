// SPDX-License-Identifier: BSD-3-Clause

//! Every glyph the game has drawn, in one texture.
//!
//! ```zig
//! var atlas: Atlas = try .init(gpa, 512, 512);
//! defer atlas.deinit();
//!
//! const entry = try atlas.glyph(&face, face.glyphFor('H'), 16);
//! ```
//!
//! Each glyph is rasterised once and packed into a shared image, so all the
//! text in a frame is instances of one quad against one texture. Keyed by
//! glyph, whole-pixel size, and how far an outline grown from it reaches.
//! White pixels with the coverage in the alpha,
//! so a glyph is a picture like any other and the sprite shader needs no
//! special case. Packed on shelves, which suits glyphs of one size: they are
//! nearly all the same height.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const font = @import("fluxion_font");

const Atlas = @This();

pub const Error = error{
    /// The atlas is full. A bigger one, or a game that draws fewer sizes.
    AtlasFull,
} || Allocator.Error || font.Font.Error;

/// Where one glyph ended up, and everything needed to place it.
pub const Entry = struct {
    /// Its corners in the texture, from zero to one.
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,

    /// How big it is, in pixels.
    width: f32,
    height: f32,

    /// How far right of the pen its left edge is.
    left: f32,
    /// How far above the baseline its top row is.
    top: f32,
    /// How far the pen moves afterwards.
    advance: f32,
};

/// One glyph at one size, and how far its outline reaches, as a number.
const Key = u64;

inline fn keyOf(index: u16, size: u16, reach: u16) Key {
    return (@as(Key, reach) << 32) | (@as(Key, size) << 16) | index;
}

/// The furthest an outline reaches from its glyph, in pixels: one asked to
/// reach further reaches this far.
pub const max_outline: u16 = 64;

/// A blank pixel between glyphs, so a linear sampler at one glyph's edge does
/// not read its neighbour. One is enough without mip-maps.
const padding: u32 = 1;

gpa: Allocator,

width: u32,
height: u32,
/// Four bytes a pixel, white throughout, with the coverage in the alpha.
pixels: []u8,

/// Whether anything has been added since the texture was last uploaded.
dirty: bool = false,

/// Tells what this atlas holds from what any atlas held before: new with
/// each atlas and each `clear`, so what was laid out against it knows
/// whether the places it found in the image still hold.
generation: u64,

/// The shelf being filled: how far up the image it starts, how tall it is,
/// and how far along it the next glyph goes.
shelf_top: u32 = padding,
shelf_height: u32 = 0,
pen: u32 = padding,

entries: std.AutoHashMapUnmanaged(Key, Entry) = .empty,

pub fn init(gpa: Allocator, width: u32, height: u32) Allocator.Error!Atlas {
    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    // White and transparent everywhere, so a glyph only writes its alpha.
    for (0..pixels.len / 4) |i| {
        pixels[i * 4 + 0] = 255;
        pixels[i * 4 + 1] = 255;
        pixels[i * 4 + 2] = 255;
        pixels[i * 4 + 3] = 0;
    }

    return .{
        .gpa = gpa,
        .width = width,
        .height = height,
        .pixels = pixels,
        .generation = nextGeneration(),
    };
}

/// The last `generation` handed out, in the whole program: a word, which
/// every target has atomics for.
var generations: std.atomic.Value(usize) = .init(0);

fn nextGeneration() u64 {
    return @as(u64, generations.fetchAdd(1, .monotonic)) + 1;
}

pub fn deinit(self: *Atlas) void {
    self.entries.deinit(self.gpa);
    self.gpa.free(self.pixels);
    self.* = undefined;
}

/// Bytes from one row of `pixels` to the next.
pub fn rowPitch(self: Atlas) usize {
    return @as(usize, self.width) * 4;
}

/// The texture has been uploaded; stop saying it has not.
pub fn markClean(self: *Atlas) void {
    self.dirty = false;
}

/// Where this glyph is in the atlas, rasterising it the first time it is
/// asked for. `size` is in whole pixels per em. The face is passed in rather
/// than held, because the font table may move.
pub fn glyph(self: *Atlas, face: *const font.Font, index: u16, size: u16) Error!Entry {
    return self.entryOf(face, index, size, 0);
}

/// The same glyph's outline: its shape grown by `reach` pixels all round,
/// as smooth at its edge as the glyph is at its own, to be drawn under it in
/// another colour. At most `max_outline`.
pub fn outline(self: *Atlas, face: *const font.Font, index: u16, size: u16, reach: u16) Error!Entry {
    return self.entryOf(face, index, size, @min(reach, max_outline));
}

fn entryOf(self: *Atlas, face: *const font.Font, index: u16, size: u16, reach: u16) Error!Entry {
    const key = keyOf(index, size, reach);
    if (self.entries.get(key)) |entry| return entry;

    var rendered = try face.render(self.gpa, index, face.scaleFor(@floatFromInt(size)));
    defer rendered.deinit(self.gpa);
    if (reach > 0) try grow(self.gpa, &rendered, reach);

    const entry = try self.place(rendered);
    try self.entries.put(self.gpa, key, entry);
    return entry;
}

/// A glyph grown into its outline: each pixel as covered as it is within
/// `reach` of the glyph's edge, with half a pixel's blend at the outline's
/// own edge. The distance is a Euclidean distance transform of the
/// coverage - squared distances along each column, then along each row -
/// so a wide outline costs no more a pixel than a thin one. A pixel the
/// glyph's edge crosses starts half a pixel less its coverage from it.
fn grow(gpa: Allocator, rendered: *font.Rendered, reach: u16) Allocator.Error!void {
    const inner = rendered.bitmap;
    if (inner.isEmpty()) return;
    const r: u32 = reach;
    const width = inner.width + 2 * r;
    const height = inner.height + 2 * r;

    const squared = try gpa.alloc(f32, @as(usize, width) * height);
    defer gpa.free(squared);
    for (0..height) |y| for (0..width) |x| {
        const coverage: u8 = if (x < r or y < r) 0 else inner.at(@intCast(x - r), @intCast(y - r));
        const within = 0.5 - @as(f32, @floatFromInt(coverage)) / 255;
        squared[y * width + x] = switch (coverage) {
            255 => 0,
            0 => far,
            else => if (within > 0) within * within else 0,
        };
    };

    const longest = @max(width, height);
    const line = try gpa.alloc(f32, longest);
    defer gpa.free(line);
    const parabolas = try gpa.alloc(u32, longest);
    defer gpa.free(parabolas);
    const bounds = try gpa.alloc(f32, longest + 1);
    defer gpa.free(bounds);
    for (0..width) |x| alongLine(squared, x, width, height, line, parabolas, bounds);
    for (0..height) |y| alongLine(squared, y * width, 1, width, line, parabolas, bounds);

    const pixels = try gpa.alloc(u8, squared.len);
    const edge = @as(f32, @floatFromInt(r)) + 0.5;
    for (squared, pixels) |distance, *pixel| {
        pixel.* = @intFromFloat(@round(std.math.clamp(edge - @sqrt(distance), 0, 1) * 255));
    }
    rendered.bitmap.deinit(gpa);
    rendered.bitmap = .{ .pixels = pixels, .width = width, .height = height };
    rendered.left -= @intCast(r);
    rendered.top += @intCast(r);
}

/// Further than any glyph is from anything, squared: no shape near yet.
const far: f32 = 1e20;

/// Along one line of `grid` - `length` cells `stride` apart from `offset` -
/// each squared distance becomes the least, over the line, of any cell's
/// plus the square of how far that cell is: the lower envelope of the
/// parabolas the cells stand for, as Felzenszwalb and Huttenlocher find it.
/// `line`, `parabolas` and `bounds` are room to work in.
fn alongLine(grid: []f32, offset: usize, stride: usize, length: usize, line: []f32, parabolas: []u32, bounds: []f32) void {
    line[0] = grid[offset];
    parabolas[0] = 0;
    bounds[0] = -far;
    bounds[1] = far;
    var k: usize = 0;
    for (1..length) |q| {
        line[q] = grid[offset + q * stride];
        // The first parabola's bound is further back than any meeting, so
        // this never steps back past it.
        var meet = meeting(line, parabolas[k], q);
        while (meet <= bounds[k]) {
            k -= 1;
            meet = meeting(line, parabolas[k], q);
        }
        k += 1;
        parabolas[k] = @intCast(q);
        bounds[k] = meet;
        bounds[k + 1] = far;
    }
    k = 0;
    for (0..length) |q| {
        const at: f32 = @floatFromInt(q);
        while (bounds[k + 1] < at) k += 1;
        const r = parabolas[k];
        const apart = at - @as(f32, @floatFromInt(r));
        grid[offset + q * stride] = line[r] + apart * apart;
    }
}

/// Where the parabolas of cells `r` and `q` cross.
fn meeting(line: []const f32, r: usize, q: usize) f32 {
    const at: f32 = @floatFromInt(q);
    const from: f32 = @floatFromInt(r);
    return (line[q] - line[r] + at * at - from * from) / (at - from) / 2;
}

/// Copy a rasterised glyph into the next free space, and say where that was.
fn place(self: *Atlas, rendered: font.Rendered) Error!Entry {
    const bitmap = rendered.bitmap;

    // A space has an advance and nothing to draw. It still gets an entry, so
    // the pen still moves.
    if (bitmap.isEmpty()) {
        return .{
            .u0 = 0,
            .v0 = 0,
            .u1 = 0,
            .v1 = 0,
            .width = 0,
            .height = 0,
            .left = @floatFromInt(rendered.left),
            .top = @floatFromInt(rendered.top),
            .advance = rendered.advance,
        };
    }

    if (bitmap.width + padding * 2 > self.width) return Error.AtlasFull;

    // Not enough room left on this shelf: open another above it.
    if (self.pen + bitmap.width + padding > self.width) {
        self.shelf_top += self.shelf_height + padding;
        self.shelf_height = 0;
        self.pen = padding;
    }
    if (bitmap.height > self.shelf_height) {
        // A taller glyph raises its shelf, as long as the shelf still fits.
        if (self.shelf_top + bitmap.height + padding > self.height) return Error.AtlasFull;
        self.shelf_height = bitmap.height;
    }
    if (self.shelf_top + self.shelf_height + padding > self.height) return Error.AtlasFull;

    const x = self.pen;
    const y = self.shelf_top;

    for (0..bitmap.height) |row| {
        const source = bitmap.row(@intCast(row));
        const start = ((y + row) * self.width + x) * 4;
        for (source, 0..) |coverage, column| {
            // The colour is already white; only the alpha is the glyph.
            self.pixels[start + column * 4 + 3] = coverage;
        }
    }

    self.pen += bitmap.width + padding;
    self.dirty = true;

    const w: f32 = @floatFromInt(self.width);
    const h: f32 = @floatFromInt(self.height);
    return .{
        .u0 = @as(f32, @floatFromInt(x)) / w,
        .v0 = @as(f32, @floatFromInt(y)) / h,
        .u1 = @as(f32, @floatFromInt(x + bitmap.width)) / w,
        .v1 = @as(f32, @floatFromInt(y + bitmap.height)) / h,
        .width = @floatFromInt(bitmap.width),
        .height = @floatFromInt(bitmap.height),
        .left = @floatFromInt(rendered.left),
        .top = @floatFromInt(rendered.top),
        .advance = rendered.advance,
    };
}

/// Every glyph forgotten and the image blank, to be filled anew: what a
/// frame whose letters no longer fit does before it lays them out again.
pub fn clear(self: *Atlas) void {
    self.entries.clearRetainingCapacity();
    for (0..self.pixels.len / 4) |i| self.pixels[i * 4 + 3] = 0;
    self.shelf_top = padding;
    self.shelf_height = 0;
    self.pen = padding;
    self.dirty = true;
    self.generation = nextGeneration();
}

/// How many glyphs are cached. One per letter per size, and per outline.
pub fn count(self: Atlas) usize {
    return self.entries.count();
}

test "a fresh atlas is transparent white and needs no upload" {
    var atlas: Atlas = try .init(testing.allocator, 32, 32);
    defer atlas.deinit();

    try testing.expect(!atlas.dirty);
    try testing.expectEqual(@as(u8, 255), atlas.pixels[0]);
    try testing.expectEqual(@as(u8, 0), atlas.pixels[3]);
}

test "shelves fill along and then upwards" {
    var atlas: Atlas = try .init(testing.allocator, 16, 16);
    defer atlas.deinit();

    // Six pixels wide with a pixel of padding: two fit on a shelf, the third
    // opens the next one.
    var coverage: [24]u8 = @splat(255);
    const wide: font.Rendered = .{
        .bitmap = .{ .pixels = &coverage, .width = 6, .height = 4 },
        .left = 0,
        .top = 4,
        .advance = 7,
    };

    const first = try atlas.place(wide);
    const second = try atlas.place(wide);
    const third = try atlas.place(wide);

    try testing.expectEqual(first.v0, second.v0);
    try testing.expect(third.v0 > second.v0);
    try testing.expect(atlas.dirty);
}

test "a glyph too wide for the image is refused rather than wrapped" {
    var atlas: Atlas = try .init(testing.allocator, 8, 8);
    defer atlas.deinit();

    var coverage: [16]u8 = @splat(255);
    const huge: font.Rendered = .{
        .bitmap = .{ .pixels = &coverage, .width = 16, .height = 1 },
        .left = 0,
        .top = 1,
        .advance = 16,
    };
    try testing.expectError(Error.AtlasFull, atlas.place(huge));
}

test "a cleared atlas forgets its glyphs and has all its room again" {
    var atlas: Atlas = try .init(testing.allocator, 8, 8);
    defer atlas.deinit();
    var coverage: [36]u8 = @splat(255);
    const square: font.Rendered = .{
        .bitmap = .{ .pixels = &coverage, .width = 6, .height = 6 },
        .left = 0,
        .top = 6,
        .advance = 6,
    };
    const first = try atlas.place(square);
    try testing.expectError(Error.AtlasFull, atlas.place(square));

    atlas.clear();
    try testing.expectEqual(@as(usize, 0), atlas.count());
    try testing.expectEqual(@as(u8, 0), atlas.pixels[(1 * 8 + 1) * 4 + 3]);
    try testing.expectEqual(first, try atlas.place(square));
}

test "a space takes no room and still moves the pen" {
    var atlas: Atlas = try .init(testing.allocator, 16, 16);
    defer atlas.deinit();

    const space: font.Rendered = .{ .bitmap = .empty, .left = 0, .top = 0, .advance = 5 };
    const entry = try atlas.place(space);

    try testing.expectEqual(@as(f32, 0), entry.width);
    try testing.expectEqual(@as(f32, 5), entry.advance);
    try testing.expect(!atlas.dirty);
}

test "an outline is the glyph grown all round, smooth at its edge" {
    const gpa = testing.allocator;
    // One covered pixel, grown by two.
    const one = try gpa.alloc(u8, 1);
    one[0] = 255;
    var rendered: font.Rendered = .{ .bitmap = .{ .pixels = one, .width = 1, .height = 1 }, .left = 3, .top = 7, .advance = 9 };
    defer rendered.deinit(gpa);
    try grow(gpa, &rendered, 2);

    try testing.expectEqual(@as(u32, 5), rendered.bitmap.width);
    try testing.expectEqual(@as(u32, 5), rendered.bitmap.height);
    try testing.expectEqual(@as(i32, 1), rendered.left);
    try testing.expectEqual(@as(i32, 9), rendered.top);
    // Solid within its reach, half at the edge of it, and nothing past.
    try testing.expectEqual(@as(u8, 255), rendered.bitmap.at(2, 2));
    try testing.expectEqual(@as(u8, 255), rendered.bitmap.at(1, 2));
    try testing.expectEqual(@as(u8, 128), rendered.bitmap.at(0, 2));
    try testing.expectEqual(@as(u8, 255), rendered.bitmap.at(1, 1));
    try testing.expectEqual(@as(u8, 0), rendered.bitmap.at(0, 0));
}
