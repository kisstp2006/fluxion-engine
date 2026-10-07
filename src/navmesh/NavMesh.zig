// SPDX-License-Identifier: BSD-3-Clause

//! A baked navigation mesh: convex polygons on the floor where an agent's
//! middle may go, each knowing the polygon across each of its edges. It
//! answers where on it a point is nearest, and the way from one point to
//! another: A* from polygon to polygon, then pulled tight through the
//! doorways between them.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const vec = @import("vec.zig");
const Vec3 = vec.Vec3;

const NavMesh = @This();

pub const max_vertices = 6;
pub const none = std.math.maxInt(u32);

pub const Polygon = struct {
    vertices: [max_vertices]u32 = @splat(none),
    /// The polygon across the edge from each corner to the next.
    neighbours: [max_vertices]u32 = @splat(none),
    count: u8 = 0,
    area: u8 = 0,
};

/// What it was baked for.
pub const Agent = struct {
    height: f32 = 0,
    radius: f32 = 0,
    max_climb: f32 = 0,
    max_slope: f32 = 0,
};

vertices: []Vec3,
polygons: []Polygon,
agent: Agent = .{},
/// Each polygon's box, for asking.
boxes: [][2]Vec3,

/// Takes the two slices, made with `gpa`.
pub fn init(gpa: Allocator, vertices: []Vec3, polygons: []Polygon, agent: Agent) Allocator.Error!NavMesh {
    const boxes = try gpa.alloc([2]Vec3, polygons.len);
    for (polygons, boxes) |p, *box| {
        box.* = .{ vertices[p.vertices[0]], vertices[p.vertices[0]] };
        for (p.vertices[1..p.count]) |v| {
            box[0] = @min(box[0], vertices[v]);
            box[1] = @max(box[1], vertices[v]);
        }
    }
    return .{ .vertices = vertices, .polygons = polygons, .agent = agent, .boxes = boxes };
}

pub fn deinit(self: *NavMesh, gpa: Allocator) void {
    gpa.free(self.vertices);
    gpa.free(self.polygons);
    gpa.free(self.boxes);
    self.* = undefined;
}

pub fn corner(self: *const NavMesh, poly: u32, i: usize) Vec3 {
    return self.vertices[self.polygons[poly].vertices[i]];
}

// -------------------------------------------------------------------------
// The file
// -------------------------------------------------------------------------

/// The version is the last two letters.
pub const magic = "FXNAV001";

/// Little-endian: the magic; the agent's four numbers; how many vertices
/// and polygons; each vertex's three floats; each polygon's count, area,
/// corners and neighbours.
pub fn write(self: *const NavMesh, gpa: Allocator) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll(magic) catch return error.OutOfMemory;
    for ([_]f32{ self.agent.height, self.agent.radius, self.agent.max_climb, self.agent.max_slope }) |f| int(w, @bitCast(f));
    int(w, @intCast(self.vertices.len));
    int(w, @intCast(self.polygons.len));
    for (self.vertices) |v| {
        inline for (0..3) |k| int(w, @bitCast(v[k]));
    }
    for (self.polygons) |p| {
        int(w, @as(u32, p.count) | @as(u32, p.area) << 8);
        for (p.vertices) |v| int(w, v);
        for (p.neighbours) |n| int(w, n);
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn int(w: *std.Io.Writer, n: u32) void {
    w.writeInt(u32, n, .little) catch {};
}

pub const ReadError = Allocator.Error || error{BadNavMesh};

pub fn read(gpa: Allocator, bytes: []const u8) ReadError!NavMesh {
    if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadNavMesh;
    var at: usize = magic.len;
    const head = try take(bytes, &at, 6);
    const agent: Agent = .{ .height = @bitCast(head[0]), .radius = @bitCast(head[1]), .max_climb = @bitCast(head[2]), .max_slope = @bitCast(head[3]) };
    const vertex_count = head[4];
    const polygon_count = head[5];
    if (vertex_count > 1 << 24 or polygon_count > 1 << 24) return error.BadNavMesh;
    const vertices = try gpa.alloc(Vec3, vertex_count);
    errdefer gpa.free(vertices);
    for (vertices) |*v| {
        const xyz = try take(bytes, &at, 3);
        v.* = .{ @bitCast(xyz[0]), @bitCast(xyz[1]), @bitCast(xyz[2]) };
    }
    const polygons = try gpa.alloc(Polygon, polygon_count);
    errdefer gpa.free(polygons);
    for (polygons) |*p| {
        const words = try take(bytes, &at, 1 + 2 * max_vertices);
        p.* = .{ .count = @truncate(words[0]), .area = @truncate(words[0] >> 8) };
        if (p.count < 3 or p.count > max_vertices) return error.BadNavMesh;
        for (0..max_vertices) |k| {
            p.vertices[k] = words[1 + k];
            p.neighbours[k] = words[1 + max_vertices + k];
            if (k < p.count and p.vertices[k] >= vertex_count) return error.BadNavMesh;
            if (k < p.count and p.neighbours[k] != none and p.neighbours[k] >= polygon_count) return error.BadNavMesh;
        }
    }
    return init(gpa, vertices, polygons, agent);
}

fn take(bytes: []const u8, at: *usize, comptime n: usize) error{BadNavMesh}![n]u32 {
    if (bytes.len - at.* < n * 4) return error.BadNavMesh;
    var out: [n]u32 = undefined;
    for (&out) |*word| {
        word.* = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
        at.* += 4;
    }
    return out;
}

// -------------------------------------------------------------------------
// Asking
// -------------------------------------------------------------------------

pub const Nearest = struct {
    poly: u32,
    point: Vec3,
};

/// The point of the mesh nearest `p`: of the polygons straight above or
/// below it, the one nearest in height - a polygon's height inside it is
/// only as true as its corners, and one may reach from a floor up a ramp
/// to a platform - and the nearest edge where none is. Null for an empty
/// mesh.
pub fn closestPoint(self: *const NavMesh, p: Vec3) ?Nearest {
    var over: ?Nearest = null;
    var over_d: f32 = std.math.inf(f32);
    for (self.polygons, 0..) |_, i| {
        const box = self.boxes[i];
        if (p[0] < box[0][0] or p[0] > box[1][0] or p[2] < box[0][2] or p[2] > box[1][2]) continue;
        const poly: u32 = @intCast(i);
        const h = self.heightAt(poly, p) orelse continue;
        const d = @abs(h - p[1]);
        if (d < over_d) {
            over_d = d;
            over = .{ .poly = poly, .point = .{ p[0], h, p[2] } };
        }
    }
    if (over) |found| return found;

    var best: ?Nearest = null;
    var best_d: f32 = std.math.inf(f32);
    for (self.polygons, 0..) |_, i| {
        const poly: u32 = @intCast(i);
        // Nothing in this box can be nearer than the box.
        const box = self.boxes[i];
        const outside = @max(box[0] - p, p - box[1]);
        const gap = @max(outside, @as(Vec3, @splat(0)));
        if (vec.dot(gap, gap) >= best_d) continue;
        const q = self.closestOnPolygon(poly, p);
        const d = vec.dot(q - p, q - p);
        if (d < best_d) {
            best_d = d;
            best = .{ .poly = poly, .point = q };
        }
    }
    return best;
}

/// The point of polygon `poly` nearest `p`.
pub fn closestOnPolygon(self: *const NavMesh, poly: u32, p: Vec3) Vec3 {
    if (self.heightAt(poly, p)) |h| return .{ p[0], h, p[2] };
    const count = self.polygons[poly].count;
    var best: Vec3 = self.corner(poly, 0);
    var best_d: f32 = std.math.inf(f32);
    for (0..count) |i| {
        const a = self.corner(poly, i);
        const b = self.corner(poly, (i + 1) % count);
        const q = closestOnSegment(a, b, p);
        const d = vec.dot(q - p, q - p);
        if (d < best_d) {
            best_d = d;
            best = q;
        }
    }
    return best;
}

/// The polygon's height under `p`, if `p` is over it.
pub fn heightAt(self: *const NavMesh, poly: u32, p: Vec3) ?f32 {
    const count = self.polygons[poly].count;
    const a = self.corner(poly, 0);
    for (1..count - 1) |i| {
        const b = self.corner(poly, i);
        const c = self.corner(poly, i + 1);
        if (barycentric(a, b, c, p)) |w| return a[1] * w[0] + b[1] * w[1] + c[1] * w[2];
    }
    return null;
}

/// Where `p` falls in triangle `a b c` on the ground, as weights, if it is in it.
fn barycentric(a: Vec3, b: Vec3, c: Vec3, p: Vec3) ?[3]f32 {
    const v0x = c[0] - a[0];
    const v0z = c[2] - a[2];
    const v1x = b[0] - a[0];
    const v1z = b[2] - a[2];
    const v2x = p[0] - a[0];
    const v2z = p[2] - a[2];
    const denom = v0x * v1z - v0z * v1x;
    if (@abs(denom) < 1e-12) return null;
    const u = (v2x * v1z - v2z * v1x) / denom;
    const v = (v0x * v2z - v0z * v2x) / denom;
    const eps = 1e-4;
    if (u < -eps or v < -eps or u + v > 1 + eps) return null;
    return .{ 1 - u - v, v, u };
}

fn closestOnSegment(a: Vec3, b: Vec3, p: Vec3) Vec3 {
    const ab = b - a;
    const len = vec.dot(ab, ab);
    if (len == 0) return a;
    const t = std.math.clamp(vec.dot(p - a, ab) / len, 0, 1);
    return vec.lerp(a, b, t);
}

pub const Path = struct {
    /// The corners to walk through, the start first and the end last.
    points: std.ArrayList(Vec3) = .empty,
    /// The polygons gone through.
    corridor: std.ArrayList(u32) = .empty,
    /// The end could not be reached: the path goes as near it as it can.
    partial: bool = false,

    pub fn deinit(self: *Path, gpa: Allocator) void {
        self.points.deinit(gpa);
        self.corridor.deinit(gpa);
        self.* = undefined;
    }

    pub fn clear(self: *Path) void {
        self.points.clearRetainingCapacity();
        self.corridor.clearRetainingCapacity();
        self.partial = false;
    }
};

/// The way from `start` to `end`, each first moved to the nearest point of
/// the mesh: through the polygons A* finds, pulled tight. Empty when the
/// mesh is.
pub fn findPath(self: *const NavMesh, gpa: Allocator, start: Vec3, end: Vec3, path: *Path) Allocator.Error!void {
    path.clear();
    const from = self.closestPoint(start) orelse return;
    const to = self.closestPoint(end) orelse return;
    try self.findCorridor(gpa, from, to, path);
    var goal = to.point;
    if (path.partial) goal = self.closestOnPolygon(path.corridor.items[path.corridor.items.len - 1], to.point);
    try self.pullTight(gpa, from.point, goal, path);
}

const Node = struct {
    /// Where it was entered: the middle of the edge crossed.
    pos: Vec3,
    cost: f32,
    total: f32,
    parent: u32,
    open: bool,
    closed: bool,
};

fn findCorridor(self: *const NavMesh, gpa: Allocator, from: Nearest, to: Nearest, path: *Path) Allocator.Error!void {
    var nodes: std.AutoHashMapUnmanaged(u32, Node) = .empty;
    defer nodes.deinit(gpa);
    const Open = struct { poly: u32, total: f32 };
    const order = struct {
        fn less(_: void, a: Open, b: Open) std.math.Order {
            return std.math.order(a.total, b.total);
        }
    };
    var open: std.PriorityQueue(Open, void, order.less) = .initContext({});
    defer open.deinit(gpa);

    const h_scale = 0.999;
    const start_h = vec.length(to.point - from.point) * h_scale;
    try nodes.put(gpa, from.poly, .{ .pos = from.point, .cost = 0, .total = start_h, .parent = none, .open = true, .closed = false });
    try open.push(gpa, .{ .poly = from.poly, .total = start_h });
    var best = from.poly;
    var best_h = start_h;

    while (open.pop()) |top| {
        const node = nodes.getPtr(top.poly).?;
        if (node.closed or top.total > node.total) continue;
        node.open = false;
        node.closed = true;
        if (top.poly == to.poly) {
            best = to.poly;
            break;
        }
        const here = node.*;
        const poly = self.polygons[top.poly];
        for (0..poly.count) |e| {
            const nb = poly.neighbours[e];
            if (nb == none or nb == here.parent) continue;
            const a = self.corner(top.poly, e);
            const b = self.corner(top.poly, (e + 1) % poly.count);
            const pos = vec.lerp(a, b, 0.5);
            var cost = here.cost + vec.length(pos - here.pos);
            var h: f32 = 0;
            if (nb == to.poly) {
                cost += vec.length(to.point - pos);
            } else h = vec.length(to.point - pos) * h_scale;
            const total = cost + h;
            const entry = try nodes.getOrPut(gpa, nb);
            if (entry.found_existing) {
                if (entry.value_ptr.closed and total >= entry.value_ptr.total) continue;
                if (entry.value_ptr.open and total >= entry.value_ptr.total) continue;
            }
            entry.value_ptr.* = .{ .pos = pos, .cost = cost, .total = total, .parent = top.poly, .open = true, .closed = false };
            try open.push(gpa, .{ .poly = nb, .total = total });
            if (h < best_h) {
                best_h = h;
                best = nb;
            }
        }
    }
    path.partial = best != to.poly;
    // Back from the last to the first.
    var at = best;
    while (at != none) : (at = nodes.get(at).?.parent) try path.corridor.append(gpa, at);
    std.mem.reverse(u32, path.corridor.items);
}

/// The edge `from` shares with `to`, as its two ends seen walking from
/// `from` into `to`: left and right.
fn portal(self: *const NavMesh, from: u32, to: u32) ?[2]Vec3 {
    const poly = self.polygons[from];
    for (0..poly.count) |e| {
        if (poly.neighbours[e] != to) continue;
        return .{ self.corner(from, e), self.corner(from, (e + 1) % poly.count) };
    }
    return null;
}

/// Twice the signed area on the ground, as the funnel turns: positive when
/// `c` is to the right of `a`-`b`, walking from `a` to `b`.
fn turn(a: Vec3, b: Vec3, c: Vec3) f32 {
    const abx = b[0] - a[0];
    const abz = b[2] - a[2];
    const acx = c[0] - a[0];
    const acz = c[2] - a[2];
    return acx * abz - abx * acz;
}

fn same(a: Vec3, b: Vec3) bool {
    const d = a - b;
    return vec.dot(d, d) < 1e-6 * 1e-6;
}

/// The corridor pulled tight from `start` to `goal`: a corner wherever the
/// way has to turn round the edge of a doorway.
fn pullTight(self: *const NavMesh, gpa: Allocator, start: Vec3, goal: Vec3, path: *Path) Allocator.Error!void {
    const corridor = path.corridor.items;
    var portals: std.ArrayList([2]Vec3) = .empty;
    defer portals.deinit(gpa);
    for (0..corridor.len -| 1) |i| {
        try portals.append(gpa, self.portal(corridor[i], corridor[i + 1]) orelse .{ goal, goal });
    }
    try portals.append(gpa, .{ goal, goal });

    try path.points.append(gpa, start);
    var apex = start;
    var portal_left = start;
    var portal_right = start;
    var apex_index: usize = 0;
    var left_index: usize = 0;
    var right_index: usize = 0;
    var i: usize = 0;
    while (i < portals.items.len) : (i += 1) {
        const left = portals.items[i][0];
        const right = portals.items[i][1];
        // The right side of the funnel, narrowed.
        if (turn(apex, portal_right, right) <= 0) {
            if (same(apex, portal_right) or turn(apex, portal_left, right) > 0) {
                portal_right = right;
                right_index = i;
            } else {
                // Past the left side: the left side's corner is turned round.
                apex = portal_left;
                apex_index = left_index;
                try appendPoint(gpa, path, apex);
                portal_left = apex;
                portal_right = apex;
                left_index = apex_index;
                right_index = apex_index;
                i = apex_index;
                continue;
            }
        }
        // And the left.
        if (turn(apex, portal_left, left) >= 0) {
            if (same(apex, portal_left) or turn(apex, portal_right, left) < 0) {
                portal_left = left;
                left_index = i;
            } else {
                apex = portal_right;
                apex_index = right_index;
                try appendPoint(gpa, path, apex);
                portal_left = apex;
                portal_right = apex;
                left_index = apex_index;
                right_index = apex_index;
                i = apex_index;
                continue;
            }
        }
    }
    try appendPoint(gpa, path, goal);
}

fn appendPoint(gpa: Allocator, path: *Path, p: Vec3) Allocator.Error!void {
    if (path.points.items.len > 0 and same(path.points.items[path.points.items.len - 1], p)) return;
    try path.points.append(gpa, p);
}

/// Whether every polygon can be reached from the first: a mesh of one
/// piece.
pub fn connectedFrom(self: *const NavMesh, gpa: Allocator, poly: u32) Allocator.Error!usize {
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, self.polygons.len);
    defer seen.deinit(gpa);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, poly);
    seen.set(poly);
    var count: usize = 0;
    while (stack.pop()) |p| {
        count += 1;
        const it = self.polygons[p];
        for (it.neighbours[0..it.count]) |nb| {
            if (nb == none or seen.isSet(nb)) continue;
            seen.set(nb);
            try stack.append(gpa, nb);
        }
    }
    return count;
}

test "a navigation mesh is written and read back the same, and a cut-off one is refused" {
    const gpa = testing.allocator;
    const vertices = try gpa.dupe(Vec3, &.{ .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 0, 0 } });
    const polygons = try gpa.dupe(Polygon, &.{.{ .vertices = .{ 0, 1, 2, 3, none, none }, .count = 4, .area = 63 }});
    var mesh = try NavMesh.init(gpa, vertices, polygons, .{ .height = 1.5, .radius = 0.5 });
    defer mesh.deinit(gpa);
    const bytes = try mesh.write(gpa);
    defer gpa.free(bytes);
    var back = try NavMesh.read(gpa, bytes);
    defer back.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), back.vertices.len);
    try testing.expectEqual(@as(f32, 0.5), back.agent.radius);
    try testing.expectEqual(@as(u8, 4), back.polygons[0].count);
    try testing.expectError(error.BadNavMesh, NavMesh.read(gpa, bytes[0 .. bytes.len - 3]));
    try testing.expectError(error.BadNavMesh, NavMesh.read(gpa, "FXNAV000"));
    // A point over it is straight below; one off it is at the nearest edge.
    const over = mesh.closestPoint(.{ 0.5, 2, 0.25 }).?;
    try testing.expect(@reduce(.And, over.point == Vec3{ 0.5, 0, 0.25 }));
    const off = mesh.closestPoint(.{ 3, 0, 0.5 }).?;
    try testing.expectApproxEqAbs(@as(f32, 1), off.point[0], 1e-6);
}
