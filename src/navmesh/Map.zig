// SPDX-License-Identifier: BSD-3-Clause

//! Several navigation meshes as one map: each put into the world by its own
//! transform, joined where their edges meet - doorways - and joined by
//! links: a jump across a gap, a drop off a ledge, a ladder. The way across
//! is A* from polygon to polygon through both, pulled tight through the
//! doorways, and broken at each jump: its start and its end are corners of
//! the way, marked, so what walks it knows to jump there.
//!
//! What stands in the way may close the doorways it stands in, or narrow
//! them: `Query.blockers`, discs a way does not go through.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const vec = @import("vec.zig");
const Vec3 = vec.Vec3;
const Affine = vec.Affine;
const NavMesh = @import("NavMesh.zig");

const Map = @This();

pub const none = NavMesh.none;

/// A mesh, and where it is.
pub const Part = struct {
    mesh: *const NavMesh,
    to_world: Affine = .identity,
    to_local: Affine = .identity,
};

/// A way out of a polygon besides its own edges.
pub const Link = struct {
    /// The polygon it comes into, by the map's numbering.
    to: u32,
    /// A doorway: its two ends, left and right going through it. A jump:
    /// where it starts and where it lands.
    a: Vec3,
    b: Vec3,
    kind: Kind,
    travel_cost: f32 = 1,
    enter_cost: f32 = 0,
    /// For a jump: what it was given as.
    id: u32 = 0,

    pub const Kind = enum(u8) { doorway, jump };
};

/// A link to make: from near `start` to near `end`.
pub const Jump = struct {
    start: Vec3,
    end: Vec3,
    bidirectional: bool = true,
    /// Going along it costs its length times this, and this added.
    travel_cost: f32 = 1,
    enter_cost: f32 = 0,
    /// Said back in the way's marks.
    id: u32 = 0,
};

pub const Settings = struct {
    /// How far apart two meshes' edges may be on the ground, and in
    /// height, and still meet.
    edge_margin: f32 = 0.25,
    edge_height_margin: f32 = 0.5,
    /// How far from a mesh a jump's ends may be.
    jump_search: f32 = 1,
};

/// A disc a way does not go through: what stands in a doorway closes it,
/// or leaves only the part of it beside itself.
pub const Blocker = struct {
    /// Its foot, and how tall it is.
    center: Vec3,
    radius: f32,
    height: f32 = 2,
};

parts: []const Part,
/// The map's number of each part's first polygon.
firsts: []const u32,
/// The links out of each polygon: those of polygon `i` are
/// `links[link_first[i]..link_first[i + 1]]`. Empty for none at all.
links: []const Link = &.{},
link_first: []const u32 = &.{},
/// Whether the slices are the map's own.
owned: bool = false,

/// One mesh, where it is, borrowed: nothing to free.
pub fn single(part: *const [1]Part) Map {
    return .{ .parts = part, .firsts = &.{0} };
}

/// The meshes of `parts` as one map, joined where their edges meet and by
/// `jumps`. Keeps `parts` borrowed: they and their meshes outlive it.
pub fn init(gpa: Allocator, parts: []const Part, jumps: []const Jump, settings: Settings) Allocator.Error!Map {
    const firsts = try gpa.alloc(u32, parts.len);
    errdefer gpa.free(firsts);
    var count: u32 = 0;
    for (parts, firsts) |part, *first| {
        first.* = count;
        count += @intCast(part.mesh.polygons.len);
    }
    var map: Map = .{ .parts = parts, .firsts = firsts, .owned = true };
    var made: std.ArrayList(From) = .empty;
    defer made.deinit(gpa);
    try map.joinEdges(gpa, settings, &made);
    for (jumps) |jump| try map.addJump(jump, settings, gpa, &made);

    // Out of each polygon, in order.
    std.mem.sort(From, made.items, {}, From.less);
    const links = try gpa.alloc(Link, made.items.len);
    errdefer gpa.free(links);
    const link_first = try gpa.alloc(u32, count + 1);
    errdefer gpa.free(link_first);
    @memset(link_first, 0);
    for (made.items, links) |m, *l| {
        l.* = m.link;
        link_first[m.from + 1] += 1;
    }
    for (1..link_first.len) |i| link_first[i] += link_first[i - 1];
    map.links = links;
    map.link_first = link_first;
    return map;
}

pub fn deinit(self: *Map, gpa: Allocator) void {
    if (self.owned) {
        gpa.free(self.firsts);
        gpa.free(self.links);
        gpa.free(self.link_first);
    }
    self.* = undefined;
}

const From = struct {
    from: u32,
    link: Link,

    fn less(_: void, a: From, b: From) bool {
        return a.from < b.from;
    }
};

pub fn polygonCount(self: *const Map) u32 {
    if (self.parts.len == 0) return 0;
    const last = self.parts.len - 1;
    return self.firsts[last] + @as(u32, @intCast(self.parts[last].mesh.polygons.len));
}

pub const Where = struct { part: u32, poly: u32 };

/// Which part a polygon of the map is in, and its number there.
pub fn where(self: *const Map, id: u32) Where {
    var part: usize = self.parts.len - 1;
    while (part > 0 and self.firsts[part] > id) part -= 1;
    return .{ .part = @intCast(part), .poly = id - self.firsts[part] };
}

/// A corner of a polygon of the map, in the world.
pub fn corner(self: *const Map, id: u32, i: usize) Vec3 {
    const w = self.where(id);
    const part = self.parts[w.part];
    return part.to_world.apply(part.mesh.corner(w.poly, i));
}

pub fn linksOf(self: *const Map, id: u32) []const Link {
    if (self.link_first.len == 0) return &.{};
    return self.links[self.link_first[id]..self.link_first[id + 1]];
}

// -------------------------------------------------------------------------
// Joining
// -------------------------------------------------------------------------

const Edge = struct {
    id: u32,
    part: u32,
    a: Vec3,
    b: Vec3,
};

/// Doorways where an edge with nothing across it lies along another
/// part's, within the margin: through the stretch where the two overlap.
fn joinEdges(self: *Map, gpa: Allocator, settings: Settings, made: *std.ArrayList(From)) Allocator.Error!void {
    if (self.parts.len < 2) return;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    for (self.parts, 0..) |part, p| {
        for (part.mesh.polygons, 0..) |poly, i| {
            for (0..poly.count) |e| {
                if (poly.neighbours[e] != NavMesh.none) continue;
                const id = self.firsts[p] + @as(u32, @intCast(i));
                try edges.append(gpa, .{
                    .id = id,
                    .part = @intCast(p),
                    .a = part.to_world.apply(part.mesh.corner(@intCast(i), e)),
                    .b = part.to_world.apply(part.mesh.corner(@intCast(i), (e + 1) % poly.count)),
                });
            }
        }
    }
    // Edges by the cells of a grid they cross, to look only at those near.
    const cell = @max(settings.edge_margin * 8, 2);
    var grid: std.AutoHashMapUnmanaged([2]i32, std.ArrayList(u32)) = .empty;
    defer {
        var it = grid.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        grid.deinit(gpa);
    }
    for (edges.items, 0..) |e, index| {
        const lo = @min(e.a, e.b) - @as(Vec3, @splat(settings.edge_margin));
        const hi = @max(e.a, e.b) + @as(Vec3, @splat(settings.edge_margin));
        var gx: i32 = @intFromFloat(@floor(lo[0] / cell));
        while (gx <= @as(i32, @intFromFloat(@floor(hi[0] / cell)))) : (gx += 1) {
            var gz: i32 = @intFromFloat(@floor(lo[2] / cell));
            while (gz <= @as(i32, @intFromFloat(@floor(hi[2] / cell)))) : (gz += 1) {
                const entry = try grid.getOrPut(gpa, .{ gx, gz });
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(gpa, @intCast(index));
            }
        }
    }
    var seen: std.AutoHashMapUnmanaged([2]u32, void) = .empty;
    defer seen.deinit(gpa);
    var it = grid.valueIterator();
    while (it.next()) |list| {
        for (list.items) |i| for (list.items) |j| {
            if (i == j) continue;
            const e1 = edges.items[i];
            const e2 = edges.items[j];
            if (e1.part == e2.part) continue;
            const pair = try seen.getOrPut(gpa, .{ i, j });
            if (pair.found_existing) continue;
            const door = overlap(e1, e2, settings) orelse continue;
            try made.append(gpa, .{ .from = e1.id, .link = .{ .to = e2.id, .a = door[0], .b = door[1], .kind = .doorway } });
        };
    }
}

/// The stretch of `e1` along which `e2` lies, within the margins: its two
/// ends on `e1`, in `e1`'s order.
fn overlap(e1: Edge, e2: Edge, settings: Settings) ?[2]Vec3 {
    const dx = e1.b[0] - e1.a[0];
    const dz = e1.b[2] - e1.a[2];
    const length = @sqrt(dx * dx + dz * dz);
    if (length < 1e-4) return null;
    const ux = dx / length;
    const uz = dz / length;
    // Along e1, and off it, for each end of e2.
    var t: [2]f32 = undefined;
    for ([_]Vec3{ e2.a, e2.b }, 0..) |p, k| {
        const px = p[0] - e1.a[0];
        const pz = p[2] - e1.a[2];
        if (@abs(px * uz - pz * ux) > settings.edge_margin) return null;
        t[k] = px * ux + pz * uz;
    }
    const t0 = @max(@min(t[0], t[1]), 0);
    const t1 = @min(@max(t[0], t[1]), length);
    if (t1 - t0 < 0.05) return null;
    const a = vec.lerp(e1.a, e1.b, t0 / length);
    const b = vec.lerp(e1.a, e1.b, t1 / length);
    // The two at about the same height.
    const span = t[1] - t[0];
    for ([_]f32{ t0, t1 }, [_]Vec3{ a, b }) |at, p| {
        const s = if (@abs(span) > 1e-6) (at - t[0]) / span else 0;
        const other = vec.lerp(e2.a, e2.b, std.math.clamp(s, 0, 1));
        if (@abs(other[1] - p[1]) > settings.edge_height_margin) return null;
    }
    return .{ a, b };
}

fn addJump(self: *Map, jump: Jump, settings: Settings, gpa: Allocator, made: *std.ArrayList(From)) Allocator.Error!void {
    const from = self.closestPoint(jump.start) orelse return;
    const to = self.closestPoint(jump.end) orelse return;
    if (vec.length(from.point - jump.start) > settings.jump_search) return;
    if (vec.length(to.point - jump.end) > settings.jump_search) return;
    if (from.id == to.id) return;
    try made.append(gpa, .{ .from = from.id, .link = .{ .to = to.id, .a = from.point, .b = to.point, .kind = .jump, .travel_cost = jump.travel_cost, .enter_cost = jump.enter_cost, .id = jump.id } });
    if (jump.bidirectional) {
        try made.append(gpa, .{ .from = to.id, .link = .{ .to = from.id, .a = to.point, .b = from.point, .kind = .jump, .travel_cost = jump.travel_cost, .enter_cost = jump.enter_cost, .id = jump.id } });
    }
}

// -------------------------------------------------------------------------
// Asking
// -------------------------------------------------------------------------

pub const Nearest = struct {
    id: u32,
    point: Vec3,
};

/// The point of the map nearest `p`, in the world: of the polygons straight
/// above or below it, the nearest in height; else the nearest edge.
pub fn closestPoint(self: *const Map, p: Vec3) ?Nearest {
    var best: ?Nearest = null;
    var best_over = false;
    var best_d: f32 = std.math.inf(f32);
    for (self.parts, 0..) |part, i| {
        const found = part.mesh.closest(part.to_local.apply(p)) orelse continue;
        const point = part.to_world.apply(found.point);
        const d = if (found.over) @abs(point[1] - p[1]) else vec.length(point - p);
        if (best_over and !found.over) continue;
        if (found.over and !best_over or d < best_d) {
            best_over = found.over;
            best_d = d;
            best = .{ .id = self.firsts[i] + found.poly, .point = point };
        }
    }
    return best;
}

/// The point of polygon `id` nearest `p`, in the world.
pub fn closestOnPolygon(self: *const Map, id: u32, p: Vec3) Vec3 {
    const w = self.where(id);
    const part = self.parts[w.part];
    return part.to_world.apply(part.mesh.closestOnPolygon(w.poly, part.to_local.apply(p)));
}

/// A corner of a way: an ordinary one, or where a jump starts or lands.
pub const Mark = struct {
    kind: Kind = .corner,
    /// The jump's id, at its start and its end.
    link: u32 = 0,

    pub const Kind = enum(u8) { corner, link_start, link_end };
};

pub const Path = struct {
    /// The corners to walk through, the start first and the end last, in
    /// the world, and what each is.
    points: std.ArrayList(Vec3) = .empty,
    marks: std.ArrayList(Mark) = .empty,
    /// The polygons gone through, by the map's numbering.
    corridor: std.ArrayList(u32) = .empty,
    /// The end could not be reached: the path goes as near it as it can.
    partial: bool = false,

    pub fn deinit(self: *Path, gpa: Allocator) void {
        self.points.deinit(gpa);
        self.marks.deinit(gpa);
        self.corridor.deinit(gpa);
        self.* = undefined;
    }

    pub fn clear(self: *Path) void {
        self.points.clearRetainingCapacity();
        self.marks.clearRetainingCapacity();
        self.corridor.clearRetainingCapacity();
        self.partial = false;
    }
};

pub const Query = struct {
    /// What a way does not go through.
    blockers: []const Blocker = &.{},
    /// How far from a blocker the middle of what walks keeps: its radius.
    clearance: f32 = 0,
};

/// How the corridor came into a polygon.
const Via = union(enum) {
    start,
    /// Across its own mesh's edge, from the polygon before.
    edge,
    link: u32,
};

const Node = struct {
    pos: Vec3,
    cost: f32,
    total: f32,
    parent: u32,
    via: Via,
    closed: bool,
};

/// The way from `start` to `end`, each first moved to the nearest point of
/// the map.
pub fn findPath(self: *const Map, gpa: Allocator, start: Vec3, end: Vec3, path: *Path, query: Query) Allocator.Error!void {
    path.clear();
    const from = self.closestPoint(start) orelse return;
    const to = self.closestPoint(end) orelse return;
    var vias: std.ArrayList(Via) = .empty;
    defer vias.deinit(gpa);
    try self.findCorridor(gpa, from, to, path, &vias, query);
    var goal = to.point;
    if (path.partial) goal = self.closestOnPolygon(path.corridor.items[path.corridor.items.len - 1], to.point);
    try self.pullTight(gpa, from.point, goal, path, vias.items, query);
}

fn findCorridor(self: *const Map, gpa: Allocator, from: Nearest, to: Nearest, path: *Path, vias: *std.ArrayList(Via), query: Query) Allocator.Error!void {
    var nodes: std.AutoHashMapUnmanaged(u32, Node) = .empty;
    defer nodes.deinit(gpa);
    const Open = struct { id: u32, total: f32 };
    const order = struct {
        fn less(_: void, a: Open, b: Open) std.math.Order {
            return std.math.order(a.total, b.total);
        }
    };
    var open: std.PriorityQueue(Open, void, order.less) = .initContext({});
    defer open.deinit(gpa);

    const h_scale = 0.999;
    const start_h = vec.length(to.point - from.point) * h_scale;
    try nodes.put(gpa, from.id, .{ .pos = from.point, .cost = 0, .total = start_h, .parent = none, .via = .start, .closed = false });
    try open.push(gpa, .{ .id = from.id, .total = start_h });
    var best = from.id;
    var best_h = start_h;

    while (open.pop()) |top| {
        const node = nodes.getPtr(top.id).?;
        if (node.closed or top.total > node.total) continue;
        node.closed = true;
        if (top.id == to.id) {
            best = to.id;
            break;
        }
        const here = node.*;
        const w = self.where(top.id);
        const part = self.parts[w.part];
        const poly = part.mesh.polygons[w.poly];
        // Its own edges.
        for (0..poly.count) |e| {
            const nb = poly.neighbours[e];
            if (nb == NavMesh.none) continue;
            const id = self.firsts[w.part] + nb;
            if (id == here.parent) continue;
            const door = self.narrowed(.{ self.corner(top.id, e), self.corner(top.id, (e + 1) % poly.count) }, query) orelse continue;
            try self.consider(gpa, &nodes, &open, top.id, here, id, vec.lerp(door[0], door[1], 0.5), 0, .edge, to, h_scale, &best, &best_h);
        }
        // And the links out of it.
        const first: u32 = if (self.link_first.len > 0) self.link_first[top.id] else 0;
        for (self.linksOf(top.id), 0..) |link, k| {
            if (link.to == here.parent and link.kind == .doorway) continue;
            const index: u32 = first + @as(u32, @intCast(k));
            switch (link.kind) {
                .doorway => {
                    const door = self.narrowed(.{ link.a, link.b }, query) orelse continue;
                    try self.consider(gpa, &nodes, &open, top.id, here, link.to, vec.lerp(door[0], door[1], 0.5), 0, .{ .link = index }, to, h_scale, &best, &best_h);
                },
                .jump => {
                    // To where it starts, then along it at its own cost.
                    var at = here;
                    at.pos = link.a;
                    at.cost += vec.length(link.a - here.pos);
                    const extra = vec.length(link.b - link.a) * (link.travel_cost - 1) + link.enter_cost;
                    try self.consider(gpa, &nodes, &open, top.id, at, link.to, link.b, extra, .{ .link = index }, to, h_scale, &best, &best_h);
                },
            }
        }
    }
    path.partial = best != to.id;
    // Back from the last to the first.
    var at = best;
    while (at != none) {
        const node = nodes.get(at).?;
        try path.corridor.append(gpa, at);
        try vias.append(gpa, node.via);
        at = node.parent;
    }
    std.mem.reverse(u32, path.corridor.items);
    std.mem.reverse(Via, vias.items);
}

fn consider(
    self: *const Map,
    gpa: Allocator,
    nodes: *std.AutoHashMapUnmanaged(u32, Node),
    open: anytype,
    from: u32,
    here: Node,
    id: u32,
    pos: Vec3,
    extra: f32,
    via: Via,
    to: Nearest,
    h_scale: f32,
    best: *u32,
    best_h: *f32,
) Allocator.Error!void {
    _ = self;
    var cost = here.cost + vec.length(pos - here.pos) + extra;
    var h: f32 = 0;
    if (id == to.id) {
        cost += vec.length(to.point - pos);
    } else h = vec.length(to.point - pos) * h_scale;
    const total = cost + h;
    const entry = try nodes.getOrPut(gpa, id);
    if (entry.found_existing and total >= entry.value_ptr.total) return;
    entry.value_ptr.* = .{ .pos = pos, .cost = cost, .total = total, .parent = from, .via = via, .closed = false };
    try open.push(gpa, .{ .id = id, .total = total });
    if (h < best_h.*) {
        best_h.* = h;
        best.* = id;
    }
}

/// The doorway left by what stands in it: the longest stretch of it no
/// blocker is nearer than its radius and the clearance to. Null when
/// nothing wide enough is left.
fn narrowed(self: *const Map, door: [2]Vec3, query: Query) ?[2]Vec3 {
    _ = self;
    if (query.blockers.len == 0) return door;
    const dx = door[1][0] - door[0][0];
    const dz = door[1][2] - door[0][2];
    const len_sq = dx * dx + dz * dz;
    if (len_sq < 1e-10) return door;
    // The stretches covered, as parts of the doorway from 0 to 1.
    var covered: [16][2]f32 = undefined;
    var count: usize = 0;
    for (query.blockers) |b| {
        const low = @min(door[0][1], door[1][1]);
        const high = @max(door[0][1], door[1][1]);
        if (high < b.center[1] - 0.5 or low > b.center[1] + b.height) continue;
        const r = b.radius + query.clearance;
        // |door[0] + t d - c|^2 = r^2, on the ground.
        const fx = door[0][0] - b.center[0];
        const fz = door[0][2] - b.center[2];
        const qa = len_sq;
        const qb = 2 * (fx * dx + fz * dz);
        const qc = fx * fx + fz * fz - r * r;
        const disc = qb * qb - 4 * qa * qc;
        if (disc <= 0) continue;
        const root = @sqrt(disc);
        const t0 = (-qb - root) / (2 * qa);
        const t1 = (-qb + root) / (2 * qa);
        if (t1 <= 0 or t0 >= 1) continue;
        if (count == covered.len) return null;
        covered[count] = .{ @max(t0, 0), @min(t1, 1) };
        count += 1;
    }
    if (count == 0) return door;
    std.mem.sort([2]f32, covered[0..count], {}, struct {
        fn less(_: void, a: [2]f32, b: [2]f32) bool {
            return a[0] < b[0];
        }
    }.less);
    // The widest gap between them.
    var best: [2]f32 = .{ 0, 0 };
    var reach: f32 = 0;
    for (covered[0..count]) |c| {
        if (c[0] - reach > best[1] - best[0]) best = .{ reach, c[0] };
        reach = @max(reach, c[1]);
    }
    if (1 - reach > best[1] - best[0]) best = .{ reach, 1 };
    const length = @sqrt(len_sq);
    if ((best[1] - best[0]) * length < 0.05) return null;
    return .{ vec.lerp(door[0], door[1], best[0]), vec.lerp(door[0], door[1], best[1]) };
}

/// The doorway from `corridor[i]` into `corridor[i + 1]`, as it was gone
/// through, narrowed by what stands in it.
fn doorway(self: *const Map, from: u32, into: u32, via: Via, query: Query) [2]Vec3 {
    switch (via) {
        .link => |index| {
            const link = self.links[index];
            return self.narrowed(.{ link.a, link.b }, query) orelse .{ link.a, link.b };
        },
        else => {},
    }
    const w = self.where(from);
    const poly = self.parts[w.part].mesh.polygons[w.poly];
    for (0..poly.count) |e| {
        if (poly.neighbours[e] == NavMesh.none) continue;
        if (self.firsts[w.part] + poly.neighbours[e] != into) continue;
        const door: [2]Vec3 = .{ self.corner(from, e), self.corner(from, (e + 1) % poly.count) };
        return self.narrowed(door, query) orelse door;
    }
    const p = self.closestOnPolygon(into, self.corner(from, 0));
    return .{ p, p };
}

/// The corridor pulled tight from `start` to `goal`, broken at each jump:
/// a corner wherever the way has to turn round the edge of a doorway, and
/// the two ends of every jump.
fn pullTight(self: *const Map, gpa: Allocator, start: Vec3, goal: Vec3, path: *Path, vias: []const Via, query: Query) Allocator.Error!void {
    const corridor = path.corridor.items;
    var portals: std.ArrayList([2]Vec3) = .empty;
    defer portals.deinit(gpa);
    var from = start;
    try appendPoint(gpa, path, from, .{});
    for (0..corridor.len -| 1) |i| {
        const via = vias[i + 1];
        if (via == .link and self.links[via.link].kind == .jump) {
            const link = self.links[via.link];
            try portals.append(gpa, .{ link.a, link.a });
            try funnel(gpa, from, portals.items, path);
            try appendPoint(gpa, path, link.a, .{ .kind = .link_start, .link = link.id });
            try appendPoint(gpa, path, link.b, .{ .kind = .link_end, .link = link.id });
            portals.clearRetainingCapacity();
            from = link.b;
            continue;
        }
        try portals.append(gpa, self.doorway(corridor[i], corridor[i + 1], via, query));
    }
    try portals.append(gpa, .{ goal, goal });
    try funnel(gpa, from, portals.items, path);
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

/// The corners from `start` through `portals`, the last of which is the
/// end, a point.
fn funnel(gpa: Allocator, start: Vec3, portals: []const [2]Vec3, path: *Path) Allocator.Error!void {
    var apex = start;
    var portal_left = start;
    var portal_right = start;
    var apex_index: usize = 0;
    var left_index: usize = 0;
    var right_index: usize = 0;
    var i: usize = 0;
    while (i < portals.len) : (i += 1) {
        const left = portals[i][0];
        const right = portals[i][1];
        // The right side of the funnel, narrowed.
        if (turn(apex, portal_right, right) <= 0) {
            if (same(apex, portal_right) or turn(apex, portal_left, right) > 0) {
                portal_right = right;
                right_index = i;
            } else {
                // Past the left side: the left side's corner is turned round.
                apex = portal_left;
                apex_index = left_index;
                try appendPoint(gpa, path, apex, .{});
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
                try appendPoint(gpa, path, apex, .{});
                portal_left = apex;
                portal_right = apex;
                left_index = apex_index;
                right_index = apex_index;
                i = apex_index;
                continue;
            }
        }
    }
    if (portals.len > 0) try appendPoint(gpa, path, portals[portals.len - 1][0], .{});
}

fn appendPoint(gpa: Allocator, path: *Path, p: Vec3, mark: Mark) Allocator.Error!void {
    if (path.points.items.len > 0 and same(path.points.items[path.points.items.len - 1], p)) {
        // A jump's mark wins over a corner's in the same place.
        if (mark.kind != .corner) path.marks.items[path.marks.items.len - 1] = mark;
        return;
    }
    try path.points.append(gpa, p);
    try path.marks.append(gpa, mark);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// A square floor `size` across with its low corner at `at`, as two
/// triangles' worth of one polygon.
fn square(gpa: Allocator, at: Vec3, size: f32) !NavMesh {
    const vertices = try gpa.dupe(Vec3, &.{ at, at + Vec3{ 0, 0, size }, at + Vec3{ size, 0, size }, at + Vec3{ size, 0, 0 } });
    const polygons = try gpa.dupe(NavMesh.Polygon, &.{.{ .vertices = .{ 0, 1, 2, 3, none, none }, .count = 4, .area = 63 }});
    return NavMesh.init(gpa, vertices, polygons, .{});
}

test "two meshes side by side are one map, and a way goes from one into the other through where they meet" {
    const gpa = testing.allocator;
    var left = try square(gpa, .{ 0, 0, 0 }, 4);
    defer left.deinit(gpa);
    var right = try square(gpa, .{ 0, 0, 0 }, 4);
    defer right.deinit(gpa);
    // The second put four along x, and a fraction apart.
    const parts = [_]Part{
        .{ .mesh = &left },
        .{ .mesh = &right, .to_world = .{ .rows = .{ .{ 1, 0, 0, 4.1 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 1 } } }, .to_local = .{ .rows = .{ .{ 1, 0, 0, -4.1 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, -1 } } } },
    };
    var map = try Map.init(gpa, &parts, &.{}, .{});
    defer map.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), map.polygonCount());
    try testing.expectEqual(@as(usize, 1), map.linksOf(0).len);
    try testing.expectEqual(@as(usize, 1), map.linksOf(1).len);
    // The doorway is where the two overlap: z from 1 to 4.
    const door = map.linksOf(0)[0];
    try testing.expectApproxEqAbs(@as(f32, 1), @min(door.a[2], door.b[2]), 1e-4);

    var path: Path = .{};
    defer path.deinit(gpa);
    // Straight across where the line fits through the doorway.
    try map.findPath(gpa, .{ 1, 0, 0.5 }, .{ 7, 0, 4.5 }, &path, .{});
    try testing.expect(!path.partial);
    try testing.expectEqual(@as(usize, 2), path.corridor.items.len);
    try testing.expectEqual(@as(usize, 2), path.points.items.len);
    // Round the doorway's end where it does not: at z = 1.
    try map.findPath(gpa, .{ 3, 0, 0.2 }, .{ 7.5, 0, 1.4 }, &path, .{});
    try testing.expectEqual(@as(usize, 3), path.points.items.len);
    try testing.expectApproxEqAbs(@as(f32, 4), path.points.items[1][0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1), path.points.items[1][2], 1e-3);

    // Too far apart, they do not meet.
    const apart = [_]Part{ parts[0], .{ .mesh = &right, .to_world = .{ .rows = .{ .{ 1, 0, 0, 5 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 } } }, .to_local = .{ .rows = .{ .{ 1, 0, 0, -5 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 } } } } };
    var far = try Map.init(gpa, &apart, &.{}, .{});
    defer far.deinit(gpa);
    try far.findPath(gpa, .{ 1, 0, 0.5 }, .{ 7, 0, 3 }, &path, .{});
    try testing.expect(path.partial);
}

test "a jump joins two floors apart, and its ends are marked corners of the way" {
    const gpa = testing.allocator;
    var near = try square(gpa, .{ 0, 0, 0 }, 4);
    defer near.deinit(gpa);
    var high = try square(gpa, .{ 8, 2, 0 }, 4);
    defer high.deinit(gpa);
    const parts = [_]Part{ .{ .mesh = &near }, .{ .mesh = &high } };
    var map = try Map.init(gpa, &parts, &.{.{ .start = .{ 3.8, 0, 2 }, .end = .{ 8.2, 2, 2 }, .bidirectional = false, .id = 7 }}, .{});
    defer map.deinit(gpa);
    var path: Path = .{};
    defer path.deinit(gpa);
    try map.findPath(gpa, .{ 1, 0, 1 }, .{ 10, 2, 3 }, &path, .{});
    try testing.expect(!path.partial);
    var start: ?usize = null;
    for (path.marks.items, 0..) |m, i| {
        if (m.kind == .link_start) start = i;
    }
    const at = start.?;
    try testing.expectEqual(@as(u32, 7), path.marks.items[at].link);
    try testing.expectEqual(Mark.Kind.link_end, path.marks.items[at + 1].kind);
    try testing.expectApproxEqAbs(@as(f32, 3.8), path.points.items[at][0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 8.2), path.points.items[at + 1][0], 1e-3);
    // One way only: not back.
    try map.findPath(gpa, .{ 10, 2, 3 }, .{ 1, 0, 1 }, &path, .{});
    try testing.expect(path.partial);
}

test "a blocker in a doorway narrows it, and one across it closes it" {
    const gpa = testing.allocator;
    var a = try square(gpa, .{ 0, 0, 0 }, 4);
    defer a.deinit(gpa);
    var b = try square(gpa, .{ 4, 0, 0 }, 4);
    defer b.deinit(gpa);
    const parts = [_]Part{ .{ .mesh = &a }, .{ .mesh = &b } };
    var map = try Map.init(gpa, &parts, &.{}, .{});
    defer map.deinit(gpa);
    var path: Path = .{};
    defer path.deinit(gpa);
    // Standing in the middle of the doorway at x = 4: the way goes past it.
    try map.findPath(gpa, .{ 1, 0, 2 }, .{ 7, 0, 2 }, &path, .{ .blockers = &.{.{ .center = .{ 4, 0, 2 }, .radius = 1 }}, .clearance = 0.2 });
    try testing.expect(!path.partial);
    var went_round = false;
    for (path.points.items) |p| {
        if (@abs(p[0] - 4) < 1e-3 and @abs(p[2] - 2) >= 1.2 - 1e-3) went_round = true;
    }
    try testing.expect(went_round);
    // One wider than the doorway: no way through.
    try map.findPath(gpa, .{ 1, 0, 2 }, .{ 7, 0, 2 }, &path, .{ .blockers = &.{.{ .center = .{ 4, 0, 2 }, .radius = 2.5 }} });
    try testing.expect(path.partial);
}
