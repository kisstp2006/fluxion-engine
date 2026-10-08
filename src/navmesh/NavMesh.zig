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
const Map = @import("Map.zig");

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

/// A polygon's heights inside it, sampled on a grid on the ground: what
/// its corners alone cannot say where it reaches from a floor up a ramp to
/// a platform.
pub const Detail = struct {
    /// The grid's low corner and its step, on the ground.
    x: f32 = 0,
    z: f32 = 0,
    step: f32 = 0,
    width: u16 = 0,
    depth: u16 = 0,
    /// Where its heights start in `detail_heights`, row by row; NaN where
    /// no floor was found.
    first: u32 = 0,
};

vertices: []Vec3,
polygons: []Polygon,
agent: Agent = .{},
/// Each polygon's box, for asking.
boxes: [][2]Vec3,
/// One for each polygon, or none: then a polygon's height is its corners'.
details: []Detail = &.{},
detail_heights: []f32 = &.{},

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

/// Give it heights sampled inside its polygons: `details` one for each,
/// made with `gpa` as `heights` are, the mesh's from here.
pub fn setDetail(self: *NavMesh, gpa: Allocator, details: []Detail, heights: []f32) void {
    gpa.free(self.details);
    gpa.free(self.detail_heights);
    self.details = details;
    self.detail_heights = heights;
}

pub fn deinit(self: *NavMesh, gpa: Allocator) void {
    gpa.free(self.vertices);
    gpa.free(self.polygons);
    gpa.free(self.boxes);
    gpa.free(self.details);
    gpa.free(self.detail_heights);
    self.* = undefined;
}

pub fn corner(self: *const NavMesh, poly: u32, i: usize) Vec3 {
    return self.vertices[self.polygons[poly].vertices[i]];
}

// -------------------------------------------------------------------------
// The file
// -------------------------------------------------------------------------

/// The version is the last two letters. A file of the first version has
/// no heights inside its polygons; it is still read.
pub const magic = "FXNAV002";
const magic_first = "FXNAV001";

/// Little-endian: the magic; the agent's four numbers; how many vertices
/// and polygons; each vertex's three floats; each polygon's count, area,
/// corners and neighbours; then how many details - none, or one for each
/// polygon - and heights, each detail's grid corner, step, size and first
/// height, and the heights.
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
    int(w, @intCast(self.details.len));
    int(w, @intCast(self.detail_heights.len));
    for (self.details) |d| {
        for ([_]f32{ d.x, d.z, d.step }) |f| int(w, @bitCast(f));
        int(w, @as(u32, d.width) | @as(u32, d.depth) << 16);
        int(w, d.first);
    }
    for (self.detail_heights) |h| int(w, @bitCast(h));
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn int(w: *std.Io.Writer, n: u32) void {
    w.writeInt(u32, n, .little) catch {};
}

pub const ReadError = Allocator.Error || error{BadNavMesh};

pub fn read(gpa: Allocator, bytes: []const u8) ReadError!NavMesh {
    if (bytes.len < magic.len) return error.BadNavMesh;
    const first_version = std.mem.eql(u8, bytes[0..magic.len], magic_first);
    if (!first_version and !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadNavMesh;
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
    var details: []Detail = &.{};
    var heights: []f32 = &.{};
    errdefer gpa.free(details);
    errdefer gpa.free(heights);
    if (!first_version) {
        const counts = try take(bytes, &at, 2);
        if (counts[0] != 0 and counts[0] != polygon_count) return error.BadNavMesh;
        if (counts[1] > 1 << 26) return error.BadNavMesh;
        details = try gpa.alloc(Detail, counts[0]);
        for (details) |*d| {
            const words = try take(bytes, &at, 5);
            d.* = .{ .x = @bitCast(words[0]), .z = @bitCast(words[1]), .step = @bitCast(words[2]), .width = @truncate(words[3]), .depth = @truncate(words[3] >> 16), .first = words[4] };
            if (@as(u64, d.first) + @as(u64, d.width) * d.depth > counts[1]) return error.BadNavMesh;
        }
        heights = try gpa.alloc(f32, counts[1]);
        for (heights) |*h| h.* = @bitCast((try take(bytes, &at, 1))[0]);
    }
    var mesh = try init(gpa, vertices, polygons, agent);
    mesh.details = details;
    mesh.detail_heights = heights;
    return mesh;
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

pub const Found = struct {
    poly: u32,
    point: Vec3,
    /// Straight above or below `p`, rather than the nearest edge.
    over: bool,
};

/// The point of the mesh nearest `p`: of the polygons straight above or
/// below it, the one nearest in height, and the nearest edge where none
/// is. Null for an empty mesh.
pub fn closestPoint(self: *const NavMesh, p: Vec3) ?Nearest {
    const found = self.closest(p) orelse return null;
    return .{ .poly = found.poly, .point = found.point };
}

/// The same, saying whether it is straight above or below.
pub fn closest(self: *const NavMesh, p: Vec3) ?Found {
    var over: ?Found = null;
    var over_d: f32 = std.math.inf(f32);
    for (self.polygons, 0..) |_, i| {
        const box = self.boxes[i];
        if (p[0] < box[0][0] or p[0] > box[1][0] or p[2] < box[0][2] or p[2] > box[1][2]) continue;
        const poly: u32 = @intCast(i);
        const h = self.heightAt(poly, p) orelse continue;
        const d = @abs(h - p[1]);
        if (d < over_d) {
            over_d = d;
            over = .{ .poly = poly, .point = .{ p[0], h, p[2] }, .over = true };
        }
    }
    if (over) |found| return found;

    var best: ?Found = null;
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
            best = .{ .poly = poly, .point = q, .over = false };
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

/// The polygon's height under `p`, if `p` is over it: from the heights
/// sampled inside it where it has them, else from its corners.
pub fn heightAt(self: *const NavMesh, poly: u32, p: Vec3) ?f32 {
    const planar = self.planarHeight(poly, p) orelse return null;
    if (self.details.len > 0) if (self.sampled(poly, p)) |h| return h;
    return planar;
}

/// The height under `p` of the polygon as its corners make it, if `p` is
/// over it.
pub fn planarHeight(self: *const NavMesh, poly: u32, p: Vec3) ?f32 {
    const count = self.polygons[poly].count;
    const a = self.corner(poly, 0);
    for (1..count - 1) |i| {
        const b = self.corner(poly, i);
        const c = self.corner(poly, i + 1);
        if (barycentric(a, b, c, p)) |w| return a[1] * w[0] + b[1] * w[1] + c[1] * w[2];
    }
    return null;
}

/// The height at `p` from the four samples round it, those that found a
/// floor, weighted by nearness.
fn sampled(self: *const NavMesh, poly: u32, p: Vec3) ?f32 {
    const d = self.details[poly];
    if (d.width == 0 or d.depth == 0 or d.step <= 0) return null;
    const fx = std.math.clamp((p[0] - d.x) / d.step, 0, @as(f32, @floatFromInt(d.width - 1)));
    const fz = std.math.clamp((p[2] - d.z) / d.step, 0, @as(f32, @floatFromInt(d.depth - 1)));
    const ix: u32 = @intFromFloat(@floor(fx));
    const iz: u32 = @intFromFloat(@floor(fz));
    const tx = fx - @as(f32, @floatFromInt(ix));
    const tz = fz - @as(f32, @floatFromInt(iz));
    const heights = self.detail_heights[d.first..][0 .. @as(usize, d.width) * d.depth];
    var sum: f32 = 0;
    var weights: f32 = 0;
    for ([_][3]f32{ .{ 0, 0, (1 - tx) * (1 - tz) }, .{ 1, 0, tx * (1 - tz) }, .{ 0, 1, (1 - tx) * tz }, .{ 1, 1, tx * tz } }) |corner_weight| {
        const x = @min(ix + @as(u32, @intFromFloat(corner_weight[0])), d.width - 1);
        const z = @min(iz + @as(u32, @intFromFloat(corner_weight[1])), d.depth - 1);
        const h = heights[z * d.width + x];
        if (std.math.isNan(h)) continue;
        // A little for each, so a sample right beside a missing one counts.
        const w = corner_weight[2] + 1e-4;
        sum += h * w;
        weights += w;
    }
    if (weights == 0) return null;
    return sum / weights;
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

pub const Path = Map.Path;

/// The way from `start` to `end`, each first moved to the nearest point of
/// the mesh: through the polygons A* finds, pulled tight. Empty when the
/// mesh is. See `Map` for ways across several meshes, links and what
/// stands in the way.
pub fn findPath(self: *const NavMesh, gpa: Allocator, start: Vec3, end: Vec3, path: *Path) Allocator.Error!void {
    const parts = [1]Map.Part{.{ .mesh = self }};
    const map: Map = .single(&parts);
    try map.findPath(gpa, start, end, path, .{});
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
