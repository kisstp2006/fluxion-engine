// SPDX-License-Identifier: BSD-3-Clause

//! Lightmap UVs: a second place on a picture for each vertex, where no two
//! triangles overlap, so a lightmap holds a light of its own for every part
//! of a surface. The shapes made from numbers lay theirs out with `layOut`;
//! a mesh that comes without them - a model's, unless it brings its own -
//! gets them from `unwrap`.
//!
//! A surface is cut into charts, pieces that face nearly one way, each laid
//! flat. The charts are packed into a square with a gap round each, and the
//! mesh says how many texels across the square has to be at least for the
//! gaps to be `gap_texels` wide: `Mesh.uv2_texels`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const math = @import("fluxion_math");

const mesh = @import("mesh.zig");
const Mesh = mesh.Mesh;
const Vertex = mesh.Vertex;

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;

/// How wide a gap between two charts is, in texels, at `Mesh.uv2_texels`.
pub const gap_texels = 2;

/// How far from a chart's way a triangle may face and still join it: sixty
/// degrees.
const reach = 0.5;

/// Lay charts out in a square. `flat[i]` is vertex `i`'s place on its chart,
/// `chart_of[i]`, in the world's units; it becomes its place in the square,
/// nought to one, each chart as big as the others for its size in the
/// world. Returns how many texels across the square has to be for the gaps
/// between the charts to be `gap_texels` wide.
pub fn layOut(gpa: Allocator, flat: []Vec2, chart_of: []const u32, chart_count: u32) Allocator.Error!u32 {
    if (flat.len == 0 or chart_count == 0) return 0;
    const Box = struct { min: Vec2, max: Vec2, used: bool };
    const boxes = try gpa.alloc(Box, chart_count);
    defer gpa.free(boxes);
    @memset(boxes, .{ .min = .splat(std.math.floatMax(f32)), .max = .splat(-std.math.floatMax(f32)), .used = false });
    for (flat, chart_of) |p, c| {
        const box = &boxes[c];
        box.min = .init(@min(box.min.x, p.x), @min(box.min.y, p.y));
        box.max = .init(@max(box.max.x, p.x), @max(box.max.y, p.y));
        box.used = true;
    }
    var area: f64 = 0;
    var longest: f32 = 0;
    for (boxes) |*box| {
        if (!box.used) box.* = .{ .min = .zero, .max = .zero, .used = false };
        const size = box.max.sub(box.min);
        area += @as(f64, size.x) * size.y;
        longest = @max(longest, @max(size.x, size.y));
    }

    // More charts need more texels for a gap round each.
    const texels = @max(64, 8 * @sqrt(@as(f32, @floatFromInt(chart_count))));
    const estimate = @max(@as(f32, @floatCast(@sqrt(area))) * 1.25, longest, 1e-6);
    const pad = gap_texels * estimate / texels;

    // Tallest first, on shelves: the width that makes the squarest whole.
    const order = try gpa.alloc(u32, chart_count);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const Taller = struct {
        fn lessThan(all: []const Box, a: u32, b: u32) bool {
            const ha = all[a].max.y - all[a].min.y;
            const hb = all[b].max.y - all[b].min.y;
            if (ha != hb) return ha > hb;
            return a < b;
        }
    };
    std.mem.sort(u32, order, @as([]const Box, boxes), Taller.lessThan);
    const places = try gpa.alloc(Vec2, chart_count);
    defer gpa.free(places);
    const trying = try gpa.alloc(Vec2, chart_count);
    defer gpa.free(trying);
    var side: f32 = std.math.floatMax(f32);
    for (0..15) |step| {
        const width = @max(estimate * (0.7 + 0.05 * @as(f32, @floatFromInt(step))), longest + pad);
        var x: f32 = 0;
        var y: f32 = 0;
        var shelf: f32 = 0;
        var widest: f32 = 0;
        for (order) |c| {
            const size = boxes[c].max.sub(boxes[c].min).add(.splat(pad));
            if (x > 0 and x + size.x > width) {
                y += shelf;
                x = 0;
                shelf = 0;
            }
            trying[c] = .init(x, y);
            x += size.x;
            widest = @max(widest, x);
            shelf = @max(shelf, size.y);
        }
        const whole = @max(widest, y + shelf);
        if (whole < side) {
            side = whole;
            @memcpy(places, trying);
        }
    }

    for (flat, chart_of) |*p, c| {
        const at = places[c].add(.splat(pad / 2)).add(p.sub(boxes[c].min));
        p.* = at.scale(1 / side);
    }
    return @intFromFloat(@ceil(gap_texels * side / pad));
}

/// Give `mesh` lightmap UVs of its own, and `uv2_texels`: its triangles cut
/// into charts that face nearly one way, joined across the edges they
/// share, each laid flat and turned to fit the smallest box, and packed by
/// `layOut`. Where a chart's edge runs between two triangles their corners
/// are split into a vertex for each, so the mesh may have more vertices
/// after; its indices name the same corners as before, in the same order.
pub fn unwrap(gpa: Allocator, target: *Mesh) Allocator.Error!void {
    const triangles = target.indices.len / 3;
    if (triangles == 0) {
        target.uv2_texels = 0;
        return;
    }
    const vertices = target.vertices;
    const indices = target.indices;

    // Each triangle's way and size.
    const normals = try gpa.alloc(Vec3, triangles);
    defer gpa.free(normals);
    const areas = try gpa.alloc(f32, triangles);
    defer gpa.free(areas);
    var largest: f32 = 0;
    for (normals, areas, 0..) |*n, *a, t| {
        const p0 = Vec3.fromArray(vertices[indices[3 * t]].position);
        const p1 = Vec3.fromArray(vertices[indices[3 * t + 1]].position);
        const p2 = Vec3.fromArray(vertices[indices[3 * t + 2]].position);
        const cross = p1.sub(p0).cross(p2.sub(p0));
        a.* = cross.len() / 2;
        n.* = cross.tryNorm() orelse .zero;
        largest = @max(largest, a.*);
    }
    const tiny = largest * 1e-7;

    // Corners that are one point are one, whichever vertex each is.
    const welded = try weld(gpa, target.*);
    defer gpa.free(welded);

    // The triangles either side of each edge.
    var edges: std.AutoHashMapUnmanaged(u64, [2]u32) = .empty;
    defer edges.deinit(gpa);
    const none = std.math.maxInt(u32);
    for (0..triangles) |t| {
        for (0..3) |k| {
            const key = edgeKey(welded[indices[3 * t + k]], welded[indices[3 * t + (k + 1) % 3]]) orelse continue;
            const found = try edges.getOrPut(gpa, key);
            if (!found.found_existing) {
                found.value_ptr.* = .{ @intCast(t), none };
            } else if (found.value_ptr[1] == none) {
                found.value_ptr[1] = @intCast(t);
            } else {
                // More than two: not a surface there, so no way across.
                found.value_ptr.* = .{ none - 1, none - 1 };
            }
        }
    }

    // Charts, grown from the largest triangle left, across shared edges, to
    // the triangles that face nearly its way.
    const chart_of_triangle = try gpa.alloc(u32, triangles);
    defer gpa.free(chart_of_triangle);
    @memset(chart_of_triangle, none);
    const by_size = try gpa.alloc(u32, triangles);
    defer gpa.free(by_size);
    for (by_size, 0..) |*t, i| t.* = @intCast(i);
    const Larger = struct {
        fn lessThan(all: []const f32, a: u32, b: u32) bool {
            if (all[a] != all[b]) return all[a] > all[b];
            return a < b;
        }
    };
    std.mem.sort(u32, by_size, @as([]const f32, areas), Larger.lessThan);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(gpa);
    var chart_count: u32 = 0;
    for (by_size) |seed| {
        if (chart_of_triangle[seed] != none) continue;
        const chart = chart_count;
        chart_count += 1;
        const way = normals[seed];
        chart_of_triangle[seed] = chart;
        queue.clearRetainingCapacity();
        try queue.append(gpa, seed);
        while (queue.pop()) |t| {
            for (0..3) |k| {
                const key = edgeKey(welded[indices[3 * t + k]], welded[indices[3 * t + (k + 1) % 3]]) orelse continue;
                const pair = edges.get(key).?;
                const other = if (pair[0] == t) pair[1] else pair[0];
                if (other >= none - 1 or chart_of_triangle[other] != none) continue;
                if (areas[other] > tiny and normals[other].dot(way) < reach) continue;
                chart_of_triangle[other] = chart;
                try queue.append(gpa, other);
            }
        }
    }

    // Each chart's plane: the way its triangles face, by their size.
    const planes = try gpa.alloc([2]Vec3, chart_count);
    defer gpa.free(planes);
    {
        const ways = try gpa.alloc(Vec3, chart_count);
        defer gpa.free(ways);
        @memset(ways, .zero);
        for (chart_of_triangle, normals, areas) |c, n, a| ways[c] = ways[c].add(n.scale(a));
        for (planes, ways) |*plane, way| {
            const n = way.tryNorm() orelse Vec3.unit_y;
            const across = n.anyPerp().norm();
            plane.* = .{ across, n.cross(across) };
        }
    }

    // A vertex for each corner's vertex and chart, laid flat on the chart.
    var split: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer split.deinit(gpa);
    var out_vertices: std.ArrayList(Vertex) = .empty;
    defer out_vertices.deinit(gpa);
    var out_chart: std.ArrayList(u32) = .empty;
    defer out_chart.deinit(gpa);
    var flat: std.ArrayList(Vec2) = .empty;
    defer flat.deinit(gpa);
    const out_indices = try gpa.alloc(u32, indices.len);
    errdefer gpa.free(out_indices);
    for (indices, 0..) |v, i| {
        const chart = chart_of_triangle[i / 3];
        const found = try split.getOrPut(gpa, (@as(u64, v) << 32) | chart);
        if (!found.found_existing) {
            found.value_ptr.* = @intCast(out_vertices.items.len);
            try out_vertices.append(gpa, vertices[v]);
            try out_chart.append(gpa, chart);
            const p = Vec3.fromArray(vertices[v].position);
            try flat.append(gpa, .init(p.dot(planes[chart][0]), p.dot(planes[chart][1])));
        }
        out_indices[i] = found.value_ptr.*;
    }

    try turnSmallest(gpa, flat.items, out_chart.items, chart_count);
    const texels = try layOut(gpa, flat.items, out_chart.items, chart_count);
    for (out_vertices.items, flat.items) |*v, p| v.uv2 = p.array();

    const own_vertices = try out_vertices.toOwnedSlice(gpa);
    gpa.free(target.vertices);
    gpa.free(target.indices);
    target.vertices = own_vertices;
    target.indices = out_indices;
    target.uv2_texels = texels;
}

/// An edge's key, the same either way along it; null for one of no length.
fn edgeKey(a: u32, b: u32) ?u64 {
    if (a == b) return null;
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

/// Each vertex's first vertex at its place, a millionth of the mesh's size
/// apart counting as one place.
fn weld(gpa: Allocator, of: Mesh) Allocator.Error![]u32 {
    const out = try gpa.alloc(u32, of.vertices.len);
    errdefer gpa.free(out);
    const size = of.bounds.max.sub(of.bounds.min).len();
    const step = @max(size * 1e-6, 1e-9);
    var seen: std.AutoHashMapUnmanaged([3]i64, u32) = .empty;
    defer seen.deinit(gpa);
    for (of.vertices, out, 0..) |v, *o, i| {
        var key: [3]i64 = undefined;
        for (&key, v.position) |*k, p| k.* = @intFromFloat(@round(p / step));
        const found = try seen.getOrPut(gpa, key);
        if (!found.found_existing) found.value_ptr.* = @intCast(i);
        o.* = found.value_ptr.*;
    }
    return out;
}

/// Turn each chart so the box round it is the smallest it can be: lined up
/// with one of the edges round its outside.
fn turnSmallest(gpa: Allocator, flat: []Vec2, chart_of: []const u32, chart_count: u32) Allocator.Error!void {
    // Each chart's points, together.
    const starts = try gpa.alloc(u32, chart_count + 1);
    defer gpa.free(starts);
    @memset(starts, 0);
    for (chart_of) |c| starts[c + 1] += 1;
    for (1..starts.len) |i| starts[i] += starts[i - 1];
    const members = try gpa.alloc(u32, flat.len);
    defer gpa.free(members);
    const filled = try gpa.alloc(u32, chart_count);
    defer gpa.free(filled);
    @memset(filled, 0);
    for (chart_of, 0..) |c, i| {
        members[starts[c] + filled[c]] = @intCast(i);
        filled[c] += 1;
    }

    var points: std.ArrayList(Vec2) = .empty;
    defer points.deinit(gpa);
    var hull: std.ArrayList(Vec2) = .empty;
    defer hull.deinit(gpa);
    for (0..chart_count) |c| {
        const mine = members[starts[c]..starts[c + 1]];
        if (mine.len < 3) continue;
        points.clearRetainingCapacity();
        for (mine) |m| try points.append(gpa, flat[m]);
        try convexHull(gpa, points.items, &hull);
        if (hull.items.len < 3) continue;
        var best_area: f32 = std.math.floatMax(f32);
        var best: Vec2 = .unit_x;
        for (hull.items, 0..) |a, i| {
            const b = hull.items[(i + 1) % hull.items.len];
            const along = b.sub(a).tryNorm() orelse continue;
            const up = along.perp();
            var lo: Vec2 = .splat(std.math.floatMax(f32));
            var hi: Vec2 = .splat(-std.math.floatMax(f32));
            for (hull.items) |p| {
                const q: Vec2 = .init(p.dot(along), p.dot(up));
                lo = .init(@min(lo.x, q.x), @min(lo.y, q.y));
                hi = .init(@max(hi.x, q.x), @max(hi.y, q.y));
            }
            const area = (hi.x - lo.x) * (hi.y - lo.y);
            if (area < best_area) {
                best_area = area;
                best = along;
            }
        }
        const up = best.perp();
        for (mine) |m| flat[m] = .init(flat[m].dot(best), flat[m].dot(up));
    }
}

/// The corners round the outside of `points`, anticlockwise: Andrew's
/// monotone chain. Sorts `points`.
fn convexHull(gpa: Allocator, points: []Vec2, out: *std.ArrayList(Vec2)) Allocator.Error!void {
    const ByPlace = struct {
        fn lessThan(_: void, a: Vec2, b: Vec2) bool {
            if (a.x != b.x) return a.x < b.x;
            return a.y < b.y;
        }
    };
    std.mem.sort(Vec2, points, {}, ByPlace.lessThan);
    out.clearRetainingCapacity();
    // The lower chain, then the upper.
    for (0..2) |pass| {
        const start = out.items.len;
        var i: usize = 0;
        while (i < points.len) : (i += 1) {
            const p = if (pass == 0) points[i] else points[points.len - 1 - i];
            while (out.items.len >= start + 2) {
                const a = out.items[out.items.len - 2];
                const b = out.items[out.items.len - 1];
                if (b.sub(a).crossZ(p.sub(a)) > 0) break;
                _ = out.pop();
            }
            try out.append(gpa, p);
        }
        _ = out.pop();
    }
}

/// How many texels of a square `texels` across more than one triangle of
/// `of`'s lightmap UVs covers: nought where none overlap. Each texel is
/// looked at in its middle.
pub fn overlaps(gpa: Allocator, of: Mesh, texels: u32) Allocator.Error!usize {
    const counts = try gpa.alloc(u8, @as(usize, texels) * texels);
    defer gpa.free(counts);
    @memset(counts, 0);
    const size: f32 = @floatFromInt(texels);
    var at: usize = 0;
    while (at + 3 <= of.indices.len) : (at += 3) {
        const a = Vec2.fromArray(of.vertices[of.indices[at]].uv2).scale(size);
        const b = Vec2.fromArray(of.vertices[of.indices[at + 1]].uv2).scale(size);
        const c = Vec2.fromArray(of.vertices[of.indices[at + 2]].uv2).scale(size);
        const twice = b.sub(a).crossZ(c.sub(a));
        if (@abs(twice) < 1e-12) continue;
        const x0: usize = @intFromFloat(std.math.clamp(@floor(@min(a.x, b.x, c.x)), 0, size - 1));
        const x1: usize = @intFromFloat(std.math.clamp(@ceil(@max(a.x, b.x, c.x)), 0, size - 1));
        const y0: usize = @intFromFloat(std.math.clamp(@floor(@min(a.y, b.y, c.y)), 0, size - 1));
        const y1: usize = @intFromFloat(std.math.clamp(@ceil(@max(a.y, b.y, c.y)), 0, size - 1));
        for (y0..y1 + 1) |y| for (x0..x1 + 1) |x| {
            const p: Vec2 = .init(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
            const w0 = b.sub(p).crossZ(c.sub(p)) / twice;
            const w1 = c.sub(p).crossZ(a.sub(p)) / twice;
            const w2 = 1 - w0 - w1;
            const edge = 1e-4;
            if (w0 > edge and w1 > edge and w2 > edge) counts[y * texels + x] +|= 1;
        };
    }
    var over: usize = 0;
    for (counts) |n| {
        if (n > 1) over += 1;
    }
    return over;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn expectInSquare(of: Mesh) !void {
    for (of.vertices) |v| {
        try testing.expect(v.uv2[0] >= 0 and v.uv2[0] <= 1);
        try testing.expect(v.uv2[1] >= 0 and v.uv2[1] <= 1);
    }
}

test "charts laid out keep apart by the gap, each the size it is in the world" {
    // Three charts: a 2 by 1, a 1 by 1 and a 1 by 3.
    var flat = [_]Vec2{
        .init(0, 0), .init(2, 1),
        .init(5, 5), .init(6, 6),
        .init(0, 0), .init(1, 3),
    };
    const chart_of = [_]u32{ 0, 0, 1, 1, 2, 2 };
    const texels = try layOut(testing.allocator, &flat, &chart_of, 3);
    try testing.expect(texels > 0);
    for (flat) |p| try testing.expect(p.x >= 0 and p.x <= 1 and p.y >= 0 and p.y <= 1);
    // As big as each other: the first chart twice as wide as the second.
    const first = flat[1].sub(flat[0]);
    const second = flat[3].sub(flat[2]);
    try testing.expectApproxEqRel(first.x, 2 * second.x, 1e-4);
    // Each box at least the gap from each other, at the texels said.
    const gap = gap_texels / @as(f32, @floatFromInt(texels));
    for (0..3) |i| for (i + 1..3) |j| {
        const a_lo = flat[2 * i];
        const a_hi = flat[2 * i + 1];
        const b_lo = flat[2 * j];
        const b_hi = flat[2 * j + 1];
        const apart_x = @max(b_lo.x - a_hi.x, a_lo.x - b_hi.x);
        const apart_y = @max(b_lo.y - a_hi.y, a_lo.y - b_hi.y);
        try testing.expect(@max(apart_x, apart_y) >= gap * 0.999);
    };
}

test "a mesh unwrapped has lightmap UVs where no two triangles overlap, and the same corners" {
    // A sphere's own UVs meet at the poles; its lightmap UVs may not.
    var ball = try mesh.sphere(testing.allocator, 1, 12, 24);
    defer ball.deinit(testing.allocator);
    const before = try testing.allocator.dupe(Vertex, ball.vertices);
    defer testing.allocator.free(before);
    const before_indices = try testing.allocator.dupe(u32, ball.indices);
    defer testing.allocator.free(before_indices);
    for (ball.vertices) |*v| v.uv2 = .{ 0, 0 };

    try unwrap(testing.allocator, &ball);
    try testing.expect(ball.uv2_texels > 0);
    try testing.expect(ball.vertices.len >= before.len);
    try expectInSquare(ball);
    try testing.expectEqual(@as(usize, 0), try overlaps(testing.allocator, ball, ball.uv2_texels * 2));
    // Every corner where it was, with the normal it had.
    for (ball.indices, before_indices) |now, was| {
        try testing.expectEqual(before[was].position, ball.vertices[now].position);
        try testing.expectEqual(before[was].normal, ball.vertices[now].normal);
        try testing.expectEqual(before[was].uv, ball.vertices[now].uv);
    }

    // A box's six sides are six charts, none turned onto another.
    var crate = try mesh.box(testing.allocator, .init(1, 2, 3));
    defer crate.deinit(testing.allocator);
    try unwrap(testing.allocator, &crate);
    try expectInSquare(crate);
    try testing.expectEqual(@as(usize, 24), crate.vertices.len);
    try testing.expectEqual(@as(usize, 0), try overlaps(testing.allocator, crate, crate.uv2_texels * 2));
}

test "an empty mesh, or one of only lines, unwraps to nothing to light" {
    var empty = try Mesh.init(testing.allocator, &.{}, &.{});
    defer empty.deinit(testing.allocator);
    try unwrap(testing.allocator, &empty);
    try testing.expectEqual(@as(u32, 0), empty.uv2_texels);

    // Two triangles of no area: still laid out, apart.
    const line = [_]Vertex{
        .{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 } },
        .{ .position = .{ 1, 0, 0 }, .normal = .{ 0, 1, 0 } },
        .{ .position = .{ 2, 0, 0 }, .normal = .{ 0, 1, 0 } },
    };
    var flat_mesh = try Mesh.init(testing.allocator, &line, &.{ 0, 1, 2, 2, 1, 0 });
    defer flat_mesh.deinit(testing.allocator);
    try unwrap(testing.allocator, &flat_mesh);
    try expectInSquare(flat_mesh);
}
