// SPDX-License-Identifier: BSD-3-Clause

//! The places to stand: one span for each top of the heightfield that can
//! be stood on, with how much air is above it and which spans beside it a
//! step can reach. Here it is worn back from the walls by the agent's
//! radius and cut into regions, each a piece of floor a contour can go
//! round.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Heightfield = @import("Heightfield.zig");
const vec = @import("vec.zig");
const Vec3 = vec.Vec3;

const Compact = @This();

pub const none = std.math.maxInt(u32);
pub const null_area = Heightfield.null_area;
pub const dx = Heightfield.dx;
pub const dz = Heightfield.dz;

pub const Span = struct {
    /// Its floor, in steps.
    y: u16,
    /// The air above it, in steps.
    h: u16,
    /// The span a step reaches in each of the four ways, or `none`.
    con: [4]u32 = @splat(none),
    region: u16 = 0,
    area: u8,
};

pub const Cell = struct {
    first: u32,
    count: u32,
};

width: u32,
depth: u32,
origin: Vec3,
cell_size: f32,
cell_height: f32,
/// The agent's height and climb, in steps.
walkable_height: i32,
walkable_climb: i32,
cells: []Cell,
spans: []Span,
/// How many regions, nought being none.
region_count: u16 = 0,

/// The tops of `hf` that can be stood on, joined to their neighbours where
/// the agent can step across: no more than `climb` up or down, with
/// `height` of air over both.
pub fn init(gpa: Allocator, hf: *const Heightfield, height: i32, climb: i32) Allocator.Error!Compact {
    const cells = try gpa.alloc(Cell, hf.columns.len);
    errdefer gpa.free(cells);
    var count: usize = 0;
    for (hf.columns) |head| {
        var at = head;
        while (at != Heightfield.none) : (at = hf.spans.items[at].next) {
            if (hf.spans.items[at].area != null_area) count += 1;
        }
    }
    const spans = try gpa.alloc(Span, count);
    errdefer gpa.free(spans);

    var index: u32 = 0;
    for (hf.columns, cells) |head, *cell| {
        cell.* = .{ .first = index, .count = 0 };
        var at = head;
        while (at != Heightfield.none) : (at = hf.spans.items[at].next) {
            const s = hf.spans.items[at];
            if (s.area == null_area) continue;
            const bot: i32 = s.smax;
            const top: i32 = if (s.next != Heightfield.none) hf.spans.items[s.next].smin else Heightfield.max_height;
            spans[index] = .{
                .y = @intCast(std.math.clamp(bot, 0, 0xffff)),
                .h = @intCast(std.math.clamp(top - bot, 0, 0xffff)),
                .area = s.area,
            };
            index += 1;
            cell.count += 1;
        }
    }

    var self: Compact = .{
        .width = hf.width,
        .depth = hf.depth,
        .origin = hf.origin,
        .cell_size = hf.cell_size,
        .cell_height = hf.cell_height,
        .walkable_height = height,
        .walkable_climb = climb,
        .cells = cells,
        .spans = spans,
    };
    // Who can step to whom.
    for (0..self.depth) |z| for (0..self.width) |x| {
        const cell = self.cellAt(@intCast(x), @intCast(z));
        for (cell.first..cell.first + cell.count) |i| {
            const s = &self.spans[i];
            for (0..4) |dir| {
                const nx = @as(i32, @intCast(x)) + dx[dir];
                const nz = @as(i32, @intCast(z)) + dz[dir];
                if (nx < 0 or nz < 0 or nx >= self.width or nz >= self.depth) continue;
                const other = self.cellAt(@intCast(nx), @intCast(nz));
                for (other.first..other.first + other.count) |k| {
                    const n = self.spans[k];
                    const bot = @max(@as(i32, s.y), n.y);
                    const top = @min(@as(i32, s.y) + s.h, @as(i32, n.y) + n.h);
                    if (top - bot >= height and @abs(@as(i32, n.y) - s.y) <= climb) {
                        s.con[dir] = @intCast(k);
                        break;
                    }
                }
            }
        }
    };
    return self;
}

pub fn deinit(self: *Compact, gpa: Allocator) void {
    gpa.free(self.cells);
    gpa.free(self.spans);
    self.* = undefined;
}

pub fn cellAt(self: *const Compact, x: u32, z: u32) Cell {
    return self.cells[@as(usize, z) * self.width + x];
}

/// The span a step from `i` the way `dir` reaches, if it is stood on.
pub fn neighbour(self: *const Compact, i: usize, dir: usize) ?u32 {
    const k = self.spans[i].con[dir];
    if (k == none or self.spans[k].area == null_area) return null;
    return k;
}

/// No standing nearer a wall or a drop than `radius` cells: the agent's
/// middle never goes there, so the mesh stops short of it.
pub fn erode(self: *Compact, gpa: Allocator, radius: i32) Allocator.Error!void {
    const dist = try gpa.alloc(u16, self.spans.len);
    defer gpa.free(dist);
    // At an edge: nought.
    for (self.spans, dist) |s, *d| {
        d.* = 0;
        if (s.area == null_area) continue;
        var joined: usize = 0;
        for (s.con) |k| {
            if (k != none and self.spans[k].area != null_area) joined += 1;
        }
        d.* = if (joined == 4) 0xffff else 0;
    }
    // Twice a cell straight across, three times one across a corner; down
    // and across first, then back up.
    for (0..self.depth) |z| for (0..self.width) |x| {
        const cell = self.cellAt(@intCast(x), @intCast(z));
        for (cell.first..cell.first + cell.count) |i| {
            const s = self.spans[i];
            if (s.con[0] != none) {
                const a = s.con[0];
                relax(dist, i, a, 2);
                if (self.spans[a].con[3] != none) relax(dist, i, self.spans[a].con[3], 3);
            }
            if (s.con[3] != none) {
                const a = s.con[3];
                relax(dist, i, a, 2);
                if (self.spans[a].con[2] != none) relax(dist, i, self.spans[a].con[2], 3);
            }
        }
    };
    var z: usize = self.depth;
    while (z > 0) {
        z -= 1;
        var x: usize = self.width;
        while (x > 0) {
            x -= 1;
            const cell = self.cellAt(@intCast(x), @intCast(z));
            for (cell.first..cell.first + cell.count) |i| {
                const s = self.spans[i];
                if (s.con[2] != none) {
                    const a = s.con[2];
                    relax(dist, i, a, 2);
                    if (self.spans[a].con[1] != none) relax(dist, i, self.spans[a].con[1], 3);
                }
                if (s.con[1] != none) {
                    const a = s.con[1];
                    relax(dist, i, a, 2);
                    if (self.spans[a].con[0] != none) relax(dist, i, self.spans[a].con[0], 3);
                }
            }
        }
    }
    const limit: u32 = @intCast(radius * 2);
    for (self.spans, dist) |*s, d| {
        if (d < limit) s.area = null_area;
    }
}

fn relax(dist: []u16, i: usize, from: u32, step: u16) void {
    const through = dist[from] +| step;
    if (through < dist[i]) dist[i] = through;
}

/// Cut what can be stood on into regions: each row is swept into runs, and
/// a run carries on the region of the run before it when it is the only
/// one to - so no region has a hole, and every one is a piece a contour
/// can go round. Groups of regions joined to each other covering fewer
/// than `min_cells` are dropped: the top of a crate, a ledge too small to
/// matter.
pub fn buildRegions(self: *Compact, gpa: Allocator, min_cells: usize) (Allocator.Error || error{TooManyRegions})!void {
    const Sweep = struct {
        /// The region of the row before it joins, `0` none, `multiple`
        /// more than one.
        nei: u16 = 0,
        /// How many of its spans join `nei`.
        ns: u32 = 0,
        id: u16 = 0,
        const multiple = std.math.maxInt(u16);
    };
    var sweeps: std.ArrayList(Sweep) = .empty;
    defer sweeps.deinit(gpa);
    // How many spans of this row join each region of the last.
    var joins: std.ArrayList(u32) = .empty;
    defer joins.deinit(gpa);

    var next_id: u32 = 1;
    for (0..self.depth) |z| {
        sweeps.clearRetainingCapacity();
        try sweeps.append(gpa, .{});
        try joins.resize(gpa, next_id + 1);
        @memset(joins.items, 0);
        for (0..self.width) |x| {
            const cell = self.cellAt(@intCast(x), @intCast(z));
            for (cell.first..cell.first + cell.count) |i| {
                const s = &self.spans[i];
                if (s.area == null_area) continue;
                // Along the row, from the left.
                var sweep: u16 = 0;
                if (self.neighbour(i, 0)) |a| {
                    if (self.spans[a].area == s.area) sweep = self.spans[a].region;
                }
                if (sweep == 0) {
                    try sweeps.append(gpa, .{});
                    sweep = @intCast(sweeps.items.len - 1);
                }
                // The row before.
                if (self.neighbour(i, 3)) |a| {
                    const n = self.spans[a];
                    if (n.region != 0 and n.area == s.area) {
                        const sw = &sweeps.items[sweep];
                        if (sw.nei == 0 or sw.nei == n.region) {
                            sw.nei = n.region;
                            sw.ns += 1;
                            joins.items[n.region] += 1;
                        } else sw.nei = Sweep.multiple;
                    }
                }
                s.region = sweep;
            }
        }
        // Each sweep its region: the one before, if it is that one's only
        // carrying on; a new one otherwise.
        for (sweeps.items[1..]) |*sw| {
            if (sw.nei != Sweep.multiple and sw.nei != 0 and joins.items[sw.nei] == sw.ns) {
                sw.id = sw.nei;
            } else {
                if (next_id >= std.math.maxInt(u16)) return error.TooManyRegions;
                sw.id = @intCast(next_id);
                next_id += 1;
            }
        }
        for (0..self.width) |x| {
            const cell = self.cellAt(@intCast(x), @intCast(z));
            for (cell.first..cell.first + cell.count) |i| {
                const s = &self.spans[i];
                if (s.region != 0) s.region = sweeps.items[s.region].id;
            }
        }
    }
    try self.dropSmall(gpa, next_id, min_cells);
}

/// Drop the groups of joined regions smaller than `min_cells`, and number
/// what is left from one.
fn dropSmall(self: *Compact, gpa: Allocator, count: u32, min_cells: usize) Allocator.Error!void {
    const sizes = try gpa.alloc(usize, count);
    defer gpa.free(sizes);
    @memset(sizes, 0);
    // The groups, by joining the regions that touch.
    const parent = try gpa.alloc(u32, count);
    defer gpa.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    for (self.spans, 0..) |s, i| {
        if (s.region == 0) continue;
        sizes[s.region] += 1;
        for (0..4) |dir| {
            const a = self.neighbour(i, dir) orelse continue;
            const r = self.spans[a].region;
            if (r != 0 and r != s.region) unite(parent, s.region, r);
        }
    }
    const group_sizes = try gpa.alloc(usize, count);
    defer gpa.free(group_sizes);
    @memset(group_sizes, 0);
    for (1..count) |r| group_sizes[find(parent, @intCast(r))] += sizes[r];

    const renumber = try gpa.alloc(u16, count);
    defer gpa.free(renumber);
    @memset(renumber, 0);
    var next: u16 = 1;
    for (1..count) |r| {
        if (sizes[r] == 0) continue;
        if (group_sizes[find(parent, @intCast(r))] < min_cells) continue;
        renumber[r] = next;
        next += 1;
    }
    for (self.spans) |*s| s.region = renumber[s.region];
    self.region_count = next;
}

fn find(parent: []u32, a: u32) u32 {
    var at = a;
    while (parent[at] != at) {
        parent[at] = parent[parent[at]];
        at = parent[at];
    }
    return at;
}

fn unite(parent: []u32, a: u32, b: u32) void {
    const ra = find(parent, a);
    const rb = find(parent, b);
    if (ra != rb) parent[@max(ra, rb)] = @min(ra, rb);
}

fn floorOf(gpa: Allocator, size: u32) !Heightfield {
    var hf = try Heightfield.init(gpa, .{ 0, 0, 0 }, .{ @floatFromInt(size), 4, @floatFromInt(size) }, 1, 0.1);
    for (0..size) |z| for (0..size) |x| {
        try hf.addSpan(gpa, @intCast(x), @intCast(z), 0, 5, Heightfield.walkable_area, 1);
    };
    return hf;
}

test "a floor's spans join their four neighbours, and the floor worn back by two cells from its edges" {
    var hf = try floorOf(testing.allocator, 10);
    defer hf.deinit(testing.allocator);
    var chf = try Compact.init(testing.allocator, &hf, 10, 2);
    defer chf.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 100), chf.spans.len);
    const middle = chf.cellAt(5, 5).first;
    for (chf.spans[middle].con) |k| try testing.expect(k != none);
    try testing.expectEqual(none, chf.spans[chf.cellAt(0, 5).first].con[0]);

    try chf.erode(testing.allocator, 2);
    var standing: usize = 0;
    for (chf.spans) |s| {
        if (s.area != null_area) standing += 1;
    }
    // The six-by-six middle, two cells in from each side.
    try testing.expectEqual(@as(usize, 36), standing);
    try testing.expect(chf.spans[chf.cellAt(2, 2).first].area != null_area);
    try testing.expect(chf.spans[chf.cellAt(1, 5).first].area == null_area);
}

test "an open floor is one region, a floor round a pillar is several with no holes, and a lone speck is dropped" {
    var hf = try floorOf(testing.allocator, 12);
    defer hf.deinit(testing.allocator);
    var chf = try Compact.init(testing.allocator, &hf, 10, 2);
    defer chf.deinit(testing.allocator);
    try chf.buildRegions(testing.allocator, 4);
    try testing.expectEqual(@as(u16, 2), chf.region_count);

    // A pillar in the middle splits the rows it crosses into two runs.
    for (5..7) |z| for (5..7) |x| {
        chf.spans[chf.cellAt(@intCast(x), @intCast(z)).first].area = null_area;
    };
    for (chf.spans) |*s| s.region = 0;
    try chf.buildRegions(testing.allocator, 4);
    try testing.expect(chf.region_count > 2);
    for (chf.spans) |s| {
        if (s.area != null_area) try testing.expect(s.region != 0);
    }
}
