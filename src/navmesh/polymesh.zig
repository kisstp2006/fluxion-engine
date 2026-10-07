// SPDX-License-Identifier: BSD-3-Clause

//! The outlines made polygons: each cut into triangles by its ears, the
//! triangles joined into convex polygons of up to `max_vertices` corners,
//! corners shared where outlines meet, and each polygon told which is
//! across each of its edges.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const contours = @import("contours.zig");
const Point = contours.Point;

pub const max_vertices = 6;
pub const none = std.math.maxInt(u32);

/// A corner on the grid: cells across and deep, steps up.
pub const Vertex = struct { x: i32, y: i32, z: i32 };

pub const Polygon = struct {
    /// Its corners, `none` past the last.
    vertices: [max_vertices]u32 = @splat(none),
    /// The polygon across the edge from each corner to the next, or `none`.
    neighbours: [max_vertices]u32 = @splat(none),
    region: u16 = 0,
    area: u8 = 0,

    pub fn count(self: Polygon) usize {
        for (self.vertices, 0..) |v, i| {
            if (v == none) return i;
        }
        return max_vertices;
    }
};

pub const Mesh = struct {
    vertices: std.ArrayList(Vertex) = .empty,
    polygons: std.ArrayList(Polygon) = .empty,
    /// Outlines that would not be cut into triangles whole.
    bad_outlines: usize = 0,

    pub fn deinit(self: *Mesh, gpa: Allocator) void {
        self.vertices.deinit(gpa);
        self.polygons.deinit(gpa);
        self.* = undefined;
    }
};

pub fn build(gpa: Allocator, set: *const contours.Set) Allocator.Error!Mesh {
    var mesh: Mesh = .{};
    errdefer mesh.deinit(gpa);
    var welder: Welder = .{};
    defer welder.deinit(gpa);

    var indices: std.ArrayList(u32) = .empty;
    defer indices.deinit(gpa);
    var triangles: std.ArrayList([3]u32) = .empty;
    defer triangles.deinit(gpa);
    var polys: std.ArrayList(Polygon) = .empty;
    defer polys.deinit(gpa);
    var shared: std.ArrayList(u32) = .empty;
    defer shared.deinit(gpa);

    for (set.contours.items) |outline| {
        const points = outline.points;
        if (points.len < 3) continue;
        try indices.resize(gpa, points.len);
        for (indices.items, 0..) |*index, j| index.* = @intCast(j);
        triangles.clearRetainingCapacity();
        if (!try triangulate(gpa, points, indices.items, &triangles)) mesh.bad_outlines += 1;

        // The outline's corners, shared with any other's in the same place.
        try shared.resize(gpa, points.len);
        for (points, shared.items) |p, *s| s.* = try welder.add(gpa, &mesh.vertices, .{ .x = p.x, .y = p.y, .z = p.z });

        polys.clearRetainingCapacity();
        for (triangles.items) |t| {
            if (t[0] == t[1] or t[0] == t[2] or t[1] == t[2]) continue;
            var poly: Polygon = .{ .region = outline.region, .area = outline.area };
            poly.vertices[0] = shared.items[t[0]];
            poly.vertices[1] = shared.items[t[1]];
            poly.vertices[2] = shared.items[t[2]];
            try polys.append(gpa, poly);
        }
        // The two whose shared edge is longest, joined while the join is
        // convex and small enough.
        while (polys.items.len > 1) {
            var best: i64 = 0;
            var best_a: usize = 0;
            var best_b: usize = 0;
            var best_ea: usize = 0;
            var best_eb: usize = 0;
            for (polys.items[0 .. polys.items.len - 1], 0..) |pa, a| {
                for (polys.items[a + 1 ..], a + 1..) |pb, b| {
                    const value = mergeValue(pa, pb, mesh.vertices.items) orelse continue;
                    if (value.length > best) {
                        best = value.length;
                        best_a = a;
                        best_b = b;
                        best_ea = value.ea;
                        best_eb = value.eb;
                    }
                }
            }
            if (best == 0) break;
            polys.items[best_a] = merged(polys.items[best_a], polys.items[best_b], best_ea, best_eb);
            _ = polys.swapRemove(best_b);
        }
        try mesh.polygons.appendSlice(gpa, polys.items);
    }
    try connect(gpa, &mesh);
    return mesh;
}

/// Corners in the same place - the same cell corner, within two steps of
/// height - made one.
const Welder = struct {
    first: std.AutoHashMapUnmanaged([2]i32, u32) = .empty,
    next: std.ArrayList(u32) = .empty,

    fn deinit(self: *Welder, gpa: Allocator) void {
        self.first.deinit(gpa);
        self.next.deinit(gpa);
    }

    fn add(self: *Welder, gpa: Allocator, vertices: *std.ArrayList(Vertex), v: Vertex) Allocator.Error!u32 {
        const entry = try self.first.getOrPut(gpa, .{ v.x, v.z });
        if (entry.found_existing) {
            var at = entry.value_ptr.*;
            while (at != none) : (at = self.next.items[at]) {
                const w = vertices.items[at];
                if (@abs(w.y - v.y) <= 2) return at;
            }
        }
        const index: u32 = @intCast(vertices.items.len);
        try vertices.append(gpa, v);
        try self.next.append(gpa, if (entry.found_existing) entry.value_ptr.* else none);
        entry.value_ptr.* = index;
        return index;
    }
};

const Merge = struct { length: i64, ea: usize, eb: usize };

/// Whether two polygons share an edge and would make one convex polygon of
/// no more than `max_vertices` corners: how long the edge is, squared.
fn mergeValue(pa: Polygon, pb: Polygon, verts: []const Vertex) ?Merge {
    const na = pa.count();
    const nb = pb.count();
    if (na + nb - 2 > max_vertices) return null;
    var ea: ?usize = null;
    var eb: ?usize = null;
    outer: for (0..na) |i| {
        var va0 = pa.vertices[i];
        var va1 = pa.vertices[(i + 1) % na];
        if (va0 > va1) std.mem.swap(u32, &va0, &va1);
        for (0..nb) |j| {
            var vb0 = pb.vertices[j];
            var vb1 = pb.vertices[(j + 1) % nb];
            if (vb0 > vb1) std.mem.swap(u32, &vb0, &vb1);
            if (va0 == vb0 and va1 == vb1) {
                ea = i;
                eb = j;
                break :outer;
            }
        }
    }
    const a = ea orelse return null;
    const b = eb orelse return null;
    // Convex where the two meet, at both ends of the edge.
    if (!uleft(verts[pa.vertices[(a + na - 1) % na]], verts[pa.vertices[a]], verts[pb.vertices[(b + 2) % nb]])) return null;
    if (!uleft(verts[pb.vertices[(b + nb - 1) % nb]], verts[pb.vertices[b]], verts[pa.vertices[(a + 2) % na]])) return null;
    const v0 = verts[pa.vertices[a]];
    const v1 = verts[pa.vertices[(a + 1) % na]];
    const dx: i64 = v0.x - v1.x;
    const dz: i64 = v0.z - v1.z;
    return .{ .length = dx * dx + dz * dz, .ea = a, .eb = b };
}

fn uleft(a: Vertex, b: Vertex, c: Vertex) bool {
    return @as(i64, b.x - a.x) * (c.z - a.z) - @as(i64, c.x - a.x) * (b.z - a.z) < 0;
}

fn merged(pa: Polygon, pb: Polygon, ea: usize, eb: usize) Polygon {
    const na = pa.count();
    const nb = pb.count();
    var out: Polygon = .{ .region = pa.region, .area = pa.area };
    var n: usize = 0;
    for (0..na - 1) |i| {
        out.vertices[n] = pa.vertices[(ea + 1 + i) % na];
        n += 1;
    }
    for (0..nb - 1) |i| {
        out.vertices[n] = pb.vertices[(eb + 1 + i) % nb];
        n += 1;
    }
    return out;
}

/// Tell each polygon which polygon is across each of its edges: two that
/// share an edge go along it opposite ways.
fn connect(gpa: Allocator, mesh: *Mesh) Allocator.Error!void {
    const Edge = struct { poly: u32, edge: u8, other: u32 = none, other_edge: u8 = 0 };
    var edges: std.AutoHashMapUnmanaged([2]u32, Edge) = .empty;
    defer edges.deinit(gpa);
    for (mesh.polygons.items, 0..) |p, i| {
        const n = p.count();
        for (0..n) |j| {
            const v0 = p.vertices[j];
            const v1 = p.vertices[(j + 1) % n];
            if (v0 < v1) try edges.put(gpa, .{ v0, v1 }, .{ .poly = @intCast(i), .edge = @intCast(j) });
        }
    }
    for (mesh.polygons.items, 0..) |p, i| {
        const n = p.count();
        for (0..n) |j| {
            const v0 = p.vertices[j];
            const v1 = p.vertices[(j + 1) % n];
            if (v0 <= v1) continue;
            const e = edges.getPtr(.{ v1, v0 }) orelse continue;
            if (e.other != none or e.poly == i) continue;
            e.other = @intCast(i);
            e.other_edge = @intCast(j);
        }
    }
    var it = edges.valueIterator();
    while (it.next()) |e| {
        if (e.other == none) continue;
        mesh.polygons.items[e.poly].neighbours[e.edge] = e.other;
        mesh.polygons.items[e.other].neighbours[e.other_edge] = e.poly;
    }
}

// -------------------------------------------------------------------------
// Ears
// -------------------------------------------------------------------------

/// A corner that can be cut off as an ear.
const removable: u32 = 0x8000_0000;
const index_mask: u32 = 0x0fff_ffff;

/// Cut a simple outline into triangles, each time the ear whose cut is
/// shortest; false when the outline crosses itself and some of it is left.
fn triangulate(gpa: Allocator, points: []const Point, indices: []u32, out: *std.ArrayList([3]u32)) Allocator.Error!bool {
    var n = indices.len;
    for (0..n) |i| {
        const j1 = next(i, n);
        const j2 = next(j1, n);
        if (diagonal(i, j2, n, points, indices)) indices[j1] |= removable;
    }
    while (n > 3) {
        var min_len: i64 = -1;
        var mini: ?usize = null;
        for (0..n) |i| {
            const j1 = next(i, n);
            if (indices[j1] & removable == 0) continue;
            const len = lengthSq(points[indices[i] & index_mask], points[indices[next(j1, n)] & index_mask]);
            if (min_len < 0 or len < min_len) {
                min_len = len;
                mini = i;
            }
        }
        if (mini == null) {
            // Overlapping edges, as a simplified outline can have: tried
            // again a little looser.
            for (0..n) |i| {
                const j1 = next(i, n);
                const j2 = next(j1, n);
                if (!diagonalLoose(i, j2, n, points, indices)) continue;
                const len = lengthSq(points[indices[i] & index_mask], points[indices[j2] & index_mask]);
                if (min_len < 0 or len < min_len) {
                    min_len = len;
                    mini = i;
                }
            }
            if (mini == null) return false;
        }
        const i = mini.?;
        var j1 = next(i, n);
        const j2 = next(j1, n);
        try out.append(gpa, .{ indices[i] & index_mask, indices[j1] & index_mask, indices[j2] & index_mask });
        // The ear's corner gone.
        n -= 1;
        var k = j1;
        while (k < n) : (k += 1) indices[k] = indices[k + 1];
        if (j1 >= n) j1 = 0;
        const before = prev(j1, n);
        if (diagonal(prev(before, n), j1, n, points, indices)) indices[before] |= removable else indices[before] &= index_mask;
        if (diagonal(before, next(j1, n), n, points, indices)) indices[j1] |= removable else indices[j1] &= index_mask;
    }
    try out.append(gpa, .{ indices[0] & index_mask, indices[1] & index_mask, indices[2] & index_mask });
    return true;
}

fn next(i: usize, n: usize) usize {
    return if (i + 1 < n) i + 1 else 0;
}

fn prev(i: usize, n: usize) usize {
    return if (i >= 1) i - 1 else n - 1;
}

fn lengthSq(a: Point, b: Point) i64 {
    const dx: i64 = b.x - a.x;
    const dz: i64 = b.z - a.z;
    return dx * dx + dz * dz;
}

fn area2(a: Point, b: Point, c: Point) i64 {
    return @as(i64, b.x - a.x) * (c.z - a.z) - @as(i64, c.x - a.x) * (b.z - a.z);
}

fn left(a: Point, b: Point, c: Point) bool {
    return area2(a, b, c) < 0;
}

fn leftOn(a: Point, b: Point, c: Point) bool {
    return area2(a, b, c) <= 0;
}

fn collinear(a: Point, b: Point, c: Point) bool {
    return area2(a, b, c) == 0;
}

fn intersectProp(a: Point, b: Point, c: Point, d: Point) bool {
    if (collinear(a, b, c) or collinear(a, b, d) or collinear(c, d, a) or collinear(c, d, b)) return false;
    return (left(a, b, c) != left(a, b, d)) and (left(c, d, a) != left(c, d, b));
}

fn between(a: Point, b: Point, c: Point) bool {
    if (!collinear(a, b, c)) return false;
    if (a.x != b.x) return (a.x <= c.x and c.x <= b.x) or (a.x >= c.x and c.x >= b.x);
    return (a.z <= c.z and c.z <= b.z) or (a.z >= c.z and c.z >= b.z);
}

fn intersect(a: Point, b: Point, c: Point, d: Point) bool {
    if (intersectProp(a, b, c, d)) return true;
    return between(a, b, c) or between(a, b, d) or between(c, d, a) or between(c, d, b);
}

fn sameSpot(a: Point, b: Point) bool {
    return a.x == b.x and a.z == b.z;
}

/// Whether `i`-`j` crosses no edge of the outline but those at its ends.
fn diagonalie(i: usize, j: usize, n: usize, points: []const Point, indices: []const u32, loose: bool) bool {
    const d0 = points[indices[i] & index_mask];
    const d1 = points[indices[j] & index_mask];
    for (0..n) |k| {
        const k1 = next(k, n);
        if (k == i or k1 == i or k == j or k1 == j) continue;
        const p0 = points[indices[k] & index_mask];
        const p1 = points[indices[k1] & index_mask];
        if (sameSpot(d0, p0) or sameSpot(d1, p0) or sameSpot(d0, p1) or sameSpot(d1, p1)) continue;
        if (if (loose) intersectProp(d0, d1, p0, p1) else intersect(d0, d1, p0, p1)) return false;
    }
    return true;
}

/// Whether `i`-`j` leaves corner `i` inwards.
fn inCone(i: usize, j: usize, n: usize, points: []const Point, indices: []const u32, loose: bool) bool {
    const pi = points[indices[i] & index_mask];
    const pj = points[indices[j] & index_mask];
    const pi1 = points[indices[next(i, n)] & index_mask];
    const pin1 = points[indices[prev(i, n)] & index_mask];
    if (leftOn(pin1, pi, pi1)) {
        if (loose) return leftOn(pi, pj, pin1) and leftOn(pj, pi, pi1);
        return left(pi, pj, pin1) and left(pj, pi, pi1);
    }
    return !(leftOn(pi, pj, pi1) and leftOn(pj, pi, pin1));
}

fn diagonal(i: usize, j: usize, n: usize, points: []const Point, indices: []const u32) bool {
    return inCone(i, j, n, points, indices, false) and diagonalie(i, j, n, points, indices, false);
}

fn diagonalLoose(i: usize, j: usize, n: usize, points: []const Point, indices: []const u32) bool {
    return inCone(i, j, n, points, indices, true) and diagonalie(i, j, n, points, indices, true);
}

test "an L-shaped outline is cut into triangles joined into two convex polygons" {
    // Wound as the outlines are.
    var points = [_]Point{
        .{ .x = 0, .y = 0, .z = 0, .r = 0 },
        .{ .x = 0, .y = 0, .z = 6, .r = 0 },
        .{ .x = 6, .y = 0, .z = 6, .r = 0 },
        .{ .x = 6, .y = 0, .z = 3, .r = 0 },
        .{ .x = 3, .y = 0, .z = 3, .r = 0 },
        .{ .x = 3, .y = 0, .z = 0, .r = 0 },
    };
    var set: contours.Set = .{};
    defer set.contours.deinit(testing.allocator);
    try testing.expect(contours.signedArea(&points) > 0);
    try set.contours.append(testing.allocator, .{ .points = &points, .region = 1, .area = 63 });
    var mesh = try build(testing.allocator, &set);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), mesh.bad_outlines);
    try testing.expectEqual(@as(usize, 6), mesh.vertices.items.len);
    try testing.expectEqual(@as(usize, 2), mesh.polygons.items.len);
    // Each across from the other.
    var joined: usize = 0;
    for (mesh.polygons.items, 0..) |p, i| {
        for (p.neighbours[0..p.count()]) |nb| {
            if (nb != none) {
                try testing.expect(nb != i);
                joined += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 2), joined);
}
