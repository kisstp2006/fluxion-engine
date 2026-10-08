// SPDX-License-Identifier: BSD-3-Clause

//! Fewer triangles for a mesh seen from far off: its triangles' corners
//! moved onto their neighbours, one edge at a time, the edge that changes
//! its shape least first, until there are as few as asked - or as few as
//! the error allowed leaves.
//!
//! How much an edge changes the shape is the sum of the squared distances
//! from the corner moved to the planes of the triangles it was on, and on
//! all that was moved onto it before (Garland and Heckbert's quadrics). A
//! corner only moves onto a neighbour - one already there - so every level
//! of detail is a list of indices into the mesh's own vertices: the
//! vertices are shared, and only the indices are new.
//!
//! What would show is kept as it is: a corner on an open edge, one where
//! the picture's places or the normals part - a seam, where one place has
//! several vertices - and one where the surface is not a simple sheet. A
//! collapse that would turn a triangle over, or join the surface to itself,
//! is passed over.
//!
//! The collapses are made in rounds: each round finds every edge's cost,
//! takes the cheapest that touch nothing another took this round, and the
//! next round starts from what is left. It is given plain numbers and gives
//! back plain numbers, and needs nothing but the standard library.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// How many indices to stop at, three a triangle.
    target_index_count: usize,
    /// The most a corner may move from the surface it was on, as a share of
    /// the mesh's size: what stops it before the target where the shape
    /// would change too much.
    target_error: f32 = 0.01,
};

pub const Result = struct {
    /// Three a triangle, into the vertices given: the caller's.
    indices: []u32,
    /// How far the farthest corner moved from the surface it was on, as a
    /// share of the mesh's size.
    error_share: f32,
};

/// `indices`' triangles over `positions`, fewer. `positions` are every
/// vertex's; `indices` name some of them, three a triangle.
pub fn simplify(gpa: Allocator, indices: []const u32, positions: []const [3]f32, options: Options) Allocator.Error!Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var work: Work = try .init(arena, indices, positions);
    const scale = work.extent;
    const limit: f64 = @as(f64, options.target_error) * scale;
    var worst: f64 = 0;
    var rounds: usize = 0;
    while (work.alive * 3 > options.target_index_count and rounds < max_rounds) : (rounds += 1) {
        const made = try work.round(arena, options.target_index_count, limit * limit);
        if (made.collapsed == 0) break;
        worst = @max(worst, made.worst);
    }

    const out = try gpa.alloc(u32, work.alive * 3);
    var at: usize = 0;
    for (work.corners, work.dead) |corners, dead| {
        if (dead) continue;
        @memcpy(out[at..][0..3], &corners);
        at += 3;
    }
    return .{ .indices = out, .error_share = if (scale > 0) @floatCast(@sqrt(worst) / scale) else 0 };
}

/// How many rounds at most: each takes away a share of what is left.
const max_rounds = 64;

/// A symmetric four by four: the sum of planes' squared distances, each
/// weighted by its triangle's area, and the areas summed.
const Quadric = struct {
    a: [10]f64 = @splat(0),
    weight: f64 = 0,

    fn ofPlane(n: [3]f64, d: f64, weight: f64) Quadric {
        return .{ .a = .{
            n[0] * n[0] * weight, n[0] * n[1] * weight, n[0] * n[2] * weight, n[0] * d * weight,
            n[1] * n[1] * weight, n[1] * n[2] * weight, n[1] * d * weight,    n[2] * n[2] * weight,
            n[2] * d * weight,    d * d * weight,
        }, .weight = weight };
    }

    fn add(self: *Quadric, other: Quadric) void {
        for (&self.a, other.a) |*x, y| x.* += y;
        self.weight += other.weight;
    }

    /// The mean squared distance from `p` to the planes, by their areas.
    fn meanAt(self: Quadric, p: [3]f64) f64 {
        if (!(self.weight > 0)) return 0;
        return @max(self.at(p), 0) / self.weight;
    }

    /// The squared distance - summed, weighted - from `p` to the planes.
    fn at(self: Quadric, p: [3]f64) f64 {
        const q = self.a;
        const x = p[0];
        const y = p[1];
        const z = p[2];
        return q[0] * x * x + 2 * q[1] * x * y + 2 * q[2] * x * z + 2 * q[3] * x +
            q[4] * y * y + 2 * q[5] * y * z + 2 * q[6] * y +
            q[7] * z * z + 2 * q[8] * z + q[9];
    }
};

const Work = struct {
    positions: []const [3]f32,
    /// Each triangle's corners, as vertices given.
    corners: [][3]u32,
    dead: []bool,
    alive: usize,
    /// Each vertex's place: the first vertex given at its position. Corners
    /// are joined by places; a corner keeps its own vertex.
    place: []u32,
    /// Each place's quadric: its planes, and those of the places moved onto it.
    quadrics: []Quadric,
    /// How big the mesh is: its box's longest side.
    extent: f64,

    fn init(arena: Allocator, indices: []const u32, positions: []const [3]f32) Allocator.Error!Work {
        const count = indices.len / 3;
        const corners = try arena.alloc([3]u32, count);
        const dead = try arena.alloc(bool, count);
        for (corners, dead, 0..) |*c, *d, t| {
            c.* = indices[t * 3 ..][0..3].*;
            d.* = false;
        }
        // Places: vertices at one position are one.
        const place = try arena.alloc(u32, positions.len);
        var seen: std.AutoHashMapUnmanaged([3]u32, u32) = .empty;
        try seen.ensureTotalCapacity(arena, @intCast(positions.len));
        var low: [3]f32 = @splat(std.math.inf(f32));
        var high: [3]f32 = @splat(-std.math.inf(f32));
        for (positions, place, 0..) |p, *at, v| {
            const key: [3]u32 = .{ @bitCast(p[0]), @bitCast(p[1]), @bitCast(p[2]) };
            const got = seen.getOrPutAssumeCapacity(key);
            if (!got.found_existing) got.value_ptr.* = @intCast(v);
            at.* = got.value_ptr.*;
            for (0..3) |k| {
                low[k] = @min(low[k], p[k]);
                high[k] = @max(high[k], p[k]);
            }
        }
        var extent: f64 = 0;
        if (positions.len > 0) for (0..3) |k| {
            extent = @max(extent, @as(f64, high[k] - low[k]));
        };
        const quadrics = try arena.alloc(Quadric, positions.len);
        @memset(quadrics, .{});
        var work: Work = .{ .positions = positions, .corners = corners, .dead = dead, .alive = count, .place = place, .quadrics = quadrics, .extent = extent };
        for (corners, dead) |c, *d| {
            const plane = work.planeOf(c) orelse {
                // No area: nothing to keep.
                d.* = true;
                work.alive -= 1;
                continue;
            };
            const q: Quadric = .ofPlane(plane.n, plane.d, plane.area);
            for (c) |v| quadrics[place[v]].add(q);
        }
        return work;
    }

    fn point(self: *const Work, v: u32) [3]f64 {
        const p = self.positions[v];
        return .{ p[0], p[1], p[2] };
    }

    const PlaneOf = struct { n: [3]f64, d: f64, area: f64 };

    fn planeOf(self: *const Work, c: [3]u32) ?PlaneOf {
        const n = normalOf(self.point(c[0]), self.point(c[1]), self.point(c[2]));
        const l = @sqrt(dot(n, n));
        if (!(l > 1e-30)) return null;
        const unit: [3]f64 = .{ n[0] / l, n[1] / l, n[2] / l };
        return .{ .n = unit, .d = -dot(unit, self.point(c[0])), .area = l / 2 };
    }

    const Made = struct { collapsed: usize, worst: f64 };

    /// One round of collapses.
    fn round(self: *Work, arena_parent: Allocator, target_indices: usize, limit: f64) Allocator.Error!Made {
        var arena_state: std.heap.ArenaAllocator = .init(arena_parent);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const places = self.positions.len;

        // Each place's triangles.
        const first = try arena.alloc(u32, places + 1);
        @memset(first, 0);
        for (self.corners, self.dead) |c, dead| {
            if (dead) continue;
            for (c) |v| first[self.place[v] + 1] += 1;
        }
        for (1..first.len) |i| first[i] += first[i - 1];
        const around = try arena.alloc(u32, first[places]);
        const filled = try arena.dupe(u32, first[0..places]);
        for (self.corners, self.dead, 0..) |c, dead, t| {
            if (dead) continue;
            for (c) |v| {
                const at = self.place[v];
                around[filled[at]] = @intCast(t);
                filled[at] += 1;
            }
        }
        const fan = struct {
            fn of(f: []const u32, a: []const u32, at: u32) []const u32 {
                return a[f[at]..f[at + 1]];
            }
        }.of;

        // Which places may move: on a closed sheet, with one vertex.
        const free = try arena.alloc(bool, places);
        for (free, 0..) |*is_free, p| {
            is_free.* = self.place[p] == p and self.movable(@intCast(p), fan(first, around, @intCast(p)));
        }

        // Every edge whose first end may move, with its cost.
        var candidates: std.ArrayList(Collapse) = .empty;
        try candidates.ensureTotalCapacity(arena, self.alive * 6);
        for (self.corners, self.dead) |c, dead| {
            if (dead) continue;
            for (0..3) |k| {
                const a = self.place[c[k]];
                const b = self.place[c[(k + 1) % 3]];
                inline for (.{ .{ a, b }, .{ b, a } }) |pair| {
                    if (free[pair[0]]) {
                        var q = self.quadrics[pair[0]];
                        q.add(self.quadrics[pair[1]]);
                        const cost = q.meanAt(self.point(pair[1]));
                        if (cost <= limit) candidates.appendAssumeCapacity(.{ .from = pair[0], .to = pair[1], .cost = cost });
                    }
                }
            }
        }
        std.mem.sort(Collapse, candidates.items, {}, Collapse.cheaper);

        // The cheapest that touch nothing another took, and keep the shape.
        const touched = try arena.alloc(bool, places);
        @memset(touched, false);
        const onto = try arena.alloc(u32, places);
        for (onto, 0..) |*o, p| o.* = @intCast(p);
        // The vertex at the new place a moved corner takes: the one on its
        // side of any seam, found before any corner moves.
        const onto_vertex = try arena.alloc(u32, places);
        var collapsed: usize = 0;
        var worst: f64 = 0;
        var removed: usize = 0;
        const wanted = if (self.alive * 3 > target_indices) (self.alive * 3 - target_indices) / 3 else 0;
        for (candidates.items) |c| {
            if (removed >= wanted) break;
            if (touched[c.from] or touched[c.to]) continue;
            const from_fan = fan(first, around, c.from);
            if (!self.linked(c.from, c.to, from_fan, fan(first, around, c.to))) continue;
            if (self.flips(c.from, c.to, from_fan)) continue;
            onto_vertex[c.from] = self.vertexAt(c.to, c.from, from_fan) orelse continue;
            // Taken: it and every place round it stay as they are this round.
            touched[c.from] = true;
            touched[c.to] = true;
            for (from_fan) |t| for (self.corners[t]) |v| {
                touched[self.place[v]] = true;
            };
            onto[c.from] = c.to;
            collapsed += 1;
            worst = @max(worst, c.cost);
            // An edge inside a sheet has two triangles.
            removed += 2;
        }
        if (collapsed == 0) return .{ .collapsed = 0, .worst = 0 };

        // The corners of the places moved, onto their new places' vertices:
        // the one a triangle on both shares - the same side of any seam.
        for (self.corners, self.dead) |*c, *dead| {
            if (dead.*) continue;
            for (c) |*v| {
                const from = self.place[v.*];
                const to = onto[from];
                if (to == from) continue;
                v.* = onto_vertex[from];
            }
            const p0 = self.place[c[0]];
            const p1 = self.place[c[1]];
            const p2 = self.place[c[2]];
            if (p0 == p1 or p1 == p2 or p0 == p2) {
                dead.* = true;
                self.alive -= 1;
            }
        }
        for (onto, 0..) |to, from| {
            if (to != from) self.quadrics[to].add(self.quadrics[from]);
        }
        return .{ .collapsed = collapsed, .worst = worst };
    }

    /// Whether the place `p` may move: every edge round it has two
    /// triangles - it is on no open edge, and the surface round it is a
    /// sheet - and every corner at it is one vertex.
    fn movable(self: *const Work, p: u32, fan: []const u32) bool {
        if (fan.len < 3) return false;
        var vertex: ?u32 = null;
        for (fan) |t| for (self.corners[t]) |v| {
            if (self.place[v] != p) continue;
            if (vertex) |known| {
                if (known != v) return false;
            } else vertex = v;
        };
        // Each neighbour round it is met twice, once by each of the two
        // triangles on the edge between them.
        var neighbours: [64]u32 = undefined;
        var counts: [64]u8 = undefined;
        var n: usize = 0;
        for (fan) |t| {
            const c = self.corners[t];
            for (c) |v| {
                const q = self.place[v];
                if (q == p) continue;
                for (neighbours[0..n], counts[0..n]) |known, *count| {
                    if (known == q) {
                        count.* += 1;
                        break;
                    }
                } else {
                    if (n == neighbours.len) return false;
                    neighbours[n] = q;
                    counts[n] = 1;
                    n += 1;
                }
            }
        }
        for (counts[0..n]) |count| if (count != 2) return false;
        return true;
    }

    /// Whether moving `from` onto `to` keeps the surface a sheet: they have
    /// exactly the two neighbours in common that the two triangles on their
    /// edge make.
    fn linked(self: *const Work, from: u32, to: u32, from_fan: []const u32, to_fan: []const u32) bool {
        var shared: usize = 0;
        var mine: [64]u32 = undefined;
        var n: usize = 0;
        for (from_fan) |t| for (self.corners[t]) |v| {
            const q = self.place[v];
            if (q == from or q == to) continue;
            if (std.mem.indexOfScalar(u32, mine[0..n], q) != null) continue;
            if (n == mine.len) return false;
            mine[n] = q;
            n += 1;
        };
        var theirs: [64]u32 = undefined;
        var m: usize = 0;
        for (to_fan) |t| for (self.corners[t]) |v| {
            const q = self.place[v];
            if (q == from or q == to) continue;
            if (std.mem.indexOfScalar(u32, theirs[0..m], q) != null) continue;
            if (m == theirs.len) return false;
            theirs[m] = q;
            m += 1;
            if (std.mem.indexOfScalar(u32, mine[0..n], q) != null) shared += 1;
        };
        return shared == 2;
    }

    /// Whether moving `from` onto `to` turns a triangle round `from` over,
    /// makes it as good as flat, or stands it up across the surface round
    /// `from` - a fin.
    fn flips(self: *const Work, from: u32, to: u32, from_fan: []const u32) bool {
        const target = self.point(to);
        // Which way the surface round `from` faces, by its triangles' areas.
        var surface: [3]f64 = .{ 0, 0, 0 };
        for (from_fan) |t| {
            const c = self.corners[t];
            const n = normalOf(self.point(c[0]), self.point(c[1]), self.point(c[2]));
            for (&surface, n) |*s_, x| s_.* += x;
        }
        const ls = @sqrt(dot(surface, surface));
        for (from_fan) |t| {
            const c = self.corners[t];
            var on_edge = false;
            for (c) |v| on_edge = on_edge or self.place[v] == to;
            if (on_edge) continue;
            var before: [3][3]f64 = undefined;
            var after: [3][3]f64 = undefined;
            for (c, 0..) |v, k| {
                before[k] = self.point(v);
                after[k] = if (self.place[v] == from) target else before[k];
            }
            const n0 = normalOf(before[0], before[1], before[2]);
            const n1 = normalOf(after[0], after[1], after[2]);
            const l0 = @sqrt(dot(n0, n0));
            const l1 = @sqrt(dot(n1, n1));
            if (!(l1 > 1e-12 * @max(l0, 1e-30))) return true;
            if (dot(n0, n1) < 0.2 * l0 * l1) return true;
            if (dot(surface, n1) < 0.3 * ls * l1) return true;
        }
        return false;
    }

    /// The vertex at place `to` a triangle round `from` that has both
    /// names: the one on `from`'s side.
    fn vertexAt(self: *const Work, to: u32, from: u32, from_fan: []const u32) ?u32 {
        for (from_fan) |t| {
            const c = self.corners[t];
            var has_from = false;
            for (c) |v| has_from = has_from or self.place[v] == from;
            if (!has_from) continue;
            for (c) |v| if (self.place[v] == to) return v;
        }
        return null;
    }
};

const Collapse = struct {
    from: u32,
    to: u32,
    cost: f64,

    fn cheaper(_: void, a: Collapse, b: Collapse) bool {
        return a.cost < b.cost;
    }
};

fn normalOf(a: [3]f64, b: [3]f64, c: [3]f64) [3]f64 {
    const u: [3]f64 = .{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const v: [3]f64 = .{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    return .{ u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0] };
}

fn dot(a: [3]f64, b: [3]f64) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

// -------------------------------------------------------------------------
// Tests

/// A ball of `slices` round and `stacks` down, its poles one vertex each.
fn ball(gpa: Allocator, slices: u32, stacks: u32) !struct { positions: [][3]f32, indices: []u32 } {
    var positions: std.ArrayList([3]f32) = .empty;
    errdefer positions.deinit(gpa);
    var indices: std.ArrayList(u32) = .empty;
    errdefer indices.deinit(gpa);
    try positions.append(gpa, .{ 0, 1, 0 });
    for (1..stacks) |j| {
        const phi = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(stacks)) * std.math.pi;
        for (0..slices) |i| {
            const theta = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(slices)) * std.math.tau;
            try positions.append(gpa, .{ @cos(theta) * @sin(phi), @cos(phi), -@sin(theta) * @sin(phi) });
        }
    }
    try positions.append(gpa, .{ 0, -1, 0 });
    const bottom: u32 = @intCast(positions.items.len - 1);
    const ring = struct {
        fn at(s: u32, j: usize, i: usize) u32 {
            return @intCast(1 + (j - 1) * s + i % s);
        }
    }.at;
    for (0..slices) |i| {
        try indices.appendSlice(gpa, &.{ 0, ring(slices, 1, i), ring(slices, 1, i + 1) });
        try indices.appendSlice(gpa, &.{ bottom, ring(slices, stacks - 1, i + 1), ring(slices, stacks - 1, i) });
    }
    for (1..stacks - 1) |j| {
        for (0..slices) |i| {
            const a = ring(slices, j, i);
            const b = ring(slices, j + 1, i);
            const c = ring(slices, j + 1, i + 1);
            const d = ring(slices, j, i + 1);
            try indices.appendSlice(gpa, &.{ a, b, c, a, c, d });
        }
    }
    return .{ .positions = try positions.toOwnedSlice(gpa), .indices = try indices.toOwnedSlice(gpa) };
}

/// Whether every edge of `indices` is met once each way: a closed surface
/// facing one way.
fn closedOneWay(gpa: Allocator, indices: []const u32) !bool {
    var edges: std.AutoHashMapUnmanaged([2]u32, i32) = .empty;
    defer edges.deinit(gpa);
    var t: usize = 0;
    while (t + 2 < indices.len) : (t += 3) {
        for (0..3) |k| {
            const a = indices[t + k];
            const b = indices[t + (k + 1) % 3];
            const key: [2]u32 = .{ @min(a, b), @max(a, b) };
            const got = try edges.getOrPut(gpa, key);
            if (!got.found_existing) got.value_ptr.* = 0;
            got.value_ptr.* += if (a < b) 1 else -1;
        }
    }
    var it = edges.valueIterator();
    while (it.next()) |sum| if (sum.* != 0) return false;
    return true;
}

test "a ball made of fewer triangles is still closed, facing out, and near its surface" {
    const gpa = testing.allocator;
    const made = try ball(gpa, 64, 32);
    defer gpa.free(made.positions);
    defer gpa.free(made.indices);
    const before = made.indices.len / 3;
    const fewer = try simplify(gpa, made.indices, made.positions, .{ .target_index_count = made.indices.len / 4, .target_error = 0.05 });
    defer gpa.free(fewer.indices);
    const after = fewer.indices.len / 3;
    try testing.expect(after <= before / 4 + before / 20);
    try testing.expect(after > 16);
    try testing.expect(fewer.error_share < 0.05);
    try testing.expect(try closedOneWay(gpa, fewer.indices));
    // Facing out still: every triangle's normal away from the middle.
    var t: usize = 0;
    while (t < fewer.indices.len) : (t += 3) {
        const a = made.positions[fewer.indices[t]];
        const b = made.positions[fewer.indices[t + 1]];
        const c = made.positions[fewer.indices[t + 2]];
        const n = normalOf(.{ a[0], a[1], a[2] }, .{ b[0], b[1], b[2] }, .{ c[0], c[1], c[2] });
        const middle: [3]f64 = .{ a[0] + b[0] + c[0], a[1] + b[1] + c[1], a[2] + b[2] + c[2] };
        // Out, and no fin standing across the surface.
        try testing.expect(dot(n, middle) > 0.2 * @sqrt(dot(n, n)) * @sqrt(dot(middle, middle)));
    }
}

test "the error allowed stops it before the target, and a flat sheet's edge stays as it is" {
    const gpa = testing.allocator;
    // A flat square of 16 by 16 cells: its inside can go, its edge cannot.
    const side = 17;
    var positions: [side * side][3]f32 = undefined;
    for (0..side) |j| for (0..side) |i| {
        positions[j * side + i] = .{ @floatFromInt(i), 0, @floatFromInt(j) };
    };
    var indices: std.ArrayList(u32) = .empty;
    defer indices.deinit(gpa);
    for (0..side - 1) |j| for (0..side - 1) |i| {
        const a: u32 = @intCast(j * side + i);
        try indices.appendSlice(gpa, &.{ a, a + side, a + side + 1, a, a + side + 1, a + 1 });
    };
    const flat = try simplify(gpa, indices.items, &positions, .{ .target_index_count = 6, .target_error = 0.01 });
    defer gpa.free(flat.indices);
    // Flat: no error; the edge's 64 corners stay, so at least 62 triangles.
    try testing.expectEqual(@as(f32, 0), flat.error_share);
    try testing.expect(flat.indices.len / 3 >= 62);
    try testing.expect(flat.indices.len / 3 < 512 / 2);
    var on_edge = [_]bool{false} ** (side * side);
    for (flat.indices) |v| on_edge[v] = true;
    for (0..side) |i| {
        try testing.expect(on_edge[i]);
        try testing.expect(on_edge[(side - 1) * side + i]);
    }

    // A ball with no error allowed keeps nearly all it had.
    const made = try ball(gpa, 32, 16);
    defer gpa.free(made.positions);
    defer gpa.free(made.indices);
    const kept = try simplify(gpa, made.indices, made.positions, .{ .target_index_count = 3, .target_error = 0.0001 });
    defer gpa.free(kept.indices);
    try testing.expect(kept.indices.len * 10 > made.indices.len * 9);
}

test "a seam - one place, two vertices - is kept, and each side keeps its own vertex" {
    const gpa = testing.allocator;
    // Two flat squares of 8 by 8 cells side by side, each with its own
    // vertices along the line they share.
    const side = 9;
    var positions: std.ArrayList([3]f32) = .empty;
    defer positions.deinit(gpa);
    var indices: std.ArrayList(u32) = .empty;
    defer indices.deinit(gpa);
    for (0..2) |half| {
        const base: u32 = @intCast(positions.items.len);
        for (0..side) |j| for (0..side) |i| {
            try positions.append(gpa, .{ @as(f32, @floatFromInt(i + half * (side - 1))), 0, @floatFromInt(j) });
        };
        for (0..side - 1) |j| for (0..side - 1) |i| {
            const a: u32 = base + @as(u32, @intCast(j * side + i));
            try indices.appendSlice(gpa, &.{ a, a + side, a + side + 1, a, a + side + 1, a + 1 });
        };
    }
    const fewer = try simplify(gpa, indices.items, positions.items, .{ .target_index_count = 24, .target_error = 0.01 });
    defer gpa.free(fewer.indices);
    // Every triangle uses only its own half's vertices.
    var t: usize = 0;
    while (t < fewer.indices.len) : (t += 3) {
        const half = fewer.indices[t] / (side * side);
        for (fewer.indices[t..][0..3]) |v| try testing.expectEqual(half, v / (side * side));
    }
    try testing.expect(fewer.indices.len < indices.items.len);
}
