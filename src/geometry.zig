// SPDX-License-Identifier: BSD-3-Clause

//! Whole-number points, and boxes of either kind: a tile map's cells, a
//! window's place on the screen, a sprite's rectangle, a picked area.
//!
//! ```zig
//! const cell: Vec2i = .init(3, -2);
//! const used: Rect2i = .init(0, 0, 16, 9);
//! if (used.hasPoint(cell)) paint(cell);
//! const button: Rect2 = .init(20, 20, 160, 48);
//! if (button.hasPoint(pointer)) press();
//! ```
//!
//! A box is where it starts and how big it is, as a window or a rectangle
//! is written down; `end` is the first point past it, so two boxes side by
//! side share no point, and a box of no size holds none.

const std = @import("std");
const testing = std.testing;

const math = @import("fluxion_math");

const Vec2 = math.Vec2;

/// A point, a size or a step on a grid: a cell of a tile map, a pixel, a
/// window's place.
pub const Vec2i = extern struct {
    x: i32 = 0,
    y: i32 = 0,

    pub const zero: Vec2i = .{};
    pub const one: Vec2i = .{ .x = 1, .y = 1 };

    pub const reflect_name = "Vec2i";

    pub inline fn init(x: i32, y: i32) Vec2i {
        return .{ .x = x, .y = y };
    }

    pub inline fn splat(value: i32) Vec2i {
        return .{ .x = value, .y = value };
    }

    pub inline fn add(a: Vec2i, b: Vec2i) Vec2i {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub inline fn sub(a: Vec2i, b: Vec2i) Vec2i {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub inline fn mul(a: Vec2i, b: Vec2i) Vec2i {
        return .{ .x = a.x * b.x, .y = a.y * b.y };
    }

    pub inline fn scale(self: Vec2i, s: i32) Vec2i {
        return .{ .x = self.x * s, .y = self.y * s };
    }

    pub inline fn neg(self: Vec2i) Vec2i {
        return .{ .x = -self.x, .y = -self.y };
    }

    pub inline fn min(a: Vec2i, b: Vec2i) Vec2i {
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y) };
    }

    pub inline fn max(a: Vec2i, b: Vec2i) Vec2i {
        return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y) };
    }

    pub inline fn abs(self: Vec2i) Vec2i {
        return .{ .x = @intCast(@abs(self.x)), .y = @intCast(@abs(self.y)) };
    }

    pub inline fn eql(a: Vec2i, b: Vec2i) bool {
        return a.x == b.x and a.y == b.y;
    }

    /// The same point with fractions.
    pub inline fn toVec2(self: Vec2i) Vec2 {
        return .init(@floatFromInt(self.x), @floatFromInt(self.y));
    }

    /// The point of the grid at or below-left of `v`: the cell a point is
    /// in, when a cell is one unit.
    pub fn floorOf(v: Vec2) Vec2i {
        return .{ .x = @intFromFloat(@floor(v.x)), .y = @intFromFloat(@floor(v.y)) };
    }

    /// The nearest point of the grid.
    pub fn roundOf(v: Vec2) Vec2i {
        return .{ .x = @intFromFloat(@round(v.x)), .y = @intFromFloat(@round(v.y)) };
    }

    pub fn format(self: Vec2i, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("({d}, {d})", .{ self.x, self.y });
    }
};

/// A box with fractions: where it starts, and how wide and tall it is.
pub const Rect2 = extern struct {
    position: Vec2 = .zero,
    size: Vec2 = .zero,

    pub const reflect_name = "Rect2";

    pub inline fn init(x: f32, y: f32, width: f32, height: f32) Rect2 {
        return .{ .position = .init(x, y), .size = .init(width, height) };
    }

    /// The box two corners span, whichever way round they are.
    pub fn fromCorners(a: Vec2, b: Vec2) Rect2 {
        const low = a.min(b);
        return .{ .position = low, .size = a.max(b).sub(low) };
    }

    /// The first point past it: its far corner.
    pub inline fn end(self: Rect2) Vec2 {
        return self.position.add(self.size);
    }

    pub inline fn center(self: Rect2) Vec2 {
        return self.position.add(self.size.scale(0.5));
    }

    pub inline fn area(self: Rect2) f32 {
        return self.size.x * self.size.y;
    }

    /// The same box with a size that is not negative: one drawn from its far
    /// corner back.
    pub fn abs(self: Rect2) Rect2 {
        return fromCorners(self.position, self.end());
    }

    /// Whether a point is inside: on the near edges counts, on the far edges
    /// does not.
    pub fn hasPoint(self: Rect2, point: Vec2) bool {
        const far = self.end();
        return point.x >= self.position.x and point.y >= self.position.y and point.x < far.x and point.y < far.y;
    }

    /// Whether the two share any point.
    pub fn intersects(a: Rect2, b: Rect2) bool {
        return a.intersection(b) != null;
    }

    /// Where the two overlap, or null where they do not.
    pub fn intersection(a: Rect2, b: Rect2) ?Rect2 {
        const low = a.position.max(b.position);
        const high = a.end().min(b.end());
        if (high.x <= low.x or high.y <= low.y) return null;
        return .{ .position = low, .size = high.sub(low) };
    }

    /// The smallest box holding both.
    pub fn merge(a: Rect2, b: Rect2) Rect2 {
        const low = a.position.min(b.position);
        return .{ .position = low, .size = a.end().max(b.end()).sub(low) };
    }

    /// Bigger by `by` on every side; smaller for a negative `by`.
    pub fn grow(self: Rect2, by: f32) Rect2 {
        return .{ .position = self.position.sub(.splat(by)), .size = self.size.add(.splat(2 * by)) };
    }

    /// Stretched to take in a point.
    pub fn expandTo(self: Rect2, point: Vec2) Rect2 {
        const low = self.position.min(point);
        return .{ .position = low, .size = self.end().max(point).sub(low) };
    }
};

/// A box of whole numbers: cells of a map, pixels of a picture.
pub const Rect2i = extern struct {
    position: Vec2i = .zero,
    size: Vec2i = .zero,

    pub const reflect_name = "Rect2i";

    pub inline fn init(x: i32, y: i32, width: i32, height: i32) Rect2i {
        return .{ .position = .init(x, y), .size = .init(width, height) };
    }

    /// The box two cells span, both of them in it.
    pub fn fromCells(a: Vec2i, b: Vec2i) Rect2i {
        const low = a.min(b);
        return .{ .position = low, .size = a.max(b).sub(low).add(.one) };
    }

    pub inline fn end(self: Rect2i) Vec2i {
        return self.position.add(self.size);
    }

    /// The last cell in it: `end` less one each way. Only for a box that
    /// holds a cell.
    pub inline fn last(self: Rect2i) Vec2i {
        return self.end().sub(.one);
    }

    pub inline fn area(self: Rect2i) i64 {
        return @as(i64, self.size.x) * self.size.y;
    }

    pub fn hasPoint(self: Rect2i, point: Vec2i) bool {
        const far = self.end();
        return point.x >= self.position.x and point.y >= self.position.y and point.x < far.x and point.y < far.y;
    }

    pub fn intersects(a: Rect2i, b: Rect2i) bool {
        return a.intersection(b) != null;
    }

    pub fn intersection(a: Rect2i, b: Rect2i) ?Rect2i {
        const low = a.position.max(b.position);
        const high = a.end().min(b.end());
        if (high.x <= low.x or high.y <= low.y) return null;
        return .{ .position = low, .size = high.sub(low) };
    }

    pub fn merge(a: Rect2i, b: Rect2i) Rect2i {
        const low = a.position.min(b.position);
        return .{ .position = low, .size = a.end().max(b.end()).sub(low) };
    }

    pub fn grow(self: Rect2i, by: i32) Rect2i {
        return .{ .position = self.position.sub(.splat(by)), .size = self.size.add(.splat(2 * by)) };
    }

    /// Stretched to take in a cell.
    pub fn expandTo(self: Rect2i, cell: Vec2i) Rect2i {
        const low = self.position.min(cell);
        return .{ .position = low, .size = self.end().max(cell.add(.one)).sub(low) };
    }

    pub fn toRect2(self: Rect2i) Rect2 {
        return .{ .position = self.position.toVec2(), .size = self.size.toVec2() };
    }
};

test "a point on the far edge of a box is outside it, and one on the near edge inside" {
    const box: Rect2 = .init(10, 20, 30, 40);
    try testing.expect(box.hasPoint(.init(10, 20)));
    try testing.expect(!box.hasPoint(.init(40, 30)));
    try testing.expect(!box.hasPoint(.init(20, 60)));
    try testing.expectEqual(Vec2.init(25, 40), box.center());
}

test "two boxes side by side do not meet, and overlapping ones meet where they overlap" {
    const left: Rect2i = .init(0, 0, 4, 4);
    try testing.expect(!left.intersects(.init(4, 0, 4, 4)));
    const overlap = left.intersection(.init(2, 3, 10, 10)).?;
    try testing.expectEqual(Rect2i.init(2, 3, 2, 1), overlap);
    try testing.expectEqual(Rect2i.init(0, 0, 12, 13), left.merge(.init(2, 3, 10, 10)));
}

test "the cells two corners span hold both corners, and growing takes a cell in" {
    const span = Rect2i.fromCells(.init(3, -1), .init(-2, 4));
    try testing.expectEqual(Vec2i.init(-2, -1), span.position);
    try testing.expectEqual(Vec2i.init(3, 4), span.last());
    try testing.expect(span.hasPoint(.init(3, 4)));
    const grown = span.expandTo(.init(10, 0));
    try testing.expect(grown.hasPoint(.init(10, 0)));
    try testing.expectEqual(Vec2i.init(10, 4), grown.last());
}

test "a point with fractions falls in the cell at or below it" {
    try testing.expectEqual(Vec2i.init(-1, 2), Vec2i.floorOf(.init(-0.5, 2.9)));
    try testing.expectEqual(Vec2i.init(0, 3), Vec2i.roundOf(.init(-0.4, 2.6)));
    try testing.expectEqual(Rect2.init(-1, -2, 4, 6), Rect2.fromCorners(.init(3, 4), .init(-1, -2)));
}
