// SPDX-License-Identifier: BSD-3-Clause
//! A picture in memory, to read and change a pixel at a time and to write to
//! a file: a save's thumbnail, a map drawn as the player explores, a picture
//! the player chose. `App.newTexture` makes one a texture to draw.
//!
//! ```zig
//! var shot = try app.captureImage(gpa);                  // the last frame
//! defer shot.deinit(gpa);
//! var thumb = try shot.resized(gpa, 160, 90, true);
//! defer thumb.deinit(gpa);
//! try app.saveImage(thumb, "user://saves/one.jpg", .{ .quality = 85 });
//! ```
//!
//! Its pixels are RGBA, eight bits a channel, top row first, packed: what a
//! texture takes and a PNG writes. A pixel outside it is nothing: read, it is
//! null; written, it is left alone; a rectangle is cut to what is inside.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const image = @import("fluxion_image");

const Color = @import("color.zig").Color;

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    /// The longest side one can have: a texture's, on every GPU.
    pub const max_side = 16384;

    pub const Error = error{
        /// A side of nought, or one longer than `max_side`.
        BadSize,
    } || Allocator.Error;

    /// One `width` by `height`, every pixel `fill`.
    pub fn init(gpa: Allocator, width: u32, height: u32, fill_with: Color) Error!Image {
        if (width == 0 or height == 0 or width > max_side or height > max_side) return error.BadSize;
        const made: Image = .{ .width = width, .height = height, .pixels = try gpa.alloc(u8, @as(usize, width) * height * 4) };
        made.fill(fill_with);
        return made;
    }

    pub fn deinit(self: *Image, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }

    /// One read from a PNG's or a JPEG's bytes.
    pub fn decode(gpa: Allocator, bytes: []const u8) !Image {
        const decoded = try image.decode(gpa, bytes);
        return .{ .width = decoded.width, .height = decoded.height, .pixels = decoded.pixels };
    }

    /// One from RGBA pixels, copied.
    pub fn fromPixels(gpa: Allocator, width: u32, height: u32, rgba: []const u8) Error!Image {
        if (width == 0 or height == 0 or width > max_side or height > max_side) return error.BadSize;
        std.debug.assert(rgba.len >= @as(usize, width) * height * 4);
        return .{ .width = width, .height = height, .pixels = try gpa.dupe(u8, rgba[0 .. @as(usize, width) * height * 4]) };
    }

    pub fn clone(self: Image, gpa: Allocator) Allocator.Error!Image {
        return .{ .width = self.width, .height = self.height, .pixels = try gpa.dupe(u8, self.pixels) };
    }

    fn at(self: Image, x: i64, y: i64) ?usize {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return null;
        return (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 4;
    }

    /// The pixel at (`x`, `y`), from the top left; null outside.
    pub fn getPixel(self: Image, x: i64, y: i64) ?Color {
        const i = self.at(x, y) orelse return null;
        return colorOf(self.pixels[i..][0..4].*);
    }

    /// Set the pixel at (`x`, `y`); nothing outside. Whether it was inside.
    pub fn setPixel(self: Image, x: i64, y: i64, color: Color) bool {
        const i = self.at(x, y) orelse return false;
        self.pixels[i..][0..4].* = bytesOf(color);
        return true;
    }

    /// Every pixel `color`.
    pub fn fill(self: Image, color: Color) void {
        const bytes = bytesOf(color);
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 4) self.pixels[i..][0..4].* = bytes;
    }

    /// The pixels of a rectangle `color`, as much of it as is inside.
    pub fn fillRect(self: Image, x: i64, y: i64, width: i64, height: i64, color: Color) void {
        const box = self.clip(x, y, width, height) orelse return;
        const bytes = bytesOf(color);
        for (box.top..box.bottom) |row| for (box.left..box.right) |column| {
            self.pixels[(row * self.width + column) * 4 ..][0..4].* = bytes;
        };
    }

    const Box = struct { left: usize, top: usize, right: usize, bottom: usize };

    fn clip(self: Image, x: i64, y: i64, width: i64, height: i64) ?Box {
        const left = @max(x, 0);
        const top = @max(y, 0);
        const right = @min(x +| @max(width, 0), self.width);
        const bottom = @min(y +| @max(height, 0), self.height);
        if (left >= right or top >= bottom) return null;
        return .{ .left = @intCast(left), .top = @intCast(top), .right = @intCast(right), .bottom = @intCast(bottom) };
    }

    /// A new image of a rectangle of this one, as much of it as is inside:
    /// `error.BadSize` when none is.
    pub fn region(self: Image, gpa: Allocator, x: i64, y: i64, width: i64, height: i64) Error!Image {
        const box = self.clip(x, y, width, height) orelse return error.BadSize;
        const out: Image = .{
            .width = @intCast(box.right - box.left),
            .height = @intCast(box.bottom - box.top),
            .pixels = try gpa.alloc(u8, (box.right - box.left) * (box.bottom - box.top) * 4),
        };
        for (box.top..box.bottom, 0..) |row, to| {
            const from = self.pixels[(row * self.width + box.left) * 4 ..][0 .. out.width * 4];
            @memcpy(out.pixels[to * out.width * 4 ..][0 .. out.width * 4], from);
        }
        return out;
    }

    /// `source` copied in with its top left at (`x`, `y`), its alpha too:
    /// what it covers is what it is.
    pub fn blit(self: Image, source: Image, x: i64, y: i64) void {
        self.put(source, x, y, false);
    }

    /// `source` drawn over with its top left at (`x`, `y`): a pixel of it
    /// half see-through shows half of what was under it.
    pub fn blend(self: Image, source: Image, x: i64, y: i64) void {
        self.put(source, x, y, true);
    }

    fn put(self: Image, source: Image, x: i64, y: i64, over: bool) void {
        const box = self.clip(x, y, source.width, source.height) orelse return;
        for (box.top..box.bottom) |row| {
            const from_row: usize = @intCast(@as(i64, @intCast(row)) - y);
            for (box.left..box.right) |column| {
                const from_column: usize = @intCast(@as(i64, @intCast(column)) - x);
                const from = source.pixels[(from_row * source.width + from_column) * 4 ..][0..4];
                const to = self.pixels[(row * self.width + column) * 4 ..][0..4];
                to.* = if (over) overOf(from.*, to.*) else from.*;
            }
        }
    }

    /// A new image `width` by `height` of this one, each pixel the nearest,
    /// or - `smooth` - the four nearest mixed.
    pub fn resized(self: Image, gpa: Allocator, width: u32, height: u32, smooth: bool) Error!Image {
        if (width == 0 or height == 0 or width > max_side or height > max_side) return error.BadSize;
        const out: Image = .{ .width = width, .height = height, .pixels = try gpa.alloc(u8, @as(usize, width) * height * 4) };
        const sx = @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(width));
        const sy = @as(f32, @floatFromInt(self.height)) / @as(f32, @floatFromInt(height));
        for (0..height) |row| for (0..width) |column| {
            const to = out.pixels[(row * width + column) * 4 ..][0..4];
            // The middle of the new pixel, in the old one's pixels.
            const fx = (@as(f32, @floatFromInt(column)) + 0.5) * sx - 0.5;
            const fy = (@as(f32, @floatFromInt(row)) + 0.5) * sy - 0.5;
            if (!smooth) {
                const nx: usize = @intFromFloat(std.math.clamp(@round(fx), 0, @as(f32, @floatFromInt(self.width - 1))));
                const ny: usize = @intFromFloat(std.math.clamp(@round(fy), 0, @as(f32, @floatFromInt(self.height - 1))));
                to.* = self.pixels[(ny * self.width + nx) * 4 ..][0..4].*;
                continue;
            }
            const x0f = std.math.clamp(@floor(fx), 0, @as(f32, @floatFromInt(self.width - 1)));
            const y0f = std.math.clamp(@floor(fy), 0, @as(f32, @floatFromInt(self.height - 1)));
            const x0: usize = @intFromFloat(x0f);
            const y0: usize = @intFromFloat(y0f);
            const x1 = @min(x0 + 1, self.width - 1);
            const y1 = @min(y0 + 1, self.height - 1);
            const tx = std.math.clamp(fx - x0f, 0, 1);
            const ty = std.math.clamp(fy - y0f, 0, 1);
            for (0..4) |c| {
                const a: f32 = @floatFromInt(self.pixels[(y0 * self.width + x0) * 4 + c]);
                const b: f32 = @floatFromInt(self.pixels[(y0 * self.width + x1) * 4 + c]);
                const d: f32 = @floatFromInt(self.pixels[(y1 * self.width + x0) * 4 + c]);
                const e: f32 = @floatFromInt(self.pixels[(y1 * self.width + x1) * 4 + c]);
                const top = a + (b - a) * tx;
                const bottom = d + (e - d) * tx;
                to[c] = @intFromFloat(@round(std.math.clamp(top + (bottom - top) * ty, 0, 255)));
            }
        };
        return out;
    }

    /// Turned over left to right.
    pub fn flipX(self: Image) void {
        for (0..self.height) |row| {
            const line = self.pixels[row * self.width * 4 ..][0 .. self.width * 4];
            var left: usize = 0;
            var right: usize = self.width - 1;
            while (left < right) : ({
                left += 1;
                right -= 1;
            }) {
                const kept = line[left * 4 ..][0..4].*;
                line[left * 4 ..][0..4].* = line[right * 4 ..][0..4].*;
                line[right * 4 ..][0..4].* = kept;
            }
        }
    }

    /// Turned over top to bottom.
    pub fn flipY(self: Image) void {
        const row_bytes = self.width * 4;
        var top: usize = 0;
        var bottom: usize = self.height - 1;
        while (top < bottom) : ({
            top += 1;
            bottom -= 1;
        }) {
            for (self.pixels[top * row_bytes ..][0..row_bytes], self.pixels[bottom * row_bytes ..][0..row_bytes]) |*a, *b| {
                std.mem.swap(u8, a, b);
            }
        }
    }

    /// What fluxion-image writes it from.
    pub fn view(self: Image) image.Image {
        return .{ .width = self.width, .height = self.height, .pixels = self.pixels, .row_pitch = @as(usize, self.width) * 4 };
    }

    /// Its PNG, see-through and all.
    pub fn encodePng(self: Image, gpa: Allocator) ![]u8 {
        return image.png.encodeAlloc(gpa, self.view(), .{ .keep_alpha = true });
    }

    /// Its JPEG at `quality`, 1 to 100: smaller, and with no alpha.
    pub fn encodeJpg(self: Image, gpa: Allocator, quality: u8) ![]u8 {
        return image.jpeg.encodeAlloc(gpa, self.view(), .{ .quality = quality });
    }
};

fn channel(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

fn bytesOf(color: Color) [4]u8 {
    return .{ channel(color.r), channel(color.g), channel(color.b), channel(color.a) };
}

fn colorOf(bytes: [4]u8) Color {
    return .{
        .r = @as(f32, @floatFromInt(bytes[0])) / 255,
        .g = @as(f32, @floatFromInt(bytes[1])) / 255,
        .b = @as(f32, @floatFromInt(bytes[2])) / 255,
        .a = @as(f32, @floatFromInt(bytes[3])) / 255,
    };
}

/// `top` over `under`, straight alpha both.
fn overOf(top: [4]u8, under: [4]u8) [4]u8 {
    const ta = @as(f32, @floatFromInt(top[3])) / 255;
    const ua = @as(f32, @floatFromInt(under[3])) / 255;
    const out_a = ta + ua * (1 - ta);
    if (out_a <= 0) return .{ 0, 0, 0, 0 };
    var out: [4]u8 = undefined;
    for (0..3) |c| {
        const t = @as(f32, @floatFromInt(top[c])) / 255;
        const u = @as(f32, @floatFromInt(under[c])) / 255;
        out[c] = channel((t * ta + u * ua * (1 - ta)) / out_a);
    }
    out[3] = channel(out_a);
    return out;
}

test "an image is filled, read and written a pixel at a time, and nothing outside it is" {
    var picture = try Image.init(testing.allocator, 4, 3, .black);
    defer picture.deinit(testing.allocator);
    try testing.expect(picture.setPixel(1, 2, .white));
    try testing.expect(!picture.setPixel(4, 0, .white));
    try testing.expect(!picture.setPixel(-1, 0, .white));
    try testing.expectEqual(@as(f32, 1), picture.getPixel(1, 2).?.r);
    try testing.expectEqual(@as(f32, 0), picture.getPixel(0, 0).?.r);
    try testing.expect(picture.getPixel(0, 3) == null);

    picture.fillRect(2, -5, 10, 7, .{ .r = 1, .g = 0, .b = 0, .a = 1 });
    try testing.expectEqual(@as(f32, 1), picture.getPixel(3, 1).?.r);
    try testing.expectEqual(@as(f32, 0), picture.getPixel(3, 2).?.r);
    try testing.expectEqual(@as(f32, 0), picture.getPixel(1, 1).?.r);
    try testing.expectError(error.BadSize, Image.init(testing.allocator, 0, 3, .black));
}

test "a region is cut, copied in, drawn over, and turned over" {
    var picture = try Image.init(testing.allocator, 4, 4, .black);
    defer picture.deinit(testing.allocator);
    _ = picture.setPixel(3, 3, .white);
    var corner = try picture.region(testing.allocator, 2, 2, 5, 5);
    defer corner.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), corner.width);
    try testing.expectEqual(@as(f32, 1), corner.getPixel(1, 1).?.g);
    try testing.expectError(error.BadSize, picture.region(testing.allocator, 9, 9, 2, 2));

    picture.blit(corner, 0, 0);
    try testing.expectEqual(@as(f32, 1), picture.getPixel(1, 1).?.g);

    var glass = try Image.init(testing.allocator, 1, 1, .{ .r = 1, .g = 1, .b = 1, .a = 0.5 });
    defer glass.deinit(testing.allocator);
    picture.blend(glass, 0, 0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), picture.getPixel(0, 0).?.r, 0.01);
    try testing.expectEqual(@as(f32, 1), picture.getPixel(0, 0).?.a);
    picture.blit(glass, 2, 0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), picture.getPixel(2, 0).?.a, 0.01);

    picture.flipX();
    try testing.expectEqual(@as(f32, 1), picture.getPixel(0, 3).?.g);
    picture.flipY();
    try testing.expectEqual(@as(f32, 1), picture.getPixel(0, 0).?.g);
}

test "an image is made smaller or bigger, sharp or smooth, and written as a PNG and a JPEG" {
    var picture = try Image.init(testing.allocator, 2, 1, .black);
    defer picture.deinit(testing.allocator);
    _ = picture.setPixel(1, 0, .white);

    var sharp = try picture.resized(testing.allocator, 4, 2, false);
    defer sharp.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 0), sharp.getPixel(1, 1).?.r);
    try testing.expectEqual(@as(f32, 1), sharp.getPixel(2, 1).?.r);

    var smooth = try picture.resized(testing.allocator, 4, 2, true);
    defer smooth.deinit(testing.allocator);
    const middle = smooth.getPixel(1, 0).?.r;
    try testing.expect(middle > 0.1 and middle < 0.5);

    const png_bytes = try smooth.encodePng(testing.allocator);
    defer testing.allocator.free(png_bytes);
    var back = try Image.decode(testing.allocator, png_bytes);
    defer back.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, smooth.pixels, back.pixels);

    const jpg_bytes = try smooth.encodeJpg(testing.allocator, 90);
    defer testing.allocator.free(jpg_bytes);
    try testing.expectEqual(image.Kind.jpeg, image.kindOf(jpg_bytes).?);
}
