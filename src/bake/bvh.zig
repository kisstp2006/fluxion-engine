// SPDX-License-Identifier: BSD-3-Clause

//! A bounding volume hierarchy over triangles, and rays traced through it:
//! the nearest triangle a ray meets, and whether anything stands between a
//! point and a way out of it. Built by the surface area of what each split
//! makes, binned; a leaf holds a few triangles.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const Vec3 = @Vector(3, f32);

pub inline fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

pub inline fn length(a: Vec3) f32 {
    return @sqrt(dot(a, a));
}

pub inline fn normalize(a: Vec3) Vec3 {
    const l = length(a);
    return if (l > 0) a / @as(Vec3, @splat(l)) else a;
}

pub inline fn splat(x: f32) Vec3 {
    return @splat(x);
}

pub inline fn vec(a: [3]f32) Vec3 {
    return .{ a[0], a[1], a[2] };
}

/// One of a vector's numbers, by a place known only as it runs.
pub inline fn axisOf(a: Vec3, i: usize) f32 {
    const numbers: [3]f32 = a;
    return numbers[i];
}

/// A triangle given: its three corners.
pub const Triangle = [3]Vec3;

/// Where a ray met a triangle: how far along it, which triangle - by its
/// place in what was given - where on it, as the second and third corners'
/// shares, and whether it met the triangle's back: the side its corners go
/// clockwise round.
pub const Hit = struct {
    t: f32,
    triangle: u32,
    u: f32,
    v: f32,
    back: bool,
};

/// Whatever is passed as a `filter` has `fn keeps(self, triangle: u32, u: f32, v: f32) bool`:
/// whether a ray stops where it meets that triangle there - false for a
/// hole cut in its picture. `all` keeps every one.
pub const all = struct {
    pub fn keeps(_: @This(), _: u32, _: f32, _: f32) bool {
        return true;
    }
}{};

const leaf_most = 4;
const bins = 16;

const Node = struct {
    min: Vec3,
    max: Vec3,
    /// A leaf's first triangle, or an inner node's first child: the second
    /// is after it.
    first: u32,
    /// How many triangles a leaf holds; nought for an inner node.
    count: u32,
};

/// A triangle as a ray meets it: its first corner and its two edges from it.
const Held = struct {
    a: Vec3,
    e1: Vec3,
    e2: Vec3,
};

pub const Bvh = struct {
    nodes: []Node,
    held: []Held,
    /// Each held triangle's place in what was given.
    ids: []u32,

    pub fn build(gpa: Allocator, triangles: []const Triangle) Allocator.Error!Bvh {
        const n = triangles.len;
        const ids = try gpa.alloc(u32, n);
        errdefer gpa.free(ids);
        for (ids, 0..) |*i, at| i.* = @intCast(at);
        const middles = try gpa.alloc(Vec3, n);
        defer gpa.free(middles);
        const lows = try gpa.alloc(Vec3, n);
        defer gpa.free(lows);
        const highs = try gpa.alloc(Vec3, n);
        defer gpa.free(highs);
        for (triangles, middles, lows, highs) |t, *m, *lo, *hi| {
            lo.* = @min(t[0], @min(t[1], t[2]));
            hi.* = @max(t[0], @max(t[1], t[2]));
            m.* = (lo.* + hi.*) * splat(0.5);
        }

        var nodes: std.ArrayList(Node) = .empty;
        errdefer nodes.deinit(gpa);
        try nodes.append(gpa, .{ .min = splat(0), .max = splat(0), .first = 0, .count = @intCast(n) });
        var work: std.ArrayList(u32) = .empty;
        defer work.deinit(gpa);
        if (n > 0) try work.append(gpa, 0);
        while (work.pop()) |at| {
            const first = nodes.items[at].first;
            const count = nodes.items[at].count;
            const mine = ids[first..][0..count];
            var lo = splat(std.math.floatMax(f32));
            var hi = splat(-std.math.floatMax(f32));
            var mid_lo = lo;
            var mid_hi = hi;
            for (mine) |i| {
                lo = @min(lo, lows[i]);
                hi = @max(hi, highs[i]);
                mid_lo = @min(mid_lo, middles[i]);
                mid_hi = @max(mid_hi, middles[i]);
            }
            nodes.items[at].min = lo;
            nodes.items[at].max = hi;
            if (count <= leaf_most) continue;

            // The way the middles spread most, cut where the two sides'
            // surfaces times their triangles are least.
            const spread = mid_hi - mid_lo;
            const axis: usize = if (spread[0] >= spread[1] and spread[0] >= spread[2]) 0 else if (spread[1] >= spread[2]) 1 else 2;
            const reach = axisOf(spread, axis);
            const start = axisOf(mid_lo, axis);
            var split: usize = count / 2;
            if (reach > 0) {
                var bin_count: [bins]u32 = @splat(0);
                var bin_lo: [bins]Vec3 = @splat(splat(std.math.floatMax(f32)));
                var bin_hi: [bins]Vec3 = @splat(splat(-std.math.floatMax(f32)));
                const scale = @as(f32, bins) / reach;
                for (mine) |i| {
                    const b = binOf(axisOf(middles[i], axis), start, scale);
                    bin_count[b] += 1;
                    bin_lo[b] = @min(bin_lo[b], lows[i]);
                    bin_hi[b] = @max(bin_hi[b], highs[i]);
                }
                // The cost of each cut, after bin `c`.
                var right_cost: [bins]f32 = undefined;
                var acc_lo = splat(std.math.floatMax(f32));
                var acc_hi = splat(-std.math.floatMax(f32));
                var acc_count: u32 = 0;
                var b: usize = bins - 1;
                while (b > 0) : (b -= 1) {
                    acc_count += bin_count[b];
                    if (bin_count[b] > 0) {
                        acc_lo = @min(acc_lo, bin_lo[b]);
                        acc_hi = @max(acc_hi, bin_hi[b]);
                    }
                    right_cost[b - 1] = if (acc_count > 0) area(acc_lo, acc_hi) * @as(f32, @floatFromInt(acc_count)) else 0;
                }
                var best_cost: f32 = std.math.floatMax(f32);
                var best_cut: ?usize = null;
                acc_lo = splat(std.math.floatMax(f32));
                acc_hi = splat(-std.math.floatMax(f32));
                acc_count = 0;
                for (0..bins - 1) |c| {
                    acc_count += bin_count[c];
                    if (bin_count[c] > 0) {
                        acc_lo = @min(acc_lo, bin_lo[c]);
                        acc_hi = @max(acc_hi, bin_hi[c]);
                    }
                    if (acc_count == 0 or acc_count == count) continue;
                    const cost = area(acc_lo, acc_hi) * @as(f32, @floatFromInt(acc_count)) + right_cost[c];
                    if (cost < best_cost) {
                        best_cost = cost;
                        best_cut = c;
                    }
                }
                if (best_cut) |c| {
                    // Those in the bins up to `c` first.
                    var left: usize = 0;
                    for (0..mine.len) |k| {
                        if (binOf(axisOf(middles[mine[k]], axis), start, scale) <= c) {
                            std.mem.swap(u32, &mine[k], &mine[left]);
                            left += 1;
                        }
                    }
                    split = left;
                }
            }
            if (split == 0 or split == count) {
                // All in one place: halved by their order along the way.
                const Along = struct {
                    middles: []const Vec3,
                    axis: usize,
                    fn lessThan(self: @This(), a: u32, b: u32) bool {
                        return axisOf(self.middles[a], self.axis) < axisOf(self.middles[b], self.axis);
                    }
                };
                std.mem.sort(u32, mine, Along{ .middles = middles, .axis = axis }, Along.lessThan);
                split = count / 2;
            }
            const child: u32 = @intCast(nodes.items.len);
            try nodes.append(gpa, .{ .min = splat(0), .max = splat(0), .first = first, .count = @intCast(split) });
            try nodes.append(gpa, .{ .min = splat(0), .max = splat(0), .first = first + @as(u32, @intCast(split)), .count = count - @as(u32, @intCast(split)) });
            nodes.items[at].first = child;
            nodes.items[at].count = 0;
            try work.append(gpa, child);
            try work.append(gpa, child + 1);
        }

        const held = try gpa.alloc(Held, n);
        errdefer gpa.free(held);
        for (held, ids) |*h, i| {
            const t = triangles[i];
            h.* = .{ .a = t[0], .e1 = t[1] - t[0], .e2 = t[2] - t[0] };
        }
        return .{ .nodes = try nodes.toOwnedSlice(gpa), .held = held, .ids = ids };
    }

    pub fn deinit(self: *Bvh, gpa: Allocator) void {
        gpa.free(self.nodes);
        gpa.free(self.held);
        gpa.free(self.ids);
        self.* = undefined;
    }

    /// The nearest triangle `filter` keeps that the ray from `origin` along
    /// `way` meets before `reach`.
    pub fn nearest(self: *const Bvh, origin: Vec3, way: Vec3, reach: f32, filter: anytype) ?Hit {
        if (self.held.len == 0) return null;
        const inverse = inverseOf(way);
        var best: ?Hit = null;
        var limit = reach;
        var stack: [64]u32 = undefined;
        var top: usize = 1;
        stack[0] = 0;
        while (top > 0) {
            top -= 1;
            const node = self.nodes[stack[top]];
            if (boxDistance(node.min, node.max, origin, inverse, limit) == null) continue;
            if (node.count > 0) {
                for (node.first..node.first + node.count) |k| {
                    const hit = meet(self.held[k], origin, way, limit) orelse continue;
                    const id = self.ids[k];
                    if (!filter.keeps(id, hit[1], hit[2])) continue;
                    limit = hit[0];
                    best = .{ .t = hit[0], .triangle = id, .u = hit[1], .v = hit[2], .back = hit[3] };
                }
                continue;
            }
            // The nearer child looked at first.
            const near_d = boxDistance(self.nodes[node.first].min, self.nodes[node.first].max, origin, inverse, limit);
            const far_d = boxDistance(self.nodes[node.first + 1].min, self.nodes[node.first + 1].max, origin, inverse, limit);
            if (near_d != null and far_d != null) {
                if (near_d.? <= far_d.?) {
                    stack[top] = node.first + 1;
                    stack[top + 1] = node.first;
                } else {
                    stack[top] = node.first;
                    stack[top + 1] = node.first + 1;
                }
                top += 2;
            } else if (near_d != null) {
                stack[top] = node.first;
                top += 1;
            } else if (far_d != null) {
                stack[top] = node.first + 1;
                top += 1;
            }
        }
        return best;
    }

    /// Whether a triangle `filter` keeps stands on the ray from `origin`
    /// along `way` before `reach`.
    pub fn blocked(self: *const Bvh, origin: Vec3, way: Vec3, reach: f32, filter: anytype) bool {
        if (self.held.len == 0) return false;
        const inverse = inverseOf(way);
        var stack: [64]u32 = undefined;
        var top: usize = 1;
        stack[0] = 0;
        while (top > 0) {
            top -= 1;
            const node = self.nodes[stack[top]];
            if (boxDistance(node.min, node.max, origin, inverse, reach) == null) continue;
            if (node.count > 0) {
                for (node.first..node.first + node.count) |k| {
                    const hit = meet(self.held[k], origin, way, reach) orelse continue;
                    if (filter.keeps(self.ids[k], hit[1], hit[2])) return true;
                }
                continue;
            }
            stack[top] = node.first;
            stack[top + 1] = node.first + 1;
            top += 2;
        }
        return false;
    }
};

fn binOf(x: f32, lo: f32, scale: f32) usize {
    const b: i64 = @intFromFloat((x - lo) * scale);
    return @intCast(std.math.clamp(b, 0, bins - 1));
}

fn area(lo: Vec3, hi: Vec3) f32 {
    const d = @max(hi - lo, splat(0));
    return d[0] * d[1] + d[1] * d[2] + d[2] * d[0];
}

fn inverseOf(way: Vec3) Vec3 {
    var out: Vec3 = undefined;
    inline for (0..3) |i| out[i] = if (way[i] != 0) 1 / way[i] else std.math.floatMax(f32);
    return out;
}

/// How far along the ray it enters the box, if it does before `limit`.
inline fn boxDistance(lo: Vec3, hi: Vec3, origin: Vec3, inverse: Vec3, limit: f32) ?f32 {
    const t0 = (lo - origin) * inverse;
    const t1 = (hi - origin) * inverse;
    const near = @reduce(.Max, @min(t0, t1));
    const far = @reduce(.Min, @max(t0, t1));
    if (far < @max(near, 0) or near > limit) return null;
    return near;
}

/// Where the ray meets the triangle, if it does between a little way out
/// and `limit`: how far, the second and third corners' shares, and whether
/// on its back.
inline fn meet(h: Held, origin: Vec3, way: Vec3, limit: f32) ?struct { f32, f32, f32, bool } {
    const p = cross(way, h.e2);
    const det = dot(h.e1, p);
    if (@abs(det) < 1e-20) return null;
    const inv = 1 / det;
    const s = origin - h.a;
    const u = dot(s, p) * inv;
    if (u < 0 or u > 1) return null;
    const q = cross(s, h.e1);
    const v = dot(way, q) * inv;
    if (v < 0 or u + v > 1) return null;
    const t = dot(h.e2, q) * inv;
    if (t <= 1e-6 or t >= limit) return null;
    return .{ t, u, v, det < 0 };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a ray meets the nearest of many triangles, from either side, and a blocked way is found" {
    // A wall of quads, one behind another along z.
    var triangles: std.ArrayList(Triangle) = .empty;
    defer triangles.deinit(testing.allocator);
    for (0..50) |k| {
        const z: f32 = -@as(f32, @floatFromInt(k));
        for (0..10) |x| for (0..10) |y| {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            try triangles.append(testing.allocator, .{ .{ fx, fy, z }, .{ fx + 1, fy, z }, .{ fx + 1, fy + 1, z } });
            try triangles.append(testing.allocator, .{ .{ fx, fy, z }, .{ fx + 1, fy + 1, z }, .{ fx, fy + 1, z } });
        };
    }
    var tree = try Bvh.build(testing.allocator, triangles.items);
    defer tree.deinit(testing.allocator);

    const hit = tree.nearest(.{ 3.3, 4.6, 5 }, .{ 0, 0, -1 }, 1000, all).?;
    try testing.expectApproxEqAbs(@as(f32, 5), hit.t, 1e-4);
    try testing.expect(!hit.back);
    const t = triangles.items[hit.triangle];
    try testing.expect(t[0][2] == 0 and t[0][0] == 3 and t[0][1] == 4);
    // From behind the last wall, its back.
    const behind = tree.nearest(.{ 3.3, 4.6, -60 }, .{ 0, 0, 1 }, 1000, all).?;
    try testing.expectApproxEqAbs(@as(f32, 11), behind.t, 1e-4);
    try testing.expect(behind.back);
    // Past the walls' edge, nothing.
    try testing.expect(tree.nearest(.{ 20, 4, 5 }, .{ 0, 0, -1 }, 1000, all) == null);
    try testing.expect(tree.blocked(.{ 3.3, 4.6, 5 }, .{ 0, 0, -1 }, 6, all));
    try testing.expect(!tree.blocked(.{ 3.3, 4.6, 5 }, .{ 0, 0, -1 }, 4.9, all));

    // A filter that keeps none: a hole everywhere.
    const none = struct {
        pub fn keeps(_: @This(), _: u32, _: f32, _: f32) bool {
            return false;
        }
    }{};
    try testing.expect(tree.nearest(.{ 3.3, 4.6, 5 }, .{ 0, 0, -1 }, 1000, none) == null);
}

test "every triangle is found by a ray at its middle, whatever the tree's shape" {
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    var triangles: [500]Triangle = undefined;
    for (&triangles) |*t| {
        const c: Vec3 = .{ random.float(f32) * 100, random.float(f32) * 100, random.float(f32) * 100 };
        t.* = .{ c, c + Vec3{ 0.3, 0, 0 }, c + Vec3{ 0, 0.3, 0 } };
    }
    var tree = try Bvh.build(testing.allocator, &triangles);
    defer tree.deinit(testing.allocator);
    for (triangles, 0..) |t, i| {
        const middle = (t[0] + t[1] + t[2]) / splat(3);
        const hit = tree.nearest(middle + Vec3{ 0, 0, 1e-3 }, .{ 0, 0, -1 }, 2e-3, all) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u32, @intCast(i)), hit.triangle);
    }
}
