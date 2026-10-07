// SPDX-License-Identifier: BSD-3-Clause

//! The solid of a world in columns: a grid over the ground, `cell_size` a
//! side, and in each column the spans the triangles fill, `cell_height` a
//! step up. A span says whether its top can be stood on - the triangle that
//! made it lies no steeper than the agent climbs. What is not a span is
//! air.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const vec = @import("vec.zig");
const Vec3 = vec.Vec3;

const Heightfield = @This();

/// No span: the end of a column.
pub const none = std.math.maxInt(u32);
/// A span's top no one stands on.
pub const null_area: u8 = 0;
pub const walkable_area: u8 = 63;
/// As high as a span reaches, in steps.
pub const max_height: i32 = 0xffff;

pub const Span = struct {
    /// Its bottom and top, in `cell_height` steps above `origin`.
    smin: u16,
    smax: u16,
    area: u8,
    /// The span above it in its column.
    next: u32,
};

/// Columns across, along x, and deep, along z.
width: u32,
depth: u32,
/// The grid's low corner.
origin: Vec3,
cell_size: f32,
cell_height: f32,
/// Each column's lowest span.
columns: []u32,
spans: std.ArrayList(Span) = .empty,
/// Spans merged away, kept for the next.
free: u32 = none,

pub fn init(gpa: Allocator, min: Vec3, max: Vec3, cell_size: f32, cell_height: f32) Allocator.Error!Heightfield {
    const width: u32 = @intFromFloat(@max(1, @ceil((max[0] - min[0]) / cell_size)));
    const depth: u32 = @intFromFloat(@max(1, @ceil((max[2] - min[2]) / cell_size)));
    const columns = try gpa.alloc(u32, @as(usize, width) * depth);
    @memset(columns, none);
    return .{ .width = width, .depth = depth, .origin = min, .cell_size = cell_size, .cell_height = cell_height, .columns = columns };
}

pub fn deinit(self: *Heightfield, gpa: Allocator) void {
    gpa.free(self.columns);
    self.spans.deinit(gpa);
    self.* = undefined;
}

pub fn column(self: *const Heightfield, x: u32, z: u32) u32 {
    return self.columns[@as(usize, z) * self.width + x];
}

/// Put a span into column `(x, z)`, merged with every span it overlaps:
/// the two become one reaching both, and where their tops are within
/// `merge` steps of each other the top that can be stood on wins.
pub fn addSpan(self: *Heightfield, gpa: Allocator, x: u32, z: u32, smin: u16, smax: u16, area: u8, merge: i32) Allocator.Error!void {
    const at = @as(usize, z) * self.width + x;
    var made: Span = .{ .smin = smin, .smax = smax, .area = area, .next = none };
    var prev: u32 = none;
    var cur = self.columns[at];
    while (cur != none) {
        const s = self.spans.items[cur];
        if (s.smin > made.smax) break;
        if (s.smax < made.smin) {
            prev = cur;
            cur = s.next;
            continue;
        }
        made.smin = @min(made.smin, s.smin);
        made.smax = @max(made.smax, s.smax);
        if (@abs(@as(i32, made.smax) - @as(i32, s.smax)) <= merge) made.area = @max(made.area, s.area);
        const next = s.next;
        self.release(cur);
        if (prev != none) self.spans.items[prev].next = next else self.columns[at] = next;
        cur = next;
    }
    made.next = cur;
    const index = try self.take(gpa, made);
    if (prev != none) self.spans.items[prev].next = index else self.columns[at] = index;
}

fn take(self: *Heightfield, gpa: Allocator, s: Span) Allocator.Error!u32 {
    if (self.free != none) {
        const index = self.free;
        self.free = self.spans.items[index].next;
        self.spans.items[index] = s;
        return index;
    }
    try self.spans.append(gpa, s);
    return @intCast(self.spans.items.len - 1);
}

fn release(self: *Heightfield, index: u32) void {
    self.spans.items[index] = .{ .smin = 0, .smax = 0, .area = null_area, .next = self.free };
    self.free = index;
}

/// Fill the cells a triangle passes through: each cell's span reaches from
/// the lowest to the highest point of the part of the triangle over it.
pub fn rasterize(self: *Heightfield, gpa: Allocator, a: Vec3, b: Vec3, c: Vec3, area: u8, merge: i32) Allocator.Error!void {
    const Fill = struct {
        hf: *Heightfield,
        gpa: Allocator,
        area: u8,
        merge: i32,
        fn cell(fill: *const @This(), x: u32, z: u32, lo: u16, hi: u16) Allocator.Error!void {
            try fill.hf.addSpan(fill.gpa, x, z, lo, hi, fill.area, fill.merge);
        }
    };
    try self.cover(a, b, c, &Fill{ .hf = self, .gpa = gpa, .area = area, .merge = merge });
}

/// A convex solid's triangles, filled from its lowest point to its highest
/// over each cell: no floor inside it, as there would be inside a box
/// standing on the floor if only its faces were laid down. The top is
/// stood on when the triangle highest over the cell is `walkable`.
pub fn rasterizeSolid(self: *Heightfield, gpa: Allocator, vertices: []const Vec3, triangles: []const [3]u32, max_slope: f32, merge: i32) Allocator.Error!void {
    const Extent = struct { lo: u16, hi: u16, area: u8 };
    var columns: std.AutoArrayHashMapUnmanaged(u64, Extent) = .empty;
    defer columns.deinit(gpa);
    const Gather = struct {
        columns: *std.AutoArrayHashMapUnmanaged(u64, Extent),
        gpa: Allocator,
        area: u8,
        fn cell(g: *const @This(), x: u32, z: u32, lo: u16, hi: u16) Allocator.Error!void {
            const entry = try g.columns.getOrPut(g.gpa, @as(u64, z) << 32 | x);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{ .lo = lo, .hi = hi, .area = g.area };
                return;
            }
            const e = entry.value_ptr;
            e.lo = @min(e.lo, lo);
            if (hi > e.hi or (hi == e.hi and g.area > e.area)) e.area = g.area;
            e.hi = @max(e.hi, hi);
        }
    };
    for (triangles) |t| {
        const a = vertices[t[0]];
        const b = vertices[t[1]];
        const c = vertices[t[2]];
        const area = if (walkable(a, b, c, max_slope)) walkable_area else null_area;
        try self.cover(a, b, c, &Gather{ .columns = &columns, .gpa = gpa, .area = area });
    }
    var it = columns.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const e = entry.value_ptr.*;
        try self.addSpan(gpa, @truncate(key), @intCast(key >> 32), e.lo, e.hi, e.area, merge);
    }
}

/// Each cell the triangle passes over, with the lowest and highest steps
/// of the part of it over that cell: `ctx.cell(x, z, lo, hi)`.
fn cover(self: *Heightfield, a: Vec3, b: Vec3, c: Vec3, ctx: anytype) Allocator.Error!void {
    const tmin = @min(a, @min(b, c));
    const tmax = @max(a, @max(b, c));
    const cs = self.cell_size;
    const ics = 1 / cs;
    const ich = 1 / self.cell_height;
    const top = @as(f32, @floatFromInt(self.depth)) * cs + self.origin[2];
    const right = @as(f32, @floatFromInt(self.width)) * cs + self.origin[0];
    if (tmax[0] < self.origin[0] or tmin[0] > right or tmax[2] < self.origin[2] or tmin[2] > top) return;
    const by = max_height_world(self);

    const z0: i32 = @intFromFloat(@floor((tmin[2] - self.origin[2]) * ics));
    const z1: i32 = @intFromFloat(@floor((tmax[2] - self.origin[2]) * ics));
    const last_z: i32 = @as(i32, @intCast(self.depth)) - 1;
    const last_x: i32 = @as(i32, @intCast(self.width)) - 1;

    var buffers: [4][7]Vec3 = undefined;
    var in: []Vec3 = buffers[0][0..3];
    in[0] = a;
    in[1] = b;
    in[2] = c;
    var z = @max(z0, 0);
    // A triangle starting before the grid is cut at its edge first.
    if (z0 < 0) {
        const cut = split(in, &buffers[1], &buffers[2], self.origin[2], 2);
        std.mem.copyForwards(Vec3, buffers[0][0..cut.above.len], cut.above);
        in = buffers[0][0..cut.above.len];
    }
    while (z <= @min(z1, last_z)) : (z += 1) {
        const cz = self.origin[2] + @as(f32, @floatFromInt(z)) * cs;
        const row_cut = split(in, &buffers[1], &buffers[2], cz + cs, 2);
        const row = row_cut.below;
        if (row.len >= 3) try self.coverRow(row, @intCast(z), last_x, ics, ich, by, &buffers[3], ctx);
        // What is left, for the next row.
        std.mem.copyForwards(Vec3, buffers[0][0..row_cut.above.len], row_cut.above);
        in = buffers[0][0..row_cut.above.len];
    }
}

fn coverRow(self: *Heightfield, row: []const Vec3, z: u32, last_x: i32, ics: f32, ich: f32, by: f32, buffer: *[7]Vec3, ctx: anytype) Allocator.Error!void {
    const cs = self.cell_size;
    var min_x = row[0][0];
    var max_x = row[0][0];
    for (row[1..]) |p| {
        min_x = @min(min_x, p[0]);
        max_x = @max(max_x, p[0]);
    }
    const x0: i32 = @intFromFloat(@floor((min_x - self.origin[0]) * ics));
    const x1: i32 = @intFromFloat(@floor((max_x - self.origin[0]) * ics));
    if (x1 < 0 or x0 > last_x) return;

    var cells: []Vec3 = buffer[0..row.len];
    std.mem.copyForwards(Vec3, cells, row);
    var x = x0;
    if (x0 < 0) {
        var left: [7]Vec3 = undefined;
        var rest: [7]Vec3 = undefined;
        const cut = split(cells, &left, &rest, self.origin[0], 0);
        std.mem.copyForwards(Vec3, buffer[0..cut.above.len], cut.above);
        cells = buffer[0..cut.above.len];
        x = 0;
    }
    while (x <= @min(x1, last_x)) : (x += 1) {
        const cx = self.origin[0] + @as(f32, @floatFromInt(x)) * cs;
        var cell: [7]Vec3 = undefined;
        var rest: [7]Vec3 = undefined;
        const cut = split(cells, &cell, &rest, cx + cs, 0);
        std.mem.copyForwards(Vec3, buffer[0..cut.above.len], cut.above);
        cells = buffer[0..cut.above.len];
        if (cut.below.len < 3) continue;

        var smin = cut.below[0][1];
        var smax = smin;
        for (cut.below[1..]) |p| {
            smin = @min(smin, p[1]);
            smax = @max(smax, p[1]);
        }
        smin -= self.origin[1];
        smax -= self.origin[1];
        if (smax < 0 or smin > by) continue;
        smin = @max(smin, 0);
        smax = @min(smax, by);
        const lo: i32 = std.math.clamp(@as(i32, @intFromFloat(@floor(smin * ich))), 0, max_height);
        const hi: i32 = std.math.clamp(@as(i32, @intFromFloat(@ceil(smax * ich))), lo + 1, max_height);
        try ctx.cell(@intCast(x), z, @intCast(lo), @intCast(hi));
    }
}

fn max_height_world(self: *const Heightfield) f32 {
    return @as(f32, @floatFromInt(max_height)) * self.cell_height;
}

const Cut = struct { below: []Vec3, above: []Vec3 };

/// A convex polygon cut by the plane where `axis` is `at`: the part on the
/// low side and the part on the high side.
fn split(in: []const Vec3, below_buffer: *[7]Vec3, above_buffer: *[7]Vec3, at: f32, comptime axis: usize) Cut {
    if (in.len == 0) return .{ .below = below_buffer[0..0], .above = above_buffer[0..0] };
    var d: [7]f32 = undefined;
    for (in, 0..) |p, i| d[i] = at - p[axis];
    var m: usize = 0;
    var n: usize = 0;
    var j = in.len - 1;
    for (0..in.len) |i| {
        const ina = d[j] >= 0;
        const inb = d[i] >= 0;
        if (ina != inb) {
            const s = d[j] / (d[j] - d[i]);
            const p = in[j] + (in[i] - in[j]) * @as(Vec3, @splat(s));
            below_buffer[m] = p;
            above_buffer[n] = p;
            m += 1;
            n += 1;
            if (d[i] > 0) {
                below_buffer[m] = in[i];
                m += 1;
            } else if (d[i] < 0) {
                above_buffer[n] = in[i];
                n += 1;
            }
        } else {
            if (d[i] >= 0) {
                below_buffer[m] = in[i];
                m += 1;
                if (d[i] != 0) {
                    j = i;
                    continue;
                }
            }
            above_buffer[n] = in[i];
            n += 1;
        }
        j = i;
    }
    return .{ .below = below_buffer[0..m], .above = above_buffer[0..n] };
}

/// Whether a triangle's top can be stood on: its normal, by its winding
/// (counter-clockwise from outside), no further from up than `max_slope`.
pub fn walkable(a: Vec3, b: Vec3, c: Vec3, max_slope: f32) bool {
    const n = vec.normalize(vec.cross(b - a, c - a));
    return n[1] > @cos(max_slope);
}

/// A span not to be stood on just above one that is - a kerb, a stair's
/// edge - is stood on, when it is no more than `climb` higher.
pub fn filterLowObstacles(self: *Heightfield, climb: i32) void {
    for (self.columns) |head| {
        var prev_walkable = false;
        var prev_area: u8 = null_area;
        var prev_top: i32 = 0;
        var at = head;
        while (at != none) {
            const s = &self.spans.items[at];
            const was_walkable = s.area != null_area;
            if (!was_walkable and prev_walkable and @as(i32, s.smax) - prev_top <= climb) s.area = prev_area;
            // Only one step up from what is stood on: the walkable flag does
            // not climb a tower of obstacles.
            prev_walkable = was_walkable;
            prev_area = s.area;
            prev_top = s.smax;
            at = s.next;
        }
    }
}

/// A span at the edge of a drop deeper than `climb`, or among neighbours
/// further apart in height than `steep`, is not stood on: what stands
/// there would fall, or is on a slope too steep.
pub fn filterLedges(self: *Heightfield, gpa: Allocator, height: i32, climb: i32, steep: i32) Allocator.Error!void {
    // Decided on the spans as they were, then marked.
    var ledges: std.ArrayList(u32) = .empty;
    defer ledges.deinit(gpa);
    for (0..self.depth) |z| {
        for (0..self.width) |x| {
            var at = self.column(@intCast(x), @intCast(z));
            while (at != none) : (at = self.spans.items[at].next) {
                const s = self.spans.items[at];
                if (s.area == null_area) continue;
                const bot: i32 = s.smax;
                const top: i32 = if (s.next != none) self.spans.items[s.next].smin else max_height;
                var lowest: i32 = max_height;
                var reach_min: i32 = s.smax;
                var reach_max: i32 = s.smax;
                for (0..4) |dir| {
                    const nx = @as(i32, @intCast(x)) + dx[dir];
                    const nz = @as(i32, @intCast(z)) + dz[dir];
                    if (nx < 0 or nz < 0 or nx >= self.width or nz >= self.depth) {
                        lowest = @min(lowest, -climb - bot);
                        continue;
                    }
                    var ns = self.column(@intCast(nx), @intCast(nz));
                    // The air under the neighbour's lowest span.
                    var nbot: i32 = -climb;
                    var ntop: i32 = if (ns != none) self.spans.items[ns].smin else max_height;
                    if (@min(top, ntop) - @max(bot, nbot) > height) lowest = @min(lowest, nbot - bot);
                    while (ns != none) : (ns = self.spans.items[ns].next) {
                        const n = self.spans.items[ns];
                        nbot = n.smax;
                        ntop = if (n.next != none) self.spans.items[n.next].smin else max_height;
                        if (@min(top, ntop) - @max(bot, nbot) > height) {
                            lowest = @min(lowest, nbot - bot);
                            if (@abs(nbot - bot) <= climb) {
                                reach_min = @min(reach_min, nbot);
                                reach_max = @max(reach_max, nbot);
                            }
                        }
                    }
                }
                if (lowest < -climb or reach_max - reach_min > steep) try ledges.append(gpa, at);
            }
        }
    }
    for (ledges.items) |at| self.spans.items[at].area = null_area;
}

/// A span with less than `height` of air above it is not stood on.
pub fn filterLowCeilings(self: *Heightfield, height: i32) void {
    for (self.columns) |head| {
        var at = head;
        while (at != none) {
            const s = &self.spans.items[at];
            const bot: i32 = s.smax;
            const top: i32 = if (s.next != none) self.spans.items[s.next].smin else max_height;
            if (top - bot <= height) s.area = null_area;
            at = s.next;
        }
    }
}

/// The four neighbours, in order: -x, +z, +x, -z.
pub const dx = [4]i32{ -1, 0, 1, 0 };
pub const dz = [4]i32{ 0, 1, 0, -1 };

fn countSpans(self: *const Heightfield, x: u32, z: u32) usize {
    var count: usize = 0;
    var at = self.column(x, z);
    while (at != none) : (at = self.spans.items[at].next) count += 1;
    return count;
}

test "two overlapping spans merge into one, and the higher top decides what is stood on" {
    var hf = try Heightfield.init(testing.allocator, .{ 0, 0, 0 }, .{ 1, 10, 1 }, 1, 0.1);
    defer hf.deinit(testing.allocator);
    try hf.addSpan(testing.allocator, 0, 0, 0, 10, null_area, 1);
    try hf.addSpan(testing.allocator, 0, 0, 20, 30, walkable_area, 1);
    try testing.expectEqual(@as(usize, 2), hf.countSpans(0, 0));
    try hf.addSpan(testing.allocator, 0, 0, 5, 22, null_area, 1);
    try testing.expectEqual(@as(usize, 1), hf.countSpans(0, 0));
    const s = hf.spans.items[hf.column(0, 0)];
    try testing.expectEqual(@as(u16, 0), s.smin);
    try testing.expectEqual(@as(u16, 30), s.smax);
    try testing.expectEqual(walkable_area, s.area);
}

test "a floor's two triangles fill every cell under it at its height, walkable" {
    var hf = try Heightfield.init(testing.allocator, .{ 0, 0, 0 }, .{ 4, 2, 4 }, 0.5, 0.1);
    defer hf.deinit(testing.allocator);
    const y = 0.55;
    const a: Vec3 = .{ 0, y, 0 };
    const b: Vec3 = .{ 0, y, 4 };
    const c: Vec3 = .{ 4, y, 4 };
    const d: Vec3 = .{ 4, y, 0 };
    try testing.expect(walkable(a, b, c, std.math.degreesToRadians(45)));
    try testing.expect(!walkable(a, c, b, std.math.degreesToRadians(45)));
    try hf.rasterize(testing.allocator, a, b, c, walkable_area, 1);
    try hf.rasterize(testing.allocator, a, c, d, walkable_area, 1);
    for (0..hf.depth) |z| for (0..hf.width) |x| {
        try testing.expectEqual(@as(usize, 1), hf.countSpans(@intCast(x), @intCast(z)));
        const s = hf.spans.items[hf.column(@intCast(x), @intCast(z))];
        try testing.expectEqual(@as(u16, 5), s.smin);
        try testing.expectEqual(@as(u16, 6), s.smax);
        try testing.expectEqual(walkable_area, s.area);
    };
}
