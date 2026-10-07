// SPDX-License-Identifier: BSD-3-Clause

//! Each region's outline: walked round its border cell edge by cell edge,
//! then drawn with as few corners as keep it within `max_error` of the
//! cells. A corner is kept wherever the region beside the outline changes,
//! so two regions' outlines meet at the same points - the doorways a path
//! goes through.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Compact = @import("Compact.zig");
const Heightfield = @import("Heightfield.zig");

/// The region beside an outline's edge, in a point's `r`.
pub const region_mask: u32 = 0xffff;
/// Beside the edge is a floor of another kind.
pub const area_border: u32 = 0x20000;

/// A corner of an outline: on the grid of cell corners, `y` in steps; `r`
/// the region beside the edge that starts here.
pub const Point = struct {
    x: i32,
    y: i32,
    z: i32,
    r: u32,
};

pub const Contour = struct {
    points: []Point,
    region: u16,
    area: u8,
};

pub const Set = struct {
    contours: std.ArrayList(Contour) = .empty,

    pub fn deinit(self: *Set, gpa: Allocator) void {
        for (self.contours.items) |c| gpa.free(c.points);
        self.contours.deinit(gpa);
        self.* = undefined;
    }
};

/// Every region's outline. `max_error` is in cells, how far the outline may
/// stray from the cells' edges along a wall; `max_edge` in cells, how long
/// an edge along a wall may be - none when nought.
pub fn build(gpa: Allocator, chf: *const Compact, max_error: f32, max_edge: i32) Allocator.Error!Set {
    const flags = try gpa.alloc(u8, chf.spans.len);
    defer gpa.free(flags);
    // Which edges of each span are on its region's border.
    for (chf.spans, flags, 0..) |s, *f, i| {
        f.* = 0;
        if (s.region == 0) continue;
        var same: u8 = 0;
        for (0..4) |dir| {
            var r: u16 = 0;
            if (s.con[dir] != Compact.none) r = chf.spans[s.con[dir]].region;
            if (r == s.region) same |= @as(u8, 1) << @intCast(dir);
        }
        f.* = same ^ 0xf;
        _ = i;
    }

    var set: Set = .{};
    errdefer set.deinit(gpa);
    var raw: std.ArrayList(Point) = .empty;
    defer raw.deinit(gpa);
    var simple: std.ArrayList(Simple) = .empty;
    defer simple.deinit(gpa);

    for (0..chf.depth) |z| for (0..chf.width) |x| {
        const cell = chf.cellAt(@intCast(x), @intCast(z));
        for (cell.first..cell.first + cell.count) |i| {
            // On no border, or alone on all four sides: nothing to go round.
            if (flags[i] == 0 or flags[i] == 0xf) {
                flags[i] = 0;
                continue;
            }
            const s = chf.spans[i];
            if (s.region == 0) continue;
            raw.clearRetainingCapacity();
            simple.clearRetainingCapacity();
            try walk(gpa, chf, @intCast(x), @intCast(z), @intCast(i), flags, &raw);
            try simplify(gpa, raw.items, &simple, max_error, max_edge);
            removeDegenerate(&simple);
            if (simple.items.len < 3) continue;
            const points = try gpa.alloc(Point, simple.items.len);
            for (simple.items, points) |p, *q| q.* = .{ .x = p.x, .y = p.y, .z = p.z, .r = p.r };
            // An outline wound the other way is a hole, which regions made
            // by rows never have: dropped.
            if (signedArea(points) < 0) {
                gpa.free(points);
                continue;
            }
            set.contours.append(gpa, .{ .points = points, .region = s.region, .area = s.area }) catch |err| {
                gpa.free(points);
                return err;
            };
        }
    };
    return set;
}

/// Twice the area on the ground, positive for an outline and negative for
/// a hole.
pub fn signedArea(points: []const Point) i64 {
    var area: i64 = 0;
    var j = points.len - 1;
    for (points, 0..) |p, i| {
        const q = points[j];
        area += @as(i64, p.x) * q.z - @as(i64, q.x) * p.z;
        j = i;
    }
    return area;
}

/// Round the border from span `i`, keeping the region to the left, a corner
/// at every border edge.
fn walk(gpa: Allocator, chf: *const Compact, start_x: i32, start_z: i32, start: u32, flags: []u8, points: *std.ArrayList(Point)) Allocator.Error!void {
    var x = start_x;
    var z = start_z;
    var i = start;
    var dir: u3 = 0;
    while (flags[i] & (@as(u8, 1) << dir) == 0) dir += 1;
    const start_dir = dir;
    const area = chf.spans[i].area;

    var rounds: usize = 0;
    while (rounds < 1 << 18) : (rounds += 1) {
        if (flags[i] & (@as(u8, 1) << dir) != 0) {
            // A border edge: its corner.
            var px = x;
            const py = cornerHeight(chf, i, dir);
            var pz = z;
            switch (dir) {
                0 => pz += 1,
                1 => {
                    px += 1;
                    pz += 1;
                },
                2 => px += 1,
                else => {},
            }
            var r: u32 = 0;
            const s = chf.spans[i];
            if (s.con[dir] != Compact.none) {
                const a = s.con[dir];
                r = chf.spans[a].region;
                if (area != chf.spans[a].area) r |= area_border;
            }
            try points.append(gpa, .{ .x = px, .y = py, .z = pz, .r = r });
            flags[i] &= ~(@as(u8, 1) << dir);
            dir = (dir + 1) & 3;
        } else {
            const next = chf.spans[i].con[dir];
            if (next == Compact.none) return;
            x += Compact.dx[dir];
            z += Compact.dz[dir];
            i = next;
            dir = (dir + 3) & 3;
        }
        if (i == start and dir == start_dir) break;
    }
}

/// The highest floor round a corner: the outline goes over what it meets.
fn cornerHeight(chf: *const Compact, i: u32, dir: u3) i32 {
    const s = chf.spans[i];
    var h: i32 = s.y;
    const dirp: u3 = (dir + 1) & 3;
    if (s.con[dir] != Compact.none) {
        const a = chf.spans[s.con[dir]];
        h = @max(h, a.y);
        if (a.con[dirp] != Compact.none) h = @max(h, chf.spans[a.con[dirp]].y);
    }
    if (s.con[dirp] != Compact.none) {
        const a = chf.spans[s.con[dirp]];
        h = @max(h, a.y);
        if (a.con[dir] != Compact.none) h = @max(h, chf.spans[a.con[dir]].y);
    }
    return h;
}

/// A point of the simplified outline: its raw point's place, and while
/// simplifying the index of that raw point.
const Simple = struct {
    x: i32,
    y: i32,
    z: i32,
    r: u32,
};

fn simplify(gpa: Allocator, raw: []const Point, out: *std.ArrayList(Simple), max_error: f32, max_edge: i32) Allocator.Error!void {
    const n = raw.len;
    if (n == 0) return;
    var has_portals = false;
    for (raw) |p| {
        if (p.r & region_mask != 0) {
            has_portals = true;
            break;
        }
    }
    if (has_portals) {
        // A corner wherever the region beside changes.
        for (raw, 0..) |p, i| {
            const q = raw[(i + 1) % n];
            const different = (p.r & region_mask) != (q.r & region_mask);
            const borders = (p.r & area_border) != (q.r & area_border);
            if (different or borders) try out.append(gpa, .{ .x = p.x, .y = p.y, .z = p.z, .r = @intCast(i) });
        }
    }
    if (out.items.len == 0) {
        // All wall: start from the lowest-left and the highest-right corners.
        var ll: usize = 0;
        var ur: usize = 0;
        for (raw, 0..) |p, i| {
            const l = raw[ll];
            const u = raw[ur];
            if (p.x < l.x or (p.x == l.x and p.z < l.z)) ll = i;
            if (p.x > u.x or (p.x == u.x and p.z > u.z)) ur = i;
        }
        try out.append(gpa, .{ .x = raw[ll].x, .y = raw[ll].y, .z = raw[ll].z, .r = @intCast(ll) });
        try out.append(gpa, .{ .x = raw[ur].x, .y = raw[ur].y, .z = raw[ur].z, .r = @intCast(ur) });
    }

    // Corners added where the cells stray furthest from an edge, until none
    // strays more than the error.
    var i: usize = 0;
    while (i < out.items.len) {
        const ii = (i + 1) % out.items.len;
        var a = out.items[i];
        var b = out.items[ii];
        const ai: usize = a.r;
        const bi: usize = b.r;
        var max_d: f32 = 0;
        var max_i: ?usize = null;
        var ci: usize = undefined;
        var step: usize = undefined;
        var end: usize = undefined;
        // Walked the same way whichever side the edge is seen from, so
        // both regions' outlines agree.
        if (b.x > a.x or (b.x == a.x and b.z > a.z)) {
            step = 1;
            ci = (ai + step) % n;
            end = bi;
        } else {
            step = n - 1;
            ci = (bi + step) % n;
            end = ai;
            std.mem.swap(Simple, &a, &b);
        }
        // Only along a wall, or a border between kinds of floor.
        if (raw[ci].r & region_mask == 0 or raw[ci].r & area_border != 0) {
            while (ci != end) {
                const d = distanceToSegment(raw[ci].x, raw[ci].z, a.x, a.z, b.x, b.z);
                if (d > max_d) {
                    max_d = d;
                    max_i = ci;
                }
                ci = (ci + step) % n;
            }
        }
        if (max_i != null and max_d > max_error * max_error) {
            const m = raw[max_i.?];
            try out.insert(gpa, i + 1, .{ .x = m.x, .y = m.y, .z = m.z, .r = @intCast(max_i.?) });
        } else i += 1;
    }

    // Long edges along walls split.
    if (max_edge > 0) {
        i = 0;
        while (i < out.items.len) {
            const ii = (i + 1) % out.items.len;
            const a = out.items[i];
            const b = out.items[ii];
            const ai: usize = a.r;
            const bi: usize = b.r;
            var max_i: ?usize = null;
            const ci = (ai + 1) % n;
            if (raw[ci].r & region_mask == 0) {
                const ex = b.x - a.x;
                const ez = b.z - a.z;
                if (ex * ex + ez * ez > max_edge * max_edge) {
                    const span = if (bi < ai) bi + n - ai else bi - ai;
                    if (span > 1) {
                        max_i = if (b.x > a.x or (b.x == a.x and b.z > a.z)) (ai + span / 2) % n else (ai + (span + 1) / 2) % n;
                    }
                }
            }
            if (max_i) |m| {
                const p = raw[m];
                try out.insert(gpa, i + 1, .{ .x = p.x, .y = p.y, .z = p.z, .r = @intCast(m) });
            } else i += 1;
        }
    }

    // Each corner says the region beside the edge that starts at it.
    for (out.items) |*p| {
        const raw_i: usize = p.r;
        p.r = raw[(raw_i + 1) % n].r & (region_mask | area_border);
    }
}

/// The square of the distance from a point to a segment, on the ground.
fn distanceToSegment(x: i32, z: i32, px: i32, pz: i32, qx: i32, qz: i32) f32 {
    const pqx: f32 = @floatFromInt(qx - px);
    const pqz: f32 = @floatFromInt(qz - pz);
    var dx: f32 = @floatFromInt(x - px);
    var dz: f32 = @floatFromInt(z - pz);
    const d = pqx * pqx + pqz * pqz;
    var t = pqx * dx + pqz * dz;
    if (d > 0) t /= d;
    t = std.math.clamp(t, 0, 1);
    dx = @as(f32, @floatFromInt(px)) + t * pqx - @as(f32, @floatFromInt(x));
    dz = @as(f32, @floatFromInt(pz)) + t * pqz - @as(f32, @floatFromInt(z));
    return dx * dx + dz * dz;
}

/// Two corners in the same place on the ground are one.
fn removeDegenerate(points: *std.ArrayList(Simple)) void {
    var i: usize = 0;
    while (i < points.items.len) {
        const ni = (i + 1) % points.items.len;
        const a = points.items[i];
        const b = points.items[ni];
        if (a.x == b.x and a.z == b.z and points.items.len > 1) {
            _ = points.orderedRemove(ni);
            if (ni == 0) i = 0;
        } else i += 1;
    }
}

test "an open square floor is one outline of four corners, all wall, wound as an outline" {
    var hf = try Heightfield.init(testing.allocator, .{ 0, 0, 0 }, .{ 8, 4, 8 }, 1, 0.1);
    defer hf.deinit(testing.allocator);
    for (0..8) |z| for (0..8) |x| {
        try hf.addSpan(testing.allocator, @intCast(x), @intCast(z), 0, 5, Heightfield.walkable_area, 1);
    };
    var chf = try Compact.init(testing.allocator, &hf, 10, 2);
    defer chf.deinit(testing.allocator);
    try chf.buildRegions(testing.allocator, 1);
    var set = try build(testing.allocator, &chf, 1.3, 0);
    defer set.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), set.contours.items.len);
    const outline = set.contours.items[0];
    try testing.expectEqual(@as(usize, 4), outline.points.len);
    try testing.expect(signedArea(outline.points) > 0);
    for (outline.points) |p| {
        try testing.expect(p.x == 0 or p.x == 8);
        try testing.expect(p.z == 0 or p.z == 8);
        try testing.expectEqual(@as(i32, 5), p.y);
        try testing.expectEqual(@as(u32, 0), p.r);
    }
    // Long walls cut every three cells or so.
    var cut = try build(testing.allocator, &chf, 1.3, 3);
    defer cut.deinit(testing.allocator);
    try testing.expect(cut.contours.items[0].points.len > 8);
}
