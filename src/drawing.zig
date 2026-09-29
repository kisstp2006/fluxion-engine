// SPDX-License-Identifier: BSD-3-Clause

//! A `Drawing2D`: lines, boxes, circles, arcs, polygons, pictures and words a
//! game draws in an entity's own space - a health bar, a path, a laser, a
//! map - kept until it draws again, and drawn among the sprites at the
//! entity's layer, moved, turned, scaled and faded with it.
//!
//! ```zig
//! try app.drawRect(bar, .init(0, 0), .init(100, 8), .gray, true, 1);
//! try app.drawRect(bar, .init(0, 0), .init(hp, 8), .red, true, 1);
//! try app.drawLine(bar, .init(0, 10), .init(100, 10), .white, 2);
//! ```
//!
//! **What is drawn stays drawn.** Each call adds to the entity's picture,
//! and `clearDrawing` empties it; the engine draws what the picture holds
//! every frame. The first call gives the entity a `Drawing2D` when it has
//! none: its layer, its place in the layer and whether it shows.
//!
//! **A script draws when asked.** Its `draw(self)` is called the first
//! frame, and at the end of any frame `self.entity.queueRedraw()` was called
//! in, on an emptied picture:
//!
//! ```zig
//! fn draw(self) {
//!     self.entity.drawCircle(vec2(0, 0), 20, color("gold"));
//!     self.entity.drawArc(vec2(0, 0), 26, 0.0, self.charge * math.tau, color("white"), 3);
//! }
//! ```
//!
//! A shape's points are in the entity's space, as a child's place is; one
//! with no `Transform2D` draws in the world's. Colours are multiplied by the
//! entity's `Appearance`, and a `Material` beside it draws all of it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const attr = @import("attr.zig");
const Assets = @import("assets.zig");
const Color = @import("color.zig").Color;

const Entity = ecs.Entity;
const Vec2 = math.Vec2;

pub const Drawing2D = extern struct {
    /// What is drawn over what, as a sprite's `layer`.
    layer: i16 = 0,
    /// Where it sits within its layer, as a sprite's `order`.
    order: f32 = 0,
    visible: bool = true,

    pub const reflect_name = "Drawing2D";
    pub const reflect_fields = .{
        .layer = .{attr.Doc{ .text = "Higher is drawn over lower" }},
        .order = .{attr.Doc{ .text = "Its place within its layer: lower first" }},
    };
};

/// One thing drawn.
pub const Shape = union(enum) {
    line: struct { from: Vec2, to: Vec2, color: Color, width: f32 },
    rect: struct { at: Vec2, size: Vec2, color: Color, filled: bool, width: f32 },
    circle: struct { center: Vec2, radius: f32, color: Color, filled: bool, width: f32 },
    arc: struct { center: Vec2, radius: f32, start: f32, end: f32, color: Color, width: f32 },
    /// Points of the picture's `points`, joined in turn.
    polyline: struct { first: u32, count: u32, color: Color, width: f32 },
    /// Points of the picture's `points`, filled: its triangles are three
    /// each of the picture's `corners`, from `first_corner`.
    polygon: struct { first_corner: u32, corners: u32, color: Color },
    texture: struct { texture: Assets.TextureHandle, at: Vec2, size: Vec2, color: Color },
    /// Bytes of the picture's `words`.
    text: struct { first: u32, len: u32, at: Vec2, color: Color, size: f32, font: Assets.FontHandle },
};

/// What one entity has drawn.
pub const Picture = struct {
    shapes: std.ArrayList(Shape) = .empty,
    points: std.ArrayList(Vec2) = .empty,
    /// Indices into `points`, three to a triangle of a polygon.
    corners: std.ArrayList(u32) = .empty,
    words: std.ArrayList(u8) = .empty,
    /// The box round everything drawn, in the entity's space: what is
    /// weighed against the camera.
    low: Vec2 = .init(std.math.inf(f32), std.math.inf(f32)),
    high: Vec2 = .init(-std.math.inf(f32), -std.math.inf(f32)),
    /// Its script is to draw it again, at the end of the frame.
    wanted: bool = false,
    /// Its script has drawn it once: it is not asked again until wanted.
    drawn: bool = false,

    pub fn deinit(self: *Picture, gpa: Allocator) void {
        self.shapes.deinit(gpa);
        self.points.deinit(gpa);
        self.corners.deinit(gpa);
        self.words.deinit(gpa);
    }

    /// Everything drawn taken away.
    pub fn clear(self: *Picture) void {
        self.shapes.clearRetainingCapacity();
        self.points.clearRetainingCapacity();
        self.corners.clearRetainingCapacity();
        self.words.clearRetainingCapacity();
        self.low = .init(std.math.inf(f32), std.math.inf(f32));
        self.high = .init(-std.math.inf(f32), -std.math.inf(f32));
    }

    /// Whether anything is drawn.
    pub fn isEmpty(self: *const Picture) bool {
        return self.shapes.items.len == 0;
    }

    /// The box grown to take in a point `reach` round.
    pub fn cover(self: *Picture, at: Vec2, reach: f32) void {
        const r: Vec2 = .splat(@abs(reach));
        self.low = self.low.min(at.sub(r));
        self.high = self.high.max(at.add(r));
    }

    pub fn add(self: *Picture, gpa: Allocator, shape: Shape) Allocator.Error!void {
        try self.shapes.append(gpa, shape);
    }

    /// Points kept for a shape that joins them, and where they start.
    pub fn keepPoints(self: *Picture, gpa: Allocator, points: []const Vec2, reach: f32) Allocator.Error!u32 {
        const first: u32 = @intCast(self.points.items.len);
        try self.points.appendSlice(gpa, points);
        for (points) |p| self.cover(p, reach);
        return first;
    }

    /// A filled polygon's points kept, cut into triangles.
    pub fn addPolygon(self: *Picture, gpa: Allocator, points: []const Vec2, color: Color) Allocator.Error!void {
        if (points.len < 3) return;
        const first = try self.keepPoints(gpa, points, 0);
        const first_corner: u32 = @intCast(self.corners.items.len);
        try triangulate(gpa, points, first, &self.corners);
        const corners: u32 = @as(u32, @intCast(self.corners.items.len)) - first_corner;
        if (corners == 0) return;
        try self.add(gpa, .{ .polygon = .{ .first_corner = first_corner, .corners = corners, .color = color } });
    }

    /// Words kept for a shape that shows them, and where they start.
    pub fn keepWords(self: *Picture, gpa: Allocator, words: []const u8) Allocator.Error!u32 {
        const first: u32 = @intCast(self.words.items.len);
        try self.words.appendSlice(gpa, words);
        return first;
    }
};

/// Every entity's picture: `app.drawings`.
pub const Drawings = struct {
    by: std.AutoArrayHashMapUnmanaged(Entity, Picture) = .empty,

    pub fn deinit(self: *Drawings, gpa: Allocator) void {
        for (self.by.values()) |*picture| picture.deinit(gpa);
        self.by.deinit(gpa);
    }

    /// Every picture gone: the world was cleared.
    pub fn clearAll(self: *Drawings, gpa: Allocator) void {
        for (self.by.values()) |*picture| picture.deinit(gpa);
        self.by.clearRetainingCapacity();
    }

    pub fn get(self: *const Drawings, entity: Entity) ?*Picture {
        return self.by.getPtr(entity);
    }

    /// An entity's picture, made the first time it is asked for.
    pub fn pictureOf(self: *Drawings, gpa: Allocator, entity: Entity) Allocator.Error!*Picture {
        const entry = try self.by.getOrPut(gpa, entity);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        return entry.value_ptr;
    }

    /// Let go of the pictures of the dead.
    pub fn forgetDead(self: *Drawings, gpa: Allocator, world: *const ecs.World) void {
        var at = self.by.count();
        while (at > 0) {
            at -= 1;
            if (world.isAlive(self.by.keys()[at])) continue;
            self.by.values()[at].deinit(gpa);
            self.by.swapRemoveAt(at);
        }
    }
};

/// How many straight pieces a circle of `radius` is drawn in: enough that
/// it looks round, few enough to cost little.
pub fn segmentsOf(radius: f32, turn: f32) u32 {
    const whole: f32 = std.math.clamp(radius * 0.75, 12, 96);
    return @max(@as(u32, @intFromFloat(@ceil(whole * @abs(turn) / std.math.tau))), 2);
}

/// Cut a simple polygon - either way round, its sides not crossing - into
/// triangles by their ears: three `corners`, indices from `base`, for each.
/// A polygon with crossing sides is cut as far as it goes.
pub fn triangulate(gpa: Allocator, points: []const Vec2, base: u32, corners: *std.ArrayList(u32)) Allocator.Error!void {
    if (points.len < 3) return;
    var left: std.ArrayList(u32) = .empty;
    defer left.deinit(gpa);
    try left.ensureTotalCapacity(gpa, points.len);
    for (0..points.len) |i| left.appendAssumeCapacity(@intCast(i));

    var area: f32 = 0;
    for (points, 0..) |p, i| {
        const q = points[(i + 1) % points.len];
        area += p.x * q.y - q.x * p.y;
    }
    const turning: f32 = if (area < 0) -1 else 1;

    while (left.items.len > 3) {
        const n = left.items.len;
        const cut = for (0..n) |i| {
            const a = points[left.items[(i + n - 1) % n]];
            const b = points[left.items[i]];
            const c = points[left.items[(i + 1) % n]];
            // Convex here, the way the polygon turns.
            if (cross(a, b, c) * turning <= 0) continue;
            // And no other corner inside the ear.
            const clear = for (left.items) |other| {
                const p = points[other];
                if (p.eql(a) or p.eql(b) or p.eql(c)) continue;
                if (inside(p, a, b, c, turning)) break false;
            } else true;
            if (clear) break i;
        } else break;
        try corners.appendSlice(gpa, &.{ base + left.items[(cut + n - 1) % n], base + left.items[cut], base + left.items[(cut + 1) % n] });
        _ = left.orderedRemove(cut);
    }
    if (left.items.len == 3) try corners.appendSlice(gpa, &.{ base + left.items[0], base + left.items[1], base + left.items[2] });
}

fn cross(a: Vec2, b: Vec2, c: Vec2) f32 {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

fn inside(p: Vec2, a: Vec2, b: Vec2, c: Vec2, turning: f32) bool {
    return cross(a, b, p) * turning >= 0 and cross(b, c, p) * turning >= 0 and cross(c, a, p) * turning >= 0;
}

test "a square is two triangles, and a notched shape is cut round its notch" {
    var corners: std.ArrayList(u32) = .empty;
    defer corners.deinit(testing.allocator);
    const square = [_]Vec2{ .init(0, 0), .init(10, 0), .init(10, 10), .init(0, 10) };
    try triangulate(testing.allocator, &square, 0, &corners);
    try testing.expectEqual(@as(usize, 6), corners.items.len);

    // A C shape, with its notch on the right: five triangles for seven
    // corners, none of them over the notch.
    corners.clearRetainingCapacity();
    const notched = [_]Vec2{ .init(0, 0), .init(10, 0), .init(10, 3), .init(4, 3), .init(4, 7), .init(10, 7), .init(10, 10), .init(0, 10) };
    try triangulate(testing.allocator, &notched, 0, &corners);
    try testing.expectEqual(@as(usize, 18), corners.items.len);
    var i: usize = 0;
    while (i < corners.items.len) : (i += 3) {
        const a = notched[corners.items[i]];
        const b = notched[corners.items[i + 1]];
        const c = notched[corners.items[i + 2]];
        const middle = a.add(b).add(c).scale(1.0 / 3.0);
        try testing.expect(!(middle.x > 4 and middle.y > 3 and middle.y < 7));
    }

    // Drawn the other way round, the same count.
    corners.clearRetainingCapacity();
    var reversed = notched;
    std.mem.reverse(Vec2, &reversed);
    try triangulate(testing.allocator, &reversed, 0, &corners);
    try testing.expectEqual(@as(usize, 18), corners.items.len);
}
