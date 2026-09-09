// SPDX-License-Identifier: BSD-3-Clause

//! Every glyph the game has drawn, in one texture.
//!
//! ```zig
//! var atlas: Atlas = try .init(gpa, 512, 512);
//! defer atlas.deinit();
//!
//! const entry = try atlas.glyph(&face, face.glyphFor('H'), 16);
//! // entry.u0, v0, u1, v1 say where it is; left, top and advance say where
//! // it goes relative to the pen.
//! ```
//!
//! A renderer cannot upload a glyph per draw: a line of prose is a few dozen
//! of them and a texture switch between each would be a few dozen draw calls
//! for one label. So each glyph is rasterised once, packed into a shared
//! image, and drawn from there for the life of the program - which turns
//! every piece of text in a frame into instances of the same quad against the
//! same texture, and therefore into one draw call.
//!
//! **Keyed by glyph and size together.** The same letter at 12 pixels and at
//! 13 is two different pictures and there is no scaling one into the other
//! that does not look wrong. A game that uses four sizes ends up with four
//! copies of its alphabet, which is a few hundred kilobytes and worth it.
//! Sizes are rounded to whole pixels for the key, so a label that eases from
//! 15.6 to 16.4 does not rasterise a new alphabet every frame.
//!
//! **White pixels with the coverage in the alpha**, rather than a single
//! channel of coverage. One byte a pixel would be four times smaller, and it
//! would need the sprite shader to know which of its textures was a glyph -
//! a flag per instance and a branch per fragment - because sampling a
//! one-channel texture gives back red and nothing else. This way a glyph is a
//! picture like any other, `sample(atlas, uv) * tint` is already the right
//! answer, and text goes through the pass that was already there. The day
//! this is the memory that matters, the shader gains the flag.
//!
//! **Packed on shelves.** A row is opened as tall as the first glyph put in
//! it, filled left to right, and closed when the next glyph will not fit. Not
//! the tightest packing there is - a proper rectangle packer wastes less -
//! and it is the right one here, because glyphs of one size are all nearly
//! the same height and a shelf of them has almost no gap in it.

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

/// One glyph at one size. The key of the cache, as a number.
const Key = u32;

inline fn keyOf(index: u16, size: u16) Key {
    return (@as(Key, size) << 16) | index;
}

/// A blank pixel between one glyph and the next.
///
/// Without it a linear sampler asked for the edge of a glyph reads a little
/// of whatever was packed beside it, which looks like a smear of the wrong
/// letter along one side. One pixel is enough because nothing here is
/// mip-mapped.
const padding: u32 = 1;

gpa: Allocator,

width: u32,
height: u32,
/// Four bytes a pixel, white throughout, with the coverage in the alpha.
pixels: []u8,

/// Whether anything has been added since the texture was last uploaded.
dirty: bool = false,

/// The shelf being filled: how far up the image it starts, how tall it is,
/// and how far along it the next glyph goes.
shelf_top: u32 = padding,
shelf_height: u32 = 0,
pen: u32 = padding,

entries: std.AutoHashMapUnmanaged(Key, Entry) = .empty,

pub fn init(gpa: Allocator, width: u32, height: u32) Allocator.Error!Atlas {
    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    // White everywhere, transparent everywhere. Every glyph then only has to
    // write the alpha, and a sampler that strays outside one reads a
    // transparent white rather than a black fringe.
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
    };
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

/// Where this glyph is in the atlas, rasterising it if this is the first time
/// anybody has asked.
///
/// `size` is in whole pixels per em. The face is passed in rather than held,
/// because a font lives in a table that may move when another is loaded and
/// a pointer kept here would be pointing at where it used to be.
pub fn glyph(self: *Atlas, face: *const font.Font, index: u16, size: u16) Error!Entry {
    const key = keyOf(index, size);
    if (self.entries.get(key)) |entry| return entry;

    var rendered = try face.render(self.gpa, index, face.scaleFor(@floatFromInt(size)));
    defer rendered.deinit(self.gpa);

    const entry = try self.place(rendered);
    try self.entries.put(self.gpa, key, entry);
    return entry;
}

/// Copy a rasterised glyph into the next free space, and say where that was.
fn place(self: *Atlas, rendered: font.Rendered) Error!Entry {
    const bitmap = rendered.bitmap;

    // A space has a real advance and nothing to draw. It still gets an entry,
    // so the cache answers for it and the pen still moves.
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

    // Does it fit on the shelf being filled? If not, close that one and open
    // another above it.
    if (self.pen + bitmap.width + padding > self.width) {
        self.shelf_top += self.shelf_height + padding;
        self.shelf_height = 0;
        self.pen = padding;
    }
    if (bitmap.height > self.shelf_height) {
        // A taller glyph raises the shelf it is on, which is only allowed
        // while the shelf would still fit in the image.
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

/// How many glyphs are cached. One per letter per size.
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

test "a space takes no room and still moves the pen" {
    var atlas: Atlas = try .init(testing.allocator, 16, 16);
    defer atlas.deinit();

    const space: font.Rendered = .{ .bitmap = .empty, .left = 0, .top = 0, .advance = 5 };
    const entry = try atlas.place(space);

    try testing.expectEqual(@as(f32, 0), entry.width);
    try testing.expectEqual(@as(f32, 5), entry.advance);
    try testing.expect(!atlas.dirty);
}
