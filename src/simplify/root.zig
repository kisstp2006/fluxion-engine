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
//! What would show keeps its line. A corner on an open edge, or on a seam -
//! where the picture's places or the normals part, so one place has two
//! vertices, or where two groups of triangles meet - moves only along it,
//! onto the next corner on it, and each side keeps a vertex of its own:
//! planes standing on the line, across the surface, hold such a corner to
//! the line as other planes hold every corner to the surface. A corner
//! where seams or edges meet or end, and one where the surface is not a
//! simple sheet, stays. A collapse that would turn a triangle over, or join
//! the surface to itself, is passed over.
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
    /// Where each group of triangles ends in `indices`, from the first: a
    /// triangle stays in its group, and where two groups meet is kept as a
    /// seam is - a mesh's surfaces, made fewer together, so no gap opens
    /// between them. None: one group.
    group_ends: []const u32 = &.{},
};

pub const Result = struct {
    /// Three a triangle, into the vertices given, each group's after the
    /// one before's.
    indices: []u32,
    /// Where each group ends in `indices`, as `Options.group_ends` were
    /// given; none when none were.
    group_ends: []u32,
    /// How far the farthest corner moved from the surface it was on, as a
    /// share of the mesh's size.
    error_share: f32,

    pub fn deinit(self: Result, gpa: Allocator) void {
        gpa.free(self.indices);
        gpa.free(self.group_ends);
    }
};

/// `indices`' triangles over `positions`, fewer. `positions` are every
/// vertex's; `indices` name some of them, three a triangle.
pub fn simplify(gpa: Allocator, indices: []const u32, positions: []const [3]f32, options: Options) Allocator.Error!Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var work: Work = try .init(arena, indices, positions, options.group_ends);
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
    errdefer gpa.free(out);
    const ends = try gpa.alloc(u32, options.group_ends.len);
    @memset(ends, 0);
    var at: usize = 0;
    for (work.corners, work.dead, work.group) |corners, dead, group| {
        if (dead) continue;
        @memcpy(out[at..][0..3], &corners);
        at += 3;
        if (ends.len > 0) ends[group] = @intCast(at);
    }
    // A group left with nothing ends where the one before did.
    if (ends.len > 1) for (1..ends.len) |g| {
        ends[g] = @max(ends[g], ends[g - 1]);
    };
    return .{ .indices = out, .group_ends = ends, .error_share = if (scale > 0) @floatCast(@sqrt(worst) / scale) else 0 };
}

/// How many rounds at most: each takes away a share of what is left.
const max_rounds = 64;
/// How near two vertices are one place, as a share of the mesh's size.
const weld_share = 1e-5;

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

    /// The plane through the line `a` to `b` that stands across the
    /// triangle `a`, `b`, `c`: what holds a corner on an open edge or a
    /// seam to it. Weighted by the line's length squared, as a triangle is
    /// by its area.
    fn ofLine(a: [3]f64, b: [3]f64, c: [3]f64, weight: f64) ?Quadric {
        const e: [3]f64 = .{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const across = cross(e, normalOf(a, b, c));
        const l = @sqrt(dot(across, across));
        if (!(l > 1e-30)) return null;
        const unit: [3]f64 = .{ across[0] / l, across[1] / l, across[2] / l };
        return .ofPlane(unit, -dot(unit, a), dot(e, e) * weight);
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
    /// Each triangle's group.
    group: []u32,
    alive: usize,
    /// Each vertex's place: the first vertex given at its position. Corners
    /// are joined by places; a corner keeps its own vertex.
    place: []u32,
    /// Each place's quadric: its planes, and those of the places moved onto it.
    quadrics: []Quadric,
    /// How big the mesh is: its box's longest side.
    extent: f64,

    fn init(arena: Allocator, indices: []const u32, positions: []const [3]f32, group_ends: []const u32) Allocator.Error!Work {
        const count = indices.len / 3;
        const corners = try arena.alloc([3]u32, count);
        const dead = try arena.alloc(bool, count);
        const group = try arena.alloc(u32, count);
        var in_group: u32 = 0;
        for (corners, dead, group, 0..) |*c, *d, *g, t| {
            c.* = indices[t * 3 ..][0..3].*;
            d.* = false;
            while (in_group < group_ends.len and t * 3 >= group_ends[in_group]) in_group += 1;
            g.* = @min(in_group, @as(u32, @intCast(@max(group_ends.len, 1))) - 1);
        }
        var low: [3]f32 = @splat(std.math.inf(f32));
        var high: [3]f32 = @splat(-std.math.inf(f32));
        for (positions) |p| for (0..3) |k| {
            low[k] = @min(low[k], p[k]);
            high[k] = @max(high[k], p[k]);
        };
        var extent: f64 = 0;
        if (positions.len > 0) for (0..3) |k| {
            extent = @max(extent, @as(f64, high[k] - low[k]));
        };
        const place = try placesOf(arena, positions, extent * weld_share);
        const quadrics = try arena.alloc(Quadric, positions.len);
        @memset(quadrics, .{});
        var work: Work = .{ .positions = positions, .corners = corners, .dead = dead, .group = group, .alive = count, .place = place, .quadrics = quadrics, .extent = extent };
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

        // The lines where the surface is open, or parted - a seam: planes
        // standing on them hold the corners on them to them.
        var edges: std.AutoHashMapUnmanaged([2]u32, Edge) = .empty;
        try edges.ensureTotalCapacity(arena, @intCast(count * 3));
        for (corners, dead, group) |c, d, g| {
            if (d) continue;
            for (0..3) |k| {
                const side: Edge = .ofSide(place, c[k], c[(k + 1) % 3], g);
                const got = edges.getOrPutAssumeCapacity(side.key);
                if (!got.found_existing) {
                    got.value_ptr.* = side;
                } else {
                    got.value_ptr.count +|= 1;
                    if (!std.meta.eql(got.value_ptr.ends, side.ends) or got.value_ptr.group != g) got.value_ptr.parted = true;
                }
            }
        }
        for (corners, dead) |c, d| {
            if (d) continue;
            for (0..3) |k| {
                const a = c[k];
                const b = c[(k + 1) % 3];
                const edge = edges.get(Edge.ofSide(place, a, b, 0).key).?;
                // An open edge has one side to hold it: twice the weight.
                const weight: f64 = if (edge.count == 1) 2 else if (edge.count == 2 and edge.parted) 1 else continue;
                const q = Quadric.ofLine(work.point(a), work.point(b), work.point(c[(k + 2) % 3]), weight) orelse continue;
                quadrics[place[a]].add(q);
                quadrics[place[b]].add(q);
            }
        }
        return work;
    }

    /// An edge between two places, as the triangles on it see it.
    const Edge = struct {
        key: [2]u32,
        /// The vertices at its lower and higher place.
        ends: [2]u32,
        group: u32,
        count: u8 = 1,
        /// Whether its triangles have different vertices or groups at it.
        parted: bool = false,

        fn ofSide(place: []const u32, a: u32, b: u32, group: u32) Edge {
            const low = place[a] < place[b];
            return .{
                .key = if (low) .{ place[a], place[b] } else .{ place[b], place[a] },
                .ends = if (low) .{ a, b } else .{ b, a },
                .group = group,
            };
        }
    };

    /// Each vertex's place: the first vertex given as near as `weld` to
    /// it, along each axis - a seam's two sides, though their positions
    /// were worked out apart and came out a hair different.
    fn placesOf(arena: Allocator, positions: []const [3]f32, weld: f64) Allocator.Error![]u32 {
        const place = try arena.alloc(u32, positions.len);
        // The places found so far, by the box of `weld` a side they are in;
        // each box's a list through `next`.
        var boxes: std.AutoHashMapUnmanaged([3]i64, u32) = .empty;
        try boxes.ensureTotalCapacity(arena, @intCast(positions.len));
        const next = try arena.alloc(u32, positions.len);
        const none = std.math.maxInt(u32);
        for (positions, place, 0..) |p, *at, v| {
            at.* = @intCast(v);
            const box = boxOf(p, weld) orelse continue;
            near: for (0..27) |n| {
                const by: [3]i64 = .{ @as(i64, @intCast(n % 3)) - 1, @as(i64, @intCast(n / 3 % 3)) - 1, @as(i64, @intCast(n / 9)) - 1 };
                var known = boxes.get(.{ box[0] + by[0], box[1] + by[1], box[2] + by[2] }) orelse continue;
                while (known != none) : (known = next[known]) {
                    const q = positions[known];
                    if (@abs(@as(f64, q[0] - p[0])) <= weld and @abs(@as(f64, q[1] - p[1])) <= weld and @abs(@as(f64, q[2] - p[2])) <= weld) {
                        at.* = known;
                        break :near;
                    }
                }
            }
            if (at.* != v) continue;
            const got = boxes.getOrPutAssumeCapacity(box);
            next[v] = if (got.found_existing) got.value_ptr.* else none;
            got.value_ptr.* = @intCast(v);
        }
        return place;
    }

    fn boxOf(p: [3]f32, weld: f64) ?[3]i64 {
        var box: [3]i64 = undefined;
        for (&box, p) |*b, x| {
            // Nothing to weld by: only the same position is one place.
            if (!(weld > 0)) {
                b.* = @as(u32, @bitCast(x));
                continue;
            }
            const at = @floor(@as(f64, x) / weld);
            if (!(@abs(at) < 1e15)) return null;
            b.* = @intFromFloat(at);
        }
        return box;
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

        // How each place may move: anywhere inside a sheet, along a seam
        // or an open edge, or not at all.
        const class = try arena.alloc(Class, places);
        for (class, 0..) |*is, p| {
            is.* = if (self.place[p] == p) self.classify(@intCast(p), fan(first, around, @intCast(p))) else .{};
        }

        // Every edge its first end may move along, with its cost.
        var candidates: std.ArrayList(Collapse) = .empty;
        try candidates.ensureTotalCapacity(arena, self.alive * 6);
        for (self.corners, self.dead) |c, dead| {
            if (dead) continue;
            for (0..3) |k| {
                const a = self.place[c[k]];
                const b = self.place[c[(k + 1) % 3]];
                inline for (.{ .{ a, b }, .{ b, a } }) |pair| {
                    if (class[pair[0]].allows(pair[1])) {
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
        // The vertex at the new place each moved vertex becomes: the one on
        // its side of any seam, found before any corner moves.
        const onto_vertex = try arena.alloc(u32, places);
        var collapsed: usize = 0;
        var worst: f64 = 0;
        var removed: usize = 0;
        const wanted = if (self.alive * 3 > target_indices) (self.alive * 3 - target_indices) / 3 else 0;
        for (candidates.items) |c| {
            if (removed >= wanted) break;
            if (touched[c.from] or touched[c.to]) continue;
            const from_fan = fan(first, around, c.from);
            // An open edge has one triangle on it, an edge in a sheet two.
            const on_edge: usize = if (class[c.from].kind == .border) 1 else 2;
            if (!self.linked(c.from, c.to, from_fan, fan(first, around, c.to), on_edge)) continue;
            if (self.flips(c.from, c.to, from_fan)) continue;
            if (!self.mapSides(c.from, c.to, from_fan, onto_vertex)) continue;
            // Taken: it and every place round it stay as they are this round.
            touched[c.from] = true;
            touched[c.to] = true;
            for (from_fan) |t| for (self.corners[t]) |v| {
                touched[self.place[v]] = true;
            };
            onto[c.from] = c.to;
            collapsed += 1;
            worst = @max(worst, c.cost);
            removed += on_edge;
        }
        if (collapsed == 0) return .{ .collapsed = 0, .worst = 0 };

        // The corners of the places moved, onto their new places' vertices:
        // the one a triangle on both shares - the same side of any seam.
        for (self.corners, self.dead) |*c, *dead| {
            if (dead.*) continue;
            for (c) |*v| {
                const from = self.place[v.*];
                if (onto[from] == from) continue;
                v.* = onto_vertex[v.*];
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

    /// How the place `p` may move. Inside a sheet - every edge round it has
    /// two triangles - with one vertex, anywhere. On a seam - two sides,
    /// each with its vertex or group, parted along two edges - only along
    /// the seam; on an open edge - two edges with one triangle - only along
    /// it. Where more meet, or a seam ends, not at all.
    fn classify(self: *const Work, p: u32, fan: []const u32) Class {
        if (fan.len < 2) return .{};
        var sides: [2]Side = undefined;
        var side_count: usize = 0;
        // Each neighbour round it, with what the triangles on the edge
        // between them have at each end.
        const Neighbour = struct { place: u32, count: u8, mine: [2]Side, theirs: [2]Side };
        var neighbours: [64]Neighbour = undefined;
        var n: usize = 0;
        for (fan) |t| {
            const c = self.corners[t];
            const mine: Side = .{ .vertex = self.vertexOf(c, p).?, .group = self.group[t] };
            if (Side.indexOf(sides[0..side_count], mine) == null) {
                if (side_count == sides.len) return .{};
                sides[side_count] = mine;
                side_count += 1;
            }
            for (c) |v| {
                const q = self.place[v];
                if (q == p) continue;
                const theirs: Side = .{ .vertex = v, .group = self.group[t] };
                for (neighbours[0..n]) |*known| {
                    if (known.place != q) continue;
                    // A third triangle on one edge: not a sheet.
                    if (known.count == 2) return .{};
                    known.count = 2;
                    known.mine[1] = mine;
                    known.theirs[1] = theirs;
                    break;
                } else {
                    if (n == neighbours.len) return .{};
                    neighbours[n] = .{ .place = q, .count = 1, .mine = .{ mine, mine }, .theirs = .{ theirs, theirs } };
                    n += 1;
                }
            }
        }
        var open: [2]u32 = undefined;
        var open_count: usize = 0;
        var seam: [2]u32 = undefined;
        var seam_count: usize = 0;
        for (neighbours[0..n]) |known| {
            if (known.count == 1) {
                if (open_count == open.len) return .{};
                open[open_count] = known.place;
                open_count += 1;
                continue;
            }
            const parted_here = !std.meta.eql(known.mine[0], known.mine[1]);
            const parted_there = !std.meta.eql(known.theirs[0], known.theirs[1]);
            // A seam that ends here, or at the neighbour.
            if (parted_here != parted_there) return .{};
            if (!parted_here) continue;
            if (seam_count == seam.len) return .{};
            seam[seam_count] = known.place;
            seam_count += 1;
        }
        if (side_count == 1 and open_count == 0 and seam_count == 0) return .{ .kind = .inner };
        if (side_count == 2 and open_count == 0 and seam_count == 2) return .{ .kind = .seam, .along = seam };
        if (side_count == 1 and open_count == 2 and seam_count == 0) return .{ .kind = .border, .along = open };
        return .{};
    }

    /// Whether moving `from` onto `to` keeps the surface a sheet: they have
    /// exactly the neighbours in common that the triangles on their edge
    /// make, `on_edge` of them.
    fn linked(self: *const Work, from: u32, to: u32, from_fan: []const u32, to_fan: []const u32, on_edge: usize) bool {
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
        return shared == on_edge;
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

    /// Each side of `from` onto the vertex at `to` on that side - the one a
    /// triangle with both has - written to `onto_vertex`. False when a side
    /// has none there, or two, or where two sides had one vertex they would
    /// have two, or one where they had two: a seam joined or begun.
    fn mapSides(self: *const Work, from: u32, to: u32, from_fan: []const u32, onto_vertex: []u32) bool {
        var sides: [2]Side = undefined;
        var targets: [2]?u32 = .{ null, null };
        var n: usize = 0;
        for (from_fan) |t| {
            const c = self.corners[t];
            const mine: Side = .{ .vertex = self.vertexOf(c, from).?, .group = self.group[t] };
            const i = Side.indexOf(sides[0..n], mine) orelse new: {
                if (n == sides.len) return false;
                sides[n] = mine;
                n += 1;
                break :new n - 1;
            };
            const theirs = self.vertexOf(c, to) orelse continue;
            if (targets[i]) |known| {
                if (known != theirs) return false;
            } else targets[i] = theirs;
        }
        for (targets[0..n]) |target| if (target == null) return false;
        if (n == 2 and (sides[0].vertex == sides[1].vertex) != (targets[0].? == targets[1].?)) return false;
        for (sides[0..n], targets[0..n]) |side, target| onto_vertex[side.vertex] = target.?;
        return true;
    }

    /// The corner of `c` at the place `p`.
    fn vertexOf(self: *const Work, c: [3]u32, p: u32) ?u32 {
        for (c) |v| if (self.place[v] == p) return v;
        return null;
    }
};

/// One side of a place: its vertex there, in its group.
const Side = struct {
    vertex: u32,
    group: u32,

    fn indexOf(sides: []const Side, side: Side) ?usize {
        for (sides, 0..) |known, i| if (std.meta.eql(known, side)) return i;
        return null;
    }
};

/// How a place may move.
const Class = struct {
    kind: Kind = .locked,
    /// For a seam or an open edge: the places next to it along it.
    along: [2]u32 = .{ 0, 0 },

    const Kind = enum { inner, seam, border, locked };

    /// Whether it may move onto the neighbour `to`.
    fn allows(self: Class, to: u32) bool {
        return switch (self.kind) {
            .inner => true,
            .seam, .border => self.along[0] == to or self.along[1] == to,
            .locked => false,
        };
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

fn cross(u: [3]f64, v: [3]f64) [3]f64 {
    return .{ u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0] };
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
    defer fewer.deinit(gpa);
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

/// The area of `indices`' triangles over `positions`.
fn areaOf(indices: []const u32, positions: []const [3]f32) f64 {
    var sum: f64 = 0;
    var t: usize = 0;
    while (t + 2 < indices.len) : (t += 3) {
        var p: [3][3]f64 = undefined;
        for (0..3) |k| {
            const at = positions[indices[t + k]];
            p[k] = .{ at[0], at[1], at[2] };
        }
        const n = normalOf(p[0], p[1], p[2]);
        sum += @sqrt(dot(n, n)) / 2;
    }
    return sum;
}

/// A flat sheet of `wide` by `deep` cells of one, its vertices `base` on.
fn sheet(gpa: Allocator, positions: *std.ArrayList([3]f32), indices: *std.ArrayList(u32), wide: u32, deep: u32, x: f32) !void {
    const base: u32 = @intCast(positions.items.len);
    const row = wide + 1;
    for (0..deep + 1) |j| for (0..row) |i| {
        try positions.append(gpa, .{ x + @as(f32, @floatFromInt(i)), 0, @floatFromInt(j) });
    };
    for (0..deep) |j| for (0..wide) |i| {
        const a: u32 = base + @as(u32, @intCast(j * row + i));
        try indices.appendSlice(gpa, &.{ a, a + row, a + row + 1, a, a + row + 1, a + 1 });
    };
}

test "the error allowed stops it before the target, and a flat sheet's edge shortens along itself, its corners kept" {
    const gpa = testing.allocator;
    // A flat square of 16 by 16 cells: its inside can go, and its edge
    // along itself; its corners cannot.
    var positions: std.ArrayList([3]f32) = .empty;
    defer positions.deinit(gpa);
    var indices: std.ArrayList(u32) = .empty;
    defer indices.deinit(gpa);
    try sheet(gpa, &positions, &indices, 16, 16, 0);
    const flat = try simplify(gpa, indices.items, positions.items, .{ .target_index_count = 6, .target_error = 0.01 });
    defer flat.deinit(gpa);
    try testing.expectEqual(@as(f32, 0), flat.error_share);
    try testing.expect(flat.indices.len / 3 <= 8);
    // The same square: its area, and its four corners.
    try testing.expectApproxEqAbs(@as(f64, 256), areaOf(flat.indices, positions.items), 1e-6);
    for ([_]u32{ 0, 16, 16 * 17, 17 * 17 - 1 }) |corner| {
        try testing.expect(std.mem.indexOfScalar(u32, flat.indices, corner) != null);
    }

    // A ball with no error allowed keeps nearly all it had.
    const made = try ball(gpa, 32, 16);
    defer gpa.free(made.positions);
    defer gpa.free(made.indices);
    const kept = try simplify(gpa, made.indices, made.positions, .{ .target_index_count = 3, .target_error = 0.0001 });
    defer kept.deinit(gpa);
    try testing.expect(kept.indices.len * 10 > made.indices.len * 9);
}

test "a seam - one place, two vertices - shortens along itself, and each side keeps its own vertices" {
    const gpa = testing.allocator;
    // Two flat squares of 8 by 8 cells side by side, each with its own
    // vertices along the line they share.
    var positions: std.ArrayList([3]f32) = .empty;
    defer positions.deinit(gpa);
    var indices: std.ArrayList(u32) = .empty;
    defer indices.deinit(gpa);
    try sheet(gpa, &positions, &indices, 8, 8, 0);
    try sheet(gpa, &positions, &indices, 8, 8, 8);
    const half_vertices = 9 * 9;
    const fewer = try simplify(gpa, indices.items, positions.items, .{ .target_index_count = 12, .target_error = 0.01 });
    defer fewer.deinit(gpa);
    try testing.expect(fewer.indices.len / 3 <= 8);
    // Every triangle uses only its own half's vertices, and each half is
    // still its square.
    var halves: [2]std.ArrayList(u32) = .{ .empty, .empty };
    defer for (&halves) |*half| half.deinit(gpa);
    var t: usize = 0;
    while (t < fewer.indices.len) : (t += 3) {
        const half = fewer.indices[t] / half_vertices;
        for (fewer.indices[t..][0..3]) |v| try testing.expectEqual(half, v / half_vertices);
        try halves[half].appendSlice(gpa, fewer.indices[t..][0..3]);
    }
    for (halves) |half| try testing.expectApproxEqAbs(@as(f64, 64), areaOf(half.items, positions.items), 1e-6);
}

test "groups made fewer together stay apart, and meet along the same line with no gap" {
    const gpa = testing.allocator;
    // One sheet of 16 by 8 cells, its vertices shared, its left half one
    // group and its right half another.
    var positions: std.ArrayList([3]f32) = .empty;
    defer positions.deinit(gpa);
    var all: std.ArrayList(u32) = .empty;
    defer all.deinit(gpa);
    try sheet(gpa, &positions, &all, 16, 8, 0);
    var indices: std.ArrayList(u32) = .empty;
    defer indices.deinit(gpa);
    for (0..2) |half| {
        var t: usize = 0;
        while (t < all.items.len) : (t += 3) {
            const x = positions.items[all.items[t]][0] + positions.items[all.items[t + 1]][0] + positions.items[all.items[t + 2]][0];
            if ((x < 24) == (half == 0)) try indices.appendSlice(gpa, all.items[t..][0..3]);
        }
    }
    const ends = [_]u32{ @intCast(indices.items.len / 2), @intCast(indices.items.len) };
    const fewer = try simplify(gpa, indices.items, positions.items, .{ .target_index_count = 12, .target_error = 0.01, .group_ends = &ends });
    defer fewer.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), fewer.group_ends.len);
    try testing.expectEqual(fewer.indices.len, fewer.group_ends[1]);
    try testing.expect(fewer.indices.len / 3 <= 8);
    const left = fewer.indices[0..fewer.group_ends[0]];
    const right = fewer.indices[fewer.group_ends[0]..];
    try testing.expectApproxEqAbs(@as(f64, 64), areaOf(left, positions.items), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 64), areaOf(right, positions.items), 1e-6);
    for (left) |v| try testing.expect(positions.items[v][0] <= 8);
    for (right) |v| try testing.expect(positions.items[v][0] >= 8);
    // The corners on the line between them are the same on both sides.
    for (left) |v| if (positions.items[v][0] == 8) try testing.expect(std.mem.indexOfScalar(u32, right, v) != null);
    for (right) |v| if (positions.items[v][0] == 8) try testing.expect(std.mem.indexOfScalar(u32, left, v) != null);
}

test "a ball with a seam down one side is made as few as one without, and no triangle crosses the seam" {
    const gpa = testing.allocator;
    // A ball whose picture is wrapped round it once: the column where the
    // picture's left and right edges meet has two vertices at each place,
    // one each side - worked out apart, at a hair from each other.
    const slices = 64;
    const stacks = 32;
    const row = slices + 1;
    var positions: std.ArrayList([3]f32) = .empty;
    defer positions.deinit(gpa);
    var across: std.ArrayList(f32) = .empty;
    defer across.deinit(gpa);
    var indices: std.ArrayList(u32) = .empty;
    defer indices.deinit(gpa);
    try positions.append(gpa, .{ 0, 1, 0 });
    try across.append(gpa, std.math.nan(f32));
    for (1..stacks) |j| {
        const phi = @as(f32, @floatFromInt(j)) / stacks * std.math.pi;
        for (0..row) |i| {
            const u = @as(f32, @floatFromInt(i)) / slices;
            const theta = u * std.math.tau;
            try positions.append(gpa, .{ @cos(theta) * @sin(phi), @cos(phi), -@sin(theta) * @sin(phi) });
            try across.append(gpa, u);
        }
    }
    try positions.append(gpa, .{ 0, -1, 0 });
    try across.append(gpa, std.math.nan(f32));
    const bottom: u32 = @intCast(positions.items.len - 1);
    const at = struct {
        fn of(j: usize, i: usize) u32 {
            return @intCast(1 + (j - 1) * row + i);
        }
    }.of;
    for (0..slices) |i| {
        try indices.appendSlice(gpa, &.{ 0, at(1, i), at(1, i + 1) });
        try indices.appendSlice(gpa, &.{ bottom, at(stacks - 1, i + 1), at(stacks - 1, i) });
    }
    for (1..stacks - 1) |j| for (0..slices) |i| {
        try indices.appendSlice(gpa, &.{ at(j, i), at(j + 1, i), at(j + 1, i + 1), at(j, i), at(j + 1, i + 1), at(j, i + 1) });
    };
    const before = indices.items.len / 3;
    const fewer = try simplify(gpa, indices.items, positions.items, .{ .target_index_count = indices.items.len / 4, .target_error = 0.05 });
    defer fewer.deinit(gpa);
    const after = fewer.indices.len / 3;
    try testing.expect(after <= before / 4 + before / 20);
    try testing.expect(fewer.error_share < 0.05);
    // Fewer than a seam held still would leave: its 31 places and the
    // poles, 33 corners, need 62 triangles closed round them.
    const fewest = try simplify(gpa, indices.items, positions.items, .{ .target_index_count = indices.items.len / 128, .target_error = 0.2 });
    defer fewest.deinit(gpa);
    try testing.expect(fewest.indices.len / 3 < 40);
    // Closed by places still.
    const by_place = try gpa.alloc(u32, fewer.indices.len);
    defer gpa.free(by_place);
    for (fewer.indices, by_place) |v, *p| {
        const column = if (v == 0 or v == bottom) 0 else (v - 1) % row;
        p.* = if (column == slices) v - slices else v;
    }
    try testing.expect(try closedOneWay(gpa, by_place));
    // No triangle's picture runs the whole way round: each side of the
    // seam kept its own vertices.
    var t: usize = 0;
    while (t < fewer.indices.len) : (t += 3) {
        var low: f32 = 1;
        var high: f32 = 0;
        for (fewer.indices[t..][0..3]) |v| {
            const u = across.items[v];
            if (std.math.isNan(u)) continue;
            low = @min(low, u);
            high = @max(high, u);
        }
        try testing.expect(high - low < 0.5);
    }
}
